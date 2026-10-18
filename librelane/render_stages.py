# Render one PNG per physical-design stage of a LibreLane run with KLayout (batch mode).
#   klayout -b -r librelane/render_stages.py -rd run=<run dir> -rd out=<out dir> -rd pdk=<IHP-Open-PDK/ihp-sg13cmos5l>
#                                            [-rd macro_lef=<macro .lef>] [-rd width=2000]
# Every stage is drawn from the DEF its step wrote (layout views are the same ones LibreLane's own KLayout.Render uses);
# the last stage is the final GDS. A zoom into a corner of the macro / standard-cell area is added for the later stages.
import glob
import os
import pya

run = globals().get("run")
out = globals().get("out")
pdk = globals().get("pdk")
macro_lef = globals().get("macro_lef")
width = int(globals().get("width", 2000))

lyt = f"{pdk}/libs.tech/klayout/tech/sg13cmos5l.lyt"
lyp = f"{pdk}/libs.tech/klayout/tech/sg13cmos5l.lyp"
lym = f"{pdk}/libs.tech/klayout/tech/sg13cmos5l.map"
lefs = [f"{pdk}/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_tech.lef",
        f"{pdk}/libs.ref/sg13cmos5l_stdcell/lef/sg13cmos5l_stdcell.lef"]
if macro_lef:
    lefs.append(macro_lef)

# (step directory prefix, short file name, zoom windows [(name, x0, y0, x1, y1)])
ZOOMS = [("zoom_macro_edge", 760, 80, 960, 200), ("zoom_cells", 800, 300, 1000, 420)]
# power-grid layers hidden in the "_cells" variants so the placement is visible
PDN_LAYERS = ("TopMetal1", "Metal4")
STAGES = [
    ("openroad-floorplan", "floorplan", []),
    ("odb-manualmacroplacement", "macro_placement", []),
    ("openroad-tapendcapinsertion", "tap_cells", []),
    ("project-bridgemacrostripes|openroad-generatepdn", "power_grid", ZOOMS[:1]),
    ("odb-applydeftemplate", "io_pins_tt_template", []),
    ("openroad-globalplacement", "global_placement", ZOOMS),
    ("openroad-detailedplacement", "detailed_placement", ZOOMS),
    ("openroad-cts", "clock_tree_cts", ZOOMS),
    ("openroad-resizertimingpostcts", "post_cts_repair", []),
    ("openroad-detailedrouting", "detailed_routing", ZOOMS),
    ("openroad-fillinsertion", "fill_insertion", ZOOMS),
]
CELLS_ONLY = ("tap_cells", "global_placement", "detailed_placement", "clock_tree_cts", "post_cts_repair", "detailed_routing")

os.makedirs(out, exist_ok=True)
tech = pya.Technology()
tech.load(lyt)


def view_for(path):
    lv = pya.LayoutView()
    lv.set_config("grid-visible", "false")
    lv.set_config("text-visible", "false")
    lv.set_config("background-color", "#000000")
    if path.endswith(".gds"):
        lv.load_layout(path)
    else:
        opts = tech.load_layout_options
        opts.lefdef_config.map_file = lym
        opts.lefdef_config.macro_resolution_mode = 1
        opts.lefdef_config.read_lef_with_def = False
        opts.lefdef_config.lef_files = lefs
        lv.load_layout(path, opts, lyt)
    lv.max_hier()
    lv.load_layer_props(lyp)
    return lv


def set_pdn_visible(lv, visible):
    it = lv.begin_layers()
    while not it.at_end():
        lp = it.current()
        if lp.has_children() is False and lp.name.split(".")[0] in PDN_LAYERS:
            lp = lp.dup()
            lp.visible = visible
            lv.set_layer_properties(it, lp)
        it.next()


def shoot(lv, name, box=None):
    bb = lv.active_cellview().layout().top_cell().dbbox()
    if box is None:
        box = bb
    else:
        box = pya.DBox(*box)
    lv.zoom_box(box.enlarged(box.width() * 0.01, box.height() * 0.01))
    w = width
    h = max(200, int(w * box.height() / box.width()))
    lv.save_image_with_options(f"{out}/{name}.png", w, h, oversampling=0)
    print("wrote", name)


n = 0
for names, label, zooms in STAGES:
    d = []
    for nm in names.split("|"):
        d = glob.glob(f"{run}/??-{nm}")
        if d:
            break
    defs = glob.glob(f"{d[0]}/*.def") if d else []
    if not defs:
        print("skip", names, label)
        continue
    n += 1
    base = f"{n:02d}_{label}"
    if os.path.exists(f"{out}/{base}.png") and os.path.getmtime(f"{out}/{base}.png") >= os.path.getmtime(defs[0]):
        print("up to date", base)      # incremental: a live watcher re-runs this script after every new stage
        continue
    lv = view_for(defs[0])
    shoot(lv, base)
    for zname, x0, y0, x1, y1 in zooms:
        shoot(lv, f"{base}__{zname}", (x0, y0, x1, y1))
    if label in CELLS_ONLY:
        set_pdn_visible(lv, False)
        shoot(lv, f"{base}__cells_only")
        for zname, x0, y0, x1, y1 in zooms:
            shoot(lv, f"{base}__cells_only_{zname}", (x0, y0, x1, y1))

gds = glob.glob(f"{run}/final/gds/*.gds")
if gds and not os.path.exists(f"{out}/{n + 1:02d}_final_gds.png"):
    n += 1
    lv = view_for(gds[0])
    base = f"{n:02d}_final_gds"
    shoot(lv, base)
    for zname, x0, y0, x1, y1 in ZOOMS:
        shoot(lv, f"{base}__{zname}", (x0, y0, x1, y1))
