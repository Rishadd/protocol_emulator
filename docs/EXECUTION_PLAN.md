# Protocol Emulator ASIC — Execution Plan

Companion to [PROTOCOL_EMULATOR_ARCHITECTURE.md](PROTOCOL_EMULATOR_ARCHITECTURE.md) | 2026-09-27, revised 2026-10-11 |
Status: **two-engine RTL and SPI management link done in simulation; UART TX, RX and full duplex proven on the DE0-Nano; area study says instruction memory must move to SRAM; GDS flow not started**

Challenge deadline: **2027-01-18** (about 14 weeks from this revision). Target shuttle: March 2027 CMOS5L.

## Progress snapshot (2026-10-11)

| Done | Evidence |
|---|---|
| ISA frozen: 5-bit opcode + flat 27-bit operand, 17 opcodes | [../instructions.md](../instructions.md), `src/isa.vh` |
| Engine core, shifters, FIFOs, 8-pin block with 2-stage input synchronizer | `src/`, unit testbenches + `tb_engine_top` |
| Instruction-memory host write port and `run` gate (engine held in reset while loading) | `tb_instr_mem`, `tb_mgmt_frame` |
| **Second engine**, shared write bus, per-engine RUN, pad merge (engine 0 wins a shared pin) | `tb_mgmt_dual` |
| **Management link over SPI, frame v1** (7 bytes, no CRC yet): load programs, RUN/stop, TX push, RX pop, status, error flag | `tb_mgmt_frame`, `_load`, `_dual`, `_read`, `_tx`; see [MGMT_PLAN.md](MGMT_PLAN.md) |
| Full-duplex 1 KB UART through SPI (TX engine 0 + RX engine 1, live echo and replay, jitter and baud error) | `tb_mgmt_duplex` + `host/mgmt_duplex_stress.py`; results recorded in [../memory.md](../memory.md) (not part of `run_tests.ps1`, not re-run for this revision) |
| Firmware: UART TX (12 words), UART RX (9 words, level waits, no edge detect needed) | `src/fpga/uart_tx_prog.hex`, `uart_rx_prog.hex`, `host/uart_rx_prog.py` |
| **FPGA bring-up (DE0-Nano + HC-05)**: TX message received on a phone; RX byte shown on LEDs; **full-duplex echo at 115200** | `src/fpga/`, `quartus/`; commit "UART Full duplex mode working at 115200 baud rate with hardware" |
| Tiny Tapeout top `tt_um_protocol_emulator` (SPI pins on `ui_in[2:0]`/`uo_out[0]`, protocol pins on `uio`) | `src/tt_um_protocol_emulator.v` |
| **ASIC area study on the real CMOS5L library** (Yosys) | [ASIC_AREA_AND_MEMORY_STUDY.md](ASIC_AREA_AND_MEMORY_STUDY.md) |
| Regression: 16 testbenches PASS (re-run 2026-10-11). `tb_de0_nano_top` hangs, pre-existing, FPGA-only, excluded | `run_tests.ps1` |

**Changes of plan since the 2026-10-03 revision**

1. **Two engines are in, not deferred.** Full-duplex UART needed them, they were cheap to add, and the
   management link already drives both.
2. **The management frame is 7 bytes, not 12.** CRC-16, sequence numbers and pipelined responses were left out on
   purpose to get the data path proven first (see [MGMT_PLAN.md](MGMT_PLAN.md)). They are still a requirement before tape-out.
3. **Instruction memory in flip-flops cannot be the tape-out design.** Measured on the real cell library the two
   64x32 stores are 80 % of the chip (414k um^2 total, 57.5 % of the nominal 720k). SRAM (or a smaller store) is now a
   gating decision, and the first thing to settle with the organizers is whether the SG13G2 macros are accepted on
   CMOS5L.
4. **I2C open-drain**: the proposed `CFG` open-drain bit (an ISA change) is superseded by a per-pad open-drain mode
   in the planned pin-management block, which also provides pin ownership. Prototype area 5.2k um^2.
5. **UART RX needed no new opcode**: the 9-word program uses `WAITH`/`WAITL` level waits. `WAITR`/`WAITF` stay
   reserved but are no longer on any critical path.

## Scope decisions

- **Two engines for v1** (built). Independent TX/RX timing is the reason; more than two is out of scope.
- **Baseline protocol scope: UART, SPI, I2C.** UART is proven on hardware. SPI and I2C firmware are still drafts in
  [../instructions.md](../instructions.md) and have not been run against the RTL. Whether each fits the instruction
  memory is open until they are assembled (decides the SRAM macro choice).
- **JTAG, SWD, PS/2, CAN, USB low speed, 10 Mbit Ethernet remain a research spike**, not committed. A JTAG shift
  loop draft exists; arbitrary-length chains need host-streamed data.
- **Reference host**: a Raspberry Pi Pico (or the existing Python host models) bridges a laptop to the ASIC over SPI.
  Today's frame is the 7-byte v1 frame; the 12-byte CRC frame is the target.
