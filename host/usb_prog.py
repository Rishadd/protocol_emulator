#!/usr/bin/env python3
"""USB low-speed DEVICE firmware for one engine (docs/USB_LS_PLAN.md): a packet shuttle. The chip handles the bus; the host software
(host/usb_device_host.py) decides what the device is by composing the packets it sends.

On the chip (this firmware, built on the line coder, docs/LINE_CODER.md):
  receive   SYNC, PID with its check bits, tokens (address filter, endpoint 0 / 1), SETUP data with CRC16 check
  answer    IN: the pending packet if it is for that endpoint, else NAK;  SETUP data, OUT data: ACK;  a packet is kept and sent again on
            every IN until the host acknowledges it
  bus       bus reset (SE0 for about 3 us or more): address back to 0, pending packet dropped
Not done on the chip: token CRC5 is not checked; OUT data is acknowledged but not passed on; one pending packet at a time (a SETUP drops it).

Host <-> engine FIFOs (32-bit words, depth 4):
  engine -> host (RX FIFO), events:
      0x01000000 + 3 words      SETUP: word0 = (bmRequestType, bRequest) in bits 31:16, word1 = wValue, wIndex, word2 = wLength + CRC16 in 31:16
                                (the three words are the last 12 bytes of the shift chain: bytes 0-7 of the request are at word0[31:16],
                                 word1, word2[15:0])
      hdr (0x03xxxxxx)          the pending packet was acknowledged: the same header word the host sent
      0x04000000                bus reset seen
  host -> engine (TX FIFO), 4-word items pushed only as a whole:
      word0 = header: [7:0] N bytes of the packet (1..11, PID + data + CRC, without SYNC), [15:8] endpoint, [23:16] kind, [31:24] 0x03
                      kind 0 = packet:  words 1..3 = the N bytes, 4 per word, first byte in the low byte of word 1
                      kind 1 = set the device address to word0[31:24]  (words 1..3 ignored); header 0x01_aa_00_00 | ...
"""
import asm as A

PID_SETUP, PID_IN, PID_OUT, PID_ACK, PID_NAK, PID_DATA0, PID_DATA1 = 0x2D, 0x69, 0xE1, 0xD2, 0x5A, 0xC3, 0x4B
RESIDUE = 0x4FFE                      # CRC unit value (CRC-16/USB, after the final XOR) over SETUP data + its CRC = 0xB001 ^ 0xFFFF
EV_SETUP, EV_RESET = 0x01000000, 0x04000000
HDR_TYPE = 0x03000000


def getb(a, lbl, abort):
    """r0 <- next received byte; jump to `abort` if the packet ends first."""
    a.label(lbl)
    a.RGET(0, "LINE")
    a.ALU("TST", 0, imm=0x300)
    a.JCC("Z", lbl)
    a.ALU("TST", 0, imm=0x100)
    a.JCC("Z", abort)
    a.ALU("AND", 0, imm=0xFF)


def wait_eop(a, lbl):
    a.label(lbl)
    a.RGET(0, "LINE")
    a.ALU("TST", 0, imm=0xA00)                # end of packet or error
    a.JCC("Z", lbl)


