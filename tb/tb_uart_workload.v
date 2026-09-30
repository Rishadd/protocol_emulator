// Generic UART-TX workload harness driven by plusargs from host/uart_workload.py:
//   +PROG=<hex 64 words>  +DATA=<hex bytes>  +GAPS=<hex idle cycles before each byte>
//   +N=<byte count>  +CPB=<cycles per bit>  +OUT=<edge log>  +NOWAIT=0|1
// Logs every transition of pin 0 as "<cycle> <level>" so Python can check the
// waveform cycle-exactly. NOWAIT=1 makes the host ignore tx_full (limit test).
`timescale 1ns/1ps
module tb_uart_workload;
    reg         clk = 0, rst_n = 0, tx_wr_en = 0;
    reg  [31:0] tx_wr_data = 0;
    wire        tx_full, rx_empty, halted, fault;
    wire [31:0] rx_rd_data;
    wire [7:0]  pin_out, pin_oe;
    wire [5:0]  pc;

    engine_top dut (
        .clk(clk), .rst_n(rst_n),
        .tx_wr_en(tx_wr_en), .tx_wr_data(tx_wr_data), .tx_full(tx_full),
        .rx_rd_en(1'b0), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in(8'h00), .pin_out(pin_out), .pin_oe(pin_oe),
        .halted(halted), .fault(fault), .pc(pc));

    reg [7:0]       data [0:4095];
    reg [31:0]      gaps [0:4095];
    reg [8*256-1:0] prog_f, data_f, gaps_f, out_f;
    integer n_bytes, cpb, nowait, fd, i, rejected = 0;
    integer cycle = 0;

    always #5 clk = ~clk;
    always @(posedge clk) cycle = cycle + 1;
    task tick; begin @(posedge clk); #1; end endtask

    reg prev = 0;
    always @(negedge clk)
        if (pin_out[0] !== prev) begin
            $fdisplay(fd, "%0d %0d", cycle, pin_out[0]);
            prev = pin_out[0];
        end

    initial begin
        if (!$value$plusargs("PROG=%s", prog_f) || !$value$plusargs("DATA=%s", data_f) ||
            !$value$plusargs("GAPS=%s", gaps_f) || !$value$plusargs("OUT=%s", out_f) ||
            !$value$plusargs("N=%d", n_bytes)   || !$value$plusargs("CPB=%d", cpb)) begin
            $display("ERROR: missing plusargs");
            $finish;
        end
        if (!$value$plusargs("NOWAIT=%d", nowait)) nowait = 0;

        $readmemh(prog_f, dut.imem.mem);
        $readmemh(data_f, data);
        $readmemh(gaps_f, gaps);
        fd = $fopen(out_f, "w");

        tick; tick; rst_n = 1;

        for (i = 0; i < n_bytes; i = i + 1) begin
            repeat (gaps[i]) tick;
            if (nowait) begin
                if (tx_full) rejected = rejected + 1;
            end else begin
                while (tx_full) tick;
            end
            tx_wr_en = 1; tx_wr_data = {24'd0, data[i]}; tick; tx_wr_en = 0;
        end

        // drain: engine back at PULL with an empty FIFO, then a little idle time
        while (!(dut.tx_fifo.empty && pc == 3) && !halted) tick;
        repeat (12 * cpb) tick;

        $fdisplay(fd, "END %0d", cycle);
        $fdisplay(fd, "STATUS halted=%0d fault=%0d pc=%0d oe=%0d rejected=%0d",
                  halted, fault, pc, pin_oe[0], rejected);
        $fclose(fd);
        $finish;
    end
endmodule
