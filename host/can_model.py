#!/usr/bin/env python3
"""CAN 2.0A (11-bit identifier) frame model written from the Bosch CAN 2.0 / ISO 11898-1 rules, independent of the firmware and of
the engine's CRC unit (the CRC-15 here is the bit-serial shift register of the specification).

  encode(id, data, rtr=0)  -> Frame with the on-wire bit list (0 = dominant, 1 = recessive) and field markers
  decode_wire(bits)         -> destuffed fields + errors, from sampled wire bits (SOF first)
  wave(bits, bit_ns, ...)   -> stimulus events for tb_proto
  sample_pad(tl, ...)       -> wire bits and edge-grid errors from a pad timeline
"""
import random

NS_PER_CLK = 20


def crc15(bits):
    """CRC-15/CAN, polynomial x^15+x^14+x^10+x^8+x^7+x^4+x^3+1 (0x4599), shift-register form of the specification."""
    crc = 0
    for b in bits:
        nxt = b ^ (crc >> 14 & 1)
        crc = (crc << 1) & 0x7FFF
        if nxt:
            crc ^= 0x4599
    return crc


def stuff(bits):
    out, run, last = [], 0, None
    for b in bits:
        out.append(b)
        if b == last:
            run += 1
        else:
            run, last = 1, b
        if run == 5:
            out.append(1 - b)
            last, run = 1 - b, 1
    return out


def destuff(bits):
    """Return (bits, error). Error when six equal bits appear. A stuff bit following the last 5 equal bits is dropped."""
    out, run, last, i = [], 0, None, 0
    while i < len(bits):
        b = bits[i]
        if run == 5:
            if b == last:
                return out, f"stuff error at wire bit {i}"
            last, run = b, 1                     # the stuff bit starts a new run
            i += 1
            continue
        out.append(b)
        if b == last:
            run += 1
        else:
            run, last = 1, b
        i += 1
    return out, None


def to_bits(v, n):
    return [v >> (n - 1 - i) & 1 for i in range(n)]


class Frame:
    def __init__(self, ident, data, rtr=0, dlc=None):
        self.ident, self.data, self.rtr = ident, list(data), rtr
        self.dlc = len(self.data) if dlc is None else dlc

    def pre_crc(self):
        b = [0] + to_bits(self.ident, 11) + [self.rtr, 0, 0] + to_bits(self.dlc, 4)
        if not self.rtr:
            for x in self.data[:min(self.dlc, 8)]:
                b += to_bits(x, 8)
        return b

    def wire(self, ack=1, ifs=3, eof=7):
        """On-wire bits. ack = level of the ACK slot as seen from the sender (1 = nobody acknowledged, 0 = acknowledged)."""
        pre = self.pre_crc()
        body = pre + to_bits(crc15(pre), 15)
        return stuff(body) + [1, ack, 1] + [1] * eof + [1] * ifs

    def stuffed_len(self):
        return len(stuff(self.pre_crc() + to_bits(crc15(self.pre_crc()), 15)))


def encode(ident, data, rtr=0, dlc=None):
    return Frame(ident, data, rtr, dlc)


def decode_wire(bits, check_tail=True):
    """bits: sampled wire levels starting with SOF. Returns dict(id, dlc, rtr, ide, data, crc_ok, ack, errors, n_wire)."""
    errs = []
    if not bits or bits[0] != 0:
        return dict(errors=["no SOF"])
    # destuff incrementally so the number of consumed wire bits is known
    out, run, last, i = [], 0, None, 0
    need = None
    while i < len(bits):
        b = bits[i]
        if run == 5:
            if b == last:
                errs.append(f"stuff error at wire bit {i}")
                break
            last, run = b, 1
            i += 1
            if need is not None and len(out) >= need:
                break
            continue
        out.append(b)
        if b == last:
            run += 1
        else:
            run, last = 1, b
        i += 1
        if len(out) == 19:
            dlc = sum(out[15 + k] << (3 - k) for k in range(4))
            rtr, ide = out[12], out[13]
            need = 19 + (0 if rtr else 8 * min(dlc, 8)) + 15
        if need is not None and len(out) >= need:
            if run == 5 and i < len(bits):
                continue                         # a stuff bit follows the last CRC bit
            break
    res = dict(errors=errs, n_wire=i)
    if need is None or len(out) < need:
        errs.append("frame truncated")
        return res
    ident = sum(out[1 + k] << (10 - k) for k in range(11))
    n = 0 if out[12] else min(dlc, 8)
    data = [sum(out[19 + 8 * j + k] << (7 - k) for k in range(8)) for j in range(n)]
    crc_rx = sum(out[19 + 8 * n + k] << (14 - k) for k in range(15))
    res.update(id=ident, dlc=dlc, rtr=out[12], ide=out[13], data=data, crc_ok=(crc15(out[:19 + 8 * n]) == crc_rx))
    tail = bits[i:i + 3 + 7]
    res["tail"] = tail
    if check_tail and len(tail) >= 3:
        res["crc_delim"], res["ack"], res["ack_delim"] = tail[0], tail[1], tail[2]
        if tail[0] != 1:
            errs.append("CRC delimiter dominant")
        if tail[2] != 1:
            errs.append("ACK delimiter dominant")
        if any(b != 1 for b in tail[3:]):
            errs.append("EOF not recessive")
    return res


