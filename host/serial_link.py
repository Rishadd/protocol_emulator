#!/usr/bin/env python3
"""PC side of the Pico bridge (host/pico_bridge.py): a link object for ChipHost on real hardware.

    from chip_host import ChipHost
    from serial_link import SerialLink
    chip = ChipHost(SerialLink("/dev/ttyACM0"), trace=True)     # pyserial: pip install pyserial
    print(chip.status())
"""
import serial


class SerialLink:
    def __init__(self, port, timeout=2.0):
        self.s = serial.Serial(port, 115200, timeout=timeout)

    def transfer(self, mosi):
        """One full-duplex SPI frame (any length): the bytes sent, the bytes read back."""
        self.s.write(b"F " + mosi.hex().encode() + b"\n")
        reply = self.s.readline().decode().split()
        if len(reply) != 2 or reply[0] != "F":
            raise IOError(f"Pico bridge did not answer: {reply!r}")
        return bytes.fromhex(reply[1])

    def close(self):
        self.s.close()

    def __enter__(self):
        return self

    def __exit__(self, *a):
        self.close()
