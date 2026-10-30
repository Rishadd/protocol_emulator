"""Figures: logic analyser, GTKWave guide, engine debug, troubleshooting, verification; plus the capture example rendered from host/la_model.py."""
import math
import os
import sys

from svg import Svg, MUT, INK


def la_workflow(out):
    s = Svg(1000, 230, "Logic analyser workflow")
    steps = [("1 Configure", "mode, trigger,|post-trigger amount", "blue"), ("2 Arm", "recording starts|into the ring buffer", "green"), ("3 Trigger", "the event you chose|happens", "orange"),
             ("4 Post-trigger", "keeps recording,|then freezes", "yellow"), ("5 Read", "words and status|over the link", "purple"), ("6 Export", "VCD file|(la_capture.py)", "grey"), ("7 View", "GTKWave", "teal")]
    w = 120
    for i, (a, b, c) in enumerate(steps):
        x = 20 + i * 138
        s.rect(x, 60, w, 100, c, 8)
        s.text(x + w / 2, 86, a, 13, weight="bold")
        s.lines(x + w / 2, 110, b.split("|"), 10, gap=14, fill=MUT)
        if i < len(steps) - 1:
            s.line(x + w, 110, x + 138, 110, arrow=True)
    s.text(500, 30, "the chip does steps 2 to 4 on its own; the host only configures, waits and reads", 12, fill=MUT)
    s.text(500, 200, "the interrupt output (or polling the state) tells the host that step 4 has finished", 11, fill=MUT)
    s.save(os.path.join(out, "fig_la_workflow.svg"))


def la_channels(out):
    s = Svg(980, 230, "Logic analyser channels")
    for i in range(16):
        x = 20 + i * 59
        col = "green" if i < 8 else "blue" if i < 13 else "orange" if i < 15 else "yellow"
        s.rect(x, 70, 54, 70, col, 5)
        s.text(x + 27, 92, f"ch{i}", 12, weight="bold")
    for i in range(8):
        s.text(20 + i * 59 + 27, 118, f"uio[{i}]", 10, fill=MUT)
    for i in range(8, 13):
        s.text(20 + i * 59 + 27, 118, f"ui_in[{i - 5}]", 10, fill=MUT)
    s.text(20 + 13 * 59 + 27, 118, "RUN 0", 10, fill=MUT)
    s.text(20 + 14 * 59 + 27, 118, "RUN 1", 10, fill=MUT)
    s.text(20 + 15 * 59 + 27, 112, "marker", 10, fill=MUT)
    s.text(20 + 15 * 59 + 27, 126, "(firmware)", 9, fill=MUT)
    s.text(490, 40, "16 channels, one clock wide, sampled after the same two-flop synchroniser the engines use", 13, weight="bold")
    s.text(490, 180, "13 pins + the RUN state of both engines + one marker line that firmware can set to flag an event in the waveform", 12, fill=MUT)
    s.save(os.path.join(out, "fig_la_channels.svg"))


def la_words(out):
    s = Svg(940, 360, "Logic analyser word formats")
    def row(y, title, labs, ws, cols):
        s.text(20, y - 12, title, 13, "start", "bold")
        x = 20
        for lab, w, c in zip(labs, ws, cols):
            s.rect(x, y, w, 46, c, 3, sw=1.3)
            s.lines(x + w / 2, y + 20, lab.split("|"), 11, gap=14)
            x += w
    row(60, "change mode: one word per change", ["channel values after the change|bits 31 .. 16", "clocks since the previous word|bits 15 .. 0"], [450, 450], ["blue", "orange"])
    row(150, "overflow word (65 535 quiet clocks)", ["same values as before|bits 31 .. 16", "0xFFFF|bits 15 .. 0"], [450, 450], ["blue", "grey"])
    row(240, "sample mode: four samples per word", ["sample 3|bits 31 .. 24", "sample 2|bits 23 .. 16", "sample 1|bits 15 .. 8", "sample 0|bits 7 .. 0"], [225, 225, 225, 225], ["green", "green", "green", "green"])
    s.text(470, 332, "the first word after arming is the starting state (delta 0); a word whose values equal the previous ones is an overflow word, never a change", 11, fill=MUT)
    s.save(os.path.join(out, "fig_la_words.svg"))


