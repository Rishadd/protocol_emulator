#!/usr/bin/env python3
"""I2C master verification: Python model + independent bus decoder vs the Verilog engine.

Phases (run all, or name some):  python host/i2c_test.py [selftest peers master chip mutants]
  selftest  decoder against ideal Python waveforms (3 speeds) + injected faults
  peers     Verilog master model <-> slave models (no engine)
  master    engine as I2C master (tb_i2c_engine, engine_top + pin_mgr) against slave models
  chip      full chip; claims, program, words and results only through the management SPI link
  mutants   deliberately broken firmware / pad setup must be caught

The bus log (every SDA/SCL change) is decoded with the I2C rules only: START/Sr/STOP, 9-bit bytes,
timing minimums of UM10204 for the chosen speed. Expected bus + RX words come from expect(), an
independent model of the word semantics (i2c_prog docstring) and of the slave models. 1 clock = 20 ns.
"""
import argparse
import glob
import os
import random
import subprocess
import sys

import i2c_prog as ip
import spi_prog as sp

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
BUILD = os.path.join(ROOT, "build", "i2c")
if os.name == "nt" and os.path.isdir(r"C:\iverilog\bin"):
    os.environ["PATH"] += os.pathsep + r"C:\iverilog\bin"
SIM_LIBS = [os.path.join(ROOT, "sim", "ihp_sram", f) for f in
            ("RM_IHPSG13_1P_core_behavioral_bm_bist.v", "RM_IHPSG13_1P_256x32_c2_bm_bist.v")]
EV_NACK = ip.EV_NACK


# ------------------------------------------------------------------ model
class Slave:
    def __init__(self, addr, en=True, nack_at=-1):
        self.addr, self.en, self.nack_at, self.ptr = addr, en, nack_at, 0
        self.mem = [i ^ 0xA5 for i in range(256)]


def expect(words, slaves):
    """(bus, rx): bus = [(start 'S'|'Sr', [(byte, ack)], stop)], rx = RX FIFO words."""
    bus, rx = [], []
    cur, opened, skip, first = None, False, False, False
    act, rw, nbyte, m_ack = None, 0, 0, True
    for w in words:
        S, slot, C, P = w >> 31 & 1, w >> 22 & 0x1FF, w >> 21 & 1, w >> 20 & 1
        if not S and (skip or not opened):
            continue                                        # dropped by the firmware
        skip = False
        if S:
            cur = ["Sr" if opened else "S", [], False]
            bus.append(cur)
            opened, first = True, True
        out, ack_out = slot >> 1, slot & 1
        if first:                                           # address byte
            first, byte = False, out
            act = next((s for s in slaves if s.en and s.addr == byte >> 1), None)
            rw, nbyte, m_ack = byte & 1, 0, True
            ack = ack_out & (0 if act else 1)
        elif act and rw == 0:                               # write data
            byte = out
            if nbyte == act.nack_at:
                ack = ack_out
            else:
                if nbyte == 0:
                    act.ptr = byte
                else:
                    act.mem[act.ptr] = byte
                    act.ptr = (act.ptr + 1) & 255
                ack = 0
            nbyte += 1
        elif act and rw == 1 and m_ack:                     # read data
            byte = out & act.mem[act.ptr]
            act.ptr = (act.ptr + 1) & 255
            ack = ack_out
            m_ack = ack_out == 0
        else:                                               # nobody answers
            byte, ack = out, ack_out
        rx.append(byte << 1 | ack)
        cur[1].append((byte, ack))
        if C and ack:
            cur[2], opened, skip = True, False, True
            rx.append(EV_NACK)
        elif P:
            cur[2], opened = True, False
    return [tuple(b) for b in bus], rx


