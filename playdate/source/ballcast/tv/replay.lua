-- DBN broadcast package: INSTANT REPLAY.
--
-- After a big play, while the replay clock is held: a VHS rewind, the INSTANT REPLAY stinger,
-- the play again from other angles in slow motion, and a freeze-frame with the TELESTRATOR
-- (a hand-drawn circle around the man, an arrow along the ball, flat labels), plus the
-- home-run distance / exit-velo panel. Then the clock is released.
--
-- The world is drawn here with the scene's renderer for (beat, tau, our camera): Play is a
-- pure function of (beat, tau), so a replay is just other taus. The freeze frame is captured
-- once and the pen strokes are drawn into it incrementally, so a frozen frame costs one blit.

import "ballcast/kit"
import "ballcast/tv/art"
import "ballcast/tv/fx"
import "ballcast/tv/stats"

local gfx <const> = playdate.graphics
local floor <const>, sin <const>, cos <const>, min <const>, max <const>, sqrt <const>, abs <const> =
  math.floor, math.sin, math.cos, math.min, math.max, math.sqrt, math.abs

BallCast = BallCast or {}
local RP = {}
BallCast.TVReplay = RP
local A = BallCast.TVArt
local FX = BallCast.TVFX
local St = BallCast.TVStats
local K = BCKit

local TELE_DUR <const> = 2.6      -- seconds the freeze frame is held for the pen
local PEN_SPEED <const> = 560     -- px/s

---------------------------------------------------------------------------
-- what deserves a replay, and how (angles, freeze point, pen strokes)

local function prevPitch(tl, bi)
  local p = tl.beats[bi - 1]
  if p and p.kind == "p" and p.e.r == "X" then return p end
  return nil
end

--- tier 1 = always (in full mode); tier 2 = only when it mattered. nil = no replay.
function RP.worthy(tl, bi)
  local b = tl.beats[bi]
  if not b or not b.plan then return nil end
  local plan = b.plan
  local swing = abs((b.we or 0.5) - (b.weBefore or 0.5))
  local late = (b.pre.inn or 1) >= 7 and abs((b.pre.home or 0) - (b.pre.away or 0)) <= 2
  if b.kind == "bip" then
    if b.e.res == "HR" then return 1, "hr" end
    if plan.leap then return 1, "catch" end
    if b.big == "WHAT A CATCH" then return 1, "catch" end
    if b.walkoff then return 1, "play" end
    if b.ultra then return 1, "play" end
    if (b.big == "DOUBLE PLAY!" or b.big == "BANG-BANG!") and (swing >= 0.06 or late) then return 2, "play" end
  elseif b.kind == "p" then
    if plan.power and b.ultra then return 1, "power" end
    if b.k and (swing >= 0.07 or late or (b.pre.outs == 2 and (b.pre.b2 or b.pre.b3))) then return 2, "k" end
  elseif b.kind == "sb" and b.big == "CAUGHT STEALING" and (swing >= 0.05 or late) then
    return 2, "play"
  end
  return nil
end

-- the catch, from the infield side and up a little: the fielder and the ball coming down
local function catchCam(plan, side)
  return function(b, tau)
    local cp = plan.catchPos or { 0, 300 }
    local cx, cy = cp[1], cp[2]
    local d = max(1, sqrt(cx * cx + cy * cy))
    local ux, uy = cx / d, cy / d
    local sw = side * (14 + tau * 4)
    local ex = cx - ux * 82 + (-uy) * sw
    local ey = cy - uy * 82 + ux * sw
    local lz = plan.leap and (plan.leap.z or 10) * 0.8 or 5
    return { ex, ey, math.max(8, lz * 0.6), cx, cy, lz, 36 }
  end
end

