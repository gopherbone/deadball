"""Small z-buffered software renderer in FIELD coordinates for BallCast backgrounds.

Field frame (same as packages/sim/src/physics.ts): feet, home plate at the origin,
+y toward center field, +x toward the first-base side, +z up.

Camera model (this is the exact contract written to parks.json):
    forward = normalize(target - eye)
    right   = normalize(cross(forward, up))      # up = (0, 0, 1)
    camup   = cross(right, forward)
    d  = p - eye
    xc = dot(d, right); yc = dot(d, camup); zc = dot(d, forward)
    visible iff zc >= near
    sx = cx + scale * xc / zc
    sy = cy - scale * yc / zc
    scale = (W / 2) / tan(fov_x / 2)
(sx, sy) are continuous screen coordinates: pixel (i, j) covers [i, i+1) x [j, j+1).

Rendering: ground plane (z = 0) is ray-cast per pixel through a shader; everything else
is convex planar polygons rasterised into a z-buffer at SS x supersampling, each with
a constant gray or a shader(P, u, v) -> gray. The gray buffer is box-downsampled and
ordered-dithered (Bayer 8x8); crisp overlays (chalk lines, outlines, text boards) are
drawn after dithering with a depth test against the downsampled z-buffer.
"""
import math
import numpy as np
from PIL import Image, ImageDraw

import common

W, H = 400, 240


def _norm(v):
    v = np.asarray(v, float)
    return v / (np.linalg.norm(v) + 1e-12)


class Camera:
    def __init__(self, eye, target, fov_x_deg, near=1.0, cx=W / 2, cy=H / 2):
        self.eye = np.array(eye, float)
        self.target = np.array(target, float)
        self.fov = float(fov_x_deg)
        self.near = near
        self.cx, self.cy = cx, cy
        self.f = _norm(self.target - self.eye)
        self.r = _norm(np.cross(self.f, [0.0, 0.0, 1.0]))
        self.u = np.cross(self.r, self.f)
        self.scale = (W / 2) / math.tan(math.radians(self.fov) / 2)

    def to_cam(self, p):
        d = np.asarray(p, float) - self.eye
        return np.array([d @ self.r, d @ self.u, d @ self.f])

    def project(self, p):
        xc, yc, zc = self.to_cam(p)
        if zc < self.near:
            return None
        return (self.cx + self.scale * xc / zc, self.cy - self.scale * yc / zc, zc)

    def to_json(self):
        r = lambda a: [round(float(x), 6) for x in a]
        return {
            "eye": r(self.eye), "target": r(self.target), "up": [0, 0, 1],
            "fov_x_deg": round(self.fov, 4), "cx": self.cx, "cy": self.cy,
            "scale": round(float(self.scale), 4), "near": self.near,
            "right": r(self.r), "camup": r(self.u), "forward": r(self.f),
        }


class Poly:
    __slots__ = ("pts", "gray", "shader", "bias", "meta")

    def __init__(self, pts, gray=0.5, shader=None, bias=0.0, meta=None):
        self.pts = [np.asarray(p, float) for p in pts]
        self.gray = gray
        self.shader = shader
        self.bias = bias
        self.meta = meta


