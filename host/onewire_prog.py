#!/usr/bin/env python3
"""1-Wire master (standard speed) for the engine, with the ROM / scratchpad CRC-8 checked by the CRC unit.
DQ = pin 2, open-drain (a 1 releases the line; the bus has a pull-up). Needs the register / ALU / CRC extension.

Host TX words (one command each; op in bits [31:28], data in [7:0]):
  1 RESET          reset pulse + presence sample  -> RX word EV | 0x100 | presence (1 = a device answered)
  2 WRITE byte     8 write slots, LSB first
  3 READ           8 read slots, LSB first         -> RX word = the byte (0..255); the byte is also fed to the CRC unit
  4 CRC RESET      CRC register <- init
  5 CRC CHECK      -> RX word EV | 0x200 | ok, ok = 1 when the CRC over everything fed since the last CRC RESET is 0
                   (a 1-Wire ROM or scratchpad including its CRC byte gives 0)
Timing (us, standard speed): reset low 500, presence sampled 70 after release, slot 70; write 1 = low 6; write 0 = low 60;
read = low 6, sample 13 after the falling edge. `t` overrides the numbers (used by the mutation tests).
"""
import argparse

from asm import Asm

DQ = 2
EV = 1 << 26
CRC_MAXIM = [("POLY", 0x31), ("INIT", 0), ("XOR", 0), ("FMT", 7 | 1 << 5 | 1 << 6)]      # CRC-8/MAXIM-DOW
T = dict(reset_low=500, pres_wait=70, reset_rest=410, w1_low=6, w1_rest=64, w0_low=60, w0_rest=10,
         r_low=6, r_wait=7, r_rest=57)


def us(x):
    return int(x * 50) - 2            # WAIT n occupies n + 1 clocks; one more for the SETLO/SETH commit


def onewire_master(t=None, crc_cfg=None, mut=()):
    t = dict(T, **(t or {}))
    a = Asm()
    a.CFG(out_pin=DQ, in_pin=DQ)                                     # OSR / ISR LSB first
    a.SETH(DQ); a.DIRO(DQ)                                           # released
    for op, v in (crc_cfg or CRC_MAXIM):
        a.LDI(2, v); a.CRC(op, 2)
    a.LDI(6, 0x40000); a.ALU("SHL", 6, imm=8)                        # R6 = EV
    a.label("cmd")
    a.RGET(0, "TXF"); a.ALU("MOV", 1, rs=0); a.ALU("SHR", 1, imm=28)
    for k, lab in ((1, "reset"), (2, "wbyte"), (3, "rbyte"), (4, "crcrst"), (5, "crcchk")):
        a.ALU("CMP", 1, imm=k); a.JCC("Z", lab)
    a.JMP("cmd")                                                     # unknown op: ignored
    # ---- reset + presence
    a.label("reset")
    a.SETLO(DQ); a.WAIT(us(t["reset_low"])); a.SETH(DQ); a.WAIT(us(t["pres_wait"]))
    a.RGET(3, "PIN"); a.ALU("AND", 3, imm=1 << DQ)
    a.ALU("MOV", 5, rs=6); a.ALU("OR", 5, imm=0x100)
    a.ALU("CMP", 3, imm=0); a.JCC("NZ", "nopres"); a.ALU("OR", 5, imm=1)
    a.label("nopres"); a.RPUT("RXF", 5); a.WAIT(us(t["reset_rest"])); a.JMP("cmd")
    # ---- write byte
    a.label("wbyte"); a.RPUT("OSR", 0); a.SETL(8)
    a.label("wb"); a.JPO("w1")
    a.SETLO(DQ); a.WAIT(us(t["w0_low"])); a.SETH(DQ); a.WAIT(us(t["w0_rest"])); a.DJNZ("wb"); a.JMP("cmd")
    a.label("w1")
    a.SETLO(DQ); a.WAIT(us(t["w1_low"])); a.SETH(DQ); a.WAIT(us(t["w1_rest"])); a.DJNZ("wb"); a.JMP("cmd")
    # ---- read byte
    a.label("rbyte"); a.SETL(8)
    a.label("rb")
    a.SETLO(DQ); a.WAIT(us(t["r_low"])); a.SETH(DQ); a.WAIT(us(t["r_wait"])); a.IN1(0); a.WAIT(us(t["r_rest"])); a.DJNZ("rb")
    a.RGET(2, "ISR"); a.ALU("SHR", 2, imm=24)
    if "no_feed" not in mut:
        a.CRC("BYTE", 2)
    a.RPUT("RXF", 2); a.JMP("cmd")
    # ---- CRC
    a.label("crcrst"); a.CRC("RST"); a.JMP("cmd")
    a.label("crcchk"); a.RGET(3, "CRC"); a.ALU("MOV", 5, rs=6); a.ALU("OR", 5, imm=0x200)
    a.ALU("CMP", 3, imm=0); a.JCC("NZ", "bad"); a.ALU("OR", 5, imm=1)
    a.label("bad"); a.RPUT("RXF", 5); a.JMP("cmd")
    return a.words()


def cmd_word(op, data=0):
    return op << 28 | data


if __name__ == "__main__":
    argparse.ArgumentParser().parse_args()
    from asm import disasm
    ws = onewire_master()
    print(f"1-Wire master: {len(ws)} words")
    for i, w in enumerate(ws):
        print(f"  {i:3d}  {w:08X}  {disasm(w)}")
