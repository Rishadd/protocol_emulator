#!/bin/bash
# Second LibreLane checkout at the release Tiny Tapeout's GitHub gds action installs (tt-gds-action@ihp-cmos5l:
# `pip install librelane==3.1.0.dev3`), so local runs use the same tools as the official build. Our ~/librelane-dev dev checkout
# is 20 commits newer and synthesises differently (SYNTH_ABC_NEW etc.: 15,597 vs 16,040 cells). Use it with
#   LLDIR=~/librelane-3.1.0.dev3 bash librelane/flow_run_wsl.sh <tag>
# The first nix-shell in the new checkout downloads that release's tools (several GB on the WSL disk).
set -euo pipefail
TAG=${1:-3.1.0.dev3}
DIR=${2:-$HOME/librelane-$TAG}
if [ ! -d "$DIR" ]; then
  git -C ~/librelane-dev worktree add --detach "$DIR" "$TAG"
fi
cd "$DIR"
echo "checkout: $(git log -1 --format='%h %ad %s' --date=short)"
nix-shell --pure --run "python3 -c 'import librelane; print(\"librelane\", librelane.__version__)'; yosys -V; openroad -version" 2>&1 | grep -v pipewire | tail -4
