"""BallCast billboard puppets: crude 1-bit figures with black contour + white halo.

Run standalone: python3 tools/assets/puppets.py
Outputs playdate/source/images/puppets/{1x,2x}/<name>-table-W-H.png (LA PNG, alpha = mask).
Every pose is defined once in a 28x44 design space (feet on y = 42, centred on x = 14) and
re-drawn (not upscaled) at 2x so close shots stay clean.
"""
import os, sys, math
import numpy as np
from PIL import Image, ImageDraw, ImageFilter

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import common

OUT = os.path.join(common.IMAGES, "puppets")
SW, SH = 28, 44
GRAY = 128  # marker colour -> 50% checker after drawing


def P(**kw):
    return kw


# ------------------------------------------------------------------ poses
# joints: head neck hip lknee rknee lfoot rfoot lelb relb lhand rhand ; face: -1 left, 0 front, 1 right, 'back'
POSES = {
    # pitcher seen from behind (CF camera)
    "pb_set": P(head=(14, 6), neck=(14, 10), hip=(14, 23), lknee=(11, 32), rknee=(17, 32), lfoot=(11, 41), rfoot=(17, 41),
                lelb=(9, 15), relb=(19, 15), lhand=(13, 18), rhand=(15, 18), face="back"),
    "pb_kick": P(head=(13, 6), neck=(13, 10), hip=(14, 23), lknee=(13, 32), rknee=(21, 21), lfoot=(13, 41), rfoot=(19, 30),
                 lelb=(8, 13), relb=(19, 14), lhand=(11, 10), rhand=(15, 10), face="back"),
    "pb_release": P(head=(11, 9), neck=(12, 13), hip=(15, 24), lknee=(8, 32), rknee=(20, 31), lfoot=(5, 41), rfoot=(24, 38),
                    lelb=(6, 17), relb=(19, 9), lhand=(4, 21), rhand=(22, 3), face="back"),
    # pitcher side-on, facing right (toward the plate). Flip for facing left.
    "ps_set": P(head=(13, 6), neck=(13, 10), hip=(13, 23), lknee=(11, 32), rknee=(15, 32), lfoot=(10, 41), rfoot=(16, 41),
                lelb=(11, 16), relb=(16, 16), lhand=(16, 19), rhand=(17, 19), face=1, front="l"),
    "ps_kick": P(head=(11, 6), neck=(12, 10), hip=(13, 23), lknee=(19, 21), rknee=(13, 32), lfoot=(16, 30), rfoot=(13, 41),
                 lelb=(9, 15), relb=(15, 15), lhand=(12, 13), rhand=(13, 13), face=1, front="l"),
    "ps_release": P(head=(19, 10), neck=(17, 14), hip=(13, 24), lknee=(20, 31), rknee=(8, 31), lfoot=(24, 41), rfoot=(3, 37),
                    lelb=(15, 19), relb=(22, 12), lhand=(13, 22), rhand=(26, 17), face=1, front="r"),
    # batter (right-handed) as seen from the CF camera: stands screen-right of the plate, faces left.
    # Left-handed batter = flip horizontally.
    "bat_stance": P(head=(15, 6), neck=(15, 10), hip=(14, 23), lknee=(10, 32), rknee=(18, 32), lfoot=(9, 41), rfoot=(19, 41),
                    lelb=(10, 14), relb=(20, 13), lhand=(18, 9), rhand=(19, 9), face=-1, bat=(25, 0)),
    "bat_swing": P(head=(13, 7), neck=(14, 11), hip=(14, 23), lknee=(9, 32), rknee=(19, 32), lfoot=(6, 41), rfoot=(20, 41),
                   lelb=(9, 15), relb=(18, 16), lhand=(6, 16), rhand=(7, 16), face=-1, bat=(-3, 14)),
    "bat_follow": P(head=(14, 7), neck=(14, 11), hip=(14, 23), lknee=(9, 32), rknee=(17, 31), lfoot=(8, 41), rfoot=(17, 41),
                    lelb=(19, 10), relb=(9, 10), lhand=(19, 6), rhand=(18, 6), face=-1, bat=(4, 2)),
    # catcher, facing the camera
    "c_crouch": P(head=(14, 16), neck=(14, 20), hip=(14, 30), lknee=(7, 31), rknee=(21, 31), lfoot=(9, 41), rfoot=(19, 41),
                  lelb=(8, 25), relb=(20, 25), lhand=(10, 22), rhand=(19, 28), face=0, glove="lhand", catcher=True),
    "c_receive": P(head=(14, 16), neck=(14, 20), hip=(14, 30), lknee=(7, 31), rknee=(21, 31), lfoot=(9, 41), rfoot=(19, 41),
                   lelb=(10, 21), relb=(20, 25), lhand=(14, 15), rhand=(19, 28), face=0, glove="lhand", catcher=True),
    "c_throw": P(head=(14, 6), neck=(14, 10), hip=(14, 23), lknee=(10, 32), rknee=(18, 32), lfoot=(9, 41), rfoot=(19, 41),
                 lelb=(8, 15), relb=(22, 11), lhand=(9, 20), rhand=(23, 4), face=0, glove="lhand", catcher=True),
    # umpire (dark suit), facing the camera
    "u_crouch": P(head=(14, 12), neck=(14, 16), hip=(14, 28), lknee=(8, 31), rknee=(20, 31), lfoot=(9, 41), rfoot=(19, 41),
                  lelb=(9, 22), relb=(19, 22), lhand=(11, 27), rhand=(17, 27), face=0),
    "u_strike": P(head=(13, 7), neck=(13, 11), hip=(13, 24), lknee=(10, 33), rknee=(17, 33), lfoot=(10, 41), rfoot=(18, 41),
                  lelb=(8, 17), relb=(21, 10), lhand=(10, 22), rhand=(21, 2), face=0),
    "u_safe": P(head=(14, 7), neck=(14, 11), hip=(14, 24), lknee=(10, 33), rknee=(18, 33), lfoot=(9, 41), rfoot=(19, 41),
                lelb=(7, 13), relb=(21, 13), lhand=(1, 13), rhand=(27, 13), face=0),
    # fielder
    "f_ready": P(head=(14, 9), neck=(14, 13), hip=(14, 25), lknee=(9, 32), rknee=(19, 32), lfoot=(8, 41), rfoot=(20, 41),
                 lelb=(9, 19), relb=(19, 19), lhand=(11, 25), rhand=(17, 25), face=0, glove="lhand"),
    "f_run1": P(head=(16, 6), neck=(15, 10), hip=(14, 23), lknee=(19, 30), rknee=(10, 31), lfoot=(16, 39), rfoot=(5, 37),
                lelb=(10, 15), relb=(20, 14), lhand=(8, 20), rhand=(22, 9), face=1, glove="lhand", front="l"),
    "f_run2": P(head=(16, 6), neck=(15, 10), hip=(14, 23), lknee=(9, 30), rknee=(18, 31), lfoot=(5, 37), rfoot=(19, 41),
                lelb=(20, 15), relb=(10, 14), lhand=(22, 20), rhand=(8, 9), face=1, glove="lhand", front="r"),
    "f_reach": P(head=(16, 6), neck=(15, 10), hip=(14, 23), lknee=(10, 31), rknee=(19, 31), lfoot=(8, 41), rfoot=(21, 40),
                 lelb=(19, 5), relb=(10, 14), lhand=(22, 1), rhand=(8, 19), face=1, glove="lhand"),
    "f_dive": P(head=(22, 31), neck=(19, 33), hip=(10, 35), lknee=(5, 32), rknee=(6, 38), lfoot=(1, 29), rfoot=(1, 40),
                lelb=(23, 28), relb=(18, 38), lhand=(27, 26), rhand=(21, 41), face=1, glove="lhand", front="l"),
    "f_throw": P(head=(18, 9), neck=(16, 13), hip=(13, 24), lknee=(19, 31), rknee=(8, 31), lfoot=(23, 41), rfoot=(4, 39),
                 lelb=(21, 15), relb=(9, 10), lhand=(24, 17), rhand=(5, 4), face=1, glove="lhand", front="l"),
    # runner (no glove), facing right
    "r_run1": P(head=(17, 6), neck=(16, 10), hip=(14, 23), lknee=(20, 30), rknee=(10, 31), lfoot=(17, 39), rfoot=(5, 36),
                lelb=(10, 15), relb=(21, 15), lhand=(9, 21), rhand=(24, 11), face=1, front="l"),
    "r_run2": P(head=(17, 6), neck=(16, 10), hip=(14, 23), lknee=(9, 30), rknee=(19, 31), lfoot=(4, 36), rfoot=(20, 41),
                lelb=(21, 16), relb=(10, 14), lhand=(24, 21), rhand=(8, 9), face=1, front="r"),
    "r_slide": P(head=(4, 29), neck=(7, 32), hip=(13, 38), lknee=(19, 36), rknee=(17, 40), lfoot=(26, 38), rfoot=(22, 41),
                 lelb=(4, 25), relb=(9, 38), lhand=(6, 20), rhand=(5, 41), face=1, front="l"),
    # crowd fan / fan on the field
    "fan_down": P(head=(14, 8), neck=(14, 12), hip=(14, 25), lknee=(11, 33), rknee=(17, 33), lfoot=(11, 41), rfoot=(17, 41),
                  lelb=(9, 18), relb=(19, 18), lhand=(9, 24), rhand=(19, 24), face=0, civ=True),
    "fan_up": P(head=(14, 8), neck=(14, 12), hip=(14, 25), lknee=(11, 33), rknee=(17, 33), lfoot=(11, 41), rfoot=(17, 41),
                lelb=(8, 8), relb=(20, 8), lhand=(7, 2), rhand=(21, 2), face=0, civ=True),
    "streak1": P(head=(17, 6), neck=(16, 10), hip=(14, 23), lknee=(20, 30), rknee=(10, 31), lfoot=(17, 39), rfoot=(5, 36),
                 lelb=(9, 7), relb=(22, 7), lhand=(8, 1), rhand=(24, 1), face=1, front="l", nude=True),
    "streak2": P(head=(17, 6), neck=(16, 10), hip=(14, 23), lknee=(9, 30), rknee=(19, 31), lfoot=(4, 36), rfoot=(20, 41),
                 lelb=(10, 7), relb=(21, 8), lhand=(8, 2), rhand=(25, 3), face=1, front="r", nude=True),
    "mascot1": P(head=(14, 10), neck=(14, 17), hip=(14, 28), lknee=(10, 34), rknee=(18, 34), lfoot=(9, 41), rfoot=(19, 41),
                 lelb=(7, 21), relb=(21, 21), lhand=(6, 27), rhand=(22, 27), face=0, mascot=True),
    "mascot2": P(head=(14, 10), neck=(14, 17), hip=(14, 28), lknee=(10, 34), rknee=(18, 34), lfoot=(9, 41), rfoot=(19, 41),
                 lelb=(6, 19), relb=(22, 16), lhand=(6, 27), rhand=(25, 9), face=0, mascot=True),
}

