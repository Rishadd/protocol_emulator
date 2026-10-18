#!/usr/bin/env python3
"""Where did each module's cells end up? Reads a placed DEF, colours every standard cell by the module its instance name belongs to
(prefix table of src/floorplan_boxes.json) and writes a placement picture plus a per-module table.

  python3 module_report.py --def <final.def> --boxes src/floorplan_boxes.json --lef <std-cell.lef> --lef <macro.lef> \
          --out <dir> [--title "tt7 boxed"]

Table per module: cells, cell area, share of the cells whose centre lies inside the module's box ("fence compliance"), and the spread of
the cells (bounding box of the 5th..95th percentile of x and y, in um^2, divided by the cell area = how loosely the module is spread).
Needs matplotlib for the picture (the table works without it).
"""
import argparse
import json
import os
import re
import sys


def read_lef_sizes(paths):
    sizes = {}
    for p in paths:
        cur = None
        for line in open(p, errors="replace"):
            m = re.match(r"\s*MACRO\s+(\S+)", line)
            if m:
                cur = m.group(1)
                continue
            m = re.match(r"\s*SIZE\s+([0-9.]+)\s+BY\s+([0-9.]+)", line)
            if m and cur:
                sizes[cur] = (float(m.group(1)), float(m.group(2)))
                cur = None
    return sizes


def read_def(path):
    text = open(path, errors="replace").read()
    dbu = int(re.search(r"UNITS\s+DISTANCE\s+MICRONS\s+(\d+)", text).group(1))
    die = [int(v) / dbu for v in re.search(r"DIEAREA\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)\s*\(\s*(-?\d+)\s+(-?\d+)\s*\)", text).groups()]
    comps = []
    sec = re.search(r"COMPONENTS\s+\d+\s*;(.*?)END COMPONENTS", text, re.S)
    for m in re.finditer(r"-\s+(\S+)\s+(\S+)\s+(?:\+\s+(?!PLACED|FIXED)\S+\s+\S+\s+)*\+\s+(PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)", sec.group(1)):
        name, cell, status, x, y, orient = m.groups()
        comps.append((name.replace("\\", ""), cell, int(x) / dbu, int(y) / dbu, orient))
    return dbu, die, comps


