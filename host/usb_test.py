#!/usr/bin/env python3
"""USB low-speed device test: the firmware (host/usb_prog.py) against the host peer model (host/usb_host.py, written from the USB 2.0 text).
  python3 host/usb_test.py             # on the cycle-exact engine model (seconds)
  python3 host/usb_test.py rtl         # on the chip RTL through the SPI management link (tb/tb_host_bridge.v)
  python3 host/usb_test.py rate        # also run the enumeration at host bit rates of +-1.5 %

Checks: the enumeration sequence a PC runs (reset, descriptors, SET_ADDRESS, SET_CONFIGURATION, HID requests), HID key reports on endpoint 1 with
DATA0/DATA1 toggling, retransmission of an unacknowledged packet, NAK when nothing is pending, no answer to a wrong address / damaged PID /
damaged SETUP data, STALL for an unsupported request, bus reset, response timing (2 .. 7.5 bit times after the host's EOP, USB 2.0 7.1.18).
"""
import importlib.util
import os
import sys

import usb_device_host as UD
import usb_host as UH
import usb_ls as U
import usb_prog

checks = fails = 0


def check(cond, msg):
    global checks, fails
    checks += 1
    if not cond:
        fails += 1
        print(f"  FAIL  {msg}")
    return cond


class Env:
    def __init__(self, mode, ppm=0.0):
        self.log = []
        words = firmware_words()
        if mode == "rtl":
            from chip_host import ChipHost, SimLink
            self.link = SimLink()
            self.chip = ChipHost(self.link)
            self.chip.claim_pad(0, eng=0)                      # D+ on uio[0], D- on uio[1]
            self.chip.claim_pad(1, eng=0)
            self.chip.load_program(0, words)
            self.chip.run(0)
            self.link.usb(True)
            port = UD.FifoPort(lambda w: self.chip.push_tx(0, w), lambda: self.chip.pop_rx(0), lambda n: self.link.wait(n))
        else:
            from usb_model_link import ModelLink
            self.link = ModelLink(words)
            port = UD.FifoPort(self.link.put, self.link.get, self.link.pump)
        self.dev = UD.DeviceSoftware(port, UD.HID_KEYBOARD, log=self.log)
        self.host = UH.UsbHost(self.link, ppm=ppm, log=self.log)
        self.host.service = self.dev.service
        self.link.wait(400)                                    # firmware initialisation

    def close(self):
        if hasattr(self.link, "close"):
            self.link.close()


