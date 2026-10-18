#!/usr/bin/env python3
"""Count Magic DRC violations by rule and by location (inside / outside the SRAM macro boxes).
Usage (in WSL): python3 magic_drc_summary.py <run-dir>"""
import re, sys, glob, collections
run = sys.argv[1]
rpt = glob.glob(run + "/*-magic-drc/reports/*.rpt") + glob.glob(run + "/*-magic-drc/reports/*.txt")
MAC = [(60, 60, 476.64, 178.78), (60, 260, 476.64, 378.78)]
rules = collections.Counter(); inside = outside = 0; out_rules = collections.Counter()
for f in rpt:
    cur = None
    for line in open(f, errors="replace"):
        line = line.strip()
        if not line: continue
        m = re.match(r"^(-?[\d.]+)um\s+(-?[\d.]+)um\s+(-?[\d.]+)um\s+(-?[\d.]+)um$", line)
        if m:
            x0, y0, x1, y1 = (float(m.group(i)) for i in (1, 2, 3, 4))
            ins = any(a <= x0 and x1 <= c and b <= y0 and y1 <= d for a, b, c, d in MAC)
            rules[cur] += 1
            if ins: inside += 1
            else: outside += 1; out_rules[cur] += 1
        elif not line.startswith("---") and line != "tt_um_protocol_emulator":
            cur = line
print("files:", rpt)
print("total", inside + outside, "inside macros", inside, "outside macros", outside)
print("outside by rule:", out_rules.most_common(10))
print("top rules:", rules.most_common(5))
