-- BallCast cameras: pinhole look-at projection in sim field coordinates
-- (feet; home plate origin, +y toward CF, +x toward 1B, +z up).
--
-- A camera renders into a background image of size (w, h) whose principal point is
-- (cx, cy). The screen shows a 400x240 window of it at (panX, panY), so a camera with a
-- bigger canvas can "pan" by sliding the window (lens shift).
--
-- When the assets agent ships images/parks/parks.json + backgrounds, Cam.fromPark()
-- reads their params instead of the built-in defaults and the procedural renderer is
-- skipped.

import "ballcast/kit"
import "ballcast/geo"

local gfx <const> = playdate.graphics
local sqrt <const>, tan <const>, rad <const>, sin <const>, cos <const> = math.sqrt, math.tan, math.rad, math.sin, math.cos
local floor <const> = math.floor

BallCast = BallCast or {}
local Cam = {}
BallCast.Cam = Cam

local BASES = { { 0, 0 }, { 63.64, 63.64 }, { 0, 127.28 }, { -63.64, 63.64 } }
Cam.BASES = BASES

---------------------------------------------------------------------------
-- camera math

--- new{ eye={x,y,z}, target={x,y,z}, fov=deg (horizontal, across 400 px), w, h, cx, cy }
function Cam.new(def)
  local c = {}
  for k, v in pairs(def) do c[k] = v end
  c.w = c.w or 400
  c.h = c.h or 240
  c.cx = c.cx or c.w / 2
  c.cy = c.cy or c.h / 2
  local ex, ey, ez = c.eye[1], c.eye[2], c.eye[3]
  local fx, fy, fz = c.target[1] - ex, c.target[2] - ey, c.target[3] - ez
  local fl = sqrt(fx * fx + fy * fy + fz * fz)
  fx, fy, fz = fx / fl, fy / fl, fz / fl
  -- right = f x up(0,0,1)
  local rx, ry, rz = fy, -fx, 0
  local rl = sqrt(rx * rx + ry * ry)
  rx, ry = rx / rl, ry / rl
  -- up = r x f
  local ux, uy, uz = ry * fz - rz * fy, rz * fx - rx * fz, rx * fy - ry * fx
  c.ex, c.ey, c.ez = ex, ey, ez
  c.fx, c.fy, c.fz = fx, fy, fz
  c.rx, c.ry, c.rz = rx, ry, rz
  c.ux, c.uy, c.uz = ux, uy, uz
  c.scale = c.focal or (200 / tan(rad(c.fov) / 2))
  c.near = c.near or 1
  return c
end

--- Project a field point → canvas x, y, depth (nil if behind the camera).
function Cam.project(c, x, y, z)
  local vx, vy, vz = x - c.ex, y - c.ey, z - c.ez
  local d = vx * c.fx + vy * c.fy + vz * c.fz
  if d < c.near then return nil end
  local s = c.scale / d
  return c.cx + (vx * c.rx + vy * c.ry + vz * c.rz) * s, c.cy - (vx * c.ux + vy * c.uy + vz * c.uz) * s, d
end
local project = Cam.project

--- Pixels per foot at a depth.
function Cam.ppf(c, depth) return c.scale / depth end

--- Self-test against projection vectors: { {p={x,y,z}, s={sx,sy}}, ... }
function Cam.selfTest(c, vectors, name)
  local worst = 0
  for _, v in ipairs(vectors or {}) do
    local p = v.p or v.world or v[1]
    local s = v.s or v.screen or v[2]
    if p and s then
      local sx, sy = project(c, p[1], p[2], p[3])
      if sx then
        local e = math.max(math.abs(sx - s[1]), math.abs(sy - s[2]))
        if e > worst then worst = e end
      else
        worst = 999
      end
    end
  end
  print(string.format("[ballcast] projection test %s: max error %.2f px%s", name or "?", worst, worst > 1.5 and "  <-- MISMATCH" or ""))
  return worst
