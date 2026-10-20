# Regression 2026-10-20

| phase | suite | result | minutes | last result line |
|---|---|---|---|---|
| A | alu_test | PASS | 0.5 | RESULT alu_test: PASS |
| A | can_test | PASS | 3.4 | RESULT can_test: PASS (47/47 cases as expected) |
| A | chip_host_demo | PASS | 0.4 | DONE: 574 SPI frames (7 bytes each way per frame), all checks passed |
| A | crc_test | PASS | 0.8 | RESULT crc_test: PASS |
| A | i2c_slave_test | **FAIL** | 0.0 | Phase 1: engine = I2C slave at 400 kHz, Verilog master model, model slave 0x50 on the same bus |
| A | i2c_test | PASS | 3.1 | RESULT i2c_test: PASS (60/60 cases as expected) |
| A | isa_diff_test | PASS | 5.9 | RESULT isa_diff_test: PASS |
| A | jtag_test | PASS | 0.2 | RESULT jtag_test: PASS (21/21 cases as expected) |
| A | line_coder_mutants | **FAIL** | 0.6 | line coder mutants caught: 16/16 |
| A | line_coder_test | PASS | 0.1 | RESULT line_coder_test: PASS (1221/1221 checks) |
| A | mgmt_duplex_stress | PASS | 12.8 | ALL PASS |
| A | modbus_test | PASS | 6.3 | RESULT modbus_test: PASS (26/26 cases as expected) |
| A | onewire_test | PASS | 1.8 | RESULT onewire_test: PASS (18/18 cases as expected) |
| A | ps2_test | PASS | 3.1 | RESULT ps2_test: PASS (29/29 cases as expected) |
| A | smbus_test | PASS | 0.5 | RESULT smbus_test: PASS (23/23 cases as expected) |
| A | spi_test | PASS | 8.4 | RESULT spi_test: PASS (312/312 cases as expected) |
| A | swd_test | PASS | 0.1 | RESULT swd_test: PASS (11/11 cases as expected) |
| A | uart_rx_workload | PASS | 3.4 | ALL PASS |
| A | uart_workload | PASS | 3.1 | 2/2 baud rates fully PASS (all bytes decoded, all frames cycle-exact vs Python reference) |
| A | unit_testbenches | PASS | 6.0 | 22 testbenches reported; none failed |
| A | usb_mutants | PASS | 0.7 | usb firmware mutants caught: 18/18 |
| A | usb_test_model | PASS | 0.2 | RESULT usb_test (model): PASS (45/45 checks) |
| A | usb_test_rtl | PASS | 2.7 | RESULT usb_test (rtl): PASS (45/45 checks) |
| A | workload | PASS | 19.7 | RESULT workload: PASS (55/55 cases as expected) |
| A | ws2812_test | PASS | 0.2 | RESULT ws2812_test: PASS (15/15 cases as expected) |
| B | chip_can_test | PASS | 3.0 | RESULT can_test: PASS (26/26 cases as expected) |
| B | chip_jtag_test | PASS | 1.4 | RESULT jtag_test: PASS (17/17 cases as expected) |
| B | chip_modbus_test | PASS | 4.9 | RESULT modbus_test: PASS (16/16 cases as expected) |
| B | chip_onewire_test | PASS | 1.6 | RESULT onewire_test: PASS (10/10 cases as expected) |
| C | org192_i2c_test | PASS | 3.7 | RESULT i2c_test: PASS (60/60 cases as expected) |
| C | org192_modbus_test | PASS | 3.7 | RESULT modbus_test: PASS (16/16 cases as expected) |
| C | org192_spi_test | PASS | 10.0 | RESULT spi_test: PASS (312/312 cases as expected) |
| C | org64_can_test | PASS | 1.0 | RESULT can_test: PASS (27/27 cases as expected) |
| C | org64_jtag_test | PASS | 0.1 | RESULT jtag_test: PASS (17/17 cases as expected) |
| C | org64_onewire_test | PASS | 1.0 | RESULT onewire_test: PASS (10/10 cases as expected) |
| D | remap1_can_test | PASS | 4.1 | RESULT can_test: PASS (26/26 cases as expected) |
| D | remap1_jtag_test | PASS | 12.0 | RESULT jtag_test: PASS (17/17 cases as expected) |
| D | remap1_modbus_test | PASS | 5.8 | RESULT modbus_test: PASS (16/16 cases as expected) |
| D | remap1_onewire_test | PASS | 1.8 | RESULT onewire_test: PASS (10/10 cases as expected) |
| D | remap2_can_test | PASS | 4.6 | RESULT can_test: PASS (26/26 cases as expected) |
| D | remap2_jtag_test | PASS | 2.2 | RESULT jtag_test: PASS (17/17 cases as expected) |
| D | remap2_modbus_test | PASS | 6.1 | RESULT modbus_test: PASS (16/16 cases as expected) |
| D | remap2_onewire_test | PASS | 2.2 | RESULT onewire_test: PASS (10/10 cases as expected) |
| D | remap3_can_test | PASS | 4.0 | RESULT can_test: PASS (26/26 cases as expected) |
| D | remap3_jtag_test | PASS | 3.2 | RESULT jtag_test: PASS (17/17 cases as expected) |
| D | remap3_modbus_test | PASS | 5.2 | RESULT modbus_test: PASS (16/16 cases as expected) |
| D | remap3_onewire_test | PASS | 2.2 | RESULT onewire_test: PASS (10/10 cases as expected) |

45 of 47 suites passed.
