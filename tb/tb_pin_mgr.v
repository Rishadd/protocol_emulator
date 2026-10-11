`timescale 1ns/1ps
`include "tb_common.vh"
// pin_mgr unit test: exhaustive pad mux (owner x od x oe/out of both engines), claim rules,
// sticky violations with write-one-to-clear, reset state, open-drain never drives high.
module tb_pin_mgr;
    reg         clk = 0, rst_n = 0;
    reg  [1:0]  run = 0;
    reg  [2:0]  cfg_pad = 0, cfg_data = 0;
    reg         cfg_we = 0;
    reg  [15:0] viol_clr = 0;
    reg  [7:0]  oe0 = 0, out0 = 0, oe1 = 0, out1 = 0;
    wire        cfg_ok;
    wire [7:0]  pad_oe, pad_out, od;
    wire [15:0] owner, viol;
    integer errors = 0, p, o, d, v, n = 0;
    reg         e_oe, e_out;

    pin_mgr dut (.clk(clk), .rst_n(rst_n), .run(run), .cfg_pad(cfg_pad), .cfg_data(cfg_data), .cfg_ok(cfg_ok),
                 .cfg_we(cfg_we), .viol_clr(viol_clr), .oe0(oe0), .out0(out0), .oe1(oe1), .out1(out1),
                 .pad_oe(pad_oe), .pad_out(pad_out), .owner(owner), .od(od), .viol(viol));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask
    task claim(input [2:0] pad, input [1:0] own, input odv);   // write only if accepted, like mgmt
        begin cfg_pad = pad; cfg_data = {odv, own}; #1; cfg_we = cfg_ok; tick; cfg_we = 0; end
    endtask

    initial begin
        tick; tick; rst_n = 1; tick;
        // ---- reset: nothing owned, nothing driven even with every engine pin enabled high
        oe0 = 8'hFF; out0 = 8'hFF; oe1 = 8'hFF; out1 = 8'hFF; #1;
        `CHECK(owner == 0 && od == 0 && pad_oe == 0 && pad_out == 0, "reset: no owner, no pad driven")
        oe0 = 0; out0 = 0; oe1 = 0; out1 = 0;

        // ---- exhaustive mux: every pad, owner 0/1/2, od 0/1, all 16 oe/out combinations of both engines
        for (p = 0; p < 8; p = p + 1)
            for (o = 0; o < 3; o = o + 1)
                for (d = 0; d < 2; d = d + 1) begin
                    claim(p, o, d);
                    `CHECK(owner[2*p +: 2] == o && od[p] == d, "claim accepted while engines held")
                    for (v = 0; v < 16; v = v + 1) begin
                        oe0[p] = v[0]; out0[p] = v[1]; oe1[p] = v[2]; out1[p] = v[3]; #1;
                        e_oe  = (o == 1) ? v[0] : (o == 2) ? v[2] : 1'b0;
                        e_out = (o == 1) ? v[1] : (o == 2) ? v[3] : 1'b0;
                        `CHECK(pad_oe[p]  == (d ? e_oe & ~e_out : e_oe), "pad enable = owner's oe (od: oe & ~out)")
                        `CHECK(pad_out[p] == (d ? 1'b0 : e_out),          "pad data = owner's out (od: 0)")
                        `CHECK(!(d && pad_oe[p] && pad_out[p]),           "open-drain never drives high")
                        `CHECK((pad_oe & ~(8'd1 << p)) == 0 && (pad_out & ~(8'd1 << p)) == 0, "other pads unaffected")
                        n = n + 1;
                    end
                    oe0 = 0; out0 = 0; oe1 = 0; out1 = 0;
                end
        $display("  mux combinations checked: %0d", n);

        // ---- claim rules
        claim(3, 1, 0); run = 2'b01; #1;
        cfg_pad = 3; cfg_data = 3'b010; #1;
        `CHECK(cfg_ok == 0, "claim refused while the owner (engine 0) runs")
        cfg_pad = 4; #1;
        `CHECK(cfg_ok == 1, "claim of another pad (free) allowed while engine 0 runs")
        claim(4, 2, 1); run = 2'b10; #1;
        cfg_pad = 4; cfg_data = 3'b001; #1;
        `CHECK(cfg_ok == 0, "claim refused while the owner (engine 1) runs")
        cfg_pad = 3; cfg_data = 3'b000; #1;
        `CHECK(cfg_ok == 1, "pad of a held engine can be released")
        cfg_data = 3'b011; #1;
        `CHECK(cfg_ok == 0, "owner 3 refused")
        run = 2'b00;

        // ---- violations: a running engine enabling a pad it does not own
        claim(0, 1, 0); claim(1, 2, 0);
        run = 2'b11; oe1 = 8'h01; oe0 = 8'h02; #1;
        `CHECK(pad_oe[0] == 0 && pad_oe[1] == 0, "violating enables never reach the pads")
        tick; oe0 = 0; oe1 = 0; tick;
        `CHECK(viol == 16'h0102, "viol: eng1 on pad 0 and eng0 on pad 1 recorded, sticky")
        viol_clr = 16'h0100; tick; viol_clr = 0; tick;
        `CHECK(viol == 16'h0002, "W1C clears only the written bits")
        oe0 = 8'h02; viol_clr = 16'h0002; tick; viol_clr = 0; oe0 = 0; tick;
        `CHECK(viol == 16'h0002, "a new violation wins over a clear in the same cycle")
        run = 2'b00; oe0 = 8'h04; tick; oe0 = 0;
        `CHECK(viol[2] == 0, "held engine: no violation recorded")
        oe0 = 8'h01; #1;
        `CHECK(pad_oe[0] == 1, "owner drives its pad (engine 0, pad 0)")
        oe0 = 0; oe1 = 8'h01; #1;
        `CHECK(pad_oe[0] == 0, "non-owner (engine 1) cannot reach pad 0")
        oe1 = 0;

        // ---- reset clears everything
        rst_n = 0; #1;
        `CHECK(owner == 0 && od == 0 && viol == 0, "reset clears owner, od and violations")

        `REPORT("tb_pin_mgr")
        $finish;
    end
endmodule
