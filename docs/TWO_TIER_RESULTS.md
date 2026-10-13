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

### Phase 2 regression (worktree, after fixes)
The first tier-1 run of the Phase 2 commit found:
- `tb_mgmt_dual` still expected `0x1004`/`0x2004` to be unmapped (they are RESET_PC now); moved to `0x1018`/`0x2018`.
- The committed combo baseline was empty: it was copied while that suite was still writing.
- A Phase 1 mutant anchor already pointed at Phase 3 code (sequencing mistake).
- Two failures caused by a different simulator (Icarus 14) on `PATH` (L7).

All of these were fixed in a follow-up commit on the Phase 2 branch, followed by a re-run.

## Phase 3: execution from L2 (2026-10-13)

**RTL:** 5 files, +117 / -17 lines, about 25 of them `ifdef FORMAL`.
- `pc_reg`: reset vector through a boot flag (`rst_val = 0` behaves like before).
- `control_unit`: `instr_valid` input (a missing word is a bubble: nothing commits, no trap; a hold never waits) and `bubble` output.
- `engine_top`:
  - fetch from L2 through `IR2` with urgent same-clock requests (mode A);
  - fault cause 2 outside `L2_RANGE`;
  - `bubble` counted only while running;
  - FORMAL-only ports and assertions.
- `instr_mem`: abstract memory under FORMAL.
- Top: engines connected to `l2_mem`.

| Test | Result |
|---|---|
| V3.1 `tb_control_unit`: `instr_valid=0` with all 32 opcodes (no strobe, no trap, no halt, bubble); toggling inside a hold changes nothing; `pc_fault` wins over a missing word | PASS (after one fix, below) |
| `tb_pc_reg` A4: reset vector in and after reset; vector 0 = old behaviour | PASS |
| V3.2-V3.4 `tb_l2_exec` (2 engines + L2 vs 2 instruction-set models, lockstep modulo bubbles, arbiter model every clock, bubble accountant) | **50 seeds, 15,000,326 clocks: 0 mismatches**, 0 arbiter mismatches, 0 unexplained bubbles, 0 bubbles in L1. Bubbles: 859,185 lost to the other engine, 343,582 lost to the host, 19,681 first L2 fetch after RUN |
| V3.5 wait bounds (measured) | round-robin: at most 1 non-host loss in a row; favoured engine: 0 |
| V3.6 fixed priority + favoured engine in a one-clock L2 loop | other engine makes no progress for 100,000 clocks (documented starvation), no fault, moves within 3 clocks after switching to round-robin |
| V3.7 engine in L1 vs L2 thrash with priority + host read every clock + policy churn, 50,000 clocks | 0 bubbles (T11) |
| V3.8 `tb_engine_ops`: sequential run past hi, JMP to lo-1, DJNZ/JPH/JPL/JPO to hi+1 | fault cause 2, nothing at the outside word commits |
| V3.9 reset vectors 1 / 0x3F (first instruction in clock 1, no bubble), L2 lo / hi (exactly 1 bubble); RUN dropped 0-4 clocks into a losing request | PASS |
| V3.10 uncontended jump into L2 | 0 bubbles (mode A) |
| F1, F2, F5, F9 (`formal/fv_engine.sby ctrl`: datapath and memories as free cut points, PDR) | **proved (unbounded)**. The proof is not vacuous: the same run fails on "bubble gate removed" (F2) and "request while held" (F9) |
| F3 word integrity (`fv_engine.sby f3`, full model, BMC) | no counterexample through step 11 (depth 12). Deeper steps are too slow on the full model (about 25 minutes per step) |
| Mutants (`host/mutate.py 3`) | **10/10 detected** (see note) |
| `run_tests.ps1` | 24/24 PASS |

**Findings and fixes while building:**
- A held engine with an L2 reset vector reported `bubble` (the word is not fetched while held). This would have made the Phase 6 counter count held clocks. `bubble` is now gated by RUN.
- The plan says a hold must ignore `instr_valid`. The first version stalled the end of a hold when the word was missing. That case cannot happen (F1), but the gate is now limited to `S_EXEC`: one term.
- Testbench bugs:
  - a global loop variable shared by the stimulus and the checker made a model write the wrong engine's memory;
  - `protected` is a SystemVerilog keyword;
  - the testbench raised RUN in the same clock as a new RESET_PC, which a real host cannot do (separate frames). The formal harness assumes the same.

