#!/usr/bin/env python3
"""1-Wire master with CRC-8 on the engine, against a Verilog 1-Wire device model (tb/peer_onewire.v, written from the Maxim timing rules).
Checks: presence detection, Read ROM (8 bytes, CRC verified on chip), Skip ROM + Read Scratchpad (9 bytes + CRC), a corrupted ROM CRC
being detected, the slot timing windows measured on the pad (reset >= 480 us, write-1 low 1..15 us, write-0 low 60..120 us, every
slot 60..120 us), and broken firmware being caught.
  python host/onewire_test.py [run mutants]
"""
import random
import sys

import crc_model as cm
import onewire_prog as op
import proto_lib as pl

EV = op.EV
RESULTS = []
CRC8 = "CRC-8/MAXIM-DOW"


def report(name, errs, stats, expect="pass"):
    ok = bool(errs) == (expect == "fail")
    tag = {"pass": "PASS" if ok else "FAIL", "fail": "DETECTED" if ok else "MISSED"}[expect]
    RESULTS.append((name, ok))
    print(f"  {tag:8s} {name:58s} {stats}")
    if not ok:
        for e in errs[:5] or ["no error was reported"]:
            print(f"           {e}")
    return ok


def rom(rnd, family=0x28, bad_crc=False):
    b = [family] + [rnd.randrange(256) for _ in range(6)]
    c = cm.make(CRC8).of(bytes(b))
    return b + [c ^ (1 if bad_crc else 0)]


def hexle(bs):
    """bytes (byte 0 first) -> hex string with byte 0 in the low bits, as the model's +OW_ROM / +OW_SP expect."""
    return "".join(f"{b:02x}" for b in reversed(bs))


def pulses(tl):
    """Timeline -> [(t_start_ns, width_ns)] of low pulses."""
    out, t0 = [], None
    for t, l in tl:
        if l == 0 and t0 is None:
            t0 = t
        elif l == 1 and t0 is not None:
            out.append((t0, t - t0))
            t0 = None
    return out


C = op.cmd_word


def write_seq(b):
    return [C(2, x) for x in b]


def run_case(name, words, exp, rom_bytes=None, sp_bytes=None, nopres=False, firmware=None, expect="pass", slots=None):
    plus = {}
    if rom_bytes:
        plus["OW_ROM"] = hexle(rom_bytes)
    if sp_bytes:
        plus["OW_SP"] = hexle(sp_bytes)
    if nopres:
        plus["OW_NOPRES"] = 1
    n_slots = sum({2: 8, 3: 8}.get(w >> 28, 0) for w in words)
    n_reset = sum(1 for w in words if w >> 28 == 1)
    dur = (n_reset * 1000 + n_slots * 80 + 300) * 1000
    L = pl.run(name, progs={0: firmware or op.onewire_master()}, htx={0: words}, od=0x04, peer=1, dur_ns=dur, plus=plus)
    errs = []
    got = [w for _, w in L["A"]]
    if got != exp:
        k = next((i for i, (g, e) in enumerate(zip(got, exp)) if g != e), min(len(got), len(exp)))
        g = f"{got[k]:#x}" if k < len(got) else "-"
        e = f"{exp[k]:#x}" if k < len(exp) else "-"
        errs.append(f"RX words: {len(got)} vs {len(exp)} expected, first difference at #{k}: {g} vs {e}")
    # slot timing on the pad
    pu = pulses(pl.timeline(L["P"], 2))
    if pu:
        if words[0] >> 28 == 1 and pu[0][1] < 480_000:
            errs.append(f"reset low {pu[0][1] / 1000:.0f} us < 480 us")
        # walk the expected slots after each reset: write bits or read slots
        i = 0
        for w in words:
            o = w >> 28
            if o == 1:
                i += 1                                   # reset pulse itself; the presence pulse (device) is a second low pulse
                if i < len(pu) and pu[i][0] - pu[i - 1][0] < 480_000:
                    pass
                i += 1 if (i < len(pu) and pu[i][1] > 60_000 and pu[i][1] < 250_000 and exp) else 0
            elif o == 2:
                for k in range(8):
                    if i >= len(pu):
                        break
                    bit = w >> k & 1
                    wd = pu[i][1]
                    lo, hi = (1000, 15000) if bit else (60000, 120000)
                    if not lo <= wd <= hi:
                        errs.append(f"write {bit} slot low {wd / 1000:.1f} us outside {lo // 1000}..{hi // 1000} us")
                        break
                    i += 1
            elif o == 3:
                i += 8
        st = [pu[k + 1][0] - pu[k][0] for k in range(len(pu) - 1) if pu[k][1] < 200_000 and pu[k + 1][1] < 200_000]
        slot_periods = [d for d in st if d < 200_000]
        if slot_periods and (min(slot_periods) < 60_000 or max(slot_periods) > 125_000):
            errs.append(f"slot period {min(slot_periods) / 1000:.0f}..{max(slot_periods) / 1000:.0f} us outside 60..120 us")
    if L["END"].get("fault0", 0) or L["END"].get("contend", 0):
        errs.append(f"END {L['END']}")
    return report(name, errs, f"{len(words)} commands, {len(got)} result words, {len(pu)} low pulses", expect)