TABLES = [
    # name, frames, description
    ("pitcher_back", ["pb_set", "pb_kick", "pb_release"], "Pitcher from behind (CF/pitch cam): set, kick, release"),
    ("pitcher_side", ["ps_set", "ps_kick", "ps_release"], "Pitcher side-on facing right (toward the plate): set, kick, release. Flip for facing left"),
    ("batter", ["bat_stance", "bat_swing", "bat_follow"], "Right-handed batter as seen from the CF cam (stands right of plate, faces left): stance, swing, follow. Left-handed = flip horizontally"),
    ("catcher", ["c_crouch", "c_receive", "c_throw"], "Catcher facing camera: crouch, receive (mitt up), throw"),
    ("umpire", ["u_crouch", "u_strike", "u_safe"], "Umpire (dark suit) facing camera: crouch, strike/out call, safe"),
    ("fielder", ["f_ready", "f_run1", "f_run2", "f_reach", "f_dive", "f_throw"], "Fielder: ready (front), run1, run2, reach, dive, throw (side, facing right)"),
    ("runner", ["r_run1", "r_run2", "r_slide"], "Runner facing right: run1, run2, slide (feet first)"),
    ("fan", ["fan_down", "fan_up"], "Crowd fan / fan on the field: arms down, arms up"),
    ("streaker", ["streak1", "streak2"], "Streaker (censor bar), running right: 2 frames"),
    ("mascot", ["mascot1", "mascot2"], "Mascot (baseball head): idle, wave"),
]


