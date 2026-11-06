`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// Pin manager through the management link (full chip): window 0x0200 claims, readback, refusals (err),
// violations + write-one-to-clear, ownership and open-drain at the uio pads.
module tb_mgmt_pins;
    // waveform: run vvp with +dump to write build/wave/tb_mgmt_pins.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_mgmt_pins.vcd"); $dumpvars(0, tb_mgmt_pins); end
    localparam [7:0] OP_WR = 8'h01, OP_RD = 8'h02;
    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 100.0, spi_cs_ns = 60.0;
    reg  [7:0] pin_in = 0;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];
    integer    errors = 0, j;
    reg  [7:0] st;
    reg [15:0] mid;
    reg [31:0] rd;

    reg  [4:0] ui_hi = 0;                    // ui_in[7:3]
    tt_um_protocol_emulator dut (.ui_in({ui_hi, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in(pin_in), .uio_out(uio_out), .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n));

    `include "spi_master.vh"
    always #5 clk = ~clk;

    task frame(input [7:0] op, input [15:0] a, input [31:0] d);
        begin spi_begin; spi_bits({72'd0, op, a, d}, 56); spi_end; {st, mid, rd} = spi_rx[55:0]; end
    endtask
    task chip_reset; begin rst_n = 0; repeat (3) @(posedge clk); #1 rst_n = 1; repeat (4) @(posedge clk); end endtask
    reg [31:0] prog [0:15];
    task load0(input integer n);   // engine 0 program from prog[], rest HALT
        for (j = 0; j < 64; j = j + 1) frame(OP_WR, 16'h1400 + 4 * j, j < n ? prog[j] : {`OP_HALT, 27'd0});
    endtask
    function [31:0] I(input [4:0] op, input [26:0] v); I = {op, v}; endfunction

    initial begin
        chip_reset;
        // ---- reset state and readback
        for (j = 0; j < 8; j = j + 1) begin
            frame(OP_RD, 16'h0200 + 4 * j, 0);                             // a READ returns its own address
            `CHECK(rd == 0, "reset: pad unowned, push-pull")
        end
        frame(OP_WR, 16'h0208, 32'd1);  frame(OP_WR, 16'h0218, 32'd6);   // pad 2 -> eng0, pad 6 -> eng1 od
        frame(OP_RD, 16'h0218, 0);
        `CHECK(rd == 32'd6, "pad 6 reads back {od=1, owner=2}")
        frame(OP_RD, 16'h0208, 0);
        `CHECK(rd == 32'd1, "pad 2 reads back {od=0, owner=1}")
        frame(OP_RD, 16'h1000, 0);
        `CHECK(st[6] == 0, "valid claims and reads leave err clear")

        // ---- refusals, each from a fresh reset because err is sticky
        chip_reset; frame(OP_WR, 16'h0200, 32'd3); frame(OP_RD, 16'h0200, 0);
        `CHECK(st[6] == 1 && rd == 0, "owner 3 refused: err, no change")
        chip_reset; frame(OP_WR, 16'h0200, 32'h41); frame(OP_RD, 16'h0200, 0);
        `CHECK(st[6] == 1 && rd == 0, "reserved data bit refused")
        chip_reset; frame(OP_WR, 16'h0224, 32'd1); frame(OP_RD, 16'h1000, 0);
        `CHECK(st[6] == 1, "unmapped 0x0224 sets err")
        chip_reset; frame(OP_WR, 16'h0201, 32'd1); frame(OP_RD, 16'h1000, 0);
        `CHECK(st[6] == 1, "misaligned 0x0201 sets err")
        chip_reset; frame(OP_WR, 16'h0220, 32'h10000); frame(OP_RD, 16'h1000, 0);
        `CHECK(st[6] == 1, "VIOL write with reserved bits sets err")
        chip_reset;
        frame(OP_WR, 16'h0208, 32'd1); frame(OP_WR, 16'h1000, 32'd1);      // pad 2 -> eng0, RUN eng0
        frame(OP_WR, 16'h0208, 32'd2); frame(OP_RD, 16'h0208, 0);
        `CHECK(st[6] == 1 && rd == 32'd1, "claim of a running engine's pad refused, owner kept")
        frame(OP_WR, 16'h1000, 32'd0); chip_reset;

        // ---- pads: ownership, violations, open-drain
        prog[0] = I(`OP_DIRO, 2);  prog[1] = I(`OP_SETH, 2);  prog[2] = I(`OP_DIRO, 3);
        prog[3] = I(`OP_SETLO, 6); prog[4] = I(`OP_DIRO, 6);  prog[5] = I(`OP_WAITH, 0);
        prog[6] = I(`OP_SETH, 6);  prog[7] = I(`OP_HALT, 0);
        load0(8);
        frame(OP_WR, 16'h0208, 32'd1);                 // pad 2: eng0 push-pull; pad 3 not claimed
        frame(OP_WR, 16'h0218, 32'd5);                 // pad 6: eng0 open-drain
        frame(OP_WR, 16'h1000, 32'd1);
        repeat (20) @(posedge clk);
        `CHECK(uio_oe[2] == 1 && uio_out[2] == 1, "owned push-pull pad driven high")
        `CHECK(uio_oe[3] == 0, "unowned pad not driven although the engine enables it")
        `CHECK(uio_oe[6] == 1 && uio_out[6] == 0, "open-drain pad pulls low for out=0")
        frame(OP_RD, 16'h0220, 0);
        `CHECK(rd == 32'h0008, "violation recorded: engine 0 on pad 3")
        frame(OP_WR, 16'h0220, 32'h0008); frame(OP_RD, 16'h0220, 0);
        `CHECK(rd == 32'h0008, "still violating: new event wins over the clear")
        pin_in[0] = 1; repeat (20) @(posedge clk);
        `CHECK(uio_oe[6] == 0, "open-drain pad released for out=1 (never driven high)")
        frame(OP_WR, 16'h1000, 32'd0); repeat (4) @(posedge clk);
        `CHECK(uio_oe == 0, "held engine drives nothing")
        frame(OP_WR, 16'h0220, 32'h0008); frame(OP_RD, 16'h0220, 0);
        `CHECK(rd == 0, "W1C clears once the engine stopped")
        frame(OP_WR, 16'h0208, 32'd2); frame(OP_RD, 16'h0208, 0);
        `CHECK(rd == 32'd2 && st[6] == 0, "pad of a held engine can be handed to engine 1")

        // ---- remapping, uo_out, input select, HOLD, IRQ and debug views (docs/PIN_MAP_PLAN.md)
        chip_reset;
        // engine 0: logical pin 0 = output high (-> pad 5 via remap, and uo_out[4]), logical pin 1 = input read into the RX FIFO
        prog[0] = I(`OP_DIRO, 0);  prog[1] = I(`OP_SETH, 0);  prog[2] = I(`OP_HALT, 0);
        load0(3);
        frame(OP_WR, 16'h0214, {26'd0, 3'd5, 1'b0, 2'd1});            // pad 5 <- engine 0 logical pin 5 ^ 5 = 0
        frame(OP_RD, 16'h0214, 0);
        `CHECK(rd == {26'd0, 3'd5, 1'b0, 2'd1}, "PAD readback with remap")
        frame(OP_WR, 16'h0250, {26'd0, 3'd4, 1'b0, 2'd1});            // ... now logical pin 0
        frame(OP_RD, 16'h0250, 0);
        `CHECK(rd == {26'd0, 3'd4, 1'b0, 2'd1}, "OPAD readback")
        frame(OP_WR, 16'h1000, 32'd1); repeat (30) @(posedge clk);
        `CHECK(uio_oe[5] == 1 && uio_out[5] == 1 && uio_oe[0] == 0, "remap: pad 5 carries logical pin 0")
        `CHECK(uo_out[4] == 1, "uo_out[4] carries logical pin 0")
        frame(OP_RD, 16'h0220, 0);
        `CHECK(rd == 0, "no violation: logical pin 0 is carried")
        frame(OP_WR, 16'h1000, 32'd0); repeat (4) @(posedge clk);
        `CHECK(uio_oe == 0, "held engine drives nothing")
        // IRQ: engine 0 halted becomes a status bit, unmasked it drives uo_out[1]
        frame(OP_RD, 16'h02C4, 0);
        `CHECK(rd[7:0] == 8'h04, "IRQ status readable (halted e0 once the engine halted)")
        frame(OP_WR, 16'h02C4, 32'hFF); frame(OP_WR, 16'h02C0, 32'h0004_0007);
        `CHECK(uo_out[1] == 0, "IRQ low when the status is clear")
        frame(OP_WR, 16'h1000, 32'd1); repeat (30) @(posedge clk);
        `CHECK(uo_out[1] == 1, "IRQ high once the engine halted")
        frame(OP_WR, 16'h1000, 32'd0); frame(OP_WR, 16'h02C4, 32'h04); repeat (4) @(posedge clk);
        `CHECK(uo_out[1] == 0, "W1C of the IRQ status clears the pin")
        // input select: logical input 2 of engine 0 reads ui_in[7] (isel 12) instead of uio[2]
        frame(OP_WR, 16'h0288, 32'd12);
        ui_hi = 5'b10000; pin_in = 0; frame(OP_RD, 16'h02C8, 0);
        `CHECK(rd[12:8] == 5'b10000, "INPUTS register shows ui_in[7:3]")
        // HOLD: ui_in[3] high stops the engines and releases the pins; RUN cannot be set while it is high
        frame(OP_WR, 16'h0200, 32'd1); frame(OP_WR, 16'h1000, 32'd1);
        ui_hi = 5'b00001; repeat (8) @(posedge clk);
        frame(OP_RD, 16'h1000, 0);
        `CHECK(rd[0] == 0 && uio_oe == 0, "HOLD: RUN cleared, pins released")
        frame(OP_WR, 16'h1000, 32'd1); frame(OP_RD, 16'h1000, 0);
        `CHECK(rd[0] == 0 && st[6] == 1, "HOLD: RUN write refused (err)")
        frame(OP_WR, 16'h02C4, 32'h40); frame(OP_RD, 16'h1000, 0); frame(OP_RD, 16'h1000, 0);
        `CHECK(st[6] == 0, "IRQ bit 6 write-one-to-clear also clears err")
        ui_hi = 0;
        frame(OP_WR, 16'h0250, 32'd0);                           // release uo_out[4] to its default function
        // debug views: view 3 mirrors ui_in[7:3] and uio[0]; view 2 shows the last SPI byte
        frame(OP_WR, 16'h02C0, 32'h0000_0003);                      // dbg_en = 0, view 0
        frame(OP_WR, 16'h02C0, 32'h0000_0033);                      // view 3
        ui_hi = 5'b10110; pin_in = 8'h01; repeat (4) @(posedge clk);
        `CHECK(uo_out[7:2] == 6'b110110, "view 3: uio[0] and ui_in[7:3]")
        pin_in = 0; ui_hi = 0;
        frame(OP_WR, 16'h02C0, 32'h0000_0023);                      // view 2 (dbg_en = 0)
        frame(OP_RD, 16'h0200, 0);
        repeat (4) @(posedge clk);
        `CHECK(uo_out[5:2] == 4'h0, "view 2: last byte (0x00) bits [7:4]")
        frame(OP_WR, 16'h0200, 32'd0);
        frame(OP_WR, 16'h02C0, 32'h0000_0013);                      // view 1: last byte bits [3:0] (data LSB byte)
        frame(OP_WR, 16'h0200, 32'h5);
        repeat (4) @(posedge clk);
        `CHECK(uo_out[5:2] == 4'h5, "view 1: last byte [3:0]")

        `REPORT("tb_mgmt_pins")
        $finish;
    end
endmodule
