# USB low speed: design and status (weeks 2-4, 2026-10-26 .. 11-15; FPGA demo week 8)

Status (2026-10-19): **line coder built and verified; device firmware (packet shuttle) enumerates a HID keyboard on the cycle-exact model and is
being verified on the RTL.** This page replaces the first plan; the decisions that changed are in section 3 and 4.

## 1. Goal and scope

A **USB low-speed (1.5 Mbit/s) device** that **enumerates on a PC** and sends HID keyboard reports, verified against a USB host peer model written from the
USB 2.0 text, then shown on the DE0-Nano plugged into a PC. Out of scope: full speed, host role, isochronous / bulk, compliance certification.

## 2. What USB LS needs (USB 2.0, chapters 7 and 8)

| Item | Requirement |
|---|---|
| Bit rate | 1.5 Mbit/s +-1.5 % (device); **33.33 clocks per bit at 50 MHz** |
| Line | D+ / D-; low speed: J = D- high / D+ low (idle), K = the opposite, SE0 = both low; the device pulls D- up with 1.5 kOhm |
| Coding | NRZI (0 = transition, 1 = no transition); **bit stuffing**: a 0 after six 1s; the SYNC's last 1 counts; a final run gets its stuff bit before the EOP |
| Packet | SYNC (KJKJKJKK), PID + complement, payload, CRC, **EOP** = SE0 for 2 bit times, J for 1 |
| CRCs | CRC5 on tokens, CRC16 on data: both in our CRC unit's catalogue |
| Turnaround | the answer starts **2 to 7.5 bit times after the end of the EOP** (7.1.18) |
| Bus states | reset = SE0 for 2.5 us or more at the device; keep-alive = an EOP every 1 ms |

## 3. Hardware: the line coder (built, [LINE_CODER.md](LINE_CODER.md))

A generic byte-level transceiver per engine (NRZI, stuffing with a programmable run length, SE0 EOP, fixed-point bit period, edge-tracking receiver), one new opcode
`LINE` (28) and `RGET LINE` (source 6). Verified against `host/usb_ls.py` (written from the specification): 1175 checks, 18 planted RTL bugs all caught;
cycle-exact model embedded in the ISA model; engine-level differential test with LINE-focused programs. A second small addition made for the firmware:
**`RGET FIFO` (source 7)**: the number of words in the TX and RX FIFO, so the firmware can ask "is a whole 4-word item there?" without blocking.

## 4. Firmware: a packet shuttle, and why ([usb_prog.py](../host/usb_prog.py), 209 of 256 words)

First plan: descriptors in program memory. **That does not fit**: the three descriptors are about 160 bytes of constant packets (data, CRC16, PID per 8-byte chunk) and
the protocol layer needs about 150 words; with one `LDI` per 3 bytes plus dispatch it comes to roughly 320 words of 256, even with a 3-byte transmit command
(designed, then dropped).

Chosen: **split the work.**

| On the chip (firmware) | In the host software ([usb_device_host.py](../host/usb_device_host.py)) |
|---|---|
| SYNC / PID check, token parse (address, endpoint 0 / 1), SETUP data with **CRC16 check** (CRC unit), handshakes ACK / NAK, keeping the pending packet and **sending it again on every IN until the host ACKs**, address filter, **bus-reset detection**, 2 to 7.5 bit-time turnaround | what the device is: descriptors, SET_ADDRESS / SET_CONFIGURATION / HID requests, STALL for unknown requests, HID key reports |

Host <-> chip interface (FIFOs, 32-bit words): the chip posts events (`SETUP` + 3 words, packet acknowledged, bus reset); the host pushes 4-word items (a header with length /
endpoint / kind, then up to 11 bytes: PID, data, CRC16) or a "set the device address" item. Full format in the module docstring.
A PC accepts seconds of NAKs on a control transfer (Linux: 5 s), so the host software has ample time even over a slow SPI/UART path; the chip itself answers every token
within a few bit times. The chip then emulates *any* low-speed device whose packets the host provides - which is what a programmable emulator is for.

Not on the chip: token CRC5 check, OUT data delivery to the host (acknowledged only), more than one pending packet.

## 5. Verification

* `host/usb_host.py`: reactive USB host peer model (bit-level driving at a programmable bit-rate offset, packet decode, timing measurement, control transfers), independent of the
  firmware. `tb/tb_host_bridge.v` has the bus model (device drivers, host driver, pull-up).
* `host/usb_test.py [rtl] [rate]`: enumeration as a PC does it (reset, 64-byte device descriptor read, SET_ADDRESS, descriptors, SET_CONFIGURATION, SET_IDLE, HID report
  descriptor, SET_PROTOCOL), HID key reports with DATA0/DATA1 toggling, retransmission of an unacknowledged packet, NAK, ignored tokens (wrong address, endpoint 2, damaged PID),
  damaged SETUP data, STALL, bus reset, response timing; at host bit rates of +-1.5 %.
* Model first (seconds), then the RTL through the SPI bridge.
* Planned: mutants of the firmware (wrong PID check, toggle, address filter, retransmission, reset threshold), FPGA demo on a PC (week 8).
