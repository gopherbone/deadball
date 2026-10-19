-- Billboard puppets: 2-3 frame crude ballplayers, drawn once from joint poses (until the
-- assets agent's imagetables land in images/puppets/), then cached per size bucket.

-- ONE instance per session. The shell loads BallCast with playdate.file.run (app/optional.lua),
-- and cards/render.lua imports this file again from the separately-run cards bundle; runtime
-- imports across bundles aren't de-duplicated, so a second run would replace BallCast.Puppets
-- while render3d/crowd keep the first (scene exit then released the wrong instance: its sprite
-- ids outlived bc3d.reset → no billboards on later replays).
BallCast = BallCast or {}
if BallCast.Puppets then
  print("[bcpup] puppets.lua imported again: keeping the first instance")
  return
end

import "ballcast/kit"
import "ballcast/anim"

local gfx <const> = playdate.graphics
local floor <const> = math.floor

local P = {}
BallCast.Puppets = P

local S <const> = 4 / 3          -- pose space 32x48 → canvas 43x64
local CW <const>, CH <const> = 43, 64
P.BASE_H = CH

-- pose = { h=head, n=neck, p=pelvis, la={elbow,hand}, ra=..., ll={knee,foot}, rl=..., bat={x1,y1,x2,y2}, cap=dx, dark=bool }
local POSES = {
  ready   = { h = { 16, 10 }, n = { 16, 16 }, p = { 16, 29 }, la = { { 10, 23 }, { 10, 30 } }, ra = { { 22, 23 }, { 22, 30 } }, ll = { { 11, 38 }, { 9, 47 } }, rl = { { 21, 38 }, { 23, 47 } }, cap = 0 },
  stand   = { h = { 16, 8 }, n = { 16, 14 }, p = { 16, 28 }, la = { { 12, 21 }, { 11, 28 } }, ra = { { 20, 21 }, { 21, 28 } }, ll = { { 14, 38 }, { 13, 47 } }, rl = { { 18, 38 }, { 19, 47 } }, cap = 0 },
  run1    = { h = { 19, 8 }, n = { 18, 14 }, p = { 15, 27 }, la = { { 11, 18 }, { 8, 13 } }, ra = { { 23, 20 }, { 26, 25 } }, ll = { { 9, 34 }, { 4, 41 } }, rl = { { 20, 37 }, { 18, 47 } }, cap = 2 },
  run2    = { h = { 19, 8 }, n = { 18, 14 }, p = { 15, 27 }, la = { { 12, 21 }, { 10, 27 } }, ra = { { 22, 17 }, { 26, 12 } }, ll = { { 13, 37 }, { 12, 47 } }, rl = { { 23, 33 }, { 27, 41 } }, cap = 2 },
  reach   = { h = { 16, 11 }, n = { 16, 17 }, p = { 16, 30 }, la = { { 10, 11 }, { 8, 3 } }, ra = { { 22, 11 }, { 24, 3 } }, ll = { { 10, 38 }, { 7, 47 } }, rl = { { 22, 38 }, { 25, 47 } }, cap = 0, glove = { 8, 3 } },
  set     = { h = { 16, 8 }, n = { 16, 14 }, p = { 16, 27 }, la = { { 11, 20 }, { 15, 20 } }, ra = { { 21, 20 }, { 17, 20 } }, ll = { { 13, 37 }, { 12, 47 } }, rl = { { 19, 37 }, { 20, 47 } }, cap = 0, back = true },
  kick    = { h = { 15, 7 }, n = { 15, 13 }, p = { 15, 26 }, la = { { 11, 19 }, { 14, 17 } }, ra = { { 20, 18 }, { 17, 17 } }, ll = { { 13, 36 }, { 13, 47 } }, rl = { { 23, 25 }, { 21, 34 } }, cap = 0, back = true },
  release = { h = { 19, 11 }, n = { 18, 17 }, p = { 15, 28 }, la = { { 10, 21 }, { 6, 26 } }, ra = { { 24, 11 }, { 26, 4 } }, ll = { { 10, 38 }, { 6, 47 } }, rl = { { 21, 38 }, { 25, 47 } }, cap = 2, back = true },
  stance  = { h = { 15, 8 }, n = { 15, 14 }, p = { 16, 27 }, la = { { 11, 19 }, { 20, 13 } }, ra = { { 22, 20 }, { 21, 13 } }, ll = { { 10, 37 }, { 8, 47 } }, rl = { { 22, 37 }, { 24, 47 } }, bat = { 21, 13, 28, 0 }, cap = -1 },
  swing   = { h = { 14, 8 }, n = { 15, 14 }, p = { 16, 27 }, la = { { 11, 19 }, { 8, 21 } }, ra = { { 19, 20 }, { 9, 22 } }, ll = { { 9, 37 }, { 7, 47 } }, rl = { { 21, 37 }, { 24, 47 } }, bat = { 8, 21, -2, 17 }, cap = -2 },
  follow  = { h = { 14, 8 }, n = { 15, 14 }, p = { 16, 27 }, la = { { 10, 16 }, { 9, 10 } }, ra = { { 18, 17 }, { 10, 11 } }, ll = { { 10, 37 }, { 9, 47 } }, rl = { { 20, 38 }, { 21, 47 } }, bat = { 9, 10, 22, 3 }, cap = -2 },
  catcher = { h = { 16, 22 }, n = { 16, 27 }, p = { 16, 36 }, la = { { 10, 31 }, { 12, 34 } }, ra = { { 22, 31 }, { 20, 34 } }, ll = { { 8, 40 }, { 10, 47 } }, rl = { { 24, 40 }, { 22, 47 } }, cap = 0, mask = true, glove = { 20, 33 } },
  ump     = { h = { 16, 15 }, n = { 16, 21 }, p = { 16, 33 }, la = { { 10, 28 }, { 11, 35 } }, ra = { { 22, 28 }, { 21, 35 } }, ll = { { 10, 40 }, { 10, 47 } }, rl = { { 22, 40 }, { 22, 47 } }, cap = 0, dark = true, mask = true },
  umpout  = { h = { 16, 9 }, n = { 16, 15 }, p = { 16, 28 }, la = { { 11, 22 }, { 11, 29 } }, ra = { { 23, 10 }, { 26, 3 } }, ll = { { 13, 38 }, { 12, 47 } }, rl = { { 19, 38 }, { 20, 47 } }, cap = 0, dark = true },
  pratfall= { h = { 4, 40 }, n = { 9, 41 }, p = { 21, 42 }, la = { { 8, 35 }, { 5, 32 } }, ra = { { 13, 45 }, { 10, 47 } }, ll = { { 25, 36 }, { 30, 33 } }, rl = { { 27, 44 }, { 31, 46 } }, cap = 0 },
  slide   = { h = { 8, 30 }, n = { 11, 35 }, p = { 18, 41 }, la = { { 6, 30 }, { 3, 26 } }, ra = { { 9, 39 }, { 6, 43 } }, ll = { { 24, 41 }, { 30, 45 } }, rl = { { 24, 45 }, { 31, 47 } }, cap = 0 },
  walk1   = { h = { 17, 8 }, n = { 17, 14 }, p = { 16, 28 }, la = { { 13, 21 }, { 12, 27 } }, ra = { { 20, 21 }, { 21, 27 } }, ll = { { 13, 38 }, { 11, 47 } }, rl = { { 19, 38 }, { 21, 47 } }, cap = 1 },
  cheer   = { h = { 16, 8 }, n = { 16, 14 }, p = { 16, 28 }, la = { { 9, 8 }, { 7, 1 } }, ra = { { 23, 8 }, { 25, 1 } }, ll = { { 12, 38 }, { 10, 47 } }, rl = { { 20, 38 }, { 22, 47 } }, cap = 0 },
}
P.POSES = POSES

local function lw(w) return math.max(1, floor(w * S + 0.5)) end
local function X(v) return v * S end

local function drawLimbs(pose, pass, body)
  -- pass 1: black outline (wider). pass 2: fill.
  local add = pass == 1 and 2 or 0
  local function seg(a, b, w)
    gfx.setLineWidth(lw(w) + add)
    gfx.drawLine(X(a[1]), X(a[2]), X(b[1]), X(b[2]))
  end
  local n, p = pose.n, pose.p
  local shl = { n[1] - 3, n[2] + 1 }
  local shr = { n[1] + 3, n[2] + 1 }
  local hpl = { p[1] - 2, p[2] }
  local hpr = { p[1] + 2, p[2] }
  if pass == 2 then body() end
  seg(hpl, pose.ll[1], 4); seg(pose.ll[1], pose.ll[2], 4)
  seg(hpr, pose.rl[1], 4); seg(pose.rl[1], pose.rl[2], 4)
  seg(n, p, 9)
  seg(shl, pose.la[1], 3); seg(pose.la[1], pose.la[2], 3)
  seg(shr, pose.ra[1], 3); seg(pose.ra[1], pose.ra[2], 3)
end

--- variant: "home" (white flannels), "away" (gray), "ump", "fan"
local function renderPose(name, variant)
  local pose = POSES[name]
  local img = gfx.image.new(CW, CH, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setLineCapStyle(gfx.kLineCapStyleRound)
  local dark = pose.dark or variant == "ump"
  -- outline pass
  gfx.setColor(gfx.kColorBlack)
  drawLimbs(pose, 1, nil)
  gfx.fillCircleAtPoint(X(pose.h[1]), X(pose.h[2]), X(4) + 1)
  if pose.bat then
    gfx.setLineWidth(lw(2) + 2)
    gfx.drawLine(X(pose.bat[1]), X(pose.bat[2]), X(pose.bat[3]), X(pose.bat[4]))
  end
  -- fill pass
  local function bodyFill()
    if dark then
      gfx.setColor(gfx.kColorBlack)
    elseif variant == "away" then
      gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
    elseif variant == "fan" then
      gfx.setDitherPattern(0.25, gfx.image.kDitherTypeBayer4x4)
    else
      gfx.setColor(gfx.kColorWhite)
    end
  end
  bodyFill()
  drawLimbs(pose, 2, bodyFill)
  -- pinstripe-ish belt + number on back
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(1)
  if not dark then
    gfx.drawLine(X(pose.p[1] - 3), X(pose.p[2] - 1), X(pose.p[1] + 3), X(pose.p[2] - 1))
  end
  if pose.back and not dark then
    gfx.setColor(variant == "away" and gfx.kColorWhite or gfx.kColorBlack)
    BCKit.fonts.tiny:drawText("7", X(pose.n[1]) - 3, X(pose.n[2]) + 4)
  end
  -- head: skin (white) with dark cap
  gfx.setColor(gfx.kColorWhite)
  gfx.fillCircleAtPoint(X(pose.h[1]), X(pose.h[2]), X(4) - 1)
  gfx.setColor(gfx.kColorBlack)
  if variant == "fan" then
    -- bare head, messy hair
    gfx.fillRect(X(pose.h[1] - 4), X(pose.h[2] - 5), X(8), X(2))
  else
    local cx, cy = X(pose.h[1]), X(pose.h[2])
    gfx.fillRect(cx - X(4), cy - X(5), X(8), X(4))
    local bill = pose.cap or 0
    if bill ~= 0 then
      gfx.fillRect(bill > 0 and cx + X(2) or cx - X(7), cy - X(2), X(5), X(1))
    elseif not pose.back then
      gfx.fillRect(cx - X(4), cy - X(1.5), X(8), X(1))
    end
  end
  if pose.mask then
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(1)
    local cx, cy = X(pose.h[1]), X(pose.h[2])
    gfx.drawLine(cx - 4, cy - 1, cx + 4, cy - 1)
    gfx.drawLine(cx - 4, cy + 2, cx + 4, cy + 2)
    gfx.drawLine(cx, cy - 3, cx, cy + 4)
  end
  if pose.glove then
    gfx.setColor(gfx.kColorBlack)
    gfx.fillCircleAtPoint(X(pose.glove[1]), X(pose.glove[2]), 3)
  end
  if pose.bat then
    gfx.setColor(gfx.kColorWhite)
    gfx.setLineWidth(lw(2))
    gfx.drawLine(X(pose.bat[1]), X(pose.bat[2]), X(pose.bat[3]), X(pose.bat[4]))
  end
  gfx.popContext()
  gfx.setLineWidth(1)
  return img
end

-- Raccoon: 2 frames, 24x14
local function renderRaccoon(frame)
  local img = gfx.image.new(32, 18, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillEllipseInRect(6, 5, 18, 9)          -- body
  gfx.fillCircleAtPoint(25, 7, 4)            -- head
  gfx.fillTriangle(23, 3, 25, 0, 27, 3)      -- ear
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(23, 6, 6, 2)                  -- mask band
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(25, 6, 1, 1)
  -- ringed tail
  for i = 0, 3 do
    gfx.setColor(i % 2 == 0 and gfx.kColorBlack or gfx.kColorWhite)
    gfx.fillRect(1 + i * 2, 5 + (frame == 1 and i % 2 or (i + 1) % 2), 2, 3)
  end
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(0, 5, 8, 4)
  -- legs
  local o = frame == 1 and 2 or -1
  gfx.fillRect(9 + o, 13, 2, 4); gfx.fillRect(19 - o, 13, 2, 4)
  gfx.fillRect(12 - o, 13, 2, 4); gfx.fillRect(16 + o, 13, 2, 4)
  gfx.popContext()
  return img
end

---------------------------------------------------------------------------
-- frame sources: the assets agent's imagetables (images/puppets/1x|2x/<table>), else the
-- procedural poses above.
--
-- Logical frames used by Play: set kick release (pitcher) · stance swing follow (batter) ·
-- catcher receive cthrow · ump umpout umpsafe · ready run1 run2 reach dive throw (fielders) ·
-- rrun1 rrun2 slide (runners) · stand walk1 pratfall cheer · raccoon1 raccoon2.
-- Variants: home, away, ump, fan (streaker), critter.

local MAP = {
  set = { "pitcher_back", 1, true }, kick = { "pitcher_back", 2, true }, release = { "pitcher_back", 3, true },
  sset = { "pitcher_side", 1, true }, skick = { "pitcher_side", 2, true }, srelease = { "pitcher_side", 3, true },
  stance = { "batter", 1, true }, swing = { "batter", 2, true }, follow = { "batter", 3, true },
  catcher = { "catcher", 1, true }, receive = { "catcher", 2, true }, cthrow = { "catcher", 3, true },
  ump = { "umpire", 1 }, umpout = { "umpire", 2 }, umpsafe = { "umpire", 3 },
  ready = { "fielder", 1, true }, run1 = { "fielder", 2, true }, run2 = { "fielder", 3, true },
  reach = { "fielder", 4, true }, dive = { "fielder", 5, true }, throw = { "fielder", 6, true },
  pratfall = { "fielder", 5, true }, stand = { "fielder", 1, true }, cheer = { "fielder", 4, true },
  rrun1 = { "runner", 1, true }, rrun2 = { "runner", 2, true }, slide = { "runner", 3, true }, walk1 = { "runner", 1, true },
  raccoon1 = { "raccoon", 1, nil, true }, raccoon2 = { "raccoon", 2, nil, true },
}
-- variant overrides
local FAN = { run1 = { "streaker", 1 }, run2 = { "streaker", 2 }, rrun1 = { "streaker", 1 }, rrun2 = { "streaker", 2 }, stand = { "fan", 1 }, cheer = { "fan", 2 } }
-- procedural names for the fallback poses
local PROC = { receive = "catcher", cthrow = "catcher", umpsafe = "ump", dive = "pratfall", throw = "release", rrun1 = "run1", rrun2 = "run2", sset = "set", skick = "kick", srelease = "release" }

local tables = {}   -- "1x/name" → imagetable | false
-- ONE image object per imagetable cell for the whole session. The C renderer keeps the raw bitmap
-- pointer (bc3d.sprite) without a Lua reference, so a cell must never be re-wrapped while an older
-- wrapper of it can still be garbage-collected: with tables cached across replays, a second replay
-- would otherwise hand C bitmaps whose (previous-replay) wrappers the GC then frees.
local wraps = setmetatable({}, { __mode = "k" })   -- [imagetable] → { [i] = image }
local function cell(t, i)
  local w = wraps[t]
  if not w then w = {}; wraps[t] = w end
  local im = w[i]
  if im == nil then im = t:getImage(i) or false; w[i] = im end
  return im or nil
end
local lateArmed = false   -- set after P.preload: any later file load is logged ([bcload] late-load)
local function tbl(scale, name)
  local key = scale .. "/" .. name
  local t = tables[key]
  if t == nil then
    local path = "images/puppets/" .. scale .. "/" .. name
    t = false
    if playdate.file.exists(path .. ".pdt") then
      if lateArmed then print("[bcload] late-load " .. path) end
      t = gfx.imagetable.new(path) or false
    end
    tables[key] = t
  end
  return t or nil
end

---------------------------------------------------------------------------
-- Packed puppet art (tools/assets/humanoid/sprites.py pack_views): every runtime puppet cell
-- lives in a few chunk imagetables images/puppets/{1x,2x}/views_<n> (one file per loader slice
-- on device: per-file cost dominated the old 48-file preload). Layout, rebuilt here from the
-- same constants as the build: rows of F cells (frames 1..F) in this order —
--   for each VIEW_SETS set, variant (home, _away), view v0..v7  (2x: CLOSE_2X sets only)
--   then LEGACY_ROWS (single-view tables, one row each)
-- a new chunk starts when the next row would pass CHUNK_CAP cells.
local VIEW_SETS <const> = { { "pitcher_seq", 6, true }, { "batter_seq", 6, true }, { "catcher", 3, true },
  { "umpire", 3, false }, { "fielder", 6, true }, { "runner", 7, true }, { "runner_seq", 4, true },
  { "catcher_reach", 14, true, { 0, 2, 4, 6 } }, { "walker", 6, true },
  { "bunter", 5, true }, { "fieldx", 13, true, { 0, 2, 4, 6 }, { 2, 6, 0, 4 } }, { "fieldin", 3, true } }      -- [4] = view subset (else all 8)
local CLOSE_2X <const> = { pitcher_seq = true, batter_seq = true, catcher = true, umpire = true, fielder = true,
  catcher_reach = true, walker = true, bunter = true, fieldx = true, fieldin = true }
local LEGACY_ROWS <const> = { { "accent", 4 }, { "accent_away", 4 }, { "fan", 4 }, { "mascot", 2 }, { "streaker", 2 } }
local CHUNK_CAP <const> = { 112, 46 }
local NVIEWS <const> = 8
-- legacy table → view set, default view (when drawn without a facing), frame remap
local LEGACY_VIEW <const> = {
  pitcher_back = { "pitcher_seq", 4, { 1, 2, 5 } }, pitcher_side = { "pitcher_seq", 6, { 1, 2, 5 } },
  pitcher_back_seq = { "pitcher_seq", 4 }, pitcher_side_seq = { "pitcher_seq", 6 },
  batter = { "batter_seq", 1, { 1, 4, 6 } }, batter_seq = { "batter_seq", 1 },
  catcher = { "catcher", 0 }, umpire = { "umpire", 0 }, fielder = { "fielder", 6 },
  runner = { "runner", 6 }, runner_seq = { "runner_seq", 6 }, catcher_reach = { "catcher_reach", 0 },
  walker = { "walker", 6 }, bunter = { "bunter", 1 }, fieldx = { "fieldx", 6 }, fieldin = { "fieldin", 6 } }
-- sets with a view subset: k (0..7) -> nearest shipped view
local VIEWMAP = {}
for _, vs in ipairs(VIEW_SETS) do
  if vs[4] then
    local m = {}
    -- (ties between two shipped views go to the first in vs[5]: the catches read best side-on)
    local order = vs[5] or vs[4]
    for k = 0, 7 do
      local best, bd = order[1], 99
      for _, v in ipairs(order) do
        local d = math.abs(((k - v + 4) % 8) - 4)
        if d < bd then best, bd = v, d end
      end
      m[k] = best
    end
    VIEWMAP[vs[1]] = m
  end
end
local loc, nChunks, needLen = { {}, {} }, { 0, 0 }, { {}, {} }
local hasAway = {}
do
  for s = 1, 2 do
    local L, chunk, n = loc[s], 1, 0
    local function row(key, F)
      if n > 0 and n + F > CHUNK_CAP[s] then chunk, n = chunk + 1, 0 end
      L[key] = { chunk, n }
      n = n + F
      needLen[s][chunk] = n
    end
    for _, vs in ipairs(VIEW_SETS) do
      hasAway[vs[1]] = vs[3]
      if s == 1 or CLOSE_2X[vs[1]] then
        for _, suf in ipairs(vs[3] and { "", "_away" } or { "" }) do
          if vs[4] then for _, v in ipairs(vs[4]) do row(vs[1] .. suf .. ":" .. v, vs[2]) end
          else for v = 0, NVIEWS - 1 do row(vs[1] .. suf .. ":" .. v, vs[2]) end end
        end
      end
    end
    for _, lr in ipairs(LEGACY_ROWS) do row(lr[1], lr[2]) end
    nChunks[s] = chunk
  end
end
-- decoded chunks, cached for the whole session (survive P.release: a second replay loads nothing)
local chunks = { {}, {} }
local function chunkTable(s, c)
  local t = chunks[s][c]
  if t == nil then
    local path = "images/puppets/" .. (s == 1 and "1x" or "2x") .. "/views_" .. c
    if lateArmed then print("[bcload] late-load " .. path) end
    t = gfx.imagetable.new(path) or false
    if t and t:getLength() < needLen[s][c] then
      print("[bcload] " .. path .. " has " .. t:getLength() .. " cells, layout needs " .. needLen[s][c]); t = false
    end
    chunks[s][c] = t
  end
  return t
end
local function chunkImg(s, key, f)
  local l = loc[s][key]
  if not l then return nil end
  local t = chunkTable(s, l[1])
  return t and cell(t, l[2] + f) or nil
end
-- virtual table names "@<set>#<view>" for P.orient's picks (precomputed: no per-frame strings)
local VNAME = {}
for _, vs in ipairs(VIEW_SETS) do
  local r = {}
  for v = 0, NVIEWS - 1 do r[v] = "@" .. vs[1] .. "#" .. v end
  VNAME[vs[1]] = r
end
--- packed cells for (variant, table, frame) → i1, i2 (nil when the table isn't packed)
local function packed(variant, tname, f)
  local set, view
  if tname:sub(1, 1) == "@" then
    set, view = tname:match("^@(.+)#(%d)$")
    view = tonumber(view)
  else
    local lv = LEGACY_VIEW[tname]
    if lv then
      set, view = lv[1], lv[2]
      if lv[3] then f = lv[3][f] or f end
    end
  end
  local key
  if set then
    key = set .. ((variant == "away" and hasAway[set]) and "_away" or "") .. ":" .. view
  else
    key = (variant == "away" and loc[1][tname .. "_away"]) and (tname .. "_away") or tname
    if not loc[1][key] then return nil end
  end
  return chunkImg(1, key, f), chunkImg(2, key, f)
end

--- Resolve (variant, frame) → img1x, img2x|nil, anchorX, anchorY (1x), flipInverted
local resolved = {}   -- [variant][frame] → { i1, i2, ax, ay, inv }
function P.frame(variant, frame)
  local rv = resolved[variant]
  if not rv then rv = {}; resolved[variant] = rv end
  local r = rv[frame]
  if r then return r[1], r[2], r[3], r[4], r[5] end
  local m = (variant == "fan" and FAN[frame]) or MAP[frame]
  local i1, i2, ax, ay, inv
  if m then
    i1, i2 = packed(variant, m[1], m[2])
    if i1 then ax, ay, inv = 14, 42, m[4] or false end
  end
  if m and not i1 then
    local name = m[1]
    if m[3] and variant == "away" then name = name .. "_away" end
    local t1, t2 = tbl("1x", name), tbl("2x", name)
    if t1 then
      i1 = cell(t1, m[2])
      i2 = t2 and cell(t2, m[2]) or nil
      if name == "raccoon" then ax, ay = 12, 13 else ax, ay = 14, 42 end
      inv = m[4] or false
    end
  end
  if not i1 then
    -- procedural fallback (43x64 canvas, feet at bottom centre)
    local pf = PROC[frame] or frame
    local v = variant == "critter" and "home" or variant
    i1 = P.base(v, pf)
    local w, h = i1:getSize()
    ax, ay = w / 2, h - 1
    inv = false
    if pf == "raccoon1" or pf == "raccoon2" then ax, ay = w / 2, h - 1 end
  end
  rv[frame] = { i1, i2, ax, ay, inv }
  return i1, i2, ax, ay, inv
end

-- procedural base frames
local base = {}
function P.base(variant, frame)
  local key = variant .. "/" .. frame
  local img = base[key]
  if img then return img end
  if frame == "raccoon1" or frame == "raccoon2" then
    img = renderRaccoon(frame == "raccoon1" and 1 or 2)
  else
    img = renderPose(POSES[frame] and frame or "stand", variant)
  end
  base[key] = img
  return img
end

-- the shipped figures are 40 px tall at 1x for 6.2 ft; the procedural ones 64 px for 6 ft
function P.figure(img1)
  local _, h = img1:getSize()
  if h == CH then return CH - 2, 6.0 end
  return 40, 6.2
end

--- Resolve a raw table frame (animatic track keys: table name + 1-based frame) for a
--- variant: "away" picks <table>_away when it exists. → img1x, img2x|nil, ax, ay, inv
local resolvedT = {}  -- [variant][table][f] → { i1, i2, ax, ay, inv }
function P.frameT(variant, tname, f)
  local rv = resolvedT[variant]
  if not rv then rv = {}; resolvedT[variant] = rv end
  local rt = rv[tname]
  if not rt then rt = {}; rv[tname] = rt end
  local r = rt[f]
  if r then return r[1], r[2], r[3], r[4], r[5] end
  local i1, i2 = packed(variant, tname, f)
  if not i1 and tname:sub(1, 1) ~= "@" then
    local name = tname
    if variant == "away" and tbl("1x", tname .. "_away") then name = tname .. "_away" end
    local t1 = tbl("1x", name)
    i1 = t1 and cell(t1, f)
    if i1 then
      local t2 = tbl("2x", name)
      i2 = t2 and f <= t2:getLength() and cell(t2, f) or nil
    end
  end
  if not i1 then
    -- missing art: the procedural stand pose
    P.nProc = P.nProc + 1
    local a1 = P.base(variant == "away" and "away" or "home", "stand")
    local w, h = a1:getSize()
    rt[f] = { a1, nil, w / 2, h - 1, false }
    return a1, nil, w / 2, h - 1, false
  end
  local ax, ay = 14, 42
  local inv = false
  if tname == "raccoon" then ax, ay, inv = 12, 13, true end
  rt[f] = { i1, i2, ax, ay, inv }
  return i1, i2, ax, ay, inv
end

--- C renderer: sprite ids, registered lazily. Logical frames and track keys that resolve
--- to the same table cell share one id (keeps us well under the C side's MAX_SPRITES).
local ids, idsT, invs, nextId = {}, {}, {}, 1
-- The C side holds MAX_SPRITES (256) ids. With the multi-view tables a long game can touch
-- more cells than that, so ids are recycled least-recently-used: owners[id] lists the cache
-- slots that point at an id (cleared on reuse), used[id] the frame it was last drawn.
local MAX_IDS <const> = 250
local owners, used = {}, {}
local tick = 0
local pendBody, pendLook = 1, 0
function P.frameDone() tick = tick + 1; pendBody, pendLook = 1, 0 end
local function own(id, t, k) local o = owners[id]; o[#o + 1] = t; o[#o + 1] = k end
P.nReg, P.nRecycle, P.nProc, P.nLooked = 0, 0, 0, 0
-- C registry generation: bumped by every bc3d.reset (whoever calls it). An id registered in an
-- older generation is gone from C, so the Lua caches are dropped and the cell re-registered
-- (P.staleIds counts it; it should stay 0). held[id] pins the images C points at.
local cgen, regGen, held = 0, {}, {}
P.staleIds, P.badDraws = 0, 0
if bc3d and not bc3d.__pupWrapped then
  local rawReset = bc3d.reset
  bc3d.reset = function(...) cgen = cgen + 1; return rawReset(...) end
  bc3d.__pupWrapped = true
end
local function forgetIds()
  ids, idsT, invs, nextId = {}, {}, {}, 1
  owners, used, regGen, held = {}, {}, {}, {}
end
--- true when sprite id is registered in the current C generation (cheap; used before every bb)
function P.live(id)
  if regGen[id] == cgen then return true end
  P.badDraws = P.badDraws + 1
  return false
end
---------------------------------------------------------------------------
-- Player looks (ballcast/looks.lua): body type = a width factor + figure height baked into the
-- sprite's C size caches (one more sprite id per body that's on screen; no per-frame cost), the
-- rest (skin dither, facial hair, socks, sleeves, helmet, number) = C stamps on the billboard
-- (bc3d look bits) placed by per-cell landmarks (images/puppets/landmarks.json).
-- P.use(body, look) applies to the NEXT puppet queued (render3d's puppet/puppetT → idT + bb).
local BODY <const> = { { 1, 1 }, { 0.9, 1.06 }, { 1.14, 0.96 } }   -- width factor, height factor
P.BODY = BODY
function P.use(body, look) pendBody, pendLook = body or 1, look or 0 end
local LM = nil      -- "set#view" → landmark string (24 chars a frame)
local function loadLandmarks()
  if LM then return LM end
  LM = {}
  local path = "images/puppets/landmarks.json"
  local doc = playdate.file.exists(path) and json.decodeFile(path) or nil
  if doc and doc.cells then LM = doc.cells end
  P.gloves = doc and doc.glove or {}
  return LM
end
P.loadLandmarks = loadLandmarks
--- the glove of catch-set frame f in the side view: 1x cell px (anchor 14, 42), or nil
function P.gloveCell(set, f)
  if not LM then loadLandmarks() end
  local g = P.gloves and P.gloves[set]
  g = g and g[f]
  if g then return g[1], g[2] end
end
local function landmarksFor(tname, f)
  local L = LM or loadLandmarks()
  local key
  if tname:sub(1, 1) == "@" then key = tname:sub(2)
  else
    local lv = LEGACY_VIEW[tname]
    if not lv then return nil end
    key = lv[1] .. "#" .. lv[2]
    if lv[3] then f = lv[3][f] or f end
  end
  local str = L[key]
  if not str or #str < f * 24 then return nil end
  return str:sub((f - 1) * 24 + 1, f * 24)
end
if bc3d and not bc3d.__lookWrapped then
  -- the look of the puppet being queued rides along as bb arg 13 (render3d stays look-agnostic)
  local rawBB = bc3d.bb
  bc3d.bb = function(id, x, y, z, fl, hs, sx, sy, rot, dx, dy, piv)
    local lk = pendLook
    pendBody, pendLook = 1, 0
    if lk ~= 0 then return rawBB(id, x, y, z, fl, hs or 1, sx or 1, sy or 1, rot or 0, dx or 0, dy or 0, piv or 0, lk) end
    if sx then return rawBB(id, x, y, z, fl, hs, sx, sy, rot, dx, dy, piv) end
    return rawBB(id, x, y, z, fl)
  end
  bc3d.__lookWrapped = true
end

local function register(i1, i2, ax, ay, inv, body, lm)
  P.nReg = P.nReg + 1
  local id = nextId
  if id > MAX_IDS then
    -- reuse the stalest id not drawn this frame
    local best, bt = nil, tick
    for i = 1, MAX_IDS do
      local u = used[i] or -1
      if u < bt then best, bt = i, u end
    end
    id = best or 1
    P.nRecycle = P.nRecycle + 1
    local o = owners[id]
    if o then for j = 1, #o, 2 do o[j][o[j + 1]] = nil end end
  else
    nextId = nextId + 1
  end
  owners[id] = {}
  used[id] = tick
  regGen[id] = cgen
  held[id] = { i1, i2 }
  local fh, ft = P.figure(i1)
  local bd = BODY[body or 1] or BODY[1]
  if bd[1] ~= 1 or lm then bc3d.sprite(id, i1, i2, ax, ay, fh, ft * bd[2], bd[1], lm)
  else bc3d.sprite(id, i1, i2, ax, ay, fh, ft) end
  invs[id] = inv or false
  P.nLooked = P.nLooked + ((body or 1) ~= 1 and 1 or 0)
  return id
end

--- sprite id for a raw table frame (+ whether the art faces the other way)
local BODYKEY <const> = { "", "/2", "/3" }
function P.idT(variant, tname, f)
  local v = (variant == "away") and "away" or (variant == "fan" or variant == "ump" or variant == "critter") and variant or "home"
  local body = pendBody
  if v ~= "home" and v ~= "away" then body = 1 end
  local vk = body == 1 and v or (v .. BODYKEY[body])
  local iv = idsT[vk]
  if not iv then iv = {}; idsT[vk] = iv end
  local it = iv[tname]
  if not it then it = {}; iv[tname] = it end
  local id = it[f]
  if id then
    if regGen[id] == cgen then used[id] = tick; return id, invs[id] end
    P.staleIds = P.staleIds + 1      -- C was reset under us: start over
    forgetIds()
    return P.idT(variant, tname, f)
  end
  local i1, i2, ax, ay, inv = P.frameT(v, tname, f)
  id = register(i1, i2, ax, ay, inv, body, (v == "home" or v == "away") and landmarksFor(tname, f) or nil)
  it[f] = id
  own(id, it, f)
  return id, invs[id]
end

--- sprite id + whether the art faces the other way (raccoon)
function P.id(variant, frame)
  if pendBody ~= 1 then
    -- a body variant: its own ids (the logical-frame cache below is shared by every body)
    local m = (variant == "fan" and FAN[frame]) or MAP[frame]
    if m then
      local id = P.idT(variant, m[1], m[2])
      if m[4] then invs[id] = true end
      return id, invs[id]
    end
  end
  local iv = ids[variant]
  if not iv then iv = {}; ids[variant] = iv end
  local id = iv[frame]
  if id then
    if regGen[id] == cgen then used[id] = tick; return id, invs[id] end
    P.staleIds = P.staleIds + 1
    forgetIds()
    return P.id(variant, frame)
  end
  local m = (variant == "fan" and FAN[frame]) or MAP[frame]
  if m then
    id = P.idT(variant, m[1], m[2])
    if m[4] then invs[id] = true end
  else
    id = register(P.frame(variant, frame))
  end
  iv[frame] = id
  own(id, iv, frame)
  return id, invs[id]
end

--- Lua fallback: draw with the parks.json sprite rule. depthScale = camera scale / depth.
--- tf: raw table frame index (then `frame` is a table name, as in P.frameT).
local scaled = {}
function P.drawAt(variant, frame, sx, sy, ppf, flip, tf)
  local i1, i2, ax, ay, inv
  if tf then i1, i2, ax, ay, inv = P.frameT(variant, frame, tf)
  else i1, i2, ax, ay, inv = P.frame(variant, frame) end
  local fh, ft = P.figure(i1)
  local s = ft * ppf / fh
  if s < 0.5 then s = 0.5 end
  local src, f, axs, ays
  if s >= 1.4 and i2 then
    src, f = i2, s / 2
    axs, ays = ax * 2, ay * 2
  else
    src, f = i1, (s >= 0.8 and s < 1.4) and 1 or s
    axs, ays = ax, ay
  end
  local img = src
  if f ~= 1 then
    local bucket = floor(f * 20 + 0.5)
    if bucket < 1 then bucket = 1 end
    local row = scaled[src]
    if not row then row = {}; scaled[src] = row end
    img = row[bucket]
    if not img then img = src:scaledImage(bucket / 20); row[bucket] = img end
    f = bucket / 20
  end
  axs, ays = axs * f, ays * f
  local w = img:getSize()
  local fl = (flip and not inv) or (inv and not flip)
  local x = fl and (sx - (w - axs)) or (sx - axs)
  img:draw(floor(x), floor(sy - ays), fl and gfx.kImageFlippedX or gfx.kImageUnflipped)
end

--- 2D (screen-space) animatic puppet for the bleacher cam: draws track `track` at track
--- time tt with its feet at screen (x, y), from the 2x table. fOff shifts the frame (the
--- fan table's gray-shirt pair is frames 3-4). Squash/stretch and rotation go through
--- image:drawRotated about the key's pivot; flips use a cached mirrored copy.
local mirrored = {}
local function mirror(img)
  local m = mirrored[img]
  if m then return m end
  local w, h = img:getSize()
  m = gfx.image.new(w, h, gfx.kColorClear)
  gfx.pushContext(m)
  img:draw(0, 0, gfx.kImageFlippedX)
  gfx.popContext()
  mirrored[img] = m
  return m
end
function P.drawTrack2D(variant, track, tt, x, y, flip, seed, fOff)
  local Anim = BallCast.Anim
  local tn, f, sx, sy, rot, dx, dy, kflip, piv = Anim.sample(track, tt, seed)
  if not tn then return end
  local i1, i2, ax, ay = P.frameT(variant, tn, f + (fOff or 0))
  local img, k = i2 or i1, i2 and 2 or 1
  ax, ay = ax * k, ay * k
  local fl = (flip and true or false) ~= kflip
  if flip then rot, dx = -rot, -dx end
  local w, h = img:getSize()
  if fl then img = mirror(img); ax = w - ax end
  local px, py = x + dx * k, y + dy * k - piv * k        -- pivot on screen
  if sx == 1 and sy == 1 and rot == 0 then
    img:draw(floor(px - ax), floor(py - (ay - piv * k)))
    return
  end
  -- image centre relative to the pivot, scaled then rotated (clockwise on screen)
  local u, v = (w / 2 - ax) * sx, (h / 2 - (ay - piv * k)) * sy
  local r = math.rad(rot)
  local c, s = math.cos(r), math.sin(r)
  img:drawRotated(floor(px + c * u - s * v + 0.5), floor(py + s * u + c * v + 0.5), rot, sx, sy)
end

---------------------------------------------------------------------------
-- Multi-view puppets. Each pose set is shipped from 8 yaws (images/puppets/<set>_v0..v7:
-- camera at azimuth k*45 deg around the figure, 0 = in front, 90 = on its left, elevation 6)
-- and 4 steep views (<set>_h0..h3: azimuth k*90 at 65 deg down) — tools/assets/humanoid.
-- P.orient picks the one matching the camera vs. the puppet's world facing, per puppet with
-- hysteresis (key = the puppet's seed), so the 3D cams see the right side of everyone.
-- Frame numbers are the legacy tables', so animatic tracks work unchanged.

local HYST <const> = 8                         -- degrees past the half-step before switching yaw
local atan <const>, cos <const>, sin <const> = math.atan, math.cos, math.sin
local R2D <const> = 180 / math.pi
local hyst = {}   -- [key] → current view k

--- (variant, logical frame) → table name, frame (nil for procedural-only frames)
function P.tableOf(variant, frame)
  local m = (variant == "fan" and FAN[frame]) or MAP[frame]
  if m then return m[1], m[2] end
end

--- Pick the view for table `tname` frame `f` drawn at (x, y, z) facing world yaw `face` (radians,
--- field coords: 0 = +x/1B side, pi/2 = +y/CF) from a camera at (ex, ey, ez). lefty mirrors the
--- figure (left-handed batter). → virtual table "@<set>#<view>", frame (remapped onto the set),
--- facesLeft (the drawn figure faces screen-left; callers mirror key rotation/offset); nil when
--- the table has no view set (accent, fan, mascot, streaker, raccoon: legacy art).
function P.orient(tname, f, x, y, z, face, lefty, key, ex, ey, ez)
  local lv = LEGACY_VIEW[tname]
  if not lv then return nil end
  if lv[3] then f = lv[3][f] or f end
  key = key or 0
  local vx, vy = ex - x, ey - y
  local fx, fy = cos(face), sin(face)
  local fwd = vx * fx + vy * fy
  local lft = fx * vy - fy * vx
  if lefty then lft = -lft end
  local az = atan(lft, fwd) * R2D
  local k = floor(az / 45 + 0.5) % 8
  local cur = hyst[key or 0]
  if cur and cur ~= k then
    local d = (az - cur * 45 + 540) % 360 - 180
    if d < 22.5 + HYST and d > -22.5 - HYST then k = cur end
  end
  hyst[key] = k
  local vm = VIEWMAP[lv[1]]
  if vm then k = vm[k] end
  local fl = k > 0 and k < 4
  if lefty then fl = not fl end
  return VNAME[lv[1]][k], f, fl
end

--- Load the packed puppet art once per session, from the loader: one chunk file per loader slice
--- (yields before each file), Y() for the loader's progress. Chunks already decoded (an earlier
--- replay this session) are skipped. Afterwards any table load prints "[bcload] late-load <path>".
P.preloadMax, P.preloadMaxName = 0, ""
function P.preload(Y)
  P.preloadMax = 0
  local now = playdate.getCurrentTimeMilliseconds
  local yieldable = coroutine.isyieldable()
  local n = 0
  local sliceT, lastDt, first = now(), 0, true
  local function load(fn, name)
    -- one slice holds as many files as fit in ~30 ms (on device: one per frame, ~35-44 ms each)
    if yieldable and (first or now() - sliceT + lastDt > 30) then coroutine.yield(); sliceT = now() end
    first = false
    local a = now()
    fn()
    local dt = now() - a
    lastDt = dt
    if dt > P.preloadMax then P.preloadMax, P.preloadMaxName = dt, name end
    n = n + 1
    if Y then Y() end
  end
  for s = 1, 2 do
    for c = 1, nChunks[s] do
      if chunks[s][c] == nil then load(function() chunkTable(s, c) end, s .. "x/views_" .. c) end
    end
  end
  if tables["1x/raccoon"] == nil then load(function() tbl("1x", "raccoon") end, "1x/raccoon") end
  if not LM then load(loadLandmarks, "landmarks.json") end
  lateArmed = true
  return n
end

--- forget the session cache of decoded chunks (memory pressure)
function P.dropChunks() chunks = { {}, {} } end

--- one-line device check: what the renderer was asked to draw vs. what reached C
function P.report(when, dg)
  local ok, all = 0, 0
  for s = 1, 2 do for c = 1, nChunks[s] do all = all + 1; if chunks[s][c] then ok = ok + 1 end end end
  local nt = 0
  if BallCast.Anim and BallCast.Anim.load then for _ in pairs(BallCast.Anim.load()) do nt = nt + 1 end end
  dg = dg or {}
  print(string.format("[bcpup] %s: drew %d puppets, %d via bb, skipped %d (far %d, no track %d%s) | chunks %d/%d, " ..
    "anim tracks %d, ids registered %d, procedural %d, stale healed %d, unregistered draws %d, bc3d %s",
    when, dg.calls or 0, dg.bb or 0, (dg.far or 0) + (dg.notrack or 0), dg.far or 0, dg.notrack or 0,
    dg.lastNoTrack and (" e.g. " .. dg.lastNoTrack) or "", ok, all, nt, P.nReg, P.nProc, P.staleIds, P.badDraws,
    tostring(bc3d ~= nil)))
end

--- snapshot the counters now (e.g. at the first pitch); printed at scene exit, never mid-play
local snaps = {}
function P.snapshot(when, dg)
  dg = dg or {}
  snaps[#snaps + 1] = { when = when, calls = dg.calls or 0, bb = dg.bb or 0, far = dg.far or 0,
    notrack = dg.notrack or 0, lastNoTrack = dg.lastNoTrack }
end

function P.release()
  base, scaled, resolved, resolvedT, mirrored = {}, {}, {}, {}, {}   -- tables/chunks/cells: session cache
  for _, sn in ipairs(snaps) do P.report(sn.when, sn) end
  snaps = {}
  P.report("scene done", BallCast.Render and BallCast.Render.diag)
  if BallCast.Juice and BallCast.Juice.report then BallCast.Juice.report() end
  if BallCast.Looks then BallCast.Looks.reset() end
  if BallCast.Play and BallCast.Play.worldReport then BallCast.Play.worldReport() end
  P.nReg, P.nRecycle, P.nProc, P.staleIds, P.badDraws, P.nLooked = 0, 0, 0, 0, 0, 0
  if bc3d then bc3d.reset() end
  forgetIds()
  hyst, lateArmed = {}, false
end
