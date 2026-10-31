<!---
Datasheet text for the Tiny Tapeout project page.
-->

## How it works

Two identical programmable engines execute a small instruction set (31 opcodes) that reads and writes pins,
counts cycles, shifts bits, and has eight 32-bit registers with an ALU (flags, conditional branches), a programmable
CRC unit (any width 1-32, polynomial, reflection, init, final XOR) and a register-driven wait. UART, SPI, I2C (master and
slave), SMBus PEC, Modbus RTU, 1-Wire, JTAG, CAN 2.0A, USB low speed, WS2812, PS/2 and SWD are firmware, not hardware blocks. Both engines fetch from
one shared 512-word x 32-bit IHP 2-port SRAM macro; each engine may only fetch inside its own window, set by its first instruction (REGION). A pin manager assigns each of the eight protocol pads (`uio[7:0]`) to
an engine, with an optional open-drain mode, and reports ownership violations. The chip is configured and
loaded over a 4-wire SPI management port (frame v1: seven bytes per frame, MSB first, mode 0; a 12-byte frame v2 with CRC-16 and sequence numbers is also accepted, see docs/HOST_INTERFACE.md):

| Pin | Function |
|---|---|
| `ui[0]` | management SCLK |
| `ui[1]` | management MOSI |
| `ui[2]` | management CS_N |
| `uo[0]` | management MISO |
| `ui[3]` HOLD, `ui[4]` trigger in, `ui[5..7]` debug view select | defaults; each can be remapped |
| `uo[1]` IRQ, `uo[2..7]` debug view | defaults; each can be remapped |
| `uio[7:0]` | protocol pads P0..P7 (shared by both engines) |

Frame: byte 0 `0x01` write or `0x02` read, bytes 1-2 address, bytes 3-6 data. MISO returns STATUS first
(`[7]` alive, `[6]` error, `[5:4]` engines running, `[3:2]` TX FIFO full, `[1:0]` RX data available).
Engine *e* (0 or 1) has its registers at `0x1000 * (e + 1)`: `+0x000` control (bit 0 = RUN), `+0x200` TX FIFO, `+0x204` RX FIFO. The shared instruction memory is at `0x0400 + 4*w` (physical word w = 0..511). Pad *p* is configured at `0x0200 + 4*p`.
Full address map and architecture: `src/mgmt.v` and `docs/PROTOCOL_EMULATOR_ARCHITECTURE.md` in the repository.

## How to test

1. Pulse `rst_n` low, clock at up to 50 MHz.
2. Read address `0x0000` (ID, `0x50454D31` = "PEM1") over the management port; STATUS bit 7 must be set.
3. Assign a pad to an engine (write `0x001` to `0x0200 + 4*p`), write the firmware words to the engine's
   instruction memory while RUN = 0, write `1` to the control register, then exchange data through the
   TX/RX FIFOs. Ready-made firmware generators and host scripts are in `host/` (`*_prog.py` builds the instruction words,
   `*_test.py` runs them against a peer model). `test/test.py` runs a small ALU + CRC program (CRC-32 of a message, checked
   against the published check value 0xCBF43926) through the management port.

## External hardware

A host that speaks SPI mode 0 to the management port (for example a microcontroller board), and whatever
UART, SPI, I2C, JTAG, 1-Wire, Modbus or CAN device (with a transceiver where the bus needs one) is wired to the protocol pads.
