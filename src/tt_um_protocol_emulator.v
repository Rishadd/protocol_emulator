// Tiny Tapeout top (template ports). Pin use per architecture doc §5:
//   ui_in[0] SCLK, ui_in[1] MOSI, ui_in[2] CS_N  (management SPI, mode 0)
//   uo_out[0] MISO
//   uio[7:0]  protocol pins P0..P7, shared by both engines
// Pin sharing until ownership registers exist: a pin is driven if either engine enables it;
// engine 0 wins if both do (that is a host configuration error).
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
    wire [5:0]  imem_waddr;
    wire [31:0] imem_wdata, tx_wr_data;
    wire        mgmt_err;

    wire [7:0]  out0, oe0, out1, oe1;
    wire [5:0]  pc0, pc1;
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
        .halted(halted), .fault(fault), .pc0(pc0), .pc1(pc1),
        .tx_full(tx_full), .rx_empty(rx_empty),
        .rx_data0(rx_data0), .rx_data1(rx_data1), .rx_rd_en(rx_rd_en),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data),
        .err(mgmt_err));

    engine_top u_eng0 (
        .clk(clk), .rst_n(srst_n), .run(eng_run[0]),
        .imem_we(imem_we[0]), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .tx_wr_en(tx_wr_en[0]), .tx_wr_data(tx_wr_data), .tx_full(tx_full[0]),
        .rx_rd_en(rx_rd_en[0]), .rx_rd_data(rx_data0), .rx_empty(rx_empty[0]),
        .pin_in(uio_in), .pin_out(out0), .pin_oe(oe0),
        .halted(halted[0]), .fault(fault[0]), .pc(pc0));

    engine_top u_eng1 (
        .clk(clk), .rst_n(srst_n), .run(eng_run[1]),
        .imem_we(imem_we[1]), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .tx_wr_en(tx_wr_en[1]), .tx_wr_data(tx_wr_data), .tx_full(tx_full[1]),
        .rx_rd_en(rx_rd_en[1]), .rx_rd_data(rx_data1), .rx_empty(rx_empty[1]),
        .pin_in(uio_in), .pin_out(out1), .pin_oe(oe1),
        .halted(halted[1]), .fault(fault[1]), .pc(pc1));

    assign uio_oe  = oe0 | oe1;
    assign uio_out = (oe0 & out0) | (~oe0 & out1);

    assign uo_out = {7'd0, miso};   // uo_out[7:1] status outputs come later

    wire _unused = &{ena, ui_in[7:3], mgmt_err, 1'b0};
endmodule
