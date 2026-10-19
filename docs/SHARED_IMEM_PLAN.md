# Shared 512-word instruction memory: design (host interface first)

Status: **design decided 2026-10-19 (defaults confirmed); RTL in progress: imem_shared, OP_REGION, mgmt window and top wiring are written; the chip-level bench, assembler, models and formal proofs are not.** Branch `feat/shared-imem`. Replaces the per-engine 256-word memories only
when the build defines `SHARED_IMEM`; the default build is unchanged until this is accepted.

## 1. Decisions

| Question | Decision |
|---|---|
| Memory | One IHP SG13 2-port 512x32 macro (`RM_IHPSG13_2P_512x32_c2_bm_bist`, 150.7k um2). Port B = engine 0 fetch, port A = engine 1 fetch. |
| Who chooses where a program lives | **The host**, at load time. Physical word addresses, 0..511. |
| Who sets the window an engine may fetch from | **The firmware**, at run time, with one instruction (`OP_REGION`). Word granularity. |
| Address translation in the fetch path | **None.** The program counter is the physical address. No adder in the fetch loop. |
| Protection | Hardware fetch check: the engine traps if its program counter leaves its window. Host writes are refused into any word inside a running engine's window. |
| Relocation | Done by the assembler at build time for the origin the host will load at. The hardware check is only a guard. |

Reason for the physical PC: the fetch loop (macro output -> decode -> next PC -> macro address) is already the critical path at
6.56 ns of macro clock-to-output on the slow corner. A base adder there costs time we have not measured; removing it costs nothing.

## 2. Memory and address map (host side)

**Shared instruction window** in the management address map, independent of the engine:

| Address | Access | Meaning |
|---|---|---|
| `0x0400 + 4*w`, `w` = 0..511 | W | instruction word `w` (physical). Accepted only if no running engine's window contains `w` (section 4). |
| `0x0400 + 4*w`, `w` = 0..511 | R | instruction word `w`, **only while both engines are held** (the macro's host-side port is shared with the fetch ports; reads cannot be served while an engine fetches). |

The old per-engine IMEM windows (`0x1000 + 0x400 + 4*i`, `0x2000 + 0x400 + 4*i`) go away with this design. `0x0400..0x0BFC`
does not overlap the pin window (`0x0200..0x02FF`) or the engine windows (`0x1xxx`, `0x2xxx`).

**Per-engine registers** (engine `e`, base `0x1000*(e+1)`), new:

| Offset | Access | Meaning |
|---|---|---|
| `+0x000` CTRL | R/W (as today) | bit 0 RUN. Read now also returns `pc[8]` at bit 16 (already in the RTL), `lock` at bit 17. |
| `+0x008` REGION | R | `{limit[8:0] at [24:16], base[8:0] at [8:0]}`: the window the engine currently holds. Read-only from the host. |
| `+0x200` TX_DATA, `+0x204` RX_DATA | unchanged | |

The host never writes a region. It only reads one back to check what the firmware set.

## 3. Firmware side

**New instruction `OP_REGION` (opcode 29, previously a reserved trap):**

```
 31..27  26..19 (unused)  18..9  8..0
 29      -       limit  base      (limit is 10 bits, 0..512)
```

- The engine's window is `[base, limit)`: fetches are legal only for `base <= pc < limit`.
- `base < limit <= 512`, else the engine faults (illegal operand).
- Executes in one clock like `NOP`. Base and limit are operand fields [8:0] and [18:9]; limit 512 is allowed.

**Lock.** A lock bit per engine:

- Set by the first `OP_REGION` after RUN rises.
- While set, a second `OP_REGION` faults. Program code therefore cannot widen its own window to reach the other engine.
- Cleared when RUN goes low (the engine is held).

**Default window.** After RUN rises and before any `OP_REGION`, the window is the whole memory, `[0, 512)`, so a program that never
calls `OP_REGION` still runs from address 0. A firmware that needs protection must call `OP_REGION` as its first instruction.
(Decision to confirm: the alternative is an empty default window, which makes the first instruction always fault.)

**Faults.** An out-of-window fetch and an illegal operand both set the engine's existing sticky `fault` and halt it (the path
used for reserved opcodes today). The host sees it through `CTRL` (`fault` bit) and the IRQ line.

## 4. Host write rule (the protection between engines)

