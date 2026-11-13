#!/usr/bin/env python3
"""Render README screenshots (SVG) from a real asmspeed run.

    python3 tools/mkshot.py [path/to/asmspeed] [out_dir]

Runs the binary on a pseudo-terminal (so colours and the live bar are on),
feeds the escape-code stream through a small terminal emulator and writes:

    screenshot-live.svg      mid-test, upload in progress
    screenshot-results.svg   the finished run

Your public IP and ASN are masked before anything is rendered or written, and
the script refuses to write a file that still contains the IP.
"""
import os
import pty
import re
import select
import sys
import time

BIN = sys.argv[1] if len(sys.argv) > 1 else "build/asmspeed"
OUT = sys.argv[2] if len(sys.argv) > 2 else "docs"

CW, CH = 9.0, 20.0           # cell size in px
PAD_X, PAD_TOP, PAD_BOT = 24, 52, 22
FG, BG = "#c0caf5", "#1a1b26"
DIM = "#6c7293"
ANSI = {30: "#414868", 31: "#f7768e", 32: "#9ece6a", 33: "#e0af68", 34: "#7aa2f7",
        35: "#bb9af7", 36: "#7dcfff", 37: "#c0caf5"}


def run_capture():
    out = b""
    pid, fd = pty.fork()
    if pid == 0:
        os.execv(BIN, [BIN])
    t0 = time.time()
    while time.time() - t0 < 120:
        r, _, _ = select.select([fd], [], [], 1)
        if r:
            try:
                d = os.read(fd, 65536)
            except OSError:
                break
            if not d:
                break
            out += d
    os.waitpid(pid, 0)
    return out.decode("utf-8", "replace")


def color256(n):
    if n < 8:
        return ANSI[30 + n]
    if n < 16:
        return ANSI[30 + n - 8]
    if n >= 232:
        v = 8 + (n - 232) * 10
        return "#%02x%02x%02x" % (v, v, v)
    n -= 16
    lv = [0, 95, 135, 175, 215, 255]
    return "#%02x%02x%02x" % (lv[n // 36], lv[(n // 6) % 6], lv[n % 6])


TOKEN = re.compile(r"\x1b\[([0-9;?]*)([A-Za-z])|(.)", re.S)


def emulate(text):
    """Tiny terminal: \\r, \\n, SGR colours, ESC[K. Returns rows of (char, fg, bold, dim)."""
    rows = [[]]
    r = c = 0
    fg, bold, dim = None, False, False
    for m in TOKEN.finditer(text):
        if m.group(3) is None:
            params, cmd = m.group(1), m.group(2)
            if cmd == "m":
                p = [int(x) if x else 0 for x in params.split(";")] if params else [0]
                i = 0
                while i < len(p):
                    v = p[i]
                    if v == 0:
                        fg, bold, dim = None, False, False
                    elif v == 1:
                        bold = True
                    elif v == 2:
                        dim = True
                    elif v == 22:
                        bold = dim = False
                    elif 30 <= v <= 37:
                        fg = ANSI[v]
                    elif v == 39:
                        fg = None
                    elif v == 38 and i + 2 < len(p) and p[i + 1] == 5:
                        fg = color256(p[i + 2])
                        i += 2
                    i += 1
            elif cmd == "K":
                del rows[r][c:]
            continue
        ch = m.group(3)
        if ch == "\r":
            c = 0
        elif ch == "\n":
            r += 1
            c = 0
            while len(rows) <= r:
                rows.append([])
        elif ch >= " ":
            row = rows[r]
            while len(row) < c:
                row.append((" ", None, False, False))
            cell = (ch, fg, bold, dim)
            if c < len(row):
                row[c] = cell
            else:
                row.append(cell)
            c += 1
    return rows


def esc(s):
    return s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")


def svg(rows, prompt="asmspeed"):
    while rows and not any(ch != " " for ch, *_ in rows[-1]):
        rows = rows[:-1]
    while rows and not any(ch != " " for ch, *_ in rows[0]):
        rows = rows[1:]
    cols = max([len(r) for r in rows] + [len(prompt) + 2]) + 2
    w = int(cols * CW + 2 * PAD_X)
    h = int((len(rows) + 1) * CH + PAD_TOP + PAD_BOT)
    o = ['<svg xmlns="http://www.w3.org/2000/svg" width="%d" height="%d" viewBox="0 0 %d %d" '
         'font-family="\'DejaVu Sans Mono\',\'JetBrains Mono\',\'Fira Code\',Menlo,Consolas,monospace" '
         'font-size="15">' % (w, h, w, h),
         '<rect width="%d" height="%d" rx="10" fill="%s"/>' % (w, h, BG),
         '<rect width="%d" height="32" rx="10" fill="#16161e"/><rect y="22" width="%d" height="10" fill="#16161e"/>' % (w, w),
         '<circle cx="22" cy="16" r="6" fill="#f7768e"/><circle cx="42" cy="16" r="6" fill="#e0af68"/>'
         '<circle cx="62" cy="16" r="6" fill="#9ece6a"/>']

    def line(y, cells):
        for x, (ch, fg, bold, dim) in enumerate(cells):
            if ch == " ":
                continue
            col = fg or (DIM if dim else ("#ffffff" if bold else FG))
            if dim and fg:
                col = DIM
            o.append('<text x="%.1f" y="%.1f" fill="%s"%s>%s</text>' % (
                PAD_X + x * CW, y, col, ' font-weight="bold"' if bold else "", esc(ch)))

    y = PAD_TOP
    line(y, [("$", "#9ece6a", True, False), (" ", None, False, False)] +
         [(ch, None, False, False) for ch in prompt])
    for row in rows:
        y += CH
        line(y, row)
    o.append("</svg>")
    return "\n".join(o)


def main():
    raw = run_capture()
    plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", raw)
    m = re.search(r"Connection\s+(\d+\.\d+\.\d+\.\d+)", plain)
    secrets = []
    if m:
        secrets.append(m.group(1))
        raw = raw.replace(m.group(1), "***.***.***.***")
    raw = re.sub(r"AS\d+", "AS*****", raw)

    # live frame: partway through the upload (the 45th redraw of that phase)
    marks = [x.start() for x in re.finditer(r"Measuring Upload", raw)]
    live = raw[: marks[min(45, len(marks) - 1)] + 40] if marks else raw
    os.makedirs(OUT, exist_ok=True)
    for name, text in (("screenshot-live.svg", live), ("screenshot-results.svg", raw)):
        doc = svg(emulate(text))
        for s in secrets:
            assert s not in doc, "unmasked IP in " + name
        assert not re.search(r"AS\d{3,}", doc), "unmasked ASN in " + name
        with open(os.path.join(OUT, name), "w", encoding="utf-8") as f:
            f.write(doc)
        print("wrote", os.path.join(OUT, name), len(doc), "bytes")


if __name__ == "__main__":
    main()
