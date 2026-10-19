"""Stage 4 — SPRITES (python3 + numpy/Pillow).

Turns the EEVEE data renders (cache/renders/<table>/NN_label.png: R class, G toon, B depth, A
coverage; SS hi-res px per 1x px) into 1-bit Playdate imagetables, 1x (28x44) and 2x (56x88):

  1. place: the field origin (ground point under the figure) lands on the anchor (14,42)/(28,84);
     frames that would leave the cell are shifted, then shrunk about the anchor (dive/slide).
  2. box-filter each output pixel's SSxSS (1x) or SS/2 (2x) block: coverage, class votes (black
     wins at >=30% so thin bats/socks survive), toon-lit fraction, depth-edge votes.
  3. ink: 1 px black contour just outside the silhouette + interior lines where the depth jumps
     (drawn on the far side, so the nearer limb keeps its full width); fills: white / jersey
     (white home, 50% checker away) / black / mid (checker); at 2x shadowed white gets a 25% dot.
  4. 1 px white halo around everything (8-neighbour), rest transparent.

Writes playdate/source/images/puppets/{1x,2x}/<table>-table-W-H.png (+ _away variants) and
contact sheets in preview/."""
import json, os, sys, glob
import numpy as np
from PIL import Image, ImageDraw

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hlib
from hlib import WHITE, JERSEY, BLACK, SKIN, SHIRT, MID, LIGHT

DEPTH_THR = 0.07           # metres; depth jump that draws an interior ink line
DEPTH_SCALE = hlib.DEPTH_RANGE / 255.0


def load(path):
    a = np.asarray(Image.open(path).convert("RGBA")).astype(np.int32)
    A = a[..., 3] > 127
    cls = np.where(A, np.rint(a[..., 0] / 16.0).astype(np.int32), 0)
    lit = a[..., 1] > 127
    dep = a[..., 2] * DEPTH_SCALE
    return A, cls, lit, dep


def resample(arrs, scale, cx, cy):
    """nearest-neighbour shrink of hi-res buffers by `scale` (<1) about (cx, cy)"""
    H, W = arrs[0].shape
    ys, xs = np.mgrid[0:H, 0:W]
    sx = np.rint((xs + 0.5 - cx) / scale + cx - 0.5).astype(int)
    sy = np.rint((ys + 0.5 - cy) / scale + cy - 0.5).astype(int)
    ok = (sx >= 0) & (sx < W) & (sy >= 0) & (sy < H)
    out = []
    for a in arrs:
        o = np.zeros_like(a)
        o[ok] = a[sy[ok], sx[ok]]
        out.append(o)
    return out


def depth_edges(A, dep):
    """far-side pixels of depth discontinuities (hi-res)"""
    E = np.zeros_like(A)
    for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0), (0, 2), (0, -2), (2, 0), (-2, 0)):
        qA = np.roll(np.roll(A, dy, 0), dx, 1)
        qd = np.roll(np.roll(dep, dy, 0), dx, 1)
        E |= A & qA & (qd < dep - DEPTH_THR)
    return E


def dil4(m):
    o = m.copy()
    o[1:] |= m[:-1]; o[:-1] |= m[1:]; o[:, 1:] |= m[:, :-1]; o[:, :-1] |= m[:, 1:]
    return o


def dil8(m):
    o = dil4(m)
    o[1:, 1:] |= m[:-1, :-1]; o[1:, :-1] |= m[:-1, 1:]; o[:-1, 1:] |= m[1:, :-1]; o[:-1, :-1] |= m[1:, 1:]
    return o


