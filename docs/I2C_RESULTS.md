# I2C Master, Pin Manager and ISA Additions — Test Methods and Results

Date: 2026-10-11/12. Simulation only (Icarus Verilog 12, IHP SRAM functional models, Python 3.14). No FPGA.
Plan and design: [I2C_PLAN.md](I2C_PLAN.md). Full log of the final run:
[../results/i2c_2026-10-11/full_run.txt](../results/i2c_2026-10-11/full_run.txt).

**Final run: `python host/i2c_test.py` -> `RESULT i2c_test: PASS (60/60 cases as expected)`, 2 min.**
Plus `run_tests.ps1` 19/19 PASS (incl. the new `tb_engine_ops`, `tb_pin_mgr`, `tb_mgmt_pins` and the chip-level
`tb_mgmt_*` testbenches updated for pad claims).

The I2C testbenches run at **50 MHz (20 ns clock)**, so every timing check is in real nanoseconds.

## 1. What was built

| Item | Files | Size |
|---|---|---|
| `JPO a` (19): jump if the next OSR bit is 1, consume it | `src/isa.vh`, `src/control_unit.v` | 5 lines |
| `PUSHI v` (20): push a 27-bit immediate into the RX FIFO, ISR untouched | `src/control_unit.v`, `src/engine_top.v` | 6 lines + 1 mux |
| Pin manager: owner per pad, claim refused while the owner runs, per-pad open-drain, sticky violations | `src/pin_mgr.v` (new), `src/mgmt.v` (window `0x0200`), `src/tt_um_protocol_emulator.v` | 50 lines; 3,680 um^2 |
| I2C master firmware generator (46 words, 100/400/1000 kHz, any f_clk) | `host/i2c_prog.py` | new |
| Runner: model, decoder, UM10204 checks, phases | `host/i2c_test.py` | new |
| I2C slave model (spec-based, EEPROM pointer, stretch, tVD, forced NACK) | `tb/i2c_slave_model.v` | new |
| Engine harness (engine + real `pin_mgr` + wired-AND bus with rise time + Verilog master model) | `tb/tb_i2c_engine.v` | new |
| Full-chip harness (management link only) | `tb/tb_i2c_chip.v` | new |
| Unit tests | `tb/tb_engine_ops.v`, `tb/tb_pin_mgr.v`, `tb/tb_mgmt_pins.v` | new |

Nothing in the engine knows about I2C: open-drain is a pad property, framing is firmware, decisions are in the host.

## 2. Test method

```
 i2c_prog.py ─> program ─┐                ┌── i2c_slave_model x2 (0x50, 0x23) on a wired-AND bus (pull-up rise T_RISE)
 transactions ─> words ──┼─> RTL (engine ─┤
                         │   + pin_mgr)   └── log: every SDA/SCL change, RX words, slave memories
                         └──────────────────> i2c_test.py: decode() (I2C rules only) + expect() (word semantics + slave
                                                            model) + UM10204 timing minimums
```

- **Reference model `expect()`**: from the host words alone it computes the transactions the bus must show (START /
  repeated START, address, data, ACK/NACK, STOP), the RX words the host must read (incl. NACK events and dropped words),
  and the slaves' final memory (EEPROM pointer semantics).
- **Decoder `decode()`**: knows only I2C: START/STOP = SDA change while SCL high; a bit is sampled at the SCL rise and
  committed at the fall (so the rise before STOP/Sr is not a bit); 9-bit bytes. Flags: START/STOP inside a byte, SDA and
  SCL changing together, STOP without START, bus left open.
- **Timing (UM10204 minimums, per speed)**: t_LOW, t_HIGH, t_SU;DAT, t_HD;STA, t_SU;STA, t_SU;STO, t_BUF and the SCL
  period (frequency must not exceed nominal). Values cross-checked against vendor datasheets that reproduce the table
  (TI TLA2022 / ADS7142 / TAC5112, ROHM BD37532, AMS AS5600, Microchip).
