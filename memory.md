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

## B2. 2026-10-11: the management link (SPI), steps 1-8 (simulation only)
- **Why:** programs must be loadable and the chip controllable by a host (Pico/PC) over a few pins, because later the memory will not be loadable any other way. Plan: [docs/MGMT_PLAN.md](docs/MGMT_PLAN.md), eight steps agreed with the user.
- **Built, step by step:** (1) instruction memory got a write port; (2) `spi_slave` (SPI mode 0) + a minimal `mgmt` block + the Tiny Tapeout top-level pins (`ui_in[0..2]` = SCLK/MOSI/CS_N, `uo_out[0]` = MISO); (3) **frame v1**: 7 bytes `{op, address(2), data(4)}`, big endian, a write commits only on the CS_N rising edge of a complete frame; `RUN` bit holds an engine in reset; (4) full program loads over SPI; (5) a **second engine** (address 0x2000), pin conflicts resolved temporarily by "engine 0 wins"; (6) reads (STATUS byte + data) including popping the RX FIFO without torn or lost bytes; (7) TX FIFO writes with host flow control; (8) a full-duplex stress test (1 KB over 115200 baud, both directions at the same time, with jitter and peer baud errors).
- **Tests and why:** one testbench per step (`tb_mgmt_frame`, `_load`, `_dual`, `_read`, `_tx`, `tb_mgmt_duplex`), each with golden engines in lockstep (a second engine loaded by `$readmemh` must match every clock), plus deliberately broken versions ("mutations") that each test must catch.
- **Problems and fixes:** a read-decode bug (must use the frame position after 3 bytes); a UART model that sampled on a zero-width simulation glitch (lesson: models must sample on clock edges, because pad multiplexing makes 0-ns glitches).
- **Outcome:** 16 testbenches pass; the full-duplex run delivered 1024/1024 bytes in all good cases; overload cases lose data as predicted (documented).

## B3. 2026-10-11: area study and SRAM instruction memory
- **Why:** the chip must fit in the Tiny Tapeout area. Question: where does the area go? ([docs/ASIC_AREA_AND_MEMORY_STUDY.md](docs/ASIC_AREA_AND_MEMORY_STUDY.md))
- **Finding:** with flip-flop memories the chip is 414,137 um2 (57.5 % of the 6x4 allowance), 80 % of it the two instruction memories. Using the manufacturer's SRAM macros instead: about 143k um2 (20 %).
- **Built (commit 1f7f61a):** instruction memory = two 1P 64x16 macros per engine; because SRAM reads are synchronous the program counter now outputs the *next* address ("next_pc"), so the instruction still arrives on time. FIFO strobes had to be masked when an engine is stopped.
- **Tests:** new `tb_fetch_equiv` runs the new engine in lockstep against the old flip-flop engine (0 mismatches); all UART and SPI full-duplex tests repeated (identical counts).
- **Open at the time:** whether Tiny Tapeout accepts these macros on this process (the user later decided: do not question it).
- **Outcome:** chip 414,137 -> 143,421 um2 (-65 %).

## B4. 2026-10-11: SPI master and slave as firmware
- **Why:** second protocol of the challenge ([docs/SPI_PLAN.md](docs/SPI_PLAN.md), results [docs/SPI_RESULTS.md](docs/SPI_RESULTS.md)).
- **Architectural change (asked for in the plan):** two new instructions `JPH`/`JPL` (jump if a pin is high/low) because polling a pin without branching costs too many instructions.
- **Built:** master 17/18 words, slave 18/16 words, all four SPI modes, 1-32 bits per frame, bit order either way.
- **Tests:** a Verilog peer and a Python decoder, 312 cases including mutants (64 planted bugs caught); timing measured to the clock.
- **Problems and fixes:** X->0 at reset counted as a clock edge; chip-level pads needed `assign #1` to hide zero-width pulses; the slave's response time had to become a measured limit; "CS setup" had to be defined as CS-fall to first edge or the sweep never stressed it.
- **Result:** exact master timing in all modes; slave limits measured (half period >= 4/5 clocks...); at chip level the slave needs about 2 management frames per SPI frame.

