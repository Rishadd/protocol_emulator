#!/usr/bin/env python3
"""ARM Serial Wire Debug (SWD) HOST (the debug probe side) for one engine: line reset, JTAG-to-SWD switch, and read / write transactions with
ACK and data parity handled in firmware (ARM Debug Interface v5 specification, chapter B4). Pins: SWCLK = logical pin 0 (output), SWDIO = logical
pin 1 (bidirectional, push-pull; released during the turnaround and the target's phases). The clock idles low; the engine changes SWDIO while
SWCLK is low and the target samples on the rising edge; in the target's phases the engine samples SWDIO late in the high phase (the target changes
it after the falling edge).

Host -> engine words (TX FIFO), command in bits [31:28]:
    0x1  line reset: 56 clocks with SWDIO high; if bit 0 is set the JTAG-to-SWD switch sequence 0xE79E (16 bits, LSB first) follows, then a second
         line reset (56 ones) and 8 idle clocks.   (arg: bit 0 = send the switch sequence)
    0x2  transaction: bits [7:0] = the 8 request bits in transmission order, bit 0 first (start 1, APnDP, RnW, A2, A3, parity, stop 0, park 1),
         bit 8 = RnW (1: read).  A write is followed by one more word: the 32 data bits.
    0x3  idle: bits [15:0] = number of clocks with SWDIO low
Engine -> host words (RX FIFO), one per command that answers:
    transaction: first word = ACK in [2:0] (0b001 OK, 0b010 WAIT, 0b100 FAULT, anything else is a protocol error) | bit 3: the read data parity was
    wrong | bit 4: a data phase was done; for a read with ACK OK a second word follows: the 32 data bits.
Clock: half period 25 clocks (1 MHz).
"""
import asm as A

CLK, DIO = 0, 1
HALF = 25                                    # clocks per half period of SWCLK


def request_byte(apndp, rnw, addr):
    """The 8 request bits for A[3:2] = addr >> 2 (addr = 0, 4, 8, 12), bit 0 first on the wire."""
    a2, a3 = addr >> 2 & 1, addr >> 3 & 1
    parity = (apndp + rnw + a2 + a3) & 1
    bits = [1, apndp, rnw, a2, a3, parity, 0, 1]
    return sum(b << i for i, b in enumerate(bits))


def cmd_reset(switch=True):
    return 0x1 << 28 | int(switch)


def cmd_xfer(apndp, rnw, addr):
    return 0x2 << 28 | rnw << 8 | request_byte(apndp, rnw, addr)


def cmd_idle(n):
    return 0x3 << 28 | (n & 0xFFFF)


