#!/usr/bin/env python3
"""JTAG controller firmware against a Verilog TAP model (tb/peer_jtag.v) and an independent Python TAP model (this file), both written
from IEEE 1149.1. For every test the expected TMS/TDI stream is built from the commands; it is
  (1) compared with the TCK/TMS/TDI waveform decoded from the pads (the firmware drives exactly the intended pin stream),
  (2) run through the Python TAP model to predict every TDO bit, which must equal what the engine captured (RX words).
  python host/jtag_test.py [run mutants]
"""
import random
import sys

import jtag_prog as jp
import proto_lib as pl

RESULTS = []
TCK, TMS, TDI, TDO = jp.TCK, jp.TMS, jp.TDI, jp.TDO

STATES = ["TLR", "RTI", "SELDR", "CAPDR", "SHDR", "EX1DR", "PADR", "EX2DR", "UPDR", "SELIR", "CAPIR", "SHIR", "EX1IR", "PAIR", "EX2IR", "UPIR"]
NEXT = {  # (state, tms) -> state, from the 1149.1 state diagram
    ("TLR", 0): "RTI", ("TLR", 1): "TLR", ("RTI", 0): "RTI", ("RTI", 1): "SELDR",
    ("SELDR", 0): "CAPDR", ("SELDR", 1): "SELIR", ("CAPDR", 0): "SHDR", ("CAPDR", 1): "EX1DR",
    ("SHDR", 0): "SHDR", ("SHDR", 1): "EX1DR", ("EX1DR", 0): "PADR", ("EX1DR", 1): "UPDR",
    ("PADR", 0): "PADR", ("PADR", 1): "EX2DR", ("EX2DR", 0): "SHDR", ("EX2DR", 1): "UPDR",
    ("UPDR", 0): "RTI", ("UPDR", 1): "SELDR",
    ("SELIR", 0): "CAPIR", ("SELIR", 1): "TLR", ("CAPIR", 0): "SHIR", ("CAPIR", 1): "EX1IR",
    ("SHIR", 0): "SHIR", ("SHIR", 1): "EX1IR", ("EX1IR", 0): "PAIR", ("EX1IR", 1): "UPIR",
    ("PAIR", 0): "PAIR", ("PAIR", 1): "EX2IR", ("EX2IR", 0): "SHIR", ("EX2IR", 1): "UPIR",
    ("UPIR", 0): "RTI", ("UPIR", 1): "SELDR",
}


class Tap:
    """Python TAP: IR 4 bits (capture 0001), IDCODE 32, USER32 (ir 2), USER64 (ir 3), BYPASS 1 bit (everything else)."""

    def __init__(self, idcode=0x1BA00477):
        self.s, self.ir, self.irsh = "TLR", 1, 0
        self.id, self.u32, self.u64 = idcode, 0, 0
        self.sh, self.n = 0, 1
        self.tdo = 1

    def length(self):
        return {1: 32, 2: 32, 3: 64}.get(self.ir, 1)

    def clock(self, tms, tdi):
        """One rising TCK; returns the TDO value present at this edge (set after the previous falling edge)."""
        out = self.tdo
        s = self.s
        if s == "CAPDR":
            self.n = self.length()
            self.sh = {1: self.id, 2: self.u32, 3: self.u64}.get(self.ir, 0)
        elif s == "SHDR":
            self.n = self.length()
            self.sh = (self.sh >> 1) | tdi << (self.n - 1)
        elif s == "UPDR":
            if self.ir == 2:
                self.u32 = self.sh & 0xFFFFFFFF
            if self.ir == 3:
                self.u64 = self.sh
        elif s == "CAPIR":
            self.irsh = 1
        elif s == "SHIR":
            self.irsh = (self.irsh >> 1) | tdi << 3
        elif s == "UPIR":
            self.ir = self.irsh
        self.s = NEXT[(s, tms)]
        if self.s == "TLR":
            self.ir = 1
        # falling edge: TDO for the new state
        self.tdo = (self.sh & 1) if self.s == "SHDR" else (self.irsh & 1) if self.s == "SHIR" else 1
        return out


def report(name, errs, stats, expect="pass"):
    ok = bool(errs) == (expect == "fail")
    tag = {"pass": "PASS" if ok else "FAIL", "fail": "DETECTED" if ok else "MISSED"}[expect]
    RESULTS.append((name, ok))
    print(f"  {tag:8s} {name:58s} {stats}")
    if not ok:
        for e in errs[:5] or ["no error was reported"]:
            print(f"           {e}")
    return ok


