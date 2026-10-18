// Instruction memory, 256 words x 32 bits: one IHP SG13 1P 256x32 SRAM macro (bit-mask + BIST variant).
//
//   fetch : SYNCHRONOUS read: instr = mem[addr] one clock after the edge that sampled addr.
//           engine_top drives addr with pc_reg.next_pc, so instr always holds the word for the
//           current pc (same behaviour as the old combinational mem[pc]).
//   write : we/waddr/wdata share the single macro port. While we=1 the host owns the port, so
//           writes are only legal while the engine is held (mgmt enforces RUN=0). The held engine
//           re-reads word 0 every clock, so RUN may rise from the second clock after the last write.
//   Contents are undefined after power-up; the engine is held until a program is written.
//   Unused macro inputs: A_BM all ones (every bit written), BIST port tied off (A_BIST_EN = 0).
//
// Simulation: compile with -DFUNCTIONAL and sim/ihp_sram/*.v. Sim-only helpers poke(a,w), peek(a),
// load_hex(file) reach the macro storage, so testbenches need not know how it is built.
module instr_mem #(
    parameter ADDR_WIDTH = 8,       // fixed by the macro: 256 x 32 only
    parameter DATA_WIDTH = 32,
    parameter DEPTH      = 256,
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
    wire [7:0] a = we ? waddr : addr;       // host owns the port while writing

    RM_IHPSG13_1P_256x32_c2_bm_bist u_mem (
        .A_CLK(clk), .A_MEN(1'b1), .A_WEN(we), .A_REN(~we),
        .A_ADDR(a), .A_DIN(wdata), .A_DLY(1'b1), .A_DOUT(instr), .A_BM({32{1'b1}}),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0),
        .A_BIST_REN(1'b0), .A_BIST_ADDR(8'd0), .A_BIST_DIN(32'd0), .A_BIST_BM(32'd0));

`ifndef SYNTHESIS
    initial if (ADDR_WIDTH != 8 || DATA_WIDTH != 32 || DEPTH != 256) begin
        $display("ERROR: instr_mem is fixed at 256x32 (got %0dx%0d)", DEPTH, DATA_WIDTH);
        $finish;
    end

    integer poke_count = 0;     // engine_top primes its fetch stage again after a poke (a poke bypasses the write port)
    task poke(input integer a, input [31:0] w);
        begin
            u_mem.i_SRAM_1P_behavioral_bm_bist.memory[a] = w;
            poke_count = poke_count + 1;
        end
    endtask
    function [31:0] peek(input integer a);
        peek = u_mem.i_SRAM_1P_behavioral_bm_bist.memory[a];
    endfunction
    task load_hex(input [8*256-1:0] f);
        reg [31:0] img [0:255];
        integer k;
        begin
            for (k = 0; k < 256; k = k + 1) img[k] = {32{1'bx}};
            $readmemh(f, img);
            for (k = 0; k < 256; k = k + 1) poke(k, img[k]);
        end
    endtask
    initial if (INIT_FILE != "") load_hex(INIT_FILE);
`endif
endmodule
