# IHP SG13 SRAM simulation models (vendored, Apache-2.0)

Simulation-only Verilog for the 1P 64x16 macro used by `src/instr_mem.v`. Kept out of `src/` on
purpose: `SRAM_1P_behavioral` is not synthesisable as a macro, and the ASIC flow reads the macro as a
black box (liberty/LEF/GDS), not from these files.

| File | Source |
|---|---|
| `RM_IHPSG13_1P_64x16_c2.v` | `IHP-Open-PDK/ihp-sg13g2/libs.ref/sg13g2_sram/verilog/` (copy of `C:\tools\ihp-sram`) |
| `RM_IHPSG13_1P_core_behavioral.v` | same directory; defines `SRAM_1P_behavioral` used by the wrapper above |

Compile with `-DFUNCTIONAL` (without it the wrapper uses the timing-annotated path with `$setuphold`).
The model has a registered read (`A_DOUT` updates on the clock edge, holds when not enabled) and
`A_DLY` must be tied to 1'b1.
