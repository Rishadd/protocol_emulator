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

    wire        pc_advance, pc_jump, dc_load, lc_load, lc_dec, tx_rd_en, rx_wr_en;
    wire        osr_load, osr_shift, isr_shift, isr_clear, pin_wr, dir_wr;
    wire        pin_wr_val, dir_wr_val, halted, fault, dc_busy, dc_last, push_imm;
    wire [7:0]  jump_addr;
    wire [26:0] dc_load_value;
    wire [15:0] lc_load_value, lc_count;
    wire [2:0]  pin_wr_idx, dir_wr_idx, cfg_out_pin, cfg_in_pin;
    wire        cfg_osr_msb, cfg_isr_msb;
    // register / ALU / CRC extension
    reg         flag_z = 0, flag_n = 0, flag_c = 0, rs_zero = 0, crc_busy = 0;
    wire        push_reg, alu_go, ldi_go, rget_go, isr_load, osr_from_reg, lc_from_reg, dc_from_reg;
    wire        crc_rst, crc_set_poly, crc_set_init, crc_set_xor, crc_set_fmt, crc_feed_bit, crc_feed_byte;

    integer errors = 0, k, fl, cc;

    control_unit dut (
        .clk(clk), .rst_n(rst_n), .instr(instr),
        .pc_advance(pc_advance), .pc_jump(pc_jump), .jump_addr(jump_addr),
        .dc_load(dc_load), .dc_load_value(dc_load_value), .dc_last(dc_last),
        .lc_load(lc_load), .lc_dec(lc_dec), .lc_load_value(lc_load_value), .lc_count(lc_count),
        .tx_empty(tx_empty), .tx_rd_en(tx_rd_en), .rx_full(rx_full), .rx_wr_en(rx_wr_en), .push_imm(push_imm), .push_reg(push_reg),
        .flag_z(flag_z), .flag_n(flag_n), .flag_c(flag_c), .rs_zero(rs_zero),
        .alu_go(alu_go), .ldi_go(ldi_go), .rget_go(rget_go), .isr_load(isr_load), .osr_from_reg(osr_from_reg),
        .lc_from_reg(lc_from_reg), .dc_from_reg(dc_from_reg),
        .crc_rst(crc_rst), .crc_set_poly(crc_set_poly), .crc_set_init(crc_set_init), .crc_set_xor(crc_set_xor),
        .crc_set_fmt(crc_set_fmt), .crc_feed_bit(crc_feed_bit), .crc_feed_byte(crc_feed_byte), .crc_busy(crc_busy),
        .osr_load(osr_load), .osr_shift(osr_shift), .osr_bit(osr_bit),
        .isr_shift(isr_shift), .isr_clear(isr_clear),
        .pin_wr(pin_wr), .pin_wr_idx(pin_wr_idx), .pin_wr_val(pin_wr_val),
        .dir_wr(dir_wr), .dir_wr_idx(dir_wr_idx), .dir_wr_val(dir_wr_val), .pin_in(pin_in),
        .cfg_out_pin(cfg_out_pin), .cfg_in_pin(cfg_in_pin),
        .cfg_osr_msb(cfg_osr_msb), .cfg_isr_msb(cfg_isr_msb),
        .halted(halted), .fault(fault));

    delay_counter dc (.clk(clk), .rst_n(rst_n), .load(dc_load), .load_value(dc_load_value),
                      .busy(dc_busy), .last(dc_last));
    loop_counter  lc (.clk(clk), .rst_n(rst_n), .load(lc_load), .load_value(lc_load_value),
                      .dec(lc_dec), .count(lc_count));

    // all one-bit control strobes packed so a single compare proves "this and nothing else"
    wire [24:0] ctl = {pc_advance, pc_jump, dc_load, lc_load, lc_dec, tx_rd_en, rx_wr_en,
                       osr_load, osr_shift, isr_shift, isr_clear, pin_wr, dir_wr,
                       alu_go, ldi_go, rget_go, isr_load, push_reg,
                       crc_rst, crc_set_poly, crc_set_init, crc_set_xor, crc_set_fmt, crc_feed_bit, crc_feed_byte};
    localparam [24:0] ADV = 25'd1 << 24, JMP = 25'd1 << 23, DCL = 25'd1 << 22, LCL = 25'd1 << 21,
                      LCD = 25'd1 << 20, TXR = 25'd1 << 19, RXW = 25'd1 << 18, OSL = 25'd1 << 17,
                      OSS = 25'd1 << 16, ISS = 25'd1 << 15, ISC = 25'd1 << 14, PW  = 25'd1 << 13,
                      DW  = 25'd1 << 12, NONE = 25'd0,
                      X_ALU = 25'd1 << 11, X_LDI = 25'd1 << 10, X_RGET = 25'd1 << 9, X_ISL = 25'd1 << 8,
                      X_PSR = 25'd1 << 7, X_CRST = 25'd1 << 6, X_CPOLY = 25'd1 << 5, X_CINIT = 25'd1 << 4,
                      X_CXOR = 25'd1 << 3, X_CFMT = 25'd1 << 2, X_CBIT = 25'd1 << 1, X_CBYTE = 25'd1;

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask
    task set(input [4:0] op, input [26:0] opnd); begin instr = {op, opnd}; #2; end endtask
    task do_reset; begin rst_n = 0; set(`OP_NOP, 0); tick; rst_n = 1; end endtask

    // timed instruction: first-cycle strobes `first`, then silence, then ADV exactly on cycle d
    task hold_test(input [4:0] op, input [26:0] d, input [24:0] first, input [80*8-1:0] name);
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

        // JPH/JPL: operand [10:8] pin, [7:0] addr; one cycle, taken or not
        pin_in = 8'h20; set(`OP_JPH, (5 << 8) | 9);
        `CHECK(ctl == JMP && jump_addr == 9, "A7 JPH taken when pin high") tick;
        pin_in = 8'hDF; #1;
        `CHECK(ctl == ADV, "A7 JPH falls through when pin low (others high)") tick;
        pin_in = 8'hFB; set(`OP_JPL, (2 << 8) | 33);
        `CHECK(ctl == JMP && jump_addr == 33, "A7 JPL taken when pin low (others high)") tick;
        pin_in = 8'h04; #1;
        `CHECK(ctl == ADV, "A7 JPL falls through when pin high") tick;
        pin_in = 8'h00;
        // 8-bit targets (256-word memory): addresses above 63 and the top word
        pin_in = 8'h20; set(`OP_JPH, (5 << 8) | 8'd200);
        `CHECK(ctl == JMP && jump_addr == 200, "A7 JPH target 200") tick;
        pin_in = 8'h00; set(`OP_JPL, (7 << 8) | 8'd255);
        `CHECK(ctl == JMP && jump_addr == 255, "A7 JPL target 255, pin 7") tick;
        set(`OP_JMP, 27'h7FF_FF00 | 8'h5A);
        `CHECK(ctl == JMP && jump_addr == 8'h5A, "A7 JMP target is operand[7:0] only") tick;
        pin_in = 8'h00;

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

        // ================= register / ALU / CRC extension (opcodes 21-27) =================
        do_reset;
        // old opcodes leave the new strobes and the register-source selects alone
        tx_empty = 0; set(`OP_PULL, 0);
        `CHECK(ctl == (ADV | TXR | OSL) && osr_from_reg == 0, "B1 PULL loads the OSR from the FIFO, not a register") tick;
        set(`OP_SETL, 3);
        `CHECK(ctl == (ADV | LCL) && lc_from_reg == 0, "B1 SETL loads the operand, not a register") tick;
        hold_test(`OP_WAIT, 2, DCL, "B1 WAIT");
        `CHECK(dc_from_reg == 0, "B1 WAIT uses the operand")

        // (register read ports are wired to their operand fields inside alu_unit: ALU [19:17], everything else [2:0];
        //  tested in tb_alu_unit and at engine level, there is no select signal any more)
        set(`OP_ALU, 0); tick;
        set(`OP_RPUT, 0); tick;
        set(`OP_WAITR, 0); rs_zero = 1; tick;
        set(`OP_CRC, 0); tick;

        // LDI
        set(`OP_LDI, {3'd5, 24'hABCDEF});
        `CHECK(ctl == (ADV | X_LDI), "B3 LDI") tick;
        // ALU: every legal function is one cycle, one strobe
        for (k = 0; k <= 12; k = k + 1) begin
            set(`OP_ALU, {k[3:0], 3'd2, 3'd1, 1'b1, 16'h1234});
            `CHECK(ctl == (ADV | X_ALU), "B4 ALU function commits in one cycle") tick;
        end
        // reserved ALU functions trap without strobes
        for (k = 13; k <= 15; k = k + 1) begin
            do_reset; set(`OP_ALU, {k[3:0], 23'd0});
            `CHECK(ctl == NONE, "B4 reserved ALU function: no strobes") tick;
            `CHECK(halted == 1 && fault == 1, "B4 reserved ALU function traps")
        end
        do_reset;

        // JCC: every condition against every flag combination, jump or advance in one cycle
        for (cc = 0; cc < 8; cc = cc + 1)
            for (fl = 0; fl < 8; fl = fl + 1) begin
                flag_z = fl[2]; flag_n = fl[1]; flag_c = fl[0];
                set(`OP_JCC, (cc << 8) | 8'd77);
                case (cc)
                    0: k = flag_z;
                    1: k = !flag_z;
                    2: k = flag_c;
                    3: k = !flag_c;
                    4: k = flag_n;
                    5: k = !flag_n;
                    6: k = flag_c && !flag_z;
                    default: k = !flag_c || flag_z;
                endcase
                if (k) begin `CHECK(ctl == JMP && jump_addr == 77, "B5 JCC taken") end
                else   begin `CHECK(ctl == ADV, "B5 JCC falls through") end
                tick;
            end
        flag_z = 0; flag_n = 0; flag_c = 0;

        // RGET: sources 0..4 commit at once; source 5 (TX FIFO) pops and stalls while empty
        for (k = 0; k <= 4; k = k + 1) begin
            set(`OP_RGET, {20'd0, k[2:0], 1'b0, 3'd2});
            `CHECK(ctl == (ADV | X_RGET), "B6 RGET (no FIFO) commits") tick;
        end
        tx_empty = 1; set(`OP_RGET, {20'd0, 3'd5, 1'b0, 3'd2});
        `CHECK(ctl == NONE, "B6 RGET TXF stalls on empty, no side effects") tick; tick;
        tx_empty = 0; #1;
        `CHECK(ctl == (ADV | X_RGET | TXR), "B6 RGET TXF pops the FIFO") tick;
        // RGET CRC waits while the CRC unit still executes the previous CRC command; no other source looks at crc_busy
        crc_busy = 1; set(`OP_RGET, {20'd0, 3'd4, 1'b0, 3'd2});
        `CHECK(ctl == NONE, "B6 RGET CRC stalls while the CRC unit is busy, no side effects") tick;
        crc_busy = 0; #1;
        `CHECK(ctl == (ADV | X_RGET), "B6 RGET CRC commits when the CRC unit is idle") tick;
        crc_busy = 1; set(`OP_RGET, {20'd0, 3'd1, 1'b0, 3'd2});
        `CHECK(ctl == (ADV | X_RGET), "B6 RGET ISR ignores crc_busy") tick;
        crc_busy = 1; set(`OP_CRC, {3'd6, 21'd0, 3'd4});
        `CHECK(ctl == (ADV | X_CBYTE), "B6 a CRC instruction never waits for crc_busy") tick;
        crc_busy = 0;
        do_reset; set(`OP_RGET, {20'd0, 3'd6, 1'b0, 3'd2}); tick;
        `CHECK(halted == 1 && fault == 1, "B6 RGET source 6 traps")
        do_reset; set(`OP_RGET, {20'd0, 3'd7, 1'b0, 3'd2}); tick;
        `CHECK(halted == 1 && fault == 1, "B6 RGET source 7 traps")
        do_reset;

        // RPUT
        set(`OP_RPUT, {20'd0, 3'd0, 1'b0, 3'd1});
        `CHECK(ctl == (ADV | OSL) && osr_from_reg == 1 && tx_rd_en == 0, "B7 RPUT OSR: load from register, no FIFO pop") tick;
        set(`OP_RPUT, {20'd0, 3'd1, 1'b0, 3'd1});
        `CHECK(ctl == (ADV | X_ISL), "B7 RPUT ISR") tick;
        set(`OP_RPUT, {20'd0, 3'd2, 1'b0, 3'd1});
        `CHECK(ctl == (ADV | LCL) && lc_from_reg == 1, "B7 RPUT LC: loop counter from register") tick;
        rx_full = 1; set(`OP_RPUT, {20'd0, 3'd3, 1'b0, 3'd1});
        `CHECK(ctl == NONE, "B7 RPUT RXF stalls on full, no side effects") tick;
        rx_full = 0; #1;
        `CHECK(ctl == (ADV | RXW | X_PSR) && push_imm == 0, "B7 RPUT RXF pushes the register") tick;
        for (k = 4; k <= 7; k = k + 1) begin
            do_reset; set(`OP_RPUT, {20'd0, k[2:0], 1'b0, 3'd1}); tick;
            `CHECK(halted == 1 && fault == 1, "B7 RPUT destination 4..7 traps")
        end
        do_reset;

        // WAITR: register delay, d+1 cycles; zero is a one-cycle instruction
        rs_zero = 1; set(`OP_WAITR, 3);
        `CHECK(ctl == (ADV | DCL) && dc_from_reg == 1, "B8 WAITR with R=0 is one cycle") tick;
        rs_zero = 0;
        hold_test(`OP_WAITR, 3, DCL, "B8 WAITR holds R+1 cycles (R taken as 3 by the stand-in operand)");
        `CHECK(dc_from_reg == 1, "B8 WAITR takes its delay from the register")

        // CRC: one strobe per operation, one cycle
        for (k = 0; k <= 6; k = k + 1) begin
            set(`OP_CRC, {k[2:0], 21'd0, 3'd4});
            case (k)
                0: `CHECK(ctl == (ADV | X_CRST),  "B9 CRC RST")
                1: `CHECK(ctl == (ADV | X_CPOLY), "B9 CRC POLY")
                2: `CHECK(ctl == (ADV | X_CINIT), "B9 CRC INIT")
                3: `CHECK(ctl == (ADV | X_CXOR),  "B9 CRC XOROUT")
                4: `CHECK(ctl == (ADV | X_CFMT),  "B9 CRC FMT")
                5: `CHECK(ctl == (ADV | X_CBIT),  "B9 CRC BIT")
                default: `CHECK(ctl == (ADV | X_CBYTE), "B9 CRC BYTE")
            endcase
            tick;
        end
        do_reset; set(`OP_CRC, {3'd7, 24'd0}); tick;
        `CHECK(halted == 1 && fault == 1, "B9 CRC operation 7 traps")

        // reserved opcodes trap (21..27 are legal now)
        for (k = 28; k <= 31; k = k + 1) begin
            do_reset; set(k[4:0], 27'd0);
            `CHECK(ctl == NONE, "A7 reserved opcode: no strobes") tick;
            `CHECK(halted == 1 && fault == 1, "A7 opcodes 28..31 trap")
        end
        set(`OP_NOP, 0);
        `CHECK(ctl == NONE, "A7 faulted engine ignores NOP")

        `REPORT("tb_control_unit")
        $finish;
    end
endmodule
