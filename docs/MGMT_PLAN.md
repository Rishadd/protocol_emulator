# Management Module + SPI Host Link — Design and Status

Companion to [EXECUTION_PLAN.md](EXECUTION_PLAN.md) (task R8) and [PROTOCOL_EMULATOR_ARCHITECTURE.md](PROTOCOL_EMULATOR_ARCHITECTURE.md) §6 |
2026-10-10, revised 2026-10-11 | Status: **frame v1 built and verified in simulation (steps 1-8); CRC, sequence numbers, ID registers and the pin window are still to do**

## Goal

A host (a testbench in simulation, a Pico later) sends everything to the chip over SPI: engine programs, control
commands and payload. The management module decodes the frames, loads both engines, starts and stops them, and moves
bytes between SPI and the engine FIFOs. Success test (met in simulation): a long message goes in over SPI, out of the TX
engine on the UART line, back into the RX engine, and out over SPI, with sent, recorded and received data identical.

## Built: frame v1 (simulation only)

**Pins** (Tiny Tapeout template, architecture doc §5): `ui_in[0]` SCLK, `ui_in[1]` MOSI, `ui_in[2]` CS_N, `uo_out[0]` MISO,
`uio[7:0]` protocol pins. Top: `src/tt_um_protocol_emulator.v`. SPI slave: `src/spi_slave.v` (mode 0, needs >= 8 system
clocks per SCLK half-period and >= 4 for CS_N setup/hold). Management: `src/mgmt.v`.

