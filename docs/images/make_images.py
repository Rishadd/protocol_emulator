#!/usr/bin/env python3
"""Generate every figure of the user guide into docs/images/ (SVG, plus the capture example). Run:  python3 docs/images/make_images.py"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import figs_a  # noqa: E402

if __name__ == "__main__":
    figs_a.all_figs(HERE)
    for mod in ("figs_b", "figs_c"):
        try:
            m = __import__(mod)
            m.all_figs(HERE)
        except ModuleNotFoundError as e:
            if e.name != mod:
                raise
    print(len([f for f in os.listdir(HERE) if f.endswith(".svg") or f.startswith("fig_") and f.endswith(".png")]), "figures in", HERE)
