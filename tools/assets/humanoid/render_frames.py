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
            mo = props["mitt"].evaluated_get(dg)
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
