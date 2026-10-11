`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// Step 5: route instruction writes to engine 0 (0x1xxx) or engine 1 (0x2xxx).
// Two golden engines (images loaded directly, RUN tied to the DUT's RUN bits) run in
// lockstep with the SPI-loaded engines: PC, pin_out, pin_oe every clock. The pad mux is
// checked too: uio_oe = oe0|oe1 and every driven bit carries the right engine's value.
module tb_mgmt_dual;
    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 80.0, spi_cs_ns = 60.0;
    reg  [7:0] uio_in = 8'b1000_0000;               // P7 high (pattern WAITH 7)
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];

    tt_um_protocol_emulator dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));

    wire [7:0] g_out [0:1];
    wire [7:0] g_oe  [0:1];
    wire [5:0] g_pc  [0:1];
    genvar ge;
    generate for (ge = 0; ge < 2; ge = ge + 1) begin : gold
        engine_top eng (
            .clk(clk), .rst_n(dut.srst_n), .run(dut.u_mgmt.eng_run[ge]),
            .imem_we(1'b0), .imem_waddr(6'd0), .imem_wdata(32'd0),
            .tx_wr_en(1'b0), .tx_wr_data(32'd0), .tx_full(),
            .rx_rd_en(1'b0), .rx_rd_data(), .rx_empty(),
            .pin_in(uio_in), .pin_out(g_out[ge]), .pin_oe(g_oe[ge]),
            .halted(), .fault(), .pc(g_pc[ge]));
    end endgenerate

    `include "spi_master.vh"

    localparam [7:0]  OP_WR  = 8'h01;
    localparam [31:0] W_HALT = {`OP_HALT, 27'd0};

    integer errors = 0, k, frames = 0;
    integer mism0 = 0, mism1 = 0, padmis = 0, run_cyc0 = 0, run_cyc1 = 0;
    reg [31:0] img   [0:127];       // engine e word j = img[64*e + j]
    reg [31:0] model [0:127];       // what each DUT memory must hold (X = never written)
    reg [5:0]  max_pc0, max_pc1;

    always #5 clk = ~clk;

    wire [7:0] d_out0 = dut.u_eng0.pin_out, d_oe0 = dut.u_eng0.pin_oe;
    wire [7:0] d_out1 = dut.u_eng1.pin_out, d_oe1 = dut.u_eng1.pin_oe;
    wire [7:0] pad_exp = (g_oe[0] & g_out[0]) | (~g_oe[0] & g_out[1]);

    always @(negedge clk) if (rst_n) begin
        if (dut.u_mgmt.eng_run[0]) run_cyc0 = run_cyc0 + 1;
        if (dut.u_mgmt.eng_run[1]) run_cyc1 = run_cyc1 + 1;
        if (dut.u_eng0.pc !== g_pc[0] || d_out0 !== g_out[0] || d_oe0 !== g_oe[0]) begin
            if (mism0 < 5) $display("  ENG0 MISMATCH @%0t pc %0d/%0d", $time, dut.u_eng0.pc, g_pc[0]);
            mism0 = mism0 + 1;
        end
        if (dut.u_eng1.pc !== g_pc[1] || d_out1 !== g_out[1] || d_oe1 !== g_oe[1]) begin
            if (mism1 < 5) $display("  ENG1 MISMATCH @%0t pc %0d/%0d", $time, dut.u_eng1.pc, g_pc[1]);
            mism1 = mism1 + 1;
        end
        if (uio_oe !== (g_oe[0] | g_oe[1]) || ((uio_out ^ pad_exp) & uio_oe) !== 8'h00) begin
            if (padmis < 5) $display("  PAD MISMATCH @%0t oe %h out %h exp %h", $time, uio_oe, uio_out, pad_exp);
            padmis = padmis + 1;
        end
        if (dut.u_eng0.pc > max_pc0) max_pc0 = dut.u_eng0.pc;
        if (dut.u_eng1.pc > max_pc1) max_pc1 = dut.u_eng1.pc;
    end

    function [31:0] I(input [4:0] op, input [26:0] opnd);
        I = {op, opnd};
    endfunction
    function [15:0] base(input e);
        base = e ? 16'h2000 : 16'h1000;
    endfunction

    task raw(input [127:0] v, input integer n);
        begin
            spi_begin; spi_bits(v, n); spi_end;
            repeat (4) @(posedge clk); #1;
            frames = frames + 1;
        end
    endtask
    task wr(input [15:0] a, input [31:0] d);
        raw({72'd0, OP_WR, a, d}, 56);
    endtask
    task ctrl(input e, input r);
        wr(base(e), {31'd0, r});
    endtask
    task wr_word(input e, input [5:0] j);
        begin
            wr(base(e) + 16'h100 + 4 * j, img[64 * e + j]);
            if (!dut.u_mgmt.eng_run[e]) model[64 * e + j] = img[64 * e + j];
        end
    endtask

    task check_mems(input [8*48-1:0] tag);
        integer j, bad;
        begin
            bad = 0;
            for (j = 0; j < 64; j = j + 1) begin
                if (dut.u_eng0.imem.peek(j) !== model[j])      bad = bad + 1;
                if (dut.u_eng1.imem.peek(j) !== model[64 + j]) bad = bad + 1;
            end
            `CHECK(bad == 0, tag)
            if (bad != 0) $display("    %0d words wrong", bad);
        end
    endtask

    // full load of one engine (halt, 64 words, check), golden copy updated
    task load(input e);
        integer j;
        begin
            ctrl(e, 0);
            for (j = 0; j < 64; j = j + 1) wr_word(e, j);
            for (j = 0; j < 64; j = j + 1)
                if (e) gold[1].eng.imem.poke(j, img[64 + j]); else gold[0].eng.imem.poke(j, img[j]);
            check_mems("both memories exact after load");
        end
    endtask

    // both engines loaded word-interleaved: e0 w0, e1 w0, e0 w1, ...
    task load_both_interleaved;
        integer j;
        begin
            ctrl(0, 0); ctrl(1, 0);
            for (j = 0; j < 64; j = j + 1) begin wr_word(0, j); wr_word(1, j); end
            for (j = 0; j < 64; j = j + 1) begin
                gold[0].eng.imem.poke(j, img[j]);
                gold[1].eng.imem.poke(j, img[64 + j]);
            end
            check_mems("both memories exact after interleaved load");
        end
    endtask

    task fill_halt(input e); integer j; begin for (j = 0; j < 64; j = j + 1) img[64 * e + j] = W_HALT; end endtask

    // pin-pattern program on pins p..p+2 (OUT1 on p), WAITH on P7
    task pattern(input e, input [2:0] p, input [26:0] w);
        integer o;
        begin
            fill_halt(e); o = 64 * e;
            img[o+0]  = I(`OP_CFG, {24'd0, p});     img[o+1]  = I(`OP_DIRO, p);
            img[o+2]  = I(`OP_DIRO, p + 3'd1);      img[o+3]  = I(`OP_DIRO, p + 3'd2);
            img[o+4]  = I(`OP_SETL, 5);             img[o+5]  = I(`OP_SETH, p);
            img[o+6]  = I(`OP_WAIT, w);             img[o+7]  = I(`OP_SETLO, p);
            img[o+8]  = I(`OP_WAIT, 3);             img[o+9]  = I(`OP_DJNZ, 5);
            img[o+10] = I(`OP_SETH, p + 3'd1);      img[o+11] = I(`OP_OUT1, 4);
            img[o+12] = I(`OP_WAITH, 7);            img[o+13] = I(`OP_NOP, 0);
            img[o+14] = I(`OP_SETLO, p + 3'd1);     img[o+15] = I(`OP_SETH, p + 3'd2);
            img[o+16] = I(`OP_WAIT, 20);            img[o+17] = I(`OP_SETLO, p + 3'd2);
            img[o+18] = I(`OP_JMP, 4);
        end
    endtask

    task hex_image(input e, input [8*40-1:0] file);
        integer j; reg [31:0] tmp [0:63];
        begin
            for (j = 0; j < 64; j = j + 1) tmp[j] = W_HALT;
            $readmemh(file, tmp);
            for (j = 0; j < 64; j = j + 1) img[64 * e + j] = tmp[j];
        end
    endtask

    task do_reset; begin rst_n = 0; repeat (2) @(posedge clk); #1 rst_n = 1; repeat (2) @(posedge clk); #1; end endtask

    task lockstep_ok(input [8*48-1:0] tag);
        begin
            `CHECK(mism0 == 0 && mism1 == 0 && padmis == 0, tag)
        end
    endtask

    task bad(input [15:0] a, input [31:0] d, input [8*48-1:0] tag);
        reg [1:0] r0;
        begin
            do_reset; r0 = dut.u_mgmt.eng_run;
            wr(a, d);
            `CHECK(dut.u_mgmt.err == 1 && dut.u_mgmt.eng_run == r0, tag)
            check_mems("memories unchanged by rejected frame");
        end
    endtask

    initial begin
        $dumpfile("build/tb_mgmt_dual.vcd");
        $dumpvars(0, tb_mgmt_dual);
        for (k = 0; k < 128; k = k + 1) model[k] = 32'bx;
        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk); #1;
        `CHECK(dut.u_mgmt.eng_run == 2'b00 && uio_oe === 8'h00, "reset: both held, pins released")

        $display("--- D1 only engine 0 loaded and run; engine 1 never written, stays held");
        pattern(0, 3'd0, 7); load(0);
        max_pc0 = 0; ctrl(0, 1); repeat (3000) @(posedge clk); #1;
        `CHECK(max_pc0 == 18 && uio_oe === 8'h07, "engine 0 pattern on P0..P2")
        `CHECK(dut.u_eng1.pc == 0 && d_oe1 === 8'h00, "engine 1 held at PC 0, no pins")
        lockstep_ok("D1 lockstep");

        $display("--- D2 only engine 1 loaded and run; engine 0 held, its memory kept");
        do_reset;
        pattern(1, 3'd4, 9); load(1);
        max_pc1 = 0; ctrl(1, 1); repeat (3000) @(posedge clk); #1;
        `CHECK(max_pc1 == 18 && uio_oe === 8'h70, "engine 1 pattern on P4..P6")
        `CHECK(dut.u_eng0.pc == 0 && d_oe0 === 8'h00, "engine 0 held at PC 0, no pins")
        lockstep_ok("D2 lockstep");

        $display("--- D3 both loaded word-interleaved, both run (P0..P2 and P4..P6)");
        do_reset;
        pattern(0, 3'd0, 5); pattern(1, 3'd4, 11); load_both_interleaved;
        max_pc0 = 0; max_pc1 = 0; ctrl(0, 1); ctrl(1, 1); repeat (5000) @(posedge clk); #1;
        `CHECK(max_pc0 == 18 && max_pc1 == 18 && uio_oe === 8'h77, "both patterns running")
        lockstep_ok("D3 lockstep");

        $display("--- D4 engine 0 = UART TX image, engine 1 = UART RX image");
        do_reset;
        hex_image(0, "src/fpga/uart_tx_prog.hex"); hex_image(1, "src/fpga/uart_rx_prog.hex");
        load(0); load(1);
        `CHECK(dut.u_eng0.imem.peek(3) === 32'h3000_0000, "TX image in engine 0")
        uio_in = 8'b0000_0010;                       // RX line (P1) idle high
        ctrl(1, 1); ctrl(0, 1); repeat (1000) @(posedge clk); #1;
        `CHECK(dut.u_eng0.pc == 3 && uio_oe === 8'h01 && uio_out[0] === 1'b1, "TX idles high on P0, blocked in PULL")
        uio_in = 8'b0000_0000; repeat (3000) @(posedge clk); #1;   // a start bit on P1
        lockstep_ok("D4 lockstep");

        $display("--- D5 swapped: engine 0 = RX, engine 1 = TX");
        do_reset;
        hex_image(0, "src/fpga/uart_rx_prog.hex"); hex_image(1, "src/fpga/uart_tx_prog.hex");
        load_both_interleaved;
        uio_in = 8'b0000_0010;
        ctrl(0, 1); ctrl(1, 1); repeat (1000) @(posedge clk); #1;
        `CHECK(dut.u_eng1.pc == 3 && uio_oe === 8'h01 && uio_out[0] === 1'b1, "TX from engine 1 idles high on P0")
        uio_in = 8'b0000_0000; repeat (3000) @(posedge clk); #1;
        lockstep_ok("D5 lockstep");

        $display("--- D6 load engine 1 while engine 0 runs; engine 0 writes refused, never disturbed");
        do_reset; uio_in = 8'b1000_0000;
        pattern(0, 3'd0, 6); load(0);
        max_pc0 = 0; ctrl(0, 1);
        pattern(1, 3'd4, 4); load(1);                // engine 0 keeps running throughout
        wr(16'h1100, W_HALT);
        `CHECK(dut.u_mgmt.err == 1, "write to running engine 0 refused")
        check_mems("engine 0 memory untouched by refused write");
        max_pc1 = 0; ctrl(1, 1); repeat (3000) @(posedge clk); #1;
        `CHECK(max_pc0 == 18 && max_pc1 == 18, "both reached word 18")
        lockstep_ok("D6 lockstep");

        $display("--- D7 stop engine 1 alone, engine 0 continues; restart engine 1 from PC 0");
        ctrl(1, 0);
        `CHECK(dut.u_eng1.pc == 0 && d_oe1 === 8'h00 && dut.u_mgmt.eng_run == 2'b01, "engine 1 stopped, pins released")
        repeat (2000) @(posedge clk); #1;
        `CHECK(d_oe0 === 8'h07, "engine 0 still driving")
        max_pc1 = 0; ctrl(1, 1); repeat (2000) @(posedge clk); #1;
        `CHECK(max_pc1 == 18, "engine 1 restarted")
        lockstep_ok("D7 lockstep");

        $display("--- D8 pin conflict: both engines drive P0, engine 0 wins");
        do_reset;
        fill_halt(0); img[0] = I(`OP_DIRO, 0); img[1] = I(`OP_SETH, 0);  img[2] = I(`OP_HALT, 0);
        fill_halt(1); img[64] = I(`OP_DIRO, 0); img[65] = I(`OP_SETLO, 0); img[66] = I(`OP_HALT, 0);
        load(0); load(1); ctrl(1, 1); ctrl(0, 1);
        `CHECK(uio_oe[0] === 1'b1 && uio_out[0] === 1'b1, "P0 shows engine 0's high")
        lockstep_ok("D8 lockstep");

        $display("--- D9 rejected addresses");
        bad(16'h2004, 32'd1,         "0x2004 (next to ENG1_CTRL) rejected");
        bad(16'h1004, 32'd1,         "0x1004 rejected");
        bad(16'h2208, 32'h1111_1111, "0x2208 rejected");
        bad(16'h3100, 32'h1111_1111, "0x3100 rejected");
        bad(16'h6100, 32'h1111_1111, "0x6100 rejected");
        bad(16'hF100, 32'h1111_1111, "0xF100 rejected");
        bad(16'h0100, 32'h1111_1111, "0x0100 rejected");
        bad(16'h2102, 32'h1111_1111, "misaligned 0x2102 rejected");
        bad(16'h2000, 32'h8000_0001, "ENG1_CTRL reserved bit rejected");

        $display("    frames: %0d, running cycles compared: eng0 %0d, eng1 %0d; mismatches %0d/%0d, pad %0d",
                 frames, run_cyc0, run_cyc1, mism0, mism1, padmis);
        `REPORT("tb_mgmt_dual")
        $finish;
    end
endmodule
