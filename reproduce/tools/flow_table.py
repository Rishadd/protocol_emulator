#!/usr/bin/env python3
"""Writes reproduce/flows/README.md: one row per archived flow with what differs in its configuration from sh4 and the numbers of its final metrics.
    python3 reproduce/tools/flow_table.py"""
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
FL = os.path.join(HERE, "..", "flows")
WHAT = {
    "sh4": "baseline: shared 512-word memory (2P macro), matched power grid 53.04 / 6.74 / 18.545, 8x4 tiles, constraint 20 ns",
    "sh5a": "constraint 17 ns + placement resizer setup margin 0.5",
    "sh5b": "constraint 18 ns + repair after global routing (RUN_POST_GRT_RESIZER_TIMING)",
    "sh5c": "delay-oriented synthesis (SYNTH_STRATEGY DELAY)",
    "sh6": "trap gate moved from imem_shared into the engines (RTL change), otherwise as sh4",
    "sh7": "sh6 RTL + current candidate RTL, constraint 19 ns + repair after global routing",
    "sh8": "candidate RTL, constraint 17 ns + margin 0.5 (the sh5a settings)",
    "sh9a": "candidate RTL, constraint 20 ns (the real clock) + margin 0.5",
    "sh9b": "candidate RTL, constraint 20 ns + margin 1.0 (result identical to sh9a in all 190 metrics)",
    "sh10": "the pushed check version: current RTL (TSTAMP, trigger line), sh8 recipe, WITHOUT the logic analyser (no LA define)",
}
base = json.load(open(os.path.join(FL, "sh4", "config_merged.json")))
rows = []
for tag in WHAT:
    cfg = json.load(open(os.path.join(FL, tag, "config_merged.json")))
    diff = {k: v for k, v in cfg.items() if base.get(k) != v}
    diff.pop("//", None)
    mp = os.path.join(FL, tag, "expected_metrics.json")
    m = json.load(open(mp)) if os.path.exists(mp) else None
    row = [f"`{tag}`", WHAT[tag], ", ".join(f"{k}={json.dumps(v)}" for k, v in diff.items() if k != "VERILOG_DEFINES") or "-"]
    if m:
        s = m["timing__setup__ws__corner:nom_slow_1p08V_125C"]
        per = cfg["CLOCK_PERIOD"] - s
        row += [f"{s:+.2f}", f"{per:.2f} ({1000 / per:.1f} MHz)", f"{m['design__instance__area__stdcell'] / 1000:.0f}k",
                str(int(m["route__drc_errors"])), str(int(m["design__lvs_error__count"])), f"{m['route__wirelength'] / 1000:.0f}k"]
    else:
        row += ["(not finished when archived)"] + [""] * 5
    rows.append(row)
out = ["# Archived flow runs (sh4 to sh9b)", "",
       "Each folder holds the exact inputs of one run (`src/`, `info.yaml`, the complete `config_merged.json`, `family.txt`) and its final metrics. Macros and the project plug-in",
       "shared by a family of runs are in `_common_shmem/` (sh4-sh5c) and `_common_shared_v2/` (sh6-sh9b). Run one again with `bash reproduce/05_run_flow.sh <tag>`; the",
       "script compares the new configuration and all 190 metrics with these files (`reproduce/tools/compare_flow.py`).", "",
       "Slow corner = 1.08 V, 125 C. Achieved period = constraint minus worst setup slack. All runs: 8x4 tiles, Tiny Tapeout flow (LibreLane 3.1.0.dev3, PDK 2bbec755).", "",
       "| run | what is different | config keys that differ from sh4 | slow setup slack (ns) | achieved period (ns) | std-cell area (um2) | route DRC | LVS errors | wire length (um) |",
       "|---|---|---|---|---|---|---|---|---|"]
out += ["| " + " | ".join(r) + " |" for r in rows]
out += ["", "Results folders with pictures: `results/shared_2026-10-20/<tag>_images/index.html`; the sh4 final files: `results/tt_flow_2026-10-20/sh4_final/`.", ""]
open(os.path.join(FL, "README.md"), "w").write("\n".join(out))
print("wrote reproduce/flows/README.md")
