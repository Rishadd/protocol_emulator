#!/usr/bin/env python3
"""Logic analyser model: the exact behaviour of the capture unit (docs/DEBUG_LA_PLAN.md), one clock at a time, plus the decoder that turns the buffer
words back into a waveform and a VCD writer. The RTL (src/la_unit.v) is checked against this model clock by clock, and the model against the stimulus.

Channels (16, one clock wide, after the 2-flop synchroniser of the chip):
  ch[12:0]  the 13 input-capable pins: uio[7:0] = ch[7:0], ui_in[7:3] = ch[12:8]
  ch[13]    RUN of engine 0         ch[14]  RUN of engine 1
  ch[15]    OR of the two engine trigger lines (a firmware marker appears in the waveform)

Change mode (default): one 32-bit word per change, {value[15:0] at 31:16, delta[15:0] at 15:0}.
  * the first word after arming is the starting state: {ch, 0}
  * a later word is written in the clock a channel differs from the last word's value; delta = clocks since the previous word (1 .. 65535)
  * if 65535 clocks pass without a change, a word with the unchanged value and delta 65535 is written ("overflow word"); the decoder tells it from a change
    because its value equals the previous value (a real change word always differs)
Sample mode: every `div` clocks the 8 channels ch[7:0] (sel = 0) or ch[15:8] (sel = 1) are sampled; four samples make a word, the first at bits [7:0].
Trigger (evaluated every clock while armed, on the full channel vector): pattern (ch & mask) == value, rising / falling edge of channel `chan`, a software trigger
  (the engine trigger lines, i.e. ch[15] rising), or manual. After the trigger the unit writes `post_words` more words (a word written in the trigger clock counts)
  or until `post_clk` clocks have passed, whichever comes first (0 = no limit of that kind); both 0 stops at once. Then it is done and the buffer is frozen.
Buffer: a ring of `depth` words (256 in the chip); the oldest words are overwritten. Readout order: oldest to newest.
Status: state (idle, armed, triggered, done), total words written, write pointer, wrapped, trigger word index (the index of the first word written after the trigger
  decision, i.e. of the first post word) and trigger_cnt (clocks since the previous word at the trigger clock, to place the trigger instant exactly).
"""
import random
import sys

IDLE, ARMED, TRIGGERED, DONE = range(4)
STATE_NAMES = ["idle", "armed", "triggered", "done"]
NCH = 16


