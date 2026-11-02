# 2. Design considerations: why the chip looks the way it does

> Based on the repository as of 31 October 2026 (`memory.md`, `docs/`, `src/`, `host/`, `formal/`, and the branches
> `submit/sh10-50mhz` and `submit/8la-43mhz`).

## The goals behind every choice

1. **Flexible.** The challenge says a new protocol after the chip is made must need only a new program.
2. **Small.** The design had to fit 6 x 4 Tiny Tapeout tiles (about 0.7 mm²). Later 8 x 4 was allowed (about 30 % more).
3. **Exact timing.** Protocols need pin changes at precise moments.
4. **Safe.** A buggy program must never damage the chip or fight another device on the wire.
5. **Provable.** The challenge stresses verification. The project rule: nothing counts until it is checked against something
   written independently.
6. **Fast enough.** Target: 50 MHz under worst-case conditions.

## The main choices

Each choice lists what it is, why it was chosen, how firmware uses it, and its good (+) and bad (−) sides.

**1. Programmable engines instead of fixed protocol blocks.**
*Why:* fixed UART, SPI and I2C blocks can never learn CAN or USB. The idea comes from the RP2040's PIO and TI's PRU.
*Firmware:* every protocol is a program, from 12 words (UART transmit) to 186 words (CAN receive).
\+ One chip, 13 protocols so far, and about 20 more estimated without any hardware change.
− Slower than a dedicated circuit, and every protocol needs its own program and tests.

**2. One instruction per clock tick, no interrupts, no cache.**
*Why:* protocols are all about timing. If timing never varies, you can calculate it on paper.
*Firmware:* timing maths is simple. `WAIT d` lasts `d + 1` ticks; a UART bit lasts `D + 2` ticks.
\+ Behaviour is exact clock for clock, so it can be compared with a model clock for clock.
− Top speed is limited. The fastest SPI slave is about 6.25 MHz at a 50 MHz clock.

**3. Two engines.**
*Why:* area. Two engines cover a transmit and receive pair, a master and a slave, or one protocol plus a "listener".
\+ Each engine has its own memory port, so one never delays the other's pin edges.
− Only two jobs at once.

**4. Registers, an ALU and a programmable CRC unit, all generic.**
*Why:* CAN, Modbus, USB, 1-Wire and SMBus need counting and checksums. A CRC done one bit at a time in software is too slow.
*Firmware:* the `CRC` instruction feeds bits or bytes; `RGET CRC` reads the result. One unit does any CRC (14 standard CRCs checked).
\+ Useful for future protocols too.
− More area. It also made the slowest path longer, so the CRC unit was given an extra pipeline step: `RGET CRC` straight after `CRC` waits one tick.

**5. A line coder for USB.**
*Why:* low-speed USB has only 33 ticks per bit at 50 MHz, too few to do its bit encoding (NRZI, bit stuffing) in instructions.
*Firmware:* the `LINE` instruction sends and receives whole bytes; the pins, bit period and stuffing rule are settings.
\+ Makes a USB device possible. − Extra area for a partly USB-specific block.

**6. An SRAM memory block instead of flip-flops.**
*Why:* a study on the real cell library showed that flip-flop memories were 80 % of the chip (414,137 µm², 57.5 % of 6 x 4).
SRAM blocks brought the chip down to 143,421 µm² (−65 %).
*Firmware:* no change. SRAM answers one tick late, so the program counter sends the *next* address early (`next_pc`).
− Memory blocks make the layout harder (power wiring, routing). See document 4.

**7. One shared 512-word memory with windows (decided 20 Oct 2026).**
*Why:* any mix of program sizes fits. A USB device that keeps its own descriptors needs about 320 to 380 words, which does not fit
in 256.
*Firmware:* the first instruction, `REGION`, declares the program's window; the host links the program at its address.
\+ Flexible, and a hardware "trap" stops a runaway program.
− One memory serves both engines, so wires are long. That cost about 1 ns of speed until a gate was moved into the engines.

**8. A pin manager with ownership, open-drain, re-routing and HOLD.**
*Why:* two engines share 8 pads, so they could fight. I2C must never drive a line high. Circuit boards differ.
*Firmware:* uses logical pins 0 to 7. The host decides which real pad each one uses, so the same program works on any pad
(tested with random pin layouts).
\+ Safety is mathematically proven. − It is the largest new block (about 2,960 gates). The host must claim pads before a run.

