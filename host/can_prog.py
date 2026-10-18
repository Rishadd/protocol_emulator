#!/usr/bin/env python3
"""CAN 2.0A (11-bit identifier, data frames) for the engine: bit stuffing and bit timing with the ALU, CRC-15 with the CRC unit,
sample points with WAITR. The bus is one open-drain pin (pin 0): 0 = dominant, 1 = recessive. cpb = clocks per bit (100 = 500 kbit/s).

  can_tx(cpb)  Host TX words per frame:  word 0 = {dlc[15:12], id[10:0]}, then ceil(min(dlc, 8) / 4) data words, data byte 0 in [31:24].
               The engine waits for 3 recessive bit times (intermission), sends SOF .. CRC with stuffing, releases the bus for the CRC
               delimiter, samples the ACK slot and idles through EOF. RX word: EV | ack (ack = 1 when a receiver pulled the ACK slot dominant).
               No arbitration, no error frames: a single talker on the bus.
  can_rx(cpb)  Receives data frames. For every frame it pushes
                 [header]  EV | dlc << 12 | id                       (only when SOF .. DLC were received without error)
                 [data]    ceil(min(dlc, 8) / 4) words, byte 0 in [31:24], a partial last word is left aligned
                 status    EV | 1 << 25 | err << 4 | ok              err: 0 none, 1 stuff error, 2 CRC error, 3 form error
                                                                      (dominant delimiter / ACK delimiter / EOF bit), 4 unsupported (RTR or IDE)
               and drives the ACK slot dominant when the CRC and the delimiters are fine. The receiver hard-synchronises on SOF only (no
               resynchronisation), so it tolerates a sender clock error of about +-0.3 %.
Every iteration of the bit loops is padded to exactly `cpb` clocks: the padding (a WAITR per exit) is computed with Asm.arrivals,
the static cycle analysis in asm.py.
"""
import argparse

from asm import Asm, disasm

EV = 1 << 26
CRC_CAN = [("POLY", 0x4599), ("INIT", 0), ("XOR", 0), ("FMT", 14)]       # CRC-15/CAN: width 15, no reflection


class _Unreachable(Exception):
    pass


def _solve(build, fix, rounds=6):
    K = {n: 0 for n in fix}
    a = build(K)
    for _ in range(rounds):
        cache = {}

        def at(start, label, a=a, cache=cache):
            if start not in cache:
                cache[start] = a.arrivals(start)
            s = cache[start].get(a.labels[label])
            if not s:
                raise _Unreachable(label)                              # code a mutant never reaches: its constant does not matter
            assert len(s) == 1, f"arrival of '{label}' from '{start}' is not unique: {s}"
            return next(iter(s))
        new = {}
        for n, f in fix.items():
            try:
                new[n] = f(at)
            except _Unreachable:
                new[n] = 0
        for n, v in new.items():
            assert v >= 0, f"{n}: negative wait {v}"
        if new == K:
            return a
        K = new
        a = build(K)
    raise AssertionError("timing constants did not converge")


