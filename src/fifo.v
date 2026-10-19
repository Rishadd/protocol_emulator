// Synchronous FIFO, first-word-fall-through (rd_data valid whenever !empty).
module fifo #(
    parameter WIDTH = 32,
    parameter DEPTH = 4
)(
    input  wire             clk,
    input  wire             rst_n,
    input  wire             wr_en,
    input  wire [WIDTH-1:0] wr_data,
    output wire             full,
    input  wire             rd_en,
    output wire [WIDTH-1:0] rd_data,
    output wire             empty,
    output wire [$clog2(DEPTH):0] level    // number of words stored
);
    localparam AW = (DEPTH > 1) ? $clog2(DEPTH) : 1;

    reg [WIDTH-1:0] mem [0:DEPTH-1];
    reg [AW-1:0]    wr_ptr, rd_ptr;
    reg [AW:0]      count;

    assign full    = (count == DEPTH);
    assign empty   = (count == 0);
    assign level   = count;
    assign rd_data = mem[rd_ptr];

    wire do_wr = wr_en && !full;
    wire do_rd = rd_en && !empty;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wr_ptr <= {AW{1'b0}};
            rd_ptr <= {AW{1'b0}};
            count  <= {(AW+1){1'b0}};
        end else begin
            if (do_wr) begin
                mem[wr_ptr] <= wr_data;
                wr_ptr <= (wr_ptr == DEPTH-1) ? {AW{1'b0}} : wr_ptr + 1'b1;
            end
            if (do_rd)
                rd_ptr <= (rd_ptr == DEPTH-1) ? {AW{1'b0}} : rd_ptr + 1'b1;
            case ({do_wr, do_rd})
                2'b10:   count <= count + 1'b1;
                2'b01:   count <= count - 1'b1;
                default: ;
            endcase
        end
    end
endmodule
