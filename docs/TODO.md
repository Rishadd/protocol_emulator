# To-do (working list, started 2026-10-20)

Direction decided 2026-10-20: **shared 512-word memory is the base**, get as close to 50 MHz as possible with a meaningful layout, then
build the logic analyser on top of it. Tick items off as they finish.

## A. Timing of the shared-memory layout
- [x] A1. Flow-only variants started on the sh4 baseline: sh5a (17 ns + resizer margin), sh5b (18 ns + repair after global routing), sh5c (18 ns + delay synthesis)
- [x] A2. Live pictures for sh5a / sh5b / sh5c
- [ ] A3. Read the three results, keep what helps
- [ ] A4 (in progress: sh6 = gate moved into the engines). RTL / placement changes aimed at the macro-to-ALU path (gating next to the engines, instruction register, fences), each with its own run
- [ ] A5. Best layout checked: LVS, DRC, precheck, picture review (meaningful floorplan, not a random mess)
- [x] A6. Explain what a slower clock changes (instruction timing, firmware tables, protocols)

## B. Repository
- [x] B1. Frame v2 regression on merge/frame-v2: found a real bug (v1 STATUS byte one clock stale: duplicated TX byte); fixed in mgmt.v, duplex stress ALL PASS, v2 236/236, unit 22/22; full regression on the fixed branch running (results in ~/pe_merge_lx/results/regression_2026-10-20_merge2)
- [x] B2. Merge frame v2 into main, push
- [x] B3. feat/shared-imem merged with frame v2 + the STATUS fix (branch shared/on-v2 in ~/pe_shared_v2: mgmt.v re-applied by hand, 22/22 unit tb, shmem_chip_test PASS, v2 236/236); also fixed tb_pc_reg (START tied)
- [x] B4. Clean up the directory: six stale worktree copies deleted (about 3 GB), build/ cleared, unique files archived in results/archive_old_worktrees, backup bundle ~/protocol_emulator_all_refs_2026-10-20.bundle

## C. Shared-memory software (before the logic analyser)
- [x] C1. Explain what it is and what Step 4 needs
- [x] C2. RTL-versus-model differential test in shared mode
- [x] C3. Formal proofs (fetch stays in the window, host writes never change a running window, lock holds until RUN falls)
- [x] C4. REGION read (ENG_BASE+0x008) and instruction readback
- [x] C5. Host layer (verified load, REGION check on start, plan_images), RTL mutants (16/16) and the protocol suites from the shared memory (phase E: CAN, JTAG, 1-Wire, Modbus, SPI, I2C) done; docs and final flow run (S7) open

## D. Plans
- [x] D1. Logic analyser plan (same format as the other module plans)
- [x] D2. Standalone USB device plan and test plan (like the competitors)
- [x] D3. Ethernet (10BASE-T) feasibility
- [x] D4. Web search: how many protocols can we pull off

## E. Wrap-up
- [ ] E1. memory.md, EXECUTION_PLAN, HANDOFF updated; commit; push (repo is private)
