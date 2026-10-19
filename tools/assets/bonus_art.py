"""Art for Bobby's Loyalty Club (playdate/source/sites/bonus.lua): the punched-star holes and the
target rings, the hole-punch pliers (keyframes), the chad, the CHNK! burst and the inked rubber
stamps (FULL CARD! FREE PACK, PAID) in pre-scaled slam steps. All original, drawn here.

Everything is prerendered 1-bit with transparency (LA PNG); nothing rotates or dithers at runtime.
Shapes are drawn 4x supersampled and thresholded, so rotated edges stay clean.

Run: python3 tools/assets/bonus_art.py   (writes playdate/source/images/ui/bonus/, preview in
tools/assets/preview/bonus_art.png)
"""
import os, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

import common
from common import IMAGES, PREVIEW, ensure_dir, save_masked, font

OUT = os.path.join(IMAGES, "ui", "bonus")
S = 4  # supersample
RNG = np.random.default_rng(1996)


def down(a, thr=0.5):
    """float array at S x (1 = set) -> bool array at 1x."""
    h, w = a.shape
    img = Image.fromarray((np.clip(a, 0, 1) * 255).astype(np.uint8), "L")
    img = img.resize((w // S, h // S), Image.BOX)
    return np.asarray(img, np.float32) / 255.0 > thr


def save(ink, mask, name):
    """ink, mask: bool arrays (ink True = black). Writes OUT/name.png."""
    ensure_dir(OUT)
    inkL = Image.fromarray(np.where(ink, 0, 255).astype(np.uint8), "L")
    maskL = Image.fromarray(np.where(mask | ink, 255, 0).astype(np.uint8), "L")
    save_masked(inkL, maskL, os.path.join(OUT, name + ".png"))
    return inkL, maskL


def dilate(b, r=1):
    out = b.copy()
    for dy in range(-r, r + 1):
        for dx in range(-r, r + 1):
            if dx * dx + dy * dy <= r * r + r:
                out |= np.roll(np.roll(b, dy, 0), dx, 1)
    return out


# ------------------------------------------------------------------ holes: a five-point star die

def star_pts(cx, cy, R, k=0.42, n=5, rot=-90):
    pts = []
    for i in range(n * 2):
        r = R if i % 2 == 0 else R * k
        a = math.radians(rot + i * 180 / n)
        pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def holes(R):
    c = R + 3
    size = 2 * c + 1
    # the hole itself, rasterized at 1x like the Lua side fills it (playdate fillPolygon)
    im = Image.new("L", (size, size), 0)
    ImageDraw.Draw(im).polygon(star_pts(c, c, R), fill=255)
    hole = np.asarray(im) > 0
    # rim: a 1 px black edge round the cut, plus the card's thickness: a 1 px shadow band inside
    # along the top and left edges (light from the top left, the cut wall in shadow)
    outline = dilate(hole, 1) & ~hole
    shifted = np.zeros_like(hole)
    shifted[1:, 1:] = hole[:-1, :-1]
    band = hole & ~shifted
    save(outline | band, outline | band, f"hole-rim-{R}")
    # rings for the holes still to punch: a dashed target ring (r = R + 2) with tick marks
    for kind in ("ring", "ring-next", "ring-pack"):
        a = np.zeros((size * S, size * S), np.float32)
        img = Image.fromarray(a)
        d = ImageDraw.Draw(img)
        rr = (R + 2) * S
        C = c * S + S // 2
        n = 16 if kind != "ring-next" else 12
        wid = S if kind != "ring-next" else 2 * S
        for i in range(0, n * 2, 2):
            a0, a1 = i * 360 / (n * 2), (i + 1) * 360 / (n * 2)
            d.arc((C - rr, C - rr, C + rr, C + rr), a0, a1, fill=1.0, width=wid)
        if kind == "ring-next":
            # the crosshair: Bobby's aiming here
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                d.line((C + dx * (rr - 4 * S), C + dy * (rr - 4 * S), C + dx * (rr + 2 * S), C + dy * (rr + 2 * S)), fill=1.0, width=S)
            d.ellipse((C - S, C - S, C + S, C + S), fill=1.0)
        if kind == "ring-pack":
            d.polygon([(x * S + S // 2, y * S + S // 2) for x, y in star_pts(c, c, R * 0.62)], outline=1.0)
            # (outline at S x is 1 px wide; thicken)
            pk = Image.new("L", (size * S, size * S), 0)
            ImageDraw.Draw(pk).polygon([(x * S + S // 2, y * S + S // 2) for x, y in star_pts(c, c, R * 0.62)], fill=255)
            pa = np.asarray(pk) > 0
            edge = dilate(pa, S // 2 + 1) & ~pa
            img = Image.fromarray(np.maximum(np.asarray(img), edge.astype(np.float32)))
        ink = down(np.asarray(img), 0.35)
        save(ink, ink, f"{kind}-{R}")
    return hole


# ------------------------------------------------------------------ the hole-punch pliers

PW = 240           # work canvas (the punch point sits at the center); saved cropped
PSCALE = 1.2
PC = PW // 2


class Layer:
    """Draw in 1x coordinates (floats) onto S x black/white/mask layers, with a transform."""

    def __init__(self, tf):
        self.ink = Image.new("L", (PW * S, PW * S), 0)    # 255 = black ink
        self.mask = Image.new("L", (PW * S, PW * S), 0)   # 255 = opaque
        self.di, self.dm = ImageDraw.Draw(self.ink), ImageDraw.Draw(self.mask)
        self.tf = tf

    def P(self, pts):
        return [((PC + x) * S, (PC + y) * S) for x, y in (self.tf(p) for p in pts)]

    def poly(self, pts, black):
        q = self.P(pts)
        self.dm.polygon(q, fill=255)
        self.di.polygon(q, fill=255 if black else 0)

    def result(self):
        ink = down(np.asarray(self.ink, np.float32) / 255.0)
        mask = down(np.asarray(self.mask, np.float32) / 255.0, 0.45)
        return ink & mask, mask


def circle(cx, cy, r, n=28):
    return [(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


def bar(p0, p1, w0, w1=None):
    w1 = w0 if w1 is None else w1
    dx, dy = p1[0] - p0[0], p1[1] - p0[1]
    L = math.hypot(dx, dy) or 1
    nx, ny = -dy / L, dx / L
    return [(p0[0] + nx * w0 / 2, p0[1] + ny * w0 / 2), (p1[0] + nx * w1 / 2, p1[1] + ny * w1 / 2),
            (p1[0] - nx * w1 / 2, p1[1] - ny * w1 / 2), (p0[0] - nx * w0 / 2, p0[1] - ny * w0 / 2)]


def rrect(x0, y0, x1, y1, r, n=6):
    pts = []
    for cx, cy, a0 in ((x1 - r, y0 + r, -90), (x1 - r, y1 - r, 0), (x0 + r, y1 - r, 90), (x0 + r, y0 + r, 180)):
        for i in range(n + 1):
            a = math.radians(a0 + 90 * i / n)
            pts.append((cx + r * math.cos(a), cy + r * math.sin(a)))
    return pts


def pliers(lift=0.0, spread=13.0, rot=0.0, squash=1.0, shadow=True):
    """The punch over the hole at (0, 0). lift: the head above the card; spread: handle angle (deg);
    rot: the whole tool swung around the punch point (deg, + = clockwise); squash: y scale at the slam."""
    ca, sa = math.cos(math.radians(rot)), math.sin(math.radians(rot))

    def tf(p):
        x, y = p[0] * PSCALE, p[1] * PSCALE
        y *= squash
        return (x * ca - y * sa, x * sa + y * ca)

    Lr = Layer(tf)
    ax = math.radians(-48)                      # the tool's axis, up and to the right
    ux, uy = math.cos(ax), math.sin(ax)
    piv = (30 * ux, 30 * uy - 4)
    # a soft shadow on the card while it hovers (50% dither, black dots only)
    if shadow and lift > 1:
        sh = Image.new("L", (PW * S, PW * S), 0)
        ImageDraw.Draw(sh).ellipse([((PC + 3 - 12) * S), ((PC + 2 - 4) * S), ((PC + 3 + 12) * S), ((PC + 2 + 4) * S)], fill=255)
        shb = down(np.asarray(sh, np.float32) / 255.0)
        yy, xx = np.mgrid[0:PW, 0:PW]
        shadow_dots = shb & (((xx + yy) % 2) == 0)
    else:
        shadow_dots = None
    # lower jaw: the anvil plate under the card's edge and its arm to the pivot
    Lr.poly(bar((-8, 6), (8, 6), 6), True)
    Lr.poly(bar((6, 6), piv, 7, 9), True)
    Lr.poly(bar((6, 6), piv, 3, 5), False)
    # the two handles from the pivot (rubber grips, ridged)
    for sgn in (1, -1):
        a = ax + math.radians(sgn * spread)
        tip = (piv[0] + 64 * math.cos(a), piv[1] + 64 * math.sin(a))
        Lr.poly(bar(piv, tip, 10, 8), True)
        mid = (piv[0] + 20 * math.cos(a), piv[1] + 20 * math.sin(a))
        Lr.poly(bar(mid, tip, 4, 3), True)
        # grip ridges and a highlight
        for k in range(5):
            t = 30 + k * 7
            c = (piv[0] + t * math.cos(a), piv[1] + t * math.sin(a))
            nx, ny = -math.sin(a), math.cos(a)
            Lr.poly(bar((c[0] - nx * 4, c[1] - ny * 4), (c[0] + nx * 4, c[1] + ny * 4), 1.2), False)
        h0 = (piv[0] + 26 * math.cos(a) - sgn * 2 * math.sin(a), piv[1] + 26 * math.sin(a) + sgn * 2 * math.cos(a))
        h1 = (piv[0] + 60 * math.cos(a) - sgn * 2 * math.sin(a), piv[1] + 60 * math.sin(a) + sgn * 2 * math.cos(a))
        Lr.poly(bar(h0, h1, 1.0), False)
        # end cap
        Lr.poly(circle(tip[0], tip[1], 5), True)
    # the spring between the handles (a zigzag)
    zz = []
    for k in range(7):
        t = 10 + k * 3.2
        s = (1 if k % 2 else -1) * (2 + t * math.tan(math.radians(spread)) * 0.9)
        zz.append((piv[0] + t * ux - s * uy, piv[1] + t * uy + s * ux))
    for p0, p1 in zip(zz, zz[1:]):
        Lr.poly(bar(p0, p1, 1.6), True)
    # upper jaw: arm from the pivot to the head (it rides up with the lift)
    head_y = -5 - lift
    Lr.poly(bar((8, head_y + 2), piv, 10, 11), True)
    Lr.poly(bar((8, head_y + 2), piv, 6, 7), False)
    # the head: the die housing, white with a black outline and a chrome stripe
    Lr.poly(rrect(-12, head_y - 7, 12, head_y + 7, 4), True)
    Lr.poly(rrect(-10, head_y - 5, 10, head_y + 5, 3), False)
    Lr.poly(bar((-7, head_y - 2), (7, head_y - 2), 1.3), True)
    # the punch (die) under the head, a star stamped on it
    Lr.poly(rrect(-7, head_y + 6, 7, head_y + 10 + lift * 0.0, 1.5), True)
    Lr.poly(star_pts(0, head_y + 8, 2.2), False)
    # the pivot rivet
    Lr.poly(circle(piv[0], piv[1], 6.5), True)
    Lr.poly(circle(piv[0], piv[1], 2.2), False)
    ink, mask = Lr.result()
    if shadow_dots is not None:
        ink = ink | (shadow_dots & ~mask)
        mask = mask | shadow_dots
    return ink, mask


# ------------------------------------------------------------------ chad, the burst

def chad(R=6):
    frames = []
    for i, sx in enumerate((1.0, 0.55, 0.15, 0.55)):
        size = 2 * R + 3
        c = size // 2
        im = Image.new("L", (size * S, size * S), 0)
        pts = [((c + (x - c) * sx) * S + S // 2, y * S + S // 2) for x, y in star_pts(c, c, R, rot=-90 + i * 17)]
        ImageDraw.Draw(im).polygon(pts, fill=255)
        shape = down(np.asarray(im, np.float32) / 255.0, 0.4)
        edge = shape & ~(np.roll(shape, 1, 0) & np.roll(shape, -1, 0) & np.roll(shape, 1, 1) & np.roll(shape, -1, 1))
        yy, xx = np.mgrid[0:size, 0:size]
        back = shape & ((xx + yy) % 2 == 0) if i == 3 else np.zeros_like(shape)   # the back side: gray
        save(edge | back, shape, f"chad-{i + 1}")


def text_mask(s, key="ui", sx=1, sy=1, thick=0, tracking=1):
    f = font(key)
    w = f.width(s) + 2 + len(s) * tracking
    im = Image.new("L", (w + 2, f.height + 2), 255)
    x = 1
    for ch in s:
        f.draw(im, (x, 1), ch, 0)
        x += f.width(ch) + f.tracking + tracking
    m = np.asarray(im) < 128
    for _ in range(thick):
        m = m | np.roll(m, 1, 1)
    img = Image.fromarray(m.astype(np.uint8) * 255).resize((int(m.shape[1] * sx), int(m.shape[0] * sy)), Image.NEAREST)
    return np.asarray(img) > 0


def burst():
    """CHNK!: a white starburst with a heavy black edge and black lettering (reads on 1-bit)."""
    w, h = 88, 56
    cx, cy = w / 2, h / 2
    for k, scale in enumerate((0.7, 1.0)):
        im = Image.new("L", (w * S, h * S), 0)
        d = ImageDraw.Draw(im)
        pts, n = [], 14
        for i in range(n * 2):
            r = (1.0 if i % 2 == 0 else 0.62) * (1 + 0.14 * math.sin(i * 2.3))
            a = 2 * math.pi * i / (n * 2)
            pts.append(((cx + r * (w / 2 - 3) * scale * math.cos(a)) * S, (cy + r * (h / 2 - 3) * scale * math.sin(a)) * S))
        d.polygon(pts, fill=255)
        shape = down(np.asarray(im, np.float32) / 255.0)
        edge = dilate(shape, 2) & ~dilate(~shape, 0) if False else (dilate(shape, 2) & ~shape)
        inner = shape & ~(dilate(~shape, 1))
        txt = text_mask("CHNK!", "oklahoma", 1, 1, thick=0, tracking=2)
        if scale < 1:
            pass
        else:
            txt = np.asarray(Image.fromarray(txt.astype(np.uint8) * 255).resize((int(txt.shape[1] * 1.0), int(txt.shape[0] * 1.4)), Image.NEAREST)) > 0
        th, tw = txt.shape
        letters = np.zeros_like(shape)
        oy, ox = int(cy - th / 2), int(cx - tw / 2)
        letters[oy:oy + th, ox:ox + tw] = txt
        ink = edge | (shape & ~inner) | (letters & shape)
        save(ink, shape | edge, f"chnk-{k + 1}")


# ------------------------------------------------------------------ the rubber stamp

STEPS = (1.6, 1.3, 1.1, 1.0)


def smooth_noise(h, w, cell, rng):
    g = rng.random((h // cell + 3, w // cell + 3)).astype(np.float32)
    img = Image.fromarray((g * 255).astype(np.uint8)).resize(((w // cell + 3) * cell, (h // cell + 3) * cell), Image.BICUBIC)
    return np.asarray(img, np.float32)[:h, :w] / 255.0


def stamp(name, lines, sx, sy, angle, seed, key="oklahoma", pad=(11, 9), thick=1, bias=0.25):
    """An inked rubber stamp: double border, heavy condensed caps, distressed ink, rotated (baked)."""
    rng = np.random.default_rng(seed)
    rows = [text_mask(l, key, 1, 1, thick=thick, tracking=2) for l in lines]
    # condensed and tall: each glyph pixel becomes sx by sy (1x units), smoothed at S x below
    rs = [np.asarray(Image.fromarray(r.astype(np.uint8) * 255).resize((int(r.shape[1] * sx * S), int(r.shape[0] * sy * S)), Image.NEAREST), np.float32) / 255.0 for r in rows]
    gap = 3 * S
    tw = max(r.shape[1] for r in rs)
    th = sum(r.shape[0] for r in rs) + gap * (len(rs) - 1)
    pad_x, pad_y = pad[0] * S, pad[1] * S
    Ws, Hs0 = tw + 2 * pad_x, th + 2 * pad_y
    Ws -= Ws % S
    Hs0 -= Hs0 % S
    a = np.zeros((Hs0, Ws), np.float32)
    y = pad_y
    for r in rs:
        x = (Ws - r.shape[1]) // 2
        a[y:y + r.shape[0], x:x + r.shape[1]] = np.maximum(a[y:y + r.shape[0], x:x + r.shape[1]], r)
        y += r.shape[0] + gap
    # rubber rounds the pixel stairs
    a = np.asarray(Image.fromarray((a * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(S * 0.7)), np.float32) / 255.0
    a = np.clip((a - bias) * 3 + 0.5, 0, 1)   # (biased: fattens the strokes)
    letters = a.copy()                         # legibility first: the wear stays off the letters
    W, H = Ws // S, Hs0 // S
    im = Image.new("L", (Ws, Hs0), 0)
    d = ImageDraw.Draw(im)
    d.rounded_rectangle((1 * S, 1 * S, (W - 2) * S, (H - 2) * S), radius=5 * S, outline=255, width=int(3.0 * S))
    d.rounded_rectangle((int(5.5 * S), int(5.5 * S), int((W - 6.5) * S), int((H - 6.5) * S)), radius=3 * S, outline=255, width=int(1.4 * S))
    a = np.maximum(a, np.asarray(im, np.float32) / 255.0)
    P = 8 * S
    a = np.pad(a, P)
    letters = np.pad(letters, P)
    # 1 on and right around the strokes, 0 on the border and in the open
    guard = np.asarray(Image.fromarray((letters * 255).astype(np.uint8)).filter(ImageFilter.MaxFilter(2 * S + 1)).filter(ImageFilter.GaussianBlur(S)), np.float32) / 255.0
    wear = 1.0 - 0.9 * guard
    Hs, Ws = a.shape
    # ink: uneven pressure (low-frequency), worn pits, a little splatter near the ink
    press = smooth_noise(Hs, Ws, 11 * S, rng) * 0.6 + smooth_noise(Hs, Ws, 4 * S, rng) * 0.4
    pim = Image.new("F", (Ws, Hs), 0)
    pd = ImageDraw.Draw(pim)
    for _ in range(int(Hs * Ws / (S * S) * 0.02)):
        px, py = rng.integers(0, Ws), rng.integers(0, Hs)
        r = rng.uniform(0.45, 0.9) * S
        pd.ellipse((px - r, py - r, px + r, py + r), fill=1.0)
    pits = np.asarray(pim)
    sim = Image.new("F", (Ws, Hs), 0)
    sd = ImageDraw.Draw(sim)
    for _ in range(int(Hs * Ws / (S * S) * 0.004)):
        px, py = int(rng.integers(0, Ws)), int(rng.integers(0, Hs))
        if a[py, px] > 0.1 or a[max(0, py - 3 * S):py + 3 * S, max(0, px - 3 * S):px + 3 * S].max() < 0.5:
            continue
        r = rng.uniform(0.6, 1.0) * S
        sd.ellipse((px - r, py - r, px + r, py + r), fill=1.0)
    strays = np.asarray(sim)
    # pressure and pits work on the border and edges; the letters print solid
    inked = np.clip(np.maximum(a * (0.8 + 0.4 * press) * wear + a * guard, letters) - pits * wear + strays, 0, 1)
    img = Image.fromarray((inked * 255).astype(np.uint8)).rotate(angle, resample=Image.BICUBIC, expand=True)
    gimg = Image.fromarray((guard * 255).astype(np.uint8)).rotate(angle, resample=Image.BILINEAR, expand=True)
    base_w, base_h = img.size[0] // S, img.size[1] // S
    thr_field = smooth_noise(img.size[1], img.size[0], 6 * S, rng)
    out = []
    for i, sc in enumerate(STEPS):
        w, h = max(8, int(base_w * sc)), max(8, int(base_h * sc))
        small = np.asarray(img.resize((w, h), Image.BOX), np.float32) / 255.0
        thr = np.asarray(Image.fromarray((thr_field * 255).astype(np.uint8)).resize((w, h), Image.BILINEAR), np.float32) / 255.0
        g = np.asarray(gimg.resize((w, h), Image.BILINEAR), np.float32) / 255.0
        ink = small > (0.42 + 0.14 * thr * (1 - g) - 0.04 * g)
        halo = dilate(ink, 1)
        ys, xs = np.nonzero(halo)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        out.append(save(ink[y0:y1, x0:x1], halo[y0:y1, x0:x1], f"{name}-{i + 1}"))
    return out


def preview(items):
    cols = 6
    cw = max(i.width for i, _ in items) + 8
    ch = max(i.height for i, _ in items) + 8
    rows = (len(items) + cols - 1) // cols
    sheet = Image.new("L", (cols * cw, rows * ch), 160)
    for k, (ink, mask) in enumerate(items):
        x, y = (k % cols) * cw + 4, (k // cols) * ch + 4
        sheet.paste(ink, (x, y), mask)
    ensure_dir(PREVIEW)
    sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST)
    sheet.save(os.path.join(PREVIEW, "bonus_art.png"))


def build():
    items = []
    for R in (11, 7):
        holes(R)
    # pliers keyframes (untweened): swing in far, swing in near, hover, SLAM (squashed, closed), recoil
    frames = [
        ("punch-1", dict(lift=8, spread=15, rot=38)),
        ("punch-2", dict(lift=6, spread=14, rot=14)),
        ("punch-3", dict(lift=6, spread=13, rot=0)),
        ("punch-4", dict(lift=0, spread=4, rot=0, squash=0.86, shadow=False)),
        ("punch-5", dict(lift=3, spread=10, rot=-4)),
    ]
    anchors = []
    for name, kw in frames:
        ink, mask = pliers(**kw)
        ys, xs = np.nonzero(mask)
        y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
        items.append(save(ink[y0:y1, x0:x1], mask[y0:y1, x0:x1], name))
        anchors.append((PC - x0, PC - y0))
    # where the punch point sits in each cropped frame (draw at hole - anchor)
    with open(os.path.join(common.SRC, "sites", "bonus_art.lua"), "w") as f:
        f.write("-- generated by tools/assets/bonus_art.py: punch-N.png anchor (the punch point) per frame\n")
        f.write("BonusArt = { punch = { " + ", ".join(f"{{ {x}, {y} }}" for x, y in anchors) + " } }\n")
    chad()
    burst()
    items += stamp("stamp-pack", ["FULL CARD!", "FREE PACK"], 1.4, 2.2, 8, 7)
    items += stamp("stamp-paid", ["PAID"], 1.25, 1.45, 5, 11, pad=(6, 4), thick=0, bias=0.4)
    items += stamp("stamp-new", ["NEW CARD"], 1.35, 2.1, 7, 5)
    preview(items)
    print("wrote", OUT)


if __name__ == "__main__":
    build()
