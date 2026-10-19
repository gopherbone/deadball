"""DBN SPIN CAM: prerendered rotating baseball frames for BallCast's TV package.

    python3 tools/tv/spin_ball.py
      -> playdate/source/images/tv/spin-table-40-40.png   (6 rows x 24 frames, LA PNG)
      -> tools/tv/preview/spin_*.gif                       (previews, 4x)

Rows (BallCast.TVSpin.ROWS): 1 four-seam backspin, 2 two-seam backspin, 3 curve (tilted
topspin), 4 gyro (slider / cutter: the axis points at the viewer, tilted), 5 changeup (slow,
tilted arm-side tumble; played slowly), 6 knuckler (no spin, a wobble back and forth).

The ball: an orthographic sphere with the classic seam curve (two lobes of a "tennis ball"
curve, a + b = 1 so it lies on the sphere), a double row of stitches across it, shading from
the upper left, ordered-dithered to 1 bit, with a crisp black outline. Original art.
"""
import math
import os

from PIL import Image

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.abspath(os.path.join(HERE, "..", ".."))
OUT = os.path.join(ROOT, "playdate", "source", "images", "tv", "spin-table-40-40.png")
PREV = os.path.join(HERE, "preview")

N = 24            # frames per row
S = 40            # cell size
R = 17.5          # ball radius in px
SS = 4            # supersampling

BAYER8 = [[0, 32, 8, 40, 2, 34, 10, 42], [48, 16, 56, 24, 50, 18, 58, 26], [12, 44, 4, 36, 14, 46, 6, 38],
          [60, 28, 52, 20, 62, 30, 54, 22], [3, 35, 11, 43, 1, 33, 9, 41], [51, 19, 59, 27, 49, 17, 57, 25],
          [15, 47, 7, 39, 13, 45, 5, 37], [63, 31, 55, 23, 61, 29, 53, 21]]


def seam(n=360, a=0.7, b=0.3):
    """the seam: points on the unit sphere (x, y, z) and their tangents"""
    k = 2 * math.sqrt(a * b)
    pts = []
    for i in range(n):
        t = 2 * math.pi * i / n
        p = (a * math.cos(t) + b * math.cos(3 * t), a * math.sin(t) - b * math.sin(3 * t), k * math.sin(2 * t))
        d = (-a * math.sin(t) - 3 * b * math.sin(3 * t), a * math.cos(t) - 3 * b * math.cos(3 * t), 2 * k * math.cos(2 * t))
        pts.append((p, d))
    return pts


def rot(axis, ang):
    x, y, z = axis
    l = math.sqrt(x * x + y * y + z * z)
    x, y, z = x / l, y / l, z / l
    c, s = math.cos(ang), math.sin(ang)
    C = 1 - c
    return ((c + x * x * C, x * y * C - z * s, x * z * C + y * s),
            (y * x * C + z * s, c + y * y * C, y * z * C - x * s),
            (z * x * C - y * s, z * y * C + x * s, c + z * z * C))


def mul(m, v):
    return tuple(m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] for i in range(3))


def mm(a, b):
    return tuple(tuple(sum(a[i][k] * b[k][j] for k in range(3)) for j in range(3)) for i in range(3))


