`timescale 1ns/1ps
`include "tb_common.vh"
// DE0-Nano top: press KEY1 -> expect the whole message on bt_tx_pin as 115200 8N1.
module tb_de0_nano_top;
    localparam integer BIT = 434;              // 50 MHz / 115200

    reg        clk = 0, reset_n = 0, start_n = 1, bt_rx_pin = 1;
    wire       bt_tx_pin;
    wire [7:0] led;
    integer    errors = 0, i, k, n;
    reg  [7:0] rxb;

    de0_nano_top #(.PROG_FILE("src/fpga/uart_tx_prog.hex"), .DEBOUNCE_BITS(4)) dut (
        .clk_50M(clk), .reset_n(reset_n), .start_n(start_n),
        .bt_rx_pin(bt_rx_pin), .bt_tx_pin(bt_tx_pin), .led(led));

    always #10 clk = ~clk;
    task tick; begin @(posedge clk); #1; end endtask

    // message taken from the DUT so the tb never duplicates the string
    integer MSG_LEN;
    initial MSG_LEN = dut.u_sender.MSG_LEN;
    function [7:0] msg_byte(input integer idx);
        msg_byte = dut.u_sender.MSG[8*(dut.u_sender.MSG_LEN-1-idx) +: 8];
    endfunction

    // mid-bit sampling receiver on bt_tx_pin
    task uart_rx(output [7:0] b);
        begin
            @(negedge clk); while (bt_tx_pin !== 1'b0) @(negedge clk);
            repeat (BIT / 2) @(negedge clk);
            `CHECK(bt_tx_pin == 0, "start bit mid-sample")
            for (k = 0; k < 8; k = k + 1) begin
                repeat (BIT) @(negedge clk);
                b[k] = bt_tx_pin;
            end
            repeat (BIT) @(negedge clk);
            `CHECK(bt_tx_pin == 1, "stop bit mid-sample")
        end
    endtask

    // count falling edges on bt_tx_pin (one per start bit)
    integer starts = 0;
    always @(negedge bt_tx_pin) if (reset_n) starts = starts + 1;

    task press_key(input integer hold_cycles);
        begin start_n = 0; repeat (hold_cycles) tick; start_n = 1; end
    endtask

    task receive_message;
        begin
            for (i = 0; i < MSG_LEN; i = i + 1) begin
                uart_rx(rxb);
                `CHECK(rxb == msg_byte(i), "message byte")
                if (rxb !== msg_byte(i)) $display("    byte %0d got %h expected %h", i, rxb, msg_byte(i));
            end
        end
    endtask

    initial begin
        $display("--- tb_de0_nano_top: MSG_LEN=%0d", MSG_LEN);
        repeat (3) tick;
        `CHECK(bt_tx_pin === 1'b1, "tx idle high during reset")
        reset_n = 1;
        repeat (20) tick;
        `CHECK(bt_tx_pin === 1'b1 && dut.pin_oe[0] == 1, "firmware drove pin 0 high")
        `CHECK(led[1] == 0 && led[2] == 0, "not halted, no fault")

        // glitch shorter than debounce must not send
        press_key(5);
        repeat (200) tick;
        `CHECK(starts == 0 && led[0] == 0, "5-cycle glitch ignored")

        // real press: whole message, in order
        press_key(100);
        receive_message;
        repeat (BIT * 2) tick;
        `CHECK(starts == MSG_LEN, "exactly MSG_LEN frames sent")
        `CHECK(led[0] == 0 && bt_tx_pin == 1, "sender idle, line high")

        // holding the key does not resend; releasing and pressing again does
        press_key(BIT * 20);
        repeat (BIT * 2) tick;
        n = starts;
        `CHECK(n == 2 * MSG_LEN, "second press sent one more message")
        press_key(100);
        receive_message;
        repeat (BIT * 2) tick;
        `CHECK(starts == 3 * MSG_LEN, "third press sent exactly one message")

        `REPORT("tb_de0_nano_top")
        $finish;
    end
endmodule