## B5. 2026-10-11 to 12: I2C master and the pin manager
- **Why:** third mandatory protocol; I2C needs open-drain pins and clock stretching, which forced a pin-ownership design ([docs/I2C_PLAN.md](docs/I2C_PLAN.md)). User approved the plan items D1-D8.
- **Architectural changes (all justified as reusable):** `JPO` (jump on the next output bit) and `PUSHI` (push an immediate value into the RX FIFO, used for event codes); a **pin manager** (`src/pin_mgr.v`): each pad owned by none/engine 0/engine 1, claim refused while the owner runs, per-pad open-drain, sticky "violation" flags. Consequence the user accepted: all chip-level tests had to claim pads first (done in a regression pass, decision D7).
- **Decision D8:** I2C *slave* not implemented yet (my first size estimate "<= 50 words" was wrong; about 64-67 words needed; later easy after the memory grew to 256 words).
- **Tests:** `tb_pin_mgr` (768 mux combinations), `tb_mgmt_pins`; I2C master: self-test 12/12, peers 7/7, master 24/24, chip 10/10, mutants 7/7, all checked against the I2C specification minimums at 100/400/1000 kHz.
- **Problems and fixes:** the slave model counted the SCL fall after START; the decoder must commit bits on SCL fall; a period padding bug (one SCL period 2499 ns at 400 kHz, 1 clock short) and a float rounding bug (25 clocks became 26) fixed in the generator.
- **Workload campaign (10-12, [docs/WORKLOAD_RESULTS.md](docs/WORKLOAD_RESULTS.md)):** long runs with host knobs (bursts, aborted frames, noise reads): UART 13/13, SPI+I2C+both together 42/42. Findings kept as documented limits: UART RX takes a 1 us glitch as a start bit, baud tolerance about -5 %/+4 %, SPI slave needs wide CS spacing when the host is slow.
- **Outcome:** three functional protocols (UART, SPI, I2C) with a growing instruction set; chip area with pin manager 150,000 um2.

## B6. 2026-10-17: 256-word instruction memory per engine
- **Why:** bigger firmwares (I2C slave, later USB, CAN). Results: [docs/BIGMEM_RESULTS.md](docs/BIGMEM_RESULTS.md).
- **Architectural change:** one 1P 256x32 macro per engine; 8-bit program counter; the JPH/JPL pin field moved to bits [10:8]; instruction window moved to address base+0x400.
- **Tests and why:** every protocol suite re-run (same results as with 64 words), firmware relocated to other addresses (`FW_ORG`) to prove position independence, lockstep against a 256-word flip-flop reference (0 mismatches in 5.8 million clocks).
- **Problems:** four places in the test harness silently assumed 64 words (e.g. a drain loop waiting for pc == 3, a mutant patching `len(ws)-2`, a test cycle budget eaten by loading 512 words); a program-counter truncation mutant survived until a test used pc >= 64.

## B7. 2026-10-17: first physical-design (layout) run
- **Why:** find out whether the design routes at all. LibreLane (open-source chip layout flow) in a Nix shell inside WSL ([docs/LIBRELANE_RESULTS.md](docs/LIBRELANE_RESULTS.md)).
- **Result:** a layout completes: setup +7.86 ns at a 20 ns constraint, LVS clean, 0 routing DRC errors; Magic DRC errors only inside the SRAM macros (ignored as in the reference SRAM design); 78 max-slew / 30 max-cap violations left. Not yet the official Tiny Tapeout flow (own die size).
- **Setup lessons:** LibreLane "dev" branch needed (the release could not read this PDK), `--manual-pdk`, always `bash -lc` in WSL, `$VAR` expansion by wsl.exe; routing shorts on TopMetal1 and a Metal4 cap made things worse, placement density 50 % routed clean.

