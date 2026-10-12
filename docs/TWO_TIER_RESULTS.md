# Two-Tier Instruction Memory: Results

Evidence for [TWO_TIER_MEMORY_PLAN.md](TWO_TIER_MEMORY_PLAN.md), filled in phase by phase. Simulation only
(Icarus Verilog 12 with the IHP SRAM functional models; Verilator 5.052 for coverage builds), no physical flow.
Test IDs (V*, F*, E*, A*) refer to the plan. §L at the end tracks every limitation and open issue.

## Phase 0: prerequisites (2026-10-13)

| Step | Result |
|---|---|
| 0.1 Decisions | User instruction 2026-10-13: build the plan as written. D0 = two-tier. D1-D9, D12-D15 as proposed. D7 = **mode A** (below). D10 (BB) decided after Phase 4a. D11: Phase 8 (`CALL`/`RET`) not built (no decision to build it). |
| 0.2 Models | `RM_IHPSG13_1P_256x32_c2_bm_bist.v` (identical to the local copy) and `RM_IHPSG13_1P_core_behavioral_bm_bist.v` (IHP-Open-PDK `5e6d592e`) vendored in `sim/ihp_sram/`. All runners now compile every file there and name the testbench as top (`-s`). |
| 0.3 V0.1 | `tb_l2_macro` PASS: 1-clock read latency; 40 patterns over all 256 words (all-0, all-1, checkerboard, inverse, address, 32 walking-1, 3 random); output holds when not reading; write-through; `men=0` write and read are no-ops; unwritten word reads X; BIST pins toggling with `A_BIST_EN=0` have no effect. |
| 0.8 V0.2 | `formal/abs_sram.v` vs vendor model, 1,000,000 random operations: **0 mismatches in 1,020,510 clocks**. |
| 0.4 V0.3 area | Stand-in (`synth/experiments/l2_standin.v`: L2 macro + per-engine IR2, PB, config regs, COPY counter, fault cause, instruction and L1-write muxes + arbiter and address mux): **69,494 µm² = 49,488.5 macro + ~20,006 glue** (plan estimate for the same parts ~24.5k; management additions not included). |
| 0.5 V0.4 depth | Generic 2-input gate netlist, `ltp -noff`: longest path 19 levels; the urgent path is buffer compare (7 levels to `pb_hit`) → arbiter (`gnt` at 12) → address mux (2-3 more) ≈ **13-15 gate levels** ≈ 1.3-2.2 ns at an assumed 0.1-0.15 ns/gate typ, after a ~3.1 ns macro clock-to-out: well inside 20 ns, so **D7 = mode A** (same-clock request). Not STA; see L2. |
| 0.6 CMOS5L acceptance | Not answerable from here; stays open (L1). |
| 0.7 V0.5 tools | `sby` (proof PASS and a real counterexample found on a toy), `eqy` (equivalent PASS / different FAIL; needs GNU make, installed in conda env `eda`), Verilator 5.052 + g++ 16.2 in WSL (conda env `vl`, no sudo): builds and runs `tb_l2_macro` with coverage, SRAM models included. Lint of the chip and both SRAM models: 0 errors. |
| Regression | `run_tests.ps1` 20/20 PASS (19 existing + `tb_l2_macro`). |

Other finding: the PDK has larger single-port macros (512x32, 1024x32, 2048x32, up to 8192x32) the plan did
not consider; 256x32 kept as planned.

## Phase 1: 9-bit PC and ISA re-encoding, L1 only (2026-10-13)

**RTL:** 5 files, +42 / -28 lines. `isa.vh`: 9-bit addresses, JPH/JPL pin at `[11:9]`.
- `control_unit`: 9-bit `jump_addr`, `pc_fault` input, `fault_cause` output.
- `engine_top`: 9-bit pc; a pc outside 0x000-0x03F faults with cause 1 before it executes.
- `mgmt` / top: CTRL read = `{pc[18:10], cause[4:3], fault, halted, run}`.

**Host:** `host/isa.py` is now the only encoder; `spi_prog`, `i2c_prog` and `uart_workload` use it with unchanged APIs.

| Test | Result |
|---|---|
| V1.1 `tb_control_unit`: JPH/JPL exhaustive (8 pins x 2 ops x taken/not x 7 addresses = 224), 9-bit JMP, `pc_fault` causes 1-3 trap with no strobe | PASS |
| V1.2 `tb_engine_ops`: JMP/DJNZ/JPO/JPH/JPL to 0x040, 0x0FF, 0x100, 0x1FF and a sequential run past 0x03F fault with cause 1; the word at the bad pc never commits | PASS (21 cases) |
| V1.3 `tb_fetch_equiv_v2` (vs frozen pre-two-tier engine, JPH/JPL/JPO/PUSHI, two encodings) and V1.4 `tb_fetch_equiv` (vs 42d262a) | 20 seeds each: **6,691,702 clocks, 0 mismatches** |
| V1.5 / V1.6 / 1.7 `host/test_isa.py` | 4,025 round-trip words; 55 generator programs, only the 99 JPH/JPL words moved; committed UART hex images = generator output |
| V1.7 `tb_mgmt_read` | CTRL layout, cause 0 (illegal) and cause 1 (pc 0x040) read through SPI |
| V1.8 every protocol suite vs the tt-phase0 baseline (`results/two_tier_baseline/`) | **identical**: spi_test 312/312 (584 lines), i2c_test 60/60, mgmt_duplex_stress all PASS, workload uart 13/13, uartlimits, spi/i2c/combo 42/42 |
| Mutants (`host/mutate.py 1`) | **6/6 detected** |
| `run_tests.ps1` | 21/21 PASS |

