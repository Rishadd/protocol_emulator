#!/usr/bin/env python3
"""Shared instruction memory on the real chip RTL (SHARED_IMEM) through the SPI link: python3 host/shmem_chip_test.py
Two images in one memory at different origins, START addresses, OP_REGION windows and the faults, the lock, and the host
write rules. The expected values come from the architecture (docs/SHARED_IMEM_PLAN.md) and from host/isa_model.py, not from the RTL.
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import asm as A                                           # noqa: E402
import shmem_host as S                                    # noqa: E402
from chip_host import SimLink, HostError, ENG_BASE        # noqa: E402

errs = 0


def check(name, cond):
    global errs
    if not cond:
        errs += 1
        print("  FAIL", name)


def count_prog(n):
    a = A.Asm()
    a.REGION()
    a.LDI(0, 0)
    a.label("l")
    a.ALU("ADD", 0, imm=1)
    a.ALU("CMP", 0, imm=n)
    a.JCC("NZ", "l")
    a.RPUT("RXF", 0)
    a.HALT()
    return a


def loop_prog():
    """Runs forever inside its window: REGION, then NOP; JMP back."""
    a = A.Asm()
    a.REGION()
    a.label("l")
    a.NOP()
    a.JMP("l")
    return a


def region_word(base, limit):
    return (A.OPCODE["REGION"] << 27) | base | (limit << 9)


def put_words(chip, origin, words):
    """Raw image write (no Image checks): used to build programs the host layer would refuse."""
    for i, w in enumerate(words):
        chip.write(S.IMEM_BASE + 4 * (origin + i), w)
    chip.check_err("raw image")


def start_raw(chip, eng, start):
    chip.write(ENG_BASE[eng] + S.START, start, check=True)
    chip.run(eng, True)


def main():
    global errs
    with SimLink(shared=True) as link:
        chip = S.ShmemHost(link)

        # ---- two images, two engines, one memory: engine 0 at origin 0, engine 1 at origin 300 (bit-8 jump targets)
        img_a = S.Image.from_asm("a", count_prog(3), origin=0)
        img_b = S.Image.from_asm("b", count_prog(5), origin=300)
        S.plan([img_a, img_b], [(img_a, img_b)])
        chip.start(0, img_a)
        chip.start(1, img_b)
        c0 = chip.wait_halt(0)
        c1 = chip.wait_halt(1)
        check("engine 0 halted without fault", c0["halted"] and not c0["fault"])
        check("engine 1 halted without fault", c1["halted"] and not c1["fault"])
        check("engine 0 result 3", chip.pop_rx(0) == 3)
        check("engine 1 result 5 (program at 300)", chip.pop_rx(1) == 5)

        # ---- both stopped again: re-run engine 1 with image A on top of its old place (the same program, other origin)
        chip.stop(0); chip.stop(1)
        img_a2 = S.Image.from_asm("a2", count_prog(4), origin=40)
        chip.start(1, img_a2)
        c1 = chip.wait_halt(1)
        check("engine 1 runs the program linked at 40", c1["halted"] and not c1["fault"] and chip.pop_rx(1) == 4)
        chip.stop(1)

        # ---- fetch past the window faults: window [0,2): REGION, NOP, NOP -> the fetch at 2 traps
        chip.stop(0)
        put_words(chip, 0, [region_word(0, 2), A.word("NOP"), A.word("NOP")])
        start_raw(chip, 0, 0)
        c0 = chip.wait_halt(0)
        check("fetch at the window's limit faults", c0["fault"] and c0["halted"])
        chip.stop(0)

        # ---- a second OP_REGION faults (the lock)
        put_words(chip, 0, [region_word(0, 8), region_word(0, 4), A.word("NOP")])
        start_raw(chip, 0, 0)
        c0 = chip.wait_halt(0)
        check("second OP_REGION in one run faults", c0["fault"])
        chip.stop(0)

        # ---- an empty window and a limit above 512 fault
        put_words(chip, 0, [region_word(4, 4)])
        start_raw(chip, 0, 0)
        check("empty window faults", chip.wait_halt(0)["fault"])
        chip.stop(0)
        put_words(chip, 0, [(A.OPCODE["REGION"] << 27) | 0 | (513 << 9)])
        start_raw(chip, 0, 0)
        check("limit 513 faults", chip.wait_halt(0)["fault"])
        chip.stop(0)

        # ---- the lock clears when the engine is held: the same image runs again
        put_words(chip, 0, count_prog(2).words_at(0))
        start_raw(chip, 0, 0)
        check("second run after a hold works (lock cleared)", not chip.wait_halt(0)["fault"] and chip.pop_rx(0) == 2)
        chip.stop(0)

        # ---- host write rules: engine 0 runs a loop in window [0,4); a write into it is refused, a write outside is accepted
        loop = S.Image.from_asm("loop", loop_prog(), origin=0)
        chip.start(0, loop)
        chip.clear_err()
        chip.write(S.IMEM_BASE + 4 * 2, A.word("NOP"))
        check("write into a running window is refused", chip.status().err)
        chip.clear_err()
        chip.write(S.IMEM_BASE + 4 * 100, A.word("NOP"))
        check("write outside the running window is accepted", not chip.status().err)
        # both engines running: no host port
        chip.start(1, S.Image.from_asm("loop1", loop_prog(), origin=200))
        chip.clear_err()
        chip.write(S.IMEM_BASE + 4 * 400, A.word("NOP"))
        check("both engines running: host write refused", chip.status().err)
        chip.clear_err()
        # START is writable only while held
        chip.write(ENG_BASE[0] + S.START, 7)
        check("START write while running is refused", chip.status().err)
        chip.clear_err()
        check("START reads back", chip.read(ENG_BASE[1] + S.START) == 200)
        chip.stop(0); chip.stop(1)

        # ---- a program without OP_REGION runs with the whole memory as its window
        a = A.Asm()
        a.LDI(0, 7)
        a.RPUT("RXF", 0)
        a.HALT()
        put_words(chip, 0, a.words_at(0))
        start_raw(chip, 0, 0)
        check("no OP_REGION: default window is the whole memory", not chip.wait_halt(0)["fault"] and chip.pop_rx(0) == 7)
        chip.stop(0)

        # ---- S1: REGION read and instruction readback (frame v2)
        from chip_host import OP2_READ, OP2_WRITE
        chip.stop(0); chip.stop(1)
        mem = [(0x5A000000 + 7 * i) & 0xFFFFFFFF for i in range(48)]
        put_words(chip, 100, mem)
        back = [chip.read2(S.IMEM_BASE + 4 * (100 + i)) for i in range(48)]
        check("readback with both engines held returns every word written", back == mem)
        put_words(chip, 0, [0x13572468])                                  # (a word never written reads as X in simulation: write the ends first)
        put_words(chip, 511, [0x2468ACE0])
        check("readback of the first and last word of the memory",
              chip.read2(S.IMEM_BASE) == 0x13572468 and chip.read2(S.IMEM_BASE + 4 * 511) == 0x2468ACE0)
        full = (512 << 16) | 0
        check("REGION of a held engine is the whole memory", chip.read2(ENG_BASE[0] + 0x008) == full
              and chip.read2(ENG_BASE[1] + 0x008) == full)

        img = S.Image.from_asm("loop", loop_prog(), origin=200)
        chip.start(0, img)
        base, limit = img.window
        want = (limit << 16) | base
        check("REGION of a running engine is the window its OP_REGION set", chip.read2(ENG_BASE[0] + 0x008) == want)
        check("REGION of the held engine is still the whole memory", chip.read2(ENG_BASE[1] + 0x008) == full)
        check("readback with one engine running goes through the held engine's port",
              [chip.read2(S.IMEM_BASE + 4 * (100 + i)) for i in range(8)] == mem[:8])
        check("readback of the running image itself matches what was loaded",
              [chip.read2(S.IMEM_BASE + 4 * (200 + i)) for i in range(len(img.words))] == list(img.words))
        r = chip.cmd2(OP2_WRITE, ENG_BASE[0] + 0x008, 0x1234)
        check("REGION is read only (result code 4)", r.code == 4)

        start_raw(chip, 1, 100)
        r = chip.cmd2(OP2_READ, S.IMEM_BASE + 4 * 100)
        check("readback with both engines running is refused (result code 4)", r.code == 4)
        chip.stop(0); chip.stop(1)
        chip.read(S.IMEM_BASE + 4 * 100)                                  # a v1 frame cannot read the memory: err
        check("a v1 read of the instruction memory is refused (err)", chip.status().err)
        chip.clear_err()
        chip.stop(0)

        # ---- S4: the host workflow: verified load, REGION check on start, plan_images
        chip.stop(0); chip.stop(1)
        words = [0x71000000 + i for i in range(20)]
        chip.load_imem(300, words)                                        # written and read back by the chip
        try:
            chip._verify("planted", 300, [w ^ 1 for w in words])
            check("readback verification catches a differing word", False)
        except HostError:
            check("readback verification catches a differing word", True)
        img = S.Image.from_asm("w", loop_prog(), origin=60)
        chip.start(0, img)                                                # verifies the load and the window the chip holds
        check("region() equals the image's window after start", chip.region(0) == img.window)
        check("the other engine, still held, holds the whole memory", chip.region(1) == (0, 512))
        chip.stop(0)
        img2 = S.Image.from_asm("w2", loop_prog(), origin=60)
        img2.limit += 1                                                   # the host believes in another window than the firmware sets
        try:
            chip.start(0, img2)
            check("start detects a window mismatch", False)
        except HostError:
            check("start detects a window mismatch", True)
        check("a failed start leaves the engine held", chip.region(0) == (0, 512))
        a1 = S.Image.from_asm("p1", loop_prog(), origin=70)
        a2 = S.Image.from_asm("p2", loop_prog(), origin=72)
        try:
            S.ShmemHost.plan_images([a1, a2], [(a1, a2)])
            check("plan_images refuses overlapping images that run together", False)
        except HostError:
            check("plan_images refuses overlapping images that run together", True)
        chip.stop(0); chip.stop(1)

    print(f"RESULT shmem_chip_test: {'PASS' if not errs else 'FAIL (%d)' % errs}")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
