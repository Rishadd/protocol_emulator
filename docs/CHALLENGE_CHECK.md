# Challenge Sanity Check and Next Steps (2026-10-12)

Checked against [../Challenge_general_instructions.md](../Challenge_general_instructions.md). Status words: **met**,
**partly**, **not yet**. Evidence is in this repository; nothing here was measured on silicon or on a real flow run.

## 1. Rules

| Rule | Status | Where we stand |
|---|---|---|
| Process: IHP 130 nm CMOS5L via Tiny Tapeout, start from the CMOS5L Verilog template (RTL to GDS) | **not yet** | Our top `tt_um_protocol_emulator` uses the template's port list, but the template repo, `config.json` and the LibreLane flow are not set up (EXECUTION_PLAN G1). Synthesis only, with Yosys on the real CMOS5L cell library. |
| `info.yaml` tile size 6x4 | **not yet** | No `info.yaml` in the repo yet (comes with the template fork). |
| Area: max 6x4 tiles (~0.7 mm^2 nominal, ~1k cells per tile) | **met on synthesis numbers** | Whole chip **150,000 um^2 = 20.8 %** of 720k, about 4.2k standard cells plus 4 SRAM macros (`build/synth/i2c_final.stat.txt`, 2026-10-12). Routing, CTS and macro placement overhead are not measured yet. |
| SRAM may be used for instruction memory (TT examples) | **partly** | 2 x IHP 1P 64x16 per engine, verified in simulation. **Open blocker A9:** the CMOS5L PDK's SRAM entry is a link to the SG13G2 macros; acceptance on the CMOS5L shuttle must be confirmed with Tiny Tapeout. Fallback costs area (flop memory was 414k um^2 = 57.5 %). |
| "Run synthesis early ... then run the full place-and-route flow and check timing" | **partly** | Synthesis done and repeated after each RTL change. **No place-and-route, no STA.** 50 MHz is assumed (template default 20 ns), not proven. |
| Open source | **partly** | Work is in a git repo; **no LICENSE file yet** and the repo's public status is not recorded here. |
| Deadline January 18, 2027 | on track if the flow starts now | About 14 weeks left. The physical flow is the critical path. |

## 2. Technical asks

| Ask | Status | Evidence |
|---|---|---|
| Programmable protocol emulator, not fixed UART/SPI/I2C blocks; new protocols after fabrication | **met** | 21-opcode engine, protocols are firmware loaded over the management link. Nothing protocol-specific in the engine; open-drain is a per-pad mode of the pin manager. |
| Start with UART, SPI, I2C | **partly** | **UART** TX/RX/full duplex: simulation + DE0-Nano. **SPI** master and slave, all 4 modes: simulation (engine, full chip, concurrent with I2C). **I2C master** 100/400/1000 kHz: simulation, UM10204 timing checked. **I2C slave: not built** (needs ~64-67 of 64 words; CALL/RET or 128-word memory would fix it, I2C_PLAN §6.4.1). |
| Stretch: low-speed USB, 10 Mbit Ethernet | **not yet** | Feasibility notes only (architecture doc §6: raw 10BASE-T is not feasible on GPIO at this clock; USB LS needs a separate study). |
| Others: JTAG, SWD, PS/2, CAN | **not yet** | JTAG shift loop drafted (`instructions.md` §5), not run. `JPO`/`PUSHI`/`JPH`/`JPL` and open-drain pads were added with these in mind. |
| FPGA testing | **partly** | UART on a DE0-Nano. SPI, I2C, pin manager and the management link have not been on the FPGA (deferred by decision). |
| Verification techniques (formal, constrained random, AI-assisted) | **partly** | Self-checking directed + random tests, independent protocol decoders and peers, golden-model lockstep (`tb_fetch_equiv`), timing-limit sweeps, mutation testing of RTL and firmware, workload campaign through the host link. **No formal properties yet** (SymbiYosys not set up). |
| "Show us anything else your architecture makes possible" | **partly** | Two protocols concurrently on one chip through one host link (SPI master + I2C master, `tb_combo_chip`); pin ownership with violation reporting; event words in the data stream (`PUSHI`). Not yet written up as a demo. |

## 3. Known functional limits found by testing (details in the results documents)

- UART RX accepts a glitch as a start bit (no mid-start re-check) and has no stop-bit/framing check; a line break gives one 0x00 byte.
- SPI slave and UART RX cannot pause their peer: sustained rates are bounded by the management link (one READ frame per
  received byte or SPI frame: SPI slave one frame per 25 us at a 10-clock half period; UART RX open loop up to a 109-clock
  bit at the fastest link). I2C master through the link: ~27 kB/s at 1 MHz.
- UART RX baud tolerance about -5 % ... +4 %.
- Frames longer than 32 bits per CS are not supported by the SPI programs.
- No firmware timeouts: a stuck I2C bus or a missing peer leaves the engine waiting until the host toggles RUN.
- Management frame v1 has no CRC or sequence number.

## 4. Brief to-do (in order)

1. **Physical flow (critical path).** Fork the TT CMOS5L template, add `info.yaml` (6x4), move the RTL flat into the
   template's `src/`, run LibreLane to GDS, read the timing report at the template clock (50 MHz; 24 MHz fallback).
2. **A9: SRAM on CMOS5L.** Ask Tiny Tapeout whether the SG13G2 macros are accepted; if not, decide the fallback
   (latch memory or smaller programs) before the first full flow run.
3. **Open-source hygiene.** Add a LICENSE (the template ships one), make the repo public, keep README/docs current.
4. **Close functional gaps.** Optional `CALL`/`RET` (makes the I2C slave fit), UART RX start-bit re-check with `JPH`
   (about 2 words), a watchdog or firmware timeout pattern, SPI frames longer than 32 bits.
5. **FPGA bring-up** of the pin manager, SPI and I2C on the DE0-Nano (real EEPROM/sensor and SPI flash).
6. **Formal properties** with SymbiYosys: open-drain pads never drive high, non-owners never reach a pad, management
   commits only on complete frames, FIFOs never lose or duplicate words.
7. **Management frame v2** (CRC-16, sequence number) and packing several bytes per FIFO word to raise link throughput.
8. **Stretch protocols** as firmware demos: JTAG/SWD first (closest to SPI), then PS/2; USB LS feasibility study.
