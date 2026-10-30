# Standalone USB low-speed device: plan and test plan

Status: **planned, 2026-10-20.** Follows [USB_LS_PLAN.md](USB_LS_PLAN.md) (line coder and the packet-shuttle firmware, built and verified) and needs the shared
instruction memory ([SHARED_IMEM_SOFTWARE_PLAN.md](SHARED_IMEM_SOFTWARE_PLAN.md)). Reason: other entries enumerate a USB device **from the chip alone** (Loom: a HID boot
mouse, "enumeration and interrupt IN", on-chip firmware). Ours today needs host software to supply the descriptors, so a PC plugged straight into the chip would not
see a device unless the SPI host is also attached.

## 1. Goal

A **USB low-speed HID device that enumerates on a PC with nothing but power, the clock and the program image**: no host software after RUN. It then sends reports
on its own (a keyboard that types a fixed message on a timer, or a mouse that traces a pattern). Verified first against our USB host peer model
(`host/usb_host.py`, written from the USB 2.0 text), then on a real PC with the DE0-Nano. Out of scope: full speed, bulk / isochronous (not allowed for low speed),
hubs, certification.

## 2. What must live in the chip

| Block | Content | Words (estimate, to be measured in Phase 2) |
|---|---|---|
| Packet layer | the existing shuttle firmware: SYNC / PID / token parse, CRC16 check of SETUP data, ACK / NAK, retransmission until ACK, address filter, bus-reset detection, turnaround | 209 (built) |
| Control requests | GET_DESCRIPTOR (device, configuration, string, HID report), SET_ADDRESS (with the status stage before the address changes), SET_CONFIGURATION, SET_IDLE, GET_REPORT, SET_PROTOCOL, STALL for everything else | about 60 |
| Descriptors | device (18 B), configuration + interface + HID + endpoint (34 B), report descriptor (about 50 to 63 B), optional strings (about 40 B) = about 150 to 160 B | about 55 `LDI` + 55 transmit words, or 2 words per 3 bytes with a 3-byte transmit command (below) |
| Report generator | a timer (`WAIT` loops, 8 to 10 ms) and a script of key codes / mouse deltas; DATA0 / DATA1 toggle | about 30 |
| Total | | **about 320 to 380 words: does not fit one 256-word engine, fits the shared memory** (one engine 320 to 380, the other 130 to 190) |

**CRC16 of each data packet** is either computed by the CRC unit during the transmit (costs words and clocks) or **precomputed by the assembler** and stored as
constants (costs 2 bytes per 8, 25 % more data words). Decision at Phase 1: precompute, because the descriptors never change after assembly.

**3-byte transmit command (optional, designed on 2026-10-19 and dropped for lack of memory):** queue three bytes from one 24-bit value, halving the descriptor words.
Revive only if the first measurement of Phase 2 exceeds 380 words. It touches the line coder, so it needs its own unit tests and a flow run.

## 3. Descriptor compiler (`host/usb_desc.py`, Phase 1)

Input: a Python description (VID / PID, strings, HID report descriptor bytes). Output: the constant data as assembler macros, CRC16 and PID per 8-byte chunk, the
`wTotalLength` of the configuration, and a table of offsets for the dispatch. Checked against the USB 2.0 and HID 1.11 text with an independent parser
(`usb_host.py` reads the descriptors the way a PC does and rejects inconsistent lengths).

## 4. Phases (each must pass before the next)

| Phase | Work | Tests | Pass criteria |
|---|---|---|---|
| 0 | shared-memory software done; line coder and shuttle firmware as they are | regression green | baseline |
| 1 | `usb_desc.py`, HID keyboard and mouse report descriptors | selftest: parse back every descriptor, lengths and CRCs; compare CRC16 with `usb_ls.py` | descriptors consistent |
| 2 | standalone firmware on the cycle-exact model | `usb_test.py standalone`: reset, 8-byte then full device descriptor, SET_ADDRESS, config, strings, SET_CONFIGURATION, SET_IDLE, report descriptor, then a stream of reports with DATA0 / DATA1 | a PC-style enumeration completes with **no host-side data**; word count measured |
| 3 | the same on the RTL (shared memory, image at its origin) through the bridge | `usb_test.py rtl standalone` | identical transcripts to the model |
| 4 | robustness | host bit rate -1.5 / +1.5 %; jitter; damaged PID; damaged SETUP data; unacknowledged report (resend); wrong address; unknown request (STALL); bus reset in every state; a second enumeration after reset; SET_ADDRESS with a lost ACK | all cases as expected |
| 5 | mutants | wrong PID check, toggle not flipped, address change before the status stage, wrong `wTotalLength`, report not resent, reset ignored, descriptor byte off by one | 100 % caught |
| 6 | FPGA and PC | DE0-Nano with a 1.5 k pull-up on D- (or the pin in open-drain with an external resistor), Linux `lsusb -v`, `dmesg`, `evtest` for the keyboard; Windows if available | the PC lists the device, accepts the configuration, receives the reports |
| 7 | flow check | image placed in the shared memory at the planned origin; no RTL change expected | nothing to rerun unless the 3-byte command is added |

## 5. Test plan against the competitors' way of showing it

What the other entries show: enumeration plus interrupt IN of a boot mouse in simulation. We add: a model host that is independent of the firmware, the timing
checks the USB text requires (turnaround 2 to 7.5 bit times, EOP, reset), host bit-rate tolerance, mutants, and a real PC.

## 6. Risks

| Risk | Mitigation |
|---|---|
| More than 380 words | 3-byte transmit command; drop optional strings; mouse instead of keyboard (smaller report descriptor) |
| A real host's timing differs from the model (recovery times, reset length) | the peer model implements the spec limits at their edges; the FPGA test on a real PC is Phase 6 |
| The pull-up on D- (device detection) | external 1.5 kOhm resistor on the demo board; documented in the board notes |
| Clock below 50 MHz | 26.7 to 33.3 clocks per bit; the period register is fixed-point, see [CLOCK_SPEED_EFFECTS.md](CLOCK_SPEED_EFFECTS.md) |
