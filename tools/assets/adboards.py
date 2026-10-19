"""Graphic ad boards for the BallCast ballparks: python3 tools/assets/adboards.py [--preview]

Redraws playdate/source/images/parks/tex/ad_<brand>.png (128x16, 1-bit, same names, so the baked
parks keep working) as bold graphics instead of text: an icon picked from the brand, at most a
3-letter wordmark in a chunky block font, and a high-contrast pattern band. Boards alternate
normal / inverted. In the game the boards pair up as trivision boards (bc3d.alt) that slat-flip
between two brands every few seconds, and are textured only up close (bc3d.quality)."""
import glob, os, re, sys
from PIL import Image, ImageDraw

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.join(HERE, "..", "..", "playdate", "source", "images", "parks", "tex")
PREVIEW = os.path.join(HERE, "preview", "adboards.png")
W, H = 128, 16

# 3x5 block font, drawn at 2x (6x10) with a 1 px gap
FONT = {
    "A": ["###", "#.#", "###", "#.#", "#.#"], "B": ["##.", "#.#", "##.", "#.#", "##."], "C": ["###", "#..", "#..", "#..", "###"],
    "D": ["##.", "#.#", "#.#", "#.#", "##."], "E": ["###", "#..", "##.", "#..", "###"], "F": ["###", "#..", "##.", "#..", "#.."],
    "G": ["###", "#..", "#.#", "#.#", "###"], "H": ["#.#", "#.#", "###", "#.#", "#.#"], "I": ["###", ".#.", ".#.", ".#.", "###"],
    "J": ["..#", "..#", "..#", "#.#", "###"], "K": ["#.#", "#.#", "##.", "#.#", "#.#"], "L": ["#..", "#..", "#..", "#..", "###"],
    "M": ["#.#", "###", "###", "#.#", "#.#"], "N": ["##.", "#.#", "#.#", "#.#", "#.#"], "O": ["###", "#.#", "#.#", "#.#", "###"],
    "P": ["###", "#.#", "###", "#..", "#.."], "Q": ["###", "#.#", "#.#", "###", "..#"], "R": ["###", "#.#", "##.", "#.#", "#.#"],
    "S": ["###", "#..", "###", "..#", "###"], "T": ["###", ".#.", ".#.", ".#.", ".#."], "U": ["#.#", "#.#", "#.#", "#.#", "###"],
    "V": ["#.#", "#.#", "#.#", "#.#", ".#."], "W": ["#.#", "#.#", "###", "###", "#.#"], "X": ["#.#", "#.#", ".#.", "#.#", "#.#"],
    "Y": ["#.#", "#.#", ".#.", ".#.", ".#."], "Z": ["###", "..#", ".#.", "#..", "###"], "$": [".#.", "###", "##.", ".##", "###"],
    "1": [".#.", "##.", ".#.", ".#.", "###"], "2": ["##.", "..#", ".#.", "#..", "###"], "9": ["###", "#.#", "###", "..#", "###"],
    "8": ["###", "#.#", "###", "#.#", "###"], "5": ["###", "#..", "##.", "..#", "##."], "0": ["###", "#.#", "#.#", "#.#", "###"],
    "4": ["#.#", "#.#", "###", "..#", "..#"], "7": ["###", "..#", ".#.", ".#.", ".#."], "6": ["###", "#..", "###", "#.#", "###"],
    "3": ["###", "..#", ".##", "..#", "###"], "!": [".#.", ".#.", ".#.", "...", ".#."], "&": [".#.", "#.#", ".#.", "#.#", ".##"],
}


def word(d, x, y, text, ink):
    for ch in text:
        g = FONT.get(ch)
        if g:
            for r, row in enumerate(g):
                for c, v in enumerate(row):
                    if v == "#":
                        d.rectangle([x + c * 2, y + r * 2, x + c * 2 + 1, y + r * 2 + 1], fill=ink)
        x += 8
    return x


