-- BallCast "juice": 1-bit impact effects for ball contact, catches, bounces, the wall, throws,
-- rolling balls and slides. Owned by the sprite agent.
--
-- Everything is a pure function of (beat, tau): the events are derived once per plan from its
-- ball segments / catches / runners (plan.juice) and each frame just draws whichever are live,
-- so crank-scrubbing is exact and nothing allocates per frame.
--
--   Juice.ground(R, b, tau)   before the billboard flush: dust puffs, skids, slide plumes (under puppets)
--   Juice.over(R, b, tau)     after the flush: bat-crack flash + starburst, glove pops, wall dent,
--                             throw streaks, thwacks, the spinning seam on rolling balls
--   Juice.kick(plan, tau)     camera kick (px) for hard contact / wall hits
-- Game.settings.reduceMotion: no flashes, rings or camera kicks (dust and streaks stay).

BallCast = BallCast or {}
if BallCast.Juice then return end

import "ballcast/kit"

local gfx <const> = playdate.graphics
local floor <const>, sqrt <const>, sin <const>, cos <const>, min <const>, max <const>, abs <const> =
  math.floor, math.sqrt, math.sin, math.cos, math.min, math.max, math.abs
local PI <const> = math.pi
local FPS <const> = 30
local BAYER <const> = gfx.image.kDitherTypeBayer4x4
local K = BCKit

local J = {}
BallCast.Juice = J

local function reduced() return Game and Game.settings and Game.settings.reduceMotion end
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

---------------------------------------------------------------------------
-- events (built once per plan)