def la_states(out):
    s = Svg(900, 300, "Logic analyser states")
    names = [("Idle", "not recording", "grey"), ("Armed", "recording,|waiting for the trigger", "green"), ("Triggered", "recording the|post-trigger part", "orange"), ("Done", "buffer frozen,|ready to read", "blue")]
    for i, (a, b, c) in enumerate(names):
        x = 40 + i * 215
        s.rect(x, 90, 160, 80, c, 10)
        s.text(x + 80, 118, a, 14, weight="bold")
        s.lines(x + 80, 138, b.split("|"), 10, gap=13, fill=MUT)
        if i < 3:
            s.line(x + 160, 130, x + 215, 130, arrow=True)
    s.text(40 + 215 + 160 + 27, 120, "trigger", 11, fill=INK)
    s.text(40 + 160 + 27, 120, "arm", 11, fill=INK)
    s.text(40 + 2 * 215 + 160 + 27, 120, "post limit", 11, fill=INK)
    s.path("M 735 170 L 735 230 L 120 230 L 120 172", "#5c6670", 1.4, arrow=True, dash="4 3")
    s.text(430, 248, "arm again: clears the pointers and starts over (also possible from Armed and Triggered)", 11, fill=MUT)
    s.text(450, 40, "manual trigger and the firmware marker work like any other trigger", 11, fill=MUT)
    s.save(os.path.join(out, "fig_la_states.svg"))


def wedge(cx, cy, r1, r2, a0, a1):
    def p(r, a):
        return cx + r * math.cos(a), cy + r * math.sin(a)
    x0, y0 = p(r2, a0); x1, y1 = p(r2, a1); x2, y2 = p(r1, a1); x3, y3 = p(r1, a0)
    return f"M {x0:.1f} {y0:.1f} A {r2} {r2} 0 0 1 {x1:.1f} {y1:.1f} L {x2:.1f} {y2:.1f} A {r1} {r1} 0 0 0 {x3:.1f} {y3:.1f} Z"


def la_ring(out):
    s = Svg(900, 420, "Ring buffer and trigger position")
    cx, cy, n = 260, 215, 16
    trig = 11
    for i in range(n):
        a0 = -math.pi / 2 + i * 2 * math.pi / n
        a1 = a0 + 2 * math.pi / n - 0.03
        fill = "#fde8d0" if i >= trig else "#dbe8fb"
        stroke = "#c46a12" if i >= trig else "#2a5db0"
        s.items.append(f'<path d="{wedge(cx, cy, 80, 160, a0, a1)}" fill="{fill}" stroke="{stroke}" stroke-width="1.4"/>')
    s.text(cx, cy - 6, "256 words", 14, weight="bold")
    s.text(cx, cy + 14, "(ring)", 11, fill=MUT)
    am = -math.pi / 2 + trig * 2 * math.pi / n
    s.line(cx + 70 * math.cos(am), cy + 70 * math.sin(am), cx + 190 * math.cos(am), cy + 190 * math.sin(am), "#b32d2d", 2.4)
    s.text(cx + 214 * math.cos(am), cy + 214 * math.sin(am) + 4, "trigger", 12, "middle", "bold", fill="#b32d2d")
    s.text(560, 70, "how to read it", 14, "start", "bold")
    s.lines(560, 100, ["Blue: words recorded before the trigger (history).", "Orange: words recorded after the trigger.",
                       "The write pointer moves round the ring; when it is full,", "the oldest words are overwritten.",
                       "", "Status gives: write pointer, whether the ring wrapped,", "the trigger word index and the clocks since the", "previous word at the trigger."], 12, "start", gap=21)
    s.text(560, 330, "read the buffer oldest first:", 12, "start", "bold")
    s.lines(560, 352, ["if it wrapped, start at the write pointer;", "if not, start at word 0"], 12, "start", gap=19, fill=MUT)
    s.save(os.path.join(out, "fig_la_ring.svg"))


def gtkwave_layout(out):
    s = Svg(940, 520, "GTKWave window")
    s.rect(30, 30, 880, 460, "grey", 8)
    s.rect(30, 30, 880, 28, "white", 8); s.text(60, 49, "File   Edit   Search   Time   Markers   View   Help", 12, "start")
    s.rect(30, 58, 880, 34, "blue", 0); s.text(60, 80, "[open]   [zoom in]  [zoom out]  [zoom fit]  [zoom to marker]  |  from  to  marker", 11, "start")
    s.rect(40, 100, 160, 330, "white", 4); s.text(120, 120, "SST (hierarchy)", 11, weight="bold"); s.text(60, 146, "- la", 11, "start"); s.text(76, 166, "ch0 .. ch15", 10, "start", fill=MUT)
    s.rect(40, 436, 160, 44, "yellow", 4); s.text(120, 462, "Append / Insert", 11)
    s.rect(210, 100, 190, 380, "white", 4); s.text(305, 120, "Signals", 11, weight="bold")
    names = ["ch0  uio[0]", "ch1  uio[1]", "ch2  uio[2]", "ch13 RUN 0", "ch15 marker"]
    for i, n in enumerate(names):
        s.text(225, 150 + i * 36, n, 11, "start")
    s.rect(410, 100, 490, 380, "grey", 4, fill="#111418", stroke="#2b3238")
    x0 = 430
    for i in range(5):
        y = 150 + i * 36
        bits = [1, 1, 0, 0, 1, 1, 1, 0, 1, 0][:10] if i % 2 == 0 else [0, 0, 1, 1, 1, 0, 0, 1, 1, 1]
        s.signal(x0, y + 8, bits, 44, 16, color="#4ade80", sw=1.8)
    s.text(655, 462, "Waves", 11, fill="#9aa5b1")
    marks = [("1", 40, 440, "open the .vcd file"), ("2", 130, 146, "pick the signals in the tree"), ("3", 125, 446, "Append them to the signal list"),
             ("4", 262, 76, "Zoom Fit to see the whole capture"), ("5", 780, 190, "click in the wave area, then use Markers to read times")]
    for n, x, y, txt in marks:
        s.circle(x, y, 11, "red"); s.text(x, y + 4, n, 11, weight="bold", fill="#b32d2d")
    for i, (n, x, y, txt) in enumerate(marks):
        s.text(40, 508 - 0, "", 1)
    s.lines(40, 510, [""], 1)
    s.text(470, 512, "1 open the file   2 select signals   3 append   4 zoom fit   5 markers measure times (one tick = one chip clock)", 11, fill=MUT)
    s.save(os.path.join(out, "fig_gtkwave_layout.svg"))


