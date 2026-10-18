#!/usr/bin/env python3
"""SMBus with PEC: engine 0 = I2C master with CRC-8 PEC (i2c_prog.master_pec), engine 1 = I2C slave (i2c_prog.slave) at 0x4C, both on the
same open-drain bus in tb/tb_proto.v (pins 6 = SDA, 7 = SCL). The slave's read data and read PEC are supplied by the host from the
independent CRC model; the bus is decoded with the I2C rules (host/i2c_test.py decode + UM10204 timing) and every byte on the wire, the
master's result words and the slave's event words are compared with expectations built from crc_model.py.
  python host/smbus_test.py [basic speeds mutants]
"""
import random
import sys

import crc_model as cm
import i2c_prog as ip
import i2c_test as it
import proto_lib as pl

EV, EV_ADDR, EV_RACK, EV_STOP, EV_SR, EV_PEC = ip.EV, ip.EV_ADDR, ip.EV_RACK, ip.EV_STOP, ip.EV_SR, ip.EV_PEC
PW = ip.pec_word
ADDR = 0x4C
AW, AR = ADDR << 1, ADDR << 1 | 1
RESULTS = []


def pec(bs):
    return cm.make("CRC-8/SMBUS").of(bytes(bs))


def report(name, errs, stats, expect="pass"):
    ok = bool(errs) == (expect == "fail")
    tag = {"pass": "PASS" if ok else "FAIL", "fail": "DETECTED" if ok else "MISSED"}[expect]
    RESULTS.append((name, ok))
    print(f"  {tag:8s} {name:58s} {stats}")
    if not ok:
        for e in errs[:5] or ["no error was reported"]:
            print(f"           {e}")
    return ok


# ---- transactions: (master words, expected bus, slave TX bytes, expected slave events, expected master RX words)
def t_write(cmd_bytes):
    """Write Byte / Block Write: addr+W, cmd (and data bytes), PEC. cmd_bytes = everything after the address byte."""
    wire = [AW] + list(cmd_bytes)
    p = pec(wire)
    ws = [PW(AW << 1 | 1, s=1, c=1, crc_rst=1)] + [PW(b << 1 | 1, c=1) for b in cmd_bytes] + [PW(0 << 1 | 1, p=1, pec_send=1)]
    bus = [("S", [(b, 0) for b in wire + [p]], True)]
    ev = [EV_ADDR | AW] + list(cmd_bytes) + [p, EV_STOP]
    rx = [b << 1 for b in wire + [p]]
    return ws, bus, [], ev, rx


def t_read(cmd, nbytes, corrupt=None, count_byte=False):
    """Read Byte (nbytes = 1) / Block Read (count_byte: the first byte read is the count): S addr+W cmd Sr addr+R data.. PEC."""
    data = [random.randrange(256) for _ in range(nbytes)]
    if count_byte:
        data = [nbytes] + data
    wire = [AW, cmd, AR] + data
    good = pec(wire)
    p = good if corrupt is None else good ^ corrupt
    ws = [PW(AW << 1 | 1, s=1, c=1, crc_rst=1), PW(cmd << 1 | 1, c=1), PW(AR << 1 | 1, s=1, c=1)]
    ws += [PW(0xFF << 1 | 0) for _ in data] + [PW(0xFF << 1 | 1, p=1, pec_chk=1)]
    bus = [("S", [(AW, 0), (cmd, 0)], False), ("Sr", [(AR, 0)] + [(b, 0) for b in data] + [(p, 1)], True)]
    ev = [EV_ADDR | AW, cmd, EV_SR, EV_ADDR | AR] + [EV_RACK | 0 for _ in data] + [EV_RACK | 1, EV_STOP]
    rx = [AW << 1, cmd << 1, AR << 1] + [b << 1 for b in data] + [p << 1 | 1]
    if p != good:
        rx.append(EV_PEC)
    return ws, bus, data + [p], ev, rx


def run_case(name, txs, khz=400, master=None, slave=None, expect="pass", rise=1):
    words, bus_exp, stx, ev_exp, rx_exp = [], [], [], [], []
    for ws, bus, tx, ev, rx in txs:
        words += ws
        bus_exp += bus
        stx += tx
        ev_exp += ev
        rx_exp += rx
    nbytes = sum(len(b[1]) for b in bus_exp)
    bit_ns = 1e6 / khz
    dur = int(nbytes * 9.5 * bit_ns + len(txs) * 8 * bit_ns + 300_000)
    s = ip.SPEC[khz]
    L = pl.run(name, progs={0: master or ip.master_pec(khz), 1: slave or ip.slave()},
               htx={0: words, 1: [0x4C] + [0xA5A5A500 | b for b in stx]}, od=0xC0, dur_ns=dur,
               plus=dict(T0START_NS=40_000))
    P = [(t, f"{v >> 6 & 1}{v >> 7 & 1}") for t, v in L["P"]]
    trans, viol, T = it.decode(P)
    errs = viol[:4]
    it.compare(errs, "bus transactions", trans, bus_exp)
    it.compare(errs, "master result words", [w for _, w in L["A"]], rx_exp)
    it.compare(errs, "slave event words", [w for _, w in L["B"]], ev_exp)
    errs += it.timing_errors(T, khz)
    e = L["END"]
    for k in ("fault0", "fault1", "contend"):
        if e.get(k, 0):
            errs.append(f"{k}={e[k]}")
    return report(name, errs, f"{len(trans)} tr {nbytes} B | {it.tstats(T)}", expect)


