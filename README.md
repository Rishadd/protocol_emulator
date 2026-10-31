# Protocol Emulator

A programmable, PIO-style protocol engine for a Tiny Tapeout CMOS5L ASIC (IHP 130 nm, 8x4 tiles): a small instruction set drives shift registers, FIFOs, eight
GPIO pins, a register file with an ALU, a programmable CRC unit and a USB-style line coder, so UART, SPI, I2C, SMBus, Modbus, 1-Wire, JTAG, CAN, USB low speed,
WS2812, PS/2 and SWD are firmware, not RTL.

## Status (2026-10-31)

| | |
|---|---|
| Chip (`main`) | two identical engines (31 opcodes 0-30, opcode 31 is the trap word; 8 x 32-bit registers, ALU, CRC unit, line coder, incl. REGION and TSTAMP / trigger line) fetching from **one shared 512-word x 32 2-port SRAM macro** (`imem_shared.v`, a window per engine set by `REGION`), pin manager (ownership, remap, open-drain, input select, HOLD, IRQ, debug views), SPI management link (frame v1 and v2 with CRC-16), optional on-chip logic analyser (`-DLA`, not in the current layout) |
| Protocols (firmware, simulation-verified) | UART TX / RX / duplex, SPI master + slave (4 modes), I2C master + slave, SMBus PEC, Modbus RTU, 1-Wire, JTAG, CAN 2.0A, USB low speed (device), WS2812, PS/2, SWD. On a real FPGA board: UART; the whole chip is prepared for the DE0-Nano (`src/fpga/de0_nano_chip_top.v`) but not yet run on hardware |
| Verification | **70 of 70 regression suites pass** (`results/regression_2026-10-30/summary.md`, phases A-F: unit and protocol suites, chip level through the SPI link, relocated firmware, pins remapped, shared memory, logic analyser, frame v2). Random differential tests of RTL against `host/isa_model.py` (0 mismatches), planted-bug (mutant) campaigns that must all be caught, 6 formal proofs (`formal/`). Older detailed tables: [docs/TEST_RESULTS.md](docs/TEST_RESULTS.md) (state of 2026-10-18) |
| Physical design | Tiny Tapeout flow on 8x4 tiles. Current recipe **sh8 / sh10**: shared memory, matched power grid, 17 ns constraint, three-column floorplan (`src/floorplan_engines_shared3.json`). sh10: 19.71 ns (50.7 MHz) at the slow corner, +0.29 ns slack at a real 20 ns clock, LVS clean, 0 DRC, 0 antenna, hold met; 27 max-slew / 30 max-cap violations still to be judged. Details: [docs/PROGRESS_REPORT_2026-10-18_to_2026-10-20.md](docs/PROGRESS_REPORT_2026-10-18_to_2026-10-20.md), [reproduce/flows/README.md](reproduce/flows/README.md) |
| Not done | silicon; the logic analyser in a layout (needs a third macro placement) and its phases 4-8; Tiny Tapeout precheck on sh10; CAN arbitration; more FPGA demos; user-guide placeholders. Open list: [docs/TODO.md](docs/TODO.md) |

**Start here:** [docs/CODE_GUIDE.md](docs/CODE_GUIDE.md) explains the whole project file by file, from the PC to a pin. [docs/README.md](docs/README.md) is the map of all documents.
The full chronological story (what was done, decided and why) is [memory.md](memory.md).
User guide (draft, with figures): [docs/USER_GUIDE.md](docs/USER_GUIDE.md) and the HTML version [docs/USER_GUIDE.html](docs/USER_GUIDE.html) (built by `python3 docs/build_user_guide.py`).

## Repository map

