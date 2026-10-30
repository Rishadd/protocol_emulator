# Project memory: the Protocol Emulator chip, from the first line of code to today (2026-10-20)

**Who this is for.** Someone who has never seen this project. Part A explains it in plain words; Parts B and C give the history in date order with every test, error, fix and decision; Parts D to F are look-up tables (documents, tests, numbers, open work). Technical readers can skip the plain-language bits, non-technical readers can skip the technical details in the "Technical" lines: each entry is written so the first sentences make sense on their own.
**Nothing was thrown away.** The previous, unordered version of this file (every old note, word for word) is kept as [docs/MEMORY_RAW_LOG_until_2026-10-20.md](docs/MEMORY_RAW_LOG_until_2026-10-20.md). Newer facts than the dates in it are only here.
**Other entry points:** [docs/README.md](docs/README.md) (map of all documents), [docs/TEST_RESULTS.md](docs/TEST_RESULTS.md) (every test number), [docs/TODO.md](docs/TODO.md) (checklist), [reproduce/README.md](reproduce/README.md) (how to repeat every result), [docs/USER_GUIDE.md](docs/USER_GUIDE.md) (guide for chip users, still a draft).

---------------------------------------------------------------------------------------------------

# PART A. What this project is

## A1. In plain language
A **protocol** is an agreed way for two electronic devices to talk over wires (UART is what a serial port speaks, SPI and I2C connect chips to each other, USB and CAN connect computers and cars). Normally a chip contains one fixed circuit per protocol. This project builds a chip with **no fixed protocol circuits**. Instead it has two tiny **processors ("engines")** that can switch the pins on and off and watch them with exact timing, one clock tick at a time. A **program ("firmware")** loaded into the chip makes an engine behave as UART, SPI, I2C, USB, CAN and so on. New protocols later mean only a new program, not a new chip. A small **management link** (a normal SPI connection, driven by a Raspberry Pi Pico or a PC) loads programs, starts and stops the engines and exchanges data.

The work is an entry in the **Jane Street "protocol emulator" ASIC challenge**: design such a chip as open source and have it made on a Tiny Tapeout shared silicon run (IHP 130 nm "CMOS5L" process). Text of the challenge: [Challenge_general_instructions.md](Challenge_general_instructions.md). Key rules: design must fit 6x4 Tiny Tapeout tiles (8x4 may be allowed later; the user decided we may use 8x4), must be open source, deadline **2027-01-18**. The user's own working deadline: **chip ready by 2026-12-30** (design frozen 2026-12-13, final layout runs 12-14 to 12-27, January = documentation only).

Two ideas run through the whole project and explain most of the testing:
1. **"Prove it" culture.** Nothing counts as working until it was checked against something independent: a second, separately written model of the engine, "peer" models of the other end of each protocol written from the official specifications, random testing, deliberately broken copies of the design ("mutants", every test must catch every one), and mathematical proofs (formal verification). The challenge explicitly asks for such verification techniques.
2. **Simulation first, hardware second.** Everything is tested in simulation (Icarus Verilog + Python) before an FPGA board or a layout run is used.

## A2. What the user (project owner) wanted, in the user's own priorities
- A real programmable engine, not a bag of fixed blocks; UART, SPI, I2C first, then USB low speed and Ethernet 10BASE-T as stretch goals, plus JTAG, SWD, PS/2, CAN and "anything else the architecture makes possible".
- Maximum verification strength (formal proofs, mutation tests, random tests) because the challenge highlights it.
- About 50 MHz clock on the real silicon-like timing check, with a floorplan that "looks meaningful" and not like a random mess.
- A **shared 512-word instruction memory** as the base of the chip (decision of 2026-10-20) so any future protocol, even a standalone USB device or Ethernet, fits; a **logic analyser** (records pin activity, viewed in GTKWave) built on top of it.
- Documentation good enough that anyone can use and reproduce the chip.

## A3. Glossary (short; technical readers skip)
| Term | Meaning here |
|---|---|
| Engine | one of the two tiny processors in the chip; runs one instruction per clock; 28+ instruction types (opcodes) |
| Firmware / image | the program loaded into an engine (UART, SPI ... each is one) |
| ISA / opcode | instruction set / one instruction type (e.g. WAIT, OUT1, CRC) |
| FIFO | small first-in-first-out buffer (4 words) that carries data between host and engine |
| Management link / host | the SPI connection through which a Pico or PC controls the chip / the Pico or PC itself |
| Frame v1 / v2 | the message format on the management link: v1 simple (7 bytes), v2 safer (12 bytes, error check CRC-16, sequence numbers) |
| Pin manager | block that decides which engine owns which pin, remaps pins, open-drain mode, flags mistakes |
| SRAM macro | a ready-made block of memory from the manufacturer (instead of building memory from flip-flops) |
| Tiny Tapeout (TT), tile | the service that puts many student chips on one wafer; a tile is the unit of area (6x4 = 24 tiles) |
| RTL | the chip's design written in Verilog |
| Flow / LibreLane / OpenROAD | the automatic tool chain that turns RTL into a physical layout (GDS file) |
| DRC / LVS / antenna / precheck | layout rule check / layout-versus-circuit check / charge-damage rule / Tiny Tapeout's own acceptance check |
| Slack, slow corner, setup / hold | timing margin in nanoseconds (positive = OK); worst-case operating condition (1.08 V, 125 C); "setup" = signal must arrive early enough, "hold" = must not change too early |
| Constraint | the clock period we ask the tool to meet (it can differ from the real clock) |
| Floorplan, macro placement | where blocks and memories sit on the die |
| Regression | the complete set of tests run together; "phase A-F" are groups of it |
| Mutant | a deliberately broken copy of the design or firmware; a good test fails on it ("caught") |
| Differential test | same random program run in the real RTL and in the Python model; every clock must agree |
| Formal proof (SymbiYosys) | mathematical proof that a property always holds, for all inputs |
| Peer model | independent model of the other end of a protocol (e.g. an I2C slave) written from the spec |
| Logic analyser (LA) | hardware block recording what the pins did, readable by the host as a waveform file (VCD) |
| Branch (git) | a separate line of development; `main` = the verified base, `shared/on-v2` = shared-memory chip + logic analyser |