def can_tx(cpb=100, pin=0, mut=(), crc_cfg=None):
    assert pin == 0
    B = cpb
    stuff_n = 4 if "stuff4" in mut else 5
    exits = ("x_std1", "x_std2", "x_d1", "x_d2", "x_crc")

    def build(K):
        a = Asm()
        a.SETH(pin); a.DIRO(pin)
        for op, v in (crc_cfg or CRC_CAN):
            a.LDI(2, v); a.CRC(op, 2)
        a.label("cmd")
        a.RGET(0, "TXF")                                                  # {dlc, id}
        a.LDI(4, B)
        a.label("idle"); a.LDI(4, B)                                      # 3 recessive bit times: 3 clocks per poll
        a.label("poll"); a.JPL(pin, "idle"); a.ALU("SUB", 4, imm=1); a.JCC("NZ", "poll")
        # header bits: SOF(0) id[10:0] RTR(0) IDE(0) r0(0) dlc[3:0], left aligned in R3
        a.ALU("MOV", 3, rs=0); a.ALU("AND", 3, imm=0x7FF); a.ALU("SHL", 3, imm=7)
        a.ALU("MOV", 1, rs=0); a.ALU("SHR", 1, imm=12); a.ALU("AND", 1, imm=15); a.ALU("OR", 3, rs=1); a.ALU("SHL", 3, imm=13)
        if "dlc_raw" not in mut:
            a.ALU("CMP", 1, imm=8); a.JCC("NC", "lt8"); a.LDI(1, 8)
        a.label("lt8")
        a.ALU("MOV", 2, rs=1); a.ALU("SHL", 2, imm=3); a.ALU("ADD", 2, imm=34)       # R2 = 19 + 8 * bytes + 15 bits to send
        a.LDI(4, 19); a.CRC("RST"); a.LDI(5, 1); a.LDI(6, 0)
        # ---- one bus bit per iteration
        a.label("top")
        a.ALU("CMP", 6, imm=stuff_n); a.JCC("Z", "stuff")
        a.ALU("SHL", 3, imm=1); a.JCC("C", "one"); a.LDI(1, 0); a.JMP("got")
        a.label("one"); a.LDI(1, 1); a.NOP()
        a.label("got")
        a.CRC("BIT", 1); a.ALU("SUB", 4, imm=1); a.ALU("SUB", 2, imm=1)
        a.ALU("CMP", 1, rs=5); a.JCC("Z", "same"); a.LDI(6, 1); a.ALU("MOV", 5, rs=1); a.JMP("emit")
        a.label("same"); a.ALU("ADD", 6, imm=1); a.NOP(); a.NOP()
        a.label("emit")
        a.ALU("TST", 1, imm=1); a.JCC("Z", "dom"); a.label("c_rec"); a.SETH(pin); a.JMP("post")
        a.label("dom"); a.label("c_dom"); a.SETLO(pin); a.NOP()
        a.label("post")
        if "no_end_stuff" in mut:
            a.ALU("CMP", 2, imm=0); a.JCC("Z", "tail")
        a.ALU("CMP", 6, imm=stuff_n); a.JCC("Z", "x_std1")
        a.ALU("CMP", 4, imm=0); a.JCC("NZ", "x_std2")
        if "no_end_stuff" not in mut:
            a.ALU("CMP", 2, imm=0); a.JCC("Z", "tail")
        a.ALU("CMP", 2, imm=15); a.JCC("Z", "loadcrc")
        a.RGET(3, "TXF"); a.ALU("MOV", 4, rs=2); a.ALU("SUB", 4, imm=15); a.ALU("CMP", 4, imm=32); a.JCC("NC", "x_d1")
        a.LDI(4, 32)
        a.label("x_d2"); a.LDI(7, K["x_d2"]); a.WAITR(7); a.JMP("top")
        a.label("x_d1"); a.LDI(7, K["x_d1"]); a.WAITR(7); a.JMP("top")
        a.label("loadcrc"); a.RGET(3, "CRC"); a.ALU("SHL", 3, imm=17); a.LDI(4, 15)
        a.label("x_crc"); a.LDI(7, K["x_crc"]); a.WAITR(7); a.JMP("top")
        a.label("x_std1"); a.LDI(7, K["x_std1"]); a.WAITR(7); a.JMP("top")
        a.label("x_std2"); a.LDI(7, K["x_std2"]); a.WAITR(7); a.JMP("top")
        # stuff bit: the complement of the last bit; padded to the length of a source-bit iteration up to "emit"
        a.label("stuff")
        a.ALU("MOV", 1, rs=5); a.ALU("XOR", 1, imm=1); a.ALU("MOV", 5, rs=1); a.LDI(6, 1)
        if "feed_stuff" in mut:
            a.CRC("BIT", 1); a.WAIT(5)
        else:
            a.WAIT(6)
        a.JMP("emit")
        # ---- tail: the stuffed region is done; release at the slot boundary, then CRC delimiter, ACK slot, ACK delimiter, EOF
        a.label("tail"); a.LDI(7, K["tail"]); a.WAITR(7); a.SETH(pin)
        a.WAIT(int(1.5 * B) - 2)                                          # sample point of the ACK slot
        a.RGET(1, "PIN"); a.ALU("AND", 1, imm=1)
        a.LDI(0, 0x40000); a.ALU("SHL", 0, imm=8)
        a.ALU("CMP", 1, imm=1 if "ack_inv" in mut else 0); a.JCC("NZ", "noack"); a.ALU("OR", 0, imm=1)
        a.label("noack"); a.RPUT("RXF", 0)
        a.LDI(7, int(8.5 * B) - 10); a.WAITR(7); a.JMP("cmd")             # to the end of EOF; the idle poll supplies the intermission
        return a

    fix = {n: (lambda at, n=n: B - 3 - at("top", n)) for n in exits}

    def tail_fix(at):
        c_e = at("top", "c_rec")
        assert c_e == at("top", "c_dom")
        return c_e + B - at("top", "tail") - 2
    fix["tail"] = tail_fix
    a = _solve(build, fix)
    assert len(a.items) <= 256
    return a.words()


