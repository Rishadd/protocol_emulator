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
    input wire [7:0]  oe0, out0, oe1, out1
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire        byte_valid, active, frame_end, frame_clean, miso;
    wire [7:0]  rx_byte, tx_byte;
    wire [1:0]  eng_run, imem_we, rx_rd_en, tx_wr_en;
    wire [7:0]  imem_waddr, pad_od, uio_oe, uio_out;
    wire [31:0] imem_wdata, tx_wr_data;
    wire [2:0]  pad_sel, pad_data;
    wire        pad_ok, pad_we, err;
    wire [15:0] viol_clr, pad_owner, pad_viol;

    spi_slave u_spi (.clk(clk), .rst_n(rst_n), .sclk(sclk), .mosi(mosi), .cs_n(cs_n), .miso(miso),
                     .byte_valid(byte_valid), .rx_byte(rx_byte), .tx_byte(tx_byte),
                     .active(active), .frame_end(frame_end), .frame_clean(frame_clean));
    mgmt u_mgmt (.clk(clk), .rst_n(rst_n), .byte_valid(byte_valid), .rx_byte(rx_byte), .tx_byte(tx_byte),
                 .active(active), .frame_end(frame_end), .frame_clean(frame_clean), .eng_run(eng_run),
                 .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
                 .halted(halted), .fault(fault), .pc0(pc0), .pc1(pc1), .tx_full(tx_full), .rx_empty(rx_empty),
                 .rx_data0(rx_data0), .rx_data1(rx_data1), .rx_rd_en(rx_rd_en), .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data),
                 .pad_sel(pad_sel), .pad_data(pad_data), .pad_ok(pad_ok), .pad_we(pad_we), .viol_clr(viol_clr),
                 .pad_owner(pad_owner), .pad_od(pad_od), .pad_viol(pad_viol), .err(err));
    pin_mgr u_pins (.clk(clk), .rst_n(rst_n), .run(eng_run), .cfg_pad(pad_sel), .cfg_data(pad_data), .cfg_ok(pad_ok),
                    .cfg_we(pad_we), .viol_clr(viol_clr), .oe0(oe0), .out0(out0), .oe1(oe1), .out1(out1),
                    .pad_oe(uio_oe), .pad_out(uio_out), .owner(pad_owner), .od(pad_od), .viol(pad_viol));

    // bytes of the current frame, counted here from the SPI slave's outputs (independent of mgmt's own counter)
    reg [3:0] nb;
    always @(posedge clk)
        if (init || frame_end) nb <= 4'd0;
        else if (byte_valid && nb != 4'd8) nb <= nb + 4'd1;

    // M1
    always @(*) if (rst_n) assert (!pad_we || pad_ok);
    // M2
    always @(*) if (rst_n) begin
        assert (!imem_we[0] || !eng_run[0]);
        assert (!imem_we[1] || !eng_run[1]);
    end
    // M3
    always @(posedge clk) if (rst_n && !$past(init)) begin
        if (pad_we || imem_we != 2'b00 || tx_wr_en != 2'b00 || rx_rd_en != 2'b00 || viol_clr != 16'd0 || eng_run != $past(eng_run))
            assert ($past(frame_end && frame_clean && nb == 4'd7));
    end
endmodule
