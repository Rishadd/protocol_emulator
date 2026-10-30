# Code guide: how the whole project works, file by file

Read this first when you need to know what the code does. It follows one program from the PC to a pin. Everything here was read from the source in
`src/` and `host/`; where a detail lives in another document the link is given. Last checked against the source on 2026-10-30.

## 1. The idea in one paragraph

The chip has **no fixed protocol hardware**. It has two small processors ("engines") whose instructions move bits on 8 pins each, wait exact numbers of
clock cycles and read pins. A protocol (UART, SPI, I2C, CAN, ...) is a *program* for an engine, loaded over a 4-wire SPI "management link". The programs are
written with a Python assembler (`host/asm.py`), tested in simulation against Python models of the other side of the wire, and then run on the chip.

```
 PC / Pico ──SPI (SCLK, MOSI, CS_N, MISO)──► spi_slave ─► mgmt ─┬─► imem_shared (ONE 512 x 32 memory) ◄── fetch ── engine 0, engine 1
                                                                ├─► engine FIFOs (TX in, RX out), RUN bits
                                                                ├─► pin_mgr  (which engine owns which pad, input selects, HOLD, IRQ)
                                                                └─► la_block (optional logic analyser)
 engine 0 / engine 1 ──8 logical pins each──► pin_mgr ──► uio[7:0] pads, uo_out[7:1]        (ui_in[7:3], uio[7:0] are the inputs)
```

## 2. Top level: `src/tt_um_protocol_emulator.v`

The Tiny Tapeout top module (fixed port names `ui_in, uo_out, uio_in/out/oe, ena, clk, rst_n`). It only wires blocks together:

| Instance | File | Job |
|---|---|---|
| `rst_sync` | (inline) | reset asserts asynchronously, releases synchronously (2 flops) |
| `u_spi` | `spi_slave.v` | SPI mode 0 slave on `ui_in[0..2]` / `uo_out[0]`; turns pins into bytes. All three inputs go through synchronisers, SCLK is edge-detected: there is no SCLK clock tree. |
| `u_mgmt` | `mgmt.v` | decodes frames into reads and writes: engine RUN, instruction memory, FIFOs, pin manager and analyser registers; keeps the sticky `err` flag |
| `u_pins` | `pin_mgr.v` | owner, remap and open-drain per output pad; input select per engine pin; HOLD; IRQ |
| `u_dbg` | `dbg_view.v` | picks one of 8 debug views for `uo_out[7:2]` (heartbeat, SPI activity, run/halt/fault, ...) |
| `u_imem` | `imem_shared.v` | the shared instruction memory (one 2-port macro) with a window per engine |
| `u_eng0`, `u_eng1` | `engine_top.v` | the two engines |
| `u_la` (only with `-DLA`) | `la_block.v`, `la_unit.v` | logic analyser: records pins and the engines' trigger lines |

Pin map (also in the file header): `ui_in[0]` SCLK, `ui_in[1]` MOSI, `ui_in[2]` CS_N, `uo_out[0]` MISO are fixed. `uio[7:0]` are protocol pads, `ui_in[3]` HOLD,
`ui_in[4]` trigger in, `ui_in[7:5]` debug view select, `uo_out[1]` IRQ. Logical pin *i* of an engine is `uio[i]` until `pin_mgr` is told otherwise.

Compile-time switches: `SHARED_IMEM` (shared memory; the chip build), `LA` (logic analyser), `SYNTHESIS` (hide simulation helpers), `FORMAL` (extra ports for proofs).
Without `SHARED_IMEM` each engine owns a private 256-word memory (`instr_mem.v`); this older variant is kept because the unit testbenches and protocol suites A-D use it.

## 3. One engine: `src/engine_top.v`

```
 imem_shared ──instr──► control_unit ──► pc_reg ──next_pc──► (address back to the memory)
                          │  decodes the 32-bit word, issues one-clock strobes to:
                          ├─ delay_counter (WAIT, timed instructions)     ├─ alu_unit (8 x 32-bit registers, flags Z N C)
                          ├─ loop_counter (SETL/DJNZ)                     ├─ crc_unit (any CRC: width, poly, init, reflect)
                          ├─ shift_reg OSR / ISR (32-bit, either bit order)├─ line_coder (USB-style NRZI + bit stuffing + SE0 byte transceiver)
                          ├─ fifo TX (host -> engine) and RX (engine -> host), 4 words deep
                          └─ pin_block: 8 pins, per-pin output value and output-enable, 2-flop input synchroniser
```

Facts that explain the behaviour:
* **Fetch.** The memory read is synchronous, so it is addressed with `next_pc` (the value the PC will have after this edge): the word for the new PC arrives in the same
  clock the PC changes (`pc_reg.v`).
