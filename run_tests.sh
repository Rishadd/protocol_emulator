#!/bin/bash
# Linux twin of run_tests.ps1: compiles and runs every testbench in tb/ against src/. Prints one RESULT line per tb.
set -uo pipefail
cd "$(dirname "$0")"

src=(src/*.v)
# instr_mem is one IHP SRAM macro (1P 256x32): simulate it with the PDK functional models
sim=(sim/ihp_sram/RM_IHPSG13_1P_core_behavioral_bm_bist.v sim/ihp_sram/RM_IHPSG13_1P_256x32_c2_bm_bist.v)
tbs=(tb_instr_mem tb_pc_reg tb_delay_counter tb_loop_counter tb_fifo tb_shift_reg
     tb_alu_unit tb_crc_unit tb_engine_alu
     tb_pin_block tb_control_unit tb_engine_top tb_rx_led_sink
     tb_mgmt_frame tb_mgmt_load tb_mgmt_dual tb_mgmt_read tb_mgmt_tx tb_fetch_equiv
     tb_engine_ops tb_pin_mgr tb_mgmt_pins)
mkdir -p build

for t in "${tbs[@]}"; do
    extra=()
    [ "$t" = tb_fetch_equiv ] && extra=(tb/ref/ref_engine.v)
    if ! iverilog -Wall -Wno-timescale -g2012 -DFUNCTIONAL -I src -I tb -o "build/$t.vvp" "tb/$t.v" "${src[@]}" "${extra[@]}" "${sim[@]}"; then
        echo "RESULT $t : COMPILE FAIL"
        continue
    fi
    vvp -n "build/$t.vvp" | grep -E 'RESULT|FAIL|---|got|interval'
done
