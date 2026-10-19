#!/usr/bin/env python3
"""SWD host firmware (host/swd_prog.py) against a reactive SWD TARGET written from the ARM Debug Interface v5 rules (chapter B4: line reset, JTAG-to-
SWD switch, request / turnaround / ACK / data / parity, DP registers, a MEM-AP with memory behind it): the target watches SWCLK edge by edge, samples
SWDIO on rising edges, drives its phases after the falling edges, answers WAIT or FAULT on demand and can corrupt the read parity.
  python host/swd_test.py [run mutants]
A probe in software on top of the FIFOs (retry on WAIT, ABORT after FAULT, posted reads through RDBUFF) turns the pair into a working debug probe:
IDCODE, power-up handshake, memory writes and reads through the AP.
"""
import random
import sys

import isa_model as M
import swd_prog as sp

RESULTS = []
CLK, DIO = sp.CLK, sp.DIO
IDCODE = 0x2BA01477
ACK_OK, ACK_WAIT, ACK_FAULT = 1, 2, 4


def report(name, errs, stats="", expect="pass"):
    ok = bool(errs) == (expect == "fail")
    tag = {"pass": "PASS" if ok else "FAIL", "fail": "DETECTED" if ok else "MISSED"}[expect]
    RESULTS.append((name, ok))
    print(f"  {tag:8s} {name:62s} {stats}")
    if not ok:
        for e in errs[:6] or ["no error was reported"]:
            print(f"           {e}")
    return ok


