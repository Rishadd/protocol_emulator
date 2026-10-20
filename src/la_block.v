// Logic analyser block: everything between the pins and the management window (docs/DEBUG_LA_PLAN.md, Phase 3).
//   * the free-running 32-bit clock counter (TSTAMP in the engines, TS register here)
//   * a 2-flop synchroniser on the 13 input-capable pins, so a capture shows what the engines' own synchronisers deliver (same latency)
//   * la_unit (capture state machine, host/la_model.py) and its buffer, the third SRAM macro (1P 256x32)
//   * the register window 0x0300..0x03FF, word index a = addr[7:2]:
//       a 0  0x0300 CTRL     W: [0] arm (restart the capture), [1] manual trigger, others 0.  R: [1:0] state (0 idle, 1 armed, 2 triggered, 3 done)
//                            [2] full [3] wrapped [15:8] write pointer [23:16] trigger position (index of the first post-trigger word)
//       a 1  0x0304 CONFIG   RW [0] sample mode [1] sample channels 15:8 [4:2] trigger type (0 manual 1 pattern 2 rise 3 fall 4 software) [8:5] trigger channel
//       a 2  0x0308 PATTERN  RW {value[31:16], mask[15:0]}
//       a 3  0x030C DIV      RW sample period in clocks (sample mode)
//       a 4  0x0310 POST     RW {post_clk[31:16], post_words[15:0]}
//       a 5  0x0314 TRIGCNT  R  clocks since the previous word at the trigger clock
//       a 6  0x0318 PTR      RW read pointer of DATA
//       a 7  0x031C DATA     R  buffer word at PTR, then PTR + 1 (frame v2 only; BUSY while the capture runs)
//       a 8  0x0320 TS       R  the clock counter
//     CONFIG .. POST cannot be written while the capture runs (armed or triggered).
//   * channels: 0-7 uio[7:0], 8-12 ui_in[7:3], 13 / 14 RUN of engine 0 / 1, 15 OR of the engines' trigger lines
`ifdef LA
module la_block (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [12:0] pins,          // {ui_in[7:3], uio_in[7:0]}
    input  wire [1:0]  run,
    input  wire [1:0]  eng_trig,
    output reg  [31:0] ts,
    // register window
    input  wire [5:0]  w_addr,
    input  wire [31:0] w_data,
    output wire        w_hit,
    output wire        w_ok,
    input  wire        we,
    input  wire [5:0]  r_addr,
    output reg  [31:0] r_data,
    // buffer readout (DATA): strobe in the commit clock, dv two clocks later with the word
    input  wire        rd_strobe,
    output reg         dv,
    output reg  [31:0] dout,
    output wire        busy,          // armed or triggered: the buffer is being written
    output wire        done_pulse,    // one clock when the capture completes
    output reg  [5:0]  view
);
    localparam AW = 8;

    always @(posedge clk or negedge rst_n)
        if (!rst_n) ts <= 32'd0;
        else        ts <= ts + 32'd1;

    reg [12:0] s0, s1;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin s0 <= 13'd0; s1 <= 13'd0; end
        else        begin s0 <= pins;  s1 <= s0; end

    wire [15:0] ch = {|eng_trig, run[1], run[0], s1};

    // ------------------------------------------------------------ registers
    reg        mode_sample, sel_hi;
    reg [2:0]  trig_type;
    reg [3:0]  trig_chan;
    reg [15:0] mask, value, div, post_words, post_clk;
    reg [AW-1:0] ptr;

    wire [1:0]    state;
    wire [AW-1:0] wp, trig_wp, buf_waddr;
    wire          full, wrapped, buf_we;
    wire [15:0]   trig_cnt;
    wire [31:0]   buf_wdata;

    assign busy = (state == 2'd1) || (state == 2'd2);

    wire a_ctrl = (w_addr == 6'd0), a_cfg = (w_addr == 6'd1), a_pat = (w_addr == 6'd2), a_div = (w_addr == 6'd3),
         a_post = (w_addr == 6'd4), a_ptr = (w_addr == 6'd6);
    assign w_hit = (w_addr <= 6'd8);
    assign w_ok  = a_ctrl ? (w_data[31:2] == 30'd0) :
                   a_cfg  ? (w_data[31:9] == 23'd0 && w_data[4:2] <= 3'd4 && !busy) :
                   (a_pat || a_div || a_post) ? !busy :
                   a_ptr  ? (w_data[31:AW] == 24'd0) : 1'b0;

    wire arm    = we && a_ctrl && w_data[0];
    wire manual = we && a_ctrl && w_data[1];

    wire rd_data_strobe = rd_strobe;        // the management controller only issues it when !busy
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            mode_sample <= 1'b0; sel_hi <= 1'b0; trig_type <= 3'd0; trig_chan <= 4'd0;
            mask <= 16'd0; value <= 16'd0; div <= 16'd1; post_words <= 16'd0; post_clk <= 16'd0; ptr <= {AW{1'b0}};
        end else begin
            if (we && a_cfg)  begin mode_sample <= w_data[0]; sel_hi <= w_data[1]; trig_type <= w_data[4:2]; trig_chan <= w_data[8:5]; end
            if (we && a_pat)  begin mask <= w_data[15:0]; value <= w_data[31:16]; end
            if (we && a_div)  div <= w_data[15:0];
            if (we && a_post) begin post_words <= w_data[15:0]; post_clk <= w_data[31:16]; end
            if (we && a_ptr)  ptr <= w_data[AW-1:0];
            else if (rd_data_strobe) ptr <= ptr + {{(AW-1){1'b0}}, 1'b1};
        end
    end

    always @(*) begin
        case (r_addr)
            6'd0:    r_data = {8'd0, trig_wp, wp, 4'd0, wrapped, full, state};
            6'd1:    r_data = {23'd0, trig_chan, trig_type, sel_hi, mode_sample};
            6'd2:    r_data = {value, mask};
            6'd3:    r_data = {16'd0, div};
            6'd4:    r_data = {post_clk, post_words};
            6'd5:    r_data = {16'd0, trig_cnt};
            6'd6:    r_data = {24'd0, ptr};
            6'd8:    r_data = ts;
            default: r_data = 32'd0;
        endcase
    end

    // ------------------------------------------------------------ capture unit and buffer
    la_unit #(.AW(AW)) u_la (
        .clk(clk), .rst_n(rst_n), .ch(ch), .arm(arm), .manual(manual), .mode_sample(mode_sample), .div(div), .sel_hi(sel_hi),
        .trig_type(trig_type), .trig_chan(trig_chan), .trig_mask(mask), .trig_value(value), .post_words(post_words), .post_clk(post_clk),
        .state(state), .wp(wp), .full(full), .wrapped(wrapped), .trig_wp(trig_wp), .trig_cnt(trig_cnt),
        .buf_we(buf_we), .buf_waddr(buf_waddr), .buf_wdata(buf_wdata));

    reg [1:0] st_q;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) st_q <= 2'd0; else st_q <= state;
    assign done_pulse = (state == 2'd3) && (st_q != 2'd3);

    wire [31:0] mem_q;
    wire [AW-1:0] mem_addr = buf_we ? buf_waddr : ptr;
    RM_IHPSG13_1P_256x32_c2_bm_bist u_buf (
        .A_CLK(clk), .A_MEN(1'b1), .A_WEN(buf_we), .A_REN(!buf_we), .A_ADDR(mem_addr), .A_DIN(buf_wdata), .A_DLY(1'b1), .A_DOUT(mem_q),
        .A_BM({32{1'b1}}),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(8'd0),
        .A_BIST_DIN(32'd0), .A_BIST_BM(32'd0));

    reg rq;
    always @(posedge clk or negedge rst_n)
        if (!rst_n) begin rq <= 1'b0; dv <= 1'b0; dout <= 32'd0; end
        else begin rq <= rd_strobe; dv <= rq; if (rq) dout <= mem_q; end

    // debug view 6: [0] armed [1] triggered or done [2] done [3] full [4] wrapped [5] the engines' trigger line
    always @(*) view = {|eng_trig, wrapped, full, state == 2'd3, state[1], state == 2'd1};

`ifndef SYNTHESIS
    task poke(input integer a, input [31:0] w);
        u_buf.i_SRAM_1P_behavioral_bm_bist.memory[a] = w;
    endtask
    function [31:0] peek(input integer a);
        peek = u_buf.i_SRAM_1P_behavioral_bm_bist.memory[a];
    endfunction
`endif
endmodule
`endif
