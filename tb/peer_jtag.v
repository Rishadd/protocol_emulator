`timescale 1ns/1ps
// IEEE 1149.1 TAP model for the protocol testbenches, written from the standard (state diagram, capture/shift/update), not from the firmware.
//   IR = 4 bits, capture value 0001. After Test-Logic-Reset the instruction is IDCODE.
//   0x1 IDCODE (32-bit, read only, +JT_ID=<hex>, bit 0 = 1)   0x2 USER32 (32-bit read/write)   0x3 USER64 (64-bit read/write)
//   0xF BYPASS (1 bit, captures 0); any other instruction selects BYPASS.
// TDI and TMS are sampled on the rising edge of TCK; TDO changes on the falling edge. tdo_low pulls the (pulled-up) TDO pad low.
module peer_jtag (
    input  wire tck,
    input  wire tms,
    input  wire tdi,
    output wire tdo_low
);
    localparam TLR = 0, RTI = 1, SELDR = 2, CAPDR = 3, SHDR = 4, EX1DR = 5, PADR = 6, EX2DR = 7, UPDR = 8,
               SELIR = 9, CAPIR = 10, SHIR = 11, EX1IR = 12, PAIR = 13, EX2IR = 14, UPIR = 15;
    reg [3:0]  state = TLR;
    reg [3:0]  ir = 4'h1, irsh = 4'h0;
    reg [31:0] idcode = 32'h1BA0_0477;
    reg [31:0] user32 = 32'h0;
    reg [63:0] user64 = 64'h0;
    reg [63:0] sh = 64'h0;
    reg        tdo = 1'b1;
    integer    len;
    assign tdo_low = ~tdo;

    initial if ($value$plusargs("JT_ID=%h", idcode)) ;

    function integer dr_len(input [3:0] i);
        dr_len = (i == 4'h1 || i == 4'h2) ? 32 : (i == 4'h3) ? 64 : 1;
    endfunction

    reg [3:0] ns;
    always @(posedge tck) begin
        // state transitions on TMS
        ns = state;
        case (state)
            TLR:   ns = tms ? TLR   : RTI;
            RTI:   ns = tms ? SELDR : RTI;
            SELDR: ns = tms ? SELIR : CAPDR;
            CAPDR: ns = tms ? EX1DR : SHDR;
            SHDR:  ns = tms ? EX1DR : SHDR;
            EX1DR: ns = tms ? UPDR  : PADR;
            PADR:  ns = tms ? EX2DR : PADR;
            EX2DR: ns = tms ? UPDR  : SHDR;
            UPDR:  ns = tms ? SELDR : RTI;
            SELIR: ns = tms ? TLR   : CAPIR;
            CAPIR: ns = tms ? EX1IR : SHIR;
            SHIR:  ns = tms ? EX1IR : SHIR;
            EX1IR: ns = tms ? UPIR  : PAIR;
            PAIR:  ns = tms ? EX2IR : PAIR;
            EX2IR: ns = tms ? UPIR  : SHIR;
            UPIR:  ns = tms ? SELDR : RTI;
        endcase
        state <= ns;
        // actions of the state we are in at this rising edge
        case (state)
            CAPDR: begin
                len = dr_len(ir);
                sh <= (ir == 4'h1) ? {32'h0, idcode} : (ir == 4'h2) ? {32'h0, user32} : (ir == 4'h3) ? user64 : 64'h0;
            end
            SHDR: begin
                len = dr_len(ir);
                sh <= (sh >> 1) | ({63'h0, tdi} << (len - 1));
            end
            UPDR: begin
                if (ir == 4'h2) user32 <= sh[31:0];
                if (ir == 4'h3) user64 <= sh;
            end
            CAPIR: irsh <= 4'b0001;
            SHIR:  irsh <= {tdi, irsh[3:1]};
            UPIR:  ir <= irsh;
            default: ;
        endcase
        if (ns == TLR) ir <= 4'h1;                       // entering Test-Logic-Reset selects IDCODE
    end
    // TDO changes on the falling edge
    always @(negedge tck) begin
        case (state)
            SHDR: tdo <= sh[0];
            SHIR: tdo <= irsh[0];
            default: tdo <= 1'b1;
        endcase
    end
endmodule
