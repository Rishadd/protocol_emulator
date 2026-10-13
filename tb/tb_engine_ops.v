`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// JPO and PUSHI inside a real engine_top: OSR bit order, RX FIFO data path, stall on a full FIFO.
// The host drains the RX FIFO on the falling edge whenever `drain` is set.
// V1.2 (two-tier plan): every jump type and a sequential run past 0x03F to a pc outside L1 faults
// with cause 1 (reserved) or 2 (L2, range empty), and the word the L1 macro shows for that pc
// (word 63 = SETH 1) never commits.
// Phase 3 (engine + shared L2, nothing else on the L2 port except tb host reads):
//   V3.8  leaving the L2 range (sequential, JMP to lo-1, DJNZ/JPH/JPL/JPO to hi+1) faults with cause 2,
//         the word there (SETH 1) never commits
//   V3.9  reset vectors: L1 1 / 0x3F start with no bubble, L2 lo / hi start after exactly one bubble;
//         RUN dropped at 0-4 clocks after a request starts losing to the host: clean restart
//   V3.10 an uncontended jump into L2 costs no bubble (mode A)
// Phase 4 (prefetch buffer; a tb "phantom" second engine requests urgently every clock, round-robin):
//   V4.1  (host reads every 2nd clock too) held / blocked predecessor (WAIT, OUT1, IN1 d = 0..6, 20; PULL, WAITH blocked 0..6, 20 clocks)
//         then SETH in L2: bubbles before the SETH, PB on and off; H_PF = shortest hold with none
//   V4.4  PB on never gives more bubbles than PB off (same program, same contention)
//   V4.6  a prefetch is granted within 2 clocks against an engine asking every clock (promotion)
//   V4.7  a word blocked for ever asks for its prefetch only until it is granted
//   V4.5  UART TX run from L2 under the same contention vs from L1: bubbles per bit, waveform
module tb_engine_ops;
    reg         clk = 0, rst_n = 0, run = 0, drain = 1;
    reg         tx_wr_en = 0, rx_rd_en = 0;
    reg  [31:0] tx_wr_data = 0;
    reg  [7:0]  pin_in = 0;
    wire [31:0] rx_rd_data;
    wire        tx_full, rx_empty, halted, fault;
    wire [7:0]  pin_out, pin_oe;
    wire [8:0]  pc;
    wire [1:0]  cause;

    reg  [8:0]  rv = 0;
    reg         ph = 0;                  // phantom engine 1: urgent request every clock
    reg  [1:0]  fcfg = 2'b00;
    reg  [15:0] rng = 16'h00FF;
    reg         h_we = 0, h_re = 0;
    reg  [7:0]  h_a = 0;
    reg  [31:0] h_d = 0;
    wire        l2_req, l2_hi, bubble;
    wire [7:0]  l2_a;
    wire [1:0]  gnt;
    wire [31:0] l2d;
    integer errors = 0, nrx = 0, k, j, t, nbub = 0, first_set = 0, ck = 0, p_on, hpf, ntr = 0, dt, same;
    integer bub_pb [0:39][0:1];
    integer hk;                          // host-toggle loop counter (ck belongs to the clock counter)
    integer ntr_j [0:1];
    integer bub_j [0:1];
    time    tr [0:31];
    time    tr_j [0:1][0:31];
    reg [31:0] uw;
    reg [31:0] utx [0:11];
    reg        p0_last = 1'b0;
    always @(posedge clk) if (run && pin_out[0] !== p0_last) begin p0_last = pin_out[0]; if (ntr < 32) tr[ntr] = $time - t_run; ntr = ntr + 1; end
    time t_run = 0;
    initial $readmemh("src/fpga/uart_tx_prog.hex", utx);
    reg [31:0] w63;
    reg [31:0] rx [0:15];

    engine_top dut (
        .clk(clk), .rst_n(rst_n), .run(run),
        .imem_we(1'b0), .imem_waddr(6'd0), .imem_wdata(32'd0),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full),
        .rx_rd_en(rx_rd_en), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in(pin_in), .pin_out(pin_out), .pin_oe(pin_oe),
        .reset_pc(rv), .l2_range(rng), .fetch_cfg(fcfg),
        .l2_req(l2_req), .l2_req_hi(l2_hi), .l2_addr(l2_a), .l2_gnt(gnt[0]), .l2_rdata(l2d), .bubble(bubble),
        .halted(halted), .fault(fault), .fault_cause(cause), .pc(pc));
    l2_mem l2 (.clk(clk), .rst_n(rst_n), .h_we(h_we), .h_re(h_re), .h_addr(h_a), .h_wdata(h_d),
               .req({ph, l2_req}), .req_hi({ph, l2_hi}), .req_addr({8'd0, l2_a}), .policy(2'd0), .gnt(gnt), .rdata(l2d));
    integer bub_at = 0, nreq = 0, wait_pf = 0, max_pf = 0;
    reg [8:0] watch = 9'h141;
    always @(posedge clk) if (run) begin
        if (bubble && pc == watch) bub_at = bub_at + 1;              // bubbles in front of the watched word
        nreq = nreq + l2_req;
        if (l2_req && !l2_hi) wait_pf = 1;                           // a fresh prefetch request is waiting
        else if (l2_req && !gnt[0] && wait_pf > 0 && !h_re) wait_pf = wait_pf + 1;   // host clocks do not count (bound: +1 each)
        if (gnt[0]) begin if (wait_pf > max_pf) max_pf = wait_pf; wait_pf = 0; end
    end
    always @(posedge clk) if (run) begin
        ck = ck + 1; nbub = nbub + bubble;
        if (pin_out[2] && first_set == 0) first_set = ck;         // clock in which SETH 2/4 committed
        if (pin_out[4] && first_set == 0) first_set = ck;
    end
    task l2w(input [7:0] a, input [31:0] d); begin h_we = 1; h_a = a; h_d = d; @(posedge clk); #1 h_we = 0; end endtask

    always #5 clk = ~clk;
    always @(negedge clk) begin
        rx_rd_en = 0;
        if (drain && !rx_empty) begin rx[nrx] = rx_rd_data; nrx = nrx + 1; rx_rd_en = 1; end
    end

    function [31:0] I(input [4:0] op, input [26:0] v); I = {op, v}; endfunction

    // reset (clears FIFOs), load prog[0..n-1], optional TX word, run until HALT (or timeout)
    reg [31:0] prog [0:15];
    task run_prog(input integer n, input [31:0] tx);
        begin
            run = 0; rst_n = 0; nrx = 0; nbub = 0; ck = 0; first_set = 0;
            @(posedge clk); #1 rst_n = 1;
            for (k = 0; k < 64; k = k + 1) dut.imem.poke(k, k < n ? prog[k] : k == 63 ? w63 : I(`OP_HALT, 0));
            @(negedge clk) begin tx_wr_en = 1; tx_wr_data = tx; end
            @(negedge clk) tx_wr_en = 0;
            @(posedge clk); @(posedge clk); #1 run = 1;
            for (k = 0; k < 2000 && !halted; k = k + 1) @(posedge clk);
            repeat (4) @(posedge clk);
        end
    endtask

    // JPO decode loop: one PUSHI 0/1 per OSR bit
    task jpo_prog(input [7:0] cfg);
        begin
            prog[0] = I(`OP_CFG, cfg);    prog[1] = I(`OP_PULL, 0);   prog[2] = I(`OP_SETL, 8);
            prog[3] = I(`OP_JPO, 6);      prog[4] = I(`OP_PUSHI, 0);  prog[5] = I(`OP_JMP, 7);
            prog[6] = I(`OP_PUSHI, 1);    prog[7] = I(`OP_DJNZ, 3);   prog[8] = I(`OP_HALT, 0);
        end
    endtask

    reg [7:0] got;
    initial begin
        w63 = I(`OP_HALT, 0);
        // ---- JPO, MSB-first: 0xC1 in [31:24] -> 1,1,0,0,0,0,0,1
        jpo_prog(8'h40); run_prog(9, 32'hC100_0000);
        got = 0; for (k = 0; k < 8; k = k + 1) got = {got[6:0], rx[k][0]};
        `CHECK(nrx == 8 && got == 8'hC1 && !fault, "JPO MSB-first consumes bits 31.. in order")
        // ---- JPO, LSB-first: 0xC1 in [7:0] -> 1,0,0,0,0,0,1,1
        jpo_prog(8'h00); run_prog(9, 32'h0000_00C1);
        got = 0; for (k = 0; k < 8; k = k + 1) got = {rx[k][0], got[7:1]};
        `CHECK(nrx == 8 && got == 8'hC1 && !fault, "JPO LSB-first consumes bits 0.. in order")

        // ---- PUSHI writes the full 27-bit immediate and leaves the ISR alone
        pin_in = 8'h01;
        prog[0] = I(`OP_CFG, 8'h80);  prog[1] = I(`OP_WAITH, 0);   // the input synchronizer resets to 0
        prog[2] = I(`OP_IN1, 0);  prog[3] = I(`OP_IN1, 0);  prog[4] = I(`OP_IN1, 0);
        prog[5] = I(`OP_PUSHI, 27'h7FF_FFFF);  prog[6] = I(`OP_PUSHI, 27'h400_0003);  prog[7] = I(`OP_PUSH, 0);
        prog[8] = I(`OP_HALT, 0);
        run_prog(9, 0);
        `CHECK(nrx == 3 && rx[0] == 32'h07FF_FFFF && rx[1] == 32'h0400_0003, "PUSHI pushes the zero-extended immediate")
        `CHECK(rx[2] == 32'h0000_0007, "PUSHI leaves the ISR intact (3 sampled ones pushed after)")
        pin_in = 8'h00;

        // ---- PUSHI stalls on a full RX FIFO (depth 4) and resumes without loss
        drain = 0;
        for (k = 0; k < 5; k = k + 1) prog[k] = I(`OP_PUSHI, 27'h100 + k);
        prog[5] = I(`OP_HALT, 0);
        run_prog(6, 0);
        `CHECK(!halted && pc == 4, "PUSHI holds the PC while the FIFO is full")
        drain = 1;
        for (k = 0; k < 40; k = k + 1) @(posedge clk);
        `CHECK(halted && nrx == 5 && rx[0] == 32'h100 && rx[4] == 32'h104, "PUSHI resumes, all 5 words in order")

        // ---- V1.2: jumps to reserved / L2 addresses (no L2 yet) and a sequential run off L1 fault, cause 1
        w63 = I(`OP_SETH, 1);
        for (j = 0; j < 5; j = j + 1) for (t = 0; t < 4; t = t + 1) begin
            got = (t == 0) ? 8'h40 : (t == 1) ? 8'hFF : 8'h00;          // low byte of the target
            prog[0] = I(`OP_SETL, 2); prog[1] = I(`OP_PULL, 0); prog[2] = I(`OP_WAITH, 2);
            pin_in = (j == 4) ? 8'h00 : 8'h04;
            case (j)
                0: prog[3] = I(`OP_JMP,  {t[1], got});
                1: prog[3] = I(`OP_DJNZ, {t[1], got});
                2: prog[3] = I(`OP_JPO,  {t[1], got});
                3: prog[3] = I(`OP_JPH,  (2 << 9) | {t[1], got});
                4: begin prog[2] = I(`OP_NOP, 0); prog[3] = I(`OP_JPL, (2 << 9) | {t[1], got}); end
            endcase
            if (t == 2) prog[3][7:0] = 8'h00;                             // 0x100
            if (t == 3) prog[3][7:0] = 8'hFF;                             // 0x1FF
            run_prog(4, 32'h1);
            `CHECK(halted && fault && cause == (t >= 2 ? 2 : 1) && pc == prog[3][8:0] && pin_out[1] == 0,
                   "V1.2 jump outside L1 faults (cause 1 reserved / 2 L2 with empty range), nothing at the bad pc commits")
        end
        pin_in = 8'h00;
        for (k = 0; k < 16; k = k + 1) prog[k] = I(`OP_NOP, 0);
        for (k = 0; k < 64; k = k + 1) dut.imem.poke(k, I(`OP_NOP, 0));
        run = 0; rst_n = 0; @(posedge clk); #1 rst_n = 1; @(posedge clk); #1 run = 1;
        for (k = 0; k < 200 && !halted; k = k + 1) @(posedge clk);
        `CHECK(halted && fault && cause == 1 && pc == 9'h040, "V1.2 sequential run past 0x03F faults at 0x040")

        // ---- Phase 3: an L2 range [0x40, 0x4F]; L2 words written through the host port
        rng = 16'h4F40; w63 = I(`OP_HALT, 0);
        for (k = 0; k < 256; k = k + 1) l2w(k, I(`OP_HALT, 0));
        l2w(8'h3F, I(`OP_SETH, 1)); l2w(8'h50, I(`OP_SETH, 1));          // just outside the range

        // V3.10: L1 JMP 0x140 -> SETH 3, HALT in L2: no bubble at all
        l2w(8'h40, I(`OP_SETH, 3)); l2w(8'h41, I(`OP_HALT, 0));
        prog[0] = I(`OP_JMP, 9'h140); run_prog(1, 0);
        `CHECK(halted && !fault && pin_out[3] && pc == 9'h141 && nbub == 0, "V3.10 uncontended jump into L2: no bubble")

        // V3.8: leave the range -> cause 2 at the outside pc, its SETH 1 never commits
        l2w(8'h4E, I(`OP_NOP, 0)); l2w(8'h4F, I(`OP_NOP, 0));
        prog[0] = I(`OP_JMP, 9'h14E); run_prog(1, 0);
        `CHECK(halted && fault && cause == 2 && pc == 9'h150 && !pin_out[1], "V3.8 sequential run past hi faults (cause 2)")
        prog[0] = I(`OP_JMP, 9'h13F); run_prog(1, 0);
        `CHECK(halted && fault && cause == 2 && pc == 9'h13F && !pin_out[1], "V3.8 JMP to lo-1 faults (cause 2)")
        for (j = 0; j < 4; j = j + 1) begin
            prog[0] = I(`OP_SETL, 2); prog[1] = I(`OP_PULL, 0); prog[2] = I(`OP_WAITH, 2);
            pin_in = (j == 2) ? 8'h00 : 8'h04;
            case (j)
                0: prog[3] = I(`OP_DJNZ, 9'h150);
                1: prog[3] = I(`OP_JPH, (2 << 9) | 9'h150);
                2: begin prog[2] = I(`OP_NOP, 0); prog[3] = I(`OP_JPL, (2 << 9) | 9'h150); end
                3: prog[3] = I(`OP_JPO, 9'h150);
            endcase
            run_prog(4, 32'h1);
            `CHECK(halted && fault && cause == 2 && pc == 9'h150 && !pin_out[1], "V3.8 DJNZ/JPH/JPL/JPO to hi+1 faults (cause 2)")
        end
        pin_in = 8'h00;

        // V3.9: reset vectors
        for (j = 0; j < 2; j = j + 1) begin                                 // L1 vectors 1 and 0x3F
            for (k = 0; k < 16; k = k + 1) prog[k] = I(`OP_HALT, 0);
            rv = j ? 9'h03F : 9'h001;
            if (j) w63 = I(`OP_SETH, 2); else prog[1] = I(`OP_SETH, 2);
            run_prog(2, 0);
            `CHECK(first_set == 2 && nbub == 0, "V3.9 L1 reset vector: first instruction in the first clock (pin seen at the 2nd edge), no bubble")
            w63 = I(`OP_HALT, 0);
        end
        `CHECK(fault && cause == 1 && pc == 9'h040, "V3.9 vector 0x3F then runs on into the reserved range (cause 1)")
        l2w(8'h40, I(`OP_SETH, 4)); l2w(8'h4F, I(`OP_SETH, 4));
        for (j = 0; j < 2; j = j + 1) begin                                 // L2 vectors lo and hi
            rv = j ? 9'h14F : 9'h140;
            run_prog(0, 0);
            `CHECK(first_set == 3 && nbub == 1, "V3.9 L2 reset vector: exactly one bubble, then the first instruction")
        end
        rv = 9'h000;
        // a request that keeps losing to the host, RUN dropped 0-4 clocks into it, clean restart
        l2w(8'h40, I(`OP_SETH, 3)); l2w(8'h41, I(`OP_HALT, 0));
        for (j = 0; j < 5; j = j + 1) begin
            run = 0; rst_n = 0; @(posedge clk); #1 rst_n = 1;
            dut.imem.poke(0, I(`OP_JMP, 9'h140));
            @(posedge clk); @(posedge clk); #1 run = 1;
            h_re = 1; h_a = 8'h00;                                           // host wins every clock
            @(posedge clk); #1;                                              // clock 1: JMP, request loses
            repeat (j) @(posedge clk); #1;
            `CHECK(!pin_out[3] && bubble, "request keeps losing to the host: bubbles")
            run = 0; @(posedge clk); #1 h_re = 0; @(posedge clk); #1 run = 1;
            for (k = 0; k < 20 && !halted; k = k + 1) @(posedge clk);
            #1 `CHECK(halted && !fault && pin_out[3] && pc == 9'h141, "V3.9 restart after RUN drop mid-request: correct program, no stale word")
        end

        // ---- Phase 4
        rv = 9'h000; w63 = I(`OP_HALT, 0); rng = 16'h4F40; pin_in = 8'h00;
        ph = 1;
        for (k = 0; k < 40; k = k + 1) begin : v41                   // kind x length
            j = k % 5; t = k / 5;                                     // j: WAIT OUT1 IN1 PULL WAITH, t: 0..6, 7 = 20
            l2w(8'h40, j == 0 ? I(`OP_WAIT, t == 7 ? 20 : t) : j == 1 ? I(`OP_OUT1, t == 7 ? 20 : t) :
                       j == 2 ? I(`OP_IN1, t == 7 ? 20 : t) : j == 3 ? I(`OP_PULL, 0) : I(`OP_WAITH, 2));
            l2w(8'h41, I(`OP_SETH, 3)); l2w(8'h42, I(`OP_HALT, 0));
            for (p_on = 0; p_on < 2; p_on = p_on + 1) begin
                fcfg = p_on; rv = 9'h140;
                run = 0; rst_n = 0; @(posedge clk); #1 rst_n = 1; pin_in = 8'h00; bub_at = 0; max_pf = 0; wait_pf = 0;
                @(posedge clk); @(posedge clk); #1 run = 1;
                fork
                    begin for (hk = 0; hk < 200 && !halted; hk = hk + 1) begin h_re = hk[0]; @(posedge clk); #1; end h_re = 0; end
                    begin                                             // release the blocked ones after t clocks
                        repeat (2 + (t == 7 ? 20 : t)) @(posedge clk);
                        #1 pin_in = 8'h04; tx_wr_en = 1; tx_wr_data = 1; @(posedge clk); #1 tx_wr_en = 0;
                    end
                join
                bub_pb[k][p_on] = bub_at;
            end
            `CHECK(halted && !fault && pin_out[3], "V4.1 program completes under contention")
            `CHECK(bub_pb[k][1] <= bub_pb[k][0], "V4.4 PB on gives no more bubbles than PB off")
            `CHECK(max_pf <= 2, "V4.6 a prefetch waits at most 2 clocks against an engine asking every clock")
        end
        $display("    V4.1 bubbles before the next word (PB off / on), hold length 0..6, 20:");
        for (j = 0; j < 5; j = j + 1) begin
            $write("      %s", j == 0 ? "WAIT " : j == 1 ? "OUT1 " : j == 2 ? "IN1  " : j == 3 ? "PULL " : "WAITH");
            for (t = 0; t < 8; t = t + 1) $write("  %0d/%0d", bub_pb[t * 5 + j][0], bub_pb[t * 5 + j][1]);
            $display("");
        end
        hpf = 99;                                                     // shortest timed hold with no bubble (PB on)
        for (t = 7; t >= 0; t = t - 1) if (bub_pb[t * 5][1] == 0 && bub_pb[t * 5 + 1][1] == 0 && bub_pb[t * 5 + 2][1] == 0) hpf = t + 1;
        $display("    H_PF (hold clocks d+1 with no bubble for WAIT/OUT1/IN1 under worst contention, PB on) = %0d", hpf);
        `CHECK(hpf <= 4, "V4.1 holds of 4 clocks or more need no bubble with PB on")

        // V4.7: PULL blocked for ever: the prefetch request stops once granted
        l2w(8'h40, I(`OP_PULL, 0)); fcfg = 1; rv = 9'h140;
        run = 0; rst_n = 0; @(posedge clk); #1 rst_n = 1; @(posedge clk); @(posedge clk); #1 run = 1;
        repeat (10) @(posedge clk); nreq = 0; repeat (50) @(posedge clk);
        `CHECK(nreq == 0 && !halted, "V4.7 blocked word: no more requests once pc+1 is in the PB")

        // V4.5: UART TX (434-clock bit) from L2 under contention vs from L1: same bytes, bubbles per bit
        for (j = 0; j < 2; j = j + 1) begin
            for (k = 0; k < 12; k = k + 1) begin
                uw = utx[k];
                if (j == 1 && (uw[31:27] == `OP_JMP || uw[31:27] == `OP_DJNZ)) uw[8:0] = uw[8:0] + 9'h140;   // relocate jumps
                if (j == 0) dut.imem.poke(k, uw); else l2w(8'h40 + k, uw);
            end
            l2w(8'h4C, I(`OP_HALT, 0));
            rv = j ? 9'h140 : 9'h000; rng = 16'h4F40; fcfg = 1; w63 = I(`OP_HALT, 0);
            run = 0; rst_n = 0; @(posedge clk); #1 rst_n = 1; nbub = 0; ntr = 0;
            @(negedge clk) begin tx_wr_en = 1; tx_wr_data = 32'h5A; end @(negedge clk) tx_wr_en = 0;
            @(posedge clk); @(posedge clk); #1 t_run = $time; p0_last = 0; run = 1;
            repeat (434 * 12) @(posedge clk);
            ntr_j[j] = ntr; bub_j[j] = nbub;
            for (k = 0; k < ntr && k < 32; k = k + 1) tr_j[j][k] = tr[k];
        end
        $display("    V4.5 UART TX: L1 %0d edges, %0d bubbles | L2 %0d edges, %0d bubbles (10 bits)", ntr_j[0], bub_j[0], ntr_j[1], bub_j[1]);
        same = ntr_j[0] == ntr_j[1];
        for (k = 0; k < ntr_j[0] && k < 32; k = k + 1) begin
            dt = tr_j[1][k] - tr_j[0][k];
            if (dt < 0 || dt > 20 * 10) same = 0;                     // never early, at most 1 clock per bit late
        end
        `CHECK(bub_j[0] == 0 && same, "V4.5 UART from L2: same bits, never early, at most one clock late per bit")
        ph = 0;

        `REPORT("tb_engine_ops")
        $finish;
    end
endmodule
