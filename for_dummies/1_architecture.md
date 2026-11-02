# 1. The architecture of the Protocol Emulator chip, explained simply

> Based on the repository as of 31 October 2026. The newest chip files (shared memory, logic analyser) are on the branches
> `submit/sh10-50mhz` and `submit/8la-43mhz`. Local `main` (20 October) does not have all of them yet.

## The big idea

Electronic devices talk to each other over wires. The rules for that talk are called a **protocol**. UART (serial port), SPI,
I2C, USB and CAN are all protocols. On the wire, a protocol is just a pattern: the voltage goes high or low at exact moments.

Most chips have one fixed circuit for each protocol. This chip has **none**. Instead it has two tiny processors called
**engines**. An engine can only do simple jobs, but it does them with perfect timing: set a pin high or low, read a pin, wait an
exact number of clock ticks, shift bits in and out. A **program** (the *firmware*) tells the engine which pattern to make. Load a
UART program and the chip is a UART. Load a CAN program and it is a CAN controller. No new chip is needed.

Think of a player piano. The piano is the chip. The paper roll is the firmware. Change the roll and you get a new song.

![The whole system](../docs/images/fig_system_context.svg)

*Figure 1. The chip sits between a host (a PC plus a Raspberry Pi Pico) and the device it talks to.*

## What is inside the chip

![Block diagram](../docs/images/fig_block_diagram.svg)

*Figure 2. The main blocks.*

| Block | What it does | Everyday comparison |
|---|---|---|
| Engine 0 and engine 1 | run firmware, one instruction per clock tick | two musicians |
| Shared program memory | one SRAM of 512 words x 32 bits. Both engines read it at the same time through two separate ports | the book of sheet music |
| Management link | a 4-wire SPI port. The host uses it to load programs, start and stop engines and swap data | the conductor's phone line |
| TX and RX FIFOs | two small queues of 4 words per engine. TX carries data from the host to the engine, RX from the engine to the host | an in-tray and an out-tray |
| Pin manager | decides which engine may drive which pin, can re-route pins, has a safe "open-drain" mode and an emergency HOLD input | a traffic officer |
| Logic analyser (optional) | records what the pins did, so you can view it as a waveform | a dash-cam |

A "word" is 32 bits, which is exactly one instruction.

## Inside one engine

![Programming model of one engine](../docs/images/fig_programming_model.svg)

*Figure 3. The parts of one engine that a program can use.*

Each engine has:

- a **program counter** (which instruction is next) and a **control unit** (reads the instruction and does it);
- **8 registers** R0 to R7, each 32 bits, and an **ALU** with 13 functions (add, subtract, compare, shift and so on);
- an **output shift register (OSR)**: bits leave it one at a time towards a pin;
- an **input shift register (ISR)**: bits from a pin are collected in it;
- a **loop counter** and a **delay counter**;
- a **CRC unit**: it computes the checksum that many protocols add to a message. It can do any CRC standard;
- a **line coder**: it does the special bit encoding that USB needs;
- a **pin block** with 8 "logical" pins.

**The golden rule:** every instruction takes exactly one clock tick. An instruction with a delay `d` takes `d + 1` ticks.
At 50 MHz one tick is 20 ns (20 billionths of a second). There are no interrupts and no caches, so nothing can change the
timing. You can work out the time of every pin change on paper before the program runs. The engine knows 31 instruction types
(opcodes 0 to 30).

## How "emulation" works: an example

To send the letter 'A' over a UART at 115,200 bits per second, each bit must last 8.68 microseconds. At 50 MHz that is 434 ticks.
The UART program does this:

1. Take the next byte from the TX FIFO.
2. Pull the pin low for one bit time (the "start bit").
3. Eight times: put the next data bit on the pin and wait one bit time.
4. Set the pin high for one bit time (the "stop bit"). Go back to step 1.

That is the whole UART transmitter: 12 instructions.

![UART frame](../docs/images/fig_uart_frame.svg)

*Figure 4. The letter 'A' on a UART wire.*

## Transmission path: from the host to the wire

```
 Host (PC + Pico)                         CHIP                                                    Device
   |  1. SPI frame "write TX_DATA"
   +----------> spi_slave --> mgmt --> TX FIFO (4 words)
                                          |  2. PULL: the engine takes one word
                                          v
                                    OSR (32-bit shift register)
                                          |  3. OUT1 d: one bit to the pin, held d+1 ticks
                                          v
                                    pin block --> pin manager --> pad uio[p] -------------------> wire
```

1. The host sends a message that writes a word into the engine's TX FIFO.
2. The firmware runs `PULL`. If the FIFO is empty, the engine simply waits there.
3. `OUT1` sends the bits out one by one, each for an exact number of ticks.
4. The pin manager passes the signal only to a pad that this engine owns.

