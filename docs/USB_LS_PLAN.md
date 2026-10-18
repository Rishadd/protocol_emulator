# USB low speed: plan (weeks 2-4, 2026-10-26 .. 11-15; FPGA demo week 8)

Status: **planned** (2026-10-18). Part of the plan to 2026-12-30 ([EXECUTION_PLAN.md](EXECUTION_PLAN.md)). Stretch goal of the
challenge; two of the strongest public entries (Loom, MarcosAsh) show a USB LS device.

## 1. Goal and scope

A **USB low-speed (1.5 Mbit/s) device** in firmware: a HID boot keyboard (or mouse) that **enumerates on a PC** and sends reports.
Verified against a USB host peer model written from the USB 2.0 specification, then shown on the DE0-Nano plugged into a PC.
Out of scope: full-speed, host role, isochronous / bulk transfers, compliance certification.

## 2. What USB LS needs (USB 2.0, chapters 7 and 8)

| Item | Requirement |
|---|---|
| Bit rate | 1.5 Mbit/s +-1.5 % (device); **33.33 clocks per bit at 50 MHz** |
| Line | differential D+ / D-; low speed: J = D- high / D+ low (idle), K = the opposite, SE0 = both low; device pulls D- up with 1.5 kOhm |
| Coding | NRZI (0 = transition, 1 = no transition); **bit stuffing**: a 0 after six consecutive 1s, removed by the receiver, seven 1s = error |
| Packet framing | SYNC (KJKJKJKK), PID (4 bits + complement), payload, CRC, **EOP** = SE0 for about 2 bit times then J |
| CRCs | CRC5 on tokens, CRC16 on data: **both already in our CRC unit's catalogue** (CRC-5/USB, CRC-16/USB, tested) |
| Packets | token (SETUP / IN / OUT: address, endpoint, CRC5), data (DATA0 / DATA1, up to 8 bytes at low speed, CRC16), handshake (ACK / NAK / STALL) |
| Turnaround | the device must start its response within a few bit times of the host's EOP (exact limit from USB 2.0 7.1.19, to be pinned in the spec phase) |
| Bus states | reset = SE0 for at least 2.5 us at the device; keep-alive = an LS EOP every 1 ms; suspend after 3 ms idle |

## 3. Why a hardware assist, and which

A firmware bit loop has 33 clocks per bit (our CAN loop needs at least 35), must insert or remove stuff bits that shift every later
bit by one bit time, must resynchronise to the host's edges, and must turn a packet around within a few bit times. Too tight for
firmware alone, so each engine gets a small **line coder** that works on bytes. It is **generic, not USB-specific** (the challenge
asks for programmable engines, not protocol blocks): NRZI on / off, stuffing on / off with a programmable run length (6 for USB,
5 for CAN), differential pair or single pin, programmable bit period (16.8 fixed point, so 33.33 clocks is exact on average),
SE0 / end-of-packet generation and detection in differential mode.

| Path | Function |
|---|---|
| Transmit | firmware queues bytes (and "send SYNC", "send EOP" commands); the coder shifts them out at the programmed bit period, LSB first, with stuffing and NRZI, driving the logical pin pair (two physical pins via the pin mapping, [PIN_MAP_PLAN.md](PIN_MAP_PLAN.md)) |
| Receive | edge-tracking sampler (re-centres on every transition, so +-1.5 % plus host jitter is tolerated), NRZI decode, destuffing, SYNC detection, byte assembly; flags SE0 / EOP, stuff errors and bit count; bytes go to the ISR / RX path for firmware |

**Instruction set:** one new opcode (28 is free, it traps today) `LINE op, rs` in the style of `CRC`: set configuration, set bit
period, queue a byte, queue SYNC / EOP, arm receive; plus one new `RGET` source (6, free) for the coder's status and received byte.
Existing opcodes, encodings and timing are unchanged; the cycle-exact model gets the coder.

## 4. Firmware

Packet layer (SYNC, PID check, CRC5 / CRC16 through the CRC unit, handshakes, DATA0 / DATA1 toggle), control transfers on endpoint 0
(GET_DESCRIPTOR device / configuration / HID report, SET_ADDRESS, SET_CONFIGURATION, SET_IDLE, SET_PROTOCOL), interrupt IN on
endpoint 1 (8-byte boot keyboard report; the host or a test pushes key codes through the TX FIFO), bus reset and keep-alive handling.
Descriptors live in program memory (256 words: size budget checked early; the second engine stays free).

## 5. Verification (same standard as every protocol so far)

- **Host peer model** written from the USB 2.0 text, not from our firmware: bit-level line with NRZI, stuffing, EOP, bit-rate
  offset and jitter, turnaround timing; runs the enumeration sequence a PC runs and checks every response.
- **Line coder unit tests** (random byte streams through TX -> RX at bit-rate offsets up to the limit), plus **formal properties**:
  never seven 1s on the line in stuffing mode, destuff(stuff(x)) = x, the receiver re-centres within one bit after an edge.
- **Mutants** in the coder RTL and the firmware (wrong stuff count, missing PID complement check, DATA toggle not flipped, CRC5
  residual wrong, late turnaround).
- Full regression (the coder must not change any existing opcode), differential test with the new opcode and RGET source.
- **Flow run** with the coder in both engines: 50 MHz must still close.
- **FPGA (week 8):** DE0-Nano, USB connector with the 1.5 kOhm pull-up on D-, plugged into a PC: the keyboard enumerates
  (`lsusb` / Device Manager) and types.

## 6. Schedule

| Week | Work |
|---|---|
| 2 (Oct 26 - Nov 1) | line coder RTL + unit tests + formal; `LINE` opcode in RTL, model, assembler |
| 3 (Nov 2 - 8) | host peer model; packet layer and control transfers in firmware |
| 4 (Nov 9 - 15) | full enumeration + HID reports against the peer; mutants; flow run |
| 8 (Dec 7 - 13) | FPGA demo on a PC |

## 7. Cost and risks

About 1-1.5k cells per engine. Off the ALU critical path (own shifter and timer). Risks: the turnaround limit in firmware (mitigation:
the coder can send a prepared handshake automatically); program size of descriptors + control transfers (mitigation: compact
descriptor encoding, or keep descriptors in the host-written data path); real PC timing quirks only visible on the FPGA (week 8).
