#!/bin/bash
# Gate-level cocotb test (test/test.py, same tests as RTL) of the routed netlist of a run, with Tiny Tapeout's Icarus Verilog 13.0
# (unpacked in ~/iverilog13, not installed): the PDK flop models need its $setuphold support.
# Usage: bash librelane/gl_test_wsl.sh <tag> [work dir, default ~/pe_<tag>]
TAG=${1:-tt6}
WORK=${2:-$HOME/pe_$TAG}
IV=$HOME/iverilog13/root/usr
. ~/ttvenv/bin/activate
D=$HOME/pe_gl_$TAG
rm -rf $D && mkdir -p $D
cp -r /mnt/c/Data/protocol_emulator/src /mnt/c/Data/protocol_emulator/sim /mnt/c/Data/protocol_emulator/test $D/
cp $WORK/runs/$TAG/final/nl/tt_um_protocol_emulator.nl.v $D/test/gate_level_netlist.v
cd $D/test
export PDK_ROOT=$HOME/IHP-Open-PDK
export ICARUS_BIN_DIR=$IV/bin IVERILOG_VPI_MODULE_PATH=$IV/lib/ivl COMPILE_ARGS="-B $IV/lib/ivl"
make -B GATES=yes 2>&1 | grep -v "Timing checks are not supported\|warning:" | tee $HOME/gl_$TAG.txt | tail -n 25
