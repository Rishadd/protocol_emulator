#!/usr/bin/env python3
"""Side-by-side table of the metrics of several flow runs.
  python compare_runs.py tt5=results/tt_flow_2026-10-17/tt5/metrics.json tt6=.../metrics.json tt7=.../metrics.json [--md out.md]
"""
import argparse
import json

ROWS = [
    ("cells (standard, excluding fill)", "design__instance__count__stdcell", "{:,.0f}"),
    ("standard-cell area um^2", "design__instance__area__stdcell", "{:,.0f}"),
    ("timing repair buffers (count)", "design__instance__count__class:timing_repair_buffer", "{:,.0f}"),
    ("hold buffers (count)", "design__instance__count__hold_buffer", "{:,.0f}"),
    ("timing repair buffer area um^2", "design__instance__area__class:timing_repair_buffer", "{:,.0f}"),
    ("clock buffers (count)", "design__instance__count__class:clock_buffer", "{:,.0f}"),
    ("instance utilisation (cells+macros / core)", "design__instance__utilization", "{:.3f}"),
    ("global-route wirelength um (estimate before detailed route)", "global_route__wirelength", "{:,.0f}"),
    ("detailed-route wirelength um", "route__wirelength", "{:,.0f}"),
    ("vias", "route__vias", "{:,.0f}"),
    ("routing DRC errors", "route__drc_errors", "{:,.0f}"),
    ("detailed-route iterations with errors", None, None),
    ("antenna violating nets", "antenna__violating__nets", "{:,.0f}"),
    ("setup worst slack, slow corner ns", "timing__setup__ws__corner:nom_slow_1p08V_125C", "{:+.3f}"),
    ("setup worst slack, typical ns", "timing__setup__ws__corner:nom_typ_1p20V_25C", "{:+.3f}"),
    ("hold worst slack, fast corner ns", "timing__hold__ws__corner:nom_fast_1p32V_m40C", "{:+.3f}"),
    ("setup violations", "timing__setup_vio__count", "{:,.0f}"),
    ("hold violations", "timing__hold_vio__count", "{:,.0f}"),
    ("clock skew worst setup ns", "clock__skew__worst_setup", "{:.3f}"),
    ("max slew violations", "design__max_slew_violation__count", "{:,.0f}"),
    ("max cap violations", "design__max_cap_violation__count", "{:,.0f}"),
    ("max fanout violations", "design__max_fanout_violation__count", "{:,.0f}"),
    ("LVS errors", "design__lvs_error__count", "{:,.0f}"),
    ("power (liberty-based) mW", "power__total", "{:.2f}"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("runs", nargs="+")
    ap.add_argument("--md", default=None)
    a = ap.parse_args()
    names, ms = [], []
    for r in a.runs:
        n, p = r.split("=", 1)
        names.append(n)
        ms.append(json.load(open(p)))
    lines = ["| metric | " + " | ".join(names) + " |", "|---|" + "---|" * len(names)]
    for label, key, fmt in ROWS:
        if key is None:
            vals = []
            for m in ms:
                it = [m.get(f"route__drc_errors__iter:{i}") for i in range(30)]
                vals.append(str([x for x in it if x is not None]))
        else:
            vals = []
            for m in ms:
                v = m.get(key)
                if key == "power__total" and v is not None:
                    v = v * 1000
                vals.append(fmt.format(v) if isinstance(v, (int, float)) else "-")
        lines.append(f"| {label} | " + " | ".join(vals) + " |")
    out = "\n".join(lines)
    print(out)
    if a.md:
        open(a.md, "w").write(out + "\n")


if __name__ == "__main__":
    main()
