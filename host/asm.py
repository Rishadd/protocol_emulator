#!/usr/bin/env python3
"""Assembler for the protocol engine ISA (docs/ALU_CRC_I2CSLAVE_PLAN.md 3.1 and instructions.md section 1).

    a = Asm()
    a.CFG(out_pin=6, in_pin=6, osr_msb=1, isr_msb=1)
    a.label("loop")
    a.ALU("ADD", rd=0, imm=1)              # R0 += 1
    a.ALU("CMP", rd=0, imm=10)
    a.JCC("NZ", "loop")                    # branch targets may be labels (resolved in words())
    a.HALT()
    words = a.words()                       # placed through fw_layout (FW_ORG relocation)

Every mnemonic method appends one instruction; operands that are labels are resolved when words() is called. The generic encoders
(enc_*) return the 32-bit word directly and are used by the models and tests.
"""
import fw_layout

OPCODE = dict(NOP=0, WAIT=1, JMP=2, HALT=3, SETL=4, DJNZ=5, PULL=6, PUSH=7, OUT1=8, IN1=9, SETH=10, SETLO=11,
              DIRO=12, DIRI=13, WAITH=14, WAITL=15, CFG=16, JPH=17, JPL=18, JPO=19, PUSHI=20,
              LDI=21, ALU=22, JCC=23, RGET=24, RPUT=25, WAITR=26, CRC=27, LINE=28)
LAST_LEGAL = 28
FUNC = dict(MOV=0, ADD=1, SUB=2, AND=3, OR=4, XOR=5, SHL=6, SHR=7, CMP=8, TST=9, NOT=10, PAR=11, REV8=12)
COND = dict(Z=0, NZ=1, C=2, NC=3, N=4, NN=5, GTU=6, LEU=7)
RGET_SRC = dict(OSR=0, ISR=1, LC=2, PIN=3, CRC=4, TXF=5, LINE=6, FIFO=7)
RPUT_DST = dict(OSR=0, ISR=1, LC=2, RXF=3)
CRC_OP = dict(RST=0, POLY=1, INIT=2, XOR=3, FMT=4, BIT=5, BYTE=6)
LINE_OP = dict(CFG=0, PERIOD=1, TXB=2, TXE=3, RXCTL=4, RESET=5)
JUMP_OPS = ("JMP", "DJNZ", "JPH", "JPL", "JPO", "JCC")   # operand [7:0] is a program address

NAME = {v: k for k, v in OPCODE.items()}


def word(op, operand=0):
    return (OPCODE[op] << 27) | (operand & 0x7FFFFFF)


def enc_ldi(rd, imm):
    return word("LDI", (rd & 7) << 24 | (imm & 0xFFFFFF))


def enc_alu(func, rd, rs=0, imm=None):
    f = FUNC[func] if isinstance(func, str) else func
    use = 0 if imm is None else 1
    return word("ALU", f << 23 | (rd & 7) << 20 | (rs & 7) << 17 | use << 16 | ((imm or 0) & 0xFFFF))


def enc_jcc(cond, addr):
    c = COND[cond] if isinstance(cond, str) else cond
    return word("JCC", c << 8 | (addr & 0xFF))


def enc_rget(rd, src):
    s = RGET_SRC[src] if isinstance(src, str) else src
    return word("RGET", s << 4 | (rd & 7))


def enc_rput(dst, rs):
    d = RPUT_DST[dst] if isinstance(dst, str) else dst
    return word("RPUT", d << 4 | (rs & 7))


def enc_crc(cop, rs=0):
    c = CRC_OP[cop] if isinstance(cop, str) else cop
    return word("CRC", c << 24 | (rs & 7))


def enc_line(lop, rs=0):
    l = LINE_OP[lop] if isinstance(lop, str) else lop
    return word("LINE", l << 24 | (rs & 7))


