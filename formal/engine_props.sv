// Formal property of one protocol engine (src/engine_top.v with all its units; the SRAM macro is its synthesis blackbox, so the
// instruction word is completely unconstrained: the property holds whatever the memory returns):
//   E1 an engine that is held (run = 0) or in reset drives no pin: pin_oe = 0 and pin_out = 0, in the same clock run falls
// Together with formal/pin_mgr.sby (only a pad's owner reaches it) this gives: a pad is only ever driven by a running engine
// that owns it.
module engine_props (
    input wire        clk,
    input wire        rst_n_in,
    input wire        run,
    input wire        imem_we,
    input wire [7:0]  imem_waddr,
    input wire [31:0] imem_wdata,
    input wire        tx_wr_en,
    input wire [31:0] tx_wr_data,
    input wire        rx_rd_en,
    input wire [7:0]  pin_in
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = rst_n_in && !init;              // reset in the first clock, and whenever the environment asserts it

    wire        tx_full, rx_empty, halted, fault;
    wire [31:0] rx_rd_data;
    wire [7:0]  pin_out, pin_oe, pc;
    engine_top dut (.clk(clk), .rst_n(rst_n), .run(run), .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
                    .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full), .rx_rd_en(rx_rd_en),
                    .rx_rd_data(rx_rd_data), .rx_empty(rx_empty), .pin_in(pin_in), .pin_out(pin_out), .pin_oe(pin_oe),
                    .halted(halted), .fault(fault), .pc(pc));

    // E1
    always @(*) if (!run || !rst_n) assert (pin_oe == 8'd0 && pin_out == 8'd0);
endmodule
