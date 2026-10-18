# Compiles and runs every testbench in tb/ against src/. Prints one RESULT line per tb.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) { $env:Path += ';C:\iverilog\bin' }

$src  = Get-ChildItem src\*.v | ForEach-Object { $_.FullName }
# instr_mem is one IHP SRAM macro (1P 256x32): simulate it with the PDK functional models
$sim  = @('sim\ihp_sram\RM_IHPSG13_1P_core_behavioral_bm_bist.v', 'sim\ihp_sram\RM_IHPSG13_1P_256x32_c2_bm_bist.v')
$tbs = @('tb_instr_mem', 'tb_delay_counter', 'tb_loop_counter', 'tb_fifo', 'tb_shift_reg',
         'tb_alu_unit', 'tb_crc_unit', 'tb_engine_alu',
         'tb_pin_block', 'tb_control_unit', 'tb_engine_top', 'tb_rx_led_sink',
         'tb_mgmt_frame', 'tb_mgmt_load', 'tb_mgmt_dual', 'tb_mgmt_read', 'tb_mgmt_tx', 'tb_fetch_equiv',
         'tb_engine_ops', 'tb_pin_mgr', 'tb_mgmt_pins')
New-Item -ItemType Directory -Force build | Out-Null

foreach ($t in $tbs) {
    $extra = @(if ($t -eq 'tb_fetch_equiv') { 'tb\ref\ref_engine.v' })
    & iverilog -Wall -Wno-timescale -g2012 -DFUNCTIONAL -I src -I tb -o "build\$t.vvp" "tb\$t.v" @src @extra @sim
    if ($LASTEXITCODE -ne 0) { Write-Host "RESULT $t : COMPILE FAIL"; continue }
    & vvp -n "build\$t.vvp" | Where-Object { $_ -match 'RESULT|FAIL|---|got|interval' }
}
