"""Blender stage 3 — RENDER.  blender -b cache/rig.blend -P render_frames.py -- [--tables a,b] [--debug]

For every table/frame in poses.TABLES: apply the pose (posing.Solver), drop the feet onto the
ground, aim an orthographic camera for the table's view and render one 16-bit RGBA "data" image
with EEVEE where every material is emission-only:
  R = material class (from the outfit's class texture or the prop's class), Closest sampling
  G = toon ramp (Diffuse BSDF -> Shader to RGB -> constant ramp, lit by a sun from camera-upper-left)
  B = view depth, A = coverage
sprites.py turns these into 1-bit cells (ink outline from silhouette + depth discontinuities,
white halo, class -> white / checker / black).  --debug instead renders shaded grey previews
(turntable + extreme poses) for checking the rig deformation."""
import bpy, json, math, os, sys
from mathutils import Vector, Matrix

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import hlib, posing, poses
import importlib
importlib.reload(poses)

argv = sys.argv[sys.argv.index("--") + 1:] if "--" in sys.argv else []
only = None
debug = "--debug" in argv
lmonly = "--landmarks" in argv      # no renders: posed joint positions per frame -> renders/landmarks.json
if "--tables" in argv:
    only = set(argv[argv.index("--tables") + 1].split(","))

sc = bpy.context.scene
rig = bpy.data.objects["Rig"]
body = bpy.data.objects["Body"]
props = {o.name: o for o in bpy.data.collections["Props"].objects}
rigj = json.load(open(hlib.RIG_JSON))
solver = posing.Solver(rig, rigj["order"])

# figure height (cap top to sole) in rest pose -> pixels per metre
cap_top = max(v.co.z for v in props["cap"].data.vertices)
H_REST = max(cap_top, rigj["height_body"])
PPM_HI = hlib.MASK_H_1X * hlib.SS / H_REST
CW, CH = hlib.CANVAS[0] * hlib.SS, hlib.CANVAS[1] * hlib.SS

# ---------------------------------------------------------------- materials
def data_material(name, cls=None, image=None):
    m = bpy.data.materials.new(name)
    m.use_nodes = True
    nt = m.node_tree
    for n in list(nt.nodes):
        nt.nodes.remove(n)
    out = nt.nodes.new("ShaderNodeOutputMaterial")
    em = nt.nodes.new("ShaderNodeEmission")
    comb = nt.nodes.new("ShaderNodeCombineColor")
    nt.links.new(comb.outputs[0], em.inputs["Color"])
    nt.links.new(em.outputs[0], out.inputs["Surface"])
    if image is not None:
        tex = nt.nodes.new("ShaderNodeTexImage")
        tex.image = image
        tex.interpolation = "Closest"
        sep = nt.nodes.new("ShaderNodeSeparateColor")
        nt.links.new(tex.outputs["Color"], sep.inputs[0])
        nt.links.new(sep.outputs[0], comb.inputs[0])
        m["tex_node"] = tex.name
    else:
        comb.inputs[0].default_value = cls * 16 / 255.0
    dif = nt.nodes.new("ShaderNodeBsdfDiffuse")
    s2r = nt.nodes.new("ShaderNodeShaderToRGB")
    nt.links.new(dif.outputs[0], s2r.inputs[0])
    sep2 = nt.nodes.new("ShaderNodeSeparateColor")
    nt.links.new(s2r.outputs[0], sep2.inputs[0])
    ramp = nt.nodes.new("ShaderNodeValToRGB")   # toon ramp: 2 constant steps
    ramp.color_ramp.interpolation = "CONSTANT"
    ramp.color_ramp.elements[0].color = (0, 0, 0, 1)
    ramp.color_ramp.elements[1].position = 0.18
    ramp.color_ramp.elements[1].color = (1, 1, 1, 1)
    nt.links.new(sep2.outputs[0], ramp.inputs[0])
    nt.links.new(ramp.outputs[0], comb.inputs[1])
    cam = nt.nodes.new("ShaderNodeCameraData")
    mr = nt.nodes.new("ShaderNodeMapRange")
    mr.inputs["From Min"].default_value = hlib.DEPTH_NEAR
    mr.inputs["From Max"].default_value = hlib.DEPTH_NEAR + hlib.DEPTH_RANGE
    nt.links.new(cam.outputs["View Z Depth"], mr.inputs["Value"])
    nt.links.new(mr.outputs["Result"], comb.inputs[2])
    return m


