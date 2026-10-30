// Formal stand-in for the IHP 2-port SRAM macro of the shared instruction memory: same ports, both read data words are a fresh arbitrary
// value every clock. A property proved with it holds whatever the memory returns. The write enables and addresses stay visible
// (dut.u_mem.A_WEN ...) so the properties can look at what is written where.
module RM_IHPSG13_2P_512x32_c2_bm_bist (
    input         A_CLK, input A_MEN, input A_WEN, input A_REN, input [8:0] A_ADDR, input [31:0] A_DIN, input A_DLY, output [31:0] A_DOUT, input [31:0] A_BM,
    input         A_BIST_CLK, input A_BIST_EN, input A_BIST_MEN, input A_BIST_WEN, input A_BIST_REN, input [8:0] A_BIST_ADDR, input [31:0] A_BIST_DIN, input [31:0] A_BIST_BM,
    input         B_CLK, input B_MEN, input B_WEN, input B_REN, input [8:0] B_ADDR, input [31:0] B_DIN, input B_DLY, output [31:0] B_DOUT, input [31:0] B_BM,
    input         B_BIST_CLK, input B_BIST_EN, input B_BIST_MEN, input B_BIST_WEN, input B_BIST_REN, input [8:0] B_BIST_ADDR, input [31:0] B_BIST_DIN, input [31:0] B_BIST_BM
);
    (* anyseq *) wire [31:0] any_a;
    (* anyseq *) wire [31:0] any_b;
    assign A_DOUT = any_a;
    assign B_DOUT = any_b;
endmodule
