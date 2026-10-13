// Formal checks on src/mgmt.v (two-tier plan F6 and the commit rule for the L2 window), every input free
// except the spi_slave contract: byte_valid and frame_end are one-clock pulses, never in the same or in
// consecutive clocks (bytes are >= 16 clocks apart at the fastest supported SCLK).
//   F6   an L2 write strobe never targets a word inside the L2_RANGE of a running engine
//   W    an L2 write strobe follows a complete clean 7-byte WRITE frame to the L2 window, one clock later
//   F12  with L2_EN = 0 the L2 port never moves (task noL2)
module fv_mgmt #(parameter L2_EN = 1) (
    input wire        clk,
    input wire        rst_n,
    input wire        byte_valid,
    input wire [7:0]  rx_byte,
    input wire        active,
    input wire        frame_end,
    input wire        frame_clean,
    input wire [1:0]  halted, fault, tx_full, rx_empty, pad_ok_in,
    input wire [8:0]  pc0, pc1,
    input wire [3:0]  fault_cause,
    input wire [31:0] rx_data0, rx_data1, l2_rdata,
    input wire [15:0] pad_owner, pad_viol,
    input wire [7:0]  pad_od,
    input wire [63:0] perf
);
    wire [7:0]  tx_byte;
    wire [1:0]  eng_run, imem_we, rx_rd_en, tx_wr_en;
    wire [5:0]  imem_waddr;
    wire [31:0] imem_wdata, tx_wr_data, l2_range, l2_wdata;
    wire [2:0]  pad_sel, pad_data;
    wire        pad_we, err, l2_we, l2_re;
    wire [15:0] viol_clr;
    wire [17:0] reset_pc;
    wire [3:0]  fetch_cfg;
    wire [1:0]  arb_policy;
    wire [7:0]  l2_addr;
    wire [3:0]  perf_clr;
    mgmt #(.L2_EN(L2_EN)) dut (
        .clk(clk), .rst_n(rst_n), .byte_valid(byte_valid), .rx_byte(rx_byte), .tx_byte(tx_byte),
        .active(active), .frame_end(frame_end), .frame_clean(frame_clean),
        .eng_run(eng_run), .imem_we(imem_we), .imem_waddr(imem_waddr), .imem_wdata(imem_wdata),
        .halted(halted), .fault(fault), .pc0(pc0), .pc1(pc1), .fault_cause(fault_cause),
        .tx_full(tx_full), .rx_empty(rx_empty), .rx_data0(rx_data0), .rx_data1(rx_data1),
        .rx_rd_en(rx_rd_en), .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data),
        .pad_sel(pad_sel), .pad_data(pad_data), .pad_ok(pad_ok_in[0]), .pad_we(pad_we), .viol_clr(viol_clr),
        .pad_owner(pad_owner), .pad_od(pad_od), .pad_viol(pad_viol),
        .reset_pc(reset_pc), .l2_range(l2_range), .fetch_cfg(fetch_cfg), .arb_policy(arb_policy),
        .perf(perf), .perf_clr(perf_clr),
        .l2_we(l2_we), .l2_re(l2_re), .l2_addr(l2_addr), .l2_wdata(l2_wdata), .l2_rdata(l2_rdata),
        .err(err));

    reg init = 1'b1, bv_d = 1'b0, fe_d = 1'b0;
    always @(posedge clk) begin init <= 1'b0; bv_d <= byte_valid; fe_d <= frame_end; end
    always @(*) begin
        if (init) assume (!rst_n);
        assume (!(byte_valid && frame_end));
        if (bv_d || fe_d) assume (!byte_valid && !frame_end);
    end

    // the last 7 bytes received and how many arrived since the last frame end (saturating at 8)
    reg [55:0] win = 56'd0;
    reg [3:0]  cnt = 4'd0;
    reg        good_d = 1'b0;          // last clock: a frame end that is a complete clean L2 WRITE
    always @(posedge clk) begin
        if (!rst_n)          begin cnt <= 4'd0; win <= 56'd0; end
        else if (frame_end)  cnt <= 4'd0;
        else if (byte_valid) begin win <= {win[47:0], rx_byte}; if (cnt != 4'd8) cnt <= cnt + 4'd1; end
        good_d <= rst_n && frame_end && frame_clean && cnt == 4'd7 && win[55:48] == 8'h01 &&
                  win[47:42] == 6'b000001 && win[33:32] == 2'b00;
    end

    wire [7:0] lo0 = l2_range[7:0], hi0 = l2_range[15:8], lo1 = l2_range[23:16], hi1 = l2_range[31:24];
    always @(*) if (rst_n) begin
        if (l2_we) begin
            assert (!(eng_run[0] && l2_addr >= lo0 && l2_addr <= hi0));          // F6
            assert (!(eng_run[1] && l2_addr >= lo1 && l2_addr <= hi1));
            assert (good_d);                                                      // W
        end
        if (!L2_EN) assert (!l2_we && !l2_re);                                   // F12
    end
endmodule
