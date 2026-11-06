`timescale 1ns/1ps
`include "tb_common.vh"
module tb_loop_counter;
    // waveform: run vvp with +dump to write build/wave/tb_loop_counter.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_loop_counter.vcd"); $dumpvars(0, tb_loop_counter); end
    reg         clk = 0, rst_n = 0, load = 0, dec = 0;
    reg  [15:0] load_value = 0;
    wire [15:0] count;
    integer errors = 0, i;

    loop_counter dut (.clk(clk), .rst_n(rst_n), .load(load),
                      .load_value(load_value), .dec(dec), .count(count));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    initial begin
        tick; tick; rst_n = 1;
        `CHECK(count == 0, "A3 reset count=0")

        load = 1; load_value = 8; tick; load = 0;
        `CHECK(count == 8, "A3 load 8")

        dec = 1;
        for (i = 7; i >= 0; i = i - 1) begin
            tick;
            `CHECK(count == i, "A3 decrement")
        end
        tick; tick;
        `CHECK(count == 0, "A3 saturates at 0")
        dec = 0;

        load = 1; dec = 1; load_value = 3; tick; load = 0; dec = 0;
        `CHECK(count == 3, "A3 load wins over dec")

        `REPORT("tb_loop_counter")
        $finish;
    end
endmodule