tex_images = {}
for o in ("player", "umpire", "fan", "streaker", "mascot"):
    im = bpy.data.images.load(os.path.join(hlib.TEXTURES, f"{o}_class.png"), check_existing=False)
    im.colorspace_settings.name = "Non-Color"
    tex_images[o] = im
body_mat = data_material("BodyData", image=tex_images["player"])
body.data.materials.clear(); body.data.materials.append(body_mat)
for n, o in props.items():
    o.data.materials.clear(); o.data.materials.append(data_material("P_" + n, cls=o["cls"]))
for p in body.data.polygons:
    p.use_smooth = True

# ---------------------------------------------------------------- scene / camera / light
for eng in ("BLENDER_EEVEE", "BLENDER_EEVEE_NEXT"):
    try:
        sc.render.engine = eng
        break
    except Exception:
        pass
sc.render.resolution_x, sc.render.resolution_y = CW, CH
sc.render.resolution_percentage = 100
sc.render.film_transparent = True
sc.render.filter_size = 0.0
try:
    sc.eevee.taa_render_samples = 1
except Exception:
    pass
sc.view_settings.view_transform = "Raw" if not debug else "Standard"
sc.view_settings.look = "None"
sc.render.image_settings.file_format = "PNG"
sc.render.image_settings.color_mode = "RGBA"
sc.render.image_settings.color_depth = "8"
sc.render.dither_intensity = 0.0
if sc.world is None:
    sc.world = bpy.data.worlds.new("W")
sc.world.use_nodes = True
bg = sc.world.node_tree.nodes.get("Background")
if bg:
    bg.inputs["Strength"].default_value = 0.0

cam_data = bpy.data.cameras.new("Cam")
cam_data.type = "ORTHO"
cam_data.ortho_scale = max(CW, CH) / PPM_HI
cam_data.clip_start, cam_data.clip_end = 0.1, 100
cam = bpy.data.objects.new("Cam", cam_data)
sc.collection.objects.link(cam)
sc.camera = cam
sun_data = bpy.data.lights.new("Sun", "SUN")
sun_data.energy = 3.0
sun_data.use_shadow = False
sun = bpy.data.objects.new("Sun", sun_data)
sc.collection.objects.link(sun)


def set_view(az, el):
    a, e = math.radians(az), math.radians(el)
    d = Vector((math.sin(a) * math.cos(e), -math.cos(a) * math.cos(e), math.sin(e)))
    fwd = -d
    right = fwd.cross(Vector((0, 0, 1))).normalized()
    up = right.cross(fwd).normalized()
    dx = hlib.ORIGIN_PX[0] * hlib.SS - CW / 2
    dy = hlib.ORIGIN_PX[1] * hlib.SS - CH / 2
    C = Vector((0, 0, 0)) - right * (dx / PPM_HI) + up * (dy / PPM_HI)
    cam.matrix_world = Matrix.Translation(C + d * hlib.CAM_DIST) @ fwd.to_track_quat("-Z", "Y").to_matrix().to_4x4()
    ldir = (fwd * 1.0 - up * 0.9 + right * 0.7).normalized()   # light travels from upper-left-front
    sun.matrix_world = ldir.to_track_quat("-Z", "Y").to_matrix().to_4x4()
    return right, up, fwd


def ground(pose):
    rig.location = (0, 0, 0)
    bpy.context.view_layer.update()
    if not pose.get("_ground", True):
        rig.location.z = pose.get("_lift", 0.0)
        return
    dg = bpy.context.evaluated_depsgraph_get()
    ev = body.evaluated_get(dg)
    m = ev.to_mesh()
    mz = min((ev.matrix_world @ v.co).z for v in m.vertices)
    ev.to_mesh_clear()
    rig.location.z = -mz + pose.get("_lift", 0.0)
    bpy.context.view_layer.update()


def show_props(names):
    for n, o in props.items():
        o.hide_render = n not in names


def set_outfit(outfit):
    nt = body_mat.node_tree
    nt.nodes[body_mat["tex_node"]].image = tex_images[outfit]


def render_to(path):
    sc.render.filepath = path
    bpy.ops.render.render(write_still=True)


