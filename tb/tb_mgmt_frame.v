`timescale 1ns/1ps
`include "isa.vh"
`include "tb_common.vh"
// Step 3: 7-byte frame {op, addr[15:0], data[31:0]} through the Tiny Tapeout pins.
// ENG0_CTRL RUN gate + single instruction writes into engine 0. Waveform: build/tb_mgmt_frame.vcd
module tb_mgmt_frame;
    reg        clk = 0, rst_n = 0;
    reg        sclk = 0, mosi = 0, cs_n = 1;
    real       spi_half_ns = 80.0, spi_cs_ns = 60.0;
    wire [7:0] uo_out, uio_out, uio_oe;
    wire       miso = uo_out[0];

    tt_um_protocol_emulator dut (
        .ui_in({5'd0, cs_n, mosi, sclk}), .uo_out(uo_out),
        .uio_in(8'd0), .uio_out(uio_out), .uio_oe(uio_oe),
        .ena(1'b1), .clk(clk), .rst_n(rst_n));

    `include "spi_master.vh"

    localparam [7:0]  OP_WR    = 8'h01;
    localparam [15:0] A_CTRL   = 16'h1000;
    localparam [15:0] A_IMEM   = 16'h1100;
    localparam [31:0] W_HALT   = {`OP_HALT, 27'd0};
    localparam [31:0] W_ILLEGAL = {5'd31, 27'd0};

    integer errors = 0, k, cyc = 0, we_count = 0, we_cycle = -1, we_width = 0, cs_cycle = 0;
    reg [31:0] model [0:63];

    wire run    = dut.u_mgmt.eng_run[0];
    wire err    = dut.u_mgmt.err;
    wire halted = dut.u_eng0.halted;
    wire fault  = dut.u_eng0.fault;
    wire [5:0] pc = dut.u_eng0.pc;

    always #5 clk = ~clk;
    always @(posedge clk) cyc = cyc + 1;
    always @(negedge clk) begin
        if (|dut.u_mgmt.imem_we) begin
            if (we_width == 0) begin we_count = we_count + 1; we_cycle = cyc; end
            we_width = we_width + 1;
        end else if (we_width != 0) begin
            `CHECK(we_width == 1, "imem_we is a single-cycle pulse")
            we_width = 0;
        end
    end

    task settle; begin repeat (8) @(posedge clk); #1; end endtask

    task raw(input [127:0] v, input integer n);
        begin
            spi_begin; spi_bits(v, n);
            #(spi_cs_ns); cs_n = 1'b1; cs_cycle = cyc; #(spi_cs_ns);
            settle;
        end
    endtask

    task wr(input [15:0] a, input [31:0] d);
        raw({72'd0, OP_WR, a, d}, 56);
    endtask

    task check_mem(input [8*48-1:0] tag);
        integer j, bad;
        begin
            bad = 0;
            for (j = 0; j < 64; j = j + 1)
                if (dut.u_eng0.imem.peek(j) !== model[j]) bad = bad + 1;
            `CHECK(bad == 0, tag)
        end
    endtask

    // one instruction write, checked at the strobe level
    task wr_instr(input [5:0] i, input [31:0] w);
        integer n0;
        begin
            n0 = we_count;
            wr(A_IMEM + {i, 2'b00}, w);
            `CHECK(we_count == n0 + 1, "exactly one imem write")
            `CHECK(we_cycle == cs_cycle + 3, "imem write 3 clocks after CS_N rise")
            model[i] = w;
            check_mem("only the addressed word changed");
        end
    endtask

    task do_reset; begin rst_n = 0; repeat (2) @(posedge clk); #1 rst_n = 1; repeat (2) @(posedge clk); #1; end endtask

    // a frame that must be rejected: no imem write, RUN unchanged, err set
    task bad(input [127:0] v, input integer n, input [8*48-1:0] tag);
        integer n0; reg r0;
        begin
            do_reset; n0 = we_count; r0 = run;
            `CHECK(err == 0, "err clear after reset")
            raw(v, n);
            `CHECK(we_count == n0, tag)
            `CHECK(run == r0, "RUN unchanged by rejected frame")
            `CHECK(err == 1, "err set by rejected frame")
            check_mem("memory unchanged by rejected frame");
        end
    endtask

    initial begin
        $dumpfile("build/tb_mgmt_frame.vcd");
        $dumpvars(0, tb_mgmt_frame);
        for (k = 0; k < 64; k = k + 1) model[k] = 32'bx;     // never-written words must stay X
        repeat (3) @(posedge clk); #1 rst_n = 1;
        repeat (4) @(posedge clk); #1;

        $display("--- F1 reset state: engine held, pins released, nothing executes");
        `CHECK(run == 0 && err == 0, "RUN=0, err=0 after reset")
        `CHECK(pc == 0 && halted == 0 && fault == 0, "core held at PC 0")
        `CHECK(uio_oe === 8'h00, "all protocol pins released")
        repeat (50) @(posedge clk); #1;
        `CHECK(pc == 0 && uio_oe === 8'h00, "still held 50 clocks later")

        $display("--- F2 explicit halt (CTRL=0), then single instruction writes");
        wr(A_CTRL, 32'd0);
        `CHECK(run == 0 && err == 0, "CTRL=0 accepted")
        wr_instr(6'd0,  W_HALT);
        wr_instr(6'd37, 32'h3000_0000);
        wr_instr(6'd63, 32'h8000_0000);

        $display("--- F3 RUN executes the written word: HALT");
        wr(A_CTRL, 32'd1);
        `CHECK(run == 1, "RUN=1")
        `CHECK(halted == 1 && fault == 0 && pc == 0, "engine ran word 0 = HALT")

        $display("--- F4 instruction write while running is rejected");
        wr(A_IMEM, W_ILLEGAL);
        `CHECK(err == 1, "err set")
        check_mem("memory unchanged while running");
        do_reset;                                           // clears err and RUN, keeps memory
        `CHECK(run == 0 && err == 0 && halted == 0, "reset: RUN=0, err=0, core held")

        $display("--- F5 overwrite word 0 with a reserved opcode -> fault proves new word executes");
        wr_instr(6'd0, W_ILLEGAL);
        wr(A_CTRL, 32'd1);
        `CHECK(fault == 1 && halted == 1, "reserved opcode trapped")
        wr(A_CTRL, 32'd0);
        `CHECK(fault == 0 && halted == 0 && pc == 0, "RUN=0 clears fault/halt, PC=0")
        wr_instr(6'd0, W_HALT);
        wr(A_CTRL, 32'd1);
        `CHECK(fault == 0 && halted == 1, "HALT again, no fault")
        wr(A_CTRL, 32'd0);

        $display("--- F6 RUN released the pins it drove (word 0 = DIRO 4, word 1 = HALT)");
        wr_instr(6'd1, W_HALT);
        wr_instr(6'd0, {`OP_DIRO, 27'd4});
        wr(A_CTRL, 32'd1);
        `CHECK(uio_oe === 8'h10 && halted == 1, "DIRO 4 drove pin 4, then HALT")
        wr(A_CTRL, 32'd0);
        `CHECK(uio_oe === 8'h00, "RUN=0 released pin 4")

        $display("--- F7 rejected frames");
        bad({72'd0, 8'h00,  A_IMEM, 32'h1111_1111}, 56, "op 0x00 rejected");
        bad({72'd0, 8'h7F,  A_IMEM, 32'h1111_1111}, 56, "op 0x7F rejected");
        bad({72'd0, OP_WR, 16'h1101, 32'h1111_1111}, 56, "misaligned address rejected");
        bad({72'd0, OP_WR, 16'h1208, 32'h1111_1111}, 56, "unmapped 0x1208 rejected");
        bad({72'd0, OP_WR, 16'h3100, 32'h1111_1111}, 56, "unmapped 0x3100 rejected");
        bad({72'd0, OP_WR, 16'h0000, 32'h1111_1111}, 56, "unmapped 0x0000 rejected");
        bad({72'd0, OP_WR, A_CTRL,   32'h0000_0003}, 56, "CTRL reserved bits rejected");
        bad({80'd0, OP_WR, A_IMEM,   24'h111111},    48, "6 bytes rejected");
        bad({64'd0, OP_WR, A_IMEM,   32'h1111_1111, 8'h11}, 64, "8 bytes rejected");
        bad({69'd0, OP_WR, A_IMEM,   32'h1111_1111, 3'b101}, 59, "7 bytes + 3 bits rejected");
        bad({73'd0, OP_WR, A_IMEM,   31'h1111_1111}, 55, "55 bits rejected");
        do_reset; raw(128'd0, 0);
        `CHECK(err == 0, "empty CS_N pulse is not an error")
        wr(A_CTRL, 32'd1);
        raw({72'd0, OP_WR, A_CTRL, 32'h0000_0002}, 56);
        `CHECK(run == 1 && err == 1, "bad CTRL write leaves RUN=1")
        do_reset;

        $display("--- F8 SCLK sweep (half period 8.7, 13.3, 50, 8 clocks) and back-to-back frames");
        spi_half_ns = 87.0;  wr_instr(6'd10, 32'hA5C3_1E7F);
        spi_half_ns = 133.0; wr_instr(6'd11, 32'h0000_0001);
        spi_half_ns = 500.0; wr_instr(6'd12, 32'hFFFF_FFFF);
        spi_half_ns = 80.0;  spi_cs_ns = 40.0;
        wr_instr(6'd13, 32'h0BAD_F00D);
        wr_instr(6'd14, 32'h600D_CAFE);
        spi_cs_ns = 60.0;

        $display("--- F9 reset mid-frame leaves no residue");
        spi_begin; spi_bits({104'd0, OP_WR, A_IMEM}, 24);
        rst_n = 0; repeat (2) @(posedge clk); #1 rst_n = 1;
        spi_bits({96'd0, 32'h2222_2222}, 32);               // only 4 bytes after reset
        #(spi_cs_ns); cs_n = 1'b1; #(spi_cs_ns); settle;
        check_mem("no write after reset mid-frame");
        wr_instr(6'd15, 32'hC0DE_0042);

        `REPORT("tb_mgmt_frame")
        $finish;
    end
endmodule
