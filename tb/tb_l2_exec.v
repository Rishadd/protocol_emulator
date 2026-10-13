`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// Two-tier plan V3.2-V3.4 (later V4.4, V5.8): two engines + the shared L2 in lockstep "modulo bubbles"
// with two reference models (tb/ref/ref_flat_engine.v): a model steps only in the clocks its engine is
// not bubbling (or waiting inside a COPY). Random programs spread over L1 and both engines' L2 ranges
// (jumps between tiers, rare jumps outside -> faults), random reset vectors, ranges, prefetch settings,
// arbitration policies (also changed while running), host L2 reads and writes outside the running
// ranges, RUN drops with reloads, FIFO and pin traffic. Checked every clock:
//   * every engine output equals its model (pins, pc, FIFOs, halted, fault, cause)
//   * every L2 grant equals the reference arbiter (tb/arb_model.vh); host reads return the model's word
//   * every bubble is explained: the engine's request lost arbitration in the clock before, or it is the
//     first running clock with an L2 reset vector; never a bubble while the pc is in L1 (T11, F5)
// Plusargs: +SEED=n +CYCLES=n (compared clocks, default 300000) +NOCOPY (COPY never generated).
module tb_l2_exec;
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;
    `include "arb_model.vh"

    reg  [1:0]  run = 0, imem_we = 0, tx_we = 0, rx_re = 0;
    reg  [5:0]  waddr = 0;
    reg  [31:0] wdata = 0;
    reg  [63:0] tx_d = 0;
    reg  [7:0]  pin_in = 0;
    reg  [17:0] rv = 0;
    reg  [31:0] rng = 32'h00FF_00FF;
    reg  [3:0]  fcfg = 0;
    reg  [1:0]  pol = 0;
    reg         h_we = 0, h_re = 0;
    reg  [7:0]  h_a = 0;
    reg  [31:0] h_d = 0;
    wire [1:0]  req, req_hi, gnt, bub, ce, cwait;
    wire [15:0] ra;
    wire [31:0] l2d;
    wire [63:0] d_rxd, r_rxd;
    wire [1:0]  d_txf, r_txf, d_rxe, r_rxe, d_hlt, r_hlt, d_flt, r_flt;
    wire [15:0] d_po, r_po, d_oe, r_oe;
    wire [17:0] d_pc, r_pc;
    wire [3:0]  d_cause, r_cause;

    l2_mem l2 (.clk(clk), .rst_n(rst_n), .h_we(h_we), .h_re(h_re), .h_addr(h_a), .h_wdata(h_d),
               .req(req), .req_hi(req_hi), .req_addr(ra), .policy(pol), .gnt(gnt), .rdata(l2d));
    genvar e;
    generate for (e = 0; e < 2; e = e + 1) begin : g
        engine_top dut (
            .clk(clk), .rst_n(rst_n), .run(run[e]),
            .imem_we(imem_we[e]), .imem_waddr(waddr), .imem_wdata(wdata),
            .tx_wr_en(tx_we[e]), .tx_wr_data(tx_d[32*e +: 32]), .tx_full(d_txf[e]),
            .rx_rd_en(rx_re[e]), .rx_rd_data(d_rxd[32*e +: 32]), .rx_empty(d_rxe[e]),
            .pin_in(pin_in), .pin_out(d_po[8*e +: 8]), .pin_oe(d_oe[8*e +: 8]),
            .reset_pc(rv[9*e +: 9]), .l2_range(rng[16*e +: 16]), .fetch_cfg(fcfg[2*e +: 2]),
            .l2_req(req[e]), .l2_req_hi(req_hi[e]), .l2_addr(ra[8*e +: 8]), .l2_gnt(gnt[e]), .l2_rdata(l2d),
            .bubble(bub[e]), .halted(d_hlt[e]), .fault(d_flt[e]), .fault_cause(d_cause[2*e +: 2]), .pc(d_pc[9*e +: 9]));
`ifdef HAS_COPY
        assign cwait[e] = dut.copy_wait;     // DUT clocks spent inside a COPY (the model needs one)
`else
        assign cwait[e] = 1'b0;
