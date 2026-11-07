"""Writes a small text PDF (one portrait page, one landscape two-page spread)
for the simulator smoke test. Standard library only."""
import sys

def page_stream(lines, x0, y0, size=12, lead=16):
    out = ["BT", f"/F1 {size} Tf", f"{lead} TL", f"{x0} {y0} Td"]
    for ln in lines:
        esc = ln.replace("\\", "\\\\").replace("(", "\\(").replace(")", "\\)")
        out.append(f"({esc}) Tj T*")
    out.append("ET")
    return "\n".join(out)

body = [
    "The quick brown fox jumps over the lazy dog near the river bank.",
    "During the Second World War, Winston Churchill spoke in London.",
    "Why did so many women join the war effort? Who could have known?",
    "In May 1940 the war effort changed the lives of women in Britain.",
] * 6

pages = []
# Portrait page with a folio at the bottom.
pages.append(((612, 792), page_stream(body, 72, 720) + "\n" + page_stream(["12"], 300, 40)))
# Landscape spread: two columns separated by a gutter, folios 13 / 14.
left = page_stream([l[:48] for l in body], 50, 560, size=11, lead=15)
right = page_stream([l[:48] for l in body], 446, 560, size=11, lead=15)
folios = page_stream(["13"], 200, 30) + "\n" + page_stream(["14"], 590, 30)
pages.append(((792, 612), left + "\n" + right + "\n" + folios))

objs = []
def add(s):
    objs.append(s)
    return len(objs)

font = add("<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>")
pages_id_placeholder = len(objs) + 1
add("PAGES")  # filled below
kids = []
for (w, h), content in pages:
    data = content.encode("latin-1")
    cid = add(f"<< /Length {len(data)} >>\nstream\n{content}\nendstream")
    pid = add(f"<< /Type /Page /Parent {pages_id_placeholder} 0 R /MediaBox [0 0 {w} {h}] "
              f"/Resources << /Font << /F1 {font} 0 R >> >> /Contents {cid} 0 R >>")
    kids.append(pid)
objs[pages_id_placeholder - 1] = (f"<< /Type /Pages /Kids [{' '.join(f'{k} 0 R' for k in kids)}] "
                                  f"/Count {len(kids)} >>")
catalog = add(f"<< /Type /Catalog /Pages {pages_id_placeholder} 0 R >>")

out = bytearray(b"%PDF-1.4\n")
offsets = []
for i, o in enumerate(objs, 1):
    offsets.append(len(out))
    out += f"{i} 0 obj\n{o}\nendobj\n".encode("latin-1")
xref = len(out)
out += f"xref\n0 {len(objs) + 1}\n0000000000 65535 f \n".encode()
for off in offsets:
    out += f"{off:010d} 00000 n \n".encode()
out += f"trailer\n<< /Size {len(objs) + 1} /Root {catalog} 0 R >>\nstartxref\n{xref}\n%%EOF\n".encode()
open(sys.argv[1], "wb").write(out)
