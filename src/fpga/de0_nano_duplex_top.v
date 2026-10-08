// DE0-Nano full duplex echo: HC-05 TXD -> RX engine -> led[7:0] + TX engine -> HC-05 RXD.
// A byte leaves rx_fifo only when tx_fifo has room, so the LEDs and the echo always agree.
module de0_nano_duplex_top #(
    parameter TX_PROG = "src/fpga/uart_tx_prog.hex",
    parameter RX_PROG = "src/fpga/uart_rx_prog.hex"
)(
    input  wire       clk_50M,     // PIN_R8
    input  wire       reset_n,     // PIN_J15  KEY0, active low
    input  wire       bt_rx_pin,   // PIN_J13  <- HC-05 TXD
    output wire       bt_tx_pin,   // PIN_J14  -> HC-05 RXD
    output wire [7:0] led
);
    reg [1:0] rst_sync;
    always @(posedge clk_50M or negedge reset_n)
        if (!reset_n) rst_sync <= 2'b00;
        else          rst_sync <= {rst_sync[0], 1'b1};
    wire rst_n = rst_sync[1];

    wire        rx_empty, rx_rd_en, tx_full;
    wire [31:0] rx_rd_data, tx_rd_unused;
    wire [7:0]  tx_out, tx_oe, rx_out, rx_oe;

    engine_top #(.INIT_FILE(RX_PROG)) u_rx (
        .clk(clk_50M), .rst_n(rst_n),
        .tx_wr_en(1'b0), .tx_wr_data(32'd0), .tx_full(),
        .rx_rd_en(rx_rd_en), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in({6'd0, bt_rx_pin, 1'b0}), .pin_out(rx_out), .pin_oe(rx_oe),
        .halted(), .fault(), .pc());

    rx_led_sink u_sink (
        .clk(clk_50M), .rst_n(rst_n), .rx_empty(rx_empty | tx_full),
        .rx_rd_data(rx_rd_data), .rx_rd_en(rx_rd_en), .led(led));

    engine_top #(.INIT_FILE(TX_PROG)) u_tx (
        .clk(clk_50M), .rst_n(rst_n),
        .tx_wr_en(rx_rd_en), .tx_wr_data({24'd0, rx_rd_data[31:24]}), .tx_full(tx_full),
        .rx_rd_en(1'b0), .rx_rd_data(tx_rd_unused), .rx_empty(),
        .pin_in(8'd0), .pin_out(tx_out), .pin_oe(tx_oe),
        .halted(), .fault(), .pc());

    assign bt_tx_pin = tx_oe[0] ? tx_out[0] : 1'b1;   // idle high until TX firmware drives
endmodule
