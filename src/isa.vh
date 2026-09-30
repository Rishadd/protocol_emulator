// Instruction word: [31:27] opcode, [26:0] operand (flat, one meaning per opcode).
// A timed instruction with operand d occupies exactly d+1 cycles (d=0 -> 1 cycle).
`ifndef ISA_VH
`define ISA_VH

`define OP_NOP    5'd0   // -
`define OP_WAIT   5'd1   // d      : hold d+1 cycles
`define OP_JMP    5'd2   // addr   : pc <= addr
`define OP_HALT   5'd3   // -
`define OP_SETL   5'd4   // n      : loop counter <= n
`define OP_DJNZ   5'd5   // addr   : loop--, jump if result != 0
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
// 5'd17 WAITR, 5'd18 WAITF reserved for edge detect (v0.3). All others trap.
`define OP_LAST_LEGAL 5'd16

`endif
