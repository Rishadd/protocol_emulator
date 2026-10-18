#!/usr/bin/env python3
"""Write README.md and index.html next to the stage images made by render_stages.py (and the module maps of module_map.py).
Usage: python3 librelane/make_gallery.py <images dir> "<run title>" [metrics.json] [--status "<text>"] [--refresh 60]
A missing metrics file is allowed (run still in progress). --refresh makes the page reload itself (live view while the flow runs)."""
import argparse
import html
import json
import os
import re

ap = argparse.ArgumentParser()
ap.add_argument("img_dir")
ap.add_argument("title")
ap.add_argument("metrics", nargs="?")
ap.add_argument("--status", default="")
ap.add_argument("--refresh", type=int, default=0)
a = ap.parse_args()
img_dir, title = a.img_dir, a.title
metrics = json.load(open(a.metrics)) if a.metrics and os.path.exists(a.metrics) else {}

STAGES = {
    "floorplan": ("Floorplan (OpenROAD.Floorplan)",
                  "The empty die: 1289.28 x 710.64 um (the Tiny Tapeout 6x4 tile size), core 2.88..1286.40 x 3.78..706.86 um. "
                  "The magenta dashed line is the die boundary (prBoundary)."),
    "macro_placement": ("Macro placement (Odb.ManualMacroPlacement)",
                        "The two 256x32 SRAM macros (one instruction memory per engine, 416.64 x 118.78 um each) on the bottom edge, "
                        "mirrored (orientation FS) so that their signal pins face up into the core; positions in src/config.json."),
    "tap_cells": ("Tap / end-cap cells",
                  "Well-tap and end-cap cells are inserted along every row. The 'cells only' view hides the power grid layers."),
    "power_grid": ("Power grid (OpenROAD.GeneratePDN + Project.BridgeMacroStripes)",
                   "Metal1 follow-pin rails plus Metal4 VPWR/VGND stripe pairs (44.96 um pitch, 2.1 um wide). TopMetal1 is not used: "
                   "the Tiny Tapeout precheck forbids it. Over each SRAM the stripes run straight across and land on the macro's own "
                   "Metal4 power columns (see the zoom image and src/pdn_cfg.tcl)."),
    "io_pins_tt_template": ("I/O pins (Odb.ApplyDEFTemplate)",
                            "Pin positions come from Tiny Tapeout's fixed 6x4 template DEF (all signal pins on the top edge, x 30-191 um)."),
    "global_placement": ("Global placement (OpenROAD.GlobalPlacement)",
                         "Cells spread to minimise wire length at a 60 % target density. In a fenced run each engine is held inside its "
                         "own column (placement fence) during this step."),
    "detailed_placement": ("Detailed placement (OpenROAD.DetailedPlacement)",
                           "Cells snapped legally onto rows and sites with no overlaps."),
    "clock_tree_cts": ("Clock tree synthesis (OpenROAD.CTS)",
                       "Clock buffers are added so every flop and both SRAM clock pins see the clock with low skew."),
    "post_cts_repair": ("Repair after the clock tree (OpenROAD.ResizerTimingPostCTS)",
                        "Hold buffers and resizing once the real clock tree exists."),
    "detailed_routing": ("Detailed routing (OpenROAD.DetailedRouting)",
                         "Signal wires on Metal2..Metal4 (the TT flow limits routing to Metal4). Red/blue are different metal layers."),
    "fill_insertion": ("Fill insertion",
                       "Filler and decap cells fill the empty site slots so the n-well and implant layers are continuous."),
    "final_gds": ("Final GDS (stream-out)",
                  "The finished layout as submitted to the foundry flow, including the SRAM macro internals."),
}
VARIANTS = {
    "": "full view",
    "zoom_macro_edge": "zoom: SRAM macro edge and the first standard-cell rows, 200 x 120 um",
    "zoom_cells": "zoom: inside the standard-cell area, 200 x 120 um",
    "cells_only": "power grid hidden (TopMetal1/Metal4 layers off), full view",
    "cells_only_zoom_macro_edge": "power grid hidden, zoom at the SRAM macro edge",
    "cells_only_zoom_cells": "power grid hidden, zoom inside the standard-cell area",
}
MAPS = {
    "annotated": "KLayout view with engine regions (white = engine 0, yellow dashed = engine 1) and module regions (coloured outlines)",
    "module_map": "every standard cell in its module's colour, with the same outlines and labels",
}

files = sorted(f for f in os.listdir(img_dir) if f.endswith(".png"))
groups, maps = {}, []
for f in files:
    m = re.match(r"(\d+)_(?:\d+_)?(.*?)(?:__(.*))?\.png$", f)
    if m:
        num, label, var = int(m.group(1)), m.group(2), m.group(3) or ""
        groups.setdefault((num, label), []).append((var, f))
        continue
    m = re.match(r"(.*?)__(annotated|module_map)\.png$", f)
    if m:
        maps.append((m.group(1), m.group(2), f))

