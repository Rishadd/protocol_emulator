`timescale 1ns/1ps
`include "tb_common.vh"
// Two-tier plan V3.4: the L2 arbiter (src/l2_mem.v) against the reference arbiter (tb/arb_model.vh),
// exhaustively: host {0,1} x request {00,01,10,11} x class {00,01,10,11} x policy {RR, e0, e1}
// x round-robin pointer {0,1} = 192 combinations. For each: the grant, the address the macro reads
// (the memory holds address-in-data, so rdata one clock later proves it) and the pointer update.
module tb_arb;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    reg        h_we = 0, h_re = 0;
    reg [7:0]  h_addr = 0;
    reg [31:0] h_wdata = 0;
    reg [1:0]  req = 0, hi = 0, pol = 0;
    reg [15:0] ra = 0;
    wire [1:0] gnt;
    wire [31:0] rdata;
    `include "arb_model.vh"

    l2_mem dut (.clk(clk), .rst_n(rst_n), .h_we(h_we), .h_re(h_re), .h_addr(h_addr), .h_wdata(h_wdata),
                .req(req), .req_hi(hi), .req_addr(ra), .policy(pol), .gnt(gnt), .rdata(rdata));

    integer errors = 0, n = 0, i, hst, r, c, p, l;
    reg [1:0] exp;
    reg last;

    task tick; begin @(posedge clk); #1; end endtask

    initial begin
        tick; rst_n = 1; tick;
        for (i = 0; i < 256; i = i + 1) begin h_we = 1; h_addr = i; h_wdata = 32'hA000_0000 | i; tick; end
        h_we = 0;
        for (hst = 0; hst < 2; hst = hst + 1) for (r = 0; r < 4; r = r + 1) for (c = 0; c < 4; c = c + 1)
        for (p = 0; p < 3; p = p + 1) for (l = 0; l < 2; l = l + 1) begin
            // prime the round-robin pointer: grant engine l alone
            pol = 0; hi = 0; req = 2'b01 << l; ra = 16'h0000; #1;
            `CHECK(gnt == req, "single request is granted")
            tick; last = l;
            // the combination under test; engine 0 asks for word 0x10+r, engine 1 for 0x80+c
            h_re = hst; h_addr = 8'h33; req = r; hi = c; pol = p; ra = {8'h80 + c[7:0], 8'h10 + r[7:0]}; #1;
            exp = arb_ref(hst, req, hi, pol, last);
            `CHECK(gnt === exp, "grant equals the reference arbiter")
            if (gnt !== exp) $display("    host=%0d req=%b hi=%b pol=%0d last=%0d: gnt=%b exp=%b", hst, r, c, p, l, gnt, exp);
            tick; h_re = 0; req = 0;
            // (begin/end: `CHECK is an if statement, so a bare else would bind to it)
            if (hst)         begin `CHECK(rdata === 32'hA000_0033, "host read returns its word") end
            else if (exp[0]) begin `CHECK(rdata === (32'hA000_0010 + r), "engine 0's address reached the macro") end
            else if (exp[1]) begin `CHECK(rdata === (32'hA000_0080 + c), "engine 1's address reached the macro") end
            if (exp != 0) begin `CHECK(dut.last === exp[1], "round-robin pointer = last granted engine") end
            else          begin `CHECK(dut.last === last, "pointer unchanged without an engine grant") end
            n = n + 1;
        end
        // a host write wins over two class-2 requests and stores its word
        h_we = 1; h_addr = 8'h05; h_wdata = 32'h1234_5678; req = 2'b11; hi = 2'b11; #1;
        `CHECK(gnt == 2'b00, "host write blocks both engines")
        tick; h_we = 0; req = 0; h_re = 1; h_addr = 8'h05; tick; h_re = 0;
        `CHECK(rdata === 32'h1234_5678, "host write stored")
        $display("checked %0d combinations", n);
        `CHECK(n == 192, "all 192 combinations")
        `REPORT("tb_arb")
        $finish;
    end
endmodule
