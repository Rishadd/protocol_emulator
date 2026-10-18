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

SDA, SCL = 6, 7
EV = 1 << 26                  # PUSHI event codes (bus data words are <= 9 bits)
EV_NACK = EV | 3

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


def master(khz=400, f_clk=50e6, d=None):
    """d overrides delays() (used by the speed sweep)."""
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
            a = SDA << 8 | L[a]
        elif isinstance(a, str):
            a = L[a]
        out.append((m, a))
    return assemble(out)


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


# =========================================================================================================== slave
# I2C slave (target), 7-bit address, written for the register / ALU extension (docs/ALU_CRC_I2CSLAVE_PLAN.md section 5).
# Pins as the master: 6 = SDA, 7 = SCL, claimed open-drain. The firmware has no timing parameters: it follows the bus.
#
# Host interface
#   TX FIFO  word 0 = own 7-bit address (low 7 bits; the firmware compares the address byte itself, no host handshake);
#            then one word per byte the master reads (low 8 bits are sent MSB first; the byte is fetched while the slave holds
#            SCL low, so a late host only slows the bus, it never loses data).
#   RX FIFO  data byte received from the master (write)          : 0x000..0x0FF
#            EV | 0x100 | addr_byte  address matched (addr_byte = address << 1 | R/W)
#            EV | 0x200 | nack       one read byte was sent; nack = 1 if the master answered NACK (last byte)
#            EV | 1  STOP after a matched transaction            EV | 2  repeated START after a matched transaction
#   A non-matching address produces no events and no ACK; the slave then ignores the bus until the next START.
#   Write bytes are ACKed after the byte is pushed (SCL is held low while the RX FIFO is full: flow control by stretching).
#   STOP / repeated START events are pushed while the bus runs on, so the host must keep the RX FIFO from filling up there.
EV_ADDR, EV_RACK, EV_STOP, EV_SR = EV | 0x100, EV | 0x200, EV | 1, EV | 2


