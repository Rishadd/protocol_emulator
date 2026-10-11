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
    output wire [5:0]  jump_addr,       // jump target address
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

    assign jump_addr     = operand[5:0];
    assign dc_load_value = operand;
    assign lc_load_value = operand[15:0];

    wire legal      = (opcode <= `OP_LAST_LEGAL);   // opcodes above OP_LAST_LEGAL trap
    wire jp_taken   = (pin_in[operand[8:6]] == (opcode == `OP_JPH));  // JPH/JPL: pin in [8:6], addr in [5:0]
    wire timed      = (opcode == `OP_WAIT) || (opcode == `OP_OUT1) || (opcode == `OP_IN1);  // instructions that require holding for a condition
    wire needs_hold = timed && (operand != 27'd0);  // indicates if the instruction requires holding based on the operand

    // blocking instructions: hold PC with no side effects until the condition clears
    wire stall = (opcode == `OP_PULL)  ? tx_empty :          // PULL needs a word in the TX FIFO
                 (opcode == `OP_PUSH || opcode == `OP_PUSHI) ? rx_full :   // PUSH/PUSHI need RX FIFO space
                 (opcode == `OP_WAITH) ? ~pin_in[pin_sel] :  // WAITH waits for pin to go high
                 (opcode == `OP_WAITL) ?  pin_in[pin_sel] :  // WAITL waits for pin to go low
                                          1'b0;              // all other opcodes never stall

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
                        default: ;
                    endcase
                end
                S_HOLD: if (dc_last) pc_advance = 1'b1;
            endcase
        end
    end
endmodule
