`timescale 1ns/1ps
`include "isa.vh"
// The protocol testbench of tb_proto.v on the FULL chip (tt_um_protocol_emulator): the host reaches the engines only through the
// management SPI link - claim pads, load the programs, RUN, write TX words, read RX words - so a whole protocol suite can be run
// against the real top level (host/proto_lib.py switches to this bench with PROTO_CHIP=1). Same plusargs and log format as tb_proto:
//   +PROG0/+PROG1=<hex>  programs      +HTX0/+HTX1=<hex> +N0/+N1=<n>  host TX words      +OD=<hex>  pads claimed open-drain
//   +OWN0/+OWN1=<hex>    pads claimed by engine 0 / 1 (default: all pads for engine 0, or for engine 1 when it is the only one with a program)
//   +EXT=<hex> +STIM=<file> +WAND=<hex> +PEER=<n> +DUR_NS=<n> +OUT=<log> +MGMT_HALF_NS=<n>
//   +OLOC=<8 hex digits>  physical output pin of each logical pin l (nibble l): 0-7 = uio[p], 8-14 = uo_out[nibble-7], F = none (default 76543210: identity)
//   +ILOC=<8 hex digits>  physical input pin of each logical pin (nibble l): 0-7 = uio[p], 8-12 = ui_in[nibble-5] (default 76543210)
// The 'pad' bus of the log is the LOGICAL pin bus (what the peers and decoders see); the board wiring between it and the physical pins is
// modelled here: the physical pin carrying logical pin l as output is wired to the same net as the input pin chosen for l.
// All times in the log are relative to the moment both engines have been started (RUN written), the stimulus file is applied from there.
// Log: P <ns> <pads hex> on every pad change, A/B <ns> <word hex> for every word read from engine 0 / 1,
//      END cyc= fault0= fault1= halted0= halted1= pc0= pc1= contend= frames= err= viol= retries=
module tb_chip_proto;
    localparam [7:0]  OP_WR = 8'h01, OP_RD = 8'h02;
    localparam [31:0] W_HALT = {`OP_HALT, 27'd0};

    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 200.0, spi_cs_ns = 120.0;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];

    reg  [7:0] ext_mask = 0, ext_val = 8'hFF, wand_mask = 0;
    integer    peer = 0, contend = 0;
    wire [7:0] pad, peer_low;
    reg [31:0] oloc = 32'h76543210, iloc = 32'h76543210;
    reg  [7:0] ch_low, ch_hi, uio_in_v;      // what the chip drives low / high on each logical pin; the physical uio input nodes
    reg  [4:0] ui_hi_v;                       // ui_in[7:3] nodes
    reg  [3:0] oc, ic;
    integer    lg;
    // built in temporaries and assigned once: zeroing the nodes first would glitch the chip's inputs in zero time, and
    // with Icarus 13 that glitch re-triggers this block through the pin manager forever (remapped JTAG hung at 10 ns)
    reg  [7:0] t_low, t_hi, t_uio;
    reg  [4:0] t_ui;
    always @* begin
        t_low = 8'd0; t_hi = 8'd0; t_uio = 8'd0; t_ui = 5'd0;
        for (lg = 0; lg < 8; lg = lg + 1) begin
            if (oloc[4*lg +: 4] < 8) begin
                t_low[lg] = uio_oe[oloc[4*lg +: 4]] & ~uio_out[oloc[4*lg +: 4]];
                t_hi[lg]  = uio_oe[oloc[4*lg +: 4]] & uio_out[oloc[4*lg +: 4]];
                t_uio[oloc[4*lg +: 4]] = pad[lg];
            end else if (oloc[4*lg +: 4] < 15) begin     // uo_out has no output enable: the pin shows oe & out of the engine
                t_low[lg] = ~uo_out[oloc[4*lg +: 4] - 7];
                t_hi[lg]  = uo_out[oloc[4*lg +: 4] - 7];
            end
            if (iloc[4*lg +: 4] < 8) t_uio[iloc[4*lg +: 4]] = pad[lg];
            else if (iloc[4*lg +: 4] < 13) t_ui[iloc[4*lg +: 4] - 8] = pad[lg];
        end
        ch_low = t_low; ch_hi = t_hi; uio_in_v = t_uio; ui_hi_v = t_ui;
    end
    wire [7:0] low_any = ch_low | peer_low;
    wire [7:0] hi_any  = ch_hi;
    // 1 ns on the pad net: a pin wired back to another pin (uo_out to ui_in in the remapped runs) closes a loop through the chip's debug view
    // select (ui_in[7:5]) while the pins are still unclaimed; without a delay Icarus 13 spins in zero time at 10 ns
    assign #1 pad = (ext_mask & ext_val) | (~ext_mask & ~low_any & (ext_val | ~wand_mask));
    always @(pad) if ((hi_any & low_any & ~ext_mask) != 0) contend = contend + 1;

    tt_um_protocol_emulator dut (
        .ui_in({ui_hi_v, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in(uio_in_v), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));
    peer_models pm (.pad(pad), .peer_sel(peer[7:0]), .peer_low(peer_low));

    `include "spi_master.vh"

    reg [8*256-1:0] p0f, p1f, h0f, h1f, sf, outf;
    reg [31:0] htx0 [0:8191];
    reg [31:0] htx1 [0:8191];
    reg [31:0] img0 [0:255];
    reg [31:0] img1 [0:255];
    integer n0 = 0, n1 = 0, sent0 = 0, sent1 = 0, dur = 1000000, half = 200, fd, k, e, p, nimg;
    integer cyc = 0, frames = 0, retries = 0;
    integer t_run = 0, running = 0;
    integer stim_fd, st_n, st_t;
    reg [7:0] od = 0, own0 = 0, own1 = 0;
    reg       has0 = 0, has1 = 0;
    reg [7:0]  st = 8'd0;
    reg [15:0] mid;
    reg [31:0] rd, st_val;

    always #10 clk = ~clk;
    always @(posedge clk) cyc = cyc + 1;
    always @(pad) if (running) $fdisplay(fd, "P %0d %h", $time - t_run, pad);

    task frame(input [7:0] op, input [15:0] a, input [31:0] d);
        begin
            spi_begin; spi_bits({72'd0, op, a, d}, 56); spi_end;
            {st, mid, rd} = spi_rx[55:0];
            frames = frames + 1;
        end
    endtask

    task load(input integer eng, input integer last);
        reg [15:0] base;
        begin
            base = eng ? 16'h2000 : 16'h1000;
            for (k = 0; k < last; k = k + 1) frame(OP_WR, base + 16'h400 + 4 * k, eng ? img1[k] : img0[k]);
        end
    endtask

    task image_len(input integer eng, output integer len);
        begin
            len = 256;
            while (len > 1 && (eng ? img1[len - 1] : img0[len - 1]) === W_HALT) len = len - 1;
            if (len < 256) len = len + 1;                         // the program plus one HALT word behind it
        end
    endtask

    // external stimulus from the Python waveform, relative to the start of the run
    initial begin : stim
        wait (running);
        if ($value$plusargs("STIM=%s", sf)) begin
            stim_fd = $fopen(sf, "r");
            while (!$feof(stim_fd)) begin
                st_n = $fscanf(stim_fd, "%d %h", st_t, st_val);
                if (st_n == 2) begin
                    if (t_run + st_t > $time) #(t_run + st_t - $time);
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
        if ($value$plusargs("MGMT_HALF_NS=%d", half)) ;
        spi_half_ns = half;
        has0 = $value$plusargs("PROG0=%s", p0f);
        has1 = $value$plusargs("PROG1=%s", p1f);
        if ($value$plusargs("HTX0=%s", h0f)) $readmemh(h0f, htx0);
        if ($value$plusargs("HTX1=%s", h1f)) $readmemh(h1f, htx1);
        own0 = has0 ? 8'hFF : 8'h00;                              // default: engine 0 owns every pad, engine 1 only listens
        own1 = (has1 && !has0) ? 8'hFF : 8'h00;
        if ($value$plusargs("OWN0=%h", k)) own0 = k[7:0];
        if ($value$plusargs("OWN1=%h", k)) own1 = k[7:0];
        if ($value$plusargs("OLOC=%h", k)) oloc = k;
        if ($value$plusargs("ILOC=%h", k)) iloc = k;
        for (k = 0; k < 256; k = k + 1) begin img0[k] = W_HALT; img1[k] = W_HALT; end
        if (has0) $readmemh(p0f, img0);
        if (has1) $readmemh(p1f, img1);

        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk);
        // claim the physical pin that carries each logical pin (remap field = logical pin XOR physical pin index)
        for (p = 0; p < 8; p = p + 1) begin
            oc = oloc[4*p +: 4];
            for (e = 0; e < 2; e = e + 1) if (e ? own1[p] : own0[p]) begin
                if (oc < 8) frame(OP_WR, 16'h0200 + 4 * oc, (e + 1) | (od[p] ? 32'd4 : 32'd0) | (((p ^ oc) & 7) << 3));
                else        frame(OP_WR, 16'h0240 + 4 * (oc - 7), (e + 1) | (((p ^ (oc - 7)) & 7) << 3));
            end
        end
        // input select of both engines, only where it differs from the reset identity
        for (p = 0; p < 8; p = p + 1) begin
            ic = iloc[4*p +: 4];
            if (ic != p) begin
                frame(OP_WR, 16'h0280 + 4 * p, ic);
                frame(OP_WR, 16'h02A0 + 4 * p, ic);
            end
            if (ic == 8) frame(OP_WR, 16'h02C0, 32'h6);          // ui_in[3] is the HOLD pin by default: here it is a protocol input
        end
        if (has0) begin image_len(0, nimg); load(0, nimg); end
        if (has1) begin image_len(1, nimg); load(1, nimg); end
        if (has0) frame(OP_WR, 16'h1000, 32'd1);                  // RUN
        if (has1) frame(OP_WR, 16'h2000, 32'd1);
        t_run = $time;
        running = 1;
        $fdisplay(fd, "P 0 %h", pad);

        while ($time - t_run < dur) begin
            // drain RX first (the last status says which engine has data), then feed TX, otherwise poll
            if (has0 && st[0]) begin
                frame(OP_RD, 16'h1204, 32'd0);
                if (st[0]) $fdisplay(fd, "A %0d %h", $time - t_run, rd);
            end else if (has1 && st[1]) begin
                frame(OP_RD, 16'h2204, 32'd0);
                if (st[1]) $fdisplay(fd, "B %0d %h", $time - t_run, rd);
            end else if (has0 && sent0 < n0) begin
                frame(OP_WR, 16'h1200, htx0[sent0]);
                if (!st[2]) sent0 = sent0 + 1; else retries = retries + 1;
            end else if (has1 && sent1 < n1) begin
                frame(OP_WR, 16'h2200, htx1[sent1]);
                if (!st[3]) sent1 = sent1 + 1; else retries = retries + 1;
            end else begin
                frame(OP_RD, has0 ? 16'h1204 : 16'h2204, 32'd0);        // poll (also refreshes the status)
                if (has0 && st[0]) $fdisplay(fd, "A %0d %h", $time - t_run, rd);
                else if (!has0 && st[1]) $fdisplay(fd, "B %0d %h", $time - t_run, rd);
            end
        end
        $fdisplay(fd, "END cyc=%0d fault0=%0d fault1=%0d halted0=%0d halted1=%0d pc0=%0d pc1=%0d contend=%0d frames=%0d err=%0d viol=%0d retries=%0d",
                  cyc, dut.fault[0], dut.fault[1], dut.halted[0], dut.halted[1], dut.pc0, dut.pc1, contend, frames,
                  dut.u_mgmt.err, dut.u_pins.viol, retries);
        $fclose(fd);
        $finish;
    end
endmodule