# ------------------------------------------------------------------ ideal waveform (selftest)
def ideal(bus, low=1300, high=600, su=100, hd=300, setup=600, buf=1300):
    """Bus transactions -> [(t, 'sda scl')] with the given phase lengths (ns)."""
    t, sda, scl, out = 0, 1, 1, []
    def put(): out.append((t, f"{sda}{scl}"))
    put()
    for start, data, stop in bus:
        if start == "Sr":
            t += hd; sda = 1; put(); t += low - hd; scl = 1; put()
        t += setup if start == "Sr" else buf; sda = 0; put()
        t += setup; scl = 0; put()
        for byte, ack in data:
            for b in [(byte >> (7 - i)) & 1 for i in range(8)] + [ack]:
                t += hd; sda = b; put(); t += low - hd; scl = 1; put(); t += high; scl = 0; put()
        if stop:
            t += hd; sda = 0; put(); t += low - hd; scl = 1; put(); t += setup; sda = 1; put()
    t += buf; put()
    return out


# ------------------------------------------------------------------ decoder
TKEYS = ("low", "high", "su_dat", "hd_dat", "hd_sta", "su_sta", "su_sto", "buf", "period")


def decode(P):
    """Bus log -> (transactions, violations, timing lists in ns)."""
    trans, viol, T = [], [], {k: [] for k in TKEYS}
    cur, bits, pend = None, [], None          # a bit is sampled at SCL rise, committed at SCL fall
    last_chg = last_rise = last_fall = last_stop = hd_sta_from = per_ref = None
    fell = False
    prev = P[0][1]
    for t, s in P[1:]:
        if any(c not in "01" for c in s + prev):
            prev = s
            continue
        sda_ch, scl_ch = s[0] != prev[0], s[1] != prev[1]
        if sda_ch and scl_ch:
            viol.append(f"{t}: SDA and SCL change at the same time")
        if sda_ch and not scl_ch and s[1] == "1":           # START / STOP
            if len(bits):
                viol.append(f"{t}: {'START' if s[0] == '0' else 'STOP'} inside a byte ({len(bits)} bits)")
            if s[0] == "0":
                if cur is not None:
                    T["su_sta"].append(t - last_rise)
                elif last_stop is not None:
                    T["buf"].append(t - last_stop)
                cur = ["Sr" if cur is not None else "S", [], False]
                trans.append(cur)
                hd_sta_from, per_ref = t, None
            else:
                if cur is None:
                    viol.append(f"{t}: STOP without START")
                else:
                    cur[2] = True
                    T["su_sto"].append(t - last_rise)
                cur, last_stop = None, t
            bits, pend = [], None             # the SCL rise before START/STOP is not a bit
        elif sda_ch:
            if fell:
                T["hd_dat"].append(t - last_fall)
                fell = False
            last_chg = t
        if scl_ch and s[1] == "1":
            if cur is not None:
                pend = int(s[0])
                if last_fall is not None:
                    T["low"].append(t - last_fall)
                if last_chg is not None and last_fall is not None and last_chg > last_fall:
                    T["su_dat"].append(t - last_chg)
                if per_ref is not None:
                    T["period"].append(t - per_ref)
                per_ref = t
            last_rise, fell = t, False
        elif scl_ch:
            if hd_sta_from is not None:
                T["hd_sta"].append(t - hd_sta_from)
                hd_sta_from = None
            elif cur is not None:
                T["high"].append(t - last_rise)
            if cur is not None and pend is not None:
                bits.append(pend)
                if len(bits) == 9:
                    cur[1].append((int("".join(map(str, bits[:8])), 2), bits[8]))
                    bits = []
            pend = None
            last_fall, fell = t, True
        prev = s
    if cur is not None:
        viol.append("bus left open (no STOP)")
    return [tuple(x) for x in trans], viol, T


def timing_errors(T, khz):
    s = ip.SPEC[khz]
    errs = []
    for k in ("low", "high", "su_dat", "hd_sta", "su_sta", "su_sto", "buf"):
        if T[k] and min(T[k]) < s[k]:
            errs.append(f"t_{k} {min(T[k])} ns < {s[k]} ns ({khz} kHz)")
    if T["period"] and min(T["period"]) < 1e6 / khz:
        errs.append(f"SCL period {min(T['period'])} ns < {1e6 / khz:g} ns")
    return errs


