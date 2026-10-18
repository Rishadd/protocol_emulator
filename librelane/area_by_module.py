#!/usr/bin/env python3
"""Standard-cell area per module of a synthesized netlist whose instance names carry the hierarchy (SYNTH_HIERARCHY_MODE =
deferred_flatten gives names like \\u_eng0.alu._1234_ ).

  python3 area_by_module.py <netlist.v> <liberty.lib> [--depth 2] [--macro-lef <lef>] [--json out.json]

Cells are grouped by the first `depth` path components of the instance name; cells directly inside a module (path shorter than depth + 1)
are listed as <prefix>.(glue). Macros (cells whose type is not in the liberty file) are reported separately with their LEF size.
Prints a table sorted by area and the share of cells that carry a hierarchical name at all.
"""
import argparse
import collections
import json
import re
import sys


def liberty_areas(path):
    areas = {}
    cell = None
    with open(path, errors="replace") as f:
        for line in f:
            m = re.match(r'\s*cell\s*\(\s*"?([^")\s]+)"?\s*\)', line)
            if m:
                cell = m.group(1)
                continue
            m = re.match(r"\s*area\s*:\s*([0-9.eE+-]+)\s*;", line)
            if m and cell and cell not in areas:
                areas[cell] = float(m.group(1))
    return areas


def lef_size(path):
    out = {}
    cur = None
    with open(path, errors="replace") as f:
        for line in f:
            m = re.match(r"\s*MACRO\s+(\S+)", line)
            if m:
                cur = m.group(1)
            m = re.match(r"\s*SIZE\s+([0-9.]+)\s+BY\s+([0-9.]+)", line)
            if m and cur:
                out[cur] = float(m.group(1)) * float(m.group(2))
    return out


def instances(path):
    """Yield (cell_type, instance_name) of the top-level module body of a Yosys netlist."""
    inst = re.compile(r"^\s*(\\?[A-Za-z_][\w$.\\]*)\s+(\\\S+|[A-Za-z_][\w$.\[\]]*)\s*\(\s*$")
    skip = {"module", "input", "output", "inout", "wire", "reg", "assign", "endmodule", "parameter", "localparam", "supply0", "supply1"}
    with open(path, errors="replace") as f:
        for line in f:
            m = inst.match(line)
            if m and m.group(1) not in skip:
                yield m.group(1), m.group(2).lstrip("\\")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("netlist")
    ap.add_argument("liberty")
    ap.add_argument("--depth", type=int, default=2)
    ap.add_argument("--macro-lef", default=None)
    ap.add_argument("--json", default=None)
    a = ap.parse_args()
    areas = liberty_areas(a.liberty)
    macros = lef_size(a.macro_lef) if a.macro_lef else {}
    by = collections.defaultdict(lambda: [0, 0.0])
    unknown = collections.Counter()
    named = total = 0
    macro_rows = []
    for ctype, name in instances(a.netlist):
        parts = name.split(".")
        if ctype in macros and ctype not in areas:
            macro_rows.append((name, ctype, macros[ctype]))
            continue
        if ctype not in areas:
            unknown[ctype] += 1
            continue
        total += 1
        if len(parts) > 1:
            named += 1
        key = ".".join(parts[:a.depth]) if len(parts) > a.depth else (".".join(parts[:-1]) + ".(glue)" if len(parts) > 1 else "(top glue)")
        by[key][0] += 1
        by[key][1] += areas[ctype]
    tot_area = sum(v[1] for v in by.values())
    print(f"{total} standard cells, {tot_area:,.0f} um^2; {100 * named / max(total, 1):.1f} % of the cells carry a hierarchical name")
    print(f"{'module':32s} {'cells':>7s} {'area um^2':>11s} {'share':>7s}")
    rows = sorted(by.items(), key=lambda kv: -kv[1][1])
    for k, (n, ar) in rows:
        print(f"{k:32s} {n:7d} {ar:11,.0f} {100 * ar / tot_area:6.1f}%")
    for name, ctype, ar in macro_rows:
        print(f"macro {name} ({ctype}): {ar:,.0f} um^2")
    if unknown:
        print("cell types without an area:", dict(unknown))
    if a.json:
        json.dump(dict(total_cells=total, total_area=tot_area, named_share=named / max(total, 1),
                       modules={k: dict(cells=n, area=ar) for k, (n, ar) in rows},
                       macros=[dict(name=n, type=t, area=ar) for n, t, ar in macro_rows]), open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
