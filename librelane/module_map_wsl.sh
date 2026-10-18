#!/bin/bash
# Annotated placement of a run step (librelane/module_map.py): module-coloured map + module/engine regions over the KLayout picture.
# Usage: bash librelane/module_map_wsl.sh <tag> <images dir (WSL path), made by render_wsl.sh> [step, default detailedplacement] [title]
TAG=$1; OUT=$2; STEP=${3:-detailedplacement}; TITLE=${4:-$TAG}
WORK=${WORK:-$HOME/pe_$TAG}
D=$(ls -d $WORK/runs/$TAG/*-openroad-$STEP | tail -n 1)
DEF=$(ls $D/*.def | head -n 1)
LABEL=${STEP/placement/_placement}                     # detailedplacement -> detailed_placement (render_stages.py file name)
BG=$(ls "$OUT"/*_${LABEL}__cells_only.png 2>/dev/null | head -n 1)
LEF=$HOME/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_stdcell.lef
. ~/ttvenv/bin/activate
python3 /mnt/c/Data/protocol_emulator/librelane/module_map.py --def $DEF --lef $LEF \
  --lef $WORK/macro/RM_IHPSG13_1P_256x32_c2_bm_bist/RM_IHPSG13_1P_256x32_c2_bm_bist.lef \
  --out "$OUT" --prefix "${STEP}__" ${BG:+--bg $BG} --title "$TITLE"