def build():
    a = A.Asm()
    # ---- initialisation: CRC unit = CRC-16/USB; the line coder keeps its reset configuration (D+ = pin 0, D- = pin 1, NRZI, stuffing 6, 1.5 Mbit/s)
    a.LDI(0, 0x8005); a.CRC("POLY", 0)
    a.LDI(0, 0xFFFF); a.CRC("INIT", 0); a.CRC("XOR", 0)
    a.LDI(0, 0x6F);   a.CRC("FMT", 0)

    a.label("main")
    a.LDI(0, 3); a.LINE("RXCTL", 0)               # receiver on, flags cleared
    a.LDI(6, 0)                                   # consecutive SE0 polls
    a.label("idle")
    a.RGET(0, "LINE")
    a.ALU("TST", 0, imm=0x100); a.JCC("NZ", "got")
    a.ALU("MOV", 5, rs=0); a.ALU("SHR", 5, imm=15); a.ALU("AND", 5, imm=3)       # {D+, D-}
    a.JCC("Z", "se0")
    a.LDI(6, 0)
    a.label("chk")                                # load the next item from the host when nothing is pending
    a.ALU("TST", 1, imm=0xFF); a.JCC("NZ", "idle")
    a.RGET(0, "FIFO"); a.ALU("AND", 0, imm=7); a.ALU("CMP", 0, imm=4); a.JCC("NC", "idle")
    a.RGET(1, "TXF"); a.RGET(2, "TXF"); a.RGET(3, "TXF"); a.RGET(4, "TXF")
    a.ALU("MOV", 0, rs=1); a.ALU("SHR", 0, imm=16); a.ALU("AND", 0, imm=0xFF)
    a.JCC("Z", "idle")                            # kind 0: a packet is pending now
    a.ALU("MOV", 7, rs=1); a.ALU("SHR", 7, imm=24); a.LDI(1, 0); a.JMP("idle")    # kind 1: new device address

    a.label("se0")                                # SE0 on the bus: a bus reset when it lasts (an EOP is only 2 bit times)
    a.ALU("ADD", 6, imm=1); a.ALU("CMP", 6, imm=20); a.JCC("NC", "idle")
    a.LDI(7, 0); a.LDI(1, 0)
    a.RGET(0, "FIFO"); a.ALU("SHR", 0, imm=3); a.ALU("AND", 0, imm=7); a.ALU("CMP", 0, imm=4); a.JCC("C", "rst_w")
    a.PUSHI(EV_RESET)
    a.label("rst_w")
    a.RGET(0, "LINE"); a.ALU("SHR", 0, imm=15); a.ALU("AND", 0, imm=3); a.JCC("Z", "rst_w")
    a.JMP("main")

    # ---- a packet starts: r0 = first byte (PID)
    a.label("got")
    a.ALU("AND", 0, imm=0xFF)
    a.ALU("MOV", 6, rs=0)                         # the PID byte is compared as a whole below, so a damaged check nibble is not a known PID
    a.ALU("CMP", 6, imm=PID_SETUP); a.JCC("Z", "tok")
    a.ALU("CMP", 6, imm=PID_IN);    a.JCC("Z", "tok")
    a.ALU("CMP", 6, imm=PID_OUT);   a.JCC("Z", "tok")
    a.ALU("CMP", 6, imm=PID_ACK);   a.JCC("Z", "ack")
    a.label("drain")                              # not for us / not understood: wait for its end
    wait_eop(a, "drn")
    a.JMP("main")

    # ---- token: two bytes = address (7) + endpoint (4) + CRC5 (5)
    a.label("tok")
    a.SETL(2)
    a.label("tk1")
    getb(a, "tk1w", "main")
    a.ALU("SHR", 5, imm=8); a.ALU("SHL", 0, imm=8); a.ALU("OR", 5, rs=0)
    a.DJNZ("tk1")
    a.ALU("AND", 5, imm=0xFFFF)
    a.ALU("MOV", 0, rs=5); a.ALU("AND", 0, imm=0x7F); a.ALU("CMP", 0, rs=7); a.JCC("NZ", "drain")       # not our address
    a.ALU("SHR", 5, imm=7); a.ALU("AND", 5, imm=15)                                                    # r5 = endpoint
    a.ALU("CMP", 5, imm=2); a.JCC("C", "drain")                                                         # only endpoints 0 and 1
    wait_eop(a, "tke")
    a.LDI(0, 3); a.LINE("RXCTL", 0)
    a.ALU("CMP", 6, imm=PID_IN);  a.JCC("Z", "in_h")
    a.ALU("CMP", 6, imm=PID_OUT); a.JCC("Z", "out_h")

    # ---- SETUP (endpoint 0): DATA0 with 8 bytes + CRC16
    a.ALU("CMP", 5, imm=0); a.JCC("NZ", "main")
    getb(a, "sp1", "main")
    a.ALU("CMP", 0, imm=PID_DATA0); a.JCC("NZ", "main")
    a.CRC("RST", 0)
    a.LDI(1, 0); a.LDI(2, 0); a.LDI(3, 0); a.LDI(4, 0)                    # the pending packet is dropped
    a.SETL(10)
    a.label("sp2")
    getb(a, "sp2w", "main")
    a.CRC("BYTE", 0)
    a.ALU("MOV", 5, rs=3); a.ALU("SHL", 5, imm=24); a.ALU("SHR", 2, imm=8); a.ALU("OR", 2, rs=5)     # 96-bit shift chain r2 <- r3 <- r4 <- byte
    a.ALU("MOV", 5, rs=4); a.ALU("SHL", 5, imm=24); a.ALU("SHR", 3, imm=8); a.ALU("OR", 3, rs=5)
    a.ALU("SHL", 0, imm=24); a.ALU("SHR", 4, imm=8); a.ALU("OR", 4, rs=0)
    a.DJNZ("sp2")
    wait_eop(a, "spe")
    a.RGET(0, "CRC"); a.ALU("CMP", 0, imm=RESIDUE); a.JCC("NZ", "main")          # damaged: no answer, the host repeats
    a.RGET(0, "FIFO"); a.ALU("SHR", 0, imm=3); a.ALU("AND", 0, imm=7); a.JCC("NZ", "main")   # RX FIFO not empty: no room for the event
    a.PUSHI(EV_SETUP); a.RPUT("RXF", 2); a.RPUT("RXF", 3); a.RPUT("RXF", 4)
    a.JMP("send_ack")

    # ---- OUT: take the data packet, acknowledge it (the data is not passed on)
    a.label("out_h")
    wait_eop(a, "oud")
    a.JMP("send_ack")

    # ---- IN: send the pending packet if it is for this endpoint, else NAK
    a.label("in_h")
    a.ALU("TST", 1, imm=0xFF); a.JCC("Z", "send_nak")
    a.ALU("MOV", 0, rs=1); a.ALU("SHR", 0, imm=8); a.ALU("AND", 0, imm=0xFF); a.ALU("CMP", 0, rs=5); a.JCC("NZ", "send_nak")
    a.WAIT(150)                                   # inter-packet delay: the EOP ends 100 clocks after its SE0 starts, the answer must start 2 .. 7.5 bit times (66 .. 250 clocks) later
    a.LDI(0, 0x80); a.LINE("TXB", 0)
    a.ALU("MOV", 6, rs=1); a.ALU("AND", 6, imm=0xFF)
    a.SETL(12)
    a.label("snd")                                # 12 rotations of the 96-bit chain: N bytes are sent, the chain is back in place afterwards
    a.ALU("CMP", 6, imm=0); a.JCC("Z", "rot")
    a.LINE("TXB", 2); a.ALU("SUB", 6, imm=1)
    a.label("rot")
    a.ALU("MOV", 5, rs=2); a.ALU("SHL", 5, imm=24)
    a.ALU("MOV", 0, rs=3); a.ALU("SHL", 0, imm=24); a.ALU("SHR", 2, imm=8); a.ALU("OR", 2, rs=0)
    a.ALU("MOV", 0, rs=4); a.ALU("SHL", 0, imm=24); a.ALU("SHR", 3, imm=8); a.ALU("OR", 3, rs=0)
    a.ALU("SHR", 4, imm=8); a.ALU("OR", 4, rs=5)
    a.DJNZ("snd")
    a.LINE("TXE", 0)
    a.JMP("main")

    # ---- ACK from the host: the pending packet is delivered
    a.label("ack")
    wait_eop(a, "ake")
    a.ALU("TST", 1, imm=0xFF); a.JCC("Z", "main")
    a.RGET(0, "FIFO"); a.ALU("SHR", 0, imm=3); a.ALU("AND", 0, imm=7); a.ALU("CMP", 0, imm=4); a.JCC("C", "main")    # no room: keep it
    a.RPUT("RXF", 1); a.LDI(1, 0); a.JMP("main")

    # ---- handshakes
    a.label("send_nak"); a.LDI(6, PID_NAK); a.JMP("send_hs")
    a.label("send_ack"); a.LDI(6, PID_ACK)
    a.label("send_hs")
    a.WAIT(150)
    a.LDI(0, 0x80); a.LINE("TXB", 0); a.LINE("TXB", 6); a.LINE("TXE", 0)
    a.JMP("main")
    return a


def words():
    return build().words()


if __name__ == "__main__":
    a = build()
    w = a.words()
    print(f"usb device firmware: {len(w)} of 256 words")
