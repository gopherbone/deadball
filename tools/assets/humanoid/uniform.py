"""Stage 2 — UNIFORM textures (plain python3 + numpy/Pillow).

Reads cache/mesh_faces.json (each face: region label from NonOverlapping.png, UVs, rest-pose 3D
positions), rasterises every UV triangle so each texel knows its body part and 3D rest position,
and paints one *class texture* per outfit: R channel = material class code * 16 (see hlib), which
the renderer emits unlit so sprites.py can map classes to 1-bit tones (white / 50% checker / black).
Also writes colourised previews (textures/<outfit>_preview.png) for humans.

Outfits: player (cap, white jersey with dark piping + number on back, belt, knickers, dark
stirrups/shoes, dark undershirt sleeves), umpire (dark suit), fan (shirt + dark trousers),
streaker (skin), mascot (white costume).  'jersey'/'shirt' classes become white (home) or gray
(away / gray-shirt fan) at sprite time, so away tables need no extra renders."""
import json, os, sys
import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hlib
from hlib import WHITE, JERSEY, BLACK, SKIN, SHIRT

SH = {"L": np.array([0.17, 1.42]), "R": np.array([-0.17, 1.42])}
WR = {"L": np.array([0.64, 1.148]), "R": np.array([-0.64, 1.148])}

# 3x5 digits for the number on the back
DIGITS = {"7": ["###", "..#", ".#.", ".#.", ".#."], "1": [".#.", "##.", ".#.", ".#.", "###"],
          "2": ["##.", "..#", ".#.", "#..", "###"], "4": ["#.#", "#.#", "###", "..#", "..#"]}


def rasterise(faces, size):
    W, H = size
    part = np.full((H, W), -1, np.int16)
    pos = np.zeros((H, W, 3), np.float32)
    nrm = np.zeros((H, W, 3), np.float32)
    names = sorted({f["part"] for f in faces})
    for f in faces:
        uv = np.array(f["uv"]) * [W, H]
        uv[:, 1] = H - uv[:, 1]
        co = np.array(f["co"])
        pid = names.index(f["part"])
        for i in range(1, len(uv) - 1):
            tri = uv[[0, i, i + 1]]; tco = co[[0, i, i + 1]]
            x0, y0 = np.floor(tri.min(0)).astype(int) - 1
            x1, y1 = np.ceil(tri.max(0)).astype(int) + 1
            x0, y0 = max(x0, 0), max(y0, 0); x1, y1 = min(x1, W - 1), min(y1, H - 1)
            ys, xs = np.mgrid[y0:y1 + 1, x0:x1 + 1]
            px = xs + 0.5; py = ys + 0.5
            (ax, ay), (bx, by), (cx, cy) = tri
            d = (by - cy) * (ax - cx) + (cx - bx) * (ay - cy)
            if abs(d) < 1e-9:
                continue
            l1 = ((by - cy) * (px - cx) + (cx - bx) * (py - cy)) / d
            l2 = ((cy - ay) * (px - cx) + (ax - cx) * (py - cy)) / d
            l3 = 1 - l1 - l2
            m = (l1 >= -0.02) & (l2 >= -0.02) & (l3 >= -0.02)
            p3 = l1[..., None] * tco[0] + l2[..., None] * tco[1] + l3[..., None] * tco[2]
            part[ys[m], xs[m]] = pid
            pos[ys[m], xs[m]] = p3[m]
            nrm[ys[m], xs[m]] = f["n"]
    return part, pos, nrm, names


def arm_t(x, z, side):
    a, b = SH[side], WR[side]
    d = b - a
    return ((np.stack([x, z], -1) - a) @ d) / (d @ d)


