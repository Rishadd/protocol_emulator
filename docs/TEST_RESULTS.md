# Test results, all in one place (state of 2026-10-18)

Everything below was measured in simulation or in the LibreLane / Tiny Tapeout flow in WSL. **Nothing was measured on silicon**, and only
UART has also run on an FPGA (DE0-Nano). Raw logs: [results/regression_2026-10-18/](../results/regression_2026-10-18/) (one log per suite).
Re-run everything with `python host/regress.py` (about 70 minutes on 16 cores) or one suite at a time (see the README).

**How to read the tables.** *Case* = one scenario that must pass. *Mutant* = a deliberately broken copy of the RTL or the firmware that the test
must catch (a mutant that is not caught is a hole in the test). A suite passes only when every case passes **and** every mutant is caught.

## 1. At a glance

| Area | Suites | Result |
|---|---|---|
| RTL unit and engine testbenches | 22 testbenches in 1 suite | all PASS |
| New ALU / CRC units (mutation tests of both units, random differential test) | 3 | all PASS, 66 of 66 planted bugs caught |
| Protocol firmware on the engine testbench (SPI, I2C master + slave, SMBus, Modbus, 1-Wire, JTAG, CAN) | 8 | all PASS, 0 missed mutants |
| CAN, JTAG, 1-Wire, Modbus on the full chip, host only through the management SPI link | 4 (+ 3 cocotb tests) | all PASS |
| Firmware relocated to other instruction-memory addresses | 6 | all PASS |
| Long workloads (UART, duplex through the link, all protocols together) | 4 | all PASS |
| **Regression total** | **26 suites** | **26 of 26 PASS** |
| Physical flow (Tiny Tapeout CMOS5L, 6x4 tiles) | see section 8 | routing clean; the signoff clock is 30 ns (33 MHz), see 8.2 |

## 2. RTL unit and engine testbenches (`run_tests.ps1`)

| Testbench | What it checks | Result |
|---|---|---|
| tb_instr_mem | the 256 x 32 SRAM macro wrapper: full read-back, one-clock read latency, no aliasing of address bits 6 and 7 | PASS |
| tb_pc_reg | program counter: jump beats advance, `next_pc` prediction, reset | PASS |
| tb_delay_counter, tb_loop_counter | `WAIT` / `WAITR` counter and `SETL` / `DJNZ` counter | PASS |
| tb_fifo, tb_shift_reg | TX / RX FIFOs, OSR / ISR shifters (both bit orders) | PASS |
| **tb_alu_unit** (new) | every ALU function and flag, register read / write rules, random operations against an independent expression | PASS |
| **tb_crc_unit** (new) | published check values of 14 CRC models, bit feed = byte feed, polynomial-division reference on random configurations, configuration rules (init / polynomial masked, format write cuts the register) | PASS |
| **tb_engine_alu** (new) | hand-written engine programs: sum loop, compare / branch, every `RGET` / `RPUT` path, `WAITR` cycle count, CRC-32 of "123456789", FIFO stalls | PASS |
| tb_pin_block, tb_pin_mgr, tb_mgmt_pins | pin direction / level, pad ownership, open-drain pads, ownership violations | PASS |
| tb_control_unit | decode of all 32 opcodes incl. the new 21-27, stalls without side effects, traps at 28-31 | PASS |
| tb_engine_top, tb_engine_ops | engine timing rules (cycle exact UART, reset in the middle of a frame), every old opcode | PASS |
| tb_fetch_equiv | lockstep of the engine against the older fetch implementation, now including the new opcodes | PASS |
| tb_rx_led_sink | FPGA helper | PASS |
| tb_mgmt_frame, tb_mgmt_load, tb_mgmt_dual, tb_mgmt_read, tb_mgmt_tx | management SPI link: frame format, program load, two engines, RX read, TX write | PASS |

## 3. The new ALU and CRC units

