# ALU + CRC units, I2C slave, protocol suite, floorplan: what came out (2026-10-18)

Outcome of [ALU_CRC_I2CSLAVE_PLAN.md](ALU_CRC_I2CSLAVE_PLAN.md). All numbers are in [TEST_RESULTS.md](TEST_RESULTS.md); this document explains the decisions and
the problems that had to be solved. Nothing here was measured on silicon.

## 1. Outcome

| Question | Answer |
|---|---|
| ALU and CRC units built and tested like the other modules? | Yes: unit testbenches, independent Python models, a random differential test against a cycle-exact model, mutation tests (66 of 66 planted bugs caught). |
| I2C slave? | Yes: 108 words of firmware, verified at 100 / 400 / 1000 kHz. |
| Other protocols re-checked with the new units? | Yes: SMBus PEC, Modbus RTU, 1-Wire, JTAG, CAN 2.0A (transmit and receive), each against a peer model written from the specification; four of them also on the full chip. USB low speed was not attempted. |
| Complete flow with the new units? | Yes, after a root-cause analysis (section 6): two signoff-clean layouts at the **30 ns** signoff clock; with the pipelined CRC unit the slow corner reaches 48.8 MHz (flat) / 43.4 MHz (symmetric), the typical corner 78 / 70 MHz. |
| Bounding boxes instead of one clump? | Tried at module level (three floorplans) and at engine level (requested layout). Flat placement is better on wirelength, timing and congestion; boxes give a readable layout (section 5). |

## 2. What was built

- **Instruction set:** 7 new opcodes (21-27): `LDI`, `ALU`, `JCC`, `RGET`, `RPUT`, `WAITR`, `CRC`; opcodes 0-20 are unchanged (timing rules included). Reference: [../instructions.md](../instructions.md).
- **`src/alu_unit.v`:** 8 x 32-bit registers, 13 functions, flags Z / N / C. ADD, SUB and CMP share one 32-bit **Kogge-Stone prefix adder**; the adder Yosys builds from `+` is a 32-stage ripple-carry chain
  and was the slow-corner critical path.
- **`src/crc_unit.v`:** any Rocksoft CRC (width 1-32, polynomial, init, final XOR, reflection), bit feed or byte feed (8 steps in one cycle). The register is kept **left aligned**
  (`crc << (32 - width)`), so a step is a shift and a conditional XOR with no width masks and no 32:1 top-bit multiplexer; the first version had both and failed timing at the CRC byte step.
  A format write cuts the register to the new width. That corner was found by the differential test: the old unit kept the cut bits and brought them back when the width grew again.
  I defined the cleaner behaviour and changed the model and documentation, not the RTL.
- **Host side:** assembler `host/asm.py` (with `Asm.arrivals`, a static cycle analysis used to pad every CAN bit loop to an exact bit time), ISA model, CRC model, one firmware generator and one test per protocol.

## 3. Protocol results in one sentence each

I2C slave: all scenarios and 16 mutants. SMBus PEC: sent, checked, a flipped bit detected. Modbus RTU: textbook frame, silences, baud error. 1-Wire: slot timing against the Maxim windows, CRC-8 on chip.
JTAG: IEEE 1149.1 TAP, scans of 1-100 bits. CAN: 1 Mbit/s to 200 kbit/s, stuffing at every field boundary, bad CRC and stuff errors, clock tolerance +-0.15 % with ACK. Details and counts: [TEST_RESULTS.md](TEST_RESULTS.md) section 4.

## 4. Physical design: what had to change, and the clock

The first flow run with the new units did not work. These are the problems in the order they appeared; every row is one flow run (details in `results/tt_flow_2026-10-18/explore/README.md`).

| Problem | Evidence | Change |
|---|---|---|
| LibreLane's IHP default `SYNTH_STRATEGY = DELAY 4` made 21.5k cells | global-routing usage 79 %, overflow 23,889, wirelength 3.5 M um | `AREA 0`: 14.5k cells |
| ALU adder is a 32-stage ripple chain; CRC step has 32:1 muxes | setup -5.9 ns and -6.6 ns at the slow corner | prefix adder, left-aligned CRC |
| Signals shorted to the Metal4 power stripes that are bridged over the SRAM macros | routing never converged (36-57 Short violations) | routing obstructions on Metal4 over both macros |
| The resizer repairs timing at placement-time wire estimates and misses the slow corner | repair reported "no violations", final STA -6.7 ns | clock period 30 ns |
| A hold margin of 0.5 ns inserted 5,900 hold buffers | overflow 1,645 (flat) and 6,847 (boxed) | margin back to 0.1 ns, extra repair after global routing |

