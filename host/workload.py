#!/usr/bin/env python3
"""Workload campaign: every protocol driven ONLY through the host management SPI link.

The host model (inside each chip testbench) claims pads (0x0200), loads programs, sets RUN, writes TX
words (base+0x200, accepted only when STATUS shows room) and reads RX words (base+0x204, valid only
when STATUS shows data). How the host behaves is varied with tb/host_knobs.vh:
  interleaved   default: read when the last STATUS showed data, else write
  burst         write until TX full, then read until RX empty
  aborts        a truncated frame (1-6 bytes, to TX_DATA or RX_DATA) before every 5th frame
  noise         a CTRL or VIOL register read before every 3rd frame
  slow host     5 us idle before every frame
  all           all of the above at once
Sections (run all, or name some):  python host/workload.py [uart uartlimits spi i2c combo]
  uart   TX only, RX only, full duplex (live echo peer), corner cases, baud and link-speed limits (closed loop)
  uartlimits  RX open-loop limits: link speed and baud rate the host can drain at line rate
  spi    master and slave (all 4 modes), every host behaviour, slave throughput limit
  i2c    master at 100/400/1000 kHz, every host behaviour, NACK/stretch under host load
  combo  SPI master (engine 0) and I2C master (engine 1) at the same time, one shared host link
Every case is checked by the protocol's independent decoder (UART reference receiver, SPI/I2C bus
decoders) and compared byte for byte with what the host sent / the peers sent.
"""
import argparse
import os
import random
import subprocess
import sys

import i2c_prog as ip
import i2c_test as it
import mgmt_duplex_stress as ud
import spi_prog as sp
import spi_test as st
import uart_workload as uw

ROOT = uw.ROOT
RESULTS, LIMITS = [], []
KNOBS = {"interleaved": {}, "burst": {"BURST": 1}, "aborts/5": {"ABORT_EVERY": 5}, "noise/3": {"NOISE_EVERY": 3},
         "slow host 5us": {"HOSTGAP_NS": 5000},
         "all": {"BURST": 1, "ABORT_EVERY": 5, "NOISE_EVERY": 3, "HOSTGAP_NS": 5000}}


def record(section, name, ok, info, expect="pass"):
    good = ok if expect == "pass" else (not ok if expect == "fail" else True)
    tag = {"pass": "PASS" if ok else "FAIL", "fail": "DETECTED" if not ok else "MISSED",
           "info": "ok" if ok else "fails"}[expect]
    if expect != "info":
        RESULTS.append((section, name, good))
    print(f"  {tag:8s} {name:52s} {info}")
    return ok


# ------------------------------------------------------------------ UART
UART_BASE = dict(BUILD=ud.BUILD, PROG0=ud.PROG0, PROG1=ud.PROG1)


def uart_baud(baud):
    for k, v in UART_BASE.items():
        setattr(ud, k, v)
    ud.CPB, ud.BAUD = 434, 115200
    ud.set_baud(baud)
    return ud.compile_tb()


def uart_info(r, st_):
    return (f"tx={r['tx']} echo={r['echo']} rx={r['rx']} exact={r['exact']} retries={st_.get('retries')} "
            f"frames={st_.get('frames')} aborts={st_.get('aborts')} noise={st_.get('noises')}")


def uart_duplex(vvp, name, pay, extra=None, half_ns=80, peer_err=0.0, expect="pass", **kw):
    d = os.path.join(ud.BUILD, "wl_" + "".join(c if c.isalnum() or c in "+-." else "_" for c in name))
    os.makedirs(d, exist_ok=True)
    log, _ = ud.run_sim(vvp, d, pay, half_ns=half_ns, peer_err=peer_err, extra=extra, **kw)
    tx_wf, tx_frames = ud.record_line(log["T"], ud.CPB)
    _, echo_frames = ud.record_line(log["E"], ud.CPB / (1 + peer_err / 100))
    ok, r = ud.compare(d, pay, log, tx_frames, tx_wf, echo_frames, ud.CPB,
                       allow_err=bool((extra or {}).get("ABORT_EVERY")))
    return record("uart", name, ok, uart_info(r, log["status"]), expect)