* **Timing.** An instruction commits in state `S_EXEC`. A timed instruction with operand *d* (WAIT, OUT1, IN1) occupies exactly *d+1* clocks: it sits in `S_HOLD` until the
  delay counter's last cycle. Blocking instructions (PULL, PUSH, WAITH, WAITL, RGET TXF, LINE TXB ...) keep the PC and have no side effect until the condition clears.
  This exactness is why protocol timing is cycle-exact and testable.
* **Traps.** An unknown opcode, a reserved sub-field, a fetch outside the engine's window, or a second `REGION` halts the engine with `fault = 1`.
* **Run / hold.** `run = 0` keeps the execution core in reset (PC = START, pins released). FIFOs and memory keep their contents, so the host loads while held.
* **Trigger / timestamp.** `TSTAMP rd` copies a free-running 32-bit counter into a register; `RPUT TRIG` drives the engine's trigger line to the analyser.

### Instruction word: `src/isa.vh` (the single list of opcodes)
`[31:27]` opcode, `[26:0]` operand. Python mirror: `host/asm.py` (`OPCODE`, `word()`); reference model: `host/isa_model.py`.

| Group | Opcodes |
|---|---|
| flow | NOP, WAIT d, JMP, HALT, SETL n, DJNZ, JPH / JPL (jump on pin), JPO (jump on next OSR bit), JCC (jump on ALU flags), WAITR (delay from a register), REGION |
| shift registers and FIFOs | PULL (TX FIFO -> OSR), PUSH (ISR -> RX FIFO), PUSHI (immediate -> RX FIFO), OUT1 d (OSR bit to pin), IN1 d (pin to ISR), CFG (pins and bit order) |
| pins | SETH, SETLO, DIRO (drive), DIRI (release), WAITH, WAITL (block until the pin is high / low) |
| registers | LDI, ALU (MOV ADD SUB AND OR XOR SHL SHR CMP TST NOT PAR REV8), RGET (read OSR/ISR/loop counter/pins/CRC/TX FIFO/line coder/FIFO levels), RPUT (write OSR/ISR/LC/RX FIFO/trigger) |
| units | CRC (reset, poly, init, xorout, format, feed bit, feed byte), LINE (config, period, tx byte, end of packet, rx control, reset), TSTAMP |

A small program, with the assembler call on the left (`host/fpga_bringup.py` runs it on the chip):
```python
a = Asm(); a.REGION()          # first instruction: this engine may fetch only the words of its own image
a.LDI(0, 0)                    # R0 = 0
a.label("l")
a.ALU("ADD", 0, imm=1)         # R0 += 1
a.ALU("CMP", 0, imm=3)         # flags from R0 - 3
a.JCC("NZ", "l")               # loop until R0 == 3
a.RPUT("RXF", 0)               # push R0 into the RX FIFO: the host reads 3
a.HALT()
```

## 4. Shared instruction memory: `src/imem_shared.v`

One 2-port 512 x 32 SRAM macro (`RM_IHPSG13_2P_512x32_c2_bm_bist`) for both engines. Engine 0 fetches on port B, engine 1 on port A. Addresses are physical.
Each engine has a window `[base, limit)` set by its own first instruction `REGION` (once per run; the lock clears when the engine is held). A fetch outside the window
returns the TRAP word (opcode 31). The host writes through the port of a *held* engine, and only into words that no running engine's window contains. Image
placement and the rules are checked in Python first (`host/shmem_host.py`: `Image`, `plan`, `ShmemHost`). Engine 1's image sits at word 256 or above, so jump targets
need address bit 8, which is operand bit 11 (done by the assembler / `fw_layout.py`).

## 5. Management link: `src/spi_slave.v`, `src/mgmt.v`

SPI mode 0, MSB first, full duplex, CS_N low for the whole frame. SCLK high and low phases >= 8 system clocks, CS_N setup/hold >= 4 (keep the host SPI clock <= 3 MHz at 50 MHz).
Two frame types, chosen by bit 7 of the first byte:
* **v1** (7 bytes, simple): `op(0x01 write / 0x02 read), address(2, big endian), data(4)`. The reply's first byte is STATUS (bit 7 = alive, 6 = err, 5:4 RUN, 3:2 TX full, 1:0 RX has data).
* **v2** (12 bytes, little endian, CRC-16, sequence numbers, results pipelined, retry-safe): described in the header of `mgmt.v` and `docs/HOST_INTERFACE.md`.

Address map (header of `mgmt.v`; `e` = engine, `base = 0x1000 * (e + 1)`): `0x0000` ID ('PEM1' = 0x50454D31), `0x0004` VERSION, `0x0008` CAPABILITY, `0x000C` SCRATCH,
`0x0010` ERRCNT; `base+0x000` CTRL (bit 0 RUN), `base+0x00C` START, `base+0x200` TX_DATA, `base+0x204` RX_DATA; **instruction words** at `0x0400 + 4*w` for physical word w = 0..511;
pin manager window `0x0200..0x02FF` (`pin_mgr.v`), analyser window `0x0300..0x03FF` (`la_block.v`).