def slave():
    from asm import Asm
    a = Asm()
    a.CFG(out_pin=SDA, in_pin=SDA, osr_msb=1, isr_msb=1)
    a.SETH(SDA); a.SETH(SCL); a.DIRO(SDA); a.DIRO(SCL)               # released (open-drain), then enabled
    a.LDI(6, 0x40000); a.ALU("SHL", 6, imm=8)                        # R6 = EV (bit 26 does not fit LDI's 24 bits)
    a.LDI(3, 0)                                                       # R3 = 1 while a matched transaction is open
    a.RGET(0, "TXF"); a.ALU("SHL", 0, imm=1)                          # R0 = own address byte (address << 1)

    # ---- idle: watch the bus for a START (SDA falls while SCL is high); a STOP or ordinary clocks are ignored
    a.label("idle");    a.WAITH(SCL); a.JPL(SDA, "idle_w")
    a.label("idle_m");  a.JPL(SCL, "idle"); a.JPH(SDA, "idle_m"); a.JMP("evt_start")
    a.label("idle_w");  a.JPL(SCL, "idle"); a.JPL(SDA, "idle_w"); a.JMP("evt_stop")

    # ---- events seen on the bus
    a.label("evt_stop");  a.ALU("CMP", 3, imm=0); a.JCC("Z", "idle"); a.PUSHI(EV_STOP); a.LDI(3, 0); a.JMP("idle")
    a.label("evt_start"); a.ALU("CMP", 3, imm=0); a.JCC("Z", "addr"); a.PUSHI(EV_SR); a.LDI(3, 0)

    # ---- address byte: 8 bits MSB first, START/STOP watched while SCL is high
    a.label("addr");  a.WAITL(SCL); a.LDI(5, 0); a.RPUT("ISR", 5); a.SETL(8)
    a.label("abit");  a.WAITH(SCL); a.IN1(0); a.JPL(SDA, "a_lo")
    a.label("a_hi");  a.JPL(SCL, "a_done"); a.JPH(SDA, "a_hi"); a.JMP("evt_start")
    a.label("a_lo");  a.JPL(SCL, "a_done"); a.JPL(SDA, "a_lo"); a.JMP("evt_stop")
    a.label("a_done"); a.DJNZ("abit")
    a.SETLO(SCL)                                                      # stretch from here until the decision is done
    a.RGET(1, "ISR")
    a.ALU("MOV", 5, rs=1); a.ALU("AND", 5, imm=0xFE); a.ALU("CMP", 5, rs=0); a.JCC("NZ", "a_nomatch")
    a.SETLO(SDA); a.LDI(3, 1)                                         # ACK
    a.ALU("MOV", 5, rs=6); a.ALU("OR", 5, imm=0x100); a.ALU("OR", 5, rs=1); a.RPUT("RXF", 5)
    a.ALU("TST", 1, imm=1); a.JCC("NZ", "rd_dir")

    # ---- master writes: receive, push, ACK
    a.label("w_ack9"); a.SETH(SCL); a.WAITH(SCL); a.WAITL(SCL); a.SETH(SDA)    # 9th clock carries our ACK
    a.LDI(5, 0); a.RPUT("ISR", 5); a.SETL(8)
    a.label("wbit");  a.WAITH(SCL); a.IN1(0); a.JPL(SDA, "w_lo")
    a.label("w_hi");  a.JPL(SCL, "w_done"); a.JPH(SDA, "w_hi"); a.JMP("evt_start")
    a.label("w_lo");  a.JPL(SCL, "w_done"); a.JPL(SDA, "w_lo"); a.JMP("evt_stop")
    a.label("w_done"); a.DJNZ("wbit")
    a.SETLO(SCL); a.SETLO(SDA)                                        # stretch + ACK
    a.RGET(1, "ISR"); a.RPUT("RXF", 1); a.JMP("w_ack9")               # blocks (SCL low) while the RX FIFO is full

    # ---- address not ours: release and ignore everything until the next START
    a.label("a_nomatch"); a.LDI(3, 0); a.SETH(SCL); a.JMP("idle")

    # ---- master reads: byte from the TX FIFO, MSB first, then sample the master's ACK
    a.label("rd_dir"); a.SETH(SCL); a.WAITH(SCL); a.WAITL(SCL)         # finish the address ACK clock
    a.label("tx_next"); a.SETLO(SCL)                                  # hold SCL while the next byte is fetched
    a.RGET(4, "TXF"); a.ALU("SHL", 4, imm=24); a.RPUT("OSR", 4); a.SETL(7)
    a.OUT1(0); a.SETH(SCL)                                            # bit 7 on SDA, then release SCL
    a.label("tbit");  a.WAITH(SCL); a.WAITL(SCL); a.OUT1(0); a.DJNZ("tbit")        # bits 6..0
    a.WAITH(SCL); a.WAITL(SCL); a.SETH(SDA)                           # 8th clock done, master's ACK slot
    a.WAITH(SCL); a.JPH(SDA, "t_nack")
    a.WAITL(SCL); a.SETLO(SCL); a.PUSHI(EV_RACK); a.JMP("tx_next")    # ACK: next byte
    a.label("t_nack"); a.WAITL(SCL); a.SETLO(SCL); a.PUSHI(EV_RACK | 1); a.SETH(SCL); a.JMP("idle")
    return a.words()


def slave_cfg_word(addr7):
    """First TX word: the slave's own address."""
    return addr7 & 0x7F


# =========================================================================================================== master + PEC
# SMBus Packet Error Code: CRC-8 (poly 0x07, init 0, no reflection) over every byte of the transaction, address bytes included,
# computed by the CRC unit. Same word format as master(); three more flags in the low half of the TX word (all clear = plain master):
#   bit 13  CRC_RST   reset the CRC before this byte (put it on the START word)
#   bit 15  PEC_SEND  the 8 data bits of the slot are replaced by the CRC so far (the PEC byte of a write)
#   bit 14  PEC_CHK   after this received byte the CRC over everything including it must be 0; otherwise EV_PEC is pushed
# Every byte (sent or received) is fed to the CRC after its 9 bits. Bus timing is identical to master(): the extra instructions run
# while SCL is held low between bytes.
EV_PEC = EV | 0x10
F_CRC_RST, F_PEC_CHK, F_PEC_SEND = 1 << 13, 1 << 14, 1 << 15


