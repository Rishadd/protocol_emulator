// Read-only instruction memory, host-write port added later.
// Load contents in a testbench with:
//   $readmemh("program.hex", <top>.imem.mem);
// or set INIT_FILE for a synthesizable ROM init (Quartus honours $readmemh).
module instr_mem #(
    parameter ADDR_WIDTH = 6,
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 64,
    parameter INIT_FILE  = ""
)(
    input  wire [ADDR_WIDTH-1:0] addr,
    output wire [DATA_WIDTH-1:0] instr
);
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];

    generate if (INIT_FILE != "") begin : g_init
        initial $readmemh(INIT_FILE, mem);
    end endgenerate

    assign instr = mem[addr];
endmodule
