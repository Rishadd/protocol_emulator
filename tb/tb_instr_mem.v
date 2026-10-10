`timescale 1ns/1ps
`include "tb_common.vh"
// instr_mem: synchronous write port, combinational read port.
module tb_instr_mem;
    reg         clk = 0, we = 0;
    reg  [5:0]  addr = 0, waddr = 0;
    reg  [31:0] wdata = 0;
    wire [31:0] instr;

    reg  [5:0]  addr_i = 0;
    reg         we_i = 0;
    reg  [5:0]  waddr_i = 0;
    reg  [31:0] wdata_i = 0;
    wire [31:0] instr_i;

    integer errors = 0, k;
    reg [31:0] model [0:63];

    instr_mem dut (.clk(clk), .addr(addr), .instr(instr),
                   .we(we), .waddr(waddr), .wdata(wdata));
    // same module with a preloaded image (FPGA/simulation init path must keep working)
    instr_mem #(.INIT_FILE("src/fpga/uart_tx_prog.hex")) dut_init (
        .clk(clk), .addr(addr_i), .instr(instr_i),
        .we(we_i), .waddr(waddr_i), .wdata(wdata_i));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    function [31:0] pat(input [5:0] a, input [7:0] salt);
        pat = {salt, 2'b10, a, ~a, 2'b01, a, salt ^ {2'b0, a}};
    endfunction

    task write(input [5:0] a, input [31:0] d);
        begin we = 1; waddr = a; wdata = d; tick; we = 0; model[a] = d; end
    endtask

    task check_all(input [8*24-1:0] tag);
        integer j;
        begin
            for (j = 0; j < 64; j = j + 1) begin
                addr = j; #1;
                `CHECK(instr == model[j], tag)
            end
        end
    endtask

    initial begin
        $display("--- M1 write all 64 words, read back");
        for (k = 0; k < 64; k = k + 1) write(k, pat(k, 8'hA5));
        check_all("readback after fill");

        $display("--- M2 we=0 does not write");
        we = 0; waddr = 6'd17; wdata = 32'hDEADBEEF; tick; tick;
        check_all("we=0 ignored");

        $display("--- M3 single overwrite disturbs no other word");
        write(6'd0,  32'hFFFF_FFFF);
        write(6'd63, 32'h0000_0000);
        write(6'd31, 32'h1234_5678);
        check_all("isolation");

        $display("--- M4 read-during-write: old word until the edge, new word after");
        addr = 6'd5; #1;
        `CHECK(instr == model[5], "before write")
        @(negedge clk); we = 1; waddr = 6'd5; wdata = 32'hCAFE_0005; #1;
        `CHECK(instr == model[5], "write pending, read still old")
        @(posedge clk); #1; we = 0; model[5] = 32'hCAFE_0005;
        `CHECK(instr == 32'hCAFE_0005, "new word visible right after the edge")

        $display("--- M5 back-to-back writes, one per cycle");
        @(negedge clk); we = 1;
        for (k = 0; k < 64; k = k + 1) begin
            waddr = 63 - k; wdata = pat(63 - k, 8'h3C); model[63 - k] = wdata;
            @(negedge clk);
        end
        we = 0;
        check_all("back-to-back");

        $display("--- M6 INIT_FILE image readable, then overwritable");
        addr_i = 6'd3; #1;
        `CHECK(instr_i == 32'h3000_0000, "init word 3 = PULL")
        addr_i = 6'd0; #1;
        `CHECK(instr_i == 32'h8000_0000, "init word 0 = CFG 0")
        @(negedge clk); we_i = 1; waddr_i = 6'd3; wdata_i = 32'h1800_0000; @(negedge clk); we_i = 0;
        addr_i = 6'd3; #1;
        `CHECK(instr_i == 32'h1800_0000, "init word 3 overwritten with HALT")
        addr_i = 6'd2; #1;
        `CHECK(instr_i == 32'h6000_0000, "init word 2 untouched (DIRO 0)")

        `REPORT("tb_instr_mem")
        $finish;
    end
endmodule