def uart_tx_only(vvp, name, pay, extra=None, half_ns=80):
    d = os.path.join(ud.BUILD, "wl_" + "".join(c if c.isalnum() or c in "+-." else "_" for c in name))
    os.makedirs(d, exist_ok=True)
    idle = os.path.join(d, "idle.txt")
    open(idle, "w").close()
    log, _ = ud.run_sim(vvp, d, pay, half_ns=half_ns, rxedges=idle, extra=extra)
    tx_wf, frames = ud.record_line(log["T"], ud.CPB)
    exact, _ = uw.check_exact(tx_wf, frames, pay, ud.CPB)
    s = log["status"]
    ok = (bytes(f[1] for f in frames) == bytes(pay) and exact == len(pay) and bytes(log["W"]) == bytes(pay)
          and all(f[2] and f[3] for f in frames) and s.get("fault0") == "0"
          and (s.get("err") == "0" or (extra or {}).get("ABORT_EVERY")))
    return record("uart", name, ok, f"tx={len(frames)} exact={exact} retries={s.get('retries')} "
                  f"frames={s.get('frames')} aborts={s.get('aborts')}")


def rx_edges(items, bit_ns, t0_bits=20):
    """items: ('b', byte) | ('idle', bits) | ('break', bits) | ('glitch', ns). Returns [(ns, level)], times
    relative to the end of program loading (+RXREL=1). The stream starts t0_bits bit times after loading
    (the host's no-progress timeout is 200 bit times)."""
    t, ev = t0_bits * bit_ns, []
    for kind, v in items:
        if kind == "b":
            for k, lvl in enumerate([0] + [(v >> i) & 1 for i in range(8)] + [1]):
                ev.append((round(t + k * bit_ns), lvl))
            t += 10 * bit_ns
        elif kind == "idle":
            t += v * bit_ns
        elif kind == "break":
            ev += [(round(t), 0), (round(t + v * bit_ns), 1)]
            t += (v + 1) * bit_ns
        elif kind == "glitch":
            ev += [(round(t), 0), (round(t + v), 1)]
            t += 12 * bit_ns
    return ev


def uart_rx_only(vvp, name, items, want, extra=None, half_ns=80, expect="pass"):
    d = os.path.join(ud.BUILD, "wl_" + "".join(c if c.isalnum() or c in "+-." else "_" for c in name))
    os.makedirs(d, exist_ok=True)
    edges = os.path.join(d, "rx_edges.txt")
    with open(edges, "w") as f:
        f.writelines(f"{t} {v}\n" for t, v in rx_edges(items, ud.CPB * ud.CYC_NS))
    n = len(want) + 8                                   # room for unexpected extra bytes
    log, _ = ud.run_sim(vvp, d, list(want) + [0] * 8, half_ns=half_ns, rxedges=edges,
                        extra=dict(extra or {}, RXONLY=1, RXREL=1))
    got = bytes(log["R"])
    s = log["status"]
    ok = got == bytes(want) and s.get("fault1") == "0"
    first = next((i for i, (a, b) in enumerate(zip(got, want)) if a != b), None)
    return record("uart", name, ok, f"rx={len(got)}/{len(want)} first_diff={first} polls={s.get('polls')} "
                  f"frames={s.get('frames')}" + ("" if ok else f" got_tail={got[-4:].hex()}"), expect)


