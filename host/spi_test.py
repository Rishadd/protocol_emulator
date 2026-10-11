#!/usr/bin/env python3
"""SPI verification: Python reference model + independent bus decoder vs the Verilog engine.

Phases (run all, or name some):  python host/spi_test.py [selftest peers master slave chip mutants]
  selftest  decoder against an ideal Python waveform (all modes, bit orders, lengths) + injected faults
  peers     Verilog master model <-> slave model, no engine (checks the testbench peers)
  master    engine as SPI master (tb_spi_engine ROLE=0) against the slave model
  slave     engine as SPI slave  (tb_spi_engine ROLE=1) against the master model
  chip      full chip: programs, data and results only through the management SPI link (tb_spi_chip)
  mutants   deliberately broken firmware (no CS check, wrong edges, wrong mode/bit order) must be caught

The testbench logs every change of CS/SCLK/MOSI/MISO; decode() rebuilds the frames from that log
using only the SPI mode table (not the firmware), checks the bus rules, and measures timing.
Negative cases must be *detected* (marked "expect fail"). 1 system clock = 10 ns.
"""
import argparse
import glob
import os
import random
import subprocess
import sys

import spi_prog as sp

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
BUILD = os.path.join(ROOT, "build", "spi")
CLK = 10
if os.name == "nt" and os.path.isdir(r"C:\iverilog\bin"):
    os.environ["PATH"] += os.pathsep + r"C:\iverilog\bin"
SIM_LIBS = [os.path.join(ROOT, "sim", "ihp_sram", f) for f in
            ("RM_IHPSG13_1P_core_behavioral.v", "RM_IHPSG13_1P_64x16_c2.v")]


# ------------------------------------------------------------------ data
def patterns(bits, rng, nrand=16):
    m = (1 << bits) - 1
    v = [0, m, 0xAAAAAAAA & m, 0x55555555 & m]
    v += [1 << i for i in range(bits)] + [m ^ (1 << i) for i in range(bits)]
    return v + [rng.getrandbits(bits) for _ in range(nrand)]


# ------------------------------------------------------------------ reference waveform (selftest)
def ideal_wave(mode, bits, lsb, mv, sv, half=50):
    """Ideal SPI bus straight from the mode table: list of (t, 'cs sclk mosi miso')."""
    cpol, cpha = mode >> 1, mode & 1
    b = lambda v, i: (v >> i) & 1 if lsb else (v >> (bits - 1 - i)) & 1
    t, st, out = 0, dict(cs=1, sclk=cpol, mosi=0, miso=0), []
    put = lambda: out.append((t, f"{st['cs']}{st['sclk']}{st['mosi']}{st['miso']}"))
    put()
    for m, s in zip(mv, sv):
        t += half; st["cs"] = 0
        if not cpha:
            st["mosi"], st["miso"] = b(m, 0), b(s, 0)
        put()
        for i in range(bits):
            t += half; st["sclk"] = 1 - cpol
            if cpha:
                st["mosi"], st["miso"] = b(m, i), b(s, i)
            put()
            t += half; st["sclk"] = cpol
            if not cpha and i + 1 < bits:
                st["mosi"], st["miso"] = b(m, i + 1), b(s, i + 1)
            put()
        t += half; st["cs"] = 1; put()
    return out


