#!/usr/bin/env python3
"""Compare a rerun of an archived flow with the archive: python3 compare_flow.py <reproduce/flows/<tag>> <work folder> <run tag>
Configuration: every key of the archived config_merged.json must have the same value in the new one.
Metrics: every key of the archived metrics.json (area, cell counts by class, wire length, DRC, LVS, antenna, slack at the three corners ...)
must have the same value in the new run. The flow is deterministic for the same inputs and tool versions, so the expected result is an exact match;
a difference is listed, with the relative difference, so a changed tool version shows up as small drifts and not as a silent pass."""
import json
import os
import sys

arch, work, tag = sys.argv[1:4]
ok = True
new_cfg = json.load(open(os.path.join(work, "src", "config_merged.json")))
old_cfg = json.load(open(os.path.join(arch, "config_merged.json")))
bad = [k for k in old_cfg if new_cfg.get(k) != old_cfg[k]]
print(f"config: {len(old_cfg) - len(bad)}/{len(old_cfg)} keys identical" + (f"; DIFFERENT: {bad}" if bad else ""))
ok &= not bad
mf = os.path.join(arch, "expected_metrics.json")
if not os.path.exists(mf):
    mf = os.path.join(arch, "metrics.json")                      # an archive made by the results folders (results/tt_flow_*/<run>/)
nf = os.path.join(work, "runs", tag, "final", "metrics.json")
if not os.path.exists(mf):
    print("no archived metrics for this run (the archive was made before it finished): the new run's metrics are", nf)
elif not os.path.exists(nf):
    print("the new run has no final metrics.json: the flow did not finish"); ok = False
else:
    old, new = json.load(open(mf)), json.load(open(nf))
    diffs = []
    for k, v in old.items():
        w = new.get(k)
        if w != v:
            rel = abs(w - v) / abs(v) if isinstance(v, (int, float)) and isinstance(w, (int, float)) and v else None
            diffs.append((k, v, w, rel))
    print(f"metrics: {len(old) - len(diffs)}/{len(old)} identical")
    for k, v, w, rel in diffs[:40]:
        print(f"  {k}: archived {v} new {w}" + (f" ({rel:.2%})" if rel is not None else ""))
    key = "timing__setup__ws__corner:nom_slow_1p08V_125C"
    print(f"slow-corner worst setup slack: archived {old.get(key)} new {new.get(key)}")
    ok &= not diffs
print("RESULT compare_flow:", "IDENTICAL" if ok else "DIFFERENT")
sys.exit(0 if ok else 1)
