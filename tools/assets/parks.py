"""BallCast 3D ballpark backgrounds + parks.json camera/projection spec.

Run standalone: python3 tools/assets/parks.py
Outputs playdate/source/images/parks/<parkId>-<cam>.png (400x240, opaque 1-bit) and
playdate/source/images/parks/parks.json. Park dimensions are parsed from
packages/sim/src/worldgen.ts (CLUBS) so rebuilds follow sim edits.
"""
import os, re, math, json, sys
import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common
from field3d import Camera, Renderer, Overlay, Poly, W, H

OUT = os.path.join(common.IMAGES, "parks")
WORLDGEN = os.path.join(common.ROOT, "packages", "sim", "src", "worldgen.ts")
S2 = math.sqrt(0.5)
BASE = 90 * S2  # 63.64

CAMS = ["pitch", "high_home", "lf", "cf", "rf", "bleachers"]


# ------------------------------------------------------------------ park data

def parse_parks():
    src = open(WORLDGEN, encoding="utf-8").read()
    out = []
    pat = re.compile(
        r'abbr:\s*"(\w+)",\s*city:\s*"([^"]+)",\s*name:\s*"([^"]+)".*?park:\s*\{\s*name:\s*"([^"]+)",\s*'
        r'fences:\s*\[([^\]]+)\],\s*walls:\s*\[([^\]]+)\],\s*altitudeFt:\s*(\d+),\s*foulTerritory:\s*(\d+),\s*turf:\s*(true|false)',
        re.S)
    for m in pat.finditer(src):
        abbr, city, name, pname, fences, walls, alt, foul, turf = m.groups()
        out.append(dict(id=f"park-{abbr.lower()}", abbr=abbr, city=city, team=name, name=pname,
                        fences=[float(v) for v in fences.split(",")], walls=[float(v) for v in walls.split(",")],
                        altitudeFt=int(alt), foulTerritory=int(foul), turf=turf == "true"))
    # generic farm park ("Municipal Field": makeFarmPark ranges, middle values)
    out.append(dict(id="park-farm", abbr="FARM", city="Anytown", team="Farmhands", name="Municipal Field",
                    fences=[325, 374, 405, 374, 325], walls=[10, 10, 10, 10, 10], altitudeFt=700,
                    foulTerritory=60, turf=False))
    return out


# per-park character
STYLE = {
    "HCL": dict(mow="stripes", sky="day", skyline=True, lamps=True, decks=2, towers=4, crowd="mixed", seat=0.55,
                ads=["ZAP COLA", "HOT DOG HAL'S", "HALDANE & SONS", "DIALUP DEPOT"],
                backstop="BETS BY BOBBY", facade=["SPORTSWIRE.NET", "ZAP COLA", "HARBOR CITY BANK"],
                board="LAMPLIGHTERS", board_spray=28, flags=True),
    "STA": dict(mow="checker", sky="day", steeple=True, decks=1, towers=4, crowd="dark", seat=0.35,
                ads=["PRAY & PLAY", "ST. ALBANS BINGO", "VOTIVE 2/$1", "CONFESS 24HR"],
                backstop="SANCTUARY FIELD", facade=["HOLY SMOKES BBQ", "BINGO TUES"],
                board="FRIARS", board_spray=0, flags=True),
    "PEM": dict(mow="stripes", sky="day", cranes=True, decks=1, towers=4, crowd="mixed", seat=0.6,
                ads=["HARBOR SALVAGE", "BAIT & MODEM", "FERRY TIX", "PORT ELLIS TRUST"],
                backstop="WHARF ST GROUNDS", facade=["ZAP COLA", "DOCK 9 OYSTERS"],
                board="MARINERS", board_spray=25, flags=True, lf_seats=False),
    "MIL": dict(mow="turf", sky="haze", stacks=True, decks=1, towers=4, crowd="mixed", seat=0.45,
                ads=["MILLBROOK STEEL", "DIALUP DEPOT", "FURNACE FIELD", "IRON CITY AUTO"],
                backstop="MILLBROOK STEEL", facade=["UNION? NO THANKS", "ZAP COLA"],
                board="IRONMEN", board_spray=-25, flags=False),
    "CSR": dict(mow="arcs", sky="day", mountains=True, tower_water=True, decks=1, towers=4, crowd="light", seat=0.7,
                ads=["STOCKYARD BBQ", "COLD SPRING FEED", "RODEO '98", "SHERIFF DALE"],
                backstop="STOCKYARD PARK", facade=["BEEF. IT'S BEEF", "ZAP COLA"],
                board="RUSTLERS", board_spray=-22, flags=True),
    "NCG": dict(mow="stripes2", sky="day", skyline=True, decks=2, towers=4, crowd="dark", seat=0.5,
                ads=["CORINTH CLUB", "OLD MONEY TRUST", "Y2K READY BANK", "GRAYS 1-900"],
                backstop="CORINTH COMMONS", facade=["MEMBERS ONLY", "Y2K READY BANK", "CIGAR LOUNGE"],
                board="GRAYS", board_spray=0, flags=True),
    "MRL": dict(mow="checker", sky="day", trees=True, decks=1, towers=0, crowd="light", seat=0.8, wood=True,
                ads=["BROTHER AMOS SAVES", "NO SUNDAY BALL", "PILGRIM PIE", "REPENT 98.5 FM"],
                backstop="PLYMOUTH YARD", facade=["THOU SHALT BUNT", "PILGRIM PIE"],
                board="PILGRIMS", board_spray=-30, flags=True),
    "ELC": dict(mow="turf", sky="night", decks=2, towers=6, crowd="mixed", seat=0.5, bolt=True,
                ads=["VOLTA P&L", "MODEM MART", "BEEPERZ", "SPORTSWIRE.NET"],
                backstop="VOLTA POWER & LIGHT", facade=["NIGHT BALL!", "VOLTA P&L", "56K OR BUST"],
                board="COMETS", board_spray=0, flags=False),
    "FARM": dict(mow="stripes", sky="day", trees=True, tower_water=True, decks=1, towers=4, crowd="sparse", seat=0.75,
                 wood=True, small=True,
                 ads=["FEED & SEED", "BIG LOU'S MUFFLERS", "MOTOR INN", "EAT AT JOE'S"],
                 backstop="MUNICIPAL FIELD", facade=["BINGO FRI", "ZAP COLA"],
                 board="HOME", board_spray=20, flags=False),
}


def fence_at(park, spray):
    s = max(-45.0, min(45.0, spray))
    idx = (s + 45) / 22.5
    i = min(3, int(math.floor(idx)))
    f = idx - i
    fe, wa = park["fences"], park["walls"]
    return fe[i] + (fe[i + 1] - fe[i]) * f, wa[i] + (wa[i + 1] - wa[i]) * f


def spray_pt(spray, r, z=0.0):
    a = math.radians(spray)
    return (r * math.sin(a), r * math.cos(a), z)


# ------------------------------------------------------------------ helpers

def h2(a, b, c=0.0):
    """Vectorised hash -> [0,1)."""
    v = np.sin(a * 12.9898 + b * 78.233 + c * 37.719) * 43758.5453
    return v - np.floor(v)


def quad_poly(a, b, c, d, gray=0.5, shader=None, bias=0.0):
    return Poly([a, b, c, d], gray, shader, bias)


def box(cx, cy, z0, sx, sy, sz, gray, rot=0.0, top=None, shader=None):
    """Axis box rotated about z; returns polys (4 sides + top)."""
    c, s = math.cos(rot), math.sin(rot)
    def p(dx, dy, z):
        return (cx + dx * c - dy * s, cy + dx * s + dy * c, z)
    hx, hy = sx / 2, sy / 2
    z1 = z0 + sz
    corners = [(-hx, -hy), (hx, -hy), (hx, hy), (-hx, hy)]
    out = []
    for i in range(4):
        (ax, ay), (bx, by) = corners[i], corners[(i + 1) % 4]
        g = gray * (0.75 if i % 2 else 1.0)
        out.append(Poly([p(ax, ay, z0), p(bx, by, z0), p(bx, by, z1), p(ax, ay, z1)], g, shader))
    out.append(Poly([p(*corners[i], z1) for i in range(4)], top if top is not None else gray * 1.15))
    return out


