`timescale 1ns/1ps
`include "tb_common.vh"
// rx_led_sink + real fifo: every pushed word must appear on led (byte = [31:24]) in order.
module tb_rx_led_sink;
    // waveform: run vvp with +dump to write build/wave/tb_rx_led_sink.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_rx_led_sink.vcd"); $dumpvars(0, tb_rx_led_sink); end
    integer errors = 0;
    reg clk = 0, rst_n = 0, wr_en = 0;
    reg [31:0] wr_data = 0;
    wire full, empty, rd_en;
    wire [31:0] rd_data;
    wire [7:0] led;

    fifo f (.clk(clk), .rst_n(rst_n), .wr_en(wr_en), .wr_data(wr_data), .full(full),
            .rd_en(rd_en), .rd_data(rd_data), .empty(empty));
    rx_led_sink dut (.clk(clk), .rst_n(rst_n), .rx_empty(empty), .rx_rd_data(rd_data),
                     .rx_rd_en(rd_en), .led(led));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask
    task push(input [31:0] w); begin wr_en = 1; wr_data = w; tick; wr_en = 0; end endtask

    reg [7:0] seen [0:15];
    integer ns = 0;
    reg [7:0] last = 8'h00;
    always @(negedge clk) if (rst_n && led !== last) begin seen[ns] = led; ns = ns + 1; last = led; end

    initial begin
        tick; tick;
        `CHECK(led === 8'h00, "led 0 in reset")
        rst_n = 1; tick; tick;
        `CHECK(led === 8'h00 && rd_en === 1'b0, "idle: led holds, no pop while empty")

        push(32'hA5000000); repeat (3) tick;
        `CHECK(led === 8'hA5 && empty === 1'b1, "single word popped, byte from [31:24]")

        push(32'h5A12_3456); repeat (3) tick;
        `CHECK(led === 8'h5A, "low 24 bits ignored")

        // back-to-back burst of 4 (fifo depth): all must show up in order
        ns = 0; last = led;
        push(32'h01000000); push(32'h02000000); push(32'h04000000); push(32'h08000000);
        repeat (4) tick;
        `CHECK(ns == 4 && seen[0] === 8'h01 && seen[1] === 8'h02 && seen[2] === 8'h04 && seen[3] === 8'h08,
               "burst of 4 seen in order")
        `CHECK(empty === 1'b1, "fifo drained")

        push(32'h00000000); repeat (3) tick;
        `CHECK(led === 8'h00, "0x00 byte shows")
        push(32'hFF000000); repeat (3) tick;
        `CHECK(led === 8'hFF, "0xFF byte shows")

        rst_n = 0; tick;
        `CHECK(led === 8'h00, "reset clears led")
        `REPORT("tb_rx_led_sink")
        $finish;
    end
endmodule
