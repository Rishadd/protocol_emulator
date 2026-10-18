#!/usr/bin/env python3
"""Differential test: random programs + random pin/FIFO stimulus run in the RTL (tb/tb_isa_diff.v -> engine_top) and in
host/isa_model.py; every clock of every test must match on pc, pins, status, FIFO head, shifters, loop counter, CRC value,
flags and R0..R7.   python host/isa_diff_test.py [run] [mutants] [--tests N] [--seed S]

Coverage is counted from what the model actually executed (opcodes, ALU functions, JCC conditions taken/not taken, RGET sources,
RPUT destinations, CRC operations, trap kinds) and a minimum count for each is required, so a green run means the whole
instruction set was exercised, not only that the two agree on easy cases.
"""
import argparse
import collections
import os
import random
import subprocess
import sys

import asm as A
import isa_model as M
import mutation as mut

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
BUILD = os.path.join(ROOT, "build", "isa_diff")
if os.name == "nt" and os.path.isdir(r"C:\iverilog\bin"):
    os.environ["PATH"] += os.pathsep + r"C:\iverilog\bin"

CYC = 400


# ------------------------------------------------------------------ random programs
WEIGHTS = [("NOP", 2), ("WAIT", 3), ("JMP", 3), ("HALT", 0.6), ("SETL", 4), ("DJNZ", 5), ("PULL", 3), ("PUSH", 3),
           ("OUT1", 4), ("IN1", 4), ("SETH", 3), ("SETLO", 3), ("DIRO", 2), ("DIRI", 2), ("WAITH", 2), ("WAITL", 2),
           ("CFG", 3), ("JPH", 3), ("JPL", 3), ("JPO", 3), ("PUSHI", 3), ("LDI", 6), ("ALU", 14), ("JCC", 8),
           ("RGET", 6), ("RPUT", 6), ("WAITR", 1.2), ("CRC", 9), ("BAD", 0.9),
           ("XSELF", 2.5), ("NOTI", 2.5)]       # idioms that make Z=1 and N=1 common enough to cover every JCC condition both ways


def rnd_word(rnd, L):
    names = [n for n, _ in WEIGHTS]
    n = rnd.choices(names, [w for _, w in WEIGHTS])[0]

    def tgt():
        return rnd.randrange(L)

    if n == "BAD":                                  # every reserved encoding gets its share
        op, extra = rnd.choice([(28, 0), (29, 0), (30, 0), (31, 0), ("ALU", 13), ("ALU", 14), ("ALU", 15), ("RGET", 6),
                                ("RGET", 7), ("RPUT", 4), ("RPUT", 5), ("RPUT", 6), ("RPUT", 7), ("CRC", 7)])
        if isinstance(op, int):
            return op << 27 | rnd.getrandbits(27)
        if op == "ALU":
            return A.word("ALU", extra << 23 | rnd.getrandbits(23))
        if op == "CRC":
            return A.word("CRC", extra << 24 | rnd.getrandbits(3))
        return A.word(op, extra << 4 | rnd.randrange(8))
    if n == "XSELF":
        r = rnd.randrange(8)
        return A.enc_alu(rnd.choice([5, 2, 8]), r, r)                  # XOR / SUB / CMP r,r: result 0, Z=1
    if n == "NOTI":
        return A.enc_alu(10, rnd.randrange(8), 0, rnd.randrange(0, 50))   # NOT imm: big negative number, N=1
    if n == "NOP":
        return A.word("NOP", rnd.getrandbits(27) if rnd.random() < 0.3 else 0)    # operand of NOP is ignored
    if n == "WAIT":
        return A.word("WAIT", rnd.randrange(0, 6))
    if n == "JMP":
        return A.word("JMP", tgt() | (rnd.getrandbits(19) << 8 if rnd.random() < 0.3 else 0))
    if n == "HALT":
        return A.word("HALT")
    if n == "SETL":
        return A.word("SETL", rnd.randrange(0, 9) if rnd.random() < 0.9 else rnd.getrandbits(16))
    if n == "DJNZ":
        return A.word("DJNZ", tgt())
    if n in ("PULL", "PUSH"):
        return A.word(n)
    if n in ("OUT1", "IN1"):
        return A.word(n, rnd.randrange(0, 5))
    if n in ("SETH", "SETLO", "DIRO", "DIRI", "WAITH", "WAITL"):
        return A.word(n, rnd.randrange(8) | (rnd.getrandbits(8) << 3 if rnd.random() < 0.2 else 0))
    if n == "CFG":
        return A.word("CFG", rnd.getrandbits(8))
    if n in ("JPH", "JPL"):
        return A.word(n, rnd.randrange(8) << 8 | tgt())
    if n == "JPO":
        return A.word("JPO", tgt())
    if n == "PUSHI":
        return A.word("PUSHI", rnd.getrandbits(27))
    if n == "LDI":
        return A.enc_ldi(rnd.randrange(8), rnd.randrange(0, 40) if rnd.random() < 0.7 else rnd.getrandbits(24))
    if n == "ALU":
        f = rnd.choices(range(13), [1, 2, 3, 1, 1, 1, 1, 1, 4, 1, 1, 1, 1])[0]
        imm = rnd.randrange(0, 40) if rnd.random() < 0.6 else rnd.getrandbits(16)
        return A.enc_alu(f, rnd.randrange(8), rnd.randrange(8), imm if rnd.random() < 0.5 else None)
    if n == "JCC":
        return A.enc_jcc(rnd.randrange(8), tgt())
    if n == "RGET":     # CRC source favoured: RGET CRC right after a CRC instruction (the 1-clock wait) must come up often
        return A.enc_rget(rnd.randrange(8), 4 if rnd.random() < 0.3 else rnd.randrange(6))
    if n == "RPUT":
        return A.enc_rput(rnd.randrange(4), rnd.randrange(8))
    if n == "WAITR":
        return A.word("WAITR", rnd.randrange(8))
    return A.enc_crc(rnd.randrange(7), rnd.randrange(8))


