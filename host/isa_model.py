#!/usr/bin/env python3
"""Cycle-accurate model of one protocol engine, written from the instruction table (instructions.md section 1 and
docs/ALU_CRC_I2CSLAVE_PLAN.md 3.1), not from the RTL: every instruction is executed as a whole with its documented effect and
cycle count. Used for differential testing against src/engine_top.v (host/isa_diff_test.py) and as the golden model for firmware.
CRC instructions are executed by the CRC unit one clock after the instruction (in order); RGET CRC directly after a CRC instruction
waits one clock (instructions.md, CRC timing).

    eng = Engine(program_words)                     # 256-word program, run=1 from the first step
    snap = eng.step(pin_in=0x00, tx_wr=None, rx_rd=False)
        # one clock edge: pin_in is sampled into the 2-stage synchronizer, tx_wr = a 32-bit word pushed by the host (dropped
        # if the FIFO is full), rx_rd pops the RX FIFO if it is not empty; returns the state AFTER the edge

Observable state (snapshot(), also the trace format of tb/tb_isa_diff.v): pc, pin_out, pin_oe, halted, fault, tx_full, rx_empty,
RX head, OSR, ISR, loop counter, CRC value, flags Z N C, R0..R7.
"""
import collections

import asm as A
import crc_model as cm
from line_model import LineCoder

MASK32 = 0xFFFFFFFF
FIFO_DEPTH = 4


class CrcUnit:
    """Register-level CRC unit (reset configuration CRC-32 ISO-HDLC); the arithmetic itself is the Rocksoft model."""

    def __init__(self):
        self.reset()

    def reset(self):
        self.poly, self.init, self.xorout = 0x04C11DB7, 0xFFFFFFFF, 0xFFFFFFFF
        self.wm1, self.refin, self.refout = 31, 1, 1
        self.reg = 0xFFFFFFFF

    @property
    def mask(self):
        return MASK32 if self.wm1 == 31 else (1 << (self.wm1 + 1)) - 1

    def rst(self):
        self.reg = self.init & self.mask

    def _bit(self, b):
        c = cm.CRC(self.wm1 + 1, self.poly & self.mask)
        c.reg = self.reg & self.mask
        c.feed_bit(b)
        self.reg = c.reg

    def feed_byte(self, v):
        order = range(8) if self.refin else range(7, -1, -1)
        for i in order:
            self._bit(v >> i & 1)

    def value(self):
        w = self.wm1 + 1
        r = cm.reflect(self.reg & self.mask, w) if self.refout else self.reg & self.mask
        return (r ^ self.xorout) & self.mask


TRAP_WORD = 31 << 27            # opcode 31: illegal, faults the engine (what imem_shared.v returns outside a window)
TSTAMP_OP = 30                  # TSTAMP rd: R[rd] <= the free-running clock counter (the cycle number, 0 at the first clock of the model)
REGION_OP = 29                  # OP_REGION (SHARED_IMEM only): [8:0] base, [18:9] limit, once per run


class SharedImem:
    """The 512-word memory both engines fetch from in shared mode (src/imem_shared.v). Physical addresses."""
    SIZE = 512

    def __init__(self):
        self.mem = [A.word("HALT")] * self.SIZE

    def load(self, origin, words):
        assert origin >= 0 and origin + len(words) <= self.SIZE, "image does not fit the memory"
        self.mem[origin:origin + len(words)] = list(words)


