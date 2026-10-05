// Feeds a fixed ASCII message into the engine's tx_fifo, one byte per write,
// stalling on tx_full (the engine's PULL does the rest). One `send` pulse = one message.
module msg_sender (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        send,
    output wire        tx_wr_en,
    output wire [31:0] tx_wr_data,
    input  wire        tx_full,
    output wire        busy
);
    // ---- EDIT HERE: message and its exact length in bytes ----
    // The literal is left-padded with NUL if shorter than MSG_LEN, truncated if longer.
    localparam integer           MSG_LEN = 17;
    localparam [8*MSG_LEN-1:0]   MSG     = "JANESTREET\r\n";
    // -----------------------------------------------------------

    localparam IDX_W = (MSG_LEN > 1) ? $clog2(MSG_LEN) : 1;

    reg             active;
    reg [IDX_W-1:0] idx;

    // first character lives in the MSB of the string literal
    wire [7:0] cur_byte = MSG[8*(MSG_LEN-1-idx) +: 8];

    assign busy       = active;
    assign tx_wr_en   = active && !tx_full;
    assign tx_wr_data = {24'd0, cur_byte};

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            active <= 1'b0;
            idx    <= {IDX_W{1'b0}};
        end else if (!active) begin
            idx <= {IDX_W{1'b0}};
            if (send) active <= 1'b1;
        end else if (tx_wr_en) begin
            if (idx == MSG_LEN-1) active <= 1'b0;
            else                  idx    <= idx + 1'b1;
        end
    end
endmodule
