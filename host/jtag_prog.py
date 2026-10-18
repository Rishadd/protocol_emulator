#!/usr/bin/env python3
"""JTAG (IEEE 1149.1) controller for the engine. TCK = pin 3, TMS = pin 4, TDI = pin 5, TDO = pin 6 (input). Push-pull outputs.
Needs the register / ALU extension (variable scan lengths and chunking use the ALU, RPUT LC and RGET).

Host TX words (op in [31:28]):
  1  TMS sequence   [27:24] = n (1..15 clocks), [15:0] = TMS bits, bit 0 first; TDI = 0
  2  SCAN           [15:0] = number of bits n (1..65535), bit 16 = last: TMS = 1 on the final bit (leaves Shift-xR for Exit1-xR).
                    Followed by ceil(n / 32) data words (TDI, bit 0 of word 0 first). The controller returns ceil(n / 32) RX words:
                    TDO as sampled at each rising TCK, bit 0 of word 0 = first bit shifted out; a partial last word is right-aligned.
  3  IDLE clocks    [15:0] = n clocks with TMS = 0
`half` = clocks per half TCK period (TCK period = 2 * half + 2 clocks; half = 10 gives about 2 MHz at 50 MHz).
TDO is sampled right as TCK rises (the synchronizer delay puts the sampled value just before the edge): the device changes TDO on
the falling edge, so the value is stable.
"""
import argparse

from asm import Asm

TCK, TMS, TDI, TDO = 3, 4, 5, 6


def jtag_master(half=10, mut=()):
    h = max(half - 3, 0)
    a = Asm()
    a.CFG(out_pin=TDI, in_pin=TDO)                                   # OSR / ISR LSB first
    for p in (TCK, TMS, TDI):
        a.SETLO(p)
    for p in (TCK, TMS, TDI):
        a.DIRO(p)
    a.label("cmd")
    a.RGET(0, "TXF"); a.ALU("MOV", 1, rs=0); a.ALU("SHR", 1, imm=28)
    a.ALU("CMP", 1, imm=1); a.JCC("Z", "tms")
    a.ALU("CMP", 1, imm=2); a.JCC("Z", "scan")
    a.ALU("CMP", 1, imm=3); a.JCC("Z", "idle")
    a.JMP("cmd")
    # ---- TMS sequence: R2 = n, R3 = bits
    a.label("tms")
    a.ALU("MOV", 2, rs=0); a.ALU("SHR", 2, imm=24); a.ALU("AND", 2, imm=0xF)
    a.ALU("MOV", 3, rs=0); a.ALU("AND", 3, imm=0xFFFF)
    a.SETLO(TDI)
    a.label("tms_l"); a.ALU("CMP", 2, imm=0); a.JCC("Z", "cmd")
    a.ALU("TST", 3, imm=1); a.JCC("Z", "tm0"); a.SETH(TMS); a.JMP("tm_c")
    a.label("tm0"); a.SETLO(TMS)
    a.label("tm_c"); a.WAIT(h); a.SETH(TCK); a.WAIT(h); a.SETLO(TCK)
    a.ALU("SHR", 3, imm=1); a.ALU("SUB", 2, imm=1); a.JMP("tms_l")
    # ---- idle clocks
    a.label("idle")
    a.ALU("MOV", 2, rs=0); a.ALU("AND", 2, imm=0xFFFF); a.SETLO(TMS); a.SETLO(TDI)
    a.label("idle_l"); a.ALU("CMP", 2, imm=0); a.JCC("Z", "cmd")
    a.WAIT(h); a.SETH(TCK); a.WAIT(h); a.SETLO(TCK); a.ALU("SUB", 2, imm=1); a.JMP("idle_l")
    # ---- scan: R2 = bits left, R4 = last flag
    a.label("scan")
    a.ALU("MOV", 2, rs=0); a.ALU("AND", 2, imm=0xFFFF)
    a.ALU("MOV", 4, rs=0); a.ALU("SHR", 4, imm=16); a.ALU("AND", 4, imm=1)
    a.SETLO(TMS)
    a.label("s_word")
    a.ALU("CMP", 2, imm=0); a.JCC("Z", "cmd")
    a.RGET(3, "TXF"); a.RPUT("OSR", 3)                                # next 32 data bits
    a.LDI(7, 0); a.RPUT("ISR", 7)
    a.ALU("MOV", 6, rs=2); a.ALU("CMP", 6, imm=32); a.JCC("NC", "s_part")     # m = min(32, bits left)
    a.LDI(6, 31 if "chunk31" in mut else 32)
    a.label("s_part"); a.RPUT("LC", 6)
    a.label("s_bit")
    a.OUT1(0)                                                         # TDI <- next bit
    if "no_last" not in mut:
        a.ALU("CMP", 2, imm=1); a.JCC("NZ", "s_clk")                  # TMS = 1 on the very last bit of a "last" scan
        a.ALU("TST", 4, imm=1); a.JCC("Z", "s_clk"); a.SETH(TMS)
    a.label("s_clk")
    a.WAIT(h); a.SETH(TCK)
    # TDO only changes on the falling edge, so sampling anywhere in the TCK-high phase reads the same bit; "late_sample" therefore
    # samples after TCK has fallen (the device has already moved on to the next bit), which is the real one-bit-late bug.
    if "late_sample" not in mut:
        a.IN1(0)                                                      # sample TDO at the rising edge
    a.WAIT(h)
    a.SETLO(TCK)
    if "late_sample" in mut:
        a.WAIT(4); a.IN1(0)
    a.ALU("SUB", 2, imm=1); a.DJNZ("s_bit")
    # chunk done: right-align a partial word and hand it to the host
    a.RGET(5, "ISR"); a.ALU("MOV", 7, rs=6); a.LDI(1, 32); a.ALU("SUB", 1, rs=7)
    if "no_align" not in mut:
        a.ALU("SHR", 5, rs=1)
    a.RPUT("RXF", 5)
    a.SETLO(TMS)
    a.JMP("s_word")
    return a.words()


def tms_word(bits, n=None):
    """TMS sequence word from a list of 0/1 (bit 0 clocked first)."""
    n = len(bits) if n is None else n
    v = sum(b << i for i, b in enumerate(bits))
    return 1 << 28 | n << 24 | v


def scan_words(data_bits, last=True):
    """SCAN command + data words for a list of TDI bits (first bit first)."""
    n = len(data_bits)
    ws = [2 << 28 | int(last) << 16 | n]
    for i in range(0, n, 32):
        chunk = data_bits[i:i + 32]
        ws.append(sum(b << k for k, b in enumerate(chunk)))
    return ws


def idle_word(n):
    return 3 << 28 | n


def bits_of(value, n):
    return [value >> i & 1 for i in range(n)]


# ---- standard TAP navigation (starting and ending in Run-Test/Idle unless noted)
TMS_RESET = [1, 1, 1, 1, 1, 0]            # Test-Logic-Reset, then Run-Test/Idle
TMS_TO_SHIFT_DR = [1, 0, 0]               # Select-DR, Capture-DR, Shift-DR
TMS_TO_SHIFT_IR = [1, 1, 0, 0]            # Select-DR, Select-IR, Capture-IR, Shift-IR
TMS_UPDATE_IDLE = [1, 0]                  # from Exit1: Update, Run-Test/Idle


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--half", type=int, default=10)
    ar = ap.parse_args()
    from asm import disasm
    ws = jtag_master(ar.half)
    print(f"JTAG controller: {len(ws)} words (TCK period {2 * ar.half + 2} clocks)")
    for i, w in enumerate(ws):
        print(f"  {i:3d}  {w:08X}  {disasm(w)}")