# ------------------------------------------------------------------ decoder / bus checker
def decode(P, mode, bits, lsb, check_z=False):
    """Frames from the pad log using only the mode table. Returns (frames, violations, samples).
    frame: t0, t1, edges [(t, is_lead)], mosi, miso, n (sampled bits), miso_on (first drive after CS fall),
           miso_off (MISO back to z after CS rise). samples[line] = [t_edge, setup, hold]."""
    cpol, cpha = mode >> 1, mode & 1
    frames, viol, f, last_f = [], [], None, None
    samples = {"mosi": [], "miso": []}
    pending = {"mosi": [], "miso": []}
    last = {"mosi": P[0][0], "miso": P[0][0]}
    prev = P[0][1]
    for t, s in P[1:]:
        cs, sc, mo, mi = s
        pcs, psc = prev[0], prev[1]
        if pcs == "1" and cs == "0":
            if sc != str(cpol):
                viol.append(f"{t}: SCLK not idle at CS fall")
            if check_z and prev[3] != "z":
                viol.append(f"{t}: MISO driven while CS inactive")
            f = dict(t0=t, t1=None, edges=[], mosi=0, miso=0, n=0, miso_on=None, miso_off=None)
        elif pcs == "0" and cs == "1" and f:
            if psc != str(cpol):
                viol.append(f"{t}: SCLK not idle at CS rise")
            f["t1"] = t
            frames.append(f); last_f, f = f, None
        if sc != psc and sc in "01" and psc in "01":
            if f is None:
                viol.append(f"{t}: SCLK edge while CS inactive")
            else:
                lead = sc != str(cpol)
                f["edges"].append((t, lead))
                if lead == (cpha == 0):                       # sampling edge: value before t
                    for line, v in (("mosi", prev[2]), ("miso", prev[3])):
                        if v not in "01":
                            viol.append(f"{t}: {line.upper()} '{v}' at sampling edge")
                        bit = 1 if v == "1" else 0
                        f[line] = f[line] | bit << f["n"] if lsb else f[line] << 1 | bit
                        rec = [t, t - last[line], None]
                        samples[line].append(rec); pending[line].append(rec)
                    f["n"] += 1
        for line, i in (("mosi", 2), ("miso", 3)):
            if s[i] != prev[i]:
                for rec in pending[line]:
                    rec[2] = t - rec[0]
                pending[line] = []
                last[line] = t
        if f is not None and f["miso_on"] is None and prev[3] == "z" and mi != "z":
            f["miso_on"] = t - f["t0"]
        if f is None and last_f and last_f["miso_off"] is None and mi == "z" and prev[3] != "z":
            last_f["miso_off"] = t - last_f["t1"]
        prev = s
    for line in samples:
        for t, setup, hold in samples[line]:
            if setup == 0 or hold == 0:
                viol.append(f"{t}: {line.upper()} changes at its sampling edge")
    return frames, viol, samples


def phases(fr, cpol):
    """(cs->first edge, lead phases, idle phases, last edge->cs rise) in ns."""
    e = [t for t, _ in fr["edges"]]
    lead = [e[i + 1] - e[i] for i in range(0, len(e) - 1, 2)]
    idle = [e[i + 1] - e[i] for i in range(1, len(e) - 1, 2)]
    return e[0] - fr["t0"], lead, idle, fr["t1"] - e[-1]


def latency_after(edges, times, end):
    """For each edge, delay to the first time in `times` before the next edge (or `end`), if any."""
    out, j = [], 0
    for k, te in enumerate(edges):
        nxt = edges[k + 1] if k + 1 < len(edges) else end
        while j < len(times) and times[j] <= te:
            j += 1
        if j < len(times) and times[j] < nxt:
            out.append(times[j] - te)
    return out


def rng_str(xs, unit=CLK):
    if not xs:
        return "-"
    lo, hi = min(xs) / unit, max(xs) / unit
    return f"{lo:g}" if lo == hi else f"{lo:g}..{hi:g}"


# ------------------------------------------------------------------ simulation
_vvp = {}


def compile_tb(name):
    if name not in _vvp:
        os.makedirs(BUILD, exist_ok=True)
        out = os.path.join(BUILD, name + ".vvp")
        srcs = sorted(glob.glob(os.path.join(ROOT, "src", "*.v")))
        subprocess.run(["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-DFUNCTIONAL",
                        "-I", os.path.join(ROOT, "src"), "-I", os.path.join(ROOT, "tb"), "-o", out,
                        os.path.join(ROOT, "tb", name + ".v"), *srcs, *SIM_LIBS], check=True)
        _vvp[name] = out
    return _vvp[name]


