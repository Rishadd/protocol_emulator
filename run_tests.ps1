# Compiles and runs every testbench in tb/ against src/. Prints one RESULT line per tb.
$ErrorActionPreference = 'Stop'
Set-Location $PSScriptRoot
if (-not (Get-Command iverilog -ErrorAction SilentlyContinue)) { $env:Path += ';C:\iverilog\bin' }

$src  = Get-ChildItem src\*.v | ForEach-Object { $_.FullName }
$fpga = Get-ChildItem src\fpga\*.v | ForEach-Object { $_.FullName }
$tbs = @('tb_pc_reg', 'tb_delay_counter', 'tb_loop_counter', 'tb_fifo', 'tb_shift_reg',
         'tb_pin_block', 'tb_control_unit', 'tb_engine_top', 'tb_rx_led_sink', 'tb_de0_nano_rx_top', 'tb_de0_nano_top')
New-Item -ItemType Directory -Force build | Out-Null

foreach ($t in $tbs) {
    $extra = if ($t -like 'tb_de0_nano*') { $fpga } else { @() }
    & iverilog -Wall -Wno-timescale -g2012 -I src -I tb -o "build\$t.vvp" "tb\$t.v" @src @extra
    if ($LASTEXITCODE -ne 0) { Write-Host "RESULT $t : COMPILE FAIL"; continue }
    & vvp -n "build\$t.vvp" | Where-Object { $_ -match 'RESULT|FAIL|---|got|interval' }
}
