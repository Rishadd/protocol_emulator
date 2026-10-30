"""Figures: link timing and frames, address map, pins, memory, engine, instruction timing, protocol waveforms."""
import os

from svg import Svg, MUT, INK


def cells(s, x, y, labels, widths, colors, h=44, size=11):
    for lab, w, c in zip(labels, widths, colors):
        s.rect(x, y, w, h, c, 3, sw=1.3)
        s.lines(x + w / 2, y + h / 2 - (len(lab.split("|")) - 1) * 6 + 4, lab.split("|"), size, gap=13)
        x += w
    return x


def spi_mode0(out):
    s = Svg(900, 360, "Management link: SPI mode 0")
    x0, t = 130, 28
    cs = [1, 1] + [0] * 22 + [1, 1]
    n = len(cs)
    sclk = [0] * 4 + [0, 1] * 8 + [0] * (n - 20)
    def data(bits):
        a = [0] * 4
        for b in bits:
            a += [b, b]
        return a + [0] * (n - len(a))
    mosi = data([1, 0, 1, 0, 0, 1, 0, 1])
    miso = data([0, 1, 1, 0, 1, 0, 0, 1])
    for name, bits, y in (("CS_N", cs, 60), ("SCLK", sclk, 120), ("MOSI", mosi, 180), ("MISO", miso, 240)):
        s.signal(x0, y, bits, t, 24, name)
    for i in range(8):
        xc = x0 + (4 + 2 * i + 1) * t
        s.text(xc, 276, str(7 - i), 11, fill=MUT)
        s.line(xc, 36, xc, 262, "#9aa5b1", 1, dash="3 4")
    s.text(x0 + 5.5 * t, 296, "bits are sampled on the rising edge, most significant bit first", 11, "start", fill=MUT)
    s.line(x0 + 2 * t, 24, x0 + 5 * t, 24, arrow=True, both=True)
    s.text(x0 + 3.5 * t, 18, "CS_N low to first edge: >= 4 clocks", 10, fill=INK)
    s.line(x0 + 5 * t, 98, x0 + 7 * t, 98, arrow=True, both=True)
    s.text(x0 + 6 * t, 92, "each phase >= 8 clocks", 10, fill=INK, anchor="start")
    s.text(450, 336, "chip clocks, not SCLK periods: at 50 MHz SCLK can be up to about 3 MHz", 11, fill=MUT)
    s.save(os.path.join(out, "fig_spi_mode0.svg"))


