# 4. Physical design: turning code into a chip layout, and how close we get

> Based on the repository as of 31 October 2026. Main sources: `results/tt_flow_2026-10-20/sh10_final/metrics.json`,
> `reproduce/flows/README.md`, `src/config.json`, `src/pnr.sdc`, `src/pdn_cfg.tcl`, `librelane_plugin_project/`, `memory.md`.
> All numbers come from the design tools. Nothing has been measured on a real chip yet.

## What "physical design" means

The chip is written in Verilog, a language that describes *behaviour*. A factory cannot build behaviour. It needs a drawing of
every transistor and every wire on every layer (a **GDS** file). Physical design turns the first into the second.

Think of building a house. The Verilog is the list of rooms you need. Physical design is the floor plan, the wiring and the
plumbing, all checked against the building codes.

## The ground rules

- **Process:** IHP 130 nm CMOS5L. The smallest transistor is about 600 times thinner than a human hair.
- **Tiny Tapeout:** many projects share one chip. Each gets a number of **tiles** of about 200 x 150 µm (µm = a millionth of a
  metre). We use **8 x 4 tiles**: a die of 1,724 x 711 µm, about 1.2 mm².
- **Tools:** LibreLane, an open-source tool chain (Yosys, OpenROAD, Magic, KLayout, Netgen). We use the exact versions that Tiny
  Tapeout's official GitHub build uses (LibreLane 3.1.0.dev3, PDK revision 2bbec755), so our local results match theirs.

## The flow, step by step

```
 Verilog --> 1 Synthesis --> 2 Floorplan --> 3 Power grid --> 4 Placement --> 5 Clock tree --> 6 Routing --> 7 Checks --> GDS
```

| Step | What happens | Our settings |
|---|---|---|
| 1 Synthesis | Yosys turns the Verilog into **standard cells** (small ready-made gates and flip-flops); the finished layout has about 28,000 | strategy "AREA 0" |
| 2 Floorplan | sets the die size and places the big blocks | the SRAM at the bottom centre; "fences" keep each engine in its own column |
| 3 Power grid | lays the wires that carry power (VPWR) and ground (VGND) | Metal4 stripes only; a custom step joins them to the SRAM |
| 4 Placement | puts every cell in a row, close to its partners | 60 % target density, timing-driven |
| 5 Clock tree | spreads the clock so it reaches every flip-flop at nearly the same time | about 420 clock buffers and inverters |
| 6 Routing | draws the real wires on the metal layers | 1.5 metres of wire in total |
| 7 Checks | timing in three conditions, drawing rules (DRC), layout = circuit (LVS), antenna rule, Tiny Tapeout precheck, gate-level test | see the scorecard below |

## Our floorplan

![Module map of run sh10](../results/shared_2026-10-20/sh10_images/detailedplacement__module_map.png)

*Figure 1. Run sh10 (candidate A). Every cell is coloured by the block it belongs to.*

The layout has **three columns**: engine 0 on the left, engine 1 on the right, and the shared logic (management, SPI link, pin
manager) in the middle. The shared 512-word SRAM (686 x 220 µm) sits at the bottom centre, so both engines are the same distance
from it. Inside each engine you can see the ALU and registers (red), the CRC unit (green) and the FIFOs (blue). The fences are
used only to guide placement and are removed afterwards.

Candidate B (with the logic analyser) has two SRAM blocks side by side along the bottom (one for programs, one as the analyser
buffer) and lets the tool place cells freely.

![Final layout of run sh10](../results/shared_2026-10-20/sh10_images/12_final_gds.png)

*Figure 2. The finished layout of run sh10, all layers.*

## Problems solved on the way

| Problem | Fix | Result |
|---|---|---|
| Flip-flop program memories were 80 % of the chip | SRAM memory blocks ("macros") | 414,137 → 143,421 µm² (−65 %) |
| Tiny Tapeout forbids the top metal layer (TopMetal1), but the default SRAM power hookup uses it | power on Metal4 only; the stripes run over the SRAM and land on its own power columns (custom step `BridgeMacroStripes`) | precheck passes |
| With the 2-port SRAM, stripes landed on the wrong columns: **power shorted to ground** (run sh3 failed LVS) | a script tried every stripe spacing; 53.04 µm pitch with a matching offset fits | LVS clean from sh4 on |
| Too much hold-time margin made the tool add 4,260 extra buffers (+20 % area) | smaller hold margin (0.1 ns) in our own timing file `src/pnr.sdc` | routing no longer jammed |
| A CRC step sat in the instruction fetch path | CRC unit pipelined | faster clock |
| GitHub's build placed cells differently and failed | same tool versions locally + `PL_MAX_PHI_COEFFICIENT 1.03` | official build passed (run 39250627497) |
| 6 x 4 tiles could not be routed after new features (+27 % cells) | 8 x 4 tiles with the three-column floorplan | routes cleanly |
| A weak gate next to the SRAM drove a long wire (about 1 ns lost) | moved that gate into the engines | 21.45 → 20.41 ns, for free |