# ---------------------------------------------------------------- debug: shaded turntable + extremes
if debug:
    sc.render.engine = "BLENDER_WORKBENCH"
    sc.display.shading.light = "STUDIO"
    sc.display.shading.color_type = "SINGLE"
    sc.display.shading.show_object_outline = True
    sc.render.film_transparent = False
    sc.render.resolution_x, sc.render.resolution_y = 300, 340
    cam_data.ortho_scale = 2.6
    show_props({"cap", "glove"})
    outd = os.path.join(hlib.CACHE, "debug")
    os.makedirs(outd, exist_ok=True)
    shots = []
    for i, az in enumerate(range(0, 360, 45)):
        shots.append(("turn%d" % az, {}, az))
    for nm, p in poses.DEBUG_POSES.items():
        for az in (0, 90, -45):
            shots.append((f"{nm}_{az}", p, az))
    for nm, p, az in shots:
        solver.apply(p); ground(p)
        right, up, fwd = set_view(az, 5)
        cam.location = cam.location + up * 0.25
        render_to(os.path.join(outd, nm + ".png"))
    json.dump([s[0] for s in shots], open(os.path.join(outd, "index.json"), "w"))
    print("DEBUG OK", len(shots))
    sys.exit(0)

# ---------------------------------------------------------------- landmarks (runtime overlays)
# Per table frame, a few posed joints projected into the same hi-res canvas the data renders use
# (sprites.py moves them with each cell's placement): head centre + a point 0.12 m in front of the
# face, the upper back (jersey number), knees/ankles, elbows/wrists; plus whether the face and the
# back are toward the camera. The runtime draws per-player details (facial hair, skin dither,
# number, socks, sleeves, helmet) on the billboard with these (bc3d look stamps).
def landmarks(Mp, right, up, fwd):
    W = rig.matrix_world
    R3 = W.to_3x3()
    cam_loc = cam.matrix_world.translation
    def px(P):
        q = P - cam_loc
        return [round(CW / 2 + q.dot(right) * PPM_HI, 1), round(CH / 2 - q.dot(up) * PPM_HI, 1)]
    def head(n):
        return W @ Mp[n].translation
    def fwd_of(n):
        D = Mp[n].to_3x3() @ solver.rest[n]["R"].inverted()
        return (R3 @ (D @ Vector((0, -1, 0)))).normalized()
    hc = (W @ (Mp["head"].translation)) * 0.45 + (W @ (Mp["head"] @ Vector((0, solver.rest["head"]["len"], 0)))) * 0.55
    hf = fwd_of("head")
    cf = fwd_of("chest")
    toCam = -fwd
    back = head("chest").lerp(head("neck"), 0.35)
    out = {"head": px(hc), "nose": px(hc + hf * 0.12), "face": round(hf.dot(toCam), 2),
           "back": px(back), "backv": round(-cf.dot(toCam), 2)}
    # the glove's centre (the fielders' catch poses: sprites.py turns it into cell px)
    dg = bpy.context.evaluated_depsgraph_get()
    go = props["glove"].evaluated_get(dg)
    gm = go.to_mesh()
    gc = sum((go.matrix_world @ v.co for v in gm.vertices), Vector()) / max(1, len(gm.vertices))
    go.to_mesh_clear()
    out["glove"] = px(gc)
    for s in ("L", "R"):
        out["knee" + s] = px(head("shin." + s)); out["ankle" + s] = px(head("foot." + s))
        out["elbow" + s] = px(head("forearm." + s)); out["wrist" + s] = px(head("hand." + s))
    return out


# ---------------------------------------------------------------- jersey panel (runtime numbers)
# The number is printed on the back of the jersey: a panel in the REST pose's mesh space (x across
# the back, z up; the back is +y — uniform.py paints the baked number in the same place). For every
# frame we find surface points on that panel (rest-pose ray hits, carried through the posed mesh by
# barycentric coords), project them like the landmarks, and test each against the camera: facing,
# lit (the toon ramp's sun) and occluded (an arm, the glove, the bat or the head in front). jersey.py
# fits these into a per-frame affine quad + occlusion grid for bc3d (landmarks.json "jersey").
JERSEY_X = (-0.165, 0.165)     # 7 glyph units: two 3x5 digits and a 1-unit gap
JERSEY_Z = (1.13, 1.39)        # 5 glyph units
JERSEY_COLS, JERSEY_ROWS = 7, 5
jersey_out = argv[argv.index("--jersey") + 1] if "--jersey" in argv else None


