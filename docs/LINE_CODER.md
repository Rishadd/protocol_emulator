# Line coder: the `LINE` opcode (built 2026-10-19)

Status: **RTL built, unit-tested against USB 2.0 and cycle-modelled** (`src/line_coder.v`, `host/line_model.py`, `host/line_coder_test.py`,
`host/isa_diff_test.py`). A small byte-level serial line transceiver in every engine. It exists because USB low speed (33.33 clocks per bit) is too fast for a firmware
bit loop that also has to insert and remove stuff bits ([USB_LS_PLAN.md](USB_LS_PLAN.md)); it is **generic, not USB-specific**: NRZI on / off, bit stuffing on / off
with a programmable run length, a differential pair with an SE0 end of packet, a bit period in clocks with 8 fractional bits.

## 1. Instruction set

| Item | Encoding | Meaning |
|---|---|---|
| `LINE lop, rs` | opcode 28, `[26:24]` lop, `[2:0]` rs | one line-coder command; R[rs] is the argument |
| `RGET rd, LINE` | RGET with source 6 | R[rd] <- status word; reading consumes the received byte |

Reserved: LINE operations 6 and 7 trap like any reserved encoding. All earlier encodings and timings are unchanged.

A companion addition, **`RGET rd, FIFO`** (RGET source 7, the last free one): `[2:0]` words in the TX FIFO, `[5:3]` words in the RX FIFO; it never stalls. Without it the only way to
learn that the host has queued data is `RGET TXF`, which blocks the engine; with it firmware can poll (the USB firmware waits for a whole 4-word item before taking it).

| lop | Name | Argument (R[rs]) | Effect |
|---|---|---|---|
| 0 | CFG | `[2:0]` D+ pin, `[5:3]` D- pin, `[6]` NRZI, `[7]` stuffing, `[10:8]` stuff run length, `[11]` fs | configuration (reset: D+ = pin 0, D- = pin 1, NRZI on, stuffing on, run 6, low speed) |
| 1 | PERIOD | `[15:0]` bit period in clocks x 256 | reset 0x2155 = 33.332 clocks = 666.6 ns (USB low speed at 50 MHz); minimum 3 clocks per bit (0x0300) |
| 2 | TXB | `[7:0]` byte | queue a byte for transmission, LSB first; **stalls while the 2-entry queue is full** |
| 3 | TXE | - | queue an end of packet: SE0 for 2 bit times, J for 1 bit time, then the driver is released; stalls while full |
| 4 | RXCTL | `[0]` receiver enable, `[1]` clear the receive flags | |
| 5 | RESET | - | transmitter and receiver to idle, queue emptied, receiver disabled (configuration kept) |

`fs` selects the polarity of J: low speed (0) has J = D+ low, D- high; full speed (1) the opposite. K is always the opposite of J.

Timing: a LINE command takes effect **one clock after its instruction** (like the CRC unit). `RGET LINE` directly after a LINE instruction waits that one clock, so it always
sees the effect of the command before it. Everything else about the engine's timing is unchanged.

## 2. Transmit

* The first TXB after idle starts the packet: the line idles at J, the driver turns on at the first bit (3 clocks after the instruction when idle).
* Bits go out LSB first at the programmed period (a fractional accumulator spreads the 0.332 so the average is exact; any single bit is 33 or 34 clocks).
* NRZI: a 0 toggles the line, a 1 keeps it. Stuffing: after `run` consecutive 1s a 0 is inserted, counting from the first bit of the packet. The USB SYNC (`KJKJKJKK`) is the ordinary byte 0x80
  and its final 1 counts toward the run, as the specification requires. **A final run of 1s gets its stuff bit before the EOP.**
* TXE ends the packet: SE0 for two bit times, J for one bit time, then the driver is released and the bus pull-up holds J. TXE as the first command is a bare EOP (the low-speed keep-alive).
* If the queue runs empty in the middle of a packet the coder waits at the byte boundary and sets `underrun`. The firmware must queue the next byte within 8 bit times (267 clocks).
* The coder drives its two logical pins (D+, D-) through the pin manager like any engine pins: they must be claimed and mapped ([HOST_INTERFACE.md](HOST_INTERFACE.md)).

## 3. Receive

* Armed by RXCTL (enable) and ignored while the coder transmits. The first K after idle starts a packet.
* The sampler is **re-centred on every line transition** and samples half a bit later; between transitions it free-runs at the programmed period, so a host bit rate within +-1.5 % and edge
  jitter are tolerated (tested at +-1.5 % with +-1 clock of jitter, runs of seven bits).
* SYNC: at least three 0s followed by a 1 (a hub may shorten the SYNC to four bits). Then NRZI decode, stuffed 0s removed (a 1 where a stuff bit belongs sets `stuff_err`), bytes assembled LSB first.
* SE0 at a sample point ends the packet: `eop` is set and `partial` holds the number of bits of an incomplete last byte. An SE1 sample sets `stuff_err` and abandons the packet. The receiver
  returns to idle when J is back.

## 4. Status word (`RGET rd, LINE`)

| Bits | Name | |
|---|---|---|
| `[7:0]` | byte | last received byte |
| 8 | valid | a received byte is waiting; **the RGET consumes it** (it is overwritten, and `overrun` set, if the next byte completes first) |
| 9 | eop | end of packet seen (sticky until RXCTL clear) |
| 10 | sync | a SYNC was seen (sticky until clear) |
| 11 | stuff_err | stuff violation or SE1 (sticky) |
| 12 | overrun | a byte was lost (sticky) |
| 13 | tx_busy | queue not empty or a packet is on the line |
| 14 | full | the next TXB / TXE would stall |
| 16:15 | D+, D- | the raw pin levels (J / K / SE0 as the firmware can time them, e.g. bus reset = SE0 for 2.5 us) |
| 19:17 | partial | bits of an incomplete last byte at the EOP |
| 20 | underrun | the transmit queue ran empty mid-packet |
| 21 | rx_active | receiving a packet |
| 22 | rx_en | receiver enabled |

Firmware pattern for a received packet: `RXCTL 3` (enable and clear), loop `RGET r, LINE`, test `valid` (take the byte and feed the CRC unit) or `eop` (packet complete), test `partial`.
A byte arrives every 8 bit times, so 267 clocks are available per byte.

## 5. Verification

* `host/line_coder_test.py`: a testbench with two coders on one bus and a pull-up; the expected waveform and the decoder come from `host/usb_ls.py`, written from the specification and sharing no
  code with the RTL. Transmit: random packets, worst-case stuffing (runs of 1s, final run, all zeros), back-to-back packets, bare EOP, underrun; every run on the bus is a whole number
  of bit times to within 1.5 clocks and the receiver (bit period off by +-1.5 %) returns the bytes. Receive: packets from the Python generator at +-1.5 % host rate with edge jitter,
  shortened SYNC, partial byte, stuff violation, false start, 25 random sweeps. **18 planted bugs in the RTL are all caught** (`python3 host/line_coder_test.py mutants`).
* `host/line_model.py` is a clock-exact model of the same state machine; `host/isa_model.py` embeds it and `host/isa_diff_test.py` compares engine and model every clock on random
  programs, including line-focused programs whose two coder pins carry random USB waveforms, with RTL mutants for the new decode, stall and pin-takeover paths.

## 6. Cost

Roughly 150 flip-flops and the logic around them per engine (about 1-1.5k cells), off the ALU critical path (own timers and shifters); the flow run with both engines will give the exact figure.