local function ev(list, k, t0, t1, x, y, z, s)
  local e = { k = k, t0 = t0, t1 = t1, x = x, y = y, z = z or 0, s = s or 1 }
  list[#list + 1] = e
  return e
end

local function build(b)
  local plan = b.plan
  local Play = BallCast.Play
  local ballAt = Play.ballAt
  local L = {}
  local big = b.big and 1.35 or 1
  local segs = plan.ball or {}
  local pitch = plan.pitch
  for i = 1, #segs do
    local s = segs[i]
    local nx = segs[i + 1]
    if s.kind == "path" and s.t0 == 0 and b.kind == "bip" and s.pts then
      -- bat on ball: strength from exit velocity
      local evm = (b.e and b.e.ev) or 85
      local st = clamp((evm - 55) / 50, 0.35, 1.25) * big
      local c = ev(L, "crack", 0, 0.14, s.pts[1], s.pts[2], s.pts[3], st)
      c.kick = st >= 0.85
    elseif s.kind == "line" and pitch and s.t0 == pitch.tPlate and not s.throw then
      if s.t1 - s.t0 < 0.1 then ev(L, "crack", s.t0, s.t0 + 0.1, s.ax, s.ay, s.az, 0.22)        -- foul tip
      elseif (s.arc or 0) >= 20 then ev(L, "crack", s.t0, s.t0 + 0.12, s.ax, s.ay, s.az, 0.4) -- foul
      end
    end
    if s.throw then
      local th = ev(L, "throw", s.t0, s.t1, 0, 0, 0, 1); th.seg, th.b = s, plan
      if nx and nx.kind == "hold" and abs(nx.t0 - s.t1) < 0.01 then
        ev(L, "pop", s.t1, s.t1 + 0.22, s.bx, s.by, s.bz, 0.55)                        -- thwack in the glove
      end
    end
    if s.kind == "roll" then
      local ro = ev(L, "roll", s.t0, s.t1, 0, 0, 0, 1); ro.seg, ro.b = s, plan
      local hops = s.hops or 3
      local landing = i > 1 and segs[i - 1].kind == "path"
      for k = 0, hops - 1 do
        local u = k / hops
        local t = s.t0 + (s.t1 - s.t0) * u
        local x, y = ballAt(plan, t + 0.001)
        if x then ev(L, "dust", t, t + 0.5, x, y, 0, ((k == 0 and landing) and 1.1 or 0.75) * (1 - u * 0.6)) end
      end
      if s.wall then
        local x, y = s.bx, s.by
        local w = ev(L, "wall", s.t1 - 0.25, s.t1 + 0.1, x, y, 2.5, 0.7)
        w.kick = true
      end
    elseif s.kind == "line" and not s.throw and (s.bz or 1) <= 0.5 and s.t1 > s.t0 + 0.1 then
      ev(L, "dust", s.t1, s.t1 + 0.45, s.bx, s.by, 0, 0.7)                                     -- a bounce
    end
  end
  -- catches: the glove pop (dives: dust cloud + skid)
  for i = 1, #(plan.catches or {}) do
    local c = plan.catches[i]
    local x, y, z = ballAt(plan, c.ct + 0.001)
    if x then
      local st = (c.catch == "dive" and 1.15 or c.catch == "high" and 0.85 or 0.65) * big
      ev(L, "pop", c.ct, c.ct + 0.24, x, y, z, st)
      if c.catch == "dive" then
        local d = sqrt(x * x + y * y)
        local e = ev(L, "skid", c.ct - 0.05, c.ct + 0.7, x, y, 0, 1.1)
        e.dx, e.dy = -x / max(d, 1), -y / max(d, 1)          -- skids back toward the plate side
      elseif c.catch == "low" then
        ev(L, "dust", c.ct, c.ct + 0.4, x, y, 0, 0.6)
      end
    end
  end
  if plan.receive then
    -- the mitt pop where and when the ball reaches the glove (end of the 0.06 s plate→mitt segment)
    local tg = plan.receive + 0.06
    local x, y, z = ballAt(plan, tg + 0.001)
    if x then ev(L, "pop", tg, tg + 0.2, x, y, z, plan.reach and 0.6 or 0.45) end
  end
  -- the home run clears the wall: dent flash + puff on the fence
  if plan.wallT then
    local x, y, z = ballAt(plan, plan.wallT)
    if x then local w = ev(L, "wall", plan.wallT, plan.wallT + 0.35, x, y, z, 1 * big); w.kick = true end
  end
  -- slides: the stolen-base slide, and runners who stop short (thrown out) and hit the dirt
  for i = 1, #(plan.runners or {}) do
    local r = plan.runners[i]
    local t0
    if plan.slide and plan.slide.id == r.id then t0 = plan.slide.t
    elseif r.to == -1 and r.role ~= "batter" then t0 = r.t1 end
    if t0 then
      local e = ev(L, "slide", t0, t0 + 0.95, 0, 0, 0, big)
      e.r = r
      local tx, ty = Play.basePos(min(r.target, 4))
      e.bx, e.by = tx, ty
    end
  end
  table.sort(L, function(a, c) return a.t0 < c.t0 end)
  local md, kick = 0, false
  for i = 1, #L do
    local d = L[i].t1 - L[i].t0
    if d > md then md = d end
    if L[i].kick then kick = true end
  end
  L.maxDur, L.hasKick = md, kick
  return L
end

local function events(b)
  local plan = b.plan
  local L = plan.juice
  if not L then L = build(b); plan.juice = L end
  return L
end
J.events = events

-- the live events at tau, found once per frame and shared by ground/over/kick:
-- binary search for the first event that could still be running (t0 >= tau - maxDur),
-- then walk while t0 <= tau. Reuses one array: no allocation.
local act, nAct, actPlan, actTau = {}, 0, nil, nil
local function active(b, tau)
  local plan = b.plan
  if plan == actPlan and tau == actTau then return act, nAct end
  local L = events(b)
  local lo, hi = 1, #L + 1
  local from = tau - (L.maxDur or 0) - 0.001
  while lo < hi do
    local mid = (lo + hi) // 2
    if L[mid].t0 < from then lo = mid + 1 else hi = mid end
  end
  local n = 0
  for i = lo, #L do
    local e = L[i]
    if e.t0 > tau + 0.001 then break end
    if tau <= e.t1 then n = n + 1; act[n] = e end
  end
  for i = n + 1, nAct do act[i] = nil end
  nAct, actPlan, actTau = n, plan, tau
  return act, n
end

---------------------------------------------------------------------------
-- drawing helpers (screen space, no allocation)

local function ppfAt(R, x, y, z)
  local sx, sy, d = R:project(x, y, z)
  if not sx then return nil end
  return sx, sy, R:ppf(d)
end

-- dust puffs are blitted from images prerendered in the loader (J.preload): dithered ellipses
-- are the costly kind of draw on the device. PUFF_R = half-widths (px), PUFF_P = fade stages.
local PUFF_R <const> = { 2, 3, 4, 6, 8, 11, 15, 20, 27, 36 }
local PUFF_P <const> = 5
local puffImg = nil     -- [ri][pi] → image
local function makePuff(rw, p)
  local rh = max(1, floor(rw * 0.42 + 0.5))
  local img = gfx.image.new(rw * 2 + 1, rh * 2 + 1, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorWhite)
  gfx.setDitherPattern(0.25 + 0.65 * p, BAYER)
  gfx.fillEllipseInRect(0, 0, rw * 2, rh * 2)
  gfx.setColor(gfx.kColorBlack)
  gfx.setDitherPattern(0.55 + 0.45 * p, BAYER)
  gfx.drawEllipseInRect(0, 0, rw * 2, rh * 2)
  gfx.popContext()
  return img
end
--- build the puff images (call from the loader; Y() between rows keeps slices short)
function J.preload(Y)
  if puffImg then return end
  local t = {}
  for ri = 1, #PUFF_R do
    local row = {}
    for pi = 1, PUFF_P do row[pi] = makePuff(PUFF_R[ri], (pi - 1) / (PUFF_P - 1)) end
    t[ri] = row
    if Y then Y() end
  end
  puffImg = t
end
local function puff(cx, cy, rw, p)
  if rw < 1.5 then return end
  if not puffImg then J.preload() end
  local ri = 1
  while ri < #PUFF_R and PUFF_R[ri + 1] <= rw do ri = ri + 1 end
  local pi = floor(p * (PUFF_P - 1) + 0.5) + 1
  if pi < 1 then pi = 1 elseif pi > PUFF_P then pi = PUFF_P end
  local img = puffImg[ri][pi]
  local w, h = img:getSize()
  img:draw(floor(cx - w * 0.5), floor(cy - h * 0.5))
end

-- starburst directions precomputed for n spokes at 16 rotation steps (no trig per frame)
local SPOKES = {}
local function spokes(n, rot)
  local q = floor(rot / (2 * PI) * 16 + 0.5) % 16
  local byN = SPOKES[n]
  if not byN then byN = {}; SPOKES[n] = byN end
  local t = byN[q]
  if not t then
    t = {}
    for i = 0, n - 1 do
      local a = q / 16 * 2 * PI + i * 2 * PI / n
      t[i * 2 + 1], t[i * 2 + 2] = cos(a), sin(a)
    end
    byN[q] = t
  end
  return t
end
local function starburst(cx, cy, r0, r1, n, rot, w)
  local t = spokes(n, rot)
  if w and w ~= 1 then gfx.setLineWidth(w) end
  for i = 0, n - 1 do
    local c, s = t[i * 2 + 1], t[i * 2 + 2]
    gfx.drawLine(cx + c * r0, cy + s * r0, cx + c * r1, cy + s * r1)
  end
  if w and w ~= 1 then gfx.setLineWidth(1) end
end

---------------------------------------------------------------------------
-- ground pass (under the puppets)

local function groundDust(R, e, tau)
  local p = (tau - e.t0) / (e.t1 - e.t0)
  local sx, sy, k = ppfAt(R, e.x, e.y, 0)
  if not sx then return end
  local rw = clamp((0.9 + 2.6 * p) * e.s * k, 1.5, 36)
  puff(sx, sy, rw, p)
  -- a few kicked-up specks
  if p < 0.6 and rw > 4 then
    gfx.setColor(gfx.kColorBlack)
    for i = 0, 3 do
      local a = i * 1.7 + e.t0 * 7
      local rr = rw * (0.6 + p)
      gfx.fillRect(floor(sx + cos(a) * rr), floor(sy - abs(sin(a)) * rr * 0.8 - p * 4), 1, 1)
    end
  end
end

local function groundSkid(R, e, tau)
  local p = (tau - e.t0) / (e.t1 - e.t0)
  local len = 5 * clamp((tau - e.t0) / 0.25, 0, 1)
  local ax, ay, k = ppfAt(R, e.x, e.y, 0)
  local bx, by = R:project(e.x + e.dx * len, e.y + e.dy * len, 0)
  if not ax or not bx then return end
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(ax, ay, bx, by)
  if k > 3 then gfx.drawLine(ax, ay + 1, bx, by + 1) end
  for j = 0, 2 do
    local pj = clamp(p * 1.4 - j * 0.15, 0, 1)
    if pj > 0 and pj < 1 then
      local qx, qy, qk = ppfAt(R, e.x + e.dx * (j * 1.6), e.y + e.dy * (j * 1.6), 0)
      if qx then puff(qx, qy, clamp((1.2 + 2.4 * pj) * e.s * qk, 1.5, 30), pj) end
    end
  end
end

local function groundSlide(R, e, tau)
  local Play = BallCast.Play
  local r = e.r
  local a = tau - e.t0
  local p = a / (e.t1 - e.t0)
  local x, y = Play.runnerPos(r, tau)
  local x0, y0 = Play.runnerPos(r, e.t0)
  local dx, dy = e.bx - x0, e.by - y0
  local dl = sqrt(dx * dx + dy * dy)
  if dl < 0.01 then dx, dy, dl = 1, 0, 1 end
  dx, dy = dx / dl, dy / dl
  -- skid mark: the last ~5 ft behind him, only while he's moving through the dirt
  local sx0, sy0 = x0, y0
  local gx, gy = x - x0, y - y0
  if gx * gx + gy * gy > 25 then sx0, sy0 = x - dx * 5, y - dy * 5 end
  local ax, ay, k = ppfAt(R, sx0, sy0, 0)
  local bx, by = R:project(x, y, 0)
  if ax and bx and a > 0.12 and a < 0.6 then
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(ax, ay, bx, by)
    if k > 3 then gfx.drawLine(ax, ay + 1, bx, by + 1) end
  end
  -- the plume trailing behind him: staggered puffs
  for j = 0, 4 do
    local pj = (a - 0.1 - j * 0.06) / 0.55
    if pj > 0 and pj < 1 then
      local px, py, pk = ppfAt(R, x - dx * (1.2 + j * 1.5), y - dy * (1.2 + j * 1.5), 0)
      if px then puff(px, py - pj * 3, clamp((1.4 + 2.8 * pj) * e.s * pk * (1 - j * 0.12), 1.5, 34), pj) end
    end
  end
  -- the burst at the bag as he gets there
  local pb = (a - 0.42) / 0.45
  if pb > 0 and pb < 1 then
    local qx, qy, qk = ppfAt(R, e.bx, e.by, 0)
    if qx then puff(qx, qy, clamp((2.2 + 3.6 * pb) * e.s * qk, 2, 40), pb) end
  end
end

local clock = playdate.getElapsedTime
local cost = 0
function J.ground(R, b, tau)
  if R.far then return end            -- blimp: puppets are dots, skip the juice
  local t0 = clock()
  local A, n = active(b, tau)
  for i = 1, n do
    local e = A[i]
    local k = e.k
    if k == "dust" then groundDust(R, e, tau)
    elseif k == "skid" then groundSkid(R, e, tau)
    elseif k == "slide" then groundSlide(R, e, tau)
    end
  end
  if n > 0 then gfx.setColor(gfx.kColorBlack) end
  cost = cost + (clock() - t0)
end

---------------------------------------------------------------------------
-- over pass (after the billboards)

local function overCrack(R, e, tau, red)
  local a = tau - e.t0
  local f = floor(a * FPS)
  local sx, sy, k = ppfAt(R, e.x, e.y, e.z)
  if not sx then return end
  local s = e.s
  local base = clamp(k * 0.9, 3, 14) * (0.6 + s * 0.6)
  if f == 0 and not red then
    -- the flash: a hard black disc with a white core and white spikes (reads on any uniform)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillCircleAtPoint(sx, sy, base + 3)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(sx, sy, base * 0.55)
    starburst(sx, sy, base * 0.5, base + 6 + s * 4, 4, 0.785, 2)
  elseif f == 1 or f == 2 then
    local r = base * (1 + f * 0.7)
    if not red then
      gfx.setColor(gfx.kColorWhite)
      gfx.setLineWidth(2)
      gfx.drawCircleAtPoint(sx, sy, r)
      gfx.setLineWidth(1)
    end
    gfx.setColor(gfx.kColorBlack)
    starburst(sx, sy, r * 0.9, r * (1.5 + s * 0.6), s > 0.8 and 10 or 7, f * 0.3 + e.t0 * 3, s > 0.9 and 2 or 1)
  elseif f == 3 and s > 0.7 then
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0.5, BAYER)
    starburst(sx, sy, base * 2.6, base * 3.4, 10, 0.15 + e.t0 * 3, 1)
  end
  gfx.setColor(gfx.kColorBlack)
