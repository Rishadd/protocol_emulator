#!/bin/bash
# The SymbiYosys proofs and their planted-bug (mutant) runs. Needs sby, yices, boolector (01_install_tools.sh).
#   bash reproduce/04_formal.sh main      4 proofs (pin_mgr, fifo, mgmt, engine) + 34 mutants
#   bash reproduce/04_formal.sh shared    6 proofs (+ imem_shared, region_go) + their mutants
# Expected: "PASS <name>" for every proof, and "caught" for every mutant (a proof that passes on a broken design proves nothing).
set -uo pipefail
R=$(cd "$(dirname "$0")/.." && pwd)
case ${1:-main} in
  main)   T=$R ;;
  shared) T=${SHARED:-$HOME/pe_shared_v2} ;;
  *) echo "usage: $0 main|shared"; exit 2 ;;
esac
cd "$T"
bash formal/run_formal_linux.sh
python3 formal/formal_mutants.py
