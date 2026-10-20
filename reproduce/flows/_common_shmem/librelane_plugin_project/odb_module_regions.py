# OpenDB script (run by the Project.ModuleRegions step): give every major module its own placement region (fence).
#
# src/floorplan_boxes.json lists boxes in micrometres; each box has a name, a list of instance-name prefixes and a rectangle.
# SYNTH_HIERARCHY_MODE = deferred_flatten keeps the hierarchy in the instance names (u_eng0.alu._1234_), so a prefix identifies the
# module a cell came from. For every box this script creates a dbRegion with that rectangle, a dbGroup attached to the region and puts
# every matching standard cell into the group; OpenROAD's global placement then keeps those cells inside the rectangle (fence).
# A cell goes to the box with the longest matching prefix; cells that match no prefix (clock tree, buffers added later, glue) stay free.
#
# The script prints, per box: cells, cell area, box area and the utilisation the placer has to reach (it fails above --max-util).
import json
import os
from reader import click, click_odb


@click.command()
@click.option("--boxes", required=True, type=click.Path(exists=True), help="floorplan_boxes.json")
@click.option("--max-util", type=float, default=0.85, help="refuse a box that would need a higher utilisation than this")
@click_odb
def regions(reader, boxes, max_util):
    import odb

    block = reader.block
    dbu = block.getDbUnitsPerMicron()
    spec = json.load(open(boxes))
    core = block.getCoreArea()
    die = block.getDieArea()
    print(f"[regions] die {die.xMax() / dbu:.1f} x {die.yMax() / dbu:.1f} um, core {core.xMin() / dbu:.1f},{core.yMin() / dbu:.1f} .. "
          f"{core.xMax() / dbu:.1f},{core.yMax() / dbu:.1f} um, {len(spec['boxes'])} boxes")

    insts = [i for i in block.getInsts() if not i.getMaster().isBlock() and i.getMaster().isCore()]
    macros = [i for i in block.getInsts() if i.getMaster().isBlock()]
    print(f"[regions] {len(insts)} standard cells, {len(macros)} macros")

    # longest-prefix assignment
    table = []
    for b in spec["boxes"]:
        for p in b["match"]:
            table.append((p, b["name"]))
    table.sort(key=lambda t: -len(t[0]))
    members = {b["name"]: [] for b in spec["boxes"]}
    unmatched = 0
    for i in insts:
        n = i.getName().replace("\\", "")
        for p, name in table:
            if n.startswith(p):
                members[name].append(i)
                break
        else:
            unmatched += 1

    problems = []
    rects = []                       # (name, [(x0, y0, x1, y1), ...]) in dbu; a box may be several rectangles (L shape)

    def inter(a, b):
        w = min(a[2], b[2]) - max(a[0], b[0])
        h = min(a[3], b[3]) - max(a[1], b[1])
        return w * h if w > 0 and h > 0 else 0

    for b in spec["boxes"]:
        raw = b["box"]
        parts = raw if isinstance(raw[0], list) else [raw]
        rs = [tuple(int(round(v * dbu)) for v in r) for r in parts]
        for (x0, y0, x1, y1) in rs:
            if not (x0 >= core.xMin() and y0 >= core.yMin() and x1 <= core.xMax() and y1 <= core.yMax()):
                problems.append(f"box {b['name']} sticks out of the core")
        for (n2, r2s) in rects:
            if any(inter(a, c) for a in rs for c in r2s):
                problems.append(f"box {b['name']} overlaps box {n2}")
        rects.append((b["name"], rs))
        macro_area = 0
        for m in macros:
            bb = m.getBBox()
            macro_area += sum(inter(a, (bb.xMin(), bb.yMin(), bb.xMax(), bb.yMax())) for a in rs)   # macros inside a box take room from the cells
        area_cells = sum(i.getMaster().getWidth() * i.getMaster().getHeight() for i in members[b["name"]]) / (dbu * dbu)
        area_box = (sum((a[2] - a[0]) * (a[3] - a[1]) for a in rs) - macro_area) / (dbu * dbu)
        util = area_cells / area_box if area_box else 9.9
        desc = " + ".join(f"({a[0] / dbu:.0f},{a[1] / dbu:.0f})-({a[2] / dbu:.0f},{a[3] / dbu:.0f})" for a in rs)
        print(f"[regions] {b['name']:14s} {len(members[b['name']]):6d} cells {area_cells:9.0f} um^2 in {area_box:9.0f} um^2 free of macros {desc}  utilisation {100 * util:.0f} %")
        if not members[b["name"]]:
            problems.append(f"box {b['name']} matched no cell")
        if util > max_util:
            problems.append(f"box {b['name']} needs {100 * util:.0f} % utilisation (> {100 * max_util:.0f} %)")
    print(f"[regions] {unmatched} standard cells match no box and stay free")
    if problems:
        for p in problems:
            print(f"[regions] ERROR: {p}")
        raise SystemExit(1)

    for b, (name, rs) in zip(spec["boxes"], rects):
        region = odb.dbRegion_create(block, name)
        for (x0, y0, x1, y1) in rs:
            odb.dbBox_create(region, x0, y0, x1, y1)
        group = odb.dbGroup_create(block, "g_" + name)
        region.addGroup(group)
        for i in members[name]:
            group.addInst(i)
    try:
        kinds = sorted({str(r.getRegionType()) for r in block.getRegions()})
    except Exception as e:  # the type accessor is not bound in every OpenROAD build
        kinds = [f"unavailable ({e})"]
    print(f"[regions] created {len(rects)} regions (type reported by OpenDB: {', '.join(kinds)})")


if __name__ == "__main__":
    regions()
