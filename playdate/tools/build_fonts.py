#!/usr/bin/env python3
"""Builds Navigator-Extras-Light/Bold (playdate/source/ui/fonts/): our own pixel glyphs for
the characters the SDK Nontendo fonts lack ($ # @ & ' * [ ] < > _ | ~ arrows, bullets...).
Run: python3 playdate/tools/build_fonts.py"""
import os, sys
from PIL import Image

SDK = os.path.expanduser("~/Developer/PlaydateSDK/Resources/Fonts/Nontendo")
OUT = os.path.join(os.path.dirname(__file__), "..", "source", "ui", "fonts")

def load(fnt, png, cw, ch):
    lines = open(os.path.join(SDK, fnt)).read().split("\n")
    tracking = 1
    glyphs = []
    for ln in lines:
        if ln.startswith("tracking="):
            tracking = int(ln.split("=")[1]); continue
        if not ln.strip():
            continue
        parts = ln.split("\t")
        name = parts[0]
        w = int([p for p in parts[1:] if p][0])
        glyphs.append([name, w, None])
    im = Image.open(os.path.join(SDK, png)).convert("RGBA")
    for i, g in enumerate(glyphs):
        cx, cy = (i % 16) * cw, (i // 16) * ch
        rows = []
        for y in range(ch):
            rows.append("".join("#" if (lambda p: p[3] > 128 and p[0] < 128)(im.getpixel((cx + x, cy + y))) else "." for x in range(cw)))
        g[2] = rows
    return tracking, glyphs

# 1px-stroke glyphs, rows 0..12, baseline row 9, cap height 10.
EXTRA = {
"$": ["..#..", ".####", "#.#..", "#.#..", ".###.", "..#.#", "..#.#", "..#.#", "####.", "..#.."],
"#": [".....", ".#.#.", ".#.#.", "#####", ".#.#.", ".#.#.", "#####", ".#.#.", ".#.#.", "....."],
"@": ["......", ".####.", "#....#", "#..###", "#.#..#", "#.#..#", "#..###", "#.....", ".####.", "......"],
"&": [".##..", "#..#.", "#..#.", ".##..", ".#...", "#.#.#", "#..#.", "#..#.", "#..#.", ".##.#"],
"'": ["#", "#", "#"],
"*": [".....", "..#..", "#.#.#", ".###.", "#.#.#", "..#..", ".....", ".....", ".....", "....."],
"[": ["##", "#.", "#.", "#.", "#.", "#.", "#.", "#.", "#.", "#.", "#.", "##"],
"]": ["##", ".#", ".#", ".#", ".#", ".#", ".#", ".#", ".#", ".#", ".#", "##"],
"{": [".##", ".#.", ".#.", ".#.", ".#.", "#..", ".#.", ".#.", ".#.", ".#.", ".#.", ".##"],
"}": ["##.", ".#.", ".#.", ".#.", ".#.", "..#", ".#.", ".#.", ".#.", ".#.", ".#.", "##."],
"<": ["....", "....", "...#", "..#.", ".#..", "#...", ".#..", "..#.", "...#", "...."],
">": ["....", "....", "#...", ".#..", "..#.", "...#", "..#.", ".#..", "#...", "...."],
"_": [".....", ".....", ".....", ".....", ".....", ".....", ".....", ".....", ".....", ".....", "#####"],
"|": ["#"] * 12,
"~": [".....", ".....", ".....", ".....", ".##.#", "#..#.", ".....", ".....", ".....", "....."],
"^": ["..#..", ".#.#.", "#...#"],
"\\": ["#...", "#...", "#...", ".#..", ".#..", ".#..", "..#.", "..#.", "..#.", "...#", "...#", "...#"],
"`": ["#.", ".#"],
"+": [".....", ".....", "..#..", "..#..", "..#..", "#####", "..#..", "..#..", "..#..", "....."],
"▶": ["....", "#...", "##..", "###.", "####", "#####"[:4], "###.", "##..", "#...", "...."],
"◀": ["....", "...#", "..##", ".###", "####", "####", ".###", "..##", "...#", "...."],
"▲": [".......", ".......", ".......", "...#...", "..###..", ".#####.", "#######", ".......", ".......", "......."],
"▼": [".......", ".......", ".......", "#######", ".#####.", "..###..", "...#...", ".......", ".......", "......."],
"•": ["...", "...", "...", "...", ".#.", "###", ".#.", "...", "...", "..."],
"…": [".....", ".....", ".....", ".....", ".....", ".....", ".....", ".....", ".....", "#.#.#"],
"—": [".......", ".......", ".......", ".......", ".......", "#######"],
"°": [".#.", "#.#", ".#."],
"★": [".......", "...#...", "...#...", "#######", ".#####.", "..###..", ".##.##.", ".#...#.", ".......", "......."],
"♥": [".......", ".......", ".##.##.", "#######", "#######", ".#####.", "..###..", "...#...", ".......", "......."],
"✓": [".......", ".......", "......#", ".....#.", "#...#..", ".#.#...", "..#....", ".......", ".......", "......."],
}

def extra_rows(ch, cw, chh):
    src = EXTRA[ch]
    w = max(len(r) for r in src)
    rows = []
    for y in range(chh):
        r = src[y] if y < len(src) else ""
        r = r.ljust(w, ".")
        rows.append((r + "." * cw)[:cw])
    return w, rows

def embolden(rows, w, cw):
    out = []
    for r in rows:
        n = ""
        for x in range(cw):
            on = r[x] == "#" or (x > 0 and r[x - 1] == "#")
            n += "#" if on else "."
        out.append(n)
    return w + 1, out

def write(name, tracking, glyphs, cw, ch):
    cols = 16
    nrows = (len(glyphs) + cols - 1) // cols
    im = Image.new("RGBA", (cw * cols, ch * nrows), (0, 0, 0, 0))
    for i, (gname, w, rows) in enumerate(glyphs):
        cx, cy = (i % cols) * cw, (i // cols) * ch
        for y, r in enumerate(rows[:ch]):
            for x, c in enumerate(r[:cw]):
                if c == "#":
                    im.putpixel((cx + x, cy + y), (0, 0, 0, 255))
    im.save(os.path.join(OUT, f"{name}-table-{cw}-{ch}.png"))
    with open(os.path.join(OUT, f"{name}.fnt"), "w") as f:
        f.write(f"tracking={tracking}\n\n")
        for gname, w, rows in glyphs:
            f.write(f"{gname}\t{w}\n")

# Glyphs the unmodified SDK Nontendo fonts lack. Only OUR original glyph art goes in the
# Navigator-Extras fonts; the SDK fonts themselves are used untouched (the SDK license
# forbids derivative fonts). ui/theme.lua composites base + extras at draw time.
LIGHT_EXTRAS = "$#@&'*[]{}<>_|~^\\`" + "".join(c for c in EXTRA if ord(c) > 127)
BOLD_EXTRAS = "$#@&*[]{}<>_|~^\\`+" + "".join(c for c in EXTRA if ord(c) > 127)

def build(light):
    cw, ch = (8, 13) if light else (10, 13)
    chars = LIGHT_EXTRAS if light else BOLD_EXTRAS
    gl = [["space", 2 if light else 3, ["." * cw] * ch]]
    for c in chars:
        w, rows = extra_rows(c, cw, ch)
        if not light:
            w, rows = embolden(rows, w, cw)
        gl.append([c, w, rows])
    write("Navigator-Extras-Light" if light else "Navigator-Extras-Bold", 1, gl, cw, ch)

build(True)
build(False)
print("ok")
