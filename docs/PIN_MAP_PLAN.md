# Pin mapping, spare-pin defaults and bring-up debug: plan (week 2, 2026-10-26 .. 11-01)

Status: **planned** (2026-10-18). Part of the plan to 2026-12-30 ([EXECUTION_PLAN.md](EXECUTION_PLAN.md)). Built before USB LS and the
logic analyser because both use it (the USB D+/D- pair, the capture inputs).

## 1. Goals

1. **Every pin except the management link can be used by protocols.** Debug and control functions are only the *defaults after
   reset*; once the chip is proven, a firmware user can take those pins for a future protocol.
2. **Bring-up without the SPI link:** if the management link does not work on silicon, the chip still shows that it is alive, what
   the SPI slave receives, whether the I/O paths and memories work, and it can be stopped safely.
3. **No instruction set change.** Each engine keeps 8 logical pins (the 3-bit pin fields of SETH, SETLO, DIRO, DIRI, OUT1, IN1,
   WAITH, WAITL, JPH, JPL, CFG); the pin manager maps them onto physical pins.
4. **Always recoverable:** reset restores the defaults; the management pins can never be remapped.

## 2. Pins

| Pins | Direction (Tiny Tapeout) | Fixed? | Default after reset | Can become |
|---|---|---|---|---|
| `ui_in[0]`, `[1]`, `[2]` | input | **fixed** | management SPI SCLK, MOSI, CS_N | - |
| `uo_out[0]` | output | **fixed** | management SPI MISO | - |
| `clk`, `rst_n`, `ena` | - | fixed (Tiny Tapeout) | - | - |
| `uio[7:0]` | in / out | | protocol pads, logical pin i = `uio[i]` for both engines (as today) | any logical pin of either engine |
| `ui_in[3]` | input | | **SAFE_N**: low = both engines held and every engine-driven pin released, in hardware | protocol input (after SAFE_N is disabled by a management write) |
| `ui_in[4]` | input | | **TRIG_IN**: external trigger of the logic analyser | protocol input |
| `ui_in[7:5]` | input | | **DBG_SEL**: selects the debug view | protocol inputs |
| `uo_out[1]` | output | | **IRQ**: attention to the host (maskable sources, section 5) | protocol output |
| `uo_out[7:2]` | output | | **debug view** (6 bits, section 4) | protocol outputs |

On the Tiny Tapeout demo board every `ui_in` / `uo_out` / `uio` pin reaches the RP2040 / RP2350 (and `uo_out` the 7-segment
display), so the defaults are usable without extra hardware.

## 3. Mapping (pin manager)

**Outputs.** Each output-capable physical pin (15: `uio[7:0]`, `uo_out[7:1]`) has a configuration word:
`owner[1:0]` (0 default function / none, 1 engine 0, 2 engine 1), `od` (open-drain), `lpin[2:0]` (which logical pin of the owner
drives it). For `uio` the default function is "not driven" (as today); for `uo_out[7:1]` it is the debug view / IRQ bit.
**Inputs.** Each engine has, per logical pin, an input select `isel[3:0]` choosing one of the 13 input-capable pins
(`uio[7:0]`, `ui_in[7:3]`). Inputs stay unmanaged: any engine may read any pin. Reset: `isel = i` (logical pin i reads `uio[i]`).
`uo_out` pins have no output enable (Tiny Tapeout drives them always): "released" means they fall back to their default function
(debug view bit or IRQ), never to an engine value.
**Rules kept from today:** a pin cannot be claimed or remapped while its current owner runs; owner code 3 is refused; violations
(a running engine enabling a logical pin that drives no owned physical pin) are flagged per engine.

Management address map (window `0x0200`, existing registers kept at their addresses):