md = [f"# {title}", ""]
if a.status:
    md += [f"**Status:** {a.status}", ""]
md += ["Images are KLayout renders of each flow stage (`librelane/render_stages.py`); open them in order. "
       "Module maps (`librelane/module_map.py`) show which engine and module sits where.", ""]
mrows = []
if metrics:
    def g(k, fmt="{:.4g}"):
        v = metrics.get(k)
        return fmt.format(v) if isinstance(v, (int, float)) else "n/a"
    mrows = [("Standard cells", f"{g('design__instance__area__stdcell', '{:,.0f}')} um^2, {g('design__instance__count__stdcell', '{:,.0f}')} cells"),
             ("Hold buffers", g('design__instance__count__hold_buffer', '{:,.0f}')),
             ("Setup slack, slow corner (1.08 V, 125 C)", g('timing__setup__ws__corner:nom_slow_1p08V_125C', '{:+.2f}') + " ns"),
             ("Setup slack, typical corner", g('timing__setup__ws__corner:nom_typ_1p20V_25C', '{:+.2f}') + " ns"),
             ("Hold slack, worst corner", g('timing__hold__ws', '{:+.3f}') + " ns"),
             ("Detailed-route wire length", g('route__wirelength', '{:,.0f}') + " um"),
             ("Routing DRC errors", g('route__drc_errors', '{:.0f}')),
             ("LVS errors", g('design__lvs_error__count', '{:.0f}'))]
    md += ["| Metric | Value |", "|---|---|"] + [f"| {k} | {v} |" for k, v in mrows] + [""]

page = []
if maps:
    md += ["## Where is what: engine and module regions", ""]
    page.append("<section><h2>Where is what: engine and module regions</h2><div class='row'>")
    for step, kind, f in sorted(maps):
        cap = f"{step.replace('placement', ' placement')}: {MAPS[kind]}"
        md += [f"**{cap}**", "", f"![{step} {kind}]({f})", ""]
        page.append(f"<figure><a href='{f}'><img loading='lazy' src='{f}'></a><figcaption>{html.escape(cap)}</figcaption></figure>")
    page.append("</div></section>")
for (num, label), items in sorted(groups.items()):
    ttl, cap = STAGES.get(label, (label, ""))
    md += [f"## {num}. {ttl}", "", cap, ""]
    page.append(f"<section><h2>{num}. {html.escape(ttl)}</h2><p>{html.escape(cap)}</p><div class='row'>")
    for var, f in sorted(items, key=lambda t: list(VARIANTS).index(t[0]) if t[0] in VARIANTS else 99):
        vcap = VARIANTS.get(var, var)
        md += [f"**{vcap}**", "", f"![{label} {var}]({f})", ""]
        page.append(f"<figure><a href='{f}'><img loading='lazy' src='{f}'></a><figcaption>{html.escape(vcap)}</figcaption></figure>")
    page.append("</div></section>")

open(os.path.join(img_dir, "README.md"), "w", encoding="utf-8").write("\n".join(md))
css = ("body{background:#111;color:#ddd;font:15px system-ui;margin:0 auto;max-width:1500px;padding:16px}"
       "h1,h2{font-weight:600}section{margin:28px 0;border-top:1px solid #333;padding-top:8px}"
       ".row{display:flex;flex-wrap:wrap;gap:12px}figure{margin:0;flex:1 1 440px}img{width:100%;border:1px solid #333}"
       "figcaption{font-size:13px;color:#999;padding:4px 0}.status{background:#1d2a1d;border:1px solid #2f4f2f;padding:8px 12px}"
       "table{border-collapse:collapse}td{border:1px solid #333;padding:3px 10px}a{color:#9cf}")
head = f"<meta http-equiv=refresh content={a.refresh}>" if a.refresh else ""
status = f"<p class=status>{html.escape(a.status)}</p>" if a.status else ""
table = ("<table>" + "".join(f"<tr><td>{html.escape(k)}</td><td>{html.escape(v)}</td></tr>" for k, v in mrows) + "</table>") if mrows else ""
open(os.path.join(img_dir, "index.html"), "w", encoding="utf-8").write(
    f"<!doctype html><meta charset=utf-8><meta name=viewport content='width=device-width,initial-scale=1'>{head}<title>{html.escape(title)}</title>"
    f"<style>{css}</style><h1>{html.escape(title)}</h1>{status}{table}" + "".join(page))
print("wrote", img_dir + "/README.md and index.html:", len(files), "images")
