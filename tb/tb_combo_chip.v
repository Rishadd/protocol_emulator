`timescale 1ns/1ps
`include "isa.vh"
// Two protocols at once on the full chip, everything through the management link (host/workload.py):
//   engine 0 = SPI master on pads 2..5 (push-pull) against the SPI slave model (spi_peer.vh)
//   engine 1 = I2C master on pads 6/7 (open-drain) against the I2C slave models (wired-AND bus)
// The host claims the pads, loads +PROG0/+PROG1, sets both RUN bits and services both engines
// round-robin: per engine, READ if the last STATUS showed RX data, else WRITE its next word, else poll.
// 20 ns = 1 system clock. Plusargs: +PROG0 +PROG1 +HTX0 +HTX1 +STX +N0 +N1 +OUT +TMAX [+MGMT_HALF_NS]
// + SPI peer settings (spi_peer.vh p_args) + host knobs (host_knobs.vh) + I2C slave knobs as tb_i2c_chip.
// Log: P (SPI lines, spi_peer.vh), Q <ns> <sda><scl>, R0/R1 <ns> <hex>, MEM, END.
module tb_combo_chip;
    parameter T_RISE = 1;
    localparam [7:0]  OP_WR = 8'h01, OP_RD = 8'h02;
    localparam [31:0] W_HALT = {`OP_HALT, 27'd0};

    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 200.0, spi_cs_ns = 120.0;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];
    wire       p_cs, p_sclk, p_mosi, p_miso;

    `include "spi_master.vh"
    `include "host_knobs.vh"
    `include "spi_peer.vh"

    assign #1 p_cs   = uio_oe[5] ? uio_out[5] : m_cs;
    assign #1 p_sclk = uio_oe[2] ? uio_out[2] : m_sclk;
    assign #1 p_mosi = uio_oe[3] ? uio_out[3] : m_mosi;
    assign #1 p_miso = uio_oe[4] ? uio_out[4] : s_miso;

    wire s1_sda, s1_scl, s2_sda, s2_scl;
    wire c_sda = uio_oe[6] & ~uio_out[6], c_scl = uio_oe[7] & ~uio_out[7];
    wire #(T_RISE, 1) sda = !(c_sda | s1_sda | s2_sda);
    wire #(T_RISE, 1) scl = !(c_scl | s1_scl | s2_scl);
    i2c_slave_model #(7'h50) s1 (.sda(sda), .scl(scl), .sda_low(s1_sda), .scl_low(s1_scl));
    i2c_slave_model #(7'h23) s2 (.sda(sda), .scl(scl), .sda_low(s2_sda), .scl_low(s2_scl));

    tt_um_protocol_emulator dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in({scl, sda, p_cs, p_miso, p_mosi, p_sclk, 2'b00}), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));

    reg [8*256-1:0] prog0_f, prog1_f, htx0_f, htx1_f, stx_f, out_f;
    reg [31:0] htx [0:1][0:8191];
    reg [31:0] img [0:255];
    integer n [0:1], sent [0:1], recv [0:1], empty [0:1];
    integer tmax = 50000000, half = 200, k, e, cyc = 0, frames = 0, retries = 0, polls = 0, drive_high = 0;
    integer idle0 = 0, idle1 = 0;
    reg [1:0] want_rx = 0;
    reg [7:0]  st;
    reg [15:0] mid, base;
    reg [31:0] rd, tmp [0:8191];

    always #10 clk = ~clk;
    always @(posedge clk) cyc = cyc + 1;
    always @(sda or scl) if (p_fd) $fdisplay(p_fd, "Q %0d %b%b", $time, sda, scl);
    always @(negedge clk) begin
        if ((uio_oe[6] & uio_out[6]) | (uio_oe[7] & uio_out[7])) drive_high = drive_high + 1;
        idle0 = (dut.u_eng0.tx_empty && dut.u_eng0.cu.opcode == `OP_PULL) ? idle0 + 1 : 0;
        idle1 = (dut.u_eng1.tx_empty && dut.u_eng1.cu.opcode == `OP_PULL) ? idle1 + 1 : 0;
    end

    task frame(input [7:0] op, input [15:0] a, input [31:0] d);
        begin
            host_extra((a[15:12] == 4'h2) ? 16'h2000 : 16'h1000);
            spi_begin; spi_bits({72'd0, op, a, d}, 56); spi_end;
            {st, mid, rd} = spi_rx[55:0];
            frames = frames + 1;
        end
    endtask
    task load(input [15:0] b, input [8*256-1:0] file);
        integer nimg;
        begin
            for (k = 0; k < 256; k = k + 1) img[k] = W_HALT;
            $readmemh(file, img);
            nimg = 256; while (nimg > 1 && img[nimg - 1] === W_HALT) nimg = nimg - 1;   // load the program, not the HALT filler
            if (nimg < 256) nimg = nimg + 1;                                            // plus one HALT word after it
            for (k = 0; k < nimg; k = k + 1) frame(OP_WR, b + 16'h400 + 4 * k, img[k]);
        end
    endtask
    function done(input integer x);
        done = sent[x] >= n[x] && (x ? idle1 : idle0) > 2000 && empty[x] >= 3;
    endfunction

    initial begin
        if (!$value$plusargs("PROG0=%s", prog0_f) || !$value$plusargs("PROG1=%s", prog1_f) ||
            !$value$plusargs("HTX0=%s", htx0_f) || !$value$plusargs("HTX1=%s", htx1_f) ||
            !$value$plusargs("N0=%d", k) || !$value$plusargs("N1=%d", e) ||
            !$value$plusargs("OUT=%s", out_f)) begin
            $display("ERROR: missing plusargs"); $finish;
        end
        n[0] = k; n[1] = e;                                               // (plusargs need plain variables)
        p_args; hk_args;
        if ($value$plusargs("STX=%s", stx_f)) $readmemh(stx_f, stx);         // SPI slave model replies
        if ($value$plusargs("TMAX=%d", tmax)) ;
        if ($value$plusargs("MGMT_HALF_NS=%d", half)) ;
        spi_half_ns = half;
        if ($value$plusargs("S_STRETCH_NS=%d", k)) s1.stretch_ns = k;
        if ($value$plusargs("S_STRETCH_MODE=%d", k)) s1.stretch_mode = k;
        s2.en = $value$plusargs("S2EN=%d", k) ? k : 0;
        $readmemh(htx0_f, tmp); for (k = 0; k < n[0]; k = k + 1) htx[0][k] = tmp[k];
        $readmemh(htx1_f, tmp); for (k = 0; k < n[1]; k = k + 1) htx[1][k] = tmp[k];
        for (e = 0; e < 2; e = e + 1) begin sent[e] = 0; recv[e] = 0; empty[e] = 0; end
        s_en = 1;
        p_fd = $fopen(out_f, "w");
        p_log; $fdisplay(p_fd, "Q %0d %b%b", $time, sda, scl);

        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk);
        for (k = 2; k < 6; k = k + 1) frame(OP_WR, 16'h0200 + 4 * k, 32'd1);   // SPI pads -> engine 0
        frame(OP_WR, 16'h0218, 32'd6); frame(OP_WR, 16'h021C, 32'd6);           // SDA/SCL -> engine 1, od
        load(16'h1000, prog0_f); load(16'h2000, prog1_f);
        frame(OP_WR, 16'h1000, 32'd1); frame(OP_WR, 16'h2000, 32'd1);

        e = 0;
        while (!(done(0) && done(1)) && cyc < tmax) begin
            base = e ? 16'h2000 : 16'h1000;
            if (!done(e)) begin
                if (want_rx[e] || sent[e] >= n[e]) begin
                    frame(OP_RD, base + 16'h204, 32'd0);
                    if (st[e]) begin
                        $fdisplay(p_fd, "R%0d %0d %h", e, $time, rd);
                        recv[e] = recv[e] + 1; empty[e] = 0;
                    end else begin
                        polls = polls + 1;
                        if (sent[e] >= n[e]) empty[e] = empty[e] + 1;
                    end
                    want_rx[e] = hk_burst ? st[e] : 1'b0;
                end else begin
                    frame(OP_WR, base + 16'h200, htx[e][sent[e]]);
                    if (!st[2 + e]) sent[e] = sent[e] + 1;
                    else retries = retries + 1;
                    want_rx[e] = hk_burst ? st[2 + e] : st[e];
                end
            end
            e = 1 - e;
        end
        repeat (200) @(posedge clk);
        $fwrite(p_fd, "MEM 1 "); for (k = 0; k < 256; k = k + 1) $fwrite(p_fd, "%h", s1.mem[k]); $fdisplay(p_fd, "");
        $fwrite(p_fd, "MEM 2 "); for (k = 0; k < 256; k = k + 1) $fwrite(p_fd, "%h", s2.mem[k]); $fdisplay(p_fd, "");
        $fdisplay(p_fd, "END cyc=%0d frames=%0d retries=%0d polls=%0d fault0=%0d fault1=%0d err=%0d viol=%0d drive_high=%0d timeout=%0d aborts=%0d noises=%0d sent0=%0d sent1=%0d recv0=%0d recv1=%0d",
                  cyc, frames, retries, polls, dut.u_eng0.fault, dut.u_eng1.fault, dut.u_mgmt.err, dut.u_pins.viol,
                  drive_high, cyc >= tmax, hk_aborts, hk_noises, sent[0], sent[1], recv[0], recv[1]);
        $fclose(p_fd);
        $finish;
    end
endmodule