def jersey_setup():
    from mathutils.bvhtree import BVHTree
    me = body.data
    me.calc_loop_triangles()
    tris = [tuple(t.vertices) for t in me.loop_triangles]
    rest = [v.co.copy() for v in me.vertices]
    bvh = BVHTree.FromPolygons(rest, tris)
    samples = []    # (col, row, sub-u, sub-v) → (tri, barycentric)
    S = 3
    for r in range(JERSEY_ROWS):
        for c in range(JERSEY_COLS):
            for sv in range(S):
                for su in range(S):
                    u = (c + (su + 0.5) / S) / JERSEY_COLS       # 0 = reading left (screen left from behind)
                    v = (r + (sv + 0.5) / S) / JERSEY_ROWS       # 0 = top
                    # seen from behind, screen-left is +x (the figure faces -y)
                    x = JERSEY_X[1] - u * (JERSEY_X[1] - JERSEY_X[0])
                    z = JERSEY_Z[1] - v * (JERSEY_Z[1] - JERSEY_Z[0])
                    hit, nrm, ti, _ = bvh.ray_cast(Vector((x, 1.0, z)), Vector((0, -1, 0)))
                    if hit is None or nrm.y < 0.2:
                        continue
                    a, b, cc = (rest[i] for i in tris[ti])
                    w = barycentric(hit, a, b, cc)
                    samples.append((c, r, u, v, ti, w))
    return tris, samples


def barycentric(p, a, b, c):
    v0, v1, v2 = b - a, c - a, p - a
    d00, d01, d11 = v0.dot(v0), v0.dot(v1), v1.dot(v1)
    d20, d21 = v2.dot(v0), v2.dot(v1)
    den = d00 * d11 - d01 * d01
    if abs(den) < 1e-12:
        return (1.0, 0.0, 0.0)
    v = (d11 * d20 - d01 * d21) / den
    w = (d00 * d21 - d01 * d20) / den
    return (1.0 - v - w, v, w)


def jersey_frame(tris, samples, shown, right, up, fwd):
    """per sample: [col, row, u, v, x, y (hi-res canvas px), facing, lit, occluded]"""
    dg = bpy.context.evaluated_depsgraph_get()
    ev = body.evaluated_get(dg)
    m = ev.to_mesh()
    W = ev.matrix_world
    P = [W @ vv.co for vv in m.vertices]
    ev.to_mesh_clear()
    cam_loc = cam.matrix_world.translation
    toCam = -fwd
    sun_to = -(sun.matrix_world.to_3x3() @ Vector((0, 0, -1))).normalized()
    out = []
    for c, r, u, v, ti, w in samples:
        a, b, cc = (P[i] for i in tris[ti])
        p = a * w[0] + b * w[1] + cc * w[2]
        n = (b - a).cross(cc - a)
        if n.length < 1e-9:
            continue
        n.normalize()
        # the mesh winding: make the normal point away from the body (the back faces +y at rest)
        q = p - cam_loc
        facing = n.dot(toCam)
        lit = n.dot(sun_to)
        occ = 0
        if facing > 0.05:
            o = p + n * 0.004
            for _ in range(6):
                hit, loc, _n, _i, obj, _m = sc.ray_cast(dg, o, toCam, distance=10.0)
                if not hit:
                    break
                if obj.name == "Body" or obj.name in shown:
                    occ = 1
                    break
                o = loc + toCam * 0.002      # a hidden prop: look past it
        out.append([c, r, round(u, 4), round(v, 4), round(CW / 2 + q.dot(right) * PPM_HI, 2),
                    round(CH / 2 - q.dot(up) * PPM_HI, 2), round(facing, 3), round(lit, 3), occ])
    return out


