#!/usr/bin/env python3
"""SPI firmware generator for the protocol engine (instructions.md section 3).

master(mode, bits, lsb, h) / slave(mode, bits, lsb) return a list of 32-bit words.
Pins: 2 = SCLK, 3 = MOSI, 4 = MISO, 5 = CS (active low). mode = CPOL*2 + CPHA.
Host data layout (one FIFO word per CS frame, bits = 1..32):
  tx_word(v): MSB-first -> v << (32 - bits), LSB-first -> v
  rx_value(w): MSB-first -> w & mask,        LSB-first -> w >> (32 - bits)

Run directly to print every variant:  python host/spi_prog.py [--bits 8] [--h 4]
"""
import argparse

OP = dict(NOP=0, WAIT=1, JMP=2, HALT=3, SETL=4, DJNZ=5, PULL=6, PUSH=7, OUT1=8, IN1=9,
          SETH=10, SETLO=11, DIRO=12, DIRI=13, WAITH=14, WAITL=15, CFG=16, JPH=17, JPL=18, JPO=19, PUSHI=20)
SCLK, MOSI, MISO, CS = 2, 3, 4, 5


def _cfg(out_pin, in_pin, lsb):
    msb = 0 if lsb else 1
    return ("CFG", out_pin | in_pin << 3 | msb << 6 | msb << 7)


def _jp(level, pin, addr):
    """Jump to addr if pin == level (JPH / JPL)."""
    return ("JPH" if level else "JPL", pin << 6 | addr)


def master(mode, bits=8, lsb=False, h=4):
    """SCLK lead phase = h+2 clocks, idle phase = h+3, CS to first edge = h+2."""
    cpol, cpha = mode >> 1, mode & 1
    lead, trail = ("SETLO", "SETH") if cpol else ("SETH", "SETLO")
    p = [_cfg(MOSI, MISO, lsb),
         (trail, SCLK), ("SETH", CS),                 # idle levels first, then drive (no glitch)
         ("DIRO", SCLK), ("DIRO", MOSI), ("DIRO", CS)]
    top = len(p)
    p += [("PULL", 0), ("SETL", bits), ("SETLO", CS)]
    if cpha:
        p += [("WAIT", h)]                            # CS setup; CPHA=0 gets it from the first OUT1
    b = len(p)
    if cpha == 0:
        p += [("OUT1", h), (lead, SCLK), ("IN1", h), (trail, SCLK)]
    else:
        p += [(lead, SCLK), ("OUT1", h), (trail, SCLK), ("IN1", h)]
    p += [("DJNZ", b), ("SETH", CS), ("PUSH", 0), ("JMP", top)]
    return assemble(p)


def slave(mode, bits=8, lsb=False):
    """Edge waits poll CS too: CS going inactive mid-frame aborts to the frame start (no PUSH).
    The frame ends at the last sample, so CS may rise right after the last sampling edge."""
    cpol, cpha = mode >> 1, mode & 1
    wait_lead = lambda a: [_jp(1, CS, top), _jp(cpol, SCLK, a)]       # loop at a until SCLK leaves idle
    wait_trail = lambda a: [_jp(1, CS, top), _jp(1 - cpol, SCLK, a)]  # loop at a until SCLK is idle
    p = [_cfg(MISO, MOSI, lsb)]
    top = len(p)
    p += [("WAITH", CS),                              # also hides the synchronizer's reset 0
          ("DIRI", MISO), ("PULL", 0), ("SETL", bits), ("WAITL", CS)]
    if cpha == 0:
        p += [("OUT1", 0)]                            # first bit before the first edge
    p += [("DIRO", MISO)]
    b = len(p)
    if cpha == 0:   # sample on lead; shift on trail, except after the last bit
        p += wait_lead(b) + [("IN1", 0), ("DJNZ", b + 6), ("PUSH", 0), ("JMP", top)]
        p += wait_trail(b + 6) + [("OUT1", 0), ("JMP", b)]
    else:           # shift on lead, sample on trail
        p += wait_lead(b) + [("OUT1", 0)] + wait_trail(b + 3) + [("IN1", 0)]
        p += [("DJNZ", b), ("PUSH", 0), ("JMP", top)]
    return assemble(p)


def assemble(prog):
    assert len(prog) <= 64
    return [OP[m] << 27 | a for m, a in prog]


def tx_word(v, bits, lsb):
    return v if lsb else (v << (32 - bits)) & 0xFFFFFFFF


def rx_value(w, bits, lsb):
    return (w >> (32 - bits)) if lsb else w & ((1 << bits) - 1)


def write_hex(words, path):
    with open(path, "w") as f:
        f.write("".join(f"{w:08X}\n" for w in words))


def disasm(w):
    name = {v: k for k, v in OP.items()}.get(w >> 27, "?")
    a = w & 0x7FFFFFF
    return f"{name} {a >> 6},{a & 63}" if name in ("JPH", "JPL") else f"{name} {a}"


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--bits", type=int, default=8)
    ap.add_argument("--h", type=int, default=4)
    ap.add_argument("--lsb", action="store_true")
    a = ap.parse_args()
    for role in ("master", "slave"):
        for mode in range(4):
            ws = master(mode, a.bits, a.lsb, a.h) if role == "master" else slave(mode, a.bits, a.lsb)
            print(f"{role} mode {mode}: {len(ws)} words")
            for i, w in enumerate(ws):
                print(f"  {i:2d}  {w:08X}  {disasm(w)}")
