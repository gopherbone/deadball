"""Pose solver (runs inside Blender; uses mathutils only).

A pose is a dict in the character frame: vectors are V(left, forward, up) in metres, rotations
are (bend, side, twist) degrees (bend = lean forward, side = lean to the character's left,
twist = turn to the character's left).  Keys:

  root:        (bend, side, twist) of the whole figure (e.g. twist=-80 = turned to his right)
  pelvis:      V position of the hips joint (default rest, ~0.89 m up)
  hips/spine/chest/neck/head: rotation relative to the parent
  <bone>:      V direction the bone should point (minimal rotation from its inherited direction),
               or {"dir": V, "twist": deg} / {"rot": (b, s, t)} / {"abs": (b, s, t)} (world-frame)
  arm.L/R, leg.L/R: {"ik": V wrist/ankle position, "pole": V elbow/knee hint}  (two-bone IK)
  bat:         V direction of the bat (child of the right hand)
  _lift, _ground, _dx, _dy, _fit: placement hints (see render_frames.py / sprites.py)

All V vectors (positions and directions) are in the root frame, so 'root' twist turns the whole pose.
Feet default to flat on the ground pointing along the root frame's forward."""
import math
from mathutils import Vector, Matrix, Euler, Quaternion


from hlib import V  # noqa: F401  (re-exported)


def vec(t):
    # (l, f, u) -> armature xyz; the character faces -Y, its left is +X
    return Vector((t[1], -t[2], t[3]))


def rot(t):
    b, s, tw = t
    return Euler((math.radians(b), math.radians(s), math.radians(tw)), "XYZ").to_matrix()


class Solver:
    def __init__(self, rig, order):
        self.rig = rig
        self.order = order
        self.rest = {}
        for b in rig.data.bones:
            self.rest[b.name] = dict(M=b.matrix_local.copy(), R=b.matrix_local.to_3x3().normalized(),
                                     head=b.head_local.copy(), tail=b.tail_local.copy(),
                                     dir=(b.tail_local - b.head_local).normalized(),
                                     len=(b.tail_local - b.head_local).length,
                                     parent=b.parent.name if b.parent else None)

    def solve(self, pose):
        rs = self.rest
        D, Hd = {}, {}
        Droot = rot(pose.get("root", (0, 0, 0)))
        specs = dict(pose)

        def tv(t):  # root-frame vector -> armature space
            return Droot @ vec(t)

        def ik(chain_a, chain_b, base, target, pole):
            la, lb = rs[chain_a]["len"], rs[chain_b]["len"]
            d = target - base
            dist = max(1e-4, min(d.length, (la + lb) * 0.999))
            u = d.normalized()
            ca = (la * la + dist * dist - lb * lb) / (2 * la * dist)
            a = math.acos(max(-1, min(1, ca)))
            p = pole - u * pole.dot(u)
            if p.length < 1e-5:
                p = Vector((0, -1, 0)) - u * (-u.y)
            p.normalize()
            elbow = base + (u * math.cos(a) + p * math.sin(a)) * la
            end = base + u * dist
            return (elbow - base).normalized(), (end - elbow).normalized()

        for name in self.order:
            r = rs[name]
            par = r["parent"]
            if par is None:
                D[name] = Droot.copy()
                Hd[name] = r["head"].copy()
            else:
                Hd[name] = Hd[par] + D[par] @ (r["head"] - rs[par]["head"])
                D[name] = D[par].copy()
            if name == "hips" and "pelvis" in pose:
                Hd[name] = tv(pose["pelvis"])
            # IK requests resolve into direction specs for the chain
            for lim, (a, b) in (("arm.L", ("upper_arm.L", "forearm.L")), ("arm.R", ("upper_arm.R", "forearm.R")),
                                ("leg.L", ("thigh.L", "shin.L")), ("leg.R", ("thigh.R", "shin.R"))):
                if name == a and lim in pose and "ik" in pose[lim]:
                    spec = pose[lim]
                    side = 1 if lim.endswith("L") else -1
                    dpole = V(side * 1, -0.3, -1) if lim.startswith("arm") else V(side * 0.15, 1, 0)
                    d1, d2 = ik(a, b, Hd[name], tv(spec["ik"]), tv(spec.get("pole", dpole)))
                    specs[a] = ("dirv", d1, spec.get("twist", 0))
                    specs[b] = ("dirv", d2, spec.get("twist2", 0))
            spec = specs.get(name)
            if spec is None and name.startswith("foot."):
                spec = {"abs": (0, 0, 0)}
            if spec is None or name == "root":
                continue
            if isinstance(spec, tuple) and spec[0] == "V":
                spec = {"dir": spec}
            elif isinstance(spec, tuple) and spec[0] == "dirv":
                spec = {"dirv": spec[1], "twist": spec[2]}
            elif isinstance(spec, tuple):
                spec = {"rot": spec}
            if "rot" in spec:
                D[name] = D[name] @ rot(spec["rot"])
            elif "abs" in spec:
                D[name] = Droot @ rot(spec["abs"])
            elif "frame" in spec:   # absolute: bone axis along 'frame', its X (left) axis toward 'side'
                yt = tv(spec["frame"]).normalized()
                xt = tv(spec["side"])
                xt = (xt - yt * xt.dot(yt)).normalized()
                zt = xt.cross(yt)
                yr = r["dir"]; xr = r["R"].col[0].normalized(); zr = xr.cross(yr)
                Ft = Matrix((xt, yt, zt)).transposed()
                Fr = Matrix((xr, yr, zr)).transposed()
                D[name] = Ft @ Fr.transposed()
                tw = spec.get("twist", 0)
                if tw:
                    D[name] = Quaternion(yt, math.radians(tw)).to_matrix() @ D[name]
            elif "dir" in spec or "dirv" in spec:
                t = spec["dirv"] if "dirv" in spec else tv(spec["dir"]).normalized()
                d0 = (D[name] @ r["dir"]).normalized()
                q = d0.rotation_difference(t)
                Dn = q.to_matrix() @ D[name]
                tw = spec.get("twist", 0)
                if tw:
                    Dn = Quaternion(t, math.radians(tw)).to_matrix() @ Dn
                D[name] = Dn
        out = {}
        for name in self.order:
            R3 = D[name] @ rs[name]["R"]
            M = R3.to_4x4()
            M.translation = Hd[name]
            out[name] = M
        return out

    def apply(self, pose):
        Mp = self.solve(pose)
        for name in self.order:
            pb = self.rig.pose.bones[name]
            r = self.rest[name]
            if r["parent"]:
                rest_local = self.rest[r["parent"]]["M"].inverted() @ r["M"]
                posed_local = Mp[r["parent"]].inverted() @ Mp[name]
            else:
                rest_local = r["M"]
                posed_local = Mp[name]
            pb.matrix_basis = rest_local.inverted() @ posed_local
        return Mp