def frame_formats(out):
    s = Svg(960, 470, "Management frame formats")
    bw = 52
    rows = [
        ("v1 request", "host to chip, 7 bytes", ["op|01 / 02", "address|high, low", "data (4 bytes, high byte first)"], [bw, 2 * bw, 4 * bw], ["orange", "blue", "green"]),
        ("v1 reply", "chip to host, 7 bytes", ["STATUS", "00 00", "read data (4 bytes)"], [bw, 2 * bw, 4 * bw], ["yellow", "grey", "green"]),
        ("v2 request", "host to chip, 12 bytes", ["op|80/81/82", "seq", "address|(low, high)", "data (4 bytes, low byte first)", "reserved|(00 00)", "CRC-16|(high, low)"],
         [bw, bw, 2 * bw, 4 * bw, 2 * bw, 2 * bw], ["orange", "purple", "blue", "green", "grey", "red"]),
        ("v2 reply", "chip to host, 12 bytes", ["STATUS", "last|seq", "seq", "result|code", "address|(low, high)", "data (4 bytes, low byte first)", "CRC-16"],
         [bw, bw, bw, bw, 2 * bw, 4 * bw, 2 * bw - 0], ["yellow", "purple", "purple", "teal", "blue", "green", "red"]),
    ]
    for i, (name, sub, labs, ws, cols) in enumerate(rows):
        y = 40 + i * 105
        s.text(20, y + 18, name, 13, "start", "bold")
        s.text(20, y + 34, sub, 10, "start", fill=MUT)
        x = cells(s, 190, y, labs, ws, cols)
        for k in range(sum(ws) // bw + 1):
            s.text(190 + k * bw + bw / 2, y + 62, str(k) if k < sum(ws) // bw else "", 9, fill=MUT)
    s.text(480, 456, "bytes are numbered from 0 (the first byte on the wire); CRC-16/CCITT-FALSE covers the first 10 bytes", 11, fill=MUT)
    s.save(os.path.join(out, "fig_frame_formats.svg"))


def status_byte(out):
    s = Svg(780, 190, "STATUS byte")
    labs = ["alive|(always 1)", "error|(sticky)", "RUN|engine 1", "RUN|engine 0", "TX FIFO full|engine 1", "TX FIFO full|engine 0", "RX data|engine 1", "RX data|engine 0"]
    for i, lab in enumerate(labs):
        x = 30 + i * 90
        s.rect(x, 60, 90, 60, ["yellow", "red", "green", "green", "orange", "orange", "blue", "blue"][i], 3, sw=1.3)
        s.lines(x + 45, 86, lab.split("|"), 11, gap=14)
        s.text(x + 45, 50, f"bit {7 - i}", 11, fill=MUT)
    s.text(390, 150, "returned in every frame, so one frame tells you the state of both engines", 11, fill=MUT)
    s.save(os.path.join(out, "fig_status_byte.svg"))


def address_map(out):
    s = Svg(840, 530, "Address map")
    blocks = [
        ("0x0000 - 0x0010", "Identity", "ID, VERSION, CAPABILITY, SCRATCH, ERRCNT", "grey", 56),
        ("0x0200 - 0x02FF", "Pin window", "ownership, remap, input select, interrupt, views", "yellow", 56),
        ("0x0300 - 0x03FF", "Logic analyser and debug (planned)", "registers to be defined (Phase 3)", "teal", 56),
        ("0x0400 - 0x0BFC", "Instruction memory", "word w at 0x0400 + 4 w, w = 0 .. 511", "purple", 70),
        ("0x1000 - 0x1FFF", "Engine 0", "+0x000 CTRL, +0x008 REGION, +0x00C START, +0x200 TX_DATA, +0x204 RX_DATA", "blue", 78),
        ("0x2000 - 0x2FFF", "Engine 1", "same layout as engine 0", "blue", 56),
    ]
    y = 30
    for addr, name, sub, col, h in blocks:
        s.rect(200, y, 600, h, col, 6, dash="6 3" if "planned" in name else None)
        s.text(185, y + h / 2 + 4, addr, 12, "end", "bold")
        s.text(220, y + h / 2 - 4, name, 14, "start", "bold")
        s.text(220, y + h / 2 + 14, sub, 11, "start", fill=MUT)
        y += h + 12
    s.text(500, y + 14, "every address is a 32-bit word register; addresses between blocks are unmapped (result code BAD_ADDR)", 11, fill=MUT)
    s.save(os.path.join(out, "fig_address_map.svg"))


def pin_ownership(out):
    s = Svg(940, 440, "Pin ownership and remapping")
    s.text(470, 28, "outputs", 14, weight="bold")
    s.box(40, 50, 190, 90, "Engine 0", ["logical pins L0 .. L7"], "blue")
    s.box(40, 160, 190, 90, "Engine 1", ["logical pins L0 .. L7"], "blue")
    s.box(350, 60, 240, 180, "Pin manager", ["per pad: owner", "none / engine 0 / engine 1,", "remap, open-drain flag"], "yellow", 15)
    s.box(710, 60, 190, 180, "Pads", ["uio[7:0]", "uo_out[7:1]"], "green")
    s.line(230, 95, 350, 120, arrow=True); s.line(230, 205, 350, 180, arrow=True)
    s.line(590, 150, 710, 150, arrow=True)
    s.text(470, 268, "only the owner of a pad drives it; a claim is refused while that engine runs", 11, fill=MUT)
    s.text(470, 306, "inputs", 14, weight="bold")
    s.box(40, 330, 190, 80, "Pads", ["uio[7:0]  ui_in[7:3]"], "green")
    s.box(350, 330, 240, 80, "Input select", ["each logical input picks a pad"], "yellow")
    s.box(710, 330, 190, 80, "Engines", ["read logical pins"], "blue")
    s.line(230, 370, 350, 370, arrow=True); s.line(590, 370, 710, 370, arrow=True)
    s.save(os.path.join(out, "fig_pin_ownership.svg"))


def open_drain(out):
    s = Svg(820, 300, "Push-pull and open-drain")
    for ox, title, od in ((40, "Push-pull (default)", False), (440, "Open-drain (I2C, 1-Wire)", True)):
        s.text(ox + 170, 30, title, 14, weight="bold")
        s.line(ox + 170, 50, ox + 170, 250, "#9aa5b1", 1, dash="4 4")
        s.text(ox + 120, 56, "3.3 V", 11, "end", fill="#c46a12")
        s.line(ox + 130, 52, ox + 210, 52, "#c46a12", 2)
        if not od:
            s.rect(ox + 150, 80, 40, 36, "blue", 4)
            s.text(ox + 170, 103, "high", 11)
        else:
            s.rect(ox + 255, 80, 14, 40, "white", 2, sw=1.4)
            s.line(ox + 262, 52, ox + 262, 80, "#5c6670", 1.4)
            s.line(ox + 262, 120, ox + 262, 170, "#5c6670", 1.4)
            s.text(ox + 280, 104, "external", 10, "start", fill=MUT)
            s.text(ox + 280, 117, "pull-up", 10, "start", fill=MUT)
        s.line(ox + 170, 116, ox + 170, 150) if not od else None
        s.circle(ox + 170, 170, 5, "white")
        s.text(ox + 190, 174, "pin", 12, "start", "bold")
        s.line(ox + 170, 175, ox + 170, 190)
        s.rect(ox + 150, 190, 40, 36, "orange", 4)
        s.text(ox + 170, 213, "low", 11)
        s.line(ox + 170, 226, ox + 170, 250)
        s.line(ox + 150, 250, ox + 190, 250, "#2b3a4a", 2)
        if od:
            s.line(ox + 170, 170, ox + 262, 170, "#5c6670", 1.4)
        s.text(ox + 170, 280, "can drive high and low" if not od else "drives low or lets go; never high", 11, fill=MUT)
    s.save(os.path.join(out, "fig_open_drain.svg"))


def memory_windows(out):
    s = Svg(900, 470, "Shared instruction memory and windows")
    x0, sc = 60, 1.5
    s.text(450, 28, "512 words, shared by both engines (word numbers)", 14, weight="bold")
    s.rect(x0, 70, 512 * sc, 56, "grey", 3)
    s.rect(x0, 70, 200 * sc, 56, "blue", 3); s.text(x0 + 100 * sc, 103, "engine 0 program", 12, weight="bold")
    s.rect(x0 + 256 * sc, 70, 165 * sc, 56, "green", 3); s.text(x0 + 338 * sc, 103, "engine 1 program", 12, weight="bold")
    s.text(x0 + 460 * sc, 103, "free", 12, fill=MUT)
    for w in (0, 200, 256, 421, 512):
        s.line(x0 + w * sc, 126, x0 + w * sc, 140, "#5c6670", 1.2)
        s.text(x0 + w * sc, 154, str(w), 11, fill=MUT)
    s.path(f"M {x0} 180 L {x0} 196 L {x0 + 200 * sc} 196 L {x0 + 200 * sc} 180", "#2a5db0", 2)
    s.text(x0 + 100 * sc, 216, "window of engine 0: [0, 200)", 11, fill="#2a5db0")
    s.path(f"M {x0 + 256 * sc} 180 L {x0 + 256 * sc} 196 L {x0 + 421 * sc} 196 L {x0 + 421 * sc} 180", "#2e7d46", 2)
    s.text(x0 + 338 * sc, 216, "window of engine 1: [256, 421)", 11, fill="#2e7d46")
    s.text(x0 + 6, 176, "START = 0", 10, "start", fill="#2a5db0")
    s.text(x0 + 256 * sc + 6, 176, "START = 256", 10, "start", fill="#2e7d46")
    s.rect(60, 250, 780, 190, "yellow", 8)
    s.lines(80, 304, ["A program's first instruction (OP_REGION) names the window it may fetch from; fetching outside faults the engine.",
                      "The window is set once per run and cannot be widened until the engine is held.",
                      "The host cannot write into the window of a running engine (result NOT_ALLOWED).",
                      "Images that run together must not overlap; the host library checks this before it writes anything."], 12, "start", gap=21)
    s.text(80, 276, "Rules the chip enforces", 13, "start", "bold")
    s.save(os.path.join(out, "fig_memory_windows.svg"))


def engine_states(out):
    s = Svg(860, 410, "Engine states")
    s.box(60, 150, 180, 80, "Held", ["RUN = 0, window cleared"], "grey")
    s.box(340, 150, 180, 80, "Running", ["fetching and executing"], "green")
    s.box(640, 40, 180, 80, "Halted", ["HALT instruction"], "blue")
    s.box(640, 260, 180, 80, "Fault", ["stopped, flag set"], "red")
    s.line(240, 175, 340, 175, arrow=True); s.text(290, 166, "RUN = 1", 11, fill=INK)
    s.line(340, 205, 240, 205, arrow=True); s.text(290, 224, "RUN = 0 or HOLD", 10, fill=INK)
    s.line(520, 165, 640, 100, arrow=True); s.text(600, 120, "HALT", 11, "end", fill=INK)
    s.line(520, 215, 640, 280, arrow=True)
    s.lines(590, 262, ["illegal instruction,", "fetch outside window,", "bad OP_REGION"], 10, "middle", gap=12, fill=INK)
    s.path("M 730 120 L 730 132 L 150 132 L 150 150", "#5c6670", 1.4, arrow=True, dash="4 3")
    s.path("M 730 340 L 730 352 L 150 352 L 150 230", "#5c6670", 1.4, arrow=True, dash="4 3")
    s.text(330, 126, "RUN = 0 from the host: back to held", 10, "middle", fill=MUT)
    s.text(440, 346, "RUN = 0 from the host: back to held", 10, "middle", fill=MUT)
    s.text(430, 385, "load images and write START only while held", 12, weight="bold")
    s.save(os.path.join(out, "fig_engine_states.svg"))


def load_sequence(out):
    s = Svg(900, 520, "Loading and starting a program")
    s.box(100, 20, 150, 40, "Host (Pico)", None, "green", 13)
    s.box(650, 20, 150, 40, "Chip", None, "blue", 13)
    s.line(175, 60, 175, 500, "#9aa5b1", 1.4, dash="4 4"); s.line(725, 60, 725, 500, "#9aa5b1", 1.4, dash="4 4")
    steps = [("write CTRL = 0 (hold the engine)", 1, 88), ("write words to 0x0400 + 4 w   (one frame per word)", 1, 140), ("read the words back and compare", 0, 192),
             ("write START = first word of the image", 1, 244), ("write CTRL = 1 (run)", 1, 296), ("read REGION: must equal the image's window", 0, 348),
             ("write TX_DATA / read RX_DATA, poll STATUS", 2, 400), ("read CTRL: pc, fault, halted", 0, 452)]
    for i, (lab, dr, y) in enumerate(steps):
        s.text(60, y + 4, f"{i + 1}", 12, "middle", "bold", fill=MUT)
        if dr == 1:
            s.line(175, y, 725, y, arrow=True)
        elif dr == 0:
            s.line(725, y, 175, y, arrow=True)
            s.line(175, y - 12, 725, y - 12, "#9aa5b1", 1.2)
        else:
            s.line(175, y, 725, y, arrow=True, both=True)
        s.text(450, y - 18 if dr == 0 else y - 8, lab, 11, fill=INK)
    s.save(os.path.join(out, "fig_load_sequence.svg"))


def programming_model(out):
    s = Svg(940, 470, "Engine programming model")
    s.rect(300, 30, 340, 400, "grey", 10)
    s.text(470, 54, "one engine", 13, weight="bold")
    s.box(320, 70, 150, 64, "R0 .. R7", ["8 x 32 bit, flags Z N C"], "blue", 13)
    s.box(480, 70, 140, 64, "ALU", ["13 functions"], "blue", 13)
    s.box(320, 156, 150, 56, "OSR", ["output shifter"], "orange", 13)
    s.box(480, 156, 140, 56, "ISR", ["input shifter"], "orange", 13)
    s.box(320, 250, 300, 56, "Pin block", ["8 logical pins: output, enable, input"], "yellow", 13)
    s.box(320, 334, 94, 76, "Loop", ["counter", "DJNZ"], "blue", 11)
    s.box(423, 334, 94, 76, "CRC unit", ["1 to 32 bit"], "blue", 11)
    s.box(526, 334, 94, 76, "Line coder", ["NRZI, stuffing"], "blue", 11)
    s.line(395, 212, 395, 250, arrow=True); s.text(405, 236, "OUT1", 10, "start", fill=INK)
    s.line(550, 250, 550, 212, arrow=True); s.text(560, 236, "IN1", 10, "start", fill=INK)
    s.box(40, 150, 200, 70, "TX FIFO (4 words)", ["written by the host"], "green", 13)
    s.box(700, 150, 200, 70, "RX FIFO (4 words)", ["read by the host"], "green", 13)
    s.line(240, 184, 320, 184, arrow=True); s.text(280, 176, "PULL", 10, fill=INK)
    s.line(620, 184, 700, 184, arrow=True); s.text(660, 176, "PUSH", 10, fill=INK)
    s.box(700, 250, 200, 70, "Pins", ["to the pin manager"], "yellow", 13)
    s.line(620, 278, 700, 278, arrow=True, both=True)
    s.box(40, 334, 200, 76, "Program memory", ["one word per clock"], "purple", 13)
    s.line(240, 372, 300, 372, arrow=True)
    s.text(470, 452, "RGET and RPUT move values between the registers and the shifters, counters, CRC and FIFOs", 11, fill=MUT)
    s.save(os.path.join(out, "fig_programming_model.svg"))


def instruction_timing(out):
    s = Svg(900, 330, "Instruction timing")
    x0, c = 150, 58
    s.text(x0 - 20, 40, "clock", 12, "end", "bold")
    ticks = 12
    bits = [1, 0] * ticks
    s.signal(x0, 52, bits, c / 2, 18)
    for i in range(ticks + 1):
        s.line(x0 + i * c, 62, x0 + i * c, 300, "#d5dbe1", 1)
    items = [("SETH p", 0, 1, "blue"), ("OUT1 d=0", 1, 1, "orange"), ("OUT1 d=2", 2, 3, "orange"), ("WAIT d=3", 5, 4, "yellow"), ("DJNZ", 9, 1, "blue"), ("RGET", 10, 1, "blue")]
    for lab, start, ln, col in items:
        s.rect(x0 + start * c + 2, 90, ln * c - 4, 46, col, 4)
        s.text(x0 + start * c + ln * c / 2, 110, lab, 10 if ln > 1 else 9, weight="bold")
        s.text(x0 + start * c + ln * c / 2, 126, f"{ln} clock{'s' if ln > 1 else ''}", 9, fill=MUT)
    s.text(x0 - 20, 118, "instruction", 12, "end", "bold")
    s.text(450, 190, "every instruction takes one clock; the delay of WAIT, OUT1 and IN1 adds d clocks", 12, fill=INK)
    s.text(450, 214, "a pin written at clock 5 is seen by the target after the pin's own delay; a pin read is two clocks old (input synchroniser)", 11, fill=MUT)
    s.text(450, 262, "at 50 MHz one clock = 20 ns; at 40 MHz = 25 ns", 12, weight="bold")
    s.save(os.path.join(out, "fig_instruction_timing.svg"))


# ---------------------------------------------------------------- protocol waveforms
def uart_frame(out):
    s = Svg(900, 250, "UART frame")
    x0, t = 120, 56
    bits = [1, 0] + [1, 0, 0, 0, 0, 0, 1, 0] + [1, 1]
    s.signal(x0, 110, bits, t, 40, "TX")
    labs = ["idle", "start"] + [f"D{i}" for i in range(8)] + ["stop", "idle"]
    for i, l in enumerate(labs):
        s.text(x0 + i * t + t / 2, 134, l, 11, fill=MUT)
        s.line(x0 + i * t, 56, x0 + i * t, 150, "#d5dbe1", 1)
    s.text(450, 180, "0x41 ('A') sent least significant bit first, 8 data bits, no parity, 1 stop bit", 12)
    s.text(450, 204, "one bit = 1 / baud rate: 8.68 us at 115200 baud = 434 clocks at 50 MHz", 11, fill=MUT)
    s.save(os.path.join(out, "fig_uart_frame.svg"))


def i2c_transfer(out):
    s = Svg(980, 330, "I2C transfer")
    x0, q = 90, 9.5
    scl, sda = [1] * 4, [1] * 2 + [0] * 2          # idle, then START: SDA falls while SCL is high
    def bit(b):
        nonlocal scl, sda
        scl += [0] * 2 + [1] * 2
        sda += [b] * 4
        scl.append(0)
        sda.append(b)
    scl += [0] * 2
    sda += [0] * 2
    first = len(scl)
    for b in [1, 0, 1, 0, 0, 0, 0, 0, 0]:           # address 0x50 + write bit 0, then ACK (low from the device)
        sda_part = b
        scl += [0, 0, 1, 1]
        sda += [sda_part] * 4
    for b in [1, 0, 1, 0, 0, 1, 0, 1, 0]:           # data 0xA5 + ACK
        scl += [0, 0, 1, 1]
        sda += [b] * 4
    scl += [0, 0, 1, 1, 1, 1]                        # STOP: SDA rises while SCL is high
    sda += [0, 0, 0, 0, 1, 1]
    s.signal(x0, 100, scl, q, 40, "SCL")
    s.signal(x0, 200, sda, q, 40, "SDA")
    s.text(x0 + 2.5 * q, 54, "START", 11, fill=INK)
    for i, l in enumerate(["1", "0", "1", "0", "0", "0", "0", "W", "ACK"]):
        s.text(x0 + (first + 4 * i + 2) * q, 232, l, 10, fill=MUT)
    for i, l in enumerate(["1", "0", "1", "0", "0", "1", "0", "1", "ACK"]):
        s.text(x0 + (first + 36 + 4 * i + 2) * q, 232, l, 10, fill=MUT)
    s.text(x0 + (first + 18) * q, 252, "address 0x50", 11, fill=INK)
    s.text(x0 + (first + 54) * q, 252, "data 0xA5", 11, fill=INK)
    s.text(x0 + (first + 74) * q, 54, "STOP", 11, fill=INK)
    s.text(490, 300, "SDA changes while SCL is low, except START and STOP; 9th bit: the receiver pulls SDA low to acknowledge", 11, fill=MUT)
    s.save(os.path.join(out, "fig_i2c_transfer.svg"))


def usb_packet(out):
    s = Svg(940, 360, "USB low-speed packet")
    labs = ["SYNC|KJKJKJKK", "PID|8 bits", "address / data|0 .. 8 bytes", "CRC|5 or 16 bits", "EOP|SE0 SE0 J"]
    ws = [110, 110, 280, 150, 150]
    x = cells(s, 40, 40, labs, ws, ["yellow", "orange", "green", "red", "grey"], 70, 12)
    s.text(470, 150, "every field is bit-stuffed (a 0 after six 1s) and NRZI coded, except SYNC and EOP", 12)
    s.text(470, 174, "1.5 Mbit/s: one bit = 666.7 ns = 33.3 clocks at 50 MHz (26.7 at 40 MHz)", 12, fill=MUT)
    x0, t = 130, 40
    sync = ["K", "J", "K", "J", "K", "J", "K", "K"]
    s.text(40, 226, "SYNC on D+ / D-:", 12, "start", "bold")
    d = [1 if c == "K" else 0 for c in sync]
    s.signal(x0 + 60, 268, d, t, 30, "D+")
    s.signal(x0 + 60, 318, [1 - b for b in d], t, 30, "D-")
    for i, c in enumerate(sync):
        s.text(x0 + 60 + i * t + t / 2, 290, c, 11, fill=MUT)
    s.text(780, 256, "K: D+ high", 11, "start", fill=MUT)
    s.text(780, 276, "J: D- high (idle)", 11, "start", fill=MUT)
    s.save(os.path.join(out, "fig_usb_packet.svg"))


def usb_stages(out):
    s = Svg(900, 330, "Line coder stages")
    x0, t = 190, 40
    data = [0, 1, 1, 1, 1, 1, 1, 1, 0]
    stuffed = [0, 1, 1, 1, 1, 1, 1, 0, 1, 0]
    s.text(20, 56, "data bits", 12, "start", "bold")
    s.text(20, 126, "after bit stuffing", 12, "start", "bold")
    s.text(20, 196, "after NRZI", 12, "start", "bold")
    s.text(20, 266, "line (D+)", 12, "start", "bold")
    for i, b in enumerate(data):
        s.rect(x0 + i * t, 36, t - 4, 28, "blue", 3); s.text(x0 + i * t + t / 2 - 2, 56, str(b), 13)
    for i, b in enumerate(stuffed):
        s.rect(x0 + i * t, 106, t - 4, 28, "orange" if i == 7 else "green", 3); s.text(x0 + i * t + t / 2 - 2, 126, str(b), 13)
    s.text(x0 + 7 * t + t / 2 - 2, 152, "stuffed 0", 10, fill="#c46a12")
    lvl, nrzi = 0, []
    for b in stuffed:
        if b == 0:
            lvl = 1 - lvl
        nrzi.append(lvl)
    for i, b in enumerate(nrzi):
        s.rect(x0 + i * t, 176, t - 4, 28, "purple", 3); s.text(x0 + i * t + t / 2 - 2, 196, "K" if b else "J", 13)
    s.signal(x0, 276, nrzi, t, 26)
    s.text(450, 316, "NRZI: a 0 is a change of level, a 1 keeps the level; after six 1s the line coder inserts a 0 so the receiver keeps seeing edges", 11, fill=MUT)
    s.save(os.path.join(out, "fig_usb_stages.svg"))


def ws2812_bits(out):
    s = Svg(900, 300, "WS2812 bit timing")
    x0, u = 120, 160                                # 160 px per microsecond
    def one(y, th, tl, name):
        s.signal(x0, y, [1] * 1 + [0] * 1, 1, 30) if False else None
        pts = f"M {x0} {y} L {x0} {y - 30} L {x0 + th * u} {y - 30} L {x0 + th * u} {y} L {x0 + (th + tl) * u} {y}"
        s.path(pts, "#1f5fbf", 2.2)
        s.text(x0 - 10, y - 10, name, 12, "end", "bold")
        s.line(x0, y + 14, x0 + th * u, y + 14, arrow=True, both=True); s.text(x0 + th * u / 2, y + 30, f"{th} us high", 10, fill=INK)
        s.line(x0 + th * u, y + 14, x0 + (th + tl) * u, y + 14, arrow=True, both=True); s.text(x0 + (th + 0.5 * tl) * u, y + 30, f"{tl} us low", 10, fill=INK)
    one(80, 0.4, 0.85, "bit 0")
    one(190, 0.8, 0.45, "bit 1")
    s.text(700, 100, "tolerance about +-150 ns", 11, fill=MUT)
    s.text(450, 270, "a latch / reset is a low of more than 50 us; 24 bits per LED (green, red, blue); data is passed on down the strip", 11, fill=MUT)
    s.save(os.path.join(out, "fig_ws2812_bits.svg"))


def can_frame(out):
    s = Svg(1000, 250, "CAN 2.0A data frame")
    labs = ["SOF|1", "identifier|11", "RTR|1", "IDE|1", "r0|1", "DLC|4", "data|0 .. 8 bytes", "CRC|15", "CRC|delim", "ACK|slot", "ACK|delim", "EOF|7", "IFS|3"]
    ws = [34, 100, 36, 36, 36, 50, 130, 80, 44, 44, 44, 60, 48]
    cols = ["yellow", "blue", "grey", "grey", "grey", "orange", "green", "red", "red", "teal", "teal", "yellow", "grey"]
    cells(s, 24, 50, labs, ws, cols, 80, 9)
    s.text(500, 170, "arbitration field = identifier + RTR; the receiver acknowledges in the ACK slot; bit stuffing applies from SOF to the CRC", 11, fill=MUT)
    s.text(500, 196, "this chip: CAN 2.0A (11-bit identifier) transmit and receive; no arbitration or error frames", 12)
    s.save(os.path.join(out, "fig_can_frame.svg"))


def clock_scaling(out):
    s = Svg(820, 330, "Instruction time at different clocks")
    data = [(50, 20.0), (46.6, 21.5), (43.4, 23.0), (40, 25.0)]
    s.text(410, 28, "time of one instruction", 14, weight="bold")
    for i, (f, ns) in enumerate(data):
        x = 100 + i * 170
        h = ns * 9
        s.rect(x, 270 - h, 90, h, "blue", 3)
        s.text(x + 45, 270 - h - 8, f"{ns} ns", 13, weight="bold")
        s.text(x + 45, 292, f"{f} MHz", 12)
    s.text(410, 320, "nothing but the time changes: every program, count and flag behaves the same", 11, fill=MUT)
    s.save(os.path.join(out, "fig_clock_scaling.svg"))


def all_figs(out):
    spi_mode0(out)
    frame_formats(out)
    status_byte(out)
    address_map(out)
    pin_ownership(out)
    open_drain(out)
    memory_windows(out)
    engine_states(out)
    load_sequence(out)
    programming_model(out)
    instruction_timing(out)
    uart_frame(out)
    i2c_transfer(out)
    usb_packet(out)
    usb_stages(out)
    ws2812_bits(out)
    can_frame(out)
    clock_scaling(out)