class Target:
    """DP + MEM-AP + memory, driven by the SWCLK / SWDIO samples. All phases follow ADIv5: request 8 bits, turnaround, ACK (3 bits, LSB first),
    data 32 bits + parity (LSB first), turnaround."""

    def __init__(self):
        self.errs = []
        self.mem = {}
        self.waits = 0                       # answer WAIT to this many requests
        self.fault_next = False
        self.bad_read_parity = False
        self.reset()
        self.requests = 0
        self.log = []

    def reset(self):
        self.mode = "unsynced"               # unsynced -> (line reset seen) -> switch seen -> idle
        self.ones = 0
        self.prev = 0
        self.shift = 0
        self.nshift = 0
        self.state = "idle"
        self.drive = None                    # None = released
        self.switched = False
        self.reset_seen = False
        self.zeros_after_reset = 0
        self.ctrl_stat = 0
        self.select = 0
        self.csw, self.tar = 0x23000002, 0
        self.rdbuff = 0
        self.sticky_err = False
        self.pending_ack = None

    # ---- DP / AP registers (reads return (value, parity_flip_ok))
    def dp_read(self, addr):
        if addr == 0x0:
            return IDCODE
        if addr == 0x4:
            v = self.ctrl_stat
            if v & (1 << 28):
                v |= 1 << 29
            if v & (1 << 30):
                v |= 1 << 31
            return v | (1 << 5 if self.sticky_err else 0)
        if addr == 0x8:
            return self.select
        return self.rdbuff                   # 0xC RDBUFF

    def dp_write(self, addr, val):
        if addr == 0x0:                      # ABORT: bit 2 clears the sticky error flag
            if val & 4:
                self.sticky_err = False
        elif addr == 0x4:
            self.ctrl_stat = val & 0xF0000000
        elif addr == 0x8:
            self.select = val

    def ap_read(self, addr):
        bank, reg = self.select >> 4 & 0xF, addr
        if bank == 0xF and reg == 0xC:
            return 0x04770031                # AP IDR
        if bank == 0 and reg == 0x0:
            return self.csw
        if bank == 0 and reg == 0x4:
            return self.tar
        if bank == 0 and reg == 0xC:         # DRW: posted read - returns the previous value, loads the new one
            prev = self.rdbuff
            self.rdbuff = self.mem.get(self.tar, 0)
            if self.csw & 0x10:
                self.tar += 4
            return prev
        return 0

    def ap_write(self, addr, val):
        bank = self.select >> 4 & 0xF
        if bank == 0 and addr == 0x0:
            self.csw = val
        elif bank == 0 and addr == 0x4:
            self.tar = val
        elif bank == 0 and addr == 0xC:
            self.mem[self.tar] = val
            if self.csw & 0x10:
                self.tar += 4

    # ---- the wire
    def on_rise(self, dio, engine_drives):
        """SWCLK rose: sample what the engine drives."""
        s = self.state
        if s == "idle":
            if not engine_drives:
                return
            if self.ones >= 50 and dio == 0:
                self.reset_seen = True
            self.ones = self.ones + 1 if dio else 0
            if self.reset_seen:
                self.shift = (self.shift >> 1) | (dio << 15)
                self.shift &= 0xFFFF
                if self.shift == 0xE79E:
                    self.switched = True
                    self.reset_seen = False
                    self.ones = 0
                    self.nshift = 0
                    self.shift = 0
            if self.ones >= 50:
                self.reset_seen = True
                self.shift = 0xFFFF
            in_reset_run = self.ones >= 50
            if self.switched and dio == 1 and self.prev == 0 and not in_reset_run:     # a start bit: after the switch sequence, an idle, outside a line reset
                self.state, self.req = "req", [1]
                self.requests += 1
            self.prev = dio
            return
        if s == "req":
            self.req.append(dio)
            if len(self.req) == 8:
                st, ap, rnw, a2, a3, par, stop, park = self.req
                ok = st == 1 and stop == 0 and park == 1 and par == ((ap + rnw + a2 + a3) & 1)
                self.ap, self.rnw, self.addr = ap, rnw, (a2 << 2) | (a3 << 3)
                if not ok:
                    self.errs.append(f"bad request {self.req}")
                    self.state = "idle"
                    self.ones = 0
                    return
                self.state = "turn1"
            return
        if s == "turn1":
            self.state = "ack_next"          # this rising edge is the turnaround
            return
        if s == "ack":
            self.state = "ack"
            return
        if s == "wdata":
            self.wbits.append(dio)
            if len(self.wbits) == 33:
                data = sum(b << i for i, b in enumerate(self.wbits[:32]))
                par = bin(data).count("1") & 1
                if par != self.wbits[32]:
                    self.errs.append("write data parity wrong")
                else:
                    (self.ap_write if self.ap else self.dp_write)(self.addr, data)
                self.state = "idle"
                self.ones = 0
            return

    def on_fall(self):
        """SWCLK fell: the target presents the next bit it drives."""
        s = self.state
        if s == "ack_next":
            # decide the answer now
            if self.waits > 0:
                self.waits -= 1
                ack = ACK_WAIT
            elif self.fault_next:
                self.fault_next = False
                self.sticky_err = True
                ack = ACK_FAULT
            elif self.sticky_err and not (self.ap == 0 and self.rnw == 0 and self.addr == 0):
                ack = ACK_FAULT
            else:
                ack = ACK_OK
            self.ack = ack
            self.out = [(ack >> i) & 1 for i in range(3)]
            self.state = "ack_bits"
        if self.state == "ack_bits":
            if self.out:
                self.drive = self.out.pop(0)
                return
            # after the last ACK bit
            self.drive = None
            if self.ack != ACK_OK:
                self.state = "turn_end"
                return
            if self.rnw:
                val = (self.ap_read if self.ap else self.dp_read)(self.addr)
                par = bin(val).count("1") & 1
                if self.bad_read_parity:
                    par ^= 1
                self.out = [(val >> i) & 1 for i in range(32)] + [par]
                self.state = "rdata"
                self.on_fall()                                         # a read: the first data bit goes out at once (no turnaround after the ACK)
            else:
                self.wbits = []
                self.state = "turn_w"                                  # a write: one turnaround clock first
            return
        if self.state == "rdata":
            if self.out:
                self.drive = self.out.pop(0)
                return
            self.drive = None
            self.state = "turn_end"
            return
        if self.state == "turn_w":
            self.state = "wdata"
            return
        if self.state == "turn_end":
            self.state = "idle"
            self.ones = 0


