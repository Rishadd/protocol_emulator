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
    output reg         pc_advance,
    output reg         pc_jump,
    output wire [5:0]  jump_addr,
    // delay counter
    output reg         dc_load,
    output wire [26:0] dc_load_value,
    input  wire        dc_last,
    // loop counter
    output reg         lc_load,
    output reg         lc_dec,
    output wire [15:0] lc_load_value,
    input  wire [15:0] lc_count,
    // fifos
    input  wire        tx_empty,
    output reg         tx_rd_en,
    input  wire        rx_full,
    output reg         rx_wr_en,
    // shift registers
    output reg         osr_load,
    output reg         osr_shift,
    input  wire        osr_bit,
    output reg         isr_shift,
    output reg         isr_clear,
    // pins
    output reg         pin_wr,
    output reg  [2:0]  pin_wr_idx,
    output reg         pin_wr_val,
    output reg         dir_wr,
    output reg  [2:0]  dir_wr_idx,
    output reg         dir_wr_val,
    input  wire [7:0]  pin_in,
    // configuration (set by CFG)
    output reg  [2:0]  cfg_out_pin,
    output reg  [2:0]  cfg_in_pin,
    output reg         cfg_osr_msb,
    output reg         cfg_isr_msb,
    // status
    output reg         halted,
    output reg         fault
);
    localparam S_EXEC = 1'b0;
    localparam S_HOLD = 1'b1;

    reg state;

    wire [4:0]  opcode  = instr[31:27];
    wire [26:0] operand = instr[26:0];
    wire [2:0]  pin_sel = operand[2:0];

    assign jump_addr     = operand[5:0];
    assign dc_load_value = operand;
    assign lc_load_value = operand[15:0];

    wire legal      = (opcode <= `OP_LAST_LEGAL);
    wire timed      = (opcode == `OP_WAIT) || (opcode == `OP_OUT1) || (opcode == `OP_IN1);
    wire needs_hold = timed && (operand != 27'd0);

    // blocking instructions: hold PC with no side effects until the condition clears
    wire stall = (opcode == `OP_PULL)  ? tx_empty :
                 (opcode == `OP_PUSH)  ? rx_full  :
                 (opcode == `OP_WAITH) ? ~pin_in[pin_sel] :
                 (opcode == `OP_WAITL) ?  pin_in[pin_sel] : 1'b0;

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
                        `OP_HALT: ;
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
                            dir_wr_val = (opcode == `OP_DIRO);
                            pc_advance = 1'b1;
                        end
                        `OP_WAITH, `OP_WAITL, `OP_CFG: pc_advance = 1'b1;
                        default: ;
                    endcase
                end
                S_HOLD: if (dc_last) pc_advance = 1'b1;
            endcase
        end
    end
endmodule
