`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// Step 4: load whole programs into engine 0 over SPI (one 7-byte frame per word, unused
// words = HALT), then CTRL RUN=1. Golden check: a second engine_top loaded with the same
// image by $readmemh/hierarchy starts on the same edge (its run = the DUT's RUN register);
// engine-level PC, pin_out and pin_oe must match every clock.
module tb_mgmt_load;
    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 80.0, spi_cs_ns = 60.0;
    reg  [7:0] uio_in = 8'b0000_1000;               // P3 high (for WAITH 3)
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];

    tt_um_protocol_emulator dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));

    // golden reference: same RTL, image loaded directly, same reset and RUN
    wire [7:0] ref_out, ref_oe;
    wire [8:0] ref_pc;
    engine_top gold (
        .reset_pc(9'd0), .l2_range(16'h00FF), .fetch_cfg(2'b00), .l2_gnt(1'b0), .l2_rdata(32'd0), .perf_clr(2'b00),   // L1 only, as in the chip at reset
        .clk(clk), .rst_n(dut.srst_n), .run(dut.u_mgmt.eng_run[0]),
        .imem_we(1'b0), .imem_waddr(6'd0), .imem_wdata(32'd0),
        .tx_wr_en(1'b0), .tx_wr_data(32'd0), .tx_full(),
        .rx_rd_en(1'b0), .rx_rd_data(), .rx_empty(),
        .pin_in(uio_in), .pin_out(ref_out), .pin_oe(ref_oe),
        .halted(), .fault(), .pc(ref_pc));

    `include "spi_master.vh"

    localparam [7:0]  OP_WR  = 8'h01;
    localparam [15:0] A_CTRL = 16'h1000;
    localparam [15:0] A_IMEM = 16'h1100;
    localparam [31:0] W_HALT = {`OP_HALT, 27'd0};

    integer errors = 0, k, mism = 0, cmp_cycles = 0, frames = 0;
    reg [5:0]  max_pc;
    reg [31:0] img [0:63];

    always #5 clk = ~clk;

    // cycle-by-cycle lockstep compare (meaningful only while RUN=1; when held both are reset)
    always @(negedge clk) if (rst_n) begin
        if (dut.u_mgmt.eng_run[0]) cmp_cycles = cmp_cycles + 1;
        if (dut.u_eng0.pc !== ref_pc || dut.u_eng0.pin_out !== ref_out || dut.u_eng0.pin_oe !== ref_oe) begin
            if (mism < 5) $display("  MISMATCH @%0t pc %0d/%0d out %h/%h oe %h/%h", $time,
                                   dut.u_eng0.pc, ref_pc, dut.u_eng0.pin_out, ref_out, dut.u_eng0.pin_oe, ref_oe);
            mism = mism + 1;
        end
        if (dut.u_eng0.pc > max_pc) max_pc = dut.u_eng0.pc;
    end

    function [31:0] I(input [4:0] op, input [26:0] opnd);
        I = {op, opnd};
    endfunction

    task wr(input [15:0] a, input [31:0] d);
        begin
            spi_begin; spi_bits({72'd0, OP_WR, a, d}, 56); spi_end;
            repeat (4) @(posedge clk); #1;
            frames = frames + 1;
        end
    endtask

    // full loading procedure: halt, write all 64 words, verify, (caller arms)
    task load(input [8*24-1:0] name);
        integer j, bad;
        begin
            wr(A_CTRL, 32'd0);
            for (j = 0; j < 64; j = j + 1) wr(A_IMEM + 4 * j, img[j]);
            bad = 0;
            for (j = 0; j < 64; j = j + 1) begin
                if (dut.u_eng0.imem.peek(j) !== img[j]) bad = bad + 1;
                gold.imem.poke(j, img[j]);
            end
            `CHECK(bad == 0, "all 64 words loaded exactly")
            `CHECK(dut.u_mgmt.err == 0, "no management error while loading")
            if (bad != 0) $display("    %0s: %0d words differ", name, bad);
        end
    endtask

    task run_and_compare(input integer cycles, input [8*40-1:0] tag);
        integer m0;
        begin
            m0 = mism; max_pc = 0;
            wr(A_CTRL, 32'd1);
            repeat (cycles) @(posedge clk); #1;
            `CHECK(mism == m0, tag)
        end
    endtask

    task claim_all; integer p; begin for (p = 0; p < 8; p = p + 1) wr(16'h0200 + 4 * p, 32'd1); end endtask  // pads -> engine 0
    task fill_halt; integer j; begin for (j = 0; j < 64; j = j + 1) img[j] = W_HALT; end endtask

    initial begin
        $dumpfile("build/tb_mgmt_load.vcd");
        $dumpvars(0, tb_mgmt_load);
        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk); #1;
        claim_all;

        $display("--- L1 pin-pattern program (19 words, every non-FIFO opcode), HALT fill");
        fill_halt;
        img[0]  = I(`OP_CFG, 0);    img[1]  = I(`OP_DIRO, 0);   img[2]  = I(`OP_DIRO, 1);
        img[3]  = I(`OP_DIRO, 2);   img[4]  = I(`OP_SETL, 5);   img[5]  = I(`OP_SETH, 0);
        img[6]  = I(`OP_WAIT, 7);   img[7]  = I(`OP_SETLO, 0);  img[8]  = I(`OP_WAIT, 3);
        img[9]  = I(`OP_DJNZ, 5);   img[10] = I(`OP_SETH, 1);   img[11] = I(`OP_OUT1, 4);
        img[12] = I(`OP_WAITH, 3);  img[13] = I(`OP_NOP, 0);    img[14] = I(`OP_SETLO, 1);
        img[15] = I(`OP_SETH, 2);   img[16] = I(`OP_WAIT, 20);  img[17] = I(`OP_SETLO, 2);
        img[18] = I(`OP_JMP, 4);
        load("pattern");
        `CHECK(dut.u_eng0.pc == 0 && uio_oe === 8'h00, "held while loading: PC 0, pins released")
        run_and_compare(2000, "pattern: lockstep with reference");
        `CHECK(uio_oe === 8'h07, "pattern drives P0..P2")
        `CHECK(max_pc == 18, "pattern reached word 18")

        $display("--- L2 reload while running is refused; after RUN=0 a new image runs");
        wr(A_IMEM, W_HALT);
        `CHECK(dut.u_mgmt.err == 1 && dut.u_eng0.imem.peek(0) === img[0], "write while running refused")
        rst_n = 0; repeat (2) @(posedge clk); #1 rst_n = 1; repeat (2) @(posedge clk); #1;  // clear err
        claim_all;

        $display("--- L3 64-word program that executes every word");
        img[0] = I(`OP_CFG, 0); img[1] = I(`OP_DIRO, 0); img[2] = I(`OP_DIRO, 1);
        for (k = 3; k < 63; k = k + 1)
            case (k % 3)
                0: img[k] = I(`OP_SETH, k % 2);
                1: img[k] = I(`OP_WAIT, k);
                2: img[k] = I(`OP_SETLO, k % 2);
            endcase
        img[63] = I(`OP_JMP, 3);
        load("full64");
        run_and_compare(6000, "full64: lockstep with reference");
        `CHECK(max_pc == 63, "full64 reached word 63");

        $display("--- L4 UART TX image (src/fpga/uart_tx_prog.hex) loaded over SPI");
        fill_halt; $readmemh("src/fpga/uart_tx_prog.hex", img);
        `CHECK(img[3] == 32'h3000_0000 && img[12] == W_HALT, "TX image read, HALT fill")
        load("uart_tx");
        run_and_compare(500, "uart_tx: lockstep with reference");
        `CHECK(uio_oe[0] === 1'b1 && uio_out[0] === 1'b1, "TX idles high on P0")
        `CHECK(dut.u_eng0.pc == 3, "TX blocked in PULL (empty FIFO)")

        $display("--- L5 UART RX image (src/fpga/uart_rx_prog.hex) loaded over SPI");
        wr(A_CTRL, 32'd0);
        fill_halt; $readmemh("src/fpga/uart_rx_prog.hex", img);
        load("uart_rx");
        uio_in = 8'b0000_0010;                       // RX line (P1) idle high
        run_and_compare(500, "uart_rx: lockstep with reference");
        uio_in = 8'b0000_0000;                       // a start bit: both engines must follow it
        repeat (3000) @(posedge clk); #1;
        `CHECK(mism == 0, "uart_rx: lockstep through a start bit")
        `CHECK(uio_oe === 8'h00, "RX drives no pins")
        wr(A_CTRL, 32'd0);

        $display("    frames sent: %0d, lockstep cycles compared while running: %0d, mismatches: %0d",
                 frames, cmp_cycles, mism);
        `REPORT("tb_mgmt_load")
        $finish;
    end
endmodule
