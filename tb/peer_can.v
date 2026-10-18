`timescale 1ns/1ps
// CAN 2.0A bus node for the protocol testbenches, written from the Bosch CAN 2.0 / ISO 11898-1 rules (not from the firmware):
// a receiver that hard-synchronises on SOF, samples at +CAN_SP percent of the bit (default 75), destuffs, checks the CRC-15 with the
// shift register of the specification and acknowledges good frames by pulling the ACK slot dominant. It prints one line per frame:
//   CANRX t=<ns> id=<dec> dlc=<n> rtr=<b> data=<hex, byte 0 in the top byte> crc=<b> ack=<b>     or     CANERR t=<ns> <reason>
// Plusargs: +CAN_BIT_NS=<n> (default 2000 = 500 kbit/s), +CAN_SP=<percent>, +CAN_ACK=0 (never acknowledge).
module peer_can (
    input  wire en,
    input  wire bus,
    output wire bus_low
);
    reg     ack_drive = 1'b0;
    assign  bus_low = ack_drive;

    real    bit_ns = 2000.0;
    integer sp_pct = 75;
    integer ack_en = 1;
    integer bn;
    initial begin
        if ($value$plusargs("CAN_BIT_NS=%d", bn)) bit_ns = bn;
        if ($value$plusargs("CAN_SP=%d", sp_pct)) ;
        if ($value$plusargs("CAN_ACK=%d", ack_en)) ;
    end

    reg [127:0] fb;                          // destuffed bits, newest in bit 0
    integer     nf, need, run, nwire, dlc, nb, idv;
    reg         last, b, stuff_err, rtr, ide, crc_ok, cx, done;
    reg [14:0]  crc;
    reg [63:0]  dat;
    real        t_sof, t_ack, t_q;

    initial begin : node
        #1;
        forever begin
            @(negedge bus);
            t_sof = $realtime;
            #(bit_ns * sp_pct / 100.0);
            if (en && bus === 1'b0) begin
                fb = 128'd0; nf = 0; need = 0; run = 0; last = 1'b1; stuff_err = 0; crc = 15'd0; nwire = 0;
                ide = 0; rtr = 0; dlc = 0; nb = 0; done = 0;
                b = 1'b0;
                while (!done) begin
                    nwire = nwire + 1;
                    if (run == 5) begin                                   // stuff bit: must differ, is discarded
                        if (b == last) begin stuff_err = 1; done = 1; end
                        else begin
                            last = b; run = 1;
                            if (need != 0 && nf >= need) done = 1;
                        end
                    end else begin
                        fb = {fb[126:0], b};
                        nf = nf + 1;
                        if (b == last && nf > 1) run = run + 1; else run = 1;
                        last = b;
                        cx = b ^ crc[14];
                        crc = {crc[13:0], 1'b0};
                        if (cx) crc = crc ^ 15'h4599;
                        if (nf == 19) begin
                            rtr = fb[6]; ide = fb[5]; dlc = fb[3:0];
                            nb = (dlc > 8) ? 8 : dlc;
                            need = 19 + (rtr ? 0 : 8 * nb) + 15;
                            if (ide) done = 1;
                        end
                        if (need != 0 && nf >= need && run != 5) done = 1;
                    end
                    if (!done) begin
                        #(bit_ns);
                        b = bus;
                    end
                end
                if (stuff_err || ide) begin
                    $display("CANERR t=%0d %s", $time, stuff_err ? "stuff error" : "extended frame");
                    t_q = $realtime;
                    while ($realtime - t_q < 11.0 * bit_ns) begin             // bus idle again: 11 recessive bit times
                        #(bit_ns / 8.0);
                        if (bus === 1'b0) t_q = $realtime;
                    end
                end else begin
                    crc_ok = (crc == 15'd0);
                    idv = fb[nf - 2 -: 11];
                    dat = rtr ? 64'd0 : ((fb >> 15) & ((64'd1 << (8 * nb)) - 64'd1));
                    // ACK slot: two bit times after the last bit of the CRC sequence (CRC delimiter first)
                    t_ack = t_sof + (nwire + 1) * bit_ns;
                    if (crc_ok && ack_en != 0) begin
                        #(t_ack - $realtime);
                        ack_drive = 1'b1;
                        #(bit_ns);
                        ack_drive = 1'b0;
                    end
                    $display("CANRX t=%0d id=%0d dlc=%0d rtr=%0d data=%h crc=%0d ack=%0d", $time, idv, dlc, rtr, dat, crc_ok,
                             crc_ok && (ack_en != 0));
                    #(t_sof + (nwire + 10) * bit_ns - $realtime);             // through the ACK delimiter and EOF
                end
            end
        end
    end
endmodule
