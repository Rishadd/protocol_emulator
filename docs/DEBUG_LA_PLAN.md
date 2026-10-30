# Logic analyser, protocol sniffer and engine debug: implementation and verification plan

Status: **planned, revised 2026-10-20** for the shared 512-word instruction memory as the base of the chip (decision 2026-10-20). Starts after the shared-memory
software ([SHARED_IMEM_SOFTWARE_PLAN.md](SHARED_IMEM_SOFTWARE_PLAN.md)) is done, because the sniffer firmware is an image loaded through that host layer.
Part of the plan to 2026-12-30 ([EXECUTION_PLAN.md](EXECUTION_PLAN.md)); builds on the pin mapping of [PIN_MAP_PLAN.md](PIN_MAP_PLAN.md).

## 1. Goal and scope

The chip that **speaks** protocols should also **listen to and record** them (the "hardware debugging and reverse engineering" use in the challenge text):

1. a **logic analyser** (new hardware): records what the pins did, with timestamps and triggers, and hands it to the host as a VCD file;
2. a **protocol sniffer** (firmware, an image in the shared memory): decodes a bus it does not drive and can trigger the analyser on a protocol condition;
3. **engine debug** over the management link: halt, single-step, breakpoint, read back all engine state.

Out of scope: analog capture, more than 16 channels, compression, streaming capture above the management link's rate (the buffer absorbs bursts).

## 2. Decisions (to confirm at the start of Phase 1)

| # | Decision |
|---|---|
| D1 | New hardware stays off the ALU / fetch critical path: the capture unit reads the synchronised pins and writes its own memory; it never touches fetch. |
| D2 | **Buffer = a third SRAM macro**, 1P 256x32 (`RM_IHPSG13_1P_256x32_c2_bm_bist`, already in `macro/`, 49.5k um2), placed top centre opposite the shared instruction macro and powered through the same Metal4 stripe bridge. Fallback if it costs timing or routing: a 32x32 flip-flop buffer. |
| D3 | **Timestamp access is a new opcode, not an `RGET` source**: all eight `RGET` sources are in use (`RG_FIFO` = 7). Opcode 30 `TSTAMP rd` (R[rd] <= 32-bit free-running counter); 31 stays a reserved trap. The model, assembler and differential test get the opcode with it. |
| D4 | The analyser samples the same 13 input-capable pins the engines see, after the 2-flop synchroniser (so a capture is what the firmware would have seen): channels 0-7 = `uio[7:0]`, 8-12 = `ui_in[7:3]`, 13 / 14 = RUN of engine 0 / 1, **15 = the OR of the two engines' trigger lines** (a firmware marker shows up in the waveform and is also the software trigger). 16 channels in all. |
| D5 | Change-mode words are `{values[15:0], delta[15:0]}`; a gap above 65,535 clocks produces an overflow word. Sample mode packs four 8-bit samples per word. |
| D6 | Engine debug uses frame v2 (CRC-16, sequence numbers): a single step must never execute twice because of a retried frame. |

## 3. Logic analyser (capture unit, `src/la_unit.v`)

| Aspect | Specification |
|---|---|
| Inputs | 16 channels (see D4) |

The exact behaviour (word formats, overflow word, trigger and post-trigger rules, readout order, status) is `host/la_model.py` (Phase 1, done: self-test with 300 random captures); the RTL is checked against that model clock by clock.

| Change mode (default) | one word per change; a UART byte at 115200 baud is about 10 words |
| Sample mode | every N clocks (N programmable, 1 = every clock), selected 8 channels |
| Resolution | one clock |
| Buffer | ring buffer in the third macro (256 changes or 1,024 samples) |
| Trigger | pattern (mask / value), rising / falling edge on a channel, TRIG_IN pin, software trigger from either engine (a `RPUT` target), management write; with a delay counter |
| Pre / post trigger | records continuously until the trigger, then a programmed number of words, then stops; trigger position kept |
| Readout | management window (new, next to the pin window): status (armed, triggered, wrapped, write pointer, trigger position), configuration, buffer words; debug view 6 shows armed / triggered / full |
| Host tool | `host/la_capture.py`: arm, wait for IRQ, read, write a **VCD** for PulseView / sigrok |

## 4. Protocol sniffer (firmware images in the shared memory)

- **Hardware, small:** the timestamp counter (D3) and an engine-to-analyser trigger bit.
- **Decoders** for buses the engine does not drive (its logical pins mapped as inputs): I2C monitor, SPI monitor (modes 0-3), UART monitor, CAN monitor (our receiver without the ACK), USB low-speed monitor (line coder receiver). Each pushes `{event type, data, flags, timestamp}` words into the RX FIFO.
- **Protocol triggers:** a decoder fires the analyser on a condition ("first NACK to I2C 0x50", "CAN frame with a CRC error"): the raw waveform around a protocol event.
- **On-silicon self-test:** engine 0 drives a protocol, engine 1 sniffs it and checks it, the analyser records the pins.
- The two sniffers can be loaded at different origins of the shared memory; a sniffer of 150 to 250 words fits next to a protocol image.

