// Program counter: holds at current value unless told to advance or jump.
// next_pc is the value pc will hold after the coming clock edge (0 while in reset). The
// instruction memory has a synchronous read, so it is addressed with next_pc: the word for
// the new pc is then on its output in the very cycle pc changes (see instr_mem.v).
// Reset vector: while in reset (and in the first clock after it) pc shows rst_val. A flag set by the
// reset does this, because a flop cannot reset asynchronously to a variable value. rst_val must not
// change while out of reset (RESET_PC is written only while the engine is held). rst_val = 0 behaves
// exactly like a plain reset-to-0 register.
module pc_reg #(
    parameter WIDTH = 6
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire [WIDTH-1:0] rst_val,
    input  wire             advance,
    input  wire             jump,
    input  wire [WIDTH-1:0] jump_addr,
    output wire [WIDTH-1:0] pc,
    output wire [WIDTH-1:0] next_pc
);
    reg [WIDTH-1:0] pc_q;
    reg             boot;               // 1 from reset until the first clock edge
    assign pc = boot ? rst_val : pc_q;

    //jump given more priority than advance
    assign next_pc = !rst_n ? rst_val       :
                     jump   ? jump_addr     :
                     advance ? pc + 1'b1    : pc;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            pc_q <= {WIDTH{1'b0}};
            boot <= 1'b1;
        end else begin
            pc_q <= next_pc;
            boot <= 1'b0;
        end
    end
endmodule
