# Running below 50 MHz: what changes and how to adjust

Written 2026-10-20 while the shared-memory layout (sh4: slow corner 21.45 ns, about 46.6 MHz) is being tuned. Short answer: **nothing breaks;
every time in seconds is rescaled, every count in clocks stays.**

## 1. Principle

The engine has no notion of time. One instruction takes one clock, `WAIT` / delay counters count clocks, the line coder's bit period is a number of clocks (8.8
fixed point). So a slower clock changes the length of a clock, not the program. For a clock of `f`:

- one instruction = `1/f` (50 MHz: 20.0 ns, 46.6 MHz: 21.5 ns, 43.4 MHz: 23.0 ns, 40 MHz: 25.0 ns);
- a protocol that needs `N` clocks per bit runs at `f / N`;
- the *logic* of every firmware (instruction order, flags, FIFO use, cycle-exact relationships between pin edges) is identical.

## 2. What the "signoff frequency" means

The flow checks setup at the **slowest corner** (1.08 V, 125 C). That is the worst case. The same layout has 6.8 ns spare at the typical corner
(1.2 V, 25 C), i.e. it would run at about 80 MHz there. The clock of a Tiny Tapeout chip is supplied by the board, so the signoff number is the
**maximum clock we promise**, not a fixed operating point. Any lower clock is safe for setup. (Hold does not depend on the clock period.)

## 3. Time-based numbers at different clocks

| Quantity | 50 MHz | 46.6 MHz | 43.4 MHz | 40 MHz |
|---|---|---|---|---|
| clock period | 20.0 ns | 21.5 ns | 23.0 ns | 25.0 ns |
| UART 115200: clocks per bit | 434.0 | 404.5 | 376.7 | 347.2 |
| USB low speed 1.5 Mbit/s: clocks per bit | 33.33 | 31.07 | 28.93 | 26.67 |
| I2C 1 MHz: clocks per SCL period | 50 | 46.6 | 43.4 | 40 |
| CAN 1 Mbit/s: clocks per bit | 50 | 46.6 | 43.4 | 40 |
| WS2812 (1.25 us per bit): clocks | 62.5 | 58.3 | 54.3 | 50 |
| 10BASE-T (100 ns per bit): clocks per bit | 5 (2.5 per half bit) | 4.66 | 4.34 | **4 (2 per half bit)** |
| Fastest SPI slave clock (half period >= 4 clocks, CPHA 0) | 6.25 MHz | 5.8 MHz | 5.4 MHz | 5.0 MHz |
| Fastest SPI master clock tested (half period 4 clocks) | 6.25 MHz | 5.8 MHz | 5.4 MHz | 5.0 MHz |

Rates that are limits in *clocks* (the SPI slave rows, the I2C stretch response, the management link's frame rate) scale with `f`. Rates that are
targets (a UART baud, an I2C speed) are met by choosing a different clock count.

## 4. What has to be adjusted

| Where | Adjustment | Effort |
|---|---|---|
| Firmware generators | They take clock counts (`spi_prog`, `uart_*`, `can_prog`, ...) or `f_clk` (`i2c_prog.delays`); regenerate with the new `f_clk`. | small |
| Fixed-point bit period of the line coder | Set `PERIOD = round(256 * f / bitrate)`; the edge-tracking receiver tolerates +-1.5 %, the quantisation is 1/256 clock. | none (a register value) |
| Test benches | `tb_*` use `always #10 clk` and `host/proto_lib.F_CLK = 50_000_000`. Add a clock-period parameter (`+CLKNS`) and an `F_CLK` override so the regression can also run at the chosen clock. | small, mechanical |
| Timing checks in ns (I2C t_HD;DAT, USB turnaround, CAN sample point, PS/2 windows) | They are computed from the clock count and re-checked by the peer models; rerun the suites with the new `F_CLK`. A few margins shrink by 7 to 20 % and are reported by the peers. | one regression run |
| Documentation | Replace "50 MHz" by "signed off at X MHz (slow corner), Y MHz typical". | text |
| Management link | The host's SPI clock must stay below the chip clock / 4; at 46.6 MHz the allowed host rate falls by 7 %. | none |

## 5. Which protocols get harder, which easier

- **Harder:** anything whose speed is fixed and whose firmware needs a minimum number of clocks per bit: CAN at 1 Mbit/s (40 clocks per bit at 40 MHz; the
  suites were run at 125 and 500 kbit/s, so 1 Mbit/s has to be measured), I2C at 1 MHz (the slave stretches), SPI above the limits in the table.
- **Unchanged:** UART, 1-Wire, Modbus, WS2812, PS/2, SMBus, JTAG / SWD at the usual rates.
- **USB low speed:** 31 clocks per bit at 46.6 MHz. The turnaround window (2 to 7.5 bit times = 62 to 233 clocks) holds the same number of instructions
  more easily at 50 MHz, but the packet-shuttle firmware needs a fraction of it either way.
- **Easier at 40 MHz:** 10BASE-T. At 40 MHz a Manchester half bit is exactly 2 clocks (line coder in Manchester mode, no 2.5-clock jitter); at 50 MHz it is
  2.5 clocks, a 10 ns pattern jitter, far above the few ns of transmit jitter the standard allows (to be checked against the text in the feasibility study). See [ETHERNET_FEASIBILITY.md](ETHERNET_FEASIBILITY.md).

## 6. Recommendation

Quote **two** numbers: the signoff clock at the slow corner (whatever the layout reaches, 43 to 50 MHz) and a recommended operating clock. 40 MHz is a good
operating clock for this design: it has margin on every layout we have built, and it makes I2C 1 MHz, CAN 1 Mbit/s, WS2812 and 10BASE-T come out as whole numbers
of clocks.
