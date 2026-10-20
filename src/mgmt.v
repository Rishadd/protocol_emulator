// Management controller: frame v1 (7 bytes, simple) and frame v2 (12 bytes, CRC-16, sequence numbers, pipelined results).
// SPI mode 0, MSB first, full duplex, CS_N low for the whole frame. The frame type is chosen by bit 7 of the first byte (op).
//
// ---- v1 (docs/HOST_INTERFACE.md): big endian
//   MOSI: byte 0 op (0x01 WRITE, 0x02 READ) | bytes 1-2 address | bytes 3-6 write data
//   MISO: byte 0 STATUS                     | bytes 1-2 0x00    | bytes 3-6 read data (0 for WRITE)
//   Writes and FIFO pops commit on the CS_N rising edge of a complete 7-byte frame, never before.
//
// ---- v2: little endian fields, 12 bytes, CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no final XOR, high byte first)
//   MOSI: [0] op (0x80 NOP, 0x81 WRITE, 0x82 READ) [1] seq [2:3] address [4:7] payload [8:9] reserved (0) [10:11] CRC over bytes 0..9
//   MISO: [0] STATUS [1] seq of the last accepted command [2] seq of the result [3] result code [4:5] address of the result
//         [6:9] result data [10:11] CRC over bytes 0..9
//   The result in a frame is that of the previous ACCEPTED command (pipelined): a READ's data comes back in the next frame (any frame, a NOP
//   will do), so a response never depends on a request that has not been checked yet. A frame is accepted only if it has exactly 12 clean
//   bytes and its CRC is right; otherwise nothing happens (counted in ERRCNT, sticky err set).
//   NOP (0x80) changes nothing (it only fetches the result). A new WRITE / READ replaces the result; the one it replaces is what this frame
//   shows. RETRY: a frame whose seq equals the last accepted command's seq shows that same older result again (so a corrupted response is
//   recoverable by sending the identical frame again); with the same CRC it is a duplicate and is not executed again (exactly once); with
//   another CRC it is refused (counted, sticky err). The first frame after reset is never a duplicate. COMMANDS ARE IN ORDER: a new
//   WRITE / READ is accepted only if its seq is the last accepted command's seq + 1 (any seq as the first one after reset); a gap means a
//   frame was lost, the command is refused (counted, sticky err) so that a later command can never overtake it. NOPs use a seq that differs
//   from the last command's (the next one will do) and take no part in the numbering.
//   Result code: 0 OK, 1 BUSY (TX FIFO full / RX FIFO empty: nothing done), 2 bad address, 3 bad value / reserved bytes nonzero,
//   4 not allowed (instruction write to a running engine, pin claim refused, RUN while HOLD, read-only register), 6 bad op.
//
// STATUS (the state when CS_N fell): [7] 1 (alive)  [6] err  [5:4] RUN e1,e0  [3:2] tx_full e1,e0  [1:0] rx has data e1,e0
// v1: TX push accepted only if STATUS showed tx_full = 0, RX pop pops only if STATUS showed data; v2: decided at commit from the live state
// and reported in the result code.
//
// Address map (e = engine 0 or 1, base = 0x1000 * (e + 1)):
//   0x0000 ID (R) 'PEM1'   0x0004 VERSION (R)   0x0008 CAPABILITY (R)   0x000C SCRATCH (RW, 32 bits)
//   0x0010 ERRCNT (R) {sequence errors (conflicts and gaps)[23:16], length errors[15:8], CRC errors[7:0]}, saturating; any write clears all three
//   base+0x000       CTRL     W: bit 0 RUN (reset 0 = engine held, imem writable)
//                             R: {pc[15:8], fault[2], halted[1], RUN[0]}
//   base+0x400+4*i   IMEM     W: instruction word i, i = 0..255 (only while that RUN = 0)
//                             With SHARED_IMEM: physical words w = 0..511 at 0x0400 + 4*w (not engine relative), accepted when a held engine's port is free
//                             and no running engine's window holds w (imem_shared.v). base+0x00C START (RW while held): program counter reset value.
//                             CTRL read, SHARED_IMEM: bit 16 = pc[8].
//   base+0x200       TX_DATA  W: word pushed into the engine's TX FIFO (any RUN state, so TX can be preloaded)
//   base+0x204       RX_DATA  R: head of the engine's RX FIFO, popped by this read
// Pin manager window 0x0200..0x02FF (register map in pin_mgr.v). Writing 1 to IRQ bit 6 (0x02C4) also clears err.
// HOLD (pin_mgr: ui_in[3] high while enabled): both RUN bits are cleared and a RUN = 1 write is refused.
// v1: anything else (wrong length, unknown op, unmapped or misaligned address, nonzero reserved CTRL bits, instruction write to a running
// engine) changes nothing and sets err.
module mgmt (
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
    output wire [8:0]  imem_waddr,
    output wire [31:0] imem_wdata,
`ifdef SHARED_IMEM
    input  wire        imem_ok,         // imem_shared: a held engine's port is free and no running window holds that word
    output reg  [8:0]  start0, start1,  // START register per engine (program counter reset value), written only while held
`endif
    // engine status and RX FIFOs
    input  wire [1:0]  halted,
    input  wire [1:0]  fault,
    input  wire [8:0]  pc0,
    input  wire [8:0]  pc1,
    input  wire [1:0]  tx_full,
    input  wire [1:0]  rx_empty,
    input  wire [31:0] rx_data0,
    input  wire [31:0] rx_data1,
    output reg  [1:0]  rx_rd_en,
    output reg  [1:0]  tx_wr_en,
    output wire [31:0] tx_wr_data,
    // pin manager register window
    output wire [5:0]  pin_wa,
    output wire [31:0] pin_wd,
    input  wire        pin_hit,
    input  wire        pin_ok,
    output reg         pin_we,
    output wire [5:0]  pin_ra,
    input  wire [31:0] pin_rd,
    input  wire        hold,
    // status
    output reg         err          // sticky, cleared by reset or IRQ bit 6 write-one-to-clear
`ifdef FORMAL
    ,
    output wire [3:0]  f_nbytes,    // internals the proof relates to its own independent counters (formal/mgmt_props.sv); not on the chip
    output wire        f_is_v2,
    output wire [15:0] f_rxcrc,
    output wire [15:0] f_low16
`endif
);
    localparam [15:0] CRC_INIT = 16'hFFFF;

    // CRC-16/CCITT-FALSE, one byte per clock (a byte lasts >= 64 system clocks on the link)
    function [15:0] crc16;
        input [15:0] c;
        input [7:0]  d;
        reg   [15:0] x;
        integer      i;
        begin
            x = c ^ {d, 8'h00};
            for (i = 0; i < 8; i = i + 1) x = x[15] ? ((x << 1) ^ 16'h1021) : (x << 1);
            crc16 = x;
        end
    endfunction

    reg [95:0] frame;               // the last 12 bytes received, newest in the low bits
    reg [3:0]  nbytes;              // saturates at 13 = "too many"
    reg        is_v2;               // first byte of this frame had bit 7 set
    reg [7:0]  status_snap;         // STATUS as sent in byte 0 of this frame
    reg        cap;                 // v1: one cycle after the address is complete
    reg [31:0] rd_word;             // v1: read data, frozen for bytes 3-6
    reg [15:0] rxcrc, txcrc;
    // v2 result of the last accepted command, duplicate cache, registers
    reg [7:0]  res_seq, res_code, old_seq, old_code;     // latest result, and the one the last accepted command was shown
    reg [15:0] res_addr, old_addr;
    reg [31:0] res_data, old_data;
    reg        show_old;                                  // this frame's seq equals the last accepted command's: show the older result
    wire [7:0] last_seq = res_seq;                            // the last accepted command's seq is the latest result's seq
    reg [15:0] last_crc;
    reg        have_last;
    reg [31:0] scratch;
    reg [7:0]  cnt_crc, cnt_len, cnt_seq;

`ifdef FORMAL
    assign f_nbytes = nbytes;
    assign f_is_v2  = is_v2;
    assign f_rxcrc  = rxcrc;
    assign f_low16  = frame[15:0];
`endif

    // ------------------------------------------------------------------ the command, in whichever frame it came
    wire [7:0]  op1   = frame[55:48];
    wire [15:0] addr1 = frame[47:32];
    wire [31:0] data1 = frame[31:0];
    wire [7:0]  op2   = frame[95:88];
    wire [7:0]  seq2  = frame[87:80];
    wire [15:0] addr2 = {frame[71:64], frame[79:72]};
    wire [31:0] data2 = {frame[39:32], frame[47:40], frame[55:48], frame[63:56]};
    wire [15:0] rcrc  = frame[15:0];

    wire v1_ok    = !is_v2 && (nbytes == 4'd7) && frame_clean;
    wire v2_ok    = is_v2 && (nbytes == 4'd12) && frame_clean && (rxcrc == rcrc);
    wire dup      = v2_ok && have_last && (seq2 == last_seq) && (rcrc == last_crc);
    wire conflict = v2_ok && have_last && (seq2 == last_seq) && (rcrc != last_crc);
    wire rsv_ok   = (frame[31:16] == 16'd0);
    wire op2_ok   = (op2 == 8'h80) || (op2 == 8'h81) || (op2 == 8'h82);
    wire gap      = v2_ok && have_last && (op2 != 8'h80) && (seq2 != last_seq) && (seq2 != last_seq + 8'd1);
    wire go       = is_v2 ? (v2_ok && !dup && !conflict && !gap && rsv_ok && op2_ok) : v1_ok;
    wire is_write = is_v2 ? (op2 == 8'h81) : (op1 == 8'h01);
    wire is_read  = is_v2 ? (op2 == 8'h82) : (op1 == 8'h02);
    wire [15:0] addr = is_v2 ? addr2 : addr1;
    wire [31:0] data = is_v2 ? data2 : data1;

    wire eng_ok   = (addr[15:12] == 4'h1) || (addr[15:12] == 4'h2);
    wire eng      = addr[13];       // 0x1xxx -> 0, 0x2xxx -> 1
    wire at_ctrl  = eng_ok && (addr[11:0] == 12'h000);
    wire hit_ctrl = at_ctrl && (data[31:1] == 31'd0);
`ifdef SHARED_IMEM
    // physical instruction words 0..511 at 0x0400 + 4*w (not engine relative): 0x400..0x7FC and 0x800..0xBFC
    wire hit_imem = (addr[15:12] == 4'h0) && (addr[11] ^ addr[10]) && (addr[1:0] == 2'b00);
    wire imem_wr_ok = imem_ok;                                                  // a held engine's port is free, no running window holds the word
    wire hit_start = eng_ok && (addr[11:0] == 12'h00C);                          // START: writable only while the engine is held
`else
    wire hit_imem = eng_ok && (addr[11:10] == 2'b01) && (addr[1:0] == 2'b00);   // 0x400..0x7FC
    wire imem_wr_ok = !eng_run[eng];
    wire hit_start = 1'b0;
`endif
    wire hit_rx   = eng_ok && (addr[11:0] == 12'h204);
    wire hit_tx   = eng_ok && (addr[11:0] == 12'h200);
    wire hit_pin  = (addr[15:8] == 8'h02) && (addr[1:0] == 2'b00) && pin_hit;   // 0x0200..0x02FC
    wire id_win   = (addr[15:5] == 11'd0) && (addr[1:0] == 2'b00);              // 0x0000..0x001C
    wire hit_scr  = id_win && (addr[4:2] == 3'd3);
    wire hit_cnt  = id_win && (addr[4:2] == 3'd4);
    wire hit_idr  = id_win && (addr[4:2] <= 3'd4);                              // readable ID-window registers
    wire tx_ok    = is_v2 ? ~tx_full[eng]  : ~status_snap[2 + eng];            // v1: flow control from the STATUS the host saw
    wire rx_ok    = is_v2 ? ~rx_empty[eng] :  status_snap[eng];

    wire [7:0] status = {1'b1, err, eng_run[1], eng_run[0], tx_full[1], tx_full[0],
                         ~rx_empty[1], ~rx_empty[0]};

    // ------------------------------------------------------------------ read mux: v1 at the cycle after the address, v2 at the commit
    wire [7:0]  c_op     = frame[23:16];
    wire [15:0] c_addr   = frame[15:0];
    wire [15:0] ra       = is_v2 ? addr2 : c_addr;
    wire        r_eng_ok = (ra[15:12] == 4'h1) || (ra[15:12] == 4'h2);
    wire        r_eng    = ra[13];
    wire        r_rx_ok  = is_v2 ? ~rx_empty[r_eng] : status_snap[r_eng];
    wire [8:0]  pc_e     = r_eng ? pc1 : pc0;
    wire [31:0] rx_e     = r_eng ? rx_data1 : rx_data0;
    reg  [31:0] rd_id;
    always @(*) begin
        case (ra[4:2])
            3'd0:    rd_id = 32'h5045_4D31;                                     // 'PEM1'
            3'd1:    rd_id = 32'h0000_0201;                                     // [15:8] frame versions up to 2, [7:0] ISA/ABI 1
`ifdef SHARED_IMEM
            3'd2:    rd_id = 32'h4002_0002;                                     // [7:0] engines, [23:8] instruction words (0x0200 = 512, shared), [31:28] FIFO depth 4
`else
            3'd2:    rd_id = 32'h4001_0002;                                     // [7:0] engines, [23:8] instruction words (0x0100 = 256), [31:28] FIFO depth 4
`endif
            3'd3:    rd_id = scratch;
            default: rd_id = {8'd0, cnt_seq, cnt_len, cnt_crc};
        endcase
    end
    wire [31:0] rd_val   = (ra[15:5] == 11'd0 && ra[1:0] == 2'b00 && ra[4:2] <= 3'd4) ? rd_id :
                           (ra[15:8] == 8'h02 && ra[1:0] == 2'b00) ? pin_rd :
                           !r_eng_ok ? 32'd0 :
                           (ra[11:0] == 12'h000) ? {15'd0, pc_e, 5'd0, fault[r_eng], halted[r_eng], eng_run[r_eng]} :   // bit 16 = pc[8] (SHARED_IMEM)
                           (ra[11:0] == 12'h204) ? (r_rx_ok ? rx_e : 32'd0) :
`ifdef SHARED_IMEM
                           (ra[11:0] == 12'h00C) ? {23'd0, r_eng ? start1 : start0} :
`endif
                                                   32'd0;
    wire [31:0] rd_mux   = (c_op != 8'h02) ? 32'd0 : rd_val;                    // v1

    // v2 result code of this command
    reg [7:0] code;
    always @(*) begin
        code = 8'd0;
        if (!op2_ok)                    code = 8'd6;
        else if (!rsv_ok)               code = 8'd3;
        else if (op2 == 8'h81) begin    // WRITE
            if (at_ctrl)                code = (data[31:1] != 31'd0) ? 8'd3 : (hold && data[0]) ? 8'd4 : 8'd0;
            else if (hit_imem)          code = imem_wr_ok ? 8'd0 : 8'd4;
            else if (hit_start)         code = (data[31:9] != 23'd0) ? 8'd3 : eng_run[eng] ? 8'd4 : 8'd0;
            else if (hit_tx)            code = tx_full[eng] ? 8'd1 : 8'd0;
            else if (hit_pin)           code = pin_ok ? 8'd0 : 8'd4;
            else if (hit_scr || hit_cnt) code = 8'd0;
            else if (id_win)            code = 8'd4;                            // ID, VERSION, CAPABILITY are read-only
            else                        code = 8'd2;
        end else if (op2 == 8'h82) begin // READ
            if (hit_rx)                 code = rx_empty[eng] ? 8'd1 : 8'd0;
            else if (at_ctrl || hit_pin || hit_idr || hit_start) code = 8'd0;
            else                        code = 8'd2;
        end
    end

    // ------------------------------------------------------------------ MISO
    wire [7:0]  sh_seq  = show_old ? old_seq  : res_seq;
    wire [7:0]  sh_code = show_old ? old_code : res_code;
    wire [15:0] sh_addr = show_old ? old_addr : res_addr;
    wire [31:0] sh_data = show_old ? old_data : res_data;
    wire [7:0] tx_v2 = (nbytes == 4'd1)  ? last_seq :                // does not depend on this frame's seq (byte 1 is still arriving)
                       (nbytes == 4'd2)  ? sh_seq :
                       (nbytes == 4'd3)  ? sh_code :
                       (nbytes == 4'd4)  ? sh_addr[7:0] :
                       (nbytes == 4'd5)  ? sh_addr[15:8] :
                       (nbytes == 4'd6)  ? sh_data[7:0] :
                       (nbytes == 4'd7)  ? sh_data[15:8] :
                       (nbytes == 4'd8)  ? sh_data[23:16] :
                       (nbytes == 4'd9)  ? sh_data[31:24] :
                       (nbytes == 4'd10) ? txcrc[15:8] :
                       (nbytes == 4'd11) ? txcrc[7:0] : 8'h00;
    // Byte 0 must be the sample the snapshot takes on the same edge: spi_slave reloads its shift register from tx_byte every clock while CS_N is high,
    // so sending status_snap here would show the host a STATUS one clock older than the one the v1 accept decision (tx_ok / rx_ok) uses
    assign tx_byte = (nbytes == 4'd0) ? (active ? status_snap : status) :
                     is_v2            ? tx_v2 :
                     (nbytes == 4'd3) ? rd_word[31:24] :
                     (nbytes == 4'd4) ? rd_word[23:16] :
                     (nbytes == 4'd5) ? rd_word[15:8]  :
                     (nbytes == 4'd6) ? rd_word[7:0]   : 8'h00;

    // frame holds still after frame_end (the next byte is >= 8 SCLK edges away),
    // so the write port reads it directly instead of copying it into more flops
`ifdef SHARED_IMEM
    assign imem_waddr = {addr[11], addr[9:2]};       // physical word: 0x400..0x7FC -> 0..255, 0x800..0xBFC -> 256..511
`else
    assign imem_waddr = {1'b0, addr[9:2]};
`endif
    assign imem_wdata = data;
    assign tx_wr_data = data;
    assign pin_wa     = addr[7:2];
    assign pin_wd     = data;
    assign pin_ra     = ra[7:2];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            frame       <= 96'd0;
            nbytes      <= 4'd0;
            is_v2       <= 1'b0;
            status_snap <= 8'd0;
            cap         <= 1'b0;
            rd_word     <= 32'd0;
            rxcrc       <= CRC_INIT;
            txcrc       <= CRC_INIT;
            res_seq     <= 8'd0;
            res_code    <= 8'd0;
            res_addr    <= 16'd0;
            res_data    <= 32'd0;
            old_seq     <= 8'd0;
            old_code    <= 8'd0;
            old_addr    <= 16'd0;
            old_data    <= 32'd0;
            show_old    <= 1'b0;
            last_crc    <= 16'd0;
            have_last   <= 1'b0;
            scratch     <= 32'd0;
            cnt_crc     <= 8'd0;
            cnt_len     <= 8'd0;
            cnt_seq     <= 8'd0;
            eng_run     <= 2'b00;
            imem_we     <= 2'b00;
`ifdef SHARED_IMEM
            start0      <= 9'd0;
            start1      <= 9'd0;
`endif
            rx_rd_en    <= 2'b00;
            tx_wr_en    <= 2'b00;
            pin_we      <= 1'b0;
            err         <= 1'b0;
        end else begin
            imem_we  <= 2'b00;
            rx_rd_en <= 2'b00;
            tx_wr_en <= 2'b00;
            pin_we   <= 1'b0;
            cap      <= byte_valid && (nbytes == 4'd2);
            if (!active) begin
                status_snap <= status;      // same edges spi_slave loads byte 0 on
                rxcrc       <= CRC_INIT;
                txcrc       <= CRC_INIT;
            end
            if (cap && !is_v2) rd_word <= rd_mux;
            if (hold) eng_run <= 2'b00;
            if (frame_end) begin
                nbytes <= 4'd0;
                if (go && is_write && hit_ctrl && !(hold && data[0]))
                    eng_run[eng] <= data[0];
`ifdef SHARED_IMEM
                else if (go && is_write && hit_imem && imem_wr_ok)
                    imem_we[0] <= 1'b1;             // one write strobe; imem_shared picks the held engine's port
                else if (go && is_write && hit_start && !eng_run[eng] && data[31:9] == 23'd0) begin
                    if (eng) start1 <= data[8:0]; else start0 <= data[8:0];
                end
`else
                else if (go && is_write && hit_imem && imem_wr_ok)
                    imem_we[eng] <= 1'b1;
`endif
                else if (go && is_read && hit_rx)
                    rx_rd_en[eng] <= rx_ok;
                else if (go && is_write && hit_tx)
                    tx_wr_en[eng] <= tx_ok;
                else if (go && is_write && hit_pin && pin_ok) begin
                    pin_we <= 1'b1;
                    if (addr[7:0] == 8'hC4 && data[6]) err <= 1'b0;
                end
                else if (go && is_write && hit_scr)
                    scratch <= data;
                else if (go && is_write && hit_cnt) begin
                    cnt_crc <= 8'd0; cnt_len <= 8'd0; cnt_seq <= 8'd0;
                end
                else if (go && is_read && (at_ctrl || hit_pin || hit_idr || hit_start))
                    ;                                   // plain register read, no side effect
                else if (go && !is_v2)                  // v1: a rejected access
                    err <= 1'b1;
                else if (!is_v2 && nbytes != 4'd0)      // v1: bad length / partial byte (an empty CS_N pulse is not an error)
                    err <= 1'b1;
                // ---- v2 bookkeeping
                if (is_v2 && nbytes != 4'd0) begin
                    if (v2_ok) begin
                        if (op2 == 8'h80) begin
                            ;                                    // NOP: fetches the result, changes nothing
                        end else if (dup) begin
                            ;                                    // a retry: not executed again, the result it was shown stays reproducible
                        end else if (conflict || gap) begin
                            err <= 1'b1;                         // same seq with another frame, or a gap in the numbering: refused
                            if (cnt_seq != 8'hFF) cnt_seq <= cnt_seq + 8'd1;
                        end else begin
                            old_seq <= res_seq; old_code <= res_code; old_addr <= res_addr; old_data <= res_data;
                            res_seq <= seq2; res_addr <= addr2; res_code <= code;
                            res_data <= (go && is_read && code == 8'd0) ? rd_val : 32'd0;
                            last_crc <= rcrc; have_last <= 1'b1;
                        end
                    end else begin                       // damaged frame: nothing executes, the host sees the old result
                        err <= 1'b1;
                        if (nbytes == 4'd12 && frame_clean) begin
                            if (cnt_crc != 8'hFF) cnt_crc <= cnt_crc + 8'd1;
                        end else begin
                            if (cnt_len != 8'hFF) cnt_len <= cnt_len + 8'd1;
                        end
                    end
                end
            end else if (byte_valid) begin
                frame <= {frame[87:0], rx_byte};
                if (nbytes != 4'd13) nbytes <= nbytes + 1'b1;
                if (nbytes == 4'd0) is_v2 <= rx_byte[7];
                if (nbytes == 4'd1) show_old <= have_last && (rx_byte == last_seq);
                if (nbytes < 4'd10) begin
                    rxcrc <= crc16(rxcrc, rx_byte);
                    txcrc <= crc16(txcrc, tx_byte);     // the byte just sent to the host
                end
            end
        end
    end
endmodule
