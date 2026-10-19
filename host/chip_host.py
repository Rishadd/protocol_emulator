#!/usr/bin/env python3
"""Host-side driver for the protocol-emulator chip over its management SPI link (frame v1), with a software link to the RTL.

    from chip_host import ChipHost, SimLink
    with SimLink() as link:                      # builds tb/tb_host_bridge.v with iverilog and runs it with vvp
        chip = ChipHost(link, trace=True)        # trace=True prints every SPI frame, decoded
        chip.load_program(0, words)              # words: 32-bit instruction words (host/asm.py)
        chip.run(0)
        chip.push_tx(0, 0x41)
        print(chip.pop_rx(0))

Nothing in ChipHost depends on the simulator: it only needs an object with `transfer(mosi: bytes) -> bytes` (one full-duplex
7-byte frame). On real hardware that object is a SPI master (mode 0, MSB first) - a microcontroller, an FTDI/RP2040 bridge or
Linux spidev. `SimLink` is the software stand-in: it drives the real chip RTL through tb/tb_host_bridge.v.

THE LINK (docs/HOST_INTERFACE.md has the full explanation, this is the short version)
  Pins: ui_in[0] SCLK, ui_in[1] MOSI, ui_in[2] CS_N, uo_out[0] MISO. SPI mode 0 (CPOL 0, CPHA 0), MSB first, full duplex.
  Every transaction is ONE FRAME of exactly 7 bytes between CS_N falling and CS_N rising:
      MOSI  byte 0      byte 1-2        byte 3-6
            op          address (BE)    write data (BE; ignored for a READ)
      MISO  byte 0      byte 1-2        byte 3-6
            STATUS      0x00 0x00       read data (BE; 0 for a WRITE)
  op 0x01 = WRITE, 0x02 = READ. The chip acts only when CS_N rises after a clean 7-byte frame; an aborted, short or long
  frame changes nothing (a short/long/odd-bit frame also sets the sticky err flag).
  STATUS (byte 0, valid at frame start, i.e. it tells the state BEFORE this frame's own effect):
      bit 7 always 1 ("alive": a chip in reset or a stuck-low MISO reads 0x00 here, which the host recognises at once)
      bit 6 err (sticky; a rejected access; cleared by reset or by writing 1 to IRQ bit 6 at 0x02C4)
      bit 5,4 RUN engine 1, 0     bit 3,2 TX FIFO full engine 1, 0     bit 1,0 RX FIFO has data engine 1, 0
  Read data is looked up while the address bytes arrive, so a READ returns the value as of the end of byte 2.
  FLOW CONTROL is in STATUS, not in the protocol: a TX push is accepted only if THIS frame's STATUS showed the FIFO not full
  (otherwise it is silently dropped: resend); an RX pop pops only if THIS frame's STATUS showed data (otherwise returns 0 and
  pops nothing). push_tx()/pop_rx() below look at the returned STATUS and tell the caller what happened.
"""
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, ".."))

OP_WRITE, OP_READ = 0x01, 0x02
ENG_BASE = (0x1000, 0x2000)
CTRL, TX_DATA, RX_DATA, IMEM = 0x000, 0x200, 0x204, 0x400        # offsets inside an engine window
IMEM_WORDS = 256
VIOL, MISC, IRQ, INPUTS = 0x0220, 0x02C0, 0x02C4, 0x02C8
IRQ_NAMES = ["rx_data_e0", "rx_data_e1", "halted_e0", "halted_e1", "fault_e0", "fault_e1", "mgmt_err", "violation"]
OP_HALT_WORD = 3 << 27


def pad_addr(p):          # uio[p] output configuration
    return 0x0200 + 4 * p


def opad_addr(k):         # uo_out[k] output configuration, k = 1..7
    return 0x0240 + 4 * k


def isel_addr(eng, i):    # engine eng, logical input pin i
    return 0x0280 + 0x20 * eng + 4 * i