- **Clock target**: the Tiny Tapeout template default is 20 ns (50 MHz). The DE0-Nano runs at 50 MHz. Whether the
  CMOS5L design closes timing at 50 MHz is unknown until a real flow run; 24 MHz remains the fallback.

## How the workstreams tie together

```mermaid
flowchart TB
    subgraph W1[Workstream 1: Architecture]
    A1-A9
    end
    subgraph W2[Workstream 2: RTL]
    R1-R13
    end
    subgraph W3[Workstream 3: GDS Flow]
    G0-G6
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

## Workstream 1 — Architecture

| ID | Task | Deliverable | Status |
|---|---|---|---|
| A1 | Freeze ISA opcode table | Opcode table | **DONE** — 17 opcodes, flat operand |
| A2 | Freeze register/CSR map | Register map | **Partly done.** Engine windows as built: `0x1000`/`0x2000` base, `+0x000` CTRL, `+0x100+4i` IMEM, `+0x200` TX, `+0x204` RX ([MGMT_PLAN.md](MGMT_PLAN.md)). Global (`0x0000`, `0x0100`), pin (`0x0200`), trace and test windows still reserved only |
| A3 | Freeze SPI host frame | Frame spec | **Interim v1 built** (7 bytes, big endian, no CRC, no sequence). Final 12-byte CRC frame still to freeze and implement |
| A4 | Pin map | Pin table | **DONE** as a firmware convention. Duplex build: TX on pin 0, RX on pin 1 |
| A5 | Code-size check against instruction memory | Word counts | UART TX 12, UART RX 9 (both measured); SPI 18, JTAG ~10 + walks (drafts). **I2C and anything larger not measured** |
| A6 | Scope: JTAG/SWD/CAN/USB/Ethernet = research spike | Scope doc | DONE |
| A7 | Interconnect spec | Signal table | **DONE** for engine and management ([diagram_core_internal.mmd](diagram_core_internal.mmd), `src/tt_um_protocol_emulator.v`) |
| A8 | Verification obligations assigned | Checklist | Per-obligation status in [WORKSTREAM1_ARCHITECTURE.md](WORKSTREAM1_ARCHITECTURE.md) A8 |
| **A9** | **SRAM decision**: confirm with Tiny Tapeout whether the SG13G2 SRAM macros are accepted on CMOS5L 6x4, then pick 4 x 1P 64x16 vs one shared 2P 256x32 | Decision note | **Open, top priority.** Evidence and numbers in [ASIC_AREA_AND_MEMORY_STUDY.md](ASIC_AREA_AND_MEMORY_STUDY.md) |

**Gate 1** (architecture settled enough to freeze RTL): A9 resolved and A3 final frame frozen. The rest is done.

---

## Workstream 2 — RTL

Detailed module status lives in [WORKSTREAM2_RTL_IMPLEMENTATION.md](WORKSTREAM2_RTL_IMPLEMENTATION.md).

| ID | Task | Status |
|---|---|---|
| R1 | Reset/abort safety-disarm latch (`ena`, abort pin, synchronized release) | Not built. The TT top has an async-assert/sync-release reset synchronizer, and `run`=0 or reset already release all pins. Formal proof (V01) pending |
| R2 | Pin ownership + electrical mode | **Prototype only** (`synth/experiments/pin_mgr.v`, 5.2k um^2, not simulated). Today a shared pin is simply "engine 0 wins". Open-drain becomes a per-pad mode here |
| R3 | Input synchronizer | **DONE** in `pin_block` (2-clock latency verified) |
| R4 | Instruction storage | **DONE for flops** with host write port and `run` gate; no parity. **R4d: SRAM wrapper** with next-PC fetch is the open item (A9) |
| R5 | Engine core | **DONE** (no ALU in the current ISA) |
| R6 | Shifters + FIFOs | **DONE** (32-bit OSR/ISR, 32 x 4 FIFOs). **R13: shrink the FIFOs** — four FIFOs are 41k um^2, the largest block after instruction memory |
| R7 | Timestamp/event fabric | Not built |
| R8 | Management controller + SPI | **Frame v1 DONE in simulation** (SPI slave, 2-engine load/run/TX/RX/status). Remaining: CRC-16, sequence numbers, ID/capacity registers, pin and global windows |
| R9 | Trace + first-fault | Not built |
| R10 | Memory BIST (March C-) | Not built (and changes with SRAM: macros need their own BIST path) |
| R11 | Top-level integration | **DONE for 2 engines + management** (`tt_um_protocol_emulator.v`) |
| R12 | Full-chip simulation of firmware against RTL | **UART TX, RX and full duplex DONE** (also through SPI). SPI/I2C pending their firmware |
| R-FPGA | DE0-Nano wrappers | **DONE**: TX (`de0_nano_top`), RX (`de0_nano_rx_top`), duplex echo (`de0_nano_duplex_top`) at 115200 on hardware |

---

## Workstream 3 — GDS Flow

Nothing here has been run. The flow has been **read, not executed**; see [ASIC_AREA_AND_MEMORY_STUDY.md](ASIC_AREA_AND_MEMORY_STUDY.md) §7.

| ID | Task | Status |
|---|---|---|
| **G0** | Yosys area/cell-count estimate on the real CMOS5L library (`synth/run_synth.sh`) | **DONE 2026-10-11.** Whole chip 414,137 um^2 with flop memory; 143,425 with 4 x 1P 64x16 SRAM. Pre-CTS, expect +10-25 % |
| G1 | Stand up the LibreLane/CMOS5L flow (template fork, `info.yaml`, `config.json`) on a small module | Not started. Needs a Linux or WSL environment |
| G2 | Re-run per module as it lands | Not started |
| G3 | Continuous flow re-run habit | Not started |
| G4 | First full-chip run, STA at the three corners | Not started. Blocked on A9 because macros change `config.json` and the PDN script |
| G5 | Area/timing check against the 6x4 budget | Partly answered by G0 (area). Timing unknown |
| G6 | Final sign-off run | Not started |

Also required before G1: put the RTL flat in the template's `src/`, keep `src/fpga` out, clean the 9 Verilator `-Wall` warnings, and port the checks that matter into cocotb (the template's gate-level job runs cocotb, not our Icarus testbenches).

---

## Workstream 4 — Firmware + Host tooling

| ID | Task | Status |
|---|---|---|
| F1 | ISA cycle model + assembler | **Partial.** `host/uart_workload.py` has the word encoder, a UART reference model and an independent receiver. A general per-opcode model is still needed for SPI/I2C differential tests |
| F2 | UART TX/RX firmware | **DONE and proven on hardware** (TX 12 words, RX 9 words) |
| F3 | SPI controller firmware | Draft ([../instructions.md](../instructions.md) §3), not simulated |
| F4 | I2C controller firmware | Draft primitives (§4). Open-drain `OUT1` is now planned as a pin-manager mode rather than a `CFG` bit; a conditional branch on a pin for ACK/NACK is still missing |
| F5 | Pico frame builder (op/addr/data, CRC-16) | The only host-side frame code today is the Verilog SPI master model (`tb/spi_master.vh`) and the pacing logic inside `tb_mgmt_*`; `host/mgmt_duplex_stress.py` just orchestrates runs and compares files. Pico/Python frame builder and CRC not started |
| F6 | Pico command dispatcher | Not started |
| F7 | Laptop control script | Not started |
| F8 | Firmware against RTL cosimulation | **UART DONE** (`tb_mgmt_*`, `tb_uart_*`). SPI/I2C pending |
| F9 | Trace readout tooling | Not started (needs R9) |
| F10 | Protocol-switch procedure (halt, load, verify, arm, run) | The primitives exist (RUN bit, write frames). Read-back verify becomes possible with SRAM |

---

## Workstream 5 — Verification + Bring-up

| ID | Task | Status |
|---|---|---|
| V1 | Formal safety proofs (V01-V03) | Not started. Pin-manager ownership proof is the first target |
| V2 | Full V01-V14 regression | Partial. 16 testbenches PASS; mapping obligations to tests is not done |
| V3 | FPGA smoke test | **DONE** — TX, RX and duplex on the DE0-Nano |
| V4 | Iteration loop | Ongoing |
| V5-V7 | Silicon bring-up (clock/ID/pins, BIST, protocols) | After tape-out. Procedure in the architecture doc §12 |
| V8 | Full-chip validation | Not started |

Lessons recorded so far (details in [../memory.md](../memory.md)): the RX input synchronizer reset to 0 looks like a
start bit (fixed in firmware by waiting for line idle first); testbench receivers must sample on clock edges because the pad
mux can glitch for zero time when a pin is enabled.

---

## Sequencing to the 2027-01-18 deadline (proposed)

| Weeks from 2026-10-11 | Focus |
|---|---|
| 0-1 | **A9**: ask Tiny Tapeout about CMOS5L SRAM. Measure SPI/I2C word counts. Set up WSL/Linux and the LibreLane template (G1) on a trivial module |
| 1-3 | Pick the memory option; build the SRAM fetch (R4d) with a behavioral macro model and re-run the full regression to prove the cycle contract. Pin manager (R2) RTL + testbench |
| 3-6 | Final management frame (CRC, sequence, ID, pin window). FIFO shrink. SPI and I2C firmware against RTL. Port key checks to cocotb |
| 6-9 | First full-chip LibreLane run (G4) and STA; fix timing and congestion; formal proofs V01-V03 |
| 9-12 | Trace/first-fault if area allows; gate-level test; precheck |
| 12-14 | Sign-off run (G6), documentation, submission package |

Post-tape-out: V5-V7 staged silicon bring-up.

## Adding more engines or features later

The second engine already exists, so the earlier "add a second engine" procedure is obsolete. Anything beyond two
engines needs an explicit area review: after SRAM the chip is about 20-25 % of nominal, so there is room, but pins (8) and
management bandwidth, not area, are the limits.
