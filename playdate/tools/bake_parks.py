#!/usr/bin/env python3
"""Bake per-park BallCast geometry for fast loading on the device.

Reads images/parks/parks-geo.json (all parks, ~300 KB of nested JSON) and images/parks/parks.json
(cameras + test vectors) and writes one small file per park, source/ballcast/data/parks/<pid>.json:

  { "v": 1,
    "materials": [...]            # as in parks-geo.json (the patterns are computed in Lua, Geo.material)
    "P": [m, layer, tex, n, x,y,z, ... | x,y,z,u,v, ...]   # flat: no per-vertex tables to decode
    "L": [ax,ay,az, bx,by,bz, white, w, layer, ...]
    "D": [m, layer, cx,cy,cz, r, ...]
    "tex": [[name, file, wrap], ...]                      # tex index above is 1-based into this
    "cams": { "<ballcast cam>": [ex,ey,ez, tx,ty,tz, fov] } }

Same semantics as Geo.shipped + Cam.presets in ballcast/geo.lua / cam.lua; the Lua side falls
back to the big files when a baked file is missing. Re-run after the parks pipeline changes:
  python3 playdate/tools/bake_parks.py
"""
import json, os

HERE = os.path.dirname(os.path.abspath(__file__))
SRC = os.path.join(HERE, "..", "source")
OUT = os.path.join(SRC, "ballcast", "data", "parks")
SHIPPED = {"pitch": "pitch", "high": "high_home", "deepL": "lf", "deepC": "cf", "deepR": "rf", "bleacher": "bleachers"}


def r2(v):
    return round(v, 2)


def main():
    geo = json.load(open(os.path.join(SRC, "images", "parks", "parks-geo.json")))
    cams = json.load(open(os.path.join(SRC, "images", "parks", "parks.json")))
    os.makedirs(OUT, exist_ok=True)
    textures = geo.get("textures", {})
    for pid, g in geo["parks"].items():
        P, L, D, tex, texIdx = [], [], [], [], {}
        for p in g.get("polys", []):
            v = p.get("v") or []
            if len(v) < 3:
                continue
            t = p.get("t")
            ti = 0
            if t and p.get("uv") and t in textures:
                if t not in texIdx:
                    d = textures[t]
                    tex.append([t, d["file"], bool(d.get("wrap"))])
                    texIdx[t] = len(tex)
                ti = texIdx[t]
            P += [(p.get("m") or 0) + 1, (p.get("l") or 0) * 2, ti, len(v)]
            for i, q in enumerate(v):
                P += [r2(q[0]), r2(q[1]), r2(q[2])]
                if ti:
                    uv = p["uv"][i] if i < len(p["uv"]) else [0, 0]
                    P += [r2(uv[0]), r2(uv[1])]
        for l in g.get("lines", []):
            a, b = l["a"], l["b"]
            ground = (a[2] if len(a) > 2 else 0) == 0 and (b[2] if len(b) > 2 else 0) == 0
            L += [r2(a[0]), r2(a[1]), r2(a[2]), r2(b[0]), r2(b[1]), r2(b[2]), 1 if (l.get("c", 1) == 1) else 0, l.get("w", 1), 18 if ground else 99]
        for bb in g.get("billboards", []):
            if bb.get("c"):
                c = bb["c"]
                D += [(bb.get("m") or 0) + 1, 20, r2(c[0]), r2(c[1]), r2(c[2]), bb.get("r", 1)]
        cj = {}
        entry = cams.get("parks", {}).get(pid) or cams.get("parks", {}).get("park-farm") or {}
        for name, shipped in SHIPPED.items():
            sc = (entry.get("cams") or {}).get(shipped)
            if sc and sc.get("eye") and sc.get("target"):
                cj[name] = [*map(r2, sc["eye"]), *map(r2, sc["target"]), sc.get("fov_x_deg")]
        doc = {"v": 1, "materials": geo.get("materials", []), "P": P, "L": L, "D": D, "tex": tex, "cams": cj}
        path = os.path.join(OUT, pid + ".json")
        with open(path, "w") as f:
            json.dump(doc, f, separators=(",", ":"))
        print(f"{pid}: {os.path.getsize(path) // 1024} KB, {len(P)} numbers, {len(tex)} textures")


if __name__ == "__main__":
    main()