class Engine:
    def __init__(self, program, shared=None, start=0):
        """shared=None: the private 256-word memory (default build). shared=SharedImem(): the program is already in the
        shared memory (program must be empty); the engine fetches through its window, see OP_REGION. start: the physical
        address the program counter takes at reset (host START register, shared mode; 0 for the default build)."""
        self.shared = shared
        self.start = start
        self.pcmask = 0x1FF if shared is not None else 0xFF
        if shared is None:
            self.mem = list(program) + [A.word("HALT")] * (256 - len(program))
        else:
            assert not program, "shared mode: load the program into the SharedImem, not the engine"
            self.mem = shared.mem
        self.tx, self.rx = [], []
        self.sync0 = self.sync1 = 0
        self.cycle = 0                         # clocks executed since construction: the value TSTAMP reads
        self.trig = 0                          # trigger line (RPUT TRIG)
        self.cov = collections.Counter()       # what was executed (for coverage reports), not part of the architecture
        self.core_reset()

    def jt(self, operand):
        """Jump target: operand [7:0], plus bit 8 from operand bit 11 in shared mode (src/control_unit.v jump_addr)."""
        return (operand & 0xFF) | ((((operand >> 11) & 1) << 8) if self.shared is not None else 0)

    def in_window(self):
        return self.shared is None or self.win[0] <= self.pc < self.win[1]

    def core_reset(self):
        self.pc, self.hold, self.halted, self.fault = self.start, False, False, False
        self.trig = 0
        self.win, self.locked = (0, SharedImem.SIZE), False      # shared mode: the whole memory until OP_REGION (src/imem_shared.v)
        self.dc, self.lc = 0, 0
        self.osr, self.isr = 0, 0
        self.cfg_out = self.cfg_in = 0
        self.osr_msb = self.isr_msb = 0
        self.pin_out = self.pin_oe = 0
        self.sync0 = self.sync1 = 0
        self.r = [0] * 8
        self.z = self.n = self.c = 0
        self.crc = CrcUnit()
        self.crc_cmd = None            # (cop, R[rs]) issued last clock: the CRC unit executes it at this clock's edge
        if hasattr(self, "line"):
            self.line.reset()
        else:
            self.line = LineCoder()    # line coder (src/line_coder.v)

    # ---- shift register helpers
    def osr_bit(self):
        return (self.osr >> 31 & 1) if self.osr_msb else (self.osr & 1)

    def osr_shift(self):
        self.osr = ((self.osr << 1) & MASK32) if self.osr_msb else (self.osr >> 1)

    def isr_shift_in(self, bit):
        self.isr = (((self.isr << 1) & MASK32) | bit) if self.isr_msb else ((self.isr >> 1) | bit << 31)

    # ---- ALU
    def alu(self, func, a, src):
        z_n_c = None
        c = self.c
        res, write = 0, True
        sh = src & 31
        if func == 0:
            res = src
        elif func == 1:
            t = a + src
            res, c = t & MASK32, t >> 32 & 1
        elif func in (2, 8):
            res, c = (a - src) & MASK32, int(a >= src)
            write = func == 2
        elif func == 3:
            res = a & src
        elif func == 4:
            res = a | src
        elif func == 5:
            res = a ^ src
        elif func == 6:
            res = (a << sh) & MASK32
            if sh:
                c = a >> (32 - sh) & 1
        elif func == 7:
            res = a >> sh
            if sh:
                c = a >> (sh - 1) & 1
        elif func == 9:
            res, write = a & src, False
        elif func == 10:
            res = ~src & MASK32
        elif func == 11:
            res = bin(src).count("1") & 1
        elif func == 12:
            res = int(f"{src & 0xFF:08b}"[::-1], 2)
        return res, write, c

    def legal(self, op, operand):
        if op == REGION_OP:
            base, limit = operand & 0x1FF, operand >> 9 & 0x3FF
            return self.shared is not None and not self.locked and base < limit <= SharedImem.SIZE
        if op > A.LAST_LEGAL and op != TSTAMP_OP:
            return False
        if op == A.OPCODE["ALU"] and operand >> 23 > 12:
            return False
        if op == A.OPCODE["RPUT"] and (operand >> 4 & 7) > 4:
            return False
        if op == A.OPCODE["CRC"] and (operand >> 24 & 7) > 6:
            return False
        if op == A.OPCODE["LINE"] and (operand >> 24 & 7) > 5:
            return False
        return True

    def cond(self, c):
        z, n, cf = self.z, self.n, self.c
        return [z, not z, cf, not cf, n, not n, cf and not z, (not cf) or z][c]

    def crc_exec(self, cop, rs):
        if cop == 0:
            self.crc.rst()
        elif cop == 1:
            self.crc.poly = rs
        elif cop == 2:
            self.crc.init = rs
        elif cop == 3:
            self.crc.xorout = rs
        elif cop == 4:
            self.crc.wm1, self.crc.refin, self.crc.refout = rs & 31, rs >> 5 & 1, rs >> 6 & 1
            self.crc.reg &= self.crc.mask             # the register is cut to the new width (and does not grow back)
        elif cop == 5:
            self.crc._bit(rs & 1)
        else:
            self.crc.feed_byte(rs & 0xFF)

    # ---- one clock edge
    def step(self, pin_in=0, tx_wr=None, rx_rd=False):
        sync1 = self.sync1            # what the engine sees this cycle (pre-edge)
        tx_empty, rx_full = not self.tx, len(self.rx) >= FIFO_DEPTH
        tx_head = self.tx[0] if self.tx else 0
        push_rx = None                 # value pushed into the RX FIFO at this edge
        new_crc_cmd = None             # CRC command issued at this edge
        line_cmd = (0, 0, 0)           # (go, op, R[rs]) for the line coder at this edge
        line_pop = False
        ldp = sync1 >> self.line.dp_pin & 1      # the pins the line coder watches (pre-edge, like the RTL)
        ldm = sync1 >> self.line.dm_pin & 1
        pop_tx = False
        dc_load = None
        pc_next = None                 # None = hold
        instr = self.mem[self.pc] if self.in_window() else TRAP_WORD
        op, operand = instr >> 27, instr & 0x7FFFFFF
        rs = self.r[operand & 7]
        dc_last = self.dc == 1

        if not self.halted:
            if self.hold:
                if dc_last:
                    self.hold = False
                    pc_next = (self.pc + 1) & self.pcmask
            elif not self.legal(op, operand):
                self.halted = self.fault = True
                self.cov[("trap", op if op > A.LAST_LEGAL else A.NAME[op])] += 1
            elif op == A.OPCODE["HALT"]:
                self.halted = True
                self.cov[("op", "HALT")] += 1
            else:
                name = "REGION" if op == REGION_OP else "TSTAMP" if op == TSTAMP_OP else A.NAME[op]
                stall = {
                    "PULL": tx_empty,
                    "PUSH": rx_full, "PUSHI": rx_full,
                    "WAITH": not (sync1 >> (operand & 7) & 1),
                    "WAITL": bool(sync1 >> (operand & 7) & 1),
                }.get(name, False)
                if name == "RGET" and operand >> 4 & 7 == 5:
                    stall = tx_empty
                if name == "RPUT" and operand >> 4 & 7 == 3:
                    stall = rx_full
                if name == "RGET" and operand >> 4 & 7 == 6 and self.line.busy():
                    stall = True               # RGET LINE directly after a LINE instruction waits one clock
                    self.cov[("rget_line_wait",)] += 1
                if name == "LINE" and operand >> 24 & 7 in (2, 3) and self.line.full():
                    stall = True               # TXB / TXE wait while the 2-entry transmit queue is full
                    self.cov[("line_full_wait",)] += 1
                if name == "RGET" and operand >> 4 & 7 == 4 and self.crc_cmd is not None:
                    stall = True               # RGET CRC directly after a CRC instruction waits one clock for the command to execute
                    self.cov[("rget_crc_wait",)] += 1
                if not stall:
                    adv = True
                    self.cov[("op", name)] += 1
                    if name == "ALU":
                        self.cov[("alu", operand >> 23)] += 1
                    elif name == "RGET":
                        self.cov[("rget", operand >> 4 & 7)] += 1
                    elif name == "RPUT":
                        self.cov[("rput", operand >> 4 & 7)] += 1
                    elif name == "CRC":
                        self.cov[("crc", operand >> 24 & 7)] += 1
                    elif name == "LINE":
                        self.cov[("line", operand >> 24 & 7)] += 1
                    elif name == "JCC":
                        self.cov[("jcc", operand >> 8 & 7, int(bool(self.cond(operand >> 8 & 7))))] += 1
                    if name == "WAIT":
                        dc_load = operand
                        adv = operand == 0
                        self.hold = operand != 0
                    elif name == "WAITR":
                        dc_load = rs & 0x7FFFFFF
                        adv = (rs & 0x7FFFFFF) == 0
                        self.hold = not adv
                    elif name in ("OUT1", "IN1"):
                        if name == "OUT1":
                            b = self.osr_bit()
                            self.pin_out = (self.pin_out & ~(1 << self.cfg_out)) | b << self.cfg_out
                            self.osr_shift()
                        else:
                            self.isr_shift_in(sync1 >> self.cfg_in & 1)
                        dc_load = operand
                        adv = operand == 0
                        self.hold = operand != 0
                    elif name == "REGION":
                        self.win = (operand & 0x1FF, operand >> 9 & 0x3FF)
                        self.locked = True
                    elif name == "JMP":
                        pc_next, adv = self.jt(operand), False
                    elif name == "SETL":
                        self.lc = operand & 0xFFFF
                    elif name == "DJNZ":
                        if self.lc > 1:
                            pc_next, adv = self.jt(operand), False
                        self.lc = max(self.lc - 1, 0)
                    elif name == "PULL":
                        pop_tx = True
                        self.osr = tx_head
                    elif name == "PUSH":
                        push_rx = self.isr
                        self.isr = 0
                    elif name == "PUSHI":
                        push_rx = operand
                    elif name == "SETH" or name == "SETLO":
                        p = operand & 7
                        self.pin_out = (self.pin_out & ~(1 << p)) | (name == "SETH") << p
                    elif name == "DIRO" or name == "DIRI":
                        p = operand & 7
                        self.pin_oe = (self.pin_oe & ~(1 << p)) | (name == "DIRO") << p
                    elif name == "CFG":
                        self.cfg_out, self.cfg_in = operand & 7, operand >> 3 & 7
                        self.osr_msb, self.isr_msb = operand >> 6 & 1, operand >> 7 & 1
                    elif name in ("JPH", "JPL"):
                        lvl = sync1 >> (operand >> 8 & 7) & 1
                        if lvl == (name == "JPH"):
                            pc_next, adv = self.jt(operand), False
                    elif name == "JPO":
                        b = self.osr_bit()
                        self.osr_shift()
                        if b:
                            pc_next, adv = self.jt(operand), False
                    elif name == "LDI":
                        self.r[operand >> 24 & 7] = operand & 0xFFFFFF
                    elif name == "ALU":
                        f, rd = operand >> 23, operand >> 20 & 7
                        src = (operand & 0xFFFF) if operand >> 16 & 1 else self.r[operand >> 17 & 7]
                        res, write, c = self.alu(f, self.r[rd], src)
                        if write:
                            self.r[rd] = res
                        self.z, self.n, self.c = int(res == 0), res >> 31 & 1, c
                    elif name == "JCC":
                        if self.cond(operand >> 8 & 7):
                            pc_next, adv = self.jt(operand), False
                    elif name == "RGET":
                        src = operand >> 4 & 7
                        val = [self.osr, self.isr, self.lc, sync1, self.crc.value(), tx_head, self.line.status(ldp, ldm),
                               len(self.rx) << 3 | len(self.tx)][src]
                        if src == 5:
                            pop_tx = True
                        if src == 6:
                            line_pop = True
                        self.r[operand & 7] = val & MASK32
                    elif name == "TSTAMP":
                        self.r[operand & 7] = self.cycle & MASK32
                    elif name == "RPUT":
                        dst = operand >> 4 & 7
                        if dst == 4:
                            self.trig = rs & 1
                        elif dst == 0:
                            self.osr = rs
                        elif dst == 1:
                            self.isr = rs
                        elif dst == 2:
                            self.lc = rs & 0xFFFF
                        else:
                            push_rx = rs
                    elif name == "CRC":
                        new_crc_cmd = (operand >> 24 & 7, rs)  # executed by the CRC unit one clock later
                    elif name == "LINE":
                        line_cmd = (1, operand >> 24 & 7, rs)   # applied by the line coder one clock later
                    if adv:
                        pc_next = (self.pc + 1) & self.pcmask
        # CRC unit: executes the command issued in the previous clock (in order, one per clock), then takes this clock's command
        if self.crc_cmd is not None:
            self.crc_exec(*self.crc_cmd)
        self.crc_cmd = new_crc_cmd
        self.line.step(line_cmd[0], line_cmd[1], line_cmd[2], line_pop, ldp, ldm)
        # counters that run on their own
        if dc_load is not None:
            self.dc = dc_load
        elif self.dc:
            self.dc -= 1
        if pc_next is not None:
            self.pc = pc_next
        # FIFOs (host side + engine side, same edge)
        host_pop = rx_rd and bool(self.rx)
        host_push = tx_wr is not None and len(self.tx) < FIFO_DEPTH
        if pop_tx:
            self.tx.pop(0)
        if host_push:
            self.tx.append(tx_wr & MASK32)
        if host_pop:
            self.rx.pop(0)
        if push_rx is not None and len(self.rx) < FIFO_DEPTH and not rx_full_before(rx_full):
            self.rx.append(push_rx & MASK32)
        self.cycle += 1
        # pin synchronizer
        self.sync1 = self.sync0
        self.sync0 = pin_in & 0xFF
        return self.snapshot()

    def pins(self):
        """(pin_out, pin_oe) as the engine drives them: the pin block, with the line coder in charge of its two pins while it transmits."""
        oe, dpv, dmv = self.line.outputs()
        pin_out, pin_oe = self.pin_out, self.pin_oe
        if oe:
            for p, v in ((self.line.dm_pin, dmv), (self.line.dp_pin, dpv)):   # D+ wins if both name the same pin
                pin_oe |= 1 << p
                pin_out = (pin_out & ~(1 << p)) | v << p
        return pin_out, pin_oe

    def snapshot(self):
        pin_out, pin_oe = self.pins()
        return dict(pc=self.pc, pin_out=pin_out, pin_oe=pin_oe, halted=int(self.halted), fault=int(self.fault),
                    tx_full=int(len(self.tx) >= FIFO_DEPTH), rx_empty=int(not self.rx),
                    rx_head=self.rx[0] if self.rx else 0, osr=self.osr, isr=self.isr, lc=self.lc,
                    crc=self.crc.value(), z=self.z, n=self.n, c=self.c, trig=self.trig, r=list(self.r))

    def trace_line(self):
        s = self.snapshot()
        return (f"{s['pc']:02x} {s['pin_out']:02x} {s['pin_oe']:02x} {s['halted']}{s['fault']}{s['tx_full']}{s['rx_empty']} "
                f"{s['rx_head']:08x} {s['osr']:08x} {s['isr']:08x} {s['lc']:04x} {s['crc']:08x} {s['z']}{s['n']}{s['c']}{s['trig']} "
                + " ".join(f"{x:08x}" for x in s["r"]))