**Findings:**
- The recorded result files are not exact baselines. `results/spi_2026-10-11` predates the pad claims (4 frames fewer per chip case), and the UART RX poll counts in `results/workload_2026-10-12` differ. The suites were re-run on tag `tt-phase0` and that output is the baseline from now on (`results/two_tier_baseline/`, worktree `../pe_baseline`).
- Testbench bugs caught while building:
  - a PUSHI operand OR-ed as 32 bits overwrote the opcode;
  - a bare `else` after `` `CHECK `` binds to the macro's `if`;
  - `8'h80 + integer` is 32 bits wide inside a concatenation.
- **Deviations from the plan:**
  - `tb_fetch_equiv_v2` is a 3-line define wrapper around `tb_fetch_equiv`.
  - The 42d262a reference now uses the frozen v1 control unit (it used to share `src/control_unit.v`).

## Phase 2: shared L2 storage and host access (2026-10-13)

**RTL:**
- New `src/l2_mem.v` (48 lines): the 256x32 macro with tie-offs, and the 3-class arbiter (host > class 2 > class 3; round-robin, engine 0 first or engine 1 first). The grant is in the same clock; data is ready one clock later.
- `mgmt`: L2 window `0x0400+4i`, RESET_PC / L2_RANGE / FETCH_CFG per engine (written only while that engine is held), ARB_CFG (any time; 3 refused), and protection (a host write inside a running engine's range is refused).
- Top: `l2_mem` is instantiated unless `-DNO_L2`. The engines do not request L2 yet.

| Test | Result |
|---|---|
| V3.4 (unit, built now) `tb_arb`: 192 combinations (host x request x class x policy x pointer); grant, address reached the macro, pointer update | PASS |
| V2.1 `tb_l2_host`: 6 patterns x 256 words loaded and read back through SPI | PASS |
| V2.2 aborted L2 frames cut after bytes 1-6 + a crafted cut frame whose last 7 bytes look like a complete L2 write | PASS (nothing written) |
| V2.3 unmapped / misaligned / below-window addresses | err, no access |
| V2.4 protection, 10 boundary points x {none, e0, e1, both running}, overlapping ranges | refused exactly inside running ranges, word unchanged |
| V2.5 reset values; held-only rule for RESET_PC/L2_RANGE/FETCH_CFG; ARB_CFG while running; reserved bits and policy 3 refused | PASS |
| V2.6 L2 read inside the frame vs SCLK half period | correct at 8, 7, 6, 5, 4 clocks; **fails at 3 clocks** (contract: >= 8) |
| V2.7 UART TX from L1 while the host hammers L2 | P0 waveform identical (27 transitions) to a quiet run |
| V2.8 `run_tests.ps1 -Define NO_L2` | 21/21 PASS |
| F4, F10, F11 + address path (`formal/fv_l2_arb`, PDR) | **proved (unbounded)** in 29 s |
| E2 (`host/run_eqy.py E2`): the `-DNO_L2` chip == the tt-phase1 chip (eqy, macros as black boxes) | **proved**: 2,524/2,524 partitions equivalent |
| F6, complete-frame commit rule, F12 (`formal/fv_mgmt`, PDR, tasks l2 / noL2) | **proved (unbounded)** |
| Mutants (`host/mutate.py 2`) | **10/10 detected** (the crafted cut-frame case was added after the first run missed "write on an incomplete frame") |

## L. Limitations and open issues (updated every phase)

| # | Item | Kind | Status |
|---|---|---|---|
| L1 | CMOS5L acceptance of the SG13G2 SRAM macros (A9), now for two macro types | external blocker | open; ask Tiny Tapeout |
| L2 | Urgent-path timing is a gate-count estimate, not STA (no wires, typ corner, slow-corner clock-to-out of the 256x32 macro not available locally) | estimate | open until the physical flow |
| L3 | Verilator is 2-state: X checks (an unwritten word reads X, plan A7) only work in Icarus | tool limit | accepted; X checks stay in Icarus |
| L4 | `eqy` on Windows needs GNU make on PATH (`C:\Users\risha\miniconda3\envs\eda\Library\bin`) | tool setup | documented |
| L5 | FPGA tops (`src/fpga/`) still instantiate the old `engine_top` port list (6-bit pc, no L2 ports); not built or run (D13). The UART hex images are unchanged and still valid | out of scope | open |
| L6 | Formal tools on Windows: Yosys formal has no hierarchical references (properties use ports or harness-side shadows), and `sby`/`eqy` read `[files]`/sources relative to the working directory. eqy partition file names break on auto-generated names that carry a drive letter, so sources are read through relative paths | tool limits | worked around |
