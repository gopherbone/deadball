--[[ The Road Map's planet (the geoscape): an Earth-like world that isn't Earth, baked once by
  tools/bake_globe.py into pennant/globedata.lua and drawn as a flat-shaded low-poly sphere by the C
  extension (c/globe.c; a slow Lua fallback below draws the same data without it).

  The planet is display only: the travel data (miles, bus / rail / charter, time zones, landmarks)
  stays on the real-world lon/lat in pennant/routes.lua and landmarks.lua. Each club has a spot on
  the planet (clubs.lua `gl`); landmarks follow through a warp fitted on the clubs.

  PGlobe.setView(lat0, lon0)       the view centre (also where the light comes from)
  PGlobe.render()                  the sphere into the frame buffer at (CX, CY), radius R
  PGlobe.at(lon, lat)              -> sx, sy, z (z > 0: this side of the planet)
  PGlobe.leg(a, b)                 a cached leg between two club abbrs (great circle, lift)
  PGlobe.drawLegs(list)            { { leg, frac } ... }: drop shadows, then the ribbons
  PGlobe.ll(abbr) / PGlobe.landmarkLL(e)   planet lon/lat of a club / a PLand entry
]]

local gfx <const> = playdate.graphics
PGlobe = PGlobe or {}
local G = PGlobe

local sin, cos, sqrt, acos, asin, atan, floor, max, min = math.sin, math.cos, math.sqrt, math.acos, math.asin, math.atan, math.floor, math.max, math.min
local D <const> = math.pi / 180

G.CX, G.CY, G.R = 142, 132, 112
G.RIBBON = 12              -- the ribbon's light body (px); a 1.5-px dark edge each side
G.LIFT = 0.16              -- how far a 40-degree leg arcs off the ground (fraction of R)
G.SHADOW = 6               -- the drop shadow's Bayer level (ANDed: it only darkens)

--- Unit vector of a lon/lat (deg).
local function world(lon, lat)
  local p, q = lat * D, lon * D
  local cp = cos(p)
  return { cp * cos(q), cp * sin(q), sin(p) }
end
G.world = world

function G.toLL(v)
  return atan(v[2], v[1]) / D, asin(max(-1, min(1, v[3]))) / D
end

local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end

--- Great-circle interpolation between unit vectors.
function G.slerp(A, B, t)
  local om = acos(max(-1, min(1, dot(A, B))))
  if om < 1e-6 then return A end
  local s = sin(om)
  local s0, s1 = sin((1 - t) * om) / s, sin(t * om) / s
  return { A[1] * s0 + B[1] * s1, A[2] * s0 + B[2] * s1, A[3] * s0 + B[3] * s1 }
end

-- the view: rows of the rotation (X right, Y up, Z toward the viewer)
local X, Y, Z = { 0, 1, 0 }, { 0, 0, 1 }, { 1, 0, 0 }
G.lat0, G.lon0 = 0, 0

function G.setView(lat0, lon0)
  G.lat0, G.lon0 = lat0, lon0
  local l0, p0 = lon0 * D, lat0 * D
  local sl, cl, sp, cp = sin(l0), cos(l0), sin(p0), cos(p0)
  X[1], X[2], X[3] = -sl, cl, 0
  Y[1], Y[2], Y[3] = -sp * cl, -sp * sl, cp
  Z[1], Z[2], Z[3] = cp * cl, cp * sl, sp
end

--- Centre the view on a unit vector.
function G.lookAt(v)
  local lon, lat = G.toLL(v)
  G.setView(lat, lon)
end

--- Screen position of a unit vector (s: radius scale for points above the ground) and its depth.
function G.proj(w, s)
  s = (s or 1) * G.R
  local x, y, z = w[1], w[2], w[3]
  return G.CX + s * (x * X[1] + y * X[2]), G.CY - s * (x * Y[1] + y * Y[2] + z * Y[3]), x * Z[1] + y * Z[2] + z * Z[3]
end
local proj = G.proj

function G.at(lon, lat) return proj(world(lon, lat)) end

--- The view centre as a unit vector.
function G.viewVec() return world(G.lon0, G.lat0) end

-- Places -----------------------------------------------------------------------------------------

function G.ll(abbr)
  local c = PennantClubs.byAbbr[abbr]
  return c.gl[1], c.gl[2]
