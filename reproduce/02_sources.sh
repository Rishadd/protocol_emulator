#!/bin/bash
# The shared-memory chip (shared 512-word instruction memory, frame v2, logic analyser) lives on the git branch shared/on-v2, which is NOT on GitHub's main.
# This script makes that branch available as a second working tree (default ~/pe_shared_v2), from this repository's own .git, or from the bundle
# reproduce/branches.bundle (all branches that are not in main: shared/on-v2, exp/shared-timing, feat/shared-imem, feat/frame-v2, merge/frame-v2).
#   bash reproduce/02_sources.sh [worktree dir] [commit-ish, default: the commit recorded in reproduce/SHARED_COMMIT]
set -euo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
W=${1:-$HOME/pe_shared_v2}
C=${2:-$(cat "$R/reproduce/SHARED_COMMIT")}
cd "$R"
if ! git cat-file -e "$C^{commit}" 2>/dev/null; then
  echo "commit $C not in this repository: fetching the branches from reproduce/branches.bundle"
  git fetch "$R/reproduce/branches.bundle" 'refs/heads/*:refs/heads/*' 2>&1 | tail -3 || true
fi
[ -d "$W" ] && { echo "$W exists; using it"; git -C "$W" log -1 --oneline; exit 0; }
git worktree add --detach "$W" "$C"
git -C "$W" log -1 --oneline