## 5. Engine debug over the management link

| Function | Specification |
|---|---|
| Halt / resume | exists (RUN) |
| Single step | a management write executes exactly one instruction of a halted engine with its normal clock count |
| Breakpoint | one PC breakpoint per engine; the engine stops before executing that address; status shows the hit |
| Read-back | registers R0-R7, flags, OSR, ISR, loop counter, delay counter, CRC value and configuration, FIFO levels, PC, line-coder state |
| Program read-back | instruction words while the engine is held (from the shared-memory software, S1) |
| Soft reset | per engine and whole chip |

## 6. Verification (same method as the other modules)

- **Models first:** `host/la_model.py` (change / sample encoding, triggers, ring buffer) written from this page; a sniffer decoder oracle from the existing peer models.
- **Capture unit:** random pin activity; the decoded VCD must equal the stimulus exactly (every change, every timestamp); trigger and pre / post windows at the buffer edges; sample mode at N = 1..16.
- **Formal (SymbiYosys):** no change lost or duplicated while the buffer has room; timestamps monotonic; trigger fires at most once per arming and the post-trigger count is exact; the analyser never drives a pin; single-step executes exactly one instruction; a breakpoint stops before the instruction; read-back never changes state.
- **Sniffer:** the existing peers drive the bus; the decoded stream must equal the peer's transcript; triggers fire on exactly the planted condition.
- **Mutants** in all three parts; full regression; flow run (third macro: placement, stripes, precheck).

## 7. Phases (each must pass before the next; `memory.md` updated at the end of each)

| Phase | Work | Tests | Pass criteria |
|---|---|---|---|
| **0 Prerequisites** | shared-memory software done; frame merged; decision D2/D3 confirmed | regression green | baseline recorded |
| **1 Spec + models** | `la_model.py`, VCD writer, `TSTAMP` in `isa_model` / `asm.py` | model self-test, VCD round trip | model agrees with this page |
| **2 Capture unit RTL** | `src/la_unit.v`, buffer wrapper (macro + flip-flop variant), unit bench | `tb_la_unit`: random activity, triggers, pre / post, sample mode, overflow word | 0 mismatches against the model |
| **3 Integration** | management window, IRQ, debug view 6, `TSTAMP` opcode, engine trigger | chip-level test through the SPI link; `isa_diff_test` with `TSTAMP` | VCD from the chip equals the stimulus |
| **4 Engine debug** | step, breakpoint, read-back | `tb_engine_debug`, differential test with stepping | step = one instruction exactly, no state change on read-back |
| **5 Sniffers** | I2C / SPI / UART / CAN / USB monitors as images | each peer drives, sniffer transcript equals peer transcript; protocol triggers | all transcripts match, triggers exact |
| **6 Formal + mutants** | proofs of section 6; mutants | SymbiYosys, mutant runs | proofs pass, 100 % of mutants caught |
| **7 Flow** | third macro floorplan, stripes, precheck | LibreLane run | LVS clean, 0 DRC, precheck passes, timing not worse than the base layout |
| **8 Host tool + demo** | `la_capture.py`; capture of a UART / I2C exchange opened in PulseView | on the RTL, then on the FPGA | VCD opens and decodes in PulseView |

## 8. Negative cases (must be detected or handled without loss)

- trigger before arming, arming twice, readout while capturing (refused or ordered by the status bits);
- buffer wrap (oldest words overwritten, `wrapped` set, trigger position kept);
- gap longer than the delta field (overflow word);
- management read of an empty buffer, a frame retry during step (exactly once);
- sniffer on a bus with a glitch (decoder reports a framing event, no hang).

## 9. Documentation and memory

| When | Update |
|---|---|
| End of each phase | `memory.md` (result, numbers, problems); this page's status |
| Phase 3 | `instructions.md` (opcode 30), architecture ISA rows, `HOST_INTERFACE.md` (new window) |
| Phase 7 | `TEST_RESULTS.md`, `TT_FLOW_RESULTS.md`, area table |
| Phase 8 | `README.md`, `docs/LA_RESULTS.md` |

## 10. Cost and risks

| Risk | Mitigation |
|---|---|
| A third macro in a floorplan that already has the 685 um shared macro | place it top centre, whole stripe pitches, 17 um halo (rules from tt8b / tt9b); keep the flip-flop buffer as fallback |
| Timing: the capture unit adds load on the synchronised pins | it taps after the synchroniser, no fan-out into the fetch loop (D1); check in the flow run |
| Schedule: Phases 2-5 are about three weeks | checkpoint Nov 29: if behind, cut to sniffer + engine debug + a flip-flop buffer, keep the RTL freeze on Dec 13 |
| GitHub build time (6 h limit) as the design grows | the sh4 flow took about 1.5 h; watch it |

Cost: capture unit about 2-3k cells plus the 256x32 macro (about 50k um2; utilisation about 42 % to about 47 %), engine debug about 1-2k cells.