## The race to 50 MHz

Timing is checked at the **slow corner**: 1.08 V and 125 °C, the worst case (low supply, very hot). At 50 MHz each tick lasts
20 ns, so every signal must finish its trip within 20 ns there. A useful trick: ask the tool for 17 ns. It then works harder and
lands below 20 ns.

| Run | What changed | Time per tick at the slow corner |
|---|---|---|
| sh4 | first clean shared-memory layout | 21.45 ns (46.6 MHz) |
| sh5c | synthesis tuned for speed | 22.43 ns (worse) |
| sh6 | weak gate moved into the engines | 20.41 ns |
| sh8 | 17 ns target + resizer margin 0.5 ns | **19.64 ns (50.9 MHz)** |
| sh9a / sh9b | honest 20 ns target | 20.45 ns (both identical) |
| **sh10** | current design, sh8 recipe (candidate A) | **19.71 ns (50.7 MHz)** |
| 8la | with the logic analyser (candidate B) | 22.4 ns (44.6 MHz), so `info.yaml` says 43 MHz |

## How accurate are we? The scorecard

For candidate A (run sh10):

| Check | Goal | Achieved |
|---|---|---|
| Speed, slow corner | 20 ns (50 MHz) | **19.71 ns (50.7 MHz)**: 0.29 ns to spare (about 1.5 %) |
| Speed, typical corner (1.2 V, 25 °C) | – | about 12.2 ns (about 82 MHz) |
| Hold time (signals must not change too early) | no violations | none; smallest margin +0.077 ns |
| Drawing rules (DRC) | 0 errors | 0 |
| Layout matches circuit (LVS) | 0 errors | 0 |
| Antenna rule | 0 | 0 |
| Max slew / max capacitance warnings | 0 | 27 / 30, **not yet judged** |
| Tiny Tapeout precheck | pass | passed on sh4 (same memory and grid); **not yet run on sh10** |
| Area used | must fit | 46 % of the core (405k µm² of cells + 151k µm² SRAM) |
| Repeatability | same result every time | a rerun of sh8, stopped at step 30 of 72, matched the original in all 29 finished steps |
| Voltage drop on power wires | small | 0.21 mV on an older layout (tt10c); not rechecked since |

For candidate B (run 8la) the repository keeps only the speed number, from a commit message. Its full metrics are not archived.

**Accuracy in a second sense: protocol timing.** Every pin change lands exactly on a tick (20 ns at 50 MHz). A UART at 115,200
baud comes out at 115,207 baud (+0.006 %). Inputs are seen 2 ticks late, and firmware allows for that. A slower clock changes
the length of a tick, not the logic. `docs/CLOCK_SPEED_EFFECTS.md` recommends 40 MHz as a comfortable operating clock, because
I2C at 1 MHz, CAN at 1 Mbit/s and WS2812 then come out as whole numbers of ticks.

## What is left

- Choose candidate A (50 MHz, no analyser) or B (43 MHz, analyser).
- Judge or fix the 27 slew and 30 capacitance warnings.
- Run the Tiny Tapeout precheck and the official GitHub build on the final design. The gate-level test was retargeted to the
  shared-memory chip on 31 October (it had failed on the GitHub check branch because it still tested the old design); no newer
  result is recorded.
- Final layout runs after the design freeze (13 Dec 2026), from 14 to 27 Dec, and a fresh voltage-drop check.

**Read more:** `results/shared_2026-10-20/sh10_images/index.html` (every stage as a picture),
[../reproduce/flows/README.md](../reproduce/flows/README.md), [../docs/PROGRESS_REPORT_2026-10-18_to_2026-10-20.md](../docs/PROGRESS_REPORT_2026-10-18_to_2026-10-20.md),
[../docs/TT_FLOW_RESULTS.md](../docs/TT_FLOW_RESULTS.md), [../docs/ALU_CRC_RESULTS.md](../docs/ALU_CRC_RESULTS.md).