def master_pec(khz=400, f_clk=50e6, d=None, cfg=None, mut=()):
    """cfg overrides the CRC configuration, mut = firmware mutations for the tests: no_send, no_check, no_rst, no_feed."""
    from asm import Asm
    d = d or delays(khz, f_clk)
    a = Asm()
    a.CFG(out_pin=SDA, in_pin=SDA, osr_msb=1, isr_msb=1)
    a.SETH(SDA); a.SETH(SCL); a.DIRO(SDA); a.DIRO(SCL)
    a.WAITH(SCL); a.WAITH(SDA)
    for op, v in (cfg or (("POLY", 7), ("INIT", 0), ("XOR", 0), ("FMT", 7))):    # CRC-8, width 8, no reflection
        a.LDI(2, v); a.CRC(op, 2)
    a.LDI(5, 0xFF); a.ALU("SHL", 5, imm=23); a.ALU("NOT", 5, rs=5)       # R5 = ~(0xFF << 23): clears the slot's 8 data bits
    n = [0]

    def prelude():
        n[0] += 1
        a.RGET(3, "OSR")                                                # R3 = the word just pulled
        a.ALU("TST", 3, imm=F_CRC_RST); a.JCC("Z", f"nr{n[0]}")
        if "no_rst" not in mut:
            a.CRC("RST")
        a.label(f"nr{n[0]}")
        a.ALU("TST", 3, imm=F_PEC_SEND); a.JCC("Z", f"ns{n[0]}")
        a.RGET(4, "CRC"); a.ALU("SHL", 4, imm=23); a.ALU("AND", 3, rs=5); a.ALU("OR", 3, rs=4)
        if "no_send" not in mut:
            a.RPUT("OSR", 3)
        a.label(f"ns{n[0]}")

    a.label("idle"); a.PULL(); prelude(); a.JPO("start"); a.JMP("idle")
    a.label("next"); a.PULL(); prelude(); a.JPO("start")
    a.label("slot"); a.SETL(9)
    a.label("bit"); a.SETLO(SCL); a.OUT1(d["tA"]); a.SETH(SCL); a.WAITH(SCL); a.IN1(d["tH"]); a.DJNZ("bit")
    a.JPO("check")
    a.label("back"); a.SETLO(SCL); a.RGET(2, "ISR"); a.PUSH(); a.ALU("SHR", 2, imm=1)
    if "no_feed" not in mut:
        a.CRC("BYTE", 2)
    a.ALU("TST", 3, imm=F_PEC_CHK); a.JCC("Z", "back2" if "no_check" not in mut else "back2")
    a.RGET(4, "CRC"); a.ALU("CMP", 4, imm=0); a.JCC("Z", "back2")
    if "no_check" not in mut:
        a.PUSHI(EV_PEC)
    a.label("back2"); a.JPO("stop"); a.JMP("next")
    a.label("check"); a.JPH(SDA, "nack"); a.JMP("back")
    a.label("nack"); a.SETLO(SCL); a.PUSH(); a.PUSHI(EV_NACK)
    a.label("stop"); a.SETLO(SDA); a.WAIT(d["tL"]); a.SETH(SCL); a.WAITH(SCL); a.WAIT(d["su_sto"]); a.SETH(SDA)
    a.WAIT(d["buf"]); a.JMP("idle")
    a.label("start"); a.SETH(SDA); a.WAIT(d["tL"]); a.SETH(SCL); a.WAITH(SCL); a.WAITH(SDA); a.WAIT(d["su_sta"])
    a.SETLO(SDA); a.WAIT(d["hd_sta"]); a.JMP("slot")
    return a.words()


def pec_word(slot9, s=0, c=0, p=0, crc_rst=0, pec_send=0, pec_chk=0):
    return word(slot9, s, c, p) | crc_rst * F_CRC_RST | pec_send * F_PEC_SEND | pec_chk * F_PEC_CHK