# ------------------------------------------------------------------ drawing

class Canvas:
    def __init__(self, k):
        self.k = k
        self.im = Image.new("L", (SW * k, SH * k), 255)   # ink
        self.fig = Image.new("L", (SW * k, SH * k), 0)    # figure coverage
        self.d = ImageDraw.Draw(self.im)
        self.df = ImageDraw.Draw(self.fig)

    def P(self, p):
        k = self.k
        return (p[0] * k + (k - 1) / 2, p[1] * k + (k - 1) / 2)

    def capsule(self, a, b, w, col):
        a, b = self.P(a), self.P(b)
        w = w * self.k
        for d, c in ((self.d, col), (self.df, 255)):
            d.line((a, b), fill=c, width=max(1, int(round(w))))
            r = w / 2 - 0.01
            for p in (a, b):
                d.ellipse((p[0] - r, p[1] - r, p[0] + r, p[1] + r), fill=c)

    def poly(self, pts, col):
        pts = [self.P(p) for p in pts]
        self.d.polygon(pts, fill=col)
        self.df.polygon(pts, fill=255)

    def ellipse(self, c, rx, ry, col):
        x, y = self.P(c)
        rx, ry = rx * self.k, ry * self.k
        self.d.ellipse((x - rx, y - ry, x + rx, y + ry), fill=col)
        self.df.ellipse((x - rx, y - ry, x + rx, y + ry), fill=255)


def _off(a, b, d):
    """Point d design-px beyond b along a->b."""
    dx, dy = b[0] - a[0], b[1] - a[1]
    L = math.hypot(dx, dy) or 1
    return (b[0] + dx / L * d, b[1] + dy / L * d)