**Frame:** exactly 7 bytes per CS_N low, SPI mode 0, MSB first, **big endian**, full duplex. (This deviates from the
architecture doc's little-endian field order so the frame is one plain shift register; revisit with the final frame.)

| Byte | 0 | 1-2 | 3-6 |
|---|---|---|---|
| MOSI | op: 0x01 WRITE, 0x02 READ | address | write data |
| MISO | STATUS | 0x00 | read data (0 for WRITE) |

STATUS (sampled while CS_N is high, so it is always the state at the start of the frame): `[7]` 1 (alive), `[6]` err,
`[5:4]` RUN e1/e0, `[3:2]` TX full e1/e0, `[1:0]` RX has data e1/e0.

**Registers** (engine e: base = 0x1000 for engine 0, 0x2000 for engine 1; `addr[15:12]` selects the engine):

| Address | Access | Meaning |
|---|---|---|
| base+0x000 | W | CTRL bit 0 RUN. RUN=0 holds PC/control/counters/shifters/pins in reset (pins released) but keeps FIFOs and memory. Reset value 0. Other bits must be 0 |
| base+0x000 | R | `{pc[13:8], fault[2], halted[1], RUN[0]}` |
| base+0x100+4i | W | instruction word i, **only while RUN=0** (otherwise rejected, sets err) |
| base+0x200 | W | TX FIFO push, also while RUN=0 (preload). Accepted only if this frame's STATUS showed TX not full; otherwise dropped silently and the host resends |
| base+0x204 | R | RX FIFO pop. Pops only if this frame's STATUS showed data; otherwise returns 0 and pops nothing. The byte is in bits [31:24] (LSB-first receive) |
| 0x0200+4p | W | pin manager, pad p: `data[1:0]` owner (0 none, 1 engine 0, 2 engine 1), `data[2]` open-drain. Refused (err) while the pad's owner runs, for owner 3 or nonzero `data[31:3]`. Reset: no owner = pad not driven (added 2026-10-11) |
| 0x0200+4p | R | `{od, owner[1:0]}` |
| 0x0220 | R / W | violations `{engine 1 [15:8], engine 0 [7:0]}` (a running engine enabled a pad it does not own); W = write-one-to-clear, a new violation wins |

**Commit rules:** nothing takes effect before CS_N rises on a complete 7-byte frame, so an aborted frame does nothing.
Read data is frozen after byte 2 and the pop happens only on a complete frame, so no byte is torn or lost. A bad frame
(wrong length, unknown op, unmapped or misaligned address, nonzero reserved CTRL bits, instruction write to a running
engine) changes nothing and sets the sticky `err` bit (cleared only by reset); an empty CS_N pulse is not an error. The
STATUS rules make every TX push and RX pop exactly-once without extra polling frames.

### Build order as executed (the user's 8 steps)

| Step | What | Test | Result |
|---|---|---|---|
| 1 | `instr_mem` synchronous write port | `tb_instr_mem` | PASS; mutations caught |
| 2 | `spi_slave`, minimal `mgmt`, TT top | `tb_spi_word0` (since replaced) | PASS |
| 3 | Frame v1, `run` gate, RUN register, write rules | `tb_mgmt_frame` | PASS; mutations caught |
| 4 | Full 64-word loads, golden engine in lockstep (pattern, 64-word, UART TX and RX images; 15,679 cycles, 0 mismatches) | `tb_mgmt_load` | PASS |
| 5 | Engine 1, per-engine RUN/write enable, pad merge (engine 0 wins) | `tb_mgmt_dual` | PASS (~112k cycles, two golden engines, 0 mismatches) |
| 6 | READ op, STATUS, RX pop with real UART RX firmware | `tb_mgmt_read` | PASS; 6 mutations caught |
| 7 | TX push with flow control, real UART TX firmware (101 bytes decoded, 218 resends in a 64-byte stream) | `tb_mgmt_tx` | PASS |
| 8 | Full duplex through SPI: TX on engine 0 / P0, RX on engine 1 / P1, 1 KB at 115200, live echo and replay, jitter, baud error, negative case | `tb_mgmt_duplex` + `host/mgmt_duplex_stress.py` | All cases 1024/1024, every TX frame cycle-exact, 0 faults; negative case detected |

Regression: the 16 testbenches in `run_tests.ps1` PASS (re-run 2026-10-11). `tb_mgmt_duplex` is driven by Python and is not
part of that script.

## Original plan: what was deferred or replaced

The first version of this document planned a 12-byte frame with CRC-16, a pipelined response with sequence numbers, and
level reporting. These were **deliberately left out of v1** to prove the data path first. They are still required before tape-out:

| Item | v1 | Target |
|---|---|---|
| Frame | 7 bytes, big endian | 12 bytes: op, seq, addr, payload, status, CRC-16/CCITT-FALSE (architecture doc §6) |
| Integrity | length + op/address checks only | CRC over bytes 0-9; commit only after CRC accepted |
| Retry safety | exactly-once via per-frame STATUS | duplicate-sequence detection, cached result, pipelined response |
| FIFO levels | full/has-data flags | levels, high-water marks, RX overrun flag (needs `fifo.v` count output) |
| ID / capacity / version registers | none | `0x0000` window; read-only capability registers |
| Pin management window | none | `0x0200` window: owner, mode, claim/deny, violations (see the study §5) |
| Instruction readback | none | free once instruction memory is SRAM (the same port) |

### Decisions the original plan left open, now answered

- **Message size:** 1 KB for the regression (done, 1024/1024). Longer soak runs remain optional.
- **Baud for the long test:** 115200 was reached directly, with an SPI half-period of 13.3 system clocks and one write frame
  plus one read frame per byte.
- **Bandwidth at 115200:** a 7-byte frame is shorter than the 12-byte target, so v1 has more margin than the final frame
  will. Re-check the budget when the 12-byte CRC frame lands (a 12-byte frame at 3 MHz is 32 us; one write and one read per byte
  is about 64 us against 87 us per UART byte).

## Interaction with the SRAM decision

[ASIC_AREA_AND_MEMORY_STUDY.md](ASIC_AREA_AND_MEMORY_STUDY.md) recommends moving instruction memory to SRAM. For this
module that means: the write port is the macro's port, still usable only while RUN=0 (same rule, so frame behavior is
unchanged); host readback becomes possible; with a shared dual-port macro the claim rule "write a page only if its owner
is not running" is added to the instruction-write decode. No frame change is needed.

## Test ladder — mapping the original T1-T7 to what exists

| Original | Where it lives now |
|---|---|
| T1 scratch, bad length, CS abort, no side effects | `tb_mgmt_frame`. **Open:** ID read, scratch echo, bad-CRC (no CRC yet) |
| T2 load both programs and verify | `tb_mgmt_load` (golden engine in lockstep). Readback checksum: open (no readback) |
| T3 TX only with flow control | `tb_mgmt_tx` |
| T4 RX only | `tb_mgmt_read` |
| T5 loopback, concurrent and two-pass replay | `tb_mgmt_duplex` live echo and replay |
| T6 stress: stalls, SCLK ratios, aborts, baud error | `tb_mgmt_read`/`_tx` SCLK sweeps and aborts; `tb_mgmt_duplex` stall negative case, jitter, baud error. Bad-CRC injection: open |
| T7 one command runs it all | `run_tests.ps1` runs 16; `tb_mgmt_duplex` still needs its Python wrapper |
