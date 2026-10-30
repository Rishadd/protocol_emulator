import re, sys
S = r"C:\Users\risha\AppData\Local\Temp\claude\c--Data-protocol-emulator\b36923da-a059-4318-a092-90a298279c3f\scratchpad"
LEF = r"C:\Data\protocol_emulator_shmem\macro\RM_IHPSG13_2P_512x32_c2_bm_bist\RM_IHPSG13_2P_512x32_c2_bm_bist.lef"
X0, Y0, H = 509.6, 13.78, 219.77            # macro origin, flipped vertically (FS): y' = Y0 + H - y

# macro power bars: (net, x0, x1, y0, y1) in absolute um
bars = []
pin = None
for line in open(LEF):
    t = line.split()
    if len(t) >= 2 and t[0] == "PIN":
        pin = t[1] if t[1] in ("VDD!", "VSS!", "VDDARRAY!") else None
    elif pin and len(t) >= 5 and t[0] == "RECT":
        a, b, c, d = map(float, t[1:5])
        net = "VGND" if pin == "VSS!" else "VPWR"
        bars.append((net, pin, X0 + a, X0 + c, Y0 + H - d, Y0 + H - b))
print("macro bars:", len(bars), "VPWR-type", sum(1 for b in bars if b[0] == "VPWR"), "VGND-type", sum(1 for b in bars if b[0] == "VGND"))

# stripes from the DEF special nets
stripes = []
net = None
for line in open(S + r"\sh3_final.def"):
    m = re.match(r"\s*-\s+(\S+)", line)
    if m and ("VPWR" in line or "VGND" in line) and "+ " not in line.split()[1:2]:
        net = m.group(1) if m.group(1) in ("VPWR", "VGND") else net
    if "SHAPE STRIPE" in line and "Metal4" in line:
        mm = re.search(r"Metal4\s+(\d+).*?\(\s*(\d+)\s+(\d+)\s*\)\s*\(\s*(\d+)\s+(\d+)\s*\)", line)
        if mm:
            w = int(mm.group(1)) / 1000
            x = int(mm.group(2)) / 1000
            stripes.append((net, x - w / 2, x + w / 2, int(mm.group(3)) / 1000, int(mm.group(5)) / 1000))
print("stripes:", len(stripes), "nets:", sorted(set(s[0] for s in stripes)))
bad = ok = 0
macro_x = (X0, X0 + 685.49)
for net, xa, xb, ya, yb in stripes:
    if xb < macro_x[0] or xa > macro_x[1]:
        continue
    hits = [(b[0], b[1]) for b in bars if xa < b[3] and xb > b[2] and ya < b[5] and yb > b[4]]
    wrong = [h for h in hits if h[0] != net]
    right = [h for h in hits if h[0] == net]
    if wrong:
        bad += 1
    elif right:
        ok += 1
    print(f"{net} stripe x {xa:8.3f}..{xb:8.3f}: overlaps right-net bars {len(right)}, WRONG-net bars {len(wrong)} {sorted(set(wrong))[:2]}")
print("stripes over the macro: ok", ok, "short", bad)