def make_cell(bufs, k, meta, fr, variant, place=None):
    A, cls, lit, dep = bufs
    SS = hlib.SS
    b = SS // k
    cw, ch = 28 * k, 44 * k
    ox, oy = hlib.ORIGIN_PX[0] * SS, hlib.ORIGIN_PX[1] * SS       # origin in hi-res px
    X0 = ox - 14 * k * b - fr.get("dx", 0) * SS
    Y0 = oy - 42 * k * b - fr.get("dy", 0) * SS
    # fit: keep the silhouette inside [2, cw-2) x [2, 42k] (room for ink + halo)
    ys, xs = np.nonzero(A)
    scale = fr.get("fit") or 1.0
    if len(xs):
        x_lo, x_hi = X0 + 2 * b, X0 + (cw - 2) * b
        y_lo = Y0 + 2 * b
        bw = xs.max() + 1 - xs.min()
        bh = oy - ys.min()
        s_auto = min(1.0, (x_hi - x_lo) / bw, (oy - y_lo) / max(1, bh))
        scale = min(scale, s_auto)
    if scale < 0.999:
        A, cls, lit, dep = resample([A, cls, lit, dep], scale, ox, oy)
        ys, xs = np.nonzero(A)
    if len(xs):
        x_lo, x_hi = X0 + 2 * b, X0 + (cw - 2) * b
        if xs.min() < x_lo:
            X0 -= int(np.ceil((x_lo - xs.min()) / b)) * b
        elif xs.max() + 1 > x_hi:
            X0 += int(np.ceil((xs.max() + 1 - x_hi) / b)) * b
    X0, Y0 = int(round(X0)), int(round(Y0))
    if place is not None:
        place.extend([X0, Y0, scale, ox, oy, b])
    E = depth_edges(A, dep)

    def blocks(a):
        H, W = a.shape
        pad = np.zeros((max(H, Y0 + ch * b) - min(0, Y0) + 1, max(W, X0 + cw * b) - min(0, X0) + 1), a.dtype)
        py, px = -min(0, Y0), -min(0, X0)
        pad[py:py + H, px:px + W] = a
        sub = pad[Y0 + py:Y0 + py + ch * b, X0 + px:X0 + px + cw * b]
        return sub.reshape(ch, b, cw, b).astype(np.float32).mean(axis=(1, 3))

    cov = blocks(A)
    black = blocks(A & (cls == BLACK))
    votes = {c: blocks(A & (cls == c)) for c in (WHITE, JERSEY, SKIN, SHIRT, MID, LIGHT)}
    litf = blocks(A & lit)
    edge = blocks(E)
    mask = (cov >= 0.5) | (black >= 0.3)
    isblack = (black >= 0.3) | (black >= 0.5 * np.maximum(cov, 1e-6))
    best = np.zeros((ch, cw), np.int32); bestv = np.zeros((ch, cw), np.float32)
    for c, v in votes.items():
        m = v > bestv
        best[m] = c; bestv[m] = v[m]
    best[isblack] = BLACK
    # ink
    ink_pre = mask & (edge * b >= 0.6) & ~isblack
    ink = (dil4(mask) & ~mask) | ink_pre
    yy, xx = np.mgrid[0:ch, 0:cw]
    checker = ((xx + yy) % 2) == 0
    jersey_gray = variant in ("away", "gray")
    out = np.ones((ch, cw), bool)          # True = white
    out[mask & (best == BLACK)] = False
    out[mask & (best == MID)] = ~checker[mask & (best == MID)]
    for c in (JERSEY, SHIRT):
        if jersey_gray:
            sel = mask & (best == c)
            out[sel] = ~checker[sel]
    if k == 2:   # toon shadow: 25% dots on shadowed white areas
        sh = mask & (litf < 0.4 * np.maximum(cov, 1e-6)) & ~isblack
        inner = mask & ~dil4(~mask | ink_pre)
        sh = sh & inner & ~dil4(~sh)          # eroded: no lone dots along the contour
        shade = sh & out & ((xx % 2 == 0) & (yy % 2 == 1))
        if jersey_gray:
            shade &= ~np.isin(best, (JERSEY, SHIRT))
        out[shade] = False
    out[ink] = False
    solid = mask | ink
    halo = dil8(solid) & ~solid
    alpha = solid | halo
    out[halo] = True
    L = np.where(out, 255, 0).astype(np.uint8)
    L[~alpha] = 255
    return L, (alpha * 255).astype(np.uint8)


def save_table(cells, out_dir, name, cols=None):
    w = cells[0][0].shape[1]; h = cells[0][0].shape[0]
    cols = cols or len(cells)
    if len(cells) % cols:        # pad the last grid row with empty (transparent) cells
        blank = (np.full((h, w), 255, np.uint8), np.zeros((h, w), np.uint8))
        cells = list(cells) + [blank] * (cols - len(cells) % cols)
    rows = [cells[i:i + cols] for i in range(0, len(cells), cols)]
    L = np.concatenate([np.concatenate([c[0] for c in r], axis=1) for r in rows], axis=0)
    A = np.concatenate([np.concatenate([c[1] for c in r], axis=1) for r in rows], axis=0)
    for old in glob.glob(os.path.join(out_dir, glob.escape(name) + "-table-*.png")):
        os.remove(old)
    path = os.path.join(out_dir, f"{name}-table-{w}-{h}.png")
    Image.fromarray(np.stack([L, A], -1), "LA").save(path, optimize=True)
    return path


