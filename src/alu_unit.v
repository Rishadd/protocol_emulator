// Register file (8 x 32), ALU and flags {Z, N, C}. Instruction operand layouts (docs/ALU_CRC_I2CSLAVE_PLAN.md 3.1):
//   ALU : [26:23] func, [22:20] rd, [19:17] rs, [16] use_imm, [15:0] imm16     R[rd] <- R[rd] func src, src = use_imm ? imm16 : R[rs]
//   LDI : [26:24] rd, [23:0] imm24                                              R[rd] <- imm24 (zero-extended)
//   RGET: [2:0] rd                                                              R[rd] <- rget_data (chosen by the engine)
// Two read ports, each wired straight to its operand field, so the register select starts from the instruction bits without waiting
// for the opcode decode (that decode used to sit in the slow-corner critical path SRAM -> decode -> register read -> adder):
//   rs_val  = R[operand[2:0]]    for the instructions that read a register outside the ALU (RPUT, WAITR, CRC)
//   ALU src = R[operand[19:17]]  (the ALU's rs field)
// Reads are combinational and see the value from before the
// clock edge (no forwarding): a result is visible to the next instruction. rs_zero = (R[rs][26:0] == 0): WAITR takes its delay from
// those 27 bits (like WAIT), so a register whose upper bits are set but whose low 27 bits are 0 is a zero delay, not a hang. Flags change only on ALU instructions (do_alu).
//   func: 0 MOV 1 ADD 2 SUB 3 AND 4 OR 5 XOR 6 SHL 7 SHR 8 CMP 9 TST 10 NOT 11 PAR 12 REV8   (13..15 are trapped by the control unit)
//   Z = result==0, N = result[31]; C: ADD carry out, SUB/CMP 1 = no borrow (a >= src unsigned), SHL/SHR last bit shifted out
//   (unchanged for a shift of 0); other functions leave C alone. CMP and TST compute flags but write nothing.
module alu_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [26:0] operand,
    input  wire        do_alu,
    input  wire        do_ldi,
    input  wire        do_rget,
    input  wire [31:0] rget_data,
    output wire [31:0] rs_val,
    output wire        rs_zero,
    output reg         flag_z,
    output reg         flag_n,
    output reg         flag_c,
    // the flags after the coming edge (the fetch stage resolves a JCC one clock early with them)
    output wire        flag_z_next,
    output wire        flag_n_next,
    output wire        flag_c_next
);
    reg [31:0] r [0:7];

    wire [3:0]  func    = operand[26:23];
    wire [2:0]  alu_rd  = operand[22:20];
    wire        use_imm = operand[16];

    assign rs_val  = r[operand[2:0]];
    assign rs_zero = (rs_val[26:0] == 27'd0);    // WAITR uses the low 27 bits as the delay, so "zero delay" must look at the same bits

    wire [31:0] a     = r[alu_rd];
    wire [31:0] alu_b = r[operand[19:17]];
    wire [31:0] src   = use_imm ? {16'd0, operand[15:0]} : alu_b;
    wire [4:0]  sh  = src[4:0];

    // ADD, SUB and CMP share one 32-bit Kogge-Stone parallel-prefix adder: a + (src ^ sub) + sub, with 5 prefix levels instead of the
    // 32-stage ripple carry Yosys builds from "+" (that chain was the critical path of the chip at the slow corner). Written as plain
    // vector expressions (a level with distance d is g | (p & g << d), p & (p << d | ones below d)) so it also simulates fast.
    // Carry out = 1 means "no borrow" (a >= src) for SUB / CMP.
    wire        sub    = (func == 4'd2) || (func == 4'd8);
    wire [31:0] ay     = sub ? ~src : src;
    wire [31:0] p0     = a ^ ay;
    wire [31:0] g0     = (a & ay) | {31'd0, p0[0] & sub};                 // carry-in folded into bit 0
    wire [31:0] g1     = g0 | (p0 & (g0 << 1));
    wire [31:0] p1     = p0 & ((p0 << 1)  | 32'h0000_0001);
    wire [31:0] g2     = g1 | (p1 & (g1 << 2));
    wire [31:0] p2     = p1 & ((p1 << 2)  | 32'h0000_0003);
    wire [31:0] g3     = g2 | (p2 & (g2 << 4));
    wire [31:0] p3     = p2 & ((p2 << 4)  | 32'h0000_000F);
    wire [31:0] g4     = g3 | (p3 & (g3 << 8));
    wire [31:0] p4     = p3 & ((p3 << 8)  | 32'h0000_00FF);
    wire [31:0] g5     = g4 | (p4 & (g4 << 16));                          // g5[i] = carry out of bit i
    wire [32:0] addsub = {g5[31], p0 ^ {g5[30:0], sub}};

    // Result: the adder output arrives last, so it gets the last 2:1 select; every other function (fast logic and the shifts) is
    // muxed first, in parallel with the adder. One function case with the adder inside put several mux levels behind the adder.
    wire        is_as = (func == 4'd1) || sub;          // ADD, SUB, CMP
    reg [31:0] other;
    reg        c_oth, c_upd_oth;
    always @(*) begin
        other = 32'd0; c_oth = flag_c; c_upd_oth = 1'b0;
        case (func)
            4'd0:  other = src;
            4'd3:  other = a & src;
            4'd4:  other = a | src;
            4'd5:  other = a ^ src;
            4'd6:  begin other = a << sh; if (sh != 5'd0) begin c_oth = a[6'd32 - {1'b0, sh}]; c_upd_oth = 1'b1; end end
            4'd7:  begin other = a >> sh; if (sh != 5'd0) begin c_oth = a[{1'b0, sh} - 6'd1];  c_upd_oth = 1'b1; end end
            4'd9:  other = a & src;
            4'd10: other = ~src;
            4'd11: other = {31'd0, ^src};
            4'd12: other = {24'd0, src[0], src[1], src[2], src[3], src[4], src[5], src[6], src[7]};
            default: other = 32'd0;
        endcase
    end
    wire [31:0] res   = is_as ? addsub[31:0] : other;
    wire        c_new = is_as ? addsub[32] : c_oth;
    wire        c_upd = is_as | c_upd_oth;
    wire        wr    = (func != 4'd8) && (func != 4'd9);   // CMP and TST only set flags

    assign flag_z_next = do_alu ? (res == 32'd0) : flag_z;
    assign flag_n_next = do_alu ? res[31] : flag_n;
    assign flag_c_next = (do_alu && c_upd) ? c_new : flag_c;

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 8; i = i + 1) r[i] <= 32'd0;
            flag_z <= 1'b0; flag_n <= 1'b0; flag_c <= 1'b0;
        end else begin
            flag_z <= flag_z_next;
            flag_n <= flag_n_next;
            flag_c <= flag_c_next;
            if (do_alu) begin
                if (wr) r[alu_rd] <= res;
            end else if (do_ldi) begin
                r[operand[26:24]] <= {8'd0, operand[23:0]};
            end else if (do_rget) begin
                r[operand[2:0]] <= rget_data;
            end
        end
    end
endmodule
