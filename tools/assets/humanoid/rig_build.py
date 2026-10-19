"""Blender stage 1 — RIG.  blender -b -P rig_build.py

Opens source/Humanoid.blend (low-poly unrigged base mesh, A-pose, faces -Y, 1.8 m),
labels every face by the flat colour region of NonOverlapping.png under its UV centroid,
stylises the proportions for 40 px sprites (bigger head/hands/feet, slightly fatter limbs),
builds a 21-bone armature from the measured seam rings between colour regions, binds with
automatic (bone-heat) weights, then cleans the weights with the region labels (a leg vertex may
only follow hips/thigh/shin/foot of its own side, etc.) and smooths them.  Simple prop meshes
(cap, glove, mitt, bat, masks, chest protector, censor bar, boater, hair, mascot ball head) are
added and rigidly bound to their bones.  Writes cache/rig.blend, cache/rig.json (bone rest data)
and cache/mesh_faces.json (UVs + rest positions per face, for uniform.py)."""
import bpy, bmesh, json, math, os, sys
from collections import defaultdict
from mathutils import Vector, Matrix

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hlib

HEAD_S, HAND_S, FOOT_S, INFLATE_ARM, INFLATE_LEG, INFLATE_TORSO = 1.32, 1.35, 1.12, 0.014, 0.010, 0.006

bpy.ops.wm.open_mainfile(filepath=hlib.SOURCE_BLEND)
for o in list(bpy.data.objects):
    if o.name != "HumanoidBase_NotOverlapping":
        bpy.data.objects.remove(o, do_unlink=True)
body = bpy.data.objects["HumanoidBase_NotOverlapping"]
body.name = "Body"
me = body.data
# bake the object transform and centre on x=0
off = body.location.copy()
for v in me.vertices:
    v.co = v.co + off
body.location = (0, 0, 0)
xs = [v.co.x for v in me.vertices]
cx = (min(xs) + max(xs)) / 2
for v in me.vertices:
    v.co.x -= cx

# ---------------------------------------------------------------- labels from UV colour regions
img = bpy.data.images["NonOverlapping"]
W, H = img.size
px = list(img.pixels)


def sample(u, v):
    x = min(W - 1, max(0, int(u * W))); y = min(H - 1, max(0, int(v * H)))
    i = (y * W + x) * 4
    return tuple(round(c * 255) for c in px[i:i + 3])


uvl = me.uv_layers["UVMap"].data
face_part = {}
for p in me.polygons:
    c = Vector((0, 0))
    for li in p.loop_indices:
        c += uvl[li].uv
    c /= p.loop_total
    col = sample(c.x, c.y)
    best = min(hlib.REGIONS, key=lambda k: sum((a - b) ** 2 for a, b in zip(k, col)))
    face_part[p.index] = hlib.REGIONS[best]
vparts = defaultdict(set)
for p in me.polygons:
    for vi in p.vertices:
        vparts[vi].add(face_part[p.index])

orig_co = {v.index: v.co.copy() for v in me.vertices}


def ring(a, b, co=None):
    co = co or {v.index: v.co for v in me.vertices}
    vs = [co[i] for i, s in vparts.items() if a in s and b in s]
    return sum(vs, Vector()) / len(vs)


def side_of(x):
    return "L" if x > 0 else "R"


# per-vertex part label (feet split by side)
def vlabel(vi):
    s = vparts[vi]
    out = set()
    for p in s:
        if p == "foot":
            out.add("foot." + side_of(orig_co[vi].x))
        else:
            out.add(p)
    return out


# ---------------------------------------------------------------- stylise proportions
neck0 = ring("torso", "head")
wrists0 = {s: ring("arm." + s, "hand." + s) for s in "LR"}
ankles0 = {s: ring("leg." + s, "foot") if False else None for s in "LR"}
for s in "LR":
    vs = [orig_co[i] for i, p in vparts.items() if "foot" in p and ("leg." + s) in p]
    ankles0[s] = sum(vs, Vector()) / len(vs)