## B8. 2026-10-18: the Tiny Tapeout flow, timing, formal proofs (a very long day)
**1. Why the first Tiny Tapeout runs never finished clean (root-cause analysis).** Wrong SRAM timing model in the slow corner, 0.25 ns clock uncertainty on hold (4,260 hold buffers), SRAMs acting as routing walls under the pins, repair after global routing, timing-driven placement off, and the CRC byte step sitting in the fetch cycle. All fixed in configuration, `src/pnr.sdc`, floorplan, and RTL.
**2. Register/ALU/CRC extension (new instructions 21-28) and pipelined CRC.** The engine got 8 general registers, an ALU (13 functions), a CRC unit supporting any width/polynomial (verified against 14 published CRC models), `RGET`/`RPUT`, `WAITR`, `LDI`, `JCC`. The CRC unit was pipelined for speed (command register; `RGET CRC` right after `CRC` waits 1 clock). Tests: ALU unit tests (28 planted bugs), CRC tests (3,280 random vectors, 14 planted bugs), differential test (RTL vs Python model, 600 programs x 400 clocks, 0 mismatches), engine mutants 24/24 then 26/26. See [docs/ALU_CRC_I2CSLAVE_PLAN.md](docs/ALU_CRC_I2CSLAVE_PLAN.md), [docs/ALU_CRC_RESULTS.md](docs/ALU_CRC_RESULTS.md).
**3. Layouts that passed everything.** tt9b (flat, 48.8 MHz slow corner) and tt9c (symmetric with engine "fences", 43.4 MHz): 0 DRC, 0 LVS, Tiny Tapeout precheck passes, gate-level test 3/3. Precheck lessons: macros only on whole stripe pitches, 17 um macro halo, `PL_KEEP_RESIZE_BELOW_OVERFLOW 0` needed with fences (else a placement crash).
**4. Three parallel improvement tracks.** (1) compact floorplan; (2) RTL "A+B": two register read ports + adder last in the ALU result mux (timing-neutral for firmware); (3) a **fetch stage** (registered SRAM output). Results: A+B regression 26/26 -> main baseline; tt10b/tt10c (compact + A+B) 19.45 / 19.8 ns = about 50 MHz with the tight constraint giving nothing extra; symmetric tt10d was only 3 % more wire than compact. **Decision: compact floorplan, tt10c setup is the tape-out candidate.** The **fetch stage was a verified experiment that did NOT help** (tt11a: -0.6 ns at 20 ns, a new critical path replaced the old) -> **recommendation not to merge; kept on branch `exp/fetch-stage`**.
**5. First push to GitHub (commit 70d332d and `exp/fetch-stage`).** The custom flow steps moved to `librelane_plugin_project/` so the official `tt_tool.py --harden` finds them. First GitHub gds run (39143586275) failed in global placement (GPL-0307 divergence). Cause chain found over the next day: the GitHub action pins an older PDK (2bbec755) *and* an older LibreLane release (3.1.0.dev3, tag of 2026-08-13, Yosys 0.66) than our local checkout, so synthesis gave 16,040 instead of 15,597 cells and placement took another path. Local runs now use exactly the action's PDK and release (tt13a reproduced GitHub's failure exactly).
**6. Formal verification started** (SymbiYosys, unbounded `abc pdr` proofs, `formal/`): pin manager (only the owner drives a pad, open-drain pads never driven high, no reclaim under a running engine, violations flagged), FIFO (equals an ideal queue), management (a state change only after a clean complete frame, memory only written while an engine is held), engine (a held engine drives no pin). 4 proofs; each proof also run against planted bugs: 20/20 caught (34/34 after pin mapping).
**7. IR drop** analysis on tt10c: worst 0.21 mV on VPWR, 0.18 mV on VGND (negligible). **Competitor review** (public repos): strongest are MarcosAsh (Hardcaml, 43 firmwares incl. USB/10BASE-T, FPGA USB demo), Loom (13 protocols incl. USB LS, 911 mutants, 8x4); we rank third by that review: deep peer-verified protocols, 50 MHz, formal pin safety, real hardware; gaps: USB LS, SWD/PS/2/WS2812, timing checker, automated mutation.
**8. Plan to 2026-12-30 agreed** ([docs/EXECUTION_PLAN.md](docs/EXECUTION_PLAN.md)) and the **working deadline set by the user**.
**9. Pin mapping built (first step):** every pin except the management link can be remapped to any engine pin; hold pin `ui_in[3]` (active high, so an undriven pin lets the chip run); IRQ on `uo_out[1]`; debug views on `uo_out[7:2]`. Tests: `tb_pin_mgr` (768 combos + remap), formal 34/34 planted bugs. Spec [docs/PIN_MAP_PLAN.md](docs/PIN_MAP_PLAN.md).
**10. Software SPI host** (`host/chip_host.py` + `chip_host_demo.py`, 574 frames, all checks pass) with the chip RTL as simulation backend; guide [docs/HOST_INTERFACE.md](docs/HOST_INTERFACE.md).

