# Protocol Emulator ASIC — Execution Plan

Companion to [PROTOCOL_EMULATOR_ARCHITECTURE.md](PROTOCOL_EMULATOR_ARCHITECTURE.md) | 2026-09-27, revised 2026-10-03 | Status: **Workstream 2 core complete in simulation; FPGA bring-up next**

## Progress snapshot (2026-10-03)

| Done | Evidence |
|---|---|
| A1 ISA frozen (5-bit opcode + flat 27-bit operand, 17 opcodes) | [../instructions.md](../instructions.md), `src/isa.vh` |
| A5 code-size check for UART (12 words), SPI/JTAG/I2C drafts | [../instructions.md](../instructions.md) |
| R3 input synchronizer, R4 instruction memory (no parity/host port yet), R5 engine core, R6 shifters + FIFOs | `src/`, 7 unit testbenches + `tb_engine_top`, 136 checks PASS |
| F1 (partial) — Python UART reference model + ideal receiver; F2 UART TX firmware | `host/uart_workload.py`, 9600–115200 cycle-exact, rx tolerance ±5.25% |
| R12 (UART subset) — firmware vs RTL byte-accurate waveform match | `results/uart_workload_2026-10-01/` |

Two plan corrections came out of the RTL work: (1) the engine is **protocol-agnostic**
— the UART-specific shifter/handshake modules from the first draft were
replaced by generic OSR/ISR, FIFOs and an 8-pin block; (2) an **FPGA milestone
(DE0-Nano + HC-05 Bluetooth)** is inserted before the management block, because
it gives a real-world pass/fail for the whole engine with no host-interface
risk in the loop. Both are reflected in the tables below.

## Scope decisions locked in for this plan

- **Single engine for v1.** Two engines are a proven, bounded add-on after the
  first engine is validated end-to-end (RTL, GDS flow, firmware). Full-duplex
  UART with independent TX/RX timing is the main reason a second engine exists;
  it is deferred, not abandoned.
- **Baseline protocol scope: UART, SPI, I2C.** These are estimated to fit the
  64-word instruction memory with headroom.
- **JTAG, SWD, PS/2, CAN, USB low speed, 10 Mbit Ethernet are a separate
  research spike**, not committed inside this 3-month plan. JTAG in particular
  does not fit the flat 64-word / no-call-stack model without a redesign
  (arbitrary-length shift chains need host-streamed data, not a preloaded
  program).
- **Reference host**: a Raspberry Pi Pico acts as the external controller,
  bridging a laptop (USB serial, human-facing commands) to the ASIC
  (SPI, 12-byte management frames per the architecture doc §6).

## How the workstreams tie together

```mermaid
flowchart TB
    subgraph W1[Workstream 1: Architecture]
    A1-A8
    end
    subgraph W2[Workstream 2: RTL]
    R1-R12
    end
    subgraph W3[Workstream 3: GDS Flow]
    G1-G6
    end
    subgraph W4[Workstream 4: Firmware + Host tooling]
    F1-F10
    end
    subgraph W5[Workstream 5: Verification + Bring-up]
    V1-V8
    end
    W1 --> W2
    W1 --> W4
    W2 --> W3
    W2 --> W5
    W3 --> W5
    W4 --> W5
```

---

## Workstream 1 — Architecture (blocks everything else)

| ID | Task | Depends on | Deliverable | Validation |
|---|---|---|---|---|
| A1 | Freeze ISA opcode table for single-engine v1 (drop nothing needed for UART/SPI/I2C only) | — | Opcode table doc, 32-bit field assignments | **DONE** — 17 opcodes, flat operand; every UART/SPI/JTAG step maps to a legal opcode; I2C needs one `CFG` bit (open-drain `OUT1`) |
| A2 | Freeze register/CSR map (addresses, bit fields, sticky bits) | A1 | Register map doc | Windows reserved (unchanged); only FIFO/status ports exist as RTL so far |
| A3 | Freeze SPI host frame format (12-byte frame, CRC-16 params) | — | Frame spec | Shape frozen; not implemented |
| A4 | Freeze pin map for single-engine v1 (which `uio` bits = UART/SPI/I2C) | A1 | Pin table | **DONE** as a firmware convention (all 8 pins identical in RTL) |
| A5 | Firmware code-size budget check for UART, SPI, I2C against 64-word limit | A1 | Instruction count estimate per protocol | **DONE** — UART 12, SPI 18 (draft), well under 51 |
| A6 | Explicit scope decision: JTAG/SWD/CAN/USB/Ethernet = research spike, not in 3-month baseline | — | One-paragraph scope doc | JTAG promoted to "draft program exists" since the generic ISA covers it for free |
| A7 | Interconnect/signal-level spec between management, engine, pins, trace (exact signal names/widths) | A1, A2 | Signal table | **DONE** for the engine — [diagram_core_internal.mmd](diagram_core_internal.mmd) matches `engine_top.v` |
| A8 | Verification obligations list assigned to owners (V01-V14 subset relevant to single engine) | A1-A4 | Assigned checklist | Every obligation has a named test type (formal/sim) and owner |

