LEF = r"C:\Data\protocol_emulator_shmem\macro\RM_IHPSG13_2P_512x32_c2_bm_bist\RM_IHPSG13_2P_512x32_c2_bm_bist.lef"
X0, MW = 509.6, 685.49
CORE_L, CORE_R, W, GAP = 2.88, 1721.3, 2.1, 8.84          # stripe width 2.1, VPWR->VGND centre distance GAP
bars = []; pin = None
for line in open(LEF):
    t = line.split()
    if len(t) >= 2 and t[0] == "PIN": pin = t[1] if t[1] in ("VDD!", "VSS!", "VDDARRAY!") else None
    elif pin and len(t) >= 5 and t[0] == "RECT":
        a, b, c, d = map(float, t[1:5]); bars.append(("VGND" if pin == "VSS!" else "VPWR", X0 + a, X0 + c))
def ov(xa, xb, b): return xa < b[2] and xb > b[1]
best = []
for pitch in (35.36, 53.04, 70.72):
    n = int(40 * 1.0)
    for i in range(0, int(pitch / 0.025)):
        c0 = i * 0.025                                  # first VPWR stripe centre (absolute x), 0 <= c0 < pitch
        wrong = right_p = right_g = 0
        k = 0
        while True:
            xp = c0 + k * pitch
            if xp > CORE_R: break
            for net, xc in (("VPWR", xp), ("VGND", xp + GAP)):
                xa, xb = xc - W / 2, xc + W / 2
                if xb < X0 or xa > X0 + MW: continue
                hits = [b for b in bars if ov(xa, xb, b)]
                if any(b[0] != net for b in hits): wrong += 1
                elif hits:
                    if net == "VPWR": right_p += 1
                    else: right_g += 1
            k += 1
        if wrong == 0 and right_p >= 3 and right_g >= 3:
            best.append((pitch, round(c0, 3), right_p, right_g))
print("clean (pitch, first VPWR centre, VPWR stripes on VDD bars, VGND stripes on VSS bars): ", len(best))
for b in best[:5] + best[-5:]: print(b)
by = {}
for b in best: by.setdefault(b[0], []).append(b)
for p, l in by.items(): print("pitch", p, ": offsets", l[0][1], "..", l[-1][1], "count", len(l))

print()
for p, l in by.items():
    offs = [b[1] for b in l]
    runs, start, prev = [], offs[0], offs[0]
    for o in offs[1:]:
        if o - prev > 0.026:
            runs.append((start, prev)); start = o
        prev = o
    runs.append((start, prev))
    print("pitch", p, "contiguous windows (first VPWR centre):", [(round(a, 3), round(b, 3), round(b - a, 3)) for a, b in runs])