class LogicAnalyser:
    def __init__(self, depth=256):
        self.depth = depth
        self.buf = [0] * depth                        # not cleared by an arm: words beyond the write pointer are stale, the readout only uses wp / full
        self.cfg = dict(mode="change", div=1, sel=0, trig="manual", mask=0, value=0, chan=0, post_words=0, post_clk=0)
        self.reset()

    def configure(self, **kw):
        for k in kw:
            assert k in self.cfg, k
        self.cfg.update(kw)

    def reset(self):
        self.state = IDLE
        self.total = 0                  # words written since arming
        self.wp = 0
        self.prev = 0                   # last written value (change mode), last channel vector (edges)
        self.cnt = 0                    # clocks since the last word
        self.have_first = False
        self.phase = 0                  # sample mode: clocks since the last sample
        self.samples = []
        self.trig_index = None
        self.trig_cnt = None
        self.post_w = 0
        self.post_c = 0
        self.last_ch = 0
        self.manual_req = False
        self.wrote = None               # the word written in the last clock, or None

    def arm(self):
        self.reset()
        self.state = ARMED

    def manual(self):
        self.manual_req = True

    # ------------------------------------------------------------------
    def _write(self, word):
        self.wrote = word & 0xFFFFFFFF
        self.buf[self.wp] = word & 0xFFFFFFFF
        self.wp = (self.wp + 1) % self.depth
        self.total += 1
        if self.state == TRIGGERED:
            self.post_w += 1

    def _triggered(self, ch):
        c = self.cfg
        t = c["trig"]
        old = self.last_ch
        if self.manual_req:
            return True
        if t == "manual":
            return False
        if t == "pattern":
            return (ch & c["mask"]) == (c["value"] & c["mask"])
        if t == "rise":
            return not (old >> c["chan"] & 1) and bool(ch >> c["chan"] & 1)
        if t == "fall":
            return bool(old >> c["chan"] & 1) and not (ch >> c["chan"] & 1)
        if t == "sw":
            return not (old >> 15 & 1) and bool(ch >> 15 & 1)
        raise ValueError(t)

    def clock(self, ch, arm=False, manual=False):
        """One clock as the registered RTL sees it: the strobes act at the clock they are given, the effect of `arm` starts with the next clock (this
        clock records nothing, the channel vector is only remembered for edge detection); `manual` is a trigger in this clock and does nothing unless armed."""
        ch &= 0xFFFF
        self.wrote = None
        if arm:
            self.arm()
            self.last_ch = ch
            return self.state
        if manual and self.state == ARMED:
            self.manual_req = True
        return self.step(ch)

    def step(self, ch):
        """One clock with channel vector ch (16 bits). Returns the state after the clock."""
        ch &= 0xFFFF
        self.wrote = None
        if self.state in (IDLE, DONE):
            self.last_ch = ch
            return self.state
        c = self.cfg
        # --- trigger decision first: a word written in this clock already counts as a post-trigger word
        if self.state == ARMED and self._triggered(ch):
            self.state = TRIGGERED
            self.trig_index = self.total
            self.trig_cnt = self.cnt + (1 if self.have_first else 0)    # clocks since the previous word at this clock (the clock counter has not advanced yet)
            self.post_w = 0
            self.post_c = 0
            self.manual_req = False
        # --- record
        if c["mode"] == "change":
            if not self.have_first:
                self._write((ch << 16) | 0)
                self.prev, self.cnt, self.have_first = ch, 0, True
            else:
                self.cnt += 1
                if ch != self.prev:
                    self._write((ch << 16) | self.cnt)
                    self.prev, self.cnt = ch, 0
                elif self.cnt == 0xFFFF:
                    self._write((self.prev << 16) | 0xFFFF)
                    self.cnt = 0
        else:                                                     # sample mode
            if not self.have_first:
                self.have_first = True
                self.phase = 0
            if self.phase == 0:
                self.samples.append((ch >> (8 * c["sel"])) & 0xFF)
                if len(self.samples) == 4:
                    w = sum(s << (8 * i) for i, s in enumerate(self.samples))
                    self._write(w)
                    self.samples = []
            self.phase = (self.phase + 1) % c["div"]
        # --- post-trigger accounting: the unit stops when the post limit is reached
        if self.state == TRIGGERED:
            self.post_c += 1
            stop_w = c["post_words"] == 0 and c["post_clk"] == 0
            if stop_w or (c["post_words"] and self.post_w >= c["post_words"]) or (c["post_clk"] and self.post_c >= c["post_clk"]):
                self.state = DONE
        self.last_ch = ch
        return self.state

    # ------------------------------------------------------------------ readout
    @property
    def wrapped(self):
        return self.total > self.depth

    @property
    def full(self):
        return self.total >= self.depth

    @property
    def trig_wp(self):
        return None if self.trig_index is None else self.trig_index % self.depth

    def words(self):
        """The buffer, oldest word first."""
        n = min(self.total, self.depth)
        if self.total <= self.depth:
            return self.buf[:n]
        return self.buf[self.wp:] + self.buf[:self.wp]

    def status(self):
        return dict(state=STATE_NAMES[self.state], total=self.total, wp=self.wp, wrapped=self.wrapped,
                    trig_index=self.trig_index, trig_cnt=self.trig_cnt)


# ---------------------------------------------------------------------- decoding
def decode_change(words):
    """Change-mode words (oldest first) -> [(t, value)]: t in clocks from the first word, value valid from t on. Overflow words only advance time."""
    out, t, prev = [], 0, None
    for i, w in enumerate(words):
        v, d = w >> 16 & 0xFFFF, w & 0xFFFF
        if i == 0:
            out.append((0, v))                                    # the first word's delta refers to a word that is no longer in the buffer
            prev = v
            continue
        t += d
        if v != prev:
            out.append((t, v))
            prev = v
    end = t
    return out, end


def decode_sample(words, div, sel=0):
    """Sample-mode words -> [(t, byte)] one per sample, t in clocks from the first sample."""
    out = []
    for i, w in enumerate(words):
        for k in range(4):
            out.append(((i * 4 + k) * div, w >> (8 * k) & 0xFF))
    return out


