#!/usr/bin/env python3
"""PS/2 device firmware (host/ps2_prog.py) against a reactive PS/2 HOST model written from the interface description (Chapweske, "The PS/2
Mouse/Keyboard Protocol"; IBM PS/2 timing), on the cycle-exact engine model with a wired-AND bus (host/bus_model.py).
  python host/ps2_test.py [run mutants]

The host watches the device's clock edges and reacts (it does not replay a fixed waveform): it samples DATA on every falling clock edge,
measures clock low / high times, data setup and hold; it inhibits a transmission by holding the clock low; it sends a command byte bit by bit
and checks the acknowledge. A software keyboard (scan code set 2, command replies) sits on the FIFOs and makes the pair a working PS/2 keyboard.
"""
import random
import sys

import bus_model as BM
import ps2_prog as pp

CLK, DATA = pp.CLK, pp.DATA
US = pp.US
RESULTS = []
LOW_MIN, LOW_MAX = 30, 50
SETUP_MIN, SETUP_MAX, HOLD_MIN, HOLD_MAX = 5, 25, 5, 25


def report(name, errs, stats="", expect="pass"):
    ok = bool(errs) == (expect == "fail")
    tag = {"pass": "PASS" if ok else "FAIL", "fail": "DETECTED" if ok else "MISSED"}[expect]
    RESULTS.append((name, ok))
    print(f"  {tag:8s} {name:62s} {stats}")
    if not ok:
        for e in errs[:6] or ["no error was reported"]:
            print(f"           {e}")
    return ok


def odd_parity_bit(b):
    return (bin(b).count("1") + 1) & 1


class Host:
    """The PS/2 host side of the bus."""

    def __init__(self, program, pins=2):
        self.bus = BM.OpenDrainBus(program, pins)
        self.errs = []
        self.mark = 0                                  # index into the bus log: events before it are consumed

    def us(self, n):
        self.bus.step(int(n * US))

    def level(self, pin):
        return self.bus.levels()[pin]

    # ---- watching the device (device -> host)
    def wait_edge(self, pin, to, max_us):
        """Advance until `pin` goes to level `to`; returns the clock count it took, or None on timeout."""
        n = 0
        limit = int(max_us * US)
        while n < limit:
            if self.level(pin) == to:
                return n
            n += self.bus.until_change(limit - n)
        return None

    def read_frame(self, timeout_us=20000):
        """Passive: one device frame (11 clocks). Returns dict(byte, parity_ok, start, stop) and appends timing violations to self.errs."""
        t0 = self.bus.clock
        if self.level(CLK) == 0:
            if self.wait_edge(CLK, 1, timeout_us) is None:
                return None
        bits, falls, rises, data_changes = [], [], [], []
        for i in range(11):
            if self.wait_edge(CLK, 0, timeout_us) is None:
                return None
            falls.append(self.bus.clock)
            bits.append(self.level(DATA))
            if self.wait_edge(CLK, 1, 200) is None:
                self.errs.append(f"bit {i}: clock low for more than 200 us")
                return None
            rises.append(self.bus.clock)
        # timing from the log between the first fall and the last rise
        for i in range(11):
            low = (rises[i] - falls[i]) / US
            if not LOW_MIN <= low <= LOW_MAX:
                self.errs.append(f"bit {i}: clock low {low:.1f} us outside [{LOW_MIN}, {LOW_MAX}]")
            if i + 1 < 11:
                high = (falls[i + 1] - rises[i]) / US
                if not LOW_MIN <= high <= LOW_MAX:
                    self.errs.append(f"bit {i}: clock high {high:.1f} us outside [{LOW_MIN}, {LOW_MAX}]")
        dchg = [c for c, lv in self.bus.log if c >= t0]
        log = self.bus.log
        # data setup / hold: last DATA change before each falling edge, first DATA change after each rising edge
        def data_at(c):
            v = None
            for cc, lv in log:
                if cc <= c:
                    v = lv[DATA]
            return v
        changes = []
        prev = log[0][1][DATA]
        for cc, lv in log:
            if lv[DATA] != prev:
                changes.append(cc)
                prev = lv[DATA]
        for i in range(11):
            before = [c for c in changes if c <= falls[i]]
            if before:
                setup = (falls[i] - before[-1]) / US
                if setup < SETUP_MIN and not (i == 0 and before[-1] == falls[0]):
                    self.errs.append(f"bit {i}: data setup {setup:.1f} us < {SETUP_MIN}")
            after = [c for c in changes if c > rises[i]]
            if after and i < 10:
                hold = (after[0] - rises[i]) / US
                nxt = falls[i + 1]
                if after[0] < nxt and hold < HOLD_MIN:
                    self.errs.append(f"bit {i}: data hold {hold:.1f} us < {HOLD_MIN}")
        byte = sum(b << k for k, b in enumerate(bits[1:9]))
        return dict(byte=byte, start=bits[0], parity=bits[9], stop=bits[10],
                    parity_ok=((bin(byte).count("1") + bits[9]) & 1) == 1, bits=bits)

    # ---- driving the device (host -> device)
    def inhibit(self, us):
        self.bus.pull(CLK, True)
        self.us(us)

    def release_clock(self):
        self.bus.pull(CLK, False)

    def send_byte(self, byte, parity_bad=False, stop_bad=False, timeout_us=20000):
        """Request to send + the 11 bits clocked by the device + acknowledge check. Returns True if the device acknowledged."""
        bits = [(byte >> k) & 1 for k in range(8)]
        p = odd_parity_bit(byte) ^ int(parity_bad)
        frame = bits + [p, 0 if stop_bad else 1]
        self.inhibit(120)
        self.bus.pull(DATA, True)                          # start bit
        self.us(5)
        self.release_clock()
        for i, b in enumerate(frame):                      # after each device clock rising edge the host presents the next bit
            if self.wait_edge(CLK, 0, timeout_us) is None:
                self.errs.append(f"host->device: the device never clocked bit {i}")
                self.bus.pull(DATA, False)
                return False
            if self.wait_edge(CLK, 1, 200) is None:
                self.errs.append(f"host->device: clock stuck low at bit {i}")
                self.bus.pull(DATA, False)
                return False
            self.us(10)
            self.bus.pull(DATA, not b)
        if self.wait_edge(CLK, 0, 2000) is None or self.wait_edge(CLK, 1, 200) is None:      # the 11th clock samples the stop bit
            self.errs.append("host->device: the device did not clock the stop bit")
            self.bus.pull(DATA, False)
            return False
        self.bus.pull(DATA, False)                         # the host releases DATA after the stop bit
        if self.wait_edge(CLK, 0, 2000) is None:           # the 12th clock is the acknowledge
            self.errs.append("host->device: no acknowledge clock")
            return False
        ack = self.level(DATA) == 0
        if not ack:
            self.errs.append("host->device: DATA not low in the acknowledge clock")
        self.wait_edge(CLK, 1, 200)
        self.us(20)
        return ack


