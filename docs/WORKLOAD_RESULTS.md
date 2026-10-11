# Workload Campaign Through the Host Link — UART, SPI, I2C — Methods and Results

Date: 2026-10-12. Simulation only (Icarus Verilog 12, IHP SRAM functional models, Python 3.14). No FPGA.
Runner: [`host/workload.py`](../host/workload.py). Logs: [`../results/workload_2026-10-12/`](../results/workload_2026-10-12/).

**Results: UART 13/13, SPI + I2C + concurrent 42/42 cases as expected; open-loop UART RX limits measured (§3.4):
at the fastest link the host drains a line-rate UART stream up to a 109-clock bit (460800 in the suite's scale).**
Before the campaign, the existing chip-level suites were re-run on the final RTL (pin manager + new opcodes):
`run_tests.ps1` 19/19, `mgmt_duplex_stress.py` (UART 1 KB full duplex, 8 cases incl. negative) ALL PASS,
`spi_test.py chip` 52/52, `i2c_test.py` 60/60.

## 1. What "through the host link" means here

Every byte goes through the chip exactly as a real host would drive it: 7-byte frames on the management SPI pins
(`ui_in[2:0]`, `uo_out[0]`). The host model in each chip testbench:

1. claims the protocol pads in the pin manager (`0x0200+4p`, push-pull or open-drain),
2. loads the programs (`base+0x100+4i`) and sets RUN (`base+0x000`),
3. writes TX words to `base+0x200` — accepted only if that frame's STATUS showed room, otherwise retried,
4. reads RX words from `base+0x204` — valid (and popped) only if that frame's STATUS showed data.

Nothing is poked into the chip from the testbench. The protocol peers on the pads are independent models (UART echo
peer / waveform replay, SPI master/slave models, I2C slave models on a wired-AND bus).

## 2. Host behaviours (`tb/host_knobs.vh`)

| Name | What the host does | What it stresses |
|---|---|---|
| interleaved | read when the last STATUS showed RX data, else write the next word | the normal case |
| burst | write until a write is refused (TX full), then read until a read comes back empty | full/empty boundaries of both FIFOs |
| aborts/5 | before every 5th frame, a truncated frame (1–6 bytes) aimed at TX_DATA (write) or RX_DATA (read) | commit-only-on-complete-frame; no duplicate push, no lost pop. Sets the sticky `err` (expected) |
| noise/3 | before every 3rd frame, a full READ of CTRL or of the pin-violation register | reads with no side effects interleaved with data traffic |
| slow host | 5 us idle before every frame | protocol behaviour when the host cannot keep up |
| all | all of the above together | everything at once |

Each case is checked by the protocol's independent decoder plus a byte-for-byte comparison with what the host and the
peers sent: UART reference receiver (`uart_workload.decode`, every TX frame also cycle-exact), SPI bus decoder
(`spi_test.decode`), I2C bus decoder with UM10204 timing (`i2c_test.decode`).

## 3. UART (TX = engine 0 / P0, RX = engine 1 / P1)

Bit = 434 clocks of the 10 ns simulation clock (the "115200" programs of the UART suite).

### 3.1 Every host behaviour, full duplex with a live echo peer (256 bytes each)

| Host | TX decoded | Echo | RX read back | TX frames cycle-exact | TX retries | Mgmt frames | Aborts / noise | Result |
|---|---|---|---|---|---|---|---|---|
| interleaved | 256 | 256 | 256 | 256 | 690 | 1356 | 0 / 0 | PASS |
| burst | 256 | 256 | 256 | 256 | 345 | 1356 | 0 / 0 | PASS |
| aborts/5 | 256 | 256 | 256 | 256 | 579 | 1243 | 248 / 0 | PASS |
| noise/3 | 256 | 256 | 256 | 256 | 391 | 1050 | 0 / 350 | PASS |
| slow host | 256 | 256 | 256 | 256 | 268 | 924 | 0 / 0 | PASS |
| all | 256 | 256 | 256 | 256 | 50 | 749 | 149 / 249 | PASS |

### 3.2 TX only, RX only

| Case | Result |
|---|---|
| TX only 256 B, interleaved (939 refused writes absorbed by retry) | PASS, 256/256 cycle-exact |
| TX only 256 B, host all | PASS |
| TX only 64 B, host waits 100 us per frame (line idles between bytes) | PASS, frames still cycle-exact |
| RX only 256 B back-to-back from the line (host only reads) | PASS 256/256 |
| RX only 256 B, host all | PASS 256/256 |
| RX bytes with 0–3 idle bits between them | PASS 64/64 |

### 3.3 Corner cases and limits (closed loop and robustness)

| Case | Outcome | Meaning |
|---|---|---|
| Line break (30 bit times low) between bytes | one `0x00` byte, then clean resync (17/17 as predicted) | no framing check: a break reads as 0x00 |
| **1 us glitch on an idle line** | **one spurious extra byte** (17 bytes for 16 sent) | **limitation:** the 9-word RX program starts on any low level and does not re-check the start bit at mid-bit. Fix candidate: `JPH` re-check half a bit after the edge (~2 words) |
| Peer baud error −4 %, −5 %, +4 % | all bytes correct | |
| Peer baud error −6 %, +6 %, +8 % | **every byte read back wrong** (the echo line itself decodes correctly) | RX sampling drifts out of the bit; usable window about −5 % … +4 % (earlier estimate −4.5 % / +6 %) |
| Management half period 8 … 32 clocks, full duplex | all pass | closed loop: the echo peer only answers what TX sent, so a slower link slows everything down without loss |
| Host stops servicing for 12 byte times while the peer keeps sending | **loss detected** (255 of 256) | negative case: RX FIFO overflow is visible to the checker |
| Full-duplex baud sweep at the fastest link: 230400 / 460800 / 921600 / 1.5 M (bit 217 / 109 / 54 / 33 clocks) | all pass, cycle-exact | firmware works down to a 33-clock bit; the closed loop paces itself |

### 3.4 Open-loop RX limits (peer streams at line rate, host only reads)

The full-duplex echo above is closed loop (the peer only answers what TX sent), so it never shows a link limit. Here
the peer streams back-to-back bytes into RX regardless of the host; the host only reads (one READ frame per byte).

| Sweep | Passes | First failure | Rule it confirms |
|---|---|---|---|
| Management half period at the 434-clock bit (128 B) | 8, 16, 24, **32** clocks | 40 clocks: 126/128 bytes (2 lost) | one 56-bit READ frame (~36 us at 32 clocks, ~45 us at 40) must fit in one byte time (43.4 us) |
| Baud rate at the fastest link (8-clock half period, ~9.1 us per frame), 96 B | 230400 (217-clk bit), **460800 (109-clk bit)** | 921600 (54-clk bit): 60/96 bytes | byte time 10.9 us > 9.1 us passes, 5.4 us < 9.1 us loses bytes |

Loss is never silent: the checker sees every missing byte. The RX FIFO (4 words) only absorbs short bursts.

## 4. SPI (master = engine 0 on pads 2–5, slave = engine 1)

### 4.1 Every host behaviour

| Host | Master mode 0, 8-bit (36 frames) | Slave mode 3, 8-bit |
|---|---|---|
| interleaved | PASS (142 mgmt frames, 1.6 ms) | PASS, CS every 40 us (49 TX retries) |
| burst | PASS | PASS, CS every 40 us |
| aborts/5 | PASS (28 aborted frames) | PASS, CS every 40 us (38 aborted frames) |
| noise/3 | PASS (47 noise reads) | PASS, CS every 40 us |
| slow host | PASS | PASS, CS every **100** us |
| all | PASS | PASS, CS every **100** us |

All modes with the host doing everything at once: master modes 0–3 with **32-bit LSB-first** frames, slave modes 0–3
with 16-bit frames (CS every 100 us): **8/8 PASS**. Master mode 2, 512 random bytes at H=1 (SCLK = clk/7), host all:
PASS (1206 frames, 241 aborts, 402 noise reads).

### 4.2 Slave sustained-rate limit versus host behaviour (40 frames, management half period 10 clocks)

| Host | Smallest CS frame spacing without loss | First failure |
|---|---|---|
| interleaved | 25 us | 20 us |
| burst | 25 us | 20 us |
| all | 50 us | 40 us |

A slave cannot pause its master, so it needs one TX word preloaded and one RX word drained per CS frame: about two
management frames of ~11 us. Burst does not help (the FIFO is only 4 deep and the work per frame is the same).
Negative: CS frames 10 us apart → loss **detected** (MISO undriven in missed frames). The SPI **master** never loses data:
with a slow host it simply pauses with CS high.

## 5. I2C master (engine 0 unless noted, pads 6/7 open-drain)

| Case | Result |
|---|---|
| Basic set at 400 kHz (writes, write → Sr → read, absent address, ...) with each host behaviour: interleaved, burst, aborts/5, noise/3, slow, all | 6/6 PASS, UM10204 timing met in every run |
| 1 MHz, engine 1, data NACK mid-write (queued words dropped), host all | PASS |
| Absent address between valid transactions, host all | PASS |
| 100 kHz, slave stretches every bit 3 us, host all | PASS |
| Two slaves, repeated-START chains, host all | PASS |
| 1 MHz random stress, 405 words, host all (193 aborts, 322 noise reads) | PASS |
| Throughput, 1 MHz bus, fastest link (8-clock half period) | 151 bytes in 6.8 ms incl. ~1.2 ms setup: **about 27 kB/s** (link-bound, ~2 frames per byte) |

With a slow host the master holds SCL low between bytes (legal); no case lost or duplicated a byte.

## 6. SPI master and I2C master at the same time (`tb/tb_combo_chip.v`)

Engine 0 runs SPI master on pads 2–5, engine 1 runs the I2C master on pads 6/7 (open-drain); one host services both
engines round-robin over the same management link. Both buses are decoded independently.

| Case | Result |
|---|---|
| SPI mode 0 + I2C 400 kHz with each host behaviour (6 runs) | 6/6 PASS |
| SPI mode 3, 32-bit LSB, H=1 + I2C 1 MHz, host all | PASS |
| SPI mode 1 + I2C 100 kHz with the slave stretching after every byte, host all | PASS |

Pin-manager violation bits stayed 0 and neither engine faulted: the engines are isolated in pins and FIFOs.

## 7. Findings

| # | Finding | Severity | Status |
|---|---|---|---|
| 1 | UART RX takes a short glitch as a start bit (spurious byte) | functional limitation | open; fix candidate with `JPH` (~2 words) |
| 2 | UART RX has no framing check; a break reads as 0x00 | limitation | documented |
| 3 | UART RX peer-baud window about −5 % … +4 % | limit | documented |
| 4 | SPI slave and UART RX throughput is bounded by the management link, not the engine (SPI slave: 25 us per frame at a 10-clock half period) | limit | documented; frame v2 / packing would raise it |
| 5 | Aborted management frames never pushed or popped anything in any run (thousands injected) | robustness | confirmed |
| 6 | Interleaved register reads never disturbed traffic | robustness | confirmed |
| 7 | Closed-loop traffic (echo) is self-pacing: a slow link causes no loss | behaviour | documented |
| 8 | Two protocols run concurrently without interference | isolation | confirmed |

## 8. Tools

| Tool | Use |
|---|---|
| Icarus Verilog 12 (`iverilog`, `vvp`) | RTL simulation, all testbenches |
| IHP SRAM functional models (`sim/ihp_sram`) | instruction memory in simulation |
| Python 3.14 (miniconda) | generators, reference models, decoders, runners |
| Testbench peers | `tb/spi_peer.vh`, `tb/i2c_slave_model.v`, UART echo / replay in `tb_mgmt_duplex.v` |
| Host knobs | `tb/host_knobs.vh` |
| Yosys + IHP CMOS5L liberty (OSS CAD Suite) | area after each RTL change |
