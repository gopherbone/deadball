"""Trading card art: fronts per rarity (2 sizes), backs, pack wrappers + tear-open tables.

Vintage tobacco-card / cabinet-card look, 1-bit, with cheap-cardboard grit.
Face window and text areas are left blank (white) for the client to composite.
Run standalone: python3 tools/assets/cards.py
"""
import os, math
import numpy as np
from PIL import Image

import common
from common import IMAGES, PREVIEW, ensure_dir, write_readme_part
from pixel import Canvas, B, W, save, table, pat_array

OUT = os.path.join(IMAGES, "cards")

RARITIES = ["common", "uncommon", "rare", "gilded", "misprint", "original"]
PACKS = [("wax", "Wax Pack"), ("cigar", "Cigar Box"), ("starter", "Starter"), ("scandal", "Scandal Pack")]

# Layouts: rects are (x, y, w, h) in card pixels.
LAYOUT = {
    "s": dict(size=(110, 154), face=(7, 7, 96, 120), face_img=96,
              name=(6, 129, 98, 12), team=(6, 142, 98, 9), serial=None),
    "l": dict(size=(160, 224), face=(32, 28, 96, 120), face_img=96,
              name=(14, 155, 132, 18), team=(14, 175, 132, 13), serial=(14, 190, 132, 11)),
}
BACK = {
    "s": dict(size=(110, 154), title=(8, 8, 94, 13), stats=(8, 24, 94, 40), text=(8, 68, 94, 66), footer=(6, 137, 98, 11)),
    "l": dict(size=(160, 224), title=(10, 10, 140, 18), stats=(10, 32, 140, 58), text=(10, 95, 140, 100), footer=(8, 200, 144, 16)),
}

# ------------------------------------------------------------------ ornaments

ROSETTE = [
    "..###..",
    ".#...#.",
    "#..#..#",
    "#.###.#",
    "#..#..#",
    ".#...#.",
    "..###..",
]
ROSETTE_W = None  # set below (inverted ROSETTE)
STAR5 = [
    "...#...",
    "...#...",
    "#######",
    ".#####.",
    "..###..",
    ".##.##.",
    "##...##",
]
SPARK = [
    "..o..",
    "..o..",
    "ooooo",
    "..o..",
    "..o..",
]
SCROLL_TL = [  # corner flourish (top-left), black on white
    "#########...",
    "#.......#...",
    "#.#####.#...",
    "#.#...#.##..",
    "#.#.#.#..#..",
    "#.#...#..#..",
    "#.##.##..#..",
    "#........#..",
    "##......##..",
    ".##....##...",
    "..######....",
    "............",
]
SPARK_O = [  # outlined sparkle, reads on patterned gold
    "...#...",
    "..#o#..",
    ".##o##.",
    "#ooooo#",
    ".##o##.",
    "..#o#..",
    "...#...",
]
FLEURON = [  # small leaf ornament for plate ends
    "..#..",
    ".#.#.",
    "#.#.#",
    ".#.#.",
    "..#..",
]


def _flip(rows, h=False, v=False):
    r = [row[::-1] for row in rows] if h else list(rows)
    return r[::-1] if v else r


def corners(c, rows, inset):
    w = len(rows[0]); h = len(rows)
    c.sprite(rows, inset, inset)
    c.sprite(_flip(rows, h=True), c.w - inset - w, inset)
    c.sprite(_flip(rows, v=True), inset, c.h - inset - h)
    c.sprite(_flip(rows, h=True, v=True), c.w - inset - w, c.h - inset - h)


def beads(c, inset, step=3, color=B):
    for x in range(inset, c.w - inset, step):
        c.px(x, inset, color); c.px(x, c.h - 1 - inset, color)
    for y in range(inset, c.h - inset, step):
        c.px(inset, y, color); c.px(c.w - 1 - inset, y, color)


def rr(c, box, color=B):
    """1px rounded-corner rectangle outline (corner pixels cut)."""
    x0, y0, x1, y1 = box
    c.hline(x0 + 1, x1 - 1, y0, color); c.hline(x0 + 1, x1 - 1, y1, color)
    c.vline(x0, y0 + 1, y1 - 1, color); c.vline(x1, y0 + 1, y1 - 1, color)


def window_box(L, grow=0):
    x, y, w, h = L["face"]
    return (x - grow, y - grow, x + w - 1 + grow, y + h - 1 + grow)


def rect_box(r, grow=0):
    x, y, w, h = r
    return (x - grow, y - grow, x + w - 1 + grow, y + h - 1 + grow)


