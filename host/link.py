"""Linker for two-tier programs (docs/TWO_TIER_MEMORY_PLAN.md step 7.1).

A program is a list of items:
  (".l1",) / (".l2",)       place what follows in the engine's own L1 / in L2 (absolute, from l2_base)
  ("lab", name)             a label at the current place
  (mnemonic, operand)       an instruction; jump targets may be label names: JMP/DJNZ/JPO "x",
                            JPH/JPL (pin, "x"), COPY ("x", dst, n) with x an L2 label
link() returns dict(l1=[64 words, HALT padded], l2={L2 word index: word}, sym={name: 9-bit address},
lo=, hi= the L2 words used) and refuses programs that do not fit.
"""
import isa

HALT = isa.enc("HALT")


def link(items, l2_base=0):
    sec, at, sym, placed = ".l1", {".l1": 0, ".l2": 0x100 + l2_base}, {}, []
    for it in items:                                   # pass 1: addresses
        if it[0] in (".l1", ".l2"):
            sec = it[0]
        elif it[0] == "lab":
            assert it[1] not in sym, f"label {it[1]} defined twice"
            sym[it[1]] = at[sec]
        else:
            placed.append((at[sec], it))
            at[sec] += 1
    assert at[".l1"] <= 64, f"L1 overflow: {at['.l1']} words"
    assert at[".l2"] <= 0x200, f"L2 overflow: {at['.l2'] - 0x100} words"
    r = lambda x: sym[x] if isinstance(x, str) else x
    l1, l2 = [HALT] * 64, {}
    for a, (m, op) in placed:                          # pass 2: encode
        if m in ("JMP", "DJNZ", "JPO"):
            op = r(op)
        elif m in ("JPH", "JPL"):
            op = (op[0], r(op[1]))
        elif m == "COPY":
            op = (r(op[0]) & 0xFF, op[1], op[2])
        w = isa.enc(m, op)
        if a < 0x100:
            l1[a] = w
        else:
            l2[a & 0xFF] = w
    used = sorted(l2)
    return dict(l1=l1, l2=l2, sym=sym, lo=used[0] if used else 0xFF, hi=used[-1] if used else 0x00)
