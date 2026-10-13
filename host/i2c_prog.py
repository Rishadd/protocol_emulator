#!/usr/bin/env python3
"""I2C master firmware generator for the protocol engine (docs/I2C_PLAN.md §6.3).

Pins: 6 = SDA, 7 = SCL. The host claims both pads for the engine as OPEN-DRAIN (pin manager), so
SETH / OUT1 1 release a line and SETLO / OUT1 0 pull it low.

One TX word per byte (MSB-first OSR, flags interleaved in shift order):
  [31] S  START (repeated START inside a transfer) before the byte
  [30:22] 9-bit slot = {byte, ack_out}: write {data, 1}, read {0xFF, 0 = ACK / 1 = NACK}
  [21] C  check ACK: if the 9th bit is 1 (NACK): STOP, push EV_NACK, then drop words until one with S
  [20] P  STOP after the byte
RX word per byte: [8:0] = {sampled byte, sampled ack}. After a STOP the master drops words without S.

Run directly to print the program:  python host/i2c_prog.py [--khz 400] [--fclk 50e6]
"""
import argparse
import math

from spi_prog import OP, assemble, write_hex   # same encoder
import link

SDA, SCL = 6, 7
EV = 1 << 26                  # PUSHI event codes (bus data words are <= 9 bits)
EV_START, EV_STOP, EV_NACK = EV | 1, EV | 2, EV | 3

# UM10204 minimums in ns (Sm, Fm, Fm+), rise = max t_r
SPEC = {
    100: dict(low=4700, high=4000, su_sta=4700, hd_sta=4000, su_dat=250, su_sto=4000, buf=4700, rise=1000),
    400: dict(low=1300, high=600, su_sta=600, hd_sta=600, su_dat=100, su_sto=600, buf=1300, rise=300),
    1000: dict(low=500, high=260, su_sta=260, hd_sta=260, su_dat=50, su_sto=260, buf=500, rise=120),
}


