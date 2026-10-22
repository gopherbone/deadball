--[[ Pennant self-test (Simulator or device): fast-forward whole seasons on the real engine and
  print what matters to the log (debug.log with debug.flag):
    league batting/pitching rates, standings spread, leaders and awards, training gains by
    intensity, injuries, per-game engine time, the worst frame slice, memory, and a save/load
    round trip (slot 9, erased afterwards).
  Trigger: a file "pennant-sim.flag" in the Data folder; its first line (optional) is the number
  of seasons (default 2). Writes "pennant-sim.done" when finished. Runs as a scene in ~25 ms
  slices, so the Simulator stays responsive (and the device watchdog stays happy).
]]

PennantTest = PennantTest or {}
local gfx <const> = playdate.graphics

local Scene = { opaque = true }
Scene.__index = Scene

local function now() return playdate.getCurrentTimeMilliseconds() end
local function log(...) print("[pntest] " .. string.format(...)) end

function PennantTest.run(seasons)
  local s = setmetatable({ seasons = seasons or 2 }, Scene)
  App.push(s)
end

function Scene:enter()
  self.msg = "starting"
  self.worst = 0
  self.co = coroutine.create(function() self:body() end)
end

function Scene:update()
  local t0 = now()
  self.sliceStart = t0
  if self.co and coroutine.status(self.co) ~= "dead" then
    local ok, e = coroutine.resume(self.co)
    if not ok then log("ERROR %s", tostring(e)) self.co = nil self.msg = "error" PennantTest.finish() end
  end
  local dt = now() - t0
  if dt > self.worst and self.started then self.worst = dt end
  gfx.clear(gfx.kColorWhite)
  Text.draw("Pennant self-test (" .. PEng.name() .. ")", 200, 90, UI.fonts.head, nil, "center")
  Text.draw(self.msg or "", 200, 116, UI.fonts.body, nil, "center")
end

--- yield when this frame's slice is spent
function Scene:Y()
  if now() - self.sliceStart > 25 then coroutine.yield() end
end

local function rates(L)
  local b, p = {}, {}
  for _, pl in pairs(L.players) do PM.addStats(b, pl.st.b) PM.addStats(p, pl.st.p) end
  local G = 0
  for _, T in pairs(L.teams) do G = G + T.w + T.l end
  return b, p, G
end

