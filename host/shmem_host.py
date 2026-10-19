#!/usr/bin/env python3
"""Host side of the shared 512-word instruction memory (SHARED_IMEM, docs/SHARED_IMEM_PLAN.md).

The host chooses where each program lives (its origin, a physical word address) and links it there (host/asm.py words_at).
The firmware sets its own window with its first instruction, OP_REGION, which must match the image: the window is the
range the image was linked for. The chip enforces the window in hardware; this module checks everything it can before a
single word is written, so a bad layout fails in Python, not as a chip fault.

    from shmem_host import Image, ShmemHost, plan
    img = Image.from_asm("uart", asm_program, origin=0)       # asm_program starts with asm.REGION()
    plan([img_a, img_b], concurrent=[(img_a, img_b)])         # overlap / fit checks, no chip access
    host = ShmemHost(link)                                    # link: a ChipHost-compatible link
    host.start(0, img_a)                                      # stops engine 0, loads the image, sets RUN

Rules the host enforces (the chip enforces the same ones in hardware):
  * an image's window is [base, limit) with base <= origin and limit >= origin + len(words) (the code is inside its window)
  * an image is written only while no RUNNING engine's window contains any of its words, and only while one engine is held
    (the host access uses a held engine's port, src/imem_shared.v)
  * two images that run at the same time must not share words (sharing code is allowed only on purpose, pass share=True)
"""
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import asm as A                                   # noqa: E402
from chip_host import ChipHost, HostError, ENG_BASE, CTRL   # noqa: E402

IMEM_BASE = 0x0400              # physical instruction word w at 0x0400 + 4*w (mgmt.v, SHARED_IMEM)
IMEM_WORDS = 512
START = 0x00C                   # per-engine register at ENG_BASE + 0x00C: the program counter's reset value (write while held)
REGION_OP = A.OPCODE["REGION"]


class Image:
    """One program in the shared memory: its origin, its words, and the window its first instruction (OP_REGION) sets."""

    def __init__(self, name, words, origin):
        self.name = name
        self.words = list(words)
        self.origin = origin
        if not self.words:
            raise HostError(f"image {name}: empty")
        if origin < 0 or origin + len(self.words) > IMEM_WORDS:
            raise HostError(f"image {name}: {len(self.words)} words at {origin} do not fit the {IMEM_WORDS}-word memory")
        first = self.words[0]
        if first >> 27 != REGION_OP:
            raise HostError(f"image {name}: the first instruction must be OP_REGION (its window), found opcode {first >> 27}")
        self.base = first & 0x1FF
        self.limit = (first >> 9) & 0x3FF
        if not (self.base <= origin and self.limit >= origin + len(self.words) and self.base < self.limit <= IMEM_WORDS):
            raise HostError(f"image {name}: window [{self.base}, {self.limit}) does not cover the code [{origin}, "
                            f"{origin + len(self.words)})")

    @classmethod
    def from_asm(cls, name, prog, origin):
        """prog: an host/asm.py Asm whose first call is prog.REGION(). Links it for `origin`."""
        try:
            words = prog.words_at(origin)
        except AssertionError as e:                     # asm.py: does not fit the memory
            raise HostError(f"image {name}: {e}") from None
        return cls(name, words, origin)

    @property
    def span(self):
        return (self.origin, self.origin + len(self.words))

    @property
    def window(self):
        return (self.base, self.limit)

    def __repr__(self):
        return f"Image({self.name!r}, origin={self.origin}, len={len(self.words)}, window=[{self.base},{self.limit}))"


def _overlap(a, b):
    return a[0] < b[1] and b[0] < a[1]


def plan(images, concurrent=(), share=False):
    """Check a set of images before any chip access. `concurrent` lists pairs that run at the same time.
    Raises HostError on the first problem; returns the list of pairs that were checked."""
    checked = []
    for x, y in concurrent:
        if not share and _overlap(x.span, y.span):
            raise HostError(f"images {x.name} and {y.name} run together but share words {max(x.origin, y.origin)}.."
                            f"{min(x.span[1], y.span[1]) - 1}")
        checked.append((x.name, y.name))
    names = [i.name for i in images]
    if len(set(names)) != len(names):
        raise HostError("image names must be unique")
    return checked


class ShmemHost(ChipHost):
    """ChipHost for the shared memory. The per-engine load_program of ChipHost does not apply: use load_image / start."""

    def __init__(self, link, trace=False, log=None):
        super().__init__(link, trace=trace, log=log)
        self._win = {0: None, 1: None}         # window of the image each engine runs (host's record), None = held

    def load_program(self, eng, words, fill_halt=True):
        raise HostError("shared memory: use load_image(...) / start(...) with a host/shmem_host.Image")

    def running(self):
        return [e for e in (0, 1) if self._win[e] is not None]

    def _check_writable(self, img):
        """A write of img is legal now: one engine held (the host's port), and no running window contains a word of img."""
        if len(self.running()) == 2:
            raise HostError("both engines run: the host has no memory port (src/imem_shared.v)")
        for e in self.running():
            base, limit = self._win[e]
            if _overlap((base, limit), img.span):
                raise HostError(f"image {img.name} overlaps the running window of engine {e} [{base}, {limit})")

    def load_image(self, img):
        """Write img into the shared memory at its origin. Every word is checked by the chip (mgmt err) and by _check_writable."""
        self._check_writable(img)
        for i, w in enumerate(img.words):
            self.write(IMEM_BASE + 4 * (img.origin + i), w)
        self.check_err(f"load_image {img.name}")

    def start(self, eng, img):
        """Stop engine eng, load img, write its START address (the program counter's reset value), set RUN.
        The image's first instruction (OP_REGION) sets the window on the chip."""
        self.stop(eng)                                    # the engine is held: its port is free for the load
        self._win[eng] = None
        self.load_image(img)
        self.write(ENG_BASE[eng] + START, img.origin, check=True)   # held engine only (mgmt refuses it while RUN = 1)
        self.run(eng, True)
        self._win[eng] = img.window                       # the window the firmware is expected to set; the chip enforces it
        return img.window

    def stop(self, eng):
        super().stop(eng)
        self._win[eng] = None
