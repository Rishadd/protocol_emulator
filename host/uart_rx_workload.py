#!/usr/bin/env python3
"""UART RX workload: a Python 'phone' drives bt_rx_pin of the real engine running
uart_rx_prog.hex (tb_uart_rx.v); the bytes popped from rx_fifo / shown on the LEDs are
compared with the bytes sent. Also measures where each IN1 sample lands inside its bit and
how much phone baud error the receiver tolerates.
"""
import argparse
import os
import random
import subprocess
import sys
import time

import uart_rx_prog as rxp
import uart_workload as uw

CYC_NS = 10          # tb clock period (tb_*.v use #5 half period); firmware only counts cycles
SYNC_NS = 2 * CYC_NS  # pin_block: IN1 at edge T reads the pin as it was at edge T-2
BUILD = os.path.join(uw.ROOT, "build", "rx_workload")
HEX = os.path.join(uw.ROOT, "src", "fpga", "uart_rx_prog.hex")


def make_edges(payload, gaps, bit_ns, rng, jitter_ns=0):
    """Rx-line edges for 8N1 LSB-first frames. Each start edge gets a random sub-clock phase.
    Returns (edges[(ns, level)], start_edge_ns per frame, end_ns)."""
    t, level, edges, starts = 2000.0, 1, [], []
    for i, b in enumerate(payload):
        t += gaps[i] * CYC_NS + rng.uniform(0, CYC_NS)
        bits = [0] + [(b >> k) & 1 for k in range(8)] + [1]
        for k, bit in enumerate(bits):
            if bit != level:
                et = round(t + k * bit_ns + (rng.uniform(-jitter_ns, jitter_ns) if k else 0))
                edges.append((et, bit))
                level = bit
                if k == 0:
                    starts.append(et)
        t += 10 * bit_ns
    return edges, starts, round(t + 12 * bit_ns)


def compile_tb():
    os.makedirs(BUILD, exist_ok=True)
    vvp = os.path.join(BUILD, "tb_uart_rx.vvp")
    srcs = [os.path.join(uw.ROOT, "src", f) for f in sorted(os.listdir(os.path.join(uw.ROOT, "src")))
            if f.endswith(".v")]
    subprocess.run(["iverilog", "-g2012", *uw.SIM_DEFS, "-I", os.path.join(uw.ROOT, "src"), "-o", vvp,
                    os.path.join(uw.ROOT, "tb", "tb_uart_rx.v")] + srcs + uw.SIM_LIBS, check=True)
    return vvp


def run_case(vvp, tag, baud, payload, gaps, err_pct=0.0, jitter_ns=0, seed=1):
    rng = random.Random(seed)
    D = round(uw.F_CLK / baud) - 2
    prog_f = os.path.join(BUILD, f"{tag}_prog.hex")
    edges_f = os.path.join(BUILD, f"{tag}_edges.txt")
    out_f = os.path.join(BUILD, f"{tag}_out.txt")
    rxp.write_hex(prog_f, D, baud)
    bit_ns = uw.F_CLK / baud * CYC_NS * (1 + err_pct / 100)
    edges, starts, end = make_edges(payload, gaps, bit_ns, rng, jitter_ns)
    with open(edges_f, "w") as f:
        for t, lv in edges:
            f.write(f"{t} {lv}\n")
    t0 = time.time()
    subprocess.run(["vvp", "-n", vvp, f"+PROG={prog_f}", f"+EDGES={edges_f}", f"+OUT={out_f}",
                    f"+TEND={end}"], check=True, capture_output=True)
    wall = time.time() - t0

    samples, pops, status = [], [], {}
    for line in open(out_f):
        p = line.split()
        if p[0] == "S":
            samples.append(int(p[1]))
        elif p[0] == "B":
            pops.append((int(p[1]), int(p[2])))
        elif p[0] == "STATUS":
            status = dict(kv.split("=") for kv in p[1:])
    got = bytes(b for _, b in pops)
    bad = next((i for i in range(min(len(got), len(payload))) if got[i] != payload[i]), None)
    ok = (got == bytes(payload) and status.get("fault") == "0" and status.get("ledmis") == "0")

    # sample position: offset (cycles) of each IN1 from the centre of its data bit
    offs = []
    if len(samples) >= 8 * len(starts):
        for i, s0 in enumerate(starts):
            for k in range(8):
                offs.append((samples[8 * i + k] - SYNC_NS - (s0 + (k + 1.5) * bit_ns)) / CYC_NS)
    # LED update latency from start edge, in bit times (< 10 means before the stop bit ends)
    lat = [(p[0] - s) / bit_ns for p, s in zip(pops, starts)]
    return dict(tag=tag, baud=baud, err=err_pct, n=len(payload), ok=ok, got=len(got), bad=bad,
                offs=offs, lat=lat, wall=wall, status=status)


