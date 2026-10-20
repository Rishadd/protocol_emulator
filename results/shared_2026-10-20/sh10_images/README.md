# sh10: current RTL (shared memory, TSTAMP, trigger line) with the sh8 recipe

**Status:** Finished: exit code 0 at 23:53

Images are KLayout renders of each flow stage (`librelane/render_stages.py`); open them in order. Module maps (`librelane/module_map.py`) show which engine and module sits where.

| Metric | Value |
|---|---|
| Standard cells | 405,072 um^2, 28,150 cells |
| Hold buffers | 1,463 |
| Setup slack, slow corner (1.08 V, 125 C) | -2.71 ns |
| Setup slack, typical corner | +4.84 ns |
| Hold slack, worst corner | +0.077 ns |
| Detailed-route wire length | 1,517,361 um |
| Routing DRC errors | 0 |
| LVS errors | 0 |

## Where is what: engine and module regions

**detailed placement: KLayout view with engine regions (white = engine 0, yellow dashed = engine 1) and module regions (coloured outlines)**

![detailedplacement annotated](detailedplacement__annotated.png)

**detailed placement: every standard cell in its module's colour, with the same outlines and labels**

![detailedplacement module_map](detailedplacement__module_map.png)

**global placement: KLayout view with engine regions (white = engine 0, yellow dashed = engine 1) and module regions (coloured outlines)**

![globalplacement annotated](globalplacement__annotated.png)

**global placement: every standard cell in its module's colour, with the same outlines and labels**

![globalplacement module_map](globalplacement__module_map.png)

## 1. Floorplan (OpenROAD.Floorplan)

The empty die: 1289.28 x 710.64 um (the Tiny Tapeout 6x4 tile size), core 2.88..1286.40 x 3.78..706.86 um. The magenta dashed line is the die boundary (prBoundary).

**full view**

![floorplan ](01_floorplan.png)

## 2. Macro placement (Odb.ManualMacroPlacement)

The two 256x32 SRAM macros (one instruction memory per engine, 416.64 x 118.78 um each) on the bottom edge, mirrored (orientation FS) so that their signal pins face up into the core; positions in src/config.json.

**full view**

![macro_placement ](02_macro_placement.png)

## 3. Tap / end-cap cells

Well-tap and end-cap cells are inserted along every row. The 'cells only' view hides the power grid layers.

**full view**

![tap_cells ](03_tap_cells.png)

**power grid hidden (TopMetal1/Metal4 layers off), full view**

![tap_cells cells_only](03_tap_cells__cells_only.png)

## 4. Power grid (OpenROAD.GeneratePDN + Project.BridgeMacroStripes)

Metal1 follow-pin rails plus Metal4 VPWR/VGND stripe pairs (44.96 um pitch, 2.1 um wide). TopMetal1 is not used: the Tiny Tapeout precheck forbids it. Over each SRAM the stripes run straight across and land on the macro's own Metal4 power columns (see the zoom image and src/pdn_cfg.tcl).

**full view**

![power_grid ](04_power_grid.png)

**zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um**

![power_grid zoom_macro_edge](04_power_grid__zoom_macro_edge.png)

## 5. I/O pins (Odb.ApplyDEFTemplate)

Pin positions come from Tiny Tapeout's fixed 6x4 template DEF (all signal pins on the top edge, x 30-191 um).

**full view**

![io_pins_tt_template ](05_io_pins_tt_template.png)

## 6. Global placement (OpenROAD.GlobalPlacement)

Cells spread to minimise wire length at a 60 % target density. In a fenced run each engine is held inside its own column (placement fence) during this step.

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

## 7. Detailed placement (OpenROAD.DetailedPlacement)

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

## 8. Clock tree synthesis (OpenROAD.CTS)

Clock buffers are added so every flop and both SRAM clock pins see the clock with low skew.

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

## 9. Repair after the clock tree (OpenROAD.ResizerTimingPostCTS)

Hold buffers and resizing once the real clock tree exists.

**full view**

![post_cts_repair ](09_post_cts_repair.png)

**power grid hidden (TopMetal1/Metal4 layers off), full view**

![post_cts_repair cells_only](09_post_cts_repair__cells_only.png)

## 10. Detailed routing (OpenROAD.DetailedRouting)

Signal wires on Metal2..Metal4 (the TT flow limits routing to Metal4). Red/blue are different metal layers.

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

## 11. Fill insertion

Filler and decap cells fill the empty site slots so the n-well and implant layers are continuous.

**full view**

![fill_insertion ](11_fill_insertion.png)

**zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um**

![fill_insertion zoom_macro_edge](11_fill_insertion__zoom_macro_edge.png)

**zoom: inside the standard-cell area, 200 x 120 um**

![fill_insertion zoom_cells](11_fill_insertion__zoom_cells.png)

## 12. Final GDS (stream-out)

The finished layout as submitted to the foundry flow, including the SRAM macro internals.

**full view**

![final_gds ](12_final_gds.png)

**zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um**

![final_gds zoom_macro_edge](12_final_gds__zoom_macro_edge.png)

**zoom: inside the standard-cell area, 200 x 120 um**

![final_gds zoom_cells](12_final_gds__zoom_cells.png)
