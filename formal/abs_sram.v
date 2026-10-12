// Abstract single-port SRAM with the IHP 1P macro behaviour that the design relies on:
// synchronous read (dout = mem[addr] one clock after the edge), dout holds when not reading,
// write-through when wen and ren are both set, nothing happens while men = 0. Full-word writes only.
// Used where the vendor model cannot go (formal proofs, coverage builds). tb_l2_macro proves in
// simulation that it matches RM_IHPSG13_1P_256x32_c2_bm_bist cycle by cycle.
module abs_sram #(
    parameter AW = 8,
    parameter DW = 32
)(
    input  wire          clk,
    input  wire          men,
    input  wire          wen,
    input  wire          ren,
    input  wire [AW-1:0] addr,
    input  wire [DW-1:0] din,
    output reg  [DW-1:0] dout
);
    reg [DW-1:0] mem [0:(1<<AW)-1];
    always @(posedge clk) begin
        if (men && wen) mem[addr] <= din;
        if (men && ren) dout <= wen ? din : mem[addr];
    end
endmodule