def plate(c, r, style="plain", color_fill=W, ink=B):
    """Nameplate cartouche around text rect r."""
    x0, y0, x1, y1 = rect_box(r, 1)
    if style == "notched":
        c.rect((x0, y0, x1, y1), fill=color_fill)
        c.line((x0 + 2, y0, x1 - 2, y0), ink); c.line((x0 + 2, y1, x1 - 2, y1), ink)
        c.line((x0, y0 + 2, x0, y1 - 2), ink); c.line((x1, y0 + 2, x1, y1 - 2), ink)
        for (px_, py_) in ((x0 + 1, y0 + 1), (x1 - 1, y0 + 1), (x0 + 1, y1 - 1), (x1 - 1, y1 - 1)):
            c.px(px_, py_, ink)
    elif style == "ribbon":
        mid = (y0 + y1) // 2
        # tails
        for sgn, xe in ((-1, x0), (1, x1)):
            tail = [(xe, y0 + 2), (xe + sgn * 6, y0 + 2), (xe + sgn * 3, mid + 1), (xe + sgn * 6, y1 + 2), (xe, y1 + 2)]
            c.poly(tail, fill=B)
        c.rect((x0, y0, x1, y1), fill=color_fill, outline=ink)
        c.hline(x0 + 2, x1 - 2, y0 + 1, ink)
    else:
        c.rect((x0, y0, x1, y1), fill=color_fill, outline=ink)


# ------------------------------------------------------------------ fronts

