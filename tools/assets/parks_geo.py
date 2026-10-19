"""Export ballpark 3D geometry for the live C BallCast renderer: images/parks/parks-geo.json
plus 1-bit textures in images/parks/tex/, and a verification preview rendered purely from the
JSON (tools/assets/preview/geo_<park>.png).

Called from parks.build(); standalone: python3 tools/assets/parks_geo.py
"""
import os, sys, math, json, re
import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
import parks as PK
from field3d import Camera, Renderer, Poly, W, H

OUT = os.path.join(common.IMAGES, "parks")
TEX = os.path.join(OUT, "tex")
S2 = math.sqrt(0.5)
BASE = PK.BASE

# ------------------------------------------------------------------ materials

PAT = {
    "lights": [0xFF, 0x99, 0x99, 0xFF, 0xFF, 0x99, 0x99, 0xFF],   # bytes: row 0..7, bit 7 = left pixel, 1 = white
    "net": [0x88, 0x55, 0x22, 0x55, 0x88, 0x55, 0x22, 0x55],
    "windows": [0xFF, 0xFF, 0xB5, 0xFF, 0xFF, 0xFF, 0xAD, 0xFF],
}

MATERIALS = [
    # name, gray (1 = white), outline, pattern
    ("ground_far", 0.8, False, None),
    ("grass_foul", 0.5, False, None),
    ("grass_a", 0.27, False, None),
    ("grass_b", 0.6, False, None),
    ("turf", 0.375, False, None),
    ("warning_track", 0.8, False, None),
    ("dirt", 0.875, False, None),
    ("mound", 0.875, False, None),
    ("chalk", 1.0, False, None),
    ("base", 1.0, True, None),
    ("plate", 1.0, False, None),
    ("rubber", 1.0, False, None),
    ("wall", 0.12, False, None),
    ("wall_wood", 0.3, False, None),
    ("wall_net", 0.72, False, "net"),
    ("stands_wall", 0.22, False, None),
    ("backstop", 0.16, False, None),
    ("dugout", 0.0, False, None),
    ("crowd", 0.6, False, None),          # per-polygon texture crowd_<style>; gray is the far fallback
    ("stands_back", 0.18, False, None),
    ("deck_facade", 0.9, False, None),
    ("deck_shadow", 0.1, False, None),
    ("ad_board", 0.95, True, None),        # textured ad_<n>
    ("marker", 0.12, False, None),         # textured dist_<n> (white numerals on the wall)
    ("scoreboard", 0.08, False, None),
    ("scoreboard_face", 0.08, False, None),  # textured sb_<park>
    ("steel", 0.25, False, None),
    ("light_bank", 0.9, False, "lights"),
    ("flag_dark", 0.1, False, None),
    ("flag_light", 0.95, False, None),
    ("lamp", 1.0, False, None),
    ("skyline", 0.82, False, "windows"),
    ("landmark", 0.72, False, None),
    ("landmark_dark", 0.5, False, None),
    ("ship", 0.2, False, None),
    ("smoke", 0.62, False, None),
    ("tree", 0.22, False, None),
    ("mountains", 0.66, False, None),
    ("mountains_near", 0.45, False, None),
    ("snow", 0.98, False, None),
    ("bolt", 0.98, True, None),
    ("treeline", 0.3, False, None),
]
MAT = {m[0]: i for i, m in enumerate(MATERIALS)}


def r1(v):
    return round(float(v), 1)


class Geo:
    def __init__(self):
        self.polys = []      # dict(m, l, v, t?, uv?)
        self.billboards = []  # dict(m, c, r)
        self.lines = []      # dict(a, b, c, w)
        self.tex = {}        # name -> PIL image

    def add(self, mat, pts, layer=10, tex=None, uv=None):
        pts = [tuple(map(float, p)) + ((0.0,) if len(p) == 2 else ()) for p in pts]
        if len(pts) < 3:
            return
        e = {"m": MAT[mat], "l": layer, "v": [[r1(c) for c in p] for p in pts]}
        if tex:
            e["t"] = tex
            e["uv"] = [[r1(a) for a in q] for q in uv]
        self.polys.append(e)

    def box(self, mat, cx, cy, z0, sx, sy, sz, rot=0.0, top=True, matTop=None):
        c, s = math.cos(rot), math.sin(rot)
        P = lambda dx, dy, z: (cx + dx * c - dy * s, cy + dx * s + dy * c, z)
        hx, hy = sx / 2, sy / 2
        cs = [(-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy)]
        for i in range(4):
            (ax, ay), (bx, by) = cs[i], cs[(i + 1) % 4]
            self.add(mat, [P(ax, ay, z0), P(bx, by, z0), P(bx, by, z0 + sz), P(ax, ay, z0 + sz)])
        if top:
            self.add(matTop or mat, [P(x, y, z0 + sz) for x, y in cs])

    def line(self, a, b, color=1, width=1):
        self.lines.append({"a": [r1(c) for c in a], "b": [r1(c) for c in b], "c": color, "w": width})


# ------------------------------------------------------------------ convex helpers

def clip_half(poly, nx, ny, d):
    """Keep points with nx*x + ny*y <= d (2D)."""
    out = []
    n = len(poly)
    for i in range(n):
        a, b = poly[i], poly[(i + 1) % n]
        fa, fb = nx * a[0] + ny * a[1] - d, nx * b[0] + ny * b[1] - d
        if fa <= 0:
            out.append(a)
        if (fa <= 0) != (fb <= 0):
            t = fa / (fa - fb)
            out.append((a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t))
    return out


def _area(poly):
    return 0.5 * sum(poly[i][0] * poly[(i + 1) % len(poly)][1] - poly[(i + 1) % len(poly)][0] * poly[i][1] for i in range(len(poly)))


def clip_convex(poly, clip):
    cx = sum(p[0] for p in clip) / len(clip); cy = sum(p[1] for p in clip) / len(clip)
    for k in range(len(clip)):
        a, b = clip[k], clip[(k + 1) % len(clip)]
        nx, ny = (b[1] - a[1]), -(b[0] - a[0])
        d = nx * a[0] + ny * a[1]
        if nx * cx + ny * cy > d:
            nx, ny, d = -nx, -ny, -d
        poly = clip_half(poly, nx, ny, d)
        if len(poly) < 3:
            return []
    return poly