def delays(khz, f_clk=50e6, margin=2):
    """Clock counts for the program. The SCL low phase is tA+2 clocks; the high phase, measured from
    the line actually going high, is tH+3 plus 1-2 clocks of input synchronizer. Each value has
    `margin` clocks on top of the minimum, and the period is padded up to the nominal frequency plus one
    clock: after a slave stretch the high phase starts at the next synchronized edge, up to 1 clock late
    relative to the line, which otherwise made one period 1 ns short (found by the 400 kHz stretch test)."""
    s = SPEC[1000 if khz > 400 else 400 if khz > 100 else 100]
    c = lambda ns: -(-int(ns) * int(f_clk) // 10**9) + margin    # exact integer ceil(ns * f_clk)
    low, high = c(s["low"]), c(s["high"])
    high = max(high, math.ceil(f_clk / (khz * 1e3)) - low - 1)
    return dict(tA=low - 2, tH=high - 4, tL=low - 4, su_sta=c(s["su_sta"]), hd_sta=c(s["hd_sta"]),
                su_sto=c(s["su_sto"]), buf=c(s["buf"]))


def master(khz=400, f_clk=50e6, d=None, sda=SDA, scl=SCL):
    """d overrides delays() (used by the speed sweep); sda/scl: pin map."""
    SDA, SCL = sda, scl
    d = d or delays(khz, f_clk)
    L = {}                                       # labels, resolved in a second pass
    p = [("CFG", SDA | SDA << 3 | 1 << 6 | 1 << 7),          # OUT1 / IN1 on SDA, MSB-first
         ("SETH", SDA), ("SETH", SCL), ("DIRO", SDA), ("DIRO", SCL),   # released (open-drain)
         ("WAITH", SCL), ("WAITH", SDA)]                       # bus idle (also hides sync reset 0)
    def lab(name): L[name] = len(p)
    lab("idle");  p += [("PULL", 0), ("JPO", "start"), ("JMP", "idle")]          # no S: dropped
    lab("next");  p += [("PULL", 0), ("JPO", "start")]
    lab("slot");  p += [("SETL", 9)]
    lab("bit");   p += [("SETLO", SCL), ("OUT1", d["tA"]), ("SETH", SCL), ("WAITH", SCL),
                        ("IN1", d["tH"]), ("DJNZ", "bit"),
                        ("JPO", "check")]                     # C flag, SCL still high (9th bit)
    lab("back");  p += [("SETLO", SCL), ("PUSH", 0), ("JPO", "stop"), ("JMP", "next")]
    lab("check"); p += [("JPH", "nack"), ("JMP", "back")]     # live ACK level while SCL is high
    lab("nack");  p += [("SETLO", SCL), ("PUSH", 0), ("PUSHI", EV_NACK)]
    lab("stop");  p += [("SETLO", SDA), ("WAIT", d["tL"]), ("SETH", SCL), ("WAITH", SCL),
                        ("WAIT", d["su_sto"]), ("SETH", SDA), ("WAIT", d["buf"]), ("JMP", "idle")]
    lab("start"); p += [("SETH", SDA), ("WAIT", d["tL"]), ("SETH", SCL), ("WAITH", SCL), ("WAITH", SDA),
                        ("WAIT", d["su_sta"]), ("SETLO", SDA), ("WAIT", d["hd_sta"]), ("JMP", "slot")]
    out = []
    for m, a in p:
        if m == "JPH":
            a = (sda, L[a])
        elif isinstance(a, str):
            a = L[a]
        out.append((m, a))
    return assemble(out)


def slave(khz=400, f_clk=50e6, split=False, sda=SDA, scl=SCL, l2_base=0):
    """I2C slave (target) firmware (docs/TWO_TIER_RESULTS.md, Phase 7). One path for every byte:
    before a byte the slave holds SCL low and PULLs a slot word (bits to drive at [31:24], 0xFF = listen);
    it releases SCL, watches the first bit for STOP / repeated START, reads 8 bits, holds SCL, PUSHes the
    byte ([7:0]) and PULLs an ACK word ([31] = 9th bit to drive: 0 ACK, 1 NACK or release when sending);
    after the 9th bit it holds SCL and PUSHes the 9th bit as sampled ([0]). START / STOP are pushed as
    EV_START / EV_STOP. A 1 in the 9th bit (NACK) releases SDA and only waits for STOP / Sr.
    The host decides every ACK (also the address match). split=True: init, idle and STOP handling go to
    L2 (cold), the byte loop stays in L1 (hot). Returns the linked program (link.link)."""
    s = SPEC[1000 if khz > 400 else 400 if khz > 100 else 100]
    tsu = -(-int(s["su_dat"]) * int(f_clk) // 10**9) + 2        # clocks from SDA change to SCL release
    cold = (".l2",) if split else (".l1",)
    p = [cold, ("lab", "init"), ("CFG", sda | sda << 3 | 1 << 6 | 1 << 7),
         ("SETH", sda), ("SETH", scl), ("DIRO", scl),
         ("lab", "idle"), ("JPL", (scl, "idle")), ("JPL", (sda, "idle")),         # wait for both high
         ("lab", "idle2"), ("JPL", (scl, "idle")), ("JPH", (sda, "idle2"))]      # SDA falls, SCL high: START
    p += [("JMP", "sr")] if split else []
    p += [(".l1",),
          ("lab", "sr"), ("WAITL", scl), ("SETLO", scl), ("PUSHI", EV_START),   # hold SCL, report
          ("lab", "held"), ("PULL", 0), ("DIRO", sda), ("SETL", 7), ("OUT1", tsu), ("SETH", scl),
          ("lab", "first"), ("WAITH", scl), ("IN1", 0), ("JPH", (sda, "w1")),
          ("lab", "w0"), ("JPL", (scl, "cont")), ("JPH", (sda, "stop")), ("JMP", "w0")]   # SDA rises: STOP
    p += [("lab", "w1"), ("JPL", (scl, "cont")), ("JPL", (sda, "sr")), ("JMP", "w1"),     # SDA falls: Sr
          ("lab", "cont"), ("OUT1", tsu), ("WAITH", scl), ("IN1", 0), ("WAITL", scl), ("DJNZ", "cont"),
          ("SETLO", scl), ("PUSH", 0), ("PULL", 0), ("OUT1", tsu), ("SETH", scl), ("WAITH", scl),
          ("IN1", 0), ("JPH", (sda, "nack")), ("WAITL", scl), ("SETLO", scl), ("PUSH", 0), ("JMP", "held"),
          ("lab", "nack"), ("WAITL", scl), ("SETLO", scl), ("PUSH", 0), ("DIRI", sda), ("SETH", scl),
          ("JMP", "first"),
          cold, ("lab", "stop"), ("PUSHI", EV_STOP), ("JMP", "idle")]
    prog = link.link(p, l2_base)
    prog["rv"] = prog["sym"]["init"]
    return prog


def word(slot9, s=0, c=0, p=0):
    return s << 31 | slot9 << 22 | c << 21 | p << 20


def transaction(addr, wr=(), rd=0, stop=True, start=True):
    """Words for START, addr + R/W, then either the write bytes or `rd` read bytes (NACK on the last).
    Chain a write and a read with stop=False on the first to get a repeated START."""
    w = [word((addr << 1 | (1 if rd else 0)) << 1 | 1, s=int(start), c=1)]
    w += [word(b << 1 | 1, c=1) for b in wr]
    w += [word(0xFF << 1 | (1 if i == rd - 1 else 0)) for i in range(rd)]
    if stop:
        w[-1] |= 1 << 20
    return w


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--khz", type=int, default=400)
    ap.add_argument("--fclk", type=float, default=50e6)
    a = ap.parse_args()
    from spi_prog import disasm
    ws = master(a.khz, a.fclk)
    print(f"I2C master {a.khz} kHz @ {a.fclk / 1e6:g} MHz: {len(ws)} words, delays {delays(a.khz, a.fclk)}")
    for i, w in enumerate(ws):
        print(f"  {i:2d}  {w:08X}  {disasm(w)}")