def parse_log(path):
    L = dict(P=[], S=[], W=[], R=[], END={})
    for line in open(path):
        p = line.split()
        if not p:
            continue
        if p[0] == "P":
            t = int(p[1])
            if L["P"] and L["P"][-1][0] == t:
                L["P"][-1] = (t, p[2])
            elif not L["P"] or L["P"][-1][1] != p[2]:
                L["P"].append((t, p[2]))
        elif p[0] == "S":
            L["S"].append(int(p[1]))
        elif p[0] in "WR":
            L[p[0]].append(int(p[2], 16) if "x" not in p[2] else None)
        elif p[0] == "END":
            L["END"] = {k: v for k, v in (x.split("=") for x in p[1:])}
    # drop repeats created by collapsing same-timestamp lines
    P = [L["P"][0]] if L["P"] else []
    for e in L["P"][1:]:
        if e[1] != P[-1][1]:
            P.append(e)
    L["P"] = P
    return L


def sim(tb, name, files, plus):
    d = os.path.join(BUILD, "".join(c if c.isalnum() or c in "-+=." else "_" for c in name))
    os.makedirs(d, exist_ok=True)
    args = []
    for k, words in files.items():
        fn = os.path.join(d, k.lower() + ".hex")
        sp.write_hex(words, fn)
        args.append(f"+{k}={fn}")
    log = os.path.join(d, "log.txt")
    args += [f"+{k}={v}" for k, v in plus.items()] + [f"+OUT={log}"]
    r = subprocess.run(["vvp", "-n", compile_tb(tb), *args], capture_output=True, text=True)
    if r.returncode or "ERROR" in r.stdout:
        raise RuntimeError(f"{name}: simulation failed\n{r.stdout}{r.stderr}")
    return parse_log(log)


# ------------------------------------------------------------------ checks
def compare(errs, what, got, exp):
    if got != exp:
        bad = next((i for i, (g, e) in enumerate(zip(got, exp)) if g != e), min(len(got), len(exp)))
        errs.append(f"{what}: {len(got)} vs {len(exp)} expected, first difference at #{bad}")


def check(L, role, mode, bits, lsb, hv, mv, sv, h=None, abort=-1):
    """role 0 engine master, 1 engine slave, 2 peers only. Returns (errors, stats string)."""
    frames, viol, samples = decode(L["P"], mode, bits, lsb, check_z=(role == 1))
    errs = viol[:5] + ([f"... {len(viol)} bus violations"] if len(viol) > 5 else [])
    cpol, cpha = mode >> 1, mode & 1
    n = len(mv if role else hv)
    if len(frames) != n:
        errs.append(f"{len(frames)} CS frames, expected {n}")
    full = [i for i in range(len(frames)) if i != abort]
    for i in full:
        if frames[i]["n"] != bits or len(frames[i]["edges"]) != 2 * bits:
            errs.append(f"frame {i}: {len(frames[i]['edges'])} SCLK edges, expected {2 * bits}")
            break
    keep = [i for i in range(n) if i != abort]
    rx = [sp.rx_value(w, bits, lsb) if w is not None else None for w in L["R"]]
    if role == 0:
        compare(errs, "MOSI vs host data", [f["mosi"] for f in frames], hv)
        compare(errs, "MISO vs slave data", [f["miso"] for f in frames], sv)
        compare(errs, "host RX vs slave data", rx, sv)
    else:
        compare(errs, "MOSI vs master data", [frames[i]["mosi"] for i in keep if i < len(frames)], [mv[i] for i in keep])
        exp_miso = [sv[i] for i in keep] if role == 2 else [hv[i] for i in keep]
        compare(errs, "MISO vs " + ("slave" if role == 2 else "host") + " data",
                [frames[i]["miso"] for i in keep if i < len(frames)], exp_miso)
        if role == 1:
            compare(errs, "host RX vs master data", rx, [mv[i] for i in keep])
    if L["END"].get("fault", "0") != "0":
        errs.append("engine fault")

    st = []
    ok = [frames[i] for i in full if i < len(frames) and len(frames[i]["edges"]) == 2 * bits]
    if ok:
        ph = [phases(f, cpol) for f in ok]
        cs_su = [p[0] for p in ph]; lead = sum((p[1] for p in ph), []); idle = sum((p[2] for p in ph), [])
        cs_h = [p[3] for p in ph]
        st.append(f"cs_setup={rng_str(cs_su)} lead={rng_str(lead)} idle={rng_str(idle)} cs_hold={rng_str(cs_h)}")
        if role == 0 and h is not None:
            for nm, xs, exp in (("CS setup", cs_su, h + 2), ("lead phase", lead, h + 2), ("idle phase", idle, h + 3)):
                if xs and (min(xs) != exp * CLK or max(xs) != exp * CLK):
                    errs.append(f"{nm} {rng_str(xs)} clk, expected exactly {exp}")
    drv = "mosi" if role != 1 else "miso"           # the line the engine drives (role 2: master model's)
    s = [r for r in samples[drv] if r[2] is not None]
    if s:
        st.append(f"{drv.upper()} setup>={min(r[1] for r in s) / CLK:g} hold>={min(r[2] for r in s) / CLK:g}")
    if role in (0, 1):
        i_drv = 2 if role == 0 else 3
        # engine output change after its shift edge, and engine sampling point after its sampling edge
        chg = [L["P"][k][0] for k in range(1, len(L["P"])) if L["P"][k][1][i_drv] != L["P"][k - 1][1][i_drv]]
        lat = sum((latency_after([t for t, lead in f["edges"] if lead == (cpha == 1)], chg, f["t1"]) for f in ok), [])
        st.append(f"{drv.upper()}_after_shift_edge={rng_str(lat)}")
        se = sorted(t for f in frames for t, lead in f["edges"] if lead == (cpha == 0))
        d = []
        for ts in L["S"]:
            prior = [te for te in se if te <= ts]
            if prior:
                d.append(ts - 2 * CLK - prior[-1])
        st.append(f"sample_point_after_edge={rng_str(d)}")
        # slave response limit (measured 1..3 clk sample, 3..5 clk MISO update; +margin for pad delay).
        # Late but still-correct behaviour only shows up here when the peer is slow.
        if role == 1 and (d and (min(d) < 0 or max(d) > 4 * CLK) or lat and max(lat) > 6 * CLK):
            errs.append(f"slave response outside 0..4 clk sample / <=6 clk MISO: {rng_str(d)} / {rng_str(lat)}")
    if role == 1 and ok:
        st.append(f"MISO_release={rng_str([f['miso_off'] for f in ok if f['miso_off'] is not None])}")
        if cpha == 0:
            st.append(f"first_bit_after_CS={rng_str([f['miso_on'] for f in ok if f['miso_on'] is not None])}")
    return errs, " ".join(st)


