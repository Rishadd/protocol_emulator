#!/usr/bin/env python3
"""Runs every verification suite of the project and writes a summary table + one log per suite.
  python host/regress.py [--out results/regression_<date>] [--jobs 4] [--only name,name] [--skip name,name]
Phases (suites inside a phase run in parallel; phases run one after the other because suites of different phases reuse build directories):
  A  RTL unit testbenches (run_tests.ps1) and every Python suite on the engine / chip testbenches
  B  the protocol suites again on the FULL chip (PROTO_CHIP=1: host only through the management SPI link)
  C  suites with every firmware image relocated to the top of the memory (FW_ORG=192; the larger firmwares from word 64)
A suite passes when its process exits with 0 and prints no line containing FAIL / MISSED / COMPILE FAIL, and its last RESULT line
(or, for the workload sweeps that have none, the last line matching `final`) says PASS. Sweeps that print FAIL rows on purpose
(rows outside a tolerance limit) set ignore_bad.
"""
import argparse
import concurrent.futures as cf
import datetime
import os
import re
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
PY = sys.executable

A = [
    ("unit_testbenches", ["powershell", "-NoProfile", "-File", "run_tests.ps1"] if os.name == "nt" else ["bash", "run_tests.sh"], {}),
    ("crc_test", [PY, "host/crc_test.py"], {}),
    ("alu_test", [PY, "host/alu_test.py"], {}),
    ("isa_diff_test", [PY, "host/isa_diff_test.py"], {}),
    ("spi_test", [PY, "host/spi_test.py"], {}),
    ("i2c_test", [PY, "host/i2c_test.py"], {}),
    ("i2c_slave_test", [PY, "host/i2c_slave_test.py"], {}),
    ("smbus_test", [PY, "host/smbus_test.py"], {}),
    ("modbus_test", [PY, "host/modbus_test.py", "tx", "rx", "loop", "mutants"], {}),
    ("onewire_test", [PY, "host/onewire_test.py"], {}),
    ("jtag_test", [PY, "host/jtag_test.py"], {}),
    ("can_test", [PY, "host/can_test.py"], {}),
    ("uart_workload", [PY, "host/uart_workload.py", "--bauds", "9600", "115200"], {}, dict(final=r"fully PASS", ignore_bad=True)),
    ("uart_rx_workload", [PY, "host/uart_rx_workload.py"], {}, dict(final=r"ALL PASS", ignore_bad=True)),
    ("mgmt_duplex_stress", [PY, "host/mgmt_duplex_stress.py"], {}, dict(final=r"PASS", ignore_bad=True)),
    ("chip_host_demo", [PY, "host/chip_host_demo.py", "--quiet"], {}, dict(final=r"all checks passed")),
    ("ws2812_test", [PY, "host/ws2812_test.py"], {}),
    ("ps2_test", [PY, "host/ps2_test.py", "run", "mutants", "rtl"], {}),
    ("swd_test", [PY, "host/swd_test.py"], {}),
    ("line_coder_test", [PY, "host/line_coder_test.py"], {}),
    # every caught mutant prints the testbench's FAIL line, so the verdict is the X/X summary only
    ("line_coder_mutants", [PY, "host/line_coder_test.py", "mutants"], {}, dict(final=r"mutants caught: (\d+)/\1\b", ignore_bad=True)),
    ("usb_test_model", [PY, "host/usb_test.py", "rate"], {}),
    ("usb_test_rtl", [PY, "host/usb_test.py", "rtl", "rate"], {}),
    ("usb_mutants", [PY, "host/usb_mutants.py"], {}, dict(final=r"mutants caught: (\d+)/\1\b")),
    ("workload", [PY, "host/workload.py"], {}, dict(final=r"PASS", ignore_bad=True)),
]
B = [
    ("chip_can_test", [PY, "host/can_test.py", "run"], {"PROTO_CHIP": "1"}),
    ("chip_jtag_test", [PY, "host/jtag_test.py", "run"], {"PROTO_CHIP": "1"}),
    ("chip_onewire_test", [PY, "host/onewire_test.py", "run"], {"PROTO_CHIP": "1"}),
    ("chip_modbus_test", [PY, "host/modbus_test.py", "tx", "rx", "loop"], {"PROTO_CHIP": "1"}),
]
C = [
    ("org192_spi_test", [PY, "host/spi_test.py"], {"FW_ORG": "192"}),
    ("org192_i2c_test", [PY, "host/i2c_test.py"], {"FW_ORG": "192"}),
    # CAN (112/186 words), JTAG (87) and 1-Wire (79) do not fit at word 192: they run from word 64 (CAN RX then ends at word 250)
    ("org64_can_test", [PY, "host/can_test.py", "run"], {"FW_ORG": "64"}),
    ("org64_jtag_test", [PY, "host/jtag_test.py", "run"], {"FW_ORG": "64"}),
    ("org192_modbus_test", [PY, "host/modbus_test.py", "tx", "rx", "loop"], {"FW_ORG": "192"}),
    ("org64_onewire_test", [PY, "host/onewire_test.py", "run"], {"FW_ORG": "64"}),
]
# D: the chip-level protocol suites again with the pins of every logical pin placed at random (output remap on uio and uo_out, input
# select including ui_in): the same firmware must still behave identically (decoders see the logical pin bus).
# PROTO_REMAP_UO = logical pins that are output-only push-pull and may sit on uo_out (JTAG TCK/TMS/TDI).
D = [(f"remap{s}_{n}", [PY, "host/" + script, *args], {"PROTO_CHIP": "1", "PROTO_REMAP": str(s), **extra})
     for s in (1, 2, 3)
     for n, script, args, extra in (("can_test", "can_test.py", ["run"], {}),
                                    ("jtag_test", "jtag_test.py", ["run"], {"PROTO_REMAP_UO": "0x38"}),
                                    ("onewire_test", "onewire_test.py", ["run"], {}),
                                    ("modbus_test", "modbus_test.py", ["tx", "rx", "loop"], {}))]
