-- BallCast play planner + world renderer.
--
-- Play.plan(beat, tl) turns one beat into an animation script (ball segments, fielder and
-- runner moves, camera cuts, slo-mo windows, sounds). Play.drawWorld(view, beat, tau)
-- draws the field for a beat at local time tau. Everything is a pure function of
-- (beat, tau), so scrubbing anywhere is exact.

import "ballcast/kit"
import "ballcast/cam"
import "ballcast/puppets"
import "ballcast/anim"
import "ballcast/tags"
import "ballcast/juice"

local gfx <const> = playdate.graphics
local floor <const>, sqrt <const>, abs <const>, min <const>, max <const> = math.floor, math.sqrt, math.abs, math.min, math.max
local sin <const>, cos <const>, exp <const>, log <const> = math.sin, math.cos, math.exp, math.log

BallCast = BallCast or {}
local Play = {}
BallCast.Play = Play
local Cam = BallCast.Cam
local Pup = BallCast.Puppets
local Anim = BallCast.Anim
local K = BCKit
local project = Cam.project

local DUR = function() return BallCast.Timeline.DUR end

local MPH <const> = 1.46667
local RUN <const> = 28        -- ft/s, runners
local TROT <const> = 36       -- ft/s, home run trot (TV-compressed)
local THROW <const> = 115     -- ft/s
local FSPEED <const> = 27     -- ft/s, fielders

local BASES = Cam.BASES       -- 1=home 2=1B 3=2B 4=3B
local function basePos(n)     -- n: 0/4 = home, 1..3
  local b = BASES[(n % 4) + 1]
  return b[1], b[2]
end
Play.basePos = basePos

local polar = Cam.polar
local ALIGN = {}
do
  local function set(pos, d, s) local x, y = polar(d, s); ALIGN[pos] = { x, y } end
  ALIGN.P = { 0, 59 }
  ALIGN.C = { 0, -3.5 }
  set("1B", 108, 36); set("2B", 150, 13); set("SS", 150, -14); set("3B", 106, -36)
  set("LF", 285, -27); set("CF", 315, 0); set("RF", 285, 27)
end
Play.ALIGN = ALIGN
local POSLIST = { "P", "C", "1B", "2B", "SS", "3B", "LF", "CF", "RF" }
Play.POSLIST = POSLIST
local INFIELD = { P = true, C = true, ["1B"] = true, ["2B"] = true, SS = true, ["3B"] = true }

local function dist2(ax, ay, bx, by) return sqrt((ax - bx) ^ 2 + (ay - by) ^ 2) end

--- Batting side from id hash (the log has no handedness): 1 = right, -1 = left.
local function batSide(id) return K.hash01(id or "x", 41) < 0.68 and 1 or -1 end
Play.batSide = batSide

---------------------------------------------------------------------------
-- planning helpers

local function newPlan()
  return { cams = {}, ball = {}, fmoves = {}, fposes = {}, runners = {}, pops = {}, sfx = {}, umpCalls = {}, catches = {}, slo = nil, shake = nil }
end

