#!/usr/bin/env python3
"""Fast stand-in for SimLink in the USB tests: the cycle-exact engine model (host/isa_model.py, with the line coder) instead of the RTL, on
the same low-speed bus model as tb/tb_host_bridge.v (uio[0] = D+, uio[1] = D-; device drives when its pin enable is set, else the host,
else the bus idles as J). Same methods as SimLink's USB part (wait, host_drive, run_until_change) plus the FIFO side
(put / get) that the device software uses instead of the SPI management link. Used to develop and debug the firmware in seconds; the
final runs go through the RTL (SimLink).
"""
import isa_model as M


class ModelLink:
    def __init__(self, program):
        self.e = M.Engine(program)
        self.h_dp, self.h_dm, self.h_oe = 0, 1, 0
        self.clocks = 0
        self.bus = self._bus()

    def _bus(self):
        po, pe = self.e.pins()
        dp = (po & 1) if pe & 1 else (self.h_dp if self.h_oe else 0)
        dm = (po >> 1 & 1) if pe & 2 else (self.h_dm if self.h_oe else 1)
        both = int(bool(self.h_oe and pe & 3))
        return dp, dm, both

    def host_drive(self, dp, dm, oe=1):
        self.h_dp, self.h_dm, self.h_oe = dp, dm, oe
        self.bus = self._bus()

    def _tick(self):
        dp, dm, _ = self.bus
        self.e.step(pin_in=dp | dm << 1)
        self.clocks += 1
        self.bus = self._bus()

    def wait(self, n):
        for _ in range(int(n)):
            self._tick()

    def run_until_change(self, max_clocks):
        lvl = self.bus[:2]
        k = 0
        while k < max_clocks and self.bus[:2] == lvl:
            self._tick()
            k += 1
        return k, self.bus[:2], self.bus[2]

    def usb(self, on=True):
        pass

    # ---- the FIFO side (what the SPI management link does on the chip)
    def put(self, word):
        if len(self.e.tx) >= 4:
            return False
        self.e.tx.append(word & 0xFFFFFFFF)
        return True

    def get(self):
        return self.e.rx.pop(0) if self.e.rx else None

    def pump(self, clocks):
        self.wait(clocks)