- **Every case also checks**: host RX words, slave memories, engine fault, pin-manager violations, management err,
  and that **the chip never drives SDA/SCL high** (open-drain invariant).
- Negative cases must be DETECTED; sweeps are informational; mutants must be caught.

## 3. Phase 0a — `JPO` / `PUSHI`

| Test | Result |
|---|---|
| `tb_control_unit`: JPO taken on 1 / falls through on 0, shifts OSR, 1 cycle; PUSHI stalls on full, pushes immediate, no ISR clear; traps moved to 21/22 | PASS |
| `tb_engine_ops`: JPO MSB-first and LSB-first consume bits in order; PUSHI writes the full 27-bit immediate, keeps the ISR; stalls on a full FIFO and resumes without loss | PASS |
| `tb_fetch_equiv` (illegal opcodes 21-31) | 177,995 cycles, 0 mismatches |
| 7 mutations (no consume, wrong polarity, always advance, PUSHI writes ISR, no stall, clears ISR, shifted immediate) | all caught |
| SPI engine-level suite after the change | 260/260, all limits identical |

## 4. Phase 0b — pin manager

| Test | Result |
|---|---|
| `tb_pin_mgr`: 768 combinations (8 pads x owner 0/1/2 x od x engine oe/out), reset state, claim rules, violations, W1C, new event wins, open-drain never drives high | PASS |
| `tb_mgmt_pins` (full chip, frames): readback, 5 refusal kinds (owner 3, reserved bits, unmapped 0x0224, misaligned, claim while running), violation + W1C, open-drain at the pads | PASS |
| 7 mutations (od ignored on enable / on data, ownership ignored, claim while running, clear wins, mgmt ignores pad_ok, VIOL readback broken) | all caught |
| Regression after integration (`run_tests.ps1`) | 19/19 PASS after adding pad claims to the chip tbs |

## 5. Phase 1 — decoder self-test (12 cases)

| Case | Result |
|---|---|
| Ideal waveform at 100 / 400 / 1000 kHz (17 transactions each), rebuilt exactly, timing within spec | 3 PASS |
| t_LOW 20 ns short, t_SU;DAT 10 ns short (each speed) | 6 DETECTED |
| SDA change while SCL high inside a byte, missing STOP, NACK where ACK expected | 3 DETECTED |

## 6. Phase 2 — peers (7 cases)

Verilog master model (same word semantics, independent code) against the slave models: Sm / Fm / Fm+ basic sets, two
slaves, slave NACK on data byte 2, slave stretching every bit 2 us, absent address. **7/7 PASS.**
Found and fixed: the slave model counted the SCL fall right after START as a data bit (model bug).

## 7. Phase 3 — engine as master (24 counted cases + sweep)

| Group | Result |
|---|---|
| Basic set (writes, write → Sr → read, current-address reads, absent address, walking bits, random) at 100 / 400 / 1000 kHz | 3 PASS |
| Same with the **maximum rise time** for each speed (1000 / 300 / 120 ns) | 3 PASS |
| Two slaves interleaved | 3 PASS |
| Data NACK (C path: STOP, event, queued bytes dropped) | 3 PASS |
| No slave at all | 3 PASS |
| Slave stretching: after every byte 10 us, every bit 1 us, after every byte 500 us | 3 PASS |
| Slave data valid 800 ns (near the Fm t_VD max 900 ns) | PASS |
| Host words 30 us apart (master parks with SCL low), RX not drained 2 ms (master stalls in PUSH), words without START on an idle bus dropped | 3 PASS |
| Random stress: 307 words at 100 kHz, 1,105 words at 1 MHz | 2 PASS |

**Measured timing minima** (ns; spec minimum in brackets):

