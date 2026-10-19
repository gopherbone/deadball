"""Small 1-bit pixel-art toolkit used by cards.py and ui_art.py.

A Canvas is an L image (0 black / 255 white) plus an L mask (255 opaque / 0 transparent).
"""
import numpy as np
from PIL import Image, ImageDraw

import common

B, W = 0, 255

PATTERNS = {
    # 1 = black at (y % h, x % w)
    "g12": np.array([[1, 0, 0, 0], [0, 0, 0, 0], [0, 0, 1, 0], [0, 0, 0, 0]]),
    "g25": np.array([[1, 0], [0, 0]]),
    "g25b": np.array([[1, 0, 0, 0], [0, 0, 1, 0], [0, 1, 0, 0], [0, 0, 0, 1]]),
    "g50": np.array([[1, 0], [0, 1]]),
    "g75": np.array([[0, 1], [1, 1]]),
    "g87": np.array([[0, 1, 1, 1], [1, 1, 1, 1], [1, 1, 0, 1], [1, 1, 1, 1]]),
    "hline": np.array([[1], [0]]),
    "vline": np.array([[1, 0]]),
    "diag": np.array([[1, 0, 0, 0], [0, 1, 0, 0], [0, 0, 1, 0], [0, 0, 0, 1]]),
    "adiag": np.array([[0, 0, 0, 1], [0, 0, 1, 0], [0, 1, 0, 0], [1, 0, 0, 0]]),
    "dots": np.array([[1, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0], [0, 0, 0, 0]]),
    "dots3": np.array([[1, 0, 0], [0, 0, 0], [0, 0, 0]]),
    "cross": np.array([[1, 0, 0, 0], [0, 1, 0, 1], [0, 0, 1, 0], [0, 1, 0, 1]]),
    "weave": np.array([[1, 1, 0, 0], [0, 1, 1, 0], [0, 0, 1, 1], [1, 0, 0, 1]]),
    "stripe4": np.array([[1, 1, 0, 0]] * 1),
    "dstripe": np.array([[1, 1, 0, 0, 0, 0], [0, 1, 1, 0, 0, 0], [0, 0, 1, 1, 0, 0], [0, 0, 0, 1, 1, 0], [0, 0, 0, 0, 1, 1], [1, 0, 0, 0, 0, 1]]),
}


