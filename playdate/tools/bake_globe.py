#!/usr/bin/env python3
"""Bake the Pennant road map's planet (the geoscape, pennant/ui/roadmap.lua) into
source/pennant/globedata.lua (the globe.bin bytes below as one Lua string: pdc leaves unknown file
types out of the .pdx). Run again only when the clubs' planet positions (clubs.lua `gl`) change.

The planet is the approved mockup's (docs: the Geoscape road map concept), generated once:
  - fractal value noise on the sphere (4 octaves), plus a gaussian bump under every club city and a
    few anchors (a filler on the home continent, the far continent) so every city stands on land;
  - landmasses under 160 cells (3.75 deg) are culled unless a club or an anchor is on them;
  - biomes from a second noise field: grassland, desert (dry and below 38 deg, a step lighter),
    forest (wet, a step darker); no ice caps;
  - the mesh: 15-degree lat/lon quads, each two flat facets (A = lower-right a,b,c; B = a,c,d); land
    is cut across each facet's 7.5-degree sub-triangles where the bilinear land field crosses zero
    (marching triangles), so coasts are straight segments running across the mesh.

Land pieces and coast segments are stored in facet coordinates (u = lon, v = lat across the quad,
0..240), so on the device they lie flat on their facet and tile it exactly.

globe.bin (little endian):
  "GLB1"
  u16 nQuads (12 x 24, lat-major from the south pole, lon from -180)
    per quad: u8 facetA, u8 facetB   (0 sea / 1 grass / 2 desert / 4 forest: the whole facet;
                                      254: land pieces cover it; 255: sea, then land pieces)
  u16 nPieces, per piece: u16 quad, u8 kind, u8 n, n x (u8 u, u8 v)   (sorted by quad)
  u16 nCoast, per segment: u16 quad, u8 u1, v1, u2, v2

Usage: python3 playdate/tools/bake_globe.py [--preview out.png]
"""
import math
import os
import re
import struct
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "source")
OUT = os.path.join(SRC, "pennant", "globedata.lua")

ST = 15                 # facet quad size (deg)
H = ST / 4              # planet cell size (deg)
TH = ST / 2             # sub-triangle size
Q = 240                 # facet coordinate resolution
D = math.pi / 180
# extra land seeds: a filler between the home continent's cities, and the far continent
ANCHORS = [(-20, 5), (128, 18), (150, -22)]


def clubs():
    """[(abbr, lon, lat)] from clubs.lua's gl fields."""
    txt = open(os.path.join(SRC, "pennant", "clubs.lua")).read()
    out = []
    for m in re.finditer(r'abbr = "(\w+)".*?gl = \{ *(-?[\d.]+), *(-?[\d.]+) *\}', txt, re.S):
        out.append((m.group(1), float(m.group(2)), float(m.group(3))))
    assert len(out) == 8, out
    return out


def world(lon, lat):
    p, q = lat * D, lon * D
    return (math.cos(p) * math.cos(q), math.cos(p) * math.sin(q), math.sin(p))


def hsh(x, y, z):
    s = math.sin(x * 127.1 + y * 311.7 + z * 74.7) * 43758.5453
    return s - math.floor(s)


def sm(t):
    return t * t * (3 - 2 * t)


def noise(x, y, z):
    ix, iy, iz = math.floor(x), math.floor(y), math.floor(z)
    fx, fy, fz = sm(x - ix), sm(y - iy), sm(z - iz)

    def lerp(a, b, t):
        return a + (b - a) * t

    def c(dx, dy, dz):
        return hsh(ix + dx, iy + dy, iz + dz)
    return lerp(lerp(lerp(c(0, 0, 0), c(1, 0, 0), fx), lerp(c(0, 1, 0), c(1, 1, 0), fx), fy),
                lerp(lerp(c(0, 0, 1), c(1, 0, 1), fx), lerp(c(0, 1, 1), c(1, 1, 1), fx), fy), fz)


def fbm(v, k, o):
    s, a, fr = 0.0, 0.5, k
    for _ in range(4):
        s += a * noise(v[0] * fr + o, v[1] * fr + o, v[2] * fr + o)
        fr *= 2
        a *= 0.5
    return s