**Clock.** Flat run at 20 ns: routing clean (0 DRC, LVS matches), slow-corner setup -6.75 ns (546 endpoints), typical corner +1.79 ns. So the worst-case limit is about 27 ns
and the signoff clock is 30 ns. The firmware tables assume 50 MHz; at 33.3 MHz regenerate them with `f_clk = 33.33e6`. Reaching 50 MHz at the slow corner needs a pipeline stage for
`CRC BYTE` and the register read path (an ISA timing change), which is not done.

## 5. Bounding boxes against flat

| Question | Result |
|---|---|
| Do fences work in OpenROAD? | Yes. A custom flow step creates one region per box; global placement keeps 98-100 % of the cells inside. The fences are removed after global placement (cells the resizer adds later belong to no box and cannot be legalised inside a fence). |
| Module-level boxes (11 boxes, then only ALU / CRC / management) | worse than flat on wirelength (+12 % to +19 %), and congested unless the boxes are roomy (utilisation 40 %): the placer already groups modules by connectivity, and a hand-made floorplan can only be as good as the guess. |
| What the data said | the control unit is the hub (146 nets to the shifters, 134 to the SRAM, 96 to the ALU, 68 to the FIFOs); **all SRAM signal pins are on the bottom edge** of the macro. |
| Engine-level boxes (one box per engine, management free in the top-left corner) | requested layout; picture and numbers below. |
| Advantage of boxes | a readable GDS and a predictable floorplan; roomy boxes can lower routing congestion. Disadvantage: longer wires, less slack. |

The numbers are in [TEST_RESULTS.md](TEST_RESULTS.md) sections 8.3 and 8.4.

## 6. Final layout

A root-cause analysis of the runs that would not finish clean at 30 ns found six causes; all are fixed (details and every number:
[TEST_RESULTS.md](TEST_RESULTS.md) section 8.4).

| Cause | Fix |
|---|---|
| The slow corner used the **typical** SRAM timing model (LibreLane loads every model whose key matches the corner name; all IHP corners start with `nom_`) | one model per corner (`*_typ_*`, `*_fast_*`, `*_slow_*`): SRAM clock-to-output is 5.1 ns slow, not 3.05 |
| 0.25 ns clock uncertainty also on **hold**: 1,906 flop-to-flop paths failed in the fast corner, 4,260 hold buffers (+20 % area) | `src/pnr.sdc`: 0.25 ns for setup, 0.1 ns for hold; 1,132 hold buffers |
| The SRAMs were walls under the chip pins (signals route on Metal2-4 only, the SRAM blocks all three); nets crossed them: shorts | both SRAMs on the bottom edge, pins facing up |
| Repair after global routing inserted buffers into routed areas: routing never converged | switched off |
| Timing-driven placement off | switched on |
| One cycle covered SRAM read -> decode -> register read -> 8 chained CRC steps | CRC commands registered and executed one clock later, polynomial pre-aligned (`RGET CRC` directly after a `CRC` waits 1 clock) |

Two floorplan details came from the TT precheck: macros must move by whole stripe pitches (44.96 um; a stripe in the SRAM's middle section
violates Metal4 spacing), and the macro halo must leave no sliver rows (42 rows 1.9 um wide broke the power-pin check).

**Two signoff-clean layouts** (0 DRC, 0 LVS, TT precheck pass, gate-level cocotb test 3/3, no setup or hold violation in any corner at 30 ns):

| | tt9b (flat) | tt9c (symmetric, engine fences) |
|---|---|---|
| Layout | both SRAMs along the bottom, the placer arranges the logic | SRAM 0 bottom left, SRAM 1 bottom right; engine 0 and engine 1 each in their own column, management / SPI / pin manager in the middle |
| Slow / typical corner | 20.5 ns (48.8 MHz) / 12.8 ns (78 MHz) | 23.0 ns (43.4 MHz) / 14.3 ns (70 MHz) |
| Wire length / power | 906 k um / 4.80 mW | 1,069 k um / 4.95 mW |

Pictures with every engine and module outlined: `results/tt_flow_2026-10-18/tt9b_images/` and `tt9c_images/` (open `index.html`).

## 7. Reproduce

`python host/regress.py` (all tests); flow: `bash librelane/flow_run_wsl.sh <tag> [boxed]` in WSL, then `precheck_wsl.sh`, `gl_test_wsl.sh`, `render_wsl.sh`, `collect_tt_wsl.sh`;
analysis tools: `librelane/net_matrix.py` (module connectivity, wirelength per module), `librelane/module_report.py` (where each module's cells went, picture),
`librelane/area_by_module.py`, `librelane/compare_runs.py`, `librelane/synth_variants_wsl.sh` (strategy comparison).
