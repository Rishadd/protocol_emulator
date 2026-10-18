# Protocol emulator: Tiny Tapeout CMOS5L flow, 6x4 tiles (run tt5)

Images are KLayout renders of each flow stage (`librelane/render_stages.py`); open them in order.

| Metric | Value |
|---|---|
| Die area | 916,214 um^2 |
| Standard cells | 136,824 um^2, 7,829 cells |
| SRAM macros | 98,977 um^2 |
| Setup slack (worst corner, 20 ns clock) | 8.045 ns |
| Hold slack (worst corner) | 0.1074 ns |
| Routing DRC errors | 0 |
| LVS errors | 0 |

## 1. Floorplan (step 13, OpenROAD.Floorplan)

The empty die: 1289.28 x 710.64 um (the Tiny Tapeout 6x4 tile size), core 2.88..1286.40 x 3.78..706.86 um (186 standard-cell rows). The magenta dashed line is the die boundary (prBoundary).

**full view**

![floorplan ](01_floorplan.png)

## 2. Macro placement (step 17, Odb.ManualMacroPlacement)

The two 256x32 SRAM macros (one instruction memory per engine) are fixed at (60, 60) and (60, 260) um, orientation N. Each is 416.64 x 118.78 um.

**full view**

![macro_placement ](02_macro_placement.png)

## 3. Tap / end-cap cells (step 19)

Well-tap and end-cap cells are inserted along every row. The '_cells_only' view hides the power grid layers.

**full view**

![tap_cells ](03_tap_cells.png)

**power grid hidden (TopMetal1/Metal4 layers off), full view**

![tap_cells cells_only](03_tap_cells__cells_only.png)

## 4. Power grid (step 21, OpenROAD.GeneratePDN + Project.BridgeMacroStripes)

Metal1 follow-pin rails plus Metal4 VPWR/VGND stripe pairs (44.96 um pitch, 2.1 um wide). TopMetal1 is not used: the Tiny Tapeout precheck forbids it. Over each SRAM the stripes run straight across and land on the macro's own Metal4 power columns (see the zoom image and src/pdn_cfg.tcl).

**full view**

![power_grid ](04_power_grid.png)

**zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um**

![power_grid zoom_macro_edge](04_power_grid__zoom_macro_edge.png)

## 5. I/O pins (step 27, Odb.ApplyDEFTemplate)

Pin positions come from Tiny Tapeout's fixed 6x4 template DEF (ui_in, uo_out, uio_*, clk, rst_n, ena, power pins), so the chip fits the shuttle's pad frame.

**full view**

![io_pins_tt_template ](05_io_pins_tt_template.png)

## 6. Global placement (step 28, OpenROAD.GlobalPlacement)

Cells are spread to minimize wire length at a 60 % target density. They gather to the right of the SRAMs, next to the memory data/address pins.

**full view**

![global_placement ](06_global_placement.png)

**zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um**

![global_placement zoom_macro_edge](06_global_placement__zoom_macro_edge.png)

**zoom: inside the standard-cell area, 200 x 120 um**

![global_placement zoom_cells](06_global_placement__zoom_cells.png)

**power grid hidden (TopMetal1/Metal4 layers off), full view**

![global_placement cells_only](06_global_placement__cells_only.png)

**power grid hidden, zoom at the SRAM macro edge**

![global_placement cells_only_zoom_macro_edge](06_global_placement__cells_only_zoom_macro_edge.png)

**power grid hidden, zoom inside the standard-cell area**

![global_placement cells_only_zoom_cells](06_global_placement__cells_only_zoom_cells.png)

## 7. Detailed placement (step 34)

Cells snapped legally onto rows and sites with no overlaps.

**full view**

![detailed_placement ](07_detailed_placement.png)

**zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um**

![detailed_placement zoom_macro_edge](07_detailed_placement__zoom_macro_edge.png)