**Gate 1**: A1-A8 complete and reviewed. Nothing below starts in earnest until
this passes (GDS flow bring-up in G1 can start early since it is decoupled).

---

## Workstream 2 — RTL (single engine, single instance)

Detailed module status lives in [WORKSTREAM2_RTL_IMPLEMENTATION.md](WORKSTREAM2_RTL_IMPLEMENTATION.md).

| ID | Task | Depends on | Deliverable | Status / validation |
|---|---|---|---|---|
| R1 | Reset/abort safety-disarm latch module | A7 | RTL + testbench | Not built. Reset already releases all pins; abort/`ena` path and formal proof (V01) pending |
| R2 | Pin ownership + electrical mode mux (push-pull/open-drain) | A4, A7 | RTL + testbench | **Partly done**: `pin_block` has per-pin data/direction. Ownership mux waits for the second engine; open-drain is a firmware idiom (`DIRO`=drive low, `DIRI`=release), no RTL mode needed |
| R3 | Input synchronizer (2-stage) + optional filter | A7 | RTL + testbench | **DONE** inside `pin_block`; 2-clock latency verified |
| R4 | Instruction/data storage (flip-flop based, parity) | A1, A5 | RTL + testbench | **DONE** without parity or host write port (R4b/R4c pending) |
| R5 | Engine core: fetch/decode/PC/ALU | A1, R4 | RTL + testbench | **DONE** (no ALU in v0.1 ISA). Every opcode's strobes and d+1 timing verified in `tb_control_unit` |
| R6 | Engine shifters + FIFOs (TX/RX) | A1, R5 | RTL + testbench | **DONE** — generic 32-bit OSR/ISR + 32×4 FIFOs; full/empty boundaries, simultaneous rd/wr, wrap tested |
| R7 | Timestamp/event fabric (32-bit counter, deadline, event bits) | A7 | RTL + testbench | Not built (needs second engine to be useful) |
| R8 | Management/CSR controller + SPI frame decode | A2, A3 | RTL + testbench | Not built |
| R9 | Trace + first-fault capture | A7 | RTL + testbench | Not built |
| R10 | Memory test/BIST controller (March C-) | A7 | RTL + testbench | Not built |
| R11 | Top-level integration (wire all modules per A7 signal spec) | R1-R10 | Integrated RTL | **DONE for the single engine** (`engine_top.v`); grows as R1/R8 land |
| R12 | Full-chip simulation: load+run UART/SPI/I2C firmware against RTL | R11, F-series firmware | Passing integration testbench | **UART TX DONE** (cycle-exact vs Python reference, 8 bauds). SPI/I2C pending their firmware |
| **R-FPGA** | **DE0-Nano wrapper**: `msg_host` + `de0_nano_top` + SDC/QSF; HC-05 Bluetooth to phone at 9600, then 115200 | R11 | Bitstream + bench log | Message received on phone; LEDs show no fault |

---

## Workstream 3 — GDS Flow (runs in parallel, starts on stub RTL immediately)

| ID | Task | Depends on | Deliverable | Validation |
|---|---|---|---|---|
| G1 | Stand up LibreLane/CMOS5L flow on a throwaway module (e.g., R1) | R1 (or any trivial module) | Working script/Makefile, one-command run | Clean GDS out, DRC/LVS pass on the stub |
| G2 | Re-run flow on each RTL module as it lands (R2-R10) | R2-R10, G1 | Per-module area/timing reports | No new DRC/LVS errors introduced per module |
| G3 | Establish continuous flow re-run habit (flow triggered on every RTL commit) | G1 | Automation script | Flow completes in a bounded time (track and report turnaround time) |
| G4 | First full-chip GDS run on integrated RTL | R11, G2 | Full GDS + STA report | STA closure at target clock (48 MHz primary, 24 MHz fallback) |
| G5 | Area/timing budget check against architecture doc §11 targets | G4 | Budget comparison doc | Confirms fit within 6x4 tile allocation |
| G6 | Final sign-off GDS run (post iteration fixes) | Workstream 5 fixes | Sign-off GDS, DRC/LVS/STA clean | Full clean report, no waived violations without documented justification |

---

## Workstream 4 — Firmware + Host tooling (Pico + laptop)

