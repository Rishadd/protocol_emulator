#!/usr/bin/env python3
"""Shared memory, software only: host layout rules (shmem_host) and two engine models running images from one SharedImem
(isa_model). No chip. Run: python3 host/shmem_test.py
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import asm as A                     # noqa: E402
import isa_model as M               # noqa: E402
import shmem_host as S              # noqa: E402
from chip_host import HostError     # noqa: E402

errs = 0


def check(name, cond):
    global errs
    if not cond:
        errs += 1
        print("  FAIL", name)


def expect_error(name, fn, *args):
    try:
        fn(*args)
    except HostError:
        return
    global errs
    errs += 1
    print("  FAIL (no HostError)", name)


def prog(n_loop=3):
    a = A.Asm()
    a.REGION()                       # window = the whole program
    a.LDI(0, 0)
    a.label("l")
    a.ALU("ADD", 0, imm=1)
    a.ALU("CMP", 0, imm=n_loop)
    a.JCC("NZ", "l")
    a.RPUT("RXF", 0)
    a.HALT()
    return a


# ---- layout: images are linked to their origin, windows follow the code
a = prog()
img_a = S.Image.from_asm("a", a, origin=0)
img_b = S.Image.from_asm("b", prog(5), origin=300)
check("window of a covers its code", img_a.window == (0, len(img_a.words)))
check("window of b is linked at 300", img_b.window == (300, 300 + len(img_b.words)) and img_b.origin == 300)

# the JCC of b jumps to its label: REGION (0), LDI (1), label "l" at index 2, so absolute 300 + 2 = 302 (bit 8 set)
jcc_b = [w for w in img_b.words if (w >> 27) == A.OPCODE["JCC"]][0]
check("JCC target of b is 302 (bit 8 in operand bit 11)", (jcc_b & 0xFF) == (302 & 0xFF) and (jcc_b >> 11 & 1) == (302 >> 8 & 1))

# ---- run both images in the model, one per engine, from one shared memory
sm = M.SharedImem()
sm.load(img_a.origin, img_a.words)
sm.load(img_b.origin, img_b.words)
ea = M.Engine([], shared=sm, start=img_a.origin)
eb = M.Engine([], shared=sm, start=img_b.origin)
for _ in range(400):
    ea.step()
    eb.step()
check("engine a: loop of 3 gives rx 3", ea.rx == [3] and ea.halted and not ea.fault)
check("engine b: loop of 5 gives rx 5 (bit-8 jump target)", eb.rx == [5] and eb.halted and not eb.fault)
check("each engine set its own window", ea.win == img_a.window and eb.win == img_b.window)

# ---- planning: overlap of concurrent images, fit, names
img_c = S.Image.from_asm("c", prog(2), origin=0)
expect_error("overlapping concurrent images are refused", S.plan, [img_a, img_c], [(img_a, img_c)])
S.plan([img_a, img_b], [(img_a, img_b)])
check("non-overlapping concurrent images pass", True)
expect_error("duplicate names refused", S.plan, [img_a, S.Image.from_asm("a", prog(), origin=400)], [])
expect_error("image past the end refused", S.Image.from_asm, "x", prog(), 508)

# ---- image validity: the first instruction must be OP_REGION and its window must cover the code
bad = A.Asm()
bad.NOP(); bad.HALT()
expect_error("image without OP_REGION refused", S.Image.from_asm, "nr", bad, 0)
narrow = A.Asm()
narrow.REGION(0, 1); narrow.NOP(); narrow.HALT()
expect_error("window narrower than the code refused", S.Image.from_asm, "nw", narrow, 0)

# ---- host write rules, with a stub link (no chip): a running window refuses an overlapping image
h = S.ShmemHost.__new__(S.ShmemHost)
S.ShmemHost.__init__(h, link=None)
h._win[0] = img_a.window                 # engine 0 runs image a
expect_error("write into a running window refused", h._check_writable, img_c)
h._win[1] = None
h._check_writable(img_b)                 # no overlap with the running window: allowed (engine 1 held)
h._win[1] = img_b.window
expect_error("both engines running: no host port", h._check_writable, img_b)

print(f"RESULT shmem_test: {'PASS' if not errs else 'FAIL (%d)' % errs}")
sys.exit(1 if errs else 0)
