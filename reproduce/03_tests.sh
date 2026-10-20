#!/bin/bash
# Every simulation test of the project. Needs 01_install_tools.sh (Icarus Verilog 13, Python 3.12) and, for the shared-memory chip, 02_sources.sh.
#   bash reproduce/03_tests.sh main      the verified base on `main` (regress phases A-D, 47 suites; results/regression_2026-10-20e)
#   bash reproduce/03_tests.sh shared    the shared-memory chip with the logic analyser (worktree from 02_sources.sh: phases A-F)
#   JOBS=12 bash reproduce/03_tests.sh shared    parallel suites (default: 8)
# Each writes <tree>/results/regression_repro_<name>/summary.md and one log per suite. A suite passes when its process exits 0, prints no FAIL / MISSED /
# COMPILE FAIL line and its last RESULT line says PASS (host/regress.py, header). Expected: every line PASS. Takes 1 to 2 hours on 16 cores.
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
WHICH=${1:-main}
JOBS=${JOBS:-8}
case $WHICH in
  main)   T=$R ;;
  shared) T=${SHARED:-$HOME/pe_shared_v2}; [ -d "$T" ] || { echo "run reproduce/02_sources.sh first"; exit 1; } ;;
  *) echo "usage: $0 main|shared"; exit 2 ;;
esac
cd "$T"
find build -name '*.vvp' -delete 2>/dev/null     # compiled files of another Icarus build do not run
python3 host/regress.py --out "results/regression_repro_$WHICH" --jobs "$JOBS"
echo "summary: $T/results/regression_repro_$WHICH/summary.md"
