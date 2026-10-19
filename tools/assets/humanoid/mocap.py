"""Optional stage — MOCAP key poses from the CMU Graphics Lab Motion Capture Database
(http://mocap.cs.cmu.edu — "free for all uses"; may be included in commercial products, the raw
data may not be resold).  Trials used:
  124_01 "Baseball Pitch", 124_07 "Baseball Swing" (subject 124), 09_01 "run" (subject 9).

python3 mocap.py fetch         download the ASF/AMC files into cache/mocap_cmu/ (not shipped)
python3 mocap.py strips        stick-figure filmstrips in preview/mocap_<trial>.png to pick frames
python3 mocap.py export        write mocap/keyposes.json (the poses used by poses.py)

Retargeting is by *directions*: forward kinematics on the ASF skeleton gives every joint's world
position; each puppet bone is then aimed along the matching mocap segment (thigh = hip->knee, etc.),
with full frames (direction + left/right axis) for hips and chest so torso twist survives.  This is
independent of the mocap actor's proportions.  The clip is re-oriented so the figure's 'forward' is
the throw / swing / run direction, and mirrored when the actor is left-handed."""
import json, math, os, sys, urllib.request
import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hlib

RAW = os.path.join(hlib.CACHE, "mocap_cmu")
BASE = "http://mocap.cs.cmu.edu/subjects/"
FILES = ["124/124.asf", "124/124_01.amc", "124/124_07.amc", "09/09.asf", "09/09_01.amc"]


def fetch():
    os.makedirs(RAW, exist_ok=True)
    for f in FILES:
        p = os.path.join(RAW, os.path.basename(f))
        if not os.path.exists(p):
            urllib.request.urlretrieve(BASE + f, p)
    return RAW


# ---------------------------------------------------------------- ASF / AMC
def rotx(a):
    c, s = math.cos(a), math.sin(a); return np.array([[1, 0, 0], [0, c, -s], [0, s, c]])


def roty(a):
    c, s = math.cos(a), math.sin(a); return np.array([[c, 0, s], [0, 1, 0], [-s, 0, c]])


def rotz(a):
    c, s = math.cos(a), math.sin(a); return np.array([[c, -s, 0], [s, c, 0], [0, 0, 1]])


def euler_xyz(r):
    rx, ry, rz = np.radians(r)
    return rotz(rz) @ roty(ry) @ rotx(rx)


def parse_asf(path):
    bones = {"root": {"dir": np.zeros(3), "len": 0.0, "axis": np.zeros(3), "dof": ["rx", "ry", "rz"]}}
    hier = {}
    lines = [l.strip() for l in open(path)]
    i = 0
    sec = None
    cur = None
    while i < len(lines):
        l = lines[i]
        if l.startswith(":"):
            sec = l.split()[0]
        elif sec == ":root" and l.startswith("orientation"):
            bones["root"]["axis"] = np.array([float(x) for x in l.split()[1:4]])
        elif sec == ":bonedata":
            t = l.split()
            if t and t[0] == "begin":
                cur = {"dof": []}
            elif t and t[0] == "name":
                cur["name"] = t[1]
            elif t and t[0] == "direction":
                cur["dir"] = np.array([float(x) for x in t[1:4]])
            elif t and t[0] == "length":
                cur["len"] = float(t[1])
            elif t and t[0] == "axis":
                cur["axis"] = np.array([float(x) for x in t[1:4]])
            elif t and t[0] == "dof":
                cur["dof"] = t[1:]
            elif t and t[0] == "end":
                bones[cur["name"]] = cur
        elif sec == ":hierarchy":
            t = l.split()
            if t and t[0] not in ("begin", "end"):
                for c in t[1:]:
                    hier[c] = t[0]
        i += 1
    for n, b in bones.items():
        b["C"] = euler_xyz(b["axis"])
        b["Cinv"] = b["C"].T
        b["parent"] = hier.get(n)
    order = []

    def visit(n):
        order.append(n)
        for c, p in hier.items():
            if p == n:
                visit(c)
    visit("root")
    return bones, order


