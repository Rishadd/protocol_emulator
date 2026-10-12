#!/usr/bin/env python3
"""Regression runner for the two-tier work (docs/TWO_TIER_MEMORY_PLAN.md §7.1).

  python host/regress.py --tier 0          unit testbenches + encoder checks (minutes)
  python host/regress.py --tier 1          + lockstep seeds + every protocol suite, compared with the baselines

Jobs run in stages; jobs inside a stage run in parallel (they never share a build directory).
Logs go to results/two_tier_<date>/tier<N>/<job>.log. A job passes when its output has a PASS RESULT
line and no FAIL, and, for jobs with a recorded baseline, when every output line equals the baseline
(timing lines excluded): the same cases, counts and measured limits. Baselines: results/two_tier_baseline/,
the outputs of the same suites on tag tt-phase0 (the design before the two-tier work).
"""
import argparse
import datetime
import os
import re
import subprocess
import sys
from concurrent.futures import ThreadPoolExecutor

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
PY = sys.executable
H = lambda f: os.path.join(ROOT, "host", f)
os.environ["PATH"] = os.pathsep.join([r"C:\tools\oss-cad-suite\bin", r"C:\tools\oss-cad-suite\lib", os.environ["PATH"],
                                      r"C:\iverilog\bin", r"C:\Users\risha\miniconda3\envs\eda\Library\bin"])  # sby, eqy (make)
FORMAL = ["fv_l2_arb", "fv_mgmt"]                     # formal/<name>.sby, proved in every tier
PHASE = 2                                                # mutants of phases 1..PHASE run in tier 1
RUN_TESTS = ["powershell", "-NoProfile", "-File", os.path.join(ROOT, "run_tests.ps1")]


def vvp(tb, seed):
    return [f"{tb} seed {seed}", ["vvp", "-n", os.path.join(ROOT, "build", tb + ".vvp"), f"+SEED={seed}"], None]


def sby(name):
    return [f"formal {name}", ["sby", "-f", "--prefix", os.path.join(ROOT, "build", "formal", name),
                               os.path.join(ROOT, "formal", name + ".sby")], None]


def stages(tier, seeds):
    s = [[["run_tests", RUN_TESTS, None], ["run_tests NO_L2", RUN_TESTS + ["-Define", "NO_L2"], None],
          ["test_isa", [PY, H("test_isa.py")], None]] + [sby(f) for f in FORMAL]]
    if tier >= 1:
        s.append([vvp(tb, k) for tb in ("tb_fetch_equiv", "tb_fetch_equiv_v2") for k in range(2, 2 + seeds)] + [
            ["spi_test", [PY, H("spi_test.py")], "results/two_tier_baseline/spi_test.txt"],
            ["i2c_test", [PY, H("i2c_test.py")], "results/two_tier_baseline/i2c_test.txt"],
            ["mgmt_duplex_stress", [PY, H("mgmt_duplex_stress.py")], "results/two_tier_baseline/mgmt_duplex_stress.txt"],
            ["eqy E2 (NO_L2 chip == tt-phase1 chip)", [PY, H("run_eqy.py"), "E2"], None]])
        s += [[["workload uart", [PY, H("workload.py"), "uart"], "results/two_tier_baseline/workload_uart.txt"]],
              [["workload uartlimits", [PY, H("workload.py"), "uartlimits"], "results/two_tier_baseline/workload_uartlimits.txt"]],
              [["workload spi i2c combo", [PY, H("workload.py"), "spi", "i2c", "combo"],
                "results/two_tier_baseline/workload_spi_i2c_combo.txt"]],
              [["mutants", [PY, H("mutate.py")] + [str(p) for p in range(1, PHASE + 1)], None]]]   # alone: rewrites src/
    return s


WALL = re.compile(r"wall=\s*[\d.]+s|\d+ min \d+ s|elapsed[^|]*")    # wall-clock fields, removed before comparing


def lines(text):
    return [WALL.sub("", l).rstrip() for l in text.splitlines() if l.strip() and not re.match(r"(real|user|sys)\s", l)]


def run(job, out_dir):
    name, cmd, base = job
    r = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
    text = r.stdout + r.stderr
    with open(os.path.join(out_dir, re.sub(r"\W+", "_", name) + ".log"), "w") as f:
        f.write(text)
    res = re.findall(r"RESULT .*|^ALL PASS$|DONE \((?:PASS|FAIL)[^)]*\)", text, re.M)
    ok = bool(res) and all("PASS" in x for x in res) and not any("FAIL" in x for x in res)
    why = "; ".join(res)[:150] or "no RESULT line"
    if ok and base:
        got, exp = lines(text), lines(open(os.path.join(ROOT, base)).read())
        diff = [(i, a, b) for i, (a, b) in enumerate(zip(got, exp)) if a != b]
        if diff or len(got) != len(exp):
            ok = False
            i, a, b = diff[0] if diff else (min(len(got), len(exp)), "<end>", "<end>")
            why = f"differs from baseline {base} at line {i + 1}:\n      got: {a}\n      exp: {b}"
        else:
            why += f" | identical to baseline ({len(exp)} lines)"
    return name, ok, why


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--tier", type=int, default=0)
    ap.add_argument("--jobs", type=int, default=6)
    ap.add_argument("--seeds", type=int, default=20)
    a = ap.parse_args()
    out = os.path.join(ROOT, "results", f"two_tier_{datetime.date.today()}", f"tier{a.tier}")
    os.makedirs(out, exist_ok=True)
    bad = 0
    for st in stages(a.tier, a.seeds):
        with ThreadPoolExecutor(a.jobs) as ex:
            for name, ok, why in ex.map(lambda j: run(j, out), st):
                bad += not ok
                print(f"{'PASS' if ok else 'FAIL'}  {name:28s} {why}", flush=True)
    print(f"RESULT regress tier {a.tier}: {'PASS' if not bad else f'FAIL ({bad} jobs)'}  (logs: {out})")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
