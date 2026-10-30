LEF = r"C:\Data\protocol_emulator_shmem\macro\RM_IHPSG13_2P_512x32_c2_bm_bist\RM_IHPSG13_2P_512x32_c2_bm_bist.lef"
X0 = 509.6
cols = {}
pin = None
for line in open(LEF):
    t = line.split()
    if len(t) >= 2 and t[0] == "PIN":
        pin = t[1] if t[1] in ("VDD!", "VSS!", "VDDARRAY!") else None
    elif pin and len(t) >= 5 and t[0] == "RECT":
        a, b, c, d = map(float, t[1:5])
        cols.setdefault((round(a, 3), round(c, 3)), set()).add(pin)
xs = sorted(cols)
print("columns:", len(xs))
prev = None
for a, c in xs:
    nets = "/".join(sorted(cols[(a, c)]))
    gap = "" if prev is None else f"  step {a - prev:6.3f}"
    print(f"macro x {a:8.3f}..{c:8.3f} (abs centre {X0 + (a + c) / 2:8.3f}) {nets:14s}{gap}")
    prev = a
