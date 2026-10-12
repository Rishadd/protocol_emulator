# Compiles and runs every testbench in tb/ against src/. Prints one RESULT line per tb.
#   .\run_tests.ps1                  the chip as built
#   .\run_tests.ps1 -Define NO_L2    the fallback chip without the shared L2 (testbenches that need L2 are skipped)
param([string]$Define = "")
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) { $env:Path += ';C:\iverilog\bin' }

$src  = Get-ChildItem src\*.v | ForEach-Object { $_.FullName }
# instr_mem (L1) and l2_mem are IHP SRAM macros: simulate them with the PDK functional models
$sim  = Get-ChildItem sim\ihp_sram\*.v | ForEach-Object { $_.FullName }
$tbs = @('tb_instr_mem', 'tb_pc_reg','tb_delay_counter', 'tb_loop_counter', 'tb_fifo', 'tb_shift_reg',
         'tb_pin_block', 'tb_control_unit', 'tb_engine_top', 'tb_rx_led_sink',
         'tb_mgmt_frame', 'tb_mgmt_load', 'tb_mgmt_dual', 'tb_mgmt_read', 'tb_mgmt_tx', 'tb_fetch_equiv',
         'tb_engine_ops', 'tb_pin_mgr', 'tb_mgmt_pins', 'tb_l2_macro', 'tb_fetch_equiv_v2', 'tb_arb', 'tb_l2_host')
$needs_l2 = @('tb_arb', 'tb_l2_host')
# extra files some testbenches need (reference models)
$extras = @{ 'tb_fetch_equiv' = @('tb\ref\ref_engine.v', 'tb\ref\ref_engine_v1.v');
             'tb_fetch_equiv_v2' = @('tb\ref\ref_engine_v1.v'); 'tb_l2_macro' = @('formal\abs_sram.v') }
$defs = @('-DFUNCTIONAL'); $out = 'build'
if ($Define) { $defs += "-D$Define"; $out = "build\$Define" }
New-Item -ItemType Directory -Force $out | Out-Null

foreach ($t in $tbs) {
    if ($Define -eq 'NO_L2' -and $needs_l2 -contains $t) { continue }
    $extra = @(); if ($extras.ContainsKey($t)) { $extra = $extras[$t] }
    & iverilog -Wall -Wno-timescale -g2012 @defs -s $t -I src -I tb -o "$out\$t.vvp" "tb\$t.v" @src @extra @sim
    if ($LASTEXITCODE -ne 0) { Write-Host "RESULT $t : COMPILE FAIL"; continue }
    & vvp -n "$out\$t.vvp" | Where-Object { $_ -match 'RESULT|FAIL|---|got|interval' }
}
