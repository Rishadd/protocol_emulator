#!/usr/bin/env python3
"""Step 8: full-duplex UART through the SPI management link (tb/tb_mgmt_duplex.v).

Everything enters the chip over SPI: both engine programs (UART TX -> engine 0 / P0,
UART RX -> engine 1 / P1), the RUN bits, and a 1 KB payload. The bytes travel
SPI -> TX FIFO -> P0 line -> peer -> P1 line -> RX FIFO -> SPI MISO and are compared.

Roles (one function each; files land in build/mgmt_duplex/<case>/):
  make payload       -> sent.bin
  record TX line     -> tx_rec.bin    P0 waveform decoded by the independent reference receiver
  send it back       -> live:   echo peer inside the tb, echoes each byte as soon as it is received
                        replay: two passes; pass 1 records P0, Python writes echo_edges.txt from
                                tx_rec.bin (each byte sent back when its stop bit was received),
                                pass 2 drives P1 from that file
  record looped data -> echo_rec.bin  P1 waveform decoded (what the RX engine was given)
                        rx_spi.bin    bytes the host read back over MISO
  compare            -> sent == tx_rec == echo_rec == rx_spi, every TX frame cycle-exact,
                        no faults / management errors / timeouts
A negative case (host stops servicing while the peer keeps sending) must be *detected* as loss.
"""
import os
import random
import subprocess
import sys
import time

import uart_workload as uw

CYC_NS = 10                      # tb: 10 ns per system clock
CPB = 434                        # UART bit, clocks (115200 @ 50 MHz)
BUILD = os.path.join(uw.ROOT, "build", "mgmt_duplex")
PROG0 = os.path.join(uw.ROOT, "src", "fpga", "uart_tx_prog.hex")
PROG1 = os.path.join(uw.ROOT, "src", "fpga", "uart_rx_prog.hex")


def compile_tb():
    os.makedirs(BUILD, exist_ok=True)
    vvp = os.path.join(BUILD, "tb_mgmt_duplex.vvp")
    src = sorted(os.path.join(uw.ROOT, "src", f) for f in os.listdir(os.path.join(uw.ROOT, "src"))
                 if f.endswith(".v"))
    subprocess.run(["iverilog", "-g2012", "-I", os.path.join(uw.ROOT, "src"),
                    "-I", os.path.join(uw.ROOT, "tb"), "-o", vvp,
                    os.path.join(uw.ROOT, "tb", "tb_mgmt_duplex.v")] + src, check=True)
    return vvp


def run_sim(vvp, d, payload, half_ns=80, rxedges=None, peer_err=0.0, jitter=0,
            stall_at=-1, stall_cyc=0, seed=1, out="sim.txt"):
    pay_f, out_f = os.path.join(d, "payload.hex"), os.path.join(d, out)
    with open(pay_f, "w") as f:
        f.writelines(f"{b:02x}\n" for b in payload)
    args = ["vvp", "-n", vvp, f"+PROG0={PROG0}", f"+PROG1={PROG1}", f"+PAYLOAD={pay_f}",
            f"+N={len(payload)}", f"+OUT={out_f}", f"+SPIHALF_NS={half_ns}",
            f"+TMAX={len(payload) * 40 * CPB + 2_000_000}", f"+SEED={seed}",
            f"+PEERBIT_PS={round(CPB * CYC_NS * 1000 / (1 + peer_err / 100))}",
            f"+JITTER_NS={jitter}", f"+STALL_AT={stall_at}", f"+STALL_CYC={stall_cyc}"]
    if rxedges:
        args.append(f"+RXEDGES={rxedges}")
    t0 = time.time()
    subprocess.run(args, check=True, capture_output=True)
    return parse(out_f), time.time() - t0