## Reception path: from the wire to the host

```
 wire --> pad --> synchroniser (2 flip-flops) --> input select --> engine
                                                                    |  WAITL / JPL: wait for the start edge
                                                                    |  IN1 d: read one bit into the ISR
                                                                    v
                                                                   ISR --PUSH--> RX FIFO --> mgmt --> SPI "read RX_DATA" --> host
```

1. The signal from the wire passes a **synchroniser**: two flip-flops that make an outside signal safe to use inside the chip.
   It also means the engine sees a pin 2 ticks late, which the firmware allows for.
2. The firmware waits for the first edge, then reads each bit at the right moment with `IN1`.
3. `PUSH` puts the collected bits into the RX FIFO.
4. The host sees "RX has data" in the status byte (or on the IRQ pin) and reads the word.

## The shared program memory

![Memory windows](../docs/images/fig_memory_windows.svg)

*Figure 5. One memory, two programs, each in its own window.*

Both engines use one 512-word memory. Every program starts with the instruction `REGION`, which states its **window**: the range of
words it may use. If an engine ever tries to read an instruction outside its window, it gets a "trap" word and stops with a
fault flag. The host can write the memory only through a stopped engine's port, and never into a running engine's window.
One shared memory means a big program (for example a USB device) and a small one can sit side by side.

## Pins and safety

![Pin ownership](../docs/images/fig_pin_ownership.svg)

*Figure 6. The pin manager connects logical pins to real pads.*

- 8 two-way pads (`uio[7:0]`) for protocols, plus 5 extra inputs and 7 extra outputs. All of them can be re-routed, except the 4 pins
  of the management link.
- Each pad has an **owner**: nobody, engine 0 or engine 1. Only the owner can drive it. The owner cannot change while that engine runs.
- **Open-drain** mode: the pad can only pull low or let go, never push high. I2C and 1-Wire need this.
- **HOLD** (`ui_in[3]`): when high, both engines stop and every engine pin is released.

These rules are proven with mathematics (formal proofs). Document 2 explains how.

## The management link

The host talks to the chip with SPI (mode 0) on four wires: SCLK, MOSI and CS_N go in, MISO comes out. Each message is a
**frame**: 7 bytes in version 1 (simple), or 12 bytes in version 2. Version 2 adds a CRC-16 check and a sequence number, so a
damaged or repeated message is never carried out twice. The first byte of every reply is **STATUS**: chip alive, error flag,
which engines run, TX FIFO full, RX FIFO has data.

| Address | What is there |
|---|---|
| `0x0000` | ID, always `0x50454D31` ("PEM1") |
| `0x0200`-`0x02FF` | pin manager |
| `0x0300`-`0x03FF` | logic analyser (if built in) |
| `0x0400 + 4*w` | program word `w` (0 to 511) |
| `0x1000` / `0x2000` | engine 0 / engine 1: `+0x000` CTRL (bit 0 = RUN), `+0x00C` START, `+0x200` TX_DATA, `+0x204` RX_DATA |

## The optional logic analyser

It records 16 channels: the 8 pads, the 5 extra inputs, the RUN flag of each engine, and a "marker" line that firmware can raise
with `RPUT TRIG`. It stores each change with a time stamp in a 256-word ring buffer, starts on a trigger you choose, and the host
turns the result into a VCD file for the free viewer GTKWave. The `TSTAMP` instruction lets firmware read the same clock.

## Two versions on the table

The repository has two submission candidates. Both have the same engines, instructions, memory, pins and management link.

| | Candidate A (`submit/sh10-50mhz`) | Candidate B (`submit/8la-43mhz`) |
|---|---|---|
| Logic analyser | not built in | built in (a second 2-port SRAM as its buffer) |
| Layout style | engines in fenced columns | cells placed freely |
| Clock in `info.yaml` | 50 MHz | 43 MHz |
| Worst-case speed reached | 19.71 ns per tick (50.7 MHz) | 22.4 ns per tick (44.6 MHz) |

The repository does not record which one will be submitted. Both use 8 x 4 Tiny Tapeout tiles (1.72 mm x 0.71 mm) and run
the same 13 protocols as firmware, checked in simulation; UART has also run on a real FPGA board.

**Read more:** `docs/CODE_GUIDE.md` (on the submission branches), [../docs/HOST_INTERFACE.md](../docs/HOST_INTERFACE.md),
[../instructions.md](../instructions.md), [../docs/PROTOCOL_EMULATOR_ARCHITECTURE.md](../docs/PROTOCOL_EMULATOR_ARCHITECTURE.md)
(the original target design, partly out of date).
