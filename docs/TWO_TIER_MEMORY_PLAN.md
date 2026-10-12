# Two-Tier Instruction Memory (per-engine L1 + shared L2): Analysis, Implementation and Verification Plan

2026-10-12 | Status: **being built** (2026-10-13: user decision to build it as written; progress and measured
numbers in [TWO_TIER_RESULTS.md](TWO_TIER_RESULTS.md)). Phase 0 done: decisions as proposed, D7 = mode A.
Values marked *(est.)* are estimates; the phase that builds the item replaces them with measured numbers and
updates this file. Background: [ASIC_AREA_AND_MEMORY_STUDY.md](ASIC_AREA_AND_MEMORY_STUDY.md),
[SRAM_INSTR_MEM_RESULTS.md](SRAM_INSTR_MEM_RESULTS.md), [I2C_PLAN.md](I2C_PLAN.md) §6.4.1 (why the I2C slave does not
fit in 64 words), [WORKLOAD_RESULTS.md](WORKLOAD_RESULTS.md).

**Idea in one paragraph.** Each engine keeps its current 64-word SRAM instruction memory (**L1**) and stays cycle-exact
there. One large single-port SRAM (**L2**, 256 x 32) is added and shared by both engines. The host loads it over the
management link. Engines execute directly from L2 through an arbitrated port, with a prefetch buffer that hides most
fetches. A new `COPY` instruction moves code from L2 into the engine's own L1, so firmware can install time-critical
loops and switch protocols itself. **Firmware decides which code is in which tier.** The hardware only provides the
mechanism, so the engine stays protocol agnostic.

---

## Contents

1. Goal, scope and rules
2. Architecture specification (what gets built)
3. Pros and cons with numerical evidence
4. Decisions to confirm before Phase 1
5. Implementation plan (phases and steps)
6. Verification plan per phase
7. Full regression and workload campaign
8. Risks and mitigations
9. Documentation and memory updates
10. Open questions

Appendix A: area estimate details. Appendix B: file plan.

---

## 1. Goal, scope and rules

### 1.1 Goal
- Give programs more than 64 words: up to **64 (L1) + 256 (L2) = 320 words** reachable by one engine.
- Keep **today's exact timing** for all code placed in L1, and make L2 timing **bounded and predictable**.
- Let **firmware** (engine programs and the host through the management link) own placement, installation,
  protection and arbitration policy. Nothing is a fixed hardware policy.
- Keep the engine **protocol agnostic** (I2C_PLAN D1/D2 still apply).

### 1.2 Rules for every phase
| # | Rule |
|---|---|
| G1 | No protocol-specific logic in the engine, L2 or management. |
| G2 | A new instruction must be generic and have at least two uses that do not depend on one protocol. |
| G3 | Every new mechanism is configurable by the engine program or by the host. Every configuration register has a documented reset value. |
| G4 | Existing programs placed in L1 run **cycle-identically** to today after the encoding change (Phase 1). |
| G5 | Minimal, clean logic. Each phase is small enough to review in one sitting. |
| G6 | A build parameter `L2_EN` removes L2 completely. With `L2_EN=0` the chip is today's chip plus a 9-bit PC (fallback if the macro or the timing fails). |
| G7 | No phase merges with a red test. Each phase ends with the full regression of every earlier phase, and every measured limit must be identical. |

### 1.3 Out of scope
- FPGA (the FPGA tops and images are not updated and are marked stale).
- Physical flow and STA (they consume this design later; §8 lists the inputs).
- Management frame v2, more than two engines, and a hardware-managed cache.
- `CALL`/`RET` is an optional phase (Phase 8) and needs its own decision.

---

## 2. Architecture specification

### 2.1 Block diagram

```
                       management SPI link (frame v1, unchanged)
            ┌──────────────────────────┴──────────────────────────────┐
            │ L1 write (engine held)     L2 write/read (any time)    regs│
            ▼                            ▼                              │
 ┌───────────────────────┐      ┌──────────────────────────────────┐   │
 │ engine 0              │      │ l2_mem                           │   │
 │  PC[8:0]              │ req0 │  arbiter: host > urgent >        │   │
 │  ├─ pc<0x040 ─► L1 ◄──┼──────┤          prefetch / COPY         │   │
 │  │   (2 x 64x16,      │ gnt0 │  policy: RR | fixed e0 | fixed e1│   │
 │  │    today's)        │◄─────┤  8-bit address mux               │   │
 │  └─ pc>=0x100 ─► IR2  │      │  RM_IHPSG13_1P_256x32_c2_bm_bist │   │
 │     PB (+BB) buffers  │      │  (BIST tied off, BM = all ones)  │   │
 │  COPY: L2 ─► own L1   │      └──────────────────────────────────┘   │
 └───────────────────────┘                ▲ req1 / gnt1                 │
 ┌───────────────────────┐                │                             │
 │ engine 1 (same)       │────────────────┘                             │
 └───────────────────────┘                                              │
   pin_mgr, FIFOs, spi_slave, frame format, STATUS byte: unchanged ◄────┘
```

### 2.2 Memories

