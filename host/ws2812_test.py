#!/usr/bin/env python3
"""WS2812 LED strip driver firmware (host/ws2812_prog.py) against an independent strip model written from the WS2812B datasheet:
the pad waveform is decoded pulse by pulse (high width classifies the bit, every pulse is checked against the datasheet windows,
a low of more than 50 us is the latch) and the decoded 24-bit pixels must equal what the host sent, in order and in frames.
  python host/ws2812_test.py [run mutants]
"""
import random
import sys

import proto_lib as pl
import ws2812_prog as wp

RESULTS = []
# WS2812B datasheet, ns
T0H, T1H, T0L, T1L, TOL = 400, 800, 850, 450, 150
RESET_NS = 50_000


def report(name, errs, stats, expect="pass"):
    ok = bool(errs) == (expect == "fail")
    tag = {"pass": "PASS" if ok else "FAIL", "fail": "DETECTED" if ok else "MISSED"}[expect]
    RESULTS.append((name, ok))
    print(f"  {tag:8s} {name:62s} {stats}")
    if not ok:
        for e in errs[:5] or ["no error was reported"]:
            print(f"           {e}")
    return ok


def decode(P, t_end):
    """Pad log -> (frames, errors): frames = list of lists of 24-bit pixels, separated by lows of more than 50 us."""
    tl = pl.timeline(P, wp.PIN)
    if tl and tl[0][1] == 1 and len(tl) > 1:        # the test pad idles high until the engine drives it; the strip's input is pulled low: start at the first fall
        tl = tl[1:]
    errs, frames, cur, bits = [], [], [], []
    pulses = []
    for (t, lvl), (t2, _) in zip(tl, tl[1:] + [(t_end, None)]):
        pulses.append((lvl, t2 - t))
    i = 0
    while i < len(pulses):
        lvl, w = pulses[i]
        if lvl == 1:
            th = w
            tlow = pulses[i + 1][1] if i + 1 < len(pulses) else RESET_NS * 2
            bit = 1 if th > (T0H + T1H) / 2 else 0
            lo, hi = (T1H - TOL, T1H + TOL) if bit else (T0H - TOL, T0H + TOL)
            if not lo <= th <= hi:
                errs.append(f"t={tl[0][0] + 0}: high pulse of {th} ns is outside the {'T1H' if bit else 'T0H'} window [{lo}, {hi}]")
            if tlow < RESET_NS:
                llo, lhi = ((T1L - TOL, T1L + 2 * TOL) if bit else (T0L - TOL, T0L + TOL))
                if not llo <= tlow <= lhi:
                    errs.append(f"low pulse of {tlow} ns after a '{bit}' is outside [{llo}, {lhi}]")
            bits.append(bit)
            if len(bits) == 24:
                cur.append(int("".join(map(str, bits)), 2))
                bits = []
            if tlow >= RESET_NS:
                if bits:
                    errs.append(f"latch after {len(bits)} stray bits")
                    bits = []
                frames.append(cur)
                cur = []
            i += 2
        else:
            i += 1
    if bits:
        errs.append(f"{len(bits)} bits left over at the end")
    if cur:
        frames.append(cur)
    return [f for f in frames if f], errs


def run_case(name, frames, firmware=None, expect="pass"):
    words, expect_frames = [], []
    for pix in frames:
        words += [wp.led_word(*p) for p in pix] + [wp.LATCH_WORD]
        expect_frames.append([(p[0] << 16) | (p[1] << 8) | p[2] for p in pix])
    nbits = sum(len(f) for f in frames) * 24
    dur = int(nbits * 1300 + len(frames) * 70_000 + 200_000)
    L = pl.run(name, progs={0: firmware or wp.ws2812()}, htx={0: words}, dur_ns=dur)
    got, errs = decode(L["P"], dur)
    if got != expect_frames:
        errs.append(f"decoded {[len(f) for f in got]} pixels per frame, expected {[len(f) for f in expect_frames]}"
                    + ("" if len(got) != len(expect_frames) else f"; first difference at "
                       f"{next((i for i, (a, b) in enumerate(zip(sum(got, []), sum(expect_frames, []))) if a != b), None)}"))
    return report(name, errs, f"{sum(len(f) for f in frames)} LEDs, {len(frames)} frame(s)", expect)


def px(rnd):
    return (rnd.randrange(256), rnd.randrange(256), rnd.randrange(256))


def phase_run():
    print("Phase 1: strip model against the firmware")
    rnd = random.Random(2812)
    run_case("one LED, a known colour", [[(0x12, 0x34, 0x56)]])
    run_case("all bits zero / all bits one", [[(0, 0, 0), (255, 255, 255)]])
    run_case("walking one through G, R, B", [[(1 << k, 0, 0) for k in range(8)] + [(0, 1 << k, 0) for k in range(8)] + [(0, 0, 1 << k) for k in range(8)]])
    run_case("eight random LEDs", [[px(rnd) for _ in range(8)]])
    run_case("three frames of different length", [[px(rnd) for _ in range(n)] for n in (3, 12, 1)])
    run_case("a 60 LED strip", [[px(rnd) for _ in range(60)]])
    for k in range(4):
        run_case(f"random frames {k + 1}", [[px(rnd) for _ in range(rnd.randrange(1, 20))] for _ in range(rnd.randrange(1, 4))])


def phase_mutants():
    print("Phase 2: broken firmware must be caught")
    rnd = random.Random(99)
    frames = [[px(rnd) for _ in range(6)], [px(rnd) for _ in range(4)]]
    for name, mut in (("bits sent LSB first", ("lsb_first",)), ("T0H too long (0.62 us)", ("long_t0h",)), ("T1H too short (0.52 us)", ("short_t1h",)),
                      ("no latch: the strip never sees a frame end", ("no_latch",)), ("latch of 20 us (too short)", ("short_latch",))):
        run_case(f"mutant: {name}", frames, firmware=wp.ws2812(mut), expect="fail")


def main():
    phases = sys.argv[1:] or ["run", "mutants"]
    for p in phases:
        {"run": phase_run, "mutants": phase_mutants}[p]()
    bad = [n for n, ok in RESULTS if not ok]
    print(f"RESULT ws2812_test: {'PASS' if not bad else 'FAIL'} ({len(RESULTS) - len(bad)}/{len(RESULTS)} cases as expected)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
