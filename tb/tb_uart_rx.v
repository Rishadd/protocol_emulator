// UART-RX workload harness driven by plusargs from host/uart_rx_workload.py:
//   +PROG=<hex 64 words>  +EDGES=<"time_ns level" lines for the rx line>  +OUT=<log>  +TEND=<ns>
// Engine runs the RX firmware, rx_fifo is drained by rx_led_sink. Log lines:
//   S <ns>        every IN1 execution (ISR shift) edge
//   B <ns> <byte> every word popped from rx_fifo (byte = [31:24])
// Also checks that led equals each popped byte on the cycle after the pop.
`timescale 1ns/1ps
module tb_uart_rx;
    reg         clk = 0, rst_n = 0, rx = 1;
    wire        tx_full, rx_empty, rx_rd_en, halted, fault;
    wire [31:0] rx_rd_data;
    wire [7:0]  pin_out, pin_oe, led;
    wire [5:0]  pc;

    engine_top dut (
        .clk(clk), .rst_n(rst_n),
        .tx_wr_en(1'b0), .tx_wr_data(32'd0), .tx_full(tx_full),
        .rx_rd_en(rx_rd_en), .rx_rd_data(rx_rd_data), .rx_empty(rx_empty),
        .pin_in({6'd0, rx, 1'b0}), .pin_out(pin_out), .pin_oe(pin_oe),
        .halted(halted), .fault(fault), .pc(pc));

    rx_led_sink sink (.clk(clk), .rst_n(rst_n), .rx_empty(rx_empty), .rx_rd_data(rx_rd_data),
                      .rx_rd_en(rx_rd_en), .led(led));

    reg [8*256-1:0] prog_f, edges_f, out_f;
    integer fo, fe, r, t, l, tend, ledmis = 0, pops = 0;
    reg chk = 0;
    reg [7:0] expv;

    always #5 clk = ~clk;

    always @(posedge clk) begin
        if (dut.isr_shift) $fdisplay(fo, "S %0d", $time);
        chk = rx_rd_en;
        if (rx_rd_en) begin
            expv = rx_rd_data[31:24];
            pops = pops + 1;
            $fdisplay(fo, "B %0d %0d", $time, rx_rd_data[31:24]);
        end
    end
    always @(negedge clk) if (chk && led !== expv) ledmis = ledmis + 1;

    initial begin
        if (!$value$plusargs("PROG=%s", prog_f) || !$value$plusargs("EDGES=%s", edges_f) ||
            !$value$plusargs("OUT=%s", out_f)   || !$value$plusargs("TEND=%d", tend)) begin
            $display("ERROR: missing plusargs");
            $finish;
        end
        $readmemh(prog_f, dut.imem.mem);
        fo = $fopen(out_f, "w");
        fe = $fopen(edges_f, "r");
        repeat (2) @(posedge clk);
        #1 rst_n = 1;
        while (!$feof(fe)) begin
            r = $fscanf(fe, "%d %d\n", t, l);
            if (r == 2) begin
                if (t > $time) #(t - $time);
                rx = l[0];
            end
        end
        if (tend > $time) #(tend - $time);
        $fdisplay(fo, "STATUS halted=%0d fault=%0d pc=%0d pops=%0d ledmis=%0d",
                  halted, fault, pc, pops, ledmis);
        $fclose(fo);
        $finish;
    end
endmodule
