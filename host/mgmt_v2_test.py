#!/usr/bin/env python3
"""Management frame v2 (CRC-16, sequence numbers, pipelined results, exactly-once retry) on the chip RTL through the SPI bridge.
  python3 host/mgmt_v2_test.py [--flips N]

What is proved here (docs/HOST_INTERFACE.md section 10):
  * identification and scratch registers, walking-bit echo; v1 frames keep working next to v2
  * a damaged frame never executes: single-bit and multi-bit flips anywhere in the 96 request bits, truncated and over-long frames, a frame cut mid-byte
  * exactly once: the identical frame sent again (the response was lost) runs the command once and shows the same older result; a gap in the
    numbering and a reused number with other content are refused; a NOP never changes anything
  * every result code, with and without a result being fetched through NOPs
  * real use: program loaded, started and a FIFO stream moved with v2 only (pipelined, one frame per word)
Prints one RESULT line.
"""
import argparse
import os
import random
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asm as A
from chip_host import (CAP_ADDR, ENG_BASE, ERRCNT_ADDR, HostError, ChipHost, ID_ADDR, OP2_NOP, OP2_READ, OP2_WRITE, Result, SCRATCH_ADDR,
                       SimLink, VERSION_ADDR, crc16)

checks = fails = 0


def check(cond, msg):
    global checks, fails
    checks += 1
    if not cond:
        fails += 1
        print(f"  FAIL  {msg}")
    return cond


def echo_plus_one():
    a = A.Asm()
    a.label("loop")
    a.PULL()
    a.RGET(1, "OSR")
    a.ALU("ADD", 1, imm=1)
    a.RPUT("ISR", 1)
    a.PUSH()
    a.JMP("loop")
    return a.words()


def drain(chip):
    """Pop RX words with v2 until the FIFO reports BUSY (empty)."""
    out = []
    while True:
        r = chip.cmd2(OP2_READ, ENG_BASE[0] + 0x204)
        if r.code == 1:
            return out
        out.append(r.data)