**Mutation note:** three planned mutants are *equivalent*, so no test can detect them:
- a bubble re-applying a stale SETH;
- a bubble loading the delay counter for a stale WAIT;
- legality checked during a bubble.

During a bubble the word on the bus is always the last executed instruction, so re-applying it changes nothing visible. They were replaced by non-idempotent ones of the same class: stale OUT1 shifts the OSR, stale DJNZ counts, gate removed.

**Deviations from the plan:**
- **E1** cannot hold as written. With L2 present and an empty range, a jump to an L2 address faults with cause 2, not 1, so the engine is not equivalent to Phase 1. The intent (the L1 path is unchanged) is covered by E2 (re-run on the Phase 3 RTL) and by `tb_fetch_equiv` / `tb_fetch_equiv_v2`, whose DUT is now the L2_EN=1 engine with an empty range.
- The reference model I2 is an independent instruction-set model written from the documents, not the frozen Phase 1 `control_unit` with a gated clock. It is more independent, and it was itself checked by the L1-only lockstep.
- Host arbiter model I4 is a Verilog function shared by `tb_arb` and `tb_l2_exec`, not a Python log reader.

## Phase 4: prefetch buffer (2026-10-13)

**RTL:** 2 files, +29 / -7 lines.
- `control_unit`: `waiting` output, true when the current word stays current next clock (held, not in the last clock, or blocked).
- `engine_top`: an address-tagged prefetch buffer (PB) that fetches pc+1 while waiting (`FETCH_CFG[0]`); prefetch requests are class 3 and are promoted to class 2 after one loss (`lost`).

The plan's "invalidate on jump / COPY / host write" is not built: PB is tagged with its address and only in-range words are ever executed, which the host cannot change while the engine runs. So only reset clears it (deviation, no correctness effect).

| Test | Result |
|---|---|
| V4.1 `tb_engine_ops`, worst contention (a phantom engine requesting urgently every clock + host reads every 2nd clock): bubbles in front of the next word, PB off/on, holds 1-7 and 21 clocks | holds of 1-3 clocks: same as PB off (1-3 bubbles). **Holds of 4 or more clocks: 0 bubbles with PB** (PB off: up to 1). **H_PF = 4 clocks** under round-robin |
| V4.4 PB on never gives more bubbles than PB off (40 cases) | PASS |
| V4.6 a prefetch waits at most 2 non-host clocks against an engine asking every clock | PASS; also proved at engine level (F10 engine side, `fv_engine ctrl`) |
| V4.7 PULL blocked for ever: requests stop once pc+1 is in PB | PASS (0 requests in 50 clocks) |
| V4.5 UART TX (434-clock bit) run from L2 under the same contention vs from L1 | same bits, never early, at most 1 clock late per bit (8 bubbles over the byte) |
| V4.4/V4.8 `tb_l2_exec` with random `FETCH_CFG` | **50 seeds, 22,528,787 clocks: 0 mismatches**, 143,633 class-3 requests, every bubble explained, a fresh prefetch always asks at class 3 |
| F1, F2, F5, F9, F10 engine side (`fv_engine ctrl`, PDR) | proved (unbounded); the promotion bound fails as it should when promotion is removed |
| Mutants (`host/mutate.py 3 4`) | 16/16 detected |

**D10 decision: BB (branch-ahead) not built.** Its only use would be the DJNZ-to-OUT1 fetch of UART-class loops run from L2. V4.5 shows that costs at most one clock per bit (0.23% of a 434-clock bit), well inside UART tolerance. The plan's BB tests (V4.2, V4.3) are therefore not applicable.

## Phase 5: COPY (2026-10-13)

**RTL:**
- `isa.vh`: `OP_COPY` = 21 (`[7:0]` src, `[13:8]` dst, `[19:14]` n-1).
- `control_unit`: state `S_COPY`; a refused COPY traps with cause 3 before anything is written; `copying` output.
- `engine_top`:
  - a COPY sequencer (counter `k`, one class-3 L2 read per word with promotion, written to L1 the clock after its grant through the existing L1 write port);
  - every check is done before the first write;
  - `copy_wait` output for the testbench model.
- `host/isa.py`: `COPY` = `(src, dst, n)`.