`endif
        assign ce[e] = !bub[e] && !cwait[e];
        ref_flat_engine m (
            .clk(clk), .rst_n(rst_n), .run(run[e]), .ce(ce[e]), .l2_en(1'b1),
            .reset_pc(rv[9*e +: 9]), .range(rng[16*e +: 16]),
            .tx_wr_en(tx_we[e]), .tx_wr_data(tx_d[32*e +: 32]), .tx_full(r_txf[e]),
            .rx_rd_en(rx_re[e]), .rx_rd_data(r_rxd[32*e +: 32]), .rx_empty(r_rxe[e]),
            .pin_in(pin_in), .pin_out(r_po[8*e +: 8]), .pin_oe(r_oe[8*e +: 8]),
            .halted(r_hlt[e]), .fault(r_flt[e]), .cause(r_cause[2*e +: 2]), .pc(r_pc[9*e +: 9]));
    end endgenerate

    integer errors = 0, seed = 1, cycles = 0, target = 300000, mism = 0, arb_mism = 0, rd_mism = 0;
    integer unexplained = 0, l1_bubbles = 0, held_req = 0, bad_class = 0, i, j, k, x, nocopy = 0;   // i: checkers only, j: stimulus only
    integer cov_bub_eng = 0, cov_bub_host = 0, cov_bub_first = 0, cov_collide = 0, cov_restart = 0;
    integer cov_l1l2 = 0, cov_l2l1 = 0, cov_l2jmp = 0, cov_l2seq = 0, cov_pf = 0, cov_copy = 0;
    integer cov_fault [0:3];
    integer streak [0:1];
    integer max_rr = 0, max_fav = 0;     // V3.5: longest run of non-host losses of a class-2 request
    integer cov_pol [0:2];
    reg        chk = 0, last_m = 0, rd_pend = 0;
    reg [7:0]  rd_a;
    reg [1:0]  lost_prev = 0, lost_host_prev = 0, run_prev = 0;
    reg [17:0] pc_prev = 0;

    function integer rnd(input integer n); reg [31:0] r; begin r = $random(seed); rnd = r % n; end endfunction
    function [7:0] lo(input integer e); lo = rng[16*e +: 8]; endfunction
    function [7:0] hi(input integer e); hi = rng[16*e + 8 +: 8]; endfunction
    function in_use(input [7:0] a);   // a running engine may execute / copy this L2 word
        in_use = (run[0] && a >= lo(0) && a <= hi(0)) || (run[1] && a >= lo(1) && a <= hi(1));
    endfunction

    // random jump target for engine e: L1, own L2 range, near the word, or (rarely) anywhere
    function [8:0] tgt(input integer e, input [8:0] at);
        integer p;
        begin
            p = rnd(100);
            if (p < 40)      tgt = rnd(64);
            else if (p < 80) tgt = 9'h100 | ((lo(e) + rnd(hi(e) - lo(e) + 1)) & 8'hFF);
            else if (p < 99) tgt = (at[8] && at[7:0] > lo(e) + 3 && at[7:0] + 4 < hi(e)) ? at + rnd(9) - 4 :
                                   (!at[8] && at > 4 && at < 59) ? at + rnd(9) - 4 : rnd(64);
            else             tgt = rnd(512);
        end
    endfunction
    function [31:0] gen(input integer e, input [8:0] at);
        integer p, n1;
        reg [8:0] t;
        begin
            p = rnd(nocopy ? 131 : 136); t = tgt(e, at);
            if      (p <  6) gen = {`OP_NOP,   27'd0};
            else if (p < 16) gen = {`OP_WAIT,  27'd0} | rnd(7);
            else if (p < 24) gen = {`OP_JMP,   27'd0} | t;
            else if (p < 25) gen = {`OP_HALT,  27'd0};
            else if (p < 33) gen = {`OP_SETL,  27'd0} | rnd(6);
            else if (p < 43) gen = {`OP_DJNZ,  27'd0} | t;
            else if (p < 51) gen = {`OP_PULL,  27'd0};
            else if (p < 57) gen = {`OP_PUSH,  27'd0};
            else if (p < 66) gen = {`OP_OUT1,  27'd0} | rnd(5);
            else if (p < 72) gen = {`OP_IN1,   27'd0} | rnd(5);
            else if (p < 77) gen = {`OP_SETH,  27'd0} | rnd(8);
            else if (p < 82) gen = {`OP_SETLO, 27'd0} | rnd(8);
            else if (p < 86) gen = {`OP_DIRO,  27'd0} | rnd(8);
            else if (p < 89) gen = {`OP_DIRI,  27'd0} | rnd(8);
            else if (p < 92) gen = {`OP_WAITH, 27'd0} | rnd(8);
            else if (p < 95) gen = {`OP_WAITL, 27'd0} | rnd(8);
            else if (p < 99) gen = {`OP_CFG,   27'd0} | rnd(256);
            else if (p < 107) gen = {`OP_JPH,  27'd0} | (rnd(8) << 9) | t;
            else if (p < 115) gen = {`OP_JPL,  27'd0} | (rnd(8) << 9) | t;
            else if (p < 120) gen = {`OP_JPO,  27'd0} | t;
            else if (p < 128) gen = {`OP_PUSHI, 27'd0} | ($random(seed) & 32'h07FF_FFFF);
            else if (p < 131) gen = {5'd22 + rnd(10), 27'd0} | rnd(64);       // illegal: trap
            else begin                                                      // COPY src,dst,n (mostly legal)
                n1 = rnd(64);                                               // n - 1; dst fits; src in range
                gen = {5'd21, 27'd0} | (n1 << 14) | ((rnd(64 - n1) & 63) << 8) | ((lo(e) + rnd(hi(e) - lo(e) + 1)) & 8'hFF);
                if (rnd(8) == 0) gen[19:0] = $random(seed);                 // sometimes anything (traps)
            end
        end
    endfunction

    task tick; begin @(posedge clk); #1; end endtask
    task l2_write(input [7:0] a, input [31:0] d);
        begin h_we = 1; h_a = a; h_d = d; tick; h_we = 0; g[0].m.l2[a] = d; g[1].m.l2[a] = d; end
    endtask
    task l1_write(input integer e, input [5:0] a, input [31:0] d);
        begin imem_we[e] = 1; waddr = a; wdata = d; tick; imem_we[e] = 0;
              if (e == 0) g[0].m.l1[a] = d; else g[1].m.l1[a] = d; end
    endtask
    // the engine's own program: L1 (word 63 a JMP) and its L2 range (last word a JMP); skips L2 words
    // a running engine may use. Random reset vector (L1 word, or an L2 word of the range).
    task load_engine(input integer e, input integer all);
        reg [8:0] a;
        begin
            for (k = 0; k < 64; k = k + 1) if (all || rnd(8) == 0)
                l1_write(e, k, k == 63 ? {`OP_JMP, 27'd0} | tgt(e, k) : gen(e, k));
            for (k = lo(e); k <= hi(e); k = k + 1) if ((all || rnd(8) == 0) && !in_use(k))
                l2_write(k, k == hi(e) ? {`OP_JMP, 27'd0} | tgt(e, 9'h100 | k) : gen(e, 9'h100 | k));
            x = rnd(4);
            a = x == 0 ? 9'd0 : x == 1 ? rnd(64) : 9'h100 | ((lo(e) + rnd(hi(e) - lo(e) + 1)) & 8'hFF);
            rv[9*e +: 9] = a;
            tick; tick;                     // RUN comes in a later frame than RESET_PC (>= 2 clocks)
        end
    endtask
    task new_range(input integer e);
        integer l, h;
        begin l = rnd(200); h = l + 12 + rnd(256 - l - 12); if (h > 255) h = 255; rng[16*e +: 16] = {h[7:0], l[7:0]}; end
    endtask

    // ------------------------------------------------------------------ per-clock checks
    always @(negedge clk) if (chk) begin
        cycles = cycles + 1;
        for (i = 0; i < 2; i = i + 1) begin
            if ({d_po[8*i +: 8], d_oe[8*i +: 8], d_pc[9*i +: 9], d_hlt[i], d_flt[i], d_txf[i], d_rxe[i], d_rxd[32*i +: 32],
                 d_flt[i] ? d_cause[2*i +: 2] : 2'd0} !==
                {r_po[8*i +: 8], r_oe[8*i +: 8], r_pc[9*i +: 9], r_hlt[i], r_flt[i], r_txf[i], r_rxe[i], r_rxd[32*i +: 32],
                 r_flt[i] ? r_cause[2*i +: 2] : 2'd0}) begin
                mism = mism + 1;
                if (mism <= 5) $display("  MISMATCH @%0t eng%0d: dut pc=%h po=%h oe=%h hlt=%b flt=%b c=%0d txf=%b rxe=%b rxd=%h | ref pc=%h po=%h oe=%h hlt=%b flt=%b c=%0d txf=%b rxe=%b rxd=%h",
                    $time, i, d_pc[9*i +: 9], d_po[8*i +: 8], d_oe[8*i +: 8], d_hlt[i], d_flt[i], d_cause[2*i +: 2], d_txf[i], d_rxe[i], d_rxd[32*i +: 32],
                    r_pc[9*i +: 9], r_po[8*i +: 8], r_oe[8*i +: 8], r_hlt[i], r_flt[i], r_cause[2*i +: 2], r_txf[i], r_rxe[i], r_rxd[32*i +: 32]);
            end
            if (req[i] && !run[i]) held_req = held_req + 1;                  // F9: a held engine asks for nothing
            if (req[i] && req_hi[i] && !lost_prev[i] && (i ? g[1].dut.waiting : g[0].dut.waiting))
                bad_class = bad_class + 1;                                    // a fresh prefetch must be class 3
            if (bub[i]) begin
                if (!d_pc[9*i + 8]) l1_bubbles = l1_bubbles + 1;
                if (lost_prev[i]) begin if (lost_host_prev[i]) cov_bub_host = cov_bub_host + 1; else cov_bub_eng = cov_bub_eng + 1; end
                else if (!run_prev[i]) cov_bub_first = cov_bub_first + 1;
                else begin unexplained = unexplained + 1; if (unexplained <= 5) $display("  UNEXPLAINED BUBBLE @%0t eng%0d pc=%h", $time, i, d_pc[9*i +: 9]); end
            end
            if (d_pc[9*i +: 9] !== pc_prev[9*i +: 9] && run[i] && run_prev[i]) begin
                if (!pc_prev[9*i + 8] && d_pc[9*i + 8]) cov_l1l2 = cov_l1l2 + 1;
                else if (pc_prev[9*i + 8] && !d_pc[9*i + 8]) cov_l2l1 = cov_l2l1 + 1;
                else if (d_pc[9*i + 8] && d_pc[9*i +: 9] == pc_prev[9*i +: 9] + 9'd1) cov_l2seq = cov_l2seq + 1;
                else if (d_pc[9*i + 8]) cov_l2jmp = cov_l2jmp + 1;
            end
        end
        // arbiter: the grant this clock must equal the reference
        if (gnt !== arb_ref(h_we | h_re, req, req_hi, pol, last_m)) begin
            arb_mism = arb_mism + 1;
            if (arb_mism <= 5) $display("  ARB MISMATCH @%0t host=%b req=%b hi=%b pol=%0d last=%b gnt=%b", $time, h_we | h_re, req, req_hi, pol, last_m, gnt);
        end
        for (i = 0; i < 2; i = i + 1) begin                                 // V3.5 wait bounds
            if (!(req[i] && req_hi[i]) || gnt[i]) streak[i] = 0;
            else if (!(h_we | h_re)) begin
                streak[i] = streak[i] + 1;
                if (pol == 0 && streak[i] > max_rr) max_rr = streak[i];
                if (pol == i + 1 && streak[i] > max_fav) max_fav = streak[i];
            end
        end
        if (req == 2'b11) cov_collide = cov_collide + 1;
        if (req != 0 && !(req & req_hi)) cov_pf = cov_pf + 1;
        cov_pol[pol] = cov_pol[pol] + (req == 2'b11);
        if (rd_pend && l2d !== g[0].m.l2[rd_a]) begin rd_mism = rd_mism + 1; $display("  HOST READ MISMATCH @%0t a=%h", $time, rd_a); end
        rd_pend = h_re; rd_a = h_a;
        lost_prev = req & ~gnt; lost_host_prev = (req & ~gnt) & {2{h_we | h_re}};
        run_prev = run; pc_prev = d_pc;
        if (|gnt) last_m = gnt[1];
    end
    // count each fault once (rising edge of the model's fault)
    reg [1:0] flt_prev = 0;
    always @(negedge clk) if (chk) begin
        for (i = 0; i < 2; i = i + 1) if (r_flt[i] && !flt_prev[i]) cov_fault[r_cause[2*i +: 2]] = cov_fault[r_cause[2*i +: 2]] + 1;
        flt_prev = r_flt;
    end

    // ------------------------------------------------------------------ stimulus
    // V3.6: fixed priority starves the other engine (documented) and it recovers at once;
    // V3.7: an engine running from L1 is never delayed by L2 contention, host traffic or the policy
    integer t0, stuck;
    reg [8:0] p1;
    task directed;
        begin
            run = 0; tick; tick;
            rng = {8'h3F, 8'h20, 8'h1F, 8'h00};                    // engine 0 [00,1F], engine 1 [20,3F]
            l2_write(8'h00, {`OP_NOP, 27'd0}); l2_write(8'h01, {`OP_NOP, 27'd0}); l2_write(8'h02, {`OP_JMP, 27'h100});
            l2_write(8'h20, {`OP_NOP, 27'd0}); l2_write(8'h21, {`OP_NOP, 27'd0}); l2_write(8'h22, {`OP_JMP, 27'h120});
            rv = {9'h120, 9'h100}; pol = 1; tick; tick;
            run = 2'b11; repeat (5) tick;
            p1 = d_pc[17:9]; stuck = 1;
            for (t0 = 0; t0 < 100000; t0 = t0 + 1) begin tick; if (d_pc[17:9] !== p1 || !bub[1]) stuck = 0; end
            `CHECK(stuck == 1, "V3.6 engine 0 first + engine 0 in a one-clock L2 loop: engine 1 waits for ever")
            `CHECK(!d_flt[0] && !d_flt[1], "V3.6 no fault, no deadlock")
            pol = 0; repeat (3) tick;
            `CHECK(d_pc[17:9] !== p1, "V3.6 round-robin again: engine 1 moves at once")
            // V3.7: engine 0 in L1 (one-clock pin toggles), engine 1 thrashing L2 with priority, host reads every clock
            run = 0; tick; tick;
            l1_write(0, 0, {`OP_DIRO, 27'd1}); l1_write(0, 1, {`OP_SETH, 27'd1}); l1_write(0, 2, {`OP_SETLO, 27'd1});
            l1_write(0, 3, {`OP_JMP, 27'd1});
            rv = {9'h120, 9'h000}; pol = 2; tick; tick;
            run = 2'b11; t0 = l1_bubbles; stuck = cov_bub_host + cov_bub_eng;
            for (k = 0; k < 50000; k = k + 1) begin h_re = 1; h_a = $random(seed); if (k % 997 == 0) pol = rnd(3); tick; end
            h_re = 0;
            `CHECK(l1_bubbles == t0 && cov_bub_host + cov_bub_eng > stuck, "V3.7 L1 engine: no bubble under L2 contention + host storm")
            run = 0; tick; tick; pol = 0;
        end
    endtask

    integer halted_for [0:1];
    initial begin
        if ($value$plusargs("SEED=%d", seed)) ;
        if ($value$plusargs("CYCLES=%d", target)) ;
        if ($test$plusargs("NOCOPY")) nocopy = 1;
`ifndef HAS_COPY
        nocopy = 1;
`endif
        for (i = 0; i < 4; i = i + 1) cov_fault[i] = 0;
        for (i = 0; i < 3; i = i + 1) cov_pol[i] = 0;
        halted_for[0] = 0; halted_for[1] = 0; streak[0] = 0; streak[1] = 0;
        tick; rst_n = 1; tick;
        new_range(0); new_range(1);
        for (k = 0; k < 256; k = k + 1) l2_write(k, gen(rnd(2), 9'h100 | k));   // every word known (no X)
        load_engine(0, 1); load_engine(1, 1);
        fcfg = $random(seed); pol = rnd(3);
        chk = 1;
        if (!$test$plusargs("NODIRECTED")) begin
            directed;
            new_range(0); new_range(1);
            for (k = 0; k < 256; k = k + 1) l2_write(k, gen(rnd(2), 9'h100 | k));
            load_engine(0, 1); load_engine(1, 1);
        end
        tick; run = 2'b11; t0 = cycles;
        while (cycles - t0 < target) begin                                  // the random part
            // pins, FIFOs
            if (rnd(100) < 6) pin_in = pin_in ^ (8'd1 << rnd(8));
            tx_we = {rnd(100) < 4, rnd(100) < 4}; tx_d = {$random(seed), $random(seed)};
            rx_re = {rnd(100) < 5, rnd(100) < 5};
            // host L2 traffic: reads anywhere, writes only outside running ranges
            x = rnd(100);
            h_a = rnd(256);
            if (x < 4) h_re = 1;
            else if (x < 7 && !in_use(h_a)) begin h_we = 1; h_d = gen(rnd(2), 9'h100 | h_a); end
            if (rnd(2000) == 0) pol = rnd(3);                               // policy change while running
            tick;
            if (h_we) begin g[0].m.l2[h_a] = h_d; g[1].m.l2[h_a] = h_d; end
            h_we = 0; h_re = 0;
            // restart an engine that halted, or sometimes at random: RUN 0, new settings and code, RUN 1
            for (j = 0; j < 2; j = j + 1) begin
                halted_for[j] = d_hlt[j] ? halted_for[j] + 1 : 0;
                if (halted_for[j] > 12 || rnd(3000) == 0) begin
                    cov_restart = cov_restart + 1;
                    tx_we = 0; rx_re = 0;
                    run[j] = 0; tick; tick;
                    if (rnd(3) == 0) new_range(j);
                    fcfg[2*j +: 2] = rnd(4);
                    load_engine(j, rnd(4) == 0);
                    run[j] = 1; halted_for[j] = 0;
                end
            end
        end
        chk = 0;
        $display("compared %0d clocks: %0d output mismatches, %0d arbiter mismatches, %0d host-read mismatches",
                 cycles, mism, arb_mism, rd_mism);
        $display("bubbles: lost to engine %0d, lost to host %0d, first L2 fetch after RUN %0d, unexplained %0d, in L1 %0d",
                 cov_bub_eng, cov_bub_host, cov_bub_first, unexplained, l1_bubbles);
        $display("coverage: L1->L2 %0d, L2->L1 %0d, L2 jumps %0d, L2 sequential %0d, collisions %0d (RR %0d, e0 %0d, e1 %0d), class-3 requests %0d, restarts %0d",
                 cov_l1l2, cov_l2l1, cov_l2jmp, cov_l2seq, cov_collide, cov_pol[0], cov_pol[1], cov_pol[2], cov_pf, cov_restart);
        $display("faults: illegal %0d, reserved %0d, L2 range %0d, COPY %0d", cov_fault[0], cov_fault[1], cov_fault[2], cov_fault[3]);
        `CHECK(mism == 0, "engines equal their models every clock (modulo bubbles)")
        `CHECK(arb_mism == 0, "every grant equals the reference arbiter")
        `CHECK(rd_mism == 0, "host L2 reads return the model's word")
        `CHECK(unexplained == 0, "every bubble explained")
        `CHECK(l1_bubbles == 0, "no bubble while the pc is in L1")
        `CHECK(held_req == 0, "F9 no L2 request from a held engine")
        `CHECK(bad_class == 0, "a fresh prefetch asks at class 3")
        `CHECK(cycles >= target, "enough clocks compared")
        `CHECK(cov_bub_eng > 0 && cov_bub_host > 0 && cov_bub_first > 0, "every bubble cause seen")
        `CHECK(cov_l1l2 > 0 && cov_l2l1 > 0 && cov_l2jmp > 0 && cov_l2seq > 0, "every tier transition seen")
        `CHECK(cov_pol[0] > 0 && cov_pol[1] > 0 && cov_pol[2] > 0, "collisions under every policy")
        `CHECK(cov_fault[0] > 0 && cov_fault[1] > 0 && cov_fault[2] > 0, "faults of causes 0, 1, 2")
        $display("wait bounds (non-host losses in a row, class 2): round-robin max %0d, favoured engine max %0d", max_rr, max_fav);
        `CHECK(max_rr <= 1 && max_fav == 0, "V3.5 round-robin waits <= 1, the favoured engine never waits")
        `REPORT("tb_l2_exec")
        $finish;
    end
endmodule
