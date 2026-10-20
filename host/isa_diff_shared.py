#!/usr/bin/env python3
"""Differential test for the shared instruction memory: random images placed at random origins of the 512-word memory, both engines started from their
own START address with random pin / FIFO stimulus, run in the RTL (tb/tb_isa_diff_shared.v: imem_shared + two engine_top) and in host/isa_model.py
(two Engines on one SharedImem); every clock of every engine must match.     python host/isa_diff_shared.py [run] [--tests N] [--seed S]

What is new compared with isa_diff_test.py: jump targets are absolute 9-bit addresses, the first instruction is often OP_REGION (exact, too small, too
large, empty, over 512), a second OP_REGION anywhere in the code faults (the lock), engines run with overlapping windows, an engine without
OP_REGION runs with the whole memory as its window, fetches outside a window trap, and the engines run side by side from one memory.
Coverage is counted from what the model executed; a green run needs a minimum count for each shared-memory behaviour as well as for the instructions.
"""
import argparse
import collections
import os
import random
import subprocess
import sys

import asm as A
import isa_diff_test as D
import isa_model as M

ROOT = D.ROOT
BUILD = os.path.join(ROOT, "build", "isa_diff_shared")
CYC = D.CYC
JUMP_OPS = {A.OPCODE[n] for n in ("JMP", "DJNZ", "JPH", "JPL", "JPO", "JCC")}


def region_word(base, limit):
    return A.word("REGION", (limit << 9) | base)


def relocate(rnd, w, origin):
    """A jump word carries a program-relative target in operand [7:0]: make it the absolute 9-bit address origin + t (bit 11 = target bit 8)."""
    if (w >> 27) in JUMP_OPS and rnd.random() < 0.93:
        t = (w & 0xFF) + origin
        w = (w & ~(0xFF | (1 << 11))) | (t & 0xFF) | (((t >> 8) & 1) << 11)
    return w


