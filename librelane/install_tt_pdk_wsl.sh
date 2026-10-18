#!/bin/bash
# Install the IHP-Open-PDK revision that Tiny Tapeout's GitHub gds action uses (tt-gds-action@ihp-cmos5l, install_sg13cmos5l.sh),
# so local flow runs build with the same standard-cell library as the official build. Installed into ~/pdk_tt (the dev checkout in
# ~/IHP-Open-PDK is left alone). Our local dev PDK (2026-10-16) synthesised 3 % fewer cells than the action's (2026-09-08).
set -euo pipefail
REV=${1:-2bbec755dc67ca3db0261c3d6163e15735d66710}
DIR=${2:-$HOME/pdk_tt}
mkdir -p "$DIR"
git -C "$DIR" init -q
git -C "$DIR" fetch -q --depth 1 https://github.com/IHP-GmbH/IHP-Open-PDK.git "$REV"
git -C "$DIR" checkout -q FETCH_HEAD
echo "IHP-Open-PDK $REV" > "$DIR/ihp-sg13cmos5l/SOURCES"
du -sh "$DIR"
echo "installed $REV in $DIR"