def debug_overview(out):
    s = Svg(900, 360, "Engine debug and sniffer")
    s.box(40, 40, 180, 90, "Host (Pico)", ["over the management link"], "green")
    s.box(360, 40, 220, 90, "Debug registers", ["halt, step, breakpoint,", "read-back"], "teal")
    s.box(360, 190, 220, 90, "Engine", ["program counter, registers,", "FIFOs, flags"], "blue")
    s.box(680, 190, 190, 90, "Sniffer image", ["decodes a bus it does", "not drive"], "purple")
    s.box(680, 40, 190, 90, "Logic analyser", ["trigger on a", "protocol event"], "yellow")
    s.line(220, 85, 360, 85, arrow=True, both=True)
    s.line(470, 130, 470, 190, arrow=True, both=True)
    s.line(580, 235, 680, 235, arrow=True, both=True)
    s.line(775, 190, 775, 130, arrow=True)
    s.text(470, 320, "planned: single step, breakpoint and state read-back are Phase 4, sniffer images Phase 5", 12, fill=MUT)
    s.save(os.path.join(out, "fig_debug_overview.svg"))


def troubleshoot_link(out):
    s = Svg(640, 620, "No response on the management link")
    def b(y, lines, col="blue"):
        s.rect(180, y, 280, 50, col, 8)
        s.lines(320, y + 22, lines, 12, gap=15)
    def d(y, lines):
        s.poly([(320, y), (450, y + 38), (320, y + 76), (190, y + 38)], "yellow")
        s.lines(320, y + 34, lines, 11, gap=14)
    b(20, ["No answer on MISO", "(always 0, or unchanged)"], "red")
    s.line(320, 70, 320, 92, arrow=True)
    d(92, ["clk present at the", "chip pin?"])
    s.line(320, 168, 320, 196, arrow=True); s.text(332, 188, "yes", 11, "start", fill=MUT)
    d(196, ["rst_n released", "(high)?"])
    s.line(320, 272, 320, 300, arrow=True); s.text(332, 292, "yes", 11, "start", fill=MUT)
    d(300, ["SPI mode 0, SCLK <", "clk / 16, CS_N active low?"])
    s.line(320, 376, 320, 404, arrow=True); s.text(332, 396, "yes", 11, "start", fill=MUT)
    d(404, ["wiring: SCLK, MOSI,", "MISO, CS_N on the", "right pins?"])
    s.line(320, 480, 320, 510, arrow=True); s.text(332, 502, "yes", 11, "start", fill=MUT)
    b(510, ["read ID (0x0000):", "expect PEM1"], "green")
    for y in (130, 234, 338, 442):
        s.line(190, y, 100, y, arrow=True, color="#b32d2d")
        s.text(145, y - 6, "no", 11, fill="#b32d2d")
    s.rect(10, 120, 90, 340, "orange", 8, dash="5 3")
    s.lines(55, 280, ["fix it", "(clock,", "reset,", "mode,", "speed,", "wiring)", "and retry"], 11, gap=16)
    s.save(os.path.join(out, "fig_troubleshoot_link.svg"))


