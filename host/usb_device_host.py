#!/usr/bin/env python3
"""Host-side software of the USB device (docs/USB_LS_PLAN.md): decides WHAT the device is. The firmware (host/usb_prog.py) handles the bus; this
code reads its SETUP events, composes the answer packets (descriptors, handshakes, HID reports) and pushes them through the TX FIFO.

    port = FifoPort(put, get, pump)         # put(word) -> bool, get() -> word | None, pump(clocks): let time pass
    dev = DeviceSoftware(port, HID_KEYBOARD)
    dev.service()                           # call regularly: handles events, queues the next packet
    dev.key(0x04)                           # type an 'a' (HID usage 0x04) when the host polls

The same class drives the RTL (put/get = ChipHost.push_tx / pop_rx) and the model (ModelLink).
"""
import usb_ls as U

HID_KEYBOARD = dict(
    device=bytes([18, 1, 0x10, 0x01, 0, 0, 0, 8, 0x09, 0x12, 0x01, 0x00, 0x00, 0x01, 0, 0, 0, 1]),     # USB 1.1, VID 0x1209, PID 0x0001
    config=bytes([9, 2, 34, 0, 1, 1, 0, 0xA0, 50,                       # configuration: 1 interface, bus powered, 100 mA
                  9, 4, 0, 0, 1, 3, 1, 1, 0,                           # interface 0: HID, boot subclass, keyboard
                  9, 0x21, 0x11, 0x01, 0, 1, 0x22, 47, 0,              # HID 1.11, one report descriptor of 47 bytes
                  7, 5, 0x81, 3, 8, 0, 10]),                           # endpoint 1 IN, interrupt, 8 bytes, every 10 ms
    report=bytes([0x05, 0x01, 0x09, 0x06, 0xA1, 0x01, 0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01,
                  0x75, 0x01, 0x95, 0x08, 0x81, 0x02, 0x95, 0x01, 0x75, 0x08, 0x81, 0x01, 0x95, 0x06, 0x75, 0x08,
                  0x15, 0x00, 0x25, 0x65, 0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x81, 0x00, 0xC0]),
)
HID_KEYBOARD["config"] = HID_KEYBOARD["config"][:25] + bytes([len(HID_KEYBOARD["report"])]) + HID_KEYBOARD["config"][26:]

HDR = 0x03000000
EV_SETUP, EV_RESET, EV_ACK = 1, 4, 3


class FifoPort:
    def __init__(self, put, get, pump):
        self.put, self.get, self.pump = put, get, pump


def item(packet, ep=0):
    """The four FIFO words of one packet (header + up to 11 bytes)."""
    assert 1 <= len(packet) <= 11
    b = bytes(packet) + bytes(12 - len(packet))
    return [HDR | ep << 8 | len(packet)] + [int.from_bytes(b[4 * i:4 * i + 4], "little") for i in range(3)]


def address_item(addr):
    return [HDR | 1 << 16 | (addr & 0x7F) << 24, 0, 0, 0]