class Asm:
    def __init__(self):
        self.items = []          # (op, operand) where operand may hold a label name in the jump address
        self.labels = {}

    def label(self, name):
        assert name not in self.labels, f"duplicate label {name}"
        self.labels[name] = len(self.items)
        return len(self.items)

    @property
    def pc(self):
        return len(self.items)

    def _add(self, op, operand=0, target=None, hi=0):
        self.items.append((op, operand, target, hi))
        return self

    # --- original instructions
    def NOP(self): return self._add("NOP")
    def WAIT(self, d): return self._add("WAIT", d)
    def WAITR(self, rs): return self._add("WAITR", rs & 7)
    def JMP(self, t): return self._add("JMP", target=t)
    def HALT(self): return self._add("HALT")
    def SETL(self, n): return self._add("SETL", n)
    def DJNZ(self, t): return self._add("DJNZ", target=t)
    def PULL(self): return self._add("PULL")
    def PUSH(self): return self._add("PUSH")
    def OUT1(self, d=0): return self._add("OUT1", d)
    def IN1(self, d=0): return self._add("IN1", d)
    def SETH(self, p): return self._add("SETH", p)
    def SETLO(self, p): return self._add("SETLO", p)
    def DIRO(self, p): return self._add("DIRO", p)
    def DIRI(self, p): return self._add("DIRI", p)
    def WAITH(self, p): return self._add("WAITH", p)
    def WAITL(self, p): return self._add("WAITL", p)
    def CFG(self, out_pin=0, in_pin=0, osr_msb=0, isr_msb=0):
        return self._add("CFG", out_pin | in_pin << 3 | osr_msb << 6 | isr_msb << 7)
    def JPH(self, p, t): return self._add("JPH", target=t, hi=p << 8)
    def JPL(self, p, t): return self._add("JPL", target=t, hi=p << 8)
    def JPO(self, t): return self._add("JPO", target=t)
    def PUSHI(self, v): return self._add("PUSHI", v)

    # --- register / ALU / CRC extension
    def LDI(self, rd, imm): return self._add("LDI", (rd & 7) << 24 | (imm & 0xFFFFFF))
    def ALU(self, func, rd, rs=0, imm=None):
        f = FUNC[func] if isinstance(func, str) else func
        use = 0 if imm is None else 1
        return self._add("ALU", f << 23 | (rd & 7) << 20 | (rs & 7) << 17 | use << 16 | ((imm or 0) & 0xFFFF))
    def JCC(self, cond, t):
        c = COND[cond] if isinstance(cond, str) else cond
        return self._add("JCC", target=t, hi=c << 8)
    def RGET(self, rd, src):
        s = RGET_SRC[src] if isinstance(src, str) else src
        return self._add("RGET", s << 4 | (rd & 7))
    def RPUT(self, dst, rs):
        d = RPUT_DST[dst] if isinstance(dst, str) else dst
        return self._add("RPUT", d << 4 | (rs & 7))
    def CRC(self, cop, rs=0):
        c = CRC_OP[cop] if isinstance(cop, str) else cop
        return self._add("CRC", c << 24 | (rs & 7))
    def LINE(self, lop, rs=0):
        l = LINE_OP[lop] if isinstance(lop, str) else lop
        return self._add("LINE", l << 24 | (rs & 7))

    # --- convenience: a long constant in a register
    def SET32(self, rd, value, tmp=7):
        """R[rd] <- 32-bit constant using LDI (24 bits) + shifts, clobbers flags; tmp must differ from rd."""
        value &= 0xFFFFFFFF
        if value < (1 << 24):
            return self.LDI(rd, value)
        self.LDI(rd, value >> 8)
        self.ALU("SHL", rd, imm=8)
        return self.ALU("OR", rd, imm=value & 0xFF)

    def raw(self):
        """Resolved (op, operand) list."""
        out = []
        for op, operand, target, hi in self.items:
            if target is not None:
                addr = self.labels[target] if isinstance(target, str) else target
                operand = hi | (addr & 0xFF)
            out.append((op, operand))
        return out

    def words(self):
        ws = [word(op, operand) for op, operand in self.raw()]
        assert len(ws) <= 256, f"program has {len(ws)} words (memory holds 256)"
        return fw_layout.place(ws)

    def words_unplaced(self):
        return [word(op, operand) for op, operand in self.raw()]

    def arrivals(self, start, limit=4000):
        """Static cycle analysis of the straight-line / branching code reachable from label `start`: returns {pc: {cycles}} where
        cycles is the number of clocks between the first cycle of the instruction at `start` and the first cycle of the instruction at pc,
        along every path. Timing rules of instructions.md: WAIT/OUT1/IN1 d take d+1 clocks, every other instruction 1 clock (taken and
        not-taken branches alike; RGET TXF counts as 1 clock, i.e. it assumes a word is waiting; RGET CRC executed directly after a CRC
        instruction takes 2 clocks). The walk stops at WAITR / HALT / PULL / PUSH / WAITH / WAITL (data dependent time) and
        never revisits a (pc, cycle) pair."""
        raw = self.raw()
        arr, seen = {}, set()
        # state: (pc, cycle, previous instruction was CRC)
        stack = [(self.labels[start] if isinstance(start, str) else start, 0, False)]
        while stack:
            pc, t, after_crc = stack.pop()
            if pc >= len(raw) or t > limit or (pc, t, after_crc) in seen:
                continue
            seen.add((pc, t, after_crc))
            arr.setdefault(pc, set()).add(t)
            op, operand = raw[pc]
            if op in ("WAITR", "HALT", "PULL", "PUSH", "WAITH", "WAITL"):
                continue
            n = (operand & 0x7FFFFFF) + 1 if op in ("WAIT", "OUT1", "IN1") else 1
            if op == "RGET" and (operand >> 4 & 7) == RGET_SRC["CRC"] and after_crc:
                n = 2
            crc = op == "CRC"
            if op == "JMP":
                stack.append((operand & 0xFF, t + 1, crc))
            elif op in ("JCC", "JPH", "JPL", "JPO", "DJNZ"):
                stack.append((operand & 0xFF, t + 1, crc))
                stack.append((pc + 1, t + 1, crc))
            else:
                stack.append((pc + 1, t + n, crc))
        return arr

    def crc_read_waits(self):
        """Program addresses of RGET CRC instructions placed directly after a CRC instruction (they take 2 clocks instead of 1)."""
        raw = self.raw()
        return [pc for pc in range(1, len(raw))
                if raw[pc][0] == "RGET" and (raw[pc][1] >> 4 & 7) == RGET_SRC["CRC"] and raw[pc - 1][0] == "CRC"]


