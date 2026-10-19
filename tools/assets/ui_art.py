"""UI bitmaps for the 90s-web shell: icons, cursors, throbber, counters, construction,
NEW! starburst, mastheads, splash, team logos, tiled backgrounds.

Run standalone: python3 tools/assets/ui_art.py
"""
import os, math
import numpy as np
from PIL import Image, ImageDraw

import common
from common import IMAGES, PREVIEW, ensure_dir, write_readme_part
from pixel import Canvas, B, W, save, table, pat_array
from fonts import GLYPHS

UI = os.path.join(IMAGES, "ui")
LOGOS = os.path.join(IMAGES, "logos")
BG = os.path.join(IMAGES, "bg")


def glyph_text(c, x, y, s, scale=1, color=B, gap=1):
    """Draw with our own 5x7 GLYPHS (fonts.py). Returns end x."""
    for ch in s.upper():
        if ch == " ":
            x += 3 * scale; continue
        g = GLYPHS.get(ch)
        if not g:
            continue
        for j, row in enumerate(g):
            for i, p in enumerate(row):
                if p == "#":
                    c.rect((x + i * scale, y + j * scale, x + (i + 1) * scale - 1, y + (j + 1) * scale - 1), fill=color)
        x += len(g[0]) * scale + gap * scale
    return x


def glyph_width(s, scale=1, gap=1):
    w = 0
    for ch in s.upper():
        w += 3 * scale if ch == " " else (len(GLYPHS.get(ch, ["."])[0]) + gap) * scale
    return w - gap * scale


# tiny 3x5 digits/letters for 16px logos & small labels (our own)
MINI = {
    "A": ["###", "#.#", "###", "#.#", "#.#"], "B": ["##.", "#.#", "##.", "#.#", "##."],
    "C": ["###", "#..", "#..", "#..", "###"], "D": ["##.", "#.#", "#.#", "#.#", "##."],
    "E": ["###", "#..", "##.", "#..", "###"], "F": ["###", "#..", "##.", "#..", "#.."],
    "G": ["###", "#..", "#.#", "#.#", "###"], "H": ["#.#", "#.#", "###", "#.#", "#.#"],
    "I": ["###", ".#.", ".#.", ".#.", "###"], "J": ["..#", "..#", "..#", "#.#", "###"],
    "K": ["#.#", "#.#", "##.", "#.#", "#.#"], "L": ["#..", "#..", "#..", "#..", "###"],
    "M": ["#.#", "###", "###", "#.#", "#.#"], "N": ["##.", "#.#", "#.#", "#.#", "#.#"],
    "O": ["###", "#.#", "#.#", "#.#", "###"], "P": ["###", "#.#", "###", "#..", "#.."],
    "Q": ["###", "#.#", "#.#", "###", "..#"], "R": ["##.", "#.#", "##.", "#.#", "#.#"],
    "S": ["###", "#..", "###", "..#", "###"], "T": ["###", ".#.", ".#.", ".#.", ".#."],
    "U": ["#.#", "#.#", "#.#", "#.#", "###"], "V": ["#.#", "#.#", "#.#", "#.#", ".#."],
    "W": ["#.#", "#.#", "###", "###", "#.#"], "X": ["#.#", "#.#", ".#.", "#.#", "#.#"],
    "Y": ["#.#", "#.#", ".#.", ".#.", ".#."], "Z": ["###", "..#", ".#.", "#..", "###"],
}


def mini_text(c, x, y, s, color=B):
    for ch in s:
        g = MINI.get(ch.upper())
        if g:
            for j, row in enumerate(g):
                for i, p in enumerate(row):
                    if p == "#":
                        c.px(x + i, y + j, color)
        x += 4
    return x


def dollar(c, x, y, color=B):
    c.sprite(["..#..", ".####", "#.#..", ".###.", "..#.#", "####.", "..#.."] if color == B else
             ["  o  ", " oooo", "o o  ", " ooo ", "  o o", "oooo ", "  o  "], x, y)


# =============================================================== ICONS 32x32

def ic_navigator():
    c = Canvas(32, 32, opaque=False)
    c.ellipse((0, 12, 31, 23), outline=B, width=2)  # orbit ring (back)
    gem = [(4, 11), (10, 4), (21, 4), (27, 11), (15.5, 29)]
    c.poly(gem, fill=W, outline=B)
    c.line((4, 11, 27, 11))
    c.line((10, 4, 12, 11)); c.line((21, 4, 19, 11)); c.line((15, 4, 15, 4))
    c.line((12, 11, 15, 28)); c.line((19, 11, 16, 28))
    c.pattern((0, 0, 31, 31), "g50", region=c.region_poly([(5, 12), (11, 12), (15, 27)]))
    c.pattern((0, 0, 31, 31), "g75", region=c.region_poly([(20, 12), (26, 12), (16, 27)]))
    c.pattern((0, 0, 31, 31), "g25", region=c.region_poly([(11, 5), (20, 5), (18, 10), (13, 10)]))
    c.poly(gem, outline=B)
    # front of the ring
    for x in range(3, 29):
        y = int(round(17.5 + 5.0 * math.sqrt(max(0, 1 - ((x - 15.5) / 15.5) ** 2))))
        c.px(x, y - 1, W); c.px(x, y, B); c.px(x, y + 1, B)
    # sparkle
    c.sprite(["..#..", "..#..", "##.##", "..#..", "..#.."], 23, 0)
    return c


def ic_sportswire():
    c = Canvas(32, 32, opaque=False)
    # folded newspaper, slight fold shadow
    c.rect((3, 4, 29, 29), fill=W, outline=B)
    c.line((4, 30, 30, 30)); c.line((30, 5, 30, 30))
    c.rect((5, 6, 27, 11), fill=B)
    mini_text(c, 7, 6, "SW", W)
    c.line((15, 8, 25, 8), W)
    c.line((5, 13, 27, 13))
    # photo block + columns
    c.rect((5, 15, 14, 23), fill=B)
    c.pattern((6, 16, 13, 22), "g50")
    for y in range(15, 28, 2):
        c.line((17, y, 27, y))
    for y in range(25, 28, 2):
        c.line((5, y, 14, y))
    return c


