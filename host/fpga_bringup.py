#!/usr/bin/env python3
"""First checks of the chip on the DE0-Nano (or in simulation, the same script).

    python3 host/fpga_bringup.py --sim                   # the DE0-Nano top in Icarus Verilog (no hardware)
    python3 host/fpga_bringup.py --port /dev/ttyACM0     # the real board through the Pico bridge (host/pico_bridge.py)

Steps (each prints OK or FAIL): 1 STATUS bit 7 (alive), 2 read ID/VERSION/CAPABILITY, 3 scratch register, 4 run a counting program on both
engines and read the results back from their RX FIFOs, 5 blink program: engine 0 toggles uio[0] (GPIO_2[1] on the DE0-Nano header),
the script samples it through uio_in in simulation or asks you to watch a LED on hardware.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import asm as A                                           # noqa: E402
import shmem_host as S                                    # noqa: E402
from chip_host import SimLink, ID_ADDR, VERSION_ADDR, CAP_ADDR, SCRATCH_ADDR   # noqa: E402

errs = 0


def check(name, cond, detail=""):
    global errs
    errs += not cond
    print(("  OK   " if cond else "  FAIL ") + name + (f"   {detail}" if detail else ""))


def count_prog(n):
    """R0 counts to n, then n is pushed into the RX FIFO and the engine halts."""
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


def blink_prog(half_period_clocks):
    """Drive logical pin 0 high and low for ever; each level lasts half_period_clocks + 1 clocks."""
    a = A.Asm()
    a.REGION()
    a.DIRO(0)
    a.label("l")
    a.SETH(0)
    a.WAIT(half_period_clocks)
    a.SETLO(0)
    a.WAIT(half_period_clocks)
    a.JMP("l")
    return a


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--sim", action="store_true")
    g.add_argument("--port")
    args = ap.parse_args()
    if args.sim:
        link = SimLink(fpga=True)
    else:
        from serial_link import SerialLink
        link = SerialLink(args.port)
    with link:
        chip = S.ShmemHost(link)
        print("1. alive")
        st = chip.status()
        check("STATUS bit 7 set (a chip in reset or a stuck-low MISO reads 0)", st.alive, repr(st))
        print("2. identity")
        ident = chip.read(ID_ADDR)
        check("ID = 'PEM1' (0x50454D31)", ident == 0x50454D31, hex(ident))
        print("   VERSION", hex(chip.read(VERSION_ADDR)), " CAPABILITY", hex(chip.read(CAP_ADDR)))
        print("3. scratch register")
        for v in (0xA5A5A5A5, 0x5A5A5A5A):
            chip.write(SCRATCH_ADDR, v)
            check(f"write/read {v:#x}", chip.read(SCRATCH_ADDR) == v)
        print("4. programs: engine 0 at word 0, engine 1 at word 300")
        img0 = S.Image.from_asm("count3", count_prog(3), origin=0)
        img1 = S.Image.from_asm("count5", count_prog(5), origin=300)
        S.plan([img0, img1], [(img0, img1)])
        chip.start(0, img0)
        chip.start(1, img1)
        c0, c1 = chip.wait_halt(0), chip.wait_halt(1)
        check("both engines halted without fault", c0["halted"] and c1["halted"] and not (c0["fault"] or c1["fault"]))
        check("engine 0 returned 3, engine 1 returned 5", (chip.pop_rx(0), chip.pop_rx(1)) == (3, 5))
        chip.stop(0)
        chip.stop(1)
        print("5. blink uio[0] from engine 0")
        chip.claim_pad(0, 0)
        if args.sim:
            chip.start(0, S.Image.from_asm("blink", blink_prog(100), origin=0))
            seen = set()
            for _ in range(40):
                link.wait(25)
                p = link.pins()
                seen.add(p["uio_out"] & 1 if p["uio_oe"] & 1 else None)
            check("pad 0 is driven and takes both levels", seen == {0, 1}, str(seen))
        else:
            chip.start(0, S.Image.from_asm("blink", blink_prog(12_500_000), origin=0))   # about 4 Hz at 50 MHz
            print("   engine 0 is toggling uio[0] = GPIO_2[1]: check it with a LED or a scope (engine runs until you stop it).")
    print("RESULT fpga_bringup:", "PASS" if not errs else f"FAIL ({errs})")
    return 1 if errs else 0


if __name__ == "__main__":
    sys.exit(main())
