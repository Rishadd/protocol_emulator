// FPGA stand-in for the IHP 2-port 512x32 SRAM macro (same module name and ports, so imem_shared.v is used unchanged).
// Each port reads synchronously (data one clock after the address, held until the next read) and writes when WEN is high.
// Unused macro inputs (bit mask, BIST, DLY, MEN) are accepted and ignored: the chip ties them to constants.
module RM_IHPSG13_2P_512x32_c2_bm_bist (
    input  wire        A_CLK, A_MEN, A_WEN, A_REN, A_DLY,
    input  wire [8:0]  A_ADDR,
    input  wire [31:0] A_DIN, A_BM,
    output wire [31:0] A_DOUT,
    input  wire        A_BIST_CLK, A_BIST_EN, A_BIST_MEN, A_BIST_WEN, A_BIST_REN,
    input  wire [8:0]  A_BIST_ADDR,
    input  wire [31:0] A_BIST_DIN, A_BIST_BM,
    input  wire        B_CLK, B_MEN, B_WEN, B_REN, B_DLY,
    input  wire [8:0]  B_ADDR,
    input  wire [31:0] B_DIN, B_BM,
    output wire [31:0] B_DOUT,
    input  wire        B_BIST_CLK, B_BIST_EN, B_BIST_MEN, B_BIST_WEN, B_BIST_REN,
    input  wire [8:0]  B_BIST_ADDR,
    input  wire [31:0] B_BIST_DIN, B_BIST_BM
);
    // the array sits in an inner module named like the macro's model so the simulation helpers poke/peek of imem_shared.v work unchanged
    fpga_ram2p i_SRAM_2P_behavioral_bm_bist (
        .a_clk(A_CLK), .a_wen(A_WEN), .a_ren(A_REN), .a_addr(A_ADDR), .a_din(A_DIN), .a_dout(A_DOUT),
        .b_clk(B_CLK), .b_wen(B_WEN), .b_ren(B_REN), .b_addr(B_ADDR), .b_din(B_DIN), .b_dout(B_DOUT));
endmodule

module fpga_ram2p (
    input  wire a_clk, a_wen, a_ren, input wire [8:0] a_addr, input wire [31:0] a_din, output reg [31:0] a_dout,
    input  wire b_clk, b_wen, b_ren, input wire [8:0] b_addr, input wire [31:0] b_din, output reg [31:0] b_dout
);
    reg [31:0] mem_arr [0:511];
    always @(posedge a_clk) begin
        if (a_wen) mem_arr[a_addr] <= a_din;
        if (a_ren) a_dout <= mem_arr[a_addr];
    end
    always @(posedge b_clk) begin
        if (b_wen) mem_arr[b_addr] <= b_din;
        if (b_ren) b_dout <= mem_arr[b_addr];
    end
endmodule
