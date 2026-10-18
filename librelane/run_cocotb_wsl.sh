#!/bin/bash
# cocotb smoke tests (test/test.py) in WSL on a copy of the project: RTL by default, gate level with GATES=yes
# (needs TT's Icarus 13 in ~/iverilog13 and a gate_level_netlist.v: NETLIST=<path to final/nl/*.nl.v>).
# Usage: bash librelane/run_cocotb_wsl.sh            or   GATES=yes NETLIST=... bash librelane/run_cocotb_wsl.sh
set -e
SRC=${SRC:-/mnt/c/Data/protocol_emulator}
W=${WORK:-$HOME/pe_cocotb}
mkdir -p "$W"
rsync -a --delete "$SRC/src/" "$W/src/" --exclude fpga
rsync -a --delete "$SRC/sim/" "$W/sim/"
rsync -a --delete --exclude sim_build --exclude results.xml --exclude '*.fst' "$SRC/test/" "$W/test/"
[ -f "$HOME/ttvenv/bin/activate" ] && . "$HOME/ttvenv/bin/activate"
[ -d "$HOME/iverilog13/bin" ] && [ "$GATES" = "yes" ] && export PATH="$HOME/iverilog13/bin:$PATH"
export PDK_ROOT=${PDK_ROOT:-$HOME/IHP-Open-PDK}
cd "$W/test"
if [ "$GATES" = "yes" ]; then
  cp "$NETLIST" gate_level_netlist.v
  make -B GATES=yes 2>&1 | tee ../cocotb_run.log | tail -n 40
else
  make -B 2>&1 | tee ../cocotb_run.log | tail -n 40
fi