def section_uart():
    print("UART (TX = engine 0 / P0, RX = engine 1 / P1, 115200 at the 434-clock bit used by the UART suite)")
    vvp = uart_baud(115200)
    pay = bytes(uw.make_payload()[:256])
    print(" full duplex (live echo peer), every host behaviour")
    for k, v in KNOBS.items():
        uart_duplex(vvp, f"duplex 256 B, host {k}", pay, extra=v)
    print(" TX only / RX only")
    uart_tx_only(vvp, "TX only 256 B, interleaved", pay)
    uart_tx_only(vvp, "TX only 256 B, host all", pay, extra=KNOBS["all"])
    uart_tx_only(vvp, "TX only 64 B, host 100 us per frame (line idles)", pay[:64], extra={"HOSTGAP_NS": 100000})
    uart_rx_only(vvp, "RX only 256 B back-to-back", [("b", b) for b in pay], list(pay))
    uart_rx_only(vvp, "RX only 256 B, host all", [("b", b) for b in pay], list(pay), extra=KNOBS["all"])
    print(" RX corner cases (no framing / start-bit validation in the 9-word RX program)")
    a, b = list(pay[:8]), list(pay[8:16])
    uart_rx_only(vvp, "RX break (30 bit times low) between bytes", [("b", x) for x in a] + [("break", 30)] +
                 [("b", x) for x in b], a + [0x00] + b, expect="info")
    uart_rx_only(vvp, "RX 1 us glitch on an idle line", [("b", x) for x in a] + [("glitch", 1000)] +
                 [("b", x) for x in b], a + b, expect="info")
    uart_rx_only(vvp, "RX bytes with 0..3 idle bits between", [i for x in pay[:64] for i in
                 (("b", x), ("idle", x % 4))], list(pay[:64]))
    print(" peer baud error (full duplex, 128 B)")
    for err in (-4.0, -5.0, -6.0, +4.0, +6.0, +8.0):
        uart_duplex(vvp, f"duplex peer {err:+.0f}%", pay[:128], peer_err=err, expect="info")
    print(" management link speed sweep (full duplex 115200, 128 B): half period in clocks")
    last = None
    for half in (80, 120, 160, 200, 240, 320):
        if not uart_duplex(vvp, f"duplex mgmt half {half // 10} clk", pay[:128], half_ns=half, expect="info"):
            LIMITS.append(("UART duplex 115200: slowest mgmt half period", last, f"{half // 10} clk"))
            break
        last = f"{half // 10} clk"
    print(" negative: host stops servicing for 12 byte-times while the peer keeps sending")
    uart_duplex(vvp, "duplex host stall (RX overflow must be detected)", pay, stall_at=100,
                stall_cyc=12 * 10 * ud.CPB, expect="fail")
    print(" baud sweep, full duplex, fastest management link (8 clocks per half period)")
    last = None
    for baud in (230400, 460800, 921600, 1500000):
        v = uart_baud(baud)
        if not uart_duplex(v, f"duplex {baud} baud (bit {ud.CPB} clk)", pay[:96], expect="info"):
            LIMITS.append(("UART full duplex through the link: max baud (bit clocks)", last, f"{baud} ({ud.CPB} clk)"))
            break
        last = f"{baud} ({ud.CPB} clk)"
    uart_baud(115200)


def section_uartlimits():
    """Open-loop limits: the peer streams into RX at line rate whatever the host does (the full-duplex echo is
    closed-loop - the peer only answers what TX sent - so a slow link only slows it down without loss)."""
    print("UART RX open-loop limits (peer streams back-to-back bytes; the host only reads)")
    vvp = uart_baud(115200)
    pay = list(uw.make_payload()[:128])
    items = [("b", b) for b in pay]
    last = None
    for half in (80, 160, 240, 320, 400, 480, 560):
        if not uart_rx_only(vvp, f"RX only 128 B, mgmt half {half // 10} clk", items, pay, half_ns=half, expect="info"):
            LIMITS.append(("UART RX 115200 (434-clk bit) open loop: slowest mgmt half period", last, f"{half // 10} clk"))
            break
        last = f"{half // 10} clk"
    last = None
    for baud in (230400, 460800, 921600, 1500000):
        v = uart_baud(baud)
        if not uart_rx_only(v, f"RX only 96 B at {baud} (bit {ud.CPB} clk), fastest link", items[:96], pay[:96],
                            expect="info"):
            LIMITS.append(("UART RX open loop, fastest link: max baud (bit clocks)", last, f"{baud} ({ud.CPB} clk)"))
            break
        last = f"{baud} ({ud.CPB} clk)"
    uart_baud(115200)


# ------------------------------------------------------------------ SPI
def spi_case(name, role, mode, extra=None, expect="pass", **kw):
    ok = st.engine_case(name, role, mode, tb="tb_spi_chip", expect="info", **{k.lower(): v for k, v in (extra or {}).items()},
                        **kw)
    e = st.LAST_END
    return record("spi", name, ok, f"frames={e.get('frames')} retries={e.get('retries')} aborts={e.get('aborts')} "
                  f"noise={e.get('noises')} {int(e.get('cyc', 0)) / 100:.0f} us", expect)


def section_spi():
    print("SPI (master = engine 0, slave = engine 1; slave CS frames 40 us apart unless noted)")
    for k, v in KNOBS.items():
        g = 100 if "HOSTGAP_NS" in v else 40           # a slowed host needs wider slave frame spacing
        spi_case(f"master mode0 8b, host {k}", 0, 0, eng=0, extra=v)
        spi_case(f"slave mode3 8b, host {k}, CS every {g} us", 1, 3, eng=1, gap_ns=g * 1000, extra=v)
    print(" all modes and frame formats with the host doing everything at once")
    for mode in range(4):
        spi_case(f"master mode{mode} 32b LSB, host all", 0, mode, bits=32, lsb=1, eng=0, extra=KNOBS["all"])
        spi_case(f"slave mode{mode} 16b MSB, host all, CS every 100 us", 1, mode, bits=16, eng=1, gap_ns=100000,
                 extra=KNOBS["all"])
    r = random.Random(9)
    spi_case("master mode2 512 random bytes, H=1, host all", 0, 2, h=1, eng=0, extra=KNOBS["all"],
             vals=[r.getrandbits(8) for _ in range(512)])
    print(" slave sustained-rate limit vs host behaviour (CS frame spacing in us, 40 frames)")
    for k in ("interleaved", "burst", "all"):
        last = None
        for g in (100, 80, 60, 50, 40, 30, 25, 20, 15):
            if not spi_case(f"slave mode0 gap {g} us, host {k}", 1, 0, eng=1, gap_ns=g * 1000, n=40,
                            extra=KNOBS[k], expect="info"):
                LIMITS.append((f"SPI slave min CS spacing, host {k}", f"{last} us", f"{g} us"))
                break
            last = g
    print(" negative: slave frames faster than the host can serve")
    spi_case("slave mode0 gap 10 us (loss must be detected)", 1, 0, eng=1, gap_ns=10000, n=40, expect="fail")