def hull(pts):
    pts = sorted(set((round(p[0], 3), round(p[1], 3)) for p in pts))
    if len(pts) < 3:
        return pts
    def cross(o, a, b):
        return (a[0] - o[0]) * (b[1] - o[1]) - (a[1] - o[1]) * (b[0] - o[0])
    lo, up = [], []
    for p in pts:
        while len(lo) >= 2 and cross(lo[-2], lo[-1], p) <= 0:
            lo.pop()
        lo.append(p)
    for p in reversed(pts):
        while len(up) >= 2 and cross(up[-2], up[-1], p) <= 0:
            up.pop()
        up.append(p)
    return lo[:-1] + up[:-1]


def circle(cx, cy, r, n=12):
    return [(cx + r * math.cos(2 * math.pi * i / n), cy + r * math.sin(2 * math.pi * i / n)) for i in range(n)]


def foul_chain(park, per_side=6):
    ft = park["foulTerritory"]
    L, R = park["fences"][0], park["fences"][4]
    d0 = 0.8 * ft + 6
    def side(Lmax, sign):
        res = []
        for k in range(per_side + 1):
            D = Lmax * (1 - k / per_side) if sign < 0 else Lmax * k / per_side
            d = d0 * (1 - 0.55 * D / Lmax) + 4
            p = D * np.array([sign * S2, S2]) + d * np.array([sign * S2, -S2])
            res.append((p[0], p[1]))
        return res
    Lp = PK.spray_pt(-45, L); Rp = PK.spray_pt(45, R)
    return [(Lp[0], Lp[1])] + side(L, -1) + [(-0.45 * ft, -ft), (0.45 * ft, -ft)] + side(R, 1) + [(Rp[0], Rp[1])]


# ------------------------------------------------------------------ textures