-- a home run in profile: off to the side of its flight, high enough to see over the seats,
-- the whole arc from the plate to the wall in frame
local function arcCam(b, park, side)
  local apex = 60
  local p = b.e.path
  if p then for i = 3, #p, 3 do if p[i] > apex then apex = p[i] end end end
  local sp = math.rad(b.e.sp or 0)
  local F = BallCast.Cam.fenceAt(park or {}, b.e.sp or 0)
  local dx, dy = sin(sp), cos(sp)
  local mx, my = dx * F * 0.52, dy * F * 0.52
  local nx, ny = dy * side, -dx * side
  local D = F * 0.62
  local cam = { mx + nx * D - dx * 30, my + ny * D - dy * 30, 30 + apex * 0.3, mx, my, apex * 0.48, 74 }
  return function() return cam end
end

-- a pitch in profile: from the side (inside the foul lines), mound to plate across the screen
local function pitchCam(side)
  local cam = { side * 56, 32, 5, 0, 30, 4, 64 }
  return function() return cam end
end

local function hrFielder(plan)
  -- the outfielder who went up the wall for it (his "catch" track starts at the wall time)
  for pos, l in pairs(plan.fposes or {}) do
    for _, f in ipairs(l) do
      if f.track == "catch" and plan.wallT and abs(f.t0 - (plan.wallT - 0.15)) < 0.05 then return pos end
    end
  end
  return nil
end

local function onScreen(x, y) return x and x > -10 and x < 410 and y > 20 and y < 230 end

local function maxDist(e)
  local p = e.path
  if not p then return nil end
  local m = 0
  for i = 1, #p - 2, 3 do
    local d = p[i] * p[i] + p[i + 1] * p[i + 1]
    if d > m then m = d end
  end
  return floor(sqrt(m) + 0.5)
end