# ------------------------------------------------------------------ I2C
def i2c_case(name, txs, khz=400, extra=None, expect="pass", **kw):
    ok = it.case(name, txs, khz, tb="tb_i2c_chip", expect="info", **{k.lower(): v for k, v in (extra or {}).items()},
                 **kw)
    e = it.LAST.get("END", {})
    return record("i2c", name, ok, f"frames={e.get('frames')} retries={e.get('retries')} aborts={e.get('aborts')} "
                  f"noise={e.get('noises')} {int(e.get('cyc', 0)) / 50:.0f} us", expect)


def section_i2c():
    print("I2C master (engine 0 unless noted), 400 kHz unless noted")
    r = random.Random(4)
    for k, v in KNOBS.items():
        i2c_case(f"basic set, host {k}", it.basic_set(r, 1), extra=v, eng=0)
    print(" protocol corner cases under host load (host all)")
    W = ip.transaction
    i2c_case("1000 kHz eng1, data NACK mid-write, queued words dropped", [W(0x50, [0x01, 0x11, 0x22, 0x33, 0x44]),
             W(0x50, [0x01], stop=False) + W(0x50, rd=4)], 1000, extra=KNOBS["all"], eng=1, s1=dict(nack_at=2))
    i2c_case("absent address between valid ones", [W(0x50, [0x10, 1]), W(0x51, [9, 9, 9]), W(0x50, [0x10], stop=False)
             + W(0x50, rd=1)], extra=KNOBS["all"], eng=0)
    i2c_case("100 kHz, slave stretches every bit 3 us", it.basic_set(r, 1), 100, extra=KNOBS["all"], eng=0,
             s_stretch_mode=2, s_stretch_ns=3000)
    i2c_case("two slaves, repeated START chains", [W(0x23, [0x05], stop=False) + W(0x50, [0x05, 7], stop=False) +
             W(0x23, rd=2)], extra=KNOBS["all"], eng=1, s2=True)
    txs = []
    while sum(len(t) for t in txs) < 400:
        p = r.randrange(256)
        txs.append(W(0x50, [p] + [r.randrange(256) for _ in range(r.randrange(1, 10))]) if r.random() < 0.5
                   else W(0x50, [p], stop=False) + W(0x50, rd=r.randrange(1, 10)))
    i2c_case(f"1000 kHz random stress ({sum(len(t) for t in txs)} words), host all", txs, 1000, extra=KNOBS["all"], eng=1)
    print(" throughput: bytes per second through the link (1000 kHz bus, interleaved host, fastest link)")
    i2c_case("1000 kHz throughput, mgmt half 8 clk", txs[:20], 1000, eng=0, mgmt_half_ns=160)


