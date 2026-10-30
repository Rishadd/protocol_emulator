# To-do (working list, started 2026-10-20)

Direction decided 2026-10-20: **shared 512-word memory is the base**, get as close to 50 MHz as possible with a meaningful layout, then
build the logic analyser on top of it. Tick items off as they finish.

## A. Timing of the shared-memory layout
- [x] A1. Flow-only variants started on the sh4 baseline: sh5a (17 ns + resizer margin), sh5b (18 ns + repair after global routing), sh5c (18 ns + delay synthesis)
- [x] A2. Live pictures for sh5a / sh5b / sh5c
- [x] A3. Read the results, keep what helps: tight constraint (17 ns) + setup margin 0.5 + trap gate in the engines; repair after GRT and delay synthesis do not pay (sh5a-sh9b, reproduce/flows/README.md)
- [x] A4 (sh6 gate in the engines: 21.45 -> 20.41 ns, free; sh8 recipe 19.64 ns = 50.9 MHz, +0.36 ns slack at 20 ns). RTL / placement changes aimed at the macro-to-ALU path (gating next to the engines, instruction register, fences), each with its own run
- [ ] A5. Best layout checked: LVS, DRC, precheck, picture review (meaningful floorplan, not a random mess)
- [x] A6. Explain what a slower clock changes (instruction timing, firmware tables, protocols)

## B. Repository
- [x] B1. Frame v2 regression on merge/frame-v2: found a real bug (v1 STATUS byte one clock stale: duplicated TX byte); fixed in mgmt.v, duplex stress ALL PASS, v2 236/236, unit 22/22; full regression on the fixed branch running (results in ~/pe_merge_lx/results/regression_2026-10-20_merge2)
- [x] B2. Merge frame v2 into main, push
- [x] B3. feat/shared-imem merged with frame v2 + the STATUS fix (branch shared/on-v2 in ~/pe_shared_v2: mgmt.v re-applied by hand, 22/22 unit tb, shmem_chip_test PASS, v2 236/236); also fixed tb_pc_reg (START tied)
- [x] B4. Clean up the directory: six stale worktree copies deleted (about 3 GB), build/ cleared, unique files archived in results/archive_old_worktrees, backup bundle ~/protocol_emulator_all_refs_2026-10-20.bundle

## A2. Submission check of the current version (started 2026-10-20 evening)
- [x] Branch check/shared-sh8 pushed (starts GitHub docs / gds / test); config = sh8 recipe
- [ ] Read the GitHub Actions result (gds, precheck, gl_test, test)
- [ ] Local flow sh10 (same RTL and recipe) finished: LVS, DRC, antenna, slack, hold, slew / cap
- [ ] Precheck on sh10 (`bash reproduce/06_precheck_and_reports.sh sh10`)
- [ ] Judge the 14-18 max-slew / 24-42 max-cap violations seen in every run

## C. Shared-memory software (before the logic analyser)
- [x] C1. Explain what it is and what Step 4 needs
- [x] C2. RTL-versus-model differential test in shared mode
- [x] C3. Formal proofs (fetch stays in the window, host writes never change a running window, lock holds until RUN falls)
- [x] C4. REGION read (ENG_BASE+0x008) and instruction readback
- [x] C5. Host layer (verified load, REGION check on start, plan_images), RTL mutants (16/16) and the protocol suites from the shared memory (phase E: CAN, JTAG, 1-Wire, Modbus, SPI, I2C) done; docs and final flow run (S7) open

## C2. Logic analyser (docs/DEBUG_LA_PLAN.md phases)
- [x] Phase 1 model, Phase 2 capture unit RTL against the model (la_rtl_test, 12/12 mutants)
- [x] Phase 3a TSTAMP opcode 30 + RPUT TRIG (diff tests 0 mismatches, 38/38 mutants), 3b la_block + window 0x0300 + IRQ bit 8 + view 6 + la_host.py + la_chip_test PASS
- [ ] Phase 4 engine debug, Phase 5 sniffers, Phase 6 formal + chip-level mutants, Phase 7 flow with the third macro (placement not defined yet), Phase 8 la_capture.py + GTKWave demo

## D. Plans
- [x] D1. Logic analyser plan (same format as the other module plans)
- [x] D2. Standalone USB device plan and test plan (like the competitors)
- [x] D3. Ethernet (10BASE-T) feasibility
- [x] D4. Web search: how many protocols can we pull off

## E0. Reproducibility
- [x] reproduce/ folder (README.md, install / tests / formal / flow / precheck / docs scripts, flows/ archive sh4-sh9b); sh8 rerun matched 29 of 29 completed steps
- [ ] Refresh reproduce/branches.bundle + SHARED_COMMIT after the final merge of shared/on-v2

## E. Wrap-up
- [ ] E1. memory.md, EXECUTION_PLAN, HANDOFF updated; commit; push (repo is private)

## F. User guide (skeleton written 2026-10-20: docs/USER_GUIDE.md and .html)
- [x] F1. Skeleton: all chapters, subsections, brief placeholder text, contents page, HTML build script
- [ ] F2. Pico host library `pe_chip` (MicroPython), tested against the simulator; fill chapters 3-7 examples
- [ ] F3. Logic analyser: registers, host tool `la_capture.py`, GTKWave screenshots and .gtkw (chapter 11)
- [ ] F4. Engine debug and sniffer (chapter 12); TSTAMP (8.8, 9.5)
- [ ] F5. Standalone USB (10.13) and Ethernet (10.16) when built; catalogue protocols (10.16)
- [ ] F6. Final pin map, ratings, power, maximum clock (2.2, 14.2, 15, Appendices B and C); check the links marked "to check" (Appendix G)
- [ ] F7. Worked recipe template (10.1), first program (8.10), quick-reference card, glossary; remove every PLACEHOLDER marker