| Address | Register | Change |
|---|---|---|
| `0x0200 + 4p`, p = 0..7 | PAD (uio p): `[1:0]` owner, `[2]` od, **`[5:3]` lpin (new)** | extended; lpin = p after reset, so today's writes keep working |
| `0x0220` | VIOL (W1C) | kept |
| `0x0240 + 4k`, k = 1..7 | OPAD (uo_out k): `[1:0]` owner (0 = default function), `[2]` od, `[5:3]` lpin | new |
| `0x0280 + 0x20*e + 4*i` (e = 0, 1; i = 0..7) | ISEL engine e, logical pin i: `[3:0]` physical input | new |
| `0x02C0` | MISC: `[0]` SAFE_N enable (1 after reset), `[1]` TRIG_IN enable, `[2]` DBG_SEL enable, `[15:8]` IRQ mask | new |
| `0x02C4` | IRQ status (W1C) | new |

## 4. Debug views (`uo_out[7:2]`, selected by `ui_in[7:5]`)

The views answer the bring-up questions that cannot wait for a working SPI link. With the link working, everything else is read
over SPI.

| View | Bits | Question | Priority |
|---|---|---|---|
| 0 (default) | heartbeat (clock / 2^25, about 1.5 Hz at 50 MHz), management error, RUN e0, RUN e1, halted-or-fault e0, halted-or-fault e1 | is the chip alive, out of reset, are the engines doing anything? | essential |
| 1 | last SPI byte received, bits [3:0], plus a toggle per received byte and a toggle per frame end | do SPI bits arrive, in order? | essential |
| 2 | last SPI byte received, bits [7:4], plus frame-clean flag and CS_N (synchronised) | completes view 1 | essential |
| 3 | loopback: `ui_in[7:3]` and `uio[0]` mirrored | do the input and output paths through the Tiny Tapeout mux work? | essential |
| 4 | memory self-test: running, done, pass e0, pass e1 (section 6) | do the SRAMs work, independent of SPI loading? | important |
| 5 | `uio[5:0]` input levels | is something pulling a pad? | useful |
| 6 | logic-analyser state: armed, triggered, full, buffer level [2:0] (filled in with the logic analyser) | | useful |
| 7 | reserved (later: engine PCs) | | - |

## 5. IRQ sources (`uo_out[1]`)

RX FIFO not empty (per engine), engine halted, engine fault, management error, logic-analyser trigger, logic-analyser buffer full,
pin violation. Level output = OR of (status AND mask); status bits are write-one-to-clear. Lets the host wait instead of polling.

## 6. Memory self-test

The SRAM macro has a BIST port that is tied off today. A small March C- sequencer per engine (in the held state only) drives it,
started by a management write or by DBG_SEL = 4 held for 2^16 clocks after reset (so it also runs without SPI). Result in view 4
and in a status register. Must not touch the functional port timing (the BIST port is separate).

## 7. Verification

- **Formal** (extends `formal/pin_mgr.sby`, `formal/mgmt.sby`): a physical pin is driven only by its owner through its mapping;
  the mapping and SAFE_N enable cannot change under a running owner; reset state = identity mapping and every default function;
  the management pins are never driven by an engine and never remapped; SAFE_N low (when enabled) releases every engine-driven pin
  in the same clock; IRQ = OR of masked status. Each with planted-bug checks (`formal/formal_mutants.py`).
- **Simulation:** directed tests of every register and view, random remapping with both engines running protocol firmware through
  remapped pins (UART on `uo_out` + `ui_in`, SPI split across pin groups), the existing 26 suites unchanged (identity mapping).
- **Model:** `host/isa_model.py` is unchanged (logical pins); the chip-level harness gets the mapping.

## 8. Cost and risk

About 1-2k cells (mapping multiplexers, 15 x 6 + 2 x 8 x 4 configuration bits, views, IRQ, BIST sequencers). The output mapping
sits after the engines' pin registers: one multiplexer level on the pad path, far from the ALU critical path. Risk: pad-path timing
to `uo_out` through the Tiny Tapeout mux (not in our STA); keep the mapping registered where possible.