# smooth vertex normals for inflation
me.calc_normals_split() if hasattr(me, "calc_normals_split") else None
vnorm = {v.index: v.normal.copy() for v in me.vertices}
for v in me.vertices:
    co = orig_co[v.index].copy()
    lab = vlabel(v.index)
    # head: scale about the neck seam, blended over the neck
    if "head" in lab:
        t = max(0.0, min(1.0, (co.z - (neck0.z - 0.01)) / 0.06))
        s = 1 + (HEAD_S - 1) * t
        piv = Vector((0, neck0.y, neck0.z - 0.02))
        co = piv + (co - piv) * s
    for sd in "LR":
        if ("hand." + sd) in lab and ("arm." + sd) not in lab:
            co = wrists0[sd] + (co - wrists0[sd]) * HAND_S
        if ("foot." + sd) in lab and not any(p.startswith("leg") for p in lab):
            piv = Vector((ankles0[sd].x, ankles0[sd].y + 0.02, 0.0))
            d = co - piv
            co = piv + Vector((d.x * FOOT_S, d.y * FOOT_S, d.z * 1.05))
    if any(p.startswith("arm") for p in lab) and "torso" not in lab:
        co = co + vnorm[v.index] * INFLATE_ARM
    elif any(p.startswith("leg") for p in lab) and "torso" not in lab and not any(p.startswith("foot") for p in lab):
        co = co + vnorm[v.index] * INFLATE_LEG
    elif lab == {"torso"}:
        co = co + vnorm[v.index] * INFLATE_TORSO
    v.co = co
me.update()

# ---------------------------------------------------------------- joints
vco = {v.index: v.co for v in me.vertices}
neck = ring("torso", "head", vco)
head_top = max(v.co.z for v in me.vertices)
J = {}
J["root"] = (Vector((0, 0, 0)), Vector((0, 0, 0.25)))
pelvis = Vector((0, 0.0, 0.89))
J["hips"] = (pelvis, Vector((0, 0.0, 1.04)))
J["spine"] = (Vector((0, 0.0, 1.04)), Vector((0, 0.0, 1.24)))
J["chest"] = (Vector((0, 0.0, 1.24)), Vector((0, 0.0, neck.z - 0.04)))
J["neck"] = (Vector((0, 0.0, neck.z - 0.04)), Vector((0, neck.y, neck.z + 0.05)))
J["head"] = (Vector((0, neck.y, neck.z + 0.05)), Vector((0, neck.y, head_top)))
for s, sg in (("L", 1), ("R", -1)):
    sh = ring("torso", "arm." + s, vco); sh = Vector((sh.x * 0.97, 0.0, sh.z - 0.025))
    wr = ring("arm." + s, "hand." + s, vco)
    el = sh.lerp(wr, 0.49) + Vector((0, 0.012, 0))
    hv = [vco[i] for i, p in vparts.items() if p == {"hand." + s}]
    tip = max(hv, key=lambda c: (c - wr).length)
    hand_tail = wr + (tip - wr) * 0.75
    J["clavicle." + s] = (Vector((sg * 0.03, 0.0, sh.z - 0.01)), sh)
    J["upper_arm." + s] = (sh, el)
    J["forearm." + s] = (el, wr)
    J["hand." + s] = (wr, hand_tail)
    hp = ring("torso", "leg." + s, vco); hp = Vector((hp.x * 0.85, 0.0, pelvis.z))
    fv = [vco[i] for i, p in vparts.items() if any(q == "foot" for q in p) and (vco[i].x * sg) > 0]
    an = Vector((sum(c.x for c in fv) / len(fv) * 0.97, 0.0, 0.0))
    an.z = max(c.z for c in fv) - 0.005
    an.y = 0.005
    kn = hp.lerp(an, 0.5) + Vector((0, -0.015, 0))
    toe = min(fv, key=lambda c: c.y)
    J["thigh." + s] = (hp, kn)
    J["shin." + s] = (kn, an)
    J["foot." + s] = (an, Vector((an.x, toe.y + 0.03, 0.025)))
# prop bones
J["glove"] = (J["hand.L"][1].copy(), J["hand.L"][1] + Vector((0, 0, 0.12)))
J["bat"] = (J["hand.R"][0].lerp(J["hand.R"][1], 0.6), J["hand.R"][0].lerp(J["hand.R"][1], 0.6) + Vector((0, 0, 0.84)))
PARENT = {"hips": "root", "spine": "hips", "chest": "spine", "neck": "chest", "head": "neck",
          "glove": "hand.L", "bat": "hand.R"}
for s in "LR":
    PARENT.update({"clavicle." + s: "chest", "upper_arm." + s: "clavicle." + s, "forearm." + s: "upper_arm." + s,
                   "hand." + s: "forearm." + s, "thigh." + s: "hips", "shin." + s: "thigh." + s,
                   "foot." + s: "shin." + s})
CONNECT = {"spine", "chest", "neck", "head", "forearm.L", "forearm.R", "hand.L", "hand.R", "shin.L", "shin.R",
           "foot.L", "foot.R", "upper_arm.L", "upper_arm.R"}