def build(cmds):
    """cmds: list of ('tms', bits) | ('scan', bits, last) | ('idle', n) -> (host words, TMS/TDI stream, scan clock ranges)."""
    words, stream, scans = [], [], []
    for c in cmds:
        if c[0] == "tms":
            words.append(jp.tms_word(c[1]))
            stream += [(b, 0) for b in c[1]]
        elif c[0] == "scan":
            bits, last = c[1], c[2] if len(c) > 2 else True
            words += jp.scan_words(bits, last)
            start = len(stream)
            stream += [(1 if (last and i == len(bits) - 1) else 0, b) for i, b in enumerate(bits)]
            scans.append((start, len(bits)))
        else:
            words.append(jp.idle_word(c[1]))
            stream += [(0, 0)] * c[1]
    return words, stream, scans


def expected_rx(stream, scans, idcode):
    tap = Tap(idcode)
    tdo = [tap.clock(tms, tdi) for tms, tdi in stream]
    out = []
    for start, n in scans:
        bits = tdo[start:start + n]
        for i in range(0, n, 32):
            ch = bits[i:i + 32]
            out.append(sum(b << k for k, b in enumerate(ch)))
    return out


def decode_pads(P):
    """(tck rising edges) -> [(tms, tdi, tdo_before_edge)] and the TCK period list in ns."""
    out, periods = [], []
    prev_tck, last_rise, tdo_prev = (P[0][1] >> TCK) & 1, None, 1      # the first sample is the initial level, not an edge
    for t, v in P:
        tck, tms, tdi, tdo = v >> TCK & 1, v >> TMS & 1, v >> TDI & 1, v >> TDO & 1
        if tck and not prev_tck:
            out.append((tms, tdi, tdo_prev))
            if last_rise is not None:
                periods.append(t - last_rise)
            last_rise = t
        prev_tck = tck
        tdo_prev = tdo
    return out, periods


def run_case(name, cmds, half=10, idcode=0x1BA00477, firmware=None, expect="pass"):
    words, stream, scans = build(cmds)
    exp = expected_rx(stream, scans, idcode)
    ncl = len(stream)
    period_ns = (2 * half + 10) * pl.NS_PER_CLK
    dur = int((ncl * period_ns * 1.3 + 100_000))
    plus = {"JT_ID": f"{idcode:x}"}
    L = pl.run(name, progs={0: firmware or jp.jtag_master(half)}, htx={0: words}, peer=2, dur_ns=dur, plus=plus)
    errs = []
    got = [w for _, w in L["A"]]
    if got != exp:
        k = next((i for i, (g, e) in enumerate(zip(got, exp)) if g != e), min(len(got), len(exp)))
        g = f"{got[k]:#x}" if k < len(got) else "-"
        e = f"{exp[k]:#x}" if k < len(exp) else "-"
        errs.append(f"captured TDO words: {len(got)} vs {len(exp)} expected, first difference at #{k}: {g} vs {e}")
    dec, periods = decode_pads(L["P"])
    pins = [(a, b) for a, b, _ in dec]
    if pins != stream:
        k = next((i for i, (g, e) in enumerate(zip(pins, stream)) if g != e), min(len(pins), len(stream)))
        errs.append(f"TMS/TDI stream on the pins: {len(pins)} clocks vs {len(stream)} expected, first difference at clock {k}")
    if periods and min(periods) < (2 * half - 10) * pl.NS_PER_CLK:
        errs.append(f"TCK period {min(periods)} ns shorter than {(2 * half - 10) * pl.NS_PER_CLK} ns")
    if L["END"].get("fault0", 0):
        errs.append("engine faulted")
    st = f"{ncl} TCK clocks, {len(got)} words, TCK >= {min(periods) if periods else 0} ns"
    return report(name, errs, st, expect)


def rb(rnd, n):
    return [rnd.randrange(2) for _ in range(n)]


def go_ir(ir_value):
    return [("tms", jp.TMS_TO_SHIFT_IR), ("scan", jp.bits_of(ir_value, 4), True), ("tms", jp.TMS_UPDATE_IDLE)]