--- Build a replay script for beat bi: { shots = {...}, ... } or nil.
function RP.script(G, bi, kind)
  local tl = G.tl
  local b = tl.beats[bi]
  local plan = b.plan
  local m = G.meta
  local live = G.live3d
  local s = { bi = bi, b = b, kind = kind, shots = {}, rewind = true }
  local function shot(beat, from, to, rate, cam, freeze, tele)
    if live and type(cam) == "string" then cam = { name = cam } end
    s.shots[#s.shots + 1] = { b = beat, from = max(0, from), to = min(beat.dur, to), rate = rate, cam = cam, freeze = freeze, tele = tele }
  end
  local side = K.hash01(b.i, 81) < 0.5 and 1 or -1
  if kind == "hr" then
    local wt = plan.wallT or (b.dur * 0.5)
    local pp = prevPitch(tl, bi)
    if pp and live then
      shot(pp, pp.plan.pitch.tPlate - 0.45, pp.dur, 0.35, { name = "batterSide", opt = { side = BallCast.Play.batSide(pp.pre.bat) } })
    end
    local fpos = hrFielder(plan)
    shot(b, wt - 2.6, wt + 0.7, 0.7, live and arcCam(b, m.park, side) or "deepC", wt - 0.04, function(R, tau)
      local st = {}
      -- arrow along the whole flight, plate to wall
      local pts = {}
      for k = 0, 14 do
        local tt = wt * k / 14
        local x, y, z = BallCast.Play.ballAt(plan, tt)
        if x then local sx, sy = R:project(x, y, z); if sx then pts[#pts + 1] = sx; pts[#pts + 1] = sy end end
      end
      if #pts >= 4 then st[#st + 1] = { pts = pts, arrow = true, label = "BALL", lat = "end" } end
      if fpos then
        local x, y = BallCast.Play.fielderAt(plan, fpos, tau)
        local sx, sy = R:project(x, y, 3.5)
        if onScreen(sx, sy) then
          local who = St.last(m, G.fielderId and G.fielderId(b, fpos) or nil)
          st[#st + 1] = { circle = { sx, sy, 22 }, label = (who ~= "?" and who ~= "NIL" and (who .. ": DID NOT CATCH IT") or "DID NOT CATCH IT") }
        end
      end
      return st
    end)
    s.dist = maxDist(b.e)
    s.ev, s.la = b.e.ev, b.e.la
  elseif kind == "catch" then
    local tc = plan.leap and plan.leap.tc or plan.catchT or (b.dur * 0.6)
    local pos = plan.leap and plan.leap.pos or (plan.lastCatch and plan.lastCatch.pos)
    shot(b, tc - 2.2, tc + 0.7, 0.5, live and catchCam(plan, side) or "deepC", tc + 0.06, function(R, tau)
      local st = {}
      if pos then
        local a = BallCast.Play.ALIGN[pos]
        local cp = plan.catchPos or { BallCast.Play.fielderAt(plan, pos, tau) }
        local x, y = cp[1], cp[2]
        local ax, ay = R:project(a[1], a[2], 0)
        local bx, by = R:project(x, y, 0)
        if onScreen(ax, ay) and onScreen(bx, by) and (abs(ax - bx) + abs(ay - by)) > 30 then
          st[#st + 1] = { pts = { ax, ay, bx, by }, arrow = true, label = "HE RAN HERE", lat = "mid" }
        end
        local cx, cy = R:project(x, y, plan.leap and math.max(4, (plan.leap.z or 8) - 3) or 3.5)
        if onScreen(cx, cy) then
          local who = St.last(m, G.fielderId and G.fielderId(b, pos) or nil)
          st[#st + 1] = { circle = { cx, cy, 26 }, label = plan.leap and "WALL: " .. floor(BallCast.Cam.wallAt(G.meta.park or {}, b.e.sp or 0)) .. " FT. HE WENT UP IT." or ((who ~= "?" and (who .. ". ") or "") .. "HE CAUGHT IT.") }
        end
      end
      return st
    end)
  elseif kind == "k" or kind == "power" then
    local p = plan.pitch
    local orig = plan.cams[1] and plan.cams[1].name
    local cam = kind == "k" and { name = "batterSide", opt = { side = BallCast.Play.batSide(b.pre.bat) } } or pitchCam(side)
    if not live then cam = (orig == "pitch") and "high" or "pitch" end
    local fz = p.tPlate + 0.02
    local power = plan.power
    if power == "STOPPER" and plan.stall then fz = plan.stall[1] + 0.25
    elseif power == "WARP_PITCH" and plan.warp then fz = plan.warp + 0.04
    elseif (power == "FIREBALL" or power == "CLOUD_BALL") then fz = p.tRel + (p.tPlate - p.tRel) * 0.55 end
    shot(b, p.tRel - 0.6, p.tPlate + 0.55, kind == "k" and 0.4 or 0.35, cam, fz, function(R, tau)
      local st = {}
      local pts = {}
      for k = 0, 8 do
        local tt = p.tRel + (min(tau, p.tPlate) - p.tRel) * k / 8
        local x, y, z = BallCast.Play.ballAt(plan, tt)
        if x then local sx, sy = R:project(x, y, z); if sx then pts[#pts + 1] = sx; pts[#pts + 1] = sy end end
      end
      local bx, by = pts[#pts - 1], pts[#pts]
      local e = b.e
      if power == "WARP_PITCH" then
        -- where it was going vs where it is
        local x, y, z = BallCast.Play.ballAt(plan, tau)
        local ax, ay = R:project(x + (plan.ball[1].warpDx or 0), y, z)
        if ax and bx then
          st[#st + 1] = { circle = { ax, ay, 12 }, label = "BALL WAS HERE." }
          st[#st + 1] = { circle = { bx, by, 12 }, label = "THEN HERE." }
        end
        return st
      end
      if #pts >= 4 then st[#st + 1] = { pts = pts, arrow = true } end
      if bx then
        local lab
        if power == "STOPPER" then lab = "THE BALL STOPPED HERE. FOR 0.6 SECONDS."
        elseif power == "FIREBALL" then lab = "THAT IS FIRE."
        elseif power == "CLOUD_BALL" then lab = "BALL IS IN THERE. PROBABLY."
        else
          lab = (BallCast.Timeline.PITCH_NAMES[e.t] or e.t or "PITCH") .. ", " .. (e.v or "--") .. " MPH. "
          lab = lab .. (e.r == "C" and "HE DID NOT SWING." or "HE SWUNG. HE MISSED.")
        end
        st[#st + 1] = { circle = { bx, by, 14 }, label = lab }
      end
      return st
    end)
  else
    -- a play in the field (DP, bang-bang, caught stealing, walk-off): wide, slow, circle the bag
    local a0, a1 = 0.2, b.dur - 0.6
    if plan.slo then a0, a1 = plan.slo[1] - 0.8, plan.slo[2] + 0.4 end
    local fz = plan.slo and (plan.slo[1] + plan.slo[2]) / 2 or nil
    shot(b, a0, a1, 0.45, live and { name = (b.kind == "sb") and "runner" or "dugout", opt = { side = side } } or "high", fz, function(R, tau)
      local st = {}
      for _, sg in ipairs(plan.ball) do
        if sg.throw and sg.t0 <= tau + 0.2 and sg.t1 >= a0 then
          local ax, ay = R:project(sg.ax, sg.ay, sg.az or 4)
          local bx, by = R:project(sg.bx, sg.by, sg.bz or 4)
          if ax and bx then st[#st + 1] = { pts = { ax, ay, bx, by }, arrow = true, label = "THROW", lat = "mid" } end
        end
      end
      local rx, ry = BallCast.Play.leadRunner(plan, tau)
      if rx then
        local sx, sy = R:project(rx, ry, 3)
        if sx then st[#st + 1] = { circle = { sx, sy, 20 }, label = b.kind == "sb" and "OUT." or "RUNNER" } end
      end
      return st
    end)
  end
  if #s.shots == 0 then return nil end
  return s
end

---------------------------------------------------------------------------
-- the pen

local function strokePoints(st)
  if st.circle then
    local cx, cy, r = st.circle[1], st.circle[2], st.circle[3]
    local pts = {}
    local n = 30
    local seed = floor(cx * 7 + cy * 13)
    for i = 0, n do
      local a = -1.9 + i / n * 2 * math.pi * 1.12
      local wob = 1 + (K.hash01(seed, i) - 0.5) * 0.12
      local rr = r * wob * (1 + i / n * 0.15)
      pts[#pts + 1] = cx + cos(a) * rr * 1.3
      pts[#pts + 1] = cy + sin(a) * rr * 0.85
    end
    return pts
  end
  return st.pts
end

-- keep a polyline's on-screen part: drop points before the first one in view (keeping one
-- just outside so the line still enters from the edge) and cap its length
local function trim(p)
  local function inside(i) return p[i] > -10 and p[i] < 410 and p[i + 1] > -10 and p[i + 1] < 250 end
  local first = nil
  for i = 1, #p - 1, 2 do if inside(i) then first = i break end end
  if not first then return {} end
  local out = {}
  local s = max(1, first - 2)
  for i = s, #p - 1, 2 do out[#out + 1] = p[i]; out[#out + 1] = p[i + 1] end
  if s < first then
    -- pull the outside point in to the screen edge so no pen time is spent off-screen
    local x0, y0, x1, y1 = out[1], out[2], out[3], out[4]
    local tx = 1
    if x0 < -10 then tx = min(tx, (x1 + 10) / max(0.001, x1 - x0)) end
    if x0 > 410 then tx = min(tx, (410 - x1) / max(0.001, x0 - x1)) end
    if y0 < -10 then tx = min(tx, (y1 + 10) / max(0.001, y1 - y0)) end
    if y0 > 250 then tx = min(tx, (250 - y1) / max(0.001, y0 - y1)) end
    out[1], out[2] = x1 + (x0 - x1) * tx, y1 + (y0 - y1) * tx
  end
  return out
end

local function prep(strokes)
  local total = 0
  for i = #strokes, 1, -1 do
    local st = strokes[i]
    if not st.circle then st.pts = trim(st.pts); if #st.pts < 4 then table.remove(strokes, i) end end
  end
  for _, st in ipairs(strokes) do
    st.p = strokePoints(st)
    local L = 0
    st.cum = { 0 }
    for i = 3, #st.p, 2 do
      L = L + sqrt((st.p[i] - st.p[i - 2]) ^ 2 + (st.p[i + 1] - st.p[i - 1]) ^ 2)
      st.cum[#st.cum + 1] = L
    end
    st.len = L
    st.start = total
    total = total + L + 90   -- (a beat between strokes, for the label)
    st.drawn = 0
  end
  return total
end

local function pointAt(st, d)
  local c = st.cum
  for i = 2, #c do
    if c[i] >= d then
      local f = (d - c[i - 1]) / max(0.001, c[i] - c[i - 1])
      local j = (i - 2) * 2 + 1
      return st.p[j] + (st.p[j + 2] - st.p[j]) * f, st.p[j + 1] + (st.p[j + 3] - st.p[j + 1]) * f
    end
  end
  return st.p[#st.p - 1], st.p[#st.p]
end

-- draw the piece of a stroke between lengths a and b (white, black outline), into the context
local function piece(st, a, b)
  if b <= a then return end
  local step = 6
  local px, py = pointAt(st, max(0, a - 4))
  gfx.setLineCapStyle(gfx.kLineCapStyleRound)
  local d = a
  local segs = {}
  segs[1], segs[2] = px, py
  while d < b do
    d = min(b, d + step)
    local x, y = pointAt(st, d)
    segs[#segs + 1], segs[#segs + 2] = x, y
  end
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(6)
  for i = 1, #segs - 2, 2 do gfx.drawLine(segs[i], segs[i + 1], segs[i + 2], segs[i + 3]) end
  -- white over it, reaching back into the previous piece so the joint stays clean
  local bx, by = pointAt(st, max(0, a - 7))
  segs[1], segs[2] = bx, by
  gfx.setColor(gfx.kColorWhite)
  gfx.setLineWidth(3)
  for i = 1, #segs - 2, 2 do gfx.drawLine(segs[i], segs[i + 1], segs[i + 2], segs[i + 3]) end
  gfx.setLineWidth(1)
  gfx.setLineCapStyle(gfx.kLineCapStyleButt)
  gfx.setColor(gfx.kColorBlack)
end

local function arrowHead(st)
  local n = #st.p
  local x1, y1 = st.p[n - 1], st.p[n]
  local x0, y0 = pointAt(st, max(0, st.len - 14))
  local dx, dy = x1 - x0, y1 - y0
  local l = max(0.001, sqrt(dx * dx + dy * dy))
  dx, dy = dx / l, dy / l
  local s = 12
  local ax, ay = x1 - dx * s - dy * s * 0.6, y1 - dy * s + dx * s * 0.6
  local bx, by = x1 - dx * s + dy * s * 0.6, y1 - dy * s - dx * s * 0.6
  gfx.setLineCapStyle(gfx.kLineCapStyleRound)
  for pass = 1, 2 do
    gfx.setColor(pass == 1 and gfx.kColorBlack or gfx.kColorWhite)
    gfx.setLineWidth(pass == 1 and 6 or 3)
    gfx.drawLine(x1, y1, ax, ay)
    gfx.drawLine(x1, y1, bx, by)
  end
  gfx.setLineWidth(1)
  gfx.setLineCapStyle(gfx.kLineCapStyleButt)
  gfx.setColor(gfx.kColorBlack)
end

local function labelImg(text)
  local f = K.fonts.bold
  local w = min(260, f:getTextWidth(text)) + 10
  local lines = K.wrap(f, text, 250)
  local h = #lines * 14 + 6
  local img = gfx.image.new(w + 3, h + 3, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(3, 3, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 0, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(0, 0, w, h)
  for i, l in ipairs(lines) do f:drawText(l, 5, 3 + (i - 1) * 14) end
  gfx.popContext()
  return img
end

local function placeLabel(st)
  local w, h = st.img:getSize()
  local function ok(x, y) return x >= 4 and x + w <= 396 and y >= 34 and y + h <= 210 end
  if st.circle then
    -- beside the circle (right, left), else above or below it: never over it
    local cx, cy, r = st.circle[1], st.circle[2], st.circle[3]
    local rx, ry = r * 1.3 + 6, r * 0.85 + 6
    local cands = { { cx + rx, cy - ry - 4 }, { cx - rx - w, cy - ry - 4 }, { cx - w / 2, cy - ry - h }, { cx - w / 2, cy + ry } }
    for _, c in ipairs(cands) do if ok(c[1], c[2]) then return floor(c[1]), floor(c[2]) end end
    local c = cands[3]
    return K.clamp(floor(c[1]), 4, 396 - w), K.clamp(floor(c[2]), 34, 210 - h)
  end
  local x, y
  if st.lat == "mid" then
    x, y = pointAt(st, st.len / 2); x, y = x + 10, y - 22
  else
    x, y = st.p[#st.p - 1] + 8, st.p[#st.p] - 26
  end
  if x + w > 396 then x = 396 - w end
  return K.clamp(floor(x), 4, 396 - w), K.clamp(floor(y), 34, 210 - h)
end

--- advance the pen to time u (s since the freeze), drawing into the context (the freeze
--- image). Returns true when a stroke or label started this call (for the squeak / tick).
function RP.pen(strokes, u)
  local d = u * PEN_SPEED
  local started = false
  for _, st in ipairs(strokes) do
    local want = K.clamp(d - st.start, 0, st.len)
    if want > st.drawn then
      if st.drawn == 0 then started = true end
      piece(st, st.drawn, want)
      st.drawn = want
      if want >= st.len and st.arrow and not st.headDone then arrowHead(st); st.headDone = true end
    end
    if want >= st.len and st.label and not st.labDone then
      st.img = st.img or labelImg(st.label)
      local x, y = placeLabel(st)
      st.img:draw(x, y)
      local lw, lh = st.img:getSize()
      st.lr = { x, y, lw, lh }
      st.labDone = true
      started = true
    end
  end
  return started
end

function RP.prep(strokes) return prep(strokes) end

--- where to put a w x h panel so it covers the least of the pen's work (corners, then centre)
function RP.clearSpot(strokes, w, h)
  local cands = { { 392 - w, 214 - h }, { 8, 214 - h }, { 392 - w, 32 }, { 8, 32 }, { 200 - w // 2, 214 - h } }
  local best, bs = cands[1], 1e9
  for _, c in ipairs(cands) do
    local x0, y0, x1, y1 = c[1], c[2], c[1] + w, c[2] + h
    local s = 0
    for _, st in ipairs(strokes) do
      if st.len and st.len > 0 then
        for d = 0, st.len, 8 do
          local px, py = pointAt(st, d)
          if px >= x0 and px <= x1 and py >= y0 and py <= y1 then s = s + 1 end
        end
      end
      local r = st.lr
      if r and r[1] < x1 and x0 < r[1] + r[3] and r[2] < y1 and y0 < r[2] + r[4] then s = s + 40 end
    end
    if s < bs then best, bs = c, s end
  end
  return best[1], best[2]
end

---------------------------------------------------------------------------
-- home-run distance / exit-velo panel (prerendered once per replay)

function RP.distPanel(s)
  if not s.dist then return nil end
  local img = gfx.image.new(220, 64, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(4, 4, 216, 60)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 0, 216, 60)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 92, 60)
  local d = A.text("waBig", tostring(s.dist), "wa")
  local dw = d:getSize()
  d:draw(46 - dw // 2, 6)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  K.fonts.bold:drawText("FEET", 30, 38)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  K.fonts.tiny:drawText("EXIT VELOCITY", 100, 6)
  K.fonts.bold:drawText((s.ev or "--") .. " MPH", 100, 16)
  K.fonts.tiny:drawText("LAUNCH ANGLE", 100, 34)
  K.fonts.bold:drawText((s.la or "--") .. " DEG", 100, 44)
  gfx.popContext()
  return img
end

RP.TELE_DUR = TELE_DUR

return RP