def front(sz, rarity, seed=0):
    L = LAYOUT[sz]
    w, h = L["size"]
    big = sz == "l"
    c = Canvas(w, h)
    rng = np.random.default_rng(hash((sz, rarity)) & 0xffff)
    inner = Canvas(w, h).region_poly([(0, 0), (w, 0), (w, h), (0, h)])
    wx0, wy0, wx1, wy1 = window_box(L)
    win = np.zeros((h, w), bool); win[wy0:wy1 + 1, wx0:wx1 + 1] = True

    def outside_window(grow):
        r = np.ones((h, w), bool)
        x0, y0, x1, y1 = window_box(L, grow)
        r[max(0, y0):y1 + 1, max(0, x0):x1 + 1] = False
        return r

    if rarity in ("common", "misprint"):
        c.rect((0, 0, w - 1, h - 1), fill=W, outline=B)
        rr(c, (3, 3, w - 4, h - 4))
        if big:
            rr(c, (5, 5, w - 6, h - 6))
            # mat around the photo: light tint + double rule
            c.pattern((8, 8, w - 9, wy1 + 5), "g12", region=outside_window(4))
            rr(c, window_box(L, 4))
            rr(c, window_box(L, 2))
            corners(c, ROSETTE, 9)
        c.rect(window_box(L, 1), outline=B)
        plate(c, L["name"], "plain")
        if big:
            plate(c, L["team"], "plain")
    elif rarity == "uncommon":
        c.rect((0, 0, w - 1, h - 1), fill=W, outline=B)
        band = np.zeros((h, w), bool); band[2:h - 2, 2:w - 2] = True; band[6:h - 6, 6:w - 6] = False
        c.pattern((0, 0, w - 1, h - 1), "g25", region=band)
        rr(c, (2, 2, w - 3, h - 3)); rr(c, (6, 6, w - 7, h - 7))
        corners(c, ROSETTE, 1 if not big else 3)
        if big:
            c.pattern((8, 8, w - 9, wy1 + 6), "diag", region=outside_window(5) & (np.indices((h, w))[0] > 7))
            c.rect(window_box(L, 5), outline=B); c.rect(window_box(L, 4), outline=W); c.rect(window_box(L, 3), outline=W)
        c.rect(window_box(L, 2), outline=B); c.rect(window_box(L, 1), outline=W)
        plate(c, L["name"], "notched")
        if big:
            plate(c, L["team"], "plain")
    elif rarity == "rare":
        # black border with white filigree (T205-ish)
        c.rect((0, 0, w - 1, h - 1), fill=B)
        rr(c, (2, 2, w - 3, h - 3), W)
        beads(c, 4, 2, W)
        if big:
            c.pattern((7, 7, w - 8, h - 8), "g87")
            rr(c, (6, 6, w - 7, h - 7), W)
            corners(c, ROSETTE_W, 8)
            c.rect(window_box(L, 4), outline=W)
        c.rect(window_box(L, 2), outline=W); c.rect(window_box(L, 1), outline=B)
        plate(c, L["name"], "notched")
        if big:
            plate(c, L["team"], "notched")
            plate(c, L["serial"], "plain", color_fill=B, ink=W)
    elif rarity == "gilded":
        c.rect((0, 0, w - 1, h - 1), fill=W, outline=B)
        gold = np.ones((h, w), bool); gold[[0, h - 1], :] = False; gold[:, [0, w - 1]] = False
        gold &= outside_window(3)
        c.pattern((1, 1, w - 2, h - 2), "cross", region=gold)
        rr(c, (2, 2, w - 3, h - 3)); rr(c, (3, 3, w - 4, h - 4), W)
        # sparkles on the gold leaf
        for _ in range(10 if big else 5):
            x = int(rng.integers(4, w - 9)); y = int(rng.integers(4, h - 9))
            if not win[max(0, y - 6):y + 10, max(0, x - 6):x + 10].any():
                c.sprite(SPARK_O, x - 1, y - 1)
        c.rect(window_box(L, 3), outline=B); c.rect(window_box(L, 2), outline=W); c.rect(window_box(L, 1), outline=B)
        beads(c, 1, 2, W)
        plate(c, L["name"], "ribbon")
        if big:
            plate(c, L["team"], "plain")
            plate(c, L["serial"], "plain")
    elif rarity == "original":
        # cabinet card: thick black mat, gilt double rule, studio imprint, seal
        c.rect((0, 0, w - 1, h - 1), fill=B)
        rr(c, (3, 3, w - 4, h - 4), W); rr(c, (5, 5, w - 6, h - 6), W)
        corners(c, _invert_rows(SCROLL_TL), 7)
        c.rect(window_box(L, 3), outline=W); c.rect(window_box(L, 1), outline=W)
        plate(c, L["name"], "notched")
        if big:
            plate(c, L["team"], "notched")
            plate(c, L["serial"], "plain", color_fill=B, ink=W)
    # misprint: registration-shifted ghost frame + ink blot + crop mark
    if rarity == "misprint":
        ghost = Canvas(w, h, opaque=False)
        dx, dy = (3, 2) if big else (2, 2)
        x0, y0, x1, y1 = window_box(L, 1)
        dx, dy = dx + 1, dy + 1
        ghost.rect((x0 + dx, y0 + dy, x1 + dx, y1 + dy), outline=B)
        ghost.rect((3 + dx, 3 + dy, w - 4 + dx, h - 4 + dy), outline=B)
        for k in ("name", "team"):
            if L.get(k):
                bx0, by0, bx1, by1 = rect_box(L[k], 1)
                ghost.rect((bx0 + dx, by0 + dy, bx1 + dx, by1 + dy), outline=B)
        gm = np.asarray(ghost.mask) > 0
        gm &= outside_window(0)
        a = np.asarray(c.im).copy(); dith = pat_array("g50", w, h)
        a[gm] = B
        c.im = Image.fromarray(a, "L"); c.d = __import__("PIL.ImageDraw", fromlist=["x"]).Draw(c.im)
        # blot
        bx, by = (w - 22, h - 26) if big else (w - 15, 5)
        if big:
            c.ellipse((bx, by, bx + 7, by + 5), fill=B); c.px(bx + 9, by + 2); c.px(bx - 2, by + 6); c.px(bx + 3, by + 8)
        else:
            c.ellipse((bx, by - 3, bx + 4, by), fill=B); c.px(bx + 6, by - 1)
        # registration cross
        rx, ry = 4 if big else 2, h - 9 if big else h - 7
        c.line((rx, ry + 3, rx + 6, ry + 3)); c.line((rx + 3, ry, rx + 3, ry + 6))
        c.ellipse((rx + 1, ry + 1, rx + 5, ry + 5), outline=B)

    # header / footer imprints for big fronts
    if big:
        hy = 9 if rarity not in ("gilded",) else 9
        title = {"common": "BASE BALL SERIES", "uncommon": "BASE BALL SERIES", "rare": "CHAMPIONS SERIES",
                 "gilded": "GILDED EDITION", "misprint": "BASE BALL SREIES", "original": "ORIGINAL"}[rarity]
        dark = rarity in ("rare", "original")
        f = common.font("tiny")
        tw_ = f.width(title)
        if rarity == "gilded":
            c.rect((w // 2 - tw_ // 2 - 4, hy + 1, w // 2 + tw_ // 2 + 3, hy + 11), fill=W, outline=B)
        if rarity in ("common", "uncommon", "misprint"):
            c.rect((w // 2 - tw_ // 2 - 3, hy + 1, w // 2 + tw_ // 2 + 2, hy + 11), fill=W)
        c.ctext(w // 2, hy + 1, title, "tiny", W if dark else B)
        if rarity not in ("rare", "original"):
            c.sprite(FLEURON, w // 2 - tw_ // 2 - 10, hy + 3); c.sprite(FLEURON, w // 2 + tw_ // 2 + 5, hy + 3)
        # footer imprint
        fy = h - 19
        foot = "CONTINENTAL LEAGUE"
        if rarity in ("rare", "original"):
            c.ctext(w // 2, fy, foot, "tiny", W)
        else:
            c.rect((w // 2 - f.width(foot) // 2 - 3, fy, w // 2 + f.width(foot) // 2 + 2, fy + 10), fill=W)
            c.ctext(w // 2, fy, foot, "tiny", B)
        if rarity == "original":
            # gilt seal bottom-right
            sx, sy = w - 30, L["serial"][1] - 2
            c.ellipse((sx, sy + 12, sx + 16, sy + 28), fill=W, outline=B)
            c.ellipse((sx + 2, sy + 14, sx + 14, sy + 26), outline=B)
            c.sprite(STAR5, sx + 5, sy + 17)
    # make sure text rects are clean white
    for k in ("name", "team", "serial"):
        r = L.get(k)
        if r and not (k == "team" and not big and False):
            if k == "serial" and rarity in ("rare", "original"):
                c.rect(rect_box(r), fill=B)
            else:
                c.rect(rect_box(r), fill=W)
    if not big:
        # small: team line sits on white below plate
        c.rect(rect_box(L["team"]), fill=W if rarity not in ("rare", "original") else B)
    # cardboard grit (not in window/plates)
    keep = np.ones((h, w), bool)
    for r in [window_box(L, 1)] + [rect_box(L[k], 1) for k in ("name", "team", "serial") if L.get(k)]:
        keep[r[1]:r[3] + 1, r[0]:r[2] + 1] = False
    c.grit((1, 1, w - 2, h - 2), density=0.012 if rarity not in ("original", "rare") else 0.003, seed=len(rarity) * 7 + w, region=keep)
    # window stays white
    c.rect(window_box(L), fill=W)
    c.round_corners(3 if big else 2)
    return c


def _invert_rows(rows):
    return ["".join("o" if ch == "#" else "#" for ch in r) for r in rows]


ROSETTE_W = _invert_rows(ROSETTE)


# ------------------------------------------------------------------ backs

def back(sz):
    L = BACK[sz]
    w, h = L["size"]
    big = sz == "l"
    c = Canvas(w, h)
    c.rect((0, 0, w - 1, h - 1), fill=W, outline=B)
    band = np.zeros((h, w), bool); band[2:h - 2, 2:w - 2] = True; band[5:h - 5, 5:w - 5] = False
    c.pattern((0, 0, w - 1, h - 1), "g50", region=band)
    rr(c, (5, 5, w - 6, h - 6))
    # title bar (black, client draws name in white)
    c.rect(rect_box(L["title"]), fill=B)
    # stats grid lines: header rule + column hint dots
    x0, y0, x1, y1 = rect_box(L["stats"])
    c.rect((x0, y0, x1, y1), outline=B)
    row_h = 9 if not big else 11
    for yy in range(y0 + row_h + 1, y1, row_h):
        for xx in range(x0 + 1, x1, 2):
            c.px(xx, yy)
    # text area: no ruling, just a top flourish
    tx0, ty0, tx1, ty1 = rect_box(L["text"])
    cx = (tx0 + tx1) // 2
    c.hline(tx0 + 10, cx - 5, ty0 - 2); c.hline(cx + 5, tx1 - 10, ty0 - 2)
    c.sprite(FLEURON, cx - 2, ty0 - 4)
    # footer ad
    fx0, fy0, fx1, fy1 = rect_box(L["footer"])
    c.rect((fx0, fy0, fx1, fy1), fill=B)
    ad = "SMOKE DEADBALL CIGARETTES" if big else "DEADBALL SMOKES"
    c.ctext((fx0 + fx1) // 2 + 1, fy0 + (0 if not big else 3) , ad, "tiny", W)
    c.grit((1, 1, w - 2, h - 2), density=0.02, seed=w + 3, region=_not_rects(w, h, [rect_box(L["text"], 1), rect_box(L["title"], 1), rect_box(L["stats"], 0)]))
    c.round_corners(3 if big else 2)
    return c


def _not_rects(w, h, boxes):
    keep = np.ones((h, w), bool)
    for x0, y0, x1, y1 in boxes:
        keep[y0:y1 + 1, x0:x1 + 1] = False
    return keep


# ------------------------------------------------------------------ packs

PW, PH = 112, 160


def pack_art(kind):
    """Closed wrapper, full opaque art inside a transparent canvas (crimped ends)."""
    c = Canvas(PW, PH, opaque=False)
    if kind == "wax":
        c.rect((4, 6, PW - 5, PH - 7), fill=W, outline=B)
        # crimp edges
        for x in range(4, PW - 4, 3):
            c.line((x, 2, x, 6)); c.line((x, PH - 7, x, PH - 3))
        c.hline(4, PW - 5, 2); c.hline(4, PW - 5, PH - 3)
        # diagonal waxy stripes behind logo
        reg = c.region_poly([(5, 7), (PW - 6, 7), (PW - 6, PH - 8), (5, PH - 8)])
        c.pattern((5, 7, PW - 6, PH - 8), "dstripe", region=reg)
        # logo panel
        c.rect((12, 26, PW - 13, 84), fill=W, outline=B)
        c.rect((14, 28, PW - 15, 82), outline=B)
        c.ctext(PW // 2, 31, "BASE", "slabb"); c.ctext(PW // 2, 47, "BALL", "slabb")
        c.ctext(PW // 2, 66, "CARDS", "tiny")
        # starburst price
        burst(c, PW // 2, 110, 22, 16)
        c.ctext(PW // 2, 101, "10", "ui"); c.ctext(PW // 2, 113, "CARDS", "tiny")
        c.rect((10, PH - 26, PW - 11, PH - 14), fill=B)
        c.ctext(PW // 2, PH - 25, "WITH STICK OF GUM", "tiny", W)
    elif kind == "cigar":
        # box seen 3/4 from top: lid + front
        c.rect((4, 10, PW - 5, PH - 5), fill=W, outline=B)
        c.pattern((5, 11, PW - 6, PH - 6), "vline")  # wood grain base
        # grain wiggles
        for y in range(14, PH - 6, 7):
            c.hline(5, PW - 6, y, W)
        # label
        c.rect((12, 24, PW - 13, 92), fill=W, outline=B)
        c.rect((14, 26, PW - 15, 90), outline=B)
        c.ellipse((PW // 2 - 18, 30, PW // 2 + 18, 58), fill=W, outline=B)
        c.ellipse((PW // 2 - 16, 32, PW // 2 + 16, 56), outline=B)
        c.sprite(STAR5, PW // 2 - 3, 41)
        c.ctext(PW // 2, 61, "LA PELOTA", "medieval"); c.ctext(PW // 2, 74, "FINA", "medieval")
        # cigar band ribbon across
        c.rect((4, 104, PW - 5, 120), fill=B)
        c.ctext(PW // 2, 107, "HAND ROLLED CARDS", "tiny", W)
        c.ctext(PW // 2, 128, "HABANA - EST. 1903", "tiny", B) if False else None
        c.rect((20, 127, PW - 21, 139), fill=W, outline=B)
        c.ctext(PW // 2, 128, "BOX OF 25", "tiny")
        # tax stamp seal over lid seam
        c.rect((4, 6, PW - 5, 12), fill=W, outline=B)
        c.rect((PW // 2 - 8, 4, PW // 2 + 8, 16), fill=W, outline=B)
        c.pattern((PW // 2 - 7, 5, PW // 2 + 7, 15), "cross")
    elif kind == "starter":
        c.rect((6, 4, PW - 7, PH - 5), fill=W, outline=B)
        c.rect((8, 6, PW - 9, PH - 7), outline=B)
        c.pattern((9, 7, PW - 10, 40), "g50")
        c.rect((9, 40, PW - 10, 41), fill=B)
        c.ctext(PW // 2, 50, "STARTER", "slabb"); c.ctext(PW // 2, 68, "SET", "slabb")
        c.ctext(PW // 2, 92, "5 CARDS", "ui")
        c.ctext(PW // 2, 106, "A FINE START TO A", "tiny"); c.ctext(PW // 2, 116, "LIFETIME HOBBY", "tiny")
        # little baseball
        c.ellipse((PW // 2 - 8, 126, PW // 2 + 8, 142), fill=W, outline=B)
        c.line((PW // 2 - 4, 128, PW // 2 - 6, 140)); c.line((PW // 2 + 4, 128, PW // 2 + 6, 140))
        c.pattern((7, PH - 15, PW - 8, PH - 6), "g25")
    elif kind == "scandal":
        c.rect((4, 6, PW - 5, PH - 7), fill=B)
        for x in range(4, PW - 4, 3):
            c.line((x, 2, x, 6)); c.line((x, PH - 7, x, PH - 3))
        c.hline(4, PW - 5, 2); c.hline(4, PW - 5, PH - 3)
        # police tape diagonal
        tape = c.region_poly([(4, 104), (PW - 5, 74), (PW - 5, 90), (4, 120)])
        c.pattern((4, 70, PW - 5, 124), "g12", region=tape)
        c.rect((4, 70, 4, 70), fill=B)
        for t in range(0, PW, 26):
            ty = int(104 - (t / (PW - 9)) * 30) + 3
            c.text((6 + t, ty), "XX", "tiny")
        c.ctext(PW // 2, 16, "EXTRA!", "ui", W)
        c.rect((10, 30, PW - 11, 62), fill=W)
        c.ctext(PW // 2, 30, "SCANDAL", "slabb"); c.ctext(PW // 2, 46, "PACK", "slabb")
        c.ctext(PW // 2, 130, "NOT FOR MINORS", "tiny", W); c.ctext(PW // 2, 140, "OR COMMISSIONERS", "tiny", W)
        # magnifier glyph
        c.ellipse((14, 72, 28, 86), outline=W, width=2)
        c.line((26, 85, 32, 92), W, 3)
    c.grit((0, 0, PW - 1, PH - 1), density=0.008, seed=len(kind) * 31, region=np.asarray(c.mask) > 0)
    return c


def burst(c, cx, cy, r, n=14, fill=W):
    pts = []
    for i in range(n * 2):
        a = math.pi * i / n
        rad = r if i % 2 == 0 else r * 0.68
        pts.append((cx + rad * math.cos(a), cy + rad * 0.62 * math.sin(a)))
    c.poly(pts, fill=fill, outline=B)


def card_stack(c, top_y):
    """Card edges peeking from an opened pack: a few stacked card tops."""
    for i, off in enumerate((0, 3, 6)):
        y = top_y + off
        c.rect((14 + i, y, PW - 15 - i, y + 20), fill=W, outline=B)
        c.hline(18 + i, PW - 19 - i, y + 3)


def pack_frames(kind):
    """4 frames: closed, tear starts, top torn off / lid lifting, open with cards rising."""
    closed = pack_art(kind)
    frames = [closed.copy()]
    if kind == "cigar":
        # lid lifts: shift top region up and compress, show cards in box
        for k, lift in enumerate((10, 24, 40)):
            f = Canvas(PW, PH, opaque=False)
            body = closed.copy()
            # interior with cards
            f.paste(body, (0, 0))
            f.rect((4, 10, PW - 5, 96), fill=B)
            card_stack(f, 20 + (2 - k) * 6)
            # lid: parallelogram rising
            lid_h = max(6, 88 - lift * 2)
            ly = 10 - lift
            f.poly([(4, ly), (PW - 5, ly), (PW - 5, ly + lid_h), (4, ly + lid_h)], fill=W, outline=B)
            f.pattern((5, max(0, ly + 1), PW - 6, ly + lid_h - 1), "hline", region=f.region_poly([(5, ly + 1), (PW - 6, ly + 1), (PW - 6, ly + lid_h - 1), (5, ly + lid_h - 1)]))
            if lid_h > 30:
                f.rect((20, ly + 8, PW - 21, ly + lid_h - 8), fill=W, outline=B)
                f.ctext(PW // 2, ly + lid_h // 2 - 5, "FINA", "medieval")
            frames.append(f)
        return frames
    # wrappers: jagged tear line moving across the top, flap peels off
    rng = np.random.default_rng(len(kind))
    tear_y = 22
    jag = [tear_y + int(rng.integers(-2, 3)) for _ in range(PW // 4 + 2)]
    for k in range(1, 4):
        f = closed.copy()
        if k == 1:
            # tear started from left: flap lifted on left third
            xt = PW // 3
            f.clear((0, 0, xt, tear_y - 1))
            pts = [(i * 4, jag[i]) for i in range(xt // 4 + 1)]
            for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
                f.line((x0, y0, x1, y1), B)
            # flap curling up-left
            f.poly([(2, tear_y - 2), (xt, tear_y - 2), (xt - 10, 2), (8, 0)], fill=W, outline=B)
            f.pattern((3, 1, xt - 2, tear_y - 3), "g25", region=f.region_poly([(4, tear_y - 3), (xt - 2, tear_y - 3), (xt - 11, 3), (9, 1)]))
        elif k == 2:
            f.clear((0, 0, PW - 1, tear_y - 1))
            pts = [(i * 4, jag[i]) for i in range(PW // 4 + 1)]
            # opening: dark interior strip + card tops
            f.rect((5, tear_y, PW - 6, tear_y + 6), fill=B)
            for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
                f.line((x0, y0, x1, y1), B)
            # flap flying away top-right
            f.poly([(PW - 30, 4), (PW - 2, 0), (PW - 4, 12), (PW - 34, 15)], fill=W, outline=B)
            f.pattern((PW - 31, 1, PW - 3, 14), "dstripe", region=f.region_poly([(PW - 29, 5), (PW - 3, 1), (PW - 5, 11), (PW - 33, 14)]))
        else:
            f.clear((0, 0, PW - 1, tear_y - 1))
            card_stack(f, 2)
            f.rect((5, tear_y + 1, PW - 6, tear_y + 4), fill=B)
            pts = [(i * 4, jag[i] + 1) for i in range(PW // 4 + 1)]
            for (x0, y0), (x1, y1) in zip(pts, pts[1:]):
                f.line((x0, y0, x1, y1), B)
        frames.append(f)
    return frames


# ------------------------------------------------------------------ build

def build():
    ensure_dir(OUT)
    for f in os.listdir(OUT):
        if f.endswith(".png"):
            os.remove(os.path.join(OUT, f))
    previews = []
    fronts = {}
    for sz in ("s", "l"):
        w, h = LAYOUT[sz]["size"]
        for r in RARITIES:
            c = front(sz, r)
            save(c, os.path.join(OUT, f"front-{r}-{w}x{h}.png"))
            fronts[(sz, r)] = c
        bc = back(sz)
        save(bc, os.path.join(OUT, f"back-{w}x{h}.png"))
        fronts[(sz, "back")] = bc
    for kind, _ in PACKS:
        fr = pack_frames(kind)
        save(fr[0], os.path.join(OUT, f"pack-{kind}.png"))
        table(fr, OUT, f"pack-{kind}-open")
        fronts[("pack", kind)] = fr
    write_preview(fronts)
    write_readme()
    print(f"  cards: {len(RARITIES) * 2} fronts, 2 backs, {len(PACKS)} packs")


def mock_face(wd, ht):
    """Placeholder face (dithered gradient oval) for previews only."""
    yy, xx = np.mgrid[0:ht, 0:wd]
    cx, cy = wd / 2, ht * 0.45
    d = ((xx - cx) / (wd * 0.32)) ** 2 + ((yy - cy) / (ht * 0.33)) ** 2
    a = np.where(d < 1, 200 - 60 * d, 90 + 40 * (yy / ht))
    a[yy > ht * 0.78] = 60
    return common.atkinson(Image.fromarray(a.astype(np.uint8), "L"))


def composite_demo(c, sz, name="MULLANE", team="HARBOR CITY", serial="No. 042 / 500"):
    L = LAYOUT[sz]
    im = c.flat(255)
    fx, fy, fw, fh = L["face"]
    im.paste(mock_face(fw, fh), (fx, fy))
    nm = L["name"]
    fk = "ui" if sz == "s" else "slabb"
    f = common.font(fk)
    f.draw(im, (nm[0] + nm[2] // 2 - f.width(name) // 2, nm[1] + (nm[3] - f.height) // 2 + (1 if sz == "s" else 1)), name)
    t = L["team"]; ft = common.font("tiny")
    tcol = 255 if (c.im.getpixel((t[0] + 1, t[1] + 1)) == 0) else 0
    ft.draw(im, (t[0] + t[2] // 2 - ft.width(team) // 2, t[1] - 1), team, tcol)
    if L["serial"]:
        s = L["serial"]; scol = 255 if c.im.getpixel((s[0] + 1, s[1] + 1)) == 0 else 0
        ft.draw(im, (s[0] + s[2] // 2 - ft.width(serial) // 2, s[1]), serial, scol)
    return im


def write_preview(fr):
    from PIL import Image as I
    sheet = I.new("L", (6 * 166 + 6, 160 + 230 + 230 + 235), 180)
    x = 4
    for r in RARITIES:
        sheet.paste(composite_demo(fr[("s", r)], "s"), (x, 4)); x += 114
    x = 4
    for r in RARITIES:
        sheet.paste(fr[("l", r)].flat(180), (x, 164)); x += 164
    x = 4
    for r in RARITIES:
        sheet.paste(composite_demo(fr[("l", r)], "l"), (x, 392)); x += 164
    y = 620
    sheet.paste(fr[("s", "back")].flat(180), (4, y)); sheet.paste(fr[("l", "back")].flat(180), (118, y))
    x = 284
    for kind, _ in PACKS:
        for f in fr[("pack", kind)]:
            pass
    # packs on a separate sheet row
    x = 284
    for kind, _ in PACKS[:2]:
        sheet.paste(fr[("pack", kind)][0].flat(180), (x, y)); x += 116
    ensure_dir(PREVIEW)
    sheet.resize((sheet.width * 2, sheet.height * 2), I.NEAREST).save(os.path.join(PREVIEW, "cards.png"))
    # packs sheet
    ps = I.new("L", (4 * (PW + 4) + 4, len(PACKS) * (PH + 4) + 4), 180)
    for j, (kind, _) in enumerate(PACKS):
        for i, f in enumerate(fr[("pack", kind)]):
            ps.paste(f.flat(180), (4 + i * (PW + 4), 4 + j * (PH + 4)))
    ps.resize((ps.width * 2, ps.height * 2), I.NEAREST).save(os.path.join(PREVIEW, "packs.png"))


def write_readme():
    s, l = LAYOUT["s"], LAYOUT["l"]
    bs, bl = BACK["s"], BACK["l"]
    lines = ["## Cards (`images/cards/`)", "",
             "All card images are LA PNGs (transparent rounded corners). Draw the frame, then the face into",
             "the face window, then text into the text rects. Rects are `x, y, w, h` relative to the card's",
             "top-left. The face window is plain white and exactly fits the 96×120 face image",
             "(`images/faces/<n>-96.png`) on both sizes; the large card just has a wider mat.", "",
             "### Fronts", "",
             "`cards/front-<rarity>-110x154.png` (binder / pack reveal) and `cards/front-<rarity>-160x224.png` (zoom;",
             "taller than the screen, scroll with the crank). `<rarity>` ∈ " + ", ".join(f"`{r}`" for r in RARITIES) + ".", "",
             "| rect | 110×154 | 160×224 | suggested font / colour |", "|---|---|---|---|",
             f"| face window | {s['face']} | {l['face']} | draw `faces/<n>-96.png` at (x, y) |",
             f"| name | {s['name']} | {l['name']} | small: `Nontendo-Bold` caps; large: `Sasser-Slab-Bold`; centred, black |",
             f"| team | {s['team']} | {l['team']} | `Bitmore` caps, centred (draw at y−1). Small `rare`/`original`: team rect is BLACK → white text |",
             f"| serial / position | — | {l['serial']} | `Bitmore`, centred. BLACK on `rare`/`original` → white text; white elsewhere |",
             "",
             "Large fronts have pre-printed header (series name per rarity) and footer (\"CONTINENTAL LEAGUE\").",
             "`misprint` = common layout with a mis-registered ghost frame, blot and crop mark — the face",
             "window is in the same place (client may additionally offset the face by 1–2 px for fun).", "",
             "### Backs", "",
             "`cards/back-110x154.png`, `cards/back-160x224.png`.", "",
             "| rect | 110×154 | 160×224 | notes |", "|---|---|---|---|",
             f"| title | {bs['title']} | {bl['title']} | BLACK bar: draw name in white (`Nontendo-Bold` / `Sasser-Slab-Bold`) |",
             f"| stats | {bs['stats']} | {bl['stats']} | boxed table, dotted row rules every {9} px (small) / {11} px (large) from the top; use `Roobert-9-Mono-Condensed` (large) or `Bitmore` (small) |",
             f"| text | {bs['text']} | {bl['text']} | snarky blurb, black on white (`Bitmore` small, `Nontendo-Light` large) |",
             f"| footer | {bs['footer']} | {bl['footer']} | pre-printed ad, leave alone |",
             "",
             "### Packs", "",
             f"Pack kinds: " + ", ".join(f"`{k}` ({n})" for k, n in PACKS) + f". Each {PW}×{PH}, LA (transparent outside the wrapper).", "",
             f"- `cards/pack-<kind>.png` — closed pack (same as frame 1).",
             f"- `cards/pack-<kind>-open-table-{PW}-{PH}.png` — 4-frame tear-open: 1 closed, 2 tear starts (top-left flap / cigar lid cracks),",
             "  3 top torn off (flap flies right / lid half open), 4 open with card tops showing. Play ~4–6 fps, then slide",
             "  cards up out of the top (cards emerge around y≈2..30 of the pack).",
             ]
    write_readme_part("40-cards.md", "\n".join(lines))


if __name__ == "__main__":
    build()
