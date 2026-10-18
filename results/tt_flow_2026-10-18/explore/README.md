# Exploration runs of 2026-10-18 (kept: small result files only; the run directories were deleted to free disk space)

All runs: Tiny Tapeout CMOS5L flow, 6x4 tiles, SRAM macros at (60,120) and (60,470), RTL of the day (ALU + CRC units), `librelane/flow_run_wsl.sh`.
Each row is one change in the flow configuration or the RTL; the reason for the next row is in the last column. Numbers come from the flow logs and
`metrics.json` (sub-directories `tt6`, `tt6b`, `tt6c`; the `grt_*.txt` files are the global-routing congestion reports).

| Run | RTL / settings | Result | Why it was changed |
|---|---|---|---|
| tt7 (DELAY 4) | old CRC (variable-width masks), synthesis strategy `DELAY 4` (LibreLane/IHP default), boxes v1 | 21,462 cells, 309k um^2; global routing: usage **79 %**, overflow **23,889**, wirelength **3.48 M um**; detailed routing started with 154k violations | the netlist is 35 % larger than necessary and unroutable on four metal layers: `SYNTH_STRATEGY = AREA 0` |
| tt6 / tt7 (AREA 0, old CRC) | `AREA 0`, old CRC | setup violation of 6.6 ns at the slow corner at the CRC byte step | CRC unit re-implemented left-aligned (no 32:1 muxes in the 8-step chain) |
| tt6 (`tt6/`) | `AREA 0`, new CRC, ripple-carry adder, 20 ns | routing clean (0 DRC, LVS 0); **setup -5.88 ns** at the slow corner: the critical path ran through a 32-stage ripple-carry chain of the ALU adder | shared Kogge-Stone prefix adder |
| tt6b (`tt6b/`) | + slow-corner resizer, post-global-route repair | worse: setup -8.35 ns, 16 DRC errors, 4 LVS errors, hold -0.13 ns | post-route repair switched off again |
| tt6c (`tt6c/`) | prefix adder, slow-corner resizer, Metal4 routing obstructions over the macros, 20 ns | routing clean (**0 DRC**, LVS 0, 0 antenna); setup -6.75 ns (546 endpoints) at the slow corner, +1.79 ns typical; hold -0.21 ns at fast/typical because the resizer was restricted to the slow corner | clock period 30 ns, all resizer corners, hold margins 0.5 / 0.4 ns (final runs `tt6f`, `tt7f`) |
| tt7 (boxes v1) | boxes for 11 modules, SRAM-side, FIFOs left, mgmt top | detailed routing never converged: 36..57 **Short** violations between signal wires and the Metal4 power stripes bridged over the SRAM macros | `ROUTING_OBSTRUCTIONS` on Metal4 over both macros |
| tt7c (boxes v1) | v1 + obstructions | global routing: usage 42.3 %, overflow **1,291**, wirelength **1.82 M um** (flat tt6c: 34.0 %, 225, 1.54 M um) | measured where the wiring goes (below), tried v2, v3 |
| tt8 (boxes v2) | only ALU, CRC, management boxed (60 % utilisation) | usage 38.8 %, overflow 1,076, wirelength 1.73 M um | boxes were too tight for the dense XOR/mux blocks: v3 with 40 % utilisation |
| tt9 (boxes v3) | v3 | usage 41.8 %, overflow **153** (better than flat), wirelength **1.80 M um** (+17 % over flat) | final boxed run `tt7f` uses v3 |

## Where the extra wiring of boxes v1 came from (half-perimeter wirelength after detailed placement, `librelane/net_matrix.py --hpwl`)

| | flat (tt6c) | boxes v1 (tt7c) |
|---|---|---|
| nets inside one module | 567,676 um | 697,874 um (+23 %) |
| nets between modules | 233,974 um (190 um/net) | 345,538 um (295 um/net) (+48 %) |
| FIFO of engine 0, inside | 22,746 um | 49,639 um (box of aspect ratio 4:1) |
| CRC of engine 0, inside | 65,807 um | 84,649 um |
| ALU of engine 0, inside | 124,463 um | 141,856 um |

Connectivity of the flat placement (weighted net counts, `net_matrix_flat_placement.json`): control - shifters 146, control - SRAM 134, control - ALU 96,
control - FIFO 68, FIFO - management 58, control - CRC 46. The SRAM macro has **all signal pins on its bottom edge** (x 3..413 um), so the control logic wants to sit
below the macro.