| Test | Result |
|---|---|
| `tb_control_unit` COPY: refused (cause 3, no strobe); accepted (waits, no bubble, ends on `copy_done`) | PASS |
| V5.1 every n = 1..64 x every dst with dst+n <= 64 (2,080) + every src at n = 1 (255) | **2,335 cases: 0 wrong**, nothing outside dst..dst+n-1 written |
| V5.3 duration | the engine waits exactly n+1 clocks; a COPY instruction takes **n + 2** clocks uncontended (T10: c = 2) |
| V5.2 COPY from L1, dst+n = 65, src < lo, src+n-1 > hi, src+n-1 > 255 | fault cause 3, L1 unchanged |
| V5.5 RUN dropped at each of the first 11 clocks of an 8-word COPY | the written words are a prefix, every other L1 word unchanged, the restarted COPY completes |
| V5.6 UART TX installed by COPY from L2 and run from L1 vs loaded by the host | identical edge spacing (start 16 clocks later: the COPY) |
| V5.4 / V5.8 `tb_l2_exec` with random COPYs (both engines, contention, host traffic) | **50 seeds, 22,530,568 clocks: 0 mismatches**; 20,652 COPYs completed, 19,591 refused |
| F7 (`fv_engine ctrl`): a COPY writes only inside dst..dst+n-1, only while it runs, never when refused | proved (unbounded); fails as it should with an off-by-one write address |
| Mutants (`host/mutate.py 5`) | **7/7 detected** (after V5.5 was extended to check all 64 L1 words: "keeps writing after RUN falls" wrote word dst-1) |
| V5.9 host L1 write while running | refused by the existing rule (`tb_mgmt_frame`); unchanged |

**Notes:**
- The instruction-set model performs a COPY in one step, so a COPY cut by RUN cannot be modelled. After such a cut, `tb_l2_exec` copies the DUT's L1 into the model; the prefix property itself is checked by V5.5.
- No prefetch runs during a COPY (the plan says "may"): the word after a COPY is fetched urgently.
- V5.7 (runtime protocol switch) needs the firmware library and is done in Phase 7.

## L. Limitations and open issues (updated every phase)

| # | Item | Kind | Status |
|---|---|---|---|
| L1 | CMOS5L acceptance of the SG13G2 SRAM macros (A9), now for two macro types | external blocker | open; ask Tiny Tapeout |
| L2 | Urgent-path timing is a gate-count estimate, not STA (no wires, typ corner, slow-corner clock-to-out of the 256x32 macro not available locally) | estimate | open until the physical flow |
| L3 | Verilator is 2-state: X checks (an unwritten word reads X, plan A7) only work in Icarus | tool limit | accepted; X checks stay in Icarus |
| L4 | `eqy` on Windows needs GNU make on PATH (`C:\Users\risha\miniconda3\envs\eda\Library\bin`) | tool setup | documented |
| L5 | FPGA tops (`src/fpga/`) still instantiate the old `engine_top` port list (6-bit pc, no L2 ports); not built or run (D13). The UART hex images are unchanged and still valid | out of scope | open |
| L8 | Fixed arbitration priority starves the other engine's L2 code with no bound (V3.6), as designed (D6); its L1 code is unaffected | by design | documented |
| L9 | F3 (word integrity) is proved only to depth 12 on the full engine model; deeper proof needs a smaller memory abstraction | proof depth | open |
| L12 | A COPY cut by RUN leaves a prefix of the words written (by design, D9); firmware must re-run the COPY after a restart | design | documented |
| L7 | Two "transient" failures in the Phase 2 regression (a testbench refused to compile, and SPI slave response timings shifted by one clock) were caused by `regress.py` putting the OSS CAD Suite first on `PATH`, which brings **Icarus 14** instead of the project's Icarus 12. They were not temp-file collisions, as first suspected. `regress.py` now puts `C:\iverilog\bin` first; each job also keeps its own `TMP` (the temp names are not unique, but they did not cause these failures) | tool setup | fixed |
| L10 | The SPI slave suite measures slave response points one clock later under Icarus 14 than under Icarus 12 (same RTL), most likely a same-time-step race between the testbench peer and the design. Not investigated (outside this plan); the project is verified on Icarus 12 | simulator sensitivity | open |
| L11 | Without BB, a one-clock instruction just before a jump into or inside L2 can cost one bubble under contention: L2 placement of tight loops is bounded, not exact (T9) | design choice (D10) | documented |
| L6 | Formal tools on Windows: Yosys formal has no hierarchical references (properties use ports or harness-side shadows), and `sby`/`eqy` read `[files]`/sources relative to the working directory. eqy partition file names break on auto-generated names that carry a drive letter, so sources are read through relative paths | tool limits | worked around |
