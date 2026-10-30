# Protocol Emulator ASIC — Execution Plan

Companion to [PROTOCOL_EMULATOR_ARCHITECTURE.md](PROTOCOL_EMULATOR_ARCHITECTURE.md) | 2026-09-27, revised 2026-10-11 |
Status (2026-10-12, superseded by the table below): **two engines, SRAM instruction memory, pin manager and SPI management link done in simulation; UART TX/RX/duplex proven on the DE0-Nano; SPI master+slave and I2C master verified in simulation (engine, full chip, concurrent); chip 150k um^2 (20.8 %) after synthesis; GDS flow not started**

## Status 2026-10-18 (current; everything below this section is the 2026-10-11 snapshot, kept as the record of earlier decisions)

| Item | State | Where |
|---|---|---|
| Instruction set | 28 opcodes: the 21 old ones plus `LDI`, `ALU`, `JCC`, `RGET`, `RPUT`, `WAITR`, `CRC` | [../instructions.md](../instructions.md) |
| ALU (8 x 32-bit registers, 13 functions, flags) and programmable CRC unit | done; CRC unit pipelined, ALU with two register read ports (timing); random differential test 0 mismatches, 75/75 coverage points, all planted bugs caught | [TEST_RESULTS.md](TEST_RESULTS.md) sections 2-3, 8.4 |
| Instruction memory | IHP SRAM macro, 256 x 32 per engine | [BIGMEM_RESULTS.md](BIGMEM_RESULTS.md) |
| Protocols as firmware | UART, SPI (4 modes), I2C master + slave, SMBus PEC, Modbus RTU, 1-Wire, JTAG, CAN 2.0A, all against peer models; USB low speed planned (weeks 2-4) | [TEST_RESULTS.md](TEST_RESULTS.md) section 4 |
| Regression | 26 of 26 suites pass (`python host/regress.py`) | [TEST_RESULTS.md](TEST_RESULTS.md) |
| Tiny Tapeout flow | **tapeout candidate tt10c**: signed off at **50 MHz in all corners** (pipelined CRC unit, two register read ports), compact symmetric floorplan with one fence per engine, 0 DRC / 0 LVS, TT precheck and gate-level test pass, IR drop 0.2 mV. Local flow now uses Tiny Tapeout's PDK and LibreLane release (reproduces the GitHub build exactly) | [TEST_RESULTS.md](TEST_RESULTS.md) section 8.4 |
| Formal | 4 unbounded SymbiYosys proofs (pin manager, FIFO, management end to end from the SPI pins, held engine releases pins), 20/20 planted bugs rejected | [../formal/README.md](../formal/README.md) |
| Repository | public; `main` pushed; GitHub `test` and `docs` workflows pass; `gds` workflow: global placement diverged with the action's tools, fix under test (branches `ci/gpl-phi`, `ci/gpl-noroute`) | GitHub Actions |
| Open | shuttle acceptance of the SRAM macro on CMOS5L (A9: strong evidence it is fine: Tiny Tapeout allow-listed the SRAM layers in the CMOS5L precheck, and other entries pass the official build with it; email drafted); management frame v2 (CRC, sequence number); FPGA bring-up beyond UART | [CHALLENGE_CHECK.md](CHALLENGE_CHECK.md) |

Challenge deadline: **2027-01-18**. **Working deadline: 2026-12-30** (design, verification and signoff GDS finished; January only for
documentation and the submission package). Target shuttle: March 2027 CMOS5L.

## Progress 2026-10-19 (weeks 1-4 of the plan below are ahead of schedule)

