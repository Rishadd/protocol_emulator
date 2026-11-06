`timescale 1ns/1ps
`include "tb_common.vh"
// pin_mgr unit test: exhaustive pad mux (owner x od x oe/out of both engines), claim rules, sticky violations with
// write-one-to-clear, reset state, open-drain never drives high; remapping of uio and uo_out pins, input select,
// HOLD, MISC lock while running, IRQ, register readback and refusals.
module tb_pin_mgr;
    // waveform: run vvp with +dump to write build/wave/tb_pin_mgr.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_pin_mgr.vcd"); $dumpvars(0, tb_pin_mgr); end
    reg         clk = 0, rst_n = 0;
    reg  [1:0]  run = 0;
    reg  [5:0]  w_addr = 0, r_addr = 0;
    reg  [31:0] w_data = 0;
    reg         we = 0;
    reg  [7:0]  oe0 = 0, out0 = 0, oe1 = 0, out1 = 0, uio_in = 0;
    reg  [4:0]  ui_hi = 0;
    reg  [5:0]  view = 6'b101010;
    reg  [6:0]  irq_src = 0;
    wire        w_hit, w_ok, hold, trig_en, irq;
    wire [31:0] r_data;
    wire [7:0]  in0, in1, pad_oe, pad_out, od;
    wire [6:0]  uo_hi;
    wire [2:0]  view_sel;
    wire [15:0] owner, oowner, viol;
    wire [23:0] remap, oremap;
    wire [31:0] isel0, isel1;
    integer errors = 0, p, o, d, v, i, n = 0;
    reg         e_oe, e_out;

    pin_mgr dut (.clk(clk), .rst_n(rst_n), .run(run), .w_addr(w_addr), .w_data(w_data), .w_hit(w_hit), .w_ok(w_ok), .we(we),
                 .r_addr(r_addr), .r_data(r_data), .oe0(oe0), .out0(out0), .oe1(oe1), .out1(out1), .in0(in0), .in1(in1),
                 .uio_in(uio_in), .ui_hi(ui_hi), .uio_oe(pad_oe), .uio_out(pad_out), .uo_hi(uo_hi), .view(view),
                 .irq_src(irq_src), .la_done(1'b0), .hold(hold), .trig_en(trig_en), .view_sel(view_sel), .irq(irq),
                 .owner(owner), .od(od), .remap(remap), .oowner(oowner), .oremap(oremap), .isel0_r(isel0), .isel1_r(isel1),
                 .viol(viol));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask
    task wr(input [5:0] a, input [31:0] dd);                 // applied only if accepted, like mgmt
        begin w_addr = a; w_data = dd; #1; we = w_ok; tick; we = 0; end
    endtask
    task ok_is(input [5:0] a, input [31:0] dd, input exp, input [8*60-1:0] msg);
        begin w_addr = a; w_data = dd; #1; `CHECK(w_ok == exp, msg) end
    endtask
    task rd(input [5:0] a); begin r_addr = a; #1; end endtask
    task claim(input [2:0] pad, input [1:0] own, input odv); wr({3'd0, pad}, {29'd0, odv, own}); endtask

    initial begin
        tick; tick; rst_n = 1; tick;
        // ---- reset: nothing owned, nothing driven even with every engine pin enabled high; defaults on uo
        oe0 = 8'hFF; out0 = 8'hFF; oe1 = 8'hFF; out1 = 8'hFF; #1;
        `CHECK(owner == 0 && od == 0 && pad_oe == 0 && pad_out == 0, "reset: no owner, no pad driven")
        `CHECK(uo_hi == {view, 1'b0}, "reset: uo_out[7:1] = {debug view, IRQ = 0}")
        `CHECK(trig_en == 1 && hold == 0, "reset: TRIG_IN enabled, not holding")
        for (i = 0; i < 8; i = i + 1) begin
            `CHECK(isel0[4*i +: 4] == i && isel1[4*i +: 4] == i, "reset: isel = identity")
        end
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
        for (p = 0; p < 8; p = p + 1) claim(p, 0, 0);

        // ---- claim rules
        claim(3, 1, 0); run = 2'b01; #1;
        ok_is(3, 32'd2, 0, "claim refused while the owner (engine 0) runs");
        ok_is(3, 32'h18, 0, "remap refused while the owner runs");
        ok_is(4, 32'd2, 1, "claim of another pad (free) allowed while engine 0 runs");
        claim(4, 2, 1); run = 2'b10; #1;
        ok_is(4, 32'd1, 0, "claim refused while the owner (engine 1) runs");
        ok_is(3, 32'd0, 1, "pad of a held engine can be released");
        ok_is(3, 32'd3, 0, "owner 3 refused");
        ok_is(3, 32'h40, 0, "PAD reserved bit 6 refused");
        run = 2'b00; claim(3, 0, 0); claim(4, 0, 0);

        // ---- violations: a running engine enabling a logical pin no owned pin carries
        claim(0, 1, 0); claim(1, 2, 0);
        run = 2'b11; oe1 = 8'h01; oe0 = 8'h02; #1;
        `CHECK(pad_oe[0] == 0 && pad_oe[1] == 0, "violating enables never reach the pads")
        tick; oe0 = 0; oe1 = 0; tick;
        `CHECK(viol == 16'h0102, "viol: eng1 on pin 0 and eng0 on pin 1 recorded, sticky")
        wr(8, 32'h0100); tick;
        `CHECK(viol == 16'h0002, "W1C clears only the written bits")
        oe0 = 8'h02; wr(8, 32'h0002); oe0 = 0; tick;
        `CHECK(viol == 16'h0002, "a new violation wins over a clear in the same cycle")
        ok_is(8, 32'h10000, 0, "VIOL write with reserved bits refused");
        run = 2'b00; wr(8, 32'hFFFF); oe0 = 8'h04; tick; oe0 = 0;
        `CHECK(viol == 0, "held engine: no violation recorded")
        oe0 = 8'h01; #1;
        `CHECK(pad_oe[0] == 1, "owner drives its pad (engine 0, pad 0)")
        oe0 = 0; oe1 = 8'h01; #1;
        `CHECK(pad_oe[0] == 0, "non-owner (engine 1) cannot reach pad 0")
        oe1 = 0; claim(0, 0, 0); claim(1, 0, 0);

        // ---- remap: pad p carries logical pin p ^ remap
        wr(5, {26'd0, 3'd5 ^ 3'd2, 1'b0, 2'd1});                // pad 5 <- engine 0 logical pin 2
        rd(5);
        `CHECK(r_data == {26'd0, 3'd7, 3'd1}, "PAD readback {remap, od, owner}")
        oe0 = 8'h04; out0 = 8'h04; #1;
        `CHECK(pad_oe == 8'h20 && pad_out == 8'h20, "pad 5 shows engine 0 logical pin 2")
        run = 2'b01; tick; tick;
        `CHECK(viol == 0, "logical pin 2 is carried by pad 5: no violation")
        oe0 = 8'h20; out0 = 8'h20; tick; tick;
        `CHECK(pad_oe == 0 && viol[5] == 1, "logical pin 5 is now carried by no pad: not driven, flagged")
        run = 0; oe0 = 0; out0 = 0; wr(8, 32'hFFFF); claim(5, 0, 0);

        // ---- uo_out[k]: OPAD, default function when unowned, oe & out when owned
        ok_is(16, 32'd1, 0, "OPAD 0 (MISO) does not exist");
        ok_is(17, 32'd4, 0, "OPAD od bit refused (uo_out has no open-drain)");
        wr(17 + 2, {26'd0, 3'd3 ^ 3'd0, 1'b0, 2'd2});           // uo_out[3] <- engine 1 logical pin 0
        rd(19);
        `CHECK(r_data == {26'd0, 3'd3, 1'b0, 2'd2}, "OPAD readback")
        out1 = 8'h01; #1;
        `CHECK(uo_hi[2] == 0, "owned uo pin with oe = 0 shows 0")
        oe1 = 8'h01; #1;
        `CHECK(uo_hi[2] == 1, "owned uo pin shows the owner's logical pin")
        `CHECK({uo_hi[6:3], uo_hi[1:0]} == {view[5:2], view[0], 1'b0}, "other uo pins keep their defaults")
        run = 2'b10; tick; tick;
        `CHECK(viol == 0, "engine 1 logical pin 0 carried by uo_out[3]: no violation")
        ok_is(19, 32'd0, 0, "uo pin of a running engine cannot be released");
        run = 0; oe1 = 0; out1 = 0; wr(19, 32'd0);
        `CHECK(uo_hi == {view, 1'b0}, "released uo pin back to its default")

        // ---- input select
        uio_in = 8'b1010_0101; ui_hi = 5'b10011; #1;
        `CHECK(in0 == uio_in && in1 == uio_in, "reset: logical pin i reads uio[i]")
        wr(32 + 1, 32'd12); wr(40 + 7, 32'd8);                 // e0 pin 1 <- ui_in[7], e1 pin 7 <- ui_in[3]
        `CHECK(in0[1] == ui_hi[4] && in1[7] == ui_hi[0], "isel routes ui_in[7:3] to logical inputs")
        uio_in = 0; ui_hi = 5'b10000; #1;
        `CHECK(in0[1] == 1 && in1[7] == 0, "isel follows the selected input")
        rd(33);
        `CHECK(r_data == 12, "ISEL readback")
        ok_is(32, 32'd13, 0, "isel 13 refused");
        run = 2'b01;
        ok_is(32, 32'd3, 0, "isel of a running engine refused");
        ok_is(40, 32'd3, 1, "isel of the held engine allowed");
        run = 0; wr(33, 1); wr(47, 7); ui_hi = 0;

        // ---- HOLD: ui_in[3] high releases every engine-driven pin (after the synchroniser)
        claim(0, 1, 0); wr(17, {26'd0, 3'd1, 1'b0, 2'd1});      // pad 0 and uo_out[1] <- engine 0 pin 0
        oe0 = 8'h01; out0 = 8'h01; #1;
        `CHECK(pad_oe[0] == 1 && uo_hi[0] == 1, "engine drives pad 0 and uo_out[1]")
        ui_hi[0] = 1; tick; tick;
        `CHECK(hold == 1 && pad_oe == 0 && uo_hi == {view, 1'b0}, "HOLD: pins released, uo back to defaults")
        rd(50);
        `CHECK(r_data[13] == 1, "INPUTS shows hold active")
        ok_is(48, 32'h6, 1, "MISC: hold_en can be cleared while engines are held");
        run = 2'b01;
        ok_is(48, 32'h6, 0, "MISC [2:0] locked while an engine runs");
        ok_is(48, 32'h7 | 32'h00FF0000, 1, "MISC IRQ mask may change while running");
        run = 0; wr(48, 32'h6); #1;
        `CHECK(hold == 0 && pad_oe[0] == 1, "hold_en = 0: ui_in[3] no longer holds")
        ui_hi[0] = 0; oe0 = 0; out0 = 0; claim(0, 0, 0); wr(17, 0);

        // ---- debug view select: DBG_SEL pins, or MISC[6:4] once released
        ui_hi[4:2] = 3'd5; #1;
        `CHECK(view_sel == 5, "dbg_en: view from ui_in[7:5]")
        wr(48, 32'h0000_0032);                                   // dbg_en = 0, view 3, hold_en = 0, trig_en = 1
        `CHECK(view_sel == 3 && trig_en == 1, "dbg_en = 0: view from MISC[6:4]")
        ok_is(48, 32'h0000_0080, 0, "MISC reserved bit 7 refused");
        rd(48);
        `CHECK(r_data == 32'h0000_0032, "MISC readback")

        // ---- IRQ: sticky status, mask, W1C
        rd(49);
        `CHECK(r_data[7] == 1, "earlier violations left IRQ bit 7 set")
        wr(49, 32'hFF); tick;
        irq_src = 7'b000_0001; tick; irq_src = 0; tick;
        `CHECK(irq == 0, "masked source: no IRQ")
        rd(49);
        `CHECK(r_data == 32'h01, "IRQ status sticky")
        wr(48, 32'h0001_0032); #1;
        `CHECK(irq == 1 && uo_hi[0] == 1, "unmasked: IRQ on uo_out[1]")
        wr(49, 32'h01); tick;
        `CHECK(irq == 0, "W1C clears the status")
        irq_src = 7'b100_0000; wr(49, 32'h40); tick; rd(49);
        `CHECK(r_data[6] == 1, "a live source wins over a clear")
        irq_src = 0;
        ok_is(49, 32'h10000, 0, "IRQ write with reserved bits refused");
        ok_is(50, 32'h0, 0, "INPUTS is read-only");
        ok_is(51, 32'h0, 0, "unmapped 0x02CC refused");
        w_addr = 51; #1;
        `CHECK(w_hit == 0, "unmapped 0x02CC is not a register")
        w_addr = 9; #1;
        `CHECK(w_hit == 0, "unmapped 0x0224 is not a register")

        // ---- reset clears everything
        rst_n = 0; #1;
        `CHECK(owner == 0 && od == 0 && viol == 0 && remap == 0 && oowner == 0 && oremap == 0, "reset clears the mapping")

        `REPORT("tb_pin_mgr")
        $finish;
    end
endmodule
