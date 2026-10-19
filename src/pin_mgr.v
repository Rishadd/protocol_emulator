// Pin manager: every pin except the management link can be used by either engine (docs/PIN_MAP_PLAN.md).
// Each engine keeps 8 logical pins (the ISA's 3-bit pin fields); this module maps them onto physical pins.
//
// Outputs: 15 output-capable physical pins, uio[7:0] (pads with an enable) and uo_out[7:1] (always driven).
//   * owner per pin: 0 none / default function, 1 engine 0, 2 engine 1 (3 refused). Reset = none.
//   * remap (3 bits): the pin carries logical pin (index XOR remap) of its owner, index = p for uio[p], k for uo_out[k].
//     0 = identity, so a register value written before remapping existed keeps its meaning.
//   * only the owner's enable/data reach the pin. uio: open-drain option (od = 1: data forced 0, enable = oe & ~out).
//     uo_out has no enable: an owned uo pin shows oe & out; a pin with owner 0 shows its default function
//     (uo_dflt: IRQ on uo_out[1], debug view on uo_out[7:2]).
//   * a pin cannot be reconfigured while its current owner runs.
// Inputs: per engine and logical pin an input select isel[3:0] over the 13 input pins {ui_in[7:3], uio[7:0]}
//   (0..7 = uio[0..7], 8..12 = ui_in[3..7]). Reset: isel = i. Changed only while that engine is held.
// HOLD (ui_in[3], when MISC.hold_en): high = every engine-driven pin released in the same clock (after a 2-flop
//   synchroniser); the management controller also clears both RUN bits. Active high so that an undriven / pulled-down
//   input (the Tiny Tapeout board default) lets the chip run.
// viol: sticky, {engine 1, engine 0} per logical pin: set when a running engine enables a logical pin that no
//   pin owned by it carries. Write-one-to-clear; a new violation wins over a clear.
// IRQ (default function of uo_out[1]): OR of (irq_st & mask); irq_st is sticky, write-one-to-clear.
//
// Register window 0x0200..0x02FF, word index a = addr[7:2]:
//   a 0..7    0x0200+4p  PAD p (uio[p])    [1:0] owner  [2] od  [5:3] remap
//   a 8       0x0220     VIOL              [15:0] {viol1, viol0}, W1C
//   a 17..23  0x0240+4k  OPAD k (uo_out[k], k = 1..7)  [1:0] owner  [5:3] remap   ([2] reserved, uo has no open-drain)
//   a 32..47  0x0280+0x20*e+4*i  ISEL engine e, logical pin i  [3:0] input 0..12
//   a 48      0x02C0     MISC  [0] hold_en (reset 1)  [1] trig_en (reset 1)  [2] dbg_en (reset 1)
//                              [6:4] debug view used when dbg_en = 0  [31:16] IRQ mask (reset 0)
//                              [2:0] cannot change while an engine runs
//   a 49      0x02C4     IRQ   [15:0] status, W1C: [0] RX data e0 [1] RX data e1 [2] halted e0 [3] halted e1
//                              [4] fault e0 [5] fault e1 [6] management error [7] pin violation  ([15:8] reserved)
//   a 50      0x02C8     INPUTS (read only)  [7:0] uio_in  [12:8] ui_in[7:3]  [13] hold active
// w_hit: the write-port address is a register (readable); w_ok: a write of w_data to it is permitted now.
// The management controller registers its write strobe one clock after the check (applies only if w_ok was 1).
module pin_mgr (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  run,
    // configuration (management)
    input  wire [5:0]  w_addr,
    input  wire [31:0] w_data,
    output wire        w_hit,
    output wire        w_ok,
    input  wire        we,
    input  wire [5:0]  r_addr,
    output reg  [31:0] r_data,
    // engines (logical pins)
    input  wire [7:0]  oe0, out0, oe1, out1,
    output wire [7:0]  in0, in1,
    // physical pins
    input  wire [7:0]  uio_in,
    input  wire [4:0]  ui_hi,        // ui_in[7:3]
    output wire [7:0]  uio_oe,
    output wire [7:0]  uio_out,
    output wire [6:0]  uo_hi,        // uo_out[7:1]
    input  wire [5:0]  view,         // debug view bits for uo_out[7:2]
    // status and controls
    input  wire [6:0]  irq_src,      // IRQ status bits [6:0]
    output wire        hold,
    output wire        trig_en,
    output wire [2:0]  view_sel,
    output wire        irq,
    // readback
    output reg  [15:0] owner,        // uio pads, 2 bits per pad
    output reg  [7:0]  od,
    output reg  [23:0] remap,        // uio pads, 3 bits per pad
    output reg  [15:0] oowner,       // uo_out[k], 2 bits per pin at slot k (slot 0 = MISO: never written, stays 0)
    output reg  [23:0] oremap,       // uo_out[k], 3 bits per pin at slot k
    output reg  [31:0] isel0_r,      // engine 0, 4 bits per logical pin
    output reg  [31:0] isel1_r,
    output reg  [15:0] viol,         // {viol1, viol0}
    output reg  [2:0]  misc,         // {dbg_en, trig_en, hold_en}
    output reg  [2:0]  vsel,
    output reg  [15:0] mask,
    output reg  [7:0]  irq_st
);
    reg [1:0]  hold_s;

    assign hold     = misc[0] & hold_s[1];
    assign trig_en  = misc[1];
    assign view_sel = misc[2] ? ui_hi[4:2] : vsel;
    assign irq      = |(irq_st & mask[7:0]);

    // ---------------- outputs
    wire [12:0] in_all = {ui_hi, uio_in};
    reg  [7:0]  map0, map1;          // logical pin carried by some pin owned by that engine
    reg  [7:0]  pad_oe_r, pad_out_r;
    reg  [6:0]  uo_r;
    wire [6:0]  dflt = {view, irq};
    integer p, k;
    reg [2:0] l;
    reg       o0, o1, oe_s, out_s;
    always @(*) begin
        map0 = 8'd0; map1 = 8'd0;
        for (p = 0; p < 8; p = p + 1) begin
            l     = remap[3*p +: 3] ^ p[2:0];
            o0    = (owner[2*p +: 2] == 2'd1);
            o1    = (owner[2*p +: 2] == 2'd2);
            oe_s  = !hold && ((o0 && oe0[l])  || (o1 && oe1[l]));
            out_s = !hold && ((o0 && out0[l]) || (o1 && out1[l]));
            pad_oe_r[p]  = oe_s && !(od[p] && out_s);
            pad_out_r[p] = out_s && !od[p];
            if (o0) map0[l] = 1'b1;
            if (o1) map1[l] = 1'b1;
        end
        for (k = 1; k < 8; k = k + 1) begin
            l  = oremap[3*k +: 3] ^ k[2:0];
            o0 = (oowner[2*k +: 2] == 2'd1);
            o1 = (oowner[2*k +: 2] == 2'd2);
            uo_r[k-1] = (hold || !(o0 || o1)) ? dflt[k-1] :
                        o0 ? (oe0[l] && out0[l]) : (oe1[l] && out1[l]);
            if (o0) map0[l] = 1'b1;
            if (o1) map1[l] = 1'b1;
        end
    end
    assign uio_oe  = pad_oe_r;
    assign uio_out = pad_out_r;
    assign uo_hi   = uo_r;

    // ---------------- inputs
    genvar i;
    generate for (i = 0; i < 8; i = i + 1) begin : g_in
        assign in0[i] = in_all[isel0_r[4*i +: 4]];
        assign in1[i] = in_all[isel1_r[4*i +: 4]];
    end endgenerate

    // ---------------- register window
    wire       a_pad  = (w_addr[5:3] == 3'd0);
    wire       a_viol = (w_addr == 6'd8);
    wire       a_opad = (w_addr[5:3] == 3'd2) && (w_addr[2:0] != 3'd0);
    wire       a_isel = (w_addr[5:4] == 2'd2);
    wire       a_misc = (w_addr == 6'd48);
    wire       a_irq  = (w_addr == 6'd49);
    wire       a_inp  = (w_addr == 6'd50);
    wire [2:0] wi     = w_addr[2:0];
    wire       w_e    = w_addr[3];                       // ISEL engine
    wire [1:0] cur_u  = owner[2*wi +: 2];
    wire [1:0] cur_o  = oowner[2*wi +: 2];
    wire [1:0] cur    = a_pad ? cur_u : cur_o;
    wire       own_ok = (w_data[1:0] != 2'd3) && !(cur == 2'd1 && run[0]) && !(cur == 2'd2 && run[1]);

    assign w_hit = a_pad | a_viol | a_opad | a_isel | a_misc | a_irq | a_inp;
    assign w_ok  = a_pad  ? (w_data[31:6] == 26'd0 && own_ok) :
                   a_opad ? (w_data[31:6] == 26'd0 && !w_data[2] && own_ok) :
                   a_viol ? (w_data[31:16] == 16'd0) :
                   a_isel ? (w_data[31:4] == 28'd0 && w_data[3:0] <= 4'd12 && !run[w_e]) :
                   a_misc ? (w_data[15:7] == 9'd0 && !w_data[3] && (run == 2'b00 || w_data[2:0] == misc)) :
                   a_irq  ? (w_data[31:16] == 16'd0) : 1'b0;

    // read port (its own address: the management controller reads before the write data has arrived)
    wire [2:0] ri = r_addr[2:0];
    always @(*) begin
        r_data = 32'd0;
        if (r_addr[5:3] == 3'd0)                          r_data = {26'd0, remap[3*ri +: 3], od[ri], owner[2*ri +: 2]};
        else if (r_addr == 6'd8)                          r_data = {16'd0, viol};
        else if (r_addr[5:3] == 3'd2 && ri != 3'd0)       r_data = {26'd0, oremap[3*ri +: 3], 1'b0, oowner[2*ri +: 2]};
        else if (r_addr[5:4] == 2'd2)                     r_data = {28'd0, r_addr[3] ? isel1_r[4*ri +: 4] : isel0_r[4*ri +: 4]};
        else if (r_addr == 6'd48)                         r_data = {mask, 9'd0, vsel, 1'b0, misc};
        else if (r_addr == 6'd49)                         r_data = {24'd0, irq_st};
        else if (r_addr == 6'd50)                         r_data = {18'd0, hold, ui_hi, uio_in};
    end

    wire [15:0] viol_clr = (we && a_viol) ? w_data[15:0] : 16'd0;
    wire [7:0]  irq_clr  = (we && a_irq)  ? w_data[7:0]  : 8'd0;
    integer n;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            owner   <= 16'd0;
            od      <= 8'd0;
            remap   <= 24'd0;
            oowner  <= 16'd0;
            oremap  <= 24'd0;
            for (n = 0; n < 8; n = n + 1) begin
                isel0_r[4*n +: 4] <= n[3:0];
                isel1_r[4*n +: 4] <= n[3:0];
            end
            viol    <= 16'd0;
            misc    <= 3'b111;
            vsel    <= 3'd0;
            mask    <= 16'd0;
            irq_st  <= 8'd0;
            hold_s  <= 2'b00;
        end else begin
            hold_s <= {hold_s[0], ui_hi[0]};
            if (we && a_pad) begin
                owner[2*wi +: 2] <= w_data[1:0];
                od[wi]           <= w_data[2];
                remap[3*wi +: 3] <= w_data[5:3];
            end
            if (we && a_opad) begin
                oowner[2*wi +: 2] <= w_data[1:0];
                oremap[3*wi +: 3] <= w_data[5:3];
            end
            if (we && a_isel && !w_e) isel0_r[4*wi +: 4] <= w_data[3:0];
            if (we && a_isel &&  w_e) isel1_r[4*wi +: 4] <= w_data[3:0];
            if (we && a_misc) begin
                misc <= w_data[2:0];
                vsel <= w_data[6:4];
                mask <= w_data[31:16];
            end
            viol   <= (viol & ~viol_clr) | {oe1 & ~map1 & {8{run[1]}}, oe0 & ~map0 & {8{run[0]}}};
            irq_st <= (irq_st & ~irq_clr) | {|viol, irq_src};
        end
    end
endmodule
