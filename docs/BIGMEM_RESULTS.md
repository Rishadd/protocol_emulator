# 256-word instruction memory per engine: changes and RTL results

2026-10-17. Replaces the 64-word instruction memory of each engine (two 1P 64x16 SRAM macros) with **one IHP SG13 1P 256x32 SRAM
macro per engine**, widens the PC and the jump targets to 8 bits, and re-runs every protocol test. Simulation only: no synthesis,
no area, no timing (by request). Baseline = commit `bff855d`. Evidence: `results/bigmem_2026-10-17/`.

## 1. Result in one table

| | 64 words (bff855d) | 256 words (now) |
|---|---|---|
| Words per engine | 64 | **256** |
| Macro | 2 x `RM_IHPSG13_1P_64x16_c2` | 1 x `RM_IHPSG13_1P_256x32_c2_bm_bist` |
| PC / jump target | 6 bit | 8 bit |
| Unit + integration testbenches (`run_tests.ps1`) | 19/19 PASS | **19/19 PASS** (instruction memory, mgmt map, control unit, lockstep, load tests widened) |
| Lockstep vs original fetch (`tb_fetch_equiv`) | 0 mismatches, 4.4 M clocks | **0 mismatches, 5.8 M clocks** (5 seeds x 1,500 programs, 256 words, 20 legal opcodes) |
| UART TX 9600 / 115200, exactness | PASS, every frame cycle-exact | **PASS, every frame cycle-exact** |
| UART RX tolerance, 1,024 bytes | +6.0 % / -4.5 % | **+6.0 % / -4.5 %** |
| UART full duplex over SPI, 115200 / 9600 | ALL PASS | **ALL PASS**, retries and polls identical |
| SPI master + slave (`spi_test.py`) | 312/312 | **312/312**, all measured limits identical |
| I2C master (`i2c_test.py`) | 60/60 | **60/60**, all measured limits identical |
| Workload campaign (`workload.py`) | UART 13/13, SPI+I2C+combo 42/42 | **55/55**, limits identical |
| Same suites with every firmware at word 192 (`FW_ORG=192`) | n/a | **all pass** (SPI 312/312, I2C 60/60, UART, duplex, workload 55/55 after the harness fix) |
| Mutants (width/decode bugs) caught | n/a | 9/9 |

The protocols behave exactly as before: same waveforms, same retry/poll counts, same limits. What is new is headroom.

## 2. What changed

### RTL

| File | Change |
|---|---|
| `src/instr_mem.v` | One `RM_IHPSG13_1P_256x32_c2_bm_bist`. Same port as before with 8-bit addresses: address = `waddr` while `we`, else the fetch address. `A_BM` all ones (every bit written), BIST port tied off. Read is still synchronous. `poke/peek/load_hex` now cover 256 words. |
| `src/pc_reg.v`, `src/engine_top.v`, `src/tt_um_protocol_emulator.v` | `pc`, `next_pc`, `jump_addr`, `imem_waddr`, `pc0/pc1` are 8 bits. |
| `src/control_unit.v`, `src/isa.vh` | Jump target = `operand[7:0]` (JMP, DJNZ, JPO, JPH, JPL). **JPH/JPL pin field moved from `[8:6]` to `[10:8]`** (the address needs `[7:0]`). Nothing else in the ISA changed. |
| `src/mgmt.v` | IMEM window moved from `base+0x100+4i` (64 words) to **`base+0x400+4i`, i = 0..255** (it could not grow in place: `+0x200/+0x204` are TX/RX). The old `0x1100`/`0x2100` window is now unmapped and sets `err`, like any other bad address. CTRL read is `{pc[15:8], fault, halted, RUN}` (pc was `[13:8]`). |

Not changed: FIFOs, shifters, counters, `pin_block`, `pin_mgr`, `spi_slave`, the fetch contract (`instr_mem` addressed with `next_pc`, FIFO strobes masked with `core_rst_n`). One instruction still executes per clock with the same branch latency.

### Firmware

| File | Change |
|---|---|
| `host/spi_prog.py`, `host/i2c_prog.py` | JPH/JPL operand is `pin << 8 | addr`; `assemble` limit 256 words; disassembler updated. No program text changed. |
| `host/fw_layout.py` (new) | `FW_ORG=<n>` relocates any generated image to word n: word 0 becomes `JMP n`, every JMP/DJNZ/JPH/JPL/JPO target gets +n, the rest is HALT. Used by `spi_prog.assemble`, `uart_workload.uart_tx_program`, `uart_rx_prog`. |
| `src/fpga/uart_*_prog.hex` | Unchanged (only JMP/DJNZ, targets below 64). |

Program sizes (words, from the generators): UART TX 12, UART RX 9, SPI master 17-18, SPI slave 16-18 (CPHA 0/1), I2C master 46.
**All five together are 102 words**, i.e. 40 % of one engine's memory. The I2C slave that did not fit in 64 words
(counted ~64-67, [I2C_PLAN.md](I2C_PLAN.md) section 6.4.1) now fits with room to spare; it is **not written** (not asked for).