SAFE = ("NOP", "LDI", "ALU", "CRC", "SETH", "SETLO", "DIRO", "DIRI", "CFG")    # straight-line instructions: no jumps, no stalls


def make_test(rnd):
    L = rnd.randint(24, 96)
    prog = [A.enc_ldi(i, rnd.randrange(0, 300) if rnd.random() < 0.5 else rnd.getrandbits(24)) for i in range(8)]   # varied register values
    if rnd.random() < 0.15:                      # trap-focused: straight-line code that is certain to reach a reserved encoding
        saved = list(WEIGHTS)
        WEIGHTS[:] = [(n, w) for n, w in WEIGHTS if n in SAFE]
        prog += [rnd_word(rnd, L) for _ in range(rnd.randrange(0, 6))]
        WEIGHTS[:] = [("BAD", 1)]
        prog += [rnd_word(rnd, L)]
        WEIGHTS[:] = saved
    prog += [rnd_word(rnd, L) for _ in range(L - len(prog))]
    prog += [A.word("HALT")] * (256 - L)
    stim = []
    pin = rnd.getrandbits(8)
    p_tx = rnd.choice([0.0, 0.03, 0.15, 0.5])          # some programs never see TX data (RGET/PULL stall), some get plenty
    p_rd = rnd.choice([0.0, 0.05, 0.35, 0.9])          # some never drain the RX FIFO (RPUT/PUSH stall when it is full)
    for _ in range(CYC):
        if rnd.random() < 0.3:
            pin = rnd.getrandbits(8) if rnd.random() < 0.5 else pin ^ (1 << rnd.randrange(8))
        tx = rnd.getrandbits(32) if rnd.random() < p_tx else None
        stim.append((pin, tx, rnd.random() < p_rd))
    return prog, stim


def stim_word(s):
    pin, tx, rd = s
    return pin << 40 | (tx is not None) << 33 | int(rd) << 32 | (tx or 0)


# ------------------------------------------------------------------ run
def write_inputs(tests, tag):
    os.makedirs(BUILD, exist_ok=True)
    pf, sf = os.path.join(BUILD, f"{tag}_prog.mem"), os.path.join(BUILD, f"{tag}_stim.mem")
    with open(pf, "w") as f:
        for prog, _ in tests:
            f.write("".join(f"{w:08x}\n" for w in prog))
    with open(sf, "w") as f:
        for _, stim in tests:
            f.write("".join(f"{stim_word(s):012x}\n" for s in stim))
    return pf, sf


def rtl_sources(override=None):
    srcs = sorted(os.path.join(ROOT, "src", f) for f in os.listdir(os.path.join(ROOT, "src")) if f.endswith(".v"))
    srcs += [os.path.join(ROOT, "sim", "ihp_sram", f) for f in ("RM_IHPSG13_1P_core_behavioral_bm_bist.v",
                                                                 "RM_IHPSG13_1P_256x32_c2_bm_bist.v")]
    if override:                      # {original file name: path of the mutated copy}
        srcs = [override.get(os.path.basename(s), s) for s in srcs]
    return srcs


