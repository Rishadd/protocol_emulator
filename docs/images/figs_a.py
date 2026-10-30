"""Figures: overview, block diagram, pins, Pico wiring, power-up, bring-up flow, protocol wiring."""
import os

from svg import Svg, MUT, INK


def system_context(out):
    s = Svg(940, 430, "System overview")
    s.box(30, 30, 190, 110, "PC", ["assembler and scripts", "GTKWave"], "grey")
    s.box(30, 250, 190, 150, "Raspberry Pi Pico", ["host: management link,", "clock, reset"], "green")
    s.line(125, 140, 125, 250, arrow=True, both=True)
    s.text(135, 200, "USB", 12, "start", fill=MUT)
    s.box(400, 120, 170, 290, "Protocol emulator", ["chip", "two engines,", "shared memory,", "logic analyser"], "blue", 15)
    s.wire([(220, 325), (400, 325)], "SPI + clock + reset", lab_at=0, dy=-8, arrow=True)
    s.line(400, 325, 220, 325, arrow=True, color="#2e7d46")
    targets = [("UART device", 40), ("SPI device", 105), ("I2C device (EEPROM)", 170), ("CAN bus", 235), ("USB host", 300), ("LED strip / PS/2 / 1-Wire ...", 365)]
    for name, y in targets:
        s.box(720, y - 25, 200, 46, name, None, "orange", 12)
        s.line(570, 140 + (y - 40) * 0.6 + 20, 720, y - 2, arrow=True, both=True)
    s.text(645, 425, "protocol pins (3.3 V)", 12, fill=MUT)
    s.rect(240, 40, 130, 60, "yellow", 6, dash="5 3")
    s.lines(305, 66, ["capture file", ".vcd"], 12)
    s.line(220, 85, 240, 70, arrow=True, grey_arrow=True)
    s.save(os.path.join(out, "fig_system_context.svg"))


