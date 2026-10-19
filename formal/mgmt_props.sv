// End-to-end formal properties of the management side: src/spi_slave.v + src/mgmt.v + src/pin_mgr.v as wired in
// tt_um_protocol_emulator, with the SPI pins (SCLK, MOSI, CS_N) and every engine-side signal completely unconstrained.
//   M1 a pin configuration write is applied only when the pin manager accepts it in that same clock (the contract that
//      formal/pin_mgr.sby assumes; pad_we is registered one clock after the check, so this also proves that nothing the check
//      depends on - pad, data, owner, run - can change in between, whatever the SPI pins do)
//   M2 an instruction memory write only ever goes to a held engine
//   M3 every state change (RUN, memory write, TX push, RX pop, pin configuration, violation clear) follows a clean frame of
//      exactly 7 bytes; an aborted, short or long frame changes nothing
module mgmt_props (
    input wire        clk,
    input wire        sclk, mosi, cs_n,
    input wire [1:0]  halted, fault, tx_full, rx_empty,
    input wire [7:0]  pc0, pc1,
    input wire [31:0] rx_data0, rx_data1,
    input wire [7:0]  oe0, out0, oe1, out1, uio_in,
    input wire [4:0]  ui_hi,
    input wire [5:0]  view
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire        byte_valid, active, frame_end, frame_clean, miso;
    wire [7:0]  rx_byte, tx_byte;
    wire [1:0]  eng_run, imem_we, rx_rd_en, tx_wr_en;
    wire [7:0]  imem_waddr, uio_oe, uio_out, in0, in1;
    wire [31:0] imem_wdata, tx_wr_data, pin_wd, pin_rd, isel0, isel1;
    wire [5:0]  pin_wa, pin_ra;
    wire [6:0]  uo_hi;
    wire [2:0]  view_sel, misc, vsel;
    wire        pin_hit, pin_ok, pin_we, err, hold, trig_en, irq;
    wire [15:0] owner, oowner, viol, mask;
    wire [23:0] remap, oremap;
    wire [7:0]  od, irq_st;

    spi_slave u_spi (.clk(clk), .rst_n(rst_n), .sclk(sclk), .mosi(mosi), .cs_n(cs_n), .miso(miso),
                     .byte_valid(byte_valid), .rx_byte(rx_byte), .tx_byte(tx_byte),
                     .active(active), .frame_end(frame_end), .frame_clean(frame_clean));
    mgmt u_mgmt (.clk(clk), .rst_n(rst_n), .byte_valid(byte_valid), .rx_byte(rx_byte), .tx_byte(tx_byte),
                 .active(active), .frame_end(frame_end), .frame_clean(frame_clean), .eng_run(eng_run),
                 .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
                 .halted(halted), .fault(fault), .pc0(pc0), .pc1(pc1), .tx_full(tx_full), .rx_empty(rx_empty),
                 .rx_data0(rx_data0), .rx_data1(rx_data1), .rx_rd_en(rx_rd_en), .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data),
                 .pin_wa(pin_wa), .pin_wd(pin_wd), .pin_hit(pin_hit), .pin_ok(pin_ok), .pin_we(pin_we),
                 .pin_ra(pin_ra), .pin_rd(pin_rd), .hold(hold), .err(err));
    pin_mgr u_pins (.clk(clk), .rst_n(rst_n), .run(eng_run), .w_addr(pin_wa), .w_data(pin_wd), .w_hit(pin_hit), .w_ok(pin_ok),
                    .we(pin_we), .r_addr(pin_ra), .r_data(pin_rd), .oe0(oe0), .out0(out0), .oe1(oe1), .out1(out1), .in0(in0), .in1(in1),
                    .uio_in(uio_in), .ui_hi(ui_hi), .uio_oe(uio_oe), .uio_out(uio_out), .uo_hi(uo_hi), .view(view),
                    .irq_src({err, fault, halted, ~rx_empty}), .hold(hold), .trig_en(trig_en), .view_sel(view_sel), .irq(irq),
                    .owner(owner), .od(od), .remap(remap), .oowner(oowner), .oremap(oremap), .isel0_r(isel0), .isel1_r(isel1),
                    .viol(viol), .misc(misc), .vsel(vsel), .mask(mask), .irq_st(irq_st));

    // bytes of the current frame, counted here from the SPI slave's outputs (independent of mgmt's own counter)
    reg [3:0] nb;
    always @(posedge clk)
        if (init || frame_end) nb <= 4'd0;
        else if (byte_valid && nb != 4'd8) nb <= nb + 4'd1;

    // M1
    always @(*) if (rst_n) assert (!pin_we || pin_ok);
    // M2
    always @(*) if (rst_n) begin
        assert (!imem_we[0] || !eng_run[0]);
        assert (!imem_we[1] || !eng_run[1]);
    end
    // M3
    always @(posedge clk) if (rst_n && !$past(init)) begin
        if (pin_we || imem_we != 2'b00 || tx_wr_en != 2'b00 || rx_rd_en != 2'b00 || (eng_run != $past(eng_run) && !$past(hold)))
            assert ($past(frame_end && frame_clean && nb == 4'd7));
    end
    // M4 HOLD: both engines are stopped one clock after it is seen, and RUN cannot be set in the cycle HOLD is active
    always @(posedge clk) if (rst_n && !$past(init) && $past(hold)) assert (eng_run == 2'b00);
endmodule