def rx_full_before(was_full):
    """The engine never pushes into a full FIFO (the instruction stalls); a push is dropped if it somehow happens."""
    return was_full


def run(program, cycles, stim=None):
    """Run `cycles` clocks. stim(c) -> (pin_in, tx_wr or None, rx_rd). Returns the list of trace lines."""
    e = Engine(program)
    out = []
    for c in range(cycles):
        pin, tx, rd = stim(c) if stim else (0, None, False)
        e.step(pin, tx, rd)
        out.append(e.trace_line())
    return out


def selftest():
    """Hand-checked programs: results known from the instruction table, independent of the RTL."""
    errs = 0

    def check(name, cond):
        nonlocal errs
        if not cond:
            errs += 1
            print("  FAIL", name)

    # sum 1..10 with a counted loop and a compare/branch
    a = A.Asm()
    a.LDI(0, 0); a.LDI(1, 1)
    a.label("l"); a.ALU("ADD", 0, rs=1); a.ALU("ADD", 1, imm=1); a.ALU("CMP", 1, imm=11); a.JCC("NZ", "l")
    a.RPUT("RXF", 0); a.HALT()
    e = Engine(a.words())
    for _ in range(200):
        e.step()
    check("sum 1..10 = 55", e.rx == [55] and e.halted and not e.fault)
    # cycle counts: WAIT d takes d+1, WAITR takes R+1, instructions take 1
    a = A.Asm()
    a.LDI(2, 4); a.WAITR(2); a.PUSHI(7); a.HALT()
    e = Engine(a.words())
    pcs = [e.step()["pc"] for _ in range(10)]
    check("WAITR 4 holds the PC 5 cycles", pcs[:8] == [1, 1, 1, 1, 1, 2, 3, 3])
    # CRC32 of "123456789" on the reset configuration
    a = A.Asm()
    for ch in b"123456789":
        a.LDI(0, ch); a.CRC("BYTE", 0)
    a.RGET(1, "CRC"); a.RPUT("RXF", 1); a.HALT()
    e = Engine(a.words())
    for _ in range(100):
        e.step()
    check("CRC-32 check value from firmware", e.rx == [0xCBF43926])
    # a CRC command executes one clock after its instruction: RGET CRC right after it waits one clock and reads the new value,
    # RGET CRC one instruction later does not wait
    for gap, want_pcs in ((False, [1, 2, 2, 3]), (True, [1, 2, 3, 4])):
        a = A.Asm()
        a.LDI(0, 0x31); a.CRC("BYTE", 0)
        if gap:
            a.NOP()
        a.RGET(1, "CRC"); a.RPUT("RXF", 1); a.HALT()
        e = Engine(a.words())
        pcs = [e.step()["pc"] for _ in range(4)]
        for _ in range(10):
            e.step()
        check(f"RGET CRC {'one instruction after' if gap else 'directly after'} CRC BYTE: pc {pcs}",
              pcs == want_pcs and e.rx == [cm.CRC(32, 0x04C11DB7, 0xFFFFFFFF, True, True, 0xFFFFFFFF).of(b"1")])
    # trap on a reserved opcode / sub-field
    for w in (29 << 27, A.enc_alu(13, 0, imm=1), A.word("RPUT", 5 << 4), A.word("CRC", 7 << 24), A.word("LINE", 6 << 24)):
        e = Engine([w])
        e.step()
        check(f"trap {w:08x}", e.halted and e.fault and e.pc == 0)
    errs += selftest_shared()
    print(f"RESULT isa_model: {'PASS' if not errs else 'FAIL (%d)' % errs}")
    return errs