def disasm(w):
    op = NAME.get(w >> 27, "?%d" % (w >> 27))
    a = w & 0x7FFFFFF
    if op in ("JPH", "JPL"):
        return f"{op} pin{(a >> 8) & 7},{a & 255}"
    if op == "JCC":
        return f"JCC {({v: k for k, v in COND.items()}[(a >> 8) & 7])},{a & 255}"
    if op == "ALU":
        f = {v: k for k, v in FUNC.items()}.get(a >> 23, "f%d" % (a >> 23))
        src = f"#{a & 0xFFFF}" if a >> 16 & 1 else f"r{(a >> 17) & 7}"
        return f"ALU {f} r{(a >> 20) & 7},{src}"
    if op == "LDI":
        return f"LDI r{(a >> 24) & 7},#{a & 0xFFFFFF:#x}"
    if op == "RGET":
        return f"RGET r{a & 7},{({v: k for k, v in RGET_SRC.items()}.get((a >> 4) & 7, '?'))}"
    if op == "RPUT":
        return f"RPUT {({v: k for k, v in RPUT_DST.items()}.get((a >> 4) & 7, '?'))},r{a & 7}"
    if op == "CRC":
        return f"CRC {({v: k for k, v in CRC_OP.items()}.get((a >> 24) & 7, '?'))},r{a & 7}"
    if op == "WAITR":
        return f"WAITR r{a & 7}"
    return f"{op} {a}"