def table_variants(name):
    import poses
    t = poses.TABLE_BY_NAME[name]
    return t.get("variants", [("", "home")])


def build(install=True, verbose=True, only=None):
    import poses
    meta = json.load(open(os.path.join(hlib.RENDERS, "meta.json")))
    sheets = {1: [], 2: []}
    views = {1: [], 2: []}
    written = []
    for t in poses.ALL_TABLES:
        name = t["name"]
        if only and name not in only and not any(name.startswith(o + "_") and t.get("multiview") for o in only):
            continue
        tm = meta["tables"].get(name)
        if not tm:
            print("missing renders for", name); continue
        bufs = [load(os.path.join(hlib.RENDERS, f["file"])) for f in tm["frames"]]
        for k in (1, 2):
            groups = t.get("variants", [("", "home")])
            for suffix, variant in groups:
                if isinstance(variant, list):    # several variants concatenated into one table (fan)
                    cells = [make_cell(bb, k, meta, f, v) for v in variant for bb, f in zip(bufs, tm["frames"])]
                else:
                    cells = [make_cell(bb, k, meta, f, variant) for bb, f in zip(bufs, tm["frames"])]
                tname = name + suffix
                if install:
                    d = os.path.join(hlib.PUPPETS_OUT, f"{k}x")
                else:
                    d = os.path.join(hlib.CACHE, "out", f"{k}x")
                os.makedirs(d, exist_ok=True)
                if t.get("multiview"):
                    views[k].append((tname, cells))
                    continue            # packed per pose set below, not written one table per view
                written.append(save_table(cells, d, tname))
                sheets[k].append((tname, cells))
    if not only:
        written += pack_views(views, sheets, install)
        written.append(write_landmarks(meta, install))
    contact(sheets)
    contact_views(views)
    if verbose:
        print("sprites:", len(written), "tables")
    return written


# ---------------------------------------------------------------- landmarks (runtime look overlays)
LM_KEYS = ["head", "nose", "back", "kneeL", "ankleL", "kneeR", "ankleR", "elbowL", "wristL", "elbowR", "wristR"]


def cell_landmarks(lm, place):
    """hi-res canvas points -> 1x cell px, through the cell's placement (shift + fit shrink)"""
    X0, Y0, scale, ox, oy, b = place
    out = {}
    for key in LM_KEYS:
        x, y = lm[key]
        if scale < 0.999:
            x, y = (x - ox) * scale + ox, (y - oy) * scale + oy
        out[key] = ((x - X0) / b, (y - Y0) / b)
    return out


def enc(v):
    """half-pixel precision in one printable char: v in [-4, 43] 1x px"""
    q = int(round(v * 2)) + 40
    return chr(max(32, min(126, q)))


def write_landmarks(meta, install=True):
    """images/puppets/landmarks.json: per view set + view, one string of 24 chars per frame:
    head, nose (x y), face code ('0' away, '1' profile, '2' toward camera), back (x y), back code
    ('0'/'1' number visible), knee/ankle L, knee/ankle R, elbow/wrist L, elbow/wrist R (x y each).
    Coordinates: 1x cell px (anchor 14,42), half-pixel steps, char = 40 + round(2v)."""
    import poses
    lmf = os.path.join(hlib.RENDERS, "landmarks.json")
    if not os.path.exists(lmf):
        print("  no landmarks (run render_frames.py --landmarks)"); return None
    LM = json.load(open(lmf))
    out = {}
    for ps in poses.POSESETS:
        for vid, _, _ in poses.VIEWS:
            tname = f"{ps['name']}_{vid}"
            t = poses.TABLE_BY_NAME.get(tname)
            tm = meta["tables"].get(tname)
            if not t or not tm or tname not in LM:
                continue
            s = ""
            for fi, fr in enumerate(tm["frames"]):
                bufs = load(os.path.join(hlib.RENDERS, fr["file"]))
                place = []
                make_cell(bufs, 1, meta, fr, "home", place)
                lm = LM[tname][fi]
                c = cell_landmarks(lm, place)
                fc = lm["face"]
                s += enc(c["head"][0]) + enc(c["head"][1]) + enc(c["nose"][0]) + enc(c["nose"][1])
                s += "2" if fc > 0.25 else ("1" if fc > -0.3 else "0")
                s += enc(c["back"][0]) + enc(c["back"][1]) + ("1" if lm["backv"] > 0.35 else "0")
                for key in LM_KEYS[3:]:
                    s += enc(c[key][0]) + enc(c[key][1])
            out[ps["name"] + "#" + vid[1:]] = s
    ppm1 = meta["ppm_hi"] / hlib.SS
    doc = {"version": 1, "doc": "tools/assets/humanoid/sprites.py write_landmarks", "headR": round(0.115 * ppm1, 2),
           "stride": 24, "cells": out}
    d = hlib.PUPPETS_OUT if install else os.path.join(hlib.CACHE, "out")
    p = os.path.join(d, "landmarks.json")
    with open(p, "w") as f:
        json.dump(doc, f, separators=(",", ":"))
    print("  landmarks:", len(out), "view rows ->", p)
    return p