class Keyboard:
    """The keyboard side in software: answers command bytes through the FIFOs, makes and breaks scan codes (set 2)."""

    def __init__(self, host):
        self.h = host
        self.expect = None
        self.leds = 0
        self.log = []

    def send(self, data):
        for b in data:
            while not self.h.bus.put(b):
                self.h.us(200)

    def service(self):
        w = self.h.bus.get()
        while w is not None:
            byte, perr, ferr = w & 0xFF, w >> 8 & 1, w >> 9 & 1
            self.log.append((byte, perr, ferr))
            if perr or ferr:
                self.send([0xFE])                          # resend request
            elif self.expect is not None:
                self.leds = byte if self.expect == 0xED else self.leds
                self.expect = None
                self.send([0xFA])
            elif byte == 0xFF:
                self.send([0xFA, 0xAA])
            elif byte in (0xED, 0xF3, 0xF0):
                self.expect = byte
                self.send([0xFA])
            elif byte in (0xF4, 0xF5, 0xF6, 0xE6):
                self.send([0xFA])
            elif byte == 0xF2:
                self.send([0xFA, 0xAB, 0x83])
            elif byte == 0xEE:
                self.send([0xEE])
            else:
                self.send([0xFE])
            w = self.h.bus.get()

    def press(self, code, extended=False):
        self.send(([0xE0] if extended else []) + [code])

    def release(self, code, extended=False):
        self.send(([0xE0] if extended else []) + [0xF0, code])


def run_tx_case(name, data, firmware, expect="pass"):
    h = Host(firmware)
    h.us(300)
    kb = Keyboard(h)
    kb.send(data[:4])
    rest = data[4:]
    got = []
    for _ in range(len(data)):
        f = h.read_frame()
        if f is None:
            h.errs.append(f"no frame {len(got) + 1} of {len(data)}")
            break
        got.append(f["byte"])
        if not f["parity_ok"]:
            h.errs.append(f"frame {len(got)}: parity bit wrong for 0x{f['byte']:02X}")
        if f["start"] != 0 or f["stop"] != 1:
            h.errs.append(f"frame {len(got)}: start {f['start']} stop {f['stop']}")
        while rest and h.bus.put(rest[0]):
            rest.pop(0)
    if got != data:
        h.errs.append(f"received {[hex(x) for x in got]}, expected {[hex(x) for x in data]}")
    return report(name, h.errs, f"{len(got)} frames", expect)