def tstats(T):
    f = lambda k: f"{min(T[k])}" if T[k] else "-"
    return " ".join(f"{k}>={f(k)}" for k in ("low", "high", "su_dat", "hd_dat", "hd_sta", "su_sto", "buf")) + \
        (f" f<={1e6 / min(T['period']):.0f}kHz" if T["period"] else "")


# ------------------------------------------------------------------ simulation
_vvp = {}


SHARED = os.environ.get("PROTO_SHARED", "") == "1"      # the chip-level test bench on the shared 512-word memory (-DSHARED_IMEM); engine 1's image at word 256
SIM_LIBS_SHARED = [os.path.join(ROOT, "sim", "ihp_sram", f) for f in
                   ("RM_IHPSG13_2P_512x32_c2_bm_bist.v", "RM_IHPSG13_2P_core_behavioral_bm_bist_ideal.v",
                    "RM_IHPSG13_1P_256x32_c2_bm_bist.v", "RM_IHPSG13_1P_core_behavioral_bm_bist.v")]


def compile_tb(name, rise):
    key = (name, rise)
    shared = SHARED and name == "tb_i2c_chip"
    if key not in _vvp:
        os.makedirs(BUILD, exist_ok=True)
        out = os.path.join(BUILD, f"{name}_r{rise}{'_shared' if shared else ''}.vvp")
        tmp = f"{out}.{os.getpid()}.tmp"                    # suites run in parallel and share this file: compile aside, then rename
        srcs = sorted(glob.glob(os.path.join(ROOT, "src", "*.v")))
        subprocess.run(["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-DFUNCTIONAL"] + (["-DSHARED_IMEM"] if shared else []) + [f"-P{name}.T_RISE={rise}",
                        "-I", os.path.join(ROOT, "src"), "-I", os.path.join(ROOT, "tb"), "-o", tmp,
                        os.path.join(ROOT, "tb", name + ".v"), os.path.join(ROOT, "tb", "i2c_slave_model.v"),
                        *srcs, *(SIM_LIBS_SHARED if shared else SIM_LIBS)], check=True)
        os.replace(tmp, out)
        _vvp[key] = out
    return _vvp[key]


def run_sim(tb, name, files, plus, rise=1):
    suite = os.path.splitext(os.path.basename(sys.argv[0]))[0]       # i2c_test / i2c_slave_test: same case names, separate folders
    d = os.path.join(BUILD, suite, "".join(c if c.isalnum() or c in "-+=." else "_" for c in name))
    os.makedirs(d, exist_ok=True)
    args = []
    for k, words in files.items():
        fn = os.path.join(d, k.lower() + ".hex")
        sp.write_hex(words, fn)
        args.append(f"+{k}={fn}")
    log = os.path.join(d, "log.txt")
    args += [f"+{k}={v}" for k, v in plus.items()] + [f"+OUT={log}"]
    r = subprocess.run(["vvp", "-n", compile_tb(tb, rise), *args], capture_output=True, text=True)
    if r.returncode or "ERROR" in r.stdout:
        raise RuntimeError(f"{name}: simulation failed\n{r.stdout}{r.stderr}")
    L = dict(P=[], R=[], S=[], MEM={}, END={})
    for line in open(log):
        p = line.split()
        if not p:
            continue
        if p[0] == "P":
            t = int(p[1])
            if L["P"] and L["P"][-1][0] == t:
                L["P"][-1] = (t, p[2])
            else:
                L["P"].append((t, p[2]))
        elif p[0] == "R":
            L["R"].append(int(p[2], 16) if "x" not in p[2] else None)
        elif p[0] == "S":                      # RX words of an engine running the I2C slave firmware
            L["S"].append(int(p[2], 16) if "x" not in p[2] else None)
        elif p[0] == "MEM":
            L["MEM"][int(p[1])] = [int(p[2][i:i + 2], 16) for i in range(0, 512, 2)]
        elif p[0] == "END":
            L["END"] = dict(x.split("=") for x in p[1:])
    return L


# ------------------------------------------------------------------ checks + runner
RESULTS, LIMITS = [], []
LAST = {}                      # timing lists of the last case (used by the speed sweep)