def run_rtl(tests, tag, srcs=None):
    pf, sf = write_inputs(tests, tag)
    vvp = os.path.join(BUILD, f"{tag}.vvp")
    out = os.path.join(BUILD, f"{tag}_rtl.trace")
    r = subprocess.run(["iverilog", "-Wno-timescale", "-g2012", "-DFUNCTIONAL", "-I", os.path.join(ROOT, "src"),
                        "-o", vvp, os.path.join(ROOT, "tb", "tb_isa_diff.v")] + (srcs or rtl_sources()),
                       capture_output=True, text=True)
    if r.returncode:
        return None, "COMPILE FAIL " + r.stderr[:300]
    r = subprocess.run(["vvp", "-n", vvp, f"+PROG={pf}", f"+STIM={sf}", f"+NT={len(tests)}", f"+CYC={CYC}", f"+OUT={out}"],
                       capture_output=True, text=True, timeout=1800)
    if "DONE" not in r.stdout:
        return None, "NO RESULT " + r.stdout[-300:]
    if "FETCH MISMATCH" in r.stdout:      # the fetch stage and the control unit disagreed about a branch (engine_top checker)
        return None, "FETCH MISMATCH " + r.stdout[r.stdout.index("FETCH MISMATCH"):][:300]
    return open(out).read().split("\n")[:-1], ""


def model_trace(test):
    prog, stim = test
    e = M.Engine(prog)
    lines = []
    for pin, tx, rd in stim:
        e.step(pin, tx, rd)
        lines.append(e.trace_line())
    return lines, e.cov


FIELDS = "pc pin_out pin_oe status rx_head osr isr lc crc znc r0 r1 r2 r3 r4 r5 r6 r7".split()


def compare(tests, rtl_lines):
    """Return (mismatches, coverage Counter)."""
    cov = collections.Counter()
    bad = []
    for t, test in enumerate(tests):
        exp, c = model_trace(test)
        cov.update(c)
        got = rtl_lines[t * CYC:(t + 1) * CYC]
        for cyc in range(CYC):
            if exp[cyc] != got[cyc]:
                e, g = exp[cyc].split(), got[cyc].split()
                diff = [f"{FIELDS[i]}: model {e[i]} rtl {g[i]}" for i in range(len(e)) if e[i] != g[i]]
                prev = test[0][int(exp[cyc - 1].split()[0], 16)] if cyc else test[0][0]
                bad.append((t, cyc, diff, A.disasm(prev)))
                break
    return bad, cov


def make_tests(seed, n):
    rnd = random.Random(seed)
    return [make_test(rnd) for _ in range(n)]


REQUIRED = [("op", n, 40) for n in A.OPCODE if n not in ("HALT",)] + [("op", "HALT", 5)] + \
           [("alu", f, 30) for f in range(13)] + \
           [("jcc", c, t, 15) for c in range(8) for t in (0, 1)] + \
           [("rget", s, 30) for s in range(6)] + [("rput", d, 30) for d in range(4)] + [("crc", k, 30) for k in range(7)] + \
           [("rget_crc_wait", 20)]


def coverage_report(cov, verbose=True):
    missing = []
    for item in REQUIRED:
        key, need = item[:-1], item[-1]
        if cov.get(key, 0) < need:
            missing.append((key, cov.get(key, 0), need))
    traps = sorted((k for k in cov if k[0] == "trap"), key=str)
    if verbose:
        total = sum(v for k, v in cov.items() if k[0] == "op")
        print(f"  coverage: {total} instructions committed; trap kinds seen: {len(traps)}; "
              f"{len(REQUIRED) - len(missing)}/{len(REQUIRED)} coverage points met")
        for m in missing:
            print(f"    NOT COVERED enough: {m[0]} saw {m[1]}, need {m[2]}")
    return not missing and len(traps) >= 6