def phase_run():
    print("Phase 1: device -> host")
    rnd = random.Random(2)
    fw = pp.ps2_device()
    run_case_bytes = [0x00, 0xFF, 0x1C, 0xF0, 0xAA, 0x55, 0x83, 0xFA, 0xE0, 0x01, 0x80, 0x7F]
    run_tx_case("known bytes incl. parity extremes (0x00, 0xFF, 0x55, 0xAA)", run_case_bytes, fw)
    run_tx_case("random bytes", [rnd.randrange(256) for _ in range(14)], fw)

    print("Phase 2: the host inhibits a transmission")
    for nbits in (1, 5, 8):
        h = Host(fw)
        h.us(300)
        h.bus.put(0xA5)
        h.wait_edge(CLK, 0, 5000)
        for _ in range(nbits):                              # nbits full clock cycles have gone out...
            h.wait_edge(CLK, 1, 200)
            h.wait_edge(CLK, 0, 200)
        h.inhibit(150)
        edges_before = len(h.bus.log)
        data_low_during = h.level(DATA)
        h.us(150)
        quiet = len(h.bus.log) == edges_before or all(lv[CLK] == 0 for _, lv in h.bus.log[edges_before:])
        h.release_clock()
        h.mark = len(h.bus.log)
        f = h.read_frame()
        errs = list(h.errs)
        if data_low_during != 1:
            pass
        if f is None or f["byte"] != 0xA5 or not f["parity_ok"]:
            errs.append(f"after the inhibit the byte is not sent again intact: {f and hex(f['byte'])}")
        if not quiet:
            errs.append("the device kept clocking while the host held the clock low")
        report(f"inhibit after {nbits} clocks: stop, release, send the byte again", errs, "")

    print("Phase 3: host -> device")
    h = Host(fw)
    h.us(300)
    kb = Keyboard(h)
    for byte in (0xFF, 0x00, 0xED, 0x5A, 0xF4):
        ok = h.send_byte(byte)
        h.us(300)
        w = h.bus.get()
        errs = list(h.errs)
        if not ok:
            errs.append("not acknowledged")
        if w is None or w != byte:
            errs.append(f"RX word {w if w is None else hex(w)} expected 0x{byte:02X}")
        report(f"host sends 0x{byte:02X}: acknowledged, captured intact", errs, "")
        h.errs.clear()
    ok = h.send_byte(0x33, parity_bad=True)
    h.us(300)
    w = h.bus.get()
    report("wrong parity is flagged (bit 8)", [] if (w is not None and w & 0x100 and w & 0xFF == 0x33) else [f"RX word {w}"], "")
    ok = h.send_byte(0x44, stop_bad=True)
    h.us(300)
    w = h.bus.get()
    report("missing stop bit is flagged (bit 9)", [] if (w is not None and w & 0x200 and w & 0xFF == 0x44) else [f"RX word {w}"], "")

    print("Phase 4: a keyboard session (commands, scan codes)")
    h = Host(fw)
    h.us(300)
    kb = Keyboard(h)

    def talk(byte, expect_bytes):
        h.send_byte(byte)
        h.us(200)                                            # the device has pushed the captured byte by now
        kb.service()                                         # the software queues its answer
        got = []
        for _ in range(len(expect_bytes)):
            f = h.read_frame()                               # the first answer frame starts about 20 us after it was queued
            if f is None:
                break
            got.append(f["byte"])
            kb.service()
        return got == expect_bytes, got

    for cmd, exp in ((0xFF, [0xFA, 0xAA]), (0xF2, [0xFA, 0xAB, 0x83]), (0xEE, [0xEE]), (0xF4, [0xFA]), (0xA5, [0xFE])):
        ok, got = talk(cmd, exp)
        report(f"command 0x{cmd:02X} answered with {[hex(x) for x in exp]}", [] if ok else [f"got {[hex(x) for x in got]}"], "")
    ok, got = talk(0xED, [0xFA])
    ok2, got2 = talk(0x05, [0xFA])
    report("set LEDs: 0xED then 0x05, both acknowledged, LEDs = 5", [] if (ok and ok2 and kb.leds == 5) else [f"{got} {got2} leds={kb.leds}"], "")
    kb.press(0x1C)
    kb.release(0x1C)
    codes = []
    for _ in range(3):
        f = h.read_frame()
        codes.append(f["byte"] if f else None)
    report("key 'A': make 1C, break F0 1C", [] if codes == [0x1C, 0xF0, 0x1C] else [f"got {codes}"], "")
    report("no timing violation in the whole session", list(h.errs), "")


