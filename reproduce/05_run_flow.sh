#!/bin/bash
# Run one archived flow again, from this repository alone, and compare the result with the archived metrics.
#   bash reproduce/05_run_flow.sh <tag>            tags: sh4 sh5a sh5b sh5c sh6 sh7 sh8 sh9a sh9b   (reproduce/flows/<tag>/)
#   NEWTAG=sh8r bash reproduce/05_run_flow.sh sh8  runs it under another tag (work folder ~/pe_sh8r) so an existing run is not touched
# What it does (the same steps librelane/flow_variant_linux.sh does, minus the variant lookup: the run's complete configuration is archived):
#   1. assembles a source tree from reproduce/flows/<tag>/ (RTL + flow files as the run used them) and reproduce/flows/_common_<family>/ (macros, project plug-in)
#   2. librelane/run_tt_wsl.sh with EXTRA_CFG = the archived config_merged.json, TILES=8x4  (Tiny Tapeout user config + LibreLane 3.1.0.dev3 in its Nix shell)
#   3. reproduce/tools/compare_flow.py: the new config_merged.json and metrics.json against the archived ones
# Needs reproduce/01_install_tools.sh done. Takes 1.5 to 3 hours. Log: ~/flow_<newtag>.log, results: ~/pe_<newtag>/runs/<newtag>/final/
set -uo pipefail
TAG=${1:?tag, see reproduce/flows/}
NEW=${NEWTAG:-$TAG}
R=$(cd "$(dirname "$0")/.." && pwd)
F=$R/reproduce/flows/$TAG
[ -d "$F" ] || { echo "no archived flow $TAG"; exit 2; }
FAM=$(cat "$F/family.txt")
T=${TREE_DIR:-$HOME/pe_repro_trees}/$NEW
rm -rf "$T"; mkdir -p "$T"
cp -r "$F/src" "$T/src"
cp "$F/info.yaml" "$T/info.yaml"
cp -r "$R/reproduce/flows/_common_$FAM/macro" "$T/macro"
cp -r "$R/reproduce/flows/_common_$FAM/librelane_plugin_project" "$T/librelane_plugin_project"
export LLDIR=${LLDIR:-$HOME/librelane-3.1.0.dev3}
export TT_PDK_ROOT=${TT_PDK_ROOT:-$HOME/pdk_tt}
export RUN_TAG=$NEW SRC=$T WORK=$HOME/pe_$NEW TILES=8x4
export EXTRA_CFG=$(python3 -c "import json,sys; print(json.dumps(json.load(open(sys.argv[1]))))" "$F/config_merged.json")
{
  echo "start $(date -Is) tag=$NEW (archived flow $TAG, family $FAM) tree=$T TILES=$TILES"
  bash "$R/librelane/run_tt_wsl.sh"
  echo "exit code $?"
} 2>&1 | tee "$HOME/flow_$NEW.log"
python3 "$R/reproduce/tools/compare_flow.py" "$F" "$WORK" "$NEW" | tee -a "$HOME/flow_$NEW.log"
