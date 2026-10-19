# Tiny Tapeout CMOS5L flow: 6x4 tiles, two SRAM macros (2026-10-17/18)

Steps 1 and 2 of [CHALLENGE_CHECK.md](CHALLENGE_CHECK.md) section 4: the project now has the Tiny Tapeout (TT) CMOS5L template
layout and goes RTL to GDS with the TT configuration, the real 6x4 die and 60 % placement density, and **passes the TT precheck
and a gate-level simulation**. Evidence: `results/tt_flow_2026-10-17/` (`tt2/` = first TT-config run that fails the precheck,
`tt5/` = final run). Stage-by-stage images: [`results/tt_flow_2026-10-17/images/index.html`](../results/tt_flow_2026-10-17/images/index.html)
(or `README.md` there).

## 1. Result (run tt5)

| | Result |
|---|---|
| Die | **1289.28 x 710.64 um = 916,214 um^2** (TT tile size table for 6x4, `tt-support-tools/tech/ihp-sg13cmos5l/tile_sizes.yaml`), core 902,417 um^2 |
| Contents | 7,829 standard cells = 136,824 um^2, 2 SRAM macros = 98,977 um^2: **235,801 um^2 = 25.7 % of the die** |
| Clock | 20 ns (50 MHz), TT default; skew 0.42 ns |
| Setup slack | **+8.04 ns** worst (slow corner 1.08 V / 125 C), 0 violations |
| Hold slack | **+0.107 ns** worst (fast corner), 0 violations |
| Routing | **0 DRC errors**, 0 antenna violations, routing capped at Metal4 (TT setting) |
| LVS (Netgen) | **0 errors** ("Circuits match uniquely") including the SRAM power pins |
| TT precheck (`tt-support-tools`, `ihp-sg13cmos5l`) | **passed**: KLayout SG13CMOS5L foundry DRC, zero-area, forbidden layers, layer list, pin check against the 6x4 template DEF, boundary, cell names |
| Gate-level simulation | the 2 cocotb tests (`test/test.py`) pass on the routed netlist with TT's Icarus 13.0 |
| Power (liberty-based) | 4.1 mW |

## 2. What changed compared with the earlier plain-LibreLane run

- **Die area**: the real 6x4 die is 916k um^2, not the 720k um^2 assumed in [LIBRELANE_RESULTS.md](LIBRELANE_RESULTS.md).
  Utilization is therefore lower than reported there (25.7 % cells + macros).
- **Template**: there is a public CMOS5L template (`TinyTapeout/ttihp-verilog-template`, branch `cmos5l`; flow in `tt-support-tools`,
  branch `ihp-sg13cmos5l`). The repo now has its layout: `info.yaml` (6x4), `src/config.json`, `docs/info.md`, `test/` (cocotb),
  `.github/workflows/`, `LICENSE`, `macro/` (the SRAM LEF/GDS/lib/CDL files, so the repo is self-contained).
- **Power grid**: the SG13G2 example's `pdn_cfg.tcl` does not work on CMOS5L (PDN-0003: the PDK's vertical layer is Metal4, so its
  Metal4-to-Metal4 connect rule is illegal), and my earlier run used TopMetal1 stripes. **The TT precheck forbids drawn TopMetal1**
  (forbidden layer, pin layer and layer checks fail; see `tt2/precheck_result.txt`). The final grid is Metal1 rails plus **Metal4-only**
  stripes. The SRAM has its power pins on Metal4 and a Metal1-4 obstruction over its whole area, so its power can only come from
  Metal4 stripes that overlap its own power columns.
- **Density 60 %** (TT default) routes clean here; the earlier 50 % setting is no longer needed.

## 3. How the SRAM is powered without TopMetal1

1. The macro's power columns are 2.81 um wide on an 11.24 um pitch, alternating VDD!/VSS! (centre distance 5.62 um). The two halves
   of each array are 0.67 um off each other's grid, with an irregular band in the middle.
2. [`src/pdn_cfg.tcl`](../src/pdn_cfg.tcl) builds only the standard-cell grid (no macro grid). [`src/config.json`](../src/config.json)
   sets the stripe pitch to 4 x 11.24 = 44.96 um, width 2.1 um, pair spacing 3.52 um, and the offset from the macro x position (60 um)
   plus a 0.335 um compromise shift, so every stripe over either array sits inside a column of the right net (slack +-0.355 um). I checked
   every stripe against the macro GDS: no overlap with foreign Metal4 (the middle band has two floating VPWR stripes and two connected VGND ones).
3. pdngen still cuts each stripe 0.5 um short of the macro, so [`librelane/odb_bridge_macro_stripes.py`](../librelane/odb_bridge_macro_stripes.py)
   (LibreLane step `Project.BridgeMacroStripes`, [`librelane_plugin_bridge_stripes.py`](../librelane/librelane_plugin_bridge_stripes.py),
   inserted after `OpenROAD.GeneratePDN`) bridges the gap with a same-net Metal4 shape and replaces the per-segment pin boxes by one
   full-height pin per stripe (the precheck wants every power port to reach both die edges).
4. LibreLane's PSM check does not count same-layer stripe/pin overlap as a connection, so it reports the macro pins as unconnected
   (`ERROR_ON_PDN_VIOLATIONS` is off, the IR-drop report is off). **LVS is the real check, and it passes.**