ENGINE_MUTANTS = [
    ("control_unit.v", "RGET TXF does not stall when the FIFO is empty",
     "(opcode == `OP_RGET && rg_src == `RG_TXF) ? tx_empty :", "(opcode == `OP_RGET && rg_src == `RG_TXF) ? 1'b0 :"),
    ("control_unit.v", "RGET CRC does not wait for the CRC unit",
     "(opcode == `OP_RGET && rg_src == `RG_CRC) ? crc_busy :", "(opcode == `OP_RGET && rg_src == `RG_CRC) ? 1'b0 :"),
    ("engine_top.v", "CRC busy not connected", ".crc_busy      (crc_busy),", ".crc_busy      (1'b0),"),
    # fetch stage: a branch is resolved one clock early from the next-state values; using the current values (or not holding
    # the fetch while the executing instruction stalls) must show up as wrong program flow
    ("fetch_unit.v", "DJNZ resolved with the current loop counter", "wire [15:0] l  = use_next ? lc_next      : lc;", "wire [15:0] l  = lc;"),
    ("fetch_unit.v", "JCC resolved with the current Z flag", "wire        z  = use_next ? flag_z_next  : flag_z;", "wire        z  = flag_z;"),
    ("fetch_unit.v", "JCC resolved with the current C flag", "wire        c  = use_next ? flag_c_next  : flag_c;", "wire        c  = flag_c;"),
    ("fetch_unit.v", "JPO resolved with the current OSR bit", "wire        ob = use_next ? osr_bit_next : osr_bit;", "wire        ob = osr_bit;"),
    ("fetch_unit.v", "JPH/JPL resolved with the current pins", "wire [7:0]  pv = use_next ? pins_next    : pins;", "wire [7:0]  pv = pins;"),
    ("fetch_unit.v", "fetch does not wait for a stalled instruction", "assign addr = running ? (x_done ? succ : fetch_pc) :",
     "assign addr = running ? succ :"),
    ("engine_top.v", "JPO bit order from the current CFG", "cfg_osr_msb_next ? osr_data_next[31]", "cfg_osr_msb ? osr_data_next[31]"),
    ("fetch_unit.v", "fetch: JCC GTU is the LEU condition", "`CC_GTU: cc = c & ~z;", "`CC_GTU: cc = ~c | z;"),
    ("fetch_unit.v", "fetch: JCC C and NC swapped", "`CC_C:   cc = c;", "`CC_C:   cc = ~c;"),
    ("control_unit.v", "RPUT RXF does not stall when full",
     "(opcode == `OP_RPUT && rp_dst == `RP_RXF) ? rx_full :", "(opcode == `OP_RPUT && rp_dst == `RP_RXF) ? 1'b0 :"),
    ("control_unit.v", "JCC GTU is the LEU condition", "`CC_GTU: cc_true = flag_c & ~flag_z;", "`CC_GTU: cc_true = ~flag_c | flag_z;"),
    ("control_unit.v", "JCC C and NC swapped", "`CC_C:   cc_true = flag_c;", "`CC_C:   cc_true = ~flag_c;"),
    ("control_unit.v", "WAITR holds even when the register is 0", "(opcode == `OP_WAITR && !rs_zero);", "(opcode == `OP_WAITR);"),
    ("alu_unit.v", "ALU source read from operand[2:0] (wrong read port)", "wire [31:0] alu_b = r[operand[19:17]];", "wire [31:0] alu_b = r[operand[2:0]];"),
    ("control_unit.v", "ALU function 13 is legal", "(alu_func <= `ALU_LAST_LEGAL)", "(alu_func <= `ALU_LAST_LEGAL + 4'd1)"),
    ("control_unit.v", "RGET source 6 is legal", "(rg_src   <= `RG_TXF)", "(rg_src   <= 3'd6)"),
    ("control_unit.v", "CRC operation 7 is legal", "(crc_cop  <= `CRC_BYTE)", "(crc_cop  <= 3'd7)"),
    ("control_unit.v", "opcode 28 is legal", "(opcode <= `OP_LAST_LEGAL) && sub_ok", "(opcode <= 5'd28) && sub_ok"),
    ("control_unit.v", "RPUT OSR also pops the TX FIFO", "`RP_OSR: begin osr_load = 1'b1; osr_from_reg = 1'b1; end",
     "`RP_OSR: begin osr_load = 1'b1; osr_from_reg = 1'b1; tx_rd_en = 1'b1; end"),
    ("control_unit.v", "RPUT LC loads the operand", "`RP_LC:  begin lc_load = 1'b1; lc_from_reg = 1'b1; end",
     "`RP_LC:  begin lc_load = 1'b1; end"),
    ("control_unit.v", "RPUT ISR does nothing", "`RP_ISR: isr_load = 1'b1;", "`RP_ISR: ;"),
    ("control_unit.v", "RGET src field decoded from [5:3]", "wire [2:0]  rg_src   = operand[6:4];", "wire [2:0]  rg_src   = operand[5:3];"),
    ("engine_top.v", "RGET PIN reads the unsynchronized pins", "(instr[6:4] == `RG_PIN) ? {24'd0, pin_in_sync} :",
     "(instr[6:4] == `RG_PIN) ? {24'd0, pin_in} :"),
    ("engine_top.v", "RGET LC returns the load value", "{16'd0, lc_count}", "{16'd0, lc_load_value}"),
    ("engine_top.v", "RPUT RXF pushes the ISR", "push_reg ? rs_val : isr_data", "push_reg ? isr_data : isr_data"),
    ("engine_top.v", "RPUT OSR loads the TX word", "osr_from_reg ? rs_val : tx_rd_data", "tx_rd_data"),
    ("engine_top.v", "WAITR delay truncated to 8 bits", "dc_from_reg ? rs_val[26:0]", "dc_from_reg ? {19'd0, rs_val[7:0]}"),
    ("engine_top.v", "CRC config data is the operand", ".cfg_data  (rs_val)", ".cfg_data  ({5'd0, instr[26:0]})"),
    ("engine_top.v", "CRC byte is rs[15:8]", ".din       (rs_val[7:0])", ".din       (rs_val[15:8])"),
    ("engine_top.v", "RGET data into the register file is the TX word", ".rget_data (rget_data)", ".rget_data (tx_rd_data)"),
    ("engine_top.v", "RPUT ISR loads zero", ".load       (isr_load),\n        .load_value (rs_val),", ".load       (isr_load),\n        .load_value (32'd0),"),
    ("engine_top.v", "RPUT LC value truncated", "lc_from_reg ? rs_val[15:0]", "lc_from_reg ? {8'd0, rs_val[7:0]}"),
]


