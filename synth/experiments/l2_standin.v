// Phase 0 area / logic-depth stand-in for the two-tier L2 glue (docs/TWO_TIER_MEMORY_PLAN.md
// steps 0.4, 0.5). NOT the design: it holds the same storage and the same urgent-fetch path
// (next_pc -> buffer compare -> request -> arbiter -> address mux -> macro) so Yosys can measure
// area and gate depth before the real RTL exists. Per engine: IR2, PB, RESET_PC, L2_RANGE,
// FETCH_CFG, COPY counter, fault cause, instruction mux, L1 write-port mux. Shared: arbiter + mux.
module l2_standin (
    input  wire        clk, rst_n,
    input  wire [17:0] npc,              // next_pc of both engines (path start)
    input  wire [1:0]  ok, hold, run,
    input  wire [1:0]  policy,
    input  wire        h_req, h_we,
    input  wire [7:0]  h_addr,
    input  wire [31:0] h_wdata,
    input  wire [26:0] cfg,              // host config write data
    input  wire [1:0]  cfg_we,
    input  wire [63:0] l1_out, l1_host_wdata,
    output wire [63:0] instr, l1_wdata,
    output wire [11:0] l1_waddr,
    output wire [1:0]  fault
);
    wire [31:0] rdata;
    reg  [1:0]  got, last;
    wire [1:0]  req, gnt;
    genvar e;
    generate for (e = 0; e < 2; e = e + 1) begin : g
        reg [31:0] ir2, pb; reg [8:0] pb_a, rv; reg pb_ok; reg [15:0] rng; reg [1:0] fcfg;
        reg [6:0] k; reg [1:0] cause;
        wire [8:0] n = npc[9*e +: 9];
        wire pb_hit = pb_ok & (pb_a == n);
        assign req[e] = run[e] & n[8] & ~ok[e] & ~pb_hit;
        always @(posedge clk or negedge rst_n)
            if (!rst_n) begin ir2 <= 0; pb <= 0; pb_a <= 0; pb_ok <= 0; rv <= 0; rng <= 0; fcfg <= 0; k <= 0; cause <= 0; end
            else begin
                if (got[e] | pb_hit) ir2 <= got[e] ? rdata : pb;
                if (got[e] & hold[e]) begin pb <= rdata; pb_a <= n + 1'b1; pb_ok <= 1'b1; end
                if (cfg_we[e]) {fcfg, rng, rv} <= cfg;
                k <= hold[e] ? k + gnt[e] : 7'd0;
                cause <= {n[7:0] > rng[15:8], n[7:0] < rng[7:0]};
            end
        assign instr[32*e +: 32]    = n[8] ? (got[e] ? rdata : ir2) : l1_out[32*e +: 32];
        assign l1_wdata[32*e +: 32] = got[e] ? rdata : l1_host_wdata[32*e +: 32];
        assign l1_waddr[6*e +: 6]   = got[e] ? k[5:0] : rv[5:0];
        assign fault[e] = |cause;
    end endgenerate

    wire pick1 = req[1] & (~req[0] | policy == 2'd2 | (policy == 2'd0 & last == 2'd0));
    assign gnt = h_req ? 2'b00 : {pick1, req[0] & ~pick1};
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin got <= 0; last <= 0; end
        else begin got <= gnt; if (|gnt) last <= gnt; end

    wire [7:0] a = h_req ? h_addr : gnt[1] ? npc[16:9] : npc[7:0];
    RM_IHPSG13_1P_256x32_c2_bm_bist u_l2 (
        .A_CLK(clk), .A_MEN(h_req | |gnt), .A_WEN(h_we), .A_REN(~h_we), .A_ADDR(a), .A_DIN(h_wdata),
        .A_DLY(1'b1), .A_DOUT(rdata), .A_BM(32'hFFFFFFFF),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR(8'd0), .A_BIST_DIN(32'd0), .A_BIST_BM(32'd0));
endmodule