def ic_bobby():
    c = Canvas(32, 32, opaque=False)
    # betting slip with notches + die
    c.rect((2, 6, 25, 27), fill=W, outline=B)
    for y in range(8, 26, 2):
        c.px(20, y)
    c.rect((4, 8, 17, 11), fill=B)
    dollar(c, 7, 14)
    for y in (14, 17, 20, 23):
        c.line((13, y, 18, y))
    c.line((22, 9, 23, 9)); c.line((22, 24, 23, 24))
    # die tumbling over the corner
    c.rect((19, 17, 30, 28), fill=W, outline=B)
    c.rect((20, 29, 31, 29), fill=B); c.rect((31, 18, 31, 29), fill=B)
    for (x, y) in ((21, 19), (24, 22), (27, 25)):
        c.rect((x, y, x + 1, y + 1), fill=B)
    return c


def ic_bbs():
    c = Canvas(32, 32, opaque=False)
    # CRT terminal
    c.rect((3, 3, 28, 22), fill=W, outline=B)
    c.rect((5, 5, 26, 19), fill=B)
    mini_text(c, 7, 7, "BBS", W)
    c.line((7, 15, 9, 15), W); c.line((11, 15, 13, 15), W)  # >_
    c.px(7, 13, W); c.px(8, 14, W)
    c.rect((12, 23, 19, 25), fill=W, outline=B)
    # keyboard
    c.poly([(2, 26), (29, 26), (31, 30), (0, 30)], fill=W, outline=B)
    for x in range(4, 28, 3):
        c.px(x, 28)
    # modem lights
    c.px(24, 21); c.px(26, 21)
    return c


def ic_mail():
    c = Canvas(32, 32, opaque=False)
    c.rect((2, 8, 29, 26), fill=W, outline=B)
    c.line((3, 9, 15, 19)); c.line((28, 9, 16, 19))
    c.line((3, 25, 12, 17)); c.line((28, 25, 19, 17))
    # stamp
    c.rect((22, 10, 27, 15), fill=W, outline=B)
    c.pattern((23, 11, 26, 14), "g50")
    # wax seal
    c.ellipse((13, 16, 18, 21), fill=B)
    return c


def ic_binder():
    c = Canvas(32, 32, opaque=False)
    c.rect((4, 2, 29, 30), fill=W, outline=B)
    c.rect((4, 2, 7, 30), fill=B)
    for y in (6, 15, 24):
        c.ellipse((2, y, 9, y + 3), fill=W, outline=B)
    # 2x2 card pockets
    for (x, y) in ((10, 4), (20, 4), (10, 17), (20, 17)):
        c.rect((x, y, x + 7, y + 10), fill=W, outline=B)
        c.rect((x + 2, y + 2, x + 5, y + 6), fill=B)
        c.line((x + 2, y + 8, x + 5, y + 8))
    return c


def ic_market():
    c = Canvas(32, 32, opaque=False)
    # storefront with striped awning
    c.rect((4, 12, 27, 29), fill=W, outline=B)
    c.poly([(2, 5), (29, 5), (31, 12), (0, 12)], fill=W, outline=B)
    for i, x in enumerate(range(2, 30, 4)):
        c.poly([(x, 5), (x + 2, 5), (x + 2 + 1, 12), (x + 1, 12)], fill=B)
    for x in range(1, 31, 4):
        c.line((x, 13, x + 2, 13))  # scallops
    c.rect((7, 16, 15, 29), fill=W, outline=B)  # door
    c.px(13, 22)
    c.rect((18, 16, 25, 23), fill=W, outline=B)  # window w/ price tag
    dollar(c, 19, 16)
    c.line((2, 30, 29, 30))
    return c


def ic_standings():
    c = Canvas(32, 32, opaque=False)
    # pennant on pole + bars
    c.line((5, 2, 5, 30)); c.line((6, 2, 6, 30))
    c.poly([(7, 3), (28, 8), (7, 13)], fill=B)
    c.line((10, 6, 20, 8), W)
    for i, hgt in enumerate((14, 9, 11, 5)):
        x = 10 + i * 5
        c.rect((x, 30 - hgt, x + 3, 30), fill=W if i else B, outline=B)
    c.line((8, 30, 30, 30))
    return c