| Test | Setup | Result |
|---|---|---|
| ALU mutation (`host/alu_test.py`) | 28 planted ALU bugs (carry polarity, flag sources, write-back of `CMP` / `TST`, shift carries, sign extension, wrong register, adder carry-in, missing prefix-adder level, ...) | **28 of 28 caught** |
| CRC unit + vectors (`host/crc_test.py`) | 3,280 random Python vectors (random width / polynomial / init / reflection / message) plus every catalogue model | PASS |
| CRC mutation | 14 planted bugs (reflection, width mask, polynomial / init alignment, top bit one low, byte step feeds 7 bits, format write does not realign, ...) | **14 of 14 caught** |
| **Differential test** (`host/isa_diff_test.py`) | 600 random programs x 400 clocks with random pin and FIFO stimulus; RTL against the independent cycle-exact Python model; compared every clock: pc, pins, FIFO pushes / pops, shifters, loop counter, CRC value, flags, R0..R7 | **0 mismatches**, 67,411 instructions, **74 of 74** coverage points |
| Engine mutation (same tool) | 24 planted engine bugs (stalls, `JCC` conditions, `WAITR`, `RGET` / `RPUT` decode, reserved encodings legal, ...) | **24 of 24 caught** |

## 4. Protocol firmware (engine testbench, peer models written from the specifications)

| Protocol | Firmware | Cases | Mutants caught | What is checked |
|---|---|---|---|---|
| UART TX / RX | 12 / 9 words | workload sweeps | - | cycle-exact frames at 9600 and 115200 baud, RX tolerance +6.0 % / -4.5 % baud error |
| SPI master + slave, 4 modes | 17 / 18 words | 312 incl. mutants | 64 | all modes, both bit orders, 1..32 bits, minimum timings, engine and full chip |
| I2C master | 46 words | 60 incl. mutants | 16 | 100 / 400 / 1000 kHz against UM10204 timing, stretching, NACK, repeated start |
| **I2C slave** (new) | 108 words | 45 incl. mutants | 16 | write 1..16 bytes, read with slow host, repeated start, every single-bit wrong address, flow control by clock stretching |
| **SMBus PEC** (new) | 88 words | 23 incl. mutants | 7 | PEC sent / checked / flipped bit detected, bus timing equals the plain master |
| **Modbus RTU** (new) | 42 words (TX) | 26 incl. mutants | 10 | textbook frame `01 03 00 00 00 0A C5 CD`, 3.5-character silences, +-2 % baud error, bad CRC, short frames, TX engine to RX engine |
| **1-Wire** (new) | 79 words | 18 incl. mutants | 8 | slot timing measured against the Maxim windows, ROM and scratchpad CRC-8 on chip, corrupted CRC, no device |
| **JTAG** (new) | 87 words | 21 incl. mutants | 4 | Verilog TAP from IEEE 1149.1, scans of 1..100 bits, pause states, TCK half periods 3 and 40, random walks vs a Python TAP |
| **CAN 2.0A** (new) | 112 TX / 186 RX words | 47 incl. mutants | 20 | 1 Mbit/s, 500 kbit/s, 200 kbit/s; bit stuffing at every field boundary and behind the CRC, ACK slot, bad CRC, stuff / form errors, remote and extended frames, +-0.15 % clock error with ACK, +-0.3 % data only; engine 0 to engine 1 |
| **USB low speed** (new) | 203 words + line coder | 45 checks (model and RTL, host rate 0 / +-1.5 %) + 18 planted firmware bugs | 4 | line coder in hardware ([LINE_CODER.md](LINE_CODER.md)); firmware is a packet shuttle, descriptors and requests in host software ([USB_LS_PLAN.md](USB_LS_PLAN.md)); PC-style enumeration of a HID keyboard against an independent host peer model, key reports with DATA toggling, retransmission, NAK, ignored tokens, STALL, bus reset, 2 to 7.5 bit-time turnaround |
| **WS2812** (new) | 25 words | 15 incl. 5 mutants | 3 | every pulse inside the datasheet windows (T0H 0.40, T1H 0.80, T0L 0.85, T1L 0.45 +-0.15 us), 800 kHz, GRB order MSB first, 50 us latch, strips of 1 to 60 LEDs |
| **PS/2 device** (new) | 89 words | 28 incl. 8 mutants | 3 | link layer; reactive host model: 11-bit frames with odd parity, clock 30..50 us low and high, data setup / hold, inhibit and resend, host-to-device bytes with acknowledge and parity / framing flags, a software keyboard (reset, ID, LEDs, scan codes); device-to-host also on the RTL |
| **SWD host** (new) | 161 words | 11 incl. 4 mutants | 3 | line reset, JTAG-to-SWD switch, request / turnaround / ACK / data / parity against a reactive ADIv5 target (DP, MEM-AP, memory): IDCODE, power-up handshake, word and 16-word block transfers with posted reads, WAIT retry, FAULT + ABORT, read parity error |

