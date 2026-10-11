# Workstream 2 — RTL Implementation Plan

Companion to [PROTOCOL_EMULATOR_ARCHITECTURE.md](PROTOCOL_EMULATOR_ARCHITECTURE.md),
[EXECUTION_PLAN.md](EXECUTION_PLAN.md), [WORKSTREAM1_ARCHITECTURE.md](WORKSTREAM1_ARCHITECTURE.md),
[MGMT_PLAN.md](MGMT_PLAN.md), [ASIC_AREA_AND_MEMORY_STUDY.md](ASIC_AREA_AND_MEMORY_STUDY.md)
and the ISA contract in [../instructions.md](../instructions.md) | revised 2026-10-11 |
Status: **two engines + SPI management link implemented and verified in simulation; UART TX/RX/duplex proven on FPGA; ASIC memory architecture under decision**

## Design history in one table

The first plan built UART-shaped hardware. Review (2026-10-03) replaced it with a protocol-agnostic datapath in the
RP2040-PIO spirit, so UART, SPI, I2C, JTAG and later protocols differ only in firmware. Nothing in `src/` knows what
UART is.

| Original (UART-specific) | Implemented (generic) |
|---|---|
| `tx_shift_reg`, 10-bit, hardwired `{stop, byte, start}` | `shift_reg` (32-bit, LSB/MSB-first), instantiated as **OSR** and **ISR** |
| `tx_handshake` / `rx_handshake` single-byte registers | `fifo` (32-bit x 4, first-word-fall-through), as `tx_fifo` and `rx_fifo` |
| Single `pin_driver` | `pin_block`: 8 pins, per-pin `out`/`oe`, 2-stage input synchronizer |
| 18-bit delay operand, side-set field | 5-bit opcode + **one flat 27-bit operand**; delay is the operand of the timed opcodes |
| 3-7 opcodes | 17 opcodes ([../instructions.md](../instructions.md) §1) |

## Module map — current state (2026-10-11)

| Module | File | Status | Notes |
|---|---|---|---|
| Program counter | `pc_reg.v` | **Done, unit-tested** | 6-bit; jump beats advance |
| Instruction memory | `instr_mem.v` | **Done, unit-tested** (64x32 flops) | Combinational read, **synchronous host write port** (`we/waddr/wdata`), no parity. **Cannot be the tape-out store**: two copies are 80 % of the chip. SRAM wrapper pending, see below |
| Delay counter | `delay_counter.v` | Done, unit-tested | 27-bit; `last` releases one cycle early so a timed instruction costs exactly d+1 |
| Loop counter | `loop_counter.v` | Done, unit-tested | 16-bit, saturates at 0 |
| FIFO | `fifo.v` | Done, unit-tested | 32 x 4. Four of them are 41k um^2, the biggest block after instruction memory |
| Shift register | `shift_reg.v` | Done, unit-tested | One module for OSR and ISR |
| Pin block | `pin_block.v` | Done, unit-tested | Reset releases all pins. No ownership logic yet |
| Control unit | `control_unit.v` | Done, unit-tested | EXEC/HOLD FSM, stalls on PULL/PUSH/WAITH/WAITL, `CFG`, trap on reserved opcodes |
| Engine top | `engine_top.v` | Done, integration-tested | New since v0.1: `run` input (holds PC, control, counters, shifters and pins in reset while `run`=0; FIFOs and instruction memory keep contents) and `imem_*` write port |
| **SPI slave** | `spi_slave.v` | **Done, tested** | Mode 0, 2-flop synchronizers, SCLK edge-detected (no SCLK clock tree); needs >= 8 system clocks per SCLK half-period |
| **Management** | `mgmt.v` | **Done (frame v1), tested** | 7-byte frames, per-engine RUN, instruction load, TX push, RX pop, status, sticky `err`. No CRC/sequence/ID yet |
| **TT top** | `tt_um_protocol_emulator.v` | **Done** | Two engines, management, reset synchronizer. Pad merge: enable = `oe0` OR `oe1`, **engine 0 wins** a shared pin |
| RX LED sink | `rx_led_sink.v` | Done, tested | FPGA/test helper that lives in `src/`; keep it out of the ASIC source list |
| FPGA wrappers | `src/fpga/` | Done | `de0_nano_top` (TX), `de0_nano_rx_top` (RX), `de0_nano_duplex_top` (echo), `msg_sender.v`, SDC |
| Safety latch (abort, `ena`) | — | Not built | Reset synchronizer and `run` gating already release pins; abort/`ena` path and formal proof (V01) pending |
| Pin ownership / directory | `synth/experiments/pin_mgr.v` | **Prototype, area-only** | 5.2k um^2 (277 cells); +REMAP 14.7k. Not simulated, not in `src/`. See study §5 |
| Edge detect | — | Not built, **no longer needed for UART** | RX firmware uses `WAITH`/`WAITL`. `WAITR`/`WAITF` (opcodes 17/18) stay reserved |
| Side-set | — | **Open decision** | Needed for I3C-class SPI speeds only. Options: dedicated opcode, or a `CFG`-selected clock pin toggled by `OUT1`/`IN1` |
| Trace / first-fault / BIST / watchdog | — | Not built | Area-dependent; first-fault capture is the last thing to drop |

## Verification status

