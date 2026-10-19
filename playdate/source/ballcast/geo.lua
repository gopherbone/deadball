-- BallCast park geometry: polygons in field feet with a material and a paint layer.
--
-- Source, in order of preference:
--   images/parks/parks-geo.json  (assets agent; per-park polygons + materials)
--   procedural: built here from the park's fences/walls (same look as the mockups)
--
-- Geo.build(park) → { mats = { [id] = {mode, amount, pat={8 bytes}} }, polys = { {mat, layer, bias, pts={{x,y,z},...}}, ... } }
-- Geo.upload(geo)  → pushes it to the C renderer (bc3d), if present.
-- Geo.paint(geo, cam) → Lua fallback rasterizer into the current graphics context.

import "ballcast/kit"

local gfx <const> = playdate.graphics
local sin <const>, cos <const>, rad <const>, floor <const> = math.sin, math.cos, math.rad, math.floor

BallCast = BallCast or {}
local Geo = {}
BallCast.Geo = Geo
local K = BCKit

-- material ids
local M = {
  grassA = 1, grassB = 2, dirt = 3, track = 4, wall = 5, white = 6, black = 7,
  crowdA = 8, crowdB = 9, crowdC = 10, roof = 11, haze = 12, foul = 13, sky = 14, skyline = 15, board = 16,
}
Geo.M = M

-- 8x8 patterns (bit 1 = white)
local MATS = {
  [M.grassA]  = { 0, 0, { 0xDD, 0x77, 0xDD, 0x77, 0xDD, 0x77, 0xDD, 0x77 } },
  [M.grassB]  = { 0, 0, { 0xFF, 0xBB, 0xFF, 0xEE, 0xFF, 0xBB, 0xFF, 0xEE } },
  [M.foul]    = { 0, 0, { 0xDD, 0x77, 0xDD, 0x77, 0xDD, 0x77, 0xDD, 0x77 } },
  [M.dirt]    = { 0, 0, { 0xFF, 0xFF, 0xF7, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF } },
  [M.track]   = { 0, 0, { 0xFF, 0xEE, 0xFF, 0xBB, 0xFF, 0xEE, 0xFF, 0xBB } },
  [M.wall]    = { 0, 0, { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } },
  [M.white]   = { 0, 0, { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } },
  [M.black]   = { 0, 0, { 0, 0, 0, 0, 0, 0, 0, 0 } },
  [M.crowdA]  = { 2, 0, { 0xC2, 0xC7, 0xA6, 0x55, 0x0C, 0x1E, 0x96, 0x55 } },   -- crowd heads: sunny
  [M.crowdB]  = { 2, 0, { 0x80, 0xC4, 0x00, 0x52, 0x08, 0x0C, 0x40, 0x8A } },   -- shaded
  [M.crowdC]  = { 2, 0, { 0x88, 0x22, 0x88, 0x44, 0x22, 0x88, 0x55, 0x00 } },   -- upper deck
  [M.roof]    = { 0, 0, { 0x00, 0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00 } },
  [M.haze]    = { 0, 0, { 0xFF, 0xDF, 0xFF, 0xFD, 0xFF, 0xDF, 0xFF, 0xFD } },
  [M.sky]     = { 0, 0, { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF } },
  [M.skyline] = { 0, 0, { 0xAA, 0xFF, 0x55, 0xFF, 0xAA, 0xFF, 0x55, 0xFF } },
  [M.board]   = { 0, 0, { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00 } },
}
Geo.MATS = MATS

local BASES = { { 0, 0 }, { 63.64, 63.64 }, { 0, 127.28 }, { -63.64, 63.64 } }

local function lerpPost(arr, spray)
  local s = math.max(-45, math.min(45, spray))
  local idx = (s + 45) / 22.5
  local i = math.min(3, floor(idx))
  local t = idx - i
  return arr[i + 1] + (arr[i + 2] - arr[i + 1]) * t
end

local function polar(d, s)
  local r = rad(s)
  return d * sin(r), d * cos(r)
end

