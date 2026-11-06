`timescale 1ns/1ps
`include "isa.vh"
// I2C master on the full chip, orchestrated by host/i2c_test.py. Everything the host does goes over
// the management SPI link: claim pads 6 (SDA) and 7 (SCL) open-drain for engine +ENG (0x0200 window),
// load +PROG, RUN, write TX words (base+0x200), read RX words (base+0x204). 20 ns = 1 system clock.
// Bus and slaves as in tb_i2c_engine (T_RISE compile parameter, s1 0x50, s2 0x23 with +S2EN=1).
// Host loop (as tb_spi_chip): last STATUS said RX data -> READ, else words left -> WRITE, else poll.
// +MGMT_HALF_NS sets the management SCLK half period. Log: P, R, MEM, END as tb_i2c_engine.
module tb_i2c_chip;
    // waveform: run vvp with +dump to write build/wave/tb_i2c_chip.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_i2c_chip.vcd"); $dumpvars(0, tb_i2c_chip); end
    parameter T_RISE = 1;
    localparam [7:0]  OP_WR = 8'h01, OP_RD = 8'h02;
    localparam [31:0] W_HALT = {`OP_HALT, 27'd0};

    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 200.0, spi_cs_ns = 120.0;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];

    wire s1_sda, s1_scl, s2_sda, s2_scl;
    wire c_sda = uio_oe[6] & ~uio_out[6], c_scl = uio_oe[7] & ~uio_out[7];
    wire #(T_RISE, 1) sda = !(c_sda | s1_sda | s2_sda);
    wire #(T_RISE, 1) scl = !(c_scl | s1_scl | s2_scl);

    tt_um_protocol_emulator dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in({scl, sda, 6'd0}), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));
    i2c_slave_model #(7'h50) s1 (.sda(sda), .scl(scl), .sda_low(s1_sda), .scl_low(s1_scl));
    i2c_slave_model #(7'h23) s2 (.sda(sda), .scl(scl), .sda_low(s2_sda), .scl_low(s2_scl));

    `include "spi_master.vh"
    `include "host_knobs.vh"
`ifdef SHARED_IMEM
    `include "shared_imem.vh"
`endif

    reg [8*256-1:0] prog_f, htx_f, out_f;
    reg [31:0] htx [0:8191];
    reg [31:0] img [0:255];
    integer nimg;
    integer eng = 0, n = 0, tmax = 50000000, half = 200, fd, k;
    integer cyc = 0, sent = 0, recv = 0, retries = 0, polls = 0, frames = 0, drive_high = 0, idle = 0, empty = 0;
    reg [7:0]  st;
    reg [15:0] mid, base;
    reg [31:0] rd;
    reg        want_rx = 0;

    always #10 clk = ~clk;
    always @(posedge clk) cyc = cyc + 1;
    always @(sda or scl) if (fd) $fdisplay(fd, "P %0d %b%b", $time, sda, scl);
    always @(negedge clk) begin
        if ((uio_oe[6] & uio_out[6]) | (uio_oe[7] & uio_out[7])) drive_high = drive_high + 1;
        idle = ((eng ? dut.u_eng1.tx_empty : dut.u_eng0.tx_empty) &&
                (eng ? dut.u_eng1.cu.opcode : dut.u_eng0.cu.opcode) == `OP_PULL) ? idle + 1 : 0;
    end

    task frame(input [7:0] op, input [15:0] a, input [31:0] d);
        begin
            host_extra((a[15:12] == 4'h2) ? 16'h2000 : 16'h1000);    // workload knobs (host_knobs.vh)
            spi_begin; spi_bits({72'd0, op, a, d}, 56); spi_end;
            {st, mid, rd} = spi_rx[55:0];
            frames = frames + 1;
        end
    endtask

    initial begin
        if (!$value$plusargs("N=%d", n) || !$value$plusargs("OUT=%s", out_f) ||
            !$value$plusargs("PROG=%s", prog_f) || !$value$plusargs("HTX=%s", htx_f)) begin
            $display("ERROR: missing plusargs"); $finish;
        end
        hk_args;
        if ($value$plusargs("ENG=%d", eng)) ;
        if ($value$plusargs("TMAX=%d", tmax)) ;
        if ($value$plusargs("MGMT_HALF_NS=%d", half)) ;
        spi_half_ns = half;
        if ($value$plusargs("S1EN=%d", k)) s1.en = k;
        s2.en = $value$plusargs("S2EN=%d", k) ? k : 0;
        if ($value$plusargs("S_TVD_NS=%d", k)) begin s1.tvd = k; s2.tvd = k; end
        if ($value$plusargs("S_STRETCH_NS=%d", k)) s1.stretch_ns = k;
        if ($value$plusargs("S_STRETCH_MODE=%d", k)) s1.stretch_mode = k;
        if ($value$plusargs("S_NACK_AT=%d", k)) s1.nack_at = k;
        $readmemh(htx_f, htx);
        base = eng ? 16'h2000 : 16'h1000;
        fd = $fopen(out_f, "w");
        $fdisplay(fd, "P %0d %b%b", $time, sda, scl);

        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk);
        frame(OP_WR, 16'h0218, 32'd5 + eng);                        // pad 6 (SDA): engine, open-drain
        frame(OP_WR, 16'h021C, 32'd5 + eng);                        // pad 7 (SCL)
        for (k = 0; k < 256; k = k + 1) img[k] = W_HALT;
        $readmemh(prog_f, img);
        nimg = 256; while (nimg > 1 && img[nimg - 1] === W_HALT) nimg = nimg - 1;   // load the program, not the HALT filler
        if (nimg < 256) nimg = nimg + 1;                                            // plus one HALT word after it
`ifdef SHARED_IMEM
        for (k = 0; k < nimg; k = k + 1) frame(OP_WR, 16'h0400 + 4 * ((base[13] ? 256 : 0) + k), shw(img[k], base[13]));
        if (base[13]) frame(OP_WR, base + 16'h00C, 32'd256);          // START of engine 1
`else
        for (k = 0; k < nimg; k = k + 1) frame(OP_WR, base + 16'h400 + 4 * k, img[k]);
`endif
        frame(OP_WR, base, 32'd1);                                  // RUN

        while ((sent < n || idle < 2000 || empty < 3) && cyc < tmax) begin
            if (want_rx || sent >= n) begin
                frame(OP_RD, base + 16'h204, 32'd0);
                if (st[eng]) begin
                    $fdisplay(fd, "R %0d %h", $time, rd);
                    recv = recv + 1; empty = 0;
                end else begin
                    polls = polls + 1;
                    if (sent >= n) empty = empty + 1;
                end
                want_rx = hk_burst ? st[eng] : 1'b0;
            end else begin
                frame(OP_WR, base + 16'h200, htx[sent]);
                if (!st[2 + eng]) sent = sent + 1;
                else retries = retries + 1;
                want_rx = hk_burst ? st[2 + eng] : st[eng];
            end
        end
        repeat (200) @(posedge clk);
        $fwrite(fd, "MEM 1 "); for (k = 0; k < 256; k = k + 1) $fwrite(fd, "%h", s1.mem[k]); $fdisplay(fd, "");
        $fwrite(fd, "MEM 2 "); for (k = 0; k < 256; k = k + 1) $fwrite(fd, "%h", s2.mem[k]); $fdisplay(fd, "");
        $fdisplay(fd, "END cyc=%0d sent=%0d recv=%0d retries=%0d polls=%0d frames=%0d fault=%0d err=%0d viol=%0d drive_high=%0d timeout=%0d aborts=%0d noises=%0d",
                  cyc, sent, recv, retries, polls, frames, eng ? dut.u_eng1.fault : dut.u_eng0.fault,
                  dut.u_mgmt.err, dut.u_pins.viol, drive_high, cyc >= tmax, hk_aborts, hk_noises);
        $fclose(fd);
        $finish;
    end
endmodule
