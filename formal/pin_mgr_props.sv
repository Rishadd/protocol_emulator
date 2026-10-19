// Formal properties of src/pin_mgr.v (SymbiYosys, formal/pin_mgr.sby). Safety obligations V01 / V02 of the architecture, extended
// for the pin mapping (docs/PIN_MAP_PLAN.md): only the owning engine ever reaches a pin, through its mapping; an open-drain pad is
// never driven high; the mapping, the input select and the control bits cannot change under a running engine; HOLD releases
// every engine-driven pin; reset restores the defaults; violations and IRQ status are exact.
// Environment contract (proved separately for the management controller): a register write is only applied when the pin
// manager accepted it (we -> w_ok). Everything else (run, engine pins, pad inputs, addresses, data) is unconstrained.
module pin_mgr_props (
    input wire        clk,
    input wire [1:0]  run,
    input wire [5:0]  w_addr, r_addr,
    input wire [31:0] w_data,
    input wire        we,
    input wire [7:0]  oe0, out0, oe1, out1, uio_in,
    input wire [4:0]  ui_hi,
    input wire [5:0]  view,
    input wire [6:0]  irq_src
);
    // reset: asserted in the first cycle, then free (a later reset is just another start)
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire        w_hit, w_ok, hold, trig_en, irq;
    wire [31:0] r_data, isel0, isel1;
    wire [7:0]  in0, in1, pad_oe, pad_out, od, irq_st;
    wire [6:0]  uo_hi;
    wire [2:0]  view_sel, misc, vsel;
    wire [15:0] owner, oowner, viol, mask;
    wire [23:0] remap, oremap;
    pin_mgr dut (.clk(clk), .rst_n(rst_n), .run(run), .w_addr(w_addr), .w_data(w_data), .w_hit(w_hit), .w_ok(w_ok), .we(we),
                 .r_addr(r_addr), .r_data(r_data), .oe0(oe0), .out0(out0), .oe1(oe1), .out1(out1), .in0(in0), .in1(in1),
                 .uio_in(uio_in), .ui_hi(ui_hi), .uio_oe(pad_oe), .uio_out(pad_out), .uo_hi(uo_hi), .view(view),
                 .irq_src(irq_src), .hold(hold), .trig_en(trig_en), .view_sel(view_sel), .irq(irq),
                 .owner(owner), .od(od), .remap(remap), .oowner(oowner), .oremap(oremap), .isel0_r(isel0), .isel1_r(isel1),
                 .viol(viol), .misc(misc), .vsel(vsel), .mask(mask), .irq_st(irq_st));

    always @(*) assume (!we || w_ok);                // the management controller's side of the contract

    // logical pins carried by a pin owned by each engine (recomputed here from the registers)
    reg [7:0] c0, c1;
    reg [2:0] l;
    integer p, k, i;
    always @(*) begin
        c0 = 8'd0; c1 = 8'd0;
        for (p = 0; p < 8; p = p + 1) begin
            l = remap[3*p +: 3] ^ p[2:0];
            if (owner[2*p +: 2] == 2'd1) c0[l] = 1'b1;
            if (owner[2*p +: 2] == 2'd2) c1[l] = 1'b1;
        end
        for (k = 1; k < 8; k = k + 1) begin
            l = oremap[3*k +: 3] ^ k[2:0];
            if (oowner[2*k +: 2] == 2'd1) c0[l] = 1'b1;
            if (oowner[2*k +: 2] == 2'd2) c1[l] = 1'b1;
        end
    end

    reg [2:0] lp;
    reg [12:0] in_all;
    always @(*) in_all = {ui_hi, uio_in};
    always @(*) if (rst_n) begin
        for (p = 0; p < 8; p = p + 1) begin
            lp = remap[3*p +: 3] ^ p[2:0];
            // P1 only the owner reaches the pad, through its mapping (enable and data); HOLD releases everything
            if (owner[2*p +: 2] == 2'd0 || hold) assert (!pad_oe[p] && !pad_out[p]);
            if (owner[2*p +: 2] == 2'd1 && !hold) assert (pad_oe[p] == (oe0[lp] & ~(od[p] & out0[lp])) && pad_out[p] == (out0[lp] & ~od[p]));
            if (owner[2*p +: 2] == 2'd2 && !hold) assert (pad_oe[p] == (oe1[lp] & ~(od[p] & out1[lp])) && pad_out[p] == (out1[lp] & ~od[p]));
            // P2 an open-drain pad is never driven high
            if (od[p]) assert (!pad_out[p]);
            // P3 the reserved owner code 3 never appears
            assert (owner[2*p +: 2] != 2'd3);
        end
        for (k = 1; k < 8; k = k + 1) begin
            lp = oremap[3*k +: 3] ^ k[2:0];
            // P1u a uo_out pin shows its default function unless owned; an owned one shows its owner's oe & out; HOLD restores defaults
            if (oowner[2*k +: 2] == 2'd0 || hold) assert (uo_hi[k-1] == ((k == 1) ? irq : view[k-2]));
            if (oowner[2*k +: 2] == 2'd1 && !hold) assert (uo_hi[k-1] == (oe0[lp] & out0[lp]));
            if (oowner[2*k +: 2] == 2'd2 && !hold) assert (uo_hi[k-1] == (oe1[lp] & out1[lp]));
            assert (oowner[2*k +: 2] != 2'd3);
        end
        // slot 0 of the uo_out tables (MISO) is never written
        assert (oowner[1:0] == 2'd0 && oremap[2:0] == 3'd0);
        // P7 the input select stays within the 13 input pins, and routes exactly that pin
        for (i = 0; i < 8; i = i + 1) begin
            assert (isel0[4*i +: 4] <= 4'd12 && isel1[4*i +: 4] <= 4'd12);
            assert (in0[i] == in_all[isel0[4*i +: 4]] && in1[i] == in_all[isel1[4*i +: 4]]);
        end
        // P8 HOLD never acts unless enabled; the debug view comes from the DBG_SEL pins unless released
        if (!misc[0]) assert (!hold);
        assert (view_sel == (misc[2] ? ui_hi[4:2] : vsel));
        assert (irq == |(irq_st & mask[7:0]));       // P9 IRQ = OR of masked status
    end

    // P4 after reset: nothing owned, nothing driven, identity input select, everything enabled, no status
    always @(posedge clk) if (rst_n && $past(init)) begin
        assert (owner == 16'd0 && od == 8'd0 && remap == 24'd0 && oowner == 16'd0 && oremap == 24'd0);
        assert (pad_oe == 8'd0 && viol == 16'd0 && misc == 3'b111 && mask == 16'd0 && irq_st == 8'd0);
        for (i = 0; i < 8; i = i + 1) assert (isel0[4*i +: 4] == i && isel1[4*i +: 4] == i);
    end

    // P5 a pin owned by a running engine keeps its owner, mapping and electrical mode; a running engine's input select stays;
    //    HOLD, DBG_SEL release and TRIG_IN enable cannot change while any engine runs
    always @(posedge clk) if (rst_n && !$past(init)) begin
        for (p = 0; p < 8; p = p + 1) begin
            if ($past(run[0]) && $past(owner[2*p +: 2]) == 2'd1)
                assert (owner[2*p +: 2] == 2'd1 && od[p] == $past(od[p]) && remap[3*p +: 3] == $past(remap[3*p +: 3]));
            if ($past(run[1]) && $past(owner[2*p +: 2]) == 2'd2)
                assert (owner[2*p +: 2] == 2'd2 && od[p] == $past(od[p]) && remap[3*p +: 3] == $past(remap[3*p +: 3]));
        end
        for (k = 1; k < 8; k = k + 1) begin
            if ($past(run[0]) && $past(oowner[2*k +: 2]) == 2'd1)
                assert (oowner[2*k +: 2] == 2'd1 && oremap[3*k +: 3] == $past(oremap[3*k +: 3]));
            if ($past(run[1]) && $past(oowner[2*k +: 2]) == 2'd2)
                assert (oowner[2*k +: 2] == 2'd2 && oremap[3*k +: 3] == $past(oremap[3*k +: 3]));
        end
        if ($past(run[0])) assert (isel0 == $past(isel0));
        if ($past(run[1])) assert (isel1 == $past(isel1));
        if ($past(run != 2'b00)) assert (misc == $past(misc));
    end

    // P6 a running engine that enables a logical pin no pin of its own carries is flagged in the next cycle, whatever the clear
    //    says; and a flag is never raised without such an event (clear-only or hold otherwise)
    always @(posedge clk) if (rst_n && !$past(init)) begin
        for (i = 0; i < 8; i = i + 1) begin
            if ($past(run[0] && oe0[i] && !c0[i])) assert (viol[i]);
            if ($past(run[1] && oe1[i] && !c1[i])) assert (viol[8 + i]);
            if (!$past(viol[i]) && !$past(run[0] && oe0[i] && !c0[i])) assert (!viol[i]);
            if (!$past(viol[8 + i]) && !$past(run[1] && oe1[i] && !c1[i])) assert (!viol[8 + i]);
        end
    end

    // P10 IRQ status: set by its source (or, bit 7, by a violation), cleared only by a write-one-to-clear
    always @(posedge clk) if (rst_n && !$past(init)) begin
        for (i = 0; i < 7; i = i + 1) begin
            if ($past(irq_src[i])) assert (irq_st[i]);
            if ($past(irq_st[i]) && !$past(irq_src[i]) && !($past(we) && $past(w_addr) == 6'd49 && $past(w_data[i]))) assert (irq_st[i]);
            if (!$past(irq_st[i]) && !$past(irq_src[i])) assert (!irq_st[i]);
        end
        if ($past(|viol)) assert (irq_st[7]);
    end
endmodule
