// Loop counter for DJNZ: decrement on command, saturates at 0.
// count_next = the value after the coming edge (the fetch stage resolves a DJNZ one clock early with it).
module loop_counter #(
    parameter WIDTH = 16
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             load,
    input  wire [WIDTH-1:0] load_value,
    input  wire             dec,
    output reg  [WIDTH-1:0] count,
    output wire [WIDTH-1:0] count_next
);
    assign count_next = load ? load_value :
                        (dec && count != {WIDTH{1'b0}}) ? count - 1'b1 : count;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            count <= {WIDTH{1'b0}};
        else
            count <= count_next;
    end
endmodule
