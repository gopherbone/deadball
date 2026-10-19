"""Animatic tracks for the BallCast puppets (untweened held keyframes + squash/stretch, shake, boil).

Writes playdate/source/images/puppets/anim_tracks.json and, as a *reference implementation* of the
per-billboard transform the renderer should apply, preview strips/GIFs in preview/anim_*.{png,gif}.

Track format (30 fps):
  tracks.<action> = {"loop": bool, "boil": bool, "keys": [key, ...]}
  key = {"t": table, "f": frame (1-based), "hold": frames,
         "sx": 1, "sy": 1,            # non-uniform scale about the pivot (keep sx*sy ~ 1)
         "rot": 0,                    # degrees, clockwise on screen
         "dx": 0, "dy": 0,            # 1x pixel offset (x2 on the 2x table)
         "flip": false,               # x-flip (combined with the puppet's own facing flip)
         "pivot": "feet"|"center",    # feet = table anchor (14,42); center = (14,22)
         "fx": {"shake": [amp_deg, frames]} | {"vibrate": [px, frames]}}   # optional, starts on this key
Rules: hard cuts between keys, no easing; a key's transform is held for its whole 'hold'.
  shake  : extra rot = amp * (-1)^k * 0.55^k on frame k of the effect (k = 0..frames-1), snapped per frame.
  vibrate: extra (dx, dy) = random integers in [-px, px] every frame for `frames` frames.
  boil   : on tracks with boil=true, every 6..14 frames (per-puppet random, seeded by puppet id) offset
           the sprite by a random (dx, dy) in {-1,0,1}^2 for 1..2 frames; also used for idle puppets.
Transform: inverse-map each destination pixel through flip/scale/rotation about the pivot and sample
the source frame nearest-neighbour (keep the 1-bit look); the pivot stays on the projected ground point
(feet) or 20 px (x scale) above it (center)."""
import json, math, os, random, sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hlib

SQ = dict(sx=1.15, sy=0.87)       # squash (impact / landing / contact / release)
SQ2 = dict(sx=1.22, sy=0.82)      # big squash (landing a flip, pratfall)
ST = dict(sx=0.9, sy=1.11)        # stretch (leap, extension)
STH = dict(sx=1.1, sy=0.91)       # horizontal stretch (dive, lunge)


def K(t, f, hold, **kw):
    d = {"t": t, "f": f, "hold": hold}
    d.update(kw)
    return d


