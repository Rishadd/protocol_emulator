#!/usr/bin/env python3
"""Host side of the logic analyser (register window 0x0300, src/la_block.v). Needs frame v2 (the buffer readout is v2 only).
    la = LogicAnalyserHost(chip)            # chip: a ChipHost (or ShmemHost)
    la.configure(trig="rise", chan=3, post_words=20)
    la.arm(); ... la.wait_done() ...; words = la.read_buffer()      # oldest word first
    changes, end = la.waveform()            # [(clock, 16-bit value)] and the capture length in clocks (change mode)
The decoding and the VCD writer are in la_model.py."""
import la_model as LM

LA_BASE = 0x0300
CTRL, CONFIG, PATTERN, DIV, POST, TRIGCNT, PTR, DATA, TS = (LA_BASE + 4 * i for i in range(9))
TRIG = {"manual": 0, "pattern": 1, "rise": 2, "fall": 3, "sw": 4}
DEPTH = 256


class LogicAnalyserHost:
    def __init__(self, chip):
        self.chip = chip
        self.cfg = dict(mode="change", div=1, sel=0)

    def configure(self, mode="change", div=1, sel=0, trig="manual", mask=0, value=0, chan=0, post_words=0, post_clk=0):
        """Every field of the capture; the unit must not be running. Raises HostError if the chip refuses a write."""
        c = self.chip
        self.cfg = dict(mode=mode, div=div, sel=sel)
        c.write2(CONFIG, (mode == "sample") | sel << 1 | TRIG[trig] << 2 | chan << 5)
        c.write2(PATTERN, value << 16 | mask)
        c.write2(DIV, div)
        c.write2(POST, post_clk << 16 | post_words)

    def arm(self):
        self.chip.write2(CTRL, 1)

    def trigger(self):
        self.chip.write2(CTRL, 2)

    def status(self):
        v = self.chip.read2(CTRL)
        return dict(state=LM.STATE_NAMES[v & 3], full=v >> 2 & 1, wrapped=v >> 3 & 1, wp=v >> 8 & 0xFF, trig_wp=v >> 16 & 0xFF,
                    trig_cnt=self.chip.read2(TRIGCNT) & 0xFFFF)

    def wait_done(self, max_polls=2000):
        for _ in range(max_polls):
            if self.status()["state"] == "done":
                return True
        return False

    def read_buffer(self):
        """The captured words, oldest first (a wrapped ring is unrolled starting at the write pointer)."""
        st = self.status()
        n = DEPTH if st["full"] else st["wp"]
        start = st["wp"] if st["wrapped"] else 0
        self.chip.write2(PTR, start % DEPTH)
        res = self.chip.pipeline2([(0x82, DATA, 0)] * n)           # one frame per word
        return [r.data for r in res]                             # a wrapped ring was read from the write pointer on: oldest first

    def waveform(self):
        return LM.decode_change(self.read_buffer())
