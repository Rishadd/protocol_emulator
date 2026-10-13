// Formal harness: one engine_top + l2_mem (two-tier plan F1, F2, F3, F5, F9). The other engine's
// requests and the host are free inputs, so every kind of contention is covered. F1/F2 are asserted
// inside control_unit and F5/F9 inside engine_top (`ifdef FORMAL); F3 is checked here:
//   F3  a valid instruction word for an L2 pc inside the range (or an L1 pc) is exactly the word last written
//       there (watched addresses fa / fl, any value)
// Assumptions = the guarantees mgmt gives (proved in fv_mgmt): configuration stable while running,
// no L1 load while running, no host L2 write inside the running range, one host access per clock,
// policy never 3.
module fv_engine (
    input wire        clk,
    input wire        rst_n,
    input wire        run,
    input wire        imem_we,
    input wire [5:0]  waddr,
    input wire [31:0] wdata,
    input wire        tx_wr_en,
    input wire [31:0] tx_wr_data,
    input wire        rx_rd_en,
    input wire [7:0]  pin_in,
    input wire [8:0]  reset_pc,
    input wire [15:0] l2_range,
    input wire [1:0]  fetch_cfg,
    input wire        h_we,
    input wire        h_re,
    input wire [7:0]  h_addr,
    input wire [31:0] h_wdata,
    input wire        o_req,
    input wire        o_hi,
    input wire [7:0]  o_addr,
    input wire [1:0]  policy,
    input wire [1:0]  perf_clr
);
    wire [31:0] rx_rd_data, l2d, f_instr;
    wire [7:0]  pin_out, pin_oe, l2_a;
    wire [8:0]  pc;
    wire [1:0]  cause, gnt;
    wire        tx_full, rx_empty, halted, fault, req, hi, bubble, f_valid, f_l1_we;
    wire [5:0]  f_l1_wa;
    wire [31:0] f_l1_wd;
    engine_top dut (
        .clk(clk), .rst_n(rst_n), .run(run), .imem_we(imem_we), .imem_waddr(waddr), .imem_wdata(wdata),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full),
        .rx_rd_en(rx_rd_en), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in(pin_in), .pin_out(pin_out), .pin_oe(pin_oe),
        .reset_pc(reset_pc), .l2_range(l2_range), .fetch_cfg(fetch_cfg),
        .l2_req(req), .l2_req_hi(hi), .l2_addr(l2_a), .l2_gnt(gnt[0]), .l2_rdata(l2d), .bubble(bubble),
        .perf_clr(perf_clr), .perf_bubble(), .perf_l2rd(), .copy_wait(),
        .halted(halted), .fault(fault), .fault_cause(cause), .pc(pc),
        .f_instr(f_instr), .f_valid(f_valid), .f_l1_we(f_l1_we), .f_l1_wa(f_l1_wa), .f_l1_wd(f_l1_wd));
    l2_mem l2 (.clk(clk), .rst_n(rst_n), .h_we(h_we), .h_re(h_re), .h_addr(h_addr), .h_wdata(h_wdata),
               .req({o_req, req}), .req_hi({o_hi, hi}), .req_addr({o_addr, l2_a}), .policy(policy),
               .gnt(gnt), .rdata(l2d));

    reg        init = 1'b1;
    reg [1:0]  we_h = 2'd0;                // L1 writes in the last two clocks
    reg [26:0] cfg_d = 27'd0, cfg_dd = 27'd0;
    always @(posedge clk) begin
        init <= 1'b0; we_h <= {we_h[0], imem_we};
        cfg_d <= {reset_pc, l2_range, fetch_cfg}; cfg_dd <= cfg_d;
    end
    wire in_rng = h_addr >= l2_range[7:0] && h_addr <= l2_range[15:8];
    always @(*) begin
        if (init) assume (!rst_n && !run);
        assume (!(h_we && h_re));
        assume (policy != 2'd3);
        // RUN, configuration and L1 loads come in separate SPI frames (>= 896 clocks apart): while
        // running, the configuration has not changed for two clocks and no L1 write was that recent
        if (run) assume ({reset_pc, l2_range, fetch_cfg} == cfg_d && cfg_d == cfg_dd && we_h == 2'd0 && !imem_we);
        if (run) assume (!(h_we && in_rng));
    end

    // F10 (engine side): a request of this engine (urgent, or a prefetch promoted after one loss) loses
    // at most 2 times in a row outside host clocks under round-robin, whatever the other engine does
    reg [1:0] eloss = 2'd0;
    always @(posedge clk)
        if (!rst_n || policy != 2'd0 || !req || gnt[0]) eloss <= 2'd0;
        else if (!(h_we || h_re)) eloss <= eloss + 2'd1;
    always @(*) if (rst_n) assert (eloss <= 2'd2);

    // F3: watched words
    (* anyconst *) reg [7:0] fa;
    (* anyconst *) reg [5:0] fl;
    reg        fa_ok = 1'b0, fl_ok = 1'b0;
    reg [31:0] fa_v, fl_v;
    always @(posedge clk) begin
        if (h_we && h_addr == fa) begin fa_v <= h_wdata; fa_ok <= 1'b1; end
        if (imem_we && waddr == fl) begin fl_v <= wdata; fl_ok <= 1'b1; end
        if (f_l1_we && f_l1_wa == fl) begin fl_v <= f_l1_wd; fl_ok <= 1'b1; end     // COPY writes
    end
`ifndef NO_F3                             // the ctrl task cuts the memories free: F3 is not meaningful there
    always @(*) if (rst_n && run && f_valid) begin
        if (pc[8] && pc[7:0] == fa && fa_ok && fa >= l2_range[7:0] && fa <= l2_range[15:8]) assert (f_instr == fa_v);
        if (!pc[8] && pc[5:0] == fl && fl_ok) assert (f_instr == fl_v);
    end
`endif
endmodule