function Scene:body()
  local seed = 777
  self.msg = "generating"
  collectgarbage("collect")
  local m0 = collectgarbage("count")
  local t0 = now()
  local L = PGen.league(seed, "HCL", 84, function() self:Y() end)
  PL.init(L)
  local genMs = now() - t0
  collectgarbage("collect")
  log("engine %s; league generated in %d ms; %d players; league data %d KB in memory", PEng.name(), genMs,
    (function() local n = 0 for _ in pairs(L.players) do n = n + 1 end return n end)(), math.floor(collectgarbage("count") - m0))
  -- the user's farm hitters train power, half Hard and half Normal (to compare); the big club
  -- keeps the coaches' default plans, so its record is a fair check on the user side
  local T = L.teams.HCL
  local k = 0
  for _, id in ipairs(T.farm) do
    local p = L.players[id]
    -- (individual plans: the club program leaves them be)
    if p.pos ~= "P" then k = k + 1 p.plan = { f = "pow", i = (k % 2 == 0) and 3 or 2 } PWeek.setOwn(L, p.id, true) end
  end
  self.started = true
  for season = 1, self.seasons do
    local snap = {}
    for _, id in ipairs(T.farm) do snap[id] = L.players[id].r.pow end
    local games, gameMs, worstGame, injuries = 0, 0, 0, 0
    while L.phase ~= "awards" do
      self.msg = string.format("season %d: %s, %s", season, PL.date(L, math.min(L.day, #L.sched)), L.phase)
      for _, g in ipairs(PL.pending(L)) do
        local t = now()
        PEng.simNow(L, g)
        local d = now() - t
        games = games + 1
        gameMs = gameMs + d
        if d > worstGame then worstGame = d end
        self:Y()
      end
      L.alerts = {}
      PL.finishDay(L)
      for _, a in ipairs(L.alerts) do if a.kind == "inj" then injuries = injuries + 1 end end
      self:Y()
    end
    local b, p, G = rates(L)
    log("season %d (%d): %d games, engine %.1f ms/game (worst %d ms)", season, L.year, games, gameMs / math.max(1, games), worstGame)
    log("  R/G %.2f  AVG %s OBP %s SLG %s  HR/G %.2f  K%% %.1f  BB%% %.1f  SB/G %.2f  ERA %.2f  P/PA %.2f",
      (b.r or 0) / G, PM.rate3(PM.avg(b)), PM.rate3(PM.obp(b)), PM.rate3(PM.slg(b)), (b.hr or 0) / G,
      100 * (b.k or 0) / math.max(1, b.pa or 1), 100 * (b.bb or 0) / math.max(1, b.pa or 1), (b.sb or 0) / G, PM.era(p), (p.np or 0) / math.max(1, b.pa or 1))
    local st = {}
    for i, TT in ipairs(PL.standings(L)) do st[#st + 1] = string.format("%s %d-%d", TT.abbr, TT.w, TT.l) end
    log("  standings: %s", table.concat(st, ", "))
    log("  champion %s over %s", tostring(L.champ), tostring(L.runnerUp))
    local A = L.awardsRes or {}
    local function nm(id) local x = id and L.players[id] return x and (PM.name(x) .. " " .. x.team) or "-" end
    log("  MVP %s, Pitcher %s, Rookie %s", nm(A.mvp), nm(A.cy), nm(A.roy))
    for _, key in ipairs({ "avg", "hr", "rbi", "era", "w", "sv" }) do
      local l = A.lead and A.lead[key]
      if l then log("  lead %s: %s %s", key, nm(l.id), PL.leaderText(key, l.v)) end
    end
    local dn, dh, cn, ch = 0, 0, 0, 0
    for _, id in ipairs(T.farm) do
      local pl = L.players[id]
      if pl and pl.pos ~= "P" and snap[id] then
        if pl.plan.i == 3 then dh = dh + pl.r.pow - snap[id] ch = ch + 1 else dn = dn + pl.r.pow - snap[id] cn = cn + 1 end
      end
    end
    log("  training: power %+.1f on Normal (n=%d), %+.1f on Hard (n=%d); HCL injuries %d", dn / math.max(1, cn), cn, dh / math.max(1, ch), ch, injuries)
    log("  memory %d KB", math.floor(collectgarbage("count")))
    -- save / load round trip
    local ts = now()
    local j = PSave.begin(L, 9)
    local steps, worstStep = 0, 0
    while true do
      local t1 = now()
      local done = j.step()
      local d = now() - t1
      steps = steps + 1
      if d > worstStep then worstStep = d end
      if done then break end
      self:Y()
    end
    local saveMs = now() - ts
    ts = now()
    local L2 = PSave.load(9)
    local loadMs = now() - ts
    local same = L2 and L2.teams.HCL.w == T.w and (function()
      for id, pl in pairs(L.players) do
        local q = L2.players[id]
        if not q or q.r.pow ~= pl.r.pow or (q.st.b.h or 0) ~= (pl.st.b.h or 0) then return false end
      end
      return true
    end)()
    log("  save: %d datastore files, %d ms total, worst file %d ms; load %d ms; round trip %s", steps, saveMs, worstStep, loadMs, same and "OK" or "MISMATCH")
    -- the week turn's club state: kept by the round trip, defaulted for a save from before it
    if L2 then
      local kept = L2.club and L2.club.fac and L2.club.fac.bat == L.club.fac.bat and L2.club.energy == L.club.energy
      L2.club = nil
      local ok = pcall(function() PWeek.ensure(L2) PWeek.units(L2, L2.user) PWeek.preview(L2, "bat", 2) end)
      log("  week state: round trip %s; old-save migration %s", kept and "OK" or "MISMATCH", (ok and L2.club and L2.club.energy) and "OK" or "FAILED")
    end
    if season < self.seasons then
      self.msg = "offseason"
      local rep = PL.offseason(L)
      log("  offseason: %d retired (HCL), %d rookies (HCL)", #rep.retired, #rep.rookies)
    end
  end
  PSave.delete(9)
  log("worst frame slice %d ms", self.worst)
  log("done")
  self.msg = "done"
  PennantTest.finish()
end

function PennantTest.finish()
  local f = playdate.file.open("pennant-sim.done", playdate.file.kFileWrite)
  if f then f:write("ok\n") f:close() end
end

if playdate.file.exists("pennant-sim.flag") then
  local f = playdate.file.open("pennant-sim.flag", playdate.file.kFileRead)
  local line = f and f:readline()
  if f then f:close() end
  if line and line:match("^programs") then
    -- "programs [games] [seed]": one season per week-program policy on the same league
    local n, seed = line:match("^programs%s*(%d*)%s*(%d*)")
    PennantTest.progOpts = { games = tonumber(n), seed = tonumber(seed) }
    playdate.frameTimer.performAfterDelay(20, function() PennantTest.programs() end)
  elseif line and line:match("^restsim") then
    -- "restsim [games] [seed]": the same season with the auto-rest off, then on (pennant/rest.lua)
    local n, seed, var = line:match("^restsim%s*(%d*)%s*(%d*)%s*(%a*)")
    PennantTest.restOpts = { games = tonumber(n), seed = tonumber(seed) }
    -- ("nopen": the plan leaves the bullpen alone)
    PRest.noPen = var == "nopen" or nil
    playdate.frameTimer.performAfterDelay(20, function() PennantTest.restsim() end)
  elseif line and line:match("^legacy") then
    -- "legacy [runs] [seed] [heat] [games] [base]": a chain of runs, each banking alumni for the
    -- next one's legacy and deck (pennant/testlegacy.lua)
    local n, seed, heat, games, base = line:match("^legacy%s*(%d*)%s*(%d*)%s*(%d*)%s*(%d*)%s*(%a*)")
    PennantTest.legOpts = { runs = tonumber(n), seed = tonumber(seed), heat = tonumber(heat), games = tonumber(games), base = base == "base" }
    playdate.frameTimer.performAfterDelay(20, function() PennantTest.legacy() end)
  elseif line and line:match("^bench") then
    playdate.frameTimer.performAfterDelay(20, function() PennantTest.bench() end)
  elseif line and line:match("^bots") then
    -- "bots [scheme] [games] [seed]": e.g. "bots scout 120 777"
    local only, n, seed = line:match("^bots%s*(%a*)%s*(%d*)%s*(%d*)")
    PennantTest.botOpts = { only = (only ~= "" and only) or nil, games = tonumber(n), seed = tonumber(seed) }
    playdate.frameTimer.performAfterDelay(20, function() PennantTest.bots() end)
  else
    local n = tonumber(line or "") or 2
    playdate.frameTimer.performAfterDelay(20, function() PennantTest.run(n) end)
  end
end

-- Device bench ("pennant-sim.flag" first line "bench"): one week through the same sliced
-- paths, timing every phase, so the slow piece shows up by name in the serial log.
local Bench = { opaque = true }
Bench.__index = Bench

local function stat() return { n = 0, sum = 0, max = 0 } end
local function add(s, d) s.n = s.n + 1 s.sum = s.sum + d if d > s.max then s.max = d end end
local function show(name, s) if s.n > 0 then log("bench %-22s n %4d  avg %6.1f  max %4d ms", name, s.n, s.sum / s.n, s.max) end end

function PennantTest.bench()
  local s = setmetatable({}, Bench)
  App.push(s)
end

function Bench:enter()
  self.co = coroutine.create(function() self:body() end)
  self.st = {}
end
function Bench:S(k) self.st[k] = self.st[k] or stat() return self.st[k] end
function Bench:update()
  if self.co and coroutine.status(self.co) ~= "dead" then
    local ok, e = coroutine.resume(self.co)
    if not ok then log("bench ERROR %s", tostring(e)) self.co = nil PennantTest.finish() end
  end
  gfx.clear(gfx.kColorWhite)
  Text.draw("Pennant bench", 200, 110, UI.fonts.head, nil, "center")
end
function Bench:T(k, fn)
  local t = now()
  local a, b, c = fn()
  add(self:S(k), now() - t)
  coroutine.yield()
  return a, b, c
end

function Bench:body()
  local L = self:T("generate", function() return PGen.league(4242, "HCL", 84) end)
  self:T("init", function() PL.init(L) end)
  L.slot = 9
  Pennant.L = L
  for d = 1, 7 do
    for _, g in ipairs(PL.pending(L)) do
      if PEng.C() then
        for _, ab in ipairs({ g.h, g.a }) do
          while true do
            local t = now()
            local ok = PEng.encodeStep(L, ab, 8)
            add(self:S("team encode step"), now() - t)
            coroutine.yield()
            if ok then break end
          end
        end
        local spec = { seed = "b" .. d .. g.h, home = PEng.encoded(L, g.h), away = PEng.encoded(L, g.a), park = PL.park(g.h) }
        self:T("spec weather/park", function() spec.weather = PEng.weather(L, g) end)
        local job = self:T("simulateStart", function() return pdsim.simulateStart(spec) end)
        local done, box
        repeat
          local t = now()
          done, box = pdsim.simulateSlice(job, 8)
          add(self:S(done and "slice (last, +box json)" or "slice 8ms"), now() - t)
          coroutine.yield()
        until done
        local res = self:T("resFromBox", function() return PEng.resFromBox(box) end)
        self:T("PL.apply", function() PL.apply(L, g, res) end)
      else
        self:T("lua sim game", function() PL.simGame(L, g) end)
      end
    end
    -- the day's close, timed between yields
    local last = now()
    local co = coroutine.create(function()
      local t1 = now()
      local tl = now()
      PennantUI.closeDay(function(label)
        local d = now() - tl
        add(self:S("close: " .. tostring(label or "?")), d)
        tl = now()
        if now() - t1 >= 8 then coroutine.yield() t1 = now() tl = now() end
      end, true)
    end)
    while coroutine.status(co) ~= "dead" do
      local t = now()
      local ok, e = coroutine.resume(co)
      if not ok then log("bench close ERROR %s", tostring(e)) break end
      add(self:S("close piece"), now() - t)
      coroutine.yield()
    end
  end
  -- a save through the job, by phase
  local j = PSave.begin(L, 9)
  while true do
    local ph = j.phase()
    local t = now()
    local done = j.step(10)
    add(self:S("save step " .. ph), now() - t)
    coroutine.yield()
    if done then break end
  end
  PSave.delete(9)
  local keys = {}
  for k in pairs(self.st) do keys[#keys + 1] = k end
  table.sort(keys)
  for _, k in ipairs(keys) do show(k, self.st[k]) end
  log("done")
  PennantTest.finish()
end

-- Simulated humans ("pennant-sim.flag" first line "bots"): the user club's games played through each
-- control scheme's mapping by bots of three skill levels, on the real engine; prints the batting
-- line the "human" produces and the line opponents hit off "human" pitching, vs the coaches.
local Bots = { opaque = true }
Bots.__index = Bots
function PennantTest.bots() App.push(setmetatable({}, Bots)) end
function Bots:enter() self.co = coroutine.create(function() self:body() end) end
function Bots:update()
  if self.co and coroutine.status(self.co) ~= "dead" then
    local ok, e = coroutine.resume(self.co)
    if not ok then log("bots ERROR %s", tostring(e)) self.co = nil PennantTest.finish() end
  end
  gfx.clear(gfx.kColorWhite)
  Text.draw("Pennant bots: " .. tostring(self.msg), 200, 110, UI.fonts.body, nil, "center")
end

local SKILL <const> = {
  great = { t = 0.030, c = 0.12, guess = 0.70, m = 0.05, call = 0.8 },
  decent = { t = 0.050, c = 0.22, guess = 0.58, m = 0.10, call = 0.7 },
  poor = { t = 0.085, c = 0.35, guess = 0.45, m = 0.18, call = 0.5 },
}

local function botBat(scheme, sk, p, L, rng)
  local i = p.info
  local pt = p.pitch
  local b = L.players[PEng.nid(i.batter.id)]
  local strike = math.max(math.abs(pt.px), math.abs(pt.pz)) < 1
  if scheme == "arcade" then
    if not rng:chance(strike and 0.70 or 0.28) then return { swing = false } end
    local raw = { dt = rng:normal(0, sk.t) * 0.6, bx = pt.px, bz = pt.pz,
      cx = pt.px + rng:normal(0, sk.c), cz = pt.pz + rng:normal(0, sk.c), power = rng:chance(0.15) }
    return PScheme.arcadeBat(raw, b.r.con)
  else
    local fast = PScheme.isFast(pt.t)
    local choice
    local x = rng:float()
    if x < 0.15 then choice = "see"
    elseif x < 0.85 then choice = rng:chance(sk.guess) and (fast and "fast" or "soft") or (fast and "soft" or "fast")
    else choice = rng:chance(sk.guess) and (PScheme.inside(pt.px, i.batter.bats) and "in" or "away") or (PScheme.inside(pt.px, i.batter.bats) and "away" or "in") end
    local r = PScheme.scoutBat(choice, pt, { con = b.r.con, eye = b.r.eye, bats = i.batter.bats, strikes = i.strikes }, rng)
    return r
  end
end

local function botPitch(scheme, sk, p, L, rng)
  local i = p.info
  local pit = L.players[PEng.nid(i.pitcher.id)]
  local typ, spot = PScheme.catcherCall(i.arsenal or {}, i.balls, i.strikes, i.batter.bats, rng)
  if not rng:chance(sk.call) then spot = rng:int(13) local a = (i.arsenal or {})[rng:int(math.max(1, #(i.arsenal or {})))] typ = a and a.kind or typ end
  if scheme == "scout" then return PScheme.scoutPitch(typ, spot, rng:chance(0.08)) end
  local x, z = PScheme.spotXY(spot)
  local m = PScheme.BAND_C + rng:normal(0, sk.m)
  if rng:chance(0.08) then m = 0.95 end
  return (PScheme.arcadePitch({ type = typ, x = x, z = z }, math.max(0, math.min(1, m)), pit.r.ctl, rng))
end

function Bots:body()
  local configs = { { "coaches" } }
  local opt = PennantTest.botOpts or {}
  for _, s in ipairs({ "arcade", "scout" }) do
    if not opt.only or opt.only == s then for _, k in ipairs({ "great", "decent", "poor" }) do configs[#configs + 1] = { s, k } end end
  end
  for _, cfg in ipairs(configs) do
    local scheme, skill = cfg[1], cfg[2]
    local sk = SKILL[skill or "decent"]
    local L = PGen.league(opt.seed or 31337, "HCL", 84)
    PL.init(L)
    Pennant.L = L
    local rng = PRng.new(99)
    local bat, opp = {}, {}
    local games = 0
    while games < (opt.games or 40) and L.phase == "season" do
      local g = PL.gameFor(L, "HCL")
      if g and not g.done then
        self.msg = scheme .. " " .. (skill or "") .. " game " .. games
        local ctrl = scheme ~= "coaches" and { HCL = { manage = true, bat = true, pitch = true } } or nil
        local h = PEng.newGame(L, g, ctrl)
        local guard = 0
        while not h:done() and guard < 20000 do
          guard = guard + 1
          local evs, p = h:step(200)
          if p and p.reason ~= "done" and scheme ~= "coaches" then
            if p.reason == "bat" then h:bat(botBat(scheme, sk, p, L, rng))
            elseif p.reason == "pitchsel" then h:pitch(botPitch(scheme, sk, p, L, rng))
            elseif p.reason == "pa" and p.role == "def" and (p.info.pitcher.fatigue or 0) > 0.2 then
              for _, e in ipairs(p.info.pen or {}) do if e.ready then h:decide({ kind = "pitch_change", id = e.id }) break end end
            end
          end
          if guard % 40 == 0 then coroutine.yield() end
        end
        local res = h:result()
        local mine = g.h == "HCL" and res.home or res.away
        local theirs = g.h == "HCL" and res.away or res.home
        for _, line in pairs(mine.bat) do PM.addStats(bat, line) end
        for _, line in pairs(theirs.bat) do PM.addStats(opp, line) end
        PL.apply(L, g, res)
        games = games + 1
      end
      for _, og in ipairs(PL.pending(L)) do PEng.simNow(L, og) end
      PL.finishDay(L)
      coroutine.yield()
    end
    local function line(s) return string.format("AVG %s OBP %s SLG %s K%% %4.1f BB%% %4.1f HR/PA %.3f",
      PM.rate3(PM.avg(s)), PM.rate3(PM.obp(s)), PM.rate3(PM.slg(s)), 100 * (s.k or 0) / math.max(1, s.pa or 1), 100 * (s.bb or 0) / math.max(1, s.pa or 1), (s.hr or 0) / math.max(1, s.pa or 1)) end
    log("bots %-7s %-6s  HCL bats: %s", scheme, skill or "", line(bat))
    log("bots %-7s %-6s  vs HCL:   %s", scheme, skill or "", line(opp))
  end
  log("done")
  PennantTest.finish()
end

-- Week programs ("pennant-sim.flag" first line "programs [games] [seed]"): the same league played
-- once per program policy (pennant/week.lua), the user club run through the real week turn
-- (beginWeek / endWeek, events, plans, goals, rewards; every game simmed). Prints the season
-- line, unit grades start -> end vs the AI clubs, and the mean rating gains per key.
local Progs = { opaque = true }
Progs.__index = Progs
function PennantTest.programs() App.push(setmetatable({}, Progs)) end
function Progs:enter() self.co = coroutine.create(function() self:body() end) self.msg = "" end
function Progs:update()
  self.t0 = now()
  if self.co and coroutine.status(self.co) ~= "dead" then
    local ok, e = coroutine.resume(self.co)
    if not ok then log("programs ERROR %s", tostring(e)) self.co = nil PennantTest.finish() end
  end
  gfx.clear(gfx.kColorWhite)
  Text.draw("Pennant programs: " .. tostring(self.msg), 200, 110, UI.fonts.body, nil, "center")
end
function Progs:Y() if now() - self.t0 > 40 then coroutine.yield() end end

local BATK <const> = { "con", "pow", "eye", "spd", "fld", "arm" }
local PITK <const> = { "velo", "ctl", "stf", "sta" }

function Progs:season(policy, opt)
  local L = PGen.league(opt.seed or 777, "HCL", opt.games or 84, function() self:Y() end)
  PL.init(L)
  Pennant.L = L
  local c = L.club
  local T = L.teams.HCL
  local snap = {}
  for id, p in pairs(L.players) do snap[id] = PM.snapshot(p) end
  local u0 = {}
  for _, cl in ipairs(PennantClubs) do u0[cl.abbr] = PWeek.units(L, cl.abbr) end
  local rot = { "bat", "arms", "def", "gym", "farm" }
  local ri, rests, fails, events, wk = 0, 0, 0, 0, 0
  local function choose()
    if policy == "coach" then
      for _, list in ipairs({ T.ml, T.farm }) do for _, id in ipairs(list) do c.own[tostring(id)] = true end end
      PL.aiPlan(L, T)
      c.prog, c.int = "farm", 2
      return
    end
    local prog, int = policy, 2
    if policy == "bathard" then prog, int = "bat", 3 end
    if policy == "rotate" then ri = ri % 5 + 1 prog = rot[ri] end
    if PWeek.energy(L) < 40 and PWeek.canRest(L) and policy ~= "farm" then
      prog = "rest" rests = rests + 1
      if policy == "rotate" then ri = ri - 1 end
    end
    c.prog, c.int = prog, int
  end
  local injuries = 0
  while L.phase ~= "awards" do
    self.msg = policy .. " " .. PL.date(L, math.min(L.day, #L.sched))
    if not c.wk or PWeek.weekDone(L) then
      if c.wk then local r = PWeek.endWeek(L) if r and r.fail then fails = fails + 1 end end
      if c.goalOffer then PWeek.pickGoal(L, 1) end
      while c.rewards and #c.rewards > 0 do PWeek.claim(L, "fac") end
      c.monthNote = nil
      if L.phase == "season" or PWeek.userSeries(L) then
        choose()
        PWeek.beginWeek(L)
        wk = wk + 1
        local ks = PWeek.keySeries(L)
        if ks and policy ~= "coach" then PWeek.choosePlan(L, ks, PWeek.planOptions(L, ks.opp)[1]) end
      end
    end
    for _, st in ipairs(PWeek.dueStops(L)) do
      if st.stop.id == "clubhouse" then PWeek.resolveEvent(L, PL.rng(L, 5):int(3)) events = events + 1 end
    end
    L.alerts = {}
    for _, g in ipairs(PL.pending(L)) do PEng.simNow(L, g) self:Y() end
    L.trainerQ = nil
    PL.finishDay(L)
    for _, a in ipairs(L.alerts) do if a.kind == "inj" and L.players[a.id] and L.players[a.id].team == "HCL" then injuries = injuries + 1 end end
    self:Y()
  end
  -- results
  local b, p, G = rates(L)
  local st = {}
  for _, TT in ipairs(PL.standings(L)) do st[#st + 1] = string.format("%s %d-%d", TT.abbr, TT.w, TT.l) end
  local cleared = 0
  for _, g in ipairs(c.goals) do if g.state == "done" then cleared = cleared + 1 end end
  local facs = {}
  for _, k in ipairs(PWeek.PROGS) do facs[#facs + 1] = k .. c.fac[k] end
  log("programs %-7s HCL %d-%d (%s), champ %s, R/G %.2f, weeks %d, rests %d, fails %d, events %d, inj %d, goals %d/%d, energy %d, fac %s",
    policy, T.w, T.l, PUI.ord(PL.rank(L, "HCL")), tostring(L.champ), (b.r or 0) / G, wk, rests, fails, events, injuries,
    cleared, #c.goals, PWeek.energy(L), table.concat(facs, ","))
  log("programs %-7s standings %s", policy, table.concat(st, ", "))
  local u1 = PWeek.units(L, "HCL")
  local ai = {}
  for _, cl in ipairs(PennantClubs) do
    if cl.abbr ~= "HCL" then
      local a = PWeek.units(L, cl.abbr)
      for _, k in ipairs(PWeek.UNITS) do ai[k] = (ai[k] or 0) + (a[k] - u0[cl.abbr][k]) / 7 end
    end
  end
  local parts = {}
  for _, k in ipairs(PWeek.UNITS) do parts[#parts + 1] = string.format("%s %.1f>%.1f (%+.1f, AI %+.1f)", k, u0.HCL[k], u1[k], u1[k] - u0.HCL[k], ai[k]) end
  log("programs %-7s units %s", policy, table.concat(parts, "  "))
  -- per-key gains: big-leaguers who were there at the start
  local function gains(filter)
    local s, n = {}, {}
    for id, q in pairs(L.players) do
      if snap[id] and q.lvl == "ML" and filter(q) then
        local keys = q.pos == "P" and PITK or BATK
        local grp = q.pos == "P" and "p" or "b"
        n[grp] = (n[grp] or 0) + 1
        for _, k in ipairs(keys) do s[k] = (s[k] or 0) + (q.r[k] - snap[id][k]) end
      end
    end
    local out = {}
    for _, k in ipairs(BATK) do out[#out + 1] = string.format("%s %+.1f", k, (s[k] or 0) / math.max(1, n.b or 0)) end
    for _, k in ipairs(PITK) do out[#out + 1] = string.format("%s %+.1f", k, (s[k] or 0) / math.max(1, n.p or 0)) end
    return table.concat(out, " ")
  end
  log("programs %-7s HCL gains %s", policy, gains(function(q) return q.team == "HCL" end))
  log("programs %-7s AI  gains %s", policy, gains(function(q) return q.team ~= "HCL" end))
  local fs, fn = 0, 0
  for _, id in ipairs(T.farm) do
    local q = L.players[id]
    if snap[id] then
      local r = q.r
      local now1 = PM.ovr(q)
      q.r = snap[id]
      local was = PM.ovr(q)
      q.r = r
      fs, fn = fs + now1 - was, fn + 1
    end
  end
  log("programs %-7s farm OVR %+.1f (n=%d)", policy, fs / math.max(1, fn), fn)
end

function Progs:body()
  local opt = PennantTest.progOpts or {}
  for _, policy in ipairs({ "coach", "bat", "bathard", "arms", "def", "gym", "farm", "rotate" }) do
    self:season(policy, opt)
    Pennant.L = nil
    collectgarbage("collect")
  end
  log("done")
  PennantTest.finish()
end

-- Rest the tired ("pennant-sim.flag" first line "restsim [games] [seed]"): one league played twice
-- through the real week turn (the rotate program, a rest week under 40 energy, every game simmed),
-- L.settings.autoRest off then on. Prints wins, injuries, the fatigue cost in the lineup (rating
-- points a lineup slot a game) and how many rests were made.
local RestSim = { opaque = true }
RestSim.__index = RestSim
function PennantTest.restsim() App.push(setmetatable({}, RestSim)) end
function RestSim:enter() self.co = coroutine.create(function() self:body() end) self.msg = "" end
RestSim.update = Progs.update
RestSim.Y = Progs.Y

function RestSim:season(auto, hard, opt)
  local L = PGen.league(opt.seed or 777, "HCL", opt.games or 84, function() self:Y() end)
  PL.init(L)
  -- (the C engine's day cache is keyed by day and season only: a new league mustn't reuse it)
  PEng.invalidate()
  L.gseq = 0
  Pennant.L = L
  L.settings.autoRest = auto or nil
  local c = L.club
  local T = L.teams.HCL
  local rot = { "bat", "arms", "def", "gym", "farm" }
  local ri = 0
  local games, slots, cost, tiredSlots, injuries, spTired = 0, 0, 0, 0, 0, 0
  -- (hard: every big-league hitter on his own HARD plan, the way a club gets worn out; the
  -- programs alone keep a lineup under the line)
  if hard then
    for _, id in ipairs(T.ml) do
      local p = L.players[id]
      if p.pos ~= "P" then c.own[tostring(id)] = true p.plan = { f = "pow", i = 3 } end
    end
  end
  local kinds = { bat = 0, sp = 0, pen = 0 }
  local apply0 = PRest.apply
  PRest.apply = function(L2, rows, mode)
    for _, r in ipairs(rows) do if r.on and (r.sub or r.k == "pen") then kinds[r.k] = kinds[r.k] + 1 end end
    return apply0(L2, rows, mode)
  end
  while L.phase ~= "awards" do
    self.msg = (auto and "auto-rest " or "no rest ") .. PL.date(L, math.min(L.day, #L.sched))
    if not c.wk or PWeek.weekDone(L) then
      if c.wk then PWeek.endWeek(L) end
      if c.goalOffer then PWeek.pickGoal(L, 1) end
      while c.rewards and #c.rewards > 0 do PWeek.claim(L, "fac") end
      c.monthNote = nil
      if L.phase == "season" or PWeek.userSeries(L) then
        ri = ri % 5 + 1
        local prog = rot[ri]
        if PWeek.energy(L) < 40 and PWeek.canRest(L) then prog = "rest" ri = ri - 1 end
        c.prog, c.int = prog, 2
        PWeek.beginWeek(L)
      end
    end
    for _, st in ipairs(PWeek.dueStops(L)) do
      if st.stop.id == "clubhouse" then PWeek.resolveEvent(L, PL.rng(L, 5):int(3)) end
    end
    L.alerts = {}
    local g = PL.gameFor(L, "HCL")
    if g and not g.done and L.phase == "season" then
      -- today's lineup as it goes in (the card, the returns and the auto-rest: PL.todayCard)
      PL.todayCard(L, "HCL")
      PRoster.validate(L, T)
      games = games + 1
      for _, id in ipairs(T.order) do
        local p = L.players[id]
        slots = slots + 1
        if (p.fat or 0) > 55 then tiredSlots = tiredSlots + 1 cost = cost + ((p.fat or 0) - 55) / 7 end
      end
      local sp = PRoster.starter(L, T)
      if sp and (L.players[sp].fat or 0) >= PRest.SP_TIRED then spTired = spTired + 1 end
    end
    for _, gg in ipairs(PL.pending(L)) do PEng.simNow(L, gg) self:Y() end
    L.trainerQ = nil
    PL.finishDay(L)
    for _, a in ipairs(L.alerts) do if a.kind == "inj" and L.players[a.id] and L.players[a.id].team == "HCL" then injuries = injuries + 1 end end
    self:Y()
  end
  PRest.apply = apply0
  log("restsim %-4s %-5s HCL %d-%d (%s) RS %d RA %d, inj %d, rests bat %d sp %d pen %d, tired slots %.1f%%, fatigue cost %.3f pts/slot/game, SP due tired %d",
    auto and "ON" or "OFF", hard and "HARD" or "PROG", T.w, T.l, PUI.ord(PL.rank(L, "HCL")), T.rs, T.ra, injuries, kinds.bat, kinds.sp, kinds.pen,
    100 * tiredSlots / math.max(1, slots), cost / math.max(1, slots), spTired)
end

function RestSim:body()
  local opt = PennantTest.restOpts or {}
  for _, hard in ipairs({ false, true }) do
    for _, auto in ipairs({ false, true }) do
      self:season(auto, hard, opt)
      Pennant.L = nil
      collectgarbage("collect")
    end
  end
  log("restsim done")
  PennantTest.finish()
end
