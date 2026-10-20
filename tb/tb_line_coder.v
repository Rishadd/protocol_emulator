`timescale 1ns/1ps
// Line coder test bench (driven by host/line_coder_test.py). Two coders on one differential bus with the low-speed pull-up (idle = J):
//   A: the transmitter under test, commands from +CMD=<file>;   B: the receiver under test (bit period +BPER=<hex>, default 0x2155).
// An external "host" can drive the bus from +STIM=<file> (lines "t_ns dp dm oe", times from the start). 1 clock = 20 ns.
// CMD lines:  c <op> <hex data>   one command, issued the way the engine issues LINE (stalls while a TXB / TXE would not fit)
//             w <n>               wait n clocks         r <hex>  read the status of A into the log  (pins as the engine sees them)
// Log (+OUT): L <ns> <dp><dm>      bus change         R <ns> <hex byte>  B received a byte (read and consumed at once)
//             F <ns> <hex flags>   B flags change     E <ns> flags partial  B saw an end of packet / error (flags are then cleared)
//             S <ns> <hex status of A> on 'r' lines    END <ns>
module tb_line_coder;
    reg clk = 0, rst_n = 0;
    reg        a_go = 0, b_go = 0, b_ago = 0;
    reg [2:0]  a_op = 0, b_op = 0;
    reg [31:0] a_data = 0, b_data = 0;
    wire       a_full, a_busy, b_full, b_busy;
    wire [31:0] a_st, b_st;
    wire [2:0] a_dpp, a_dmp, b_dpp, b_dmp;
    wire       a_oe, a_dp, a_dm, b_oe, b_dp, b_dm;
    reg        h_oe = 0, h_dp = 0, h_dm = 1;
    reg        b_pop = 0;

    // bus: the pull-up holds J (D+ low, D- high); two drivers at most, never both in these tests
    wire bus_dp = a_oe ? a_dp : b_oe ? b_dp : h_oe ? h_dp : 1'b0;
    wire bus_dm = a_oe ? a_dm : b_oe ? b_dm : h_oe ? h_dm : 1'b1;
    reg [1:0] a_sp = 2'b01, b_sp = 2'b01;                       // two-flop synchronisers (the engines' pin block)
    always @(posedge clk) begin a_sp <= {a_sp[0], bus_dp}; b_sp <= {b_sp[0], bus_dp}; end
    reg [1:0] a_sm = 2'b11, b_sm = 2'b11;
    always @(posedge clk) begin a_sm <= {a_sm[0], bus_dm}; b_sm <= {b_sm[0], bus_dm}; end

    line_coder a (.clk(clk), .rst_n(rst_n), .cmd_go(a_go), .cmd_op(a_op), .cmd_data(a_data), .full(a_full), .busy(a_busy),
                  .rd_pop(1'b0), .status(a_st), .dp_in(a_sp[1]), .dm_in(a_sm[1]), .dp_pin(a_dpp), .dm_pin(a_dmp),
                  .tx_oe(a_oe), .tx_dp(a_dp), .tx_dm(a_dm));
    wire       b_gow = b_go | b_ago;
    line_coder b (.clk(clk), .rst_n(rst_n), .cmd_go(b_gow), .cmd_op(b_ago ? 3'd4 : b_op), .cmd_data(b_ago ? 32'd3 : b_data), .full(b_full), .busy(b_busy),
                  .rd_pop(b_pop), .status(b_st), .dp_in(b_sp[1]), .dm_in(b_sm[1]), .dp_pin(b_dpp), .dm_pin(b_dmp),
                  .tx_oe(b_oe), .tx_dp(b_dp), .tx_dm(b_dm));

    always #10 clk = ~clk;
    // watchdog: a command stream that never drains (a broken transmitter) must end the run, not hang it
    initial begin #50000000; $display("ERROR watchdog: command stream stalled"); $finish; end

    integer fd, cf, sf, n, k, t0;
    reg [8*256-1:0] outf, cmdf, stimf;
    reg [7:0] op_c;
    reg [8*64-1:0] skip;
    reg [31:0] dat;
    integer wn, st_t, st_n, st_oe, st_dp, st_dm;
    reg [4:0] bf_prev = 5'd0;
    reg       e_pend = 1'b0;                  // an end-of-packet / error event was logged and its flags are being cleared

    always @(bus_dp or bus_dm) if (fd != 0) $fdisplay(fd, "L %0d %b%b", $time - t0, bus_dp, bus_dm);
    // B: consume every received byte at once (the engine would RGET it), log byte and flag changes
    always @(posedge clk) begin
        b_pop <= 1'b0;
        if (b_st[8] && !b_pop) begin b_pop <= 1'b1; $fdisplay(fd, "R %0d %h", $time - t0, b_st[7:0]); end
        b_ago <= 1'b0;
        if (!(b_st[9] || b_st[11] || b_st[12])) e_pend <= 1'b0;
        if ((b_st[9] || b_st[11] || b_st[12]) && !b_st[8] && !e_pend) begin
            e_pend <= 1'b1;
            $fdisplay(fd, "E %0d %h partial=%0d", $time - t0, b_st[12:9], b_st[19:17]);
            b_ago <= 1'b1;
        end
        if (b_st[12:9] != bf_prev[3:0]) begin
            bf_prev[3:0] <= b_st[12:9];
            $fdisplay(fd, "F %0d %h partial=%0d", $time - t0, b_st[12:9], b_st[19:17]);
        end
    end

    task issue(input [2:0] op, input [31:0] d);                  // one LINE instruction on A
        begin
            @(negedge clk); a_go = 0;
            while ((op == 3'd2 || op == 3'd3) && a_full) @(negedge clk);
            a_go = 1; a_op = op; a_data = d;
        end
    endtask
    task issue_b(input [2:0] op, input [31:0] d);
        begin @(negedge clk); b_go = 1; b_op = op; b_data = d; @(negedge clk); b_go = 0; end
    endtask

    initial begin : stim
        if (!$value$plusargs("STIM=%s", stimf)) disable stim;
        wait (fd != 0);
        sf = $fopen(stimf, "r");
        while (!$feof(sf)) begin
            st_n = $fscanf(sf, "%d %d %d %d", st_t, st_dp, st_dm, st_oe);
            if (st_n == 4) begin
                if (st_t > $time - t0) #(st_t - ($time - t0));
                h_dp = st_dp; h_dm = st_dm; h_oe = st_oe;
            end
        end
    end

    initial begin
        if (!$value$plusargs("OUT=%s", outf)) begin $display("ERROR: +OUT missing"); $finish; end
        fd = 0;
        repeat (4) @(posedge clk); #1 rst_n = 1; repeat (4) @(posedge clk);
        fd = $fopen(outf, "w");
        t0 = $time;
        $fdisplay(fd, "L 0 %b%b", bus_dp, bus_dm);
        if ($value$plusargs("BPER=%h", dat)) issue_b(3'd1, dat);
        issue_b(3'd4, 32'd1);                                    // B: receiver on
        if ($value$plusargs("CMD=%s", cmdf)) begin
            cf = $fopen(cmdf, "r");
            while (!$feof(cf)) begin
                n = $fscanf(cf, " %c", op_c);
                if (n == 1) begin
                    if (op_c == "c") begin n = $fscanf(cf, "%d %h", wn, dat); issue(wn[2:0], dat); end
                    else if (op_c == "w") begin n = $fscanf(cf, "%d", wn); @(negedge clk); a_go = 0; repeat (wn) @(negedge clk); end
                    else if (op_c == "r") begin @(negedge clk); a_go = 0; @(negedge clk); $fdisplay(fd, "S %0d %h", $time - t0, a_st); end
                    else n = $fscanf(cf, "%s", skip);
                end
            end
            @(negedge clk); a_go = 0;
        end
        wn = 1000;
        $value$plusargs("TAIL=%d", wn);
        repeat (wn) @(posedge clk);
        $fdisplay(fd, "END %0d", $time - t0);
        $fclose(fd);
        $finish;
    end
endmodule