class HostError(Exception):
    pass


class Status:
    """The STATUS byte (byte 0 of every reply)."""

    def __init__(self, b):
        self.raw = b
        self.alive = bool(b & 0x80)
        self.err = bool(b & 0x40)
        self.run = ((b >> 4) & 1, (b >> 5) & 1)          # (engine 0, engine 1)
        self.tx_full = ((b >> 2) & 1, (b >> 3) & 1)
        self.rx_avail = (b & 1, (b >> 1) & 1)

    def __repr__(self):
        return (f"STATUS(0x{self.raw:02X} alive={int(self.alive)} err={int(self.err)} run={self.run} "
                f"tx_full={self.tx_full} rx_avail={self.rx_avail})")


def describe(op, addr, data=0):
    """One line in words for a (op, address, data) access."""
    def reg(a):
        e = {0x1000: 0, 0x2000: 1}.get(a & 0xF000)
        if e is not None:
            o = a & 0xFFF
            if o == CTRL:
                return f"E{e}.CTRL"
            if o == TX_DATA:
                return f"E{e}.TX_DATA"
            if o == RX_DATA:
                return f"E{e}.RX_DATA"
            if IMEM <= o < IMEM + 4 * IMEM_WORDS:
                return f"E{e}.IMEM[{(o - IMEM) // 4}]"
        if 0x0200 <= a < 0x0220:
            return f"PAD[uio{(a - 0x200) // 4}]"
        if a == VIOL:
            return "VIOL"
        if 0x0244 <= a < 0x0260:
            return f"OPAD[uo_out{(a - 0x240) // 4}]"
        if 0x0280 <= a < 0x02C0:
            return f"ISEL[E{(a - 0x280) // 0x20}.pin{((a - 0x280) % 0x20) // 4}]"
        return {MISC: "MISC", IRQ: "IRQ", INPUTS: "INPUTS"}.get(a, "?")
    n = reg(addr)
    if op == OP_WRITE:
        return f"WRITE {n} (0x{addr:04X}) <- 0x{data:08X}"
    if op == OP_READ:
        return f"READ  {n} (0x{addr:04X})"
    return f"op 0x{op:02X} (unknown) 0x{addr:04X}"