## B9. 2026-10-19: placement fix, USB groundwork, 8x4 tiles, more protocols, frame v2, shared memory, move to Linux
- **Placement fix chosen:** `PL_MAX_PHI_COEFFICIENT 1.03` (commit 3416ad3). GitHub branch `ci/gpl-phi` passed gds, precheck, gl_test; only the `viewer` job failed (GitHub Pages not enabled; the user was told how to enable it).
- **Remapped-pin tests:** the chip-level firmware suites repeated with random pin placements (seeds 1-3) to prove the remap hardware is transparent.
- **Line coder (USB prerequisite):** `LINE` opcode 28, `RGET` source 6; a USB low-speed signalling unit in each engine (NRZI, bit stuffing, SE0 end of packet, edge-tracking receiver). Tests: `usb_ls.py` written from the USB 2.0 spec, 1175 checks, differential test (600 programs x 600 clocks, 0 mismatches). **USB design decision:** a "packet shuttle": the chip handles the bus level; the host software composes descriptors (because ~160 bytes of descriptors do not fit in 256 words). New hardware for it: `RGET` source 7 = FIFO occupancy. A "TXW" instruction was designed and dropped.
- **tt14a FAILED in global routing** (6x4 tiles, pin mapping + line coder: cells 16,040 -> 20,334, +27 %). Response (user approved 8x4: "assume 8x is allowed"): a **three-column 8x4 floorplan** (engine 0 | common logic | engine 1). **tt14b routes: 0 DRC, LVS clean, +1.69 ns slack at 20 ns, hold +0.10 ns; main now uses it** (commit e3846c3).
- **Frame v2** (branch `feat/frame-v2`, f234342): 12-byte frames, CRC-16/CCITT-FALSE both ways, sequence numbers (commands strictly in order), pipelined results, a retry shows the same result again and is not executed twice, NOP, result codes, ID/VERSION/CAPABILITY/SCRATCH/ERRCNT registers; v1 unchanged. Tests: `mgmt_v2_test` 135 checks, later 236, including random bit-flipped frames that must never execute; 22 unit testbenches pass; bugs found on the way (payload byte positions, `is_v2` cleared too early). Merged into main the same day (e2ef0b4).
- **Three more protocols as firmware, each checked against an independent reactive peer:** WS2812 (25 words, 15 cases/5 mutants), PS/2 device (89 words, 28 cases/8 mutants), SWD host (161 words against a reactive ADIv5 target, 11 cases/4 mutants). **13 verified protocols** (the week-5 goal reached in week 1).
- **Shared 512-word memory experiment** (branch `feat/shared-imem`): one 2-port 512x32 macro for both engines, each engine gets a "window" it sets once per run with the new instruction `OP_REGION` (lock after first use), a START address register, host writes through a held engine's port. Chip-level test passed on the RTL. Layout run sh2 (L-shaped engines) was congested; **sh3 (compact columns) routed (32 % demand) but LVS failed: VPWR and VGND were shorted** because our power stripes (pitch 44.96 um) did not match the 2-port macro's power columns (17.68 um pitch). Fix found by scanning pitches/offsets: **stripe pitch 53.04, VPWR-VGND spacing 6.74, offset 18.545** (matched grid), checked by a quick run with 0 wrong-net overlaps.
- **Move to native Ubuntu** (decided because WSL had only 7.8 GB RAM and shut down when idle, killing flows): everything committed, handoff written ([docs/HANDOFF_LINUX.md](docs/HANDOFF_LINUX.md)); GitHub gds run 39250627497 kept building remotely.

---------------------------------------------------------------------------------------------------

# PART C. 2026-10-20, hour by hour in order (the busiest day; native Ubuntu)

