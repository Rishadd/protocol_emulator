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
// Address map (architecture doc §6 windows), e = engine 0 or 1, base = 0x1000 * (e + 1):
//   base+0x000       CTRL     W: bit 0 RUN (reset 0 = engine held, imem writable)
//                             R: {pc[15:8], fault[2], halted[1], RUN[0]}
//   base+0x400+4*i   IMEM     W: instruction word i, i = 0..255 (only while that RUN = 0)
//                             With SHARED_IMEM: i = 0..511 (up to base+0xBFC), region relative, accepted only inside the engine's region
//                             and, when the regions overlap, only while the other engine is held too (imem_shared.v)
//   base+0x200       TX_DATA  W: word pushed into the engine's TX FIFO (any RUN state, so TX can be
//                             preloaded). Accepted only if this frame's STATUS showed tx_full = 0
//                             for that engine; otherwise dropped (not an error): the host resends.
//   base+0x204       RX_DATA  R: head of the engine's RX FIFO, popped by this read.
//                             Pops only if this frame's STATUS showed data for that engine;
//                             otherwise returns 0 and pops nothing (not an error).
// Pin manager window 0x0200..0x02FF (PAD, VIOL, OPAD, ISEL, MISC, IRQ, INPUTS; register map in pin_mgr.v): a READ of
//   a register pin_mgr knows returns it; a WRITE is applied only if pin_mgr accepts it (pin_ok), otherwise err.
//   Writing 1 to IRQ bit 6 (0x02C4) also clears err.
// With SHARED_IMEM a second window 0x0300..0x03FF holds the instruction-memory regions (register map in imem_shared.v), same rules.
// CTRL read, SHARED_IMEM: bit 16 = pc[8].
// HOLD (pin_mgr: ui_in[3] high while enabled): both RUN bits are cleared and a RUN = 1 write is refused (err).
// Anything else (wrong length, unknown op, unmapped or misaligned address, nonzero
// reserved CTRL bits, instruction write to a running engine) changes nothing and sets err.
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
);
    reg [55:0] frame;
    reg [3:0]  nbytes;              // saturates at 8 = "too many"
    reg [7:0]  status_snap;         // STATUS as sent in byte 0 of this frame
    reg        cap;                 // one cycle after the address is complete
    reg [31:0] rd_word;             // read data, frozen for bytes 3-6

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
`ifdef SHARED_IMEM
    // physical instruction words 0..511 at 0x0400 + 4*w (not engine relative): 0x400..0x7FC and 0x800..0xBFC
    wire hit_imem = (addr[15:12] == 4'h0) && (addr[11] ^ addr[10]) && (addr[1:0] == 2'b00);
    wire imem_range_ok = imem_ok;
`else
    wire hit_imem = eng_ok && (addr[11:10] == 2'b01) && (addr[1:0] == 2'b00);   // 0x400..0x7FC
    wire imem_range_ok = 1'b1;
`endif
    wire hit_rx   = eng_ok && (addr[11:0] == 12'h204);
`ifdef SHARED_IMEM
    wire hit_start = eng_ok && (addr[11:0] == 12'h00C);     // START: writable only while the engine is held
`else
    wire hit_start = 1'b0;
`endif
    wire hit_tx   = eng_ok && (addr[11:0] == 12'h200);
    wire hit_pin  = (addr[15:8] == 8'h02) && (addr[1:0] == 2'b00) && pin_hit;   // 0x0200..0x02FC

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
    wire [31:0] rd_mux   = (c_op != 8'h02) ? 32'd0 :
                           (c_addr[15:8] == 8'h02 && c_addr[1:0] == 2'b00) ? pin_rd :
                           !c_eng_ok ? 32'd0 :
                           (c_addr[11:0] == 12'h000) ? {15'd0, pc_e[8], pc_e[7:0], 5'd0, fault[c_eng], halted[c_eng], eng_run[c_eng]} :
                           (c_addr[11:0] == 12'h204) ? (status_snap[c_eng] ? rx_e : 32'd0) :
`ifdef SHARED_IMEM
                           (c_addr[11:0] == 12'h00C) ? {23'd0, c_eng ? start1 : start0} :
`endif
                                                       32'd0;

    // byte to send next = index nbytes
    assign tx_byte = (nbytes == 4'd0) ? status :
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
    assign pin_ra     = c_addr[7:2];

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
            pin_we      <= 1'b0;
`ifdef SHARED_IMEM
            start0      <= 9'd0;
            start1      <= 9'd0;
`endif
            err         <= 1'b0;
        end else begin
            imem_we  <= 2'b00;
            rx_rd_en <= 2'b00;
            tx_wr_en <= 2'b00;
            pin_we   <= 1'b0;
            cap     <= byte_valid && (nbytes == 4'd2);
            if (!active) status_snap <= status;     // same edges spi_slave loads byte 0 on
            if (cap) rd_word <= rd_mux;
            if (hold) eng_run <= 2'b00;
            if (frame_end) begin
                nbytes <= 4'd0;
                if (len_ok && is_write && hit_ctrl && !(hold && data[0]))
                    eng_run[eng] <= data[0];
`ifdef SHARED_IMEM
                else if (len_ok && is_write && hit_imem && imem_range_ok)
                    imem_we[0] <= 1'b1;             // one write strobe; imem_shared picks the held engine's port
`else
                else if (len_ok && is_write && hit_imem && !eng_run[eng])
                    imem_we[eng] <= 1'b1;
`endif
                else if (len_ok && is_read && hit_rx)
                    rx_rd_en[eng] <= status_snap[eng];
                else if (len_ok && is_write && hit_tx)
                    tx_wr_en[eng] <= ~status_snap[2 + eng];
                else if (len_ok && is_write && hit_pin && pin_ok) begin
                    pin_we <= 1'b1;
                    if (addr[7:0] == 8'hC4 && data[6]) err <= 1'b0;
                end
`ifdef SHARED_IMEM
                else if (len_ok && is_write && hit_start && !eng_run[eng] && data[31:9] == 23'd0) begin
                    if (eng) start1 <= data[8:0]; else start0 <= data[8:0];
                end
`endif
                else if (len_ok && is_read && (at_ctrl || hit_pin || hit_start))
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