# ------------------------------------------------------------------ case runners
RESULTS = []
LAST_END = {}                  # END line of the last chip case (workload.py reads it)


LIMITS = []


def report(name, errs, stats, expect="pass"):
    """expect: 'pass', 'fail' (negative case, must be detected) or 'info' (sweep point, not counted)."""
    ok = bool(errs) == (expect == "fail")
    tag = {"pass": "PASS" if ok else "FAIL", "fail": "DETECTED" if ok else "MISSED",
           "info": "ok" if not errs else "fails"}[expect]
    if expect != "info":
        RESULTS.append((name, ok))
    print(f"  {tag:8s} {name:46s} {stats}")
    if not ok and expect != "info" or errs and expect == "info":
        for e in errs[:3 if expect == "info" else 6] or ["no error was reported"]:
            print(f"           {e}")
    return not errs


def sweep(label, values, run):
    """Run values in order until the first failure; record the last passing value."""
    last = fail = None
    for v in values:
        if not run(v):
            fail = v
            break
        last = v
    LIMITS.append((label, last, fail))
    print(f"  LIMIT    {label}: last pass {last}, first fail {fail}")


def engine_case(name, role, mode, bits=8, lsb=0, n=None, h=4, seed=1, expect="pass",
                peer_mode=None, abort=-1, vals=None, tb="tb_spi_engine", **plus):
    rng = random.Random(seed)
    mk = lambda: vals[:] if vals else patterns(bits, rng)
    hv, mv, sv = mk(), mk(), mk()
    rng.shuffle(mv); rng.shuffle(sv)
    if n:
        hv, mv, sv = hv[:n], mv[:n], sv[:n]
    files, cnt = {}, len(hv)
    if role == 0:
        files["PROG"] = sp.master(mode, bits, lsb, h)
    elif role == 1:
        files["PROG"] = sp.slave(mode, bits, lsb)
    if role != 2:
        files["HTX"] = [sp.tx_word(v, bits, lsb) for v in hv]
    files["MTX"], files["STX"] = mv, sv
    pm = mode if peer_mode is None else peer_mode
    args = dict(ROLE=role, N=cnt, MODE=pm, BITS=bits, LSB=lsb, SEED=seed, TMAX=20_000_000)
    if abort >= 0:
        args["ABORT"] = abort
    args.update({k.upper(): v for k, v in plus.items()})
    L = sim(tb, name, files, args)
    errs, st = check(L, role, mode, bits, lsb, hv, mv, sv, h=h if role == 0 else None, abort=abort)
    if tb == "tb_spi_chip":
        e = L["END"]
        if (e.get("err") != "0" and e.get("aborts", "0") == "0") or e.get("oe_other") != "0":   # aborts set err
            errs.append(f"management err={e.get('err')}, idle engine drove pins {e.get('oe_other')} cycles")
        us = int(e["cyc"]) * CLK / 1000
        st = f"{e['frames']} mgmt frames ({e['retries']} TX retries, {e['polls']} empty reads), {us:.0f} us | " + st
        LAST_END.clear(); LAST_END.update(e)
    return report(name, errs, st, expect)