| ID | Task | Depends on | Deliverable | Validation |
|---|---|---|---|---|
| F1 | ISA cycle-accurate simulator/model (independent of RTL) + assembler | A1 | Python/C model + assembler | **Partial**: `host/uart_workload.py` has the word encoder and a UART reference/decoder. A general per-opcode cycle model is still needed for SPI/I2C differential tests |
| F2 | UART TX/RX firmware program | F1, A5 | Assembled instruction words | **TX DONE** (12 words, verified against RTL at 8 bauds). RX waits for edge detect (v0.3) |
| F3 | SPI controller firmware program | F1, A5 | Assembled instruction words | Draft in [../instructions.md](../instructions.md) §3, not simulated |
| F4 | I2C controller firmware program | F1, A5 | Assembled instruction words | Draft primitives in [../instructions.md](../instructions.md) §4; blocked on `CFG` open-drain bit |
| F5 | Pico-side SPI frame builder (pack op/seq/addr/payload, CRC-16) | A3 | Pico C/MicroPython module | Unit test: encode known frame, compare byte-for-byte against hand-computed reference |
| F6 | Pico-side command dispatcher (USB-serial commands -> SPI frames) | F5 | Pico firmware | Manual test: send "load"/"send"/"trace" commands from laptop, confirm correct SPI frames on a logic analyzer |
| F7 | Laptop-side control script (Python, talks to Pico over USB serial) | F6 | Python CLI tool | Confirms round-trip: laptop command -> Pico -> (simulated) SPI frame -> response parsed correctly |
| F8 | Firmware validation against RTL cosimulation (not just model) | F2-F4, R11 | Cosim test report | Byte-accurate match between model and RTL for all 3 protocols (ties to R12/V12) |
| F9 | Debug/trace readout tooling (decode trace buffer into human-readable log) | R9, F7 | Trace decoder script | Confirms decoded trace matches known injected event sequence |
| F10 | Firmware switch procedure tooling (halt->invalidate->load->verify->arm->start as one Pico command) | F6, R4 | Pico "switch_protocol" command | Confirms protocol switch completes and old program is fully overwritten (checksum verified) |

---

## Workstream 5 — Verification + Bring-up (ties everything together)

| ID | Task | Depends on | Deliverable | Validation |
|---|---|---|---|---|
| V1 | Formal safety proofs (V01-V03) | R1-R3 | SymbiYosys property files | All properties pass, no counterexamples |
| V2 | Full V01-V14 regression suite assembled | R11, F8 | Test suite | All 14 obligations have passing, reproducible tests |
| V3 | FPGA/gate-level smoke test plan (if FPGA available) | R11 | Test report | **Pulled forward** as R-FPGA: DE0-Nano is available; UART TX to a phone via HC-05 is the smoke test |
| V4 | Iteration loop: triage Gate-2 failures, re-run affected module + flow + firmware tests | V2, G4 | Bug list + fix commits | Each fix re-passes its original failing test plus full regression (no new regressions) |
| V5 | Bring-up stage 1-3: power/clock alive, ID echo, pin diagnostic (silicon or FPGA) | G6 (or FPGA equiv) | Bring-up log | Each stage passes before proceeding to next |
| V6 | Bring-up stage 4-5: memory BIST, trivial toggle program | V5 | Bring-up log | BIST reports zero faults; scope confirms pin toggling at expected rate |
| V7 | Bring-up stage 6-8: UART, then SPI, then I2C, each with Pico as host | V6, F2-F4, F10 | Bring-up log per protocol | Each protocol validated independently before moving to next; full chain (laptop->Pico->ASIC->target) exercised |
| V8 | Full chip validation: full regression + randomized/adversarial protocol tests (jitter, CPOL/CPHA sweep, NACK/stretch) | V2, V7 | Final validation report | Requirement-to-test mapping complete; no open V01-V14 items |

---

## Sequencing against the 12-week timeline

| Weeks | Primary focus | Status |
|---|---|---|
| 1-3 | Workstream 1 (A1-A8) -> Gate 1 | A1/A4/A5/A7 done; A2/A3 shape frozen |
| 4 | R1-R4, G1 start in parallel; F1 starts | R3/R4 done; R1 pending |
| 5-6 | R5-R7, G2 continuous; F2-F4 against simulator | R5/R6 done, F2 TX done, UART workload validated |
| **6-7** | **R-FPGA: DE0-Nano + Bluetooth bring-up** | next |
| 7-8 | R8-R10, G2 continuous; F5-F7 Pico tooling; V1 formal proofs start | |
| 9 | R11-R12, G4 first full-chip GDS; F8 cosim; V2 regression assembly -> Gate 2 | |
| 10-11 | V4 iteration loop (fix RTL/firmware/flow issues found at Gate 2) | |
| 12 | V8 full chip validation, G6 sign-off GDS | |

Post-tape-out (outside the 3-month window): V5-V7 staged bring-up with real
silicon and the Pico.

## Adding the second engine later

This plan assumes single engine only. When adding a second engine:

1. Repeat R5-R7 as a second parameterized instance.
2. Re-run R11/R12 integration and G4 full-chip GDS.
3. Re-run V2/V8 regression and validation.

This is a bounded add-on, not a restart of the whole plan, because the
management controller, pin ownership, trace, and safety logic are already
written generically for N engines.