def draw_puppet(j, k, uni="white"):
    """Return (ink L, mask L) for pose j at scale k."""
    c = Canvas(k)
    o = 1.0 / k if k == 1 else 1.0 / k * 1.5  # contour width in design px (1px at 1x, 1.5->~2px at 2x? see below)
    o = 1.0 if k == 1 else 0.75               # 1 px at 1x, 1.5 px -> rendered 2 px at 2x via rounding
    umpire = j is not None and j.get("ump", False)
    dark = uni == "dark"
    nude = j.get("nude", False)
    civ = j.get("civ", False)
    mascot = j.get("mascot", False)
    jersey = {"white": 255, "gray": GRAY, "dark": 0}[uni]
    pants = jersey if uni != "gray" else 255
    if nude:
        jersey = pants = 255
    if civ:
        pants = 0 if uni == "white" else GRAY
    skin = 255
    face = j.get("face", 0)
    front = j.get("front", "l")
    back_side = "r" if front == "l" else "l"

    def leg(s, col):
        hip, kn, ft = j["hip"], j[s + "knee"], j[s + "foot"]
        hipx = (hip[0] + (-1.5 if s == "l" else 1.5), hip[1])
        c.capsule(hipx, kn, 4.6 + 2 * o, 0); c.capsule(kn, ft, 3.6 + 2 * o, 0)
        c.capsule(hipx, kn, 4.6, col); c.capsule(kn, ft, 3.6, col)
        if not nude and not mascot:
            # socks / shin guards: lower shin dark
            m = ((kn[0] + ft[0]) / 2, (kn[1] + ft[1]) / 2)
            if j.get("catcher"):
                m = kn
            c.capsule(m, ft, 3.6, 0)
        # shoe
        if face in (1, -1):
            toe = (ft[0] + 2.0 * face, ft[1] + 0.3)
            c.capsule(ft, toe, 2.6, 0)
        else:
            c.ellipse((ft[0], ft[1] + 0.3), 1.8, 1.2, 0)

    def arm(s, col):
        nk, el, hd = j["neck"], j[s + "elb"], j[s + "hand"]
        sh = (nk[0] + (-3 if s == "l" else 3) * (0.6 if face in (1, -1) else 1), nk[1] + 1.2)
        c.capsule(sh, el, 3.4 + 2 * o, 0); c.capsule(el, hd, 3.0 + 2 * o, 0)
        c.capsule(sh, el, 3.4, col); c.capsule(el, hd, 3.0, col)
        if j.get("glove") == s + "hand":
            g = _off(el, hd, 0.8)
            c.ellipse(g, 2.4, 2.4, 0)
            if k > 1:
                c.ellipse((g[0] - 0.5, g[1] - 0.5), 0.6, 0.6, 255)
        else:
            c.ellipse(hd, 1.2 + o, 1.2 + o, 0)
            c.ellipse(hd, 1.2, 1.2, skin)

    def torso():
        nx, ny = j["neck"]; hx, hy = j["hip"]
        sw = 4.6 if face in (0, "back") else 3.4
        hw = 3.8 if face in (0, "back") else 3.2
        if mascot:
            sw, hw = 5.5, 5.5
        pts = [(nx - sw, ny), (nx + sw, ny), (hx + hw, hy + 1), (hx - hw, hy + 1)]
        e = o
        c.poly([(nx - sw - e, ny - e), (nx + sw + e, ny - e), (hx + hw + e, hy + 1 + e), (hx - hw - e, hy + 1 + e)], 0)
        c.poly(pts, jersey if not mascot else 255)
        if not nude and not civ and not mascot:
            c.capsule((hx - hw + 0.5, hy), (hx + hw - 0.5, hy), 1.2 if k == 1 else 1.0, 0)  # belt
        if j.get("catcher") and face == 0:
            # chest protector
            c.poly([(nx - 3, ny + 1), (nx + 3, ny + 1), (hx + 2.5, hy - 2), (hx - 2.5, hy - 2)], 0)
            if k > 1:
                for t in (0.35, 0.65):
                    yy = ny + (hy - ny) * t
                    c.capsule((nx - 2, yy), (nx + 2, yy), 0.5, 255)
        if face == "back" and k > 1 and not dark:
            # jersey number on the back
            _digit(c, (nx - 1.5, ny + 3.0), "7", jersey)
        if face == "back" and k == 1 and not dark:
            c.capsule((nx - 0.5, ny + 3), (nx + 0.6, ny + 3), 0.9, 0)
            c.capsule((nx + 0.6, ny + 3), (nx - 0.3, ny + 7), 0.9, 0)
        if nude:
            c.poly([(hx - 3.6, hy - 1.5), (hx + 3.6, hy - 1.5), (hx + 3.6, hy + 2.2), (hx - 3.6, hy + 2.2)], 0)  # censor bar

    def head():
        hx, hy = j["head"]
        if mascot:
            r = 7.0
            c.ellipse((hx, hy), r + o, r + o, 0)
            c.ellipse((hx, hy), r, r, 255)
            # stitches
            for sgn in (-1, 1):
                for t in range(-3, 4):
                    yy = hy + t * 1.6
                    xx = hx + sgn * (4.2 - 0.25 * t * t)
                    c.capsule((xx - 0.6 * sgn, yy), (xx + 0.6 * sgn, yy), 0.6 if k == 1 else 0.5, 0)
            # eyes + grin
            c.ellipse((hx - 2, hy - 1), 0.9, 1.2, 0); c.ellipse((hx + 2, hy - 1), 0.9, 1.2, 0)
            c.capsule((hx - 2.2, hy + 2.6), (hx + 2.2, hy + 2.6), 0.9, 0)
            c.poly([(hx - 7.5, hy - 4), (hx + 7.5, hy - 4), (hx + 5, hy - 8.4), (hx - 5, hy - 8.4)], 0)  # cap
            return
        r = 3.2
        c.ellipse((hx, hy), r + o, r + o, 0)
        c.ellipse((hx, hy), r, r, 255 if not dark or True else 0)
        if j.get("catcher") and face == 0 and "c_throw" not in j.get("_name", ""):
            # mask
            c.ellipse((hx, hy + 0.4), 2.6, 2.6, 0)
            if k > 1:
                c.capsule((hx - 1.8, hy - 0.4), (hx + 1.8, hy - 0.4), 0.45, 255)
                c.capsule((hx - 1.8, hy + 1.4), (hx + 1.8, hy + 1.4), 0.45, 255)
        if nude or civ:
            # hair
            c.poly([(hx - r, hy - 0.5), (hx - r + 0.5, hy - r + 0.2), (hx + r - 0.5, hy - r + 0.2), (hx + r, hy - 0.5)], 0)
            if face in (1, -1):
                c.ellipse((hx - face * 1.4, hy), 1.6, 1.8, 0)
        else:
            # cap crown
            c.poly([(hx - r - 0.2, hy - 0.6), (hx - r + 0.4, hy - r - 0.6), (hx + r - 0.4, hy - r - 0.6), (hx + r + 0.2, hy - 0.6)], 0)
            if face in (1, -1):
                c.capsule((hx, hy - 0.6), (hx + face * (r + 2.4), hy - 0.4), 1.2, 0)  # brim
            elif face == 0:
                c.capsule((hx - r - 0.6, hy - 0.4), (hx + r + 0.6, hy - 0.4), 1.0, 0)
            else:  # back: hair below cap
                c.ellipse((hx, hy + 0.2), 2.6, 0.9, 0)
        if k > 1 and face == 0 and not (j.get("catcher") and "c_throw" not in j.get("_name", "")):
            c.ellipse((hx - 1.2, hy + 0.6), 0.45, 0.55, 0); c.ellipse((hx + 1.2, hy + 0.6), 0.45, 0.55, 0)
        if k > 1 and face in (1, -1):
            c.ellipse((hx + face * 1.6, hy + 0.4), 0.45, 0.55, 0)

    def bat():
        if "bat" not in j:
            return
        hd = j["rhand"]; tip = j["bat"]
        c.capsule(hd, tip, 2.0 + 2 * o, 0)
        c.capsule(_off(tip, hd, 0), _off(hd, tip, -1.0), 1.2 if k == 1 else 1.3, 0)
        # white highlight so the bat reads on dark grounds
        if k > 1:
            c.capsule(_off(tip, hd, -3), _off(hd, tip, -2.5), 0.6, 255)

    # z-order: back limbs, torso, front leg, head, front arm, bat
    bk, fr = back_side, front
    if face == 0 or face == "back":
        bk, fr = "l", "r"
    leg(bk, pants)
    arm(bk, jersey)
    bat()
    leg(fr, pants)
    torso()
    head()
    arm(fr, jersey)
    if "bat" in j:
        bat()
    return finish(c, k)


