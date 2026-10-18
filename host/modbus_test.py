#!/usr/bin/env python3
"""Modbus RTU over UART with the CRC unit: engine 0 transmits frames, engine 1 receives and checks them, both in tb/tb_proto.v.
Oracles: crc_model.py (published check values), a UART decoder written from the 8N1 rules (proto_lib.uart_decode) that also
checks every edge against the bit grid, and Python waveform generators for the receive side.
  python host/modbus_test.py [tx rx loop mutants]
"""
import random
import sys

import crc_model as cm
import modbus_prog as mp
import proto_lib as pl

EV = mp.EV
RESULTS = []


def report(name, errs, stats, expect="pass"):
    ok = bool(errs) == (expect == "fail")
    tag = {"pass": "PASS" if ok else "FAIL", "fail": "DETECTED" if ok else "MISSED"}[expect]
    RESULTS.append((name, ok))
    print(f"  {tag:8s} {name:58s} {stats}")
    if not ok:
        for e in errs[:5] or ["no error was reported"]:
            print(f"           {e}")
    return ok


def payload(rnd, n):
    return [rnd.randrange(256) for _ in range(n)]


def tx_case(name, payloads, cpb=434, prog=None, expect="pass"):
    htx, exp = [], []
    for p in payloads:
        htx += [len(p)] + [(0xA5A5A500 | b) ^ (0x5A5A5A00 if i & 1 else 0) for i, b in enumerate(p)]   # junk above the byte
        exp.append(mp.frame_bytes(p))
    bit = cpb * pl.NS_PER_CLK
    n_bytes = sum(len(e) for e in exp)
    dur = (n_bytes * 10 + len(exp) * 45) * bit + 200_000
    L = pl.run(name, progs={0: prog or mp.modbus_tx(cpb)}, htx={0: htx}, dur_ns=dur)
    fr = pl.uart_decode(pl.timeline(L["P"], 0), bit)
    errs = []
    got = [b for _, b, _, _ in fr]
    flat = [b for e in exp for b in e]
    if got != flat:
        k = next((i for i, (g, e) in enumerate(zip(got, flat)) if g != e), min(len(got), len(flat)))
        errs.append(f"bytes on the wire: {len(got)} vs {len(flat)} expected, first difference at #{k}")
    if not all(f[2] for f in fr):
        errs.append("a stop bit is not high")
    if not all(f[3] for f in fr):
        errs.append("an edge is off the bit grid")
    # gaps: inside a frame <= 3 bit times, between frames >= 3.5 characters (38.5 bits)
    idx = 0
    gaps_in, gaps_between = [], []
    for fi, e in enumerate(exp):
        for bi in range(len(e)):
            k = idx + bi
            if k + 1 < len(fr):
                g = (fr[k + 1][0] - (fr[k][0] + 10 * bit)) / bit
                (gaps_between if bi == len(e) - 1 else gaps_in).append(g)
        idx += len(e)
    if gaps_in and max(gaps_in) > 3:
        errs.append(f"gap inside a frame {max(gaps_in):.1f} bit times (> 3)")
    if gaps_between and (min(gaps_between) < 44 or max(gaps_between) > 46):
        errs.append(f"gap between frames {min(gaps_between):.1f}..{max(gaps_between):.1f} bit times (the sender waits 4 characters = 44 bits)")
    if L["END"].get("fault0", 0) or L["END"].get("contend", 0):
        errs.append(f"END {L['END']}")
    st = f"{len(exp)} frames {n_bytes} B | in-frame gap <= {max(gaps_in, default=0):.1f} bits, gap {min(gaps_between, default=0):.1f} bits"
    return report(name, errs, st, expect)


def rx_waveform(frames, cpb, rnd, intra=(0, 6), inter=(42, 70), err=0.0):
    """frames: list of byte lists (already including CRC bytes, possibly corrupted)."""
    gaps = []
    for fr in frames:
        g = [rnd.uniform(*intra) if i < len(fr) - 1 else rnd.uniform(*inter) for i in range(len(fr))]
        gaps.append(g)
    cpb_tx = cpb * (1 + err)
    ev, end = pl.uart_wave(frames, cpb_tx, start_ns=2000, idle_bits=2, gap_bits=gaps, pin=1)
    return ev, end


