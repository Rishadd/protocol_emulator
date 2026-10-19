#!/usr/bin/env python3
"""Planted-bug check of the USB firmware: every mutant of host/usb_prog.py must make host/usb_test.py fail (on the engine model, seconds each).
  python3 host/usb_mutants.py
A mutant that still passes means a hole in usb_test.py. (old text, new text, description); the old text must occur exactly once.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
SRC = os.path.join(HERE, "usb_prog.py")
WORK = os.path.join(ROOT, "build", "usb_mut")

MUTANTS = [
    ('a.ALU("CMP", 0, rs=7); a.JCC("NZ", "drain")', 'a.ALU("CMP", 0, rs=7)', "address filter off"),
    ('a.ALU("CMP", 5, imm=2); a.JCC("C", "drain")', 'a.ALU("CMP", 5, imm=3); a.JCC("C", "drain")', "endpoint 2 is accepted"),
    ('a.RGET(0, "CRC"); a.ALU("CMP", 0, imm=RESIDUE); a.JCC("NZ", "main")', 'a.RGET(0, "CRC"); a.ALU("CMP", 0, imm=RESIDUE)', "SETUP data CRC16 not checked"),
    ('a.RPUT("RXF", 1); a.LDI(1, 0); a.JMP("main")', 'a.RPUT("RXF", 1); a.JMP("main")', "an ACKed packet stays pending"),
    ('a.SETL(12)\n    a.label("snd")', 'a.SETL(11)\n    a.label("snd")', "packet chain not restored after sending (the retransmission is damaged)"),
    ('a.WAIT(150)                                   # inter-packet delay', 'a.WAIT(20)                                    # inter-packet delay', "IN answered before the EOP ended"),
    ('    a.WAIT(150)\n    a.LDI(0, 0x80); a.LINE("TXB", 0); a.LINE("TXB", 6)', '    a.WAIT(500)\n    a.LDI(0, 0x80); a.LINE("TXB", 0); a.LINE("TXB", 6)', "handshake answered too late (over 7.5 bit times)"),
    ('a.ALU("CMP", 6, imm=20); a.JCC("NC", "idle")', 'a.ALU("CMP", 6, imm=2); a.JCC("NC", "idle")', "an EOP is taken for a bus reset"),
    ('a.ALU("CMP", 6, imm=20); a.JCC("NC", "idle")', 'a.ALU("CMP", 6, imm=2000); a.JCC("NC", "idle")', "a bus reset is never recognised"),
    ('a.ALU("CMP", 0, rs=5); a.JCC("NZ", "send_nak")', 'a.ALU("CMP", 0, rs=5)', "a packet for endpoint 1 is sent on an endpoint 0 token"),
    ('    a.LDI(0, 0x80); a.LINE("TXB", 0); a.LINE("TXB", 6); a.LINE("TXE", 0)', '    a.LDI(0, 0x81); a.LINE("TXB", 0); a.LINE("TXB", 6); a.LINE("TXE", 0)', "wrong SYNC in handshakes"),
    ('    a.ALU("MOV", 7, rs=1); a.ALU("SHR", 7, imm=24)', '    a.ALU("MOV", 6, rs=1); a.ALU("SHR", 6, imm=24)', "set-address item ignored"),
    ('    a.ALU("TST", 1, imm=0xFF); a.JCC("Z", "send_nak")', '    a.ALU("TST", 1, imm=0xFF)', "IN with nothing pending sends garbage instead of NAK"),
    ('a.ALU("CMP", 0, imm=PID_DATA0); a.JCC("NZ", "main")', 'a.ALU("CMP", 0, imm=PID_DATA0)', "SETUP data accepted with any PID"),
    ('a.PUSHI(EV_SETUP); a.RPUT("RXF", 2); a.RPUT("RXF", 3); a.RPUT("RXF", 4)', 'a.PUSHI(EV_SETUP); a.RPUT("RXF", 2); a.RPUT("RXF", 4); a.RPUT("RXF", 3)', "SETUP event words in the wrong order"),
    ('    a.LDI(7, 0); a.LDI(1, 0)\n    a.RGET(0, "FIFO")', '    a.LDI(1, 0)\n    a.RGET(0, "FIFO")', "bus reset leaves the old address"),
    ('a.ALU("CMP", 6, imm=PID_IN);    a.JCC("Z", "tok")', 'a.ALU("CMP", 6, imm=PID_IN & 0x0F);    a.JCC("Z", "tok")', "IN token compared without its check nibble"),
    ('0xD2, 0x5A, 0xC3', '0xD2, 0x5B, 0xC3', "NAK with a wrong PID"),
]


def main():
    text = open(SRC).read()
    os.makedirs(WORK, exist_ok=True)
    caught = invalid = 0
    for i, (old, new, desc) in enumerate(MUTANTS):
        if text.count(old) != 1:
            print(f"  MUTANT {i:2d} INVALID ({text.count(old)} matches): {desc}")
            invalid += 1
            continue
        path = os.path.join(WORK, f"usb_prog_m{i}.py")
        with open(path, "w") as f:
            f.write(text.replace(old, new).replace("import asm as A", f"import sys\nsys.path.insert(0, {HERE!r})\nimport asm as A"))
        try:
            r = subprocess.run([sys.executable, os.path.join(HERE, "usb_test.py")], capture_output=True, text=True, timeout=600,
                               env=dict(os.environ, USB_PROG_FILE=path))
            fail = "RESULT usb_test (model): PASS" not in r.stdout
        except subprocess.TimeoutExpired:
            fail = True
        caught += fail
        print(f"  MUTANT {i:2d} {'caught ' if fail else 'MISSED '} {desc}")
    total = len(MUTANTS)
    print(f"usb firmware mutants caught: {caught}/{total - invalid}" + (f" ({invalid} invalid)" if invalid else ""))
    return 0 if caught == total - invalid and not invalid else 1


if __name__ == "__main__":
    sys.exit(main())
