// Formal properties of the shared instruction memory (src/imem_shared.v, the 2P macro replaced by formal/sram2p_free.v: any data comes back).
// (The properties look at the window through region0 / region1 / locked and at the macro's write strobes through the m_* ports: Yosys does not resolve
// hierarchical references into a submodule.)
//   P1 fetch stays in the window: an engine that is running only ever decodes a word (not the TRAP substitute) that was fetched from an address inside the
//      window in force in that clock (the one set by an OP_REGION in the same clock, else the registered one). Outside it the word is replaced by TRAP.
//   P2 host writes never change a running window: no write reaches the macro through a running engine's port, and a write never lands on a word inside
//      the window of a running engine; with both engines running nothing is written at all.
//   P3 the lock holds until RUN falls: while an engine runs and its window is locked, the lock and the window are constant; a held engine's window is the
//      whole memory and unlocked one clock later; the first OP_REGION of a run sets exactly the window it names and the lock.
// P3 uses the assumption proved in region_go.sby on the control unit: an OP_REGION reaches the memory (rg_go) only when the engine is not locked and
// the window is valid (base < limit <= 512). The environment is otherwise free: any run / fetch address / host write sequence.
module imem_shared_props (
    input wire        clk,
    input wire        rst_n_in,
    input wire [1:0]  run,
    input wire [8:0]  f_addr0,
    input wire [8:0]  f_addr1,
    input wire        rg_go0,
    input wire        rg_go1,
    input wire [18:0] rg_val0,
    input wire [18:0] rg_val1,
    input wire        iw_wr,
    input wire [8:0]  iw_addr,
    input wire [31:0] iw_data,
    input wire        ir_rd
);
    reg init = 1'b1;
    always @(posedge clk) init <= 1'b0;
    wire rst_n = rst_n_in && !init;

    wire [31:0] f_raw0, f_raw1, ir_data, region0, region1;
    wire        f_oob0, f_oob1, locked0, locked1, iw_ok, ir_valid, wa, wb;
    wire [8:0]  aa, ab;
    imem_shared dut (.clk(clk), .rst_n(rst_n), .run(run), .f_addr0(f_addr0), .f_addr1(f_addr1), .f_raw0(f_raw0), .f_raw1(f_raw1),
                     .f_oob0(f_oob0), .f_oob1(f_oob1), .rg_go0(rg_go0), .rg_go1(rg_go1), .rg_val0(rg_val0), .rg_val1(rg_val1),
                     .locked0(locked0), .locked1(locked1), .iw_wr(iw_wr), .iw_addr(iw_addr), .iw_data(iw_data), .iw_ok(iw_ok),
                     .ir_rd(ir_rd), .ir_data(ir_data), .ir_valid(ir_valid), .region0(region0), .region1(region1),
                     .m_wa(wa), .m_wb(wb), .m_aa(aa), .m_ab(ab));

    // what the control unit guarantees (region_go.sby)
    always @(*) begin
        assume (!(rg_go0 && locked0));
        assume (!(rg_go1 && locked1));
        assume (!rg_go0 || ({1'b0, rg_val0[8:0]} < rg_val0[18:9] && rg_val0[18:9] <= 10'd512));
        assume (!rg_go1 || ({1'b0, rg_val1[8:0]} < rg_val1[18:9] && rg_val1[18:9] <= 10'd512));
    end

    // one clock of history
    reg        p_ok = 1'b0;                                     // the previous clock was out of reset
    reg [1:0]  p_run;
    reg [8:0]  p_a0, p_a1, p_b0, p_b1;
    reg [9:0]  p_l0, p_l1;
    reg        p_g0, p_g1, p_k0, p_k1;
    reg [18:0] p_v0, p_v1;
    always @(posedge clk) begin
        p_ok <= rst_n;
        p_run <= run; p_a0 <= f_addr0; p_a1 <= f_addr1;
        p_b0 <= region0[8:0]; p_b1 <= region1[8:0]; p_l0 <= region0[25:16]; p_l1 <= region1[25:16];
        p_g0 <= rg_go0; p_g1 <= rg_go1; p_k0 <= locked0; p_k1 <= locked1; p_v0 <= rg_val0; p_v1 <= rg_val1;
    end

    // window in force in the previous clock (OP_REGION of that clock applies to the address of that clock)
    wire [8:0] eb0 = p_g0 ? p_v0[8:0] : p_b0;
    wire [9:0] el0 = p_g0 ? p_v0[18:9] : p_l0;
    wire [8:0] eb1 = p_g1 ? p_v1[8:0] : p_b1;
    wire [9:0] el1 = p_g1 ? p_v1[18:9] : p_l1;

    // ---------------------------------------------------------------- P1
    always @(*) if (rst_n && p_ok && p_run[0] && !f_oob0) assert ({1'b0, p_a0} >= {1'b0, eb0} && {1'b0, p_a0} < el0);
    always @(*) if (rst_n && p_ok && p_run[1] && !f_oob1) assert ({1'b0, p_a1} >= {1'b0, eb1} && {1'b0, p_a1} < el1);

    // ---------------------------------------------------------------- P2
    always @(*) if (rst_n) begin
        if (wb) assert (!run[0]);                               // port B is engine 0's: never written while it runs
        if (wa) assert (!run[1]);
        if (wa || wb) assert (!(run[0] && run[1]));             // both running: nothing is written
        if (wb && run[1]) assert (!({1'b0, ab} >= {1'b0, region1[8:0]} && {1'b0, ab} < region1[25:16]));
        if (wa && run[0]) assert (!({1'b0, aa} >= {1'b0, region0[8:0]} && {1'b0, aa} < region0[25:16]));
    end

    // ---------------------------------------------------------------- P3
    always @(*) if (rst_n && p_ok) begin
        if (p_run[0] && p_k0) assert (locked0 && region0[8:0] == p_b0 && region0[25:16] == p_l0);          // locked and running: constant
        if (p_run[1] && p_k1) assert (locked1 && region1[8:0] == p_b1 && region1[25:16] == p_l1);
        if (!p_run[0]) assert (!locked0 && region0[8:0] == 9'd0 && region0[25:16] == 10'd512);              // held: whole memory, unlocked
        if (!p_run[1]) assert (!locked1 && region1[8:0] == 9'd0 && region1[25:16] == 10'd512);
        if (p_run[0] && p_g0 && !p_k0) assert (locked0 && region0[8:0] == p_v0[8:0] && region0[25:16] == p_v0[18:9]);   // the first OP_REGION sets its window
        if (p_run[1] && p_g1 && !p_k1) assert (locked1 && region1[8:0] == p_v1[8:0] && region1[25:16] == p_v1[18:9]);
    end
endmodule
