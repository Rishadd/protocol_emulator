#!/bin/bash
# Tiny Tapeout precheck (tt-support-tools, branch ihp-sg13cmos5l) on the final GDS of a run made by flow_variant_linux.sh.
# Usage: bash librelane/precheck_linux.sh <tag> [work dir, default ~/pe_<tag>]
# The work folder's info.yaml must name the tile size of the layout (8x4 for the shared / tt14b runs): the precheck compares the layout
# with that template. ~/ttvenv has the precheck requirements (pip install -r ~/tt-support-tools/precheck/requirements.txt); its Python is
# Nix's, so the C++ / zlib / expat libraries it needs come from the Nix store through LD_LIBRARY_PATH (the system ones need a newer glibc).
TAG=${1:?tag}
WORK=${2:-$HOME/pe_$TAG}
G=$WORK/runs/$TAG/final/gds/tt_um_protocol_emulator.gds
LIBS=""
for p in gcc-*-lib zlib-[0-9]* expat-[0-9]*; do
  d=$(ls -d /nix/store/*-$p/lib 2>/dev/null | head -1); [ -n "$d" ] && LIBS=$LIBS:$d
done
export LD_LIBRARY_PATH=${LIBS#:}
export PDK_ROOT=${TT_PDK_ROOT:-$HOME/pdk_tt} PDK=ihp-sg13cmos5l
cd "$WORK/tt/precheck" && "$HOME/ttvenv/bin/python" precheck.py --gds "$G" --tech ihp-sg13cmos5l 2>&1 | tee "$HOME/precheck_$TAG.txt"
