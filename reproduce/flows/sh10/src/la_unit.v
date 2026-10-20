// Logic analyser capture unit (docs/DEBUG_LA_PLAN.md). The behaviour is host/la_model.py, clock for clock; tb/tb_la_unit.v + host/la_rtl_test.py compare the two.
//
//   ch          16 channels, one clock wide (the chip feeds the synchronised pins, the two RUN bits and the OR of the engines' trigger lines)
//   arm         one-clock strobe: clear the buffer pointer and the state and start recording with the NEXT clock (this clock only remembers ch for edge detection)
//   manual      one-clock strobe: trigger now (only while armed)
//   mode_sample 0 = change mode (one word {value, delta} per change), 1 = sample mode (4 samples of ch[7:0] / ch[15:8] per word every `div` clocks)
//   trig_type   0 manual only, 1 pattern (ch & mask) == (value & mask), 2 rising edge of ch[trig_chan], 3 falling edge, 4 software (ch[15] rising)
//   post_words / post_clk   after the trigger stop at the first of: post_words more words (a word written in the trigger clock counts), post_clk clocks (0 = no limit
//               of that kind); both 0 stops in the trigger clock
//   buf_*       write port of the buffer: a word is written in a clock when buf_we is high, at buf_waddr = wp (a ring of 2**AW words, the oldest are overwritten)
//   state       0 idle, 1 armed (recording, waiting for the trigger), 2 triggered (recording the post-trigger part), 3 done (buffer frozen)
//   full        2**AW words have been written; wrapped: a word has overwritten an older one
//   trig_wp     write pointer at the trigger = index of the first post-trigger word;  trig_cnt  clocks since the previous word at the trigger clock
module la_unit #(
    parameter AW = 8
) (
    input  wire          clk,
    input  wire          rst_n,
    input  wire [15:0]   ch,
    input  wire          arm,
    input  wire          manual,
    input  wire          mode_sample,
    input  wire [15:0]   div,
    input  wire          sel_hi,
    input  wire [2:0]    trig_type,
    input  wire [3:0]    trig_chan,
    input  wire [15:0]   trig_mask,
    input  wire [15:0]   trig_value,
    input  wire [15:0]   post_words,
    input  wire [15:0]   post_clk,
    output reg  [1:0]    state,
    output reg  [AW-1:0] wp,
    output reg           full,
    output reg           wrapped,
    output reg  [AW-1:0] trig_wp,
    output reg  [15:0]   trig_cnt,
    output wire          buf_we,
    output wire [AW-1:0] buf_waddr,
    output wire [31:0]   buf_wdata
);
    localparam [1:0] IDLE = 2'd0, ARMED = 2'd1, TRIG = 2'd2, DONE = 2'd3;
    localparam [AW-1:0] LAST = {AW{1'b1}};

    reg [15:0] last_ch, prev, cnt, phase, post_w, post_c;
    reg        have_first;
    reg [23:0] samples;
    reg [1:0]  scnt;

    wire [15:0] cnt_n = cnt + 16'd1;
    wire        rec   = (state == ARMED) || (state == TRIG);
    wire [7:0]  sbyte = sel_hi ? ch[15:8] : ch[7:0];

    // trigger condition on the channel vector of this clock
    reg cond;
    always @(*) begin
        case (trig_type)
            3'd1:    cond = ((ch & trig_mask) == (trig_value & trig_mask));
            3'd2:    cond = !last_ch[trig_chan] && ch[trig_chan];
            3'd3:    cond = last_ch[trig_chan] && !ch[trig_chan];
            3'd4:    cond = !last_ch[15] && ch[15];
            default: cond = 1'b0;
        endcase
    end
    wire trig_now = (state == ARMED) && (manual || cond);

    // the word written in this clock, if any
    reg        we;
    reg [31:0] wd;
    always @(*) begin
        we = 1'b0;
        wd = 32'd0;
        if (rec) begin
            if (!mode_sample) begin
                if (!have_first)           begin we = 1'b1; wd = {ch, 16'd0}; end
                else if (ch != prev)       begin we = 1'b1; wd = {ch, cnt_n}; end
                else if (cnt_n == 16'hFFFF) begin we = 1'b1; wd = {prev, 16'hFFFF}; end
            end else if (phase == 16'd0 && scnt == 2'd3) begin
                we = 1'b1;
                wd = {sbyte, samples};
            end
        end
    end
    assign buf_we    = we && !arm;
    assign buf_waddr = wp;
    assign buf_wdata = wd;

    // post-trigger accounting: counters as they are after this clock
    wire        in_post = (state == TRIG) || trig_now;
    wire [15:0] pw_n    = (trig_now ? 16'd0 : post_w) + {15'd0, we};
    wire [15:0] pc_n    = (trig_now ? 16'd0 : post_c) + 16'd1;
    wire        stop    = (post_words == 16'd0 && post_clk == 16'd0) ||
                          (post_words != 16'd0 && pw_n >= post_words) ||
                          (post_clk   != 16'd0 && pc_n >= post_clk);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= IDLE; wp <= {AW{1'b0}}; full <= 1'b0; wrapped <= 1'b0; trig_wp <= {AW{1'b0}}; trig_cnt <= 16'd0;
            last_ch <= 16'd0; prev <= 16'd0; cnt <= 16'd0; phase <= 16'd0; post_w <= 16'd0; post_c <= 16'd0;
            have_first <= 1'b0; samples <= 24'd0; scnt <= 2'd0;
        end else begin
            last_ch <= ch;
            if (arm) begin
                state <= ARMED; wp <= {AW{1'b0}}; full <= 1'b0; wrapped <= 1'b0; trig_wp <= {AW{1'b0}}; trig_cnt <= 16'd0;
                prev <= 16'd0; cnt <= 16'd0; phase <= 16'd0; post_w <= 16'd0; post_c <= 16'd0;
                have_first <= 1'b0; samples <= 24'd0; scnt <= 2'd0;
            end else if (rec) begin
                if (trig_now) begin
                    trig_wp  <= wp;
                    trig_cnt <= have_first ? cnt_n : cnt;
                end
                if (!mode_sample) begin
                    if (!have_first)        begin have_first <= 1'b1; prev <= ch; cnt <= 16'd0; end
                    else if (ch != prev)    begin prev <= ch; cnt <= 16'd0; end
                    else if (cnt_n == 16'hFFFF) cnt <= 16'd0;
                    else                    cnt <= cnt_n;
                end else begin
                    have_first <= 1'b1;
                    if (phase == 16'd0) begin
                        samples <= {sbyte, samples[23:8]};
                        scnt    <= scnt + 2'd1;
                    end
                    phase <= (div <= 16'd1 || phase + 16'd1 >= div) ? 16'd0 : phase + 16'd1;
                end
                if (we) begin
                    wp <= wp + {{(AW-1){1'b0}}, 1'b1};
                    if (wp == LAST) full <= 1'b1;
                    if (full)       wrapped <= 1'b1;
                end
                if (in_post) begin
                    post_w <= (pw_n == 16'd0 && we) ? 16'hFFFF : pw_n;           // saturates instead of wrapping
                    post_c <= (pc_n == 16'd0) ? 16'hFFFF : pc_n;
                    state  <= stop ? DONE : TRIG;
                end
            end
        end
    end
endmodule