A write to word `w` through `0x0400 + 4*w` is accepted only if, for each engine `e`:

```
not (RUN_e == 1 and base_e <= w < limit_e)
```

So the host can load a program into memory that the other engine is running in, as long as the window the running engine
holds does not contain it. Writes into a running window are refused and set `err` (existing rule). This check uses the window
registers, so a host load and a firmware `OP_REGION` cannot race: an engine that is not running has no window to protect.

## 5. Host workflow (the part to implement in `host/chip_host.py`)

The host owns the memory map. It plans the layout, not the chip.

1. **Plan:** the host keeps a table of images with their origin and length (`[origin, origin+len)`). Two images that will run at
   the same time must not overlap unless they are meant to share code. Overlap between images that never run together is fine.
2. **Assemble for the origin:** `asm.py` takes `origin=` (default 0) and writes every jump target as an absolute physical address.
   It checks statically that every instruction lies in `[origin, origin+len)` and that the `OP_REGION` in the image names exactly that range.
3. **Load:** with both engines held, write each word `origin + i` (`chip.write_imem(w, value)`); then read back and compare.
   Readback is only legal with both engines held (rule in section 2).
4. **Start:** write `CTRL.RUN = 1` for the engine. The image's first instruction is its `OP_REGION`, so the engine sets its own window.
5. **Verify:** read `REGION` and check it equals the image's range. A mismatch means the image was linked for another origin.
6. **Stop:** write `CTRL.RUN = 0`. The lock clears; the window stays readable until the next run.

New host API functions (names proposed):

| Function | Does |
|---|---|
| `load_imem(origin, words, verify=True)` | steps 3 and the readback |
| `region(engine)` | reads `REGION`, returns `(base, limit)` |
| `plan_images(images)` | checks overlap and origin fit before any write |
| `start(engine, image)` | steps 4-5 |

Frame v2 (`cmd2` etc.) is used for all of it, so every write and read is CRC-checked and exactly-once.

## 6. What changes where

| File | Change |
|---|---|
| `src/isa.vh` | `OP_REGION = 29`; `OP_LAST_LEGAL` moves to 29. Jump targets are 9 bits absolute: bit 11 of the operand is target bit 8 (already in the worktree). |
| `src/control_unit.v` | decode `OP_REGION`; lock flag; fault on second use or bad operand. |
| `src/imem_shared.v` | drop the base adder: `phys = pc`. Window compare `base <= pc < limit` registered beside the fetch (trap). Host write check per word (section 4). Readback port. Drop the `0x0300` region register window. |
| `src/mgmt.v` | IMEM window at `0x0400`, 512 words, physical. Write check from `imem_shared`. REGION read. |
| `src/engine_top.v`, `src/pc_reg.v` | 9-bit physical PC. |
| `host/asm.py` | `origin=`, absolute jump targets, static window check, `OP_REGION` op. |
| `host/isa_model.py`, `host/isa_diff_test.py` | window, lock, fault, `OP_REGION`; `BAD` generator no longer uses opcode 29. |
| `host/chip_host.py`, `host/proto_lib.py` | load/verify/region/start API above. |
| `tb/tb_imem_shared.v` | rewrite for physical addressing, windows, lock, host write rule, readback rule. |
| `formal/` | proofs: fetch never leaves the window while RUN; host writes never change a word in a running window; lock holds until RUN falls. |
| `docs/HOST_INTERFACE.md` | the new address map and the workflow. |

## 7. Tests that decide "done"

- Unit: `tb_imem_shared` for physical fetch, window trap, lock, readback rule, write rule (including the other engine running).
- Mutants: remove the window check, remove the lock, allow host writes into a running window, skip the readback rule. Each must fail.
- Differential: the ISA model and the RTL agree on `OP_REGION` and faults cycle by cycle.
- Host: load two programs at different origins, start both, check each `REGION` and that both run to their expected results.
- Formal: the three properties in section 6.
- Flow: a 2P-macro flow run (tt14-class) for timing on the fetch loop. This is the decision point: if the loop does not close with the physical PC, we revisit.

## 8. Open items

- Confirm the default window `[0, 512)` (section 3).
- Confirm that a readback while held is enough for verification (no readback during fetch).
- Whether `OP_REGION` should also fault when the other engine's window currently contains the new window while it runs.
  Code is read-only while running, so two windows that overlap are harmless; the proposal is to allow it.

