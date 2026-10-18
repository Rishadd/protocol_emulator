# Logic analyser, protocol sniffer and engine debug: plan (weeks 5-7, 2026-11-16 .. 12-06)

Status: **planned** (2026-10-18). Part of the plan to 2026-12-30 ([EXECUTION_PLAN.md](EXECUTION_PLAN.md)). Builds on the pin mapping,
spare-pin defaults and bring-up debug of [PIN_MAP_PLAN.md](PIN_MAP_PLAN.md) (week 2).

## 1. Goals

The same chip that **speaks** protocols should be able to **listen to and record** them: the "hardware debugging and reverse
engineering" use the challenge text describes. Three parts:
1. a **logic analyser** (new hardware): records what the pins did, with timestamps and triggers;
2. a **protocol sniffer** (firmware on an engine): decodes a bus it does not drive and can trigger the analyser on a protocol
   condition;
3. **engine debug** over the management link: halt, single-step, breakpoint, read back all engine state.
Basis already in the design: both engines see every pin, also pins they do not own; the pin manager only controls who drives.

## 2. Logic analyser (capture unit)

| Aspect | Specification |
|---|---|
| Inputs | up to 16 channels: the 13 input-capable pins (`uio[7:0]`, `ui_in[7:3]`) after synchronisation, plus RUN of both engines and one software trigger line per engine |
| Change mode (default) | one 32-bit word per change: `{channels changed-to value, time since the previous word}`; long gaps produce an overflow word. A UART byte at 115200 baud is about 10 words |
| Sample mode | every N clocks (N programmable, 1 = 50 MHz) a sample of the selected 8 channels; four samples per word |
| Resolution | one clock, 20 ns at 50 MHz |
| Buffer | a **third SRAM macro, 256 x 32** (256 changes or 1,024 samples), placed and powered like the program memories (same Metal4 stripe bridge). Fallback if the macro causes trouble: a 32 x 32 flip-flop buffer |
| Trigger | any of: pattern (mask / value) on the channels, rising / falling edge on a chosen channel, TRIG_IN pin, software trigger from either engine (new instruction field or RPUT target), management write; with a delay counter |
| Pre / post trigger | ring buffer: records continuously until the trigger, then a programmed number of words more, then stops; the trigger position is kept |
| Readout | management window (new): status (armed, triggered, wrapped, write pointer, trigger position), configuration, and the buffer words; the debug view 6 shows armed / triggered / full |
| Host tool | `host/la_capture.py`: arm, wait (IRQ), read, write a **VCD** file for PulseView / sigrok (and for our own checks) |

## 3. Protocol sniffer (firmware)

- **New hardware, small:** a free-running 32-bit **timestamp counter** readable by firmware (new `RGET` source, 7) and an
  **engine-to-analyser trigger** (one bit an engine can set), so decoded events carry time and can fire a capture.
- **Firmware decoders** for buses the engine does not drive (its logical pins mapped as inputs only): I2C monitor (start, stop,
  address, data, ACK / NACK), SPI monitor (CS framing, mode 0-3), UART monitor (both directions), CAN monitor (our receiver
  without the ACK). Each pushes `{event type, data, flags}` words with timestamps into the RX FIFO.
- **Protocol triggers:** the decoder fires the analyser on a protocol condition, e.g. "the first NACK to I2C address 0x50" or "a CAN
  frame with a CRC error": the raw waveform around a protocol event, which commercial analysers sell as an option.
- **On-silicon self-test:** engine 0 drives a protocol, engine 1 sniffs and checks it, the analyser records the pins.

## 4. Engine debug over the management link

| Function | Specification |
|---|---|
| Halt / resume | exists (RUN bit) |
| Single step | a management write executes exactly one instruction of a halted (stepping) engine, with its normal clock count |
| Breakpoint | one PC breakpoint per engine: the engine stops before executing that address; status shows the hit |
| Read-back | registers R0-R7, flags, OSR, ISR, loop counter, delay counter, CRC value and configuration, FIFO levels, PC, state |
| Program read-back | read instruction memory words (verify a load) while the engine is held |
| Soft reset | per engine and whole chip (management write), in addition to `rst_n` |
| Frame v2 | CRC-16 and a sequence number on management frames (planned since the start, needed for reliable debug on a real board): done in week 3 with the pin-mapping registers |

## 5. Verification

- **Capture unit:** a Python model of the change / sample encoding; random pin activity, compare the decoded VCD with the stimulus
  exactly (every change, every timestamp); trigger and pre / post-trigger windows at the buffer edges.
- **Formal:** no change is lost or duplicated while the buffer has room, timestamps are monotonic, the trigger fires at most once
  per arming and the post-trigger count is exact, the analyser never drives a pin; engine debug: single-step executes exactly one
  instruction, a breakpoint stops before the instruction, read-back never changes state.
- **Sniffer:** the existing protocol peers drive the bus, the sniffer's decoded stream must match the peer's transcript; protocol
  triggers fire on exactly the planted condition.
- **Mutants** in all three parts; full regression; flow run (the third SRAM macro: placement, stripes, precheck).

## 6. Schedule and checkpoint

| Week | Work |
|---|---|
| 5 (Nov 16 - 22) | capture unit RTL + model + unit tests; timestamp counter and engine trigger |
| 6 (Nov 23 - 29) | third SRAM placement and flow run; readout window; host VCD tool; engine debug (step, breakpoint, read-back) |
| 7 (Nov 30 - Dec 6) | sniffer firmware (I2C, SPI, UART, CAN) and protocol triggers; formal; mutants |

**Checkpoint Nov 29:** if behind, cut to sniffer + engine debug + a small flip-flop buffer (no third SRAM), and keep the RTL
freeze on Dec 13.

## 7. Cost and risks

Capture unit about 2-3k cells plus the 256 x 32 SRAM (about 50k um^2, utilisation from about 41 % to about 46-50 % with USB and the
pin mapping). Engine debug about 1-2k cells (read-back multiplexers). Risks: a third macro in the floorplan (stripe alignment and
the halo rules found in tt8b / tt9b apply: whole stripe pitches, no sliver rows); GitHub build time (6 h limit) as the design grows.