# E: the shared 512-word instruction memory (PROTO_SHARED=1, -DSHARED_IMEM): the chip-level protocol suites with engine 0's image at word 0 and engine 1's at word 256
# (absolute 9-bit jump targets, START register), plain and with the pins of seed 2 placed at random
E = [(n.replace("chip_", "shared_"), cmd, {**env, "PROTO_SHARED": "1"}) for n, cmd, env in B] + \
    [(n.replace("remap2_", "sharedremap2_"), cmd, {**env, "PROTO_SHARED": "1"}) for n, cmd, env in D if n.startswith("remap2_")] + \
    [("shared_spi_chip", [PY, "host/spi_test.py", "chip"], {"PROTO_SHARED": "1"}),      # SPI master on engine 0, slave on engine 1 (word 256)
     ("shared_i2c_chip", [PY, "host/i2c_test.py", "chip"], {"PROTO_SHARED": "1"})]
# F: management frame v2, the shared-memory software (host rules, models, differential test, chip level) and the logic analyser (model, capture unit
# against the model, chip level through the SPI link); every *_mutants run must catch all its planted bugs
F = [
    ("mgmt_v2_test", [PY, "host/mgmt_v2_test.py"], {}),
    ("mgmt_v2_mutants", [PY, "host/mgmt_v2_mutants.py"], {}),
    ("shmem_test", [PY, "host/shmem_test.py"], {}),
    ("shmem_chip_test", [PY, "host/shmem_chip_test.py"], {}),
    ("isa_diff_shared", [PY, "host/isa_diff_shared.py", "run"], {}),
    ("isa_diff_shared_mutants", [PY, "host/isa_diff_shared.py", "mutants"], {}),
    ("la_model", [PY, "host/la_model.py"], {}),
    ("la_rtl_test", [PY, "host/la_rtl_test.py", "run"], {}),
    ("la_rtl_mutants", [PY, "host/la_rtl_test.py", "mutants"], {}),
    ("la_chip_test", [PY, "host/la_chip_test.py"], {}),
]
BAD = re.compile(r"\bFAIL\b|MISSED|COMPILE FAIL|Traceback")


