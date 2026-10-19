-- BallCast animatic tracks: untweened held keyframes over the prerendered puppet tables,
-- with squash/stretch, shake, vibrate, flips, spins and a per-puppet "boil".
--
-- Data: images/puppets/anim_tracks.json (spec: images/README.md "Puppet animatic tracks";
-- reference implementation tools/assets/humanoid/anim_tracks.py `play`). 30 fps keys.
--
-- Everything here is a pure function of (track, time, seed) so crank-scrubbing is exact:
-- vibrate and boil use a hash of (seed, frame) instead of a running RNG.
--
--   A.sample(track, t, seed [, vib]) → tbl, f, sx, sy, rot, dx, dy, flip, pivot, done
--   A.boil(seed, frame)              → dx, dy   (1 px jitter every 6–14 frames, 1–2 frames long)
--   A.length(track)                  → seconds (one pass)
--   A.vibrate(seed, frame, px)       → dx, dy   (random in [-px, px])
--   A.keyTime(track, i)              → seconds to the start of key i

-- one instance per session (see puppets.lua: the cards bundle imports us again at runtime)
BallCast = BallCast or {}
if BallCast.Anim then return end

import "ballcast/kit"

local floor <const> = math.floor

BallCast = BallCast or {}
local A = {}
BallCast.Anim = A

local FPS = 30
local DECAY = 0.55
local CENTER_PIV = 20       -- anchor (14,42) → centre (14,22) in 1x px
-- The JSON's boil (every 6-14 frames) read as jitter on hardware: idle puppets now settle
-- for 2.5-6 s between single-frame 1 px twitches, and tracks never boil.
local BOIL_EVERY = { 75, 180 }
local BOIL_LEN = { 1, 1 }

local tracks = nil

-- small-number integer hash (Playdate Lua: keep intermediates well under 2^31)
local function ih(a, b, c)
  local h = (a % 65521) * 31 + (b % 65521)
  h = (h % 65521) * 2654 + 40503
  h = (h % 65521) * 31 + (c or 0) % 65521
  h = (h % 65521) * 2654 + 40503
  return h % 65521
end
A.ih = ih

local function load()
  if tracks then return tracks end
  tracks = {}
  local path = "images/puppets/anim_tracks.json"
  local doc = playdate.file.exists(path) and json.decodeFile(path) or nil
  if doc and doc.catcherReach then A.catcherReach = doc.catcherReach end   -- glove anchors (play.lua)
  if doc and doc.tracks then
    local m = doc.meta or {}
    FPS = m.fps or FPS
    DECAY = m.shake_decay or DECAY
    if m.center_1x and m.anchor_1x then CENTER_PIV = m.anchor_1x[2] - m.center_1x[2] end
    for name, tr in pairs(doc.tracks) do
      -- precompute key start frames + flattened fields (no per-frame table lookups for defaults)
      local keys, start = {}, 0
      for i, k in ipairs(tr.keys) do
        local fx = k.fx
        keys[i] = {
          t = k.t, f = k.f, hold = k.hold or 1, s0 = start,
          sx = k.sx or 1, sy = k.sy or 1, rot = k.rot or 0, dx = k.dx or 0, dy = k.dy or 0,
          flip = k.flip and true or false, piv = (k.pivot == "center") and CENTER_PIV or 0,
          shake = fx and fx.shake, vib = fx and fx.vibrate,
        }
        start = start + (k.hold or 1)
      end
      -- O(1) sampling: frame -> key, and only the keys that carry a shake/vibrate
      local keyAt, fxKeys = {}, {}
      for _, k in ipairs(keys) do
        for f = k.s0, k.s0 + k.hold - 1 do keyAt[f] = k end
        if k.shake or k.vib then fxKeys[#fxKeys + 1] = k end
      end
      tracks[name] = { keys = keys, n = start, loop = tr.loop and true or false, boil = tr.boil and true or false,
        keyAt = keyAt, fxKeys = fxKeys }
    end
  end
  return tracks
end
A.load = load

function A.has(name) return load()[name] ~= nil end
function A.length(name)
  local tr = load()[name]
  return tr and tr.n / FPS or 0
end
function A.fps() return FPS end
--- seconds from the track start to the start of key i (e.g. the release / contact key)
function A.keyTime(name, i)
  local tr = load()[name]
  local k = tr and tr.keys[i]
  return k and k.s0 / FPS or 0
end

--- deterministic vibrate offset for frame n
function A.vibrate(seed, n, px)
  local h = ih(seed, n, 7)
  local span = px * 2 + 1
  return (h % span) - px, (floor(h / span) % span) - px
end

--- boil: per-puppet period in [every], 1–2 frame 1 px jitter at the start of each period
local boilP = {}   -- seed → { period, phase } (computed once per puppet, not every frame)
function A.boil(seed, n)
  local bp = boilP[seed]
  if not bp then
    local lo, hi = BOIL_EVERY[1], BOIL_EVERY[2]
    local period = lo + ih(seed, 11, 3) % (hi - lo + 1)
    bp = { period, ih(seed, 5, 9) % period }
    boilP[seed] = bp
  end
  local period = bp[1]
  local q = n + bp[2]
  local cyc = q // period
  if q - cyc * period >= BOIL_LEN[1] then return 0, 0 end   -- (one-frame nudges: len is 1)
  local h = ih(seed, cyc, 2)
  -- a single 1 px nudge, mostly a little "breath" upward
  if h % 3 == 0 then return ((h // 3) % 2 == 0) and 1 or -1, 0 end
  return 0, -1
end

--- Sample a track at time t (seconds since the track started).
--- seed: per-puppet integer (vibrate/boil). vib: extra vibrate px (big moments), optional.
--- Returns tbl, f, sx, sy, rot, dx, dy, flip, pivot, done — or nil if the track is unknown.
function A.sample(name, t, seed, vib)
  local tr = load()[name]
  if not tr then return nil end
  local n = floor((t > 0 and t or 0) * FPS)
  local done = false
  local total = tr.n
  local nl = n
  if tr.loop then nl = n % total
  elseif n >= total then nl = total - 1; done = true end
  local key = tr.keyAt[nl] or tr.keys[1]
  local rot, dx, dy = 0, 0, 0
  local fxKeys = tr.fxKeys
  for i = 1, #fxKeys do
    local k = fxKeys[i]
    if k.s0 > nl then break end
    -- effects that started on this key run on (across later keys) for their frame count
    if k.shake then
      local e = nl - k.s0
      if e < k.shake[2] then rot = rot + k.shake[1] * ((e % 2 == 0) and 1 or -1) * DECAY ^ e end
    end
    if k.vib then
      local e = nl - k.s0
      if e < k.vib[2] then
        local vx, vy = A.vibrate(seed, n, k.vib[1])
        dx, dy = dx + vx, dy + vy
      end
    end
  end
  if vib and vib > 0 then
    local vx, vy = A.vibrate(seed + 17, n, vib)
    dx, dy = dx + vx, dy + vy
  end
  return key.t, key.f, key.sx, key.sy, key.rot + floor(rot + 0.5), key.dx + dx, key.dy + dy, key.flip, key.piv, done
end

return A
