# Workstream 2 — RTL Implementation Plan

Companion to [PROTOCOL_EMULATOR_ARCHITECTURE.md](PROTOCOL_EMULATOR_ARCHITECTURE.md),
[EXECUTION_PLAN.md](EXECUTION_PLAN.md), [WORKSTREAM1_ARCHITECTURE.md](WORKSTREAM1_ARCHITECTURE.md)
and the ISA contract in [../instructions.md](../instructions.md) | revised 2026-10-03 |
Status: **v0.1 engine implemented and verified in simulation**

## What changed from the original plan (2026-09-27 → 2026-10-03)

The first plan built UART-shaped hardware: a 10-bit "TX shift register with
frame packing", a single `TX_DATA` register + valid flag, and opcodes
(`LDBYTE`, `OUT1` with an embedded delay field) that only made sense for UART.
During review we replaced that with a protocol-agnostic datapath in the
RP2040-PIO spirit, so that UART, SPI, I2C, JTAG and future protocols differ
only in firmware:

| Original (UART-specific) | Implemented (generic) |
|---|---|
| `tx_shift_reg`, 10-bit, hardwired `{stop, byte, start}` | `shift_reg` (32-bit, LSB/MSB-first selectable), instantiated twice as **OSR** and **ISR** |
| `tx_handshake` / `rx_handshake` single-byte registers | `fifo` (32-bit × 4, first-word-fall-through), instantiated twice as `tx_fifo` and `rx_fifo` |
| Single `pin_driver` for 1 pin | `pin_block`: 8 pins, per-pin `out`/`oe` registers, 2-stage input synchronizer |
| No loop counter in v0.1 | `loop_counter` (16-bit) + `SETL`/`DJNZ`, needed to fit 8-bit loops in 64 words |
| 18-bit delay operand | 27-bit flat operand (covers 2.68 s at 50 MHz) |
| Opcode 5 bits + delay 6 + side-set 3 + operand 18 | Opcode 5 bits + **one flat 27-bit operand**; delay *is* the operand of timed instructions |
| 3–7 opcodes | 17 opcodes (see [../instructions.md](../instructions.md) §1) |

Framing (start/stop bits, CS, SCLK, TMS…) is now entirely firmware
(`SETH`/`SETLO`/`DIRO`/`DIRI`). Nothing in `src/` knows what UART is.

## Module map — current state

| Module | File | Status | Notes / what grows later |
|---|---|---|---|
| Program counter | `pc_reg.v` | **Done, unit-tested** | 6-bit; jump beats advance |
| Instruction memory | `instr_mem.v` | **Done** (64×32, combinational read) | Loaded by `$readmemh` / FPGA power-up init. **Host write port and parity not yet built** (RTL-5b, RTL-5c) |
| Delay counter | `delay_counter.v` | **Done, unit-tested** | 27-bit, `busy` + `last`; `last` lets the control unit release one cycle early so a timed instruction costs exactly d+1 |
| Loop counter | `loop_counter.v` | **Done, unit-tested** | 16-bit, saturates at 0 |
| FIFO | `fifo.v` | **Done, unit-tested** | DEPTH parameter; 4 today. Host must honor `tx_full` (proven in the workload limit test) |
| Shift register | `shift_reg.v` | **Done, unit-tested** | One module for OSR and ISR |
| Pin block | `pin_block.v` | **Done, unit-tested** | Reset releases all pins (`oe=0`). Edge detect (v0.3), ownership mux (multi-engine), abort/`ena` latch (RTL-1) still to add |
| Control unit | `control_unit.v` | **Done, unit-tested** | 2-state FSM (EXEC / HOLD), stall logic for PULL/PUSH/WAITH/WAITL, `CFG` registers, trap on reserved opcodes |
| Engine top | `engine_top.v` | **Done, integration-tested** | Host-facing: `tx_fifo` write port, `rx_fifo` read port, 8 pins, `halted`/`fault`/`pc` |
| Safety latch (abort, `ena`) | — | Not built | Reset already releases pins; async abort + synchronized release is RTL-1 |
| Management / CSR + SPI frame decode | — | Not built | RTL-8; needed before the chip is host-loadable |
| Input edge detect | — | Not built | For `WAITR`/`WAITF` (opcodes 17/18, reserved) — UART RX |
| Side-set | — | **Open decision** | Flat format gave up the reserved bits; options are a dedicated opcode or a `CFG`-selected pin that `OUT1`/`IN1` toggle automatically. Needed for I3C-class speeds |
| Trace / first-fault / BIST / watchdog | — | Not built | v0.6 |

