// Decodes instr[31:27] opcode, instr[26:0] flat operand (see isa.vh).
// Every instruction commits in S_EXEC; timed ones with d>0 then sit in S_HOLD
// until the delay counter's last cycle, so total occupancy is exactly d+1 cycles.
// Blocking instructions (PULL/PUSH/WAITH/WAITL) hold PC with no side effects.
`include "isa.vh"
module control_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [31:0] instr,
    // program counter
    output reg         pc_advance,      // normal increment
    output reg         pc_jump,         // jump to given address
    output wire [7:0]  jump_addr,       // jump target address
    // delay counter
    output reg         dc_load,         // signal to load the delay counter
    output wire [26:0] dc_load_value,   // value to load into the delay counter
    input  wire        dc_last,         // signals that the delay counter is in its last cycle for instruction execution
    // loop counter
    output reg         lc_load,         // signal to load the loop counter
    output reg         lc_dec,          // signal to start decrementing the loop counter
    output wire [15:0] lc_load_value,   // value to load into the loop counter    
    input  wire [15:0] lc_count,        // current value of the loop counter
    // fifos
    input  wire        tx_empty,        // indicates if the transmit FIFO is empty
    output reg         tx_rd_en,        // signal to read from the transmit FIFO
    input  wire        rx_full,         // indicates if the receive FIFO is full
    output reg         rx_wr_en,        // signal to write to the receive FIFO
    output reg         push_imm,        // with rx_wr_en: write the operand (PUSHI), not the ISR
    output reg         push_reg,        // with rx_wr_en: write R[rs] (RPUT RXF)
    // register file / ALU / CRC extension
    input  wire        flag_z,          // ALU flags (from alu_unit)
    input  wire        flag_n,
    input  wire        flag_c,
    input  wire        rs_zero,         // R[rs] == 0 (for WAITR)
    output reg         alu_go,          // ALU instruction commits
    output reg         ldi_go,          // LDI commits
    output reg         rget_go,         // RGET commits (engine_top selects the source from operand[6:4])
    output reg         isr_load,        // RPUT ISR: ISR <= R[rs]
    output reg         osr_from_reg,    // with osr_load: load value is R[rs] (RPUT OSR), not the TX FIFO word
    output reg         lc_from_reg,     // with lc_load: load value is R[rs][15:0] (RPUT LC), not the operand
    output reg         dc_from_reg,     // with dc_load: delay is R[rs] (WAITR), not the operand
    output reg         crc_rst,
    output reg         crc_set_poly,
    output reg         crc_set_init,
    output reg         crc_set_xor,
    output reg         crc_set_fmt,
    output reg         crc_feed_bit,
    output reg         crc_feed_byte,
    input  wire        crc_busy,        // a CRC command issued in the previous clock is still executing (RGET CRC waits)
    output wire        cfg_osr_msb_next, // OSR bit order after the coming edge (the fetch stage resolves a JPO one clock early)
    // shift registers
    output reg         osr_load,        // signal to load the output shift register
    output reg         osr_shift,       // signal to shift the output shift register
    input  wire        osr_bit,         // current bit of the output shift register
    output reg         isr_shift,       // signal to shift the input shift register
    output reg         isr_clear,       // signal to clear the input shift register
    // pins
    output reg         pin_wr,          // signal to write to a pin
    output reg  [2:0]  pin_wr_idx,      // index of the pin to write to
    output reg         pin_wr_val,      // value to write to the pin
    output reg         dir_wr,          // signal to write to a pin direction register
    output reg  [2:0]  dir_wr_idx,      // index of the direction register to write to
    output reg         dir_wr_val,      // direction value: 1 = output (drive), 0 = input (release / hi-Z)
    input  wire [7:0]  pin_in,          // current values of the input pins
    // configuration (set by CFG instruction, sticky until next CFG or reset)
    output reg  [2:0]  cfg_out_pin,     // GPIO index that OUT1 drives the next OSR bit onto
    output reg  [2:0]  cfg_in_pin,      // GPIO index that IN1 samples into the ISR
    output reg         cfg_osr_msb,     // OSR bit order: 0 = LSB-first (UART), 1 = MSB-first (SPI/I2C)
    output reg         cfg_isr_msb,     // ISR bit order: 0 = LSB-first, 1 = MSB-first
    // status
    output reg         halted,
    output reg         fault
);
    localparam S_EXEC = 1'b0;           // state for executing instructions
    localparam S_HOLD = 1'b1;           // state for holding until a condition clears

    reg state;

    wire [4:0]  opcode  = instr[31:27];
    wire [26:0] operand = instr[26:0];
    wire [2:0]  pin_sel = operand[2:0];

    assign jump_addr     = operand[7:0];
    assign dc_load_value = operand;
    assign lc_load_value = operand[15:0];

    // sub-field legality of the register extension: reserved function / source / destination / CRC op traps like a reserved opcode
    wire [3:0]  alu_func = operand[26:23];
    wire [2:0]  rg_src   = operand[6:4];
    wire [2:0]  rp_dst   = operand[6:4];
    wire [2:0]  crc_cop  = operand[26:24];
    wire sub_ok = (opcode == `OP_ALU)  ? (alu_func <= `ALU_LAST_LEGAL) :
                  (opcode == `OP_RGET) ? (rg_src   <= `RG_TXF) :
                  (opcode == `OP_RPUT) ? (rp_dst   <= `RP_RXF) :
                  (opcode == `OP_CRC)  ? (crc_cop  <= `CRC_BYTE) : 1'b1;
    wire legal      = (opcode <= `OP_LAST_LEGAL) && sub_ok;   // opcodes above OP_LAST_LEGAL, or a reserved sub-field, trap
    wire jp_taken   = (pin_in[operand[10:8]] == (opcode == `OP_JPH));  // JPH/JPL: pin in [10:8], addr in [7:0]
    wire timed      = (opcode == `OP_WAIT) || (opcode == `OP_OUT1) || (opcode == `OP_IN1);  // instructions that require holding for a condition
    wire needs_hold = (timed && (operand != 27'd0)) ||            // indicates if the instruction requires holding based on the operand
                      (opcode == `OP_WAITR && !rs_zero);          // WAITR: delay in a register


    // JCC condition on the ALU flags
    reg cc_true;
    always @(*) begin
        case (operand[10:8])
            `CC_Z:   cc_true = flag_z;
            `CC_NZ:  cc_true = ~flag_z;
            `CC_C:   cc_true = flag_c;
            `CC_NC:  cc_true = ~flag_c;
            `CC_N:   cc_true = flag_n;
            `CC_NN:  cc_true = ~flag_n;
            `CC_GTU: cc_true = flag_c & ~flag_z;
            default: cc_true = ~flag_c | flag_z;     // CC_LEU
        endcase
    end

    // blocking instructions: hold PC with no side effects until the condition clears
    wire stall = (opcode == `OP_PULL)  ? tx_empty :          // PULL needs a word in the TX FIFO
                 (opcode == `OP_PUSH || opcode == `OP_PUSHI) ? rx_full :   // PUSH/PUSHI need RX FIFO space
                 (opcode == `OP_WAITH) ? ~pin_in[pin_sel] :  // WAITH waits for pin to go high
                 (opcode == `OP_WAITL) ?  pin_in[pin_sel] :  // WAITL waits for pin to go low
                 (opcode == `OP_RGET && rg_src == `RG_TXF) ? tx_empty :   // RGET TXF needs a TX FIFO word
                 (opcode == `OP_RGET && rg_src == `RG_CRC) ? crc_busy :   // RGET CRC directly after a CRC instruction: 1 clock
                 (opcode == `OP_RPUT && rp_dst == `RP_RXF) ? rx_full :    // RPUT RXF needs RX FIFO space
                                          1'b0;              // all other opcodes never stall

    assign cfg_osr_msb_next = (!halted && state == S_EXEC && legal && opcode != `OP_HALT && !stall && opcode == `OP_CFG) ?
                              operand[6] : cfg_osr_msb;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state       <= S_EXEC;
            halted      <= 1'b0;
            fault       <= 1'b0;
            cfg_out_pin <= 3'd0;
            cfg_in_pin  <= 3'd0;
            cfg_osr_msb <= 1'b0;
            cfg_isr_msb <= 1'b0;
        end else if (!halted) begin
            case (state)
                S_EXEC: begin
                    if (!legal) begin
                        halted <= 1'b1;
                        fault  <= 1'b1;
                    end else if (opcode == `OP_HALT) begin
                        halted <= 1'b1;
                    end else if (!stall) begin
                        if (opcode == `OP_CFG) begin
                            cfg_out_pin <= operand[2:0];
                            cfg_in_pin  <= operand[5:3];
                            cfg_osr_msb <= operand[6];
                            cfg_isr_msb <= operand[7];
                        end
                        if (needs_hold)
                            state <= S_HOLD;
                    end
                end
                S_HOLD: if (dc_last) state <= S_EXEC;
            endcase
        end
    end

    always @(*) begin
        pc_advance = 1'b0;
        pc_jump    = 1'b0;
        dc_load    = 1'b0;
        lc_load    = 1'b0;
        lc_dec     = 1'b0;
        tx_rd_en   = 1'b0;
        rx_wr_en   = 1'b0;
        push_imm   = 1'b0;
        push_reg   = 1'b0;
        alu_go     = 1'b0;
        ldi_go     = 1'b0;
        rget_go    = 1'b0;
        isr_load   = 1'b0;
        osr_from_reg = 1'b0;
        lc_from_reg  = 1'b0;
        dc_from_reg  = 1'b0;
        crc_rst       = 1'b0;
        crc_set_poly  = 1'b0;
        crc_set_init  = 1'b0;
        crc_set_xor   = 1'b0;
        crc_set_fmt   = 1'b0;
        crc_feed_bit  = 1'b0;
        crc_feed_byte = 1'b0;
        osr_load   = 1'b0;
        osr_shift  = 1'b0;
        isr_shift  = 1'b0;
        isr_clear  = 1'b0;
        pin_wr     = 1'b0;
        pin_wr_idx = 3'd0;
        pin_wr_val = 1'b0;
        dir_wr     = 1'b0;
        dir_wr_idx = 3'd0;
        dir_wr_val = 1'b0;
        if (!halted && legal) begin
            case (state)
                S_EXEC: if (!stall) begin
                    case (opcode)
                        `OP_NOP:  pc_advance = 1'b1;
                        `OP_WAIT: begin
                            dc_load    = 1'b1;
                            pc_advance = !needs_hold;
                        end
                        `OP_JMP:  pc_jump = 1'b1;
                        `OP_HALT: ;     // intentionally does nothing
                        `OP_SETL: begin
                            lc_load    = 1'b1;
                            pc_advance = 1'b1;
                        end
                        `OP_DJNZ: begin
                            lc_dec = 1'b1;
                            if (lc_count > 16'd1) pc_jump    = 1'b1;
                            else                  pc_advance = 1'b1;
                        end
                        `OP_PULL: begin
                            tx_rd_en   = 1'b1;
                            osr_load   = 1'b1;
                            pc_advance = 1'b1;
                        end
                        `OP_PUSH: begin
                            rx_wr_en   = 1'b1;
                            isr_clear  = 1'b1;
                            pc_advance = 1'b1;
                        end
                        `OP_OUT1: begin
                            pin_wr     = 1'b1;
                            pin_wr_idx = cfg_out_pin;
                            pin_wr_val = osr_bit;
                            osr_shift  = 1'b1;
                            dc_load    = 1'b1;
                            pc_advance = !needs_hold;
                        end
                        `OP_IN1: begin
                            isr_shift  = 1'b1;
                            dc_load    = 1'b1;
                            pc_advance = !needs_hold;
                        end
                        `OP_SETH, `OP_SETLO: begin
                            pin_wr     = 1'b1;
                            pin_wr_idx = pin_sel;
                            pin_wr_val = (opcode == `OP_SETH);
                            pc_advance = 1'b1;
                        end
                        `OP_DIRO, `OP_DIRI: begin
                            dir_wr     = 1'b1;
                            dir_wr_idx = pin_sel;
                            dir_wr_val = (opcode == `OP_DIRO);   // DIRO -> 1 (output), DIRI -> 0 (input)
                            pc_advance = 1'b1;
                        end
                        `OP_WAITH, `OP_WAITL, `OP_CFG: pc_advance = 1'b1;
                        `OP_JPH, `OP_JPL: begin
                            pc_jump    = jp_taken;
                            pc_advance = !jp_taken;
                        end
                        `OP_JPO: begin
                            osr_shift  = 1'b1;
                            pc_jump    = osr_bit;
                            pc_advance = !osr_bit;
                        end
                        `OP_PUSHI: begin
                            rx_wr_en   = 1'b1;
                            push_imm   = 1'b1;
                            pc_advance = 1'b1;
                        end
                        `OP_LDI: begin
                            ldi_go     = 1'b1;
                            pc_advance = 1'b1;
                        end
                        `OP_ALU: begin
                            alu_go     = 1'b1;
                            pc_advance = 1'b1;
                        end
                        `OP_JCC: begin
                            pc_jump    = cc_true;
                            pc_advance = !cc_true;
                        end
                        `OP_RGET: begin
                            rget_go    = 1'b1;
                            tx_rd_en   = (rg_src == `RG_TXF);
                            pc_advance = 1'b1;
                        end
                        `OP_RPUT: begin
                            case (rp_dst)
                                `RP_OSR: begin osr_load = 1'b1; osr_from_reg = 1'b1; end
                                `RP_ISR: isr_load = 1'b1;
                                `RP_LC:  begin lc_load = 1'b1; lc_from_reg = 1'b1; end
                                default: begin rx_wr_en = 1'b1; push_reg = 1'b1; end   // RP_RXF
                            endcase
                            pc_advance = 1'b1;
                        end
                        `OP_WAITR: begin
                            dc_load     = 1'b1;
                            dc_from_reg = 1'b1;
                            pc_advance  = !needs_hold;
                        end
                        `OP_CRC: begin
                            case (crc_cop)
                                `CRC_RST:  crc_rst       = 1'b1;
                                `CRC_POLY: crc_set_poly  = 1'b1;
                                `CRC_INIT: crc_set_init  = 1'b1;
                                `CRC_XOR:  crc_set_xor   = 1'b1;
                                `CRC_FMT:  crc_set_fmt   = 1'b1;
                                `CRC_BIT:  crc_feed_bit  = 1'b1;
                                default:   crc_feed_byte = 1'b1;     // CRC_BYTE
                            endcase
                            pc_advance = 1'b1;
                        end
                        default: ;
                    endcase
                end
                S_HOLD: if (dc_last) pc_advance = 1'b1;
            endcase
        end
    end
endmodule