## 5. Full chip, host only through the management SPI link

| Suite | Cases | Result |
|---|---|---|
| CAN (transmit and receive) | 26 | PASS |
| JTAG | 17 | PASS |
| 1-Wire | 10 | PASS |
| Modbus (TX, RX, TX to RX) | 16 | PASS |
| cocotb on RTL: status, pad owner, **ALU + CRC program through the port** (CRC-32 of "123456789" = 0xCBF43926, sum, xor) | 3 | PASS |
| SPI and I2C full-chip phases, SPI + I2C at the same time | inside the suites of section 4 / 7 | PASS |

## 6. Firmware at other instruction-memory addresses (`FW_ORG`)

Every firmware image can be relocated so that jump targets and the 8-bit PC are exercised high in the memory.

| Suite | Origin | Cases | Result |
|---|---|---|---|
| SPI, I2C master, Modbus | word 192 | 312 / 60 / 16 | PASS |
| CAN, JTAG, 1-Wire (too large for word 192) | word 64 | 27 / 17 / 10 | PASS |

## 7. Long workloads

| Suite | Result |
|---|---|
| UART workload at 9600 and 115200 baud (1,024 distinct bytes, every frame cycle exact against a Python reference) | PASS |
| UART RX tolerance sweep | PASS (+6.0 % / -4.5 %) |
| 1 KB full duplex through the management link, host aborts and noise, plus a deliberate host stall that must be detected | PASS |
| All protocols together, only through the link (UART, SPI modes 0-3, I2C 100 / 400 / 1000 kHz, SPI + I2C at once, host noise and aborts, limit searches) | PASS, 55 of 55 |

## 8. Physical design

### 8.1 Cell count and area after synthesis (Yosys, 20 ns clock, 14.5k - 21.5k cells)

| Version | Strategy | Cells | Cell area |
|---|---|---|---|
| Before the ALU / CRC units (run tt5, after place and route) | `DELAY 4` | 7,829 | 136,824 um^2 |
| With ALU + CRC (first versions) | `DELAY 4` (flow default) | 21,462 | 308,970 um^2 |
| With ALU + CRC (first versions) | `AREA 0` | 15,657 | 229,476 um^2 |
| **Final RTL** (left-aligned CRC, prefix adder) | `AREA 0` | **14,499** | **223,815 um^2** |
| Final RTL | `DELAY 2` / `DELAY 4` | 16,715 / 18,410 | 251,611 / 280,538 um^2 |

Cell area per engine, final RTL: ALU 34,279, CRC 24,882, FIFOs 22,265, control group 12,952, shifters + pin block 8,718 (together 103,096 um^2); management
17,344 um^2. Two SRAM macros add 98,977 um^2. The die is 916,214 um^2.

### 8.2 Timing and routing, flat placement (one flow run per row; all with the TT configuration)

| Step | Change | Routing DRC / LVS | Setup slack, slow corner | Setup slack, typical | Hold, fast corner |
|---|---|---|---|---|---|
| tt5 (old design, 20 ns) | before the ALU / CRC work | 0 / 0 | +8.04 ns | - | +0.11 ns |
| `DELAY 4` synthesis | first ALU + CRC | unroutable: global-routing usage 79 %, overflow 23,889 | - | - | - |
| `AREA 0`, ripple adder (tt6) | | 0 / 0 | **-5.88 ns** (ripple-carry chain of the adder) | - | -0.23 ns |
| prefix adder, Metal4 obstructions over the macros (tt6c) | 20 ns | 0 / 0 | **-6.75 ns** (546 endpoints) | +1.79 ns | -0.21 ns |
| (a post-route repair attempt, tt6b) | | 16 DRC, 4 LVS errors | -8.35 ns | - | -0.13 ns |
| hold margin 0.5 ns | 30 ns | overflow 1,645 (5,900 hold buffers) | - | - | - |

