# LibreLane run (Nix shell in WSL): first RTL-to-layout result with the 256-word memory

2026-10-17. First physical-design run of `tt_um_protocol_emulator` (two engines, one 1P 256x32 SRAM macro each, 8-bit PC;
[BIGMEM_RESULTS.md](BIGMEM_RESULTS.md)) through LibreLane on the IHP **sg13cmos5l** PDK. Evidence: `results/librelane_2026-10-17/`
(`run1`, `run3`: metrics, resolved config, routing DRC, STA summary, Magic DRC summary).

## 1. Result (run3, the clean one)

| | Result |
|---|---|
| Flow | Classic flow, 72 steps, **"Flow complete"** (about 28 min on 16 cores; the Magic DRC step alone is about 18 min) |
| Die | 1200 x 600 um = 720,000 um^2 (my assumption for the 6x4-tile area, see section 4) |
| Standard cells | **134,364 um^2**, 7,585 cells, 23.4 % of the core in stdcell utilization |
| SRAM macros | 2 x 49,488 = **98,977 um^2** |
| Cells + macros | **233,341 um^2 = 32.4 % of the die** (incl. 29.0k um^2 of timing-repair buffers, of which 1,608 are hold buffers, and 4.0k of clock tree) |
| Setup slack, 20 ns clock (50 MHz) | **+7.86 ns** worst (slow corner 1.08 V / 125 C); +11.28 typ; +13.24 fast. 0 violations |
| Hold slack | **+0.088 ns** worst (fast corner), 0 violations |
| Routing | **0 DRC violations** after detailed routing, 0 antenna violations |
| LVS (Netgen) | **0 differences** (devices, nets, pins) |
| IR drop | 0.36 mV worst |
| Power (liberty-based, typ) | 4.1 mW total |
| Clock | CTS done, worst skew 0.46 ns |
| Lint | 0 errors |

Compared with the earlier Yosys-only estimate (150k + ~38k for the larger memory = ~188k): the placed result is 233k because
it includes what Yosys does not: timing-repair and hold buffers (29.0k), the clock tree (4.0k), antenna and tap cells.

## 2. What does not pass

- **Magic DRC: 116,612 errors, all inside the two SRAM macros** (0 outside, checked by coordinates:
  `run3/magic_drc_summary.txt`). Metal2 minimum area (61,440) and overlapping layers (52,190) dominate. This is the macro's
  own layout under Magic's rules; the silicon-proven SRAM example (`ttihp-sram-test`) sets `ERROR_ON_MAGIC_DRC: false` for the same
  reason, and so do I. KLayout DRC is disabled (as in that example), so there is **no DRC verdict from the foundry
  deck** yet.
- **Max slew 78, max capacitance 30, max fanout 81 violations** (slow corner worst for slew). Not repaired; no clock or data path
  fails because of them in STA. They need a decision (tighter repair or relaxed limits) before sign-off.
- Run1 (before changing the placement density from 60 % to 50 %) ended with **2 routing shorts** on TopMetal1 (a signal net against
  the power stripes). Capping signal routing at Metal4 (run2) made it worse (300+ violations, abandoned); a lower placement density (run3)
  routed clean. So the clean result is sensitive to tool settings, not a robust margin.

## 3. How it was run

- **WSL2 Ubuntu 26.04**, Nix 2.35 (multi-user, flakes, `nix-cache.fossi-foundation.org` substituter), installed with `wsl -u root`.
- **LibreLane `dev` branch** (3.1.0.dev3, `~/librelane-dev`, full clone: its flake needs history). LibreLane `main` (3.0.16) cannot read the
  CMOS5L PDK (`Required PDK variable 'LIB'`); the IHP template says the same.
- **PDK**: `IHP-Open-PDK` branch `dev` (`~/IHP-Open-PDK`, commit `89d42ee`), `--manual-pdk --pdk ihp-sg13cmos5l`. Ciel does not know this family.
- Files in the repo: `librelane/config.json` (design, 50 MHz clock, macros, placement), `librelane/macro/RM_IHPSG13_1P_256x32_c2_bm_bist.v`
  (blackbox for Yosys), `librelane/run_wsl.sh` (copies `src/` and `librelane/` to the WSL disk and runs the flow in `nix-shell --pure`),
  `librelane/collect_wsl.sh`, `librelane/magic_drc_summary.py`.
- Run: `wsl -d Ubuntu -- bash -lc 'RUN_TAG=run3 bash /mnt/c/Data/protocol_emulator/librelane/run_wsl.sh'` (login shell, or `nix-shell` is not on PATH).

Config choices that matter: `VERILOG_DEFINES: ["SYNTHESIS"]` (the simulation-only `peek/poke` helpers in `instr_mem.v` fail Verilator lint
against the blackbox otherwise); macros at (60,60) and (60,260), orientation N, power connected with `PDN_MACRO_CONNECTIONS` to `VDD!/VDDARRAY!/VSS!`;
the PDK's own PDN (Metal4 vertical, TopMetal1 horizontal) with no custom `PDN_CFG` (the SG13G2 example's script connects Metal4 to Metal4 here and
fails with PDN-0003); `PL_TARGET_DENSITY_PCT` 50; `DESIGN_REPAIR_BUFFER_OUTPUT_PORTS` off; `RUN_KLAYOUT_XOR/DRC` off.

> **Superseded 2026-10-18 by [TT_FLOW_RESULTS.md](TT_FLOW_RESULTS.md).** The caveats below ("not the Tiny Tapeout flow", "no public CMOS5L
> template", die assumed 1200 x 600 um) no longer hold: a public CMOS5L template exists, the real 6x4 die is 1289.28 x 710.64 um, and this
> run's TopMetal1 power grid fails the TT precheck (TopMetal1 is forbidden), so the final design uses a Metal4-only grid.

## 4. Caveats: what this run is not

- **Not the Tiny Tapeout flow.** There is no public CMOS5L Tiny Tapeout template; this is the plain LibreLane flow with my own die size
  (1200 x 600, chosen to equal the 720k nominal area), automatic pin placement, no pad frame, no TT power-pin and pin-template rules. A real
  submission needs those from the organizers' template.
- **Macro placement is a first guess** (two fixed positions); no halos, no analysis of the macro-to-`next_pc` path beyond what STA reports (+7.86 ns slack
  at 20 ns, so that path is not critical).
- **CMOS5L acceptance of the SG13G2 SRAM macro is still unconfirmed** (open item A9); the PDK only links to the SG13G2 macros.
- The routing result depends on settings (section 2). Fill, GDS, KLayout-render and LEF outputs exist in the WSL run directory
  (`~/pe_run/librelane/runs/run3/final`, 8 MB GDS) and were not copied into the repo.
- Gate-level simulation of the routed netlist was not run.
