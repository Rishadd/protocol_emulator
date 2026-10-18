#!/usr/bin/env python3
"""Mutation check of the formal proofs: every planted bug must make its proof FAIL (a proof that still passes on a broken design
proves nothing). Runs in WSL: python3 formal/formal_mutants.py [proof name ...]
Each mutant: (proof, source file, original text, replacement, description); the original text must occur exactly once."""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "src")
WORK = os.path.expanduser("~/formal_work/mutants")

MUTANTS = [
    ("pin_mgr", "pin_mgr.v", "wire [7:0] oe_sel  = (own0 & oe0)  | (own1 & oe1);", "wire [7:0] oe_sel  = (own0 & oe0)  | oe1;",
     "a non-owner's enable reaches the pad"),
    ("pin_mgr", "pin_mgr.v", "assign pad_out = out_sel & ~od;", "assign pad_out = out_sel;", "an open-drain pad is driven high"),
    ("pin_mgr", "pin_mgr.v", " && !(cur == 2'd1 && run[0])", "", "a pad owned by running engine 0 can be reclaimed"),
    ("pin_mgr", "pin_mgr.v", "(cfg_data[1:0] != 2'd3) && ", "", "the reserved owner code 3 is accepted"),
    ("pin_mgr", "pin_mgr.v", "viol <= (viol & ~viol_clr) | {oe1 & ~own1 & {8{run[1]}}, oe0 & ~own0 & {8{run[0]}}};",
     "viol <= (viol | {oe1 & ~own1 & {8{run[1]}}, oe0 & ~own0 & {8{run[0]}}}) & ~viol_clr;", "a clear wins over a new violation"),
    ("pin_mgr", "pin_mgr.v", "            owner <= 16'd0;", "            owner <= 16'h0001;", "reset leaves pad 0 owned by engine 0"),
    ("fifo", "fifo.v", "wire do_wr = wr_en && !full;", "wire do_wr = wr_en;", "a write when full is accepted (overwrites a word)"),
    ("fifo", "fifo.v", "wire do_rd = rd_en && !empty;", "wire do_rd = rd_en;", "a read when empty moves the pointer"),
    ("fifo", "fifo.v", "2'b10:   count <= count + 1'b1;", "2'b10, 2'b11: count <= count + 1'b1;", "simultaneous read and write counts as a write"),
    ("fifo", "fifo.v", "rd_ptr <= (rd_ptr == DEPTH-1) ? {AW{1'b0}} : rd_ptr + 1'b1;",
     "rd_ptr <= (rd_ptr == DEPTH-2) ? {AW{1'b0}} : rd_ptr + 1'b1;", "read pointer wraps one word early"),
    ("fifo", "fifo.v", "assign full    = (count == DEPTH);", "assign full    = (count == DEPTH-1);", "full one word early"),
    ("fifo", "fifo.v", "assign rd_data = mem[rd_ptr];", "assign rd_data = mem[wr_ptr];", "output taken from the write pointer"),
    ("mgmt", "mgmt.v", "&& hit_pad && pad_ok &&", "&& hit_pad &&", "a pin claim is applied without the pin manager's consent"),
    ("mgmt", "mgmt.v", "hit_imem && !eng_run[eng]", "hit_imem", "instruction memory written while the engine runs"),
    ("mgmt", "mgmt.v", "wire len_ok   = (nbytes == 4'd7) && frame_clean;", "wire len_ok   = (nbytes == 4'd7);",
     "a frame with a partial byte commits"),
    ("mgmt", "mgmt.v", "wire len_ok   = (nbytes == 4'd7) && frame_clean;", "wire len_ok   = (nbytes >= 4'd6) && frame_clean;",
     "a 6-byte frame commits"),
    ("mgmt", "mgmt.v", "            if (frame_end) begin", "            if (frame_end || (byte_valid && nbytes == 4'd7)) begin",
     "commits on the 7th byte instead of at CS_N rising"),
    ("engine", "engine_top.v", "wire        core_rst_n = rst_n & run;", "wire        core_rst_n = rst_n;", "run does not hold the engine core"),
    ("engine", "engine_top.v", "    pin_block pins (\n        .clk         (clk),\n        .rst_n       (core_rst_n),",
     "    pin_block pins (\n        .clk         (clk),\n        .rst_n       (rst_n),", "the pin block is not reset when the engine is held"),
    ("engine", "pin_block.v", "            pin_oe  <= 8'h00;", "            pin_oe  <= 8'h01;", "reset leaves pin 0 enabled"),
]


def main():
    only = set(sys.argv[1:])
    caught = total = bad = 0
    for i, (proof, fname, old, new, desc) in enumerate(MUTANTS):
        if only and proof not in only:
            continue
        total += 1
        text = open(os.path.join(SRC, fname)).read()
        if text.count(old) != 1:
            print(f"  MUTANT {i:2d} INVALID ({text.count(old)} matches): {desc}")
            bad += 1
            continue
        d = os.path.join(WORK, f"m{i}")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(SRC, d)
        open(os.path.join(d, fname), "w").write(text.replace(old, new))
        r = subprocess.run(["bash", os.path.join(HERE, "run_formal_wsl.sh"), proof + ".sby"], capture_output=True, text=True,
                           env=dict(os.environ, SRC_DIR=d, FORMAL_WORK=os.path.join(WORK, f"w{i}")))
        hit = f"FAIL {proof}" in r.stdout
        caught += hit
        print(f"  MUTANT {i:2d} {'caught ' if hit else 'MISSED '} [{proof}] {desc}")
    print(f"  formal mutants caught: {caught}/{total}" + (f" ({bad} invalid)" if bad else ""))
    return 0 if caught == total and not bad else 1


if __name__ == "__main__":
    sys.exit(main())
