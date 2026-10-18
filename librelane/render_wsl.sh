#!/bin/bash
# Stage-by-stage KLayout images of a run (librelane/render_stages.py), then the gallery (README.md + index.html).
# Usage: bash librelane/render_wsl.sh <tag> <output dir (WSL path)> [title] [work dir, default ~/pe_<tag>]
TAG=$1
OUT=$2
TITLE=${3:-$TAG}
WORK=${4:-$HOME/pe_$TAG}
RUN=$WORK/runs/$TAG
PDK=$HOME/IHP-Open-PDK/ihp-sg13cmos5l
SCRIPT=/mnt/c/Data/protocol_emulator/librelane/render_stages.py
MLEF=$WORK/macro/RM_IHPSG13_1P_256x32_c2_bm_bist/RM_IHPSG13_1P_256x32_c2_bm_bist.lef
mkdir -p "$OUT"
cd ~/librelane-dev
nix-shell --pure --run "klayout -b -r $SCRIPT -rd run=$RUN -rd out=$OUT -rd pdk=$PDK -rd macro_lef=$MLEF -rd width=2000" 2>&1 | grep -v pipewire
python3 /mnt/c/Data/protocol_emulator/librelane/make_gallery.py "$OUT" "$TITLE" "$RUN/final/metrics.json"
