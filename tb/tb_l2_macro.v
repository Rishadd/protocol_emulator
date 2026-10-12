`timescale 1ns/1ps
`include "tb_common.vh"
// Phase 0 (docs/TWO_TIER_MEMORY_PLAN.md V0.1, V0.2): pins down the behaviour of the IHP
// RM_IHPSG13_1P_256x32_c2_bm_bist functional model that the L2 design relies on, and proves the
// abstract memory (formal/abs_sram.v) matches it cycle by cycle.
//   V0.1 1-clock read latency, every address with fixed / walking-1 / address / random patterns,
//        output holds when not reading, write-through, men=0 is a no-op, unwritten word reads X,
//        BIST pins toggling with A_BIST_EN=0 have no effect.
//   V0.2 1,000,000 random operations: vendor model and abs_sram outputs identical every clock.
module tb_l2_macro;
    reg clk = 0;
    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    reg        men = 0, wen = 0, ren = 0;
    reg [7:0]  addr = 0;
    reg [31:0] din = 0;
    reg [7:0]  b_addr = 0;              // BIST pins: random noise, BIST disabled
    reg [31:0] b_din = 0, b_bm = 0;
    reg        b_clk = 0, b_men = 0, b_wen = 0, b_ren = 0;
    wire [31:0] dout, adout;

    RM_IHPSG13_1P_256x32_c2_bm_bist u_m (
        .A_CLK(clk), .A_MEN(men), .A_WEN(wen), .A_REN(ren), .A_ADDR(addr), .A_DIN(din),
        .A_DLY(1'b1), .A_DOUT(dout), .A_BM(32'hFFFFFFFF),
        .A_BIST_CLK(b_clk), .A_BIST_EN(1'b0), .A_BIST_MEN(b_men), .A_BIST_WEN(b_wen), .A_BIST_REN(b_ren),
        .A_BIST_ADDR(b_addr), .A_BIST_DIN(b_din), .A_BIST_BM(b_bm));
    abs_sram #(.AW(8), .DW(32)) u_a (.clk(clk), .men(men), .wen(wen), .ren(ren), .addr(addr), .din(din), .dout(adout));

    integer errors = 0, seed = 7, i, b, n, mism = 0, cmp = 0;
    reg [31:0] model [0:255];
    reg [31:0] held;

    always @(negedge clk) begin          // V0.2: identical outputs every clock (X == X counts as equal)
        cmp = cmp + 1;
        if (dout !== adout) begin mism = mism + 1; if (mism <= 5) $display("  MISMATCH @%0t vendor=%h abs=%h", $time, dout, adout); end
        {b_addr, b_din, b_bm, b_men, b_wen, b_ren} = {$random(seed), $random(seed), $random(seed)};
        b_clk = $random(seed);
    end

    task op(input m, input w, input r, input [7:0] a, input [31:0] d);
        begin men = m; wen = w; ren = r; addr = a; din = d; tick; men = 0; wen = 0; ren = 0; end
    endtask
    task wr(input [7:0] a, input [31:0] d); begin op(1, 1, 0, a, d); model[a] = d; end endtask
    task rd_check(input [7:0] a, input [8*24-1:0] msg);
        begin op(1, 0, 1, a, 0); `CHECK(dout === model[a], msg) end
    endtask
    task fill_check(input integer kind, input [8*24-1:0] msg);   // write every word, then read every word
        begin
            for (i = 0; i < 256; i = i + 1)
                wr(i, kind == 0 ? 32'h0 : kind == 1 ? 32'hFFFFFFFF : kind == 2 ? ((i & 1) ? 32'h55555555 : 32'hAAAAAAAA) :
                      kind == 3 ? ((i & 1) ? 32'hAAAAAAAA : 32'h55555555) : kind == 4 ? {4{i[7:0]}} :
                      kind < 37 ? (32'd1 << (kind - 5)) : $random(seed));
            for (i = 0; i < 256; i = i + 1) rd_check(i, msg);
        end
    endtask

    initial begin
        tick;
        op(1, 0, 1, 8'd17, 0);
        `CHECK(^dout === 1'bx, "never-written word reads X")
        $display("--- V0.1 patterns: all-0, all-1, checkerboard, inverse, address, walking-1 (32), random (3)");
        for (b = 0; b < 40; b = b + 1) fill_check(b, "read = last written word");
        $display("--- V0.1 latency, hold, write-through, men=0");
        wr(8'd5, 32'h12345678); wr(8'd6, 32'hCAFEF00D);
        men = 1; ren = 1; addr = 5; @(posedge clk); #1;
        `CHECK(dout === 32'h12345678, "data valid one clock after the read edge")
        men = 0; ren = 0;
        held = dout;
        for (i = 0; i < 20; i = i + 1) begin addr = $random(seed); din = $random(seed); tick; end
        `CHECK(dout === held, "dout holds while not reading")
        op(1, 0, 0, 8'd6, 0); `CHECK(dout === held, "dout holds on men=1 with ren=wen=0")
        op(1, 1, 1, 8'd9, 32'hA5A5_0001); model[9] = 32'hA5A5_0001;
        `CHECK(dout === 32'hA5A5_0001, "write-through: dout = new data")
        rd_check(9, "write-through stored the word");
        op(0, 1, 0, 8'd9, 32'hDEAD_BEEF);
        rd_check(9, "men=0 write is ignored");
        held = dout; op(0, 0, 1, 8'd6, 0);
        `CHECK(dout === held, "men=0 read leaves dout unchanged")
        $display("--- V0.2 1,000,000 random operations, vendor vs abs_sram");
        for (n = 0; n < 1000000; n = n + 1) begin
            men = ($random(seed) % 8) != 0; wen = $random(seed); ren = $random(seed);
            addr = $random(seed); din = $random(seed); tick;
        end
        $display("compared %0d clocks: %0d mismatches", cmp, mism);
        `CHECK(mism == 0, "V0.2 vendor model == abs_sram every clock")
        `REPORT("tb_l2_macro")
        $finish;
    end
endmodule