def mutants_phase(seed, n):
    tests = make_tests(seed + 1000, n)
    rc = 0
    caught = 0
    bad = 0
    outdir = os.path.join(ROOT, "build", "mutants", "isa_diff")
    os.makedirs(outdir, exist_ok=True)
    for i, (fname, desc, old, new) in enumerate(ENGINE_MUTANTS):
        path = os.path.join(ROOT, "src", fname)
        text = open(path).read()
        if text.count(old) != 1:
            print(f"  MUTANT {i:2d} INVALID ({text.count(old)} matches): {desc}")
            bad += 1
            continue
        mpath = os.path.join(outdir, f"m{i}_{fname}")
        open(mpath, "w").write(text.replace(old, new))
        lines, err = run_rtl(tests, f"mut{i}", rtl_sources({fname: mpath}))
        if lines is None:
            if err.startswith("COMPILE"):
                print(f"  MUTANT {i:2d} INVALID (does not compile): {desc}")
                bad += 1
                continue
            hit = True
        else:
            mism, _ = compare(tests, lines)
            hit = bool(mism)
        caught += hit
        print(f"  MUTANT {i:2d} {'caught ' if hit else 'MISSED '} {desc}")
    print(f"  mutants caught: {caught}/{len(ENGINE_MUTANTS)}" + (f" ({bad} invalid)" if bad else ""))
    return 0 if caught == len(ENGINE_MUTANTS) and not bad else 1


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("phases", nargs="*", default=["run", "mutants"])
    ap.add_argument("--tests", type=int, default=600)
    ap.add_argument("--seed", type=int, default=1)
    a = ap.parse_args()
    rc = 0
    if M.selftest():
        return 1
    if "run" in a.phases:
        total_cov = collections.Counter()
        batches = max(1, a.tests // 150)
        ok = True
        for b in range(batches):
            tests = make_tests(a.seed * 100 + b, min(150, a.tests))
            lines, err = run_rtl(tests, f"run{b}")
            if lines is None:
                print("  RTL run failed:", err)
                return 1
            mism, cov = compare(tests, lines)
            total_cov.update(cov)
            print(f"  batch {b}: {len(tests)} programs x {CYC} clocks: {len(mism)} mismatching programs")
            for t, cyc, diff, prev in mism[:5]:
                print(f"    program {t} clock {cyc} (after {prev}): " + "; ".join(diff[:4]))
            ok &= not mism
        ok &= coverage_report(total_cov)
        rc |= 0 if ok else 1
    if "mutants" in a.phases:
        rc |= mutants_phase(a.seed, 300)
    print("RESULT isa_diff_test:", "PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    sys.exit(main())
