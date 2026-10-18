# Formal proofs (SymbiYosys)

Unbounded safety proofs (`abc pdr`) of the properties a wrong design could damage hardware or a bus with. Run in WSL with the
tools in LibreLane's Nix shell:

```
bash formal/run_formal_wsl.sh            # every proof: one PASS / FAIL line each
python3 formal/formal_mutants.py         # every proof must FAIL on each planted bug (a passing proof of a broken design proves nothing)
```

| Proof | Design under proof | Properties | Planted bugs caught |
|---|---|---|---|
| `pin_mgr.sby` | `pin_mgr` | only the owning engine's enable and data reach a pad; an open-drain pad is never driven high; owner code 3 never appears; reset owns nothing; a pad owned by a running engine keeps owner and mode; a running engine enabling a pad it does not own is flagged in the next clock and flags appear for no other reason. Assumes the management contract (a configuration write only when the pin manager accepts it), proved by `mgmt.sby` | 6/6 |
| `fifo.sby` | `fifo` (depth 4, width 4; the FIFO only moves data) | equivalent to an ideal queue: no word lost, duplicated or reordered, full / empty / output always right, a write when full and a read when empty change nothing | 6/6 |
| `mgmt.sby` | `spi_slave` + `mgmt` + `pin_mgr` as on the chip; SPI pins and all engine signals free | M1 a pin configuration is applied only with the pin manager's consent (the contract above, even though the write is registered one clock after the check); M2 instruction memory is written only while that engine is held; M3 every state change (RUN, memory write, FIFO push / pop, pin configuration, violation clear) follows a clean frame of exactly 7 bytes | 5/5 |
| `engine.sby` | `engine_top` with all units; the SRAM replaced by `sram_free.v` (arbitrary word every clock) | E1 a held or reset engine drives no pin, in the same clock run falls | 3/3 |

Together: **a pad is only ever driven by a running engine that owns it, as configured by a complete management frame, and an
open-drain pad is never driven high**, for any SPI input and any program.

No SMT solver is installed (only the `abc` engines), so there are no cover traces yet.
