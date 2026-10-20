#!/usr/bin/env python3
"""Build docs/USER_GUIDE.html from docs/USER_GUIDE.md (no dependencies):  python3 docs/build_user_guide.py
One self-contained HTML file: a fixed contents sidebar (clickable, follows the scroll position, filterable), the full contents list under the "Contents"
heading, tables, code blocks, links, and a highlighted style for the [PLACEHOLDER] markers. Edit the Markdown, never the HTML."""
import html
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "USER_GUIDE.md")
OUT = os.path.join(HERE, "USER_GUIDE.html")


def slug(text, used):
    s = re.sub(r"[^a-z0-9]+", "-", text.lower()).strip("-") or "section"
    base, n = s, 2
    while s in used:
        s = f"{base}-{n}"
        n += 1
    used.add(s)
    return s


def inline(text):
    toks = []

    def keep(h):
        toks.append(h)
        return f"\x00{len(toks) - 1}\x00"

    text = re.sub(r"`([^`]+)`", lambda m: keep(f"<code>{html.escape(m.group(1))}</code>"), text)
    text = re.sub(r"\[([^\]]+)\]\((https?://[^)\s]+)\)",
                  lambda m: keep(f'<a href="{html.escape(m.group(2))}" target="_blank" rel="noopener">{inline(m.group(1))}</a>'), text)
    text = re.sub(r"(?<![\"\w/])(https?://[^\s<)|]+)",
                  lambda m: keep(f'<a href="{html.escape(m.group(1))}" target="_blank" rel="noopener">{html.escape(m.group(1))}</a>'), text)
    text = html.escape(text)
    text = re.sub(r"\*\*\[PLACEHOLDER\]\*\*", '<span class="ph">PLACEHOLDER</span>', text)
    text = re.sub(r"\*\*(.+?)\*\*", r"<strong>\1</strong>", text)
    text = re.sub(r"(?<![\w*])\*([^*\n]+?)\*(?![\w*])", r"<em>\1</em>", text)
    return re.sub(r"\x00(\d+)\x00", lambda m: toks[int(m.group(1))], text)


def parse(md):
    lines = md.split("\n")
    body, toc, used = [], [], set()
    i, title = 0, None
    while i < len(lines):
        ln = lines[i]
        if ln.startswith("```"):
            j = i + 1
            code = []
            while j < len(lines) and not lines[j].startswith("```"):
                code.append(lines[j])
                j += 1
            body.append(f"<pre><code>{html.escape(chr(10).join(code))}</code></pre>")
            i = j + 1
            continue
        m = re.match(r"^(#{1,4}) (.*)$", ln)
        if m:
            lvl, text = len(m.group(1)), m.group(2).strip()
            if lvl == 1 and title is None:
                title = text
                body.append(f'<h1 class="doc-title">{html.escape(text)}</h1>')
            else:
                hid = slug(text, used)
                toc.append((lvl, text, hid))
                body.append(f'<h{lvl} id="{hid}"><a class="anchor" href="#{hid}">#</a>{html.escape(text)}</h{lvl}>')
                if lvl == 2 and text == "Contents":
                    body.append("<!--TOC-->")
            i += 1
            continue
        if ln.startswith("|") and i + 1 < len(lines) and re.match(r"^\|[\s:|-]+\|$", lines[i + 1]):
            head = [c.strip() for c in ln.strip().strip("|").split("|")]
            rows = []
            j = i + 2
            while j < len(lines) and lines[j].startswith("|"):
                rows.append([c.strip() for c in lines[j].strip().strip("|").split("|")])
                j += 1
            t = "<div class='tw'><table><thead><tr>" + "".join(f"<th>{inline(c)}</th>" for c in head) + "</tr></thead><tbody>"
            for r in rows:
                t += "<tr>" + "".join(f"<td>{inline(c)}</td>" for c in r) + "</tr>"
            body.append(t + "</tbody></table></div>")
            i = j
            continue
        if ln.startswith("> "):
            j, q = i, []
            while j < len(lines) and lines[j].startswith("> "):
                q.append(lines[j][2:])
                j += 1
            body.append(f"<blockquote>{inline(' '.join(q))}</blockquote>")
            i = j
            continue
        if ln.startswith("- "):
            j, items = i, []
            while j < len(lines) and (lines[j].startswith("- ") or (lines[j].startswith("  ") and lines[j].strip() and items)):
                if lines[j].startswith("- "):
                    items.append(lines[j][2:])
                else:
                    items[-1] += " " + lines[j].strip()
                j += 1
            body.append("<ul>" + "".join(f"<li>{inline(x)}</li>" for x in items) + "</ul>")
            i = j
            continue
        if not ln.strip():
            i += 1
            continue
        j, para = i, []
        while j < len(lines) and lines[j].strip() and not re.match(r"^(#{1,4} |```|\||> |- )", lines[j]):
            para.append(lines[j].strip())
            j += 1
        if not para:
            para, j = [ln.strip()], i + 1
        body.append(f"<p>{inline(' '.join(para))}</p>")
        i = j
    return title or "User Guide", body, toc


