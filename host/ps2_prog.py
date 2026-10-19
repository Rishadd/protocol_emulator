#!/usr/bin/env python3
"""PS/2 DEVICE link layer (keyboard / mouse side) for one engine; the device's behaviour (scan codes, answers to commands) is host software
(host/ps2_test.py has a keyboard). Pins: CLK = logical pin 0, DATA = logical pin 1, both open drain (claim the pads with the open-drain bit):
SETH releases a line, SETLO pulls it low.

Device -> host (TX word, low 8 bits = byte): wait until the bus is idle (CLK and DATA high), then send an 11-bit frame - start (0), D0..D7, odd
parity, stop (1) - with 40 us clock low and 40 us clock high (12.5 kHz), data changing 20 us before the clock falls. If the host pulls the clock low
during the frame (inhibit) the device stops, releases DATA and sends the whole byte again when the bus is idle. 500 us between bytes.
Host -> device: the host holds CLK low for 100 us or more, pulls DATA low and releases CLK (request to send). The device then clocks the 11 bits
(start .. stop) in, samples DATA in the middle of each clock low, pulls DATA low in a 12th clock (acknowledge) and pushes one RX word:
[7:0] the byte, [8] parity error, [9] framing error (start bit not 0 or stop bit not 1).
Timing windows (IBM PS/2 interface, Adam Chapweske's "PS/2 Mouse/Keyboard Protocol"): clock low and high 30..50 us, data setup 5..25 us before the
falling edge and hold 5..25 us after the rising edge.
"""
import asm as A

CLK, DATA = 0, 1
US = 50                                    # clocks per microsecond at 50 MHz


def ps2_device(mut=()):
    """mut: planted bugs: even_parity, msb_first, no_inhibit, no_ack, fast_clock, no_retry, late_sample, no_stop."""
    t_low = (10 if "fast_clock" in mut else 40) * US - 1          # WAIT operand: operand + 1 clocks
    t_half = t_low // 2
    t_setup = 20 * US - 1
    a = A.Asm()
    a.CFG(out_pin=DATA, in_pin=DATA, osr_msb=1 if "msb_first" in mut else 0, isr_msb=0)
    a.SETH(CLK); a.SETH(DATA)
    a.DIRO(CLK); a.DIRO(DATA)
    a.LDI(5, 0)                                                   # r5: a byte to send again (0x100 | byte)

    a.label("main")
    a.JPL(CLK, "host")                                            # the host holds the clock low: inhibit or a command
    a.JPL(DATA, "rx")                                             # clock released while data is low: request to send
    a.ALU("TST", 5, imm=0x100); a.JCC("NZ", "retry")
    a.RGET(0, "FIFO"); a.ALU("AND", 0, imm=7); a.JCC("Z", "main")  # nothing queued
    a.RGET(1, "TXF"); a.ALU("AND", 1, imm=0xFF)                   # r1 = the byte (a word is there: RGET TXF does not wait)
    a.JMP("send")
    a.label("retry")
    a.ALU("MOV", 1, rs=5); a.ALU("AND", 1, imm=0xFF); a.LDI(5, 0)

    a.label("send")
    a.JPL(CLK, "hold"); a.JPL(DATA, "hold")                       # the bus is not idle: keep the byte
    a.ALU("PAR", 2, rs=1)                                         # 1 if the byte has an odd number of ones
    if "even_parity" not in mut:
        a.ALU("XOR", 2, imm=1)                                    # odd parity: the parity bit is 1 when the data has an even number of ones
    a.ALU("SHL", 2, imm=9)
    a.ALU("MOV", 3, rs=1); a.ALU("SHL", 3, imm=1); a.ALU("OR", 3, rs=2)
    if "no_stop" not in mut:
        a.ALU("OR", 3, imm=0x400)
    a.RPUT("OSR", 3)
    a.SETL(11)
    a.label("tbit")
    a.OUT1(0)                                                     # DATA <- the next frame bit (open drain: 1 = released)
    a.WAIT(t_setup)
    if "no_inhibit" not in mut:
        a.JPL(CLK, "abort")                                       # inhibit: the host wants the line
    a.SETLO(CLK); a.WAIT(t_low); a.SETH(CLK)
    a.WAIT(t_setup)                                               # data hold, then the next bit
    a.DJNZ("tbit")
    a.SETH(DATA)
    a.WAIT(500 * US - 1)
    a.JMP("main")
    a.label("abort")
    a.SETH(DATA)
    if "no_retry" not in mut:
        a.ALU("MOV", 5, rs=1); a.ALU("OR", 5, imm=0x100)
    a.JMP("main")
    a.label("hold")
    a.ALU("MOV", 5, rs=1); a.ALU("OR", 5, imm=0x100)
    a.JMP("main")

    a.label("host")
    a.WAITH(CLK)                                                  # until the host releases the clock
    a.JPH(DATA, "main")                                           # data high: it was only an inhibit
    a.label("rx")
    a.WAIT(20 * US - 1)
    a.SETL(11)
    a.label("rbit")                                               # 11 clocks: the device generates them, the host changes DATA while the clock is high
    if "late_sample" in mut:                                      # samples after the clock rose, when the host is already changing DATA
        a.SETLO(CLK); a.WAIT(t_low); a.SETH(CLK); a.WAIT(30 * US - 1); a.IN1(0); a.WAIT(10 * US - 1)
    else:
        a.SETLO(CLK); a.WAIT(t_half); a.IN1(0); a.WAIT(t_low - t_half); a.SETH(CLK); a.WAIT(t_low)
    a.DJNZ("rbit")
    if "no_ack" not in mut:
        a.SETLO(DATA); a.WAIT(t_setup)                            # acknowledge: DATA low during a 12th clock
    a.SETLO(CLK); a.WAIT(t_low); a.SETH(CLK)
    a.SETH(DATA)
    a.WAIT(100 * US - 1)
    a.RGET(0, "ISR"); a.ALU("SHR", 0, imm=21)                     # r0 = start, D0..D7, parity, stop
    a.ALU("MOV", 1, rs=0); a.ALU("SHR", 1, imm=1); a.ALU("AND", 1, imm=0xFF)
    a.ALU("PAR", 2, rs=1)
    a.ALU("MOV", 3, rs=0); a.ALU("SHR", 3, imm=9); a.ALU("AND", 3, imm=1)
    a.ALU("XOR", 2, rs=3); a.ALU("XOR", 2, imm=1)                 # 1 if the parity is wrong (data ones + parity bit must be odd)
    a.ALU("SHL", 2, imm=8); a.ALU("OR", 1, rs=2)
    a.ALU("MOV", 3, rs=0); a.ALU("AND", 3, imm=1)                 # start bit must be 0
    a.ALU("MOV", 4, rs=0); a.ALU("SHR", 4, imm=10); a.ALU("XOR", 4, imm=1)   # stop bit must be 1
    a.ALU("OR", 3, rs=4); a.ALU("SHL", 3, imm=9); a.ALU("OR", 1, rs=3)
    a.RPUT("RXF", 1)
    a.JMP("main")
    return a.words()


if __name__ == "__main__":
    print(f"ps2 device firmware: {len(ps2_device())} words")
