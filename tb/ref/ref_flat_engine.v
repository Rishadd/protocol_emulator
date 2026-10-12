`include "isa.vh"
// REFERENCE MODEL (two-tier plan I2): one engine as an instruction-set model, written from
// instructions.md and the plan, not from src/ (only fifo is shared: unchanged since the plan).
// Flat memory: l1[0:63] (own L1) and l2[0:255] (this model's copy of the shared L2; the testbench
// writes it whenever it writes the real L2). The core steps only when ce = 1; the testbench drives
// ce = 0 in exactly the clocks the DUT bubbles or waits inside a COPY, so DUT and model must then show
// the same pins, FIFOs, pc and faults on every clock. COPY completes in one step here; the input
// synchronizer and the FIFOs' host ports never stop. ce is never 0 during a hold (WAIT/OUT1/IN1 d > 0).
module ref_flat_engine (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        run,
    input  wire        ce,
    input  wire        l2_en,
    input  wire [8:0]  reset_pc,
    input  wire [15:0] range,            // {hi, lo}: L2 words this engine may execute or copy
    input  wire        tx_wr_en,
    input  wire [31:0] tx_wr_data,
    output wire        tx_full,
    input  wire        rx_rd_en,
    output wire [31:0] rx_rd_data,
    output wire        rx_empty,
    input  wire [7:0]  pin_in,
    output reg  [7:0]  pin_out,
    output reg  [7:0]  pin_oe,
    output reg         halted,
    output reg         fault,
    output reg  [1:0]  cause,
    output wire [8:0]  pc                // shows reset_pc while held, like the engine
);
    reg [8:0]  pcr;
    assign pc = (rst_n && run) ? pcr : reset_pc;
    reg [31:0] l1 [0:63];
    reg [31:0] l2 [0:255];
    reg [7:0]  s0, s1;                   // 2-flop input synchronizer
    reg        hold;
    reg [26:0] dc;
    reg [15:0] lc;
    reg [31:0] osr, isr;
    reg [2:0]  cout, cin;
    reg        omsb, imsb;
    wire       core = rst_n & run;

    wire [31:0] w  = pcr[8] ? l2[pcr[7:0]] : l1[pcr[5:0]];
    wire [4:0]  op = w[31:27];
    wire [26:0] v  = w[26:0];
    wire [7:0]  lo = range[7:0], hi = range[15:8];
    wire [1:0]  pf = !pcr[8] ? (pcr[7:6] != 2'd0 ? 2'd1 : 2'd0) :
                     !l2_en ? 2'd1 : (pcr[7:0] < lo || pcr[7:0] > hi) ? 2'd2 : 2'd0;
    wire        obit = omsb ? osr[31] : osr[0];
    wire [31:0] osr_sh = omsb ? {osr[30:0], 1'b0} : {1'b0, osr[31:1]};
    wire [31:0] isr_sh = imsb ? {isr[30:0], s1[cin]} : {s1[cin], isr[31:1]};
    // COPY src,dst,n: [7:0] src, [13:8] dst, [19:14] n-1
    wire [8:0]  src_end = {1'b0, v[7:0]} + v[19:14];
    wire [6:0]  dst_end = {1'b0, v[13:8]} + v[19:14];
    wire        copy_bad = !pcr[8] || src_end[8] || v[7:0] < lo || src_end[7:0] > hi || dst_end[6];

    wire step = core && ce && !halted && !hold && pf == 2'd0;      // an instruction may act this clock
    wire tx_empty, rx_full;
    wire [31:0] tx_head;
    wire pull = step && op == `OP_PULL && !tx_empty;
    wire push = step && (op == `OP_PUSH || op == `OP_PUSHI) && !rx_full;
    fifo txf (.clk(clk), .rst_n(rst_n), .wr_en(tx_wr_en), .wr_data(tx_wr_data), .full(tx_full),
              .rd_en(pull), .rd_data(tx_head), .empty(tx_empty));
    fifo rxf (.clk(clk), .rst_n(rst_n), .wr_en(push), .wr_data(op == `OP_PUSHI ? {5'd0, v} : isr),
              .full(rx_full), .rd_en(rx_rd_en), .rd_data(rx_rd_data), .empty(rx_empty));

    integer i;
    task next; pcr <= pcr + 9'd1; endtask
    task timed; begin if (v == 27'd0) next; else begin hold <= 1'b1; dc <= v; end end endtask

    always @(posedge clk or negedge core) begin
        if (!core) begin
            pcr <= reset_pc; hold <= 1'b0; dc <= 27'd0; lc <= 16'd0; osr <= 32'd0; isr <= 32'd0;
            cout <= 3'd0; cin <= 3'd0; omsb <= 1'b0; imsb <= 1'b0; pin_out <= 8'd0; pin_oe <= 8'd0;
            halted <= 1'b0; fault <= 1'b0; cause <= 2'd0; s0 <= 8'd0; s1 <= 8'd0;
        end else begin
            s0 <= pin_in; s1 <= s0;
            if (ce && !halted) begin
                if (hold) begin
                    dc <= dc - 27'd1;
                    if (dc == 27'd1) begin hold <= 1'b0; next; end
                end else if (pf != 2'd0) begin
                    halted <= 1'b1; fault <= 1'b1; cause <= pf;
                end else case (op)
                    `OP_NOP:   next;
                    `OP_WAIT:  timed;
                    `OP_JMP:   pcr <= v[8:0];
                    `OP_HALT:  halted <= 1'b1;
                    `OP_SETL:  begin lc <= v[15:0]; next; end
                    `OP_DJNZ:  begin if (lc > 16'd1) pcr <= v[8:0]; else next; if (lc != 16'd0) lc <= lc - 16'd1; end
                    `OP_PULL:  if (!tx_empty) begin osr <= tx_head; next; end
                    `OP_PUSH:  if (!rx_full) begin isr <= 32'd0; next; end
                    `OP_OUT1:  begin pin_out[cout] <= obit; osr <= osr_sh; timed; end
                    `OP_IN1:   begin isr <= isr_sh; timed; end
                    `OP_SETH:  begin pin_out[v[2:0]] <= 1'b1; next; end
                    `OP_SETLO: begin pin_out[v[2:0]] <= 1'b0; next; end
                    `OP_DIRO:  begin pin_oe[v[2:0]] <= 1'b1; next; end
                    `OP_DIRI:  begin pin_oe[v[2:0]] <= 1'b0; next; end
                    `OP_WAITH: if (s1[v[2:0]]) next;
                    `OP_WAITL: if (!s1[v[2:0]]) next;
                    `OP_CFG:   begin cout <= v[2:0]; cin <= v[5:3]; omsb <= v[6]; imsb <= v[7]; next; end
                    `OP_JPH:   if (s1[v[11:9]]) pcr <= v[8:0]; else next;
                    `OP_JPL:   if (!s1[v[11:9]]) pcr <= v[8:0]; else next;
                    `OP_JPO:   begin osr <= osr_sh; if (obit) pcr <= v[8:0]; else next; end
                    `OP_PUSHI: if (!rx_full) next;
                    5'd21:     if (copy_bad) begin halted <= 1'b1; fault <= 1'b1; cause <= 2'd3; end   // COPY
                               else begin for (i = 0; i <= v[19:14]; i = i + 1) l1[v[13:8] + i] <= l2[v[7:0] + i]; next; end
                    default:   begin halted <= 1'b1; fault <= 1'b1; cause <= 2'd0; end
                endcase
            end
        end
    end
endmodule
