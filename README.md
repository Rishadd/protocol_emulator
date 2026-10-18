# Protocol Emulator

A programmable, PIO-style protocol engine for a Tiny Tapeout CMOS5L ASIC (IHP 130 nm, 6x4 tiles): a small instruction set drives shift registers, FIFOs, eight
GPIO pins, a register file with an ALU and a programmable CRC unit, so UART, SPI, I2C, SMBus, Modbus, 1-Wire, JTAG and CAN are firmware, not RTL.

## Status (2026-10-18)

| | |
|---|---|
| Chip | two identical engines (256-word SRAM instruction memory each, 28 opcodes, 8 x 32-bit registers, ALU, CRC unit), pin manager (ownership, open-drain), SPI management link |
| Protocols (firmware, simulation only) | UART TX / RX / duplex (also on a DE0-Nano), SPI master + slave (4 modes), I2C master + slave, SMBus PEC, Modbus RTU, 1-Wire, JTAG, CAN 2.0A |
| Verification | 26 regression suites all pass; random differential test against a cycle-exact model (0 mismatches); 66 of 66 planted ALU / CRC / engine bugs caught. **All numbers: [docs/TEST_RESULTS.md](docs/TEST_RESULTS.md)** |
| Physical design | Tiny Tapeout flow, two signoff-clean layouts (0 DRC, 0 LVS, TT precheck pass, gate-level test pass, no timing violations at the 30 ns signoff clock): **tt9b** (flat, fastest: slow corner 48.8 MHz, typical 78 MHz) and **tt9c** (symmetric, one fenced column per engine: 43.4 / 70 MHz). Comparison of every change: [docs/TEST_RESULTS.md](docs/TEST_RESULTS.md) section 8.4; images: `results/tt_flow_2026-10-18/index.html` |
| Not done | silicon, FPGA (except UART), USB low speed, CAN arbitration |

Where to read next: [docs/README.md](docs/README.md) is the map of all documents.

## Repository map

| Path | Contents |
|---|---|
| `src/` | RTL. `tt_um_protocol_emulator.v` is the chip top; `engine_top.v` the engine (`control_unit`, `alu_unit`, `crc_unit`, `pc_reg`, FIFOs, shifters, `pin_block`); `isa.vh` the opcode table; `mgmt.v`, `spi_slave.v`, `pin_mgr.v` the management side. `config.json`, `pdn_cfg.tcl`, `floorplan_boxes.json` are the flow configuration. `src/fpga/` holds the DE0-Nano tops and UART images. |
| `tb/` | self-checking Icarus testbenches (unit tests, engine, management link, protocol benches `tb_proto.v` and `tb_chip_proto.v`) and the peer models `peer_*.v`. |
| `host/` | Python: assembler (`asm.py`), ISA model and differential test, CRC model, firmware generators `*_prog.py`, suites `*_test.py`, `regress.py` (runs everything). |
| `test/` | cocotb tests for the Tiny Tapeout flow (RTL and gate level). |
| `librelane/` | flow scripts for WSL (`run_tt_wsl.sh`, `flow_run_wsl.sh`, precheck, gate-level test, images), the custom flow steps (power-stripe bridge, engine fences) and analysis tools. |
| `macro/`, `sim/ihp_sram/` | the SRAM macro views and its functional simulation models. |
| `synth/` | Yosys experiments on the real CMOS5L cell library. |
| `quartus/` | DE0-Nano projects (TX, RX, duplex) and their bitstreams. |
| `docs/` | plans, decisions, results (index in `docs/README.md`). |
| `results/` | kept evidence, one folder per phase (index in `results/README.md`). |
| `instructions.md` | instruction set and firmware of every protocol. |
| `memory.md` | running project notes (what was verified, problems, decisions). |
| `info.yaml`, `LICENSE`, `.github/` | Tiny Tapeout project description, licence, CI workflows. |

## Run

Needs Icarus Verilog (`iverilog` / `vvp`, 12.0) and Python 3.12 or later. The flow needs WSL with Nix (see `docs/TT_FLOW_RESULTS.md`).

```powershell
.\run_tests.ps1                                   # 22 RTL testbenches
python host\regress.py                            # everything: all suites, chip-level and relocated-firmware variants (about 70 min)
python host\isa_diff_test.py                      # random programs: RTL against the Python model, coverage, 24 engine mutants
python host\alu_test.py ; python host\crc_test.py # unit tests + mutants of the new units
python host\spi_test.py | i2c_test.py | i2c_slave_test.py | smbus_test.py | modbus_test.py | onewire_test.py | jtag_test.py | can_test.py
$env:PROTO_CHIP = 1; python host\can_test.py run  # the same suite on the full chip, host only through the management link
$env:FW_ORG = 192; python host\spi_test.py        # firmware relocated to another address (CAN, JTAG, 1-Wire do not fit at 192: use 64)
```

Physical flow (in WSL): `bash librelane/flow_run_wsl.sh <tag> [boxed]` runs the complete flow in `~/pe_<tag>`; `precheck_wsl.sh`, `gl_test_wsl.sh`,
`render_wsl.sh` and `collect_tt_wsl.sh` check and collect it.
