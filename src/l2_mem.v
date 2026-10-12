// Shared L2 instruction memory (docs/TWO_TIER_MEMORY_PLAN.md §2.5): one IHP 1P 256x32 SRAM macro and
// its arbiter. One access per clock:
//   class 1  host (h_we or h_re): always granted; at most one per management frame
//   class 2  engine requests with req_hi set (urgent fetch, or a request that already lost once)
//   class 3  other engine requests (prefetch, COPY reads)
// Inside a class, policy 0 = round-robin (the engine not granted last wins), 1 = engine 0 first,
// 2 = engine 1 first. The grant is combinational, in the clock of the request (mode A, D7); the word
// is on rdata one clock later and holds until the next read.
module l2_mem (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        h_we,
    input  wire        h_re,
    input  wire [7:0]  h_addr,
    input  wire [31:0] h_wdata,
    input  wire [1:0]  req,            // per engine
    input  wire [1:0]  req_hi,         // per engine: request is class 2
    input  wire [15:0] req_addr,       // {engine 1, engine 0}
    input  wire [1:0]  policy,
    output wire [1:0]  gnt,
    output wire [31:0] rdata
);
    reg  last;                                              // engine granted last
    wire host  = h_we | h_re;
    wire [1:0] top = (req & req_hi) != 2'b00 ? (req & req_hi) : req;   // requests of the best class
    wire pick1 = top[1] & (~top[0] | policy == 2'd2 | (policy == 2'd0 & ~last));
    assign gnt = host ? 2'b00 : {pick1, top[0] & ~pick1};

    always @(posedge clk or negedge rst_n)
        if (!rst_n)      last <= 1'b0;
        else if (|gnt)   last <= gnt[1];

    wire [7:0] addr = host ? h_addr : gnt[1] ? req_addr[15:8] : req_addr[7:0];
`ifdef FORMAL
    abs_sram #(.AW(8), .DW(32)) u_l2 (.clk(clk), .men(host | |gnt), .wen(h_we), .ren(~h_we),
                                      .addr(addr), .din(h_wdata), .dout(rdata));
`else
    RM_IHPSG13_1P_256x32_c2_bm_bist u_l2 (
        .A_CLK(clk), .A_MEN(host | |gnt), .A_WEN(h_we), .A_REN(~h_we), .A_ADDR(addr), .A_DIN(h_wdata),
        .A_DLY(1'b1), .A_DOUT(rdata), .A_BM(32'hFFFFFFFF),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0),
        .A_BIST_ADDR(8'd0), .A_BIST_DIN(32'd0), .A_BIST_BM(32'd0));
`endif
endmodule
