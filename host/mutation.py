#!/usr/bin/env python3
"""Tiny mutation-testing helper: apply one textual change at a time to an RTL file, run a test, require that it FAILS.

  run(mutants, target_file, runner, root, tag) -> 0 if every mutant was caught
    mutants : list of (description, old_text, new_text); old_text must occur exactly once in target_file
    runner  : f(srcs, name) -> text; srcs is the source list with the target replaced by the mutated copy
The mutated copy lives in build/mutants/<tag>/ and never touches src/.
"""
import os


def run(mutants, target, runner, root, tag, base_srcs=None):
    base_srcs = base_srcs or [target]
    text = open(target).read()
    outdir = os.path.join(root, "build", "mutants", tag)
    os.makedirs(outdir, exist_ok=True)
    caught = 0
    bad = 0
    for n, (desc, old, new) in enumerate(mutants):
        cnt = text.count(old)
        if cnt != 1:
            print(f"  MUTANT {n:2d} INVALID ({cnt} matches): {desc}")
            bad += 1
            continue
        path = os.path.join(outdir, f"m{n}_" + os.path.basename(target))
        open(path, "w").write(text.replace(old, new))
        srcs = [path if s == target else s for s in base_srcs]
        out = runner(srcs, f"{tag}_m{n}")
        if "COMPILE" in out:        # a mutant that does not even compile proves nothing: report it as invalid
            print(f"  MUTANT {n:2d} INVALID (does not compile): {desc}")
            bad += 1
            continue
        failed = ("FAIL" in out) or ("NO RESULT" in out)
        caught += failed
        print(f"  MUTANT {n:2d} {'caught ' if failed else 'MISSED '} {desc}")
    print(f"  mutants caught: {caught}/{len(mutants)}" + (f" ({bad} invalid)" if bad else ""))
    return 0 if caught == len(mutants) and not bad else 1


def run_tb(root, tb, srcs, name, plus=(), extra_inc=(), defines=()):
    """Compile tb + srcs with Icarus and run it; return the RESULT line (plus the log when it failed)."""
    import subprocess
    if os.name == "nt" and os.path.isdir(r"C:\iverilog\bin") and r"C:\iverilog\bin" not in os.environ["PATH"]:
        os.environ["PATH"] += os.pathsep + r"C:\iverilog\bin"
    build = os.path.join(root, "build", "mut_run")
    os.makedirs(build, exist_ok=True)
    vvp = os.path.join(build, name + ".vvp")
    cmd = ["iverilog", "-Wall", "-Wno-timescale", "-g2012", "-DFUNCTIONAL"] + [f"-D{d}" for d in defines] + \
          ["-I", os.path.join(root, "src"), "-I", os.path.join(root, "tb")] + [x for i in extra_inc for x in ("-I", i)] + \
          ["-o", vvp, tb] + list(srcs)
    r = subprocess.run(cmd, capture_output=True, text=True)
    if r.returncode:
        return "COMPILE FAIL " + r.stderr[:300]
    try:
        r = subprocess.run(["vvp", "-n", vvp] + list(plus), capture_output=True, text=True, timeout=900)
    except subprocess.TimeoutExpired:
        return "FAIL timeout"
    res = [l for l in r.stdout.splitlines() if l.startswith("RESULT")]
    return (res[-1] if res else "NO RESULT") + ("\n" + r.stdout[-1500:] if "FAIL" in r.stdout else "")
