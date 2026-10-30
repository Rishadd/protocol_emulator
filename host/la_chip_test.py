#!/usr/bin/env python3
"""Logic analyser on the real chip RTL (-DSHARED_IMEM -DLA) through the SPI link: python3 host/la_chip_test.py
Registers and their refusals, a capture of known pin activity read back through the buffer window and decoded (values and the clock distances
between the changes must equal what the stimulus did), sample mode, TSTAMP (the clock distance between two reads is the model's), the engine trigger
line (RPUT TRIG shows on channel 15, is the software trigger, drops when the engine is held), the done IRQ (IRQ bit 8 -> uo_out[1]) and the debug view.
Expected values come from the stimulus and from host/isa_model.py, not from the RTL."""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import asm as A                                           # noqa: E402
import isa_model as M                                     # noqa: E402
import la_host as L                                       # noqa: E402
import la_model as LM                                     # noqa: E402
import shmem_host as S                                    # noqa: E402
from chip_host import SimLink, HostError, OP2_READ, OP2_WRITE   # noqa: E402

errs = 0


def check(name, cond, extra=""):
    global errs
    if not cond:
        errs += 1
        print("  FAIL", name, extra)


def tstamp_prog():
    a = A.Asm()
    a.REGION()
    a.TSTAMP(0)
    a.WAIT(9)
    a.TSTAMP(1)
    a.ALU("SUB", 1, 0)                # r1 = r1 - r0
    a.RPUT("RXF", 1)
    a.HALT()
    return a


def trig_prog():
    a = A.Asm()
    a.REGION()
    a.LDI(0, 1)
    a.WAIT(49)
    a.RPUT("TRIG", 0)                 # the trigger line goes high
    a.WAIT(29)
    a.LDI(1, 0)
    a.RPUT("TRIG", 1)                 # and low again 32 clocks later
    a.HALT()
    return a


def trig_hold_prog():
    a = A.Asm()
    a.REGION()
    a.LDI(0, 1)
    a.RPUT("TRIG", 0)
    a.HALT()
    return a


