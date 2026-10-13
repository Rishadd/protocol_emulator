#!/usr/bin/env python3
"""Phase 7 checks of the toolchain and the library (docs/TWO_TIER_MEMORY_PLAN.md V7.1-V7.3, V7.5, V7.7).

V7.1  link(): relocation of labels in both tiers, JPH/JPL/COPY operands, overflow and label errors
V7.3  fetchcheck.hot() refuses a hot loop in L2 that has an urgent way in, accepts it in L1
V7.2  fetchcheck on the UART TX loop placed in L2 predicts 1 urgent fetch per bit (DJNZ -> OUT1), the
      bound measured in V4.5 (at most 1 clock late per bit under worst contention)
V7.5/V7.7  tb_library: the engine installs UART TX, SPI master, I2C master, UART RX, UART TX from the L2
      library by itself and each works
"""
import os
import subprocess
import sys

import fetchcheck
import isa
import library
import link
import uart_workload as uw

ROOT = uw.ROOT
errs = []


def check(ok, msg):
    if not ok:
        errs.append(msg)


# V7.1
p = link.link([("lab", "a"), ("NOP", 0), ("JMP", "b"), (".l2",), ("lab", "b"), ("JPH", (3, "a")),
               ("COPY", ("b", 5, 2)), ("DJNZ", "b")], l2_base=0x20)
check(p["sym"] == {"a": 0, "b": 0x120}, f"symbols {p['sym']}")
check(p["l1"][1] == isa.enc("JMP", 0x120), "JMP to an L2 label")
check(p["l2"][0x20] == isa.enc("JPH", (3, 0)) and p["l2"][0x21] == isa.enc("COPY", (0x20, 5, 2)), "JPH / COPY operands")
check(p["l2"][0x22] == isa.enc("DJNZ", 0x120) and (p["lo"], p["hi"]) == (0x20, 0x22), "L2 placement and range")
for bad in ([("NOP", 0)] * 65, [("lab", "x"), ("lab", "x")], [(".l2",)] + [("NOP", 0)] * 257, [("JMP", "nowhere")]):
    try:
        link.link(bad)
        errs.append(f"accepted a bad program ({len(bad)} items)")
    except (AssertionError, KeyError):
        pass
print("V7.1 linker checks done")

# V7.3: a one-clock polling loop is hot: refused in L2, fine in L1
loop = [("lab", "s"), ("JPH", (1, "s")), ("JMP", "s"), ("lab", "e")]
try:
    fetchcheck.hot(link.link([(".l2",)] + loop), [("s", "e")])
    errs.append("hot loop in L2 accepted")
except AssertionError:
    pass
fetchcheck.hot(link.link(loop), [("s", "e")])
print("V7.3 hot-placement refusal done")

# V7.2: UART TX loop in L2 (relocated): OUT1 432 -> DJNZ covered, DJNZ -> OUT1 urgent
D = 432
tx = uw.uart_tx_program(D)[:12]
items = [(".l2",)] + [(isa.NAME[w >> 27], library._operand(w) + 0x100 if (w >> 27) in (2, 5) else library._operand(w))
                      for w in tx]
ways = fetchcheck.check(link.link(items))
check(ways[0x107] == 1 and ways[0x108] == 0, f"UART loop ways: OUT1 {ways[0x107]}, DJNZ {ways[0x108]}")
print(f"V7.2 UART TX in L2: urgent ways into OUT1 = {ways[0x107]}, into DJNZ = {ways[0x108]} (measured V4.5: <= 1 clock per bit)")

# V7.5 / V7.7: library run
lib = library.build()
d = os.path.join(ROOT, "build", "library")
os.makedirs(d, exist_ok=True)
isa.write_hex([lib["l2"].get(i, isa.enc("HALT")) for i in range(256)], os.path.join(d, "l2.hex"))
srcs = sorted(os.path.join(ROOT, "src", f) for f in os.listdir(os.path.join(ROOT, "src")) if f.endswith(".v"))
sims = sorted(os.path.join(ROOT, "sim", "ihp_sram", f) for f in os.listdir(os.path.join(ROOT, "sim", "ihp_sram")) if f.endswith(".v"))
vvp = os.path.join(d, "tb_library.vvp")
subprocess.run(["iverilog", "-g2012", "-Wall", "-Wno-timescale", "-DFUNCTIONAL", "-s", "tb_library", "-I", os.path.join(ROOT, "src"),
                "-I", os.path.join(ROOT, "tb"), "-o", vvp, os.path.join(ROOT, "tb", "tb_library.v"),
                os.path.join(ROOT, "tb", "i2c_slave_model.v"), *srcs, *sims], check=True)
args = [f"+L2PROG={os.path.join(d, 'l2.hex')}", f"+RV={lib['rv']}", f"+RANGE={lib['hi'] << 8 | lib['lo']}"]
args += [f"+CMD{k}={library.command(k)}" for k in range(6)]
r = subprocess.run(["vvp", "-n", vvp, *args], capture_output=True, text=True)
print("\n".join(l for l in r.stdout.splitlines() if "FAIL" in l or "RESULT" in l))
check("RESULT tb_library: PASS" in r.stdout, "tb_library")

for e in errs:
    print("  FAIL", e)
print(f"RESULT test_toolchain: {'PASS' if not errs else f'FAIL ({len(errs)} errors)'}")
sys.exit(1 if errs else 0)
