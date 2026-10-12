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
         "(pc[7:6] != 2'd0 ? 2'd1 : 2'd0)", "2'd0", ["tb_engine_ops"]),
        ("fault cause swapped", "src/control_unit.v",
         "fault_cause <= pc_fault;", "fault_cause <= ~pc_fault;", ["tb_control_unit", "tb_engine_ops"]),
        ("faulting instruction commits", "src/control_unit.v",
         "if (!halted && legal && pc_fault == 2'd0) begin", "if (!halted && legal) begin", ["tb_control_unit", "tb_engine_ops"]),
        ("CTRL pc field shifted", "src/mgmt.v",
         "{13'd0, pc_e, 5'd0,", "{14'd0, pc_e, 4'd0,", ["tb_mgmt_read"]),
    ],
    2: [
        ("protection range compare < instead of <=", "src/mgmt.v",
         "wi >= l2_range[7:0]  &&", "wi > l2_range[7:0]  &&", ["tb_l2_host"]),
        ("L2 write commits on an incomplete frame", "src/mgmt.v",
         "else if (len_ok && is_write && hit_l2 && !l2_prot)", "else if (is_write && hit_l2 && !l2_prot)", ["tb_l2_host"]),
        ("L2 read data latched a clock early (stale word)", "src/mgmt.v",
         "if (l2_cap) rd_word <= l2_rdata;", "if (cap) rd_word <= l2_rdata;", ["tb_l2_host"]),
        ("one bit-mask bit stuck at 0", "src/l2_mem.v",
         ".A_BM(32'hFFFFFFFF)", ".A_BM(32'hFFFFFFFE)", ["tb_l2_host", "tb_arb"]),
        ("protection off", "src/mgmt.v",
         "wire l2_prot  = (eng_run[0]", "wire l2_prot  = 1'b0 && (eng_run[0]", ["tb_l2_host"]),
        ("ARB_CFG written from the wrong bits", "src/mgmt.v",
         "arb_policy <= data[1:0];", "arb_policy <= data[2:1];", ["tb_l2_host"]),
        ("RESET_PC writable while running", "src/mgmt.v",
         "is_write && at_rv && !eng_run[eng]", "is_write && at_rv", ["tb_l2_host"]),
        ("round-robin inverted", "src/l2_mem.v",
         "(policy == 2'd0 & ~last)", "(policy == 2'd0 & last)", ["tb_arb"]),
        ("host not the top class", "src/l2_mem.v",
         "assign gnt = host ? 2'b00 :", "assign gnt = 1'b0 ? 2'b00 :", ["tb_arb"]),
        ("request class ignored", "src/l2_mem.v",
         "wire [1:0] top = (req & req_hi) != 2'b00 ? (req & req_hi) : req;", "wire [1:0] top = req;", ["tb_arb"]),
    ],
    3: [
        ("bubble does not block pin writes (SETH)", "src/control_unit.v",
         "        if (!halted && instr_valid && pc_fault == 2'd0 && legal) begin",
         "        if (!halted && !instr_valid && opcode == `OP_SETH) begin pin_wr = 1'b1; pin_wr_idx = pin_sel; pin_wr_val = 1'b1; end\n        if (!halted && instr_valid && pc_fault == 2'd0 && legal) begin",
         ["tb_l2_exec"]),
        ("bubble lets a FIFO pop through (PULL)", "src/control_unit.v",
         "        if (!halted && instr_valid && pc_fault == 2'd0 && legal) begin",
         "        if (!halted && !instr_valid && opcode == `OP_PULL && !tx_empty) tx_rd_en = 1'b1;\n        if (!halted && instr_valid && pc_fault == 2'd0 && legal) begin",
         ["tb_l2_exec"]),
        ("bubble lets the delay counter load (WAIT)", "src/control_unit.v",
         "        if (!halted && instr_valid && pc_fault == 2'd0 && legal) begin",
         "        if (!halted && !instr_valid && opcode == `OP_WAIT) dc_load = 1'b1;\n        if (!halted && instr_valid && pc_fault == 2'd0 && legal) begin",
         ["tb_l2_exec"]),
        ("legality checked on an invalid word", "src/control_unit.v",
         "if (pc_fault != 2'd0 || (instr_valid && !legal)) begin", "if (pc_fault != 2'd0 || !legal) begin",
         ["tb_l2_exec"]),
        ("ir2 latched from the wrong clock (always the macro output)", "src/engine_top.v",
         "ir2 <= w2; got <= need && l2_gnt;", "ir2 <= l2_rdata; got <= need && l2_gnt;", ["tb_l2_exec"]),
        ("RUN falling does not clear the fetch state", "src/engine_top.v",
         "        if (!core_rst_n) begin\n            ir2 <= 32'd0; got <= 1'b0; ir2_ok <= 1'b0;",
         "        if (!rst_n) begin\n            ir2 <= 32'd0; got <= 1'b0; ir2_ok <= 1'b0;",
         ["tb_l2_exec", "tb_engine_ops"]),
        ("request not gated while held", "src/engine_top.v",
         "wire need = L2_EN && core_rst_n && !halted && next_pc[8] && !keep;",
         "wire need = L2_EN && !halted && next_pc[8] && !keep;", ["tb_l2_exec", "tb_engine_ops"]),
        ("L2 range check off by one (hi excluded)", "src/engine_top.v",
         "(pc[7:0] < lo || pc[7:0] > hi) ? 2'd2 : 2'd0", "(pc[7:0] < lo || pc[7:0] >= hi) ? 2'd2 : 2'd0",
         ["tb_l2_exec", "tb_engine_ops"]),
        ("reset vector ignored", "src/engine_top.v",
         ".rst_val   (L2_EN ? reset_pc : 9'd0),", ".rst_val   (9'd0),", ["tb_l2_exec", "tb_engine_ops"]),
        ("word kept although the pc moved", "src/engine_top.v",
         "wire keep = pc[8] && instr_valid && (next_pc == pc);", "wire keep = pc[8] && instr_valid;", ["tb_l2_exec"]),
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
