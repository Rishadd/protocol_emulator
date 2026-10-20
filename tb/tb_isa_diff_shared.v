`timescale 1ns/1ps
// Differential-test harness for the shared instruction memory (compile with -DFUNCTIONAL -DSHARED_IMEM): imem_shared (the 2P 512x32 macro) and
// two engine_top, started from their own START addresses, run back to back for many (image, stimulus) pairs; one trace line per engine per clock.
// host/isa_diff_shared.py makes the inputs, runs host/isa_model.py on the same inputs and compares every line.
//   +IMG=<hex>   nt*512 words of shared memory per test      +START=<hex>  nt words {7'b0, start1[8:0], 7'b0, start0[8:0]}
//   +STIM0=<hex> / +STIM1=<hex>  nt*cyc 48-bit words each {pin_in[7:0], 6'b0, tx_wr, rx_rd, tx_data[31:0]}
//   +NT=<tests>  +CYC=<clocks per test>    +OUT=<trace file>
// Trace line (after each clock edge, engine 0 then engine 1): pc pin_out pin_oe {halted fault tx_full rx_empty} rx_head osr isr lc crc zn c r0..r7
module tb_isa_diff_shared;
    localparam NTMAX = 400, CYCMAX = 600;
    reg         clk = 0, rst_n = 0;
    reg  [1:0]  run = 2'b00;
    reg  [8:0]  start0 = 0, start1 = 0;

    // ------------------------------------------------------------------ the shared memory and the two fetch paths
    wire [8:0]  im_addr0, im_addr1;
    wire [31:0] raw0, raw1;
    wire        oob0, oob1, rg_go0, rg_go1, lk0, lk1;
    wire [18:0] rg_val0, rg_val1;

    imem_shared imem (
        .clk(clk), .rst_n(rst_n), .run(run),
        .f_addr0(im_addr0), .f_addr1(im_addr1), .f_raw0(raw0), .f_raw1(raw1), .f_oob0(oob0), .f_oob1(oob1),
        .rg_go0(rg_go0), .rg_go1(rg_go1), .rg_val0(rg_val0), .rg_val1(rg_val1), .locked0(lk0), .locked1(lk1),
        .iw_wr(1'b0), .iw_addr(9'd0), .iw_data(32'd0), .iw_ok(),
        .ir_rd(1'b0), .ir_data(), .ir_valid(), .region0(), .region1());

    // ------------------------------------------------------------------ the engines
    reg         tx_wr0 = 0, rx_rd0 = 0, tx_wr1 = 0, rx_rd1 = 0;
    reg  [31:0] txd0 = 0, txd1 = 0;
    reg  [7:0]  pin0 = 0, pin1 = 0;
    wire [31:0] rxd0, rxd1;
    wire        txf0, txf1, rxe0, rxe1, hlt0, hlt1, flt0, flt1;
    wire [7:0]  po0, po1, oe0, oe1;
    wire [8:0]  pc0, pc1;

    engine_top e0 (
        .clk(clk), .rst_n(rst_n), .run(run[0]),
        .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .im_addr(im_addr0), .im_instr(raw0), .im_oob(oob0), .rg_go(rg_go0), .rg_val(rg_val0), .rg_locked(lk0), .start_pc(start0),
        .tx_wr_en(tx_wr0), .tx_wr_data(txd0), .tx_full(txf0),
        .rx_rd_en(rx_rd0), .rx_rd_data(rxd0), .rx_empty(rxe0),
        .pin_in(pin0), .pin_out(po0), .pin_oe(oe0), .halted(hlt0), .fault(flt0), .pc(pc0));
    engine_top e1 (
        .clk(clk), .rst_n(rst_n), .run(run[1]),
        .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .im_addr(im_addr1), .im_instr(raw1), .im_oob(oob1), .rg_go(rg_go1), .rg_val(rg_val1), .rg_locked(lk1), .start_pc(start1),
        .tx_wr_en(tx_wr1), .tx_wr_data(txd1), .tx_full(txf1),
        .rx_rd_en(rx_rd1), .rx_rd_data(rxd1), .rx_empty(rxe1),
        .pin_in(pin1), .pin_out(po1), .pin_oe(oe1), .halted(hlt1), .fault(flt1), .pc(pc1));

    reg [31:0] img   [0:NTMAX*512-1];
    reg [31:0] strt  [0:NTMAX-1];
    reg [47:0] stim0 [0:NTMAX*CYCMAX-1];
    reg [47:0] stim1 [0:NTMAX*CYCMAX-1];
    reg [8*256-1:0] imgf, stf, s0f, s1f, of;
    integer nt, cyc, t, c, a, fo;
    reg [47:0] s0, s1;

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    initial begin
        if (!$value$plusargs("IMG=%s", imgf) || !$value$plusargs("START=%s", stf) || !$value$plusargs("STIM0=%s", s0f) ||
            !$value$plusargs("STIM1=%s", s1f) || !$value$plusargs("OUT=%s", of)) begin
            $display("RESULT tb_isa_diff_shared: FAIL (need +IMG +START +STIM0 +STIM1 +OUT)"); $finish;
        end
        if (!$value$plusargs("NT=%d", nt)) nt = 1;
        if (!$value$plusargs("CYC=%d", cyc)) cyc = 100;
        $readmemh(imgf, img);
        $readmemh(stf, strt);
        $readmemh(s0f, stim0);
        $readmemh(s1f, stim1);
        fo = $fopen(of, "w");
        for (t = 0; t < nt; t = t + 1) begin
            run = 2'b00; rst_n = 0; tx_wr0 = 0; rx_rd0 = 0; tx_wr1 = 0; rx_rd1 = 0; pin0 = 0; pin1 = 0;
            start0 = strt[t][8:0]; start1 = strt[t][24:16];
            tick; tick; rst_n = 1; tick;
            for (a = 0; a < 512; a = a + 1) imem.poke(a, img[t * 512 + a]);
            tick; tick; tick;                      // the held engines re-read their start words
            for (c = 0; c < cyc; c = c + 1) begin
                s0 = stim0[t * cyc + c]; s1 = stim1[t * cyc + c];
                pin0 = s0[47:40]; tx_wr0 = s0[33]; rx_rd0 = s0[32]; txd0 = s0[31:0];
                pin1 = s1[47:40]; tx_wr1 = s1[33]; rx_rd1 = s1[32]; txd1 = s1[31:0];
                run = 2'b11;
                tick;
                $fdisplay(fo, "%h %h %h %b%b%b%b %h %h %h %h %h %b%b%b %h %h %h %h %h %h %h %h", pc0, po0, oe0,
                          hlt0, flt0, txf0, rxe0, rxe0 ? 32'd0 : rxd0,
                          e0.osr.data, e0.isr.data, e0.lc.count, e0.crc.value,
                          e0.alu.flag_z, e0.alu.flag_n, e0.alu.flag_c,
                          e0.alu.r[0], e0.alu.r[1], e0.alu.r[2], e0.alu.r[3], e0.alu.r[4], e0.alu.r[5], e0.alu.r[6], e0.alu.r[7]);
                $fdisplay(fo, "%h %h %h %b%b%b%b %h %h %h %h %h %b%b%b %h %h %h %h %h %h %h %h", pc1, po1, oe1,
                          hlt1, flt1, txf1, rxe1, rxe1 ? 32'd0 : rxd1,
                          e1.osr.data, e1.isr.data, e1.lc.count, e1.crc.value,
                          e1.alu.flag_z, e1.alu.flag_n, e1.alu.flag_c,
                          e1.alu.r[0], e1.alu.r[1], e1.alu.r[2], e1.alu.r[3], e1.alu.r[4], e1.alu.r[5], e1.alu.r[6], e1.alu.r[7]);
            end
        end
        $fclose(fo);
        $display("RESULT tb_isa_diff_shared: DONE (%0d tests x %0d clocks x 2 engines)", nt, cyc);
        $finish;
    end
endmodule
