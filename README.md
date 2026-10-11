# Protocol Emulator

Programmable, PIO-style protocol engine: a tiny instruction set drives shift
registers, FIFOs and 8 GPIO pins so any bit-banged serial protocol (UART, SPI,
I2C, JTAG, ...) is firmware, not RTL. Target: a Tiny Tapeout CMOS5L ASIC (6x4 tiles).

**Status (2026-10-12):** two engines with SRAM instruction memory, a pin manager (ownership + open-drain) and an SPI
management link, verified in simulation. Protocols as firmware: UART TX/RX/duplex (also on a DE0-Nano with an HC-05),
SPI master and slave in all 4 modes, I2C master at 100/400/1000 kHz - each tested at engine level, on the full chip
purely through the management link, and SPI + I2C concurrently. Yosys on the CMOS5L library: 150k um^2 (20.8 % of the
6x4-tile area). No LibreLane/GDS run yet. See [docs/EXECUTION_PLAN.md](docs/EXECUTION_PLAN.md),
[docs/CHALLENGE_CHECK.md](docs/CHALLENGE_CHECK.md) and [memory.md](memory.md).

| Path | Contents |
|---|---|
| `src/` | Synthesizable RTL. `tt_um_protocol_emulator.v` is the chip top (2 x `engine_top`, `mgmt`, `spi_slave`, `pin_mgr`); `isa.vh` is the opcode table (21 opcodes). `rx_led_sink.v` is an FPGA/test helper. |
| `src/fpga/` | DE0-Nano tops (TX, RX, full-duplex echo), SDC, UART firmware images (`.hex`). |
| `tb/` | Self-checking Icarus testbenches: unit tests per module, `tb_engine_top`, `tb_engine_ops`, `tb_pin_mgr`, FPGA-top tests, `tb_mgmt_*` for the management link; protocol harnesses `tb_spi_*`, `tb_i2c_*`, `tb_combo_chip` with peers `spi_peer.vh`, `i2c_slave_model.v` and host knobs `host_knobs.vh` (driven by `host/`). |
| `host/` | Python host models: UART reference model / decoder (`uart_workload.py`, `uart_rx_workload.py`, `uart_duplex_workload.py`), RX firmware generator (`uart_rx_prog.py`), the 1 KB full-duplex-over-SPI runner (`mgmt_duplex_stress.py`), SPI and I2C firmware generators (`spi_prog.py`, `i2c_prog.py`) and verification runners (`spi_test.py`, `i2c_test.py`), and the all-protocol workload campaign (`workload.py`). |
| `quartus/` | DE0-Nano projects: one revision each for TX, RX and duplex. |
| `synth/` | Yosys flow onto the real IHP CMOS5L cell library (`run_synth.sh`) plus area-only experiments (SRAM stand-in, latch memory, pin manager). Results: [docs/ASIC_AREA_AND_MEMORY_STUDY.md](docs/ASIC_AREA_AND_MEMORY_STUDY.md). |
| `docs/` | Architecture, execution plan, management-link design, area study, SPI/I2C plans and results, workload results, challenge check, Mermaid diagrams. |
| `results/` | Kept evidence from workload runs (logs + payload). |
| `instructions.md` | **ISA reference and per-protocol programs** (UART TX/RX verified; SPI master/slave and I2C master verified in simulation; JTAG draft) — the contract for the host loader. |
| `memory.md` | Running project notes: what was verified, problems and fixes, decisions. |
| `run_tests.ps1` | Compiles and runs 19 testbenches; prints one `RESULT` line each. |
| `build/` | Generated (ignored). |

## Run

```powershell
.\run_tests.ps1                                   # regression: 19 PASS; tb_de0_nano_top is known to hang (FPGA-only)
python host\uart_workload.py --bauds 9600 115200  # workload sweep, add --limits for stress tests
python host\mgmt_duplex_stress.py                 # 1 KB full duplex through the SPI link (compiles tb_mgmt_duplex itself; iverilog on PATH)
python host\spi_test.py                           # SPI master + slave, all 4 modes, engine and full chip (docs/SPI_PLAN.md); or name phases: selftest peers master slave chip mutants
python host\i2c_test.py                           # I2C master, 100/400/1000 kHz, engine and full chip (docs/I2C_PLAN.md); phases: selftest peers master chip mutants
python host\workload.py                           # UART/SPI/I2C + SPI&I2C concurrently, only through the management link (docs/WORKLOAD_RESULTS.md)
```

Requires Icarus Verilog (`iverilog`/`vvp`, tested with 12.0) and Python 3 (3.12 or later, not the Windows Store stub;
the 2026-10-12 runs used miniconda's Python 3.14). Chip-level hosts must claim pads first (`0x0200+4p`, see MGMT_PLAN).

Area/cell-count estimate (needs the OSS CAD Suite and the CMOS5L liberty files; paths are set in `synth/synth_cmos5l.tcl`):

```bash
synth/run_synth.sh baseline                       # whole chip, hierarchy kept -> build/synth/baseline.stat.txt
```