# ---------------------------------------------------------------- contact sheets
def _bg(w, h, kind):
    if kind == 0:
        return np.full((h, w), 255, np.uint8)
    yy, xx = np.mgrid[0:h, 0:w]
    return np.where(((xx + yy) % 2 == 0) | ((xx % 4 == 1) & (yy % 2 == 1)), 0, 255).astype(np.uint8)


def compose(L, A, kind):
    h, w = L.shape
    bg = _bg(w, h, kind)
    return np.where(A > 0, L, bg)


def strip(name, cells, zoom, label=True):
    h, w = cells[0][0].shape
    gap = 4
    W = len(cells) * (w + gap) + gap
    img = np.full((h + 2 * gap, W), 255, np.uint8)
    for i, (L, A) in enumerate(cells):
        img[gap:gap + h, gap + i * (w + gap):gap + i * (w + gap) + w] = compose(L, A, i % 2 == 0)
    im = Image.fromarray(img, "L").resize((img.shape[1] * zoom, img.shape[0] * zoom), Image.NEAREST)
    if label:
        out = Image.new("L", (im.width, im.height + 12), 255)
        out.paste(im, (0, 12))
        ImageDraw.Draw(out).text((2, 0), name, fill=0)
        return out
    return im


def pack(strips, maxw):
    rows, cur, cw = [], [], 0
    for s in strips:
        if cw + s.width > maxw and cur:
            rows.append(cur); cur, cw = [], 0
        cur.append(s); cw += s.width + 6
    if cur:
        rows.append(cur)
    H = sum(max(s.height for s in r) + 6 for r in rows)
    W = max(sum(s.width + 6 for s in r) for r in rows)
    sheet = Image.new("L", (W, H), 255)
    y = 0
    for r in rows:
        x = 0
        for s in r:
            sheet.paste(s, (x, y)); x += s.width + 6
        y += max(s.height for s in r) + 6
    return sheet


# 2x view rows only for the sets that close cameras show big (memory + load time)
CLOSE_2X = {"pitcher_seq", "batter_seq", "catcher", "umpire", "fielder", "catcher_reach", "walker"}
# small single-view tables packed after the view rows (the face-less draws: celebrations, mascot, streaker)
LEGACY_ROWS = ["accent", "accent_away", "fan", "mascot", "streaker"]
CHUNK_CAP = {1: 112, 2: 46}     # cells per chunk file: each file loads in one ~40 ms loader slice on device


