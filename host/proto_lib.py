#!/usr/bin/env python3
"""Shared helpers for the protocol tests that use tb/tb_proto.v (two engines on one 8-pin pad bus).

run(name, progs={0: words, 1: words}, htx={0: [words], 1: [...]}, od=0x00, ext=0x00, stim=[(t_ns, pads)], dur_ns=..., own={0: mask, 1: mask})
  -> dict(P=[(t_ns, pad_byte)], A=[(t_ns, word)], B=[(t_ns, word)], END={...})
With the environment variable PROTO_CHIP=1 (or run(..., chip=True)) the same test runs on the FULL chip (tb/tb_chip_proto.v): pads are claimed,
programs loaded and TX/RX words moved only through the management SPI link; `od` then selects the open-drain pad claims and `own` the pads
claimed by each engine (default: all pads for engine 0, or for engine 1 when it is the only one with a program). Times are relative to the start of the run.
Decoders are written from the protocol rules only (independent of the firmware):  timeline(), uart_decode().
1 clock = 20 ns (50 MHz).
"""
import glob
import os
import random
import subprocess

import spi_prog as sp

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
BUILD = os.path.join(ROOT, "build", "proto")
if os.name == "nt" and os.path.isdir(r"C:\iverilog\bin"):
    os.environ["PATH"] += os.pathsep + r"C:\iverilog\bin"
SIM_LIBS = [os.path.join(ROOT, "sim", "ihp_sram", f) for f in
            ("RM_IHPSG13_1P_core_behavioral_bm_bist.v", "RM_IHPSG13_1P_256x32_c2_bm_bist.v")]
NS_PER_CLK = 20
F_CLK = 50_000_000
EV = 1 << 26

CHIP = os.environ.get("PROTO_CHIP", "") == "1"
SHARED = os.environ.get("PROTO_SHARED", "") == "1"      # chip-level runs on the shared 512-word memory (-DSHARED_IMEM): engine 0 at word 0, engine 1 at word 256
SIM_LIBS_SHARED = [os.path.join(ROOT, "sim", "ihp_sram", f) for f in
                   ("RM_IHPSG13_2P_512x32_c2_bm_bist.v", "RM_IHPSG13_2P_core_behavioral_bm_bist_ideal.v",
                    "RM_IHPSG13_1P_256x32_c2_bm_bist.v", "RM_IHPSG13_1P_core_behavioral_bm_bist.v")]
JUMP_OPS = (2, 5, 17, 18, 19, 23)                       # JMP DJNZ JPH JPL JPO JCC: operand [7:0] is a program address; shared mode: bit 11 is address bit 8
_vvp = None


def _newest_input():
    files = glob.glob(os.path.join(ROOT, "src", "*.v")) + glob.glob(os.path.join(ROOT, "tb", "tb_*proto.v")) + glob.glob(os.path.join(ROOT, "tb", "*.vh")) + \
        glob.glob(os.path.join(ROOT, "tb", "peer_*.v")) + glob.glob(os.path.join(ROOT, "src", "*.vh"))
    return max(os.path.getmtime(f) for f in files)


def compile_tb(extra_srcs=(), tag=None, chip=None):
    global _vvp
    chip = CHIP if chip is None else chip
    tag = tag or ("tb_chip_proto" if chip else "tb_proto")
    shared = SHARED and chip
    os.makedirs(BUILD, exist_ok=True)
    out = os.path.join(BUILD, tag + ("_shared" if shared else "") + ".vvp")
    if not os.path.exists(out) or os.path.getmtime(out) < _newest_input():
        srcs = sorted(glob.glob(os.path.join(ROOT, "src", "*.v"))) + (SIM_LIBS_SHARED if shared else SIM_LIBS) + sorted(
            glob.glob(os.path.join(ROOT, "tb", "peer_*.v"))) + list(extra_srcs)
        r = subprocess.run(["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-DFUNCTIONAL"] + (["-DSHARED_IMEM"] if shared else []) +
                           ["-I", os.path.join(ROOT, "src"),
                            "-I", os.path.join(ROOT, "tb"), "-o", out, os.path.join(ROOT, "tb", tag + ".v")] + srcs,
                           capture_output=True, text=True)
        if r.returncode:
            raise RuntimeError("compile failed:\n" + r.stderr[:2000])
    return out


def _safe(name):
    return "".join(c if c.isalnum() or c in "-+=." else "_" for c in name)


REMAP = os.environ.get("PROTO_REMAP", "")


