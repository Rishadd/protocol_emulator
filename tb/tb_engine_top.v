`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
module tb_engine_top;
    reg         clk = 0, rst_n = 0;
    reg         tx_wr_en = 0, rx_rd_en = 0;
    reg  [31:0] tx_wr_data = 0;
    reg  [7:0]  pin_in = 0;
    wire [31:0] rx_rd_data;
    wire        tx_full, rx_empty, halted, fault;
    wire [7:0]  pin_out, pin_oe;
    wire [7:0]  pc;

    integer errors = 0, i, n, edges;
    integer cycle = 0;
    reg  [7:0] rxb;
    reg  [7:0] bytes [0:3];
    reg  [7:0] pin1_hist [0:31];
    reg  [7:0] pc_hist   [0:31];
    reg        halt_hist [0:31];

    engine_top dut (
        .clk(clk), .rst_n(rst_n),
        .imem_we(1'b0), .imem_waddr(8'd0), .imem_wdata(32'd0), .run(1'b1),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full),
        .rx_rd_en(rx_rd_en), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in(pin_in), .pin_out(pin_out), .pin_oe(pin_oe),
        .halted(halted), .fault(fault), .pc(pc));

    always #5 clk = ~clk;
    always @(posedge clk) cycle = cycle + 1;
    task tick; begin @(posedge clk); #1; end endtask
    // run is tied to 1 here: after reset the fetch stage primes for 2 clocks (reads word 0, then its successor) before the core
    // runs, so the reset sequence ends when the engine is ready; the checks count clocks from there
    task do_reset; begin rst_n = 0; tick; tick; rst_n = 1; tick; tick; end endtask

    function [31:0] I(input [4:0] op, input [26:0] opnd);
        I = {op, opnd};
    endfunction

    task clear_mem;
        integer k;
        for (k = 0; k < 64; k = k + 1) dut.imem.poke(k, I(`OP_HALT, 0));
    endtask

    task host_write(input [31:0] w);
        begin tx_wr_en = 1; tx_wr_data = w; tick; tx_wr_en = 0; end
    endtask

    // ---------------- UART TX reference program ----------------
    // bit period = D+2 cycles for start and every data bit (see report).
    task load_uart_prog(input [26:0] D);
        begin
            clear_mem;
            dut.imem.poke(0, I(`OP_CFG,   0));   // out_pin=0, LSB first
            dut.imem.poke(1, I(`OP_DIRO,  0));
            dut.imem.poke(2, I(`OP_SETH,  0));   // idle high
            dut.imem.poke(3, I(`OP_PULL,  0));   // block for next byte
            dut.imem.poke(4, I(`OP_SETL,  8));
            dut.imem.poke(5, I(`OP_SETLO, 0));   // start bit
            dut.imem.poke(6, I(`OP_WAIT,  D));
            dut.imem.poke(7, I(`OP_OUT1,  D));   // data bit
            dut.imem.poke(8, I(`OP_DJNZ,  7));
            dut.imem.poke(9, I(`OP_SETH,  0));   // stop bit
            dut.imem.poke(10, I(`OP_WAIT,  D));
            dut.imem.poke(11, I(`OP_JMP,   3));
        end
    endtask

    // edge-interval recorder on pin 0 (cycles between consecutive transitions)
    reg     prev0 = 0;
    integer last_edge = 0, n_int = 0;
    integer intervals [0:63];
    always @(negedge clk) begin
        if (pin_out[0] !== prev0) begin
            if (n_int < 64) intervals[n_int] = cycle - last_edge;
            n_int = n_int + 1;
            last_edge = cycle;
            prev0 = pin_out[0];
        end
    end

    // mid-bit sampling UART receiver
    task uart_rx(input integer BIT, output [7:0] b);
        integer k;
        begin
            @(negedge clk); while (pin_out[0] !== 1'b0) @(negedge clk);
            repeat (BIT / 2) @(negedge clk);
            `CHECK(pin_out[0] == 0, "UART start bit mid-sample")
            for (k = 0; k < 8; k = k + 1) begin
                repeat (BIT) @(negedge clk);
                b[k] = pin_out[0];
            end
            repeat (BIT) @(negedge clk);
            `CHECK(pin_out[0] == 1, "UART stop bit mid-sample")
        end
    endtask

    task uart_test(input integer BIT, input [64*8-1:0] name);
        begin
            $display("--- %0s (BIT=%0d, D=%0d)", name, BIT, BIT - 2);
            load_uart_prog(BIT - 2);
            do_reset;
            bytes[0] = 8'h55; bytes[1] = 8'hA3; bytes[2] = 8'h00; bytes[3] = 8'hFF;
            for (i = 0; i < 4; i = i + 1) host_write({24'd0, bytes[i]});
            `CHECK(tx_full == 1 || dut.tx_fifo.count >= 3, "fifo accepted 4 bytes")
            while (pin_out[0] !== 1'b1) tick;
            `CHECK(pin_oe[0] == 1, "pin 0 driven")
            n_int = 0; last_edge = cycle;
            for (i = 0; i < 4; i = i + 1) begin
                uart_rx(BIT, rxb);
                `CHECK(rxb == bytes[i], "UART byte value")
                if (rxb !== bytes[i]) $display("    got %h expected %h", rxb, bytes[i]);
            end
            // 0x55 toggles on every bit: intervals[1..9] must each be exactly BIT
            for (i = 1; i <= 9; i = i + 1) begin
                `CHECK(intervals[i] == BIT, "UART bit interval exact")
                if (intervals[i] !== BIT) $display("    interval[%0d]=%0d", i, intervals[i]);
            end
            `CHECK(intervals[10] == BIT + 3, "UART stop->start = BIT+3 (SETH+WAIT+JMP+PULL+SETL)")
            if (intervals[10] !== BIT + 3) $display("    interval[10]=%0d", intervals[10]);
            repeat (BIT) tick;
            `CHECK(pin_out[0] == 1 && pc == 3 && halted == 0, "engine parked at PULL, line idle high")
        end
    endtask

    initial begin
        // ---------------- B1: PC / imem / decode ----------------
        $display("--- B1 pc flow");
        clear_mem;
        dut.imem.poke(0, I(`OP_NOP, 0));
        dut.imem.poke(1, I(`OP_NOP, 0));
        dut.imem.poke(2, I(`OP_JMP, 5));
        dut.imem.poke(5, I(`OP_NOP, 0));
        dut.imem.poke(6, I(`OP_JMP, 0));
        do_reset;
        `CHECK(pc == 0, "B1 pc=0 after reset")
        for (n = 1; n <= 20; n = n + 1) begin
            tick;
            case (n % 5)
                1: `CHECK(pc == 1, "B1 seq")
                2: `CHECK(pc == 2, "B1 seq")
                3: `CHECK(pc == 5, "B1 seq")
                4: `CHECK(pc == 6, "B1 seq")
                0: `CHECK(pc == 0, "B1 seq")
            endcase
            `CHECK(pc != 3 && pc != 4, "B1 never visits HALT slots")
            `CHECK(halted == 0, "B1 never halts")
        end

        // ---------------- B2: delay stall ----------------
        $display("--- B2 delay stall");
        clear_mem;
        dut.imem.poke(0, I(`OP_DIRO,  1));
        dut.imem.poke(1, I(`OP_SETH,  1));
        dut.imem.poke(2, I(`OP_WAIT, 10));
        dut.imem.poke(3, I(`OP_SETLO, 1));
        dut.imem.poke(4, I(`OP_WAIT,  0));
        dut.imem.poke(5, I(`OP_SETH,  1));
        dut.imem.poke(6, I(`OP_HALT,  0));
        do_reset;
        for (n = 1; n <= 20; n = n + 1) begin
            tick;
            pin1_hist[n] = pin_out[1]; pc_hist[n] = pc; halt_hist[n] = halted;
        end
        `CHECK(pin1_hist[1] == 0 && pin_oe[1] == 1, "B2 DIRO first")
        `CHECK(pin1_hist[2] == 1, "B2 rise at n=2")
        for (n = 2; n <= 12; n = n + 1) `CHECK(pc_hist[n] == 2, "B2 pc frozen at WAIT for 11 cycles")
        `CHECK(pc_hist[13] == 3, "B2 pc leaves WAIT at n=13")
        for (n = 3; n <= 13; n = n + 1) `CHECK(pin1_hist[n] == 1, "B2 pin high through WAIT")
        `CHECK(pin1_hist[14] == 0, "B2 fall at n=14 (= rise+12)")
        `CHECK(pin1_hist[15] == 0, "B2 WAIT 0 holds one cycle")
        `CHECK(pin1_hist[16] == 1, "B2 rise at n=16 (= fall+2)")
        `CHECK(halt_hist[16] == 0 && halt_hist[17] == 1, "B2 halts at n=17")
        `CHECK(fault == 0, "B2 no fault")

        // ---------------- B3: loop ----------------
        $display("--- B3 DJNZ loop");
        clear_mem;
        dut.imem.poke(0, I(`OP_DIRO,  2));
        dut.imem.poke(1, I(`OP_SETL,  5));
        dut.imem.poke(2, I(`OP_SETH,  2));
        dut.imem.poke(3, I(`OP_SETLO, 2));
        dut.imem.poke(4, I(`OP_DJNZ,  2));
        dut.imem.poke(5, I(`OP_HALT,  0));
        do_reset;
        edges = 0; prev0 = 0;
        for (n = 0; n < 100 && !halted; n = n + 1) begin
            tick;
            if (pin_out[2] && !prev0) edges = edges + 1;
            prev0 = pin_out[2];
        end
        `CHECK(edges == 5, "B3 exactly 5 pulses")
        `CHECK(halted == 1 && fault == 0, "B3 halts cleanly")
        prev0 = 0;

        // ---------------- B4: PULL blocking ----------------
        $display("--- B4 PULL blocking");
        clear_mem;
        dut.imem.poke(0, I(`OP_PULL, 0));
        dut.imem.poke(1, I(`OP_NOP,  0));
        do_reset;
        for (n = 0; n < 50; n = n + 1) begin
            tick;
            `CHECK(pc == 0, "B4 pc holds at PULL with empty fifo")
        end
        `CHECK(dut.osr.data == 0, "B4 OSR untouched while blocked")
        host_write(32'h12345678);
        `CHECK(dut.tx_fifo.empty == 0, "B4 fifo has data")
        tick;
        `CHECK(dut.osr.data == 32'h12345678, "B4 OSR loaded")
        `CHECK(pc == 1, "B4 pc advanced")
        `CHECK(dut.tx_fifo.empty == 1, "B4 fifo popped")

        // ---------------- B5: trap ----------------
        $display("--- B5 reserved opcode trap");
        clear_mem;
        dut.imem.poke(0, I(`OP_NOP, 0));
        dut.imem.poke(1, I(`OP_NOP, 0));
        dut.imem.poke(2, I(`OP_NOP, 0));
        dut.imem.poke(3, I(5'd31, 0));
        dut.imem.poke(4, I(`OP_SETH, 0));
        do_reset;
        tick; tick; tick;
        `CHECK(pc == 3 && halted == 0, "B5 reaches illegal word")
        tick;
        `CHECK(halted == 1 && fault == 1 && pc == 3, "B5 traps in one cycle")
        for (n = 0; n < 10; n = n + 1) tick;
        `CHECK(halted == 1 && fault == 1 && pc == 3, "B5 stays trapped")
        `CHECK(pin_out == 0 && pin_oe == 0, "B5 no side effects after trap")

        // ---------------- B6 / B7: UART ----------------
        uart_test(434,  "B6 UART 115200 @50MHz");
        uart_test(5208, "B7 UART 9600 @50MHz");

        // ---------------- B8: reset mid-transmission ----------------
        $display("--- B8 reset mid-frame");
        load_uart_prog(432);
        do_reset;
        host_write(32'h55);
        repeat (600) tick;
        `CHECK(pc >= 7 && pc <= 8, "B8 mid data bits before reset")
        rst_n = 0; #1;
        `CHECK(pin_oe == 0 && pin_out == 0, "B8 pins released immediately on reset")
        `CHECK(pc == 0 && halted == 0 && fault == 0, "B8 core state cleared")
        tick; rst_n = 1;
        host_write(32'hA3);
        while (pin_out[0] !== 1'b1) tick;
        uart_rx(434, rxb);
        `CHECK(rxb == 8'hA3, "B8 byte after reset")

        `REPORT("tb_engine_top")
        $finish;
    end
endmodule
