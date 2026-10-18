`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// Equivalence of the SRAM-fetch engine (engine_top: synchronous instr_mem addressed with next_pc)
// with the original fetch scheme (ref_engine_top in tb/ref: combinational flop memory addressed with pc),
// both 256 words deep with an 8-bit pc and 8-bit jump targets (JMP, DJNZ, JPH, JPL, JPO).
// Both get identical random programs (loaded through the host write port), identical FIFO and pin
// traffic, random RUN drops and host rewrites while held. Every clock, every output of the two
// engines and the instruction bus itself must match. Plusargs: +TRIALS=n +SEED=n
module tb_fetch_equiv;
    reg         clk = 0, rst_n = 0, run = 0;
    reg         we = 0;
    reg  [7:0]  waddr = 0;
    reg  [31:0] wdata = 0;
    reg         tx_wr_en = 0, rx_rd_en = 0;
    reg  [31:0] tx_wr_data = 0;
    reg  [7:0]  pin_in = 0;

    wire [31:0] d_rxd, r_rxd;
    wire        d_txf, r_txf, d_rxe, r_rxe, d_hlt, r_hlt, d_flt, r_flt;
    wire [7:0]  d_po, r_po, d_oe, r_oe;
    wire [7:0]  d_pc, r_pc;

    engine_top dut (
        .clk(clk), .rst_n(rst_n), .run(run),
        .imem_we(we), .imem_waddr(waddr), .imem_wdata(wdata),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(d_txf),
        .rx_rd_en(rx_rd_en), .rx_rd_data(d_rxd), .rx_empty(d_rxe),
        .pin_in(pin_in), .pin_out(d_po), .pin_oe(d_oe),
        .halted(d_hlt), .fault(d_flt), .pc(d_pc));

    ref_engine_top ref_e (
        .clk(clk), .rst_n(rst_n), .run(run),
        .imem_we(we), .imem_waddr(waddr), .imem_wdata(wdata),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(r_txf),
        .rx_rd_en(rx_rd_en), .rx_rd_data(r_rxd), .rx_empty(r_rxe),
        .pin_in(pin_in), .pin_out(r_po), .pin_oe(r_oe),
        .halted(r_hlt), .fault(r_flt), .pc(r_pc));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    integer ra;
    integer errors = 0, seed = 1, trials = 300, t, k, c, len;
    integer cycles = 0, mism = 0, instr_mism = 0, jumps = 0, stalls = 0, runs_dropped = 0, rewrites = 0;
    integer ophist [0:31];
    integer quarter [0:3];          // run cycles with pc in 0-63, 64-127, 128-191, 192-255
    reg [7:0] pc_prev = 0;
    reg       chk = 0;
    reg [31:0] r;

    function integer rnd(input integer n);      // 0 .. n-1
        reg [31:0] x;
        begin x = $random(seed); rnd = x % n; end
    endfunction

    // Word 0 never holds PULL/PUSH: while the engine is held (RUN=0) control_unit still decodes
    // word 0 and its tx_rd_en / rx_wr_en reach the FIFOs. That quirk exists in the original
    // engine too (see docs/SRAM_INSTR_MEM_RESULTS.md); it is timing-shifted by the new read
    // latency, so the lockstep comparison keeps it out and compares everything else strictly.
    function [31:0] rand_instr(input integer idx);
        reg [31:0] w;
        begin
            w = rand_instr_raw(idx);
            if (idx == 0 && (w[31:27] == `OP_PULL || w[31:27] == `OP_PUSH)) w = {`OP_NOP, 27'd0};
            rand_instr = w;
        end
    endfunction

    function [31:0] rand_instr_raw(input integer idx);
        integer p, d, tgt;
        reg [4:0] op;
        begin
            p = rnd(112);
            d = rnd(7);
            tgt = (rnd(2) == 0) ? rnd(256) : ((idx + rnd(9) - 4) & 255);
            if      (p <  6) rand_instr_raw = {`OP_NOP,   27'd0};
            else if (p < 16) rand_instr_raw = {`OP_WAIT,  27'd0} | d;
            else if (p < 24) rand_instr_raw = {`OP_JMP,   27'd0} | tgt;
            else if (p < 25) rand_instr_raw = {`OP_HALT,  27'd0};
            else if (p < 33) rand_instr_raw = {`OP_SETL,  27'd0} | rnd(6);
            else if (p < 43) rand_instr_raw = {`OP_DJNZ,  27'd0} | tgt;
            else if (p < 51) rand_instr_raw = {`OP_PULL,  27'd0};
            else if (p < 57) rand_instr_raw = {`OP_PUSH,  27'd0};
            else if (p < 66) rand_instr_raw = {`OP_OUT1,  27'd0} | rnd(5);
            else if (p < 72) rand_instr_raw = {`OP_IN1,   27'd0} | rnd(5);
            else if (p < 77) rand_instr_raw = {`OP_SETH,  27'd0} | rnd(8);
            else if (p < 82) rand_instr_raw = {`OP_SETLO, 27'd0} | rnd(8);
            else if (p < 86) rand_instr_raw = {`OP_DIRO,  27'd0} | rnd(8);
            else if (p < 89) rand_instr_raw = {`OP_DIRI,  27'd0} | rnd(8);
            else if (p < 92) rand_instr_raw = {`OP_WAITH, 27'd0} | rnd(8);
            else if (p < 95) rand_instr_raw = {`OP_WAITL, 27'd0} | rnd(8);
            else if (p < 99) rand_instr_raw = {`OP_CFG,   27'd0} | rnd(256);
            else if (p < 103) rand_instr_raw = {`OP_JPH,  27'd0} | (rnd(8) << 8) | tgt;
            else if (p < 107) rand_instr_raw = {`OP_JPL,  27'd0} | (rnd(8) << 8) | tgt;
            else if (p < 111) rand_instr_raw = {`OP_JPO,  27'd0} | tgt;
            else begin op = 5'd21 + rnd(11); rand_instr_raw = {op, 27'd0} | rnd(256); end   // illegal -> fault (PUSHI (20) is not generated: the frozen reference has no RX immediate mux)
        end
    endfunction

    task host_write(input [7:0] a, input [31:0] w);
        begin we = 1; waddr = a; wdata = w; tick; we = 0; end
    endtask

    // identical stimulus, driven like flops would (just after the clock edge)
    task stimulus;
        begin
            if (rnd(100) < 6)  pin_in = pin_in ^ (8'd1 << rnd(8));
            if (rnd(100) < 2)  pin_in = rnd(256);
            tx_wr_en   = (rnd(100) < 4);
            tx_wr_data = $random(seed);
            rx_rd_en   = (rnd(100) < 5);
        end
    endtask

    // ------------------------------------------------------------------ comparison + coverage
    always @(negedge clk) if (chk) begin
        cycles = cycles + 1;
        if ({d_po, d_oe, d_pc, d_hlt, d_flt, d_txf, d_rxe, d_rxd} !==
            {r_po, r_oe, r_pc, r_hlt, r_flt, r_txf, r_rxe, r_rxd}) begin
            mism = mism + 1;
            if (mism <= 5) $display("  MISMATCH @%0t run=%b: dut pc=%0d po=%h oe=%h hlt=%b flt=%b txf=%b rxe=%b rxd=%h | ref pc=%0d po=%h oe=%h hlt=%b flt=%b txf=%b rxe=%b rxd=%h",
                $time, run, d_pc, d_po, d_oe, d_hlt, d_flt, d_txf, d_rxe, d_rxd, r_pc, r_po, r_oe, r_hlt, r_flt, r_txf, r_rxe, r_rxd);
        end
        // instr is only used while running; while the host writes, the macro port is busy and
        // its output holds, so it is compared from the first running cycle on
        if (run && dut.instr !== ref_e.instr) begin
            instr_mism = instr_mism + 1;
            if (instr_mism <= 5) $display("  INSTR MISMATCH @%0t pc=%0d dut=%h ref=%h", $time, d_pc, dut.instr, ref_e.instr);
        end
        if (run) begin
            ophist[dut.cu.opcode] = ophist[dut.cu.opcode] + 1;
            if (d_pc !== pc_prev && d_pc !== pc_prev + 8'd1) jumps = jumps + 1;
            if (d_pc === pc_prev && !d_hlt) stalls = stalls + 1;
            quarter[d_pc[7:6]] = quarter[d_pc[7:6]] + 1;
        end
        pc_prev = d_pc;
    end

    initial begin
        for (k = 0; k < 32; k = k + 1) ophist[k] = 0;
        for (k = 0; k < 4; k = k + 1) quarter[k] = 0;
        if ($value$plusargs("TRIALS=%d", trials)) ;
        if ($value$plusargs("SEED=%d", seed)) ;
        rst_n = 0; run = 0; tick; tick; rst_n = 1; tick;
        chk = 1;
        for (t = 0; t < trials; t = t + 1) begin
            // load a fresh random program through the host write port while the engine is held
            run = 0; tick; tick;
            for (k = 0; k < 256; k = k + 1) host_write(k, rand_instr(k));
            if (t % 25 == 0) begin rst_n = 0; tick; tick; rst_n = 1; tick; end   // also reset between trials
            tick;
            run = 1;
            len = 250 + rnd(500);
            for (c = 0; c < len; c = c + 1) begin
                stimulus;
                // occasionally stop the engine, rewrite a few words while held, resume from pc=0
                if (rnd(1000) < 6) begin
                    run = 0; runs_dropped = runs_dropped + 1;
                    tick; tick;
                    for (k = rnd(4); k >= 0; k = k - 1) begin ra = rnd(256); host_write(ra, rand_instr(ra)); rewrites = rewrites + 1; end
                    host_write(0, rand_instr(0)); rewrites = rewrites + 1;   // word 0 is what the engine reads first
                    tick;
                    run = 1;
                end
                tick;
            end
        end
        chk = 0;
        $display("compared %0d cycles over %0d random programs: %0d output mismatches, %0d instr-bus mismatches",
                 cycles, trials, mism, instr_mism);
        $display("coverage: %0d jumps, %0d stall cycles, %0d RUN drops, %0d host rewrites while held", jumps, stalls, runs_dropped, rewrites);
        $display("pc coverage (run cycles per 64-word quarter): %0d %0d %0d %0d", quarter[0], quarter[1], quarter[2], quarter[3]);
        $write("opcode cycles:");
        for (k = 0; k < 32; k = k + 1) if (ophist[k] != 0) $write(" %0d:%0d", k, ophist[k]);
        $display("");
        `CHECK(mism == 0,       "all engine outputs identical every cycle")
        `CHECK(instr_mism == 0, "instruction bus identical every cycle")
        `CHECK(cycles > 100000, "enough cycles compared")
        for (k = 0; k <= 19; k = k + 1) `CHECK(ophist[k] > 100, "every legal opcode executed")
        for (k = 0; k < 4; k = k + 1) `CHECK(quarter[k] > 5000, "every 64-word quarter of the memory executed")
        `CHECK(ophist[21] + ophist[22] + ophist[23] + ophist[24] +
               ophist[25] + ophist[26] + ophist[27] + ophist[28] + ophist[29] + ophist[30] + ophist[31] > 0, "illegal opcodes executed (fault path)")
        `REPORT("tb_fetch_equiv")
        $finish;
    end
endmodule