## C1. Getting the Ubuntu machine ready (morning)
- **Asked by the user:** read `docs/HANDOFF_LINUX.md` and `memory.md` and say what to continue with; "check the environments and path clear that first"; keep the same working directory (the repository stays on the NTFS data drive `/media/rishadd/OS/Data/protocol_emulator`).
- **Environment problems found and fixed:** (1) `.git/config` contained `fileMode = core.autocrlf`, which made every git command fail -> set `fileMode=false`, `autocrlf=input` (the 128 "modified" files were only line-ending/permission differences). (2) The user believed LibreLane was already installed in a Nix environment (`~/librelane`, `nix develop`); it was an old 2.4.13 checkout whose unit test failed. **The user then decided: "remove all librelane and nix environments from this system and do a clean install the same as the windows system"** and asked for the removal commands. (3) The Determinate Nix installer refused because the apt package `nix-bin` was installed (user removed it); the per-user profile folder needed `sudo mkdir /nix/var/nix/profiles/per-user/rishadd`. (4) Final stack (also in [reproduce/versions.txt](reproduce/versions.txt)): Nix, Icarus Verilog 13.0, Python 3.12, SymbiYosys 0.69 + Yices + Boolector, KLayout, LibreLane 3.1.0.dev3 (the GitHub action's release), IHP PDK revision 2bbec755, tt-support-tools, two Python virtual environments.
- **GitHub check the user asked for ("This run has passed, check it properly"):** run 39250627497 (main 8795248): gds 3h45, precheck 1h58, gl_test and viewer all passed: the official flow accepted the tt14b-based design.

## C2. Regression ported to Linux; all 47 suites pass
- **Why:** the whole test suite had been run on Windows. A clean pass on the new machine proves the environment and finds hidden platform assumptions.
- **Errors found and fixes:** a Windows-only `powershell` call -> new `run_tests.sh`; Icarus 13 rejects "use before declaration" in `tb_mgmt_pins` -> declaration moved; parallel remap suites shared one build folder (flaky CAN/Modbus, hung JTAG) -> folder names include remap seed and `FW_ORG`; a stalled line-coder transmitter hung a test -> watchdog added (mutant loop counts it as caught); a pad wired back to the debug-view select closed a zero-delay loop in Icarus 13 (remapped JTAG hung at 10 ns) -> pads built through temporaries with `assign #1`; `i2c_slave_test` lost a race when several suites compiled the same `.vvp` -> compile aside + atomic rename, separate case folders; the "line_coder_mutants" suite was flagged FAIL because caught mutants print FAIL lines -> its verdict is the "X/X caught" line.
- **Also found (line coder test gap):** `tx_stuff_before_eop` never sent a packet ending in six ones (bytes go LSB first, last byte 0xFC does) and two mutants survived -> test fixed, transmitted symbol runs now compared with the USB model; 16/16 mutants caught + one documented equivalent ("SE0 one clock too long", below measurement resolution); checks 1175 -> 1221.
- **Result:** runs d (45/47) and e: **47 of 47 suites pass** (`results/regression_2026-10-20d`, `...e`).

## C3. Shared-memory layout sh4 (the matched power grid works)
- **Run:** `librelane/flow_variant_linux.sh sh4 shared3 <tree>`; sh4 was restarted from scratch (the old log had ended in the power-grid step, not in routing as the handoff said). Live pictures of every stage written to `results/shared_2026-10-20/` (the user asked for the log terminal and the pictures; one terminal was blank at first and one picture page did not show, both fixed).
- **Result: LVS clean (the matched grid fixed the VPWR/VGND short), 0 DRC, 0 antenna, hold +0.10 ns, Tiny Tapeout precheck passes. Open: slow-corner setup -1.45 ns at 20 ns -> 21.45 ns = 46.6 MHz; area 368k + 151k (macros).** The precheck needs the `klayout` program and Nix libraries on the library path (documented in the script).
- **Repository privacy:** the user asked whether the repository can be made private; answer yes (done by the user), pushes only on request; the LICENSE (Apache-2.0) was pushed on request.

## C4. The decision: shared memory or separate memories
- **User asked for data to decide**; the comparison (area, flexibility for USB descriptors and future protocols, timing cost) was given. **The user then decided: the shared 512-word memory is the base** (reason: the chip must be compatible with all future protocols, including a standalone USB device; the logic analyser will be integrated on top) and **asked what causes the slow-corner problem with the shared memory** (answer: a weak gate right next to the macro drove a long wire to the engines, about 1 ns of slew).
- **Orders given by the user:** start flow-only variants, then make any RTL, script or placement change needed to get close to 50 MHz, *while keeping the layout meaningful*; explain how a slightly slower clock changes instruction timing; clean up the directory; merge and rebase frame v2; write the plans for logic analyser, standalone USB device and Ethernet; search the web for what other participants did; before building the logic analyser, do the shared-memory software ("Step 4") and explain what it is.

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

## C6. Repository work done in parallel
- **Directory clean-up (user: "B4, clean up the directory and proceed with the checklist"):** a backup bundle of every branch (`~/protocol_emulator_all_refs_2026-10-20.bundle`) was made, then stale worktree copies deleted (about 3 GB; the user approved the deletion explicitly after the safety check blocked it once); unique files rescued to `results/archive_old_worktrees/`; the 1.6 GB fetch-stage copy was left untouched.
- **Frame v2 merge into main (fcbd07b, pushed on request).** The merge exposed a **real bug**: the first TX byte of a v1 frame came from a status register one clock older than the one the accept decision used -> a duplicated TX byte (UART duplex stress 1025 bytes for 1024, 6 of 7 cases; workload 54/55). Fix in `mgmt.v` (send the live STATUS while idle). After the fix: duplex stress ALL PASS, v2 236/236, 22/22 unit tests, regression 47/47.
- **TODO list** created on request ([docs/TODO.md](docs/TODO.md)) and kept ticked.
- **Plans written (documents):** [DEBUG_LA_PLAN](docs/DEBUG_LA_PLAN.md) (logic analyser: 16 channels, triggers, third SRAM macro, phases 0-8, TSTAMP as a new opcode because all eight RGET sources were already used), [USB_STANDALONE_PLAN](docs/USB_STANDALONE_PLAN.md) (descriptors on chip, ~320-380 words, fits only the shared memory), [ETHERNET_FEASIBILITY](docs/ETHERNET_FEASIBILITY.md) (10BASE-T transmit feasible at 40 MHz, receive is research), [PROTOCOL_CATALOGUE](docs/PROTOCOL_CATALOGUE.md) (13 verified + ~20 firmware-only candidates), [SHARED_IMEM_SOFTWARE_PLAN](docs/SHARED_IMEM_SOFTWARE_PLAN.md), [CLOCK_SPEED_EFFECTS](docs/CLOCK_SPEED_EFFECTS.md). Competitor scan repeated: Loom (8x4, 13 firmwares, 911 mutants, ~43 MHz) and Abagel-coder (6x4, 3 protocols, 50 MHz) are the real comparisons; our gaps: mutation volume, a static timing checker, a self-contained USB device, FPGA demos.

## C7. Shared-memory software "Step 4" (done, branch `shared/on-v2`, local)
Plain-language: Step 4 is everything *around* the new shared memory so that it can be trusted: tests, proofs and host tools. It lives on the branch `shared/on-v2` in `~/pe_shared_v2` (frame v2 merged in by hand).
- **S1 RTL:** read-back of an engine's window (`REGION` at ENG_BASE+0x008) and of instruction words (frame v2, through any held engine's port).
- **S2 differential test in shared mode:** random images at random places in the 512 words, both engines, RTL vs model every clock: 400 tests x 600 clocks x 2 engines, 0 mismatches, 76/76 coverage.
- **S3 formal:** `imem_shared.sby` (a fetch never leaves the window; host writes never land in a running window or through a running port; the lock holds) and `region_go.sby` (the control unit accepts `OP_REGION` only when unlocked and valid); 6 proofs in total; 13 planted bugs caught. A first attempt failed because Yosys treats hierarchical references as free signals -> the macro write signals were exposed as outputs.
- **S4 host layer:** verified image load, REGION check at start, `plan_images` overlap check. **S5:** 16/16 planted RTL bugs caught by the differential test. **S6:** the chip-level protocol suites run from the shared memory (engine 1 at word 256): CAN, JTAG, 1-Wire, Modbus (plain + remap seed 2), SPI chip 52/52, I2C chip 10/10 ("phase E" of the regression). Test-writing traps: unwritten memory words read as X (write first), a test bench input left unconnected.
- **Not yet run from the shared memory:** UART, USB, SMBus, long workloads, WS2812/PS/2/SWD (model level only).

