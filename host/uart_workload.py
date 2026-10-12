#!/usr/bin/env python3
"""UART TX workload: Python host/reference model vs the Verilog engine.

For every baud rate this script
  1. assembles the 12-word UART TX program for that baud,
  2. generates a 1 KB payload full of edge cases plus a host "silence" schedule,
  3. runs the Verilog engine (tb_uart_workload) as the transmitter,
  4. decodes the resulting pin waveform with an ideal UART receiver running at the
     *nominal* baud (so the engine's integer-divider error is really exercised),
  5. compares every frame cycle-exactly against the Python reference waveform,
  6. measures how much receiver clock error the waveform tolerates.
"""
import argparse
import bisect
import glob
import os
import random
import subprocess
import sys
import time

os.chdir(os.path.dirname(os.path.abspath(__file__)))
ROOT = os.path.abspath("..")
BUILD = os.path.join(ROOT, "build", "workload")
F_CLK = 50_000_000
if os.name == "nt" and os.path.isdir(r"C:\iverilog\bin"):
    os.environ["PATH"] += os.pathsep + r"C:\iverilog\bin"

# instr_mem is two IHP SG13 SRAM macros (1P 64x16), simulated with the PDK functional models in
# sim/ihp_sram. Every harness compiles the RTL with these lists.
SIM_DEFS = ["-DFUNCTIONAL"]
SIM_LIBS = sorted(glob.glob(os.path.join(ROOT, "sim", "ihp_sram", "*.v")))   # every vendored SRAM model

STANDARD_BAUDS = [300, 600, 1200, 2400, 4800, 9600, 14400, 19200, 28800, 38400,
                  57600, 76800, 115200, 230400, 460800, 921600,
                  1_000_000, 1_500_000, 2_000_000, 3_000_000]

OP = dict(NOP=0, WAIT=1, JMP=2, HALT=3, SETL=4, DJNZ=5, PULL=6, PUSH=7, OUT1=8, IN1=9,
          SETH=10, SETLO=11, DIRO=12, DIRI=13, WAITH=14, WAITL=15, CFG=16)


def word(op, operand=0):
    return (OP[op] << 27) | (operand & 0x7FFFFFF)


def uart_tx_program(D):
    """The verified 12-word program from instructions.md; bit period = D+2 cycles."""
    prog = [
        word("CFG", 0), word("SETH", 0), word("DIRO", 0),
        word("PULL"), word("SETL", 8), word("SETLO", 0), word("WAIT", D),
        word("OUT1", D), word("DJNZ", 7), word("SETH", 0), word("WAIT", D), word("JMP", 3),
    ]
    return prog + [word("HALT")] * (64 - len(prog))


# ----------------------------------------------------------------------------- payload
def make_payload():
    """Exactly 1024 bytes: readable text, numbers, symbols, every byte value,
    long same-level runs, alternating patterns, UTF-8, control characters."""
    parts = []
    parts.append(
        b"The quick brown fox jumps over the lazy dog. 0123456789 "
        b"!\"#$%&'()*+,-./:;<=>?@[\\]^_`{|}~ "
        b"UART TX workload test: 8N1, LSB first, host-paced with silence gaps.\r\n"
        b"Pi=3.14159265358979, e=2.718281828, -273.15C, 6.022e23, 0xDEADBEEF, 0b10101010\r\n"
        b"Line with tab\tand ESC \x1b[0m and BEL \x07 and NUL \x00 and DEL \x7f end.\r\n")
    parts.append(bytes(range(256)))                     # every bit pattern once
    parts.append(b"\x00" * 8 + b"\xff" * 8 + b"\x55" * 8 + b"\xaa" * 8)   # long runs / max toggling
    parts.append(bytes([0x01, 0x80, 0x7f, 0xfe, 0x0f, 0xf0, 0x33, 0xcc] * 4))
    parts.append("naïve café — 日本語 ✓ € ünïcödé ñ ß ø\r\n".encode("utf-8"))
    parts.append(b"\xff\x00" * 16 + b"\x00\xff" * 16)  # stop->start with zero idle, start after 0xFF
    parts.append(b"CSV,1,2,3,-4,5.5,6e6,\"quoted, comma\",end\n")
    parts.append(b"0" * 32 + b"1" * 32 + b"Az" * 16)
    payload = b"".join(parts)
    filler = (b"Lorem ipsum dolor sit amet, consectetur adipiscing elit, sed do eiusmod "
              b"tempor incididunt ut labore et dolore magna aliqua. ")
    while len(payload) < 1024:
        payload += filler
    payload = payload[:1024]
    assert len(payload) == 1024
    assert set(payload) == set(range(256))
    return payload


