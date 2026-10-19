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
    if p.pos ~= "P" then k = k + 1 p.plan = { f = "pow", i = (k % 2 == 0) and 3 or 2 } end
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
  if line and line:match("^bench") then
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
