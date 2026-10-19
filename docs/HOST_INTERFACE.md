# Host interface: everything that passes between the host and the chip

Status: **built and simulated** (2026-10-18). The host side is `host/chip_host.py` (library) and `host/chip_host_demo.py` (guided tour); the
chip side is `src/spi_slave.v`, `src/mgmt.v`, `src/pin_mgr.v`. The Python code talks to the real chip RTL through `tb/tb_host_bridge.v`, so what
you see in the trace is what the pins carry.

```
python3 host/chip_host_demo.py            # every SPI frame printed with its raw bytes and a decoded line
python3 host/chip_host_demo.py --quiet    # only the results
```

## 1. What is physically connected

| Pin | Direction | Use |
|---|---|---|
| `ui_in[0]` | host -> chip | SCLK |
| `ui_in[1]` | host -> chip | MOSI |
| `ui_in[2]` | host -> chip | CS_N (active low) |
| `uo_out[0]` | chip -> host | MISO (0 while CS_N is high) |
| `clk`, `rst_n` | host -> chip | system clock (50 MHz target) and reset (Tiny Tapeout board provides both) |
| `uio[7:0]`, `ui_in[7:3]`, `uo_out[7:1]` | | everything else: protocol pins and the reset-default functions of [PIN_MAP_PLAN.md](PIN_MAP_PLAN.md) |

The host and the chip are the only two parties on the SPI link; the engines never see it. The host is the SPI master and the chip is a slave,
mode 0 (CPOL 0, CPHA 0: SCLK idles low, both sides sample on the rising edge), most significant bit first, full duplex.

Timing contract: SCLK high and low phases at least 8 system clocks (160 ns at 50 MHz, i.e. SCLK up to ~3 MHz), CS_N set up at least 4 clocks before
the first SCLK edge and held 4 clocks after the last. SCLK is sampled by the system clock (no SCLK clock tree), hence the minimum.

## 2. The frame

Every access is **one frame of exactly 7 bytes** (56 SCLK pulses) between CS_N falling and CS_N rising. Both directions move at once:

```
 byte        0           1   2          3   4   5   6
 MOSI        op          address        write data
             (host -> chip, big endian: the high byte of each field goes first)
 MISO        STATUS      0x00 0x00      read data
             (chip -> host)
```

| op | meaning |
|---|---|
| `0x01` | WRITE: `data` goes to `address`; MISO bytes 3-6 are 0 |
| `0x02` | READ: MISO bytes 3-6 carry the value of the register at `address`; MOSI bytes 3-6 are ignored (send 0) |

Anything else (unknown op, wrong length) changes nothing and raises `err` (section 4).

**The commit rule.** The chip acts only when CS_N *rises*, and only if the frame was clean (7 whole bytes). An aborted, short or long frame
changes nothing (and counts as an error unless it was empty). So a glitch or a host that dies in the middle of a frame cannot half-write a register.
Proved by `formal/mgmt.sby` (M3). The read value, in contrast, is already on MISO while the frame runs: the chip looks the register up as soon as the
address bytes have arrived (end of byte 2) and shifts it out in bytes 3-6.

Example, the first frame after reset (`READ E0.CTRL`):

```
MOSI 02 10 00 00 00 00 00      op=READ, address=0x1000
MISO 80 00 00 00 00 00 00      STATUS=0x80 (alive, nothing else), read data=0
```

## 3. STATUS: the first MISO byte of every frame

STATUS is sampled while CS_N is high, so it describes the chip **before** this frame has any effect. Every frame therefore also polls the chip for free.

| Bit | Name | Meaning |
|---|---|---|
| 7 | alive | always 1. A chip in reset or a stuck-low MISO line reads 0x00, which the host recognises immediately (`HostError`) |
| 6 | err | sticky: a previous access was rejected (section 4). Cleared by reset or by writing 1 to IRQ bit 6 |
| 5, 4 | RUN e1, e0 | engine running (not held in reset) |
| 3, 2 | tx_full e1, e0 | the engine's TX FIFO (host -> engine) is full |
| 1, 0 | rx data e1, e0 | the engine's RX FIFO (engine -> host) holds at least one word |