def make_gaps(n, cpb, seed=1):
    """Idle cycles the host waits before writing byte i. Mostly bursts (0), some
    sub-frame jitter, occasional multi-frame silence, a few long silences."""
    rng = random.Random(seed)
    frame = 10 * cpb
    gaps = []
    for i in range(n):
        r = rng.random()
        if r < 0.70:
            g = 0
        elif r < 0.90:
            g = rng.randint(1, cpb)
        elif r < 0.98:
            g = rng.randint(2 * frame, 5 * frame)
        else:
            g = 20 * frame
        gaps.append(g)
    gaps[1] = 20 * frame          # silence right after the very first byte
    gaps[8 * 1 + 256 + 3] = 20 * frame   # silence inside the 0x00 run
    return gaps


# ----------------------------------------------------------------------------- reference model
def frame_bits(b):
    """Python UART TX reference: start, 8 data bits LSB first, stop."""
    return [0] + [(b >> i) & 1 for i in range(8)] + [1]


def ref_edge_offsets(b, cpb):
    """Cycle offsets (from start edge) at which the reference waveform toggles inside the frame."""
    bits = frame_bits(b)
    return [k * cpb for k in range(1, 10) if bits[k] != bits[k - 1]]


# ----------------------------------------------------------------------------- file / sim plumbing
def write_hex(path, values, digits):
    with open(path, "w") as f:
        for v in values:
            f.write(f"{v:0{digits}x}\n")


def compile_tb():
    os.makedirs(BUILD, exist_ok=True)
    vvp = os.path.join(BUILD, "tb_uart_workload.vvp")
    srcs = [os.path.join(ROOT, "src", f) for f in sorted(os.listdir(os.path.join(ROOT, "src")))
            if f.endswith(".v")]
    cmd = ["iverilog", "-g2012", *SIM_DEFS, "-s", "tb_uart_workload", "-I", os.path.join(ROOT, "src"),
           "-o", vvp, os.path.join(ROOT, "tb", "tb_uart_workload.v")] + srcs + SIM_LIBS
    subprocess.run(cmd, check=True)
    return vvp


def run_sim(vvp, tag, D, payload, gaps, cpb, nowait=0):
    prog_f = os.path.join(BUILD, f"{tag}_prog.hex")
    data_f = os.path.join(BUILD, f"{tag}_data.hex")
    gaps_f = os.path.join(BUILD, f"{tag}_gaps.hex")
    out_f = os.path.join(BUILD, f"{tag}_edges.txt")
    write_hex(prog_f, uart_tx_program(D), 8)
    write_hex(data_f, payload, 2)
    write_hex(gaps_f, gaps, 8)
    cmd = ["vvp", "-n", vvp, f"+PROG={prog_f}", f"+DATA={data_f}", f"+GAPS={gaps_f}",
           f"+OUT={out_f}", f"+N={len(payload)}", f"+CPB={cpb}", f"+NOWAIT={nowait}"]
    t0 = time.time()
    subprocess.run(cmd, check=True, capture_output=True)
    return out_f, time.time() - t0


def parse_edges(path):
    cycles, levels, status, end = [], [], {}, None
    with open(path) as f:
        for line in f:
            p = line.split()
            if p[0] == "END":
                end = int(p[1])
            elif p[0] == "STATUS":
                status = dict(kv.split("=") for kv in p[1:])
            else:
                cycles.append(int(p[0]))
                levels.append(int(p[1]))
    return cycles, levels, end, status


