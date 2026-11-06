`timescale 1ns/1ps
`include "tb_common.vh"
module tb_shift_reg;
    // waveform: run vvp with +dump to write build/wave/tb_shift_reg.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_shift_reg.vcd"); $dumpvars(0, tb_shift_reg); end
    reg         clk = 0, rst_n = 0, msb_first = 0, load = 0, clear = 0;
    reg         shift_out = 0, shift_in = 0, in_bit = 0;
    reg  [31:0] load_value = 0;
    wire [31:0] data;
    wire        out_bit;
    integer errors = 0, i;
    reg  [7:0]  pattern;

    shift_reg #(.WIDTH(32)) dut (
        .clk(clk), .rst_n(rst_n), .msb_first(msb_first), .load(load), .load_value(load_value),
        .clear(clear), .shift_out(shift_out), .shift_in(shift_in), .in_bit(in_bit),
        .data(data), .out_bit(out_bit));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    initial begin
        pattern = 8'hC5; // 1100_0101, not a palindrome so bit order is observable
        tick; tick; rst_n = 1;
        `CHECK(data == 0, "A5 reset data=0")

        // OSR LSB-first: out_bit stream = pattern[0], pattern[1], ...
        msb_first = 0;
        load = 1; load_value = {24'd0, pattern}; tick; load = 0;
        for (i = 0; i < 8; i = i + 1) begin
            `CHECK(out_bit == pattern[i], "A5 LSB-first out_bit")
            shift_out = 1; tick; shift_out = 0;
        end
        `CHECK(data == 0, "A5 LSB-first fully shifted out")

        // OSR MSB-first: byte must sit in [31:24]
        msb_first = 1;
        load = 1; load_value = {pattern, 24'd0}; tick; load = 0;
        for (i = 7; i >= 0; i = i - 1) begin
            `CHECK(out_bit == pattern[i], "A5 MSB-first out_bit")
            shift_out = 1; tick; shift_out = 0;
        end
        `CHECK(data == 0, "A5 MSB-first fully shifted out")

        // ISR LSB-first: bits enter at [31], byte lands in [31:24]
        msb_first = 0;
        for (i = 0; i < 8; i = i + 1) begin
            shift_in = 1; in_bit = pattern[i]; tick; shift_in = 0;
        end
        `CHECK(data == {pattern, 24'd0}, "A5 LSB-first shift_in lands in [31:24]")

        // clear
        clear = 1; tick; clear = 0;
        `CHECK(data == 0, "A5 clear")

        // ISR MSB-first: bits enter at [0], byte lands in [7:0]
        msb_first = 1;
        for (i = 7; i >= 0; i = i - 1) begin
            shift_in = 1; in_bit = pattern[i]; tick; shift_in = 0;
        end
        `CHECK(data == {24'd0, pattern}, "A5 MSB-first shift_in lands in [7:0]")

        // clear beats load
        clear = 1; load = 1; load_value = 32'hFFFFFFFF; tick; clear = 0; load = 0;
        `CHECK(data == 0, "A5 clear has priority over load")

        `REPORT("tb_shift_reg")
        $finish;
    end
endmodule
