# Kept results, one folder per phase

Only evidence that a document refers to is kept; temporary and per-run scratch output was deleted. All numbers in one place: [../docs/TEST_RESULTS.md](../docs/TEST_RESULTS.md).

| Folder | What it is | Described in |
|---|---|---|
| `regression_2026-10-18/` | **final regression**: `summary.md` (26 of 26 suites pass) and one log per suite | [TEST_RESULTS.md](../docs/TEST_RESULTS.md) |
| `tt_flow_2026-10-18/` | Tiny Tapeout flow with the ALU / CRC units: the final flat and engine-box runs (metrics, reports, images) and `explore/` (the exploration runs that led to the settings: synthesis strategy, adder, clock, floorplans) | [ALU_CRC_RESULTS.md](../docs/ALU_CRC_RESULTS.md), `explore/README.md` |
| `tt_flow_2026-10-17/` | the design **before** the ALU / CRC units: `tt2` (first run, fails the precheck), `tt5` (accepted run: precheck, LVS, gate-level) and the stage-by-stage images | [TT_FLOW_RESULTS.md](../docs/TT_FLOW_RESULTS.md) |
| `librelane_2026-10-17/` | the first place-and-route run with plain LibreLane | [LIBRELANE_RESULTS.md](../docs/LIBRELANE_RESULTS.md) |
| `bigmem_2026-10-17/` | regression with the 256-word instruction memory | [BIGMEM_RESULTS.md](../docs/BIGMEM_RESULTS.md) |
| `spi_2026-10-11/`, `i2c_2026-10-11/` | full SPI and I2C test runs | [SPI_RESULTS.md](../docs/SPI_RESULTS.md), [I2C_RESULTS.md](../docs/I2C_RESULTS.md) |
| `workload_2026-10-12/`, `uart_workload_2026-10-01/` | UART and all-protocol workload runs | [WORKLOAD_RESULTS.md](../docs/WORKLOAD_RESULTS.md) |