def pct(vals, q):
    v = sorted(vals)
    return v[min(len(v) - 1, max(0, int(round(q * (len(v) - 1)))))]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="deff", required=True)
    ap.add_argument("--boxes", required=True)
    ap.add_argument("--lef", action="append", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--title", default="")
    a = ap.parse_args()
    spec = json.load(open(a.boxes))
    sizes = read_lef_sizes(a.lef)
    dbu, die, comps = read_def(a.deff)
    os.makedirs(a.out, exist_ok=True)
    table = sorted(((p, b["name"]) for b in spec["boxes"] for p in b["match"]), key=lambda t: -len(t[0]))
    boxes = {b["name"]: (b["box"] if isinstance(b["box"][0], list) else [b["box"]]) for b in spec["boxes"]}   # a box is a list of rectangles
    cells = {n: [] for n in boxes}
    other, macros = [], []
    for name, cell, x, y, orient in comps:
        w, h = sizes.get(cell, (0, 0))
        if orient in ("E", "W", "FE", "FW"):
            w, h = h, w
        if cell.startswith("RM_IHPSG13"):
            macros.append((name, x, y, w, h))
            continue
        if w == 0 or any(k in cell for k in ("tap", "endcap", "fill", "decap")):
            continue
        for p, n in table:
            if name.startswith(p):
                cells[n].append((x, y, w, h))
                break
        else:
            other.append((x, y, w, h))
    rows = []
    tot_in = tot = 0
    for n, cs in cells.items():
        if not cs:
            continue
        inside = sum(1 for x, y, w, h in cs if any(r[0] <= x + w / 2 <= r[2] and r[1] <= y + h / 2 <= r[3] for r in boxes[n]))
        area = sum(w * h for x, y, w, h in cs)
        xs = [x + w / 2 for x, y, w, h in cs]
        ys = [y + h / 2 for x, y, w, h in cs]
        spread = (pct(xs, .95) - pct(xs, .05)) * (pct(ys, .95) - pct(ys, .05))
        rows.append((n, len(cs), area, 100 * inside / len(cs), spread, spread / area if area else 0, sum(xs) / len(xs), sum(ys) / len(ys)))
        tot_in += inside
        tot += len(cs)
    lines = [f"{a.title}: {tot} cells assigned to boxes, {len(other)} unassigned, {len(macros)} macros; die {die[2]:.0f} x {die[3]:.0f} um",
             f"{'module':14s} {'cells':>6s} {'area um^2':>10s} {'inside box':>10s} {'5-95% span um^2':>16s} {'span/area':>9s} {'centroid':>14s}"]
    for n, c, ar, comp, sp, ratio, cx, cy in sorted(rows, key=lambda r: -r[2]):
        lines.append(f"{n:14s} {c:6d} {ar:10.0f} {comp:9.1f}% {sp:16.0f} {ratio:9.1f} ({cx:5.0f},{cy:5.0f})")
    lines.append(f"overall fence compliance: {100 * tot_in / max(tot, 1):.1f} % of the assigned cells have their centre inside their box")
    txt = "\n".join(lines)
    print(txt)
    open(os.path.join(a.out, "module_report.txt"), "w").write(txt + "\n")
    json.dump(dict(rows=[dict(module=r[0], cells=r[1], area=r[2], inside_pct=r[3], span=r[4], span_over_area=r[5], cx=r[6], cy=r[7]) for r in rows],
                   compliance_pct=100 * tot_in / max(tot, 1)), open(os.path.join(a.out, "module_report.json"), "w"), indent=1)

    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
        from matplotlib.collections import PatchCollection
        from matplotlib.patches import Rectangle
    except Exception as e:
        print("matplotlib not available, no picture:", e)
        return
    pal = ["#e6194b", "#3cb44b", "#4363d8", "#f58231", "#911eb4", "#46f0f0", "#f032e6", "#bcf60c", "#008080", "#9a6324",
           "#800000", "#808000", "#000075", "#fabebe", "#aaffc3", "#e6beff", "#ffd8b1", "#a9a9a9"]
    names = list(boxes)
    col = {n: pal[i % len(pal)] for i, n in enumerate(names)}
    fig, ax = plt.subplots(figsize=(16, 9.2))
    ax.add_patch(Rectangle((die[0], die[1]), die[2] - die[0], die[3] - die[1], fill=False, ec="black", lw=1.5))
    for name, x, y, w, h in macros:
        ax.add_patch(Rectangle((x, y), w, h, fc="#dddddd", ec="#555555", hatch="///", lw=0.8))
        ax.text(x + w / 2, y + h / 2, name.split(".")[0] + " SRAM", ha="center", va="center", fontsize=8)
    for n, cs in cells.items():
        pc = PatchCollection([Rectangle((x, y), max(w, 1.0), max(h, 1.0)) for x, y, w, h in cs], fc=col[n], ec="none", alpha=0.9)
        ax.add_collection(pc)
    if other:
        ax.add_collection(PatchCollection([Rectangle((x, y), max(w, 1.0), max(h, 1.0)) for x, y, w, h in other], fc="#777777", ec="none", alpha=0.6))
    for n, rs in boxes.items():
        for (x0, y0, x1, y1) in rs:
            ax.add_patch(Rectangle((x0, y0), x1 - x0, y1 - y0, fill=False, ec=col[n], lw=1.6, ls="--"))
        x0, y0, x1, y1 = rs[0]
        ax.text(x0 + 3, y1 - 3, n, color="black", fontsize=7, va="top", ha="left",
                bbox=dict(fc="white", ec=col[n], lw=0.8, pad=1.2, alpha=0.85))
    ax.set_xlim(die[0] - 5, die[2] + 5)
    ax.set_ylim(die[1] - 5, die[3] + 5)
    ax.set_aspect("equal")
    ax.set_title(f"{a.title} - standard cells coloured by module, dashed = module box ({100 * tot_in / max(tot, 1):.1f} % of cells inside)")
    ax.set_xlabel("um")
    fig.tight_layout()
    fig.savefig(os.path.join(a.out, "placement_by_module.png"), dpi=140)
    print("wrote", os.path.join(a.out, "placement_by_module.png"))


if __name__ == "__main__":
    sys.exit(main())
