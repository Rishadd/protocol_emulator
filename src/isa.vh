// Instruction word: [31:27] opcode, [26:0] operand (flat, one meaning per opcode).
// A timed instruction with operand d occupies exactly d+1 cycles (d=0 -> 1 cycle).
`ifndef ISA_VH
`define ISA_VH

`define OP_NOP    5'd0   // -
`define OP_WAIT   5'd1   // d      : hold d+1 cycles
`define OP_JMP    5'd2   // [7:0] addr : pc <= addr (256-word program memory)
`define OP_HALT   5'd3   // -
`define OP_SETL   5'd4   // n      : loop counter <= n
`define OP_DJNZ   5'd5   // [7:0] addr : loop--, jump if result != 0
`define OP_PULL   5'd6   // -      : block until tx_fifo nonempty, pop into OSR
`define OP_PUSH   5'd7   // -      : block until rx_fifo not full, push ISR, clear ISR
`define OP_OUT1   5'd8   // d      : pin[out_pin] <= OSR bit, shift OSR, hold d+1 cycles
`define OP_IN1    5'd9   // d      : ISR <= pin[in_pin], hold d+1 cycles
`define OP_SETH   5'd10  // pin    : pin_out[pin] <= 1
`define OP_SETLO  5'd11  // pin    : pin_out[pin] <= 0
`define OP_DIRO   5'd12  // pin    : pin_oe[pin] <= 1 (drive)
`define OP_DIRI   5'd13  // pin    : pin_oe[pin] <= 0 (release / input)
`define OP_WAITH  5'd14  // pin    : block until pin_in[pin] == 1
`define OP_WAITL  5'd15  // pin    : block until pin_in[pin] == 0
`define OP_CFG    5'd16  // [2:0] out_pin, [5:3] in_pin, [6] OSR msb-first, [7] ISR msb-first
`define OP_JPH    5'd17  // [7:0] addr, [10:8] pin : jump if pin_in[pin] == 1, else advance
`define OP_JPL    5'd18  // [7:0] addr, [10:8] pin : jump if pin_in[pin] == 0, else advance
`define OP_JPO    5'd19  // [7:0] addr : jump if the next OSR bit is 1, else advance; OSR shifts (bit consumed)
`define OP_PUSHI  5'd20  // v      : block until rx_fifo not full; rx_fifo <= zero-extended v; ISR untouched
// ---- register / ALU / CRC extension (docs/ALU_CRC_I2CSLAVE_PLAN.md section 3.1)
`define OP_LDI    5'd21  // [26:24] rd, [23:0] imm24 : R[rd] <= imm24 (zero-extended), flags unchanged
`define OP_ALU    5'd22  // [26:23] func, [22:20] rd, [19:17] rs, [16] use_imm, [15:0] imm16 : R[rd] <= R[rd] func (use_imm ? imm16 : R[rs])
`define OP_JCC    5'd23  // [10:8] cond, [7:0] addr : jump if the condition holds on the flags, else advance
`define OP_RGET   5'd24  // [2:0] rd, [6:4] src : R[rd] <= OSR / ISR / loop counter / pins / CRC value / TX FIFO word (pops, stalls while empty)
`define OP_RPUT   5'd25  // [2:0] rs, [6:4] dst : OSR / ISR / loop counter <= R[rs]; RX FIFO <= R[rs] (stalls while full)
`define OP_WAITR  5'd26  // [2:0] rs : hold R[rs] + 1 cycles (WAIT with the delay taken from a register)
`define OP_CRC    5'd27  // [26:24] cop, [2:0] rs : CRC unit operation (see CRC_* below)
// All others trap.
`define OP_LAST_LEGAL 5'd27

// ALU functions (OP_ALU [26:23]); 13..15 trap
`define ALU_MOV  4'd0
`define ALU_ADD  4'd1
`define ALU_SUB  4'd2
`define ALU_AND  4'd3
`define ALU_OR   4'd4
`define ALU_XOR  4'd5
`define ALU_SHL  4'd6
`define ALU_SHR  4'd7
`define ALU_CMP  4'd8
`define ALU_TST  4'd9
`define ALU_NOT  4'd10
`define ALU_PAR  4'd11
`define ALU_REV8 4'd12
`define ALU_LAST_LEGAL 4'd12

// JCC conditions (OP_JCC [10:8])
`define CC_Z   3'd0
`define CC_NZ  3'd1
`define CC_C   3'd2
`define CC_NC  3'd3
`define CC_N   3'd4
`define CC_NN  3'd5
`define CC_GTU 3'd6   // C and not Z (unsigned greater after CMP)
`define CC_LEU 3'd7   // not C or Z

// RGET sources (OP_RGET [6:4]); 6, 7 trap
`define RG_OSR 3'd0
`define RG_ISR 3'd1
`define RG_LC  3'd2
`define RG_PIN 3'd3
`define RG_CRC 3'd4
`define RG_TXF 3'd5
// RPUT destinations (OP_RPUT [6:4]); 4..7 trap
`define RP_OSR 3'd0
`define RP_ISR 3'd1
`define RP_LC  3'd2
`define RP_RXF 3'd3
// CRC operations (OP_CRC [26:24]); 7 traps
`define CRC_RST   3'd0
`define CRC_POLY  3'd1
`define CRC_INIT  3'd2
`define CRC_XOR   3'd3
`define CRC_FMT   3'd4
`define CRC_BIT   3'd5
`define CRC_BYTE  3'd6

`endif
