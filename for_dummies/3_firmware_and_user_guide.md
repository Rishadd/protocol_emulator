# 3. Firmware: how it works, what is left, and a quick user guide

> Covers every branch on GitHub up to 31 October 2026. The user guide below needs a submission branch
> (`git checkout submit/sh10-50mhz` or `submit/8la-43mhz`): the files `host/shmem_host.py`, `host/fpga_bringup.py`,
> `host/serial_link.py`, `host/pico_bridge.py`, `host/la_capture.py` and `quartus/pe_chip.qpf` are not on `main` yet.

## What "firmware" means here

Firmware is a list of 32-bit numbers. Each number is one instruction for an engine. Nobody types the numbers by hand: programs are
written in Python with the assembler `host/asm.py`. Each protocol has a **generator**, `host/<protocol>_prog.py`, that takes
settings (baud rate, SPI mode, clock frequency ...) and produces the words.

## The life of a program

![Load sequence](../docs/images/fig_load_sequence.svg)

*Figure 1. How the host loads and starts a program (submission branches).*

1. **Generate** the words in Python.
2. **Link** the program at an address (its *origin*) in the 512-word memory. `host/shmem_host.py` checks that two programs do not
   overlap before anything is sent.
3. **Hold** the engine (CTRL = 0). Only a held engine can be loaded.
4. **Write** the words to `0x0400 + 4*w`, then **read them back** and compare.
5. Write **START** = the origin, then **RUN** = 1.
6. The program's first instruction, **`REGION`**, locks its window. The host reads the window back to check it.
7. The host and the program swap data through **TX_DATA** and **RX_DATA**. The program ends with `HALT`, or the host stops it.

![Engine states](../docs/images/fig_engine_states.svg)

*Figure 2. An engine is held, running, halted or in fault. RUN = 0 always brings it back to held.*

## How firmware differs between branches

| Branch | Where a program goes | Instructions | Notes |
|---|---|---|---|
| `main` | its own engine's 256-word memory, at `0x1000/0x2000 + 0x400 + 4*i` | 29 (opcodes 0–28) | no `REGION`; programs can start at any word (`FW_ORG`) |
| `two-tier` (13 Oct, not merged) | 64-word L1 per engine + shared 256-word L2 | adds `COPY` (L2 to L1) | a resident library let the engine install UART, SPI or I2C from L2 by itself; first version of the I2C slave |
| `shared/on-v2`, `submit/*` | one shared 512-word memory, physical address `0x0400 + 4*w` | 31 (adds `REGION`, `TSTAMP`) | `shmem_host.py` requires `REGION` first (without it the window is the whole memory); engine 1's programs usually start at word 256 or above |

The protocol generators were not rewritten for the shared memory: the assembler (`words_at`) or the test harness moves a program
to its address and fixes its jump targets.

## A real program, line by line: the UART transmitter

This is the verified 12-instruction transmitter from [../instructions.md](../instructions.md). On the shared-memory chip a
`REGION` instruction goes in front of it.

| Instruction | What it does in plain words |
|---|---|
| `CFG 0` | use pin 0 for output, send the lowest bit first |
| `DIRO 0` | start driving pin 0 |
| `SETH 0` | line high: the "idle" state of a UART |
| **loop:** `PULL` | wait until the host has put a byte in the TX FIFO, then take it |
| `SETL 8` | loop counter = 8 (eight data bits) |
| `SETLO 0` | line low: the start bit |
| `WAIT D` | hold for the rest of the bit time |
| **bit:** `OUT1 D` | put the next bit on the pin and hold it |
| `DJNZ bit` | count down; repeat until 8 bits are sent |
| `SETH 0` / `WAIT D` | line high for one bit time: the stop bit |
| `JMP loop` | go and wait for the next byte |

**Timing maths:** one bit lasts `D + 2` ticks. At 50 MHz and 115,200 baud: 50,000,000 / 115,200 ≈ 434 ticks, so `D = 432`.
The real rate is 115,207 baud, an error of only +0.006 %. For another clock, the generator simply recomputes `D`.

## The toolbox firmware uses

| Group | Instructions |
|---|---|
| Flow | `NOP`, `WAIT`, `JMP`, `HALT`, `SETL`/`DJNZ` (loops), `JPH`/`JPL` (jump on a pin), `JPO`, `JCC` (jump on a flag), `WAITR`, `REGION` |
| Bits and queues | `PULL`, `PUSH`, `PUSHI` (send a code to the host), `OUT1`, `IN1`, `CFG` |
| Pins | `SETH`, `SETLO`, `DIRO` (drive), `DIRI` (let go), `WAITH`/`WAITL` (wait for a level) |
| Registers and units | `LDI`, `ALU` (13 functions), `RGET`, `RPUT`, `CRC` (checksums), `LINE` (USB bit coding), `TSTAMP` (clock counter) |

I2C and 1-Wire never push a line high: they pull it low with `DIRO` + `SETLO` and let go with `DIRI`. Events for the host (such
as "NACK received") go out with `PUSHI`. Markers for the logic analyser are raised with `RPUT TRIG`.

## The protocol library

All of these pass their tests in simulation against an independently written "other side". Only UART has also run on real
hardware: a DE0-Nano FPGA board at 115,200 baud, full duplex, using the UART builds in `quartus/` on `main`.

