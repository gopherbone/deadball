"""Jersey numbers printed on the back: per-frame panel quads for bc3d (landmarks.json "jersey").

    blender -b cache/rig.blend -P render_frames.py -- --jersey cache/jersey_raw.json
    python3 tools/assets/humanoid/jersey.py [cache/jersey_raw.json] [--sheet out.png]

render_frames.py --jersey samples the number panel on the posed mesh (the rest-pose back, where
uniform.py paints the baked "7": JERSEY_X/Z, 7 x 5 glyph units = two 3x5 digits + a gap) and
projects every sample into the hi-res render canvas, with facing / lit / occluded flags. Here:

  1. the canvas -> 1x cell placement of each frame (sprites.py make_cell: shift + fit shrink, a
     uniform scale + offset) is recovered by fitting the frame's posed landmarks (head, nose, back,
     knees, ankles, elbows, wrists) to the shipped landmarks.json cells — no renders needed, and the
     residual checks that the poses still match the art;
  2. the panel samples are fitted with an affine map (u, v) -> cell px: P = O + (u-.5) U + (v-.5) V
     (u reads left to right as seen from behind, v top to bottom), so the digits follow the
     shoulders' slant, the twist (foreshortening) and the lean of the actual pose;
  3. each of the 7 x 5 glyph cells is marked hidden when an arm / glove / bat / the head is in front
     of it, or it wraps away from the camera; a frame shows a number only when the panel faces the
     camera (mean facing > FACE_MIN) and enough of it is clear.

Output: landmarks.json gains "jersey": {"<set>#<view>": string} (JSTRIDE chars a frame) and
"jerseyStride"; nothing else in the file changes. Per frame:
  12 chars  O.x O.y U.x U.y V.x V.y — 2 chars each, q = (v + 64) * 32, chars 32 + q // 94, 32 + q % 94
   1 char   '1' the number shows, '0' it doesn't (side/front views, wrapped, mostly occluded)
   7 chars  per glyph column (left to right), 5 bits (bit r = row r visible), chr(64 + bits)
   2 chars  the clear span of the panel across (u from, to; chr(40 + round(80 u))): no ink line (an
            arm's edge, the torso's side) touching the digits, found on the shipped art (2x where
            there is one; an occluder's own edge in a hidden cell doesn't count) — the runtime fits
            the digits in it, or drops the number when they'd squeeze under a px a column
"""
import json, os, sys
import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import hlib

JSTRIDE = 22
FACE_MIN = 0.42      # mean panel facing (cos) below which the number isn't drawn (side-on)
CELL_FACE = 0.2      # a glyph cell wrapped further round than this is hidden
OCC_FRAC = 0.34      # a glyph cell with this share of samples occluded is hidden
LM_KEYS = ["head", "nose", "back", "kneeL", "ankleL", "kneeR", "ankleR", "elbowL", "wristL", "elbowR", "wristR"]
LM_AT = [0, 2, 5, 8, 10, 12, 14, 16, 18, 20, 22]


def dec_lm(s, f):
    o = f * 24
    return [((ord(s[o + a]) - 40) * 0.5, (ord(s[o + a + 1]) - 40) * 0.5) for a in LM_AT]