def phase_selftest():
    print("Phase 1: decoder vs ideal Python waveform")
    rng = random.Random(7)
    for mode in range(4):
        for lsb in (0, 1):
            for bits in (1, 7, 8, 16, 32):
                mv, sv = patterns(bits, rng), patterns(bits, rng)
                rng.shuffle(sv)
                fr, viol, _ = decode(ideal_wave(mode, bits, lsb, mv, sv), mode, bits, lsb)
                errs = list(viol)
                compare(errs, "MOSI", [f["mosi"] for f in fr], mv)
                compare(errs, "MISO", [f["miso"] for f in fr], sv)
                report(f"ideal mode{mode} {'lsb' if lsb else 'msb'} {bits}b", errs, f"{len(fr)} frames")
    mv = patterns(8, rng)
    for mode in range(4):
        for other in range(4):
            if other != mode:     # decoding with the wrong mode must not reproduce the data
                fr, viol, _ = decode(ideal_wave(mode, 8, 0, mv, mv), other, 8, 0)
                errs = list(viol)
                compare(errs, "MOSI", [f["mosi"] for f in fr], mv)
                report(f"wave mode{mode} decoded as mode{other}", errs, "", expect="fail")
    w = ideal_wave(0, 8, 0, mv[:3], mv[:3])
    bad = w[:1] + [(5, "1100"), (6, "1000")] + w[1:]          # SCLK pulse while CS high
    report("SCLK pulse while CS inactive", decode(bad, 0, 8, 0)[1], "", expect="fail")
    report("wrong SCLK idle level", decode(w, 2, 8, 0)[1], "", expect="fail")
    bad = [(t, s[:3] + ("z" if 300 < t < 700 else s[3])) for t, s in w]
    report("MISO undriven in a frame", decode(bad, 0, 8, 0, check_z=True)[1], "", expect="fail")


def phase_peers():
    print("Phase 2: Verilog master model <-> slave model (no engine)")
    for mode in range(4):
        for lsb in (0, 1):
            for bits in (1, 7, 8, 16, 32):
                engine_case(f"peers mode{mode} {'lsb' if lsb else 'msb'} {bits}b", 2, mode, bits, lsb)
    for mode in range(4):
        engine_case(f"peers mode{mode} jitter+-30ns tco=40ns", 2, mode, half_ns=100, jit_ns=30, tco_ns=40)
        engine_case(f"peers run in mode{mode ^ 1}, decoded as mode{mode}", 2, mode, peer_mode=mode ^ 1,
                    expect="fail")


