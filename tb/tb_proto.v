`timescale 1ns/1ps
`include "isa.vh"
// Generic protocol testbench: two engine_top instances on one 8-pin pad bus, orchestrated by host/proto_lib.py.
//   +PROG0=<hex> +PROG1=<hex>   programs (an engine without a program is not run)
//   +HTX0=<hex> +N0=<n> +HTX1=<hex> +N1=<n>   host TX words per engine (fed whenever the TX FIFO has room), +TXGAP0_NS/+TXGAP1_NS between words,
//                                              +T0START_NS/+T1START_NS earliest time of the first word
//   +OD=<hex>    pins that are open-drain (an engine's output 1 releases the line; the bus has pull-ups)
//   +EXT=<hex> +STIM=<file>   pins driven from outside by the Python waveform: file lines "<time_ns> <pins hex>", sorted by time
//   +WAND=<hex>  pins on which the Python waveform is one more open-drain driver of a wired-AND bus (pad = waveform AND NOT engine pulls),
//                so an engine can pull the line low while the waveform is recessive (CAN ACK slot); no +EXT needed for these pins
//   +PEER=<n>    Verilog peer model on the bus (see tb/peer_*.v), 0 = none
//   +LOOP=<hex>  pins on which engine 0's output is wired into the pad even without OD (default: both engines drive their pins)
//   +DUR_NS=<n>  simulated time;  +OUT=<log>
// Log: P <ns> <pads hex> on every pad change; A/B <ns> <word hex> for every word the host reads from engine 0 / 1; END ...
// Pad resolution per pin: any engine pulling low (or open-drain 0) -> 0; else a push-pull driver at 1 -> 1; else pulled up -> 1.
module tb_proto;
    // waveform: run vvp with +dump to write build/wave/tb_proto.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_proto.vcd"); $dumpvars(0, tb_proto); end
    reg         clk = 0, rst_n = 0;
    reg  [1:0]  run = 2'b00;
    reg         tx0_wr = 0, tx1_wr = 0, rx0_rd = 0, rx1_rd = 0;
    reg  [31:0] tx0_data = 0, tx1_data = 0;
    wire [31:0] rx0_data, rx1_data;
    wire        tx0_full, tx1_full, rx0_empty, rx1_empty, halted0, halted1, fault0, fault1;
    wire [7:0]  o0, oe0, o1, oe1, pc0, pc1;
    wire [7:0]  pad;
    wire [7:0]  peer_low;

    reg  [7:0]  od = 0, ext_mask = 0, ext_val = 8'hFF, wand_mask = 0;
    integer     peer = 0, contend = 0;

    wire [7:0] low0  = oe0 & ~o0, low1 = oe1 & ~o1;
    wire [7:0] hi0   = oe0 & o0 & ~od, hi1 = oe1 & o1 & ~od;
    wire [7:0] low_any = low0 | low1 | peer_low;
    wire [7:0] hi_any  = hi0 | hi1;
    assign pad = (ext_mask & ext_val) | (~ext_mask & ~low_any & (ext_val | ~wand_mask));   // pulled up; pulled low by any driver
    always @(pad) if ((hi_any & low_any & ~ext_mask) != 0) contend = contend + 1;

    engine_top e0 (.clk(clk), .rst_n(rst_n), .run(run[0]), .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .tx_wr_en(tx0_wr), .tx_wr_data(tx0_data), .tx_full(tx0_full), .rx_rd_en(rx0_rd), .rx_rd_data(rx0_data),
        .rx_empty(rx0_empty), .pin_in(pad), .pin_out(o0), .pin_oe(oe0), .halted(halted0), .fault(fault0), .pc(pc0));
    engine_top e1 (.clk(clk), .rst_n(rst_n), .run(run[1]), .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .tx_wr_en(tx1_wr), .tx_wr_data(tx1_data), .tx_full(tx1_full), .rx_rd_en(rx1_rd), .rx_rd_data(rx1_data),
        .rx_empty(rx1_empty), .pin_in(pad), .pin_out(o1), .pin_oe(oe1), .halted(halted1), .fault(fault1), .pc(pc1));

    // peer models (selected with +PEER); each drives peer_low (open-drain pulls) from the pad levels
    peer_models pm (.pad(pad), .peer_sel(peer[7:0]), .peer_low(peer_low));

    reg [8*256-1:0] p0f, p1f, h0f, h1f, sf, outf;
    reg [31:0] htx0 [0:8191];
    reg [31:0] htx1 [0:8191];
    integer n0 = 0, n1 = 0, i0 = 0, i1 = 0, gap0 = 0, gap1 = 0, t0next = 0, t1next = 0, dur = 1000000, fd, cyc = 0, k;
    integer stim_fd, st, st_t, st_v;
    reg  [31:0] st_val;

    always #10 clk = ~clk;
    always @(posedge clk) cyc = cyc + 1;
    always @(pad) if (fd != 0) $fdisplay(fd, "P %0d %h", $time, pad);

    always @(negedge clk) begin
        tx0_wr = 0; tx1_wr = 0; rx0_rd = 0; rx1_rd = 0;
        if (run[0] && i0 < n0 && !tx0_full && $time >= t0next) begin tx0_wr = 1; tx0_data = htx0[i0]; i0 = i0 + 1; t0next = $time + gap0; end
        if (run[1] && i1 < n1 && !tx1_full && $time >= t1next) begin tx1_wr = 1; tx1_data = htx1[i1]; i1 = i1 + 1; t1next = $time + gap1; end
        if (!rx0_empty) begin rx0_rd = 1; $fdisplay(fd, "A %0d %h", $time, rx0_data); end
        if (!rx1_empty) begin rx1_rd = 1; $fdisplay(fd, "B %0d %h", $time, rx1_data); end
    end

    // external stimulus from the Python waveform
    initial begin : stim
        if ($value$plusargs("STIM=%s", sf)) begin
            stim_fd = $fopen(sf, "r");
            while (!$feof(stim_fd)) begin
                st = $fscanf(stim_fd, "%d %h", st_t, st_val);
                if (st == 2) begin
                    if (st_t > $time) #(st_t - $time);
                    ext_val = st_val[7:0];
                end
            end
            $fclose(stim_fd);
        end
    end

    initial begin
        if (!$value$plusargs("OUT=%s", outf)) begin $display("ERROR: +OUT missing"); $finish; end
        fd = $fopen(outf, "w");
        if ($value$plusargs("OD=%h", k)) od = k[7:0];
        if ($value$plusargs("EXT=%h", k)) ext_mask = k[7:0];
        if ($value$plusargs("WAND=%h", k)) wand_mask = k[7:0];
        if ($value$plusargs("PEER=%d", peer)) ;
        if ($value$plusargs("DUR_NS=%d", dur)) ;
        if ($value$plusargs("N0=%d", n0)) ;
        if ($value$plusargs("N1=%d", n1)) ;
        if ($value$plusargs("TXGAP0_NS=%d", gap0)) ;
        if ($value$plusargs("TXGAP1_NS=%d", gap1)) ;
        if ($value$plusargs("T0START_NS=%d", t0next)) ;      // first host TX word of engine 0 / 1 not before this time
        if ($value$plusargs("T1START_NS=%d", t1next)) ;
        if ($value$plusargs("HTX0=%s", h0f)) $readmemh(h0f, htx0);
        if ($value$plusargs("HTX1=%s", h1f)) $readmemh(h1f, htx1);
        if ($value$plusargs("PROG0=%s", p0f)) e0.imem.load_hex(p0f);
        if ($value$plusargs("PROG1=%s", p1f)) e1.imem.load_hex(p1f);
        $fdisplay(fd, "P %0d %h", $time, pad);
        repeat (4) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk);
        #1 run = {$value$plusargs("PROG1=%s", p1f) ? 1'b1 : 1'b0, $value$plusargs("PROG0=%s", p0f) ? 1'b1 : 1'b0};
        #(dur);
        $fdisplay(fd, "END cyc=%0d fault0=%0d fault1=%0d halted0=%0d halted1=%0d pc0=%0d pc1=%0d contend=%0d",
                  cyc, fault0, fault1, halted0, halted1, pc0, pc1, contend);
        $fclose(fd);
        $finish;
    end
endmodule