TRACKS = {
    "pitch_back": {"loop": False, "boil": True, "keys": [
        K("pitcher_back_seq", 1, 10), K("pitcher_back_seq", 2, 6, **ST), K("pitcher_back_seq", 3, 3),
        K("pitcher_back_seq", 4, 3, **ST), K("pitcher_back_seq", 5, 2, **SQ, fx={"shake": [4, 4]}),
        K("pitcher_back_seq", 6, 9)]},
    "pitch_side": {"loop": False, "boil": True, "keys": [
        K("pitcher_side_seq", 1, 10), K("pitcher_side_seq", 2, 6, **ST), K("pitcher_side_seq", 3, 3),
        K("pitcher_side_seq", 4, 3, sx=0.92, sy=1.09), K("pitcher_side_seq", 5, 2, **SQ, fx={"shake": [5, 4]}),
        K("pitcher_side_seq", 6, 9)]},
    "swing": {"loop": False, "boil": True, "keys": [
        K("batter_seq", 1, 8), K("batter_seq", 2, 5, sx=0.94, sy=1.06), K("batter_seq", 3, 2),
        K("batter_seq", 4, 2, **SQ, rot=-4, fx={"shake": [6, 5]}), K("batter_seq", 5, 2, **STH),
        K("batter_seq", 6, 10)]},
    "homer_batter": {"loop": False, "keys": [
        K("batter_seq", 6, 6, fx={"vibrate": [1, 18]}), K("accent", 4, 4, **ST, dy=-5), K("accent", 4, 3, **SQ),
        K("accent", 4, 4, **ST, dy=-4), K("accent", 4, 6, **SQ)]},
    "run": {"loop": True, "keys": [
        K("runner_seq", 1, 3, sx=1.05, sy=0.95), K("runner_seq", 2, 4, sx=0.96, sy=1.05, dy=-1),
        K("runner_seq", 3, 3, sx=1.05, sy=0.95), K("runner_seq", 4, 4, sx=0.96, sy=1.05, dy=-1)]},
    "slide": {"loop": False, "keys": [
        K("runner", 2, 2), K("runner", 3, 3, **STH, dx=2), K("runner", 3, 2, **SQ, fx={"shake": [4, 4]}),
        K("runner", 3, 12)]},
    # the slide sequence: run -> drop (or head-first dive) -> slide along the dirt -> squash at the
    # bag (shake) -> pop up (safe) or slump (out). runner frames 4 drop, 5 head-first, 6 pop-up, 7 slump
    "slide_safe": {"loop": False, "keys": [
        K("runner", 2, 2), K("runner", 4, 2, sx=0.92, sy=1.08, dy=-1), K("runner", 3, 3, **STH, dx=2),
        K("runner", 3, 4, sx=1.14, sy=0.88, dx=5), K("runner", 3, 2, **SQ, dx=6, fx={"shake": [4, 4]}),
        K("runner", 6, 3, **ST, dx=6, dy=-3), K("runner", 6, 12, dx=6)]},
    "slide_out": {"loop": False, "keys": [
        K("runner", 2, 2), K("runner", 4, 2, sx=0.92, sy=1.08, dy=-1), K("runner", 3, 3, **STH, dx=2),
        K("runner", 3, 4, sx=1.14, sy=0.88, dx=5), K("runner", 3, 2, **SQ, dx=6, fx={"shake": [4, 4]}),
        K("runner", 7, 2, **SQ, dx=6), K("runner", 7, 16, dx=6)]},
    "slide_head_safe": {"loop": False, "keys": [
        K("runner", 2, 2), K("runner", 5, 3, **STH, rot=-10, dy=-4), K("runner", 5, 4, sx=1.15, sy=0.88, dx=4),
        K("runner", 5, 2, **SQ2, dx=6, fx={"shake": [5, 4]}), K("runner", 6, 3, **ST, dx=6, dy=-3),
        K("runner", 6, 12, dx=6)]},
    "slide_head_out": {"loop": False, "keys": [
        K("runner", 2, 2), K("runner", 5, 3, **STH, rot=-10, dy=-4), K("runner", 5, 4, sx=1.15, sy=0.88, dx=4),
        K("runner", 5, 2, **SQ2, dx=6, fx={"shake": [5, 4]}), K("runner", 7, 2, **SQ, dx=6),
        K("runner", 7, 16, dx=6)]},
    "fielder_throw": {"loop": False, "keys": [
        K("fielder", 1, 4), K("fielder", 6, 4, **ST), K("pitcher_side_seq", 5, 2, **SQ),
        K("pitcher_side_seq", 6, 6), K("fielder", 1, 6)]},
    "catch": {"loop": False, "keys": [
        K("fielder", 4, 3, **ST, dy=-2), K("fielder", 1, 2, **SQ, fx={"shake": [3, 3]}), K("fielder", 1, 8)]},
    "dive": {"loop": False, "keys": [
        K("fielder", 2, 2), K("fielder", 5, 3, **STH, rot=-12, dy=-4), K("fielder", 5, 2, **SQ2, fx={"shake": [7, 5]}),
        K("fielder", 5, 12)]},
    "catcher_receive": {"loop": False, "boil": True, "keys": [
        K("catcher", 1, 8), K("catcher", 2, 2, **SQ, fx={"shake": [3, 3]}), K("catcher", 2, 8)]},
    "catcher_throw": {"loop": False, "keys": [
        K("catcher", 1, 4), K("catcher", 3, 4, **ST, dy=-1), K("catcher", 3, 2, **SQ), K("catcher", 3, 6)]},
    "ump_strike": {"loop": False, "keys": [
        K("umpire", 1, 6), K("umpire", 2, 3, **ST), K("umpire", 2, 2, **SQ),
        K("umpire", 2, 12, fx={"vibrate": [1, 10]})]},
    "ump_safe": {"loop": False, "keys": [
        K("umpire", 1, 6), K("umpire", 3, 2, sx=1.2, sy=0.85), K("umpire", 3, 12)]},
    "fan_cheer": {"loop": True, "boil": True, "keys": [
        K("fan", 1, 7), K("fan", 2, 5, **ST, dy=-1), K("fan", 2, 3)]},
    "mascot_wave": {"loop": True, "boil": True, "keys": [
        K("mascot", 1, 8), K("mascot", 2, 4, rot=5), K("mascot", 2, 4, rot=-5)]},
    "streaker": {"loop": True, "keys": [
        K("streaker", 1, 3, sx=1.05, sy=0.95), K("streaker", 2, 3, sx=0.95, sy=1.06, dy=-2)]},
    "cartwheel": {"loop": False, "keys": [
        K("fielder", 1, 3), K("accent", 1, 3, rot=-90, pivot="center", dx=4),
        K("accent", 1, 3, pivot="center", dx=8), K("accent", 1, 3, rot=90, pivot="center", dx=12),
        K("fielder", 1, 2, dx=16, **SQ), K("accent", 4, 8, dx=16)]},
    "backflip": {"loop": False, "keys": [
        K("fielder", 1, 3, **SQ), K("accent", 4, 3, **ST, dy=-4), K("accent", 2, 2, pivot="center", dy=-12),
        K("accent", 2, 2, rot=-90, pivot="center", dy=-14), K("accent", 2, 2, rot=-180, pivot="center", dy=-12),
        K("accent", 2, 2, rot=-270, pivot="center", dy=-6), K("fielder", 1, 3, **SQ2, fx={"shake": [5, 4]}),
        K("accent", 4, 8)]},
    "pratfall": {"loop": False, "keys": [
        K("fielder", 2, 3), K("accent", 3, 2, rot=20, dy=-6), K("accent", 3, 3, **SQ2, fx={"shake": [8, 6]}),
        K("accent", 3, 14)]},
    "celebrate": {"loop": True, "keys": [
        K("accent", 4, 4, **ST, dy=-5, fx={"vibrate": [1, 4]}), K("accent", 4, 3, **SQ), K("fan", 2, 4, flip=True)]},
    "turn": {"loop": False, "keys": [K("runner", 1, 2, sx=0.6), K("runner", 1, 2, sx=0.6, flip=True),
                                      K("runner", 1, 4, flip=True)]},
}
META = {"fps": 30, "anchor_1x": [14, 42], "center_1x": [14, 22],
        "shake_decay": 0.55, "boil": {"every": [6, 14], "len": [1, 2], "px": 1},
        "squash": SQ, "squash_big": SQ2, "stretch": ST, "stretch_h": STH}


