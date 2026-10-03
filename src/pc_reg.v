// Program counter: holds at current value unless told to advance or jump.
module pc_reg #(
    parameter WIDTH = 6
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             advance,
    input  wire             jump,
    input  wire [WIDTH-1:0] jump_addr,
    output reg  [WIDTH-1:0] pc
);
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= {WIDTH{1'b0}};
        else if (jump) //jump given more priority than advance
            pc <= jump_addr;
        else if (advance)
            pc <= pc + 1'b1;
    end
endmodule
