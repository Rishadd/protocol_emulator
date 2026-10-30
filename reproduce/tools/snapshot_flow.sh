#!/bin/bash
# Archive everything one finished (or started) flow run was built from, so it can be run again from this repository alone:
#   reproduce/flows/<tag>/src/            the RTL and flow files exactly as the run used them (copied from the run's work folder)
#   reproduce/flows/<tag>/info.yaml       the run's info.yaml
#   reproduce/flows/<tag>/config_merged.json   the complete LibreLane configuration the run used
#   reproduce/flows/<tag>/expected_metrics.json  the run's final metrics (compared by reproduce/05_run_flow.sh after a rerun)
#   reproduce/flows/<tag>/command.txt     the log's first line (date, variant, source tree)
# The macro folder and the project plug-in are shared by several runs: reproduce/flows/_common_<family>/ (made once per family).
# Usage: bash reproduce/tools/snapshot_flow.sh <tag> <family: shmem | shared_v2> [work folder, default ~/pe_<tag>]
set -euo pipefail
TAG=$1; FAM=$2; W=${3:-$HOME/pe_$TAG}
R=$(cd "$(dirname "$0")/../.." && pwd)
D=$R/reproduce/flows/$TAG
rm -rf "$D"; mkdir -p "$D/src"
rsync -a --exclude user_config.json --exclude config_merged.json "$W/src/" "$D/src/"
cp "$W/src/config_merged.json" "$D/config_merged.json"
cp "$W/info.yaml" "$D/info.yaml"
echo "$FAM" > "$D/family.txt"
[ -f "$W/runs/$TAG/final/metrics.json" ] && cp "$W/runs/$TAG/final/metrics.json" "$D/expected_metrics.json"
grep -m1 '^start' "$HOME/flow_$TAG.log" > "$D/command.txt" 2>/dev/null || true
C=$R/reproduce/flows/_common_$FAM
if [ ! -d "$C" ]; then
  mkdir -p "$C"
  rsync -a "$W/macro/" "$C/macro/"
  rsync -a --exclude __pycache__ "$W/librelane_plugin_project/" "$C/librelane_plugin_project/"
fi
echo "snapshot $TAG -> $D (family $FAM)"
