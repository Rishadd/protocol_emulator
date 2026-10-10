// DE0-Nano top: KEY1 press -> msg_sender -> engine_top (UART TX program) -> HC-05.
// Pin names match the old HardwareTest.qsf so the board wiring is unchanged.
module de0_nano_top #(
    parameter PROG_FILE     = "uart_tx_prog.hex",
    parameter DEBOUNCE_BITS = 20                 // 2^20 / 50 MHz ~ 21 ms
)(
    input  wire       clk_50M,     // PIN_R8
    input  wire       reset_n,     // PIN_J15  KEY0, active low
    input  wire       start_n,     // PIN_E1   KEY1, active low: send message
    input  wire       bt_rx_pin,   // PIN_J13  <- HC-05 TXD (unused until RX phase)
    output wire       bt_tx_pin,   // PIN_J14  -> HC-05 RXD
    output wire [7:0] led
);
    // ---- reset: async assert, sync release ----
    reg [1:0] rst_sync;
    always @(posedge clk_50M or negedge reset_n) begin
        if (!reset_n) rst_sync <= 2'b00;
        else          rst_sync <= {rst_sync[0], 1'b1};
    end
    wire rst_n = rst_sync[1];

    // ---- KEY1: sync, debounce, falling edge -> single-cycle send pulse ----
    reg [1:0]             btn_sync;
    reg [DEBOUNCE_BITS-1:0] db_cnt;
    reg                   btn_stable, btn_stable_d;

    always @(posedge clk_50M or negedge rst_n) begin
        if (!rst_n) begin
            btn_sync     <= 2'b11;
            db_cnt       <= {DEBOUNCE_BITS{1'b0}};
            btn_stable   <= 1'b1;
            btn_stable_d <= 1'b1;
        end else begin
            btn_sync     <= {btn_sync[0], start_n};
            btn_stable_d <= btn_stable;
            if (btn_sync[1] == btn_stable) begin
                db_cnt <= {DEBOUNCE_BITS{1'b0}};
            end else if (&db_cnt) begin
                btn_stable <= btn_sync[1];
                db_cnt     <= {DEBOUNCE_BITS{1'b0}};
            end else begin
                db_cnt <= db_cnt + 1'b1;
            end
        end
    end
    wire send = btn_stable_d & ~btn_stable;   // press = high -> low

    // ---- message feeder -> engine ----
    wire        tx_wr_en, tx_full, busy;
    wire [31:0] tx_wr_data;
    wire [7:0]  pin_out, pin_oe;
    wire        halted, fault;
    wire [5:0]  pc;
    wire [31:0] rx_rd_data;
    wire        rx_empty;

    msg_sender u_sender (
        .clk        (clk_50M),
        .rst_n      (rst_n),
        .send       (send),
        .tx_wr_en   (tx_wr_en),
        .tx_wr_data (tx_wr_data),
        .tx_full    (tx_full),
        .busy       (busy)
    );

    engine_top #(.INIT_FILE(PROG_FILE)) u_engine (
        .clk        (clk_50M),
        .imem_we(1'b0), .imem_waddr(6'd0), .imem_wdata(32'd0), .run(1'b1),
        .rst_n      (rst_n),
        .tx_wr_en   (tx_wr_en),
        .tx_wr_data (tx_wr_data),
        .tx_full    (tx_full),
        .rx_rd_en   (1'b0),
        .rx_rd_data (rx_rd_data),
        .rx_empty   (rx_empty),
        .pin_in     ({6'd0, bt_rx_pin, 1'b0}),   // pin 1 = UART RX (future)
        .pin_out    (pin_out),
        .pin_oe     (pin_oe),
        .halted     (halted),
        .fault      (fault),
        .pc         (pc)
    );

    // idle high until firmware runs DIRO
    assign bt_tx_pin = pin_oe[0] ? pin_out[0] : 1'b1;

    assign led[0]   = busy;
    assign led[1]   = halted;
    assign led[2]   = fault;
    assign led[3]   = ~btn_stable;
    assign led[7:4] = pc[3:0];
endmodule
