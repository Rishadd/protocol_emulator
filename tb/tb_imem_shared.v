// Unit test of imem_shared (SHARED_IMEM, physical addressing): fetch on both ports, windows set by OP_REGION (rg_go),
// the trap outside a window, the window clearing when an engine is held, host writes through a held engine's port,
// and the rule that a host write may not hit a running window. Compile with -DFUNCTIONAL -DSHARED_IMEM.
`timescale 1ns/10ps
module tb_imem_shared;
    // waveform: run vvp with +dump to write build/wave/tb_imem_shared.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_imem_shared.vcd"); $dumpvars(0, tb_imem_shared); end
    reg clk = 0, rst_n = 0;
    always #5 clk = ~clk;

    reg  [1:0]  run = 2'b00;
    reg  [8:0]  f_addr0 = 0, f_addr1 = 0;
    wire [31:0] f_raw0, f_raw1;
    wire        f_oob0, f_oob1;
    // the engines substitute TRAP (opcode 31) for an out-of-window word; the bench applies the same rule to keep checking the word the engine would decode
    wire [31:0] f_instr0 = f_oob0 ? {5'd31, 27'd0} : f_raw0;
    wire [31:0] f_instr1 = f_oob1 ? {5'd31, 27'd0} : f_raw1;
    reg         rg_go0 = 0, rg_go1 = 0;
    reg  [18:0] rg_val0 = 0, rg_val1 = 0;
    wire        locked0, locked1;
    reg         iw_wr = 0;
    reg  [8:0]  iw_addr = 0;
    reg  [31:0] iw_data = 0;
    wire        iw_ok;
    reg         ir_rd = 0;
    wire [31:0] ir_data, region0, region1;
    wire        ir_valid;

    imem_shared dut (
        .clk(clk), .rst_n(rst_n), .run(run),
        .f_addr0(f_addr0), .f_addr1(f_addr1), .f_raw0(f_raw0), .f_raw1(f_raw1), .f_oob0(f_oob0), .f_oob1(f_oob1),
        .rg_go0(rg_go0), .rg_go1(rg_go1), .rg_val0(rg_val0), .rg_val1(rg_val1),
        .locked0(locked0), .locked1(locked1),
        .iw_wr(iw_wr), .iw_addr(iw_addr), .iw_data(iw_data), .iw_ok(iw_ok),
        .ir_rd(ir_rd), .ir_data(ir_data), .ir_valid(ir_valid), .region0(region0), .region1(region1));

    integer fails = 0, checks = 0;
    task check(input ok, input [8*56-1:0] what);
        begin
            checks = checks + 1;
            if (!ok) begin fails = fails + 1; $display("FAIL: %0s", what); end
        end
    endtask

    // host write of one word (applied at the next rising edge)
    task host_write(input [8:0] a, input [31:0] w);
        begin
            @(negedge clk);
            iw_addr = a; iw_data = w; iw_wr = 1;
            @(negedge clk);
            iw_wr = 0;
        end
    endtask

    // present both fetch addresses in one clock; the words are read one clock later
    task fetch(input [8:0] a0, input [8:0] a1, output [31:0] w0, output [31:0] w1);
        begin
            @(negedge clk);
            f_addr0 = a0; f_addr1 = a1;
            @(negedge clk);
            w0 = f_instr0; w1 = f_instr1;
        end
    endtask

    // OP_REGION of one engine: window = [base, limit), one clock
    task region(input e, input [8:0] base, input [9:0] limit);
        begin
            @(negedge clk);
            if (e == 0) begin rg_go0 = 1; rg_val0 = {limit, base}; end
            else        begin rg_go1 = 1; rg_val1 = {limit, base}; end
            @(negedge clk);
            rg_go0 = 0; rg_go1 = 0;
        end
    endtask

    // host read of one word: strobe for one clock; the word and ir_valid arrive two clocks after the strobe clock and ir_valid lasts one clock
    reg        v_early, v_on, v_late;
    task host_read(input [8:0] a, output [31:0] w);
        begin
            @(negedge clk);
            iw_addr = a; ir_rd = 1;
            @(negedge clk);
            ir_rd = 0; v_early = ir_valid;
            @(negedge clk);
            w = ir_data; v_on = ir_valid;
            @(negedge clk);
            v_late = ir_valid;
        end
    endtask

    reg [31:0] w0, w1;
    integer k;

    initial begin
        #1; rst_n = 0; #20; rst_n = 1;
        @(negedge clk);
        run = 2'b00;                                        // both held after reset

        // A. host writes through the held engines' port (both held: port B), then fetch both engines
        for (k = 0; k < 16; k = k + 1) host_write(k, 32'h1000 + k);
        for (k = 0; k < 16; k = k + 1) host_write(256 + k, 32'h2000 + k);
        check(dut.u_mem.i_SRAM_2P_behavioral_bm_bist.mem_arr[5] == 32'h1005, "host write lands at physical word 5");
        check(dut.u_mem.i_SRAM_2P_behavioral_bm_bist.mem_arr[261] == 32'h2005, "host write lands at physical word 261");
        check(!locked0 && !locked1, "no window locked after reset");

        // B. both engines run; OP_REGION sets their windows. A fetch in the same clock already sees the new window.
        run = 2'b11; @(negedge clk); #1;
        @(negedge clk);
        rg_go0 = 1; rg_val0 = {10'd16, 9'd8}; f_addr0 = 9'd16; f_addr1 = 9'd256;   // engine 0: [8,16), fetches 16 now
        @(negedge clk);
        rg_go0 = 0;
        check(f_instr0[31:27] == 5'd31, "fetch in the OP_REGION clock outside the new window traps");
        check(locked0, "OP_REGION locks engine 0");
        region(1, 9'd256, 10'd260);
        check(locked1, "OP_REGION locks engine 1");
        fetch(9'd8, 9'd256, w0, w1);
        check(w0 == 32'h1008, "engine 0 fetches inside its window");
        check(w1 == 32'h2000, "engine 1 fetches its base");
        fetch(9'd16, 9'd259, w0, w1);
        check(w0[31:27] == 5'd31, "engine 0 fetch at its limit traps");
        check(w1 == 32'h2003, "engine 1 fetches its last word");
        fetch(9'd3, 9'd260, w0, w1);
        check(w0[31:27] == 5'd31, "engine 0 fetch below its base traps");
        check(w1[31:27] == 5'd31, "engine 1 fetch at its limit traps");

        // C. engine 1 held, engine 0 running with [8,16): writes into its window refused, outside accepted (port A)
        run = 2'b01; @(negedge clk); #1;
        iw_addr = 9'd10; #1;
        check(iw_ok == 1'b0, "write into the running window refused");
        iw_addr = 9'd300; #1;
        check(iw_ok == 1'b1, "write outside the running window accepted via the held engine's port");

        // D. both running: no host port
        run = 2'b11; @(negedge clk); #1;
        iw_addr = 9'd300; #1;
        check(iw_ok == 1'b0, "both engines running: host write refused");

        // E. engine 0 held (port B), engine 1 running: its window was cleared while it was held, so it is the full memory
        run = 2'b10; @(negedge clk); #1;
        iw_addr = 9'd300; #1;
        check(iw_ok == 1'b0, "engine 1 running with the cleared (full) window refuses word 300");
        iw_addr = 9'd258; #1;
        check(iw_ok == 1'b0, "and word 258 as well");

        // F. engine 1 running with its window cleared by a held period: the full memory is its window
        run = 2'b00; @(negedge clk); #1;
        run = 2'b10; @(negedge clk); #1;
        iw_addr = 9'd300; #1;
        check(iw_ok == 1'b0, "engine 1 running with the full window refuses every host write");

        // G. instruction readback with both engines held (port B): every word written in A comes back, valid pulses once, two clocks after the strobe
        run = 2'b00; @(negedge clk); #1;
        host_read(9'd5, w0);
        check(w0 == 32'h1005 && v_on && !v_early && !v_late, "readback word 5 via port B, valid pulse exactly once");
        host_read(9'd261, w0);
        check(w0 == 32'h2005 && v_on, "readback word 261 via port B");
        host_write(9'd400, 32'hCAFE0190);
        host_read(9'd400, w0);
        check(w0 == 32'hCAFE0190, "write then read back word 400");

        // H. engine 0 running with window [8,16), engine 1 held: readback goes through port A, also inside the running window (read only)
        run = 2'b11; @(negedge clk); #1;
        region(0, 9'd8, 10'd16);
        check(region0 == {6'd0, 10'd16, 7'd0, 9'd8}, "REGION of engine 0 after OP_REGION [8,16)");
        run = 2'b01; @(negedge clk); #1;
        host_read(9'd10, w0);
        check(w0 == 32'h1000 + 10 && v_on, "readback inside the running window via port A");
        host_read(9'd400, w0);
        check(w0 == 32'hCAFE0190, "readback outside the window via port A");
        check(region0 == {6'd0, 10'd16, 7'd0, 9'd8}, "REGION of engine 0 kept while it runs");

        // I. REGION of engine 1, and the full window after a hold
        run = 2'b11; @(negedge clk); #1;
        region(1, 9'd256, 10'd260);
        check(region1 == {6'd0, 10'd260, 7'd0, 9'd256}, "REGION of engine 1 after OP_REGION [256,260)");
        run = 2'b10; @(negedge clk); #1; @(negedge clk); #1;
        check(region0 == {6'd0, 10'd512, 7'd0, 9'd0}, "REGION of a held engine is the full memory");
        check(region1 == {6'd0, 10'd260, 7'd0, 9'd256}, "REGION of the running engine is kept");

        $display("RESULT tb_imem_shared: %s (%0d/%0d checks)", fails == 0 ? "PASS" : "FAIL", checks - fails, checks);
        $finish;
    end
endmodule