def _digit(c, xy, ch, bg):
    glyph = {"7": ["###", "..#", ".#.", ".#.", ".#."]}[ch]
    x0, y0 = xy
    for yy, row in enumerate(glyph):
        for xx, v in enumerate(row):
            if v == "#":
                c.poly([(x0 + xx, y0 + yy * 1.0), (x0 + xx + 1, y0 + yy * 1.0), (x0 + xx + 1, y0 + yy + 1), (x0 + xx, y0 + yy + 1)], 0)


def finish(c, k, halo=1):
    ink = np.asarray(c.im).copy()
    # gray marker -> checker
    yy, xx = np.mgrid[0:ink.shape[0], 0:ink.shape[1]]
    g = (ink > 64) & (ink < 192)
    ink[g] = np.where(((xx + yy) % 2 == 0)[g], 0, 255)
    ink = np.where(ink >= 128, 255, 0).astype(np.uint8)
    fig = c.fig.point(lambda v: 255 if v >= 128 else 0)
    mask = fig
    for _ in range(halo):
        mask = mask.filter(ImageFilter.MaxFilter(3))
    # halo pixels are white
    inkim = Image.fromarray(ink, "L")
    figm = np.asarray(fig) > 0
    ink2 = np.where(figm, ink, 255).astype(np.uint8)
    return Image.fromarray(ink2, "L"), mask


# ------------------------------------------------------------------ dark umpire

