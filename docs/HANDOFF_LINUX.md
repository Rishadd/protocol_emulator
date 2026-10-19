# Handoff: continue on native Ubuntu (written 2026-10-19 evening)

Read this first in the new session. State of the project when the laptop was closed; what is verified, what is half done, what to run next.

## 1. Rules from the user (keep following them)
- Do **not** send the Tiny Tapeout email. Do **not** question the SRAM macros. 8x4 tiles are allowed (and now used).
- Keep `memory.md` and the docs updated. Run independent work in parallel. RTL/ISA changes are fine when the gain is significant.
- Deadline: **chip ready by 2026-12-30** (RTL freeze Dec 13, final flow runs with Tiny Tapeout's tools Dec 14-27); January is documentation only. Challenge deadline 2027-01-18.
- Run each flow / long process in **its own visible terminal window**, with the live log in that window. Do not push without the user's go-ahead.
- Commit trailer: end commit messages with `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>` (or whatever the session's attribution reminder says). Commit identity: `git -c user.name="Rishadd Ranjith" -c user.email=you@example.com commit ...`. The user's own `LICENSE` edit stays uncommitted.

## 2. Repository state (everything is committed; nothing was pushed after `8795248`)
| Tree / branch | Contents |
|---|---|
| `main` (`C:\Data\protocol_emulator`) | pin mapping, SPI host, line coder, USB device, WS2812 / PS/2 / SWD, **8x4 three-column floorplan** (info.yaml, src/config.json), docs. GitHub `main` is at `8795248`; local is 3+ commits ahead (docs, isa_diff_test fix `053fdbd`) |
| `feat/frame-v2` (`C:\Data\protocol_emulator_v2`) | management frame v2 (CRC-16, sequence numbers), commit `f234342`. **Fully verified**: 22/22 unit tb, mgmt_v2_test 236/236 on the chip RTL, 20/20 RTL mutants, formal 4/4 proofs + 39/39 mutants |
| `merge/frame-v2` (`C:\Data\pe_merge`) | `main` + frame v2, clean merge, **not yet regression-tested** |
| `feat/shared-imem` (`C:\Data\protocol_emulator_shmem`) | shared 512-word memory (2P 512x32 macro, physical PC, OP_REGION window per engine, START register), flow variants `shared` / `shared3`, matched power grid; commit `3ed9d42`. Design: `docs/SHARED_IMEM_PLAN.md` on that branch |

## 3. Results to know (details in docs/TEST_RESULTS.md section 11, docs/TT_FLOW_RESULTS.md)
- **tt14b** (8x4, private macros): routes, 0 DRC, LVS clean, slow setup +1.69 ns at 20 ns, hold +0.10 ns, Tiny Tapeout **precheck passes** (with info.yaml at 8x4). Saved: `results/tt_flow_2026-10-19/tt14b_final/` (GDS, LEF, netlists, metrics), logs in `.../logs/`.
- **Formal on main**: 4/4 proofs, 34/34 mutants. **isa_diff_test** passes (0 mismatches, 33/33 mutants, coverage met with the TX-FIFO share).
- **Regression 2026-10-19c (Windows, stopped for the move)**: phase A had 19/25 passed, 0 failed: crc_test alu_test unit_testbenches isa_diff_test i2c_test spi_test i2c_slave_test smbus_test onewire_test jtag_test can_test modbus_test uart_workload uart_rx_workload chip_host_demo ws2812_test ps2_test swd_test line_coder_test . Not run yet: the rest of phase A, phases B, C, D. (Log: `build/wlogs/regress_c.log`.)
- **Shared memory**: chip-level test passes on the RTL. sh2 (L-shaped engines) congested; **sh3** (compact columns) routes (demand 32 %, DRT 0) but **LVS failed: VPWR and VGND shorted** because the 44.96 um power-stripe pitch does not match the 2P macro's power columns (4.42 um wide, 17.68 um pitch; irregular middle section x 813-886 um). Fix found by scanning (`librelane/pdn_scan.py`, `pdn_check.py` on the shared branch): **FP_PDN_VPITCH 53.04, FP_PDN_VSPACING 6.74, FP_PDN_VOFFSET 18.545** in `librelane/floorplan_shared3_cfg.json`; a quick run showed 0 wrong-net overlaps (25 stripe segments on right-net bars). The full run **sh4** with this grid was stopped about 20 min in: rerun it.
- **GitHub**: `test`, `docs` pass for `8795248`; **`gds` was still building** (run 39250627497, https://github.com/Rishadd/protocol_emulator/actions/runs/39250627497, started 2026-10-19 12:15 UTC; earlier comparable run took 3 h 24 min). Check it first. The `viewer` job needs GitHub Pages set to "GitHub Actions" (the user was shown how; not confirmed). The anonymous API is rate limited: read run pages / badges instead.

## 4. What to do, in order
1. Check the GitHub `gds` / `precheck` / `gl_test` result (above). If `gds` failed, read the log; the local tt14b run predicts success.
2. **Set up native Ubuntu** (see section 5), then `find build -name "*.vvp" -delete` in every tree (compiled simulator files from another Icarus do not run).
3. Run the **full regression on `merge/frame-v2`** (`python3 host/regress.py --out results/regression_2026-10-20 --jobs 6`; Linux can use many more jobs). If green, fast-forward `main` to `merge/frame-v2`, update docs, ask the user, push (starts the workflows).
4. Rerun **sh4** (shared memory, matched grid): `PE=<path of the shmem tree> bash librelane/flow_variant_wsl.sh sh4 shared3`; expect LVS to pass; then run the precheck on it (`librelane/precheck_wsl.sh sh4`, info.yaml must say 8x4 in the work folder). Pictures: `librelane/live_images_shared_wsl.sh`. If it passes: decide with the user whether the shared memory goes into the design (area +52k um2 for 512 words; benefits in docs/SHARED_IMEM_PLAN.md).
5. Shared-memory software still missing: RTL-vs-model differential test in shared mode, formal proofs (fetch stays in the window; host writes never change a running window; lock holds until RUN falls), the `REGION` read at ENG_BASE+0x008, instruction readback.
6. Then the plan in docs/EXECUTION_PLAN.md: logic analyser (third SRAM), sniffer, engine debug, memory self-test, mutation campaign + timing checker, FPGA demos, RTL freeze Dec 13.

## 5. Setting up native Ubuntu (what the WSL install had)
- Nix (multi-user), then LibreLane release: `librelane/install_tt_librelane_wsl.sh` (creates `~/librelane-3.1.0.dev3`, used as `LLDIR`); Tiny Tapeout's PDK revision: `librelane/install_tt_pdk_wsl.sh` (`~/pdk_tt`); `~/tt-support-tools` (branch `ihp-sg13cmos5l`); a Python venv `~/ttvenv` for the precheck and module maps; Icarus Verilog 13; Python 3.12; klayout comes with the Nix shell.
- The scripts in `librelane/` hard-code `/mnt/c/Data/protocol_emulator` and `/home/rishadd`: change `P`, `SRC`, `PE`, `WORK` (env overrides exist: `SRC`, `PE`, `WORK`, `TT_PDK_ROOT`, `LLDIR`) or symlink the repo to that path. Shell scripts must have LF line endings.
- The old WSL home (`ext4.vhdx`) is not readable from Linux: everything needed from it was copied into `results/tt_flow_2026-10-19/`.

## 6. Gotchas learned
- Compiled `build/**/*.vvp` from WSL's Icarus fail on Windows (and the reverse): clean `build/` when switching.
- The precheck compares the layout with the template of the tiles named in the work folder's `info.yaml`.
- GRT congestion decides everything on this die: keep each engine in a compact column (the L-shaped shared layout needed 54 % routing demand, the compact one 32 %).
- A `?:` on an unknown signal spreads X forever in a 4-state simulation: use if/else.
- The flows stop when the WSL VM stops; native Linux does not have that problem.
