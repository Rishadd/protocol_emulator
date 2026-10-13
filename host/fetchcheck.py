"""Static fetch checker for two-tier programs (docs/TWO_TIER_MEMORY_PLAN.md step 7.2, oracle I9).

For every L2 instruction it looks at the ways into it:
  * sequential, after an instruction that holds >= H_PF clocks (WAIT/OUT1/IN1 with d+1 >= H_PF): covered,
    the prefetch buffer has the word in time (T8, H_PF measured in Phase 4)
  * sequential after a one-clock or blocking instruction, any jump, or the reset vector: an urgent
    fetch, which may wait 1 clock per competing request (+1 per host access) under round-robin (T9)
check() returns {L2 address: number of uncovered ways in}. hot(): refuses hot L2 words with any.
"""
import isa

H_PF = 4                                           # clocks of hold that hide the next fetch (Phase 4)
TIMED = {isa.OP["WAIT"], isa.OP["OUT1"], isa.OP["IN1"]}
JUMPS = {isa.OP["JMP"], isa.OP["DJNZ"], isa.OP["JPH"], isa.OP["JPL"], isa.OP["JPO"]}
NO_FALL = {isa.OP["JMP"], isa.OP["HALT"]}


def words(prog):
    """{9-bit address: word} of a linked program."""
    w = {a: x for a, x in enumerate(prog["l1"])}
    w.update({0x100 | a: x for a, x in prog["l2"].items()})
    return w


def check(prog, entry=None):
    w = words(prog)
    ways = {a: 0 for a in w if a >= 0x100}
    for a, x in w.items():
        op, v = x >> 27, x & 0x7FFFFFF
        if op in JUMPS and (v & 0x1FF) in ways:
            ways[v & 0x1FF] += 1                    # a jump into L2: urgent
        nxt = (a + 1) & 0x1FF
        if nxt in ways and op not in NO_FALL:
            held = op in TIMED and (v & 0x7FFFFFF) + 1 >= H_PF
            ways[nxt] += 0 if held else 1           # falls through without enough hold: urgent
    if entry is not None and entry in ways:
        ways[entry] += 1                            # first fetch after RUN
    return ways


def hot(prog, labels):
    """Refuse (AssertionError) if a word in a hot range [start label, end label) is not covered."""
    ways = check(prog)
    for start, end in labels:
        for a in range(prog["sym"][start], prog["sym"][end]):
            assert a < 0x100 or ways.get(a, 0) == 0, f"hot word {a:#05x} in L2 has an urgent way in"
    return ways