def report(name, errs, stats, expect="pass"):
    ok = bool(errs) == (expect == "fail")
    tag = {"pass": "PASS" if ok else "FAIL", "fail": "DETECTED" if ok else "MISSED",
           "info": "ok" if not errs else "fails"}[expect]
    if expect != "info":
        RESULTS.append((name, ok))
    print(f"  {tag:8s} {name:50s} {stats}")
    if (not ok and expect != "info") or (errs and expect == "info"):
        for e in errs[:4 if expect == "info" else 6] or ["no error was reported"]:
            print(f"           {e}")
    return not errs


def compare(errs, what, got, exp):
    if got != exp:
        bad = next((i for i, (g, e) in enumerate(zip(got, exp)) if g != e), min(len(got), len(exp)))
        g = got[bad] if bad < len(got) else "-"
        e = exp[bad] if bad < len(exp) else "-"
        errs.append(f"{what}: {len(got)} vs {len(exp)} expected, first difference at #{bad}: {g} vs {e}")


def check(L, words, slaves, khz, spec=True):
    bus_exp, rx_exp = expect(words, slaves)
    trans, viol, T = decode(L["P"])
    errs = viol[:4]
    compare(errs, "bus transactions", trans, bus_exp)
    compare(errs, "host RX words", L["R"], rx_exp)
    for i, s in ((1, slaves[0]), (2, slaves[1])):
        if L["MEM"].get(i) != s.mem:
            errs.append(f"slave {i} memory differs from the model")
    if spec:
        errs += timing_errors(T, khz)
    e = L["END"]
    for k in ("fault", "drive_high", "viol", "timeout", "err"):
        if e.get(k, "0") != "0" and not (k == "err" and e.get("aborts", "0") != "0"):   # aborts set err
            errs.append(f"{k}={e[k]}")
    nb = sum(len(b) for _, b, _ in trans)
    return errs, f"{len(trans)} tr {nb} B | {tstats(T)}"


def case(name, txs, khz=400, expect="pass", rise=1, prog=None, s1=None, s2=False, spec=True, tb="tb_i2c_engine",
         role=0, **plus):
    """txs: list of word lists (one per transaction)."""
    words = [w for t in txs for w in t]
    slaves = [Slave(0x50, **(s1 or {})), Slave(0x23, en=s2)]
    files = {"HTX": words}
    if role == 0:
        files["PROG"] = prog or ip.master(khz)
    args = dict(ROLE=role, N=len(words), S2EN=int(s2), TMAX=50_000_000)
    if s1:
        if "nack_at" in s1:
            args["S_NACK_AT"] = s1["nack_at"]
        if not s1.get("en", True):
            args["S1EN"] = 0
    args.update({k.upper(): v for k, v in plus.items()})
    L = run_sim(tb, name, files, args, rise)
    errs, st = check(L, words, slaves, khz, spec)
    LAST.update(decode(L["P"])[2])
    LAST["END"] = L["END"]
    if tb == "tb_i2c_chip":
        e = L["END"]
        st = f"{e['frames']} mgmt frames ({e['retries']} TX retries), {int(e['cyc']) / 50:.0f} us | " + st
    return report(name, errs, st, expect)


W, T = ip.transaction, ip.word


def basic_set(rng, n=3):
    """A mix of writes, write->Sr->read, current-address reads and an absent address."""
    out = [W(0x50, [0x10, 0x00, 0xFF, 0xAA, 0x55]),
           W(0x50, [0x10], stop=False) + W(0x50, rd=4),
           W(0x50, rd=2),
           W(0x51, [0x01, 0x02]),                    # absent: NACK, data words dropped
           W(0x50, [0x20] + [1 << i for i in range(8)]),
           W(0x50, [0x20], stop=False) + W(0x50, rd=8)]
    for _ in range(n):
        p = rng.randrange(256)
        out += [W(0x50, [p] + [rng.randrange(256) for _ in range(rng.randrange(1, 6))]),
                W(0x50, [p], stop=False) + W(0x50, rd=rng.randrange(1, 6))]
    return out


