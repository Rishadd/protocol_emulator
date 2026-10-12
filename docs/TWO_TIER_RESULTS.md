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

## L. Limitations and open issues (updated every phase)

| # | Item | Kind | Status |
|---|---|---|---|
| L1 | CMOS5L acceptance of the SG13G2 SRAM macros (A9), now for two macro types | external blocker | open; ask Tiny Tapeout |
| L2 | Urgent-path timing is a gate-count estimate, not STA (no wires, typ corner, slow-corner clock-to-out of the 256x32 macro not available locally) | estimate | open until the physical flow |
| L3 | Verilator is 2-state: X checks (an unwritten word reads X, plan A7) only work in Icarus | tool limit | accepted; X checks stay in Icarus |
| L4 | `eqy` on Windows needs GNU make on PATH (`C:\Users\risha\miniconda3\envs\eda\Library\bin`) | tool setup | documented |
