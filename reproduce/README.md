# Reproducing every result of this project

See [HOW_TO_REPRODUCE.md](HOW_TO_REPRODUCE.md) for the step-by-step walkthrough.

Everything a third person needs to repeat our results is in this folder or in the scripts it calls; nothing depends on a file that is only on one machine
(see "What is not exactly reproducible" at the end for the honest list of exceptions). All scripts are plain bash / Python, take paths relative to the repository
and print what they do. Reference machine: Ubuntu 22.04.5, x86-64, 16 cores, 15 GB RAM, 100 GB free disk (the Nix store alone is 10 GB, the PDK 1.3 GB).

## Quick start

```bash
git clone <this repository> && cd protocol_emulator
bash reproduce/01_install_tools.sh          # Nix, Icarus Verilog 13, SymbiYosys + Yices + Boolector, LibreLane 3.1.0.dev3, IHP PDK 2bbec755, tt-support-tools
bash reproduce/02_sources.sh                # the shared-memory chip (branch shared/on-v2) as a second working tree (~/pe_shared_v2)
bash reproduce/03_tests.sh main             # 1. simulation regression of the verified base (main)
bash reproduce/03_tests.sh shared           #    ... and of the shared-memory chip with the logic analyser
bash reproduce/04_formal.sh main            # 2. formal proofs and their planted-bug runs
bash reproduce/04_formal.sh shared
bash reproduce/05_run_flow.sh sh8           # 3. a physical-design run (1.5 to 3 hours); sh4 ... sh9b are archived
bash reproduce/06_precheck_and_reports.sh sh8   # 4. Tiny Tapeout precheck, pictures
bash reproduce/07_docs.sh                   # 5. user guide pictures and HTML
```

`reproduce/versions.txt` lists every tool version; `01_install_tools.sh check` prints the versions found so they can be compared.

## What each script produces, and where the recorded result is

