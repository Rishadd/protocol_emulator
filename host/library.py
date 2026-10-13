#!/usr/bin/env python3
"""Resident protocol library in L2 (docs/TWO_TIER_MEMORY_PLAN.md steps 7.4, 7.6).

build() packs every verified protocol into one L2 image. Each protocol is stored as its L1 image (L1
addresses) plus an installer: COPY image -> L1 0, JMP 0. A dispatcher at the reset vector PULLs one
command word and jumps to the installer it selects (JPO, command bits MSB first):
    command(k), k = 0 UART TX, 1 UART RX, 2 SPI master, 3 SPI slave, 4 I2C master, 5 I2C slave. The
    dispatcher runs before any CFG, so the OSR is LSB-first: bit 0 of the word is the first JPO (MSB of k).
So the host loads the library once; to change protocol it sets RUN 0 -> 1 (reset vector = dispatcher)
and writes one command word; the engine installs the protocol itself (about n + 4 clocks).
"""
import isa
import link
import i2c_prog as ip
import spi_prog as sp
import uart_rx_prog as urx
import uart_workload as uw

D = round(uw.F_CLK / 115200) - 2
PROTOS = [("uart_tx", lambda: uw.uart_tx_program(D)[:12]),
          ("uart_rx", lambda: [w for w, _ in urx.uart_rx_program(D)]),
          ("spi_master", lambda: sp.master(0)),
          ("spi_slave", lambda: sp.slave(0)),
          ("i2c_master", lambda: ip.master(400)),
          ("i2c_slave", lambda: ip.slave(400)["l1"][:50])]


def build(l2_base=0):
    images = [(n, f()) for n, f in PROTOS]
    p = [(".l2",), ("lab", "disp"), ("PULL", 0)]
    # binary tree on the 3 command bits: JPO consumes one bit per level
    p += [("JPO", "b1"), ("JPO", "b01"), ("JPO", "i1"), ("JMP", "i0"),
          ("lab", "b01"), ("JPO", "i3"), ("JMP", "i2"),
          ("lab", "b1"), ("JPO", "b11"), ("JPO", "i5"), ("JMP", "i4"),
          ("lab", "b11"), ("JMP", "disp")]                          # 6, 7: unknown -> wait for another
    for k, (n, ws) in enumerate(images):
        p += [("lab", f"i{k}"), ("COPY", (f"img{k}", 0, len(ws))), ("JMP", 0)]
    for k, (n, ws) in enumerate(images):
        p += [("lab", f"img{k}")] + [(isa.NAME[w >> 27], _operand(w)) for w in ws]
    prog = link.link(p, l2_base)
    prog["rv"] = prog["sym"]["disp"]
    prog["images"] = dict(images)
    return prog


def _operand(w):
    """Re-express a word for link(): operands as encoded (JPH/JPL/COPY need tuples)."""
    m, a = isa.NAME[w >> 27], w & 0x7FFFFFF
    if m in ("JPH", "JPL"):
        return (a >> 9, a & 511)
    if m == "COPY":
        return (a & 255, a >> 8 & 63, (a >> 14 & 63) + 1)
    return a


def command(k):
    return (k >> 2 & 1) | (k >> 1 & 1) << 1 | (k & 1) << 2       # MSB of k first, OSR LSB-first


if __name__ == "__main__":
    lib = build()
    print(f"library: {len(lib['l2'])} L2 words (of 256), dispatcher at {lib['rv']:#05x}")
    for k, (n, ws) in enumerate(lib["images"].items()):
        print(f"  {k} {n:11s} {len(ws):3d} words, image at {lib['sym'][f'img{k}']:#05x}, installer {lib['sym'][f'i{k}']:#05x}")