## 6. Pins: `src/pin_mgr.v`

Each engine has 8 logical pins. For each output pad: an *owner* (none / engine 0 / engine 1), a *remap* and an open-drain bit. For each engine and logical input: an input select over
`{uio[7:0], ui_in[7:3]}`. A pad cannot be reconfigured while its owner runs. HOLD (`ui_in[3]`, when enabled) releases every engine pin and clears RUN. Host calls: `claim_pad`, `claim_uo`, `select_input` in `host/chip_host.py`.

## 7. Logic analyser: `src/la_block.v`, `src/la_unit.v`
16 channels (13 input pins, RUN of both engines, OR of the engines' trigger lines), a ring buffer in a macro, trigger types manual / pattern / rising / falling / software, capture in change mode or sample mode.
`la_unit.v` is the state machine; `host/la_model.py` is its Python twin and the two are compared clock for clock. Registers are at `0x0300..0x0320`. The buffer is a second instance of the 2-port macro (only port A, words 0..255 used).
Not built yet (docs/DEBUG_LA_PLAN.md phases 4-8): engine halt / single-step / breakpoints, protocol sniffers, the capture tool `la_capture.py` with GTKWave output.

## 8. The Python side (`host/`)

| Layer | Files | What it does |
|---|---|---|
| assemble | `asm.py`, `fw_layout.py`, `*_prog.py` (spi, i2c, can, jtag, usb, modbus, onewire, ws2812, ps2, swd, uart_rx) | build instruction words; every `*_prog.py` is a firmware generator for one protocol |
| model | `isa_model.py`, `crc_model.py`, `line_model.py`, `la_model.py`, `can_model.py`, `bus_model.py` | Python reference of the processor and of the units; the other side of each wire |
| drive the chip | `chip_host.py` (`ChipHost`: frames, FIFOs, pins; `SimLink`: the RTL in Icarus), `shmem_host.py` (placing images), `serial_link.py` + `pico_bridge.py` (real hardware) | |
| test | `*_test.py`, `isa_diff*.py`, `*_mutants.py`, `mutation.py`, `workload.py`, `uart_*workload.py`, `mgmt_*`, `regress.py` | see section 9 |
| bring-up | `fpga_bringup.py` | first checks on the board or in simulation |

## 9. How it is verified (all run by `python3 host/regress.py`)
1. **Unit testbenches** (`tb/tb_*.v`, run by `run_tests.sh`): one per block.
2. **Differential test**: random instruction streams run on the RTL and on `isa_model.py`; every register, pin and PC must match.
3. **Protocol suites**: the firmware talks to a Python or Verilog model of the other side (`tb/peer_*.v`); cycle-exact comparison against a reference waveform.
4. **Chip level**: the same suites again through the management SPI only (`PROTO_CHIP=1`), with pins remapped at random, with firmware relocated, and from the shared memory.
5. **Mutation tests**: bugs are planted in RTL or firmware; the tests must catch every one (`*_mutants.py` print "caught N/N").
6. **Formal proofs** (`formal/*.sby`): FIFO, engine, management, pin manager, shared memory windows.
7. **Layout checks**: LibreLane flow, DRC, LVS, antenna, timing in three corners, Tiny Tapeout precheck.

## 10. Hardware bring-up on the DE0-Nano

`src/fpga/de0_nano_chip_top.v` puts the whole chip on the board: 50 MHz oscillator directly, `src/fpga/sram2p_fpga.v` replaces the SRAM macro with block RAM, KEY0 is reset.
Header GPIO_2 (pin numbers are in `quartus/pe_chip.qsf`, from Terasic's manual): inputs `GPIO_2_IN[0..2]` = SCLK, MOSI, CS_N; `GPIO_2[0]` = MISO; `GPIO_2[8:1]` = `uio[7:0]`;
`GPIO_2[9]` = IRQ; `GPIO_2[10]` = HOLD in; `GPIO_2[11]` = trigger in; `GPIO_2[12]` = debug select bit 0. LEDs show IRQ, a heartbeat and the debug view.
Steps: (1) open `quartus/pe_chip.qpf`, compile, program; (2) wire a Pico: GP18 SCK, GP19 MOSI, GP16 MISO, GP17 CS to the three inputs and MISO, common ground, 3.3 V only; copy `host/pico_bridge.py` to the Pico as `main.py`;
(3) `pip install pyserial`; `python3 host/fpga_bringup.py --port /dev/ttyACM0`. The same script with `--sim` runs the identical design in simulation.
**Not verified:** the Quartus compile and timing at 50 MHz (no Quartus on the build machine), and the Pico bridge on real hardware. Both are simulated or syntax-checked only.
