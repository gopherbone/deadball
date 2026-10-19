--[[ Pennant <-> game engine. One interface over the C engine (pdsim, docs/PENNANT_ENGINE.md) and
  the Lua fallback (pennant/sim.lua):

  h = PEng.newGame(L, g, ctrlFor)    -- ctrlFor[abbr] = { manage, bat, pitch } for the human side
  evs, pause = h:step(maxEvents, budgetMs)    -- pause = nil | { reason = "pa"|"bat"|"pitchsel"|"done", side, role, info, pitch }
  h:decide(d)  h:bat(t)  h:pitch(t)  h:info()  h:done()  h:result()  -- result: Pennant's res (PL.apply)
  h.people, h.park                   -- for BallCast
  job = PEng.simJob(L, g)            -- an AI game for PJobs (sliced)

  Ratings: Pennant keeps a compact set (contact, power, eye, speed, fielding, arm; velocity,
  control, stuff, stamina) and maps it onto the engine's TS-shaped player here. Condition and
  fatigue shift the ratings, mood goes in as TS mood, league norms keep scoring level.
]]

PEng = PEng or {}

local floor, max, min = math.floor, math.max, math.min
local clamp = PM.clamp

-- (dev: a "pennant-lua.flag" in the Data folder forces the Lua engine, to test the fallback)
PEng.forceLua = playdate and playdate.file and playdate.file.exists("pennant-lua.flag") or false
function PEng.C() return not PEng.forceLua and pdsim ~= nil and pdsim._new ~= nil and pdsim.new ~= nil end
function PEng.name() return PEng.C() and "pdsim (C)" or "Lua fallback" end

local function pid(id) return "p" .. id end
local function nid(s) return tonumber(tostring(s):match("%d+")) end
PEng.nid = nid

-- Contract-format specs ----------------------------------------------------------------------------

--- condition + fatigue as rating points (mood goes in separately as TS mood)
local function form(p)
  local b = PM.COND_BONUS[p.cond or 3]
  local f = p.fat or 0
  if p.pos ~= "P" and f > 55 then b = b - (f - 55) / 7 end
  return b
end

function PEng.player(p, norm, slim)
  local r = p.r
  local b = form(p)
  local nb, np = norm and norm.bat or 0, norm and norm.pit or 0
  local function R(v, off) return clamp(floor(v + b - (off or 0) + 0.5), 15, 85) end
  -- (slim: background games; names and faces only matter to BallCast)
  local t = { id = pid(p.id), bats = p.bats, throws = p.throws, pos = p.pos, mood = (p.mood or 0) * 2 }
  if not slim then t.name, t.face, t.traits = PM.name(p), "face:" .. p.face, {} end
  if p.pos == "P" or not slim then t.recentPitches = p.rp or { 0, 0, 0, 0, 0 } end
  if p.inj then t.injury = { daysLeft = p.inj.d } end
  if p.pos == "P" then
    t.batting = { contact = 22, power = 20, eye = 25, gap = 20, lift = 40, pull = 50, speed = 30, baserunning = 30, vsL = 0 }
    t.fielding = { range = 40, hands = 45, arm = 55, accuracy = 45, reaction = 45, framing = 50, positions = { P = 1 } }
    local stuff = r.stf * 0.75 + r.velo * 0.25
    local ps = {}
    for i, pt in ipairs(p.pitches) do
      ps[i] = { kind = pt.k, quality = R(pt.q, np), velo = PM.mph(r.velo) + (PM.PITCH_DV[pt.k] or 0), usage = i == 1 and 50 or max(8, floor(pt.q - 22)) }
    end
    t.pitching = { stuff = R(stuff, np), control = R(r.ctl, np), command = R(r.ctl * 0.6 + r.stf * 0.4, np), movement = R(r.stf, np),
      stamina = clamp(floor(r.sta + 0.5), 15, 85), groundball = 50, hold = 50, pitches = ps }
  else
    local pos = { [p.pos] = 1 }
    if p.pos2 then pos[p.pos2] = 0.75 end
    pos["1B"] = pos["1B"] or 0.55
    pos.DH = 1
    t.batting = { contact = R(r.con, nb), power = R(r.pow, nb), eye = R(r.eye, nb), gap = R((r.con + r.pow) / 2, nb),
      lift = clamp(floor(48 + (r.pow - 50) * 0.4), 25, 75), pull = clamp(floor(50 + (r.pow - 50) * 0.3), 30, 70), speed = R(r.spd), baserunning = R(r.spd * 0.6 + 20), vsL = 0 }
    t.fielding = { range = R(r.fld * 0.8 + r.spd * 0.2), hands = R(r.fld), arm = R(r.arm), accuracy = R((r.fld + r.arm) / 2),
      reaction = R(r.fld), framing = p.pos == "C" and R(r.fld) or 50, positions = pos }
  end
  return t