def enc2(v):
    q = int(round((v + 64) * 32))
    q = max(0, min(94 * 94 - 1, q))
    return chr(32 + q // 94) + chr(32 + q % 94)


def dec2(s, o):
    return ((ord(s[o]) - 32) * 94 + (ord(s[o + 1]) - 32)) / 32.0 - 64


def fit_place(raw_lm, cell_lm):
    """canvas (hi-res px) -> cell (1x px): x' = a x + tx, y' = a y + ty (least squares)"""
    A, b = [], []
    for k, (cx, cy) in zip(LM_KEYS, cell_lm):
        x, y = raw_lm[k]
        A.append([x, 1, 0]); b.append(cx)
        A.append([y, 0, 1]); b.append(cy)
    A, b = np.array(A, float), np.array(b, float)
    sol, *_ = np.linalg.lstsq(A, b, rcond=None)
    res = A @ sol - b
    return sol, float(np.sqrt(np.mean(res ** 2))), float(np.max(np.abs(res)))


# ---------------------------------------------------------------- the shipped art (puppets.lua layout)
VIEW_SETS = [("pitcher_seq", 6, True, None), ("batter_seq", 6, True, None), ("catcher", 3, True, None),
             ("umpire", 3, False, None), ("fielder", 6, True, None), ("runner", 7, True, None),
             ("runner_seq", 4, True, None), ("catcher_reach", 14, True, [0, 2, 4, 6]), ("walker", 6, True, None),
             ("bunter", 5, True, None), ("fieldx", 13, True, [0, 2, 4, 6]), ("fieldin", 3, True, None)]
CLOSE_2X = {"pitcher_seq", "batter_seq", "catcher", "umpire", "fielder", "catcher_reach", "walker", "bunter",
            "fieldx", "fieldin"}
CHUNK_CAP = {1: 112, 2: 46}
_loc = {}
_tabs = {}


def _layout(sc):
    if sc in _loc:
        return _loc[sc]
    loc, chunk, n = {}, 1, 0
    for name, F, away, sub in VIEW_SETS:
        if sc == 2 and name not in CLOSE_2X:
            continue
        for suf in (["", "_away"] if away else [""]):
            for v in (sub or range(8)):
                if n > 0 and n + F > CHUNK_CAP[sc]:
                    chunk, n = chunk + 1, 0
                loc[f"{name}{suf}:{v}"] = (chunk, n)
                n += F
    _loc[sc] = loc
    return loc


def cell_image(ps, v, f, sc, suf=""):
    """(L 0/255, A) of a shipped cell, sc = 1 or 2 (None if not packed)"""
    from PIL import Image
    loc = _layout(sc).get(f"{ps}{suf}:{v}")
    if not loc:
        return None
    c, o = loc
    key = (sc, c)
    if key not in _tabs:
        cw, ch = (28, 44) if sc == 1 else (56, 88)
        path = os.path.join(hlib.PUPPETS_OUT, f"{sc}x", f"views_{c}-table-{cw}-{ch}.png")
        _tabs[key] = (Image.open(path).convert("LA"), cw, ch)
    im, cw, ch = _tabs[key]
    cols = im.width // cw
    k = o + f
    a = np.array(im.crop(((k % cols) * cw, (k // cols) * ch, (k % cols) * cw + cw, (k // cols) * ch + ch)))
    return a[..., 0].copy(), a[..., 1].copy()


SPAN_BINS = 28


def clear_span(key, f, O, U, V, vis, cols, rows):
    """the widest run of panel-u where the digits would sit clear of ink lines and hidden cells"""
    ps, v = key.split("#")
    sc = 2 if ps in CLOSE_2X else 1
    img = cell_image(ps, int(v), f, sc)
    ok = np.ones(SPAN_BINS, bool)
    if not vis.any():
        return 0.0, 0.0
    if img is not None:
        L, A = img
        op = A > 0
        blk = op & (L < 128)
        nb = np.zeros_like(blk, int)
        nb[1:, :] += blk[:-1, :]; nb[:-1, :] += blk[1:, :]; nb[:, 1:] += blk[:, :-1]; nb[:, :-1] += blk[:, 1:]
        ink = (blk & (nb >= 2)) | ~op         # solid black lines (not the away checker) and outside
        H, W = ink.shape
        det = U[0] * V[1] - U[1] * V[0]
        yy, xx = np.mgrid[0:H, 0:W]
        x = (xx + 0.5) / sc - O[0]; y = (yy + 0.5) / sc - O[1]
        uu = (x * V[1] - y * V[0]) / det + 0.5
        vv = (U[0] * y - U[1] * x) / det + 0.5
        # the baked "7" isn't an obstacle (it gets erased)
        baked = (uu > 2 / 7 - 0.03) & (uu < 5 / 7 + 0.03) & (vv > -0.05) & (vv < 1.05)
        # ink in a hidden cell is the occluder's own edge (the digits are hidden there anyway)
        gc = np.clip((uu * cols).astype(int), 0, cols - 1); gr = np.clip((vv * rows).astype(int), 0, rows - 1)
        hidden = ~vis[gc, gr]
        bad = ink & ~baked & ~hidden
        # touching the digits (an art px around them)
        r = 1
        badd = bad.copy()
        for dy in range(-r, r + 1):
            for dx in range(-r, r + 1):
                badd |= np.roll(np.roll(bad, dy, 0), dx, 1)
        sel = badd & (vv >= 0) & (vv < 1) & (uu >= 0) & (uu < 1)
        for b in np.unique((uu[sel] * SPAN_BINS).astype(int)):
            if 0 <= b < SPAN_BINS:
                ok[b] = False
    best, cur, bs = (0, 0), 0, 0
    for b in range(SPAN_BINS + 1):
        if b < SPAN_BINS and ok[b]:
            if cur == 0:
                bs = b
            cur += 1
        else:
            if cur > best[1] - best[0]:
                best = (bs, bs + cur)
            cur = 0
    return best[0] / SPAN_BINS, best[1] / SPAN_BINS


def frame_code(samples, place, cols, rows, key=None, f=0):
    a, tx, ty = place
    S = np.array([s for s in samples], float)
    if len(S) < 12:
        return None
    u, v = S[:, 2], S[:, 3]
    x, y = S[:, 4] * a + tx, S[:, 5] * a + ty
    face, occ = S[:, 6], S[:, 8]
    # affine fit over the samples facing the camera (the panel as seen), else all
    sel = face > 0.05
    if sel.sum() < 12:
        sel = np.ones_like(face, bool)
    M = np.stack([np.ones(sel.sum()), u[sel] - 0.5, v[sel] - 0.5], 1)
    cx, *_ = np.linalg.lstsq(M, x[sel], rcond=None)
    cy, *_ = np.linalg.lstsq(M, y[sel], rcond=None)
    err = np.hypot(M @ cx - x[sel], M @ cy - y[sel])
    O, U, V = (cx[0], cy[0]), (cx[1], cy[1]), (cx[2], cy[2])
    vis = np.zeros((cols, rows), bool)
    for c in range(cols):
        for r in range(rows):
            m = (S[:, 0] == c) & (S[:, 1] == r)
            if m.sum() == 0:
                continue
            vis[c, r] = face[m].mean() > CELL_FACE and occ[m].mean() < OCC_FRAC
    mean_face = float(face.mean())
    shows = mean_face > FACE_MIN and vis.sum() >= 0.5 * cols * rows
    s = enc2(O[0]) + enc2(O[1]) + enc2(U[0]) + enc2(U[1]) + enc2(V[0]) + enc2(V[1])
    ua, ub = clear_span(key, f, O, U, V, vis, cols, rows) if (shows and key) else (0.0, 0.0)
    if ub - ua < 3 / 7 - 1e-6:
        shows = False        # not even one digit fits clear
    s += "1" if shows else "0"
    for c in range(cols):
        bits = 0
        for r in range(rows):
            if vis[c, r]:
                bits |= 1 << r
        s += chr(64 + bits)
    s += chr(40 + int(round(ua * 80))) + chr(40 + int(round(ub * 80)))
    assert len(s) == JSTRIDE
    return s, dict(err=float(err.max()), rms=float(np.sqrt(np.mean(err ** 2))), face=mean_face,
                   shows=shows, clear=int(vis.sum()), O=O, U=U, V=V, vis=vis, span=(ua, ub))


def build(raw_path, lm_path, verbose=True):
    raw = json.load(open(raw_path))
    cols, rows = raw["cols"], raw["rows"]
    doc = json.load(open(lm_path))
    cells = doc["cells"]
    out, stats = {}, {}
    worst = (0, None)
    for tname, frames in sorted(raw["tables"].items()):
        ps, vid = tname.rsplit("_", 1)
        key = ps + "#" + vid[1:]
        if key not in cells:
            continue
        lmstr = cells[key]
        nf = len(lmstr) // 24
        if nf != len(frames):
            print("  frame count mismatch", key, nf, len(frames)); continue
        s = ""
        st = []
        for f, fr in enumerate(frames):
            place, rms, mx = fit_place(fr["lm"], dec_lm(lmstr, f))
            if mx > worst[0]:
                worst = (mx, f"{key} f{f + 1}")
            code = frame_code(fr["s"], place, cols, rows, key, f)
            if code is None:
                s += enc2(0) * 6 + "0" + chr(64) * cols + chr(40) + chr(40)
                st.append(None); continue
            s += code[0]
            code[1]["place_rms"] = rms
            st.append(code[1])
        out[key] = s
        stats[key] = st
    if verbose:
        n = sum(len(v) for v in stats.values())
        shown = sum(1 for v in stats.values() for x in v if x and x["shows"])
        perr = max((x["err"] for v in stats.values() for x in v if x and x["shows"]), default=0)
        print(f"  jersey: {len(out)} view rows, {n} frames, {shown} show a number; "
              f"placement fit worst {worst[0]:.2f} px ({worst[1]}); panel affine worst {perr:.2f} px (1x)")
    return out, stats, doc


def write(out, doc, lm_path):
    before = json.dumps({k: v for k, v in doc.items() if k not in ("jersey", "jerseyStride")}, sort_keys=True)
    doc["jersey"] = out
    doc["jerseyStride"] = JSTRIDE
    after = json.dumps({k: v for k, v in doc.items() if k not in ("jersey", "jerseyStride")}, sort_keys=True)
    assert before == after
    with open(lm_path, "w") as f:
        json.dump(doc, f, separators=(",", ":"))


# ---------------------------------------------------------------- reference renderer (sheets)
DIG = [[7, 5, 5, 5, 7], [2, 6, 2, 2, 7], [7, 1, 7, 4, 7], [7, 1, 3, 1, 7], [5, 5, 7, 1, 1],
       [7, 4, 7, 1, 7], [7, 4, 7, 5, 7], [7, 1, 1, 2, 2], [7, 5, 7, 5, 7], [7, 5, 7, 1, 1]]


JPAD = 0.12


def stamp(L, A, code, num, cs, away=False, cols=7, rows=5, flip=False):
    """Python mirror of bc3d.c's jersey stamp (LK_NUMBER, away style 0) on one cell image
    (L: 0/255 luma, A: alpha), cs = image px per 1x cell px. Home: black digits on the white
    jersey; away (50% checker): black digits on a light patch in the same quad. The digits sit in
    the clear span, glyph columns >= 1 px, or the number is dropped (the baked "7" erased)."""
    O = (dec2(code, 0), dec2(code, 2)); U = (dec2(code, 4), dec2(code, 6)); V = (dec2(code, 8), dec2(code, 10))
    if code[12] != "1":
        return L
    det = U[0] * V[1] - U[1] * V[0]
    if abs(det) < 1e-6:
        return L
    ja, jb = (ord(code[20]) - 40) / 80.0, (ord(code[21]) - 40) / 80.0
    sa, sb = (1 - jb, 1 - ja) if flip else (ja, jb)
    vis = [ord(code[13 + c]) - 64 for c in range(cols)]
    nd = 2 if num >= 10 else 1
    units = nd * 4 - 1
    wpx = np.hypot(U[0] * cs, U[1] * cs)
    span = sb - sa
    gu = min(1 / 7, span / units)
    if wpx * gu < 1:
        gu = 1 / max(wpx, 1e-3)
    u0 = (sa + sb) / 2 - units * gu / 2
    erase_only = units * gu > span + 0.002
    src = L
    L = L.copy()
    H, W = L.shape
    op = (A > 0)
    inner = op.copy()
    inner[1:, :] &= op[:-1, :]; inner[:-1, :] &= op[1:, :]; inner[:, 1:] &= op[:, :-1]; inner[:, :-1] &= op[:, 1:]

    def at(i, j):
        x, y = (i + 0.5) / cs - O[0], (j + 0.5) / cs - O[1]
        u = (x * V[1] - y * V[0]) / det + 0.5
        v = (U[0] * y - U[1] * x) / det + 0.5
        if u < 0 or u >= 1 or v < -JPAD or v >= 1 + JPAD:
            return -1
        gc, gr = int(u * cols), min(rows - 1, max(0, int(v * rows)))
        if not (vis[gc] >> gr) & 1:
            return -1
        r = 2 if (2 <= gc <= 4 and 0 <= v < 1) else 0
        uu = 1 - u if flip else u
        t = (uu - u0) / gu
        if -0.5 <= t < units - 0.5 and sa <= uu < sb:
            r |= 4
        if t < 0 or v < 0 or v >= 1 or erase_only:
            return r
        dc, row = int(t), int(v * rows)
        cx = dc % 4
        if cx < 3 and dc < units:
            digit = (num // 10 if dc < 4 else num % 10) if nd == 2 else num
            if (DIG[digit][row] >> (2 - cx)) & 1:
                r |= 1
        return r

    for j in range(H):
        for i in range(W):
            if not inner[j, i]:
                continue
            on = at(i, j)
            if on < 0:
                continue
            col = None
            if on & 1:
                col = 0
            elif away and not erase_only and (on & 4):
                col = 255
            elif (on & 2) and src[j, i] == 0:
                col = 255 if not away else (255 if (int((i + 0.5) / cs * 2) + int((j + 0.5) / cs * 2)) % 2 else 0)
            if col is not None:
                L[j, i] = col
    return L


if __name__ == "__main__":
    args = sys.argv[1:]
    raw = args[0] if args and not args[0].startswith("--") else os.path.join(hlib.CACHE, "jersey_raw.json")
    lm = os.path.join(hlib.PUPPETS_OUT, "landmarks.json")
    out, stats, doc = build(raw, lm)
    if "--dry" not in args:
        write(out, doc, lm)
        print("  ->", lm)
