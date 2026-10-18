#!/bin/bash
# Where did each module's cells end up? Table + module-coloured picture (librelane/module_report.py) for a step of a run.
# Usage: bash librelane/report_modules_wsl.sh <tag> <step dir suffix, e.g. openroad-detailedplacement> <output dir> [title]
TAG=$1; STEP=$2; OUT=$3; TITLE=${4:-$TAG $STEP}
WORK=${WORK:-$HOME/pe_$TAG}
D=$(ls -d $WORK/runs/$TAG/*-$STEP | tail -n 1)
DEF=$(ls $D/*.def | head -n 1)
LEF=$HOME/IHP-Open-PDK/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_stdcell.lef
. ~/ttvenv/bin/activate
python3 /mnt/c/Data/protocol_emulator/librelane/module_report.py --def $DEF --boxes /mnt/c/Data/protocol_emulator/src/floorplan_boxes.json \
  --lef $LEF --lef $WORK/macro/RM_IHPSG13_1P_256x32_c2_bm_bist/RM_IHPSG13_1P_256x32_c2_bm_bist.lef --out "$OUT" --title "$TITLE"