def phase_master():
    print("Phase 3: engine = SPI master, peer = slave model")
    for mode in range(4):
        for lsb in (0, 1):
            for bits in (1, 7, 8, 16, 32):
                engine_case(f"master mode{mode} {'lsb' if lsb else 'msb'} {bits}b H=4", 0, mode, bits, lsb)
    print(" H sweep (SCLK = f_clk/(2H+5)), slave model tco=0")
    for mode in range(4):
        for h in (0, 1, 2):
            engine_case(f"master mode{mode} H={h} (SCLK = clk/{2 * h + 5})", 0, mode, h=h)
    print(" slave clock-to-out sweep (largest tco the engine still samples correctly)")
    for mode in range(4):
        for h in (0, 4):
            sweep(f"master mode{mode} H={h}: slave tco ns", range(0, 300, 10),
                  lambda t: engine_case(f"master mode{mode} H={h} tco={t}ns", 0, mode, h=h, tco_ns=t, n=24,
                                        expect="info"))
    print(" flow control and stress")
    for mode in range(4):
        engine_case(f"master mode{mode} host feeds late, RX drained late", 0, mode,
                    txlate_ns=3000, rxoff_ns=20000)
        engine_case(f"master mode{mode} 1024 random bytes H=1", 0, mode, h=1, seed=mode + 10,
                    vals=[random.Random(mode).getrandbits(8) for _ in range(1024)])
        engine_case(f"master mode{mode} vs slave model mode{mode ^ 1}", 0, mode, peer_mode=mode ^ 1,
                    expect="fail")
        engine_case(f"master mode{mode} vs slave model mode{mode ^ 2}", 0, mode, peer_mode=mode ^ 2,
                    expect="fail")


def phase_slave():
    print("Phase 4: engine = SPI slave, peer = master model")
    for mode in range(4):
        for lsb in (0, 1):
            for bits in (1, 7, 8, 16, 32):
                engine_case(f"slave mode{mode} {'lsb' if lsb else 'msb'} {bits}b half=10clk", 1, mode, bits, lsb)
    print(" sweeps (half period, CS setup, CS inactive gap), ns, decreasing")
    for mode in range(4):
        sweep(f"slave mode{mode}: SCLK half period ns", range(100, 0, -10),
              lambda v: engine_case(f"slave mode{mode} half={v}ns", 1, mode, half_ns=v, n=24, expect="info"))
        sweep(f"slave mode{mode}: CS setup ns", range(100, 0, -10),
              lambda v: engine_case(f"slave mode{mode} CS setup={v}ns", 1, mode, css_ns=v, n=24, expect="info"))
        sweep(f"slave mode{mode}: CS inactive gap ns", range(200, 0, -10),
              lambda v: engine_case(f"slave mode{mode} CS gap={v}ns", 1, mode, gap_ns=v, csh_ns=10, n=24,
                                    expect="info"))
    print(" CS abort (JPH/JPL), jitter, stress, negative")
    for mode in range(4):
        engine_case(f"slave mode{mode} CS pulse with no clocks", 1, mode, abort=5, abits=0)
        engine_case(f"slave mode{mode} CS abort after 3 of 8 bits", 1, mode, abort=5, abits=3)
        engine_case(f"slave mode{mode} jitter +-20ns half=10clk", 1, mode, jit_ns=20)
        engine_case(f"slave mode{mode} 1024 random bytes half=6clk", 1, mode, half_ns=60, seed=mode + 20,
                    vals=[random.Random(mode + 4).getrandbits(8) for _ in range(1024)])
        engine_case(f"slave mode{mode} master model in mode{mode ^ 1}", 1, mode, peer_mode=mode ^ 1,
                    expect="fail")
        engine_case(f"slave mode{mode} host does not preload TX", 1, mode, txlate_ns=4000, expect="fail")
        engine_case(f"slave mode{mode} host stops draining RX", 1, mode, rxoff_ns=10**9, expect="fail")