def errcnt(chip):
    v = chip.read2(ERRCNT_ADDR)
    return v & 0xFF, v >> 8 & 0xFF, v >> 16 & 0xFF          # CRC, length, sequence


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--flips", type=int, default=200)
    args = ap.parse_args()
    rnd = random.Random(5)
    link = SimLink()
    chip = ChipHost(link)

    print("--- identification, scratch, v1 next to v2")
    check(chip.read2(ID_ADDR) == 0x50454D31, "ID register reads 'PEM1'")
    check(chip.read2(VERSION_ADDR) >> 8 & 0xFF == 2, "VERSION: frame versions up to 2")
    cap = chip.read2(CAP_ADDR)
    check(cap & 0xFF == 2 and cap >> 8 & 0xFFFF == 256 and cap >> 28 == 4, f"CAPABILITY 0x{cap:08X}: 2 engines, 256 words, FIFO depth 4")
    for i in range(32):
        chip.write2(SCRATCH_ADDR, 1 << i)
        if chip.read2(SCRATCH_ADDR) != 1 << i:
            check(False, f"scratch walking bit {i}")
            break
    else:
        check(True, "scratch register: walking-one echo, 32 bits")
    chip.write2(SCRATCH_ADDR, 0xA5A5A5A5)
    check(chip.read(SCRATCH_ADDR) == 0xA5A5A5A5, "a v1 frame reads what a v2 frame wrote (v1 still works)")
    chip.write(SCRATCH_ADDR, 0x12345678)
    check(chip.read2(SCRATCH_ADDR) == 0x12345678, "a v1 frame writes, a v2 frame reads")
    check(errcnt(chip) == (0, 0, 0), "no errors counted so far")

    print("--- damaged frames never execute")
    chip.write2(SCRATCH_ADDR, 0xC0FFEE00)
    base_seq = chip.cmd_seq
    n_crc = n_v1 = 0
    seq = chip.new_seq2()
    good = ChipHost.frame2_bytes(OP2_WRITE, seq, SCRATCH_ADDR, 0xDEADBEEF)
    for k in range(args.flips):                          # 1 to 3 bit flips anywhere in the 96 bits
        bits = rnd.sample(range(96), rnd.choice([1, 1, 1, 2, 3]))
        bad = int.from_bytes(good, "big")
        for b in bits:
            bad ^= 1 << b
        r = chip.exchange2(bad.to_bytes(12, "big"))
        # bit 95 is bit 7 of the first byte: it selects frame v1. A damaged request with it flipped is a 12-byte v1 frame: it never
        # executes (checked below), is answered in the v1 format (no CRC) and is not counted as a v2 CRC error.
        if 95 in bits:
            n_v1 += 1
        else:
            check(r.crc_ok, f"the chip's own answer to a damaged request is intact (bits flipped: {sorted(bits)})")
            n_crc += 1
    r = chip.exchange2(chip.nop2())
    check(chip.read2(SCRATCH_ADDR) == 0xC0FFEE00, f"scratch untouched by {args.flips} damaged write frames ({n_v1} of them looked like v1)")
    c = errcnt(chip)
    check(c[0] == n_crc, f"CRC error counter = {c[0]} (sent {n_crc} v2-looking damaged frames; the {n_v1} v1-looking ones are not counted)")
    chip.write2(ERRCNT_ADDR, 0)
    check(errcnt(chip) == (0, 0, 0), "any write to ERRCNT clears the counters")
    # truncated / over-long / cut mid-byte
    f = int.from_bytes(ChipHost.frame2_bytes(OP2_WRITE, chip.new_seq2(), SCRATCH_ADDR, 0xBADBAD00), "big")
    link.transfer_bits(88, f >> 8)                       # 11 bytes
    link.transfer_bits(90, f >> 6)                       # 11 bytes and 2 bits
    link.transfer_bits(104, f << 8)                      # 13 bytes
    link.transfer_bits(8, 0x81)                          # a first byte only
    check(chip.read2(SCRATCH_ADDR) == 0xC0FFEE00, "truncated, over-long and cut frames change nothing")
    c = errcnt(chip)
    check(c[1] == 4, f"length error counter = {c[1]} (sent 4)")
    check(chip.status().err, "the sticky err flag is set by damaged frames")
    chip.clear_err()

    print("--- exactly once: retry, gap, conflict, NOP")
    chip.load_program(0, echo_plus_one())
    chip.run(0)
    seq = chip.new_seq2()
    push = ChipHost.frame2_bytes(OP2_WRITE, seq, ENG_BASE[0] + 0x200, 100)
    chip.cmd_seq = seq
    chip.exchange2(push)
    chip.exchange2(push)                                 # the response was "lost": the identical frame again
    chip.exchange2(push)                                 # and once more
    for _ in range(40):
        link.wait(50)
    r = chip.fetch2(seq)
    check(r is not None and r.code == 0, "the pushed word is acknowledged")
    link.wait(3000)
    got = drain(chip)
    check(got == [101], f"a push frame sent three times runs once: the echo engine returns {got}")
    # lost response of a pop: the identical frame again must not pop twice
    chip.write2(ENG_BASE[0] + 0x200, 20)
    chip.write2(ENG_BASE[0] + 0x200, 30)
    link.wait(4000)
    chip.write2(SCRATCH_ADDR, 0x600DF00D)
    seq_s = chip.new_seq2()
    chip.cmd_seq = seq_s
    chip.exchange2(ChipHost.frame2_bytes(OP2_READ, seq_s, SCRATCH_ADDR))      # its result (0x600DF00D) is not fetched yet
    seq = chip.new_seq2()
    pop = ChipHost.frame2_bytes(OP2_READ, seq, ENG_BASE[0] + 0x204)
    chip.cmd_seq = seq
    r_a = chip.exchange2(pop)                            # accepted; its answer shows the previous result (the scratch read)
    r_b = chip.exchange2(pop)                            # "lost": sent again
    check(r_a.seq == seq_s and r_a.data == 0x600DF00D, f"a frame shows the previous command's result: {r_a}")
    check((r_b.seq, r_b.code, r_b.addr, r_b.data) == (r_a.seq, r_a.code, r_a.addr, r_a.data), "the retried frame shows the same older result again, data included (the response can be recovered)")
    check(r_b.last_seq == seq, "MISO byte 1 reports the last accepted command's seq")
    r_c = chip.fetch2(seq)
    check(r_c is not None and r_c.data == 21, f"the pop ran once and returned 21 (got {r_c.data if r_c else None})")
    r_n = chip.exchange2(chip.nop2())
    check(r_n.seq == seq and r_n.data == 21, "NOPs show the result again and again without changing anything")
    check(chip.read2(ENG_BASE[0] + 0x204) == 31, "the next pop returns 31: nothing was popped twice")
    # gap and conflict
    chip.write2(SCRATCH_ADDR, 0x11111111)
    before = errcnt(chip)
    chip.cmd_seq = (chip.cmd_seq + 1) & 0xFF             # skip one number: the chip must refuse
    gap = ChipHost.frame2_bytes(OP2_WRITE, (chip.cmd_seq + 1) & 0xFF, SCRATCH_ADDR, 0x22222222)
    chip.exchange2(gap)
    chip.exchange2(chip.nop2())
    chip.resync2()
    check(chip.read2(SCRATCH_ADDR) == 0x11111111, "a command with a gap in the numbering is refused (nothing can overtake a lost frame)")
    check(errcnt(chip)[2] == before[2] + 1, "the sequence-error counter counts the gap")
    last = chip.cmd_seq
    conflict = ChipHost.frame2_bytes(OP2_WRITE, last, SCRATCH_ADDR, 0x33333333)      # same seq, other content
    chip.exchange2(conflict)
    check(chip.read2(SCRATCH_ADDR) == 0x11111111, "the same number with other content is refused")
    check(errcnt(chip)[2] >= before[2] + 2, "and counted")
    chip.write2(ERRCNT_ADDR, 0)
    check(errcnt(chip) == (0, 0, 0), "a write to ERRCNT clears the sequence counter too")
    check(chip.status().err, "refused frames set the sticky err flag")
    chip.clear_err()

    print("--- result codes")
    codes = [
        ("write to an unmapped address", chip.cmd2(OP2_WRITE, 0x0F00, 1).code, 2),
        ("read from an unmapped address", chip.cmd2(OP2_READ, 0x3000).code, 2),
        ("write to the read-only ID register", chip.cmd2(OP2_WRITE, ID_ADDR, 1).code, 4),
        ("CTRL write with reserved bits", chip.cmd2(OP2_WRITE, ENG_BASE[1], 2).code, 3),
        ("instruction write to a running engine", chip.cmd2(OP2_WRITE, ENG_BASE[0] + 0x400, 0).code, 4),
    ]
    for name, got, want in codes:
        check(got == want, f"{name}: code {got} (expected {want})")
    raw_bad_op = ChipHost.frame2_bytes(0x83, chip.new_seq2(), 0, 0)
    chip.cmd_seq = raw_bad_op[1]
    chip.exchange2(raw_bad_op)
    r = chip.fetch2(raw_bad_op[1])
    check(r is not None and r.code == 6, "an unknown op: code 6")
    rs = ChipHost.frame2_bytes(OP2_WRITE, chip.new_seq2(), SCRATCH_ADDR, 5, rsv=1)
    chip.cmd_seq = rs[1]
    chip.exchange2(rs)
    r = chip.fetch2(rs[1])
    check(r is not None and r.code == 3 and chip.read2(SCRATCH_ADDR) == 0x11111111, "nonzero reserved bytes: code 3, nothing written")
    chip.stop(0)
    # RX empty / TX full give BUSY and do nothing
    while chip.pop_rx(0) is not None:
        pass
    r = chip.cmd2(OP2_READ, ENG_BASE[0] + 0x204)
    check(r.code == 1 and r.data == 0, "pop from an empty RX FIFO: BUSY")
    for i in range(4):
        chip.write2(ENG_BASE[0] + 0x200, i)
    r = chip.cmd2(OP2_WRITE, ENG_BASE[0] + 0x200, 99)
    check(r.code == 1, "push into a full TX FIFO: BUSY (the host just sends it again later)")

    print("--- real use: program, run and a FIFO stream with v2 frames")
    chip.reset()
    chip = ChipHost(link)
    words = echo_plus_one()
    cmds = [(OP2_WRITE, ENG_BASE[0] + 0x400 + 4 * i, w) for i, w in enumerate(words)]
    res = chip.pipeline2(cmds + [(OP2_WRITE, ENG_BASE[0], 1)])
    check(all(r.code == 0 for r in res), "instruction words written and RUN set with pipelined frames")
    frames_before = chip.frames
    stream = list(range(1000, 1012))
    out = []
    pending = list(stream)
    for _ in range(400):
        if len(out) == len(stream):
            break
        batch = [(OP2_WRITE, ENG_BASE[0] + 0x200, w) for w in pending[:2]] + [(OP2_READ, ENG_BASE[0] + 0x204, 0)] * 2
        rs = chip.pipeline2(batch)
        sent = 0
        for (op, a, d), r in zip(batch, rs):
            if op == OP2_WRITE and r.code == 0:
                sent += 1
            elif op == OP2_READ and r.code == 0:
                out.append(r.data)
        pending = pending[sent:]
    check(out == [w + 1 for w in stream], f"12 words through the echo engine in order: {out[:6]}...")
    print(f"      {chip.frames - frames_before} frames for the stream")

    link.close()
    print(f"{checks} checks, {fails} failed")
    print(f"RESULT mgmt_v2_test: {'PASS' if not fails else 'FAIL'} ({checks - fails}/{checks} checks)")
    return 1 if fails else 0


if __name__ == "__main__":
    try:
        rc = main()
    except HostError as e:
        print(f"  FAIL  {e}")
        print("RESULT mgmt_v2_test: FAIL (exception)")
        rc = 1
    sys.exit(rc)
