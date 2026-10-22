-- Dev harness for BallCast + Cards (NOT imported by the game). Used as main.lua in a
-- scratch build: it walks a script of scenes, saves screenshots to docs/screens/ and
-- prints frame timings, then quits the Simulator.
--
--   mkdir -p $SCRATCH/src && rsync -a playdate/source/ $SCRATCH/src/ &&
--   echo 'import "ballcast/devharness"' > $SCRATCH/src/main.lua &&
--   pdc $SCRATCH/src $SCRATCH/dev.pdx && open -a "Playdate Simulator" $SCRATCH/dev.pdx

import "CoreLibs/object"
import "CoreLibs/graphics"
import "CoreLibs/timer"
import "CoreLibs/frameTimer"
import "CoreLibs/crank"
import "app/scene"
import "ballcast/ballcast"
import "cards/cards"
-- the audio agent's module, if it's in the build (exercises the Audio integration path)
if playdate.file.exists("audio/audio.pdz") then pcall(playdate.file.run, "audio/audio") end

local gfx <const> = playdate.graphics
playdate.display.setRefreshRate(30)

local OUT = HARNESS_OUT or "/Users/nick/pd_baseball/docs/screens/"
-- mirror print() into Data/<bundle>/harness.log (the Simulator console isn't on stdout)
local logf = playdate.file.open("harness.log", playdate.file.kFileWrite)
local rawPrint = print
print = function(...)
  rawPrint(...)
  if logf then
    local parts = {}
    for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
    logf:write(table.concat(parts, " ") .. "\n")
    logf:flush()
  end
end
local frame = 0
print("[harness] start, bc3d=" .. tostring(bc3d ~= nil))
local steps = {}
local stepI = 1
local waitUntil = 0
local timings = {}
local timingTag = nil

local function shot(name)
  if playdate.simulator then
    playdate.simulator.writeToFile(gfx.getDisplayImage(), OUT .. (HARNESS_PREFIX or "") .. name .. ".png")
    print("[harness] saved " .. name)
  end
end

-- (cambake, camaudit) a baked camera pick as Lua source
function bakeSer(v)
  if type(v) == "table" then
    local parts = {}
    for i = 1, #v do parts[i] = bakeSer(v[i]) end
    return "{ " .. table.concat(parts, ", ") .. " }"
  elseif type(v) == "number" then
    return v == math.floor(v) and string.format("%d", v) or string.format("%.17g", v)
  end
  return tostring(v)
end

local function step(fn, wait) steps[#steps + 1] = { fn = fn, wait = wait or 1 } end
local function waitFor(pred, maxFrames) steps[#steps + 1] = { pred = pred, wait = maxFrames or 300 } end

local BC = BallCast.scene
if HARNESS_STATIC then BallCast.Render.forceStatic = true end
local GAME = HARNESS_GAME or "g1"
local function seek(pred, tau)
  return function()
    BC.mode = "watch"
    BC:debugSeek(pred, tau)
    BC.playing = false
    BC.scrubT = playdate.getCurrentTimeMilliseconds() + 100000
  end
end
local function firstHR(b) return b.kind == "bip" and b.e.res == "HR" end

-- Device perf run: play 1x from mid-game for HARNESS_PERF seconds, log frame costs per shot
if HARNESS_PERF then
  step(function() App.push(BC, { gameId = "g1", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  step(function()
    BC:debugSeek(function(b) return b.kind == "bip" and b.e.res == "HR" end, -6)
    BC.playing = true
    BC.scrubT = 0
    timingTag = "perf"
  end, 30 * HARNESS_PERF)
  step(function() timingTag = nil end, 2)
end

-- BallCast animatic puppets + Enhanced League powers (HARNESS_ONLY = "anim", game "ultra")
local only = HARNESS_ONLY
if only == "anim" then
  local U = BallCast.Play.ultra
  local function pw(power) return function(b) return U(b, power) ~= nil end end
  step(function() App.push(BC, { gameId = "ultra", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  local function at(name, pred, tau)
    step(seek(pred, tau), 8)
    step(function() shot(name) end)
  end
  local function pitchN(b) return b.kind == "p" and b.n > 20 and not b.ultra and b.pre.b + b.pre.s >= 2 end
  -- the windup, frame by frame (untweened held keys: set, kick, stride, cock, release, follow)
  for k = 0, 7 do
    at(string.format("anim_pitch_%d", k), pitchN, function(b) return b.plan.pitch.tRel - 0.75 + k * 0.1 end)
  end
  at("anim_swing_contact", function(b) return b.kind == "p" and b.e.r == "F" and b.n > 20 and not b.ultra end, function(b) return b.plan.pitch.tPlate + 0.02 end)
  at("anim_catcher_receive", function(b) return b.kind == "p" and b.e.r == "B" and b.n > 20 end, function(b) return b.plan.pitch.tPlate + 0.02 end)
  at("anim_strike3_punchout", function(b) return b.kind == "p" and b.k and b.e.r == "C" end, function(b) return b.plan.umpCall + 0.25 end)
  at("anim_whiff_k", function(b) return b.kind == "p" and b.k and b.e.r == "S" and not b.ultra end, function(b) return b.plan.pitch.tPlate + 0.4 end)
  at("ultra_fireball", pw("FIREBALL"), function(b) local p = b.plan.pitch; return p.tRel + (p.tPlate - p.tRel) * 0.4 end)
  at("ultra_fireball_charge", pw("FIREBALL"), 0.5)
  at("ultra_stopper", pw("STOPPER"), function(b) return b.plan.stall[1] + 0.3 end)
  at("ultra_warp_blink", pw("WARP_PITCH"), function(b) return b.plan.warp - 0.02 end)
  at("ultra_warp_pop", pw("WARP_PITCH"), function(b) return b.plan.warp + 0.1 end)
  at("ultra_cloud", pw("CLOUD_BALL"), function(b) return b.plan.cloud[1] + 0.05 end)
  at("ultra_cloud2", pw("CLOUD_BALL"), function(b) return b.plan.cloud[1] + 0.25 end)
  at("ultra_hyper_flash", function(b) return b.kind == "p" and U(b, "HYPER_HIT") end, function(b) return b.plan.pitch.tPlate + 0.03 end)
  at("ultra_hyper_burst", function(b) return b.kind == "p" and U(b, "HYPER_HIT") end, function(b) return b.plan.pitch.tPlate + 0.2 end)
  at("ultra_hyper_bip", function(b) return b.kind == "bip" and U(b, "HYPER_HIT") end, 0.6)
  at("anim_homer_batter", function(b) return b.kind == "bip" and U(b, "HYPER_HIT") end, 0.35)
  at("ultra_leap_climb", pw("LEAP_CATCH"), function(b) return b.plan.leap.tc - 0.05 end)
  at("ultra_leap_land", pw("LEAP_CATCH"), function(b) return b.plan.leap.land + 0.05 end)
  at("ultra_laser", pw("LASER_ARM"), function(b)
    for _, s in ipairs(b.plan.ball) do if s.throw then return s.t0 + (s.t1 - s.t0) * 0.6 end end
    return 1
  end)
  at("ultra_warp_run", pw("WARP_RUN"), function(b) local r = b.plan.runners[1]; return r and r.t0 + 1.2 or 1 end)
  at("anim_hr_trot", function(b) return b.kind == "bip" and b.e.res == "HR" end, function(b) return b.dur - 3.5 end)
  at("anim_score_celebrate", function(b) return b.kind == "bip" and b.plan.scoreT and b.e.res == "1B" end, function(b) return b.plan.scoreT + 0.15 end)
  at("anim_doubleplay_slide", function(b) return b.kind == "bip" and b.e.res == "DP" end, function(b) return b.plan.slo and (b.plan.slo[1] + 0.45) or 1.5 end)
  at("anim_brawl", function(b) return b.kind == "inc" and b.e.kind == "BRAWL" end, 4.6)
  at("anim_brawl_rush", function(b) return b.kind == "inc" and b.e.kind == "BRAWL" end, 1.5)
  at("anim_streaker", function(b) return b.kind == "inc" and b.e.kind == "FAN_ON_FIELD" end, 1.3)
  at("anim_ejection", function(b) return b.kind == "inc" and b.e.kind == "EJECTION" end, 1.4)
  at("anim_hbp", function(b) return b.kind == "p" and b.e.r == "H" end, function(b) return b.plan.hbp + 0.3 end)
  at("anim_mascot_half", function(b) return b.kind == "half" and b.e.inn == 5 end, 1.2)
  at("anim_final_mob", function(b) return b.kind == "end" end, 1.2)
  at("anim_bleacher_cheer", function(b) return b.kind == "bip" and b.e.res == "HR" end, function(b) return b.plan.wallT + 2.0 end)
  at("anim_bleacher_cheer2", function(b) return b.kind == "bip" and b.e.res == "HR" end, function(b) return b.plan.wallT + 2.2 end)
  at("anim_bleacher_streaker", function(b) return b.kind == "inc" and b.e.kind == "FAN_ON_FIELD" end, 3.4)
  step(function()
    for _, p in ipairs({ { 62, 22 }, { 0, 58 }, { 0, 0 } }) do print("[harness] project", p[1], p[2], bc3d.project(p[1], p[2], 0)) end
  end)
  -- 1x playback timing (Simulator only: device perf is the lead's)
  step(function()
    BC:debugSeek(function(b) return b.kind == "p" and b.n > 50 end, 0)
    BC.playing = true
    BC.scrubT = 0
    timingTag = "pitch"
  end, 120)
  step(function()
    BC:debugSeek(pw("FIREBALL"), 0)
    timingTag = "fireball"
  end, 75)
  step(function()
    BC:debugSeek(function(b) return b.kind == "bip" and b.e.res == "HR" end, 0)
    timingTag = "hr"
  end, 120)
  step(function() timingTag = nil; App.pop() end, 5)
elseif only == "tv" then
  -- DBN broadcast package (ballcast/tv): every segment recorded frame by frame (GIF material,
  -- TV.debugClock makes the segment clock step exactly 1/30 s a frame), plus single shots of
  -- the overlays at fixed taus. Game "ultra" (powers, incidents, homers).
  local TV = BallCast.TV
  local U = BallCast.Play.ultra
  step(function() App.push(BC, { gameId = HARNESS_GAME or "ultra", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  step(function() BC.playing = false; BC.scrubT = playdate.getCurrentTimeMilliseconds() + 1e6 end, 30)
  local function at(name, pred, tau)
    step(seek(pred, tau), 6)
    step(function() shot(name) end)
  end
  local function idx(pred)
    for i, b in ipairs(BC.tl.beats) do if pred(b) then return i end end
    return nil
  end
  local segStats = {}
  -- record a segment: every `every`-th frame saved as <prefix>_NNN, until it ends (or maxF)
  local function rec(prefix, what, pred, every, maxF)
    local f = 0
    local done = false
    step(function()
      local bi = type(pred) == "number" and pred or (pred and idx(pred)) or 1
      BC:debugSeek(function(b) return b.n == (bi or 1) end, 0)
      BC.playing = false
      TV.debugClock = 1 / 30
      local ok = TV.debugStart(BC, what, bi)
      print("[harness] tv start " .. prefix .. " beat " .. tostring(bi) .. " ok=" .. tostring(ok))
      segStats[prefix] = { n = 0, sum = 0, max = 0 }
    end, 1)
    for k = 1, maxF do
      step(function()
        if done then return end
        f = f + 1
        local kind = TV.debugState()
        local s = segStats[prefix]
        if TV.lastMs then s.n = s.n + 1; s.sum = s.sum + TV.lastMs; s.max = math.max(s.max, TV.lastMs) end
        if f % every == 0 then shot(string.format("%s_%03d", prefix, f)) end
        if not kind and not TV.active() then done = true end
      end, 1)
    end
    step(function()
      TV.interrupt(); TV.debugClock = nil
      local s = segStats[prefix]
      print(string.format("[harness] tv %s: %d frames, TV frame avg %.1f ms max %.1f ms", prefix, f, s.n > 0 and s.sum / s.n or 0, s.max))
    end, 2)
  end
  local function hr(b) return b.kind == "bip" and b.e.res == "HR" end
  rec("tv_open", "open", nil, 2, 520)
  rec("tv_replay_hr", "replay", hr, 2, 520)
  rec("tv_replay_power", "replay", function(b) return b.kind == "p" and b.plan.power and b.ultra end, 2, 360)
  rec("tv_replay_k", "replayK", function(b) return b.kind == "p" and b.k and b.n > 30 end, 2, 300)
  rec("tv_replay_catch", "replay", function(b) return b.kind == "bip" and b.plan.leap end, 2, 360)
  rec("tv_special", "special", function(b) return b.kind == "inc" and b.e.kind == "FAN_ON_FIELD" end, 2, 160)
  rec("tv_break_ad", "break", function(b) return b.kind == "half" and b.e.top and b.e.inn == 3 end, 2, 400)
  rec("tv_break_dyk", "break", function(b) return b.kind == "half" and b.e.top and b.e.inn == 4 end, 2, 300)
  rec("tv_stretch", "break", function(b) return b.kind == "half" and not b.e.top and b.e.inn == 7 end, 2, 160)
  rec("tv_dueup", "break", function(b) return b.kind == "half" and not b.e.top and b.e.inn == 1 end, 2, 120)
  for k = 1, 4 do rec("tv_ad" .. k, "ad", k, 6, 110) end
  step(function() end, 1)
  rec("tv_post", "post", function(b) return b.kind == "end" end, 2, 420)
  step(function() print(string.format("[harness] tv art caches ~%d KB (upper bound), Lua heap %d KB", BallCast.TVArt.memBytes() // 1024, collectgarbage("count") // 1)) end)
  -- reduce motion: the same replay and a break with flashes/spins/shakes off, wipes as dissolves
  step(function() if Game and Game.settings then Game.settings.reduceMotion = true end end)
  rec("tv_reduce_hr", "replay", hr, 6, 520)
  rec("tv_reduce_break", "break", function(b) return b.kind == "half" and b.e.top and b.e.inn == 3 end, 6, 400)
  step(function() if Game and Game.settings then Game.settings.reduceMotion = false end end)
  -- overlays over live play, as sequences (the clock stepped 1/15 s a frame: GIF material)
  local function seekRec(prefix, pred, t0, t1)
    local i = 0
    local bi
    step(function() bi = idx(pred); print("[harness] tv live " .. prefix .. " beat " .. tostring(bi)) end, 1)
    for k = 0, 80 do
      step(function()
        if not bi then return end
        local b = BC.tl.beats[bi]
        local a, z = t0(b), t1(b)
        local tau = a + k / 15
        if tau > z then return end
        BC.mode = "watch"
        BC.t = b.start + tau
        BC.lastBeat = nil
        BC.playing = false
        BC.scrubT = playdate.getCurrentTimeMilliseconds() + 100000
      end, 1)
      step(function()
        if not bi then return end
        local b = BC.tl.beats[bi]
        if t0(b) + k / 15 <= t1(b) then i = i + 1; shot(string.format("%s_%03d", prefix, i)) end
      end, 1)
    end
  end
  seekRec("tv_live_hr", hr, function(b) return b.plan.wallT - 0.6 end, function(b) return b.plan.wallT + 2.6 end)
  seekRec("tv_live_pa", function(b) return b.kind == "pa" and b.n > 30 end, function() return 0 end, function(b) return b.dur end)
  seekRec("tv_live_k", function(b) return b.kind == "p" and b.k and b.e.r == "C" and b.n > 20 end,
    function(b) return b.plan.pitch.tRel - 0.3 end, function(b) return b.plan.kT + 1.9 end)
  seekRec("tv_live_power", function(b) return b.kind == "p" and b.plan.power and b.ultra end, function() return 0 end,
    function(b) return b.plan.pitch.tPlate + 0.6 end)
  -- overlays over live play (pure in tau: single shots)
  local function pitchK(b) return b.kind == "p" and b.n > 30 and b.plan.cams[1].name == "pitch" and b.pre.b + b.pre.s >= 3 end
  at("tv_ov_kzone_flight", pitchK, function(b) return b.plan.pitch.tPlate - 0.12 end)
  at("tv_ov_kzone_track", pitchK, function(b) return b.plan.pitch.tPlate + 0.5 end)
  at("tv_ov_kstamp", function(b) return b.kind == "p" and b.k and b.e.r == "C" end, function(b) return b.plan.kT + 0.5 end)
  at("tv_ov_kstamp_swing", function(b) return b.kind == "p" and b.k and b.e.r == "S" end, function(b) return b.plan.kT + 0.06 end)
  at("tv_ov_power", function(b) return b.kind == "p" and b.plan.power and b.ultra end, 0.5)
  at("tv_ov_power_hyper", function(b) return b.kind == "p" and b.plan.hyperPower and b.ultra end, 0.4)
  for _, a in ipairs({ 0.05, 0.12, 0.3, 0.8, 1.9 }) do
    at("tv_ov_lowerthird_" .. a, function(b) return b.kind == "pa" and b.n > 30 end, a)
  end
  for _, a in ipairs({ 0.03, 0.1, 0.2, 0.35, 0.6, 1.2, 1.85 }) do
    at("tv_ov_hrbanner_" .. a, hr, function(b) return b.plan.wallT + 0.3 + a end)
  end
  for _, a in ipairs({ 0.1, 0.5 }) do
    at("tv_ov_tier2_" .. a, function(b) return b.big == "DOUBLE PLAY!" end, function(b)
      local t0 = b.plan.bannerT or (b.plan.slo and b.plan.slo[2]) or (b.dur * 0.45); return t0 + a end)
  end
  at("tv_ov_halfpill", function(b) return b.kind == "half" and b.e.inn == 5 end, 0.6)
  for _, a in ipairs({ 0.1, 0.3, 0.6 }) do at("tv_ov_final_" .. a, function(b) return b.kind == "end" end, a) end
  -- 1x playback timing with the overlays on (Simulator only)
  step(function()
    BC:debugSeek(function(b) return b.kind == "p" and b.n > 50 end, 0)
    BC.playing = true
    BC.scrubT = 0
    timingTag = "pitch"
  end, 120)
  step(function() timingTag = nil; App.pop() end, 5)
elseif only == "tvplay" then
  -- DBN segments fired by real playback (no debug starts): the open from the intro menu, then
  -- the clock dropped just before a homer ends, a half-inning, an incident and the final out.
  local TV = BallCast.TV
  step(function() App.push(BC, { gameId = HARNESS_GAME or "ultra" }) end)
  waitFor(function() return BC.mode == "intro" end, 900)
  step(function() end, 20)
  step(function() BC.menuSel = 1; BC:AButtonDown() end, 1)
  local n = 0
  local function run(prefix, frames, every)
    for k = 1, frames do
      step(function()
        if k % every == 0 then shot(string.format("%s_%03d", prefix, k)) end
        if k % 30 == 0 then print("[harness] tvplay " .. prefix .. " t=" .. string.format("%.1f", BC.t) .. " seg=" .. tostring(TV.debugState()) .. " playing=" .. tostring(BC.playing)) end
      end, 1)
    end
  end
  local function drop(pred, before)
    step(function()
      for i, b in ipairs(BC.tl.beats) do
        if pred(b, i) then
          local tb = (type(before) == "function") and before(b) or before
          BC.t = b.start + tb
          BC.lastBeat = nil
          BC.playing = true
          BC.speed = 1
          BC.scrubT = 0
          print("[harness] tvplay drop at beat " .. i .. " " .. b.kind)
          return
        end
      end
    end, 1)
  end
  run("tvplay_open", 540, 3)
  drop(function(b) return b.kind == "bip" and b.e.res == "HR" end, function(b) return b.dur - 1.0 end)
  run("tvplay_hr", 480, 3)
  drop(function(b) return b.kind == "half" and b.e.top and b.e.inn == 3 end, -0.8)
  run("tvplay_break", 420, 3)
  drop(function(b) return b.kind == "inc" end, -0.8)
  run("tvplay_inc", 200, 3)
  drop(function(b) return b.kind == "end" end, function(b) return b.dur - 1.0 end)
  run("tvplay_post", 420, 3)
  step(function() App.pop() end, 5)
elseif only == "nospoil" then
  -- No spoilers: frames just before and just after each play's moment (the catch, the K, the
  -- throw beating him to first, the ball over the wall, the run home, the last out of a DP, a
  -- walk-off made from a bottom-inning run), at 1x with the clock held there (nothing paused).
  -- Each frame's name carries its offset from the moment. Then A (the next camera shot): where
  -- it lands, mid-play and at a beat's end, and that a live broadcast won't skip near its head.
  local Play, TL = BallCast.Play, BallCast.Timeline
  step(function() App.push(BC, { gameId = HARNESS_GAME or "dev", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" and not BC:timelinePending() end, 1800)
  step(function() BC.playing = false end, 10)
  local function batterOut(b) for _, m in ipairs(b.mvs) do if m.from == 0 then return m.to == -1 end end return false end
  -- the moments, from the plan's runners and ball (so the same mode runs on an older build: the
  -- before/after pairs)
  local function batterR(b) for _, r in ipairs(b.plan.runners) do if r.from == 0 then return r end end end
  local function batterT(b) local r = batterR(b); return r and (r.to == -1 and (r.outAt or r.t1) or r.t1) end
  local function lastOutT(b) local t = 0; for _, r in ipairs(b.plan.runners) do if r.to == -1 then t = math.max(t, r.outAt or r.t1) end end return t end
  local function firstRunT(b) local t; for _, r in ipairs(b.plan.runners) do if r.to == 4 then t = math.min(t or 99, r.t1) end end return t end
  local function lastRunT(b) local t; for _, r in ipairs(b.plan.runners) do if r.to == 4 then t = math.max(t or 0, r.t1) end end return t end
  local cases = {
    { "flyout", function(b) return b.kind == "bip" and b.e.res == "OUT" and b.plan.flyCatch and not b.big end, function(b) return b.plan.catchT end },
    { "strikeout", function(b) return b.kind == "p" and b.k and b.e.r == "S" end, function(b) return b.plan.kT end },
    { "groundout", function(b) return b.kind == "bip" and b.e.res == "OUT" and b.e.out == "GO" and batterOut(b) end, batterT },
    { "homer", function(b) return b.kind == "bip" and b.e.res == "HR" and not b.walkoff end, function(b) return b.plan.wallT end },
    { "runscores", function(b) return b.kind == "bip" and b.e.res ~= "HR" and (b.runs or 0) > 0 and not b.walkoff end, firstRunT },
    { "double", function(b) return b.kind == "bip" and b.e.res == "2B" and not b.walkoff end, batterT },
    { "dp", function(b) return b.kind == "bip" and b.e.res == "DP" end, lastOutT },
    { "walkoff", function(b) return b.walkoff and b.kind == "bip" and b.e.res ~= "HR" end, lastRunT },
    { "walkoffhr", function(b) return b.walkoff and b.kind == "bip" and b.e.res == "HR" end, function(b) return b.plan.wallT end },
  }
  local OFFS = { -0.6, -0.15, 0.2, 0.6, 1.2 }
  -- (no walk-off in the fixtures: make two out of a bottom-inning run and a bottom-inning homer,
  -- re-planned the way TL.layout does once a game is final)
  step(function()
    local tl = BC.tl
    local made = {}
    for _, b in ipairs(tl.beats) do
      if b.kind == "bip" and not b.pre.top and (b.runs or 0) > 0 then
        local hr = b.e.res == "HR"
        if not made[hr] then made[hr] = true; b.walkoff = true; Play.plan(b, tl) end
      end
    end
    TL.layout(tl)
  end, 2)
  for _, c in ipairs(cases) do
    local b, m
    step(function()
      b, m = nil, nil
      for _, x in ipairs(BC.tl.beats) do if c[2](x) then b = x break end end
      if b then m = c[3](b) end
      print(string.format("[nospoil] %s beat %s moment %s callT %s revealT %s settleT %s bannerT %s big %s cams %s",
        c[1], tostring(b and b.n), m and string.format("%.2f", m) or "-", b and b.plan.callT and string.format("%.2f", b.plan.callT) or "-",
        b and Play.revealT and string.format("%.2f", Play.revealT(b)) or "-", b and Play.settleT and string.format("%.2f", Play.settleT(b)) or "-",
        b and Play.bannerT and string.format("%.2f", Play.bannerT(b)) or "-", tostring(b and b.big), b and (function()
          local s = {}
          for _, cc in ipairs(b.plan.cams) do s[#s + 1] = cc.name .. "@" .. string.format("%.1f", cc.t) end
          return table.concat(s, " ")
        end)() or "-"))
    end, 1)
    for _, off in ipairs(OFFS) do
      local function hold()
        if not b or not m then return end
        BC.mode = "watch"
        BC.t = b.start + m + off
        BC.lastBeat = nil
        BC.playing = true
        BC.speed = 1
        BC.scrubT = 0
        BC.hintUntil = nil
        BC.lastMs = playdate.getCurrentTimeMilliseconds()
      end
      step(hold, 1)
      step(hold, 1)
      step(function() if b and m then shot(string.format("nospoil_%s_%s%.2f", c[1], off < 0 and "m" or "p", math.abs(off))) end end, 1)
    end
  end
  -- A: the next camera shot
  local function report(label)
    local bi = BC:curBeatIndex()
    local bb = BC.tl.beats[bi]
    print(string.format("[nospoil] %s: t=%.2f beat %d(%s) tau=%.2f cam=%s playing=%s", label, BC.t, bi, bb.kind, BC.t - bb.start,
      Play.camAt(bb.plan, BC.t - bb.start).name, tostring(BC.playing)))
  end
  local hr
  step(function()
    for _, x in ipairs(BC.tl.beats) do if x.kind == "bip" and x.e.res == "HR" and not x.walkoff then hr = x break end end
    BC.t = hr.start + 0.5; BC.lastBeat = nil; BC.playing = true; BC.scrubT = 0; BC.lastMs = playdate.getCurrentTimeMilliseconds()
    report("A: homer in flight, before")
  end, 2)
  step(function() BC:AButtonDown(); BC:AButtonUp(); report("A: after one press") end, 3)
  step(function() shot("nospoil_A_1") end, 1)
  step(function() BC:AButtonDown(); BC:AButtonUp(); report("A: after two") end, 3)
  step(function() shot("nospoil_A_2") end, 1)
  step(function() BC:AButtonDown(); BC:AButtonUp(); report("A: after three (next beat)") end, 3)
  step(function() shot("nospoil_A_3") end, 1)
  -- paused: A moves on and plays
  step(function() BC:leftButtonDown(); report("left at 1x (pause)") end, 2)
  step(function() shot("nospoil_paused") end, 1)
  step(function() BC:AButtonDown(); BC:AButtonUp(); report("A while paused") end, 3)
  step(function() BC.hintUntil = playdate.getCurrentTimeMilliseconds() + 3000 end, 3)
  step(function() shot("nospoil_hint") end, 1)
  -- a live broadcast: no jump to within LIVE_EDGE s of the head
  step(function()
    local tl = BC.tl
    BC.live = true
    BC.t = tl.total - 12; BC.lastBeat = nil
    local tgt = BC:nextShotT()
    print(string.format("[nospoil] live, 12 s behind the head: next shot %s (head %.2f)", tgt and string.format("%.2f", tgt) or "refused", tl.total))
    BC.t = tl.total - 5
    tgt = BC:nextShotT()
    print(string.format("[nospoil] live, 5 s behind the head: next shot %s", tgt and string.format("%.2f", tgt) or "refused"))
    BC.live = false
  end, 2)
  step(function() App.pop() end, 5)
elseif only == "tvcatch" then
  -- Sliding / diving catches frame by frame: the first "slide" fly catch (planFlyCatch) and the
  -- first old-style "dive" (fcatch / ftrack), ~12 frames through the move, at the play's own
  -- camera (the low "dive" cut) and at the gameplay camera (that cut taken out). tvcatch_<kind>_<cam>_<i>
  local Play = BallCast.Play
  step(function() App.push(BC, { gameId = HARNESS_GAME or "ultra", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" and not BC:timelinePending() end, 1800)
  step(function() BC.playing = false end, 10)
  local function diveOf(b)
    if b.kind ~= "bip" then return nil end
    for _, l in pairs(b.plan.fposes or {}) do
      for _, e in ipairs(l) do
        if e.catch == "dive" then return e.t0 end
        if e.track == "dive" then return e.t0 end
      end
    end
  end
  local OFP = { LF = true, CF = true, RF = true }
  -- (the fixtures have hardly any: force them, Play.forceCatchStyle, on deep outfield fly outs)
  step(function()
    local tl, k, dive = BC.tl, 0, false
    for _, b in ipairs(tl.beats) do
      local c = b.kind == "bip" and b.plan.flyCatch
      if c and OFP[c.pos] and math.sqrt(c.fx * c.fx + c.fy * c.fy) > 200 then
        k = k + 1
        if k <= 2 then
          Play.forceCatchStyle = k == 1 and "slide" or "layout"
          Play.plan(b, tl)
          Play.forceCatchStyle = nil
        elseif not dive and not b.ultra then
          -- the old dive (fcatch "dive"): LEAP_CATCH on a ball that never reaches the wall
          b.ultra = { { power = "LEAP_CATCH" } }
          Play.plan(b, tl)
          if diveOf(b) then dive = true else b.ultra = nil; Play.plan(b, tl) end
        end
      end
    end
    BallCast.Timeline.layout(tl)
  end, 2)
  local CASES = {
    { "slide", function(b) local c = b.kind == "bip" and b.plan.flyCatch; return c and c.style == "slide" and c.t0 or nil end },
    { "layout", function(b) local c = b.kind == "bip" and b.plan.flyCatch; return c and c.style == "layout" and c.t0 or nil end },
    { "dive", diveOf },
  }
  local N = tonumber(HARNESS_FRAMES or 16)
  for _, c in ipairs(CASES) do
    local b, t0
    step(function()
      b, t0 = nil, nil
      local n = 0
      for _, x in ipairs(BC.tl.beats) do
        local t = c[2](x)
        if t then n = n + 1; if not b then b, t0 = x, t end end
      end
      print(string.format("[tvcatch] %s: %d beats, first %s t0 %s", c[1], n, tostring(b and b.n), t0 and string.format("%.2f", t0) or "-"))
    end, 1)
    for _, camk in ipairs({ "play", "game" }) do
      local saved
      step(function()
        if not b then return end
        saved = b.plan.cams
        if camk == "game" then
          local l = {}
          for _, cc in ipairs(saved) do if not (cc.opt and (cc.opt.play == "dive" or cc.opt.play == "track")) then l[#l + 1] = cc end end
          b.plan.cams = l
        end
      end, 1)
      for i = 0, N - 1 do
        local tt
        step(function()
          if not b then return end
          tt = t0 - 0.2 + i * (HARNESS_SPAN or 1.6) / N
          BC.mode = "watch"
          BC.t = b.start + tt
          BC.lastBeat = nil
          BC.playing = false
          BC.scrubT = playdate.getCurrentTimeMilliseconds() + 100000
        end, 4)
        step(function() if b then shot(string.format("tvcatch_%s_%s_%02d", c[1], camk, i)) end end, 1)
      end
      step(function() if b and saved then b.plan.cams = saved end end, 1)
    end
  end
  step(function() App.pop() end, 5)
elseif only == "catchaudit" then
  -- Catch audit (census + glove-ball contact). Every fixture game (dev, ultra, bunts, the shell's
  -- g1) plus HARNESS_PDSIM pdsim games (spec: catchspec.json in the build) planned by Play, then:
  --   [census] every code path that puts a fielder on the ground diving/flopping, per game
  --   [contact] per catch style: where the DRAWN glove is (the pose's glove cell — fieldx/fieldin
  --     glove anchors, else the side view's glove wrist — through the key's squash/rotation/
  --     offset, lifted, at his feet and facing) vs. the ball at the catch; whether the ball came
  --     down below the glove / to the ground in the half second before the catch; the ball vs.
  --     the glove while it's held. Feet, ft; 1 ft = 6.45 px on a 40 px (1x) figure.
  local Play, TL, Anim, Pup = BallCast.Play, BallCast.Timeline, BallCast.Anim, BallCast.Puppets
  local LMK = json.decodeFile("images/puppets/landmarks.json") or { cells = {} }
  local cos, sin, sqrt, max, min, abs, floor = math.cos, math.sin, math.sqrt, math.max, math.min, math.abs, math.floor
  local function wrist(set, view, f)
    local s = LMK.cells[set .. "#" .. view]
    if not s or #s < f * 24 then return nil end
    local o = (f - 1) * 24
    return (s:byte(o + 19) - 40) * 0.5, (s:byte(o + 20) - 40) * 0.5
  end
  local VSET = { fielder = "fielder", runner_seq = "runner_seq", runner = "runner", fieldx = "fieldx", fieldin = "fieldin" }
  -- the glove in the figure's frame from cell + key transform → right, fwd, up (ft above his feet)
  local function cellGlove(tn, f)
    if tn == "fieldx" or tn == "fieldin" then
      local cx, cy = Pup.gloveCell(tn, f)
      Anim.load()
      local g = Anim.reach and Anim.reach[tn] and Anim.reach[tn].glove[f]
      if cx then return cx, cy, g and g[1] or 0 end
    end
    local set = VSET[tn]
    if not set then return nil end
    local x, y = wrist(set, 6, f)
    if not x then return nil end
    local x0 = wrist(set, 0, f)
    return x + 1, y, x0 and -(x0 - 14) * 0.155 or 0
  end
  local function keyGlove(tn, f, sx, sy, rot, dx, dy, piv)
    local cx, cy, lat = cellGlove(tn, f)
    if not cx then return nil end
    local py = -(piv or 0)
    local vx, vy = (cx - 14) * (sx or 1), (cy - 42 - py) * (sy or 1)
    local r = math.rad(rot or 0)
    local c, s = cos(r), sin(r)
    local wx, wy = vx * c - vy * s, vx * s + vy * c
    wx, wy = wx + (dx or 0), wy + py + (dy or 0)
    return lat, wx * 0.155, -wy * 0.155
  end
  local function yawOf(dx, dy, fb) if (dx or 0) == 0 and (dy or 0) == 0 then return fb end return math.atan(dy, dx) end
  -- the pose drawn for a fielder at tau (mirrors Play.drawWorld's fielder branch) → world glove
  local function poseGlove(plan, pos, tau)
    if Play.poseAt then
      local tn, f, sx, sy, rot, dx, dy, piv, x, y, z, face = Play.poseAt(plan, pos, tau)
      if not tn then return nil end
      local gr, gf, gu = keyGlove(tn, f, sx, sy, rot, dx, dy, piv)
      if not gr then return nil end
      local fx, fy = cos(face), sin(face)
      return x + gr * fy + gf * fx, y - gr * fx + gf * fy, (z or 0) + gu, tn, f
    end
    local x, y, moving, pe, dir, ddx, ddy = Play.fielderAt(plan, pos, tau)
    if pos == "C" then x, y = 0, -3.2 end
    if plan.leap and plan.leap.pos == pos and tau >= plan.leap.t0 and tau < plan.leap.land then
      local L = plan.leap
      local top = max(2, L.z - 6.5)
      local face = math.atan(y, x)
      local gr, gf, gu = keyGlove("fielder", 4, 0.9, 1.12, 0, 0, 0, 0)
      local fx, fy = cos(face), sin(face)
      return x + gr * fy + gf * fx, y - gr * fx + gf * fy, top + gu, "fielder", 4
    end
    if not pe then return nil end
    local face = yawOf(ddx, ddy, math.atan(-y, -x))
    local tn, f, sx, sy, rot, dx, dy, piv, z = nil, nil, 1, 1, 0, 0, 0, 0, 0
    if pe.catch then
      if pe.track then
        tn, f, sx, sy, rot, dx, dy, _, piv = Anim.sample(pe.track, tau - pe.t0, 0)
        z = Play.catchLift(pe, tau)
        face = pe.face or face
      elseif pe.catch == "dive" then
        tn, f, sx, sy, rot, dx, dy, _, piv = Anim.sample("dive", tau - pe.ct + 0.2, 0)
      else
        local k = tau - pe.ct
        tn, f = "fielder", 4
        if pe.catch == "low" then
          f = 1
          if k < 0 then sx, sy = 1.12, 0.86 elseif k < 0.1 then sx, sy, rot = 1.22, 0.8, (floor(k * 30) % 2 == 0) and 4 or -4 else sx, sy = 1.06, 0.94 end
        else
          if k < 0 then sx, sy = 0.9, 1.12 elseif k < 0.1 then sx, sy, rot = 1.14, 0.88, (floor(k * 30) % 2 == 0) and 5 or -5 end
        end
      end
    elseif pe.track then
      tn, f, sx, sy, rot, dx, dy, _, piv = Anim.sample(pe.track, tau - pe.t0, 0)
    else
      return nil
    end
    local gr, gf, gu = keyGlove(tn, f, sx, sy, rot, dx, dy, piv)
    if not gr then return nil end
    local fx, fy = cos(face), sin(face)
    return x + gr * fy + gf * fx, y - gr * fx + gf * fy, z + gu, tn, f
  end
  -- the ball as drawn at tau (mirrors drawWorld's in-glove logic) → x, y, z, inGlove
  local function ballDrawn(plan, tau)
    if Play.ballDrawn then return Play.ballDrawn(plan, tau) end
    local bx, by, bz = Play.ballAt(plan, tau)
    local inG = false
    for i = 1, #plan.catches do
      local c = plan.catches[i]
      if tau >= c.ct and tau < c.ct + c.hold then
        local gx, gy = Play.fielderAt(plan, c.pos, tau)
        if c.pos == "C" then gx, gy = 0, -3.2 end
        if c.gz then
          local kx, ky, kz = nil, nil, nil
          if c.style == "slide" then kx, ky, kz = Play.trackGlove(c, tau) end
          if kx then bx, by, bz = gx + kx, gy + ky, kz
          elseif tau < c.ct + 0.3 then bx, by, bz = gx + c.gx, gy + c.gy, c.gz + Play.catchLift(c, tau)
          else bx, by, bz = gx, gy, 6.2 end
          if c.ct2 and tau < c.ct2 then bx = nil end
          inG = bx ~= nil
          if not bx then bx, by, bz = Play.ballAt(plan, tau) end
        else
          bx, by, bz = gx, gy, Play.GLOVE_Z[c.catch] or 5
          inG = true
        end
      end
    end
    return bx, by, bz, inG
  end
  local function d3(ax, ay, az, bx, by, bz) return sqrt((ax - bx) ^ 2 + (ay - by) ^ 2 + (az - bz) ^ 2) end
  local INF = { P = true, C = true, ["1B"] = true, ["2B"] = true, ["3B"] = true, SS = true }
  local function label(b, c)
    local plan = b.plan
    if c.style then
      if c.catch == "dive" then return "layout (LEAP_CATCH short of the wall)" end
      return c.style .. (INF[c.pos] and " (IF)" or " (OF)")
    end
    if c.catch == "throw" then
      if c.pos == "1B" then return "throw: 1B takes it" elseif c.pos == "C" then return "throw: C at home" end
      return "throw: " .. (INF[c.pos] and "IF bag/relay" or "OF")
    end
    if c.catch == "low" then
      if plan.bunt then return "bunt fielded" end
      if b.e.path then return "low: OF picks up a hit" end
      return "grounder" .. (INF[c.pos] and " (IF)" or " (OF)")
    end
    if c.catch == "high" then return plan.bunt and "bunt pop-up" or "high (legacy fly)" end
    return c.catch
  end
  local sources = {}
  step(function() print("[catchaudit] start") end, 1)
  step(function()
    for _, fx in ipairs({ { "dev", "fixtures_dev/ballcast/game-log.json" }, { "ultra", "fixtures_dev/ballcast/game-log-ultra.json" },
        { "bunts", "fixtures_dev/ballcast/game-log-bunts.json" }, { "g1", "fixtures/game-log.json" } }) do
      local d = BCKit.readJson(fx[2])
      if d and d.log then sources[#sources + 1] = { name = fx[1], people = d.people or {}, park = d.park or {}, log = d.log } end
    end
    local spec = HARNESS_PDSIM and pdsim and json.decodeFile("catchspec.json")
    if spec then
      for i = 1, HARNESS_PDSIM do
        spec.seed = "catch-" .. i
        local g = pdsim.new(spec)
        pdsim.step(g)
        local people = {}
        for _, side in ipairs({ "home", "away" }) do
          for _, p in ipairs(spec[side].players or {}) do people[p.id] = { id = p.id, name = p.name or p.id, pos = p.pos } end
        end
        sources[#sources + 1] = { name = "pdsim" .. i, people = people, park = spec.park, log = pdsim.log(g) }
      end
    end
    print("[catchaudit] sources " .. #sources)
  end, 2)
  step(function()
    local census = {}            -- path → { n, games = {} }
    local function cen(k, src) local e = census[k] or { n = 0, g = {} }; census[k] = e; e.n = e.n + 1; e.g[src] = (e.g[src] or 0) + 1 end
    local stats = {}
    local order = {}
    local nb, nbip = 0, 0
    local rows = {}
    for _, src in ipairs(sources) do
      local tl = TL.new({ people = src.people, park = src.park })
      TL.append(tl, src.log)
      for _, b in ipairs(tl.beats) do
        nb = nb + 1
        local plan = b.plan
        if b.kind == "bip" then nbip = nbip + 1 end
        if b.kind == "inc" and b.e and (b.e.kind == "BRAWL" or b.e.kind == "RACCOON_ON_FIELD") then cen("incident " .. b.e.kind .. " (dive track in the scrum / at the raccoon)", src.name) end
        if plan and b.kind == "bip" then
          for pos, l in pairs(plan.fposes or {}) do
            for _, e in ipairs(l) do
              if e.track == "dive" and not e.catch then cen("ftrack 'dive' (old fielder flop: dropped fly, E-)", src.name) end
              if e.catch == "dive" then cen("fcatch 'dive' (LEAP_CATCH short of the wall)" .. (e.track and (" -> " .. e.track) or " -> old dive track"), src.name) end
            end
          end
          local fc = plan.flyCatch
          if fc then cen("fly catch: " .. fc.style, src.name) end
          if plan.leap then cen("LEAP_CATCH at the wall (drawLeap)", src.name) end
          for _, c in ipairs(plan.catches or {}) do
            local lb = label(b, c)
            local s = stats[lb]
            if not s then s = { n = 0, e = 0, emax = 0, h = 0, hmax = 0, below = 0, ground = 0, snap = 0, snapmax = 0, dz = 0, nomodel = 0, roll = 0 }; stats[lb] = s; order[#order + 1] = lb end
            s.n = s.n + 1
            local ct = c.ct
            local px, py, pz, seg = Play.ballAt(plan, ct - 0.001)
            local gx, gy, gz = poseGlove(plan, c.pos, ct + 0.001)
            if not px or not gx then s.nomodel = s.nomodel + 1
            else
              local e = d3(px, py, pz, gx, gy, gz)
              s.e = s.e + e; s.emax = max(s.emax, e); s.dz = s.dz + (gz - pz)
              -- the half second before: below the glove (by > 0.75 ft) or on the ground (not a roller)
              local below, ground = false, false
              local isRoll = seg and seg.kind == "roll"
              if isRoll then s.roll = s.roll + 1 end
              for k = 1, 15 do
                local t = ct - k / 30
                local x, y, z, sg = Play.ballAt(plan, t)
                if z then
                  if z < gz - 0.75 then below = true end
                  if z < 0.35 and not (sg and sg.kind == "roll") then ground = true end
                end
              end
              if below then s.below = s.below + 1 end
              if ground then s.ground = s.ground + 1 end
              local qx, qy, qz = ballDrawn(plan, ct + 1 / 30)
              if qx then local sn = d3(px, py, pz, qx, qy, qz); s.snap = s.snap + sn; s.snapmax = max(s.snapmax, sn) end
              local hm = 0
              for k = 1, floor(min(c.hold, 0.6) * 30) - 1 do
                local t = ct + k / 30
                local bx, by, bz, inG = ballDrawn(plan, t)
                local hx, hy, hz = poseGlove(plan, c.pos, t)
                if bx and hx and inG then hm = max(hm, d3(bx, by, bz, hx, hy, hz)) end
              end
              s.h = s.h + hm; s.hmax = max(s.hmax, hm)
              if e > 2.5 and #rows < 400 then
                rows[#rows + 1] = string.format("[catchaudit] big %s %s b%d %s err %.1f ball (%.1f,%.1f,%.1f) glove (%.1f,%.1f,%.1f)", src.name, lb, b.n or 0, c.pos, e, px, py, pz, gx, gy, gz)
              end
            end
          end
        end
      end
    end
    print(string.format("[catchaudit] beats %d, balls in play %d, games %d", nb, nbip, #sources))
    local ks = {}
    for k in pairs(census) do ks[#ks + 1] = k end
    table.sort(ks)
    for _, k in ipairs(ks) do
      local e = census[k]
      local parts = {}
      for g, n in pairs(e.g) do parts[#parts + 1] = g .. ":" .. n end
      table.sort(parts)
      print(string.format("[census] %-70s %4d  (%s)", k, e.n, table.concat(parts, " ")))
    end
    table.sort(order)
    print("[contact] style | n | glove-ball at catch mean/max ft | glove z - ball z mean ft | %below glove before | %ground before (not rollers) | rollers | snap mean/max ft | held: ball-glove max mean/max ft | no model")
    for _, lb in ipairs(order) do
      local s = stats[lb]
      local m = max(1, s.n - s.nomodel)
      print(string.format("[contact] %-38s | %4d | %5.2f / %5.2f | %+5.2f | %5.1f%% | %5.1f%% | %d | %5.2f / %5.2f | %5.2f / %5.2f | %d",
        lb, s.n, s.e / m, s.emax, s.dz / m, 100 * s.below / m, 100 * s.ground / m, s.roll, s.snap / m, s.snapmax, s.h / m, s.hmax, s.nomodel))
    end
    for i = 1, min(#rows, HARNESS_ROWS or 40) do print(rows[i]) end
  end, 2)
elseif only == "stealaudit" then
  -- Tag / force plays and bat drops, over every fixture game (dev, ultra, bunts, the shell's g1),
  -- planned by Play (no drawing):
  --   [tag] every runner who reaches a base a throw is going to (safe), and every runner put out
  --     there (tag / force): the ball in the glove at the bag vs. the runner touching it vs. the
  --     sim's call. Safe: the ball must not beat him (ball >= touch - 0.02 s). Out: the ball must
  --     beat him (ball <= the time he'd touch it) and the out (r.outAt) can't land before the ball.
  --     A caught stealing's tag has to be on him (<= 6 ft from the bag). The call (plan.callT, the
  --     ump's call, the SAFE/OUT pop, Play.revealT) can't come before the play it calls.
  --   [bat] every batter after the bat leaves his hands (plan.batToss.t): any frame (1/30 s) where
  --     the pose drawn for him still has the bat (batter / batter_seq / bunter cells, the walker's
  --     bat-drag cells, the stance/swing/follow idles).
  local Play, TL, Anim, Pup = BallCast.Play, BallCast.Timeline, BallCast.Anim, BallCast.Puppets
  local sqrt, max, min, abs, floor = math.sqrt, math.max, math.min, math.abs, math.floor
  local BATSET = { batter = true, batter_seq = true, bunter = true }
  local function withBat(mode, name, tt)
    if not mode then return false end
    local tn, f
    if mode == "track" then tn, f = Anim.sample(name, tt or 0, 0) else tn, f = Pup.tableOf("home", name) end
    if not tn then return false end
    return BATSET[tn] or (tn == "walker" and f >= 5), tn, f
  end
  -- the batter's pose at tau (the game's own Play.batterPose when it has one; else a mirror of the
  -- old drawWorld batter branch) → mode ("track"/"idle"), name, track time
  local kt
  local function batterPose(b, tau)
    if Play.batterPose then return Play.batterPose(b, tau) end
    kt = kt or { swingLen = Anim.length("swing"), swingHit = Anim.keyTime("swing", 4) }
    local plan, pre = b.plan, b.pre
    if b.kind == "half" or b.kind == "end" or not pre.bat then return nil end
    for i = 1, #plan.runners do if plan.runners[i].from == 0 and tau >= plan.runners[i].t0 then return nil end end
    local bx0 = plan.batterExit
    if bx0 and tau >= bx0.t0 then return nil end
    if b.kind == "bip" and plan.bunt then
      local tr = plan.bunt.kind == "drag" and "drag_bunt" or "bunt_contact"
      return "track", tr, tau + Anim.keyTime(tr, plan.bunt.kind == "drag" and 3 or 2)
    elseif plan.bunt and plan.pitch and tau >= plan.bunt.show then return "track", "square", 0
    elseif b.kind == "bip" then
      if plan.homerBatter then return "track", "homer_batter", tau end
      return "track", "swing", kt.swingLen + tau
    elseif plan.hbp and tau >= plan.hbp then return "track", "pratfall", tau - plan.hbp
    elseif plan.swing then
      local t0 = plan.swing + 0.12 - kt.swingHit
      if tau < t0 then return "idle", "stance" end
      if plan.hyperWhiff and tau > t0 + kt.swingLen then return "track", "pratfall", tau - t0 - kt.swingLen end
      return "track", "swing", tau - t0
    end
    return "idle", "stance"
  end
  local sources = {}
  step(function()
    for _, fx in ipairs({ { "dev", "fixtures_dev/ballcast/game-log.json" }, { "ultra", "fixtures_dev/ballcast/game-log-ultra.json" },
        { "bunts", "fixtures_dev/ballcast/game-log-bunts.json" }, { "g1", "fixtures/game-log.json" } }) do
      local d = BCKit.readJson(fx[2])
      if d and d.log then sources[#sources + 1] = { name = fx[1], people = d.people or {}, park = d.park or {}, log = d.log } end
    end
    print("[stealaudit] sources " .. #sources)
  end, 2)
  step(function()
    -- the earliest throw that ends in a glove at base B, arriving in [ta, tb]
    local function ballIn(plan, B, ta, tb)
      local bx, by = Play.basePos(B)
      local best = nil
      for _, s in ipairs(plan.ball) do
        if s.kind == "line" and (s.throw or s.tagBall) and s.t1 >= ta and s.t1 <= tb then
          if (s.bx - bx) ^ 2 + (s.by - by) ^ 2 < 14 * 14 and (not best or s.t1 < best) then best = s.t1 end
        end
      end
      return best
    end
    local function distTo(r, tau, B)
      local x, y = Play.runnerPos(r, tau)
      local bx, by = Play.basePos(B)
      return sqrt((x - bx) ^ 2 + (y - by) ^ 2)
    end
    local cats, order, rows = {}, {}, {}
    local function cat(k) local c = cats[k]; if not c then c = { n = 0, bad = 0, early = 0, far = 0, margin = 0 }; cats[k] = c; order[#order + 1] = k end; return c end
    local bat = { beats = 0, bad = 0, frames = 0, waits = 0, waitMax = 0 }
    local batRows = {}
    for _, src in ipairs(sources) do
      local tl = TL.new({ people = src.people, park = src.park })
      TL.append(tl, src.log)
      for _, b in ipairs(tl.beats) do
        local plan = b.plan
        if plan and plan.runners then
          for _, r in ipairs(plan.runners) do
            local T = r.target
            local kindK = b.kind .. " " .. (T == 4 and "home" or (T .. "B"))
            if r.to ~= -1 then
              local tb = ballIn(plan, T, r.t0, r.t1 + 0.6)
              if tb then
                local c = cat(kindK .. " safe")
                c.n = c.n + 1
                local margin = tb - r.t1                       -- > 0: he's in first
                c.margin = c.margin + margin
                local bad = margin < -0.02
                local ev = max(tb, r.t1)
                local early = false
                if b.kind == "sb" then
                  if (plan.callT or 0) < ev - 0.01 or Play.revealT(b) < ev then early = true end
                  for _, u in ipairs(plan.umpCalls) do if u.t < ev - 0.05 then early = true end end
                  for _, p in ipairs(plan.pops) do if (p.text == "SAFE!" or p.text == "OUT!") and p.t < ev - 0.01 then early = true end end
                elseif r.from == 0 and b.kind == "bip" then
                  if (plan.callT or 0) < r.t1 - 0.01 then early = true end
                end
                if bad then c.bad = c.bad + 1 end
                if early then c.early = c.early + 1 end
                if (bad or early) and #rows < 400 then
                  rows[#rows + 1] = string.format("[tag] %s b%d i%s %s SAFE %d->%d ball %.2f runner %.2f (%+.2f) call %.2f reveal %.2f%s",
                    src.name, b.n, tostring(b.i), b.kind == "bip" and tostring(b.e.res) or b.kind, r.from, T, tb, r.t1, margin, plan.callT or -1, Play.revealT(b), early and " EARLY" or "")
                end
              end
            elseif r.outAt and r.role ~= "batter" then
              local Bt = min(r.from + 1, 4)
              local tb = ballIn(plan, Bt, -1, r.outAt + 0.3)
              if tb then
                local c = cat(kindK .. " out")
                c.n = c.n + 1
                local touch = r.t0 + (Bt - r.from) * 90 / r.speed      -- when he'd have had the bag
                c.margin = c.margin + (touch - tb)
                local bad = tb > touch + 0.02 or r.outAt < tb - 0.02
                local far = b.kind == "sb" and distTo(r, r.outAt, Bt) > 6
                local early = false
                if b.kind == "sb" then
                  if (plan.callT or 0) < r.outAt - 0.01 or Play.revealT(b) < r.outAt then early = true end
                  for _, p in ipairs(plan.pops) do if p.text == "OUT!" and p.t < r.outAt - 0.01 then early = true end end
                end
                if bad then c.bad = c.bad + 1 end
                if far then c.far = c.far + 1 end
                if early then c.early = c.early + 1 end
                if (bad or far or early) and #rows < 400 then
                  rows[#rows + 1] = string.format("[tag] %s b%d i%s %s OUT %d->%d ball %.2f touch %.2f out %.2f dist@out %.1f ft call %.2f%s",
                    src.name, b.n, tostring(b.i), b.kind == "bip" and tostring(b.e.res) or b.kind, r.from, Bt, tb, touch, r.outAt, distTo(r, r.outAt, Bt), plan.callT or -1, early and " EARLY" or "")
                end
              end
            end
          end
          -- the bat on the ground: every later frame of the beat
          local toss = plan.batToss
          if toss then
            bat.beats = bat.beats + 1
            local nbad, first, firstName = 0, nil, nil
            local runT = nil
            for _, r in ipairs(plan.runners) do if r.from == 0 then runT = r.t0 end end
            if runT and runT > toss.t then
              bat.waits = bat.waits + 1
              bat.waitMax = max(bat.waitMax, runT - toss.t)
            end
            local t = toss.t + 0.001
            while t < (b.dur or 0) do
              local mode, name, tt = batterPose(b, t)
              local wb, tn, f = withBat(mode, name, tt)
              if wb then
                nbad = nbad + 1
                if not first then first, firstName = t, string.format("%s %s (%s #%d)", mode, name, tn, f) end
              end
              t = t + 1 / 30
            end
            if nbad > 0 then
              bat.bad = bat.bad + 1
              bat.frames = bat.frames + nbad
              if #batRows < 400 then
                batRows[#batRows + 1] = string.format("[bat] %s b%d i%s %s%s toss %.2f run %s: %d frames with the bat, first %.2f %s",
                  src.name, b.n, tostring(b.i), b.kind, b.kind == "bip" and (" " .. tostring(b.e.res) .. (plan.bunt and " bunt" or "")) or (b.walk and " walk" or ""),
                  toss.t, runT and string.format("%.2f", runT) or "-", nbad, first, firstName)
              end
            end
          end
        end
      end
    end
    table.sort(order)
    local tn, tbad, tearly, tfar = 0, 0, 0, 0
    print("[tag] kind | n | ball-beats-call mismatches | early calls | CS tag far from bag | mean margin s (safe: ball - touch; out: touch - ball)")
    for _, k in ipairs(order) do
      local c = cats[k]
      tn, tbad, tearly, tfar = tn + c.n, tbad + c.bad, tearly + c.early, tfar + c.far
      print(string.format("[tag] %-16s | %4d | %4d | %4d | %4d | %+5.2f", k, c.n, c.bad, c.early, c.far, c.margin / max(1, c.n)))
    end
    print(string.format("[tag] TOTAL plays %d mismatches %d early calls %d far tags %d", tn, tbad, tearly, tfar))
    print(string.format("[bat] TOTAL beats with a bat drop %d, beats with the bat in hand after the drop %d (%d frames); runs after the drop %d (longest wait %.2f s)",
      bat.beats, bat.bad, bat.frames, bat.waits, bat.waitMax))
    for i = 1, min(#rows, HARNESS_ROWS or 60) do print(rows[i]) end
    for i = 1, min(#batRows, HARNESS_ROWS or 60) do print(batRows[i]) end
  end, 2)
elseif only == "stealstrip" then
  -- Frame strips (game camera as planned) of steals and bat drops: HARNESS_GAME's beats picked
  -- from the log (not the plan, so before/after show the same plays): the first stolen bases and
  -- caught stealings, plus HARNESS_BATPICKS (log indexes b.i). steal_<kind>_<i>_NN.png / bat_<i>_NN.png
  step(function() App.push(BC, { gameId = HARNESS_GAME or "bunts", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" and not BC:timelinePending() end, 1800)
  step(function() BC.playing = false end, 10)
  local N = tonumber(HARNESS_FRAMES or 14)
  local picks = {}
  step(function()
    local nsafe, nout = 0, 0
    for _, b in ipairs(BC.tl.beats) do
      if b.kind == "sb" then
        if b.e.ok and nsafe < (HARNESS_NSTEAL or 2) then nsafe = nsafe + 1; picks[#picks + 1] = { b = b, name = "steal_safe_" .. b.i, t0 = 1.6, t1 = 4.2 }
        elseif not b.e.ok and nout < (HARNESS_NSTEAL or 2) then nout = nout + 1; picks[#picks + 1] = { b = b, name = "steal_out_" .. b.i, t0 = 1.6, t1 = 4.2 } end
      end
    end
    for w in string.gmatch(HARNESS_BATPICKS or "", "[^,]+") do
      local i = tonumber(w)
      for _, b in ipairs(BC.tl.beats) do if b.i == i then picks[#picks + 1] = { b = b, name = "bat_" .. i, t0 = 0, t1 = 1.6 } end end
    end
    print("[stealstrip] picks " .. #picks)
  end, 1)
  for k = 1, 12 do
    for i = 0, N - 1 do
      step(function()
        local p = picks[k]
        if not p then return end
        local b = p.b
        local tt = p.t0 + i * (p.t1 - p.t0) / (N - 1)
        -- (the high shot's re-framing glide runs on plan time: a held scrub frame never finishes
        -- it, so start each frame framed as the shot wants it)
        for _, c in ipairs(b.plan.cams) do c.glide = nil end
        BC.mode = "watch"
        BC.t = b.start + tt
        BC.lastBeat = nil
        BC.playing = false
        BC.scrubT = playdate.getCurrentTimeMilliseconds() + 100000
      end, 4)
      step(function()
        local p = picks[k]
        if p then
          shot(string.format("%s_%02d", p.name, i))
          print(string.format("[stealstrip] %s_%02d tau %.2f cam %s shot %s", p.name, i, BC.t - p.b.start,
            tostring(BallCast.Play.camAt(p.b.plan, BC.t - p.b.start).name), tostring(BC.camShot and BC.camShot.name)))
        end
      end, 1)
    end
  end
  step(function() App.pop() end, 5)
elseif only == "catchsheet" then
  -- Every catch style frame by frame around the catch (HARNESS_FRAMES frames from 0.6 s before
  -- to 0.9 s after), at the gameplay camera (the play's low "dive" / "track" cuts taken out) and
  -- for the big ones at the play's own camera too: catch_<case>_<cam>_<i>.png, and a
  -- "[crop] <file> sx sy ppf" line per frame (the fielder on screen) for the sheet crops.
  -- The outfield styles are forced (Play.forceCatchStyle) on the same fixture fly balls before and
  -- after, picked from the log (not the plan), so the two runs show the same plays.
  local Play = BallCast.Play
  step(function() App.push(BC, { gameId = HARNESS_GAME or "ultra", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" and not BC:timelinePending() end, 1800)
  step(function() BC.playing = false end, 10)
  local OFP = { LF = true, CF = true, RF = true }
  local function landD(b)
    local p = b.e and b.e.path
    if not p or #p < 6 then return 0 end
    return math.sqrt(p[#p - 2] ^ 2 + p[#p - 1] ^ 2)
  end
  local function apexOf(b) local m = 0; for i = 3, #b.e.path, 3 do m = math.max(m, b.e.path[i]) end; return m end
  local function flyOut(b) return b.kind == "bip" and b.e.res == "OUT" and b.e.path and #b.e.path >= 6 and apexOf(b) > 12 and not b.ultra end
  local mid, deep, ifpop = nil, nil, nil
  step(function()
    for _, b in ipairs(BC.tl.beats) do
      if flyOut(b) and OFP[b.e.f] then
        local d = landD(b)
        if d > 230 and d < 300 and not mid then mid = b end
        if not deep or d > landD(deep) then deep = b end
      elseif flyOut(b) and not OFP[b.e.f] and not ifpop then ifpop = b end
    end
    print(string.format("[catchsheet] mid b%s %.0f ft, deep b%s %.0f ft, IF pop b%s", tostring(mid and mid.n), mid and landD(mid) or 0,
      tostring(deep and deep.n), deep and landD(deep) or 0, tostring(ifpop and ifpop.n)))
  end, 2)
  local function firstCatch(pred)
    for _, b in ipairs(BC.tl.beats) do
      if b.kind == "bip" and b.plan then
        for _, c in ipairs(b.plan.catches or {}) do if pred(b, c) then return b, c end end
      end
    end
  end
  local CASES = {
    { "layout", "mid", "layout" }, { "slide", "mid", "slide" }, { "shoe", "mid", "shoe" }, { "stab", "mid", "stab" },
    { "basket", "mid", "basket" }, { "side", "mid", "side" }, { "backhand", "mid", "backhand" }, { "juggle", "mid", "juggle" },
    { "leap", "deep", "leap" }, { "crash", "deep", "crash" },
    { "ifpop", "ifpop", nil },
    { "grounder", function(b, c) return c.catch == "low" and not b.e.path and not b.plan.bunt and c.pos == "SS" end },
    { "ofpickup", function(b, c) return c.catch == "low" and b.e.path ~= nil end },
    { "throw1b", function(b, c) return c.catch == "throw" and c.pos == "1B" end },
    { "throwbag", function(b, c) return c.catch == "throw" and c.pos ~= "1B" and c.pos ~= "C" end },
  }
  local N = tonumber(HARNESS_FRAMES or 12)
  for _, cs in ipairs(CASES) do
    local name = cs[1]
    local b, c
    step(function()
      b, c = nil, nil
      if type(cs[2]) == "function" then
        b, c = firstCatch(cs[2])
      else
        b = (cs[2] == "mid" and mid) or (cs[2] == "deep" and deep) or (cs[2] == "ifpop" and ifpop) or nil
        if b then
          Play.forceCatchStyle = cs[3]
          Play.plan(b, BC.tl)
          Play.forceCatchStyle = nil
          BallCast.Timeline.layout(BC.tl)
          c = b.plan.flyCatch or b.plan.lastCatch
        end
      end
      print(string.format("[catchsheet] %s: b%s %s ct %s", name, tostring(b and b.n), c and c.pos or "-", c and string.format("%.2f", c.ct) or "-"))
    end, 2)
    for _, camk in ipairs({ "game", "play" }) do
      local saved
      step(function()
        if not b then return end
        saved = b.plan.cams
        if camk == "game" then
          local l = {}
          for _, cc in ipairs(saved) do if not (cc.opt and (cc.opt.play == "dive" or cc.opt.play == "track")) then l[#l + 1] = cc end end
          b.plan.cams = l
        end
      end, 1)
      local playCut = false
      if camk == "play" then
        step(function()
          playCut = false
          if b then for _, cc in ipairs(b.plan.cams) do if cc.opt and cc.opt.play == "dive" then playCut = true end end end
        end, 1)
      end
      for i = 0, N - 1 do
        local tt
        step(function()
          if not b or (camk == "play" and not playCut) then return end
          tt = c.ct - 0.6 + i * 1.5 / (N - 1)
          BC.mode = "watch"
          BC.t = b.start + tt
          BC.lastBeat = nil
          BC.playing = false
          BC.scrubT = playdate.getCurrentTimeMilliseconds() + 100000
        end, 4)
        step(function()
          if not b or (camk == "play" and not playCut) then return end
          local fname = string.format("catch_%s_%s_%02d", name, camk, i)
          shot(fname)
          local x, y = Play.fielderAt(b.plan, c.pos, tt)
          if c.pos == "C" and not b.plan.fmoves.C then x, y = 0, -3.2 end
          local sx, sy, d = BC.R:project(x, y, 3)
          if sx then print(string.format("[crop] %s %.1f %.1f %.2f %.2f", fname, sx, sy, BC.R:ppf(d), tt - c.ct)) end
        end, 1)
      end
      step(function() if b and saved then b.plan.cams = saved end end, 1)
    end
  end
  step(function() App.pop() end, 5)
elseif only == "tvcams" then
  -- every live camera at typical moments: the tallest player billboard on screen (a 6.5 ft
  -- figure projected at the people who stand closest to the lenses), to catch shots that put
  -- a puppet in the lens. Limit: about the 2x sprite height (88 px).
  step(function() App.push(BC, { gameId = "ultra", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  step(function()
    local R, R3, Play = BC.R, BallCast.Render, BallCast.Play
    local tl = BC.tl
    local pitchB, bipB
    for _, b in ipairs(tl.beats) do
      if not pitchB and b.kind == "p" and b.n > 20 then pitchB = b end
      if not bipB and b.kind == "bip" and b.n > 20 and b.plan.catchPos then bipB = b end
    end
    local people = { { 3.2, 0.6 }, { -3.2, 0.6 }, { 0, -3.5 }, { 0, -6.6 }, { 0, 59 } }
    for _, a in pairs(Play.ALIGN) do people[#people + 1] = a end
    local worst = 0
    local function check(label, b, cc, tau)
      local cam = R3.shot(R, b, tau, cc)
      R:setCamera(cam)
      local mx, who = 0, nil
      for _, p in ipairs(people) do
        local x0, y0 = R:project(p[1], p[2], 0)
        local x1, y1 = R:project(p[1], p[2], 6.5)
        if x0 and x1 and x0 > -40 and x0 < 440 and y1 < 260 and y0 > -20 then
          local h = math.abs(y0 - y1)
          if h > mx then mx, who = h, p[1] .. "," .. p[2] end
        end
      end
      if mx > worst then worst = mx end
      print(string.format("[tvcams] %-22s tau %.1f  tallest %3d px (at %s)%s", label, tau, math.floor(mx), tostring(who), mx > 88 and "  <-- TOO BIG" or ""))
    end
    for _, cn in ipairs({ "pitch", "behindPlate", "pitcherSide", "batterSide" }) do
      for _, side in ipairs({ 1, -1 }) do
        for _, tau in ipairs({ 0.2, 1.0, 2.0 }) do check(cn .. " side " .. side, pitchB, { name = cn, opt = { side = side } }, tau) end
      end
    end
    for _, cn in ipairs({ "high", "dugout", "runner", "wallLow", "deepC", "blimp" }) do
      for _, side in ipairs({ 1, -1 }) do
        for _, tau in ipairs({ 0.3, 1.5, 3.0 }) do check(cn .. " side " .. side, bipB, { name = cn, opt = { side = side } }, tau) end
      end
    end
    print("[tvcams] worst " .. math.floor(worst) .. " px")
    -- the batter at the moment the pitch arrives, on every pitching shot: share of his
    -- billboard on screen, and share hidden behind the (closer) catcher / ump billboards
    local function box(x, y)
      local x0, y0 = R:project(x, y, 0)
      local x1, y1 = R:project(x, y, 6.5)
      if not x0 or not x1 then return nil end
      local h = math.abs(y0 - y1)
      local w = h * 0.45
      return { x0 - w / 2, math.min(y0, y1), x0 + w / 2, math.max(y0, y1) }
    end
    local function area(r) return math.max(0, r[3] - r[1]) * math.max(0, r[4] - r[2]) end
    local function inter(a, b) return { math.max(a[1], b[1]), math.max(a[2], b[2]), math.min(a[3], b[3]), math.min(a[4], b[4]) } end
    local bad = 0
    for _, bp in ipairs({ 9, -9 }) do
      BallCast.Render.BP_SIDE = bp
      local nb, onSum, covMax = 0, 0, 0
      for _, b in ipairs(tl.beats) do
        if b.kind == "p" and b.plan.pitch then
          for _, cn in ipairs({ "pitch", "behindPlate", "batterSide" }) do
            local tau = b.plan.pitch.tPlate
            R:setCamera(R3.shot(R, b, tau, { name = cn, opt = { side = 1 } }))
            local bx = -Play.batSide(b.pre.bat) * 3.2
            local bb = box(bx, 0.6)
            if bb then
              local on = area(inter(bb, { 0, 0, 400, 225 })) / math.max(1, area(bb))
              local cov = 0
              for _, o in ipairs({ { 0, -3.5 }, { 0, -6.6 } }) do
                local ob = box(o[1], o[2])
                if ob then cov = cov + area(inter(bb, ob)) / math.max(1, area(bb)) end
              end
              cov = math.min(1, cov)
              if cn == "behindPlate" then nb = nb + 1; onSum = onSum + on; covMax = math.max(covMax, cov) end
              if on < 0.7 and bad == 0 then
                local c = R.cam
                print(string.format("[tvcams] debug cam %.0f %.0f %.0f -> %.0f %.0f %.0f fov %.1f  batter box %.0f %.0f %.0f %.0f  stand z %s", c[1], c[2], c[3], c[4], c[5], c[6], c[7], bb[1], bb[2], bb[3], bb[4], tostring(BallCast.Cam.standZ(R.park, c[1], c[2]))))
              end
              if on < 0.7 then
                bad = bad + 1
                if bad < 8 then print(string.format("[tvcams] BATTER OFF %s beat %d: %.0f%% on screen", cn, b.n, on * 100)) end
              end
            end
          end
        end
      end
      print(string.format("[tvcams] behindPlate side %d: batter on screen avg %.0f%%, hidden behind catcher/ump up to %.0f%%", bp, onSum / math.max(1, nb) * 100, covMax * 100))
    end
    BallCast.Render.BP_SIDE = nil
    print("[tvcams] batter < 70% on screen: " .. bad .. " shot(s)")
  end, 2)
  step(function() App.pop() end, 5)
elseif only == "tvparks" then
  -- Every camera (the scene's shots, the establishing orbit, the intro orbit, the open's
  -- flyover, the replay angles) in every park's baked geometry, at several moments:
  --   INSIDE  the eye is under a stand's seating surface (inside the stand mass)
  --   NEAR    > 60 % of a 16x10 ray grid hits a non-ground polygon closer than 40 ft
  -- The camera is first passed through Cam.safeEye (the guard), as Live:setCamera does.
  local Cam, R3, Play, Geo = BallCast.Cam, BallCast.Render, BallCast.Play, BallCast.Geo
  step(function() App.push(BC, { gameId = "ultra", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  step(function()
    local pj = Cam.parksJson()
    local beats = {}
    for _, b in ipairs(BC.tl.beats) do
      if b.kind == "p" and not beats.p and b.n > 20 then beats.p = b end
      if b.kind == "bip" and b.e.res == "HR" and not beats.hr then beats.hr = b end
      if b.kind == "bip" and b.plan.catchPos and not beats.fly and b.e.res ~= "HR" then beats.fly = b end
      if b.kind == "half" and not beats.half then beats.half = b end
    end
    local total, bad = 0, 0
    local batterX
    for pid, pk in pairs(pj.parks) do
      local bk = Geo.baked({ id = pid })
      local mats = {}
      for i, m in ipairs(bk.materials) do mats[i - 1] = m.name end
      -- polygons (xyz), skipping the flat ground
      local polys = {}
      local P = bk.P
      local i = 1
      while i <= #P do
        local m, layer, ti, nv = P[i], P[i + 1], P[i + 2], P[i + 3]
        i = i + 4
        local stride = ti > 0 and 5 or 3
        local pts, zmax = {}, -1e9
        for k = 0, nv - 1 do
          local j = i + k * stride
          pts[#pts + 1] = { P[j], P[j + 1], P[j + 2] }
          if P[j + 2] > zmax then zmax = P[j + 2] end
        end
        i = i + nv * stride
        if zmax > 0.6 then
          local cx, cy, cz = 0, 0, 0
          for _, p in ipairs(pts) do cx, cy, cz = cx + p[1], cy + p[2], cz + p[3] end
          cx, cy, cz = cx / #pts, cy / #pts, cz / #pts
          local rr = 0
          for _, p in ipairs(pts) do rr = math.max(rr, math.sqrt((p[1] - cx) ^ 2 + (p[2] - cy) ^ 2 + (p[3] - cz) ^ 2)) end
          local name = mats[m] or "?"
          polys[#polys + 1] = { pts = pts, c = { cx, cy, cz }, r = rr, mat = name,
            stand = name == "crowd" or name == "stands_back" or name == "deck_facade" or name == "deck_shadow" or name == "stands_wall" }
        end
      end
      local park = { id = pid, fences = pk.fences, walls = pk.walls, foulTerritory = pk.foulTerritory }
      Cam.guardBuild(park)
      local r = { park = park, presets = Cam.presets(park, bk.cams) }
      local function sub(a, b) return { a[1] - b[1], a[2] - b[2], a[3] - b[3] } end
      local function cross(a, b) return { a[2] * b[3] - a[3] * b[2], a[3] * b[1] - a[1] * b[3], a[1] * b[2] - a[2] * b[1] } end
      local function dot(a, b) return a[1] * b[1] + a[2] * b[2] + a[3] * b[3] end
      local function hit(p, E, d)
        local v = p.pts
        local n = cross(sub(v[2], v[1]), sub(v[3], v[1]))
        local den = dot(n, d)
        if math.abs(den) < 1e-6 then return nil end
        local t = dot(n, sub(v[1], E)) / den
        if t <= 0 then return nil end
        local q = { E[1] + d[1] * t, E[2] + d[2] * t, E[3] + d[3] * t }
        local sgn = 0
        for k = 1, #v do
          local a, b = v[k], v[k % #v + 1]
          local s = dot(cross(sub(b, a), sub(q, a)), n)
          if s ~= 0 then
            if sgn == 0 then sgn = s > 0 and 1 or -1
            elseif (s > 0 and 1 or -1) ~= sgn then return nil end
          end
        end
        return t
      end
      local function inside(E)
        -- under a stand surface: a downward ray from the eye misses, an upward ray hits a stand
        for _, p in ipairs(polys) do
          if p.stand and math.abs(p.c[1] - E[1]) < p.r + 1 and math.abs(p.c[2] - E[2]) < p.r + 1 then
            local t = hit(p, E, { 0, 0, 1 })
            if t and t > 1 then return p.mat end
          end
        end
        return nil
      end
      local function check(label, cam)
        cam = Cam.safeEye and Cam.safeEye(park, { cam[1], cam[2], cam[3], cam[4], cam[5], cam[6], cam[7] }) or cam
        local E = { cam[1], cam[2], cam[3] }
        local f = sub({ cam[4], cam[5], cam[6] }, E)
        local fl = math.sqrt(dot(f, f)); f = { f[1] / fl, f[2] / fl, f[3] / fl }
        local rt = { f[2], -f[1], 0 }
        local rl = math.sqrt(dot(rt, rt)); rt = { rt[1] / rl, rt[2] / rl, 0 }
        local up = cross(rt, f)
        local scale = 200 / math.tan(math.rad(cam[7]) / 2)
        local near = {}
        for _, p in ipairs(polys) do
          local dd = math.sqrt((p.c[1] - E[1]) ^ 2 + (p.c[2] - E[2]) ^ 2 + (p.c[3] - E[3]) ^ 2)
          if dd - p.r < 40 then near[#near + 1] = p end
        end
        local hits, n = 0, 0
        matHit = {}
        for gy = 0, 9 do
          for gx = 0, 15 do
            local sx, sy = (gx + 0.5) * 25 - 200, 120 - (gy + 0.5) * 24
            local d = { f[1] + (rt[1] * sx + up[1] * sy) / scale, f[2] + (rt[2] * sx + up[2] * sy) / scale, f[3] + (rt[3] * sx + up[3] * sy) / scale }
            local dl = math.sqrt(dot(d, d)); d = { d[1] / dl, d[2] / dl, d[3] / dl }
            n = n + 1
            for _, p in ipairs(near) do
              local t = hit(p, E, d)
              if t and t < 40 then hits = hits + 1; matHit[p.mat] = (matHit[p.mat] or 0) + 1 break end
            end
          end
        end
        local ins = inside(E)
        local cov = hits / n
        -- pitching shots: the batter's billboard on screen when the pitch arrives
        if batterX then
          local function proj(x, y, z)
            local v = { x - E[1], y - E[2], z - E[3] }
            local d = dot(v, f)
            if d < 1 then return nil end
            return 200 + dot(v, rt) * scale / d, 120 - dot(v, up) * scale / d
          end
          local fx, fy = proj(batterX, 0.6, 0)
          local hx, hy = proj(batterX, 0.6, 6.5)
          local frac = 0
          if fx and hx then
            local hgt = math.abs(fy - hy)
            local w = hgt * 0.45
            local x0, x1, y0, y1 = fx - w / 2, fx + w / 2, math.min(fy, hy), math.max(fy, hy)
            local ix = math.max(0, math.min(x1, 400) - math.max(x0, 0))
            local iy = math.max(0, math.min(y1, 225) - math.max(y0, 0))
            frac = (ix * iy) / math.max(1, (x1 - x0) * (y1 - y0))
          end
          if frac < 0.7 then
            bad = bad + 1
            print(string.format("[tvparks] %-10s %-28s BATTER %.0f%% on screen", pid, label, frac * 100))
          end
          batterX = nil
        end
        total = total + 1
        if ins or cov > 0.6 then
          bad = bad + 1
          local ms = {}
          for k, v in pairs(matHit) do ms[#ms + 1] = k .. ":" .. v end
          print(string.format("[tvparks] %-10s %-28s eye (%.0f,%.0f,%.0f) %s near %.0f%% [%s]", pid, label, E[1], E[2], E[3], ins and ("INSIDE " .. ins) or "", cov * 100, table.concat(ms, " ")))
        end
      end
      local function shot(label, b, cc, taus)
        if not b then return end
        for _, tau in ipairs(taus) do check(label .. " " .. tau, R3.shot(r, b, tau, cc)) end
      end
      -- every pitch in the game on the pitching shots, at the plate
      for _, b in ipairs(BC.tl.beats) do
        if b.kind == "p" and b.plan.pitch and b.n % 7 == 0 then
          for _, cn in ipairs({ "pitch", "behindPlate", "batterSide" }) do
            batterX = -Play.batSide(b.pre.bat) * 3.2
            check(cn .. " pitch " .. b.n, R3.shot(r, b, b.plan.pitch.tPlate, { name = cn, opt = { side = 1 } }))
          end
        end
      end
      for _, side in ipairs({ 1, -1 }) do
        for _, cn in ipairs({ "pitch", "behindPlate", "pitcherSide", "batterSide" }) do shot(cn .. " s" .. side, beats.p, { name = cn, opt = { side = side } }, { 0.2, 1.5 }) end
        for _, cn in ipairs({ "high", "dugout", "runner", "wallLow", "deepL", "deepC", "deepR", "blimp" }) do
          shot(cn .. " s" .. side, beats.fly, { name = cn, opt = { side = side } }, { 0.3, 1.5, 3 })
          shot(cn .. " hr s" .. side, beats.hr, { name = cn, opt = { side = side } }, { 1, 3 })
        end
        shot("blimp half s" .. side, beats.half, { name = "blimp", opt = { side = side } }, { 0, 1.5, 3 })
      end
      shot("establish", beats.half, { name = "high", opt = { establish = true } }, { 0, 1, 2, 3, 4, 6 })
      for a = 0, 330, 30 do
        local ar = math.rad(a)
        check("intro orbit " .. a, { math.sin(ar) * 280, -math.cos(ar) * 280 + 60, 110, 0, 170, 10, 50 })
      end
      for k = 0, 10 do check("open flyover " .. k / 10, BallCast.TV.flyCam(k / 10)) end
    end
    print(string.format("[tvparks] %d camera checks, %d offenders", total, bad))
  end, 2)
  step(function() App.pop() end, 5)
elseif only == "tvpip" then
  -- the swing cam on four swings: a miss, a foul, weak contact, a homer (clock stepped 1/15 s)
  local PiP = BallCast.TVPiP
  step(function() App.push(BC, { gameId = HARNESS_GAME or "ultra", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  step(function() PiP.force = true end, 20)
  local function find(pred)
    for i, b in ipairs(BC.tl.beats) do if pred(b, i) then return b end end
  end
  local function nextBip(b) local nb = BC.tl.beats[b.n + 1]; return nb and nb.kind == "bip" and nb or nil end
  local cases = {
    { "tv_pip_miss", function(b) return b.kind == "p" and b.e.r == "S" and b.k and b.n > 20 end },
    { "tv_pip_foul", function(b) return b.kind == "p" and b.e.r == "F" and (b.pre.s or 0) == 2 and b.n > 20 end },
    { "tv_pip_weak", function(b) local nb = b.kind == "p" and b.e.r == "X" and nextBip(b); return nb and (nb.e.ev or 99) < 80 and nb.e.res ~= "HR" end },
    { "tv_pip_homer", function(b) local nb = b.kind == "p" and b.e.r == "X" and nextBip(b); return nb and nb.e.res == "HR" end },
  }
  for _, c in ipairs(cases) do
    local b
    step(function() b = find(c[2]); print("[harness] pip " .. c[1] .. " beat " .. tostring(b and b.n)) end, 1)
    for k = 0, 75 do
      step(function()
        if not b then return end
        local t = b.plan.pitch.tPlate - 0.75 + k / 15
        BC.mode = "watch"
        BC.t = b.start + t
        BC.lastBeat = nil
        BC.playing = false
        BC.scrubT = playdate.getCurrentTimeMilliseconds() + 100000
      end, 1)
      step(function() if b then shot(string.format("%s_%03d", c[1], k)) end end, 1)
    end
  end
  -- 1x playback cost with the swing cam on every swing
  step(function()
    BC:debugSeek(function(b) return b.kind == "p" and b.n > 50 end, 0)
    BC.playing = true
    BC.scrubT = 0
    timingTag = "pitch+pip"
  end, 240)
  step(function() timingTag = nil; PiP.force = false; App.pop() end, 5)
elseif only == "tvspin" then
  -- the spin cam for every pitch type in the game, and the four pitch powers (1/15 s a frame)
  local Spin = BallCast.TVSpin
  step(function() App.push(BC, { gameId = HARNESS_GAME or "ultra", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  step(function() Spin.force = true end, 20)
  local cases = {}
  for _, ty in ipairs({ "FB", "SI", "CT", "SL", "CB", "CH", "SPL", "KN", "SPIT" }) do
    cases[#cases + 1] = { "tv_spin_" .. ty, function(b) return b.kind == "p" and b.e.t == ty and not b.ultra and b.plan.cams[1].name == "pitch" end }
  end
  for _, pw in ipairs({ "FIREBALL", "CLOUD_BALL", "WARP_PITCH", "STOPPER" }) do
    cases[#cases + 1] = { "tv_spin_" .. pw, function(b) return b.kind == "p" and b.plan.power == pw end }
  end
  for _, c in ipairs(cases) do
    local b
    step(function()
      b = nil
      for _, x in ipairs(BC.tl.beats) do if c[2](x) then b = x break end end
      print("[harness] spin " .. c[1] .. " beat " .. tostring(b and b.n))
    end, 1)
    for k = 0, 40 do
      step(function()
        if not b then return end
        local p = b.plan.pitch
        local t = p.tRel - 0.3 + k / 15
        if t > p.tPlate + 0.9 then return end
        BC.mode = "watch"
        BC.t = b.start + t
        BC.lastBeat = nil
        BC.playing = false
        BC.scrubT = playdate.getCurrentTimeMilliseconds() + 100000
      end, 1)
      step(function()
        if b and b.plan.pitch.tRel - 0.3 + k / 15 <= b.plan.pitch.tPlate + 0.9 then shot(string.format("%s_%03d", c[1], k)) end
      end, 1)
    end
  end
  step(function() Spin.force = false; App.pop() end, 5)
elseif only == "tvstart" then
  -- a skipIntro start played at 1x from the first pitch (no intro menu idle time): every
  -- lower third / scorebug name / pill should already be built when it shows ([bchud] MISS)
  step(function() App.push(BC, { gameId = HARNESS_GAME or "g1", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  step(function() BC.playing = true; BC.scrubT = 0; BC.speed = 1 end, 30 * 240)
  step(function()
    print("[harness] tvstart misses " .. tostring(BallCast.HUD.misses or 0) .. ", t=" .. string.format("%.0f", BC.t) .. " beat " .. tostring(BC:curBeatIndex()))
    App.pop()
  end, 5)
elseif only == "tvcalls" then
  -- the call text: every call image on one screen (sizes), then live sequences of a few
  local Calls = BallCast.TVCalls
  step(function() App.push(BC, { gameId = HARNESS_GAME or "ultra", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  step(function() BC.playing = false end, 10)
  local cases = {
    { "ball", function(b) return b.kind == "p" and b.e.r == "B" and not b.walk and b.plan.cams[1].name == "pitch" end },
    { "strikeC", function(b) return b.kind == "p" and b.e.r == "C" and not b.k and b.plan.cams[1].name == "pitch" end },
    { "strikeS", function(b) return b.kind == "p" and b.e.r == "S" and not b.k and b.plan.cams[1].name == "pitch" end },
    { "foul", function(b) return b.kind == "p" and b.e.r == "F" and b.plan.cams[1].name == "pitch" end },
    { "k3C", function(b) return b.kind == "p" and b.k and b.e.r == "C" end },
    { "k3S", function(b) return b.kind == "p" and b.k and b.e.r == "S" end },
    { "ball4", function(b) return b.kind == "p" and b.walk and b.e.r == "B" end },
    { "hbp", function(b) return b.kind == "p" and b.e.r == "H" end },
    { "out", function(b) return b.kind == "bip" and b.e.res == "OUT" and b.plan.catchT end },
    { "single", function(b) return b.kind == "bip" and b.e.res == "1B" end },
    { "double", function(b) return b.kind == "bip" and b.e.res == "2B" end },
    { "dp", function(b) return b.kind == "bip" and b.e.res == "DP" end },
  }
  for _, c in ipairs(cases) do
    local b, t0
    step(function()
      b = nil
      for _, x in ipairs(BC.tl.beats) do if c[2](x) then b = x break end end
      if b then local _; _, t0 = Calls.callFor(BC.tl, b) end
      print("[harness] call " .. c[1] .. " beat " .. tostring(b and b.n))
    end, 1)
    for k = 0, 16 do
      step(function()
        if not b or not t0 then return end
        BC.mode = "watch"
        BC.t = b.start + t0 - 0.07 + k / 15
        BC.lastBeat = nil
        BC.playing = false
        BC.scrubT = 0
        BC.lastMs = playdate.getCurrentTimeMilliseconds()
      end, 1)
      step(function() if b and t0 then shot(string.format("tv_call_%s_%03d", c[1], k)) end end, 1)
    end
  end
  step(function() App.pop() end, 5)
elseif only == "camaudit" then
  -- Occlusion audit. Every camera the replay can cut to (each beat's own shots at many
  -- moments, both batter hands; the replay angles; the open's flyover and the intro orbit),
  -- in all nine parks, through the camera guard like Live:setCamera:
  --   HIDDEN  an action point (ball, batter, pitcher, catcher, the fielder making the play,
  --           runners and their bases) in the frame but behind park geometry
  --   JUNK    park geometry between the lens and the field in the frame's central half
  -- Then renders the blimp shots of every park (and the worst offenders) for contact sheets.
  local Cam, R3, Play, Geo = BallCast.Cam, BallCast.Render, BallCast.Play, BallCast.Geo
  local games = { HARNESS_GAME or "ultra" }
  step(function() App.push(BC, { gameId = games[1], skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  waitFor(function() return not BC:timelinePending() end, 3000)   -- (the whole game, every run)
  local shots = {}           -- park id -> { {label, cam}, ... } to render
  local summary = {}
  step(function()
    local pj = Cam.parksJson()
    local tl = BC.tl
    local origBatSide = Play.batSide
    -- the picks are computed fresh (Cam.bakeOff) and checked against ballcast/camcache.lua
    Cam.bakeOff = true
    local bakeN, bakeStale = 0, 0
    local function checkBake(park, kind, key, v)
      bakeN = bakeN + 1
      local c = BallCast.CamCache and BallCast.CamCache[park.id]
      local b = c and c[kind] and c[kind][key]
      if b == nil or bakeSer(b) ~= bakeSer(v) then
        bakeStale = bakeStale + 1
        if bakeStale <= 5 then print("[camaudit] stale bake: " .. park.id .. " " .. kind .. " " .. tostring(key)) end
      end
    end
    local RP = BallCast.TVReplay
    local G = { tl = tl, meta = BC.meta, live3d = true, fielderId = function() return nil end }
    local total, hidden, junk = 0, 0, 0
    planIssues = {}
    local byCam = {}
    local function note(name, kind)
      local e = byCam[name] or { n = 0, hid = 0, junk = 0 }
      byCam[name] = e
      if kind then e[kind] = e[kind] + 1 else e.n = e.n + 1 end
    end
    for pid, pk in pairs(pj.parks) do
      local park = { id = pid, fences = pk.fences, walls = pk.walls, foulTerritory = pk.foulTerritory }
      Cam.guardBuild(park)
      local bk = Geo.baked(park)
      local r = { park = park, presets = Cam.presets(park, bk.cams) }
      shots[pid] = {}
      junkCache = {}
      -- the game re-planned in this park (fences, walls, foul ground: where the ball lands and
      -- the fielders run depend on them)
      -- (two games: this one and the dev fixture's, back to back in one timeline)
      local tl = BallCast.Timeline.new({ people = BC.meta.people, park = park, home = BC.meta.home, away = BC.meta.away })
      BallCast.Timeline.append(tl, BC.tl.log)
      for _, fx in ipairs({ "fixtures_dev/ballcast/game-log.json", "fixtures_dev/ballcast/game-log-bunts.json" }) do
        -- (+ the Pennant bunts game: sac bunts, squeezes, the bunt angle)
        local dev = BCKit.readJson(fx)
        if dev and dev.log then
          local people = tl.meta.people
          for id, p in pairs(dev.people or {}) do people[id] = people[id] or p end
          BallCast.Timeline.append(tl, dev.log)
        end
      end
      if Play.playCamPrepare then
        for _, sd in ipairs({ 1, -1 }) do checkBake(park, "bunt", sd, Play.playCamPrepare(park, sd)) end
      end
      G.tl = tl
      local printed = 0
      local function audit(name, label, cam, pts, keep)
        cam = Cam.safeEye(park, { cam[1], cam[2], cam[3], cam[4], cam[5], cam[6], cam[7] })
        total = total + 1
        note(name)
        local inF, hid, tag, mat = 0, 0, nil, nil
        if pts and #pts > 0 then inF, hid, tag, mat = Cam.clearOfAction(park, cam, pts) end
        local jkey = string.format("%.0f,%.0f,%.0f,%.0f,%.0f,%.0f,%.1f", cam[1], cam[2], cam[3], cam[4], cam[5], cam[6], cam[7])
        local jc = junkCache[jkey]
        if not jc then jc = { Cam.junkInMiddle(park, cam) }; junkCache[jkey] = jc end
        local jf, jm = jc[1], jc[2]
        if hid > 0 and printed < 4 then
          for _, p in ipairs(pts) do
            local mat, t = Cam.blocked(park, { cam[1], cam[2], cam[3] }, p, 1.5)
            if mat then
              print(string.format("[camaudit]   %s at (%.0f,%.0f,%.0f) hidden by %s at (%.0f,%.0f,%.0f)", p[4], p[1], p[2], p[3], mat,
                cam[1] + (p[1] - cam[1]) * t, cam[2] + (p[2] - cam[2]) * t, cam[3] + (p[3] - cam[3]) * t))
              break
            end
          end
        end
        local bad = false
        if hid > 0 then hidden = hidden + 1; note(name, "hid"); bad = true end
        if jf >= 0.05 then junk = junk + 1; note(name, "junk"); bad = true end
        if bad and printed < 40 then
          printed = printed + 1
          print(string.format("[camaudit] %-9s %-12s %-26s eye (%.0f,%.0f,%.0f) %s%s", pid, name, label, cam[1], cam[2], cam[3],
            hid > 0 and string.format("HIDDEN %d/%d (%s behind %s) ", hid, inF, tag, mat) or "",
            jf >= 0.05 and string.format("JUNK %.0f%% (%s)", jf * 100, jm) or ""))
        end
        if (bad or keep) and #shots[pid] < 10 then shots[pid][#shots[pid] + 1] = { label = name .. " " .. label, cam = cam, bad = bad } end
      end
      local function actionAt(b, tau, bs)
        local plan = b.plan
        local pts = {}
        -- (6 ft of contact: a fielder against the wall is touching it, not hidden behind it)
        local function fig(x, y, tag)
          if not Cam.inField(park, x, y, -2) then
            -- (a player planned off the field, past the fence: a play-planning issue, not the camera's)
            planIssues[tag .. " b" .. b.n] = string.format("(%.0f,%.0f)", x, y)
            return
          end
          pts[#pts + 1] = { x, y, 1, tag, 6 }; pts[#pts + 1] = { x, y, 3.5, tag, 6 }; pts[#pts + 1] = { x, y, 5.5, tag, 6 }
        end
        local bx, by, bz = Play.ballAt(plan, tau)
        -- (the ball counts while it's over the field: not once it's over the seats)
        if bx and bz >= 0 and Cam.inField(park, bx, by, 4) then
          pts[#pts + 1] = { bx, by, math.max(0.3, bz), "ball", 6 }
        end
        if plan.pitch or b.kind == "pa" then
          fig(-bs * 3.2, 0.6, "batter"); fig(0, 59, "pitcher")
          pts[#pts + 1] = { 0, -3.5, 1, "catcher" }; pts[#pts + 1] = { 0, -3.5, 3, "catcher" }
        end
        for _, c in ipairs(plan.catches or {}) do
          if tau > c.t0 - 0.8 and tau < c.ct + c.hold + 0.2 then
            local x, y = Play.fielderAt(plan, c.pos, tau)
            fig(x, y, "fielder " .. c.pos)
          end
        end
        for _, rn in ipairs(plan.runners or {}) do
          if tau >= rn.t0 - 0.2 and tau <= rn.t1 + 0.4 then
            local x, y = Play.runnerPos(rn, tau)
            pts[#pts + 1] = { x, y, 1, "runner" }; pts[#pts + 1] = { x, y, 3.5, "runner" }
            local tx, ty = Play.basePos(rn.target)
            pts[#pts + 1] = { tx, ty, 0.5, "base" }
          end
        end
        return pts
      end
      for _, bs in ipairs({ 1, -1 }) do
        Play.batSide = function() return bs end
        for i, b in ipairs(tl.beats) do
          if bs == 1 or b.plan.pitch or b.kind == "pa" then
            local d = b.dur or 2
            for k = 0, 3 do
              local tau = d * (k + 0.5) / 4
              local cc = Play.camAt(b.plan, tau)
              if cc.name ~= "bleacher" then
                local cam = R3.shot(r, b, tau, cc)
                audit(cc.name .. (cc.opt and cc.opt.establish and "/est" or "") .. (cc.opt and cc.opt.play and ("/" .. cc.opt.play) or ""), "b" .. i .. " t" .. string.format("%.1f", tau) .. " h" .. bs,
                  cam, actionAt(b, tau, bs), cc.name == "blimp" and k == 1 and bs == 1)
              end
            end
          end
        end
        -- the replay angles
        for i, b in ipairs(tl.beats) do
          local tier, kind = RP.worthy(tl, i)
          if tier then
            local sc = RP.script(G, i, kind)
            for _, sh in ipairs(sc and sc.shots or {}) do
              for k = 0, 4 do
                local tau = sh.from + (sh.to - sh.from) * k / 4
                local cam
                if type(sh.cam) == "function" then cam = sh.cam(sh.b, tau)
                elseif type(sh.cam) == "table" and sh.cam.name then cam = R3.shot(r, sh.b, tau, sh.cam)
                elseif type(sh.cam) == "table" then cam = sh.cam end
                if cam then audit("replay " .. kind, "b" .. i .. " t" .. string.format("%.1f", tau) .. " h" .. bs, cam, actionAt(sh.b, tau, bs)) end
              end
            end
          end
        end
      end
      Play.batSide = origBatSide
      for k = 0, 10 do audit("flyover", "k" .. k / 10, BallCast.TV.flyCam(k / 10), nil) end
      -- every blimp and establishing-orbit moment, both sides, over a half-inning and a fly ball
      local half, fly
      for _, b in ipairs(tl.beats) do
        if b.kind == "half" and not half then half = b end
        if b.kind == "bip" and b.plan.catchPos and not fly then fly = b end
      end
      for _, side in ipairs({ 1, -1 }) do
        for tau = 0, 6, 0.5 do
          if half then audit("blimp", "half side" .. side .. " t" .. tau, R3.shot(r, half, tau, { name = "blimp", opt = { side = side } }), nil, tau == 1 and side == 1) end
          if fly then audit("blimp", "fly side" .. side .. " t" .. tau, R3.shot(r, fly, tau, { name = "blimp", opt = { side = side } }), actionAt(fly, tau, 1)) end
          if half and side == 1 then audit("high/est", "half t" .. tau, R3.shot(r, half, tau, { name = "high", opt = { establish = true } }), nil, tau == 1) end
        end
      end
      -- the half-inning changeover's held shots (checked and cached as the loader does)
      for _, top in ipairs({ true, false }) do
        for k = 1, 2 do
          if Play.changeoverPrepare then checkBake(park, "co", (top and 1 or 0) .. "/" .. k, Play.changeoverPrepare(park, top, k)) end
          local e, t, fov = Play.changeoverShot(r, { pre = { top = top } }, 0, k)
          audit("changeover", (top and "top" or "bot") .. " k" .. k, { e[1], e[2], e[3], t[1], t[2], t[3], fov }, Play.changeoverPts(), k == 1 and top)
        end
      end
      -- Pennant's decision angles (vetted at load as the TV loader does), as R3.shot frames them in
      -- each free strip of the screen (full, left of the dugout panel, between the pitch panels)
      if R3.decisionPrepare then
        for _, c in ipairs(R3.decisionCombos()) do
          local pick = R3.decisionPrepare(park, c[1], c[2], c[3])
          checkBake(park, "dec", c[1] .. "/" .. c[2] .. "/" .. (c[1] == "overShoulder" and c[3] or 0), pick)
          if pick then
            for _, strip in ipairs({ { 4, 396 }, { 4, 224 }, { 96, 292 } }) do
              local fakeB = { pre = { bat = nil }, plan = {} }
              local savedBS = Play.batSide
              Play.batSide = function() return c[2] end
              local cam = R3.shot(r, fakeB, 0, { name = "decision", opt = { kind = c[1], side = c[3], step = 0, x0 = strip[1], x1 = strip[2] } })
              Play.batSide = savedBS
              audit("decision", c[1] .. " bs" .. c[2] .. " s" .. c[3] .. " " .. strip[1] .. "-" .. strip[2], cam, R3.decisionPts(c[2]), strip[2] == 396 and c[2] == 1)
            end
          end
        end
      end
      for a = 0, 330, 30 do
        local ar = math.rad(a)
        audit("intro orbit", "a" .. a, Cam.introOrbit and not CAMAUDIT_BEFORE and Cam.introOrbit(park, ar)
          or { math.sin(ar) * 280, -math.cos(ar) * 280 + 60, 110, 0, 170, 10, 50 }, nil)
      end
    end
    for name, e in pairs(byCam) do
      print(string.format("[camaudit] camera %-14s samples %5d  hidden %4d  junk %4d", name, e.n, e.hid, e.junk))
    end
    local np = 0
    for k, v in pairs(planIssues) do np = np + 1; if np <= 10 then print("[camaudit] plan issue: " .. k .. " off the field at " .. v) end end
    print(string.format("[camaudit] %d camera samples, %d with the action hidden, %d with junk in the middle (%d players planned off the field: not counted)", total, hidden, junk, np))
    print(string.format("[camaudit] bake: %d picks checked, %d stale%s", bakeN, bakeStale, bakeStale > 0 and " (run playdate/tools/cambake.sh)" or ""))
    Cam.bakeOff = false
    summary.total, summary.hidden, summary.junk = total, hidden, junk
  end, 2)
  -- render: per park, the blimp sample and the offenders (the park's own geometry uploaded)
  step(function()
    local pj = Cam.parksJson()
    local list = {}
    for pid in pairs(pj.parks) do list[#list + 1] = pid end
    table.sort(list)
    CAMAUDIT_LIST = list
  end, 1)
  for pi = 1, 9 do
    step(function()
      local pid = CAMAUDIT_LIST[pi]
      if not pid then return end
      local bk = Geo.baked({ id = pid })
      Geo.uploadBaked(bk)
      CAMAUDIT_PID = pid
    end, 2)
    for si = 1, 10 do
      step(function()
        local pid = CAMAUDIT_PID
        local s = pid and shots[pid] and shots[pid][si]
        if not s then return end
        BC.mode = "watch"
        local c = s.cam
        bc3d.camera(c[1], c[2], c[3], c[4], c[5], c[6], c[7])
        if bc3d.quality then bc3d.quality(0) end
        bc3d.render(0, 0)
        bc3d.flush(0, 0)
        BallCast.TVArt.drawText("tiny", pid .. "  " .. s.label .. (s.bad and "  [OFFENDER]" or ""), 4, 228, nil, "wo")
        CAMAUDIT_IMG = gfx.getWorkingImage()
      end, 1)
      step(function()
        local pid = CAMAUDIT_PID
        local s = pid and shots[pid] and shots[pid][si]
        if s and CAMAUDIT_IMG then
          playdate.simulator.writeToFile(CAMAUDIT_IMG, OUT .. string.format("camaudit_%s_%02d.png", pid, si))
        end
      end, 1)
    end
  end
  step(function() App.pop() end, 5)
elseif only == "cambake" then
  -- every park's clear-eye picks for the fixed cameras, computed as the loader would, written to
  -- Data/<bundle>/camcache.lua (playdate/tools/cambake.sh copies it to ballcast/camcache.lua)
  local Cam, R3, Play = BallCast.Cam, BallCast.Render, BallCast.Play
  step(function()
    Cam.bakeOff = true
    local ser = bakeSer
    local pj = Cam.parksJson()
    local ids = {}
    for pid in pairs(pj.parks) do ids[#ids + 1] = pid end
    table.sort(ids)
    local out = { "-- GENERATED by playdate/tools/cambake.sh (the devharness \"cambake\" mode); see Cam.baked.",
      "-- Each park's picks for the fixed cameras: co = changeover, bunt = the bunt angle per side,",
      "-- dec = Pennant's decision angles (false: not clear in that park). Re-bake after changing a",
      "-- park's geometry or those cameras (devharness camaudit reports a stale bake).",
      "BallCast = BallCast or {}", "BallCast.CamCache = {" }
    for _, pid in ipairs(ids) do
      local pk = pj.parks[pid]
      local park = { id = pid, fences = pk.fences, walls = pk.walls, foulTerritory = pk.foulTerritory }
      Cam.guardBuild(park)
      out[#out + 1] = string.format("  [%q] = {", pid)
      local co = {}
      for _, top in ipairs({ true, false }) do
        for k = 1, 2 do co[#co + 1] = string.format("[%q] = %s", (top and 1 or 0) .. "/" .. k, ser(Play.changeoverPrepare(park, top, k))) end
      end
      out[#out + 1] = "    co = { " .. table.concat(co, ", ") .. " },"
      local bunt = {}
      for _, sd in ipairs({ 1, -1 }) do bunt[#bunt + 1] = string.format("[%d] = %s", sd, ser(Play.playCamPrepare(park, sd))) end
      out[#out + 1] = "    bunt = { " .. table.concat(bunt, ", ") .. " },"
      out[#out + 1] = "    dec = {"
      for _, c in ipairs(R3.decisionCombos()) do
        local key = c[1] .. "/" .. c[2] .. "/" .. (c[1] == "overShoulder" and c[3] or 0)
        out[#out + 1] = string.format("      [%q] = %s,", key, ser(R3.decisionPrepare(park, c[1], c[2], c[3])))
      end
      out[#out + 1] = "    },"
      out[#out + 1] = "  },"
      Cam.releaseOccluders(park)
      print("[cambake] " .. pid)
    end
    out[#out + 1] = "}"
    local f = playdate.file.open("camcache.lua", playdate.file.kFileWrite)
    f:write(table.concat(out, "\n") .. "\n")
    f:close()
    print("[cambake] wrote " .. #ids .. " parks")
  end, 2)
elseif only == "tvunit" then
  -- DBN art at 3x (digits, K card, radar gun, logo, bug) on one screen
  step(function()
    local A = BallCast.TVArt
    gfx.clear(gfx.kColorWhite)
    for d = 0, 9 do A.digit(d):drawScaled(4 + d * 39, 4, 3) end
    A.logo():draw(4, 80)
    A.bug(false):drawScaled(170, 80, 2)
    A.bug(true):drawScaled(170, 120, 2)
    BallCast.HUD.pitchNo = 47
    BallCast.HUD.pitchBox("SL", 87, 4, 160)
    BallCast.HUD.pitchBox("FB", 101, 140, 160)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillPolygon(table.unpack({ 300, 180, 380, 180, 365, 195, 315, 195 }))
    gfx.fillPolygon(300, 200, 380, 200, 365, 215, 315, 215)
    local img = gfx.image.new(13, 21, gfx.kColorClear)
    gfx.pushContext(img)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillPolygon(2, 0, 10, 0, 7, 3, 5, 3)
    gfx.fillRect(0, 10, 13, 2)
    gfx.popContext()
    img:drawScaled(260, 170, 3)
    TVUNIT = gfx.getWorkingImage()
  end, 2)
  step(function() playdate.simulator.writeToFile(TVUNIT, OUT .. "tvunit.png") end, 2)
elseif only == "loadprof" then
  -- relative costs of the load stages (Simulator; device is ~50-150x slower for Lua)
  step(function()
    local function t() return playdate.getElapsedTime() * 1000 end
    local data = BCKit.readJson("fixtures_dev/ballcast/game-log.json")
    local t0 = t()
    for i = 1, 5 do json.decodeFile("images/parks/parks-geo.json") end
    print("[prof] decode parks-geo x5", t() - t0); t0 = t()
    for i = 1, 5 do json.decodeFile("images/parks/parks.json") end
    print("[prof] decode parks.json x5", t() - t0); t0 = t()
    for i = 1, 5 do json.decodeFile("fixtures/game-log.json") end
    print("[prof] decode game-log (objects) x5", t() - t0); t0 = t()
    local c
    for i = 1, 5 do c = json.decodeFile("fixtures/game-logc.json") end
    print("[prof] decode game-logc (one string) x5", t() - t0); t0 = t()
    for i = 1, 5 do
      local pos, n = 1, 0
      while pos <= #c.logc do local _; _, pos = BallCast.Timeline.decodeC(c.logc, pos); n = n + 1 end
    end
    print("[prof] parse all compact events x5", t() - t0); t0 = t()
    for i = 1, 5 do json.decodeFile("fixtures/game.json") end
    print("[prof] decode game.json x5", t() - t0); t0 = t()
    for i = 1, 5 do json.decodeFile("fixtures/game-lite.json") end
    print("[prof] decode game-lite x5", t() - t0); t0 = t()
    -- round trip: compact events == object events
    local o = json.decodeFile("fixtures/game-log.json")
    local pos, i, bad = 1, 0, 0
    while pos <= #c.logc do
      local e
      e, pos = BallCast.Timeline.decodeC(c.logc, pos)
      i = i + 1
      local r = o.log[i]
      for k, v in pairs(r) do
        local w = e[k]
        if type(v) == "table" then
          if type(w) ~= "table" or #w ~= #v then bad = bad + 1 else for j = 1, #v do if v[j] ~= w[j] then bad = bad + 1 break end end end
        elseif v ~= w then bad = bad + 1; if bad < 5 then print("[prof] mismatch", i, k, tostring(v), tostring(w)) end end
      end
    end
    print("[prof] compact round trip: events", i, "of", #o.log, "mismatches", bad); t0 = t()
    local P = BallCast.Play
    local planT, n = 0, 0
    local orig = P.plan
    P.plan = function(b, tl) local a = t(); local r = orig(b, tl); planT = planT + t() - a; n = n + 1; return r end
    t0 = t()
    for i = 1, 5 do
      local tl = BallCast.Timeline.new({ people = data.people, park = data.park })
      BallCast.Timeline.append(tl, data.log)
    end
    print("[prof] TL.append x5", t() - t0, "of which plan", planT, "calls", n)
    P.plan = orig
    t0 = t()
    for i = 1, 5 do BallCast.Geo.build(data.park) end
    print("[prof] Geo.build x5", t() - t0); t0 = t()
    local g = BallCast.Geo.build(data.park)
    for i = 1, 5 do BallCast.Geo.upload(g) end
    print("[prof] Geo.upload x5", t() - t0); t0 = t()
    for i = 1, 5 do BallCast.Cam.presets(data.park) end
    print("[prof] presets x5", t() - t0)
  end, 5)
elseif only == "smoothcam" then
  -- Camera smoothness + the pitching lane, over many pitches of a game at a fixed 1/30 s clock:
  --  (a) within a shot, the second difference of where fixed field points land on screen
  --      (px/frame^2: a stepping or snapping camera spikes it; a smooth move stays small)
  --  (b) no puppet stands in the mound-to-plate lane (|x| < LANE_X, LANE_Y0 < y < LANE_Y1) from
  --      the start of the pitch beat until the ball reaches the catcher
  --  (c) Pennant-style decision idle (a held clock, the decision angles): same metric, plus how
  --      many cuts it makes
  -- Prints [smoothcam] lines; HARNESS_SHOTS=n saves frame strips of the first n pitches.
  local Cam = BallCast.Cam
  local LANE_X, LANE_Y0, LANE_Y1 = table.unpack(BallCast.Play.LANE)
  local PTS = { { 0, 0, 0 }, { 0, 60.5, 0 }, { 0, 127.3, 0 }, { 63.6, 63.6, 0 }, { -63.6, 63.6, 0 }, { 0, 0, 6 } }
  local NP = tonumber(HARNESS_NP) or 60
  local stripN = tonumber(HARNESS_SHOTS) or 3
  step(function() App.push(BC, { gameId = HARNESS_GAME or "g1", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" and not BC:timelinePending() end, 1800)
  local pitches, st = {}, nil
  local function newStats() return { frames = 0, worst = 0, worstAt = "", sum = 0, n = 0, over = 0, lane = 0, laneWho = {}, cuts = 0, secs = 0, hist = {} } end
  local stats, bstats, dstats, pstats, pbstats, dbstats = newStats(), newStats(), newStats(), newStats(), newStats(), newStats()
  local function report(name, S)
    print(string.format("[smoothcam] %s: %d frames, %d cuts, 2nd-diff px/frame^2 max %.2f mean %.3f, frames > 1 px: %d (worst: %s)",
      name, S.frames, S.cuts, S.worst, S.sum / math.max(1, S.n), S.over, S.worstAt))
  end
  local function screen(c)
    local cam = Cam.new({ eye = { c[1], c[2], c[3] }, target = { c[4], c[5], c[6] }, fov = c[7] })
    local out = {}
    for i, p in ipairs(PTS) do
      local x, y = Cam.project(cam, p[1], p[2], p[3])
      if x and x > -400 and x < 800 and y > -300 and y < 540 then out[i] = { x, y } end
    end
    return out
  end
  local spikes = 0
  local function measure(S, tag, cut, which)
    -- S: the stats table; the camera actually sent to the renderer this frame (which = "bg":
    -- the one the park picture on screen was rendered from: the park-render cache reuses one)
    local c = BC.R and (which == "bg" and BC.R.bgCam or BC.R.cam)
    if not c then return end
    local sp = screen(c)
    local hist = S.hist
    if cut then hist = {}; S.cuts = S.cuts + 1 end
    hist[#hist + 1] = sp
    if #hist > 3 then table.remove(hist, 1) end
    S.hist = hist
    S.frames = S.frames + 1
    if #hist == 3 then
      local a, b2, c2 = hist[1], hist[2], hist[3]
      local m = 0
      for i = 1, #PTS do
        if a[i] and b2[i] and c2[i] then
          local dx = c2[i][1] - 2 * b2[i][1] + a[i][1]
          local dy = c2[i][2] - 2 * b2[i][2] + a[i][2]
          m = math.max(m, math.sqrt(dx * dx + dy * dy))
        end
      end
      S.sum, S.n = S.sum + m, S.n + 1
      if m > 1 then S.over = S.over + 1 end
      if m > S.worst then S.worst, S.worstAt = m, tag end
      if m > 8 and which ~= "bg" then
        spikes = spikes + 1
        if spikes <= 25 then print(string.format("[smoothcam] spike %.1f px at %s", m, tag)) end
      end
    end
  end
  -- the puppets drawn this frame
  local drawn = {}
  local function wrap(R)
    if R.smoothWrapped then return end
    R.smoothWrapped = true
    local mt = getmetatable(R).__index
    local P0, PT = mt.puppet, mt.puppetT
    R.puppet = function(self, variant, frame, x, y, z, ...)
      drawn[#drawn + 1] = { tostring(variant) .. ":" .. tostring(frame), x, y }
      return P0(self, variant, frame, x, y, z, ...)
    end
    R.puppetT = function(self, variant, tname, f, x, y, z, ...)
      drawn[#drawn + 1] = { tostring(variant) .. ":" .. tostring(tname), x, y }
      return PT(self, variant, tname, f, x, y, z, ...)
    end
  end
  step(function()
    BallCast.TV.frame = function() return false end   -- (no DBN segments: the game picture only)
    BC.debugDt = 1 / 30
    wrap(BC.R)
    local all = {}
    for i, b in ipairs(BC.tl.beats) do if b.kind == "p" and b.plan and b.plan.pitch then all[#all + 1] = i end end
    local stride = math.max(1, math.floor(#all / NP))
    for k = 1, #all, stride do pitches[#pitches + 1] = all[k] end
    print(string.format("[smoothcam] %d pitches in the game, sampling %d", #all, #pitches))
  end)
  local pi, phase, f = 0, "next", 0
  waitFor(function()
    local tl = BC.tl
    if phase == "next" then
      pi = pi + 1
      if pi > #pitches then return true end
      local b = tl.beats[pitches[pi]]
      -- from a second before the beat (the cut in), at 1x
      BC.t = b.start - 1.0
      BC.lastBeat = nil
      BC.playing, BC.speed, BC.scrubT = true, 1, 0
      phase, f = "run", 0
      stats.hist, bstats.hist, pstats.hist, pbstats.hist = {}, {}, {}, {}
      drawn = {}
      return false
    end
    f = f + 1
    local bi = BC:curBeatIndex()
    local b = tl.beats[pitches[pi]]
    local tau = BC.t - b.start
    if f > 1 then
      local tag = string.format("pitch %d beat %d tau %.2f cam %s", pi, pitches[pi], tau, tostring(BC.curCam))
      if bi == pitches[pi] then
        measure(stats, tag, BC.cutThisFrame)
        measure(bstats, tag, BC.cutThisFrame, "bg")
      else
        -- the beat after the pitch (the ball in play, the walk, the next batter)
        measure(pstats, tag, BC.cutThisFrame)
        measure(pbstats, tag, BC.cutThisFrame, "bg")
      end
    end
    if bi == pitches[pi] and tau >= 0 and tau <= b.plan.pitch.tPlate + 0.06 then
      for _, d in ipairs(drawn) do
        if math.abs(d[2]) < LANE_X and d[3] > LANE_Y0 and d[3] < LANE_Y1 then
          stats.lane = stats.lane + 1
          local key = d[1]
          stats.laneWho[key] = (stats.laneWho[key] or 0) + 1
          if stats.lane <= 12 then print(string.format("[smoothcam] LANE beat %d tau %.2f %s at %.1f, %.1f", pitches[pi], tau, d[1], d[2], d[3])) end
        end
      end
    end
    drawn = {}
    if pi <= stripN and f % 3 == 0 and BC.t < b.start + b.plan.pitch.tPlate + 0.5 then shot(string.format("smoothcam_p%d_%03d", pi, f)) end
    local nb = tl.beats[pitches[pi] + 1]
    if bi > pitches[pi] + 1 or (nb and BC.t > nb.start + math.min(nb.dur, 8)) or (not nb and tau > b.dur) then phase = "next" end
    return false
  end, 60 * 400)
  step(function()
    report("pitch camera", stats)
    report("pitch park picture", bstats)
    report("next beat camera", pstats)
    report("next beat park picture", pbstats)
    local who = {}
    for k, v in pairs(stats.laneWho) do who[#who + 1] = k .. "=" .. v end
    print(string.format("[smoothcam] lane: %d puppet-frames in the lane during pitches (%s)", stats.lane, table.concat(who, " ")))
  end)
  -- (c) the decision idle: a held clock at a pitch, as Pennant does while the player aims
  local fake = {
    idleDecision = function() return true end,
    frame = function() return 0 end,
    decisionFrame = function() return 96, 292 end,
  }
  local di, dphase, df = 0, "next", 0
  waitFor(function()
    if dphase == "next" then
      di = di + 1
      if di > 4 then return true end
      local b = BC.tl.beats[pitches[di * 3]]
      BC.t = b.start
      BC.lastBeat = nil
      BC.playing, BC.speed, BC.scrubT = true, 1, 0
      BC.src = fake
      BC.idleT, BC.decision = nil, nil
      dphase, df = "run", 0
      dstats.hist, dbstats.hist = {}, {}
      return false
    end
    df = df + 1
    if BC.idleFrame == nil or BC.idleFrame % 2 == 0 then
      measure(dstats, string.format("decision %d idle %.2f", di, BC.idleT or 0), BC.cutThisFrame)
      measure(dbstats, string.format("decision %d idle %.2f", di, BC.idleT or 0), BC.cutThisFrame, "bg")
    end
    if di == 1 and df % 6 == 0 and df <= 300 then shot(string.format("smoothcam_dec_%03d", df)) end
    if df >= 30 * 12 then
      dstats.secs = dstats.secs + 12
      BC.src = nil
      dphase = "next"
    end
    return false
  end, 30 * 12 * 5 + 50)
  step(function()
    BC.src = nil
    report(string.format("decision idle (%d s) camera", dstats.secs), dstats)
    report("decision idle park picture", dbstats)
    BC.debugDt = nil
    App.pop()
  end, 5)
elseif only == "jersey" then
  -- jersey numbers wherever a back can face a lens: pitcher from behind through the delivery,
  -- the batter, the side / dugout / runner cams, catches, the DP pivot, runners (slides and
  -- dives: tvcatch has those at their play cams). Prints [jersey] per shot: numbers stamped and their stamp time.
  -- (HARNESS_AWAYSTYLE: the away number's style, bc3d lookStats arg 3)
  step(function()
    if HARNESS_AWAYSTYLE and bc3d.lookStats then bc3d.lookStats(nil, nil, HARNESS_AWAYSTYLE) end
    App.push(BC, { gameId = HARNESS_GAME or "ultra", skipIntro = true })
  end)
  waitFor(function() return BC.mode == "watch" end, 900)
  local function at(name, pred, tau)
    step(seek(pred, tau), 6)
    step(function() if bc3d.lookStats then bc3d.lookStats() end end, 4)
    step(function()
      local px, nj, ms = 0, 0, 0
      if bc3d.lookStats then px, nj, ms = bc3d.lookStats() end
      print(string.format("[jersey] %-28s stampPx/f %5d numbers/f %.1f numberMs/f %.3f", name, (px or 0) // 4, (nj or 0) / 4, (ms or 0) / 4))
      shot("jersey_" .. name)
    end)
  end
  local function pitchB(min) return function(b) return b.kind == "p" and b.n > (min or 30) and b.plan.cams[1].name == "pitch" end end
  for _, tau in ipairs({ 0.0, 0.35, 0.6, 0.85, 1.2 }) do at(string.format("pitch_t%.2f", tau), pitchB(30), tau) end
  for _, n in ipairs({ 80, 130, 200 }) do
    for _, tau in ipairs({ 0.0, 0.6, 1.2 }) do at(string.format("pitch%d_t%.2f", n, tau), pitchB(n), tau) end
  end
  local function catchT(k, d) return function(b) local c = b.plan.catches[k]; return c and (c.ct + (d or 0.04)) or 1 end end
  local function bipOut(o) return function(b) return b.kind == "bip" and b.e.res == "OUT" and b.e.out == o and b.n > 30 end end
  at("grounder_scoop", bipOut("GO"), catchT(1))
  at("grounder_1b", bipOut("GO"), catchT(2))
  at("fly_caught", bipOut("FO"), catchT(1))
  at("dp_pivot", function(b) return b.kind == "bip" and b.e.res == "DP" end, catchT(2))
  at("single_runners", function(b) return b.kind == "bip" and b.e.res == "1B" and b.n > 30 end, function(b) return b.dur - 2.2 end)
  at("double_runners", function(b) return b.kind == "bip" and b.e.res == "2B" end, function(b) return b.dur - 1.5 end)
  at("hr_trot", function(b) return b.kind == "bip" and b.e.res == "HR" end, function(b) return b.plan.wallT + 2.5 end)
  -- closeups: the beat's own camera at that moment, narrowed (fov / z) onto a man (aim: world
  -- point, or nil = the shot's own target), held as a "decision" cam for the frame
  local Play, R3 = BallCast.Play, BallCast.Render
  local function zoomAt(name, pred, tau, z, aim)
    local b, saved, t
    step(function()
      b = nil
      for _, x in ipairs(BC.tl.beats) do if pred(x) then b = x; break end end
      if not b then return end
      t = type(tau) == "function" and tau(b) or tau
      local c = R3.shot(BC.R, b, t, Play.camAt(b.plan, t), {})
      local a = aim and aim(b, t) or { c[4], c[5], c[6] }
      local f = c[7] / z
      saved = b.plan.cams
      b.plan.cams = { { name = "decision", t = -10, opt = { cam = { c[1], c[2], c[3], a[1], a[2], a[3], f, f } } } }
    end, 1)
    at(name, function(x) return x == b end, function() return t or 0 end)
    step(function() if b and saved then b.plan.cams = saved end end, 1)
  end
  local function pitcherAim() return { 0, 60.5, 4.2 } end
  local function batterAim(b) return { -Play.batSide(b.pre.bat) * 3.2, 0.6, 4.0 } end
  for _, n in ipairs({ 30, 200 }) do
    for _, tau in ipairs({ 0.0, 0.5, 0.9 }) do
      for _, z in ipairs({ 2, 4 }) do zoomAt(string.format("zpitcher%d_t%.1f_z%d", n, tau, z), pitchB(n), tau, z, pitcherAim) end
    end
  end
  local function hasCam(cn) return function(b) for _, c in ipairs(b.plan.cams) do if c.name == cn then return c end end end end
  for _, d in ipairs({ 0.2, 0.6, 1.0 }) do
    zoomAt(string.format("zbatter_%.1f", d), hasCam("behindPlate"), function(b) return hasCam("behindPlate")(b).t + d end, 3, batterAim)
    zoomAt(string.format("zrunner_%.1f", d), hasCam("runner"), function(b) return hasCam("runner")(b).t + d end, 2.5)
    zoomAt(string.format("zbatside_%.1f", d), hasCam("batterSide"), function(b) return hasCam("batterSide")(b).t + d end, 2.5, batterAim)
  end
  for _, cn in ipairs({ "behindPlate", "pitcherSide", "batterSide", "dugout", "runner", "wallLow", "deepC", "high" }) do
    local function has(b) for _, c in ipairs(b.plan.cams) do if c.name == cn then return c end end end
    for _, d in ipairs({ 0.3, 0.9 }) do
      at(string.format("cam_%s_%.1f", cn, d), function(b) return has(b) ~= nil end, function(b) return has(b).t + d end)
    end
  end
  step(function() App.pop() end, 5)
elseif only == "fix" then
  -- catches, receivers, nametags, ball flight, camera variety, HUD cards, game log, crowd pops
  step(function() App.push(BC, { gameId = HARNESS_GAME or "g1", skipIntro = true }) end)
  waitFor(function() return BC.mode == "watch" end, 900)
  local function at(name, pred, tau)
    step(seek(pred, tau), 8)
    step(function() shot(name) end)
  end
  local function catchT(k, d) return function(b) local c = b.plan.catches[k]; return c and (c.ct + (d or 0.04)) or 1 end end
  local function bipOut(o) return function(b) return b.kind == "bip" and b.e.res == "OUT" and b.e.out == o and b.n > 30 end end
  at("fix_grounder_scoop", bipOut("GO"), catchT(1))
  at("fix_grounder_1b_takes_throw", bipOut("GO"), catchT(2))
  at("fix_grounder_throw_inflight", bipOut("GO"), catchT(2, -0.25))
  at("fix_fly_arriving", bipOut("FO"), catchT(1, -0.25))
  at("fix_fly_caught", bipOut("FO"), catchT(1))
  at("fix_liner_caught", bipOut("LO"), catchT(1))
  at("fix_dp_pivot", function(b) return b.kind == "bip" and b.e.res == "DP" end, catchT(2))
  at("fix_dp_first", function(b) return b.kind == "bip" and b.e.res == "DP" end, catchT(3))
  at("fix_hr_flight", function(b) return b.kind == "bip" and b.e.res == "HR" end, function(b) return b.plan.wallT - 1.2 end)
  at("fix_hr_flight2", function(b) return b.kind == "bip" and b.e.res == "HR" end, function(b) return b.plan.wallT - 0.4 end)
  at("fix_double_flight", function(b) return b.kind == "bip" and b.e.res == "2B" end, 1.2)
  at("fix_single_runners", function(b) return b.kind == "bip" and b.e.res == "1B" and b.n > 30 end, function(b) return b.dur - 2.2 end)
  at("fix_pitch_tags", function(b) return b.kind == "p" and b.n > 40 and b.plan.cams[1].name == "pitch" and b.pre.b + b.pre.s > 0 end, 0.6)
  at("fix_lower_third", function(b) return b.kind == "pa" and b.n > 30 and b.plan.cams[1].name == "pitch" end, 1.2)
  for _, cn in ipairs({ "behindPlate", "pitcherSide", "batterSide", "dugout", "blimp", "wallLow", "runner" }) do
    local function has(b) for _, c in ipairs(b.plan.cams) do if c.name == cn then return c end end end
    at("fix_cam_" .. cn, function(b) return has(b) ~= nil end, function(b) return has(b).t + 0.7 end)
  end
  at("fix_bat_toss", function(b) return b.kind == "bip" and b.plan.cams[1].name == "high" and b.n > 20 end, 0.42)
  at("fix_bat_toss2", function(b) return b.kind == "bip" and b.plan.cams[1].name == "high" and b.n > 20 end, 0.62)
  at("fix_bat_down", function(b) return b.kind == "bip" and b.plan.cams[1].name == "high" and b.n > 20 end, 1.3)
  at("fix_runner_spin", function(b) return b.kind == "bip" and b.e.res ~= "HR" and BallCast.Play.findSpin(b) ~= nil end, function(b) return BallCast.Play.findSpin(b) end)
  at("fix_bleacher_shout", function(b) return b.kind == "bip" and b.e.res == "HR" end, function(b) return b.plan.wallT + 2.0 end)
  step(seek(function(b) return b.kind == "half" and b.e.inn == 6 end, 0.5), 8)
  step(function() BC:openLog() end, 6)
  step(function() shot("fix_gamelog") end)
  step(function() for i = 1, 6 do BallCast.GameLog.move(-1) end end, 4)
  step(function() shot("fix_gamelog_scrolled") end)
  step(function() BC:closeLog(BallCast.GameLog.pick()) end, 10)
  step(function() BC.playing = false; shot("fix_gamelog_jumped") end)
  step(function()
    BC:debugSeek(function(b) return b.kind == "p" and b.n > 50 end, 0)
    BC.playing = true
    BC.scrubT = 0
    timingTag = "pitch"
  end, 90)
  step(function()
    BC:debugSeek(function(b) return b.kind == "bip" and b.e.res == "HR" end, 0)
    timingTag = "hr"
  end, 150)
  step(function() timingTag = nil; App.pop() end, 5)
elseif only ~= "cards" and not HARNESS_PERF then
step(function() App.push(BC, { gameId = GAME, debug = true }) end)
waitFor(function() return BC.mode == "intro" end)
step(function() end, 10)
step(function()
  -- timeline sanity: 3 outs before every half change, runs match the final
  local tl = BC.tl
  local bad = 0
  for i, b in ipairs(tl.beats) do
    if b.kind == "half" and i > 1 and tl.beats[i - 1].post.outs ~= 3 and not (b.e.inn == 1 and b.e.top) then
      bad = bad + 1
      if bad < 4 then print("[harness] outs mismatch before beat", i, "outs", tl.beats[i - 1].post.outs, "inn", b.e.inn) end
    end
    if b.kind == "end" then
      print("[harness] final", b.e.away, b.e.home, "tracked", b.pre.away, b.pre.home)
    end
  end
  print("[harness] timeline beats", #tl.beats, "total", math.floor(tl.total), "s, half mismatches", bad)
  shot("ballcast_intro")
  if bc3d then
    print("[harness] stats", bc3d.stats())
    print("[harness] project home", bc3d.project(0, 0, 0))
    print("[harness] project cf", bc3d.project(0, 300, 0))
    for i = 0, 6 do print("[harness] poly", i, bc3d.debugPoly(i)) end
    for i = 1, 4 do print("[harness] mat", i, bc3d.debugMat(i)) end
  end
end)
step(seek(function(b) return b.kind == "pa" and b.n > 20 end, 1.0), 8)
step(function() shot("ballcast_atbat") end)
step(seek(function(b) return b.kind == "p" and b.e.r == "C" and b.n > 20 end, function(b) return b.plan.pitch.tPlate - 0.15 end), 8)
step(function() shot("ballcast_pitchcam") end)
step(seek(function(b) return b.kind == "p" and b.e.r ~= "X" and b.n > 30 end, function(b) return b.plan.pitch.tPlate + 0.5 end), 8)
step(function() shot("ballcast_pitchcam_result") end)
step(seek(firstHR, function(b) return b.plan.wallT - 0.6 end), 8)
step(function() shot("ballcast_hr_flight") end)
step(seek(firstHR, function(b) return b.plan.wallT + 0.5 end), 8)
step(function() shot("ballcast_hr_banner") end)
step(seek(firstHR, function(b) return b.plan.wallT + 2.0 end), 8)
step(function() shot("ballcast_hr_bleachers") end)
step(seek(function(b) return b.kind == "bip" and b.e.out == "FO" end, function(b) return b.dur * 0.35 end), 8)
step(function() shot("ballcast_flyball") end)
step(seek(function(b) return b.kind == "bip" and b.e.res == "2B" end, function(b) return b.dur - 2.0 end), 8)
step(function() shot("ballcast_double_runners") end)
step(seek(function(b) return b.kind == "bip" and b.e.out == "GO" and b.n > 40 end, 0.6), 8)
step(function()
  shot("ballcast_grounder")
  local b = BC.tl.beats[BC:curBeatIndex()]
  print("[harness] grounder beat", b.kind, b.e.res, b.e.out, "cam", table.concat(BC.camCur or {}, ","), "shot", BC.camShot and BC.camShot.name)
  print("[harness] ball", BallCast.Play.ballAt(b.plan, BC.t - b.start))
end)
step(seek(function(b) return b.kind == "bip" and b.e.res == "DP" end, function(b) return b.plan.slo and (b.plan.slo[1] + 0.2) or 1.5 end), 8)
step(function()
  shot("ballcast_doubleplay")
  local b = BC.tl.beats[BC:curBeatIndex()]
  local tau = BC.t - b.start
  for _, pos in ipairs(BallCast.Play.POSLIST) do
    local x, y = BallCast.Play.fielderAt(b.plan, pos, tau)
    print("[harness] fielder", pos, x, y, bc3d.project(x, y, 0))
  end
end)
step(seek(function(b) return b.kind == "inc" and b.e.kind == "RACCOON_ON_FIELD" end, 1.2), 8)
step(function() shot("ballcast_raccoon") end)
step(seek(function(b) return b.kind == "inc" and b.e.kind == "BRAWL" end, 1.6), 8)
step(function() shot("ballcast_brawl") end)
step(seek(function(b) return b.kind == "inc" and b.e.kind == "FAN_ON_FIELD" end, 3.4), 8)
step(function() shot("ballcast_bleachers_fan") end)
step(seek(function(b) return b.kind == "half" and b.e.inn == 7 end, 1.4), 8)
step(function() shot("ballcast_inning") end)
step(seek(function(b) return b.kind == "end" end, 3.0), 8)
step(function() shot("ballcast_final") end)
-- performance: play 4 seconds of each kind of beat at 1x and time update()
step(function()
  BC:debugSeek(firstHR, 0)
  BC.playing = true
  BC.scrubT = 0
  timingTag = "hr"
end, 120)
step(function()
  BC:debugSeek(function(b) return b.kind == "p" and b.n > 50 end, 0)
  timingTag = "pitch"
end, 90)
step(function() timingTag = nil; App.pop() end, 5)
end

-- Cards ----------------------------------------------------------------------
if Cards and Cards.debugScript and only ~= "ballcast" and only ~= "anim" and only ~= "fix" and not (only or ""):match("^tv") and only ~= "camaudit" and only ~= "catchaudit" and only ~= "catchsheet" and only ~= "cambake" and only ~= "smoothcam" then
  Cards.debugScript(step, waitFor, shot)
end

step(function()
  for tag, t in pairs(timings) do
    table.sort(t)
    local sum = 0
    for _, v in ipairs(t) do sum = sum + v end
    print(string.format("[harness] %s: frames %d avg %.1f ms p90 %.1f ms max %.1f ms", tag, #t, sum / #t, t[math.floor(#t * 0.9)] or 0, t[#t]))
  end
  print("[harness] done")
  if playdate.simulator and not HARNESS_STAY then playdate.simulator.exit() end
end, 2)

local lastFrameT = nil
function playdate.update()
  frame = frame + 1
  if HARNESS_PERF then
    local now = playdate.getElapsedTime()
    if lastFrameT and timingTag then
      local tag = "interval"
      timings[tag] = timings[tag] or {}
      table.insert(timings[tag], (now - lastFrameT) * 1000)
    end
    lastFrameT = now
  end
  if frame % 30 == 0 then print("[harness] frame " .. frame .. " step " .. stepI .. " mode " .. tostring(BC.mode) .. " msg " .. tostring(BC.loadMsg)) end
  local t0 = playdate.getElapsedTime() * 1000
  gfx.clear(gfx.kColorWhite)
  local ok, err = true, nil
  if #App.stack > 0 then ok, err = xpcall(App.draw, debug.traceback) end
  if not ok then
    print("[harness] ERROR " .. tostring(err))
    if playdate.simulator and not HARNESS_STAY then playdate.simulator.exit() end
    return
  end
  local ok2, err2 = xpcall(playdate.timer.updateTimers, debug.traceback)
  if not ok2 then
    print("[harness] TIMER ERROR " .. tostring(err2))
    if playdate.simulator then playdate.simulator.exit() end
    return
  end
  playdate.frameTimer.updateTimers()
  local dt = playdate.getElapsedTime() * 1000 - t0
  if timingTag then
    local tag = timingTag .. (HARNESS_PERF and ("/" .. tostring(BC.camShot and BC.camShot.name or BC.curCam)) or "")
    timings[tag] = timings[tag] or {}
    table.insert(timings[tag], dt)
    timings[timingTag] = timings[timingTag] or {}
    table.insert(timings[timingTag], dt)
  end
  if HARNESS_PERF then
    playdate.drawFPS(380, 2)
    if timingTag and frame % 150 == 0 then
      local t = timings[timingTag] or {}
      local iv = timings.interval or {}
      local function win(a)
        local n, sum, mx = 0, 0, 0
        for i = math.max(1, #a - 149), #a do n = n + 1; sum = sum + a[i]; if a[i] > mx then mx = a[i] end end
        return n > 0 and sum / n or 0, mx
      end
      local ua, um = win(t)
      local ia, im = win(iv)
      local rms, fms = 0, 0
      if bc3d then local _, _, _, _, a, b = bc3d.stats(); rms, fms = a or 0, b or 0 end
      print(string.format("[perf] f%d shot=%s update avg %.1f max %.1f ms | interval avg %.1f max %.1f (%.1f fps) | C render %.1f flush %.1f | world(lua+flush) %.1f hud %.1f",
        frame, tostring(BC.camShot and BC.camShot.name), ua, um, ia, im, ia > 0 and 1000 / ia or 0, rms, fms, BC.profWorld or 0, BC.profHud or 0))
    end
  end
  local s = steps[stepI]
  if not s then return end
  if s.pred then
    if s.pred() or frame >= waitUntil + s.wait then
      if frame >= waitUntil + s.wait then print("[harness] wait timed out at step " .. stepI) end
      stepI = stepI + 1
      waitUntil = frame
    end
    return
  end
  if frame >= waitUntil then
    local ok, e = pcall(s.fn)
    if not ok then print("[harness] step " .. stepI .. " failed: " .. tostring(e)) end
    stepI = stepI + 1
    waitUntil = frame + s.wait
  end
end