end

--- noPlayers: list the active roster's ids in team.playerIds instead of building player tables
function PEng.team(L, abbr, ctrl, noPlayers)
  local T = L.teams[abbr]
  PL.todayCard(L, abbr)
  local notes = PRoster.validate(L, T)
  if abbr == L.user and #notes > 0 then L.lineupNotes = notes end
  local c = PennantClubs.byAbbr[abbr]
  local sp, idx = PRoster.starter(L, T)
  T.todaySp, T.todaySpIdx = sp, idx
  local t = { id = abbr, abbr = abbr, city = c.city, teamName = c.name, players = {}, lineup = {}, bench = {}, bullpen = {} }
  if noPlayers then t.playerIds = {} t.players = nil end
  for _, id in ipairs(T.ml) do
    local p = L.players[id]
    if p and not p.inj and (p.late or 0) <= 0 then
      if noPlayers then t.playerIds[#t.playerIds + 1] = id else t.players[#t.players + 1] = PEng.player(p, L.norm) end
    end
  end
  for _, id in ipairs(T.order) do t.lineup[#t.lineup + 1] = { id = pid(id), pos = T.field[id] or "DH" } end
  for _, id in ipairs(PRoster.bench(L, T)) do t.bench[#t.bench + 1] = pid(id) end
  t.starter = sp and pid(sp) or nil
  local RO = { CL = 1, SU = 2, MR = 3, LR = 4 }
  local pen = {}
  for id, role in pairs(T.pen or {}) do
    local p = L.players[id]
    if p and not p.inj and id ~= sp then pen[#pen + 1] = { id = pid(id), role = role, o = RO[role] or 3, q = PM.ovr(p) } end
  end
  table.sort(pen, function(a, b) if a.o ~= b.o then return a.o < b.o end return a.q > b.q end)
  for _, e in ipairs(pen) do t.bullpen[#t.bullpen + 1] = { id = e.id, role = e.role } end
  if ctrl then t.control = { manage = ctrl.manage == true, bat = ctrl.bat == true, pitch = ctrl.pitch == true, perPitch = false } end
  return t
end

--- Weather by date and park: warmer in summer, a breeze from any direction (deterministic).
function PEng.weather(L, g)
  local m = PL.calendar(L.day, L)
  local h = ((L.seed or 1) * 31 + L.day * 17 + (PennantClubs.byAbbr[g.h].idx or 1) * 7) % 997
  return { tempF = 52 + math.min(9, m) * 3 + h % 9, windDir = (h * 37) % 360 - 180, windMph = h % 12 }
end

function PEng.spec(L, g, ctrlFor, log)
  local c = PennantClubs.byAbbr[g.h]
  L.gseq = (L.gseq or 0) + 1
  return {
    seed = "pennant-" .. L.seed .. "-" .. L.season .. "-" .. L.day .. "-" .. g.h .. "-" .. L.gseq,
    home = PEng.team(L, g.h, ctrlFor and ctrlFor[g.h]),
    away = PEng.team(L, g.a, ctrlFor and ctrlFor[g.a]),
    park = PL.park(g.h),
    weather = PEng.weather(L, g),
    log = log,
  }
end

function PEng.peopleOf(spec)
  local out = {}
  for _, k in ipairs({ "home", "away" }) do
    local t = spec[k]
    local field = {}
    for _, s in ipairs(t.lineup or {}) do field[s.id] = s.pos end
    for _, p in ipairs(t.players) do out[p.id] = { id = p.id, name = p.name, face = p.face, teamAbbr = t.abbr, pos = field[p.id] or p.pos } end
  end
  return out
end

-- Box scores -> Pennant results ----------------------------------------------------------------------

--- pdsim box -> { home = side, away = side, innings, W, L, S } with per-player lines keyed by
--- Pennant ids (the same shape the Lua engine produces).
function PEng.resFromBox(box)
  local function side(s)
    local o = { runs = s.runs, hits = s.hits, errors = s.errors, lob = s.lob, line = {}, bat = {}, pitch = {}, pitchOrder = {}, order = {}, pc = {} }
    for i, v in ipairs(s.line or {}) do o.line[i] = (v >= 0) and v or nil end
    for _, b in ipairs(s.bat or {}) do
      local id = nid(b.id)
      o.order[#o.order + 1] = id
      local pa = (b.ab or 0) + (b.bb or 0) + (b.hbp or 0) + (b.sf or 0) + (b.sh or 0)
      o.bat[id] = { g = 1, pa = pa, ab = b.ab, r = b.r, h = b.h, d = b.d, t = b.t, hr = b.hr, rbi = b.rbi, bb = b.bb, k = b.k,
        sb = b.sb, cs = b.cs, hbp = b.hbp, sf = b.sf }
    end
    for i, p in ipairs(s.pitch or {}) do
      local id = nid(p.id)
      o.pitchOrder[#o.pitchOrder + 1] = id
      o.pitch[id] = { g = 1, gs = i == 1 and 1 or nil, outs = p.outs, h = p.h, r = p.r, er = p.er, bb = p.bb, k = p.k, hr = p.hr,
        hbp = p.hbp, np = p.pitches, bf = p.bf }
      o.pc[id] = p.pitches
    end
    return o
  end
  local res = { home = side(box.home), away = side(box.away), innings = box.innings or 9 }
  local d = box.decisions or {}
  local function mark(id, k)
    local n = id and nid(id)
    if not n then return nil end
    for _, sd in ipairs({ res.home, res.away }) do if sd.pitch[n] then sd.pitch[n][k] = 1 end end
    return n
  end
  res.W, res.L, res.S = mark(d.w, "w"), mark(d.l, "l"), mark(d.s, "sv")
  res.injuries = {}
  for _, inj in ipairs(box.injuries or {}) do res.injuries[#res.injuries + 1] = { id = nid(inj.id), kind = inj.kind, days = inj.days } end
  return res
end

--- The Lua engine's result already has Pennant ids; add pitch counts in the same field.
local function resFromStub(r)
  for _, k in ipairs({ "home", "away" }) do
    local s = r[k]
    s.pc = s.pc or {}
    for id, line in pairs(s.pitch) do s.pc[id] = line.np or 0 end
  end
  r.injuries = r.injuries or {}
  return r
end

-- AI games for the background queue -----------------------------------------------------------------

--- Each team encoded once a day for the C engine (pdsim.encodeTeam: json.encode of a roster costs
--- more than the game).
function PEng.encoded(L, abbr)
  local c = PEng.cache
  if not c or c.day ~= L.day or c.season ~= L.season then c = { day = L.day, season = L.season, t = {}, w = {} } PEng.cache = c end
  if not c.t[abbr] then
    while not PEng.encodeStep(L, abbr, 1000) do end
  end
  return c.t[abbr]
end

--- The same string pdsim.encodeTeam(team) makes, built a player at a time (json.encode of a
--- whole roster is one 30+ ms call on the device). Returns true when cache.t[abbr] is ready.
function PEng.encodeStep(L, abbr, ms)
  local c = PEng.cache
  if not c or c.day ~= L.day or c.season ~= L.season then c = { day = L.day, season = L.season, t = {}, w = {} } PEng.cache = c end
  if c.t[abbr] then return true end
  local t0 = playdate.getCurrentTimeMilliseconds()
  local w = c.w[abbr]
  if not w then
    -- step 1: the club's lineup / staff (no player tables yet)
    local team = PEng.team(L, abbr, nil, true)
    local ids = team.playerIds
    team.playerIds = nil
    w = { rest = json.encode(team), ids = ids, i = 1, out = {} }
    c.w[abbr] = w
    return false
  end
  -- then one player at a time: build his engine table and encode it
  while w.i <= #w.ids do
    w.out[#w.out + 1] = json.encode(PEng.player(L.players[w.ids[w.i]], L.norm, true))
    w.i = w.i + 1
    if playdate.getCurrentTimeMilliseconds() - t0 >= (ms or 6) then return false end
  end
  c.t[abbr] = '{"players":[' .. table.concat(w.out, ",") .. "]," .. w.rest:sub(2)
  c.w[abbr] = nil
  return true
end
function PEng.invalidate() PEng.cache = nil end

function PEng.simJob(L, g)
  local job = { what = "sim " .. g.a .. "@" .. g.h }
  local cj, gm
  function job.step(ms)
    if g.done then return true end
    if PEng.C() then
      if not cj then
        -- one roster encode per step (each costs a few ms of json.encode on the device)
        if not PEng.encodeStep(L, g.h, ms) then return false end
        if not PEng.encodeStep(L, g.a, ms) then return false end
        local spec = { seed = "pennant-" .. L.seed .. "-" .. L.season .. "-" .. L.day .. "-" .. g.h,
          home = PEng.encoded(L, g.h), away = PEng.encoded(L, g.a), park = PL.park(g.h) }
        spec.weather = PEng.weather(L, g)
        cj = pdsim.simulateStart(spec)
        return false
      end
      if job.box then
        -- the result in two more steps: convert, then apply
        if not job.res then job.res = PEng.resFromBox(job.box) return false end
        PL.apply(L, g, job.res)
        return true
      end
      local done, box = pdsim.simulateSlice(cj, math.max(2, math.min(ms or 6, 8)))
      if done then job.box = box end
      return false
    end
    if not gm then
      local spec = PL.spec(L, g, nil)
      spec.log = false
      gm = PSim.new(spec)
      return false
    end
    local t0 = playdate.getCurrentTimeMilliseconds()
    while playdate.getCurrentTimeMilliseconds() - t0 < math.max(2, ms or 5) do
      if gm:run(25) == "final" then PL.apply(L, g, resFromStub(gm:result())) return true end
    end
    return false
  end
  return job
end

--- Whole game now (tests, "sim to end").
function PEng.simNow(L, g)
  if PEng.C() then
    local box = pdsim.simulate(PEng.spec(L, g, nil, false))
    PL.apply(L, g, PEng.resFromBox(box))
  else
    local spec = PL.spec(L, g, nil)
    PL.apply(L, g, resFromStub(PSim.simulate(spec)))
  end
end

-- Live games -------------------------------------------------------------------------------------------

local CGame = {}
CGame.__index = CGame

function CGame:step(n, ms)
  local evs, pause = pdsim.step(self.g, n, ms)
  if pause and pause.reason == "done" then self.final = true end
  return evs, pause
end
function CGame:decide(d) return pdsim.decide(self.g, d) end
function CGame:bat(t) return pdsim.batInput(self.g, t) end
function CGame:pitch(t) return pdsim.pitchInput(self.g, t) end
function CGame:info() return pdsim.info(self.g) end
function CGame:done() return pdsim.done(self.g) end
function CGame:result() return PEng.resFromBox(pdsim.box(self.g)) end
--- (sim to end: hand both sides to the AI; unanswered pauses are AI calls)
function CGame:release()
  self.released = true
end

-- the Lua engine behind the same interface
local SGame = {}
SGame.__index = SGame

local function sid(id) return id and ("p" .. id) or nil end

function SGame:pauseOf()
  local g = self.g
  if g.status == "final" then return { reason = "done" } end
  if g.status ~= "decide" then return nil end
  local d = g.decision
  local p = { side = d.side, info = self:info() }
  if d.kind == "manage" then
    p.reason = "pa"
    p.role = d.offense and "off" or "def"
  elseif d.kind == "bat" then
    p.reason = "bat"
    p.role = "off"
    local pt = d.pitch
    p.pitch = { t = pt.k, v = pt.mph, px = pt.px / 0.83, pz = pt.pz - 2.5, zone = pt.z }
    p.take = d.take
  else
    p.reason = "pitchsel"
    p.role = "def"
  end
  return p
end

function SGame:step(n, ms)
  local g = self.g
  if g.status == "decide" then
    local resp = self.resp or { ai = true }
    self.resp = nil
    g:answer(resp)
  end
  local from = self.sent
  if g.status ~= "final" and g.status ~= "decide" then g:run(n or 40) end
  local evs = {}
  for i = from + 1, #g.log do evs[#evs + 1] = g.log[i] end
  self.sent = #g.log
  local pause = self:pauseOf()
  if pause and pause.reason == "done" then self.final = true end
  return evs, pause
end

local KIND <const> = { steal = "steal", bunt = "bunt", hitrun = "hitrun", squeeze = "bunt", ibb = "ibb", shift = "shift",
  pitch_around = "around", infield_in = "none" }
function SGame:decide(d)
  local g = self.g
  if g.status ~= "decide" or not g.decision or g.decision.kind ~= "manage" then return false, "no pause" end
  self.resp = self.resp or { list = {} }
  local c
  if d.kind == "pinch_hit" then c = { call = "ph", id = nid(d.id) }
  elseif d.kind == "pitch_change" then c = { call = "pc", id = nid(d.id), why = "manager" }
  else c = { call = KIND[d.kind] or "none" } end
  table.insert(self.resp.list, c)
  return true
end
function SGame:bat(t) self.resp = { swing = t.swing ~= false, timing = t.timing, aim = t.aim, power = t.power } return true end
function SGame:pitch(t) self.resp = { type = t.type, x = t.x, z = t.z, effort = t.effort } return true end
function SGame:done() return self.g.status == "final" end
function SGame:result() return resFromStub(self.g:result()) end
function SGame:release() end

--- The contract's info table from the Lua engine's state.
function SGame:info()
  local g = self.g
  local off, def = g:offense(), g:defense()
  local bat = off.order[off.slot]
  local bv = off.p[bat]
  local v = def.p[def.pit]
  local t = g:tired(def)
  local tb = off.bat[bat] or {}
  local pt = def.pitch[def.pit] or {}
  local pen = {}
  for _, id in ipairs(def.pen) do
    if not def.used[id] then pen[#pen + 1] = { id = sid(id), role = def.roles[id] or "MR", ready = (def.p[id].fat or 0) < 60 } end
  end
  local bench = {}
  for _, id in ipairs(off.bench) do bench[#bench + 1] = sid(id) end
  local ars = {}
  for _, x in ipairs(v.pitches) do ars[#ars + 1] = { kind = x.k, quality = x.q, velo = PM.mph(v.velo) + (PM.PITCH_DV[x.k] or 0) } end
  return {
    inn = g.inn, top = g.top, outs = g.outs, balls = g.balls or 0, strikes = g.strikes or 0,
    score = { home = g.home.runs, away = g.away.runs },
    bases = { g.bases[1] and sid(g.bases[1]) or false, g.bases[2] and sid(g.bases[2]) or false, g.bases[3] and sid(g.bases[3]) or false },
    batter = { id = sid(bat), bats = bv.bats, slot = off.slot, pos = off.field[bat], today = { ab = tb.ab or 0, h = tb.h or 0, hr = tb.hr or 0, bb = tb.bb or 0, k = tb.k or 0 } },
    onDeck = sid(off.order[off.slot % 9 + 1]),
    pitcher = { id = sid(def.pit), throws = v.throws, pitches = floor(def.pc[def.pit] or 0), cap = floor(35 + v.sta * 1.1), fatigue = max(0, t - 0.75),
      today = { outs = pt.outs or 0, h = pt.h or 0, r = pt.r or 0, er = pt.er or 0, bb = pt.bb or 0, k = pt.k or 0 } },
    bench = bench, pen = pen, arsenal = ars, orders = {},
  }
end

function PEng.newGame(L, g, ctrlFor)
  local h
  if PEng.C() then
    local spec = PEng.spec(L, g, ctrlFor, true)
    local gm, err = pdsim.new(spec)
    if not gm then print("[pennant] pdsim.new failed: " .. tostring(err)) end
    if gm then
      h = setmetatable({ g = gm, spec = spec }, CGame)
      h.people = PEng.peopleOf(spec)
    end
  end
  if not h then
    local spec = PL.spec(L, g, ctrlFor)
    h = setmetatable({ g = PSim.new(spec), spec = spec, sent = 0 }, SGame)
    h.people = PL.people(spec)
  end
  h.park = PL.park(g.h)
  h.home, h.away = g.h, g.a
  return h
end