| Level | Harness | Result |
|---|---|---|
| Unit (8 modules) | `tb_instr_mem`, `_pc_reg`, `_delay_counter`, `_loop_counter`, `_fifo`, `_shift_reg`, `_pin_block`, `_control_unit` — self-checking, X-safe (`!==`) | All PASS (re-run 2026-10-11) |
| Engine integration | `tb_engine_top`: PC flow, stall, DJNZ loop, PULL blocking, trap freeze, UART TX 115200 + 9600, reset mid-frame | PASS |
| Firmware on RTL | `tb_rx_led_sink`, `tb_de0_nano_rx_top` (UART RX through the FPGA top) | PASS |
| Management | `tb_mgmt_frame` (frame rules, bad length, abort, reset mid-frame), `tb_mgmt_load` (64-word loads vs a golden engine, lockstep), `tb_mgmt_dual` (both engines, pin conflict, bad addresses), `tb_mgmt_read` (RX pop, in order, abort, SCLK sweep), `tb_mgmt_tx` (101 bytes decoded, flow-control resends) | All PASS; each had mutations that were caught |
| Full duplex over SPI | `tb_mgmt_duplex` + `host/mgmt_duplex_stress.py`: 1 KB at 115200, live echo and replay, peer +-2 %, 20 ns jitter, plus a negative case where loss must be detected | PASS when recorded 2026-10-11; **not in `run_tests.ps1`, not re-run for this revision** |
| UART workloads | `tb_uart_workload`, `tb_uart_rx`, `tb_uart_duplex` with `host/uart_*workload.py` (Python reference model + independent receiver) | Recorded results in [../memory.md](../memory.md) and `results/`; not re-run for this revision |
| FPGA | DE0-Nano + HC-05: TX message on a phone, RX byte on LEDs, full-duplex echo at 115200 | Works (commits `2403f22`, `ea4ff82`) |

`run_tests.ps1` runs 17 names; **16 PASS and `tb_de0_nano_top` hangs** (pre-existing, FPGA TX top, not touched).

Bugs found and fixed so far: the combinational stall `case` propagated X before the first fetch (replaced by a `?:`
chain); `SETL` between the start-bit `WAIT` and the first `OUT1` stretched the start bit (firmware order); the RX
synchronizer resets to 0, which looks like a start bit (firmware waits for idle first); management read decode must use
`frame[23:0]` when the address completes; testbench receivers must sample on clock edges because the pad mux creates a
zero-width glitch when a pin is enabled.

Timing contract everything depends on, **verified**: non-timed instruction = 1 cycle; `WAIT d`/`OUT1 d`/`IN1 d` = exactly
d+1 cycles; blocking instructions hold PC with zero side effects; pin inputs are 2 clocks old.

## Area as measured (Yosys, real CMOS5L cells, pre-CTS)

Whole chip 414,137 um^2 / 15.5k cells = **57.5 % of the nominal 720k**. Per instance: `instr_mem` 165,955 (x2), `fifo`
10,211 (x4), `mgmt` 8,959, `shift_reg` 3,114 (x4), `delay_counter` 2,540 (x2), `pin_block` 2,083 (x2), `spi_slave` 2,468,
`loop_counter` 1,694 (x2), `control_unit` 1,598 (x2), `pc_reg` 559 (x2). With 4 x 1P 64x16 SRAM macros the chip is
143,425 um^2 (20 %). Details and the flop/latch/SRAM comparison: [ASIC_AREA_AND_MEMORY_STUDY.md](ASIC_AREA_AND_MEMORY_STUDY.md).

## Remaining RTL tasks (ordered)

| ID | Task | Depends on | Validation |
|---|---|---|---|
| RTL-SRAM | `instr_mem` behind a wrapper with a **next-PC fetch** (macro address = D input of `pc_reg`, stalls re-read the same address, host owns the port while `run`=0). First with a behavioral macro model, then the real 1P 64x16 (x2 per engine) or a shared 2P 256x32 with page select | A9 decision | Whole existing regression unchanged (cycle-exact contract preserved), then STA on the macro-to-address path |
| RTL-PIN | Pin-management block from the prototype: ownership, claim/deny, violation flags, per-pad open-drain, optional remap; management window `0x0200` | RTL-8 final frame | Every illegal claim and cross-drive rejected; formal "non-owner never reaches a pad" (V02, V03) |
| RTL-8 | Final management frame: CRC-16, sequence/duplicate handling, ID and capacity registers, pin window | A3 decision | Corrupt-byte and duplicate-sequence tests (V10) |
| RTL-F | Shrink the FIFOs (width/depth from firmware needs; latch or narrower storage) | measured firmware needs | Existing FIFO + duplex tests, area re-measured |
| RTL-1 | Safety latch: abort pin, `ena`, async disarm with synchronized release | — | Formal or exhaustive directed test (V01) |
| RTL-S | Side-set decision | design review | SPI >= 5 MHz with SCLK toggled in the `OUT1` instruction |
| RTL-L | Clean the 9 Verilator `-Wall` warnings (4 width, 2 empty pins, 2 unused, 1 sync/async) | — | Lint clean (the template runs a linter) |
| RTL-5c | Parity on instruction storage (SRAM macros change how this is done) | RTL-SRAM | Fault injection |
| RTL-9 | Trace, first-fault, BIST, watchdog | area budget | Obligations V09, V11, V14 |

Deleted rather than deferred: the original RTL-6/RTL-7 (UART shifter, TX_DATA handshake, covered by `shift_reg` and
`fifo`), RTL-5b (host write port, done), RTL-2nd (second engine, done; only its pin-ownership half remains as RTL-PIN),
RTL-E (edge detect, not needed for UART RX).

## Notes for later versions (deltas only)

- **SPI firmware**: shifters already do MSB-first and full duplex. Run the draft against the RTL first (F3); only then
  decide whether side-set is needed.
- **I2C**: open-drain becomes a pin-manager mode (pad data forced 0, pad enable = `oe & ~out`), so `OUT1`/`SETH`/`SETLO`
  are I2C-safe and the proposed `CFG` open-drain bit is dropped. Still wanted: a conditional branch on a pin for ACK/NACK.
- **Debug/safety**: CRC, trace, BIST, watchdog only after the functional core and the memory decision settle.