**Conclusion.** With the ALU and CRC units the worst-case corner (1.08 V, 125 C) limits the clock to about 27 ns; the typical corner still meets 20 ns (50 MHz).
The signoff clock of the final runs is therefore **30 ns (33 MHz)**. To reach 50 MHz at the slow corner the CRC byte step and the register-file read path would need
a pipeline stage (an ISA timing change for `CRC BYTE`), which was not done.

### 8.3 Placement experiments: flat against bounding boxes

Global-routing congestion after the same flow steps (lower overflow = easier to route):

| Layout | Usage | Overflow | Wirelength | Remark |
|---|---|---|---|---|
| Flat (placer decides), 20 ns | 34.0 % | 225 | 1.54 M um | |
| Flat, 30 ns, post-route repair | 35.1 % | 612 | 1.61 M um | |
| Module boxes v1 (11 boxes) | 42.3 % | 1,291 | 1.82 M um | boxes too tight, FIFO box 4:1 |
| Module boxes v2 (ALU, CRC, management; 60 % utilisation) | 38.8 % | 1,076 | 1.73 M um | |
| Module boxes v3 (same, 40 % utilisation) | 41.8 % | 153 | 1.80 M um | less congested than flat, 17 % longer wires |
| Engine boxes (two boxes: engine 0, engine 1) | see 8.4 | | | requested layout |

Half-perimeter wirelength after detailed placement, flat against module boxes v1: nets inside modules 567,676 against 697,874 um; nets between modules 233,974
against 345,538 um (the FIFO box alone doubled its internal wiring).

### 8.4 Final runs (30 ns clock)

Root-cause analysis of the earlier runs (they never finished clean at 30 ns) found six causes; each column adds one group of fixes, so the
gain of every change can be read off. All runs: 30 ns signoff clock, flat synthesis `AREA 0`, same TT configuration otherwise.

| Run | What changed |
|---|---|
| tt6c / tt6h (before) | macros at (60,120) / (60,470), under the chip pins; hold uncertainty 0.25 ns; tt6c at 20 ns, tt6h at 30 ns with hold margin 0.25 (stopped in routing) |
| **tt8b** | configuration and floorplan fixes: SRAM timing model per corner (the slow corner had used the typical model), own SDC with 0.1 ns hold uncertainty, no repair after global routing, timing-driven placement, both SRAMs on the bottom edge with pins facing up |
| **tt9a** | + RTL: CRC unit pipelined (command register, pre-aligned polynomial; `RGET CRC` directly after a CRC instruction waits 1 clock) |
| **tt9b** | + floorplan correction for the precheck: SRAM 1 on a whole stripe pitch, horizontal macro halo 17 um (tt8b had 42 rows 1.9 um wide and a Metal4 spacing error) |
| **tt9c** | symmetric floorplan: SRAM 0 bottom left, SRAM 1 bottom right, each engine fenced into its own column, management / SPI / pin manager in the middle |

| Parameter | before (tt6c / tt6h) | tt8b | tt9a | tt9b | tt9c |
|---|---|---|---|---|---|
| Global routing usage / overflow | 34.0 % / 225 (tt6c), 35.9 % / 563 (tt6h) | 26.6 % / **0** | 28.1 % / 0 | 27.1 % / 0 | 31.9 % / 0 |
| Global-route wire length | 1.54 M um (tt6c) | 1.19 M um | 1.26 M um | 1.22 M um | 1.40 M um |
| Detailed-route wire length | - | 890 k um | 944 k um | 906 k um | 1,069 k um |
| Hold buffers | 4,260 (tt6h, +20 % cell area) | **1,141** | 1,151 | 1,132 | 1,121 |
| Standard cells / area | - | 17,627 / 261 k um^2 | 18,411 / 273 k um^2 | 18,333 / 271 k um^2 | 18,824 / 275 k um^2 |
| Routing DRC | tt6c 0; tt6h 29-31 shorts over the SRAMs, never cleared | 0 | 0 | 0 | 0 |
| LVS errors | 0 (tt6c) | 0 | 0 | 0 | 0 |
| Slow corner (1.08 V, 125 C): minimum period | 26.8 ns with the typical SRAM model (about 29 ns with the real one) | 23.5 ns | 20.9 ns | **20.5 ns** | 23.0 ns |
| Slow corner: max. clock | about 34 MHz | 42.6 MHz | 47.8 MHz | **48.8 MHz** | 43.4 MHz |
| Typical corner: minimum period / max. clock | 18.2 ns / 55 MHz | 14.6 ns / 68 MHz | 13.0 ns / 77 MHz | **12.8 ns / 78 MHz** | 14.3 ns / 70 MHz |
| Hold, worst slack (fast corner) | -0.21 ns (violations) | +0.099 ns | +0.099 ns | +0.100 ns | +0.089 ns |
| Setup / hold violations at 30 ns | setup at 20 ns: 546 endpoints (tt6c) | 0 / 0 | 0 / 0 | 0 / 0 | 0 / 0 |
| Power (liberty estimate) | - | 4.54 mW | 4.92 mW | 4.80 mW | 4.95 mW |
| Tiny Tapeout precheck | not reached | fail (power pins, Metal4 spacing) | (tt8b floorplan) | **pass** | **pass** |
| Gate-level cocotb test | - | - | - | **3/3 pass** | **3/3 pass** |
| Layout | one blob, macros under the pins | one region | one region | one region | **engine 0 / shared / engine 1, mirror images** |