def frame(m):
    """one 40x40 LA image of the ball oriented by rotation matrix m (viewer looks down -z)"""
    W = S * SS
    cx = cy = W / 2
    rr = R * SS
    # shading + seams in a float buffer (1 = white)
    buf = [[None] * W for _ in range(W)]
    lx, ly, lz = -0.45, -0.55, 0.7       # light from the upper left, toward the viewer
    ll = math.sqrt(lx * lx + ly * ly + lz * lz)
    lx, ly, lz = lx / ll, ly / ll, lz / ll
    for j in range(W):
        for i in range(W):
            x, y = (i + 0.5 - cx) / rr, (j + 0.5 - cy) / rr
            d2 = x * x + y * y
            if d2 <= 1:
                z = math.sqrt(1 - d2)
                lam = max(0.0, x * lx + y * ly + z * lz)
                buf[j][i] = 0.55 + 0.55 * lam
    # seams: project each seam point; front-facing ones stamp the seam line and the stitches
    mark = [[False] * W for _ in range(W)]

    def dot(px, py, rad):
        r2 = rad * rad
        for yy in range(int(py - rad), int(py + rad) + 1):
            for xx in range(int(px - rad), int(px + rad) + 1):
                if 0 <= xx < W and 0 <= yy < W and (xx - px) ** 2 + (yy - py) ** 2 <= r2 and buf[yy][xx] is not None:
                    mark[yy][xx] = True

    sp = seam()
    for idx, (p, d) in enumerate(sp):
        q = mul(m, p)
        if q[2] <= 0.05:
            continue
        qd = mul(m, d)
        px, py = cx + q[0] * rr, cy + q[1] * rr
        fore = 0.4 + 0.6 * q[2]           # thinner toward the limb
        dot(px, py, 0.9 * SS * fore)
        if idx % 12 == 0:
            # a stitch: a short tick across the seam (perpendicular in screen space), both sides
            tx, ty = qd[0], qd[1]
            tl = math.hypot(tx, ty) or 1
            nx, ny = -ty / tl, tx / tl
            for side in (-1, 1):
                for k in range(4):
                    f = 0.9 + k * 0.55
                    dot(px + side * nx * f * SS * fore - tx / tl * k * 0.5 * SS * fore,
                        py + side * ny * f * SS * fore - ty / tl * k * 0.5 * SS * fore, 0.7 * SS * fore)
    # downsample + dither + outline
    img = Image.new("LA", (S, S), (0, 0))
    px = img.load()
    for j in range(S):
        for i in range(S):
            cov, lum, seamc = 0, 0.0, 0
            for b in range(SS):
                for a in range(SS):
                    v = buf[j * SS + b][i * SS + a]
                    if v is not None:
                        cov += 1
                        lum += v
                        if mark[j * SS + b][i * SS + a]:
                            seamc += 1
            if cov == 0:
                continue
            n = SS * SS
            if cov < n * 0.35:
                continue
            lum /= cov
            # the outline: pixels on the rim
            x, y = (i + 0.5 - S / 2) / R, (j + 0.5 - S / 2) / R
            rim = math.sqrt(x * x + y * y) > 1 - 1.3 / R
            if rim or seamc > n * 0.3:
                px[i, j] = (0, 255)
                continue
            thr = (BAYER8[j % 8][i % 8] + 0.5) / 64
            px[i, j] = (255 if lum > thr else 0, 255)
    return img


def rows():
    """six rotation sequences of N frames each"""
    base4 = rot((0, 1, 0), math.pi / 2)              # four-seam: seams cross the spin axis 4x
    base2 = rot((0, 0, 1), 0.0)
    out = []
    # 1 four-seam backspin: axis = screen x, the top comes toward the viewer
    out.append([mm(rot((1, 0, 0), -2 * math.pi * f / N), base4) for f in range(N)])
    # 2 two-seam backspin, axis tilted a little arm-side
    out.append([mm(rot((1, 0.25, 0), -2 * math.pi * f / N), base2) for f in range(N)])
    # 3 curve: topspin on a tilted axis
    out.append([mm(rot((1, -0.55, 0), 2 * math.pi * f / N), base4) for f in range(N)])
    # 4 gyro (slider / cutter): axis mostly at the viewer, tilted
    out.append([mm(rot((0.35, 0.3, 1), 2 * math.pi * f / N), base2) for f in range(N)])
    # 5 changeup: arm-side tilted tumble (played slowly)
    out.append([mm(rot((1, 0.8, 0.2), -2 * math.pi * f / N), base2) for f in range(N)])
    # 6 knuckler: no spin; a wobble, back and forth (loops seamlessly)
    out.append([mm(rot((0.6, 1, 0.3), 0.35 * math.sin(2 * math.pi * f / N)), base4) for f in range(N)])
    return out


def main():
    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    os.makedirs(PREV, exist_ok=True)
    seqs = rows()
    sheet = Image.new("LA", (S * N, S * len(seqs)), (0, 0))
    names = ["four", "two", "curve", "gyro", "change", "knuckle"]
    for r, seq in enumerate(seqs):
        frames = []
        for f, m in enumerate(seq):
            im = frame(m)
            sheet.paste(im, (f * S, r * S))
            pv = Image.new("L", (S, S), 140)
            pv.paste(im.convert("L"), (0, 0), im.split()[1])
            frames.append(pv.resize((S * 4, S * 4), Image.NEAREST))
        frames[0].save(os.path.join(PREV, f"spin_{names[r]}.gif"), save_all=True, append_images=frames[1:], duration=60, loop=0)
    sheet.save(OUT)
    print(OUT, sheet.size)


if __name__ == "__main__":
    main()