| | L1 (per engine) | L2 (shared) |
|---|---|---|
| Macro | 2 x `RM_IHPSG13_1P_64x16_c2` (today's `instr_mem`, unchanged) | 1 x `RM_IHPSG13_1P_256x32_c2_bm_bist` |
| Words x bits | 64 x 32 | 256 x 32 |
| Size (LEF) | 236.8 x 64.36 µm each | 416.64 x 118.78 µm |
| Area | 2 x 15,240.4 µm² | 49,488.5 µm² (datasheet) |
| Clock-to-out, typ 1.20 V 25 °C | 2.91-3.06 ns | 3.05-3.14 ns |
| Read | every clock, address = `next_pc` (today) | on demand, through the arbiter |
| Write | host while the engine is held (today) + `COPY` while it runs | host at any time, outside protected ranges |
| Timing | exact (today's rules) | bounded (§2.10) |

Macro tie-offs: `A_DLY=1` (datasheet: mandatory), `A_BIST_EN=0` and all `A_BIST_*` tied to 0, `A_BM=32'hFFFFFFFF`,
`A_MEN=1` only on a granted access (saves power). `A_REN`/`A_WEN` come from the arbiter.

### 2.3 Address map per engine (9-bit PC)

| PC range | Meaning |
|---|---|
| `0x000-0x03F` | Own L1, word `pc[5:0]` |
| `0x040-0x0FF` | Reserved (room for a larger L1 later). A fetch here **faults** (cause 1) |
| `0x100-0x1FF` | L2, word `pc[7:0]`. Absolute addressing: no window or relocation hardware. The generator/linker places code at its final address |

- The same L2 address means the same word for both engines, so **shared code needs no hardware support**.
- A fetch outside the engine's own L2 range `[L2_LO, L2_HI]` **faults** (cause 2). The range check runs in parallel with
  the read and is never on the address path.
- With `L2_EN=0`, any fetch at `pc >= 0x040` faults (cause 1).

### 2.4 Fetch rules

**Definitions**
- **Urgent fetch:** the engine commits a one-clock instruction (or ends a held one) this clock, `next_pc` is in L2,
  and no buffer holds the word for `next_pc`. Without a grant this clock, the next clock is a bubble.
- **Prefetch:** the current instruction holds (`S_HOLD` with at least one clock left) or blocks (`PULL`, `PUSH`,
  `PUSHI` on full RX FIFO, `WAITH`, `WAITL`), and `pc+1` is in L2. The engine fetches `pc+1` into the prefetch buffer **PB**.
- **Branch-ahead (optional, Phase 4b):** PB holds a branch (`JMP`, `DJNZ`, `JPH`, `JPL`, `JPO`) whose target is in L2.
  The engine fetches the target into the branch buffer **BB** during the same hold.
- **COPY read:** one L2 read per copied word (§2.8).

**Bubble semantics (D8)**
- A bubble is a clock in `S_EXEC` with `instr_valid = 0`.
- In a bubble, **nothing in the core changes**: PC, `state`, `cfg_*`, delay and loop counters, OSR and ISR, pin
  outputs and directions. All FIFO strobes are 0.
- The input synchronizers and the host side of the FIFOs keep running.
- Bubbles happen **only between instructions**, never inside a held instruction. `WAIT d` still lasts exactly d+1
  clocks once it starts.
- An invalid word is never decoded. No trap or HALT is taken on stale bits.
- RTL intent: `stall |= ~instr_valid`, and the legality, HALT and side-effect decode are gated by `instr_valid`.

**Sources of the instruction word**
- `pc` in L1: the L1 macro output, exactly as today.
- `pc` in L2: `IR2`, a per-engine 32-bit latch (the L2 output is shared, so each engine needs its own copy).
  `IR2` loads from the macro output (granted read), from PB (`pc` matches PB) or from BB (taken branch matches BB).

### 2.5 Arbiter (D6)

Each engine raises **at most one request per clock**. Urgent, prefetch, branch-ahead and COPY cannot happen in the same
clock for one engine (§2.4).

| Class (high to low) | Members | Rule inside the class |
|---|---|---|
| 1 | Host access (L2 write commit or L2 read of a management frame) | single requester |
| 2 | Urgent fetches; prefetch, branch-ahead and COPY requests that already **lost once** (promoted) | policy register `ARB_POLICY`: 0 = round-robin (default), 1 = engine 0 first, 2 = engine 1 first |
| 3 | Fresh prefetch, branch-ahead and COPY requests | same policy |

**Bounds this gives (checked in Phase 3/4, §6)**

| Policy | Urgent request waits | Prefetch / COPY request waits |
|---|---|---|
| Round-robin | ≤ 1 clock | ≤ 2 clocks |
| Fixed priority, favoured engine | 0 clocks | ≤ 1 clock |
| Fixed priority, other engine | **unbounded** (documented; starvation is the user's choice) | **unbounded** |

- Each host access adds at most one more clock, to one engine.
- Host accesses are at most one per management frame, and frames are ≥ 896 clocks apart at the fastest tested link
  (8-clock SCLK half period x 2 x 8 bits x 7 bytes).

### 2.6 Prefetch buffers

| Buffer | Holds | Filled when | Used when | Invalidated when |
|---|---|---|---|---|
| PB | `{valid, addr[8:0], word[31:0]}` | prefetch rule (§2.4) | `next_pc == PB.addr` | jump to a different address; RUN falls; fault; host write to `PB.addr`; COPY start |
| BB (opt.) | `{valid, addr[8:0], word[31:0]}` | branch-ahead rule | taken branch with `target == BB.addr` | same as PB; also once the branch is passed |

Both buffers are enabled per engine by `FETCH_CFG` (host, written only while the engine is held). The defaults are
PB on and BB on if it is built.

### 2.7 Protection and faults

**Protection**
- `L2_RANGE[e] = {hi[15:8], lo[7:0]}`. When `lo > hi` the range is empty: the engine may not touch L2 at all. That is
  the reset value, so a fresh engine can never execute stale L2.
- A host L2 write whose address lies in the range of a **running** engine is **refused**: sticky `err` is set and the
  memory is unchanged.
- `RESET_PC`, `L2_RANGE` and `FETCH_CFG` are writable **only while that engine is held** (the same rule as L1 loads).
- `COPY` reads must lie inside the executing engine's own range.

**Faults** (the engine halts, `fault = 1`; cause in CTRL `[4:3]`)

| Cause | Meaning |
|---|---|
| 0 | illegal opcode (today) |
| 1 | fetch from a reserved address, or from L2 while `L2_EN=0` |
| 2 | fetch from L2 outside own range |
| 3 | `COPY` violation (executed from L1, source outside own range or wrapping, `dst + n > 64`) |

### 2.8 ISA changes (D3, D9)

| Opcode | Today | New |
|---|---|---|
| `JMP a` (2), `DJNZ a` (5), `JPO a` (19) | `a` = operand `[5:0]` | `a` = operand `[8:0]` |
| `JPH p,a` (17), `JPL p,a` (18) | `[5:0]` addr, `[8:6]` pin | **`[8:0]` addr, `[11:9]` pin** |
| **`COPY src,dst,n` (21, new)** | — | `[7:0]` src (L2 word), `[13:8]` dst (L1 word), `[19:14]` n-1 (1..64). Copies L2[src..src+n-1] to own L1[dst..dst+n-1]. Every check is done **before** the first write, so a refused COPY writes nothing. The engine pauses; PC goes to pc+1 when done. RUN falling aborts it. Allowed only from L2 (an L1 COPY could overwrite itself). |
| `OP_LAST_LEGAL` | 20 | 21 (23 if Phase 8 adds `CALL`/`RET`) |

**Why `COPY` meets G2 (it is not protocol specific):**
1. installing hot loops for any protocol;
2. overlays (swapping code phases of one long program);
3. runtime protocol switching;
4. self-repair: re-install L1 from a protected L2 image after a host error.

### 2.9 Management changes (frame v1 and STATUS byte unchanged)

| Address | Access | Meaning | Reset |
|---|---|---|---|
| `base+0x000` CTRL | R | **new layout** `{13'd0, pc[8:0], 5'd0, cause[1:0], fault, halted, run}` | — |
| `base+0x004` RESET_PC | R/W (W only while held) | `[8:0]` first PC after RUN rises | 0 |
| `base+0x008` L2_RANGE | R/W (W only while held) | `[7:0]` lo, `[15:8]` hi | lo=0xFF, hi=0x00 (empty) |
| `base+0x00C` FETCH_CFG | R/W (W only while held) | `[0]` PB enable, `[1]` BB enable | 0b11 |
| `base+0x010` PERF_BUBBLE | R; W (any data) clears | 16-bit saturating count of bubbles | 0 |
| `base+0x014` PERF_L2RD | R; W clears | 16-bit saturating count of granted L2 reads by this engine | 0 |
| `0x0300` ARB_CFG | R/W (any time; takes effect next clock) | `[1:0]` policy | 0 (RR) |
| `0x0310` HOST_COPY (Phase 6, opt.) | W (refused while that engine runs) | `{eng[24], n-1[19:14], dst[13:8], src[7:0]}` | — |
| `0x0400 + 4i`, i = 0..255 | R/W | L2 word i. W refused inside a running engine's range. R has no side effects | contents undefined |
| `base+0x100 + 4i` | W | L1 word i (today, unchanged) | — |

Notes:
- **CTRL layout:** 13 + 9 + 5 + 2 + 3 = 32 bits as `{13'd0, pc[8:0], 5'd0, cause[1:0], fault, halted, run}`
  (fault `[2]`, cause `[4:3]`). The host decoder changes once, in Phase 1.
- **L2 read in a frame:** the address is complete after byte 2; read data must be latched before MISO starts byte 3.
  With the host at class 1 the read returns in about 2 clocks *(est.)*, inside the ~8 clocks available at the fastest
  link. This is checked in V2.6.
- Unmapped or unaligned addresses keep today's behaviour (`err`).

### 2.10 Timing contract (the future `instructions.md` §1)

**Kept from today:** T1-T6 (instructions.md §1, rules 1-6) for every instruction executed from L1.

**New:**

| # | Rule |
|---|---|
| T7 | A **bubble** (one clock with no effect) can only occur **before** an instruction fetched from L2, never inside one. |
| T8 | An L2 instruction reached from an instruction that held or blocked for ≥ `H_PF` clocks is never delayed, when PB is on. `H_PF` = 3 under round-robin *(est.; measured in Phase 4)*. With BB on, the same holds for the **taken** target of a branch that directly follows such an instruction. |
| T9 | Any other L2 fetch is delayed by at most: (urgent-wait bound from §2.5) + (1 clock per host L2 access in that window). In mode B (D7) one extra clock is always added, and that clock is constant. |
| T10 | `COPY n` takes `n + c` clocks uncontended (`c` measured in Phase 5) and is delayed per T9. |
| T11 | Code in L1 is never delayed by L2 traffic, host L2 access, `COPY` of the *other* engine or the arbitration policy. |

### 2.11 What firmware controls

| Knob | Who sets it | Mechanism |
|---|---|---|
| Placement of every instruction (L1 / L2) | generator / linker | program layout (absolute addresses) |
| What is in L1 at a given moment | engine program | `COPY`; host L1 loads while held |
| Start address (L1 or L2) | host | `RESET_PC` |
| Which L2 words an engine may execute/copy, and which the host may not overwrite while it runs | host | `L2_RANGE` |
| Shared code between engines | host / linker | overlapping ranges, same absolute addresses |
| Prefetch / branch-ahead | host | `FETCH_CFG` |
| Who wins contention | host | `ARB_CFG` |
| Observing timing cost | host / tests | `PERF_BUBBLE`, `PERF_L2RD` |

---

## 3. Pros and cons with numerical evidence

### 3.1 Where the numbers come from
| Number | Source |
|---|---|
| Today's chip 150,000 µm² (20.8 % of 720,000 µm²) | `build/synth/i2c_final.stat.txt`, CHALLENGE_CHECK |
| Per-module areas, flop cost 48.99 µm² (no enable) / ~67 µm² (with mux), mux2 18.14 µm² | ASIC_AREA_AND_MEMORY_STUDY §1-2, SRAM_INSTR_MEM_RESULTS §2 |
| Macro sizes, areas, clock-to-out | IHP macro LEF/liberty/datasheets in `C:\tools\ihp-sram` (typ corner only locally) |
| Macro halo cost 6,423 µm² per 64x16 macro at 10 µm | SRAM_INSTR_MEM_RESULTS (224,087 vs 198,394 for 4 macros) |
| Program sizes | instructions.md, I2C_PLAN §6.4.1 |
| Management frame = 896 clocks at the fastest tested link | MGMT_PLAN frame v1 (7 bytes), WORKLOAD_RESULTS (8-clock half period) |
| Protocol limits | SPI_RESULTS, I2C_RESULTS, WORKLOAD_RESULTS |

### 3.2 Area *(est., Appendix A)*

| Item | µm² |
|---|---:|
| L2 macro | 49,488.5 |
| Glue per engine: `IR2`, PB, instruction source mux, PC +3 bits, range/reset/config regs, range compare, COPY sequencer, L1 write-port mux, fault cause | ~11,800 |
| Optional per engine: BB + 2 performance counters | ~3,800 |
| Shared glue: arbiter, address mux, ARB_CFG, management decode/read mux additions | ~4,900 |
| **Total added, minimum build (no BB, no counters)** | **~78,000** |
| **Total added, full build** | **~86,000** |
| **Chip** | **~228,000-236,000 µm² = 31.7-32.8 % of 720k** (today 20.8 %) |
| Placement footprint (cells / 0.6 + macros with 10 µm halo) | ~343,000-356,000 µm² = 47.7-49.4 % (today 32.6 %) |

The glue is larger than a first guess suggests. Every flop in this library costs 49-67 µm², so
3 x 42-bit buffers + 32-bit latch per engine add up quickly.

### 3.3 Against the alternatives (same 2 engines)

| Option | Chip µm² | % of 720k | Footprint % | Exact words / engine | Max words for one engine | Shared code | Macros | Engine RTL change |
|---|---:|---:|---:|---|---:|---|---:|---|
| Today | 150,000 | 20.8 | 32.6 | 64 | 64 | no | 4 | — |
| **A.** Private 1P 256x32 per engine | ~188,300 | 26.2 | 37.5 | 256 | 256 | no | 2 | macro swap, 8-bit PC |
| **B.** Shared 2P 256x32 + partition | ~188,300 | 26.2 | 37.0 | 256 (shared) | 256 | yes | 1 (703 µm wide) | fetch path, 8-bit PC, partition |
| **C.** Shared 1P 256x32 only, arbitrated (no L1) | ~165,000-170,000 | ~23 | ~35 | 0 (all bounded) | 256 | yes | 1 | fetch path, bubbles |
| **This plan** (L1 + shared 1P L2) | 228,000-236,000 | 31.7-32.8 | 47.7-49.4 | 64 + covered L2 code | 320 | yes | 5 | fetch path, bubbles, COPY, 9-bit PC |

**What this table says, plainly:** for two engines, option A is smaller (~40-48k µm² less), uses fewer macros, gives
more exact words, and changes the least RTL. The two-tier plan is only worth it for capabilities A does not have
(§3.9, gate D0).

### 3.4 Fetch demand: how often each protocol needs an L2 read when placed in L2

| Program (verified listing) | Bit loop | Clocks/bit | Urgent fetches/bit, PB only | With BB | Share of clocks |
|---|---|---:|---:|---:|---:|
| UART TX, 434-clock bit | `OUT1 432`, `DJNZ` | 434 | 1 (DJNZ → OUT1) | 0 | 0.23 % → 0 |
| UART RX, 434-clock bit | `IN1 432`, `DJNZ` | 434 | 1 | 0 | 0.23 % → 0 |
| I2C master 400 kHz @ 50 MHz | `SETLO`, `OUT1 65`, `SETH`, `WAITH`, `IN1 53`, `DJNZ` | ~125 | 3 | 2 | 2.4 % → 1.6 % |
| SPI master H=4 | `OUT1 4`, `SETH`, `IN1 4`, `SETLO`, `DJNZ` | 13 | 3 | 3 | 23 % |
| SPI master H=1 | same, H=1 | 7 | 3 | 3 | 43 % |
| SPI slave, inside a frame | `JPH 5` / `JPL 2` polling | — | every clock | every clock | 100 % |
| I2C slave START/STOP watch (planned) | `JPL`/`JPH`/`JMP` | — | every clock | every clock | 100 % |

**Consequences**

| Program | Effect | Rule for placement |
|---|---|---|
| UART TX/RX (with BB) | Exact even from L2 under any contention (T8) | L2 is fine |
| I2C master | Each contested urgent fetch adds 1 clock to a ~125-clock bit (≤ 1.6 %); minimum timings stay met because delays only lengthen intervals | L2 is fine |
| SPI master from L2 under worst contention | Up to +3 clocks per bit: 7 → 10 clocks at H=1, i.e. SCLK rate −30 % and uneven | Keep the loop in L1 |
| SPI slave, I2C slave | Polling latency doubles; the SPI slave's measured limit (half period ≥ 4 clocks, CPHA=0) would rise | **Must stay in L1.** The linker enforces this (Phase 7) |

### 3.5 Program space

| Program | Words (verified unless noted) |
|---|---:|
| UART TX / UART RX | 12 / 9 |
| SPI master (CPHA 0/1) / SPI slave (CPHA 0/1) | 17-18 / 18-16 |
| I2C master | 46 |
| I2C slave | ~50 (restructured design) to ~64-67 (§6.4 design) *(est.)* |
| **Whole verified library + I2C slave + ~3-word installers** | **~171 *(est.)* = 67 % of L2** |

- Today one engine can hold one protocol at a time, and the I2C slave does not fit.
- With this plan the full library fits in L2 at once, with ~85 words spare.

### 3.6 Install and switch time (clocks, independent of clock frequency)

| Action | Today | Two-tier |
|---|---:|---:|
| Replace 64 words of L1 | 64 frames x 896 = **57,344 clocks** (+ RUN frames), host involved | `COPY` ≈ 64 + c ≈ **66 clocks** *(est.)*, engine alone |
| Factor | | ~870x faster, no host |
| Load the full library | not possible | 256 frames = 229,376 clocks once (4.6 ms at 50 MHz) |

### 3.7 Critical-path budget *(est., to be confirmed by STA in the physical flow)*

| Segment | L1 fetch (today) | L1 fetch (two-tier) | L2 urgent fetch, mode A |
|---|---|---|---|
| Macro clock-to-out (typ) | 2.91-3.06 ns | same | 3.05-3.14 ns |
| Decode, stall, `next_pc` | unmeasured | + `instr_valid` term | same |
| Tier select + PB/BB address compare (9-bit) | — | — | +0.5-0.8 ns |
| Arbiter (2 requesters + host + class + policy) | — | — | +0.5-1.0 ns |
| Address mux to macro | 6-bit 2:1 | 6-bit 3:1 (host, COPY, fetch) | 8-bit 4:1 (+~0.4 ns) |
| Macro address setup (typ) | ≈ -0.4…+0.06 ns | same | same |

- The slow-corner clock-to-out of the 64x16 macro is 5.05-5.3 ns (area study); the 256x32 slow corner is not
  available locally.
- Mode B (registered urgent requests) removes the arbiter and the compare from this path, at the cost of one constant
  clock per uncovered L2 fetch.

### 3.8 Pros and cons

**Pros**
1. **Program space:** up to 320 words for one engine (5x today) and 384 words in total (3x today's 128).
2. **Exact where it matters:** L1 code has 0 bubbles by construction, proven formally (F5). Even L2 code is exact after
   holds (UART 0 % urgent fetches with BB).
3. **Resident library:** all verified protocols plus the I2C slave fit at once (~171 of 256 words).
4. **Protocol switching by firmware:** about 66 clocks per 64-word install against 57,344 clocks over the link
   (~870x), with no host involvement.
5. **Shared code:** both engines run one copy (absolute addressing, overlapping ranges).
6. **Less link traffic:** load the library once (229k clocks) instead of reloading per protocol change.
7. **Power:** L2 is read only on demand (`A_MEN` gated). Today all four macros read every clock. Not quantified for the
   256x32 macro.
8. **Fallback:** `L2_EN=0` gives today's chip with a 9-bit PC. Phase 1 alone is useful (room for a larger L1).
9. **Scales:** more engines could share the same L2. Not in scope.

**Cons**
1. **Area:** +78-86k µm² (+52-57 %), chip 31.7-32.8 % of nominal. That is 40-48k more than option A.
2. **Only 64 words per engine are exact under every condition.** L2 code is bounded (T9). Under worst-case contention,
   one-clock-dense L2 code runs at half speed.
3. **5 macros** (option A: 2), including a 416.64 x 118.78 µm L2, with more halo, PDN and DRC/LVS waiver work.
4. **New stall source:** the engine can be stalled from outside for the first time. This is the riskiest RTL change
   and the largest verification effort of all options.
5. **ISA re-encoding:** every generator, hex image and test changes (JPH/JPL fields move). FPGA images go stale.
6. **New critical path** for L2 urgent fetches, adding ~1.4-2.2 ns *(est.)* on a path that has never been timed.
7. **Cross-engine effects:** `COPY` and host L2 traffic delay the other engine's L2 code (bounded, never L1 code).
8. **More management state:** 7 new registers per engine plus globals, and new error cases.
9. **Fewer total words and less exactness than option A** for the same two engines.

### 3.9 Decision gate D0

Proceed with this plan only if at least one of the following is a real requirement. Otherwise option A (private
256x32 per engine) is cheaper, simpler and fully exact.

| # | Requirement that only the two-tier plan meets |
|---|---|
| R1 | Engines must share one resident code library (cross-engine sharing, one copy) |
| R2 | Firmware must install or switch protocols itself, without the host, in about 66 clocks |
| R3 | One engine needs more than 256 words |
| R4 | A planned growth to 3 or more engines that share code |

The rest of this document assumes D0 = two-tier.

---

## 4. Decisions to confirm before Phase 1

| # | Proposal | Alternative | Why this proposal |
|---|---|---|---|
| D0 | Two-tier (this plan) | option A / B (§3.3) | Gate §3.9 |
| D1 | L1 = today's `instr_mem`, unchanged | smaller L1 in flops/latches | 64x16 is the smallest macro; a flop L1 costs more per word (166k for 64 words) |
| D2 | L2 = 1P 256x32 bm_bist, BIST off, BM all ones | 2 x 1P 256x16 (56k) | one macro, 49.5k |
| D3 | 9-bit PC, absolute L2 addressing, no window or relocation hardware | window registers | zero hardware; the linker knows final addresses |
| D4 | `0x040-0x0FF` reserved, faults | alias L1 | room for a larger L1 without a re-encoding |
| D5 | Protection by per-engine L2 range; config registers writable only while that engine is held | always writable | deterministic; same rule as L1 loads |
| D6 | Host > urgent (+ promoted) > fresh prefetch/COPY; RR / fixed policy | pure RR | bounded prefetch wait (T8) without hurting urgent fetches |
| D7 | Urgent request mode A (same clock) if the Phase 0 budget allows, else mode B (registered) | — | A is faster; B is safer for timing |
| D8 | Bubble = core-wide hold, only between instructions | — | simplest correct semantics; reuses `stall` |
| D9 | `COPY` opcode 21, checks before the first write, L2-only, aborted by RUN falling | allow COPY from L1 | prevents self-overwrite |
| D10 | PB always built; BB built only if Phase 4a shows that it removes needed bubbles (UART-class loops) | always build BB | ~2.8k µm² per engine |
| D11 | `CALL`/`RET` deferred to optional Phase 8 | include now | separate generic feature |
| D12 | `L2_EN` parameter; `L2_EN=0` = Phase 1 chip | — | fallback (G6) |
| D13 | FPGA tops and images not updated, marked stale | update | out of scope |
| D14 | `RESET_PC = 0` is cycle-identical to today; other L1 vectors also start without a bubble; L2 vectors start after ≤ 1 + arbitration clocks | — | G4 |
| D15 | ARB_CFG writable at any time (effective next clock) | only while both held | lets the host react; fully modelled in tests |

---

## 5. Implementation plan

Each phase runs on its own git branch and is tagged at exit. Exit always requires the phase's tests (§6) plus the full
regression of every earlier phase (G7). Sizes are *(est.)*.

### Phase 0: Prerequisites and decision gate (no `src/` change)
| Step | Work |
|---|---|
| 0.1 | Confirm D0-D15 with the user. Record them in this file and in `memory.md`. |
| 0.2 | Vendor `RM_IHPSG13_1P_256x32_c2_bm_bist.v` from `C:\tools\ihp-sram` into `sim/ihp_sram/`. Fetch the `SRAM_1P_behavioral_bm_bist` core from IHP-Open-PDK (it is **not** in the local copy, same situation as the 64x16 core). Record the source, commit and licence (Apache-2.0). |
| 0.3 | Write the macro characterisation testbench `tb/tb_l2_macro.v`. It pins down the model behaviour the design relies on (V0.1). |
| 0.4 | Build an area stand-in: synthesize the chip plus the L2 macro (the liberty file is already local) plus glue stand-ins in `synth/experiments/`, and replace §3.2's estimates. |
| 0.5 | Timing budget: longest topological path of the stand-in fetch/arbiter logic with Yosys (`ltp`, gate levels) plus liberty numbers → decide **D7 (mode A or B)**. |
| 0.6 | Ask Tiny Tapeout whether the `bm_bist` 256x32 macro is accepted on CMOS5L (extends the open blocker A9). |
| 0.7 | Tool check: `sby`, `eqy`, `verilator` (with coverage) on a toy design. Check that the IHP SRAM models compile in Verilator. |
| 0.8 | Formal-friendly abstract memory `formal/abs_sram.v` (parameterized depth), proven equivalent in simulation to the vendor model (V0.2). |

**Exit:** decisions confirmed, models vendored, V0.1-V0.4 PASS, area measured, D7 chosen.

### Phase 1: 9-bit PC and ISA re-encoding, L1 only (behaviour identical to today)
| Step | Work | Files |
|---|---|---|
| 1.1 | `ADDR_W = 9`; JPH/JPL pin field `[11:9]`; comments | `src/isa.vh` |
| 1.2 | PC and `next_pc` 9 bits | `src/pc_reg.v` |
| 1.3 | `jump_addr` 9 bits; JPH/JPL pin from `[11:9]`; `fault_cause` output | `src/control_unit.v` |
| 1.4 | Fetch-address check: reserved range or `pc >= 0x040` with `L2_EN=0` → fault cause 1, without committing that instruction. L1 address = `next_pc[5:0]`. `pc` and `cause` ports widened | `src/engine_top.v` |
| 1.5 | CTRL readback layout (§2.9) | `src/mgmt.v`, `src/tt_um_protocol_emulator.v` |
| 1.6 | One shared encoder/disassembler `host/isa.py` (the single source of truth). `spi_prog.py`, `i2c_prog.py`, `uart_rx_prog.py` and the UART TX image builder use it; their APIs are unchanged | `host/` |
| 1.7 | Regenerate every hex image used by simulation. Mark `src/fpga/*.hex` stale | `src/fpga/README` note |
| 1.8 | Adapt testbench widths and CTRL decoding; freeze today's engine as `tb/ref/ref_engine_v1.v` (pre-Phase-1 HEAD) for the lockstep | `tb/` |

**Exit:** V1.1-V1.8 PASS; all suites identical (counts and limits).

### Phase 2: L2 storage and host access (engines do not fetch from L2 yet)
| Step | Work | Files |
|---|---|---|
| 2.1 | `l2_mem` module: macro with tie-offs, arbiter skeleton (host requester only; engine and COPY ports defined, tied off), `L2_EN` generate | `src/l2_mem.v` (new) |
| 2.2 | Management L2 window `0x0400+4i`: write commits on a complete frame; read latches data before byte 3 | `src/mgmt.v` |
| 2.3 | Registers `RESET_PC`, `L2_RANGE`, `FETCH_CFG`, `ARB_CFG` (stored only; used from Phase 3). Held-only write rule enforced | `src/mgmt.v` |
| 2.4 | Protection: refuse host L2 writes inside a running engine's range (`err`) | `src/l2_mem.v`, `src/mgmt.v` |
| 2.5 | Top-level instance and wiring | `src/tt_um_protocol_emulator.v` |
| 2.6 | Host helpers: L2 load/readback, register access | `host/` (chip host model) |

**Exit:** V2.1-V2.8 PASS.

### Phase 3: Execution from L2 (urgent fetch only, no prefetch)
| Step | Work | Files |
|---|---|---|
| 3.1 | `instr_valid` input; `stall |= ~instr_valid`; legality, HALT and side effects gated by `instr_valid` | `src/control_unit.v` |
| 3.2 | Fetch unit: tier decode of `next_pc`; L1 path unchanged; L2 request (mode per D7); `IR2` latch with valid bit; instruction source mux; range check → fault cause 2; cancel/invalidate on RUN falling | `src/engine_top.v` (or a new `src/fetch_unit.v` if it grows) |
| 3.3 | Arbiter classes 1-2, policies RR / fixed (§2.5), grant-to-engine response path | `src/l2_mem.v` |
| 3.4 | `RESET_PC`: while held, the L1 macro reads `RESET_PC[5:0]` (so any L1 vector starts with no bubble); an L2 vector issues its first request on the first clock after RUN | `src/engine_top.v`, `src/pc_reg.v` |
| 3.5 | Fault cause readback; `PERF_*` hooks (counters may come in Phase 6) | `src/mgmt.v` |

**Exit:** V3.1-V3.12 PASS.

### Phase 4: Prefetch buffer (4a) and branch-ahead (4b)
| Step | Work |
|---|---|
| 4a.1 | PB fill rule (§2.4) using held/blocked state from `control_unit` (new status output `can_prefetch`) |
| 4a.2 | PB use on `next_pc == PB.addr`; class 3 requests with promotion to class 2 after one loss |
| 4a.3 | Invalidation rules (§2.6) |
| 4a.4 | `FETCH_CFG[0]` gate |
| 4a.5 | Measure `H_PF` and fill in T8 |
| 4b.1 | Only if D10 says so: BB fill (target decode from the PB word; branch opcodes only), use on a taken branch, invalidation, `FETCH_CFG[1]` |

**Exit:** V4.1-V4.9 PASS.

### Phase 5: `COPY`
| Step | Work |
|---|---|
| 5.1 | Opcode 21 in `isa.vh`; `OP_LAST_LEGAL = 21`; `host/isa.py` encoding |
| 5.2 | `control_unit`: decode, pre-checks (fault cause 3), new pause state `S_COPY` (or `S_HOLD` with a copy-done condition) |
| 5.3 | Copy sequencer in `engine_top`: L2 read requests (class 3 with promotion), L1 writes through the existing `instr_mem` write port. The port mux gains a COPY source (host writes need held, COPY needs running: exclusive by construction) |
| 5.4 | PB may prefetch `pc+1` during the copy |
| 5.5 | Measure `c` in T10 |

**Exit:** V5.1-V5.10 PASS.

### Phase 6: Management extras
| Step | Work |
|---|---|
| 6.1 | `PERF_BUBBLE`, `PERF_L2RD` (16-bit saturating, write clears) |
| 6.2 | Optional `HOST_COPY` for a held engine (reuses the COPY sequencer, which therefore sits outside the core reset) |
| 6.3 | Register map in MGMT_PLAN |

**Exit:** V6.1-V6.4 PASS.

### Phase 7: Toolchain and firmware library
| Step | Work |
|---|---|
| 7.1 | `host/link.py`: sections `.l1`, `.l2`, `.l2shared`; symbols; absolute placement; overflow errors; per-engine range output; `hot` annotation forces L1 |
| 7.2 | `host/fetchcheck.py`, the **static exactness checker**. For every L2 instruction it classifies the incoming edges (prefetch-covered, BB-covered, urgent) and reports the worst-case added clocks per loop iteration. It **refuses** a `hot` loop in L2 unless all its fetches are covered |
| 7.3 | Pin-map parameters for `spi_prog`, `i2c_prog`, UART generators (needed for same-protocol pairs, §7.4) |
| 7.4 | Library image builder: all protocols + installers (`COPY` + `JMP`) + host symbol table |
| 7.5 | I2C slave firmware (L1 hot loops, L2 event handlers). Its protocol verification follows I2C_PLAN Phases 4-5 |
| 7.6 | Protocol-switch demo: an engine dispatches on a host command word (`JPO`) and installs another protocol |

**Exit:** V7.1-V7.7 PASS.

### Phase 8 (optional, separate decision D11): `CALL a` / `RET`
One-level link register (9 bits), opcodes 22/23, reset on RUN, nesting not supported (a second `CALL` overwrites the
link). Allowed across tiers. **Exit:** V8.1-V8.5 PASS.

### Phase 9: Measure and document
| Step | Work |
|---|---|
| 9.1 | Synthesize the final chip; replace every *(est.)* in this file |
| 9.2 | Gate-level simulation subset (V9.1) |
| 9.3 | Re-run all formal properties on the final RTL |
| 9.4 | Docs (§9) |

---

## 6. Verification plan per phase

### 6.0 Method

**What "works exactly as intended 100 % of the time" can mean, and how each layer earns it**

| Layer | Guarantee | Used for |
|---|---|---|
| 1. Formal proof (SymbiYosys; k-induction where it converges, else bounded depth stated in the report) | for **all** inputs | invariants F1-F12 (§6.1) |
| 2. Formal equivalence (eqy) | structural, all inputs | the L1 path is unchanged (E1) |
| 3. Exhaustive simulation | every case of a finite space | arbiter request x class x policy x host; COPY n x dst; opcode x `instr_valid`; register fields |
| 4. Constrained-random lockstep against independent references, until coverage closure | high confidence, measured | full engine behaviour with bubbles |
| 5. Protocol-level independent decoders over the workload campaign | end-to-end behaviour | §7 |
| 6. Mutation testing (100 % of planted bugs must be caught) | measures how strong layers 1-5 are | every phase |

Simulation alone cannot prove "100 %". The plan claims it only for what layers 1-3 cover, and states the measured
coverage for layers 4-5.

**Outside every layer** (needs the physical flow or silicon):
- STA at all corners;
- the macro's real behaviour beyond its functional model;
- CMOS5L acceptance of the macro;
- pad and analog effects.

**Oracle rule.** No check may use DUT logic as its own reference. Today `tb/ref/ref_engine.v` shares
`src/control_unit.v`. From Phase 3 on, the reference engine uses a **frozen copy** of the Phase 1 `control_unit`
(`ref_control_unit`), so a bug in the new stall logic cannot hide in both.

### 6.1 Infrastructure (built in Phases 0-1, extended later)

| ID | Item | Purpose |
|---|---|---|
| I1 | `tb/ref/ref_engine_v1.v` | today's engine, frozen before Phase 1 (6-bit encoding) |
| I2 | `tb/ref/ref_flat_engine.v` | ideal engine: flat 512-word combinational memory (9-bit PC), frozen `ref_control_unit`, a **core clock enable** `ce` (a bubble = `ce` low on PC, state, counters, shifters, pin output regs, cfg regs; synchronizers and FIFO host ports keep running), independent `COPY` and fault semantics. Oracle for Phases 3-5 |
| I3 | Commit trace | per engine, per commit: `{clock, pc, instr, pin_out, pin_oe, fifo ops, fault}`. Python diff against the reference trace |
| I4 | `host/arb_model.py` + Verilog shadow arbiter in the tb | reference arbiter built from §2.5. Predicts the grant every clock from the logged requests. Any mismatch is a FAIL |
| I5 | Bubble accountant | every bubble must have a cause the model agrees with: lost to the other engine's request (class/policy), host access, mode-B constant, first fetch of an L2 reset vector. **An unexplained bubble is a FAIL.** Any bubble while `pc` is in L1 is a FAIL |
| I6 | Coverage collector | testbench counters per bin → log → Python merge across runs. Closure = every bin hit at least `N_min` times (default 10). Plus Verilator line/toggle coverage of `src/` (target 100 % of reachable lines; each exclusion justified in the results file) |
| I7 | `formal/*.sby` | properties F1-F12 on small parameters (L1 8 words, L2 16 words, abstract memory I-0.8) |
| I8 | `host/mutate.py` | applies listed RTL/firmware mutations one at a time, runs the designated suite, expects FAIL. Generalizes the existing `spi_test.py`/`i2c_test.py` mutant phases |
| I9 | `host/fetchcheck.py` (Phase 7, prototype in Phase 4) | static prediction of bubbles; used as an oracle for "must be 0" regions |
| I10 | Random program generator | constrained legal programs with tier placement, jump targets inside placed code, mixed opcodes and delays. Emits both encodings for I1/DUT and I2/DUT |

**Formal properties** (proven on the abstract memory)

| ID | Property |
|---|---|
| F1 | A bubble happens only in `S_EXEC` at an instruction boundary, never in `S_HOLD` |
| F2 | During a bubble every side-effect strobe is 0 and PC/state/counters/shifters/pins are unchanged |
| F3 | Every instruction commits exactly once; no commit uses a word whose fetch address ≠ `pc` |
| F4 | At most one L2 grant per clock; a grant goes only to a requester; class order holds |
| F5 | While `pc` is in L1, `instr_valid` = 1, except during the engine's own `COPY` |
| F6 | A host write never lands inside a running engine's range; no out-of-range L2 fetch commits |
| F7 | `COPY` writes exactly n words to `dst..dst+n-1` with the L2 contents read; nothing else commits during it; a refused COPY writes nothing |
| F8 | PB and BB never supply a word whose address ≠ the address being executed (coherence) |
| F9 | After RUN falls: no new request from that engine, PB/BB/IR2 invalid, any grant in flight is discarded |
| F10 | Round-robin: urgent wait ≤ 1, promoted wait ≤ 2 (+1 per host access) |
| F11 | Host access always granted in its clock |
| F12 | `L2_EN=0` build: no L2 port activity and fault on any `pc ≥ 0x040` |

**Equivalence**

| ID | Proof |
|---|---|
| E1 | (eqy) Phase-N engine with `L2_RANGE` empty and the L2 interface tied ≡ Phase 1 engine, for every N ≥ 3 |
| E2 | (eqy) `L2_EN=0` chip ≡ Phase 1 chip |

### Phase 0 tests

| ID | Test | Method | Pass |
|---|---|---|---|
| V0.1 | 256x32 macro model behaviour: read latency 1 clock; every address with all-0, all-1, checkerboard, inverse, walking-1 per bit, address-in-data, 3 random seeds; output with `A_REN=0`; write-through; `A_BM` all ones; BIST pins toggled randomly with `A_BIST_EN=0` (no effect); `A_MEN=0` no-op; uninitialized read = X | directed sim | every observation matches the datasheet table; output-hold behaviour recorded for the design |
| V0.2 | Abstract memory ≡ vendor model | 10^6 random ops, same stimulus to both, outputs compared every clock | 0 mismatches |
| V0.3 | Area stand-in | synthesis | numbers recorded in §3.2 |
| V0.4 | Gate-depth budget for the urgent path | Yosys `ltp` | D7 decided and recorded |
| V0.5 | Tool smoke | sby, eqy, Verilator coverage on a toy design + SRAM model compile | all run |

### Phase 1 tests

| ID | Test | Method | Pass |
|---|---|---|---|
| V1.1 | JPH/JPL exhaustive: 8 pins x 2 levels x {taken, not taken} x addresses {0, 1, 0x03F, 0x040, 0x0FF, 0x100, 0x1FF}; other pins at the opposite level | `tb_control_unit` | jumps exact in 1 clock; addresses ≥ 0x040 fault cause 1 |
| V1.2 | JMP/DJNZ/JPO to every legal L1 address and to reserved/L2 addresses; sequential run past 0x03F | `tb_control_unit`, `tb_engine_ops` | correct target; fault cause 1 at 0x040; the faulting instruction does not commit |
| V1.3 | **Lockstep vs I1**: same abstract random programs encoded for each; random RUN drops; host rewrites while held; random pins and FIFO traffic | new `tb_fetch_equiv_v2` | ≥ 20 seeds, ≥ 10^6 clocks in total, **0 mismatches** on every output every clock (pc compared on `[5:0]`) |
| V1.4 | Old `tb_fetch_equiv` (vs 42d262a) with regenerated encodings | existing tb | 0 mismatches |
| V1.5 | Encoder round trip: every opcode x operand corner (0, max, each bit alone) → encode → disassemble → encode | Python | identical |
| V1.6 | Every generator's programs: old encoding vs new encoding decode to the same abstract program | Python | identical |
| V1.7 | CTRL readback layout, fault cause after each fault type | `tb_mgmt_read` (updated) | exact fields |
| V1.8 | Full regression with regenerated firmware (§7.2 list) | all runners | counts identical; **every measured limit identical** to `results/spi_2026-10-11`, I2C_RESULTS, `results/workload_2026-10-12` |

**Coverage:** every opcode at every address class (L1 / reserved / L2), every jump type taken and not taken.
**Mutants (all must fail V1.x):**
- JPH/JPL pin still read from `[8:6]`;
- `jump_addr` truncated to 6 bits;
- reserved-range check off;
- fault cause swapped;
- faulting instruction commits;
- CTRL fields shifted.

### Phase 2 tests

| ID | Test | Method | Pass |
|---|---|---|---|
| V2.1 | Load all 256 words over SPI, read all back, with V0.1 patterns | `tb_l2_host` (chip, management link only) | 0 mismatches |
| V2.2 | Aborted frames on the L2 window, truncated after each byte 1-6, writes and reads | chip tb | memory unchanged; no side effect; `err` per MGMT_PLAN rules |
| V2.3 | Unmapped (`0x0800`), unaligned, out-of-window addresses | chip tb | `err`, no access |
| V2.4 | Protection: running engine with range `[lo, hi]`; host writes at lo-1, lo, mid, hi, hi+1; empty range; overlapping ranges of both engines; held engine (accepted) | chip tb, exhaustive over these points x {eng0 running, eng1 running, both, none} | refused exactly inside running ranges; `err` set; readback proves no change |
| V2.5 | Held-only rule: `RESET_PC`, `L2_RANGE`, `FETCH_CFG` written while running (refused) and while held (accepted); `ARB_CFG` any time | chip tb | as spec |
| V2.6 | L2 read latency inside the frame: SCLK half period swept from the fastest supported link downwards | chip tb + sweep | correct data at every tested speed; limit recorded |
| V2.7 | Engines running L1 programs (UART TX + RX duplex) during heavy host L2 traffic | `tb_mgmt_duplex` variant | engine traces cycle-identical to the run without L2 traffic (T11) |
| V2.8 | `L2_EN=0` build | Phase 1 regression + E2 | identical |

**Formal:** F6 (write part), F11, F12; management commit-only-on-complete-frame for the L2 window.
**Mutants:**
- range compare `<` vs `<=`;
- write commits on an incomplete frame;
- read data latched one clock late;
- one `A_BM` bit stuck at 0;
- protection off;
- `ARB_CFG` written to the wrong field.

### Phase 3 tests

| ID | Test | Method | Pass |
|---|---|---|---|
| V3.1 | `instr_valid = 0` with every opcode (incl. illegal, HALT, blocking, timed) in `S_EXEC`; `instr_valid` toggling during `S_HOLD` | `tb_control_unit`, exhaustive over opcode x valid x state | no strobe, no PC change, no trap, no HALT; hold unaffected |
| V3.2 | **Lockstep modulo bubbles vs I2**: DUT engine with programs fully in L2 and mixed (random jumps across tiers). The other engine runs random L2-heavy programs; random host L2 traffic outside ranges; random policy changes; random RUN toggles | new `tb_l2_exec` | ≥ 50 seeds, ≥ 5 x 10^6 clocks, **0 trace mismatches** |
| V3.3 | Bubble accounting (I5) on every V3.x run | accountant | 0 unexplained bubbles; 0 bubbles in L1 |
| V3.4 | Arbiter conformance (I4): every combination of {none, urgent} x {none, urgent} x host {0, 1} x policy {RR, F0, F1} x RR pointer {0, 1} | unit `tb_arb` exhaustive + in-system logs | 0 mismatches; all 48 combinations covered |
| V3.5 | Bounds: max urgent wait over all runs | from logs | RR ≤ 1 (+ host); favoured engine 0 waits |
| V3.6 | Starvation (documented behaviour): fixed priority, favoured engine in a 3-instruction L2 polling loop for 10^5 clocks | directed | other engine makes 0 progress; resumes on the first free clock; no deadlock, no fault |
| V3.7 | **T11:** engine 0 runs UART TX, SPI master or I2C master in L1; engine 1 runs the adversary (L2 thrash) + host L2 storm + policy churn | chip tb | engine 0 commit trace **cycle-identical** to the Phase 1 golden trace; `PERF_BUBBLE` = 0 |
| V3.8 | Range faults: leave the range by sequential run, JMP, DJNZ, JPH/JPL/JPO, at lo-1 and hi+1 | directed | fault cause 2; the faulting instruction does not commit; the other engine is unaffected |
| V3.9 | Reset vector: L1 vectors 0, 1, 0x3F (vector 0 cycle-identical to today; others no bubble); L2 vectors lo, hi; RUN toggled at every clock offset relative to a pending request (exhaustive over 0-4 offsets) | directed | correct first instruction; no stale grant used |
| V3.10 | Mode check: uncontended jump into L2 | directed | mode A: 0 bubbles; mode B: exactly 1 |
| V3.11 | E1 equivalence | eqy | proven |
| V3.12 | Full regression | §7 Tier 1 | green |

**Formal:** F1-F6, F9-F11.
**Coverage bins:**
- bubble cause x engine x policy;
- tier transition types (L1→L2, L2→L1, L2→L2 jump, sequential);
- fault causes;
- request collisions on every clock offset relative to host frames.

**Mutants:**
- bubble does not gate `pin_wr`, `dir_wr`, `osr_shift`, `isr_shift`, `lc_dec`, `dc_load` or the FIFO strobes (one mutant each);
- legality checked on an invalid word;
- both engines granted;
- RR pointer never updated;
- `IR2` latched one clock late;
- RUN falling does not cancel the request;
- host not at top priority;
- range check off by one.

### Phase 4 tests

| ID | Test | Method | Pass |
|---|---|---|---|
| V4.1 | For each held/blocking predecessor (`WAIT d`, `OUT1 d`, `IN1 d` for d = 0..6 and large; blocked `PULL`, `PUSH`, `PUSHI`, `WAITH`, `WAITL` for blocking lengths 0..6 and large) followed by each opcode class in L2, under the maximal adversary | directed matrix | 0 bubbles when hold ≥ `H_PF`; below that, bubbles exactly as the arbiter model predicts; `H_PF` recorded |
| V4.2 | BB: every branch opcode (JMP; DJNZ taken / not; JPH, JPL taken / not; JPO 1 / 0) after a long hold, under the adversary | directed | taken path 0 bubbles; not-taken per model |
| V4.3 | Invalidation: jump elsewhere with PB valid; RUN falling; fault; host write to the PB address (range permitting); COPY start | directed + lockstep | never stale execution (trace 0 mismatches) |
| V4.4 | `FETCH_CFG` x V3.2 lockstep (off, PB, PB+BB) | lockstep | 0 mismatches in all three; per program, bubbles(off) ≥ bubbles(PB) ≥ bubbles(PB+BB) |
| V4.5 | **Key property:** UART TX/RX, I2C master and SPI master placed fully in L2 with PB+BB under the adversary | chip tb | covered programs (I9) are **cycle-identical** to their L1 placement; uncovered ones have bubble count ≤ I9's bound |
| V4.6 | Promotion: prefetch request against an engine that issues urgent requests every clock | directed | prefetch wait ≤ 2 (RR) |
| V4.7 | PB fill while the engine's own instruction is blocked indefinitely | directed | at most one prefetch; no repeated requests |
| V4.8 | Regression: V3.x suite with PB/BB on | rerun | green |
| V4.9 | Full regression | Tier 1 | green |

**Formal:** F8, F10 (promoted part).
**Mutants:**
- PB address compare ignores bit 0 or bit 8;
- PB not invalidated on jump;
- BB used on a not-taken branch;
- prefetch at class 2 from the start;
- no promotion;
- PB filled from the other engine's grant.

### Phase 5 tests

| ID | Test | Method | Pass |
|---|---|---|---|
| V5.1 | All n = 1..64 x all dst with dst+n ≤ 64 (2,080 cases); src at both range edges; src = every L2 address for n = 1 (256 cases); random data | directed + exhaustive | L1 contents (peek and execution) exactly as specified |
| V5.2 | Every trap: COPY in L1; dst+n = 65; src < lo; src+n-1 > hi; src+n-1 > 255 | directed | fault cause 3; **zero writes** (peek) |
| V5.3 | Uncontended duration for every n | measured | `n + c` exactly, `c` constant |
| V5.4 | COPY while the other engine runs L1 code (no effect, cycle-identical) and L2 code (bounded per model) | chip tb | as spec |
| V5.5 | RUN falling at every clock offset of an n=8 COPY (exhaustive) | directed | abort; words not yet written are unchanged; clean restart; host L1 load works afterwards |
| V5.6 | Install-and-run: L2 library → `COPY` UART TX into L1 → `JMP` | chip tb | waveform cycle-identical to a host-loaded L1 UART TX |
| V5.7 | Runtime switch UART TX → SPI master → back, on host command words | chip tb + decoders | bytes before and after correct; pad states during the switch as documented; pin-manager violations 0 |
| V5.8 | Lockstep: I2 with independent COPY semantics, random COPYs in random programs | `tb_l2_exec` | 0 mismatches |
| V5.9 | Host L1 write attempts during COPY (engine running → refused today; still refused) | directed | refused, `err` |
| V5.10 | Full regression | Tier 1 | green |

**Formal:** F7.
**Mutants:**
- length off by one;
- dst not incremented;
- src from the other engine's range;
- COPY allowed from L1;
- PC advances before the copy is done;
- checks done after the first write;
- RUN abort ignored.

### Phase 6 tests

| ID | Test | Pass |
|---|---|---|
| V6.1 | `PERF_BUBBLE` and `PERF_L2RD` equal the testbench's own counts in every V3-V5 run | exact |
| V6.2 | Saturation at 0xFFFF; clear on write; clear during counting | exact |
| V6.3 | `HOST_COPY` (if built): V5.1 matrix through the management link on a held engine; refused while running | as V5.1 |
| V6.4 | Full regression | green |

### Phase 7 tests

| ID | Test | Pass |
|---|---|---|
| V7.1 | Linker unit tests: relocation, symbol errors, section overflow, range output, `hot` placement | all Python tests pass |
| V7.2 | Static checker (I9) vs measurement: for every program in V4.5 and the workloads, prediction ≥ measured bubbles under the adversary and = measured when uncontended | 100 % of programs |
| V7.3 | Checker refuses a `hot` loop with an uncovered fetch (constructed cases) | refused |
| V7.4 | Pin-mapped generators: SPI on alternative pads, I2C on 4/5, UART on other pads; subsets of `spi_test`, `i2c_test`, UART suites | same counts as default pins |
| V7.5 | Library image: each protocol installed from L2 runs its full suite (`spi_test` master/slave, `i2c_test` master, UART suites) | same counts and limits as host-loaded L1 |
| V7.6 | I2C slave: I2C_PLAN Phase 4/5 matrix (address ACK/NACK, write, read, repeated START, STOP at every byte position, stretching, bus error + RUN recovery, 3 speeds, 1 KB stress) | as I2C_PLAN pass criteria |
| V7.7 | Protocol-switch demo | decoders pass across switches |

### Phase 8 tests (only if built)

| ID | Test | Pass |
|---|---|---|
| V8.1 | CALL/RET unit: link value, RET target, both tiers | exact |
| V8.2 | Nested CALL overwrites the link (documented); RET without CALL returns to the reset value | as documented |
| V8.3 | Link register reset on RUN | exact |
| V8.4 | Lockstep with I2 extended | 0 mismatches |
| V8.5 | Full regression | green |

### Phase 9 tests

| ID | Test | Pass |
|---|---|---|
| V9.1 | Gate-level subset on the Yosys CMOS5L netlist with cell and SRAM functional models (Icarus, else Verilator): Tier 0 + V3.2 (2 seeds, 10^5 clocks) + V5.1 subset + one workload per protocol | identical results to RTL |
| V9.2 | All formal properties F1-F12, E1, E2 on the final RTL | proven |
| V9.3 | Final Tier 3 campaign (§7) | green, coverage closed |

---

## 7. Full regression and workload campaign

### 7.1 Tiers

| Tier | When | Content | Time *(est.)* |
|---|---|---|---|
| 0 smoke | every edit | `run_tests.ps1` unit tbs + one short case per protocol + V3.2 one seed 10^4 clocks | < 5 min |
| 1 commit | every phase exit, every merge | everything in §7.2 + all phase suites V1-V(current) + formal F* + E* + mutants of the current phase | 1-2 h |
| 2 campaign | weekly, and at Phases 4, 5, 7, 9 | Tier 1 + pairwise combinatorial campaign (§7.7) + host model-based test (§7.6) + adversarial set (§7.8) | 4-8 h |
| 3 full | Phase 9 and before tape-out | Tier 2 + exhaustive pair x placement (§7.7) + 24 h random soak (§7.9) + gate-level subset + all mutants of all phases | 24-36 h |

A runner `host/regress.py --tier N [--jobs J] [--seed S]` (to be built in Phase 1) runs independent simulations in
parallel. It writes `results/two_tier_<date>/<tier>/` with one log per case and a summary line `RESULT <case> :
PASS|FAIL|EXPECTED-FAIL|DETECTED`, plus merged coverage. A failing case prints its seed and command so it can be
reproduced exactly.

### 7.2 Existing suites carried forward (must stay green at every tier ≥ 1)

| Suite | Today | Kept as |
|---|---|---|
| `run_tests.ps1` | 19/19 | all unit and chip tbs, extended with the new tbs |
| `tb_fetch_equiv` (vs 42d262a) | 0 mismatches | + `tb_fetch_equiv_v2` (vs I1) |
| `python host/spi_test.py` | 312/312, limits in SPI_RESULTS | identical counts and limits (L1 placement); + L2/installed placement variants |
| `python host/i2c_test.py` | 60/60, limits in I2C_RESULTS | same |
| `python host/mgmt_duplex_stress.py` | 8 cases incl. negative | same |
| `python host/workload.py` | UART 13/13, SPI+I2C+combo 42/42 | same; + two-tier sections |

### 7.3 Protocol programs used in the campaign

| Code | Program | Speeds (slow / nominal / max) | Default pads |
|---|---|---|---|
| UTX | UART TX | 9600 / 115200 / 1.5 Mbaud (33-clock bit) equivalents | P0 |
| URX | UART RX | same | P1 |
| SPIM | SPI master, modes 0-3, 8/16/32 bits, MSB/LSB | H=4 / H=1 / H=0 | 2-5 |
| SPIS | SPI slave, modes 0-3 | half 10 / 6 / 4-5 clocks | 2-5 |
| I2CM | I2C master | 100 / 400 / 1000 kHz | 6-7 (OD) |
| I2CS | I2C slave (after Phase 7) | 100 / 400 / 1000 kHz | 6-7 or 4-5 (OD) |
| ADV | adversary: random one-clock-dense L2 code, maximizes requests | — | none |
| IDLE | held engine, or halted program | — | none |
| SWITCH | installer cycling UTX → SPIM → I2CM on command words | nominal | union |

### 7.4 Protocol pairs (engine 0 x engine 1)

All 6 x 6 = 36 ordered pairs of {UTX, URX, SPIM, SPIS, I2CM, I2CS} run in both engine assignments, plus each protocol
with ADV, IDLE and SWITCH on the other engine (6 x 3 x 2 = 36). **72 pair configurations in total.**

**Pad maps and peers**

| Pair | Pads | Peer |
|---|---|---|
| UTX + URX | P0 / P1 | echo peer or replay (existing) |
| UTX + URX loopback | P0 → P1 wired in tb | none (internal) |
| SPIM + SPIS | **loopback on pads 2-5**: master owns SCLK/MOSI/CS, slave owns MISO | none (internal) |
| SPIM + SPIM, SPIS + SPIS | 2-5 and {0, 1, 6, 7} via pin maps | two SPI peers |
| I2CM + I2CS | master 6/7, slave 4/5; tb ties 4↔6 and 5↔7 into one wired-AND bus | optional third-party slave model on the same bus |
| I2CM + I2CM, I2CS + I2CS | 6/7 and 4/5, two buses | slave or master models |
| any + UART | UART moved to the free pads by pin map when 0/1 are taken | UART peer |

- Pairs that cannot fit in 8 pads (e.g. SPIM + SPIM + a UART) are excluded by constraint and listed in the report.
- Pin maps come from Phase 7 (step 7.3). Before Phase 7, only pairs with the default pads run.

### 7.5 Placement permutations (per engine)

| Code | Placement |
|---|---|
| L1 | whole program in L1, host-loaded (today's model) |
| HOT | hot loops installed into L1 by `COPY` from the L2 library; cold code (init, events) runs from L2 |
| L2 | whole program in L2, PB+BB on |
| L2W | whole program in L2, PB/BB off (worst case) |

Expected results per placement:
- **L1 and HOT:** protocol timing **cycle-identical** to today's L1 traces.
- **L2:** cycle-identical where I9 says covered; otherwise within I9's bound.
- **L2W:** within I9's bound. For SPIS and I2CS slaves, the recorded limits may differ. Those runs are informational
  and must be reported, not hidden.

### 7.6 Host interaction: model-based test (all combinations)

**Operations** (the host model can issue any of them at any time)

| # | Operation | # | Operation |
|---|---|---|---|
| H1 | L1 write (eng e) | H12 | VIOL clear |
| H2 | L2 write (address in / out of each range) | H13 | TX push |
| H3 | L2 read | H14 | RX pop |
| H4 | RUN set | H15 | CTRL read |
| H5 | RUN clear | H16 | PERF read |
| H6 | RESET_PC write | H17 | PERF clear |
| H7 | L2_RANGE write | H18 | HOST_COPY (if built) |
| H8 | FETCH_CFG write | H19 | aborted frame (target x truncation 1-6) |
| H9 | ARB_CFG write | H20 | unmapped address |
| H10 | pad claim (owner, od) | H21 | unaligned address |
| H11 | pad claim on a running owner's pad | H22 | STATUS-only frame |

**Method**
- `host/hostmodel.py` holds a reference model of all management-visible state:
  - per engine: held/running, L1 image, ranges, RESET_PC, FETCH_CFG, FIFO occupancy bounds, fault;
  - global: L2 image, ARB_CFG, pad owners and od, `err`, viol.
- The model generates random walks of operations and predicts, for each frame: accepted or refused, STATUS bits,
  `err`, and read data.
- The chip testbench executes the frames. Python compares every frame's prediction with the observed result.
- Both engines run real programs (random pair and placement from §7.4/7.5) during the walk, so management traffic and
  execution interleave.

**Coverage closure**
- Every ordered pair (H_i, H_j) in each of the 4 engine-state combinations (held/held, held/run, run/held, run/run):
  22 x 22 x 4 = **1,936 bins**.
- Every operation at every clock offset 0-4 relative to an engine's L2 request (cycle-directed sub-runs).
- Run walks until every bin is hit ≥ 10 times. Expected ~10^5 frames *(est.)*, split across seeds.

**Pass:** 0 prediction mismatches, 0 protocol decoder failures, and the protection invariants (F6) observed on every
frame.

**Existing host behaviours** from `tb/host_knobs.vh` stay (interleaved, burst, aborts/5, noise/3, slow, all). New
behaviours:

| Behaviour | What the host does |
|---|---|
| l2noise | L2 reads every 3rd frame |
| l2write | writes to free L2 regions while running |
| l2refused | writes into protected ranges; must be refused, data unaffected |
| cfgchurn | ARB_CFG changes while running; held-only registers attempted while running (refused) |
| runtoggle | stop/restart one engine mid-traffic |
| reload | reload the L1 of a held engine while the other runs |

### 7.7 Combinatorial design

**Factors**

| # | Factor | Levels |
|---|---|---|
| F1 | engine 0 program | UTX, URX, SPIM, SPIS, I2CM, I2CS, ADV, IDLE, SWITCH (9) |
| F2 | engine 1 program | same (9) |
| F3 | engine 0 placement | L1, HOT, L2, L2W (4) |
| F4 | engine 1 placement | same (4) |
| F5 | arbitration | RR, F0, F1 (3) |
| F6 | FETCH_CFG | off, PB, PB+BB (3) (overrides L2/L2W where applicable) |
| F7 | host behaviour | 6 existing + 6 new (12) |
| F8 | speed | slow, nominal, max (3) |
| F9 | protocol sub-mode | e.g. SPI mode 0-3 x bits x order; I2C read/write mix (per protocol) |
| F10 | seed | random |

**Campaigns**

| Campaign | Size | Tier |
|---|---|---|
| **Pairwise** (all-pairs covering array over F1-F9, generated by a greedy IPOG tool in `host/regress.py`, with constraints for pads and invalid combinations) | lower bound 12 x 9 = 108 runs; expected ~130-160 | 2 |
| **3-wise** over F1, F2, F3 x F4 (merged, 16 levels), F5 | ~1,300 runs *(est.)* | 3 |
| **Exhaustive** pair x placement for the contention-relevant core: F1 x F2 (81) x placement pairs {L1/L1, L2W/L2W, HOT/L2} (3) x RR | 243 runs | 3 |

**Pass rules for every run**
1. Each protocol's independent decoder passes: data byte-identical, timing within the spec for the speed.
2. Cycle-identical where §7.5 says so.
3. Bubble accountant: 0 unexplained.
4. Faults only where expected, with the right cause.
5. `err` only where the host model predicts it.
6. Pin-manager violations 0 except in intended negative cases.
7. Measured limits for L1/HOT placements identical to the baselines.

### 7.8 Adversarial and stress tests (Tier 2, all must pass)

| ID | Test | Pass |
|---|---|---|
| A1 | L2 thrash: both engines in one-clock L2 loops | RR: each exactly 50 % of clocks (± 0 over 10^5); fixed: starvation exactly as spec |
| A2 | Host storm: back-to-back L2 reads/writes at the fastest link while an engine runs a one-clock L2 loop | bubbles = number of host accesses, exactly |
| A3 | COPY storm: repeated 64-word COPY + JMP while the other engine runs L2 code | other engine within bound; L1 code of the other engine untouched |
| A4 | RUN storm: random RUN toggles every 1-1000 clocks for 10^6 clocks, random placements | no stale instruction, no X on any output, faults only as expected |
| A5 | Boundary walk: code at 0x03F, at the range edges, at L2 0x00 and 0xFF | as spec (faults or correct execution) |
| A6 | Same-clock collisions: host access in exactly the clock of each request type of each engine (cycle-directed) | arbiter model match |
| A7 | X check: L2 filled with random words; any X reaching a commit, an output or a FIFO is a FAIL | 0 X |
| A8 | `rst_n` asserted mid-COPY, mid-request, mid-frame | clean reset; state as reset values |
| A9 | Policy churn every 1-50 clocks during A1 | arbiter model match |
| A10 | Maximum FIFO pressure (host never reads) combined with L2 contention | engines block correctly; no loss once the host drains |

### 7.9 Random soak (Tier 3)
- For 24 h, `regress.py --soak` keeps starting runs with a random pair, placements, factors and host walk. It changes
  host behaviour every N ms of simulated time and injects A1-A10 events at random.
- It stops at the first failure and keeps the seed.
- **Pass:** 0 failures. Report simulated clocks, frames, bytes per protocol and coverage reached.

### 7.10 Evidence and reporting
- Logs: `results/two_tier_<date>/<tier>/<case>.log`, plus merged coverage `coverage.json` and Verilator coverage
  reports.
- Report: `docs/TWO_TIER_RESULTS.md`, structured like SPI_RESULTS/I2C_RESULTS. It includes:
  - per-phase tables;
  - measured `H_PF`, `c`, area, timing budget;
  - limits per placement;
  - coverage closure;
  - mutation score;
  - formal results (depth or induction);
  - deviations.
- Tests that fail by design are labelled `EXPECTED-FAIL` and count as passes only when they fail.

---

## 8. Risks and mitigations

| # | Risk | Impact | Mitigation |
|---|---|---|---|
| K1 | The `bm_bist` 256x32 macro is not accepted on CMOS5L (A9) | L2 cannot be built | ask in Phase 0; `L2_EN=0` fallback (G6); Phase 1 is still useful |
| K2 | L2 urgent path misses timing | lower clock or failure | mode B (D7); registered prefetch requests; decide in Phase 0, confirm with STA in the flow |
| K3 | External stall introduces subtle bugs | wrong behaviour in rare cases | F1-F3 formal, I2 lockstep with a frozen independent reference, bubble mutants for every strobe |
| K4 | `SRAM_1P_behavioral_bm_bist` model differs from silicon | sim/silicon mismatch | V0.1 pins the behaviour relied on; design uses the datasheet table only (no hold-output assumption without V0.1 evidence) |
| K5 | Verilator cannot compile the macro models | no line coverage | coverage build with the abstract memory (proven equivalent, V0.2) |
| K6 | Formal does not converge on full parameters | weaker proof | small parameters + abstract memory; state the bounded depth in the report |
| K7 | Firmware places a time-critical loop in L2 | protocol limits drop | static checker refuses it (V7.3); documented T8/T9 |
| K8 | Area grows beyond the estimate | budget | Phase 0 measurement; D10 (BB optional); counters optional |
| K9 | Same-protocol pairs need pin maps | campaign gaps before Phase 7 | constraint list; full pair matrix only after Phase 7 |
| K10 | FPGA images stale | FPGA demos broken | D13; note in `src/fpga/`; regenerate later with `host/isa.py` |
| K11 | Campaign run time | slow feedback | tiers; parallel jobs; Tier 0 under 5 min |

**Inputs for the physical flow:**
- 5 macros: 4 x 64x16 + 1 x 256x32 (416.64 x 118.78 µm);
- PDN connections for both macro types;
- the urgent-fetch path as a named timing path;
- `A_DLY` tied high.

---

## 9. Documentation and memory updates

| When | Update |
|---|---|
| Phase 0 | this plan (decisions, measured area, D7); `memory.md` (decisions, plan link) |
| Phase 1 | `instructions.md` §1 (encodings, 9-bit fields), §6 (loader needs); MGMT_PLAN CTRL layout |
| Phase 2 | MGMT_PLAN register map (L2 window, new registers) |
| Phases 3-5 | `instructions.md` timing contract T7-T11 with measured `H_PF` and `c`; architecture doc fetch section |
| Phase 7 | `instructions.md` library, linker and placement rules; I2C_PLAN status (slave); README |
| Phase 9 | `docs/TWO_TIER_RESULTS.md`; ASIC_AREA_AND_MEMORY_STUDY (measured); CHALLENGE_CHECK; EXECUTION_PLAN; README status |
| End of every phase | `memory.md`: result, numbers, problems and fixes |

---

## 10. Open questions (for the user)

1. **D0:** which of R1-R4 (§3.9) are real requirements? If none, option A is the better choice.
2. **D10:** build BB (+2.8k µm² per engine) to make UART-class loops exact from L2?
3. **D11:** include `CALL`/`RET` (Phase 8) now that a shared library exists?
4. **D15:** allow ARB_CFG changes while running (proposed), or only while both engines are held?
5. Should the campaign include FPGA runs later (needs an inferred-RAM stand-in for the macros)?

---

## Appendix A: area estimate details *(est.)*

Unit costs from the area study: enable flop ≈ 67 µm² (48.99 flop + 18.14 mux2), plain flop 48.99 µm², mux2 18.14 µm².

| Item (per engine) | Bits / cells | µm² |
|---|---|---:|
| `IR2` latch | 32 enable flops | 2,144 |
| PB `{valid, addr, word}` | 42 enable flops | 2,814 |
| `IR2` load mux (macro / PB / BB) + instruction source mux (L1 / IR2) | 3 mux2 x 32 | 1,741 |
| PC +3 bits, wider incrementer and jump mux | — | ~250 |
| `RESET_PC` 9 + `L2_RANGE` 16 + `FETCH_CFG` 2 | 27 enable flops | 1,809 |
| Range comparators (2 x 8-bit) | — | ~300 |
| COPY sequencer (src 8, dst 6, count 6, state 1 + incrementers) | 21 enable flops + logic | ~1,800 |
| L1 write-port mux (COPY source: 6 address + 32 data) | 38 mux2 | ~690 |
| Fault cause | 2-3 flops | ~200 |
| **Per engine, minimum** | | **~11,750** |
| BB (optional) | 42 enable flops | 2,814 |
| 2 x 16-bit performance counters (optional) | 32 flops + incrementers | ~2,000 |

| Shared item | µm² |
|---|---:|
| Arbiter (classes, policy, RR pointer, promotion flags) | ~400 |
| 8-bit 4:1 address mux to the macro | ~435 |
| `ARB_CFG` | ~150 |
| Management decode and read-mux additions (~10 readable registers + L2 data path) | ~3,500-4,000 |
| **Shared total** | **~4,500-5,000** |

- Minimum build: 2 x 11.75k + ~4.9k ≈ 28.4k glue; + 49.5k macro = **~78k added → ~228k chip**.
- Full build: + 2 x (2.8k + ~2k) ≈ 9.6k → **~86-88k added → ~236-238k chip**. §3.2 rounds this to the 236k used in
  the tables.

## Appendix B: file plan (created or changed by phase; nothing exists yet)

| Phase | New | Changed |
|---|---|---|
| 0 | `sim/ihp_sram/RM_IHPSG13_1P_256x32_c2_bm_bist.v`, `sim/ihp_sram/<bm_bist core>.v`, `tb/tb_l2_macro.v`, `formal/abs_sram.v`, `synth/experiments/l2_standin.v` | — |
| 1 | `host/isa.py`, `host/regress.py`, `tb/ref/ref_engine_v1.v`, `tb/tb_fetch_equiv_v2.v` | `src/isa.vh`, `src/pc_reg.v`, `src/control_unit.v`, `src/engine_top.v`, `src/mgmt.v`, `src/tt_um_protocol_emulator.v`, generators, tbs, `run_tests.ps1` |
| 2 | `src/l2_mem.v`, `tb/tb_l2_host.v` | `src/mgmt.v`, top |
| 3 | `tb/ref/ref_flat_engine.v`, `tb/ref/ref_control_unit.v`, `tb/tb_l2_exec.v`, `tb/tb_arb.v`, `host/arb_model.py`, `formal/*.sby` | `src/control_unit.v`, `src/engine_top.v` (or `src/fetch_unit.v`), `src/l2_mem.v` |
| 4 | — | fetch unit, `l2_mem`, tbs, formal |
| 5 | `tb/tb_copy.v` | `src/isa.vh`, `src/control_unit.v`, `src/engine_top.v`, `host/isa.py` |
| 6 | — | `src/mgmt.v` |
| 7 | `host/link.py`, `host/fetchcheck.py`, `host/hostmodel.py`, `host/mutate.py`, `tb/tb_twotier_chip.v` | generators (pin maps), `host/workload.py` |
| 8 | — | ISA, `control_unit`, refs |
| 9 | `docs/TWO_TIER_RESULTS.md` | docs (§9) |