end

---------------------------------------------------------------------------
-- default camera rig (used until parks.json exists)

Cam.DEFS = {
  -- 90s CF center-field camera: long lens over the pitcher's shoulder
  pitch = { eye = { -14, 410, 46 }, target = { 0, 0, 3.5 }, fov = 7.2 },
  -- high home: the whole diamond, for grounders and runners
  high  = { eye = { 0, -95, 62 }, target = { 0, 150, 0 }, fov = 64 },
  -- deep cams from high behind home, toward each field; bigger canvas so they can pan
  deepL = { eye = { 8, -50, 34 }, target = { -170, 210, 16 }, fov = 44, w = 560, h = 400, cx = 280, cy = 230 },
  deepC = { eye = { 0, -50, 34 }, target = { 0, 270, 16 }, fov = 44, w = 560, h = 400, cx = 280, cy = 230 },
  deepR = { eye = { -8, -50, 34 }, target = { 170, 210, 16 }, fov = 44, w = 560, h = 400, cx = 280, cy = 230 },
}

---------------------------------------------------------------------------
-- procedural ballpark background (placeholder for images/parks/*)

local function fenceAt(park, spray)
  local f = park.fences or { 330, 375, 400, 375, 330 }
  local s = math.max(-45, math.min(45, spray))
  local idx = (s + 45) / 22.5
  local i = math.min(3, floor(idx))
  local t = idx - i
  return f[i + 1] + (f[i + 2] - f[i + 1]) * t
end
Cam.fenceAt = fenceAt

local function wallAt(park, spray)
  local f = park.walls or { 10, 10, 10, 10, 10 }
  local s = math.max(-45, math.min(45, spray))
  local idx = (s + 45) / 22.5
  local i = math.min(3, floor(idx))
  local t = idx - i
  return f[i + 1] + (f[i + 2] - f[i + 1]) * t
end
Cam.wallAt = wallAt

local function polar(d, spray)
  local r = rad(spray)
  return d * sin(r), d * cos(r)
end
Cam.polar = polar

-- Clip a 3D polygon against the near plane, project, and fill it.
local function fillPoly3(c, pts, near)
  near = near or 2
  local n = #pts
  local cam = {}
  for i = 1, n do
    local p = pts[i]
    local vx, vy, vz = p[1] - c.ex, p[2] - c.ey, p[3] - c.ez
    cam[i] = { vx * c.rx + vy * c.ry + vz * c.rz, vx * c.ux + vy * c.uy + vz * c.uz, vx * c.fx + vy * c.fy + vz * c.fz }
  end
  local out = {}
  for i = 1, n do
    local a, b = cam[i], cam[i % n + 1]
    local ain, bin = a[3] >= near, b[3] >= near
    if ain then out[#out + 1] = a end
    if ain ~= bin then
      local t = (near - a[3]) / (b[3] - a[3])
      out[#out + 1] = { a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t, near }
    end
  end
  if #out < 3 then return end
  local flat = {}
  for i = 1, #out do
    local p = out[i]
    flat[#flat + 1] = c.cx + p[1] * c.scale / p[3]
    flat[#flat + 1] = c.cy - p[2] * c.scale / p[3]
  end
  gfx.fillPolygon(table.unpack(flat))
end
Cam.fillPoly3 = fillPoly3

local function line3(c, a, b, w)
  -- clipped 3D line
  local pa = { a[1], a[2], a[3] }
  local pb = { b[1], b[2], b[3] }
  local function depth(p) return (p[1] - c.ex) * c.fx + (p[2] - c.ey) * c.fy + (p[3] - c.ez) * c.fz end
  local da, db = depth(pa), depth(pb)
  local near = 2
  if da < near and db < near then return end
  if da < near then
    local t = (near - da) / (db - da)
    pa = { pa[1] + (pb[1] - pa[1]) * t, pa[2] + (pb[2] - pa[2]) * t, pa[3] + (pb[3] - pa[3]) * t }
  elseif db < near then
    local t = (near - db) / (da - db)
    pb = { pb[1] + (pa[1] - pb[1]) * t, pb[2] + (pa[2] - pb[2]) * t, pb[3] + (pa[3] - pb[3]) * t }
  end
  local x1, y1 = project(c, pa[1], pa[2], pa[3])
  local x2, y2 = project(c, pb[1], pb[2], pb[3])
  if x1 and x2 then
    gfx.setLineWidth(w or 1)
    gfx.drawLine(x1, y1, x2, y2)
    gfx.setLineWidth(1)
  end
end

---------------------------------------------------------------------------
-- parks.json support (assets agent): exact camera bases + static backgrounds.

local parksJson
function Cam.parksJson()
  if parksJson == nil then
    parksJson = BCKit.readJson("images/parks/parks.json") or false
  end
  return parksJson or nil
end

-- our camera names → parks.json names
local SHIPPED = { pitch = "pitch", high = "high_home", deepL = "lf", deepC = "cf", deepR = "rf", bleacher = "bleachers" }
Cam.SHIPPED = SHIPPED

--- A camera from a parks.json entry (uses its precomputed basis so projection matches exactly).
function Cam.fromShipped(sc)
  local c = Cam.new({ eye = sc.eye, target = sc.target, fov = sc.fov_x_deg or sc.fov or 60, cx = sc.cx, cy = sc.cy })
  if sc.right and sc.camup and sc.forward then
    c.rx, c.ry, c.rz = sc.right[1], sc.right[2], sc.right[3]
    c.ux, c.uy, c.uz = sc.camup[1], sc.camup[2], sc.camup[3]
    c.fx, c.fy, c.fz = sc.forward[1], sc.forward[2], sc.forward[3]
  end
  if sc.scale then c.scale = sc.scale end
  c.near = sc.near or 1
  return c
end

function Cam.parkEntry(park)
  local pj = Cam.parksJson()
  if not pj then return nil end
  local parks = pj.parks or {}
  local pid = park and park.id or "park-farm"
  return parks[pid] or parks["park-farm"]
end

--- Camera presets for the live renderer: { name = {eye, target, fov} } (parks.json when present).
function Cam.presets(park, baked)
  local out = {}
  if baked then
    -- baked cams: [ex,ey,ez, tx,ty,tz, fov]; anything missing from Cam.DEFS (no parks.json decode)
    for name, def in pairs(Cam.DEFS) do
      local c = baked[name]
      if c then out[name] = { eye = { c[1], c[2], c[3] }, target = { c[4], c[5], c[6] }, fov = c[7] or def.fov }
      else out[name] = { eye = { def.eye[1], def.eye[2], def.eye[3] }, target = { def.target[1], def.target[2], def.target[3] }, fov = def.fov } end
    end
    return out
  end
  local entry = Cam.parkEntry(park)
  for name, def in pairs(Cam.DEFS) do
    local sc = entry and entry.cams and entry.cams[SHIPPED[name] or name]
    if sc and sc.eye and sc.target then
      out[name] = { eye = { sc.eye[1], sc.eye[2], sc.eye[3] }, target = { sc.target[1], sc.target[2], sc.target[3] }, fov = sc.fov_x_deg or def.fov }
    else
      out[name] = { eye = { def.eye[1], def.eye[2], def.eye[3] }, target = { def.target[1], def.target[2], def.target[3] }, fov = def.fov }
    end
  end
  return out
end

--- Static rig (Lua fallback): { name = {cam=, bg=image|nil} } using shipped art when present.
function Cam.rig(park)
  local entry = Cam.parkEntry(park)
  local rig = {}
  for name, def in pairs(Cam.DEFS) do
    local sc = entry and entry.cams and entry.cams[SHIPPED[name] or name]
    local c, bg
    if sc and sc.eye then
      c = Cam.fromShipped(sc)
      if sc.image then bg = BCKit.image(sc.image) end
      if BCKit.DEBUG and sc.tests then
        local vec = {}
        for _, t in ipairs(sc.tests) do if t.expect then vec[#vec + 1] = { p = t.p, s = t.expect } end end
        Cam.selfTest(c, vec, (park and park.id or "?") .. "/" .. name)
      end
    else
      local d = {}
      for k, v in pairs(def) do d[k] = v end
      d.w, d.h, d.cx, d.cy = 400, 240, 200, 120
      c = Cam.new(d)
    end
    c.name = name
    rig[name] = { cam = c, bg = bg }
  end
  return rig
end

--- Lazily paint a background for a rig entry that has no shipped art.
function Cam.ensureBg(entry, park)
  if not entry.bg then
    local c = entry.cam
    local img = gfx.image.new(c.w, c.h, gfx.kColorWhite)
    gfx.pushContext(img)
    BallCast.Geo.paint(BallCast.Geo.build(park), c)
    gfx.popContext()
    entry.bg = img
  end
  return entry.bg
end

---------------------------------------------------------------------------
-- Camera guard: keep every eye out of the stands.
--
-- A camera is fine anywhere on the field (fair territory inside the fence, foul territory
-- inside the stands line, behind home inside the backstop), or 10+ ft above the stand surface
-- under it. An eye that isn't is moved: a low one (< 45 ft) is pulled in toward what it looks
-- at until it's on the field; a high one is raised to 10 ft above the stand surface.
-- The stand surfaces come from the park's baked geometry, indexed on a 40 ft grid once per
-- park (Cam.guardBuild, a slice at a time from the loader).

local GUARD_MATS = { crowd = true, stands_back = true, stands_wall = true, deck_facade = true, deck_shadow = true }
local CELL <const> = 40
local guards = {}   -- park id -> { polys = {...}, grid = { [key] = {i,...} }, pos = cursor, done = bool }

local function cellKey(cx, cy) return cx * 1000 + cy end

--- index up to `n` more polygons of the park's stand geometry; returns true when finished
function Cam.guardBuild(park, n)
  local pid = park and park.id or "park-farm"
  local g = guards[pid]
  if g and g.done then return true end
  local bk = BallCast.Geo and BallCast.Geo.baked(park)
  if not bk then guards[pid] = { done = true, polys = {}, grid = {} } return true end
  if not g then
    local mats = {}
    for i, m in ipairs(bk.materials or {}) do mats[i - 1] = GUARD_MATS[m.name] or false end
    g = { polys = {}, grid = {}, pos = 1, mats = mats }
    guards[pid] = g
  end
  local P = bk.P
  local count = 0
  while g.pos <= #P and count < (n or 1e9) do
    local i = g.pos
    local m, ti, nv = P[i], P[i + 2], P[i + 3]
    local stride = ti > 0 and 5 or 3
    local j0 = i + 4
    g.pos = j0 + nv * stride
    count = count + 1
    if g.mats[m] and nv >= 3 then
      local xs, ys, zs = {}, {}, {}
      local x0, x1, y0, y1 = 1e9, -1e9, 1e9, -1e9
      for k = 0, nv - 1 do
        local j = j0 + k * stride
        xs[#xs + 1], ys[#ys + 1], zs[#zs + 1] = P[j], P[j + 1], P[j + 2]
        if P[j] < x0 then x0 = P[j] end
        if P[j] > x1 then x1 = P[j] end
        if P[j + 1] < y0 then y0 = P[j + 1] end
        if P[j + 1] > y1 then y1 = P[j + 1] end
      end
      -- (vertical faces have no footprint: only surfaces you could be under or on matter)
      if x1 - x0 > 0.5 and y1 - y0 > 0.5 then
        local poly = { xs = xs, ys = ys, zs = zs }
        g.polys[#g.polys + 1] = poly
        local id = #g.polys
        for cx = math.floor(x0 / CELL), math.floor(x1 / CELL) do
          for cy = math.floor(y0 / CELL), math.floor(y1 / CELL) do
            local key = cellKey(cx, cy)
            local l = g.grid[key]
            if not l then l = {}; g.grid[key] = l end
            l[#l + 1] = id
          end
        end
      end
    end
  end
  if g.pos > #P then g.done = true; g.mats = nil end
  return g.done
end

-- the height of the polygon's plane at (x, y) if (x, y) is inside its footprint, else nil
local function surfaceZ(p, x, y)
  local xs, ys, zs = p.xs, p.ys, p.zs
  local n = #xs
  local inside = false
  local j = n
  for i = 1, n do
    if ((ys[i] > y) ~= (ys[j] > y)) and (x < (xs[j] - xs[i]) * (y - ys[i]) / (ys[j] - ys[i]) + xs[i]) then inside = not inside end
    j = i
  end
  if not inside then return nil end
  -- plane through the first three vertices
  local ax, ay, az = xs[2] - xs[1], ys[2] - ys[1], zs[2] - zs[1]
  local bx, by, bz = xs[3] - xs[1], ys[3] - ys[1], zs[3] - zs[1]
  local nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
  if math.abs(nz) < 1e-6 then return nil end
  return zs[1] - (nx * (x - xs[1]) + ny * (y - ys[1])) / nz
end

--- highest stand surface over (x, y), or nil
function Cam.standZ(park, x, y)
  local g = guards[park and park.id or "park-farm"]
  if not g then return nil end
  local l = g.grid[cellKey(math.floor(x / CELL), math.floor(y / CELL))]
  if not l then return nil end
  local best
  for k = 1, #l do
    local z = surfaceZ(g.polys[l[k]], x, y)
    if z and (not best or z > best) then best = z end
  end
  return best
end

--- on the field (fair inside the fence, foul inside the stands line, behind home inside the
--- backstop), with `margin` ft to spare
function Cam.inField(park, x, y, margin)
  margin = margin or 8
  local ft = (park and park.foulTerritory) or 50
  local r = math.sqrt(x * x + y * y)
  local sp = math.deg(math.atan(x, y))
  local a = math.abs(sp)
  if a <= 45 then return r < fenceAt(park or {}, sp) - margin end
  if a <= 135 then
    local off = math.rad(a - 45)
    local along, d = r * cos(off), r * sin(off)
    -- (the stands close in toward the corners: only the near 80 % of the line counts)
    return d < ft - margin and along < fenceAt(park or {}, sp > 0 and 45 or -45) * 0.8 - margin
  end
  return r < ft - margin
end

--- the guard: returns c ({ ex, ey, ez, tx, ty, tz, fov }), adjusted in place if the eye was in
--- the stands
function Cam.safeEye(park, c)
  local g = guards[park and park.id or "park-farm"]
  if not g then return c end
  local x, y, z = c[1], c[2], c[3]
  if Cam.inField(park, x, y, 8) then return c end
  local surf = Cam.standZ(park, x, y)
  -- over a stand and clear of it: fine (the high-home and center-field cameras live there)
  if surf and z >= surf + 10 then return c end
  -- open ground off the field (no seats over or under it): only a ground-level eye gets
  -- pulled in (it would be at the foot of a wall); a raised one is fine
  if not surf and z >= 26 then return c end
  if z < 45 then
    -- low: pull in along the ground toward the target until on the field (8 halvings)
    local tx, ty = c[4], c[5]
    if not Cam.inField(park, tx, ty, 8) then tx, ty = 0, 60 end
    local lo, hi = 0, 1
    for _ = 1, 8 do
      local m = (lo + hi) / 2
      if Cam.inField(park, tx + (x - tx) * m, ty + (y - ty) * m, 8) then lo = m else hi = m end
    end
    c[1], c[2] = tx + (x - tx) * lo, ty + (y - ty) * lo
  elseif surf and z < surf + 10 then
    c[3] = surf + 10
  end
  return c
end

---------------------------------------------------------------------------
-- Occlusion: is the action in view, and is the middle of the frame clear?
--
-- Cam.occluders(park) lists the park's raised geometry (stands, decks, walls, ad boards,
-- light towers, flags, scoreboards, landmarks: every polygon above 0.6 ft) once per park.
-- Cam.blocked(park, eye, p) says what, if anything, stands between the eye and point p.
-- Cam.clearOfAction(park, cam, pts) counts the action points (field coords) in the frame
-- and how many of them are hidden. Cam.junkInMiddle(park, cam) measures how much of the
-- frame's central half shows park geometry *in front of* the field (between the lens and
-- the grass), not as the backdrop behind it.
-- For checks and for picking a shot (e.g. idle "decision" angles), not per-frame work.

local occCache = {}

function Cam.occluders(park)
  local pid = park and park.id or "park-farm"
  local o = occCache[pid]
  if o then return o end
  o = {}
  occCache[pid] = o
  local bk = BallCast.Geo and BallCast.Geo.baked(park)
  if not bk then return o end
  local names = {}
  for i, m in ipairs(bk.materials or {}) do names[i - 1] = m.name end
  local P = bk.P
  local i = 1
  while i <= #P do
    local m, ti, nv = P[i], P[i + 2], P[i + 3]
    local stride = ti > 0 and 5 or 3
    local j0 = i + 4
    i = j0 + nv * stride
    local pts, zmax = {}, -1e9
    for k = 0, nv - 1 do
      local j = j0 + k * stride
      pts[#pts + 1] = { P[j], P[j + 1], P[j + 2] }
      if P[j + 2] > zmax then zmax = P[j + 2] end
    end
    if zmax > 0.6 and nv >= 3 then
      local cx, cy, cz = 0, 0, 0
      for _, q in ipairs(pts) do cx, cy, cz = cx + q[1], cy + q[2], cz + q[3] end
      cx, cy, cz = cx / nv, cy / nv, cz / nv
      local r = 0
      for _, q in ipairs(pts) do r = math.max(r, sqrt((q[1] - cx) ^ 2 + (q[2] - cy) ^ 2 + (q[3] - cz) ^ 2)) end
      -- plane
      local ax, ay, az = pts[2][1] - pts[1][1], pts[2][2] - pts[1][2], pts[2][3] - pts[1][3]
      local bx, by, bz = pts[3][1] - pts[1][1], pts[3][2] - pts[1][2], pts[3][3] - pts[1][3]
      local nx, ny, nz = ay * bz - az * by, az * bx - ax * bz, ax * by - ay * bx
      o[#o + 1] = { pts = pts, c = { cx, cy, cz }, r = r, n = { nx, ny, nz }, mat = names[m] or "?" }
    end
  end
  return o
end

-- first hit of the ray e + t*d (t in (t0, t1)) on polygon q, or nil
local function hitPoly(q, ex, ey, ez, dx, dy, dz, t1)
  -- bounding sphere first
  local cx, cy, cz = q.c[1] - ex, q.c[2] - ey, q.c[3] - ez
  local dd = dx * dx + dy * dy + dz * dz
  local tc = (cx * dx + cy * dy + cz * dz) / dd
  if tc < -q.r or tc > t1 + q.r then return nil end
  local px, py, pz = cx - dx * tc, cy - dy * tc, cz - dz * tc
  if px * px + py * py + pz * pz > q.r * q.r * 1.01 then return nil end
  local n = q.n
  local den = n[1] * dx + n[2] * dy + n[3] * dz
  if den > -1e-9 and den < 1e-9 then return nil end
  local p1 = q.pts[1]
  local t = (n[1] * (p1[1] - ex) + n[2] * (p1[2] - ey) + n[3] * (p1[3] - ez)) / den
  if t <= 1e-4 or t >= t1 then return nil end
  local hx, hy, hz = ex + dx * t, ey + dy * t, ez + dz * t
  local pts = q.pts
  local sgn = 0
  for k = 1, #pts do
    local a, b = pts[k], pts[k % #pts + 1]
    local ux, uy, uz = b[1] - a[1], b[2] - a[2], b[3] - a[3]
    local vx, vy, vz = hx - a[1], hy - a[2], hz - a[3]
    local s = (uy * vz - uz * vy) * n[1] + (uz * vx - ux * vz) * n[2] + (ux * vy - uy * vx) * n[3]
    if s ~= 0 then
      local sg = s > 0 and 1 or -1
      if sgn == 0 then sgn = sg elseif sg ~= sgn then return nil end
    end
  end
  return t
end

--- nearest occluder between eye e {x,y,z} and point p {x,y,z} (ignoring the last `slack` ft
--- before p): material name, fraction along the segment; or nil when the view is clear
function Cam.blocked(park, e, p, slack)
  local dx, dy, dz = p[1] - e[1], p[2] - e[2], p[3] - e[3]
  local len = sqrt(dx * dx + dy * dy + dz * dz)
  if len < 1e-3 then return nil end
  local t1 = 1 - (slack or 2) / len
  local best, mat = nil, nil
  for _, q in ipairs(Cam.occluders(park)) do
    local t = hitPoly(q, e[1], e[2], e[3], dx, dy, dz, best or t1)
    if t then best, mat = t, q.mat end
  end
  return mat, best
end

-- screen projection for a camera { ex, ey, ez, tx, ty, tz, fov }: sx, sy (nil if behind)
local function basis(cam)
  local fx, fy, fz = cam[4] - cam[1], cam[5] - cam[2], cam[6] - cam[3]
  local fl = sqrt(fx * fx + fy * fy + fz * fz)
  fx, fy, fz = fx / fl, fy / fl, fz / fl
  local rx, ry = fy, -fx
  local rl = sqrt(rx * rx + ry * ry)
  if rl < 1e-6 then rx, ry, rl = 1, 0, 1 end
  rx, ry = rx / rl, ry / rl
  local ux, uy, uz = ry * fz, -rx * fz, rx * fy - ry * fx
  return { fx, fy, fz, rx, ry, 0, ux, uy, uz, 200 / math.tan(math.rad(cam[7]) / 2) }
end
Cam.basis = basis
function Cam.projectWith(cam, B, x, y, z)
  local vx, vy, vz = x - cam[1], y - cam[2], z - cam[3]
  local d = vx * B[1] + vy * B[2] + vz * B[3]
  if d < 1 then return nil end
  return 200 + (vx * B[4] + vy * B[5]) * B[10] / d, 120 - (vx * B[7] + vy * B[8] + vz * B[9]) * B[10] / d
end

--- pts: { {x, y, z, tag [, slack ft]}, ... } the action. Returns inFrame, hidden, the first hidden tag
--- and what hid it. (A point counts when it projects inside the 400x240 frame.)
function Cam.clearOfAction(park, cam, pts)
  local B = basis(cam)
  local inF, hid, firstTag, firstMat = 0, 0, nil, nil
  local e = { cam[1], cam[2], cam[3] }
  for _, p in ipairs(pts) do
    local sx, sy = Cam.projectWith(cam, B, p[1], p[2], p[3])
    if sx and sx >= 0 and sx < 400 and sy >= 0 and sy < 240 then
      inF = inF + 1
      -- (geometry within a few feet of the point is what it's touching, e.g. a ball against
      -- the wall: not something in the way)
      local mat = Cam.blocked(park, e, p, p[5] or 3)
      if mat then
        hid = hid + 1
        if not firstTag then firstTag, firstMat = p[4], mat end
      end
    end
  end
  return inF, hid, firstTag, firstMat
end

--- share of the frame's central half (x 100-300, y 60-180; a 10x6 grid of rays) where park
--- geometry stands between the lens and the field (the ray would reach the grass inside the
--- fence, but hits geometry first). Also returns the most common material.
function Cam.junkInMiddle(park, cam)
  local B = basis(cam)
  local e = cam
  local n, junk, mats = 0, 0, {}
  for gy = 0, 5 do
    for gx = 0, 9 do
      local sx, sy = 100 + (gx + 0.5) * 20 - 200, 120 - (60 + (gy + 0.5) * 20)
      local dx = B[1] + (B[4] * sx + B[7] * sy) / B[10]
      local dy = B[2] + (B[5] * sx + B[8] * sy) / B[10]
      local dz = B[3] + (B[6] * sx + B[9] * sy) / B[10]
      n = n + 1
      if dz < -1e-6 then
        local tg = -e[3] / dz                          -- where it meets the ground
        local gx2, gy2 = e[1] + dx * tg, e[2] + dy * tg
        -- (the field proper: ground within 12 ft of the stands line is backdrop territory)
        if Cam.inField(park, gx2, gy2, 12) then
          local best, mat = nil, nil
          for _, q in ipairs(Cam.occluders(park)) do
            local t = hitPoly(q, e[1], e[2], e[3], dx, dy, dz, best or tg * 0.999)
            if t then best, mat = t, q.mat end
          end
          -- (a low wall just in front of the ground it hides is the field's edge seen
          -- end-on, i.e. backdrop: junk is geometry well out in front of the grass)
          local dl = sqrt(dx * dx + dy * dy + dz * dz)
          if mat and (tg - best) * dl > 40 then junk = junk + 1; mats[mat] = (mats[mat] or 0) + 1 end
        end
      end
    end
  end
  local top, topN = nil, 0
  for k, v in pairs(mats) do if v > topN then top, topN = k, v end end
  return junk / n, top
end

--- pull (x, y) toward (tx, ty) until it's on the field with `margin` ft to spare (same z):
--- the nearest such point on the segment (8 halvings). Unchanged if it's already on it.
function Cam.pullIn(park, x, y, tx, ty, margin)
  margin = margin or 10
  if Cam.inField(park, x, y, margin) then return x, y end
  if not Cam.inField(park, tx, ty, margin) then tx, ty = 0, 60 end
  local lo, hi = 0, 1
  for _ = 1, 8 do
    local m = (lo + hi) / 2
    if Cam.inField(park, tx + (x - tx) * m, ty + (y - ty) * m, margin) then lo = m else hi = m end
  end
  return tx + (x - tx) * lo, ty + (y - ty) * lo
end

--- the intro menu's slow orbit at angle a (radians): over the field, high, looking across
--- it (it used to circle 280 ft out, through the stands)
function Cam.introOrbit(park, a)
  local x, y = Cam.pullIn(park, math.sin(a) * 130, 150 - math.cos(a) * 130, 0, 150, 10)
  return { x, y, 120, 0, 150, 0, 60 }
end

--- One call for shot pickers: true when none of the action points in frame are hidden and
--- park geometry fills under 5 % of the frame's middle in front of the field.
--- cam: { ex, ey, ez, tx, ty, tz, fov } (pass it through Cam.safeEye first, as Live does);
--- pts: { {x, y, z [, tag [, slack]]}, ... }. Costs a few thousand ray/polygon tests: use it
--- when choosing a shot (or offline), not every frame.
function Cam.isClear(park, cam, pts)
  local _, hidden = Cam.clearOfAction(park, cam, pts or {})
  if hidden > 0 then return false, "hidden" end
  local j = Cam.junkInMiddle(park, cam)
  if j >= 0.05 then return false, "junk" end
  return true
end

--- drop a park's occluder list (after the loader's checks; Cam.occluders rebuilds on demand)
function Cam.releaseOccluders(park)
  occCache[park and park.id or "park-farm"] = nil
end