def phase_selftest():
    print("Phase 1: decoder vs ideal waveform")
    rng = random.Random(1)
    for khz in (100, 400, 1000):
        s = ip.SPEC[khz]
        txs = basic_set(rng)
        bus, _ = expect([w for t in txs for w in t], [Slave(0x50), Slave(0x23, en=False)])
        hi = max(s["high"], int(1e6 / khz) - s["low"]) + 40           # padded to the nominal period
        wave = ideal(bus, low=s["low"] + 40, high=hi, hd=20, setup=max(s["su_sta"], s["su_sto"]) + 40,
                     buf=s["buf"] + 40)
        trans, viol, T = decode(wave)
        errs = viol + timing_errors(T, khz)
        compare(errs, "transactions", trans, bus)
        report(f"ideal {khz} kHz", errs, f"{len(trans)} tr | {tstats(T)}")
        w = ideal(bus, low=s["low"] - 20, high=hi, hd=20, setup=s["su_sto"] + 40, buf=s["buf"] + 40)
        report(f"t_LOW 20 ns short at {khz} kHz", timing_errors(decode(w)[2], khz), "", expect="fail")
        w = ideal(bus, low=s["low"] + 40, high=hi, hd=s["low"] + 40 - s["su_dat"] + 10,
                  setup=s["su_sto"] + 40, buf=s["buf"] + 40)
        report(f"t_SU;DAT 10 ns short at {khz} kHz", timing_errors(decode(w)[2], khz), "", expect="fail")
    wv = ideal([("S", [(0xA0, 0), (0x12, 0)], True)])
    k = next(i for i in range(6, len(wv)) if wv[i][1][1] == "1" and wv[i - 1][1][1] == "0")   # an SCL rise mid-byte
    flip = ("1" if wv[k][1][0] == "0" else "0") + "1"
    bad = wv[:k + 1] + [(wv[k][0] + 10, flip)] + wv[k + 1:]
    report("SDA change while SCL high inside a byte", decode(bad)[1], "", expect="fail")
    report("missing STOP", decode(ideal([("S", [(0xA0, 0)], False)]))[1], "", expect="fail")
    tr, _, _ = decode(ideal([("S", [(0xA0, 1)], True)]))
    errs = []
    compare(errs, "ack", tr, [("S", [(0xA0, 0)], True)])
    report("NACK vs expected ACK", errs, "", expect="fail")


def phase_peers():
    print("Phase 2: Verilog master model <-> slave models (no engine)")
    rng = random.Random(2)
    for lo, hi, nm in ((4800, 4100, "Sm"), (1400, 700, "Fm"), (600, 300, "Fm+")):
        case(f"peers {nm} basic set", basic_set(rng), role=2, spec=False, m_low_ns=lo, m_high_ns=hi)
    case("peers two slaves", [W(0x23, [0x05, 9, 8]), W(0x50, [0x05, 1, 2]), W(0x23, [0x05], stop=False) + W(0x23, rd=2)],
         role=2, s2=True, spec=False)
    case("peers slave NACKs data byte 2", [W(0x50, [0x01, 0x11, 0x22, 0x33]), W(0x50, [0x01], stop=False) + W(0x50, rd=3)],
         role=2, s1=dict(nack_at=2), spec=False)
    case("peers slave stretches every bit 2 us", basic_set(rng, 1), role=2, spec=False, s_stretch_mode=2, s_stretch_ns=2000)
    case("peers absent address only", [W(0x51, [1, 2, 3]), W(0x51, rd=2)], role=2, spec=False)


