# Workstream 2 — RTL Implementation Plan

Companion to [PROTOCOL_EMULATOR_ARCHITECTURE.md](PROTOCOL_EMULATOR_ARCHITECTURE.md),
[EXECUTION_PLAN.md](EXECUTION_PLAN.md), and
[WORKSTREAM1_ARCHITECTURE.md](WORKSTREAM1_ARCHITECTURE.md) | 2026-09-27 |
Status: planning, pre-RTL

## Same staging rule as Workstream 1

This plan follows the same principle as the architecture doc: **full detail
for v0.1 only, brief deltas for later versions.** Each RTL module below maps
directly to a hardware capability already derived from the v0.1 opcode set
(`PULL_BYTE`, `OUT1`, `JMP`) and to a task ID in
[EXECUTION_PLAN.md](EXECUTION_PLAN.md)'s Workstream 2 (R1-R12) — this document
narrows those broad tasks down to exactly what v0.1 needs, nothing more.

## Module map (brief — full detail for v0.1 below)

| Module | v0.1 (UART TX) | Arrives/grows at |
|---|---|---|
| Safety latch | Full detail below | Unchanged in later versions — this one is done right the first time |
| Pin driver | Full detail below (1 pin, no ownership mux) | Ownership mux added at v0.4 (multi-pin), electrical mode added at v0.5 (open-drain) |
| Delay counter | Full detail below | Unchanged — reused as-is by every later opcode that needs timed holds |
| PC / fetch / decode | Full detail below (3 opcodes) | Opcode table grows at v0.3/v0.5; conditional PC mux added at v0.5 (`BRANCH_IF`) |
| Instruction memory | Full detail below (64x32, no parity) | Parity bit added at v0.6 |
| TX shift register | Full detail below (10-bit, UART frame packing) | RX shift register added at v0.3; generic 8-bit mode added at v0.4 (SPI/I2C) |
| Host data handshake | Full detail below (TX_DATA + valid flag) | RX_DATA + ready flag added at v0.3 |
| Management/CSR + frame decode | Full detail below (minimal register set, no CRC) | Full CRC-16 + sequence pipelining added at v0.6 |
| Input synchronizer | *(not needed yet)* | Added at v0.3 (UART RX) |
| Side-set apply logic | *(not needed yet)* | Added at v0.4 (SPI) |
| Trace / first-fault / BIST / watchdog | *(not needed yet)* | Added at v0.6 |

---

## v0.1 — Full RTL detail

### RTL-1: Safety latch

**Purpose**: reset or abort must instantly force the owned pin to a
non-driving state, overriding every other module below.

- Inputs: `rst_n`, `abort_n`, `ena`
- Output: `disarm` (1 = force output-enable to 0 everywhere)
- Behavior: `disarm` asserts **asynchronously** the instant `rst_n` or
  `abort_n` goes low, or `ena` drops. It **releases synchronously** — i.e.
  waiting one clock after the input returns high, never combinationally.
- **Validation**: formal property — for every reachable state of every other
  module, `rst_n=0` OR `abort_n=0` implies pin output-enable is 0 on the next
  clock edge, with zero exceptions. This is V01 from the verification
  obligations list and gets a dedicated SymbiYosys proof, not just simulation.

### RTL-2: Pin driver (single pin, v0.1)

**Purpose**: hold a single output pin at a commanded level.

- Inputs: `pin_data` (from TX shift register or side-set — side-set unused in
  v0.1), `disarm` (from RTL-1)
- Outputs: `uio_out[0]`, `uio_oe[0]`
- Behavior: `uio_oe[0] = !disarm`; `uio_out[0] = pin_data` when not disarmed.
- **Validation**: directed sim — assert `disarm` mid-drive, confirm `uio_oe`
  drops within one clock regardless of what `pin_data` was doing.

### RTL-3: Delay counter

**Purpose**: hold the engine at the current instruction for exactly N cycles,
where N comes directly from the instruction's operand field (not a narrow
6-bit field — see the discussion that led to `WAITCYC`-style timing being
folded into `OUT1` itself).

