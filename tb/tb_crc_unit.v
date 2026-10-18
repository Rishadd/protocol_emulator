`timescale 1ns/1ps
`include "tb_common.vh"
// crc_unit against (A) published catalogue check values for "123456789", (B) bit-by-bit feeding, (C) an independent reference
// that does NOT use the shift-register algorithm: GF(2) polynomial division of the whole bit stream
//     R(M, init) = (M * x^W  xor  init * x^|M|)  mod  (x^W + poly)
// (linearity of the direct algorithm), (D) random widths/polynomials/flags/messages, (E) configuration rules, (G) the command
// pipeline (a command executes one clock after it is presented; busy in between; commands back to back keep their order).
// Commands are presented back to back everywhere (as an engine does); `settle` gives the last command its execution clock
// before `value` is checked.
// Optional: +VEC=<file> reads vectors made by host/crc_test.py (one per line: width poly init refin refout xorout nbytes bytes...).
module tb_crc_unit;
    reg         clk = 0, rst_n = 0;
    reg         rst_crc = 0, set_poly = 0, set_init = 0, set_xor = 0, set_fmt = 0, feed_bit = 0, feed_byte = 0;
    reg  [31:0] cfg_data = 0;
    reg  [7:0]  din = 0;
    wire [31:0] value;
    wire        busy;
    integer errors = 0, i, j, n, t;

    crc_unit dut (.clk(clk), .rst_n(rst_n), .rst_crc(rst_crc), .set_poly(set_poly), .set_init(set_init),
                  .set_xor(set_xor), .set_fmt(set_fmt), .cfg_data(cfg_data), .feed_bit(feed_bit),
                  .feed_byte(feed_byte), .din(din), .value(value), .busy(busy));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask
    task settle; begin tick; end endtask     // one idle clock: the last command executes

    // ---- driver tasks
    task cfg(input integer w, input [31:0] poly, input [31:0] init, input refin, input refout, input [31:0] xo);
        begin
            cfg_data = poly; set_poly = 1; tick; set_poly = 0;
            cfg_data = init; set_init = 1; tick; set_init = 0;
            cfg_data = xo;   set_xor = 1;  tick; set_xor = 0;
            cfg_data = (w - 1) | (refin << 5) | (refout << 6); set_fmt = 1; tick; set_fmt = 0;
            rst_crc = 1; tick; rst_crc = 0;
        end
    endtask
    task put_byte(input [7:0] b); begin din = b; feed_byte = 1; tick; feed_byte = 0; end endtask
    task put_bit(input b);        begin din = {7'd0, b}; feed_bit = 1; tick; feed_bit = 0; end endtask

    // ---- (C) independent reference: polynomial division on long bit vectors
    reg [511:0] stream;         // stream[i] = i-th fed bit (i = 0 first)
    integer     slen;
    reg [511:0] poly_work;
    function [31:0] pmod(input integer W, input [31:0] poly, input integer total, input [511:0] bits_msb_first);
        // bits_msb_first[total-1] is the highest-degree coefficient. Returns remainder mod (x^W + poly).
        reg [511:0] r;
        integer d;
        reg [32:0] g;
        begin
            r = bits_msb_first;
            g = {1'b1, poly} & ((33'd1 << (W + 1)) - 1);   // x^W + poly(W bits)
            g[W] = 1'b1;
            for (d = total - 1; d >= W; d = d - 1)
                if (r[d]) r = r ^ ({479'd0, g} << (d - W));
            pmod = r[31:0] & ((W == 32) ? 32'hFFFF_FFFF : ((32'd1 << W) - 1));
        end
    endfunction
    function [31:0] refl(input integer W, input [31:0] v);
        integer q;
        begin refl = 0; for (q = 0; q < W; q = q + 1) refl[q] = v[W - 1 - q]; end
    endfunction
    // expected final value for the bits currently in stream[0..slen-1]
    function [31:0] ref_final(input integer W, input [31:0] poly, input [31:0] init, input ro, input [31:0] xo);
        reg [511:0] m, a, ib;
        reg [31:0]  r1, r2, r, mk;
        integer q;
        begin
            mk = (W == 32) ? 32'hFFFF_FFFF : ((32'd1 << W) - 1);
            // term 1: M * x^W  (M first bit = highest degree), then mod
            m = 0;
            for (q = 0; q < slen; q = q + 1) m[slen - 1 - q + W] = stream[q];
            r1 = pmod(W, poly, slen + W, m);
            // term 2: init * x^|M| mod G
            ib = 0;
            for (q = 0; q < W; q = q + 1) ib[q + slen] = init[q] & mk[q];
            r2 = pmod(W, poly, slen + W, ib);
            r = r1 ^ r2;
            ref_final = ((ro ? refl(W, r) : r) ^ xo) & mk;
        end
    endfunction

    // ---- feed a byte into both the DUT and the reference stream
    task send_byte(input refin, input [7:0] b);
        integer q;
        begin
            put_byte(b);
            for (q = 0; q < 8; q = q + 1) begin
                stream[slen] = refin ? b[q] : b[7 - q];
                slen = slen + 1;
            end
        end
    endtask
    task send_bit(input b); begin put_bit(b); stream[slen] = b; slen = slen + 1; end endtask

    // ---- (A) catalogue
    task cat(input [8*20-1:0] name, input integer w, input [31:0] poly, input [31:0] init, input refin,
             input refout, input [31:0] xo, input [31:0] check);
        integer q;
        reg [7:0] ch;
        begin
            cfg(w, poly, init, refin, refout, xo);
            for (q = 0; q < 9; q = q + 1) put_byte("1" + q);
            settle;
            `CHECK(value === check, {"A catalogue byte feed: ", name})
            if (value !== check) $display("    %0s: got %h want %h", name, value, check);
            // same message, bit by bit in the model's bit order
            rst_crc = 1; tick; rst_crc = 0;
            for (q = 0; q < 9; q = q + 1) begin
                ch = "1" + q;
                for (j = 0; j < 8; j = j + 1) put_bit(refin ? ch[j] : ch[7 - j]);
            end
            settle;
            `CHECK(value === check, {"B catalogue bit feed: ", name})
        end
    endtask

    reg [31:0] rnd = 32'h1234_5678;
    function [31:0] next_rnd(input [31:0] s); begin next_rnd = s * 32'd1664525 + 32'd1013904223; end endfunction

    reg [8*256-1:0] vec_file;
    integer W, nb;
    reg [31:0] rawp, rawi, rawx;
    reg [31:0] poly, init, xo, mk, got, exp;
    reg ri, ro;
    integer fd, rc;
    integer vw, vnb;
    reg [31:0] vp, vi, vxo, vcheck;
    integer vri, vro;
    reg [7:0] vb;

    initial begin
        tick; tick; rst_n = 1; tick;

        // ---- E1: reset configuration is CRC-32 (ISO-HDLC)
        for (i = 0; i < 9; i = i + 1) put_byte("1" + i);
        settle;
        `CHECK(value === 32'hCBF4_3926, "E1 reset config = CRC-32, register = init at reset")

        // ---- E1b: no configuration at all: RST then message gives CRC-32 (init register default)
        rst_crc = 1; tick; rst_crc = 0;
        for (i = 0; i < 9; i = i + 1) put_byte("1" + i);
        settle;
        `CHECK(value === 32'hCBF4_3926, "E1b reset defaults: RST loads init FFFFFFFF")

        // ---- A/B catalogue
        cat("CRC-4/G-704",       4,  32'h3,         32'h0,         1, 1, 32'h0,         32'h7);
        cat("CRC-5/USB",         5,  32'h05,        32'h1F,        1, 1, 32'h1F,        32'h19);
        cat("CRC-7/MMC",         7,  32'h09,        32'h00,        0, 0, 32'h00,        32'h75);
        cat("CRC-8/SMBUS",       8,  32'h07,        32'h00,        0, 0, 32'h00,        32'hF4);
        cat("CRC-8/MAXIM-DOW",   8,  32'h31,        32'h00,        1, 1, 32'h00,        32'hA1);
        cat("CRC-15/CAN",        15, 32'h4599,      32'h0000,      0, 0, 32'h0000,      32'h059E);
        cat("CRC-16/MODBUS",     16, 32'h8005,      32'hFFFF,      1, 1, 32'h0000,      32'h4B37);
        cat("CRC-16/USB",        16, 32'h8005,      32'hFFFF,      1, 1, 32'hFFFF,      32'hB4C8);
        cat("CRC-16/CCITT-FALSE",16, 32'h1021,      32'hFFFF,      0, 0, 32'h0000,      32'h29B1);
        cat("CRC-16/XMODEM",     16, 32'h1021,      32'h0000,      0, 0, 32'h0000,      32'h31C3);
        cat("CRC-16/KERMIT",     16, 32'h1021,      32'h0000,      1, 1, 32'h0000,      32'h2189);
        cat("CRC-32/ISO-HDLC",   32, 32'h04C11DB7,  32'hFFFFFFFF,  1, 1, 32'hFFFFFFFF,  32'hCBF43926);
        cat("CRC-32C",           32, 32'h1EDC6F41,  32'hFFFFFFFF,  1, 1, 32'hFFFFFFFF,  32'hE3069283);
        cat("CRC-32/MPEG-2",     32, 32'h04C11DB7,  32'hFFFFFFFF,  0, 0, 32'h00000000,  32'h0376E6E7);

        // ---- E2: configuration writes do not disturb the register; RST loads init (masked to the width)
        cfg(16, 32'h1021, 32'hFFFF, 0, 0, 32'h0);
        put_byte(8'h41);
        settle;
        got = value;
        cfg_data = 32'h0000_00FF; set_poly = 1; tick; set_poly = 0;
        cfg_data = 32'h1234_5678; set_xor = 1;  tick; set_xor = 0;
        cfg_data = 32'hFFFF;      set_poly = 0; set_init = 1; tick; set_init = 0;
        cfg_data = 32'h1021;      set_poly = 1; tick; set_poly = 0;
        cfg_data = 32'h0;         set_xor = 1;  tick; set_xor = 0;
        settle;
        `CHECK(value === got, "E2 set_poly/set_init/set_xor leave the CRC register alone")
        rst_crc = 1; tick; rst_crc = 0;
        settle;
        `CHECK(value === 32'hFFFF, "E2 RST loads init")
        cfg(8, 32'h07, 32'hFFFF_FFFF, 0, 0, 32'h0);   // init wider than the width: masked
        settle;
        `CHECK(value === 32'hFF, "E2 init masked to the width")

        // ---- E2b: init is masked into the register, so widening the width later exposes zeros, not stale upper bits
        cfg(8, 32'h07, 32'hFFFF_FFFF, 0, 0, 32'h0);
        cfg_data = 32'd31; set_fmt = 1; tick; set_fmt = 0;      // width 32, refin 0, refout 0, no RST
        cfg_data = 32'h0;  set_xor = 1; tick; set_xor = 0;
        settle;
        `CHECK(value === 32'h0000_00FF, "E2b init masked on RST (no stale upper bits after widening)")

        // ---- E2c: junk above the width in the polynomial must not leak into the register (visible after widening)
        cfg(8, 32'hFFFF_FF07, 32'h0, 0, 0, 32'h0);          // junk polynomial
        put_byte(8'h5A); put_byte(8'h01);
        cfg_data = 32'd31; set_fmt = 1; tick; set_fmt = 0;
        settle;
        got = value;
        cfg(8, 32'h0000_0007, 32'h0, 0, 0, 32'h0);          // same with the clean polynomial
        put_byte(8'h5A); put_byte(8'h01);
        cfg_data = 32'd31; set_fmt = 1; tick; set_fmt = 0;
        settle;
        `CHECK(value === got, "E2c polynomial masked to the width (no junk after widening)")

        // ---- E3: widths 1 and 32 edge, value masked
        cfg(1, 32'h1, 32'h0, 0, 0, 32'h0);
        put_bit(1); put_bit(0); put_bit(1);
        settle;
        `CHECK(value === 32'h0, "E3 width 1 (parity of 101 = 0)")
        put_bit(1);
        settle;
        `CHECK(value === 32'h1, "E3 width 1 (parity of 1011 = 1)")

        // ---- E3b: a format write keeps the register but cuts it to the new width; widening again does not bring the old bits back
        cfg(32, 32'h0, 32'hFFFF_FFFF, 0, 0, 32'h0);                  // register = FFFFFFFF
        settle;
        `CHECK(value === 32'hFFFF_FFFF, "E3b register = init")
        cfg_data = 32'd7; set_fmt = 1; tick; set_fmt = 0;            // width 8
        settle;
        `CHECK(value === 32'h0000_00FF, "E3b narrowing keeps the low bits")
        cfg_data = 32'd31; set_fmt = 1; tick; set_fmt = 0;           // width 32 again
        settle;
        `CHECK(value === 32'h0000_00FF, "E3b the bits cut by the narrowing do not come back")
        cfg_data = 32'd3; set_fmt = 1; tick; set_fmt = 0;            // width 4
        cfg_data = 32'd15; set_fmt = 1; tick; set_fmt = 0;           // width 16
        settle;
        `CHECK(value === 32'h0000_000F, "E3b narrowing twice, then widening")

        // ---- E4: reset restores the default configuration
        rst_n = 0; tick; rst_n = 1; tick;
        for (i = 0; i < 9; i = i + 1) put_byte("1" + i);
        settle;
        `CHECK(value === 32'hCBF4_3926, "E4 asynchronous reset restores CRC-32 defaults")

        // ---- G: the command pipeline
        // G1: busy only in the clock after a command; value changes one clock after the command was taken
        cfg(8, 32'h07, 32'h0, 0, 0, 32'h0);
        settle;
        `CHECK(busy === 1'b0 && value === 32'h0, "G1 idle: busy 0, register = init")
        din = 8'h31; feed_byte = 1; #1;
        `CHECK(busy === 1'b0, "G1 busy is registered (not combinational from the command)")
        tick; feed_byte = 0; #1;
        `CHECK(busy === 1'b1 && value === 32'h0, "G1 clock after the command: busy 1, value still old")
        tick;
        `CHECK(busy === 1'b0 && value === 32'h97, "G1 one clock later: busy 0, value updated (CRC-8/SMBUS of '1' = 97)")
        // G2: back to back, each command in its own clock, in order: POLY then BYTE uses the new polynomial
        cfg(8, 32'h07, 32'h0, 0, 0, 32'h0);
        cfg_data = 32'h31; set_poly = 1; tick; set_poly = 0;
        din = 8'h31; feed_byte = 1; tick; feed_byte = 0;
        settle;
        `CHECK(value === 32'hF4, "G2 POLY alone (no FMT after it) takes effect: CRC-8 poly 31 of '1' = F4")
        got = value;                                    // compared with the same sequence with an idle clock between the commands
        cfg(8, 32'h07, 32'h0, 0, 0, 32'h0);
        cfg_data = 32'h31; set_poly = 1; tick; set_poly = 0;
        settle;
        din = 8'h31; feed_byte = 1; tick; feed_byte = 0;
        settle;
        `CHECK(value === got, "G2 POLY then BYTE back to back = with an idle clock between")
        // G3: FMT then BIT back to back (new width and new alignment of register and polynomial), against the idle-clock sequence
        cfg(16, 32'h1021, 32'hBEEF, 0, 0, 32'h0);
        cfg_data = 32'd7; set_fmt = 1; tick; set_fmt = 0;
        din = 8'h01; feed_bit = 1; tick; feed_bit = 0;
        din = 8'h00; feed_bit = 1; tick; feed_bit = 0;
        settle;
        got = value;
        cfg(16, 32'h1021, 32'hBEEF, 0, 0, 32'h0);
        cfg_data = 32'd7; set_fmt = 1; tick; set_fmt = 0;
        settle;
        din = 8'h01; feed_bit = 1; tick; feed_bit = 0;
        settle;
        din = 8'h00; feed_bit = 1; tick; feed_bit = 0;
        settle;
        `CHECK(value === got, "G3 FMT then BIT BIT back to back = with idle clocks between")
        // G4: BYTE then RST back to back: the RST wins (the byte is applied first, then the register is reloaded)
        cfg(8, 32'h07, 32'h5A, 0, 0, 32'h0);
        din = 8'hC3; feed_byte = 1; tick; feed_byte = 0;
        rst_crc = 1; tick; rst_crc = 0;
        settle;
        `CHECK(value === 32'h5A, "G4 BYTE then RST back to back: register = init")
        // G5: a command waiting in the pipeline is dropped by the asynchronous reset
        cfg(8, 32'h07, 32'h0, 0, 0, 32'h0);
        settle;
        din = 8'h31; feed_byte = 1; tick; feed_byte = 0;
        rst_n = 0; #1;
        `CHECK(busy === 1'b0, "G5 reset clears a waiting command")
        tick; rst_n = 1; tick; tick;
        for (i = 0; i < 9; i = i + 1) put_byte("1" + i);
        settle;
        `CHECK(value === 32'hCBF4_3926, "G5 after the reset: CRC-32 defaults, no stale command applied")

        // ---- C/D: random configurations against the polynomial-division reference
        for (t = 0; t < 1500; t = t + 1) begin
            rnd = next_rnd(rnd); W = 1 + (rnd >> 8) % 32;
            rnd = next_rnd(rnd); poly = rnd;
            rnd = next_rnd(rnd); init = rnd;
            rnd = next_rnd(rnd); xo = rnd;
            rnd = next_rnd(rnd); ri = rnd[9]; ro = rnd[17];
            mk = (W == 32) ? 32'hFFFF_FFFF : ((32'd1 << W) - 1);
            rawp = poly; rawi = init; rawx = xo;                  // the DUT may be given junk above the width
            poly = poly & mk; init = init & mk; xo = xo & mk;
            rnd = next_rnd(rnd);
            if (rnd[12]) cfg(W, rawp, rawi, ri, ro, rawx);        // unmasked values: must behave as masked
            else         cfg(W, poly, init, ri, ro, xo);
            slen = 0; stream = 0;
            rnd = next_rnd(rnd); nb = (rnd >> 8) % 18;
            for (i = 0; i < nb; i = i + 1) begin
                rnd = next_rnd(rnd);
                if (rnd[30]) send_bit(rnd[3]);           // mix single bits and bytes
                else         send_byte(ri, rnd[23:16]);
            end
            settle;
            exp = ref_final(W, poly, init, ro, xo);
            if (value !== exp) begin
                errors = errors + 1;
                if (errors < 8) $display("  FAIL random %0d: W=%0d poly=%h init=%h ri=%b ro=%b xo=%h len=%0d got %h want %h",
                                         t, W, poly, init, ri, ro, xo, slen, value, exp);
            end
        end

        // ---- F: vectors from the Python model (host/crc_test.py)
        if ($value$plusargs("VEC=%s", vec_file)) begin
            fd = $fopen(vec_file, "r");
            n = 0;
            while (!$feof(fd)) begin
                rc = $fscanf(fd, "%d %h %h %d %d %h %d", vw, vp, vi, vri, vro, vxo, vnb);
                if (rc == 7) begin
                    cfg(vw, vp, vi, vri[0], vro[0], vxo);
                    for (i = 0; i < vnb; i = i + 1) begin rc = $fscanf(fd, "%h", vb); put_byte(vb); end
                    rc = $fscanf(fd, "%h", vcheck);
                    settle;
                    n = n + 1;
                    if (value !== vcheck) begin
                        errors = errors + 1;
                        if (errors < 8) $display("  FAIL python vector %0d: W=%0d got %h want %h", n, vw, value, vcheck);
                    end
                end
            end
            $fclose(fd);
            $display("  python vectors: %0d checked", n);
            `CHECK(n > 0, "F python vectors present")
        end

        `REPORT("tb_crc_unit")
        $finish;
    end
endmodule