def phase_master():
    print("Phase 3: engine = I2C master, peers = slave models")
    rng = random.Random(3)
    for khz in (100, 400, 1000):
        case(f"master {khz} kHz basic set", basic_set(rng), khz)
        case(f"master {khz} kHz rise {ip.SPEC[khz]['rise']} ns (spec max)", basic_set(rng, 1), khz,
             rise=ip.SPEC[khz]["rise"])
        case(f"master {khz} kHz two slaves interleaved", [W(0x23, [0x40, 1, 2, 3]), W(0x50, [0x40, 4, 5]),
             W(0x23, [0x40], stop=False) + W(0x23, rd=3), W(0x50, [0x40], stop=False) + W(0x50, rd=2)], khz, s2=True)
        case(f"master {khz} kHz data NACK (C path drops queued bytes)",
             [W(0x50, [0x01, 0x11, 0x22, 0x33, 0x44]), W(0x50, [0x01], stop=False) + W(0x50, rd=4)], khz,
             s1=dict(nack_at=2))
        case(f"master {khz} kHz no slave at all", [W(0x50, [1, 2]), W(0x50, rd=3), W(0x23, [7])], khz,
             s1=dict(en=False))
    print(" clock stretching (400 kHz)")
    case("stretch after every byte 10 us", basic_set(rng, 1), s_stretch_mode=1, s_stretch_ns=10000)
    case("stretch every bit 1 us", basic_set(rng, 1), s_stretch_mode=2, s_stretch_ns=1000)
    case("stretch after every byte 500 us", [W(0x50, [0x30, 1, 2, 3])], s_stretch_mode=1, s_stretch_ns=500000)
    case("slave data valid 800 ns (tVD near Fm max 900)", basic_set(rng, 1), s_tvd_ns=800)
    print(" host-side flow (400 kHz)")
    case("host words arrive 30 us apart (master parks, SCL low)", basic_set(rng, 1), txgap_ns=30000)
    case("RX not drained for 2 ms (master stalls in PUSH)", basic_set(rng, 1), rxoff_ns=2_000_000)
    case("words without START on an idle bus are dropped", [[T(0x55 << 1 | 1)], W(0x50, [0x60, 0x99]),
         [T(0x77 << 1 | 1, p=1)], W(0x50, [0x60], stop=False) + W(0x50, rd=1)])
    print(" stress")
    for khz in (100, 1000):
        r = random.Random(khz)
        txs = []
        while sum(len(t) for t in txs) < (300 if khz == 100 else 1100):
            p = r.randrange(256)
            if r.random() < 0.5:
                txs.append(W(0x50, [p] + [r.randrange(256) for _ in range(r.randrange(1, 16))]))
            else:
                txs.append(W(0x50, [p], stop=False) + W(0x50, rd=r.randrange(1, 16)))
        case(f"master {khz} kHz random stress ({sum(len(t) for t in txs)} words)", txs, khz)
    print(" speed sweep beyond 1 MHz: shrink tA/tH to 0, data must stay correct (spec check off)")
    for tvd in (0, 100, 200):
        last = None
        for half in (12, 10, 8, 6, 5, 4, 3, 2):           # target SCL half period in clocks at 50 MHz
            d = dict(tA=half - 2, tH=max(0, half - 4), tL=half, su_sta=half, hd_sta=half, su_sto=half, buf=2 * half)
            ok = case(f"sweep tA={d['tA']} tH={d['tH']} tVD={tvd} ns", basic_set(random.Random(half), 1), 1000,
                      prog=ip.master(1000, d=d), spec=False, s_tvd_ns=tvd, expect="info")
            f = 1e6 / min(LAST["period"]) if LAST["period"] else 0
            if not ok:
                break
            last = f"{f:.0f} kHz measured (tA={d['tA']}, tH={d['tH']})"
        LIMITS.append((f"master max SCL, slave tVD {tvd} ns", last, None if ok else f"tA={d['tA']} tH={d['tH']}"))