### Simulation and tests

- `sim/ihp_sram/`: the 256x32 wrapper plus the real IHP core model `SRAM_1P_behavioral_bm_bist` (fetched from the IHP-Open-PDK
  repo; it was not in the local PDK copy). The 64x16 models stay for reference.
- `run_tests.ps1` and the Python harnesses compile the new models. Testbenches use the new window (`0x400`) and 8-bit pc.
- Widened tests: `tb_instr_mem` (all 256 words, address-bit aliasing 3/67/131/195, first and last word), `tb_control_unit` (JPH/JPL
  targets 200 and 255, pin 7, JMP uses `operand[7:0]` only), `tb_mgmt_frame` (words 64/128/255 written, old and past-the-end
  windows rejected), `tb_mgmt_load` (a 256-word program that executes every word, jumping back from word 255, in lockstep with a golden
  engine), `tb_mgmt_dual` (D10: distinct data in all 256 words of both engines through the management link; rejected-address
  list extended), `tb_mgmt_read` (R8b: CTRL read at pc 200 and 129).
- `tb_fetch_equiv`: the reference engine (combinational flop memory, addressed with `pc`) is widened to 256 words / 8 bits and the
  random programs now use all 256 words, 8-bit jump targets and JPH/JPL/JPO. It checks that every 64-word quarter of the
  memory is executed.
- Chip-level protocol testbenches load the program (plus one HALT word), not 256 words, as a real host would.

## 3. Verification detail

### 3.1 Unit and integration (`run_tests.ps1`)

19/19 PASS (`results/bigmem_2026-10-17/run_tests.txt`), 0 compiler warnings.

### 3.2 Lockstep against the original fetch scheme

`tb_fetch_equiv`, seeds 1-5, 1,500 random programs each: 1.15-1.17 M clocks per seed, **0 output mismatches, 0 instruction-bus
mismatches**, about 55k jumps, 320k stall cycles, 4.4k RUN drops with host rewrites while held per seed. Run cycles per 64-word quarter
of the memory: roughly 430k / 95k / 100k / 115k, so the upper three quarters are exercised, not just the first.

### 3.3 Mutants (width and decode bugs)

Each mutant is applied to a copy of `src/`; the 9 relevant testbenches are run; a mutant is caught if any fails
(`results/bigmem_2026-10-17/mutants.txt`).

| Mutant | Caught by |
|---|---|
| host write address truncated to 6 bits | `tb_instr_mem`, `tb_mgmt_frame`, `tb_mgmt_load`, `tb_mgmt_dual`, `tb_mgmt_read`, `tb_fetch_equiv` |
| fetch address truncated to 6 bits | `tb_instr_mem`, `tb_fetch_equiv` |
| `jump_addr` = `operand[5:0]` | `tb_control_unit`, `tb_fetch_equiv` |
| JPH/JPL pin field still `[8:6]` | `tb_control_unit` |
| `imem_waddr` = `addr[7:2]` (6 bits) | `tb_mgmt_frame`, `tb_mgmt_load`, `tb_mgmt_dual`, `tb_mgmt_read` |
| IMEM window decodes every address above 0x400 | `tb_mgmt_frame`, `tb_mgmt_dual` |
| `pc_reg` 7 bits wide | `tb_mgmt_load`, `tb_fetch_equiv` |
| `instr_mem.addr = pc` instead of `next_pc` | `tb_mgmt_load`, `tb_mgmt_dual`, `tb_mgmt_read`, `tb_fetch_equiv`, `tb_engine_top` |
| CTRL read truncates pc to 6 bits | **survived the first sweep**; caught by `tb_mgmt_read` R8b, added for this reason |

### 3.4 Protocol suites, firmware at word 0 (the normal layout)

| Suite | Result | Notes |
|---|---|---|
| `uart_workload.py --bauds 9600 115200 --limits` | 2/2 baud rates PASS, all frames cycle-exact; limit cases as before | 25 Mbaud (D=0) and 16.7 Mbaud (D=1) exact; odd D exact; the "host ignores tx_full" case fails by design (FIFO overflow demo, 5 of 1,024 bytes sent) exactly as before |
| `uart_rx_workload.py` | ALL PASS, tolerance **+6.0 % / -4.5 %** | 1,024 bytes at 115200, 48 bytes at 9600, 20 ns jitter, baud-error sweep |
| `mgmt_duplex_stress.py` (115200, 1,024 bytes) | ALL PASS, 8 cases | retries/polls **identical** to bff855d (e.g. ideal: 2,803 retries, 21 polls); frames 105 fewer (5,005 -> 4,900) only because the testbench now loads 23 words instead of 128 |
| `mgmt_duplex_stress.py --baud 9600` (128 bytes) | ALL PASS, 8 cases | live echo, peer +-2 %, jitter, replay, stall-loss detection |
| `spi_test.py` | **312/312**, 0 limit lines changed (22) | all 4 modes, engine and full chip, slave, mutants |
| `i2c_test.py` | **60/60**, 0 limit lines changed (3) | 100/400/1000 kHz, peers, stretch, mutants; max SCL with an ideal slave 6.25 MHz as before |
| `workload.py` | 55/55, limits identical | section 4.1 |

