#!/bin/bash
# Copy the small result files of a Tiny Tapeout-flow run (run_tt_wsl.sh) from the WSL disk into the repo.
# Usage (in WSL): [WORK=~/pe_tt6] bash librelane/collect_tt_wsl.sh tt6 [results-subdir]
RUN=${1:-tt3}
OUT=${2:-/mnt/c/Data/protocol_emulator/results/tt_flow_2026-10-17}/$RUN
W=${WORK:-$HOME/pe_tt}
R=$W/runs/$RUN
mkdir -p "$OUT"
cp "$R"/final/metrics.json "$R"/final/metrics.csv "$R"/resolved.json "$OUT"/
cp "$W"/src/config_merged.json "$OUT"/config_merged.json 2>/dev/null
cp "$R"/*-openroad-detailedrouting/*.drc "$OUT"/detailed_routing.drc 2>/dev/null
for d in "$R"/*-openroad-stapostpnr "$R"/*-misc-reportmanufacturability "$R"/*-openroad-irdropreport "$R"/*-netgen-lvs "$R"/*-openroad-cts; do
  [ -d "$d" ] && mkdir -p "$OUT/$(basename "$d")" && cp -r "$d"/reports "$d"/*.rpt "$d"/*.json "$d"/*.log "$OUT/$(basename "$d")"/ 2>/dev/null
done
[ -d "$W/tt/precheck/reports" ] && cp -r "$W/tt/precheck/reports" "$OUT/precheck_reports"
du -sh "$OUT"; ls "$OUT"
