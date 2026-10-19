"""Shared helpers for the DEADBALL asset pipeline (1-bit Playdate output).

Conventions
- Work in PIL mode "L" (0 = black ink, 255 = white paper). Opaque outputs are saved as
  1-bit PNG; sprites with transparency are saved as "LA" (alpha 0 = transparent).
- Matrix imagetables follow the Playdate naming rule `<name>-table-<w>-<h>.png`, frames laid
  out row-major left->right, top->bottom; Lua: imagetable:getImage(n) with n 1-based.
"""
import os, re, glob, json, math
import numpy as np
from PIL import Image, ImageDraw, ImageOps, ImageEnhance

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
CACHE = os.path.join(HERE, ".cache")
PREVIEW = os.path.join(HERE, "preview")
README_PARTS = os.path.join(HERE, "readme")
SRC = os.path.join(ROOT, "playdate", "source")
IMAGES = os.path.join(SRC, "images")
FONTS_OUT = os.path.join(SRC, "fonts")
SDK = os.path.expanduser(os.environ.get("PLAYDATE_SDK_PATH", "~/Developer/PlaydateSDK"))
SDK_FONTS = os.path.join(SDK, "Resources", "Fonts")

BLACK, WHITE = 0, 255


def ensure_dir(p):
    os.makedirs(p, exist_ok=True)
    return p


# ---------------------------------------------------------------- dithering