def parse_amc(path):
    frames, cur = [], None
    for l in open(path):
        l = l.strip()
        if not l or l.startswith("#") or l.startswith(":"):
            continue
        t = l.split()
        if t[0].isdigit() and len(t) == 1:
            cur = {}; frames.append(cur)
        elif cur is not None:
            cur[t[0]] = [float(x) for x in t[1:]]
    return frames


def fk(bones, order, fr):
    """world joint positions (end of each bone; 'root' = root position) and bone matrices"""
    pos, mat = {}, {}
    for n in order:
        b = bones[n]
        if n == "root":
            v = fr["root"]
            pos[n] = np.array(v[:3])
            M = euler_xyz(v[3:6])
            mat[n] = b["C"] @ M @ b["Cinv"]
            continue
        r = [0.0, 0.0, 0.0]
        for d, val in zip(b["dof"], fr.get(n, [])):
            r["xyz".index(d[1])] = val
        M = euler_xyz(r)
        mat[n] = mat[b["parent"]] @ b["C"] @ M @ b["Cinv"]
        pos[n] = pos[b["parent"]] + b["len"] * (mat[n] @ b["dir"])
    return pos, mat


class Clip:
    def __init__(self, asf, amc):
        self.bones, self.order = parse_asf(os.path.join(RAW, asf))
        self.frames = parse_amc(os.path.join(RAW, amc))
        self.P = [fk(self.bones, self.order, f)[0] for f in self.frames]
        # rest hip height (zero pose) for scaling
        zero = {"root": [0, 0, 0, 0, 0, 0]}
        p0, _ = fk(self.bones, self.order, zero)
        foot = min(p0["ltoes"][1], p0["rtoes"][1], p0["lfoot"][1])
        self.hip_h = p0["root"][1] - foot

    def joints(self, i):
        p = self.P[i]
        return {"hip.L": p["lhipjoint"], "hip.R": p["rhipjoint"], "knee.L": p["lfemur"], "knee.R": p["rfemur"],
                "ankle.L": p["ltibia"], "ankle.R": p["rtibia"], "toe.L": p["lfoot"], "toe.R": p["rfoot"],
                "pelvis": p["root"], "spine": p["lowerback"], "chest": p["upperback"], "thorax": p["thorax"],
                "neck": p["upperneck"], "head": p["head"],
                "sh.L": p["lclavicle"], "sh.R": p["rclavicle"], "el.L": p["lhumerus"], "el.R": p["rhumerus"],
                "wr.L": p["lradius"], "wr.R": p["rradius"], "hand.L": p["lhand"], "hand.R": p["rhand"]}


# ---------------------------------------------------------------- frame conversion
def basis(fwd):
    """CMU is Y-up.  returns function world vec -> (left, forward, up)"""
    f = np.array([fwd[0], 0, fwd[2]]); f /= np.linalg.norm(f)
    up = np.array([0, 1.0, 0])
    left = np.cross(up, f)
    return lambda v: np.array([v @ left, v @ f, v[1]])


def unit(v):
    n = np.linalg.norm(v)
    return v / n if n > 1e-9 else v


