#!/usr/bin/env python3
"""I2C slave verification: the engine runs host/i2c_prog.py slave(); the Verilog master model (written from the I2C specification,
tb/tb_i2c_engine.v ROLE=1) drives the bus; the bus log is decoded with the I2C rules only (host/i2c_test.py decode + UM10204 minimum
timings); the expected bus, the master's read data and the engine's event words come from an independent model of the slave's
documented behaviour (expect_s below), not from the firmware.

  python host/i2c_slave_test.py [selftest basic speeds flow mutants]
"""
import random
import sys

import i2c_prog as ip
import i2c_test as it
import mutation  # noqa: F401  (kept for symmetry with the other test drivers)

EV, EV_ADDR, EV_RACK, EV_STOP, EV_SR = ip.EV, ip.EV_ADDR, ip.EV_RACK, ip.EV_STOP, ip.EV_SR
W, T = ip.transaction, ip.word


class Eng:
    """Documented behaviour of the engine slave (i2c_prog.py header), as a model."""

    def __init__(self, addr, read_bytes=()):
        self.addr, self.tx, self.active = addr, list(read_bytes), False
        self.events = []


def expect_s(words, slaves, eng):
    """Like i2c_test.expect, plus the engine slave. Returns (bus, master_rx_words, engine_rx_words)."""
    bus, rx = [], []
    cur, opened, skip, first = None, False, False, False
    act, rw, nbyte, m_ack = None, 0, 0, True
    for w in words:
        S, slot, C, P = w >> 31 & 1, w >> 22 & 0x1FF, w >> 21 & 1, w >> 20 & 1
        if not S and (skip or not opened):
            continue
        skip = False
        if S:
            if opened and eng.active:
                eng.events.append(EV_SR)
                eng.active = False
            cur = ["Sr" if opened else "S", [], False]
            bus.append(cur)
            opened, first = True, True
        out, ack_out = slot >> 1, slot & 1
        if first:
            first, byte = False, out
            act = next((s for s in slaves if s.en and s.addr == byte >> 1), None)
            if act is None and eng.addr == byte >> 1:
                act = "ENG"
                eng.active = True
                eng.events.append(EV_ADDR | byte)
            rw, nbyte, m_ack = byte & 1, 0, True
            ack = ack_out & (0 if act else 1)
        elif act == "ENG" and rw == 0:
            byte, ack = out, 0
            eng.events.append(byte)
        elif act == "ENG" and rw == 1 and m_ack:
            byte = out & eng.tx.pop(0)
            ack = ack_out
            m_ack = ack_out == 0
            eng.events.append(EV_RACK | ack_out)
        elif act and act != "ENG" and rw == 0:
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
        elif act and act != "ENG" and rw == 1 and m_ack:
            byte = out & act.mem[act.ptr]
            act.ptr = (act.ptr + 1) & 255
            ack = ack_out
            m_ack = ack_out == 0
        else:
            byte, ack = out, ack_out
        rx.append(byte << 1 | ack)
        cur[1].append((byte, ack))
        if C and ack:
            cur[2], opened, skip = True, False, True
            rx.append(it.EV_NACK)
            eng.active = False
        elif P:
            cur[2], opened = True, False
            if eng.active:
                eng.events.append(EV_STOP)
                eng.active = False
    return [tuple(b) for b in bus], rx, eng.events


MLOW = {100: (5200, 4900), 400: (1500, 1050), 1000: (650, 400)}   # master model phases (ns): period above the nominal one


