-- pdsim Simulator test (NOT imported by the game): used as main.lua in a scratch build. It
-- exercises the Lua API (simulate, slices, a fully human-managed/controlled game with every
-- decision kind), times it, then plays pdsim games in BallCast (final and live) and saves
-- screenshots. See playdate/c/pdsim_test/simtest.sh.
--
-- Reads PDSIM_SPEC (default "pdsim_demo_spec.json", from `host dumpspec`); screenshots go to
-- PDSIM_OUT (default /tmp/). Logs to Data/<bundle>/pdsim_simtest.log.

import "CoreLibs/object"
import "CoreLibs/graphics"
import "CoreLibs/timer"
import "CoreLibs/frameTimer"
import "CoreLibs/crank"
import "app/scene"
import "ballcast/ballcast"
import "pdsim/pdsim"
import "pdsim/replay"

local gfx <const> = playdate.graphics
playdate.display.setRefreshRate(30)
local OUT = PDSIM_OUT or "/tmp/"

local logf = playdate.file.open("pdsim_simtest.log", playdate.file.kFileWrite)
local function log(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
  local s = "[pdsim] " .. table.concat(parts, " ")
  print(s)
  if logf then logf:write(s .. "\n"); logf:flush() end
end
local function ms() return playdate.getElapsedTime() * 1000 end
local function shot(name)
  if playdate.simulator then
    playdate.simulator.writeToFile(gfx.getDisplayImage(), OUT .. name .. ".png")
    log("saved " .. name)
  end
end
local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end

local spec = json.decodeFile(PDSIM_SPEC or "pdsim_demo_spec.json")
assert(spec, "no spec")
local failures = 0
local function check(ok, what) if not ok then failures = failures + 1; log("FAIL " .. what) end end

---------------------------------------------------------------------------
-- 1. API tests (run in the first frame)

local function apiTests()
  log("pdsim C module:", pdsim ~= nil, "version", PDSIM_VERSION)
  local al = pdsim.autoLineup(spec.home)
  check(al and #al.lineup == 9 and al.starter, "autoLineup")
  log("autoLineup: leadoff", al.lineup[1].id, al.lineup[1].pos, "starter", al.starter, "pen", #al.bullpen)
  local alL = pdsim.autoLineup(spec.home, "L")
  log("autoLineup vs LHP: leadoff", alL.lineup[1].id)

  -- whole AI games
  local t0 = ms()
  local enc = json.encode(spec)
  local tEnc = ms() - t0
  local N = 20
  t0 = ms()
  local runs = 0
  for i = 1, N do
    spec.seed = "sim-" .. i
    local box = pdsim.simulate(spec)
    check(box and box.final and box.winner, "simulate")
    runs = runs + box.home.runs + box.away.runs
  end
  local tSim = (ms() - t0) / N
  t0 = ms()
  for i = 1, N do pdsim._simulate(enc) end
  local tCore = (ms() - t0) / N
  log(string.format("simulate: %.2f ms/game incl. json (encode %.2f ms), %.2f ms/game JSON in/out only; %.1f runs/game; spec JSON %d bytes",
    tSim, tEnc, tCore, runs / N, #enc))

  -- with pre-encoded teams (what a season loop should do for the other games of the day)
  local cached = { home = pdsim.encodeTeam(spec.home), away = pdsim.encodeTeam(spec.away), park = spec.park, weather = spec.weather }
  t0 = ms()
  for i = 1, N do
    cached.seed = "sim-" .. i
    local box = pdsim.simulate(cached)
    check(box and box.final, "simulate cached")
  end
  log(string.format("simulate with pdsim.encodeTeam teams: %.2f ms/game", (ms() - t0) / N))
  cached.seed = "sim-1"; spec.seed = "sim-1"
  local b1, b2 = pdsim.simulate(cached), pdsim.simulate(spec)
  check(b1.home.runs == b2.home.runs and b1.away.runs == b2.away.runs and b1.home.hits == b2.home.hits, "cached spec == table spec")

  -- sliced
  spec.seed = "slice-1"
  local job = pdsim.simulateStart(spec)
  local slices, done, box = 0, false, nil
  t0 = ms()
  while not done do done, box = pdsim.simulateSlice(job, 2); slices = slices + 1 end
  log(string.format("simulateSlice(2 ms): %d slices, %.1f ms total, final %d-%d", slices, ms() - t0, box.home.runs, box.away.runs))
  check(box and box.final, "simulateSlice")

  -- a game the human runs completely (home: manager + per-pitch + bat + pitch)
  local hs = copy(spec)
  hs.seed = "human-1"
  hs.home.control = { manage = true, perPitch = true, bat = true, pitch = true }
  local g = pdsim.new(hs)
  check(g ~= nil, "new")
  local counts, nEv, steps, maxStep, decided = {}, 0, 0, 0, {}
  local tries = { "steal", "bunt", "squeeze", "hitrun", "pinch_hit", "pinch_run", "ibb", "pitch_change", "infield_in", "shift", "pitch_around" }
  local ti = 1
  local evKinds = {}
  local lastInfo
  while true do
    local s0 = ms()
    local evs, pause = pdsim.step(g, 1)
    local dt = ms() - s0
    steps = steps + 1
    if dt > maxStep then maxStep = dt end
    nEv = nEv + #evs
    for _, e in ipairs(evs) do evKinds[e.k] = (evKinds[e.k] or 0) + 1 end
    if pause then
      counts[pause.reason] = (counts[pause.reason] or 0) + 1
      if pause.reason == "done" then break end
      lastInfo = pause.info
      if pause.reason == "pa" or pause.reason == "pitch" then
        -- cycle through the decision kinds; most fail validation unless the situation fits
        local k = tries[ti]
        ti = ti % #tries + 1
        local d = { kind = k }
        local info = pause.info
        if k == "steal" then d.runner = info.bases[1] and 1 or 2 end
        if k == "pinch_hit" or k == "pinch_run" then d.id = info.bench[1]; d.runner = 1 end
        if k == "pitch_change" then d.id = info.pen[1] and info.pen[1].id end
        if (pause.role == "off") == (k == "steal" or k == "bunt" or k == "squeeze" or k == "hitrun" or k == "pinch_hit" or k == "pinch_run") then
          if k ~= "ibb" or math.random() < 0.2 then
            local ok = pdsim.decide(g, d)
            if ok then decided[k] = (decided[k] or 0) + 1 end
          end
        end
      elseif pause.reason == "bat" then
        local p = pause.pitch
        pdsim.batInput(g, { swing = p.zone <= 1 or math.random() < 0.25, timing = (math.random() - 0.5) * 0.4, aim = p.pz + (math.random() - 0.5) * 0.6 })
      elseif pause.reason == "pitchsel" then
        local a = pause.info.arsenal
        pdsim.pitchInput(g, { type = a[math.random(#a)].kind, x = (math.random() * 2 - 1) * 0.9, z = (math.random() * 2 - 1) * 0.9, effort = 0.5 })
      end
    end
  end
  local box = pdsim.box(g)
  log(string.format("human game: %d steps, %d events, max %.2f ms/step; pauses pa=%d pitch=%d bat=%d pitchsel=%d; final %d-%d in %d",
    steps, nEv, maxStep, counts.pa or 0, counts.pitch or 0, counts.bat or 0, counts.pitchsel or 0, box.home.runs, box.away.runs, box.innings))
  local dl = {}
  for k, v in pairs(decided) do dl[#dl + 1] = k .. "=" .. v end
  table.sort(dl)
  log("decisions applied: " .. table.concat(dl, " "))
  local ek = {}
  for k, v in pairs(evKinds) do ek[#ek + 1] = k .. "=" .. v end
  table.sort(ek)
  log("events: " .. table.concat(ek, " "))
  check(pdsim.done(g), "done")
  check(#pdsim.log(g) == nEv, "log length")
  check(lastInfo and lastInfo.pitcher and lastInfo.batter, "info")
  log("decisions:", box.decisions.w, box.decisions.l, box.decisions.s or "-")

  -- per-frame cost of stepping a watched AI game a beat at a time
  spec.seed = "watch-1"
  local w = pdsim.new(spec)
  local tot, n, mx = 0, 0, 0
  while not pdsim.done(w) do
    local s0 = ms()
    pdsim.step(w, 1)
    local dt = ms() - s0
    tot, n = tot + dt, n + 1
    if dt > mx then mx = dt end
  end
  log(string.format("watched game, step(g, 1): %d calls, avg %.3f ms, max %.2f ms", n, tot / n, mx))
end

---------------------------------------------------------------------------
-- 2. BallCast: a finished pdsim game, then a live one

local steps, stepI, waitUntil, frame = {}, 1, 0, 0
local function step(fn, wait) steps[#steps + 1] = { fn = fn, wait = wait or 1 } end
local function waitFor(pred, maxFrames) steps[#steps + 1] = { pred = pred, wait = maxFrames or 300 } end
local BC = BallCast.scene
local gFinal, idFinal, gLive, idLive, liveSpec

step(function()
  local t0 = ms()
  apiTests()
  log(string.format("api tests took %.0f ms, %d failures", ms() - t0, failures))
  -- a finished game for the replay (pick a seed with a home run and an extra-base hit)
  for i = 1, 40 do
    local s = copy(spec)
    s.seed = "replay-" .. i
    local g = pdsim.new(s)
    pdsim.step(g)
    local hr, xbh = false, false
    for _, e in ipairs(pdsim.log(g)) do
      if e.k == "bip" then
        if e.res == "HR" then hr = true end
        if e.res == "2B" or e.res == "3B" then xbh = true end
      end
    end
    if hr and xbh then gFinal = g; idFinal = PdsimReplay.register(g, s); log("replay game " .. s.seed .. " id " .. idFinal); break end
  end
end, 2)

local function seek(pred, tau)
  return function()
    BC.mode = "watch"
    BC:debugSeek(pred, tau)
    BC.playing = false
    BC.scrubT = playdate.getCurrentTimeMilliseconds() + 100000
  end
end
local function at(name, pred, tau)
  step(seek(pred, tau), 8)
  step(function() shot(name) end)
end
local function play1x(name, pred, tau, frames)
  step(function()
    BC.mode = "watch"
    BC:debugSeek(pred, tau)
    BC.playing = true
    BC.scrubT = 0
  end, frames)
  step(function() shot(name) end)
end

step(function() App.push(BC, { gameId = idFinal, skipIntro = true }) end)
waitFor(function() return BC.mode == "watch" end, 900)
-- the timeline keeps building in the background while it plays
step(function() BC.playing = false end)
waitFor(function() return not BC:timelinePending() end, 1800)
step(function()
  log("BallCast watching " .. idFinal .. ": " .. #BC.tl.beats .. " beats, status " .. tostring(BC.status) .. ", " .. tostring(BC.meta.away and BC.meta.away.abbr) .. " at " .. tostring(BC.meta.home and BC.meta.home.abbr))
  local bad = 0
  for _, b in ipairs(BC.tl.beats) do if not b.plan then bad = bad + 1 end end
  check(bad == 0, "every beat planned")
  local fin = BC.tl.beats[#BC.tl.beats]
  local box = pdsim.box(gFinal)
  check(fin.kind == "end" and fin.post.home == box.home.runs and fin.post.away == box.away.runs, "BallCast final score == box")
  log("BallCast final", fin.post.away, fin.post.home, "box", box.away.runs, box.home.runs)
end, 2)
local function firstP(b) return b.kind == "p" and b.n > 12 and b.e.r == "X" end
local function xbhPitch(b)
  local nb = BC.tl.beats[b.n + 1]
  return b.kind == "p" and b.e.r == "X" and nb and nb.kind == "bip" and (nb.e.res == "2B" or nb.e.res == "3B" or nb.e.res == "HR")
end
local function hr(b) return b.kind == "bip" and b.e.res == "HR" end
at("pdsim_bc_pitch", firstP, function(b) return b.plan.pitch.tPlate - 0.25 end)
at("pdsim_bc_bip", function(b) return b.kind == "bip" and b.e.path and b.e.res ~= "HR" and b.n > 20 end, 1.0)
at("pdsim_bc_hr", hr, function(b) return (b.plan.wallT or 2) - 0.2 end)
-- the swing cam (TV PiP) only shows while playing at 1x: run into an extra-base swing
play1x("pdsim_bc_swingcam", xbhPitch, function(b) return b.plan.pitch.tPlate - 0.9 end, 28)
play1x("pdsim_bc_playing", function(b) return b.kind == "pa" and b.n > 60 end, 0, 45)
step(function() App.pop() end, 10)

-- live: a game in progress; step it while BallCast polls
step(function()
  liveSpec = copy(spec)
  liveSpec.seed = "live-1"
  gLive = pdsim.new(liveSpec)
  pdsim.step(gLive, 120)
  idLive = PdsimReplay.register(gLive, liveSpec)
  App.push(BC, { gameId = idLive, skipIntro = true })
end)
waitFor(function() return BC.mode == "watch" end, 900)
local liveN0
step(function()
  liveN0 = #BC.tl.log
  log("live: BallCast status " .. tostring(BC.status) .. ", " .. liveN0 .. " events; stepping 200 more")
  check(BC.status == "live", "live status")
  pdsim.step(gLive, 200)
end, 30 * 6)   -- one poll (5 s)
step(function()
  log("live: after a poll BallCast has " .. #BC.tl.log + BC:pendingCount() .. " events (engine " .. pdsim.eventCount(gLive) .. ")")
  check(#BC.tl.log + BC:pendingCount() == pdsim.eventCount(gLive), "live poll picked up the new events")
  shot("pdsim_bc_live")
  App.pop()
end, 10)
step(function()
  log(string.format("DONE: %d failures", failures))
  if logf then logf:close() end
  if playdate.simulator and not PDSIM_STAY then playdate.simulator.exit() end
end)

function playdate.update()
  frame = frame + 1
  gfx.clear(gfx.kColorWhite)
  if #App.stack > 0 then
    local ok, err = xpcall(App.draw, debug.traceback)
    if not ok then log("ERROR " .. tostring(err)); if playdate.simulator then playdate.simulator.exit() end return end
  end
  local ok2, err2 = xpcall(playdate.timer.updateTimers, debug.traceback)
  if not ok2 then log("TIMER ERROR " .. tostring(err2)); if playdate.simulator then playdate.simulator.exit() end return end
  playdate.frameTimer.updateTimers()
  local s = steps[stepI]
  if not s then return end
  if s.pred then
    if s.pred() or frame >= waitUntil + s.wait then
      if frame >= waitUntil + s.wait then log("wait timed out at step " .. stepI) end
      stepI = stepI + 1
      waitUntil = frame
    end
    return
  end
  if frame >= waitUntil then
    local ok, e = xpcall(s.fn, debug.traceback)
    if not ok then failures = failures + 1; log("step " .. stepI .. " failed: " .. tostring(e)) end
    stepI = stepI + 1
    waitUntil = frame + s.wait
  end
end
