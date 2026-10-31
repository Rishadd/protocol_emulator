# Handoff: continue on Windows (written 2026-10-31, from the Ubuntu session)

Read this first. The Ubuntu machine and the Windows PC share one disk: this repository is `C:\Data\protocol_emulator` on Windows and `/media/rishadd/OS/Data/protocol_emulator` on Ubuntu. Challenge deadline 2027-01-18; the user's own targets: RTL freeze 2026-12-13, chip ready 2026-12-30.

## 1. Rules from the user (keep following them)
- **No RTL changes now** (said on 2026-10-31). Test, host, firmware-generator, flow and documentation changes are fine.
- Do **not** send the Tiny Tapeout email. Do **not** question the SRAM macros. 8x4 tiles are allowed.
- Push to GitHub only when the user says so (the repository is public since 2026-10-30). Commit trailer: `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; `[skip ci]` on commits that must not start the workflows.
- Run long jobs in their own visible terminal window with the live log. Do not delete anything irreversible without asking. Report results honestly, including failures.
- The user must be able to understand all the code: [CODE_GUIDE.md](CODE_GUIDE.md) is the walk-through.

## 2. The open decision: which chip to submit
Two candidates, both pushed to GitHub on 2026-10-31 (the workflows `gds`, `precheck`, `gl_test`, `viewer` run on each; gds takes 4 to 6 hours; read https://github.com/Rishadd/protocol_emulator/actions). The repo is public, so the API works without a login: `curl https://api.github.com/repos/Rishadd/protocol_emulator/actions/runs`. Job logs need admin rights; check-run annotations do not.

| | A: `submit/sh10-50mhz` | B: `submit/8la-43mhz` |
|---|---|---|
| Design | shared 512x32 2P memory, TSTAMP, trigger, **no logic analyser** | A plus the logic analyser (second 2P macro as capture buffer) |
| Placement | fenced (`src/floorplan_engines_shared3.json`) | free cell placement, both macros pinned |
| Slow-corner period (local flow) | **19.71 ns = 50.7 MHz** (sh10) | about 22.4 ns = 44.6 MHz (8la) |
| `info.yaml` clock | 50 MHz | 43 MHz |
| Local checks | LVS clean, 0 DRC, 0 antenna | LVS clean, 0 DRC, 0 antenna |
| GitHub | an earlier run of the same recipe (branch `check/shared-sh8`) passed gds and precheck; its gl_test failed because the cocotb test targeted the old chip (fixed in commit 639663b, passes locally on the sh10 netlist) | not yet verified on GitHub |

The user has **not decided** between 50 MHz (A) and 43 MHz (B). Switching is a one-file change: `info.yaml` `clock_hz` and `src/config.json` (`CLOCK_PERIOD` stays 17, the placer target; the 43 MHz is the promise). The signed-off clock is the maximum promised clock (slow corner, 1.08 V, 125 C); a slower clock changes seconds, not behaviour ([CLOCK_SPEED_EFFECTS.md](CLOCK_SPEED_EFFECTS.md)).

## 3. Layout results of 2026-10-30 (all at the 17 ns target; achievable period = 17 - slack)
| Run | Setup | Slow slack | Failing paths | DRC | LVS |
|---|---|---|---|---|---|
| sh10 (8x4, fenced, no LA) | 19.71 ns | -2.71 | 555 | 0 | clean |
| 8n (8x4, free, no LA) | about 20.1 ns | -3.11 | 556 | 0 | clean |
| **8la (8x4, free, LA)** | about 22.4 ns | -5.37 | 817 | 0 | clean |
| 8lf (8x4, fenced, LA) | failed | -7.40 | 669 | **794** | **31 errors** |
| 6s6a (6x4, fenced, LA absent) | about 23.3 ns | -6.34 | 555 | 0 | clean |
| 6n (6x4, free, no LA) | about 22.3 ns | -5.32 | 775 | 0 | clean |
| 6s6b (6x4, fenced, other macro place) | failed in global placement (fence too small) | | | | |
- Conclusions: fences only help a little on 8x4 (about 0.4 ns); the fenced analyser layout (8lf) is worse than free placement; the 6x4 die is 2.5 to 3.5 ns slower than 8x4 and has no room for a second macro (cells 405k + macros 151k + 151k = 707k um2 of 916k). The 6x4 fallback is a slower clock (about 23 to 26 ns) without the analyser.
- The power-grid check reports 8,657 violations on every single-macro run (also the accepted sh8/sh10); it is a macro power-pin check, not a defect. 8la has 17,338 (two macros).
- Outputs: `archive/layouts_2026-10-31/<run>/` (GDS, netlist, LEF, SDC, metrics.json, resolved.json, logs, `layout_render.png`). `archive/` is git-ignored (large). Pictures of sh4 to sh10 are in `results/shared_2026-10-20/`; stage pictures for the 2026-10-30 runs were **not** generated (only the final render); regenerate with `librelane/render_stages.py` on a rerun.

