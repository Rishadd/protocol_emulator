`include "isa.vh"
// Fetch stage: the SRAM output is registered in the instruction register (ir), so the instruction being executed comes from a flop
// and the SRAM read (5.4 ns at the slow corner) is no longer in front of the decode / register read / ALU.
//
// While instruction X executes from ir, the SRAM output (dout) already holds the next instruction Y, read from fetch_pc. The address
// put on the SRAM in this clock is the instruction AFTER Y. If Y is a branch its condition is evaluated here, one clock early, from
// the state X leaves behind: the next-state (D-input) values of the loop counter, the flags, the OSR output bit and the pin
// synchroniser are exactly the values Y will see when it executes. So every branch still takes one clock, taken or not, and the
// instruction timing is the same as without the fetch stage (no firmware change).
//   X completes this clock (x_done): ir <= Y, fetch_pc <= successor of Y, SRAM address = successor of Y.
//   X stalls or holds:               everything stays, the SRAM re-reads Y.
// Priming (after reset, after the host wrote the memory, after run fell): phase 0 reads word 0, phase 1 loads it into ir and reads
// its successor (with the reset state, which is what word 0 sees), phase 2 = ready. The engine core is held until ready, so word 0
// executes in the first clock after run (exactly as before) as long as run rises 2 or more clocks after the last memory write.
module fetch_unit (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        run,
    input  wire        imem_we,         // host owns the SRAM port this clock: prime again afterwards
    input  wire [31:0] dout,            // SRAM output = instruction at fetch_pc
    output wire [7:0]  addr,            // SRAM read address for the coming edge
    output reg  [31:0] ir,
    output reg  [7:0]  ir_pc,
    output wire        ready,           // primed: the engine core may run
    // execution of X
    input  wire        x_done,          // X completes at this edge (= pc advance or jump in control_unit)
    // state that Y's branch condition depends on: current value (for priming, word 0 sees the reset state) and next value
    input  wire [15:0] lc,         input wire [15:0] lc_next,
    input  wire        flag_z,     input wire        flag_z_next,
    input  wire        flag_n,     input wire        flag_n_next,
    input  wire        flag_c,     input wire        flag_c_next,
    input  wire        osr_bit,    input wire        osr_bit_next,
    input  wire [7:0]  pins,       input wire [7:0]  pins_next
);
    reg [1:0] phase;
    reg [7:0] fetch_pc;
    reg       run_q;
    assign ready = (phase == 2'd2);
    wire running = run & ready;

    // ---- branch resolution of the word on dout (Y while running, word 0 in priming phase 1)
    wire        use_next = running;
    wire [15:0] l  = use_next ? lc_next      : lc;
    wire        z  = use_next ? flag_z_next  : flag_z;
    wire        n  = use_next ? flag_n_next  : flag_n;
    wire        c  = use_next ? flag_c_next  : flag_c;
    wire        ob = use_next ? osr_bit_next : osr_bit;
    wire [7:0]  pv = use_next ? pins_next    : pins;

    wire [4:0]  op  = dout[31:27];
    reg         cc;
    always @(*) begin
        case (dout[10:8])
            `CC_Z:   cc = z;
            `CC_NZ:  cc = ~z;
            `CC_C:   cc = c;
            `CC_NC:  cc = ~c;
            `CC_N:   cc = n;
            `CC_NN:  cc = ~n;
            `CC_GTU: cc = c & ~z;
            default: cc = ~c | z;               // CC_LEU
        endcase
    end
    wire taken = (op == `OP_JMP) ||
                 (op == `OP_DJNZ && l[15:1] != 15'd0) ||           // DJNZ jumps while the counter is above 1
                 (op == `OP_JCC  && cc) ||
                 (op == `OP_JPH  &&  pv[dout[10:8]]) ||
                 (op == `OP_JPL  && !pv[dout[10:8]]) ||
                 (op == `OP_JPO  && ob);
    wire [7:0] dout_pc = running ? fetch_pc : 8'd0;              // address of the word on dout
    wire [7:0] succ    = taken ? dout[7:0] : dout_pc + 8'd1;

    assign addr = running ? (x_done ? succ : fetch_pc) :
                  (phase == 2'd1) ? succ :
                  (phase == 2'd2) ? fetch_pc : 8'd0;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            phase    <= 2'd0;
            run_q    <= 1'b0;
            fetch_pc <= 8'd0;
            ir       <= {`OP_HALT, 27'd0};
            ir_pc    <= 8'd0;
        end else begin
            run_q <= running;
            if (imem_we || (run_q && !run)) begin
                phase <= 2'd0;                     // memory written or engine stopped: prime from word 0 again
            end else if (running) begin
                if (x_done) begin
                    ir       <= dout;
                    ir_pc    <= fetch_pc;
                    fetch_pc <= succ;
                end
            end else if (phase == 2'd0) begin
                phase <= 2'd1;
            end else if (phase == 2'd1) begin
                ir       <= dout;                  // word 0
                ir_pc    <= 8'd0;
                fetch_pc <= succ;
                phase    <= 2'd2;
            end
        end
    end
endmodule
