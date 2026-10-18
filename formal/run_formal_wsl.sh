#!/bin/bash
# Run SymbiYosys proofs with the sby / yosys / abc from LibreLane's Nix shell. Usage: bash formal/run_formal_wsl.sh [name.sby ...]
# Each proof prints one line "PASS name" / "FAIL name"; work directories go to ~/formal_work (not into the repo).
# SRC_DIR=<dir> runs the proofs against another copy of src/ (used by formal/formal_mutants.py for broken designs).
F=/mnt/c/Data/protocol_emulator/formal
W=${FORMAL_WORK:-$HOME/formal_work}
SRC=${SRC_DIR:-/mnt/c/Data/protocol_emulator/src}
mkdir -p $W
JOBS=${*:-$(cd $F && ls *.sby)}
rc=0
for s in $JOBS; do
  n=${s%.sby}
  rm -rf $W/$n
  sed "s#\.\./src/#$SRC/#" $F/$s > $W/$s            # same proof, sources from SRC
  (cd ~/librelane-dev && nix-shell --pure --run "cd $F && sby -f -d $W/$n $W/$s" > $W/$n.log 2>&1)
  if grep -q 'DONE (PASS' $W/$n.log; then
    echo "PASS $n"
  else
    echo "FAIL $n"; grep -E 'Assert failed|failed assertion|ERROR|summary' $W/$n.log | grep -v pipewire | head -8; rc=1
  fi
done
exit $rc
