// Single protocol engine: instr_mem + pc_reg + delay_counter + loop_counter
// + control_unit + tx/rx fifo + OSR/ISR shift registers + 8-pin block.
// Fetch: instr_mem has a synchronous read (SRAM macros) and is addressed with pc_reg.next_pc,
// so instr always holds the word for the current pc. The pc is 9 bits (isa.vh): L1 holds 0x000-0x03F,
// any other pc faults (cause 1) before it executes. In a testbench use <inst>.imem.poke(a,w) /
// .load_hex("program.hex") (not a hierarchical array write).
// Two-tier memory (docs/TWO_TIER_MEMORY_PLAN.md, L2_EN = 1): a pc in 0x100-0x1FF fetches word pc[7:0]
// of the shared L2 through l2_req/l2_gnt (urgent: same clock, mode A); the word arrives on l2_rdata one
// clock later and is kept in ir2 while the pc stays. A clock without the word is a bubble (nothing
// happens). An L2 pc outside l2_range faults (cause 2). L1 fetches are never delayed.
// run=0 holds the execution core (PC, control, counters, shifters, pins) in reset:
// PC=reset_pc, pins released. FIFOs and instruction memory keep their contents.
// run must come from a flop (it gates an asynchronous reset).
module engine_top #(
    parameter INIT_FILE = "",
    parameter L2_EN     = 1
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
    // two-tier memory: configuration (written only while held) and the shared L2 port
    input  wire [8:0]  reset_pc,
    input  wire [15:0] l2_range,         // {hi, lo}
    input  wire [1:0]  fetch_cfg,        // [0] prefetch buffer enable
    output wire        l2_req,
    output wire        l2_req_hi,        // class 2 (urgent)
    output wire [7:0]  l2_addr,
    input  wire        l2_gnt,
    input  wire [31:0] l2_rdata,
    output wire        bubble,
    // status
    output wire        halted,
    output wire        fault,
    output wire [1:0]  fault_cause,
    output wire [8:0]  pc
`ifdef FORMAL
    ,                                    // formal harness only: the instruction word and L1 writes
    output wire [31:0] f_instr,
    output wire        f_valid,
    output wire        f_l1_we,
    output wire [5:0]  f_l1_wa,
    output wire [31:0] f_l1_wd
`endif
);
    wire        core_rst_n = rst_n & run;
    wire [31:0] instr;
    wire        pc_advance, pc_jump;
    wire [8:0]  jump_addr, next_pc;
    wire [7:0]  lo = l2_range[7:0], hi = l2_range[15:8];
    wire [1:0]  pc_fault = !pc[8] ? (pc[7:6] != 2'd0 ? 2'd1 : 2'd0) :   // reserved 0x040-0x0FF
                           !L2_EN ? 2'd1 : (pc[7:0] < lo || pc[7:0] > hi) ? 2'd2 : 2'd0;
    wire [31:0] l1_out;                 // L1 macro output
    wire        cu_bubble;
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
        .instr (l1_out),
        .we    (imem_we),
        .waddr (imem_waddr),
        .wdata (imem_wdata)
    );

    // ---- fetch: pc in L1 -> the L1 macro (exact, as before); pc in L2 -> the shared L2 port
    reg  [31:0] ir2;                    // L2 word of the current pc
    reg         got, ir2_ok;            // got: l2_rdata holds it this clock (granted last clock)
    // prefetch buffer PB (fetch_cfg[0]): while the current word waits (held or blocked), fetch pc+1.
    // Tagged with its address, so it is only used for that pc. pend: its word is on l2_rdata now.
    // A request that lost once (lost) is promoted to class 2 so it cannot starve.
    reg         pb_ok, pend, lost;
    reg  [8:0]  pb_a;
    reg  [31:0] pb;
    wire        waiting;
    wire [8:0]  pc1    = pc + 9'd1;
    wire        pb_has = pb_ok || pend;
    wire [31:0] pb_w   = pend ? l2_rdata : pb;
    wire [31:0] w2 = got ? l2_rdata : ir2;
    wire        instr_valid = !pc[8] || got || ir2_ok;
    assign instr = pc[8] ? w2 : l1_out;
    wire keep = pc[8] && instr_valid && (next_pc == pc);                 // same word next clock
    wire pb_hit = pb_has && (pb_a == next_pc) && next_pc[8];
    wire need = L2_EN && core_rst_n && !halted && next_pc[8] && !keep && !pb_hit;   // urgent fetch of next_pc
    wire pf   = L2_EN && core_rst_n && fetch_cfg[0] && waiting && pc[8] && pc1[8] && !(pb_has && pb_a == pc1);
    assign l2_req    = need || pf;
    assign l2_req_hi = need || lost;
    assign l2_addr   = need ? next_pc[7:0] : pc1[7:0];
    always @(posedge clk or negedge core_rst_n) begin
        if (!core_rst_n) begin
            ir2 <= 32'd0; got <= 1'b0; ir2_ok <= 1'b0;
            pb <= 32'd0; pb_a <= 9'd0; pb_ok <= 1'b0; pend <= 1'b0; lost <= 1'b0;
        end else begin
            ir2 <= (pb_hit && !keep) ? pb_w : w2; got <= need && l2_gnt; ir2_ok <= keep || pb_hit;
            lost <= l2_req && !l2_gnt;
            pend <= pf && l2_gnt;
            if (pend) begin pb <= l2_rdata; pb_ok <= 1'b1; end
            if (pf && l2_gnt) begin pb_a <= pc1; pb_ok <= 1'b0; end
        end
    end

`ifdef FORMAL
    assign {f_instr, f_valid} = {instr, instr_valid};
    assign {f_l1_we, f_l1_wa, f_l1_wd} = {1'b0, 6'd0, 32'd0};    // COPY writes: Phase 5
    // F5: an L1 pc never waits for its word; F9: a held engine asks for nothing and keeps no L2 word
    always @(*) if (rst_n) begin
        if (!pc[8]) assert (instr_valid);
        if (!core_rst_n) assert (!l2_req && !got && !ir2_ok);
    end
`endif

    pc_reg #(.WIDTH(9)) pc_i (
        .clk       (clk),
        .rst_n     (core_rst_n),
        .rst_val   (L2_EN ? reset_pc : 9'd0),
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
        .instr_valid   (instr_valid),
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
        .fault_cause   (fault_cause),
        .bubble        (cu_bubble),
        .waiting       (waiting)
    );
    assign bubble = core_rst_n && cu_bubble;   // a held engine is not bubbling
endmodule
