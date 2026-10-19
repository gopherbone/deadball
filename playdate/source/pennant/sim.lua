--[[ pennant/sim.lua: a small Lua baseball engine, the fallback when the C engine (`pdsim`,
  docs/PENNANT_ENGINE.md) isn't in the build (pdc-only builds, desktop tests). pennant/engine.lua
  wraps it in the same step / decide / batInput / pitchInput shape as pdsim, with the contract's
  semantics: a managed side pauses before every PA, an unanswered pause is played by the AI,
  locations are normalised to the zone, batting input uses the contract's quality formula.

  g = PSim.new(spec)            -- a game; nothing simulated yet
  g:run(maxEvents)  -> status   -- "play" (budget spent) | "decide" (needs input) | "final"
  g.log                          -- LogEv list (BallCast format: half/pa/p/bip/mv/sb/wp/sub/end)
  g.decision                     -- when status == "decide": { kind = "manage"|"bat"|"pitch", ... }
  g:answer(resp)                 -- resume after a decision
  g:setControl(sideKey, ctrl)    -- { manage =, bat =, pitch = } for one side (nil = AI)
  g:result()                     -- box score once final
  PSim.simulate(spec)            -- whole game, AI both sides, no log

  spec = { id, seed, log = bool, park = { fences = {5}, alt = ft }, home = side, away = side }
  side = { abbr, ctrl = {manage, bat, pitch} | nil, order = {pid x9}, field = {[pid] = pos},
           sp = pid, pen = {pid...}, roles = {[pid] = "CL"|"SU"|"MR"|"LR"}, bench = {pid...},
           p = {[pid] = view} }   view = { id = "p12", name, short, face, bats, throws, pos,
           con, pow, eye, spd, fld, arm, velo, ctl, stf, sta, pitches = {{k, q}}, fat }
  The ratings in the views already include condition / mood / fatigue (pennant/engine.lua).
]]

PSim = PSim or {}
PSim.__index = PSim
PSim.VERSION = "lua-stub-1"

local floor, abs, min, max, sqrt, sin, cos, rad = math.floor, math.abs, math.min, math.max, math.sqrt, math.sin, math.cos, math.rad
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

local DV <const> = { FB = 0, SI = -1, CT = -4, SL = -8, CB = -12, CH = -9, SPL = -8 }
local ZONE_X <const> = { [0] = { 0, 0.45 }, [1] = { 0.55, 0.8 }, [2] = { 0.85, 1.1 }, [3] = { 1.25, 2.0 } }
local SPRAY_FIELDER <const> = { { -32, "3B" }, { -10, "SS" }, { 10, "2B" }, { 32, "2B" }, { 99, "1B" } }
local OF_FIELDER <const> = { { -16, "LF" }, { 16, "CF" }, { 99, "RF" } }

-- Game construction -------------------------------------------------------------------------