def swd_host(mut=()):
    """mut: planted bugs: msb_first, no_turnaround, wrong_parity, ack_msb."""
    a = A.Asm()
    h = HALF - 1
    a.CFG(out_pin=DIO, in_pin=DIO, osr_msb=1 if "msb_first" in mut else 0, isr_msb=0)
    a.SETLO(CLK); a.SETLO(DIO); a.DIRO(CLK); a.DIRO(DIO)

    # one clock cycle: clock low (SWDIO already set), clock high (target samples), clock low again
    def clock(a, sample=False):
        a.SETH(CLK)
        if sample:
            a.WAIT(h - 1); a.IN1(0)            # sample late in the high phase
        else:
            a.WAIT(h)
        a.SETLO(CLK); a.WAIT(h)

    a.label("cmd")
    a.PULL()
    a.RGET(0, "OSR")
    a.ALU("SHR", 0, imm=28)
    a.ALU("CMP", 0, imm=1); a.JCC("Z", "reset")
    a.ALU("CMP", 0, imm=2); a.JCC("Z", "xfer")
    a.ALU("CMP", 0, imm=3); a.JCC("Z", "idle")
    a.JMP("cmd")

    # ---- line reset (+ JTAG-to-SWD switch)
    a.label("reset")
    a.RGET(4, "OSR"); a.ALU("AND", 4, imm=1)
    a.SETH(DIO)
    a.SETL(56)
    a.label("r1"); clock(a); a.DJNZ("r1")
    a.ALU("TST", 4, imm=1); a.JCC("Z", "rdone")
    a.LDI(1, 0xE79E); a.RPUT("OSR", 1)
    a.SETL(16)
    a.label("r2"); a.OUT1(0); clock(a); a.DJNZ("r2")
    a.SETH(DIO)
    a.SETL(56)
    a.label("r3"); clock(a); a.DJNZ("r3")
    a.label("rdone")
    a.SETLO(DIO)
    a.SETL(8)
    a.label("r4"); clock(a); a.DJNZ("r4")
    a.JMP("cmd")

    # ---- idle clocks
    a.label("idle")
    a.RGET(1, "OSR"); a.ALU("AND", 1, imm=0xFFFF)
    a.SETLO(DIO)
    a.label("i1")
    clock(a)
    a.ALU("SUB", 1, imm=1); a.JCC("NZ", "i1")
    a.JMP("cmd")

    # ---- transaction
    a.label("xfer")
    a.RGET(5, "OSR"); a.ALU("MOV", 6, rs=5); a.ALU("SHR", 6, imm=8); a.ALU("AND", 6, imm=1)       # r6 = RnW
    a.ALU("AND", 5, imm=0xFF); a.RPUT("OSR", 5)
    a.SETL(8)
    a.label("x1"); a.OUT1(0); clock(a); a.DJNZ("x1")
    a.DIRI(DIO)                                                       # turnaround: the target takes the line
    if "no_turnaround" not in mut:
        clock(a)
    a.LDI(7, 0)
    a.SETL(3)
    a.label("x2"); clock(a, sample=True); a.DJNZ("x2")               # ACK, 3 bits
    a.RGET(0, "ISR"); a.ALU("SHR", 0, imm=29)                         # r0 = ACK (first bit sampled = bit 0)
    if "ack_msb" in mut:
        a.ALU("REV8", 0, rs=0); a.ALU("SHR", 0, imm=5)
    a.ALU("CMP", 0, imm=1); a.JCC("NZ", "xack")                       # not OK: no data phase
    a.ALU("CMP", 6, imm=0); a.JCC("Z", "xwrite")
    # read: 32 data bits + parity from the target, then the turnaround back
    a.SETL(32)
    a.label("x3"); clock(a, sample=True); a.DJNZ("x3")
    a.RGET(2, "ISR")                                                  # r2 = data
    a.SETH(CLK)                                                       # parity bit
    a.WAIT(h - 1); a.IN1(0)
    a.SETLO(CLK); a.WAIT(h)
    a.RGET(3, "ISR"); a.ALU("SHR", 3, imm=31)                         # r3 = parity bit received
    a.ALU("PAR", 4, rs=2); a.ALU("XOR", 4, rs=3)                      # 1 if the parity is wrong
    clock(a)                                                          # turnaround
    a.DIRO(DIO); a.SETLO(DIO)
    a.ALU("SHL", 4, imm=3); a.ALU("OR", 0, rs=4); a.ALU("OR", 0, imm=0x10)
    a.RPUT("RXF", 0); a.RPUT("RXF", 2)
    a.JMP("xidle")
    a.label("xwrite")
    clock(a)                                                          # turnaround to the host
    a.DIRO(DIO)
    a.PULL(); a.RGET(2, "OSR")                                        # the data word
    a.ALU("PAR", 3, rs=2)
    if "wrong_parity" in mut:
        a.ALU("XOR", 3, imm=1)
    a.SETL(32)
    a.label("x4"); a.OUT1(0); clock(a); a.DJNZ("x4")
    a.ALU("MOV", 1, rs=3); a.RPUT("OSR", 1); a.OUT1(0); clock(a)      # parity bit
    a.SETLO(DIO)
    a.ALU("OR", 0, imm=0x10)
    a.RPUT("RXF", 0)
    a.JMP("xidle")
    a.label("xack")                                                   # WAIT / FAULT / garbage: turnaround, no data phase
    clock(a)
    a.DIRO(DIO); a.SETLO(DIO)
    a.RPUT("RXF", 0)
    a.label("xidle")
    if "no_idle" not in mut:
        a.SETL(8)
        a.label("x5"); clock(a); a.DJNZ("x5")
    a.JMP("cmd")
    return a


def words(mut=()):
    return swd_host(mut).words()


if __name__ == "__main__":
    print(f"swd host firmware: {len(words())} words")
