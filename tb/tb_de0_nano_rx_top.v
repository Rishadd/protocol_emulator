`timescale 1ns/1ps
`include "tb_common.vh"
// Top-level RX check at 50 MHz / 115200: bytes on bt_rx_pin must appear on led[7:0].
module tb_de0_nano_rx_top;
    integer errors = 0;
    reg clk_50M = 0, reset_n = 0, bt_rx_pin = 1;
    wire bt_tx_pin;
    wire [7:0] led;
    localparam BIT = 434 * 20;     // ns

    de0_nano_rx_top dut (.clk_50M(clk_50M), .reset_n(reset_n), .bt_rx_pin(bt_rx_pin),
                         .bt_tx_pin(bt_tx_pin), .led(led));
    always #10 clk_50M = ~clk_50M;

    task send(input [7:0] b);
        integer k;
        begin
            bt_rx_pin = 0; #(BIT);
            for (k = 0; k < 8; k = k + 1) begin bt_rx_pin = b[k]; #(BIT); end
            bt_rx_pin = 1; #(BIT);
        end
    endtask

    task expect_led(input [7:0] b, input [255:0] name);
        begin
            #(BIT);   // led must already be updated well before the next frame
            `CHECK(led === b, name)
        end
    endtask

    initial begin
        #200; reset_n = 1;
        #(20 * BIT);
        `CHECK(led === 8'h00 && bt_tx_pin === 1'b1, "idle after reset: leds off, no phantom byte")
        send(8'h41); expect_led(8'h41, "A");
        send(8'h55); expect_led(8'h55, "0x55");
        send(8'hAA); expect_led(8'hAA, "0xAA");
        send(8'h00); expect_led(8'h00, "0x00");
        send(8'hFF); expect_led(8'hFF, "0xFF");
        send(8'h7A); send(8'h30); expect_led(8'h30, "back-to-back z,0 -> 0");
        `REPORT("tb_de0_nano_rx_top")
        $finish;
    end
endmodule
