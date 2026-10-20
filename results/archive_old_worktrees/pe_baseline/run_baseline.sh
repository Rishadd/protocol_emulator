#!/usr/bin/env bash
# Baseline outputs of every protocol suite on the pre-two-tier design (tag tt-phase0).
cd "$(dirname "$0")"
PY=/c/Users/risha/miniconda3/python.exe
export PATH=$PATH:/c/iverilog/bin
mkdir -p baseline
$PY host/spi_test.py > baseline/spi_test.txt 2>&1 &
$PY host/i2c_test.py > baseline/i2c_test.txt 2>&1 &
$PY host/mgmt_duplex_stress.py > baseline/mgmt_duplex_stress.txt 2>&1 &
wait
$PY host/workload.py uart > baseline/workload_uart.txt 2>&1
$PY host/workload.py uartlimits > baseline/workload_uartlimits.txt 2>&1
$PY host/workload.py spi i2c combo > baseline/workload_spi_i2c_combo.txt 2>&1
echo BASELINE DONE