def build_toc(toc):
    """Groups: front matter, each part (h1) with its chapters (h2) and their sections (h3), appendices."""
    groups, cur = [], None
    for lvl, text, hid in toc:
        if lvl == 1:
            cur = {"title": text, "id": hid, "chapters": []}
            groups.append(cur)
        elif lvl == 2:
            if cur is None:
                cur = {"title": "Front matter", "id": None, "chapters": []}
                groups.append(cur)
            cur["chapters"].append({"title": text, "id": hid, "sections": []})
        elif lvl == 3 and cur and cur["chapters"]:
            cur["chapters"][-1]["sections"].append((text, hid))
    return groups


def nav_html(groups):
    out = []
    for g in groups:
        head = f'<a class="part" href="#{g["id"]}">{html.escape(g["title"])}</a>' if g["id"] else f'<div class="part">{html.escape(g["title"])}</div>'
        out.append(f'<div class="grp">{head}')
        for c in g["chapters"]:
            secs = "".join(f'<a class="sec" href="#{h}">{html.escape(t)}</a>' for t, h in c["sections"])
            if secs:
                out.append(f'<details><summary><a class="ch" href="#{c["id"]}">{html.escape(c["title"])}</a></summary>{secs}</details>')
            else:
                out.append(f'<div class="single"><a class="ch" href="#{c["id"]}">{html.escape(c["title"])}</a></div>')
        out.append("</div>")
    return "".join(out)


def contents_html(groups):
    out = ['<div class="contents">']
    for g in groups:
        out.append(f'<h4>{html.escape(g["title"])}</h4><ul>')
        for c in g["chapters"]:
            out.append(f'<li><a href="#{c["id"]}"><b>{html.escape(c["title"])}</b></a>')
            if c["sections"]:
                out.append("<ul>" + "".join(f'<li><a href="#{h}">{html.escape(t)}</a></li>' for t, h in c["sections"]) + "</ul>")
            out.append("</li>")
        out.append("</ul>")
    return "".join(out) + "</div>"