ORDER = ["root", "hips", "spine", "chest", "neck", "head",
         "clavicle.L", "upper_arm.L", "forearm.L", "hand.L", "glove",
         "clavicle.R", "upper_arm.R", "forearm.R", "hand.R", "bat",
         "thigh.L", "shin.L", "foot.L", "thigh.R", "shin.R", "foot.R"]
DEFORM_BODY = [b for b in ORDER if b not in ("root", "glove", "bat")]
DEFORM = [b for b in ORDER if b != "root"]   # prop bones deform their prop meshes only

arm_data = bpy.data.armatures.new("Rig")
rig = bpy.data.objects.new("Rig", arm_data)
bpy.context.scene.collection.objects.link(rig)
bpy.context.view_layer.objects.active = rig
bpy.ops.object.mode_set(mode="EDIT")
eb = {}
for name in ORDER:
    h, t = J[name]
    b = arm_data.edit_bones.new(name)
    b.head, b.tail = h, t
    b.roll = 0
    eb[name] = b
for name, par in PARENT.items():
    eb[name].parent = eb[par]
    eb[name].use_connect = name in CONNECT and (eb[par].tail - eb[name].head).length < 1e-4
for name in ORDER:
    arm_data.edit_bones[name].use_deform = name in DEFORM
bpy.ops.object.mode_set(mode="OBJECT")

# ---------------------------------------------------------------- bind: automatic weights + cleanup
bpy.ops.object.select_all(action="DESELECT")
body.select_set(True); rig.select_set(True)
bpy.context.view_layer.objects.active = rig
ok = True
try:
    bpy.ops.object.parent_set(type="ARMATURE_AUTO")
except Exception as e:  # bone heat can fail on non-manifold meshes
    print("auto weights failed:", e); ok = False
if not body.vertex_groups:
    ok = False
    bpy.ops.object.parent_set(type="ARMATURE_NAME")


def allowed(vi):
    lab = vlabel(vi)
    a = set()
    x = orig_co[vi].x
    for p in lab:
        if p == "head":
            a |= {"neck", "head"}
        elif p == "torso":
            a |= {"hips", "spine", "chest", "neck", "clavicle.L", "clavicle.R"}
            z = orig_co[vi].z
            if z > 1.30:
                a.add("upper_arm." + side_of(x))
            if z < 1.00:
                a.add("thigh." + side_of(x))
        elif p.startswith("arm."):
            s = p[-1]; a |= {"clavicle." + s, "upper_arm." + s, "forearm." + s, "hand." + s}
            if orig_co[vi].z > 1.35:
                a.add("chest")
        elif p.startswith("hand."):
            s = p[-1]; a |= {"forearm." + s, "hand." + s}
        elif p.startswith("leg."):
            s = p[-1]; a |= {"thigh." + s, "shin." + s, "foot." + s}
            if orig_co[vi].z > 0.80:
                a.add("hips")
        elif p.startswith("foot."):
            s = p[-1]; a |= {"shin." + s, "foot." + s}
    return a


def seg_dist(p, a, b):
    ab = b - a
    t = max(0.0, min(1.0, (p - a).dot(ab) / ab.length_squared))
    return (a + ab * t - p).length


def proximity(vi, names):
    p = vco[vi]
    w = {n: 1.0 / max(0.01, seg_dist(p, *J[n])) ** 4 for n in names}
    s = sum(w.values())
    return {n: x / s for n, x in w.items()}


vg = {g.index: g.name for g in body.vertex_groups}
for n in DEFORM_BODY:
    if n not in body.vertex_groups:
        body.vertex_groups.new(name=n)
WT = {}
for v in me.vertices:
    al = allowed(v.index)
    w = {}
    if ok:
        for g in v.groups:
            nm = body.vertex_groups[g.group].name
            if nm in al and g.weight > 1e-4:
                w[nm] = g.weight
    if sum(w.values()) < 0.05:
        w = proximity(v.index, al)
    WT[v.index] = w
# smoothing: average with mesh neighbours (restricted to the vertex's allowed set) twice
nbrs = defaultdict(set)
for e in me.edges:
    a, b = e.vertices; nbrs[a].add(b); nbrs[b].add(a)
for _ in range(2):
    WT2 = {}
    for vi, w in WT.items():
        al = allowed(vi)
        acc = defaultdict(float)
        for n, x in w.items():
            acc[n] += x * 2
        for nb in nbrs[vi]:
            for n, x in WT[nb].items():
                if n in al:
                    acc[n] += x / max(1, len(nbrs[vi])) * 1.0
        s = sum(acc.values())
        WT2[vi] = {n: x / s for n, x in acc.items() if x / s > 0.01}
    WT = WT2