def go_dr(bits):
    return [("tms", jp.TMS_TO_SHIFT_DR), ("scan", bits, True), ("tms", jp.TMS_UPDATE_IDLE)]


def phase_run():
    print("Phase 1: JTAG controller on the engine, Verilog TAP model on the pins, Python TAP model as oracle")
    rnd = random.Random(51)
    reset = [("tms", jp.TMS_RESET)]
    run_case("IDCODE read (default instruction after reset)", reset + go_dr([0] * 32))
    run_case("IDCODE read, other device ID", reset + go_dr([0] * 32), idcode=0x2BA01477)
    run_case("IR scan (4 bits) reads back the capture pattern 0001", reset + [("tms", jp.TMS_TO_SHIFT_IR),
             ("scan", [1, 1, 1, 1], True), ("tms", jp.TMS_UPDATE_IDLE)])
    v = rnd.getrandbits(32)
    run_case("USER32: write a word, read it back", reset + go_ir(2) + go_dr(jp.bits_of(v, 32)) + go_dr([0] * 32))
    v64 = rnd.getrandbits(64)
    run_case("USER64: write 64 bits (2 words), read back", reset + go_ir(3) + go_dr(jp.bits_of(v64, 64)) + go_dr([0] * 64))
    run_case("BYPASS: 17 bits come back delayed by one clock", reset + go_ir(0xF) + go_dr(rb(rnd, 17)))
    run_case("scan lengths 1..40 through BYPASS", reset + go_ir(0xF) + [x for n in range(1, 41) for x in go_dr(rb(rnd, n))])
    run_case("scan lengths 1..33 of IDCODE (partial words)", reset + [x for n in range(1, 34) for x in
             [("tms", jp.TMS_TO_SHIFT_DR), ("scan", [0] * n, True), ("tms", jp.TMS_UPDATE_IDLE)]])
    run_case("scan of 100 bits across several words (USER64 chain overrun)", reset + go_ir(3) + go_dr(rb(rnd, 100)))
    run_case("Pause-DR in the middle of a scan (Exit1 -> Pause -> Exit2 -> Shift)", reset + go_ir(2) + [
        ("tms", jp.TMS_TO_SHIFT_DR), ("scan", rb(rnd, 12), False), ("tms", [1, 0, 0, 1, 0]), ("scan", rb(rnd, 20), True),
        ("tms", jp.TMS_UPDATE_IDLE)] + go_dr([0] * 32))
    run_case("idle clocks in Run-Test/Idle", reset + [("idle", 50)] + go_dr([0] * 32))
    for half in (3, 40):
        run_case(f"TCK half period {half} clocks", reset + go_ir(2) + go_dr(rb(rnd, 32)) + go_dr([0] * 32), half=half)
    # random walks
    for k in range(4):
        cmds = reset[:]
        for _ in range(25):
            r = rnd.random()
            if r < 0.4:
                cmds.append(("tms", [rnd.randrange(2) for _ in range(rnd.randrange(1, 12))]))
            elif r < 0.9:
                cmds.append(("scan", rb(rnd, rnd.randrange(1, 70)), rnd.random() < 0.5))
            else:
                cmds.append(("idle", rnd.randrange(1, 30)))
        run_case(f"random walk {k + 1} (TMS sequences, scans, idle)", cmds)


def phase_mutants():
    print("Phase 2: broken firmware must be caught")
    rnd = random.Random(52)
    cmds = [("tms", jp.TMS_RESET)] + go_ir(2) + go_dr(rb(rnd, 37)) + go_dr([0] * 37) + go_dr([0] * 32)
    for name, mut in (("last bit does not raise TMS", ("no_last",)), ("TDO sampled after TCK falls (one bit late)", ("late_sample",)),
                      ("partial words not right-aligned", ("no_align",)), ("chunks of 31 bits", ("chunk31",))):
        run_case(f"mutant: {name}", cmds, firmware=jp.jtag_master(10, mut=mut), expect="fail")


def main():
    phases = sys.argv[1:] or ["run", "mutants"]
    for p in phases:
        {"run": phase_run, "mutants": phase_mutants}[p]()
    bad = [n for n, ok in RESULTS if not ok]
    print(f"RESULT jtag_test: {'PASS' if not bad else 'FAIL'} ({len(RESULTS) - len(bad)}/{len(RESULTS)} cases as expected)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