class Bus:
    def __init__(self, program, target):
        self.e = M.Engine(program)
        self.t = target
        self.clock = 0
        self.clk_log = []                                    # (clock, level) of SWCLK
        self.dio_changes = []                                # (clock, level) of SWDIO as driven by the engine
        self.contention = 0
        self._prev_clk = 0
        self.lv = self._levels()

    def _levels(self):
        po, pe = self.e.pins()
        clk = (po & 1) if pe & 1 else 0
        eng = bool(pe & 2)
        if eng and self.t.drive is not None:
            self.contention += 1
        dio = (po >> 1 & 1) if eng else (self.t.drive if self.t.drive is not None else 1)
        return clk, dio, eng

    def step(self, n=1):
        for _ in range(n):
            clk, dio, eng = self.lv
            self.e.step(pin_in=clk | dio << 1)
            self.clock += 1
            new = self._levels()
            if new[0] != self._prev_clk:
                self.clk_log.append((self.clock, new[0]))
                if new[0]:
                    self.t.on_rise(new[1], new[2])
                else:
                    self.t.on_fall()
                    new = self._levels()                     # the target may have changed its drive
                self._prev_clk = new[0]
            if new[1] != self.lv[1] and new[2]:
                self.dio_changes.append((self.clock, new[1], new[0]))
            self.lv = new

    def put(self, w):
        if len(self.e.tx) >= 4:
            return False
        self.e.tx.append(w & 0xFFFFFFFF)
        return True

    def get(self):
        return self.e.rx.pop(0) if self.e.rx else None


