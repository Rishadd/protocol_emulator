// Single protocol engine: instr_mem + pc_reg + delay_counter + loop_counter
// + control_unit + tx/rx fifo + OSR/ISR shift registers + 8-pin block.
// Fetch: instr_mem (256 x 32, one SRAM macro) has a synchronous read and is addressed with pc_reg.next_pc,
// so instr always holds the word for the current pc. In a testbench use <inst>.imem.poke(a,w) /
// .load_hex("program.hex") (not a hierarchical array write).
// run=0 holds the execution core (PC, control, counters, shifters, pins) in reset:
// PC=0, pins released. FIFOs and instruction memory keep their contents.
// run must come from a flop (it gates an asynchronous reset).
`include "isa.vh"
module engine_top #(
    parameter INIT_FILE = ""
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        run,
    // host -> instruction memory (management write port); unused with SHARED_IMEM (imem_shared owns the writes)
    input  wire        imem_we,
    input  wire [7:0]  imem_waddr,
    input  wire [31:0] imem_wdata,
`ifdef SHARED_IMEM
    // fetch port of the shared instruction memory: im_addr = next_pc (region relative), im_instr arrives one clock later
    output wire [8:0]  im_addr,
    input  wire [31:0] im_instr,
    input  wire        im_oob,          // the word lies outside the window: decode TRAP instead (opcode 31, a fault)
    // OP_REGION: window request to imem_shared and the window's lock
    output wire        rg_go,
    output wire [18:0] rg_val,
    input  wire        rg_locked,
    // START: the program counter's reset value (host register, written while held; mgmt.v)
    input  wire [8:0]  start_pc,
`endif
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
    output wire [8:0]  pc               // bit 8 is 0 unless SHARED_IMEM
);
`ifdef SHARED_IMEM
    localparam PC_W = 9;
`else
    localparam PC_W = 8;
`endif
    wire        core_rst_n = rst_n & run;
    wire [31:0] instr;
    wire        pc_advance, pc_jump;
    wire [8:0]  jump_addr;
    wire [PC_W-1:0] next_pc, pc_r;
    wire        dc_load, dc_last;
    wire [26:0] dc_load_value_cu, dc_load_value;
    wire        lc_load, lc_dec;
    wire [15:0] lc_load_value_cu, lc_load_value, lc_count;
    wire        tx_empty, tx_rd_en;
    wire [31:0] tx_rd_data;
    wire        rx_full, rx_wr_en, push_imm, push_reg;
    // register file / ALU / CRC extension
    wire        flag_z, flag_n, flag_c, rs_zero;
    wire        alu_go, ldi_go, rget_go, isr_load, osr_from_reg, lc_from_reg, dc_from_reg;
    wire        crc_rst, crc_set_poly, crc_set_init, crc_set_xor, crc_set_fmt, crc_feed_bit, crc_feed_byte, crc_busy;
    wire        line_go, line_full, line_busy, line_oe, line_dp, line_dm;
    wire [2:0]  line_dp_pin, line_dm_pin;
    wire [31:0] line_status;
    wire [2:0]  tx_level, rx_level;                 // FIFO occupancy for RGET FIFO
    wire [7:0]  pin_out_c, pin_oe_c;                // pin block outputs, before the line coder takes over its two pins
    wire [31:0] rs_val, crc_value, rget_data, osr_load_value;
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
`ifdef SHARED_IMEM
    assign instr   = im_oob ? {5'd31, 27'd0} : im_instr;
    assign im_addr = next_pc;
    assign rg_val  = instr[18:0];           // OP_REGION operand (valid only with rg_go)
    wire _unused_imem = &{imem_we, imem_waddr, imem_wdata, INIT_FILE != "", 1'b0};
`else
    instr_mem #(.INIT_FILE(INIT_FILE)) imem (
        .clk   (clk),
        .addr  (next_pc),
        .instr (instr),
        .we    (imem_we),
        .waddr (imem_waddr),
        .wdata (imem_wdata)
    );
