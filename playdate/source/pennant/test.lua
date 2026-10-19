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
  local n = tonumber(line or "") or 2
  playdate.frameTimer.performAfterDelay(20, function() PennantTest.run(n) end)
end