def show(r):
    o, la = r["offs"], r["lat"]
    span = f"{min(o):+7.1f}..{max(o):+7.1f}" if o else "    n/a"
    lat = f"{max(la):5.2f}" if la else "  n/a"
    print(f"{r['tag']:<12} {r['baud']:>7} {r['err']:>+6.1f}% {r['n']:>5} {r['got']:>5}  "
          f"{'PASS' if r['ok'] else 'FAIL'}  sample-vs-centre(cyc) {span}  max-latency(bit) {lat}  "
          f"{r['wall']:5.1f}s {r['status']}")
    if r["bad"] is not None:
        print(f"             first mismatch at byte {r['bad']}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--budget", type=float, default=12e6, help="max simulated cycles per run")
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--sweep-step", type=float, default=0.5)
    args = ap.parse_args()
    fails = 0

    vvp = compile_tb()
    payload = uw.make_payload()

    # F11: the committed hex must be exactly what the generator produces
    gen = os.path.join(BUILD, "gen_115200.hex")
    rxp.write_hex(gen, 432, 115200)
    same = open(gen).read() == open(HEX).read()
    print(f"committed uart_rx_prog.hex == generator output: {'PASS' if same else 'FAIL'}")
    fails += not same

    print(f"{'run':<12} {'baud':>7} {'err':>7} {'sent':>5} {'got':>5}  result")

    def sized(baud, want):
        cpb = round(uw.F_CLK / baud)
        gaps = uw.make_gaps(len(payload), cpb, args.seed)
        n = min(want, len(payload))
        while n > 1 and n * 10 * cpb + sum(gaps[:n]) > args.budget:
            n -= 1
        return payload[:n], gaps[:n]

    for tag, baud, want in (("nominal", 115200, 1024), ("9600", 9600, 48)):
        p, g = sized(baud, want)
        r = run_case(vvp, tag, baud, p, g, seed=args.seed)
        show(r)
        fails += not r["ok"]

    p, g = sized(115200, 128)
    r = run_case(vvp, "jitter+-20ns", 115200, p, g, jitter_ns=20, seed=args.seed)
    show(r)
    fails += not r["ok"]

    # back-to-back (zero idle) worst case + baud-error sweep
    sweep = bytes([0x00, 0xFF, 0x55, 0xAA, 0x80, 0x01, 0x7F, 0xFE, 0x0F, 0xF0, 0x33, 0xCC,
                   0x81, 0x7E, 0xC0, 0x03] * 4)
    zero = [0] * len(sweep)
    print("\nphone baud error sweep @115200, zero idle between frames:")
    res = {}
    steps = int(7 / args.sweep_step)
    for s in range(-steps, steps + 1):
        e = s * args.sweep_step
        res[e] = run_case(vvp, f"err{e:+.1f}", 115200, sweep, zero, err_pct=e, seed=args.seed)
        show(res[e])
    tol = {}
    for sign in (+1, -1):
        best = 0.0
        for s in range(0, steps + 1):
            e = sign * s * args.sweep_step
            if not res[e]["ok"]:
                break
            best = abs(e)
        tol[sign] = best
    print(f"\nrx baud tolerance: +{tol[+1]:.1f}% / -{tol[-1]:.1f}% (theory ~ +-5%)")
    if min(tol.values()) < 4.0:
        print("FAIL: tolerance below the 4% target")
        fails += 1

    print(f"\n{'ALL PASS' if not fails else str(fails) + ' FAILURE(S)'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
