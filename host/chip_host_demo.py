#!/usr/bin/env python3
"""Software host for the protocol-emulator chip: a guided tour of everything the management SPI link can do, run against the RTL.

    python3 host/chip_host_demo.py            # every frame printed, decoded
    python3 host/chip_host_demo.py --quiet    # only the section headings and results

Needs iverilog + vvp (the chip is simulated; the host side is plain Python). Explanation of each exchange: docs/HOST_INTERFACE.md.
"""
import argparse
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import asm as A
from chip_host import ChipHost, HostError, SimLink, ENG_BASE, CTRL, OP_WRITE


def section(t):
    print(f"\n=== {t}")


def echo_plus_one():
    """Firmware: read a word from the TX FIFO, add 1, send it to the RX FIFO, forever."""
    a = A.Asm()
    a.label("loop")
    a.PULL()                       # TX FIFO -> output shift register (waits while the FIFO is empty)
    a.RGET(1, "OSR")               # R1 <- OSR
    a.ALU("ADD", 1, imm=1)         # R1 += 1
    a.RPUT("ISR", 1)               # input shift register <- R1
    a.PUSH()                       # ISR -> RX FIFO (waits while the FIFO is full)
    a.JMP("loop")
    return a.words()


def hold_pin_high():
    """Firmware: drive logical pin 0 high and stop."""
    a = A.Asm()
    a.DIRO(0)
    a.SETH(0)
    a.HALT()
    return a.words()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--quiet", action="store_true")
    ap.add_argument("--fpga", action="store_true", help="run on the DE0-Nano top (src/fpga) instead of the chip top")
    args = ap.parse_args()
    with SimLink(fpga=args.fpga) as link:
        chip = ChipHost(link, trace=not args.quiet)

        section("1. Is the chip alive? Reset state (STATUS bit 7 = 1, nothing running, no error)")
        st = chip.status()
        assert st.alive and not st.err and st.run == (0, 0)
        print("   ", st)

        section("2. Load firmware into engine 0 (engine is held in reset until RUN = 1, so the memory can be written)")
        words = echo_plus_one()
        chip.load_program(0, words, fill_halt=False)
        print(f"    {len(words)} instruction words written to engine 0 (IMEM is write-only over this link)")

        section("3. RUN, then exchange data through the FIFOs (flow control = the STATUS byte of every frame)")
        chip.run(0)
        sent = [0x10, 0x20, 0xFFFFFFFF, 0x7]
        chip.send_words(0, sent)
        got = chip.recv_words(0, len(sent))
        print("    sent    ", [hex(x) for x in sent])
        print("    received", [hex(x) for x in got])
        assert got == [(x + 1) & 0xFFFFFFFF for x in sent]
        print("    engine 0:", chip.ctrl(0))

        section("4. TX flow control: a push is only accepted when STATUS shows the FIFO not full")
        chip.stop(0)
        n = 0
        while chip.push_tx(0, 0xA0 + n):
            n += 1
        print(f"    FIFO took {n} words, the next push was dropped (STATUS tx_full = {chip.last_status.tx_full[0]}); resending would be needed")
        chip.write(ENG_BASE[0] + CTRL, 0)

        section("5. RX flow control: an empty FIFO returns nothing and pops nothing")
        print("    pop_rx on an empty FIFO ->", chip.pop_rx(1))

        section("6. Pin manager: engine 1 drives logical pin 0 on uio[5] (remap) and uo_out[4]")
        chip.load_program(1, hold_pin_high())
        chip.claim_pad(5, eng=1, logical=0)
        chip.claim_uo(4, eng=1, logical=0)
        print("    PAD[5] =", chip.pad(5))
        chip.run(1)
        chip.wait(40)
        p = chip.pins()
        print(f"    uio_oe=0x{p['uio_oe']:02X} uio_out=0x{p['uio_out']:02X} uo_out=0x{p['uo_out']:02X}")
        assert p["uio_oe"] == 0x20 and p["uio_out"] == 0x20 and p["uo_out"] >> 4 & 1
        print("    violations:", chip.violations())

        section("7. A rejected access: the chip changes nothing and raises the sticky err flag in STATUS")
        try:
            chip.write(0x0224, 1, check=True)
        except HostError as e:
            print("    host saw:", e)
        print("    err after clear_err:", chip.status().err)
        try:
            chip.claim_pad(5, eng=0)           # engine 1 is running and owns the pad
        except HostError as e:
            print("    host saw:", e)
        chip.stop(1)

        section("8. Bring-up without SPI: debug view on uo_out[7:2] (view 0 = heartbeat, err, RUN e0/e1, halted-or-fault e0/e1)")
        chip.set_inputs(ui_in_7_3=0b00000)     # DBG_SEL = 0
        chip.wait(10)
        print(f"    uo_out[7:2] = {chip.pins()['uo_out'] >> 2:06b}")

        section("9. Interrupt and HOLD")
        chip.irq_clear()
        chip.set_misc(irq_mask=0x04)          # IRQ pin follows 'engine 0 halted'
        chip.load_program(0, hold_pin_high())
        chip.run(0)
        chip.wait(40)
        print("    IRQ status:", {k: v for k, v in chip.irq_status().items() if v}, " uo_out[1] =", chip.pins()["uo_out"] >> 1 & 1)
        chip.set_inputs(ui_in_7_3=0b00001)    # ui_in[3] = HOLD high
        chip.wait(10)
        print("    HOLD high -> engine 0 CTRL:", chip.ctrl(0), " inputs:", chip.inputs())
        chip.set_inputs(ui_in_7_3=0)

        print(f"\nDONE: {chip.frames} SPI frames (7 bytes each way per frame), all checks passed")


if __name__ == "__main__":
    main()