# ---------------------------------------------------------------- waveforms
def wave(bits, bit_ns, start_ns=2000, pin=0, others=0xFF, ack_low=None):
    """Wire bits -> [(t_ns, pads)] on pin `pin` (0 = low). Returns (events, end_time_ns). The sender holds recessive after the last bit."""
    ev = [(0, others | 1 << pin)]
    t = start_ns
    cur = 1
    for b in bits:
        if b != cur:
            ev.append((int(round(t)), (others | 1 << pin) if b else (others & ~(1 << pin))))
            cur = b
        t += bit_ns
    if cur != 1:
        ev.append((int(round(t)), others | 1 << pin))
    return ev, int(t)


def merge_frames(frames_bits, bit_ns, start_ns=2000, gaps=None, pin=0, scale=1.0):
    """Several frames (wire bit lists), separated by `gaps[i]` extra recessive bit times (default 0). Frames are placed back to back;
    `scale` stretches the sender's bit time (clock error)."""
    bits, marks = [], []
    for i, fb in enumerate(frames_bits):
        marks.append(len(bits))
        bits += fb
        bits += [1] * (gaps[i] if gaps else 0)
    ev, end = wave(bits, bit_ns * scale, start_ns, pin)
    return ev, end, [start_ns + m * bit_ns * scale for m in marks]


# ---------------------------------------------------------------- decoding the pad
def pad_levels(tl):
    return tl


def sample_pad(tl, bit_ns, t_sof=None, frac=0.5, nbits=None, tol_ns=2 * NS_PER_CLK):
    """tl: [(t_ns, level)] of the bus pin. Find the first falling edge, sample at (k + frac) bit times, return
    (t_sof, bits, errors). errors lists edges that are not on the bit grid (more than tol_ns away)."""
    errs = []
    if t_sof is None:
        t_sof = next((t for t, l in tl if l == 0), None)
        if t_sof is None:
            return None, [], ["no dominant bit on the bus"]

    def level_at(t):
        lv = tl[0][1]
        for tt, l in tl:
            if tt <= t:
                lv = l
            else:
                break
        return lv
    n = nbits if nbits is not None else int((tl[-1][0] - t_sof) // bit_ns) + 1
    bits = [level_at(t_sof + (k + frac) * bit_ns) for k in range(n)]
    t_end = t_sof + n * bit_ns
    for t, _ in tl[1:]:
        if t_sof <= t < t_end:
            r = (t - t_sof) / bit_ns
            if abs(r - round(r)) * bit_ns > tol_ns:
                errs.append(f"edge at {t} ns is {abs(r - round(r)) * bit_ns:.0f} ns off the bit grid")
    return t_sof, bits, errs


def random_frame(rnd, dlc=None):
    d = rnd.randrange(9) if dlc is None else dlc
    return encode(rnd.randrange(0x800), [rnd.randrange(256) for _ in range(d)])


def selftest():
    # published check value of CRC-15/CAN (CRC catalogue): 0x059E over "123456789" - the specification register is bit serial
    bits = [b for ch in b"123456789" for b in to_bits(ch, 8)]
    assert crc15(bits) == 0x059E, hex(crc15(bits))
    rnd = random.Random(1)
    n_end_stuff = 0
    for _ in range(3000):
        f = random_frame(rnd)
        w = f.wire(ack=0)
        r = decode_wire(w)
        assert not r["errors"] and r["id"] == f.ident and r["data"] == f.data and r["crc_ok"] and r["ack"] == 0, (f.ident, f.data, r)
        # no six equal bits inside the stuffed region
        sl = f.stuffed_len()
        reg = w[:sl]
        for i in range(len(reg) - 5):
            assert len(set(reg[i:i + 6])) > 1
        pre = f.pre_crc() + to_bits(crc15(f.pre_crc()), 15)
        if len(stuff(pre)) > len(stuff(pre[:-1])) + 1:
            n_end_stuff += 1
    # special frames
    assert stuff([0] * 5) == [0] * 5 + [1]
    assert stuff([0] * 10) == [0] * 5 + [1] + [0] * 5 + [1]
    assert stuff([1, 0, 1, 0]) == [1, 0, 1, 0]
    print("can_model selftest ok; frames whose last CRC bits force a trailing stuff bit:", n_end_stuff)


if __name__ == "__main__":
    selftest()