end
function G.vec(abbr) local c = PennantClubs.byAbbr[abbr] c.glv = c.glv or world(c.gl[1], c.gl[2]) return c.glv end

-- real lon/lat -> planet lon/lat: a least-squares affine fit on the eight clubs, plus an inverse-
-- distance share of each club's leftover (so the clubs themselves land exactly)
local fit
local function solve3(m, v)
  -- Cramer's rule, 3x3
  local function det(a) return a[1] * (a[5] * a[9] - a[6] * a[8]) - a[2] * (a[4] * a[9] - a[6] * a[7]) + a[3] * (a[4] * a[8] - a[5] * a[7]) end
  local d = det(m)
  local out = {}
  for c = 1, 3 do
    local t = { table.unpack(m) }
    for r = 1, 3 do t[(r - 1) * 3 + c] = v[r] end
    out[c] = det(t) / d
  end
  return out
end
local function buildFit()
  local m, bx, by = { 0, 0, 0, 0, 0, 0, 0, 0, 0 }, { 0, 0, 0 }, { 0, 0, 0 }
  for _, c in ipairs(PennantClubs) do
    local r = { c.ll[1], c.ll[2], 1 }
    for i = 1, 3 do
      for j = 1, 3 do m[(i - 1) * 3 + j] = m[(i - 1) * 3 + j] + r[i] * r[j] end
      bx[i] = bx[i] + r[i] * c.gl[1]
      by[i] = by[i] + r[i] * c.gl[2]
    end
  end
  fit = { x = solve3(m, bx), y = solve3(m, by) }
  local function aff(lon, lat) return fit.x[1] * lon + fit.x[2] * lat + fit.x[3], fit.y[1] * lon + fit.y[2] * lat + fit.y[3] end
  fit.aff = aff
  fit.res = {}
  for _, c in ipairs(PennantClubs) do
    local x, y = aff(c.ll[1], c.ll[2])
    fit.res[#fit.res + 1] = { c.ll[1], c.ll[2], c.gl[1] - x, c.gl[2] - y }
  end
end

function G.fromReal(lon, lat)
  if not fit then buildFit() end
  local x, y = fit.aff(lon, lat)
  local sw, dx, dy = 0, 0, 0
  for _, r in ipairs(fit.res) do
    local d2 = (lon - r[1]) ^ 2 + (lat - r[2]) ^ 2
    if d2 < 1e-6 then return x + r[3], y + r[4] end
    local w = 1 / (d2 * d2)
    sw, dx, dy = sw + w, dx + w * r[3], dy + w * r[4]
  end
  return x + dx / sw, y + dy / sw
end

function G.landmarkLL(e)
  if not e.gl then e.gl = { G.fromReal(e.ll[1], e.ll[2]) } end
  return e.gl[1], e.gl[2]
end

-- the 9 Bayer 4x4 levels as 8x8 patterns (0 white .. 8 black)
local PATS = {}
do
  local bayer = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }
  for l = 0, 8 do
    local p = {}
    for y = 0, 7 do
      local b = 0
      for x = 0, 7 do if bayer[y % 4 + 1][x % 4 + 1] >= 2 * l then b = b | (0x80 >> x) end end
      p[y + 1] = b
    end
    PATS[l] = p
  end
end
G.PATS = PATS

-- Legs -------------------------------------------------------------------------------------------

local N <const> = 36
local legCache = {}

--- A leg: the great circle between two clubs, 36 steps, lifted off the ground by its length.
function G.leg(a, b)
  local key = a .. b
  local l = legCache[key]
  if l then return l end
  local A, B = G.vec(a), G.vec(b)
  local span = acos(max(-1, min(1, dot(A, B)))) / D
  l = { a = a, b = b, A = A, B = B, span = span, lift = G.LIFT * max(0.5, min(1.4, span / 40)), pts = {} }
  for i = 0, N do l.pts[i + 1] = G.slerp(A, B, i / N) end
  legCache[key] = l
  return l
end

--- The point t (0..1) of the way along a leg, on the ground.
function G.legVec(l, t) return G.slerp(l.A, l.B, t) end

