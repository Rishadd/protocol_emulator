// Formal properties of src/pin_mgr.v (SymbiYosys, formal/pin_mgr.sby). Safety obligations V01 / V02 of the architecture:
// only the owning engine ever reaches a pad, an open-drain pad is never driven high, ownership cannot change under a running engine.
// Environment contract (proved separately for the management controller): a configuration write is only applied when the pin
// manager accepted it (cfg_we -> cfg_ok). Everything else (run, engine pins, clears, writes) is unconstrained.
module pin_mgr_props (
    input wire        clk,
    input wire [1:0]  run,
    input wire [2:0]  cfg_pad,
    input wire [2:0]  cfg_data,
    input wire        cfg_we,
    input wire [15:0] viol_clr,
    input wire [7:0]  oe0, out0, oe1, out1
);
    // reset: asserted in the first cycle, then free (a later reset is just another start)
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire        cfg_ok;
    wire [7:0]  pad_oe, pad_out, od;
    wire [15:0] owner, viol;
    pin_mgr dut (.clk(clk), .rst_n(rst_n), .run(run), .cfg_pad(cfg_pad), .cfg_data(cfg_data), .cfg_ok(cfg_ok), .cfg_we(cfg_we),
                 .viol_clr(viol_clr), .oe0(oe0), .out0(out0), .oe1(oe1), .out1(out1), .pad_oe(pad_oe), .pad_out(pad_out),
                 .owner(owner), .od(od), .viol(viol));

    always @(*) assume (!cfg_we || cfg_ok);          // the management controller's side of the contract

    integer p;
    always @(*) if (rst_n) begin
        for (p = 0; p < 8; p = p + 1) begin
            // P1 only the owner reaches the pad (enable and data)
            if (owner[2*p +: 2] == 2'd0) assert (!pad_oe[p] && !pad_out[p]);
            if (owner[2*p +: 2] == 2'd1) assert (pad_oe[p] == (oe0[p] & ~(od[p] & out0[p])) && pad_out[p] == (out0[p] & ~od[p]));
            if (owner[2*p +: 2] == 2'd2) assert (pad_oe[p] == (oe1[p] & ~(od[p] & out1[p])) && pad_out[p] == (out1[p] & ~od[p]));
            // P2 an open-drain pad is never driven high, and it pulls low exactly when the owner drives 0 with its enable on
            if (od[p]) assert (!pad_out[p]);
            // P3 the reserved owner code 3 never appears
            assert (owner[2*p +: 2] != 2'd3);
        end
    end

    // P4 after reset nothing is owned, so nothing is driven
    always @(posedge clk) if (rst_n && $past(init)) assert (owner == 16'd0 && od == 8'd0 && pad_oe == 8'd0 && viol == 16'd0);

    // P5 a pad owned by a running engine keeps its owner and its electrical mode
    always @(posedge clk) if (rst_n && !$past(init)) begin
        for (p = 0; p < 8; p = p + 1) begin
            if ($past(run[0]) && $past(owner[2*p +: 2]) == 2'd1) assert (owner[2*p +: 2] == 2'd1 && od[p] == $past(od[p]));
            if ($past(run[1]) && $past(owner[2*p +: 2]) == 2'd2) assert (owner[2*p +: 2] == 2'd2 && od[p] == $past(od[p]));
        end
    end

    // P6 a running engine that enables a pad it does not own is flagged in the next cycle, whatever the clear says
    always @(posedge clk) if (rst_n && !$past(init)) begin
        for (p = 0; p < 8; p = p + 1) begin
            if ($past(run[0] && oe0[p]) && $past(owner[2*p +: 2]) != 2'd1) assert (viol[p]);
            if ($past(run[1] && oe1[p]) && $past(owner[2*p +: 2]) != 2'd2) assert (viol[8 + p]);
            // and a flag is never raised without such an event (clear-only or hold otherwise)
            if (!$past(viol[p]) && !($past(run[0] && oe0[p]) && $past(owner[2*p +: 2]) != 2'd1)) assert (!viol[p]);
        end
    end
endmodule
