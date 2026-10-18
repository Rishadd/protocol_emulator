#!/usr/bin/env python3
"""Generic CRC (Rocksoft model) used as the oracle for src/crc_unit.v and for every protocol that uses it.

  CRC(width, poly, init, refin, refout, xorout)
    reset()        register <- init
    feed_bit(b)    one bit, as given (bit order is the caller's)
    feed_byte(v)   8 bits: refin ? LSB first : MSB first
    value()        final value: (refout ? reflect(register) : register) ^ xorout

The models in CATALOGUE come with the published check value for the ASCII string "123456789" (Greg Cook's catalogue of
parametrised CRC algorithms). They are *not* derived from the RTL. `python host/crc_model.py` checks every model against its
check value and against zlib.crc32 / binascii.crc_hqx, and runs the unit-config word helpers.

Config words for the CRC instruction (docs/ALU_CRC_I2CSLAVE_PLAN.md section 3.1):
  FMT = (width-1) | refin << 5 | refout << 6 ; POLY, INIT, XOROUT are written as plain values.
"""
import binascii
import random
import zlib


def reflect(v, n):
    r = 0
    for i in range(n):
        if v >> i & 1:
            r |= 1 << (n - 1 - i)
    return r


class CRC:
    def __init__(self, width, poly, init=0, refin=False, refout=False, xorout=0):
        assert 1 <= width <= 32
        self.width, self.poly, self.init = width, poly, init
        self.refin, self.refout, self.xorout = refin, refout, xorout
        self.mask = (1 << width) - 1
        self.reset()

    def reset(self):
        self.reg = self.init & self.mask

    def feed_bit(self, b):
        top = self.reg >> (self.width - 1) & 1
        self.reg = (self.reg << 1) & self.mask
        if top ^ (b & 1):
            self.reg ^= self.poly & self.mask

    def feed_byte(self, v):
        v &= 0xFF
        order = range(8) if self.refin else range(7, -1, -1)
        for i in order:
            self.feed_bit(v >> i & 1)

    def value(self):
        r = reflect(self.reg, self.width) if self.refout else self.reg
        return (r ^ self.xorout) & self.mask

    def of(self, data):
        self.reset()
        for b in data:
            self.feed_byte(b)
        return self.value()

    def fmt_word(self):
        return (self.width - 1) | int(self.refin) << 5 | int(self.refout) << 6

    def config_words(self):
        """(poly, init, xorout, fmt) as the four register values the firmware writes with CRC POLY/INIT/XOROUT/FMT."""
        return self.poly & self.mask, self.init & self.mask, self.xorout & self.mask, self.fmt_word()


# name: (width, poly, init, refin, refout, xorout, check)
CATALOGUE = {
    "CRC-4/G-704":      (4, 0x3, 0x0, True, True, 0x0, 0x7),
    "CRC-5/USB":        (5, 0x05, 0x1F, True, True, 0x1F, 0x19),
    "CRC-7/MMC":        (7, 0x09, 0x00, False, False, 0x00, 0x75),
    "CRC-8/SMBUS":      (8, 0x07, 0x00, False, False, 0x00, 0xF4),
    "CRC-8/MAXIM-DOW":  (8, 0x31, 0x00, True, True, 0x00, 0xA1),
    "CRC-15/CAN":       (15, 0x4599, 0x0000, False, False, 0x0000, 0x059E),
    "CRC-16/MODBUS":    (16, 0x8005, 0xFFFF, True, True, 0x0000, 0x4B37),
    "CRC-16/USB":       (16, 0x8005, 0xFFFF, True, True, 0xFFFF, 0xB4C8),
    "CRC-16/CCITT-FALSE": (16, 0x1021, 0xFFFF, False, False, 0x0000, 0x29B1),
    "CRC-16/XMODEM":    (16, 0x1021, 0x0000, False, False, 0x0000, 0x31C3),
    "CRC-16/KERMIT":    (16, 0x1021, 0x0000, True, True, 0x0000, 0x2189),
    "CRC-32/ISO-HDLC":  (32, 0x04C11DB7, 0xFFFFFFFF, True, True, 0xFFFFFFFF, 0xCBF43926),
    "CRC-32C":          (32, 0x1EDC6F41, 0xFFFFFFFF, True, True, 0xFFFFFFFF, 0xE3069283),
    "CRC-32/MPEG-2":    (32, 0x04C11DB7, 0xFFFFFFFF, False, False, 0x00000000, 0x0376E6E7),
}


def make(name):
    w, p, i, ri, ro, xo, _ = CATALOGUE[name]
    return CRC(w, p, i, ri, ro, xo)


def selftest():
    errs = 0
    msg = b"123456789"
    for name, (w, p, i, ri, ro, xo, chk) in CATALOGUE.items():
        got = make(name).of(msg)
        ok = got == chk
        errs += not ok
        print(f"  {name:20s} check {chk:#0{2 + (w + 3) // 4}x} got {got:#0{2 + (w + 3) // 4}x} {'ok' if ok else 'FAIL'}")
    # cross-checks against the standard library (independent implementations)
    rnd = random.Random(1)
    for _ in range(200):
        data = bytes(rnd.randrange(256) for _ in range(rnd.randrange(0, 40)))
        if make("CRC-32/ISO-HDLC").of(data) != zlib.crc32(data):
            errs += 1
            print("  FAIL vs zlib.crc32", data.hex())
        if make("CRC-16/XMODEM").of(data) != binascii.crc_hqx(data, 0):
            errs += 1
            print("  FAIL vs binascii.crc_hqx", data.hex())
        if make("CRC-16/CCITT-FALSE").of(data) != binascii.crc_hqx(data, 0xFFFF):
            errs += 1
            print("  FAIL ccitt-false vs crc_hqx", data.hex())
    # bit feeding of a byte equals byte feeding (refin LSB first, else MSB first)
    for name in CATALOGUE:
        a, b = make(name), make(name)
        for v in (0x00, 0xFF, 0xA5, 0x3C):
            a.feed_byte(v)
            for k in (range(8) if a.refin else range(7, -1, -1)):
                b.feed_bit(v >> k & 1)
        if a.value() != b.value():
            errs += 1
            print("  FAIL bit/byte mismatch", name)
    # appending the CRC (transmitted in the model's own bit order) must give a constant residue for the non-reflected models:
    c = make("CRC-16/CCITT-FALSE")
    d = b"hello world"
    v = c.of(d)
    c.reset()
    for byte in d + v.to_bytes(2, "big"):
        c.feed_byte(byte)
    if c.reg != 0:
        errs += 1
        print("  FAIL ccitt residue")
    # Modbus: CRC appended low byte first gives residue 0
    c = make("CRC-16/MODBUS")
    d = bytes([0x01, 0x03, 0x00, 0x00, 0x00, 0x0A])
    v = c.of(d)
    if v != 0xCDC5:
        errs += 1
        print("  FAIL known Modbus frame 01 03 00 00 00 0A -> C5 CD, got", hex(v))
    c.reset()
    for byte in d + bytes([v & 0xFF, v >> 8]):
        c.feed_byte(byte)
    if c.reg != 0:
        errs += 1
        print("  FAIL modbus residue")
    print(f"RESULT crc_model: {'PASS' if not errs else 'FAIL (%d)' % errs}")
    return errs


if __name__ == "__main__":
    raise SystemExit(1 if selftest() else 0)