end

local function overPop(R, e, tau, red)
  local a = tau - e.t0
  local f = floor(a * FPS)
  local sx, sy, k = ppfAt(R, e.x, e.y, e.z)
  if not sx then return end
  local base = clamp(k * 0.55, 2, 10) * (0.7 + e.s * 0.5)
  if f <= 1 then
    gfx.setColor(gfx.kColorWhite)
    starburst(sx, sy, base * (0.9 + f * 0.6), base * (1.8 + f * 0.8), 6, 0.4 + f * 0.25, 3)
    gfx.setColor(gfx.kColorBlack)
    starburst(sx, sy, base * (0.9 + f * 0.6), base * (1.8 + f * 0.8), 6, 0.4 + f * 0.25, 1)
  elseif not red then
    -- the puff ring: expands and blinks out (a plain circle: no dither on the device)
    local p = (a - 2 / FPS) / max(0.05, e.t1 - e.t0 - 2 / FPS)
    if p < 0.5 or f % 2 == 0 then
      gfx.setColor(gfx.kColorBlack)
      gfx.drawCircleAtPoint(sx, sy, base * (1.6 + p * 1.8))
    end
  end
  gfx.setColor(gfx.kColorBlack)
end

local function overWall(R, e, tau, red)
  local a = tau - e.t0
  local f = floor(a * FPS)
  local sx, sy, k = ppfAt(R, e.x, e.y, e.z)
  if not sx then return end
  local base = clamp(k * 1.2, 3, 18) * e.s
  if f < 2 and not red then
    -- the dent flash: a white star punched into the wall
    gfx.setColor(gfx.kColorWhite)
    starburst(sx, sy, 0, base * 1.6, 8, 0.2, 3)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawCircleAtPoint(sx, sy, base * 0.5)
  end
  local p = a / (e.t1 - e.t0)
  -- dust off the padding (prerendered puff)
  puff(sx, sy, base * (0.8 + p * 1.6), p)
