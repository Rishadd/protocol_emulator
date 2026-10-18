#!/usr/bin/env python3
"""Modbus RTU framing over UART for the engine: CRC-16/MODBUS from the CRC unit, byte counting with the ALU, the 3.5-character
inter-frame silence with WAITR. 8N1, LSB first (the CRC-16 goes out low byte first). Needs the register / ALU / CRC extension.

  modbus_tx(cpb)  engine 0, TX on pin 0.  Host TX words per frame: [N, b0 .. bN-1] (low 8 bits of each word). The engine sends the
                  N payload bytes, then the CRC low byte, CRC high byte, then waits 3.5 characters before it takes the next frame.
  modbus_rx(cpb)  engine 1, RX on pin `rx_pin`. Every received byte is pushed to the host as a plain word (0..255). A frame ends after
                  3.5 character times of silence; then one event word is pushed:  EV | ok << 8 | byte_count,  ok = 1 when at least
                  4 bytes arrived and the CRC over all of them (CRC included) is zero.
cpb = clocks per bit (434 at 115200 baud, 50 MHz). Character = 11 bit times (Modbus), so the silence is 38.5 bit times.
"""
import argparse

from asm import Asm
from spi_prog import write_hex
import crc_model as cm

EV = 1 << 26
MODBUS = cm.make("CRC-16/MODBUS")
CRC_CFG = [("POLY", 0x8005), ("INIT", 0xFFFF), ("XOR", 0x0000), ("FMT", 0x6F)]     # width 16, refin, refout


def _crc_setup(a, cfg=None):
    for op, val in (cfg or CRC_CFG):
        a.LDI(2, val)
        a.CRC(op, 2)


def silence_cycles(cpb):
    return 44 * cpb                          # the sender waits 4 characters (44 bit times): the receiver ends a frame after 3.5 characters (38.5 bit times) of silence


def modbus_tx(cpb=434, tx_pin=0, crc_cfg=None, sil_scale=1.0, swap_crc=False):
    D = cpb - 2
    a = Asm()
    a.CFG(out_pin=tx_pin)                                   # OSR LSB first
    a.SETH(tx_pin); a.DIRO(tx_pin)
    _crc_setup(a, crc_cfg)
    a.LDI(7, int(silence_cycles(cpb) * sil_scale))
    a.label("frame")
    a.RGET(0, "TXF")                                        # N
    a.CRC("RST")
    a.ALU("MOV", 1, rs=0)                                   # R1 = payload bytes left
    a.LDI(2, 0)                                             # R2 = CRC bytes sent
    a.label("loop")
    a.ALU("CMP", 1, imm=0); a.JCC("NZ", "payload")
    a.ALU("CMP", 2, imm=2); a.JCC("Z", "done")
    a.RGET(3, "CRC"); a.ALU("CMP", 2, imm=1 if swap_crc else 0); a.JCC("Z", "lo")      # swap_crc: test mutant (high byte first)
    a.ALU("SHR", 3, imm=8); a.JMP("crcsend")
    a.label("lo");  a.ALU("AND", 3, imm=0xFF)
    a.label("crcsend"); a.ALU("ADD", 2, imm=1); a.JMP("send")
    a.label("payload"); a.RGET(3, "TXF"); a.CRC("BYTE", 3); a.ALU("SUB", 1, imm=1)
    a.label("send")
    a.RPUT("OSR", 3); a.SETL(8); a.SETLO(tx_pin); a.WAIT(D)         # start bit
    a.label("bit"); a.OUT1(D); a.DJNZ("bit")                         # 8 data bits
    a.SETH(tx_pin); a.WAIT(D); a.JMP("loop")                         # stop bit
    a.label("done"); a.WAITR(7); a.JMP("frame")                      # 3.5 character silence
    return a.words()


def modbus_rx(cpb=434, rx_pin=1, crc_cfg=None, iters_scale=1.0, min_bytes=4):
    D = cpb - 2
    W = round(1.5 * cpb) - 4
    iters = round(38.5 * cpb / 3 * iters_scale)           # poll loop = 3 clocks; counted from the end of the stop bit
    a = Asm()
    a.CFG(in_pin=rx_pin)                                    # ISR LSB first
    _crc_setup(a, crc_cfg)
    a.LDI(6, 0x40000); a.ALU("SHL", 6, imm=8)               # R6 = EV
    a.label("frame")
    a.CRC("RST"); a.LDI(2, 0)                               # R2 = bytes received
    a.WAITH(rx_pin); a.WAITL(rx_pin); a.JMP("byte")         # first start bit (the pin synchronizer resets to 0: wait for idle first)
    a.label("next"); a.LDI(4, iters)
    a.label("poll"); a.JPL(rx_pin, "byte"); a.ALU("SUB", 4, imm=1); a.JCC("NZ", "poll")
    # silence: frame is over
    a.RGET(3, "CRC")
    a.ALU("CMP", 2, imm=min_bytes); a.JCC("NC", "bad")              # fewer than 4 bytes
    a.ALU("CMP", 3, imm=0); a.JCC("NZ", "bad")              # residue must be zero
    a.ALU("MOV", 5, rs=6); a.ALU("OR", 5, imm=0x100); a.ALU("OR", 5, rs=2); a.RPUT("RXF", 5); a.JMP("frame")
    a.label("bad"); a.ALU("MOV", 5, rs=6); a.ALU("OR", 5, rs=2); a.RPUT("RXF", 5); a.JMP("frame")
    a.label("byte"); a.SETL(8); a.WAIT(W)
    a.label("rbit"); a.IN1(D); a.DJNZ("rbit")
    a.RGET(3, "ISR"); a.ALU("SHR", 3, imm=24); a.CRC("BYTE", 3)     # LSB first: the byte is in [31:24]
    a.RPUT("RXF", 3); a.ALU("ADD", 2, imm=1)
    a.WAIT(round(0.5 * cpb) - 8)                                     # to the end of the stop bit (the last data bit was sampled 1.5 bit times before it)
    a.JMP("next")                                                    # then poll for the next start bit or the silence
    return a.words()


def frame_bytes(payload):
    c = cm.make("CRC-16/MODBUS")
    v = c.of(bytes(payload))
    return list(payload) + [v & 0xFF, v >> 8]


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--cpb", type=int, default=434)
    a = ap.parse_args()
    from asm import disasm
    for name, ws in (("TX", modbus_tx(a.cpb)), ("RX", modbus_rx(a.cpb))):
        print(f"Modbus RTU {name}: {len(ws)} words @ {a.cpb} clocks/bit")
        for i, w in enumerate(ws):
            print(f"  {i:3d}  {w:08X}  {disasm(w)}")