def scenario(name, txs, addr=0x2A, reads=(), khz=400, expect="pass", rise=1, prog=None, spec=True, s2=False, **plus):
    """txs: master transactions (word lists); reads: bytes the host supplies for the master's reads."""
    words = [w for t in txs for w in t]
    eng = Eng(addr, reads)
    slaves = [it.Slave(0x50), it.Slave(0x23, en=s2)]
    stx = [ip.slave_cfg_word(addr)] + [(0xA5A5A500 | b) ^ (0x5A5A5A00 if i & 1 else 0) for i, b in enumerate(reads)]
    bus_exp, rx_exp, ev_exp = expect_s(words, slaves, eng)
    lo, hi = MLOW[khz]
    args = dict(ROLE=1, N=len(words), NS=len(stx), S2EN=int(s2), TMAX=2_000_000, M_LOW_NS=lo, M_HIGH_NS=hi)
    args.update({k.upper(): v for k, v in plus.items()})
    L = it.run_sim("tb_i2c_engine", name, {"HTX": words, "STX": stx, "PROG": prog or ip.slave()}, args, rise)
    trans, viol, Tm = it.decode(L["P"])
    errs = viol[:4]
    it.compare(errs, "bus transactions", trans, bus_exp)
    it.compare(errs, "master read words", L["R"], rx_exp)
    it.compare(errs, "slave event/data words", L["S"], ev_exp)
    if L["MEM"].get(1) != slaves[0].mem:
        errs.append("model slave 0x50 memory differs from the expectation")
    if spec:
        errs += it.timing_errors(Tm, khz)
    e = L["END"]
    for k in ("fault", "drive_high", "viol", "timeout"):
        if e.get(k, "0") != "0":
            errs.append(f"{k}={e[k]}")
    nb = sum(len(b) for _, b, _ in trans)
    return it.report(name, errs, f"{len(trans)} tr {nb} B {len(ev_exp)} ev | {it.tstats(Tm)}", expect)


def basic_txs(rng, addr=0x2A, n_rand=3):
    """(transactions, bytes the master will read from the engine, in order)."""
    txs, reads = [], []

    def rd(n):
        b = [rng.randrange(256) for _ in range(n)]
        reads.extend(b)
        return W(addr, rd=n, stop=True)

    txs.append(W(addr, [0x11]))
    txs.append(W(addr, [1, 2, 3, 4, 5]))
    txs.append(W(addr, [rng.randrange(256) for _ in range(16)]))
    txs.append(rd(1))
    txs.append(rd(3))
    txs.append(rd(8))
    reads.extend(rng.randrange(256) for _ in range(2))
    txs.append(W(addr, [0x40], stop=False) + W(addr, rd=2))                  # write pointer, Sr, read
    txs.append(W(0x50, [0x10, 0xAA, 0xBB]))                                  # another slave on the bus: engine silent
    for b in range(7):                                                       # every single-bit-different address: not ours
        txs.append(W(addr ^ (1 << b), [0x70 + b, 0x88]))
    txs.append(W(addr ^ 0x40, rd=2))                                         # not ours, read direction
    txs.append(W(addr, [0x01, 0x02]))
    for _ in range(n_rand):
        k = rng.randrange(3)
        if k == 0:
            txs.append(W(addr, [rng.randrange(256) for _ in range(rng.randrange(1, 7))]))
        elif k == 1:
            n = rng.randrange(1, 6)
            reads.extend(rng.randrange(256) for _ in range(n))
            txs.append(W(addr, rd=n))
        else:
            n = rng.randrange(1, 4)
            reads.extend(rng.randrange(256) for _ in range(n))
            txs.append(W(addr, [rng.randrange(256)], stop=False) + W(addr, rd=n))
    return txs, reads


def fix_reads(txs, addr):
    """The read bytes must be the host's list in order: rebuild it from the transactions (count of read words)."""
    return None