| Step | Command | Expected | Recorded in |
|---|---|---|---|
| Tool install | `01_install_tools.sh` | versions as in `versions.txt` | `memory.md` entry 2026-10-20 "native Ubuntu set up" |
| Simulation regression, main | `03_tests.sh main` (host/regress.py phases A-D) | every suite PASS (47 of 47 on Ubuntu) | `results/regression_2026-10-20e/summary.md`, `docs/TEST_RESULTS.md` |
| Simulation regression, shared-memory chip | `03_tests.sh shared` (phases A-F: + shared-memory chip suites E, frame v2 / shared-memory software / logic analyser F) | every suite PASS | `results/regression_2026-10-20_shared/`, `docs/TEST_RESULTS.md` |
| Formal proofs | `04_formal.sh main` / `shared` | 4 (main) / 6 (shared) proofs PASS; every planted bug caught (34 main, +13 shared) | `formal/README.md`, `docs/TEST_RESULTS.md` |
| Flow runs sh4 ... sh9b | `05_run_flow.sh <tag>` | the new run's configuration and all 190 metrics identical to `flows/<tag>/expected_metrics.json` (`RESULT compare_flow: IDENTICAL`) | `flows/README.md` (table), `results/shared_2026-10-20/`, `results/tt_flow_2026-10-20/sh4_final/` |
| Flow run tt14b (8x4, private macros) | `05b_run_historic_flow.sh` | compared with `results/tt_flow_2026-10-19/tt14b_final/metrics.json` | `docs/TEST_RESULTS.md` section 11 |
| Precheck | `06_precheck_and_reports.sh <tag>` | Tiny Tapeout precheck passes (needs the work folder's info.yaml at 8x4, which the flow scripts set up) | `~/precheck_<tag>.txt`, `results/tt_flow_2026-10-20/sh4_final/` |
| User guide | `07_docs.sh` | `docs/USER_GUIDE.html` and `docs/images/*` regenerated | `docs/USER_GUIDE.md` |

Individual tests can be run on their own; each script's first lines say how (`python3 host/<name>.py`). The suites and their commands are listed in `host/regress.py`
(lists A to F: one entry per suite, with its arguments and environment variables such as `PROTO_CHIP`, `PROTO_SHARED`, `FW_ORG`, `PROTO_REMAP`).

## The flow archive (`flows/`)

`flows/README.md` has one row per run (what changed, the configuration keys that differ, slow-corner slack, area, DRC, LVS). Every folder holds the RTL and flow
files exactly as the run used them, the complete LibreLane configuration (`config_merged.json`) and the final metrics. `05_run_flow.sh <tag>` assembles a source tree
from them, runs `librelane/run_tt_wsl.sh` (the same steps as Tiny Tapeout's `tt_tool.py --harden`, written out) in LibreLane's Nix shell and then compares.
`NEWTAG=<other> bash reproduce/05_run_flow.sh <tag>` keeps an existing run untouched. To make a new archive entry from any finished run:
`bash reproduce/tools/snapshot_flow.sh <tag> <family> [work folder]` and `python3 reproduce/tools/flow_table.py`.

The configuration files of the Tiny Tapeout flow are written by `librelane/run_tt_wsl.sh` (user config as `tt_tool.py --create-user-config` does it, project plug-in
`librelane_plugin_project/`: stripe bridge over the macros, engine fences, Netgen JSON fix). Floorplan variants are `librelane/floorplan_*_cfg.json` plus `src/floorplan_engines_*.json`
(on `main`: compact, symmetric, tri; the shared-memory variant `shared3` is on branch shared/on-v2 and inside every flow archive).

## Where the shared-memory chip's source is

`main` has the verified base design (private 256-word memories, frame v2). The shared 512-word memory, the logic analyser, TSTAMP and the shared-memory software are on the
branch `shared/on-v2` (commit recorded in `SHARED_COMMIT`); it is in this repository's `.git` and, for a fresh clone, in `branches.bundle` (every branch that is not in `main`,
made with `git bundle create reproduce/branches.bundle <branches> ^main`). `02_sources.sh` turns it into a working tree. Each flow archive also contains the exact RTL of its run.

## What is not exactly reproducible (nothing is hidden)

* **Runs before 2026-10-18 23:10** (tt2 ... tt12a, including the 6x4 layouts tt9b / tt9c and the compact experiments of `docs/TT_FLOW_RESULTS.md`) were made with LibreLane's development
  checkout (`main` of 2026-10-06, 20 commits after 3.1.0.dev3) and a local PDK checkout of 2026-10-16, not with the release and PDK revision Tiny Tapeout's GitHub action uses. That tool
  state is not stored here; their configurations are archived (`results/tt_flow_2026-10-18/<run>/config_merged.json`, `resolved.json`) and rerunning them with 3.1.0.dev3 + PDK 2bbec755 gives a close
  but different layout (about 3 % fewer cells with the older PDK, `docs/LIBRELANE_RESULTS.md`). The numbers in `docs/TT_FLOW_RESULTS.md` for those runs are the recorded ones.
* **tt14b** is rebuilt from commit e3846c3 (its floorplan commit; its merged configuration was compared with tt14b's key by key, no differences), with the release tools; the run itself was
  made with the working tree just before that commit.
* **Line endings:** the archived inputs of sh4-sh5c (and their macro files) were CRLF files copied from the Windows machine; git stores them with LF endings, so a fresh clone has LF. Verilog, JSON and Liberty/LEF text is whitespace-insensitive, so the results are expected to be the same, but only the LF-based family (sh6-sh9b, made on Linux) was rechecked by the sh8 rerun.
* **GitHub Actions results** (gds, precheck, gl_test, viewer jobs of run 39250627497) are on GitHub; the same tools run locally in `05_run_flow.sh` and `06_precheck_and_reports.sh`.
* **Determinism of the flow:** the check is `compare_flow.py`; a partial rerun of sh8 matched the original in all 29 completed steps (HOW_TO_REPRODUCE.md, section 5). The record is in
  `memory.md` (entry "reproduce/ folder check") and below.
* **FPGA results** (UART on a DE0-Nano, `src/fpga/`, `quartus/`) need the board and Quartus; not reproducible by script.
* **Web-only material** in the user guide (the Raspberry Pi Pico pinout image, `docs/images/third_party/`) is a download with its licence in `ATTRIBUTION.md`; links in Appendix G of the guide marked "to check" were not all verified.