# hard rules: head region rigid to head above the jaw; hands rigid to hand; feet to foot
for v in me.vertices:
    lab = vlabel(v.index)
    if lab == {"head"} and orig_co[v.index].z > neck0.z + 0.06:
        WT[v.index] = {"head": 1.0}
    for s in "LR":
        if lab == {"hand." + s}:
            WT[v.index] = {"hand." + s: 1.0}
        if lab == {"foot." + s}:
            WT[v.index] = {"foot." + s: 1.0}
for g in list(body.vertex_groups):
    body.vertex_groups.remove(g) if g.name not in DEFORM_BODY else None
for n in DEFORM_BODY:
    g = body.vertex_groups[n]
    g.remove(list(range(len(me.vertices))))
for vi, w in WT.items():
    s = sum(w.values())
    for n, x in w.items():
        body.vertex_groups[n].add([vi], x / s, "REPLACE")
print("weights:", "auto+cleanup" if ok else "proximity fallback")

# ---------------------------------------------------------------- props
props_col = bpy.data.collections.new("Props")
bpy.context.scene.collection.children.link(props_col)
hv = [v.co for v in me.vertices if vlabel(v.index) == {"head"}]
hmin = Vector((min(c.x for c in hv), min(c.y for c in hv), min(c.z for c in hv)))
hmax = Vector((max(c.x for c in hv), max(c.y for c in hv), max(c.z for c in hv)))
hc = (hmin + hmax) / 2
hr = (hmax - hmin) / 2
PROPS = {}


def make_prop(name, bone, cls, build):
    bm = bmesh.new()
    build(bm)
    m = bpy.data.meshes.new(name)
    bm.to_mesh(m); bm.free()
    for p in m.polygons:
        p.use_smooth = True
    o = bpy.data.objects.new(name, m)
    props_col.objects.link(o)
    o.parent = rig
    g = o.vertex_groups.new(name=bone)
    g.add(list(range(len(m.vertices))), 1.0, "REPLACE")
    mod = o.modifiers.new("Armature", "ARMATURE"); mod.object = rig
    o["cls"] = cls
    PROPS[name] = {"bone": bone, "cls": cls}
    return o


def xf(bm, scale=(1, 1, 1), rot=None, loc=(0, 0, 0), verts=None):
    verts = verts if verts is not None else bm.verts
    M = Matrix.Translation(loc)
    if rot:
        M = M @ rot.to_4x4()
    M = M @ Matrix.Diagonal((*scale, 1))
    bmesh.ops.transform(bm, matrix=M, verts=list(verts))


def sphere(bm, scale, loc, rot=None, seg=16, rings=10):
    r = bmesh.ops.create_uvsphere(bm, u_segments=seg, v_segments=rings, radius=1.0)
    xf(bm, scale, rot, loc, r["verts"])
    return r["verts"]


def box(bm, scale, loc, rot=None):
    r = bmesh.ops.create_cube(bm, size=2.0)
    xf(bm, scale, rot, loc, r["verts"])


def cyl(bm, r1, r2, depth, loc, rot=None, seg=12):
    r = bmesh.ops.create_cone(bm, cap_ends=True, segments=seg, radius1=r1, radius2=r2, depth=depth)
    xf(bm, (1, 1, 1), rot, loc, r["verts"])


def dome(bm, scale, loc, cut=-0.05, back_drop=0.0):
    vs = sphere(bm, (1, 1, 1), (0, 0, 0), seg=20, rings=12)
    kill = [v for v in vs if v.co.z < cut - (back_drop if v.co.y > 0.3 else 0)]
    bmesh.ops.delete(bm, geom=kill, context="VERTS")
    xf(bm, scale, None, loc)


capz = hc.z + hr.z * 0.22


def b_cap(bm):
    dome(bm, (hr.x * 1.10, hr.y * 1.08, hr.z * 0.86), (0, hc.y, capz))
    # brim: flat half-ellipse sticking out in front (-Y)
    r = bmesh.ops.create_cone(bm, cap_ends=True, segments=16, radius1=1, radius2=1, depth=0.016)
    xf(bm, (hr.x * 1.0, hr.y * 0.95, 1), None, (0, hc.y - hr.y * 0.75, capz + 0.004), r["verts"])


make_prop("cap", "head", hlib.BLACK, b_cap)


def b_hair(bm):
    dome(bm, (hr.x * 1.06, hr.y * 1.06, hr.z * 1.0), (0, hc.y + 0.008, hc.z + hr.z * 0.05), cut=0.25, back_drop=0.75)


make_prop("hair", "head", hlib.BLACK, b_hair)


