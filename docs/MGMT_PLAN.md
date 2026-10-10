# Management Module + SPI Host Link — Implementation and Test Plan

Companion to [EXECUTION_PLAN.md](EXECUTION_PLAN.md) (task R8) and [PROTOCOL_EMULATOR_ARCHITECTURE.md](PROTOCOL_EMULATOR_ARCHITECTURE.md) §6 | 2026-10-10 | Status: **plan, nothing built yet**

## As built: frame v1 (2026-10-11, simulation only)

The user's 8-step sequence (see [../memory.md](../memory.md)) replaced the order below. CRC and
sequence numbers are deliberately left out until the basics are proven.

**Pins (Tiny Tapeout template, architecture doc §5):** `ui_in[0]` SCLK, `ui_in[1]` MOSI,
`ui_in[2]` CS_N, `uo_out[0]` MISO, `uio[7:0]` protocol pins. Top: `src/tt_um_protocol_emulator.v`.

**Frame:** exactly 7 bytes per CS_N low, SPI mode 0, MSB first, big endian, full duplex.

| Byte | 0 | 1-2 | 3-6 |
|---|---|---|---|
| MOSI | op: 0x01 WRITE, 0x02 READ | address | write data |
| MISO | STATUS | 0x00 | read data (0 for WRITE) |

STATUS (sampled at frame start): `[7]` 1 (alive), `[6]` err, `[5:4]` RUN e1/e0,
`[3:2]` TX full e1/e0, `[1:0]` RX has data e1/e0.

**Registers** (engine e, base = 0x1000 for engine 0 and 0x2000 for engine 1):

| Address | Access | Meaning |
|---|---|---|
| base+0x000 | W | CTRL bit 0 RUN. RUN=0 holds PC/control/pins in reset, keeps FIFOs and memory |
| base+0x000 | R | `{pc[13:8], fault[2], halted[1], RUN[0]}` |
| base+0x100+4i | W | instruction word i (only while RUN=0) |
| base+0x200 | W | TX FIFO push; accepted only if this frame's STATUS showed TX not full |
| base+0x204 | R | RX FIFO pop; valid (and popped) only if this frame's STATUS showed RX data |

**Commit rules:** nothing takes effect before CS_N rises on a complete 7-byte frame, so an
aborted frame does nothing. A bad frame (length, op, address, a write to a running engine's
memory) changes nothing and sets the sticky err bit (cleared by reset). The STATUS rules make
every TX push and RX pop exactly-once, without extra polling frames.

## Goal

A host (a testbench in simulation, a Pico later) sends everything to the chip over SPI:
the engine programs, the control commands, and a long message. The management module
decodes the SPI frames and loads the two UART engines (TX and RX firmware). It then moves
payload bytes between SPI and the engine FIFOs. Success test: a long message goes out over
SPI, through the TX engine onto the UART line, back into the RX engine, and out over SPI.
The sent and received data must be identical.

## What blocks us today

- **The instruction memory is read-only.** [instr_mem.v](../src/instr_mem.v) is a ROM loaded
  with `INIT_FILE`. Programs can't come from SPI until it gets a write port.
- **The engine starts running at reset.** If the memory is empty or X, it executes garbage, so
  we need a `run` gate that holds the PC and control state in reset while the memory loads.
  The FIFOs and the memory must survive that hold, so a TX word can be preloaded before arming.
- **The FIFOs are only 4 words deep** ([fifo.v](../src/fifo.v)). A long message can't be pushed
  in one go, and the RX side must be drained fast enough. Flow control is the central part of
  this design. `fifo.v` exposes only `full`/`empty`, so level reporting needs a small
  count output.
- **Bandwidth is tight at 115200 baud.** One byte takes about 87 us per direction. At a 3 MHz
  SPI clock, a 12-byte frame takes 32 us. Streaming needs one write frame and one read frame
  per byte, which is about 64 us, so there is almost no spare time. Put FIFO status in the
  response to every frame so we never spend frames polling, and start the long-message tests at
  a lower baud. Keep 115200 as the stretch goal.

## Build order

Each step has a testbench that passes before the next starts.

1. **Freeze the v1 spec and write the Python golden model** (`host/mgmt_frame.py`).
   - The 12-byte frame: op, seq, addr, payload, status, CRC-16/CCITT-FALSE.
   - A minimal address map: ID, global run/halt/reset per engine, engine instruction-memory
     window, FIFO window, and status. Engine 1 sits at the 0x2000 window.
   - Status bits: `tx_full`, `rx_empty`, levels, `halted`, `fault`, and a sticky RX-overrun flag.
   - **Test:** the CRC of `"123456789"` must be 0x29B1, and encode/decode must round-trip.