local function cam(plan, t, name, opt) plan.cams[#plan.cams + 1] = { t = t, name = name, opt = opt } end
local function sfx(plan, t, kind, v) plan.sfx[#plan.sfx + 1] = { t = t, kind = kind, v = v } end
local function pop(plan, t, text, x, y, z, dur) plan.pops[#plan.pops + 1] = { t = t, text = text, x = x, y = y, z = z or 8, dur = dur or 1.2 } end
local function fmove(plan, pos, t0, t1, x0, y0, x1, y1)
  local l = plan.fmoves[pos]
  if not l then l = {}; plan.fmoves[pos] = l end
  l[#l + 1] = { t0 = t0, t1 = t1, x0 = x0, y0 = y0, x1 = x1, y1 = y1 }
end
local function fpose(plan, pos, t0, t1, pose)
  local l = plan.fposes[pos]
  if not l then l = {}; plan.fposes[pos] = l end
  l[#l + 1] = { t0 = t0, t1 = t1, pose = pose }
end
-- animatic track on a fielder from t0 (track time 0) until t1
local function ftrack(plan, pos, t0, t1, track, vib)
  local l = plan.fposes[pos]
  if not l then l = {}; plan.fposes[pos] = l end
  l[#l + 1] = { t0 = t0, t1 = t1, track = track, vib = vib }
end
-- a fielder gloving the ball at t: kind "high" (reach, glove up), "throw" (reach at chest),
-- "low" (scoop), "dive" (the dive track). hold = how long the ball stays in the glove.
local GLOVE_Z = { high = 6.4, throw = 5.6, low = 1.0, dive = 1.4 }
Play.GLOVE_Z = GLOVE_Z
local function fcatch(plan, pos, t, kind, hold)
  local l = plan.fposes[pos]
  if not l then l = {}; plan.fposes[pos] = l end
  local c = { t0 = t - (kind == "dive" and 0.2 or 0.28), t1 = t + (hold or 0.4), catch = kind, ct = t, pos = pos, hold = hold or 0.4 }
  l[#l + 1] = c
  plan.catches[#plan.catches + 1] = c
  plan.lastCatch = c
  return c
end
-- where a fielder is at plan time t (follows his scripted moves)
local function posAt(plan, pos, t)
  local a = ALIGN[pos]
  local x, y = a[1], a[2]
  local l = plan.fmoves[pos]
  if l then
    for i = 1, #l do
      local m = l[i]
      if t >= m.t1 then x, y = m.x1, m.y1
      elseif t > m.t0 then
        local u = (t - m.t0) / (m.t1 - m.t0)
        return m.x0 + (m.x1 - m.x0) * u, m.y0 + (m.y1 - m.y0) * u
      end
    end
  end
  return x, y
end
-- which base (0 home .. 3) a point is, if it's on a bag
local function baseAt(x, y)
  for n = 0, 3 do
    local bx, by = basePos(n)
    if abs(bx - x) < 4 and abs(by - y) < 4 then return n end
  end
  return nil
end
-- who takes a throw at (x, y): the bag's baseman, the middle infielder not involved, the
-- catcher at home, a cutoff man otherwise; never the thrower himself
local function receiverFor(x, y, thrower)
  local base = baseAt(x, y)
  local r
  if base == 1 then r = "1B"
  elseif base == 3 then r = "3B"
  elseif base == 0 then r = "C"
  elseif base == 2 then r = (thrower == "SS" or thrower == "3B" or thrower == "LF") and "2B" or "SS"
  else r = x > 0 and "2B" or "SS" end
  if r == thrower then
    r = (r == "1B" and "P") or (r == "2B" and "SS") or (r == "SS" and "2B") or (r == "3B" and "SS") or "P"
  end
  return r
end
-- send a receiver to the spot, a stride off the bag toward the throw, by tArrive - 0.25
local function cover(plan, pos, x, y, fromX, fromY, tArrive)
  local sx, sy = posAt(plan, pos, max(0, tArrive - 2))
  local dx, dy = fromX - x, fromY - y
  local d = sqrt(dx * dx + dy * dy)
  local gx, gy = x, y
  if d > 1 then gx, gy = x + dx / d * 2.5, y + dy / d * 2.5 end
  local need = dist2(sx, sy, gx, gy)
  if need > 0.5 then
    local t1 = max(0.25, tArrive - 0.25)
    local t0 = max(0.1, t1 - need / FSPEED)
    if t1 - t0 < 0.15 then t1 = t0 + 0.15 end
    -- don't rewrite history: start after his last scripted move ends
    local l = plan.fmoves[pos]
    if l and #l > 0 and l[#l].t1 > t0 then t0 = l[#l].t1; t1 = max(t1, t0 + 0.15) end
    fmove(plan, pos, t0, t1, sx, sy, gx, gy)
  end
  return gx, gy
end

-- umpire call: track starts at t (the call lands a few frames in)
local function umpCall(plan, t, track, dur, vib)
  plan.umpCalls[#plan.umpCalls + 1] = { t = t, track = track, dur = dur or 0.9, vib = vib }
end

--- Enhanced League power used on this beat (the attached "ultra" log event), or nil.
local function ultra(b, power)
  local l = b.ultra
  if not l then return nil end
  for i = 1, #l do if l[i].power == power then return l[i] end end
  return nil
end
Play.ultra = ultra
-- passive powers (LASER_ARM, WARP_RUN) aren't logged by the sim; honour them if the
-- people table ever carries powers.
local function hasPower(tl, id, kind)
  local p = id and tl.meta and tl.meta.people and tl.meta.people[id]
  local l = p and p.powers
  if not l then return false end
  for i = 1, #l do if l[i] == kind or l[i].kind == kind then return true end end
  return false
end
local function seg(plan, s) plan.ball[#plan.ball + 1] = s; return s end

-- runner along the base paths: from base a to base b (b may be 4 = home), start t0
local function runner(plan, id, from, to, t0, speed, outAt, role)
  local target = to == -1 and min(from + 1, 4) or to
  local distance = (target - from) * 90
  local r = { id = id, from = from, to = to, target = target, t0 = t0, speed = speed or RUN, outAt = outAt, role = role }
  r.t1 = t0 + distance / r.speed
  if to == -1 then
    -- stops short, then trudges off
    r.stopFrac = 0.82
    r.t1 = t0 + distance * r.stopFrac / r.speed
  end
  plan.runners[#plan.runners + 1] = r
  return r
end

local function runnerPos(r, tau)
  if tau <= r.t0 then local x, y = basePos(r.from); return x, y, false end
  local d = (tau - r.t0) * r.speed
  local total = (r.target - r.from) * 90 * (r.stopFrac or 1)
  local moving = d < total
  if not moving then d = total end
  local leg = floor(d / 90)
  local f = (d - leg * 90) / 90
  local a, b = r.from + leg, r.from + leg + 1
  if b > r.target then a, b, f = r.target, r.target, 0 end
  local ax, ay = basePos(a)
  local bx, by = basePos(b)
  -- round the bases: bow outward a little near each bag
  local x, y = ax + (bx - ax) * f, ay + (by - ay) * f
  return x, y, moving
end
Play.runnerPos = runnerPos

-- ball segment evaluation ----------------------------------------------------
local function ballAt(plan, tau)
  local segs = plan.ball
  for i = 1, #segs do
    local s = segs[i]
    if tau >= s.t0 and tau <= s.t1 then
      local u = (s.t1 > s.t0) and (tau - s.t0) / (s.t1 - s.t0) or 1
      if s.kind == "path" then
        local p = s.pts
        local n = #p // 3
        local fi = (tau - s.t0) / 0.1
        local i0 = floor(fi)
        if i0 >= n - 1 then i0 = n - 2; fi = n - 1 end
        if i0 < 0 then i0 = 0 end
        local f = fi - i0
        local a, b = i0 * 3, (i0 + 1) * 3
        return p[a + 1] + (p[b + 1] - p[a + 1]) * f, p[a + 2] + (p[b + 2] - p[a + 2]) * f, max(0, p[a + 3] + (p[b + 3] - p[a + 3]) * f), s
      elseif s.kind == "line" then
        if s.stallD then
          -- STOPPER: the ball hangs in the air for stallD seconds at stallT
          local te = tau
          if te > s.stallT then te = max(s.stallT, te - s.stallD) end
          u = (te - s.t0) / (s.t1 - s.stallD - s.t0)
        end
        local x = s.ax + (s.bx - s.ax) * u
        if s.warpT and tau < s.warpT then x = x + s.warpDx end
        local y = s.ay + (s.by - s.ay) * u
        local z = s.az + (s.bz - s.az) * u + (s.arc or 0) * 4 * u * (1 - u)
        if s.brk then x = x + s.brk * u * u; z = z - (s.drop or 0) * u * u end
        return x, y, z, s
      elseif s.kind == "roll" then
        -- decelerating roll with hops
        local e = 1 - (1 - u) * (1 - u)
        local x = s.ax + (s.bx - s.ax) * e
        local y = s.ay + (s.by - s.ay) * e
        local z = (s.hop or 0) * abs(sin(u * (s.hops or 3) * math.pi)) * (1 - u)
        return x, y, z, s
      elseif s.kind == "hold" then
        return s.ax, s.ay, s.az, s
      end
    end
  end
  return nil
end
Play.ballAt = ballAt

local function camAt(plan, tau)
  local c = plan.cams[1]
  for i = 2, #plan.cams do
    if plan.cams[i].t <= tau then c = plan.cams[i] else break end
  end
  return c
end
Play.camAt = camAt

---------------------------------------------------------------------------
-- pitch

local ZONE_X = { [0] = { 0, 0.45 }, [1] = { 0.55, 0.8 }, [2] = { 0.85, 1.1 }, [3] = { 1.25, 2.0 } }
local BREAK = { SL = { 1.0, 0.4 }, CB = { 0.5, 1.4 }, SPL = { 0, 1.2 }, CH = { -0.4, 0.7 }, SI = { -0.6, 0.5 }, CT = { 0.4, 0.2 }, KN = { 0.6, 0.6 }, SPIT = { -0.3, 1.3 }, FB = { 0, 0 } }

-- catcher reach grid (catcher_reach frames, IK-posed offline): the frame whose mitt is nearest
-- where the pitch crosses the plate; balls in the dirt get the block. → frame, glove x, y, z (field ft)
local CATCHER_X <const>, CATCHER_Y <const> = 0, -3.2
local function reachFor(px, pz)
  Anim.load()
  local cr = Anim.catcherReach
  if not cr then return nil end
  local G, L = cr.glove, cr.labels
  local best, bd = nil, 1e9
  for i = 2, #G do
    local g = G[i]
    if g and L[i] ~= "block" then
      local dx, dz = (CATCHER_X + g[1]) - px, g[3] - pz
      local d = dx * dx + dz * dz * 1.3
      if d < bd then best, bd = i, d end
    end
  end
  if pz < 1.0 then for i = 1, #L do if L[i] == "block" then best = i end end end
  if not best then return nil end
  local g = G[best]
  return best, CATCHER_X + g[1], CATCHER_Y + g[2], g[3]
end
Play.reachFor = reachFor

local function planPitch(b, tl, plan)
  local e = b.e
  local D = DUR()
  local h = K.hash01(b.i, 3)
  local h2 = K.hash01(b.i, 9)
  local zx = ZONE_X[e.z or 0] or ZONE_X[0]
  local side = (h < 0.5) and -1 or 1
  local px = side * (zx[1] + (zx[2] - zx[1]) * h2)
  local pz = 2.5 + (h2 - 0.5) * 1.4
  if e.z == 3 and h2 > 0.6 then pz = h2 > 0.8 and 4.3 or 0.7 end
  -- (local engines (pdsim) log the exact location, normalised to the zone: |px|, |pz| <= 1 is a
  -- strike; a pitch the player aimed lands where it went)
  if e.px and e.pz then px, pz = e.px * 0.83, 2.5 + e.pz end
  local tRel = 1.0
  local travel = 60.5 / ((e.v or 90) * MPH)
  -- Enhanced League pitch powers
  local uF, uS, uW, uC = ultra(b, "FIREBALL"), ultra(b, "STOPPER"), ultra(b, "WARP_PITCH"), ultra(b, "CLOUD_BALL")
  local uH = ultra(b, "HYPER_HIT")
  local stallD = uS and 0.6 or 0
  local tPlate = tRel + travel + stallD
  local br = BREAK[e.t] or BREAK.FB
  plan.pitch = { tRel = tRel, tPlate = tPlate, px = px, pz = pz, r = e.r, side = batSide(b.pre.bat) }
  local takes = e.r == "B" or e.r == "C"
  if takes and not b.ultra and K.hash01(b.i, 51) < 0.22 then
    cam(plan, 0, "behindPlate", { side = K.hash01(b.i, 52) < 0.5 and 1 or -1 })
  else
    cam(plan, 0, "pitch")
  end
  local rx = -1.6
  local ps = seg(plan, { kind = "line", t0 = tRel, t1 = tPlate, ax = rx, ay = 55, az = 6.0, bx = px - br[1], by = 0.5, bz = pz + br[2], brk = br[1], drop = br[2], arc = 0.6 })
  local pu = uF or uS or uW or uC
  if pu then
    plan.power = pu.power
    plan.powerVib = { t0 = 0.1, t1 = tRel + 0.1, who = "P" }
    pop(plan, 0.15, (BallCast.Timeline.POWER_NAMES[pu.power] or pu.power) .. "!", 0, 60, 7.5, tRel - 0.1)
    sfx(plan, 0.15, "ooh")
  end
  if uF then plan.fire = true end
  if uS then
    ps.stallT, ps.stallD = tRel + travel * 0.45, stallD
    plan.stall = { ps.stallT, ps.stallT + stallD }
  end
  if uW then
    ps.warpT, ps.warpDx = tRel + travel * 0.45, (px < 0 and 1 or -1) * 4.5
    plan.warp = ps.warpT
  end
  if uC then plan.cloud = { tRel + travel * 0.2, tPlate - 0.06 } end
  sfx(plan, tRel, "whoosh")
  local r = e.r
  local swingAt = tPlate - 0.12
  -- STOPPER: the batter's timing is shot, he swings at the hanging ball
  if uS and r == "S" then swingAt = plan.stall[1] + 0.1 end
  if uH then
    plan.hyperPower = true
    plan.powerVib = { t0 = 0.1, t1 = tPlate, who = "B" }
    pop(plan, 0.3, "HYPER HIT!", -plan.pitch.side * 3, 0, 8, 1.0)
    if r == "X" or r == "F" then plan.hyperT = tPlate end
    if r == "S" then plan.hyperWhiff = true end
  end
  if r == "X" then
    b.dur = tPlate + 0.12
    sfx(plan, tPlate, "crack")
    plan.swing = swingAt
  elseif r == "F" then
    plan.swing = swingAt
    sfx(plan, tPlate, "foul")
    local dir = (h2 < 0.5) and -1 or 1
    seg(plan, { kind = "line", t0 = tPlate, t1 = tPlate + 0.9, ax = px, ay = 0.5, az = pz, bx = dir * (30 + 40 * h), by = -70 - 30 * h2, bz = 4, arc = 40 + 30 * h })
    b.dur = D.p
  elseif r == "S" then
    plan.swing = swingAt
    local rf, gx, gy, gz = reachFor(px, pz)
    if not rf then gx, gy, gz = px * 0.6, -3, 2.2 end
    plan.reach = rf and { f = rf, x = gx, y = gy, z = gz } or nil
    seg(plan, { kind = "line", t0 = tPlate, t1 = tPlate + 0.06, ax = px, ay = 0.5, az = pz, bx = gx, by = gy, bz = gz })
    seg(plan, { kind = "hold", t0 = tPlate + 0.06, t1 = tPlate + 0.8, ax = gx, ay = gy, az = gz })
    sfx(plan, tPlate + 0.06, "pop")
    b.dur = D.p + (plan.hyperWhiff and 0.8 or 0)
  elseif r == "H" then
    seg(plan, { kind = "line", t0 = tPlate, t1 = tPlate + 0.5, ax = px, ay = 0.5, az = pz, bx = -plan.pitch.side * 6, by = 8, bz = 0, arc = 2 })
    sfx(plan, tPlate, "thud")
    pop(plan, tPlate + 0.1, "OUCH!", -plan.pitch.side * 3, 0, 7, 1.4)
    plan.hbp = tPlate
    b.dur = D.pH
  else
    -- the catcher reaches for it: the ball ends in the mitt of the reach pose nearest the pitch
    local rf, gx, gy, gz = reachFor(px, pz)
    if not rf then gx, gy, gz = px * 0.6, -3, 2.4 end
    plan.reach = rf and { f = rf, x = gx, y = gy, z = gz } or nil
    seg(plan, { kind = "line", t0 = tPlate, t1 = tPlate + 0.06, ax = px, ay = 0.5, az = pz, bx = gx, by = gy, bz = gz })
    seg(plan, { kind = "hold", t0 = tPlate + 0.06, t1 = tPlate + 0.8, ax = gx, ay = gy, az = gz })
    sfx(plan, tPlate + 0.06, "pop")
    b.dur = D.p
  end
  if b.k then
    pop(plan, tPlate + 0.25, e.r == "C" and "STRIKE THREE!" or "STRUCK HIM OUT!", 0, -6, 9, 1.4)
    plan.umpCall = tPlate + 0.2
    umpCall(plan, tPlate + 0.2, "ump_strike", 1.4, 1)    -- the punch-out
    plan.kT = tPlate + 0.2
    sfx(plan, tPlate + 0.2, "ooh")
    sfx(plan, tPlate + 0.25, "strike3")
  elseif e.r == "C" then
    plan.umpCall = tPlate + 0.2
    umpCall(plan, tPlate + 0.2, "ump_strike", 0.8)
  end
  if r ~= "X" and r ~= "H" then plan.receive = tPlate end
  if r == "H" then plan.hbp = tPlate end
  if b.walk then
    -- trot to first: cut wide for the runners
    local tw = tPlate + 0.9
    cam(plan, tw, "high")
    local side = batSide(b.pre.bat)
    plan.batToss = { t = tw, x0 = -side * 3.2, y0 = 0.6, z0 = 2.5, x1 = -side * 4.5, y1 = -1.5, dur = 0.35, h = 1.2, spin = 1, rest = 160 }
    for _, m in ipairs(b.mvs) do runner(plan, m.id, m.from, m.to, tw, RUN * 0.6) end
    pop(plan, tPlate + 0.3, e.r == "H" and "HIT BY PITCH" or "BALL FOUR", 0, -6, 9, 1.2)
    b.dur = tw + D.walk + (#b.mvs > 1 and 1.2 or 0)
  end
end

---------------------------------------------------------------------------
-- balls in play

local function pathPoints(e)
  local p = e.path
  if not p or #p < 6 then return nil end
  return p
end

local function pathMaxZ(p)
  local m = 0
  for i = 3, #p, 3 do if p[i] > m then m = p[i] end end
  return m
end

-- time (s) when the descending ball first drops to z <= zc after the apex; nil if never
local function catchIndex(p, zc)
  local n = #p // 3
  local apexI, apexZ = 0, -1
  for i = 0, n - 1 do
    local z = p[i * 3 + 3]
    if z > apexZ then apexZ, apexI = z, i end
  end
  for i = apexI, n - 1 do
    if p[i * 3 + 3] <= zc then return i end
  end
  return n - 1
end

local function deepCamFor(sp) if sp < -14 then return "deepL" elseif sp > 14 then return "deepR" else return "deepC" end end

local function planBip(b, tl, plan)
  local e = b.e
  local park = tl.meta.park or {}
  local res = e.res
  local sp = e.sp or 0
  local dx, dy = sin(math.rad(sp)), cos(math.rad(sp))
  local path = pathPoints(e)
  local f = e.f or "SS"
  local fa = ALIGN[f] or ALIGN.SS
  local isHit = res == "1B" or res == "2B" or res == "3B" or res == "HR"
  local air = path ~= nil and (pathMaxZ(path) > 12 or res == "HR")
  local batter = b.pre.bat
  local tFielded, fx, fy -- where/when the defense secures the ball
  local tBallDone
  local throws = {}      -- { t0, ax, ay, base, arrive }
  -- Enhanced League
  local uH, uL = ultra(b, "HYPER_HIT"), ultra(b, "LEAP_CATCH")
  local uLaser, uRun = ultra(b, "LASER_ARM"), ultra(b, "WARP_RUN")
  local throwSpeed = THROW
  if uLaser or hasPower(tl, nil, "LASER_ARM") then throwSpeed = THROW * 2; plan.laser = true end
  local warpRunner = uRun and uRun.who or nil
  if not warpRunner then
    for _, m in ipairs(b.mvs) do if hasPower(tl, m.id, "WARP_RUN") then warpRunner = m.id end end
  end
  plan.warpRun = warpRunner
  if uH then
    plan.hyperT = 0
    plan.hyperBip = true
    pop(plan, 0.15, "HYPER HIT!", 0, 10, 12, 1.0)
  end
  if uLaser then pop(plan, 0.2, "LASER ARM!", fa[1], fa[2], 10, 1.0) end
  if uRun then pop(plan, 0.3, "WARP RUN!", 45, 45, 8, 1.0) end

  -- 1) the ball ------------------------------------------------------------
  if air then
    local n = #path // 3
    local hang = (n - 1) * 0.1
    local caught = (res == "OUT" or res == "SF" or res == "FOUL_OUT" or res == "DP" and e.out ~= "DP") and not isHit
    if res == "DP" and e.out ~= "DP" then caught = true end
    if caught then
      local ci = catchIndex(path, 6)
      local fence = Cam.fenceAt(park, sp)
      local wi = nil
      if uL then
        -- LEAP_CATCH: he climbs the wall and takes it back at the fence line
        for i = 0, n - 1 do
          local x, y = path[i * 3 + 1], path[i * 3 + 2]
          if sqrt(x * x + y * y) >= fence - 3 then wi = i break end
        end
        if wi then ci = wi end
      end
      local tc = ci * 0.1
      seg(plan, { kind = "path", t0 = 0, t1 = tc, pts = path })
      fx, fy = path[ci * 3 + 1], path[ci * 3 + 2]
      tFielded = tc
      plan.catchT, plan.catchPos = tc, { fx, fy }
      -- fielder runs under it
      local need = dist2(fa[1], fa[2], fx, fy)
      local tRun = need / FSPEED
      local tStart = max(0.25, tc - tRun - 0.4)
      if wi then
        local zc = path[ci * 3 + 3]
        local t0 = tc - 0.5
        fmove(plan, f, tStart, max(tStart + 0.1, t0 - 0.05), fa[1], fa[2], fx, fy)
        plan.leap = { pos = f, t0 = t0, tc = tc, z = zc, land = tc + 0.55 }
        plan.catchZ = max(4, zc - 4)
        -- ball rides down with him
        seg(plan, { kind = "line", t0 = tc, t1 = tc + 0.55, ax = fx, ay = fy, az = zc, bx = fx, by = fy, bz = 5 })
        seg(plan, { kind = "hold", t0 = tc + 0.55, t1 = tc + 1.1, ax = fx, ay = fy, az = 5 })
        ftrack(plan, f, tc + 0.55, tc + 1.6, "celebrate", 1)
        pop(plan, tc + 0.1, "ROBBED!", fx, fy, zc + 8, 1.4)
        sfx(plan, tc, "roar", 1.0)
        plan.slo = { tc - 0.7, tc + 0.35 }
        b.big = "LEAP CATCH! ROBBED!"
        plan.bannerT = tc + 0.6
        plan.shake = tc + 0.55
        tBallDone = tc + 1.1
      else
        fmove(plan, f, tStart, max(tStart + 0.1, tc - 0.15), fa[1], fa[2], fx, fy)
        fcatch(plan, f, tc, need > 70 and "dive" or "high", 0.6)
        seg(plan, { kind = "hold", t0 = tc, t1 = tc + 0.6, ax = fx, ay = fy, az = 6 })
        pop(plan, tc + 0.1, "CAUGHT", fx, fy, 14, 1.0)
        if need > 70 then plan.slo = { tc - 0.6, tc + 0.25 }; b.big = b.big or "WHAT A CATCH" end
        tBallDone = tc + 0.6
      end
      sfx(plan, tc, "pop")
      -- throw it back in
      local tx, ty = basePos(res == "SF" and 0 or 2)
      if res ~= "SF" then tx, ty = 0, 118 end
      throws[#throws + 1] = { t0 = tBallDone, ax = fx, ay = fy, bx = tx, by = ty, from = f }
    else
      seg(plan, { kind = "path", t0 = 0, t1 = hang, pts = path })
      local lx, ly = path[(n - 1) * 3 + 1], path[(n - 1) * 3 + 2]
      tBallDone = hang
      if res == "HR" then
        -- over the wall: who goes back for it
        local best, bd = "CF", 1e9
        for _, pos in ipairs({ "LF", "CF", "RF" }) do
          local a = ALIGN[pos]
          local d = dist2(a[1], a[2], lx, ly)
          if d < bd then best, bd = pos, d end
        end
        local fence = Cam.fenceAt(park, sp)
        local wx, wy = dx * (fence - 4), dy * (fence - 4)
        fmove(plan, best, 0.3, min(hang - 0.2, 0.3 + dist2(ALIGN[best][1], ALIGN[best][2], wx, wy) / FSPEED), ALIGN[best][1], ALIGN[best][2], wx, wy)
        -- find the wall crossing for slo-mo
        local tw = hang * 0.8
        for i = 0, n - 1 do
          local x, y = path[i * 3 + 1], path[i * 3 + 2]
          if sqrt(x * x + y * y) >= fence then tw = i * 0.1 break end
        end
        -- he leaps at the wall as it goes over; sometimes he eats the warning track
        ftrack(plan, best, tw - 0.15, tw + 0.25, "catch")
        if K.hash01(b.i, 21) < 0.4 then ftrack(plan, best, tw + 0.25, tw + 1.5, "pratfall", 1)
        else fpose(plan, best, tw + 0.25, tw + 1.5, "reach") end
        plan.slo = { max(0.2, tw - 1.1), tw + 0.35 }
        plan.shake = tw
        plan.wallT = tw
        sfx(plan, 0, "crack")
        sfx(plan, tw, "roar", 1.0)
        pop(plan, tw + 0.2, "GONE!", wx, wy, 30, 1.4)
        b.big = b.walkoff and "WALK-OFF HOME RUN!" or (b.runs >= 4 and "GRAND SLAM!" or "HOME RUN!")
        sfx(plan, tw + 0.6, "homerun")
      else
        -- lands, rolls on, gets run down
        local rx, ry = lx + dx * 35, ly + dy * 35
        local fence = Cam.fenceAt(park, sp)
        local rd = sqrt(rx * rx + ry * ry)
        if rd > fence - 6 then rx, ry = rx * (fence - 6) / rd, ry * (fence - 6) / rd end
        seg(plan, { kind = "roll", t0 = hang, t1 = hang + 1.1, ax = lx, ay = ly, bx = rx, by = ry, hop = 5, hops = 2, wall = rd > fence - 6 })
        local fpos = f
        if INFIELD[f] and dist2(0, 0, lx, ly) > 170 then
          local best, bd = "CF", 1e9
          for _, pos in ipairs({ "LF", "CF", "RF" }) do
            local a = ALIGN[pos]
            local d = dist2(a[1], a[2], rx, ry)
            if d < bd then best, bd = pos, d end
          end
          fpos = best
        end
        local fa2 = ALIGN[fpos]
        local tGet = hang + 1.1
        fmove(plan, fpos, 0.3, tGet, fa2[1], fa2[2], rx, ry)
        if dist2(fa2[1], fa2[2], lx, ly) < 25 and res == "ROE" then
          ftrack(plan, fpos, hang - 0.2, hang + 0.9, "dive")
          pop(plan, hang, "E-" .. (f or "?"), lx, ly, 10, 1.4)
          sfx(plan, hang, "ooh")
        end
        seg(plan, { kind = "hold", t0 = tGet, t1 = tGet + 0.35, ax = rx, ay = ry, az = 3 })
        fcatch(plan, fpos, tGet, "low", 0.35)
        fx, fy, tFielded = rx, ry, tGet
        plan.catchT, plan.catchPos = tGet, { rx, ry }
        tBallDone = tGet + 0.35
        local tb = res == "3B" and 3 or 2
        local tx, ty = basePos(tb)
        throws[#throws + 1] = { t0 = tGet + 0.35, ax = rx, ay = ry, bx = tx, by = ty, slow = true, from = fpos }
        if res == "3B" then b.big = b.big or "TRIPLE!" end
        sfx(plan, 0, "crack")
        sfx(plan, hang * 0.6, "roar", 0.7)
      end
    end
    if res == "FOUL_OUT" then cam(plan, 0, "high")
    elseif not uL and res ~= "HR" and K.hash01(b.i, 53) < 0.3 then cam(plan, 0, "wallLow", { side = sp < 0 and 1 or -1 })
    else cam(plan, 0, deepCamFor(sp), { follow = true }) end
    if res ~= "HR" then cam(plan, tBallDone + 0.4, ((res == "2B" or res == "3B") and K.hash01(b.i, 54) < 0.5) and "runner" or "high", { side = 1 }) end
    if res == "HR" then
      cam(plan, (plan.wallT or tBallDone) + 1.2, "bleacher", { cheer = true })
      cam(plan, (plan.wallT or tBallDone) + 3.6, K.hash01(b.i, 55) < 0.4 and "blimp" or "high")
    end
    if res ~= "HR" then sfx(plan, 0, "crack") end
  else
    -- 2) ground ball / line drive on the ground --------------------------------
    local ev = (e.ev or 80)
    local loss = (e.la or 0) < -5 and 0.62 or (e.la or 0) < 3 and 0.78 or 0.7
    local v0 = ev * MPH * loss
    local c = 0.24
    local maxD = v0 / c
    local fpos = f
    local ta, d
    if INFIELD[fpos] and not (isHit and not INFIELD[f]) then
      -- intercept where the fielder cuts the ball's line
      d = max(25, fa[1] * dx + fa[2] * dy)
      if fpos == "P" then d = 55 end
      if fpos == "C" then d = 8 end
    else
      d = min(maxD * 0.9, (ALIGN[fpos] and (ALIGN[fpos][1] * dx + ALIGN[fpos][2] * dy) or 240) - 25)
    end
    if d >= maxD * 0.98 then d = maxD * 0.9 end
    ta = -log(1 - d * c / v0) / c
    if ta ~= ta or ta > 4 then ta = 2.0 end
    ta = max(0.35, ta)
    fx, fy = dx * d, dy * d
    seg(plan, { kind = "roll", t0 = 0, t1 = ta, ax = 0, ay = 2, bx = fx, by = fy, hop = (e.la or 0) < -10 and 9 or 3, hops = (e.la or 0) < -10 and 3 or 5 })
    local fa2 = ALIGN[fpos] or fa
    fmove(plan, fpos, 0.15, ta, fa2[1], fa2[2], fx, fy)
    fcatch(plan, fpos, ta, "low", 0.3)
    plan.groundFielder = fpos
    tFielded = ta
    seg(plan, { kind = "hold", t0 = ta, t1 = ta + 0.3, ax = fx, ay = fy, az = 2 })
    tBallDone = ta + 0.3
    sfx(plan, 0, "crack")
    if res == "OUT" or res == "FC" or res == "DP" then
      if res == "DP" then
        throws[#throws + 1] = { t0 = ta + 0.3, ax = fx, ay = fy, bx = basePos(2), by = select(2, basePos(2)), base = 2, relay = true }
      elseif res == "FC" then
        local lead = 2
        for _, m in ipairs(b.mvs) do if m.to == -1 and m.from > 0 then lead = min(4, m.from + 1) end end
        local bx2, by2 = basePos(lead)
        throws[#throws + 1] = { t0 = ta + 0.3, ax = fx, ay = fy, bx = bx2, by = by2, base = lead }
      else
        local bx2, by2 = basePos(1)
        throws[#throws + 1] = { t0 = ta + 0.3, ax = fx, ay = fy, bx = bx2, by = by2, base = 1 }
      end
    elseif res == "ROE" then
      local bx2, by2 = basePos(1)
      throws[#throws + 1] = { t0 = ta + 0.3, ax = fx, ay = fy, bx = bx2 + 25, by = by2 - 30, base = 1, wild = true }
      pop(plan, ta + 0.9, "E-" .. (f or "?"), bx2, by2, 10, 1.4)
      sfx(plan, ta + 0.9, "ooh")
    elseif isHit then
      local tb = res == "3B" and 3 or 2
      local bx2, by2 = basePos(INFIELD[fpos] and 1 or tb)
      throws[#throws + 1] = { t0 = ta + 0.3, ax = fx, ay = fy, bx = bx2, by = by2, slow = not INFIELD[fpos] }
      sfx(plan, 0.3, "roar", 0.5)
    end
    if K.hash01(b.i, 56) < 0.3 then cam(plan, 0, "dugout", { side = sp < 0 and 1 or -1 }) else cam(plan, 0, "high") end
  end

  -- 3) throws -------------------------------------------------------------------
  -- every throw has a receiver who runs to the bag (or cutoff spot) first and gloves it
  local outAt = {}  -- base → time the ball gets there
  local lastT = tBallDone or 1
  for i, th in ipairs(throws) do
    local from = th.from or plan.groundFielder or b.e.f or "SS"
    local d = dist2(th.ax, th.ay, th.bx, th.by)
    local spd = th.slow and throwSpeed * 0.75 or throwSpeed
    local t1 = th.t0 + d / spd
    local rcv = (not th.wild) and receiverFor(th.bx, th.by, from) or nil
    local gz = GLOVE_Z.throw
    if rcv and rcv ~= "C" then th.bx, th.by = cover(plan, rcv, th.bx, th.by, th.ax, th.ay, t1) end
    seg(plan, { kind = "line", t0 = th.t0, t1 = t1, ax = th.ax, ay = th.ay, az = 5, bx = th.bx, by = th.by, bz = rcv and gz or 4, arc = d / 14 / (spd / THROW), throw = true })
    if not plan.leap then ftrack(plan, from, th.t0 - 0.27, th.t0 + 0.46, "fielder_throw") end
    if th.base then outAt[th.base] = t1 end
    lastT = t1
    if th.relay then
      -- the pivot gloves it, turns and fires to first
      local bx2, by2 = basePos(1)
      local f1 = rcv == "1B" and "P" or "1B"
      bx2, by2 = cover(plan, f1, bx2, by2, th.bx, th.by, t1 + 0.6)
      local t2 = t1 + 0.35 + dist2(th.bx, th.by, bx2, by2) / throwSpeed
      fcatch(plan, rcv, t1, "throw", 0.35)
      seg(plan, { kind = "hold", t0 = t1, t1 = t1 + 0.35, ax = th.bx, ay = th.by, az = gz })
      seg(plan, { kind = "line", t0 = t1 + 0.35, t1 = t2, ax = th.bx, ay = th.by, az = 5, bx = bx2, by = by2, bz = gz, arc = 3, throw = true })
      ftrack(plan, rcv, t1 + 0.35 - 0.27, t1 + 0.8, "fielder_throw")
      fcatch(plan, f1, t2, "throw", 0.5)
      seg(plan, { kind = "hold", t0 = t2, t1 = t2 + 0.5, ax = bx2, ay = by2, az = gz })
      outAt[1] = t2
      lastT = t2
    elseif th.wild then
      seg(plan, { kind = "roll", t0 = t1, t1 = t1 + 1.0, ax = th.bx, ay = th.by, bx = th.bx + 30, by = th.by - 40, hop = 2, hops = 3 })
      lastT = t1 + 1.0
    else
      if rcv then fcatch(plan, rcv, t1, "throw", 0.5) end
      seg(plan, { kind = "hold", t0 = t1, t1 = t1 + 0.5, ax = th.bx, ay = th.by, az = gz })
    end
  end

  -- 4) runners --------------------------------------------------------------------
  local caughtFly = air and (res == "OUT" or res == "SF" or res == "FOUL_OUT")
  local endT = lastT
  for _, m in ipairs(b.mvs) do
    if m.from ~= m.to then
      local t0
      if m.from == 0 and res == "HR" then t0 = 0.85; plan.homerBatter = true   -- admire it first
      elseif m.from == 0 then t0 = 0.25
      elseif caughtFly then t0 = (tFielded or 1) + 0.1
      else t0 = 0.05 end
      local speed = res == "HR" and TROT or RUN
      if warpRunner and m.id == warpRunner then speed = speed * 1.8 end
      local oa = nil
      if m.to == -1 then
        local tgt = min(m.from + 1, 4)
        oa = outAt[tgt] or (caughtFly and m.from == 0 and tFielded) or (tFielded and tFielded + 0.6)
        if caughtFly and m.from == 0 then
          -- the batter peels off halfway
          local r = runner(plan, m.id, 0, -1, 0.25, RUN * 0.8, oa, "batter")
          r.stopFrac = 0.4
          r.t1 = r.t0 + 90 * 0.4 / r.speed
        else
          local r = runner(plan, m.id, m.from, -1, t0, RUN, oa)
          -- make the out a bang-bang play: arrive right as the ball does
          if oa then
            local need = (90 * r.stopFrac) / RUN
            r.t0 = max(0.05, oa - need + 0.12)
            r.t1 = r.t0 + need
            if abs(oa - r.t1) < 0.35 and not plan.slo then
              plan.slo = { oa - 0.55, oa + 0.3 }
              b.big = b.big or (res == "DP" and "DOUBLE PLAY!" or "BANG-BANG!")
              umpCall(plan, oa, "ump_strike", 0.9)
            end
          end
          pop(plan, oa or r.t1, "OUT!", select(1, basePos(tgt)), select(2, basePos(tgt)), 10, 1.0)
          sfx(plan, oa or r.t1, "ooh")
        end
      else
        local r = runner(plan, m.id, m.from, m.to, t0, speed)
        if m.to == 4 then
          plan.scoreT = max(plan.scoreT or 0, r.t1)
          pop(plan, r.t1, "SCORES!", 0, 0, 10, 1.1)
          sfx(plan, r.t1, "roar", 0.8)
          if b.walkoff then plan.slo = plan.slo or { r.t1 - 0.6, r.t1 + 0.4 } end
        end
        if r.t1 > endT then endT = r.t1 end
      end
    end
  end
  if res == "DP" then b.big = b.big or "DOUBLE PLAY!" end
  if res == "ROE" then b.big = b.big or "ERROR!"; sfx(plan, (tFielded or 1) + 0.3, "error") end
  if plan.homerBatter then plan.trotVib = true end
  -- the bat toss as he breaks for first (a big flip on a homer)
  do
    local side = batSide(batter)
    local bx = -side * 3.2
    local hr = res == "HR"
    plan.batToss = { t = hr and 0.2 or 0.24, x0 = bx, y0 = 0.6, z0 = 3, dur = hr and 1.0 or 0.5, h = hr and 15 or 4,
      spin = hr and 4.5 or 2.2, rest = 20 + floor(K.hash01(b.i, 74) * 140) }
    if hr then plan.batToss.x1, plan.batToss.y1 = bx + side * 3, 5
    else plan.batToss.x1, plan.batToss.y1 = bx - side * (2 + K.hash01(b.i, 75) * 4), -4 - K.hash01(b.i, 76) * 4 end
  end
  if b.walkoff then b.big = (res == "HR") and "WALK-OFF HOME RUN!" or "WALK-OFF!"; plan.slo = plan.slo or { 0.3, 1.2 } end
  if res == "HR" and b.walkoff then sfx(plan, (plan.wallT or 2) + 0.2, "fanfare") end
  b.dur = max(endT, lastT) + 1.3
end

---------------------------------------------------------------------------
-- other beats

local function planOther(b, tl, plan)
  local D = DUR()
  local k = b.kind
  local e = b.e
  if k == "half" then
    if K.hash01(b.i, 57) < 0.4 then cam(plan, 0, "blimp", { side = K.hash01(b.i, 58) < 0.5 and 1 or -1 })
    else cam(plan, 0, "high", { establish = true }) end
    b.dur = D.half
  elseif k == "pa" then
    local h = K.hash01(b.i, 59)
    -- dead time between batters: a slow push on the pitcher or the batter, or the usual angle
    if h < 0.25 then cam(plan, 0, "pitcherSide", { side = h < 0.12 and 1 or -1 })
    elseif h < 0.5 then cam(plan, 0, "batterSide", { side = Play.batSide(e.bat) })
    else cam(plan, 0, "pitch") end
    b.dur = D.pa
  elseif k == "sb" then
    cam(plan, 0, K.hash01(b.i, 60) < 0.5 and "runner" or "high", { side = -1 })
    local m = b.mvs[1]
    local from = m and m.from or 1
    local id = e.id
    local tArr = 0.3 + 90 / RUN
    local r = runner(plan, id, from, e.ok and e.base or -1, 0.3, RUN)
    if not e.ok then r.stopFrac = 0.92; r.t1 = 0.3 + 90 * 0.92 / RUN end
    -- pitch + catcher's throw to second
    local bx, by = basePos(2)
    seg(plan, { kind = "line", t0 = 0.3, t1 = 0.75, ax = -1.6, ay = 55, az = 6, bx = 0, by = -2, bz = 2.5 })
    local tThrow = 0.95
    local tIn = tThrow + 127 / THROW
    seg(plan, { kind = "line", t0 = tThrow, t1 = tIn, ax = 0, ay = -2, az = 5, bx = bx - 4, by = by, bz = 5.6, arc = 6, throw = true })
    seg(plan, { kind = "hold", t0 = tIn, t1 = tIn + 0.8, ax = bx - 4, ay = by, az = 5.6 })
    fmove(plan, "SS", 0.4, tIn - 0.1, ALIGN.SS[1], ALIGN.SS[2], bx - 4, by)
    fcatch(plan, "SS", tIn, "throw", 0.6)
    plan.relT = 0.3
    plan.cthrow = tThrow
    umpCall(plan, tIn + 0.05, e.ok and "ump_safe" or "ump_strike", 0.9)
    plan.slo = { tIn - 0.5, tIn + 0.3 }
    pop(plan, tIn + 0.1, e.ok and "SAFE!" or "OUT!", bx, by, 10, 1.2)
    sfx(plan, tIn + 0.1, e.ok and "roar" or "ooh", 0.6)
    plan.slide = { id = id, t = tIn - 0.3, safe = e.ok and true or false }
    b.big = e.ok and "STOLEN BASE" or "CAUGHT STEALING"
    b.dur = max(tArr, tIn) + 1.6
  elseif k == "wp" then
    cam(plan, 0, "pitch")
    seg(plan, { kind = "line", t0 = 0.4, t1 = 0.85, ax = -1.6, ay = 55, az = 6, bx = 1.5, by = 2, bz = 0.2 })
    plan.relT = 0.4
    plan.wildT = 0.85
    seg(plan, { kind = "roll", t0 = 0.85, t1 = 1.8, ax = 1.5, ay = 2, bx = 18, by = -40, hop = 2, hops = 3 })
    cam(plan, 1.0, "high")
    pop(plan, 0.9, e.pb and "PASSED BALL" or "WILD PITCH", 0, -6, 9, 1.4)
    local endT = 1.8
    for _, m in ipairs(b.mvs) do
      local r = runner(plan, m.id, m.from, m.to, 0.9)
      if m.to == 4 then pop(plan, r.t1, "SCORES!", 0, 0, 10, 1.0) end
      endT = max(endT, r.t1)
    end
    b.dur = endT + 1.0
  elseif k == "sub" then
    cam(plan, 0, "pitch")
    b.dur = D.sub
  elseif k == "inc" then
    local kind = e.kind
    if kind == "RACCOON_ON_FIELD" or kind == "FAN_ON_FIELD" or kind == "BRAWL" then
      cam(plan, 0, "high", { incident = kind })
      cam(plan, 2.8, "bleacher", { incident = kind, cheer = kind ~= "BRAWL" })
      if kind == "BRAWL" then cam(plan, 4.2, "high", { incident = kind }) end
    elseif kind == "EJECTION" or kind == "BALL_TAMPERING" then
      cam(plan, 0, "pitch", { incident = kind })
    else
      cam(plan, 0, "bleacher", { incident = kind, cheer = kind == "RACCOONS_BULLPEN" })
    end
    sfx(plan, 0.2, "ooh")
    sfx(plan, 0.6, "roar", 0.6)
    if kind == "RACCOON_ON_FIELD" or kind == "RACCOONS_BULLPEN" then sfx(plan, 0.3, "gladiators") end
    if kind == "EJECTION" then sfx(plan, 0.4, "eject") end
    if kind == "EJECTION" or kind == "BRAWL" then plan.bigVib = true end
    b.big = nil
    b.dur = D.inc + (kind == "BRAWL" and 1.5 or 0)
  elseif k == "end" then
    cam(plan, 0, "high", { establish = true })
    cam(plan, 2.0, "bleacher", { cheer = true })
    sfx(plan, 0.2, "roar", 1.0)
    b.dur = D["end"]
  else
    cam(plan, 0, "high")
    local endT = 1
    for _, m in ipairs(b.mvs or {}) do
      local r = runner(plan, m.id, m.from, m.to, 0.2)
      endT = max(endT, r.t1)
    end
    b.dur = endT + 0.8
  end
end

-- Canned crowd reactions (audio.lua "c_*" cues; the scene scales volume by leverage and
-- audio.lua keeps them from stacking). The crowd is the home crowd.
local function reactions(b, plan)
  local home = not b.pre.top        -- home team at bat
  local e = b.e
  local function R(t, kind, v) sfx(plan, max(0, t), kind, v or 0.8) end
  local k = b.kind
  if k == "p" then
    local tp = plan.pitch.tPlate
    if b.k then
      if not home then R(tp + 0.35, "c_applause", 0.9)          -- our guy struck him out
      elseif e.r == "C" then R(tp + 0.3, "c_boo", 0.8)          -- called strike three on us
      else R(tp + 0.3, "c_groan", 0.7) end
    elseif b.walk then R(tp + 0.5, home and "c_clap" or "c_murmur", 0.6)
    elseif e.r == "H" and home then R(tp + 0.35, "c_boo", 0.7)
    end
    if plan.power or plan.hyperPower then R(0.35, "c_ooh", 0.7) end
  elseif k == "bip" then
    local res = e.res
    if res == "HR" then R(plan.wallT or 1, home and "c_roar" or "c_groan", 1)
    elseif plan.leap then R(plan.leap.tc + 0.05, home and "c_groan" or "c_roar", 1)
    else
      local cp = plan.catchPos
      local deep = cp and (cp[1] * cp[1] + cp[2] * cp[2]) > 270 * 270
      if deep and plan.catchT and (res == "OUT" or res == "SF" or res == "DP" or res == "FOUL_OUT") then
        R(plan.catchT - 0.8, "c_ooh", 0.85)                     -- it's carrying... caught
      end
      if (res == "1B" or res == "2B" or res == "3B") and home then R(0.7, "c_cheer", res == "1B" and 0.6 or 0.85) end
      if res == "ROE" then R((plan.catchT or 1) + 0.5, home and "c_cheer" or "c_groan", 0.8) end
      if res == "DP" then R(plan.slo and plan.slo[2] or 2, home and "c_groan" or "c_applause", 0.8) end
    end
    if plan.scoreT and res ~= "HR" then R(plan.scoreT, home and "c_cheer" or "c_groan", 0.9) end
    if b.walkoff then R(plan.scoreT or 1, "c_roar", 1) end
  elseif k == "sb" then
    local t = (plan.slo and plan.slo[2]) or 1.5
    if e.ok then R(t, home and "c_cheer" or "c_murmur", 0.7)
    else R(t, home and "c_boo" or "c_applause", 0.8) end
  elseif k == "wp" then
    R(1.0, home and "c_cheer" or "c_groan", 0.6)
  elseif k == "inc" then
    local kind = e.kind
    if kind == "EJECTION" or kind == "BRAWL" or kind == "BALL_TAMPERING" then R(0.7, "c_boo", 1)
    elseif kind == "FAN_ON_FIELD" or kind == "RACCOON_ON_FIELD" then R(1.0, "c_cheer", 0.8)
    else R(0.5, "c_murmur", 0.5) end
  elseif k == "end" then
    if (e.home or 0) > (e.away or 0) then R(0.4, "c_roar", 1) else R(0.4, "c_groan", 0.7) end
  end
end

function Play.plan(b, tl)
  local plan = newPlan()
  b.plan = plan
  if b.kind == "p" then planPitch(b, tl, plan)
  elseif b.kind == "bip" then planBip(b, tl, plan)
  else planOther(b, tl, plan) end
  reactions(b, plan)
  if #plan.cams == 0 then cam(plan, 0, "pitch") end
  table.sort(plan.cams, function(a, c) return a.t < c.t end)
  -- pitch + big moments: the strikeout that ends it, the final out of a close game, etc.
  return plan
end

---------------------------------------------------------------------------
-- drawing
--
-- Puppets play the animatic tracks (images/puppets/anim_tracks.json via ballcast/anim):
-- untweened held keys with squash/stretch, shake and vibrate, applied by the C billboard
-- transform. Idle puppets "boil" (a seeded 1 px jitter every 6-14 frames) so a field full
-- of them never moves in sync. Track times are offsets from plan times, so scrubbing is exact.

local FPS <const> = 30
local runFrame = function(tau) return (floor(tau * 8) % 2 == 0) and "run1" or "run2" end

-- key timings read from the track data (the moment that has to land on a plan time)
local KT = nil
local function keyTimes()
  if KT then return KT end
  KT = {
    pitchRel = Anim.keyTime("pitch_back", 5),       -- release key
    swingHit = Anim.keyTime("swing", 4),            -- contact key
    swingLen = Anim.length("swing"),
    recv = Anim.keyTime("catcher_receive", 2),       -- mitt pops
    cthrow = Anim.keyTime("catcher_throw", 2),
    ump = Anim.keyTime("ump_strike", 2),             -- the call
  }
  return KT
end

local BRAWL_TRACKS = { "dive", "pratfall", "backflip", "cartwheel" }
local MOB_TRACKS = { "celebrate", "celebrate", "backflip", "celebrate", "cartwheel", "celebrate" }

local function fielderAt(plan, pos, tau)
  local a = ALIGN[pos]
  local x, y = a[1], a[2]
  local moving, dir, ddx, ddy = false, 0, 0, 0
  local l = plan.fmoves[pos]
  if l then
    for i = 1, #l do
      local m = l[i]
      if tau >= m.t1 then x, y = m.x1, m.y1; ddx, ddy = m.x1 - m.x0, m.y1 - m.y0
      elseif tau > m.t0 then
        local u = (tau - m.t0) / (m.t1 - m.t0)
        x, y = m.x0 + (m.x1 - m.x0) * u, m.y0 + (m.y1 - m.y0) * u
        moving = true
        dir = m.x1 - m.x0
        ddx, ddy = m.x1 - m.x0, m.y1 - m.y0
        break
      else break end
    end
  end
  local pe = nil
  local lp = plan.fposes[pos]
  if lp then
    for i = 1, #lp do
      local p = lp[i]
      if tau >= p.t0 and tau <= p.t1 then pe = p end
    end
  end
  return x, y, moving, pe, dir, ddx, ddy
end
Play.fielderAt = fielderAt

-- does moving by dx in field x go left on screen? (for facing)
local function facesLeft(R, x, y, dx, dy)
  if (dx or 0) == 0 and (dy or 0) == 0 then return false end
  local a = R:project(x, y, 0)
  local b = R:project(x + (dx or 0), y + (dy or 0), 0)
  return a and b and b < a or false
end

--- puppet from an animatic track at track time tt. The facing flip mirrors the key's
--- rotation and x offset (a dive leans the way he's going); the key's own flip composes.
--- face (optional): world facing yaw (radians). With a facing the renderer picks the view
--- table for the current camera (puppets.lua P.orient); `flip` then means a mirrored
--- (left-handed) figure, and the renderer mirrors the key's lean when he faces screen-left.
local atan2 <const> = math.atan
local function yawTo(x, y, tx, ty) return atan2(ty - y, tx - x) end
local function yawOf(dx, dy, fallback) if (dx or 0) == 0 and (dy or 0) == 0 then return fallback end return atan2(dy, dx) end
Play.yawTo = yawTo
local function putTrack(R, variant, track, tt, x, y, z, flip, seed, vib, xrot, face)
  if R.far then R:dot(x, y, (z or 0) + 3, false, true); return false end   -- blimp: a dot
  if R.offscreen and R:offscreen(x, y, z or 0) then return false end      -- off screen: no work
  local tn, f, sx, sy, rot, dx, dy, kflip, piv, done = Anim.sample(track, tt, seed, vib)
  if not tn then local d = R.diag; if d then d.notrack = d.notrack + 1; d.lastNoTrack = track end; return true end
  if face then
    if xrot and xrot ~= 0 then rot, piv = rot + xrot, 20 end
    R:puppetT(variant, tn, f, x, y, z or 0, flip, sx, sy, rot, dx, dy, piv, face, seed, kflip)
    return done
  end
  flip = flip and true or false
  if flip then rot, dx = -rot, -dx end
  if xrot and xrot ~= 0 then rot, piv = rot + (flip and -xrot or xrot), 20 end
  R:puppetT(variant, tn, f, x, y, z or 0, flip ~= kflip, sx, sy, rot, dx, dy, piv)
  return done
end

--- a held logical frame (puppets.lua MAP) with the per-puppet boil (+ optional vibrate)
local function putIdle(R, variant, frame, x, y, z, flip, seed, n, vib, face)
  if R.far then R:dot(x, y, (z or 0) + 3, false, true); return end
  if R.offscreen and R:offscreen(x, y, z or 0) then return end
  local dx, dy = Anim.boil(seed, n)
  if vib and vib > 0 then
    local vx, vy = Anim.vibrate(seed, n, vib)
    dx, dy = dx + vx, dy + vy
  end
  R:puppet(variant, frame, x, y, z or 0, flip, dx, dy, face, seed)
end

-- pirouette: a quick untweened 360 (90/180/270 held 2 frames each), t = time since it began
local SPIN_LEN <const> = 0.2
local function spinRot(t)
  if not t or t < 0 or t >= SPIN_LEN then return 0 end
  return (floor(t * FPS / 2) + 1) * 90
end
-- some players are spinners (seeded per player): they pirouette rounding bases a lot more
local function isSpinner(id) return K.hash01(id or "?", 71) < 0.25 end
local function runnerSpin(r, tau, b, trot)
  local d = (tau - r.t0) * r.speed
  if d <= 0 then return nil end
  local k = floor(d / 90)
  if k < 1 or r.from + k >= r.target then return nil end   -- only rounding a bag, not arriving
  local since = (d - k * 90) / r.speed
  if since >= SPIN_LEN then return nil end
  local sp = isSpinner(r.id)
  local chance = sp and (trot and 0.85 or 0.5) or (trot and 0.3 or 0.08)
  if K.hash01(tostring(r.id) .. ":" .. b.i .. ":" .. k, 73) < chance then return since end
  return nil
end

--- dev: first (beat-local) time a runner pirouettes in beat b, or nil
function Play.findSpin(b)
  for i = 1, #b.plan.runners do
    local r = b.plan.runners[i]
    for t = r.t0, r.t1, 1 / 30 do
      if runnerSpin(r, t, b, b.plan.homerBatter and r.to == 4) then return t + 0.07 end
    end
  end
  return nil
end

-- the bat: tossed end over end as he breaks for first (a showy flip on a homer, a casual
-- drop on a walk), bounces once and lies by the plate. Drawn as a 1-bit line in 3D space.
local function drawBat(R, toss, tau, n)
  local t = tau - toss.t
  if t < 0 then return end
  local x, y, z, ang
  local dur, h, spin = toss.dur, toss.h, toss.spin
  if t < dur then
    local u = t / dur
    x, y = toss.x0 + (toss.x1 - toss.x0) * u, toss.y0 + (toss.y1 - toss.y0) * u
    z = toss.z0 * (1 - u) + 4 * h * u * (1 - u)
    ang = floor(t * spin * 8) * 45                  -- snapped to 45 degrees: animatic tumble
  elseif t < dur + 0.22 then
    local u = (t - dur) / 0.22
    x, y = toss.x1 + (toss.x1 - toss.x0) * 0.12 * u, toss.y1 + (toss.y1 - toss.y0) * 0.12 * u
    z = 4 * min(1.6, h * 0.12) * u * (1 - u)
    ang = floor(dur * spin * 8) * 45 + floor(u * 2) * 45
  else
    x, y = toss.x1 + (toss.x1 - toss.x0) * 0.12, toss.y1 + (toss.y1 - toss.y0) * 0.12
    z = 0.15
    ang = toss.rest
  end
  local sx, sy, d = R:project(x, y, z)
  if not sx then return end
  local L = K.clamp(R:ppf(d) * 2.8, 4, 70)
  local a = math.rad(ang)
  local cx, cy = math.cos(a) * L * 0.5, math.sin(a) * L * 0.5
  local w = L > 24 and 2 or 1
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(w + 2)
  gfx.drawLine(sx - cx, sy - cy, sx + cx, sy + cy)
  gfx.setColor(gfx.kColorWhite)
  gfx.setLineWidth(w)
  gfx.drawLine(sx - cx * 0.2, sy - cy * 0.2, sx + cx * 0.85, sy + cy * 0.85)   -- the barrel
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(1)
end

-- a catch: held keys around the moment the ball hits the glove (t = pe.ct)
--   reach: stretch up · SQUASH + shake on the pop · settle     scoop: crouch · squash · rise
local function drawCatch(R, variant, pe, x, y, tau, flip, seed, face)
  local k = tau - pe.ct
  if pe.catch == "dive" then
    putTrack(R, variant, "dive", k + 0.2, x, y, 0, flip, seed, nil, nil, face)
    return
  end
  local f, sx, sy, rot = 4, 1, 1, 0
  if pe.catch == "low" then
    f = 1
    if k < 0 then sx, sy = 1.12, 0.86
    elseif k < 0.1 then sx, sy, rot = 1.22, 0.8, (floor(k * FPS) % 2 == 0) and 4 or -4
    else sx, sy = 1.06, 0.94 end
  else
    if k < 0 then sx, sy = 0.9, 1.12
    elseif k < 0.1 then sx, sy, rot = 1.14, 0.88, (floor(k * FPS) % 2 == 0) and 5 or -5
    end
  end
  if face then R:puppetT(variant, "fielder", f, x, y, 0, false, sx, sy, rot, 0, 0, 0, face, seed, false); return end
  if flip then rot = -rot end
  R:puppetT(variant, "fielder", f, x, y, 0, flip, sx, sy, rot, 0, 0, 0)
end

-- the catcher's reach (animatic, no in-betweens): set → hard cut to the reach pose ~0.2 s before
-- the ball (a slight stretch toward it) → 2-frame squash + shake as it pops into the mitt →
-- the frame/stick hold → back to set. One prerendered cell per frame; the IK was done offline.
local function drawReach(R, variant, plan, x, y, tau, seed, vib)
  local t = tau - plan.receive
  local f, sx, sy, rot = plan.reach.f, 1, 1, 0
  if t < -0.2 then f = 1
  elseif t < -0.07 then sx, sy = 0.95, 1.06
  elseif t >= 0.05 and t < 0.12 then
    sx, sy = 1.12, 0.9
    rot = (floor(t * FPS) % 2 == 0) and 3 or -3
  elseif t >= 0.62 then f = 1 end
  if R.far then R:dot(x, y, 3, false, true) return end
  if R.offscreen and R:offscreen(x, y, 0) then return end
  local dx, dy = 0, 0
  if vib and vib > 0 then dx, dy = Anim.vibrate(seed, floor(tau * FPS), vib) end
  R:puppetT(variant, "catcher_reach", f, x, y, 0, false, sx, sy, rot, dx, dy, 0, math.pi / 2, seed, false)
end

-- LEAP_CATCH: untweened climb up the wall in held steps (z in feet), then the drop
local function drawLeap(R, variant, L, x, y, tau, flip, seed, face)
  local k = tau - L.t0
  local top = max(2, L.z - 6.5)
  if k < 0.12 then
    R:puppetT(variant, "fielder", 1, x, y, 0, flip, 1.22, 0.82, 0, 0, 0, 0, face, seed)               -- crouch
  elseif k < 0.22 then
    R:puppetT(variant, "fielder", 4, x, y, top * 0.4, flip, 0.88, 1.14, 0, 0, 0, 0, face, seed)        -- spring
  elseif k < 0.32 then
    R:puppetT(variant, "fielder", 4, x, y, top * 0.75, flip, 0.9, 1.11, flip and 6 or -6, 0, 0, 20, face, seed)
  elseif tau < L.tc + 0.18 then
    local vx, vy = Anim.vibrate(seed, floor(tau * FPS), 1)
    R:puppetT(variant, "fielder", 4, x, y, top, flip, 0.9, 1.12, 0, vx, vy, 0, face, seed)             -- up the wall
  elseif tau < L.land - 0.12 then
    R:puppetT(variant, "accent", 2, x, y, top * 0.45, flip, 1, 1, flip and 30 or -30, 0, 0, 20, face, seed) -- tumbling down
  else
    local sh = (floor(tau * FPS) % 2 == 0) and 5 or -5
    R:puppetT(variant, "fielder", 1, x, y, 0, flip, 1.22, 0.82, sh, 0, 0, 0, face, seed)              -- landed
  end
end

---------------------------------------------------------------------------
-- Enhanced League power effects (2D overlays, after the billboards). 1-bit and crude.

local function ballR(R, d) return K.clamp(R:ppf(d) * 0.6, 1.5, 7) end

-- "marching ants": the last ~0.7 s of the ball's path as a dashed line whose dashes crawl
-- toward the ball. Black dashes on white gaps, so it reads on grass, dirt and stands.
local antX, antY = {}, {}
local function drawAnts(R, plan, tau, n)
  local m = 0
  for k = 0, 7 do
    local t = tau - k * 0.085
    local x, y, z, s = ballAt(plan, t)
    if not x or (s and s.kind == "hold") then break end
    local sx, sy = R:project(x, y, z)
    if not sx then break end
    m = m + 1
    antX[m], antY[m] = sx, sy
  end
  if m < 2 then return end
  -- dashes laid along the polyline by arc length; the phase shifts 1 px per frame
  local DASH <const> = 6
  local phase = (-n) % (DASH * 2)      -- dashes crawl toward the ball
  local white, black = gfx.kColorWhite, gfx.kColorBlack
  gfx.setLineWidth(1)
  -- (device cost: one black polyline, then only the white cells on top — half the draw calls
  -- and one colour switch instead of one per dash)
  gfx.setColor(black)
  for i = 1, m - 1 do gfx.drawLine(antX[i], antY[i], antX[i + 1], antY[i + 1]) end
  gfx.setColor(white)
  local s0 = 0                       -- arc length at the start of this segment
  for i = 1, m - 1 do
    local x0, y0, x1, y1 = antX[i], antY[i], antX[i + 1], antY[i + 1]
    local dx, dy = x1 - x0, y1 - y0
    local len = sqrt(dx * dx + dy * dy)
    if len >= 1 then
      -- whole dash cells overlapping this segment (integer counter: always terminates)
      local c0 = floor((s0 + phase) / DASH)
      local c1 = floor((s0 + len + phase) / DASH)
      if c0 % 2 == 0 then c0 = c0 + 1 end          -- odd cells are the white ones
      local il = 1 / len
      for c = c0, c1, 2 do
        local a = max(0, c * DASH - phase - s0)
        local e = min(len, (c + 1) * DASH - phase - s0)
        if e > a then
          gfx.drawLine(x0 + dx * a * il, y0 + dy * a * il, x0 + dx * e * il, y0 + dy * e * il)
        end
      end
      s0 = s0 + len
    end
  end
  gfx.setColor(black)
end

local function drawFx(R, plan, tau, n)
  local white, black = gfx.kColorWhite, gfx.kColorBlack
  local pitch = plan.pitch

  -- power-up: dashed rings around whoever is charging
  local pv = plan.powerVib
  if pv and tau >= pv.t0 and tau < pv.t1 then
    local px, py, pz = 0, 60, 3.2
    if pv.who == "B" and pitch then px, py = -pitch.side * 3.2, 0.2 end
    local sx, sy, d = R:project(px, py, pz)
    if sx then
      local base = K.clamp(R:ppf(d) * 3.4, 10, 60)
      for k = 0, 1 do
        local r = base + ((n + k * 2) % 4) * 3
        gfx.setColor(k == 0 and black or white)
        gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
        gfx.setLineWidth(2)
        gfx.drawCircleAtPoint(sx, sy, r)
      end
      gfx.setColor(black)
      gfx.setLineWidth(1)
    end
  end

  if pitch then
    local inFlight = tau >= pitch.tRel and tau <= pitch.tPlate
    -- FIREBALL: a guttering flame trail behind the ball
    if plan.fire and inFlight then
      local bx, by, bz = ballAt(plan, tau)
      local sx0, sy0, d0 = R:project(bx, by, bz)
      if sx0 then
        local r0 = ballR(R, d0)
        -- a jagged comet of flame back along the flight path, flickering every frame
        local tx, ty, tz = ballAt(plan, max(pitch.tRel, tau - 0.16))
        local ex, ey = R:project(tx, ty, tz)
        local ddx, ddy = (ex or sx0) - sx0, (ey or sy0) - sy0
        local len = sqrt(ddx * ddx + ddy * ddy)
        if len < 14 then ddx, ddy, len = 0, 14, 14 end
        local nx, ny = -ddy / len, ddx / len
        local w = r0 * 1.8 + 2
        for layer = 1, 2 do
          local sc = layer == 1 and 1 or 0.5
          local pts = {}
          local m = 6
          for j = 0, m do           -- one side, ball → tip
            local u = j / m
            local h = Anim.ih(n, j + layer * 10, 4)
            local jag = (j % 2 == 0) and 1 or (0.45 + (h % 4) * 0.1)
            local ww = w * sc * (1 - u) * jag
            pts[#pts + 1] = sx0 + ddx * u * 1.3 * sc + nx * ww
            pts[#pts + 1] = sy0 + ddy * u * 1.3 * sc + ny * ww
          end
          for j = m - 1, 1, -1 do   -- the other side back
            local u = j / m
            local h = Anim.ih(n, j + layer * 20, 6)
            local jag = (j % 2 == 1) and 1 or (0.45 + (h % 4) * 0.1)
            local ww = w * sc * (1 - u) * jag
            pts[#pts + 1] = sx0 + ddx * u * 1.3 * sc - nx * ww
            pts[#pts + 1] = sy0 + ddy * u * 1.3 * sc - ny * ww
          end
          if layer == 1 then gfx.setColor(black)
          else
            gfx.setColor(white)
            if n % 2 == 1 then gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2) end
          end
          gfx.fillPolygon(table.unpack(pts))
        end
        gfx.setColor(black)
        gfx.fillCircleAtPoint(sx0, sy0, r0 + 2)
        gfx.setColor(white)
        gfx.fillCircleAtPoint(sx0, sy0, r0)
        -- sparks
        gfx.setColor(black)
        for k = 1, 6 do
          local h = Anim.ih(n, k, 9)
          gfx.fillRect(sx0 - 14 + h % 28, sy0 - 16 + (h // 28) % 22, 2, 2)
        end
      end
    end
    -- STOPPER: the hanging ball hums
    if plan.stall and tau >= plan.stall[1] and tau < plan.stall[2] then
      local bx, by, bz = ballAt(plan, tau)
      local sx, sy, d = R:project(bx, by, bz)
      if sx then
        local r = ballR(R, d)
        gfx.setColor(black)
        gfx.setLineWidth(1)
        gfx.drawCircleAtPoint(sx, sy, r + 4 + (n % 3) * 3)
        gfx.drawCircleAtPoint(sx, sy, r + 12 + (n % 2) * 4)
        -- "stopped" tick marks
        for k = 0, 3 do
          local a = k * 1.5708 + 0.785
          gfx.drawLine(sx + cos(a) * (r + 6), sy + sin(a) * (r + 6), sx + cos(a) * (r + 10), sy + sin(a) * (r + 10))
        end
      end
    end
    -- WARP_PITCH: it blinks out and pops in somewhere else
    if plan.warp and abs(tau - plan.warp) < 0.22 then
      local k = tau - plan.warp
      for side = 0, 1 do
        local tx, ty, tz = ballAt(plan, plan.warp + (side == 0 and -0.001 or 0.001))
        local sx, sy, d = R:project(tx, ty, tz)
        local show = (side == 0 and k > -0.08) or (side == 1 and k > -0.04)
        if sx and show then
          local r = ballR(R, d)
          local g = 6 + abs(k) * 110
          gfx.setColor((n % 2 == 0) and black or white)
          gfx.setLineWidth(2)
          gfx.drawLine(sx - g, sy, sx + g, sy)
          gfx.drawLine(sx, sy - g, sx, sy + g)
          gfx.setLineWidth(1)
          gfx.setColor(black)
          gfx.drawLine(sx - g * 0.6, sy - g * 0.6, sx + g * 0.6, sy + g * 0.6)
          gfx.drawLine(sx - g * 0.6, sy + g * 0.6, sx + g * 0.6, sy - g * 0.6)
          if side == 0 then
            gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
            gfx.drawCircleAtPoint(sx, sy, r + g * 0.5)
            gfx.setColor(black)
          end
        end
      end
    end
    -- CLOUD_BALL: the ball dissolves into a dithered puff that drifts in
    if plan.cloud and tau >= plan.cloud[1] and tau < plan.cloud[2] then
      local k = tau - plan.cloud[1]
      for j = 3, 0, -1 do
        local tx, ty, tz = ballAt(plan, max(plan.cloud[1], tau - j * 0.05))
        local sx, sy, d = R:project(tx, ty, tz)
        if sx then
          local r = ballR(R, d)
          local rr = r * (2.2 + min(k, 0.3) * 7) - j * 2
          local h = Anim.ih(n, j, 5)
          if rr > 1 then
            gfx.setColor(white)
            gfx.setDitherPattern(0.25 + j * 0.15, gfx.image.kDitherTypeBayer4x4)
            gfx.fillCircleAtPoint(sx + (h % 3) - 1, sy + ((h // 3) % 3) - 1, rr)
            if j == 0 then
              gfx.setColor(black)
              gfx.setDitherPattern(0.75, gfx.image.kDitherTypeBayer4x4)
              gfx.fillCircleAtPoint(sx - rr * 0.4, sy - rr * 0.2, rr * 0.55)
              gfx.fillCircleAtPoint(sx + rr * 0.5, sy + rr * 0.1, rr * 0.45)
            end
          end
        end
      end
      gfx.setColor(black)
    end
  end

  -- LASER_ARM: every throw is a beam
  if plan.laser then
    local _, _, _, s = ballAt(plan, tau)
    if s and s.throw then
      local bx, by, bz = ballAt(plan, tau)
      local ax, ay = R:project(s.ax, s.ay, s.az)
      local cx, cy = R:project(bx, by, bz)
      if ax and cx then
        gfx.setColor(black)
        gfx.setLineWidth(7)
        gfx.drawLine(ax, ay, cx, cy)
        gfx.setColor(white)
        gfx.setLineWidth(n % 2 == 0 and 4 or 3)
        gfx.drawLine(ax, ay, cx, cy)
        gfx.setColor(black)
        gfx.setLineWidth(1)
        gfx.drawLine(ax, ay, cx, cy)
        gfx.fillCircleAtPoint(cx, cy, 5)
        gfx.setColor(white)
        gfx.fillCircleAtPoint(cx, cy, 3)
        gfx.setColor(black)
      end
    end
  end

  -- HYPER_HIT: the screen flashes and the ball leaves a fat streak
  if plan.hyperT then
    local k = tau - plan.hyperT
    if k >= 0 and k < 0.45 then
      local cx, cy = 200, 150
      if plan.hyperBip then
        local bx, by, bz = ballAt(plan, tau)
        if bx then cx, cy = R:project(bx, by, bz) end
        cx, cy = cx or 200, cy or 150
      else
        local px, py = R:project(0, 0.5, 3)
        if px then cx, cy = px, py end
      end
      if k < 0.07 then
        gfx.setColor(white)
        gfx.fillRect(0, 0, 400, 240)
      elseif k < 0.14 then
        gfx.setColor(white)
        gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
        gfx.fillRect(0, 0, 400, 240)
      end
      gfx.setColor(black)
      gfx.setLineWidth(k < 0.14 and 3 or 2)
      local rays = 16
      for i = 0, rays - 1 do
        local a = i / rays * 6.2832 + (n % 2) * 0.19
        local r0 = 8 + k * 260
        local r1 = r0 + 30 + (i % 3) * 22
        gfx.drawLine(cx + cos(a) * r0, cy + sin(a) * r0, cx + cos(a) * r1, cy + sin(a) * r1)
      end
      gfx.setLineWidth(1)
    end
    if plan.hyperBip and k >= 0 then
      -- streak behind the ball for the whole flight
      local bx, by, bz, s = ballAt(plan, tau)
      if bx and s and s.kind == "path" then
        local px, py = R:project(bx, by, bz)
        for j = 1, 4 do
          local tx, ty, tz = ballAt(plan, max(0, tau - j * 0.06))
          local qx, qy = R:project(tx, ty, tz)
          if px and qx then
            gfx.setColor(black)
            gfx.setLineWidth(6 - j)
            gfx.drawLine(px, py, qx, qy)
            gfx.setColor(white)
            gfx.setLineWidth(max(1, 3 - j))
            gfx.drawLine(px, py, qx, qy)
          end
          px, py = qx, qy
        end
        gfx.setColor(black)
        gfx.setLineWidth(1)
      end
    end
  end
end
Play.drawFx = drawFx

-- nametags: pitcher + batter on the pitch; the man making the play + runners on balls in play
local drawTags
local function lastNameOf(people, id)
  local p = id and people[id]
  return p and p.name and K.lastName(p.name) or nil
end
-- the defense's player at a position (the log only names positions), by team + listed pos
local function fielderName(view, pitId, pos)
  local people = view.people or {}
  local pit = pitId and people[pitId]
  if pos == "P" then return lastNameOf(people, pitId) end
  local team = pit and pit.teamAbbr
  if not team then return pos end
  local idx = view.posIdx
  if not idx or idx.people ~= people then
    idx = { people = people }
    for id, q in pairs(people) do
      if q.teamAbbr and q.pos then idx[q.teamAbbr .. ":" .. q.pos] = id end
    end
    view.posIdx = idx
  end
  local id = idx[team .. ":" .. pos]
  return id and lastNameOf(people, id) or pos
end

drawTags = function(R, view, b, tau)
  local Tags = BallCast.Tags
  if R.far then Tags.begin(); Tags.draw(R); return end   -- blimp: no nametags (dots)
  local plan, pre = b.plan, b.pre
  local people = view.people or {}
  Tags.begin()
  if plan.pitch or b.kind == "pa" or b.kind == "sub" then
    -- pitcher and batter are already named by the scorebug and the lower third: no tags
  else
    local c = nil
    for i = 1, #plan.catches do
      local q = plan.catches[i]
      if tau >= q.t0 - 0.6 and tau <= q.ct + q.hold + 0.4 then c = q end
    end
    if c then
      local x, y = fielderAt(plan, c.pos, tau)
      if c.pos == "C" then x, y = 0, -3.2 end
      Tags.want(fielderName(view, pre.pit, c.pos), x, y, 3)
    end
    for i = 1, #plan.runners do
      local r = plan.runners[i]
      if tau >= r.t0 and tau <= r.t1 + 0.4 then
        local x, y = runnerPos(r, tau)
        Tags.want(lastNameOf(people, r.id), x, y, r.from == 0 and 2 or 1)
      end
    end
  end
  Tags.draw(R)
end

--- Queue puppets + ball for the beat at tau into renderer R, then R:finish(); popups after.
local FACE_CF <const> = math.pi / 2      -- catcher / umpire face out toward the mound
-- slides: some runners go in head-first (seeded per player); safe → pop-up, out → slump
local function slideTrack(id, safe)
  local head = K.hash01(tostring(id), 91) < 0.35
  if Anim.has and not Anim.has("slide_safe") then return "slide" end
  return (head and "slide_head_" or "slide_") .. (safe and "safe" or "out")
end
-- world-pass sub-timers for the device: [bcworld] breakdown when a frame's world pass is slow
local WT, worldAcc = {}, nil
local WT_NAMES <const> = { "pre+juice", "defense", "ump", "batter", "onbase", "runners", "crowd/inc", "ball", "flush", "fx", "tags", "pops" }
local clk = playdate.getElapsedTime
Play.worldSpikeMs = 18
worldAcc = {}
function Play.worldReport()
  for cam, acc in pairs(worldAcc) do
    if acc.n > 0 then
      local parts, tot = {}, 0
      for i = 1, 12 do tot = tot + acc[i]; parts[i] = string.format("%s %.2f", WT_NAMES[i], acc[i] / acc.n * 1000) end
      print(string.format("[bcworld] avg cam=%s %.2f ms over %d frames | %s", cam, tot / acc.n * 1000, acc.n, table.concat(parts, " ")))
    end
  end
  worldAcc = {}
end
--- view: { defV, offV, incident, brawl }
function Play.drawWorld(R, view, b, tau)
  WT[1] = clk()
  -- device check: one summary per scene at the first pitch (are the puppets really drawn?)
  if R.diag and not R.diag.said and b.kind == "p" and tau > 1.0 and BallCast.scene and BallCast.scene.mode == "watch" then
    R.diag.said = true
    BallCast.Puppets.snapshot("first pitch", R.diag)     -- printed at scene exit (no mid-play prints)
  end
  -- the stands react: a rolling wave and camera flashes on the big moments (C crowd heads)
  do
    local plan0 = b.plan
    local big = b.big or plan0.homerBatter or b.walkoff
    local tm = plan0.wallT or plan0.scoreT or plan0.shake or plan0.catchT or 0.5
    R.crowdWave = (big and tau > tm + 0.4) and 1 or 0
    R.crowdFlash = (big and tau > tm - 0.6) and 1 or ((b.k and plan0.kT and tau > plan0.kT and tau < plan0.kT + 1.5) and 0.4 or 0)
  end
  -- dust, skids, slide plumes: drawn now, under the billboards the C flush draws later
  BallCast.Juice.ground(R, b, tau)
  local plan = b.plan
  local defV, offV = view.defV, view.offV
  local pre = b.pre
  local kt = keyTimes()
  local n = floor(((b.start or 0) + tau) * FPS)    -- boil clock (global, so beats don't reset it)
  local big = plan.bigVib and 1 or nil              -- ejection / brawl: everyone's rattled
  local pv = plan.powerVib
  local powerOn = pv and tau >= pv.t0 and tau < pv.t1
  local isEnd = b.kind == "end"

  WT[2] = clk()
  -- defense
  local pitchPlan = plan.pitch
  local relT = pitchPlan and pitchPlan.tRel or plan.relT
  if not isEnd then
    for i = 1, #POSLIST do
      local pos = POSLIST[i]
      local seed = i * 97 + 13
      local x, y, moving, pe, dir, ddx, ddy = fielderAt(plan, pos, tau)
      local flip = moving and facesLeft(R, x, y, dir, 0)
      if view.brawl then
        local a = ALIGN[pos]
        local u = K.clamp((tau - 0.5) / 2.0, 0, 1)
        x, y = a[1] + (0 - a[1]) * u + (i - 5) * 2.5, a[2] + (45 - a[2]) * u + (i % 3) * 2
        flip = a[1] > 0
        if u < 1 then
          putIdle(R, defV, runFrame(tau + i * 0.1), x, y, 0, false, seed, n, 1, yawTo(x, y, 0, 45))
        else
          -- the scrum: everyone cycles through dives, falls, flips, out of sync
          local ph = (tau - 2.5) + K.hash01(i, 3) * 2.7
          local slot = floor(ph / 0.9)
          local tr = BRAWL_TRACKS[1 + (slot + i) % #BRAWL_TRACKS]
          putTrack(R, defV, tr, ph - slot * 0.9, x, y, 0, false, seed, 1, nil, (slot * 2.3 + i * 1.7) % 6.283)
        end
      elseif plan.leap and plan.leap.pos == pos and tau >= plan.leap.t0 and tau < plan.leap.land then
        drawLeap(R, defV, plan.leap, x, y, tau, false, seed, yawTo(0, 0, x, y))
      elseif pos == "P" and relT and not pe then
        -- windup: pitch_back's release key lands on the ball's release
        x, y = 0, 60
        local t0 = relT - kt.pitchRel
        local vib = (powerOn and pv.who == "P") and 1 or big
        local pf = yawTo(x, y, 0, 0)
        if tau < t0 then putIdle(R, defV, "set", x, y, 0, false, seed, n, vib, pf)
        elseif tau < relT + 0.8 then putTrack(R, defV, "pitch_back", tau - t0, x, y, 0, false, seed, vib, nil, pf)
        else putIdle(R, defV, "ready", x, y, 0, false, seed, n, big, pf) end
      elseif pos == "C" and not pe then
        x, y = 0, -3.2
        if plan.reach and tau >= plan.receive - 0.25 and tau < plan.receive + 0.75 then
          drawReach(R, defV, plan, x, y, tau, seed, big)
        elseif plan.receive and tau >= plan.receive - kt.recv and tau < plan.receive + 0.7 then
          putTrack(R, defV, "catcher_receive", tau - (plan.receive - kt.recv), x, y, 0, false, seed, big, nil, FACE_CF)
        elseif plan.cthrow and tau >= plan.cthrow - kt.cthrow and tau < plan.cthrow + 0.6 then
          putTrack(R, defV, "catcher_throw", tau - (plan.cthrow - kt.cthrow), x, y, 0, false, seed, big, nil, FACE_CF)
        else
          putIdle(R, defV, "catcher", x, y, 0, false, seed, n, big, FACE_CF)
        end
      elseif pe and pe.catch then
        if pos == "C" then x, y = 0, -3.2 end
        drawCatch(R, defV, pe, x, y, tau, false, seed, yawOf(ddx, ddy, yawTo(x, y, 0, 0)))
      elseif pe and pe.track then
        if pos == "C" then x, y = 0, -3.2 end
        local fc = yawOf(ddx, ddy, yawTo(x, y, 0, 0))
        if pe.track == "fielder_throw" then fc = yawOf(-x, 60 - y, fc) end
        putTrack(R, defV, pe.track, tau - pe.t0, x, y, 0, false, seed, pe.vib or big, nil, fc)
      else
        local frame = (pe and pe.pose) or (moving and runFrame(tau + i * 0.05)) or "ready"
        if pos == "P" and not pe and not moving then frame = (b.kind == "pa" or b.kind == "sub") and "set" or "ready" end
        if pos == "C" then x, y = 0, -3.2; if not pe then frame = "catcher" end end
        if moving then
          -- fielders on the run: alternate stride frames with a little bob
          local up = frame == "run2" and -1 or 0
          R:puppet(defV, frame, x, y, 0, false, 0, up, yawOf(ddx, ddy, 0), seed)
        else
          putIdle(R, defV, frame, x, y, 0, false, seed, n, big, yawTo(x, y, 0, 0))
        end
      end
    end
  end

  WT[3] = clk()
  -- umpire
  local uc = nil
  for i = 1, #plan.umpCalls do
    local c = plan.umpCalls[i]
    if tau >= c.t - kt.ump and tau < c.t + c.dur then uc = c end
  end
  if view.incident == "EJECTION" and tau > 0.6 then
    -- "YER OUTTA HERE": the punch-out, over and over, shaking
    putTrack(R, "ump", "ump_strike", kt.ump + (tau - 0.6) % 0.7, 0, -6.6, 0, false, 51, 2, nil, FACE_CF)
  elseif uc then
    putTrack(R, "ump", uc.track, tau - (uc.t - kt.ump), 0, -6.6, 0, false, 51, uc.vib, nil, FACE_CF)
  elseif plan.reach and tau >= plan.receive - 0.1 and tau < plan.receive + 0.5 and not R.far
      and not (R.offscreen and R:offscreen(0, -6.6, 0)) then
    -- the umpire leans with the pitch (a few degrees toward where the mitt went)
    local lean = K.clamp(plan.reach.x * 2.5, -5, 5)
    R:puppetT("ump", "umpire", 1, 0, -6.6, 0, false, 1, 1, lean, 0, 0, 20, FACE_CF, 51, false)
  else
    putIdle(R, "ump", "ump", 0, -6.6, 0, false, 51, n, big, FACE_CF)
  end

  WT[4] = clk()
  -- batter (until he becomes a runner)
  local batterRunning = false
  for i = 1, #plan.runners do if plan.runners[i].from == 0 and tau >= plan.runners[i].t0 then batterRunning = true end end
  if b.kind ~= "half" and not isEnd and pre.bat and not batterRunning and not view.brawl then
    local side = batSide(pre.bat)
    -- RHB stands on the 3B side (x < 0); the table is a RHB as seen from CF
    local x, y, fl = -side * 3.2, 0.2, side < 0
    local bf = side < 0 and math.pi or 0         -- faces the plate (lefties: mirrored figure)
    local seed = 61
    local vib = (powerOn and pv.who == "B") and 1 or big
    if plan.kT and tau > plan.kT and tau < plan.kT + 0.5 then vib = 1 end   -- strikeout: a jolt
    if b.kind == "bip" then
      if plan.homerBatter then putTrack(R, offV, "homer_batter", tau, x, y, 0, fl, seed, vib, nil, bf)
      else putTrack(R, offV, "swing", kt.swingLen + tau, x, y, 0, fl, seed, vib, nil, bf) end
    elseif plan.hbp and tau >= plan.hbp then
      putTrack(R, offV, "pratfall", tau - plan.hbp, x, y, 0, fl, seed, 1, nil, bf)
    elseif plan.swing then
      local t0 = plan.swing + 0.12 - kt.swingHit
      if tau < t0 then putIdle(R, offV, "stance", x, y, 0, fl, seed, n, vib, bf)
      elseif plan.hyperWhiff and tau > t0 + kt.swingLen then
        -- swung so hard he corkscrewed himself into the dirt
        putTrack(R, offV, "pratfall", tau - t0 - kt.swingLen, x, y, 0, fl, seed, 1, nil, bf)
      else putTrack(R, offV, "swing", tau - t0, x, y, 0, fl, seed, vib, nil, bf) end
    else
      putIdle(R, offV, "stance", x, y, 0, fl, seed, n, vib, bf)
    end
  end

  WT[5] = clk()
  -- runners holding their bases
  local movingIds = view.movingIds or {}
  view.movingIds = movingIds
  for k in pairs(movingIds) do movingIds[k] = nil end
  for i = 1, #plan.runners do movingIds[plan.runners[i].id] = true end
  local bases = view.bases or {}
  view.bases = bases
  bases[1], bases[2], bases[3] = pre.b1, pre.b2, pre.b3
  if not isEnd then
    for bi = 1, 3 do
      local id = bases[bi]
      if id and not movingIds[id] then
        local x, y = basePos(bi)
        putIdle(R, offV, "stand", x - 4, y - 2, 0, false, 200 + bi * 7, n, big, yawTo(x - 4, y - 2, 0, 0))
      end
    end
  end
  WT[6] = clk()
  -- moving runners
  for i = 1, #plan.runners do
    local r = plan.runners[i]
    local x, y, mv = runnerPos(r, tau)
    local seed = 300 + i * 31
    if r.to == 4 and tau > r.t1 + ((plan.homerBatter or b.walkoff) and 1.4 or 0.8) then x = nil end
    if r.to == -1 and tau > r.t1 + 1.6 then x = nil end
    if x then
      local nx, ny = basePos(math.min(r.target, r.from + 1 + floor(max(0, (tau - r.t0) * r.speed) / 90)))
      local rf = yawOf(nx - x, ny - y, yawTo(x, y, 0, 0))   -- toward the next base
      if r.to == -1 and tau > r.t1 then
        if r.role == "batter" then
          -- peels off: turns around, trudges back
          if tau < r.t1 + 0.3 then putTrack(R, offV, "turn", tau - r.t1, x, y, 0, false, seed, nil, nil, rf)
          else putIdle(R, offV, "walk1", x, y, 0, false, seed, n, nil, rf + math.pi) end
        else
          -- thrown out: the slide (feet-first or head-first), then the slump; then he trudges off
          local tr = slideTrack(r.id, false)
          if tau < r.t1 + Anim.length(tr) + 0.6 then putTrack(R, offV, tr, tau - r.t1, x, y, 0, false, seed, nil, nil, rf)
          else putIdle(R, offV, "walk1", x, y, 0, false, seed, n, nil, rf) end
        end
      elseif plan.slide and plan.slide.id == r.id and tau > plan.slide.t
          and tau < plan.slide.t + Anim.length(slideTrack(r.id, plan.slide.safe)) + 0.6 then
        putTrack(R, offV, slideTrack(r.id, plan.slide.safe), tau - plan.slide.t, x, y, 0, false, seed, nil, nil, rf)
      elseif r.to == 4 and tau > r.t1 then
        local hype = plan.homerBatter or b.walkoff
        -- spinners (and the odd happy guy) twirl as they cross the plate
        local tw = (isSpinner(r.id) or K.hash01(tostring(r.id) .. b.i, 77) < 0.3) and spinRot(tau - r.t1 - 0.05) or 0
        putTrack(R, offV, "celebrate", tau - r.t1, x, y, 0, false, seed, hype and 1 or nil, tw)
      elseif mv then
        local vib = (plan.trotVib and r.from == 0 and tau < r.t0 + 1.2) and 1 or big
        if plan.warpRun == r.id then
          -- WARP_RUN: flickering afterimages strung out behind him
          vib = 1
          for k = 3, 1, -1 do
            if (n + k) % 2 == 0 then
              local gx, gy = runnerPos(r, tau - k * 0.09)
              putTrack(R, offV, "run", tau - k * 0.09 - r.t0, gx, gy, 0, false, seed + k, nil, nil, rf)
            end
          end
        end
        local st = runnerSpin(r, tau, b, plan.homerBatter and r.to == 4)
        putTrack(R, offV, "run", tau - r.t0 + i * 0.07, x, y, 0, false, seed, vib, spinRot(st), rf)
      else
        putIdle(R, offV, "stand", x, y, 0, false, seed, n, big, rf)
      end
    end
  end

  WT[7] = clk()
  -- walk-off: the dugout empties onto home plate
  if b.walkoff and plan.scoreT and tau > plan.scoreT then
    for i = 1, 6 do
      local a = i * 1.047
      local tr = MOB_TRACKS[i]
      local ph = tau - plan.scoreT + K.hash01(i, 4) * 0.6
      local len = Anim.length(tr) + 0.3
      local tw = (i % 3 == 0) and spinRot((tau + i * 0.41) % 1.7) or 0
      putTrack(R, offV, tr, ph % len, cos(a) * 7, 4 + sin(a) * 5, 0, false, 600 + i, 1, tw, yawTo(cos(a) * 7, 4 + sin(a) * 5, 0, 4))
    end
  end

  -- final: the winners mob the mound; the mascot works the line
  if isEnd then
    local e = b.e
    local winV = ((e.home or 0) >= (e.away or 0)) and "home" or "away"
    for i = 1, 9 do
      local a = i * 0.698
      local tr = MOB_TRACKS[1 + i % #MOB_TRACKS]
      local len = Anim.length(tr) + 0.25 + K.hash01(i, 5) * 0.4
      local tw = (i % 4 == 1) and spinRot((tau + i * 0.53) % 2.1) or 0
      putTrack(R, winV, tr, (tau + K.hash01(i, 8) * 2) % len, cos(a) * 10, 58 + sin(a) * 8, 0, false, 500 + i, 1, tw, yawTo(cos(a) * 10, 58 + sin(a) * 8, 0, 58))
    end
  end
  if b.kind == "half" or isEnd then
    putTrack(R, "home", "mascot_wave", tau, 62, 22, 0, false, 777)
  end

  -- incident critters
  local inc = view.incident
  if inc == "RACCOON_ON_FIELD" then
    local u = tau / 2.6
    local x, y = -90 + 200 * u, 40 + 70 * sin(u * 5)
    putIdle(R, "critter", (floor(tau * 10) % 2 == 0) and "raccoon1" or "raccoon2", x, y, 0, false, 41, n)
    if u > 0.7 then putTrack(R, defV, "dive", tau - 0.7 * 2.6, x - 25, y + 6, 0, false, 42, nil, nil, 0)
    else putIdle(R, defV, runFrame(tau), x - 25, y + 6, 0, false, 42, n, nil, 0) end
  elseif inc == "FAN_ON_FIELD" then
    local u = tau / 2.6
    local x, y = -150 + 300 * u, 220 + 40 * sin(u * 3)
    putTrack(R, "fan", "streaker", tau, x, y, 0, false, 43, nil, nil, 0)
    putIdle(R, "ump", "ump", x - 30, y + 5, 0, false, 44, n, 1, 0)
    putIdle(R, "ump", "ump", x - 45, y - 6, 0, false, 45, n, 1, 0)
  end

  WT[8] = clk()
  -- ball + dotted trail
  local bx, by, bz = ballAt(plan, tau)
  local inGlove = false
  for i = 1, #plan.catches do
    local c = plan.catches[i]
    if tau >= c.ct and tau < c.ct + c.hold then
      -- it's in his glove: ride with him, drawn in front of him
      local gx, gy = fielderAt(plan, c.pos, tau)
      if c.pos == "C" then gx, gy = 0, -3.2 end
      bx, by, bz = gx, gy, GLOVE_Z[c.catch] or 5
      inGlove = true
    end
  end
  local hide = false
  if plan.warp and abs(tau - plan.warp) < 0.08 then hide = true end
  if plan.cloud and tau > plan.cloud[1] + 0.1 and tau < plan.cloud[2] then hide = true end
  if bx and plan.stall and tau >= plan.stall[1] and tau < plan.stall[2] then bx = bx + ((n % 2 == 0) and 0.15 or -0.15) end
  if bx and not hide then
    -- shadow only on the field (not up in the seats on a homer)
    local shadow = not inGlove
    if shadow and R.park then
      local d = sqrt(bx * bx + by * by)
      if d > 60 then shadow = d < Cam.fenceAt(R.park, math.deg(math.atan(bx, by))) - 2 end
    end
    R:ball(bx, by, bz, nil, inGlove and 3 or 0, shadow)
  end
  WT[9] = clk()
  R:finish()
  WT[10] = clk()
  if bx and not hide and not inGlove and not plan.pitch then drawAnts(R, plan, tau, n) end
  drawFx(R, plan, tau, n)
  BallCast.Juice.over(R, b, tau)        -- impact flashes, pops, streaks (juice.lua)
  if plan.batToss and not view.brawl then drawBat(R, plan.batToss, tau, n) end
  WT[11] = clk()
  -- calls ("OUT!", "SAFE!") take the moment: no nametags while one is up
  local popUp = false
  for i = 1, #plan.pops do
    local p = plan.pops[i]
    if tau >= p.t and tau <= p.t + p.dur then popUp = true break end
  end
  if view.tags and not popUp and not isEnd and b.kind ~= "half" and b.kind ~= "inc" then drawTags(R, view, b, tau) end

  WT[12] = clk()
  -- popups ("OUT!", "SCORES!")
  local font = K.fonts.nb
  for i = 1, #plan.pops do
    local p = plan.pops[i]
    if tau >= p.t and tau <= p.t + p.dur then
      local sx, sy = R:project(p.x, p.y, p.z)
      if sx then
        local rise = (tau - p.t) * 10
        local w = font:getTextWidth(p.text) + 6
        local x0 = K.clamp(sx - w / 2, 2, 398 - w)
        local y0 = K.clamp(sy - 16 - rise, 40, 196)
        gfx.setColor(gfx.kColorBlack)
        gfx.fillRect(x0, y0, w, 15)
        gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
        font:drawText(p.text, x0 + 3, y0 + 1)
        gfx.setImageDrawMode(gfx.kDrawModeCopy)
      end
    end
  end
  WT[13] = clk()
  -- per-camera averages of each section (printed once at scene exit: Play.worldReport)
  local cam = BallCast.scene and BallCast.scene.curCam or "?"
  local acc = worldAcc[cam]
  if not acc then acc = { n = 0 }; for i = 1, 12 do acc[i] = 0 end; worldAcc[cam] = acc end
  for i = 1, 12 do acc[i] = acc[i] + (WT[i + 1] - WT[i]) end
  acc.n = acc.n + 1
  local total = (WT[13] - WT[1]) * 1000
  if total > Play.worldSpikeMs then
    local parts = {}
    for i = 1, 12 do parts[i] = string.format("%s %.1f", WT_NAMES[i], (WT[i + 1] - WT[i]) * 1000) end
    print(string.format("[bcworld] %.1f ms beat=%s(%s) tau=%.2f | %s", total, tostring(b.i), b.kind, tau, table.concat(parts, " ")))
  end
end

--- The lead runner's position at tau (the one still running, farthest along), or nil.
function Play.leadRunner(plan, tau)
  local best, bx, by = -1, nil, nil
  for i = 1, #plan.runners do
    local r = plan.runners[i]
    if tau >= r.t0 - 0.3 and tau <= r.t1 + 0.6 then
      local x, y = runnerPos(r, tau)
      local prog = r.from * 90 + max(0, tau - r.t0) * r.speed
      if prog > best then best, bx, by = prog, x, y end
    end
  end
  return bx, by
end

--- Bounding box (field ft) of what matters at tau: the ball, fielders with a catch/throw
--- around now (and where they're headed), moving runners. → x0, x1, y0, y1, ballZ | nil
function Play.interest(plan, tau)
  local x0, x1, y0, y1 = 1e9, -1e9, 1e9, -1e9
  local n = 0
  local function add(x, y)
    if x < x0 then x0 = x end
    if x > x1 then x1 = x end
    if y < y0 then y0 = y end
    if y > y1 then y1 = y end
    n = n + 1
  end
  local bx, by, bz = ballAt(plan, tau)
  if bx then add(bx, by) end
  for i = 1, #plan.catches do
    local c = plan.catches[i]
    if tau > c.t0 - 0.8 and tau < c.ct + c.hold + 0.2 then
      local x, y = fielderAt(plan, c.pos, c.ct)
      add(x, y)
      local cx, cy = fielderAt(plan, c.pos, tau)
      add(cx, cy)
    end
  end
  for i = 1, #plan.runners do
    local r = plan.runners[i]
    if tau >= r.t0 and tau <= r.t1 + 0.3 then
      local x, y = runnerPos(r, tau)
      add(x, y)
    end
  end
  if n == 0 then return nil end
  return x0, x1, y0, y1, bz or 0
end

--- The field point the camera should frame at tau (ball, else lead runner, else nil).
function Play.focusPoint(plan, tau)
  local bx, by, bz = ballAt(plan, tau)
  if bx then return bx, by, bz end
  local r = plan.runners[#plan.runners]
  if r then local x, y = runnerPos(r, tau); return x, y, 0 end
  return nil
end

--- Where the follow camera wants to look (canvas coords) at tau.
function Play.focus(c, b, tau)
  local plan = b.plan
  local bx, by, bz = ballAt(plan, tau)
  if not bx then
    -- after the ball is dead, frame the lead runner or the infield
    local r = plan.runners[#plan.runners]
    if r then bx, by = runnerPos(r, tau); bz = 0 else bx, by, bz = 0, 120, 0 end
  end
  local sx, sy = project(c, bx, by, bz)
  return sx, sy
end