def paint(outfit, part, pos, nrm, names):
    H, W = part.shape
    cls = np.zeros((H, W), np.uint8)
    x, y, z = pos[..., 0], pos[..., 1], pos[..., 2]

    def P(name):
        return part == names.index(name) if name in names else np.zeros_like(part, bool)

    head, torso, foot = P("head"), P("torso"), P("foot")
    arms = {s: P("arm." + s) for s in "LR"}
    hands = {s: P("hand." + s) for s in "LR"}
    legs = P("leg.L") | P("leg.R")
    t_arm = {s: arm_t(x, z, s) for s in "LR"}

    if outfit in ("player", "mascot"):
        cls[head] = SKIN
        cls[torso] = JERSEY
        cls[torso & (z < 0.985)] = BLACK            # belt
        cls[torso & (z < 0.945)] = WHITE            # knickers
        if outfit == "player":
            cls[torso & (np.abs(x) < 0.013) & (y < -0.05) & (z > 1.0) & (z < 1.46)] = BLACK   # placket piping
            cls[torso & (z > 1.495)] = BLACK         # collar piping
            # number on the back
            digit = DIGITS["7"]
            bx0, bx1, bz0, bz1 = -0.07, 0.07, 1.14, 1.38
            m = torso & (y > 0.0) & (nrm[..., 1] > 0.2) & (x > bx0) & (x < bx1) & (z > bz0) & (z < bz1)
            gx = np.clip(((x - bx0) / (bx1 - bx0) * 3).astype(int), 0, 2)
            gz = np.clip(((bz1 - z) / (bz1 - bz0) * 5).astype(int), 0, 4)
            on = np.array([[c == "#" for c in row] for row in digit])
            cls[m & on[gz, gx]] = BLACK
        for s in "LR":
            cls[arms[s]] = JERSEY
            if outfit == "player":
                cls[arms[s] & (t_arm[s] > 0.47)] = BLACK      # dark undershirt sleeves
            cls[hands[s]] = SKIN if outfit == "player" else WHITE
        cls[legs] = WHITE
        cls[legs & (z < 0.50)] = BLACK                     # stirrup socks
        cls[foot] = BLACK
        if outfit == "mascot":
            cls[torso & (z >= 0.985)] = WHITE
            for s in "LR":
                cls[arms[s]] = WHITE
    elif outfit == "umpire":
        cls[torso | legs | foot | arms["L"] | arms["R"]] = BLACK
        cls[head] = SKIN
        cls[torso & (z > 1.47) & (y < -0.03)] = WHITE     # shirt collar
        for s in "LR":
            cls[hands[s]] = SKIN
    elif outfit == "fan":
        cls[head] = SKIN
        cls[torso] = SHIRT
        cls[torso & (z < 0.95)] = BLACK
        for s in "LR":
            cls[arms[s]] = SHIRT
            cls[hands[s]] = SKIN
        cls[legs | foot] = BLACK
    elif outfit == "streaker":
        cls[head | torso | legs | foot | arms["L"] | arms["R"] | hands["L"] | hands["R"]] = SKIN
    else:
        raise ValueError(outfit)
    # bleed into the gutters so 'closest' sampling at seams never hits background
    filled = cls > 0
    for _ in range(8):
        for dy, dx in ((0, 1), (0, -1), (1, 0), (-1, 0)):
            sh = np.roll(np.roll(cls, dy, 0), dx, 1)
            take = (~filled) & (sh > 0)
            cls[take] = sh[take]
            filled |= take
    return cls


OUTFITS = ["player", "umpire", "fan", "streaker", "mascot"]


def build(verbose=True):
    d = json.load(open(hlib.FACES_JSON))
    part, pos, nrm, names = rasterise(d["faces"], d["tex_size"])
    os.makedirs(hlib.TEXTURES, exist_ok=True)
    out = []
    for o in OUTFITS:
        cls = paint(o, part, pos, nrm, names)
        rgba = np.zeros(cls.shape + (4,), np.uint8)
        rgba[..., 0] = cls * 16; rgba[..., 3] = 255
        p = os.path.join(hlib.TEXTURES, f"{o}_class.png")
        Image.fromarray(rgba, "RGBA").save(p)
        prev = np.zeros(cls.shape + (3,), np.uint8)
        for k, c in hlib.CLASS_RGB.items():
            prev[cls == k] = c
        prev[part < 0] = (40, 40, 40)
        Image.fromarray(prev, "RGB").resize((512, 512), Image.NEAREST).save(
            os.path.join(hlib.TEXTURES, f"{o}_preview.png"))
        out.append(p)
    if verbose:
        print("uniform:", ", ".join(os.path.basename(p) for p in out))
    return out


if __name__ == "__main__":
    build()
