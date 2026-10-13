`timescale 1ns/1ps
// SPI at engine level, orchestrated by host/spi_test.py. 10 ns = 1 system clock.
// The host side writes/reads the engine FIFOs directly (no management link).
//   +ROLE=0 engine is master, peer = slave model     +ROLE=1 engine is slave, peer = master model
//   +ROLE=2 no engine: master model <-> slave model (checks the peers themselves)
// Plusargs: +PROG (engine hex) +HTX (host TX words, hex) +MTX/+STX (peer values, hex) +N (frames)
//           +OUT (log) +TMAX (cycles) [+TXLATE_NS +RXOFF_NS: host starts feeding / draining late]
//           + peer timing, see spi_peer.vh p_args
// Log: P <ns> <cs sclk mosi miso>  S <ns> (engine ISR shifts at this edge)  W/R <ns> <hex>  END ...
// Pads: pin 2 SCLK, 3 MOSI, 4 MISO, 5 CS. A pin the engine does not drive carries the peer's value.
module tb_spi_engine;
    reg         clk = 0, rst_n = 0, run = 0;
    reg         tx_wr_en = 0, rx_rd_en = 0;
    reg  [31:0] tx_wr_data = 0;
    wire [31:0] rx_rd_data;
    wire        tx_full, rx_empty, halted, fault;
    wire [7:0]  pin_out, pin_oe;
    wire [8:0]  pc;
    wire        p_cs, p_sclk, p_mosi, p_miso;

    `include "spi_peer.vh"

    assign p_cs   = pin_oe[5] ? pin_out[5] : m_cs;
    assign p_sclk = pin_oe[2] ? pin_out[2] : m_sclk;
    assign p_mosi = pin_oe[3] ? pin_out[3] : m_mosi;
    assign p_miso = pin_oe[4] ? pin_out[4] : s_en ? s_miso : 1'bz;

    engine_top dut (
        .reset_pc(9'd0), .l2_range(16'h00FF), .fetch_cfg(2'b00), .l2_gnt(1'b0), .l2_rdata(32'd0), .perf_clr(2'b00),   // L1 only, as in the chip at reset
        .clk(clk), .rst_n(rst_n), .run(run),
        .imem_we(1'b0), .imem_waddr(6'd0), .imem_wdata(32'd0),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full),
        .rx_rd_en(rx_rd_en), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in({2'b00, p_cs, p_miso, p_mosi, p_sclk, 2'b00}), .pin_out(pin_out), .pin_oe(pin_oe),
        .halted(halted), .fault(fault), .pc(pc));

    reg [8*256-1:0] prog_f, htx_f, mtx_f, stx_f, out_f;
    reg [31:0] htx [0:4095];
    integer role = 0, n = 0, tmax = 1000000, txlate = 0, rxoff = 0;
    integer cyc = 0, nw = 0, nr = 0;

    always #5 clk = ~clk;
    always @(posedge clk) cyc = cyc + 1;

    // host side: FIFO strobes set on the falling edge, taken on the next rising edge
    always @(negedge clk) begin
        tx_wr_en = 0; rx_rd_en = 0;
        if (run && dut.isr_shift) $fdisplay(p_fd, "S %0d", $time + 5);
        if (run && role != 2 && nw < n && !tx_full && $time >= txlate) begin
            tx_wr_en = 1; tx_wr_data = htx[nw]; nw = nw + 1;
            $fdisplay(p_fd, "W %0d %h", $time, tx_wr_data);
        end
        if (run && !rx_empty && $time >= rxoff) begin
            rx_rd_en = 1; nr = nr + 1;
            $fdisplay(p_fd, "R %0d %h", $time, rx_rd_data);
        end
    end

    initial begin
        if (!$value$plusargs("ROLE=%d", role) || !$value$plusargs("N=%d", n) ||
            !$value$plusargs("OUT=%s", out_f)) begin
            $display("ERROR: missing plusargs"); $finish;
        end
        p_args;
        if ($value$plusargs("TMAX=%d", tmax)) ;
        if ($value$plusargs("TXLATE_NS=%d", txlate)) ;
        if ($value$plusargs("RXOFF_NS=%d", rxoff)) ;
        if ($value$plusargs("MTX=%s", mtx_f)) $readmemh(mtx_f, mtx);
        if ($value$plusargs("STX=%s", stx_f)) $readmemh(stx_f, stx);
        if ($value$plusargs("HTX=%s", htx_f)) $readmemh(htx_f, htx);
        if ($value$plusargs("PROG=%s", prog_f)) dut.imem.load_hex(prog_f);
        s_en = (role != 1);
        p_fd = $fopen(out_f, "w");
        p_log;

        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (2) @(posedge clk); #1 run = (role != 2);
        repeat (20) @(posedge clk);

        if (role == 0) wait (nr >= n || cyc >= tmax);
        else           m_run(n);
        repeat (200) @(posedge clk);
        $fdisplay(p_fd, "END cyc=%0d nw=%0d nr=%0d fault=%0d halted=%0d pc=%0d s_frames=%0d",
                  cyc, nw, nr, fault, halted, pc, s_idx);
        $fclose(p_fd);
        $finish;
    end
endmodule
