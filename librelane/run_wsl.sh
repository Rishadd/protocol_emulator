#!/bin/bash
# Run the LibreLane flow for tt_um_protocol_emulator inside WSL, in LibreLane's Nix shell.
# Needs (once): Nix with flakes + the fossi cache, ~/librelane (github.com/librelane/librelane) and
# ~/IHP-Open-PDK (dev branch, has ihp-sg13cmos5l). The repo is copied to the WSL disk first
# (the /mnt/c share is too slow for a P&R run). Usage: bash librelane/run_wsl.sh [extra librelane args]
set -e
SRC=${SRC:-/mnt/c/Data/protocol_emulator}
WORK=${WORK:-$HOME/pe_run}
mkdir -p "$WORK"
rsync -a --delete --exclude runs "$SRC/src" "$SRC/librelane" "$WORK/" --exclude fpga
cd "${LLDIR:-$HOME/librelane-dev}"
nix-shell --pure --run "cd $WORK/librelane && librelane config.json --pdk ihp-sg13cmos5l --pdk-root $HOME/IHP-Open-PDK --manual-pdk --run-tag ${RUN_TAG:-run1} $*"