def vcd(changes, end, names=None, timescale_ns=20, path=None):
    """[(t, value16)] -> VCD text (also written to path)."""
    names = names or [f"ch{i}" for i in range(NCH)]
    ids = [chr(33 + i) for i in range(NCH)]
    lines = [f"$timescale {timescale_ns}ns $end", "$scope module la $end"]
    lines += [f"$var wire 1 {ids[i]} {names[i]} $end" for i in range(NCH)]
    lines += ["$upscope $end", "$enddefinitions $end"]
    prev = None
    for t, v in changes:
        lines.append(f"#{t}")
        for i in range(NCH):
            b = v >> i & 1
            if prev is None or (prev >> i & 1) != b:
                lines.append(f"{b}{ids[i]}")
        prev = v
    lines.append(f"#{end}")
    text = "\n".join(lines) + "\n"
    if path:
        open(path, "w").write(text)
    return text


def parse_vcd(text):
    """Minimal VCD reader for the round-trip test: -> ([(t, value16)], last time)."""
    ids, cur, out, t, last = {}, 0, [], 0, 0
    pending = False
    for ln in text.splitlines():
        if ln.startswith("$var"):
            p = ln.split()
            ids[p[3]] = int(p[4][2:])
        elif ln.startswith("#"):
            if pending:
                out.append((t, cur))
                pending = False
            t = int(ln[1:])
            last = t
        elif ln and ln[0] in "01" and ln[1:] in ids:
            bit = ids[ln[1:]]
            cur = (cur & ~(1 << bit)) | (int(ln[0]) << bit)
            pending = True
    if pending:
        out.append((t, cur))
    return out, last


# ---------------------------------------------------------------------- self test
def activity(rnd, n, burst=0.1, quiet=0.0, start=0):
    """n clocks of channel vectors: long quiet runs and bursts of single-bit and multi-bit changes."""
    v, out = start, []
    mode_len = 0
    active = True
    for _ in range(n):
        if mode_len == 0:
            active = rnd.random() < 0.55
            mode_len = rnd.choice([1, 3, 10, 40, 200, 700])
        mode_len -= 1
        if active and rnd.random() < (0.5 if rnd.random() < 0.5 else burst * 3):
            v = v ^ (1 << rnd.randrange(NCH)) if rnd.random() < 0.8 else rnd.getrandbits(16)
        out.append(v)
    return out


