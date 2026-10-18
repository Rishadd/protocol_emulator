`timescale 1ns/1ps
`include "tb_common.vh"
// alu_unit: register file, every ALU function, flags, LDI, RGET, strobe isolation.
// The reference (ref_op) is written differently from the RTL: 64-bit arithmetic, iterative one-bit shifts, loops for parity and
// bit reversal, an unsigned compare for the no-borrow flag. After every operation all 8 registers and the 3 flags are compared with a
// shadow copy kept by the testbench. A directed section pins down the edge cases; a random section runs thousands of operations.
module tb_alu_unit;
    reg         clk = 0, rst_n = 0;
    reg  [26:0] operand = 0;
    reg         do_alu = 0, do_ldi = 0, do_rget = 0;
    reg  [31:0] rget_data = 0;
    wire [31:0] rs_val;
    wire        rs_zero, fz, fn, fc;
    integer errors = 0, i, k, t;

    alu_unit dut (.clk(clk), .rst_n(rst_n), .operand(operand), .do_alu(do_alu), .do_ldi(do_ldi),
                  .do_rget(do_rget), .rget_data(rget_data), .rs_val(rs_val), .rs_zero(rs_zero),
                  .flag_z(fz), .flag_n(fn), .flag_c(fc));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    // shadow state
    reg [31:0] sh [0:7];
    reg        sz, sn, sc;

    // ---- independent reference
    reg [31:0] r_res;
    reg        r_c, r_cupd, r_wr;
    task ref_alu(input [3:0] func, input [31:0] a, input [31:0] src, input oldc);
        reg [63:0] A, S, R;
        integer q, n;
        reg x;
        begin
            A = {32'd0, a}; S = {32'd0, src};
            r_c = oldc; r_cupd = 0; r_wr = 1;
            case (func)
                0:  r_res = src;
                1:  begin R = A + S; r_res = R[31:0]; r_c = R[32]; r_cupd = 1; end
                2:  begin R = A - S; r_res = R[31:0]; r_c = (a >= src); r_cupd = 1; end
                3:  r_res = a & src;
                4:  r_res = a | src;
                5:  r_res = a ^ src;
                6:  begin r_res = a; n = src[4:0];
                          for (q = 0; q < n; q = q + 1) begin r_c = r_res[31]; r_res = {r_res[30:0], 1'b0}; r_cupd = 1; end end
                7:  begin r_res = a; n = src[4:0];
                          for (q = 0; q < n; q = q + 1) begin r_c = r_res[0]; r_res = {1'b0, r_res[31:1]}; r_cupd = 1; end end
                8:  begin R = A - S; r_res = R[31:0]; r_c = (a >= src); r_cupd = 1; r_wr = 0; end
                9:  begin r_res = a & src; r_wr = 0; end
                10: r_res = ~src;
                11: begin x = 0; for (q = 0; q < 32; q = q + 1) x = x ^ src[q]; r_res = {31'd0, x}; end
                12: begin r_res = 0; for (q = 0; q < 8; q = q + 1) r_res[q] = src[7 - q]; end
                default: begin r_res = 0; r_wr = 0; end
            endcase
        end
    endtask

    // ---- operations (one clock each, shadow updated alongside)
    task op_alu(input [3:0] func, input [2:0] rd, input [2:0] rs, input useimm, input [15:0] imm);
        reg [31:0] src;
        begin
            operand = {func, rd, rs, useimm, imm};
            src = useimm ? {16'd0, imm} : sh[rs];
            ref_alu(func, sh[rd], src, sc);
            do_alu = 1; tick; do_alu = 0;
            if (r_wr) sh[rd] = r_res;
            sz = (r_res == 0); sn = r_res[31];
            if (r_cupd) sc = r_c;
        end
    endtask
    task op_ldi(input [2:0] rd, input [23:0] imm);
        begin operand = {rd, imm}; do_ldi = 1; tick; do_ldi = 0; sh[rd] = {8'd0, imm}; end
    endtask
    task op_rget(input [2:0] rd, input [31:0] data);
        begin operand = {24'd0, rd}; rget_data = data; do_rget = 1; tick; do_rget = 0; sh[rd] = data; end
    endtask
    // load a full 32-bit value into a register (RGET path)
    task load32(input [2:0] rd, input [31:0] v); begin op_rget(rd, v); end endtask

    // ---- compare everything with the shadow
    task check_all(input [255:0] tag);
        integer q;
        begin
            for (q = 0; q < 8; q = q + 1) begin
                operand = {24'd0, q[2:0]}; #1;
                if (rs_val !== sh[q] || rs_zero !== (sh[q][26:0] == 0)) begin
                    errors = errors + 1;
                    if (errors < 10) $display("  FAIL %0s: R%0d = %h (zero=%b) want %h", tag, q, rs_val, rs_zero, sh[q]);
                end
            end
            if (fz !== sz || fn !== sn || fc !== sc) begin
                errors = errors + 1;
                if (errors < 10) $display("  FAIL %0s: flags ZNC = %b%b%b want %b%b%b", tag, fz, fn, fc, sz, sn, sc);
            end
        end
    endtask

    reg [31:0] rnd = 32'hC0FF_EE11;
    function [31:0] nr(input [31:0] s); begin nr = s * 32'd1664525 + 32'd1013904223; end endfunction
    function [31:0] pick(input [31:0] r);       // biased toward edge values
        case (r[27:25])
            0: pick = 32'h0000_0000;
            1: pick = 32'hFFFF_FFFF;
            2: pick = 32'h8000_0000;
            3: pick = 32'h7FFF_FFFF;
            4: pick = 32'h0000_0001;
            default: pick = r * 32'd2654435761 + r[7:0];
        endcase
    endfunction

    reg [3:0] f;
    reg [2:0] d, s;
    reg ui;
    initial begin
        for (i = 0; i < 8; i = i + 1) sh[i] = 0;
        sz = 0; sn = 0; sc = 0;
        tick; tick; rst_n = 1; tick;
        check_all("reset: registers and flags clear");

        // LDI: zero extension, only the addressed register changes, flags untouched
        for (i = 0; i < 8; i = i + 1) op_ldi(i[2:0], 24'h80_0000 | (i * 24'h11_1111));
        check_all("LDI every register");
        op_ldi(3, 24'hFF_FFFF);
        `CHECK(dut.r[3] === 32'h00FF_FFFF, "LDI zero-extends (24 bit)")
        check_all("LDI 0xFFFFFF");

        // RGET: 32-bit write, flags untouched
        for (i = 0; i < 8; i = i + 1) op_rget(i[2:0], 32'hA000_0000 + i * 32'h0101_0101);
        check_all("RGET every register");

        // no strobe: nothing changes whatever the operand/data
        operand = 27'h7FF_FFFF; rget_data = 32'hDEAD_BEEF; tick; tick;
        check_all("idle: operand/data changes without a strobe");

        // directed ALU edge cases
        load32(0, 32'hFFFF_FFFF); load32(1, 32'h0000_0001);
        op_alu(1, 0, 1, 0, 0);   check_all("ADD carry out (FFFFFFFF+1)");
        `CHECK(sh[0] === 0 && sz === 1 && sc === 1 && sn === 0, "ADD wraps to 0 with Z and C (model)")
        load32(0, 32'h8000_0000); load32(1, 32'h8000_0000);
        op_alu(1, 0, 1, 0, 0);   check_all("ADD 8..+8.. = 0 carry");
        load32(0, 5); op_alu(2, 0, 0, 1, 7);  check_all("SUB 5-7 borrow (C=0)");
        `CHECK(sc === 0 && sn === 1, "SUB 5-7: C=0 (borrow), N=1")
        load32(0, 7); op_alu(2, 0, 0, 1, 7);  check_all("SUB 7-7");
        `CHECK(sc === 1 && sz === 1, "SUB 7-7: Z=1, C=1 (no borrow)")
        load32(0, 9); load32(1, 4); op_alu(8, 0, 1, 0, 0); check_all("CMP 9,4");
        `CHECK(sh[0] === 9 && sc === 1 && sz === 0, "CMP does not write, C=1 for a>=b")
        op_alu(9, 0, 0, 1, 16'h0006);  check_all("TST 9 & 6");
        `CHECK(sh[0] === 9 && sz === 1, "TST does not write, Z set when no common bits")
        load32(0, 32'h0000_0001); op_alu(6, 0, 0, 1, 31); check_all("SHL 1<<31");
        `CHECK(sh[0] === 32'h8000_0000 && sc === 0 && sn === 1, "SHL by 31: C = bit 1 shifted out (0)")
        load32(0, 32'h8000_0001); load32(2, 0); op_alu(6, 0, 2, 0, 0); check_all("SHL by 0 leaves C");
        op_alu(6, 0, 0, 1, 1);    check_all("SHL by 1 sets C from bit 31");
        `CHECK(sc === 1, "SHL by 1: C = old bit 31 = 1")
        load32(0, 32'h0000_0003); op_alu(7, 0, 0, 1, 1); check_all("SHR by 1");
        `CHECK(sh[0] === 1 && sc === 1, "SHR by 1: C = old bit 0")
        load32(0, 32'h1234_5678); load32(1, 32'hFFFF_FFE4);
        op_alu(7, 0, 1, 0, 0);    check_all("SHR by register[4:0] (=4)");
        `CHECK(sh[0] === 32'h0123_4567, "SHR uses only src[4:0]")
        load32(1, 32'h0000_00B1); op_alu(12, 2, 1, 0, 0); check_all("REV8");
        `CHECK(sh[2] === 32'h0000_008D, "REV8 of 0xB1 = 0x8D, upper bits zero")
        load32(1, 32'hFFFF_FFB1); op_alu(12, 2, 1, 0, 0); check_all("REV8 ignores bits above 7");
        `CHECK(sh[2] === 32'h0000_008D, "REV8 uses only the low byte")
        load32(1, 32'h0000_0007); op_alu(11, 2, 1, 0, 0); check_all("PAR 3 ones");
        `CHECK(sh[2] === 1, "PAR of 0b111 = 1")
        load32(1, 32'h8000_0001); op_alu(11, 2, 1, 0, 0); check_all("PAR 2 ones");
        `CHECK(sh[2] === 0 && sz === 1, "PAR of two ones = 0 with Z")
        load32(1, 32'h00FF_00FF); op_alu(10, 2, 1, 0, 0); check_all("NOT");
        `CHECK(sh[2] === 32'hFF00_FF00, "NOT of src (not of the destination)")
        // rs_zero looks at the 27-bit WAITR delay field only (a register like 0xE8000000 is a zero delay)
        load32(6, 32'hE800_0000); operand = {24'd0, 3'd6}; #1;
        `CHECK(rs_zero === 1'b1, "rs_zero ignores bits above 26 (WAITR delay is 27 bits)")
        load32(6, 32'h0000_0001); operand = {24'd0, 3'd6}; #1;
        `CHECK(rs_zero === 1'b0, "rs_zero = 0 for a nonzero delay")
        // the two read ports are independent: rs_val follows operand[2:0], the ALU source operand[19:17]
        load32(1, 32'h1111_1111); load32(2, 32'h2222_2222); load32(3, 0);
        operand = {4'd0, 3'd3, 3'd2, 1'b0, 13'd0, 3'd1}; #1;           // MOV r3, r2 with operand[2:0] = 1
        `CHECK(rs_val === 32'h1111_1111, "rs_val reads operand[2:0] even inside an ALU word")
        op_alu(0, 3, 2, 0, 16'h0001); check_all("MOV r3,r2 with operand[2:0] = 1");
        `CHECK(sh[3] === 32'h2222_2222, "ALU source is operand[19:17], not operand[2:0]")
        // rd == rs (reads before the edge)
        load32(4, 32'h0000_0010); op_alu(1, 4, 4, 0, 0); check_all("ADD r,r doubles");
        `CHECK(sh[4] === 32'h20, "ADD r4,r4 = 0x20")
        // immediate is zero-extended, not sign-extended
        load32(5, 0); op_alu(0, 5, 0, 1, 16'hFFFF); check_all("MOV imm16 0xFFFF");
        `CHECK(sh[5] === 32'h0000_FFFF, "imm16 zero-extended")

        // random: thousands of operations, all registers and flags checked every time
        for (t = 0; t < 12000; t = t + 1) begin
            rnd = nr(rnd);
            case (rnd[31:29])
                0: begin rnd = nr(rnd); op_ldi(rnd[26:24], rnd[23:0]); end
                1: begin rnd = nr(rnd); op_rget(rnd[26:24], pick(nr(rnd))); end
                default: begin
                    rnd = nr(rnd); f = rnd[27:24]; if (f > 12) f = f - 3;
                    d = rnd[22:20]; s = rnd[19:17]; ui = rnd[16];
                    op_alu(f, d, s, ui, rnd[15:0] ^ (rnd[3] ? 16'hFFFF : 16'h0));
                end
            endcase
            check_all("random");
        end

        // asynchronous reset clears registers and flags
        rst_n = 0; #1; rst_n = 0; tick; rst_n = 1; tick;
        for (i = 0; i < 8; i = i + 1) sh[i] = 0;
        sz = 0; sn = 0; sc = 0;
        check_all("reset clears all state");

        `REPORT("tb_alu_unit")
        $finish;
    end
endmodule
