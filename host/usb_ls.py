#!/usr/bin/env python3
"""USB 2.0 low-speed signalling and packets, written from the specification (chapters 7 and 8), independent of the line coder and of
the firmware. Used by the line-coder test and by the USB host peer model.

  bits / symbols     SYNC, NRZI, bit stuffing, EOP:                        packet_symbols(), decode_runs()
  waveform           symbols -> timed pin levels (rate offset, jitter):    waveform(), runs_from_events()
  packets            tokens (CRC5), data (CRC16), handshakes:              token(), data_packet(), handshake(), parse()
Low speed: 1.5 Mbit/s (bit time 666.67 ns), idle = J = D- high / D+ low, K = D+ high / D- low, SE0 = both low.
A "run" is (symbol, n_bit_times): the line stays at one symbol for n bit times.
"""
import random

import crc_model as cm

T_BIT = 1000.0 / 1.5                      # ns
PID = dict(OUT=0x1, IN=0x9, SOF=0x5, SETUP=0xD, DATA0=0x3, DATA1=0xB, DATA2=0x7, MDATA=0xF, ACK=0x2, NAK=0xA, STALL=0xE, NYET=0x6, PRE=0xC)
PID_NAME = {v: k for k, v in PID.items()}
SYNC = 0x80                                # KJKJKJKK as NRZI of the bits 0,0,0,0,0,0,0,1


def pid_byte(p):
    return (p & 15) | ((~p & 15) << 4)


def crc5(v11):
    """CRC5 of the 11-bit address+endpoint field, in the form that is transmitted in bits [15:11] of the token."""
    c = cm.make("CRC-5/USB")
    for i in range(11):
        c.feed_bit(v11 >> i & 1)
    return c.value()


def crc16(data):
    return cm.make("CRC-16/USB").of(bytes(data))


def token(pid, addr, ep):
    v = (addr & 0x7F) | (ep & 0xF) << 7
    v |= crc5(v) << 11
    return bytes([pid_byte(PID[pid]), v & 0xFF, v >> 8])


def data_packet(pid, payload):
    c = crc16(payload)
    return bytes([pid_byte(PID[pid])]) + bytes(payload) + bytes([c & 0xFF, c >> 8])


def handshake(pid):
    return bytes([pid_byte(PID[pid])])


def parse(pkt):
    """Check a received packet (bytes after SYNC). Returns dict(pid=name, ...) or raises ValueError with the reason."""
    if not pkt:
        raise ValueError("empty packet")
    p = pkt[0]
    if (p & 15) != (~p >> 4 & 15):
        raise ValueError(f"PID check bits wrong: 0x{p:02X}")
    name = PID_NAME.get(p & 15)
    if name is None:
        raise ValueError(f"unknown PID 0x{p & 15:X}")
    if name in ("OUT", "IN", "SETUP", "SOF"):
        if len(pkt) != 3:
            raise ValueError(f"token of {len(pkt)} bytes")
        v = pkt[1] | pkt[2] << 8
        if crc5(v & 0x7FF) != v >> 11:
            raise ValueError("CRC5 error")
        if name == "SOF":
            return dict(pid=name, frame=v & 0x7FF)
        return dict(pid=name, addr=v & 0x7F, ep=v >> 7 & 0xF)
    if name in ("ACK", "NAK", "STALL", "NYET"):
        if len(pkt) != 1:
            raise ValueError("handshake with extra bytes")
        return dict(pid=name)
    if name.startswith("DATA") or name == "MDATA":
        if len(pkt) < 3:
            raise ValueError("data packet without CRC")
        if crc16(pkt[1:-2]) != pkt[-2] | pkt[-1] << 8:
            raise ValueError("CRC16 error")
        return dict(pid=name, data=bytes(pkt[1:-2]))
    return dict(pid=name)


# ------------------------------------------------------------------ bits -> symbols
def to_bits(data):
    return [b >> i & 1 for b in data for i in range(8)]                    # LSB first


def stuff(bits, run=6):
    out, ones = [], 0
    for b in bits:
        out.append(b)
        ones = ones + 1 if b else 0
        if ones == run:
            out.append(0)                                                   # also after the very last bit
            ones = 0
    return out


def nrzi(bits, start="J"):
    s, out = start, []
    for b in bits:
        if b == 0:
            s = "K" if s == "J" else "J"
        out.append(s)
    return out


def packet_symbols(pkt, sync=SYNC, eop=True):
    """One symbol per bit time: SYNC + packet through stuffing and NRZI, then the EOP (SE0, SE0, J)."""
    syms = nrzi(stuff(to_bits(bytes([sync]) + bytes(pkt))))
    return syms + (["0", "0", "J"] if eop else [])