def verification_layers(out):
    s = Svg(900, 400, "How the chip was verified")
    layers = [("Formal proofs", "pin ownership, memory window and lock rules hold for every input", "purple", 300),
              ("Planted-bug checks", "bugs are inserted on purpose: every test must fail", "red", 400),
              ("Differential tests", "random programs: the chip logic against a cycle-exact model", "orange", 500),
              ("Peer-model protocol tests", "every protocol against an independently written other side", "green", 600),
              ("Unit tests", "each block on its own", "blue", 700)]
    for i, (a, b, c, w) in enumerate(layers):
        x = 450 - w / 2
        s.rect(x, 30 + i * 66, w, 56, c, 8)
        s.text(450, 56 + i * 66, a, 14, weight="bold")
        s.text(450, 74 + i * 66, b, 11, fill=MUT)
    s.text(450, 378, "each layer checks something the others cannot", 12, fill=MUT)
    s.save(os.path.join(out, "fig_verification_layers.svg"))


def capture_example(out):
    """A real capture produced by host/la_model.py: UART byte 0x41 on channel 0, RUN 0 on channel 13, a firmware marker on channel 15; rendered GTKWave-style."""
    here = os.path.dirname(os.path.abspath(__file__))
    for d in (os.environ.get("LA_MODEL_DIR", ""), os.path.join(here, "..", "..", "host"), os.path.expanduser("~/pe_shared_v2/host")):
        if d and os.path.exists(os.path.join(d, "la_model.py")):
            sys.path.insert(0, d)                          # host/la_model.py (on the shared-memory branch until it is merged)
            break
    import la_model as LM
    bit = 16
    byte = [0] + [(0x41 >> i) & 1 for i in range(8)] + [1]
    stim, marker_clk = [], None
    ch0 = [1] * 40
    for b in byte:
        ch0 += [b] * bit
    ch0 += [1] * 60
    n = len(ch0)
    for c in range(n):
        v = ch0[c]
        v |= 1 << 13                                   # engine 0 is running
        if 38 <= c < 42:
            v |= 1 << 15                               # the firmware marks the moment it starts sending
        stim.append(v)
    la = LM.LogicAnalyser(depth=256)
    la.configure(trig="fall", chan=0, post_words=12, post_clk=0)
    for c in range(n):
        la.clock(stim[c], arm=(c == 0))
    words = la.words()
    changes, end = LM.decode_change(words)
    vcd_path = os.path.join(out, "example_capture.vcd")
    names = [f"uio_{i}" for i in range(8)] + [f"ui_in_{i}" for i in range(3, 8)] + ["run0", "run1", "marker"]
    LM.vcd(changes, end, names=names, path=vcd_path)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(11, 3.4), dpi=110)
    fig.patch.set_facecolor("#111418"); ax.set_facecolor("#111418")
    show = [(0, "uio_0 (TX)"), (13, "run0"), (15, "marker")]
    for row, (chn, name) in enumerate(show):
        ys = []
        ts = []
        prev = None
        for t, v in changes:
            bit_v = v >> chn & 1
            if prev is not None:
                ts += [t]; ys += [prev]
            ts += [t]; ys += [bit_v]
            prev = bit_v
        ts += [end]; ys += [prev]
        base = (len(show) - 1 - row) * 1.7
        ax.step(ts, [base + 1.0 * y for y in ys], where="post", color="#4ade80", lw=1.8)
        ax.text(-end * 0.015, base + 0.5, name, color="#e4e7ea", ha="right", va="center", fontsize=9)
    ax.set_xlim(0, end); ax.set_ylim(-0.4, 5.4)
    ax.set_yticks([]); ax.tick_params(colors="#98a2ad", labelsize=8)
    for sp in ax.spines.values():
        sp.set_color("#2b3238")
    ax.set_xlabel("time in chip clocks since the first word of the capture (1 clock = 20 ns at 50 MHz)", color="#98a2ad", fontsize=8)
    ax.axvline(40, color="#facc15", lw=1, ls="--"); ax.text(42, 5.0, "trigger: start bit", color="#facc15", fontsize=8)
    for i, lab in enumerate(["start", "D0", "D1", "D2", "D3", "D4", "D5", "D6", "D7", "stop"]):
        ax.text(40 + i * bit + bit / 2, 4.55, lab, color="#98a2ad", fontsize=7, ha="center")
        ax.axvline(40 + i * bit, color="#2b3238", lw=0.8)
    fig.subplots_adjust(left=0.12, right=0.99, top=0.96, bottom=0.2)
    fig.savefig(os.path.join(out, "fig_la_capture_example.png"), facecolor=fig.get_facecolor())
    plt.close(fig)
    print("capture example:", len(words), "words,", len(changes), "changes, span", end, "clocks")


def all_figs(out):
    la_workflow(out)
    la_channels(out)
    la_words(out)
    la_states(out)
    la_ring(out)
    gtkwave_layout(out)
    debug_overview(out)
    troubleshoot_link(out)
    verification_layers(out)
    try:
        capture_example(out)
    except ImportError as e:
        print("capture example skipped:", e)
