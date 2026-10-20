# Formal proofs (SymbiYosys)

Unbounded safety proofs (`abc pdr`) of the properties a wrong design could damage hardware or a bus with. Run in WSL with the
tools in LibreLane's Nix shell:

```
bash formal/run_formal_wsl.sh            # every proof: one PASS / FAIL line each
python3 formal/formal_mutants.py         # every proof must FAIL on each planted bug (a passing proof of a broken design proves nothing)
```

| Proof | Design under proof | Properties | Planted bugs caught |
|---|---|---|---|
| `pin_mgr.sby` | `pin_mgr` | only the owning engine reaches a pin, through its remap (uio and uo_out); an open-drain pad is never driven high; owner code 3 never appears; reset = nothing owned, identity input select, every default; an owned pin, an input select and the MISC control bits keep their value while the owner runs; the input select stays within the 13 pins and routes exactly that pin; HOLD releases every engine-driven pin and acts only when enabled; violations (a logical pin no owned pin carries) are flagged exactly; IRQ = OR of masked status, status sticky and cleared only by write-one-to-clear. Assumes the management contract (a register write only when the pin manager accepts it), proved by `mgmt.sby` | 18/18 |
| `fifo.sby` | `fifo` (depth 4, width 4; the FIFO only moves data) | equivalent to an ideal queue: no word lost, duplicated or reordered, full / empty / output always right, a write when full and a read when empty change nothing | 6/6 |
| `mgmt.sby` | `spi_slave` + `mgmt` + `pin_mgr` as on the chip; SPI pins and all engine signals free | M1 a pin configuration is applied only with the pin manager's consent (the contract above, even though the write is registered one clock after the check); M2 instruction memory is written only while that engine is held; M3 every state change (RUN, memory write, FIFO push / pop, any pin-manager register write) follows a clean frame of exactly 7 bytes; M4 HOLD stops both engines and RUN cannot be set while it is active | 7/7 |
| `engine.sby` | `engine_top` with all units; the SRAM replaced by `sram_free.v` (arbitrary word every clock) | E1 a held or reset engine drives no pin, in the same clock run falls | 3/3 |

Together: **a pad is only ever driven by a running engine that owns it, as configured by a complete management frame, and an
open-drain pad is never driven high**, for any SPI input and any program.

No SMT solver is installed (only the `abc` engines), so there are no cover traces yet.

## Shared instruction memory (branch shared/on-v2, built with SHARED_IMEM)

| Proof | Statement |
|---|---|
| `imem_shared.sby` (P1) | a running engine only decodes a word (not the TRAP substitute) that was fetched from an address inside the window in force in that clock |
| `imem_shared.sby` (P2) | no host write reaches the macro through a running engine's port, none lands inside a running engine's window, and with both engines running nothing is written |
| `imem_shared.sby` (P3) | while an engine runs with a locked window, the lock and the window are constant; a held engine's window is the whole memory and unlocked one clock later; the first OP_REGION of a run sets exactly the window it names and the lock |
| `region_go.sby` | the control unit passes an OP_REGION on (`rg_go`) only when the engine is not locked and the window is valid (base < limit <= 512): the assumption P3 uses |

The memory macro is replaced by `sram2p_free.v` (arbitrary read data), the environment is otherwise free (any run / fetch / host write sequence).
`imem_shared` exports the macro's write strobes and addresses (`m_wa m_wb m_aa m_ab`) for these properties: Yosys does not resolve hierarchical references into a submodule.
Run on Linux: `bash formal/run_formal_linux.sh` (sby, yosys, yices, boolector from the Nix profile); mutants: `python3 formal/formal_mutants.py imem_shared region_go`
(13 planted bugs, 13 caught). Total: 6 proofs.