def rx_expected(frames):
    out = []
    for fr in frames:
        out += list(fr)
        c = cm.make("CRC-16/MODBUS")
        for b in fr:
            c.feed_byte(b)
        ok = int(len(fr) >= 4 and c.reg == 0)
        out.append(EV | ok << 8 | len(fr))
    return out


def rx_case(name, frames, cpb=434, prog=None, expect="pass", rnd=None, **wf):
    rnd = rnd or random.Random(5)
    ev, end = rx_waveform(frames, cpb, rnd, **wf)
    bit = cpb * pl.NS_PER_CLK
    L = pl.run(name, progs={1: prog or mp.modbus_rx(cpb)}, ext=0x02, stim=ev, dur_ns=end + 60 * bit)
    got = [w for _, w in L["B"]]
    exp = rx_expected(frames)
    errs = []
    if got != exp:
        k = next((i for i, (g, e) in enumerate(zip(got, exp)) if g != e), min(len(got), len(exp)))
        g = f"{got[k]:#x}" if k < len(got) else "-"
        e = f"{exp[k]:#x}" if k < len(exp) else "-"
        errs.append(f"RX words: {len(got)} vs {len(exp)} expected, first difference at #{k}: {g} vs {e}")
    if L["END"].get("fault1", 0):
        errs.append("engine faulted")
    nbad = sum(1 for w in exp if w >= EV and not w >> 8 & 1)
    return report(name, errs, f"{len(frames)} frames ({nbad} bad) {sum(len(f) for f in frames)} B", expect)


def good_frame(rnd, n):
    return mp.frame_bytes(payload(rnd, n))


def phase_tx():
    print("Phase 1: engine 0 transmits Modbus RTU frames (CRC-16 from the CRC unit)")
    rnd = random.Random(21)
    tx_case("textbook frame 01 03 00 00 00 0A -> CRC C5 CD", [[0x01, 0x03, 0x00, 0x00, 0x00, 0x0A]])
    tx_case("one-byte payload", [[0x7F]])
    tx_case("frames of 2..32 bytes, 115200 baud", [payload(rnd, n) for n in (2, 5, 8, 16, 32)])
    tx_case("32 random frames of 1..12 bytes", [payload(rnd, rnd.randrange(1, 13)) for _ in range(32)])
    tx_case("19200 baud (cpb 2604)", [payload(rnd, 6), payload(rnd, 3)], cpb=2604)
    tx_case("all-0x00 and all-0xFF payloads", [[0] * 8, [0xFF] * 8])


def phase_rx():
    print("Phase 2: engine 1 receives frames from a Python waveform and checks the CRC")
    rnd = random.Random(22)
    rx_case("good frames of 4..40 bytes, random gaps", [good_frame(rnd, rnd.randrange(2, 39)) for _ in range(8)], rnd=rnd)
    fr = [good_frame(rnd, rnd.randrange(3, 20)) for _ in range(10)]
    bad = []
    for f in fr:                                   # one flipped bit anywhere (data or CRC): always detected
        f = list(f)
        f[rnd.randrange(len(f))] ^= 1 << rnd.randrange(8)
        bad.append(f)
    rx_case("one flipped bit per frame is always detected", bad, rnd=rnd)
    rx_case("mix of good and corrupted frames", [x for pair in zip(fr[:5], bad[:5]) for x in pair], rnd=rnd)
    rx_case("frames shorter than 4 bytes are bad", [[0x01], [0x01, 0x02], [0x01, 0x02, 0x03], good_frame(rnd, 3)], rnd=rnd)
    rx_case("gaps of 16 bit times inside a frame stay one frame", [good_frame(rnd, 10) for _ in range(3)], rnd=rnd,
            intra=(15, 16))
    rx_case("frames separated by exactly 40 bit times", [good_frame(rnd, 6) for _ in range(4)], rnd=rnd, inter=(40, 40.5))
    for e in (-0.02, 0.02):
        rx_case(f"sender baud error {e * 100:+.0f} %", [good_frame(rnd, 8) for _ in range(4)], rnd=rnd, err=e)
    rx_case("19200 baud", [good_frame(rnd, 6), good_frame(rnd, 3)], cpb=2604, rnd=rnd)


