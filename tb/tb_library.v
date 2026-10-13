`timescale 1ns/1ps
`include "tb_common.vh"
// Two-tier plan V7.5 / V7.7: the resident library (host/library.py) in L2, one engine (50 MHz). For each
// step the host sets RUN 0 -> 1 (reset vector = dispatcher), writes one command word and the payload;
// the engine installs the protocol from L2 into L1 by itself (COPY) and runs it:
//   UART TX (P0) -> SPI master mode 0 (2 SCLK, 3 MOSI, 4 MISO, 5 CS) -> I2C master 400 kHz (6 SDA, 7 SCL,
//   open drain, slave model 0x50) -> UART RX (P1) -> UART TX again. Each result is decoded independently.
// Plusargs: +L2PROG=<256 words> +RV=<dispatcher> +RANGE=<{hi,lo}> +CMD0..+CMD5 (command words).
module tb_library;
    reg         clk = 0, rst_n = 0, run = 0;
    reg         tx_wr_en = 0, rx_rd_en = 0;
    reg  [31:0] tx_wr_data = 0;
    wire [31:0] rx_rd_data;
    wire        tx_full, rx_empty, halted, fault;
    wire [7:0]  pin_out, pin_oe;
    wire [8:0]  pc;
    reg  [8:0]  rv = 0;
    reg  [15:0] rng = 16'h00FF;
    reg         h_we = 0;
    reg  [7:0]  h_a = 0;
    reg  [31:0] h_d = 0;
    wire        l2_req, l2_hi;
    wire [7:0]  l2_a;
    wire [1:0]  gnt;
    wire [31:0] l2d;
    reg         uart_in = 1, miso = 0;
    wire        s_sda, s_scl;
    wire        sda = !((pin_oe[6] & ~pin_out[6]) | s_sda), scl = !((pin_oe[7] & ~pin_out[7]) | s_scl);   // open drain
    always #10 clk = ~clk;

    l2_mem l2 (.clk(clk), .rst_n(rst_n), .h_we(h_we), .h_re(1'b0), .h_addr(h_a), .h_wdata(h_d),
               .req({1'b0, l2_req}), .req_hi({1'b0, l2_hi}), .req_addr({8'd0, l2_a}), .policy(2'd0), .gnt(gnt), .rdata(l2d));
    engine_top dut (
        .clk(clk), .rst_n(rst_n), .run(run), .imem_we(1'b0), .imem_waddr(6'd0), .imem_wdata(32'd0),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full),
        .rx_rd_en(rx_rd_en), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in({scl, sda, pin_out[5], miso, pin_out[3:2], uart_in, pin_out[0]}), .pin_out(pin_out), .pin_oe(pin_oe),
        .reset_pc(rv), .l2_range(rng), .fetch_cfg(2'b01), .perf_clr(2'b00),
        .l2_req(l2_req), .l2_req_hi(l2_hi), .l2_addr(l2_a), .l2_gnt(gnt[0]), .l2_rdata(l2d),
        .halted(halted), .fault(fault), .pc(pc));
    i2c_slave_model #(7'h50) s1 (.sda(sda), .scl(scl), .sda_low(s_sda), .scl_low(s_scl));

    integer errors = 0, k, b;
    reg [31:0] img [0:255];
    reg [31:0] cmd [0:5];
    reg [7:0]  got;

    task host_tx(input [31:0] w); begin @(negedge clk) begin tx_wr_en = 1; tx_wr_data = w; end @(negedge clk) tx_wr_en = 0; end endtask
    task start(input integer p);                // RUN 0 -> 1: the dispatcher waits for the command
        begin run = 0; repeat (4) @(posedge clk); #1 run = 1; host_tx(cmd[p]); repeat (200) @(posedge clk); end
    endtask
    task uart_rx_byte(output [7:0] v);          // decode P0: wait for the start bit, sample mid-bit
        begin
            wait (pin_oe[0] && pin_out[0] === 1'b0);
            repeat (434 + 217) @(posedge clk);
            for (b = 0; b < 8; b = b + 1) begin v[b] = pin_out[0]; repeat (434) @(posedge clk); end
        end
    endtask
    task uart_send(input [7:0] v);              // drive P1, 8N1, 434 clocks per bit
        begin
            uart_in = 0; repeat (434) @(posedge clk);
            for (b = 0; b < 8; b = b + 1) begin uart_in = v[b]; repeat (434) @(posedge clk); end
            uart_in = 1; repeat (434) @(posedge clk);
        end
    endtask
    task rx_pop(output [31:0] w); begin wait (!rx_empty); @(negedge clk) begin w = rx_rd_data; rx_rd_en = 1; end @(negedge clk) rx_rd_en = 0; end endtask

    // SPI peer: MISO shifts 0x96 out MSB first (changes on SCLK falls), MOSI captured on SCLK rises
    reg [7:0] mosi_cap = 0, miso_sh = 8'h96;
    always @(posedge pin_out[2]) if (!pin_out[5]) mosi_cap = {mosi_cap[6:0], pin_out[3]};
    always @(negedge pin_out[5]) begin miso_sh = 8'h96; miso = miso_sh[7]; end
    always @(negedge pin_out[2]) if (!pin_out[5]) begin miso_sh = {miso_sh[6:0], 1'b0}; miso = miso_sh[7]; end

    reg [31:0] w;
    reg [8*256-1:0] fname;
    initial begin
        if (!$value$plusargs("L2PROG=%s", fname)) begin $display("ERROR: +L2PROG"); $finish; end
        $readmemh(fname, img);
        if ($value$plusargs("RV=%d", k)) rv = k;
        if ($value$plusargs("RANGE=%d", k)) rng = k;
        for (k = 0; k < 6; k = k + 1) cmd[k] = k;                       // overwritten below
        if ($value$plusargs("CMD0=%d", k)) cmd[0] = k; if ($value$plusargs("CMD1=%d", k)) cmd[1] = k;
        if ($value$plusargs("CMD2=%d", k)) cmd[2] = k; if ($value$plusargs("CMD4=%d", k)) cmd[4] = k;
        repeat (3) @(posedge clk); #1 rst_n = 1;
        for (k = 0; k < 256; k = k + 1) begin @(negedge clk) begin h_we = 1; h_a = k; h_d = img[k]; end end
        @(negedge clk) h_we = 0;

        start(0); host_tx(32'h5A);                                       // UART TX
        uart_rx_byte(got);
        `CHECK(got == 8'h5A && !fault, "V7.5 library UART TX: installed by the engine, byte 0x5A on P0")
        start(2); host_tx(32'hC300_0000);                               // SPI master mode 0, 8 bits, MSB first
        rx_pop(w);
        `CHECK(mosi_cap == 8'hC3 && w[7:0] == 8'h96 && !fault, "V7.5 library SPI master: MOSI 0xC3, MISO 0x96 read back")
        start(4);                                                        // I2C master: write 0xAB to 0x50 reg 0x10
        host_tx(32'h80000000 | ((8'hA0 << 1 | 1) << 22) | (1 << 21));   // S, addr 0x50 write, check ACK
        host_tx(((8'h10 << 1 | 1) << 22) | (1 << 21));
        host_tx(((8'hAB << 1 | 1) << 22) | (1 << 21) | (1 << 20));      // data, check, STOP
        repeat (20000) @(posedge clk);
        `CHECK(s1.mem[8'h10] == 8'hAB && !fault, "V7.5 library I2C master: slave 0x50 register 0x10 = 0xAB")
        for (k = 0; k < 3; k = k + 1) begin rx_pop(w); `CHECK(w[0] == 1'b0, "V7.5 I2C master RX word: byte ACKed") end
        start(1); uart_send(8'h3C); rx_pop(w);                           // UART RX
        `CHECK(w[31:24] == 8'h3C && !fault, "V7.5 library UART RX: 0x3C read from P1")
        start(0); host_tx(32'hE7); uart_rx_byte(got);                    // and back to UART TX
        `CHECK(got == 8'hE7 && !fault, "V7.7 protocol switch back: UART TX again")
        `REPORT("tb_library")
        $finish;
    end
endmodule
