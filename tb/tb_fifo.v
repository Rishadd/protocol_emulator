`timescale 1ns/1ps
`include "tb_common.vh"
module tb_fifo;
    // waveform: run vvp with +dump to write build/wave/tb_fifo.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_fifo.vcd"); $dumpvars(0, tb_fifo); end
    reg         clk = 0, rst_n = 0, wr_en = 0, rd_en = 0;
    reg  [31:0] wr_data = 0;
    wire [31:0] rd_data;
    wire        full, empty;
    integer errors = 0, i;

    fifo #(.WIDTH(32), .DEPTH(4)) dut (
        .clk(clk), .rst_n(rst_n), .wr_en(wr_en), .wr_data(wr_data), .full(full),
        .rd_en(rd_en), .rd_data(rd_data), .empty(empty));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    initial begin
        tick; tick; rst_n = 1;
        `CHECK(empty == 1 && full == 0, "A4 reset empty")

        // fill 4, 5th write rejected
        for (i = 1; i <= 4; i = i + 1) begin
            wr_en = 1; wr_data = i; tick; wr_en = 0;
            `CHECK(empty == 0, "A4 not empty after write")
            `CHECK(rd_data == 1, "A4 head stays first word")
        end
        `CHECK(full == 1, "A4 full after 4 writes")
        wr_en = 1; wr_data = 99; tick; wr_en = 0;
        `CHECK(full == 1, "A4 5th write rejected, still full")

        // drain 4 in order, 5th read rejected
        for (i = 1; i <= 4; i = i + 1) begin
            `CHECK(rd_data == i, "A4 read order")
            `CHECK(empty == 0, "A4 not empty during drain")
            rd_en = 1; tick; rd_en = 0;
        end
        `CHECK(empty == 1 && full == 0, "A4 empty after drain")
        rd_en = 1; tick; rd_en = 0;
        `CHECK(empty == 1, "A4 read on empty rejected")

        // simultaneous rd/wr at count 1, wrapping pointers 3 times
        wr_en = 1; wr_data = 10; tick; wr_en = 0;
        for (i = 0; i < 12; i = i + 1) begin
            `CHECK(rd_data == 10 + i, "A4 simultaneous rd/wr order")
            wr_en = 1; rd_en = 1; wr_data = 11 + i; tick; wr_en = 0; rd_en = 0;
            `CHECK(dut.count == 1, "A4 count stays 1 on simultaneous")
        end
        `CHECK(rd_data == 22, "A4 final head after wrap")

        // simultaneous at count 3
        wr_en = 1; wr_data = 100; tick; wr_data = 101; tick; wr_en = 0;
        `CHECK(dut.count == 3, "A4 count 3")
        wr_en = 1; rd_en = 1; wr_data = 102; tick; wr_en = 0; rd_en = 0;
        `CHECK(dut.count == 3 && rd_data == 100, "A4 simultaneous at count 3")
        rd_en = 1; tick; `CHECK(rd_data == 101, "A4 order 101")
        tick;            `CHECK(rd_data == 102, "A4 order 102")
        tick; rd_en = 0; `CHECK(empty == 1, "A4 drained")

        `REPORT("tb_fifo")
        $finish;
    end
endmodule
