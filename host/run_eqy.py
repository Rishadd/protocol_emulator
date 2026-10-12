#!/usr/bin/env python3
"""Formal equivalence for the two-tier work (docs/TWO_TIER_MEMORY_PLAN.md E1/E2), with eqy.

  python host/run_eqy.py E2      the chip built with -DNO_L2 == the chip at tag tt-phase1

The gold design is taken from the git tag, the gate design is src/ as it is now. The SRAM macros are
black boxes (their liberty files). Both designs are flattened (constants then cross module borders).
Sources are read through relative paths: auto-generated names then carry no drive letter, which would
otherwise break eqy's partition file names on Windows. Prints one RESULT line.
"""
import os
import subprocess
import sys

ROOT = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
LIBS = ["C:/tools/ihp-sram/RM_IHPSG13_1P_64x16_c2_typ_1p20V_25C.lib",
        "C:/tools/ihp-sram/RM_IHPSG13_1P_256x32_c2_bm_bist_typ_1p20V_25C.lib"]
os.environ["PATH"] = os.pathsep.join([r"C:\tools\oss-cad-suite\bin", r"C:\tools\oss-cad-suite\lib", os.environ["PATH"],
                                      r"C:\Users\risha\miniconda3\envs\eda\Library\bin"])
CHECKS = {"E2": ("tt-phase1", "tt_um_protocol_emulator", "-DNO_L2")}


def main():
    name = sys.argv[1] if len(sys.argv) > 1 else "E2"
    tag, top, defs = CHECKS[name]
    work = os.path.join(ROOT, "build", "eqy", name)          # src/ is ../../../src from here
    os.makedirs(os.path.join(work, "gold"), exist_ok=True)
    for f in subprocess.run(["git", "ls-tree", "--name-only", tag, "src/"], cwd=ROOT,
                            capture_output=True, text=True).stdout.split():
        if f.endswith((".v", ".vh")):
            with open(os.path.join(work, "gold", os.path.basename(f)), "w") as out:
                out.write(subprocess.run(["git", "show", f"{tag}:{f}"], cwd=ROOT, capture_output=True, text=True).stdout)
    libs = "\n".join(f"read_liberty -lib {l}" for l in LIBS)
    gv = " ".join(sorted("gold/" + f for f in os.listdir(os.path.join(work, "gold")) if f.endswith(".v")))
    sv = " ".join(sorted("../../../src/" + f for f in os.listdir(os.path.join(ROOT, "src")) if f.endswith(".v")))
    prep = f"prep -flatten -top {top}\n\n"
    with open(os.path.join(work, f"{name}.eqy"), "w") as f:
        f.write(f"[gold]\n{libs}\nread_verilog -sv -Igold {gv}\n{prep}"
                f"[gate]\n{libs}\nread_verilog -sv {defs} -I../../../src {sv}\n{prep}"
                "[strategy sat]\nuse sat\ndepth 10\n")
    r = subprocess.run(["eqy", "-f", "-d", "run", f"{name}.eqy"], cwd=work, capture_output=True, text=True)
    ok = "DONE (PASS" in r.stdout
    print("\n".join(l for l in r.stdout.splitlines() if "DONE" in l or "Failed" in l or "ERROR" in l))
    print(f"RESULT eqy {name}: {'PASS' if ok else 'FAIL'}")
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
