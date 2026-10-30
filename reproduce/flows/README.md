# Archived flow runs (sh4 to sh9b)

Each folder holds the exact inputs of one run (`src/`, `info.yaml`, the complete `config_merged.json`, `family.txt`) and its final metrics. Macros and the project plug-in
shared by a family of runs are in `_common_shmem/` (sh4-sh5c) and `_common_shared_v2/` (sh6-sh9b). Run one again with `bash reproduce/05_run_flow.sh <tag>`; the
script compares the new configuration and all 190 metrics with these files (`reproduce/tools/compare_flow.py`).

Slow corner = 1.08 V, 125 C. Achieved period = constraint minus worst setup slack. All runs: 8x4 tiles, Tiny Tapeout flow (LibreLane 3.1.0.dev3, PDK 2bbec755).

| run | what is different | config keys that differ from sh4 | slow setup slack (ns) | achieved period (ns) | std-cell area (um2) | route DRC | LVS errors | wire length (um) |
|---|---|---|---|---|---|---|---|---|
| `sh4` | baseline: shared 512-word memory (2P macro), matched power grid 53.04 / 6.74 / 18.545, 8x4 tiles, constraint 20 ns | - | -1.45 | 21.45 (46.6 MHz) | 368k | 0 | 0 | 1415k |
| `sh5a` | constraint 17 ns + placement resizer setup margin 0.5 | CLOCK_PERIOD=17, PL_RESIZER_SETUP_SLACK_MARGIN=0.5 | -2.50 | 19.50 (51.3 MHz) | 368k | 0 | 0 | 1404k |
| `sh5b` | constraint 18 ns + repair after global routing (RUN_POST_GRT_RESIZER_TIMING) | RUN_POST_GRT_RESIZER_TIMING=true, CLOCK_PERIOD=18, GRT_RESIZER_SETUP_SLACK_MARGIN=0.3 | -1.98 | 19.98 (50.1 MHz) | 395k | 0 | 0 | 1430k |
| `sh5c` | delay-oriented synthesis (SYNTH_STRATEGY DELAY) | SYNTH_STRATEGY="DELAY 1", CLOCK_PERIOD=18, SYNTH_SIZING=true, SYNTH_ABC_BUFFERING=true | -4.43 | 22.43 (44.6 MHz) | 404k | 0 | 0 | 1926k |
| `sh6` | trap gate moved from imem_shared into the engines (RTL change), otherwise as sh4 | - | -0.41 | 20.41 (49.0 MHz) | 368k | 0 | 0 | 1410k |
| `sh7` | sh6 RTL + current candidate RTL, constraint 19 ns + repair after global routing | RUN_POST_GRT_RESIZER_TIMING=true, CLOCK_PERIOD=19, GRT_RESIZER_SETUP_SLACK_MARGIN=0.3 | -1.29 | 20.29 (49.3 MHz) | 433k | 0 | 0 | 1592k |
| `sh8` | candidate RTL, constraint 17 ns + margin 0.5 (the sh5a settings) | CLOCK_PERIOD=17, PL_RESIZER_SETUP_SLACK_MARGIN=0.5 | -2.64 | 19.64 (50.9 MHz) | 402k | 0 | 0 | 1504k |
| `sh9a` | candidate RTL, constraint 20 ns (the real clock) + margin 0.5 | PL_RESIZER_SETUP_SLACK_MARGIN=0.5 | -0.45 | 20.45 (48.9 MHz) | 403k | 0 | 0 | 1532k |
| `sh9b` | candidate RTL, constraint 20 ns + margin 1.0 (result identical to sh9a in all 190 metrics) | PL_RESIZER_SETUP_SLACK_MARGIN=1.0 | -0.45 | 20.45 (48.9 MHz) | 403k | 0 | 0 | 1532k |
| `sh10` | the pushed check version: current RTL (TSTAMP, trigger line), sh8 recipe, WITHOUT the logic analyser (no LA define) | CLOCK_PERIOD=17, PL_RESIZER_SETUP_SLACK_MARGIN=0.5 | -2.71 | 19.71 (50.7 MHz) | 405k | 0 | 0 | 1517k |

Results folders with pictures: `results/shared_2026-10-20/<tag>_images/index.html`; the sh4 final files: `results/tt_flow_2026-10-20/sh4_final/`.