def read_rom_case(name, rnd, bad_crc=False, **kw):
    r = rom(rnd, bad_crc=bad_crc)
    words = [C(1), C(2, 0x33), C(4)] + [C(3)] * 8 + [C(5)]
    exp = [EV | 0x101] + r + [EV | 0x200 | (0 if bad_crc else 1)]
    return run_case(name, words, exp, rom_bytes=r, **kw)


def phase_run():
    print("Phase 1: 1-Wire master + CRC-8 on the engine, device model on the bus")
    rnd = random.Random(41)
    read_rom_case("Read ROM, CRC verified on chip", rnd)
    for k in range(3):
        read_rom_case(f"Read ROM, random device {k + 2}", rnd)
    read_rom_case("Read ROM with a corrupted CRC byte is detected", rnd, bad_crc=True)
    sp = [rnd.randrange(256) for _ in range(8)]
    sp.append(cm.make(CRC8).of(bytes(sp)))
    words = [C(1)] + write_seq([0xCC, 0xBE]) + [C(4)] + [C(3)] * 9 + [C(5)]
    run_case("Skip ROM + Read Scratchpad (9 bytes, CRC ok)", words, [EV | 0x101] + sp + [EV | 0x201], sp_bytes=sp)
    sp2 = list(sp)
    sp2[3] ^= 0x10
    run_case("scratchpad with a flipped data bit is detected", words, [EV | 0x101] + sp2 + [EV | 0x200], sp_bytes=sp2)
    run_case("no device on the bus: no presence", [C(1), C(1)], [EV | 0x100, EV | 0x100], nopres=True)
    r = rom(rnd)
    words = [C(1), C(2, 0x33), C(4)] + [C(3)] * 8 + [C(5), C(1), C(2, 0x33), C(4)] + [C(3)] * 8 + [C(5)]
    run_case("two Read ROM transactions back to back", words, ([EV | 0x101] + r + [EV | 0x201]) * 2, rom_bytes=r)
    allbits = [0x00, 0xFF, 0x55, 0xAA, 0x0F, 0xF0, 0x01, 0x80]
    run_case("every bit pattern as the command byte is timed correctly (write slots)",
             [C(1)] + write_seq(allbits) + [C(1)], [EV | 0x101, EV | 0x101], rom_bytes=r)


def phase_mutants():
    print("Phase 2: broken firmware must be caught")
    rnd = random.Random(42)
    r = rom(rnd)
    words = [C(1), C(2, 0x33), C(4)] + [C(3)] * 8 + [C(5)]
    exp = [EV | 0x101] + r + [EV | 0x201]

    rb = rom(rnd, bad_crc=True)
    exp_bad = [EV | 0x101] + rb + [EV | 0x200]

    def m(name, bad=False, **kw):
        run_case(f"mutant: {name}", words, exp_bad if bad else exp, rom_bytes=rb if bad else r,
                 firmware=op.onewire_master(**kw), expect="fail")
    m("reset low 300 us", t=dict(reset_low=300))
    m("write-0 low 30 us (slave samples while the line is rising)", t=dict(w0_low=30))
    m("write-1 low 20 us", t=dict(w1_low=20))
    m("read sample 40 us after the falling edge", t=dict(r_wait=34))
    m("CRC polynomial 0x07", crc_cfg=[("POLY", 7)] + op.CRC_MAXIM[1:])
    m("no reflection", crc_cfg=op.CRC_MAXIM[:3] + [("FMT", 7)])
    m("bytes not fed to the CRC (a corrupted ROM then looks good)", bad=True, mut=("no_feed",))
    m("slot period 40 us", t=dict(w1_rest=34, w0_rest=2))


def main():
    phases = sys.argv[1:] or ["run", "mutants"]
    for p in phases:
        {"run": phase_run, "mutants": phase_mutants}[p]()
    bad = [n for n, ok in RESULTS if not ok]
    print(f"RESULT onewire_test: {'PASS' if not bad else 'FAIL'} ({len(RESULTS) - len(bad)}/{len(RESULTS)} cases as expected)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