def to_pose(clip, i, fwd, mirror=False, ground_ref=None):
    J = clip.joints(i)
    cv = basis(fwd)
    L = {k: cv(v) for k, v in J.items()}
    if mirror:   # swap sides and negate 'left' -> right-handed version of a left-handed actor
        M = {}
        for k, v in L.items():
            k2 = k.replace(".L", ".X").replace(".R", ".L").replace(".X", ".R")
            M[k2] = v * np.array([-1, 1, 1])
        L = M
    s = 0.89 / clip.hip_h          # scale positions to the puppet (pelvis height 0.89 m)
    foot_y = min(L["ankle.L"][2], L["ankle.R"][2], L["toe.L"][2], L["toe.R"][2])
    # anchor: lower ankle if one foot is clearly up, else between the feet
    if abs(L["ankle.L"][2] - L["ankle.R"][2]) > 0.15 / s:
        anc = L["ankle.L"] if L["ankle.L"][2] < L["ankle.R"][2] else L["ankle.R"]
    else:
        anc = (L["ankle.L"] + L["ankle.R"]) / 2
    if ground_ref is not None:
        anc = ground_ref
    pel = (L["hip.L"] + L["hip.R"]) / 2
    pv = (pel - np.array([anc[0], anc[1], foot_y])) * s
    V = lambda v: ["V", round(float(v[0]), 4), round(float(v[1]), 4), round(float(v[2]), 4)]
    d = lambda a, b: V(unit(L[b] - L[a]))
    pose = {"pelvis": V(pv + np.array([0, 0, 0.0])),
            "hips": {"frame": d("pelvis", "spine"), "side": V(unit(L["hip.L"] - L["hip.R"]))},
            "spine": d("spine", "chest"),
            "chest": {"frame": d("chest", "thorax"), "side": V(unit(L["sh.L"] - L["sh.R"]))},
            "neck": d("thorax", "neck"), "head": d("neck", "head")}
    for sd in "LR":
        pose["upper_arm." + sd] = d("sh." + sd, "el." + sd)
        pose["forearm." + sd] = d("el." + sd, "wr." + sd)
        pose["hand." + sd] = d("wr." + sd, "hand." + sd)
        pose["thigh." + sd] = d("hip." + sd, "knee." + sd)
        pose["shin." + sd] = d("knee." + sd, "ankle." + sd)
        pose["foot." + sd] = d("ankle." + sd, "toe." + sd)
    # two-handed grip: the bat axis runs from the bottom (left) hand through the top (right) hand
    gl = (L["wr.L"] + L["hand.L"]) / 2; gr = (L["wr.R"] + L["hand.R"]) / 2
    pose["_grip"] = V(unit(gr - gl))
    return pose


# ---------------------------------------------------------------- clip set-up (orientation, handedness)
def throw_arm(clip):
    sp = {}
    for sd in "LR":
        w = np.array([clip.joints(i)["wr." + sd] for i in range(len(clip.frames))])
        sp[sd] = np.max(np.linalg.norm(np.diff(w, axis=0), axis=1))
    return max(sp, key=sp.get)


def clip_forward(clip, kind, i0=0, i1=-1):
    if kind == "travel":       # running: overall root travel
        a, b = clip.P[i0]["root"], clip.P[i1]["root"]
        return b - a
    J = clip.joints(i0)
    if kind == "stride":       # pivot (right) ankle at the set -> landing (left) ankle at release
        a = clip.joints(i0)["ankle.R"]; b = clip.joints(i1)["ankle.L"]
        return b - a
    if kind == "throw":        # horizontal direction of the throwing wrist at its fastest
        sd = throw_arm(clip)
        w = np.array([clip.joints(i)["wr." + sd] for i in range(len(clip.frames))])
        v = np.diff(w, axis=0); k = int(np.argmax(np.linalg.norm(v, axis=1)))
        return w[min(k + 3, len(w) - 1)] - w[max(k - 3, 0)]
    if kind == "facing":       # hips facing at frame i0: forward = left x up (Y-up)
        side = J["hip.L"] - J["hip.R"]
        return np.cross(side, np.array([0, 1.0, 0]))
    raise ValueError(kind)


CLIPS = {
    "pitch1": ("124.asf", "124_01.amc"),
    "swing": ("124.asf", "124_07.amc"),
    "run": ("09.asf", "09_01.amc"),
}


def load(name):
    return Clip(*CLIPS[name])


# ---------------------------------------------------------------- filmstrips
SEG = [("hip.L", "knee.L"), ("knee.L", "ankle.L"), ("ankle.L", "toe.L"), ("hip.R", "knee.R"), ("knee.R", "ankle.R"),
       ("ankle.R", "toe.R"), ("pelvis", "spine"), ("spine", "chest"), ("chest", "thorax"), ("thorax", "neck"),
       ("neck", "head"), ("thorax", "sh.L"), ("sh.L", "el.L"), ("el.L", "wr.L"), ("thorax", "sh.R"), ("sh.R", "el.R"),
       ("el.R", "wr.R"), ("hip.L", "hip.R")]


