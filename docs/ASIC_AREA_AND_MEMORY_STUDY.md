# ASIC Area, SRAM and Pin-Ownership Study

2026-10-11 | Status: **measurement and analysis only. No RTL under `src/` was changed, no part of the
RTL-to-GDS flow was run.** Reproduce everything with `synth/run_synth.sh` (OSS CAD Suite 2026-10-10,
Yosys 0.69, IHP `sg13cmos5l_stdcell` typ 1.20 V 25 C liberty).

## 1. How the numbers were made, and how far to trust them

`synth/synth_cmos5l.tcl` reads `src/*.v`, runs `synth`, maps flops with `dfflibmap` and logic with
`abc -liberty` onto the **real CMOS5L cell library**, and reports area in um^2 with `stat -liberty`. It
follows the LibreLane steps closely but is *not* the sign-off netlist:

- No clock tree, no resizing, no hold buffers, no tie/fill/decap. Expect the real post-route cell area to
  be roughly 10-25 % higher. This is a planning figure, not a measurement of the final design.
- The abc call fell back to its "liberty format" path on this Windows build (a quoting problem in a
  helper step). It still mapped to the real cells, but the mapping may be a few percent off LibreLane's.
- The CMOS5L library is small: 89 cells, **no plain D flip-flop**. Every flop is an async-reset flop;
  the cheapest is `dfrbpq_1` at 48.99 um^2 (a NAND2 is 7.26 um^2, a mux2 18.14, a latch `dlhq_1` 30.84,
  a clock-gate `lgcp_1` 27.22). A storage bit in flops therefore costs 49 um^2, and an enable flop costs
  49 + 18 = 67 um^2 because the library has no enable flop either.
- Area budget: the challenge gives about 24 x 200 x 150 = **720,000 um^2** nominal for 6x4. Real usable
  placement area is smaller (die margins, pin ring, power grid), and the template targets 60 % placement
  density. Treat 720k as an upper bound on the denominator.

## 2. The chip today (flop instruction memory)

Top `tt_um_protocol_emulator`, hierarchy kept: **414,137 um^2, 15,516 cells, 5,091 flops** (60 % of the area
is flops) = **57.5 % of the nominal 720k**, before clock tree, buffers or any new feature.

| Block (each instance) | um^2 | x | Total um^2 | % of chip |
|---|---:|---:|---:|---:|
| `instr_mem` 64x32 flops + write mux + read mux | 165,955 | 2 | 331,909 | **80.1 %** |
| `fifo` 4x32 | 10,211 | 4 | 40,843 | 9.9 % |
| `shift_reg` (OSR/ISR) | 3,114 | 4 | 12,457 | 3.0 % |
| `mgmt` | 8,959 | 1 | 8,959 | 2.2 % |
| `delay_counter` | 2,540 | 2 | 5,080 | 1.2 % |
| `pin_block` | 2,083 | 2 | 4,166 | 1.0 % |
| `loop_counter` | 1,694 | 2 | 3,389 | 0.8 % |
| `control_unit` | 1,598 | 2 | 3,197 | 0.8 % |
| `spi_slave` | 2,468 | 1 | 2,468 | 0.6 % |
| `pc_reg`, glue | | | ~1,670 | 0.4 % |

**Instruction memory is four-fifths of the chip.** Inside one `instr_mem`: 2,048 flops = 100.3k, 2,048
enable-feedback mux2 = 37.2k, read mux and decode = ~28k. Everything *except* instruction memory is only
**82,228 um^2 (11.4 % of nominal)**. At the template's 60 % density target the usable cell budget is about
430k at best, so the current design leaves essentially nothing for CTS, the pin manager, trace, BIST or a
third engine. The flop-based instruction memory cannot be the tape-out design.

## 3. Instruction-memory options, measured

| Option | Chip um^2 | % of 720k | How obtained | Notes |
|---|---:|---:|---|---|
| A. Flops + enable mux (today) | 414,137 | 57.5 % | measured | does not leave room to grow |
| B. Flops + clock gate per word | ~343,000 | ~48 % | estimate (drops 2x2,048 mux2, adds 128 `lgcp_1`) | needs manual ICG instancing, still huge |
| C. Latch array (`dlhq_1`) | 244,391 | 33.9 % | measured (AND-gate gating as stand-in) | latch timing and CTS support in the flow is unproven; ICG would cut ~1k more |
| **D. 4 x SRAM 1P 64x16 (2 per engine)** | **143,425** | **19.9 %** | **measured** (macro areas from the liberty) | keeps today's 64x32 per engine |
| E. 1 x SRAM 2P 64x32, shared | ~138,000 | ~19 % | estimate | only 64 words *total* |
| **F. 1 x SRAM 2P 256x32, shared, partitioned** | **~182,000** | **~25 %** | estimate (+~3k glue) | 256 words, flexible split |

