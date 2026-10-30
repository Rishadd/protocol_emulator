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


def crc16(data, crc=0xFFFF):
    """CRC-16/CCITT-FALSE (poly 0x1021, init 0xFFFF, no reflection, no final XOR) as used by frame v2."""
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = (crc << 1 ^ 0x1021) & 0xFFFF if crc & 0x8000 else (crc << 1) & 0xFFFF
    return crc


OP2_NOP, OP2_WRITE, OP2_READ = 0x80, 0x81, 0x82
CODE_NAMES = {0: "OK", 1: "BUSY", 2: "BAD_ADDR", 3: "BAD_VALUE", 4: "NOT_ALLOWED", 6: "BAD_OP"}
ID_ADDR, VERSION_ADDR, CAP_ADDR, SCRATCH_ADDR, ERRCNT_ADDR = 0x0000, 0x0004, 0x0008, 0x000C, 0x0010


class Result:
    """The 12 bytes the chip returns in a v2 frame: STATUS, the last accepted command's seq, and the result of the previous command."""

    def __init__(self, raw):
        self.raw = bytes(raw)
        self.crc_ok = len(raw) == 12 and crc16(raw[:10]) == int.from_bytes(raw[10:12], "big")
        self.status = Status(raw[0])
        self.last_seq = raw[1]
        self.seq = raw[2]
        self.code = raw[3]
        self.addr = raw[4] | raw[5] << 8
        self.data = int.from_bytes(raw[6:10], "little")

    @property
    def code_name(self):
        return CODE_NAMES.get(self.code, f"code {self.code}")

    def __repr__(self):
        return (f"Result(crc_ok={int(self.crc_ok)} seq={self.seq} {self.code_name} addr=0x{self.addr:04X} data=0x{self.data:08X} "
                f"last_seq={self.last_seq} {self.status})")


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
        self.cmd_seq = None                          # frame v2: sequence number of the last command sent (None: the chip may take any first one)

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

    # ------------------------------------------------------------------ frame v2: CRC-16, sequence numbers, pipelined results
    @staticmethod
    def frame2_bytes(op, seq, addr=0, data=0, rsv=0):
        """The 12 request bytes: op, seq, address (LE), payload (LE), reserved (2), CRC-16 (high byte first) over the first 10."""
        body = bytes([op, seq & 0xFF, addr & 0xFF, addr >> 8 & 0xFF]) + (data & 0xFFFFFFFF).to_bytes(4, "little") + (rsv & 0xFFFF).to_bytes(2, "little")
        return body + crc16(body).to_bytes(2, "big")

    def exchange2(self, raw12):
        """Send 12 bytes (a frame built by frame2_bytes, or any damaged variant), return the parsed Result (crc_ok tells whether the chip's answer is intact)."""
        r = Result(self.link.transfer(raw12))
        self.frames += 1
        self.last_status = r.status
        if self.trace:
            print(f"  [{self.frames:4d}] v2 MOSI {raw12.hex(' ')}\n         MISO {r.raw.hex(' ')}  {r}")
        return r

    def new_seq2(self):
        """The sequence number of the next command: the chip accepts a command only as last + 1 (any value as the very first)."""
        return 0 if self.cmd_seq is None else (self.cmd_seq + 1) & 0xFF

    def nop2(self):
        """A NOP frame: it only fetches the latest result. Its seq differs from the last command's (a NOP must not look like a retry)."""
        return self.frame2_bytes(OP2_NOP, self.new_seq2())

    def resync2(self):
        """Forget the numbering and learn the chip's: after an abandoned command, or when another host talked to the chip before."""
        for _ in range(8):
            r = self.exchange2(self.frame2_bytes(OP2_NOP, 0x55))
            if r.crc_ok:
                self.cmd_seq = r.last_seq
                return r
        raise HostError("frame v2: no intact answer from the chip")

    def fetch2(self, seq, tries=8):
        """NOPs until the chip shows the result of command `seq`; returns it, or None if the chip never accepted that command."""
        for _ in range(tries):
            r = self.exchange2(self.nop2())
            if r.crc_ok:
                return r if r.seq == seq else None
        raise HostError("frame v2: no intact answer from the chip")

    def cmd2(self, op, addr=0, data=0, tries=6):
        """One WRITE / READ with exactly-once semantics, through a damaged link too: send, fetch the result with a NOP, resend the identical
        frame if the chip did not accept it. Returns the Result of this command (code, data)."""
        seq = self.new_seq2()
        frame = self.frame2_bytes(op, seq, addr, data)
        self.cmd_seq = seq
        for _ in range(tries):
            self.exchange2(frame)
            r = self.fetch2(seq)
            if r is not None:
                return r
        raise HostError(f"frame v2: command seq {seq} never accepted (resync2() learns the chip's numbering)")

    def write2(self, addr, data):
        r = self.cmd2(OP2_WRITE, addr, data)
        if r.code not in (0, 1):
            raise HostError(f"write 0x{addr:04X} <- 0x{data:X}: {r.code_name}")
        return r

    def read2(self, addr):
        r = self.cmd2(OP2_READ, addr)
        if r.code not in (0, 1):
            raise HostError(f"read 0x{addr:04X}: {r.code_name}")
        return r.data

    def pipeline2(self, commands):
        """commands: [(op, addr, data)]. One frame per command: each frame carries the next command and returns the previous one's result, so a
        stream of FIFO transfers costs one frame per word. Returns the Results in order. A damaged frame is sent again (identical, so no command
        runs twice and no result is lost)."""
        frames = []                                      # the exact frame of every command, kept for resending
        for op, addr, data in commands:
            seq = self.new_seq2()
            self.cmd_seq = seq
            frames.append((seq, self.frame2_bytes(op, seq, addr, data)))
        results = []
        i = 0
        while i <= len(frames):
            seq, frame = frames[i] if i < len(frames) else (None, self.nop2())
            for _ in range(8):
                r = self.exchange2(frame)
                if r.crc_ok:
                    break
            else:
                raise HostError("frame v2: no intact answer from the chip")
            if i > 0 and r.seq != frames[i - 1][0]:
                i -= 1                                       # the previous frame never arrived (the chip refused this one as a gap): again from there
                continue
            if i > 0 and len(results) == i - 1:              # (after stepping back the result is already recorded)
                results.append(r)
            i += 1
        return results

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

    def __init__(self, half_ns=200, cs_ns=100, rebuild=None, shared=False, la=False, fpga=False):
        """shared=True: the chip with the shared 512-word instruction memory (-DSHARED_IMEM, docs/SHARED_IMEM_PLAN.md)."""
        fpga = fpga or os.environ.get("PE_FPGA") == "1"       # PE_FPGA=1 runs any suite on the DE0-Nano top
        self.fpga = fpga                                 # the DE0-Nano top (src/fpga) with its block-RAM memory instead of the SRAM macro model
        shared = shared or fpga
        self.shared = shared
        self.la = la                                     # -DLA: the logic analyser block (needs the 1P 256x32 buffer macro)
        # PE_SRC_DIR=<dir> simulates another copy of src/ (used by the planted-bug checks), built into its own file
        self.src = os.environ.get("PE_SRC_DIR") or os.path.join(ROOT, "src")
        name = ("bridge_fpga" if fpga else "bridge_shared" if shared else "bridge") + ("_la" if la else "")
        if "PE_SRC_DIR" in os.environ:
            name += "_" + os.path.basename(os.path.normpath(self.src))
        self.vvp = os.path.join(ROOT, "build", "host", name + ".vvp")
        self._build(rebuild)
        self.p = subprocess.Popen(["vvp", "-n", self.vvp], stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True, bufsize=1,
                                  cwd=ROOT)
        self._cmd(f"T {int(half_ns)} {int(cs_ns)}")

    def _build(self, rebuild):
        srcs = sorted(f for f in os.listdir(self.src) if f.endswith(".v"))
        deps = [os.path.join(self.src, f) for f in srcs] + [os.path.join(ROOT, "tb", "tb_host_bridge.v"),
                                                              os.path.join(ROOT, "tb", "spi_master.vh")]
        stale = not os.path.exists(self.vvp) or max(os.path.getmtime(d) for d in deps) > os.path.getmtime(self.vvp)
        if rebuild or (rebuild is None and stale):
            os.makedirs(os.path.dirname(self.vvp), exist_ok=True)
            if os.name == "nt" and os.path.isdir(r"C:\iverilog\bin"):
                os.environ["PATH"] += os.pathsep + r"C:\iverilog\bin"
            r = subprocess.run(["iverilog", "-g2012", "-Wno-timescale", "-DFUNCTIONAL"] + (["-DSHARED_IMEM"] if self.shared else []) + (["-DLA"] if self.la else []) + (["-DFPGA_TOP"] if self.fpga else []) +
                               ["-I", self.src, "-I",
                                os.path.join(ROOT, "tb"), "-o", self.vvp, os.path.join(ROOT, "tb", "tb_host_bridge.v")] +
                               [d for d in deps if d.endswith(".v") and "tb_host_bridge" not in d] +
                               [os.path.join(self.src, "fpga", f) for f in (("de0_nano_chip_top.v", "sram2p_fpga.v") if self.fpga else ())] +
                               [os.path.join(ROOT, s) for s in (() if self.fpga else self.SRCS_SHARED if self.shared else self.SRCS)],
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
        """One frame of any length up to 16 bytes (7 bytes = frame v1, 12 bytes = frame v2)."""
        if len(mosi) == 7:
            reply = self._cmd("F " + mosi.hex())
            return bytes.fromhex(reply.split()[1])
        return self.transfer_bits(8 * len(mosi), int.from_bytes(mosi, "big")).to_bytes(len(mosi), "big")

    def transfer_bits(self, nbits, value):
        """A frame of nbits (up to 128, may be cut mid-byte to test the chip's reaction); returns the nbits seen on MISO as an integer."""
        reply = self._cmd(f"X {nbits} {value:x}")
        return int(reply.split()[1], 16) & ((1 << nbits) - 1)

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