## A4. Where things stand today (2026-10-20, late evening)
| Area | State |
|---|---|
| Protocols (firmware, simulation-verified) | 13: UART, SPI (master+slave), I2C (master+slave), SMBus, Modbus RTU, 1-Wire, JTAG, CAN 2.0A, USB low speed (device), WS2812, PS/2, SWD. On a real FPGA board: UART only |
| Main verification | regression of 47 suites passes on `main`; 4 formal proofs (6 on the shared branch); thousands of planted-bug checks all caught |
| Chip variants | `main`: two private 256-word memories (2 macros), frame v2, pin mapping, line coder, 8x4 tiles, layout run tt14b clean. `shared/on-v2` (local branch, base for the future): one shared 512-word memory, TSTAMP, trigger line, logic analyser block (not yet in a layout) |
| Best layout so far | **sh8**: shared memory, 8x4 tiles, 19.64 ns achieved at the slow corner (50.9 MHz), LVS clean, 0 DRC; positive slack (+0.36 ns) at a 20 ns real clock |
| GitHub check | branch `check/shared-sh8` pushed 2026-10-20 evening to run the official workflows (result visible only on GitHub's Actions page) |
| Docs | 34 documents in `docs/`, a user-guide draft with 47 figures, a `reproduce/` folder |
| Not done yet | logic analyser phases 4-8 (engine debug, sniffers, formal proofs of the analyser, layout with its third macro, host tool), mutation campaign + timing checker, more FPGA demos, final RTL freeze 12-13, final signoff runs |

## A5. How the user and the assistant work together (standing rules)
- Do **not** send the Tiny Tapeout email; do **not** question the SRAM macros (the user decided they are fine); 8x4 tiles are allowed.
- Run each long job (flow, regression) in **its own visible terminal window** with a live log; watch jobs only with **monitors**, never by polling terminals; "don't wait online": start a monitor and continue with other work.
- Keep `memory.md` and the docs updated; keep a checkable to-do list (docs/TODO.md).
- Commits: author "Rishadd Ranjith", trailer `Co-Authored-By: Claude Sonnet 5.5 <noreply@anthropic.com>`; `[skip ci]` on commits that should not start GitHub workflows; **push only when the user says so** (the repository is private since 2026-10-20).
- The user's own edit of `LICENSE` is never overwritten.

---------------------------------------------------------------------------------------------------

# PART B. The history, in date order (2026-10-01 to 2026-10-19)

Format of each entry: **Why** (what was wanted / who asked) -> **What was built** -> **Tests and why** -> **Problems found and how they were fixed** -> **Result / outcome**. Dates are those of the notes and commits.

## B1. 2026-10-01 to 2026-10-08: the engine and UART on a real FPGA
- **Why:** first prove the idea: a small engine whose *program* is the protocol. Target: DE0-Nano FPGA board at 50 MHz talking to a phone through an HC-05 Bluetooth module.
- **Built:** "protocol engine v0.1" (commit 40cc482, 10-01): a PIO-style processor (like the Raspberry Pi RP2040's PIO) with 21 instruction types, a 64-word program memory, four-word FIFOs, 8 pins; UART transmit (12 instructions) and receive (9 instructions) as *firmware*, no UART hardware. Docs aligned with the implemented design (10-03). FPGA wrappers and a Quartus project (10-03 to 10-05), "project works with FPGA" (10-05), full duplex UART at 115200 baud on real hardware (10-08).
- **Tests and why:** a Python "fake phone" produces the waveform, the real RTL runs in Icarus Verilog, Python compares the result; only after that was anything compiled for the FPGA ("nothing went to the FPGA unverified"). TX matched a Python reference cycle-exactly at 8 baud rates.
- **Problems and fixes:** (1) RX saw a fake start bit after reset because the input synchroniser resets to 0 -> fixed in firmware (wait for the line to be high first). (2) With LSB-first shifting the received byte lands in bits [31:24] of the FIFO word -> LED sink reads there. (3) Tool setup: old Icarus could not build the testbenches and a stale 32-bit DLL crashed vvp -> clean Icarus 12 install; Quartus not on PATH; `python` was a Store stub. (4) One Quartus compile ran without the clock constraint -> always check slack after a compile (RX +12 ns).
- **Decisions:** no stop-bit check in RX (RX tolerates about -4.5 % / +6 % baud error); each FPGA build its own Quartus revision; engine RTL not changed for these fixes.
- **Outcome:** phone received the TX message; a byte sent from the phone showed on the 8 LEDs. **This is the only protocol tested on real hardware to date.**
- **Files (exact names):** `src/engine_top.v`, `src/control_unit.v`, `src/pc_reg.v`, `src/delay_counter.v`, `src/loop_counter.v`, `src/fifo.v`, `src/shift_reg.v`, `src/pin_block.v`, `src/instr_mem.v`, `src/isa.vh`; FPGA: `src/fpga/de0_nano_top.v` (TX), `src/fpga/de0_nano_rx_top.v` (RX), `src/fpga/de0_nano_duplex_top.v` (duplex), `src/fpga/msg_sender.v`, `src/rx_led_sink.v`, `src/fpga/de0_nano.sdc`, `src/fpga/uart_tx_prog.hex`, `src/fpga/uart_rx_prog.hex`, `quartus/protocol_emulator_fpga.qpf/.qsf`, `quartus/protocol_emulator_rx.qsf`, `quartus/protocol_emulator_duplex.qsf`; tests: `tb/tb_uart_workload.v`, `tb/tb_uart_rx.v`, `tb/tb_uart_duplex.v`, `tb/tb_de0_nano_top.v`, `tb/tb_de0_nano_rx_top.v`, `tb/tb_engine_top.v`, `tb/tb_instr_mem.v`, `tb/tb_pc_reg.v`, `tb/tb_delay_counter.v`, `tb/tb_loop_counter.v`, `tb/tb_fifo.v`, `tb/tb_shift_reg.v`, `tb/tb_pin_block.v`, `tb/tb_rx_led_sink.v`, `tb/tb_control_unit.v`, `run_tests.ps1`; Python: `host/uart_workload.py`, `host/uart_rx_workload.py`, `host/uart_rx_prog.py`, `host/uart_duplex_workload.py`; evidence `results/uart_workload_2026-10-01/payload.bin`, `sweep_log.txt`; documents `docs/WORKSTREAM1_ARCHITECTURE.md`, `docs/WORKSTREAM2_RTL_IMPLEMENTATION.md`, `docs/PROTOCOL_EMULATOR_ARCHITECTURE.md`, `instructions.md`.

## B2. 2026-10-11: the management link (SPI), steps 1-8 (simulation only)
- **Why:** programs must be loadable and the chip controllable by a host (Pico/PC) over a few pins, because later the memory will not be loadable any other way. Plan: [docs/MGMT_PLAN.md](docs/MGMT_PLAN.md), eight steps agreed with the user.
- **Built, step by step:** (1) instruction memory got a write port; (2) `spi_slave` (SPI mode 0) + a minimal `mgmt` block + the Tiny Tapeout top-level pins (`ui_in[0..2]` = SCLK/MOSI/CS_N, `uo_out[0]` = MISO); (3) **frame v1**: 7 bytes `{op, address(2), data(4)}`, big endian, a write commits only on the CS_N rising edge of a complete frame; `RUN` bit holds an engine in reset; (4) full program loads over SPI; (5) a **second engine** (address 0x2000), pin conflicts resolved temporarily by "engine 0 wins"; (6) reads (STATUS byte + data) including popping the RX FIFO without torn or lost bytes; (7) TX FIFO writes with host flow control; (8) a full-duplex stress test (1 KB over 115200 baud, both directions at the same time, with jitter and peer baud errors).
- **Tests and why:** one testbench per step (`tb_mgmt_frame`, `_load`, `_dual`, `_read`, `_tx`, `tb_mgmt_duplex`), each with golden engines in lockstep (a second engine loaded by `$readmemh` must match every clock), plus deliberately broken versions ("mutations") that each test must catch.
- **Problems and fixes:** a read-decode bug (must use the frame position after 3 bytes); a UART model that sampled on a zero-width simulation glitch (lesson: models must sample on clock edges, because pad multiplexing makes 0-ns glitches).
- **Outcome:** 16 testbenches pass; the full-duplex run delivered 1024/1024 bytes in all good cases; overload cases lose data as predicted (documented).
- **Files (exact names):** `src/spi_slave.v`, `src/mgmt.v`, `src/tt_um_protocol_emulator.v`, `src/engine_top.v`, `src/instr_mem.v`; tests `tb/tb_mgmt_frame.v`, `tb/tb_mgmt_load.v`, `tb/tb_mgmt_dual.v`, `tb/tb_mgmt_read.v`, `tb/tb_mgmt_tx.v`, `tb/tb_mgmt_duplex.v`, `tb/spi_master.vh`, `host/mgmt_duplex_stress.py`; plan `docs/MGMT_PLAN.md`; run script `run_tests.ps1`.

## B3. 2026-10-11: area study and SRAM instruction memory
- **Why:** the chip must fit in the Tiny Tapeout area. Question: where does the area go? ([docs/ASIC_AREA_AND_MEMORY_STUDY.md](docs/ASIC_AREA_AND_MEMORY_STUDY.md))
- **Finding:** with flip-flop memories the chip is 414,137 um2 (57.5 % of the 6x4 allowance), 80 % of it the two instruction memories. Using the manufacturer's SRAM macros instead: about 143k um2 (20 %).
- **Built (commit 1f7f61a):** instruction memory = two 1P 64x16 macros per engine; because SRAM reads are synchronous the program counter now outputs the *next* address ("next_pc"), so the instruction still arrives on time. FIFO strobes had to be masked when an engine is stopped.
- **Tests:** new `tb_fetch_equiv` runs the new engine in lockstep against the old flip-flop engine (0 mismatches); all UART and SPI full-duplex tests repeated (identical counts).
- **Open at the time:** whether Tiny Tapeout accepts these macros on this process (the user later decided: do not question it).
- **Outcome:** chip 414,137 -> 143,421 um2 (-65 %).
- **Files (exact names):** `docs/ASIC_AREA_AND_MEMORY_STUDY.md`, `docs/SRAM_INSTR_MEM_RESULTS.md`; area tools `synth/run_synth.sh`, `synth/synth_cmos5l.tcl`, `synth/experiments/instr_mem_latch.v`, `synth/experiments/instr_mem_sram_2x1p64x16.v`, `synth/experiments/pin_mgr.v`; RTL `src/instr_mem.v`, `src/pc_reg.v` (next_pc), `src/engine_top.v`; simulation models `sim/ihp_sram/RM_IHPSG13_1P_64x16_c2.v`, `sim/ihp_sram/RM_IHPSG13_1P_core_behavioral.v`; tests `tb/tb_fetch_equiv.v` with `tb/ref/ref_engine.v` (the frozen old engine), `tb/tb_instr_mem.v`, `tb/tb_pc_reg.v`.

## B4. 2026-10-11: SPI master and slave as firmware
- **Why:** second protocol of the challenge ([docs/SPI_PLAN.md](docs/SPI_PLAN.md), results [docs/SPI_RESULTS.md](docs/SPI_RESULTS.md)).
- **Architectural change (asked for in the plan):** two new instructions `JPH`/`JPL` (jump if a pin is high/low) because polling a pin without branching costs too many instructions.
- **Built:** master 17/18 words, slave 18/16 words, all four SPI modes, 1-32 bits per frame, bit order either way.
- **Tests:** a Verilog peer and a Python decoder, 312 cases including mutants (64 planted bugs caught); timing measured to the clock.
- **Problems and fixes:** X->0 at reset counted as a clock edge; chip-level pads needed `assign #1` to hide zero-width pulses; the slave's response time had to become a measured limit; "CS setup" had to be defined as CS-fall to first edge or the sweep never stressed it.
- **Result:** exact master timing in all modes; slave limits measured (half period >= 4/5 clocks...); at chip level the slave needs about 2 management frames per SPI frame.
- **Files (exact names):** `host/spi_prog.py`, `host/spi_test.py`, `tb/spi_peer.vh`, `tb/tb_spi_engine.v`, `tb/tb_spi_chip.v`, `src/control_unit.v` + `src/isa.vh` (JPH/JPL), `docs/SPI_PLAN.md`, `docs/SPI_RESULTS.md`, `results/spi_2026-10-11/full_run.txt`.

## B5. 2026-10-11 to 12: I2C master and the pin manager
- **Why:** third mandatory protocol; I2C needs open-drain pins and clock stretching, which forced a pin-ownership design ([docs/I2C_PLAN.md](docs/I2C_PLAN.md)). User approved the plan items D1-D8.
- **Architectural changes (all justified as reusable):** `JPO` (jump on the next output bit) and `PUSHI` (push an immediate value into the RX FIFO, used for event codes); a **pin manager** (`src/pin_mgr.v`): each pad owned by none/engine 0/engine 1, claim refused while the owner runs, per-pad open-drain, sticky "violation" flags. Consequence the user accepted: all chip-level tests had to claim pads first (done in a regression pass, decision D7).
- **Decision D8:** I2C *slave* not implemented yet (my first size estimate "<= 50 words" was wrong; about 64-67 words needed; later easy after the memory grew to 256 words).
- **Tests:** `tb_pin_mgr` (768 mux combinations), `tb_mgmt_pins`; I2C master: self-test 12/12, peers 7/7, master 24/24, chip 10/10, mutants 7/7, all checked against the I2C specification minimums at 100/400/1000 kHz.
- **Problems and fixes:** the slave model counted the SCL fall after START; the decoder must commit bits on SCL fall; a period padding bug (one SCL period 2499 ns at 400 kHz, 1 clock short) and a float rounding bug (25 clocks became 26) fixed in the generator.
- **Workload campaign (10-12, [docs/WORKLOAD_RESULTS.md](docs/WORKLOAD_RESULTS.md)):** long runs with host knobs (bursts, aborted frames, noise reads): UART 13/13, SPI+I2C+both together 42/42. Findings kept as documented limits: UART RX takes a 1 us glitch as a start bit, baud tolerance about -5 %/+4 %, SPI slave needs wide CS spacing when the host is slow.
- **Outcome:** three functional protocols (UART, SPI, I2C) with a growing instruction set; chip area with pin manager 150,000 um2.
- **Files (exact names):** `src/pin_mgr.v`, `src/mgmt.v` (window 0x0200), `src/control_unit.v` + `src/isa.vh` (JPO, PUSHI), `src/engine_top.v`; firmware `host/i2c_prog.py`; tests `host/i2c_test.py`, `host/i2c_slave_test.py`, `host/smbus_test.py`, `tb/i2c_slave_model.v`, `tb/tb_i2c_engine.v`, `tb/tb_i2c_chip.v`, `tb/tb_pin_mgr.v`, `tb/tb_mgmt_pins.v`, `tb/tb_engine_ops.v`, `tb/tb_combo_chip.v`, `tb/host_knobs.vh`, `host/workload.py`; documents `docs/I2C_PLAN.md`, `docs/I2C_RESULTS.md`, `docs/WORKLOAD_RESULTS.md`, `docs/CHALLENGE_CHECK.md`; evidence `results/i2c_2026-10-11/full_run.txt`, `results/workload_2026-10-12/*`.

## B6. 2026-10-17: 256-word instruction memory per engine
- **Why:** bigger firmwares (I2C slave, later USB, CAN). Results: [docs/BIGMEM_RESULTS.md](docs/BIGMEM_RESULTS.md).
- **Architectural change:** one 1P 256x32 macro per engine; 8-bit program counter; the JPH/JPL pin field moved to bits [10:8]; instruction window moved to address base+0x400.
- **Tests and why:** every protocol suite re-run (same results as with 64 words), firmware relocated to other addresses (`FW_ORG`) to prove position independence, lockstep against a 256-word flip-flop reference (0 mismatches in 5.8 million clocks).
- **Problems:** four places in the test harness silently assumed 64 words (e.g. a drain loop waiting for pc == 3, a mutant patching `len(ws)-2`, a test cycle budget eaten by loading 512 words); a program-counter truncation mutant survived until a test used pc >= 64.
- **Files (exact names):** `src/instr_mem.v`, `src/pc_reg.v`, `src/control_unit.v`, `src/isa.vh`, `src/mgmt.v`, `macro/RM_IHPSG13_1P_256x32_c2_bm_bist/*`, `sim/ihp_sram/RM_IHPSG13_1P_256x32_c2_bm_bist.v`, `sim/ihp_sram/RM_IHPSG13_1P_core_behavioral_bm_bist.v`, `host/fw_layout.py` (FW_ORG), `host/spi_prog.py` + `host/i2c_prog.py` (JPH/JPL shift), `docs/BIGMEM_RESULTS.md`, `results/bigmem_2026-10-17/*`.

## B7. 2026-10-17: first physical-design (layout) run
- **Why:** find out whether the design routes at all. LibreLane (open-source chip layout flow) in a Nix shell inside WSL ([docs/LIBRELANE_RESULTS.md](docs/LIBRELANE_RESULTS.md)).
- **Result:** a layout completes: setup +7.86 ns at a 20 ns constraint, LVS clean, 0 routing DRC errors; Magic DRC errors only inside the SRAM macros (ignored as in the reference SRAM design); 78 max-slew / 30 max-cap violations left. Not yet the official Tiny Tapeout flow (own die size).
- **Setup lessons:** LibreLane "dev" branch needed (the release could not read this PDK), `--manual-pdk`, always `bash -lc` in WSL, `$VAR` expansion by wsl.exe; routing shorts on TopMetal1 and a Metal4 cap made things worse, placement density 50 % routed clean.
- **Files (exact names):** `librelane/config.json`, `librelane/run_wsl.sh`, `librelane/collect_wsl.sh`, `librelane/macro/RM_IHPSG13_1P_256x32_c2_bm_bist.v`, `docs/LIBRELANE_RESULTS.md`, `results/librelane_2026-10-17/run1`, `run3`.

## B8. 2026-10-18: the Tiny Tapeout flow, timing, formal proofs (a very long day)
**1. Why the first Tiny Tapeout runs never finished clean (root-cause analysis).** Wrong SRAM timing model in the slow corner, 0.25 ns clock uncertainty on hold (4,260 hold buffers), SRAMs acting as routing walls under the pins, repair after global routing, timing-driven placement off, and the CRC byte step sitting in the fetch cycle. All fixed in configuration, `src/pnr.sdc`, floorplan, and RTL.
**2. Register/ALU/CRC extension (new instructions 21-28) and pipelined CRC.** The engine got 8 general registers, an ALU (13 functions), a CRC unit supporting any width/polynomial (verified against 14 published CRC models), `RGET`/`RPUT`, `WAITR`, `LDI`, `JCC`. The CRC unit was pipelined for speed (command register; `RGET CRC` right after `CRC` waits 1 clock). Tests: ALU unit tests (28 planted bugs), CRC tests (3,280 random vectors, 14 planted bugs), differential test (RTL vs Python model, 600 programs x 400 clocks, 0 mismatches), engine mutants 24/24 then 26/26. See [docs/ALU_CRC_I2CSLAVE_PLAN.md](docs/ALU_CRC_I2CSLAVE_PLAN.md), [docs/ALU_CRC_RESULTS.md](docs/ALU_CRC_RESULTS.md).
**2b. Protocol firmware created in the same phase (commit 3730c18 "Verification and firmware"):** I2C slave (108 words, `host/i2c_prog.py`, tests `host/i2c_slave_test.py`), SMBus with PEC (88 words, `host/smbus_test.py`), Modbus RTU (`host/modbus_prog.py`, `host/modbus_test.py`), 1-Wire (`host/onewire_prog.py`, `host/onewire_test.py`, `tb/peer_onewire.v`), JTAG (`host/jtag_prog.py`, `host/jtag_test.py`, `tb/peer_jtag.v`), CAN 2.0A (`host/can_prog.py`, `host/can_model.py`, `host/can_test.py`, `tb/peer_can.v`) and the shared peer file `tb/peer_models.v`, `tb/tb_proto.v` (two engines on a pad bus, driven by `host/proto_lib.py`). Each was checked against an independent peer written from the standard, with planted-bug firmware.
**3. Layouts that passed everything.** tt9b (flat, 48.8 MHz slow corner) and tt9c (symmetric with engine "fences", 43.4 MHz): 0 DRC, 0 LVS, Tiny Tapeout precheck passes, gate-level test 3/3. Precheck lessons: macros only on whole stripe pitches, 17 um macro halo, `PL_KEEP_RESIZE_BELOW_OVERFLOW 0` needed with fences (else a placement crash).
**4. Three parallel improvement tracks.** (1) compact floorplan; (2) RTL "A+B": two register read ports + adder last in the ALU result mux (timing-neutral for firmware); (3) a **fetch stage** (registered SRAM output). Results: A+B regression 26/26 -> main baseline; tt10b/tt10c (compact + A+B) 19.45 / 19.8 ns = about 50 MHz with the tight constraint giving nothing extra; symmetric tt10d was only 3 % more wire than compact. **Decision: compact floorplan, tt10c setup is the tape-out candidate.** The **fetch stage was a verified experiment that did NOT help** (tt11a: -0.6 ns at 20 ns, a new critical path replaced the old) -> **recommendation not to merge; kept on branch `exp/fetch-stage`**.
**5. First push to GitHub (commit 70d332d and `exp/fetch-stage`).** The custom flow steps moved to `librelane_plugin_project/` so the official `tt_tool.py --harden` finds them. First GitHub gds run (39143586275) failed in global placement (GPL-0307 divergence). Cause chain found over the next day: the GitHub action pins an older PDK (2bbec755) *and* an older LibreLane release (3.1.0.dev3, tag of 2026-08-13, Yosys 0.66) than our local checkout, so synthesis gave 16,040 instead of 15,597 cells and placement took another path. Local runs now use exactly the action's PDK and release (tt13a reproduced GitHub's failure exactly).
**6. Formal verification started** (SymbiYosys, unbounded `abc pdr` proofs, `formal/`): pin manager (only the owner drives a pad, open-drain pads never driven high, no reclaim under a running engine, violations flagged), FIFO (equals an ideal queue), management (a state change only after a clean complete frame, memory only written while an engine is held), engine (a held engine drives no pin). 4 proofs; each proof also run against planted bugs: 20/20 caught (34/34 after pin mapping).
**7. IR drop** analysis on tt10c: worst 0.21 mV on VPWR, 0.18 mV on VGND (negligible). **Competitor review** (public repos): strongest are MarcosAsh (Hardcaml, 43 firmwares incl. USB/10BASE-T, FPGA USB demo), Loom (13 protocols incl. USB LS, 911 mutants, 8x4); we rank third by that review: deep peer-verified protocols, 50 MHz, formal pin safety, real hardware; gaps: USB LS, SWD/PS/2/WS2812, timing checker, automated mutation.
**8. Plan to 2026-12-30 agreed** ([docs/EXECUTION_PLAN.md](docs/EXECUTION_PLAN.md)) and the **working deadline set by the user**.
**9. Pin mapping built (first step):** every pin except the management link can be remapped to any engine pin; hold pin `ui_in[3]` (active high, so an undriven pin lets the chip run); IRQ on `uo_out[1]`; debug views on `uo_out[7:2]`. Tests: `tb_pin_mgr` (768 combos + remap), formal 34/34 planted bugs. Spec [docs/PIN_MAP_PLAN.md](docs/PIN_MAP_PLAN.md).
**10. Software SPI host** (`host/chip_host.py` + `chip_host_demo.py`, 574 frames, all checks pass) with the chip RTL as simulation backend; guide [docs/HOST_INTERFACE.md](docs/HOST_INTERFACE.md).
- **Files (exact names):** RTL `src/alu_unit.v`, `src/crc_unit.v`, `src/control_unit.v`, `src/engine_top.v`, `src/isa.vh`; flow `src/pnr.sdc`, `src/pdn_cfg.tcl`, `src/config.json`, `src/floorplan_boxes.json`, `src/floorplan_engines_compact.json`, `src/floorplan_engines_symmetric.json`, `info.yaml`, `librelane/run_tt_wsl.sh`, `librelane/flow_run_wsl.sh`, `librelane/flow_variant_wsl.sh`, `librelane/floorplan_compact_cfg.json`, `librelane/floorplan_symmetric_cfg.json`, `librelane/gl_test_wsl.sh`, `librelane/precheck_wsl.sh`, `librelane/install_tt_pdk_wsl.sh`, `librelane/install_tt_librelane_wsl.sh`, `librelane/render_stages.py`, `librelane/make_gallery.py`, `librelane/module_map.py`, `librelane/module_report.py`, `librelane/net_matrix.py`, `librelane/compare_runs.py`, `librelane/area_by_module.py`, `librelane/magic_drc_summary.py`, `librelane/synth_variants_wsl.sh`, `librelane_plugin_project/*.py`, `.github/workflows/*.yaml`; Python `host/asm.py`, `host/isa_model.py`, `host/isa_diff_test.py`, `host/mutation.py`, `host/alu_test.py`, `host/crc_test.py`, `host/crc_model.py`, `host/regress.py`; tests `tb/tb_alu_unit.v`, `tb/tb_crc_unit.v`, `tb/tb_engine_alu.v`, `tb/tb_isa_diff.v`; formal `formal/pin_mgr.sby`, `formal/fifo.sby`, `formal/mgmt.sby`, `formal/engine.sby` (+ `*_props.sv`, `formal/sram_free.v`, `formal/formal_mutants.py`, `formal/run_formal_wsl.sh`, `formal/README.md`); pin mapping `src/pin_mgr.v`, `src/dbg_view.v`, `src/mgmt.v`, `src/tt_um_protocol_emulator.v`; host `host/chip_host.py`, `host/chip_host_demo.py`, `tb/tb_host_bridge.v`; documents `docs/ALU_CRC_I2CSLAVE_PLAN.md`, `docs/ALU_CRC_RESULTS.md`, `docs/TT_FLOW_RESULTS.md`, `docs/EXECUTION_PLAN.md`, `docs/PIN_MAP_PLAN.md`, `docs/HOST_INTERFACE.md`, `docs/USB_LS_PLAN.md`, `docs/DEBUG_LA_PLAN.md`, `docs/TEST_RESULTS.md`; evidence `results/tt_flow_2026-10-17/*`, `results/tt_flow_2026-10-18/*`, `results/regression_2026-10-18/`, `results/regression_2026-10-18_pinmap/`. The fetch-stage experiment lives in branch `exp/fetch-stage` (files `src/fetch_unit.v`, `docs/FETCH_STAGE.md` there; copy `/media/rishadd/OS/Data/protocol_emulator_fetch`).

## B9. 2026-10-19: placement fix, USB groundwork, 8x4 tiles, more protocols, frame v2, shared memory, move to Linux
- **Placement fix chosen:** `PL_MAX_PHI_COEFFICIENT 1.03` (commit 3416ad3). GitHub branch `ci/gpl-phi` passed gds, precheck, gl_test; only the `viewer` job failed (GitHub Pages not enabled; the user was told how to enable it).
- **Remapped-pin tests:** the chip-level firmware suites repeated with random pin placements (seeds 1-3) to prove the remap hardware is transparent.
- **Line coder (USB prerequisite):** `LINE` opcode 28, `RGET` source 6; a USB low-speed signalling unit in each engine (NRZI, bit stuffing, SE0 end of packet, edge-tracking receiver). Tests: `usb_ls.py` written from the USB 2.0 spec, 1175 checks, differential test (600 programs x 600 clocks, 0 mismatches). **USB design decision:** a "packet shuttle": the chip handles the bus level; the host software composes descriptors (because ~160 bytes of descriptors do not fit in 256 words). New hardware for it: `RGET` source 7 = FIFO occupancy. A "TXW" instruction was designed and dropped.
- **tt14a FAILED in global routing** (6x4 tiles, pin mapping + line coder: cells 16,040 -> 20,334, +27 %). Response (user approved 8x4: "assume 8x is allowed"): a **three-column 8x4 floorplan** (engine 0 | common logic | engine 1). **tt14b routes: 0 DRC, LVS clean, +1.69 ns slack at 20 ns, hold +0.10 ns; main now uses it** (commit e3846c3).
- **Frame v2** (branch `feat/frame-v2`, f234342): 12-byte frames, CRC-16/CCITT-FALSE both ways, sequence numbers (commands strictly in order), pipelined results, a retry shows the same result again and is not executed twice, NOP, result codes, ID/VERSION/CAPABILITY/SCRATCH/ERRCNT registers; v1 unchanged. Tests: `mgmt_v2_test` 135 checks, later 236, including random bit-flipped frames that must never execute; 22 unit testbenches pass; bugs found on the way (payload byte positions, `is_v2` cleared too early). Merged into main the same day (e2ef0b4).
- **Three more protocols as firmware, each checked against an independent reactive peer:** WS2812 (25 words, 15 cases/5 mutants), PS/2 device (89 words, 28 cases/8 mutants), SWD host (161 words against a reactive ADIv5 target, 11 cases/4 mutants). **13 verified protocols** (the week-5 goal reached in week 1).
- **Shared 512-word memory experiment** (branch `feat/shared-imem`): one 2-port 512x32 macro for both engines, each engine gets a "window" it sets once per run with the new instruction `OP_REGION` (lock after first use), a START address register, host writes through a held engine's port. Chip-level test passed on the RTL. Layout run sh2 (L-shaped engines) was congested; **sh3 (compact columns) routed (32 % demand) but LVS failed: VPWR and VGND were shorted** because our power stripes (pitch 44.96 um) did not match the 2-port macro's power columns (17.68 um pitch). Fix found by scanning pitches/offsets: **stripe pitch 53.04, VPWR-VGND spacing 6.74, offset 18.545** (matched grid), checked by a quick run with 0 wrong-net overlaps.
- **Move to native Ubuntu** (decided because WSL had only 7.8 GB RAM and shut down when idle, killing flows): everything committed, handoff written ([docs/HANDOFF_LINUX.md](docs/HANDOFF_LINUX.md)); GitHub gds run 39250627497 kept building remotely.
- **Files (exact names):** `src/line_coder.v`, `src/pin_mgr.v`, `src/mgmt.v`, `src/control_unit.v`, `src/isa.vh`; firmware `host/usb_prog.py`, `host/ws2812_prog.py`, `host/ps2_prog.py`, `host/swd_prog.py`; tests `host/line_coder_test.py`, `host/line_model.py`, `host/usb_ls.py`, `host/usb_host.py`, `host/usb_device_host.py`, `host/usb_model_link.py`, `host/usb_test.py`, `host/usb_mutants.py`, `host/ws2812_test.py`, `host/ps2_test.py`, `host/swd_test.py`, `host/bus_model.py`, `host/mgmt_v2_test.py`, `host/mgmt_v2_mutants.py`, `tb/tb_line_coder.v`, `tb/tb_chip_proto.v`, `tb/tb_host_bridge.v`; flow `librelane/floorplan_tri_cfg.json`, `src/floorplan_engines_tri.json`, `src/config.json`, `info.yaml`; documents `docs/LINE_CODER.md`, `docs/HANDOFF_LINUX.md`; branch files (see G-branch) `src/imem_shared.v`, `docs/SHARED_IMEM_PLAN.md`, `librelane/floorplan_shared3_cfg.json`, `src/floorplan_engines_shared3.json`, `librelane/pdn_scan.py`, `librelane/pdn_check.py`, `librelane/bars.py`; evidence `results/tt_flow_2026-10-19/*`, `results/shared_2026-10-19/*`, `results/regression_2026-10-19*`.

---------------------------------------------------------------------------------------------------

# PART C. 2026-10-20, hour by hour in order (the busiest day; native Ubuntu)

## C1. Getting the Ubuntu machine ready (morning)
- **Asked by the user:** read `docs/HANDOFF_LINUX.md` and `memory.md` and say what to continue with; "check the environments and path clear that first"; keep the same working directory (the repository stays on the NTFS data drive `/media/rishadd/OS/Data/protocol_emulator`).
- **Environment problems found and fixed:** (1) `.git/config` contained `fileMode = core.autocrlf`, which made every git command fail -> set `fileMode=false`, `autocrlf=input` (the 128 "modified" files were only line-ending/permission differences). (2) The user believed LibreLane was already installed in a Nix environment (`~/librelane`, `nix develop`); it was an old 2.4.13 checkout whose unit test failed. **The user then decided: "remove all librelane and nix environments from this system and do a clean install the same as the windows system"** and asked for the removal commands. (3) The Determinate Nix installer refused because the apt package `nix-bin` was installed (user removed it); the per-user profile folder needed `sudo mkdir /nix/var/nix/profiles/per-user/rishadd`. (4) Final stack (also in [reproduce/versions.txt](reproduce/versions.txt)): Nix, Icarus Verilog 13.0, Python 3.12, SymbiYosys 0.69 + Yices + Boolector, KLayout, LibreLane 3.1.0.dev3 (the GitHub action's release), IHP PDK revision 2bbec755, tt-support-tools, two Python virtual environments.
- **GitHub check the user asked for ("This run has passed, check it properly"):** run 39250627497 (main 8795248): gds 3h45, precheck 1h58, gl_test and viewer all passed: the official flow accepted the tt14b-based design.
- **Files (exact names):** `.git/config` (fixed), `docs/HANDOFF_LINUX.md`, `reproduce/versions.txt`, `librelane/install_tt_librelane_wsl.sh`, `librelane/install_tt_pdk_wsl.sh`; logs `~/install_librelane.log`, `~/install_pdk.log`.

## C2. Regression ported to Linux; all 47 suites pass
- **Why:** the whole test suite had been run on Windows. A clean pass on the new machine proves the environment and finds hidden platform assumptions.
- **Errors found and fixes:** a Windows-only `powershell` call -> new `run_tests.sh`; Icarus 13 rejects "use before declaration" in `tb_mgmt_pins` -> declaration moved; parallel remap suites shared one build folder (flaky CAN/Modbus, hung JTAG) -> folder names include remap seed and `FW_ORG`; a stalled line-coder transmitter hung a test -> watchdog added (mutant loop counts it as caught); a pad wired back to the debug-view select closed a zero-delay loop in Icarus 13 (remapped JTAG hung at 10 ns) -> pads built through temporaries with `assign #1`; `i2c_slave_test` lost a race when several suites compiled the same `.vvp` -> compile aside + atomic rename, separate case folders; the "line_coder_mutants" suite was flagged FAIL because caught mutants print FAIL lines -> its verdict is the "X/X caught" line.
- **Also found (line coder test gap):** `tx_stuff_before_eop` never sent a packet ending in six ones (bytes go LSB first, last byte 0xFC does) and two mutants survived -> test fixed, transmitted symbol runs now compared with the USB model; 16/16 mutants caught + one documented equivalent ("SE0 one clock too long", below measurement resolution); checks 1175 -> 1221.
- **Result:** runs d (45/47) and e: **47 of 47 suites pass** (`results/regression_2026-10-20d`, `...e`).
- **Files (exact names):** `run_tests.sh`, `tb/tb_mgmt_pins.v`, `host/proto_lib.py`, `tb/tb_line_coder.v`, `tb/tb_chip_proto.v`, `host/i2c_test.py`, `host/i2c_slave_test.py`, `host/regress.py`, `host/line_coder_test.py`; evidence `results/regression_2026-10-20/` ... `results/regression_2026-10-20e/`.

## C3. Shared-memory layout sh4 (the matched power grid works)
- **Run:** `librelane/flow_variant_linux.sh sh4 shared3 <tree>`; sh4 was restarted from scratch (the old log had ended in the power-grid step, not in routing as the handoff said). Live pictures of every stage written to `results/shared_2026-10-20/` (the user asked for the log terminal and the pictures; one terminal was blank at first and one picture page did not show, both fixed).
- **Result: LVS clean (the matched grid fixed the VPWR/VGND short), 0 DRC, 0 antenna, hold +0.10 ns, Tiny Tapeout precheck passes. Open: slow-corner setup -1.45 ns at 20 ns -> 21.45 ns = 46.6 MHz; area 368k + 151k (macros).** The precheck needs the `klayout` program and Nix libraries on the library path (documented in the script).
- **Repository privacy:** the user asked whether the repository can be made private; answer yes (done by the user), pushes only on request; the LICENSE (Apache-2.0) was pushed on request.
- **Files (exact names):** `librelane/flow_variant_linux.sh`, `librelane/live_images_linux.sh`, `librelane/module_map_shared_linux.sh`, `librelane/precheck_linux.sh`, `librelane/floorplan_shared3_cfg.json`, `src/floorplan_engines_shared3.json`; evidence `results/tt_flow_2026-10-20/sh4_final/`, `results/shared_2026-10-20/sh4_images/`, `~/flow_sh4.log`, `~/precheck_sh4.txt`; `LICENSE`.

## C4. The decision: shared memory or separate memories
- **User asked for data to decide**; the comparison (area, flexibility for USB descriptors and future protocols, timing cost) was given. **The user then decided: the shared 512-word memory is the base** (reason: the chip must be compatible with all future protocols, including a standalone USB device; the logic analyser will be integrated on top) and **asked what causes the slow-corner problem with the shared memory** (answer: a weak gate right next to the macro drove a long wire to the engines, about 1 ns of slew).
- **Orders given by the user:** start flow-only variants, then make any RTL, script or placement change needed to get close to 50 MHz, *while keeping the layout meaningful*; explain how a slightly slower clock changes instruction timing; clean up the directory; merge and rebase frame v2; write the plans for logic analyser, standalone USB device and Ethernet; search the web for what other participants did; before building the logic analyser, do the shared-memory software ("Step 4") and explain what it is.
- **Files (exact names):** decision recorded in this file, `docs/SHARED_IMEM_PLAN.md`, `docs/SHARED_IMEM_SOFTWARE_PLAN.md`, `docs/EXECUTION_PLAN.md`.

## C5. The timing campaign to ~50 MHz (all on 8x4, slow corner; table: [reproduce/flows/README.md](reproduce/flows/README.md))
| Run | Change tried | Why | Result |
|---|---|---|---|
| sh4 | baseline | reference | 21.45 ns |
| sh5a | constraint 17 ns + setup resizer margin 0.5 | ask the tool for more than needed | 19.50 ns, no area cost |
| sh5b | 18 ns + repair after global routing | let the tool repair late | 19.98 ns but +7 % area |
| sh5c | delay-oriented synthesis | faster logic | **worse**: 22.43 ns, much more wire |
| sh6 | the trap gate moved from the memory block into the engines | a weak gate drove a long wire | 20.41 ns, free |
| sh7 | candidate RTL + repair, 19 ns | combine | 20.29 ns, +8 % area (not worth it) |
| **sh8** | candidate RTL + sh5a settings (17 ns, margin 0.5) | combine the free gains | **19.64 ns = 50.9 MHz, 402k, slack +0.36 ns at a real 20 ns clock** |
| sh9a / sh9b | same RTL, constraint 20 ns, margin 0.5 / 1.0 | check that a "honest" 20 ns constraint passes | both **20.45 ns; identical in all 190 metrics** (margin has no effect) |
- **Decisions/lessons:** the free gains are the trap gate inside the engines (~1 ns) and a tight constraint (~1.9 ns). Do **not** constrain at the real clock. **The sh8 settings are the standard recipe.** Everything LVS clean, 0 DRC. Max-slew (14-18) and max-cap (24-42) violations exist in every run and are not yet judged. Also written: [docs/CLOCK_SPEED_EFFECTS.md](docs/CLOCK_SPEED_EFFECTS.md): a slower clock rescales times, not logic; **40 MHz is a good operating clock** (I2C 1 MHz, CAN 1 Mbit/s, WS2812 and 10BASE-T become whole numbers of clocks).
- **Files (exact names):** `reproduce/flows/README.md` (the table), `reproduce/flows/sh4 ... sh9b/`, `~/flow_sh5a.log ... ~/flow_sh9b.log`, `results/shared_2026-10-20/sh5a_images ... sh9b_images/` (untracked), `src/engine_top.v` + `src/imem_shared.v` (trap gate move, branch), `docs/CLOCK_SPEED_EFFECTS.md`.

## C6. Repository work done in parallel
- **Directory clean-up (user: "B4, clean up the directory and proceed with the checklist"):** a backup bundle of every branch (`~/protocol_emulator_all_refs_2026-10-20.bundle`) was made, then stale worktree copies deleted (about 3 GB; the user approved the deletion explicitly after the safety check blocked it once); unique files rescued to `results/archive_old_worktrees/`; the 1.6 GB fetch-stage copy was left untouched.
- **Frame v2 merge into main (fcbd07b, pushed on request).** The merge exposed a **real bug**: the first TX byte of a v1 frame came from a status register one clock older than the one the accept decision used -> a duplicated TX byte (UART duplex stress 1025 bytes for 1024, 6 of 7 cases; workload 54/55). Fix in `mgmt.v` (send the live STATUS while idle). After the fix: duplex stress ALL PASS, v2 236/236, 22/22 unit tests, regression 47/47.
- **TODO list** created on request ([docs/TODO.md](docs/TODO.md)) and kept ticked.
- **Plans written (documents):** [DEBUG_LA_PLAN](docs/DEBUG_LA_PLAN.md) (logic analyser: 16 channels, triggers, third SRAM macro, phases 0-8, TSTAMP as a new opcode because all eight RGET sources were already used), [USB_STANDALONE_PLAN](docs/USB_STANDALONE_PLAN.md) (descriptors on chip, ~320-380 words, fits only the shared memory), [ETHERNET_FEASIBILITY](docs/ETHERNET_FEASIBILITY.md) (10BASE-T transmit feasible at 40 MHz, receive is research), [PROTOCOL_CATALOGUE](docs/PROTOCOL_CATALOGUE.md) (13 verified + ~20 firmware-only candidates), [SHARED_IMEM_SOFTWARE_PLAN](docs/SHARED_IMEM_SOFTWARE_PLAN.md), [CLOCK_SPEED_EFFECTS](docs/CLOCK_SPEED_EFFECTS.md). Competitor scan repeated: Loom (8x4, 13 firmwares, 911 mutants, ~43 MHz) and Abagel-coder (6x4, 3 protocols, 50 MHz) are the real comparisons; our gaps: mutation volume, a static timing checker, a self-contained USB device, FPGA demos.
- **Files (exact names):** `~/protocol_emulator_all_refs_2026-10-20.bundle`, `results/archive_old_worktrees/*`, `src/mgmt.v` (STATUS fix), `docs/TODO.md`, `docs/DEBUG_LA_PLAN.md`, `docs/USB_STANDALONE_PLAN.md`, `docs/ETHERNET_FEASIBILITY.md`, `docs/PROTOCOL_CATALOGUE.md`, `docs/SHARED_IMEM_SOFTWARE_PLAN.md`, `docs/CLOCK_SPEED_EFFECTS.md`.

## C7. Shared-memory software "Step 4" (done, branch `shared/on-v2`, local)
Plain-language: Step 4 is everything *around* the new shared memory so that it can be trusted: tests, proofs and host tools. It lives on the branch `shared/on-v2` in `~/pe_shared_v2` (frame v2 merged in by hand).
- **S1 RTL:** read-back of an engine's window (`REGION` at ENG_BASE+0x008) and of instruction words (frame v2, through any held engine's port).
- **S2 differential test in shared mode:** random images at random places in the 512 words, both engines, RTL vs model every clock: 400 tests x 600 clocks x 2 engines, 0 mismatches, 76/76 coverage.
- **S3 formal:** `imem_shared.sby` (a fetch never leaves the window; host writes never land in a running window or through a running port; the lock holds) and `region_go.sby` (the control unit accepts `OP_REGION` only when unlocked and valid); 6 proofs in total; 13 planted bugs caught. A first attempt failed because Yosys treats hierarchical references as free signals -> the macro write signals were exposed as outputs.
- **S4 host layer:** verified image load, REGION check at start, `plan_images` overlap check. **S5:** 16/16 planted RTL bugs caught by the differential test. **S6:** the chip-level protocol suites run from the shared memory (engine 1 at word 256): CAN, JTAG, 1-Wire, Modbus (plain + remap seed 2), SPI chip 52/52, I2C chip 10/10 ("phase E" of the regression). Test-writing traps: unwritten memory words read as X (write first), a test bench input left unconnected.
- **Not yet run from the shared memory:** UART, USB, SMBus, long workloads, WS2812/PS/2/SWD (model level only).
- **Files (exact names):** `src/imem_shared.v`, `src/mgmt.v`, `src/control_unit.v`, `tb/tb_imem_shared.v`, `tb/tb_isa_diff_shared.v`, `tb/shared_imem.vh`, `host/isa_diff_shared.py`, `host/shmem_host.py`, `host/shmem_test.py`, `host/shmem_chip_test.py`, `formal/imem_shared.sby`, `formal/imem_shared_props.sv`, `formal/region_go.sby`, `formal/region_go_props.sv`, `formal/sram2p_free.v`, `formal/run_formal_linux.sh`, `formal/formal_mutants.py`, `host/regress.py` (phase E), `host/proto_lib.py` (PROTO_SHARED).

## C8. The user guide (for chip users)
- **Asked by the user (while sh8 was running):** "create a highly detailed user guide with chapters, subheadings and a contents page ... include every functionality ... assume a Raspberry Pi Pico is the host". I first listed the chapters for approval. **User's changes:** logic-analyser chapter must use **GTKWave** not PulseView; chapter 16 is "Troubleshooting and debug" (no FAQ); tools that do not exist yet get **placeholders + a memory entry saying the text must be edited later**; nothing silicon/fabrication specific; every title and subheading present with brief placeholder text; a markdown file in the repo plus a scrollable neat HTML with a clickable contents page.
- **Built:** [docs/USER_GUIDE.md](docs/USER_GUIDE.md) (17 chapters in 3 parts, 9 appendices, 189 headings) and generated HTML (`python3 docs/build_user_guide.py`, dependency free, sidebar contents with filter). Placeholders to fill later are listed in the guide's "Document status" table: Pico library `pe_chip`, logic analyser registers + `la_capture.py` + GTKWave screenshots, engine debug, sniffer, TSTAMP, standalone USB, Ethernet, final pin map/ratings/power, remaining catalogue protocols, worked recipe, first-program listing, quick-reference card. Links "to check" in Appendix G were not all reachable (flaky network).
- **Figures (user: "generate and add all images wherever possible ... the Pico pinout etc are online"):** 47 figures: 45 diagrams drawn by Python scripts (`docs/images/make_images.py`; system view, block diagram, Pico wiring, protocol wiring for 11 protocols, frame formats, timing diagrams, logic analyser figures ...), a real capture example produced by the logic-analyser model (`example_capture.vcd`), and the Raspberry Pi Pico pinout downloaded from CIRCUITSTATE (CC BY-SA 4.0, attribution in `docs/images/third_party/ATTRIBUTION.md` and Appendix I). Several figures were redrawn after visual review (double arrows, overlapping labels, USB NRZI start level ...). Pushed with the README link on the user's request (commits e2d6499, a0e988a, 744a214 on `main`).
- **Files (exact names):** `docs/USER_GUIDE.md`, `docs/USER_GUIDE.html`, `docs/build_user_guide.py`, `docs/images/*` (see G-docs), `docs/images/third_party/pico-pinout-r0.3-circuitstate.png`, `docs/images/third_party/ATTRIBUTION.md`, `docs/images/example_capture.vcd`, `README.md` (link).

## C9. Logic analyser Phases 1-3 (branch `shared/on-v2`)
- **Plan decisions (D1-D6 in DEBUG_LA_PLAN):** the analyser never touches the instruction-fetch path; third macro (1P 256x32) as capture buffer; timestamp access is a new opcode 30 `TSTAMP`; channels = 13 pins after the 2-flop synchroniser + RUN of each engine + marker channel 15 (OR of the engines' trigger lines); change-mode words `{value[15:0], delta[15:0]}` with an overflow word every 65,535 quiet clocks; engine debug later uses frame v2 so a retried step never executes twice.
- **Phase 1 model (`host/la_model.py`)**, self-test with 300 random captures, VCD writer and decoder. **Phase 2 RTL (`src/la_unit.v`)** compared with the model clock by clock (`la_rtl_test.py`; 200 tests x 3000 clocks, depth 16, plus long captures for the overflow word); 12 planted bugs in the unit all caught. Issue found: the model cleared the buffer on re-arm but the RTL did not (model changed to match, harmless because only the write pointer defines valid words); a mutant for the overflow word needed deliberately long captures.
- **Phase 3a (user asked: "start Phase 3 now"):** `TSTAMP rd` (opcode 30, reads a 32-bit free-running counter) and `RPUT TRIG` (destination 4 of RPUT: the engine's trigger line, shown on channel 15, drops when the engine is held). Updated: RTL (`engine_top`, `control_unit`), assembler, Python model (cycle counter, trigger), the two differential tests (a new trace column; the test bench drives `ts` = clock number), 6 new planted bugs. **Results: differential test 0 mismatches, 99/99 coverage, 38/38 mutants caught; shared-memory differential test 0 mismatches.** The old "REGION is covered" requirement of the non-shared test was unreachable and had been failing already; excluded. Two old unit tests expected "destination 4 and opcode 30 trap" and had to be updated.
- **Phase 3b:** `src/la_block.v` (only when `-DLA`): timestamp counter, pin synchroniser, capture unit, third macro buffer, register window `0x0300` (CTRL, CONFIG, PATTERN, DIV, POST, TRIGCNT, PTR, DATA, TS); management controller gets the window and a buffer read-out (v2 frames only; BUSY while a capture runs; v1 DATA read refused); IRQ bit 8 "capture done" (pin manager IRQ status widened to 9 bits); debug view 6; `host/la_host.py` (first part of the host tool).
- **Chip-level test `host/la_chip_test.py` (through the real SPI link): PASS** - register read-back and refusals, a capture of known pin activity with exact clock spacing (30 and 20 clocks), VCD round trip, sample mode, TSTAMP difference 11 equal to the model, the 32-clock trigger pulse on channel 15, trigger line low when the engine is held, done interrupt on `uo_out[1]`, debug view. Formal proofs of the changed blocks (pin manager, management, engine, region_go) re-run: all PASS.
- **Files (exact names):** `host/la_model.py`, `host/la_rtl_test.py`, `host/la_chip_test.py`, `host/la_host.py`, `src/la_unit.v`, `src/la_block.v`, `tb/tb_la_unit.v`, `src/isa.vh`, `src/engine_top.v`, `src/control_unit.v`, `src/mgmt.v`, `src/pin_mgr.v`, `src/dbg_view.v`, `src/tt_um_protocol_emulator.v`, `host/asm.py`, `host/isa_model.py`, `host/isa_diff_test.py`, `host/isa_diff_shared.py`, `tb/tb_isa_diff.v`, `tb/tb_isa_diff_shared.v`, `tb/tb_control_unit.v`, `tb/tb_engine_alu.v`, `tb/tb_pin_mgr.v`, `tb/tb_i2c_engine.v`, `formal/pin_mgr_props.sv`, `formal/mgmt_props.sv`, `host/chip_host.py` (SimLink `la=True`), `docs/DEBUG_LA_PLAN.md`.

## C10. "How do I reproduce all results?" -> the `reproduce/` folder
- **Asked by the user:** give every script needed to reproduce all results including the layout flows, in this directory, nothing hidden. **Built:** `reproduce/README.md` (single document, the user asked for one, not two), install/tests/formal/flow/precheck/docs scripts (01-07), an **archive of the nine shared-memory flow runs sh4-sh9b** with their exact RTL, complete configuration and metrics (`flows/`), a comparison tool (`tools/compare_flow.py`), tool versions, and a git bundle of branches not in main. The flow scripts no longer contain hard-coded home paths.
- **User: "don't wait for the whole rerun if the signature is the same so far":** sh8 was rerun from the folder alone and stopped at step 30 of 72 after **29 of 29 completed steps had identical cumulative metrics**: the flow is deterministic. Honest limits written into the README: flows before 2026-10-18 23:10 (tt2-tt12a, incl. tt9b/tt9c) used a dev LibreLane and an older PDK that are not stored (configs archived, rerun gives a close but different layout); tt14b is rebuilt from commit e3846c3; GitHub jobs and FPGA runs are not scriptable; CRLF input files of sh4-sh5c.
- **Files (exact names):** `reproduce/` (all files in G-reproduce), `librelane/run_tt_wsl.sh`, `librelane/live_images_linux.sh`, `librelane/module_map_shared_linux.sh` (paths made repo-relative), `~/flow_sh8r.log`, `~/pe_sh8r/`.

## C11. "Is my design fit for submission? Check it with all prechecks and metrics and start the GitHub workflow"
- **Answer given first:** a three-layer checklist (simulation/formal; layout metrics + precheck + gate-level test; challenge rules in [docs/CHALLENGE_CHECK.md](docs/CHALLENGE_CHECK.md)). Today the design is *not* yet submission-ready: the final RTL (with the analyser, engine debug, sniffers) has not been through a layout and precheck, and the slew/cap violations and the public-repo build are unchecked.
- **Done on request:** branch **`check/shared-sh8`** created from `shared/on-v2` with `src/config.json` = the sh8 recipe (so GitHub and the local flow use the same configuration) and **pushed** (this starts the docs, gds and test workflows; gds takes 4-6 hours; I cannot see the result: no `gh` and no token here and the repository is private, so the user reads https://github.com/Rishadd/protocol_emulator/actions). The current build deliberately **excludes the logic analyser** (no macro placement for its macro yet), so this checks the shared-memory chip with TSTAMP/trigger. The local twin run **sh10** (same recipe and RTL) was started and the Tiny Tapeout precheck on it follows; **result: sh10 finished (exit 0): 19.71 ns = 50.7 MHz at the slow corner, +0.29 ns slack at a real 20 ns clock, setup -2.71 ns at the 17 ns constraint (555 paths), hold +0.077 ns, LVS clean, 0 DRC, 0 antenna, std cells 405k um2 + 151k macros, 27 max-slew / 30 max-cap violations, wire 1,517k um; no precheck run on it (not started on request); pictures `results/shared_2026-10-20/sh10_images/`; evidence `results/tt_flow_2026-10-20/sh10_final/`; the run does NOT contain the logic analyser (defines are SYNTHESIS and SHARED_IMEM only)**. Caveat told to the user: the `test` job runs cocotb tests written for the old design and may fail for reasons unrelated to the layout.
- **Files (exact names):** `src/config.json` (on branch `check/shared-sh8`, commit 884a7fd), `docs/CHALLENGE_CHECK.md`, `.github/workflows/gds.yaml`, `.github/workflows/test.yaml`, `.github/workflows/docs.yaml`, `librelane/flow_variant_linux.sh`, `librelane/precheck_linux.sh`, `~/flow_sh10.log`, `~/pe_sh10/`.

## C12. The regression of the shared-memory branch: what went wrong and how it was repaired (read this to understand the harness)
1. The first full run of the 57-suite regression (phases A-F; phase F is new: frame v2, shared-memory software, logic analyser) ended at 45/57.
2. **My own mistake:** a monitor that looked for the regression process with `pgrep "host/regress.py"` missed a run started as `cd host && python3 regress.py`; I concluded the run had died and **started a second regression while the first was still running**. Both share build folders, and the second run's start deleted compiled files (`.vvp`) that the first needed. The user noticed ("why did you start a new one again"); the duplicate was killed at once; the damage was a few suites failing with "Unable to open input file", which were rerun. Rule added: never start a second regression while one runs; watch with monitors on the exact process id.
3. Real problems found and fixed: (a) phase E (10 chip-level suites) failed at once because `la_block.v` instantiates the 1P macro and the shared-memory simulations did not include its model; my first fix (add the model to the shared libraries) was wrong (it became a stray top-level module whose unconnected pins stop every bench at time 0: "A_DLY must be tied to 1'b1"); the right fix: `la_block.v` exists only with `-DLA`; (b) ten suites compiled the same chip bench `.vvp` simultaneously (race, "syntax error") -> private temporary file + atomic rename; (c) the build's staleness check ignores the list of macro models, so stale compiled files had to be deleted by hand once; (d) phase F mutant suites print a FAIL line for every caught bug -> judged by their "caught X/X" line; (e) `isa_diff_shared_mutants` caught only 15/16 because the new TSTAMP changed the random generator and the rare "empty window" case no longer occurred in 150 tests -> 300 tests, 16/16.
4. **Results after the repairs:** phase E 10/10 pass (CAN 26/26, JTAG 17/17, 1-Wire 10/10, Modbus 16/16, SPI chip 52/52, I2C chip 10/10, plus the remap-seed variants); phase F: mgmt_v2_test 236/236, mgmt_v2_mutants 20/20, shmem_test, shmem_chip_test, isa_diff_shared (0 mismatches), isa_diff_shared_mutants 16/16, la_model, la_rtl_test, la_rtl_mutants 12/12, la_chip_test all PASS; org192_spi_test and the unit testbenches pass on rerun. **Not yet done: one single clean A-F pass on the final code.** Evidence folders: `~/pe_shared_v2/results/regression_repro_shared_*`.
- **Files (exact names):** `host/regress.py` (phase F), `host/proto_lib.py`, `host/i2c_test.py`, `host/spi_test.py`, `src/la_block.v` (`ifdef LA`), `host/isa_diff_shared.py`, `tb/tb_control_unit.v`, `tb/tb_engine_alu.v`; logs `~/regress_la3.log`, `~/regress_rerun.log`, `~/regress_final.log`, `~/regress_final2.log`, `~/regress_final3.log`, `~/regress_shared_full.log`; evidence folders `~/pe_shared_v2/results/regression_2026-10-20*/`, `regression_repro_shared*/`; commits on the shared branch 820322b, 55923b6, d90daca, 9495e4b, 2b7af4b (harness fixes).

## C13. Reports, pushes and the end of 2026-10-20
- **Asked by the user:** "dont start any task after sh10 finishes, just commit and push everything to GitHub and wait", plus "a detailed report on everything we worked on in the past couple of days ... add it to the repo and push", and "update the images from sh10 also".
- **Done:** report [docs/PROGRESS_REPORT_2026-10-18_to_2026-10-20.md](docs/PROGRESS_REPORT_2026-10-18_to_2026-10-20.md); sh10 pictures (`results/shared_2026-10-20/sh10_images/`) and evidence (`results/tt_flow_2026-10-20/sh10_final/`); `reproduce/flows/sh10/` archived; the shared branches pushed (`shared/on-v2` new on origin, `check/shared-sh8` at f9583f5, both `[skip ci]`); `main` pushed with everything. **The user asked where the logic analyser is in the sh10 pictures: it is not in sh10** (no `LA` define, no `u_la` in the netlist, only the shared 512-word macro): the analyser has no floorplan position for its third macro yet (Phase 7). No other task was started after sh10 finished (no precheck on sh10, no clean A-F regression pass).
- **Files (exact names):** `docs/PROGRESS_REPORT_2026-10-18_to_2026-10-20.md`, `results/tt_flow_2026-10-20/sh10_final/*`, `results/shared_2026-10-20/sh10_images/*`, `reproduce/flows/sh10/*`, `reproduce/flows/README.md`, `reproduce/tools/flow_table.py`, `~/pictures_sh10.log`, `~/flow_sh10.log`.

---------------------------------------------------------------------------------------------------

# PART D. Every decision the user made, and what happened to it (proceed / revert / keep)
| Date | Decision or instruction by the user | What was done | Outcome |
|---|---|---|---|
| 10-01..08 | Build a protocol engine; UART first, on the DE0-Nano | engine v0.1, UART TX/RX firmware, FPGA | worked on hardware |
| 10-11 | Eight-step management link plan | steps 1-8 | all done |
| 10-11 | Move instruction memory to SRAM macros | 2 x 1P 64x16 per engine | kept; chip -65 % area |
| 10-11 | SPI with a pin-conditional jump, no loopback | JPH/JPL | kept |
| 10-11 | I2C plan D1-D8 (new instructions JPO/PUSHI only if reusable; pin manager; I2C slave later) | built master + pin manager | kept; slave added later in the ALU/CRC phase |
| 10-17 | 256-word memory, one 1P 256x32 macro per engine | done | kept |
| 10-18 | Plan to 2026-12-30; working deadline 12-30; RTL freeze 12-13 | EXECUTION_PLAN | active |
| 10-18 | Compact floorplan + A+B setup (tt10c) as tape-out candidate | adopted | later superseded by 8x4 three-column floorplan |
| 10-18 | (assistant's recommendation) do not merge the fetch stage | experiment kept on `exp/fetch-stage` | **not merged** (no timing gain) |
| 10-19 | "Assume 8x4 is allowed" after tt14a failed to route in 6x4 | three-column 8x4 floorplan, tt14b clean | kept; `info.yaml` says 8x4 |
| 10-19 | Shared 512-word memory experiment | branch feat/shared-imem, sh2/sh3 | sh2 congested (replaced), sh3 shorted (fixed by matched grid) |
| 10-19 | Move to native Ubuntu | environment rebuilt | done |
| 10-20 | Remove all LibreLane/Nix and reinstall cleanly | done after two installer problems | kept |
| 10-20 | Repository private; push only on request; license pushed | done | active |
| 10-20 | **Shared memory is the base; logic analyser on top** | branch shared/on-v2 | active direction |
| 10-20 | Get as close to 50 MHz as possible with a meaningful layout | sh5-sh9 | 50.9 MHz (sh8) |
| 10-20 | Software for the shared memory before the logic analyser | Step 4 | done |
| 10-20 | Plans for LA, standalone USB, Ethernet; clock-speed explanation | 6 documents | done |
| 10-20 | User guide; GTKWave not PulseView; no FAQ; placeholders + memory entry | draft + 47 figures | done, placeholders open |
| 10-20 | Do not make the guide a priority over the chip timeline | back to LA Phase 3 | active |
| 10-20 | Reproduce folder, one README, nothing hidden | built | done |
| 10-20 | Stop the rerun when the signature matches | stopped at step 30/72 | accepted evidence |
| 10-20 | Check the current version and start the GitHub workflow | branch check/shared-sh8 pushed | result pending |
| 10-20 | Always use monitors, never poll terminals | rule followed | active |
Reverted decisions: none were reverted at the user's request. Superseded or abandoned by evidence: the fetch stage (no gain), the symmetric floorplan (3 % more wire), delay-oriented synthesis, repair after global routing (area for little gain), the 6x4 floorplan (does not route with pin mapping), the idea of a `TXW` USB instruction (dropped for the packet-shuttle design), the WSL machine (replaced by native Ubuntu).

---------------------------------------------------------------------------------------------------

# PART E. Look-up tables

## E1. Documents created (34 in `docs/`; all in the repository)
**Plans:** WORKSTREAM1_ARCHITECTURE, WORKSTREAM2_RTL_IMPLEMENTATION, PROTOCOL_EMULATOR_ARCHITECTURE (the original design), MGMT_PLAN, SPI_PLAN, I2C_PLAN, ALU_CRC_I2CSLAVE_PLAN, PIN_MAP_PLAN, USB_LS_PLAN, EXECUTION_PLAN (to 2026-12-30), DEBUG_LA_PLAN, USB_STANDALONE_PLAN, ETHERNET_FEASIBILITY, SHARED_IMEM_SOFTWARE_PLAN, PROTOCOL_CATALOGUE.
**Results:** SPI_RESULTS, I2C_RESULTS, WORKLOAD_RESULTS, SRAM_INSTR_MEM_RESULTS, BIGMEM_RESULTS, ALU_CRC_RESULTS, LIBRELANE_RESULTS, TT_FLOW_RESULTS, TEST_RESULTS (all numbers), ASIC_AREA_AND_MEMORY_STUDY, CLOCK_SPEED_EFFECTS.
**Interfaces and guides:** HOST_INTERFACE, LINE_CODER, USER_GUIDE (md + html + 47 figures), CHALLENGE_CHECK (rules vs status), HANDOFF_LINUX, README (map), TODO, info.md (Tiny Tapeout project page text), MEMORY_RAW_LOG_until_2026-10-20 (the old memory file). Elsewhere: `reproduce/README.md`, `docs/images/`, `results/*/index.html` (layout picture galleries).

## E2. Tests: what exists, why, and the latest result
| Test | What it proves | Why it was written | Latest result |
|---|---|---|---|
| 22 RTL unit testbenches (`run_tests.sh`) | each block (memory wrapper, PC, counters, FIFO, shifters, ALU, CRC, pin block/manager, control unit, engine, management) | smallest-scope bugs | all PASS |
| `isa_diff_test.py` | RTL = independent cycle-exact Python model, random programs and stimulus, 99 coverage points | catches any instruction/timing mismatch | 0 mismatches; 38/38 planted bugs |
| `isa_diff_shared.py` | same, two engines, shared memory, random image layouts | shared-memory correctness | 0 mismatches (400x600x2); 16/16 mutants |
| ALU / CRC tests | all functions and flags; 14 CRC models; random vectors | new units | 28/28 and 14/14 planted bugs |
| Protocol suites (`spi_test`, `i2c_test`, `i2c_slave_test`, `smbus_test`, `modbus_test`, `onewire_test`, `jtag_test`, `can_test`, `usb_test`, `ws2812_test`, `ps2_test`, `swd_test`, uart workloads) | each firmware against independent peer models written from the specs, with planted-bug firmware | prove the protocols | all PASS (counts in TEST_RESULTS.md) |
| Chip-level suites (phase B, D, E) | same firmware with the host only on the SPI link; random pin placement; from the shared memory | proves the management link, pin mapping and shared memory | all PASS |
| `FW_ORG` suites (phase C) | firmware relocated to other addresses | position independence | all PASS |
| `line_coder_test.py` (+mutants) | USB line coder against a spec-based model | USB groundwork | 1221 checks; 16/16 + 1 equivalent |
| `mgmt_v2_test.py` (+mutants) | frame v2: CRC, sequence, retries exactly once, bit flips never execute | safe management link | 236/236; 20/20 |
| `mgmt_duplex_stress.py`, workloads | 1 KB duplex through the link, overload behaviour | find limits | ALL PASS |
| Formal (`formal/*.sby`, 6 proofs on shared branch) | pin safety, FIFO, management commits, engine release, memory windows, region lock | hardware-safety guarantees | PASS; 34 + 13 planted bugs caught |
| Logic analyser: `la_model.py`, `la_rtl_test.py`, `la_chip_test.py` | model self-test; RTL = model every clock; chip-level through SPI | new feature | PASS; 12/12 mutants |
| Layout checks (every flow) | DRC, LVS, antenna, timing (3 corners), Tiny Tapeout precheck, gate-level cocotb test | can the chip be made | see E3 |
| `regress.py` | runs everything: phases A-D on `main` (47 suites), E-F on the shared branch | one command | see C12 |

## E3. Key numbers
- Area: flip-flop memories 414k um2 -> SRAM 143k; tt14b (8x4): 24,867 cells, 356k + 99k macros; shared-memory layouts: ~368-402k std cells + 151k macros of a 1724x711 um die.
- Timing (slow corner, achieved period): tt10c 19.8 ns; tt14b +1.69 ns at 20 ns; sh4 21.45; sh8 **19.64 ns (50.9 MHz)**; sh9 20.45.
- Verification counts: 13 protocols; 47 regression suites on `main`; ~100 planted-bug checks in the engine, hundreds across protocols (e.g. 64 SPI, 20 CAN, 18 USB); formal: 6 proofs, 47 planted bugs.
- Competitors (public repos, unverified claims): MarcosAsh (43 firmwares), Loom (13 protocols, 911 mutants, ~43 MHz, 8x4), Abagel-coder (3 protocols, 50 MHz).

## E4. Where things are
| Thing | Place |
|---|---|
| Repository (main) | `/media/rishadd/OS/Data/protocol_emulator` (GitHub `Rishadd/protocol_emulator`, private) |
| Shared-memory branch working tree | `~/pe_shared_v2` (branch `shared/on-v2`, plus `check/shared-sh8` pushed; backups: `reproduce/branches.bundle`, `~/protocol_emulator_all_refs_2026-10-20.bundle`) |
| Layout runs | `~/pe_<tag>/runs/<tag>/` (e.g. sh8, sh10); saved evidence in `results/` |
| Tools | `~/librelane-3.1.0.dev3`, `~/pdk_tt`, `~/tt-support-tools`, `~/ttvenv`, `~/pictvenv`, Nix profile |
| Old Windows-era copies | deleted after backup; `protocol_emulator_shmem` (source of the sh4-sh5 flows) and `protocol_emulator_fetch` (1.6 GB experiment) kept |

---------------------------------------------------------------------------------------------------

# PART F. What is open, and what comes next
**Running or waiting on results (2026-10-20 night):** local flow sh10 (same RTL/recipe as the GitHub check) -> then the Tiny Tapeout precheck on it; GitHub workflow results of branch `check/shared-sh8` (user reads the Actions page); one clean full regression pass A-F on the final code.
**Next chip work, in order (docs/DEBUG_LA_PLAN.md):** Phase 4 engine debug (halt, single step, breakpoint, register read-back); Phase 5 protocol sniffers (images in the shared memory); Phase 6 formal proofs and chip-level mutants for the analyser; Phase 7 layout with the third macro (placement not defined yet; fallback: 32x32 flip-flop buffer); Phase 8 `la_capture.py` + GTKWave demo; then merge `shared/on-v2` into `main`, refresh `reproduce/branches.bundle` + `SHARED_COMMIT`, mutation campaign + timing checker, memory self-test, FPGA demos for more protocols, judge the slew/cap violations, RTL freeze 2026-12-13, final runs 12-14..12-27 with Tiny Tapeout's own tools.
**Submission checklist still open:** public repository + passing GitHub gds/precheck/gl_test on the final commit, all guide placeholders filled, more FPGA demos, deadline 2027-01-18.
**Known limits (documented):** UART RX accepts glitches as start bits and has no stop-bit check; CAN has no arbitration/error frames; SPI slave and UART RX cannot pause their peer; no firmware timeouts (a stuck bus waits for the host); sustained rates are bounded by the management link (one frame per word); the user guide has placeholders.
**To refresh this file:** add new dated entries to Part C (or a new Part for a new period), update A4, D, E2/E3 and F; never delete history (the raw old log stays in docs/).

---------------------------------------------------------------------------------------------------

# PART G. Catalogue of every folder and file (exact names)

How to use: find a name mentioned in Parts B-F here, or walk the tree top-down. Files marked "(shared branch)" or listed in G-branch exist only on the branches `shared/on-v2` / `check/shared-sh8` (working tree `~/pe_shared_v2`), not on `main`. Descriptions of source files are the first line of the file's own header comment; descriptions of the tables in G-host, G-results, G-reproduce were written by hand. The top-level layout of the repository: `src/` RTL, `tb/` testbenches, `host/` Python, `formal/` proofs, `librelane/` flow scripts, `librelane_plugin_project/` custom flow steps, `macro/` SRAM macro files, `sim/` SRAM simulation models, `synth/` early synthesis, `test/` cocotb, `quartus/` FPGA, `docs/` documents, `results/` evidence, `reproduce/` reproduction kit, `.github/workflows/` CI, root files (G-root).

### G-src  src/ : the chip RTL (Verilog) and the files the layout flow reads next to it  (on branch `main`)

| file | what it is |
|---|---|
| `src/alu_unit.v` | Register file (8 x 32), ALU and flags {Z, N, C}. Instruction operand layouts (docs/ALU_CRC_I2CSLAVE_PLAN.md 3.1): |
| `src/config.json` | LibreLane configuration of the Tiny Tapeout flow on main (tt14b recipe: 8x4, three-column floorplan, SRAM 1 position, stripe grid 44.96/3.52/18.16, CLOCK_PERIOD 20). On branch check/shared-sh8 it holds the sh8 recipe instead. |
| `src/control_unit.v` | Decodes instr[31:27] opcode, instr[26:0] flat operand (see isa.vh). |
| `src/crc_unit.v` | Programmable CRC unit (Rocksoft model): any width 1..32, any polynomial, input/output reflection, init, final XOR. |
| `src/dbg_view.v` | Debug views: the default function of uo_out[7:2] (docs/PIN_MAP_PLAN.md section 4), selected by DBG_SEL = ui_in[7:5] |
| `src/delay_counter.v` | Counts down from load_value to 0; busy stays high until it reaches 0. |
| `src/engine_top.v` | Single protocol engine: instr_mem + pc_reg + delay_counter + loop_counter |
| `src/fifo.v` | Synchronous FIFO, first-word-fall-through (rd_data valid whenever !empty). |
| `src/floorplan_boxes.json` | module "boxes" (placement fences) of the first boxed 6x4 floorplan (tt9c era) |
| `src/floorplan_engines_compact.json` | engine fences for the compact 6x4 floorplan variant (tt10b/tt10c) |
| `src/floorplan_engines_symmetric.json` | engine fences for the symmetric 6x4 floorplan variant (tt9c, tt10d) |
| `src/floorplan_engines_tri.json` | engine fences for the three-column 8x4 floorplan (engine 0 / common logic / engine 1): tt14b, main default |
| `src/fpga/db/de0_nano.db_info` | Quartus database info for the DE0-Nano project |
| `src/fpga/de0_nano.sdc` | 50 MHz oscillator; everything else is asynchronous (buttons, UART line). |
| `src/fpga/de0_nano_duplex_top.v` | DE0-Nano full duplex echo: HC-05 TXD -> RX engine -> led[7:0] + TX engine -> HC-05 RXD. |
| `src/fpga/de0_nano_rx_top.v` | DE0-Nano RX top: HC-05 TXD -> engine (UART RX program) -> rx_fifo -> rx_led_sink -> led[7:0]. |
| `src/fpga/de0_nano_top.v` | DE0-Nano top: KEY1 press -> msg_sender -> engine_top (UART TX program) -> HC-05. |
| `src/fpga/msg_sender.v` | Feeds a fixed ASCII message into the engine's tx_fifo, one byte per write, |
| `src/fpga/msg_sender.v.bak` | backup copy of msg_sender.v |
| `src/fpga/uart_rx_prog.hex` | Generated by host/uart_rx_prog.py -- do not edit. |
| `src/fpga/uart_tx_prog.hex` | UART TX 8N1, LSB first, out_pin=0. Bit period = D+2 cycles; D=432 -> 434 cycles = 115200 baud @ 50 MHz. |
| `src/instr_mem.v` | Instruction memory, 256 words x 32 bits: one IHP SG13 1P 256x32 SRAM macro (bit-mask + BIST variant). |
| `src/isa.vh` | Instruction word: [31:27] opcode, [26:0] operand (flat, one meaning per opcode). |
| `src/line_coder.v` | Line coder: byte-level serial line transceiver for two logical pins of an engine (docs/LINE_CODER.md). Generic, not USB-specific: |
| `src/loop_counter.v` | Loop counter for DJNZ: decrement on command, saturates at 0. |
| `src/mgmt.v` | Management controller: frame v1 (7 bytes, simple) and frame v2 (12 bytes, CRC-16, sequence numbers, pipelined results). |
| `src/pc_reg.v` | Program counter: holds at current value unless told to advance or jump. |
| `src/pdn_cfg.tcl` | Metal4-only power grid for Tiny Tapeout CMOS5L with IHP SRAM macros. |
| `src/pin_block.v` | 8 GPIO pins: per-pin output data + output enable registers, 2-stage input sync. |
| `src/pin_mgr.v` | Pin manager: every pin except the management link can be used by either engine (docs/PIN_MAP_PLAN.md). |
| `src/pnr.sdc` | Timing constraints for place-and-route and signoff. |
| `src/rx_led_sink.v` | Drains a first-word-fall-through rx_fifo: pops every word as soon as it appears |
| `src/shift_reg.v` | Generic serial shift register, used both as OSR (shift_out) and ISR (shift_in). |
| `src/spi_slave.v` | SPI mode 0 slave (CPOL=0, CPHA=0), MSB first, oversampled in the system clock domain. |
| `src/tt_um_protocol_emulator.v` | Tiny Tapeout top (template ports). Pin use (docs/PIN_MAP_PLAN.md): |

### G-tb  tb/ : Verilog testbenches, peer models and include files  (on branch `main`)

| file | what it is |
|---|---|
| `tb/host_knobs.vh` | Host-behaviour knobs for the chip-level workload harnesses (include after spi_master.vh). |
| `tb/i2c_slave_model.v` | I2C slave (target) model for the testbenches, written from the I2C specification, not from the |
| `tb/peer_can.v` | CAN 2.0A bus node for the protocol testbenches, written from the Bosch CAN 2.0 / ISO 11898-1 rules (not from the firmware): |
| `tb/peer_jtag.v` | IEEE 1149.1 TAP model for the protocol testbenches, written from the standard (state diagram, capture/shift/update), not from the firmware. |
| `tb/peer_models.v` | Verilog peer models for the protocol testbenches (written from the specifications, independent of the firmware). |
| `tb/peer_onewire.v` | 1-Wire slave model (DS18B20-style), written from the Maxim 1-Wire timing rules, not from the firmware. Standard speed. |
| `tb/ref/ref_engine.v` | REFERENCE MODEL, do not edit. The original engine fetch: combinational-read flop instruction memory |
| `tb/spi_master.vh` | SPI mode 0 master model (include inside a module). |
| `tb/spi_peer.vh` | Protocol-side SPI peers for the SPI testbenches (include inside a module), all 4 modes. |
| `tb/tb_alu_unit.v` | alu_unit: register file, every ALU function, flags, LDI, RGET, strobe isolation. |
| `tb/tb_chip_proto.v` | The protocol testbench of tb_proto.v on the FULL chip (tt_um_protocol_emulator): the host reaches the engines only through the |
| `tb/tb_combo_chip.v` | Two protocols at once on the full chip, everything through the management link (host/workload.py): |
| `tb/tb_common.vh` | Shared self-check macros. Each tb declares `integer errors = 0;`. |
| `tb/tb_control_unit.v` | control_unit + real delay_counter + real loop_counter; fifos/pins/shifters are |
| `tb/tb_crc_unit.v` | crc_unit against (A) published catalogue check values for "123456789", (B) bit-by-bit feeding, (C) an independent reference |
| `tb/tb_de0_nano_rx_top.v` | Top-level RX check at 50 MHz / 115200: bytes on bt_rx_pin must appear on led[7:0]. |
| `tb/tb_de0_nano_top.v` | DE0-Nano top: press KEY1 -> expect the whole message on bt_tx_pin as 115200 8N1. |
| `tb/tb_delay_counter.v` | delay_counter unit test: busy for exactly N cycles, last flag on the Nth |
| `tb/tb_engine_alu.v` | Register file / ALU / CRC instructions inside a real engine_top (directed programs, results known from the instruction table). |
| `tb/tb_engine_ops.v` | JPO and PUSHI inside a real engine_top: OSR bit order, RX FIFO data path, stall on a full FIFO. |
| `tb/tb_engine_top.v` | engine_top test: UART TX reference program, cycle-exact frame check, reset in the middle of a frame |
| `tb/tb_fetch_equiv.v` | Equivalence of the SRAM-fetch engine (engine_top: synchronous instr_mem addressed with next_pc) |
| `tb/tb_fifo.v` | fifo unit test: fill 4, 5th write rejected, first-word-fall-through, empty read ignored |
| `tb/tb_host_bridge.v` | Software SPI host bridge: the full chip (tt_um_protocol_emulator) driven line by line from stdin, so a Python program |
| `tb/tb_i2c_chip.v` | I2C master on the full chip, orchestrated by host/i2c_test.py. Everything the host does goes over |
| `tb/tb_i2c_engine.v` | I2C at engine level (engine_top + the real pin_mgr, pads 6/7 claimed open-drain for engine 0), |
| `tb/tb_instr_mem.v` | instr_mem (one 256x32 SRAM macro): synchronous host write, SYNCHRONOUS read (data appears one clock |
| `tb/tb_isa_diff.v` | Differential-test harness for engine_top: runs many (program, stimulus) pairs back to back and writes one trace line per clock. |
| `tb/tb_line_coder.v` | Line coder test bench (driven by host/line_coder_test.py). Two coders on one differential bus with the low-speed pull-up (idle = J): |
| `tb/tb_loop_counter.v` | loop_counter unit test: load, decrement, DJNZ saturation at 0 |
| `tb/tb_mgmt_dual.v` | Step 5: route instruction writes to engine 0 (0x1xxx) or engine 1 (0x2xxx). |
| `tb/tb_mgmt_duplex.v` | Step 8: full-duplex UART through the SPI management link, orchestrated by |
| `tb/tb_mgmt_frame.v` | Step 3: 7-byte frame {op, addr[15:0], data[31:0]} through the Tiny Tapeout pins. |
| `tb/tb_mgmt_load.v` | Step 4: load whole programs into engine 0 over SPI (one 7-byte frame per word, unused |
| `tb/tb_mgmt_pins.v` | Pin manager through the management link (full chip): window 0x0200 claims, readback, refusals (err), |
| `tb/tb_mgmt_read.v` | Step 6: READ over MISO. 7-byte frame both ways; MISO = {STATUS, 00, 00, data[31:0]}. |
| `tb/tb_mgmt_tx.v` | Step 7: WRITE TX_DATA (base+0x200) feeds the engine's TX FIFO; the UART TX firmware |
| `tb/tb_pc_reg.v` | pc_reg unit test: jump beats advance, next_pc prediction, reset |
| `tb/tb_pin_block.v` | pin_block unit test: direction/level, 2-clock input synchroniser latency |
| `tb/tb_pin_mgr.v` | pin_mgr unit test: exhaustive pad mux (owner x od x oe/out of both engines), claim rules, sticky violations with |
| `tb/tb_proto.v` | Generic protocol testbench: two engine_top instances on one 8-pin pad bus, orchestrated by host/proto_lib.py. |
| `tb/tb_rx_led_sink.v` | rx_led_sink + real fifo: every pushed word must appear on led (byte = [31:24]) in order. |
| `tb/tb_shift_reg.v` | shift_reg unit test: OSR/ISR both bit orders |
| `tb/tb_spi_chip.v` | SPI on the full chip (tt_um_protocol_emulator), orchestrated by host/spi_test.py. |
| `tb/tb_spi_engine.v` | SPI at engine level, orchestrated by host/spi_test.py. 10 ns = 1 system clock. |
| `tb/tb_uart_duplex.v` | Duplex echo harness for host/uart_duplex_workload.py (de0_nano_duplex_top, 10 ns = 1 cycle): |
| `tb/tb_uart_rx.v` | UART-RX workload harness driven by plusargs from host/uart_rx_workload.py: |
| `tb/tb_uart_workload.v` | Generic UART-TX workload harness driven by plusargs from host/uart_workload.py: |

### G-host  host/ : Python (models, firmware generators, test drivers, host API)  (on branch `main`)

| file | what it is |
|---|---|
| `host/alu_test.py` | ALU unit tests: tb_alu_unit with 12,000 random operations against a Python reference + 28 planted ALU bugs |
| `host/asm.py` | assembler for the engine ISA (opcodes, labels, REGION, TSTAMP, RPUT TRIG; words()/words_at(origin)) |
| `host/bus_model.py` | reactive wired-AND bus models around the cycle-exact engine model (SWD target, PS/2 host, etc.) |
| `host/can_model.py` | Python CAN 2.0A frame encoder/decoder (bit stuffing, CRC-15) used as oracle |
| `host/can_prog.py` | CAN transmit (112 words) and receive (186 words) firmware generator |
| `host/can_test.py` | CAN tests: 47 cases incl. 20 mutants, 1 Mbit/s..200 kbit/s, ACK, bad CRC, stuff errors |
| `host/chip_host.py` | ChipHost: the Python host API over the management link (frames v1/v2, pin claims, FIFOs, IRQ) + SimLink (chip RTL in Icarus via tb_host_bridge.v) |
| `host/chip_host_demo.py` | guided tour of the host API (9 scenarios, 574 frames, "all checks passed") |
| `host/crc_model.py` | Rocksoft CRC model + catalogue of 14 standard CRCs |
| `host/crc_test.py` | CRC unit verification: catalogue values, 3,280 random vectors, 14 planted bugs |
| `host/fw_layout.py` | places a firmware image at word FW_ORG of the memory (word 0 = JMP n) |
| `host/i2c_prog.py` | I2C master (46 words, 100/400/1000 kHz) and slave firmware generator |
| `host/i2c_slave_test.py` | I2C slave tests (45 cases incl. 16 mutants, every wrong address bit) |
| `host/i2c_test.py` | I2C master tests: selftest, peers, master, chip, mutants (checked against UM10204) |
| `host/isa_diff_test.py` | differential test RTL vs isa_model (random programs, 99 coverage points, engine mutants) |
| `host/isa_model.py` | cycle-exact Python model of one engine (every instruction, FIFOs, CRC unit, line coder, TSTAMP, trigger, shared memory windows) |
| `host/jtag_prog.py` | JTAG controller firmware (87 words) |
| `host/jtag_test.py` | JTAG tests against a Verilog TAP and a Python TAP (21 cases/4 mutants) |
| `host/line_coder_test.py` | line coder tests (1221 checks) + mutants (16/16 + 1 equivalent) |
| `host/line_model.py` | cycle-exact model of src/line_coder.v |
| `host/mgmt_duplex_stress.py` | full-duplex UART stress through the management link |
| `host/mgmt_v2_mutants.py` | planted-bug check of frame v2 (20 mutants of src/mgmt.v) |
| `host/mgmt_v2_test.py` | frame v2 tests on the chip RTL (236 checks: CRC, sequence, retry exactly once, random bit flips) |
| `host/modbus_prog.py` | Modbus RTU firmware (42 words TX, CRC-16 from the CRC unit) |
| `host/modbus_test.py` | Modbus tests (26 cases/10 mutants, 3.5-character silences) |
| `host/mutation.py` | helper: compile a testbench with a mutated source and run it |
| `host/onewire_prog.py` | 1-Wire master firmware (79 words, ROM/scratchpad CRC-8) |
| `host/onewire_test.py` | 1-Wire tests (18 cases/8 mutants, Maxim timing windows) |
| `host/proto_lib.py` | common harness for the protocol suites (compile + run tb_proto/tb_chip_proto, pin maps for PROTO_REMAP, PROTO_CHIP, PROTO_SHARED) |
| `host/ps2_prog.py` | PS/2 device firmware (89 words) |
| `host/ps2_test.py` | PS/2 tests (28 cases/8 mutants, reactive host) |
| `host/regress.py` | the regression: phases A-D (+E, F on the shared branch), one log per suite, summary.md |
| `host/smbus_test.py` | SMBus PEC tests (23 cases/7 mutants) |
| `host/spi_prog.py` | SPI master/slave firmware generator (all modes) |
| `host/spi_test.py` | SPI tests (312 cases incl. 64 mutants; chip phase 52 cases) |
| `host/swd_prog.py` | SWD host firmware (161 words) |
| `host/swd_test.py` | SWD tests against a reactive ADIv5 target (11 cases/4 mutants) |
| `host/uart_duplex_workload.py` | FPGA duplex echo workload (does not build with the macro memory; not run) |
| `host/uart_rx_prog.py` | UART RX firmware generator (9 words; writes src/fpga/uart_rx_prog.hex) |
| `host/uart_rx_workload.py` | UART RX workload (fake phone edges, baud error window) |
| `host/uart_workload.py` | UART TX workload (1024 bytes at several baud rates) |
| `host/usb_device_host.py` | host software that composes USB descriptors/reports and serves the packet-shuttle firmware |
| `host/usb_host.py` | reactive USB low-speed host model |
| `host/usb_ls.py` | USB 2.0 low-speed signalling written from the spec (CRC5/CRC16, SYNC, NRZI, stuffing, EOP, decoder) |
| `host/usb_model_link.py` | fast stand-in for SimLink in USB tests (engine model instead of RTL) |
| `host/usb_mutants.py` | planted-bug check of the USB firmware (18 mutants) |
| `host/usb_prog.py` | USB low-speed device firmware (203 words, packet shuttle) |
| `host/usb_test.py` | USB tests (45 checks on model and RTL, host rate 0/+-1.5 %) |
| `host/workload.py` | workload campaign: every protocol only through the management link (UART, SPI, I2C, combo) |
| `host/ws2812_prog.py` | WS2812 firmware (25 words) |
| `host/ws2812_test.py` | WS2812 tests (15 cases/5 mutants, datasheet pulse windows) |

### G-formal  formal/ : SymbiYosys proofs  (on branch `main`)

| file | what it is |
|---|---|
| `formal/README.md` | Formal proofs (SymbiYosys) |
| `formal/engine.sby` | SymbiYosys job: engine_top proof (held engine drives no pin), SRAM replaced by sram_free.v |
| `formal/engine_props.sv` | Formal property of one protocol engine (src/engine_top.v with all its units; the SRAM macro is its synthesis blackbox, so the |
| `formal/fifo.sby` | SymbiYosys job: fifo equals an ideal depth-4 queue |
| `formal/fifo_props.sv` | Formal properties of src/fifo.v (SymbiYosys, formal/fifo.sby): the FIFO behaves exactly like an ideal queue of depth 4. |
| `formal/formal_mutants.py` | Mutation check of the formal proofs: every planted bug must make its proof FAIL (a proof that still passes on a broken design |
| `formal/mgmt.sby` | SymbiYosys job: spi_slave + mgmt + pin_mgr as on the chip |
| `formal/mgmt_props.sv` | End-to-end formal properties of the management side: src/spi_slave.v + src/mgmt.v + src/pin_mgr.v as wired in |
| `formal/pin_mgr.sby` | SymbiYosys job: pin_mgr safety proofs |
| `formal/pin_mgr_props.sv` | Formal properties of src/pin_mgr.v (SymbiYosys, formal/pin_mgr.sby). Safety obligations V01 / V02 of the architecture, extended |
| `formal/run_formal_wsl.sh` | Run SymbiYosys proofs with the sby / yosys / abc from LibreLane's Nix shell. Usage: bash formal/run_formal_wsl.sh [name.sby ...] |
| `formal/sram_free.v` | Formal stand-in for the IHP SRAM macro: same ports, the read data is a fresh arbitrary value every clock. A property proved |

### G-librelane  librelane/ : layout-flow scripts, variant settings, picture and analysis tools  (on branch `main`)

| file | what it is |
|---|---|
| `librelane/area_by_module.py` | Yield (cell_type, instance_name) of the top-level module body of a Yosys netlist. |
| `librelane/collect_tt_wsl.sh` | Copy the small result files of a Tiny Tapeout-flow run (run_tt_wsl.sh) from the WSL disk into the repo. |
| `librelane/collect_wsl.sh` | Copy the small result files of a LibreLane run (metrics, resolved config, routing DRC, STA summaries) from the WSL |
| `librelane/compare_runs.py` | Side-by-side table of the metrics of several flow runs. |
| `librelane/config.json` | first (non Tiny Tapeout) LibreLane configuration used for run1-run3 of 2026-10-17 |
| `librelane/floorplan_compact_cfg.json` | flow variant "compact": settings overlaid by flow_variant_*.sh (6x4 compact columns, tt10b/tt10c) |
| `librelane/floorplan_symmetric_cfg.json` | flow variant "symmetric": settings for the symmetric engine-fence layout (tt9c, tt10d) |
| `librelane/floorplan_tri_cfg.json` | flow variant "tri": 8x4 three-column floorplan settings (tt14b) |
| `librelane/flow_run_wsl.sh` | One complete TT-flow run in its own work directory (so several runs can go in parallel). |
| `librelane/flow_variant_linux.sh` | Linux version of flow_variant_wsl.sh + flow_run_wsl.sh + run_tt_wsl.sh in one: a full TT-flow run with a floorplan variant. |
| `librelane/flow_variant_wsl.sh` | Flow run with a floorplan variant: per-run overrides from librelane/<variant>_cfg.json + the matching engine fences in src/. |
| `librelane/gl_test_wsl.sh` | Gate-level cocotb test (test/test.py, same tests as RTL) of the routed netlist of a run, with Tiny Tapeout's Icarus Verilog 13.0 |
| `librelane/install_tt_librelane_wsl.sh` | Second LibreLane checkout at the release Tiny Tapeout's GitHub gds action installs (tt-gds-action@ihp-cmos5l: |
| `librelane/install_tt_pdk_wsl.sh` | Install the IHP-Open-PDK revision that Tiny Tapeout's GitHub gds action uses (tt-gds-action@ihp-cmos5l, install_sg13cmos5l.sh), |
| `librelane/live_images_linux.sh` | Live images while flow runs are going: after every new step of each run, render the new stage (render_stages.py, incremental), |
| `librelane/live_images_shared_wsl.sh` | Live images while flow runs are going: after every new step of each run, render the new stage (render_stages.py, incremental), |
| `librelane/live_images_wsl.sh` | Live images while flow runs are going: after every new step of each run, render the new stage (render_stages.py, incremental), |
| `librelane/macro/RM_IHPSG13_1P_256x32_c2_bm_bist.v` | Blackbox for synthesis: the real macro is a hard IP (LEF/GDS/liberty from the PDK). |
| `librelane/magic_drc_summary.py` | Count Magic DRC violations by rule and by location (inside / outside the SRAM macro boxes). |
| `librelane/make_gallery.py` | Write README.md and index.html next to the stage images made by render_stages.py (and the module maps of module_map.py). |
| `librelane/module_map.py` | (group key, engine or None) of an instance name. |
| `librelane/module_map_shared_linux.sh` | Annotated placement of a run step (librelane/module_map.py): module-coloured map + module/engine regions over the KLayout picture. |
| `librelane/module_map_shared_wsl.sh` | Annotated placement of a run step (librelane/module_map.py): module-coloured map + module/engine regions over the KLayout picture. |
| `librelane/module_map_wsl.sh` | Annotated placement of a run step (librelane/module_map.py): module-coloured map + module/engine regions over the KLayout picture. |
| `librelane/module_report.py` | Where did each module's cells end up? Reads a placed DEF, colours every standard cell by the module its instance name belongs to |
| `librelane/net_matrix.py` | Module-to-module connectivity of a placed design: how many nets connect each pair of modules (instance-name prefixes of |
| `librelane/precheck_linux.sh` | Tiny Tapeout precheck (tt-support-tools, branch ihp-sg13cmos5l) on the final GDS of a run made by flow_variant_linux.sh. |
| `librelane/precheck_wsl.sh` | Tiny Tapeout precheck (tt-support-tools, branch ihp-sg13cmos5l) on the final GDS of a run made by flow_run_wsl.sh / run_tt_wsl.sh. |
| `librelane/render_stages.py` | Render one PNG per physical-design stage of a LibreLane run with KLayout (batch mode). |
| `librelane/render_wsl.sh` | Stage-by-stage KLayout images of a run (librelane/render_stages.py), then the gallery (README.md + index.html). |
| `librelane/report_modules_wsl.sh` | Where did each module's cells end up? Table + module-coloured picture (librelane/module_report.py) for a step of a run. |
| `librelane/run_cocotb_wsl.sh` | cocotb smoke tests (test/test.py) in WSL on a copy of the project: RTL by default, gate level with GATES=yes |
| `librelane/run_tt_wsl.sh` | Tiny Tapeout CMOS5L flow for tt_um_protocol_emulator, run inside WSL in LibreLane's Nix shell. |
| `librelane/run_wsl.sh` | Run the LibreLane flow for tt_um_protocol_emulator inside WSL, in LibreLane's Nix shell. |
| `librelane/synth_variants_wsl.sh` | Synthesis + pre-layout STA of the TT configuration with different Yosys strategies (and optional extra config JSON): |

### G-librelane_plugin_project  librelane_plugin_project/ : custom LibreLane steps (a Python package the flow finds from the repository root)  (on branch `main`)

| file | what it is |
|---|---|
| `librelane_plugin_project/__init__.py` | Project LibreLane plugin (package name must start with librelane_plugin_). |
| `librelane_plugin_project/bridge_stripes.py` | LibreLane plugin: step Project.BridgeMacroStripes (see odb_bridge_macro_stripes.py). |
| `librelane_plugin_project/module_regions.py` | LibreLane plugin: step Project.ModuleRegions (see odb_module_regions.py). |
| `librelane_plugin_project/netgen_json.py` | LibreLane plugin: tolerate the invalid JSON escapes netgen writes for the IHP SRAM pin names. |
| `librelane_plugin_project/odb_bridge_macro_stripes.py` | OpenDB script (run by the Project.BridgeMacroStripes step): bridge the Metal4 power stripes across the SRAM macros. |
| `librelane_plugin_project/odb_module_regions.py` | OpenDB script (run by the Project.ModuleRegions step): give every major module its own placement region (fence). |
| `librelane_plugin_project/odb_remove_module_regions.py` | OpenDB script (run by the Project.RemoveModuleRegions step): delete the module regions (fences) created by odb_module_regions.py. |

### G-sim  sim/ihp_sram/ : manufacturer simulation models of the SRAM macros (vendored, Apache-2.0)  (on branch `main`)

| file | what it is |
|---|---|
| `sim/ihp_sram/README.md` | IHP SG13 SRAM simulation models (vendored, Apache-2.0) |
| `sim/ihp_sram/RM_IHPSG13_1P_256x32_c2_bm_bist.v` | IHP simulation wrapper of the 1P 256x32 SRAM macro (checks A_DLY tied high; instantiates the behavioural core) |
| `sim/ihp_sram/RM_IHPSG13_1P_64x16_c2.v` | IHP simulation model of the 1P 64x16 macro (used while instruction memory was 2 x 64x16, 2026-10-11) |
| `sim/ihp_sram/RM_IHPSG13_1P_core_behavioral.v` | IHP behavioural core of the 64x16 macro |
| `sim/ihp_sram/RM_IHPSG13_1P_core_behavioral_bm_bist.v` | IHP behavioural core (bit-mask + BIST variant) used by the 256x32 macro model; array is called `memory` |

### G-macro  macro/ : the SRAM macro files the layout flow uses (abstract, layout, circuit, timing at 3 corners)  (on branch `main`)

| file | what it is |
|---|---|
| `macro/RM_IHPSG13_1P_256x32_c2_bm_bist/RM_IHPSG13_1P_256x32_c2_bm_bist.cdl` | circuit description (netlist) of the 1P 256x32 macro for LVS |
| `macro/RM_IHPSG13_1P_256x32_c2_bm_bist/RM_IHPSG13_1P_256x32_c2_bm_bist.gds` | layout of the 1P 256x32 macro |
| `macro/RM_IHPSG13_1P_256x32_c2_bm_bist/RM_IHPSG13_1P_256x32_c2_bm_bist.lef` | abstract (pins, size, power columns) of the 1P 256x32 macro |
| `macro/RM_IHPSG13_1P_256x32_c2_bm_bist/RM_IHPSG13_1P_256x32_c2_bm_bist.v` | Blackbox for synthesis: the real macro is a hard IP (LEF/GDS/liberty from the PDK). |
| `macro/RM_IHPSG13_1P_256x32_c2_bm_bist/RM_IHPSG13_1P_256x32_c2_bm_bist_fast_1p32V_m55C.lib` | timing model, fast corner (1.32 V, -55 C) |
| `macro/RM_IHPSG13_1P_256x32_c2_bm_bist/RM_IHPSG13_1P_256x32_c2_bm_bist_slow_1p08V_125C.lib` | timing model, slow corner (1.08 V, 125 C) |
| `macro/RM_IHPSG13_1P_256x32_c2_bm_bist/RM_IHPSG13_1P_256x32_c2_bm_bist_typ_1p20V_25C.lib` | timing model, typical corner (1.20 V, 25 C) |

### G-synth  synth/ : early area-estimate synthesis (Yosys) and experiments  (on branch `main`)

| file | what it is |
|---|---|
| `synth/experiments/instr_mem_latch.v` | AREA EXPERIMENT ONLY: latch-array instruction memory (64 x 32), same ports as src/instr_mem.v. |
| `synth/experiments/instr_mem_sram_2x1p64x16.v` | AREA EXPERIMENT ONLY (never read by the simulation flow). |
| `synth/experiments/pin_mgr.v` | PROTOTYPE for an area estimate (not integrated, not simulated, not in src/). |
| `synth/run_synth.sh` | Wrapper: puts the OSS CAD Suite on PATH and runs the Yosys flow. Run from the repo root. |
| `synth/synth_cmos5l.tcl` | Yosys area/cell-count estimate against the real IHP sg13cmos5l standard-cell library. |

### G-test  test/ : cocotb tests used by the GitHub workflows  (on branch `main`)

| file | what it is |
|---|---|
| `test/Makefile` | cocotb makefile of the Tiny Tapeout test (RTL or gate level) |
| `test/requirements.txt` | Python packages of the cocotb test (installed by the GitHub test workflow) |
| `test/tb.gtkw` | GTKWave save file for the cocotb test bench |
| `test/tb.v` | wrapper of the design for cocotb |
| `test/test.py` | cocotb tests (status, pad owner, ALU + CRC program through the SPI port; run on RTL and on the gate-level netlist) |

### G-quartus  quartus/ : FPGA (DE0-Nano) Quartus projects  (on branch `main`)

| file | what it is |
|---|---|
| `quartus/protocol_emulator_duplex.qsf` | Revision "protocol_emulator_duplex": HC-05 -> RX engine -> LEDs + echo -> TX engine -> HC-05. |
| `quartus/protocol_emulator_fpga.qpf` | Quartus project file (DE0-Nano) |
| `quartus/protocol_emulator_fpga.qsf` | Quartus settings, revision protocol_emulator_fpga = UART TX build |
| `quartus/protocol_emulator_rx.qsf` | Revision "protocol_emulator_rx": HC-05 -> UART RX firmware -> LEDs. |

### G-.github  .github/workflows/ : GitHub Actions  (on branch `main`)

| file | what it is |
|---|---|
| `.github/workflows/docs.yaml` | GitHub workflow: builds the Tiny Tapeout docs page (runs on every push) |
| `.github/workflows/fpga.yaml` | GitHub workflow: FPGA bitstream for the TT ASIC simulator (disabled: branches: none) |
| `.github/workflows/gds.yaml` | GitHub workflow: build GDS with the official tt-gds-action, then precheck, gate-level test and viewer jobs (runs on every push; 4-6 h) |
| `.github/workflows/test.yaml` | GitHub workflow: RTL cocotb tests with Icarus Verilog |

### G-.vscode  .vscode/  (on branch `main`)

| file | what it is |
|---|---|
| `.vscode/settings.json` | editor settings |

### G-branch  Files that exist ONLY on branch `shared/on-v2` / `check/shared-sh8` (not on `main`), exact names

| file (added) | what it is |
|---|---|
| `docs/SHARED_IMEM_PLAN.md` | design of the shared 512-word memory (windows, lock, START, host access, layout experiments sh1-sh3) |
| `formal/imem_shared.sby` | SymbiYosys job: shared-memory proofs (fetch inside window, host writes, lock) |
| `formal/imem_shared_props.sv` | properties of imem_shared (fetch stays in the window, no host write into a running window or through a running port, lock until RUN falls) |
| `formal/region_go.sby` | SymbiYosys job: control unit passes OP_REGION only when unlocked and valid |
| `formal/region_go_props.sv` | properties for the OP_REGION request of control_unit |
| `formal/run_formal_linux.sh` | runs the proofs on Linux (sby/yosys from the Nix store; SRC_DIR option for mutants; work in ~/formal_work) |
| `formal/sram2p_free.v` | formal stand-in for the 2P macro (arbitrary read data every clock) |
| `host/isa_diff_shared.py` | (shared branch) differential test for the shared memory: random images/origins, both engines, RTL vs model; mutants (16) |
| `host/la_chip_test.py` | (shared branch) logic analyser on the chip RTL through the SPI link (registers, capture, VCD, sample mode, TSTAMP, trigger, IRQ, view) |
| `host/la_host.py` | (shared branch) host side of the logic analyser (configure, arm, trigger, wait_done, read_buffer, waveform) |
| `host/la_model.py` | (shared branch) logic analyser model, decoder, VCD writer/parser, random activity generator |
| `host/la_rtl_test.py` | (shared branch) la_unit RTL vs la_model clock by clock; 12 planted bugs |
| `host/shmem_chip_test.py` | (shared branch) shared memory on the chip RTL through the SPI link (two images, windows, faults, lock, host write rules) |
| `host/shmem_host.py` | (shared branch) host layer: Image, plan_images, verified load_image, start(), ShmemHost |
| `host/shmem_test.py` | (shared branch) shared-memory host rules + two engine models on one SharedImem (no chip) |
| `librelane/bars.py` | draws the macro power bars (analysis helper for the stripe grid) |
| `librelane/floorplan_shared3_cfg.json` | flow variant "shared3": 8x4, compact columns, shared 2P macro at the bottom centre, matched stripe grid 53.04/6.74/18.545, SHARED_IMEM define |
| `librelane/floorplan_shared_cfg.json` | flow variant "shared": first (L-shaped engines) shared-memory floorplan (run sh2, congested) |
| `librelane/pdn_check.py` | checks a power grid for stripes over wrong-net macro columns (found the sh3 short) |
| `librelane/pdn_scan.py` | scans stripe pitch/offset combinations for no wrong-net overlap with the 2P macro (found 53.04 / 18.545) |
| `macro/RM_IHPSG13_2P_512x32_c2_bm_bist/RM_IHPSG13_2P_512x32_c2_bm_bist.cdl` | circuit description of the 2P 512x32 macro for LVS |
| `macro/RM_IHPSG13_2P_512x32_c2_bm_bist/RM_IHPSG13_2P_512x32_c2_bm_bist.gds` | layout of the 2-port 512x32 macro (the shared instruction memory) |
| `macro/RM_IHPSG13_2P_512x32_c2_bm_bist/RM_IHPSG13_2P_512x32_c2_bm_bist.lef` | abstract of the 2P 512x32 macro (power columns 4.42 um wide, 17.68 um pitch) |
| `macro/RM_IHPSG13_2P_512x32_c2_bm_bist/RM_IHPSG13_2P_512x32_c2_bm_bist.v` | synthesis blackbox of the 2P 512x32 macro |
| `macro/RM_IHPSG13_2P_512x32_c2_bm_bist/RM_IHPSG13_2P_512x32_c2_bm_bist_fast_1p32V_m55C.lib` | timing model, fast corner |
| `macro/RM_IHPSG13_2P_512x32_c2_bm_bist/RM_IHPSG13_2P_512x32_c2_bm_bist_slow_1p08V_125C.lib` | timing model, slow corner |
| `macro/RM_IHPSG13_2P_512x32_c2_bm_bist/RM_IHPSG13_2P_512x32_c2_bm_bist_typ_1p20V_25C.lib` | timing model, typical corner |
| `sim/ihp_sram/RM_IHPSG13_2P_512x32_c2_bm_bist.v` | IHP simulation wrapper of the 2P 512x32 macro (array: u_mem.i_SRAM_2P_behavioral_bm_bist.mem_arr) |
| `sim/ihp_sram/RM_IHPSG13_2P_core_behavioral_bm_bist_ideal.v` | IHP behavioural core of the 2P macro (ideal timing) |
| `src/floorplan_engines_shared.json` | engine fences for the first shared-memory floorplan (variant shared, sh2) |
| `src/floorplan_engines_shared3.json` | engine fences for the compact shared-memory floorplan (variant shared3: sh3-sh10) |
| `src/imem_shared.v` | shared 512-word instruction memory: 2P macro, per-engine window (OP_REGION), lock, host write/read through a held engine's port, trap outside the window |
| `src/la_block.v` | logic analyser block (only with -DLA): timestamp counter, pin synchroniser, la_unit, 1P 256x32 buffer, register window 0x0300 |
| `src/la_unit.v` | logic analyser capture state machine (change/sample mode, triggers, ring buffer); behaviour = host/la_model.py |
| `tb/shared_imem.vh` | include for testbenches of the shared-memory chip (poke/peek of the 2P macro) |
| `tb/tb_imem_shared.v` | imem_shared unit test (windows, lock, host access, traps) |
| `tb/tb_isa_diff_shared.v` | differential-test harness for the shared memory: imem_shared + two engine_top, one trace line per engine per clock |
| `tb/tb_la_unit.v` | la_unit test bench (random configuration and pin activity; compared with host/la_model.py by host/la_rtl_test.py) |

Files that exist on both but were **changed** on the shared branch (the differences are described in Part C): `formal/README.md`, `formal/formal_mutants.py`, `formal/mgmt_props.sv`, `formal/pin_mgr_props.sv`, `host/asm.py`, `host/chip_host.py`, `host/i2c_test.py`, `host/isa_diff_test.py`, `host/isa_model.py`, `host/proto_lib.py`, `host/regress.py`, `host/spi_test.py`, `info.yaml`, `librelane/flow_run_wsl.sh`, `librelane/flow_variant_wsl.sh`, `src/config.json`, `src/control_unit.v`, `src/dbg_view.v`, `src/engine_top.v`, `src/instr_mem.v`, `src/isa.vh`, `src/mgmt.v`, `src/pc_reg.v`, `src/pin_mgr.v`, `src/tt_um_protocol_emulator.v`, `tb/tb_chip_proto.v`, `tb/tb_control_unit.v`, `tb/tb_engine_alu.v`, `tb/tb_i2c_chip.v`, `tb/tb_i2c_engine.v`, `tb/tb_isa_diff.v`, `tb/tb_pc_reg.v`, `tb/tb_pin_mgr.v`, `tb/tb_spi_chip.v`. On `check/shared-sh8` `src/config.json` is replaced by the sh8 recipe (commit 884a7fd).

### G-docs  docs/ : documents (every file; title = first heading)

| file | title / what it is |
|---|---|
| `docs/ALU_CRC_I2CSLAVE_PLAN.md` | Plan: ALU + CRC units, I2C slave, protocol suite, boxed floorplan (2026-10-18) |
| `docs/ALU_CRC_RESULTS.md` | ALU + CRC units, I2C slave, protocol suite, floorplan: what came out (2026-10-18) |
| `docs/ASIC_AREA_AND_MEMORY_STUDY.md` | ASIC Area, SRAM and Pin-Ownership Study |
| `docs/BIGMEM_RESULTS.md` | 256-word instruction memory per engine: changes and RTL results |
| `docs/CHALLENGE_CHECK.md` | Challenge check against the rules (state of 2026-10-18) |
| `docs/CLOCK_SPEED_EFFECTS.md` | Running below 50 MHz: what changes and how to adjust |
| `docs/DEBUG_LA_PLAN.md` | Logic analyser, protocol sniffer and engine debug: implementation and verification plan |
| `docs/ETHERNET_FEASIBILITY.md` | 10 Mbit Ethernet (10BASE-T): feasibility on this chip |
| `docs/EXECUTION_PLAN.md` | Protocol Emulator ASIC — Execution Plan |
| `docs/HANDOFF_LINUX.md` | Status 2026-10-20 (native Ubuntu, read this before the rest) |
| `docs/HOST_INTERFACE.md` | Host interface: everything that passes between the host and the chip |
| `docs/I2C_PLAN.md` | I2C Master and Slave + Pin Manager — Implementation and Verification Plan |
| `docs/I2C_RESULTS.md` | I2C Master, Pin Manager and ISA Additions — Test Methods and Results |
| `docs/LIBRELANE_RESULTS.md` | LibreLane run (Nix shell in WSL): first RTL-to-layout result with the 256-word memory |
| `docs/LINE_CODER.md` | Line coder: the `LINE` opcode (built 2026-10-19) |
| `docs/MEMORY_RAW_LOG_until_2026-10-20.md` | the old, unordered memory.md kept word for word |
| `docs/MGMT_PLAN.md` | Management Module + SPI Host Link — Design and Status |
| `docs/PIN_MAP_PLAN.md` | Pin mapping, spare-pin defaults and bring-up debug: plan (week 2, 2026-10-26 .. 11-01) |
| `docs/PROTOCOL_CATALOGUE.md` | How many protocols can this chip pull off |
| `docs/PROTOCOL_EMULATOR_ARCHITECTURE.md` | Programmable Protocol Emulator ASIC |
| `docs/README.md` | Documentation map |
| `docs/SHARED_IMEM_SOFTWARE_PLAN.md` | Shared instruction memory: the software and verification work (what it is, what is missing, how it is done) |
| `docs/SPI_PLAN.md` | SPI Master and Slave on the Protocol Engine — Design and Status |
| `docs/SPI_RESULTS.md` | SPI Master and Slave — Test Methods and Results |
| `docs/SRAM_INSTR_MEM_RESULTS.md` | Instruction memory moved to SRAM macros: changes and measured gains |
| `docs/TEST_RESULTS.md` | Test results, all in one place (state of 2026-10-18) |
| `docs/TODO.md` | To-do (working list, started 2026-10-20) |
| `docs/PROGRESS_REPORT_2026-10-18_to_2026-10-20.md` | detailed report of 10-18 to 10-20: summary, timeline, architecture changes, flows, tests, logic analyser, infrastructure, submission readiness |
| `docs/TT_FLOW_RESULTS.md` | Tiny Tapeout CMOS5L flow: 6x4 tiles, two SRAM macros (2026-10-17/18) |
| `docs/USB_LS_PLAN.md` | USB low speed: design and status (weeks 2-4, 2026-10-26 .. 11-15; FPGA demo week 8) |
| `docs/USB_STANDALONE_PLAN.md` | Standalone USB low-speed device: plan and test plan |
| `docs/USER_GUIDE.html` | {box-sizing:border-box}html{scroll-behavior:smooth;scroll-padding-top:16px} |
| `docs/USER_GUIDE.md` | Protocol Emulator Chip: User Guide |
| `docs/WORKLOAD_RESULTS.md` | Workload Campaign Through the Host Link — UART, SPI, I2C — Methods and Results |
| `docs/WORKSTREAM1_ARCHITECTURE.md` | Workstream 1 — Architecture: Staged, Incremental Plan |
| `docs/WORKSTREAM2_RTL_IMPLEMENTATION.md` | Workstream 2 — RTL Implementation Plan |
| `docs/build_user_guide.py` | Local images are embedded (data URI) so the HTML is one self-contained file; web images stay links. |
| `docs/diagram_core_internal.mmd` | Mermaid source: inside one engine (fetch, decode, registers, FIFOs, pins) |
| `docs/diagram_full_chip.mmd` | Mermaid source: the whole chip (management link, pin manager, two engines, memory) |
| `docs/info.md` | Tiny Tapeout project description page source (how it works, how to test) shown on the project page |

`docs/images/` (user guide figures, 54 files): `make_images.py` (runs everything), `svg.py` (SVG helper), `figs_a.py` (system, block diagram, pins, Pico wiring, power-up, bring-up, protocol wiring), `figs_b.py` (SPI mode, frames, STATUS, address map, ownership, open drain, windows, states, load sequence, programming model, timing, UART/I2C/USB/WS2812/CAN, clock scaling), `figs_c.py` (logic analyser figures, GTKWave layout, debug, troubleshooting, verification layers, the real capture example); generated figures: `example_capture.vcd`, `fig_address_map.svg`, `fig_block_diagram.svg`, `fig_bringup_flow.svg`, `fig_can_frame.svg`, `fig_clock_scaling.svg`, `fig_debug_overview.svg`, `fig_engine_states.svg`, `fig_frame_formats.svg`, `fig_gtkwave_layout.svg`, `fig_i2c_transfer.svg`, `fig_instruction_timing.svg`, `fig_la_capture_example.png`, `fig_la_channels.svg`, `fig_la_ring.svg`, `fig_la_states.svg`, `fig_la_words.svg`, `fig_la_workflow.svg`, `fig_load_sequence.svg`, `fig_memory_windows.svg`, `fig_open_drain.svg`, `fig_pico_wiring.svg`, `fig_pin_groups.svg`, `fig_pin_ownership.svg`, `fig_power_up.svg`, `fig_programming_model.svg`, `fig_spi_mode0.svg`, `fig_status_byte.svg`, `fig_system_context.svg`, `fig_troubleshoot_link.svg`, `fig_uart_frame.svg`, `fig_usb_packet.svg`, `fig_usb_stages.svg`, `fig_verification_layers.svg`, `fig_wire_can.svg`, `fig_wire_i2c.svg`, `fig_wire_jtag.svg`, `fig_wire_modbus.svg`, `fig_wire_onewire.svg`, `fig_wire_ps2.svg`, `fig_wire_spi_master.svg`, `fig_wire_spi_slave.svg`, `fig_wire_swd.svg`, `fig_wire_uart.svg`, `fig_wire_usb.svg`, `fig_wire_ws2812.svg`, `fig_ws2812_bits.svg`; `third_party/pico-pinout-r0.3-circuitstate.png` (downloaded, CC BY-SA 4.0) and `third_party/ATTRIBUTION.md`.
`docs/build_user_guide.py`: dependency-free converter USER_GUIDE.md -> USER_GUIDE.html (embeds images as data URIs). `docs/diagram_core_internal.mmd`, `docs/diagram_full_chip.mmd`: Mermaid sources of the two architecture diagrams.

### G-root  Files in the repository root

| file | what it is |
|---|---|
| `README.md` | project front page: status table, repository map, how to run, link to the user guide |
| `memory.md` | THIS FILE |
| `LICENSE` | Apache-2.0 licence (copyright line filled in by the user on 2026-10-20) |
| `info.yaml` | Tiny Tapeout project description: title, 8x4 tiles, clock 50 MHz, source file list, pinout |
| `instructions.md` | the instruction set reference (every opcode, operands, timing) |
| `Challenge_general_instructions.md` | the challenge text (rules, goals, deadline) |
| `run_tests.sh` | Linux unit-testbench runner (22 benches, prints one RESULT line each) |
| `run_tests.ps1` | Windows (PowerShell) twin of run_tests.sh |
| `.gitignore` | files git ignores (build/, logs, ...) |
Untracked / local-only in the root: `build/` (compiled simulations and test work folders, never committed), `GDS_logs.zip` (logs downloaded from a GitHub gds run).

### G-results  results/ : evidence kept in the repository (exact folder names; "regression_*" folders hold one `<suite>.log` per suite + `summary.md`/`console.log`)
| folder | what it is | when / why |
|---|---|---|
| `results/README.md` | table of the folders below (older version) | 2026-10-18 |
| `results/uart_workload_2026-10-01/` | `payload.bin`, `sweep_log.txt`: first UART TX workload sweep at several baud rates | engine v0.1 verification |
| `results/spi_2026-10-11/full_run.txt` | full SPI suite run | SPI work, B4 |
| `results/i2c_2026-10-11/full_run.txt` | full I2C master suite run | I2C work, B5 |
| `results/workload_2026-10-12/` | `workload_uart.txt`, `workload_uartlimits.txt`, `workload_spi_i2c_combo.txt`, `uart_duplex_1KB_regression.txt` | workload campaign (docs/WORKLOAD_RESULTS.md) |
| `results/bigmem_2026-10-17/` | regression with the 256-word memory: `run_tests.txt`, `spi_test.txt`, `i2c_test.txt`, `mutants.txt`, `uart_duplex_115200.txt`, `uart_duplex_9600.txt`, `uart_rx_workload.txt`, `uart_tx_workload.txt`, `workload_all.txt`, `workload_uart_rerun.txt`, `fetch_equiv_seed1..5.txt` (lockstep vs the flop reference, 5.8 M clocks), `org192/` (firmware at word 192), `DONE` | B6 |
| `results/librelane_2026-10-17/run1`, `run3` | metrics/reports of the first plain-LibreLane layouts (run1 TopMetal1 shorts; run3 clean) | B7 |
| `results/tt_flow_2026-10-17/` | `tt2/` (first Tiny Tapeout run, fails the precheck), `tt5/` (accepted run: precheck, LVS, gate level), `images/` (stage pictures) | before the ALU/CRC units |
| `results/tt_flow_2026-10-18/` | `tt8b`, `tt9a`, `tt9b` (flat, signoff clean), `tt9c` (symmetric with fences), `tt10b` (compact + A+B, 30 ns), `tt10c` (compact + A+B, 20 ns, tape-out candidate then), `tt10d` (symmetric + A+B), `tt11a` (fetch stage), `tt12a` (main config with TT PDK): each holds `metrics.json/csv`, `config_merged.json`, `resolved.json`, step folders (`38-openroad-cts`, `58-openroad-stapostpnr`, `66-netgen-lvs`, `72-misc-reportmanufacturability`), `detailed_routing.drc`, `precheck_reports`; `<run>_images/` = stage pictures and module maps; `explore/` (module boxes, net matrix, exploration README); `floorplan_draft_compact.png`; `index.html` gallery | B8 |
| `results/tt_flow_2026-10-19/` | `tt14b_final/` (the 8x4 three-column run: gds, lef, lib, netlists, spef, sdf, metrics, config_merged.json), `tt14b_images/`, `sh3_reports/` (shared memory, shorted power grid), `sh4_partial/` (stopped run), `logs/` (`flow_tt14b.log`, `flow_sh3.log`, `flow_sh4.log`, `precheck_tt14b.txt`), `index.html` | B9 |
| `results/tt_flow_2026-10-20/sh4_final/` | metrics, config, logs, GDS and LEF of the first shared-memory layout (LVS clean) | C3 |
| `results/tt_flow_2026-10-20/sh10_final/` | `metrics.json`, `metrics.csv`, `config_merged.json`, `resolved.json`, `lef/tt_um_protocol_emulator.lef`, `logs/flow_sh10.log` of run sh10 (current RTL, sh8 recipe, no logic analyser) | C11 |
| `results/shared_2026-10-19/` | `index.html`, `sh2_images/`, `sh3_images/` (pictures of the first shared-memory runs) | B9 |
| `results/shared_2026-10-20/` | `index.html` + `sh4_images/ ... sh10_images/` (stage-by-stage pictures, module maps, galleries of every timing run). **`sh5a_images` ... `sh9b_images` are NOT committed** (untracked local files) | C3, C5 |
| `results/regression_2026-10-18/` | final regression on Windows: 26 of 26 pass | B8 |
| `results/regression_2026-10-18_pinmap/` | regression after the pin mapping | B8 |
| `results/regression_2026-10-19/`, `_19b`, `_19c`, `_19_remap` | Windows regressions on 10-19; `19c` was stopped for the move to Linux (19 of 25 phase A suites done, none failed); `19_remap` = remap seed suites | B9 |
| `results/regression_2026-10-20/`, `_20b`, `_20c`, `_20d`, `_20e` | first Linux runs: `20b` 41 pass / 6 fail (harness problems), `20c` partial reruns, `20d` 45 pass / 2 fail, `20e` the two fixed reruns -> **47 of 47** | C2 |
| `results/archive_old_worktrees/` | files rescued from the deleted worktree copies: `pe_baseline/` (`baseline`, `baseline_run.log`, `run_baseline.sh`), `pe_p2/` (`regress_p2.txt`, `regress_p2_clean.txt`, `spi_rerun.txt`), `pe_p4/engine_top_uncommitted.diff`, `pe_p6/regress_p6.txt`, `README.md` | C6 |
Not in `main`'s results/ but in the shared worktree `~/pe_shared_v2/results/` (untracked): `regression_2026-10-20_shared/`, `regression_repro_shared/`, `regression_repro_shared_rerun/`, `regression_repro_shared_final/`, `_final2/`, `_final3/` (the repair passes of C12: `_final3` = phase E 10/10).

### G-reproduce  reproduce/ : the reproduction kit (exact files)
| file | what it is |
|---|---|
| `reproduce/README.md` | the single walkthrough: install, sources, tests, formal, flow, precheck, docs, expected results, what cannot be reproduced |
| `reproduce/01_install_tools.sh` | Nix + Icarus 13 + SymbiYosys/Yices/Boolector + KLayout + GTKWave + LibreLane 3.1.0.dev3 + PDK 2bbec755 + tt-support-tools d66cf179 + two venvs |
| `reproduce/02_sources.sh` | creates the shared-branch working tree `~/pe_shared_v2` from `.git` or `branches.bundle` |
| `reproduce/03_tests.sh` | `main` or `shared` regression (`host/regress.py`) |
| `reproduce/04_formal.sh` | `formal/run_formal_linux.sh` + `formal/formal_mutants.py` |
| `reproduce/05_run_flow.sh` | reruns one archived flow from `reproduce/flows/<tag>` and compares with the archive |
| `reproduce/05b_run_historic_flow.sh` | rebuilds tt14b from commit e3846c3 |
| `reproduce/06_precheck_and_reports.sh` | Tiny Tapeout precheck + pictures of a finished run |
| `reproduce/07_docs.sh` | rebuilds the user guide figures and HTML |
| `reproduce/requirements_ttvenv.txt`, `requirements_pictvenv.txt` | pinned Python packages of the two venvs |
| `reproduce/versions.txt` | exact tool versions |
| `reproduce/SHARED_COMMIT` | commit of `shared/on-v2` the kit was written for (5bc90d8 era: out of date, refresh) |
| `reproduce/branches.bundle` | git bundle of `shared/on-v2`, `exp/shared-timing`, `feat/shared-imem`, `feat/frame-v2`, `merge/frame-v2` (relative to main; out of date) |
| `reproduce/tools/snapshot_flow.sh` | archive a finished run's inputs and metrics into `reproduce/flows/<tag>` |
| `reproduce/tools/compare_flow.py` | compares a rerun's configuration and all 190 metrics with the archive |
| `reproduce/tools/flow_table.py` | writes `reproduce/flows/README.md` (the sh4-sh9b table) |
| `reproduce/flows/README.md` | table of the nine archived runs (settings differing from sh4, slack, area, DRC, LVS, wire) |
| `reproduce/flows/<tag>/` for `sh4 sh5a sh5b sh5c sh6 sh7 sh8 sh9a sh9b sh10` | `src/` (the run's RTL and flow files: `alu_unit.v`, `config.json`, `control_unit.v`, `crc_unit.v`, `dbg_view.v`, `delay_counter.v`, `engine_top.v`, `fifo.v`, `floorplan_boxes.json`, `floorplan_engines_{compact,shared,shared3,symmetric,tri}.json`, `imem_shared.v`, `instr_mem.v`, `isa.vh`, `line_coder.v`, `loop_counter.v`, `mgmt.v`, `pc_reg.v`, `pdn_cfg.tcl`, `pin_block.v`, `pin_mgr.v`, `pnr.sdc`, `rx_led_sink.v`, `shift_reg.v`, `spi_slave.v`, `tt_um_protocol_emulator.v`), `info.yaml`, `config_merged.json` (complete configuration), `expected_metrics.json` (final metrics; absent for runs archived before they finished), `command.txt` (first log line), `family.txt` (`shmem` for sh4-sh5c, `shared_v2` for sh6-sh9b) |
| `reproduce/flows/_common_shmem/`, `_common_shared_v2/` | `macro/` (the 1P and 2P macro files) and `librelane_plugin_project/` shared by the runs of one family |

### G-outside  Folders and files outside the repository (this machine)
| path | what it is |
|---|---|
| `/media/rishadd/OS/Data/protocol_emulator` | the repository (NTFS data drive) |
| `/media/rishadd/OS/Data/protocol_emulator_shmem` | old working copy of branch `feat/shared-imem`; source tree of flows sh4, sh5a, sh5b, sh5c (kept) |
| `/media/rishadd/OS/Data/protocol_emulator_fetch` | 1.6 GB copy with the fetch-stage experiment (branch `exp/fetch-stage`); untouched |
| `/media/rishadd/OS/Data/projects` | unrelated user projects (not part of this work) |
| `~/pe_shared_v2` | working tree of `shared/on-v2` (now on `check/shared-sh8`); source of flows sh7-sh10 and of the whole shared-memory/analyser work |
| `~/pe_shared` | worktree of `exp/shared-timing` (source of flow sh6) |
| `~/pe_merge_lx` | worktree of `test/merge-lx` (merge test) |
| `~/pe_sh4 ... ~/pe_sh9b`, `~/pe_sh10`, `~/pe_sh8r` | work folders of the flow runs (`src/`, `macro/`, `tt/`, `runs/<tag>/` with the 72 numbered step folders, `final/`) |
| `~/flow_sh4.log ... ~/flow_sh10.log`, `~/flow_sh8r.log` | the live logs of those runs (last line `exit code N`) |
| `~/precheck_sh4.txt`, `~/precheck_sh4.done` | precheck output of sh4 |
| `~/regress_la3.log`, `~/regress_rerun.log`, `~/regress_final.log`, `~/regress_final2.log`, `~/regress_final3.log`, `~/regress_shared_full.log` | the regression passes of C12 |
| `~/formal_la3.log`, `~/formal_work/` | formal run after the logic analyser changes; work folders of the proofs |
| `~/librelane-3.1.0.dev3`, `~/librelane-dev` | LibreLane release used by all flows / development checkout (older runs) |
| `~/pdk_tt` | IHP-Open-PDK 2bbec755; `~/tt-support-tools` (branch ihp-sg13cmos5l); `~/ttvenv`, `~/pictvenv` (Python venvs) |
| `~/protocol_emulator_all_refs_2026-10-20.bundle` | backup of every branch before the clean-up |
| `~/pe_repro_trees/`, `~/pe_repro_src_e3846c3/` | trees assembled by `reproduce/05_run_flow.sh` / `05b` |