def pack_views(views, legacy, install=True):
    """All runtime puppet art in a few chunk files per scale: `views_<n>` (1x 28x44 / 2x 56x88).
    Cells run in this order, one ROW = F cells (frames 1..F):
      for set in poses.VIEW_SETS: for variant (home, _away if any): views v0..v7
      (2x: only CLOSE_2X sets), then LEGACY_ROWS (one row each).
    Rows never split; a new chunk starts when the next row would pass CHUNK_CAP.
    puppets.lua rebuilds the same layout from the same constants (and checks chunk lengths)."""
    import poses
    vids = [v for v, _, _ in poses.VIEWS]
    out = []
    for k in (1, 2):
        d = os.path.join(hlib.PUPPETS_OUT if install else os.path.join(hlib.CACHE, "out"), f"{k}x")
        for old in glob.glob(os.path.join(d, "*_views*-table-*.png")) + glob.glob(os.path.join(d, "views_*-table-*.png")):
            os.remove(old)
        by = {n: c for n, c in views[k]}
        rows = []
        for ps in poses.POSESETS:
            if k == 2 and ps["name"] not in CLOSE_2X:
                continue
            sub = poses.VIEW_SUBSET.get(ps["name"])
            for suffix, _ in ps["variants"]:
                for vi, vid in enumerate(vids):
                    if sub is not None and vi not in sub:
                        continue
                    rows.append(by[f"{ps['name']}_{vid}{suffix}"])
        lg = {n: c for n, c in legacy[k]}
        for n in LEGACY_ROWS:
            rows.append(lg[n])
        chunks, cur = [], []
        for r in rows:
            if cur and len(cur) + len(r) > CHUNK_CAP[k]:
                chunks.append(cur); cur = []
            cur = cur + list(r)
        if cur:
            chunks.append(cur)
        for i, c in enumerate(chunks):
            # grid width with the least padding (blank cells still cost RAM when decoded)
            cols = min(range(8, 17), key=lambda w: ((-len(c)) % w, -w))
            out.append(save_table(c, d, f"views_{i + 1}", cols=cols))
        print(f"  {k}x: {len(rows)} rows, {sum(len(c) for c in chunks)} cells in {len(chunks)} chunk files")
    return out


def contact_views(views):
    """per pose set: rows = frames, columns = views v0..v7 h0..h3 (home), 1x at zoom 3"""
    import poses
    by = {n: c for n, c in views[1]}
    blocks = []
    for ps in poses.POSESETS:
        cols = [by.get(f"{ps['name']}_{vid}") for vid, _, _ in poses.VIEWS]
        if not all(cols):
            continue
        nf = len(cols[0])
        rows = []
        for fi in range(nf):
            rows.append(strip("", [c[fi] for c in cols], 3, label=False))
        h = sum(r.height for r in rows) + 12
        b = Image.new("L", (rows[0].width, h), 255)
        ImageDraw.Draw(b).text((2, 0), ps["name"] + "  views: " + " ".join(f"{v}({a},{e})" for v, a, e in poses.VIEWS), fill=0)
        y = 12
        for r in rows:
            b.paste(r, (0, y)); y += r.height
        blocks.append(b)
    if blocks:
        pack(blocks, 1300).save(os.path.join(hlib.PREVIEW, "contact_views_1x_zoom3.png"))


def load_table(path, w, h):
    im = np.asarray(Image.open(path).convert("LA"))
    n = im.shape[1] // w
    return [(im[:, i * w:(i + 1) * w, 0], im[:, i * w:(i + 1) * w, 1]) for i in range(n)]


def contact(sheets):
    os.makedirs(hlib.PREVIEW, exist_ok=True)
    pack([strip(n + " 1x", c, 4) for n, c in sheets[1]], 1900).save(os.path.join(hlib.PREVIEW, "contact_1x_zoom4.png"))
    pack([strip(n + " 1x", c, 1) for n, c in sheets[1]], 700).save(os.path.join(hlib.PREVIEW, "contact_1x.png"))
    pack([strip(n + " 2x", c, 2) for n, c in sheets[2]], 1900).save(os.path.join(hlib.PREVIEW, "contact_2x_zoom2.png"))
    # before / after per table (legacy hand-drawn above, rendered below), 1x at zoom 4
    rows = []
    for n, cells in sheets[1]:
        lp = glob.glob(os.path.join(hlib.LEGACY, "1x", n + "-table-*.png"))
        if not lp:
            continue
        old = load_table(lp[0], 28, 44)
        a = strip(n + " legacy", old, 3); b = strip(n + " rendered", cells, 3)
        r = Image.new("L", (max(a.width, b.width), a.height + b.height), 255)
        r.paste(a, (0, 0)); r.paste(b, (0, a.height))
        rows.append(r)
    pack(rows, 1900).save(os.path.join(hlib.PREVIEW, "before_after_1x.png"))


if __name__ == "__main__":
    only = set(sys.argv[1].split(",")) if len(sys.argv) > 1 and sys.argv[1] != "--preview" else None
    build(install="--preview" not in sys.argv, only=only)
