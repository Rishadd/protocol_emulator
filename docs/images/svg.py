"""Tiny SVG toolkit for the user guide figures (no dependencies). Every figure is a white card so it reads well on a light or dark page."""
import html

FONT = "DejaVu Sans, Verdana, Arial, sans-serif"
INK, MUT, LINE = "#1c2733", "#5c6670", "#2b3a4a"
PAL = {  # name: (fill, stroke)
    "blue": ("#dbe8fb", "#2a5db0"), "green": ("#dff3e3", "#2e7d46"), "orange": ("#fde8d0", "#c46a12"), "grey": ("#eef0f3", "#5c6670"),
    "yellow": ("#fff3c4", "#b38f00"), "red": ("#fbdcdc", "#b32d2d"), "purple": ("#ece0f7", "#7a3fb0"), "white": ("#ffffff", "#2b3a4a"),
    "teal": ("#d6f1ef", "#1f7f78"),
}


class Svg:
    def __init__(self, w, h, title=""):
        self.w, self.h, self.items = w, h, []
        self.defs = ('<defs><marker id="ah" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
                     f'<path d="M0,0 L10,5 L0,10 z" fill="{LINE}"/></marker>'
                     '<marker id="ahg" viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">'
                     f'<path d="M0,0 L10,5 L0,10 z" fill="{MUT}"/></marker></defs>')
        self.title = title

    # --- primitives
    def rect(self, x, y, w, h, color="white", r=6, sw=1.5, dash=None, fill=None, stroke=None):
        f, s = PAL[color]
        d = f' stroke-dasharray="{dash}"' if dash else ""
        self.items.append(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="{r}" fill="{fill or f}" stroke="{stroke or s}" stroke-width="{sw}"{d}/>')

    def text(self, x, y, s, size=13, anchor="middle", weight="normal", fill=INK, italic=False, rot=None):
        st = ' font-style="italic"' if italic else ""
        tr = f' transform="rotate({rot} {x} {y})"' if rot is not None else ""
        self.items.append(f'<text x="{x}" y="{y}" font-family="{FONT}" font-size="{size}" text-anchor="{anchor}" font-weight="{weight}" fill="{fill}"{st}{tr}>{html.escape(str(s))}</text>')

    def lines(self, x, y, rows, size=13, anchor="middle", gap=None, weight="normal", fill=INK):
        gap = gap or size * 1.3
        for i, r in enumerate(rows):
            self.text(x, y + i * gap, r, size, anchor, weight, fill)

    def line(self, x1, y1, x2, y2, color=LINE, sw=1.6, dash=None, arrow=False, both=False, grey_arrow=False):
        d = f' stroke-dasharray="{dash}"' if dash else ""
        m = ""
        mk = "ahg" if grey_arrow else "ah"
        if arrow:
            m += f' marker-end="url(#{mk})"'
        if both:
            m += f' marker-start="url(#{mk})"'
        self.items.append(f'<line x1="{x1}" y1="{y1}" x2="{x2}" y2="{y2}" stroke="{color}" stroke-width="{sw}"{d}{m}/>')

    def path(self, d, color=LINE, sw=1.6, fill="none", arrow=False, dash=None):
        m = ' marker-end="url(#ah)"' if arrow else ""
        da = f' stroke-dasharray="{dash}"' if dash else ""
        self.items.append(f'<path d="{d}" stroke="{color}" stroke-width="{sw}" fill="{fill}"{m}{da}/>')

    def poly(self, pts, color="grey", sw=1.5):
        f, s = PAL[color]
        self.items.append(f'<polygon points="{" ".join(f"{x},{y}" for x, y in pts)}" fill="{f}" stroke="{s}" stroke-width="{sw}"/>')

    def circle(self, x, y, r, color="white", sw=1.5):
        f, s = PAL[color]
        self.items.append(f'<circle cx="{x}" cy="{y}" r="{r}" fill="{f}" stroke="{s}" stroke-width="{sw}"/>')

    # --- composites
    def box(self, x, y, w, h, title, sub=None, color="blue", size=14, r=8):
        self.rect(x, y, w, h, color, r)
        if sub:
            self.text(x + w / 2, y + h / 2 - (len(sub) - 1) * 7 - 2, title, size, weight="bold")
            self.lines(x + w / 2, y + h / 2 + 14 - (len(sub) - 1) * 7, sub if isinstance(sub, list) else [sub], size - 2, fill=MUT)
        else:
            self.text(x + w / 2, y + h / 2 + size * 0.35, title, size, weight="bold")

    def wire(self, pts, label=None, color=LINE, sw=1.8, lab_at=0, dy=-6, arrow=False, size=11):
        d = "M" + " L".join(f"{x},{y}" for x, y in pts)
        self.path(d, color, sw, arrow=arrow)
        if label:
            (x1, y1), (x2, y2) = pts[lab_at], pts[lab_at + 1]
            self.text((x1 + x2) / 2, (y1 + y2) / 2 + dy, label, size, fill=MUT)

    def signal(self, x0, y, bits, tbit, hi=16, name=None, color="#1f5fbf", sw=2.0, label_x=None, per=None):
        """Digital waveform from a list of 0/1 per `tbit` pixels, starting at x0 (the 1 level is y - hi, the 0 level is y)."""
        pts, prev = [], None
        for i, b in enumerate(bits):
            yy = y - hi if b else y
            x = x0 + i * tbit
            if prev is None:
                pts.append((x, yy))
            elif b != prev:
                pts.append((x, y - hi if prev else y))
                pts.append((x, yy))
            prev = b
        pts.append((x0 + len(bits) * tbit, y - hi if bits[-1] else y))
        self.path("M" + " L".join(f"{a},{b}" for a, b in pts), color, sw)
        if name:
            self.text(label_x if label_x is not None else x0 - 8, y - hi / 2 + 4, name, 12, "end", "bold")

    def save(self, path):
        body = "\n".join(self.items)
        t = f"<title>{html.escape(self.title)}</title>" if self.title else ""
        svg = (f'<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {self.w} {self.h}" width="{self.w}" height="{self.h}">{t}{self.defs}'
               f'<rect x="0.75" y="0.75" width="{self.w - 1.5}" height="{self.h - 1.5}" rx="12" fill="#ffffff" stroke="#c9d1d9" stroke-width="1.5"/>\n{body}\n</svg>\n')
        open(path, "w", encoding="utf8").write(svg)
