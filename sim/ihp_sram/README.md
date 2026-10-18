# IHP SG13 SRAM simulation models (vendored, Apache-2.0)

Simulation-only Verilog for the macros used by `src/instr_mem.v`. Kept out of `src/` on purpose:
`SRAM_1P_behavioral*` is not synthesisable as a macro, and the ASIC flow reads the macro as a black box
(liberty/LEF/GDS), not from these files.

**Current instruction memory: one 1P 256x32 macro per engine** (`run_tests.ps1` and the Python harnesses compile
the first two files):

| File | Source |
|---|---|
| `RM_IHPSG13_1P_256x32_c2_bm_bist.v` | `IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/` (copy of `C:\tools\ihp-sram`) |
| `RM_IHPSG13_1P_core_behavioral_bm_bist.v` | same directory in the IHP-Open-PDK repo (`main`, fetched 2026-10-17); defines `SRAM_1P_behavioral_bm_bist` used by the wrapper above. Write bit mask `A_BM[i]=1` writes bit i. |

Previous design (two 1P 64x16 macros per engine, 64 words), no longer used by `src/` but kept for reference:

| File | Source |
|---|---|
| `RM_IHPSG13_1P_64x16_c2.v` | `IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/` |
| `RM_IHPSG13_1P_core_behavioral.v` | same directory; defines `SRAM_1P_behavioral` |

Compile with `-DFUNCTIONAL` (without it the wrappers use the timing-annotated path with `$setuphold`).
The models have a registered read (`A_DOUT` updates on the clock edge, holds when not enabled) and
`A_DLY` must be tied to 1'b1. The 256x32 macro also has a BIST port (tied off in `instr_mem.v`: `A_BIST_EN = 0`).
