`timescale 1ns/1ps
`include "tb_common.vh"
module tb_pin_block;
    reg        clk = 0, rst_n = 0;
    reg        pin_wr = 0, pin_wr_val = 0, dir_wr = 0, dir_wr_val = 0;
    reg  [2:0] pin_wr_idx = 0, dir_wr_idx = 0;
    reg  [7:0] pin_in = 0;
    wire [7:0] pin_out, pin_oe, pin_in_sync;
    integer errors = 0;

    pin_block dut (
        .clk(clk), .rst_n(rst_n),
        .pin_wr(pin_wr), .pin_wr_idx(pin_wr_idx), .pin_wr_val(pin_wr_val),
        .dir_wr(dir_wr), .dir_wr_idx(dir_wr_idx), .dir_wr_val(dir_wr_val),
        .pin_in(pin_in), .pin_out(pin_out), .pin_oe(pin_oe), .pin_in_sync(pin_in_sync));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    initial begin
        tick; tick; rst_n = 1;
        `CHECK(pin_out == 8'h00, "A6 reset out=0")
        `CHECK(pin_oe  == 8'h00, "A6 reset oe=0 (all released)")
        `CHECK(pin_in_sync == 8'h00, "A6 reset sync=0")

        pin_wr = 1; pin_wr_idx = 3; pin_wr_val = 1; tick; pin_wr = 0;
        `CHECK(pin_out == 8'b0000_1000, "A6 write pin3=1")
        pin_wr = 1; pin_wr_idx = 0; pin_wr_val = 1; tick; pin_wr = 0;
        `CHECK(pin_out == 8'b0000_1001, "A6 write pin0=1, pin3 untouched")
        dir_wr = 1; dir_wr_idx = 3; dir_wr_val = 1; tick; dir_wr = 0;
        `CHECK(pin_oe == 8'b0000_1000, "A6 dir pin3=out")
        `CHECK(pin_out == 8'b0000_1001, "A6 dir write leaves out untouched")
        pin_wr = 1; pin_wr_idx = 3; pin_wr_val = 0; tick; pin_wr = 0;
        `CHECK(pin_out == 8'b0000_0001, "A6 write pin3=0")

        // input synchronizer: exactly 2 clocks of latency
        pin_in = 8'hA5; tick;
        `CHECK(pin_in_sync == 8'h00, "A6 sync not yet visible after 1 clk")
        tick;
        `CHECK(pin_in_sync == 8'hA5, "A6 sync visible after 2 clks")
        pin_in = 8'h00; tick;
        `CHECK(pin_in_sync == 8'hA5, "A6 sync fall not yet visible")
        tick;
        `CHECK(pin_in_sync == 8'h00, "A6 sync fall visible after 2 clks")

        `REPORT("tb_pin_block")
        $finish;
    end
endmodule