end

local function overThrow(R, e, tau)
  local Play = BallCast.Play
  if tau - e.t0 < 0.03 or e.t1 - tau < 0.02 then return end
  local x, y, z = Play.ballAt(e.b, tau)
  local px, py, pz = Play.ballAt(e.b, tau - 0.07)
  if not x or not px then return end
  local ax, ay = R:project(x, y, z)
  local bx, by = R:project(px, py, pz)
  if not ax or not bx then return end
  local dx, dy = ax - bx, ay - by
  local l = sqrt(dx * dx + dy * dy)
  if l < 4 then return end
  local nx, ny = -dy / l * 1.5, dx / l * 1.5
  -- two speed lines behind the ball, the far ends dithered off
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(ax - dx * 0.25 + nx, ay - dy * 0.25 + ny, bx + nx, by + ny)
  gfx.drawLine(ax - dx * 0.25 - nx, ay - dy * 0.25 - ny, bx - nx, by - ny)
  -- broken tails (a short gap, then a dash) instead of dithered lines
  gfx.drawLine(bx - dx * 0.2 + nx, by - dy * 0.2 + ny, bx - dx * 0.5 + nx, by - dy * 0.5 + ny)
  gfx.drawLine(bx - dx * 0.2 - nx, by - dy * 0.2 - ny, bx - dx * 0.5 - nx, by - dy * 0.5 - ny)