| Path | Contents |
|---|---|
| `src/` | RTL. `tt_um_protocol_emulator.v` is the chip top; `engine_top.v` the engine (`control_unit`, `alu_unit`, `crc_unit`, `pc_reg`, `fifo`, `shift_reg`, `delay_counter`, `loop_counter`, `line_coder`, `pin_block`); `isa.vh` the opcode table; `imem_shared.v` the shared instruction memory (`instr_mem.v` is the older private-memory variant, used without `SHARED_IMEM`); `mgmt.v`, `spi_slave.v`, `pin_mgr.v`, `dbg_view.v` the management side; `la_block.v`, `la_unit.v` the optional logic analyser. Flow configuration: `config.json`, `pnr.sdc`, `pdn_cfg.tcl`, `floorplan_engines_shared3.json`. `src/fpga/` holds the DE0-Nano tops (`de0_nano_chip_top.v` = whole chip), the block-RAM stand-in `sram2p_fpga.v` and the UART images. |
| `tb/` | self-checking Icarus testbenches (one per block, engine, management link, `tb_proto.v` and `tb_chip_proto.v` protocol benches, shared-memory and logic-analyser benches), peer models `peer_*.v`, include files `tb_common.vh`, `spi_master.vh`, `shared_imem.vh`. |
| `host/` | Python. Assembler `asm.py`; models `isa_model.py`, `crc_model.py`, `line_model.py`, `la_model.py`, `can_model.py`, `bus_model.py`; firmware generators `*_prog.py` (one per protocol) and suites `*_test.py`; `regress.py` runs everything. Driving the chip: `chip_host.py` (`ChipHost`, `SimLink`), `shmem_host.py` (placing images in the shared memory), `serial_link.py` + `pico_bridge.py` (real hardware), `fpga_bringup.py`, `la_host.py` + `la_capture.py` (logic analyser, VCD for GTKWave). Mutation tools: `mutation.py`, `*_mutants.py`. |
| `test/` | cocotb tests for the Tiny Tapeout flow (RTL and gate level; built for the shared-memory chip, program at 0x0400). |
| `formal/` | SymbiYosys proofs: FIFO, engine, management, pin manager, shared-memory windows, region-go. |
| `librelane/`, `librelane_plugin_project/` | flow scripts (Linux and WSL variants: run, precheck, gate-level test, pictures, analysis tools) and the custom flow steps (power-stripe bridge, module regions). |
| `macro/`, `sim/ihp_sram/` | the SRAM macro views and the manufacturer simulation models. |
| `synth/` | early Yosys area experiments on the real cell library. |
| `quartus/` | DE0-Nano Quartus projects (`pe_chip` = whole chip; UART TX, RX, duplex) and bitstreams. |
| `reproduce/` | the reproduction kit: numbered scripts (install tools, sources, tests, formal, flow, precheck, docs), tool versions, and the archive of every timing run `flows/sh4 ... sh10`. |
| `docs/` | plans, decisions, results (map in `docs/README.md`). |
| `results/` | kept evidence, one folder per phase (index in `results/README.md`). |
| `instructions.md` | instruction set and firmware of every protocol. |
| `memory.md` | the project story in date order, decisions, tests, numbers, catalogue of every file. |
| `info.yaml`, `LICENSE`, `.github/workflows/` | Tiny Tapeout project description, licence, CI (`test`, `gds`, `docs`, `fpga`). |

## Run

Needs Icarus Verilog (`iverilog` / `vvp`, 12.0) and Python 3.12 or later. Development moved from Windows/WSL to native Ubuntu on 2026-10-20; the install steps are in `reproduce/01_install_tools.sh`.

```bash
bash run_tests.sh                              # 22 RTL unit testbenches (run_tests.ps1 is the Windows twin)
python3 host/regress.py                        # everything: 70 suites, phases A-F (about 70 min on 16 cores)
python3 host/isa_diff_test.py                  # random programs: RTL against the Python model, coverage, engine mutants
python3 host/alu_test.py ; python3 host/crc_test.py
python3 host/spi_test.py                       # likewise i2c_test, i2c_slave_test, smbus_test, modbus_test, onewire_test, jtag_test, can_test, usb_test, ...
PROTO_CHIP=1 python3 host/can_test.py run      # the same suite on the full chip, host only through the management link
FW_ORG=192 python3 host/spi_test.py            # firmware relocated to another address (CAN, JTAG, 1-Wire do not fit at 192: use 64)
python3 host/fpga_bringup.py --sim             # first checks on the chip, in simulation (--port /dev/ttyACM0 for the board)
python3 host/la_capture.py --sim --demo --out capture.vcd   # logic analyser demo, open with GTKWave
cd test && make                                # cocotb test, as the GitHub `test` workflow runs it
bash formal/run_formal_linux.sh                # formal proofs
```

Physical flow: `bash reproduce/05_run_flow.sh <tag>` (or `librelane/flow_variant_linux.sh`), then `reproduce/06_precheck_and_reports.sh <tag>`; the older WSL scripts
(`librelane/flow_run_wsl.sh`, `precheck_wsl.sh`, `gl_test_wsl.sh`, `collect_tt_wsl.sh`) are kept. `reproduce/README.md` lists every step.

## Branches

`main` holds the current chip (shared memory, frame v2, pin mapping, line coder, logic analyser RTL) and everything above. `check/shared-sh8` is the branch pushed to run the official GitHub
workflows; `shared/on-v2` is the working branch of the shared-memory and analyser work; `exp/fetch-stage` is a verified experiment that gave no timing gain and was not merged.
