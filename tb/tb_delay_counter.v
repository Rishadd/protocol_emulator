`timescale 1ns/1ps
`include "tb_common.vh"
module tb_delay_counter;
    reg         clk = 0, rst_n = 0, load = 0;
    reg  [26:0] load_value = 0;
    wire        busy, last;
    integer errors = 0, i;

    delay_counter dut (.clk(clk), .rst_n(rst_n), .load(load),
                       .load_value(load_value), .busy(busy), .last(last));

    always #5 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    // load N, then busy must be high for exactly N cycles, last only on the Nth
    task test_load(input integer n);
        integer k;
        begin
            load = 1; load_value = n; tick; load = 0;
            for (k = 1; k <= n; k = k + 1) begin
                `CHECK(busy == 1, "A2 busy during countdown")
                `CHECK(last == (k == n), "A2 last only on final busy cycle")
                tick;
            end
            `CHECK(busy == 0, "A2 busy clears after N cycles")
            `CHECK(last == 0, "A2 last clears")
        end
    endtask

    initial begin
        tick; tick; rst_n = 1;
        `CHECK(busy == 0, "A2 reset busy=0")
        `CHECK(last == 0, "A2 reset last=0")

        test_load(0);
        test_load(1);
        test_load(2);
        test_load(100);

        // reload mid-count restarts the countdown
        load = 1; load_value = 10; tick; load = 0; tick; tick; tick;
        `CHECK(dut.count == 7, "A2 mid-count value")
        test_load(5);

        // max value loads without truncation
        load = 1; load_value = 27'h7FFFFFF; tick; load = 0;
        `CHECK(busy == 1 && last == 0, "A2 max value busy")
        `CHECK(dut.count == 27'h7FFFFFF, "A2 max value stored")

        `REPORT("tb_delay_counter")
        $finish;
    end
endmodule
