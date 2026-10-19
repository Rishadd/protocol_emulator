#!/usr/bin/env python3
"""USB low-speed HOST peer model for the chip (docs/USB_LS_PLAN.md), written from USB 2.0 chapters 7-9 and the HID 1.11 specification,
independent of the firmware. It drives and watches the D+/D- bus model of tb/tb_host_bridge.v through SimLink, reactively: it sends a packet
bit by bit at its own bit rate (with a programmable offset in ppm), then watches the device answer, measures the timing and decodes the
response with host/usb_ls.py.

    link = SimLink(); chip = ChipHost(link); link.usb(True)
    h = UsbHost(link)
    h.bus_reset()
    r = h.setup(0, 0, bytes([0x80, 6, 0, 1, 0, 0, 8, 0]))        # GET_DESCRIPTOR(device, 8)
    pid, data = h.in_(0, 0)                                      # DATA1 with 8 bytes
    h.out_status(0, 0)

All times are in system clocks (20 ns); one low-speed bit is 33.33 clocks.
"""
import usb_ls as U

CLK_NS = 20.0
SYM = {(0, 1): "J", (1, 0): "K", (0, 0): "0", (1, 1): "1"}


class UsbError(Exception):
    pass


class UsbHost:
    def __init__(self, link, ppm=0.0, log=None):
        self.link = link
        self.bit_clk = (U.T_BIT / CLK_NS) * (1 + ppm * 1e-6)         # host bit time in clocks
        self.frac = 0.0
        self.log = log                                               # optional list of strings
        self.last_response_clocks = None                             # EOP of our packet -> first edge of the device's answer
        self.service = lambda: None                                  # called while the host waits (the device software runs here)
        self.t_end_tx = 0

    def _note(self, msg):
        if self.log is not None:
            self.log.append(msg)

    # ---- driving
    def _bit_clocks(self):
        self.frac += self.bit_clk
        n = int(self.frac)
        self.frac -= n
        return n

    def drive_symbols(self, symbols):
        for s in symbols:
            dp, dm = U.LEVEL[s]
            self.link.host_drive(dp, dm, 1)
            self.link.wait(self._bit_clocks())
        self.link.host_drive(0, 1, 0)                                # release; the bus idles as J

    def send(self, pkt, sync=U.SYNC):
        """Send SYNC + packet + EOP. Before a token the device software is serviced, as a real one polls its FIFOs all the time."""
        if pkt[0] & 15 in (U.PID["SETUP"], U.PID["IN"], U.PID["OUT"]):
            self.service()
        self._note(f"host  >> {U.PID_NAME.get(pkt[0] & 15, '?')} {bytes(pkt).hex()}")
        self.drive_symbols(U.packet_symbols(pkt, sync))

    def idle(self, bits):
        self.link.wait(int(round(bits * self.bit_clk)))

    def bus_reset(self, ms=1.0):
        self.link.host_drive(0, 0, 1)                                # SE0
        self.link.wait(int(ms * 1e6 / CLK_NS))
        self.link.host_drive(0, 1, 0)
        self.idle(100)

    def keep_alive(self):
        self.drive_symbols(["0", "0", "J"])

    # ---- watching
    def receive(self, timeout_bits=18, max_bits=400):
        """Wait up to timeout_bits for the device to start a packet, then decode it. Returns (bytes, info) or None when nothing came.
        info: dict(start_clocks = clocks from now until the first edge, runs = [(symbol, bit times)], partial, errors, eop_se0_bits)."""
        wait_clk = int(timeout_bits * self.bit_clk)
        waited = 0
        lvl = None
        while waited < wait_clk:
            ran, lv, both = self.link.run_until_change(wait_clk - waited)
            waited += ran
            if SYM[lv] != "J":
                lvl = lv
                break
        if lvl is None:
            return None
        start = waited
        runs, cur = [], SYM[lvl]
        for _ in range(max_bits * 2):
            ran, lv, both = self.link.run_until_change(int(8 * self.bit_clk))
            if both:
                raise UsbError("bus contention: the device drove while the host did")
            sym = SYM[lv]
            if ran >= int(8 * self.bit_clk) and sym == cur:        # no change for 8 bit times: the line stays at `cur`
                runs.append((cur, ran))
                break
            runs.append((cur, ran))
            cur = sym
            if sym == "J" and len(runs) > 1 and runs[-1][0] == "0":
                break
        rb = [(s, n / self.bit_clk) for s, n in runs]
        pk = []
        for s, n in rb:
            pk.append((s, round(n)))
            if s == "0":
                break
        # runs up to and including the SE0 run
        body = []
        for s, n in pk:
            body.append((s, n))
        data, partial, errs = U.decode_runs(body)
        se0 = [n for s, n in rb if s == "0"]
        info = dict(start_clocks=start, runs=rb, partial=partial, errors=errs, se0_bits=se0[0] if se0 else None)
        if data:
            self._note(f"device << {U.PID_NAME.get(data[0] & 15, '?')} {data.hex()}  (answer after {start / self.bit_clk:.1f} bit times)")
        return data, info

    # ---- transactions (USB 2.0 section 8.5)
    def _expect(self, pkt, what):
        if pkt is None:
            raise UsbError(f"{what}: no answer from the device")
        data, info = pkt
        if info["errors"] or info["partial"]:
            raise UsbError(f"{what}: damaged packet {data.hex()} {info['errors']} partial={info['partial']}")
        return data, info

    def setup(self, addr, ep, request8):
        """SETUP + DATA0(8 bytes). Returns the device's handshake PID name."""
        self.send(U.token("SETUP", addr, ep))
        self.idle(2)
        self.send(U.data_packet("DATA0", request8))
        data, info = self._expect(self.receive(), "handshake after SETUP data")
        self.last_response_clocks = info["start_clocks"]
        self.service()
        return U.parse(data)["pid"]

    def in_(self, addr, ep, ack=True):
        """IN token. Returns (PID name, payload) with payload b'' for a handshake; sends ACK after DATA."""
        self.send(U.token("IN", addr, ep))
        data, info = self._expect(self.receive(), "answer to IN")
        self.last_response_clocks = info["start_clocks"]
        p = U.parse(data)
        if p["pid"].startswith("DATA"):
            if ack:
                self.idle(2)
                self.send(U.handshake("ACK"))
            return p["pid"], p["data"]
        return p["pid"], b""

    def out(self, addr, ep, payload, pid="DATA1"):
        self.send(U.token("OUT", addr, ep))
        self.idle(2)
        self.send(U.data_packet(pid, payload))
        data, info = self._expect(self.receive(), "handshake after OUT data")
        self.last_response_clocks = info["start_clocks"]
        return U.parse(data)["pid"]

    def out_status(self, addr, ep):
        """Zero-length DATA1 OUT (status stage of a control read)."""
        return self.out(addr, ep, b"", "DATA1")

    # ---- control transfers
    def control_read(self, addr, request8, max_packets=64):
        """SETUP, IN ... until a short packet or wLength bytes, status OUT. Returns the data."""
        pid = self.setup(addr, 0, request8)
        if pid != "ACK":
            raise UsbError(f"SETUP not acknowledged: {pid}")
        wlen = request8[6] | request8[7] << 8
        got, toggle = b"", 0
        for _ in range(max_packets):
            pid, d = self.in_(addr, 0)
            if pid == "NAK":
                self.service()
                self.idle(30)
                continue
            if pid == "STALL":
                raise UsbError("control read STALLed")
            if pid != ("DATA1" if toggle == 0 else "DATA0"):
                raise UsbError(f"wrong DATA toggle {pid} at byte {len(got)}")
            toggle ^= 1
            got += d
            if len(d) < 8 or len(got) >= wlen:
                break
        st = self.out_status(addr, 0)
        if st != "ACK":
            raise UsbError(f"status stage answered {st}")
        return got

    def control_no_data(self, addr, request8, recovery_us=100):
        """SETUP, then the status stage: IN returning a zero-length DATA1; then the recovery time before the next request (USB 2.0 9.2.6.3)."""
        pid = self.setup(addr, 0, request8)
        if pid != "ACK":
            raise UsbError(f"SETUP not acknowledged: {pid}")
        for _ in range(32):
            pid, d = self.in_(addr, 0)
            if pid == "NAK":
                self.service()
                self.idle(30)
                continue
            if pid != "DATA1" or d:
                raise UsbError(f"status stage: {pid} {d.hex()}")
            self.service()
            self.link.wait(int(recovery_us * 1000 / CLK_NS))
            return
        raise UsbError("status stage never completed")


def setup_packet(bm, req, value=0, index=0, length=0):
    return bytes([bm, req, value & 0xFF, value >> 8, index & 0xFF, index >> 8, length & 0xFF, length >> 8])


GET_DESCRIPTOR, SET_ADDRESS, SET_CONFIGURATION, SET_IDLE, SET_PROTOCOL = 6, 5, 9, 0x0A, 0x0B
