#!/usr/bin/env python3
"""Capture with the on-chip logic analyser and write a VCD file for GTKWave.

    python3 host/la_capture.py --sim --demo --out capture.vcd            # simulated DE0-Nano top, engine 0 blinks uio[0], rising edge of uio[0] triggers
    python3 host/la_capture.py --port /dev/ttyACM0 --trig rise --chan 0 --post-words 40 --out capture.vcd --gtkwave
Channels: 0-7 uio[0..7], 8-12 ui_in[3..7], 13 / 14 engine 0 / 1 running, 15 the engines' trigger line (RPUT TRIG).
Needs a chip built with the analyser (-DLA, the DE0-Nano project has it on). One time unit in the VCD is one 20 ns system clock.
"""
import argparse
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import asm as A                                           # noqa: E402
import la_host as L                                       # noqa: E402
import la_model as LM                                     # noqa: E402
import shmem_host as S                                    # noqa: E402
from chip_host import SimLink                             # noqa: E402

NAMES = [f"uio_{i}" for i in range(8)] + [f"ui_in_{i}" for i in range(3, 8)] + ["run0", "run1", "trigger"]


def blink(half):
    a = A.Asm()
    a.REGION()
    a.DIRO(0)
    a.label("l")
    a.SETH(0)
    a.WAIT(half)
    a.SETLO(0)
    a.WAIT(half)
    a.JMP("l")
    return a


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--sim", action="store_true", help="simulated DE0-Nano top with the analyser")
    g.add_argument("--port", help="serial port of the Pico bridge")
    ap.add_argument("--trig", default="rise", choices=sorted(L.TRIG))
    ap.add_argument("--chan", type=int, default=0, help="trigger channel for rise / fall")
    ap.add_argument("--mask", type=lambda x: int(x, 0), default=0, help="pattern trigger: channels that must match")
    ap.add_argument("--value", type=lambda x: int(x, 0), default=0, help="pattern trigger: their values")
    ap.add_argument("--post-words", type=int, default=40, help="words recorded after the trigger (the trigger word counts)")
    ap.add_argument("--demo", action="store_true", help="first start a program on engine 0 that toggles uio[0] (the pad is claimed for engine 0)")
    ap.add_argument("--out", default="capture.vcd")
    ap.add_argument("--gtkwave", action="store_true", help="open the file in GTKWave when done")
    args = ap.parse_args()

    link = SimLink(fpga=True, la=True) if args.sim else __import__("serial_link").SerialLink(args.port)
    with link:
        chip = S.ShmemHost(link)
        chip.set_misc(irq_mask=0x100, dbg_en=1)
        la = L.LogicAnalyserHost(chip)
        la.configure(trig=args.trig, chan=args.chan, mask=args.mask, value=args.value, post_words=args.post_words)
        if args.demo:
            chip.claim_pad(0, 0)
            chip.start(0, S.Image.from_asm("blink", blink(60 if args.sim else 5_000_000), origin=0))
        la.arm()
        if args.trig == "manual":
            la.trigger()
        if not la.wait_done(max_polls=20000):
            print("no trigger: the capture never completed (state", la.status()["state"] + ")")
            return 1
        changes, end = la.waveform()
    LM.vcd(changes, end, names=NAMES, path=args.out)
    print(f"{len(changes)} value changes over {end} clocks written to {args.out}")
    if args.sim and args.demo:                                 # self-check used by the regression: uio[0] toggled with the programmed period
        edges = [t for (t, v), (_, w) in zip(changes, changes[1:]) if (v ^ w) & 1] if len(changes) > 1 else []
        gaps = {b - a for a, b in zip(edges[1:], edges[2:])}      # the first gap is the pre-trigger sample
        ok = len(edges) > 8 and gaps <= {62, 63}
        print("RESULT la_capture:", "PASS" if ok else f"FAIL (edges {len(edges)}, gaps {sorted(gaps)})")
        return 0 if ok else 1
    if args.gtkwave:
        subprocess.Popen(["gtkwave", args.out])
    return 0


if __name__ == "__main__":
    sys.exit(main())
