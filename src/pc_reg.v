// Program counter: holds at current value unless told to advance or jump.
// next_pc is the value pc will hold after the coming clock edge (0 while in reset). The
// instruction memory has a synchronous read, so it is addressed with next_pc: the word for
// the new pc is then on its output in the very cycle pc changes (see instr_mem.v).
module pc_reg #(
    parameter WIDTH = 8
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             advance,
    input  wire             jump,
    input  wire [WIDTH-1:0] jump_addr,
    output reg  [WIDTH-1:0] pc,
    output wire [WIDTH-1:0] next_pc
);
    //jump given more priority than advance
    assign next_pc = !rst_n ? {WIDTH{1'b0}} :
                     jump   ? jump_addr     :
                     advance ? pc + 1'b1    : pc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= {WIDTH{1'b0}};
        else
            pc <= next_pc;
    end
endmodule
