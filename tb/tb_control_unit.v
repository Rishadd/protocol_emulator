`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// control_unit + real delay_counter + real loop_counter; fifos/pins/shifters are
// modelled by directly driving tx_empty / rx_full / pin_in / osr_bit.
module tb_control_unit;
    reg         clk = 0, rst_n = 0;
    reg  [31:0] instr = 0;
    reg         tx_empty = 1, rx_full = 0, osr_bit = 1;
    reg  [7:0]  pin_in = 0;
    reg  [1:0]  pc_fault = 0;
    wire [1:0]  fault_cause;

    wire        pc_advance, pc_jump, dc_load, lc_load, lc_dec, tx_rd_en, rx_wr_en;
    wire        osr_load, osr_shift, isr_shift, isr_clear, pin_wr, dir_wr;
    wire        pin_wr_val, dir_wr_val, halted, fault, dc_busy, dc_last, push_imm;
    wire [8:0]  jump_addr;
    wire [26:0] dc_load_value;
    wire [15:0] lc_load_value, lc_count;
    wire [2:0]  pin_wr_idx, dir_wr_idx, cfg_out_pin, cfg_in_pin;
    wire        cfg_osr_msb, cfg_isr_msb;

    integer errors = 0, k, p, lv, tk;
    reg [8:0] a;

    control_unit dut (
        .clk(clk), .rst_n(rst_n), .instr(instr), .pc_fault(pc_fault),
        .pc_advance(pc_advance), .pc_jump(pc_jump), .jump_addr(jump_addr),
        .dc_load(dc_load), .dc_load_value(dc_load_value), .dc_last(dc_last),
        .lc_load(lc_load), .lc_dec(lc_dec), .lc_load_value(lc_load_value), .lc_count(lc_count),
        .tx_empty(tx_empty), .tx_rd_en(tx_rd_en), .rx_full(rx_full), .rx_wr_en(rx_wr_en), .push_imm(push_imm),
        .osr_load(osr_load), .osr_shift(osr_shift), .osr_bit(osr_bit),
        .isr_shift(isr_shift), .isr_clear(isr_clear),
        .pin_wr(pin_wr), .pin_wr_idx(pin_wr_idx), .pin_wr_val(pin_wr_val),
        .dir_wr(dir_wr), .dir_wr_idx(dir_wr_idx), .dir_wr_val(dir_wr_val), .pin_in(pin_in),
        .cfg_out_pin(cfg_out_pin), .cfg_in_pin(cfg_in_pin),
        .cfg_osr_msb(cfg_osr_msb), .cfg_isr_msb(cfg_isr_msb),
        .halted(halted), .fault(fault), .fault_cause(fault_cause));

    delay_counter dc (.clk(clk), .rst_n(rst_n), .load(dc_load), .load_value(dc_load_value),
                      .busy(dc_busy), .last(dc_last));
    loop_counter  lc (.clk(clk), .rst_n(rst_n), .load(lc_load), .load_value(lc_load_value),
                      .dec(lc_dec), .count(lc_count));

    // all one-bit control strobes packed so a single compare proves "this and nothing else"
    wire [12:0] ctl = {pc_advance, pc_jump, dc_load, lc_load, lc_dec, tx_rd_en, rx_wr_en,
                       osr_load, osr_shift, isr_shift, isr_clear, pin_wr, dir_wr};
    localparam [12:0] ADV = 13'b1_0000_0000_0000, JMP = 13'b0_1000_0000_0000,
                      DCL = 13'b0_0100_0000_0000, LCL = 13'b0_0010_0000_0000,
                      LCD = 13'b0_0001_0000_0000, TXR = 13'b0_0000_1000_0000,
                      RXW = 13'b0_0000_0100_0000, OSL = 13'b0_0000_0010_0000,
                      OSS = 13'b0_0000_0001_0000, ISS = 13'b0_0000_0000_1000,
                      ISC = 13'b0_0000_0000_0100, PW  = 13'b0_0000_0000_0010,
                      DW  = 13'b0_0000_0000_0001, NONE = 13'd0;

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask
    task set(input [4:0] op, input [26:0] opnd); begin instr = {op, opnd}; #2; end endtask
    task do_reset; begin rst_n = 0; set(`OP_NOP, 0); tick; rst_n = 1; end endtask

    // timed instruction: first-cycle strobes `first`, then silence, then ADV exactly on cycle d
    task hold_test(input [4:0] op, input [26:0] d, input [12:0] first, input [80*8-1:0] name);
        begin
            set(op, d);
            `CHECK(ctl == (first | (d == 0 ? ADV : NONE)), name)
            tick;
            for (k = 1; k <= d; k = k + 1) begin
                `CHECK(ctl == (k == d ? ADV : NONE), name)
                tick;
            end
        end
    endtask

    initial begin
        do_reset;
        `CHECK(halted == 0 && fault == 0, "A7 reset status")

        set(`OP_NOP, 0);
        `CHECK(ctl == ADV, "A7 NOP") tick;

        set(`OP_JMP, 5);
        `CHECK(ctl == JMP && jump_addr == 5, "A7 JMP") tick;

        set(`OP_SETL, 8);
        `CHECK(ctl == (ADV | LCL) && lc_load_value == 8, "A7 SETL") tick;
        `CHECK(lc_count == 8, "A7 SETL loaded")

        set(`OP_DJNZ, 2);
        for (k = 0; k < 7; k = k + 1) begin
            `CHECK(ctl == (JMP | LCD) && jump_addr == 2, "A7 DJNZ jumps while count>1") tick;
        end
        `CHECK(lc_count == 1, "A7 DJNZ count before last")
        `CHECK(ctl == (ADV | LCD), "A7 DJNZ falls through on last") tick;
        `CHECK(lc_count == 0, "A7 DJNZ final count 0")

        tx_empty = 1; set(`OP_PULL, 0);
        `CHECK(ctl == NONE, "A7 PULL stalls on empty") tick; tick;
        `CHECK(ctl == NONE, "A7 PULL keeps stalling")
        tx_empty = 0; #1;
        `CHECK(ctl == (ADV | TXR | OSL), "A7 PULL fires when data present") tick;

        rx_full = 1; set(`OP_PUSH, 0);
        `CHECK(ctl == NONE, "A7 PUSH stalls on full") tick;
        rx_full = 0; #1;
        `CHECK(ctl == (ADV | RXW | ISC) && push_imm == 0, "A7 PUSH fires when space, pushes the ISR") tick;

        // PUSHI: like PUSH but writes the operand (push_imm) and leaves the ISR alone (no ISC)
        rx_full = 1; set(`OP_PUSHI, 27'h4000003);
        `CHECK(ctl == NONE && push_imm == 0, "A7 PUSHI stalls on full") tick;
        rx_full = 0; #1;
        `CHECK(ctl == (ADV | RXW) && push_imm == 1, "A7 PUSHI fires when space, immediate, ISR kept") tick;

        // JPO: consumes one OSR bit, jumps if it is 1; one cycle either way
        osr_bit = 1; set(`OP_JPO, 12);
        `CHECK(ctl == (JMP | OSS) && jump_addr == 12, "A7 JPO taken on 1, shifts OSR") tick;
        osr_bit = 0; #1;
        `CHECK(ctl == (ADV | OSS), "A7 JPO falls through on 0, shifts OSR") tick;
        osr_bit = 1;

        osr_bit = 1;
        hold_test(`OP_OUT1, 0, PW | OSS | DCL, "A7 OUT1 d=0");
        `CHECK(pin_wr_idx == 0 && pin_wr_val == 1, "A7 OUT1 pin idx/val")
        hold_test(`OP_OUT1, 1, PW | OSS | DCL, "A7 OUT1 d=1");
        hold_test(`OP_OUT1, 3, PW | OSS | DCL, "A7 OUT1 d=3");
        hold_test(`OP_IN1,  0, ISS | DCL, "A7 IN1 d=0");
        hold_test(`OP_IN1,  2, ISS | DCL, "A7 IN1 d=2");
        hold_test(`OP_WAIT, 0, DCL, "A7 WAIT d=0");
        hold_test(`OP_WAIT, 1, DCL, "A7 WAIT d=1");
        hold_test(`OP_WAIT, 5, DCL, "A7 WAIT d=5");

        set(`OP_SETH, 5);
        `CHECK(ctl == (ADV | PW) && pin_wr_idx == 5 && pin_wr_val == 1, "A7 SETH") tick;
        set(`OP_SETLO, 6);
        `CHECK(ctl == (ADV | PW) && pin_wr_idx == 6 && pin_wr_val == 0, "A7 SETLO") tick;
        set(`OP_DIRO, 2);
        `CHECK(ctl == (ADV | DW) && dir_wr_idx == 2 && dir_wr_val == 1, "A7 DIRO") tick;
        set(`OP_DIRI, 7);
        `CHECK(ctl == (ADV | DW) && dir_wr_idx == 7 && dir_wr_val == 0, "A7 DIRI") tick;

        pin_in = 8'h00; set(`OP_WAITH, 4);
        `CHECK(ctl == NONE, "A7 WAITH stalls while low") tick;
        pin_in = 8'h10; #1;
        `CHECK(ctl == ADV, "A7 WAITH passes when high") tick;
        set(`OP_WAITL, 4);
        `CHECK(ctl == NONE, "A7 WAITL stalls while high") tick;
        pin_in = 8'h00; #1;
        `CHECK(ctl == ADV, "A7 WAITL passes when low") tick;

        // V1.1 JPH/JPL: operand [11:9] pin, [8:0] addr; one cycle, taken or not; exhaustive over
        // 8 pins x {JPL, JPH} x {taken, not taken} x 7 addresses, every other pin at the opposite level
        for (k = 0; k < 8 * 2 * 2 * 7; k = k + 1) begin
            p = k % 8; lv = (k / 8) % 2; tk = (k / 16) % 2;
            case (k / 32) 0: a = 0; 1: a = 1; 2: a = 9'h03F; 3: a = 9'h040; 4: a = 9'h0FF; 5: a = 9'h100; default: a = 9'h1FF; endcase
            pin_in = (tk == lv) ? (8'd1 << p) : ~(8'd1 << p);
            set(lv ? `OP_JPH : `OP_JPL, (p << 9) | a);
            `CHECK(ctl == (tk ? JMP : ADV) && (!tk || jump_addr == a), "V1.1 JPH/JPL pin [11:9], 9-bit address") tick;
        end
        pin_in = 8'h00;
        set(`OP_JMP, 9'h1A5);
        `CHECK(ctl == JMP && jump_addr == 9'h1A5, "V1.1 JMP 9-bit address") tick;

        set(`OP_CFG, 8'b1110_1011); // out=3 in=5 osr_msb=1 isr_msb=1
        `CHECK(ctl == ADV, "A7 CFG") tick;
        `CHECK(cfg_out_pin == 3 && cfg_in_pin == 5 && cfg_osr_msb == 1 && cfg_isr_msb == 1, "A7 CFG regs")
        set(`OP_OUT1, 0);
        `CHECK(pin_wr_idx == 3, "A7 OUT1 uses cfg_out_pin") tick;

        set(`OP_HALT, 0);
        `CHECK(ctl == NONE, "A7 HALT no strobes") tick;
        `CHECK(halted == 1 && fault == 0, "A7 HALT status")
        set(`OP_NOP, 0);
        `CHECK(ctl == NONE, "A7 halted engine ignores NOP") tick;

        do_reset; set(5'd21, 0);
        `CHECK(ctl == NONE, "A7 opcode 21 no strobes") tick;
        `CHECK(halted == 1 && fault == 1, "A7 opcode 21 traps")
        do_reset; set(5'd22, 0); tick;
        `CHECK(halted == 1 && fault == 1, "A7 opcode 22 traps")
        do_reset; set(5'd31, 0); tick;
        `CHECK(halted == 1 && fault == 1, "A7 opcode 31 traps")
        set(`OP_NOP, 0);
        `CHECK(ctl == NONE, "A7 faulted engine ignores NOP")
        `CHECK(fault_cause == 0, "V1 illegal opcode = cause 0")

        // pc_fault: the pc may not be executed -> trap with that cause, nothing commits
        for (k = 1; k < 4; k = k + 1) begin
            do_reset; pin_in = 8'hFF; pc_fault = k; set(`OP_SETH, 3);
            `CHECK(ctl == NONE, "V1 pc_fault: no strobes") tick;
            `CHECK(halted == 1 && fault == 1 && fault_cause == k, "V1 pc_fault traps with its cause")
            pc_fault = 0; set(`OP_NOP, 0);
            `CHECK(ctl == NONE, "V1 trapped engine stays halted") tick;
        end

        `REPORT("tb_control_unit")
        $finish;
    end
endmodule
