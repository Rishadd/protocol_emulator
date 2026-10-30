// DE0-Nano top for the whole protocol-emulator chip (tt_um_protocol_emulator, shared 512-word memory, no logic analyser).
// A host (Raspberry Pi Pico, docs/HOST_INTERFACE.md) talks to it over the management SPI; the protocol pads are on the GPIO_2 header.
//   GPIO_2_IN[0] = SCLK, GPIO_2_IN[1] = MOSI, GPIO_2_IN[2] = CS_N      (inputs)      -> chip ui_in[0..2]
//   GPIO_2[0]    = MISO                                                (output)      <- chip uo_out[0]
//   GPIO_2[8:1]  = protocol pads uio[7:0], bidirectional (chip uio_oe = drive)
//   GPIO_2[9]    = IRQ out (uo_out[1]);  GPIO_2[10] = HOLD in (ui_in[3]);  GPIO_2[12:11] = ui_in[5:4] (debug select bit 0, trigger in)
//   KEY0 = reset (low = reset), LED[0] = IRQ, LED[7:2] = debug view uo_out[7:2], LED[1] = clk heartbeat (about 1.5 Hz)
// The 50 MHz oscillator drives the chip directly.
module de0_nano_chip_top (
    input  wire        clk_50M,
    input  wire        reset_n,
    input  wire [2:0]  gpio2_in,
    inout  wire [12:0] gpio2,
    output wire [7:0]  led
);
    wire [7:0] uo_out, uio_out, uio_oe;
    wire [7:0] uio_in;

    // the management SPI inputs come from the header, everything else unused is tied low
    wire [7:0] ui_in = {2'b00, gpio2[12:11], gpio2[10], gpio2_in};

    tt_um_protocol_emulator u_chip (
        .ui_in(ui_in), .uo_out(uo_out), .uio_in(uio_in), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk_50M), .rst_n(reset_n));

    assign gpio2[0] = uo_out[0];                 // MISO
    assign gpio2[9] = uo_out[1];                 // IRQ
    genvar i;
    generate for (i = 0; i < 8; i = i + 1) begin : g_pad
        assign gpio2[i+1] = uio_oe[i] ? uio_out[i] : 1'bz;
        assign uio_in[i]  = gpio2[i+1];
    end endgenerate

    reg [24:0] beat;
    always @(posedge clk_50M) beat <= beat + 1'b1;
    assign led = {uo_out[7:2], beat[24], uo_out[1]};
endmodule
