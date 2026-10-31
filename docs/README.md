# Documentation map

Read in this order if you are new to the project. "Decisions" documents say what was chosen and why; "results" documents say what was measured.

| Read | File | What it is |
|---|---|---|
| 0 | [CODE_GUIDE.md](CODE_GUIDE.md) | **start here**: how the whole project works, file by file, from the PC to a pin (checked 2026-10-30) |
| 1 | [../README.md](../README.md) | what the chip is, current status, repository map, how to run the tests |
| 2 | [PROTOCOL_EMULATOR_ARCHITECTURE.md](PROTOCOL_EMULATOR_ARCHITECTURE.md) | architecture: engines, FIFOs, pin manager, management link |
| 3 | [../instructions.md](../instructions.md) | the instruction set (31 opcodes; the file may still describe the 28 of the first version, `src/isa.vh` is authoritative) and the firmware of every protocol |
| 4 | [TEST_RESULTS.md](TEST_RESULTS.md) | **all test and flow results in tables** |
| 4b | [PROGRESS_REPORT_2026-10-18_to_2026-10-20.md](PROGRESS_REPORT_2026-10-18_to_2026-10-20.md) | **detailed report of the last three days: flows, architecture changes, tests, logic analyser** |
| 5 | [EXECUTION_PLAN.md](EXECUTION_PLAN.md) | project plan and status |
| 6 | [CHALLENGE_CHECK.md](CHALLENGE_CHECK.md) | the challenge rules against what exists |
| 6b | [SHARED_IMEM_PLAN.md](SHARED_IMEM_PLAN.md), [SHARED_IMEM_SOFTWARE_PLAN.md](SHARED_IMEM_SOFTWARE_PLAN.md) | the shared 512-word instruction memory (current base of the chip): hardware plan and host software |
| 6c | [../memory.md](../memory.md) | the whole project story in date order, decisions, tests, key numbers, catalogue of every file |
| 7 | [HOST_INTERFACE.md](HOST_INTERFACE.md) | **every host-chip exchange**: SPI frame, STATUS, address map, flow control; Python host `host/chip_host.py` |

## Decisions and plans (why things are the way they are)

Note: `TEST_RESULTS.md`, `EXECUTION_PLAN.md` and `CHALLENGE_CHECK.md` carry the state of 2026-10-18 to 2026-10-20; the newest numbers are in `../results/regression_2026-10-30/summary.md`, `PROGRESS_REPORT_2026-10-18_to_2026-10-20.md`, `TODO.md` and `../memory.md`.

| File | Topic |
|---|---|
| [ALU_CRC_I2CSLAVE_PLAN.md](ALU_CRC_I2CSLAVE_PLAN.md) | ALU + CRC units, I2C slave, protocol suite, bounding-box experiment; section 13 lists where the plan changed |
| [ALU_CRC_RESULTS.md](ALU_CRC_RESULTS.md) | what came out of that plan, the flow problems that had to be solved, the final layout |
| [PIN_MAP_PLAN.md](PIN_MAP_PLAN.md) | plan (week 2): every pin except the management link remappable; spare-pin defaults (SAFE_N, IRQ, debug views); bring-up without SPI |
| [USB_LS_PLAN.md](USB_LS_PLAN.md) | USB low-speed device: line coder, packet-shuttle firmware, host software, verification, what changed from the first plan |
| [LINE_CODER.md](LINE_CODER.md) | the `LINE` opcode and RGET sources 6 and 7: transmitter, receiver, status word, verification |
| [DEBUG_LA_PLAN.md](DEBUG_LA_PLAN.md) | plan (weeks 5-7): logic analyser, protocol sniffer with protocol triggers, engine debug over SPI |
| [FETCH_STAGE.md](https://github.com/Rishadd/protocol_emulator/blob/exp/fetch-stage/docs/FETCH_STAGE.md) (on branch `exp/fetch-stage`) | experiment: instruction register with early branch resolution, verified, no timing gain, not merged |
| [USB_STANDALONE_PLAN.md](USB_STANDALONE_PLAN.md), [ETHERNET_FEASIBILITY.md](ETHERNET_FEASIBILITY.md), [PROTOCOL_CATALOGUE.md](PROTOCOL_CATALOGUE.md) | standalone USB device, 10BASE-T feasibility, which further protocols are possible |
| [CLOCK_SPEED_EFFECTS.md](CLOCK_SPEED_EFFECTS.md), [HANDOFF_LINUX.md](HANDOFF_LINUX.md) | what a slower clock changes; moving the work to Linux |
| [USER_GUIDE.md](USER_GUIDE.md) | user guide draft (HTML: `USER_GUIDE.html`) |
| [MGMT_PLAN.md](MGMT_PLAN.md) | the SPI management link (frame format, address map) |
| [SPI_PLAN.md](SPI_PLAN.md), [I2C_PLAN.md](I2C_PLAN.md) | SPI and I2C firmware design |
| [ASIC_AREA_AND_MEMORY_STUDY.md](ASIC_AREA_AND_MEMORY_STUDY.md) | area study: flop memory against SRAM macro |

## Results of earlier phases

| File | Topic |
|---|---|
| [SPI_RESULTS.md](SPI_RESULTS.md), [I2C_RESULTS.md](I2C_RESULTS.md), [WORKLOAD_RESULTS.md](WORKLOAD_RESULTS.md) | SPI, I2C and the all-protocol workload |
| [SRAM_INSTR_MEM_RESULTS.md](SRAM_INSTR_MEM_RESULTS.md), [BIGMEM_RESULTS.md](BIGMEM_RESULTS.md) | instruction memory in an SRAM macro, then 256 words |
| [LIBRELANE_RESULTS.md](LIBRELANE_RESULTS.md) | the first place-and-route run (plain LibreLane) |
| [TT_FLOW_RESULTS.md](TT_FLOW_RESULTS.md) | the Tiny Tapeout flow: template, power grid for the SRAM macros, precheck (design before the ALU / CRC units) |
| [WORKSTREAM1_ARCHITECTURE.md](WORKSTREAM1_ARCHITECTURE.md), [WORKSTREAM2_RTL_IMPLEMENTATION.md](WORKSTREAM2_RTL_IMPLEMENTATION.md) | the first design notes (historical) |

## Other

| File | Topic |
|---|---|
| [info.md](info.md) | datasheet text for the Tiny Tapeout project page |
| [diagram_full_chip.mmd](diagram_full_chip.mmd), [diagram_core_internal.mmd](diagram_core_internal.mmd) | Mermaid block diagrams |