def block_diagram(out):
    s = Svg(1040, 620, "Block diagram")
    s.box(40, 30, 230, 100, "Management link", ["SPI slave, frames,", "CRC, registers"], "orange")
    s.box(330, 30, 380, 100, "Shared instruction memory", ["512 words x 32 bit, two ports", "(one per engine), windows"], "purple")
    s.box(770, 30, 230, 100, "Logic analyser", ["16 channels, ring buffer,", "triggers, engine debug"], "teal")
    for ex, name in ((40, "Engine 0"), (530, "Engine 1")):
        s.rect(ex, 190, 470, 270, "grey", 10)
        s.text(ex + 235, 214, name, 15, weight="bold")
        subs = [("Control unit", "program counter"), ("ALU", "R0-R7, flags"), ("Shifters", "OSR, ISR, loop"), ("FIFOs", "TX and RX, 4 words"),
                ("CRC unit", "1 to 32 bit"), ("Line coder", "NRZI, stuffing")]
        for i, (a, b) in enumerate(subs):
            bx, by = ex + 15 + (i % 3) * 152, 232 + (i // 3) * 100
            s.box(bx, by, 142, 84, a, [b], "blue", 13)
        s.text(ex + 235, 448, "one instruction per clock", 11, fill=MUT)
        s.line(ex + 235, 460, ex + 235, 500, arrow=True)
    s.box(40, 500, 960, 70, "Pin manager", ["ownership, output remap, input select, open-drain, HOLD, interrupt, debug views"], "yellow")
    s.line(155, 130, 155, 190, arrow=True, both=True)          # management -> engine 0 (FIFOs, control)
    s.line(270, 80, 330, 80, arrow=True, both=True)            # management <-> memory (load, readback)
    s.line(470, 130, 470, 190, arrow=True)                     # memory -> engine 0 (fetch)
    s.line(570, 130, 570, 190, arrow=True)                     # memory -> engine 1
    s.path("M 255 100 L 255 160 L 705 160 L 705 190", "#2b3a4a", 1.6, arrow=True)   # management -> engine 1
    s.line(770, 80, 710, 80, arrow=True, grey_arrow=True)
    s.path("M 885 130 L 885 160 L 1020 160 L 1020 535 L 1000 535", "#5c6670", 1.4, arrow=True, dash="5 3")
    s.text(950, 152, "pins", 11, fill=MUT)
    s.text(520, 595, "chip pins: management link, clock, reset, 15 outputs, 13 inputs", 12, fill=MUT)
    s.save(os.path.join(out, "fig_block_diagram.svg"))


def pin_groups(out):
    s = Svg(820, 460, "Chip pin groups")
    s.box(280, 60, 260, 300, "Protocol emulator", None, "blue", 16)
    left = [("clk", "system clock, up to 50 MHz"), ("rst_n", "reset, active low"), ("ena", "enable"), ("ui_in[0]", "management SCLK"),
            ("ui_in[1]", "management MOSI"), ("ui_in[2]", "management CS_N"), ("ui_in[3]", "HOLD (or protocol input)"), ("ui_in[7:4]", "protocol inputs")]
    for i, (a, b) in enumerate(left):
        y = 90 + i * 32
        s.line(240, y, 280, y)
        s.text(236, y + 4, a, 12, "end", "bold")
        s.text(24, y + 4, b, 10, "start", fill=MUT)
    right = [("uo_out[0]", "management MISO"), ("uo_out[1]", "interrupt (default)"), ("uo_out[7:2]", "debug views (default), or outputs"), ("", "")]
    for i, (a, b) in enumerate(right[:3]):
        y = 90 + i * 40
        s.line(540, y, 580, y)
        s.text(584, y + 4, a, 12, "start", "bold")
        s.text(584, y + 18, b, 10, "start", fill=MUT)
    s.rect(280, 360, 260, 6, "grey", 2)
    for i in range(8):
        x = 296 + i * 31
        s.line(x, 360, x, 395)
        s.text(x, 410, str(7 - i), 11, fill=INK)
    s.text(410, 432, "uio[7:0]: bidirectional protocol pins", 12, weight="bold")
    s.save(os.path.join(out, "fig_pin_groups.svg"))


def pico_wiring(out):
    s = Svg(920, 560, "Raspberry Pi Pico wired to the chip")
    s.rect(40, 40, 230, 480, "green", 10)
    s.text(155, 68, "Raspberry Pi Pico", 15, weight="bold")
    s.rect(650, 40, 230, 480, "blue", 10)
    s.text(765, 68, "Protocol emulator", 15, weight="bold")
    rows = [("GP18  (pin 24)  SPI0 SCK", "ui_in[0]  SCLK", "management clock", "→"),
            ("GP19  (pin 25)  SPI0 TX", "ui_in[1]  MOSI", "host to chip", "→"),
            ("GP16  (pin 21)  SPI0 RX", "uo_out[0]  MISO", "chip to host", "←"),
            ("GP17  (pin 22)  SPI0 CSn", "ui_in[2]  CS_N", "chip select", "→"),
            ("GP21  (pin 27)  clock out", "clk", "system clock", "→"),
            ("GP22  (pin 29)  GPIO", "rst_n", "reset, active low", "→"),
            ("GP26  (pin 31)  GPIO", "ui_in[3]  HOLD", "optional emergency stop", "→"),
            ("GP27  (pin 32)  GPIO in", "uo_out[1]  IRQ", "optional interrupt", "←"),
            ("GND  (pin 23)", "GND", "common ground", "—"),
            ("3V3  (pin 36)", "VDD (see board)", "supply, 3.3 V", "→")]
    for i, (a, b, c, d) in enumerate(rows):
        y = 100 + i * 42
        s.text(52, y + 4, a, 11, "start")
        s.text(868, y + 4, b, 11, "end", "bold")
        if d == "←":
            s.line(650, y, 270, y, "#2b3a4a", 1.8, arrow=True)
        else:
            s.line(270, y, 650, y, "#2b3a4a", 1.8, arrow=(d == "→"))
        s.text(460, y - 6, c, 10, fill=MUT)
    s.text(460, 538, "All signals are 3.3 V logic. Suggested pins: check the clock-output pin against the RP2040 datasheet.", 11, fill=MUT)
    s.save(os.path.join(out, "fig_pico_wiring.svg"))


def power_up(out):
    s = Svg(900, 300, "Power-up sequence")
    x0, t = 120, 10.0
    rows = [("VDD", [0] + [1] * 66, 40), ("clk", [0] * 12 + [1, 0] * 27, 90), ("rst_n", [0] * 24 + [1] * 42, 140), ("CS_N", [1] * 50 + [0] * 12 + [1] * 4, 190)]
    for name, bits, y in rows:
        s.signal(x0, y + 16, bits, t, 16, name)
    for x, lab in ((x0 + 12 * t, "1 clock starts"), (x0 + 24 * t, "2 rst_n released"), (x0 + 50 * t, "3 first frame")):
        s.line(x, 30, x, 235, MUT, 1, dash="4 3")
        s.text(x, 255, lab, 11, fill=INK)
    s.text(x0 + 12 * t + 120, 134, "held in reset", 10, "middle", fill=MUT, italic=True)
    s.text(450, 285, "after reset both engines are held and every protocol pin is released", 11, fill=MUT)
    s.save(os.path.join(out, "fig_power_up.svg"))


def bringup_flow(out):
    s = Svg(560, 640, "First power-on flow")
    def b(y, txt, color="blue"):
        s.rect(150, y, 260, 48, color, 8)
        s.lines(280, y + 20, txt if isinstance(txt, list) else [txt], 12, gap=15)
    def d(y, txt):
        s.poly([(280, y), (400, y + 40), (280, y + 80), (160, y + 40)], "yellow")
        s.lines(280, y + 36, txt, 11, gap=14)
    b(20, "Check wiring and 3.3 V")
    s.line(280, 68, 280, 90, arrow=True)
    b(90, ["Power, start the clock,", "release rst_n"])
    s.line(280, 138, 280, 160, arrow=True)
    d(160, ["ID register", "reads PEM1?"])
    s.line(280, 240, 280, 262, arrow=True); s.text(292, 256, "yes", 11, "start", fill=MUT)
    d(262, ["Scratch write,", "read back equal?"])
    s.line(280, 342, 280, 364, arrow=True); s.text(292, 358, "yes", 11, "start", fill=MUT)
    b(364, ["Load the test program,", "run it"])
    s.line(280, 412, 280, 434, arrow=True)
    d(434, ["Word arrives,", "error flag clear?"])
    s.line(280, 514, 280, 540, arrow=True); s.text(292, 534, "yes", 11, "start", fill=MUT)
    b(540, "Ready: continue with chapter 5", "green")
    for y in (200, 302, 474):
        s.line(160, y, 112, y, color="#b32d2d", arrow=True)
        s.text(136, y - 6, "no", 11, fill="#b32d2d")
    s.rect(10, 190, 100, 290, "red", 8, dash="5 3")
    s.lines(60, 330, ["see", "chapter 16", "troubleshooting"], 11, gap=15)
    s.save(os.path.join(out, "fig_bringup_flow.svg"))


# ---------------------------------------------------------------- protocol wiring
def proto_fig(out, name, title, chip_pins, target, target_pins, mid=None, pull=None, notes=None, w=860):
    """chip_pins: [(label, direction)] direction '>' chip drives, '<' target drives, '=' bidirectional. target_pins: matching labels."""
    n = len(chip_pins)
    h = 120 + n * 46 + (30 if notes else 0) + (36 if pull else 0)
    s = Svg(w, h, title)
    top, bh = 54, 40 + n * 46
    s.rect(40, top, 190, bh, "blue", 10)
    s.text(135, top + 24, "Protocol emulator", 13, weight="bold")
    tx = w - 230
    s.rect(tx, top, 190, bh, "orange", 10)
    s.text(tx + 95, top + 24, target, 13, weight="bold")
    if mid:
        s.rect(w / 2 - 70, top + 30, 140, bh - 60, "teal", 10)
        s.lines(w / 2, top + bh / 2 - 6, mid.split("|"), 12, gap=15, weight="bold")
    for i, ((lab, dr), tl) in enumerate(zip(chip_pins, target_pins)):
        y = top + 60 + i * 46
        s.text(50, y + 4, lab, 11, "start", "bold")
        s.text(tx + 180, y + 4, tl, 11, "end", "bold")
        x1, x2 = 230, tx
        if dr == "-":
            s.line(x1, y, x2, y)
        elif mid:
            s.line(x1, y, w / 2 - 70, y, arrow=(dr == ">"), both=(dr == "="))
            if dr == "<":
                s.line(w / 2 - 70, y, x1, y, arrow=True)
            s.line(w / 2 + 70, y, x2, y, arrow=(dr == ">"), both=(dr == "="))
            if dr == "<":
                s.line(x2, y, w / 2 + 70, y, arrow=True)
        else:
            if dr == "<":
                s.line(x2, y, x1, y, arrow=True)
            else:
                s.line(x1, y, x2, y, arrow=True, both=(dr == "="))
    if pull:
        rail = top + bh + 18
        s.line(w / 2 - 60, rail, w / 2 + 40 + 50 * len(pull), rail, "#c46a12", 2)
        s.text(w / 2 - 66, rail + 4, "3.3 V", 11, "end", "bold", fill="#c46a12")
        for k, (idx, txt) in enumerate(pull):
            y = top + 60 + idx * 46
            px = w / 2 + 20 + k * 50
            s.circle(px, y, 3.5, "white")
            s.line(px, y, px, rail - 30, "#5c6670", 1.4)
            s.rect(px - 7, rail - 30, 14, 22, "white", 2, sw=1.4)
            s.line(px, rail - 8, px, rail, "#5c6670", 1.4)
            s.text(px - 12 if k % 2 == 0 else px + 12, rail - 14, txt, 10, "end" if k % 2 == 0 else "start", fill=MUT)
    if notes:
        s.text(w / 2, h - 14, notes, 11, fill=MUT)
    s.save(os.path.join(out, name))


def protocol_wiring(out):
    proto_fig(out, "fig_wire_uart.svg", "UART wiring", [("uio[0]  TX", ">"), ("uio[1]  RX", "<"), ("GND", "-")], "UART device", ["RX", "TX", "GND"],
              notes="cross TX and RX; a 3.3 V device, or add a level shifter")
    proto_fig(out, "fig_wire_spi_master.svg", "SPI master wiring", [("uio[0]  SCLK", ">"), ("uio[1]  MOSI", ">"), ("uio[2]  MISO", "<"), ("uio[3]  CS", ">"), ("GND", "-")],
              "SPI device", ["SCLK", "MOSI / SDI", "MISO / SDO", "CS", "GND"], notes="mode 0 to 3 chosen in the firmware")
    proto_fig(out, "fig_wire_spi_slave.svg", "SPI slave wiring", [("uio[0]  SCLK", "<"), ("uio[1]  MOSI", "<"), ("uio[2]  MISO", ">"), ("uio[3]  CS", "<"), ("GND", "-")],
              "SPI master", ["SCLK", "MOSI", "MISO", "CS", "GND"], notes="the host keeps the TX and RX FIFOs served")
    proto_fig(out, "fig_wire_i2c.svg", "I2C and SMBus wiring", [("uio[0]  SDA", "="), ("uio[1]  SCL", "="), ("GND", "-")], "I2C device", ["SDA", "SCL", "GND"],
              pull=[(0, "4.7 k to 3.3 V"), (1, "4.7 k to 3.3 V")], notes="open-drain pins (chapter 6.4) with external pull-ups; one pair per bus")
    proto_fig(out, "fig_wire_modbus.svg", "Modbus RTU wiring", [("uio[0]  TX", ">"), ("uio[1]  RX", "<"), ("uio[2]  DE / RE", ">")], "Modbus device", ["A", "B", "(bus pair)"],
              mid="RS-485|transceiver", notes="RS-485 bus: A and B twisted pair, termination at both ends")
    proto_fig(out, "fig_wire_onewire.svg", "1-Wire wiring", [("uio[0]  DQ", "="), ("GND", "-")], "1-Wire device", ["DQ", "GND"], pull=[(0, "4.7 k to 3.3 V")],
              notes="open-drain pin with one external pull-up")
    proto_fig(out, "fig_wire_jtag.svg", "JTAG wiring", [("uio[0]  TCK", ">"), ("uio[1]  TMS", ">"), ("uio[2]  TDI", ">"), ("uio[3]  TDO", "<"), ("GND", "-")],
              "Target TAP", ["TCK", "TMS", "TDI", "TDO", "GND"], notes="TCK, TMS and TDI may sit on the output-only pins (uo_out)")
    proto_fig(out, "fig_wire_swd.svg", "SWD wiring", [("uio[0]  SWCLK", ">"), ("uio[1]  SWDIO", "="), ("uio[2]  nRESET", ">"), ("GND", "-")], "Target (Arm)", ["SWCLK", "SWDIO", "nRESET", "GND"],
              notes="nRESET is optional")
    proto_fig(out, "fig_wire_can.svg", "CAN wiring", [("uio[0]  TX", ">"), ("uio[1]  RX", "<")], "CAN node", ["CANH", "CANL"], mid="CAN|transceiver",
              notes="120 ohm termination at both ends of the bus; a transceiver is required")
    proto_fig(out, "fig_wire_usb.svg", "USB low-speed wiring", [("uio[0]  D+", "="), ("uio[1]  D-", "=")], "USB host (port)", ["D+", "D-"], pull=[(1, "1.5 k to 3.3 V")],
              notes="low-speed device: 1.5 k pull-up on D-; series resistors on both data lines (value to be confirmed)")
    proto_fig(out, "fig_wire_ws2812.svg", "WS2812 wiring", [("uio[0]  DATA", ">"), ("GND", "-")], "LED strip", ["DIN", "GND"], mid="level|shifter",
              notes="3.3 V data into a 5 V strip needs a level shifter; power the strip separately and join the grounds")
    proto_fig(out, "fig_wire_ps2.svg", "PS/2 wiring", [("uio[0]  CLK", "="), ("uio[1]  DATA", "="), ("GND", "-")], "PS/2 port", ["CLK", "DATA", "GND"], mid="3.3 V / 5 V|level shifter",
              notes="PS/2 is a 5 V interface with open-collector lines: use a bidirectional level shifter")


def all_figs(out):
    system_context(out)
    block_diagram(out)
    pin_groups(out)
    pico_wiring(out)
    power_up(out)
    bringup_flow(out)
    protocol_wiring(out)