`endif

`ifndef SHARED_IMEM
    wire [PC_W-1:0] start_pc = {PC_W{1'b0}};       // the default build always starts at 0
`endif
    pc_reg #(.WIDTH(PC_W)) pc_i (
        .clk       (clk),
        .rst_n     (core_rst_n),
        .advance   (pc_advance),
        .jump      (pc_jump),
        .jump_addr (jump_addr[PC_W-1:0]),
        .start     (start_pc[PC_W-1:0]),
        .pc        (pc_r),
        .next_pc   (next_pc)
    );
    assign pc = pc_r;                   // zero-extended when PC_W = 8

    // register-sourced values for the counters / shifters (RPUT, WAITR) instead of the instruction operand / TX FIFO word
    assign dc_load_value  = dc_from_reg ? rs_val[26:0] : dc_load_value_cu;
    assign lc_load_value  = lc_from_reg ? rs_val[15:0] : lc_load_value_cu;
    assign osr_load_value = osr_from_reg ? rs_val : tx_rd_data;
    assign rget_data = (instr[6:4] == `RG_OSR) ? osr_data :
                       (instr[6:4] == `RG_ISR) ? isr_data :
                       (instr[6:4] == `RG_LC)  ? {16'd0, lc_count} :
                       (instr[6:4] == `RG_PIN) ? {24'd0, pin_in_sync} :
                       (instr[6:4] == `RG_CRC) ? crc_value :
                       (instr[6:4] == `RG_LINE) ? line_status :
                       (instr[6:4] == `RG_FIFO) ? {26'd0, rx_level, tx_level} : tx_rd_data;   // RG_TXF

    alu_unit alu (
        .clk       (clk),
        .rst_n     (core_rst_n),
        .operand   (instr[26:0]),
        .do_alu    (alu_go),
        .do_ldi    (ldi_go),
        .do_rget   (rget_go),
        .rget_data (rget_data),
        .rs_val    (rs_val),
        .rs_zero   (rs_zero),
        .flag_z    (flag_z),
        .flag_n    (flag_n),
        .flag_c    (flag_c)
    );

    crc_unit crc (
        .clk       (clk),
        .rst_n     (core_rst_n),
        .rst_crc   (crc_rst),
        .set_poly  (crc_set_poly),
        .set_init  (crc_set_init),
        .set_xor   (crc_set_xor),
        .set_fmt   (crc_set_fmt),
        .cfg_data  (rs_val),
        .feed_bit  (crc_feed_bit),
        .feed_byte (crc_feed_byte),
        .din       (rs_val[7:0]),
        .value     (crc_value),
        .busy      (crc_busy)      // a CRC command executes one clock after its instruction: RGET CRC waits for it
    );

    line_coder line (
        .clk       (clk),
        .rst_n     (core_rst_n),
        .cmd_go    (line_go),
        .cmd_op    (instr[26:24]),
        .cmd_data  (rs_val),
        .full      (line_full),
        .busy      (line_busy),
        .rd_pop    (rget_go && instr[6:4] == `RG_LINE),
        .status    (line_status),
        .dp_in     (pin_in_sync[line_dp_pin]),
        .dm_in     (pin_in_sync[line_dm_pin]),
        .dp_pin    (line_dp_pin),
        .dm_pin    (line_dm_pin),
        .tx_oe     (line_oe),
        .tx_dp     (line_dp),
        .tx_dm     (line_dm)
    );

    // while the coder transmits it drives its two logical pins; otherwise the pin block's values pass through
    genvar gi;
    generate for (gi = 0; gi < 8; gi = gi + 1) begin : g_line
        wire is_dp = line_oe && (line_dp_pin == gi);
        wire is_dm = line_oe && (line_dm_pin == gi);
        assign pin_oe[gi]  = pin_oe_c[gi] | is_dp | is_dm;
        assign pin_out[gi] = is_dp ? line_dp : is_dm ? line_dm : pin_out_c[gi];
    end endgenerate

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
        .empty   (tx_empty),
        .level   (tx_level)
    );

    fifo rx_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (rx_wr_en & core_rst_n),
        .wr_data (push_imm ? {5'd0, instr[26:0]} : push_reg ? rs_val : isr_data),   // PUSHI immediate, RPUT register or ISR
        .full    (rx_full),
        .rd_en   (rx_rd_en),
        .rd_data (rx_rd_data),
        .empty   (rx_empty),
        .level   (rx_level)
    );

    shift_reg osr (
        .clk        (clk),
        .rst_n      (core_rst_n),
        .msb_first  (cfg_osr_msb),
        .load       (osr_load),
        .load_value (osr_load_value),
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
        .load       (isr_load),
        .load_value (rs_val),
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
        .pin_out     (pin_out_c),
        .pin_oe      (pin_oe_c),
        .pin_in_sync (pin_in_sync)
    );

    control_unit cu (
        .clk           (clk),
        .rst_n         (core_rst_n),
        .instr         (instr),
        .pc_advance    (pc_advance),
        .pc_jump       (pc_jump),
        .jump_addr     (jump_addr),
`ifdef SHARED_IMEM
        .region_locked (rg_locked),
        .region_go     (rg_go),
`endif
        .dc_load       (dc_load),
        .dc_load_value (dc_load_value_cu),
        .dc_last       (dc_last),
        .lc_load       (lc_load),
        .lc_dec        (lc_dec),
        .lc_load_value (lc_load_value_cu),
        .lc_count      (lc_count),
        .tx_empty      (tx_empty),
        .tx_rd_en      (tx_rd_en),
        .rx_full       (rx_full),
        .rx_wr_en      (rx_wr_en),
        .push_imm      (push_imm),
        .push_reg      (push_reg),
        .flag_z        (flag_z),
        .flag_n        (flag_n),
        .flag_c        (flag_c),
        .rs_zero       (rs_zero),
        .alu_go        (alu_go),
        .ldi_go        (ldi_go),
        .rget_go       (rget_go),
        .isr_load      (isr_load),
        .osr_from_reg  (osr_from_reg),
        .lc_from_reg   (lc_from_reg),
        .dc_from_reg   (dc_from_reg),
        .crc_rst       (crc_rst),
        .crc_set_poly  (crc_set_poly),
        .crc_set_init  (crc_set_init),
        .crc_set_xor   (crc_set_xor),
        .crc_set_fmt   (crc_set_fmt),
        .crc_feed_bit  (crc_feed_bit),
        .crc_feed_byte (crc_feed_byte),
        .crc_busy      (crc_busy),
        .line_go       (line_go),
        .line_full     (line_full),
        .line_busy     (line_busy),
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
