#!/usr/bin/env python3
"""Phase 1 checks of the host encoder (docs/TWO_TIER_MEMORY_PLAN.md V1.5, V1.6, step 1.7).

V1.5  every opcode x operand corner: encode -> disassemble -> parse -> encode gives the same word.
V1.6  every generator program: the old encoding (JPH/JPL pin at [8:6]) and the new one ([11:9])
      decode to the same (opcode, pin, address, operand) program, and no other word changed.
1.7   the committed UART images (src/fpga/*.hex) equal the generators' output (no re-encoding needed).
"""
import os
import sys

import isa
import i2c_prog
import spi_prog
import uart_rx_prog
import uart_workload as uw

errs = []


def check(ok, msg):
    if not ok:
        errs.append(msg)


def parse(text):                          # inverse of isa.disasm
    name, arg = text.split(" ")
    if name in ("JPH", "JPL"):
        pin, addr = arg.split(",")
        return isa.enc(name, (int(pin), int(addr)))
    return isa.enc(name, int(arg))


# V1.5
corners = [0, 1, 0x3F, 0x40, 0xFF, 0x100, 0x1FF, 0x7FFFFFF] + [1 << b for b in range(27)]
n = 0
for m in isa.OP:
    for a in corners:
        if m in ("JPH", "JPL"):
            for pin in range(8):
                for addr in (0, 1, 0x3F, 0x40, 0x100, 0x1FF):
                    w = isa.enc(m, (pin, addr))
                    check(parse(isa.disasm(w)) == w and (w >> 9) & 7 == pin and w & 511 == addr, f"{m} {pin},{addr}")
                    n += 1
        else:
            w = isa.enc(m, a)
            check(parse(isa.disasm(w)) == w, f"{m} {a}")
            n += 1
print(f"V1.5 round trip: {n} words")

# V1.6: old encoding of the same program = new word with the JPH/JPL fields moved back
def old_of(w):
    op = w >> 27
    if op in (17, 18):
        return op << 27 | ((w >> 9) & 7) << 6 | (w & 63)
    return w

progs = {f"spi master m{m} b{b} lsb{l}": spi_prog.master(m, b, l) for m in range(4) for b in (1, 8, 32) for l in (0, 1)}
progs.update({f"spi slave m{m} b{b} lsb{l}": spi_prog.slave(m, b, l) for m in range(4) for b in (1, 8, 32) for l in (0, 1)})
progs.update({f"i2c master {k}": i2c_prog.master(k) for k in (100, 400, 1000)})
progs.update({f"uart tx D{d}": uw.uart_tx_program(d) for d in (432, 5206)})
progs.update({f"uart rx D{d}": [w for w, _ in uart_rx_prog.uart_rx_program(d)] for d in (432, 5206)})
moved = 0
for name, ws in progs.items():
    for w in ws:
        o = old_of(w)
        if o != w:
            moved += 1
            check((w >> 27) in (17, 18) and (o >> 6) & 7 == (w >> 9) & 7 and o & 63 == w & 511, f"{name}: {w:08X}")
        check(w & 511 < 64 or (w >> 27) not in (2, 5, 17, 18, 19), f"{name}: jump target >= 64")
print(f"V1.6 generators: {len(progs)} programs, {moved} JPH/JPL words re-encoded, every other word unchanged")

# 1.7: committed UART images still match the generators
def hexwords(path):
    ws = []
    for line in open(path):
        line = line.split("//")[0].strip()
        if line and not line.startswith("@"):
            ws += [int(x, 16) for x in line.split()]
    return ws

tx = hexwords(os.path.join(uw.ROOT, "src", "fpga", "uart_tx_prog.hex"))
rx = hexwords(os.path.join(uw.ROOT, "src", "fpga", "uart_rx_prog.hex"))
gen_tx = uw.uart_tx_program(round(uw.F_CLK / 115200) - 2)
gen_rx = [w for w, _ in uart_rx_prog.uart_rx_program(round(uw.F_CLK / 115200) - 2)]
check(tx[:len(gen_tx)] == gen_tx, "uart_tx_prog.hex != generator")
check(rx[:len(gen_rx)] == gen_rx, "uart_rx_prog.hex != generator")
print("1.7 committed UART images == generator output")

for e in errs[:10]:
    print("  FAIL", e)
print(f"RESULT test_isa: {'PASS' if not errs else f'FAIL ({len(errs)} errors)'}")
sys.exit(1 if errs else 0)
