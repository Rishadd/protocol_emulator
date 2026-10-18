// Formal stand-in for the IHP SRAM macro: same ports, the read data is a fresh arbitrary value every clock. A property proved
// with it holds whatever the instruction memory returns (any program, any corruption).
module RM_IHPSG13_1P_256x32_c2_bm_bist (
    input         A_CLK,
    input         A_MEN,
    input         A_WEN,
    input         A_REN,
    input  [7:0]  A_ADDR,
    input  [31:0] A_DIN,
    input         A_DLY,
    output [31:0] A_DOUT,
    input  [31:0] A_BM,
    input         A_BIST_CLK,
    input         A_BIST_EN,
    input         A_BIST_MEN,
    input         A_BIST_WEN,
    input         A_BIST_REN,
    input  [7:0]  A_BIST_ADDR,
    input  [31:0] A_BIST_DIN,
    input  [31:0] A_BIST_BM
);
    (* anyseq *) wire [31:0] any_word;
    assign A_DOUT = any_word;
endmodule
