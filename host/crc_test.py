#!/usr/bin/env python3
"""CRC unit verification: runs tb/tb_crc_unit.v (directed + catalogue + independent-division reference) and feeds it vectors
made by host/crc_model.py (random width/poly/init/flags/xorout/messages, plus every catalogue model on random data).
  python host/crc_test.py [vectors N] [mutants]
"""
import os
import random
import subprocess
import sys

import crc_model as cm
import mutation as mut

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
if os.name == "nt" and os.path.isdir(r"C:\iverilog\bin"):
    os.environ["PATH"] += os.pathsep + r"C:\iverilog\bin"
SRC = [os.path.join(ROOT, "src", "crc_unit.v")]
TB = os.path.join(ROOT, "tb", "tb_crc_unit.v")
BUILD = os.path.join(ROOT, "build", "crc")


def make_vectors(path, n, seed=7):
    rnd = random.Random(seed)
    lines = []
    for name in cm.CATALOGUE:
        for _ in range(20):
            c = cm.make(name)
            data = bytes(rnd.randrange(256) for _ in range(rnd.randrange(0, 40)))
            lines.append((c, data, c.of(data)))
    for _ in range(n):
        w = rnd.randint(1, 32)
        m = (1 << w) - 1
        c = cm.CRC(w, rnd.getrandbits(32) & m, rnd.getrandbits(32) & m, bool(rnd.getrandbits(1)),
                   bool(rnd.getrandbits(1)), rnd.getrandbits(32) & m)
        data = bytes(rnd.randrange(256) for _ in range(rnd.randrange(0, 33)))
        lines.append((c, data, c.of(data)))
    with open(path, "w") as f:
        for c, data, v in lines:
            f.write(f"{c.width} {c.poly:x} {c.init:x} {int(c.refin)} {int(c.refout)} {c.xorout:x} {len(data)} "
                    + " ".join(f"{b:02x}" for b in data) + f" {v:x}\n")
    return len(lines)


def run_tb(srcs, vec=None, name="crc"):
    os.makedirs(BUILD, exist_ok=True)
    vvp = os.path.join(BUILD, f"{name}.vvp")
    r = subprocess.run(["iverilog", "-Wall", "-Wno-timescale", "-g2012", "-I", os.path.join(ROOT, "src"),
                        "-I", os.path.join(ROOT, "tb"), "-o", vvp, TB] + srcs, capture_output=True, text=True)
    if r.returncode:
        return "COMPILE FAIL " + r.stderr[:400]
    args = ["vvp", "-n", vvp] + ([f"+VEC={vec}"] if vec else [])
    r = subprocess.run(args, capture_output=True, text=True, timeout=600)
    res = [l for l in r.stdout.splitlines() if l.startswith("RESULT")]
    return (res[-1] if res else "NO RESULT") + ("\n" + r.stdout if "FAIL" in r.stdout else "")


def main():
    phases = sys.argv[1:] or ["vectors", "mutants"]
    n = 3000
    rc = 0
    if cm.selftest():
        return 1
    if "vectors" in phases:
        vec = os.path.join(BUILD, "vectors.txt")
        os.makedirs(BUILD, exist_ok=True)
        cnt = make_vectors(vec, n)
        out = run_tb(SRC, vec)
        print(f"  {cnt} Python vectors:", out.splitlines()[0])
        if "PASS" not in out:
            print(out)
            rc = 1
    if "mutants" in phases:
        mutants = [
            ("refin ignored (always MSB first)", "refin ? q_din[i] : q_din[7 - i]", "q_din[7 - i]"),
            ("refout ignored", "(refout ? refl : cl_r)", "cl_r"),
            ("width mask off by one", "(32'd1 << (wm1 + 5'd1)) - 32'd1", "(32'd1 << wm1) - 32'd1"),
            ("polynomial aligned one bit off", "(cmd_poly ? q_data : poly) << s_new;", "(cmd_poly ? q_data : poly) << (s_new + 5'd1);"),
            ("init not aligned on RST", "if (cmd_rst || cmd_fmt)  cl <= lsh;", "if (cmd_rst) cl <= init; else if (cmd_fmt) cl <= lsh;"),
            ("xorout skipped", "^ xorout) & mask", ") & mask"),
            ("feedback ignores input bit", "((c[31] ^ b) ? p : 32'd0)", "((c[31]) ? p : 32'd0)"),
            ("top bit taken one low", "((c[31] ^ b) ? p : 32'd0)", "((c[30] ^ b) ? p : 32'd0)"),
            ("byte step feeds only 7 bits", "for (i = 0; i < 8; i = i + 1)", "for (i = 0; i < 7; i = i + 1)"),
            ("set_poly also resets the register", "if (cmd_poly) poly   <= q_data;", "if (cmd_poly) begin poly <= q_data; cl <= init; end"),
            ("reset default not CRC-32 (init)", "init    <= 32'hFFFF_FFFF;", "init    <= 32'h0;"),
            ("reflect shifted by one", "assign refl[k] = cl[31 - k];", "assign refl[k] = cl[(62 - k) % 32];"),
            ("format write does not realign the register", "if (cmd_rst || cmd_fmt)  cl <= lsh;", "if (cmd_rst)  cl <= lsh;"),
            ("format write realigns by the old width", "wire [4:0]  s_new   = cmd_fmt ? ~q_data[4:0] : s_cur;", "wire [4:0]  s_new   = s_cur;"),
            # command pipeline and pre-aligned polynomial
            ("aligned polynomial not updated on FMT", "if (cmd_poly || cmd_fmt) poly_al <= psh;", "if (cmd_poly) poly_al <= psh;"),
            ("aligned polynomial not updated on POLY", "if (cmd_poly || cmd_fmt) poly_al <= psh;", "if (cmd_fmt) poly_al <= psh;"),
            ("byte step uses the unaligned polynomial", "q_din[7 - i], poly_al);", "q_din[7 - i], poly);"),
            ("busy never set", "assign busy = cmd_rst | cmd_poly | cmd_init | cmd_xor | cmd_fmt | cmd_bit | cmd_byte;", "assign busy = 1'b0;"),
            ("busy combinational from the command inputs",
             "assign busy = cmd_rst | cmd_poly | cmd_init | cmd_xor | cmd_fmt | cmd_bit | cmd_byte;",
             "assign busy = rst_crc | set_poly | set_init | set_xor | set_fmt | feed_bit | feed_byte;"),
            ("feed takes the live input byte, not the registered one", "wire [31:0] bit_next = step(cl, q_din[0], poly_al);",
             "wire [31:0] bit_next = step(cl, din[0], poly_al);"),
        ]
        res = mut.run(mutants, SRC[0], lambda srcs, name: run_tb(srcs, os.path.join(BUILD, "vectors.txt"), name), ROOT, "crc")
        rc |= res
    print("RESULT crc_test:", "PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    sys.exit(main())