def strip(name, step=None, view="side", fwd=None, out=None, a=0, b=None):
    from PIL import Image, ImageDraw
    c = load(name)
    n = len(c.frames)
    b = b or n
    step = step or max(1, (b - a) // 40)
    idx = list(range(a, b, step))
    fwd = fwd if fwd is not None else clip_fwd_for(name, c)
    cv = basis(fwd)
    W, H = 110, 150
    im = Image.new("RGB", (W * 10, H * ((len(idx) + 9) // 10)), "white")
    dr = ImageDraw.Draw(im)
    sc = 60 / c.hip_h
    for k, i in enumerate(idx):
        J = {a: cv(v) for a, v in c.joints(i).items()}
        ox, oy = (k % 10) * W + W // 2, (k // 10) * H + H - 15
        base = (J["ankle.L"] + J["ankle.R"]) / 2
        foot = min(J["toe.L"][2], J["toe.R"][2], J["ankle.L"][2], J["ankle.R"][2])

        def pt(v):
            h = v[1] - base[1] if view == "side" else -(v[0] - base[0])
            if view == "back":
                h = -(v[0] - base[0])
            return (ox + h * sc, oy - (v[2] - foot) * sc)
        for a, b in SEG:
            col = (200, 0, 0) if a.endswith(".R") or b.endswith(".R") else ((0, 0, 200) if a.endswith(".L") or b.endswith(".L") else (0, 0, 0))
            dr.line([pt(J[a]), pt(J[b])], fill=col, width=2)
        dr.text((ox - W // 2 + 3, oy - H + 18), str(i), fill=(0, 0, 0))
    p = out or os.path.join(hlib.PREVIEW, f"mocap_{name}_{view}.png")
    im.save(p)
    return p, n


# ---------------------------------------------------------------- export
# Key frames picked from the filmstrips (preview/mocap_*.png).  Both actors are right-handed
# (subject 124 throws right, strides with the left leg when batting), so nothing is mirrored.
SELECT = [{"key": "pitch_" + k, "clip": "pitch1", "frame": f} for k, f in
          (("set", 230), ("break", 300), ("kick", 342), ("stride", 400), ("cock", 433), ("release", 441),
           ("follow", 462))] + \
         [{"key": "swing_" + k, "clip": "swing", "frame": f} for k, f in
          (("stance", 280), ("load", 315), ("launch", 332), ("contact", 340), ("extend", 350), ("follow", 372))] + \
         [{"key": "run_" + k, "clip": "run", "frame": f} for k, f in
          (("a", 27), ("b", 72), ("pass_a", 45), ("pass_b", 0))]


def export():
    out = {}
    for spec in SELECT:
        name, i, key = spec["clip"], spec["frame"], spec["key"]
        c = CACHE_CLIPS.setdefault(name, load(name))
        fwd = clip_fwd_for(name, c)
        mirror = HANDED.get(name) == "L"
        out[key] = to_pose(c, i, fwd, mirror=mirror)
    os.makedirs(hlib.MOCAP, exist_ok=True)
    with open(os.path.join(hlib.MOCAP, "keyposes.json"), "w") as f:
        f.write("{\n" + ",\n".join(f"{json.dumps(k)}: {json.dumps(v)}" for k, v in out.items()) + "\n}\n")
    return out


CACHE_CLIPS = {}
HANDED = {}


FWD_KIND = {"pitch1": ("stride", 230, 447), "swing": ("facing", 0, -1), "run": ("travel", 0, -1)}


def clip_fwd_for(name, c):
    k, a, b = FWD_KIND.get(name, ("facing", 0, -1))
    return clip_forward(c, k, a, b)


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "export"
    if cmd == "fetch":
        print(fetch())
    elif cmd == "strips":
        for nm in (sys.argv[2].split(",") if len(sys.argv) > 2 else CLIPS):
            c = load(nm)
            print(nm, "frames", len(c.frames), "throw arm", throw_arm(c), "hip_h", round(c.hip_h, 2))
            a, b = (int(sys.argv[3]), int(sys.argv[4])) if len(sys.argv) > 4 else (0, None)
            for v in ("side", "back"):
                print(strip(nm, view=v, a=a, b=b))
    elif cmd == "export":
        print(len(export()), "key poses")