def runs(symbols):
    out = []
    for s in symbols:
        if out and out[-1][0] == s:
            out[-1][1] += 1
        else:
            out.append([s, 1])
    return [(s, n) for s, n in out]


def decode_runs(rs, run=6):
    """Decode the runs of one packet that starts with the first K after idle J and ends with SE0 runs.
    Returns (bytes, partial_bits, errors) - errors lists stuff violations."""
    bits, errs = [], []
    prev = "J"
    for s, n in rs:
        if s == "0":
            break
        if s == prev:
            raise ValueError("two runs of the same symbol")
        bits += [0] + [1] * (n - 1)
        prev = s
    # destuff
    out, ones, i = [], 0, 0
    for b in bits:
        if ones == run:
            if b:
                errs.append("stuff violation")
            ones = 0
            continue
        out.append(b)
        ones = ones + 1 if b else 0
    if out[:8] != [0] * 7 + [1] and not (len(out) >= 4):
        errs.append("no SYNC")
    body = out[8:]
    data = bytes(sum(body[8 * j + i] << i for i in range(8)) for j in range(len(body) // 8))
    return data, len(body) % 8, errs


# ------------------------------------------------------------------ symbols -> timed pin levels
LEVEL = {"J": (0, 1), "K": (1, 0), "0": (0, 0)}                             # (D+, D-) of a low-speed device / host driver


def waveform(symbols, t0, T=T_BIT, jitter_ns=0.0, rng=None, release_after_j=True):
    """Timed pin changes [(t_ns, dp, dm, oe)] for a symbol list: each symbol lasts T (+ jitter on every edge). The driver is released
    (oe = 0, the bus returns to J by its pull-up) after the final J of an EOP."""
    rng = rng or random.Random(0)
    ev, t = [], t0
    for i, s in enumerate(symbols):
        te = t0 + i * T + (rng.uniform(-jitter_ns, jitter_ns) if i else 0.0)
        dp, dm = LEVEL[s]
        ev.append((te, dp, dm, 1))
    end = t0 + len(symbols) * T
    if release_after_j:
        ev.append((end, 0, 1, 0))
    return ev


def runs_from_events(changes, T=T_BIT):
    """Bus change log [(t_ns, dp, dm)] -> list of packets, each a list of runs (symbol, n_bit_times) from the first K to the SE0 run(s)
    (the final J of the EOP is dropped). Run lengths are rounded to whole bit times: the line coder must be within 0.5 bit of nominal."""
    sym = {(0, 1): "J", (1, 0): "K", (0, 0): "0", (1, 1): "1"}
    pk, cur, last = [], None, None            # last: (t, symbol)
    seq = [(t, sym[(a, b)]) for t, a, b in changes]
    seq.append((seq[-1][0] + 10 * T, "J"))
    for (t, s), (t2, _) in zip(seq, seq[1:]):
        n = (t2 - t) / T
        if cur is None:
            if s == "K":
                cur = [[s, n]]
        else:
            if s == "J" and cur[-1][0] == "0":
                pk.append(cur)
                cur = None
            else:
                cur.append([s, n])
    return [[(s, n) for s, n in p] for p in pk]


def run_bits(rs):
    return [(s, round(n), n) for s, n in rs]


def packets_from_events(changes, run=6):
    out = []
    for p in runs_from_events(changes):
        r = [(s, round(n)) for s, n in p]
        out.append(decode_runs(r, run))
    return out


def selftest():
    # known vectors: SETUP to address 0 endpoint 0 is 2D 00 10; IN to address 0x15 endpoint 0xE has CRC5 0x17; ACK is D2, NAK 5A
    assert token("SETUP", 0, 0) == bytes([0x2D, 0x00, 0x10]), token("SETUP", 0, 0).hex()
    assert handshake("ACK") == bytes([0xD2]) and handshake("NAK") == bytes([0x5A]) and handshake("STALL") == bytes([0x1E])
    for pkt in (token("OUT", 5, 3), data_packet("DATA1", b"\x01\x02\x03"), data_packet("DATA0", b""), handshake("ACK")):
        syms = packet_symbols(pkt)
        r = runs(syms)
        rr = [x for x in r]
        d, partial, errs = decode_runs(rr[:-1] if rr[-1][0] == "J" else rr)
        assert not errs and partial == 0 and d == pkt, (d, pkt)
        assert parse(d)
    # six ones then a stuffed zero
    assert stuff([1] * 6) == [1] * 6 + [0] and stuff([1] * 12) == [1] * 6 + [0] + [1] * 6 + [0]
    print("usb_ls selftest ok")


if __name__ == "__main__":
    selftest()
