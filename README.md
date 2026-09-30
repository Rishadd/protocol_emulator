# Protocol Emulator

Programmable, PIO-style protocol engine: a tiny instruction set drives shift
registers, FIFOs and 8 GPIO pins so any bit-banged serial protocol (UART, SPI,
I2C, JTAG, ...) is firmware, not RTL.

| Path | Contents |
|---|---|
| `src/` | Synthesizable RTL. `engine_top.v` is the top; `isa.vh` is the opcode table. |
| `tb/` | Self-checking Icarus testbenches (7 unit + `tb_engine_top` + `tb_uart_workload`). |
| `host/` | `uart_workload.py` — Python host model / reference decoder that drives the Verilog engine with 1 KB payloads across baud rates. |
| `docs/` | Architecture, execution plan, workstream plans, Mermaid diagrams (pre-RTL planning). |
| `results/` | Kept evidence from workload runs (logs + payload). |
| `instructions.md` | **ISA reference and per-protocol programs** — the contract for the host loader. |
| `run_tests.ps1` | Compiles and runs every testbench; prints one `RESULT` line each. |
| `build/` | Generated (ignored). |

## Run

```powershell
.\run_tests.ps1                                   # full regression
python host\uart_workload.py --bauds 9600 115200  # workload sweep, add --limits for stress tests
```

Requires Icarus Verilog (`iverilog`/`vvp`, tested with 12.0) and Python 3.