def make_program(rnd, L, origin, mode):
    """One engine's image: L words for physical address `origin`. mode selects what its first instruction does with the window."""
    prog = [A.enc_ldi(i, 0 if rnd.random() < 0.15 else rnd.randrange(0, 300) if rnd.random() < 0.5 else rnd.getrandbits(24)) for i in range(8)]
    body = [relocate(rnd, D.rnd_word(rnd, L), origin) for _ in range(L)]
    words = prog + body[:L - len(prog)]
    if mode == "exact":
        words[0] = region_word(origin, origin + L)
    elif mode == "small":
        words[0] = region_word(origin, origin + rnd.randint(4, max(5, L // 2)))      # code beyond the window traps
    elif mode == "wide":
        words[0] = region_word(max(0, origin - rnd.randint(0, 30)), min(512, origin + L + rnd.randint(0, 30)))
    elif mode == "late":                                                              # the window is set after a few instructions
        words[rnd.randint(1, 6)] = region_word(origin, origin + L)
    elif mode == "bad":
        words[0] = rnd.choice([region_word(40, 40), region_word(50, 20), region_word(300, 200), region_word(5, 1000), region_word(0, 513)])
        # empty, inverted, or a limit above 512 (the limit field is 10 bits): the engine faults at once
    # mode "none": no OP_REGION of ours at the start; random words may still contain one (opcode 29 from the BAD generator)
    return words


def make_stim(rnd):
    stim = []
    pin = rnd.getrandbits(8)
    p_tx = rnd.choice([0.0, 0.03, 0.15, 0.5])
    p_rd = rnd.choice([0.0, 0.05, 0.35, 0.9])
    for _ in range(CYC):
        if rnd.random() < 0.3:
            pin = rnd.getrandbits(8) if rnd.random() < 0.5 else pin ^ (1 << rnd.randrange(8))
        tx = rnd.getrandbits(32) if rnd.random() < p_tx else None
        stim.append((pin, tx, rnd.random() < p_rd))
    return stim


MODES = ["exact"] * 5 + ["none"] * 3 + ["small"] * 2 + ["wide"] + ["late"] + ["bad"]
LAYOUTS = ["disjoint"] * 4 + ["adjacent"] * 2 + ["overlap"] * 2 + ["same"]


def make_test(rnd):
    """-> (image of 512 words, [start0, start1], [stim0, stim1], info)"""
    L0, L1 = rnd.randint(24, 96), rnd.randint(24, 96)
    layout = rnd.choice(LAYOUTS)
    if layout == "disjoint":
        o0 = rnd.randint(0, 511 - L0 - L1 - 40)
        o1 = rnd.randint(o0 + L0 + 20, 511 - L1)
    elif layout == "adjacent":
        o0 = rnd.randint(0, 511 - L0 - L1)
        o1 = o0 + L0
    elif layout == "overlap":
        o0 = rnd.randint(0, 511 - L0 - 10)
        o1 = min(511 - L1, o0 + rnd.randint(1, L0 - 1))
    else:
        o0 = o1 = rnd.randint(0, 511 - max(L0, L1))
    if rnd.random() < 0.5:                                    # swap, so engine 1 is also the lower one sometimes
        (o0, L0), (o1, L1) = (o1, L1), (o0, L0)
    modes = [rnd.choice(MODES), rnd.choice(MODES)]
    p0, p1 = make_program(rnd, L0, o0, modes[0]), make_program(rnd, L1, o1, modes[1])
    img = [A.word("HALT")] * 512
    img[o0:o0 + L0] = p0
    img[o1:o1 + L1] = p1                                      # in the overlap layouts the second image overwrites the first where they meet
    return img, [o0, o1], [make_stim(rnd), make_stim(rnd)], dict(layout=layout, modes=modes, spans=[(o0, o0 + L0), (o1, o1 + L1)])


def make_tests(seed, n):
    rnd = random.Random(seed)
    return [make_test(rnd) for _ in range(n)]


# ------------------------------------------------------------------ RTL
def rtl_sources(override=None):
    srcs = sorted(os.path.join(ROOT, "src", f) for f in os.listdir(os.path.join(ROOT, "src")) if f.endswith(".v"))
    srcs += [os.path.join(ROOT, "sim", "ihp_sram", f) for f in ("RM_IHPSG13_2P_512x32_c2_bm_bist.v", "RM_IHPSG13_2P_core_behavioral_bm_bist_ideal.v")]
    if override:
        srcs = [override.get(os.path.basename(s), s) for s in srcs]
    return srcs


def write_inputs(tests, tag):
    os.makedirs(BUILD, exist_ok=True)
    p = {k: os.path.join(BUILD, f"{tag}_{k}.mem") for k in ("img", "start", "stim0", "stim1")}
    with open(p["img"], "w") as f:
        for img, _, _, _ in tests:
            f.write("".join(f"{w:08x}\n" for w in img))
    with open(p["start"], "w") as f:
        for _, st, _, _ in tests:
            f.write(f"{(st[1] << 16) | st[0]:08x}\n")
    for e in (0, 1):
        with open(p[f"stim{e}"], "w") as f:
            for _, _, stim, _ in tests:
                f.write("".join(f"{D.stim_word(s):012x}\n" for s in stim[e]))
    return p


def run_rtl(tests, tag, srcs=None):
    p = write_inputs(tests, tag)
    vvp = os.path.join(BUILD, f"{tag}.vvp")
    out = os.path.join(BUILD, f"{tag}_rtl.trace")
    r = subprocess.run(["iverilog", "-Wno-timescale", "-g2012", "-DFUNCTIONAL", "-DSHARED_IMEM", "-I", os.path.join(ROOT, "src"),
                        "-o", vvp, os.path.join(ROOT, "tb", "tb_isa_diff_shared.v")] + (srcs or rtl_sources()), capture_output=True, text=True)
    if r.returncode:
        return None, "COMPILE FAIL " + r.stderr[:400]
    r = subprocess.run(["vvp", "-n", vvp, f"+IMG={p['img']}", f"+START={p['start']}", f"+STIM0={p['stim0']}", f"+STIM1={p['stim1']}",
                        f"+NT={len(tests)}", f"+CYC={CYC}", f"+OUT={out}"], capture_output=True, text=True, timeout=3600)
    if "DONE" not in r.stdout:
        return None, "NO RESULT " + r.stdout[-300:]
    return open(out).read().split("\n")[:-1], ""


# ------------------------------------------------------------------ model
def model_trace(test):
    img, starts, stim, info = test
    sm = M.SharedImem()
    sm.load(0, img)
    eng = [M.Engine([], shared=sm, start=starts[0]), M.Engine([], shared=sm, start=starts[1])]
    lines = ([], [])
    cov = collections.Counter()
    for c in range(CYC):
        for e in (0, 1):
            pin, tx, rd = stim[e][c]
            eng[e].step(pin, tx, rd)
            lines[e].append(eng[e].trace_line())
    for e in (0, 1):
        cov.update(eng[e].cov)
        cov[("sh", "engine_runs")] += 1
        pcs = [int(l.split()[0], 16) for l in lines[e]]
        if eng[e].fault:
            cov[("sh", "fault")] += 1
        if eng[e].locked:
            cov[("sh", "window_set")] += 1
        if max(pcs) >= 256:
            cov[("sh", "pc_above_255")] += 1
        win = eng[e].win
        if win != (0, 512):
            cov[("sh", "window_narrowed")] += 1
        if any(not (win[0] <= p < win[1]) for p in pcs) and eng[e].fault:
            cov[("sh", "fetch_outside_window_fault")] += 1
    cov[("sh", "layout", info["layout"])] += 1
    for m in info["modes"]:
        cov[("sh", "mode", m)] += 1
    return lines, cov


FIELDS = "pc pin_out pin_oe status rx_head osr isr lc crc znc r0 r1 r2 r3 r4 r5 r6 r7".split()


def same(a, b):
    ea, eb = a.split(), b.split()
    return len(ea) == len(eb) and int(ea[0], 16) == int(eb[0], 16) and ea[1:] == eb[1:]


def compare(tests, rtl_lines):
    cov = collections.Counter()
    bad = []
    for t, test in enumerate(tests):
        (m0, m1), c = model_trace(test)
        cov.update(c)
        base = t * CYC * 2
        for cyc in range(CYC):
            g0, g1 = rtl_lines[base + 2 * cyc], rtl_lines[base + 2 * cyc + 1]
            for e, (exp, got) in enumerate(((m0[cyc], g0), (m1[cyc], g1))):
                if not same(exp, got):
                    ex, gx = exp.split(), got.split()
                    diff = [f"{FIELDS[i]}: model {ex[i]} rtl {gx[i]}" for i in range(len(ex)) if ex[i] != gx[i] and not (i == 0 and int(ex[0], 16) == int(gx[0], 16))]
                    bad.append((t, e, cyc, diff, test[3]))
                    break
            else:
                continue
            break
    return bad, cov


REQUIRED = [("op", n, 30) for n in A.OPCODE if n not in ("HALT", "REGION")] + [("op", "HALT", 10), ("op", "REGION", 30)] + \
           [("alu", f, 20) for f in range(13)] + [("jcc", c, t, 10) for c in range(8) for t in (0, 1)] + \
           [("sh", "window_set", 150), ("sh", "window_narrowed", 100), ("sh", "fault", 150), ("sh", "pc_above_255", 150),
            ("sh", "fetch_outside_window_fault", 40)] + \
           [("sh", "layout", l, 20) for l in ("disjoint", "adjacent", "overlap", "same")] + \
           [("sh", "mode", m, 20) for m in ("exact", "none", "small", "wide", "late", "bad")]


def coverage_report(cov, n_tests):
    scale = n_tests / 400.0                      # the minimums above are for 400 tests
    missing = []
    for item in REQUIRED:
        key, need = item[:-1], max(1, int(item[-1] * min(1.0, scale)))
        if cov.get(key, 0) < need:
            missing.append((key, cov.get(key, 0), need))
    traps = sorted((k for k in cov if k[0] == "trap"), key=str)
    print(f"  coverage: {sum(v for k, v in cov.items() if k[0] == 'op')} instructions committed; trap kinds seen: {len(traps)}; "
          f"{len(REQUIRED) - len(missing)}/{len(REQUIRED)} coverage points met")
    for m in missing:
        print(f"    NOT COVERED enough: {m[0]} saw {m[1]}, need {m[2]}")
    return not missing


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("phase", nargs="*", default=["run"])
    ap.add_argument("--tests", type=int, default=400)
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()
    tests = make_tests(args.seed, args.tests)
    lines, err = run_rtl(tests, f"s{args.seed}")
    if lines is None:
        print("RESULT isa_diff_shared: FAIL", err)
        return 1
    bad, cov = compare(tests, lines)
    for t, e, cyc, diff, info in bad[:8]:
        print(f"  MISMATCH test {t} engine {e} clock {cyc}: {'; '.join(diff[:4])}   [{info['layout']}, {info['modes']}, spans {info['spans']}]")
    ok = coverage_report(cov, args.tests)
    good = not bad and ok
    print(f"RESULT isa_diff_shared: {'PASS' if good else 'FAIL'} ({len(tests)} tests x {CYC} clocks x 2 engines, {len(bad)} mismatching tests, seed {args.seed})")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main())