def phase_basic():
    print("Phase 1: engine = I2C slave at 400 kHz, Verilog master model, model slave 0x50 on the same bus")
    rng = random.Random(11)
    # each scenario supplies exactly as many read bytes as the master reads
    def count_reads(txs):
        return sum(1 for t in txs for w in t[1:] if False) or sum(
            1 for t in txs for w in t if (w >> 22 & 0x1FF) == 0x1FE or (w >> 22 & 0x1FF) == 0x1FF)

    cases = [
        ("write 1 byte", [W(0x2A, [0x5A])], []),
        ("write 16 bytes", [W(0x2A, list(range(16)))], []),
        ("read 1 byte", [W(0x2A, rd=1)], [0xC3]),
        ("read 8 bytes", [W(0x2A, rd=8)], [0x81, 0x7E, 0x00, 0xFF, 0x55, 0xAA, 0x0F, 0xF0]),
        ("write pointer, repeated START, read", [W(0x2A, [0x40], stop=False) + W(0x2A, rd=3)], [1, 2, 3]),
        ("address only (no data) then STOP", [W(0x2A, [])], []),
        ("read after write, two transactions", [W(0x2A, [9, 8]), W(0x2A, rd=2)], [0xDE, 0xAD]),
        ("not our address: neighbour 0x28", [W(0x28, [1, 2, 3]), W(0x28, rd=2)], []),
        ("our address then the model slave 0x50", [W(0x2A, [1]), W(0x50, [0x10, 7, 8]), W(0x2A, [2])], []),
        ("two repeated STARTs in a row", [W(0x2A, [5], stop=False) + W(0x2A, [6], stop=False) + W(0x2A, rd=1)], [0x99]),
    ]
    for name, txs, reads in cases:
        scenario(name, txs, reads=reads, spec=True)
    txs, reads = basic_txs(rng)
    scenario("mixed set (writes, reads, Sr, other addresses)", txs, reads=reads)
    for addr in (0x01, 0x2A, 0x55, 0x7E, 0x7F):
        scenario(f"address 0x{addr:02X}: ours and 0x{addr ^ 1:02X}", [W(addr, [3, 4]), W(addr ^ 1, [5]), W(addr, rd=2)],
                 addr=addr, reads=[0x12, 0x34])


def phase_speeds():
    print("Phase 2: speeds, rise times")
    rng = random.Random(12)
    for khz in (100, 400, 1000):
        txs, reads = basic_txs(rng, n_rand=4)
        scenario(f"{khz} kHz mixed set", txs, reads=reads, khz=khz)
        txs, reads = basic_txs(rng, n_rand=2)
        scenario(f"{khz} kHz mixed set, rise {ip.SPEC[khz]['rise']} ns (spec max)", txs, reads=reads, khz=khz,
                 rise=ip.SPEC[khz]["rise"])
    for khz in (400, 1000):
        r = random.Random(khz)
        txs, reads = [], []
        while sum(len(t) for t in txs) < 400:
            k = r.randrange(3)
            if k == 0:
                txs.append(W(0x2A, [r.randrange(256) for _ in range(r.randrange(1, 12))]))
            elif k == 1:
                n = r.randrange(1, 10)
                reads.extend(r.randrange(256) for _ in range(n))
                txs.append(W(0x2A, rd=n))
            else:
                n = r.randrange(1, 6)
                reads.extend(r.randrange(256) for _ in range(n))
                txs.append(W(0x2A, [r.randrange(256)], stop=False) + W(0x2A, rd=n))
        scenario(f"{khz} kHz random stress ({sum(len(t) for t in txs)} words)", txs, reads=reads, khz=khz)


def phase_flow():
    print("Phase 3: flow control by clock stretching")
    rng = random.Random(13)
    big = [W(0x2A, [rng.randrange(256) for _ in range(14)])]
    scenario("RX not drained for 1 ms (14 bytes > 4-word FIFO: SCL held low)", big, rxoff_ns=1_000_000, spec=False)
    scenario("RX not drained for 1 ms, 1 MHz", big, khz=1000, rxoff_ns=1_000_000, spec=False)
    txs = [W(0x2A, rd=6)]
    reads = [rng.randrange(256) for _ in range(6)]
    scenario("TX words 50 us apart (slave stretches SCL for each read byte)", txs, reads=reads, stxgap_ns=50_000, spec=False)
    scenario("TX first word 300 us late", txs, reads=reads, stxlate_ns=300_000, spec=False)
    scenario("TX words 20 us apart at 1 MHz", txs, reads=reads, khz=1000, stxgap_ns=20_000, spec=False)