## 9. Deviations made while building (2026-10-19)

These refine the design above; the RTL follows them.

- **Host access goes through a held engine's port.** Port B serves the host while engine 0 is held, otherwise port A while
  engine 1 is held. With both engines running there is no port, so host writes are refused. (The earlier text said
  "readback only while both held"; now a single held engine is enough for a write.)
- **A held engine's window returns to the whole memory on the clock after it is held**, and its lock clears. The window is therefore
  the full memory from the moment RUN is low. A `REGION` read of a held engine shows the full window, not the last one.
- **Out-of-window fetch and an illegal `OP_REGION` both fault** through the control unit's existing illegal path. A fetch in the
  same clock as `OP_REGION` already sees the new window.
- **The `0x0300` region register window is removed.** Nothing in the host map writes a window; the host only reads `REGION`.
- **Not built yet:** the `REGION` read (`0x1008`/`0x2008`), host readback of instruction words, the host-side `load_imem` API,
  the assembler's origin and 9-bit absolute targets, the models, the formal proofs.
- **START register (new, 2026-10-19).** The program counter resets to 0, so an image linked at a nonzero origin could not start.
  Each engine gets a START register at `ENG_BASE + 0x00C` (9 bits). It is written only while the engine is held and is the
  program counter's value at reset. The host writes `START = origin` before RUN (`host/shmem_host.py`, `ShmemHost.start`).
  RTL built (mgmt.v `start0`/`start1`, pc_reg `start` input); no chip-level test yet.
- **Host layer and model (software, 2026-10-19):** `host/shmem_host.py` (Image, plan, ShmemHost), `host/asm.py` (`words_at(origin)`,
  `REGION()`, absolute 9-bit targets; default encodings unchanged), `host/isa_model.py` (SharedImem, `Engine(..., shared=, start=)`,
  OP_REGION, the window trap, bit 8 of jump targets). Tests: `host/shmem_test.py` and the shared selftest in `isa_model.py`.

## 10. Verification status (2026-10-19)

- `tb/tb_imem_shared.v` 18/18; `host/isa_model.py` and `host/shmem_test.py` pass; the default build's unit tests and `chip_host_demo` still pass.
- **`host/shmem_chip_test.py` passes on the full chip RTL** (SimLink(shared=True)): two images at origins 0 and 300 on the two engines
  with bit-8 jump targets, START, OP_REGION windows, trap at the window limit, lock, empty/over-range window faults, lock cleared by a
  hold, host write refused into a running window / accepted outside / refused with both engines running, START write refused while running.
- Bugs this test found and fixed: `OP_REGION` had no case in the control unit (PC never advanced); a `?:` mux made the window trap X
  forever in 4-state simulation (now if/else); the host's address stayed on the held engine's port after its write (the held engine
  must keep reading its start word).
- **Flow ready, not run:** `PE=/mnt/c/Data/protocol_emulator_shmem bash librelane/flow_variant_wsl.sh <tag> shared` (8x4, macro at
  x = 509.6, L-shaped engine fences in `src/floorplan_engines_shared.json`). Open: power-stripe alignment over the 685 um macro and timing.
- **Not yet:** differential RTL-vs-model test in shared mode, `REGION` read / instruction readback, formal proofs.

## 11. Flow smoke test (2026-10-19, run sh1, to the power grid)

`PE=/mnt/c/Data/protocol_emulator_shmem TO=OpenROAD.GeneratePDN bash librelane/flow_variant_wsl.sh sh1 shared` completes: lint, synthesis,
floorplan with the 2P macro at (509.6, 13.78) FS, macro placement, tap cells, power grid. Problems it found and fixed:
- the PDK's macro `.v` has a `specify` block Yosys cannot parse: `macro/RM_IHPSG13_2P_512x32_c2_bm_bist/*.v` is a ports-only blackbox, like the 1P one;
- a program counter that resets to a register value needs an asynchronous-load flop that the library does not have: in shared mode `pc_reg`
  loads START through a synchronous reset (default build keeps its asynchronous reset to 0);
- the worktree's flow shell scripts must have LF line endings (autocrlf checkout gave CRLF).
The grid reports PSM-0069 and unconnected macro power pins, exactly as tt13b / tt14b do with the 1P macros (those runs ended with clean DRC and LVS).
Next: a full run for DRC, LVS, timing, and congestion with the 685 um macro.
