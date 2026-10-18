#!/usr/bin/env python3
"""Module-to-module connectivity of a placed design: how many nets connect each pair of modules (instance-name prefixes of
src/floorplan_boxes.json), and the weighted centre of every module in the placement. Used to design the module boxes from data.

  python3 net_matrix.py --def <placed.def> --boxes src/floorplan_boxes.json [--ignore-nets-over 200]

A net with pins in k modules adds 1/(k-1) to each pair of those modules (a clique with weight 1/(k-1) keeps big fanout nets from
dominating); nets with more than --ignore-nets-over pins (clock, reset) are skipped.
"""
import argparse
import collections
import itertools
import json
import re


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--def", dest="deff", required=True)
    ap.add_argument("--boxes", required=True)
    ap.add_argument("--ignore-nets-over", type=int, default=200)
    ap.add_argument("--json", default=None, help="write the pair weights and module centres here")
    ap.add_argument("--hpwl", action="store_true", help="also print half-perimeter wirelength per module (nets inside one module) and for inter-module nets")
    a = ap.parse_args()
    spec = json.load(open(a.boxes))
    table = sorted(((p, b["name"]) for b in spec["boxes"] for p in b["match"]), key=lambda t: -len(t[0]))
    text = open(a.deff, errors="replace").read()
    dbu = int(re.search(r"UNITS\s+DISTANCE\s+MICRONS\s+(\d+)", text).group(1))
    comp = re.search(r"COMPONENTS\s+\d+\s*;(.*?)END COMPONENTS", text, re.S).group(1)
    mod_of, pos, at = {}, collections.defaultdict(list), {}
    for m in re.finditer(r"-\s+(\S+)\s+(\S+)\s+(?:\+\s+(?!PLACED|FIXED)\S+\s+\S+\s+)*\+\s+(PLACED|FIXED)\s+\(\s*(-?\d+)\s+(-?\d+)\s*\)", comp):
        name, cell, _, x, y = m.groups()
        n = name.replace("\\", "")
        if cell.startswith("RM_IHPSG13"):
            key = "sram:" + n.split(".")[0]
        else:
            key = next((b for p, b in table if n.startswith(p)), None)
        at[name] = (int(x) / dbu, int(y) / dbu)
        if key:
            mod_of[name] = key
            pos[key].append((int(x) / dbu, int(y) / dbu))
    nets = re.search(r"NETS\s+\d+\s*;(.*?)END NETS", text, re.S).group(1)
    pair = collections.Counter()
    intra, inter, n_intra, n_inter = collections.Counter(), 0.0, collections.Counter(), 0
    for chunk in nets.split(";"):
        pins = re.findall(r"\(\s*(\S+)\s+(\S+)\s*\)", chunk)
        if not pins or len(pins) > a.ignore_nets_over:
            continue
        mods = {mod_of.get(i) for i, p in pins if i in mod_of}
        mods.discard(None)
        if a.hpwl:
            pts = [at[i] for i, p in pins if i in at]
            if len(pts) >= 2:
                h = (max(q[0] for q in pts) - min(q[0] for q in pts)) + (max(q[1] for q in pts) - min(q[1] for q in pts))
                if len(mods) == 1:
                    intra[next(iter(mods))] += h
                    n_intra[next(iter(mods))] += 1
                elif len(mods) > 1:
                    inter += h
                    n_inter += 1
        if len(mods) < 2:
            continue
        w = 1.0 / (len(mods) - 1)
        for x, y in itertools.combinations(sorted(mods), 2):
            pair[(x, y)] += w
    print("module centres (um) and cells:")
    for k, v in sorted(pos.items()):
        print(f"  {k:12s} {len(v):6d}  ({sum(p[0] for p in v) / len(v):6.0f},{sum(p[1] for p in v) / len(v):6.0f})")
    print("module pairs by connecting nets (weighted):")
    for (x, y), w in pair.most_common(40):
        cx = lambda k: (sum(p[0] for p in pos[k]) / len(pos[k]), sum(p[1] for p in pos[k]) / len(pos[k])) if pos.get(k) else (0, 0)
        (x1, y1), (x2, y2) = cx(x), cx(y)
        print(f"  {x:10s} - {y:10s} {w:8.0f}   distance in this placement {abs(x1 - x2) + abs(y1 - y2):6.0f} um")
    if a.hpwl:
        print(f"HPWL inside modules (um, nets): total {sum(intra.values()):,.0f}")
        for k, v in sorted(intra.items(), key=lambda kv: -kv[1]):
            print(f"  {k:10s} {v:10,.0f}   {n_intra[k]:5d} nets   {v / max(n_intra[k], 1):6.1f} um/net")
        print(f"HPWL of nets between modules: {inter:,.0f} um over {n_inter} nets ({inter / max(n_inter, 1):.1f} um/net)")
    if a.json:
        json.dump(dict(pairs=[[x, y, w] for (x, y), w in pair.most_common()],
                       centres={k: [sum(p[0] for p in v) / len(v), sum(p[1] for p in v) / len(v)] for k, v in pos.items()},
                       cells={k: len(v) for k, v in pos.items()}), open(a.json, "w"), indent=1)


if __name__ == "__main__":
    main()
