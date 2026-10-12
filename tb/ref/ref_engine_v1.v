// REFERENCE MODEL, do not edit. The engine exactly as tagged tt-phase0 (before the two-tier work):
// 6-bit pc, JPH/JPL pin at [8:6]. tb_fetch_equiv_v2 runs it in lockstep against the current engine.
// Generated with: git show tt-phase0:src/{engine_top,control_unit,pc_reg,instr_mem}.v + v1_ module prefix.
// fifo, shift_reg, delay_counter, loop_counter and pin_block are shared with src/ (unchanged).
// Single protocol engine: v1_instr_mem + v1_pc_reg + delay_counter + loop_counter
// + v1_control_unit + tx/rx fifo + OSR/ISR shift registers + 8-pin block.
// Fetch: v1_instr_mem has a synchronous read (SRAM macros) and is addressed with v1_pc_reg.next_pc,
// so instr always holds the word for the current pc. In a testbench use <inst>.imem.poke(a,w) /
// .load_hex("program.hex") (not a hierarchical array write).
// run=0 holds the execution core (PC, control, counters, shifters, pins) in reset:
// PC=0, pins released. FIFOs and instruction memory keep their contents.
// run must come from a flop (it gates an asynchronous reset).
module v1_engine_top #(
    parameter INIT_FILE = ""
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        run,
    // host -> instruction memory (management write port)
    input  wire        imem_we,
    input  wire [5:0]  imem_waddr,
    input  wire [31:0] imem_wdata,
    // host -> engine data
    input  wire        tx_wr_en,
    input  wire [31:0] tx_wr_data,
    output wire        tx_full,
    // engine -> host data
    input  wire        rx_rd_en,
    output wire [31:0] rx_rd_data,
    output wire        rx_empty,
    // protocol pins
    input  wire [7:0]  pin_in,
    output wire [7:0]  pin_out,
    output wire [7:0]  pin_oe,
    // status
    output wire        halted,
    output wire        fault,
    output wire [5:0]  pc
);
    wire        core_rst_n = rst_n & run;
    wire [31:0] instr;
    wire        pc_advance, pc_jump;
    wire [5:0]  jump_addr, next_pc;
    wire        dc_load, dc_last;
    wire [26:0] dc_load_value;
    wire        lc_load, lc_dec;
    wire [15:0] lc_load_value, lc_count;
    wire        tx_empty, tx_rd_en;
    wire [31:0] tx_rd_data;
    wire        rx_full, rx_wr_en, push_imm;
    wire        osr_load, osr_shift, osr_bit;
    wire [31:0] osr_data, isr_data;
    wire        isr_shift, isr_clear;
    wire        pin_wr, pin_wr_val, dir_wr, dir_wr_val;
    wire [2:0]  pin_wr_idx, dir_wr_idx;
    wire [7:0]  pin_in_sync;
    wire [2:0]  cfg_out_pin, cfg_in_pin;
    wire        cfg_osr_msb, cfg_isr_msb;

    // Held engine (core_rst_n=0): pc is already 0 but, with the synchronous instruction read, instr
    // still shows the previous pc's word for one more clock (the macro re-reads word 0 on the next
    // edge), and v1_control_unit decodes whatever instr holds. tx_rd_en / rx_wr_en are the only
    // v1_control_unit outputs that reach state outside the reset core (the FIFOs), so they are
    // masked with core_rst_n; everything else sits behind core_rst_n's asynchronous reset.
    v1_instr_mem #(.INIT_FILE(INIT_FILE)) imem (
        .clk   (clk),
        .addr  (next_pc),
        .instr (instr),
        .we    (imem_we),
        .waddr (imem_waddr),
        .wdata (imem_wdata)
    );

    v1_pc_reg pc_i (
        .clk       (clk),
        .rst_n     (core_rst_n),
        .advance   (pc_advance),
        .jump      (pc_jump),
        .jump_addr (jump_addr),
        .pc        (pc),
        .next_pc   (next_pc)
    );

    delay_counter dc (
        .clk        (clk),
        .rst_n      (core_rst_n),
        .load       (dc_load),
        .load_value (dc_load_value),
        .busy       (),
        .last       (dc_last)
    );

    loop_counter lc (
        .clk        (clk),
        .rst_n      (core_rst_n),
        .load       (lc_load),
        .load_value (lc_load_value),
        .dec        (lc_dec),
        .count      (lc_count)
    );

    fifo tx_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (tx_wr_en),
        .wr_data (tx_wr_data),
        .full    (tx_full),
        .rd_en   (tx_rd_en & core_rst_n),   // masked while held (note above imem)
        .rd_data (tx_rd_data),
        .empty   (tx_empty)
    );

    fifo rx_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (rx_wr_en & core_rst_n),
        .wr_data (push_imm ? {5'd0, instr[26:0]} : isr_data),   // PUSHI immediate or ISR
        .full    (rx_full),
        .rd_en   (rx_rd_en),
        .rd_data (rx_rd_data),
        .empty   (rx_empty)
    );

    shift_reg osr (
        .clk        (clk),
        .rst_n      (core_rst_n),
        .msb_first  (cfg_osr_msb),
        .load       (osr_load),
        .load_value (tx_rd_data),
        .clear      (1'b0),
        .shift_out  (osr_shift),
        .shift_in   (1'b0),
        .in_bit     (1'b0),
        .data       (osr_data),
        .out_bit    (osr_bit)
    );

    shift_reg isr (
        .clk        (clk),
        .rst_n      (core_rst_n),
        .msb_first  (cfg_isr_msb),
        .load       (1'b0),
        .load_value (32'd0),
        .clear      (isr_clear),
        .shift_out  (1'b0),
        .shift_in   (isr_shift),
        .in_bit     (pin_in_sync[cfg_in_pin]),
        .data       (isr_data),
        .out_bit    ()
    );

    pin_block pins (
        .clk         (clk),
        .rst_n       (core_rst_n),
        .pin_wr      (pin_wr),
        .pin_wr_idx  (pin_wr_idx),
        .pin_wr_val  (pin_wr_val),
        .dir_wr      (dir_wr),
        .dir_wr_idx  (dir_wr_idx),
        .dir_wr_val  (dir_wr_val),
        .pin_in      (pin_in),
        .pin_out     (pin_out),
        .pin_oe      (pin_oe),
        .pin_in_sync (pin_in_sync)
    );

    v1_control_unit cu (
        .clk           (clk),
        .rst_n         (core_rst_n),
        .instr         (instr),
        .pc_advance    (pc_advance),
        .pc_jump       (pc_jump),
        .jump_addr     (jump_addr),
        .dc_load       (dc_load),
        .dc_load_value (dc_load_value),
        .dc_last       (dc_last),
        .lc_load       (lc_load),
        .lc_dec        (lc_dec),
        .lc_load_value (lc_load_value),
        .lc_count      (lc_count),
        .tx_empty      (tx_empty),
        .tx_rd_en      (tx_rd_en),
        .rx_full       (rx_full),
        .rx_wr_en      (rx_wr_en),
        .push_imm      (push_imm),
        .osr_load      (osr_load),
        .osr_shift     (osr_shift),
        .osr_bit       (osr_bit),
        .isr_shift     (isr_shift),
        .isr_clear     (isr_clear),
        .pin_wr        (pin_wr),
        .pin_wr_idx    (pin_wr_idx),
        .pin_wr_val    (pin_wr_val),
        .dir_wr        (dir_wr),
        .dir_wr_idx    (dir_wr_idx),
        .dir_wr_val    (dir_wr_val),
        .pin_in        (pin_in_sync),
        .cfg_out_pin   (cfg_out_pin),
        .cfg_in_pin    (cfg_in_pin),
        .cfg_osr_msb   (cfg_osr_msb),
        .cfg_isr_msb   (cfg_isr_msb),
        .halted        (halted),
        .fault         (fault)
    );
endmodule
// Decodes instr[31:27] opcode, instr[26:0] flat operand (see isa.vh).
// Every instruction commits in S_EXEC; timed ones with d>0 then sit in S_HOLD
// until the delay counter's last cycle, so total occupancy is exactly d+1 cycles.
// Blocking instructions (PULL/PUSH/WAITH/WAITL) hold PC with no side effects.
`include "isa.vh"
module v1_control_unit (
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

    wire legal      = (opcode <= 5'd20);   // opcodes above OP_LAST_LEGAL trap
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
// Program counter: holds at current value unless told to advance or jump.
// next_pc is the value pc will hold after the coming clock edge (0 while in reset). The
// instruction memory has a synchronous read, so it is addressed with next_pc: the word for
// the new pc is then on its output in the very cycle pc changes (see v1_instr_mem.v).
module v1_pc_reg #(
    parameter WIDTH = 6
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             advance,
    input  wire             jump,
    input  wire [WIDTH-1:0] jump_addr,
    output reg  [WIDTH-1:0] pc,
    output wire [WIDTH-1:0] next_pc
);
    //jump given more priority than advance
    assign next_pc = !rst_n ? {WIDTH{1'b0}} :
                     jump   ? jump_addr     :
                     advance ? pc + 1'b1    : pc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= {WIDTH{1'b0}};
        else
            pc <= next_pc;
    end
endmodule
// Instruction memory, 64 words x 32 bits: two IHP SG13 1P 64x16 SRAM macros side by side.
// Both macros get the same 6-bit address; u_lo stores bits [15:0] of every word, u_hi bits [31:16],
// so together they are one 64 x 32 memory (like two 16-bit-wide chips on one 32-bit bus).
//
//   fetch : SYNCHRONOUS read: instr = mem[addr] one clock after the edge that sampled addr.
//           v1_engine_top drives addr with v1_pc_reg.next_pc, so instr always holds the word for the
//           current pc (same behaviour as the old combinational mem[pc]).
//   write : we/waddr/wdata share the single macro port. While we=1 the host owns the port, so
//           writes are only legal while the engine is held (mgmt enforces RUN=0). The held engine
//           re-reads word 0 every clock, so RUN may rise from the second clock after the last write.
//   Contents are undefined after power-up; the engine is held until a program is written.
//
// Simulation: compile with -DFUNCTIONAL and sim/ihp_sram/*.v. Sim-only helpers poke(a,w), peek(a),
// load_hex(file) reach the macro storage, so testbenches need not know how it is built.
module v1_instr_mem #(
    parameter ADDR_WIDTH = 6,       // fixed by the macros: 64 x 32 only
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 64,
    parameter INIT_FILE  = ""       // simulation preload only (macros cannot be preloaded)
)(
    input  wire                  clk,
    // fetch port (engine): addr = next_pc
    input  wire [ADDR_WIDTH-1:0] addr,
    output wire [DATA_WIDTH-1:0] instr,
    // write port (host / management)
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata
);
    wire [5:0] a = we ? waddr : addr;       // host owns the port while writing

    RM_IHPSG13_1P_64x16_c2 u_lo (
        .A_CLK(clk), .A_MEN(1'b1), .A_WEN(we), .A_REN(~we),
        .A_ADDR(a), .A_DIN(wdata[15:0]),  .A_DLY(1'b1), .A_DOUT(instr[15:0]));
    RM_IHPSG13_1P_64x16_c2 u_hi (
        .A_CLK(clk), .A_MEN(1'b1), .A_WEN(we), .A_REN(~we),
        .A_ADDR(a), .A_DIN(wdata[31:16]), .A_DLY(1'b1), .A_DOUT(instr[31:16]));

`ifndef SYNTHESIS
    initial if (ADDR_WIDTH != 6 || DATA_WIDTH != 32 || DEPTH != 64) begin
        $display("ERROR: v1_instr_mem is fixed at 64x32 (got %0dx%0d)", DEPTH, DATA_WIDTH);
        $finish;
    end

    task poke(input integer a, input [31:0] w);
        begin
            u_lo.i_SRAM_1P_behavioral.memory[a] = w[15:0];
            u_hi.i_SRAM_1P_behavioral.memory[a] = w[31:16];
        end
    endtask
    function [31:0] peek(input integer a);
        peek = {u_hi.i_SRAM_1P_behavioral.memory[a], u_lo.i_SRAM_1P_behavioral.memory[a]};
    endfunction
    task load_hex(input [8*256-1:0] f);
        reg [31:0] img [0:63];
        integer k;
        begin
            for (k = 0; k < 64; k = k + 1) img[k] = {32{1'bx}};
            $readmemh(f, img);
            for (k = 0; k < 64; k = k + 1) poke(k, img[k]);
        end
    endtask
    initial if (INIT_FILE != "") load_hex(INIT_FILE);
`endif
endmodule