def parse(path):
    log = dict(T=([], []), E=([], []), W=[], R=[], status={})
    for p in (line.split() for line in open(path)):
        if p[0] in ("T", "E"):
            log[p[0]][0].append(int(p[1]) // CYC_NS)
            log[p[0]][1].append(int(p[2]))
        elif p[0] in ("W", "R"):
            log[p[0]].append(int(p[2]))
        elif p[0] == "STATUS":
            log["status"] = dict(kv.split("=") for kv in p[1:])
    return log


def record_line(cycles_levels, bit):
    """Independent reference receiver (uart_workload.decode) on a logged line."""
    wf = uw.Waveform(*cycles_levels)
    start = wf.first_high()
    frames = uw.decode(wf, bit, start) if start is not None else []
    return wf, frames


def make_echo_edges(frames, path, bit_cyc, err=0.0, jitter_ns=0, seed=1):
    """Send each recorded byte back starting when its stop bit was received (mid stop bit),
    or right after the previous echo. Peer bit time includes its baud error."""
    rng = random.Random(seed)
    bit_ns = bit_cyc * CYC_NS / (1 + err / 100)
    t_free, level, edges = 0.0, 1, []
    for t0, b, _, _ in frames:
        t = max(t0 * CYC_NS + 9.5 * bit_cyc * CYC_NS, t_free)
        bits = [0] + [(b >> k) & 1 for k in range(8)] + [1]
        for k, v in enumerate(bits):
            if v != level:
                edges.append((round(t + k * bit_ns + (rng.uniform(-jitter_ns, jitter_ns) if k else 0)), v))
                level = v
        t_free = t + 10 * bit_ns
    with open(path, "w") as f:
        f.writelines(f"{t} {v}\n" for t, v in edges)


def compare(d, payload, log, tx_frames, tx_wf, echo_frames, peer_bit):
    tx_rec = bytes(f[1] for f in tx_frames)
    echo_rec = bytes(f[1] for f in echo_frames)
    rx_spi = bytes(log["R"])
    for name, data in (("sent.bin", payload), ("tx_rec.bin", tx_rec),
                       ("echo_rec.bin", echo_rec), ("rx_spi.bin", rx_spi)):
        with open(os.path.join(d, name), "wb") as f:
            f.write(data)
    exact, _ = uw.check_exact(tx_wf, tx_frames, payload, CPB)
    framing = all(f[2] and f[3] for f in tx_frames + echo_frames)
    st = log["status"]
    first_bad = next((i for i, (a, b) in enumerate(zip(rx_spi, payload)) if a != b),
                     None if len(rx_spi) == len(payload) else min(len(rx_spi), len(payload)))
    ok = (tx_rec == payload and echo_rec == payload and rx_spi == payload and
          exact == len(payload) and framing and bytes(log["W"]) == payload and
          st.get("fault0") == "0" and st.get("fault1") == "0" and st.get("err") == "0" and
          st.get("timeout") == "0")
    return ok, dict(tx=len(tx_rec), echo=len(echo_rec), rx=len(rx_spi), exact=exact,
                    framing=framing, first_bad=first_bad, st=st)


def report(tag, ok, r, wall, expect_ok=True):
    st = r["st"]
    verdict = ("PASS" if ok else "FAIL") if expect_ok else \
              ("PASS (loss detected)" if not ok else "FAIL (loss NOT detected)")
    print(f"{tag:<22} tx_rec={r['tx']:4} echo={r['echo']:4} rx_spi={r['rx']:4} exact={r['exact']:4} "
          f"retries={st.get('retries'):>5} polls={st.get('polls'):>5} frames={st.get('frames'):>5} "
          f"Mcyc={int(st.get('cycles', 0)) / 1e6:5.2f} wall={wall:5.1f}s  {verdict}"
          + ("" if r["first_bad"] is None else f"  first-bad={r['first_bad']}"))
    return ok if expect_ok else not ok


def live_case(vvp, tag, payload, expect_ok=True, peer_err=0.0, **kw):
    d = os.path.join(BUILD, tag)
    os.makedirs(d, exist_ok=True)
    log, wall = run_sim(vvp, d, payload, peer_err=peer_err, **kw)
    tx_wf, tx_frames = record_line(log["T"], uw.F_CLK / 115200)
    _, echo_frames = record_line(log["E"], CPB / (1 + peer_err / 100))
    ok, r = compare(d, payload, log, tx_frames, tx_wf, echo_frames, CPB)
    return report(tag, ok, r, wall, expect_ok)


def replay_case(vvp, tag, payload, err=0.0, jitter=0, expect_ok=True, pass2_kw=None, **kw):
    d = os.path.join(BUILD, tag)
    os.makedirs(d, exist_ok=True)
    idle = os.path.join(d, "idle_edges.txt")
    open(idle, "w").close()
    # pass 1: P1 idle, record what the chip transmits
    log1, w1 = run_sim(vvp, d, payload, rxedges=idle, out="pass1.txt", **kw)
    _, frames1 = record_line(log1["T"], uw.F_CLK / 115200)
    with open(os.path.join(d, "tx_rec_pass1.bin"), "wb") as f:
        f.write(bytes(fr[1] for fr in frames1))
    # send the recording back, byte by byte as it was received
    echo = os.path.join(d, "echo_edges.txt")
    make_echo_edges(frames1, echo, CPB, err, jitter)
    # pass 2: same host program, P1 driven from the file
    log2, w2 = run_sim(vvp, d, payload, rxedges=echo, out="pass2.txt", **dict(kw, **(pass2_kw or {})))
    tx_wf, tx_frames = record_line(log2["T"], uw.F_CLK / 115200)
    _, echo_frames = record_line(log2["E"], CPB / (1 + err / 100))
    ok, r = compare(d, payload, log2, tx_frames, tx_wf, echo_frames, CPB)
    ok = ok and bytes(fr[1] for fr in frames1) == payload
    return report(tag, ok, r, w1 + w2, expect_ok)


def main():
    vvp = compile_tb()
    pay = uw.make_payload()
    print(f"payload {len(pay)} bytes ({len(set(pay))} distinct values), UART 115200, "
          f"SPI half period in clocks noted per case\n")
    fails = 0
    print("live loopback (echo peer in the tb sends each byte back as soon as it is received):")
    fails += not live_case(vvp, "live_ideal_spi8", pay)
    fails += not live_case(vvp, "live_spi13.3", pay, half_ns=133)
    fails += not live_case(vvp, "live_peer+2%", pay, peer_err=+2.0)
    fails += not live_case(vvp, "live_peer-2%", pay, peer_err=-2.0)
    fails += not live_case(vvp, "live_jitter20ns", pay, jitter=20, seed=7)
    print("\nreplay (pass 1 records P0 to a file, pass 2 sends that file back on P1):")
    fails += not replay_case(vvp, "replay_ideal", pay)
    fails += not replay_case(vvp, "replay_-1.5%_jit15", pay, err=-1.5, jitter=15)
    print("\nnegative check (replay keeps sending at line rate while the host stops servicing SPI\n"
          "for 12 byte-times in pass 2: RX FIFO overflows, the compare must catch the loss):")
    fails += not replay_case(vvp, "neg_host_stall", pay[:256], expect_ok=False,
                             pass2_kw=dict(stall_at=100, stall_cyc=12 * 10 * CPB))
    print(f"\n{'ALL PASS' if not fails else str(fails) + ' FAILURE(S)'}")
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main())
