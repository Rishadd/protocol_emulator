// Instruction memory: combinational read (engine fetch), synchronous host write.
// The write port is the only way to load a program on silicon; INIT_FILE is kept for
// simulation and the FPGA tops. Memory bits have no reset (reset clears control, not storage).
// Read-during-write to the same address returns the old word until the clock edge.
module instr_mem #(
    parameter ADDR_WIDTH = 6,
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 64,
    parameter INIT_FILE  = ""
)(
    input  wire                  clk,
    // read port (engine fetch)
    input  wire [ADDR_WIDTH-1:0] addr,
    output wire [DATA_WIDTH-1:0] instr,
    // write port (host / management)
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata
);
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    generate if (INIT_FILE != "") begin : g_init
        initial $readmemh(INIT_FILE, mem);
    end endgenerate

    always @(posedge clk)
        if (we) mem[waddr] <= wdata;

    assign instr = mem[addr];
endmodule
