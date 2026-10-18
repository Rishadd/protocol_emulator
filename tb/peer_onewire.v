`timescale 1ns/1ps
// 1-Wire slave model (DS18B20-style), written from the Maxim 1-Wire timing rules, not from the firmware. Standard speed.
//   reset: master pulls DQ low >= 480 us, releases -> after 30 us the slave pulls DQ low for 120 us (presence), unless +OW_NOPRES=1
//   byte from master (LSB first): each bit starts with a falling edge; sampled 30 us after it: low = 0, high = 1
//   0x33 READ ROM : sends the 8 ROM bytes (family code first, CRC last), bits LSB first
//   0xCC SKIP ROM then 0xBE READ SCRATCHPAD : sends the 9 scratchpad bytes (byte 8 = CRC)
//   +OW_ROM=<64-bit hex, byte 0 in bits 7:0>   +OW_SP=<72-bit hex>   +OW_NOPRES=1
// Read slot: the slave pulls DQ low for 30 us when it sends a 0 (the master samples at about 15 us), nothing for a 1.
// Prints "OW reset", "OW cmd xx", "OW sent n" so the testbench log shows what the device saw.
module peer_onewire (
    input  wire dq,
    output reg  dq_low
);
    reg [63:0] rom = 64'h0000_0000_0000_0000;
    reg [71:0] sp  = 72'h0;
    integer nopres = 0;
    reg [7:0] cmd;
    integer i, t0;
    reg bitv;

    initial begin
        dq_low = 1'b0;
        if ($value$plusargs("OW_ROM=%h", rom)) ;
        if ($value$plusargs("OW_SP=%h", sp)) ;
        if ($value$plusargs("OW_NOPRES=%d", nopres)) ;
        wait_loop;
    end

    task wait_reset;
        reg done;
        begin
            done = 0;
            while (!done) begin
                @(negedge dq);
                t0 = $time;
                @(posedge dq);
                if ($time - t0 >= 480000) done = 1;                      // low for at least 480 us (time unit = 1 ns)
            end
        end
    endtask

    task get_byte(output [7:0] b);
        integer k;
        begin
            b = 8'h00;
            for (k = 0; k < 8; k = k + 1) begin
                @(negedge dq);
                #30000;                                                  // 30 us
                b[k] = dq;
                if (!dq) @(posedge dq);
            end
        end
    endtask

    task send_bits(input [71:0] data, input integer nbits);
        integer k;
        begin
            for (k = 0; k < nbits; k = k + 1) begin
                @(negedge dq);
                if (!data[k]) begin dq_low = 1'b1; #30000; dq_low = 1'b0; end
                if (!dq) @(posedge dq);
            end
        end
    endtask

    task wait_loop;
        begin
            forever begin
                wait_reset;
                $display("OW reset at %0t", $time);
                #30000;
                if (!nopres) begin dq_low = 1'b1; #120000; dq_low = 1'b0; end
                get_byte(cmd);
                $display("OW cmd %02x", cmd);
                if (cmd == 8'h33) begin
                    send_bits({8'h00, rom}, 64);
                    $display("OW sent ROM");
                end else if (cmd == 8'hCC) begin
                    get_byte(cmd);
                    $display("OW cmd2 %02x", cmd);
                    if (cmd == 8'hBE) begin send_bits(sp, 72); $display("OW sent scratchpad"); end
                end
            end
        end
    endtask
endmodule
