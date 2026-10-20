#!/bin/bash
# Linux version of flow_variant_wsl.sh + flow_run_wsl.sh + run_tt_wsl.sh in one: a full TT-flow run with a floorplan variant.
# Usage: bash librelane/flow_variant_linux.sh <tag> <variant: compact | symmetric | shared3> [tree: default = this repo] [extra JSON merged on top]
# Example (shared memory, matched power grid): bash librelane/flow_variant_linux.sh sh4 shared3 /media/rishadd/OS/Data/protocol_emulator_shmem
# Work folder: $HOME/pe_<tag>, log: $HOME/flow_<tag>.log, exit status appended to the log as "exit code N".
# LibreLane: ~/librelane-3.1.0.dev3 (the release the Tiny Tapeout action uses), PDK: ~/pdk_tt, tools: ~/tt-support-tools.
set -uo pipefail
TAG=$1; V=$2
PE=${3:-$(cd "$(dirname "$0")/.." && pwd)}
MORE=${4:-'{}'}
export LLDIR=${LLDIR:-$HOME/librelane-3.1.0.dev3}
export TT_PDK_ROOT=${TT_PDK_ROOT:-$HOME/pdk_tt}
export RUN_TAG=$TAG
export SRC=$PE
export WORK=$HOME/pe_$TAG

# the variant file holds TILES and the per-variant settings; TILES also selects the die and the DEF template
export TILES=$(python3 -c "import json; print(json.load(open('$PE/librelane/floorplan_${V}_cfg.json')).get('TILES',''))")
CFG_EXTRA=$(python3 -c "import json,sys; a=json.load(open('$PE/librelane/floorplan_${V}_cfg.json')); a.pop('TILES', None); a.update(json.loads(sys.argv[1])); print(json.dumps(a))" "$MORE")

# same as flow_run_wsl.sh with boxes: module boxes from src/floorplan_engines_<variant>.json, magic DRC skipped
export EXTRA_CFG=$(python3 -c "import json,sys; a=json.loads(sys.argv[1]); a.update(json.loads(sys.argv[2])); print(json.dumps(a))" \
  "{\"MODULE_BOXES\": \"dir::floorplan_engines_${V}.json\", \"RUN_MAGIC_DRC\": false}" "$CFG_EXTRA")

{
  echo "start $(date -Is) tag=$TAG variant=$V tree=$PE TILES=$TILES"
  bash "$(dirname "$0")/run_tt_wsl.sh" ${TO:+--to $TO}
  echo "exit code $?"
} 2>&1 | tee "$HOME/flow_$TAG.log"
