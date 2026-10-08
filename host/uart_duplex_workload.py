#!/usr/bin/env python3
"""Full-duplex echo check of de0_nano_duplex_top: the fake phone (uart_rx_workload.make_edges)
drives bt_rx_pin while the echo goes out on bt_tx_pin. Checks bytes popped/LEDs, the echoed
bytes (ideal receiver from uart_workload), TX frames cycle-exact, RX samples centred."""
import os
import random
import subprocess
import sys

import uart_rx_workload as rxw
import uart_workload as uw

CPB, BAUD, NS = 434, 115200, rxw.CYC_NS
BUILD = os.path.join(uw.ROOT, "build", "duplex")
PROGS = [f"+{k}={os.path.join(uw.ROOT, 'src', 'fpga', f)}"
         for k, f in (("TXPROG", "uart_tx_prog.hex"), ("RXPROG", "uart_rx_prog.hex"))]


def compile_tb():
    os.makedirs(BUILD, exist_ok=True)
    vvp = os.path.join(BUILD, "tb_uart_duplex.vvp")
    src = [os.path.join(uw.ROOT, "src", f) for f in os.listdir(os.path.join(uw.ROOT, "src")) if f.endswith(".v")]
    subprocess.run(["iverilog", "-g2012", "-I", os.path.join(uw.ROOT, "src"), "-o", vvp,
                    os.path.join(uw.ROOT, "tb", "tb_uart_duplex.v"),
                    os.path.join(uw.ROOT, "src", "fpga", "de0_nano_duplex_top.v")] + src, check=True)
    return vvp


def run(vvp, tag, payload, gaps, err=0.0, jitter=0, seed=1):
    bit_ns = uw.F_CLK / BAUD * NS * (1 + err / 100)
    edges, starts, end = rxw.make_edges(payload, gaps, bit_ns, random.Random(seed), jitter)
    ef, of = (os.path.join(BUILD, f"{tag}_{x}.txt") for x in ("edges", "out"))
    with open(ef, "w") as f:
        f.writelines(f"{t} {lv}\n" for t, lv in edges)
    subprocess.run(["vvp", "-n", vvp, *PROGS, f"+EDGES={ef}", f"+OUT={of}",
                    f"+TEND={end + 250 * CPB * NS}"], check=True, capture_output=True)

    S, B, tc, tl, st = [], [], [], [], {}
    for p in (line.split() for line in open(of)):
        if p[0] == "S": S.append(int(p[1]))
        elif p[0] == "B": B.append(int(p[2]))
        elif p[0] == "T": tc.append(int(p[1]) // NS); tl.append(int(p[2]))
        else: st = dict(kv.split("=") for kv in p[1:])
    wf = uw.Waveform(tc, tl)
    frames = uw.decode(wf, uw.F_CLK / BAUD, wf.first_high())
    echo = bytes(f[1] for f in frames)
    framing = all(f[2] and f[3] for f in frames)
    exact, _ = uw.check_exact(wf, frames, payload, CPB)
    offs = [(S[8 * i + k] - rxw.SYNC_NS - (s + (k + 1.5) * bit_ns)) / NS
            for i, s in enumerate(starts) for k in range(8)] if len(S) >= 8 * len(starts) else [0]
    # full duplex: rx frames that start while an echo frame is on the wire
    overlap = sum(any(f[0] <= s / NS < f[0] + 10 * CPB for f in frames) for s in starts)
    ok = (bytes(B) == payload and echo == payload and framing and exact == len(payload)
          and st.get("ledmis") == "0" and st.get("rx_fault") == "0" and st.get("tx_fault") == "0")
    first_bad = next((i for i, (a, b) in enumerate(zip(echo, payload)) if a != b), None)
    print(f"{tag:<16} err={err:+5.2f}% sent={len(payload):4} popped={len(B):4} echoed={len(echo):4} "
          f"exact={exact:4} overlap={overlap:4} rx-sample={min(offs):+6.1f}..{max(offs):+6.1f}cyc "
          f"{'PASS' if ok else 'FAIL'} {st}" + ("" if first_bad is None else f" first-bad={first_bad}"))
    return ok


def main():
    vvp = compile_tb()
    pay = uw.make_payload()
    allv = bytes(range(256))
    fails = 0
    fails += not run(vvp, "1KB+gaps", pay, uw.make_gaps(len(pay), CPB))
    fails += not run(vvp, "256-back2back", allv, [0] * 256)
    fails += not run(vvp, "jitter+-20ns", pay[:256], uw.make_gaps(len(pay), CPB, 2)[:256], jitter=20, seed=2)
    print("\nphone baud error, 64-byte back-to-back bursts:")
    burst = allv[::4]
    sweep = {e: run(vvp, f"err{e:+.1f}", burst, [0] * 64, err=e) for e in
             (-4.5, -3, -2, -1, -0.5, -0.25, 0.25, 0.5, 1, 2, 3, 4.5, 6)}
    fails += not all(sweep[e] for e in (-0.25, 0.25, 0.5, 1, 2, 3, 4.5))
    print("\nlong burst limit when the phone is faster than the FPGA (1024 bytes, no idle):")
    for e in (-0.25, -0.5, -1.0):   # -1.0 overflows by design (echo cannot keep up)
        run(vvp, f"long{e:+.2f}", pay, [0] * len(pay), err=e)
    print(f"\n{'ALL REQUIRED PASS' if not fails else str(fails) + ' REQUIRED FAILURE(S)'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