def prism(cx, cy, z0, r, hgt, gray, n=8, r_top=None):
    r_top = r if r_top is None else r_top
    out = []
    for i in range(n):
        a0, a1 = 2 * math.pi * i / n, 2 * math.pi * (i + 1) / n
        shade = 0.7 + 0.3 * abs(math.cos((a0 + a1) / 2 - 0.6))
        out.append(Poly([(cx + r * math.cos(a0), cy + r * math.sin(a0), z0), (cx + r * math.cos(a1), cy + r * math.sin(a1), z0),
                         (cx + r_top * math.cos(a1), cy + r_top * math.sin(a1), z0 + hgt),
                         (cx + r_top * math.cos(a0), cy + r_top * math.sin(a0), z0 + hgt)], gray * shade))
    return out


def facing_disc(cam, c, r, gray, n=12):
    """Vertical disc facing the camera (billboard polygon) — smoke puffs, tree crowns."""
    c = np.asarray(c, float)
    to = cam.eye - c
    to[2] = 0
    to /= (np.linalg.norm(to) + 1e-9)
    side = np.array([-to[1], to[0], 0.0])
    pts = [c + side * r * math.cos(2 * math.pi * i / n) + np.array([0, 0, 1.0]) * r * 0.85 * math.sin(2 * math.pi * i / n)
           for i in range(n)]
    return Poly(pts, gray)


# ------------------------------------------------------------------ shaders

def grass_shader(park, st):
    mow = st["mow"]

    def fn(x, y, depth, pix):
        r = np.hypot(x, y)
        spray = np.degrees(np.arctan2(x, y))
        fair = (np.abs(spray) <= 45) & (y > -1)
        sc = np.clip(spray, -45, 45)
        idx = (sc + 45) / 22.5
        i = np.minimum(3, np.floor(idx)).astype(int)
        f = idx - i
        fe = np.array(park["fences"])
        fd = fe[i] + (fe[np.minimum(i + 1, 4)] - fe[i]) * f
        turf = mow == "turf"
        # base grass with mowing pattern
        if turf:
            g = np.full(x.shape, 0.42, np.float32)
            seam = (np.abs(((y + 2.5) % 15) - 7.5) > 7.2) | (np.abs(((x + 2.5) % 15) - 7.5) > 7.2)
            g = np.where(seam & (pix < 0.6), 0.52, g)
        elif mow == "stripes":
            g = np.where((np.floor((y + 4) / 16) % 2) == 0, 0.27, 0.6)
        elif mow == "stripes2":  # diagonal stripes
            g = np.where((np.floor((x + y) / 18) % 2) == 0, 0.27, 0.6)
        elif mow == "checker":
            g = np.where(((np.floor((x + y) / 22) + np.floor((y - x) / 22)) % 2) == 0, 0.27, 0.6)
        else:  # arcs
            g = np.where((np.floor(r / 18) % 2) == 0, 0.27, 0.6)
        g = g.astype(np.float32)
        # foul territory: plainer
        foul = ~fair
        g = np.where(foul, 0.58 if not turf else 0.42, g)
        dirt = 0.86
        # warning track
        track = fair & (r > fd - 14) & (r <= fd + 1)
        g = np.where(track, 0.8, g)
        beyond = fair & (r > fd + 1)
        g = np.where(beyond, 0.3, g)
        # the world outside the park (seen over the stands from high cameras): town blocks
        outside = r > fe.max() + 140
        blocks = ((x % 70) < 52) & ((y % 70) < 52)
        roof = h2(np.floor(x / 70), np.floor(y / 70), 5.0)
        town = np.where(blocks, np.where(roof < 0.5, 0.62, 0.78), 0.92)
        g = np.where(outside, town, g)
        # infield
        dm = np.hypot(x, y - 60.5)
        if turf:
            inf_dirt = np.zeros(x.shape, bool)
            for bx, by in ((BASE, BASE), (0, 2 * BASE), (-BASE, BASE)):
                inf_dirt |= (np.abs(x - bx) < 6) & (np.abs(y - by) < 6)
            inf_dirt |= dm < 9
            inf_dirt |= np.hypot(x, y) < 13
            # baseline paths stay turf; arc line drawn as overlay
        else:
            arc = (dm < 95) & (y > 0) & (np.abs(spray) < 52)
            diamond = (np.abs(x) + np.abs(y - BASE) < BASE - 3.5)
            inf_dirt = (arc & ~diamond) | (dm < 9) | (np.hypot(x, y) < 13)
            # dirt lanes home -> 1B / 3B are inside 'arc & ~diamond' already near the bases;
            lane = (np.abs(np.abs(x) - y) < 2.6 * 1.414) & (y > 0) & (y < BASE + 4)
            inf_dirt |= lane
        g = np.where(inf_dirt, dirt, g)
        # mound shading (slight darker rim)
        g = np.where((dm < 9) & (dm > 8), 0.78, g)
        return g.astype(np.float32)
    return fn


CROWD_DENS = {"sparse": 0.35, "light": 0.72, "dark": 0.85, "mixed": 0.8}
ROW_FT, SEAT_FT = 2.8, 2.0


def crowd_shader(st, seed):
    """Seat texture under the crowd. Near rows get people drawn as busts in an overlay pass
    (see draw_crowd); far rows read as a calm row pattern."""
    kind = st.get("crowd", "mixed")
    dens = CROWD_DENS[kind]
    seat_g = st.get("seat", 0.55)
    far_g = {"dark": 0.42, "light": 0.72, "mixed": 0.6, "sparse": 0.75}[kind]

    def fn(P, u, v, pix, Lu, Lv):
        lv = v * Lv
        ly = lv % ROW_FT
        g = np.full(u.shape, 0.5 + 0.4 * seat_g, np.float32)
        g = np.where(ly < 0.6, 0.3, g)
        # far: row-striped average with a gentle per-block variation
        blk = h2(np.floor(u * Lu / 9.0), np.floor(lv / ROW_FT), seed)
        farv = np.where(ly < 1.2, far_g - 0.2, far_g + 0.1)
        return np.where(pix > 0.25, farv, g).astype(np.float32)
    return fn


# Photo crowd: one 512x256 grayscale tile (tools/assets/crowd.py, from LoC Bain crowd photos) covers
# PHOTO_TILE_FT along the row x PHOTO_TILE_FT/2 up the stands slope; horizontally seamless.
PHOTO_TILE_FT = 48.0
_photo_cache = {}