| Speed | t_LOW | t_HIGH | t_SU;DAT | t_HD;STA | t_SU;STO | t_BUF | max f_SCL |
|---|---|---|---|---|---|---|---|
| 100 kHz | 4740 (4700) | 5280 (4000) | 4639 (250) | 4120 (4000) | 4140 (4000) | 14360 (4700) | 100 kHz |
| 400 kHz | 1340 (1300) | 1180 (600) | 1239 (100) | 720 (600) | 740 (600) | 3460 (1300) | 397 kHz |
| 1 MHz | 540 (500) | 480 (260) | 439 (50) | 380 (260) | 400 (260) | 1520 (500) | 980 kHz |

With rise time at the spec maximum the bus slows (91 / 357 / 893 kHz) because the master waits for SCL to be really high
(`WAITH`), which is the correct behaviour. t_HD;DAT is 1 clock (20 ns) after SCL falls.

**Speed limit sweep** (custom delays, data must stay correct, spec check off):

| Slave t_VD | Highest SCL with correct data (measured) | First failing setting |
|---|---|---|
| 0 ns | 6.25 MHz (tA = tH = 0, the loop's floor) | none |
| 100 ns | 3.57 MHz | tA=3, tH=1 |
| 200 ns | 1.92 MHz | tA=8, tH=6 |

Rule: the slave's data must be valid within the master's SCL low phase (`tA+2` clocks) minus the 2-clock input
synchronizer.

**Finding fixed in this phase:** after a slave stretch the master's high phase starts at the next synchronized edge, up to
one clock late relative to the line; one SCL period measured **2499 ns at 400 kHz** (limit 2500). `delays()` now pads the
period by one more clock. Also fixed: a float ceiling made 25 clocks into 26 at 1 MHz.

## 8. Phase 5 — full chip through the management link (10 cases)

Pads 6/7 claimed open-drain over `0x0200`, program loaded, RUN, words and results only through 7-byte frames.

| Case | Mgmt frames | Time | Result |
|---|---|---|---|
| Engine 0, 100 kHz basic set (70 B) | 367 (140 TX retries: host faster than the bus) | 8.4 ms | PASS |
| Engine 0, 400 kHz basic set | 209 | 4.8 ms | PASS |
| Engine 0, 1 MHz basic set | 221 | 5.0 ms | PASS |
| Engine 1, 400 kHz basic set | 205 | 4.7 ms | PASS |
| Engine 1, 1 MHz, two slaves + data NACK | 112 | 2.6 ms | PASS |
| Engine 0, 400 kHz, rise 300 ns + stretch every byte 20 us | 179 | 4.1 ms | PASS |
| Engine 0, 1 MHz, slow host (management half period 2 us) | 171 | 38.4 ms | PASS (master parks, bus stays legal) |
| Engine 0, 1 MHz, fastest host (8-clock half period) | 167 | 3.1 ms | PASS |
| Engine 0, 400 kHz random stress (301 words) | 672 | 15.3 ms | PASS |
| Engine 1, 1 MHz random stress (307 words) | 684 | 15.6 ms | PASS |

Throughput through the link (1 MHz bus, 10-clock management half period): about 20 bytes/ms. Each byte costs one WRITE
and one READ frame (~11 us each at that link speed); the bus waits with SCL low in between.

## 9. Mutants (7, all DETECTED)

| Mutation | Caught by |
|---|---|
| Bit loop ignores stretching (no `WAITH SCL`), slave stretches every bit | data / transactions (SCL never seen high) |
| ACK not checked (C flag consumed, ignored), slave NACKs data | extra bytes after the NACK |
| SDA sampled while SCL is low | read data |
| STOP without pulling SDA low first | missing STOP / transactions |
| t_HD;STA = 0 | timing check |
| t_LOW too short | timing + data |
| Pads claimed push-pull | "chip drives SDA/SCL high" counter |

## 10. Limits and what is not covered

- **I2C slave not implemented** (word budget; I2C_PLAN §6.4.1).
- No multi-master arbitration, 10-bit addressing, Hs-mode, SMBus timeouts.
- Stuck bus (SDA held low): the master waits in `WAITH` forever; recovery is the host toggling RUN (no firmware timeout).
- Zero-delay RTL simulation: pad delays and metastability are not modelled; rise time is modelled as a delay on release.