class Probe:
    """A debug probe in software on top of the engine: composes commands, retries on WAIT, recovers from FAULT."""

    def __init__(self, bus):
        self.b = bus
        self.errs = []

    def push(self, w):
        for _ in range(100000):
            if self.b.put(w):
                return
            self.b.step(100)
        raise RuntimeError("TX FIFO stuck")

    def pop(self, max_clocks=400_000):
        for _ in range(max_clocks // 100):
            w = self.b.get()
            if w is not None:
                return w
            self.b.step(100)
        raise RuntimeError("no answer from the engine")

    def connect(self):
        self.push(sp.cmd_reset(True))
        return self.dp_read(0)

    def xfer(self, apndp, rnw, addr, data=None, retries=20):
        for _ in range(retries):
            self.push(sp.cmd_xfer(apndp, rnw, addr))
            if not rnw:
                self.push(data & 0xFFFFFFFF)
            w = self.pop()
            ack = w & 7
            if ack == ACK_WAIT:
                self.b.step(500)
                continue
            if ack == ACK_FAULT:
                self.last_fault = True
                self.push(sp.cmd_xfer(0, 0, 0)); self.push(4)            # ABORT: clear the sticky error
                self.pop()
                raise RuntimeError("FAULT")
            if ack != ACK_OK:
                raise RuntimeError(f"protocol error: ACK 0b{ack:03b}")
            if rnw:
                v = self.pop()
                return v, bool(w & 8)
            return None, False
        raise RuntimeError("WAIT forever")

    def dp_read(self, addr):
        v, perr = self.xfer(0, 1, addr)
        if perr:
            self.errs.append(f"read parity error DP {addr:#x}")
        return v

    def dp_write(self, addr, val):
        self.xfer(0, 0, addr, val)

    def ap_read(self, addr):
        v, perr = self.xfer(1, 1, addr)
        if perr:
            self.errs.append(f"read parity error AP {addr:#x}")
        return v

    def ap_write(self, addr, val):
        self.xfer(1, 0, addr, val)

    def select(self, apsel, bank):
        self.dp_write(0x8, apsel << 24 | bank << 4)

    def powerup(self):
        self.dp_write(0x4, 0x50000000)
        return self.dp_read(0x4)

    def mem_write(self, addr, val):
        self.select(0, 0)
        self.ap_write(0x4, addr)
        self.ap_write(0xC, val)

    def mem_read(self, addr):
        self.select(0, 0)
        self.ap_write(0x4, addr)
        self.ap_read(0xC)                                # posted: the value arrives with the next read
        return self.dp_read(0xC)                         # RDBUFF


def rig(firmware=None):
    t = Target()
    b = Bus(firmware or sp.words(), t)
    b.step(200)
    return b, t, Probe(b)


def timing_errors(b, t):
    errs = []
    rises = [c for c, l in b.clk_log if l]
    falls = [c for c, l in b.clk_log if not l]
    if len(rises) > 10:
        periods = [r2 - r1 for r1, r2 in zip(rises, rises[1:])]
        busy = [p for p in periods if p < 200]
        mean = sum(busy) / len(busy)
        if not 40 <= mean <= 62:
            errs.append(f"SWCLK period {mean:.1f} clocks ({50 / mean:.2f} MHz), expected about 1 MHz")
        # the engine changes SWDIO only while SWCLK is low (target samples on the rising edge)
        bad = [(c, v) for c, v, clk in b.dio_changes if clk == 1]
        if bad:
            errs.append(f"SWDIO driven during the clock high phase {len(bad)} times, first at clock {bad[0][0]}")
    if b.contention:
        errs.append(f"{b.contention} clocks with both sides driving SWDIO")
    errs += t.errs
    return errs


def phase_run():
    print("Phase 1: debug probe against the target model")
    rnd = random.Random(7)
    b, t, p = rig()
    errs = []
    try:
        idc = p.connect()
        if idc != IDCODE:
            errs.append(f"IDCODE 0x{idc:08X}")
        st = p.powerup()
        if (st >> 28) & 0xF != 0xF:
            errs.append(f"power-up handshake incomplete: CTRL/STAT 0x{st:08X}")
        report("line reset, JTAG-to-SWD switch, IDCODE, power-up handshake", errs + p.errs)
        errs = []
        values = {0x20000000 + 4 * i: rnd.getrandbits(32) for i in range(8)}
        for a, v in values.items():
            p.mem_write(a, v)
        for a, v in values.items():
            got = p.mem_read(a)
            if got != v:
                errs.append(f"memory 0x{a:08X}: wrote 0x{v:08X}, read 0x{got:08X}")
        report("8 words written and read back through the AP (posted reads + RDBUFF)", errs + p.errs)
        errs = []
        # block with auto-increment
        p.select(0, 0)
        p.ap_write(0x0, 0x23000012)                       # CSW: word size + auto increment
        p.ap_write(0x4, 0x20000100)
        blk = [rnd.getrandbits(32) for _ in range(16)]
        for v in blk:
            p.ap_write(0xC, v)
        p.ap_write(0x4, 0x20000100)
        p.ap_read(0xC)                                    # posted: the first read only loads the pipeline
        got = [p.ap_read(0xC) for _ in range(16)]         # read i returns word i-1 and loads word i
        if got != blk:
            errs.append("auto-increment block read does not match what was written")
        report("16-word block with auto-increment", errs + p.errs)
        # WAIT handling
        t.waits = 3
        errs = [] if p.dp_read(0x0) == IDCODE else ["IDCODE after WAITs wrong"]
        if t.waits != 0:
            errs.append("the target's WAITs were not consumed")
        report("the target answers WAIT three times, the probe retries and succeeds", errs + p.errs)
        # FAULT handling
        t.fault_next = True
        try:
            p.dp_read(0x4)
            errs = ["no FAULT seen"]
        except RuntimeError as e:
            errs = [] if str(e) == "FAULT" else [str(e)]
        errs += [] if p.dp_read(0x0) == IDCODE else ["no recovery after ABORT"]
        report("FAULT then ABORT: the sticky error is cleared and the link works again", errs + p.errs)
        # parity error on a read is flagged
        t.bad_read_parity = True
        p.errs.clear()
        p.dp_read(0x0)
        errs = [] if any("parity" in e for e in p.errs) else ["a wrong read parity was not flagged"]
        t.bad_read_parity = False
        report("a wrong parity on read data is flagged", errs)
        p.errs.clear()
        report("clock rate ~1 MHz, SWDIO only changes while SWCLK is low, no contention, no target complaints", timing_errors(b, t), f"{t.requests} requests")
    except RuntimeError as e:
        report("probe session", [str(e)])


def phase_mutants():
    print("Phase 2: broken firmware must be caught")
    for name, mut in (("data and request sent MSB first", ("msb_first",)), ("no turnaround clock after the request", ("no_turnaround",)),
                      ("wrong parity on write data", ("wrong_parity",)), ("ACK decoded MSB first", ("ack_msb",))):
        b, t, p = rig(sp.words(mut))
        errs = []
        try:
            idc = p.connect()
            if idc != IDCODE:
                errs.append(f"IDCODE 0x{idc:08X}")
            p.mem_write(0x20000000, 0xCAFEBABE)
            if p.mem_read(0x20000000) != 0xCAFEBABE:
                errs.append("memory round trip failed")
        except RuntimeError as e:
            errs.append(str(e))
        errs += timing_errors(b, t) + p.errs
        report(f"mutant: {name}", errs, "", "fail")


def main():
    phases = sys.argv[1:] or ["run", "mutants"]
    for ph in phases:
        {"run": phase_run, "mutants": phase_mutants}[ph]()
    bad = [n for n, ok in RESULTS if not ok]
    print(f"RESULT swd_test: {'PASS' if not bad else 'FAIL'} ({len(RESULTS) - len(bad)}/{len(RESULTS)} cases as expected)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