## 4. State of the code (branch `main`, merged from `clean/v1`)
- Full regression on the merged code: **70 of 70 suites pass** (`results/regression_2026-10-30/summary.md`). Before the merge the baseline was 67 of 67.
- New in this round: [CODE_GUIDE.md](CODE_GUIDE.md); DE0-Nano chip top `src/fpga/de0_nano_chip_top.v` with a block-RAM stand-in `src/fpga/sram2p_fpga.v`, Quartus project `quartus/pe_chip.qpf`; `host/fpga_bringup.py`, `host/pico_bridge.py` (MicroPython), `host/serial_link.py`; `host/la_capture.py` (writes a VCD for GTKWave; `--sim --demo` passes); the logic-analyser capture buffer now uses the 2P macro (`src/la_block.v`); old floorplan files and dead files removed; firmware opcode tables de-duplicated.
- Not changed on purpose: RTL size. The readability cost is two variants (private memory vs `SHARED_IMEM`, about 35 `ifdef`s) and frame v1 plus v2 in `mgmt.v`; removing either means migrating about 13 testbenches and the hosts.
- **Not verified on hardware:** the Quartus compile and 50 MHz timing of `pe_chip`, the Pico bridge, the GPIO_0/1 pins. Only the GPIO_2 header, KEY0, the clock and the LEDs were checked against Terasic's manual. The FPGA top is verified only in simulation (`host/fpga_bringup.py --sim`).
- Logic-analyser phases 4 to 6 (engine debug, sniffers, formal and chip-level mutants) are not built; phases 1 to 3, 7 (layout, 8la) and 8 (capture tool) are done.

## 5. Ideas discussed, not started
- A host-side timing framework: one clock object (`f_clk`), helpers that turn ns, baud and bit rates into clock counts (with the instruction overheads), the firmware generators (`spi_prog`, `uart_*`, `i2c_prog`, `can_prog`, `onewire_prog`, ...) taking rates instead of raw counts, and a `+CLKNS` plusarg in the testbenches. Acceptance criterion: byte-identical programs at 50 MHz. The user said not to start yet.

## 6. Setting up on Windows
- The tool stack was originally WSL on Windows and was moved to native Ubuntu because WSL had only 7.8 GB of RAM and shut down when idle, which killed flows. Give WSL at least 16 GB (`.wslconfig`) or run the flows on Ubuntu.
- Installation scripts: `reproduce/01_install_tools.sh` to `07_docs.sh`, `librelane/install_tt_librelane_wsl.sh`, `librelane/install_tt_pdk_wsl.sh`. Versions: [reproduce/versions.txt](../reproduce/versions.txt) (LibreLane 3.1.0.dev3, IHP PDK revision 2bbec755, Icarus 13.0, Yosys 0.66; the GitHub action pins the same).
- A flow run: `bash librelane/flow_variant_linux.sh <tag> <variant> [tree] [extra JSON]`, with `PATH=$HOME/ttvenv/bin:$PATH`; variant files `librelane/floorplan_<v>_cfg.json` plus `src/floorplan_engines_<v>.json`. Variants kept: `shared3` (sh10 recipe), `s8la` (analyser, free placement: remove `MODULE_BOXES`, as `src/config.json` on branch B does).
- Simulation: `python3 host/regress.py` runs all phases (about 90 minutes).
- cocotb test (what GitHub runs): `cd test; pip install -r requirements.txt; make` (RTL) and `make GATES=yes` with `test/gate_level_netlist.v` copied from a run (needs Icarus 13 and `PDK_ROOT`).

## 7. What is where
| Place | Contents |
|---|---|
| `src/` | RTL (`tt_um_protocol_emulator.v` top), flow files `config.json`, `pnr.sdc`, `pdn_cfg.tcl`, floorplan JSON |
| `host/`, `tb/`, `formal/`, `test/` | Python hosts and generators; testbenches; formal proofs; cocotb for GitHub |
| `docs/` | CODE_GUIDE, USER_GUIDE, plans and results, this file; `memory.md` (root) is the chronological project story |
| `results/` | evidence: regression summaries, layout metrics, pictures |
| `archive/` (git-ignored) | full layout outputs of 2026-10-30; `work_configs/` floorplan and config files of the 6x4 experiments |
| `quartus/`, `src/fpga/` | DE0-Nano projects |
| `reproduce/` | scripts to rebuild everything |

## 8. Next steps in order
1. Read the GitHub results for branches A and B; if B passes gds, precheck and gl_test, B is a real option.
2. The user decides 50 or 43 MHz; set `info.yaml` and `src/config.json` on `main` to the chosen recipe, rerun the full regression (RTL and sources unchanged), and write the final numbers into `memory.md` and `docs/TODO.md` (both still lack the 2026-10-30/31 entries: this file is the only record of this round).
3. Hardware: build and test the DE0-Nano design (`docs/CODE_GUIDE.md` section on bring-up), then fix the pin and timing issues Quartus reports.
4. RTL freeze 2026-12-13, final flows on the frozen RTL 2026-12-14 to 27.
