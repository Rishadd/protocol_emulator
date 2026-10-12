#!/usr/bin/env python3
"""Mutation testing for the two-tier work (docs/TWO_TIER_MEMORY_PLAN.md I8).

  python host/mutate.py <phase> [...]      e.g. python host/mutate.py 1 2

Each mutant replaces one exact piece of text in one file (it must occur exactly once), runs the named
testbenches (compiled like run_tests.ps1, in build/mut/), restores the file and expects at least one
testbench to report FAIL. A mutant that does not compile counts as NOT DETECTED (it proves nothing).
Do not run next to another job that compiles src/ (the file is changed while the mutant runs).
"""
import glob
import os
import re
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
BUILD = os.path.join(ROOT, "build", "mut")
os.environ["PATH"] += os.pathsep + r"C:\iverilog\bin"
EXTRAS = {"tb_fetch_equiv": ["tb/ref/ref_engine.v", "tb/ref/ref_engine_v1.v"],
          "tb_fetch_equiv_v2": ["tb/ref/ref_engine_v1.v"], "tb_l2_macro": ["formal/abs_sram.v"]}

# phase -> [(name, file, old text, new text, [testbenches])]
MUTANTS = {
    1: [
        ("JPH/JPL pin still read from [8:6]", "src/control_unit.v",
         "pin_in[operand[11:9]]", "pin_in[operand[8:6]]", ["tb_control_unit"]),
        ("jump_addr truncated to 6 bits", "src/control_unit.v",
         "assign jump_addr     = operand[8:0];", "assign jump_addr     = {3'd0, operand[5:0]};", ["tb_control_unit", "tb_engine_ops"]),
        ("reserved-range check off", "src/engine_top.v",
         "(pc[8:6] != 3'd0) ? 2'd1 : 2'd0", "2'd0", ["tb_engine_ops"]),
        ("fault cause swapped", "src/control_unit.v",
         "fault_cause <= pc_fault;", "fault_cause <= ~pc_fault;", ["tb_control_unit", "tb_engine_ops"]),
        ("faulting instruction commits", "src/control_unit.v",
         "if (!halted && legal && pc_fault == 2'd0) begin", "if (!halted && legal) begin", ["tb_control_unit", "tb_engine_ops"]),
        ("CTRL pc field shifted", "src/mgmt.v",
         "{13'd0, pc_e, 5'd0,", "{14'd0, pc_e, 4'd0,", ["tb_mgmt_read"]),
    ],
}


def run_tb(tb):
    out = os.path.join(BUILD, tb + ".vvp")
    srcs = sorted(glob.glob(os.path.join(ROOT, "src", "*.v"))) + sorted(glob.glob(os.path.join(ROOT, "sim", "ihp_sram", "*.v")))
    c = subprocess.run(["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-DFUNCTIONAL", "-s", tb, "-I", "src", "-I", "tb",
                        "-o", out, f"tb/{tb}.v", *srcs, *EXTRAS.get(tb, [])], cwd=ROOT, capture_output=True, text=True)
    if c.returncode:
        return "COMPILE"
    r = subprocess.run(["vvp", "-n", out], cwd=ROOT, capture_output=True, text=True, timeout=1800)
    res = re.findall(r"RESULT .*", r.stdout)
    return "PASS" if res and all("PASS" in x for x in res) else "FAIL"


def main():
    os.makedirs(BUILD, exist_ok=True)
    total = caught = 0
    for ph in [int(x) for x in sys.argv[1:]] or sorted(MUTANTS):
        for name, f, old, new, tbs in MUTANTS[ph]:
            path = os.path.join(ROOT, f)
            orig = open(path, newline="").read()
            assert orig.count(old) == 1, f"mutant '{name}': text not found exactly once in {f}"
            open(path, "w", newline="").write(orig.replace(old, new))
            try:
                res = {tb: run_tb(tb) for tb in tbs}
            finally:
                open(path, "w", newline="").write(orig)
            hit = "FAIL" in res.values()
            total += 1
            caught += hit
            print(f"  {'DETECTED    ' if hit else 'NOT DETECTED'} P{ph} {name:45s} {res}", flush=True)
    print(f"RESULT mutate: {'PASS' if caught == total else 'FAIL'} ({caught}/{total} mutants detected)")
    sys.exit(0 if caught == total else 1)


if __name__ == "__main__":
    main()