The only differences from the pre-change logs are chip-level management frame counts (different number of words loaded) and, in
the SPI log, sample times that moved because the earlier log predates the pad-claim frames.

## 4. Firmware at the top of the memory (`FW_ORG=192`) and the workload campaign

### 4.1 Workload campaign (`workload.py`, only through the management link), firmware at word 0

**55/55 cases as expected** (UART 13/13, SPI + I2C + combo 42/42), same as bff855d. Every measured limit is identical:

| Limit | bff855d | now |
|---|---|---|
| UART RX open loop, slowest management half period at 115200 | 32 clk pass / 40 fail | 32 / 40 |
| UART RX open loop, max baud | 460800 pass / 921600 fail | 460800 / 921600 |
| SPI slave min CS spacing, host interleaved | 25 us pass / 20 fail | 25 / 20 |
| SPI slave min CS spacing, host burst | 25 / 20 | 25 / 20 |
| SPI slave min CS spacing, host all | 50 / 40 | 50 / 40 |

The UART section was re-run (13/13) after the `TMAX` change described in section 5 (`workload_uart_rerun.txt`).

### 4.2 The same suites with every firmware image at word 192 (`FW_ORG=192`)

Word 0 is `JMP 192`, the program occupies words 192-255 (UART TX 12 words, RX 9, SPI 16-18, I2C master 46), so the 8-bit PC, 8-bit
jump targets and the top quarter of the macro are exercised by real protocol traffic.

| Suite | Result |
|---|---|
| `uart_workload.py --bauds 9600 115200 --limits` | 2/2 PASS, all frames cycle-exact; same limit cases (pc reported as 195 = PULL) |
| `uart_rx_workload.py` | ALL PASS, tolerance +6.0 % / -4.5 % |
| `mgmt_duplex_stress.py` 115200 and 9600 | ALL PASS, 8 cases each; retries and polls identical to word-0 run |
| `spi_test.py` | **312/312** |
| `i2c_test.py` | **60/60** (7/7 mutants after fixing the mutant locator) |
| `workload.py` | 54/55 in the first run; the one failure was the harness budget bug below. After the fix the UART section is **13/13**, and the SPI/I2C/combo part (42/42 in that run) and all limits equal the word-0 run |

Cost of relocation: one clock at start (the `JMP`), every waveform shifts by 20 ns, nothing else.

## 5. Findings while doing this

1. **Four harness assumptions of "64 words" surfaced** (none an RTL bug): the UART TX testbench waited for `pc == 3` to see the PULL
   (hung with relocated firmware; now `+PULLPC`); the I2C mutant "t_HD;STA = 0" patched `len(ws) - 2`, a no-op once the image is padded to
   256 words (now locates the last program word); the workload host's cycle budget (`TMAX`) was eaten by loading 512 words at 100 us
   per frame (a 64-byte TX run failed with 0 bytes sent; the testbenches now load only the program, and `+TMAX` in `tb_mgmt_duplex` counts from the end of loading); the CTRL-read test never used a
   pc of 64 or more, so a pc-truncation mutant survived until R8b.
2. **Relocation costs exactly one clock** (the `JMP n` at word 0): every waveform shifts by 20 ns (visible in the I2C failure
   timestamps, 2872 -> 2892). Retries, polls and all limits are identical.
3. **The 256x32 macro is the BM + BIST variant** (the only 256x32 single-port macro in the PDK). `A_BM` must be driven (tied to ones)
   and `A_BIST_*` tied off (`A_BIST_EN = 0`); both are constants in `instr_mem.v`.
4. The loading cost of a full image grows with the memory (256 frames at 56 bits each), so a host should write only the program
   words; the testbenches now do.

## 6. Not done, open

- **No synthesis, area, timing or power**, as requested. For orientation only, from the macro datasheets (not a synthesis result):
  1P 256x32 = 49,488.5 um^2 vs 2 x 15,240.4 = 30,480.9 for the old pair, so **+19.0k um^2 per engine, +38.0k for the chip**
  (+5.3 points of the 720k nominal area); on top of the last synthesised chip (150k) that would be roughly 188k (about 26 %).
  The macro is physically bigger (416.6 x 118.8 um); clock-to-output and the macro-to-`next_pc` path were not analysed.
- **Macro acceptance**: the CMOS5L PDK only links to the SG13G2 SRAM macros (open item A9); the 256x32 BM/BIST macro has not been
  compared with any silicon-proven example (the earlier study found only a SG13G2 one, `urish/ttihp-sram-test`).
- I2C slave not written (fits now). No multi-protocol resident image was demonstrated (all five fit; selecting one by rewriting
  word 0 is what `FW_ORG` already exercises).
- FPGA tops (`src/fpga`, `quartus/`) still do not build against the macro `instr_mem` (unchanged from the earlier SRAM change).
- The `quartus` and older docs still describe the 64-word window (`base+0x100`); this document and `instructions.md` /
  `mgmt.v` header are current.
