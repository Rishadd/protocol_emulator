// Formal properties of src/fifo.v (SymbiYosys, formal/fifo.sby): the FIFO behaves exactly like an ideal queue of depth 4.
// The reference is a shift queue kept here; equivalence means no word is lost, duplicated or reordered, a write when full and a
// read when empty change nothing, and full / empty / rd_data always match. The FIFO only moves data, so a 4-bit width proves the
// same control logic as the 32-bit instances (the depth, 4, is the real one).
module fifo_props (
    input wire       clk,
    input wire       wr_en,
    input wire [3:0] wr_data,
    input wire       rd_en
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = !init;

    wire       full, empty;
    wire [3:0] rd_data;
    fifo #(.WIDTH(4), .DEPTH(4)) dut (.clk(clk), .rst_n(rst_n), .wr_en(wr_en), .wr_data(wr_data), .full(full),
                                      .rd_en(rd_en), .rd_data(rd_data), .empty(empty));

    // reference queue: q[0] is the head
    reg [3:0] q0, q1, q2, q3;
    reg [2:0] n;
    wire m_wr = wr_en && n != 3'd4;
    wire m_rd = rd_en && n != 3'd0;
    always @(posedge clk) begin
        if (init) begin
            n <= 3'd0;
        end else begin
            // read: shift down; write: append behind the remaining words
            case ({m_wr, m_rd})
                2'b01: begin q0 <= q1; q1 <= q2; q2 <= q3; n <= n - 3'd1; end
                2'b10: begin
                    case (n) 3'd0: q0 <= wr_data; 3'd1: q1 <= wr_data; 3'd2: q2 <= wr_data; default: q3 <= wr_data; endcase
                    n <= n + 3'd1;
                end
                2'b11: begin
                    q0 <= (n == 3'd1) ? wr_data : q1;
                    q1 <= (n == 3'd2) ? wr_data : q2;
                    q2 <= (n == 3'd3) ? wr_data : q3;
                    q3 <= wr_data;                       // only meaningful when n = 4, which m_wr excludes; harmless
                end
                default: ;
            endcase
        end
    end

    always @(*) if (rst_n) begin
        assert (empty == (n == 3'd0));
        assert (full  == (n == 3'd4));
        assert (n <= 3'd4);
        if (n != 3'd0) assert (rd_data == q0);
    end
endmodule
