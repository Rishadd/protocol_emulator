# How to reproduce our results, step by step

Read this top to bottom on a fresh Ubuntu 22.04 (x86-64, 16 GB RAM, 100 GB disk). [README.md](README.md) is the index of this folder; this file is the walkthrough.
Every command is run from the repository root. Nothing needs a file that is not in the repository.

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

## What cannot be reproduced exactly (full list in README.md)
Flow runs before 2026-10-18 23:10 (tt2 to tt12a: tool state of that day is not stored), GitHub Actions jobs (they run the same tools remotely), FPGA runs (need the board).
