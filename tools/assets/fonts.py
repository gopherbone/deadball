"""Copy Playdate SDK fonts into playdate/source/fonts and build the DEADBALL headline font.

SDK fonts ship with the Playdate SDK and are licensed for use in Playdate games.
Run standalone: python3 tools/assets/fonts.py
"""
import os, re, glob, shutil
import numpy as np
from PIL import Image

import common
from common import SDK_FONTS, FONTS_OUT, ensure_dir, write_readme_part

# (sdk relative .fnt, output base name, use)
COPY = [
    ("Nontendo/Nontendo-Bold.fnt", "Nontendo-Bold", "UI chrome, menus, buttons (13px)"),
    ("Nontendo/Nontendo-Light.fnt", "Nontendo-Light", "body text (13px)"),
    ("Nontendo/Nontendo-Bold-2x.fnt", "Nontendo-Bold-2x", "big UI / scores (26px)"),
    ("Nontendo/Nontendo-Light-2x.fnt", "Nontendo-Light-2x", "big light (26px)"),
    ("Roobert/Roobert-9-Mono-Condensed.fnt", "Roobert-9-Mono-Condensed", "tables, odds, box scores (14px)"),
    ("Roobert/Roobert-10-Bold.fnt", "Roobert-10-Bold", "bold labels (14px; has kana/kanji)"),
    ("Roobert/Roobert-11-Medium.fnt", "Roobert-11-Medium", "large readable text (22px cell)"),
    ("Roobert/Roobert-11-Mono-Condensed.fnt", "Roobert-11-Mono-Condensed", "ticker / wire (16px)"),
    ("Newsleak Serif/Newsleak-Serif.fnt", "Newsleak-Serif", "newspaper body (20px cell)"),
    ("Newsleak Serif/Newsleak-Serif-Bold.fnt", "Newsleak-Serif-Bold", "newspaper headlines"),
    ("Sasser Slab/Sasser-Slab.fnt", "Sasser-Slab", "card backs, captions (18px cell)"),
    ("Sasser Slab/Sasser-Slab-Bold.fnt", "Sasser-Slab-Bold", "card nameplates, slab headlines"),
    ("Sasser Slab/Sasser-Small-Caps.fnt", "Sasser-Small-Caps", "card team captions"),
    ("Bitmore/font-Bitmore.fnt", "Bitmore", "tiny labels, icon captions (11px)"),
    ("Bitmore/font-Bitmore-Medieval-Bold.fnt", "Bitmore-Medieval-Bold", "olde-timey tiny captions"),
    ("Oklahoma/Oklahoma-Bold.fnt", "Oklahoma-Bold", "western/rustic headlines (Rustlers)"),
    ("Cuberick/font-Cuberick-Bold.fnt", "Cuberick-Bold", "chunky arcade headlines"),
]


def _table_for(fnt):
    base = fnt[:-4]
    t = glob.glob(glob.escape(base) + "-table-*-*.png")
    return t[0] if t else None


def copy_fonts():
    out = []
    for rel, name, use in COPY:
        src = os.path.join(SDK_FONTS, rel)
        if not os.path.exists(src):
            print("  missing SDK font", rel)
            continue
        table = _table_for(src)
        dims = re.search(r"-table-(\d+-\d+)\.png$", table).group(1)
        for old in glob.glob(os.path.join(FONTS_OUT, glob.escape(name) + "-table-*.png")):
            os.remove(old)
        shutil.copyfile(src, os.path.join(FONTS_OUT, name + ".fnt"))
        shutil.copyfile(table, os.path.join(FONTS_OUT, f"{name}-table-{dims}.png"))
        out.append((name, dims, use, rel))
    return out


# ------------------------------------------------------------- headline display font

# ------------------------------------------------------------- DEADBALL WordArt font
# Our own glyphs (drawn here from scratch, NOT derived from SDK fonts — the SDK license
# forbids derivative works). 5x7 chunky caps, rendered at 2x/3x with a 1px outline and a
# 2px drop shadow for 90s-homepage headlines.

