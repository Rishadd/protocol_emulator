# Shared instruction memory: the software and verification work (what it is, what is missing, how it is done)

Written 2026-10-20. The hardware design is in `SHARED_IMEM_PLAN.md` (branch `feat/shared-imem`); this page is about everything *around* the RTL that makes
the shared memory safe to use and to trust. Decision 2026-10-20: the shared 512-word memory is the base of the chip.

## 1. What the shared memory changes, in plain words

Before: each engine has its own 256-word memory; nothing can go wrong between engines because they cannot see each other's code.
Now: one 512-word memory, **both engines fetch from it at the same time** (a two-port macro). That gives a bigger program for one engine (a standalone USB device
needs about 320 words), but it creates three new things that can go wrong, and each needs a guard and a proof:

| New risk | Guard in the hardware | What we must prove / test |
|---|---|---|
| An engine runs off the end of its program into the other engine's code | each engine gets a **window** `[base, limit)` set by the firmware's first instruction `OP_REGION`; a fetch outside it faults the engine | the engine never fetches outside its window while it runs |
| Firmware widens its own window to reach the other engine's code | a **lock**: the second `OP_REGION` after RUN rises faults; the lock clears when RUN falls | the lock holds until RUN falls |
| The host overwrites code that an engine is executing | host writes into a running engine's window are refused (`err`) | a host write never changes a word inside a running window |

"Software" here means five things: the **models** (so we know what the chip should do), the **differential test** (RTL against the model), the **formal proofs**,
the **host layer** (how a person loads and starts programs) and the **small RTL additions** the host needs to check its work (`REGION` read, instruction readback).

## 2. What exists (branch `feat/shared-imem`, 2026-10-19)

| Piece | State |
|---|---|
| `src/imem_shared.v`, `OP_REGION`, window trap, lock, host write rule, START register | built; `tb_imem_shared` 18/18 |
| `host/asm.py` (`origin=`, absolute 9-bit jump targets, `REGION()`), `host/isa_model.py` (shared memory, windows, trap), `host/shmem_host.py` (`Image`, plan, `ShmemHost`) | built; `shmem_test.py` and the model self-test pass |
| `host/shmem_chip_test.py` on the full chip RTL | passes (two images at origins 0 and 300, traps, lock, write rules) |
| Layout: sh4 (matched power grid) LVS clean, DRC 0, precheck passes | timing being tuned (see `CLOCK_SPEED_EFFECTS.md`) |

## 3. What is missing (Step 4)

| # | Item | Why it matters |
|---|---|---|
| S1 | **`REGION` read** at `ENG_BASE + 0x008` and **instruction readback** (the host reads memory words while an engine is held) | without them the host cannot check that what it loaded is what is in the memory, or what window an engine really holds. Everything else (verification of loads, debugging) depends on it |
| S2 | **Differential test in shared mode**: random programs, both engines running with different windows, the RTL and `isa_model.py` compared cycle by cycle (PC, pins, FIFO words, faults) | the existing `isa_diff_test` is single-memory; windows and faults are new behaviour that the model and the RTL might disagree on |
| S3 | **Three formal proofs** (SymbiYosys, unbounded): fetch stays in the window while RUN; a host write never changes a running window's words; the lock holds until RUN falls. Each with planted-bug mutants | tests only try some cases; the proofs cover every input. This is the protection between the two engines |
| S4 | **Host workflow**: `load_imem`, `region`, `plan_images`, `start` in `chip_host.py` (frame v2 for every access), assembler origin check, docs `HOST_INTERFACE.md` | the way a person actually uses the chip |
| S5 | **Mutants** (remove the window check, remove the lock, allow writes into a running window, skip the readback rule): each must fail some test | proves the tests can see the guards |
| S6 | **Regression integration**: shared mode as a build option in `regress.py` (the full protocol suites rerun from the shared memory, as `FW_ORG` did for the 256-word case) | all 13 protocols must behave identically from the shared memory |
| S7 | **Rebase on `main` + frame v2 + pin mapping**, then rerun everything | the branch was built before frame v2 and parts of the pin mapping |

## 4. Order and pass criteria

| Phase | Work | Done when |
|---|---|---|
| S0 | rebase `feat/shared-imem` onto the new `main` (frame v2 merged); fix conflicts in `mgmt.v`, `tt_um_protocol_emulator.v`, `chip_host.py` | the branch builds, the default build's regression is unchanged |
| S1 | `REGION` read and instruction readback in `mgmt.v` / `imem_shared.v`; unit tests | `tb_imem_shared` extended; chip test reads back every word loaded; readback refused while both engines run |
| S2 | shared-mode differential test | 600+ programs, 0 mismatches, coverage counts met (windows, faults, lock, START), mutants of the model caught |
| S3 | the three proofs, plus the existing four still pass | 7/7 proofs, planted bugs rejected |
| S4 | host API, assembler origin checks, `HOST_INTERFACE.md` | `chip_host_demo` extended; load two images, start both, read both `REGION`s |
| S5 | mutants | 100 % caught |
| S6 | regression from the shared memory | all suites pass in shared mode |
| S7 | docs and `memory.md`; flow run with the final RTL | numbers in `TEST_RESULTS.md` |

## 5. Open points (from SHARED_IMEM_PLAN.md section 8, to decide before S1)

- default window `[0, 512)` after RUN rises (keeps old firmware working) versus an empty window (forces every image to call `OP_REGION`);
- whether two overlapping windows are allowed (code is read-only while running, so harmless: proposal is to allow);
- readback only while held is enough for verification (no readback during fetch).

## 6. Effect on the schedule

About 1.5 to 2 weeks of work, mostly in S2 and S3. It must finish before the logic analyser build starts, because the analyser's firmware (sniffer) and the
standalone USB firmware are both *images placed in the shared memory*, and loading them goes through this host layer.
