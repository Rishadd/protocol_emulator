`timescale 1ns/1ps
// Differential-test harness for engine_top: runs many (program, stimulus) pairs back to back and writes one trace line per clock.
// host/isa_diff_test.py makes the inputs, runs host/isa_model.py on the same inputs and compares every line.
//   +PROG=<hex>  nt*256 program words      +STIM=<hex>  nt*cyc 48-bit words {pin_in[7:0], 6'b0, tx_wr, rx_rd, tx_data[31:0]}
//   +NT=<tests>  +CYC=<clocks per test>    +OUT=<trace file>
// Trace line (after each clock edge): pc pin_out pin_oe {halted fault tx_full rx_empty} rx_head osr isr lc crc zn c r0..r7
module tb_isa_diff;
    localparam NTMAX = 400, CYCMAX = 600;
    reg         clk = 0, rst_n = 0, run = 0;
    reg         tx_wr_en = 0, rx_rd_en = 0;
    reg  [31:0] tx_wr_data = 0;
    reg  [7:0]  pin_in = 0;
    wire [31:0] rx_rd_data;
    wire        tx_full, rx_empty, halted, fault;
    wire [7:0]  pin_out, pin_oe, pc;

    engine_top dut (
        .clk(clk), .rst_n(rst_n), .run(run),
        .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full),
        .rx_rd_en(rx_rd_en), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in(pin_in), .pin_out(pin_out), .pin_oe(pin_oe),
        .halted(halted), .fault(fault), .pc(pc));

    reg [31:0] prog [0:NTMAX*256-1];
    reg [47:0] stim [0:NTMAX*CYCMAX-1];
    reg [8*256-1:0] pf, sf, of;
    integer nt, cyc, t, c, a, fo;
    reg [47:0] s;

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    initial begin
        if (!$value$plusargs("PROG=%s", pf) || !$value$plusargs("STIM=%s", sf) || !$value$plusargs("OUT=%s", of)) begin
            $display("RESULT tb_isa_diff: FAIL (need +PROG +STIM +OUT)"); $finish;
        end
        if (!$value$plusargs("NT=%d", nt)) nt = 1;
        if (!$value$plusargs("CYC=%d", cyc)) cyc = 100;
        $readmemh(pf, prog);
        $readmemh(sf, stim);
        fo = $fopen(of, "w");
        for (t = 0; t < nt; t = t + 1) begin
            run = 0; rst_n = 0; tx_wr_en = 0; rx_rd_en = 0; pin_in = 0;
            tick; tick; rst_n = 1; tick;
            for (a = 0; a < 256; a = a + 1) dut.imem.poke(a, prog[t * 256 + a]);
            tick; tick; tick;                      // the held engine re-reads word 0
            for (c = 0; c < cyc; c = c + 1) begin
                s = stim[t * cyc + c];
                pin_in = s[47:40]; tx_wr_en = s[33]; rx_rd_en = s[32]; tx_wr_data = s[31:0];
                run = 1;
                tick;
                $fdisplay(fo, "%h %h %h %b%b%b%b %h %h %h %h %h %b%b%b %h %h %h %h %h %h %h %h", pc, pin_out, pin_oe,
                          halted, fault, tx_full, rx_empty, rx_empty ? 32'd0 : rx_rd_data,
                          dut.osr.data, dut.isr.data, dut.lc.count, dut.crc.value,
                          dut.alu.flag_z, dut.alu.flag_n, dut.alu.flag_c,
                          dut.alu.r[0], dut.alu.r[1], dut.alu.r[2], dut.alu.r[3],
                          dut.alu.r[4], dut.alu.r[5], dut.alu.r[6], dut.alu.r[7]);
            end
        end
        $fclose(fo);
        $display("RESULT tb_isa_diff: DONE (%0d tests x %0d clocks)", nt, cyc);
        $finish;
    end
endmodule
