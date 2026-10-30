#!/usr/bin/env python3
"""Capture unit RTL against the model: tb/tb_la_unit.v (src/la_unit.v) and host/la_model.py get the same random configurations, strobes and channel activity;
every clock (state, write pointer, full / wrapped flags, the word written) and, at the end of each test, the trigger position and the whole buffer must match.
    python host/la_rtl_test.py [run] [mutants] [--tests N] [--clocks C] [--seed S] [--aw 4]"""
import argparse
import os
import random
import subprocess
import sys

import la_model as LM

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build", "la")
TRIG = {"manual": 0, "pattern": 1, "rise": 2, "fall": 3, "sw": 4}


def make_test(rnd, n):
    mode = rnd.random() < 0.3
    cfg = dict(mode="sample" if mode else "change", div=rnd.choice([1, 2, 3, 7, 16]), sel=rnd.choice([0, 1]),
               trig=rnd.choice(list(TRIG)), mask=rnd.choice([0x1, 0x3, 0xF0, 0xFFFF, 0x8001]), value=rnd.getrandbits(16), chan=rnd.randrange(16),
               post_words=rnd.choice([0, 1, 5, 40, 1000]), post_clk=rnd.choice([0, 0, 0, 30, 3000]))
    stim = LM.activity(rnd, n, start=rnd.getrandbits(16))
    long_cap = n >= 70000
    if long_cap:                                                # long captures: two changes ~100000 clocks apart (the 65535-clock overflow word), manual trigger near the end
        v1, v2 = rnd.getrandbits(16), rnd.getrandbits(16)
        a, b = rnd.randrange(50, 2000), rnd.randrange(105000, n - 200)
        stim = [v1 if c < b else v2 for c in range(n)]
        stim[a:b] = [rnd.getrandbits(16)] * (b - a) if rnd.random() < 0.5 else stim[a:b]
        cfg.update(mode="change", trig="manual", post_words=rnd.choice([1, 2, 3]), post_clk=0)
    arms = {rnd.randrange(0, 40) if long_cap else rnd.randrange(0, max(1, n // 3))}
    if not long_cap and rnd.random() < 0.25:
        arms.add(rnd.randrange(n // 3, n))                       # a second arm in the middle of a capture
    man = n - 100 if long_cap else (rnd.randrange(0, n) if rnd.random() < 0.9 else None)
    if not long_cap and rnd.random() < 0.15:
        stim = [stim[0]] * n if rnd.random() < 0.5 else stim      # a long quiet capture for the overflow word
    return cfg, stim, arms, man


def write_inputs(tests, n, tag):
    os.makedirs(BUILD, exist_ok=True)
    cf, sf = os.path.join(BUILD, tag + "_cfg.mem"), os.path.join(BUILD, tag + "_stim.mem")
    with open(cf, "w") as f:
        for cfg, _, _, _ in tests:
            a = (cfg["mode"] == "sample") | (cfg["sel"] << 1) | (TRIG[cfg["trig"]] << 2) | (cfg["chan"] << 5)
            f.write(f"{a:08x}\n{(cfg['value'] << 16) | cfg['mask']:08x}\n{(cfg['post_clk'] << 16) | cfg['post_words']:08x}\n{cfg['div']:08x}\n")
    with open(sf, "w") as f:
        for _, stim, arms, man in tests:
            for c in range(n):
                f.write(f"{stim[c] | (int(c in arms) << 16) | (int(c == man) << 17):08x}\n")
    return cf, sf


def run_rtl(tests, n, aw, tag, src=None):
    cf, sf = write_inputs(tests, n, tag)
    vvp = os.path.join(BUILD, f"{tag}.vvp")
    out = os.path.join(BUILD, f"{tag}.log")
    r = subprocess.run(["iverilog", "-g2012", "-Wno-timescale", f"-Ptb_la_unit.AW={aw}", "-o", vvp, os.path.join(ROOT, "tb", "tb_la_unit.v"),
                        src or os.path.join(ROOT, "src", "la_unit.v")], capture_output=True, text=True)
    if r.returncode:
        return None, "COMPILE FAIL " + r.stderr[:400]
    r = subprocess.run(["vvp", "-n", vvp, f"+CFG={cf}", f"+STIM={sf}", f"+NT={len(tests)}", f"+N={n}", f"+OUT={out}"], capture_output=True, text=True, timeout=3600)
    if "DONE" not in r.stdout:
        return None, "NO RESULT " + r.stdout[-300:]
    return open(out).read().split("\n")[:-1], ""


def compare(tests, n, aw, lines):
    depth = 1 << aw
    per = n + 1 + depth
    bad = []
    for t, (cfg, stim, arms, man) in enumerate(tests):
        la = LM.LogicAnalyser(depth=depth)
        la.configure(**cfg)
        chunk = lines[t * per:(t + 1) * per]
        for c in range(n):
            la.clock(stim[c], arm=(c in arms), manual=(c == man))
            exp = f"C {la.state} {la.wp} {int(la.full)}{int(la.wrapped)} {int(la.wrote is not None)} {(la.wrote or 0):08x}"
            if exp != chunk[c]:
                bad.append((t, c, exp, chunk[c]))
                break
        else:
            tw = la.trig_wp if la.trig_wp is not None else 0
            tc = la.trig_cnt if la.trig_cnt is not None else 0
            if chunk[n] != f"T {tw} {tc}":
                bad.append((t, "end", f"T {tw} {tc}", chunk[n]))
                continue
            for i in range(depth):
                if chunk[n + 1 + i] != f"M {i} {la.buf[i]:08x}":
                    bad.append((t, f"buf[{i}]", f"{la.buf[i]:08x}", chunk[n + 1 + i]))
                    break
    return bad


MUTANTS = [
    ("the delta of a change word is one too small", "wd = {ch, cnt_n}; end", "wd = {ch, cnt}; end"),
    ("no overflow word after 65535 quiet clocks", "else if (cnt_n == 16'hFFFF) begin we = 1'b1; wd = {prev, 16'hFFFF}; end", "else if (1'b0) begin we = 1'b1; wd = {prev, 16'hFFFF}; end"),
    ("the pattern trigger ignores the mask", "((ch & trig_mask) == (trig_value & trig_mask))", "(ch == trig_value)"),
    ("rising and falling edges swapped", "3'd2:    cond = !last_ch[trig_chan] && ch[trig_chan];", "3'd2:    cond = last_ch[trig_chan] && !ch[trig_chan];"),
    ("the software trigger fires on any level", "3'd4:    cond = !last_ch[15] && ch[15];", "3'd4:    cond = ch[15];"),
    ("a write in the trigger clock is not a post-trigger word", "(trig_now ? 16'd0 : post_w) + {15'd0, we};", "(trig_now ? 16'd0 : post_w) + {15'd0, we & !trig_now};"),
    ("the post-clock limit is one clock late", "(post_clk   != 16'd0 && pc_n >= post_clk);", "(post_clk   != 16'd0 && pc_n > post_clk);"),
    ("the trigger clock count ignores the current clock", "trig_cnt <= have_first ? cnt_n : cnt;", "trig_cnt <= cnt;"),
    ("sample mode takes the wrong byte", "wire [7:0]  sbyte = sel_hi ? ch[15:8] : ch[7:0];", "wire [7:0]  sbyte = sel_hi ? ch[7:0] : ch[15:8];"),
    ("the wrapped flag is set one word early", "if (full)       wrapped <= 1'b1;", "if (wp == LAST) wrapped <= 1'b1;"),
    ("a re-arm does not clear the write pointer", "state <= ARMED; wp <= {AW{1'b0}};", "state <= ARMED;"),
    ("the sample phase never wraps", "phase <= (div <= 16'd1 || phase + 16'd1 >= div) ? 16'd0 : phase + 16'd1;", "phase <= (div <= 16'd1) ? 16'd0 : phase + 16'd1;"),
]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("phase", nargs="*", default=["run"])
    ap.add_argument("--tests", type=int, default=200)
    ap.add_argument("--clocks", type=int, default=3000)
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--aw", type=int, default=4)
    a = ap.parse_args()
    rnd = random.Random(a.seed)
    if "mutants" in a.phase:
        tests = [make_test(rnd, a.clocks) for _ in range(min(a.tests, 120))]
        long_tests = [make_test(rnd, 140000) for _ in range(4)]
        text = open(os.path.join(ROOT, "src", "la_unit.v")).read()
        caught = 0
        for i, (desc, old, new) in enumerate(MUTANTS):
            if text.count(old) != 1:
                print(f"  MUTANT {i:2d} INVALID ({text.count(old)} matches): {desc}")
                continue
            path = os.path.join(BUILD, f"m{i}_la_unit.v")
            os.makedirs(BUILD, exist_ok=True)
            open(path, "w").write(text.replace(old, new))
            lines, err = run_rtl(tests, a.clocks, a.aw, f"mut{i}", path)
            hit = lines is None or bool(compare(tests, a.clocks, a.aw, lines))
            if not hit:                                         # some bugs only show in captures longer than 65535 clocks (the overflow word)
                lines, err = run_rtl(long_tests, 140000, a.aw, f"mutlong{i}", path)
                hit = lines is None or bool(compare(long_tests, 140000, a.aw, lines))
            caught += hit
            print(f"  MUTANT {i:2d} {'caught ' if hit else 'MISSED '} {desc}")
        print(f"  la_unit mutants caught: {caught}/{len(MUTANTS)}")
        return 0 if caught == len(MUTANTS) else 1
    tests = [make_test(rnd, a.clocks) for _ in range(a.tests)]
    lines, err = run_rtl(tests, a.clocks, a.aw, f"aw{a.aw}")
    if lines is None:
        print("RESULT la_rtl_test: FAIL", err)
        return 1
    bad = compare(tests, a.clocks, a.aw, lines)
    for t, where, exp, got in bad[:6]:
        print(f"  MISMATCH test {t} at {where}: model {exp} rtl {got}")
    print(f"RESULT la_rtl_test: {'PASS' if not bad else 'FAIL'} ({len(tests)} tests x {a.clocks} clocks, depth {1 << a.aw}, {len(bad)} mismatching tests, seed {a.seed})")
    return 0 if not bad else 1


if __name__ == "__main__":
    sys.exit(main())
