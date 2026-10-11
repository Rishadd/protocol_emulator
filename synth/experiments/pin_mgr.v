// PROTOTYPE for an area estimate (not integrated, not simulated, not in src/).
// Pin management directory between the two engines and the 8 protocol pads (uio[7:0]).
//   * every pad has an owner: none / engine 0 / engine 1 / diagnostic (host-driven)
//   * only the owner's data and enable reach the pad, and only while that engine is running
//   * a claim on a pad owned by a running engine is refused (deny flag), so a later-loaded
//     protocol cannot steal a pin from a live one; a free pad, or one whose owner is held, can be claimed
//   * a non-owner trying to drive a pad is blocked and recorded in a sticky per-pin violation bit
//   * per-pad open-drain mode: pad data forced 0, pad enable = oe & ~out ("1" releases the line),
//     so OUT1/SETH/SETLO become I2C/1-Wire safe without a new ISA bit
//   * REMAP=1 adds a per-pad source-pin map (which engine pin drives each pad) and a per-engine
//     input map (which pad each engine pin reads), so one firmware image can run on any pads
// Reset releases everything: owner = none, so nothing drives until the host claims pads.
module pin_mgr #(
    parameter REMAP = 0
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  run,
    // claim / configuration write port (management)
    input  wire        cfg_we,
    input  wire [2:0]  cfg_pad,
    input  wire [1:0]  cfg_owner,     // 0 none, 1 eng0, 2 eng1, 3 diagnostic
    input  wire        cfg_od,
    input  wire [2:0]  cfg_src,       // REMAP: engine pin that drives this pad
    input  wire        cfg_in_we,     // REMAP: engine input map write
    input  wire        cfg_in_eng,
    input  wire [2:0]  cfg_in_pin,
    input  wire [2:0]  cfg_in_pad,
    input  wire        diag_we,       // diagnostic drive registers
    input  wire [7:0]  diag_oe_d,
    input  wire [7:0]  diag_out_d,
    input  wire [7:0]  viol_clr,
    // engines
    input  wire [7:0]  oe0, out0, oe1, out1,
    output wire [7:0]  in0, in1,
    // pads
    input  wire [7:0]  pad_in,
    output wire [7:0]  pad_oe,
    output wire [7:0]  pad_out,
    // readback / status
    output wire [15:0] owner_q,
    output wire [7:0]  od_q,
    output wire [7:0]  viol0_q, viol1_q,
    output reg         deny
);
    reg [15:0] owner;
    reg [7:0]  od, diag_oe, diag_out, viol0, viol1;
    reg [23:0] src;                       // REMAP: per pad
    reg [23:0] inmap0, inmap1;            // REMAP: per engine pin -> pad

    assign owner_q = owner;
    assign od_q    = od;
    assign viol0_q = viol0;
    assign viol1_q = viol1;

    wire [1:0] cur   = owner[cfg_pad*2 +: 2];
    wire cur_running = (cur == 2'd1 && run[0]) || (cur == 2'd2 && run[1]);
    wire grant       = cfg_we && !cur_running;

    wire [7:0] e0sel, e1sel, dgsel, oe_raw, out_raw, v0n, v1n;
    wire [7:0] oe0m, out0m, oe1m, out1m;

    genvar p;
    generate for (p = 0; p < 8; p = p + 1) begin : g
        wire [2:0] s = REMAP ? src[p*3 +: 3] : p[2:0];
        assign oe0m[p]  = oe0[s];
        assign out0m[p] = out0[s];
        assign oe1m[p]  = oe1[s];
        assign out1m[p] = out1[s];

        assign e0sel[p] = (owner[p*2 +: 2] == 2'd1) & run[0];
        assign e1sel[p] = (owner[p*2 +: 2] == 2'd2) & run[1];
        assign dgsel[p] = (owner[p*2 +: 2] == 2'd3);
        assign oe_raw[p]  = (e0sel[p] & oe0m[p])  | (e1sel[p] & oe1m[p])  | (dgsel[p] & diag_oe[p]);
        assign out_raw[p] = (e0sel[p] & out0m[p]) | (e1sel[p] & out1m[p]) | (dgsel[p] & diag_out[p]);
        assign pad_oe[p]  = od[p] ? (oe_raw[p] & ~out_raw[p]) : oe_raw[p];
        assign pad_out[p] = od[p] ? 1'b0 : out_raw[p];

        // a running engine enabling a pad it does not own
        assign v0n[p] = run[0] & oe0m[p] & (owner[p*2 +: 2] != 2'd1);
        assign v1n[p] = run[1] & oe1m[p] & (owner[p*2 +: 2] != 2'd2);

        assign in0[p] = REMAP ? pad_in[inmap0[p*3 +: 3]] : pad_in[p];
        assign in1[p] = REMAP ? pad_in[inmap1[p*3 +: 3]] : pad_in[p];
    end endgenerate

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner <= 16'd0; od <= 8'd0; diag_oe <= 8'd0; diag_out <= 8'd0;
            viol0 <= 8'd0; viol1 <= 8'd0; deny <= 1'b0; src <= 24'd0;
            inmap0 <= 24'd0; inmap1 <= 24'd0;
        end else begin
            if (grant) begin
                owner[cfg_pad*2 +: 2] <= cfg_owner;
                od[cfg_pad]           <= cfg_od;
                if (REMAP) src[cfg_pad*3 +: 3] <= cfg_src;
            end
            if (cfg_we && !grant) deny <= 1'b1;
            if (REMAP && cfg_in_we) begin
                if (cfg_in_eng) inmap1[cfg_in_pin*3 +: 3] <= cfg_in_pad;
                else            inmap0[cfg_in_pin*3 +: 3] <= cfg_in_pad;
            end
            if (diag_we) begin diag_oe <= diag_oe_d; diag_out <= diag_out_d; end
            viol0 <= (viol0 & ~viol_clr) | v0n;
            viol1 <= (viol1 & ~viol_clr) | v1n;
        end
    end
endmodule