def pin_map(seed, own_mask, od=0, uo_ok=0):
    """Random pin placement for the full chip (tb_chip_proto.v +OLOC/+ILOC; physical codes: 0-7 uio[p], 8-14 uo_out[code-7],
    inputs also 8-12 = ui_in[code-5]). Returns (oloc, iloc) as 8-digit hex strings, nibble l = logical pin l.
    Every logical pin an engine owns gets its own physical output pin (uio, or uo_out when uo_ok allows it: output-only push-pull pins);
    each logical input is read from its own pad or, at random, from another free input node (a wire on the board): that exercises the
    output remap and the input select of the pin manager in every combination. Physical nodes are never shared between two nets."""
    rnd = random.Random(seed)
    uio, uo = list(range(8)), list(range(8, 15))
    rnd.shuffle(uio)
    rnd.shuffle(uo)
    oloc = {}
    for l in range(8):
        if not own_mask >> l & 1:
            oloc[l] = 15
        elif uo_ok >> l & 1 and not od >> l & 1 and rnd.random() < 0.6:
            oloc[l] = uo.pop()
        else:
            oloc[l] = uio.pop()
    free = [p for p in uio] + list(range(8, 13))          # input nodes nobody drives (leftover uio pads and ui_in[7:3])
    rnd.shuffle(free)
    iloc = {}
    for l in range(8):                                     # pins that need a node of their own first
        if oloc[l] >= 8:
            iloc[l] = free.pop()
    for l in rnd.sample(range(8), 8):                      # the others keep their pad, or move to a free node at random
        if l not in iloc:
            iloc[l] = oloc[l] if oloc[l] < 8 and (rnd.random() < 0.5 or not free) else free.pop()
    for l in range(8):
        assert iloc[l] != 15
    return "".join(f"{oloc[l]:x}" for l in reversed(range(8))), "".join(f"{iloc[l]:x}" for l in reversed(range(8)))


def run(name, progs=None, htx=None, od=0, ext=0, stim=None, dur_ns=1_000_000, peer=0, plus=None, own=None, chip=None, remap=None,
        uo_ok=0):
    """remap = seed of a random pin placement (chip mode; env PROTO_REMAP gives the default), uo_ok = logical pins that may sit on uo_out."""
    chip = CHIP if chip is None else chip
    if remap is None and REMAP:
        remap = int(REMAP)
    uo_ok = uo_ok or int(os.environ.get("PROTO_REMAP_UO", "0"), 0)    # logical pins that are output-only push-pull (e.g. JTAG TCK/TMS/TDI = 0x38)
    if chip and remap:
        own_m = {0: 0xFF if 0 in (progs or {}) else 0, 1: 0xFF if (1 in (progs or {}) and 0 not in (progs or {})) else 0}
        own_m.update(own or {})
        oloc, iloc = pin_map(remap, own_m[0] | own_m[1], od, uo_ok)
        plus = dict(plus or {}, OLOC=oloc, ILOC=iloc)
    # one folder per (case, chip, pin seed, firmware origin): regression suites run in parallel and must not share files
    tag = ("_chip" if chip else "") + (f"_r{remap}" if chip and remap else "") + (f"_o{os.environ['FW_ORG']}" if os.environ.get("FW_ORG") else "") + \
        ("_sh" if SHARED and chip else "")
    d = os.path.join(BUILD, _safe(name) + tag)
    os.makedirs(d, exist_ok=True)
    args = []
    for e, words in (progs or {}).items():
        if SHARED and chip and e == 1:                  # engine 1's image sits at physical word 256: every jump target gets address bit 8 (operand bit 11)
            words = [w | (1 << 11) if (w >> 27) in JUMP_OPS else w for w in words]
        fn = os.path.join(d, f"prog{e}.hex")
        sp.write_hex(words, fn)
        args.append(f"+PROG{e}={fn}")
    for e, words in (htx or {}).items():
        fn = os.path.join(d, f"htx{e}.hex")
        sp.write_hex(words, fn)
        args += [f"+HTX{e}={fn}", f"+N{e}={len(words)}"]
    if stim:
        fn = os.path.join(d, "stim.txt")
        with open(fn, "w") as f:
            for t, v in stim:
                f.write(f"{int(t)} {v:02x}\n")
        args.append(f"+STIM={fn}")
    log = os.path.join(d, "log.txt")
    if chip:
        # the host works through the management SPI link: about 25 us per 56-bit frame, one frame per TX word and per RX word read
        dur_ns += 60_000 * sum(len(w) for w in (htx or {}).values()) + 300_000
    args += [f"+OD={od:x}", f"+EXT={ext:x}", f"+PEER={peer}", f"+DUR_NS={int(dur_ns)}", f"+OUT={log}"]
    for e, m in (own or {}).items():
        args.append(f"+OWN{e}={m:x}")
    args += [f"+{k}={v}" for k, v in (plus or {}).items()]
    r = subprocess.run(["vvp", "-n", compile_tb(chip=chip), *args], capture_output=True, text=True)
    if r.returncode or "ERROR" in r.stdout:
        raise RuntimeError(f"{name}: simulation failed\n{r.stdout}{r.stderr}")
    L = dict(P=[], A=[], B=[], END={}, STDOUT=r.stdout.splitlines())
    for line in open(log):
        p = line.split()
        if not p:
            continue
        if p[0] == "P":
            if "x" in p[2] or "z" in p[2]:
                continue                    # bus not resolved yet (engines still in reset)
            t = int(p[1])
            if L["P"] and L["P"][-1][0] == t:
                L["P"][-1] = (t, int(p[2], 16))
            else:
                L["P"].append((t, int(p[2], 16)))
        elif p[0] in "AB":
            L[p[0]].append((int(p[1]), int(p[2], 16)))
        elif p[0] == "END":
            L["END"] = {k: int(v) for k, v in (x.split("=") for x in p[1:])}
    if chip and (L["END"].get("err", 0) or L["END"].get("viol", 0)):
        raise RuntimeError(f"{name}: management error flag or pin ownership violation on the chip: {L['END']}")
    return L