def planet(cities):
    seeds = [(lon, lat) for _, lon, lat in cities] + ANCHORS
    anchors = [world(lon, lat) for lon, lat in seeds]
    nLat, nLon = round(180 / H), round(360 / H)
    kind, ev = [], []
    for j in range(nLat):
        row, erow = [], []
        for i in range(nLon):
            lat, lon = -90 + (j + 0.5) * H, -180 + (i + 0.5) * H
            v = world(lon, lat)
            bias = 0.0
            for a in anchors:
                ang = math.acos(max(-1, min(1, v[0] * a[0] + v[1] * a[1] + v[2] * a[2])))
                bias += 0.24 * math.exp(-(ang / 0.3) ** 2)
            e = fbm(v, 2.1, 3.1) - 0.5 + min(0.3, bias) - 0.03
            erow.append(e)
            if e <= 0:
                row.append(0)
                continue
            dry = fbm(v, 3.2, 21.3)
            row.append(2 if abs(lat) < 38 and dry > 0.54 else (4 if dry < 0.44 else 1))
        kind.append(row)
        ev.append(erow)
    # cull the small landmasses: keep one if it's big or a club (or an anchor) is on it
    keep = set()
    for lon, lat in seeds:
        keep.add((int((lat + 90) // H), int((lon + 180) // H)))
    seen = [[False] * nLon for _ in range(nLat)]
    for j in range(nLat):
        for i in range(nLon):
            if seen[j][i] or kind[j][i] == 0:
                continue
            stack, comp, city = [(j, i)], [], False
            seen[j][i] = True
            while stack:
                c = stack.pop()
                comp.append(c)
                if c in keep:
                    city = True
                for dj, di in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    y, x = c[0] + dj, (c[1] + di) % nLon
                    if y < 0 or y >= nLat or seen[y][x] or kind[y][x] == 0:
                        continue
                    seen[y][x] = True
                    stack.append((y, x))
            if not city and len(comp) < 160:
                for (y, x) in comp:
                    kind[y][x] = 0
                    ev[y][x] = min(ev[y][x], -0.06)
    return kind, ev, nLat, nLon


def bake(cities):
    kind, ev, nLat, nLon = planet(cities)

    def kindAt(j, i):
        return 0 if j < 0 or j >= nLat else kind[j][i % nLon]

    def evAt(j, i):
        return ev[max(0, min(nLat - 1, j))][i % nLon]

    def field(la, lo):
        y, x = (la + 90) / H - 0.5, (lo + 180) / H - 0.5
        j, i = math.floor(y), math.floor(x)
        fy, fx = y - j, x - i
        return ((evAt(j, i) * (1 - fx) + evAt(j, i + 1) * fx) * (1 - fy)
                + (evAt(j + 1, i) * (1 - fx) + evAt(j + 1, i + 1) * fx) * fy)

    def triKind(la, lo, t):
        cla, clo = la + TH * (2 / 3 if t else 1 / 3), lo + TH * (1 / 3 if t else 2 / 3)
        return kindAt(math.floor((cla + 90) / H), math.floor((clo + 180) / H))

    quads, pieces, coast = [], [], []
    qi = 0
    for lat in range(-90, 90, ST):
        for lon in range(-180, 180, ST):
            per = {0: [], 1: []}       # facet -> [(kind, [(u, v)...], full)]
            for sj in range(2):
                for si in range(2):
                    la, lo = lat + sj * TH, lon + si * TH
                    tris = [[(la, lo), (la, lo + TH), (la + TH, lo + TH)], [(la, lo), (la + TH, lo + TH), (la + TH, lo)]]
                    for t, tv in enumerate(tris):
                        facet = 0 if si > sj else (1 if si < sj else t)
                        k = triKind(la, lo, t)
                        fv = [field(a, b) for a, b in tv]
                        inside = [x > 0 for x in fv]
                        n = sum(inside)
                        if n == 0:
                            per[facet].append((0, None, True))
                            continue
                        if not k:
                            k = 1
                        if n == 3:
                            per[facet].append((k, tv, True))
                            continue
                        poly, cut = [], []
                        for e in range(3):
                            A, B, fa, fb = tv[e], tv[(e + 1) % 3], fv[e], fv[(e + 1) % 3]
                            if inside[e]:
                                poly.append(A)
                            if inside[e] != inside[(e + 1) % 3]:
                                u = fa / (fa - fb)
                                X = (A[0] + (B[0] - A[0]) * u, A[1] + (B[1] - A[1]) * u)
                                poly.append(X)
                                cut.append(X)
                        per[facet].append((k, poly, False))
                        if len(cut) == 2:
                            coast.append((qi, cut))

            def uv(p):
                return (round((p[1] - lon) / ST * Q), round((p[0] - lat) / ST * Q))
            codes = []
            for facet in (0, 1):
                subs = per[facet]
                kinds = {k for k, _, full in subs if full}
                if all(full for _, _, full in subs) and len(kinds) == 1:
                    codes.append(kinds.pop())           # the whole facet one kind (sea or land)
                    continue
                anySea = any(k == 0 or not full for k, _, full in subs)
                codes.append(255 if anySea else 254)
                for k, poly, full in subs:
                    if k == 0:
                        continue
                    pieces.append((qi, k, [uv(p) for p in poly]))
            quads.append(codes)
            qi += 1
    out = bytearray(b"GLB1")
    out += struct.pack("<H", len(quads))
    for a, b in quads:
        out += struct.pack("<BB", a, b)
    out += struct.pack("<H", len(pieces))
    for q, k, pts in pieces:
        out += struct.pack("<HBB", q, k, len(pts))
        for u, v in pts:
            out += struct.pack("<BB", u, v)
    out += struct.pack("<H", len(coast))
    for q, cut in coast:
        a = (round((cut[0][1] - (-180 + (q % 24) * ST)) / ST * Q), round((cut[0][0] - (-90 + (q // 24) * ST)) / ST * Q))
        b = (round((cut[1][1] - (-180 + (q % 24) * ST)) / ST * Q), round((cut[1][0] - (-90 + (q // 24) * ST)) / ST * Q))
        out += struct.pack("<HBBBB", q, a[0], a[1], b[0], b[1])
    return bytes(out), quads, pieces, coast, kind


def preview(path, quads, pieces, coast, cities, lon0=10, lat0=5):
    """A 400x240 orthographic look at the baked mesh (the device's shading)."""
    from PIL import Image, ImageDraw
    S = 2
    img = Image.new("L", (400 * S, 240 * S), 40)
    dr = ImageDraw.Draw(img)
    cx, cy, R = 142 * S, 132 * S, 112 * S
    l0, p0 = lon0 * D, lat0 * D
    X = (-math.sin(l0), math.cos(l0), 0)
    Y = (-math.sin(p0) * math.cos(l0), -math.sin(p0) * math.sin(l0), math.cos(p0))
    Z = (math.cos(p0) * math.cos(l0), math.cos(p0) * math.sin(l0), math.sin(p0))

    def rot(lon, lat):
        w = world(lon, lat)
        return (sum(a * b for a, b in zip(w, X)), sum(a * b for a, b in zip(w, Y)), sum(a * b for a, b in zip(w, Z)))
    BASE, GAIN = [0.06, 0.3, 0.42, 0.52, 0.18], [0.62, 0.75, 0.75, 0.7, 0.75]

    def shade(lit, k):
        lv = max(0, min(8, round((1 - (BASE[k] + GAIN[k] * lit)) * 8)))
        return int(40 + (1 - lv / 8) * 200)
    dr.ellipse((cx - R, cy - R, cx + R, cy + R), fill=40)
    byq = {}
    for q, k, pts in pieces:
        byq.setdefault(q, []).append((k, pts))
    cuts = {}
    for q, cut in coast:
        cuts.setdefault(q, []).append(cut)
    for qi, (fa, fb) in enumerate(quads):
        la, lo = -90 + (qi // 24) * ST, -180 + (qi % 24) * ST
        c4 = [rot(lo, la), rot(lo + ST, la), rot(lo + ST, la + ST), rot(lo, la + ST)]
        if any(p[2] < 0 for p in c4):
            continue
        P = [(cx + R * p[0], cy - R * p[1]) for p in c4]

        def at(u, v):
            u, v = u / Q, v / Q
            if v <= u:
                return (P[0][0] + u * (P[1][0] - P[0][0]) + v * (P[2][0] - P[1][0]), P[0][1] + u * (P[1][1] - P[0][1]) + v * (P[2][1] - P[1][1]))
            return (P[0][0] + v * (P[3][0] - P[0][0]) + u * (P[2][0] - P[3][0]), P[0][1] + v * (P[3][1] - P[0][1]) + u * (P[2][1] - P[3][1]))
        lits = []
        for tri in ((0, 1, 2), (0, 2, 3)):
            s = [sum(c4[i][d] for i in tri) for d in range(3)]
            w = [sum(world(*[(lo, la), (lo + ST, la), (lo + ST, la + ST), (lo, la + ST)][i])[d] for i in tri) for d in range(3)]
            lits.append(max(0, s[2] / math.sqrt(sum(x * x for x in w))))
        for f, code, tri in ((0, fa, (0, 1, 2)), (1, fb, (0, 2, 3))):
            if code != 254:
                dr.polygon([P[i] for i in tri], fill=shade(lits[f], 0 if code == 255 else code))
        for k, pts in byq.get(qi, []):
            u0 = sum(p[0] for p in pts) / len(pts)
            v0 = sum(p[1] for p in pts) / len(pts)
            f = 0 if v0 <= u0 else 1
            dr.polygon([at(*p) for p in pts], fill=shade(lits[f], k))
        for cut in cuts.get(qi, []):
            a = ((cut[0][1] - lo) / ST * Q, (cut[0][0] - la) / ST * Q)
            b = ((cut[1][1] - lo) / ST * Q, (cut[1][0] - la) / ST * Q)
            dr.line([at(*a), at(*b)], fill=40, width=S)
    for abbr, lon, lat in cities:
        p = rot(lon, lat)
        if p[2] > 0.1:
            x, y = cx + R * p[0], cy - R * p[1]
            dr.ellipse((x - 4 * S, y - 4 * S, x + 4 * S, y + 4 * S), fill=230, outline=40, width=S)
            dr.text((x + 6 * S, y - 4 * S), abbr, fill=20)
    img.save(path)


def main():
    cities = clubs()
    data, quads, pieces, coast, kind = bake(cities)

    def esc(b):
        c = chr(b)
        if c == '"' or c == "\\":
            return "\\" + c
        if 32 <= b < 127:
            return c
        return "\\%03d" % b
    body = "".join(esc(b) for b in data)
    # lines of ~100 chars, split only between escapes (a cut inside one would change its meaning)
    out, cur = [], ""
    for ch in re.findall(r'\\\d{3}|\\.|.', body):
        cur += ch
        if len(cur) >= 100:
            out.append(cur)
            cur = ""
    if cur:
        out.append(cur)
    with open(OUT, "w") as f:
        f.write("-- Generated by tools/bake_globe.py: the road map's planet (globe.bin format, see there).\n")
        f.write("-- Do not edit; re-run the tool.\n")
        f.write("PGlobeData = table.concat({\n")
        for ln in out:
            f.write('  "' + ln + '",\n')
        f.write("})\n")
    land = sum(1 for r in kind for k in r if k)
    print(f"globedata.lua: {len(data)} bytes, {len(pieces)} land pieces, {len(coast)} coast segments, land {land * 100 // (len(kind) * len(kind[0]))}% of cells")
    if "--preview" in sys.argv:
        p = sys.argv[sys.argv.index("--preview") + 1]
        preview(p, quads, pieces, coast, cities)
        base, ext = os.path.splitext(p)
        preview(base + "_far" + ext, quads, pieces, coast, cities, lon0=140, lat0=0)
        print("preview:", p)


if __name__ == "__main__":
    main()