5. Netgen writes the SRAM pin names (`VDD!`, `VSS!`, `VDDARRAY!`) with an invalid JSON escape and LibreLane crashes;
   [`librelane/librelane_plugin_netgen_json.py`](../librelane/librelane_plugin_netgen_json.py) repairs it.
6. Magic flags the deliberate stripe/pin overlap as "illegal overlap" (224 findings); `ERROR_ON_ILLEGAL_OVERLAPS` is off (the IHP chip
   template disables that checker too).

The approach was learned from a competitor's public repo (`WilliamZhang20/protocol-emulator`, branch `cmos5l`), which solves the same problem
with a custom stripe-rewriting step; the code here is my own implementation for the 256x32 macro.

## 4. Still open (read before relying on this)

- **Magic DRC reports 116,602 errors**, as in the earlier run; they come from the SRAM macros' own layout (the example project sets
  `ERROR_ON_MAGIC_DRC: false` for this reason). The foundry KLayout deck, run by the precheck, passes. I did not re-attribute
  the 116k errors by coordinates for tt5.
- **No IR-drop number.** Only 4 columns per net per array carry stripes; the rest of the macro's mesh is assumed to share current
  internally. Ask TT/IHP whether that is acceptable for the 256x32 macro (only the 1024x8 macro has been proven in silicon, on SG13G2).
- **Max slew 72, max capacitance 15, max fanout 76 violations** are not repaired (STA paths are fine).
- **A9 (SRAM acceptance on the CMOS5L shuttle)** is not answered by the tools: the macro passes the TT precheck and LVS, but the
  shuttle organizers have not confirmed it. TT's memory page says the SG13G2 macros can only be used in shuttles IHP manufactures.
- The GitHub workflows (`gds`, `precheck`, `gl_test`, `docs`) have not run: the repo has not been pushed since the template was added.
  I reproduced their steps locally. `tt_tool.py` was not used (its Python dependencies are not installed); `librelane/run_tt_wsl.sh`
  writes the same `user_config.json`/merged config.
- The cocotb tests are a 2-test smoke suite. The full self-checking suite is still in `tb/` (`run_tests.ps1`) and runs on RTL only.
- The standard-cell part clusters in one corner (placement density 60 %), so the die has a lot of free area: a larger memory
  or more logic would fit.

## 5. Reproduce

WSL2 Ubuntu with Nix and LibreLane `dev` (3.1.0.dev3), `~/IHP-Open-PDK` (`dev` branch), `~/tt-support-tools` (branch `ihp-sg13cmos5l`):

```
wsl -d Ubuntu -- bash -lc 'RUN_TAG=tt5 bash /mnt/c/Data/protocol_emulator/librelane/run_tt_wsl.sh'      # about 35 min, mostly Magic DRC
wsl -d Ubuntu -- bash -lc 'bash /mnt/c/Data/protocol_emulator/librelane/collect_tt_wsl.sh tt5'              # metrics into results/
# images: klayout -b -r librelane/render_stages.py -rd run=... -rd out=... -rd pdk=... -rd macro_lef=...
# precheck: PDK_ROOT=~/IHP-Open-PDK PDK=ihp-sg13cmos5l python tt/precheck/precheck.py --gds runs/tt5/final/gds/tt_um_protocol_emulator.gds
# gate level: copy runs/tt5/final/nl/*.nl.v to test/gate_level_netlist.v, then `make -B GATES=yes` in test/ with Icarus 13.0
```

`PDN_VOFFSET` in `src/config.json` is derived from the macro x position (60 um) and the core left edge (2.88 um); change one and
recompute the other (the generator logic is in the comment block of `src/pdn_cfg.tcl`).

## tt14b: the three-column 8x4 floorplan (2026-10-19)

The 6x4 die no longer routes the current RTL (tt14a, GRT-0228). On 8x4 (die 1724.16 x 710.64 um, core 2.9..1721.3 x 3.8..706.9 um) the engines get their own columns:
engine 0 x 20..583 um, common logic 640..1155, engine 1 1212..1663, SRAMs at x = 149.92 and 1228.96 (whole stripe pitches of 44.96 um), y = 13.78, flipped (FS).
Run `bash librelane/flow_variant_wsl.sh <tag> tri` (overrides in `librelane/floorplan_tri_cfg.json`); the same settings are now the default in `src/config.json` and `info.yaml`.

Result: global routing demand 198,509 tracks (32 %), no overflow; detailed routing reached 0 violations; LVS circuits match uniquely; slow-corner setup +1.69 ns at 20 ns,
hold +0.10 ns, no violations in the three corners; 92,012 instances incl. fillers, 24,867 std cells (356k um2); 9.3 mW. Tiny Tapeout precheck passes (needs `info.yaml` at 8x4
in the work folder: the pin check compares the layout with the template of the tiles named there).
Routing uses Metal2-Metal4 only (`RT_MIN_LAYER` Metal2, `RT_MAX_LAYER` Metal4): Metal1 holds the cell wiring and the power rails, and the SRAMs block Metal1-4 over their whole area.

Running several flows: each flow is one `openroad` process (one core); two together fit the 7.8 GB WSL VM. The WSL VM stops when it is idle and kills its jobs: keep a WSL window open.
