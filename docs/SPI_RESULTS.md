# SPI Master and Slave — Test Methods and Results

Date: 2026-10-11. Simulation only (Icarus Verilog 12, IHP SRAM functional models, Python 3). No FPGA.
Design: [SPI_PLAN.md](SPI_PLAN.md). Full log of the final run: [../results/spi_2026-10-11/full_run.txt](../results/spi_2026-10-11/full_run.txt).

**Final run: `python host/spi_test.py` -> `RESULT spi_test: PASS (312/312 cases as expected)`, 5 min 23 s.**

> **Re-run 2026-10-12** after the pin manager and `JPO`/`PUSHI`: engine phases 260/260 and chip phase 52/52 (pads 2-5
> now claimed over `0x0200`), every measured limit identical. Workload results through the link with varied host
> behaviour: [WORKLOAD_RESULTS.md](WORKLOAD_RESULTS.md) §4.
Plus the non-UART unit regression (`tb_control_unit`, `tb_fetch_equiv`, `tb_instr_mem`, `tb_pc_reg`, `tb_delay_counter`,
`tb_loop_counter`, `tb_fifo`, `tb_shift_reg`, `tb_pin_block`): 9/9 PASS; `tb_fetch_equiv` 177,995 cycles, 0 mismatches
against the pre-change engine. UART tests were not run (out of scope by request).

All times below are in system clocks (sim clock 10 ns). At 50 MHz, 1 clock = 20 ns.

## 1. Test method

```
 host/spi_prog.py ──> program hex ─┐
 Python data (patterns + random) ──┼──> Icarus: RTL engine / full chip  <──> Verilog peer (master or slave model)
                                   │          │ logs every CS/SCLK/MOSI/MISO change, ISR shift times, FIFO words
                                   └──────────┴──> host/spi_test.py: independent decoder + checks + comparisons
```

| Element | What it is | Why it is independent |
|---|---|---|
| Reference waveform (`ideal_wave`) | Python SPI bus from the mode table | no RTL, no firmware |
| Bus decoder (`decode`) | Rebuilds frames from the pad log using only CPOL/CPHA/bit order | does not know the program |
| Peers (`tb/spi_peer.vh`) | 4-mode master model (half period, CS setup/hold/gap, jitter, abort) and slave model (clock-to-out) | written from the mode table, not from the firmware |
| Engine harness (`tb_spi_engine`) | `engine_top` + host writing/reading the FIFOs directly | isolates firmware + engine |
| Chip harness (`tb_spi_chip`) | `tt_um_protocol_emulator`; program load, RUN, TX, RX only via the 7-byte management frames | proves the real host path |

**Checks in every case**
- Frame count, exactly `2n` SCLK edges per complete frame.
- Decoded MOSI == data sent by the master side; decoded MISO == data sent by the slave side; host RX FIFO data == peer data.
- Bus rules:
  - SCLK idle level at CS fall and CS rise;
  - no SCLK edge while CS is inactive;
  - no data change exactly at a sampling edge;
  - data line driven (not `z`/`x`) at every sampling edge;
  - slave: MISO never driven while CS is inactive.
- Engine fault = 0; at chip level also management `err` = 0 and the idle engine never drives a pin.
- Master role: lead phase, idle phase and CS setup must be **exactly** H+2 / H+3 / H+2 clocks for every bit.
- Slave role: the measured response must stay within limits. Sampling must be 0–4 clocks after the edge and the MISO update ≤ 6 clocks after it. This catches a slave that still delivers correct data with a slow peer but answers a half-period late (found with a mutant, see §7).

**Data:** for n bits: 0, all ones, 0xAA.., 0x55.., walking 1, walking 0, plus 16 random values. Stress runs use random bytes (1024 at engine level, 256 at chip level).

**Case types**
- **PASS cases** must pass.
- **"Expect fail" cases** must be DETECTED: mode mismatch, missing host preload, RX not drained, and broken firmware.
- **Sweeps** are informational. They step one parameter until the first failure and report the limit.

## 2. Implementations

| Change | Files | Size |
|---|---|---|
| Opcodes `JPH p,a` (17), `JPL p,a` (18): jump if synchronized pin high / low | `src/isa.vh`, `src/control_unit.v` | +2 defines, +1 wire, +4 lines |
| Unit tests for JPH/JPL; trap tests moved to opcodes 19/20 | `tb/tb_control_unit.v` | +10 lines |
| Random illegal opcodes drawn from 19..31 (17/18 are legal now; later moved to 21..31 for JPO/PUSHI) | `tb/tb_fetch_equiv.v` | 2 lines |
| SPI firmware generator (8 variants, any bit order, 1-32 bits) | `host/spi_prog.py` | new |
| Runner, reference waveform, decoder, checks, sweeps, mutants | `host/spi_test.py` | new |
| Verilog peers + pad logger | `tb/spi_peer.vh` | new |
| Engine-level and chip-level harnesses | `tb/tb_spi_engine.v`, `tb/tb_spi_chip.v` | new |
| Docs | `docs/SPI_PLAN.md`, this file, `instructions.md` §3 + opcode table, ISA rows in the architecture doc, `EXECUTION_PLAN.md` A5/R12/F3/F8, `README.md`, `memory.md` | edits |