Macro facts (IHP-Open-PDK `ihp-sg13g2/libs.ref/sg13g2_sram`, typ corner): 1P 64x16 = 236.8 x 64.36 =
15,240 um^2; 2P 64x32 = 52,621; 1P 256x32 = 49,489 (one port only); 2P 256x32 = 96,267. Clock-to-data-out
is 3.0-3.1 ns typ and **5.05-5.3 ns at the slow corner (1.08 V, 125 C)**; reads and writes are synchronous,
data appears one cycle after the address. Two-port macros have fully independent ports with **no conflict
handling** (same-address read/write from both ports is undefined). Leakage is tens of nW; dynamic power is
~16 uW/MHz for a 64x16 macro.

**Verdict on SRAM instead of flops: yes, it is the single biggest lever (-65 % chip area, -270k um^2).**
It is a gating decision, not yet a commitment, because of the risks below.

### Risks, in order of seriousness

1. **No CMOS5L-specific SRAM exists in the PDK.** `ihp-sg13cmos5l/libs.ref/sg13cmos5l_sram` is a symlink to
   `../../ihp-sg13g2/libs.ref/sg13g2_sram`, and the only silicon-proven SRAM project (`ttihp0p2` urish SRAM test)
   is SG13G2. The challenge page says Tiny Tapeout has SRAM examples "on this process node", so it is
   probably supported, but nothing in the public files proves the macro is accepted on the CMOS5L shuttle,
   fits the 6x4 layout, or passes precheck. **Ask the organizers/Discord before depending on it.**
2. **Flow integration is manual and rough.** The SRAM example needed a custom `pdn_cfg.tcl` (macro power on
   Metal4, connected up to TopMetal1), `PDN_MACRO_CONNECTIONS`, hand-placed macro `location`/`orientation`,
   `MAGIC_MACRO_STD_CELL_SOURCE`, `ERROR_ON_MAGIC_DRC: false` ("macro internals trigger massive DRC") and
   `MAGIC_EXT_ABSTRACT_CELLS` because "the macros are not LVS clean". Each is a place the flow can bite.
3. **The fetch timing contract must be re-derived.** Today `instr = mem[pc]` is combinational. A macro read is
   synchronous, so it cannot just be dropped in. The contract can be kept (1-cycle branches, exact d+1
   delays) by presenting `next_pc` (the D input of the PC register: hold on a stall, pc+1, or the jump
   target) to the macro address pin, so the new word is on the output in the cycle the PC changes. Stalled
   instructions simply re-read the same address. The cost is a longer critical path: macro clock-to-Q
   (5.3 ns slow corner) + decode + stall/jump select + address setup, all inside one clock. That fits 20 ns
   on paper but **has not been simulated or timed**; it needs OpenSTA through the real flow.
4. **Host writes share the engine's port.** Fine under the existing rule "instruction writes only while
   RUN=0" (address/data/write-enable muxed by `run`, six address muxes per engine, included in the numbers).
   Bonus: read-back of a loaded program comes free, which flops did not give us.
5. Macro power: ~0.8 mW at 50 MHz per 64x16 macro if read every cycle; 4 macros ~3 mW. Probably fine, but the
   board limit has not been checked. Contents are undefined at power-up, which is already safe because
   engines are held with RUN=0 until a program is written.
6. Gate-level test needs the macro's functional model (`-DFUNCTIONAL`) added to the template's GL Makefile.

## 4. Partitioning one SRAM into per-engine regions

The idea is sound only with a **dual-port** macro.

- **Single-port macro shared by two engines: reject.** Each engine fetches every cycle; one port gives one
  access per cycle. Time-sharing would halve the instruction rate or need a 2x clock, either of which
  breaks the exact-timing contract the whole chip is sold on. (Half-cycle tricks on the falling edge leave
  ~10 ns for a 5.3 ns macro plus logic at 50 MHz; not worth the risk.) The 1P 256x32 (49k) is cheap per bit
  but unusable for two engines.
