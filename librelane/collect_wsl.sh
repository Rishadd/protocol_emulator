#!/bin/bash
# Copy the small result files of a LibreLane run (metrics, resolved config, routing DRC, STA summaries) from the WSL
# disk into results/librelane_<date>/<run>. Usage (in WSL): bash librelane/collect_wsl.sh run1 [results-subdir]
RUN=${1:-run1}
OUT=${2:-/mnt/c/Data/protocol_emulator/results/librelane_2026-10-17}/$RUN
R=$HOME/pe_run/librelane/runs/$RUN
mkdir -p "$OUT"
cp "$R"/final/metrics.json "$R"/final/metrics.csv "$R"/resolved.json "$OUT"/
cp "$R"/*-openroad-detailedrouting/*.drc "$OUT"/detailed_routing.drc 2>/dev/null
for d in "$R"/*-openroad-stapostpnr "$R"/*-misc-reportmanufacturability "$R"/*-openroad-irdropreport; do
  [ -d "$d" ] && mkdir -p "$OUT/$(basename "$d")" && cp -r "$d"/reports "$d"/*.rpt "$OUT/$(basename "$d")"/ 2>/dev/null
done
du -sh "$OUT"; ls "$OUT"
