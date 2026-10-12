// Formal checks on src/l2_mem.v (two-tier plan F4, F10, F11), every input free. Proved by
// formal/fv_l2_arb.sby (k-induction). The host contract (never write and read in one clock) and
// "policy 3 is never stored" (mgmt refuses it) are the only assumptions.
module fv_l2_arb (
    input wire        clk,
    input wire        rst_n,
    input wire        h_we,
    input wire        h_re,
    input wire [7:0]  h_addr,
    input wire [31:0] h_wdata,
    input wire [1:0]  req,
    input wire [1:0]  req_hi,
    input wire [15:0] req_addr,
    input wire [1:0]  policy
);
    wire [1:0]  gnt;
    wire [31:0] rdata;
    l2_mem dut (.clk(clk), .rst_n(rst_n), .h_we(h_we), .h_re(h_re), .h_addr(h_addr), .h_wdata(h_wdata),
                .req(req), .req_hi(req_hi), .req_addr(req_addr), .policy(policy), .gnt(gnt), .rdata(rdata));

    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    always @(*) begin
        if (init) assume (!rst_n);
        assume (!(h_we && h_re));
        assume (policy != 2'd3);
    end

    wire       host = h_we | h_re;
    wire [1:0] best = req & req_hi;
    always @(*) if (rst_n) begin
        // F4: one grant at most, only to a requester, only inside the best class present
        assert (gnt != 2'b11);
        assert ((gnt & ~req) == 2'b00);
        if (best != 2'b00) assert ((gnt & ~best) == 2'b00);
        if (!host && req != 2'b00) assert (gnt != 2'b00);            // never idle while asked
        // F11: the host always gets the port
        if (host) assert (gnt == 2'b00);
        // fixed priority: the favoured engine never loses outside host clocks (in its class)
        if (!host && policy == 2'd1 && req[0] && (req_hi[0] || !best[1])) assert (gnt[0]);
        if (!host && policy == 2'd2 && req[1] && (req_hi[1] || !best[0])) assert (gnt[1]);
    end

    // Address path: a watched word fa (any address) remembers the last host write to it; a read of fa
    // by the host or by the granted engine returns exactly that value one clock later.
    (* anyconst *) reg [7:0] fa;
    reg        fv_ok = 1'b0, rd_fa = 1'b0;
    reg [31:0] fv;
    always @(posedge clk) begin
        if (h_we && h_addr == fa) begin fv <= h_wdata; fv_ok <= 1'b1; end
        rd_fa <= (h_re && h_addr == fa) || (!host && gnt[0] && req_addr[7:0] == fa) ||
                 (!host && gnt[1] && req_addr[15:8] == fa);
    end
    always @(*) if (rd_fa && fv_ok) assert (rdata == fv);

    // F10: round-robin, a class-2 request loses at most once in a row outside host clocks
    reg [1:0] lose0 = 2'd0, lose1 = 2'd0;
    always @(posedge clk) begin
        if (!rst_n || policy != 2'd0) begin
            lose0 <= 2'd0; lose1 <= 2'd0;
        end else begin
            lose0 <= !(req[0] && req_hi[0]) || gnt[0] ? 2'd0 : host ? lose0 : lose0 + 2'd1;
            lose1 <= !(req[1] && req_hi[1]) || gnt[1] ? 2'd0 : host ? lose1 : lose1 + 2'd1;
        end
    end
    always @(*) if (rst_n) begin
        assert (lose0 <= 2'd1);
        assert (lose1 <= 2'd1);
    end
endmodule
