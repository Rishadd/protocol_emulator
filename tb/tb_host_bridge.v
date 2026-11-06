`timescale 1ns/1ps
// Software SPI host bridge: the full chip (tt_um_protocol_emulator) driven line by line from stdin, so a Python program
// (host/chip_host.py) can talk to the RTL like a microcontroller would talk to the real chip. Run with vvp -n.
// One command per line, one reply line per command (stdout is flushed after every reply):
//   F <14 hex>        one 7-byte SPI frame (MSB first, mode 0): replies  F <14 hex>  with the 7 bytes seen on MISO
//   X <bits> <hex>    one frame of any length up to 128 bits (MSB first, the value right-aligned): replies  X <32 hex>  with the last 128 bits seen on MISO
//   I <hex> <hex>     set the pins   ui_in[7:3] (5 bits), uio_in (8 bits)                     replies  OK
//   W <dec>           advance the system clock by that many cycles                              replies  OK
//   G                 sample the pins                          replies  G <uo_out> <uio_out> <uio_oe> <time ns>
//   R                 chip reset (rst_n low for 3 clocks, then 4 clocks of settling)             replies  OK
//   T <dec> <dec>     SPI timing in ns: SCLK half period, CS_N setup/hold                        replies  OK
//   Q                 end of the simulation                                                      replies  OK
// USB low-speed bus (for host/usb_host.py): with U 1 the chip's uio[0] = D+ and uio[1] = D- are wired to a bus model: the device drives
// them when uio_oe is set, otherwise the host driver (B) does, otherwise the bus idles as J (D+ low by the host's pull-down, D- high by the
// device's 1.5 kOhm pull-up).
//   U <0|1>           bus model off / on (off: the I command's uio_in goes to the chip)               replies  OK
//   B <dp> <dm> <oe>  host driver levels and enable (no time passes)                                replies  OK
//   N <max>           run until the bus changes or <max> clocks passed         replies  N <clocks run> <dp><dm> <both driving: 0/1>
// System clock 50 MHz (20 ns). Default SPI timing: SCLK half period 200 ns (10 clocks), CS_N 100 ns (5 clocks), within the
// contract of docs/PROTOCOL_EMULATOR_ARCHITECTURE.md section 6 (>= 8 clocks per SCLK phase, >= 4 clocks CS_N setup / hold).
module tb_host_bridge;
    // waveform: run vvp with +dump to write build/wave/tb_host_bridge.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_host_bridge.vcd"); $dumpvars(0, tb_host_bridge); end
    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 200.0, spi_cs_ns = 100.0;
    reg  [4:0] ui_hi = 0;
    reg  [7:0] uio_in = 0;
    reg        usb_en = 0, h_oe = 0, h_dp = 0, h_dm = 1;
    integer    contend = 0;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];
    wire       bus_dp = uio_oe[0] ? uio_out[0] : h_oe ? h_dp : 1'b0;
    wire       bus_dm = uio_oe[1] ? uio_out[1] : h_oe ? h_dm : 1'b1;
    wire       both = usb_en && h_oe && (uio_oe[0] || uio_oe[1]);

`ifdef FPGA_TOP
    // the DE0-Nano wrapper (src/fpga/de0_nano_chip_top.v): the same chip behind the GPIO_2 header; pads uio = gpio2[8:1]
    wire [12:0] gp;
    wire [7:0]  led;
    assign gp[0] = 1'bz;  assign gp[9] = 1'bz;
    assign gp[10] = ui_hi[0];  assign gp[12:11] = ui_hi[2:1];
    genvar gi;
    generate for (gi = 0; gi < 8; gi = gi + 1) begin : g_pad
        assign gp[gi+1] = uio_oe[gi] ? 1'bz : (usb_en && gi < 2) ? (gi == 0 ? bus_dp : bus_dm) : uio_in[gi];
    end endgenerate
    de0_nano_chip_top dut (.clk_50M(clk), .reset_n(rst_n), .gpio2_in({cs_n, mosi, sclk}), .gpio2(gp), .led(led));
    assign uo_out = {led[7:2], gp[9], gp[0]};
    assign uio_out = dut.uio_out;  assign uio_oe = dut.uio_oe;
`else
    tt_um_protocol_emulator dut (.ui_in({ui_hi, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in(usb_en ? {uio_in[7:2], bus_dm, bus_dp} : uio_in), .uio_out(uio_out), .uio_oe(uio_oe), .ena(1'b1), .clk(clk), .rst_n(rst_n));
`endif

    `include "spi_master.vh"
    always #10 clk = ~clk;

    integer     stdin = 32'h8000_0000;
    integer     r, a, b, k;
    reg [1:0]   lvl;
    reg [8*8-1:0] cmd;
    reg [55:0]  w;
    reg [127:0] wide;

    initial begin
        repeat (3) @(posedge clk); #1 rst_n = 1; repeat (4) @(posedge clk);
        forever begin
            r = $fscanf(stdin, "%s", cmd);
            if (r != 1) $finish;
            if (cmd == "F") begin
                r = $fscanf(stdin, "%h", w);
                spi_begin; spi_bits({72'd0, w}, 56); spi_end;
                $display("F %014h", spi_rx[55:0]);
            end else if (cmd == "X") begin
                r = $fscanf(stdin, "%d %h", a, wide);
                spi_begin; spi_bits(wide, a); spi_end;
                $display("X %032h", spi_rx);
            end else if (cmd == "I") begin
                r = $fscanf(stdin, "%h %h", a, b);
                ui_hi = a[4:0]; uio_in = b[7:0];
                $display("OK");
            end else if (cmd == "W") begin
                r = $fscanf(stdin, "%d", a);
                repeat (a) @(posedge clk);
                $display("OK");
            end else if (cmd == "G") begin
                $display("G %02h %02h %02h %0d", uo_out, uio_out, uio_oe, $time);
            end else if (cmd == "R") begin
                rst_n = 0; repeat (3) @(posedge clk); #1 rst_n = 1; repeat (4) @(posedge clk);
                $display("OK");
            end else if (cmd == "T") begin
                r = $fscanf(stdin, "%d %d", a, b);
                spi_half_ns = a; spi_cs_ns = b;
                $display("OK");
            end else if (cmd == "U") begin
                r = $fscanf(stdin, "%d", a);
                usb_en = a[0];
                $display("OK");
            end else if (cmd == "B") begin
                r = $fscanf(stdin, "%d %d %d", a, b, k);
                h_dp = a[0]; h_dm = b[0]; h_oe = k[0];
                $display("OK");
            end else if (cmd == "N") begin
                r = $fscanf(stdin, "%d", a);
                k = 0; lvl = {bus_dp, bus_dm};
                while (k < a && {bus_dp, bus_dm} === lvl) begin @(posedge clk); #1; k = k + 1; end
                $display("N %0d %b%b %0d", k, bus_dp, bus_dm, both);
            end else if (cmd == "Q") begin
                $display("OK");
                $finish;
            end else begin
                $display("ERR unknown command");
            end
            $fflush;
        end
    end
endmodule