def draw_umpire(name, k):
    j = dict(POSES[name]); j["_name"] = name
    ink, mask = draw_puppet(j, k, uni="dark")
    return ink, mask


# ------------------------------------------------------------------ ascii sprites (raccoon)

RACCOON = [
    ["..X.X..............",
     ".XXXXX.............",
     "XwXXwXX............",
     "XXXXXXXXXXXXXX.....",
     ".XXXXXXXXXXXXXXwXw.",
     "..XXXXXXXXXXXXXXXXX",
     "..XX.XX....XX.XX...",
     "..X..X.....X..X...."],
    ["..X.X..............",
     ".XXXXX.............",
     "XwXXwXX............",
     "XXXXXXXXXXXXXX..w..",
     ".XXXXXXXXXXXXXXXwXX",
     "..XXXXXXXXXXXXXX...",
     "...XXXX....XXXX....",
     "...X..X....X..X...."],
]
RACCOON2X = [
    ["....XX..XX..................................",
     "...XXXXXXXX.................................",
     "..XXXXXXXXXX................................",
     ".XXwwXXXXwwXX...............................",
     ".XXwXXwwXXwXX...............................",
     "XXXwwXXXXwwXXX..............................",
     "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX..............",
     ".XXXwwwwwwXXXXXXXXXXXXXXXXXXXXXX............",
     "..XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX...XXwwXX..",
     "...XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXwwXXwwXXX.",
     "....XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
     "....XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX.wwXXwwXX.",
     ".....XXXX.XXXX.........XXXX.XXXX............",
     ".....XXX...XXX.........XXX...XXX............",
     ".....XX.....XX.........XX.....XX............",
     "....XXX....XXX........XXX....XXX............"],
    ["....XX..XX..................................",
     "...XXXXXXXX.................................",
     "..XXXXXXXXXX................................",
     ".XXwwXXXXwwXX...............................",
     ".XXwXXwwXXwXX...............................",
     "XXXwwXXXXwwXXX..............................",
     "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX.......XXwwXX.",
     ".XXXwwwwwwXXXXXXXXXXXXXXXXXXXXXX...XXwwXXwwX",
     "..XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX..",
     "...XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXwwX......",
     "....XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX..........",
     "....XXXXXXXXXXXXXXXXXXXXXXXXXXXXXX..........",
     "......XXXXXX.............XXXXXX.............",
     ".......XXXX...............XXXX..............",
     "......XX..XX.............XX..XX.............",
     ".....XXX..XXX...........XXX..XXX............"],
]


def ascii_sprite(rows, size, pad=(1, 1)):
    w, h = size
    ink = Image.new("L", (w, h), 255)
    fig = Image.new("L", (w, h), 0)
    ox = (w - len(rows[0])) // 2
    oy = h - len(rows) - 1
    for y, row in enumerate(rows):
        for x, ch in enumerate(row):
            if ch != ".":
                ink.putpixel((ox + x, oy + y), 0 if ch == "X" else 255)
                fig.putpixel((ox + x, oy + y), 255)
    mask = fig.filter(ImageFilter.MaxFilter(3))
    return ink, mask


# ------------------------------------------------------------------ ball / shadow / dust

BALL_D = [2, 3, 4, 6, 8, 10]


def ball_frames(k):
    cell = 12 * k
    frames, masks = [], []
    for dd in BALL_D:
        D = dd * k
        for spin in range(2):
            im = Image.new("L", (cell, cell), 255)
            fig = Image.new("L", (cell, cell), 0)
            d = ImageDraw.Draw(im); df = ImageDraw.Draw(fig)
            c0 = (cell - D) / 2
            box = (c0, c0, c0 + D - 1, c0 + D - 1)
            if D <= 2:
                d.rectangle(box, fill=255); df.rectangle(box, fill=255)
                d.point((c0 + spin, c0 + spin), fill=0)
            elif D <= 3:
                d.rectangle(box, fill=255); df.rectangle(box, fill=255)
                d.rectangle((c0 + 1, c0 + 1, c0 + 1, c0 + 1), fill=255)
                d.point((c0 + (2 if spin else 0), c0), fill=0)
                d.point((c0 + (0 if spin else 2), c0 + 2), fill=0)
            else:
                d.ellipse(box, fill=255, outline=0); df.ellipse(box, fill=255)
                if D >= 6:
                    # seams: two arcs
                    r = D / 2
                    cx = cy = cell / 2 - 0.5
                    for sgn in (-1, 1):
                        a0 = -50 + spin * 30
                        bb = (cx + sgn * r * 0.55 - r * 0.6, cy - r * 0.7, cx + sgn * r * 0.55 + r * 0.6, cy + r * 0.7)
                        if sgn < 0:
                            d.arc(bb, 300 + spin * 20, 60 + spin * 20, fill=0)
                        else:
                            d.arc(bb, 120 + spin * 20, 240 + spin * 20, fill=0)
                else:
                    d.point((cell / 2 - 1 + spin, cell / 2 - 1), fill=0)
            mask = fig.filter(ImageFilter.MaxFilter(3))
            frames.append(im); masks.append(mask)
    return frames, masks