# ----------------------------------------------------------------------------- receiver / checker
class Waveform:
    def __init__(self, cycles, levels):
        self.c, self.l = cycles, levels

    def level_at(self, t):
        i = bisect.bisect_right(self.c, t) - 1
        return self.l[i] if i >= 0 else 0

    def next_fall(self, t):
        i = bisect.bisect_left(self.c, t)
        while i < len(self.c) and self.l[i] != 0:
            i += 1
        return self.c[i] if i < len(self.c) else None

    def first_high(self):
        for c, l in zip(self.c, self.l):
            if l == 1:
                return c
        return None


def decode(wf, bit, start):
    """Ideal 8N1 receiver: hunt for falling edge, sample mid-bit at its own nominal bit length."""
    frames, t = [], start
    while True:
        t0 = wf.next_fall(t)
        if t0 is None:
            return frames
        s = [wf.level_at(t0 + bit * (k + 0.5)) for k in range(10)]
        byte = sum(s[1 + k] << k for k in range(8))
        frames.append((t0, byte, s[0] == 0, s[9] == 1))
        t = t0 + bit * 9.5


def check_exact(wf, frames, payload, cpb):
    """Every frame's transitions must sit exactly on the Python reference's bit boundaries,
    and the stop bit must last at least one full bit."""
    exact = 0
    bad = []
    for i, (t0, byte, _, _) in enumerate(frames):
        if i >= len(payload):
            break
        want = set(t0 + off for off in ref_edge_offsets(payload[i], cpb))
        lo = bisect.bisect_right(wf.c, t0)
        hi = bisect.bisect_right(wf.c, t0 + 9 * cpb)
        got = set(wf.c[lo:hi])
        nxt = wf.next_fall(t0 + 9 * cpb + 1)
        stop_ok = nxt is None or nxt >= t0 + 10 * cpb
        if got == want and stop_ok:
            exact += 1
        elif len(bad) < 3:
            bad.append((i, sorted(x - t0 for x in got), sorted(x - t0 for x in want), stop_ok))
    return exact, bad


def rx_tolerance(wf, bit_nominal, start, payload):
    """Largest receiver clock error (percent, each sign) that still decodes every byte."""
    def ok(bit):
        fr = decode(wf, bit, start)
        return len(fr) == len(payload) and all(
            f[1] == payload[i] and f[2] and f[3] for i, f in enumerate(fr))
    res = {}
    for sign in (+1, -1):
        best = 0.0
        off = 0.0
        while off <= 12.0 and ok(bit_nominal * (1 + sign * off / 100)):
            best = off
            off += 0.25
        res[sign] = best
    return res[+1], res[-1]


# ----------------------------------------------------------------------------- one run
def run_case(vvp, tag, baud, D, payload, gaps, nowait=0, quiet=False):
    cpb = D + 2
    out_f, wall = run_sim(vvp, tag, D, payload, gaps, cpb, nowait)
    cycles, levels, end, status = parse_edges(out_f)
    wf = Waveform(cycles, levels)
    start = wf.first_high()
    bit_nominal = F_CLK / baud
    frames = decode(wf, bit_nominal, start)
    n = len(payload)
    decoded = bytes(f[1] for f in frames[:n])
    byte_ok = sum(1 for i, f in enumerate(frames[:n]) if f[1] == payload[i] and f[2] and f[3])
    exact, bad = check_exact(wf, frames, payload, cpb)
    tol_p, tol_m = rx_tolerance(wf, bit_nominal, start, payload) if byte_ok == n else (0, 0)
    actual_baud = F_CLK / cpb
    err = (actual_baud - baud) / baud * 100
    r = dict(baud=baud, cpb=cpb, D=D, actual=actual_baud, err=err, n=n, frames=len(frames),
             byte_ok=byte_ok, exact=exact, bad=bad, cycles=end, wall=wall, status=status,
             tol_p=tol_p, tol_m=tol_m, decoded=decoded)
    if not quiet:
        print_row(r)
    return r


