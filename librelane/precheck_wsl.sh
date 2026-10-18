#!/bin/bash
# Tiny Tapeout precheck (tt-support-tools, branch ihp-sg13cmos5l) on the final GDS of a run made by flow_run_wsl.sh / run_tt_wsl.sh.
# Usage: bash librelane/precheck_wsl.sh <tag> [work dir, default ~/pe_<tag>]
TAG=${1:-tt6}
WORK=${2:-$HOME/pe_$TAG}
G=$WORK/runs/$TAG/final/gds/tt_um_protocol_emulator.gds
cd ~/librelane-dev
nix-shell --pure --run "export PDK_ROOT=$HOME/IHP-Open-PDK PDK=ihp-sg13cmos5l; . $HOME/ttvenv/bin/activate; cd $WORK/tt/precheck && python precheck.py --gds $G --tech ihp-sg13cmos5l" 2>&1 | grep -v pipewire | tee $HOME/precheck_$TAG.txt | tail -n 60