def selftest_shared():
    """Shared memory (SHARED_IMEM): windows, the lock, the trap outside a window, jump bit 8. Hand-checked, not from the RTL."""
    errs = 0

    def check(name, cond):
        nonlocal errs
        if not cond:
            errs += 1
            print("  FAIL shared:", name)

    NOP = A.word("NOP")
    HALT = A.word("HALT")

    def region(base, limit):
        return (REGION_OP << 27) | base | (limit << 9)

    def jmp(target):
        return A.word("JMP", target & 0xFF) | (((target >> 8) & 1) << 11)

    # window [0,2): the NOP at 1 is inside, the fetch at 2 is outside and traps (the trap is seen when the fetch happens)
    sm = SharedImem(); sm.load(0, [region(0, 2), NOP, NOP, NOP])
    e = Engine([], shared=sm)
    for _ in range(3):
        e.step()
    check("fetch at the window's limit traps", e.halted and e.fault and e.pc == 2)

    # a second OP_REGION in the same run faults (the lock)
    sm = SharedImem(); sm.load(0, [region(0, 8), region(0, 4), NOP])
    e = Engine([], shared=sm)
    for _ in range(4):
        e.step()
    check("second OP_REGION faults", e.halted and e.fault and e.pc == 1 and e.locked)

    # limit above 512 and an empty window are illegal
    sm = SharedImem(); sm.load(0, [region(0, 513)])
    e = Engine([], shared=sm); e.step()
    check("limit 513 faults", e.halted and e.fault)
    sm = SharedImem(); sm.load(0, [region(4, 4)])
    e = Engine([], shared=sm); e.step()
    check("empty window faults", e.halted and e.fault)

    # a loop inside its window runs; the full-width limit 512 is legal
    sm = SharedImem(); sm.load(0, [region(0, 512), NOP, jmp(1)])
    e = Engine([], shared=sm)
    for _ in range(12):
        e.step()
    check("loop inside the window runs", not e.fault and not e.halted)

    # jump target bit 8 from operand bit 11: JMP 258 reaches the HALT at 258
    sm = SharedImem(); sm.load(0, [jmp(258)]); sm.load(258, [HALT])
    e = Engine([], shared=sm)
    for _ in range(3):
        e.step()
    check("JMP with target bit 8 reaches word 258", e.halted and not e.fault and e.pc == 258)

    # the program counter takes the host's START address at reset: a program at 100 with window [100,103) traps after 2 instructions
    sm = SharedImem(); sm.load(100, [region(100, 103), NOP, NOP])
    e = Engine([], shared=sm, start=100)
    for _ in range(4):
        e.step()
    check("START address: program at 100 runs in its window and traps at 103", e.halted and e.fault and e.pc == 103)

    # the default build is unchanged: an engine without shared memory has no window and a 256-word PC
    e = Engine([NOP, jmp(1)])
    check("default engine: no window", e.in_window() and not e.locked and e.pcmask == 0xFF)
    return errs


if __name__ == "__main__":
    raise SystemExit(1 if selftest() else 0)