Minimum period = clock period - worst setup slack (signoff STA of the run, all three corners with the matching SRAM model).

**Gains by change.** Configuration and floorplan (before -> tt8b): congestion gone (overflow 225-563 -> 0), hold buffers -73 %, wire length -23 %,
slow corner about 29 -> 23.5 ns. Pipelined CRC (tt8b -> tt9a): slow corner 23.5 -> 20.9 ns (-11 %), typical 14.6 -> 13.0 ns, for +4.4 % cells,
+5.5 % wire, +8 % power. Floorplan correction (tt9a -> tt9b): precheck passes, wire length -4 %. Symmetric fenced floorplan (tt9b -> tt9c):
the readable layout costs +18 % wire, +2.5 ns at the slow corner and +3 % power; it still meets the 30 ns clock with 7 ns to spare.

**What now limits the clock** (tt9a / tt9b / tt9c): SRAM read (5.4-5.5 ns at the slow corner) -> decode -> ALU operand select -> 32-bit adder ->
register write. Several cells on this path are minimum size driving 50-130 fF (0.8-1.5 ns each): at a 30 ns constraint the path has 7-9 ns of
slack, so the resizer has no reason to upsize them. Constraining the flow at 20 ns is the next experiment for 50 MHz at the slow corner.

Images of every stage, the module maps (where each engine and module sits) and the metrics of each run: `results/tt_flow_2026-10-18/index.html`.

## 9. Bugs the tests found

| Bug | Found by | Fix |
|---|---|---|
| `WAITR` hung when the register's upper bits were set but its low 27 bits were 0 | differential test | stall test looks at the same 27 bits |
| New CRC unit lost bits on a format write in the middle of a stream (the old unit kept them) | differential test (unit-level comparison of old and new RTL) | defined: a format write cuts the register to the new width; model, documentation and a unit test updated |
| RTL cocotb test hung: `test/Makefile` lacked `-DFUNCTIONAL` (the SRAM model needs it) | cocotb ALU + CRC test | define added |
| Slow-corner timing: 32-stage ripple-carry adder, 32:1 muxes inside the CRC chain | static timing of the first flow runs | prefix adder, left-aligned CRC |
| Signals shorted to the Metal4 power stripes bridged over the SRAMs | detailed routing never converged | routing obstructions on Metal4 over the macros |
| Test-tool weaknesses: mutants that "failed" only because they did not compile, mutants equivalent to the correct code (JTAG sampling point), generator that rarely reached reserved encodings | mutation runs | tools and mutants corrected until each mutant is caught for the right reason |

## 10. What was not tested