Untouched: `src/fpga/`, `quartus/`, every UART file, `engine_top`, `mgmt`, `spi_slave`, `tt_um_protocol_emulator`, and the other
RTL modules.

Program sizes (64-word memory):

| | CPHA=0 | CPHA=1 |
|---|---|---|
| Master | 17 words | 18 words |
| Slave | 18 words | 16 words |

## 3. Phase 0: ISA change

| Test | Result |
|---|---|
| `tb_control_unit`: JPH taken when pin high, falls through when low (other pins high); JPL taken when low (other pins high), falls through when high; 1 cycle | PASS |
| Opcodes 19, 20, 31 still trap; 9-tb non-UART unit regression | 9/9 PASS |
| `tb_fetch_equiv` new engine vs pre-change engine, random programs | 177,995 cycles, 0 mismatches |
| Mutations: pin field `[2:0]` instead of `[8:6]`; polarity inverted; `OP_LAST_LEGAL` back to 16; never advance | all 4 caught (4, 4, 8, 2 errors) |

## 4. Phase 1: decoder self-test (55 cases, all as expected)

- **Ideal waveform round trip:** all 4 modes × MSB/LSB × 1, 7, 8, 16 and 32 bits. 40/40 PASS; MOSI and MISO were rebuilt exactly.
- **Wrong-mode decode:** each mode decoded as each of the other 3 modes. 12/12 DETECTED.
- **Injected faults:** an SCLK pulse while CS is inactive, the wrong SCLK idle level, and MISO undriven inside a frame. 3/3 DETECTED.

## 5. Phase 2: peers against each other (48 cases, all as expected)

- **Basic matrix:** the master model against the slave model in all 4 modes × MSB/LSB × 1, 7, 8, 16 and 32 bits. 40/40 PASS.
- **Timing stress:** ±30 ns jitter on every half period, with slave clock-to-out of 40 ns. 4/4 PASS.
- **Wrong-mode decode:** the peers run in mode X and are decoded as mode Y. 4/4 DETECTED.

## 6. Phase 3: engine as master (68 counted cases + sweeps)

| Group | Cases | Result |
|---|---|---|
| 4 modes x MSB/LSB x 1/7/8/16/32 bits, H=4 | 40 | 40 PASS, timing exact |
| H = 0, 1, 2 (SCLK = clk/5, /7, /9) per mode | 12 | 12 PASS |
| Host feeds late (3 us) and drains RX late (20 us): engine parks with CS high, SCLK idle | 4 | 4 PASS (no data loss, no bus violation) |
| 1024 random bytes, H=1 (clk/7), per mode | 4 | 4 PASS |
| Slave model in the other CPHA / other CPOL | 8 | 8 DETECTED |

**Measured master timing (all modes, all cases)**
- **SCLK phases:** the lead phase is H+2 clocks, the idle phase is H+3, and CS fall to the first edge is H+2.
- **MOSI setup** before the sampling edge is H+1 clocks.
- **MOSI hold** after the sampling edge is H+4 clocks for CPHA=0 and H+4 or more for CPHA=1.
- **CS hold** after the last edge is 2 clocks for CPHA=0 and H+3 for CPHA=1.
- **Master sampling point:** the master samples MISO 1 clock *before* its own sampling edge, because of the 2-flop synchronizer.

**Slave clock-to-out sweep**

| H | Passes up to | First fail | Rule |
|---|---|---|---|
| 0 | 0 ns | 10 ns | clock-to-out < (H+1) clocks |
| 4 | 40 ns | 50 ns | clock-to-out < (H+1) clocks |

- The limit is the same in all 4 modes and matches the cycle arithmetic. The tightest bit is the first one, whose CS-to-edge time is H+2 clocks.
- A real slave's clock-to-out plus the pad and board delays must fit within H+1 clocks. H=0 works only with an ideal (zero-delay) slave.

## 7. Phase 4: engine as slave (68 counted cases + sweeps)

| Group | Cases | Result |
|---|---|---|
| 4 modes x MSB/LSB x 1/7/8/16/32 bits, half = 10 clk | 40 | 40 PASS |
| CS pulse with no clocks (frame 5) — `JPH` abort path | 4 | 4 PASS |
| CS aborted after 3 of 8 bits (frame 5) — `JPH` abort path | 4 | 4 PASS (aborted frame: no RX word, its TX word consumed; all later frames correct) |
| Jitter +-20 ns, half = 10 clk | 4 | 4 PASS |
| 1024 random bytes, half = 6 clk | 4 | 4 PASS |
| Master model in the other CPHA | 4 | 4 DETECTED |
| Host does not preload TX (first 4 us) | 4 | 4 DETECTED (MISO undriven during the missed frames) |
| Host stops draining RX | 4 | 4 DETECTED (frames lost after the 4-deep FIFO + blocked PUSH) |

