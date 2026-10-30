# Reproducing every result of this project

Everything a third person needs to repeat our results is in this folder or in the scripts it calls; nothing depends on a file that is only on one machine
(see "What is not exactly reproducible" at the end for the honest list of exceptions). All scripts are plain bash / Python, take paths relative to the repository
and print what they do. Reference machine: Ubuntu 22.04.5, x86-64, 16 cores, 15 GB RAM, 100 GB free disk (the Nix store alone is 10 GB, the PDK 1.3 GB).
Run every command from the repository root, in order. `versions.txt` lists every tool version used.

## 0. Get the code
```bash
git clone <this repository> protocol_emulator && cd protocol_emulator
```

## 1. Install the tools (about 1 hour, mostly downloads)
```bash
bash reproduce/01_install_tools.sh
```
Installs Nix, then Icarus Verilog 13.0, Python 3.12, SymbiYosys 0.69, Yices 2.7.0, Boolector 3.2.4, KLayout 0.30.12 and GTKWave 3.3.128 (Nix profile), LibreLane 3.1.0.dev3
(commit ca6adb1, its own Nix shell with Yosys 0.66 and OpenROAD), the IHP-Open-PDK revision 2bbec755 (`~/pdk_tt`), tt-support-tools (commit d66cf179, `~/tt-support-tools`) and two
Python venvs (`~/ttvenv`, `~/pictvenv`) with pinned packages. If the script stops after the Nix step, open a new terminal and run `bash reproduce/01_install_tools.sh profile librelane pdk tt venvs check`.
`reproduce/versions.txt` lists the versions we used; the last step prints the versions it found.

## 2. Get the shared-memory chip source
```bash
bash reproduce/02_sources.sh
```
The shared 512-word memory, the logic analyser and their software are on the branch `shared/on-v2` (commit in `reproduce/SHARED_COMMIT`), which is not on `main`. The script makes it a
working tree in `~/pe_shared_v2`, from this repository or from `reproduce/branches.bundle`.

## 3. Simulation tests (1 to 2 hours each)
```bash
bash reproduce/03_tests.sh main       # the base design on main: 47 suites
bash reproduce/03_tests.sh shared     # the shared-memory chip with the logic analyser: phases A to F
```
Each prints one `PASS` / `FAIL` line per suite and writes `results/regression_repro_<name>/summary.md` with one log per suite. Expected: every line PASS. What the suites check
(peer models written from the protocol specifications, a cycle-exact instruction-set model with differential tests, planted-bug mutants, chip tests through the SPI link) is in
`docs/TEST_RESULTS.md`; each suite's command is listed in `host/regress.py`. A single suite: `python3 host/<name>.py` (for example `python3 host/isa_diff_test.py run`).

## 4. Formal proofs
```bash
bash reproduce/04_formal.sh main      # 4 proofs, then every planted bug must be caught
bash reproduce/04_formal.sh shared    # 6 proofs (adds the shared-memory proofs)
```
Expected: `PASS <proof>` for every proof, `caught` for every mutant.

## 5. A physical-design run
The archived runs are `sh4 sh5a sh5b sh5c sh6 sh7 sh8 sh9a sh9b` (table: `reproduce/flows/README.md`; each folder holds that run's RTL, complete configuration and final metrics).
```bash
bash reproduce/05_run_flow.sh sh8                     # 1.5 to 3 hours; log ~/flow_sh8.log, results ~/pe_sh8/runs/sh8/final/
NEWTAG=sh8r bash reproduce/05_run_flow.sh sh8         # same, under another name (does not touch an existing run)
```
At the end it prints `config: N/N keys identical`, `metrics: 190/190 identical` and `RESULT compare_flow: IDENTICAL` (or lists every metric that differs, with the relative difference).
Then the Tiny Tapeout precheck and the pictures (stage-by-stage images, module maps, gallery):
```bash
bash reproduce/06_precheck_and_reports.sh sh8
```
tt14b (8x4 tiles, private macros, the layout before the shared memory): `bash reproduce/05b_run_historic_flow.sh`.

### What the check on this folder showed
The run sh8 was started again from `reproduce/flows/sh8/` alone (`NEWTAG=sh8r`, 2026-10-20). It was stopped during global placement (step 30 of 72) because the first 29 steps already
matched: **the cumulative metrics (cell counts, areas, wire estimates, timing) after every one of those 29 steps are identical to the original run**, including synthesis, floorplan, power
grid and macro placement. The flow is deterministic for the same inputs and tool versions, so the rest is expected to match; the end-to-end comparison above was not run for the full rerun.

## 6. Documents
```bash
bash reproduce/07_docs.sh        # user guide pictures (docs/images) and docs/USER_GUIDE.html
```

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
* **Determinism of the flow:** the check is `compare_flow.py`; a partial rerun of sh8 matched the original in all 29 completed steps (section 5 above). The record is in
  `memory.md` (entry "reproduce/ folder check") and below.
* **FPGA results** (UART on a DE0-Nano, `src/fpga/`, `quartus/`) need the board and Quartus; not reproducible by script.
* **Web-only material** in the user guide (the Raspberry Pi Pico pinout image, `docs/images/third_party/`) is a download with its licence in `ATTRIBUTION.md`; links in Appendix G of the guide marked "to check" were not all verified.