- Inputs: `load` (pulse), `load_value` (18 bits, from instruction operand),
  `clk`
- Output: `busy` (1 while counting down)
- Behavior: on `load`, counter := `load_value`; decrements every clock while
  nonzero; `busy` deasserts the cycle the counter reaches 0, allowing the
  next fetch.
- **Validation**: directed sim — load with 0, 1, and the maximum 18-bit value;
  confirm `busy` timing matches `1 + load_value` cycles exactly (this is the
  cycle-accounting rule the whole architecture depends on).

### RTL-4: PC / fetch / decode (3 opcodes)

**Purpose**: fetch one instruction per cycle (once RTL-3's `busy` clears),
decode it, and drive the rest of the datapath.

- Inputs: instruction word from RTL-5, `busy` from RTL-3
- Outputs: `pc` (6 bits, for `PC_READBACK`), decoded opcode, decoded operand
  fields routed to the relevant module (delay value to RTL-3, jump target to
  its own PC-load mux, shift command to RTL-6)
- Opcodes implemented: `PULL_BYTE` (0), `OUT1` (1), `JMP` (2). **Every other
  5-bit opcode value must trap** — force the engine to a fault/halted state
  visible in `STATUS`, never execute undefined behavior.
- **Validation**: differential test against the ISA cycle model
  (Workstream 4's F1) for all three opcodes, plus a directed test that writes
  every unimplemented opcode value and confirms a clean trap, not garbage
  execution. This is V04 and V13 from the verification obligations list.

### RTL-5: Instruction memory (64 x 32, no parity in v0.1)

**Purpose**: store the program; host-writable, engine-readable.

- 64 words x 32 bits, implemented as flip-flops (not SRAM, per the
  architecture doc's baseline)
- Host write port: address + data, gated by "engine halted" (no writes while
  running)
- Engine read port: combinational read at `pc`
- No parity bit in v0.1 — deferred to v0.6 alongside BIST, to keep the first
  RTL pass as small as possible
- **Validation**: write/read-back test for all 64 words; confirm a write
  attempt while the engine is running is rejected or has no effect (never
  silently corrupts a running program — ties to V13)

### RTL-6: TX shift register (10-bit, UART frame packing)

**Purpose**: turn one host-supplied byte into a 10-bit UART frame
(`{stop=1, byte[7:0], start=0}`) and shift it out one bit per `OUT1`.

- Parallel load: on `PULL_BYTE`, load `{1'b1, tx_data_byte, 1'b0}`
- Serial shift: on `OUT1`, output current LSB, then shift right by 1
- **Validation**: directed sim — load a known byte (e.g. `0x55`), step through
  10 `OUT1`s, confirm the bit sequence matches `0, 1,0,1,0,1,0,1,0, 1`
  (start, LSB-first data, stop) exactly.

### RTL-7: Host data handshake (TX_DATA + valid flag)

**Purpose**: let the host hand a byte to the engine without racing it.

- `TX_DATA` register (8 bits), host-writable
- `valid` flag: set on host write, cleared on `PULL_BYTE` consumption
- `PULL_BYTE` stalls fetch (via the same mechanism as RTL-3's `busy`, or a
  dedicated stall signal) until `valid=1`
- **Validation**: directed sim — write a byte, confirm `PULL_BYTE` unblocks
  immediately; issue `PULL_BYTE` with no byte written, confirm it stalls
  indefinitely until a write occurs (no false unblock)

### RTL-8: Management/CSR + frame decode (minimal, v0.1 register set only)

**Purpose**: let the host talk to everything above over SPI.

- Implements only the six v0.1 registers from
  [WORKSTREAM1_ARCHITECTURE.md](WORKSTREAM1_ARCHITECTURE.md#a2--register-map-v01-subset-same-address-windows-as-the-full-doc):
  `ID`, `CONTROL`, `STATUS`, `TX_DATA`, `PC_READBACK`, instruction memory
  window
- Frame format: same 12-byte shape as the full architecture doc (op,
  sequence, address, payload, reserved/status) — **the shape is frozen now**,
  but the integrity mechanism is simplified for v0.1: use a 1-byte additive
  checksum instead of full CRC-16, deferring CRC-16 to v0.6. (This reverses
  the earlier "freeze CRC now" call, per the later simplification review —
  flag this explicitly if you want to keep full CRC-16 from day one instead.)
- **Validation**: directed sim — encode/decode a known frame by hand, confirm
  register read/write reaches the correct target; corrupt one byte, confirm
  the checksum mismatch is detected and the frame is rejected without
  mutating state (V10)

### RTL-9: Top-level integration (v0.1)

Wire RTL-1 through RTL-8 together per the block diagram in
[WORKSTREAM1_ARCHITECTURE.md](WORKSTREAM1_ARCHITECTURE.md#a7--interconnect--signal-spec-v01-minimal).

- **Validation**: full-chip simulation running the 12-word UART TX reference
  program from the earlier design discussion; confirm the pin waveform
  matches 115200 baud within the expected -0.08% error, byte-accurate
  against an independent UART decoder (V12)

---

## Bring-up order for v0.1 RTL (build and test in this sequence)

1. RTL-1 (safety latch) — formal proof passes standalone before anything else is built
2. RTL-3 (delay counter) — the cycle-accounting foundation everything else depends on
3. RTL-5 (instruction memory) — write/read-back proven before the engine can fetch from it
4. RTL-4 (PC/fetch/decode) — using RTL-3 and RTL-5, prove the 3-opcode fetch/decode/trap behavior
5. RTL-6 + RTL-7 (shift register + handshake) — prove frame packing and blocking behavior
6. RTL-2 (pin driver) — wire the shift register's output through the safety latch
7. RTL-8 (management/CSR) — prove the host can load a program and read status
8. RTL-9 (integration) — run the full reference program end to end

This order matches the GDS-flow philosophy from
[EXECUTION_PLAN.md](EXECUTION_PLAN.md): each module is proven in isolation
before integration, so a full-chip failure can only mean an interconnect bug,
not a hidden module bug.

---

## Brief roadmap for later versions (deltas only)

- **v0.3 (UART RX / full duplex)**: add an input synchronizer module (2-stage
  flip-flops per input pin), an RX shift register (mirror of RTL-6, shifting
  in instead of out), an edge detector (for `WAIT_EDGE`'s start-bit
  detection), and an RX_DATA + ready-flag handshake (mirror of RTL-7).
  Instantiate a second copy of RTL-2 through RTL-7 as Engine 1, run
  independently of Engine 0.

- **v0.4 (SPI)**: add side-set apply logic (a small pin-map register plus
  logic to drive 1-2 auxiliary pins alongside the main opcode's effect,
  finally using the side-set bits reserved in the instruction format since
  v0.1). Add the pin ownership mux (RTL-2 grows from "1 pin, always owned"
  to "N pins, checked ownership per write"). Optionally reintroduce a general
  loop counter register (`LDI`/`DJNZ`) if compact variable-length transfers
  are wanted.

- **v0.5 (I2C)**: add open-drain electrical mode to RTL-2 (output-enable
  computed differently: writing "1" releases rather than drives high). Add a
  level detector (for `WAIT_LEVEL`'s clock-stretch handling) and a
  "last-sampled-bit" condition register plus a conditional PC mux in RTL-4
  (for `BRANCH_IF`'s ACK/NACK handling).

- **v0.6 (debug/safety hardening)**: add parity bit generation/checking to
  RTL-5, full CRC-16/CCITT-FALSE plus sequence-number pipelining to RTL-8,
  a trace buffer and first-fault latch (new modules, read-only taps on the
  existing datapath, never able to backpressure the engine), a memory BIST
  controller (March C- FSM, temporarily takes ownership of RTL-5's ports),
  and a watchdog timer (separate from RTL-3's delay counter — this one
  detects "stuck but still executing" firmware, not "waiting on purpose").
