// DE0-Nano RX top: HC-05 TXD -> engine (UART RX program) -> rx_fifo -> rx_led_sink -> led[7:0].
// Pin names match de0_nano_top so the same board assignments apply.
module de0_nano_rx_top #(
    parameter PROG_FILE = "src/fpga/uart_rx_prog.hex"
)(
    input  wire       clk_50M,     // PIN_R8
    input  wire       reset_n,     // PIN_J15  KEY0, active low
    input  wire       bt_rx_pin,   // PIN_J13  <- HC-05 TXD
    output wire       bt_tx_pin,   // PIN_J14  -> HC-05 RXD, held idle high
    output wire [7:0] led
);
    // ---- reset: async assert, sync release ----
    reg [1:0] rst_sync;
    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) rst_sync <= 2'b00;
        else          rst_sync <= {rst_sync[0], 1'b1};
    end
    wire rst_n = rst_sync[1];

    wire        tx_full, rx_empty, rx_rd_en, halted, fault;
    wire [31:0] rx_rd_data;
    wire [7:0]  pin_out, pin_oe;
    wire [5:0]  pc;

    engine_top #(.INIT_FILE(PROG_FILE)) u_engine (
        .clk        (clk_50M),
        .imem_we(1'b0), .imem_waddr(6'd0), .imem_wdata(32'd0), .run(1'b1),
        .rst_n      (rst_n),
        .tx_wr_en   (1'b0),
        .tx_wr_data (32'd0),
        .tx_full    (tx_full),
        .rx_rd_en   (rx_rd_en),
        .rx_rd_data (rx_rd_data),
        .rx_empty   (rx_empty),
        .pin_in     ({6'd0, bt_rx_pin, 1'b0}),   // pin 1 = UART RX
        .pin_out    (pin_out),
        .pin_oe     (pin_oe),
        .halted     (halted),
        .fault      (fault),
        .pc         (pc)
    );

    rx_led_sink u_sink (
        .clk        (clk_50M),
        .rst_n      (rst_n),
        .rx_empty   (rx_empty),
        .rx_rd_data (rx_rd_data),
        .rx_rd_en   (rx_rd_en),
        .led        (led)
    );

    assign bt_tx_pin = 1'b1;
endmodule
