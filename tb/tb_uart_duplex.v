// Duplex echo harness for host/uart_duplex_workload.py (de0_nano_duplex_top, 10 ns = 1 cycle):
//   +TXPROG +RXPROG +EDGES=<"ns level" rx line> +OUT=<log> +TEND=<ns>
// Log: S <ns> (RX IN1), B <ns> <byte> (pop/echo), T <ns> <level> (bt_tx_pin edges), STATUS.
`timescale 1ns/1ps
module tb_uart_duplex;
    reg  clk = 0, rst_n = 0, rx = 1;
    wire tx;
    wire [7:0] led;
    de0_nano_duplex_top dut (.clk_50M(clk), .reset_n(rst_n), .bt_rx_pin(rx), .bt_tx_pin(tx), .led(led));

    reg [8*256-1:0] txp, rxp, edges_f, out_f;
    integer fo, fe, r, t, l, tend, ledmis = 0, pops = 0;
    reg chk = 0, prev = 1'bx;
    reg [7:0] expv;

    always #5 clk = ~clk;
    always @(posedge clk) begin
        if (dut.u_rx.isr_shift) $fdisplay(fo, "S %0d", $time);
        chk = dut.rx_rd_en;
        if (chk) begin
            expv = dut.rx_rd_data[31:24];
            pops = pops + 1;
            $fdisplay(fo, "B %0d %0d", $time, expv);
        end
    end
    always @(negedge clk) begin
        if (chk && led !== expv) ledmis = ledmis + 1;
        if (tx !== prev) begin $fdisplay(fo, "T %0d %0d", $time, tx); prev = tx; end
    end

    initial begin
        if (!$value$plusargs("TXPROG=%s", txp) || !$value$plusargs("RXPROG=%s", rxp) ||
            !$value$plusargs("EDGES=%s", edges_f) || !$value$plusargs("OUT=%s", out_f) ||
            !$value$plusargs("TEND=%d", tend)) begin
            $display("ERROR: missing plusargs");
            $finish;
        end
        $readmemh(txp, dut.u_tx.imem.mem);
        $readmemh(rxp, dut.u_rx.imem.mem);
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
        $fdisplay(fo, "STATUS rx_fault=%0d tx_fault=%0d pops=%0d ledmis=%0d",
                  dut.u_rx.fault, dut.u_tx.fault, pops, ledmis);
        $fclose(fo);
        $finish;
    end
endmodule