class ChipHost:
    """The chip's management interface as Python calls. `link.transfer(bytes7) -> bytes7` moves one frame."""

    def __init__(self, link, trace=False, log=None):
        self.link = link
        self.trace = trace
        self.log = log if log is not None else []     # (op, addr, data, reply Status, read data)
        self.frames = 0
        self.last_status = None

    # ------------------------------------------------------------------ frames
    def frame(self, op, addr, data=0):
        """One 7-byte frame. Returns (Status, read_data). Byte layout: op | addr[15:8] addr[7:0] | data[31:24]..data[7:0]."""
        mosi = bytes([op, addr >> 8 & 0xFF, addr & 0xFF]) + (data & 0xFFFFFFFF).to_bytes(4, "big")
        miso = self.link.transfer(mosi)
        assert len(miso) == 7
        st = Status(miso[0])
        rd = int.from_bytes(miso[3:7], "big")
        self.frames += 1
        self.last_status = st
        self.log.append((op, addr, data, st, rd))
        if self.trace:
            tail = f" -> 0x{rd:08X}" if op == OP_READ else ""
            print(f"  [{self.frames:4d}] MOSI {mosi.hex(' ')} | MISO {miso.hex(' ')} | {describe(op, addr, data)}{tail}"
                  f"   {st}")
        if not st.alive:
            raise HostError(f"chip does not answer: STATUS 0x{st.raw:02X} (bit 7 must be 1)")
        return st, rd

    def write(self, addr, data, check=False):
        """WRITE. A write the chip rejects (bad address/value, running engine, ...) sets err; check=True fetches the status to
        find out (one extra frame) and raises HostError."""
        self.frame(OP_WRITE, addr, data)
        if check:
            self.check_err(f"write 0x{addr:04X} <- 0x{data:X}")

    def read(self, addr):
        return self.frame(OP_READ, addr)[1]

    def status(self):
        """Status as of now (a harmless READ of engine 0's CTRL)."""
        return self.frame(OP_READ, ENG_BASE[0] + CTRL)[0]

    def check_err(self, what=""):
        st = self.status()
        if st.err:
            self.clear_err()
            raise HostError(f"the chip rejected an access ({what}): err flag was set (cleared again)")

    def clear_err(self):
        self.frame(OP_WRITE, IRQ, 1 << 6)             # IRQ status bit 6 = management error, write-one-to-clear; also clears err

    # ------------------------------------------------------------------ engines
    def ctrl(self, eng):
        v = self.read(ENG_BASE[eng] + CTRL)
        return dict(run=v & 1, halted=v >> 1 & 1, fault=v >> 2 & 1, pc=v >> 8 & 0xFF)

    def run(self, eng, go=True):
        self.write(ENG_BASE[eng] + CTRL, 1 if go else 0, check=True)

    def stop(self, eng):
        self.run(eng, False)

    def load_program(self, eng, words, fill_halt=True):
        """Write instruction words 0..n-1 (the engine must be stopped: RUN = 0; this call stops it). With fill_halt the rest of the
        256-word memory is filled with HALT, so a stray jump stops instead of executing leftovers. The instruction memory is
        write-only over this link (it cannot be read back)."""
        if len(words) > IMEM_WORDS:
            raise HostError(f"program has {len(words)} words, memory holds {IMEM_WORDS}")
        self.stop(eng)
        base = ENG_BASE[eng] + IMEM
        for i, w in enumerate(words):
            self.write(base + 4 * i, w)
        if fill_halt:
            for i in range(len(words), IMEM_WORDS):
                self.write(base + 4 * i, OP_HALT_WORD)
        self.check_err(f"load_program engine {eng}")

    def wait_halt(self, eng, max_polls=2000):
        """Poll CTRL until the engine halted (or faulted). Returns the final ctrl dict."""
        for _ in range(max_polls):
            c = self.ctrl(eng)
            if c["halted"] or c["fault"]:
                return c
        raise HostError(f"engine {eng} did not halt after {max_polls} polls")

    # ------------------------------------------------------------------ FIFOs (flow control through STATUS)
    def push_tx(self, eng, word, retries=0):
        """Push one 32-bit word into the engine's TX FIFO. Accepted only if the frame's STATUS shows tx_full = 0; returns True if
        accepted. With retries > 0 a dropped push is resent (each resend is a new frame with a fresh STATUS)."""
        for _ in range(retries + 1):
            st, _ = self.frame(OP_WRITE, ENG_BASE[eng] + TX_DATA, word)
            if not st.tx_full[eng]:
                return True
        return False

    def send_words(self, eng, words, max_polls=10000):
        """Push words in order, waiting for FIFO space (resend while the FIFO is full)."""
        for w in words:
            for _ in range(max_polls):
                if self.push_tx(eng, w):
                    break
            else:
                raise HostError(f"TX FIFO of engine {eng} stayed full")

    def pop_rx(self, eng):
        """Pop one word from the engine's RX FIFO: returns the word, or None if the FIFO was empty (nothing popped)."""
        st, rd = self.frame(OP_READ, ENG_BASE[eng] + RX_DATA)
        return rd if st.rx_avail[eng] else None

    def recv_words(self, eng, n, max_polls=10000):
        """Read n words from the RX FIFO, polling while it is empty."""
        out = []
        for _ in range(max_polls):
            w = self.pop_rx(eng)
            if w is not None:
                out.append(w)
                if len(out) == n:
                    return out
        raise HostError(f"only {len(out)} of {n} words arrived from engine {eng}")

    # ------------------------------------------------------------------ pin manager (window 0x0200)
    def claim_pad(self, p, eng, od=False, logical=None):
        """uio[p] is driven by engine `eng` (0/1; None releases it). od = open-drain. logical = which of the engine's 8 logical pins
        it carries (default p). Refused while the pad's current owner runs."""
        owner = 0 if eng is None else eng + 1
        remap = 0 if logical is None else (logical ^ p) & 7
        self.write(pad_addr(p), remap << 3 | int(od) << 2 | owner, check=True)

    def claim_uo(self, k, eng, logical=None):
        """uo_out[k] (k = 1..7) carries logical pin `logical` of engine `eng` (shows oe & out); eng None = default function (IRQ/debug)."""
        owner = 0 if eng is None else eng + 1
        remap = 0 if logical is None else (logical ^ k) & 7
        self.write(opad_addr(k), remap << 3 | owner, check=True)

    def select_input(self, eng, logical, phys):
        """Logical input pin of an engine reads physical input phys: 0..7 = uio[0..7], 8..12 = ui_in[3..7]. Engine must be stopped."""
        self.write(isel_addr(eng, logical), phys, check=True)

    def set_misc(self, hold_en=1, trig_en=1, dbg_en=1, view=0, irq_mask=0):
        """MISC: hold_en (ui_in[3] high stops the engines), trig_en, dbg_en (1 = debug view chosen by ui_in[7:5], 0 = by `view`),
        irq_mask (8 bits, which IRQ sources drive uo_out[1]). The three enable bits cannot change while an engine runs."""
        self.write(MISC, irq_mask << 16 | view << 4 | dbg_en << 2 | trig_en << 1 | hold_en, check=True)

    def pad(self, p):
        v = self.read(pad_addr(p))
        return dict(owner=v & 3, od=v >> 2 & 1, remap=v >> 3 & 7)

    def violations(self):
        """(engine 0 mask, engine 1 mask): logical pins a running engine enabled but no pin of its own carries."""
        v = self.read(VIOL)
        return v & 0xFF, v >> 8 & 0xFF

    def clear_violations(self, mask=0xFFFF):
        self.write(VIOL, mask, check=True)

    def irq_status(self):
        v = self.read(IRQ)
        return {n: v >> i & 1 for i, n in enumerate(IRQ_NAMES)}

    def irq_clear(self, mask=0xFF):
        self.write(IRQ, mask, check=True)

    def inputs(self):
        v = self.read(INPUTS)
        return dict(uio_in=v & 0xFF, ui_in_7_3=v >> 8 & 0x1F, hold=v >> 13 & 1)

    # ------------------------------------------------------------------ simulation only (pins around the chip)
    def set_inputs(self, uio_in=0, ui_in_7_3=0):
        self.link.set_inputs(uio_in, ui_in_7_3)

    def pins(self):
        return self.link.pins()

    def wait(self, cycles):
        self.link.wait(cycles)

    def reset(self):
        self.link.reset()