| Protocol | Size (words) | | Protocol | Size (words) |
|---|---|---|---|---|
| UART transmit / receive | 12 / 9 | | JTAG controller | 87 |
| SPI master / slave (4 modes) | 17–18 / 16–18 | | CAN 2.0A transmit / receive | 112 / 186 |
| I2C master / slave | 46 / 108 | | USB low-speed device | 203 |
| SMBus with PEC | 88 | | WS2812 LED strip | 25 |
| Modbus RTU (transmit) | 42 | | PS/2 device | 89 |
| 1-Wire master | 79 | | SWD host | 161 |

## What is left to do

**Firmware:** protocol sniffers (listen-only decoders that trigger the analyser); a standalone USB device with its descriptors on
the chip (about 320–380 words; today the host supplies them); Ethernet 10BASE-T transmit (possible at 40 MHz; receive is
research); CAN arbitration and error frames; a UART-receiver glitch filter and stop-bit check; bus timeouts; about 20 more
"firmware only" protocols from [../docs/PROTOCOL_CATALOGUE.md](../docs/PROTOCOL_CATALOGUE.md); running the UART, USB, SMBus,
WS2812, PS/2 and SWD tests from the shared memory on the full chip (done so far for CAN, JTAG, 1-Wire, Modbus, SPI, I2C); if
candidate B (43 MHz) is chosen, regenerating every program for 43 MHz and rerunning the tests. The `two-tier` ideas (`COPY`,
self-installing library) were not carried forward.

**Around the firmware:** engine debug (halt, single step, breakpoint, register read-back); a MicroPython library for the Pico
(`pe_chip`), since today the Pico only forwards SPI frames; a first real run of the whole chip on the DE0-Nano (prepared, but the
Quartus build and Pico bridge are untested on hardware); merging the submission branch into `main`; filling the placeholders in
[../docs/USER_GUIDE.md](../docs/USER_GUIDE.md). Dates: design freeze 13 Dec 2026, final layouts 14–27 Dec, deadline 18 Jan 2027.

## Quick user guide

**You need** a computer with Python 3.12+, Icarus Verilog 12+ and GTKWave; for hardware today, a DE0-Nano FPGA board, a
Raspberry Pi Pico and jumper wires. The real chip comes after manufacturing.

### Step 1: try everything without hardware

```bash
git checkout submit/sh10-50mhz                         # or submit/8la-43mhz
bash run_tests.sh                                      # 22 small tests of the chip's blocks
python3 host/fpga_bringup.py --sim                     # first-contact checks on a simulated chip
python3 host/la_capture.py --sim --demo --out capture.vcd
gtkwave capture.vcd                                    # look at the recorded waveform
```

The bring-up script should end with `RESULT fpga_bringup: PASS`.

### Step 2: wire the Pico to the board

![Pico wiring](../docs/images/fig_pico_wiring.svg)

*Figure 3. Pico wiring for the management link. Use 3.3 V signals only.*

| Pico pin | Chip signal | DE0-Nano header |
|---|---|---|
| GP18 (SPI clock) | SCLK | `GPIO_2_IN[0]` |
| GP19 (SPI out) | MOSI | `GPIO_2_IN[1]` |
| GP17 (chip select) | CS_N | `GPIO_2_IN[2]` |
| GP16 (SPI in) | MISO | `GPIO_2[0]` |
| GND | GND | GND |

Compile and program `quartus/pe_chip.qpf` in Quartus, copy `host/pico_bridge.py` to the Pico as `main.py`, then run
`pip install pyserial` on the computer.

### Step 3: first contact

```bash
python3 host/fpga_bringup.py --port /dev/ttyACM0
```

It checks the "alive" bit, the ID `PEM1`, the scratch register, a counting program on both engines, and a blinking pin `uio[0]`
(`GPIO_2[1]` on the board; watch it with an LED).

### Step 4: your first program

Run this from the `host/` folder. Engine 0 counts to 3 and sends the answer to the host.

```python
import asm as A, shmem_host as S
from serial_link import SerialLink

a = A.Asm()
a.REGION()                       # first instruction: claim my window
a.LDI(0, 0)                      # R0 = 0
a.label("l")
a.ALU("ADD", 0, imm=1)           # R0 = R0 + 1
a.ALU("CMP", 0, imm=3)           # compare R0 with 3
a.JCC("NZ", "l")                 # not equal yet: go back
a.RPUT("RXF", 0)                 # send R0 to the host
a.HALT()

with SerialLink("/dev/ttyACM0") as link:
    chip = S.ShmemHost(link)
    chip.start(0, S.Image.from_asm("count", a, origin=0))
    chip.wait_halt(0)
    print(chip.pop_rx(0))        # prints 3
```

To use a pin, give it to the engine first, for example `chip.claim_pad(0, 0)` (pad 0 to engine 0). Each protocol's `*_test.py`
file shows how the host feeds and reads that protocol.

### If something goes wrong

| What you see | Likely cause |
|---|---|
| STATUS reads `0x00` | chip held in reset, no clock, or MISO not connected |
| error bit (STATUS bit 6) set | wrong frame length, bad address, or a write to a running engine; read ERRCNT at `0x0010` |
| engine shows "fault" | it fetched outside its window or hit an illegal instruction; check the origin and `REGION` |
| nothing on the pin | the pad was not claimed, or HOLD (`ui_in[3]`) is high |
| garbled replies | SPI clock too fast; keep it at or below 3 MHz (the bridge uses 1 MHz) |

The full draft guide (17 chapters, 47 figures) is [../docs/USER_GUIDE.md](../docs/USER_GUIDE.md).