def run_one(item, outdir):
    name, cmd, env = item[:3]
    opt = item[3] if len(item) > 3 else {}
    t0 = time.time()
    e = dict(os.environ, **env)
    e.setdefault("PYTHONUNBUFFERED", "1")
    p = subprocess.run(cmd, cwd=ROOT, env=e, capture_output=True, text=True, errors="replace")
    text = p.stdout + ("\n--- stderr ---\n" + p.stderr if p.stderr.strip() else "")
    with open(os.path.join(outdir, name + ".log"), "w", encoding="utf-8") as f:
        f.write(text)
    lines = [ln for ln in p.stdout.splitlines() if ln.strip()]
    results = [ln.strip() for ln in lines if ln.lstrip().startswith("RESULT")]
    bad = [] if opt.get("ignore_bad") else [ln for ln in lines if BAD.search(ln)]
    if "final" in opt:
        fin = [ln for ln in lines if re.search(opt["final"], ln)]
        results = results or fin[-1:]
    ok = p.returncode == 0 and not bad and bool(results or name == "unit_testbenches")
    last = results[-1] if results else (lines[-1].strip() if lines else "(no output)")
    if name == "unit_testbenches":
        n = len(results)
        last = f"{n} testbenches reported; " + ("none failed" if not bad else f"{len(bad)} FAIL lines")
    return name, ok, time.time() - t0, last, p.returncode


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join("results", "regression_" + datetime.date.today().isoformat()))
    ap.add_argument("--jobs", type=int, default=4)
    ap.add_argument("--only", default="")
    ap.add_argument("--skip", default="")
    a = ap.parse_args()
    outdir = os.path.join(ROOT, a.out)
    os.makedirs(outdir, exist_ok=True)
    only = {x for x in a.only.split(",") if x}
    skip = {x for x in a.skip.split(",") if x}
    sys.path.insert(0, HERE)
    import proto_lib as pl
    for chip in (False, True):                                   # compile the shared protocol benches once, before anything runs in parallel
        pl.compile_tb(chip=chip)
    rows = []
    for label, phase in (("A", A), ("B", B), ("C", C), ("D", D), ("E", E), ("F", F)):
        items = [i for i in phase if (not only or i[0] in only) and i[0] not in skip]
        if not items:
            continue
        print(f"--- phase {label}: {len(items)} suites", flush=True)
        with cf.ThreadPoolExecutor(max_workers=a.jobs) as ex:
            futs = [ex.submit(run_one, i, outdir) for i in items]
            for f in cf.as_completed(futs):
                name, ok, dt, last, rc = f.result()
                rows.append((label, name, ok, dt, last, rc))
                print(f"  {'PASS' if ok else 'FAIL':4s} {name:22s} {dt / 60:6.1f} min  {last}", flush=True)
    bad = [r for r in rows if not r[2]]
    with open(os.path.join(outdir, "summary.md"), "w", encoding="utf-8") as f:
        f.write(f"# Regression {datetime.date.today().isoformat()}\n\n")
        f.write("| phase | suite | result | minutes | last result line |\n|---|---|---|---|---|\n")
        for label, name, ok, dt, last, rc in sorted(rows):
            f.write(f"| {label} | {name} | {'PASS' if ok else '**FAIL**'} | {dt / 60:.1f} | {last} |\n")
        f.write(f"\n{len(rows) - len(bad)} of {len(rows)} suites passed.\n")
    print(f"REGRESSION {'PASS' if not bad else 'FAIL'}: {len(rows) - len(bad)} of {len(rows)} suites; summary in {a.out}/summary.md")
    return 1 if bad else 0


if __name__ == "__main__":
    sys.exit(main())