- Silicon, FPGA (except UART), gate-level simulation of the final netlist beyond the cocotb tests in section 5 (see 8.4), formal properties.
- Magic DRC was skipped in the new flow runs (it reports about 116k errors that come from the SRAM macros' own layout); the foundry DRC of the Tiny Tapeout precheck is the check.
- CAN arbitration and error frames, USB, Ethernet.
- Power: only the liberty-based estimate of the flow, no measurement.

## 11. Update 2026-10-19: the 8x4 layout, formal, GitHub, shared memory

### 11.1 Physical design runs of the current RTL (release LibreLane 3.1.0.dev3, Tiny Tapeout PDK)

| Run | Die | What | Result |
|---|---|---|---|
| tt13b | 6x4 | previous RTL, `PL_MAX_PHI_COEFFICIENT 1.03` | 0 DRC, LVS clean, hold ok, slow-corner setup -0.45 ns at 20 ns |
| tt14a | 6x4 | + pin mapping, line coder, RGET FIFO (16,040 -> 20,334 cells, std-cell area 246k -> 308k um2) | **failed in global routing** (GRT-0228): management, SPI and pin manager sat in an 89 um gap between the engine fences |
| **tt14b** | **8x4** | three columns: engine 0 / common logic / engine 1 (`src/floorplan_engines_tri.json`) | **routes**: routing DRC 0 (detailed routing went 23,753 -> 0 violations), LVS circuits match uniquely, slow-corner setup **+1.69 ns** at 20 ns, hold +0.10 ns (fast corner), 0 setup / hold violations in all three corners, 24,867 std cells = 356k um2 (32 % of the die) + 2 SRAM macros 99.0k um2, 9.3 mW; 1 antenna violation (1 net / 1 pin), 50 max-slew and 12 max-cap violations left |
| tt14b precheck | 8x4 | Tiny Tapeout precheck on the final GDS | **passes** (foundry KLayout DRC, zero area, pin labels, layers, boundary, cell names, analog pins); the first attempt failed only the pin check because the work folder still had `info.yaml` at 6x4 |

`main` uses this layout since commit `e3846c3`; the merged configuration was compared key by key with the one tt14b ran (no differences).

### 11.2 Formal proofs (SymbiYosys, `abc pdr`, unbounded)

| Tree | Proofs | Planted bugs caught |
|---|---|---|
| `main` | pin_mgr, fifo, mgmt (frame v1), engine: all four PASS | 34/34 |
| `feat/frame-v2` | pin_mgr, fifo, mgmt (frame v2: CRC, sequence rules), engine: all four PASS | v2 mutant run in progress |

### 11.3 RTL against the model (`host/isa_diff_test.py`)

Random programs, every clock compared on pc, pins, status, FIFO head, shifters, loop counter, CRC value, flags and R0..R7: **0 mismatching programs**
(batches of 150 x 600 clocks, 97k-99k committed instructions per run), 33/33 planted bugs caught. Two coverage counts fell just short after generator
changes (RGET CRC wait 17 of 20; RGET from the TX FIFO 28 of 30); the generator now weights the CRC wait and the default is 900 programs.

### 11.4 GitHub workflows

Before this push nothing had run since 2026-10-18; `main` was red (`gds` failed at "Build GDS": the placement divergence GPL-0307), `ci/gpl-phi` had
gds, precheck, gl_test, test and docs green and only `viewer` failing (GitHub Pages not enabled). After the push of `8795248` (the placement fix and the
8x4 layout): `test` and `docs` pass; `gds` was running.

### 11.5 Shared 512-word instruction memory (branch `feat/shared-imem`)

| Check | Result |
|---|---|
| `tb/tb_imem_shared.v` | 18/18 |
| `host/isa_model.py`, `host/shmem_test.py` | pass (windows, lock, trap, START, bit-8 jump targets, layout rules) |
| `host/shmem_chip_test.py` on the full chip RTL | pass: two images on two engines (origin 0 and 300), faults, lock, host write rules |
| Default 256-word build | unchanged: unit testbenches, chip demo (574 frames), assembler output identical |
| Layout `shared` (run sh2, L-shaped engines) | global routing demand 319,970 tracks (54 %), overflow 5,726; detailed routing 42,461 -> 31,709 -> 30,768 violations: congested, stopped |
| Layout `shared3` (run sh3, compact 475 um engine columns, macro bottom centre) | global routing demand 192,438 tracks (32 %), overflow 0 (tt14b: 198,509, 0); detailed routing in progress |

Bugs the chip-level test found in the shared-memory RTL: `OP_REGION` had no case in the control unit (PC never advanced); a `?:` mux made the window trap
X for ever in 4-state simulation; the host's address stayed on a held engine's port; a program counter reset to a register value needs an asynchronous-load flop
the library does not have (now a synchronous load of START in shared mode); the PDK's macro Verilog has a `specify` block Yosys cannot parse (a ports-only blackbox is used).
