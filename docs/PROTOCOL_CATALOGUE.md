# How many protocols can this chip pull off

Written 2026-10-20. Sources: our own results (sections 1), the engine's published limits (one instruction per clock, pins sampled 2 clocks late, 4-word FIFOs, 8 pins),
the line coder (NRZI, stuffing, fixed-point bit period), the standards named in each row, and a web search whose results were thin (the only precedents found: DShot bit-banged on an
AVR, 10BASE-T transmit bit-banged on an AVR at 20 MHz, DMX512 as a UART). **Everything outside section 1 is an estimate until a peer model and a test exist.**

## 1. Done and verified against independent peer models (13, plus variants)

| Protocol | Notes |
|---|---|
| UART | TX, RX, full duplex; tolerance -4.5 / +6 % |
| SPI | master and slave, modes 0 to 3 |
| I2C | master 100 / 400 / 1000 kHz, slave; SMBus PEC |
| Modbus RTU | CRC-16 |
| 1-Wire | master |
| JTAG | TAP master, IDCODE, random walks |
| SWD | ADIv5 host (DP, MEM-AP) |
| CAN 2.0A | transmit and receive; no arbitration or error frames |
| USB low speed | device, packet shuttle with host-supplied descriptors (standalone: [USB_STANDALONE_PLAN.md](USB_STANDALONE_PLAN.md)) |
| WS2812 | LED strip |
| PS/2 | device link layer, host to device and back |

## 2. Firmware only, no hardware change (estimated 20 more)

Rates are well inside one instruction per clock. Each needs a peer model written from the standard and the usual mutants (about 1 to 3 days each once the template exists).

| Protocol | Rate / timing | Clocks per bit at 50 MHz | Note |
|---|---|---|---|
| MIDI | 31.25 kbit/s UART, current loop outside | 1600 | UART firmware with another divisor |
| DMX512 | 250 kbit/s, 2 stop bits, 88 us break | 200 | RS-485 driver external; sources describe it as UART-based |
| LIN | 19.2 kbit/s UART with break and sync, checksum | 2600 | master and slave frames |
| SBUS / DSM style RC | 100 kbit/s 8E2 inverted | 500 | inverted UART |
| Modbus ASCII | UART with LRC | 5200 | |
| DShot 150 / 300 / 600 | 6.67 / 3.33 / 1.67 us per bit, 16-bit packet, CRC4 | 333 / 167 / 83 | bit-banged on an AVR in the wild; ours is comfortable |
| IR remote (NEC, RC5, Sony) | 38 kHz carrier, ms-scale timing | hundreds | carrier by timed toggling |
| Wiegand | two-wire pulses, ms scale | huge | receive |
| I2S | clocked serial with word select; 1 to 3 MHz bit clock | 16 to 50 | master TX / RX |
| MDIO / MDC | 2.5 MHz | 20 | Ethernet PHY management |
| HD44780 / parallel LCD | 4-bit bus, microsecond waits | large | |
| SPI display / flash / SD card in SPI mode / ADC | SPI master with a command layer | 8 to 20 | uses the SPI master; layers above SPI |
| APA102 / SK9822 / WS2811 | SPI-like or timed LED strips | 8 to 60 | |
| SENT (J2716) | 3 us tick | 150 | receive |
| DHT22 / DS18B20 | one-wire timing, tens of us | large | |
| Servo PWM / PPM | ms scale | huge | |
| Dallas / iButton | 1-Wire family | | |
| I3C (SDR, up to about 3 MHz) | push-pull after the address phase | 16 | no hot-join or in-band interrupts |
| QSPI flash read | 4 data pins, single edge | 8 | needs 4 free pins; the chip has 8 |
| Manchester / biphase generic | 1 to 2 Mbit/s | 25 to 50 | cell-based, plus SWO as a UART |

Count: **about 20 further protocols with firmware only**, which makes **30 to 35 in total** (counting variants as one protocol each, UART-family and SPI-family members separately).

## 3. Needs a small hardware addition

| Protocol | Addition | Where |
|---|---|---|
| 10BASE-T Ethernet, transmit | none for pre-built frames; Manchester mode in the line coder for generated frames; **40 MHz clock** | [ETHERNET_FEASIBILITY.md](ETHERNET_FEASIBILITY.md) |
| 10BASE-T receive | Manchester receiver with a DPLL | same page, research item |
| CAN with arbitration, error frames and resynchronisation | a bit-level watcher in firmware, probably hardware-assisted edge timestamps | needs the timestamp counter of the logic analyser plan |
| S/PDIF (about 6 Mbit/s biphase) | Manchester-style mode | 8 clocks per symbol at 50 MHz |

## 4. Not feasible at this clock

| Protocol | Why |
|---|---|
| USB full speed (12 Mbit/s) | 4.2 clocks per bit at 50 MHz, below the receiver's needs; no line driver for it |
| 100BASE-TX, gigabit | rates and signalling far beyond the clock |
| SDIO 4-bit, eMMC, SD UHS | tens of MHz parallel buses |
| CAN FD data phase (2 to 8 Mbit/s) | 6 to 25 clocks per bit with a hardware CRC engine requirement |
| Anything above about one quarter of the clock as a bit rate | the engine does one decision per clock |

## 5. What the engine is not good at (so the claim stays honest)

- sustained data streams: the management link moves about one 32-bit word per frame (27 kB/s measured), the FIFOs are 4 words deep;
- protocols needing timeouts built in (a stuck bus leaves the engine waiting until the host toggles RUN);
- analog levels and electrical compliance: the pads are 3.3 V CMOS, external drivers are needed for RS-485, CAN, 10BASE-T and USB.

## 6. Recommendation

Count what is verified, not what is possible: today 13. Add the cheapest dozen of section 2 as one batch (UART-family: MIDI, DMX512, LIN, SBUS, Modbus ASCII, DShot, IR; then I2S, MDIO, SPI flash / display / SD) because
each reuses a verified template, and use the extra count as part of the pitch for a general-purpose emulator. Keep Ethernet as a clearly labelled stretch.
