# Fetch stage experiment (branch exp/fetch-stage)

**Result: functionally complete and verified, no timing gain, not merged.** Kept for the USB low-speed path (needs 60+ MHz).

## Idea

The SRAM output (5.4 ns read at the slow corner) feeds the decode, register read and ALU in the same clock. `src/fetch_unit.v`
registers it in an instruction register, so the executing instruction comes from a flop. While instruction X executes, the
SRAM output already holds the next word Y; the address put on the SRAM is the word after Y. If Y is a branch, its condition is
resolved one clock early from the **next-state values** (D inputs) of the state it tests: loop counter (DJNZ), flags (JCC), OSR
bit and bit order (JPO), pin synchroniser (JPH / JPL). Those are exactly the values Y sees when it executes, so every instruction
keeps its clock count and **no firmware changes**. While X stalls or holds, the SRAM re-reads Y.

Priming: after reset, a memory write or run falling, the fetch stage reads word 0, then loads it and reads its successor; the core
is held until then (2 clocks). The real chip writes the program and sets RUN in separate management frames, many clocks apart.

## Verification

| Test | Result |
|---|---|
| `tb_fetch_equiv` against the original (combinational-fetch) engine | 300 random programs, 234,066 clocks, 0 mismatches |
| Differential test against the cycle-exact Python model | 600 programs, 0 mismatches, 75/75 coverage points |
| Engine mutants (7 new: each branch condition from the current instead of the next state, fetch not holding on a stall) | 35/35 caught |
| Simulation checker (fetch decision against the control unit's own branch decision) | wired into the differential test: a disagreement fails it |
| Full regression | 26/26 suites |

Two testbenches start 2 clocks later (tb_engine_top ties run high; tb_fetch_equiv started 1 clock after its last write).

## Physical result (run tt11a, compact floorplan, 20 ns)

Slow corner -0.6 ns at 20 ns (20.6 ns) against 19.8 ns without the fetch stage (tt10c). The SRAM read left the ALU path but an
equally long path appeared: instruction register -> buf_1 fanout chain (about 3.3 ns) -> ALU -> next flags -> JCC condition ->
SRAM address, where the SRAM's address hold requirement adds two hold delay cells (about 1.4 ns). Possible fixes (duplicate the
instruction register bits, a fast Z detect, move the hold fix off the path) might give 1-3 ns.