end

local function overRoll(R, e, tau)
  local s = e.seg
  local Play = BallCast.Play
  local x, y, z = Play.ballAt(e.b, tau)
  if not x then return end
  local sx, sy, d = R:project(x, y, z)
  if not sx then return end
  local rb = clamp(R:ppf(d) * 0.6, 1.5, 7)
  if rb < 2.5 then return end
  -- the seam dot turns with the distance rolled (fast, then slowing)
  local u = (tau - s.t0) / (s.t1 - s.t0)
  local e2 = 1 - (1 - u) * (1 - u)
  local dist = sqrt((s.bx - s.ax) ^ 2 + (s.by - s.ay) ^ 2) * e2
  local ang = dist / 0.24 * (s.bx >= s.ax and 1 or -1)
  -- a deflected / tumbling ball wobbles
  local wob = (s.hops or 0) >= 3 and sin(tau * 40) * rb * 0.25 or 0
  gfx.setColor(gfx.kColorBlack)
  local r = rb * 0.55
  gfx.fillRect(floor(sx + cos(ang) * r + wob), floor(sy + sin(ang) * r), 1, rb >= 4 and 2 or 1)
  gfx.fillRect(floor(sx - cos(ang) * r + wob), floor(sy - sin(ang) * r), 1, 1)
