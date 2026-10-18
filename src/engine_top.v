// Single protocol engine: instr_mem + fetch_unit + delay_counter + loop_counter
// + control_unit + tx/rx fifo + OSR/ISR shift registers + 8-pin block.
// Fetch: instr_mem (256 x 32, one SRAM macro, synchronous read) feeds fetch_unit, which registers the word in the instruction
// register (instr below) and resolves branches one clock early from the next-state values of the state they test, so instruction
// timing is unchanged (fetch_unit.v). In a testbench use <inst>.imem.poke(a,w) / .load_hex("program.hex") (not a hierarchical
// array write); a poke while the engine is held primes the fetch stage again.
// run=0 holds the execution core (PC, control, counters, shifters, pins) in reset:
// PC=0, pins released. FIFOs and instruction memory keep their contents. The core also stays held until the fetch stage is primed
// (2 clocks after reset, after a memory write or after run fell), so run should rise 2 or more clocks after the last write.
// run must come from a flop (it gates an asynchronous reset).
`include "isa.vh"
module engine_top #(
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
    wire        fetch_ready;
    wire        core_rst_n = rst_n & run & fetch_ready;
    wire [31:0] instr, sram_dout;
    wire        pc_advance, pc_jump;
    wire [7:0]  jump_addr, fetch_addr, ir_pc;
    wire        dc_load, dc_last;
    wire [26:0] dc_load_value_cu, dc_load_value;
    wire        lc_load, lc_dec;
    wire [15:0] lc_load_value_cu, lc_load_value, lc_count, lc_count_next;
    wire        flag_z_next, flag_n_next, flag_c_next, cfg_osr_msb_next;
    wire [31:0] osr_data_next;
    wire [7:0]  pin_in_sync_next;
    wire        tx_empty, tx_rd_en;
    wire [31:0] tx_rd_data;
    wire        rx_full, rx_wr_en, push_imm, push_reg;
    // register file / ALU / CRC extension
    wire        flag_z, flag_n, flag_c, rs_zero;
    wire        alu_go, ldi_go, rget_go, isr_load, osr_from_reg, lc_from_reg, dc_from_reg;
    wire        crc_rst, crc_set_poly, crc_set_init, crc_set_xor, crc_set_fmt, crc_feed_bit, crc_feed_byte, crc_busy;
    wire [31:0] rs_val, crc_value, rget_data, osr_load_value;
    wire        osr_load, osr_shift, osr_bit;
    wire [31:0] osr_data, isr_data;
    wire        isr_shift, isr_clear;
    wire        pin_wr, pin_wr_val, dir_wr, dir_wr_val;
    wire [2:0]  pin_wr_idx, dir_wr_idx;
    wire [7:0]  pin_in_sync;
    wire [2:0]  cfg_out_pin, cfg_in_pin;
    wire        cfg_osr_msb, cfg_isr_msb;

    // Held engine (core_rst_n=0): control_unit decodes whatever the instruction register holds. tx_rd_en / rx_wr_en are the only
    // control_unit outputs that reach state outside the reset core (the FIFOs), so they are masked with core_rst_n; everything
    // else sits behind core_rst_n's asynchronous reset.
    instr_mem #(.INIT_FILE(INIT_FILE)) imem (
        .clk   (clk),
        .addr  (fetch_addr),
        .instr (sram_dout),
        .we    (imem_we),
        .waddr (imem_waddr),
        .wdata (imem_wdata)
    );

    fetch_unit fe (
        .clk          (clk),
        .rst_n        (rst_n),
        .run          (run),
        .imem_we      (imem_we),
        .dout         (sram_dout),
        .addr         (fetch_addr),
        .ir           (instr),
        .ir_pc        (ir_pc),
        .ready        (fetch_ready),
        .x_done       (pc_advance | pc_jump),
        .lc           (lc_count),    .lc_next      (lc_count_next),
        .flag_z       (flag_z),      .flag_z_next  (flag_z_next),
        .flag_n       (flag_n),      .flag_n_next  (flag_n_next),
        .flag_c       (flag_c),      .flag_c_next  (flag_c_next),
        .osr_bit      (osr_bit),     .osr_bit_next (cfg_osr_msb_next ? osr_data_next[31] : osr_data_next[0]),
        .pins         (pin_in_sync), .pins_next    (pin_in_sync_next)
    );
    assign pc = core_rst_n ? ir_pc : 8'd0;

`ifndef SYNTHESIS
    // The fetch stage resolved every branch one clock early; it must agree with the control unit's own decision for the same
    // instruction (pc_jump / pc_advance). fetch_mismatches counts disagreements (testbenches may check it; it also prints).
    integer fetch_mismatches = 0;
    always @(posedge clk) begin
        if (core_rst_n && (pc_advance || pc_jump) && fe.fetch_pc !== (pc_jump ? jump_addr : ir_pc + 8'd1)) begin
            fetch_mismatches = fetch_mismatches + 1;
            if (fetch_mismatches <= 5)
                $display("FETCH MISMATCH %m t=%0t: pc %0d fetched %0d, control unit goes to %0d", $time, ir_pc, fe.fetch_pc,
                         pc_jump ? jump_addr : ir_pc + 8'd1);
        end
    end
    // a testbench poke while the engine is held: prime again from word 0 (real writes come through imem_we)
    always @(imem.poke_count) if (!(run && fetch_ready)) fe.phase = 2'd0;
`endif

    // register-sourced values for the counters / shifters (RPUT, WAITR) instead of the instruction operand / TX FIFO word
    assign dc_load_value  = dc_from_reg ? rs_val[26:0] : dc_load_value_cu;
    assign lc_load_value  = lc_from_reg ? rs_val[15:0] : lc_load_value_cu;
    assign osr_load_value = osr_from_reg ? rs_val : tx_rd_data;
    assign rget_data = (instr[6:4] == `RG_OSR) ? osr_data :
                       (instr[6:4] == `RG_ISR) ? isr_data :
                       (instr[6:4] == `RG_LC)  ? {16'd0, lc_count} :
                       (instr[6:4] == `RG_PIN) ? {24'd0, pin_in_sync} :
                       (instr[6:4] == `RG_CRC) ? crc_value : tx_rd_data;   // RG_TXF

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
        .flag_c    (flag_c),
        .flag_z_next (flag_z_next),
        .flag_n_next (flag_n_next),
        .flag_c_next (flag_c_next)
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
        .count      (lc_count),
        .count_next (lc_count_next)
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
        .wr_data (push_imm ? {5'd0, instr[26:0]} : push_reg ? rs_val : isr_data),   // PUSHI immediate, RPUT register or ISR
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
        .load_value (osr_load_value),
        .clear      (1'b0),
        .shift_out  (osr_shift),
        .shift_in   (1'b0),
        .in_bit     (1'b0),
        .data       (osr_data),
        .data_next  (osr_data_next),
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
        .data_next  (),
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
        .pin_in_sync (pin_in_sync),
        .pin_in_sync_next (pin_in_sync_next)
    );

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
        .cfg_osr_msb_next (cfg_osr_msb_next),
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