GLYPHS = {
    "A": [".###.", "##.##", "##.##", "#####", "##.##", "##.##", "##.##"],
    "B": ["####.", "##.##", "##.##", "####.", "##.##", "##.##", "####."],
    "C": [".###.", "##.##", "##...", "##...", "##...", "##.##", ".###."],
    "D": ["####.", "##.##", "##.##", "##.##", "##.##", "##.##", "####."],
    "E": ["#####", "##...", "##...", "####.", "##...", "##...", "#####"],
    "F": ["#####", "##...", "##...", "####.", "##...", "##...", "##..."],
    "G": [".###.", "##.##", "##...", "##.##", "##.##", "##.##", ".####"],
    "H": ["##.##", "##.##", "##.##", "#####", "##.##", "##.##", "##.##"],
    "I": ["####", ".##.", ".##.", ".##.", ".##.", ".##.", "####"],
    "J": ["..###", "...##", "...##", "...##", "##.##", "##.##", ".###."],
    "K": ["##.##", "##.##", "####.", "###..", "####.", "##.##", "##.##"],
    "L": ["##...", "##...", "##...", "##...", "##...", "##...", "#####"],
    "M": ["##...##", "###.###", "#######", "##.#.##", "##...##", "##...##", "##...##"],
    "N": ["##..##", "###.##", "######", "##.###", "##..##", "##..##", "##..##"],
    "O": [".###.", "##.##", "##.##", "##.##", "##.##", "##.##", ".###."],
    "P": ["####.", "##.##", "##.##", "####.", "##...", "##...", "##..."],
    "Q": [".###.", "##.##", "##.##", "##.##", "##.##", "##.#.", ".##.#"],
    "R": ["####.", "##.##", "##.##", "####.", "####.", "##.##", "##.##"],
    "S": [".####", "##...", "##...", ".###.", "...##", "...##", "####."],
    "T": ["######", "..##..", "..##..", "..##..", "..##..", "..##..", "..##.."],
    "U": ["##.##", "##.##", "##.##", "##.##", "##.##", "##.##", ".###."],
    "V": ["##.##", "##.##", "##.##", "##.##", "##.##", ".###.", "..#.."],
    "W": ["##...##", "##...##", "##...##", "##.#.##", "#######", "###.###", "##...##"],
    "X": ["##.##", "##.##", ".###.", "..#..", ".###.", "##.##", "##.##"],
    "Y": ["##..##", "##..##", "##..##", ".####.", "..##..", "..##..", "..##.."],
    "Z": ["#####", "...##", "..##.", ".##..", "##...", "##...", "#####"],
    "0": [".###.", "##.##", "##.##", "##.##", "##.##", "##.##", ".###."],
    "1": [".##", "###", ".##", ".##", ".##", ".##", ".##"],
    "2": [".###.", "##.##", "...##", "..##.", ".##..", "##...", "#####"],
    "3": ["####.", "...##", "...##", ".###.", "...##", "...##", "####."],
    "4": ["##.##", "##.##", "##.##", "#####", "...##", "...##", "...##"],
    "5": ["#####", "##...", "####.", "...##", "...##", "##.##", ".###."],
    "6": [".###.", "##...", "####.", "##.##", "##.##", "##.##", ".###."],
    "7": ["#####", "...##", "..##.", "..##.", ".##..", ".##..", ".##.."],
    "8": [".###.", "##.##", "##.##", ".###.", "##.##", "##.##", ".###."],
    "9": [".###.", "##.##", "##.##", ".####", "...##", "...##", ".###."],
    "!": ["##", "##", "##", "##", "##", "..", "##"],
    "?": [".###.", "##.##", "...##", "..##.", ".##..", ".....", ".##.."],
    ".": ["..", "..", "..", "..", "..", "..", "##"],
    ",": ["..", "..", "..", "..", "..", "##", ".#"],
    "'": ["##", "##", ".#", "..", "..", "..", ".."],
    "-": ["....", "....", "....", "####", "....", "....", "...."],
    ":": ["..", "##", "##", "..", "##", "##", ".."],
    "/": ["...##", "...##", "..##.", "..##.", ".##..", "##...", "##..."],
    "$": ["..#..", ".####", "##.#.", ".###.", ".#.##", "####.", "..#.."],
    "&": [".##..", "##.#.", ".##..", "###.#", "##.##", "##.#.", ".##.#"],
    "#": [".#.#.", "#####", ".#.#.", ".#.#.", "#####", ".#.#.", "....."],
    "*": ["..#..", "#.#.#", ".###.", "#####", ".###.", "#.#.#", "..#.."],
}