def can_rx(cpb=100, pin=0, mut=(), crc_cfg=None, sample_adj=0):
    assert pin == 0
    B = cpb
    stuff_n = 4 if "stuff4" in mut else 5
    top_exits = ("x_norm", "x_stuff", "x_crcs", "x_h1", "x_h2", "x_pw", "x_sd")
    tail_exits = ("x_tail1", "x_tail2")
    noack_exits = ("x_noack1", "x_noack2") + (("x_noack3",) if "no_ack" in mut else ())

    def build(K):
        a = Asm()
        a.SETH(pin); a.DIRO(pin)
        for op, v in (crc_cfg or CRC_CAN):
            a.LDI(2, v); a.CRC(op, 2)
        a.label("frame")
        a.CRC("RST"); a.LDI(5, 1); a.LDI(6, 0); a.LDI(2, 0); a.LDI(4, 19); a.LDI(3, 0); a.LDI(0, 0)
        a.WAITH(pin); a.WAITL(pin)                                        # the pin synchronizer resets to 0: wait for idle first
        a.WAIT(B // 2 - 4 + sample_adj)                                   # to the middle of the SOF bit
        a.JPH(pin, "frame")                                               # a glitch, not a start of frame
        # ---- one sample per iteration (the first one is SOF itself)
        a.label("top")
        a.RGET(1, "PIN"); a.ALU("AND", 1, imm=1)
        a.ALU("CMP", 6, imm=stuff_n); a.JCC("Z", "stuffb")
        a.CRC("BIT", 1)
        a.ALU("CMP", 1, rs=5); a.JCC("Z", "same"); a.LDI(6, 1); a.ALU("MOV", 5, rs=1); a.JMP("acc")
        a.label("same"); a.ALU("ADD", 6, imm=1); a.NOP(); a.NOP()
        a.label("acc")
        a.ALU("SHL", 3, imm=1); a.ALU("OR", 3, rs=1); a.ALU("ADD", 0, imm=1)
        a.ALU("SUB", 4, imm=1); a.JCC("Z", "secend")
        a.ALU("CMP", 0, imm=32); a.JCC("Z", "pushw")
        a.label("x_norm"); a.LDI(7, K["x_norm"]); a.WAITR(7); a.JMP("top")
        # stuff bit: must differ from the previous bit; it is not part of the CRC
        a.label("stuffb")
        if "no_stuff_check" in mut:
            a.NOP(); a.NOP()
        else:
            a.ALU("CMP", 1, rs=5); a.JCC("Z", "stuff_err")
        if "feed_stuff" in mut:
            a.CRC("BIT", 1)
        a.ALU("MOV", 5, rs=1); a.LDI(6, 1)
        a.ALU("CMP", 4, imm=0); a.JCC("Z", "x_tail2")                      # R4 = 0 only after the last CRC bit: this was the stuff bit behind it
        a.label("x_stuff"); a.LDI(7, K["x_stuff"]); a.WAITR(7); a.JMP("top")
        a.label("x_tail2"); a.LDI(7, K["x_tail2"]); a.WAITR(7); a.JMP("tail_top")
        # data word complete in the middle of the data field
        a.label("pushw"); a.RPUT("RXF", 3); a.LDI(3, 0); a.LDI(0, 0)
        a.label("x_pw"); a.LDI(7, K["x_pw"]); a.WAITR(7); a.JMP("top")
        # ---- end of a field (R2 = 0 header, 1 data, 2 CRC)
        a.label("secend")
        a.ALU("CMP", 2, imm=0); a.JCC("Z", "sec_hdr")
        a.ALU("CMP", 2, imm=1); a.JCC("Z", "sec_data")
        if "no_end_stuff" not in mut:
            a.ALU("CMP", 6, imm=stuff_n); a.JCC("Z", "x_crcs")             # a stuff bit follows the last CRC bit
        a.label("x_tail1"); a.LDI(7, K["x_tail1"]); a.WAITR(7); a.JMP("tail_top")
        a.label("x_crcs"); a.LDI(7, K["x_crcs"]); a.WAITR(7); a.JMP("top")
        a.label("sec_data")                                               # last data bits: left align, push
        a.LDI(7, 32); a.ALU("SUB", 7, rs=0); a.ALU("SHL", 3, rs=7); a.RPUT("RXF", 3)
        a.LDI(2, 2); a.LDI(4, 15); a.LDI(3, 0); a.LDI(0, 0)
        a.label("x_sd"); a.LDI(7, K["x_sd"]); a.WAITR(7); a.JMP("top")
        a.label("sec_hdr")                                                # SOF id[10:0] RTR IDE r0 dlc[3:0] in R3[18:0]
        if "ignore_rtr" not in mut:
            a.ALU("TST", 3, imm=0x60); a.JCC("NZ", "unsup")
        a.ALU("MOV", 0, rs=3); a.ALU("SHR", 0, imm=7); a.ALU("AND", 0, imm=0x7FF)
        a.ALU("MOV", 7, rs=3); a.ALU("AND", 7, imm=15); a.ALU("SHL", 7, imm=12); a.ALU("OR", 0, rs=7)
        a.LDI(7, 0x40000); a.ALU("SHL", 7, imm=8); a.ALU("OR", 0, rs=7); a.RPUT("RXF", 0)
        a.ALU("MOV", 7, rs=3); a.ALU("AND", 7, imm=15)
        if "dlc_raw" not in mut:
            a.ALU("CMP", 7, imm=8); a.JCC("NC", "lt8"); a.LDI(7, 8); a.JMP("j8")
            a.label("lt8"); a.NOP(); a.NOP()
            a.label("j8")
        a.ALU("CMP", 7, imm=0); a.JCC("Z", "nodata")
        a.LDI(2, 1); a.ALU("MOV", 4, rs=7); a.ALU("SHL", 4, imm=3); a.LDI(3, 0); a.LDI(0, 0)
        a.label("x_h1"); a.LDI(7, K["x_h1"]); a.WAITR(7); a.JMP("top")
        a.label("nodata"); a.LDI(2, 2); a.LDI(4, 15); a.LDI(3, 0); a.LDI(0, 0)
        a.label("x_h2"); a.LDI(7, K["x_h2"]); a.WAITR(7); a.JMP("top")
        # ---- CRC delimiter, ACK slot, ACK delimiter, EOF
        a.label("tail_top")
        a.RGET(1, "PIN"); a.ALU("AND", 1, imm=1); a.RGET(0, "CRC"); a.LDI(3, 0)
        a.ALU("CMP", 1, imm=0); a.JCC("NZ", "c_chk"); a.LDI(3, 3); a.JMP("x_noack1")      # CRC delimiter must be recessive
        a.label("c_chk")
        if "no_crc_check" in mut:
            a.JMP("x_ack")
        else:
            a.ALU("CMP", 0, imm=0); a.JCC("Z", "good"); a.LDI(3, 2)
            a.JMP("x_ack2" if "ack_always" in mut else "x_noack2")                       # residue != 0: CRC error, no ACK
        a.label("good"); a.JMP("x_noack3" if "no_ack" in mut else "x_ack")
        for n in ("x_ack",) + (("x_ack2",) if "ack_always" in mut else ()):
            a.label(n); a.LDI(7, K.get(n, 0)); a.WAITR(7); a.SETLO(pin); a.WAIT(B - 2); a.SETH(pin); a.JMP("eofw")
        for n in noack_exits:
            a.label(n); a.LDI(7, K[n]); a.WAITR(7); a.NOP(); a.WAIT(B - 2); a.NOP(); a.JMP("eofw")
        a.label("eofw"); a.WAIT(B // 2 - 4); a.SETL(8)
        a.label("eof")
        a.RGET(1, "PIN"); a.ALU("AND", 1, imm=1); a.ALU("CMP", 1, imm=0); a.JCC("NZ", "e_ok"); a.LDI(3, 3)
        a.label("e_ok"); a.WAIT(B - 6); a.DJNZ("eof")
        a.JMP("report")
        # ---- error exits
        a.label("unsup"); a.LDI(3, 4); a.JMP("report")
        a.label("stuff_err"); a.LDI(3, 1)
        a.label("report")                                                  # R3 = error code (0 = frame ok)
        a.LDI(7, 0x60000); a.ALU("SHL", 7, imm=8); a.ALU("MOV", 0, rs=3); a.ALU("SHL", 0, imm=4); a.ALU("OR", 0, rs=7)
        a.ALU("CMP", 3, imm=0); a.JCC("NZ", "st_push"); a.ALU("OR", 0, imm=1)
        a.label("st_push"); a.RPUT("RXF", 0)
        a.ALU("CMP", 3, imm=1); a.JCC("Z", "quiet"); a.ALU("CMP", 3, imm=4); a.JCC("Z", "quiet"); a.JMP("frame")
        a.label("quiet"); a.LDI(4, (11 * B) // 3)                          # wait for 11 recessive bit times
        a.label("qpoll"); a.JPL(pin, "quiet"); a.ALU("SUB", 4, imm=1); a.JCC("NZ", "qpoll"); a.JMP("frame")
        return a

    fix = {n: (lambda at, n=n: B - 3 - at("top", n)) for n in top_exits}
    fix.update({n: (lambda at, n=n: B - 3 - at("top", n)) for n in tail_exits})
    for n in ("x_ack",) + (("x_ack2",) if "ack_always" in mut else ()):
        fix[n] = lambda at, n=n: B // 2 - at("tail_top", n) - 2
    for n in noack_exits:
        fix[n] = lambda at, n=n: B // 2 - at("tail_top", n) - 2
    a = _solve(build, fix)
    assert len(a.items) <= 256
    return a.words()


def host_words(ident, data, dlc=None):
    """Host TX words for can_tx: {dlc, id} then the data bytes packed four per word, byte 0 in [31:24]."""
    d = len(data) if dlc is None else dlc
    ws = [d << 12 | ident]
    n = min(d, 8)
    for i in range(0, n, 4):
        chunk = list(data[i:min(i + 4, n)]) + [0] * 4
        ws.append(chunk[0] << 24 | chunk[1] << 16 | chunk[2] << 8 | chunk[3])
    return ws


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--cpb", type=int, default=100)
    a = ap.parse_args()
    for name, ws in (("TX", can_tx(a.cpb)), ("RX", can_rx(a.cpb))):
        print(f"CAN {name}: {len(ws)} words @ {a.cpb} clocks/bit")
        for i, w in enumerate(ws):
            print(f"  {i:3d}  {w:08X}  {disasm(w)}")
