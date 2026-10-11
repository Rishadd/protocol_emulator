// Pin manager: ownership and electrical mode of the 8 protocol pads (uio[7:0]) shared by two engines.
//   * owner per pad: 0 none, 1 engine 0, 2 engine 1 (3 reserved). Reset = none: nothing drives until
//     the host claims a pad.
//   * only the owner's enable/data reach the pad (a held engine has already released its pins).
//   * a claim (cfg write) is refused while the pad's current owner is running, and for owner 3.
//     cfg_ok tells the management controller; it applies cfg_we only when cfg_ok was 1.
//   * open-drain pad (od = 1): data forced 0, enable = oe & ~out, so out = 1 releases the line and
//     out = 0 pulls it low. SETH/SETLO/OUT1 then drive an open-drain bus with no ISA change.
//   * viol: sticky, {engine 1, engine 0}; set when a running engine enables a pad it does not own.
//     Cleared by viol_clr (write-one-to-clear); a new violation wins over a clear.
// Inputs are not managed: both engines always see every pad.
module pin_mgr (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  run,
    // configuration (management)
    input  wire [2:0]  cfg_pad,
    input  wire [2:0]  cfg_data,     // [1:0] owner, [2] open-drain
    output wire        cfg_ok,
    input  wire        cfg_we,
    input  wire [15:0] viol_clr,     // pulse: bits to clear
    // engines
    input  wire [7:0]  oe0, out0, oe1, out1,
    // pads
    output wire [7:0]  pad_oe,
    output wire [7:0]  pad_out,
    // readback
    output reg  [15:0] owner,        // 2 bits per pad
    output reg  [7:0]  od,
    output reg  [15:0] viol          // {viol1, viol0}
);
    wire [1:0] cur = owner[cfg_pad*2 +: 2];
    assign cfg_ok = (cfg_data[1:0] != 2'd3) && !(cur == 2'd1 && run[0]) && !(cur == 2'd2 && run[1]);

    wire [7:0] own0, own1;
    genvar p;
    generate for (p = 0; p < 8; p = p + 1) begin : g
        assign own0[p] = (owner[2*p +: 2] == 2'd1);
        assign own1[p] = (owner[2*p +: 2] == 2'd2);
    end endgenerate

    wire [7:0] oe_sel  = (own0 & oe0)  | (own1 & oe1);
    wire [7:0] out_sel = (own0 & out0) | (own1 & out1);
    assign pad_oe  = oe_sel & ~(od & out_sel);
    assign pad_out = out_sel & ~od;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner <= 16'd0;
            od    <= 8'd0;
            viol  <= 16'd0;
        end else begin
            if (cfg_we) begin
                owner[cfg_pad*2 +: 2] <= cfg_data[1:0];
                od[cfg_pad]           <= cfg_data[2];
            end
            viol <= (viol & ~viol_clr) | {oe1 & ~own1 & {8{run[1]}}, oe0 & ~own0 & {8{run[0]}}};
        end
    end
endmodule
