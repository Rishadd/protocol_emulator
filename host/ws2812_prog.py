#!/usr/bin/env python3
"""WS2812 / NeoPixel LED strip driver for the engine (single-wire, 800 kHz, no clock): one TX word per LED.

Timing at 50 MHz (1 clock = 20 ns), bit period 62 clocks = 1.24 us:
    '0'  high 20 clocks (0.40 us), low 42 clocks (0.84 us)        '1'  high 40 clocks (0.80 us), low 22 clocks (0.44 us)
WS2812B datasheet windows: T0H 0.40 +-0.15, T1H 0.80 +-0.15, T0L 0.85 +-0.15, T1L 0.45 +-0.15 us, reset = low for more than 50 us.

Host -> engine words (TX FIFO):
    LED data   bits [31:8] = the 24 colour bits in the order the strip wants them (G7..G0 R7..R0 B7..B0), sent MSB first; bits [7:1] = 0, bit 0 = 0
    latch      bit 0 = 1: the line is held low for 60 us (the strip latches the data it has shifted in)
Pin: logical pin 0 (push-pull). The end of one word to the start of the next adds about 0.1 us to the last low time, still inside the window.
"""
import asm as A

PIN = 0
T_HIGH0, T_HIGH1 = 18, 38           # WAIT operands: high time = operand + 2 clocks (20 and 40)
T_LOW0, T_LOW1 = 38, 18             # low time = operand + 4 clocks (42 and 22)
LATCH_CLOCKS = 3000                 # 60 us


def led_word(g, r, b):
    return ((g & 0xFF) << 24) | ((r & 0xFF) << 16) | ((b & 0xFF) << 8)


LATCH_WORD = 1


def ws2812(mut=()):
    """mut: planted bugs for the tests: lsb_first, long_t0h, short_t1h, no_latch, short_latch, no_msb."""
    h0 = 30 if "long_t0h" in mut else T_HIGH0
    h1 = 24 if "short_t1h" in mut else T_HIGH1
    a = A.Asm()
    a.CFG(out_pin=PIN, osr_msb=0 if ("lsb_first" in mut or "no_msb" in mut) else 1)
    a.SETLO(PIN)
    a.DIRO(PIN)
    a.label("next")
    a.PULL()
    if "no_latch" not in mut:
        a.RGET(0, "OSR")
        a.ALU("TST", 0, imm=1)
        a.JCC("NZ", "latch")
    a.SETL(24)
    a.label("bit")
    a.JPO("one")
    a.SETH(PIN); a.WAIT(h0); a.SETLO(PIN); a.WAIT(T_LOW0); a.DJNZ("bit"); a.JMP("next")
    a.label("one")
    a.SETH(PIN); a.WAIT(h1); a.SETLO(PIN); a.WAIT(T_LOW1); a.DJNZ("bit"); a.JMP("next")
    if "no_latch" not in mut:
        a.label("latch")
        a.SETLO(PIN)
        a.LDI(1, 1000 if "short_latch" in mut else LATCH_CLOCKS)
        a.WAITR(1)
        a.JMP("next")
    return a.words()


if __name__ == "__main__":
    print(f"ws2812 firmware: {len(ws2812())} words")
