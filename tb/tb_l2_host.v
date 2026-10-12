`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// Two-tier plan Phase 2, full chip, host only through the management link (SPI frames):
//   V2.1 L2 load + readback of all 256 words, 6 patterns (all-0, all-1, checkerboard, inverse, address, random)
//   V2.2 aborted frames on the L2 window (cut after each of bytes 1-6, writes and reads): memory unchanged
//   V2.3 unmapped / misaligned / out-of-window addresses: err, no access
//   V2.4 protection: host writes at lo-1, lo, mid, hi, hi+1 of both (overlapping) ranges with
//        {none, engine 0, engine 1, both} running: refused (err, word unchanged) exactly inside running ranges
//   V2.5 RESET_PC / L2_RANGE / FETCH_CFG writable only while that engine is held; ARB_CFG any time;
//        nonzero reserved bits and policy 3 refused; reset values
//   V2.6 L2 read data inside the same frame over an SCLK sweep (reports the limit)
//   V2.7 engine 0 transmits UART from L1 while the host hammers L2: P0 waveform identical to a quiet run (T11)
module tb_l2_host;
    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 80.0, spi_cs_ns = 60.0;
    reg  [7:0] uio_in = 8'h00;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];

    tt_um_protocol_emulator dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));

    `include "spi_master.vh"
    localparam [7:0] OP_WR = 8'h01, OP_RD = 8'h02;
    always #5 clk = ~clk;

    integer errors = 0, i, j, k, pat, n_ok, combo, pt;
    reg [7:0]  st;
    reg [15:0] mid;
    reg [31:0] rd, v;
    reg [31:0] model [0:255];
    reg [7:0]  pts [0:9];

    task frame(input [7:0] op, input [15:0] a, input [31:0] d);
        begin spi_begin; spi_bits({72'd0, op, a, d}, 56); spi_end; {st, mid, rd} = spi_rx[55:0]; repeat (4) @(posedge clk); #1; end
    endtask
    task wr(input [15:0] a, input [31:0] d); frame(OP_WR, a, d); endtask
    task rdreg(input [15:0] a);              frame(OP_RD, a, 32'd0); endtask
    function [15:0] base(input e); base = e ? 16'h2000 : 16'h1000; endfunction
    task l2w(input [7:0] i, input [31:0] d); wr(16'h0400 + 4 * i, d); endtask
    task l2r(input [7:0] i); rdreg(16'h0400 + 4 * i); endtask
    task do_reset; begin rst_n = 0; repeat (2) @(posedge clk); #1 rst_n = 1; repeat (2) @(posedge clk); #1; end endtask
    task cut(input [7:0] op, input [15:0] a, input [31:0] d, input integer nbytes);   // aborted frame
        begin spi_begin; spi_bits({72'd0, op, a, d} >> (8 * (7 - nbytes)), 8 * nbytes); spi_end; repeat (4) @(posedge clk); #1; end
    endtask
    function [31:0] patw(input integer p, input integer i);
        patw = p == 0 ? 32'h0 : p == 1 ? 32'hFFFFFFFF : p == 2 ? (i[0] ? 32'h55555555 : 32'hAAAAAAAA) :
               p == 3 ? (i[0] ? 32'hAAAAAAAA : 32'h55555555) : p == 4 ? {4{i[7:0]}} : $random;
    endfunction
    // both engines: word 0 = JMP 0 (run forever in L1, never touch L2)
    task park_programs; begin wr(16'h1100, {`OP_JMP, 27'd0}); wr(16'h2100, {`OP_JMP, 27'd0}); end endtask

    // ---- V2.7: P0 transition times relative to engine 0's RUN commit
    integer ntr = 0, quiet_n = 0;
    time    t_run = 0, tr [0:511], quiet [0:511];
    reg     rec = 0, p0_last = 0;
    always @(posedge clk) if (dut.u_mgmt.eng_run[0] && t_run == 0) t_run = $time;
    always @(posedge clk) if (rec && uio_oe[0] && uio_out[0] !== p0_last) begin
        p0_last = uio_out[0]; if (ntr < 512) tr[ntr] = $time - t_run; ntr = ntr + 1;
    end
    reg [31:0] img [0:63];
    task load_tx;   // engine 0 = UART TX image (434-clock bit), as in tb_mgmt_tx
        begin
            for (j = 0; j < 64; j = j + 1) img[j] = {`OP_HALT, 27'd0};
            $readmemh("src/fpga/uart_tx_prog.hex", img);
            for (j = 0; j < 64; j = j + 1) wr(16'h1100 + 4 * j, img[j]);
        end
    endtask
    task uart_pass(input noisy);
        begin
            do_reset; t_run = 0; ntr = 0; p0_last = 0;
            wr(16'h0200, 32'd1);                                  // P0 -> engine 0, push-pull
            for (j = 0; j < 4; j = j + 1) wr(16'h1200, 32'h55 + 32'h11 * j);   // preload 4 bytes
            rec = 1; wr(16'h1000, 32'd1); wr(16'h2000, 32'd1);    // RUN both (engine 1 parks in L1)
            if (noisy) for (j = 0; j < 40; j = j + 1) begin l2w(j, $random); l2r(j); end
            else repeat (52000) @(posedge clk);
            repeat (2000) @(posedge clk); rec = 0;
        end
    endtask

    initial begin
        repeat (3) @(posedge clk); #1 rst_n = 1; repeat (4) @(posedge clk); #1;

        $display("--- V2.5 reset values");
        rdreg(16'h1004); `CHECK(rd == 0, "RESET_PC0 reset 0")
        rdreg(16'h2008); `CHECK(rd == 32'h0000_00FF, "L2_RANGE1 reset = empty (lo FF, hi 00)")
        rdreg(16'h100C); `CHECK(rd == 32'd3, "FETCH_CFG0 reset 3")
        rdreg(16'h0300); `CHECK(rd == 0, "ARB_CFG reset 0 (round-robin)")
        `CHECK(dut.u_mgmt.err == 0, "register reads are not errors")

        $display("--- V2.1 L2 load + readback, 6 patterns x 256 words");
        for (pat = 0; pat < 6; pat = pat + 1) begin
            for (i = 0; i < 256; i = i + 1) begin model[i] = patw(pat, i); l2w(i, model[i]); end
            n_ok = 0;
            for (i = 0; i < 256; i = i + 1) begin l2r(i); n_ok = n_ok + (rd === model[i]); end
            `CHECK(n_ok == 256, "every word reads back what was written")
        end
        `CHECK(dut.u_mgmt.err == 0, "no error during load/readback")

        $display("--- V2.2 aborted L2 frames (cut after bytes 1-6) change nothing");
        for (k = 1; k < 7; k = k + 1) begin
            cut(OP_WR, 16'h0400 + 4 * 8'h21, 32'hDEADBEEF, k);
            cut(OP_RD, 16'h0400 + 4 * 8'h21, 32'd0, k);
        end
        // crafted: after this READ the last 7 bytes in the frame register read "01 04 84 AA" + 3 new bytes,
        // i.e. a complete-looking L2 write of word 0x21; only the frame length can refuse it
        do_reset; frame(OP_RD, 16'h0300, 32'h010484AA);
        cut(8'h11, 16'h2233, 32'd0, 3);
        do_reset; l2r(8'h21);
        `CHECK(rd === model[8'h21] && dut.u_mgmt.err == 0, "word unchanged after aborted writes")

        $display("--- V2.3 unmapped, misaligned, out-of-window: err, no access");
        wr(16'h0800, 32'h1); `CHECK(dut.u_mgmt.err == 1, "0x0800 write refused") do_reset;
        rdreg(16'h0800);     `CHECK(dut.u_mgmt.err == 1 && rd == 0, "0x0800 read refused") do_reset;
        wr(16'h0402, 32'h1); `CHECK(dut.u_mgmt.err == 1, "misaligned 0x0402 refused") do_reset;
        rdreg(16'h0401);     `CHECK(dut.u_mgmt.err == 1 && rd == 0, "misaligned read refused") do_reset;
        wr(16'h03FC, 32'h1); `CHECK(dut.u_mgmt.err == 1, "0x03FC (below the window) refused") do_reset;
        l2r(8'h00); `CHECK(rd === model[0], "L2 word 0 intact after refused accesses")

        $display("--- V2.4 protection: host writes vs running ranges (engine 0 [20,3F], engine 1 [30,5F])");
        pts[0] = 8'h1F; pts[1] = 8'h20; pts[2] = 8'h2F; pts[3] = 8'h3F; pts[4] = 8'h40;
        pts[5] = 8'h2F; pts[6] = 8'h30; pts[7] = 8'h47; pts[8] = 8'h5F; pts[9] = 8'h60;
        park_programs;
        for (combo = 0; combo < 4; combo = combo + 1) for (pt = 0; pt < 10; pt = pt + 1) begin
            do_reset;
            wr(16'h1008, 32'h3F20); wr(16'h2008, 32'h5F30);
            if (combo[0]) wr(16'h1000, 32'd1);
            if (combo[1]) wr(16'h2000, 32'd1);
            v = $random;
            l2w(pts[pt], v);
            k = (combo[0] && pts[pt] >= 8'h20 && pts[pt] <= 8'h3F) || (combo[1] && pts[pt] >= 8'h30 && pts[pt] <= 8'h5F);
            `CHECK(dut.u_mgmt.err == k, "write refused (err) exactly inside a running range")
            l2r(pts[pt]);
            if (!k) model[pts[pt]] = v;
            `CHECK(rd === model[pts[pt]], "refused write left the word unchanged / accepted write stored")
            if (rd !== model[pts[pt]]) $display("    combo %0d point %h: got %h exp %h", combo, pts[pt], rd, model[pts[pt]]);
        end

        $display("--- V2.5 held-only configuration registers, ARB_CFG any time, reserved bits");
        for (k = 0; k < 2; k = k + 1) begin
            do_reset; wr(base(k) + 16'h000, 32'd1);               // running (word 0 = JMP 0)
            wr(base(k) + 16'h004, 32'h1A5); `CHECK(dut.u_mgmt.err == 1, "RESET_PC write refused while running")
            do_reset; wr(base(k) + 16'h000, 32'd1);
            wr(base(k) + 16'h008, 32'h1020); `CHECK(dut.u_mgmt.err == 1, "L2_RANGE write refused while running")
            do_reset; wr(base(k) + 16'h000, 32'd1);
            wr(base(k) + 16'h00C, 32'h0);    `CHECK(dut.u_mgmt.err == 1, "FETCH_CFG write refused while running")
            wr(base(k) + 16'h000, 32'd0);
            rdreg(base(k) + 16'h004); `CHECK(rd == 0, "RESET_PC unchanged")
            rdreg(base(k) + 16'h008); `CHECK(rd == 32'h00FF, "L2_RANGE unchanged")
            rdreg(base(k) + 16'h00C); `CHECK(rd == 3, "FETCH_CFG unchanged")
            do_reset;
            wr(base(k) + 16'h004, 32'h1A5);  rdreg(base(k) + 16'h004); `CHECK(rd == 32'h1A5, "RESET_PC written while held")
            wr(base(k) + 16'h008, 32'h8010); rdreg(base(k) + 16'h008); `CHECK(rd == 32'h8010, "L2_RANGE written while held")
            wr(base(k) + 16'h00C, 32'h1);    rdreg(base(k) + 16'h00C); `CHECK(rd == 32'h1, "FETCH_CFG written while held")
            `CHECK(dut.u_mgmt.err == 0, "held writes accepted")
            wr(base(k) + 16'h004, 32'h200);  `CHECK(dut.u_mgmt.err == 1, "RESET_PC bit 9 refused") do_reset;
            wr(base(k) + 16'h008, 32'h10000); `CHECK(dut.u_mgmt.err == 1, "L2_RANGE bit 16 refused") do_reset;
            wr(base(k) + 16'h00C, 32'h4);    `CHECK(dut.u_mgmt.err == 1, "FETCH_CFG bit 2 refused") do_reset;
        end
        park_programs; wr(16'h1000, 32'd1); wr(16'h2000, 32'd1);
        wr(16'h0300, 32'd2); rdreg(16'h0300); `CHECK(rd == 2 && dut.u_mgmt.err == 0, "ARB_CFG written while both run")
        wr(16'h0300, 32'd1); rdreg(16'h0300); `CHECK(rd == 1 && dut.u_mgmt.err == 0, "ARB_CFG = engine 0 first")
        wr(16'h0300, 32'd3); `CHECK(dut.u_mgmt.err == 1, "policy 3 refused") rdreg(16'h0300); `CHECK(rd == 1, "policy kept") do_reset;
        wr(16'h0300, 32'h4); `CHECK(dut.u_mgmt.err == 1, "ARB_CFG bit 2 refused") do_reset;

        $display("--- V2.6 L2 read inside the frame vs SCLK half period");
        for (k = 80; k >= 30; k = k - 10) begin
            spi_half_ns = k; n_ok = 0;
            for (i = 0; i < 16; i = i + 1) begin l2r(8'hF0 + i); n_ok = n_ok + (rd === model[8'hF0 + i]); end
            $display("    half period %0d ns (%0d clocks): %0d/16 L2 reads correct", k, k / 10, n_ok);
            if (k >= 80) `CHECK(n_ok == 16, "L2 read correct at the supported SCLK (half period >= 8 clocks)")
        end
        spi_half_ns = 80.0;

        $display("--- V2.7 UART TX from L1, quiet host vs host hammering L2 (T11)");
        wr(16'h1000, 32'd0); wr(16'h2000, 32'd0); load_tx;
        uart_pass(0); quiet_n = ntr; for (i = 0; i < ntr && i < 512; i = i + 1) quiet[i] = tr[i];
        uart_pass(1);
        n_ok = (ntr == quiet_n);
        for (i = 0; i < ntr && i < 512; i = i + 1) if (tr[i] !== quiet[i]) n_ok = 0;
        $display("    P0 transitions: quiet %0d, noisy %0d", quiet_n, ntr);
        `CHECK(quiet_n > 20 && n_ok, "P0 waveform identical with and without L2 traffic")

        `REPORT("tb_l2_host")
        $finish;
    end
endmodule