def phase_mutants():
    print("Phase 4: broken slave firmware must be caught")
    import asm as A
    base = ip.slave()
    dis = [A.disasm(w) for w in base]
    NOP = A.word("NOP")

    def edit(idx, expect_text, new_word):
        assert dis[idx] == expect_text, f"slave program changed: word {idx} is '{dis[idx]}', expected '{expect_text}'"
        ws = list(base)
        ws[idx] = new_word
        return ws

    # every single-bit-different address is not ours
    mixed = [W(0x2A, [0x11, 0x22, 0x33])] + [W(0x2A ^ (1 << b), [0x44 + b]) for b in range(7)] + \
            [W(0x2A, rd=3), W(0x2A, [0x40], stop=False) + W(0x2A, rd=2), W(0x2A, [0x55])]
    mixed_reads = [0x81, 0x42, 0xA6, 0x5B, 0xE0]
    flow = [W(0x2A, list(range(1, 13)))]
    cases = [
        ("address compare ignores bit 1 (mask 0xFC)", edit(44, "ALU AND r5,#254", A.enc_alu("AND", 5, imm=0xFC)), mixed, mixed_reads, {}),
        ("address ACK missing", edit(47, "SETLO 6", NOP), mixed, mixed_reads, {}),
        ("write-data ACK missing", edit(73, "SETLO 6", NOP), mixed, mixed_reads, {}),
        ("read data sent LSB first (OSR bit order)", edit(0, "CFG 246", A.word("CFG", 6 | 6 << 3 | 0 << 6 | 1 << 7)), mixed, mixed_reads, {}),
        ("write data not pushed to the host", edit(75, "RPUT RXF,r1", NOP), mixed, mixed_reads, {}),
        ("STOP event missing", edit(20, f"PUSHI {EV_STOP}", NOP), mixed, mixed_reads, {}),
        ("repeated START event missing", edit(25, f"PUSHI {EV_SR}", NOP), mixed, mixed_reads, {}),
        ("master NACK recognised with inverted polarity", edit(98, "JPH pin6,103", A.word("JPL", 6 << 8 | 103)), mixed, mixed_reads, {}),
        ("no SCL hold after a write byte (flow control gone)", edit(72, "SETLO 7", NOP), flow, [], dict(rxoff_ns=300_000)),
        ("session flag never set (no events at the end)", edit(48, "LDI r3,#0x1", A.enc_ldi(3, 0)), mixed, mixed_reads, {}),
        ("read bits 6..0 not driven", edit(92, "OUT1 0", NOP), mixed, mixed_reads, {}),
        ("SDA not released after the address ACK clock", edit(58, "SETH 6", NOP), mixed, mixed_reads, {}),
        ("SDA not released before the master's ACK slot", edit(96, "SETH 6", NOP), mixed, mixed_reads, {}),
        ("read/write bit tested on the wrong bit", edit(53, "ALU TST r1,#1", A.enc_alu("TST", 1, imm=2)), mixed, mixed_reads, {}),
        ("TX word not fetched for a read byte", edit(84, "RGET r4,TXF", NOP), mixed, mixed_reads, {}),
        ("read byte aligned one bit low", edit(85, "ALU SHL r4,#24", A.enc_alu("SHL", 4, imm=23)), mixed, mixed_reads, {}),
    ]
    for name, prog, txs, reads, extra in cases:
        scenario(f"mutant: {name}", txs, reads=reads, prog=prog, expect="fail", **extra)


def main():
    phases = sys.argv[1:] or ["basic", "speeds", "flow", "mutants"]
    for p in phases:
        {"basic": phase_basic, "speeds": phase_speeds, "flow": phase_flow, "mutants": phase_mutants}[p]()
    bad = [n for n, ok in it.RESULTS if not ok]
    print(f"RESULT i2c_slave_test: {'PASS' if not bad else 'FAIL'} ({len(it.RESULTS) - len(bad)}/{len(it.RESULTS)} cases as expected)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
