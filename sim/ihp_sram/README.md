# IHP SG13 SRAM simulation models (vendored, Apache-2.0)

Simulation-only Verilog for the SRAM macros: the 1P 64x16 used by `src/instr_mem.v` (L1) and the
1P 256x32 used by the shared L2 (docs/TWO_TIER_MEMORY_PLAN.md). Kept out of `src/` on purpose: the
behavioral cores are not synthesisable as macros, and the ASIC flow reads the macros as black boxes
(liberty/LEF/GDS), not from these files.

| File | Source |
|---|---|
| `RM_IHPSG13_1P_64x16_c2.v` | `IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/` (copy of `C:\tools\ihp-sram`) |
| `RM_IHPSG13_1P_core_behavioral.v` | same directory; defines `SRAM_1P_behavioral` used by the wrapper above |
| `RM_IHPSG13_1P_256x32_c2_bm_bist.v` | same directory (identical to `C:\tools\ihp-sram` and to IHP-Open-PDK commit `5e6d592e`) |
| `RM_IHPSG13_1P_core_behavioral_bm_bist.v` | IHP-Open-PDK commit `5e6d592e4002946a4616f798c357f0f3c06cf3b6` (not in the local copy); defines `SRAM_1P_behavioral_bm_bist` |

Compile with `-DFUNCTIONAL` (without it the wrappers use the timing-annotated path with `$setuphold`)
and name the testbench as the top (`-s <tb>`): an uninstantiated wrapper would otherwise become a
second top with `A_DLY` floating and stop the run. The models have a registered read (`A_DOUT`
updates on the clock edge, holds when not reading); `A_DLY` must be tied to 1'b1. `tb/tb_l2_macro.v`
pins down the 256x32 behaviour (V0.1) and proves `formal/abs_sram.v` equivalent to it (V0.2).