def ic_settings():
    c = Canvas(32, 32, opaque=False)
    cx, cy = 15.5, 15.5
    pts = []
    for i in range(32):
        a = 2 * math.pi * i / 32
        r = 14 if (i // 2) % 2 == 0 else 10.5
        pts.append((cx + r * math.cos(a + 0.1), cy + r * math.sin(a + 0.1)))
    c.poly(pts, fill=B)
    c.ellipse((9, 9, 22, 22), fill=W, outline=B)
    c.ellipse((12, 12, 19, 19), fill=B)
    c.ellipse((14, 14, 17, 17), fill=W)
    return c


def ic_basket():
    c = Canvas(32, 32, opaque=False)
    c.poly([(5, 8), (26, 8), (23, 30), (8, 30)], fill=W, outline=B)
    for xx in (10, 15, 20):
        c.line((xx + 1, 10, xx + (0 if xx == 15 else (-1 if xx < 15 else 2)) + 1, 28))
    for y in (14, 20, 26):
        c.line((7, y, 24, y))
    c.rect((3, 5, 28, 8), fill=W, outline=B)
    # crumpled paper peeking out
    c.poly([(10, 5), (13, 1), (17, 3), (20, 0), (22, 5)], fill=W, outline=B)
    return c


ICONS = [("navigator", ic_navigator), ("sportswire", ic_sportswire), ("bobby", ic_bobby), ("bbs", ic_bbs),
         ("mail", ic_mail), ("binder", ic_binder), ("market", ic_market), ("standings", ic_standings),
         ("settings", ic_settings), ("basket", ic_basket)]


def selected(c):
    """Classic-Mac selected icon: invert inside the mask."""
    s = c.copy()
    a = np.asarray(s.im).copy(); m = np.asarray(s.mask) > 0
    a[m] = 255 - a[m]
    s.im = Image.fromarray(a, "L"); s.d = ImageDraw.Draw(s.im)
    s.outline_mask(B)
    return s


# =============================================================== CURSORS

ARROW = [
    "#          ",
    "##         ",
    "#.#        ",
    "#..#       ",
    "#...#      ",
    "#....#     ",
    "#.....#    ",
    "#......#   ",
    "#.......#  ",
    "#........# ",
    "#.....#####",
    "#..#..#    ",
    "#.# #..#   ",
    "##  #..#   ",
    "#    #..#  ",
    "     #..#  ",
    "      ##   ",
]
HAND = [
    "    ##      ",
    "   #..#     ",
    "   #..#     ",
    "   #..#     ",
    "   #..###   ",
    "   #..#..## ",
    "## #..#..#.#",
    "#.##.......#",
    "#..#.......#",
    " #.........#",
    "  #........#",
    "  #.......# ",
    "   #......# ",
    "   #......# ",
    "    ######  ",
]
IBEAM = [
    "##.##",
    "  #  ",
    "  #  ",
    "  #  ",
    "  #  ",
    "  #  ",
    "  #  ",
    "  #  ",
    "  #  ",
    "  #  ",
    "##.##",
]


def cursor_canvas(rows, size=(16, 18)):
    c = Canvas(*size, opaque=False)
    c.sprite(rows, 0, 0)
    return c


def watch_frames(n=8):
    out = []
    for k in range(n):
        c = Canvas(16, 18, opaque=False)
        c.rect((5, 0, 10, 3), fill=B)  # strap
        c.rect((5, 14, 10, 17), fill=B)
        c.ellipse((1, 2, 14, 15), fill=W, outline=B)
        c.ellipse((2, 3, 13, 14), outline=B)
        c.px(15, 8); c.px(14, 8)  # crown
        for t in range(12):
            a = 2 * math.pi * t / 12
            if t % 3 == 0:
                c.px(round(7.5 + 4.6 * math.cos(a)), round(8.5 + 4.6 * math.sin(a)))
        # minute hand rotates, hour hand slower
        a = 2 * math.pi * k / n - math.pi / 2
        c.line((7.5, 8.5, 7.5 + 4 * math.cos(a), 8.5 + 4 * math.sin(a)))
        a2 = 2 * math.pi * k / (n * 4) - math.pi / 2 + 1.0
        c.line((7.5, 8.5, 7.5 + 2.5 * math.cos(a2), 8.5 + 2.5 * math.sin(a2)))
        out.append(c)
    return out


# =============================================================== THROBBER (spinning baseball 22x14)

def throbber_frames(n=8):
    """Spinning baseball: the real seam curve (tennis-ball curve) rotated about the
    vertical axis, orthographic projection, front half only."""
    out = []
    R = 6.0
    cx, cy = 14.5, 6.5
    a_, b_ = 0.72, 0.28
    t = np.linspace(0, 2 * np.pi, 160)
    sx = a_ * np.cos(t) + b_ * np.cos(3 * t)
    sy = a_ * np.sin(t) - b_ * np.sin(3 * t)
    sz = 2 * math.sqrt(a_ * b_) * np.sin(2 * t)
    # tilt the ball so seams read as the classic "smile" shapes
    tilt = 0.5
    sy, sz = sy * math.cos(tilt) - sz * math.sin(tilt), sy * math.sin(tilt) + sz * math.cos(tilt)
    for k in range(n):
        c = Canvas(22, 14, opaque=False)
        for i, (y, l) in enumerate(((3, 4), (6, 6), (9, 5), (11, 3))):
            ll = l - ((k + i) % 2)
            c.line((7 - ll, y, 6, y))
        c.ellipse((cx - R, cy - R, cx + R, cy + R), fill=W, outline=B)
        phi = 2 * math.pi * k / n / 2  # seam pattern has 2-fold symmetry: half turn per cycle
        X = sx * math.cos(phi) + sz * math.sin(phi)
        Z = -sx * math.sin(phi) + sz * math.cos(phi)
        for x, y, z in zip(X, sy, Z):
            if z > 0.1:
                px_, py_ = int(round(cx + x * (R - 1.2))), int(round(cy - y * (R - 1.2)))
                c.px(px_, py_)
        c.ellipse((cx - R, cy - R, cx + R, cy + R), outline=B)
        out.append(c)
    return out


# =============================================================== HIT COUNTER DIGITS

ODO = {
    "0": [".###.", "#...#", "#..##", "#.#.#", "##..#", "#...#", "#...#", ".###."],
    "1": ["..#..", ".##..", "..#..", "..#..", "..#..", "..#..", "..#..", ".###."],
    "2": [".###.", "#...#", "....#", "...#.", "..#..", ".#...", "#....", "#####"],
    "3": ["#####", "...#.", "..#..", "...#.", "....#", "....#", "#...#", ".###."],
    "4": ["...#.", "..##.", ".#.#.", "#..#.", "#####", "...#.", "...#.", "...#."],
    "5": ["#####", "#....", "####.", "....#", "....#", "....#", "#...#", ".###."],
    "6": ["..##.", ".#...", "#....", "####.", "#...#", "#...#", "#...#", ".###."],
    "7": ["#####", "....#", "...#.", "..#..", ".#...", ".#...", ".#...", ".#..."],
    "8": [".###.", "#...#", "#...#", ".###.", "#...#", "#...#", "#...#", ".###."],
    "9": [".###.", "#...#", "#...#", "#...#", ".####", "....#", "...#.", ".##.."],
}
CW, CH = 9, 14


def odo_cell(d, inverted=False):
    """Black drum cell with white digit (inverted=True: white cell, black digit)."""
    fg, bg = (W, B) if not inverted else (B, W)
    c = Canvas(CW, CH)
    c.rect((0, 0, CW - 1, CH - 1), fill=bg)
    if inverted:
        c.rect((0, 0, CW - 1, CH - 1), outline=B)
    # drum shading: top & bottom rows dotted (curvature)
    for x in range(1, CW - 1, 2):
        c.px(x, 1, fg if not inverted else B); c.px(x + 1, CH - 2, fg if not inverted else B)
    rows = ODO[d]
    for j, row in enumerate(rows):
        for i, p in enumerate(row):
            if p == "#":
                c.px(2 + i, 3 + j, fg)
    c.vline(CW - 1, 0, CH - 1, B if not inverted else B)
    return c


def odo_roll(d0, d1, frac, inverted=False):
    """Intermediate rolling frame between digit d0 and d1 (frac 0..1 = scrolled up)."""
    a = odo_cell(d0, inverted).im; b = odo_cell(d1, inverted).im
    strip = Image.new("L", (CW, CH * 2)); strip.paste(a, (0, 0)); strip.paste(b, (0, CH))
    off = int(round(frac * CH))
    c = Canvas(CW, CH); c.im = strip.crop((0, off, CW, off + CH)); c.d = ImageDraw.Draw(c.im)
    return c


# =============================================================== UNDER CONSTRUCTION

def stripe_frames(w=32, h=10, n=8):
    out = []
    for k in range(n):
        c = Canvas(w, h)
        for y in range(h):
            for x in range(w):
                on = ((x + y + k) // 4) % 2 == 0
                c.im.putpixel((x, y), B if on else W)
        c.hline(0, w - 1, 0); c.hline(0, w - 1, h - 1)
        out.append(c)
    return out


DIGGER = [
    [
        "      ###       ",
        "     #####      ",
        "    #######     ",
        "     #...#      ",
        "     #...#    # ",
        "      ###    #  ",
        "    #######.#   ",
        "   #.#####.#    ",
        "   #.#####.     ",
        "   #.#####      ",
        "    .#####      ",
        "     #.##       ",
        "    #.. #.      ",
        "   #..   #.     ",
        "  ##.     ##    ",
    ],
    [
        "                ",
        "      ###       ",
        "     #####      ",
        "    #######     ",
        "     #...#      ",
        "      ###       ",
        "    ######      ",
        "   #.#####.     ",
        "   #.#####.#    ",
        "   #.#####..#   ",
        "    .#####   #  ",
        "     #.##     # ",
        "    #.. #.      ",
        "   #..   #.     ",
        "  ##.     ##    ",
    ],
]


def construction_sign_frames():
    out = []
    for k in range(2):
        c = Canvas(32, 32, opaque=False)
        # diamond road sign
        c.poly([(16, 0), (31, 15), (16, 30), (1, 15)], fill=W, outline=B)
        c.poly([(16, 2), (29, 15), (16, 28), (3, 15)], outline=B)
        # digger + dirt pile
        c.sprite(DIGGER[k], 7, 6)
        c.poly([(18, 23), (21, 19), (25, 23)], fill=B)
        if k == 1:
            c.px(24, 17); c.px(26, 18)
        out.append(c)
    return out


# =============================================================== NEW! starburst

def burst_canvas(w, h, inverted=False, spin=0.0, label="NEW!"):
    c = Canvas(w, h, opaque=False)
    cx, cy = w / 2 - 0.5, h / 2 - 0.5
    pts = []
    n = 12
    for i in range(n * 2):
        a = math.pi * i / n + spin
        r = 1.0 if i % 2 == 0 else 0.66
        pts.append((cx + r * (w / 2 - 0.5) * math.cos(a), cy + r * (h / 2 - 0.5) * math.sin(a)))
    c.poly(pts, fill=B if not inverted else W, outline=B)
    tw_ = glyph_width(label)
    glyph_text(c, int(cx - tw_ / 2 + 1), int(cy - 3), label, 1, W if not inverted else B)
    return c


# =============================================================== MASTHEADS / LOGOS

def wordart(c, x, y, s, scale=2, fill=W, shadow=2):
    """Outlined + shadowed text from our own glyphs onto canvas c."""
    tmp = Canvas(c.w, c.h, opaque=False)
    glyph_text(tmp, x, y, s, scale, B, gap=1)
    m = np.asarray(tmp.mask) > 0
    dil = m.copy()
    for dy in (-1, 0, 1):
        for dx in (-1, 0, 1):
            dil |= np.roll(np.roll(m, dy, 0), dx, 1)
    sh = np.zeros_like(dil)
    for k in range(1, shadow + 1):
        sh |= np.roll(np.roll(dil, k, 0), k, 1)
    a = np.asarray(c.im).copy(); mm = np.asarray(c.mask).copy()
    a[(dil | sh)] = B; a[m] = fill
    mm[dil | sh] = 255
    c.im = Image.fromarray(a, "L"); c.mask = Image.fromarray(mm, "L")
    c.d = ImageDraw.Draw(c.im); c.dm = ImageDraw.Draw(c.mask)
    return x + glyph_width(s, scale)


def masthead_sportswire():
    c = Canvas(240, 30)
    f = common.font("serifb")
    c.rect((0, 0, 239, 29), fill=W)
    c.text((2, 3), "SportsWire", "serifb")
    x = 4 + f.width("SportsWire")
    c.rect((x + 2, 7, x + 49, 18), fill=B)
    c.text((x + 6, 6), "ONLINE", "ui", W)
    c.text((x + 55, 7), "est. 1996", "tiny")
    c.hline(0, 239, 25); c.pattern((0, 27, 239, 28), "g50")
    # little lightning wire mark
    c.poly([(226, 2), (220, 13), (225, 13), (221, 23), (232, 9), (226, 9), (231, 2)], fill=B)
    return c


def masthead_bobby():
    c = Canvas(220, 34)
    c.pattern((0, 0, 219, 33), "dots")
    end = wordart(c, 30, 7, "BETS BY BOBBY", 2)
    # dice either side
    for x0, pips in ((4, ((8, 12), (12, 16), (16, 20))), (200, ((206, 12), (210, 20)))):
        c.rect((x0, 8, x0 + 15, 23), fill=W, outline=B)
        c.rect((x0 + 1, 24, x0 + 16, 24), fill=B); c.rect((x0 + 16, 9, x0 + 16, 24), fill=B)
        for px_, py_ in pips:
            c.rect((px_ - 1 + (0), py_ - 1, px_ + 0, py_), fill=B)
    return c


def crest(c, x, y, scale=1):
    """Continental League crest: shield with crossed bats + ball, star above (32x32 at scale 1)."""
    s = scale
    pts = [(x + 2 * s, y + 4 * s), (x + 29 * s, y + 4 * s), (x + 29 * s, y + 16 * s), (x + 15.5 * s, y + 30 * s), (x + 2 * s, y + 16 * s)]
    c.poly(pts, fill=W, outline=B)
    inner = [(x + 4 * s, y + 6 * s), (x + 27 * s, y + 6 * s), (x + 27 * s, y + 15.5 * s), (x + 15.5 * s, y + 27.5 * s), (x + 4 * s, y + 15.5 * s)]
    c.poly(inner, fill=B)
    c.line((x + 7 * s, y + 9 * s, x + 24 * s, y + 24 * s), W, 2 * s)
    c.line((x + 24 * s, y + 9 * s, x + 7 * s, y + 24 * s), W, 2 * s)
    c.ellipse((x + 11 * s, y + 10 * s, x + 20 * s, y + 19 * s), fill=W, outline=B)
    c.line((x + 13 * s, y + 11 * s, x + 13 * s, y + 18 * s)); c.line((x + 18 * s, y + 11 * s, x + 18 * s, y + 18 * s))
    c.poly([(x + 15.5 * s, y + 0), (x + 17 * s, y + 3 * s), (x + 14 * s, y + 3 * s)], fill=B)


def masthead_continental():
    c = Canvas(240, 40)
    crest(c, 4, 4)
    crest(c, 204, 4)
    c.ctext(120, 3, "THE", "tiny")
    glyph_text(c, 120 - glyph_width("CONTINENTAL", 2) // 2, 13, "CONTINENTAL", 2)
    c.hline(42, 197, 30); c.hline(42, 197, 32)
    c.ctext(120, 28, " LEAGUE OF BASE BALL CLUBS ", "tiny")
    w = common.font("tiny").width(" LEAGUE OF BASE BALL CLUBS ")
    c.rect((120 - w // 2, 29, 120 + w // 2, 37), fill=W)
    c.ctext(120, 28, "LEAGUE OF BASE BALL CLUBS", "tiny")
    return c


def diamond_logo(c, cx, cy, r):
    """Faceted gem/diamond with a baseball diamond (bases) inside."""
    top = [(cx - r, cy - r * 0.35), (cx - r * 0.55, cy - r * 0.8), (cx + r * 0.55, cy - r * 0.8), (cx + r, cy - r * 0.35)]
    gem = top + [(cx, cy + r)]
    c.poly(gem, fill=W, outline=B)
    c.line((cx - r, cy - r * 0.35, cx + r, cy - r * 0.35))
    for fx in (-0.55, 0.55):
        c.line((cx + fx * r, cy - r * 0.8, cx + fx * r * 0.5, cy - r * 0.35))
    c.line((cx, cy - r * 0.8, cx - r * 0.25, cy - r * 0.35)); c.line((cx, cy - r * 0.8, cx + r * 0.25, cy - r * 0.35))
    for fx in (-1, -0.5, 0, 0.5, 1):
        c.line((cx + fx * r * (0.6 if abs(fx) < 1 else 1), cy - r * 0.35, cx, cy + r))
    # shade alternate facets
    reg = c.region_poly([(cx - r, cy - r * 0.35), (cx - r * 0.6, cy - r * 0.35), (cx, cy + r)])
    c.pattern((int(cx - r), int(cy - r), int(cx + r), int(cy + r)), "g50", region=reg)
    reg = c.region_poly([(cx + r * 0.3, cy - r * 0.35), (cx + r * 0.6, cy - r * 0.35), (cx, cy + r)])
    c.pattern((int(cx - r), int(cy - r), int(cx + r), int(cy + r)), "g25", region=reg)
    reg = c.region_poly([(cx + r * 0.55, cy - r * 0.8), (cx + r, cy - r * 0.35), (cx + r * 0.25, cy - r * 0.35)])
    c.pattern((int(cx - r), int(cy - r), int(cx + r), int(cy + r)), "g75", region=reg)
    # outline again
    c.poly(gem, outline=B)


def splash():
    c = Canvas(400, 240, fill=B)
    rng = np.random.default_rng(7)
    for _ in range(140):
        x, y = int(rng.integers(0, 400)), int(rng.integers(0, 240))
        c.px(x, y, W)
        if rng.random() < 0.12:
            c.px(x + 1, y, W); c.px(x - 1, y, W); c.px(x, y + 1, W); c.px(x, y - 1, W)
    # card panel
    c.rect((40, 34, 359, 205), fill=W, outline=B)
    c.rect((42, 36, 357, 203), outline=B)
    c.rect((360, 35, 361, 206), fill=B)
    c.rect((41, 206, 361, 207), fill=B)
    diamond_logo(c, 100, 92, 40)
    wordart(c, 152, 58, "DIAMOND", 3)
    wordart(c, 152, 88, "NAVIGATOR", 2)
    c.text((152, 110), "Version 3.0 Gold", "ui")
    c.text((152, 124), "for pocket computers", "tiny")
    c.hline(52, 347, 150)
    c.text((52, 154), "Copyright (c) 1996-1998 Diamond Communications Corp.", "tiny")
    c.text((52, 164), "All rights reserved. Not a real company.", "tiny")
    # progress bar frame (client fills)
    c.rect((52, 182, 291, 193), outline=B)
    c.text((300, 182), "Loading...", "tiny")
    # wave of baseballs in the corner
    return c


SPLASH_PROGRESS = (54, 184, 236, 8)  # x, y, w, h of the empty progress bar interior


# =============================================================== TEAM LOGOS

CLUBS = [("HCL", "Lamplighters"), ("STA", "Friars"), ("PEM", "Mariners"), ("MIL", "Ironmen"),
         ("CSR", "Rustlers"), ("NCG", "Grays"), ("MRL", "Pilgrims"), ("ELC", "Comets")]


def roundel(c, ring=True):
    c.ellipse((0, 0, 31, 31), fill=W, outline=B)
    if ring:
        c.ellipse((2, 2, 29, 29), outline=B)


def logo_hcl():  # lamplighters: street lantern
    c = Canvas(32, 32, opaque=False); roundel(c)
    c.rect((15, 18, 16, 28), fill=B)
    c.rect((12, 27, 19, 28), fill=B)
    c.poly([(11, 8), (20, 8), (19, 17), (12, 17)], fill=W, outline=B)
    c.poly([(10, 8), (15, 3), (16, 3), (21, 8)], fill=B)
    c.rect((12, 17, 19, 18), fill=B)
    c.line((14, 10, 14, 15)); c.px(17, 10); c.px(17, 11)  # flame / glass glint
    c.poly([(15, 9), (17, 12), (15, 15), (14, 12)], fill=B)
    for (x0, y0, x1, y1) in ((7, 10, 9, 10), (22, 10, 24, 10), (8, 6, 9, 7), (22, 7, 23, 6)):
        c.line((x0, y0, x1, y1))
    return c


def logo_sta():  # friars: monk hood + cross
    c = Canvas(32, 32, opaque=False); roundel(c)
    c.poly([(16, 5), (24, 13), (25, 27), (7, 27), (8, 13)], fill=B)
    c.ellipse((11, 11, 21, 23), fill=W)
    c.ellipse((12, 13, 20, 23), fill=B)
    c.rect((15, 18, 16, 26), fill=W); c.rect((13, 20, 18, 21), fill=W)
    return c


def logo_pem():  # mariners: anchor
    c = Canvas(32, 32, opaque=False); roundel(c)
    c.ellipse((13, 4, 18, 9), outline=B, width=2)
    c.rect((15, 9, 16, 25), fill=B)
    c.rect((10, 11, 21, 12), fill=B)
    c.arc_pts = None
    for t in np.linspace(0.15, math.pi - 0.15, 24):
        x = 15.5 - 9 * math.cos(t); y = 17 + 8 * math.sin(t)
        c.rect((round(x) - 0, round(y) - 0, round(x) + 1, round(y) + 1), fill=B)
    c.poly([(5, 20), (9, 17), (9, 22)], fill=B); c.poly([(26, 20), (22, 17), (22, 22)], fill=B)
    return c


def logo_mil():  # ironmen: anvil + hammer
    c = Canvas(32, 32, opaque=False); roundel(c)
    c.poly([(5, 15), (26, 15), (24, 18), (20, 18), (19, 21), (22, 25), (9, 25), (12, 21), (11, 18), (8, 18)], fill=B)
    c.line((10, 5, 20, 13), B, 2)
    c.poly([(17, 6), (22, 3), (25, 8), (20, 11)], fill=B)
    c.px(14, 12, W)
    for (x, y) in ((8, 11), (6, 9), (24, 12)):
        c.px(x, y)
    return c


def logo_csr():  # rustlers: steer skull horns
    c = Canvas(32, 32, opaque=False); roundel(c)
    c.poly([(3, 10), (8, 13), (12, 12), (12, 15), (7, 15)], fill=B)
    c.poly([(28, 10), (23, 13), (19, 12), (19, 15), (24, 15)], fill=B)
    c.poly([(11, 11), (20, 11), (19, 22), (17, 27), (14, 27), (12, 22)], fill=B)
    c.rect((13, 15, 14, 16), fill=W); c.rect((17, 15, 18, 16), fill=W)
    c.px(14, 24, W); c.px(17, 24, W)
    return c


def logo_ncg():  # grays: gothic interlocked NC monogram
    c = Canvas(32, 32, opaque=False); roundel(c)
    c.pattern((3, 3, 28, 28), "g25", region=c.region_ellipse((3, 3, 28, 28)))
    c.ellipse((5, 5, 26, 26), fill=W, outline=B)
    glyph_text(c, 9, 6, "G", 3 if False else 2)
    c.rect((9, 6, 22, 25), fill=W)
    glyph_text(c, 11, 9, "G", 2)
    mini_text(c, 10, 20, "NC")
    c.hline(18, 21, 22)
    return c


def logo_mrl():  # pilgrims: buckle hat
    c = Canvas(32, 32, opaque=False); roundel(c)
    c.poly([(10, 6), (21, 6), (23, 21), (8, 21)], fill=B)
    c.rect((4, 21, 27, 24), fill=B)
    c.rect((9, 15, 22, 17), fill=W)
    c.rect((13, 14, 18, 18), fill=W); c.rect((14, 15, 17, 17), fill=B)
    return c


def logo_elc():  # comets: comet with tail + bolt
    c = Canvas(32, 32, opaque=False); roundel(c)
    tail = [(16, 9), (23, 16), (9, 27), (5, 23)]
    c.poly(tail, fill=W, outline=B)
    c.pattern((0, 0, 31, 31), "g50", region=c.region_poly(tail))
    c.line((18, 13, 8, 24), B, 2)
    c.ellipse((16, 6, 26, 16), fill=B)
    c.ellipse((18, 8, 21, 11), fill=W)
    c.sprite(["..#..", ".###.", "#####", ".###.", "..#.."], 6, 6)
    return c


LOGO32 = {"HCL": logo_hcl, "STA": logo_sta, "PEM": logo_pem, "MIL": logo_mil, "CSR": logo_csr,
          "NCG": logo_ncg, "MRL": logo_mrl, "ELC": logo_elc}

# 16x16: pennant shape per club with 2-letter mini monogram
SMALL_ID = {"HCL": "HC", "STA": "SA", "PEM": "PE", "MIL": "MI", "CSR": "CS", "NCG": "NC", "MRL": "MR", "ELC": "EC"}
SMALL_STYLE = {"HCL": "pennant", "STA": "shield", "PEM": "circle", "MIL": "square", "CSR": "pennant",
               "NCG": "shield", "MRL": "square", "ELC": "circle"}


def small_logo(letters, style, dark=True):
    c = Canvas(16, 16, opaque=False)
    fg = W if dark else B
    if style == "pennant":
        c.poly([(1, 2), (15, 8), (1, 14)], fill=B if dark else W, outline=B)
        c.rect((0, 1, 1, 15), fill=B)
        mini_text(c, 3, 6, letters[:2], fg)
    elif style == "shield":
        c.poly([(1, 1), (14, 1), (14, 9), (7.5, 15), (1, 9)], fill=B if dark else W, outline=B)
        mini_text(c, 3, 3, letters[:2], fg)
    elif style == "circle":
        c.ellipse((0, 0, 15, 15), fill=B if dark else W, outline=B)
        mini_text(c, 4, 5, letters[:2], fg)
    else:
        c.rect((1, 1, 14, 14), fill=B if dark else W, outline=B)
        c.rect((2, 2, 13, 13), outline=W if dark else B)
        mini_text(c, 4, 5, letters[:2], fg)
    return c


def farm_logo32(letter, k):
    """Generic farm pennant (felt pennant on a stick), letter in our 5x7 glyphs at 2x."""
    c = Canvas(32, 32, opaque=False)
    dark = k % 2 == 0
    c.rect((0, 2, 1, 31), fill=B)  # stick
    pts = [(2, 4), (31, 16), (2, 28)]
    c.poly(pts, fill=B if dark else W)
    c.line((2, 4, 31, 16)); c.line((2, 28, 31, 16)); c.line((2, 4, 2, 28))
    # sewn strip near the stick
    c.rect((2, 5, 4, 27), fill=W if dark else B)
    if not dark:
        c.rect((3, 5, 3, 27), fill=W)
    gw = glyph_width(letter, 2)
    glyph_text(c, 7 + max(0, (12 - gw) // 2), 9, letter, 2, W if dark else B)
    return c


# =============================================================== TILED BACKGROUNDS

def tile_stars():
    c = Canvas(32, 32, fill=B)
    big = [" o ", "ooo", " o "]
    c.sprite(big, 4, 4)
    c.sprite(big, 20, 19)
    for (x, y) in ((14, 9), (27, 4), (9, 22), (24, 12), (2, 15), (17, 28), (30, 25), (12, 1)):
        c.px(x, y, W)
    # a sparkle
    c.sprite(["  o  ", "  o  ", "oo.oo", "  o  ", "  o  "], 24, 26 - 26 + 0)
    return c


def tile_bricks():
    c = Canvas(32, 32, fill=W)
    c.pattern((0, 0, 31, 31), "g25")
    for row in range(4):
        y = row * 8
        c.hline(0, 31, y + 7)
        c.hline(0, 31, y)
        off = 0 if row % 2 == 0 else 8
        for x in range(off, 32 + off, 16):
            c.vline(x % 32, y, y + 7)
    # mortar white speckle
    for (x, y) in ((5, 3), (21, 12), (13, 27), (27, 19)):
        c.px(x, y, B)
    return c


def tile_baseballs():
    c = Canvas(32, 32, fill=W)
    c.pattern((0, 0, 31, 31), "dots")
    for (cx, cy) in ((8, 8), (24, 24)):
        c.ellipse((cx - 5, cy - 5, cx + 5, cy + 5), fill=W, outline=B)
        for sgn in (-1, 1):
            for y in range(-3, 4):
                x = cx + sgn * (3 - (1 if abs(y) < 2 else 0))
                c.px(x, cy + y)
                if y % 2 == 0:
                    c.px(x + sgn, cy + y)
    return c


def tile_marble():
    """Seamless 64x64 marble: periodic sine veins + ordered dither."""
    n = 64
    yy, xx = np.mgrid[0:n, 0:n] / n * 2 * math.pi
    turb = 0.6 * np.sin(2 * xx + np.sin(3 * yy)) + 0.4 * np.sin(3 * yy + 2 * np.cos(xx)) + 0.25 * np.sin(5 * xx + 4 * yy)
    v = np.sin(xx * 2 + yy * 1 + 2.2 * turb)
    av = np.abs(v)
    a = np.ones_like(av)
    a[av < 0.22] = 0.8
    a[av < 0.12] = 0.5
    a[av < 0.045] = 0.0
    # second, fainter vein family
    v2 = np.sin(yy * 3 - xx + 1.5 * turb)
    a[np.abs(v2) < 0.05] = np.minimum(a[np.abs(v2) < 0.05], 0.6)
    out = common.bayer(a, common.BAYER4)
    c = Canvas(n, n); c.im = Image.fromarray(out, "L"); c.d = ImageDraw.Draw(c.im)
    return c


def tile_money():
    c = Canvas(32, 32, fill=W)
    dollar(c, 4, 4); dollar(c, 20, 20)
    for (x, y) in ((22, 6), (6, 22)):
        c.ellipse((x - 3, y - 3, x + 3, y + 3), outline=B)
        c.px(x, y)
    return c


TILES = [("stars", tile_stars), ("bricks", tile_bricks), ("baseballs", tile_baseballs), ("marble", tile_marble),
         ("money", tile_money)]


# =============================================================== BUILD

def build():
    for d in (UI, LOGOS, BG):
        ensure_dir(d)
        for root, _, files in os.walk(d):
            for f in files:
                if f.endswith(".png"):
                    os.remove(os.path.join(root, f))
    prev = {}
    # icons
    icons = []
    for name, fn in ICONS:
        c = fn(); icons.append(c)
        save(c, os.path.join(UI, "icons", f"{name}.png"))
        save(selected(c), os.path.join(UI, "icons", f"{name}-sel.png"))
    table(icons, os.path.join(UI, "icons"), "icons")
    table([selected(c) for c in icons], os.path.join(UI, "icons"), "icons-sel")
    prev["icons"] = icons + [selected(c) for c in icons]
    # cursors
    arrow = cursor_canvas(ARROW); hand = cursor_canvas(HAND); ibeam = cursor_canvas(IBEAM, (8, 12))
    save(arrow, os.path.join(UI, "cursor-arrow.png")); save(hand, os.path.join(UI, "cursor-hand.png"))
    save(ibeam, os.path.join(UI, "cursor-ibeam.png"))
    watch = watch_frames()
    table(watch, UI, "cursor-busy")
    prev["cursors"] = [arrow, hand, ibeam] + watch
    # throbber
    thr = throbber_frames()
    table(thr, UI, "throbber")
    prev["throbber"] = thr
    # counter digits (0..9) + roll frames
    for inv, nm in ((False, "counter-digits"), (True, "counter-digits-inv")):
        cells = [odo_cell(str(d), inv) for d in range(10)]
        table(cells, UI, nm, masked=False)
        prev[nm] = cells
    rolls = []
    for d in range(10):
        for frac in (0.25, 0.5, 0.75):
            rolls.append(odo_roll(str(d), str((d + 1) % 10), frac))
    table(rolls, UI, "counter-roll", cols=3, masked=False)
    prev["counter-roll"] = rolls[:6]
    # construction
    st = stripe_frames()
    table(st, UI, "construction-stripe", masked=False)
    sign = construction_sign_frames()
    table(sign, UI, "construction-sign")
    prev["construction"] = st + sign
    # NEW!
    bursts = [burst_canvas(30, 20), burst_canvas(30, 20, inverted=True), burst_canvas(30, 20, spin=math.pi / 12)]
    table(bursts, UI, "new-burst")
    hot = [burst_canvas(30, 20, label="HOT!"), burst_canvas(30, 20, inverted=True, label="HOT!")]
    table(hot, UI, "hot-burst")
    prev["bursts"] = bursts + hot
    # mastheads
    ms = {"masthead-sportswire": masthead_sportswire(), "masthead-bobby": masthead_bobby(),
          "masthead-continental": masthead_continental()}
    for k, c in ms.items():
        save(c, os.path.join(UI, f"{k}.png"), masked=False)
    cr = Canvas(32, 32, opaque=False); crest(cr, 0, 0)
    save(cr, os.path.join(UI, "crest-continental.png"))
    sp = splash()
    save(sp, os.path.join(UI, "splash-navigator.png"), masked=False)
    dl = Canvas(48, 48, opaque=False); diamond_logo(dl, 24, 22, 22)
    save(dl, os.path.join(UI, "navigator-logo-48.png"))
    prev["mastheads"] = list(ms.values()) + [cr, dl]
    prev["splash"] = sp
    # logos
    l32, l16 = [], []
    for abbr, _ in CLUBS:
        c = LOGO32[abbr](); l32.append(c)
        save(c, os.path.join(LOGOS, f"{abbr}-32.png"))
        s = small_logo(SMALL_ID[abbr], SMALL_STYLE[abbr]); l16.append(s)
        save(s, os.path.join(LOGOS, f"{abbr}-16.png"))
    table(l32, LOGOS, "clubs-32"); table(l16, LOGOS, "clubs-16")
    letters = [chr(ord("A") + i) for i in range(26)]
    f32 = [farm_logo32(L, i) for i, L in enumerate(letters)]
    f16 = [small_logo(L, ["pennant", "shield", "circle", "square"][i % 4], dark=(i % 2 == 0)) for i, L in enumerate(letters)]
    table(f32, LOGOS, "farm-32", cols=13); table(f16, LOGOS, "farm-16", cols=13)
    prev["logos"] = l32 + l16
    prev["farm"] = f32 + f16
    # tiles
    tiles = []
    for name, fn in TILES:
        c = fn(); tiles.append((name, c))
        save(c, os.path.join(BG, f"{name}.png"), masked=False)
    prev["tiles"] = tiles
    write_preview(prev)
    write_readme()
    print(f"  ui: {len(ICONS)} icons, {len(CLUBS)} club logos, 26 farm logos, {len(TILES)} tiles")


def write_preview(p):
    sheet = Image.new("L", (400, 600), 170)
    y = 4

    def row(items, y, gap=4, bg=230):
        x = 4; hmax = 0
        for c in items:
            if x + c.w > 396:
                x = 4; y += hmax + gap; hmax = 0
            sheet.paste(c.flat(bg), (x, y)); x += c.w + gap; hmax = max(hmax, c.h)
        return y + hmax + gap + 2

    y = row(p["icons"], y)
    y = row(p["cursors"] + p["throbber"], y)
    y = row(p["counter-digits"] + p["counter-digits-inv"] + p["counter-roll"], y)
    y = row(p["construction"] + p["bursts"], y)
    y = row(p["mastheads"], y, bg=255)
    y = row(p["logos"], y)
    y = row(p["farm"], y)
    # tiles shown as 2x2 repeats
    x = 4
    for name, c in p["tiles"]:
        rep = Image.new("L", (64, 64))
        for ty in range(0, 64, c.h):
            for tx in range(0, 64, c.w):
                rep.paste(c.im, (tx, ty))
        sheet.paste(rep, (x, y)); x += 68
    y += 70
    sheet = sheet.crop((0, 0, 400, y))
    sheet.resize((800, y * 2), Image.NEAREST).save(os.path.join(PREVIEW, "ui.png"))
    p["splash"].im.resize((800, 480), Image.NEAREST).save(os.path.join(PREVIEW, "ui-splash.png"))


def write_readme():
    names = ", ".join(f"{i + 1} `{n}`" for i, (n, _) in enumerate(ICONS))
    clubs = ", ".join(f"{i + 1} `{a}`" for i, (a, _) in enumerate(CLUBS))
    lines = ["## UI bitmaps (`images/ui/`, `images/logos/`, `images/bg/`)", "",
             "LA = PNG with transparency (alpha 0 outside the shape). 1-bit = opaque.", "",
             "### Icons (32×32, LA)", "",
             f"- `ui/icons/<name>.png` and `ui/icons/<name>-sel.png` (selected = inverted inside the shape).",
             f"- Matrix tables: `ui/icons/icons-table-32-32.png`, `ui/icons/icons-sel-table-32-32.png`, frame order: {names}.",
             "- Label icons below in `Bitmore` (client draws labels; selected label = black box, white text).", "",
             "### Cursors (LA, hotspot = top-left pixel (0,0) unless noted)", "",
             "- `ui/cursor-arrow.png` 16×18 (hotspot 0,0); `ui/cursor-hand.png` 16×18 link hand (hotspot 4,0);",
             "  `ui/cursor-ibeam.png` 8×12 (hotspot 2,6).",
             "- `ui/cursor-busy-table-16-18.png` — 8 frames, wristwatch, minute hand at 12, 1:30, 3, … o'clock (frame 1 = 12). Hotspot 8,9. ~8 fps.", "",
             "### Throbber", "",
             "- `ui/throbber-table-22-14.png` — 8 frames, spinning baseball with speed lines (LA). Frame 1 = idle pose. 10–12 fps while loading.", "",
             "### Hit counter", "",
             f"- `ui/counter-digits-table-{CW}-{CH}.png` — frames 1..10 = digits 0..9, white on black drum (opaque). Place cells edge to edge every {CW} px.",
             f"- `ui/counter-digits-inv-table-{CW}-{CH}.png` — same, black on white.",
             f"- `ui/counter-roll-table-{CW}-{CH}.png` — rolling in-betweens, 3 per digit, laid out 3 columns × 10 rows: frame `d*3 + k` (k=1..3) is",
             "  digit d scrolled 25/50/75% up toward d+1 (9 rolls to 0). Optional odometer animation.", "",
             "### Under construction", "",
             "- `ui/construction-stripe-table-32-10.png` — 8 frames of hazard stripes (opaque); tile horizontally, step 1 frame per tick to scroll.",
             "- `ui/construction-sign-table-32-32.png` — 2 frames, diamond road sign with digging worker (LA).", "",
             "### Starbursts (LA)", "",
             "- `ui/new-burst-table-30-20.png` — 3 frames: black/white \"NEW!\", inverted, rotated. Flash 1↔2, or 1→3.",
             "- `ui/hot-burst-table-30-20.png` — 2 frames \"HOT!\" (normal, inverted).", "",
             "### Mastheads & logos", "",
             "- `ui/masthead-sportswire.png` 240×30 (opaque) — SportsWire ONLINE header.",
             "- `ui/masthead-bobby.png` 220×34 (opaque) — BETS BY BOBBY WordArt with dice on a dotted bg.",
             "- `ui/masthead-continental.png` 240×40 (opaque) — Continental League banner with crests.",
             "- `ui/crest-continental.png` 32×32 (LA) — league crest.",
             "- `ui/navigator-logo-48.png` 48×48 (LA) — Diamond Navigator gem logo.",
             f"- `ui/splash-navigator.png` 400×240 (opaque) — boot splash. Empty progress bar interior rect (x, y, w, h) = {SPLASH_PROGRESS}; fill left→right in black.", "",
             "### Team logos (`logos/`, LA)", "",
             f"- `logos/<ABBR>-32.png` roundel emblems, `logos/<ABBR>-16.png` small badges (2-letter monogram).",
             f"- Tables `logos/clubs-32-table-32-32.png`, `logos/clubs-16-table-16-16.png`, frame order: {clubs}.",
             "- Generic farm logos: `logos/farm-32-table-32-32.png` (pennants) and `logos/farm-16-table-16-16.png`, 26 frames each,",
             "  frame n = letter `A`+(n−1) (use the farm club's city initial), laid out 13 columns × 2 rows.", "",
             "### Tiled backgrounds (`bg/`, opaque, seamless)", "",
             "- `bg/stars.png` 32×32 (white on black), `bg/bricks.png` 32×32, `bg/baseballs.png` 32×32, `bg/marble.png` 64×64, `bg/money.png` 32×32.",
             "  Use `image:drawTiled(x, y, w, h)`.",
             ]
    write_readme_part("50-ui.md", "\n".join(lines))


if __name__ == "__main__":
    build()
