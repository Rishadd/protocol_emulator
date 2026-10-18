# SPDX-License-Identifier: Apache-2.0
# Smoke tests through the management SPI port (frame v1, see src/mgmt.v). The full self-checking
# suite (engines, UART/SPI/I2C firmware, mutation tests) lives in tb/ and runs with run_tests.ps1.

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles

OP_WR, OP_RD = 0x01, 0x02
HALF = 8  # clk cycles per SCLK half period


async def reset(dut):
    cocotb.start_soon(Clock(dut.clk, 20, unit="ns").start())  # 50 MHz
    dut.ena.value = 1
    dut.ui_in.value = 0b100  # CS_N high, SCLK low
    dut.uio_in.value = 0xFF
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1
    await ClockCycles(dut.clk, 10)


async def frame(dut, op, addr, data=0):
    """One 7-byte full-duplex frame; returns (status, mid, read_data)."""
    tx = [op, addr >> 8, addr & 0xFF] + list(data.to_bytes(4, "big"))
    rx = []
    dut.ui_in.value = 0b000  # CS_N low
    await ClockCycles(dut.clk, HALF)
    for byte in tx:
        got = 0
        for i in range(7, -1, -1):
            mosi = (byte >> i) & 1
            dut.ui_in.value = mosi << 1  # SCLK low, MOSI set
            await ClockCycles(dut.clk, HALF)
            dut.ui_in.value = (mosi << 1) | 1  # SCLK rising: slave samples MOSI, master samples MISO
            await ClockCycles(dut.clk, 1)
            got = (got << 1) | (int(dut.uo_out.value) & 1)
            await ClockCycles(dut.clk, HALF - 1)
        rx.append(got)
    dut.ui_in.value = 0b000
    await ClockCycles(dut.clk, HALF)
    dut.ui_in.value = 0b100  # CS_N high: the frame commits here
    await ClockCycles(dut.clk, 4 * HALF)
    return rx[0], (rx[1] << 8) | rx[2], int.from_bytes(bytes(rx[3:]), "big")


@cocotb.test()
async def test_status_alive(dut):
    await reset(dut)
    status, _, _ = await frame(dut, OP_RD, 0x1000)
    dut._log.info(f"STATUS = 0x{status:02x}")
    assert status & 0x80, "alive bit must be set"
    assert not status & 0x40, "no error expected"
    assert status & 0x30 == 0, "both engines held after reset"


@cocotb.test()
async def test_imem_write_and_pad_owner(dut):
    await reset(dut)
    # pad 3: owner = engine 0 (1), push-pull; read it back
    await frame(dut, OP_WR, 0x0200 + 4 * 3, 0b001)
    _, _, val = await frame(dut, OP_RD, 0x0200 + 4 * 3)
    assert val == 0b001
    # a bad frame (unmapped address) sets err in the next STATUS and changes nothing
    await frame(dut, OP_RD, 0x7FFC)
    status, _, _ = await frame(dut, OP_RD, 0x1000)
    assert status & 0x40, "err must be set after an unmapped access"


# ALU + CRC program, loaded and run through the management port. Generated with host/asm.py:
#   CRC RST; R0 <- N (TX FIFO); R1 = 0 (sum); R2 = 0 (xor)
#   loop: while R0 != 0: R3 <- next TX word; CRC BYTE R3; R1 += R3; R2 ^= R3; R0 -= 1
#   then RX FIFO <- CRC register, R1, R2; HALT.  The CRC unit resets to CRC-32 (init/xorout 0xFFFFFFFF, reflected).
PROG_ALU_CRC = [
    0xD8000000, 0xC0000050, 0xA9000000, 0xAA000000, 0xB4010000, 0xB800000C, 0xC0000053, 0xDE000003,
    0xB0960000, 0xB2A60000, 0xB1010001, 0x10000004, 0xC0000044, 0xC8000034, 0xC8000031, 0xC8000032,
    0x18000000,
]


@cocotb.test()
async def test_alu_crc_program(dut):
    await reset(dut)
    for k, w in enumerate(PROG_ALU_CRC):
        await frame(dut, OP_WR, 0x1400 + 4 * k, w)  # engine 0 instruction memory
    await frame(dut, OP_WR, 0x1000, 1)  # RUN engine 0
    for msg in (b"123456789", bytes(range(1, 21))):
        for w in [len(msg)] + list(msg):
            for _ in range(200):
                status, _, _ = await frame(dut, OP_WR, 0x1200, w)
                if not status & 0x04:  # TX FIFO of engine 0 was not full: the word was taken
                    break
            else:
                assert False, "the engine never took a TX word: program not running"
        got = []
        for _ in range(400):
            status, _, val = await frame(dut, OP_RD, 0x1204)
            if status & 1:
                got.append(val)
            if len(got) == 3:
                break
        xor = 0
        for b in msg:
            xor ^= b
        import zlib
        assert got == [zlib.crc32(msg), sum(msg), xor], [hex(g) for g in got]
        if msg == b"123456789":
            assert got[0] == 0xCBF43926  # the published CRC-32 check value
        # the program halts after one message; restart it for the next one
        await frame(dut, OP_WR, 0x1000, 0)
        await frame(dut, OP_WR, 0x1000, 1)
