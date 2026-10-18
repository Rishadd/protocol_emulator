// Generic serial shift register, used both as OSR (shift_out) and ISR (shift_in).
// msb_first=0: out_bit = data[0], shift_out = >>1, shift_in enters at data[WIDTH-1].
// msb_first=1: out_bit = data[WIDTH-1], shift_out = <<1, shift_in enters at data[0].
// data_next = the value after the coming edge (the fetch stage resolves a JPO one clock early with it).
module shift_reg #(
    parameter WIDTH = 32
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             msb_first,
    input  wire             load,
    input  wire [WIDTH-1:0] load_value,
    input  wire             clear,
    input  wire             shift_out,
    input  wire             shift_in,
    input  wire             in_bit,
    output reg  [WIDTH-1:0] data,
    output wire [WIDTH-1:0] data_next,
    output wire             out_bit
);
    assign out_bit = msb_first ? data[WIDTH-1] : data[0];
    assign data_next = clear     ? {WIDTH{1'b0}} :
                       load      ? load_value :
                       shift_out ? (msb_first ? {data[WIDTH-2:0], 1'b0} : {1'b0, data[WIDTH-1:1]}) :
                       shift_in  ? (msb_first ? {data[WIDTH-2:0], in_bit} : {in_bit, data[WIDTH-1:1]}) : data;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            data <= {WIDTH{1'b0}};
        else
            data <= data_next;
    end
endmodule
