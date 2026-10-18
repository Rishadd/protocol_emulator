"""Where a firmware image sits in the 256-word instruction memory.

Every generator builds its program at word 0 (jump targets 0..N). Setting the environment variable
FW_ORG=<n> makes the generators (spi_prog.assemble, uart_workload.uart_tx_program,
uart_rx_prog.uart_rx_program output) relocate the program to word n instead: word 0 becomes `JMP n`,
every JMP/DJNZ/JPH/JPL/JPO target gets +n, the rest of the memory is HALT. Used to run every protocol
test with the firmware at the top of the 256-word memory (FW_ORG=192), so the 8-bit PC, the 8-bit jump
targets and the whole address range of the macro are exercised by real protocol traffic.
"""
import os

MEM_WORDS = 256
OP_JMP, OP_HALT, OP_DJNZ, OP_JPH, OP_JPL, OP_JPO, OP_JCC = 2, 3, 5, 17, 18, 19, 23
JUMPS = (OP_JMP, OP_DJNZ, OP_JPH, OP_JPL, OP_JPO, OP_JCC)      # operand [7:0] is a program address
HALT_WORD = OP_HALT << 27


def org():
    return int(os.environ.get("FW_ORG", "0"))


def relocate(words, origin):
    """Encoded words -> 256-word image with the program at `origin` and `JMP origin` at word 0."""
    words = list(words)
    while words and words[-1] == HALT_WORD:             # drop padding, it is rebuilt below
        words.pop()
    assert origin + len(words) <= MEM_WORDS, f"{len(words)} words do not fit at {origin}"
    out = [HALT_WORD] * MEM_WORDS
    out[0] = OP_JMP << 27 | origin
    for i, w in enumerate(words):
        if w >> 27 in JUMPS:
            a = (w & 0xFF) + origin
            assert a < MEM_WORDS, "relocated jump target outside the memory"
            w = (w & ~0xFF) | a
        out[origin + i] = w
    return out


def place(words):
    """Apply FW_ORG (if set) to an encoded program."""
    o = org()
    return relocate(words, o) if o else list(words)
