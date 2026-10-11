# Instruction memory moved to SRAM macros: changes and measured gains

2026-10-11. Replaces the flop-based `instr_mem` (64 x 32 per engine) with two IHP SG13 1P 64x16 SRAM
macros per engine. UART full duplex keeps working at 115200 and 9600 baud, cycle-exact, in simulation.
Baseline = commit `42d262a`. Background and option study: [ASIC_AREA_AND_MEMORY_STUDY.md](ASIC_AREA_AND_MEMORY_STUDY.md).

## 1. Result in one table

Yosys 0.69 + abc on the real IHP `sg13cmos5l_stdcell` typ 1.20 V 25 C library, same script
(`synth/run_synth.sh`), hierarchy kept, whole chip `tt_um_protocol_emulator`. Macro area from the macro
liberty (15,240.448 um^2 each).

| | Flops (42d262a) | SRAM macros (now) | Change |
|---|---:|---:|---:|
| Chip area (cells + macros) | 414,136.7 um^2 | 143,421.0 um^2 | **-270,715.7 um^2 (-65.4 %)** |
| Share of the 720,000 um^2 nominal 6x4 area | 57.5 % | 19.9 % | -37.6 points |
| Standard cells | 15,516 | 3,834 (+ 4 macros) | **-11,682 (-75.3 %)** |
| Share of the ~24k logic-cell budget (1k/tile x 24) | 64.7 % | 16.0 % | |
| Flip-flops (`dfrbpq_1`) | 5,091 | 995 | -4,096 (-80.5 %) |
| Sequential area | 249,402.0 um^2 (60.2 %) | 48,743.9 um^2 (34.0 %) | |

Not included (same for both, so the comparison holds): clock tree, hold buffers, resizing, fill.

## 2. Per module (one instance each)

| Module | Flops: um^2 (cells) | SRAM: um^2 (cells) | Instances |
|---|---:|---:|---:|
| `instr_mem` | 165,954.7 (5,848) | 30,602.5 (2 macros + 8 cells) | 2 |
| `pc_reg` | 558.8 (33) | 538.9 (30) | 2 |
| `engine_top` glue | 110.7 (5) | 128.8 (7) | 2 |
| `control_unit` | 1,598.3 (113) | 1,612.8 (112) | 2 |
| `delay_counter` | 2,540.0 (154) | 2,521.7 (155) | 2 |
| `fifo` | 10,210.8 (394) | 10,210.8 (394) | 4 |
| `shift_reg` | 3,114.2 (170) | 3,114.2 (170) | 4 |
| `loop_counter` | 1,694.5 (116) | 1,694.5 (116) | 2 |
| `pin_block` | 2,082.9 (80) | 2,082.9 (80) | 2 |
| `mgmt` | 8,958.9 (451) | 8,958.9 (451) | 1 |
| `spi_slave` | 2,467.6 (91) | 2,467.6 (91) | 1 |
| top glue | 330.2 (20) | 330.2 (20) | 1 |

- Old `instr_mem`: 2,048 flops + 2,104 mux2 (write-enable feedback) + 423 mux4 and 1,273 other cells
  (read mux and decode). Two of them were 80.1 % of the chip.
- New `instr_mem`: 2 x 15,240.4 um^2 macros + 121.6 um^2 glue (6 mux2 address select, 1 inverter, 1 tie).
- `engine_top` +2 cells = the two AND gates that mask the FIFO strobes (section 4). `control_unit`,
  `delay_counter`, `pc_reg` differ by under 20 um^2: abc mapping noise plus the `next_pc` output.
- The four FIFOs (40,843 um^2) are now the largest block: 28.5 % of the chip.

## 3. Placement footprint and wiring (estimates, not a place-and-route result)

Footprint at the template's 60 % placement density = standard cells / 0.6 + macros:

| | Flops | SRAM, no halo | SRAM, 10 um halo per macro |
|---|---:|---:|---:|
| Footprint | 690,228 um^2 | 198,394 um^2 | 224,087 um^2 |
| Share of 720k | 95.9 % | 27.6 % | 31.1 % |

The flop design fills almost the whole die before clock tree and buffers; the SRAM design leaves about
two thirds free. Wiring (analytic model on the synthesised netlist, see the area study): a flop
`instr_mem` needs roughly 365-543 mm of routed wire, mostly ~130 high-fanout broadcast nets (word write
enables, write data, read select); the macro version needs about 10 mm per engine (43 short pin nets per
macro, all on one edge, Metal2). The macro blocks Metal1-4 over its 236.8 x 64.36 um body.

## 4. RTL changes

| File | Change |
|---|---|
| `src/instr_mem.v` | Two `RM_IHPSG13_1P_64x16_c2` macros. Same 6-bit address to both; `u_lo` stores bits [15:0], `u_hi` bits [31:16] of every word, so they act as one 64 x 32 memory. Address = `waddr` while `we`, else the fetch address. Read is now **synchronous** (data one clock after the address). Sim-only helpers `poke`, `peek`, `load_hex`; `INIT_FILE` still preloads in simulation. |
| `src/pc_reg.v` | New output `next_pc` = the value `pc` takes at the next edge (jump > advance > hold, 0 in reset). `pc <= next_pc`. |
| `src/engine_top.v` | `instr_mem.addr = next_pc` (was `pc`), so `instr` is the word for the current `pc` in the same cycle as before. FIFO strobes `tx_rd_en`, `rx_wr_en` masked with `core_rst_n` (2 AND gates). |

