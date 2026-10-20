# 10 Mbit Ethernet (10BASE-T): feasibility on this chip

Written 2026-10-20 (the challenge lists "low-speed USB and 10Mbit Ethernet" as stretch goals). Conclusion first: **transmit is feasible, with no new hardware for pre-built
frames and a small line-coder addition for generated frames, but only at a clock where a Manchester half bit is a whole number of clocks (40 MHz). Receive is the hard part
and is a research item.** The earlier note "raw 10BASE-T is not feasible on GPIO at this clock" (CHALLENGE_CHECK.md) was about 50 MHz and about receive.

## 1. What 10BASE-T needs

| Item | Requirement | Source |
|---|---|---|
| Line code | Manchester, 10 Mbit/s: bit time 100 ns, always a mid-bit transition, direction = value | IEEE 802.3 clause 7 |
| Pair | one differential pair each way (TD+/TD-, RD+/RD-) through a 1:1 isolation transformer (magnetics, RJ45) | clause 14 |
| Idle and link | idle = TP_IDL; a normal link pulse (100 ns) every 16 ms (8 to 24 ms) to show a link | clause 14.2 |
| Frame | preamble 7 x 0x55, SFD 0xD5, destination, source, type / length, payload 46 to 1500, FCS = CRC-32 | clause 3 |
| Gap | at least 9.6 us between frames | clause 4 |
| TX jitter | a few ns | clause 14.3 (to be read before Phase 1) |
| RX | must decode with jitter of the order of 18 ns (a hardware Manchester decoder's rating, DP8391A data sheet) | datasheet |

## 2. Timing against our clock

| Clock | Clocks per bit | Clocks per half bit | Verdict |
|---|---|---|---|
| 50 MHz | 5 | **2.5** | half bits alternate 2 and 3 clocks: 10 ns pattern jitter, too much for a clean transmitter |
| 46.6 MHz | 4.66 | 2.33 | worse |
| **40 MHz** | **4** | **2** | exact |
| 20 MHz | 2 | 1 | exact but no room for instructions |

So the chip must be run at 40 MHz (or 80) for Ethernet. That fits the recommended operating clock in [CLOCK_SPEED_EFFECTS.md](CLOCK_SPEED_EFFECTS.md).

## 3. Transmit

The instruction `OUT1 d` writes one OSR bit to the output pin and holds for `d` more clocks (d+1 in total). At 40 MHz `OUT1 1` is **one half-bit symbol every 2 clocks**,
so a run of pre-expanded symbols goes out as `OUT1 1`, one symbol per 2 clocks. `OUT1 0` followed by one other single-clock instruction (`LDI`, `RPUT`, `ALU`, `CRC`) is also exactly one symbol time,
which is where the work for the next 24 symbols is done without disturbing the waveform. Frames can therefore be sent with **firmware only**:

- **Pre-built frames** (ARP announcement, a UDP broadcast with a fixed payload): the assembler expands bytes into symbols and computes the FCS at build time; the frame is kept
  as `LDI` constants (24 bits = 24 symbols = 12 data bits per `LDI`, plus one `RPUT OSR`): about 1.3 words per byte of frame, i.e. a 64-byte frame is about 85 words, plus a short send loop. Fits the shared memory.
- **Generated frames** (a counter in the payload, a changing field): the engine must produce one byte per 32 clocks (8 bits x 4). The SPI management link cannot feed that (FIFO depth is
  4 words), so bytes come from registers and the ALU. Doing it in pure firmware leaves the CRC and the symbol expansion competing for the same 32 slots; a **Manchester mode in the
  line coder** (byte in, symbols out, preamble / SFD / FCS inserted from the CRC unit) removes that pressure. Estimated cost: about 100 cells, one `LINE` configuration bit, a model and
  unit tests, a flow run.
- **Link pulses:** one 100 ns pulse (4 clocks) every 16 ms: a `WAIT` loop. The 16 ms (640,000 clocks at 40 MHz) fits the 27-bit `WAIT`.

Electrical: a GPIO pair through series resistors and a transformer is the usual low-cost way and works with most switches in practice; it is not a compliant transmitter (pad drive
and the template are outside what simulation shows). The Tiny Tapeout pads drive 3.3 V.

## 4. Receive

Receive needs clock recovery from the data: at 4 clocks per bit the sampling resolution is 25 % of a bit, against a jitter allowance of about 18 % (18 ns of 100 ns). A firmware loop
cannot track edges at that rate. Options:

1. a **Manchester receiver in the line coder** (edge detector, DPLL with a 4x oversampled clock, preamble lock, SFD search): about 400 cells and one to two weeks including a peer model with jitter;
2. an external comparator + decoder (not within the spirit of the challenge);
3. leave receive out (a transmit-only Ethernet "talker": announces itself, sends sensor frames).

Receive is not needed to demonstrate 10BASE-T transmit, so it comes last and only if time remains.

## 5. Verification plan

| Phase | Work | Pass criteria |
|---|---|---|
| E1 | `host/eth10.py` from the standard's text: Manchester encoder / decoder, FCS, frame builder, link-pulse checker, IFG check, pcap writer | selftest against known vectors (CRC-32 of "123456789", an ARP frame decoded by tcpdump) |
| E2 | firmware: link pulses + pre-built frame at 40 MHz on the cycle-exact model | decoded frame equals the intended bytes, FCS good, every half bit exactly 2 clocks, IFG >= 9.6 us |
| E3 | the same on the RTL | identical waveform |
| E4 | mutants (wrong symbol order, FCS off by one, preamble length, pulse spacing) | 100 % caught |
| E5 | line-coder Manchester mode (only if generated frames are wanted) | unit tests + differential test + flow run |
| E6 | hardware: DE0-Nano, transformer + RJ45, a laptop NIC | link LED / `ethtool` carrier, `tcpdump` sees the frames, correct FCS |

## 6. Recommendation

Put Ethernet **after** the logic analyser as a stretch item for weeks 8 to 9, transmit only: E1 to E4 need no RTL change and cost about a week. It requires the 40 MHz clock, which is
a documentation decision, not a design change. Receive and the Manchester line-coder mode stay as options. Do not promise 10BASE-T until E2 passes.
