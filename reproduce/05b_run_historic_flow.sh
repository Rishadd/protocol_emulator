#!/bin/bash
# The flow run tt14b (8x4 tiles, private macros, three-column floorplan): its source is the repository at commit e3846c3 (the commit that made its
# floorplan the default; docs/TEST_RESULTS.md section 11 records that the merged configuration of e3846c3 equals tt14b's key by key).
#   bash reproduce/05b_run_historic_flow.sh        runs it as tag tt14br and compares with results/tt_flow_2026-10-19/tt14b_final/
# NOT exactly reproducible (said openly): the earlier runs tt2 ... tt12a (2026-10-17/18) used LibreLane's dev checkout (main of 2026-10-06, 20 commits after
# 3.1.0.dev3) and a local PDK checkout of 2026-10-16; tt9b / tt9c / tt10b of docs/TT_FLOW_RESULTS.md come from that tool state, which is not part of this
# repository, so rerunning them with 3.1.0.dev3 + PDK 2bbec755 gives a close but not identical layout (3 % fewer cells with the older PDK, see
# docs/LIBRELANE_RESULTS.md). Their configurations are archived in results/tt_flow_2026-10-18/<run>/config_merged.json and resolved.json.
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
T=${HOME}/pe_repro_src_e3846c3
[ -d "$T" ] || git -C "$R" worktree add --detach "$T" e3846c3
bash "$R/librelane/flow_variant_linux.sh" tt14br tri "$T"
python3 "$R/reproduce/tools/compare_flow.py" "$R/results/tt_flow_2026-10-19/tt14b_final" "$HOME/pe_tt14br" tt14br
