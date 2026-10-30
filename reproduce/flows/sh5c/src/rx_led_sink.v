// Drains a first-word-fall-through rx_fifo: pops every word as soon as it appears
// and latches its byte onto led. LSB-first 8-bit receive leaves the byte in ISR[31:24].
module rx_led_sink (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rx_empty,
    input  wire [31:0] rx_rd_data,
    output wire        rx_rd_en,
    output reg  [7:0]  led
);
    assign rx_rd_en = !rx_empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)         led <= 8'h00;
        else if (!rx_empty) led <= rx_rd_data[31:24];
    end
endmodule