def firmware_words():
    """The firmware under test: host/usb_prog.py, or the file named by USB_PROG_FILE (used by usb_mutants.py)."""
    path = os.environ.get("USB_PROG_FILE")
    if not path:
        return usb_prog.words()
    spec = importlib.util.spec_from_file_location("usb_prog_under_test", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod.words()


def timing_ok(env, what):
    r = env.host.last_response_clocks
    bits = r / env.host.bit_clk
    check(r is not None and 2.0 <= bits <= 7.5, f"{what}: answer {bits:.2f} bit times after the host's EOP (limits 2 .. 7.5)")


def enumerate_device(env, check_data=True):
    h, dev = env.host, env.dev
    D = UD.HID_KEYBOARD
    h.bus_reset(0.1)
    dev.service()
    d8 = h.control_read(0, UH.setup_packet(0x80, 6, 0x0100, 0, 64))      # Linux first asks for 64 bytes: the device answers 18
    check(d8 == D["device"], f"device descriptor {d8.hex()}")
    timing_ok(env, "SETUP")
    h.bus_reset(0.1)
    dev.service()
    h.control_no_data(0, UH.setup_packet(0x00, 5, 7))                    # SET_ADDRESS 7
    check(dev.addr == 7, "SET_ADDRESS seen by the software")
    d = h.control_read(7, UH.setup_packet(0x80, 6, 0x0100, 0, 18))
    check(d == D["device"], "device descriptor at address 7")
    c9 = h.control_read(7, UH.setup_packet(0x80, 6, 0x0200, 0, 9))
    check(c9 == D["config"][:9], f"configuration descriptor, first 9 bytes: {c9.hex()}")
    wtotal = c9[2] | c9[3] << 8
    cfg = h.control_read(7, UH.setup_packet(0x80, 6, 0x0200, 0, wtotal))
    check(cfg == D["config"], f"full configuration descriptor ({len(cfg)} bytes)")
    h.control_no_data(7, UH.setup_packet(0x00, 9, 1))                    # SET_CONFIGURATION 1
    check(dev.configured, "configured")
    h.control_no_data(7, UH.setup_packet(0x21, 0x0A, 0, 0, 0))           # SET_IDLE
    rep = h.control_read(7, UH.setup_packet(0x81, 6, 0x2200, 0, len(D["report"])))
    check(rep == D["report"], f"HID report descriptor ({len(rep)} bytes)")
    h.control_no_data(7, UH.setup_packet(0x21, 0x0B, 0, 0, 0))           # SET_PROTOCOL (boot)


def tests(mode, rate):
    for ppm in ([0.0, 15000.0, -15000.0] if rate else [0.0]):
        print(f"--- enumeration, host bit rate {ppm / 1e4:+.1f} %")
        env = Env(mode, ppm)
        enumerate_device(env)
        if ppm:
            env.close()
            continue
        h, dev = env.host, env.dev

        print("--- HID reports on endpoint 1")
        pid, d = h.in_(7, 1)
        check(pid == "NAK", f"IN endpoint 1 with nothing queued: {pid}")
        dev.key(0x04)
        dev.feed_reports()
        h.idle(40)
        pid, d = h.in_(7, 1)
        check((pid, d) == ("DATA0", bytes([0, 0, 4, 0, 0, 0, 0, 0])), f"first report: {pid} {d.hex()}")
        timing_ok(env, "IN endpoint 1")
        dev.service()
        check(dev.acked >= 1, "the software saw the acknowledgement event")
        dev.feed_reports()
        h.idle(40)
        pid, d = h.in_(7, 1)
        check((pid, d) == ("DATA1", bytes(8)), f"release report toggles to DATA1: {pid} {d.hex()}")
        dev.service()

        print("--- retransmission and NAK")
        dev.key(0x05)
        dev.feed_reports()
        h.idle(40)
        h.send(U.token("IN", 7, 1))
        a = h.receive()
        h.send(U.token("IN", 7, 1))                    # the host did not acknowledge: the same packet again
        b = h.receive()
        check(a and b and a[0] == b[0], f"unacknowledged packet is sent again: {a[0].hex() if a else None} / {b[0].hex() if b else None}")
        h.idle(2)
        h.send(U.handshake("ACK"))
        h.idle(20)
        dev.service()
        h.send(U.token("IN", 7, 1))
        c = h.receive()
        check(c and c[0][0] != b[0][0] or (c and U.parse(c[0])["pid"] == "NAK"), "after the ACK the old packet is gone")
        # drain the second (release) report so the pipe is idle
        dev.feed_reports()
        h.idle(40)
        h.in_(7, 1)
        dev.service()
        h.idle(40)

        print("--- a pending packet belongs to its endpoint")
        dev.key(0x06)
        dev.feed_reports()
        h.idle(40)
        h.send(U.token("IN", 7, 0))
        r = h.receive()
        check(r and U.parse(r[0])["pid"] == "NAK", "packet pending for endpoint 1, IN on endpoint 0: NAK")
        pid, d = h.in_(7, 1)
        check(pid.startswith("DATA") and d[2] == 6, f"the same packet on endpoint 1: {pid} {d.hex()}")
        dev.service()
        dev.feed_reports()
        h.idle(40)
        h.in_(7, 1)
        dev.service()
        h.idle(40)

        print("--- tokens that must be ignored")
        h.send(U.token("IN", 9, 1))
        check(h.receive(timeout_bits=30) is None, "IN to another address: no answer")
        h.send(U.token("IN", 7, 2))
        check(h.receive(timeout_bits=30) is None, "IN to endpoint 2: no answer")
        bad = bytearray(U.token("IN", 7, 0))
        bad[0] ^= 0x10                                  # damaged PID check bits
        h.send(bytes(bad))
        check(h.receive(timeout_bits=30) is None, "damaged PID: no answer")
        h.send(U.token("IN", 7, 0))
        r = h.receive()
        check(r and U.parse(r[0])["pid"] == "NAK", "IN endpoint 0 with nothing pending: NAK")

        print("--- SETUP with damaged data, unsupported request, OUT")
        h.send(U.token("SETUP", 7, 0))
        h.idle(2)
        good = U.data_packet("DATA0", UH.setup_packet(0x80, 6, 0x0100, 0, 8))
        h.send(good[:-1] + bytes([good[-1] ^ 1]))       # CRC16 wrong
        check(h.receive(timeout_bits=30) is None, "SETUP data with a wrong CRC16: no answer")
        h.send(U.token("SETUP", 7, 0))
        h.idle(2)
        h.send(U.data_packet("DATA1", UH.setup_packet(0x80, 6, 0x0100, 0, 8)))     # SETUP data must be DATA0
        check(h.receive(timeout_bits=30) is None, "SETUP data with the PID DATA1: no answer")
        h.send(U.token("SETUP", 7, 0))
        h.idle(2)
        h.send(U.data_packet("DATA0", UH.setup_packet(0xC0, 0x55, 0, 0, 4)))      # vendor request the software does not know
        r = h.receive()
        check(r and U.parse(r[0])["pid"] == "ACK", "unsupported request: SETUP data acknowledged")
        dev.service()
        h.idle(40)
        h.send(U.token("IN", 7, 0))
        r = h.receive()
        check(r and U.parse(r[0])["pid"] == "STALL", f"unsupported request: STALL ({r[0].hex() if r else None})")
        check(h.out(7, 1, b"\x02") == "ACK", "OUT data to endpoint 1 is acknowledged")

        print("--- bus reset")
        h.bus_reset(0.1)
        dev.service()
        check(dev.resets >= 1, "reset event seen by the software")
        h.send(U.token("IN", 7, 0))
        check(h.receive(timeout_bits=30) is None, "after the reset the old address is gone")
        h.send(U.token("IN", 0, 0))
        r = h.receive()
        check(r and U.parse(r[0])["pid"] == "NAK", "address 0 answers again")
        env.close()
    print(f"{checks} checks, {fails} failed")
    print(f"RESULT usb_test ({mode}): {'PASS' if not fails else 'FAIL'} ({checks - fails}/{checks} checks)")
    return 1 if fails else 0


if __name__ == "__main__":
    args = sys.argv[1:]
    try:
        rc = tests("rtl" if "rtl" in args else "model", "rate" in args)
    except Exception as e:                           # a device that stops answering is a failed test, not a crash
        print(f"  FAIL  {type(e).__name__}: {e}")
        print("RESULT usb_test: FAIL (exception)")
        rc = 1
    sys.exit(rc)
