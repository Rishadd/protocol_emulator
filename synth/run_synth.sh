#!/usr/bin/env bash
# Wrapper: puts the OSS CAD Suite on PATH and runs the Yosys flow. Run from the repo root.
#   synth/run_synth.sh <tag> [VAR=value ...]     e.g. synth/run_synth.sh sram SYNTH_SKIP=instr_mem.v
# Output: build/synth/<tag>.{log,stat.txt,netlist.v}
set -e
export PATH=/c/tools/oss-cad-suite/bin:/c/tools/oss-cad-suite/lib:$PATH
tag=$1; shift
for kv in "$@"; do export "$kv"; done
export SYNTH_OUT=build/synth/$tag
mkdir -p build/synth
yosys -c synth/synth_cmos5l.tcl -l build/synth/$tag.log > /dev/null
grep -E "Chip area for top module|of which used for sequential" build/synth/$tag.stat.txt | tail -2