def timeline(P, pin):
    """Pad log -> [(t_ns, level)] changes of one pin (first entry = initial level)."""
    out, last = [], None
    for t, v in P:
        b = v >> pin & 1
        if b != last:
            out.append((t, b))
            last = b
    return out


# ------------------------------------------------------------------ UART decoder (8N1, LSB first), rules only
def uart_decode(tl, bit_ns, tol_ns=2 * NS_PER_CLK, nbits=8, t_end=None):
    """Return [(t_start, byte, stop_ok, edges_ok)]. edges_ok: every edge inside the frame lies on the bit grid within tol_ns."""
    frames = []
    edges = [t for t, _ in tl[1:]]
    levels = {t: l for t, l in tl}
    i = 0

    def level_at(t):
        lv = tl[0][1]
        for tt, l in tl:
            if tt <= t:
                lv = l
            else:
                break
        return lv
    t_last_end = -1
    for k, (t, l) in enumerate(tl):
        if l != 0 or t < t_last_end or k == 0:
            continue
        t0 = t                                        # falling edge = start bit
        bits = [level_at(t0 + int(bit_ns * (n + 0.5))) for n in range(nbits + 2)]
        if bits[0] != 0:
            continue
        byte = sum(bits[1 + n] << n for n in range(nbits))
        stop_ok = bits[nbits + 1] == 1
        ok = True
        for te in edges:
            if t0 < te < t0 + bit_ns * (nbits + 1) - tol_ns:
                r = ((te - t0) / bit_ns)
                if abs(r - round(r)) * bit_ns > tol_ns:
                    ok = False
        frames.append((t0, byte, stop_ok, ok))
        t_last_end = t0 + int(bit_ns * (nbits + 1))     # stop bit starts here; next start edge can come after the stop bit
    return frames


def uart_wave(frames, cpb, start_ns=1000, idle_bits=0, gap_bits=None, pin=1, others=0xFF):
    """Byte list(s) -> stimulus events [(t_ns, pads)] for the external pin `pin` (8N1, LSB first); `gap_bits` = extra idle
    bit times after each byte (list, same shape as frames, or None). Returns (events, end_time_ns)."""
    bit = cpb * NS_PER_CLK
    ev, t = [(0, others)], start_ns + idle_bits * bit

    def put(level, tt):
        v = (others | 1 << pin) if level else (others & ~(1 << pin))
        if ev[-1][1] != v:
            ev.append((int(tt), v))
    put(1, 0)
    for fi, fr in enumerate(frames):
        for bi, b in enumerate(fr):
            put(0, t)
            for n in range(8):
                put(b >> n & 1, t + (n + 1) * bit)
            put(1, t + 9 * bit)
            t += 10 * bit
            g = gap_bits[fi][bi] if gap_bits else 0
            t += int(g * bit)
    return ev, int(t)
