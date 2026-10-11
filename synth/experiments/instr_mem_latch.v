// AREA EXPERIMENT ONLY: latch-array instruction memory (64 x 32), same ports as src/instr_mem.v.
// Models the standard-cell alternative to SRAM: one transparent latch per bit, written
// through a per-word gate. The gate here is a plain AND (area stand-in); a real build would use
// a clock-gate cell (sg13cmos5l_lgcp_1, 27 um^2 per word) and hold wdata in a flop for the write.
// Run with SYNTH_SKIP=instr_mem.v SYNTH_EXTRA=synth/experiments/instr_mem_latch.v
module instr_mem #(
    parameter ADDR_WIDTH = 6,
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 64,
    parameter INIT_FILE  = ""
)(
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] addr,
    output wire [DATA_WIDTH-1:0] instr,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata
);
    reg [DATA_WIDTH-1:0] mem [0:DEPTH-1];
    reg [DATA_WIDTH-1:0] wd;
    always @(posedge clk) wd <= wdata;

    genvar i;
    generate for (i = 0; i < DEPTH; i = i + 1) begin : w
        wire gate = clk & we & (waddr == i);
        always @* if (gate) mem[i] = wd;
    end endgenerate

    assign instr = mem[addr];
endmodule