## C8. The user guide (for chip users)
- **Asked by the user (while sh8 was running):** "create a highly detailed user guide with chapters, subheadings and a contents page ... include every functionality ... assume a Raspberry Pi Pico is the host". I first listed the chapters for approval. **User's changes:** logic-analyser chapter must use **GTKWave** not PulseView; chapter 16 is "Troubleshooting and debug" (no FAQ); tools that do not exist yet get **placeholders + a memory entry saying the text must be edited later**; nothing silicon/fabrication specific; every title and subheading present with brief placeholder text; a markdown file in the repo plus a scrollable neat HTML with a clickable contents page.
- **Built:** [docs/USER_GUIDE.md](docs/USER_GUIDE.md) (17 chapters in 3 parts, 9 appendices, 189 headings) and generated HTML (`python3 docs/build_user_guide.py`, dependency free, sidebar contents with filter). Placeholders to fill later are listed in the guide's "Document status" table: Pico library `pe_chip`, logic analyser registers + `la_capture.py` + GTKWave screenshots, engine debug, sniffer, TSTAMP, standalone USB, Ethernet, final pin map/ratings/power, remaining catalogue protocols, worked recipe, first-program listing, quick-reference card. Links "to check" in Appendix G were not all reachable (flaky network).
- **Figures (user: "generate and add all images wherever possible ... the Pico pinout etc are online"):** 47 figures: 45 diagrams drawn by Python scripts (`docs/images/make_images.py`; system view, block diagram, Pico wiring, protocol wiring for 11 protocols, frame formats, timing diagrams, logic analyser figures ...), a real capture example produced by the logic-analyser model (`example_capture.vcd`), and the Raspberry Pi Pico pinout downloaded from CIRCUITSTATE (CC BY-SA 4.0, attribution in `docs/images/third_party/ATTRIBUTION.md` and Appendix I). Several figures were redrawn after visual review (double arrows, overlapping labels, USB NRZI start level ...). Pushed with the README link on the user's request (commits e2d6499, a0e988a, 744a214 on `main`).

