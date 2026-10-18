#!/bin/bash
# Synthesis + pre-layout STA of the TT configuration with different Yosys strategies (and optional extra config JSON):
# prints standard-cell count, area and the worst setup slack of each corner.
# Usage: bash librelane/synth_variants_wsl.sh AREA_0 DELAY_2 ...   (underscore stands for the space in the strategy name)
LIB=${TT_PDK_ROOT:-$HOME/pdk_tt}/ihp-sg13cmos5l/libs.ref/sg13cmos5l_stdcell/lib/sg13cmos5l_stdcell_typ_1p20V_25C.lib
for A in "$@"; do
  S=${A//_/ }; N=$A
  export RUN_TAG=syn_$N WORK=$HOME/pe_syn_$N
  rm -rf $WORK/runs
  export EXTRA_CFG="{\"SYNTH_STRATEGY\": \"$S\", \"RUN_MAGIC_DRC\": false}"
  bash /mnt/c/Data/protocol_emulator/librelane/run_tt_wsl.sh --to OpenROAD.STAPrePNR > $HOME/syn_$N.log 2>&1
  NL=$(ls $WORK/runs/$RUN_TAG/*-yosys-synthesis/tt_um_protocol_emulator.nl.v | head -n 1)
  echo "=== $S"; python3 /mnt/c/Data/protocol_emulator/librelane/area_by_module.py "$NL" "$LIB" --depth 2 | head -n 1
  for c in nom_slow_1p08V_125C nom_typ_1p20V_25C nom_fast_1p32V_m40C; do
    f=$(ls $WORK/runs/$RUN_TAG/*-openroad-staprepnr/$c/ws.max.rpt 2>/dev/null | head -n 1)
    [ -n "$f" ] && echo "  setup ws $c: $(grep -E '[-0-9]+\.[0-9]+' $f | tail -n 1)"
  done
done
