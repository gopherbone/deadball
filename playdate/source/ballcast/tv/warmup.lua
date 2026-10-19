-- DBN cold open: pregame warmups on the field under the stadium flyover.
--
-- Pairs playing catch along both foul lines (home on the first-base side, visitors on the
-- third-base side), the starter throwing to his catcher on the mound, the umpire crew meeting
-- at the plate, two players jogging the warning track, one man doing cartwheels in shallow
-- center (stretching, he says), and the mascot. All from the existing puppets and animatic
-- tracks; positions and timing are seeded by the game id, and every puppet is culled when
-- it's off screen (Live:offscreen) or drawn as a dot from the blimp heights (R.far).

import "ballcast/kit"
import "ballcast/anim"

local floor <const>, sin <const>, cos <const>, sqrt <const>, rad <const> = math.floor, math.sin, math.cos, math.sqrt, math.rad

BallCast = BallCast or {}
local W = {}
BallCast.TVWarmup = W
local K = BCKit

local Anim
local function yawTo(x, y, tx, ty) return math.atan(ty - y, tx - x) end

local function put(R, variant, track, tt, x, y, face, seed)
  if R.far then R:dot(x, y, 3, false, true) return end
  if R.offscreen and R:offscreen(x, y, 0) then return end
  local len = Anim.length(track) or 1
  local tn, f, sx, sy, rot, dx, dy, kflip, piv = Anim.sample(track, tt % len, seed, 0)
  if not tn then return end
  R:puppetT(variant, tn, f, x, y, 0, false, sx, sy, rot, dx, dy, piv, face, seed, kflip)
end

local function idle(R, variant, frame, x, y, face, seed, n)
  if R.far then R:dot(x, y, 3, false, true) return end
  if R.offscreen and R:offscreen(x, y, 0) then return end
  local dx, dy = Anim.boil(seed, n)
  R:puppet(variant, frame, x, y, 0, false, dx, dy, face, seed)
end

local function ball(R, ax, ay, bx, by, u, h)
  if R.far then return end
  local x, y = ax + (bx - ax) * u, ay + (by - ay) * u
  local z = 5.5 + h * 4 * u * (1 - u)
  if R.offscreen and R:offscreen(x, y, z) then return end
  R:ball(x, y, z)
end

local layout, layoutFor
local function build(seedKey)
  local L = { pairs = {} }
  local h = function(i) return K.hash01(seedKey, i) end
  -- catch pairs: one man near the line (foul side), his partner out on the grass
  for side = -1, 1, 2 do
    local variant = side > 0 and "home" or "away"
    local lx, ly = side * 0.7071, 0.7071          -- along the foul line
    local nx, ny = 0.7071, -side * 0.7071          -- toward foul territory (rotated)
    if side < 0 then nx, ny = -0.7071, -0.7071 end
    for k = 1, 3 do
      local d = 95 + k * 38 + h(side * 10 + k) * 10
      local ax, ay = lx * d + nx * 10, ly * d + ny * 10
      local gap = 46 + h(side * 20 + k) * 20
      local bx, by = lx * d - nx * gap, ly * d - ny * gap
      L.pairs[#L.pairs + 1] = { variant = variant, ax = ax, ay = ay, bx = bx, by = by,
        period = 2.4 + h(side * 30 + k) * 0.6, off = h(side * 40 + k) * 3, seed = 300 + side * 20 + k }
    end
  end
  L.jog0 = -40 + h(51) * 20
  L.cart = { x = (h(52) - 0.5) * 60, y = 205 + h(53) * 30 }
  return L
end

--- queue the warmup puppets for time t (seconds since the open began) and flush
function W.draw(R, t, meta)
  Anim = Anim or BallCast.Anim
  local key = tostring(meta and meta.home and meta.home.abbr or "") .. tostring(meta and meta.park and meta.park.id or "")
  if layoutFor ~= key then layout, layoutFor = build(key), key end
  local L = layout
  local n = floor(t * 30)
  -- catch along the lines
  for _, p in ipairs(L.pairs) do
    local u = (t + p.off) % p.period
    local half = p.period / 2
    local fromA = u < half
    local w = fromA and u or (u - half)
    local tx, ty, rx, ry = p.ax, p.ay, p.bx, p.by
    if not fromA then tx, ty, rx, ry = p.bx, p.by, p.ax, p.ay end
    local thrower, catcher = fromA and "a" or "b", fromA and "b" or "a"
    local faceT = yawTo(tx, ty, rx, ry)
    local faceC = yawTo(rx, ry, tx, ty)
    put(R, p.variant, "fielder_throw", w, tx, ty, faceT, p.seed + (fromA and 0 or 1))
    if w > half * 0.45 then put(R, p.variant, "catch", w - half * 0.45, rx, ry, faceC, p.seed + (fromA and 1 or 0))
    else idle(R, p.variant, "ready", rx, ry, faceC, p.seed + (fromA and 1 or 0), n) end
    -- the ball, from the release to the glove
    local f = (w - 0.25) / (half * 0.62)
    if f > 0 and f < 1 then ball(R, tx, ty, rx, ry, f, 7) end
  end
  -- the starter, throwing to his catcher
  local pp = 3.0
  local u = t % pp
  put(R, "home", "pitch_back", u, 0, 59, -math.pi / 2, 801)
  local rel, arr = 0.9, 1.35
  if u > rel and u < arr then ball(R, -1.6, 55, 0, -2, (u - rel) / (arr - rel), 1) end
  if u >= arr - 0.1 then put(R, "home", "catcher_receive", u - arr + 0.1, 0, -3.5, math.pi / 2, 802)
  else idle(R, "home", "catcher", 0, -3.5, math.pi / 2, 802, n) end
  -- the umpire crew, meeting at the plate
  idle(R, "ump", "ump", -5, -13, yawTo(-5, -13, 0, -15), 811, n)
  idle(R, "ump", "ump", 5, -13, yawTo(5, -13, 0, -15), 812, n)
  idle(R, "ump", "ump", 0, -19, math.pi / 2, 813, n)
  -- two jogging the warning track
  for k = 0, 1 do
    local a = rad(L.jog0 + t * 4.2 + k * 4)
    local r = 300 - k * 6
    local x, y = sin(a) * r, cos(a) * r
    put(R, "away", "run", t + k * 0.13, x, y, yawTo(x, y, sin(a + 0.1) * r, cos(a + 0.1) * r), 820 + k)
  end
  -- stretching
  local c = L.cart
  if (t % 3.2) < 1.4 then put(R, "home", "cartwheel", t % 3.2, c.x, c.y, 0, 830)
  else idle(R, "home", "stand", c.x, c.y, -math.pi / 2, 830, n) end
  -- the mascot by the third-base dugout
  put(R, "home", "mascot_wave", t, -46, 14, rad(-30), 777)
  R:finish()
end

return W
