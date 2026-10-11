// AREA EXPERIMENT ONLY (never read by the simulation flow).
// Drop-in port-compatible stand-in for src/instr_mem.v built from two IHP 1P 64x16 macros
// (low half / high half of the 32-bit word). Run with
//   SYNTH_SKIP=instr_mem.v SYNTH_EXTRA=synth/experiments/instr_mem_sram_2x1p64x16.v
// to see what the chip costs when each engine's program lives in SRAM.
//
// Functionally this is NOT equivalent to instr_mem: the macro read is synchronous, so a real
// engine feeds `addr` with next_pc (pc_reg's D input) instead of pc, and run selects the
// host address while the engine is held. The stand-in has the same mux count as that scheme
// (6 address muxes), which is what matters for area. The synchronous-read timing contract is
// analysed in docs/ASIC_AREA_AND_MEMORY_STUDY.md; it is not simulated here.
module instr_mem #(
    parameter ADDR_WIDTH = 6,
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 64,
    parameter INIT_FILE  = ""
)(
    input  wire                  clk,
    input  wire [ADDR_WIDTH-1:0] addr,      // engine fetch address (next_pc in a real build)
    output wire [DATA_WIDTH-1:0] instr,
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata
);
    wire [5:0] a = we ? waddr : addr;       // host owns the port while the engine is held

    RM_IHPSG13_1P_64x16_c2 u_lo (
        .A_CLK(clk), .A_MEN(1'b1), .A_WEN(we), .A_REN(~we),
        .A_ADDR(a), .A_DIN(wdata[15:0]), .A_DLY(1'b1), .A_DOUT(instr[15:0]));
    RM_IHPSG13_1P_64x16_c2 u_hi (
        .A_CLK(clk), .A_MEN(1'b1), .A_WEN(we), .A_REN(~we),
        .A_ADDR(a), .A_DIN(wdata[31:16]), .A_DLY(1'b1), .A_DOUT(instr[31:16]));
endmodule
