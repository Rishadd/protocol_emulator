// Management controller, frame v1 (no CRC / sequence yet).
// Frame = exactly 7 bytes while CS_N is low, MSB first, big endian, full duplex:
//   MOSI: byte 0 op (0x01 WRITE, 0x02 READ) | bytes 1-2 address | bytes 3-6 write data
//   MISO: byte 0 STATUS                     | bytes 1-2 0x00    | bytes 3-6 read data (0 for WRITE)
// Writes and FIFO pops commit on the CS_N rising edge of a complete frame, never before,
// so an aborted frame has no effect.
//
// STATUS (sampled while CS_N is high, i.e. at frame start):
//   [7] 1 (alive)  [6] err  [5:4] RUN e1,e0  [3:2] tx_full e1,e0  [1:0] rx has data e1,e0
//
// Address map (architecture doc ยง6 windows), e = engine 0 or 1, base = 0x1000 * (e + 1):
//   base+0x000       CTRL     W: bit 0 RUN (reset 0 = engine held, imem writable)
//                             R: {pc[18:10], cause[4:3], fault[2], halted[1], RUN[0]}  (cause valid when fault=1)
//   base+0x100+4*i   IMEM     W: instruction word i (only while that RUN = 0)
//   base+0x200       TX_DATA  W: word pushed into the engine's TX FIFO (any RUN state, so TX can be
//                             preloaded). Accepted only if this frame's STATUS showed tx_full = 0
//                             for that engine; otherwise dropped (not an error): the host resends.
//   base+0x204       RX_DATA  R: head of the engine's RX FIFO, popped by this read.
//                             Pops only if this frame's STATUS showed data for that engine;
//                             otherwise returns 0 and pops nothing (not an error).
// Pin manager (pin_mgr), p = pad 0..7:
//   0x0200+4*p       PAD      W: data[1:0] owner (0 none, 1 eng0, 2 eng1), data[2] open-drain. Refused
//                             (err) while the pad's owner runs, for owner 3 or nonzero data[31:3].
//                             R: {od, owner[1:0]}
//   0x0220           VIOL     R: {viol1[7:0], viol0[7:0]}  W: data[15:0] = bits to clear (W1C)
// Two-tier memory (L2_EN = 1; docs/TWO_TIER_MEMORY_PLAN.md ง2.9), otherwise these addresses are unmapped:
//   base+0x004       RESET_PC  R/W [8:0] first pc after RUN rises (W only while that engine is held)
//   base+0x008       L2_RANGE  R/W [7:0] lo, [15:8] hi: L2 words the engine may execute/copy; lo > hi = none
//                              (W only while held; reset 0x00FF = empty)
//   base+0x00C       FETCH_CFG R/W [0] prefetch buffer enable, [1] reserved (W only while held; reset 3)
//   0x0300           ARB_CFG   R/W [1:0] L2 arbitration: 0 round-robin, 1 engine 0 first, 2 engine 1 first
//                              (any time; 3 refused)
//   0x0400+4*i       L2        R/W shared L2 word i (i = 0..255). W refused (err) inside the L2_RANGE of a
//                              running engine. R has no side effect; the word is read in the frame.
// Anything else (wrong length, unknown op, unmapped or misaligned address, nonzero
// reserved CTRL bits, instruction write to a running engine) changes nothing and sets err.
module mgmt #(
    parameter L2_EN = 1
)(
    input  wire        clk,
    input  wire        rst_n,
    // spi_slave
    input  wire        byte_valid,
    input  wire [7:0]  rx_byte,
    output wire [7:0]  tx_byte,
    input  wire        active,
    input  wire        frame_end,
    input  wire        frame_clean,
    // engines: per-engine RUN and write enable, shared write address/data
    output reg  [1:0]  eng_run,
    output reg  [1:0]  imem_we,
    output wire [5:0]  imem_waddr,
    output wire [31:0] imem_wdata,
    // engine status and RX FIFOs
    input  wire [1:0]  halted,
    input  wire [1:0]  fault,
    input  wire [8:0]  pc0,
    input  wire [8:0]  pc1,
    input  wire [3:0]  fault_cause,  // {engine 1, engine 0}
    input  wire [1:0]  tx_full,
    input  wire [1:0]  rx_empty,
    input  wire [31:0] rx_data0,
    input  wire [31:0] rx_data1,
    output reg  [1:0]  rx_rd_en,
    output reg  [1:0]  tx_wr_en,
    output wire [31:0] tx_wr_data,
    // pin manager
    output wire [2:0]  pad_sel,
    output wire [2:0]  pad_data,
    input  wire        pad_ok,
    output reg         pad_we,
    output reg  [15:0] viol_clr,
    input  wire [15:0] pad_owner,
    input  wire [7:0]  pad_od,
    input  wire [15:0] pad_viol,
    // two-tier memory configuration and the host port of the shared L2
    output reg  [17:0] reset_pc,     // {engine 1, engine 0}
    output reg  [31:0] l2_range,     // {engine 1 {hi, lo}, engine 0 {hi, lo}}
    output reg  [3:0]  fetch_cfg,    // {engine 1, engine 0}
    output reg  [1:0]  arb_policy,
    output reg         l2_we,        // one-clock strobes to l2_mem (host class: always granted)
    output wire        l2_re,
    output wire [7:0]  l2_addr,
    output wire [31:0] l2_wdata,
    input  wire [31:0] l2_rdata,
    // status
    output reg         err          // sticky, cleared by reset
);
    reg [55:0] frame;
    reg [3:0]  nbytes;              // saturates at 8 = "too many"
    reg [7:0]  status_snap;         // STATUS as sent in byte 0 of this frame
    reg        cap;                 // one cycle after the address is complete
    reg [31:0] rd_word;             // read data, frozen for bytes 3-6
    reg        l2_cap;              // L2 read issued last clock: its word is on l2_rdata now

    wire [7:0]  op   = frame[55:48];
    wire [15:0] addr = frame[47:32];
    wire [31:0] data = frame[31:0];

    wire len_ok   = (nbytes == 4'd7) && frame_clean;
    wire is_write = (op == 8'h01);
    wire is_read  = (op == 8'h02);
    wire eng_ok   = (addr[15:12] == 4'h1) || (addr[15:12] == 4'h2);
    wire eng      = addr[13];       // 0x1xxx -> 0, 0x2xxx -> 1
    wire at_ctrl  = eng_ok && (addr[11:0] == 12'h000);
    wire hit_ctrl = at_ctrl && (data[31:1] == 31'd0);
    wire hit_imem = eng_ok && (addr[11:8] == 4'h1) && (addr[1:0] == 2'b00);
    wire hit_rx   = eng_ok && (addr[11:0] == 12'h204);
    wire hit_tx   = eng_ok && (addr[11:0] == 12'h200);
    wire hit_pad  = (addr[15:5] == 11'h010) && (addr[1:0] == 2'b00);   // 0x0200..0x021C
    wire hit_viol = (addr == 16'h0220);
    wire at_rv    = L2_EN && eng_ok && (addr[11:0] == 12'h004);
    wire at_rng   = L2_EN && eng_ok && (addr[11:0] == 12'h008);
    wire at_fcfg  = L2_EN && eng_ok && (addr[11:0] == 12'h00C);
    wire hit_arb  = L2_EN && (addr == 16'h0300);
    wire hit_l2   = L2_EN && (addr[15:10] == 6'b000001) && (addr[1:0] == 2'b00);   // 0x0400..0x07FC
    // a host write may not change a word a running engine may execute or copy
    wire [7:0] wi = addr[9:2];
    wire l2_prot  = (eng_run[0] && wi >= l2_range[7:0]  && wi <= l2_range[15:8]) ||
                    (eng_run[1] && wi >= l2_range[23:16] && wi <= l2_range[31:24]);

    wire [7:0] status = {1'b1, err, eng_run[1], eng_run[0], tx_full[1], tx_full[0],
                         ~rx_empty[1], ~rx_empty[0]};

    // read mux, evaluated when only op + address are in: they sit in frame[23:0] then
    // (captured into rd_word on the cycle after the third byte)
    wire [7:0]  c_op     = frame[23:16];
    wire [15:0] c_addr   = frame[15:0];
    wire        c_eng_ok = (c_addr[15:12] == 4'h1) || (c_addr[15:12] == 4'h2);
    wire        c_eng    = c_addr[13];
    wire [8:0]  pc_e     = c_eng ? pc1 : pc0;
    wire [31:0] rx_e     = c_eng ? rx_data1 : rx_data0;
    wire [2:0]  c_pad    = c_addr[4:2];
    wire        c_l2     = L2_EN && (c_op == 8'h02) && (c_addr[15:10] == 6'b000001) && (c_addr[1:0] == 2'b00);
    wire [31:0] rd_mux   = (c_op != 8'h02) ? 32'd0 :
                           (c_addr[15:5] == 11'h010 && c_addr[1:0] == 2'b00) ?
                               {29'd0, pad_od[c_pad], pad_owner[2*c_pad +: 2]} :
                           (c_addr == 16'h0220) ? {16'd0, pad_viol} :
                           (L2_EN && c_addr == 16'h0300) ? {30'd0, arb_policy} :
                           !c_eng_ok ? 32'd0 :
                           (c_addr[11:0] == 12'h000) ? {13'd0, pc_e, 5'd0, fault_cause[2*c_eng +: 2], fault[c_eng], halted[c_eng], eng_run[c_eng]} :
                           (c_addr[11:0] == 12'h204) ? (status_snap[c_eng] ? rx_e : 32'd0) :
                           !L2_EN ? 32'd0 :
                           (c_addr[11:0] == 12'h004) ? {23'd0, reset_pc[9*c_eng +: 9]} :
                           (c_addr[11:0] == 12'h008) ? {16'd0, l2_range[16*c_eng +: 16]} :
                           (c_addr[11:0] == 12'h00C) ? {30'd0, fetch_cfg[2*c_eng +: 2]} :
                                                       32'd0;

    // byte to send next = index nbytes
    assign tx_byte = (nbytes == 4'd0) ? status :
                     (nbytes == 4'd3) ? rd_word[31:24] :
                     (nbytes == 4'd4) ? rd_word[23:16] :
                     (nbytes == 4'd5) ? rd_word[15:8]  :
                     (nbytes == 4'd6) ? rd_word[7:0]   : 8'h00;

    // frame holds still after frame_end (the next byte is >= 8 SCLK edges away),
    // so the write port reads it directly instead of copying it into more flops
    assign imem_waddr = addr[7:2];
    assign imem_wdata = data;
    assign tx_wr_data = data;
    assign pad_sel    = addr[4:2];
    assign pad_data   = data[2:0];
    // L2 host port: a write commits after a complete frame (address/data from the frame); a read is
    // issued the clock after the address is in and its word is latched one clock later
    assign l2_re      = cap && c_l2;
    assign l2_addr    = l2_we ? addr[9:2] : c_addr[9:2];
    assign l2_wdata   = data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame       <= 56'd0;
            nbytes      <= 4'd0;
            status_snap <= 8'd0;
            cap         <= 1'b0;
            rd_word     <= 32'd0;
            eng_run     <= 2'b00;
            imem_we     <= 2'b00;
            rx_rd_en    <= 2'b00;
            tx_wr_en    <= 2'b00;
            pad_we      <= 1'b0;
            viol_clr    <= 16'd0;
            err         <= 1'b0;
            l2_cap      <= 1'b0;
            l2_we       <= 1'b0;
            reset_pc    <= 18'd0;
            l2_range    <= 32'h00FF_00FF;
            fetch_cfg   <= 4'hF;
            arb_policy  <= 2'd0;
        end else begin
            l2_we    <= 1'b0;
            l2_cap   <= l2_re;
            imem_we  <= 2'b00;
            rx_rd_en <= 2'b00;
            tx_wr_en <= 2'b00;
            pad_we   <= 1'b0;
            viol_clr <= 16'd0;
            cap      <= byte_valid && (nbytes == 4'd2);
            if (!active) status_snap <= status;     // same edges spi_slave loads byte 0 on
            if (cap) rd_word <= rd_mux;
            if (l2_cap) rd_word <= l2_rdata;
            if (frame_end) begin
                nbytes <= 4'd0;
                if (len_ok && is_write && hit_ctrl)
                    eng_run[eng] <= data[0];
                else if (len_ok && is_write && hit_imem && !eng_run[eng])
                    imem_we[eng] <= 1'b1;
                else if (len_ok && is_read && hit_rx)
                    rx_rd_en[eng] <= status_snap[eng];
                else if (len_ok && is_write && hit_tx)
                    tx_wr_en[eng] <= ~status_snap[2 + eng];
                else if (len_ok && is_write && hit_pad && pad_ok && data[31:3] == 29'd0)
                    pad_we <= 1'b1;
                else if (len_ok && is_write && hit_viol && data[31:16] == 16'd0)
                    viol_clr <= data[15:0];
                else if (len_ok && is_write && at_rv && !eng_run[eng] && data[31:9] == 23'd0)
                    reset_pc[9*eng +: 9] <= data[8:0];
                else if (len_ok && is_write && at_rng && !eng_run[eng] && data[31:16] == 16'd0)
                    l2_range[16*eng +: 16] <= data[15:0];
                else if (len_ok && is_write && at_fcfg && !eng_run[eng] && data[31:2] == 30'd0)
                    fetch_cfg[2*eng +: 2] <= data[1:0];
                else if (len_ok && is_write && hit_arb && data[31:2] == 30'd0 && data[1:0] != 2'd3)
                    arb_policy <= data[1:0];
                else if (len_ok && is_write && hit_l2 && !l2_prot)
                    l2_we <= 1'b1;
                else if (len_ok && is_read && (at_ctrl || hit_pad || hit_viol || at_rv || at_rng || at_fcfg || hit_arb || hit_l2))
                    ;                                   // plain register read, no side effect
                else if (nbytes != 4'd0)                // an empty CS_N pulse is not an error
                    err <= 1'b1;
            end else if (byte_valid) begin
                frame <= {frame[47:0], rx_byte};
                if (nbytes != 4'd8) nbytes <= nbytes + 1'b1;
            end
        end
    end
endmodule
