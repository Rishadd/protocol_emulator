`timescale 1ns/1ps
`include "isa.vh"
// SPI on the full chip (tt_um_protocol_emulator), orchestrated by host/spi_test.py.
// Everything the host does goes over the management SPI link (ui_in / uo_out[0]): load the
// program into engine +ENG, set RUN, write TX words (base+0x200), read RX words (base+0x204).
// The protocol SPI runs on uio[5:2] (5 CS, 4 MISO, 3 MOSI, 2 SCLK). 10 ns = 1 system clock.
//   +ROLE=0 engine is master, peer = slave model    +ROLE=1 engine is slave, peer = master model
// Plusargs: +ENG +PROG +HTX +MTX/+STX +N +OUT +TMAX [+MGMT_HALF_NS] + peer timing (spi_peer.vh)
// Host loop (as in tb_mgmt_duplex): last STATUS said RX data -> READ, else words left -> WRITE,
// else READ as a poll. A WRITE is accepted iff its STATUS showed TX not full, a READ is valid
// iff its STATUS showed RX data.
// Log: P/S lines as tb_spi_engine, W/R <ns> <hex> (accepted write / valid read), END ...
module tb_spi_chip;
    localparam [7:0]  OP_WR = 8'h01, OP_RD = 8'h02;
    localparam [31:0] W_HALT = {`OP_HALT, 27'd0};

    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;                 // management link (spi_master.vh)
    real       spi_half_ns = 100.0, spi_cs_ns = 60.0;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];
    wire       p_cs, p_sclk, p_mosi, p_miso;                 // protocol SPI pads

    `include "spi_master.vh"
    `include "host_knobs.vh"
    `include "spi_peer.vh"

    // 1 ns inertial pad delay: filters the zero-width pulse the uio_out mux makes in zero-delay
    // simulation when an engine enables a pin (see memory.md); real pads are slower anyway
    assign #1 p_cs   = uio_oe[5] ? uio_out[5] : m_cs;
    assign #1 p_sclk = uio_oe[2] ? uio_out[2] : m_sclk;
    assign #1 p_mosi = uio_oe[3] ? uio_out[3] : m_mosi;
    assign #1 p_miso = uio_oe[4] ? uio_out[4] : s_en ? s_miso : 1'bz;

    tt_um_protocol_emulator dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in({2'b00, p_cs, p_miso, p_mosi, p_sclk, 2'b00}), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));

    reg [8*256-1:0] prog_f, htx_f, mtx_f, stx_f, out_f;
    reg [31:0] htx [0:4095];
    reg [31:0] img [0:255];
    integer role = 0, eng = 0, n = 0, tmax = 5000000, half = 100, k;
    integer cyc = 0, sent = 0, recv = 0, retries = 0, polls = 0, frames = 0, oe_other = 0, idle = 0;
    reg [7:0]  st;
    reg [15:0] mid, base;
    reg [31:0] rd;
    reg        want_rx = 0, peer_done = 0;

    always #5 clk = ~clk;
    always @(posedge clk) cyc = cyc + 1;
    wire isr_shift = eng ? dut.u_eng1.isr_shift : dut.u_eng0.isr_shift;
    always @(negedge clk) begin
        if (isr_shift) $fdisplay(p_fd, "S %0d", $time + 5);
        if (eng ? dut.oe0 : dut.oe1) oe_other = oe_other + 1;   // the idle engine must drive nothing
    end

    task frame(input [7:0] op, input [15:0] a, input [31:0] d);
        begin
            host_extra((a[15:12] == 4'h2) ? 16'h2000 : 16'h1000);    // workload knobs (host_knobs.vh)
            spi_begin; spi_bits({72'd0, op, a, d}, 56); spi_end;
            {st, mid, rd} = spi_rx[55:0];
            frames = frames + 1;
        end
    endtask

    task load(input [8*256-1:0] file);
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

    initial begin
        if (!$value$plusargs("ROLE=%d", role) || !$value$plusargs("N=%d", n) ||
            !$value$plusargs("OUT=%s", out_f) || !$value$plusargs("PROG=%s", prog_f) ||
            !$value$plusargs("HTX=%s", htx_f)) begin
            $display("ERROR: missing plusargs"); $finish;
        end
        p_args; hk_args;
        if ($value$plusargs("ENG=%d", eng)) ;
        if ($value$plusargs("TMAX=%d", tmax)) ;
        if ($value$plusargs("MGMT_HALF_NS=%d", half)) spi_half_ns = half;
        if ($value$plusargs("MTX=%s", mtx_f)) $readmemh(mtx_f, mtx);
        if ($value$plusargs("STX=%s", stx_f)) $readmemh(stx_f, stx);
        $readmemh(htx_f, htx);
        base = eng ? 16'h2000 : 16'h1000;
        s_en = (role == 0);
        p_fd = $fopen(out_f, "w");
        p_log;

        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk);
        for (k = 2; k < 6; k = k + 1) frame(OP_WR, 16'h0200 + 4 * k, eng + 1);   // pin manager: pads 2..5
        load(prog_f);
        frame(OP_WR, base, 32'd1);                                  // RUN
        $fdisplay(p_fd, "LOADED %0d", $time);

        fork
            begin if (role == 1) begin #(m_gap); m_run(n); end peer_done = 1; end   // gap first: host preloads
            begin
                while ((sent < n || recv < n) && cyc < tmax && idle < 3) begin
                    if (want_rx || sent >= n) begin
                        frame(OP_RD, base + 16'h204, 32'd0);
                        if (st[eng]) begin
                            $fdisplay(p_fd, "R %0d %h", $time, rd);
                            recv = recv + 1;
                        end else begin
                            polls = polls + 1;
                            if (peer_done && role == 1) idle = idle + 1;   // slave: nothing more will come
                        end
                        want_rx = hk_burst ? st[eng] : 1'b0;   // this STATUS predates the pop: write next
                                                               // (burst: keep reading while reads return data)
                    end else begin
                        frame(OP_WR, base + 16'h200, htx[sent]);
                        if (!st[2 + eng]) begin
                            $fdisplay(p_fd, "W %0d %h", $time, htx[sent]);
                            sent = sent + 1;
                        end else retries = retries + 1;
                        want_rx = hk_burst ? st[2 + eng] : st[eng];   // burst: read only once TX is full
                    end
                end
            end
        join
        repeat (200) @(posedge clk);
        $fdisplay(p_fd, "END cyc=%0d sent=%0d recv=%0d retries=%0d polls=%0d frames=%0d fault=%0d err=%0d oe_other=%0d s_frames=%0d aborts=%0d noises=%0d",
                  cyc, sent, recv, retries, polls, frames, eng ? dut.u_eng1.fault : dut.u_eng0.fault,
                  dut.u_mgmt.err, oe_other, s_idx, hk_aborts, hk_noises);
        $fclose(p_fd);
        $finish;
    end
endmodule