def print_header():
    print(f"{'baud':>8} {'cpb':>6} {'D':>6} {'actual':>10} {'err%':>7} {'bytes':>5} "
          f"{'frames':>6} {'byteOK':>6} {'exact':>5} {'rxtol+%':>7} {'rxtol-%':>7} "
          f"{'Mcycles':>7} {'wall s':>6}  status")


def print_row(r):
    st = r["status"]
    flag = "PASS" if (r["byte_ok"] == r["n"] and r["exact"] == r["n"] and r["frames"] == r["n"]
                      and st.get("fault") == "0" and st.get("oe") == "1") else "FAIL"
    print(f"{r['baud']:>8} {r['cpb']:>6} {r['D']:>6} {r['actual']:>10.1f} {r['err']:>+7.3f} {r['n']:>5} "
          f"{r['frames']:>6} {r['byte_ok']:>6} {r['exact']:>5} {r['tol_p']:>7.2f} {r['tol_m']:>7.2f} "
          f"{r['cycles']/1e6:>7.2f} {r['wall']:>6.1f}  {flag} pc={st.get('pc')} fault={st.get('fault')} "
          f"rejected={st.get('rejected')}")
    for b in r["bad"]:
        print(f"           frame {b[0]}: got edges {b[1]} want {b[2]} stop_ok={b[3]}")


# ----------------------------------------------------------------------------- main
def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--bauds", type=int, nargs="*", default=STANDARD_BAUDS)
    ap.add_argument("--budget", type=float, default=25e6,
                    help="max simulated cycles per run; slow bauds get a payload prefix")
    ap.add_argument("--limits", action="store_true", help="also run the breaking-point tests")
    ap.add_argument("--seed", type=int, default=1)
    args = ap.parse_args()

    vvp = compile_tb()
    payload = make_payload()
    with open(os.path.join(BUILD, "payload.bin"), "wb") as f:
        f.write(payload)

    print(f"payload: {len(payload)} bytes, {len(set(payload))} distinct byte values, "
          f"f_clk={F_CLK/1e6:.0f} MHz, cycle budget/run={args.budget/1e6:.0f}M")
    print_header()
    results = []
    for baud in args.bauds:
        cpb = round(F_CLK / baud)
        D = cpb - 2
        gaps = make_gaps(len(payload), cpb, args.seed)
        # silence gaps are paid for in sim time too; budget on frames + gaps
        n = len(payload)
        while n > 1 and (n * 10 * cpb + sum(gaps[:n])) > args.budget:
            n -= 1
        results.append(run_case(vvp, f"b{baud}", baud, D, payload[:n], gaps[:n]))

    if args.limits:
        print("\n--- limit tests ---")
        sub = payload[:64]
        print("D=0 -> 2 cycles/bit = 25 Mbaud (fastest the loop can go):")
        print_header()
        run_case(vvp, "lim_D0", F_CLK / 2, 0, sub, [0] * 64)
        print("D=1 -> 3 cycles/bit = 16.67 Mbaud:")
        run_case(vvp, "lim_D1", F_CLK / 3, 1, sub, [0] * 64)
        print("host ignores tx_full (writes 1 KB back-to-back into a 4-deep FIFO) @115200:")
        r = run_case(vvp, "lim_nowait", 115200, 432, payload, [0] * len(payload), nowait=1, quiet=True)
        print_row(r)
        kept = r["decoded"]
        print(f"   engine transmitted {len(r['decoded'])} of 1024 bytes; first 8 kept: {kept[:8].hex()} "
              f"(payload starts {payload[:8].hex()}); every transmitted frame exact={r['exact']==r['frames']}")
        print("odd D (bit period 435 cycles) still exact:")
        run_case(vvp, "lim_odd", F_CLK / 435, 433, sub, [0] * 64)

    fails = [r for r in results if not (r["byte_ok"] == r["n"] and r["exact"] == r["n"])]
    print(f"\n{len(results) - len(fails)}/{len(results)} baud rates fully PASS "
          f"(all bytes decoded, all frames cycle-exact vs Python reference)")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