class SimLink:
    """The software SPI master: runs the chip RTL (tt_um_protocol_emulator) in Icarus Verilog through tb/tb_host_bridge.v and
    clocks each frame through the real SCLK/MOSI/CS_N/MISO pins with the SPI timing of the contract (SCLK phase 200 ns =
    10 system clocks, CS_N 100 ns)."""

    SRCS = ["sim/ihp_sram/RM_IHPSG13_1P_core_behavioral_bm_bist.v", "sim/ihp_sram/RM_IHPSG13_1P_256x32_c2_bm_bist.v"]
    SRCS_SHARED = ["sim/ihp_sram/RM_IHPSG13_2P_core_behavioral_bm_bist_ideal.v", "sim/ihp_sram/RM_IHPSG13_2P_512x32_c2_bm_bist.v"]

    def __init__(self, half_ns=200, cs_ns=100, rebuild=None, shared=False):
        """shared=True: the chip with the shared 512-word instruction memory (-DSHARED_IMEM, docs/SHARED_IMEM_PLAN.md)."""
        self.shared = shared
        self.vvp = os.path.join(ROOT, "build", "host", "bridge_shared.vvp" if shared else "bridge.vvp")
        self._build(rebuild)
        self.p = subprocess.Popen(["vvp", "-n", self.vvp], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
                                  cwd=ROOT)
        self._cmd(f"T {int(half_ns)} {int(cs_ns)}")

    def _build(self, rebuild):
        srcs = sorted(f for f in os.listdir(os.path.join(ROOT, "src")) if f.endswith(".v"))
        deps = [os.path.join(ROOT, "src", f) for f in srcs] + [os.path.join(ROOT, "tb", "tb_host_bridge.v"),
                                                              os.path.join(ROOT, "tb", "spi_master.vh")]
        stale = not os.path.exists(self.vvp) or max(os.path.getmtime(d) for d in deps) > os.path.getmtime(self.vvp)
        if rebuild or (rebuild is None and stale):
            os.makedirs(os.path.dirname(self.vvp), exist_ok=True)
            if os.name == "nt" and os.path.isdir(r"C:\iverilog\bin"):
                os.environ["PATH"] += os.pathsep + r"C:\iverilog\bin"
            r = subprocess.run(["iverilog", "-g2012", "-Wno-timescale", "-DFUNCTIONAL"] + (["-DSHARED_IMEM"] if self.shared else []) +
                               ["-I", os.path.join(ROOT, "src"), "-I",
                                os.path.join(ROOT, "tb"), "-o", self.vvp, os.path.join(ROOT, "tb", "tb_host_bridge.v")] +
                               [d for d in deps if d.endswith(".v") and "tb_host_bridge" not in d] +
                               [os.path.join(ROOT, s) for s in (self.SRCS_SHARED if self.shared else self.SRCS)],
                               capture_output=True, text=True)
            if r.returncode:
                raise HostError("iverilog failed:\n" + r.stderr)

    def _cmd(self, line):
        self.p.stdin.write(line + "\n")
        self.p.stdin.flush()
        reply = self.p.stdout.readline().strip()
        if not reply or reply.startswith("ERR"):
            raise HostError(f"simulator: {reply or 'no reply'} (command {line!r})")
        return reply

    def transfer(self, mosi):
        assert len(mosi) == 7
        reply = self._cmd("F " + mosi.hex())
        return bytes.fromhex(reply.split()[1])

    def set_inputs(self, uio_in=0, ui_in_7_3=0):
        self._cmd(f"I {ui_in_7_3 & 0x1F:x} {uio_in & 0xFF:x}")

    def pins(self):
        _, uo, uio, oe, t = self._cmd("G").split()
        return dict(uo_out=int(uo, 16), uio_out=int(uio, 16), uio_oe=int(oe, 16), time_ns=int(t))

    def wait(self, cycles):
        self._cmd(f"W {int(cycles)}")

    def reset(self):
        self._cmd("R")

    # ---- USB low-speed bus model (tb/tb_host_bridge.v): uio[0] = D+, uio[1] = D-, J = idle
    def usb(self, on=True):
        self._cmd(f"U {int(on)}")

    def host_drive(self, dp, dm, oe=1):
        self._cmd(f"B {dp} {dm} {int(oe)}")

    def run_until_change(self, max_clocks):
        """Advance until D+/D- change or max_clocks pass. Returns (clocks run, (dp, dm) now, contention flag)."""
        _, ran, lv, both = self._cmd(f"N {int(max_clocks)}").split()
        return int(ran), (int(lv[0]), int(lv[1])), int(both)

    def close(self):
        try:
            self._cmd("Q")
        except Exception:
            pass
        self.p.stdin.close()
        self.p.wait(timeout=10)

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()


if __name__ == "__main__":
    sys.exit("run host/chip_host_demo.py")
