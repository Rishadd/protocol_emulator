#!/usr/bin/env python3
"""Annotated placement: which engine and which module sits where.

  python3 module_map.py --def <placed.def> --lef <std-cell.lef> --lef <macro.lef> --out <dir> [--bg <klayout png>] [--title "..."]

Reads the placed DEF, assigns every standard cell to a module from its hierarchical instance name (u_eng0.alu._123_ -> engine 0 ALU),
and writes
  <prefix>module_map.png  : every cell drawn in its module's colour, region outline and label per module, engine regions outlined
  <prefix>annotated.png   : the same outlines and labels drawn over the KLayout picture of the step (--bg, rendered by render_stages.py
                            from the die box enlarged by 1 % on each side), so the real layout can be read
A region is the smoothed cell-density contour that holds about 75 % of a module's cells (90 % for an engine); the label sits at the
median cell position. Buffers inserted by the tools (place*, fanout*, hold*, wire*, ...) belong to no module and are drawn grey.
"""
import argparse
import os
import re
import sys

import numpy as np

# (key, label, colour, instance-name prefixes after "u_engN.")
ENGINE_MODULES = [
    ("alu", "ALU + registers", "#e6194b", ["alu."]),
    ("crc", "CRC", "#3cb44b", ["crc."]),
    ("fifo", "TX/RX FIFOs", "#4363d8", ["tx_fifo.", "rx_fifo."]),
    ("shift", "OSR/ISR shifters", "#f58231", ["osr.", "isr."]),
    ("ctrl", "control (decode, PC, counters)", "#911eb4", ["cu.", "pc_i.", "dc.", "lc.", "imem."]),
    ("pins", "pin block", "#f032e6", ["pins."]),
]
TOP_MODULES = [
    ("mgmt", "management", "#ffe119", ["u_mgmt."]),
    ("spi", "SPI link", "#bcf60c", ["u_spi."]),
    ("pinmgr", "pin manager", "#46f0f0", ["u_pins."]),
]
ENGINE_COL = {0: "#ffffff", 1: "#ffd23f"}


def read_lef_sizes(paths):
    sizes, cur = {}, None
    for p in paths:
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
    sec = re.search(r"COMPONENTS\s+\d+\s*;(.*?)END COMPONENTS", text, re.S).group(1)
    comps = []
    for m in re.finditer(r"-\s+(\S+)\s+(\S+)\s+(?:\+\s+(?!PLACED|FIXED)\S+\s+\S+\s+)*\+\s+(PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)\s+(\S+)",
                         sec):
        name, cell, _, x, y, orient = m.groups()
        comps.append((name.replace("\\", ""), cell, int(x) / dbu, int(y) / dbu, orient))
    return die, comps


def classify(name):
    """(group key, engine or None) of an instance name."""
    m = re.match(r"u_eng(\d)\.(.*)", name)
    if m:
        eng, rest = int(m.group(1)), m.group(2)
        for key, _, _, prefixes in ENGINE_MODULES:
            if any(rest.startswith(p) for p in prefixes):
                return key, eng
        return "ctrl", eng                      # engine_top glue (u_engN._123_): decode / select logic around the control unit
    for key, _, _, prefixes in TOP_MODULES:
        if any(name.startswith(p) for p in prefixes):
            return key, None
    return None, None


def density(xs, ys, die, bin_um=8.0, sigma_bins=2.5):
    nx, ny = int(np.ceil(die[2] / bin_um)), int(np.ceil(die[3] / bin_um))
    h, xe, ye = np.histogram2d(xs, ys, bins=[nx, ny], range=[[0, nx * bin_um], [0, ny * bin_um]])
    r = int(3 * sigma_bins)
    k = np.exp(-0.5 * (np.arange(-r, r + 1) / sigma_bins) ** 2)
    k /= k.sum()
    h = np.apply_along_axis(lambda v: np.convolve(v, k, mode="same"), 0, h)
    h = np.apply_along_axis(lambda v: np.convolve(v, k, mode="same"), 1, h)
    xc = (xe[:-1] + xe[1:]) / 2
    yc = (ye[:-1] + ye[1:]) / 2
    return xc, yc, h


