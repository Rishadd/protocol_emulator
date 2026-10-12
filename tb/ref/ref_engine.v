// REFERENCE MODEL, do not edit. The engine exactly as committed in 42d262a (before the SRAM macros):
// combinational-read flop instruction memory addressed with pc. tb_fetch_equiv runs it in lockstep
// against the current engine_top (synchronous SRAM fetch addressed with next_pc) and requires
// identical behaviour on every output and every clock. The control unit is the frozen pre-two-tier
// copy v1_control_unit (tb/ref/ref_engine_v1.v, compile both); fifo, shift_reg, ... are shared with
// src/ because they did not change. Generated with:
//   git show 42d262a:src/{instr_mem,pc_reg,engine_top}.v  + module renames (ref_ prefix)

// Instruction memory: combinational read (engine fetch), synchronous host write.
// The write port is the only way to load a program on silicon; INIT_FILE is kept for
// simulation and the FPGA tops. Memory bits have no reset (reset clears control, not storage).
// Read-during-write to the same address returns the old word until the clock edge.
module ref_instr_mem #(
    parameter ADDR_WIDTH = 6,
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 64,
    parameter INIT_FILE  = ""
)(
    input  wire                  clk,
    // read port (engine fetch)
    input  wire [ADDR_WIDTH-1:0] addr,
    output wire [DATA_WIDTH-1:0] instr,
    // write port (host / management)
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata
);
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    generate if (INIT_FILE != "") begin : g_init
        initial $readmemh(INIT_FILE, mem);
    end endgenerate

    always @(posedge clk)
        if (we) mem[waddr] <= wdata;

    assign instr = mem[addr];
endmodule

// Program counter: holds at current value unless told to advance or jump.
module ref_pc_reg #(
    parameter WIDTH = 6
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             advance,
    input  wire             jump,
    input  wire [WIDTH-1:0] jump_addr,
    output reg  [WIDTH-1:0] pc
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= {WIDTH{1'b0}};
        else if (jump) //jump given more priority than advance
            pc <= jump_addr;
        else if (advance)
            pc <= pc + 1'b1;
    end
endmodule

// Single protocol engine: instr_mem + pc_reg + delay_counter + loop_counter
// + control_unit + tx/rx fifo + OSR/ISR shift registers + 8-pin block.
// In a testbench: $readmemh("program.hex", <inst>.imem.mem);
// run=0 holds the execution core (PC, control, counters, shifters, pins) in reset:
// PC=0, pins released. FIFOs and instruction memory keep their contents.
// run must come from a flop (it gates an asynchronous reset).
module ref_engine_top #(
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
    wire [5:0]  jump_addr;
    wire        dc_load, dc_last;
    wire [26:0] dc_load_value;
    wire        lc_load, lc_dec;
    wire [15:0] lc_load_value, lc_count;
    wire        tx_empty, tx_rd_en;
    wire [31:0] tx_rd_data;
    wire        rx_full, rx_wr_en;
    wire        osr_load, osr_shift, osr_bit;
    wire [31:0] osr_data, isr_data;
    wire        isr_shift, isr_clear;
    wire        pin_wr, pin_wr_val, dir_wr, dir_wr_val;
    wire [2:0]  pin_wr_idx, dir_wr_idx;
    wire [7:0]  pin_in_sync;
    wire [2:0]  cfg_out_pin, cfg_in_pin;
    wire        cfg_osr_msb, cfg_isr_msb;

    ref_instr_mem #(.INIT_FILE(INIT_FILE)) imem (
        .clk   (clk),
        .addr  (pc),
        .instr (instr),
        .we    (imem_we),
        .waddr (imem_waddr),
        .wdata (imem_wdata)
    );

    ref_pc_reg pc_i (
        .clk       (clk),
        .rst_n     (core_rst_n),
        .advance   (pc_advance),
        .jump      (pc_jump),
        .jump_addr (jump_addr),
        .pc        (pc)
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
        .rd_en   (tx_rd_en),
        .rd_data (tx_rd_data),
        .empty   (tx_empty)
    );

    fifo rx_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (rx_wr_en),
        .wr_data (isr_data),
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
