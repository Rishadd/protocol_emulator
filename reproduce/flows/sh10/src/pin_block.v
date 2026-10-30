// 8 GPIO pins: per-pin output data + output enable registers, 2-stage input sync.
// Reset releases every pin (oe=0), so the chip never drives before firmware says so.
module pin_block (
    input  wire       clk,
    input  wire       rst_n,
    input  wire       pin_wr,
    input  wire [2:0] pin_wr_idx,
    input  wire       pin_wr_val,
    input  wire       dir_wr,
    input  wire [2:0] dir_wr_idx,
    input  wire       dir_wr_val,
    input  wire [7:0] pin_in,
    output reg  [7:0] pin_out,
    output reg  [7:0] pin_oe,
    output wire [7:0] pin_in_sync
);
    reg [7:0] sync0, sync1;
    assign pin_in_sync = sync1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pin_out <= 8'h00;
            pin_oe  <= 8'h00;
            sync0   <= 8'h00;
            sync1   <= 8'h00;
        end else begin
            sync0 <= pin_in;
            sync1 <= sync0;
            if (pin_wr) pin_out[pin_wr_idx] <= pin_wr_val;
            if (dir_wr) pin_oe[dir_wr_idx]  <= dir_wr_val;
        end
    end
endmodule