2. **Engine changes** (the only edits to verified RTL): the instruction-memory write port and
   the `run` gate.
   - **Test:** all 136 existing checks still pass with `run` tied high. A new testbench writes
     words, arms the engine, and checks the PC starts at 0.
3. **`spi_slave.v`**: SPI mode 0, MSB first, with SCLK, CS and MOSI synchronized into the
   system clock. CS going high mid-frame aborts the frame.
   - **Test:** an SPI master model in the testbench (`tb/spi_bfm.vh`), swept over SCLK divide
     ratios down to 8 system clocks per half-period.
4. **Frame layer** (`mgmt_frame.v`): collect 12 bytes, check the CRC, and commit only after the
   frame is accepted. Responses are pipelined, so each frame returns the previous command's
   result, and a duplicate seq returns the cached result without side effects.
   - **Test:** bad CRC, a mid-frame CS abort, and a duplicate seq. The duplicate-seq case
     matters most. A retried frame must never push or pop a FIFO twice, or the stream gets
     corrupted.
5. **`mgmt_regs.v`**: the decoder that routes to the resources:
   - instruction-memory write and read-back for both engines
   - run, halt and reset control
   - TX FIFO write (never blocks, returns BUSY when full)
   - RX FIFO pop (BUSY when empty)
   - status reads
   - The RX word is exposed raw as 32 bits, with the byte in bits [31:24], and the host script
     shifts it down. This avoids extra hardware.
   - **Test:** load `uart_tx_prog.hex` over SPI, then compare the waveform to the INIT_FILE
     version using the existing cycle-exact `check_exact`. This proves SPI loading changes
     nothing.
6. **`mgmt_top.v`**: SPI slave, frame layer, regs and both engines. The UART pins match the
   duplex top. The old [de0_nano_duplex_top.v](../src/fpga/de0_nano_duplex_top.v) stays
   untouched as the known-good fallback.

## How the testbench works

- Python writes a **command file** with high-level operations: load program, write byte N, read
  RX, arm, run for N cycles. The Verilog SPI master (`tb_mgmt.v`) executes it.
- **The polling and pacing logic lives in the Verilog master model.** Flow control has to react
  to the FIFO status coming back, and a precomputed edges file can't do that. This is the one
  real difference from today's open-loop edges-file approach
  ([host/uart_duplex_workload.py](../host/uart_duplex_workload.py)).
- The testbench logs:
  - UART TX line edges (the same `T <ns> <level>` format the existing code decodes)
  - every RX word read over SPI
  - status snapshots

## Test ladder

| # | Test | Pass condition |
|---|---|---|
| T1 | Read ID, scratch write/read, bad CRC, CS abort | Correct responses, no side effects on bad frames |
| T2 | Load both programs, read back and checksum | Checksum matches the hex files |
| T3 | **TX only**: stream the long message through SPI with flow control. `rec_tx.py` decodes the line into `tx_rec.bin`. | `tx_rec.bin` equals the sent message |
| T4 | **RX only**: the existing fake phone (`make_edges`) drives RX, and the host drains over SPI into `rx_got.bin` | `rx_got.bin` equals the sent bytes |
| T5 | **Loopback**: the long message goes over SPI, out the TX engine, back into the RX engine, and out over SPI. `compare.py` checks sent against recorded against received. | All three identical; on mismatch it prints the first bad index |
| T6 | Stress: host stalls (provoke RX overrun and check the flag), SPI clock ratios, CS aborts and bad CRC injected mid-stream with retries, baud error | Exactly-once delivery, no duplicates or drops |
| T7 | Add everything to [run_tests.ps1](../run_tests.ps1) | One command runs it all |

**T5, two ways.** The Verilog simulator can't stream to and from a live Python script in batch
mode, so the loopback runs in two forms:

- **Concurrent loopback.** The testbench wires TX to RX and Python only post-processes. This
  tests real full-duplex timing, and it's the primary result.
- **Two-pass replay.** Run 1 records the TX line. Python writes `tx_rec.bin` and converts the
  recorded timestamps into an edges file (optionally with jitter or baud error). Run 2 replays
  that edges file into RX. The same record and compare scripts later work against a real serial
  port on hardware.

## Open decisions

- **Message size.** At 115200 baud, 10 KB is about 44M simulated clock cycles. Proposal: 1 KB for
  the regression and 10 KB or more as an occasional soak run.
- **Baud for the long test.** Proposal: run T3 to T5 at 57600 or lower first, and push to 115200
  once the pacing is proven.
