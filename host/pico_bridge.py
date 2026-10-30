# MicroPython, runs ON the Raspberry Pi Pico (copy to the Pico as main.py). It is a dumb SPI master controlled over USB serial:
# the PC sends one line "F <hex bytes>" per frame, the Pico clocks it out on the chip's management SPI (mode 0, MSB first, CS_N low for the
# whole frame) and answers with one line of the bytes it read back. All protocol logic stays in host/chip_host.py on the PC.
# Wiring (3.3 V only): GP18 SCK -> chip SCLK, GP19 MOSI -> chip MOSI, GP16 MISO <- chip MISO, GP17 CS_N -> chip CS_N, common GND.
# The chip needs at least 8 system clocks per SCLK phase: at 50 MHz keep the SPI clock at or below 3 MHz (1 MHz here).
import sys
from machine import Pin, SPI

spi = SPI(0, baudrate=1_000_000, polarity=0, phase=0, bits=8, firstbit=SPI.MSB, sck=Pin(18), mosi=Pin(19), miso=Pin(16))
cs = Pin(17, Pin.OUT, value=1)

while True:
    line = sys.stdin.readline().strip()
    if not line.startswith("F "):
        continue
    out = bytes.fromhex(line[2:])
    back = bytearray(len(out))
    cs(0)
    spi.write_readinto(out, back)
    cs(1)
    print("F " + back.hex())
