// Programmable CRC unit (Rocksoft model): any width 1..32, any polynomial, input/output reflection, init, final XOR.
//   feed_bit : one bit, in the order given (din[0])
//   feed_byte: 8 bits of din, LSB first when refin=1, MSB first when refin=0
//   rst_crc  : register <- init
//   set_*    : configuration registers, written from cfg_data (set_poly / set_init / set_xor do not touch the CRC register)
//   fmt      : [4:0] width-1, [5] refin, [6] refout. Writing it keeps the register value (cut to the new width if that is smaller).
//   value    : final CRC = (refout ? reflect(register) : register) ^ xorout, masked to the width
// The reset configuration is CRC-32 (ISO-HDLC): poly 04C11DB7, init FFFFFFFF, xorout FFFFFFFF, reflected in and out.
// Oracle: host/crc_model.py (published catalogue check values), tb/tb_crc_unit.v.
//
// Pipelining: every command is registered (cmd_* / q_data / q_din) and executed one clock LATER, in the order given. `value` therefore
// shows a command's effect two edges after the command was presented, and `busy` is 1 in the clock between (a command is waiting).
// The engine stalls RGET CRC while busy, so firmware always reads the up-to-date value; only an RGET CRC directly after a CRC
// instruction costs one extra clock. This takes the instruction fetch, decode and register read out of the path into the 8-step
// chain (the slow-corner critical path before this change: SRAM -> decode -> register read -> 8 CRC steps).
//
// Implementation: the register is kept LEFT ALIGNED (cl = crc << (32 - width), the low 32 - width bits are always 0). A bit step is then
//   cl' = (cl << 1) ^ ((cl[31] ^ bit) ? poly_al : 0)
// with no width mask and no variable top-bit select, so the unrolled 8-bit step is 8 x 32 AND-XOR cells. The polynomial is kept
// pre-aligned (poly_al = poly << (32 - width), recomputed when POLY or FMT is written), so no shifter sits in front of the step chain.
// One left shifter aligns init (RST) or the old register value (FMT, realigned to the new width); one right shifter gives the
// right-aligned register for the output and for that realignment.
module crc_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        rst_crc,
    input  wire        set_poly,
    input  wire        set_init,
    input  wire        set_xor,
    input  wire        set_fmt,
    input  wire [31:0] cfg_data,
    input  wire        feed_bit,
    input  wire        feed_byte,
    input  wire [7:0]  din,
    output wire [31:0] value,
    output wire        busy
);
    // ---- stage 1: command register
    reg        cmd_rst, cmd_poly, cmd_init, cmd_xor, cmd_fmt, cmd_bit, cmd_byte;
    reg [31:0] q_data;
    reg [7:0]  q_din;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            {cmd_rst, cmd_poly, cmd_init, cmd_xor, cmd_fmt, cmd_bit, cmd_byte} <= 7'd0;
            q_data <= 32'd0;
            q_din  <= 8'd0;
        end else begin
            {cmd_rst, cmd_poly, cmd_init, cmd_xor, cmd_fmt, cmd_bit, cmd_byte} <=
                {rst_crc, set_poly, set_init, set_xor, set_fmt, feed_bit, feed_byte};
            q_data <= cfg_data;
            q_din  <= din;
        end
    end
    assign busy = cmd_rst | cmd_poly | cmd_init | cmd_xor | cmd_fmt | cmd_bit | cmd_byte;

    // ---- stage 2: execute
    reg [31:0] cl, poly, poly_al, init, xorout;  // cl: CRC register, left aligned; poly_al: polynomial, left aligned
    reg [4:0]  wm1;                              // width - 1
    reg        refin, refout;

    wire [4:0]  s_cur   = ~wm1;                                  // 32 - width = 31 - wm1
    wire [4:0]  s_new   = cmd_fmt ? ~q_data[4:0] : s_cur;        // alignment after this command
    wire [31:0] mask    = (wm1 == 5'd31) ? 32'hFFFF_FFFF : ((32'd1 << (wm1 + 5'd1)) - 32'd1);
    wire [31:0] cl_r    = cl >> s_cur;                           // right aligned register

    // left shifters (bits above the width fall off the top): init (RST) or the realigned register (FMT); the polynomial (POLY, FMT)
    wire [31:0] lsh     = (cmd_fmt ? cl_r : init) << s_new;
    wire [31:0] psh     = (cmd_poly ? q_data : poly) << s_new;

    function [31:0] step(input [31:0] c, input b, input [31:0] p);
        step = {c[30:0], 1'b0} ^ ((c[31] ^ b) ? p : 32'd0);
    endfunction

    reg [31:0] byte_next;
    integer i;
    always @(*) begin
        byte_next = cl;
        for (i = 0; i < 8; i = i + 1)
            byte_next = step(byte_next, refin ? q_din[i] : q_din[7 - i], poly_al);
    end
    wire [31:0] bit_next = step(cl, q_din[0], poly_al);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cl      <= 32'hFFFF_FFFF;
            poly    <= 32'h04C1_1DB7;
            poly_al <= 32'h04C1_1DB7;
            init    <= 32'hFFFF_FFFF;
            xorout  <= 32'hFFFF_FFFF;
            wm1     <= 5'd31;
            refin   <= 1'b1;
            refout  <= 1'b1;
        end else begin
            if (cmd_poly) poly   <= q_data;
            if (cmd_init) init   <= q_data;
            if (cmd_xor)  xorout <= q_data;
            if (cmd_fmt) begin
                wm1    <= q_data[4:0];
                refin  <= q_data[5];
                refout <= q_data[6];
            end
            if (cmd_poly || cmd_fmt) poly_al <= psh;
            if (cmd_rst || cmd_fmt)  cl <= lsh;
            else if (cmd_byte)       cl <= byte_next;
            else if (cmd_bit)        cl <= bit_next;
        end
    end

    // reflect over the configured width: result bit i = register bit (width-1-i) = cl[31-i]; the bits above the width are 0 by construction
    wire [31:0] refl;
    genvar k;
    generate for (k = 0; k < 32; k = k + 1) begin : g_refl
        assign refl[k] = cl[31 - k];
    end endgenerate
    assign value = ((refout ? refl : cl_r) ^ xorout) & mask;
endmodule