def photo_mips(style):
    if style not in _photo_cache:
        import crowd
        t = crowd.gray_texture(style, "512x256")
        if t is None:
            t = crowd.gray_texture("mixed", "512x256")
        if t is None:
            _photo_cache[style] = None
        else:
            mips = [t]
            for _ in range(4):
                a = mips[-1]
                h, w = a.shape
                mips.append(a.reshape(h // 2, 2, w // 2, 2).mean(axis=(1, 3)))
            _photo_cache[style] = mips
    return _photo_cache[style]


def crowd_uv(x, y, z, frame):
    """Photo-crowd mapping shared by parks.py and parks_geo.py. frame = (ax, ay, tx, ty, s0): U (ft) is
    the arc length along the stands (s0 at the segment start a, unit tangent t), V (ft) is world height,
    so people stay upright and rows stay level instead of being squashed onto the slope."""
    ax, ay, tx, ty, s0 = frame
    return s0 + (np.asarray(x) - ax) * tx + (np.asarray(y) - ay) * ty, z


def seg_frame(a, b, s0):
    t = np.array(b[:2], float) - np.array(a[:2], float)
    L = float(np.linalg.norm(t)) or 1.0
    return (float(a[0]), float(a[1]), float(t[0] / L), float(t[1] / L), float(s0)), L


def photo_crowd_shader(mips, frame):
    texel_ft = PHOTO_TILE_FT / mips[0].shape[1]

    def fn(P, u, v, pix):
        U, V = crowd_uv(P[..., 0], P[..., 1], P[..., 2], frame)
        lvl = np.clip(np.floor(np.log2(np.maximum(pix / texel_ft, 1e-6) * 1.2)), 0, len(mips) - 1).astype(int)
        out = np.zeros(u.shape, np.float32)
        for L, t in enumerate(mips):
            sel = lvl == L
            if not sel.any():
                continue
            h, w = t.shape
            tf = PHOTO_TILE_FT / w
            xi = np.floor(U[sel] / tf).astype(int) % w
            yi = (h - 1 - np.floor(V[sel] / tf).astype(int)) % h   # front row = bottom of the photo
            out[sel] = t[yi, xi]
        return out
    return fn


def make_crowd_poly(a, b, c, d, st, seed, **kw):
    a, b, c, d = (np.asarray(p, float) for p in (a, b, c, d))
    Lu = np.linalg.norm(b - a)
    Lv = np.linalg.norm(d - a)
    style = st.get("crowd", "mixed")
    meta = dict(kind="crowd", seed=seed, Lu=Lu, Lv=Lv, dens=CROWD_DENS[style], style=style)
    mips = photo_mips(style)
    if mips is not None:
        meta["photo"] = True
        return Poly([a, b, c, d], 0.5, photo_crowd_shader(mips, kw.get("frame") or seg_frame(a, b, 0.0)[0]), meta=meta)
    sh = crowd_shader(st, seed)  # drawn fallback when the crowd photos aren't cached
    return Poly([a, b, c, d], 0.5, lambda P, u, v, pix: sh(P, u, v, pix, Lu, Lv), meta=meta)


def draw_crowd(img, ov, cam, crowd_polys, min_r=1.4):
    """Overlay pass: people as little busts (head + shoulders) on near stands rows."""
    d = ImageDraw.Draw(img)
    items = []
    for p in crowd_polys:
        m = p.meta
        A, B, C, D = p.pts
        rows = int(m["Lv"] / ROW_FT)
        near_depth = min([q[2] for q in (cam.project(x) for x in p.pts) if q] or [1e9])
        if 0.5 * cam.scale / near_depth < min_r:
            continue
        rng = np.random.default_rng(m["seed"])
        for r in range(rows):
            t = (r * ROW_FT + 0.9) / m["Lv"]
            r0 = A + (D - A) * t
            r1 = B + (C - B) * t
            Lr = np.linalg.norm(r1 - r0)
            e1 = (r1 - r0) / Lr
            seats = int(Lr / SEAT_FT)
            off = (r % 2) * SEAT_FT * 0.5
            for k in range(seats):
                hv = rng.random(); hv2 = rng.random(); hv3 = rng.random()
                if hv > m["dens"]:
                    continue
                along = k * SEAT_FT + SEAT_FT * 0.5 + off + (hv3 - 0.5) * 0.5
                if along > Lr:
                    continue
                base = r0 + e1 * along
                head = base + np.array([0, 0, 2.4])
                q = cam.project(head)
                if q is None:
                    continue
                rad = 0.48 * cam.scale / q[2]
                if rad < min_r or not (-10 < q[0] < 410 and -10 < q[1] < 250):
                    continue
                qb = cam.project(base + np.array([0, 0, 1.0]))
                if qb is None:
                    continue
                if not ov.visible(qb[0], qb[1], qb[2], 0.08):
                    continue
                items.append((q[2], q, qb, rad, hv, hv2, hv3, m["style"]))
    items.sort(key=lambda t: -t[0])
    for depth, q, qb, rad, hv, hv2, hv3, style in items:
        x, y = q[0], q[1]
        # shoulders
        sw = rad * 1.9
        sy0 = y + rad * 0.9
        sy1 = qb[1] + rad
        if style == "dark":
            shirt = 0 if hv2 < 0.6 else 1
        elif style == "light":
            shirt = 2 if hv2 < 0.6 else (1 if hv2 < 0.85 else 0)
        else:
            shirt = 0 if hv2 < 0.35 else (1 if hv2 < 0.6 else 2)
        box = (x - sw, sy0, x + sw, sy1 + rad * 1.2)
        if rad >= 2.2:
            d.chord(box, 180, 360, fill=255 if shirt == 2 else 0, outline=0)
            if shirt == 1:
                x0, y0, x1, y1 = (int(round(v)) for v in box)
                px = img.load()
                for yy in range(max(0, y0 + 1), min(240, int(sy1 + 1))):
                    for xx in range(max(0, x0 + 1), min(400, x1)):
                        if px[xx, yy] == 0 and (xx + yy) % 2 == 0 and (xx - x) ** 2 / (sw ** 2) + (yy - (y0 + y1) / 2) ** 2 / ((y1 - y0) / 2) ** 2 < 0.8:
                            px[xx, yy] = 255
            # head: face white with dark hair/hat
            d.ellipse((x - rad, y - rad, x + rad, y + rad), fill=255, outline=0)
            if hv3 < 0.45:
                d.chord((x - rad, y - rad, x + rad, y + rad), 180, 360, fill=0)  # hair / cap
                if hv3 < 0.15:
                    d.line((x - rad * 1.6, y, x + rad * 0.2, y), fill=0)  # brim
            if hv < 0.06 and rad >= 2.5:
                # cheering fan: arms up
                d.line((x - sw, sy0 + 1, x - sw - rad * 0.6, y - rad * 2.2), fill=0, width=max(1, int(rad * 0.6)))
                d.line((x + sw, sy0 + 1, x + sw + rad * 0.6, y - rad * 2.2), fill=0, width=max(1, int(rad * 0.6)))
        else:
            # tiny: dark/light head dot over shirt dot
            d.rectangle((x - 1, y + 1, x + 1, y + 2), fill=0 if shirt != 2 else 255)
            d.point((x, y), fill=0 if hv3 < 0.5 else 255)


def board_shader(gray_bg=0.97, gray_fg=0.1):
    """Fake text texture for boards too small for real text."""
    def fn(P, u, v, pix):
        g = np.full(u.shape, gray_bg, np.float32)
        band = (v > 0.3) & (v < 0.7) & (u > 0.12) & (u < 0.88)
        letters = (np.floor(u * 22) % 3) != 2
        g = np.where(band & letters, gray_fg + 0.25, g)
        return g
    return fn


def lights_shader(P, u, v, pix):
    g = np.full(u.shape, 0.15, np.float32)
    cell = ((u * 6) % 1 > 0.2) & ((v * 3) % 1 > 0.2)
    return np.where(cell, 1.0, g)


def windows_shader(base, seed):
    def fn(P, u, v, pix):
        g = np.full(u.shape, base, np.float32)
        wx = (P[..., 0] + P[..., 1]) / 9.0
        wz = P[..., 2] / 11.0
        win = ((wx % 1) > 0.45) & ((wz % 1) > 0.5)
        lit = h2(np.floor(wx), np.floor(wz), seed) < 0.5
        return np.where(win & (pix < 0.6), np.where(lit, base + 0.2, base - 0.2), g)
    return fn


# ------------------------------------------------------------------ sky

def sky_fn(park, st, seed):
    kind = st["sky"]
    rng = np.random.default_rng(seed)
    clouds = [(rng.uniform(-180, 180), rng.uniform(6, 22), rng.uniform(8, 18), rng.uniform(2, 4)) for _ in range(9)]

    def fn(az, el):
        if kind == "night":
            g = np.full(az.shape, 0.03, np.float32)
            stars = (h2(np.floor(az * 9), np.floor(el * 9), 3.0) > 0.996) & (el > 4)
            g = np.where(stars, 1.0, g)
            return g
        top = 0.97 if kind == "day" else 0.86
        g = (top - 0.12 * np.exp(-np.maximum(el, 0) / 12.0)).astype(np.float32)
        for (caz, cel, wa, we) in clouds:
            d = ((az - caz + 180) % 360 - 180) / wa
            e = (el - cel) / we
            puff = d * d + e * e < 1 + 0.35 * np.sin(az * 0.7 + cel)
            g = np.where(puff, 1.0, g)
            g = np.where(puff & (e > 0.5), 0.9, g)
        if st.get("mountains"):
            ridge = 6.5 + 2.6 * np.sin(np.radians(az) * 3 + 1) + 1.0 * np.sin(np.radians(az) * 7 + 2) + 0.5 * np.sin(np.radians(az) * 17)
            ridge = np.maximum(ridge, 0.6)
            g = np.where(el < ridge, 0.66, g)
            g = np.where((el < ridge) & (el > ridge - 0.9) & (ridge > 8.0), 0.98, g)  # snowcaps
            ridge2 = 4.2 + 1.2 * np.sin(np.radians(az) * 5 + 4) + 0.4 * np.sin(np.radians(az) * 13)
            g = np.where(el < ridge2, 0.45, g)
        if st.get("trees"):
            tl = 3.4 + 0.9 * np.abs(np.sin(np.radians(az) * 40)) + 0.3 * np.sin(np.radians(az) * 11)
            g = np.where(el < tl, 0.3, g)
        if kind == "haze":
            g = np.where(el < 3, 0.78, g)
        return g
    return fn


# ------------------------------------------------------------------ scene

def foul_boundary(park):
    """Stands-wall polyline (3B side pole -> behind home -> 1B side pole) in field coords."""
    ft = park["foulTerritory"]
    L, R = park["fences"][0], park["fences"][4]
    d0 = 0.8 * ft + 6
    pts = []
    def side(Lmax, sign):
        res = []
        for k in range(9):
            D = Lmax * (1 - k / 8) if sign < 0 else Lmax * k / 8
            d = d0 * (1 - 0.55 * D / Lmax) + 4
            dirv = np.array([sign * S2, S2]); nrm = np.array([sign * S2, -S2])
            p = D * dirv + d * nrm
            res.append((p[0], p[1]))
        return res
    left = side(L, -1)          # from LF pole toward home
    right = side(R, +1)         # from home toward RF pole
    back = [(-0.45 * ft, -ft), (0.45 * ft, -ft)]
    pts = left + back + right
    return pts


def build_scene(park, st, cam):
    polys = []
    labels = []   # (pts3d, text, fg, bg, fill, fonts)
    lines = []    # (a, b, color, width)
    seed = sum(ord(c) for c in park["abbr"])
    rng = np.random.default_rng(seed)

    # ---------------- outfield wall + bleachers
    n = 32
    sprays = [-45 + 90 * i / n for i in range(n + 1)]
    wall_pts = [(s,) + fence_at(park, s) for s in sprays]
    lf_seats = st.get("lf_seats", True)
    small = st.get("small", False)
    for i in range(n):
        s0, r0, h0 = wall_pts[i]
        s1, r1, h1 = wall_pts[i + 1]
        a, b = spray_pt(s0, r0), spray_pt(s1, r1)
        wall_g = 0.12 if not st.get("wood") else 0.3
        polys.append(quad_poly(a, b, (b[0], b[1], h1), (a[0], a[1], h0), wall_g))
        lines.append(((a[0], a[1], h0), (b[0], b[1], h1), 255, 1))
        seats = not (not lf_seats and s0 < -12)
        depth = 45 if small else 75
        rise = 22 if small else 42
        if seats:
            k0 = (r0 + depth) / r0; k1 = (r1 + depth) / r1
            # bleacher face
            fr, _ = seg_frame(a, b, sum(np.hypot(*(np.array(spray_pt(*wall_pts[j][:2])[:2]) - np.array(spray_pt(*wall_pts[j + 1][:2])[:2])))
                                        for j in range(i)))
            polys.append(make_crowd_poly((a[0], a[1], h0), (b[0], b[1], h1), (b[0] * k1, b[1] * k1, h1 + rise),
                                         (a[0] * k0, a[1] * k0, h0 + rise), st, seed + i, frame=fr))
            # back wall of bleachers
            polys.append(quad_poly((a[0] * k0, a[1] * k0, h0 + rise), (b[0] * k1, b[1] * k1, h1 + rise),
                                   (b[0] * k1, b[1] * k1, h1 + rise + 6), (a[0] * k0, a[1] * k0, h0 + rise + 6), 0.2))
            lines.append(((a[0] * k0, a[1] * k0, h0 + rise + 6), (b[0] * k1, b[1] * k1, h1 + rise + 6), 0, 1))
        else:
            # big wall: add a screen/net above it (Port Ellis) as darker band
            polys.append(quad_poly((a[0], a[1], h0), (b[0], b[1], h1), (b[0], b[1], h1 + 18), (a[0], a[1], h0 + 18), 0.72))
            lines.append(((a[0], a[1], h0 + 18), (b[0], b[1], h1 + 18), 0, 1))
    # wall ad boards + distance markers
    for k, s in enumerate((-33.75, -11.25, 11.25, 33.75)):
        r, h = fence_at(park, s)
        half = math.degrees(13.0 / r)
        ra, _ = fence_at(park, s - half); rb, _ = fence_at(park, s + half)
        inset = 0.4
        a = spray_pt(s - half, ra - inset); b = spray_pt(s + half, rb - inset)
        z0, z1 = h * 0.22, h * 0.82
        pts = [(a[0], a[1], z0), (b[0], b[1], z0), (b[0], b[1], z1), (a[0], a[1], z1)]
        polys.append(Poly(pts, 0.95, board_shader(), bias=0.0))
        labels.append((pts, st["ads"][k % len(st["ads"])], 0, 255, True, ("bold10", "ui", "tiny")))
    for s in (-45, -22.5, 0, 22.5, 45):
        r, h = fence_at(park, s)
        half = math.degrees(6.0 / r)
        a = spray_pt(s - half, r - 0.4); b = spray_pt(s + half, r - 0.4)
        z0, z1 = h * 0.3, min(h * 0.8, h * 0.3 + 6)
        labels.append(([(a[0], a[1], z0), (b[0], b[1], z0), (b[0], b[1], z1), (a[0], a[1], z1)], str(int(round(r))), 255, 0, False,
                       ("big", "bold10", "ui", "tiny")))
    # foul poles
    for s in (-45, 45):
        r, h = fence_at(park, s)
        p = spray_pt(s, r)
        lines.append(((p[0], p[1], 0), (p[0], p[1], h + 55), 255, 2))

    # ---------------- foul-side stands
    bpts = foul_boundary(park)
    # connect poles to boundary ends with short walls
    Lp = spray_pt(-45, park["fences"][0]); Rp = spray_pt(45, park["fences"][4])
    chain = [(Lp[0], Lp[1])] + bpts + [(Rp[0], Rp[1])]
    wall_h = 4.0
    ft = park["foulTerritory"]
    depth = 60 if small else 105
    rise = 26 if small else 52
    centroid = np.array([0.0, 150.0])
    for i in range(len(chain) - 1):
        a, b = np.array(chain[i]), np.array(chain[i + 1])
        polys.append(quad_poly((a[0], a[1], 0), (b[0], b[1], 0), (b[0], b[1], wall_h), (a[0], a[1], wall_h), 0.22))
        lines.append(((a[0], a[1], wall_h), (b[0], b[1], wall_h), 255, 1))
        # outward direction: away from field centroid, perpendicular to segment
        t = b - a; nrm = np.array([t[1], -t[0]]); nrm /= np.linalg.norm(nrm) + 1e-9
        if nrm @ ((a + b) / 2 - centroid) < 0:
            nrm = -nrm
        # use per-vertex normals averaged so stands are continuous
        def vn(j):
            p = np.array(chain[j])
            v = p - centroid
            return v / (np.linalg.norm(v) + 1e-9)
        na, nb = vn(i), vn(i + 1)
        A0 = (a[0], a[1], wall_h); B0 = (b[0], b[1], wall_h)
        A1 = (a[0] + na[0] * depth, a[1] + na[1] * depth, wall_h + rise)
        B1 = (b[0] + nb[0] * depth, b[1] + nb[1] * depth, wall_h + rise)
        fr, _ = seg_frame(a, b, sum(np.hypot(*(np.array(chain[j]) - np.array(chain[j + 1]))) for j in range(i)))
        polys.append(make_crowd_poly(A0, B0, B1, A1, st, seed + 100 + i, frame=fr))
        if st.get("decks", 1) >= 2:
            # upper deck: facade (with ads), seating, roof
            off0, z0 = depth * 0.55, wall_h + rise * 0.55 + 14
            def at(p, nv, off, z):
                return (p[0] + nv[0] * off, p[1] + nv[1] * off, z)
            Fa0, Fb0 = at(a, na, off0, z0), at(b, nb, off0, z0)
            Fa1, Fb1 = at(a, na, off0, z0 + 9), at(b, nb, off0, z0 + 9)
            polys.append(quad_poly(Fa0, Fb0, Fb1, Fa1, 0.9, bias=-0.5))
            # shadow under the deck
            polys.append(quad_poly(at(a, na, off0, z0), at(b, nb, off0, z0), at(b, nb, depth, z0), at(a, na, depth, z0), 0.1))
            Ua1, Ub1 = at(a, na, off0 + 70, z0 + 9 + 40), at(b, nb, off0 + 70, z0 + 9 + 40)
            polys.append(make_crowd_poly(Fa1, Fb1, Ub1, Ua1, st, seed + 300 + i, frame=fr))
            lines.append((Fa1, Fb1, 0, 1)); lines.append((Fa0, Fb0, 0, 1))
        else:
            # back wall/roof band at top of the single deck
            polys.append(quad_poly(A1, B1, (B1[0], B1[1], B1[2] + 8), (A1[0], A1[1], A1[2] + 8), 0.15))
            lines.append(((A1[0], A1[1], A1[2] + 8), (B1[0], B1[1], B1[2] + 8), 0, 1))
    # backstop board text (behind home, faces the field)
    bx = 0.45 * ft
    bk = [(-bx, -ft + 0.3, 0.6), (bx, -ft + 0.3, 0.6), (bx, -ft + 0.3, wall_h - 0.4), (-bx, -ft + 0.3, wall_h - 0.4)]
    # backstop: raise it — taller screen behind home
    polys.append(quad_poly((-bx, -ft, 0), (bx, -ft, 0), (bx, -ft, 9), (-bx, -ft, 9), 0.16, bias=-0.2))
    bk = [(-bx * 0.55, -ft + 0.3, 3.0), (bx * 0.55, -ft + 0.3, 3.0), (bx * 0.55, -ft + 0.3, 7.0), (-bx * 0.55, -ft + 0.3, 7.0)]
    polys.append(Poly(bk, 0.95, board_shader(), bias=-0.4))
    labels.append((bk, st["backstop"], 0, 255, True, ("big", "bold10", "ui", "tiny")))
    lines.append(((-bx, -ft, 9), (bx, -ft, 9), 255, 1))
    # facade ads on upper deck (behind home & down the lines)
    if st.get("decks", 1) >= 2:
        for k, txt in enumerate(st["facade"]):
            j = [len(chain) // 2 - 1, 5, len(chain) - 6][k % 3]
            a, b = np.array(chain[j]), np.array(chain[j + 1])
            def vn2(p):
                v = p - centroid
                return v / (np.linalg.norm(v) + 1e-9)
            na, nb = vn2(a), vn2(b)
            off0, z0 = depth * 0.55, wall_h + rise * 0.55 + 14
            A = (a[0] + na[0] * off0, a[1] + na[1] * off0); B = (b[0] + nb[0] * off0, b[1] + nb[1] * off0)
            mid = ((A[0] + B[0]) / 2, (A[1] + B[1]) / 2)
            dv = np.array(B) - np.array(A); Lseg = np.linalg.norm(dv); dv /= Lseg
            hw = min(Lseg * 0.45, 30)
            inward = -vn2(np.array(mid)) * 0.6
            p0 = (mid[0] - dv[0] * hw + inward[0], mid[1] - dv[1] * hw + inward[1])
            p1 = (mid[0] + dv[0] * hw + inward[0], mid[1] + dv[1] * hw + inward[1])
            pts = [(p0[0], p0[1], z0 + 1), (p1[0], p1[1], z0 + 1), (p1[0], p1[1], z0 + 8), (p0[0], p0[1], z0 + 8)]
            labels.append((pts, txt, 255, 0, True, ("bold10", "ui", "tiny")))
    else:
        # single deck: ad boards along the low stands wall near the dugouts
        for k, txt in enumerate(st["facade"][:2]):
            j = [6, len(chain) - 8][k]
            a, b = np.array(chain[j]), np.array(chain[j + 1])
            dv = b - a; Lseg = np.linalg.norm(dv); dv /= Lseg
            mid = (a + b) / 2
            inward = -(mid - centroid) / np.linalg.norm(mid - centroid) * 0.4
            hw = min(Lseg * 0.48, 22)
            p0 = mid - dv * hw + inward; p1 = mid + dv * hw + inward
            pts = [(p0[0], p0[1], 0.4), (p1[0], p1[1], 0.4), (p1[0], p1[1], wall_h - 0.4), (p0[0], p0[1], wall_h - 0.4)]
            polys.append(Poly(pts, 0.95, board_shader(), bias=-0.3))
            labels.append((pts, txt, 0, 255, True, ("ui", "tiny")))

    # dugouts: dark slots in the stands wall along each line
    for sign in (-1, 1):
        D0, D1 = 55, 95
        d = 0.8 * ft + 6
        for (Da, Db) in ((D0, D1),):
            def bp(D):
                dd = d * (1 - 0.55 * D / park["fences"][0 if sign < 0 else 4]) + 4 - 0.3
                return np.array([sign * S2, S2]) * D + np.array([sign * S2, -S2]) * dd
            a, b = bp(Da), bp(Db)
            polys.append(quad_poly((a[0], a[1], 0), (b[0], b[1], 0), (b[0], b[1], 2.6), (a[0], a[1], 2.6), 0.0, bias=-0.3))

    # ---------------- scoreboard
    sbs = st.get("board_spray", 0)
    r, h = fence_at(park, sbs)
    rr = r + (55 if small else 85)
    c = spray_pt(sbs, rr)
    rot = -math.radians(sbs)
    w_ = 56 if small else 90
    z0 = (22 if small else 40)
    hgt = 26 if small else 42
    polys += box(c[0], c[1], z0, w_, 6, hgt, 0.08, rot=rot, top=0.3)
    # legs
    for dx in (-w_ * 0.35, w_ * 0.35):
        lx = c[0] + dx * math.cos(rot); ly = c[1] + dx * math.sin(rot)
        polys += box(lx, ly, 0, 3, 3, z0, 0.25, rot=rot)
    # scoreboard face text rows (face toward home = -radial side)
    def sbrow(z_a, z_b, text, fonts=("bold10", "ui", "tiny")):
        dirv = np.array([math.cos(rot), math.sin(rot)])
        inward = -np.array(spray_pt(sbs, 1.0)[:2]) * 3.3
        p0 = np.array(c[:2]) - dirv * w_ * 0.45 + inward
        p1 = np.array(c[:2]) + dirv * w_ * 0.45 + inward
        labels.append(([(p0[0], p0[1], z_a), (p1[0], p1[1], z_a), (p1[0], p1[1], z_b), (p0[0], p0[1], z_b)], text, 255, 0, False, fonts))
    sbrow(z0 + hgt * 0.72, z0 + hgt * 0.95, st["board"], ("big", "bold10", "ui", "tiny"))
    sbrow(z0 + hgt * 0.45, z0 + hgt * 0.68, "1 2 3 4 5 6 7 8 9  R H E", ("ui", "tiny"))
    sbrow(z0 + hgt * 0.24, z0 + hgt * 0.44, "0 0 0 0 0 0 0 0 0  0 0 0", ("ui", "tiny"))
    sbrow(z0 + hgt * 0.03, z0 + hgt * 0.22, "0 0 0 0 0 0 0 0 0  0 0 0", ("ui", "tiny"))
    if st.get("bolt"):
        # lightning bolt sign on top of the scoreboard
        bc = np.array(spray_pt(sbs, rr - 3.5))
        dirv = np.array([math.cos(rot), math.sin(rot)])
        def P(dx, z):
            return (bc[0] + dirv[0] * dx, bc[1] + dirv[1] * dx, z)
        top = z0 + hgt
        polys.append(Poly([P(-4, top + 34), P(8, top + 34), P(2, top + 18), P(10, top + 18), P(-8, top - 2), P(-2, top + 14), P(-10, top + 14)][::1], 0.98))

    # ---------------- light towers
    nt = st.get("towers", 0)
    tower_sprays = {4: [-62, -25, 25, 62], 6: [-75, -40, -12, 12, 40, 75]}.get(nt, [])
    for s in tower_sprays:
        if abs(s) > 45:
            # along the foul side, behind the stands
            D = 150 if abs(s) > 70 else 230
            sign = 1 if s > 0 else -1
            p = np.array([sign * S2, S2]) * D + np.array([sign * S2, -S2]) * (0.8 * ft + 6 + (85 if not small else 50))
            p = (p[0], p[1])
        else:
            r, _ = fence_at(park, s)
            p = spray_pt(s, r + (65 if not small else 45))
        topz = 150 if not small else 80
        polys += box(p[0], p[1], 0, 3.5, 3.5, topz, 0.22)
        # light bank facing home
        to = -np.array(p[:2]); to /= np.linalg.norm(to)
        side = np.array([-to[1], to[0]])
        bw = 15 if not small else 10
        c0 = np.array(p[:2]) + to * 2.2
        a = c0 - side * bw; b = c0 + side * bw
        polys.append(Poly([(a[0], a[1], topz - 4), (b[0], b[1], topz - 4), (b[0], b[1], topz + 12), (a[0], a[1], topz + 12)], 0.9, lights_shader))

    # ---------------- flags on outfield bleachers
    if st.get("flags"):
        for s in (-30, -10, 10, 30):
            if not lf_seats and s < -12:
                continue
            r, h = fence_at(park, s)
            k = (r + 75) / r
            p = spray_pt(s, r * k)
            base = h + 42 + 6
            polys += box(p[0], p[1], base, 0.8, 0.8, 26, 0.3)
            polys.append(Poly([(p[0], p[1], base + 26), (p[0] + 9, p[1] + 2, base + 23), (p[0], p[1], base + 20)], 0.1 if s % 20 else 0.95))

    # ---------------- lamplighter lamps (HCL): lampposts on the wall top
    if st.get("lamps"):
        for s in np.linspace(-40, 40, 9):
            r, h = fence_at(park, s)
            p = spray_pt(s, r + 1.5)
            polys += box(p[0], p[1], h, 0.7, 0.7, 10, 0.1)
            polys += box(p[0], p[1], h + 10, 2.2, 2.2, 2.4, 0.98, top=0.1)

    # ---------------- skyline / landmarks (far)
    if st.get("skyline"):
        for k in range(26):
            s = -70 + 140 * k / 25 + rng.uniform(-2, 2)
            rr = rng.uniform(900, 1300)
            p = spray_pt(s, rr)
            hgt = rng.uniform(60, 260)
            wdt = rng.uniform(40, 80)
            polys += box(p[0], p[1], 0, wdt, wdt * 0.8, hgt, 0.82, rot=math.radians(-s), top=0.9,
                         shader=windows_shader(0.8, k))
    if st.get("steeple"):
        p = spray_pt(8, 760)
        polys += box(p[0], p[1], 0, 40, 40, 110, 0.75, top=0.6)
        for i in range(4):
            a0, a1 = math.pi / 2 * i + math.pi / 4, math.pi / 2 * (i + 1) + math.pi / 4
            q = 20 * math.sqrt(2)
            polys.append(Poly([(p[0] + q * math.cos(a0), p[1] + q * math.sin(a0), 110), (p[0] + q * math.cos(a1), p[1] + q * math.sin(a1), 110),
                               (p[0], p[1], 210)], 0.55 if i % 2 else 0.7))
        polys += box(p[0], p[1], 205, 2.5, 2.5, 26, 0.1)
        polys += box(p[0], p[1], 220, 14, 2.5, 2.5, 0.1)
        # rose window: dark disc
        polys.append(facing_disc(cam, (p[0], p[1] - 20.5, 80), 9, 0.15))
        # church body
        polys += box(p[0] + 60, p[1] + 10, 0, 90, 50, 60, 0.7, top=0.5)
    if st.get("cranes"):
        for k, s in enumerate((-40, -24, 52)):
            p = spray_pt(s, 640 + 60 * k)
            hgt = 150 + 20 * k
            polys += box(p[0], p[1], 0, 6, 6, hgt, 0.25)
            polys += box(p[0] + 30, p[1] + 10, hgt, 110, 4, 4, 0.25, rot=0.4)
            polys += box(p[0] - 5, p[1], hgt - 25, 12, 10, 14, 0.3)
        # ship
        p = spray_pt(-10, 820)
        polys += box(p[0], p[1], 0, 260, 40, 30, 0.2, top=0.35)
        polys += box(p[0] + 60, p[1], 30, 60, 30, 30, 0.85, top=0.6, shader=windows_shader(0.8, 4))
        polys += prism(p[0] - 30, p[1], 30, 7, 30, 0.25)
    if st.get("stacks"):
        for k, s in enumerate((-35, -20, 5, 18)):
            p = spray_pt(s, 700 + 90 * (k % 2))
            hgt = 170 + 30 * (k % 3)
            polys += prism(p[0], p[1], 0, 12, hgt, 0.3, r_top=9)
            polys += prism(p[0], p[1], hgt * 0.8, 9.8, 10, 0.95)
            for j in range(4):
                polys.append(facing_disc(cam, (p[0] + 14 * j + 4, p[1] + 3 * j, hgt + 14 + 16 * j), 12 + 6 * j, 0.62 + 0.06 * j, n=10))
        p = spray_pt(-27, 760)
        polys += box(p[0], p[1], 0, 220, 70, 70, 0.4, rot=0.3, top=0.5)
    if st.get("tower_water"):
        s = -30 if park["abbr"] == "CSR" else 35
        p = spray_pt(s, 560)
        for dx in (-9, 9):
            for dy in (-9, 9):
                polys += box(p[0] + dx, p[1] + dy, 0, 1.5, 1.5, 70, 0.2)
        polys += prism(p[0], p[1], 70, 16, 24, 0.85)
        polys += prism(p[0], p[1], 94, 16, 9, 0.6, r_top=1)
        if park["abbr"] == "CSR":
            # windmill
            q = spray_pt(38, 520)
            polys += prism(q[0], q[1], 0, 6, 55, 0.2, n=4, r_top=1.5)
            for k in range(8):
                a = 2 * math.pi * k / 8
                polys.append(Poly([(q[0], q[1] - 2, 55), (q[0] + 13 * math.cos(a), q[1] - 2, 55 + 13 * math.sin(a)),
                                   (q[0] + 13 * math.cos(a + 0.25), q[1] - 2, 55 + 13 * math.sin(a + 0.25))], 0.15))
    if st.get("trees"):
        for k in range(30):
            s = -60 + 120 * k / 29 + rng.uniform(-1.5, 1.5)
            rr = park["fences"][2] + rng.uniform(110, 200)
            p = spray_pt(s, rr)
            hh = rng.uniform(30, 55)
            polys += box(p[0], p[1], 0, 3, 3, hh * 0.5, 0.2)
            polys.append(facing_disc(cam, (p[0], p[1], hh * 0.7), hh * 0.38, 0.18 + 0.1 * rng.random(), n=10))
    return polys, labels, lines


# ------------------------------------------------------------------ cameras

def cameras(park):
    cf = park["fences"][2]
    ft = park["foulTerritory"]
    cams = {}
    # Broadcast CF camera, slightly left of dead center, long lens on the plate.
    ey = max(430.0, cf + 18)
    cams["pitch"] = Camera((-9.0, ey, 64.0), (0.6, 0.0, 3.0), 7.0)
    cams["high_home"] = Camera((0.0, -ft - 95.0, 112.0), (0.0, 190.0, 0.0), 72.0)
    for name, s in (("lf", -28.0), ("cf", 0.0), ("rf", 28.0)):
        r, h = fence_at(park, s)
        eye = spray_pt(s, r + 30, h + 45.0)
        tgt = spray_pt(s * 0.6, 200, 0.0)
        cams[name] = Camera(eye, tgt, 50.0)
    # Bleachers: from shallow foul ground off 1B, looking at the stands down the RF line.
    Rl = park["fences"][4]
    D = 120
    d = (0.8 * ft + 6) * (1 - 0.55 * D / Rl) + 4
    wallp = np.array([S2, S2]) * D + np.array([S2, -S2]) * d
    eye = wallp - np.array([S2, -S2]) * 36 + np.array([S2, S2]) * -14
    tgt = wallp + np.array([S2, -S2]) * 36
    cams["bleachers"] = Camera((eye[0], eye[1], 7.0), (tgt[0], tgt[1], 20.0), 36.0)
    return cams


SPRITE_FT = 6.2  # puppet frame (head top..feet) represents ~6.2 ft; 40 px tall in the 28x44 table


def render_park(park, cam_name, cam):
    st = STYLE[park["abbr"]]
    rnd = Renderer(cam, ss=2)
    seed = sum(ord(c) for c in park["abbr"])
    rnd.sky(sky_fn(park, st, seed))
    rnd.ground(grass_shader(park, st))
    polys, labels, lines = build_scene(park, st, cam)
    rnd.polys(polys)
    img, zbuf, gray = rnd.resolve()
    ov = Overlay(img, zbuf, cam)
    # chalk
    for sign, fi in ((-1, 0), (1, 4)):
        L = park["fences"][fi]
        ov.line3d((0, 0, 0), (sign * L * S2, L * S2, 0), 255)
    # batter's boxes (4x6 ft, 6" from plate edges)
    for sx in (-1, 1):
        x0, x1 = sx * 1.2, sx * 5.2
        for a, b in (((x0, -3, 0), (x1, -3, 0)), ((x0, 3, 0), (x1, 3, 0)), ((x1, -3, 0), (x1, 3, 0)), ((x0, -3, 0), (x0, 3, 0))):
            ov.line3d(a, b, 255)
    # catcher's box
    for a, b in (((-1.8, -3, 0), (-1.8, -9, 0)), ((1.8, -3, 0), (1.8, -9, 0))):
        ov.line3d(a, b, 255)
    if st["mow"] == "turf":
        # infield arc painted on turf
        pts = [(95 * math.sin(math.radians(t)), 60.5 + 95 * math.cos(math.radians(t)), 0) for t in np.linspace(-58, 58, 60)]
        for a, b in zip(pts, pts[1:]):
            ov.line3d(a, b, 0)
    # bases, plate, rubber as filled quads
    d = ImageDraw.Draw(img)
    def fillq(pts3d, color=255, outline=None):
        q = [cam.project(p) for p in pts3d]
        if any(v is None for v in q):
            return
        if not ov.visible(sum(p[0] for p in q) / len(q), sum(p[1] for p in q) / len(q), sum(p[2] for p in q) / len(q), 0.05):
            return
        d.polygon([(p[0], p[1]) for p in q], fill=color, outline=outline)
    for bx, by in ((BASE, BASE), (0, 2 * BASE), (-BASE, BASE)):
        fillq([(bx, by - 1.06, 0), (bx + 1.06, by, 0), (bx, by + 1.06, 0), (bx - 1.06, by, 0)], 255, 0)
    fillq([(-0.71, 0.0, 0), (0.71, 0.0, 0), (0.71, 0.71, 0), (0, 1.42, 0), (-0.71, 0.71, 0)][::-1], 255)
    fillq([(-1, 60.5, 0.6), (1, 60.5, 0.6), (1, 60.67, 0.6), (-1, 60.67, 0.6)], 255)
    for a, b, col, wdt in lines:
        ov.line3d(a, b, col, width=wdt)
    if photo_mips("mixed") is None:  # drawn busts only when the photo crowd is unavailable
        draw_crowd(img, ov, cam, [p for p in polys if p.meta and p.meta.get("kind") == "crowd"])
    for pts, txt, fg, bg, fill, fonts in labels:
        ov.board(pts, txt, fg=fg, bg=bg, fill=fill, fonts=fonts)
    return img


# ------------------------------------------------------------------ JSON spec

REF_PY = '''def project(cam, p):
    """cam: a parks.json camera dict; p: (x, y, z) field feet. Returns (sx, sy, depth) or None."""
    d = [p[i] - cam["eye"][i] for i in range(3)]
    xc = sum(d[i] * cam["right"][i] for i in range(3))
    yc = sum(d[i] * cam["camup"][i] for i in range(3))
    zc = sum(d[i] * cam["forward"][i] for i in range(3))
    if zc < cam["near"]:
        return None
    return (cam["cx"] + cam["scale"] * xc / zc, cam["cy"] - cam["scale"] * yc / zc, zc)
'''

TEST_POINTS = [
    ("home plate", (0, 0, 0)),
    ("pitcher rubber", (0, 60.5, 0)),
    ("pitcher head", (0, 60.5, 6.2)),
    ("1B", (BASE, BASE, 0)),
    ("2B", (0, 2 * BASE, 0)),
    ("3B", (-BASE, BASE, 0)),
    ("ball at 10ft over SS", (-30, 140, 10)),
    ("deep LF", (-150, 250, 0)),
    ("deep RC fly", (120, 300, 60)),
    ("RF line 1B side seats", (180, 60, 20)),
]


def camera_entry(park, name, cam):
    j = cam.to_json()
    # sprite size hints: on-screen height of a 6.2 ft puppet at a few depths
    j["sprite"] = {
        "ft": SPRITE_FT,
        "px_at_depth_100": round(SPRITE_FT * cam.scale / 100.0, 2),
        "rule": "h_px = 6.2 * scale / depth; s = h_px / 40. If s < 1.4 draw the 28x44 table scaled by s "
                "(or unscaled when 0.8 <= s < 1.4); else draw the 56x88 table scaled by s/2. Clamp s >= 0.5 (players are exaggerated in wide shots).",
    }
    tv = []
    for label, p in TEST_POINTS:
        q = cam.project(p)
        tv.append({"label": label, "p": list(p), "expect": None if q is None else [round(q[0], 3), round(q[1], 3), round(q[2], 3)]})
    j["tests"] = tv
    j["image"] = f"images/parks/{park['id']}-{name}"
    return j


CAM_NOTES = {
    "pitch": "Broadcast CF camera behind the pitcher (slightly left of center), long lens on the plate. Puppet scale s ~1.3 (pitcher) / ~1.1 (batter): draw the 1x tables unscaled.",
    "high_home": "High behind home plate (upper deck), whole field. Use for balls in play / overview.",
    "lf": "Elevated camera in the left-field seats (30 ft behind the wall, wall+45 ft up) looking in toward the infield; field visible from ~r-75 ft in. Outfield plays, throws home.",
    "cf": "Elevated camera in the center-field seats (30 ft behind the wall, wall+45 ft up) looking in toward home; field visible from ~r-75 ft in. Outfield plays, throws home.",
    "rf": "Elevated camera in the right-field seats (30 ft behind the wall, wall+45 ft up) looking in toward the infield; field visible from ~r-75 ft in. Outfield plays, throws home.",
    "bleachers": "Close shot of the first-base-side stands from shallow foul ground (crowd incidents, raccoons, streakers).",
}


def build(verbose=True):
    common.ensure_dir(OUT)
    parks = parse_parks()
    spec = {
        "version": 1,
        "coords": "Field feet: home plate origin, +y toward CF, +x toward 1B side, +z up (packages/sim/src/physics.ts).",
        "screen": {"w": W, "h": H, "note": "sx, sy are continuous: pixel (i, j) covers [i, i+1) x [j, j+1); draw at floor()."},
        "projection": [
            "d = p - eye",
            "xc = dot(d, right); yc = dot(d, camup); zc = dot(d, forward)",
            "visible iff zc >= near",
            "sx = cx + scale * xc / zc",
            "sy = cy - scale * yc / zc",
            "where forward = normalize(target - eye), right = normalize(cross(forward, up)), camup = cross(right, forward), up = (0,0,1), scale = (400/2) / tan(fov_x/2)",
        ],
        "sprite_rule": "Puppet on-screen height h_px = 6.2 * scale / depth (depth = zc at the feet). Draw the puppet with its anchor (feet) at (sx, sy) of the ground point. Ball: project (x, y, z); its shadow: project (x, y, 0).",
        "reference_python": REF_PY,
        "cameras": CAM_NOTES,
        "parks": {},
    }
    for park in parks:
        cams = cameras(park)
        entry = {k: park[k] for k in ("name", "abbr", "city", "team", "fences", "walls", "altitudeFt", "foulTerritory", "turf")}
        entry["cams"] = {}
        for name in CAMS:
            cam = cams[name]
            img = render_park(park, name, cam)
            common.save_1bit(img, os.path.join(OUT, f"{park['id']}-{name}.png"))
            entry["cams"][name] = camera_entry(park, name, cam)
        spec["parks"][park["id"]] = entry
        if verbose:
            print("park", park["id"])
    common.write_json(os.path.join(OUT, "parks.json"), spec, indent=None)
    previews(parks, spec)
    composite_preview(spec)
    readme(spec)
    import parks_geo  # live-renderer geometry export (needs the static renders for its preview)
    parks_geo.build(verbose)
    return spec


def previews(parks, spec):
    items = []
    for park in parks:
        for name in CAMS:
            im = Image.open(os.path.join(OUT, f"{park['id']}-{name}.png")).convert("L")
            items.append((im, f"{park['id']} {name}"))
    # two sheets so they stay viewable
    half = (len(parks) // 2) * len(CAMS)
    common.contact_sheet(items[:half], os.path.join(common.PREVIEW, "parks.png"), cols=3)
    common.contact_sheet(items[half:], os.path.join(common.PREVIEW, "parks2.png"), cols=3)


def composite_preview(spec, park_id="park-hcl"):
    """Puppets placed with the parks.json math (exec'd reference function) — proves the projection."""
    pdir = os.path.join(common.IMAGES, "puppets")
    if not os.path.isdir(pdir):
        return
    ns = {}
    exec(spec["reference_python"], ns)
    project = ns["project"]

    def table(k, name):
        import glob
        f = glob.glob(os.path.join(pdir, f"{k}x", name + "-table-*.png"))[0]
        w, h = map(int, re.search(r"-table-(\d+)-(\d+)\.png$", f).groups())
        im = Image.open(f).convert("LA")
        return [im.crop((i * w, 0, (i + 1) * w, h)) for i in range(im.width // w)]

    def put(img, cam, name, frame, p, flip=False, kind="puppet"):
        q = project(cam, p)
        if q is None:
            return
        sx, sy, depth = q
        if kind == "puppet":
            hpx = 6.2 * cam["scale"] / depth
            s = max(0.5, hpx / 40.0)
            if s < 1.4:
                fr = table(1, name)[frame - 1]
                sc = 1.0 if 0.8 <= s < 1.4 else s
                anchor = (14, 42)
            else:
                fr = table(2, name)[frame - 1]
                sc = s / 2
                anchor = (28, 84)
        else:  # ball / shadow / raccoon: fixed sizes at 1x
            fr = table(1, name)[frame - 1]
            sc = 1.0
            anchor = (fr.width // 2, fr.height // 2 if kind == "center" else fr.height - 1)
        if flip:
            fr = fr.transpose(Image.FLIP_LEFT_RIGHT)
        if sc != 1.0:
            fr = fr.resize((max(1, round(fr.width * sc)), max(1, round(fr.height * sc))), Image.NEAREST)
            anchor = (anchor[0] * sc, anchor[1] * sc)
        L, A = fr.split()
        img.paste(L, (int(math.floor(sx - anchor[0])), int(math.floor(sy - anchor[1]))), A)

    shots = []
    cams = spec["parks"][park_id]["cams"]
    B = BASE
    # pitch cam: delivery
    img = Image.open(os.path.join(OUT, f"{park_id}-pitch.png")).convert("L")
    c = cams["pitch"]
    put(img, c, "umpire", 1, (0, -6.5, 0))
    put(img, c, "catcher", 1, (0, -3.5, 0))
    put(img, c, "batter_away", 1, (-3.0, 0.5, 0))
    put(img, c, "pitcher_back", 2, (0, 60.5, 0))
    put(img, c, "ball", 7, (0.5, 40, 5.5), kind="center")
    shots.append(img)
    # high home: defence + runner + fly ball
    img = Image.open(os.path.join(OUT, f"{park_id}-high_home.png")).convert("L")
    c = cams["high_home"]
    for pos in ((B + 5, B + 10), (30, 2 * B + 10), (-30, 2 * B + 12), (-B - 8, B + 8), (-110, 270), (0, 320), (110, 270), (0, 60.5)):
        put(img, c, "fielder", 1, (pos[0], pos[1], 0))
    put(img, c, "catcher", 1, (0, -3.5, 0)); put(img, c, "umpire", 1, (0, -6.5, 0))
    put(img, c, "runner_away", 1, (B - 2, B - 6, 0))
    put(img, c, "shadow", 2, (-70, 230, 0), kind="center")
    put(img, c, "ball", 5, (-70, 230, 70), kind="center")
    shots.append(img)
    # cf cam: catch at the wall
    img = Image.open(os.path.join(OUT, f"{park_id}-cf.png")).convert("L")
    c = cams["cf"]
    put(img, c, "fielder", 2, (40, 2 * B + 15, 0))
    put(img, c, "runner_away", 2, (-25, 2 * B - 25, 0))
    put(img, c, "fielder", 4, (-8, 285, 0), flip=True)
    put(img, c, "shadow", 3, (-12, 291, 0), kind="center")
    put(img, c, "ball", 11, (-12, 291, 11), kind="center")
    put(img, c, "raccoon", 1, (30, 270, 0))
    shots.append(img)
    img = Image.open(os.path.join(OUT, f"{park_id}-bleachers.png")).convert("L")
    c = cams["bleachers"]
    tg = np.array(c["target"]); rt = np.array(c["right"])
    for i, (nm, fr, off, dz) in enumerate((("fan", 4, -40, -2), ("mascot", 2, 0, -14), ("fan", 2, 22, -10))):
        p = tg + rt * off
        put(img, c, nm, fr, (p[0], p[1], p[2] + dz))
    shots.append(img)
    sheet = Image.new("L", (808, 488), 255)
    for i, im in enumerate(shots):
        sheet.paste(im, (4 + (i % 2) * 404, 4 + (i // 2) * 244))
    sheet.save(os.path.join(common.PREVIEW, "ballcast_composite.png"))


def readme(spec):
    ex = spec["parks"]["park-hcl"]["cams"]["pitch"]
    t = f"""## BallCast ballparks (`images/parks/`)

Static 400x240 opaque 1-bit backgrounds, one per park per camera:
`images/parks/<parkId>-<cam>.png` — load with `gfx.image.new("images/parks/park-hcl-pitch")`.

- parkIds: {", ".join(spec["parks"].keys())} (`park-<abbr lowercased>` as in worldgen; `park-farm` is the
  generic "Municipal Field" used for every farm park).
- cams: `pitch`, `high_home`, `lf`, `cf`, `rf`, `bleachers`.
{chr(10).join(f"  - `{k}`: {v}" for k, v in CAM_NOTES.items())}
- Rendered full-frame; the top/bottom ~16 px can be covered by HUD overlays without losing anything important
  (pitch cam keeps the plate area in the middle band).

### parks.json (`images/parks/parks.json`)

```
{{ "version": 1, "coords": "...", "screen": {{"w":400,"h":240}}, "projection": [...], "reference_python": "...",
  "parks": {{ "park-hcl": {{ "name", "abbr", "city", "team", "fences", "walls", "altitudeFt", "foulTerritory", "turf",
      "cams": {{ "pitch": {{ "eye":[x,y,z], "target":[x,y,z], "up":[0,0,1], "fov_x_deg", "cx":200, "cy":120,
                          "scale", "near":1, "right":[..], "camup":[..], "forward":[..],
                          "sprite": {{"ft":6.2, "px_at_depth_100", "rule"}},
                          "tests": [{{"label", "p":[x,y,z], "expect":[sx,sy,depth] | null}}, ...],
                          "image": "images/parks/park-hcl-pitch" }}, ... }} }}, ... }} }}
```

Field coordinates are feet: home plate at the origin, +y toward CF, +x toward the 1B side, +z up
(same as `packages/sim/src/physics.ts`, so `Flight.path` samples project directly).

Projection (pinhole; basis vectors are precomputed in the JSON, so the client needs only dot products):

```
d  = p - eye
xc = dot(d, right);  yc = dot(d, camup);  zc = dot(d, forward)
if zc < near: not visible
sx = cx + scale * xc / zc
sy = cy - scale * yc / zc
```

`sx, sy` are continuous coordinates (pixel (i,j) covers [i,i+1) x [j,j+1)); draw at `math.floor`.
`depth = zc` — sort puppets far-to-near by it. Puppet height on screen `h = 6.2 * scale / depth`
(puppet tables are 40 px from head to feet at 1x): `s = h / 40`; if `s < 1.4` draw the 28x44 table
(unscaled when 0.8 <= s < 1.4, else `drawScaled(s)`), otherwise the 56x88 table at `s / 2`. Clamp `s >= 0.5` (wide shots exaggerate players, like
the mockups). Anchor the
puppet's feet on the projected ground point (x, y, 0). Ball: project (x, y, z); shadow: project (x, y, 0).

Example (park-hcl pitch): eye {ex["eye"]}, target {ex["target"]}, fov_x {ex["fov_x_deg"]}°, scale {ex["scale"]}.
Test vector: home plate (0,0,0) -> {ex["tests"][0]["expect"]}; rubber (0,60.5,0) -> {ex["tests"][1]["expect"]}.
Every camera carries ~10 such `tests` — port the math, then assert |dx|,|dy| < 0.01.

Lua port:

```lua
local function project(c, x, y, z)
  local dx, dy, dz = x - c.eye[1], y - c.eye[2], z - c.eye[3]
  local zc = dx*c.forward[1] + dy*c.forward[2] + dz*c.forward[3]
  if zc < c.near then return nil end
  local xc = dx*c.right[1] + dy*c.right[2] + dz*c.right[3]
  local yc = dx*c.camup[1] + dy*c.camup[2] + dz*c.camup[3]
  return c.cx + c.scale * xc / zc, c.cy - c.scale * yc / zc, zc
end
```

Per-park character: Bellwood (HCL) skyline + gaslamps on the wall, double deck; Sanctuary (STA) church
steeple, dark-clad crowd; Wharf Street (PEM) 25 ft LF wall with net and harbor cranes/ship, no LF seats;
Furnace (MIL) turf + smokestacks; Stockyard (CSR) mountains, water tower, windmill; Corinth Commons (NCG)
double deck, skyline; Plymouth Yard (MRL) wooden walls, tree line; Dynamo (ELC) night game, 6 light towers,
turf, lightning-bolt scoreboard; Municipal Field (farm) small wooden park, water tower, trees.
Wall distance markers are painted from the actual `fences` values. Stands are filled with the real crowd
photos from `images/crowd/` (crowd.py; per-park style mixed/dark/light/sparse), mapped upright (u = arc length
along the stands, v = height) and error-diffused; the earlier drawn head-and-shoulders crowd is only a fallback.
"""
    common.write_readme_part("30-parks.md", t)


if __name__ == "__main__":
    import time
    t0 = time.time()
    only = sys.argv[1:]
    if only:
        parks = [p for p in parse_parks() if p["id"] in only or p["abbr"] in only]
        for park in parks:
            cams = cameras(park)
            for name in CAMS:
                img = render_park(park, name, cams[name])
                common.save_1bit(img, os.path.join(OUT, f"{park['id']}-{name}.png"))
                print(park["id"], name)
    else:
        build()
    print("done in %.1fs" % (time.time() - t0))