**9. An SPI management link with checked frames (version 2).**
*Why:* it needs only 4 pins. A flipped bit on the wire must never run a command twice or write the wrong word.
*Firmware:* data reaches the program only through the FIFOs.
\+ Robust: a retried frame is carried out exactly once.
− Bandwidth: one 32-bit word per frame, SPI clock at most about 3 MHz. An SPI slave or UART receiver cannot pause its partner if
the host is slow.

**10. One clock for everything; every input synchronised.**
*Why:* signals from outside can arrive at any moment. Two flip-flops in a row make them safe (they avoid "metastability"). The SPI
clock from the host is sampled like data, not used as a second clock.
*Firmware:* a pin read is 2 ticks old, and programs allow for it.
− The host must hold each SPI clock phase for at least 8 chip ticks.

**11. Small FIFOs (4 words) and an optional logic analyser.**
*Why:* area. The analyser is switched on with a build option (`-DLA`) and never touches the instruction fetch path.
− Candidate B, which includes the analyser, reaches only about 44.6 MHz instead of 50.7 MHz.

## Ideas that were tried and dropped

| Idea | What happened |
|---|---|
| Flip-flop program memory | far too big; replaced by SRAM |
| An extra fetch pipeline stage | verified, but 0.6 ns *slower*; kept on branch `exp/fetch-stage`, not merged |
| 6 x 4 tiles | did not route after pin re-routing and the line coder were added (+27 % cells); moved to 8 x 4 |
| A private 256-word memory per engine | worked, but the shared memory is more flexible |
| A special USB transmit instruction (`TXW`) | dropped for the "packet shuttle" design |
| Delay-oriented synthesis, repair after routing | slower or bigger; not used |

## Testability: built to be checked

![Verification layers](../docs/images/fig_verification_layers.svg)

*Figure 1. Each layer of testing catches mistakes the others cannot.*

### Before manufacturing (simulation and maths)

| Design feature | How it makes testing possible |
|---|---|
| Exact timing (choice 2) | A separate Python model (`host/isa_model.py`) predicts every tick. Random programs run on the real design and on the model: 0 differences. |
| Protocols are firmware (choice 1) | Each protocol is tested against an "other side" written separately from the official standard (an I2C memory, a CAN node, a USB host ...). |
| Logical pins (choice 8) | The same protocol tests run again with random pin layouts and with programs moved to other addresses. |
| Simple safety rules (choices 7, 8, 9) | Proven for every possible input with **6 formal proofs** (pin manager, FIFO, management link, engine, memory windows, `REGION`). |
| Frame version 2 (choice 9) | Random bit flips are injected; a damaged frame must never execute (236 checks). |
| Everything goes through SPI | Whole protocol tests run again at chip level, with the host using only the management link. |

On top of this comes **mutation testing**: deliberately broken copies of the design ("mutants"). A test is trusted only if it
catches every one. Examples: 38/38 engine bugs, 20/20 frame bugs, 16/16 shared-memory bugs, 12/12 analyser bugs, 47 bugs in the
formal proofs. The latest full run (30–31 October) passed **70 of 70** test suites.

### After manufacturing (test hooks inside the chip)

- **ID, VERSION and SCRATCH registers:** prove the link works before any program is loaded.
- **STATUS byte** in every reply, and **ERRCNT**, which counts bad frames.
- **Read-back** of every program word and of each engine's window.
- **Debug views** on `uo_out[7:2]` (heartbeat, run, halt, fault ...), chosen with 3 input pins. They work even without SPI.
- **IRQ** pin, and the **HOLD** pin as an emergency stop.
- **Self-test with two engines:** engine 0 speaks a protocol while engine 1 listens and checks it.
- **Logic analyser, `TSTAMP` and the trigger line** (candidate B).
- A **gate-level test** runs the same checks on the final circuit netlist.

### Honest gaps

- No scan chains and no built-in memory self-test (factory-style tests). The original architecture document proposed them; they
  were not built.
- No single-step or breakpoint for engines yet (logic analyser plan, phase 4).
- No firmware timeouts: a stuck bus waits until the host stops the engine.

**Read more:** [../memory.md](../memory.md) (history and every decision), [../docs/TEST_RESULTS.md](../docs/TEST_RESULTS.md),
[../formal/README.md](../formal/README.md), [../docs/ASIC_AREA_AND_MEMORY_STUDY.md](../docs/ASIC_AREA_AND_MEMORY_STUDY.md).