| Item | State |
|---|---|
| GitHub `gds` placement fix | `PL_MAX_PHI_COEFFICIENT 1.03` (branch `ci/gpl-phi`: gds, precheck, gl_test, test, docs pass; only the `viewer` job fails, GitHub Pages setting); on `main` |
| Pin mapping (week 2) | built: remap of 15 output pins, input select, HOLD, IRQ, debug views 0-3 and 5; 22/22 testbenches, formal 18+7 properties, 34/34 planted bugs caught; remapped-pin protocol suites (phase D) pass |
| Software SPI host | `host/chip_host.py`, `chip_host_demo.py`, [HOST_INTERFACE.md](HOST_INTERFACE.md) |
| USB line coder (weeks 2-3) | built and verified ([LINE_CODER.md](LINE_CODER.md)) |
| USB device (weeks 3-4) | packet-shuttle firmware (209 words) + host software enumerates a HID keyboard on the model and on the RTL against an independent host peer model ([USB_LS_PLAN.md](USB_LS_PLAN.md)); firmware mutants and flow run pending |
| 8x4 floorplan (run tt14b) | the new RTL does not route on 6x4 (tt14a, GRT-0228); the **three-column 8x4 layout routes**: 0 DRC, LVS clean, slow-corner setup **+1.69 ns** at 20 ns (hold +0.10 ns, no violations in the three corners), 24,867 std cells (356k um2, 32 % of the die); Tiny Tapeout precheck **passes**; on `main` (`info.yaml` 8x4, `src/config.json`) |
| GitHub workflows | `main` pushed at `8795248` (2026-10-19): `test` and `docs` pass; `gds` was building at the time of writing (results below when it ends); the `viewer` job needs GitHub Pages set to "GitHub Actions" |
| Formal | all four proofs pass on `main` and on the frame v2 branch (pin_mgr, fifo, mgmt, engine); 34/34 planted bugs caught on `main` ([formal/README.md](../formal/README.md)) |
| Management frame v2 | built on branch `feat/frame-v2` (CRC-16, sequence numbers, retry that returns the older result); 4/4 proofs pass; 20/20 RTL mutants caught before the last simplification (the redundant `last_seq` register was removed; rerun in progress); not merged |
| Shared 512-word instruction memory | branch `feat/shared-imem` (see SHARED_IMEM_PLAN.md there): one 2P 512x32 macro, physical PC, per-engine window set by firmware (`OP_REGION`, once per run), START register; chip-level test passes on the RTL; first layout (L-shaped engines, run sh2) congested (54 % routing demand, 5,726 overflow); compact-column layout (run sh3) has the same routing demand as tt14b (32 %, zero overflow) but failed LVS (power stripes did not match the 2P macro's power columns); run sh4 with the matched grid (53.04 / 6.74 / 18.545) is **LVS clean, 0 DRC, TT precheck passes**, slow-corner setup -1.45 ns at 20 ns (about 46.6 MHz), results in results/tt_flow_2026-10-20/sh4_final; not merged (decision open) |
| Differential test | RTL and model agree on every program (0 mismatches, 33/33 mutants caught); a coverage count (RGET from the TX FIFO, 28 of 30) was short after a generator change, so the default is now 900 programs |
| Environment | real Python 3.12 installed on Windows; all regression suites run there; WSL is used for the flows and the proofs; each flow runs in its own window; the WSL VM stops when idle and kills its jobs |
| Open | regression 2026-10-19c (full, Windows) in progress; the `gds` / `precheck` / `gl_test` results on GitHub; timing is no longer open on the 8x4 layout (tt14b +1.69 ns) |

## Plan to 2026-12-30 (agreed 2026-10-18)

New features: **USB low speed** ([USB_LS_PLAN.md](USB_LS_PLAN.md)) and the **logic analyser, protocol sniffer and engine debug**
([DEBUG_LA_PLAN.md](DEBUG_LA_PLAN.md)), on top of **pin mapping, spare-pin defaults and bring-up debug** ([PIN_MAP_PLAN.md](PIN_MAP_PLAN.md)).
Chosen after reviewing the public entries: the strongest ones show USB LS, broad protocol lists and checked timing.

| Weeks | Dates | Work | Done when |
|---|---|---|---|
| 1 | Oct 19 - 25 | GitHub `gds` green (placement fix), commit formal + toolchain alignment; email Tiny Tapeout (SRAM confirmation, 8x4); the three specs reviewed | baseline green in CI |
| 2 | Oct 26 - Nov 1 | **pin mapping** + SAFE_N / IRQ / debug views 0-4 + memory self-test, with formal; USB **line coder** RTL + `LINE` opcode | every pin except the management link remappable; line coder unit-tested |
| 3 | Nov 2 - 8 | USB host peer model, packet layer and control transfers; **management frame v2** (CRC-16, sequence number) | |
| 4 | Nov 9 - 15 | USB enumeration + HID reports against the peer, mutants, flow run; start SWD / PS/2 / WS2812 | USB LS device verified; 50 MHz still closes |
| 4-5 | Nov 9 - 22 | **SWD, PS/2, WS2812** firmware with peer models and mutants | 13 verified protocols |
| 5-7 | Nov 16 - Dec 6 | **logic analyser** (third SRAM), timestamp counter, engine debug (step, breakpoint, read-back), **sniffer** firmware and protocol triggers | verified against models, formal, flow run |
| 7 | Nov 30 - Dec 6 | **automated mutation campaign** (generated faults, kill rate) and a **timing checker** built on `Asm.arrivals` (firmware bit times proven) | numbers in TEST_RESULTS |
| 8 | Dec 7 - 13 | **RTL freeze Dec 13**; FPGA demos: USB keyboard on a PC, a capture opened in PulseView | freeze tagged |
| 9-10 | Dec 14 - 27 | final flow runs (Tiny Tapeout's tools), GitHub `gds` / `precheck` / `gl_test` green, full regression, formal suite, release tag | submission-ready GDS from the official workflow |
| - | Dec 28 - 30 | buffer | |
| - | January | documentation and submission package | |

Rules: every feature gets the same verification standard (peer model from the specification, mutants, regression, formal where it
fits) and a flow run that must still meet 50 MHz; new hardware stays off the ALU critical path. **Checkpoint Nov 29:** if the logic
analyser is behind, cut it to sniffer + engine debug + a flip-flop buffer and keep the freeze date. Risks and fallbacks are in the
three specs (third SRAM macro, USB turnaround in firmware, the GitHub build's 6-hour limit).

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
4. **I2C open-drain**: done as a per-pad open-drain mode of the pin manager (`src/pin_mgr.v`, built 2026-10-11,
   3.7k um^2), which also provides pin ownership. No ISA change was needed for open-drain.
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
| A5 | Code-size check against instruction memory | Word counts | UART TX 12, UART RX 9, SPI master 17/18, SPI slave 18/16 (CPHA 0/1) (all measured); JTAG ~10 + walks (draft). **I2C and anything larger not measured** |
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
| R2 | Pin ownership + electrical mode | **DONE in simulation** (`src/pin_mgr.v`, 3.7k um^2): owner per pad, claim refused while running, per-pad open-drain, violations; `tb_pin_mgr`, `tb_mgmt_pins`. Diagnostic owner and remap not built |
| R3 | Input synchronizer | **DONE** in `pin_block` (2-clock latency verified) |
| R4 | Instruction storage | **DONE with SRAM in simulation** (2 x IHP 1P 64x16 per engine, next-PC fetch, `tb_fetch_equiv` 0 mismatches; [SRAM_INSTR_MEM_RESULTS.md](SRAM_INSTR_MEM_RESULTS.md)); no parity. Open: CMOS5L acceptance of the macro (A9) |
| R5 | Engine core | **DONE** (no ALU in the current ISA) |
| R6 | Shifters + FIFOs | **DONE** (32-bit OSR/ISR, 32 x 4 FIFOs). **R13: shrink the FIFOs** — four FIFOs are 41k um^2, the largest block after instruction memory |
| R7 | Timestamp/event fabric | Not built |
| R8 | Management controller + SPI | **Frame v1 DONE in simulation** (SPI slave, 2-engine load/run/TX/RX/status). Remaining: CRC-16, sequence numbers, ID/capacity registers, pin and global windows |
| R9 | Trace + first-fault | Not built |
| R10 | Memory BIST (March C-) | Not built (and changes with SRAM: macros need their own BIST path) |
| R11 | Top-level integration | **DONE for 2 engines + management** (`tt_um_protocol_emulator.v`) |
| R12 | Full-chip simulation of firmware against RTL | **UART TX, RX and full duplex DONE** (also through SPI). **SPI master + slave, 4 modes, DONE** through the management link (`tb_spi_chip`). **I2C master DONE** (`tb_i2c_chip`); SPI + I2C concurrently (`tb_combo_chip`) |
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
| F3 | SPI controller firmware | **DONE in simulation**: master and slave, modes 0-3, 1-32 bits, both bit orders (`host/spi_prog.py`, [SPI_PLAN.md](SPI_PLAN.md)). New opcodes `JPH`/`JPL` |
| F4 | I2C controller firmware | **Master DONE in simulation** (`host/i2c_prog.py`, 46 words, 100/400/1000 kHz, [I2C_RESULTS.md](I2C_RESULTS.md)); uses `JPO`/`PUSHI` and pin-manager open-drain. **Slave deferred**: ~64-67 words vs 64 ([I2C_PLAN.md](I2C_PLAN.md) §6.4.1) |
| F5 | Pico frame builder (op/addr/data, CRC-16) | The only host-side frame code today is the Verilog SPI master model (`tb/spi_master.vh`) and the pacing logic inside `tb_mgmt_*`; `host/mgmt_duplex_stress.py` just orchestrates runs and compares files. Pico/Python frame builder and CRC not started |
| F6 | Pico command dispatcher | Not started |
| F7 | Laptop control script | Not started |
| F8 | Firmware against RTL cosimulation | **UART DONE** (`tb_mgmt_*`, `tb_uart_*`). **SPI DONE** (`host/spi_test.py`, [SPI_RESULTS.md](SPI_RESULTS.md)). **I2C master DONE** (`host/i2c_test.py`). Workload campaign through the link: `host/workload.py`, [WORKLOAD_RESULTS.md](WORKLOAD_RESULTS.md) |
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