# ---------------------------------------------------------------- icons (draw into a 20x16 box at x)
def i_hotdog(d, x, ink):
    d.ellipse([x, 4, x + 19, 13], fill=ink)
    d.ellipse([x + 2, 6, x + 17, 10], fill=1 - ink)
    d.ellipse([x + 1, 6, x + 18, 9], fill=ink)
    for k in range(0, 14, 4):
        d.line([x + 3 + k, 7, x + 5 + k, 8], fill=1 - ink)


def i_bolt(d, x, ink):
    d.polygon([(x + 11, 0), (x + 3, 9), (x + 9, 9), (x + 6, 15), (x + 16, 5), (x + 10, 5), (x + 13, 0)], fill=ink)


def i_dice(d, x, ink):
    for ox, oy in ((0, 3), (9, 0)):
        d.rectangle([x + ox, oy, x + ox + 9, oy + 9], fill=ink)
        for px, py in ((2, 2), (6, 6), (4, 4)) if ox else ((2, 2), (6, 2), (2, 6), (6, 6)):
            d.rectangle([x + ox + px, oy + py, x + ox + px + 1, oy + py + 1], fill=1 - ink)


def i_star(d, x, ink, cx=None):
    import math
    cx = x + 9
    pts = []
    for k in range(10):
        r = 8 if k % 2 == 0 else 3.5
        a = -math.pi / 2 + k * math.pi / 5
        pts.append((cx + r * math.cos(a), 8 + r * math.sin(a)))
    d.polygon(pts, fill=ink)


def i_raccoon(d, x, ink):
    d.polygon([(x + 2, 1), (x + 5, 5), (x + 14, 5), (x + 17, 1), (x + 18, 9), (x + 10, 15), (x + 1, 9)], fill=ink)
    d.rectangle([x + 3, 7, x + 16, 9], fill=1 - ink)
    d.rectangle([x + 6, 7, x + 7, 8], fill=ink)
    d.rectangle([x + 12, 7, x + 13, 8], fill=ink)


def i_comet(d, x, ink):
    d.ellipse([x + 11, 2, x + 18, 9], fill=ink)
    for k in range(4):
        d.line([x + 12 - k, 8 + k, x + 1 + k * 2, 15], fill=ink)


def i_cross(d, x, ink):
    d.rectangle([x + 8, 0, x + 11, 15], fill=ink)
    d.rectangle([x + 3, 4, x + 16, 7], fill=ink)


def i_anchor(d, x, ink):
    d.ellipse([x + 8, 0, x + 12, 4], outline=ink)
    d.rectangle([x + 9, 4, x + 10, 14], fill=ink)
    d.rectangle([x + 5, 5, x + 14, 6], fill=ink)
    d.arc([x + 2, 4, x + 17, 15], 20, 160, fill=ink, width=2)


def i_wheel(d, x, ink):
    d.ellipse([x + 2, 0, x + 17, 15], fill=ink)
    d.ellipse([x + 6, 4, x + 13, 11], fill=1 - ink)
    d.ellipse([x + 8, 6, x + 11, 9], fill=ink)


def i_modem(d, x, ink):
    d.rectangle([x + 1, 8, x + 18, 14], fill=ink)
    for k in range(3):
        d.rectangle([x + 4 + k * 4, 11, x + 5 + k * 4, 12], fill=1 - ink)
    for r in (3, 6):
        d.arc([x + 10 - r, 6 - r, x + 10 + r, 6 + r], 200, 340, fill=ink)


def i_pie(d, x, ink):
    d.pieslice([x + 1, 1, x + 18, 18], 180, 360, fill=ink)
    for k in range(3, 18, 4):
        d.line([x + k, 4, x + k, 9], fill=1 - ink)
    d.rectangle([x, 10, x + 19, 12], fill=ink)