**zoom: inside the standard-cell area, 200 x 120 um**

![detailed_placement zoom_cells](07_detailed_placement__zoom_cells.png)

**power grid hidden (TopMetal1/Metal4 layers off), full view**

![detailed_placement cells_only](07_detailed_placement__cells_only.png)

**power grid hidden, zoom at the SRAM macro edge**

![detailed_placement cells_only_zoom_macro_edge](07_detailed_placement__cells_only_zoom_macro_edge.png)

**power grid hidden, zoom inside the standard-cell area**

![detailed_placement cells_only_zoom_cells](07_detailed_placement__cells_only_zoom_cells.png)

## 8. Clock tree synthesis (step 35, OpenROAD.CTS)

Clock buffers/inverters are added so every flop (and the SRAM clock pins) sees the 50 MHz clock with low skew.

**full view**

![clock_tree_cts ](08_clock_tree_cts.png)

**zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um**

![clock_tree_cts zoom_macro_edge](08_clock_tree_cts__zoom_macro_edge.png)

**zoom: inside the standard-cell area, 200 x 120 um**

![clock_tree_cts zoom_cells](08_clock_tree_cts__zoom_cells.png)

**power grid hidden (TopMetal1/Metal4 layers off), full view**

![clock_tree_cts cells_only](08_clock_tree_cts__cells_only.png)

**power grid hidden, zoom at the SRAM macro edge**

![clock_tree_cts cells_only_zoom_macro_edge](08_clock_tree_cts__cells_only_zoom_macro_edge.png)

**power grid hidden, zoom inside the standard-cell area**

![clock_tree_cts cells_only_zoom_cells](08_clock_tree_cts__cells_only_zoom_cells.png)

## 9. Post-CTS timing repair (step 37)

Hold buffers and resizing after the real clock tree exists.

**full view**

![post_cts_repair ](09_post_cts_repair.png)

**power grid hidden (TopMetal1/Metal4 layers off), full view**

![post_cts_repair cells_only](09_post_cts_repair__cells_only.png)

## 10. Detailed routing (step 44, OpenROAD.DetailedRouting)

Signal wires on Metal1..Metal4 (the TT flow limits routing to Metal4). Red/blue are different metal layers.

**full view**

![detailed_routing ](10_detailed_routing.png)

**zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um**

![detailed_routing zoom_macro_edge](10_detailed_routing__zoom_macro_edge.png)

**zoom: inside the standard-cell area, 200 x 120 um**

![detailed_routing zoom_cells](10_detailed_routing__zoom_cells.png)

**power grid hidden (TopMetal1/Metal4 layers off), full view**

![detailed_routing cells_only](10_detailed_routing__cells_only.png)

**power grid hidden, zoom at the SRAM macro edge**

![detailed_routing cells_only_zoom_macro_edge](10_detailed_routing__cells_only_zoom_macro_edge.png)

**power grid hidden, zoom inside the standard-cell area**

![detailed_routing cells_only_zoom_cells](10_detailed_routing__cells_only_zoom_cells.png)

## 11. Fill insertion (step 52)

Filler and decap cells fill the empty site slots so the n-well and implant layers are continuous.

**full view**

![fill_insertion ](11_fill_insertion.png)

**zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um**

![fill_insertion zoom_macro_edge](11_fill_insertion__zoom_macro_edge.png)

**zoom: inside the standard-cell area, 200 x 120 um**

![fill_insertion zoom_cells](11_fill_insertion__zoom_cells.png)

## 12. Final GDS (KLayout stream-out)

The finished layout as submitted to the foundry flow, including the SRAM macro internals.

**full view**

![final_gds ](12_final_gds.png)

**zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um**

![final_gds zoom_macro_edge](12_final_gds__zoom_macro_edge.png)

**zoom: inside the standard-cell area, 200 x 120 um**

![final_gds zoom_cells](12_final_gds__zoom_cells.png)
