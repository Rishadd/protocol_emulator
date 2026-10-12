`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// Step 7: WRITE TX_DATA (base+0x200) feeds the engine's TX FIFO; the UART TX firmware
// (src/fpga/uart_tx_prog.hex, P0, 115200 @ 50 MHz) sends it. Checks:
//   - a UART receiver model on pad P0 decodes exactly the bytes the host sent (8N1)
//   - golden engines fed the same accepted words on the same cycle run in lockstep
//   - flow control: a write is accepted only if that frame's STATUS showed tx_full = 0;
//     the host resends otherwise, so nothing is dropped or duplicated
module tb_mgmt_tx;
    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 80.0, spi_cs_ns = 60.0;
    reg  [7:0] uio_in = 8'b0000_0000;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];

    tt_um_protocol_emulator dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));

    wire [7:0] g_out [0:1];
    wire [7:0] g_oe  [0:1];
    wire [8:0] g_pc  [0:1];
    genvar ge;
    generate for (ge = 0; ge < 2; ge = ge + 1) begin : gold
        engine_top eng (
            .clk(clk), .rst_n(dut.srst_n), .run(dut.u_mgmt.eng_run[ge]),
            .imem_we(1'b0), .imem_waddr(6'd0), .imem_wdata(32'd0),
            .tx_wr_en(dut.u_mgmt.tx_wr_en[ge]), .tx_wr_data(dut.u_mgmt.tx_wr_data), .tx_full(),
            .rx_rd_en(1'b0), .rx_rd_data(), .rx_empty(),
            .pin_in(uio_in), .pin_out(g_out[ge]), .pin_oe(g_oe[ge]),
            .halted(), .fault(), .pc(g_pc[ge]));
    end endgenerate

    `include "spi_master.vh"

    localparam integer BIT = 434;
    localparam [7:0]  OP_WR = 8'h01, OP_RD = 8'h02;
    localparam [31:0] W_HALT = {`OP_HALT, 27'd0};

    integer errors = 0, k, mism = 0, retries = 0, n_rx = 0, framing = 0;
    reg [7:0]  st;
    reg [15:0] mid;
    reg [31:0] rd;
    reg [31:0] img [0:63];
    reg [7:0]  rx_log [0:1023];
    reg [7:0]  msg    [0:1023];

    always #5 clk = ~clk;

    // lockstep: SPI-fed engines vs golden engines fed the same accepted words
    always @(negedge clk) if (rst_n) begin
        if (dut.u_eng0.pc !== g_pc[0] || dut.u_eng0.pin_out !== g_out[0] || dut.u_eng0.pin_oe !== g_oe[0] ||
            dut.u_eng1.pc !== g_pc[1] || dut.u_eng1.pin_out !== g_out[1] || dut.u_eng1.pin_oe !== g_oe[1]) begin
            if (mism < 5) $display("  LOCKSTEP MISMATCH @%0t", $time);
            mism = mism + 1;
        end
    end

    // UART receiver model on pad P0 (released = pulled high): clock-sampled like a real
    // receiver, so zero-width simulation glitches never start a frame. Mid-bit, 8N1, LSB first.
    wire line = uio_oe[0] ? uio_out[0] : 1'b1;
    initial begin : uart_rx_model
        integer i; reg [7:0] b; reg prev;
        prev = 1'b1;
        forever begin
            @(posedge clk);
            while (!(prev === 1'b1 && line === 1'b0)) begin prev = line; @(posedge clk); end
            prev = 1'b0;
            repeat (BIT / 2 - 1) @(posedge clk);
            if (line !== 1'b0) framing = framing + 1;          // start bit gone: glitch
            for (i = 0; i < 8; i = i + 1) begin repeat (BIT) @(posedge clk); b[i] = line; end
            repeat (BIT) @(posedge clk);
            if (line !== 1'b1) framing = framing + 1;          // stop bit
            rx_log[n_rx] = b; n_rx = n_rx + 1;
        end
    end

    task frame(input [7:0] op, input [15:0] a, input [31:0] d);
        begin
            spi_begin; spi_bits({72'd0, op, a, d}, 56); spi_end;
            {st, mid, rd} = spi_rx[55:0];
            repeat (4) @(posedge clk); #1;
        end
    endtask
    task wr(input [15:0] a, input [31:0] d); frame(OP_WR, a, d); endtask
    function [15:0] base(input e); base = e ? 16'h2000 : 16'h1000; endfunction
    task ctrl(input e, input r); wr(base(e), {31'd0, r}); endtask

    // host send with flow control: resend while this frame's STATUS said TX full
    task tx_send(input e, input [7:0] b);
        begin
            wr(base(e) + 16'h200, {24'd0, b});
            while (st[2 + e]) begin
                retries = retries + 1;
                wr(base(e) + 16'h200, {24'd0, b});
            end
        end
    endtask

    task load_tx_image(input e);
        integer j;
        begin
            for (j = 0; j < 64; j = j + 1) img[j] = W_HALT;
            $readmemh("src/fpga/uart_tx_prog.hex", img);
            ctrl(e, 0);
            for (j = 0; j < 64; j = j + 1) begin
                wr(base(e) + 16'h100 + 4 * j, img[j]);
                if (e) gold[1].eng.imem.poke(j, img[j]); else gold[0].eng.imem.poke(j, img[j]);
            end
        end
    endtask

    task wait_rx(input integer n);
        integer t;
        begin
            t = 0;
            while (n_rx < n && t < 200 * BIT) begin @(posedge clk); t = t + 1; end
            repeat (2 * BIT) @(posedge clk); #1;
        end
    endtask

    task check_rx(input integer from, input integer n, input [8*40-1:0] tag);
        integer j, bad;
        begin
            bad = 0;
            for (j = 0; j < n; j = j + 1)
                if (rx_log[from + j] !== msg[j]) begin
                    if (bad < 3) $display("    byte %0d got %h expected %h", j, rx_log[from + j], msg[j]);
                    bad = bad + 1;
                end
            `CHECK(bad == 0 && n_rx == from + n, tag)
            if (n_rx != from + n) $display("    received %0d bytes, expected %0d", n_rx - from, n);
        end
    endtask

    initial begin
        $dumpfile("build/tb_mgmt_tx.vcd");
        $dumpvars(0, tb_mgmt_tx);
        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk); #1;

        $display("--- T1 engine 0 = UART TX image, one byte over SPI -> P0");
        wr(16'h0200, 32'd1);                         // pin manager: P0 -> engine 0
        load_tx_image(0); ctrl(0, 1);
        repeat (20) @(posedge clk);
        `CHECK(uio_oe[0] === 1'b1 && uio_out[0] === 1'b1, "TX idles high")
        msg[0] = 8'h55; tx_send(0, 8'h55);
        wait_rx(1);
        check_rx(0, 1, "0x55 on the UART line");

        $display("--- T2 64-byte stream, SPI ~4.5x faster than UART: STATUS flow control");
        for (k = 0; k < 64; k = k + 1) msg[k] = (k == 0) ? 8'h00 : (k == 1) ? 8'hFF : (k * 37 + 11);
        retries = 0;
        for (k = 0; k < 64; k = k + 1) tx_send(0, msg[k]);
        wait_rx(65);
        check_rx(1, 64, "64 bytes in order, none dropped or duplicated");
        `CHECK(retries > 0, "flow control was exercised (TX FIFO filled)")
        $display("    retries (frames dropped because TX was full): %0d", retries);
        `CHECK(dut.u_mgmt.err == 0, "no management error")

        $display("--- T3 preload while held: 4 accepted, 5th dropped (STATUS full), then RUN sends 4");
        ctrl(0, 0);
        repeat (2 * BIT) @(posedge clk);
        for (k = 0; k < 4; k = k + 1) begin
            msg[k] = 8'hA0 + k; wr(16'h1200, {24'd0, msg[k]});
            `CHECK(st[2] == 0, "accepted (STATUS tx_full = 0)")
        end
        wr(16'h1200, 32'h0000_00EE);
        `CHECK(st[2] == 1 && dut.u_eng0.tx_fifo.count == 4, "5th write dropped, FIFO holds 4")
        k = n_rx;
        ctrl(0, 1);
        wait_rx(k + 4);
        check_rx(k, 4, "exactly the 4 preloaded bytes, in order");

        $display("--- T4 aborted TX write frame pushes nothing");
        spi_begin; spi_bits({72'd0, OP_WR, 16'h1200, 32'h0000_0042}, 50); spi_end; repeat (4) @(posedge clk);
        `CHECK(dut.u_eng0.tx_fifo.count == 0, "nothing pushed")
        k = n_rx; repeat (12 * BIT) @(posedge clk);
        `CHECK(n_rx == k, "nothing transmitted")
        rst_n = 0; repeat (2) @(posedge clk); #1 rst_n = 1; repeat (2) @(posedge clk); #1;   // clear err

        $display("--- T5 engine 1 = UART TX image (engine 0 held); writes to engine 1 only");
        wr(16'h0200, 32'd2);                         // pin manager: P0 -> engine 1
        load_tx_image(1); ctrl(1, 1);
        repeat (20) @(posedge clk);
        for (k = 0; k < 16; k = k + 1) msg[k] = 8'h30 + k;
        k = n_rx;
        begin : e1 integer j; for (j = 0; j < 16; j = j + 1) tx_send(1, msg[j]); end
        wait_rx(k + 16);
        check_rx(k, 16, "16 bytes from engine 1");
        `CHECK(dut.u_eng0.tx_fifo.count == 0, "engine 0 FIFO untouched")

        $display("--- T6 SCLK sweep on the write path (half period 8.7 and 50 clocks)");
        spi_half_ns = 87.0;
        for (k = 0; k < 8; k = k + 1) msg[k] = 8'hC0 + k;
        k = n_rx;
        begin : s1 integer j; for (j = 0; j < 8; j = j + 1) tx_send(1, msg[j]); end
        wait_rx(k + 8); check_rx(k, 8, "8 bytes at 8.7 clk");
        spi_half_ns = 500.0;
        k = n_rx;
        begin : s2 integer j; for (j = 0; j < 8; j = j + 1) tx_send(1, msg[j]); end
        wait_rx(k + 8); check_rx(k, 8, "8 bytes at 50 clk");
        spi_half_ns = 80.0;

        $display("--- T7 near-miss TX addresses push nothing and set err");
        rst_n = 0; repeat (2) @(posedge clk); #1 rst_n = 1; repeat (2) @(posedge clk); #1;
        wr(16'h1300, 32'h0000_0011); wr(16'h1600, 32'h0000_0022); wr(16'h1F00, 32'h0000_0033);
        wr(16'h1201, 32'h0000_0044); wr(16'h1210, 32'h0000_0055);
        `CHECK(dut.u_eng0.tx_fifo.count == 0 && dut.u_eng1.tx_fifo.count == 0, "no TX push from bad addresses")
        `CHECK(dut.u_mgmt.err == 1, "err set")

        `CHECK(mism == 0, "lockstep with golden engines")
        `CHECK(framing == 0, "no UART framing errors")
        $display("    bytes received on P0: %0d, framing errors: %0d, lockstep mismatches: %0d",
                 n_rx, framing, mism);
        `REPORT("tb_mgmt_tx")
        $finish;
    end
endmodule
