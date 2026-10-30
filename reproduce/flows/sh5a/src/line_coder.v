// Line coder: byte-level serial line transceiver for two logical pins of an engine (docs/LINE_CODER.md). Generic, not USB-specific:
// NRZI on/off, bit stuffing on/off with a programmable run length, differential pair with SE0 end-of-packet, bit period in clocks with
// 8 fractional bits (33.33 clocks per bit at 50 MHz for USB low speed = 0x2155). Used by the LINE opcode (28) and RGET source 6.
//
// Commands (executed one clock after the instruction, like the CRC unit; `busy` makes RGET LINE wait that clock):
//   0 CFG     data[2:0] dp pin, [5:3] dm pin, [6] nrzi, [7] stuff, [10:8] stuff run length, [11] fs (J = D+ high, D- low; 0 = low speed)
//   1 PERIOD  data[15:0] bit period in clocks * 256
//   2 TXB     queue data[7:0] for transmission, LSB first (stalls while the 2-entry queue is full)
//   3 TXE     queue an end-of-packet: SE0 for 2 bit times, J for 1 bit time, then the driver is released (stalls while full)
//   4 RXCTL   data[0] receiver enable, data[1] clear the receive flags (eop, stuff error, overrun, sync seen, underrun)
//   5 RESET   transmitter and receiver back to idle, queue emptied (configuration kept)
// Transmit: the first TXB of a packet starts the driver with line idle = J; bit stuffing counts from the first bit (the SYNC byte 0x80
// is an ordinary byte: its last 1 counts), a stuff bit is also inserted after a final run of ones before the EOP. An empty queue in the
// middle of a packet sets `underrun` and waits.
// Receive (armed by RXCTL, ignored while transmitting): the first K after idle starts a packet; the sampler is re-centred on every
// line transition and samples half a bit later; SYNC = at least three 0s then a 1 (a hub may shorten the SYNC); NRZI decode; stuffed
// 0 removed (a 1 where a stuff bit belongs sets `stuff_err`); bytes LSB first; SE0 at a sample point ends the packet (`eop`,
// `partial` = bits of an incomplete last byte). Status: see `status`.
module line_coder (
    input  wire        clk,
    input  wire        rst_n,
    // command from the control unit
    input  wire        cmd_go,
    input  wire [2:0]  cmd_op,
    input  wire [31:0] cmd_data,
    output wire        full,         // an enqueue (TXB / TXE) would not fit: the instruction stalls
    output wire        busy,         // a command from the previous clock is not applied yet
    input  wire        rd_pop,       // RGET LINE executes: the received byte is consumed
    output wire [31:0] status,
    // pins
    input  wire        dp_in,        // synchronised levels of the two logical pins
    input  wire        dm_in,
    output reg  [2:0]  dp_pin,
    output reg  [2:0]  dm_pin,
    output wire        tx_oe,
    output wire        tx_dp,
    output wire        tx_dm
);
    localparam OP_CFG = 3'd0, OP_PERIOD = 3'd1, OP_TXB = 3'd2, OP_TXE = 3'd3, OP_RXCTL = 3'd4, OP_RESET = 3'd5;

    // ---------------------------------------------------------------- command register
    reg        c_v;
    reg [2:0]  c_op;
    reg [15:0] c_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin c_v <= 1'b0; c_op <= 3'd0; c_d <= 16'd0; end
        else begin
            c_v <= cmd_go;
            if (cmd_go) begin c_op <= cmd_op; c_d <= cmd_data[15:0]; end
        end
    end
    wire c_enq = c_v && (c_op == OP_TXB || c_op == OP_TXE);
    wire c_rst = c_v && (c_op == OP_RESET);
    assign busy = c_v;

    // ---------------------------------------------------------------- configuration
    reg        nrzi, stuff, fs;
    reg [2:0]  slen;
    reg [15:0] period;
    reg        rx_en;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            dp_pin <= 3'd0; dm_pin <= 3'd1; nrzi <= 1'b1; stuff <= 1'b1; slen <= 3'd6; fs <= 1'b0;
            period <= 16'h2155; rx_en <= 1'b0;
        end else if (c_v) begin
            case (c_op)
                OP_CFG: begin
                    dp_pin <= c_d[2:0]; dm_pin <= c_d[5:3]; nrzi <= c_d[6]; stuff <= c_d[7]; slen <= c_d[10:8]; fs <= c_d[11];
                end
                OP_PERIOD: period <= c_d;
                OP_RXCTL:  rx_en <= c_d[0];
                OP_RESET:  rx_en <= 1'b0;
                default: ;
            endcase
        end
    end
    wire jdp = fs;                          // D+ level of the J state

    // ---------------------------------------------------------------- transmit queue (2 entries of {eop, byte})
    reg [8:0] q0, q1;
    reg [1:0] qn;
    reg       tx_pop;
    wire      push = c_enq && (qn != 2'd2 || tx_pop);
    wire [8:0] item = {c_op == OP_TXE, c_d[7:0]};
    assign full = (qn == 2'd2) || (qn == 2'd1 && c_enq);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin q0 <= 9'd0; q1 <= 9'd0; qn <= 2'd0; end
        else if (c_rst) qn <= 2'd0;
        else case ({push, tx_pop})
            2'b10: begin if (qn == 2'd0) q0 <= item; else q1 <= item; qn <= qn + 2'd1; end
            2'b01: begin q0 <= q1; qn <= qn - 2'd1; end
            2'b11: begin if (qn == 2'd1) q0 <= item; else begin q0 <= q1; q1 <= item; end end
            default: ;
        endcase
    end

    // ---------------------------------------------------------------- transmitter
    localparam T_IDLE = 3'd0, T_RUN = 3'd1, T_E0 = 3'd2, T_E1 = 3'd3, T_EJ = 3'd4;
    reg [2:0] tstate;
    reg       oe_r, dp_r, dm_r;
    reg       lvl;                          // 1 = J, 0 = K
    reg [7:0] cur;
    reg [3:0] bits_left;
    reg [2:0] ones;
    reg [7:0] tmr, tacc;
    reg       underrun;
    assign tx_oe = oe_r;
    assign tx_dp = dp_r;
    assign tx_dm = dm_r;

    wire [8:0] tsum = {1'b0, tacc} + {1'b0, period[7:0]};
    wire [7:0] tlen = period[15:8] + {7'd0, tsum[8]};
    wire       tick = (tmr == 8'd0);
    wire       stuff_now = stuff && (ones == slen);
    wire       have_cur  = (bits_left != 4'd0);
    wire       q_data    = (qn != 2'd0) && !q0[8];
    wire       q_eop     = (qn != 2'd0) &&  q0[8];
    wire [7:0] srcb      = have_cur ? cur : q0[7:0];
    wire       ebit      = stuff_now ? 1'b0 : srcb[0];                     // the bit emitted by a data tick
    wire       nlvl      = nrzi ? (ebit ? lvl : ~lvl) : ebit;              // line level after it (1 = J)

    task emit_level(input l);               // drive J / K, restart the bit timer (all nonblocking, used in the always block)
        begin
            lvl  <= l;
            dp_r <= l ? jdp : ~jdp;
            dm_r <= l ? ~jdp : jdp;
        end
    endtask

    always @(*) begin
        tx_pop = 1'b0;
        if (!c_rst) case (tstate)
            T_IDLE: tx_pop = q_eop;
            T_RUN:  if (tick && !stuff_now) tx_pop = (!have_cur && (q_data || q_eop));
            default: ;
        endcase
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate <= T_IDLE; oe_r <= 1'b0; dp_r <= 1'b0; dm_r <= 1'b0; lvl <= 1'b1; cur <= 8'd0; bits_left <= 4'd0;
            ones <= 3'd0; tmr <= 8'd0; tacc <= 8'd0; underrun <= 1'b0;
        end else if (c_rst) begin
            tstate <= T_IDLE; oe_r <= 1'b0; lvl <= 1'b1; bits_left <= 4'd0; ones <= 3'd0; tmr <= 8'd0; underrun <= 1'b0;
        end else begin
            if (c_v && c_op == OP_RXCTL && c_d[1]) underrun <= 1'b0;
            if (tmr != 8'd0) tmr <= tmr - 8'd1;
            case (tstate)
                T_IDLE: begin
                    lvl <= 1'b1; ones <= 3'd0; bits_left <= 4'd0;
                    if (qn != 2'd0) begin
                        if (q0[8]) begin                                   // a bare EOP (keep-alive): SE0 now
                            oe_r <= 1'b1; dp_r <= 1'b0; dm_r <= 1'b0; tstate <= T_E0;
                            tacc <= tsum[7:0]; tmr <= tlen - 8'd1;
                        end else begin
                            tstate <= T_RUN; tmr <= 8'd0;                  // first bit at the next clock
                        end
                    end
                end
                T_RUN: if (tick) begin
                    if (stuff_now || have_cur || q_data) begin
                        oe_r <= 1'b1;
                        emit_level(nlvl);
                        tacc <= tsum[7:0]; tmr <= tlen - 8'd1;
                        if (stuff_now) ones <= 3'd0;
                        else begin
                            cur <= {1'b0, srcb[7:1]};
                            bits_left <= (have_cur ? bits_left : 4'd8) - 4'd1;
                            ones <= srcb[0] ? ((ones == 3'd7) ? ones : ones + 3'd1) : 3'd0;
                        end
                    end else if (q_eop) begin
                        dp_r <= 1'b0; dm_r <= 1'b0; tstate <= T_E0;
                        tacc <= tsum[7:0]; tmr <= tlen - 8'd1;
                    end else
                        underrun <= 1'b1;
                end
                T_E0: if (tick) begin dp_r <= 1'b0; dm_r <= 1'b0; tstate <= T_E1; tacc <= tsum[7:0]; tmr <= tlen - 8'd1; end
                T_E1: if (tick) begin emit_level(1'b1); tstate <= T_EJ; tacc <= tsum[7:0]; tmr <= tlen - 8'd1; end
                T_EJ: if (tick) begin oe_r <= 1'b0; dp_r <= 1'b0; dm_r <= 1'b0; tstate <= T_IDLE; end
                default: tstate <= T_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------- receiver
    localparam R_IDLE = 2'd0, R_SYNC = 2'd1, R_DATA = 2'd2, R_WAIT = 2'd3;
    reg [1:0] rstate;
    reg [1:0] r_prev;
    reg [7:0] rph, racc;
    reg       psym;                         // previous sampled symbol: 1 = J
    reg [2:0] zc, rones, rbits;
    reg [7:0] sh, rx_byte;
    reg       rx_valid, f_eop, f_serr, f_ovr, f_sync;
    reg [2:0] partial;

    wire se0  = ~dp_in & ~dm_in;
    wire se1  =  dp_in &  dm_in;
    wire j_s  = (dp_in == jdp) && (dm_in == ~jdp);
    wire k_s  = (dp_in == ~jdp) && (dm_in == jdp);
    wire redge = ({dp_in, dm_in} != r_prev);
    wire [8:0] rsum = {1'b0, racc} + {1'b0, period[7:0]};
    wire [7:0] rlen = period[15:8] + {7'd0, rsum[8]};
    wire [7:0] half = {1'b0, period[15:9]};
    wire       rtrack = (rstate == R_SYNC) || (rstate == R_DATA);
    wire       sample = rtrack && !redge && (rph == half);
    wire       rbit   = nrzi ? (j_s == psym) : j_s;           // decoded bit of a J / K sample
    wire       r_stuffed = stuff && (rones == slen);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rstate <= R_IDLE; r_prev <= 2'b00; rph <= 8'd0; racc <= 8'd0; psym <= 1'b1; zc <= 3'd0; rones <= 3'd0; rbits <= 3'd0;
            sh <= 8'd0; rx_byte <= 8'd0; rx_valid <= 1'b0; f_eop <= 1'b0; f_serr <= 1'b0; f_ovr <= 1'b0; f_sync <= 1'b0; partial <= 3'd0;
        end else begin
            r_prev <= {dp_in, dm_in};
            if (rd_pop) rx_valid <= 1'b0;
            if (c_v && c_op == OP_RXCTL && c_d[1]) begin f_eop <= 1'b0; f_serr <= 1'b0; f_ovr <= 1'b0; f_sync <= 1'b0; end
            if (c_rst || !rx_en || oe_r) begin
                rstate <= R_IDLE;
                if (c_rst) rx_valid <= 1'b0;
            end else case (rstate)
                R_IDLE: if (k_s) begin rstate <= R_SYNC; rph <= 8'd0; racc <= 8'd0; psym <= 1'b1; zc <= 3'd0; end
                R_SYNC, R_DATA: begin
                    // sampling phase: restart on every transition, wrap at the bit length
                    if (redge) rph <= 8'd0;
                    else if (rph >= rlen - 8'd1) begin rph <= 8'd0; racc <= rsum[7:0]; end
                    else rph <= rph + 8'd1;
                    if (sample) begin
                        if (se0) begin
                            if (rstate == R_DATA) begin f_eop <= 1'b1; partial <= rbits; end
                            rstate <= R_WAIT;
                        end else if (se1) begin
                            f_serr <= 1'b1; rstate <= R_WAIT;
                        end else begin
                            psym <= j_s;
                            if (rstate == R_SYNC) begin
                                if (!rbit) zc <= (zc == 3'd7) ? zc : zc + 3'd1;
                                else if (zc >= 3'd3) begin rstate <= R_DATA; f_sync <= 1'b1; rones <= 3'd1; rbits <= 3'd0; end
                                else rstate <= R_WAIT;                               // not a SYNC
                            end else begin
                                if (r_stuffed) begin
                                    rones <= 3'd0;
                                    if (rbit) begin f_serr <= 1'b1; rstate <= R_WAIT; end   // a stuff bit must be 0
                                end else begin
                                    rones <= rbit ? ((rones == 3'd7) ? rones : rones + 3'd1) : 3'd0;
                                    sh    <= {rbit, sh[7:1]};
                                    rbits <= rbits + 3'd1;
                                    if (rbits == 3'd7) begin
                                        rx_byte <= {rbit, sh[7:1]};
                                        if (rx_valid && !rd_pop) f_ovr <= 1'b1;
                                        rx_valid <= 1'b1;
                                    end
                                end
                            end
                        end
                    end
                end
                R_WAIT: if (j_s) rstate <= R_IDLE;
            endcase
        end
    end

    assign status = {9'd0, rx_en, rstate == R_DATA, underrun, partial, dp_in, dm_in, full, (tstate != T_IDLE) || (qn != 2'd0) || c_enq,
                     f_ovr, f_serr, f_sync, f_eop, rx_valid, rx_byte};
endmodule
