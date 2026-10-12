// Single protocol engine: instr_mem + pc_reg + delay_counter + loop_counter
// + control_unit + tx/rx fifo + OSR/ISR shift registers + 8-pin block.
// Fetch: instr_mem has a synchronous read (SRAM macros) and is addressed with pc_reg.next_pc,
// so instr always holds the word for the current pc. The pc is 9 bits (isa.vh): L1 holds 0x000-0x03F,
// any other pc faults (cause 1) before it executes. In a testbench use <inst>.imem.poke(a,w) /
// .load_hex("program.hex") (not a hierarchical array write).
// run=0 holds the execution core (PC, control, counters, shifters, pins) in reset:
// PC=0, pins released. FIFOs and instruction memory keep their contents.
// run must come from a flop (it gates an asynchronous reset).
module engine_top #(
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
    output wire [1:0]  fault_cause,
    output wire [8:0]  pc
);
    wire        core_rst_n = rst_n & run;
    wire [31:0] instr;
    wire        pc_advance, pc_jump;
    wire [8:0]  jump_addr, next_pc;
    wire [1:0]  pc_fault = (pc[8:6] != 3'd0) ? 2'd1 : 2'd0;   // only L1 exists
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
    // edge), and control_unit decodes whatever instr holds. tx_rd_en / rx_wr_en are the only
    // control_unit outputs that reach state outside the reset core (the FIFOs), so they are
    // masked with core_rst_n; everything else sits behind core_rst_n's asynchronous reset.
    instr_mem #(.INIT_FILE(INIT_FILE)) imem (
        .clk   (clk),
        .addr  (next_pc[5:0]),
        .instr (instr),
        .we    (imem_we),
        .waddr (imem_waddr),
        .wdata (imem_wdata)
    );

    pc_reg #(.WIDTH(9)) pc_i (
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

    control_unit cu (
        .clk           (clk),
        .rst_n         (core_rst_n),
        .instr         (instr),
        .pc_fault      (pc_fault),
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
        .fault         (fault),
        .fault_cause   (fault_cause)
    );
endmodule