def pat_array(kind, w, h, ox=0, oy=0):
    p = PATTERNS[kind]
    ph, pw = p.shape
    t = np.tile(p, (h // ph + 2, w // pw + 2))
    return t[oy % ph: oy % ph + h, ox % pw: ox % pw + w].astype(bool)


class Canvas:
    def __init__(self, w, h, fill=W, opaque=True):
        self.w, self.h = w, h
        self.im = Image.new("L", (w, h), fill)
        self.mask = Image.new("L", (w, h), 255 if opaque else 0)
        self.d = ImageDraw.Draw(self.im)
        self.dm = ImageDraw.Draw(self.mask)

    # --- shapes (also mark opaque in mask)
    def rect(self, box, fill=None, outline=None, width=1):
        self.d.rectangle(box, fill=fill, outline=outline, width=width)
        if fill is None:
            self.dm.rectangle(box, outline=255, width=width)
        else:
            self.dm.rectangle(box, fill=255)

    def poly(self, pts, fill=None, outline=None):
        self.d.polygon(pts, fill=fill, outline=outline)
        self.dm.polygon(pts, fill=255)

    def ellipse(self, box, fill=None, outline=None, width=1):
        self.d.ellipse(box, fill=fill, outline=outline, width=width)
        if fill is None:
            self.dm.ellipse(box, outline=255, width=width)
        else:
            self.dm.ellipse(box, fill=255)

    def line(self, pts, fill=B, width=1):
        self.d.line(pts, fill=fill, width=width)
        self.dm.line(pts, fill=255, width=width)

    def px(self, x, y, c=B):
        if 0 <= x < self.w and 0 <= y < self.h:
            self.im.putpixel((x, y), c)
            self.mask.putpixel((x, y), 255)

    def hline(self, x0, x1, y, c=B):
        self.line((x0, y, x1, y), c)

    def vline(self, x, y0, y1, c=B):
        self.line((x, y0, x, y1), c)

    def clear(self, box):
        """Make a region transparent (and white)."""
        self.d.rectangle(box, fill=W)
        self.dm.rectangle(box, fill=0)

    # --- patterns: fill pixels in region with pattern (black where pattern is 1, else white)
    def pattern(self, box, kind, region=None, invert=False, ox=0, oy=0):
        x0, y0, x1, y1 = box
        a = np.asarray(self.im).copy()
        m = np.asarray(self.mask).copy()
        p = pat_array(kind, self.w, self.h, ox, oy)
        if invert:
            p = ~p
        sel = np.zeros((self.h, self.w), bool)
        sel[max(0, y0):y1 + 1, max(0, x0):x1 + 1] = True
        if region is not None:
            sel &= region
        a[sel] = np.where(p[sel], B, W)
        m[sel] = 255
        self.im = Image.fromarray(a, "L"); self.mask = Image.fromarray(m, "L")
        self.d = ImageDraw.Draw(self.im); self.dm = ImageDraw.Draw(self.mask)

    def region_poly(self, pts):
        r = Image.new("L", (self.w, self.h), 0)
        ImageDraw.Draw(r).polygon(pts, fill=255)
        return np.asarray(r) > 0

    def region_ellipse(self, box):
        r = Image.new("L", (self.w, self.h), 0)
        ImageDraw.Draw(r).ellipse(box, fill=255)
        return np.asarray(r) > 0

    # --- text
    def text(self, xy, s, fk="body", color=B):
        f = common.font(fk)
        x = f.draw(self.im, xy, s, color)
        # text pixels are inside opaque areas by convention; mark bbox opaque if needed
        return x

    def ctext(self, cx, y, s, fk="body", color=B):
        f = common.font(fk)
        return self.text((cx - f.width(s) // 2, y), s, fk, color)

    def rtext(self, rx, y, s, fk="body", color=B):
        f = common.font(fk)
        return self.text((rx - f.width(s), y), s, fk, color)

    def sprite(self, rows, x, y, scale=1):
        """ASCII: '#' black, '.' or 'o' white, ' ' transparent/skip."""
        for j, row in enumerate(rows):
            for i, ch in enumerate(row):
                if ch == " ":
                    continue
                c = B if ch in "#X" else W
                for dy in range(scale):
                    for dx in range(scale):
                        self.px(x + i * scale + dx, y + j * scale + dy, c)

    def paste(self, other, xy):
        self.im.paste(other.im, xy, other.mask)
        self.mask.paste(255, (xy[0], xy[1], xy[0] + other.w, xy[1] + other.h), other.mask)

    def grit(self, box, density=0.01, seed=0, on_white=True, region=None, clusters=True):
        """Cheap-cardboard specks: isolated black flecks on white (and a few white flecks on black)."""
        rng = np.random.default_rng(seed)
        a = np.asarray(self.im).copy()
        x0, y0, x1, y1 = box
        sel = np.zeros_like(a, bool)
        sel[y0:y1 + 1, x0:x1 + 1] = True
        if region is not None:
            sel &= region
        r = rng.random(a.shape)
        white = (a == W) & sel
        black = (a == B) & sel
        # only flip pixels whose 4-neighbours are all the same colour (keeps line art crisp)
        same = np.ones_like(a, bool)
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            same &= np.roll(np.roll(a, dy, 0), dx, 1) == a
        flip_w = white & same & (r < density)
        flip_b = black & same & (r < density * 0.6) if on_white else black & same & (r < density)
        a[flip_w] = B
        a[flip_b] = W
        if clusters:
            # a few 2-pixel fibres
            r2 = rng.random(a.shape)
            fib = white & same & (r2 < density * 0.15)
            a[fib] = B
            a[np.roll(fib, 1, 1) & white] = B
        self.im = Image.fromarray(a, "L"); self.d = ImageDraw.Draw(self.im)

    def round_corners(self, r=3):
        """Transparent rounded corners (mask only)."""
        for (cx, cy, sx, sy) in ((0, 0, 1, 1), (self.w - 1, 0, -1, 1), (0, self.h - 1, 1, -1), (self.w - 1, self.h - 1, -1, -1)):
            for i in range(r):
                for j in range(r):
                    if (r - i - 0.5) ** 2 + (r - j - 0.5) ** 2 > r * r:
                        self.mask.putpixel((cx + sx * i, cy + sy * j), 0)
                        self.im.putpixel((cx + sx * i, cy + sy * j), W)

    def invert(self):
        self.im = self.im.point(lambda v: 255 - v)
        self.d = ImageDraw.Draw(self.im)
        return self

    def copy(self):
        c = Canvas(self.w, self.h)
        c.im = self.im.copy(); c.mask = self.mask.copy()
        c.d = ImageDraw.Draw(c.im); c.dm = ImageDraw.Draw(c.mask)
        return c

    def flat(self, bg=200):
        return common.flatten_preview(self.im, self.mask, Image.new("L", (self.w, self.h), bg))

    def outline_mask(self, color=W):
        """Add a 1px halo (in `color`) around the opaque area (for sprites over busy bg)."""
        m = np.asarray(self.mask) > 0
        dil = m.copy()
        for dy in (-1, 0, 1):
            for dx in (-1, 0, 1):
                sh = np.zeros_like(m)
                ys = slice(max(0, dy), self.h + min(0, dy)); yd = slice(max(0, -dy), self.h + min(0, -dy))
                xs = slice(max(0, dx), self.w + min(0, dx)); xd = slice(max(0, -dx), self.w + min(0, -dx))
                sh[yd, xd] = m[ys, xs]
                dil |= sh
        ring = dil & ~m
        a = np.asarray(self.im).copy(); a[ring] = color
        mm = np.asarray(self.mask).copy(); mm[ring] = 255
        self.im = Image.fromarray(a, "L"); self.mask = Image.fromarray(mm, "L")
        self.d = ImageDraw.Draw(self.im); self.dm = ImageDraw.Draw(self.mask)


def from_ascii(rows, black="#X", white=".o"):
    h, w = len(rows), max(len(r) for r in rows)
    c = Canvas(w, h, opaque=False)
    c.sprite(rows, 0, 0)
    return c


def save(c, path, masked=True):
    if masked:
        common.save_masked(c.im, c.mask, path)
    else:
        common.save_1bit(c.im, path)


def table(canvases, out_dir, name, cols=None, masked=True):
    return common.save_table([c.im for c in canvases], out_dir, name, cols=cols,
                             masks=[c.mask for c in canvases] if masked else None)
