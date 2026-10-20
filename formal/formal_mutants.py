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
    ("pin_mgr", "pin_mgr.v", "|| (o1 && oe1[l]));", "|| oe1[l]);", "a non-owner's enable reaches a pad"),
    ("pin_mgr", "pin_mgr.v", "pad_out_r[p] = out_s && !od[p];", "pad_out_r[p] = out_s;", "an open-drain pad is driven high"),
    ("pin_mgr", "pin_mgr.v", " && !(cur == 2'd1 && run[0])", "", "a pin owned by running engine 0 can be reclaimed"),
    ("pin_mgr", "pin_mgr.v", "(w_data[1:0] != 2'd3) && ", "", "the reserved owner code 3 is accepted"),
    ("pin_mgr", "pin_mgr.v", "viol   <= (viol & ~viol_clr) | {oe1 & ~map1 & {8{run[1]}}, oe0 & ~map0 & {8{run[0]}}};",
     "viol   <= (viol | {oe1 & ~map1 & {8{run[1]}}, oe0 & ~map0 & {8{run[0]}}}) & ~viol_clr;", "a clear wins over a new violation"),
    ("pin_mgr", "pin_mgr.v", "            owner   <= 16'd0;", "            owner   <= 16'h0001;", "reset leaves pad 0 owned by engine 0"),
    ("pin_mgr", "pin_mgr.v", "oe_s  = !hold && ", "oe_s  = ", "HOLD does not release the uio pads"),
    ("pin_mgr", "pin_mgr.v", "uo_r[k-1] = (hold || !(o0 || o1))", "uo_r[k-1] = (!(o0 || o1))", "HOLD does not release the uo_out pins"),
    ("pin_mgr", "pin_mgr.v", "w_data[3:0] <= 4'd12 && !run[w_e]", "w_data[3:0] <= 4'd12", "input select changes under a running engine"),
    ("pin_mgr", "pin_mgr.v", "w_data[3:0] <= 4'd12 && ", "", "input select accepts an out-of-range pin"),
    ("pin_mgr", "pin_mgr.v", "(run == 2'b00 || w_data[2:0] == misc)", "1'b1", "MISC control bits change under a running engine"),
    ("pin_mgr", "pin_mgr.v", "l     = remap[3*p +: 3] ^ p[2:0];", "l     = remap[3*p +: 3];", "remap is not relative to the pin number"),
    ("pin_mgr", "pin_mgr.v", "assign irq      = |(irq_st & mask[7:0]);", "assign irq      = |irq_st;", "IRQ ignores the mask"),
    ("pin_mgr", "pin_mgr.v", "{|viol, irq_src};", "{1'b0, irq_src};", "a violation does not set IRQ status bit 7"),
    ("pin_mgr", "pin_mgr.v", "isel0_r[4*n +: 4] <= n[3:0];", "isel0_r[4*n +: 4] <= 4'd0;", "reset leaves engine 0's input select wrong"),
    ("pin_mgr", "pin_mgr.v", "oe0 & ~map0 & {8{run[0]}}};", "oe0 & ~8'hFF & {8{run[0]}}};", "violations are never flagged for engine 0"),
    ("pin_mgr", "pin_mgr.v", "assign hold     = misc[0] & hold_s[1];", "assign hold     = hold_s[1];", "HOLD acts although disabled"),
    ("pin_mgr", "pin_mgr.v", "assign view_sel = misc[2] ? ui_hi[4:2] : vsel;", "assign view_sel = ui_hi[4:2];", "DBG_SEL release ignored"),
    ("fifo", "fifo.v", "wire do_wr = wr_en && !full;", "wire do_wr = wr_en;", "a write when full is accepted (overwrites a word)"),
    ("fifo", "fifo.v", "wire do_rd = rd_en && !empty;", "wire do_rd = rd_en;", "a read when empty moves the pointer"),
    ("fifo", "fifo.v", "2'b10:   count <= count + 1'b1;", "2'b10, 2'b11: count <= count + 1'b1;", "simultaneous read and write counts as a write"),
    ("fifo", "fifo.v", "rd_ptr <= (rd_ptr == DEPTH-1) ? {AW{1'b0}} : rd_ptr + 1'b1;",
     "rd_ptr <= (rd_ptr == DEPTH-2) ? {AW{1'b0}} : rd_ptr + 1'b1;", "read pointer wraps one word early"),
    ("fifo", "fifo.v", "assign full    = (count == DEPTH);", "assign full    = (count == DEPTH-1);", "full one word early"),
    ("fifo", "fifo.v", "assign rd_data = mem[rd_ptr];", "assign rd_data = mem[wr_ptr];", "output taken from the write pointer"),
    ("mgmt", "mgmt.v", "hit_pin && pin_ok) begin", "hit_pin) begin", "a pin claim is applied without the pin manager's consent"),
    ("mgmt", "mgmt.v", "hit_imem && !eng_run[eng]", "hit_imem", "instruction memory written while the engine runs"),
    ("mgmt", "mgmt.v", "wire v1_ok    = !is_v2 && (nbytes == 4'd7) && frame_clean;", "wire v1_ok    = !is_v2 && (nbytes == 4'd7);",
     "a v1 frame with a partial byte commits"),
    ("mgmt", "mgmt.v", "wire v1_ok    = !is_v2 && (nbytes == 4'd7) && frame_clean;", "wire v1_ok    = !is_v2 && (nbytes >= 4'd6) && frame_clean;",
     "a 6-byte v1 frame commits"),
    ("mgmt", "mgmt.v", "(nbytes == 4'd12) && frame_clean && (rxcrc == rcrc);", "(nbytes == 4'd12) && frame_clean;",
     "a v2 frame commits without the right CRC"),
    ("mgmt", "mgmt.v", "(nbytes == 4'd12) && frame_clean && (rxcrc == rcrc);", "(nbytes >= 4'd11) && frame_clean && (rxcrc == rcrc);",
     "an 11-byte v2 frame commits"),
    ("mgmt", "mgmt.v", "(nbytes == 4'd12) && frame_clean && (rxcrc == rcrc);", "(nbytes == 4'd12) && (rxcrc == rcrc);",
     "a v2 frame with a partial byte commits"),
    ("mgmt", "mgmt.v", "rxcrc <= crc16(rxcrc, rx_byte);", "rxcrc <= crc16(rxcrc, 8'h00);", "the received CRC ignores the received bytes"),
    ("mgmt", "mgmt.v", "16'h1021) : (x << 1)", "16'h1020) : (x << 1)", "the CRC polynomial is wrong"),
    ("mgmt", "mgmt.v", "            if (frame_end) begin", "            if (frame_end || (byte_valid && nbytes == 4'd7)) begin",
     "commits on the 7th byte instead of at CS_N rising"),
    ("mgmt", "mgmt.v", "            if (hold) eng_run <= 2'b00;", "            ", "HOLD does not stop the engines"),
    ("mgmt", "mgmt.v", " && !(hold && data[0])", "", "RUN can be set while HOLD is active"),
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
