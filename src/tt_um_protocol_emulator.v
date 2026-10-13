// Tiny Tapeout top (template ports). Pin use per architecture doc §5:
//   ui_in[0] SCLK, ui_in[1] MOSI, ui_in[2] CS_N  (management SPI, mode 0)
//   uo_out[0] MISO
//   uio[7:0]  protocol pins P0..P7, shared by both engines through pin_mgr: a pad is driven only by
//             the engine the host assigned it to (management window 0x0200), optionally open-drain.
//             Both engines always read every pad.
//   Shared L2 instruction memory (docs/TWO_TIER_MEMORY_PLAN.md): l2_mem, loaded by the host through mgmt.
//   Build with -DNO_L2 for the fallback chip without it (L2_EN = 0).
module tt_um_protocol_emulator (
    input  wire [7:0] ui_in,
    output wire [7:0] uo_out,
    input  wire [7:0] uio_in,
    output wire [7:0] uio_out,
    output wire [7:0] uio_oe,     // 1 = drive
    input  wire       ena,
    input  wire       clk,
    input  wire       rst_n
);
`ifdef NO_L2
    localparam L2_EN = 0;
`else
    localparam L2_EN = 1;
`endif
    // asynchronous assert, synchronous release
    reg [1:0] rst_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    wire srst_n = rst_sync[1];

    wire        byte_valid, spi_active, frame_end, frame_clean, miso;
    wire [7:0]  rx_byte, tx_byte;
    wire [1:0]  eng_run, imem_we, rx_rd_en, tx_wr_en;
    wire [5:0]  imem_waddr;
    wire [31:0] imem_wdata, tx_wr_data;
    wire        mgmt_err;
    wire [2:0]  pad_sel, pad_data;
    wire        pad_ok, pad_we;
    wire [15:0] viol_clr, pad_owner, pad_viol;
    wire [7:0]  pad_od;

    wire [7:0]  out0, oe0, out1, oe1;
    wire [8:0]  pc0, pc1;
    wire [3:0]  fault_cause;
    wire [17:0] reset_pc;
    wire [31:0] l2_range, l2_wdata, l2_rdata;
    wire [3:0]  fetch_cfg;
    wire [1:0]  arb_policy, l2_req, l2_req_hi, l2_gnt;
    wire        l2_we, l2_re;
    wire [7:0]  l2_addr;
    wire [15:0] l2_req_addr;
    wire [1:0]  bubble;
    wire [63:0] perf;
    wire [3:0]  perf_clr;
    wire [31:0] rx_data0, rx_data1;
    wire [1:0]  halted, fault, tx_full, rx_empty;

    spi_slave u_spi (
        .clk(clk), .rst_n(srst_n),
        .sclk(ui_in[0]), .mosi(ui_in[1]), .cs_n(ui_in[2]), .miso(miso),
        .byte_valid(byte_valid), .rx_byte(rx_byte), .tx_byte(tx_byte),
        .active(spi_active), .frame_end(frame_end), .frame_clean(frame_clean));

    mgmt #(.L2_EN(L2_EN)) u_mgmt (
        .clk(clk), .rst_n(srst_n),
        .byte_valid(byte_valid), .rx_byte(rx_byte), .tx_byte(tx_byte),
        .active(spi_active), .frame_end(frame_end), .frame_clean(frame_clean),
        .eng_run(eng_run),
        .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .halted(halted), .fault(fault), .pc0(pc0), .pc1(pc1), .fault_cause(fault_cause),
        .tx_full(tx_full), .rx_empty(rx_empty),
        .rx_data0(rx_data0), .rx_data1(rx_data1), .rx_rd_en(rx_rd_en),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data),
        .pad_sel(pad_sel), .pad_data(pad_data), .pad_ok(pad_ok), .pad_we(pad_we), .viol_clr(viol_clr),
        .pad_owner(pad_owner), .pad_od(pad_od), .pad_viol(pad_viol),
        .reset_pc(reset_pc), .l2_range(l2_range), .fetch_cfg(fetch_cfg), .arb_policy(arb_policy),
        .perf(perf), .perf_clr(perf_clr),
        .l2_we(l2_we), .l2_re(l2_re), .l2_addr(l2_addr), .l2_wdata(l2_wdata), .l2_rdata(l2_rdata),
        .err(mgmt_err));

    generate if (L2_EN) begin : g_l2
        l2_mem u_l2 (.clk(clk), .rst_n(srst_n), .h_we(l2_we), .h_re(l2_re), .h_addr(l2_addr), .h_wdata(l2_wdata),
                     .req(l2_req), .req_hi(l2_req_hi), .req_addr(l2_req_addr), .policy(arb_policy),
                     .gnt(l2_gnt), .rdata(l2_rdata));
    end else begin : g_no_l2
        assign l2_gnt = 2'b00;
        assign l2_rdata = 32'd0;
    end endgenerate

    pin_mgr u_pins (
        .clk(clk), .rst_n(srst_n), .run(eng_run),
        .cfg_pad(pad_sel), .cfg_data(pad_data), .cfg_ok(pad_ok), .cfg_we(pad_we), .viol_clr(viol_clr),
        .oe0(oe0), .out0(out0), .oe1(oe1), .out1(out1),
        .pad_oe(uio_oe), .pad_out(uio_out),
        .owner(pad_owner), .od(pad_od), .viol(pad_viol));

    engine_top #(.L2_EN(L2_EN)) u_eng0 (
        .clk(clk), .rst_n(srst_n), .run(eng_run[0]),
        .imem_we(imem_we[0]), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .tx_wr_en(tx_wr_en[0]), .tx_wr_data(tx_wr_data), .tx_full(tx_full[0]),
        .rx_rd_en(rx_rd_en[0]), .rx_rd_data(rx_data0), .rx_empty(rx_empty[0]),
        .pin_in(uio_in), .pin_out(out0), .pin_oe(oe0),
        .reset_pc(reset_pc[8:0]), .l2_range(l2_range[15:0]), .fetch_cfg(fetch_cfg[1:0]),
        .l2_req(l2_req[0]), .l2_req_hi(l2_req_hi[0]), .l2_addr(l2_req_addr[7:0]), .l2_gnt(l2_gnt[0]),
        .l2_rdata(l2_rdata), .bubble(bubble[0]),
        .perf_clr(perf_clr[1:0]), .perf_bubble(perf[15:0]), .perf_l2rd(perf[31:16]),
        .halted(halted[0]), .fault(fault[0]), .fault_cause(fault_cause[1:0]), .pc(pc0));

    engine_top #(.L2_EN(L2_EN)) u_eng1 (
        .clk(clk), .rst_n(srst_n), .run(eng_run[1]),
        .imem_we(imem_we[1]), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .tx_wr_en(tx_wr_en[1]), .tx_wr_data(tx_wr_data), .tx_full(tx_full[1]),
        .rx_rd_en(rx_rd_en[1]), .rx_rd_data(rx_data1), .rx_empty(rx_empty[1]),
        .pin_in(uio_in), .pin_out(out1), .pin_oe(oe1),
        .reset_pc(reset_pc[17:9]), .l2_range(l2_range[31:16]), .fetch_cfg(fetch_cfg[3:2]),
        .l2_req(l2_req[1]), .l2_req_hi(l2_req_hi[1]), .l2_addr(l2_req_addr[15:8]), .l2_gnt(l2_gnt[1]),
        .l2_rdata(l2_rdata), .bubble(bubble[1]),
        .perf_clr(perf_clr[3:2]), .perf_bubble(perf[47:32]), .perf_l2rd(perf[63:48]),
        .halted(halted[1]), .fault(fault[1]), .fault_cause(fault_cause[3:2]), .pc(pc1));

    assign uo_out = {7'd0, miso};   // uo_out[7:1] status outputs come later

    wire _unused = &{ena, ui_in[7:3], mgmt_err, 1'b0};
endmodule
