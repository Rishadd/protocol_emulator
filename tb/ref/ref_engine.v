// REFERENCE MODEL, do not edit. The original engine fetch: combinational-read flop instruction memory
// addressed with pc (as committed in 42d262a), widened to 8-bit pc / 256 words to match the 256x32 SRAM
// engine. tb_fetch_equiv runs it in lockstep against the current engine_top (synchronous SRAM fetch
// addressed with next_pc) and requires identical behaviour on every output and every clock. Other
// modules (control_unit, fifo, ...) are shared with src/.

// Instruction memory: combinational read (engine fetch), synchronous host write.
// The write port is the only way to load a program on silicon; INIT_FILE is kept for
// simulation and the FPGA tops. Memory bits have no reset (reset clears control, not storage).
// Read-during-write to the same address returns the old word until the clock edge.
module ref_instr_mem #(
    parameter ADDR_WIDTH = 8,
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 256,
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
    parameter WIDTH = 8
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

`include "isa.vh"
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
    input  wire [7:0]  imem_waddr,
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
    output wire [7:0]  pc
);
    wire        core_rst_n = rst_n & run;
    wire [31:0] instr;
    wire        pc_advance, pc_jump;
    wire [7:0]  jump_addr;
    wire        dc_load, dc_last;
    wire [26:0] dc_load_value_cu, dc_load_value;
    wire        lc_load, lc_dec;
    wire [15:0] lc_load_value_cu, lc_load_value, lc_count;
    wire        tx_empty, tx_rd_en;
    wire [31:0] tx_rd_data;
    wire        rx_full, rx_wr_en, push_imm, push_reg;
    // register file / ALU / CRC extension: same shared units as engine_top, so equivalence covers every opcode
    wire        flag_z, flag_n, flag_c, rs_zero;
    wire        alu_go, ldi_go, rget_go, isr_load, osr_from_reg, lc_from_reg, dc_from_reg;
    wire        crc_rst, crc_set_poly, crc_set_init, crc_set_xor, crc_set_fmt, crc_feed_bit, crc_feed_byte, crc_busy;
    wire [31:0] rs_val, crc_value, rget_data, osr_load_value;
    wire        line_go, line_full, line_busy, line_oe, line_dp, line_dm;
    wire [2:0]  line_dp_pin, line_dm_pin, tx_level, rx_level;
    wire [31:0] line_status;
    wire [7:0]  pin_out_c, pin_oe_c;
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

    assign dc_load_value  = dc_from_reg ? rs_val[26:0] : dc_load_value_cu;
    assign lc_load_value  = lc_from_reg ? rs_val[15:0] : lc_load_value_cu;
    assign osr_load_value = osr_from_reg ? rs_val : tx_rd_data;
    assign rget_data = (instr[6:4] == `RG_OSR) ? osr_data :
                       (instr[6:4] == `RG_ISR) ? isr_data :
                       (instr[6:4] == `RG_LC)  ? {16'd0, lc_count} :
                       (instr[6:4] == `RG_PIN) ? {24'd0, pin_in_sync} :
                       (instr[6:4] == `RG_CRC) ? crc_value :
                       (instr[6:4] == `RG_LINE) ? line_status :
                       (instr[6:4] == `RG_FIFO) ? {26'd0, rx_level, tx_level} : tx_rd_data;

    alu_unit alu (
        .clk(clk), .rst_n(core_rst_n), .operand(instr[26:0]),
        .do_alu(alu_go), .do_ldi(ldi_go), .do_rget(rget_go), .rget_data(rget_data),
        .rs_val(rs_val), .rs_zero(rs_zero), .flag_z(flag_z), .flag_n(flag_n), .flag_c(flag_c));

    crc_unit crc (
        .clk(clk), .rst_n(core_rst_n), .rst_crc(crc_rst), .set_poly(crc_set_poly), .set_init(crc_set_init),
        .set_xor(crc_set_xor), .set_fmt(crc_set_fmt), .cfg_data(rs_val), .feed_bit(crc_feed_bit),
        .feed_byte(crc_feed_byte), .din(rs_val[7:0]), .value(crc_value), .busy(crc_busy));

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
        .empty   (tx_empty),
        .level   (tx_level)
    );

    fifo rx_fifo (
        .clk     (clk),
        .rst_n   (rst_n),
        .wr_en   (rx_wr_en),
        .wr_data (push_imm ? {5'd0, instr[26:0]} : push_reg ? rs_val : isr_data),
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

    line_coder line (
        .clk(clk), .rst_n(core_rst_n), .cmd_go(line_go), .cmd_op(instr[26:24]), .cmd_data(rs_val), .full(line_full), .busy(line_busy),
        .rd_pop(rget_go && instr[6:4] == `RG_LINE), .status(line_status), .dp_in(pin_in_sync[line_dp_pin]), .dm_in(pin_in_sync[line_dm_pin]),
        .dp_pin(line_dp_pin), .dm_pin(line_dm_pin), .tx_oe(line_oe), .tx_dp(line_dp), .tx_dm(line_dm));
    genvar gi;
    generate for (gi = 0; gi < 8; gi = gi + 1) begin : g_line
        wire is_dp = line_oe && (line_dp_pin == gi);
        wire is_dm = line_oe && (line_dm_pin == gi);
        assign pin_oe[gi]  = pin_oe_c[gi] | is_dp | is_dm;
        assign pin_out[gi] = is_dp ? line_dp : is_dm ? line_dm : pin_out_c[gi];
    end endgenerate

    control_unit cu (
        .clk           (clk),
        .rst_n         (core_rst_n),
        .instr         (instr),
        .pc_advance    (pc_advance),
        .pc_jump       (pc_jump),
        .jump_addr     (jump_addr),
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
        .flag_z(flag_z), .flag_n(flag_n), .flag_c(flag_c), .rs_zero(rs_zero),
        .alu_go(alu_go), .ldi_go(ldi_go), .rget_go(rget_go), .isr_load(isr_load),
        .osr_from_reg(osr_from_reg), .lc_from_reg(lc_from_reg), .dc_from_reg(dc_from_reg),
        .crc_rst(crc_rst), .crc_set_poly(crc_set_poly), .crc_set_init(crc_set_init), .crc_set_xor(crc_set_xor),
        .crc_set_fmt(crc_set_fmt), .crc_feed_bit(crc_feed_bit), .crc_feed_byte(crc_feed_byte), .crc_busy(crc_busy),
        .line_go(line_go), .line_full(line_full), .line_busy(line_busy),
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
