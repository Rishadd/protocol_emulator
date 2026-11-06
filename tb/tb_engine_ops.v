`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// JPO and PUSHI inside a real engine_top: OSR bit order, RX FIFO data path, stall on a full FIFO.
// The host drains the RX FIFO on the falling edge whenever `drain` is set.
module tb_engine_ops;
    // waveform: run vvp with +dump to write build/wave/tb_engine_ops.vcd
    initial if ($test$plusargs("dump")) begin $dumpfile("build/wave/tb_engine_ops.vcd"); $dumpvars(0, tb_engine_ops); end
    reg         clk = 0, rst_n = 0, run = 0, drain = 1;
    reg         tx_wr_en = 0, rx_rd_en = 0;
    reg  [31:0] tx_wr_data = 0;
    reg  [7:0]  pin_in = 0;
    wire [31:0] rx_rd_data;
    wire        tx_full, rx_empty, halted, fault;
    wire [7:0]  pin_out, pin_oe;
    wire [7:0]  pc;

    integer errors = 0, nrx = 0, k;
    reg [31:0] rx [0:15];

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

    function [31:0] I(input [4:0] op, input [26:0] v); I = {op, v}; endfunction

    // reset (clears FIFOs), load prog[0..n-1], optional TX word, run until HALT (or timeout)
    reg [31:0] prog [0:15];
    task run_prog(input integer n, input [31:0] tx);
        begin
            run = 0; rst_n = 0; nrx = 0;
            @(posedge clk); #1 rst_n = 1;
            for (k = 0; k < 64; k = k + 1) dut.imem.poke(k, k < n ? prog[k] : I(`OP_HALT, 0));
            @(negedge clk) begin tx_wr_en = 1; tx_wr_data = tx; end
            @(negedge clk) tx_wr_en = 0;
            @(posedge clk); @(posedge clk); #1 run = 1;
            for (k = 0; k < 2000 && !halted; k = k + 1) @(posedge clk);
            repeat (4) @(posedge clk);
        end
    endtask

    // JPO decode loop: one PUSHI 0/1 per OSR bit
    task jpo_prog(input [7:0] cfg);
        begin
            prog[0] = I(`OP_CFG, cfg);    prog[1] = I(`OP_PULL, 0);   prog[2] = I(`OP_SETL, 8);
            prog[3] = I(`OP_JPO, 6);      prog[4] = I(`OP_PUSHI, 0);  prog[5] = I(`OP_JMP, 7);
            prog[6] = I(`OP_PUSHI, 1);    prog[7] = I(`OP_DJNZ, 3);   prog[8] = I(`OP_HALT, 0);
        end
    endtask

    reg [7:0] got;
    initial begin
        // ---- JPO, MSB-first: 0xC1 in [31:24] -> 1,1,0,0,0,0,0,1
        jpo_prog(8'h40); run_prog(9, 32'hC100_0000);
        got = 0; for (k = 0; k < 8; k = k + 1) got = {got[6:0], rx[k][0]};
        `CHECK(nrx == 8 && got == 8'hC1 && !fault, "JPO MSB-first consumes bits 31.. in order")
        // ---- JPO, LSB-first: 0xC1 in [7:0] -> 1,0,0,0,0,0,1,1
        jpo_prog(8'h00); run_prog(9, 32'h0000_00C1);
        got = 0; for (k = 0; k < 8; k = k + 1) got = {rx[k][0], got[7:1]};
        `CHECK(nrx == 8 && got == 8'hC1 && !fault, "JPO LSB-first consumes bits 0.. in order")

        // ---- PUSHI writes the full 27-bit immediate and leaves the ISR alone
        pin_in = 8'h01;
        prog[0] = I(`OP_CFG, 8'h80);  prog[1] = I(`OP_WAITH, 0);   // the input synchronizer resets to 0
        prog[2] = I(`OP_IN1, 0);  prog[3] = I(`OP_IN1, 0);  prog[4] = I(`OP_IN1, 0);
        prog[5] = I(`OP_PUSHI, 27'h7FF_FFFF);  prog[6] = I(`OP_PUSHI, 27'h400_0003);  prog[7] = I(`OP_PUSH, 0);
        prog[8] = I(`OP_HALT, 0);
        run_prog(9, 0);
        `CHECK(nrx == 3 && rx[0] == 32'h07FF_FFFF && rx[1] == 32'h0400_0003, "PUSHI pushes the zero-extended immediate")
        `CHECK(rx[2] == 32'h0000_0007, "PUSHI leaves the ISR intact (3 sampled ones pushed after)")
        pin_in = 8'h00;

        // ---- PUSHI stalls on a full RX FIFO (depth 4) and resumes without loss
        drain = 0;
        for (k = 0; k < 5; k = k + 1) prog[k] = I(`OP_PUSHI, 27'h100 + k);
        prog[5] = I(`OP_HALT, 0);
        run_prog(6, 0);
        `CHECK(!halted && pc == 4, "PUSHI holds the PC while the FIFO is full")
        drain = 1;
        for (k = 0; k < 40; k = k + 1) @(posedge clk);
        `CHECK(halted && nrx == 5 && rx[0] == 32'h100 && rx[4] == 32'h104, "PUSHI resumes, all 5 words in order")

        `REPORT("tb_engine_ops")
        $finish;
    end
endmodule