def decode_pads(P):
    """Pad log of the RTL run -> (frames, errors): the same decoding and timing windows as Host.read_frame, applied after the fact."""
    ev = [(t, (v >> CLK) & 1, (v >> DATA) & 1) for t, v in P]
    falls, rises, changes = [], [], []
    for (t0, c0, d0), (t1, c1, d1) in zip(ev, ev[1:]):
        if c0 == 1 and c1 == 0:
            falls.append((t1, d1))
        if c0 == 0 and c1 == 1:
            rises.append(t1)
        if d0 != d1:
            changes.append(t1)
    errs, frames = [], []
    for k in range(0, len(falls) - 10, 11):
        f, r = falls[k:k + 11], rises[k:k + 11]
        if len(r) < 11:
            break
        bits = [d for _, d in f]
        byte = sum(b << i for i, b in enumerate(bits[1:9]))
        frames.append(byte)
        if bits[0] != 0 or bits[10] != 1 or ((bin(byte).count("1") + bits[9]) & 1) != 1:
            errs.append(f"frame {len(frames)}: start {bits[0]} parity {bits[9]} stop {bits[10]} for 0x{byte:02X}")
        for i in range(11):
            low = (r[i] - f[i][0]) / 1000
            if not LOW_MIN <= low <= LOW_MAX:
                errs.append(f"frame {len(frames)} bit {i}: clock low {low:.1f} us")
            if i < 10:
                high = (f[i + 1][0] - r[i]) / 1000
                if not LOW_MIN <= high <= LOW_MAX:
                    errs.append(f"frame {len(frames)} bit {i}: clock high {high:.1f} us")
            before = [c for c in changes if c <= f[i][0]]
            if before and (f[i][0] - before[-1]) / 1000 < SETUP_MIN and not (i == 0):
                errs.append(f"frame {len(frames)} bit {i}: data setup {(f[i][0] - before[-1]) / 1000:.1f} us")
    return frames, errs


def phase_rtl():
    print("Phase RTL: the device -> host direction on the RTL (engine testbench, open-drain pads), decoded after the fact")
    import proto_lib as pl
    data = [0x00, 0xFF, 0x1C, 0xF0, 0x55, 0xAA, 0x83, 0xFA]
    L = pl.run("ps2_rtl", progs={0: pp.ps2_device()}, htx={0: data}, od=0x03, dur_ns=len(data) * 1_600_000 + 400_000)
    frames, errs = decode_pads(L["P"])
    if frames != data:
        errs.append(f"decoded {[hex(x) for x in frames]}, expected {[hex(x) for x in data]}")
    report("RTL: 8 bytes framed, parity, clock and data timing windows", errs, f"{len(frames)} frames")


def phase_mutants():
    print("Phase 2: broken firmware must be caught")
    data = [0x00, 0xFF, 0x5A, 0x1C, 0xF0, 0x83]
    for name, mut in (("even parity instead of odd", ("even_parity",)), ("bits sent MSB first", ("msb_first",)),
                      ("clock low 10 us (too fast)", ("fast_clock",)), ("no stop bit", ("no_stop",))):
        run_tx_case(f"mutant: {name}", data, pp.ps2_device(mut), expect="fail")
    # inhibit / retry
    for name, mut in (("keeps clocking when the host inhibits", ("no_inhibit",)), ("does not send the byte again after an inhibit", ("no_retry",))):
        h = Host(pp.ps2_device(mut))
        h.us(300)
        h.bus.put(0xA5)
        h.wait_edge(CLK, 0, 5000)
        for _ in range(4):
            h.wait_edge(CLK, 1, 200)
            h.wait_edge(CLK, 0, 200)
        h.inhibit(150)
        n0 = len(h.bus.log)
        h.us(150)
        clocked = any(lv[CLK] == 1 and c > h.bus.clock - 150 * US for c, lv in h.bus.log[n0:]) and len(h.bus.log) > n0 + 1
        h.release_clock()
        f = h.read_frame(timeout_us=3000)
        errs = []
        if clocked:
            errs.append("clock moved during the inhibit")
        if f is None or f["byte"] != 0xA5:
            errs.append("the byte was not sent again")
        report(f"mutant: {name}", errs, "", "fail")
    # host -> device
    for name, mut in (("no acknowledge", ("no_ack",)), ("samples DATA after the clock rose", ("late_sample",))):
        h = Host(pp.ps2_device(mut))
        h.us(300)
        ok = h.send_byte(0x5A)
        h.us(300)
        w = h.bus.get()
        errs = list(h.errs)
        if w != 0x5A:
            errs.append(f"RX word {w}")
        report(f"mutant: {name}", errs, "", "fail")


def main():
    phases = sys.argv[1:] or ["run", "mutants"]
    for p in phases:
        {"run": phase_run, "mutants": phase_mutants, "rtl": phase_rtl}[p]()
    bad = [n for n, ok in RESULTS if not ok]
    print(f"RESULT ps2_test: {'PASS' if not bad else 'FAIL'} ({len(RESULTS) - len(bad)}/{len(RESULTS)} cases as expected)")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