def phase_chip():
    print("Phase 5: full chip, host only through the management SPI link")
    rng = random.Random(5)
    chip = dict(tb="tb_i2c_chip")
    for khz in (100, 400, 1000):
        case(f"chip eng0 {khz} kHz basic set", basic_set(rng), khz, eng=0, **chip)
    case("chip eng1 400 kHz basic set", basic_set(rng), 400, eng=1, **chip)
    case("chip eng1 1000 kHz two slaves + data NACK", [W(0x23, [0x40, 1, 2, 3]), W(0x50, [0x01, 0x11, 0x22, 0x33]),
         W(0x23, [0x40], stop=False) + W(0x23, rd=3), W(0x50, [0x01], stop=False) + W(0x50, rd=2)], 1000, eng=1,
         s2=True, s1=dict(nack_at=2), **chip)
    case("chip eng0 400 kHz rise 300 ns + stretch every byte 20 us", basic_set(rng, 1), 400, rise=300, eng=0,
         s_stretch_mode=1, s_stretch_ns=20000, **chip)
    case("chip eng0 1000 kHz slow host (mgmt half 2 us)", basic_set(rng, 1), 1000, eng=0, mgmt_half_ns=2000, **chip)
    case("chip eng0 1000 kHz fastest host (mgmt half 8 clk)", basic_set(rng, 1), 1000, eng=0, mgmt_half_ns=160, **chip)
    for khz, eng in ((400, 0), (1000, 1)):
        r = random.Random(khz + eng)
        txs = []
        while sum(len(t) for t in txs) < 300:
            p = r.randrange(256)
            txs.append(W(0x50, [p] + [r.randrange(256) for _ in range(r.randrange(1, 12))]) if r.random() < 0.5
                       else W(0x50, [p], stop=False) + W(0x50, rd=r.randrange(1, 12)))
        case(f"chip eng{eng} {khz} kHz random stress ({sum(len(t) for t in txs)} words)", txs, khz, eng=eng, **chip)


def _find(ws, op, arg, after=0):
    w = sp.OP[op] << 27 | arg
    return next(i for i in range(after, len(ws)) if ws[i] == w)


def phase_mutants():
    print("Mutants: broken firmware / pad setup must be caught (400 kHz)")
    rng = random.Random(6)
    good = ip.master(400)
    I = lambda op, a=0: sp.OP[op] << 27 | a
    bit = _find(good, "SETL", 9) + 1                               # bit loop start
    def m(name, fn, **kw):
        ws = list(good)
        fn(ws)
        case(f"mut {name}", basic_set(rng, 1), 400, prog=ws, expect="fail", **kw)
    m("bit loop ignores stretching (no WAITH SCL)", lambda ws: ws.__setitem__(_find(ws, "WAITH", 7, bit), I("NOP")),
      s_stretch_mode=2, s_stretch_ns=3000)
    m("no ACK check (C flag consumed, ignored)", lambda ws: ws.__setitem__(_find(ws, "SETL", 9) + 7,
      I("JPO", _find(ws, "SETL", 9) + 8)), s1=dict(nack_at=2))
    m("samples SDA while SCL is low", lambda ws: ws.__setitem__(slice(bit + 2, bit + 5),
      [ws[bit + 4], ws[bit + 2], ws[bit + 3]]))
    m("STOP does not pull SDA low first", lambda ws: ws.__setitem__(_find(ws, "SETLO", 6), I("NOP")))
    last = max(i for i, w in enumerate(good) if w >> 27 != sp.OP["HALT"])      # image may be padded (FW_ORG)
    m("t_HD;STA = 0", lambda ws: ws.__setitem__(last - 1, I("WAIT", 0)))
    m("t_LOW too short (OUT1 0)", lambda ws: ws.__setitem__(bit + 1, I("OUT1", 0)))
    case("mut pads claimed push-pull (drives SDA/SCL high)", basic_set(rng, 1), 400, pushpull=1, expect="fail")


PHASES = dict(selftest=phase_selftest, peers=phase_peers, master=phase_master, chip=phase_chip,
              mutants=phase_mutants)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("phases", nargs="*", default=list(PHASES))
    a = ap.parse_args()
    for p in a.phases:
        PHASES[p]()
    for label, last, fail in LIMITS:
        print(f"LIMIT {label}: last pass {last}, first fail {fail}")
    bad = [n for n, ok in RESULTS if not ok]
    print(f"RESULT i2c_test: {'PASS' if not bad else 'FAIL'} ({len(RESULTS) - len(bad)}/{len(RESULTS)} cases as expected)")
    sys.exit(1 if bad else 0)
