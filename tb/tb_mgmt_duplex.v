`timescale 1ns/1ps
`include "isa.vh"
// Step 8: full-duplex UART through the SPI management link, orchestrated by
// host/mgmt_duplex_stress.py. 10 ns = 1 system clock (firmware only counts cycles).
//
// Host model: loads +PROG0 (UART TX, P0) into engine 0 and +PROG1 (UART RX, P1) into engine 1
// over SPI, sets both RUN bits, then services both directions in one loop:
//   last STATUS said engine 1 has RX data -> READ 0x2204  (valid iff this frame's STATUS bit 1)
//   else bytes left to send               -> WRITE 0x1200 (accepted iff this frame's STATUS bit 2 = 0)
//   else                                  -> READ 0x2204 as a poll
// P1 (RX line) source:
//   +RXEDGES=<file "ns level">  replay: Python-generated waveform (record-then-send-back flow)
//   otherwise                   live: UART echo peer receives each byte on P0 and sends it back
//                               on P1 as soon as its stop bit is sampled (+PEERBIT_PS bit time,
//                               +JITTER_NS edge jitter)
// Plusargs: +PROG0 +PROG1 +PAYLOAD(hex bytes) +N +OUT +SPIHALF_NS +TMAX(cycles after loading) [+BIT(clocks, 434)]
//           [+RXEDGES] [+PEERBIT_PS] [+JITTER_NS] [+STALL_AT +STALL_CYC] [+SEED] [+RXONLY=1: no TX writes]
//           [+RXREL=1: RXEDGES times are relative to the end of program loading]
//           + host workload knobs (host_knobs.vh: +HOSTGAP_NS +ABORT_EVERY +NOISE_EVERY +BURST)
// Log: T <ns> <lvl> (P0 line)  E <ns> <lvl> (P1 line)  W <ns> <byte> (TX accepted)
//      R <ns> <byte> (valid RX read)  STATUS k=v ...
module tb_mgmt_duplex;
    // waveform: run vvp with +dump to write build/wave/tb_mgmt_duplex.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_mgmt_duplex.vcd"); $dumpvars(0, tb_mgmt_duplex); end
    integer            BIT = 434;                   // nominal UART bit, clocks (+BIT=, 5208 = 9600)
    localparam [7:0]   OP_WR = 8'h01, OP_RD = 8'h02;
    localparam [31:0]  W_HALT = {`OP_HALT, 27'd0};

    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 80.0, spi_cs_ns = 60.0;
    reg        p1_line = 1'b1;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];
    wire       p0_line = uio_oe[0] ? uio_out[0] : 1'b1;   // released = pulled high

    tt_um_protocol_emulator dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in({6'd0, p1_line, 1'b0}), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));

    `include "spi_master.vh"
    `include "host_knobs.vh"

    reg [8*256-1:0] prog0_f, prog1_f, pay_f, out_f, rxe_f;
    integer fo, n, tmax, half_ns, peer_bit_ps = BIT * 10 * 1000, jitter_ns = 0;
    integer stall_at = -1, stall_cyc = 0, seed = 1, rxonly = 0, rxrel = 0, loaded_t = -1;
    integer cyc = 0, sent = 0, recv = 0, retries = 0, polls = 0, frames = 0, rx_full_stall = 0;
    reg     replay = 0, live_peer = 1;
    reg [7:0]  pay [0:65535];
    reg [31:0] img [0:255];
    reg [7:0]  st;
    reg [15:0] mid;
    reg [31:0] rd;

    always #5 clk = ~clk;
    always @(posedge clk) cyc = cyc + 1;

    // ---------------------------------------------------------------- line logs (clock-sampled)
    reg p0_prev = 1'bx, p1_prev = 1'bx;
    always @(negedge clk) begin
        if (p0_line !== p0_prev) begin $fdisplay(fo, "T %0d %0d", $time, p0_line); p0_prev = p0_line; end
        if (p1_line !== p1_prev) begin $fdisplay(fo, "E %0d %0d", $time, p1_line); p1_prev = p1_line; end
        if (dut.u_eng1.rx_fifo.full && dut.u_eng1.cu.opcode == `OP_PUSH) rx_full_stall = rx_full_stall + 1;
    end

    // ---------------------------------------------------------------- live UART echo peer
    reg [7:0] pq [0:65535];
    integer   pq_w = 0, pq_r = 0;
    initial begin : peer_rx                          // clock-sampled 8N1 receiver on P0
        integer i; reg [7:0] b; reg prev;
        prev = 1'b1;
        forever begin
            @(posedge clk);
            while (!(prev === 1'b1 && p0_line === 1'b0)) begin prev = p0_line; @(posedge clk); end
            prev = 1'b0;
            repeat (BIT / 2 - 1) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin repeat (BIT) @(posedge clk); b[i] = p0_line; end
            repeat (BIT) @(posedge clk);             // mid stop bit: byte complete, echo it now
            pq[pq_w] = b; pq_w = pq_w + 1;
        end
    end
    initial begin : peer_tx                          // sends queued bytes back on P1
        integer k, jit; reg [9:0] bits; real t0, bit_ns, tgt;
        #1;
        if (live_peer) begin
            bit_ns = peer_bit_ps / 1000.0;
            forever begin
                wait (pq_r < pq_w);
                bits = {1'b1, pq[pq_r], 1'b0};       // stop, data[7:0], start (sent LSB first)
                t0 = $realtime;
                for (k = 0; k < 10; k = k + 1) begin
                    // via a 32-bit integer on purpose: used directly in a real expression the
                    // unsigned mix turns -j into ~4.29e9 ns
                    jit = (k == 0 || jitter_ns == 0) ? 0 :
                          (($random(seed) & 32'h7fff_ffff) % (2 * jitter_ns + 1)) - jitter_ns;
                    tgt = t0 + k * bit_ns + jit;
                    if (tgt > $realtime) #(tgt - $realtime);
                    p1_line = bits[k];
                end
                tgt = t0 + 10 * bit_ns;
                if (tgt > $realtime) #(tgt - $realtime);
                pq_r = pq_r + 1;
            end
        end
    end

    // ---------------------------------------------------------------- replay P1 from a file
    initial begin : replay_rx
        integer fe, r, t, l;
        #1;
        if (replay) begin
            if (rxrel) wait (loaded_t >= 0);
            fe = $fopen(rxe_f, "r");
            while (!$feof(fe)) begin
                r = $fscanf(fe, "%d %d\n", t, l);
                if (r == 2) begin
                    if (rxrel) t = t + loaded_t;               // +RXREL=1: times count from LOADED
                    if (t > $time) #(t - $time);
                    p1_line = l[0];
                end
            end
            $fclose(fe);
        end
    end

    // ---------------------------------------------------------------- host model
    task frame(input [7:0] op, input [15:0] a, input [31:0] d);
        begin
            host_extra((a[15:12] == 4'h2) ? 16'h2000 : 16'h1000);    // workload knobs (host_knobs.vh)
            spi_begin; spi_bits({72'd0, op, a, d}, 56); spi_end;
            {st, mid, rd} = spi_rx[55:0];
            frames = frames + 1;
        end
    endtask

    task load(input [15:0] base, input [8*256-1:0] file);
        integer j, nimg;
        begin
            for (j = 0; j < 256; j = j + 1) img[j] = W_HALT;
            $readmemh(file, img);
            nimg = 256; while (nimg > 1 && img[nimg - 1] === W_HALT) nimg = nimg - 1;   // load the program, not the HALT filler
            if (nimg < 256) nimg = nimg + 1;                                            // plus one HALT word after it
            frame(OP_WR, base, 32'd0);                              // RUN = 0
            for (j = 0; j < nimg; j = j + 1) frame(OP_WR, base + 16'h400 + 4 * j, img[j]);
        end
    endtask

    integer last_progress, stalled;
    reg     want_rx;
    initial begin
        if (!$value$plusargs("PROG0=%s", prog0_f) || !$value$plusargs("PROG1=%s", prog1_f) ||
            !$value$plusargs("PAYLOAD=%s", pay_f) || !$value$plusargs("N=%d", n) ||
            !$value$plusargs("OUT=%s", out_f) || !$value$plusargs("TMAX=%d", tmax) ||
            !$value$plusargs("SPIHALF_NS=%d", half_ns)) begin
            $display("ERROR: missing plusargs"); $finish;
        end
        replay    = $value$plusargs("RXEDGES=%s", rxe_f);
        live_peer = !replay;
        if ($value$plusargs("BIT=%d", BIT)) ;
        if (!$value$plusargs("PEERBIT_PS=%d", peer_bit_ps)) peer_bit_ps = BIT * 10 * 1000;
        if ($value$plusargs("JITTER_NS=%d", jitter_ns)) ;
        if ($value$plusargs("STALL_AT=%d", stall_at)) ;
        if ($value$plusargs("STALL_CYC=%d", stall_cyc)) ;
        if ($value$plusargs("SEED=%d", seed)) ;
        if ($value$plusargs("RXREL=%d", rxrel)) ;
        hk_args;
        spi_half_ns = half_ns;
        $readmemh(pay_f, pay, 0, n - 1);
        fo = $fopen(out_f, "w");

        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk);

        frame(OP_WR, 16'h0200, 32'd1);                              // pin manager: P0 (TX) -> engine 0
        load(16'h1000, prog0_f);
        load(16'h2000, prog1_f);
        frame(OP_WR, 16'h2000, 32'd1);                              // RX engine first
        frame(OP_WR, 16'h1000, 32'd1);
        $fdisplay(fo, "LOADED %0d", $time);
        loaded_t = $time;

        want_rx = 0; last_progress = cyc; stalled = 0;
        tmax = tmax + cyc;                          // +TMAX is the run budget: it starts when loading ends
        if ($value$plusargs("RXONLY=%d", rxonly) && rxonly) sent = n;  // RX-only workload: the host never writes
        while ((sent < n || recv < n) && cyc < tmax && cyc - last_progress < 200 * BIT) begin
            if (!stalled && stall_at >= 0 && sent == stall_at) begin
                stalled = 1;
                repeat (stall_cyc) @(posedge clk);
                last_progress = cyc;
            end
            if (want_rx || sent >= n) begin
                frame(OP_RD, 16'h2204, 32'd0);
                if (st[1]) begin
                    $fdisplay(fo, "R %0d %0d", $time, rd[31:24]);
                    recv = recv + 1; last_progress = cyc;
                end else polls = polls + 1;
                // this STATUS predates the frame's own pop, so it cannot say whether more
                // data is waiting: send next (a write's STATUS is fresh)
                want_rx = hk_burst ? st[1] : 1'b0;      // burst: keep reading while reads return data
            end else begin
                frame(OP_WR, 16'h1200, {24'd0, pay[sent]});
                if (!st[2]) begin
                    $fdisplay(fo, "W %0d %0d", $time, pay[sent]);
                    sent = sent + 1; last_progress = cyc;
                end else retries = retries + 1;
                want_rx = hk_burst ? st[2] : st[1];     // burst: read only once TX is full
            end
        end
        repeat (20 * BIT) @(posedge clk);
        $fdisplay(fo, "STATUS sent=%0d recv=%0d retries=%0d polls=%0d frames=%0d cycles=%0d fault0=%0d fault1=%0d err=%0d rx_full_stall=%0d peer_rx=%0d timeout=%0d aborts=%0d noises=%0d",
                  sent, recv, retries, polls, frames, cyc, dut.u_eng0.fault, dut.u_eng1.fault,
                  dut.u_mgmt.err, rx_full_stall, pq_w, (sent < n || recv < n), hk_aborts, hk_noises);
        $fclose(fo);
        $finish;
    end
endmodule