def tex_text(text, w, h, fg=0, bg=255, fonts=("big", "bold10", "ui", "tiny"), border=True):
    im = Image.new("L", (w, h), bg)
    for fk in fonts:
        f = common.font(fk)
        if any(ch not in f.widths for ch in text):
            continue
        if f.width(text) <= w - 4 and f.ch * 0.72 <= h - 2:
            f.draw(im, ((w - f.width(text)) // 2, (h - f.ch) // 2 + 1), text, fg)
            break
    if border:
        ImageDraw.Draw(im).rectangle((0, 0, w - 1, h - 1), outline=fg)
    return im


def tex_crowd(style, seed):
    """Tileable 64x45 crowd: 3 rows x 8 seats; 4 texels/ft along a row, 15 texels per 2.8 ft row."""
    w, h = 64, 45
    im = Image.new("L", (w, h), 255)
    d = ImageDraw.Draw(im)
    rng = np.random.default_rng(seed)
    dens = PK.CROWD_DENS[style]
    # seat rows (back -> front so nearer rows overlap)
    for row in range(3):
        y0 = row * 15
        d.rectangle((0, y0 + 13, w - 1, y0 + 14), fill=0)          # step riser
        for x in range(0, w, 2):
            d.point((x + (row % 2), y0 + 11), fill=0)                 # seat backs (dither)
    for row in range(3):
        y0 = row * 15
        off = 4 if row % 2 else 0
        for k in range(8):
            if rng.random() > dens:
                continue
            cx = (k * 8 + 4 + off + rng.integers(-1, 2)) % w
            hv = rng.random(); hv3 = rng.random()
            if style == "dark":
                shirt = 0 if hv < 0.6 else 1
            elif style == "light":
                shirt = 2 if hv < 0.6 else (1 if hv < 0.85 else 0)
            else:
                shirt = 0 if hv < 0.35 else (1 if hv < 0.6 else 2)
            for dx in (-w, 0, w):  # wrap
                x = cx + dx
                d.chord((x - 4, y0 + 6, x + 4, y0 + 18), 180, 360, fill=255 if shirt == 2 else 0, outline=0)
                if shirt == 1:
                    for yy in range(y0 + 8, y0 + 12):
                        for xx in range(x - 3, x + 4):
                            if 0 <= xx < w and (xx + yy) % 2 == 0:
                                im.putpixel((xx, yy), 255)
                d.ellipse((x - 2, y0 + 2, x + 2, y0 + 6), fill=255, outline=0)
                if hv3 < 0.45:
                    d.chord((x - 2, y0 + 2, x + 2, y0 + 6), 180, 360, fill=0)
    return im


def tex_scoreboard(team):
    w, h = 96, 48
    im = Image.new("L", (w, h), 0)
    f = common.font("bold10")
    if f.width(team) > w - 6:
        f = common.font("tiny")
    f.draw(im, ((w - f.width(team)) // 2, 1), team, 255)
    t = common.font("tiny")
    t.draw(im, (4, 16), "1 2 3 4 5 6 7 8 9  R", 255)
    for i, lab in enumerate(("V", "H")):
        y = 26 + i * 10
        t.draw(im, (4, y), "0 0 0 0 0 0 0 0 0  0", 255)
    ImageDraw.Draw(im).rectangle((0, 0, w - 1, h - 1), outline=255)
    return im


def slug(s):
    return re.sub(r"[^a-z0-9]+", "_", s.lower()).strip("_")


# ------------------------------------------------------------------ geometry

def ground(g, park, st):
    fe = park["fences"]
    chain = foul_chain(park)
    fence = [PK.spray_pt(s, PK.fence_at(park, s)[0])[:2] for s in np.linspace(-45, 45, 17)]
    g.add("ground_far", [(-3000, -3000), (3000, -3000), (3000, 3000), (-3000, 3000)], layer=0)
    g.add("grass_foul" if st["mow"] != "turf" else "turf", hull(chain + fence), layer=1)
    fan = hull([(0, 0)] + fence)
    turf = st["mow"] == "turf"
    g.add("turf" if turf else "grass_a", fan, layer=2)
    mow = st["mow"]
    if mow in ("stripes", "stripes2"):
        step = 16 if mow == "stripes" else 18 * S2
        for k in range(0, 40, 2):
            if mow == "stripes":
                y0 = k * 16 - 4; y1 = y0 + 16
                piece = clip_half(clip_half(fan, 0, -1, -y0), 0, 1, y1)
            else:
                a0 = k * 18; a1 = a0 + 18
                piece = clip_half(clip_half(fan, -S2, -S2, -a0 * S2), S2, S2, a1 * S2)
            if len(piece) >= 3:
                g.add("grass_b", piece, layer=3)
    elif mow == "checker":
        sq = 44
        for i in range(-12, 13):
            for j in range(0, 14):
                if (i + j) % 2:
                    continue
                # diamond-oriented squares (rotated 45 deg): u=(x+y), v=(y-x)
                u0, v0 = i * sq, j * sq - 6 * sq
                cell = [((u0 - v0) / 2, (u0 + v0) / 2), ((u0 + sq - v0) / 2, (u0 + sq + v0) / 2),
                        ((u0 + sq - v0 - sq) / 2, (u0 + sq + v0 + sq) / 2), ((u0 - v0 - sq) / 2, (u0 + v0 + sq) / 2)]
                piece = clip_convex(fan, cell)
                if len(piece) >= 3 and abs(_area(piece)) > 20:
                    g.add("grass_b", piece, layer=3)
    elif mow == "arcs":
        for k in range(1, 24, 2):
            r0, r1_ = k * 36 / 2, k * 36 / 2 + 18
            for a in range(-45, 45, 15):
                piece = [PK.spray_pt(a, r0)[:2], PK.spray_pt(a + 15, r0)[:2], PK.spray_pt(a + 15, r1_)[:2], PK.spray_pt(a, r1_)[:2]]
                fd = min(PK.fence_at(park, a)[0], PK.fence_at(park, a + 15)[0])
                if r0 < fd:
                    g.add("grass_b", piece, layer=3)
    # warning track
    for i in range(16):
        s0, s1 = -45 + i * 5.625, -45 + (i + 1) * 5.625
        f0, f1 = PK.fence_at(park, s0)[0], PK.fence_at(park, s1)[0]
        g.add("warning_track", [PK.spray_pt(s0, f0 - 14), PK.spray_pt(s1, f1 - 14), PK.spray_pt(s1, f1), PK.spray_pt(s0, f0)], layer=4)
    # infield
    if not turf:
        wedge = circle(0, 60.5, 95, 32)
        wedge = clip_half(wedge, -math.cos(math.radians(52)), -math.sin(math.radians(52)), 0)
        wedge = clip_half(wedge, math.cos(math.radians(52)), -math.sin(math.radians(52)), 0)
        g.add("dirt", wedge, layer=5)
        e = BASE - 3.5
        g.add("grass_a", [(0, BASE - e), (e, BASE), (0, BASE + e), (-e, BASE)], layer=6)
    else:
        for bx, by in ((BASE, BASE), (0, 2 * BASE), (-BASE, BASE)):
            g.add("dirt", [(bx - 6, by - 6), (bx + 6, by - 6), (bx + 6, by + 6), (bx - 6, by + 6)], layer=5)
        arc = [PK.spray_pt(0, 0)]  # painted infield arc as a chalk line list
        pts = [(95 * math.sin(math.radians(t)), 60.5 + 95 * math.cos(math.radians(t)), 0) for t in np.linspace(-58, 58, 13)]
        for a, b in zip(pts, pts[1:]):
            g.line(a, b, 0)
    g.add("mound", circle(0, 60.5, 9, 12), layer=7)
    g.add("dirt", circle(0, 0, 13, 12), layer=7)
    # chalk + bases (lines are the crisp version; polygons below are the plates)
    for sign, fi in ((-1, 0), (1, 4)):
        L = fe[fi]
        g.line((0, 0, 0), (sign * L * S2, L * S2, 0), 1)
    for sx in (-1, 1):
        x0, x1 = sx * 1.2, sx * 5.2
        for a, b in (((x0, -3, 0), (x1, -3, 0)), ((x0, 3, 0), (x1, 3, 0)), ((x1, -3, 0), (x1, 3, 0)), ((x0, -3, 0), (x0, 3, 0))):
            g.line(a, b, 1)
    for bx, by in ((BASE, BASE), (0, 2 * BASE), (-BASE, BASE)):
        g.add("base", [(bx, by - 1.1), (bx + 1.1, by), (bx, by + 1.1), (bx - 1.1, by)], layer=8)
    g.add("plate", [(-0.7, 0.7), (-0.7, 0.0), (0, -0.0), (0.7, 0.0), (0.7, 0.7), (0, 1.4)][::-1], layer=8)
    g.add("rubber", [(-1, 60.5, 0), (1, 60.5, 0), (1, 60.7, 0), (-1, 60.7, 0)], layer=8)


def structures(g, park, st, texset):
    abbr = park["abbr"]
    small = st.get("small", False)
    style = st.get("crowd", "mixed")
    crowd_tex = f"crowd_{style}"
    texset.add(crowd_tex)
    photo = _photo_tex(style)
    if photo:
        KU, KV = 128 / PK.PHOTO_TILE_FT, 64 / (PK.PHOTO_TILE_FT / 2)   # photo tile 128x64 = 48 x 24 ft
    else:
        KU, KV = 4.0, 15 / 2.8  # drawn fallback tile: texels per ft (along row, up the slope)
    lf_seats = st.get("lf_seats", True)
    wood = st.get("wood")
    n = 16
    sprays = [-45 + 90 * i / n for i in range(n + 1)]
    wp = [(s,) + PK.fence_at(park, s) for s in sprays]
    depth_b, rise_b = (45, 22) if small else (75, 42)

    def crowd_quad(A, B, C, D, frame=None):
        A, B, C, D = (np.array(p, float) for p in (A, B, C, D))
        if photo:
            # same mapping as the static renders: u by azimuth (continuous), v by world height (upright people)
            uv = []
            fr = frame or PK.seg_frame(A, B, 0.0)[0]
            for q in (A, B, C, D):
                U, V = PK.crowd_uv(q[0], q[1], q[2], fr)
                uv.append((float(U) * KU, 640 - float(V) * KV))
            g.add("crowd", [A, B, C, D], tex=crowd_tex, uv=uv)
            return
        Lu = np.linalg.norm(B - A); Lv = np.linalg.norm(D - A); Lu2 = np.linalg.norm(C - D)
        g.add("crowd", [A, B, C, D], tex=crowd_tex,
              uv=[(0, Lv * KV), (Lu * KU, Lv * KV), (Lu2 * KU, 0), (0, 0)])

    for i in range(n):
        s0, r0, h0 = wp[i]; s1, r1_, h1 = wp[i + 1]
        a, b = PK.spray_pt(s0, r0), PK.spray_pt(s1, r1_)
        g.add("wall_wood" if wood else "wall", [a, b, (b[0], b[1], h1), (a[0], a[1], h0)])
        g.line((a[0], a[1], h0), (b[0], b[1], h1), 1)
        if lf_seats or s0 >= -12:
            k0 = (r0 + depth_b) / r0; k1 = (r1_ + depth_b) / r1_
            crowd_quad((a[0], a[1], h0), (b[0], b[1], h1), (b[0] * k1, b[1] * k1, h1 + rise_b), (a[0] * k0, a[1] * k0, h0 + rise_b),
                       PK.seg_frame(a, b, sum(np.hypot(*(np.array(PK.spray_pt(*wp[j][:2])[:2]) - np.array(PK.spray_pt(*wp[j + 1][:2])[:2]))) for j in range(i)))[0])
            g.add("stands_back", [(a[0] * k0, a[1] * k0, h0 + rise_b), (b[0] * k1, b[1] * k1, h1 + rise_b),
                                  (b[0] * k1, b[1] * k1, h1 + rise_b + 6), (a[0] * k0, a[1] * k0, h0 + rise_b + 6)])
        else:
            g.add("wall_net", [(a[0], a[1], h0), (b[0], b[1], h1), (b[0], b[1], h1 + 18), (a[0], a[1], h0 + 18)])
    # wall ads + distance markers
    for k, s in enumerate((-33.75, -11.25, 11.25, 33.75)):
        r, h = PK.fence_at(park, s)
        half = math.degrees(13.0 / r)
        ra = PK.fence_at(park, s - half)[0]; rb = PK.fence_at(park, s + half)[0]
        a = PK.spray_pt(s - half, ra - 0.4); b = PK.spray_pt(s + half, rb - 0.4)
        z0, z1 = h * 0.22, h * 0.82
        name = "ad_" + slug(st["ads"][k % len(st["ads"])])
        texset.add(("ad", name, st["ads"][k % len(st["ads"])]))
        g.add("ad_board", [(a[0], a[1], z0), (b[0], b[1], z0), (b[0], b[1], z1), (a[0], a[1], z1)], tex=name,
              uv=[(0, 16), (128, 16), (128, 0), (0, 0)])
    for s in (-45, -22.5, 0, 22.5, 45):
        r, h = PK.fence_at(park, s)
        half = math.degrees(6.0 / r)
        a = PK.spray_pt(s - half, r - 0.4); b = PK.spray_pt(s + half, r - 0.4)
        z0, z1 = h * 0.3, min(h * 0.8, h * 0.3 + 6)
        name = f"dist_{int(round(r))}"
        texset.add(("dist", name, str(int(round(r)))))
        g.add("marker", [(a[0], a[1], z0), (b[0], b[1], z0), (b[0], b[1], z1), (a[0], a[1], z1)], tex=name,
              uv=[(0, 12), (24, 12), (24, 0), (0, 0)])
        if abs(s) == 45:
            p = PK.spray_pt(s, r)
            g.line((p[0], p[1], 0), (p[0], p[1], h + 55), 1, 2)
    # foul stands
    chain = foul_chain(park)
    ft = park["foulTerritory"]
    wall_h = 4.0
    depth, rise = (60, 26) if small else (105, 52)
    cen = np.array([0.0, 150.0])
    vn = lambda p: (np.array(p) - cen) / (np.linalg.norm(np.array(p) - cen) + 1e-9)
    decks = st.get("decks", 1)
    for i in range(len(chain) - 1):
        a, b = np.array(chain[i]), np.array(chain[i + 1])
        g.add("stands_wall", [(a[0], a[1], 0), (b[0], b[1], 0), (b[0], b[1], wall_h), (a[0], a[1], wall_h)])
        g.line((a[0], a[1], wall_h), (b[0], b[1], wall_h), 1)
        na, nb = vn(a), vn(b)
        fr = PK.seg_frame(a, b, sum(np.hypot(*(np.array(chain[j]) - np.array(chain[j + 1]))) for j in range(i)))[0]
        A0 = (a[0], a[1], wall_h); B0 = (b[0], b[1], wall_h)
        A1 = (a[0] + na[0] * depth, a[1] + na[1] * depth, wall_h + rise)
        B1 = (b[0] + nb[0] * depth, b[1] + nb[1] * depth, wall_h + rise)
        if decks >= 2:
            off0, z0 = depth * 0.55, wall_h + rise * 0.55 + 14
            at = lambda p, nv, off, z: (p[0] + nv[0] * off, p[1] + nv[1] * off, z)
            # lower deck only up to the facade
            crowd_quad(A0, B0, at(b, nb, off0, wall_h + rise * 0.55), at(a, na, off0, wall_h + rise * 0.55), fr)
            g.add("deck_shadow", [at(a, na, off0, wall_h + rise * 0.55), at(b, nb, off0, wall_h + rise * 0.55), at(b, nb, off0, z0), at(a, na, off0, z0)])
            Fa0, Fb0, Fa1, Fb1 = at(a, na, off0, z0), at(b, nb, off0, z0), at(a, na, off0, z0 + 9), at(b, nb, off0, z0 + 9)
            g.add("deck_facade", [Fa0, Fb0, Fb1, Fa1])
            crowd_quad(Fa1, Fb1, at(b, nb, off0 + 70, z0 + 49), at(a, na, off0 + 70, z0 + 49), fr)
        else:
            crowd_quad(A0, B0, B1, A1, fr)
            g.add("stands_back", [A1, B1, (B1[0], B1[1], B1[2] + 8), (A1[0], A1[1], A1[2] + 8)])
    # backstop + board
    bx = 0.45 * ft
    g.add("backstop", [(-bx, -ft + 0.1, 0), (bx, -ft + 0.1, 0), (bx, -ft + 0.1, 9), (-bx, -ft + 0.1, 9)])
    name = "ad_" + slug(st["backstop"])
    texset.add(("ad", name, st["backstop"]))
    g.add("ad_board", [(bx * 0.55, -ft + 0.4, 3), (-bx * 0.55, -ft + 0.4, 3), (-bx * 0.55, -ft + 0.4, 7), (bx * 0.55, -ft + 0.4, 7)],
          tex=name, uv=[(0, 16), (128, 16), (128, 0), (0, 0)])
    g.line((-bx, -ft, 9), (bx, -ft, 9), 1)
    # dugouts
    for sign in (-1, 1):
        d = 0.8 * ft + 6
        Lx = park["fences"][0 if sign < 0 else 4]
        def bp(D):
            dd = d * (1 - 0.55 * D / Lx) + 4 - 0.3
            return np.array([sign * S2, S2]) * D + np.array([sign * S2, -S2]) * dd
        a, b = bp(55), bp(95)
        g.add("dugout", [(a[0], a[1], 0), (b[0], b[1], 0), (b[0], b[1], 2.6), (a[0], a[1], 2.6)])
    # scoreboard: box with textured front face
    sbs = st.get("board_spray", 0)
    r, h = PK.fence_at(park, sbs)
    rr = r + (55 if small else 85)
    c = PK.spray_pt(sbs, rr)
    rot = -math.radians(sbs)
    w_ = 56 if small else 90
    z0 = 22 if small else 40
    hgt = 26 if small else 42
    g.box("scoreboard", c[0], c[1], z0, w_, 6, hgt, rot=rot)
    dirv = np.array([math.cos(rot), math.sin(rot)])
    inward = -np.array(PK.spray_pt(sbs, 1.0)[:2]) * 3.2
    p0 = np.array(c[:2]) - dirv * w_ * 0.48 + inward; p1 = np.array(c[:2]) + dirv * w_ * 0.48 + inward
    sbname = f"sb_{abbr.lower()}"
    texset.add(("sb", sbname, st["board"]))
    g.add("scoreboard_face", [(p0[0], p0[1], z0 + 1), (p1[0], p1[1], z0 + 1), (p1[0], p1[1], z0 + hgt - 1), (p0[0], p0[1], z0 + hgt - 1)],
          tex=sbname, uv=[(0, 48), (96, 48), (96, 0), (0, 0)])
    for dx in (-w_ * 0.35, w_ * 0.35):
        g.box("steel", c[0] + dx * math.cos(rot), c[1] + dx * math.sin(rot), 0, 3, 3, z0, rot=rot, top=False)
    if st.get("bolt"):
        bc = np.array(PK.spray_pt(sbs, rr - 3.5))
        P = lambda dx, z: (bc[0] + dirv[0] * dx, bc[1] + dirv[1] * dx, z)
        top = z0 + hgt
        g.add("bolt", [P(-4, top + 34), P(8, top + 34), P(2, top + 18), P(-6, top + 18)])
        g.add("bolt", [P(-6, top + 18), P(10, top + 18), P(-8, top - 2)])
    # light towers
    nt = st.get("towers", 0)
    for s in {4: [-62, -25, 25, 62], 6: [-75, -40, -12, 12, 40, 75]}.get(nt, []):
        if abs(s) > 45:
            D = 150 if abs(s) > 70 else 230
            sign = 1 if s > 0 else -1
            p = np.array([sign * S2, S2]) * D + np.array([sign * S2, -S2]) * (0.8 * ft + 6 + (85 if not small else 50))
        else:
            p = np.array(PK.spray_pt(s, PK.fence_at(park, s)[0] + (65 if not small else 45))[:2])
        topz = 150 if not small else 80
        g.box("steel", p[0], p[1], 0, 3.5, 3.5, topz, top=False)
        to = -p / np.linalg.norm(p); side = np.array([-to[1], to[0]])
        bw = 15 if not small else 10
        c0 = p + to * 2.2
        a, b = c0 - side * bw, c0 + side * bw
        g.add("light_bank", [(a[0], a[1], topz - 4), (b[0], b[1], topz - 4), (b[0], b[1], topz + 12), (a[0], a[1], topz + 12)])
    if st.get("flags"):
        for s in (-30, -10, 10, 30):
            if not lf_seats and s < -12:
                continue
            r, h = PK.fence_at(park, s)
            p = PK.spray_pt(s, r + 75)
            base = h + 48
            g.box("steel", p[0], p[1], base, 0.8, 0.8, 26, top=False)
            g.add("flag_dark" if s % 20 else "flag_light", [(p[0], p[1], base + 26), (p[0] + 9, p[1] + 2, base + 23), (p[0], p[1], base + 20)])
    if st.get("lamps"):
        for s in np.linspace(-40, 40, 9):
            r, h = PK.fence_at(park, s)
            p = PK.spray_pt(s, r + 1.5)
            g.line((p[0], p[1], h), (p[0], p[1], h + 10), 0, 1)
            g.billboards.append({"m": MAT["lamp"], "c": [r1(p[0]), r1(p[1]), r1(h + 11)], "r": 1.3})
    rng = np.random.default_rng(sum(ord(ch) for ch in abbr))
    if st.get("skyline"):
        for k in range(14):
            s = -70 + 140 * k / 13 + rng.uniform(-2, 2)
            p = PK.spray_pt(s, rng.uniform(900, 1300))
            hh = rng.uniform(60, 260); wd = rng.uniform(50, 90)
            g.box("skyline", p[0], p[1], 0, wd, wd * 0.8, hh, rot=math.radians(-s), top=False)
    if st.get("steeple"):
        p = PK.spray_pt(8, 760)
        g.box("landmark", p[0], p[1], 0, 40, 40, 110, top=False)
        q = 20 * math.sqrt(2)
        for i in range(4):
            a0, a1 = math.pi / 2 * i + math.pi / 4, math.pi / 2 * (i + 1) + math.pi / 4
            g.add("landmark_dark" if i % 2 else "landmark", [(p[0] + q * math.cos(a0), p[1] + q * math.sin(a0), 110),
                                                           (p[0] + q * math.cos(a1), p[1] + q * math.sin(a1), 110), (p[0], p[1], 210)])
        g.line((p[0], p[1] - 1, 205), (p[0], p[1] - 1, 232), 0, 2)
        g.line((p[0] - 7, p[1] - 1, 222), (p[0] + 7, p[1] - 1, 222), 0, 2)
        g.box("landmark", p[0] + 60, p[1] + 10, 0, 90, 50, 60, top=False)
    if st.get("cranes"):
        for k, s in enumerate((-40, -24, 52)):
            p = PK.spray_pt(s, 640 + 60 * k)
            hh = 150 + 20 * k
            g.box("steel", p[0], p[1], 0, 6, 6, hh, top=False)
            g.box("steel", p[0] + 30, p[1] + 10, hh, 110, 4, 4, rot=0.4, top=False)
        p = PK.spray_pt(-10, 820)
        g.box("ship", p[0], p[1], 0, 260, 40, 30)
        g.box("landmark", p[0] + 60, p[1], 30, 60, 30, 30)
    if st.get("stacks"):
        for k, s in enumerate((-35, -20, 5, 18)):
            p = PK.spray_pt(s, 700 + 90 * (k % 2))
            hh = 170 + 30 * (k % 3)
            g.box("landmark_dark", p[0], p[1], 0, 22, 22, hh, top=False)
            for j in range(3):
                g.billboards.append({"m": MAT["smoke"], "c": [r1(p[0] + 14 * j + 4), r1(p[1] + 3 * j), r1(hh + 14 + 16 * j)], "r": 12 + 6 * j})
        p = PK.spray_pt(-27, 760)
        g.box("landmark_dark", p[0], p[1], 0, 220, 70, 70, rot=0.3)
    if st.get("tower_water"):
        p = PK.spray_pt(-30 if abbr == "CSR" else 35, 560)
        g.box("steel", p[0], p[1], 0, 18, 18, 70, top=False)
        g.box("landmark", p[0], p[1], 70, 30, 30, 24)
    if st.get("trees"):
        for k in range(14):
            s = -60 + 120 * k / 13 + rng.uniform(-1.5, 1.5)
            p = PK.spray_pt(s, park["fences"][2] + rng.uniform(110, 200))
            hh = rng.uniform(30, 55)
            g.billboards.append({"m": MAT["tree"], "c": [r1(p[0]), r1(p[1]), r1(hh * 0.7)], "r": r1(hh * 0.42)})
        # tree line ring
        for k in range(12):
            a0, a1 = -90 + 15 * k, -90 + 15 * (k + 1)
            R = 1400
            A, B = PK.spray_pt(a0, R), PK.spray_pt(a1, R)
            g.add("treeline", [A, B, (B[0], B[1], 70), (A[0], A[1], 70)])
    if st.get("mountains"):
        # far mountain range: triangles on a ring at 4000 ft, behind everything
        rng2 = np.random.default_rng(3)
        for k in range(16):
            a = -110 + 220 * k / 15 + rng2.uniform(-4, 4)
            R = 4000
            hh = rng2.uniform(300, 650)
            wa = rng2.uniform(9, 16)
            A, B, Cc = PK.spray_pt(a - wa, R), PK.spray_pt(a + wa, R), PK.spray_pt(a, R - 50, hh)
            g.add("mountains", [A, B, Cc])
            if hh > 480:
                t = 0.2
                L = [A[i] + (Cc[i] - A[i]) * (1 - t) for i in range(3)]
                Rr = [B[i] + (Cc[i] - B[i]) * (1 - t) for i in range(3)]
                Cs = PK.spray_pt(a, R - 60, hh)
                g.add("snow", [L, Rr, Cs])


def _photo_tex(style):
    return os.path.exists(os.path.join(common.IMAGES, "crowd", f"tex-{style}-128x64.png"))


def sky_spec(st):
    k = st["sky"]
    if k == "night":
        return {"top": 0.03, "horizon": 0.03, "stars": True}
    if k == "haze":
        return {"top": 0.86, "horizon": 0.74, "stars": False}
    return {"top": 0.97, "horizon": 0.85, "stars": False}


# ------------------------------------------------------------------ export

def export(verbose=True):
    common.ensure_dir(TEX)
    parks = PK.parse_parks()
    out = {"version": 1,
           "coords": "feet; home plate origin, +y to CF, +x to 1B side, +z up",
           "materials": [{"name": n, "gray": g, "outline": o, **({"pattern": PAT[p]} if p else {})} for n, g, o, p in MATERIALS],
           "textures": {}, "parks": {}}
    texset = set()
    counts = {}
    for park in parks:
        st = PK.STYLE[park["abbr"]]
        g = Geo()
        ground(g, park, st)
        structures(g, park, st, texset)
        out["parks"][park["id"]] = {"sky": sky_spec(st), "polys": g.polys, "billboards": g.billboards, "lines": g.lines}
        counts[park["id"]] = (len(g.polys), len(g.billboards), len(g.lines))
    # textures
    for t in sorted(texset, key=str):
        if isinstance(t, str):  # crowd style
            style = t.split("_", 1)[1]
            name = t; wrap = True
            if _photo_tex(style):
                # real crowd photo tile from crowd.py (images/crowd/tex-<style>-128x64)
                im = Image.open(os.path.join(common.IMAGES, "crowd", f"tex-{style}-128x64.png")).convert("L")
                out["textures"][name] = {"file": f"images/crowd/tex-{style}-128x64", "w": im.width, "h": im.height, "wrap": True}
                old = os.path.join(TEX, name + ".png")
                if os.path.exists(old):
                    os.remove(old)
                continue
            im = tex_crowd(style, 11 + len(style))
        else:
            kind, name, text = t
            if kind == "ad":
                im = tex_text(text, 128, 16)
            elif kind == "dist":
                im = tex_text(text, 24, 12, fg=255, bg=0, fonts=("bold10", "ui", "tiny"), border=False)
            else:
                im = tex_scoreboard(text)
            wrap = False
        common.save_1bit(im, os.path.join(TEX, name + ".png"))
        out["textures"][name] = {"file": f"images/parks/tex/{name}", "w": im.width, "h": im.height, "wrap": wrap}
    path = os.path.join(OUT, "parks-geo.json")
    with open(path, "w") as fh:
        json.dump(out, fh, separators=(",", ":"))
    if verbose:
        for k, v in counts.items():
            print(f"{k}: {v[0]} polys, {v[1]} billboards, {v[2]} lines")
        print("parks-geo.json", os.path.getsize(path), "bytes;", len(out["textures"]), "textures")
    return out, counts


# ------------------------------------------------------------------ verification renderer (JSON only)

def render_from_geo(geo, park_id, cam):
    """Painter's renderer driven only by parks-geo.json data + camera (dither + textures)."""
    pk = geo["parks"][park_id]
    mats = geo["materials"]
    texcache = {}
    def tex(name):
        if name not in texcache:
            t = geo["textures"][name]
            texcache[name] = (np.asarray(Image.open(os.path.join(common.SRC, t["file"] + ".png")).convert("L")) > 127, t["wrap"])
        return texcache[name]
    rnd = Renderer(cam, ss=1)
    sk = pk["sky"]
    def skyfn(az, el):
        g = sk["top"] + (sk["horizon"] - sk["top"]) * np.exp(-np.maximum(el, 0) / 12.0)
        if sk.get("stars"):
            g = np.where((PK.h2(np.floor(az * 9), np.floor(el * 9), 3.0) > 0.996) & (el > 4), 1.0, g)
        return g.astype(np.float32)
    rnd.sky(skyfn)
    pattern_px = {}
    # depth sort: layers < 10 in (layer, index) order; others far -> near by centroid distance
    eye = cam.eye
    items = []
    for i, p in enumerate(pk["polys"]):
        v = np.array(p["v"], float)
        if p["l"] < 10:
            key = (0, p["l"], i)
        else:
            dcen = np.linalg.norm(v.mean(0) - eye)
            key = (1, -dcen, i)
        items.append((key, "p", p))
    for b in pk["billboards"]:
        items.append(((1, -float(np.linalg.norm(np.array(b["c"]) - eye)), 0), "b", b))
    items.sort(key=lambda t: t[0])
    hard = np.full((H, W), -1, np.int16)  # -1 = use dithered gray, 0/255 = exact (pattern/texture)
    for key, kind, p in items:
        if kind == "b":
            q = cam.project(p["c"])
            if q is None:
                continue
            r = p["r"] * cam.scale / q[2]
            m = mats[p["m"]]
            yy, xx = np.mgrid[0:H, 0:W]
            msk = (xx + 0.5 - q[0]) ** 2 + ((yy + 0.5 - q[1]) / 0.85) ** 2 < r * r
            rnd.gray[msk] = m["gray"]; hard[msk] = -1
            continue
        m = mats[p["m"]]
        pts = [np.array(v, float) for v in p["v"]]
        shader = None
        if "t" in p:
            img, wrap = tex(p["t"])
            uv = np.array(p["uv"], float)
            # texel density (texels per ft) along edge 0->1; too dense on screen -> material gray
            dens = np.linalg.norm(uv[1] - uv[0]) / (np.linalg.norm(pts[1] - pts[0]) + 1e-9)
            def shader(P, u, v, pix, uv=uv, img=img, wrap=wrap, dens=dens, gray=m["gray"]):
                U = uv[0][0] + u * (uv[1][0] - uv[0][0]) + v * (uv[-1][0] - uv[0][0])
                V = uv[0][1] + u * (uv[1][1] - uv[0][1]) + v * (uv[-1][1] - uv[0][1])
                hh, ww = img.shape
                if wrap:
                    Ui = np.floor(U).astype(int) % ww; Vi = np.floor(V).astype(int) % hh
                else:
                    Ui = np.clip(np.floor(U).astype(int), 0, ww - 1); Vi = np.clip(np.floor(V).astype(int), 0, hh - 1)
                exact = np.where(img[Vi, Ui], 2.0, -2.0).astype(np.float32)  # out-of-range markers = exact
                return np.where(pix * dens > 1.5, gray, exact)
        elif "pattern" in m:
            pat = np.array([[(row >> (7 - b)) & 1 for b in range(8)] for row in m["pattern"]], bool)
            def shader(P, u, v, pix, pat=pat):
                return np.full(u.shape, 3.0, np.float32)  # marker -> screen-space pattern
            pattern_px[id(p)] = pat
        before = rnd.gray.copy()
        rnd.z[:] = np.inf   # painter's: no depth test
        rnd.poly(Poly(pts, m["gray"], shader))
        changed = rnd.gray != before
        g = rnd.gray
        if "t" in p:
            ex = changed & (np.abs(g) >= 2)
            hard[ex] = np.where(g[ex] > 0, 255, 0)
            g[ex] = 0.5
        elif "pattern" in m:
            pat = pattern_px[id(p)]
            ex = changed & (g == 3.0)
            yy, xx = np.nonzero(ex)
            hard[yy, xx] = np.where(pat[yy % 8, xx % 8], 255, 0)
            g[ex] = 0.5
        else:
            hard[changed] = -1
    img, zb, _ = rnd.resolve()
    a = np.asarray(img).copy()
    a = np.where(hard >= 0, hard, a).astype(np.uint8)
    im = Image.fromarray(a, "L")
    d = ImageDraw.Draw(im)
    for ln in pk["lines"]:
        A, B = np.array(ln["a"]), np.array(ln["b"])
        ca, cb = cam.to_cam(A), cam.to_cam(B)
        if ca[2] < 1 and cb[2] < 1:
            continue
        if ca[2] < 1:
            A = A + (B - A) * ((1 - ca[2]) / (cb[2] - ca[2]))
        elif cb[2] < 1:
            B = B + (A - B) * ((1 - cb[2]) / (ca[2] - cb[2]))
        pa, pb = cam.project(A), cam.project(B)
        if pa and pb:
            d.line((pa[0], pa[1], pb[0], pb[1]), fill=255 if ln["c"] else 0, width=ln["w"])
    return im


def previews(geo, verbose=True):
    for park in PK.parse_parks():
        cams = PK.cameras(park)
        row = []
        for cn in ("pitch", "high_home"):
            geo_im = render_from_geo(geo, park["id"], cams[cn])
            static = Image.open(os.path.join(OUT, f"{park['id']}-{cn}.png")).convert("L")
            row += [static, geo_im]
        sheet = Image.new("L", (808, 488), 255)
        for i, im in enumerate(row):
            sheet.paste(im, (4 + (i % 2) * 404, 4 + (i // 2) * 244))
        sheet.save(os.path.join(common.PREVIEW, f"geo_{park['id']}.png"))


def readme(geo, counts):
    mats = ", ".join(f"`{m['name']}`" for m in geo["materials"])
    cnt = "; ".join(f"{k}: {v[0]} polys / {v[1]} billboards / {v[2]} lines" for k, v in counts.items())
    t = f"""## BallCast live geometry (`images/parks/parks-geo.json`, `images/parks/tex/`)

For the live C renderer. Same field frame and camera math as `parks.json` (feet; home plate origin,
+y to CF, +x to 1B side, +z up). Compact JSON, coordinates rounded to 0.1 ft.

```
{{ "version":1,
  "materials":[ {{"name":"grass_a","gray":0.27,"outline":false}}, {{"name":"light_bank","gray":0.9,"outline":false,
                 "pattern":[8 bytes]}}, ... ],            # index = material id
  "textures": {{ "crowd_mixed": {{"file":"images/parks/tex/crowd_mixed","w":64,"h":45,"wrap":true}}, ... }},
  "parks": {{ "park-hcl": {{
      "sky": {{"top":0.97,"horizon":0.85,"stars":false}},
      "polys": [ {{"m":2,"l":2,"v":[[x,y,z],...]}},                       # convex, 3+ verts
                {{"m":18,"l":10,"v":[[..]x4],"t":"crowd_mixed","uv":[[u,v]x4]}}, ... ],
      "billboards": [ {{"m":35,"c":[x,y,z],"r":12}} ],                       # camera-facing discs (smoke, trees, lamps)
      "lines": [ {{"a":[x,y,z],"b":[x,y,z],"c":1,"w":1}} ] }} }} }}        # c: 1 white / 0 black, w: px width
```

**Materials** (fill = `gray` 0..1 through an 8x8 Bayer ordered dither, 1 = white; if `pattern` is present use it
instead: 8 bytes = rows 0..7, bit 7 = leftmost pixel, 1 = white, anchored to screen coordinates;
`outline` = draw a 1 px black edge): {mats}.

**Draw order.** Clear to the sky: per screen row, gray = `horizon + (top - horizon) * (1 - exp(-max(el,0)/12))`
where `el` is the ray elevation in degrees (a flat `top` fill is fine too); night parks (`stars`) are near-black.
Then polygons with `l < 10` in ascending `l`, and within a layer in file order (ground: 0 far ground,
1 foul grass, 2 fair grass, 3 mowing stripes, 4 warning track, 5 infield dirt, 6 infield grass, 7 mound/home
circle, 8 bases/plate/rubber). Then everything with `l == 10` plus the billboards, sorted far -> near by the
distance from the eye to the polygon centroid (billboard centre). Clip against the near plane (z_cam >= 1)
before projecting. Finally draw `lines` (chalk, wall-top stripe, foul poles, lamp posts) as 2D lines between
projected end points (clip to the near plane). Billboards: filled disc radius `r * scale / depth`.

**Textures.** 1-bit opaque PNGs in `images/parks/tex/` (`crowd_<style>` = the photo crowd tile `images/crowd/tex-<style>-128x64` (128x64 = 48 x 24 ft, tileable, `wrap:true`; the textures table gives the file), falling back to a drawn 64x45 tile only if the photos are missing;
`ad_<brand>` 128x16 black-on-white boards; `dist_<feet>` 24x12 white numerals; `sb_<abbr>` 96x48 scoreboard
faces). A textured polygon has `t` and `uv` with one `[u,v]` per vertex in texel units (u right, v down;
for wrapping textures take `mod w/h`). Map affinely across the projected quad (vertex 0 -> uv 0 ...);
crowd uvs are not per-quad 0..1: u = arc length along the stands, v = 640 - world height (both x 128/48 texels
per ft), so the photo crowd stays upright and continuous across segments; affine mapping across a big
stands quad shows some skew/streaking — perspective-correct (or subdividing the quad) looks better.
Untextured fallback: the material `gray` — also use it when the texture would be minified (texels per
screen pixel > ~1.5, i.e. `texels_per_ft * depth / scale > 1.5`, with texels_per_ft = |uv1-uv0| / |v1-v0|);
point-sampling a minified crowd texture just makes moire.

**Counts:** {cnt}.

Verification: `tools/assets/preview/geo_<park>.png` shows, per row, the static background (left) and the same
camera rendered only from parks-geo.json (right), for the pitch and high_home cameras.
"""
    common.write_readme_part("35-parks-geo.md", t)


def build(verbose=True):
    geo, counts = export(verbose)
    previews(geo, verbose)
    readme(geo, counts)
    return geo


if __name__ == "__main__":
    build()