def phase_loop():
    print("Phase 3: engine 0 (TX) wired to engine 1 (RX) on pin 0")
    rnd = random.Random(23)
    pays = [payload(rnd, rnd.randrange(1, 20)) for _ in range(12)]
    htx = []
    for p in pays:
        htx += [len(p)] + list(p)
    exp = rx_expected([mp.frame_bytes(p) for p in pays])
    bit = 434 * 20
    dur = (sum(len(p) + 2 for p in pays) * 10 + len(pays) * 50) * bit
    L = pl.run("loopback", progs={0: mp.modbus_tx(434), 1: mp.modbus_rx(434, rx_pin=0)}, htx={0: htx}, dur_ns=dur)
    got = [w for _, w in L["B"]]
    errs = []
    if got != exp:
        k = next((i for i, (g, e) in enumerate(zip(got, exp)) if g != e), min(len(got), len(exp)))
        errs.append(f"RX words: {len(got)} vs {len(exp)} expected, first difference at #{k}")
    if L["END"].get("fault0", 0) or L["END"].get("fault1", 0) or L["END"].get("contend", 0):
        errs.append(f"END {L['END']}")
    report("TX engine -> RX engine, 12 frames, all CRCs good", errs, f"{len(pays)} frames {sum(len(p) + 2 for p in pays)} B")


def phase_mutants():
    print("Phase 4: broken firmware must be caught")
    rnd = random.Random(24)
    txp = [payload(rnd, n) for n in (4, 9)]
    good = [good_frame(rnd, n) for n in (6, 12, 5)]
    other = list(mp.CRC_CFG)
    tx_case("mutant TX: polynomial 0x8004", txp, prog=mp.modbus_tx(434, crc_cfg=[("POLY", 0x8004)] + other[1:]), expect="fail")
    tx_case("mutant TX: init 0x0000", txp, prog=mp.modbus_tx(434, crc_cfg=[other[0], ("INIT", 0)] + other[2:]), expect="fail")
    tx_case("mutant TX: no input reflection", txp, prog=mp.modbus_tx(434, crc_cfg=other[:3] + [("FMT", 0x4F)]), expect="fail")
    tx_case("mutant TX: CRC high byte first", txp, prog=mp.modbus_tx(434, swap_crc=True), expect="fail")
    tx_case("mutant TX: silence 2 characters", txp, prog=mp.modbus_tx(434, sil_scale=0.5), expect="fail")
    rx_case("mutant RX: polynomial 0x8004", good, prog=mp.modbus_rx(434, crc_cfg=[("POLY", 0x8004)] + other[1:]), expect="fail", rnd=rnd)
    rx_case("mutant RX: silence timeout 2x too long (frames merge)", good, prog=mp.modbus_rx(434, iters_scale=2.2), expect="fail", rnd=rnd)
    rx_case("mutant RX: silence timeout 3x too short (frames split)", good, prog=mp.modbus_rx(434, iters_scale=0.3), expect="fail", rnd=rnd, intra=(15, 16))
    rx_case("mutant RX: 3 bytes are enough (3-byte frame with a valid CRC)", [good_frame(rnd, 1)], prog=mp.modbus_rx(434, min_bytes=3), expect="fail", rnd=rnd)
    rx_case("mutant RX: init 0x0000", good, prog=mp.modbus_rx(434, crc_cfg=[other[0], ("INIT", 0)] + other[2:]), expect="fail", rnd=rnd)


def main():
    phases = sys.argv[1:] or ["tx", "rx", "loop", "mutants"]
    for p in phases:
        {"tx": phase_tx, "rx": phase_rx, "loop": phase_loop, "mutants": phase_mutants}[p]()
    bad = [n for n, ok in RESULTS if not ok]
    print(f"RESULT modbus_test: {'PASS' if not bad else 'FAIL'} ({len(RESULTS) - len(bad)}/{len(RESULTS)} cases as expected)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
