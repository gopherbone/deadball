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
if Cards and Cards.debugScript and only ~= "ballcast" and only ~= "anim" and only ~= "fix" and not (only or ""):match("^tv") and only ~= "camaudit" and only ~= "cambake" then
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