if jersey_out:
    tris, samples = jersey_setup()
    # winding check: at rest the back's normals face +y
    rn = [(body.data.vertices[tris[s[4]][1]].co - body.data.vertices[tris[s[4]][0]].co).cross(
        body.data.vertices[tris[s[4]][2]].co - body.data.vertices[tris[s[4]][0]].co).y for s in samples]
    sign = 1 if sum(rn) >= 0 else -1
    if sign < 0:
        tris = [(t[0], t[2], t[1]) for t in tris]
        samples = [(c, r, u, v, ti, (w[0], w[2], w[1])) for c, r, u, v, ti, w in samples]
    print("JERSEY samples", len(samples), "winding", sign)
    res = {}
    for t in poses.ALL_TABLES:
        if not t.get("multiview") or t["outfit"] != "player":
            continue
        if only and not any(t["name"].startswith(o + "_") for o in only):
            continue
        fr = []
        for i, (label, pose) in enumerate(t["frames"]):
            shown = set(t.get("props", ())) | set(pose.get("_props", ())) - set(pose.get("_hide", ()))
            show_props(shown)
            for n_, o_ in props.items():
                o_.hide_viewport = n_ not in shown
            Mp = solver.apply(pose); ground(pose)
            view = pose.get("_view", t["view"])
            right, up, fwd = set_view(view[0], view[1])
            bpy.context.view_layer.update()
            fr.append({"lm": landmarks(Mp, right, up, fwd), "s": jersey_frame(tris, samples, shown, right, up, fwd)})
        res[t["name"]] = fr
        print("  jersey", t["name"], len(fr))
    json.dump({"cols": JERSEY_COLS, "rows": JERSEY_ROWS, "tables": res}, open(jersey_out, "w"), separators=(",", ":"))
    print("JERSEY OK", len(res), "tables")
    sys.exit(0)


if lmonly:
    lm_path = os.path.join(hlib.RENDERS, "landmarks.json")
    lmd = json.load(open(lm_path)) if (only and os.path.exists(lm_path)) else {}
    for t in poses.ALL_TABLES:
        if only and t["name"] not in only and not any(t["name"].startswith(o + "_") and t.get("multiview") for o in only):
            continue
        fr = []
        for i, (label, pose) in enumerate(t["frames"]):
            Mp = solver.apply(pose); ground(pose)
            view = pose.get("_view", t["view"])
            right, up, fwd = set_view(view[0], view[1])
            bpy.context.view_layer.update()
            fr.append(landmarks(Mp, right, up, fwd))
        lmd[t["name"]] = fr
    json.dump(lmd, open(lm_path, "w"), separators=(",", ":"))
    print("LANDMARKS OK", len(lmd), "tables")
    sys.exit(0)

# ---------------------------------------------------------------- data renders
meta = {"ppm_hi": PPM_HI, "ss": hlib.SS, "canvas": [CW, CH], "origin_px": hlib.ORIGIN_PX,
        "h_rest": H_REST, "tables": {}}
meta_path = os.path.join(hlib.RENDERS, "meta.json")
if os.path.exists(meta_path) and only:
    old = json.load(open(meta_path))
    meta["tables"] = old.get("tables", {})
for t in poses.ALL_TABLES:
    if only and t["name"] not in only and not any(t["name"].startswith(o + "_") and t.get("multiview") for o in only):
        continue
    d = os.path.join(hlib.RENDERS, t["name"])
    os.makedirs(d, exist_ok=True)
    set_outfit(t["outfit"])
    frames = []
    for i, (label, pose) in enumerate(t["frames"]):
        show_props(set(t.get("props", ())) | set(pose.get("_props", ())) - set(pose.get("_hide", ())))
        solver.apply(pose); ground(pose)
        view = pose.get("_view", t["view"])
        set_view(view[0], view[1])
        p = os.path.join(d, f"{i + 1:02d}_{label}.png")
        render_to(p)
        fr = {"file": os.path.relpath(p, hlib.RENDERS), "label": label,
              "dx": pose.get("_dx", 0), "dy": pose.get("_dy", 0), "fit": pose.get("_fit", None)}
        if t.get("glove"):
            # posed mitt centre in game feet, in the figure's frame: x = -left (it faces +y in the
            # field), y = forward, z = up (1 m = 6.2 ft / rest height, the sprite scale)
            dg = bpy.context.evaluated_depsgraph_get()
            gp = props["mitt"] if not props["mitt"].hide_render else props["glove"]
            mo = gp.evaluated_get(dg)
            mm = mo.to_mesh()
            cs = [mo.matrix_world @ v.co for v in mm.vertices]
            mo.to_mesh_clear()
            c = sum(cs, Vector()) / len(cs)
            ftm = 6.2 / H_REST
            fr["glove"] = [round(-c.x * ftm, 3), round(-c.y * ftm, 3), round(c.z * ftm, 3)]
        frames.append(fr)
    meta["tables"][t["name"]] = {"frames": frames, "outfit": t["outfit"]}
json.dump(meta, open(meta_path, "w"), indent=1)
print("RENDER OK", len(meta["tables"]), "tables")