class Renderer:
    def __init__(self, cam, ss=2):
        self.cam = cam
        self.ss = ss
        self.Ws, self.Hs = W * ss, H * ss
        self.scale_s = cam.scale * ss
        self.cxs, self.cys = cam.cx * ss, cam.cy * ss
        jj, ii = np.mgrid[0:self.Hs, 0:self.Ws]
        self.xn = (ii + 0.5 - self.cxs) / self.scale_s
        self.yn = -(jj + 0.5 - self.cys) / self.scale_s
        # world ray directions with forward component 1 (so t == camera depth zc)
        c = cam
        self.dx = self.xn * c.r[0] + self.yn * c.u[0] + c.f[0]
        self.dy = self.xn * c.r[1] + self.yn * c.u[1] + c.f[1]
        self.dz = self.xn * c.r[2] + self.yn * c.u[2] + c.f[2]
        self.gray = np.ones((self.Hs, self.Ws), np.float32)
        self.z = np.full((self.Hs, self.Ws), np.inf, np.float32)
        self.ground_z = np.full((self.Hs, self.Ws), np.inf, np.float32)
        self.mat = np.zeros((self.Hs, self.Ws), np.uint8)  # 1 = photo-crowd surface (error-diffused in resolve)

    # ---- background + ground
    def sky(self, fn):
        """fn(az_deg, el_deg) -> gray array. az 0 = +y, positive toward +x."""
        horiz = np.hypot(self.dx, self.dy)
        az = np.degrees(np.arctan2(self.dx, self.dy))
        el = np.degrees(np.arctan2(self.dz, horiz))
        self.gray[:] = fn(az, el)

    def ground(self, fn):
        """fn(x, y, depth, pix_ft) -> gray (NaN = leave sky)."""
        m = self.dz < -1e-6
        t = np.where(m, -self.cam.eye[2] / np.where(m, self.dz, -1), np.inf)
        x = self.cam.eye[0] + t * self.dx
        y = self.cam.eye[1] + t * self.dy
        pix_ft = t / self.scale_s  # world feet per SS pixel at that depth (approx)
        with np.errstate(all="ignore"):
            g = fn(np.where(m, x, 0), np.where(m, y, 0), t, pix_ft)
        ok = m & np.isfinite(g) & (t < 5000)
        self.gray[ok] = g[ok]
        self.z[ok] = t[ok]
        self.ground_z[ok] = t[ok]

    # ---- polygons
    def _clip(self, cs):
        near = self.cam.near
        out = []
        n = len(cs)
        for i in range(n):
            a, b = cs[i], cs[(i + 1) % n]
            ain, bin_ = a[2] >= near, b[2] >= near
            if ain:
                out.append(a)
            if ain != bin_:
                t = (near - a[2]) / (b[2] - a[2])
                out.append(a + (b - a) * t)
        return out

    def poly(self, p):
        cam = self.cam
        cs = [cam.to_cam(q) for q in p.pts]
        n = np.cross(cs[1] - cs[0], cs[2] - cs[0])
        if np.linalg.norm(n) < 1e-9:
            return
        cl = self._clip(cs)
        if len(cl) < 3:
            return
        pr = [(self.cxs + self.scale_s * c[0] / c[2], self.cys - self.scale_s * c[1] / c[2]) for c in cl]
        xs = [q[0] for q in pr]; ys = [q[1] for q in pr]
        x0, x1 = max(0, int(math.floor(min(xs)))), min(self.Ws, int(math.ceil(max(xs))) + 1)
        y0, y1 = max(0, int(math.floor(min(ys)))), min(self.Hs, int(math.ceil(max(ys))) + 1)
        if x0 >= x1 or y0 >= y1:
            return
        mimg = Image.new("1", (x1 - x0, y1 - y0), 0)
        ImageDraw.Draw(mimg).polygon([(q[0] - x0 - 0.5, q[1] - y0 - 0.5) for q in pr], fill=1)
        mask = np.asarray(mimg, bool)
        if not mask.any():
            return
        d = n @ cs[0]
        xn = self.xn[y0:y1, x0:x1]; yn = self.yn[y0:y1, x0:x1]
        den = n[0] * xn + n[1] * yn + n[2]
        with np.errstate(divide="ignore", invalid="ignore"):
            z = d / den
        z = np.where(np.isfinite(z) & (z > 0), z, np.inf)
        zb = self.z[y0:y1, x0:x1]
        win = mask & (z + p.bias < zb)
        if not win.any():
            return
        if p.shader is not None:
            with np.errstate(all="ignore"):
                P = np.stack([cam.eye[k] + z * (xn * cam.r[k] + yn * cam.u[k] + cam.f[k]) for k in range(3)], -1)
                A = p.pts[0]
                e1 = p.pts[1] - A
                e2 = p.pts[-1] - A
                u = ((P - A) @ e1) / (e1 @ e1)
                v = ((P - A) @ e2) / (e2 @ e2)
                g = p.shader(P, u, v, z / self.scale_s)
        else:
            g = np.full(z.shape, p.gray, np.float32)
        self.gray[y0:y1, x0:x1][win] = np.asarray(g, np.float32)[win] if np.ndim(g) else g
        zb[win] = z[win]
        self.mat[y0:y1, x0:x1][win] = 1 if (p.meta and p.meta.get("photo")) else 0

    def polys(self, plist):
        for p in plist:
            self.poly(p)

    # ---- output
    def resolve(self, matrix=None, levels=8):
        s = self.ss
        g = self.gray.reshape(H, s, W, s).mean(axis=(1, 3))
        if levels:
            # snap to a few gray levels so the ordered dither gives clean regular patterns
            g = np.round(g * levels) / levels
        zmin = self.z.reshape(H, s, W, s).min(axis=(1, 3))
        img = common.bayer(np.clip(g, 0, 1), matrix if matrix is not None else common.BAYER8)
        pm = self.mat.reshape(H, s, W, s).mean(axis=(1, 3)) > 0.5
        if pm.any():
            # photo surfaces (crowd photos): Atkinson on the unquantised gray reads far better than Bayer
            graw = self.gray.reshape(H, s, W, s).mean(axis=(1, 3))
            at = np.asarray(common.atkinson(Image.fromarray((np.clip(graw, 0, 1) * 255).astype(np.uint8), "L")))
            img = np.where(pm, at, img).astype(np.uint8)
        return Image.fromarray(img, "L").copy(), zmin, g