CSS = """
:root{--bg:#fbfbfa;--fg:#1c1f23;--mut:#5c6670;--line:#dfe3e7;--acc:#1f5fbf;--card:#ffffff;--code:#f0f2f4;--ph:#fff3c4;--phb:#e0b100;--side:#f3f4f6}
@media(prefers-color-scheme:dark){:root{--bg:#14171a;--fg:#e4e7ea;--mut:#98a2ad;--line:#2b3238;--acc:#79a9f5;--card:#1a1e22;--code:#22272c;--ph:#4a3f10;--phb:#d9ab00;--side:#171b1f}}
*{box-sizing:border-box}html{scroll-behavior:smooth;scroll-padding-top:16px}
body{margin:0;background:var(--bg);color:var(--fg);font:16px/1.6 system-ui,-apple-system,Segoe UI,Roboto,sans-serif}
nav#side{position:fixed;top:0;left:0;bottom:0;width:320px;overflow-y:auto;background:var(--side);border-right:1px solid var(--line);padding:14px 12px 40px;font-size:14px}
nav#side input{width:100%;padding:7px 9px;border:1px solid var(--line);border-radius:6px;background:var(--card);color:var(--fg);margin-bottom:10px}
nav#side .brand{font-weight:700;margin:2px 4px 10px}
nav#side a{color:var(--fg);text-decoration:none;display:block;padding:2px 6px;border-radius:5px}
nav#side a:hover{background:var(--line)}nav#side a.on{background:var(--acc);color:#fff}
nav#side .part{font-weight:700;margin-top:12px;color:var(--mut);text-transform:uppercase;font-size:12px;letter-spacing:.04em}
nav#side summary{cursor:pointer;list-style:none;padding:0}nav#side summary::-webkit-details-marker{display:none}
nav#side .ch{font-weight:600}nav#side .sec{padding-left:20px;color:var(--mut);font-size:13px}nav#side .single .ch{font-weight:500}
main{margin-left:320px;max-width:980px;padding:28px 40px 120px}
h1.doc-title{font-size:2rem;margin:.2em 0 .6em}h1{font-size:1.7rem;border-bottom:2px solid var(--line);padding-bottom:.3em;margin-top:2.2em}
h2{font-size:1.4rem;margin-top:2em;border-bottom:1px solid var(--line);padding-bottom:.2em}h3{font-size:1.1rem;margin-top:1.5em}h4{margin:1em 0 .3em}
.anchor{color:var(--mut);text-decoration:none;margin-right:.4em;opacity:0;font-weight:400}h1:hover .anchor,h2:hover .anchor,h3:hover .anchor{opacity:1}
a{color:var(--acc)}code{background:var(--code);padding:.1em .35em;border-radius:4px;font-size:.92em}
pre{background:var(--code);padding:12px 14px;border-radius:8px;overflow-x:auto}pre code{background:none;padding:0}
.tw{overflow-x:auto}table{border-collapse:collapse;width:100%;margin:.6em 0;background:var(--card);font-size:.95em}
th,td{border:1px solid var(--line);padding:6px 10px;text-align:left;vertical-align:top}th{background:var(--side)}
blockquote{margin:.8em 0;padding:.5em 1em;background:var(--ph);border-left:4px solid var(--phb);border-radius:4px}
.ph{background:var(--phb);color:#000;font-size:.72em;font-weight:700;padding:.1em .45em;border-radius:4px;letter-spacing:.03em;vertical-align:.1em}
.contents{columns:2;column-gap:40px;background:var(--card);border:1px solid var(--line);border-radius:10px;padding:10px 24px}
.contents ul{margin:.2em 0 .5em;padding-left:1.1em}.contents li{break-inside:avoid;font-size:.95em}.contents h4{break-after:avoid;color:var(--mut)}
@media(max-width:900px){nav#side{position:static;width:auto;border-right:0;border-bottom:1px solid var(--line);max-height:50vh}main{margin-left:0;padding:16px}.contents{columns:1}}
"""

JS = """
const links=[...document.querySelectorAll('nav#side a[href^="#"]')];
const heads=[...document.querySelectorAll('main h1[id],main h2[id],main h3[id]')];
function spy(){let cur=null;for(const h of heads){if(h.getBoundingClientRect().top<120)cur=h;else break}
 links.forEach(a=>a.classList.remove('on'));
 if(cur){const a=links.find(x=>x.getAttribute('href')==='#'+cur.id);if(a){a.classList.add('on');const d=a.closest('details');
  document.querySelectorAll('nav#side details').forEach(x=>{if(x!==d)x.open=false});if(d)d.open=true;
  const r=a.getBoundingClientRect(),s=document.getElementById('side').getBoundingClientRect();if(r.top<s.top+50||r.bottom>s.bottom-10)a.scrollIntoView({block:'center'})}}}
addEventListener('scroll',spy,{passive:true});spy();
document.getElementById('flt').addEventListener('input',e=>{const q=e.target.value.toLowerCase();
 document.querySelectorAll('nav#side details').forEach(d=>{const hit=!q||d.textContent.toLowerCase().includes(q);d.style.display=hit?'':'none';if(q&&hit)d.open=true});
 document.querySelectorAll('nav#side .single').forEach(d=>{d.style.display=(!q||d.textContent.toLowerCase().includes(q))?'':'none'})});
"""


def main():
    md = open(SRC, encoding="utf8").read()
    title, body, toc = parse(md)
    groups = build_toc(toc)
    page = "\n".join(body).replace("<!--TOC-->", contents_html(groups))
    doc = (f'<!doctype html><html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">'
           f"<title>{html.escape(title)}</title><style>{CSS}</style></head><body>"
           f'<nav id="side"><div class="brand">{html.escape(title)}</div><input id="flt" type="search" placeholder="Filter contents...">{nav_html(groups)}</nav>'
           f"<main>{page}</main><script>{JS}</script></body></html>")
    open(OUT, "w", encoding="utf8").write(doc)
    heads = sum(1 for _ in toc)
    print(f"wrote {OUT}: {len(doc) // 1024} KB, {heads} headings, {sum(len(g['chapters']) for g in groups)} chapters")


if __name__ == "__main__":
    sys.exit(main())
