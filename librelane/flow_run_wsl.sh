#!/bin/bash
# One complete TT-flow run in its own work directory (so several runs can go in parallel).
# Usage: bash librelane/flow_run_wsl.sh <tag> [boxed [boxes file in src/, default floorplan_boxes.json]]      boxed = also set MODULE_BOXES
# TO=<last step id> stops the run after that step (e.g. TO=OpenROAD.GlobalRouting for a quick congestion check)
# Magic DRC is skipped (it reports about 116k errors that come from the SRAM macros' own layout, see docs/TT_FLOW_RESULTS.md;
# the foundry KLayout DRC of the TT precheck is the real check and is run on the final GDS).
TAG=$1
export RUN_TAG=$TAG
export WORK=$HOME/pe_$TAG
if [ "$2" = "boxed" ]; then
  export EXTRA_CFG="{\"MODULE_BOXES\": \"dir::${3:-floorplan_boxes.json}\", \"RUN_MAGIC_DRC\": false}"
else
  export EXTRA_CFG='{"RUN_MAGIC_DRC": false}'
fi
# CFG_EXTRA='{"PL_RESIZER_HOLD_SLACK_MARGIN": 0.3}' merges more settings into the run configuration
if [ -n "$CFG_EXTRA" ]; then EXTRA_CFG=$(python3 -c "import json,os; a=json.loads(os.environ['EXTRA_CFG']); a.update(json.loads(os.environ['CFG_EXTRA'])); print(json.dumps(a))"); export EXTRA_CFG; fi
bash ${PE:-/mnt/c/Data/protocol_emulator}/librelane/run_tt_wsl.sh ${TO:+--to $TO} > $HOME/flow_$TAG.log 2>&1
echo "exit code $?" >> $HOME/flow_$TAG.log
