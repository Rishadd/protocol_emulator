`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// Register file / ALU / CRC instructions inside a real engine_top (directed programs, results known from the instruction table).
// host/isa_diff_test.py covers the same instructions with random programs against the Python model; this bench is the readable
// version: a counted sum, CRC-32 and CRC-16/Modbus computed by firmware, WAITR cycle counts, every RGET source and RPUT destination,
// FIFO stalls with no side effects, traps, and reset behaviour.
module tb_engine_alu;
    // waveform: run vvp with +dump to write build/wave/tb_engine_alu.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_engine_alu.vcd"); $dumpvars(0, tb_engine_alu); end
    reg         clk = 0, rst_n = 0, run = 0, drain = 1;
    reg         tx_wr_en = 0, rx_rd_en = 0;
    reg  [31:0] tx_wr_data = 0;
    reg  [7:0]  pin_in = 0;
    wire [31:0] rx_rd_data;
    wire        tx_full, rx_empty, halted, fault;
    wire [7:0]  pin_out, pin_oe, pc;

    integer errors = 0, nrx = 0, k, cyc;
    reg [31:0] rx [0:31];

    engine_top dut (
        .clk(clk), .rst_n(rst_n), .run(run),
        .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full),
        .rx_rd_en(rx_rd_en), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in(pin_in), .pin_out(pin_out), .pin_oe(pin_oe),
        .halted(halted), .fault(fault), .pc(pc));

    always #5 clk = ~clk;
    always @(negedge clk) begin
        rx_rd_en = 0;
        if (drain && !rx_empty) begin rx[nrx] = rx_rd_data; nrx = nrx + 1; rx_rd_en = 1; end
    end

    // ---- encoders
    function [31:0] I(input [4:0] op, input [26:0] v); I = {op, v}; endfunction
    function [31:0] LDI(input [2:0] rd, input [23:0] imm);              LDI = I(`OP_LDI, {rd, imm}); endfunction
    function [31:0] ALUI(input [3:0] f, input [2:0] rd, input [15:0] imm); ALUI = I(`OP_ALU, {f, rd, 3'd0, 1'b1, imm}); endfunction
    function [31:0] ALUR(input [3:0] f, input [2:0] rd, input [2:0] rs);   ALUR = I(`OP_ALU, {f, rd, rs, 1'b0, 16'd0}); endfunction
    function [31:0] JCC(input [2:0] c, input [7:0] a);                  JCC = I(`OP_JCC, {c, a} & 27'h7FF); endfunction
    function [31:0] RGET(input [2:0] rd, input [2:0] src);              RGET = I(`OP_RGET, {src, 1'b0, rd}); endfunction
    function [31:0] RPUT(input [2:0] dst, input [2:0] rs);              RPUT = I(`OP_RPUT, {dst, 1'b0, rs}); endfunction
    function [31:0] CRC(input [2:0] cop, input [2:0] rs);               CRC = I(`OP_CRC, {cop, 21'd0, rs}); endfunction

    reg [31:0] prog [0:127];
    // reset (clears FIFOs), load prog[0..n-1], run until HALT or timeout; optional TX words
    task load_prog(input integer n);
        begin
            run = 0; rst_n = 0; nrx = 0; drain = 1; pin_in = 0;
            @(posedge clk); #1 rst_n = 1;
            for (k = 0; k < 256; k = k + 1) dut.imem.poke(k, k < n ? prog[k] : I(`OP_HALT, 0));
            @(posedge clk); @(posedge clk); @(posedge clk); #1;
        end
    endtask
    task tx_push(input [31:0] w);
        begin @(negedge clk) begin tx_wr_en = 1; tx_wr_data = w; end @(negedge clk) tx_wr_en = 0; end
    endtask
    task go(input integer max);
        begin
            run = 1;
            for (cyc = 0; cyc < max && !halted; cyc = cyc + 1) @(posedge clk);
            repeat (4) @(posedge clk);
        end
    endtask

    // pc history, to count the cycles an instruction occupies
    reg [7:0] pch [0:4095];
    integer   pcn = 0;
    always @(posedge clk) if (run) begin pch[pcn % 4096] = pc; pcn = pcn + 1; end

    reg [15:0] c16;
    integer i2, t0;
    initial begin
        // ---- T1: counted sum with compare/branch: R0 = 1+2+...+10
        prog[0] = LDI(0, 0);  prog[1] = LDI(1, 1);
        prog[2] = ALUR(`ALU_ADD, 0, 1);  prog[3] = ALUI(`ALU_ADD, 1, 1);
        prog[4] = ALUI(`ALU_CMP, 1, 11); prog[5] = JCC(`CC_NZ, 2);
        prog[6] = RPUT(`RP_RXF, 0);      prog[7] = I(`OP_HALT, 0);
        load_prog(8); go(400);
        `CHECK(nrx == 1 && rx[0] == 55 && halted && !fault, "T1 sum 1..10 = 55 through ALU, CMP and JCC")

        // ---- T2: CRC-32 of "123456789" computed by firmware on the reset configuration
        for (i2 = 0; i2 < 9; i2 = i2 + 1) begin prog[2 * i2] = LDI(0, "1" + i2); prog[2 * i2 + 1] = CRC(`CRC_BYTE, 0); end
        prog[18] = RGET(1, `RG_CRC); prog[19] = RPUT(`RP_RXF, 1); prog[20] = I(`OP_HALT, 0);
        load_prog(21); go(400);
        `CHECK(nrx == 1 && rx[0] == 32'hCBF43926 && !fault, "T2 CRC-32 check value computed by the engine")

        // ---- T3: CRC-16/MODBUS configured by firmware; frame 01 03 00 00 00 0A -> CRC C5 CD; appended low byte first -> residue 0
        prog[0]  = LDI(2, 16'h8005); prog[1] = CRC(`CRC_POLY, 2);
        prog[2]  = LDI(2, 16'hFFFF); prog[3] = CRC(`CRC_INIT, 2);
        prog[4]  = LDI(2, 0);        prog[5] = CRC(`CRC_XOR, 2);
        prog[6]  = LDI(2, 15 | (1 << 5) | (1 << 6)); prog[7] = CRC(`CRC_FMT, 2);
        prog[8]  = CRC(`CRC_RST, 0);
        prog[9]  = LDI(0, 8'h01); prog[10] = CRC(`CRC_BYTE, 0);
        prog[11] = LDI(0, 8'h03); prog[12] = CRC(`CRC_BYTE, 0);
        prog[13] = LDI(0, 8'h00); prog[14] = CRC(`CRC_BYTE, 0);
        prog[15] = CRC(`CRC_BYTE, 0); prog[16] = CRC(`CRC_BYTE, 0);
        prog[17] = LDI(0, 8'h0A); prog[18] = CRC(`CRC_BYTE, 0);
        prog[19] = RGET(1, `RG_CRC); prog[20] = RPUT(`RP_RXF, 1);       // CDC5
        prog[21] = ALUI(`ALU_AND, 1, 16'h00FF); prog[22] = CRC(`CRC_BYTE, 1);   // append low byte (C5)
        prog[23] = RGET(1, `RG_CRC); prog[24] = ALUI(`ALU_SHR, 1, 8);           // not used below
        prog[25] = LDI(0, 8'hCD); prog[26] = CRC(`CRC_BYTE, 0);                 // append high byte (CD)
        prog[27] = RGET(1, `RG_CRC); prog[28] = RPUT(`RP_RXF, 1);               // residue 0
        prog[29] = I(`OP_HALT, 0);
        load_prog(30); go(600);
        `CHECK(nrx == 2 && rx[0] == 32'h0000_CDC5 && !fault, "T3 CRC-16/MODBUS of the frame = CDC5, configured by firmware")
        `CHECK(nrx == 2 && rx[1] == 32'h0000_0000, "T3 CRC over frame + CRC (low byte first) = 0")

        // ---- T4: WAITR cycle counts: R=0 -> 1 cycle, R=5 -> 6 cycles, R with only upper bits set -> 1 cycle (not a hang)
        prog[0] = LDI(2, 0);  prog[1] = I(`OP_WAITR, 2);          // pc 1: zero delay
        prog[2] = LDI(3, 5);  prog[3] = I(`OP_WAITR, 3);          // pc 3: R3 = 5
        prog[4] = LDI(4, 24'hE80000); prog[5] = ALUI(`ALU_SHL, 4, 8);   // R4 = 0xE8000000: bits 27.. set, low 27 bits zero
        prog[6] = I(`OP_WAITR, 4);                                // pc 6
        prog[7] = RPUT(`RP_RXF, 4); prog[8] = I(`OP_HALT, 0);
        load_prog(9); pcn = 0; go(200);
        `CHECK(!fault && nrx == 1 && rx[0] == 32'hE800_0000, "T4 program completes (WAITR with upper-bit-only register does not hang)")
        // locate runs of identical pc in the history
        begin : t4
            integer n1, n3, n6, q;
            n1 = 0; n3 = 0; n6 = 0;
            for (q = 0; q < pcn; q = q + 1) begin
                if (pch[q] == 8'd1) n1 = n1 + 1;
                if (pch[q] == 8'd3) n3 = n3 + 1;
                if (pch[q] == 8'd6) n6 = n6 + 1;
            end
            `CHECK(n1 == 1, "T4 WAITR with R=0 occupies 1 cycle")
            `CHECK(n3 == 6, "T4 WAITR with R=5 occupies 6 cycles")
            `CHECK(n6 == 1, "T4 WAITR with low 27 bits zero occupies 1 cycle")
        end

        // ---- T5: RGET sources and RPUT destinations
        prog[0]  = RGET(0, `RG_TXF);                               // R0 <- TX word
        prog[1]  = RPUT(`RP_OSR, 0);  prog[2] = RGET(1, `RG_OSR);  // OSR round trip
        prog[3]  = RPUT(`RP_ISR, 0);  prog[4] = RGET(2, `RG_ISR);  // ISR round trip
        prog[5]  = LDI(3, 5);         prog[6] = RPUT(`RP_LC, 3);  prog[7] = RGET(4, `RG_LC);   // loop counter
        prog[8]  = I(`OP_WAIT, 6);                                   // let the pin synchronizer settle
        prog[9]  = RGET(5, `RG_PIN);                               // synchronized pins
        prog[10] = RPUT(`RP_RXF, 0); prog[11] = RPUT(`RP_RXF, 1); prog[12] = RPUT(`RP_RXF, 2);
        prog[13] = RPUT(`RP_RXF, 4); prog[14] = RPUT(`RP_RXF, 5); prog[15] = I(`OP_HALT, 0);
        load_prog(16); pin_in = 8'h5A; tx_push(32'hDEAD_BEEF); go(300);
        `CHECK(!fault && nrx == 5, "T5 program completes, five words pushed")
        `CHECK(rx[0] == 32'hDEAD_BEEF, "T5 RGET TXF pops the TX word into a register")
        `CHECK(rx[1] == 32'hDEAD_BEEF, "T5 RPUT OSR / RGET OSR round trip")
        `CHECK(rx[2] == 32'hDEAD_BEEF, "T5 RPUT ISR / RGET ISR round trip")
        `CHECK(rx[3] == 32'd5, "T5 RPUT LC / RGET LC round trip")
        `CHECK(rx[4] == 32'h0000_005A, "T5 RGET PIN returns the synchronized pins")

        // ---- T6: RPUT OSR feeds the shifters like PULL (OUT1 drives the bits), TX FIFO untouched
        prog[0]  = I(`OP_CFG, 8'd0);          // out pin 0, LSB first
        prog[1]  = I(`OP_DIRO, 0);
        prog[2]  = LDI(0, 8'h01);              // OSR = 1: first bit out = 1
        prog[3]  = RPUT(`RP_OSR, 0);
        prog[4]  = I(`OP_OUT1, 0);
        prog[5]  = I(`OP_HALT, 0);
        load_prog(6); tx_push(32'h0000_0000); go(100);
        `CHECK(pin_out[0] == 1'b1 && pin_oe[0] == 1'b1, "T6 OUT1 after RPUT OSR drives the register's bit")
        `CHECK(dut.tx_fifo.count == 1, "T6 RPUT OSR does not touch the TX FIFO")

        // ---- T7: FIFO stalls with no side effects
        prog[0] = RGET(0, `RG_TXF); prog[1] = RPUT(`RP_RXF, 0); prog[2] = I(`OP_HALT, 0);
        load_prog(3); go(30);                           // no TX word: stalls at pc 0
        `CHECK(pc == 8'd0 && !halted && nrx == 0 && dut.tx_fifo.count == 0, "T7 RGET TXF stalls on an empty FIFO, pc held, nothing popped")
        tx_push(32'h1234_5678); repeat (6) @(posedge clk);
        `CHECK(halted && nrx == 1 && rx[0] == 32'h1234_5678, "T7 the stalled RGET TXF completes when the host writes a word")
        // RPUT RXF into a full FIFO: six pushes, host drains late
        prog[0] = LDI(0, 1); prog[1] = RPUT(`RP_RXF, 0); prog[2] = ALUI(`ALU_ADD, 0, 1);
        prog[3] = ALUI(`ALU_CMP, 0, 7); prog[4] = JCC(`CC_NZ, 1); prog[5] = I(`OP_HALT, 0);
        load_prog(6); drain = 0; go(60);
        `CHECK(!halted && dut.rx_fifo.count == 4, "T7 RPUT RXF stalls with a full RX FIFO (4 words held, engine not halted)")
        `CHECK(pc == 8'd1, "T7 stalled RPUT RXF holds the pc")
        drain = 1; repeat (60) @(posedge clk);
        `CHECK(halted && nrx == 6 && rx[0] == 1 && rx[1] == 2 && rx[2] == 3 && rx[3] == 4 && rx[4] == 5 && rx[5] == 6,
               "T7 after draining all six pushed words arrive in order")

        // ---- T8: traps
        prog[0] = ALUI(13, 0, 0);  load_prog(1); go(10);
        `CHECK(halted && fault && pc == 8'd0, "T8 ALU function 13 traps (pc frozen)")
        // RGET FIFO (source 7): {RX level, TX level}, never stalls
        prog[0] = RGET(0, `RG_FIFO); prog[1] = RPUT(`RP_RXF, 0); prog[2] = RGET(1, `RG_FIFO); prog[3] = RPUT(`RP_RXF, 1); prog[4] = RGET(2, `RG_FIFO);
        prog[5] = RPUT(`RP_RXF, 2); prog[6] = RGET(3, `RG_TXF); prog[7] = RGET(4, `RG_FIFO); prog[8] = RPUT(`RP_RXF, 4); prog[9] = I(`OP_HALT, 0);
        load_prog(10); tx_push(32'h11); tx_push(32'h22); tx_push(32'h33); drain = 0; go(200);
        `CHECK(!fault && halted, "T8 RGET FIFO is legal and does not stall")
        `CHECK(dut.rx_fifo.count == 4, "T8 four status words pushed")
        drain = 1; repeat (20) @(posedge clk);
        `CHECK(nrx == 4 && rx[0] == {26'd0, 3'd0, 3'd3} && rx[1] == {26'd0, 3'd1, 3'd3} && rx[2] == {26'd0, 3'd2, 3'd3} && rx[3] == {26'd0, 3'd3, 3'd2},
               "T8 RGET FIFO = {RX words, TX words}: 0/3, 1/3, 2/3, then 3/2 after RGET TXF popped one")
        prog[0] = I(`OP_RGET, {3'd7, 1'b0, 3'd0}); prog[1] = RPUT(`RP_RXF, 0); prog[2] = I(`OP_HALT, 0);
        load_prog(3); tx_push(32'h1); tx_push(32'h2); tx_push(32'h3); tx_push(32'h4); go(100);
        `CHECK(nrx == 1 && rx[0] == {26'd0, 3'd0, 3'd4}, "T8 a full TX FIFO reads 4")
        prog[0] = I(`OP_RPUT, {3'd5, 1'b0, 3'd0}); load_prog(1); go(10);
        `CHECK(halted && fault, "T8 RPUT destination 5 traps")
        prog[0] = I(`OP_CRC, {3'd7, 24'd0}); load_prog(1); go(10);
        `CHECK(halted && fault, "T8 CRC operation 7 traps")
        prog[0] = I(5'd29, 0); load_prog(1); go(10);
        `CHECK(halted && fault, "T8 opcode 29 traps")
        prog[0] = I(`OP_LINE, {3'd6, 24'd0}); load_prog(1); go(10);
        `CHECK(halted && fault, "T8 LINE operation 6 traps")

        // ---- T9: stopping the engine (run=0) clears registers, flags and the CRC unit; FIFOs are kept
        prog[0] = LDI(0, 24'h123456); prog[1] = ALUI(`ALU_CMP, 0, 0); prog[2] = LDI(1, 16'h0007);
        prog[3] = CRC(`CRC_POLY, 1); prog[4] = LDI(2, 8'hFF); prog[5] = CRC(`CRC_BYTE, 2); prog[6] = I(`OP_HALT, 0);
        load_prog(7); go(50);
        `CHECK(dut.alu.r[0] == 32'h123456 && dut.alu.flag_c == 1'b1, "T9 state exists before the stop")
        run = 0; repeat (3) @(posedge clk); #1;
        `CHECK(dut.alu.r[0] == 0 && dut.alu.r[1] == 0 && dut.alu.r[2] == 0 && dut.alu.flag_z == 0 && dut.alu.flag_c == 0,
               "T9 run=0 clears the register file and the flags")
        `CHECK(dut.crc.value == 32'h0000_0000 && dut.crc.poly == 32'h04C1_1DB7,
               "T9 run=0 restores the CRC unit's reset configuration (register = init, poly = CRC-32)")

        `REPORT("tb_engine_alu")
        $finish;
    end
endmodule
