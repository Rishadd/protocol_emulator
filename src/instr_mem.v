// Instruction memory, 64 words x 32 bits: two IHP SG13 1P 64x16 SRAM macros side by side.
// Both macros get the same 6-bit address; u_lo stores bits [15:0] of every word, u_hi bits [31:16],
// so together they are one 64 x 32 memory (like two 16-bit-wide chips on one 32-bit bus).
//
//   fetch : SYNCHRONOUS read: instr = mem[addr] one clock after the edge that sampled addr.
//           engine_top drives addr with pc_reg.next_pc, so instr always holds the word for the
//           current pc (same behaviour as the old combinational mem[pc]).
//   write : we/waddr/wdata share the single macro port. While we=1 the host owns the port, so
//           writes are only legal while the engine is held (mgmt enforces RUN=0). The held engine
//           re-reads word 0 every clock, so RUN may rise from the second clock after the last write.
//   Contents are undefined after power-up; the engine is held until a program is written.
//
// Simulation: compile with -DFUNCTIONAL and sim/ihp_sram/*.v. Sim-only helpers poke(a,w), peek(a),
// load_hex(file) reach the macro storage, so testbenches need not know how it is built.
module instr_mem #(
    parameter ADDR_WIDTH = 6,       // fixed by the macros: 64 x 32 only
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 64,
    parameter INIT_FILE  = ""       // simulation preload only (macros cannot be preloaded)
)(
    input  wire                  clk,
    // fetch port (engine): addr = next_pc
    input  wire [ADDR_WIDTH-1:0] addr,
    output wire [DATA_WIDTH-1:0] instr,
    // write port (host / management)
    input  wire                  we,
    input  wire [ADDR_WIDTH-1:0] waddr,
    input  wire [DATA_WIDTH-1:0] wdata
);
    wire [5:0] a = we ? waddr : addr;       // host owns the port while writing

`ifdef FORMAL
    abs_sram #(.AW(6), .DW(32)) u_mem (.clk(clk), .men(1'b1), .wen(we), .ren(~we), .addr(a), .din(wdata), .dout(instr));
`else
    RM_IHPSG13_1P_64x16_c2 u_lo (
        .A_CLK(clk), .A_MEN(1'b1), .A_WEN(we), .A_REN(~we),
        .A_ADDR(a), .A_DIN(wdata[15:0]),  .A_DLY(1'b1), .A_DOUT(instr[15:0]));
    RM_IHPSG13_1P_64x16_c2 u_hi (
        .A_CLK(clk), .A_MEN(1'b1), .A_WEN(we), .A_REN(~we),
        .A_ADDR(a), .A_DIN(wdata[31:16]), .A_DLY(1'b1), .A_DOUT(instr[31:16]));
`endif

`ifndef SYNTHESIS
    initial if (ADDR_WIDTH != 6 || DATA_WIDTH != 32 || DEPTH != 64) begin
        $display("ERROR: instr_mem is fixed at 64x32 (got %0dx%0d)", DEPTH, DATA_WIDTH);
        $finish;
    end

    task poke(input integer a, input [31:0] w);
        begin
            u_lo.i_SRAM_1P_behavioral.memory[a] = w[15:0];
            u_hi.i_SRAM_1P_behavioral.memory[a] = w[31:16];
        end
    endtask
    function [31:0] peek(input integer a);
        peek = {u_hi.i_SRAM_1P_behavioral.memory[a], u_lo.i_SRAM_1P_behavioral.memory[a]};
    endfunction
    task load_hex(input [8*256-1:0] f);
        reg [31:0] img [0:63];
        integer k;
        begin
            for (k = 0; k < 64; k = k + 1) img[k] = {32{1'bx}};
            $readmemh(f, img);
            for (k = 0; k < 64; k = k + 1) poke(k, img[k]);
        end
    endtask
    initial if (INIT_FILE != "") load_hex(INIT_FILE);
`endif
endmodule