# ---------------------------------------------------------------- reference transform
def load_tables(scale="1x"):
    import glob
    out = {}
    for p in glob.glob(os.path.join(hlib.PUPPETS_OUT, scale, "*-table-*.png")):
        b = os.path.basename(p)
        name, dims = b.split("-table-")
        w, h = (int(x) for x in dims[:-4].split("-"))
        a = np.asarray(Image.open(p).convert("LA"))
        out[name] = [a[:, i * w:(i + 1) * w] for i in range(a.shape[1] // w)]
    return out


def blit(dst, src, ax, ay, sx=1, sy=1, rot=0, flip=False, pivot="feet", k=1):
    """nearest-neighbour affine blit of an LA cell; (ax, ay) = ground point in dst"""
    h, w = src.shape[:2]
    px, py = 14 * k, (42 if pivot == "feet" else 22) * k
    oy = 0 if pivot == "feet" else -20 * k        # pivot position relative to the ground point
    c, s = math.cos(math.radians(rot)), math.sin(math.radians(rot))
    H, W = dst.shape[:2]
    R = int(max(w, h) * max(sx, sy) * 1.5) + 2
    for y in range(max(0, ay + oy - R), min(H, ay + oy + R)):
        for x in range(max(0, ax - R), min(W, ax + R)):
            u, v = x + 0.5 - ax, y + 0.5 - (ay + oy)
            u, v = (c * u + s * v), (-s * u + c * v)       # inverse rotation
            u, v = u / sx, v / sy
            if flip:
                u = -u
            i, j = int(math.floor(px + u)), int(math.floor(py + v))
            if 0 <= i < w and 0 <= j < h and src[j, i, 1] > 0:
                dst[y, x] = src[j, i, 0]


def play(track, tables, seed=1, k=1):
    """yield (key, extra) per 30 fps frame: extra = (rot, dx, dy) from fx/boil"""
    rnd = random.Random(seed)
    keys = track["keys"]
    nb = rnd.randint(*META["boil"]["every"]); boil_left = 0; bd = (0, 0)
    fx = []
    for key in keys:
        if "fx" in key:
            for name, (a, n) in key["fx"].items():
                fx.append([name, a, n, 0])
        for _ in range(key["hold"]):
            rot = dx = dy = 0
            for e in fx:
                name, a, n, i = e
                if i < n:
                    if name == "shake":
                        rot += a * (-1) ** i * META["shake_decay"] ** i
                    else:
                        dx += rnd.randint(-a, a); dy += rnd.randint(-a, a)
                    e[3] += 1
            if track.get("boil"):
                nb -= 1
                if nb <= 0:
                    boil_left = rnd.randint(*META["boil"]["len"]); bd = (rnd.randint(-1, 1), rnd.randint(-1, 1))
                    nb = rnd.randint(*META["boil"]["every"])
                if boil_left > 0:
                    dx += bd[0]; dy += bd[1]; boil_left -= 1
            yield key, (rot, dx, dy)


def preview(tables):
    os.makedirs(hlib.PREVIEW, exist_ok=True)
    W, H = 64, 60
    rows = []
    for name, tr in TRACKS.items():
        frames = []
        for key, (r, dx, dy) in play(tr, tables, seed=hash(name) & 0xffff):
            yy, xx = np.mgrid[0:H, 0:W]
            dst = np.where(((xx + yy) % 2 == 0) | ((xx % 4 == 1) & (yy % 2 == 1)), 0, 255).astype(np.uint8)
            cell = tables[key["t"]][key["f"] - 1]
            blit(dst, cell, 24 + key.get("dx", 0) + dx, 52 + key.get("dy", 0) + dy, key.get("sx", 1), key.get("sy", 1),
                 key.get("rot", 0) + r, key.get("flip", False), key.get("pivot", "feet"))
            frames.append(Image.fromarray(dst, "L"))
        big = [f.resize((W * 3, H * 3), Image.NEAREST) for f in frames]
        big[0].save(os.path.join(hlib.PREVIEW, f"anim_{name}.gif"), save_all=True, append_images=big[1:],
                    duration=33, loop=0)
        # every frame in a row (30 fps), for review
        strip = Image.new("L", (len(frames) * (W + 1), H + 10), 255)
        for i, f in enumerate(frames):
            strip.paste(f, (i * (W + 1), 10))
        from PIL import ImageDraw
        ImageDraw.Draw(strip).text((2, 0), name, fill=0)
        rows.append(strip)
    maxw = max(r.width for r in rows)
    sheet = Image.new("L", (min(maxw, 64 * 34), sum(r.height for r in rows)), 255)
    y = 0
    for r in rows:
        sheet.paste(r, (0, y)); y += r.height
    sheet.resize((sheet.width * 2, sheet.height * 2), Image.NEAREST).save(os.path.join(hlib.PREVIEW, "anim_tracks.png"))


def build(verbose=True):
    p = os.path.join(hlib.PUPPETS_OUT, "anim_tracks.json")
    doc = {"version": 1, "doc": "see images/README.md 'Puppet animatic tracks'", "meta": META, "tracks": TRACKS}
    # catcher reach grid: per frame of catcher_reach, the posed mitt centre in game feet relative to
    # the catcher's feet in HIS frame (x = toward his glove side is -x in the field when he faces +y)
    meta = json.load(open(os.path.join(hlib.RENDERS, "meta.json")))
    cr = meta["tables"].get("catcher_reach")
    if cr:
        doc["catcherReach"] = {"labels": [f["label"] for f in cr["frames"]], "glove": [f.get("glove") for f in cr["frames"]]}
    with open(p, "w") as f:
        f.write("{\n" + ",\n".join(f"{json.dumps(k)}: {json.dumps(v, separators=(',', ':'))}"
                                   for k, v in doc.items()) + "\n}\n")
    tables = load_tables()
    for tr in TRACKS.values():
        for key in tr["keys"]:
            assert key["t"] in tables and 1 <= key["f"] <= len(tables[key["t"]]), key
    preview(tables)
    if verbose:
        print("anim tracks:", len(TRACKS), "->", p)
    return p


if __name__ == "__main__":
    build()