## C9. Logic analyser Phases 1-3 (branch `shared/on-v2`)
- **Plan decisions (D1-D6 in DEBUG_LA_PLAN):** the analyser never touches the instruction-fetch path; third macro (1P 256x32) as capture buffer; timestamp access is a new opcode 30 `TSTAMP`; channels = 13 pins after the 2-flop synchroniser + RUN of each engine + marker channel 15 (OR of the engines' trigger lines); change-mode words `{value[15:0], delta[15:0]}` with an overflow word every 65,535 quiet clocks; engine debug later uses frame v2 so a retried step never executes twice.
- **Phase 1 model (`host/la_model.py`)**, self-test with 300 random captures, VCD writer and decoder. **Phase 2 RTL (`src/la_unit.v`)** compared with the model clock by clock (`la_rtl_test.py`; 200 tests x 3000 clocks, depth 16, plus long captures for the overflow word); 12 planted bugs in the unit all caught. Issue found: the model cleared the buffer on re-arm but the RTL did not (model changed to match, harmless because only the write pointer defines valid words); a mutant for the overflow word needed deliberately long captures.
- **Phase 3a (user asked: "start Phase 3 now"):** `TSTAMP rd` (opcode 30, reads a 32-bit free-running counter) and `RPUT TRIG` (destination 4 of RPUT: the engine's trigger line, shown on channel 15, drops when the engine is held). Updated: RTL (`engine_top`, `control_unit`), assembler, Python model (cycle counter, trigger), the two differential tests (a new trace column; the test bench drives `ts` = clock number), 6 new planted bugs. **Results: differential test 0 mismatches, 99/99 coverage, 38/38 mutants caught; shared-memory differential test 0 mismatches.** The old "REGION is covered" requirement of the non-shared test was unreachable and had been failing already; excluded. Two old unit tests expected "destination 4 and opcode 30 trap" and had to be updated.
- **Phase 3b:** `src/la_block.v` (only when `-DLA`): timestamp counter, pin synchroniser, capture unit, third macro buffer, register window `0x0300` (CTRL, CONFIG, PATTERN, DIV, POST, TRIGCNT, PTR, DATA, TS); management controller gets the window and a buffer read-out (v2 frames only; BUSY while a capture runs; v1 DATA read refused); IRQ bit 8 "capture done" (pin manager IRQ status widened to 9 bits); debug view 6; `host/la_host.py` (first part of the host tool).
- **Chip-level test `host/la_chip_test.py` (through the real SPI link): PASS** - register read-back and refusals, a capture of known pin activity with exact clock spacing (30 and 20 clocks), VCD round trip, sample mode, TSTAMP difference 11 equal to the model, the 32-clock trigger pulse on channel 15, trigger line low when the engine is held, done interrupt on `uo_out[1]`, debug view. Formal proofs of the changed blocks (pin manager, management, engine, region_go) re-run: all PASS.

## C10. "How do I reproduce all results?" -> the `reproduce/` folder
- **Asked by the user:** give every script needed to reproduce all results including the layout flows, in this directory, nothing hidden. **Built:** `reproduce/README.md` (single document, the user asked for one, not two), install/tests/formal/flow/precheck/docs scripts (01-07), an **archive of the nine shared-memory flow runs sh4-sh9b** with their exact RTL, complete configuration and metrics (`flows/`), a comparison tool (`tools/compare_flow.py`), tool versions, and a git bundle of branches not in main. The flow scripts no longer contain hard-coded home paths.
- **User: "don't wait for the whole rerun if the signature is the same so far":** sh8 was rerun from the folder alone and stopped at step 30 of 72 after **29 of 29 completed steps had identical cumulative metrics**: the flow is deterministic. Honest limits written into the README: flows before 2026-10-18 23:10 (tt2-tt12a, incl. tt9b/tt9c) used a dev LibreLane and an older PDK that are not stored (configs archived, rerun gives a close but different layout); tt14b is rebuilt from commit e3846c3; GitHub jobs and FPGA runs are not scriptable; CRLF input files of sh4-sh5c.

## C11. "Is my design fit for submission? Check it with all prechecks and metrics and start the GitHub workflow"
- **Answer given first:** a three-layer checklist (simulation/formal; layout metrics + precheck + gate-level test; challenge rules in [docs/CHALLENGE_CHECK.md](docs/CHALLENGE_CHECK.md)). Today the design is *not* yet submission-ready: the final RTL (with the analyser, engine debug, sniffers) has not been through a layout and precheck, and the slew/cap violations and the public-repo build are unchecked.
- **Done on request:** branch **`check/shared-sh8`** created from `shared/on-v2` with `src/config.json` = the sh8 recipe (so GitHub and the local flow use the same configuration) and **pushed** (this starts the docs, gds and test workflows; gds takes 4-6 hours; I cannot see the result: no `gh` and no token here and the repository is private, so the user reads https://github.com/Rishadd/protocol_emulator/actions). The current build deliberately **excludes the logic analyser** (no macro placement for its macro yet), so this checks the shared-memory chip with TSTAMP/trigger. The local twin run **sh10** (same recipe and RTL) was started and the Tiny Tapeout precheck on it follows; **result pending**. Caveat told to the user: the `test` job runs cocotb tests written for the old design and may fail for reasons unrelated to the layout.

## C12. The regression of the shared-memory branch: what went wrong and how it was repaired (read this to understand the harness)
1. The first full run of the 57-suite regression (phases A-F; phase F is new: frame v2, shared-memory software, logic analyser) ended at 45/57.
2. **My own mistake:** a monitor that looked for the regression process with `pgrep "host/regress.py"` missed a run started as `cd host && python3 regress.py`; I concluded the run had died and **started a second regression while the first was still running**. Both share build folders, and the second run's start deleted compiled files (`.vvp`) that the first needed. The user noticed ("why did you start a new one again"); the duplicate was killed at once; the damage was a few suites failing with "Unable to open input file", which were rerun. Rule added: never start a second regression while one runs; watch with monitors on the exact process id.
3. Real problems found and fixed: (a) phase E (10 chip-level suites) failed at once because `la_block.v` instantiates the 1P macro and the shared-memory simulations did not include its model; my first fix (add the model to the shared libraries) was wrong (it became a stray top-level module whose unconnected pins stop every bench at time 0: "A_DLY must be tied to 1'b1"); the right fix: `la_block.v` exists only with `-DLA`; (b) ten suites compiled the same chip bench `.vvp` simultaneously (race, "syntax error") -> private temporary file + atomic rename; (c) the build's staleness check ignores the list of macro models, so stale compiled files had to be deleted by hand once; (d) phase F mutant suites print a FAIL line for every caught bug -> judged by their "caught X/X" line; (e) `isa_diff_shared_mutants` caught only 15/16 because the new TSTAMP changed the random generator and the rare "empty window" case no longer occurred in 150 tests -> 300 tests, 16/16.
4. **Results after the repairs:** phase E 10/10 pass (CAN 26/26, JTAG 17/17, 1-Wire 10/10, Modbus 16/16, SPI chip 52/52, I2C chip 10/10, plus the remap-seed variants); phase F: mgmt_v2_test 236/236, mgmt_v2_mutants 20/20, shmem_test, shmem_chip_test, isa_diff_shared (0 mismatches), isa_diff_shared_mutants 16/16, la_model, la_rtl_test, la_rtl_mutants 12/12, la_chip_test all PASS; org192_spi_test and the unit testbenches pass on rerun. **Not yet done: one single clean A-F pass on the final code.** Evidence folders: `~/pe_shared_v2/results/regression_repro_shared_*`.

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
