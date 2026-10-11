# Protocol Emulator

Programmable, PIO-style protocol engine: a tiny instruction set drives shift
registers, FIFOs and 8 GPIO pins so any bit-banged serial protocol (UART, SPI,
I2C, JTAG, ...) is firmware, not RTL. Target: a Tiny Tapeout CMOS5L ASIC (6x4 tiles).

**Status (2026-10-11):** two engines plus an SPI management link are verified in simulation; UART TX, RX and
full-duplex echo at 115200 run on a DE0-Nano with an HC-05 module. Yosys on the real CMOS5L cell library shows the
flop-based instruction memory is 80 % of the chip, so SRAM is the next architecture decision. No LibreLane/GDS run yet.
See [docs/EXECUTION_PLAN.md](docs/EXECUTION_PLAN.md) and [memory.md](memory.md).

| Path | Contents |
|---|---|
| `src/` | Synthesizable RTL. `tt_um_protocol_emulator.v` is the chip top (2 x `engine_top`, `mgmt`, `spi_slave`); `isa.vh` is the opcode table. `rx_led_sink.v` is an FPGA/test helper. |
| `src/fpga/` | DE0-Nano tops (TX, RX, full-duplex echo), SDC, UART firmware images (`.hex`). |
| `tb/` | Self-checking Icarus testbenches: unit tests per module, `tb_engine_top`, FPGA-top tests, and `tb_mgmt_*` for the SPI management link. Workload and duplex testbenches are driven by `host/`. |
| `host/` | Python host models: UART reference model / decoder (`uart_workload.py`, `uart_rx_workload.py`, `uart_duplex_workload.py`), RX firmware generator (`uart_rx_prog.py`), and the 1 KB full-duplex-over-SPI stress runner (`mgmt_duplex_stress.py`). |
| `quartus/` | DE0-Nano projects: one revision each for TX, RX and duplex. |
| `synth/` | Yosys flow onto the real IHP CMOS5L cell library (`run_synth.sh`) plus area-only experiments (SRAM stand-in, latch memory, pin manager). Results: [docs/ASIC_AREA_AND_MEMORY_STUDY.md](docs/ASIC_AREA_AND_MEMORY_STUDY.md). |
| `docs/` | Architecture, execution plan, workstream plans, management-link design, area study, Mermaid diagrams. |
| `results/` | Kept evidence from workload runs (logs + payload). |
| `instructions.md` | **ISA reference and per-protocol programs** (UART TX/RX verified; SPI, I2C, JTAG drafts) — the contract for the host loader. |
| `memory.md` | Running project notes: what was verified, problems and fixes, decisions. |
| `run_tests.ps1` | Compiles and runs 17 testbenches; prints one `RESULT` line each. |
| `build/` | Generated (ignored). |

## Run

```powershell
.\run_tests.ps1                                   # regression: 16 PASS; tb_de0_nano_top is known to hang (FPGA-only)
python host\uart_workload.py --bauds 9600 115200  # workload sweep, add --limits for stress tests
python host\mgmt_duplex_stress.py                 # 1 KB full duplex through the SPI link (compiles tb_mgmt_duplex itself; iverilog on PATH)
```

Requires Icarus Verilog (`iverilog`/`vvp`, tested with 12.0) and Python 3 (the global 3.12, not the Store stub).

Area/cell-count estimate (needs the OSS CAD Suite and the CMOS5L liberty files; paths are set in `synth/synth_cmos5l.tcl`):

```bash
synth/run_synth.sh baseline                       # whole chip, hierarchy kept -> build/synth/baseline.stat.txt
```