## 4. Errors

A rejected access leaves the chip unchanged and sets the sticky `err` bit, visible in the STATUS of the **next** frame. Rejected:
unknown op, wrong length, unmapped or unaligned address, reserved bits set in a data word, an instruction write to a *running* engine, a pin
reconfiguration of a pin whose owner runs, `RUN = 1` while HOLD is active, owner code 3. Not errors: an empty CS_N pulse, a TX push into a full FIFO,
an RX pop from an empty FIFO (those are flow control, section 6).

Python: `chip.write(addr, data, check=True)` spends one extra frame on reading STATUS, raises `HostError` if `err` was set, and clears it again.

## 5. Address map

All addresses are 16-bit, word aligned. `e` = engine 0 or 1, window base `0x1000` (engine 0) or `0x2000` (engine 1).

### Engine windows

| Address | Name | WRITE | READ |
|---|---|---|---|
| base + `0x000` | CTRL | bit 0 = RUN (1 starts the engine from PC 0, 0 holds it in reset); other bits must be 0 | `{16'd0, pc[7:0], 5'd0, fault, halted, RUN}` |
| base + `0x200` | TX_DATA | pushes the 32-bit word into the engine's TX FIFO (only if STATUS showed not full) | 0 |
| base + `0x204` | RX_DATA | - | head of the RX FIFO; the read **pops** it (only if STATUS showed data), otherwise 0 |
| base + `0x400 + 4i`, i = 0..255 | IMEM word i | instruction word, **only while RUN = 0** (else err) | 0 (write-only) |

(An older plan, `MGMT_PLAN.md`, put IMEM at `0x100`; the built chip uses `0x400`.)

### Pin manager window `0x0200..0x02FF`

| Address | Name | Fields |
|---|---|---|
| `0x0200 + 4p`, p = 0..7 | PAD (uio p) | `[1:0]` owner (0 none, 1 engine 0, 2 engine 1), `[2]` open-drain, `[5:3]` remap |
| `0x0220` | VIOL | `[7:0]` engine 0, `[15:8]` engine 1: logical pins the engine enabled that no pin of its own carries. Write-one-to-clear |
| `0x0240 + 4k`, k = 1..7 | OPAD (uo_out k) | `[1:0]` owner (0 = default function: IRQ / debug), `[5:3]` remap |
| `0x0280 + 0x20e + 4i` | ISEL (engine e, logical input i) | `[3:0]` physical input: 0..7 = `uio[0..7]`, 8..12 = `ui_in[3..7]` |
| `0x02C0` | MISC | `[0]` hold_en, `[1]` trig_en, `[2]` dbg_en (all 1 after reset; cannot change while an engine runs), `[6:4]` debug view used when dbg_en = 0, `[31:16]` IRQ mask |
| `0x02C4` | IRQ | status, write-one-to-clear: 0/1 RX data e0/e1, 2/3 halted, 4/5 fault, 6 management error (also clears `err`), 7 violation |
| `0x02C8` | INPUTS | read only: `[7:0]` uio_in, `[12:8]` ui_in[7:3], `[13]` HOLD active |

Each engine has 8 *logical* pins (the 3-bit pin fields of the instruction set). A physical output pin `p` (or `uo_out[k]`) with owner `e` carries logical pin
`remap XOR p` of that engine; remap 0 is the identity, so `PAD[p] = 1` still means "uio[p] is logical pin p of engine 0". Inputs go the other way: logical
input `i` of an engine reads the physical input in ISEL (reset: `uio[i]`). A pin can be claimed or changed only while its current owner is held.