-- layers: 0 sky/skyline, 10 stands, 20 ground, 30 field, 40 infield, 50 lines/bases, 60 walls
function Geo.procedural(park)
  park = park or {}
  local fences = park.fences or { 330, 375, 400, 375, 330 }
  local walls = park.walls or { 10, 10, 10, 10, 10 }
  local fence = function(s) return lerpPost(fences, s) end
  local wall = function(s) return lerpPost(walls, s) end
  local polys = {}
  local function P(mat, layer, pts, bias) polys[#polys + 1] = { mat = mat, layer = layer, bias = bias or 0, pts = pts } end

  -- far skyline silhouette (behind everything)
  local seed = K.hash01(park.id or "x", 3)
  for i = 0, 15 do
    local s0, s1 = -70 + 140 * i / 16, -70 + 140 * (i + 1) / 16
    local h = 40 + 80 * K.hash01(i, floor(seed * 100))
    local r = 900
    local ax, ay = polar(r, s0)
    local bx, by = polar(r, s1)
    P(M.skyline, 0, { { ax, ay, 0 }, { bx, by, 0 }, { bx, by, h }, { ax, ay, h } })
  end

  -- ground plane
  P(M.foul, 20, { { -900, -300, 0 }, { 900, -300, 0 }, { 900, 900, 0 }, { -900, 900, 0 } })

  -- stands: three decks wrapping the outfield and down the lines
  local decks = {
    { off = 18, rise = 0, depth = 70, h = 34, mat = M.crowdA },
    { off = 88, rise = 38, depth = 60, h = 40, mat = M.crowdB },
    { off = 148, rise = 82, depth = 50, h = 34, mat = M.crowdC },
  }
  local N = 14
  for d = 1, #decks do
    local dk = decks[d]
    for i = 0, N - 1 do
      local s0, s1 = -50 + 100 * i / N, -50 + 100 * (i + 1) / N
      local ax, ay = polar(fence(s0) + dk.off, s0)
      local bx, by = polar(fence(s1) + dk.off, s1)
      local cx, cy = polar(fence(s1) + dk.off + dk.depth, s1)
      local dx, dy = polar(fence(s0) + dk.off + dk.depth, s0)
      P(dk.mat, 10, { { ax, ay, dk.rise }, { bx, by, dk.rise }, { cx, cy, dk.rise + dk.h }, { dx, dy, dk.rise + dk.h } })
      -- facade below each deck
      P(M.black, 11, { { ax, ay, dk.rise - 4 }, { bx, by, dk.rise - 4 }, { bx, by, dk.rise + 1 }, { ax, ay, dk.rise + 1 } }, -1)
    end
    -- roof over the top deck
    if d == #decks then
      for i = 0, N - 1 do
        local s0, s1 = -50 + 100 * i / N, -50 + 100 * (i + 1) / N
        local ax, ay = polar(fence(s0) + dk.off + dk.depth - 10, s0)
        local bx, by = polar(fence(s1) + dk.off + dk.depth - 10, s1)
        local z = dk.rise + dk.h + 14
        P(M.roof, 12, { { ax, ay, z }, { bx, by, z }, { bx, by, z + 8 }, { ax, ay, z + 8 } })
      end
    end
  end
  -- grandstand behind home (so reverse angles have something to look at)
  for i = 0, 9 do
    local a0, a1 = 135 + 90 * i / 10, 135 + 90 * (i + 1) / 10
    local r0, r1 = 75, 190
    local ax, ay = r0 * sin(rad(a0)), r0 * cos(rad(a0))
    local bx, by = r0 * sin(rad(a1)), r0 * cos(rad(a1))
    local cx, cy = r1 * sin(rad(a1)), r1 * cos(rad(a1))
    local dx, dy = r1 * sin(rad(a0)), r1 * cos(rad(a0))
    P(M.crowdA, 10, { { ax, ay, 4 }, { bx, by, 4 }, { cx, cy, 70 }, { dx, dy, 70 } })
  end
  -- scoreboard in deep CF + light towers
  do
    local x, y = polar(fence(0) + 120, 0)
    P(M.board, 13, { { x - 45, y, 50 }, { x + 45, y, 50 }, { x + 45, y, 92 }, { x - 45, y, 92 } })
    for row = 0, 2 do
      for col = 0, 8 do
        local px = x - 38 + col * 8.6
        local pz = 56 + row * 11
        P(M.white, 14, { { px, y - 1, pz }, { px + 5.5, y - 1, pz }, { px + 5.5, y - 1, pz + 7 }, { px, y - 1, pz + 7 } })
      end
    end
    for _, s in ipairs({ -40, -14, 14, 40 }) do
      local tx, ty = polar(fence(s) + 210, s)
      P(M.black, 13, { { tx - 2, ty, 0 }, { tx + 2, ty, 0 }, { tx + 2, ty, 150 }, { tx - 2, ty, 150 } })
      P(M.roof, 14, { { tx - 16, ty, 150 }, { tx + 16, ty, 150 }, { tx + 16, ty, 168 }, { tx - 16, ty, 168 } })
    end
  end

  -- outfield grass in mowing bands
  local function fan(r0fn, r1fn, n)
    local pts = {}
    for i = 0, n do local s = -45 + 90 * i / n; local x, y = polar(r1fn(s), s); pts[#pts + 1] = { x, y, 0 } end
    for i = n, 0, -1 do local s = -45 + 90 * i / n; local x, y = polar(r0fn(s), s); pts[#pts + 1] = { x, y, 0 } end
    return pts
  end
  for i = 0, 13 do
    local r0, r1 = 30 * i, 30 * (i + 1)
    P((i % 2 == 0) and M.grassA or M.grassB, 30 + i, fan(function(s) return math.min(r0, fence(s) - 14) end, function(s) return math.min(r1, fence(s) - 14) end, 12))
  end
  P(M.track, 44, fan(function(s) return fence(s) - 14 end, fence, 16))
  -- infield
  local dirt = { { 0, -6, 0 } }
  for i = 0, 18 do
    local a = rad(-82 + 164 * i / 18)
    dirt[#dirt + 1] = { 95 * sin(a), 60.5 + 95 * cos(a), 0 }
  end
  P(M.dirt, 45, dirt)
  local b = 63.64
  P(M.grassA, 46, { { 0, 8, 0 }, { b - 9, b, 0 }, { 0, 2 * b - 10, 0 }, { -(b - 9), b, 0 } })
  local function disc(x, y, r, n, mat, layer)
    local pts = {}
    for i = 0, n - 1 do local a = 2 * math.pi * i / n; pts[#pts + 1] = { x + r * cos(a), y + r * sin(a), 0 } end
    P(mat, layer, pts)
  end
  disc(0, 60.5, 9, 12, M.dirt, 47)
  disc(0, 0, 13, 12, M.dirt, 47)
  -- foul lines, bases, plate, rubber
  for _, sg in ipairs({ -1, 1 }) do
    local ex, ey = polar(fence(sg * 45), sg * 45)
    P(M.white, 50, { { -0.6 * sg, 0.6, 0 }, { ex - 0.6 * sg, ey + 0.6, 0 }, { ex + 0.6 * sg, ey - 0.6, 0 }, { 0.6 * sg, -0.6, 0 } })
    -- foul pole
    local h = wall(sg * 45) + 45
    P(M.black, 62, { { ex - 0.8, ey, 0 }, { ex + 0.8, ey, 0 }, { ex + 0.8, ey, h }, { ex - 0.8, ey, h } })
  end
  for i = 2, 4 do
    local bx, by = BASES[i][1], BASES[i][2]
    P(M.white, 51, { { bx, by - 1.6, 0.2 }, { bx + 1.6, by, 0.2 }, { bx, by + 1.6, 0.2 }, { bx - 1.6, by, 0.2 } })
  end
  P(M.white, 51, { { -0.8, 0.8, 0 }, { 0.8, 0.8, 0 }, { 0.8, -0.2, 0 }, { 0, -0.9, 0 }, { -0.8, -0.2, 0 } })
  P(M.white, 51, { { -1, 60.3, 0.8 }, { 1, 60.3, 0.8 }, { 1, 60.8, 0.8 }, { -1, 60.8, 0.8 } })
  -- batter's boxes (outlines as thin strips)
  for _, sx in ipairs({ -1, 1 }) do
    local x0 = sx * 1.5
    local x1 = sx * 5.5
    P(M.white, 50, { { x0, -3, 0 }, { x1, -3, 0 }, { x1, -2.7, 0 }, { x0, -2.7, 0 } })
    P(M.white, 50, { { x0, 3, 0 }, { x1, 3, 0 }, { x1, 2.7, 0 }, { x0, 2.7, 0 } })
  end
  -- dugouts
  for _, sg in ipairs({ -1, 1 }) do
    P(M.black, 52, { { sg * 95, -10, 0 }, { sg * 130, 25, 0 }, { sg * 130, 25, 7 }, { sg * 95, -10, 7 } })
  end
  -- backstop
  P(M.wall, 60, { { -55, -62, 0 }, { 55, -62, 0 }, { 55, -62, 12 }, { -55, -62, 12 } })
  -- outfield wall: padded panels + white cap
  local WN = 24
  for i = 0, WN - 1 do
    local s0, s1 = -45 + 90 * i / WN, -45 + 90 * (i + 1) / WN
    local ax, ay = polar(fence(s0), s0)
    local bx, by = polar(fence(s1), s1)
    local h0, h1 = wall(s0), wall(s1)
    P(M.wall, 60, { { ax, ay, 0 }, { bx, by, 0 }, { bx, by, h1 }, { ax, ay, h0 } })
    P(M.white, 61, { { ax, ay, h0 - 0.8 }, { bx, by, h1 - 0.8 }, { bx, by, h1 }, { ax, ay, h0 } })
  end
  -- distance markers: white plaques on the wall
  for _, s in ipairs({ -45, -22.5, 0, 22.5, 45 }) do
    local d = fence(s) - 0.3
    local x, y = polar(d, s)
    local nx, ny = cos(rad(s)), -sin(rad(s))
    local z = wall(s) * 0.45
    P(M.white, 62, { { x - nx * 5, y - ny * 5, z }, { x + nx * 5, y + ny * 5, z }, { x + nx * 5, y + ny * 5, z + 3 }, { x - nx * 5, y - ny * 5, z + 3 } })
  end
  return { mats = MATS, polys = polys, source = "procedural" }
end

--- parks-geo.json from the assets agent:
---   materials = [{name, gray, outline, pattern?}]  (polys reference them 0-based by `m`)
---   parks[pid] = { sky, polys = [{m, l, v=[[x,y,z]..], t?, uv?}], lines = [{a, b, c, w}], billboards }
local geoJson
function Geo.shipped(park)
  if geoJson == nil then geoJson = K.readJson("images/parks/parks-geo.json") or false end
  if not geoJson then return nil end
  local parks = geoJson.parks or {}
  local pid = park and park.id or "park-farm"
  local g = parks[pid] or parks["park-farm"]
  if not g or not g.polys then return nil end
  local mats, matNames = {}, {}
  for i, def in ipairs(geoJson.materials or {}) do
    local name = def.name or ""
    matNames[i] = name
    local pat = def.pattern or Geo.bayer(Geo.tone(name, def.gray or 0.5))
    local crowd = name:find("crowd") ~= nil
    if crowd then pat = { 0xC2, 0xC7, 0xA6, 0x55, 0x0C, 0x1E, 0x96, 0x55 } end   -- crowd heads (sunny)
    mats[i] = { crowd and 2 or 0, 0, pat, def.outline and true or false }
  end
  local polys = {}
  for _, p in ipairs(g.polys) do
    if p.v and #p.v >= 3 then
      polys[#polys + 1] = { mat = (p.m or 0) + 1, layer = (p.l or 0) * 2, bias = 0, pts = p.v, tex = p.t, uv = p.uv }
    end
  end
  local lines = {}
  for _, l in ipairs(g.lines or {}) do
    local ground = (l.a[3] or 0) == 0 and (l.b[3] or 0) == 0
    lines[#lines + 1] = { a = l.a, b = l.b, white = (l.c or 1) == 1, w = l.w or 1, layer = ground and 18 or 99 }
  end
  local discs = {}
  for _, b in ipairs(g.billboards or {}) do
    if b.c then discs[#discs + 1] = { mat = (b.m or 0) + 1, layer = 20, c = b.c, r = b.r or 1 } end
  end
  return { mats = mats, matNames = matNames, polys = polys, lines = lines, discs = discs, textures = geoJson.textures, source = "parks-geo.json" }
end

-- The real screen washes out mid-greys: push field tones lighter and walls darker.
function Geo.tone(name, gray)
  -- grass stays light and quiet so the crowd photo texture is the only busy thing in a wide shot
  if name == "grass_b" then return 0.8 end
  if name:find("grass") or name == "turf" then return math.max(gray, 0.88) end
  if name:find("wall") or name == "backstop" or name == "dugout" then return math.min(gray, 0.1) end
  if name == "dirt" or name == "mound" or name == "warning_track" then return math.max(gray, 0.94) end
  return gray
end

local BAYER4 = { { 0, 8, 2, 10 }, { 12, 4, 14, 6 }, { 3, 11, 1, 9 }, { 15, 7, 13, 5 } }
--- 8x8 ordered-dither pattern for a gray level (0 = black, 1 = white).
function Geo.bayer(level)
  local pat = {}
  local thr = level * 16
  for y = 0, 7 do
    local row = 0
    for x = 0, 7 do
      if BAYER4[(y % 4) + 1][(x % 4) + 1] < thr then row = row | (0x80 >> x) end
    end
    pat[y + 1] = row
  end
  return pat
end

---------------------------------------------------------------------------
-- the stands: no textures. Crowd polygons use the C "crowd heads" material (mode 2): an 8x8
-- head-and-shoulders tile filled in screen space and anchored to the camera pan, animated per
-- column in C (shimmer, the wave, flashes; bc3d.crowd). Sections get different tiles for depth:
-- sunny lower deck, shaded lower deck (3B side), upper deck (dark, small heads).
local CROWD_TILE <const> = {
  sunny  = { 0xC2, 0xC7, 0xA6, 0x55, 0x0C, 0x1E, 0x96, 0x55 },
  shaded = { 0x80, 0xC4, 0x00, 0x52, 0x08, 0x0C, 0x40, 0x8A },
  upper  = { 0x88, 0x22, 0x88, 0x44, 0x22, 0x88, 0x55, 0x00 },
}
local MAT_UPPER <const>, MAT_SHADED <const> = 60, 61
Geo.CROWD_TILE = CROWD_TILE
local function crowdMats()
  local t = CROWD_TILE
  bc3d.material(MAT_UPPER, 2, 0, table.unpack(t.upper))
  bc3d.material(MAT_SHADED, 2, 0, table.unpack(t.shaded))
end
--- which crowd material a stands polygon gets (from its average height / side of the field)
local function crowdMatFor(base, sx, sz, n)
  local z = sz / n
  if z > 40 then return MAT_UPPER end
  if sx / n < -20 then return MAT_SHADED end
  return base
end
Geo.crowdMatFor = crowdMatFor

---------------------------------------------------------------------------
-- diamond outlines: 1 px black strokes on the boundary edges of the infield ground pieces
-- (dirt, infield grass, mound/home circle, bases, plate, rubber), uploaded as black lines on
-- layer 17 — after every ground layer, under the chalk (18). Only boundary edges (not shared by
-- two polygons of the same group) are stroked, so split areas don't show seams. C skips edges a
-- few px long, and strokes the chalk itself (black under white) when it's wide enough on screen.
-- Chalk and outlines stop at the circles: ground chalk segments and the dirt / infield-grass
-- outline edges are clipped against the "circle" pieces (layer 14: home-plate circle, mound,
-- base cutouts) and the bags (layer 16: bases, plate, rubber), so each foul line / base path is
-- two thin black strokes with the white between that END on the circle's own outline.
-- Convex polygons (the baked geometry is convex) clipped with Cyrus-Beck; static, done once.
local CLIP_LAYERS <const> = { [14] = true, [16] = true }
local function insideInterval(ax, ay, bx, by, cp, eps)
  local xs, ys, n, s = cp.xs, cp.ys, cp.n, cp.s
  local t0, t1 = 0, 1
  local dx, dy = bx - ax, by - ay
  for i = 1, n do
    local j = i % n + 1
    local ex, ey = xs[j] - xs[i], ys[j] - ys[i]
    local num = s * (ex * (ay - ys[i]) - ey * (ax - xs[i]))
    -- eps > 0: the polygon grown by eps ft (so an edge lying ALONG it counts as inside)
    if eps then num = num + eps * math.sqrt(ex * ex + ey * ey) end
    local den = s * (ex * dy - ey * dx)
    if den == 0 then
      if num < 0 then return nil end
    else
      local t = -num / den
      if den > 0 then if t > t0 then t0 = t end elseif t < t1 then t1 = t end
    end
    if t0 >= t1 then return nil end
  end
  return t0, t1
end
--- segment (ax,ay)-(bx,by) minus the clip polygons → list of { t0, t1 } kept intervals
local function clipOut(ax, ay, bx, by, clips, eps, skip)
  local keep = { { 0, 1 } }
  local g = eps or 0
  for _, cp in ipairs(clips) do
    -- quick reject: segment bbox vs polygon bbox
    if cp ~= skip and not (math.max(ax, bx) < cp.x0 - g or math.min(ax, bx) > cp.x1 + g or math.max(ay, by) < cp.y0 - g or math.min(ay, by) > cp.y1 + g) then
      local u0, u1 = insideInterval(ax, ay, bx, by, cp, eps)
      if u0 then
        local nk = {}
        for _, iv in ipairs(keep) do
          if u1 <= iv[1] or u0 >= iv[2] then nk[#nk + 1] = iv
          else
            if u0 > iv[1] then nk[#nk + 1] = { iv[1], u0 } end
            if u1 < iv[2] then nk[#nk + 1] = { u1, iv[2] } end
          end
        end
        keep = nk
      end
    end
  end
  return keep
end
local function clipPoly(xs, ys, n)
  local a, x0, x1, y0, y1 = 0, 1e9, -1e9, 1e9, -1e9
  local cx, cy = {}, {}
  for i = 1, n do
    local j = i % n + 1
    a = a + xs[i] * ys[j] - xs[j] * ys[i]
    cx[i], cy[i] = xs[i], ys[i]
    if xs[i] < x0 then x0 = xs[i] end
    if xs[i] > x1 then x1 = xs[i] end
    if ys[i] < y0 then y0 = ys[i] end
    if ys[i] > y1 then y1 = ys[i] end
  end
  return { xs = cx, ys = cy, n = n, s = a > 0 and 1 or -1, x0 = x0, x1 = x1, y0 = y0, y1 = y1 }
end
-- No chalk on the field (the user prefers the clean look: dirt, grass and bases outlined, no
-- foul lines or base paths drawn). Flip to bring the chalk bands back.
local DRAW_CHALK <const> = false

--- upload a ground chalk line minus the circles/bags (other lines unchanged)
local function chalkLine(clips, ax, ay, az, bx, by, bz, white, w, layer)
  if layer == 18 and white and not DRAW_CHALK then return end
  if layer ~= 18 or not white or #clips == 0 then return bc3d.line(ax, ay, az, bx, by, bz, white, w, layer) end
  for _, iv in ipairs(clipOut(ax, ay, bx, by, clips)) do
    local t0, t1 = iv[1], iv[2]
    if (t1 - t0) * math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2) > 0.3 then
      bc3d.line(ax + (bx - ax) * t0, ay + (by - ay) * t0, az + (bz - az) * t0,
                ax + (bx - ax) * t1, ay + (by - ay) * t1, az + (bz - az) * t1, white, w, layer)
    end
  end
end
Geo.clipOut = clipOut

-- a dirt/grass edge running alongside a chalk line a few feet off (hcl's base-path grass edge,
-- 2.5 ft inside the foul line) is dropped: the chalk band's own ink edges stand for it, and the
-- pair of near-touching strokes read as rough on the high and deep shots
local CHALK_NEAR_FT <const> = 4.0
local function nearChalk(chalks, ax, ay, bx, by)
  local ex, ey = bx - ax, by - ay
  local el = math.sqrt(ex * ex + ey * ey)
  if el < 1 then return false end
  for _, l in ipairs(chalks) do
    local lx, ly, ll = l[3] - l[1], l[4] - l[2], l[5]
    -- parallel (within ~3 deg), both ends close to the chalk's line and within its extent
    if math.abs(ex * ly - ey * lx) < 0.05 * el * ll then
      local function near(px, py)
        local qx, qy = px - l[1], py - l[2]
        local t = (qx * lx + qy * ly) / (ll * ll)
        return t > -0.02 and t < 1.02 and math.abs(qx * ly - qy * lx) / ll < CHALK_NEAR_FT
      end
      if near(ax, ay) and near(bx, by) then return true end
    end
  end
  return false
end
local function chalkOf(chalks, ax, ay, az, bx, by, bz, white, layer)
  if not DRAW_CHALK then return end   -- no chalk: keep the dirt/grass edges along the lines
  if layer == 18 and white and az < 0.5 and bz < 0.5 then
    local ll = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
    if ll > 20 then chalks[#chalks + 1] = { ax, ay, bx, by, ll } end
  end
end

local OUTLINE_MATS <const> = { dirt = true, mound = true, base = true, plate = true, rubber = true,
  grass_a = true, grass_b = true, turf = true }
local OUTLINE_LAYERS <const> = { [10] = "dirt", [12] = "grass", [14] = "circle", [16] = "bags" }
-- an outline is only where the VISIBLE material changes: each edge is probed a little inside
-- and a little outside (topmost ground polygon at each point, painter's order) and kept only
-- where the two differ. So the home circle's dirt running into the base-path dirt, a cutout over
-- the infield dirt, or a bag-covered stretch draws nothing, while the same circle's edge against
-- the infield grass (laid over a dirt skin) stays. Static, done once at upload.
local SIDE_EPS <const> = 0.12   -- ft off the edge for the inside / outside probes
local SAMPLE_FT <const> = 2.5   -- probe spacing; boundaries refined by bisection
local function inPoly(P, x, y)
  if x < P.x0 or x > P.x1 or y < P.y0 or y > P.y1 then return false end
  local xs, ys, n, c = P.xs, P.ys, P.n, false
  local j = n
  for i = 1, n do
    if (ys[i] > y) ~= (ys[j] > y) and x < xs[i] + (y - ys[i]) * (xs[j] - xs[i]) / (ys[j] - ys[i]) then c = not c end
    j = i
  end
  return c
end
-- cands sorted topmost first (layer, then upload order), so the first hit is the visible one
local function visibleMat(cands, x, y)
  for i = 1, #cands do
    local P = cands[i]
    if inPoly(P, x, y) then return P.m end
  end
  return false
end
local function outliner()
  local edges = {}
  local ground = {}   -- every outline-layer polygon (any material), for the visible-material probes
  local o = {}
  function o.add(matName, layer, xs, ys, zs, n)
    local g = OUTLINE_LAYERS[layer]
    if not g then return end
    local own = clipPoly(xs, ys, n)
    own.m, own.layer, own.k = matName, layer, #ground + 1
    ground[#ground + 1] = own   -- upload order = painter's order within a layer
    if not OUTLINE_MATS[matName] then return end
    for k = 1, n do
      local j = k % n + 1
      local ka = string.format("%s|%.1f,%.1f|%.1f,%.1f", g, xs[k], ys[k], xs[j], ys[j])
      local kb = string.format("%s|%.1f,%.1f|%.1f,%.1f", g, xs[j], ys[j], xs[k], ys[k])
      local e = edges[kb]
      if e then e.n = e.n + 1
      else
        e = edges[ka]
        if e then e.n = e.n + 1 else edges[ka] = { n = 1, xs[k], ys[k], zs[k], xs[j], ys[j], zs[j], s = own.s } end
      end
    end
  end
  -- the sub-intervals of edge e (within ivs) where the material just inside differs from the
  -- one just outside
  function o.visibleSplit(e, ivs)
    local ax, ay, bx, by = e[1], e[2], e[4], e[5]
    local dx, dy = bx - ax, by - ay
    local len = math.sqrt(dx * dx + dy * dy)
    if len < 1e-3 then return {} end
    -- outward normal: interior is left of the edge for a CCW polygon (s = 1)
    local nx, ny = dy / len * e.s * SIDE_EPS, -dx / len * e.s * SIDE_EPS
    local x0, x1 = math.min(ax, bx) - 1, math.max(ax, bx) + 1
    local y0, y1 = math.min(ay, by) - 1, math.max(ay, by) + 1
    local cands = {}
    for _, P in ipairs(ground) do
      if not (P.x1 < x0 or P.x0 > x1 or P.y1 < y0 or P.y0 > y1) then cands[#cands + 1] = P end
    end
    table.sort(cands, function(a, b) if a.layer ~= b.layer then return a.layer > b.layer end return a.k > b.k end)
    local function differs(t)
      local px, py = ax + dx * t, ay + dy * t
      return visibleMat(cands, px - nx, py - ny) ~= visibleMat(cands, px + nx, py + ny)
    end
    local out = {}
    for _, iv in ipairs(ivs) do
      local ta, tb = iv[1], iv[2]
      -- probes at both ends (inset a hair) and every SAMPLE_FT between
      local steps = math.max(1, math.ceil((tb - ta) * len / SAMPLE_FT))
      local inset = math.min(0.05 / len, (tb - ta) * 0.25)
      local function probeT(k)
        if k == 0 then return ta + inset elseif k == steps then return tb - inset end
        return ta + (tb - ta) * k / steps
      end
      local prevT = probeT(0)
      local prevD = differs(prevT)
      local runStart = prevD and ta or nil
      for k = 1, steps do
        local t = probeT(k)
        local d = differs(t)
        if d ~= prevD then
          local lo, hi = prevT, t   -- bisect the change between the two probes
          for _ = 1, 6 do
            local mid = (lo + hi) * 0.5
            if differs(mid) == prevD then lo = mid else hi = mid end
          end
          local cut = (lo + hi) * 0.5
          if d then runStart = cut else out[#out + 1] = { runStart, cut }; runStart = nil end
          prevD = d
        end
        prevT = t
      end
      if runStart then out[#out + 1] = { runStart, tb } end
    end
    local keep = {}   -- drop slivers
    for _, iv in ipairs(out) do if (iv[2] - iv[1]) * len >= 0.3 then keep[#keep + 1] = iv end end
    return keep
  end
  function o.upload(clips, chalks, Y)
    local c, ne = 0, 0
    for key, e in pairs(edges) do
      ne = ne + 1
      if Y and ne % 16 == 0 then Y() end
      if e.n == 1 and not (chalks and nearChalk(chalks, e[1], e[2], e[4], e[5])) then
        -- dirt / infield-grass edges stop at the circles and bags (their own outlines take over);
        -- and each keeps only where the visible material actually changes across it
        local g = key:sub(1, key:find("|") - 1)
        local ivs = { { 0, 1 } }
        if clips and (g == "dirt" or g == "grass") then ivs = clipOut(e[1], e[2], e[4], e[5], clips) end
        ivs = o.visibleSplit(e, ivs)
        do
          for _, iv in ipairs(ivs) do
            local t0, t1 = iv[1], iv[2]
            bc3d.line(e[1] + (e[4] - e[1]) * t0, e[2] + (e[5] - e[2]) * t0, e[3] + 0.02,
                      e[1] + (e[4] - e[1]) * t1, e[2] + (e[5] - e[2]) * t1, e[6] + 0.02, false, 1, 17)
            c = c + 1
          end
        end
      end
    end
    return c
  end
  return o
end
Geo.outliner = outliner

---------------------------------------------------------------------------
-- baked per-park geometry (playdate/tools/bake_parks.py → ballcast/data/parks/<pid>.json):
-- flat number arrays, so the device decodes ~25 KB instead of the 300 KB all-parks file and
-- uploads straight from the arrays with table.unpack (no per-vertex tables).

local bakedCache = {}   -- pid → baked table (kept for the session: re-entering a replay is cheap)
function Geo.baked(park)
  local pid = park and park.id or "park-farm"
  local bk = bakedCache[pid]
  if bk == nil then
    bk = K.readJson("ballcast/data/parks/" .. pid .. ".json")
      or (pid ~= "park-farm" and K.readJson("ballcast/data/parks/park-farm.json")) or false
    bakedCache[pid] = bk
  end
  return bk or nil
end

--- material table (as Geo.shipped builds it) for the baked materials list
local function bakedMats(bk)
  if bk.mats then return bk.mats end
  local mats = {}
  for i, def in ipairs(bk.materials or {}) do
    local name = def.name or ""
    local pat = def.pattern or Geo.bayer(Geo.tone(name, def.gray or 0.5))
    local crowd = name:find("crowd") ~= nil
    if crowd then pat = CROWD_TILE.sunny end
    mats[i] = { crowd and 2 or 0, 0, pat, def.outline and true or false }
  end
  bk.mats = mats
  return mats
end

--- Upload a baked park to bc3d. Y() is called between chunks (the loader yields there when
--- the frame's time budget is spent). Textures load one at a time; images stay alive in bk.
function Geo.uploadBaked(bk, Y)
  Y = Y or function() end
  bc3d.clearGeometry()
  for id, m in pairs(bakedMats(bk)) do
    local p = m[3]
    bc3d.material(id, m[1] + (m[4] and 4 or 0), m[2], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8])
  end
  local D = bk.D
  for i = 1, #D, 6 do bc3d.disc(D[i], D[i + 1], D[i + 2], D[i + 3], D[i + 4], D[i + 5]) end
  -- the circle / bag polygons (for clipping the chalk and the dirt/grass outlines)
  local clips = {}
  do
    local P = bk.P
    local i = 1
    while i <= #P do
      local layer, ti, nv = P[i + 1], P[i + 2], P[i + 3]
      i = i + 4
      if ti == 0 and CLIP_LAYERS[layer] then
        local xs, ys = {}, {}
        for k = 0, nv - 1 do local j = i + k * 3; xs[k + 1], ys[k + 1] = P[j], P[j + 1] end
        clips[#clips + 1] = clipPoly(xs, ys, nv)
      end
      i = i + nv * (ti > 0 and 5 or 3)
    end
  end
  bk.clips = clips
  local L = bk.L
  local chalks = {}
  for i = 1, #L, 9 do
    chalkLine(clips, L[i], L[i + 1], L[i + 2], L[i + 3], L[i + 4], L[i + 5], L[i + 6] == 1, L[i + 7], L[i + 8])
    chalkOf(chalks, L[i], L[i + 1], L[i + 2], L[i + 3], L[i + 4], L[i + 5], L[i + 6] == 1, L[i + 8])
  end
  bk.chalks = chalks
  Y()
  crowdMats()
  -- textures: ids 0..n-1 in bake order. Crowd photo tiles are not loaded any more (the stands
  -- are the crowd-heads material); ad boards pair up as trivision boards (bc3d.alt).
  bk.texImgs = bk.texImgs or {}
  local ads = {}
  for i, t in ipairs(bk.tex or {}) do
    if t[1]:find("crowd") then
      bk.texImgs[i] = false
    else
      local img = bk.texImgs[i]
      if img == nil then img = K.image(t[2]) or false; bk.texImgs[i] = img; Y() end
      if img then bc3d.texture(i - 1, img, t[3] and true or false, false) end
      if img and t[1]:find("^ad_") then ads[#ads + 1] = i end
    end
  end
  local altOf = {}
  for k, ti in ipairs(ads) do altOf[ti] = ads[(k % #ads) + 1] end
  local P = bk.P
  local i, n, count = 1, #P, 0
  local unpack = table.unpack
  local ol = outliner()
  local oxs, oys, ozs = {}, {}, {}
  local mnames = {}
  for k, def in ipairs(bk.materials or {}) do mnames[k] = def.name or "" end
  while i <= n do
    local m, layer, ti, nv = P[i], P[i + 1], P[i + 2], P[i + 3]
    i = i + 4
    if ti == 0 and OUTLINE_LAYERS[layer] then
      for k = 0, nv - 1 do local j = i + k * 3; oxs[k + 1], oys[k + 1], ozs[k + 1] = P[j], P[j + 1], P[j + 2] end
      ol.add(mnames[m], layer, oxs, oys, ozs, nv)
    end
    if ti > 0 and bk.texImgs[ti] then
      bc3d.polyT(m, layer, 0, ti - 1, unpack(P, i, i + nv * 5 - 1))
      local alt = altOf[ti]
      if alt and alt ~= ti and bc3d.alt then bc3d.alt(alt - 1) end
      i = i + nv * 5
    elseif ti > 0 and bk.tex[ti] and bk.tex[ti][1]:find("crowd") then
      -- stands: crowd-heads material by section
      local sx, sz = 0, 0
      for k = 0, nv - 1 do local j = i + k * 5; sx = sx + P[j]; sz = sz + P[j + 2] end
      bc3d.poly(crowdMatFor(m, sx, sz, nv), layer, 0)
      for k = 0, nv - 1 do local j = i + k * 5; bc3d.v(P[j], P[j + 1], P[j + 2]) end
      i = i + nv * 5
    elseif ti > 0 then
      -- texture failed to load: plain polygon from the xyz of each xyzuv
      bc3d.poly(m, layer, 0)
      for k = 0, nv - 1 do local j = i + k * 5; bc3d.v(P[j], P[j + 1], P[j + 2]) end
      i = i + nv * 5
    else
      bc3d.poly(m, layer, 0, unpack(P, i, i + nv * 3 - 1))
      i = i + nv * 3
    end
    count = count + 1
    if count % 24 == 0 then Y() end
  end
  ol.upload(clips, chalks, Y)
  return true
end

function Geo.build(park)
  return Geo.shipped(park) or Geo.procedural(park)
end

--- Upload to the C renderer.
function Geo.upload(geo)
  if not bc3d then return false end
  bc3d.clearGeometry()
  for id, m in pairs(geo.mats) do
    local p = m[3]
    bc3d.material(id, m[1] + (m[4] and 4 or 0), m[2], p[1], p[2], p[3], p[4], p[5], p[6], p[7], p[8])
  end
  crowdMats()
  for _, d in ipairs(geo.discs or {}) do
    bc3d.disc(d.mat, d.layer, d.c[1], d.c[2], d.c[3], d.r)
  end
  local clips = {}
  for _, p in ipairs(geo.polys) do
    if not p.tex and CLIP_LAYERS[p.layer] then
      local xs, ys = {}, {}
      for k, v in ipairs(p.pts) do xs[k], ys[k] = v[1], v[2] end
      clips[#clips + 1] = clipPoly(xs, ys, #p.pts)
    end
  end
  local chalks = {}
  for _, l in ipairs(geo.lines or {}) do
    chalkLine(clips, l.a[1], l.a[2], l.a[3], l.b[1], l.b[2], l.b[3], l.white, l.w, l.layer)
    chalkOf(chalks, l.a[1], l.a[2], l.a[3], l.b[1], l.b[2], l.b[3], l.white, l.layer)
  end
  -- textures (kept alive in geo.texImgs while the renderer uses them)
  local texIds, nextTex = {}, 0
  geo.texImgs = {}
  local function texId(name)
    if texIds[name] ~= nil then return texIds[name] end
    local def = geo.textures and geo.textures[name]
    local img = def and K.image(def.file)
    if not img or nextTex >= 96 then texIds[name] = false return false end
    local id = nextTex
    nextTex = nextTex + 1
    geo.texImgs[id] = img
    bc3d.texture(id, img, def.wrap and true or false, name:find("crowd") ~= nil)
    texIds[name] = id
    return id
  end
  local args = {}
  local ol = outliner()
  local oxs, oys, ozs = {}, {}, {}
  for _, p in ipairs(geo.polys) do
    if not p.tex and OUTLINE_LAYERS[p.layer] and geo.matNames then
      for k, v in ipairs(p.pts) do oxs[k], oys[k], ozs[k] = v[1], v[2], v[3] end
      ol.add(geo.matNames[p.mat] or "", p.layer, oxs, oys, ozs, #p.pts)
    end
    if p.tex and p.tex:find("crowd") then
      -- stands: crowd-heads material by section (no texture)
      local sx, sz = 0, 0
      for _, v in ipairs(p.pts) do sx = sx + v[1]; sz = sz + v[3] end
      p = { mat = crowdMatFor(p.mat, sx, sz, #p.pts), layer = p.layer, bias = p.bias, pts = p.pts }
    end
    local tid = p.tex and p.uv and texId(p.tex)
    if tid then
      local n = 0
      for i, v in ipairs(p.pts) do
        local uv = p.uv[i] or { 0, 0 }
        args[n + 1], args[n + 2], args[n + 3], args[n + 4], args[n + 5] = v[1], v[2], v[3], uv[1], uv[2]
        n = n + 5
      end
      bc3d.polyT(p.mat, p.layer, p.bias or 0, tid, table.unpack(args, 1, n))
      goto continue
    end
    local n = 0
    for _, v in ipairs(p.pts) do
      args[n + 1], args[n + 2], args[n + 3] = v[1], v[2], v[3]
      n = n + 3
    end
    for k = #args, n + 1, -1 do args[k] = nil end
    bc3d.poly(p.mat, p.layer, p.bias or 0, table.unpack(args, 1, n))
    ::continue::
  end
  ol.upload(clips, chalks, Y)
  return true
end

--- Lua fallback: paint the geometry through a camera (BallCast.Cam) into the current context.
function Geo.paint(geo, c)
  local Cam = BallCast.Cam
  local order = {}
  for i, p in ipairs(geo.polys) do
    local d, n = 0, #p.pts
    for _, v in ipairs(p.pts) do
      d = d + (v[1] - c.ex) * c.fx + (v[2] - c.ey) * c.fy + (v[3] - c.ez) * c.fz
    end
    order[#order + 1] = { p = p, d = d / n + (p.bias or 0), i = i }
  end
  table.sort(order, function(a, b)
    if a.p.layer ~= b.p.layer then return a.p.layer < b.p.layer end
    if a.d ~= b.d then return a.d > b.d end
    return a.i < b.i
  end)
  for _, o in ipairs(order) do
    local m = geo.mats[o.p.mat]
    if m then gfx.setPattern(m[3]) else gfx.setColor(gfx.kColorBlack) end
    Cam.fillPoly3(c, o.p.pts)
  end
  for _, l in ipairs(geo.lines or {}) do
    local x1, y1 = Cam.project(c, l.a[1], l.a[2], l.a[3])
    local x2, y2 = Cam.project(c, l.b[1], l.b[2], l.b[3])
    if x1 and x2 then
      gfx.setColor(l.white and gfx.kColorWhite or gfx.kColorBlack)
      gfx.drawLine(x1, y1, x2, y2)
    end
  end
end