def main():
    with SimLink(shared=True, la=True) as link:
        chip = S.ShmemHost(link)
        la = L.LogicAnalyserHost(chip)
        chip.set_misc(irq_mask=0x100, dbg_en=0, view=6)

        # ---- registers: reset values, read back, refusals
        r = lambda addr: chip.read2(addr)                     # noqa: E731
        check("reset: state idle", r(L.CTRL) & 3 == 0)
        check("reset: DIV = 1", r(L.DIV) == 1)
        la.configure(trig="rise", chan=3, post_words=3, mask=0x00FF, value=0x5A)
        check("CONFIG reads back", r(L.CONFIG) == (2 << 2 | 3 << 5), hex(r(L.CONFIG)))
        check("PATTERN reads back", r(L.PATTERN) == 0x5A << 16 | 0xFF)
        check("POST reads back", r(L.POST) == 3)
        check("write to the reserved CONFIG bit refused", chip.cmd2(OP2_WRITE, L.CONFIG, 1 << 9).code == 4)
        check("trigger type 5 refused", chip.cmd2(OP2_WRITE, L.CONFIG, 5 << 2).code == 4)
        check("CTRL reserved bit refused", chip.cmd2(OP2_WRITE, L.CTRL, 4).code == 4)
        check("word 9 of the window is a bad address", chip.cmd2(OP2_WRITE, L.LA_BASE + 36, 0).code == 2)
        check("TS is read only", chip.cmd2(OP2_WRITE, L.TS, 0).code == 4)
        t1 = r(L.TS)
        t2 = r(L.TS)
        check("TS counts", 0 < t2 - t1 < 20000 and t2 > t1, f"{t1} {t2}")
        check("v1 read of DATA is refused (v2 only)", (chip.read(L.DATA), chip.status().err)[1] == 1)
        chip.clear_err()

        # ---- a capture of known activity: rising edge of uio[3], 3 words (the trigger word counts)
        link.set_inputs(uio_in=0x00)
        la.arm()
        check("armed", la.status()["state"] == "armed")
        check("DATA read while capturing: BUSY", chip.cmd2(OP2_READ, L.DATA).code == 1)
        check("CONFIG write while capturing refused", chip.cmd2(OP2_WRITE, L.CONFIG, 0).code == 4)
        check("view 6: armed", link.pins()["uo_out"] >> 2 & 0x3F == 0b000001, hex(link.pins()["uo_out"]))
        link.wait(50)
        link.set_inputs(uio_in=0x08)
        link.wait(30)
        link.set_inputs(uio_in=0x09)
        link.wait(20)
        link.set_inputs(uio_in=0x0B)
        link.wait(40)
        link.set_inputs(uio_in=0x0A)
        link.wait(100)
        check("capture completed", la.wait_done())
        st = la.status()
        check("4 words (start state + 3 post words), trigger word is index 1", st["wp"] == 4 and st["trig_wp"] == 1 and not st["full"], str(st))
        check("view 6: done", link.pins()["uo_out"] >> 2 & 0x3F == 0b000110, hex(link.pins()["uo_out"]))
        check("IRQ bit 8 set", r(0x02C4) >> 8 & 1 == 1)
        check("uo_out[1] (IRQ) high", link.pins()["uo_out"] >> 1 & 1 == 1)
        chip.write2(0x02C4, 0x100)
        check("IRQ bit 8 cleared (write one to clear)", r(0x02C4) >> 8 & 1 == 0)
        check("uo_out[1] (IRQ) low again", link.pins()["uo_out"] >> 1 & 1 == 0)
        words = la.read_buffer()
        changes, end = LM.decode_change(words)
        check("values 0, 8, 9, B", [v for _, v in changes] == [0x0000, 0x0008, 0x0009, 0x000B], str([hex(v) for _, v in changes]))
        d1, d2 = changes[2][0] - changes[1][0], changes[3][0] - changes[2][0]
        check("clock distances 30 and 20 (same pin latency on every edge)", (d1, d2) == (30, 20), f"{d1} {d2}")
        check("trig_cnt = clocks since the previous word", la.status()["trig_cnt"] == changes[1][0] - changes[0][0])
        check("reading DATA advanced PTR by the words read", r(L.PTR) == 4, str(r(L.PTR)))
        vcd = LM.vcd(changes, end)
        got, _ = LM.parse_vcd(vcd)
        check("VCD round trip", got == changes)

        # ---- sample mode: constant pins, every word is four equal samples
        link.set_inputs(uio_in=0xA5)
        la.configure(mode="sample", div=4, sel=0, trig="manual", post_words=2)
        la.arm()
        link.wait(300)
        la.trigger()
        check("sample capture completed", la.wait_done())
        w = la.read_buffer()
        check("sample words are 0xA5A5A5A5", len(w) >= 3 and all(x == 0xA5A5A5A5 for x in w), str([hex(x) for x in w[:4]]))
        link.set_inputs(uio_in=0x00)

        # ---- TSTAMP on an engine
        img = S.Image.from_asm("ts", tstamp_prog(), origin=0)
        chip.start(0, img)
        c0 = chip.wait_halt(0)
        check("TSTAMP program halted cleanly", c0["halted"] and not c0["fault"])
        sm = M.SharedImem(); sm.load(0, img.words)
        e = M.Engine([], shared=sm)
        for _ in range(40):
            e.step()
        check("TSTAMP difference equals the model's", chip.pop_rx(0) == e.rx[0] == 11, str(e.rx))
        chip.stop(0)

        # ---- the engine trigger line: RPUT TRIG shows on channel 15 and is the software trigger
        la.configure(trig="sw", post_words=2)
        la.arm()
        chip.start(0, S.Image.from_asm("trig", trig_prog(), origin=0))
        check("trigger capture completed", la.wait_done())
        changes, end = LM.decode_change(la.read_buffer())
        vals = [v for _, v in changes]
        check("channel 15 rises (with RUN0 on channel 13) and falls", vals == [0x0000, 0x2000, 0xA000, 0x2000], str([hex(v) for v in vals]))
        d = changes[2][0] - changes[1][0]
        check("RUN to the first RPUT TRIG: about 52 clocks", 50 <= d <= 56, str(d))
        check("trigger line high for exactly 32 clocks", changes[3][0] - changes[2][0] == 32, str(changes[3][0] - changes[2][0]))
        chip.stop(0)

        # ---- the trigger line stays high while the engine halts with it high, and drops when the engine is held
        chip.start(0, S.Image.from_asm("th", trig_hold_prog(), origin=0))
        chip.wait_halt(0)
        la.configure(trig="manual", post_words=1)
        la.arm(); la.trigger(); la.wait_done()
        check("halted engine keeps the line high: first word 0x2000|0x8000", la.read_buffer()[0] >> 16 == 0xA000)
        chip.stop(0)
        la.arm(); la.trigger(); la.wait_done()
        check("held engine: trigger line low, RUN low", la.read_buffer()[0] >> 16 == 0x0000)

    print("RESULT la_chip_test:", "PASS" if not errs else f"FAIL ({errs})")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