local function newSide(spec, key)
  local s = spec[key]
  local side = { key = key, abbr = s.abbr, spec = s, ctrl = s.ctrl, order = {}, field = {}, slot = 1,
    p = s.p, pit = s.sp, pc = {}, pRuns = {}, used = {}, bench = {}, pen = {}, roles = s.roles or {},
    bat = {}, pitch = {}, pitchOrder = {}, line = {}, runs = 0, hits = 0, errors = 0, lob = 0, entryLead = {} }
  for i, id in ipairs(s.order) do side.order[i] = id side.used[id] = true end
  for id, pos in pairs(s.field) do side.field[id] = pos end
  for _, id in ipairs(s.bench or {}) do side.bench[#side.bench + 1] = id end
  for _, id in ipairs(s.pen or {}) do side.pen[#side.pen + 1] = id end
  side.used[s.sp] = true
  side.pitchOrder[1] = s.sp
  side.pitch[s.sp] = { gs = 1 }
  return side
end

function PSim.new(spec)
  local g = setmetatable({}, PSim)
  g.spec = spec
  g.rng = PRng.new(spec.seed or 1)
  g.logOn = spec.log ~= false
  g.log = {}
  g.nEv = 0
  g.home = newSide(spec, "home")
  g.away = newSide(spec, "away")
  g.park = spec.park or { fences = { 330, 375, 400, 375, 330 }, alt = 0 }
  g.status = "play"
  g.inn, g.top, g.outs = 1, true, 0
  g.bases = { false, false, false }
  g.co = coroutine.create(function() g:play() end)
  return g
end

function PSim:setControl(key, ctrl) self[key].ctrl = ctrl end

-- Event plumbing ----------------------------------------------------------------------------

function PSim:emit(e)
  self.nEv = self.nEv + 1
  if self.logOn then self.log[#self.log + 1] = e end
  self.budget = self.budget - 1
  if self.budget <= 0 then coroutine.yield("play") end
end

function PSim:ask(d)
  self.decision = d
  local resp = coroutine.yield("decide")
  self.decision = nil
  return resp or {}
end

function PSim:run(maxEvents)
  if self.status == "final" then return "final" end
  if self.status == "decide" then return "decide" end
  self.budget = maxEvents or 1e9
  local ok, st = coroutine.resume(self.co)
  if not ok then
    print("[psim] error: " .. tostring(st))
    self.status = "final"
    self.err = st
    return "final"
  end
  if coroutine.status(self.co) == "dead" then self.status = "final" else self.status = st end
  return self.status
end

function PSim:answer(resp)
  if self.status ~= "decide" then return end
  self.budget = 1e9
  self.status = "play"
  self.pendingResp = resp
  local ok, st = coroutine.resume(self.co, resp)
  if not ok then print("[psim] error: " .. tostring(st)) self.status = "final" self.err = st return end
  if coroutine.status(self.co) == "dead" then self.status = "final" else self.status = st end
end

-- Stats helpers -----------------------------------------------------------------------------

local function bl(side, id)
  local t = side.bat[id]
  if not t then t = {} side.bat[id] = t end
  return t
end
local function pl(side, id)
  local t = side.pitch[id]
  if not t then t = {} side.pitch[id] = t end
  return t
end
local function inc(t, k, n) t[k] = (t[k] or 0) + (n or 1) end

function PSim:offense() return self.top and self.away or self.home end
function PSim:defense() return self.top and self.home or self.away end

function PSim:lead(side)
  local other = side == self.home and self.away or self.home
  return side.runs - other.runs
end

--- A run scores: R for the runner, ER/R for the responsible pitcher, lead-change bookkeeping.
function PSim:score(runnerId, rbiTo, unearned)
  local off, def = self:offense(), self:defense()
  local before = off.runs - def.runs
  off.runs = off.runs + 1
  off.line[self.inn] = (off.line[self.inn] or 0) + 1
  inc(bl(off, runnerId), "r")
  if rbiTo then inc(bl(off, rbiTo), "rbi") end
  local resp = (self.resp and self.resp[runnerId]) or def.pit
  local pt = pl(def, resp)
  inc(pt, "r")
  if not unearned then inc(pt, "er") end
  def.pRuns[def.pit] = (def.pRuns[def.pit] or 0) + 1
  if before == 0 then
    -- took the lead: pitchers of record
    self.goAhead = { win = off.pit, lose = resp, side = off.key }
  elseif before == -1 then
    self.goAhead = nil -- tied
  end
  if self.logOn then self:emit({ k = "mv", id = runnerId, from = 0, to = 4 }) else self.nEv = self.nEv + 1 end
end

-- Ratings -----------------------------------------------------------------------------------

function PSim:pv(side, id) return side.p[id] end

--- Pitcher's in-game effectiveness given his pitch count (0 = fresh .. >1 = gassed).
function PSim:tired(def)
  local v = def.p[def.pit]
  local cap = 35 + v.sta * 1.1 - (v.fat or 0) * 0.5
  if cap < 20 then cap = 20 end
  return (def.pc[def.pit] or 0) / cap
end

function PSim:pitcherNow(def)
  local v = def.p[def.pit]
  local t = self:tired(def)
  local pen = t > 0.75 and (t - 0.75) or 0
  return v, v.velo - pen * 40, v.ctl - pen * 45, v.stf - pen * 35, t
end

-- Pitch location / zone classes ---------------------------------------------------------------

local function classify(px, pz)
  local ax = abs(px)
  if ax <= 0.45 and pz >= 2.0 and pz <= 3.0 then return 0 end
  if ax <= 0.83 and pz >= 1.45 and pz <= 3.55 then return 1 end
  if ax <= 1.15 and pz >= 1.1 and pz <= 3.9 then return 2 end
  return 3
end
PSim.classify = classify

function PSim:placeFor(z, batR)
  local r = self.rng
  local zx = ZONE_X[z]
  local side = r:chance(0.5) and -1 or 1
  local h = r:float()
  local px = side * (zx[1] + (zx[2] - zx[1]) * r:float())
  local pz = 2.5 + (h - 0.5) * 1.4
  if z == 3 and h > 0.6 then pz = h > 0.8 and 4.2 or 0.8 end
  if z == 2 and r:chance(0.4) then pz = r:chance(0.5) and 1.25 or 3.75 px = px * 0.6 end
  return px, pz
end

--- AI pitch: type, velocity, zone class, location.
function PSim:aiPitch(def, off, bat, mods)
  local r = self.rng
  local v, velo, ctl, stf = self:pitcherNow(def)
  local b, s = self.balls, self.strikes
  -- pitch type: weighted by quality, fastballs when behind, breaking stuff when ahead
  local tot, ws = 0, {}
  for i, pt in ipairs(v.pitches) do
    local w = (pt.q - 15) * (i == 1 and 1.5 or 1)
    if i == 1 and b > s then w = w * 1.8 end
    if i > 1 and s == 2 then w = w * 1.4 end
    ws[i] = max(1, w)
    tot = tot + ws[i]
  end
  local x, pick = r:float() * tot, v.pitches[1]
  for i, pt in ipairs(v.pitches) do x = x - ws[i] if x <= 0 then pick = pt break end end
  local mph = floor(82 + (velo - 20) * 0.27 + (DV[pick.k] or 0) + r:normal(0, 0.9) + 0.5)
  -- intent: in the zone?
  local pIn = 0.47
  if b == 3 then pIn = 0.78 elseif b == 2 and s < 2 then pIn = 0.64 elseif s == 2 and b < 2 then pIn = 0.32 end
  if mods and mods.around then pIn = pIn - 0.28 end
  local z
  if r:chance(pIn) then
    z = r:chance(0.34 - (ctl - 50) * 0.006) and 0 or 1
    if r:chance(0.22 - (ctl - 50) * 0.006) then z = 2 end
  else
    z = r:chance(0.55) and 2 or 3
    if r:chance(0.06 - (ctl - 50) * 0.002) then z = 0 end
  end
  local px, pz = self:placeFor(z)
  return { k = pick.k, q = pick.q + (stf - v.stf), mph = mph, z = z, px = px, pz = pz, stf = stf, velo = velo }
end

--- User pitch: chosen type and target, scattered by control / effort / fatigue.
function PSim:userPitch(def, resp)
  local r = self.rng
  local v, velo, ctl, stf = self:pitcherNow(def)
  local pick = v.pitches[1]
  for _, pt in ipairs(v.pitches) do if pt.k == (resp.type or resp.k) then pick = pt end end
  local eff = clamp(resp.effort or 0.6, 0, 1.1)
  local over = max(0, eff - 0.95) * 6        -- overthrow: past the sweet spot
  local mph = floor(82 + (velo - 20) * 0.27 + (DV[pick.k] or 0) + (eff - 0.6) * 5 + r:normal(0, 0.7) + 0.5)
  local sd = 0.28 * (1 + (55 - ctl) / 45) * (1 + max(0, eff - 0.6) * 0.9 + over)
  sd = clamp(sd, 0.1, 0.8)
  local px = (resp.x or 0) * 0.83 + r:normal(0, sd)
  local pz = 2.5 + (resp.z or 0) + r:normal(0, sd)
  px, pz = clamp(px, -2.2, 2.2), clamp(pz, 0.5, 4.5)
  -- effort also spends the arm: count hard pitches extra
  def.pc[def.pit] = (def.pc[def.pit] or 0) + max(0, eff - 0.6) * 0.8
  return { k = pick.k, q = pick.q + (stf - v.stf) + (eff - 0.6) * 10, mph = mph, z = classify(px, pz), px = px, pz = pz,
    stf = stf + (eff - 0.6) * 8, velo = velo, user = true }
end

-- Batted balls ---------------------------------------------------------------------------------

function PSim:fenceAt(sp)
  local f = self.park.fences
  local x = (clamp(sp, -45, 45) + 45) / 22.5   -- 0..4
  local i = floor(x)
  if i >= 4 then return f[5] end
  local t = x - i
  return f[i + 1] * (1 - t) + f[i + 2] * t
end

local function fielderFor(sp, outfield)
  local tbl = outfield and OF_FIELDER or SPRAY_FIELDER
  for _, e in ipairs(tbl) do if sp <= e[1] then return e[2] end end
  return "CF"
end

--- Parabolic flight sampled every 0.1 s: { x,y,z, ... } feet, to the landing spot (dist, sp).
local function flightPath(ev, la, dist, sp)
  local vz = ev * 1.467 * sin(rad(max(la, 2)))
  local H = vz * vz / 64.4 * 0.62 + 3
  local T = 2 * sqrt(2 * H / 32.2)
  T = clamp(T, 0.6, 7)
  local n = max(3, floor(T / 0.1 + 0.5))
  local dx, dy = sin(rad(sp)), cos(rad(sp))
  local p = {}
  for i = 0, n do
    local u = i / n
    local d = dist * (u * (1.15 - 0.15 * u))     -- a little drag: slower late
    local z = 3 + (H - 3) * 4 * u * (1 - u) - 3 * u
    if i == n then z = 0 end
    p[#p + 1] = floor(dx * d + 0.5)
    p[#p + 1] = floor(dy * d + 0.5)
    p[#p + 1] = floor(max(0, z) + 0.5)
  end
  return p
end

--- Ball in play from exit velocity / launch angle / spray -> result.
-- returns { res, f, out, ev, la, sp, dist, path, air, kind = "gb"|"ld"|"fb"|"pu" }
function PSim:battedBall(off, def, bat, ev, la, sp, mods)
  local r = self.rng
  local bv = off.p[bat]
  local defFld = 0
  local n = 0
  for id, pos in pairs(def.field) do if pos ~= "DH" and pos ~= "P" then defFld = defFld + def.p[id].fld n = n + 1 end end
  defFld = n > 0 and defFld / n or 50
  local out = { ev = floor(ev + 0.5), la = floor(la + 0.5), sp = floor(sp + 0.5) }
  local fence = self:fenceAt(sp)
  local altK = 1 + (self.park.alt or 0) / 1000 * 0.012
  if la < 9 then
    out.kind = "gb"
    local pHit = 0.215 + (ev - 86) * 0.0055 + (bv.spd - 50) * 0.0022 - (defFld - 50) * 0.003
    if ev < 62 then pHit = 0.13 + (bv.spd - 50) * 0.006 end
    if mods and mods.shift then
      local pull = (bv.bats == "L") and sp > 8 or (bv.bats ~= "L" and sp < -8)
      pHit = pHit + (pull and -0.09 or 0.12)
    end
    if mods and mods.hitrun then pHit = pHit + 0.05 end
    out.f = fielderFor(sp, false)
    if r:chance(clamp(pHit, 0.05, 0.6)) then
      out.res = (ev > 99 and abs(sp) > 33 and r:chance(0.35)) and "2B" or "1B"
      if out.res == "1B" and ev >= 62 then out.f = fielderFor(sp, true) end
    else
      out.res, out.out = "OUT", "GO"
    end
  elseif la < 25 then
    out.kind = "ld"
    local dist = (ev - 32) * 4.6 * (0.55 + la / 50) * altK
    out.dist = dist
    local pHit = 0.66 + (ev - 90) * 0.009 - (defFld - 50) * 0.003
    out.f = fielderFor(sp, dist > 150)
    if r:chance(clamp(pHit, 0.25, 0.92)) then
      local pX = clamp(0.18 + (ev - 92) * 0.012 + (dist > 260 and 0.1 or 0), 0.03, 0.55)
      if r:chance(pX) then
        out.res = r:chance(0.05 + (bv.spd - 50) * 0.003) and "3B" or "2B"
      else
        out.res = "1B"
      end
    else
      out.res, out.out = "OUT", "LO"
      if dist < 140 then out.f = fielderFor(sp, false) end
    end
    out.path = flightPath(ev, la, clamp(dist, 60, 330), sp)
    out.air = true
  elseif la < 50 then
    out.kind = "fb"
    local f = clamp(1 - ((la - 28) / 30) ^ 2, 0.15, 1)
    local dist = (ev - 35) * 6.0 * f * altK
    out.dist = dist
    out.f = fielderFor(sp, true)
    if dist > fence + 4 then
      out.res = "HR"
      out.path = flightPath(ev, la, dist, sp)
    elseif dist > fence - 25 then
      out.path = flightPath(ev, la, dist, sp)
      if r:chance(0.42) then out.res = r:chance(0.12 + (bv.spd - 50) * 0.004) and "3B" or "2B"
      else out.res, out.out = "OUT", "FO" out.path = flightPath(ev, la, fence - 8, sp) end
    else
      out.path = flightPath(ev, la, clamp(dist, 90, 420), sp)
      local pHit = dist < 200 and 0.22 or 0.06
      if r:chance(pHit - (defFld - 50) * 0.002) then out.res = "1B"
      else out.res, out.out = "OUT", "FO" end
    end
    out.air = true
  else
    out.kind = "pu"
    local dist = clamp((ev - 30) * 1.6, 30, 180)
    out.dist = dist
    out.f = fielderFor(sp, dist > 150)
    out.path = flightPath(ev, la, dist, sp)
    out.air = true
    if abs(sp) > 38 and r:chance(0.35) then
      out.res, out.out = "FOUL_OUT", "PO"
    elseif r:chance(0.02) then
      out.res = "1B"
    else
      out.res, out.out = "OUT", "PO"
    end
  end
  -- errors on routine outs
  if out.res == "OUT" and out.kind ~= "pu" then
    local fid
    for id, pos in pairs(def.field) do if pos == out.f then fid = id end end
    local fr = fid and def.p[fid].fld or 50
    if r:chance(0.012 + (50 - fr) * 0.0006) then
      out.res, out.out = "ROE", nil
      out.errBy = fid
    end
  end
  return out
end

--- Runners after a ball in play. Returns moves { {id, from, to} } (to: 1..3, 4 scored, -1 out)
-- plus outs and the final result kind (DP / FC / SF adjustments).
function PSim:advance(off, bb, bat, mods)
  local r = self.rng
  local b = self.bases
  local moves = {}
  local outs = self.outs
  local res = bb.res
  local function sp(id) return off.p[id] and off.p[id].spd or 50 end
  local nb = { false, false, false }
  local function put(id, from, to)
    moves[#moves + 1] = { id = id, from = from, to = to }
    if to >= 1 and to <= 3 then nb[to] = id end
  end
  local run = mods and mods.hitrun
  if res == "HR" then
    for i = 3, 1, -1 do if b[i] then put(b[i], i, 4) end end
    put(bat, 0, 4)
  elseif res == "3B" then
    for i = 3, 1, -1 do if b[i] then put(b[i], i, 4) end end
    put(bat, 0, 3)
  elseif res == "2B" then
    if b[3] then put(b[3], 3, 4) end
    if b[2] then put(b[2], 2, 4) end
    if b[1] then put(b[1], 1, (r:chance(0.42 + (sp(b[1]) - 50) * 0.012 + (outs == 2 and 0.2 or 0) + (run and 0.3 or 0))) and 4 or 3) end
    put(bat, 0, 2)
  elseif res == "1B" or res == "ROE" then
    if b[3] then put(b[3], 3, 4) end
    local third = false
    if b[2] then
      if r:chance(0.58 + (sp(b[2]) - 50) * 0.012 + (outs == 2 and 0.25 or 0)) or res == "ROE" then put(b[2], 2, 4) else put(b[2], 2, 3) third = true end
    end
    if b[1] then
      if not third and r:chance(0.27 + (sp(b[1]) - 50) * 0.01 + (run and 0.35 or 0)) then put(b[1], 1, 3) else put(b[1], 1, 2) end
    end
    put(bat, 0, 1)
  else
    -- outs
    local kind = bb.kind
    if kind == "gb" then
      if b[1] and outs < 2 and not run and r:chance(0.5 - (sp(bat) - 50) * 0.008) then
        res = "DP"
        bb.out = "DP"
        -- runner from first and batter out; others move up
        if b[3] and outs == 0 then put(b[3], 3, 4) elseif b[3] then put(b[3], 3, 3) end
        if b[2] then put(b[2], 2, 3) end
      elseif b[1] and not run and r:chance(0.22) then
        res = "FC"
        bb.out = "FC"
        if b[3] then put(b[3], 3, outs < 2 and 4 or 3) end
        if b[2] then put(b[2], 2, 3) end
        put(bat, 0, 1)
      else
        if b[3] then put(b[3], 3, (outs < 2 and r:chance(0.55)) and 4 or 3) end
        if b[2] then put(b[2], 2, (r:chance(0.62) or run) and 3 or 2) end
        if b[1] then put(b[1], 1, 2) end
      end
    elseif kind == "fb" or kind == "ld" then
      local d = bb.dist or 0
      if b[3] and outs < 2 and kind == "fb" and d > 210 and r:chance(0.62 + (sp(b[3]) - 50) * 0.01 + (d > 300 and 0.25 or 0)) then
        put(b[3], 3, 4)
        res = "SF"
      elseif b[3] then put(b[3], 3, 3) end
      if b[2] then put(b[2], 2, (outs < 2 and kind == "fb" and d > 290 and r:chance(0.5)) and 3 or 2) end
      if b[1] then
        if kind == "ld" and outs < 2 and (run or r:chance(0.06)) then
          res = "DP"
          bb.out = "LO"     -- doubled off first
        else
          put(b[1], 1, 1)
        end
      end
    else
      for i = 1, 3 do if b[i] then put(b[i], i, i) end end
    end
  end
  bb.res = res
  -- tidy: a base can't hold two runners (rare after a forced move)
  local seen = {}
  for i = #moves, 1, -1 do
    local m = moves[i]
    if m.to >= 1 and m.to <= 3 then
      if seen[m.to] then m.to = math.min(4, m.to + 1) end
      seen[m.to] = true
    end
  end
  return moves
end

-- Plate appearance -------------------------------------------------------------------------------

function PSim:emitPitch(p, result)
  local e = { k = "p", t = p.k, v = p.mph, z = p.z, r = result, b = self.balls, s = self.strikes,
    px = floor(p.px / 0.83 * 100 + 0.5) / 100, pz = floor((p.pz - 2.5) * 100 + 0.5) / 100 }
  self:emit(e)
  return e
end

--- The batter's response to a pitch (AI). Returns "take" | "whiff" | "foul" | "inplay", contact quality.
function PSim:aiSwing(off, bat, pitch, mods)
  local r = self.rng
  local bv = off.p[bat]
  local inZone = pitch.z <= 1
  local s, b = self.strikes, self.balls
  local pSwing
  if inZone then
    pSwing = 0.66 + (s == 2 and 0.2 or 0) + (pitch.z == 0 and 0.08 or 0) - (b == 3 and s == 0 and 0.45 or 0) - (bv.eye - 50) * 0.001
  else
    pSwing = 0.25 - (bv.eye - 50) * 0.0065 + (pitch.stf - 50) * 0.004 + (s == 2 and 0.12 or 0) + (pitch.z == 2 and 0.12 or -0.14)
  end
  if mods and mods.hitrun then pSwing = inZone and 0.95 or 0.7 end
  if mods and mods.bunt then return "bunt" end
  if not r:chance(clamp(pSwing, 0.02, 0.97)) then return "take" end
  local pContact = self:aiContactChance(off, bat, pitch)
  if mods and mods.hitrun then pContact = pContact + 0.06 end
  if not r:chance(clamp(pContact, 0.25, 0.97)) then return "whiff" end
  local pFoul = 0.45 + (s == 2 and 0.06 or 0) + (pitch.z >= 2 and 0.12 or 0)
  if r:chance(pFoul) then return "foul" end
  return "inplay", r:float()
end

function PSim:aiContactChance(off, bat, pitch)
  local bv = off.p[bat]
  return 0.75 + (bv.con - 50) * 0.0062 - (pitch.stf - 50) * 0.0058 - (pitch.mph - 91) * 0.006
    + ({ [0] = 0.07, [1] = 0, [2] = -0.13, [3] = -0.32 })[pitch.z] + (self.lastK == pitch.k and 0.03 or 0)
end

--- Exit velo / launch / spray for AI contact.
function PSim:aiContact(off, bat, pitch, mods)
  local r = self.rng
  local bv = off.p[bat]
  local ev = 87.5 + (bv.pow - 50) * 0.34 + ({ [0] = 3, [1] = 0, [2] = -5, [3] = -9 })[pitch.z] - (pitch.stf - 50) * 0.12 + r:normal(0, 12.5)
  local la = r:normal(12 + (bv.pow - 50) * 0.14, 25)
  local pullSign = bv.bats == "L" and 1 or -1
  if bv.bats == "S" then pullSign = (self:defense().p[self:defense().pit].throws == "L") and -1 or 1 end
  local sp = clamp(r:normal(pullSign * 9, 22), -44, 44)
  return clamp(ev, 35, 117), clamp(la, -50, 75), sp
end

--- User swing -> outcome (the contract's model: input quality scales the rated contact chance).
-- resp = { swing, timing (-1..1, + late), aim (-1..1, zone z units), power }
function PSim:userSwing(off, bat, pitch, resp)
  local r = self.rng
  local bv = off.p[bat]
  local wT = 0.45 + (bv.con - 50) * 0.004
  local wA = 0.70 + (bv.con - 50) * 0.005
  local pzN = pitch.pz - 2.5
  local tim = resp.timing or 0
  local q = math.exp(-(tim / wT) ^ 2) * math.exp(-(((resp.aim or 0) - pzN) / wA) ^ 2)
  local base = self:aiContactChance(off, bat, pitch)
  if resp.power then base = base * 0.87 end
  if not r:chance(clamp(base * (0.55 + 0.6 * q), 0.05, 0.97)) then return "whiff" end
  local pFoul = 0.40 + (1 - q) * 0.3 + (self.strikes == 2 and 0.06 or 0)
  if r:chance(clamp(pFoul, 0.2, 0.85)) then return "foul" end
  local ev, la, sp = self:aiContact(off, bat, pitch)
  ev = ev + 5 * (q - 0.75) + (resp.power and 4 or 0)
  -- bat under the ball lifts it, over it beats it into the ground
  la = la + (pzN - (resp.aim or 0)) * 22 + (resp.power and 6 or 0)
  local pullSign = bv.bats == "L" and 1 or -1
  if bv.bats == "S" then pullSign = (self:defense().p[self:defense().pit].throws == "L") and -1 or 1 end
  sp = clamp(sp * 0.5 + pullSign * (-tim) * 30, -44, 44)
  return "inplay", clamp(ev, 35, 117), clamp(la, -50, 75), sp
end

--- The take result for a pitch: ball, or called strike (zone + umpire on the edges).
function PSim:takeResult(pitch)
  if pitch.z <= 1 then return "C" end
  if pitch.z == 2 and self.rng:chance(0.12) then return "C" end
  return "B"
end

function PSim:countAfter(res)
  if res == "B" then self.balls = self.balls + 1
  elseif res == "C" or res == "S" then self.strikes = self.strikes + 1
  elseif res == "F" then if self.strikes < 2 then self.strikes = self.strikes + 1 end end
end

function PSim:walk(off, def, bat, hbp)
  local b = self.bases
  local moves = {}
  -- forced runners move implicitly in the log; scorers log a run
  if b[1] then
    if b[2] then
      if b[3] then self:score(b[3], bat) end
      b[3] = b[2]
    end
    b[2] = b[1]
  end
  b[1] = bat
  if self.logOn then self:emit({ k = "mv", id = bat, from = 0, to = 1 }) end
  local bt, pt = bl(off, bat), pl(def, def.pit)
  inc(bt, "pa") inc(pt, "bf")
  if hbp then inc(bt, "hbp") inc(pt, "hbp") else inc(bt, "bb") inc(pt, "bb") end
  self.resp[bat] = def.pit
end

function PSim:outRecorded(def, n)
  self.outs = self.outs + n
  inc(pl(def, def.pit), "outs", n)
end

--- One plate appearance (after the "pa" event). Returns when it's over.
function PSim:plateAppearance(off, def, bat, mods)
  local r = self.rng
  self.balls, self.strikes = 0, 0
  self.lastK = nil
  local bt = bl(off, bat)
  -- intentional walk: four wide ones
  if mods.ibb then
    for _ = 1, 4 do
      self.balls = self.balls + 1
      def.pc[def.pit] = (def.pc[def.pit] or 0) + 1
      self:emitPitch({ k = "FB", mph = 80, z = 3, px = (off.p[bat].bats == "L" and -1.9 or 1.9), pz = 2.6 }, "B")
    end
    self:walk(off, def, bat, false)
    return
  end
  -- steal: on the first pitch
  if mods.steal and self.bases[1] and not self.bases[2] then
    local rid = self.bases[1]
    local cid
    for id, pos in pairs(def.field) do if pos == "C" then cid = id end end
    local carm = cid and def.p[cid].arm or 50
    local hold = def.p[def.pit].ctl
    local ok = r:chance(clamp(0.68 + (off.p[rid].spd - 55) * 0.011 - (carm - 50) * 0.006 - (hold - 50) * 0.002, 0.25, 0.95))
    self:emit({ k = "sb", id = rid, base = 2, ok = ok })
    self.bases[1] = false
    if ok then self.bases[2] = rid inc(bl(off, rid), "sb") else inc(bl(off, rid), "cs") self:outRecorded(def, 1) end
    if self.outs >= 3 then return "cs" end
  end
  local ctrlBat = off.ctrl and off.ctrl.bat
  local ctrlPit = def.ctrl and def.ctrl.pitch
  while true do
    local pitch
    if ctrlPit then
      local v = def.p[def.pit]
      local sug = self:aiPitch(def, off, bat, mods)
      local resp = self:ask({ kind = "pitch", side = def.key, pit = def.pit, bat = bat, pitches = v.pitches,
        suggest = { k = sug.k, px = sug.px, pz = sug.pz }, b = self.balls, s = self.strikes, outs = self.outs,
        tired = self:tired(def), pc = def.pc[def.pit] or 0 })
      if resp.ai then pitch = sug else pitch = self:userPitch(def, resp) end
    else
      pitch = self:aiPitch(def, off, bat, mods)
    end
    def.pc[def.pit] = (def.pc[def.pit] or 0) + 1
    inc(pl(def, def.pit), "np")
    -- hit by pitch: wild ones in on the hands
    if pitch.z == 3 and r:chance(0.035) then
      self:emitPitch(pitch, "H")
      self:walk(off, def, bat, true)
      return
    end
    local outcome, ev, la, sp
    local take = self:takeResult(pitch)
    if ctrlBat and not mods.bunt then
      local takeEv = { k = "p", t = pitch.k, v = pitch.mph, z = pitch.z, r = take,
        b = self.balls + (take == "B" and 1 or 0), s = self.strikes + (take == "C" and 1 or 0),
        px = floor(pitch.px * 100 + 0.5) / 100, pz = floor(pitch.pz * 100 + 0.5) / 100 }
      local resp = self:ask({ kind = "bat", side = off.key, bat = bat, pit = def.pit, pitch = pitch, take = takeEv,
        b = self.balls, s = self.strikes, outs = self.outs })
      if resp.ai then
        outcome = self:aiSwing(off, bat, pitch, mods)
        if outcome == "inplay" then ev, la, sp = self:aiContact(off, bat, pitch, mods) end
      elseif resp.swing then
        outcome, ev, la, sp = self:userSwing(off, bat, pitch, resp)
      else
        outcome = "take"
      end
    else
      outcome = self:aiSwing(off, bat, pitch, mods)
      if outcome == "inplay" then ev, la, sp = self:aiContact(off, bat, pitch, mods) end
    end
    self.lastK = pitch.k
    if outcome == "bunt" then
      -- sacrifice bunt attempt
      if pitch.z >= 2 and r:chance(0.6) then
        outcome = "take"
      elseif r:chance(0.72 + (off.p[bat].con - 50) * 0.005) then
        self.strikes = self.strikes
        self:emitPitch(pitch, "X")
        local f = r:chance(0.5) and "3B" or (r:chance(0.5) and "P" or "1B")
        local bb = { ev = 38, la = -22, sp = f == "3B" and -25 or (f == "1B" and 25 or 0), kind = "gb", res = "OUT", out = "GO", f = f }
        local moves = {}
        local b = self.bases
        for i = 3, 1, -1 do if b[i] then moves[#moves + 1] = { id = b[i], from = i, to = math.min(4, i + 1) } end end
        if r:chance(0.08 + (off.p[bat].spd - 50) * 0.005) then
          bb.res = "1B"
          moves[#moves + 1] = { id = bat, from = 0, to = 1 }
        end
        return self:finishBip(off, def, bat, bb, moves, true)
      else
        outcome = (self.strikes == 2) and "whiff" or "foul"
        if outcome == "foul" and self.strikes == 2 then outcome = "whiff" end
      end
    end
    if outcome == "take" then
      self:countAfter(take)
      self:emitPitch(pitch, take)
      if take == "B" and r:chance(0.004) and (self.bases[1] or self.bases[2] or self.bases[3]) then
        -- wild pitch: everyone moves up
        self:emit({ k = "wp", pb = r:chance(0.3) })
        local b = self.bases
        if b[3] then self:score(b[3], nil, true) end
        b[3], b[2], b[1] = b[2], b[1], false
        if self.logOn then
          for i = 3, 2, -1 do if b[i] then self:emit({ k = "mv", id = b[i], from = i - 1, to = i }) end end
        end
      end
      if self.balls >= 4 then self:walk(off, def, bat, false) return end
      if self.strikes >= 3 then
        inc(bt, "pa") inc(bt, "ab") inc(bt, "k")
        local pt = pl(def, def.pit) inc(pt, "k") inc(pt, "bf")
        self:outRecorded(def, 1)
        return
      end
    elseif outcome == "whiff" then
      self.strikes = self.strikes + 1
      self:emitPitch(pitch, "S")
      if mods.hitrun and self.bases[1] and not self.bases[2] then
        -- the runner was going: a steal attempt with a worse jump
        local rid = self.bases[1]
        local ok = r:chance(clamp(0.55 + (off.p[rid].spd - 55) * 0.01, 0.2, 0.9))
        self:emit({ k = "sb", id = rid, base = 2, ok = ok })
        self.bases[1] = false
        if ok then self.bases[2] = rid inc(bl(off, rid), "sb") else inc(bl(off, rid), "cs") self:outRecorded(def, 1) end
        mods.hitrun = false
      end
      if self.strikes >= 3 then
        inc(bt, "pa") inc(bt, "ab") inc(bt, "k")
        local pt = pl(def, def.pit) inc(pt, "k") inc(pt, "bf")
        self:outRecorded(def, 1)
        return
      end
      if self.outs >= 3 then return "cs" end
    elseif outcome == "foul" then
      self:countAfter("F")
      self:emitPitch(pitch, "F")
    else
      self:emitPitch(pitch, "X")
      local bb = self:battedBall(off, def, bat, ev, la, sp, mods)
      local moves = self:advance(off, bb, bat, mods)
      return self:finishBip(off, def, bat, bb, moves, false)
    end
  end
end

--- Log + stats for a ball in play with its runner moves.
function PSim:finishBip(off, def, bat, bb, moves, sac)
  local e = { k = "bip", ev = bb.ev, la = bb.la, sp = bb.sp, res = bb.res, f = bb.f, out = bb.out, path = bb.path }
  self:emit(e)
  local bt, pt = bl(off, bat), pl(def, def.pit)
  inc(bt, "pa") inc(pt, "bf")
  local res = bb.res
  local hit = res == "1B" or res == "2B" or res == "3B" or res == "HR"
  if res == "SF" then inc(bt, "sf") elseif not sac then inc(bt, "ab") end
  if hit then
    inc(bt, "h") inc(pt, "h") off.hits = off.hits + 1
    if res == "2B" then inc(bt, "d") elseif res == "3B" then inc(bt, "t") elseif res == "HR" then inc(bt, "hr") inc(pt, "hr") end
  end
  if res == "ROE" then def.errors = def.errors + 1 end
  -- count outs: participants - safe - scored
  local parts = 1
  for i = 1, 3 do if self.bases[i] then parts = parts + 1 end end
  local safe, scored = 0, 0
  local nb = { false, false, false }
  local scorers = {}
  for _, m in ipairs(moves) do
    if m.to == 4 then scored = scored + 1 scorers[#scorers + 1] = m.id
    elseif m.to >= 1 and m.to <= 3 then safe = safe + 1 nb[m.to] = m.id end
  end
  local outs = max(0, parts - safe - scored)
  -- the third out on the play: no runs count (force / DP / batter out before first)
  if outs > 0 and self.outs + outs >= 3 then scorers = {} end
  -- runner moves first (the log wants mvs after the bip), then runs
  if self.logOn then
    for _, m in ipairs(moves) do
      if m.to >= 1 and m.to <= 3 then self:emit({ k = "mv", id = m.id, from = m.from, to = m.to }) end
    end
  end
  self.bases = nb
  if safe > 0 then for _, m in ipairs(moves) do if m.from == 0 and m.to >= 1 and m.to <= 3 then self.resp[m.id] = def.pit end end end
  local unearned = res == "ROE"
  local rbi = (res ~= "DP" and res ~= "ROE") and bat or nil
  for _, id in ipairs(scorers) do self:score(id, rbi, unearned) end
  if outs > 0 then self:outRecorded(def, min(outs, 3 - self.outs)) end
  if self.outs >= 3 then return "inning" end
end

-- Managers -------------------------------------------------------------------------------------------

local function bestBy(ids, side, fn)
  local best, bv = nil, -1e9
  for _, id in ipairs(ids) do
    local v = fn(side.p[id], id)
    if v and v > bv then best, bv = id, v end
  end
  return best, bv
end

function PSim:batValue(v) return v.con * 0.4 + v.pow * 0.4 + v.eye * 0.2 end

--- Relievers still available (not used, not exhausted).
function PSim:availablePen(def)
  local out = {}
  for _, id in ipairs(def.pen) do
    if not def.used[id] and (def.p[id].fat or 0) < 85 then out[#out + 1] = id end
  end
  return out
end

--- The AI's choice of reliever for the situation.
function PSim:pickReliever(def)
  local av = self:availablePen(def)
  if #av == 0 then return nil end
  local lead = self:lead(def)
  local late = self.inn >= 8
  local want = (self.inn >= 9 and lead >= 1 and lead <= 3) and "CL" or ((self.inn == 8 and lead >= 0 and lead <= 3) and "SU")
    or (self.inn <= 5 and "LR") or "MR"
  for _, id in ipairs(av) do if def.roles[id] == want then return id end end
  -- otherwise the best fresh arm that isn't the closer (save him)
  return bestBy(av, def, function(v, id)
    if def.roles[id] == "CL" and not late then return nil end
    return v.stf + v.ctl - (v.fat or 0) * 0.3
  end) or av[1]
end

--- AI: change pitchers?
function PSim:aiWantsChange(def)
  local t = self:tired(def)
  local runs = def.pRuns[def.pit] or 0
  local starter = def.pitchOrder[1] == def.pit
  if t >= 1.0 then return true end
  if t > 0.85 and (self.bases[2] or self.bases[3]) then return true end
  local outsBy = pl(def, def.pit).outs or 0
  local fresh = #self:availablePen(def) > 0
  if not starter and fresh and self.outs == 0 and def.roles[def.pit] ~= "CL"
    and outsBy >= (def.roles[def.pit] == "LR" and 6 or 3) then return true end
  if starter and fresh and self.inn >= 8 and self.outs == 0 and t > 0.7 then return true end
  if starter and runs >= 6 then return true end
  if not starter and runs >= 3 then return true end
  -- closer for the ninth
  if self.inn >= 9 and def.roles[def.pit] ~= "CL" then
    local lead = self:lead(def)
    if lead >= 1 and lead <= 3 and t > 0.4 then
      for _, id in ipairs(self:availablePen(def)) do if def.roles[id] == "CL" then return true end end
    end
  end
  return false
end

function PSim:changePitcher(def, id, why)
  local old = def.pit
  def.pit = id
  def.used[id] = true
  def.pitchOrder[#def.pitchOrder + 1] = id
  def.entryLead[id] = self:lead(def)
  for pid, pos in pairs(def.field) do if pos == "P" then def.field[pid] = nil end end
  inc(pl(def, id), "g")
  self:emit({ k = "sub", side = def.key, out = old, ["in"] = id, pos = "P", why = why or "pitching change" })
end

function PSim:pinchHit(off, id)
  local slot = off.slot
  local old = off.order[slot]
  off.order[slot] = id
  off.used[id] = true
  local pos = off.field[old] or "DH"
  off.field[old] = nil
  off.field[id] = pos
  for i, b in ipairs(off.bench) do if b == id then table.remove(off.bench, i) break end end
  inc(bl(off, id), "g")
  self:emit({ k = "sub", side = off.key, out = old, ["in"] = id, pos = pos, why = "pinch hitter" })
end

--- AI offensive call for this PA.
function PSim:aiOffense(off, def, bat)
  local r = self.rng
  local b = self.bases
  local diff = self:lead(off)
  local late = self.inn >= 7 and abs(diff) <= 2
  local bv = off.p[bat]
  -- pinch hit late for a weak bat
  if late and self.inn >= 8 and #off.bench > 0 then
    local best, val = bestBy(off.bench, off, function(v) return self:batValue(v) end)
    if best and val > self:batValue(bv) + 8 and r:chance(0.5) then return { call = "ph", id = best } end
  end
  if b[1] and not b[2] and self.outs < 2 then
    local rv = off.p[b[1]]
    if rv.spd >= 54 and r:chance(0.18 + (rv.spd - 54) * 0.015) then return { call = "steal" } end
    if late and self.outs == 0 and bv.con + bv.pow < 92 and r:chance(0.35) then return { call = "bunt" } end
    if bv.con >= 55 and r:chance(0.05) then return { call = "hitrun" } end
  end
  return { call = "none" }
end

function PSim:aiDefense(off, def, bat)
  local r = self.rng
  local b = self.bases
  if self:aiWantsChange(def) then
    local id = self:pickReliever(def)
    if id then return { call = "pc", id = id } end
  end
  local bv = off.p[bat]
  if not b[1] and (b[2] or b[3]) and self.inn >= 7 and bv.pow >= 64 and abs(self:lead(def)) <= 1 and r:chance(0.3) then
    return { call = "ibb" }
  end
  if bv.pow >= 66 and self.balls == 0 and r:chance(0.1) then return { call = "around" } end
  return { call = "none" }
end

--- Is this a spot where a human manager would want the dugout menu?
function PSim:interesting(side, offense, bat)
  if side.callTime then return true end
  local b = self.bases
  local close = abs(self:lead(side)) <= 3
  if offense then
    if (b[1] or b[2]) and self.outs < 2 and close then return true end
    if self.inn >= 7 and close and #side.bench > 0 then return true end
  else
    if self:tired(side) > 0.8 then return true end
    if (b[2] or b[3]) and self.inn >= 6 and close then return true end
    if self.inn >= 8 and close and self.outs == 0 and not (b[1] or b[2] or b[3]) then return true end
  end
  return false
end

-- The game -----------------------------------------------------------------------------------------

function PSim:applyCalls(off, def, bat, oc, dc, mods)
  -- a call is { call = ... } or { list = { {call=...}, ... } } (several orders for one PA)
  local function each(c, fn) if c.list then for _, x in ipairs(c.list) do fn(x) end else fn(c) end end
  each(dc, function(c)
    if c.call == "pc" and c.id and def.p[c.id] and not def.used[c.id] then self:changePitcher(def, c.id, c.why or "manager") end
    if c.call == "ibb" then mods.ibb = true end
    if c.call == "around" then mods.around = true end
    if c.call == "shift" then mods.shift = true end
  end)
  each(oc, function(c)
    if c.call == "ph" and c.id and off.p[c.id] and not off.used[c.id] then self:pinchHit(off, c.id) end
    if c.call == "steal" then mods.steal = true end
    if c.call == "bunt" then mods.bunt = true end
    if c.call == "hitrun" then mods.hitrun = true end
  end)
end

function PSim:play()
  self.resp = {}
  for _, s in ipairs({ self.away, self.home }) do
    for _, id in ipairs(s.order) do inc(bl(s, id), "g") end
    inc(pl(s, s.pit), "g")
  end
  local inn = 1
  while true do
    for half = 1, 2 do
      self.inn, self.top, self.outs = inn, half == 1, 0
      self.bases = { false, false, false }
      local off, def = self:offense(), self:defense()
      -- bottom of the ninth (or later) isn't played when the home side leads
      if not self.top and inn >= 9 and self.home.runs > self.away.runs then break end
      self:emit({ k = "half", inn = inn, top = self.top })
      while self.outs < 3 do
        local bat = off.order[off.slot]
        local mods = {}
        -- managers: defense, then offense (a user-managed side gets the dugout menu)
        local dc, oc
        if def.ctrl and def.ctrl.manage then
          local sug = self:aiDefense(off, def, bat)
          dc = self:ask({ kind = "manage", side = def.key, offense = false, bat = bat, pit = def.pit, suggest = sug,
            pen = self:availablePen(def), tired = self:tired(def), pc = def.pc[def.pit] or 0 })
          if dc.ai then dc = sug end
        else
          dc = self:aiDefense(off, def, bat)
        end
        if off.ctrl and off.ctrl.manage then
          local sug = self:aiOffense(off, def, bat)
          oc = self:ask({ kind = "manage", side = off.key, offense = true, bat = bat, pit = def.pit, suggest = sug,
            bench = off.bench, tired = self:tired(def), pc = def.pc[def.pit] or 0 })
          if oc.ai then oc = { call = "none" } end
        else
          oc = self:aiOffense(off, def, bat)
        end
        self:applyCalls(off, def, bat, oc, dc, mods)
        bat = off.order[off.slot]
        self:emit({ k = "pa", bat = "p" .. bat, pit = "p" .. def.pit })
        local st = self:plateAppearance(off, def, bat, mods)
        -- (caught stealing for the third out: the batter leads off next inning)
        if st ~= "cs" then off.slot = off.slot % 9 + 1 end
        -- walk-off
        if not self.top and inn >= 9 and self.home.runs > self.away.runs then break end
      end
      local lob = 0
      for i = 1, 3 do if self.bases[i] then lob = lob + 1 end end
      off.lob = off.lob + lob
      off.line[inn] = off.line[inn] or 0
      if not self.top and inn >= 9 and self.home.runs > self.away.runs then break end
    end
    if inn >= 9 and self.home.runs ~= self.away.runs then break end
    if inn >= 15 then break end   -- a tie after 15 stands (it happens)
    inn = inn + 1
  end
  self.innings = inn
  self:decisions()
  self:emit({ k = "end", home = self.home.runs, away = self.away.runs })
end

--- Winning / losing pitcher, save.
function PSim:decisions()
  local h, a = self.home, self.away
  if h.runs == a.runs then return end
  local win = h.runs > a.runs and h or a
  local lose = win == h and a or h
  local ga = self.goAhead
  local wp = ga and ga.win or win.pitchOrder[#win.pitchOrder]
  local lp = ga and ga.lose or lose.pit
  -- a starter needs five innings for the win
  if wp == win.pitchOrder[1] and (pl(win, wp).outs or 0) < 15 then
    wp = win.pitchOrder[2] or wp
  end
  inc(pl(win, wp), "w")
  inc(pl(lose, lp), "l")
  self.W, self.L = wp, lp
  local last = win.pitchOrder[#win.pitchOrder]
  if last ~= wp and #win.pitchOrder > 1 then
    local el = win.entryLead[last] or 99
    if el >= 1 and el <= 3 and (pl(win, last).outs or 0) >= 1 then
      inc(pl(win, last), "sv")
      self.S = last
    end
  end
  -- holds: relievers who entered and left with a save-situation lead
  for i = 2, #win.pitchOrder - 1 do
    local id = win.pitchOrder[i]
    local el = win.entryLead[id] or 99
    if el >= 1 and el <= 3 and id ~= wp then inc(pl(win, id), "hld") end
  end
end

function PSim:result()
  local function side(s)
    return { abbr = s.abbr, runs = s.runs, hits = s.hits, errors = s.errors, lob = s.lob, line = s.line,
      bat = s.bat, pitch = s.pitch, pitchOrder = s.pitchOrder, order = s.order, pc = s.pc }
  end
  return { home = side(self.home), away = side(self.away), innings = self.innings or 9,
    W = self.W, L = self.L, S = self.S, events = self.nEv }
end

--- Whole game, both sides AI, no log.
function PSim.simulate(spec)
  spec.log = false
  spec.home.ctrl, spec.away.ctrl = nil, nil
  local g = PSim.new(spec)
  g:run()
  return g:result()
end