**Measured slave limits (sweeps, 24 frames each, decreasing until the first failure)**

| Mode | Min SCLK half period | Min CS fall → first edge | Min CS inactive |
|---|---|---|---|
| 0 (CPHA=0) | 4 clk (3 fails) | 6 clk (5 fails) | 4 clk (3 fails) |
| 1 (CPHA=1) | 5 clk (4 fails) | 1 clk (sweep floor) | 4 clk (3 fails) |
| 2 (CPHA=0) | 4 clk | 6 clk | 4 clk |
| 3 (CPHA=1) | 5 clk | 1 clk | 4 clk |

- At 50 MHz this gives a maximum SCLK of 6.25 MHz for CPHA=0 and 5 MHz for CPHA=1, with zero margin.
- The 1024-byte stress used a half-period of 6 clocks (4.2 MHz at 50 MHz).

**Slave response, measured**
- **MOSI sampling:** taken from the pad 1–3 clocks after the sampling edge, so the master must hold MOSI that long.
- **MISO update:** 3–5 clocks after the shift edge.
- **First bit (CPHA=0):** driven 4–5 clocks after CS falls.
- **MISO release:** 3 clocks after CS rises.

## 8. Phase 5: full chip through the management link (52 counted cases + sweep)

The management SPI link runs at a 10-clock half-period. A program load is 65 frames.

| Group | Cases | Result |
|---|---|---|
| Master on engine 0: 4 modes x {8b MSB, 8b LSB, 16b MSB, 32b LSB}, H=4 | 16 | 16 PASS |
| Slave on engine 1: same matrix, 40 us between CS frames | 16 | 16 PASS |
| Roles swapped: master on engine 1, slave on engine 0, per mode | 8 | 8 PASS |
| 256 random bytes: master on engine 0, H=1 | 4 | 4 PASS (578 management frames, 0 TX retries) |
| 256 random bytes: slave on engine 1, half = 6 clk | 4 | 4 PASS (~992 management frames, ~402 TX retries handled by STATUS flow control) |
| Slave with master model in a different mode | 4 | 4 DETECTED |

- **Every chip case:** management `err` = 0, engine fault = 0, and the idle engine drove no pin.
- **Measured timing:** identical to engine level, apart from the 1 ns pad delay the chip testbench adds (§10).

**Sustained slave rate through the host link (CS frame spacing sweep, modes 0 and 3)**

| CS frame spacing | Result |
|---|---|
| 40, 30, 25 µs | pass |
| 20 µs | fail: the host cannot preload in time, and MISO is undriven in the missed frames |

- Each slave frame needs one management WRITE and one management READ, about 11.4 µs each at this link speed.
- So the sustained slave rate is set by the management link, not by the engine.
- A master never loses data. It simply pauses with CS high.

## 9. Mutants: broken firmware must be caught (21 cases, all DETECTED)

| Mutation | Cases | Caught by |
|---|---|---|
| Slave without CS checks (`JPH CS` removed), CS abort after 3 bits / CS pulse without clocks | 8 | data misalignment after the abort |
| Slave SCLK waits inverted (answers a half period late) | 4 | slave response-time check (sample 11-51 clk after the edge) |
| Master programmed with the wrong CPHA | 4 | data + exact timing |
| Slave programmed with the wrong CPOL | 4 | response-time check / data |
| Master bit order flipped | 1 | data |

With the CS checks removed, normal traffic still passes. So the abort tests are what prove JPH/JPL is required and works.

## 10. Issues found and fixed during the work

1. **CPHA=0 slave, firmware.** The first version waited for one more trailing edge after its last sample. If CS rose right at that edge, the CS check would discard a complete frame. The slave now ends at its last sample (+1 word).
2. **Decoder.** It counted the reset X→0 transition as an SCLK edge. Only 0↔1 changes count now.
3. **Master model.** In CPHA=0, "CS setup" did not include the first half period, so the CS-setup sweep never stressed it. CS setup now means CS fall to first edge in every mode.
4. **Sweeps.** CS and SCLK changing in the same nanosecond broke them. The sweeps now stop at 10 ns, since a real master never does that.
5. **Chip testbench.** The `uio_out` mux makes a zero-width pulse in zero-delay simulation when a pin is enabled. The slave model counted it as a CS fall. A 1 ns inertial delay on the testbench pads fixes it; this is the same lesson as the UART work in memory.md.
6. **Coverage gap.** The inverted-SCLK mutant passed all data checks with a slow peer. The slave response time is now a checked limit.

## 11. Limits and what is not covered

- Simulation is zero-delay RTL. Real pad and board delays, and synchronizer metastability, are not modelled. Limits are in clocks; margins are needed on silicon.
- No loopback (engine 0 master ↔ engine 1 slave on shared pads). It was deferred by decision.
- Frames are 1–32 bits per CS. Longer transactions are not supported yet.
- The slave cannot detect a CS pulse shorter than about 2–3 clocks: the synchronizer plus the poll may miss it. This was not swept below the 10 ns floor.
- I2C, JTAG and UART were not touched or re-run.