def b_boater(bm):
    cyl(bm, hr.x * 1.12, hr.x * 1.08, hr.z * 0.32, (0, hc.y, hc.z + hr.z * 0.70))
    cyl(bm, hr.x * 1.75, hr.x * 1.75, 0.014, (0, hc.y, hc.z + hr.z * 0.55), seg=20)


make_prop("boater", "head", hlib.BLACK, b_boater)


def b_mask(bm):
    box(bm, (hr.x * 0.82, 0.025, hr.z * 0.70), (0, hmin.y - 0.012, hc.z - hr.z * 0.12))


make_prop("mask", "head", hlib.BLACK, b_mask)

chest_b = J["chest"]


def b_chestpro(bm):
    box(bm, (0.165, 0.035, 0.24), (0, -0.115, 1.18))


make_prop("chestpro", "chest", hlib.MID, b_chestpro)


def b_censor(bm):
    box(bm, (0.19, 0.155, 0.055), (0, -0.015, 0.86))


make_prop("censor", "hips", hlib.BLACK, b_censor)

hl0, hl1 = J["hand.L"]


def b_glove(bm):
    c = hl0.lerp(hl1, 0.6)
    sphere(bm, (0.065, 0.10, 0.11), (c.x + 0.02, c.y - 0.01, c.z))


make_prop("glove", "hand.L", hlib.BLACK, b_glove)


def b_mitt(bm):
    c = hl0.lerp(hl1, 0.6)
    sphere(bm, (0.08, 0.14, 0.14), (c.x + 0.03, c.y - 0.01, c.z))


make_prop("mitt", "hand.L", hlib.BLACK, b_mitt)

bh, bt = J["bat"]


def b_bat(bm):
    # knob slightly below the grip, barrel up the bone (+Z at rest)
    cyl(bm, 0.020, 0.036, 0.86, (bh.x, bh.y, bh.z + 0.43 - 0.06), seg=10)


make_prop("bat", "bat", hlib.BLACK, b_bat)


BALL_R = hr.z * 1.75
BALL_C = Vector((0, hc.y, hc.z + hr.z * 0.35))


def b_ballhead(bm):
    sphere(bm, (BALL_R, BALL_R, BALL_R), BALL_C, seg=24, rings=14)


make_prop("ballhead", "head", hlib.WHITE, b_ballhead)


def b_ballface(bm):
    R, c = BALL_R, BALL_C
    on = lambda d: c + d.normalized() * R * 1.0
    for sx in (-1, 1):  # eyes
        sphere(bm, (0.035, 0.03, 0.05), on(Vector((sx * 0.32, -1, 0.22))), seg=8, rings=6)
    for i in range(7):  # grin
        a = math.radians(-45 + i * 15)
        sphere(bm, (0.026, 0.026, 0.026), on(Vector((math.sin(a) * 0.55, -1, -0.30 - math.cos(a) * 0.18))), seg=6, rings=4)
    for sx in (-1, 1):  # the two seams, as C-shaped arcs of dots on the sides
        for i in range(11):
            a = math.radians(-75 + i * 15)
            d = Vector((sx * math.cos(a), 0.15 + 0.45 * (1 - math.cos(a)), math.sin(a)))
            sphere(bm, (0.022, 0.022, 0.022), on(d), seg=6, rings=4)


make_prop("ballface", "head", hlib.BLACK, b_ballface)

for o in props_col.objects:
    o.hide_render = True

# ---------------------------------------------------------------- outputs
os.makedirs(hlib.CACHE, exist_ok=True)
faces = []
for p in me.polygons:
    faces.append({"part": face_part[p.index],
                  "uv": [[round(uvl[li].uv.x, 6), round(uvl[li].uv.y, 6)] for li in p.loop_indices],
                  "co": [[round(c, 5) for c in orig_co[me.loops[li].vertex_index]] for li in p.loop_indices],
                  "n": [round(c, 4) for c in p.normal]})
json.dump({"faces": faces, "tex_size": [W, H]}, open(hlib.FACES_JSON, "w"))
bones = {}
for b in arm_data.bones:
    bones[b.name] = {"head": list(b.head_local), "tail": list(b.tail_local),
                     "parent": b.parent.name if b.parent else None}
rest_h = max(v.co.z for v in me.vertices)
json.dump({"bones": bones, "order": ORDER, "props": PROPS, "height_body": rest_h,
           "weights": "auto+cleanup" if ok else "proximity"}, open(hlib.RIG_JSON, "w"), indent=1)
bpy.ops.wm.save_as_mainfile(filepath=hlib.RIG_BLEND)
print("RIG OK", hlib.RIG_BLEND, "bones", len(ORDER), "height", rest_h)
