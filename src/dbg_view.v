// Debug views: the default function of uo_out[7:2] (docs/PIN_MAP_PLAN.md section 4), selected by DBG_SEL = ui_in[7:5]
// (or by MISC[6:4] once DBG_SEL is released for protocol use). Answers the bring-up questions that cannot wait for a
// working management link. view[0] drives uo_out[2], view[5] uo_out[7].
//   0  heartbeat (clk / 2^25, ~1.5 Hz at 50 MHz), management error, RUN e0, RUN e1, halted-or-fault e0, halted-or-fault e1
//   1  last SPI byte received [3:0], toggle per received byte, toggle per frame end
//   2  last SPI byte received [7:4], frame-clean flag, CS_N (synchronised)
//   3  loopback: ui_in[7:3], uio_in[0]
//   4  memory self-test (not built yet: 0)
//   5  uio_in[5:0]
//   6  logic analyser: [0] armed [1] triggered or done [2] done [3] buffer full [4] wrapped [5] engines' trigger line (view[0] = uo_out[2])
//   7  reserved (0)
module dbg_view (
    input  wire       clk,
    input  wire       rst_n,
    input  wire [2:0] sel,
    input  wire       err,
    input  wire [1:0] run,
    input  wire [1:0] halted,
    input  wire [1:0] fault,
    input  wire [7:0] rx_byte,       // spi_slave: holds the last completed byte
    input  wire       byte_valid,
    input  wire       frame_end,
    input  wire       frame_clean,
    input  wire       active,
    input  wire [4:0] ui_hi,         // ui_in[7:3]
    input  wire [7:0] uio_in,
    input  wire [5:0] la_view,       // la_block
    output reg  [5:0] view
);
    reg [24:0] hb;
    reg        t_byte, t_frame;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hb      <= 25'd0;
            t_byte  <= 1'b0;
            t_frame <= 1'b0;
        end else begin
            hb <= hb + 1'b1;
            if (byte_valid) t_byte  <= ~t_byte;
            if (frame_end)  t_frame <= ~t_frame;
        end
    end

    wire [1:0] hf = halted | fault;
    always @(*) begin
        case (sel)
            3'd0:    view = {hf[1], hf[0], run[1], run[0], err, hb[24]};
            3'd1:    view = {t_frame, t_byte, rx_byte[3:0]};
            3'd2:    view = {~active, frame_clean, rx_byte[7:4]};
            3'd3:    view = {uio_in[0], ui_hi};
            3'd5:    view = uio_in[5:0];
            3'd6:    view = la_view;
            default: view = 6'd0;
        endcase
    end
endmodule