- **Dual-port macro, port A = engine 0 fetch, port B = engine 1 fetch: works.** Both ports may touch any
  address, so a small directory must guarantee they never touch the same words with a write involved. Cost
  of the glue is small: a page-select register per engine (2 bits for four 64-word pages of a 256-word
  array, address = `{page, pc[5:0]}`, no adder), a 2-bit owner tag per page, and the claim rule below.
  Estimated ~3k um^2 (~32 flops + logic), not measured.
- **Why it is attractive:**
  1. More code than 64 words per engine when a protocol needs it. Unmeasured: `instructions.md` §4 notes an
     unrolled I2C byte would need "too many words", and USB low-speed or CAN firmware are likely larger still.
  2. **Resident protocol library:** four pages can hold e.g. UART-TX/RX, SPI, I2C, JTAG all at once, and
     switching protocol is writing a page number while the engine is held: no reload over SPI.
  3. Two engines can *share* one read-only page (same image on both, with different pin maps, see §5).
  4. Page-select needs **no ISA change**: `pc` stays 6 bits, JMP/DJNZ keep their 6-bit target.
- **Costs and risks:** +35k um^2 vs option D for 2x the words, plus all risks of §3, plus: the translation
  sits in the next-pc critical path (keep it to the two page bits, which change only on a page write, so
  they can come from flops), and host loading is only allowed into a page whose owner is not running
  (same rule as today, per page). A shared page must be write-protected while any user runs.
- **Recommendation:** decide by firmware size, which we can measure. If the full UART/SPI/I2C/JTAG
  images fit in 64 words each (UART 12/9, SPI 18 today), take **D** (simplest, 143k, per-engine ports, no
  directory). If I2C or a stretch protocol needs more, or the resident-library feature is wanted, take **F**
  (~182k, still only 25 % of nominal). Either way keep the macro choice behind one `instr_mem` wrapper so the
  rest of the RTL does not care.

## 5. Pin-management block (ownership directory)

Today `tt_um_protocol_emulator` merges pads with `uio_oe = oe0 | oe1` and "engine 0 wins". There is no
isolation: engine 1 can enable a pin engine 0 is using as an input and corrupt the line, and a later-loaded
protocol can silently steal a pin from a running one. A directory fixes this and also implements
architecture-doc obligations V01-V03.

> **Update 2026-10-11:** built and integrated as `src/pin_mgr.v` (ownership + claim rule + open-drain + violations; no
> diagnostic owner, no REMAP). Synthesized in the full chip: **3,680 um^2**; whole chip now **150,000 um^2 (20.8 %)**
> with the SRAM instruction memory, JPO/PUSHI and the `0x0200` management window included.

Prototype `synth/experiments/pin_mgr.v` (**area study only**; superseded by `src/pin_mgr.v`):

- 8 pads, each with an owner: none / engine 0 / engine 1 / diagnostic (host-driven). Reset = none, so
  nothing drives until the host claims it.
- Only the owner's data and enable reach the pad, and only while that engine is running.
- **Claim rule:** a claim on a pad owned by a *running* engine is refused (sticky `deny`), so loading a new
  protocol can never take a pin from a live one. A free pad, or one whose owner is held, can be claimed.
- A non-owner enabling a pad is blocked and recorded in a sticky per-engine, per-pin violation bit.
- Per-pad open-drain mode (pad data forced 0, pad enable = `oe & ~out`). **This removes the ISA gap in
  `instructions.md` §4**: with it, `OUT1`/`SETH`/`SETLO` are already I2C/1-Wire safe, so the proposed
  `CFG` open-drain bit (an ISA change to verified RTL) is not needed.
