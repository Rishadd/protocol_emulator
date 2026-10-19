// Tiny Tapeout top (template ports). Pin use (docs/PIN_MAP_PLAN.md):
//   fixed:    ui_in[0] SCLK, ui_in[1] MOSI, ui_in[2] CS_N (management SPI, mode 0), uo_out[0] MISO
//   remappable through pin_mgr (management window 0x0200), defaults after reset:
//     uio[7:0]     protocol pads, logical pin i = uio[i] for both engines, not driven until claimed
//     ui_in[3]     HOLD (high = both engines held, engine-driven pins released)
//     ui_in[4]     TRIG_IN (logic analyser, later)
//     ui_in[7:5]   DBG_SEL, picks the debug view on uo_out[7:2] (dbg_view.v)
//     uo_out[1]    IRQ
//   A pin owned by an engine carries one of its 8 logical pins; each engine's 8 logical inputs select
//   any of uio[7:0], ui_in[7:3].
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
    // asynchronous assert, synchronous release
    reg [1:0] rst_sync;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) rst_sync <= 2'b00;
        else        rst_sync <= {rst_sync[0], 1'b1};
    wire srst_n = rst_sync[1];

    wire        byte_valid, spi_active, frame_end, frame_clean, miso;
    wire [7:0]  rx_byte, tx_byte;
    wire [1:0]  eng_run, imem_we, rx_rd_en, tx_wr_en;
    wire [8:0]  imem_waddr;
    wire [31:0] imem_wdata, tx_wr_data;
`ifdef SHARED_IMEM
    wire        imem_ok;
    wire [8:0]  start0, start1;
    wire [31:0] instr0, instr1;
    wire [8:0]  im_addr0, im_addr1;
    wire        rg_go0, rg_go1, rg_locked0, rg_locked1;
    wire [18:0] rg_val0, rg_val1;
`endif
    wire        mgmt_err;
    wire [5:0]  pin_wa, pin_ra;
    wire [31:0] pin_wd, pin_rd;
    wire        pin_hit, pin_ok, pin_we, hold, trig_en, irq;
    wire [2:0]  view_sel;
    wire [5:0]  view;
    wire [6:0]  uo_hi;

    wire [7:0]  out0, oe0, out1, oe1, in0, in1;
    wire [8:0]  pc0, pc1;
    wire [31:0] rx_data0, rx_data1;
    wire [1:0]  halted, fault, tx_full, rx_empty;

    spi_slave u_spi (
        .clk(clk), .rst_n(srst_n),
        .sclk(ui_in[0]), .mosi(ui_in[1]), .cs_n(ui_in[2]), .miso(miso),
        .byte_valid(byte_valid), .rx_byte(rx_byte), .tx_byte(tx_byte),
        .active(spi_active), .frame_end(frame_end), .frame_clean(frame_clean));

    mgmt u_mgmt (
        .clk(clk), .rst_n(srst_n),
        .byte_valid(byte_valid), .rx_byte(rx_byte), .tx_byte(tx_byte),
        .active(spi_active), .frame_end(frame_end), .frame_clean(frame_clean),
        .eng_run(eng_run),
        .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
`ifdef SHARED_IMEM
        .imem_ok(imem_ok), .start0(start0), .start1(start1),
`endif
        .halted(halted), .fault(fault), .pc0(pc0), .pc1(pc1),
        .tx_full(tx_full), .rx_empty(rx_empty),
        .rx_data0(rx_data0), .rx_data1(rx_data1), .rx_rd_en(rx_rd_en),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data),
        .pin_wa(pin_wa), .pin_wd(pin_wd), .pin_hit(pin_hit), .pin_ok(pin_ok), .pin_we(pin_we),
        .pin_ra(pin_ra), .pin_rd(pin_rd), .hold(hold),
        .err(mgmt_err));

    pin_mgr u_pins (
        .clk(clk), .rst_n(srst_n), .run(eng_run),
        .w_addr(pin_wa), .w_data(pin_wd), .w_hit(pin_hit), .w_ok(pin_ok), .we(pin_we),
        .r_addr(pin_ra), .r_data(pin_rd),
        .oe0(oe0), .out0(out0), .oe1(oe1), .out1(out1), .in0(in0), .in1(in1),
        .uio_in(uio_in), .ui_hi(ui_in[7:3]), .uio_oe(uio_oe), .uio_out(uio_out), .uo_hi(uo_hi), .view(view),
        .irq_src({mgmt_err, fault, halted, ~rx_empty}),
        .hold(hold), .trig_en(trig_en), .view_sel(view_sel), .irq(irq),
        .owner(), .od(), .remap(), .oowner(), .oremap(), .isel0_r(), .isel1_r(), .viol(), .misc(), .vsel(), .mask(), .irq_st());

    dbg_view u_dbg (
        .clk(clk), .rst_n(srst_n), .sel(view_sel), .err(mgmt_err), .run(eng_run), .halted(halted), .fault(fault),
        .rx_byte(rx_byte), .byte_valid(byte_valid), .frame_end(frame_end), .frame_clean(frame_clean),
        .active(spi_active), .ui_hi(ui_in[7:3]), .uio_in(uio_in), .view(view));

`ifdef SHARED_IMEM
    imem_shared u_imem (
        .clk(clk), .rst_n(srst_n), .run(eng_run),
        .f_addr0(im_addr0), .f_addr1(im_addr1), .f_instr0(instr0), .f_instr1(instr1),
        .rg_go0(rg_go0), .rg_go1(rg_go1), .rg_val0(rg_val0), .rg_val1(rg_val1),
        .locked0(rg_locked0), .locked1(rg_locked1),
        .iw_wr(imem_we[0]), .iw_addr(imem_waddr), .iw_data(imem_wdata), .iw_ok(imem_ok));
`endif

    engine_top u_eng0 (
        .clk(clk), .rst_n(srst_n), .run(eng_run[0]),
        .imem_we(imem_we[0]), .imem_waddr(imem_waddr[7:0]), .imem_wdata(imem_wdata),
`ifdef SHARED_IMEM
        .im_addr(im_addr0), .im_instr(instr0),
        .rg_go(rg_go0), .rg_val(rg_val0), .rg_locked(rg_locked0), .start_pc(start0),
`endif
        .tx_wr_en(tx_wr_en[0]), .tx_wr_data(tx_wr_data), .tx_full(tx_full[0]),
        .rx_rd_en(rx_rd_en[0]), .rx_rd_data(rx_data0), .rx_empty(rx_empty[0]),
        .pin_in(in0), .pin_out(out0), .pin_oe(oe0),
        .halted(halted[0]), .fault(fault[0]), .pc(pc0));

    engine_top u_eng1 (
        .clk(clk), .rst_n(srst_n), .run(eng_run[1]),
        .imem_we(imem_we[1]), .imem_waddr(imem_waddr[7:0]), .imem_wdata(imem_wdata),
`ifdef SHARED_IMEM
        .im_addr(im_addr1), .im_instr(instr1),
        .rg_go(rg_go1), .rg_val(rg_val1), .rg_locked(rg_locked1), .start_pc(start1),
`endif
        .tx_wr_en(tx_wr_en[1]), .tx_wr_data(tx_wr_data), .tx_full(tx_full[1]),
        .rx_rd_en(rx_rd_en[1]), .rx_rd_data(rx_data1), .rx_empty(rx_empty[1]),
        .pin_in(in1), .pin_out(out1), .pin_oe(oe1),
        .halted(halted[1]), .fault(fault[1]), .pc(pc1));

    assign uo_out = {uo_hi, miso};

    wire _unused = &{ena, trig_en, 1'b0};
endmodule