def phase_chip():
    print("Phase 5: full chip, host only through the management SPI link (master on engine 0, slave on engine 1)")
    chip = dict(tb="tb_spi_chip")
    for mode in range(4):
        for bits, lsb in ((8, 0), (8, 1), (16, 0), (32, 1)):
            engine_case(f"chip master eng0 mode{mode} {'lsb' if lsb else 'msb'} {bits}b H=4", 0, mode, bits, lsb,
                        eng=0, **chip)
    for mode in range(4):
        for bits, lsb in ((8, 0), (8, 1), (16, 0), (32, 1)):
            engine_case(f"chip slave eng1 mode{mode} {'lsb' if lsb else 'msb'} {bits}b gap=40us", 1, mode, bits, lsb,
                        eng=1, gap_ns=40000, **chip)
    print(" other engine, stress, negative")
    for mode in range(4):
        engine_case(f"chip master eng1 mode{mode}", 0, mode, eng=1, **chip)
        engine_case(f"chip slave eng0 mode{mode}", 1, mode, eng=0, gap_ns=40000, **chip)
        r = random.Random(mode + 30)
        engine_case(f"chip master eng0 mode{mode} 256 random bytes H=1", 0, mode, h=1, eng=0,
                    vals=[r.getrandbits(8) for _ in range(256)], **chip)
        engine_case(f"chip slave eng1 mode{mode} 256 random bytes half=6clk", 1, mode, eng=1, half_ns=60,
                    gap_ns=40000, vals=[r.getrandbits(8) for _ in range(256)], **chip)
        engine_case(f"chip slave eng1 mode{mode} master model in mode{mode ^ 3}", 1, mode, eng=1,
                    peer_mode=mode ^ 3, gap_ns=40000, expect="fail", **chip)
    print(" sustained slave rate through the host link: CS frame gap sweep (us)")
    for mode in (0, 3):
        sweep(f"chip slave mode{mode}: min CS gap us (host keeps up)", (40, 30, 25, 20, 15, 10, 5),
              lambda g: engine_case(f"chip slave mode{mode} gap={g}us", 1, mode, eng=1, gap_ns=g * 1000, n=40,
                                    expect="info", **chip))


def phase_mutants():
    """Broken firmware must be caught by the same checks (proves the checks can fail)."""
    print("Mutants: deliberately broken firmware")
    jp, ms, sl = sp._jp, sp.master, sp.slave
    try:
        sp._jp = lambda lv, pin, a: ("NOP", 0) if pin == sp.CS else jp(lv, pin, a)       # no CS abort check
        for mode in range(4):
            engine_case(f"mut no CS check mode{mode}: CS abort after 3 bits", 1, mode, abort=5, abits=3, expect="fail")
            engine_case(f"mut no CS check mode{mode}: CS pulse, no clocks", 1, mode, abort=5, abits=0, expect="fail")
        sp._jp = lambda lv, pin, a: jp(1 - lv if pin == sp.SCLK else lv, pin, a)           # SCLK waits inverted
        for mode in range(4):
            engine_case(f"mut slave SCLK waits inverted mode{mode}", 1, mode, expect="fail")
        sp._jp = jp
        sp.master = lambda mode, *a, **k: ms(mode ^ 1, *a, **k)                            # master CPHA wrong
        sp.slave = lambda mode, *a, **k: sl(mode ^ 2, *a, **k)                             # slave CPOL wrong
        for mode in range(4):
            engine_case(f"mut master runs mode{mode ^ 1} for mode{mode}", 0, mode, expect="fail")
            engine_case(f"mut slave runs mode{mode ^ 2} for mode{mode}", 1, mode, expect="fail")
        sp.master = lambda mode, bits=8, lsb=0, h=4: ms(mode, bits, 1 - lsb, h)              # bit order wrong
        engine_case("mut master bit order flipped", 0, 0, expect="fail")
    finally:
        sp._jp, sp.master, sp.slave = jp, ms, sl


PHASES = dict(selftest=phase_selftest, peers=phase_peers, master=phase_master, slave=phase_slave,
              chip=phase_chip, mutants=phase_mutants)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("phases", nargs="*", default=list(PHASES))
    a = ap.parse_args()
    for p in a.phases:
        PHASES[p]()
    for label, last, fail in LIMITS:
        print(f"LIMIT {label}: last pass {last}, first fail {fail}")
    bad = [n for n, ok in RESULTS if not ok]
    print(f"RESULT spi_test: {'PASS' if not bad else 'FAIL'} ({len(RESULTS) - len(bad)}/{len(RESULTS)} cases as expected)")
    sys.exit(1 if bad else 0)
