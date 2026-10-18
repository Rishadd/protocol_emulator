#!/usr/bin/env python3
"""ALU unit verification: tb/tb_alu_unit.v (directed + 12000 random operations against an independent reference) and mutation testing.
  python host/alu_test.py [run] [mutants]
"""
import os
import sys

import mutation as mut

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DUT = os.path.join(ROOT, "src", "alu_unit.v")
TB = os.path.join(ROOT, "tb", "tb_alu_unit.v")

C_NEW = "wire        c_new = is_as ? addsub[32] : c_oth;"
WR = "wire        wr    = (func != 4'd8) && (func != 4'd9);"
MUTANTS = [
    ("SUB carry polarity inverted", C_NEW, "wire        c_new = is_as ? (sub ? ~addsub[32] : addsub[32]) : c_oth;"),
    ("CMP writes the result back", WR, "wire        wr    = (func != 4'd9);"),
    ("TST writes the result back", WR, "wire        wr    = (func != 4'd8);"),
    ("SHL carry one bit off", "c_oth = a[6'd32 - {1'b0, sh}]", "c_oth = a[6'd31 - {1'b0, sh}]"),
    ("SHR carry one bit off", "c_oth = a[{1'b0, sh} - 6'd1]", "c_oth = a[{1'b0, sh}]"),
    ("N taken from bit 30", "flag_n <= res[31];", "flag_n <= res[30];"),
    ("Z inverted", "flag_z <= (res == 32'd0);", "flag_z <= (res != 32'd0);"),
    ("use_imm ignored", "wire [31:0] src   = use_imm ? {16'd0, operand[15:0]} : alu_b;", "wire [31:0] src   = alu_b;"),
    ("imm16 sign-extended", "{16'd0, operand[15:0]} : alu_b", "{{16{operand[15]}}, operand[15:0]} : alu_b"),
    ("LDI sign-extended", "{8'd0, operand[23:0]}", "{{8{operand[23]}}, operand[23:0]}"),
    ("ALU writes the rs register", "if (wr) r[alu_rd] <= res;", "if (wr) r[operand[19:17]] <= res;"),
    ("ALU source read from operand[2:0]", "wire [31:0] alu_b = r[operand[19:17]];", "wire [31:0] alu_b = r[operand[2:0]];"),
    ("rs_val read from the ALU rs field", "assign rs_val  = r[operand[2:0]];", "assign rs_val  = r[operand[19:17]];"),
    ("parity inverted", "{31'd0, ^src}", "{31'd0, ~^src}"),
    ("REV8 is the identity", "{24'd0, src[0], src[1], src[2], src[3], src[4], src[5], src[6], src[7]}",
     "{24'd0, src[7], src[6], src[5], src[4], src[3], src[2], src[1], src[0]}"),
    ("ADD carry from bit 31", C_NEW, "wire        c_new = is_as ? ((func == 4'd1) ? addsub[31] : addsub[32]) : c_oth;"),
    ("NOT of the destination", "4'd10: other = ~src;", "4'd10: other = ~a;"),
    ("MOV copies the destination", "4'd0:  other = src;", "4'd0:  other = a;"),
    ("shift by 0 updates C", "if (sh != 5'd0) begin c_oth = a[{1'b0, sh} - 6'd1];", "if (1'b1) begin c_oth = a[{1'b0, sh} - 6'd1];"),
    ("LDI also updates Z", "r[operand[26:24]] <= {8'd0, operand[23:0]};", "begin r[operand[26:24]] <= {8'd0, operand[23:0]}; flag_z <= 1'b0; end"),
    ("RGET writes the wrong register", "r[operand[2:0]] <= rget_data;", "r[operand[6:4]] <= rget_data;"),
    ("rs_zero looks at all 32 bits", "assign rs_zero = (rs_val[26:0] == 27'd0);", "assign rs_zero = (rs_val == 32'd0);"),
    ("flags updated by CMP skipped (C)", "wire        c_upd = is_as | c_upd_oth;", "wire        c_upd = (is_as && func != 4'd8) | c_upd_oth;"),
    ("adder result not selected for SUB", "wire        is_as = (func == 4'd1) || sub;", "wire        is_as = (func == 4'd1);"),
    ("SUB does not add the carry-in", "{31'd0, p0[0] & sub}", "{31'd0, 1'b0}"),
    ("SUB does not invert the operand", "wire [31:0] ay     = sub ? ~src : src;", "wire [31:0] ay     = src;"),
    ("CMP is not a subtraction", "wire        sub    = (func == 4'd2) || (func == 4'd8);", "wire        sub    = (func == 4'd2);"),
    ("prefix adder lacks its last level", "wire [31:0] g5     = g4 | (p4 & (g4 << 16));", "wire [31:0] g5     = g4;"),
    ("prefix adder drops a group propagate", "wire [31:0] p2     = p1 & ((p1 << 2)  | 32'h0000_0003);", "wire [31:0] p2     = p1;"),
    ("prefix adder level shifted by the wrong distance", "wire [31:0] g3     = g2 | (p2 & (g2 << 4));", "wire [31:0] g3     = g2 | (p2 & (g2 << 3));"),
]


def runner(srcs, name):
    return mut.run_tb(ROOT, TB, srcs, name)


def main():
    phases = sys.argv[1:] or ["run", "mutants"]
    rc = 0
    if "run" in phases:
        out = runner([DUT], "alu")
        print(" ", out.splitlines()[0])
        if "PASS" not in out:
            print(out)
            rc = 1
    if "mutants" in phases:
        rc |= mut.run(MUTANTS, DUT, runner, ROOT, "alu")
    print("RESULT alu_test:", "PASS" if rc == 0 else "FAIL")
    return rc


if __name__ == "__main__":
    sys.exit(main())
