# Compiles and runs every testbench in tb/ against src/. Prints one RESULT line per tb.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) { $env:Path += ';C:\iverilog\bin' }

$src  = Get-ChildItem src\*.v | ForEach-Object { $_.FullName }
# instr_mem is two IHP SRAM macros: simulate them with the PDK functional models
$sim  = Get-ChildItem sim\ihp_sram\*.v | ForEach-Object { $_.FullName }
$tbs = @('tb_instr_mem', 'tb_pc_reg','tb_delay_counter', 'tb_loop_counter', 'tb_fifo', 'tb_shift_reg',
         'tb_pin_block', 'tb_control_unit', 'tb_engine_top', 'tb_rx_led_sink',
         'tb_mgmt_frame', 'tb_mgmt_load', 'tb_mgmt_dual', 'tb_mgmt_read', 'tb_mgmt_tx', 'tb_fetch_equiv',
         'tb_engine_ops', 'tb_pin_mgr', 'tb_mgmt_pins', 'tb_l2_macro')
# extra files some testbenches need (reference models)
$extras = @{ 'tb_fetch_equiv' = @('tb\ref\ref_engine.v'); 'tb_l2_macro' = @('formal\abs_sram.v') }
New-Item -ItemType Directory -Force build | Out-Null

foreach ($t in $tbs) {
    $extra = @(); if ($extras.ContainsKey($t)) { $extra = $extras[$t] }
    & iverilog -Wall -Wno-timescale -g2012 -DFUNCTIONAL -s $t -I src -I tb -o "build\$t.vvp" "tb\$t.v" @src @extra @sim
    if ($LASTEXITCODE -ne 0) { Write-Host "RESULT $t : COMPILE FAIL"; continue }
    & vvp -n "build\$t.vvp" | Where-Object { $_ -match 'RESULT|FAIL|---|got|interval' }
}
