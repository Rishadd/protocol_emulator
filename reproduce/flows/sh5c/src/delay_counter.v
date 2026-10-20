// Counts down from load_value to 0; busy stays high until it reaches 0.
// last flags the final busy cycle so the control unit can release one cycle early.
module delay_counter #(
    parameter WIDTH = 27
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             load,
    input  wire [WIDTH-1:0] load_value,
    output wire             busy,
    output wire             last
);
    reg [WIDTH-1:0] count;

    assign busy = (count != {WIDTH{1'b0}});
    assign last = (count == {{(WIDTH-1){1'b0}}, 1'b1});

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)
            count <= {WIDTH{1'b0}};
        else if (load)
            count <= load_value;
        else if (count != {WIDTH{1'b0}})
            count <= count - 1'b1;
    end
endmodule