def selftest():
    errs = 0

    def check(name, cond):
        nonlocal errs
        if not cond:
            errs += 1
            print("  FAIL", name)

    # --- hand-checked: a UART-like waveform, no wrap, manual trigger after 12 clocks, then stop after 3 more words
    la = LogicAnalyser(depth=16)
    la.configure(trig="manual", post_words=3)
    la.arm()
    stim = [0, 0, 1, 1, 1, 0, 0, 2, 2, 2, 2, 3, 3, 1, 0, 0]
    for i, v in enumerate(stim):
        if i == 6:
            la.manual()
        la.step(v)
    check("hand: words", la.words() == [0x00000000, 0x00010002, 0x00000003, 0x00020002, 0x00030004, 0x00010002])
    ch, end = decode_change(la.words())
    # stim changes at clocks 2 (1), 5 (0), 7 (2), 11 (3), 13 (1) -> the state at clock 0 is 0
    check("hand: decoded changes", ch[:4] == [(0, 0), (2, 1), (5, 0), (7, 2)])
    check("hand: done after 3 post words", la.state == DONE and la.post_w == 3)
    check("hand: trigger index and clock count", la.trig_index == 3 and la.trig_cnt == 1)

    # --- overflow word: 70000 quiet clocks
    la = LogicAnalyser(depth=16)
    la.configure(trig="manual", post_words=1)
    la.arm()
    la.step(5)
    for _ in range(70000):
        la.step(5)
    la.manual()
    la.step(9)
    ch, end = decode_change(la.words())
    check("overflow: one overflow word, then the change at the right time", [w & 0xFFFF for w in la.words()] == [0, 0xFFFF, 70001 - 65535] and ch == [(0, 5), (70001, 9)])

    # --- random: capture of random activity, every trigger type, ring wrap, decoded window must equal the stimulus
    rnd = random.Random(7)
    for trial in range(300):
        depth = rnd.choice([8, 16, 64])
        n = rnd.choice([200, 2000, 9000])
        stim = activity(rnd, n, start=rnd.getrandbits(16))
        trig = rnd.choice(["manual", "pattern", "rise", "fall", "sw"])
        cfg = dict(trig=trig, mask=rnd.choice([0x1, 0x3, 0xF0, 0xFFFF]), value=rnd.getrandbits(16), chan=rnd.randrange(16),
                   post_words=rnd.choice([0, 1, 5, 40, 1000]), post_clk=rnd.choice([0, 0, 0, 30, 3000]))
        la = LogicAnalyser(depth=depth)
        la.configure(**cfg)
        arm_clk = rnd.randrange(0, n // 2)
        man = rnd.randrange(arm_clk, n)
        trig_clk = None
        done_clk = None
        for t in range(n):
            if t == arm_clk:
                la.arm()
            if trig == "manual" and t == man:
                la.manual()
            before = la.state
            la.step(stim[t])
            if t >= arm_clk and before == ARMED and la.state in (TRIGGERED, DONE) and trig_clk is None:
                trig_clk = t
            if t >= arm_clk and la.state == DONE and done_clk is None:
                done_clk = t
        words = la.words()
        if not words:
            continue
        ch, end = decode_change(words)
        # independent reference: replay the stimulus with the spec's rule (a word on every change and every 65535 quiet clocks) and keep the last len(words)
        stop_clk = done_clk if done_clk is not None else n - 1
        wcl = [arm_clk]
        c, pv = 0, stim[arm_clk]
        for t_ in range(arm_clk + 1, stop_clk + 1):
            c += 1
            if stim[t_] != pv:
                wcl.append(t_)
                pv, c = stim[t_], 0
            elif c == 0xFFFF:
                wcl.append(t_)
                c = 0
        wcl_all = list(wcl)
        wcl = wcl[-len(words):]
        base = wcl[0]
        ok = len(wcl) == len(words)
        for t_ in range(base, wcl[-1] + 1):          # the decoded waveform must equal the stimulus at every clock of the window
            val = None
            for tt, vv in ch:
                if tt <= t_ - base:
                    val = vv
            if val != stim[t_]:
                ok = False
                break
        check(f"random trial {trial} ({trig}, depth {depth}): decoded waveform equals the stimulus", ok)
        if trig_clk is not None and la.trig_index:                  # the trigger instant: the word before the first post word, plus the clocks since it
            check(f"random trial {trial}: trigger position", wcl_all[la.trig_index - 1] + la.trig_cnt == trig_clk)
        text = vcd(ch, end)                                          # the waveform survives the VCD file
        back, _ = parse_vcd(text)
        want = []
        for tt, vv in ch:
            if not want or want[-1][1] != vv:
                want.append((tt, vv))
        check(f"random trial {trial}: VCD round trip", back == want)
    # --- sample mode
    rnd = random.Random(11)
    for trial in range(40):
        div = rnd.choice([1, 2, 3, 7])
        stim = activity(rnd, 4000)
        la = LogicAnalyser(depth=32)
        la.configure(mode="sample", div=div, sel=rnd.choice([0, 1]), trig="manual", post_words=10)
        la.arm()
        man = rnd.randrange(100, 3000)
        for t in range(4000):
            if t == man:
                la.manual()
            la.step(stim[t])
        s = decode_sample(la.words(), div)
        sel = la.cfg["sel"]
        # the first sample sits at the first sampling clock: clock 0 (arm clock), then every div clocks; the words keep the newest 32*4 samples
        allsamples = [(stim[t] >> (8 * sel)) & 0xFF for t in range(0, 4000, div)]
        got = [b for _, b in s]
        # find the window
        found = False
        for off in range(0, len(allsamples) - len(got) + 1):
            if allsamples[off:off + len(got)] == got:
                found = True
                break
        check(f"sample trial {trial}: samples are a contiguous window of the stimulus", found)
    print(f"RESULT la_model selftest: {'PASS' if not errs else 'FAIL (%d)' % errs}")
    return errs


if __name__ == "__main__":
    sys.exit(1 if selftest() else 0)
