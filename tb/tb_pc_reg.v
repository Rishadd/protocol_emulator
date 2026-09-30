`timescale 1ns/1ps
`include "tb_common.vh"
module tb_pc_reg;
    reg        clk = 0, rst_n = 0, advance = 0, jump = 0;
    reg  [5:0] jump_addr = 0;
    wire [5:0] pc;
    integer errors = 0, i;

    pc_reg dut (.clk(clk), .rst_n(rst_n), .advance(advance), .jump(jump),
                .jump_addr(jump_addr), .pc(pc));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    initial begin
        tick; tick; rst_n = 1;
        `CHECK(pc == 0, "A1 reset pc=0")

        advance = 1; for (i = 0; i < 10; i = i + 1) tick; advance = 0;
        `CHECK(pc == 10, "A1 10 advances -> 10")

        jump = 1; jump_addr = 37; tick; jump = 0;
        `CHECK(pc == 37, "A1 jump 37")

        advance = 1; tick; advance = 0;
        `CHECK(pc == 38, "A1 advance after jump")

        jump = 1; advance = 1; jump_addr = 5; tick; jump = 0; advance = 0;
        `CHECK(pc == 5, "A1 jump wins over advance")

        tick;
        `CHECK(pc == 5, "A1 hold with no control")

        `REPORT("tb_pc_reg")
        $finish;
    end
endmodule
