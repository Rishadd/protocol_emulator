`timescale 1ns/1ps
`include "tb_common.vh"
module tb_pc_reg;
    // waveform: run vvp with +dump to write build/wave/tb_pc_reg.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_pc_reg.vcd"); $dumpvars(0, tb_pc_reg); end
    reg        clk = 0, rst_n = 0, advance = 0, jump = 0;
    reg  [7:0] jump_addr = 0;
    wire [7:0] pc, next_pc;
    integer errors = 0, i;
    reg [7:0] nxt;

    pc_reg dut (.clk(clk), .rst_n(rst_n), .advance(advance), .jump(jump),
                .jump_addr(jump_addr), .start(8'd0), .pc(pc), .next_pc(next_pc));

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


        // next_pc: the value pc takes at the coming edge (it addresses the synchronous imem)
        $display("--- A2 next_pc predicts pc");
        jump = 0; advance = 0; jump_addr = 0; #1;
        `CHECK(next_pc == pc, "A2 hold: next_pc == pc")
        advance = 1; #1;
        `CHECK(next_pc == pc + 8'd1, "A2 advance: next_pc == pc+1")
        jump = 1; jump_addr = 8'd42; #1;
        `CHECK(next_pc == 8'd42, "A2 jump beats advance in next_pc")
        tick;
        `CHECK(pc == 8'd42, "A2 pc took the predicted value")
        jump = 0; advance = 0; jump_addr = 0;
        for (i = 0; i < 40; i = i + 1) begin
            advance = i[0] | i[2]; jump = (i % 7) == 3; jump_addr = (i * 11) & 63; #1;
            nxt = next_pc; tick;
            `CHECK(pc == nxt, "A2 sweep: pc == next_pc sampled before the edge")
        end
        advance = 0; jump = 0;
        $display("--- A3 reset: next_pc is 0 while rst_n=0 even with advance/jump asserted");
        advance = 1; jump = 1; jump_addr = 8'd9; rst_n = 0; #1;
        `CHECK(pc == 0,      "A3 async reset clears pc")
        `CHECK(next_pc == 0, "A3 next_pc forced 0 in reset")
        advance = 0; jump = 0; rst_n = 1; tick;
        `CHECK(pc == 0, "A3 pc still 0 after release with no control")
        `REPORT("tb_pc_reg")
        $finish;
    end
endmodule