class Overlay:
    """Crisp 1x post-dither drawing with depth tests."""

    def __init__(self, img, zbuf, cam):
        self.img = img
        self.px = img.load()
        self.z = zbuf
        self.cam = cam

    def visible(self, x, y, depth, tol=0.03):
        xi, yi = int(x), int(y)
        if not (0 <= xi < W and 0 <= yi < H):
            return False
        return depth <= self.z[yi, xi] * (1 + tol) + 0.5

    def line3d(self, a, b, color=255, tol=0.03, step=0.5, width=1):
        cam = self.cam
        a, b = np.asarray(a, float), np.asarray(b, float)
        ca, cb = cam.to_cam(a), cam.to_cam(b)
        near = cam.near
        if ca[2] < near and cb[2] < near:
            return
        if ca[2] < near:
            t = (near - ca[2]) / (cb[2] - ca[2]); a = a + (b - a) * t
        elif cb[2] < near:
            t = (near - cb[2]) / (ca[2] - cb[2]); b = b + (a - b) * t
        pa, pb = cam.project(a), cam.project(b)
        if pa is None or pb is None:
            return
        n = int(max(abs(pb[0] - pa[0]), abs(pb[1] - pa[1])) / step) + 2
        for i in range(n + 1):
            t = i / n
            P = a + (b - a) * t
            q = cam.project(P)
            if q is None:
                continue
            if self.visible(q[0], q[1], q[2], tol):
                xi, yi = int(q[0]), int(q[1])
                for k in range(width):
                    if 0 <= xi + k < W:
                        self.px[xi + k, yi] = color

    def quad_screen(self, pts3d):
        q = [self.cam.project(p) for p in pts3d]
        if any(v is None for v in q):
            return None
        return q

    def board(self, pts3d, text, fg=0, bg=255, fonts=("big", "bold10", "ui", "tiny"), min_h=6, fill=True, pad=1):
        """Paint a text board: fill projected quad with bg, draw text in fg centered.
        pts3d: 4 corners (bottom-left, bottom-right, top-right, top-left) as seen from front."""
        q = self.quad_screen(pts3d)
        if q is None:
            return False
        cxp = sum(p[0] for p in q) / 4; cyp = sum(p[1] for p in q) / 4
        depth = sum(p[2] for p in q) / 4
        if not self.visible(cxp, cyp, depth, 0.05):
            return False
        xs = [p[0] for p in q]; ys = [p[1] for p in q]
        h = (abs(q[3][1] - q[0][1]) + abs(q[2][1] - q[1][1])) / 2
        w = (abs(q[1][0] - q[0][0]) + abs(q[2][0] - q[3][0])) / 2
        if fill:
            d = ImageDraw.Draw(self.img)
            d.polygon([(p[0], p[1]) for p in q], fill=bg)
        if h < min_h or w < 6:
            return True
        for fk in fonts:
            f = common.font(fk)
            if any(ch not in f.widths for ch in text):
                continue
            # visible cap height ~ 70% of cell height for these fonts
            if f.ch * 0.72 <= h - pad and f.width(text) <= w - 2:
                ty = int(round(cyp - f.ch / 2 + (1 if f.ch < 14 else 0)))
                f.draw(self.img, (int(round(cxp - f.width(text) / 2)), ty), text, fg)
                return True
        return True