BAYER8 = (np.array([
    [0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26],
    [12, 44, 4, 36, 14, 46, 6, 38], [60, 28, 52, 20, 62, 30, 54, 22],
    [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
    [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21]]) + 0.5) / 64.0

BAYER4 = (np.array([[0, 8, 2, 10], [12, 4, 14, 6], [3, 11, 1, 9], [15, 7, 13, 5]]) + 0.5) / 16.0


def bayer(a, matrix=BAYER8, ox=0, oy=0):
    """a: float array 0..1 (1 = white). Returns uint8 0/255 array. ox/oy shift the matrix
    phase (use screen coordinates so tiles line up)."""
    h, w = a.shape
    m = matrix.shape[0]
    thr = np.tile(matrix, (h // m + 2, w // m + 2))
    thr = thr[oy % m: oy % m + h, ox % m: ox % m + w]
    return np.where(a > thr, 255, 0).astype(np.uint8)


def atkinson(img, serpentine=False):
    """Atkinson error diffusion. img: PIL L. Returns PIL L with 0/255."""
    a = np.asarray(img, dtype=np.float32).copy()
    h, w = a.shape
    pad = np.zeros((h + 2, w + 4), np.float32)
    pad[:h, 2:w + 2] = a
    for y in range(h):
        row = pad[y]
        nxt = pad[y + 1]
        nn = pad[y + 2]
        for x in range(2, w + 2):
            old = row[x]
            new = 255.0 if old >= 128 else 0.0
            row[x] = new
            e = (old - new) * 0.125
            if e:
                row[x + 1] += e; row[x + 2] += e
                nxt[x - 1] += e; nxt[x] += e; nxt[x + 1] += e
                nn[x] += e
    out = pad[:h, 2:w + 2]
    return Image.fromarray(np.where(out >= 128, 255, 0).astype(np.uint8), "L")


def threshold(img, t=128):
    return img.point(lambda v: 255 if v >= t else 0)


# ---------------------------------------------------------------- saving

def save_1bit(img, path):
    """Opaque 1-bit PNG."""
    ensure_dir(os.path.dirname(path))
    img.convert("L").point(lambda v: 255 if v >= 128 else 0).convert("1").save(path, optimize=True)


def save_masked(ink, mask, path):
    """ink: L (0/255), mask: L (255 = opaque). Saved as LA so pdc keeps transparency."""
    ensure_dir(os.path.dirname(path))
    ink = ink.convert("L").point(lambda v: 255 if v >= 128 else 0)
    mask = mask.convert("L").point(lambda v: 255 if v >= 128 else 0)
    Image.merge("LA", (ink, mask)).save(path, optimize=True)


def save_table(frames, out_dir, name, cols=None, masks=None):
    """Write a Playdate matrix imagetable `<name>-table-<w>-<h>.png`.
    frames: list of PIL L images (all same size). masks: optional list of L masks.
    Returns the file path. Frame n (1-based) is at row (n-1)//cols, col (n-1)%cols."""
    w, h = frames[0].size
    for f in frames:
        assert f.size == (w, h), (name, f.size, (w, h))
    n = len(frames)
    cols = cols or n
    rows = (n + cols - 1) // cols
    sheet = Image.new("L", (cols * w, rows * h), 255)
    msheet = Image.new("L", (cols * w, rows * h), 0)
    for i, f in enumerate(frames):
        x, y = (i % cols) * w, (i // cols) * h
        sheet.paste(f, (x, y))
        msheet.paste(masks[i] if masks else Image.new("L", (w, h), 255), (x, y))
    # remove stale tables with other dims
    for old in glob.glob(os.path.join(out_dir, glob.escape(name) + "-table-*.png")):
        os.remove(old)
    path = os.path.join(out_dir, f"{name}-table-{w}-{h}.png")
    if masks:
        save_masked(sheet, msheet, path)
    else:
        save_1bit(sheet, path)
    return path


def flatten_preview(ink, mask, bg=None):
    """Composite a masked sprite onto a checker/gray bg for previews."""
    w, h = ink.size
    if bg is None:
        bg = Image.new("L", (w, h), 200)
    out = bg.copy()
    out.paste(ink, (0, 0), mask)
    return out


# ---------------------------------------------------------------- fonts (Playdate .fnt)

class PDFont:
    """Minimal Playdate .fnt (dependent table) loader + 1-bit renderer."""

    def __init__(self, fnt_path):
        base = fnt_path[:-4]
        table = glob.glob(glob.escape(base) + "-table-*-*.png")[0]
        cw, ch = map(int, re.search(r"-table-(\d+)-(\d+)\.png$", table).groups())
        self.cw, self.ch, self.height = cw, ch, ch
        img = Image.open(table).convert("RGBA")
        self.tracking, self.widths, self.kern, order = 0, {}, {}, []
        for line in open(fnt_path, encoding="utf-8"):
            line = line.rstrip("\n")
            if not line or line.startswith("--"):
                continue
            if line.startswith("tracking="):
                self.tracking = int(line.split("=")[1]); continue
            parts = re.split(r"\t+|\s{2,}| (?=-?\d+$)", line)
            if len(parts) < 2:
                continue
            key, m = parts[0], re.match(r"-?\d+", parts[1].strip())
            if not m:
                continue
            val = m.group(0)
            if key == "space":
                key = " "
            if key.startswith("U+") and len(key) > 2:
                try:
                    key = chr(int(key[2:], 16))
                except ValueError:
                    pass
            if len(key) == 1:
                self.widths[key] = int(val); order.append(key)
            elif len(key) == 2:
                self.kern[key] = int(val)
        cols = img.width // cw
        self.glyphs = {}
        for i, c in enumerate(order):
            x, y = (i % cols) * cw, (i // cols) * ch
            g = img.crop((x, y, x + cw, y + ch))
            a = np.asarray(g)
            self.glyphs[c] = (a[:, :, 3] > 127) & (a[:, :, 0] < 128)

    def width(self, s):
        w = 0
        for i, c in enumerate(s):
            w += self.widths.get(c, self.widths.get("?", 4)) + self.tracking
            if i + 1 < len(s):
                w += self.kern.get(s[i:i + 2], 0)
        return max(0, w - self.tracking)

    def draw(self, im, xy, s, color=0):
        """Draw onto PIL L image. color: 0 black ink, 255 white ink."""
        x, y = int(xy[0]), int(xy[1])
        px = im.load()
        for i, c in enumerate(s):
            g = self.glyphs.get(c)
            if g is None:
                g = self.glyphs.get("?")
            if g is not None:
                ys, xs = np.nonzero(g)
                for gy, gx in zip(ys, xs):
                    X, Y = x + gx, y + gy
                    if 0 <= X < im.width and 0 <= Y < im.height:
                        px[X, Y] = color
            x += self.widths.get(c, 4) + self.tracking
            if i + 1 < len(s):
                x += self.kern.get(s[i:i + 2], 0)
        return x

    def draw_center(self, im, cx, y, s, color=0):
        return self.draw(im, (cx - self.width(s) // 2, y), s, color)


_fonts = {}
FONT_FILES = {
    "ui": "Nontendo/Nontendo-Bold.fnt",
    "ui2x": "Nontendo/Nontendo-Bold-2x.fnt",
    "body": "Nontendo/Nontendo-Light.fnt",
    "tiny": "Bitmore/font-Bitmore.fnt",
    "medieval": "Bitmore/font-Bitmore-Medieval-Bold.fnt",
    "mono": "Roobert/Roobert-9-Mono-Condensed.fnt",
    "serif": "Newsleak Serif/Newsleak-Serif.fnt",
    "serifb": "Newsleak Serif/Newsleak-Serif-Bold.fnt",
    "slab": "Sasser Slab/Sasser-Slab.fnt",
    "slabb": "Sasser Slab/Sasser-Slab-Bold.fnt",
    "big": "Roobert/Roobert-11-Medium.fnt",
    "bold10": "Roobert/Roobert-10-Bold.fnt",
    "oklahoma": "Oklahoma/Oklahoma-Bold.fnt",
    "cuberick": "Cuberick/font-Cuberick-Bold.fnt",
    "pixieval": "Crooked Park/font-pixieval-large-black-bold.fnt",
}


def font(key):
    if key not in _fonts:
        _fonts[key] = PDFont(os.path.join(SDK_FONTS, FONT_FILES.get(key, key)))
    return _fonts[key]


# ---------------------------------------------------------------- previews

def contact_sheet(items, path, cols=8, cell=None, label_font="tiny", scale=1, bg=255, pad=4):
    """items: list of (PIL image, label). Writes an L PNG contact sheet (optionally scaled)."""
    if not items:
        return
    cw = cell[0] if cell else max(i.width for i, _ in items)
    chh = cell[1] if cell else max(i.height for i, _ in items)
    f = font(label_font)
    lh = f.height + 1 if any(l for _, l in items) else 0
    rows = (len(items) + cols - 1) // cols
    W = cols * (cw + pad) + pad
    H = rows * (chh + lh + pad) + pad
    sheet = Image.new("L", (W, H), bg)
    for i, (im, lab) in enumerate(items):
        x = pad + (i % cols) * (cw + pad)
        y = pad + (i // cols) * (chh + lh + pad)
        sheet.paste(im.convert("L"), (x, y))
        if lab:
            f.draw(sheet, (x, y + chh), str(lab)[: max(1, cw // 4)])
    if scale != 1:
        sheet = sheet.resize((W * scale, H * scale), Image.NEAREST)
    ensure_dir(os.path.dirname(path))
    sheet.save(path)
    return path


def write_readme_part(name, text):
    ensure_dir(README_PARTS)
    with open(os.path.join(README_PARTS, name), "w") as fh:
        fh.write(text.rstrip() + "\n")


def write_json(path, obj, indent=1):
    ensure_dir(os.path.dirname(path))
    with open(path, "w") as fh:
        json.dump(obj, fh, indent=indent)
        fh.write("\n")
