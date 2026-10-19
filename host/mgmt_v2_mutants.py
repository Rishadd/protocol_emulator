#!/usr/bin/env python3
"""Planted-bug check of frame v2: every mutant of src/mgmt.v must make host/mgmt_v2_test.py fail (on the RTL through the SPI bridge).
  python3 host/mgmt_v2_mutants.py [first_index]
A mutant that still passes means a hole in the test. (old text, new text, description); the old text must occur exactly once.
"""
import os
import shutil
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))
WORK = os.path.join(ROOT, "build", "v2_mut")

MUTANTS = [
    ("&& frame_clean && (rxcrc == rcrc);", "&& frame_clean;", "the request CRC is not checked"),
    ("localparam [15:0] CRC_INIT = 16'hFFFF;", "localparam [15:0] CRC_INIT = 16'h0000;", "CRC initial value wrong"),
    ("16'h1021) : (x << 1)", "16'h1020) : (x << 1)", "CRC polynomial wrong"),
    ("txcrc <= crc16(txcrc, tx_byte);", "txcrc <= crc16(txcrc, 8'h00);", "the response CRC ignores the response"),
    ("(seq2 == last_seq) && (rcrc == last_crc);", "(seq2 == last_seq) && (rcrc == last_crc) && 1'b0;", "a duplicate frame is executed again"),
    ("show_old <= have_last && (rx_byte == last_seq);", "show_old <= 1'b0;", "a retried frame shows the new result, the older one is lost"),
    ("if (op2 == 8'h80) begin\n                            ;", "if (1'b0) begin\n                            ;", "a NOP replaces the result"),
    ("(seq2 != last_seq) && (seq2 != last_seq + 8'd1);", "1'b0;", "a gap in the numbering is accepted"),
    ("(seq2 == last_seq) && (rcrc != last_crc);", "(seq2 == last_seq) && (rcrc != last_crc) && 1'b0;", "the same number with other content is accepted"),
    ("wire rsv_ok   = (frame[31:16] == 16'd0);", "wire rsv_ok   = 1'b1;", "reserved bytes are not checked"),
    ("wire [31:0] data2 = {frame[39:32], frame[47:40], frame[55:48], frame[63:56]};", "wire [31:0] data2 = {frame[63:56], frame[55:48], frame[47:40], frame[39:32]};",
     "payload byte order wrong"),
    ("else if (id_win)            code = 8'd4;", "else if (id_win)            code = 8'd0;", "a write to a read-only register reports OK"),
    ("code = rx_empty[eng] ? 8'd1 : 8'd0;", "code = 8'd0;", "an empty RX FIFO does not report BUSY"),
    ("if (cnt_crc != 8'hFF) cnt_crc <= cnt_crc + 8'd1;", "", "CRC errors are not counted"),
    ("if (cnt_len != 8'hFF) cnt_len <= cnt_len + 8'd1;", "", "length errors are not counted"),
    ("cnt_crc <= 8'd0; cnt_len <= 8'd0; cnt_seq <= 8'd0;", "cnt_crc <= 8'd0; cnt_len <= 8'd0;", "writing ERRCNT does not clear the sequence counter"),
    ("old_seq <= res_seq; old_code <= res_code; old_addr <= res_addr; old_data <= res_data;", "old_seq <= res_seq; old_code <= res_code; old_addr <= res_addr;",
     "the older result's data is lost"),
    ("res_data <= (go && is_read && code == 8'd0) ? rd_val : 32'd0;", "res_data <= 32'd0;", "read data never reaches the result"),
    ("wire id_win   = (addr[15:5] == 11'd0) && (addr[1:0] == 2'b00);", "wire id_win   = (addr[15:5] == 11'd1) && (addr[1:0] == 2'b00);", "the ID window sits at the wrong address"),
    ("                    end else begin                       // damaged frame: nothing executes, the host sees the old result\n                        err <= 1'b1;",
     "                    end else begin                       // damaged frame: nothing executes, the host sees the old result\n                        ", "a damaged frame does not set the err flag"),
]


def main():
    start = int(sys.argv[1]) if len(sys.argv) > 1 else 0
    src = os.path.join(ROOT, "src")
    text = open(os.path.join(src, "mgmt.v")).read()
    caught = invalid = 0
    total = 0
    for i, (old, new, desc) in enumerate(MUTANTS):
        if i < start:
            continue
        total += 1
        if text.count(old) != 1:
            print(f"  MUTANT {i:2d} INVALID ({text.count(old)} matches): {desc}", flush=True)
            invalid += 1
            continue
        d = os.path.join(WORK, f"m{i}")
        shutil.rmtree(d, ignore_errors=True)
        shutil.copytree(src, d)
        with open(os.path.join(d, "mgmt.v"), "w") as f:
            f.write(text.replace(old, new))
        try:
            r = subprocess.run([sys.executable, os.path.join(HERE, "mgmt_v2_test.py"), "--flips", "30"], capture_output=True, text=True, timeout=900,
                               env=dict(os.environ, PE_SRC_DIR=d))
            failed = "RESULT mgmt_v2_test: PASS" not in r.stdout
        except subprocess.TimeoutExpired:
            failed = True
        caught += failed
        print(f"  MUTANT {i:2d} {'caught ' if failed else 'MISSED '} {desc}", flush=True)
    print(f"frame v2 mutants caught: {caught}/{total - invalid}" + (f" ({invalid} invalid)" if invalid else ""))
    return 0 if caught == total - invalid and not invalid else 1


if __name__ == "__main__":
    sys.exit(main())
