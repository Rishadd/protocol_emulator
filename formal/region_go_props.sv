// Formal property of the control unit's OP_REGION handling (src/engine_top.v built with SHARED_IMEM; instruction words, the window lock and the
// out-of-window flag are completely unconstrained inputs): whenever an engine passes OP_REGION on to the shared memory (rg_go), it is not locked and
// the window it names is valid: base < limit <= 512. This is the assumption of imem_shared.sby (P3, the lock).
module region_go_props (
    input wire        clk,
    input wire        rst_n_in,
    input wire        run,
    input wire [31:0] im_instr,
    input wire        im_oob,
    input wire        rg_locked,
    input wire [8:0]  start_pc,
    input wire        tx_wr_en,
    input wire [31:0] tx_wr_data,
    input wire        rx_rd_en,
    input wire [7:0]  pin_in
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = rst_n_in && !init;

    wire        tx_full, rx_empty, halted, fault, rg_go;
    wire [31:0] rx_rd_data;
    wire [7:0]  pin_out, pin_oe;
    wire [8:0]  pc, im_addr;
    wire [18:0] rg_val;
    engine_top dut (.clk(clk), .rst_n(rst_n), .run(run), .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
                    .im_addr(im_addr), .im_instr(im_instr), .im_oob(im_oob), .rg_go(rg_go), .rg_val(rg_val), .rg_locked(rg_locked), .start_pc(start_pc),
                    .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full), .rx_rd_en(rx_rd_en),
                    .rx_rd_data(rx_rd_data), .rx_empty(rx_empty), .pin_in(pin_in), .pin_out(pin_out), .pin_oe(pin_oe),
                    .halted(halted), .fault(fault), .pc(pc));

    always @(*) if (rg_go) assert (!rg_locked && {1'b0, rg_val[8:0]} < rg_val[18:9] && rg_val[18:9] <= 10'd512);
endmodule