def shadow_frames(k):
    w, h = 16 * k, 6 * k
    frames, masks = [], []
    for rx in (2, 4, 7):
        im = Image.new("L", (w, h), 255)
        m = Image.new("L", (w, h), 0)
        R = rx * k; ry = max(1, rx * k // 3)
        cx, cy = w / 2 - 0.5, h / 2 - 0.5
        box = (cx - R, cy - ry, cx + R, cy + ry)
        ImageDraw.Draw(im).ellipse(box, fill=0)
        ImageDraw.Draw(m).ellipse(box, fill=255)
        frames.append(im); masks.append(m)
    # 50% dithered variants (softer shadow for high balls)
    for i in range(3):
        im = frames[i].copy(); px = im.load(); m = masks[i].copy(); mp = m.load()
        for y in range(h):
            for x in range(w):
                if mp[x, y] and (x + y) % 2:
                    mp[x, y] = 0
        frames.append(im); masks.append(m)
    return frames, masks


def dust_frames(k):
    w, h = 24 * k, 16 * k
    frames, masks = [], []
    rng = np.random.default_rng(7)
    blobs = [(rng.uniform(-1, 1), rng.uniform(-0.3, 0.2), rng.uniform(0.5, 1.0)) for _ in range(7)]
    for f in range(4):
        im = Image.new("L", (w, h), 255)
        fig = Image.new("L", (w, h), 0)
        d = ImageDraw.Draw(im); df = ImageDraw.Draw(fig)
        spread = (3 + f * 3) * k
        for bx, by, br in blobs:
            r = (2 + f * 1.2) * br * k
            cx = w / 2 + bx * spread
            cy = h - 2 * k - r - f * by * 2 * k - f * k
            box = (cx - r, cy - r, cx + r, cy + r)
            d.ellipse(box, fill=255, outline=0)
            df.ellipse(box, fill=255)
        # thin out late frames (dissipating): checker the interior
        a = np.asarray(im).copy(); fm = np.asarray(fig) > 0
        yy, xx = np.mgrid[0:h, 0:w]
        if f >= 2:
            keep = ((xx + yy) % 2 == 0) if f == 2 else ((xx % 2 == 0) & (yy % 2 == 0))
            fm = fm & keep
            a = np.where(fm, a, 255)
        im = Image.fromarray(a.astype(np.uint8), "L")
        m = Image.fromarray((fm * 255).astype(np.uint8), "L")
        if f < 2:
            m = m.filter(ImageFilter.MaxFilter(3))
        frames.append(im); masks.append(m)
    return frames, masks


# ------------------------------------------------------------------ build

def render_table(frames_names, k, uni):
    frames, masks = [], []
    for nm in frames_names:
        j = dict(POSES[nm]); j["_name"] = nm
        u = uni
        if nm.startswith("u_"):
            u = "dark"
        ink, mask = draw_puppet(j, k, uni=u)
        frames.append(ink); masks.append(mask)
    return frames, masks


def build(verbose=True):
    # RETIRED: the shipped puppets come from tools/assets/humanoid/build.py. This generator would
    # overwrite them (and readme/20-puppets.md); kept only for reference.
    if os.environ.get("DEADBALL_LEGACY_PUPPETS") != "1":
        raise SystemExit("tools/assets/puppets.py is retired: run python3 tools/assets/humanoid/build.py "
                         "(set DEADBALL_LEGACY_PUPPETS=1 to force the old hand-drawn set)")
    outputs = []
    previews = []
    for k in (1, 2):
        d = common.ensure_dir(os.path.join(OUT, f"{k}x"))
        for name, fr, desc in TABLES:
            for uni, suffix in (("white", ""), ("gray", "_away")):
                if suffix and name in ("umpire", "fan", "streaker", "mascot"):
                    continue
                f, m = render_table(fr, k, uni)
                if name == "fan" and uni == "white":
                    f2, m2 = render_table(fr, k, "gray")
                    f, m = f + f2, m + m2
                p = common.save_table(f, d, name + suffix, masks=m)
                outputs.append(p)
                if k == 2 or True:
                    previews.append((k, name + suffix, f, m))
        # raccoon
        rows = RACCOON if k == 1 else RACCOON2X
        size = (24, 14) if k == 1 else (48, 28)
        rf, rm = zip(*[ascii_sprite(r, size) for r in rows])
        outputs.append(common.save_table(list(rf), d, "raccoon", masks=list(rm)))
        previews.append((k, "raccoon", list(rf), list(rm)))
        for nm, fn in (("ball", ball_frames), ("shadow", shadow_frames), ("dust", dust_frames)):
            f, m = fn(k)
            outputs.append(common.save_table(f, d, nm, masks=m))
            previews.append((k, nm, f, m))
    make_preview(previews)
    readme()
    if verbose:
        print("puppets:", len(outputs), "tables")
    return outputs


def make_preview(previews):
    # 1x and 2x composited onto a dithered mid-gray (like grass) and white, scaled 2x
    rows = []
    for k in (1, 2):
        for kk, name, f, m in previews:
            if kk != k:
                continue
            rows.append((k, name, f, m))
    W = 0
    blocks = []
    for k, name, f, m in rows:
        w, h = f[0].size
        strip = Image.new("L", (len(f) * (w + 4) + 4, h + 14), 255)
        bg = Image.new("L", (w, h), 255)
        yy, xx = np.mgrid[0:h, 0:w]
        bgarr = np.where(((xx + yy) % 2 == 0) | ((xx % 4 == 1) & (yy % 2 == 1)), 0, 255).astype(np.uint8)
        bgd = Image.fromarray(bgarr, "L")
        for i, (a, b) in enumerate(zip(f, m)):
            tile = (bgd if i % 2 == 0 else bg).copy()
            tile.paste(a, (0, 0), b)
            strip.paste(tile, (4 + i * (w + 4), 12))
        common.font("tiny").draw(strip, (4, 0), f"{name} {k}x")
        blocks.append(strip)
    # pack blocks into rows of max width 900
    maxw = 900
    lines, cur, cw = [], [], 0
    for b in blocks:
        if cw + b.width > maxw and cur:
            lines.append(cur); cur, cw = [], 0
        cur.append(b); cw += b.width
    if cur:
        lines.append(cur)
    H = sum(max(b.height for b in ln) + 4 for ln in lines)
    sheet = Image.new("L", (maxw, H), 255)
    y = 0
    for ln in lines:
        x = 0
        for b in ln:
            sheet.paste(b, (x, y)); x += b.width
        y += max(b.height for b in ln) + 4
    sheet = sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST)
    sheet.save(os.path.join(common.ensure_dir(common.PREVIEW), "puppets.png"))


