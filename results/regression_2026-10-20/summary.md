# Regression 2026-10-20

| phase | suite | result | minutes | last result line |
|---|---|---|---|---|
| A | alu_test | PASS | 0.6 | RESULT alu_test: PASS |
| A | can_test | PASS | 3.2 | RESULT can_test: PASS (47/47 cases as expected) |
| A | chip_host_demo | PASS | 0.4 | DONE: 574 SPI frames (7 bytes each way per frame), all checks passed |
| A | crc_test | PASS | 0.8 | RESULT crc_test: PASS |
| A | i2c_slave_test | PASS | 2.4 | RESULT i2c_slave_test: PASS (45/45 cases as expected) |
| A | i2c_test | PASS | 2.6 | RESULT i2c_test: PASS (60/60 cases as expected) |
| A | isa_diff_test | PASS | 6.3 | RESULT isa_diff_test: PASS |
| A | jtag_test | PASS | 0.2 | RESULT jtag_test: PASS (21/21 cases as expected) |
| A | line_coder_mutants | PASS | 0.6 | line coder mutants caught: 16/16 |
| A | line_coder_test | PASS | 0.1 | RESULT line_coder_test: PASS (1221/1221 checks) |
| A | mgmt_duplex_stress | PASS | 12.8 | ALL PASS |
| A | modbus_test | PASS | 5.4 | RESULT modbus_test: PASS (26/26 cases as expected) |
| A | onewire_test | PASS | 2.0 | RESULT onewire_test: PASS (18/18 cases as expected) |
| A | ps2_test | PASS | 1.5 | RESULT ps2_test: PASS (29/29 cases as expected) |
| A | smbus_test | PASS | 0.6 | RESULT smbus_test: PASS (23/23 cases as expected) |
| A | spi_test | PASS | 8.1 | RESULT spi_test: PASS (312/312 cases as expected) |
| A | swd_test | PASS | 0.1 | RESULT swd_test: PASS (11/11 cases as expected) |
| A | uart_rx_workload | PASS | 2.9 | ALL PASS |
| A | uart_workload | PASS | 3.2 | 2/2 baud rates fully PASS (all bytes decoded, all frames cycle-exact vs Python reference) |
| A | unit_testbenches | **FAIL** | 4.3 | 22 testbenches reported; 6 FAIL lines |
| A | usb_mutants | PASS | 0.7 | usb firmware mutants caught: 18/18 |
| A | usb_test_model | PASS | 0.1 | RESULT usb_test (model): PASS (45/45 checks) |
| A | usb_test_rtl | PASS | 2.7 | RESULT usb_test (rtl): PASS (45/45 checks) |
| A | workload | PASS | 20.6 | RESULT workload: PASS (55/55 cases as expected) |
| A | ws2812_test | PASS | 0.3 | RESULT ws2812_test: PASS (15/15 cases as expected) |
| B | chip_can_test | PASS | 2.9 | RESULT can_test: PASS (26/26 cases as expected) |
| B | chip_jtag_test | PASS | 1.4 | RESULT jtag_test: PASS (17/17 cases as expected) |
| B | chip_modbus_test | PASS | 5.0 | RESULT modbus_test: PASS (16/16 cases as expected) |
| B | chip_onewire_test | PASS | 1.6 | RESULT onewire_test: PASS (10/10 cases as expected) |
| C | org192_i2c_test | PASS | 3.7 | RESULT i2c_test: PASS (60/60 cases as expected) |
| C | org192_modbus_test | PASS | 3.8 | RESULT modbus_test: PASS (16/16 cases as expected) |
| C | org192_spi_test | **FAIL** | 6.7 | PASS     chip slave eng1 mode0 256 random bytes half=6clk 1143 mgmt frames (402 TX retries, 12 empty reads), 13033 us | cs_setup=10 lead=6 idle=6 cs_hold=10 MISO setup>=2 hold>=10 MISO_after_shift_edge=4 sample_point_after_edge=1.9 MISO_release=4 first_bit_after_CS=5 |
| C | org64_can_test | PASS | 1.0 | RESULT can_test: PASS (27/27 cases as expected) |
| C | org64_jtag_test | PASS | 0.1 | RESULT jtag_test: PASS (17/17 cases as expected) |
| C | org64_onewire_test | PASS | 0.9 | RESULT onewire_test: PASS (10/10 cases as expected) |
| D | remap1_can_test | PASS | 4.2 | RESULT can_test: PASS (26/26 cases as expected) |
| D | remap1_jtag_test | PASS | 12.8 | RESULT jtag_test: PASS (17/17 cases as expected) |
| D | remap1_modbus_test | PASS | 6.8 | RESULT modbus_test: PASS (16/16 cases as expected) |
| D | remap1_onewire_test | PASS | 2.7 | RESULT onewire_test: PASS (10/10 cases as expected) |
| D | remap2_can_test | PASS | 3.4 | RESULT can_test: PASS (26/26 cases as expected) |
| D | remap2_jtag_test | PASS | 1.7 | RESULT jtag_test: PASS (17/17 cases as expected) |
| D | remap2_modbus_test | PASS | 5.9 | RESULT modbus_test: PASS (16/16 cases as expected) |
| D | remap2_onewire_test | PASS | 2.0 | RESULT onewire_test: PASS (10/10 cases as expected) |
| D | remap3_can_test | PASS | 3.9 | RESULT can_test: PASS (26/26 cases as expected) |
| D | remap3_jtag_test | PASS | 3.0 | RESULT jtag_test: PASS (17/17 cases as expected) |
| D | remap3_modbus_test | PASS | 5.3 | RESULT modbus_test: PASS (16/16 cases as expected) |
| D | remap3_onewire_test | PASS | 1.8 | RESULT onewire_test: PASS (10/10 cases as expected) |
| E | shared_can_test | **FAIL** | 0.0 | Phase 1: engine transmits, bus node + Python decoder check the wire |
| E | shared_i2c_chip | **FAIL** | 0.0 | Phase 5: full chip, host only through the management SPI link |
| E | shared_jtag_test | **FAIL** | 0.0 | Phase 1: JTAG controller on the engine, Verilog TAP model on the pins, Python TAP model as oracle |
| E | shared_modbus_test | **FAIL** | 0.0 | Phase 1: engine 0 transmits Modbus RTU frames (CRC-16 from the CRC unit) |
| E | shared_onewire_test | **FAIL** | 0.0 | Phase 1: 1-Wire master + CRC-8 on the engine, device model on the bus |
| E | shared_spi_chip | **FAIL** | 0.0 | Phase 5: full chip, host only through the management SPI link (master on engine 0, slave on engine 1) |
| E | sharedremap2_can_test | **FAIL** | 0.0 | Phase 1: engine transmits, bus node + Python decoder check the wire |
| E | sharedremap2_jtag_test | **FAIL** | 0.0 | Phase 1: JTAG controller on the engine, Verilog TAP model on the pins, Python TAP model as oracle |
| E | sharedremap2_modbus_test | **FAIL** | 0.0 | Phase 1: engine 0 transmits Modbus RTU frames (CRC-16 from the CRC unit) |
| E | sharedremap2_onewire_test | **FAIL** | 0.0 | Phase 1: 1-Wire master + CRC-8 on the engine, device model on the bus |

45 of 57 suites passed.