def build_wordart(name, scale):
    keys = list(GLYPHS.keys())
    order = ["space"] + keys + [k.lower() for k in keys if k.isalpha()]
    gw = max(len(r[0]) for r in GLYPHS.values())
    pad = 1
    cw, ch = gw * scale + 2 * pad + 2, 7 * scale + 2 * pad + 2
    ncols = 16
    rows = (len(order) + ncols - 1) // ncols
    out = np.zeros((rows * ch, ncols * cw, 4), np.uint8)
    widths = []
    for i, key in enumerate(order):
        if key == "space":
            widths.append(3 * scale); continue
        g = GLYPHS[key.upper()]
        gwid = len(g[0])
        m = np.zeros((ch, cw), bool)
        for y, row in enumerate(g):
            for x, c in enumerate(row):
                if c == "#":
                    m[pad + y * scale: pad + (y + 1) * scale, pad + x * scale: pad + (x + 1) * scale] = True
        dil = m.copy()
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                dil |= np.roll(np.roll(m, dy, 0), dx, 1)
        shadow = np.zeros_like(dil)
        for k in (1, 2):
            shadow |= np.roll(np.roll(dil, k, 0), k, 1)
        cell = np.zeros((ch, cw, 4), np.uint8)
        cell[(dil | shadow) & ~m] = (0, 0, 0, 255)
        cell[m] = (255, 255, 255, 255)
        if scale >= 3:  # chrome stripe across the lower third of each letter
            ys = np.arange(ch)[:, None]
            stripe = m & (ys == pad + int(4.5 * scale))
            cell[stripe] = (0, 0, 0, 255)
        ox, oy = (i % ncols) * cw, (i // ncols) * ch
        out[oy:oy + ch, ox:ox + cw] = cell
        widths.append(gwid * scale + 3)
    for old in glob.glob(os.path.join(FONTS_OUT, name + "-table-*.png")):
        os.remove(old)
    Image.fromarray(out, "RGBA").save(os.path.join(FONTS_OUT, f"{name}-table-{cw}-{ch}.png"), optimize=True)
    with open(os.path.join(FONTS_OUT, name + ".fnt"), "w", encoding="utf-8") as fh:
        fh.write("-- DEADBALL WordArt font (original glyphs, tools/assets/fonts.py)\n")
        fh.write("tracking=0\n\n")
        for k, wd in zip(order, widths):
            fh.write(f"{k}\t{wd}\n")
    return name, f"{cw}-{ch}"


def render_rgba_font(name, text, bg):
    """Preview helper: paste RGBA glyphs (white + black ink) onto bg."""
    fnt = os.path.join(FONTS_OUT, name + ".fnt")
    tpath = glob.glob(os.path.join(FONTS_OUT, glob.escape(name) + "-table-*.png"))[0]
    cw, ch = map(int, re.search(r"-table-(\d+)-(\d+)\.png$", tpath).groups())
    tab = Image.open(tpath).convert("RGBA")
    order, widths = [], {}
    for line in open(fnt):
        p = line.split()
        if len(p) == 2 and p[1].lstrip("-").isdigit():
            order.append(p[0]); widths[p[0]] = int(p[1])
    cols = tab.width // cw
    x = 2
    for c in text:
        k = "space" if c == " " else c
        if k in widths:
            i = order.index(k)
            g = tab.crop(((i % cols) * cw, (i // cols) * ch, (i % cols + 1) * cw, (i // cols + 1) * ch))
            bg.paste(g.convert("L"), (x, 2), g.split()[3])
            x += widths[k]
    return bg


def build():
    ensure_dir(FONTS_OUT)
    for old in glob.glob(os.path.join(FONTS_OUT, "Deadball-Headline*")):
        os.remove(old)
    copied = copy_fonts()
    made = [build_wordart("Deadball-WordArt", 2), build_wordart("Deadball-WordArt-Big", 3)]
    for name, *_ in copied:
        common.PDFont(os.path.join(FONTS_OUT, name + ".fnt"))
    lines = ["## Fonts (`fonts/`)", "",
             "Playdate SDK fonts (licensed for use in Playdate games) copied **unmodified** with flat names. Each is a",
             "dependent `.fnt` + `-table-W-H.png` pair; load with `playdate.graphics.font.new(\"fonts/<Name>\")`.", "",
             "| Lua path | cell | use | SDK source |", "|---|---|---|---|"]
    for name, dims, use, rel in copied:
        lines.append(f"| `fonts/{name}` | {dims} | {use} | `{rel}` |")
    for name, dims in made:
        lines.append(f"| `fonts/{name}` | {dims} | WordArt headline (our own glyphs): white caps, black outline, 2px drop shadow; opaque white interior, transparent outside. Caps, digits, `! ? . , ' - : / $ & # *`; lowercase maps to caps | original |")
    lines += ["",
              "Notes: the Nontendo fonts have **no `$` glyph** — draw money with a Roobert/Newsleak/Sasser/Bitmore font",
              "(or the WordArt font). `Sasser-Small-Caps` only has lowercase glyphs (drawn as small caps), so lowercase",
              "your string. The SDK license forbids derivative works, so SDK fonts are never edited by the pipeline."]
    write_readme_part("60-fonts.md", "\n".join(lines))
    prev = Image.new("L", (400, 22 * (len(copied) + 4)), 255)
    y = 2
    for name, *_ in copied:
        f = common.PDFont(os.path.join(FONTS_OUT, name + ".fnt"))
        f.draw(prev, (2, y), f"{name}: DEADBALL $1,240 Friars 4-3")
        y += min(f.height, 30) + 2
    for name, dims in made:
        bg = Image.new("L", (400, 30), 255)
        a = np.asarray(bg).copy(); a[::2, ::2] = 0
        bg = render_rgba_font(name, "SLO-MO! Friars WIN $50", Image.fromarray(a))
        prev.paste(bg, (0, y)); y += 32
    prev = prev.crop((0, 0, 400, y + 2))
    prev.resize((800, prev.height * 2), Image.NEAREST).save(os.path.join(common.PREVIEW, "fonts.png"))
    print(f"  fonts: {len(copied)} SDK fonts + {len(made)} WordArt")


if __name__ == "__main__":
    build()
