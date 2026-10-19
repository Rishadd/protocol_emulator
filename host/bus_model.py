#!/usr/bin/env python3
"""Reactive bus models around the cycle-exact engine model (host/isa_model.py), for protocols where the test bench must answer what the
engine does clock by clock (the host peer sees the engine's edges and reacts). Same style as host/usb_model_link.py.

  OpenDrainBus(program, pins=2)     wired-AND bus with pull-ups (PS/2, I2C style): a pin is low if the engine drives it low (pin enable set and
                                    output 0) or the peer pulls it low; otherwise it is high.
        bus.pull(pin, low)           the peer pulls a pin low / releases it
        bus.levels()                 tuple of the pin levels now
        bus.step(n)                  advance n system clocks (1 clock = 20 ns)
        bus.until_change(max)        advance until any pin changes (or max clocks); returns the clocks run
        bus.put(word) / bus.get()    the host FIFO side of the engine (TX words in, RX words out)
        bus.log                      [(clock, levels)] every change, for post-hoc timing analysis
"""
import isa_model as M


class OpenDrainBus:
    def __init__(self, program, pins=2):
        self.e = M.Engine(program)
        self.pins = pins
        self.peer_low = [0] * pins
        self.clock = 0
        self.log = []
        self._levels = self._compute()
        self.log.append((0, self._levels))

    def _compute(self):
        po, pe = self.e.pins()
        out = []
        for i in range(self.pins):
            dev_low = bool(pe >> i & 1) and not (po >> i & 1)
            out.append(0 if (dev_low or self.peer_low[i]) else 1)
        return tuple(out)

    def levels(self):
        return self._levels

    def pull(self, pin, low=True):
        self.peer_low[pin] = int(bool(low))
        self._note()

    def _note(self):
        lv = self._compute()
        if lv != self._levels:
            self._levels = lv
            self.log.append((self.clock, lv))

    def step(self, n=1):
        for _ in range(int(n)):
            pin_in = sum(l << i for i, l in enumerate(self._levels))
            self.e.step(pin_in=pin_in)
            self.clock += 1
            self._note()

    def until_change(self, max_clocks):
        lvl = self._levels
        k = 0
        while k < max_clocks and self._levels == lvl:
            self.step(1)
            k += 1
        return k

    def put(self, word):
        if len(self.e.tx) >= 4:
            return False
        self.e.tx.append(word & 0xFFFFFFFF)
        return True

    def get(self):
        return self.e.rx.pop(0) if self.e.rx else None
