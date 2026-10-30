`ifdef SHARED_IMEM
// Shared instruction memory: ONE IHP SG13 2-port 512x32 SRAM macro for both engines (docs/SHARED_IMEM_PLAN.md).
//
//   Addresses are physical: the program counter is the word address. Port B serves engine 0 and port A engine 1 for fetch.
//   Each engine's window [base, limit) is set by its own firmware with OP_REGION (lock: once per run, cleared when the engine is
//   held). Power-up and every hold: the window is the whole memory, [0, 512).
//
//   A fetch outside the window returns TRAP (opcode 31), which the control unit faults on like any illegal opcode.
//
//   Host writes (one strobe per word) use the port of a HELD engine: port B when engine 0 is held, else port A when engine 1
//   is held. With both engines running there is no port for the host and the write is refused. A word is accepted only if no
//   running engine's window contains it. Host reads are not served here yet (readback needs a port pipeline in mgmt).
//
// Simulation: compile with -DFUNCTIONAL and sim/ihp_sram/RM_IHPSG13_2P_*.v. poke/peek use physical word numbers.
module imem_shared (
    input  wire        clk,
    input  wire        rst_n,
    input  wire [1:0]  run,
    // fetch ports (physical program counters); data one clock later
    input  wire [8:0]  f_addr0,
    input  wire [8:0]  f_addr1,
    output wire [31:0] f_raw0,       // macro output, port B (engine 0); the engine substitutes TRAP when f_oob0 is set
    output wire [31:0] f_raw1,       // macro output, port A (engine 1)
    output wire        f_oob0,       // registered: the fetched word lies outside engine 0's window
    output wire        f_oob1,
    // OP_REGION from the control units: window = {limit[9:0], base[8:0]}, operand fields 18:9 and 8:0
    input  wire        rg_go0,
    input  wire        rg_go1,
    input  wire [18:0] rg_val0,
    input  wire [18:0] rg_val1,
    output wire        locked0,
    output wire        locked1,
    // host write (mgmt): one strobe per word
    input  wire        iw_wr,
    input  wire [8:0]  iw_addr,
    input  wire [31:0] iw_data,
    output wire        iw_ok,
    // host read (mgmt): a one-clock strobe reads word iw_addr through a held engine's port; ir_valid pulses two clocks later with the word in ir_data
    input  wire        ir_rd,
    output reg  [31:0] ir_data,
    output reg         ir_valid,
    // the windows the engines hold, for the host's REGION read: {6'd0, limit[9:0], 7'd0, base[8:0]}
    output wire [31:0] region0,
    output wire [31:0] region1,
    // what reaches the macro, for the formal proofs (formal/imem_shared_props.sv); unconnected in the chip
    output wire        m_wa,
    output wire        m_wb,
    output wire [8:0]  m_aa,
    output wire [8:0]  m_ab
);
    localparam [31:0] TRAP = {5'd31, 27'd0};

    reg [8:0] base0, base1;
    reg [9:0] limit0, limit1;
    reg       lk0, lk1;
    assign locked0 = lk0;
    assign locked1 = lk1;

    // ------------------------------------------------------------------ windows
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            base0 <= 9'd0; limit0 <= 10'd512; lk0 <= 1'b0;
            base1 <= 9'd0; limit1 <= 10'd512; lk1 <= 1'b0;
        end else begin
            if (!run[0]) begin                       // held: the window returns to the whole memory, the lock clears
                base0 <= 9'd0; limit0 <= 10'd512; lk0 <= 1'b0;
            end else if (rg_go0) begin
                base0 <= rg_val0[8:0]; limit0 <= rg_val0[18:9]; lk0 <= 1'b1;
            end
            if (!run[1]) begin
                base1 <= 9'd0; limit1 <= 10'd512; lk1 <= 1'b0;
            end else if (rg_go1) begin
                base1 <= rg_val1[8:0]; limit1 <= rg_val1[18:9]; lk1 <= 1'b1;
            end
        end
    end

    // registered: a fetch outside the window traps the engine at its next instruction. The window used is the one that
    // takes effect in this clock (an OP_REGION in this clock already applies to the address fetched in it).
    // (written as if/else, not as a ?: mux: while the instruction is still unknown at start-up rg_go is X, and an if/else treats X as
    // false where a mux would spread X through oob into the instruction and back, which a 4-state simulation never leaves)
    reg oob0, oob1;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            oob0 <= 1'b0; oob1 <= 1'b0;
        end else begin
            if (rg_go0) oob0 <= !(({1'b0, f_addr0} >= {1'b0, rg_val0[8:0]}) && ({1'b0, f_addr0} < rg_val0[18:9]));
            else        oob0 <= !(({1'b0, f_addr0} >= {1'b0, base0})        && ({1'b0, f_addr0} < limit0));
            if (rg_go1) oob1 <= !(({1'b0, f_addr1} >= {1'b0, rg_val1[8:0]}) && ({1'b0, f_addr1} < rg_val1[18:9]));
            else        oob1 <= !(({1'b0, f_addr1} >= {1'b0, base1})        && ({1'b0, f_addr1} < limit1));
        end
    end

    // ------------------------------------------------------------------ host write rule
    wire in0 = ({1'b0, iw_addr} >= {1'b0, base0}) && ({1'b0, iw_addr} < limit0);
    wire in1 = ({1'b0, iw_addr} >= {1'b0, base1}) && ({1'b0, iw_addr} < limit1);
    wire port_b = !run[0];                    // engine 0 held: host uses port B
    wire port_a = run[0] && !run[1];          // engine 1 held, engine 0 running: host uses port A
    assign iw_ok = (port_b || port_a) && !(run[0] && in0) && !(run[1] && in1);
    wire wb = iw_wr && iw_ok && port_b;
    wire wa = iw_wr && iw_ok && port_a;

    // ------------------------------------------------------------------ the macro
    // the host's address is on the held engine's port only during its own write: in every other clock the held engine keeps
    // reading its start word, so it has its first instruction ready in the clock RUN rises
    wire [8:0]  addr_b = (port_b && (iw_wr || ir_rd)) ? iw_addr : f_addr0;
    wire [8:0]  addr_a = (port_a && (iw_wr || ir_rd)) ? iw_addr : f_addr1;
    wire [31:0] dout_a, dout_b;

    // host read: the address is on the held engine's port during the strobe clock, the macro answers one clock later (the same latency as a fetch)
    reg ir_q, ir_pb;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ir_q <= 1'b0; ir_pb <= 1'b0; ir_valid <= 1'b0; ir_data <= 32'd0;
        end else begin
            ir_q <= ir_rd; ir_pb <= port_b; ir_valid <= ir_q;
            if (ir_q) ir_data <= ir_pb ? dout_b : dout_a;
        end
    end
    assign region0 = {6'd0, limit0, 7'd0, base0};
    assign region1 = {6'd0, limit1, 7'd0, base1};

    // The trap substitution (oob ? TRAP : word) is done inside each engine, next to the decode: a gate here sat beside the macro in the
    // middle of the die and drove the long wire to the engine with a minimum-size cell (about 1 ns of slew in the sh4 run).
    assign f_raw0 = dout_b;
    assign f_raw1 = dout_a;
    assign f_oob0 = oob0;
    assign f_oob1 = oob1;

    assign m_wa = wa;  assign m_wb = wb;  assign m_aa = addr_a;  assign m_ab = addr_b;

    RM_IHPSG13_2P_512x32_c2_bm_bist u_mem (
        .A_CLK(clk), .A_MEN(1'b1), .A_WEN(wa), .A_REN(!wa), .A_ADDR(addr_a), .A_DIN(iw_data), .A_DLY(1'b1), .A_DOUT(dout_a),
        .A_BM({32{1'b1}}),
        .A_BIST_CLK(1'b0), .A_BIST_EN(1'b0), .A_BIST_MEN(1'b0), .A_BIST_WEN(1'b0), .A_BIST_REN(1'b0), .A_BIST_ADDR(9'd0),
        .A_BIST_DIN(32'd0), .A_BIST_BM(32'd0),
        .B_CLK(clk), .B_MEN(1'b1), .B_WEN(wb), .B_REN(!wb), .B_ADDR(addr_b), .B_DIN(iw_data), .B_DLY(1'b1), .B_DOUT(dout_b),
        .B_BM({32{1'b1}}),
        .B_BIST_CLK(1'b0), .B_BIST_EN(1'b0), .B_BIST_MEN(1'b0), .B_BIST_WEN(1'b0), .B_BIST_REN(1'b0), .B_BIST_ADDR(9'd0),
        .B_BIST_DIN(32'd0), .B_BIST_BM(32'd0));

`ifndef SYNTHESIS
    task poke(input integer a, input [31:0] w);
        begin
            u_mem.i_SRAM_2P_behavioral_bm_bist.mem_arr[a] = w;
        end
    endtask
    function [31:0] peek(input integer a);
        peek = u_mem.i_SRAM_2P_behavioral_bm_bist.mem_arr[a];
    endfunction
`endif
endmodule
`endif
