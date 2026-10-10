`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// Step 6: READ over MISO. 7-byte frame both ways; MISO = {STATUS, 00, 00, data[31:0]}.
// RX data comes from the real UART RX firmware (src/fpga/uart_rx_prog.hex, P1, 115200 @ 50 MHz)
// fed by a bit-banged UART on uio_in[1]. Waveform: build/tb_mgmt_read.vcd
module tb_mgmt_read;
    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 80.0, spi_cs_ns = 60.0;
    reg  [7:0] uio_in = 8'b0000_0010;               // P1 = UART line, idle high
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];

    tt_um_protocol_emulator dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));

    `include "spi_master.vh"

    localparam integer BIT = 434;                   // clocks per UART bit (115200 @ 50 MHz)
    localparam [7:0]  OP_WR = 8'h01, OP_RD = 8'h02;
    localparam [31:0] W_HALT = {`OP_HALT, 27'd0};
    localparam [7:0]  ST_ALIVE = 8'h80, ST_ERR = 8'h40, ST_RUN1 = 8'h20, ST_RUN0 = 8'h10,
                      ST_RX1 = 8'h02, ST_RX0 = 8'h01;

    integer errors = 0, k, miso_viol = 0;
    reg [7:0]  st;                                  // STATUS byte of the last frame
    reg [15:0] mid;                                 // MISO bytes 1-2 of the last frame
    reg [31:0] rd;                                  // MISO bytes 3-6 of the last frame
    reg [31:0] img [0:63];

    always #5 clk = ~clk;

    // mode 0: MISO may only change while SCLK is low (or CS_N is high)
    always @(miso) if (!cs_n && sclk === 1'b1) miso_viol = miso_viol + 1;

    task frame(input [7:0] op, input [15:0] a, input [31:0] d);
        begin
            spi_begin; spi_bits({72'd0, op, a, d}, 56); spi_end;
            {st, mid, rd} = spi_rx[55:0];
            repeat (4) @(posedge clk); #1;
        end
    endtask
    task wr(input [15:0] a, input [31:0] d); frame(OP_WR, a, d); endtask
    task rdreg(input [15:0] a);              frame(OP_RD, a, 32'd0); endtask
    function [15:0] base(input e); base = e ? 16'h2000 : 16'h1000; endfunction
    task ctrl(input e, input r); wr(base(e), {31'd0, r}); endtask
    task rx_read(input e); rdreg(base(e) + 16'h204); endtask

    task load_rx_image(input e);
        integer j;
        begin
            for (j = 0; j < 64; j = j + 1) img[j] = W_HALT;
            $readmemh("src/fpga/uart_rx_prog.hex", img);
            ctrl(e, 0);
            for (j = 0; j < 64; j = j + 1) wr(base(e) + 16'h100 + 4 * j, img[j]);
        end
    endtask

    // 8N1, LSB first, on P1
    task uart_send(input [7:0] b);
        integer i;
        begin
            @(posedge clk); uio_in[1] = 1'b0; repeat (BIT) @(posedge clk);
            for (i = 0; i < 8; i = i + 1) begin uio_in[1] = b[i]; repeat (BIT) @(posedge clk); end
            uio_in[1] = 1'b1; repeat (BIT) @(posedge clk);
        end
    endtask

    task expect_byte(input e, input [7:0] b, input [8*40-1:0] tag);
        begin
            rx_read(e);
            `CHECK(st[e ? 1 : 0] == 1'b1, "STATUS showed data for this engine")
            `CHECK(rd == {b, 24'd0} && mid == 16'h0000, tag)
            if (rd !== {b, 24'd0}) $display("    got %h expected %h", rd, {b, 24'd0});
        end
    endtask

    task do_reset; begin rst_n = 0; repeat (2) @(posedge clk); #1 rst_n = 1; repeat (2) @(posedge clk); #1; end endtask

    initial begin
        $dumpfile("build/tb_mgmt_read.vcd");
        $dumpvars(0, tb_mgmt_read);
        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk); #1;

        $display("--- R1 after reset: STATUS = alive only, CTRL reads 0, MISO low while idle");
        `CHECK(miso === 1'b0, "MISO low with CS_N high")
        rdreg(16'h1000);
        `CHECK(st == ST_ALIVE && mid == 0 && rd == 0, "status 0x80, CTRL0 = 0")
        `CHECK(miso === 1'b0, "MISO low again after the frame")

        $display("--- R2 engine 1 = UART RX image, RUN; CTRL read shows RUN, PC parked at WAITL");
        load_rx_image(1);
        wr(16'h1000, 32'd0);
        `CHECK(st == ST_ALIVE && mid == 0 && rd == 0, "WRITE frame returns status + zeros")
        ctrl(1, 1);
        rdreg(16'h2000);
        `CHECK(st == (ST_ALIVE | ST_RUN1), "status shows RUN1")
        `CHECK(rd == {18'd0, 6'd2, 5'd0, 3'b001}, "CTRL1 = pc 2, not halted, no fault, RUN")

        $display("--- R3 one UART byte -> STATUS rx bit -> READ pops it");
        uart_send(8'h55); repeat (100) @(posedge clk);
        expect_byte(1, 8'h55, "0x55 read from engine 1 RX FIFO");
        rdreg(16'h2000);
        `CHECK(st == (ST_ALIVE | ST_RUN1), "FIFO empty after the pop")

        $display("--- R4 four bytes (FIFO full) read back in order; then empty read");
        uart_send(8'h00); uart_send(8'hFF); uart_send(8'hA5); uart_send(8'h3C);
        repeat (100) @(posedge clk);
        `CHECK(dut.u_eng1.rx_fifo.full == 1, "RX FIFO full")
        expect_byte(1, 8'h00, "byte 1 of 4");
        expect_byte(1, 8'hFF, "byte 2 of 4");
        expect_byte(1, 8'hA5, "byte 3 of 4");
        expect_byte(1, 8'h3C, "byte 4 of 4");
        rx_read(1);
        `CHECK(st == (ST_ALIVE | ST_RUN1) && rd == 0, "empty read: status says empty, data 0")
        rdreg(16'h2000);
        `CHECK((st & ST_ERR) == 0 && dut.u_mgmt.err == 0, "empty read is not an error")

        $display("--- R5 aborted READ (CS_N up after 5 bytes) pops nothing");
        uart_send(8'h77); repeat (100) @(posedge clk);
        spi_begin; spi_bits({88'd0, OP_RD, 16'h2204, 16'h0000}, 40); spi_end; repeat (4) @(posedge clk);
        `CHECK(dut.u_eng1.rx_empty == 0, "byte still in FIFO after abort")
        expect_byte(1, 8'h77, "full READ after abort returns the same byte");
        rdreg(16'h2000);
        `CHECK((st & ST_ERR) != 0, "aborted frame flagged in STATUS err bit");
        do_reset;                                   // clears err; memory kept, engines held
        ctrl(1, 1);

        $display("--- R6 byte arriving mid-READ: frame said empty -> returns 0, pops nothing");
        spi_half_ns = 2000.0;                       // one frame = 22,400 clocks, a UART byte = 4,340
        fork
            uart_send(8'h99);
            rx_read(1);
        join
        `CHECK(st[1] == 0 && rd == 0, "READ started on an empty FIFO returns 0")
        `CHECK(dut.u_eng1.rx_empty == 0, "the byte that arrived mid-frame is still queued")
        spi_half_ns = 80.0;
        expect_byte(1, 8'h99, "next READ gets it");

        $display("--- R7 both engines run the RX image on the same line; FIFOs read independently");
        load_rx_image(0); ctrl(0, 1);
        uart_send(8'h11); uart_send(8'h22); repeat (100) @(posedge clk);
        rdreg(16'h1000);
        `CHECK((st & 8'h33) == 8'h33, "both RUN, both have data")
        expect_byte(0, 8'h11, "engine 0 first byte");
        expect_byte(0, 8'h22, "engine 0 second byte");
        rdreg(16'h1000);
        `CHECK((st & 8'h03) == ST_RX1, "engine 0 empty, engine 1 untouched")
        expect_byte(1, 8'h11, "engine 1 first byte");
        expect_byte(1, 8'h22, "engine 1 second byte");

        $display("--- R8 CTRL read reflects halted and fault");
        ctrl(0, 0); wr(16'h1100, W_HALT); ctrl(0, 1);
        rdreg(16'h1000);
        `CHECK(rd == 32'h0000_0003, "CTRL0: RUN, halted, pc 0")
        ctrl(0, 0); wr(16'h1100, {5'd31, 27'd0}); ctrl(0, 1);
        rdreg(16'h1000);
        `CHECK(rd == 32'h0000_0007, "CTRL0: RUN, halted, fault")
        ctrl(0, 0);
        rdreg(16'h1000);
        `CHECK(rd == 32'h0000_0000, "CTRL0 after RUN=0: all clear")

        $display("--- R9 unreadable addresses: data 0 and err");
        do_reset;
        rdreg(16'h1100); `CHECK(rd == 0 && dut.u_mgmt.err == 1, "IMEM window not readable") do_reset;
        rdreg(16'h1200); `CHECK(rd == 0 && dut.u_mgmt.err == 1, "0x1200 not readable") do_reset;
        rdreg(16'h3204); `CHECK(rd == 0 && dut.u_mgmt.err == 1, "0x3204 unmapped") do_reset;
        rdreg(16'h2206); `CHECK(rd == 0 && dut.u_mgmt.err == 1, "misaligned RX_DATA") do_reset;
        frame(8'h03, 16'h2204, 32'd0); `CHECK(dut.u_mgmt.err == 1, "op 0x03 rejected") do_reset;

        $display("--- R10 read path over the SCLK sweep (half period 8, 8.7, 13.3, 50 clocks)");
        ctrl(1, 1);
        spi_half_ns = 80.0;  uart_send(8'hC3); repeat (100) @(posedge clk); expect_byte(1, 8'hC3, "8 clk");
        spi_half_ns = 87.0;  uart_send(8'h3C); repeat (100) @(posedge clk); expect_byte(1, 8'h3C, "8.7 clk");
        spi_half_ns = 133.0; uart_send(8'h81); repeat (100) @(posedge clk); expect_byte(1, 8'h81, "13.3 clk");
        spi_half_ns = 500.0; uart_send(8'h7E); repeat (100) @(posedge clk); expect_byte(1, 8'h7E, "50 clk");
        spi_half_ns = 80.0;

        `CHECK(miso_viol == 0, "MISO never changed while SCLK was high")
        $display("    MISO changes while SCLK high: %0d", miso_viol);
        `REPORT("tb_mgmt_read")
        $finish;
    end
endmodule