def i_steer(d, x, ink):
    d.polygon([(x, 2), (x + 6, 5), (x + 13, 5), (x + 19, 2), (x + 15, 7), (x + 13, 15), (x + 6, 15), (x + 4, 7)], fill=ink)
    d.rectangle([x + 7, 8, x + 8, 9], fill=1 - ink)
    d.rectangle([x + 11, 8, x + 12, 9], fill=1 - ink)


def i_wheat(d, x, ink):
    d.line([x + 10, 15, x + 10, 1], fill=ink, width=2)
    for k in range(4):
        y = 2 + k * 3
        d.ellipse([x + 4, y, x + 9, y + 3], fill=ink)
        d.ellipse([x + 11, y, x + 16, y + 3], fill=ink)


def i_dollar(d, x, ink):
    d.ellipse([x + 1, 0, x + 18, 15], fill=ink)
    word(d, x + 7, 3, "$", 1 - ink)


def i_girder(d, x, ink):
    d.rectangle([x, 1, x + 19, 4], fill=ink)
    d.rectangle([x, 11, x + 19, 14], fill=ink)
    for k in range(0, 18, 6):
        d.line([x + k, 4, x + k + 6, 11], fill=ink, width=2)


def i_moon(d, x, ink):
    d.ellipse([x + 3, 1, x + 16, 14], fill=ink)
    d.ellipse([x + 7, -1, x + 19, 11], fill=1 - ink)
    d.point([(x + 16, 12), (x + 18, 6)], fill=ink)


def i_badge(d, x, ink):
    i_star(d, x, ink)
    d.ellipse([x + 7, 6, x + 11, 10], fill=1 - ink)


def i_bingo(d, x, ink):
    d.ellipse([x + 2, 0, x + 17, 15], fill=ink)
    d.ellipse([x + 5, 3, x + 14, 12], fill=1 - ink)
    word(d, x + 6, 3, "7"[:1], ink) if False else d.text((x + 7, 3), "B", fill=ink)


def i_bottle(d, x, ink):
    d.rectangle([x + 8, 0, x + 11, 4], fill=ink)
    d.polygon([(x + 8, 4), (x + 11, 4), (x + 14, 8), (x + 14, 15), (x + 5, 15), (x + 5, 8)], fill=ink)
    d.rectangle([x + 6, 9, x + 13, 11], fill=1 - ink)


def i_radio(d, x, ink):
    d.rectangle([x + 9, 6, x + 10, 15], fill=ink)
    d.ellipse([x + 8, 4, x + 11, 7], fill=ink)
    for r in (4, 7):
        d.arc([x + 10 - r, 5 - r, x + 10 + r, 5 + r], 200, 340, fill=ink)
        d.arc([x + 10 - r, 5 - r, x + 10 + r, 5 + r], 20, 160, fill=ink)


def i_diamond(d, x, ink):
    d.polygon([(x + 10, 0), (x + 19, 8), (x + 10, 15), (x + 1, 8)], fill=ink)
    d.polygon([(x + 10, 4), (x + 14, 8), (x + 10, 11), (x + 6, 8)], fill=1 - ink)


def i_fork(d, x, ink):
    for k in (2, 5, 8):
        d.line([x + k, 0, x + k, 5], fill=ink)
    d.rectangle([x + 2, 5, x + 8, 7], fill=ink)
    d.rectangle([x + 4, 7, x + 6, 15], fill=ink)
    d.ellipse([x + 11, 0, x + 17, 8], fill=ink)
    d.rectangle([x + 13, 8, x + 15, 15], fill=ink)