Unchanged: `control_unit`, `fifo`, `shift_reg`, counters, `pin_block`, `mgmt`, `spi_slave`, the top, the ISA
and both UART firmware images.

**Why the FIFO mask is needed.** When RUN drops, `pc` resets to 0 at once but the macro output still shows
the old pc's word for one more clock. `control_unit` decodes it, and a stale `PULL`/`PUSH` popped or
pushed a FIFO once. The lockstep test below found this; the old design never did it. Every other
control output goes to blocks that are already held in reset by `core_rst_n`. The mask also removes an
older quirk: the held engine decodes word 0, so a `PULL`/`PUSH` at word 0 touched the FIFOs while RUN=0
(UART firmware has `CFG` at word 0, so it was never hit).

**Rule for the host:** RUN may rise from the second clock after the last instruction write (the held
engine re-reads word 0 every clock). `mgmt` writes and RUN arrive in separate 7-byte SPI frames, so this
always holds.

## 5. Test and tool changes

- `sim/ihp_sram/`: vendored PDK simulation models (Apache-2.0). `SRAM_1P_behavioral` comes from
  IHP-Open-PDK `RM_IHPSG13_1P_core_behavioral.v` (not in the local `C:\tools\ihp-sram` copy). Compile
  with `-DFUNCTIONAL`.
- Testbenches: `imem.mem[...]` accesses replaced by `imem.poke/peek/load_hex` (tb_engine_top,
  tb_mgmt_dual/frame/load/tx, tb_uart_rx, tb_uart_workload). `tb_instr_mem` rewritten for the
  synchronous read and checks the lo/hi split. `tb_pc_reg` checks `next_pc`. `tb_mgmt_duplex` takes `+BIT`.
- New `tb/tb_fetch_equiv.v` + `tb/ref/ref_engine.v` (the engine exactly as in 42d262a): both engines get
  the same random programs (written through the host port), FIFO and pin traffic, RUN drops and rewrites
  while held; every output and the instruction bus must match on every clock.
- Host: `uart_workload.SIM_DEFS/SIM_LIBS` used by every harness; `mgmt_duplex_stress.py --baud N`
  regenerates both firmware images for that baud.
- `run_tests.ps1`: compiles the macro models, adds `tb_fetch_equiv`, drops the FPGA top testbenches.
- `synth/synth_cmos5l.tcl`: reads the 64x16 macro liberty by default.

## 6. Verification

All runs in Icarus Verilog 12 with the PDK macro models. "Before" = same suites on 42d262a.

| Check | Before (flops) | After (SRAM) |
|---|---|---|
| `run_tests.ps1` unit + integration testbenches | 15/15 PASS | 15/15 PASS + `tb_fetch_equiv` PASS, 0 compiler warnings |
| `tb_fetch_equiv`, old vs new engine in lockstep | n/a | 0 output and 0 instruction-bus mismatches over ~4.4 M clocks (5 seeds x 1,500 random programs), all 17 opcodes + illegal-opcode fault path |
| Deliberate bugs (mutations) caught | n/a | 5/5: `addr=pc`, no reset on `next_pc`, no FIFO mask, lo/hi swapped, write address ignored |
| UART TX 9600 (245 bytes) / 115200 (1,024 bytes) | PASS, all frames cycle-exact | PASS, all frames cycle-exact |
| UART RX 115200 1,024 bytes, 9600 48 bytes, jitter | PASS, tolerance +6.0 / -4.5 % | PASS, tolerance +6.0 / -4.5 % |
| **Full duplex over SPI, 115200**, 1,024 bytes, 8 cases | ALL PASS | ALL PASS, identical counts (e.g. ideal: 2,803 retries, 21 polls, 5,004 frames, 4.58 M clocks) |
| **Full duplex over SPI, 9600**, 128 bytes, 8 cases | (not run) | ALL PASS: live echo, peer +-2 %, 20 ns jitter, replay, replay -1.5 % + 15 ns jitter, and the negative host-stall check detects the loss |

Full duplex = `host/mgmt_duplex_stress.py` on the chip top `tt_um_protocol_emulator`: both programs
loaded over SPI into the macros, engine 0 transmits UART TX on P0, engine 1 receives on P1 while P0
is busy, the host reads and writes both through SPI. Every byte sent, echoed and read back matches, and
every transmitted frame is cycle-exact against the Python reference. At 115200 the counts equal the
flop baseline, i.e. the chip behaves cycle for cycle the same.

## 7. Not done / open

- **FPGA:** out of scope by request. `src/fpga`, `quartus/` and their testbenches (`tb_de0_nano_*`,
  `tb_uart_duplex.v` + `host/uart_duplex_workload.py`) are untouched and no longer build against the new
  `instr_mem` (the FPGA has no IHP macro).
- **CMOS5L acceptance of the SG13G2 macro** is still unconfirmed (PDK symlink; the only silicon-proven
  example, `urish/ttihp-sram-test`, is on the SG13G2 shuttle). Ask the organizers.
- **Timing not analysed:** new path = macro clock-to-out (3.0-3.1 ns typ, 5.05-5.3 ns slow corner) +
  decode + `next_pc` select + macro address setup, inside 20 ns. Needs STA in the real flow.
- LibreLane config not written yet (`MACROS`, `PDN_MACRO_CONNECTIONS`, custom `pdn_cfg.tcl`, DRC/LVS
  settings, as in `ttihp-sram-test`). Gate-level test needs the macro model with `-DFUNCTIONAL`.