# ------------------------------------------------------------------ SPI + I2C at the same time
def combo_case(name, spi_mode=0, spi_bits=8, spi_lsb=0, h=4, khz=400, extra=None, seed=1, n_spi=None, txs=None,
               stretch=None, expect="pass"):
    rng = random.Random(seed)
    hv = st.patterns(spi_bits, rng)[:n_spi] if n_spi else st.patterns(spi_bits, rng)
    sv = st.patterns(spi_bits, rng)[:len(hv)]
    rng.shuffle(sv)
    txs = txs or it.basic_set(rng, 1)
    i2c_words = [w for t in txs for w in t]
    d = os.path.join(ROOT, "build", "workload", "".join(c if c.isalnum() or c in "-+=." else "_" for c in name))
    os.makedirs(d, exist_ok=True)
    files = {"PROG0": sp.master(spi_mode, spi_bits, spi_lsb, h), "PROG1": ip.master(khz),
             "HTX0": [sp.tx_word(v, spi_bits, spi_lsb) for v in hv], "HTX1": i2c_words, "STX": sv}
    args = [f"+N0={len(hv)}", f"+N1={len(i2c_words)}", f"+MODE={spi_mode}", f"+BITS={spi_bits}", f"+LSB={spi_lsb}",
            f"+OUT={os.path.join(d, 'log.txt')}", "+TMAX=60000000"]
    for k, w in files.items():
        fn = os.path.join(d, k.lower() + ".hex")
        sp.write_hex(w, fn)
        args.append(f"+{k}={fn}")
    args += [f"+{k}={v}" for k, v in dict(extra or {}, **(stretch or {})).items()]
    vvp = it.compile_tb("tb_combo_chip", 1)
    rr = subprocess.run(["vvp", "-n", vvp, *args], capture_output=True, text=True)
    if rr.returncode or "ERROR" in rr.stdout:
        raise RuntimeError(rr.stdout + rr.stderr)
    P, Q, R0, R1, MEM, END = [], [], [], [], {}, {}
    for line in open(os.path.join(d, "log.txt")):
        p = line.split()
        if p[0] in ("P", "Q"):
            lst = P if p[0] == "P" else Q
            t = int(p[1])
            if lst and lst[-1][0] == t:
                lst[-1] = (t, p[2])
            elif not lst or lst[-1][1] != p[2]:
                lst.append((t, p[2]))
        elif p[0] in ("R0", "R1"):
            (R0 if p[0] == "R0" else R1).append(int(p[2], 16))
        elif p[0] == "MEM":
            MEM[int(p[1])] = [int(p[2][i:i + 2], 16) for i in range(0, 512, 2)]
        elif p[0] == "END":
            END = dict(x.split("=") for x in p[1:])
    old = st.CLK
    st.CLK = 20                                         # the combo tb runs at 50 MHz
    try:
        errs, sst = st.check(dict(P=P, S=[], R=R0, END={}), 0, spi_mode, spi_bits, spi_lsb, hv, hv, sv, h=h)
    finally:
        st.CLK = old
    slaves = [it.Slave(0x50), it.Slave(0x23, en=False)]
    allow = END.get("aborts", "0") != "0"
    ierrs, ist = it.check(dict(P=Q, R=R1, MEM=MEM, END={k: END[k] for k in ("drive_high", "viol", "timeout")}
                               | {"fault": END["fault1"], "err": "0" if allow else END["err"]}), i2c_words, slaves, khz)
    errs = [f"SPI: {e}" for e in errs] + [f"I2C: {e}" for e in ierrs]
    if END.get("fault0") != "0":
        errs.append("engine 0 fault")
    for e in errs[:4]:
        print(f"           {e}")
    return record("combo", name, not errs, f"SPI {len(hv)} frames + I2C {len(i2c_words)} bytes, "
                  f"frames={END.get('frames')} retries={END.get('retries')} aborts={END.get('aborts')} "
                  f"{int(END.get('cyc', 0)) / 50:.0f} us", expect)


def section_combo():
    print("SPI master (engine 0, pads 2-5) + I2C master (engine 1, pads 6-7) at the same time")
    for k, v in KNOBS.items():
        combo_case(f"SPI mode0 + I2C 400 kHz, host {k}", extra=v)
    combo_case("SPI mode3 32b LSB H=1 + I2C 1000 kHz, host all", 3, 32, 1, h=1, khz=1000, extra=KNOBS["all"])
    combo_case("SPI mode1 + I2C 100 kHz slave stretching every byte, host all", 1, khz=100, extra=KNOBS["all"],
               stretch={"S_STRETCH_MODE": 1, "S_STRETCH_NS": 20000})


SECTIONS = dict(uart=section_uart, uartlimits=section_uartlimits, spi=section_spi, i2c=section_i2c,
                combo=section_combo)

if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("sections", nargs="*", default=list(SECTIONS))
    a = ap.parse_args()
    for s in a.sections:
        SECTIONS[s]()
    print()
    for label, last, fail in LIMITS:
        print(f"LIMIT {label}: last pass {last}, first fail {fail}")
    bad = [f"{s}: {n}" for s, n, ok in RESULTS if not ok]
    for b in bad:
        print(f"NOT AS EXPECTED: {b}")
    print(f"RESULT workload: {'PASS' if not bad else 'FAIL'} ({len(RESULTS) - len(bad)}/{len(RESULTS)} cases as expected)")
    sys.exit(1 if bad else 0)