end

-- per-camera cost log (device tour): [bcjuice] cost cam=X avg Y ms over N frames
-- (accumulated per camera, printed ONCE at scene exit by J.report: a print inside the world
-- pass blocks on the device's serial console and showed up as 35-45 ms world spikes)
local camAcc = {}
local function logCost()
  local sc = BallCast.scene
  local cam = sc and sc.curCam or "?"
  local a = camAcc[cam]
  if not a then a = { 0, 0 }; camAcc[cam] = a end
  a[1], a[2] = a[1] + cost, a[2] + 1
  cost = 0
end
function J.report()
  for cam, a in pairs(camAcc) do
    if a[2] > 0 then print(string.format("[bcjuice] cost cam=%s avg %.2f ms over %d frames", cam, a[1] / a[2] * 1000, a[2])) end
  end
  camAcc = {}
end

function J.over(R, b, tau)
  if R.far then return end
  local t0 = clock()
  local A, n = active(b, tau)
  if n > 0 then
    local red = reduced()
    for i = 1, n do
      local e = A[i]
      local k = e.k
      if k == "crack" then overCrack(R, e, tau, red)
      elseif k == "pop" then overPop(R, e, tau, red)
      elseif k == "wall" then overWall(R, e, tau, red)
      elseif k == "throw" then overThrow(R, e, tau)
      elseif k == "roll" then overRoll(R, e, tau)
      end
    end
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(1)
  end
  cost = cost + (clock() - t0)
  logCost()
end

-- camera kick: a few hard frames, deterministic (no RNG), none with reduceMotion
local KICK <const> = { 3, -2, 2, -1, 1, 0 }
function J.kick(b, tau)
  local L = b.plan.juice
  if L and not L.hasKick then return 0, 0 end      -- most plays: nothing to scan
  if reduced() then return 0, 0 end
  local A, n = active(b, tau)
  for i = 1, n do
    local e = A[i]
    if e.kick then
      local f = floor((tau - e.t0) * FPS)
      if f >= 0 and f < #KICK then
        local a = KICK[f + 1] * clamp(e.s, 0.6, 1.4)
        return floor(a + 0.5), floor(-a * 0.5 + 0.5)
      end
    end
  end
  return 0, 0
end

return J