-- runs of visible screen points (a leg passing behind the planet breaks into pieces)
local function runs(l, frac, ground, dx, dy)
  local out, cur = {}, nil
  local pi = math.pi
  for i = 0, N do
    local t = frac * i / N
    local w = frac >= 1 and l.pts[i + 1] or G.slerp(l.A, l.B, t)
    local s = ground and 1 or (1 + l.lift * sin(pi * t))
    local x, y, z = proj(w, s)
    local vis
    if ground then vis = z > 0
    else
      local px, py = (x - G.CX) / G.R, (G.CY - y) / G.R
      vis = z > 0 or (px * px + py * py) > 1.0404
    end
    if vis then
      if not cur then cur = {} out[#out + 1] = cur end
      cur[#cur + 1] = x + (dx or 0)
      cur[#cur + 1] = y + (dy or 0)
    else
      cur = nil
    end
  end
  return out
end

--- The tip of a leg drawn to frac (screen x, y), or nil when it's out of sight.
function G.legTip(l, frac)
  local w = G.slerp(l.A, l.B, frac)
  local x, y, z = proj(w, 1 + l.lift * sin(math.pi * frac))
  return x, y, z
end

local function polyline(pts, w, outline)
  -- (Lua fallback for globe.leg)
  gfx.setLineCapStyle(gfx.kLineCapStyleRound)
  if outline then
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(w + 3)
    for i = 1, #pts - 3, 2 do gfx.drawLine(pts[i], pts[i + 1], pts[i + 2], pts[i + 3]) end
    gfx.setColor(gfx.kColorWhite)
  end
  gfx.setLineWidth(w)
  for i = 1, #pts - 3, 2 do gfx.drawLine(pts[i], pts[i + 1], pts[i + 2], pts[i + 3]) end
  gfx.setLineWidth(1)
  gfx.setLineCapStyle(gfx.kLineCapStyleButt)
  gfx.setColor(gfx.kColorBlack)
end

--- Draw legs: every drop shadow on the ground track (offset 3, 4), then each ribbon arcing off the
--- planet (a light body with a dark edge). list = { { leg, frac }, ... }
function G.drawLegs(list)
  local w = G.RIBBON
  if globe then
    -- (C: the slerp, the projection and the fill in one call a leg)
    for pass = 0, 1 do
      for _, e in ipairs(list) do
        local l, frac = e[1], e[2]
        if frac > 0 then
          local A, B = l.A, l.B
          globe.leg(pass, A[1], A[2], A[3], B[1], B[2], B[3], frac, l.lift, w, G.SHADOW)
        end
      end
    end
    return
  end
  for _, e in ipairs(list) do
    if e[2] > 0 then
      for _, r in ipairs(runs(e[1], e[2], true, 3, 4)) do
        if #r >= 4 then gfx.setPattern(PATS[G.SHADOW]) polyline(r, w) end
      end
    end
  end
  for _, e in ipairs(list) do
    if e[2] > 0 then
      for _, r in ipairs(runs(e[1], e[2], false)) do
        if #r >= 4 then polyline(r, w, true) end
      end
    end
  end
end

-- The planet ----------------------------------------------------------------------------------------

local data            -- (Lua fallback) the parsed globe.bin
local ok = false

function G.load()
  if ok then return true end
  local bytes = PGlobeData
  if not bytes then print("[globe] no planet data") return false end
  if globe then
    local r, err = globe.load(bytes)
    if not r then print("[globe] " .. tostring(err)) return false end
  else
    data = G.parse(bytes)
  end
  ok = true
  return true
end

--- globe.bin -> { codes = { [q] = { a, b } }, pieces = { [q] = { { kind, u1, v1, ... } } }, coast = { { q, u1, v1, u2, v2 } } }
function G.parse(s)
  local up = string.unpack
  local p = 5
  local nq
  nq, p = up("<I2", s, p)
  local d = { codes = {}, pieces = {}, coast = {} }
  for q = 0, nq - 1 do
    local a, b
    a, b, p = up("<BB", s, p)
    d.codes[q] = { a, b }
  end
  local np
  np, p = up("<I2", s, p)
  for _ = 1, np do
    local q, k, n
    q, k, n, p = up("<I2BB", s, p)
    local pc = { k }
    for _ = 1, n do
      local u, v
      u, v, p = up("<BB", s, p)
      pc[#pc + 1] = u
      pc[#pc + 1] = v
    end
    d.pieces[q] = d.pieces[q] or {}
    table.insert(d.pieces[q], pc)
  end
  local nc
  nc, p = up("<I2", s, p)
  for _ = 1, nc do
    local q, u1, v1, u2, v2
    q, u1, v1, u2, v2, p = up("<I2BBBB", s, p)
    d.coast[#d.coast + 1] = { q, u1, v1, u2, v2 }
  end
  return d
end

-- (Lua fallback) the same shading as globe.c, through gfx
local BASE <const> = { [0] = 0.06, 0.30, 0.42, 0.52, 0.18 }
local GAIN <const> = { [0] = 0.62, 0.75, 0.75, 0.70, 0.75 }
local function levelFor(lit, k)
  local l = floor((1 - (BASE[k] + GAIN[k] * lit)) * 8 + 0.5)
  return l < 0 and 0 or (l > 8 and 8 or l)
end

local corners
local function renderLua()
  if not corners then
    corners = {}
    for j = 0, 12 do for i = 0, 23 do corners[j * 24 + i] = world(-180 + 15 * i, -90 + 15 * j) end end
  end
  local sx, sy, sz = {}, {}, {}
  for k = 0, 13 * 24 - 1 do sx[k], sy[k], sz[k] = proj(corners[k]) end
  local function at(px, py, u, v)
    u, v = u / 240, v / 240
    if v <= u then return px[1] + u * (px[2] - px[1]) + v * (px[3] - px[2]), py[1] + u * (py[2] - py[1]) + v * (py[3] - py[2]) end
    return px[1] + v * (px[4] - px[1]) + u * (px[3] - px[4]), py[1] + v * (py[4] - py[1]) + u * (py[3] - py[4])
  end
  local vis = {}
  for j = 0, 11 do
    for i = 0, 23 do
      local q = j * 24 + i
      local k4 = { j * 24 + i, j * 24 + (i + 1) % 24, (j + 1) * 24 + (i + 1) % 24, (j + 1) * 24 + i }
      if sz[k4[1]] >= 0 and sz[k4[2]] >= 0 and sz[k4[3]] >= 0 and sz[k4[4]] >= 0 then
        local px, py = {}, {}
        for n = 1, 4 do px[n], py[n] = sx[k4[n]], sy[k4[n]] end
        vis[q] = { px, py }
        local function nlit(a, b, c)
          local A, B, C = corners[a], corners[b], corners[c]
          local s = { A[1] + B[1] + C[1], A[2] + B[2] + C[2], A[3] + B[3] + C[3] }
          return max(0, (sz[a] + sz[b] + sz[c]) / sqrt(dot(s, s)))
        end
        local lit = { nlit(k4[1], k4[2], k4[3]), nlit(k4[1], k4[3], k4[4]) }
        for f = 1, 2 do
          local code = data.codes[q][f]
          if code ~= 254 then
            gfx.setPattern(PATS[levelFor(lit[f], code == 255 and 0 or code)])
            local b, c = f == 1 and 2 or 3, f == 1 and 3 or 4
            gfx.fillTriangle(px[1], py[1], px[b], py[b], px[c], py[c])
          end
        end
        for _, pc in ipairs(data.pieces[q] or {}) do
          local pts, su, sv = {}, 0, 0
          for n = 2, #pc, 2 do
            su, sv = su + pc[n], sv + pc[n + 1]
            local x, y = at(px, py, pc[n], pc[n + 1])
            pts[#pts + 1] = x
            pts[#pts + 1] = y
          end
          gfx.setPattern(PATS[levelFor(lit[sv <= su and 1 or 2], pc[1])])
          gfx.fillPolygon(table.unpack(pts))
        end
      end
    end
  end
  gfx.setColor(gfx.kColorBlack)
  for _, c in ipairs(data.coast) do
    local v = vis[c[1]]
    if v then
      local x1, y1 = at(v[1], v[2], c[2], c[3])
      local x2, y2 = at(v[1], v[2], c[4], c[5])
      gfx.drawLine(x1, y1, x2, y2)
    end
  end
end

--- The planet, centred on the current view. (C: ~5 ms on the device; the Lua fallback is slow.)
function G.render(clipX, clipY, clipW, clipH)
  if not ok and not G.load() then return end
  if globe then
    if clipX then globe.render(G.lat0, G.lon0, G.CX, G.CY, G.R, clipX, clipY, clipX + clipW, clipY + clipH)
    else globe.render(G.lat0, G.lon0, G.CX, G.CY, G.R) end
  else
    renderLua()
  end
end