def level_for(xs, ys, xc, yc, h, share):
    """density level whose contour holds about `share` of the points"""
    ix = np.clip(np.searchsorted(xc, xs) - 1, 0, len(xc) - 1)
    iy = np.clip(np.searchsorted(yc, ys) - 1, 0, len(yc) - 1)
    return float(np.quantile(h[ix, iy], 1 - share))


def spread_labels(points, min_dx=95, min_dy=16):
    """move label anchors down a little where two would overlap"""
    placed = []
    for x, y in points:
        while any(abs(x - px) < min_dx and abs(y - py) < min_dy for px, py in placed):
            y -= min_dy
        placed.append((x, y))
    return placed


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="deff", required=True)
    ap.add_argument("--lef", action="append", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--bg", default=None)
    ap.add_argument("--prefix", default="")
    ap.add_argument("--title", default="")
    a = ap.parse_args()

    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.collections import PatchCollection
    from matplotlib.patches import Patch, Rectangle

    sizes = read_lef_sizes(a.lef)
    die, comps = read_def(a.deff)
    groups, other, macros = {}, [], []
    for name, cell, x, y, orient in comps:
        w, h = sizes.get(cell, (0, 0))
        if orient in ("E", "W", "FE", "FW"):
            w, h = h, w
        if cell.startswith("RM_IHPSG13"):
            macros.append((name, x, y, w, h))
            continue
        if w == 0 or any(k in cell for k in ("tap", "endcap", "fill", "decap")):
            continue
        key, eng = classify(name)
        if key is None:
            other.append((x, y, w, h))
        else:
            groups.setdefault((key, eng), []).append((x, y, w, h))

    colour = {k: c for k, _, c, _ in ENGINE_MODULES + TOP_MODULES}
    label = {k: l for k, l, _, _ in ENGINE_MODULES + TOP_MODULES}

    def regions(ax, on_dark):
        # engine regions first (behind), then module outlines and labels
        for eng in (0, 1):
            cs = [c for (k, e), v in groups.items() if e == eng for c in v]
            xs = np.array([x + w / 2 for x, y, w, h in cs])
            ys = np.array([y + h / 2 for x, y, w, h in cs])
            xc, yc, hh = density(xs, ys, die, sigma_bins=4.0)
            lv = level_for(xs, ys, xc, yc, hh, 0.90)
            ax.contourf(xc, yc, hh.T, levels=[lv, hh.max() + 1], colors=[ENGINE_COL[eng]], alpha=0.10 if on_dark else 0.08)
            ax.contour(xc, yc, hh.T, levels=[lv], colors=[ENGINE_COL[eng] if on_dark else "black"], linewidths=3.0,
                       linestyles="--" if eng else "-")
        anchors, texts = [], []
        for (k, e), cs in sorted(groups.items(), key=lambda t: (t[0][1] is None, t[0][1] or 0, t[0][0])):
            xs = np.array([x + w / 2 for x, y, w, h in cs])
            ys = np.array([y + h / 2 for x, y, w, h in cs])
            xc, yc, hh = density(xs, ys, die)
            lv = level_for(xs, ys, xc, yc, hh, 0.75)
            ax.contour(xc, yc, hh.T, levels=[lv], colors=[colour[k]], linewidths=2.2)
            anchors.append((float(np.median(xs)), float(np.median(ys))))
            texts.append(((("E%d " % e) if e is not None else "") + label[k].split(" (")[0], colour[k], k, e, len(cs)))
        for (x, y), (t, c, k, e, n) in zip(spread_labels(anchors), texts):
            ax.text(x, y, t, color="black", fontsize=9, fontweight="bold", ha="center", va="center",
                    bbox=dict(fc=c, ec="black", lw=0.8, pad=1.5, alpha=0.92))

    def engine_tags(ax, on_dark):
        for eng in (0, 1):
            cs = [c for (k, e), v in groups.items() if e == eng for c in v]
            xs = np.array([x + w / 2 for x, y, w, h in cs])
            ax.text(float(np.median(xs)), die[3] - 22, f"ENGINE {eng}" + (" (solid outline)" if eng == 0 else " (dashed outline)"),
                    ha="center", va="center", fontsize=13, fontweight="bold", color="black",
                    bbox=dict(fc=ENGINE_COL[eng] if on_dark else "white", ec="black", lw=1.5, pad=3))
        for name, x, y, w, h in macros:
            eng = name.split(".")[0].replace("u_eng", "")
            ax.text(x + w / 2, y + h / 2, f"SRAM engine {eng}\n(256 x 32 program memory)", ha="center", va="center", fontsize=10,
                    fontweight="bold", color="black", bbox=dict(fc="#dddddd", ec="black", lw=1, pad=3, alpha=0.9))

    def legend(ax):
        hs = [Patch(fc=colour[k], ec="black", label=l) for k, l, _, _ in ENGINE_MODULES + TOP_MODULES]
        hs.append(Patch(fc="#888888", ec="black", label="buffers added by the tools (no module)"))
        ax.legend(handles=hs, loc="upper right", fontsize=8, framealpha=0.92, title="module regions (~75 % of its cells inside)",
                  title_fontsize=8)

    def frame(ax):
        ax.set_xlim(die[0] - 0.01 * die[2], die[2] * 1.01)
        ax.set_ylim(die[1] - 0.01 * die[3], die[3] * 1.01)
        ax.set_aspect("equal")
        ax.set_xlabel("x (um)")
        ax.set_ylabel("y (um)")

    os.makedirs(a.out, exist_ok=True)
    # 1: cells coloured by module
    fig, ax = plt.subplots(figsize=(18, 10.4))
    ax.add_patch(Rectangle((die[0], die[1]), die[2] - die[0], die[3] - die[1], fill=False, ec="black", lw=1.5))
    for name, x, y, w, h in macros:
        ax.add_patch(Rectangle((x, y), w, h, fc="#eeeeee", ec="#555555", hatch="///", lw=0.8))
    if other:
        ax.add_collection(PatchCollection([Rectangle((x, y), max(w, 1), max(h, 1)) for x, y, w, h in other], fc="#888888", ec="none", alpha=0.6))
    for (k, e), cs in groups.items():
        ax.add_collection(PatchCollection([Rectangle((x, y), max(w, 1), max(h, 1)) for x, y, w, h in cs], fc=colour[k], ec="none",
                                          alpha=0.85 if e != 1 else 0.6))
    regions(ax, on_dark=False)
    engine_tags(ax, on_dark=False)
    legend(ax)
    frame(ax)
    ax.set_title(f"{a.title}: every standard cell in its module's colour; thick outline = engine region (~90 % of its cells)")
    fig.tight_layout()
    p1 = os.path.join(a.out, a.prefix + "module_map.png")
    fig.savefig(p1, dpi=120)
    plt.close(fig)
    print("wrote", p1)

    # 2: outlines and labels over the KLayout picture
    if a.bg:
        img = plt.imread(a.bg)
        fig, ax = plt.subplots(figsize=(18, 10.4))
        ex = [die[0] - 0.01 * die[2], die[2] * 1.01, die[1] - 0.01 * die[3], die[3] * 1.01]
        ax.imshow(img, extent=ex, origin="upper", interpolation="bilinear")
        regions(ax, on_dark=True)
        engine_tags(ax, on_dark=True)
        legend(ax)
        frame(ax)
        ax.set_title(f"{a.title}: KLayout view with module regions (coloured outlines) and engine regions (white = engine 0, yellow dashed = engine 1)")
        fig.tight_layout()
        p2 = os.path.join(a.out, a.prefix + "annotated.png")
        fig.savefig(p2, dpi=120)
        plt.close(fig)
        print("wrote", p2)

    # cell counts per group
    for (k, e), cs in sorted(groups.items(), key=lambda t: (t[0][1] is None, t[0][1] or 0, t[0][0])):
        print(f"  {('engine %d' % e) if e is not None else 'top':9s} {label[k]:32s} {len(cs):6d} cells")
    print(f"  {'':9s} {'buffers added by the tools':32s} {len(other):6d} cells")


if __name__ == "__main__":
    sys.exit(main())
