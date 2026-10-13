"""Instruction encoder / disassembler: the one host-side copy of src/isa.vh.

Word = opcode[31:27] | operand[26:0]. Program addresses are 9 bits (0x000-0x03F L1, 0x100-0x1FF L2).
JPH / JPL take the operand as (pin, addr): pin in [11:9], addr in [8:0].
COPY takes (src, dst, n): L2 word src..src+n-1 -> own L1 dst..dst+n-1, n = 1..64.
"""
OP = dict(NOP=0, WAIT=1, JMP=2, HALT=3, SETL=4, DJNZ=5, PULL=6, PUSH=7, OUT1=8, IN1=9,
          SETH=10, SETLO=11, DIRO=12, DIRI=13, WAITH=14, WAITL=15, CFG=16, JPH=17, JPL=18, JPO=19, PUSHI=20, COPY=21)
NAME = {v: k for k, v in OP.items()}


def enc(m, a=0):
    if m in ("JPH", "JPL"):
        pin, addr = a
        a = pin << 9 | addr
    elif m == "COPY":
        src, dst, n = a
        a = (n - 1) << 14 | dst << 8 | src
    return OP[m] << 27 | (a & 0x7FFFFFF)


def assemble(prog):
    """prog = [(mnemonic, operand), ...] -> list of words."""
    return [enc(m, a) for m, a in prog]


def disasm(w):
    name, a = NAME.get(w >> 27, "?"), w & 0x7FFFFFF
    if name == "COPY":
        return f"COPY {a & 255},{a >> 8 & 63},{(a >> 14 & 63) + 1}"
    return f"{name} {a >> 9},{a & 511}" if name in ("JPH", "JPL") else f"{name} {a}"


def write_hex(words, path):
    with open(path, "w") as f:
        f.write("".join(f"{w:08X}\n" for w in words))
