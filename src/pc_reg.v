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
    input  wire [WIDTH-1:0] start,      // reset value: 0 in the default build, the host's START address in shared mode
    output reg  [WIDTH-1:0] pc,
    output wire [WIDTH-1:0] next_pc
);
    //jump given more priority than advance
    assign next_pc = !rst_n ? start :
                     jump   ? jump_addr     :
                     advance ? pc + 1'b1    : pc;

`ifdef SHARED_IMEM
    // The reset value is a register (the host's START address), and the cell library has no asynchronous-load flop: the held PC
    // takes START at every clock edge instead. next_pc is already START while held, so the memory is addressed correctly at once;
    // the PC register catches up one clock later, and the held core ignores it. START is written many clocks before RUN.
    always @(posedge clk)
        pc <= !rst_n ? start : next_pc;
`else
    // the default build always starts at 0 (start is tied to 0): asynchronous reset to a constant
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            pc <= {WIDTH{1'b0}};
        else
            pc <= next_pc;
    end
`endif
endmodule