ICONS = [  # (pattern in the brand name, icon)
    ("hot_dog", i_hotdog), ("volta|power|zap_?|bolt", i_bolt), ("bets|bobby|1_900|grays", i_dice),
    ("bingo", i_bingo), ("sheriff", i_badge), ("raccoon|bait", i_raccoon), ("y2k|comet", i_comet),
    ("pray|confess|amos|votive|no_sunday|repent|sanctuary", i_cross), ("harbor|wharf|ferry|port", i_anchor),
    ("auto|muffler|motor_inn", i_wheel), ("modem|dialup|beeper|sportswire", i_modem), ("pie", i_pie),
    ("stockyard|rodeo", i_steer), ("feed|seed|cold_spring", i_wheat), ("money|trust|bank|haldane", i_dollar),
    ("steel|iron|furnace", i_girder), ("inn", i_moon), ("cola", i_bottle), ("98|fm", i_radio),
    ("joe|club|eat", i_fork), ("field|yard|commons|grounds|park", i_diamond),
]
ICON_ORDER = [i_star, i_comet, i_diamond, i_bolt]


def icon_for(name):
    for pat, fn in ICONS:
        if re.search(pat, name):
            return fn
    return ICON_ORDER[sum(map(ord, name)) % len(ICON_ORDER)]


def letters(name):
    words = [w for w in name.split("_") if w and w not in ("s", "the", "at", "by")]
    nums = [w for w in words if w.isdigit()]
    if nums and len(nums[0]) <= 3:
        return nums[0]
    ini = "".join(w[0] for w in words).upper()
    if len(words) == 1:
        ini = words[0][:3].upper()
    return ini[:3]


def pattern(d, x0, x1, kind, ink):
    if kind == 0:     # chevrons
        for x in range(x0, x1, 8):
            d.line([x, 2, x + 5, 8, x, 14], fill=ink, width=2)
    elif kind == 1:   # checker band
        for x in range(x0, x1, 4):
            for y in range(2, 14, 4):
                if ((x // 4) + (y // 4)) % 2 == 0:
                    d.rectangle([x, y, x + 3, y + 3], fill=ink)
    elif kind == 2:   # diagonal stripes
        for x in range(x0 - 16, x1, 6):
            d.line([x, 15, x + 15, 0], fill=ink, width=2)
    else:             # dots
        for x in range(x0 + 1, x1 - 1, 5):
            d.ellipse([x, 6, x + 3, 9], fill=ink)


def board(name, idx):
    inv = idx % 2 == 1
    bg, ink = (0, 1) if inv else (1, 0)
    img = Image.new("1", (W, H), bg)
    d = ImageDraw.Draw(img)
    d.rectangle([0, 0, W - 1, H - 1], outline=ink)
    fn = icon_for(name)
    lt = letters(name)
    # layout: icon | wordmark | pattern band | icon (mirrored repeat on the long boards)
    fn(d, 4, ink)
    x = word(d, 28, 3, lt, ink) + 4
    band = Image.new("1", (W, H), bg)
    pattern(ImageDraw.Draw(band), x, W - 26, idx % 4, ink)
    img.paste(band.crop((x, 1, W - 27, H - 1)), (x, 1))
    fn(d, W - 24, ink)
    return img


def build(preview_only=False):
    files = sorted(glob.glob(os.path.join(TEX, "ad_*.png")))
    imgs = []
    for i, f in enumerate(files):
        name = os.path.basename(f)[3:-4]
        img = board(name, i)
        imgs.append((name, img))
        if not preview_only:
            img.save(f)
    sheet = Image.new("L", (2 * (W * 2 + 8), ((len(imgs) + 1) // 2) * (H * 2 + 12)), 200)
    d = ImageDraw.Draw(sheet)
    for i, (name, img) in enumerate(imgs):
        x, y = (i % 2) * (W * 2 + 8), (i // 2) * (H * 2 + 12)
        sheet.paste(img.convert("L").resize((W * 2, H * 2), Image.NEAREST), (x, y + 10))
        d.text((x, y), name, fill=0)
    os.makedirs(os.path.dirname(PREVIEW), exist_ok=True)
    sheet.save(PREVIEW)
    print("adboards:", len(imgs), "boards", "(preview only)" if preview_only else "written", "->", PREVIEW)


if __name__ == "__main__":
    build(preview_only="--preview" in sys.argv)