## Verification status

| Level | Harness | Result |
|---|---|---|
| Unit (7 modules) | `tb/tb_<module>.v`, self-checking, X-safe (`!==`) | All PASS |
| Control unit | `tb/tb_control_unit.v` — every opcode's exact strobe set, d+1 timing for d∈{0,1,2,3,5}, stall with zero side-effects, trap on 17/18/31 | PASS |
| Integration | `tb/tb_engine_top.v` B1–B8: PC flow, 11-cycle stall, DJNZ loop, PULL blocking, trap freeze, UART TX 115200 + 9600 decoded, reset mid-frame | PASS (136 checks total across suite) |
| Workload | `host/uart_workload.py` + `tb/tb_uart_workload.v`: Python reference model + ideal receiver, 1 KB payload with all 256 byte values, runs of 0x00/0xFF/0x55, UTF-8, host silence gaps | 9600–115200 all cycle-exact; rx clock tolerance ±5.25%; D=0 (25 Mbaud) still exact; host ignoring `tx_full` drops whole bytes cleanly, never corrupts |

One RTL bug found and fixed by the suite: the combinational stall `case` had no
match for an X opcode (before first fetch) and propagated X onto every control
strobe. Replaced with a `?:` chain. One firmware bug found before simulation:
`SETL` placed after the start-bit `WAIT` stretched the start bit by one cycle.

Timing contract that everything depends on, now **verified**: non-timed
instruction = 1 cycle; `WAIT d` / `OUT1 d` / `IN1 d` = exactly d+1 cycles;
blocking instructions hold PC with zero side-effects; pin inputs are 2 clocks old.

## Remaining RTL tasks (ordered)

| ID | Task | Depends on | Validation |
|---|---|---|---|
| RTL-F1 | **FPGA wrapper for DE0-Nano**: `msg_host.v` (string → `tx_fifo`, honors `tx_full`), `de0_nano_top.v` (KEY0 reset sync, tri-state `GPIO_0`, LEDs), `.sdc`, `.qsf` pins, `instr_mem` power-up init | — | Testbench on `de0_nano_top`; then message received on a phone via HC-05 at 9600 |
| RTL-5b | Host write port on `instr_mem` (gated by halted) | — | Write/read-back all 64 words; write while running has no effect |
| RTL-1 | Safety latch: async disarm on reset/abort/`!ena`, synchronized release, forces all `pin_oe=0` | — | Formal (SymbiYosys) or exhaustive directed sim: V01 |
| RTL-E | Edge detector per pin + `WAITR`/`WAITF` decode | — | Directed sim; then UART RX firmware (v0.3) |
| RTL-S | Side-set decision + implementation | design review | SPI at ≥ 5 MHz with SCLK toggled in the same instruction as `OUT1` |
| RTL-8 | Management/CSR + 12-byte SPI frame decode (checksum first, CRC-16 later) | RTL-5b | Frame encode/decode round trip, corrupt-byte rejection (V10) |
| RTL-2nd | Second engine instance + pin ownership mux | RTL-8 | Both engines run independent programs without pin interference (V03) |
| RTL-5c | Parity on `instr_mem` | RTL-8 | Fault injection |
| RTL-9 | Trace, first-fault, BIST, watchdog | all above | v0.6 obligations |

The original RTL-6/RTL-7 (UART shifter, TX_DATA handshake) are **deleted**, not
deferred — their roles are covered by `shift_reg` and `fifo`.

## Brief roadmap for later versions (deltas only)

- **v0.3 (UART RX / full duplex)**: RTL-E edge detect, second engine, `IN1`
  into ISR, `PUSH` to `rx_fifo` — all already present except edge detect.
- **v0.4 (SPI)**: side-set decision; ownership mux. The shifters already do
  MSB-first and full duplex (`OUT1` + `IN1` per bit).
- **v0.5 (I2C)**: open-drain needs no RTL mode — firmware uses `DIRO`=drive-low,
  `DIRI`=release. Still wanted: a `CFG` bit making `OUT1` write `~bit` to
  `pin_oe` so a data byte fits in a loop (see [../instructions.md](../instructions.md) §4),
  and a conditional branch on a pin for ACK/NACK.
- **v0.6**: parity, CRC-16, trace, BIST, watchdog.