class DeviceSoftware:
    def __init__(self, port, desc=HID_KEYBOARD, log=None):
        self.port, self.desc, self.log = port, desc, log
        self.out = []                 # words still to push, in order
        self.configured = False
        self.addr = 0
        self.ep1_toggle = 0
        self.keys_pending = []
        self.acked = 0
        self.resets = 0
        self.setups = []              # decoded SETUP requests, for the tests

    def _note(self, msg):
        if self.log is not None:
            self.log.append(msg)

    # ---- events from the chip
    def _word(self, tries=2000):
        for _ in range(tries):
            w = self.port.get()
            if w is not None:
                return w
            self.port.pump(20)
        raise TimeoutError("event word missing")

    def service(self):
        """Handle every event the chip has queued, then push what is waiting for the TX FIFO."""
        while True:
            w = self.port.get()
            if w is None:
                break
            t = w >> 24
            if t == EV_SETUP:
                w0, w1, w2 = self._word(), self._word(), self._word()
                req = bytes([w0 >> 16 & 0xFF, w0 >> 24, w1 & 0xFF, w1 >> 8 & 0xFF, w1 >> 16 & 0xFF, w1 >> 24, w2 & 0xFF, w2 >> 8 & 0xFF])
                self._setup(req)
            elif t == EV_ACK:
                self.acked += 1
                self._note(f"chip: packet acknowledged (ep {w >> 8 & 0xFF}, {w & 0xFF} bytes)")
            elif t == EV_RESET:
                self.resets += 1
                self.addr = 0
                self.configured = False
                self.out = []
                self._note("chip: bus reset")
            else:
                self._note(f"chip: unknown event 0x{w:08X}")
        self._push()

    def _push(self):
        while self.out:
            if not self.port.put(self.out[0]):
                return
            self.out.pop(0)

    def _queue(self, packet, ep=0):
        self.out += item(packet, ep)

    # ---- control requests (USB 2.0 chapter 9, HID 1.11)
    def _setup(self, req):
        bm, r, wv, wi, wl = req[0], req[1], req[2] | req[3] << 8, req[4] | req[5] << 8, req[6] | req[7] << 8
        self.setups.append(req)
        self.out = []                                  # a new control transfer abandons whatever was queued
        self._note(f"chip: SETUP {req.hex()}  bm=0x{bm:02X} req={r} value=0x{wv:04X} index={wi} length={wl}")
        if (bm, r) == (0x80, 6) or (bm, r) == (0x81, 6):             # GET_DESCRIPTOR
            kind = wv >> 8
            data = {1: self.desc["device"], 2: self.desc["config"], 0x22: self.desc["report"]}.get(kind)
            if data is None:
                return self._stall()
            self._send_data(data[:wl])
        elif (bm, r) == (0x00, 5):                                   # SET_ADDRESS: status stage first, then the new address takes effect
            self._queue(U.data_packet("DATA1", b""))
            self.out += address_item(wv & 0x7F)
            self.addr = wv & 0x7F
        elif (bm, r) == (0x00, 9):                                   # SET_CONFIGURATION
            self.configured = wv & 0xFF != 0
            self._queue(U.data_packet("DATA1", b""))
        elif (bm, r) in ((0x21, 0x0A), (0x21, 0x0B)):                # SET_IDLE, SET_PROTOCOL
            self._queue(U.data_packet("DATA1", b""))
        elif (bm, r) == (0x80, 0):                                   # GET_STATUS
            self._send_data(bytes([0, 0])[:wl])
        else:
            self._stall()

    def _stall(self):
        self._note("   -> STALL")
        self._queue(U.handshake("STALL"))

    def _send_data(self, data):
        """The data stage of a control read: 8-byte packets, DATA1 first, alternating; a short packet (or a zero-length one when the length is a
        multiple of 8) ends it. The chip keeps one packet pending and sends the next only after the host acknowledged the previous."""
        toggle = 1
        chunks = [data[i:i + 8] for i in range(0, len(data), 8)] or [b""]
        if data and len(data) % 8 == 0:
            chunks.append(b"")
        for c in chunks:
            self._queue(U.data_packet("DATA1" if toggle else "DATA0", c))
            toggle ^= 1

    # ---- HID reports on endpoint 1
    def key(self, usage, modifiers=0):
        """Queue a key press followed by the release (two reports)."""
        self.keys_pending += [bytes([modifiers, 0, usage, 0, 0, 0, 0, 0]), bytes(8)]

    def feed_reports(self):
        """Push the next HID report when the chip is idle (nothing queued): called by the test between transfers."""
        if self.configured and self.keys_pending and not self.out:
            rep = self.keys_pending.pop(0)
            self._queue(U.data_packet("DATA1" if self.ep1_toggle else "DATA0", rep), ep=1)
            self.ep1_toggle ^= 1
            self._push()
