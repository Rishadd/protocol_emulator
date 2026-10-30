`timescale 1ns/1ps
// Test bench of la_unit: runs many (configuration, stimulus) pairs and writes one log line per clock plus the buffer at the end of each test.
// host/la_rtl_test.py makes the inputs, runs host/la_model.py on the same inputs and compares everything.
//   +CFG=<hex> 4 words per test: {..., sel, mode} A, {value, mask} B, {post_clk, post_words} C, div D     +STIM=<hex> N words per test {14'b0, manual, arm, ch[15:0]}
//   +NT=<tests> +N=<clocks per test> +OUT=<log>          parameter AW: buffer of 2**AW words
// Log: "C state wp full wrapped we wdata" per clock (we / wdata = the write this clock performs, the rest after the edge); per test "T trig_wp trig_cnt" and "M i word" for every buffer word
module tb_la_unit;
    parameter AW = 8;
    localparam DEPTH = 1 << AW;
    reg         clk = 0, rst_n = 0, arm = 0, manual = 0, mode_sample = 0, sel_hi = 0;
    reg  [15:0] ch = 0, div = 1, trig_mask = 0, trig_value = 0, post_words = 0, post_clk = 0;
    reg  [2:0]  trig_type = 0;
    reg  [3:0]  trig_chan = 0;
    wire [1:0]  state;
    wire [AW-1:0] wp, trig_wp, buf_waddr;
    wire        full, wrapped, buf_we;
    wire [15:0] trig_cnt;
    wire [31:0] buf_wdata;

    la_unit #(.AW(AW)) dut (.clk(clk), .rst_n(rst_n), .ch(ch), .arm(arm), .manual(manual), .mode_sample(mode_sample), .div(div), .sel_hi(sel_hi),
        .trig_type(trig_type), .trig_chan(trig_chan), .trig_mask(trig_mask), .trig_value(trig_value), .post_words(post_words), .post_clk(post_clk),
        .state(state), .wp(wp), .full(full), .wrapped(wrapped), .trig_wp(trig_wp), .trig_cnt(trig_cnt),
        .buf_we(buf_we), .buf_waddr(buf_waddr), .buf_wdata(buf_wdata));

    reg [31:0] mem [0:DEPTH-1];
    always @(posedge clk) if (buf_we) mem[buf_waddr] <= buf_wdata;

    always #5 clk = ~clk;
    reg [31:0] cfg [0:4*400-1];
    reg [31:0] stim [0:4000000-1];
    reg [8*256-1:0] cf, sf, of;
    integer nt, n, t, c, i, fo;
    reg [31:0] s, w_wd;
    reg w_we;

    initial begin
        if (!$value$plusargs("CFG=%s", cf) || !$value$plusargs("STIM=%s", sf) || !$value$plusargs("OUT=%s", of)) begin
            $display("RESULT tb_la_unit: FAIL (need +CFG +STIM +OUT)"); $finish;
        end
        if (!$value$plusargs("NT=%d", nt)) nt = 1;
        if (!$value$plusargs("N=%d", n)) n = 100;
        $readmemh(cf, cfg);
        $readmemh(sf, stim);
        fo = $fopen(of, "w");
        for (t = 0; t < nt; t = t + 1) begin
            rst_n = 0; arm = 0; manual = 0; ch = 0;
            for (i = 0; i < DEPTH; i = i + 1) mem[i] = 32'd0;
            mode_sample = cfg[4*t][0]; sel_hi = cfg[4*t][1]; trig_type = cfg[4*t][4:2]; trig_chan = cfg[4*t][8:5];
            trig_mask = cfg[4*t+1][15:0]; trig_value = cfg[4*t+1][31:16]; post_words = cfg[4*t+2][15:0]; post_clk = cfg[4*t+2][31:16]; div = cfg[4*t+3][15:0];
            @(negedge clk); @(negedge clk); rst_n = 1;
            for (c = 0; c < n; c = c + 1) begin
                @(negedge clk);
                s = stim[t * n + c];
                ch = s[15:0]; arm = s[16]; manual = s[17];
                #1; w_we = buf_we; w_wd = buf_wdata;
                @(posedge clk); #1;
                $fdisplay(fo, "C %0d %0d %b%b %b %h", state, wp, full, wrapped, w_we, w_we ? w_wd : 32'd0);
            end
            $fdisplay(fo, "T %0d %0d", trig_wp, trig_cnt);
            for (i = 0; i < DEPTH; i = i + 1) $fdisplay(fo, "M %0d %h", i, mem[i]);
        end
        $fclose(fo);
        $display("RESULT tb_la_unit: DONE (%0d tests x %0d clocks)", nt, n);
        $finish;
    end
endmodule
