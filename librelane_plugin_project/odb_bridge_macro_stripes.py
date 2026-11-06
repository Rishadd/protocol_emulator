# OpenDB script (run by the Project.BridgeMacroStripes step): bridge the Metal4 power stripes across the SRAM macros.
#
# OpenROAD's pdngen cuts every power stripe where it meets a macro (stops about 0.5 um short of the macro edge), even with
# -skip_trim. With a Metal4-only grid there is no TopMetal1 to connect the macro's Metal4 power pins from above, so the
# stripes have to run over the macro and overlap its pin columns instead. For each macro this script finds, per VPWR/VGND
# stripe whose x range lies inside the macro, the segment ending at/below the macro bottom and the segment starting at/above
# the macro top, and fills the gap between them with one Metal4 shape of the same net and width. A macro on the bottom (top)
# edge has no segment below (above) it, so the shape then starts (ends) where the full stripes do. src/pdn_cfg.tcl and the pitch
# in src/config.json guarantee that those x positions coincide with macro power columns of the same net.
from reader import click, click_odb

MACRO_PREFIX = "RM_IHPSG13_"
LAYER = "Metal4"
NETS = ("VPWR", "VGND")


@click.command()
@click_odb
def bridge(reader):
    block = reader.block
    layer = reader.tech.findLayer(LAYER)
    macros = [i for i in block.getInsts() if i.getMaster().getName().startswith(MACRO_PREFIX)]
    print(f"[bridge] {len(macros)} SRAM macro instance(s)")
    import odb

    added = 0
    pins_fixed = 0
    bridged = set()
    for net_name in NETS:
        net = block.findNet(net_name)
        if net is None:
            raise SystemExit(f"net {net_name} not found")
        swires = net.getSWires()
        if not swires:
            raise SystemExit(f"net {net_name} has no special wires: run after OpenROAD.GeneratePDN")
        swire = swires[0]
        boxes = [
            b
            for w in swires
            for b in w.getWires()
            if not b.isVia() and b.getTechLayer() is not None and b.getTechLayer().getName() == LAYER
        ]
        vertical = [b for b in boxes if b.yMax() - b.yMin() > b.xMax() - b.xMin()]
        # where a full stripe starts and ends (the core edges): used when a macro sits on the bottom or top edge,
        # because pdngen then removes the short stripe stub between the die edge and the macro as floating
        grid_lo = min(b.yMin() for b in vertical)
        grid_hi = max(b.yMax() for b in vertical)
        for inst in macros:
            bb = inst.getBBox()
            mx0, mx1, my0, my1 = bb.xMin(), bb.xMax(), bb.yMin(), bb.yMax()
            stripes = {}
            for b in vertical:
                cx = (b.xMin() + b.xMax()) // 2
                if mx0 < cx < mx1:
                    stripes.setdefault((b.xMin(), b.xMax()), []).append(b)
            for (x0, x1), segs in sorted(stripes.items()):
                below = [s for s in segs if s.yMax() <= my0 + 1000]
                above = [s for s in segs if s.yMin() >= my1 - 1000]
                if not below and not above:
                    continue  # stripe does not reach the macro: nothing to bridge
                ylo = max(s.yMax() for s in below) if below else grid_lo
                yhi = min(s.yMin() for s in above) if above else grid_hi
                if yhi <= ylo:
                    continue
                odb.dbSBox_create(swire, layer, x0, ylo, x1, yhi, segs[0].getWireShapeType())
                added += 1
                bridged.add((x0, x1, min([s.yMin() for s in segs] + [ylo]), max([s.yMax() for s in segs] + [yhi])))
            print(f"[bridge] {net_name} {inst.getName()}: stripes now bridged: {added}")

        # A stripe that is not over any macro can still stop short: with two macros side by side, pdngen leaves the stripes in the
        # channel between them as a stub that ends at the macro tops (found on the 8x4 chip with the logic analyser: 460.94 um short
        # of the top edge, precheck "Port VGND is too far from top edge"). Fill such stripes up to the grid edges the same way.
        bridged_x = {(x0, x1) for x0, x1, _, _ in bridged}
        by_x = {}
        for b in vertical:
            by_x.setdefault((b.xMin(), b.xMax()), []).append(b)
        for (x0, x1), segs in sorted(by_x.items()):
            if (x0, x1) in bridged_x:
                continue
            lo = min(s.yMin() for s in segs)
            hi = max(s.yMax() for s in segs)
            if lo <= grid_lo + 1000 and hi >= grid_hi - 1000:
                continue  # already a full-height stripe
            if lo > grid_lo:
                odb.dbSBox_create(swire, layer, x0, grid_lo, x1, lo, segs[0].getWireShapeType())
                added += 1
            if hi < grid_hi:
                odb.dbSBox_create(swire, layer, x0, hi, x1, grid_hi, segs[0].getWireShapeType())
                added += 1
            bridged.add((x0, x1, min(lo, grid_lo), max(hi, grid_hi)))
            print(f"[bridge] {net_name}: short stripe x {x0 / 1000:.2f}-{x1 / 1000:.2f} extended to the grid edges")

        # The Tiny Tapeout precheck wants every power port in the LEF to be one rectangle reaching both die edges, but
        # pdngen made one pin box per stripe segment. Replace the segment pin boxes of each bridged stripe with one
        # full-height pin box.
        bterm = block.findBTerm(net_name)
        if bterm is None:
            continue
        for x0, x1, ymin, ymax in sorted(bridged):
            for bpin in list(bterm.getBPins()):
                boxes = [b for b in bpin.getBoxes() if b.getTechLayer().getName() == LAYER and b.xMin() == x0 and b.xMax() == x1]
                if not boxes:
                    continue
                for b in boxes:
                    odb.dbBox_destroy(b)
                if not list(bpin.getBoxes()):
                    odb.dbBPin_destroy(bpin)
            bpin = odb.dbBPin_create(bterm)
            odb.dbBox_create(bpin, layer, x0, ymin, x1, ymax)
            bpin.setPlacementStatus("FIRM")
        pins_fixed += len(bridged)
        bridged.clear()
    print(f"[bridge] added {added} Metal4 bridge shape(s), merged the pin boxes of {pins_fixed} stripe(s) into full-height pins")


if __name__ == "__main__":
    bridge()
