# Challenge check against the rules (state of 2026-10-18)

Checked against [../Challenge_general_instructions.md](../Challenge_general_instructions.md). Status words: **met**, **partly**, **not yet**.
Evidence is in this repository ([TEST_RESULTS.md](TEST_RESULTS.md)); nothing was measured on silicon.

## 1. Rules

| Rule | Status | Where we stand |
|---|---|---|
| IHP 130 nm CMOS5L through Tiny Tapeout, RTL to GDS from the CMOS5L Verilog template | **met** | the repo has the template layout (`info.yaml`, `src/config.json`, `test/`, `.github/`); the design goes RTL to GDS with the TT flow and passed the TT precheck, LVS and the gate-level cocotb test (design before the ALU / CRC units, run tt5, [TT_FLOW_RESULTS.md](TT_FLOW_RESULTS.md)); the new design's runs are in [TEST_RESULTS.md](TEST_RESULTS.md) section 8 |
| `info.yaml` tile size 6x4 | **met** | `info.yaml`, die 1289.28 x 710.64 um = 916,214 um^2 |
| Area: at most 6x4 tiles | **met** | after synthesis 14.5k cells, 223,815 um^2, plus two SRAM macros 98,977 um^2: about 35 % of the die |
| SRAM may be used for instruction memory | **partly** | 2 x IHP 1P 256x32 macros, powered from Metal4 stripes (the precheck forbids TopMetal1), passes precheck and LVS. **Open (A9):** the shuttle organisers have not confirmed that the SG13G2 macros are accepted on the CMOS5L shuttle |
| Run synthesis early, then place and route and check timing | **met** | done repeatedly; a root-cause analysis of the failing runs led to configuration, floorplan and RTL fixes (CRC unit pipelined). Final layouts tt9b / tt9c: signoff clock 30 ns with 9.5 / 7.0 ns to spare at the slow corner (48.8 / 43.4 MHz possible), 78 / 70 MHz at the typical corner; 0 DRC, 0 LVS, TT precheck and gate-level test pass ([TEST_RESULTS.md](TEST_RESULTS.md) section 8.4) |
| Open source | **partly** | Apache-2.0 `LICENSE` is in the repo; the repository is not public yet and the GitHub workflows have not run (their steps were reproduced locally) |
| Deadline 2027-01-18 | on track | about 13 weeks left |

## 2. Technical asks

| Ask | Status | Evidence |
|---|---|---|
| Programmable emulator, not fixed protocol blocks; new protocols after fabrication | **met** | 28-opcode engine with registers, ALU and CRC; all protocols are firmware loaded over the management link |
| Start with UART, SPI, I2C | **met (simulation)** | UART TX / RX / duplex (also on a DE0-Nano); SPI master + slave, 4 modes; I2C master 100 / 400 / 1000 kHz and **I2C slave** |
| Stretch: low-speed USB, 10 Mbit Ethernet | **USB LS met (simulation)**, Ethernet no | a line coder (NRZI, stuffing, SE0 EOP, edge-tracking receiver) in every engine and device firmware enumerate a HID keyboard against an independent host model, on the RTL ([USB_LS_PLAN.md](USB_LS_PLAN.md)); raw 10BASE-T is not feasible on GPIO at this clock |
| Others: JTAG, SWD, PS/2, CAN | **met (simulation)** | JTAG, SWD (host), PS/2 (device) and CAN 2.0A (transmit and receive) done, plus SMBus PEC, Modbus RTU, 1-Wire and WS2812; CAN has no arbitration or error frames |
| FPGA testing | **partly** | UART on a DE0-Nano; the other protocols and the ALU / CRC units were not on the FPGA |
| Verification techniques (formal, constrained random, mutation) | **partly** | independent models and peers written from the specifications; random differential test (600 programs, 0 mismatches, 74 of 74 coverage points); mutation testing everywhere (66 planted ALU / CRC / engine bugs plus 145 protocol mutants, all caught); **no formal properties yet** |
| "Show us anything else your architecture makes possible" | **partly** | two protocols at once on one chip through one host link; pin ownership with violation reporting; event words in the data stream; a CRC unit that is any Rocksoft CRC |

## 3. Known limits (found by testing)

- **Clock:** with the pipelined CRC unit the slow corner (1.08 V, 125 C) needs 20.5 ns (flat layout tt9b) or 23.0 ns (symmetric tt9c); the limit is now SRAM read -> decode -> ALU adder, with minimum-size cells the resizer does not upsize at a 30 ns constraint. Next step: constrain the flow at 20 ns.
- The firmware tables assume a 50 MHz clock; at 33.3 MHz regenerate the firmware with `f_clk = 33.33e6`.
- UART RX accepts a glitch as a start bit and has no stop-bit check; RX baud tolerance about -4.5 % / +6 %.
- CAN: no arbitration, error frames, resynchronisation (receiver tolerates about +-0.3 % clock error), extended identifiers or remote frames.
- SPI slave and UART RX cannot pause their peer; sustained rates are bounded by the management link (one frame per word).
- No firmware timeouts: a stuck bus leaves the engine waiting until the host toggles RUN.
- Management frame v1 has no CRC or sequence number.

## 4. Open items, in order

1. Confirm with Tiny Tapeout that the SRAM macros are accepted on the CMOS5L shuttle (A9).
2. Make the repository public and let the GitHub workflows (`gds`, `precheck`, `gl_test`) run; the flow needs the custom steps in `librelane/` (power-stripe bridge, engine fences).
3. Management frame v2 (CRC-16, sequence number).
4. FPGA bring-up of SPI, I2C and the new protocols.
5. Formal properties (open-drain pads never drive high, non-owners never reach a pad, management commits only complete frames, FIFOs never lose words).
6. 50 MHz at the slow corner (pipeline stage), CAN arbitration, USB low speed with an unrolled loop.