def readme():
    lines = ["## BallCast puppets (`images/puppets/`)", "",
             "Billboard sprites with transparency (black contour + 1 px white halo so they read on dithered grass).",
             "Every table exists twice with identical frame order: `images/puppets/1x/<name>` (base) and",
             "`images/puppets/2x/<name>` (redrawn at double size, not upscaled — use for close shots).",
             "Load with `gfx.imagetable.new(\"images/puppets/1x/pitcher_back\")`; frames are 1-based.",
             "",
             "| table | 1x cell | 2x cell | frames (1-based) | anchor 1x / 2x |",
             "|---|---|---|---|---|"]
    for name, fr, desc in TABLES:
        if name == "fan":
            continue
        lines.append(f"| `{name}` | 28x44 | 56x88 | {', '.join(f'{i+1} {n.split('_', 1)[1] if '_' in n else n}' for i, n in enumerate(fr))} — {desc} | feet (14,42) / (28,84) |")
    lines += [
        "| `fan` | 28x44 | 56x88 | 1 arms down, 2 arms up (white shirt); 3 arms down, 4 arms up (gray shirt) | feet (14,42) / (28,84) |",
        "| `raccoon` | 24x14 | 48x28 | 1, 2 (walk cycle, facing left; flip for right) | feet bottom-centre (12,13) / (24,27) |",
        f"| `ball` | 12x12 | 24x24 | 12 frames: frame = (sizeIdx-1)*2 + spin + 1; sizeIdx 1..6 = diameter {BALL_D} px (x2 at 2x), spin 0/1 alternates | centre (6,6) / (12,12) |",
        "| `shadow` | 16x6 | 32x12 | 1-3 solid ellipse small/med/large, 4-6 same but 50% dithered (ball high up) | centre (8,3) / (16,6) |",
        "| `dust` | 24x16 | 48x32 | 1-4 puff growing and dissipating | bottom-centre (12,15) / (24,31) |",
        "",
        "Away-team variants: `<name>_away` (pitcher_back_away, pitcher_side_away, batter_away, catcher_away, fielder_away,",
        "runner_away) — same frames, gray (50% checker) jerseys. Umpire is always dark.",
        "",
        "Facing: side-on tables face **right**; draw with `gfx.kFlippedX` to face left. The batter table is a",
        "right-handed batter as seen from the CF camera; flip it for left-handed batters (and on reverse angles).",
        "",
        "Sizing: the figure is 40 px tall (head top y=2 to feet y=42) at 1x and represents ~6.2 ft. See parks.json",
        "`sprite_rule`: h = 6.2 * scale / depth; s = h / 40; s < 1.4 -> 1x table (scaled by s unless 0.8 <= s < 1.4),",
        "else 2x table at s / 2. Draw with the anchor (feet) on the projected ground point.",
    ]
    common.write_readme_part("20-puppets.md", "\n".join(lines))


if __name__ == "__main__":
    build()