def phase_basic():
    print("Phase 1: SMBus with PEC, engine master <-> engine slave (400 kHz)")
    rnd = random.Random(31)
    random.seed(31)
    run_case("Write Byte with PEC", [t_write([0x12, 0x34])])
    run_case("Write Byte with PEC, 20 random", [t_write([rnd.randrange(256), rnd.randrange(256)]) for _ in range(20)])
    run_case("Block Write with PEC, 1..32 data bytes",
             [t_write([rnd.randrange(256), n] + [rnd.randrange(256) for _ in range(n)]) for n in (1, 2, 7, 16, 32)])
    run_case("Read Byte with PEC (good PEC)", [t_read(0x21, 1)])
    run_case("Read Byte with PEC, 12 random", [t_read(rnd.randrange(256), 1) for _ in range(12)])
    run_case("Block Read with PEC (count byte + 5 data)", [t_read(0x30, 5, count_byte=True)])
    run_case("wrong PEC from the slave: master reports EV_PEC", [t_read(0x21, 1, corrupt=0x01)])
    run_case("wrong PEC (all 255 single-byte corruptions of the PEC would be caught)", [t_read(0x21, 1, corrupt=c) for c in (0x80, 0x55, 0xFF, 0x02)])
    run_case("one corrupted data byte in a block read is caught via the PEC",
             [t_read(0x30, 4, corrupt=0x40, count_byte=True)])
    run_case("mixed sequence", [t_write([1, 2]), t_read(5, 1), t_write([9, 3, 1, 2, 3]), t_read(7, 3, count_byte=True), t_write([4, 4])])


def phase_speeds():
    print("Phase 2: speeds")
    rnd = random.Random(32)
    random.seed(32)
    for khz in (100, 400, 1000):
        run_case(f"{khz} kHz mixed sequence", [t_write([rnd.randrange(256), rnd.randrange(256)]), t_read(rnd.randrange(256), 1),
                                              t_write([3, 4, 9, 8, 7, 6]), t_read(0x11, 3, count_byte=True)], khz=khz)
        run_case(f"{khz} kHz rise {ip.SPEC[khz]['rise']} ns", [t_write([1, 2]), t_read(0x44, 1)], khz=khz, rise=ip.SPEC[khz]["rise"])


def phase_mutants():
    print("Phase 3: broken firmware must be caught")
    random.seed(33)
    seq = [t_write([0x12, 0x34]), t_read(0x21, 1), t_write([9, 2, 7, 8]), t_read(0x30, 3, count_byte=True)]
    base = (("POLY", 7), ("INIT", 0), ("XOR", 0), ("FMT", 7))
    run_case("mutant: polynomial 0x31", seq, master=ip.master_pec(400, cfg=(("POLY", 0x31),) + base[1:]), expect="fail")
    run_case("mutant: init 0xFF", seq, master=ip.master_pec(400, cfg=base[:1] + (("INIT", 0xFF),) + base[2:]), expect="fail")
    run_case("mutant: reflected input", seq, master=ip.master_pec(400, cfg=base[:3] + (("FMT", 0x27),)), expect="fail")
    run_case("mutant: PEC byte not replaced by the CRC", seq, master=ip.master_pec(400, mut=("no_send",)), expect="fail")
    run_case("mutant: CRC not reset at START", seq, master=ip.master_pec(400, mut=("no_rst",)), expect="fail")
    run_case("mutant: bytes not fed to the CRC", seq, master=ip.master_pec(400, mut=("no_feed",)), expect="fail")
    bad = [t_read(0x21, 1, corrupt=0x10)]
    run_case("mutant: PEC check never reports", bad, master=ip.master_pec(400, mut=("no_check",)), expect="fail")


def main():
    phases = sys.argv[1:] or ["basic", "speeds", "mutants"]
    for p in phases:
        {"basic": phase_basic, "speeds": phase_speeds, "mutants": phase_mutants}[p]()
    bad = [n for n, ok in RESULTS if not ok]
    print(f"RESULT smbus_test: {'PASS' if not bad else 'FAIL'} ({len(RESULTS) - len(bad)}/{len(RESULTS)} cases as expected)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
