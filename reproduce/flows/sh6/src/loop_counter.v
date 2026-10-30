// Loop counter for DJNZ: decrement on command, saturates at 0.
module loop_counter #(
    parameter WIDTH = 16
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             load,
    input  wire [WIDTH-1:0] load_value,
    input  wire             dec,
    output reg  [WIDTH-1:0] count
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            count <= {WIDTH{1'b0}};
        else if (load)
            count <= load_value;
        else if (dec && count != {WIDTH{1'b0}})
            count <= count - 1'b1;
    end
endmodule