- Optional `REMAP=1`: per-pad source pin plus per-engine input map, so one firmware image can run on any
  pads (two UARTs from one 12-word image, with option F's shared page).

| Variant | Cells | um^2 | % of 720k | % of SRAM option D chip |
|---|---:|---:|---:|---:|
| Ownership + claim + open-drain + diag drive + violations | 277 | 5,206 | 0.7 % | 3.6 % |
| ... + REMAP (output and input maps) | 588 | 14,700 | 2.0 % | 10.2 % |

**Verdict: add it, the ownership version costs under 1 % of the chip.** Do REMAP only if shared firmware images
are wanted. Hooks into the management map at the architecture doc's `0x0200` window; needs a new `CLAIM`/
`RELEASE` frame op or registers, a formal property "no pad is ever driven by a non-owner or a held engine",
and a testbench that tries every illegal claim and every cross-drive. Reset-state and the existing
`run`-gating already release pins, so safety does not regress.

## 6. Other findings

- **After SRAM, the FIFOs are the next target:** 4 x 10.2k = 40.8k, i.e. **28 % of the SRAM-based chip**
  (512 bits in flops with 32-bit-wide read muxes). The architecture doc planned 8 x 16; width and depth
  should be driven by firmware needs. A latch-based FIFO or narrower words would cut this roughly in half.
- Flattened synthesis gives 410k / 16,034 cells vs 414k hierarchical (1 % difference), so the per-module
  table is trustworthy.
- Verilator `-Wall` on `src/` (the template runs a linter) gives 9 warnings, none functional: 4 width
  (`fifo.v:36,39`, `mgmt.v:87,129`), 2 empty pin connections (`engine_top.v:77,137`), 2 unused signals
  (`osr_data`, `cfg_out_pin`), and the reset synchronizer flagged sync/async (`rst_sync`, intentional).
  Clean these before the real flow.

## 7. RTL-to-GDS flow (read from the public template; nothing was run)

Sources fetched: `TinyTapeout/ttihp-verilog-template` branch `cmos5l`, `IHP-Open-PDK` (`dev`) `ihp-sg13cmos5l`.

1. **Project files:** `info.yaml` (title, `top_module: tt_um_...`, `source_files` flat under `src/`, `clock_hz`,
   `tiles` set to `"6x4"` per the challenge although the stock template comment lists up to 8x2, pin names),
   `src/config.json`, `test/` (cocotb + Icarus), `docs/info.md`.
2. **`src/config.json` defaults:** `CLOCK_PERIOD` 20 ns (50 MHz), `PL_TARGET_DENSITY_PCT` 60, hold margins 0.1/0.05
   ns, absolute die size, no PDN rings, CTS on, Verilator lint on, KLayout DRC and XOR off, `GRT_ALLOW_CONGESTION` 1.
3. **GitHub workflow `gds.yaml`** with `tt-gds-action@ihp-cmos5l`, `pdk: ihp-sg13cmos5l`: LibreLane runs Yosys
   synthesis, floorplan, IO placement, PDN, global/detail placement, CTS, global/detail routing, multi-corner
   STA (typ 1.20 V 25 C, fast 1.32 V -40 C, slow 1.08 V 125 C), fill, antenna repair, Magic DRC and LVS.
   Then jobs `precheck` (Tiny Tapeout checks), `gl_test` (cocotb on the gate netlist with
   `sg13cmos5l_stdcell.v` and `sg13cmos5l_io.v`) and `viewer`.
4. **Library facts that matter:** site 0.48 x 3.78 um (1.8144 um^2), no tap/endcap cells, only async-reset flops,
   `synth_exclude.cells` removes `lgcp_1`, `slgcp_1`, `sdfbbp_1`, `dfrbp_2` and `sighold` from synthesis, CTS buffers
   `buf_1..8`.
5. **Work our repo needs before step 3:** put the RTL flat in `src/` (we have `isa.vh` includes, `src/fpga` must
   stay out), port the checks that matter into cocotb (`test/test.py`) since the gate-level job runs cocotb,
   not our Icarus testbenches (the Python workload models can be reused as the golden side), clean the lint
   warnings, and settle the SRAM question first because it changes `config.json` (macro, PDN script).

## 8. Open items, in priority order

1. Ask Tiny Tapeout/the organizers: is the 1P/2P SRAM accepted on the CMOS5L 6x4 shuttle, and with which macro views?
2. Measure firmware word counts for the full protocol set (decides D vs F).
3. Prototype next-pc fetch with a behavioral SRAM model and rerun `tb_engine_top` / `tb_mgmt_*` to prove the
   cycle-exact contract survives the synchronous read.
4. Get OpenSTA numbers (needs the real flow or a local LibreLane) for the SRAM-to-address path.
5. Simulate and formally check `pin_mgr` before integrating.
6. Shrink the FIFOs.
