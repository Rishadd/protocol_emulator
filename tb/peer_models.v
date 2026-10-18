`timescale 1ns/1ps
// Verilog peer models for the protocol testbenches (written from the specifications, independent of the firmware).
// peer_sel 0: none, 1: 1-Wire slave on pin 2 (tb/peer_onewire.v), 2: JTAG TAP (tb/peer_jtag.v): TCK 3, TMS 4, TDI 5, TDO 6.
// 3: CAN 2.0A node on pin 0 (tb/peer_can.v): acknowledges good frames, prints the frames it sees.
module peer_models (
    input  wire [7:0] pad,
    input  wire [7:0] peer_sel,
    output wire [7:0] peer_low
);
    wire ow_low, jt_low, can_low;
    peer_onewire ow (.dq(pad[2]), .dq_low(ow_low));
    peer_jtag    jt (.tck(pad[3]), .tms(pad[4]), .tdi(pad[5]), .tdo_low(jt_low));        // TDO on pad 6
    peer_can     cn (.en(peer_sel == 8'd3), .bus(pad[0]), .bus_low(can_low));
    assign peer_low = {1'b0, (peer_sel == 8'd2) ? jt_low : 1'b0, 3'b000, (peer_sel == 8'd1) ? ow_low : 1'b0, 1'b0,
                       (peer_sel == 8'd3) ? can_low : 1'b0};
endmodule