Reset defaults: nothing owned and nothing driven on `uio`; `ui_in[3]` HOLD (high stops both engines and releases every engine-driven pin), `ui_in[4]`
TRIG_IN (unused until the logic analyser), `ui_in[7:5]` DBG_SEL, `uo_out[1]` IRQ, `uo_out[7:2]` debug view. View 0 = {heartbeat ~1.5 Hz, err, RUN e0, RUN e1,
halted-or-fault e0, e1}; view 1/2 = the last SPI byte received (bits 3:0 + two toggles / bits 7:4 + clean + CS_N); view 3 = loopback of `ui_in[7:3]` and `uio[0]`;
view 5 = `uio[5:0]`; views 4, 6, 7 are reserved (memory self-test, logic analyser). These let a chip that does not answer on SPI still be diagnosed.

## 6. Flow control

The FIFOs are depth 4 words. There is no handshake on the wires; the STATUS byte of each frame is the handshake, and it is evaluated at the start of the frame:

* **TX push** (host -> engine): write `base+0x200`. If STATUS (the same frame) showed `tx_full = 0`, the word is queued; otherwise it is dropped silently and the host
  must send it again. `push_tx()` returns whether it was accepted; `send_words()` resends until it is.
* **RX pop** (engine -> host): read `base+0x204`. If STATUS showed `rx data = 1`, the word is returned and removed; otherwise the read returns 0 and removes nothing.
  `pop_rx()` returns `None` for "nothing there"; `recv_words()` polls.

Consequence: because the decision is made against the status at frame start, there is no race with the engine filling or draining the FIFO during the frame.
A word is never lost or duplicated; the worst case is one wasted frame.

## 7. A session, step by step (what `chip_host_demo.py` does)

1. **Check** (`status()`): READ CTRL; expect STATUS `0x80`.
2. **Load firmware**: `CTRL <- 0` (hold), then one WRITE per instruction word to `base+0x400+4i`. The engine's instruction memory is an SRAM macro that the chip fills through its
   write port only while the engine is held; it cannot be read back over this link. Pad with HALT words so a stray jump stops.
3. **Configure pins** (optional, any time the owner is held): PAD / OPAD / ISEL writes. Unclaimed `uio` pins stay undriven, a safe default.
4. **Run**: `CTRL <- 1`. The engine starts at PC 0. TX words can be queued before RUN.
5. **Exchange data**: TX pushes and RX pops as in section 6; poll STATUS/CTRL for `halted`/`fault`.
6. **Stop / reconfigure**: `CTRL <- 0` releases all the engine's pins (a held engine drives nothing), after which its pins can be re-claimed.
7. **Diagnose**: STATUS `err`, VIOL for pin mistakes, IRQ status, the debug views on `uo_out[7:2]`.

## 8. Running the same Python on real hardware

`ChipHost` needs only `link.transfer(7 bytes) -> 7 bytes`. A real link is a few lines (Linux spidev shown; any SPI master in mode 0, MSB first works):

```python
import spidev
class HwLink:
    def __init__(self, bus=0, dev=0, hz=1_000_000):
        self.s = spidev.SpiDev(); self.s.open(bus, dev); self.s.mode = 0; self.s.max_speed_hz = hz
    def transfer(self, mosi): return bytes(self.s.xfer2(list(mosi)))   # CS_N low for the whole 7-byte call
```

Keep the hardware SPI clock at or below ~3 MHz (section 1) and CS_N low for exactly the 7 bytes. The simulator-only calls (`set_inputs`, `pins`, `wait`, `reset`) have no
hardware equivalent; they are the pins the real board would let you drive and sample.

## 9. What is not built yet

Frame v2 (sequence number and CRC-16, `MGMT_PLAN.md`) would let the host detect a corrupted frame instead of trusting the wire; frame v1 relies on the clean-frame
rule and on read-back. The SRAM self-test (view 4), the logic analyser (view 6) and USB/other firmware add registers in the same window, not new framing.
