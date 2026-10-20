-- DBN: the BallCast broadcast package ("Deadball Broadcast Network", 1996).
--
-- A presentation layer over the replay scene. Two kinds of things:
--   overlays  drawn over live play every frame, never hold the clock (bug, K-zone + pitch
--             tracker, radar gun, power dossier, K card; HUD.lua does the lower thirds and the
--             big-moment banners)
--   segments  hold the replay clock and own the whole frame for a few seconds: the cold open
--             (network ident, stadium flyover, matchup, lineups), INSTANT REPLAY with the
--             telestrator, between-inning cards (linescore, due up, did you know, the stretch,
--             commercials), the SPECIAL REPORT bulletin, and the postgame (final, player of the
--             game, sign-off)
--
-- Segments start only on natural forward playback (1x; 2x gets tier-1 replays and bulletins)
-- at a beat boundary, each at most once per beat. Any button skips (the scene calls
-- TV.interrupt()); the crank skips and scrubs. Game.settings.reduceMotion turns flashes,
-- shakes and spins into dissolves.
--
-- Scene hooks (ballcast/scene.lua): TV.reset/TV.release (enter/exit), TV.prepare (loader),
-- TV.holding() (clock), TV.frame() (before the world is drawn; true = TV drew the frame),
-- TV.overlay() (after the HUD), TV.interrupt() (input).

import "ballcast/kit"
import "ballcast/hud"
import "ballcast/audio"
import "ballcast/tv/art"
import "ballcast/tv/fx"
import "ballcast/tv/stats"
import "ballcast/tv/cards"
import "ballcast/tv/replay"
import "ballcast/tv/overlay"
import "ballcast/tv/warmup"
import "ballcast/tv/pip"
import "ballcast/tv/spin"
import "ballcast/tv/calls"

local gfx <const> = playdate.graphics
local floor <const>, sin <const>, cos <const>, min <const>, max <const>, abs <const> = math.floor, math.sin, math.cos, math.min, math.max, math.abs
local pi <const> = math.pi

BallCast = BallCast or {}
local TV = {}
BallCast.TV = TV
local K = BCKit
local A = BallCast.TVArt
local FX = BallCast.TVFX
local St = BallCast.TVStats
local Cards = BallCast.TVCards
local RP = BallCast.TVReplay
local O = BallCast.TVOverlay
local PiP = BallCast.TVPiP
local Spin = BallCast.TVSpin
local Calls = BallCast.TVCalls
local HUD = BallCast.HUD
local Audio = BallCast.Audio

local WIPE <const> = 0.42       -- card-to-card transition: 0.18 s cover + 0.24 s reveal
local WIPE_IN <const> = 0.18
local OUTRO <const> = 0.3

local G            -- game context (meta, tl, lineups, crawl, ...)
local seg          -- the running segment, or nil
local outro        -- { kind, t } uncover wipe drawn over the scene after a segment
local lastBi, lastTau
local seen = {}    -- beat index -> true once something fired there
local wipeN = 0
local prepUpcoming, runSoon   -- (defined with the lower-third helpers below)
TV.debugClock = nil   -- harness: a fixed segment-time step per frame (deterministic shots)

---------------------------------------------------------------------------
-- settings

-- (TV graphics are always on: there is no lite mode; a saved Game.settings.tvGraphics from an
-- older build is ignored)
local function settings() return (Game and Game.settings) or nil end
function TV.mode() return "full" end
local function reduce() local s = settings(); return s and s.reduceMotion or false end

local function sfx(kind, v) if not G or not G.quietFn or not G.quietFn() then Audio.sfx(kind, v) end end

---------------------------------------------------------------------------
-- game context

local function fielderId(b, pos)
  local people = G.meta.people or {}
  local pit = b.pre and b.pre.pit and people[b.pre.pit]
  if pos == "P" then return b.pre.pit end
  local team = pit and pit.teamAbbr
  if not team then return nil end
  if not G.posIdx then
    G.posIdx = {}
    for id, q in pairs(people) do if q.teamAbbr and q.pos then G.posIdx[q.teamAbbr .. ":" .. q.pos] = id end end
  end
  return G.posIdx[team .. ":" .. pos]
end

local function context(scene)
  if G and G.scene == scene and G.tl == scene.tl then return G end
  G = { scene = scene, meta = scene.meta, tl = scene.tl, live3d = scene.live3d, lineups = { away = {}, home = {}, sp = {} } }
  G.fielderId = fielderId
  G.quietFn = function() return scene.speed > 2 or not scene.playing end
  return G
end

local function curPitchers(tl, bi)
  local out = {}
  for i = min(bi, #tl.beats), 1, -1 do
    local b = tl.beats[i]
    if b.kind == "p" and b.pre.pit then
      local side = b.pre.top and "home" or "away"
      out[side] = out[side] or b.pre.pit
      if out.home and out.away then break end
    end
  end
  return out
end

---------------------------------------------------------------------------
-- loader: everything that would otherwise touch the disk mid-replay

function TV.prepare(scene, step)
  local g = context(scene)
  local m = scene.meta
  step("tv lineups", function() g.lineups = St.lineups(scene) end)
  -- faces: every player at 48 px, one per loader step (a step that has to decode a packed face
  -- table is then alone in its slice), sorted so each pack table is decoded once
  local nums = {}
  for _, p in pairs(m.people or {}) do if p.face and p.teamAbbr then nums[#nums + 1] = K.faceNum(p.face) end end
  table.sort(nums)
  for _, n in ipairs(nums) do step("tv face " .. n, function() A.preloadFace(n) end) end
  -- archive photos: only for the incidents this game has (the commercials go without), one
  -- per step (each may decode a packed archive table)
  local kinds = {}
  for _, b in ipairs(scene.tl.beats) do if b.kind == "inc" then kinds[b.e.kind] = true end end
  if scene.pendC then for kind in ("\n" .. scene.pendC.s):gmatch("\ninc\tkind=([^\t\n]+)") do kinds[kind] = true end end
  for _, e in ipairs(scene.pendingEv or {}) do if e.k == "inc" then kinds[e.kind] = true end end
  local seenPh = {}
  for kind in pairs(kinds) do
    local id = St.INCIDENT_PHOTO[kind]
    if id and not seenPh[id] then seenPh[id] = true; step("tv photo " .. id, function() A.preloadPhoto(id) end) end
    if kind:find("RACCOON") then g.raccoons = true end
  end
  step("tv packs flush", function() if Packs and Packs.flush then Packs.flush() end end)
  -- logos and fonts: one file per step (each is a disk read; the 2x logos are scaled after)
  for _, side in ipairs({ "away", "home" }) do
    step("tv logo32 " .. side, function() A.clubLogo(m[side], 32) end)
    step("tv logo16 " .. side, function() A.clubLogo(m[side], 16) end)
    step("tv logo2x " .. side, function() A.clubLogo2x(m[side]) end)
  end
  for _, f in ipairs({ "wa", "waBig", "serifb" }) do step("tv font " .. f, function() A.font(f) end) end
  for _, f in ipairs({ "big", "tiny", "mono", "bold", "nb" }) do step("tv font " .. f, function() local _ = K.fonts[f] end) end
  -- Prerendering: each item is one image (a text, a lower third, a dossier...). The few the
  -- first minutes need are loader steps of their own; the rest go on the idle queue, worked
  -- off on frames with time to spare (TV.idle: the intro menu, pauses, card/segment frames,
  -- light frames). Anything not ready when it's wanted is made on first use, as before.
  local queue = {}
  g.queue, g.qi = queue, 1
  local function later(label, fn) queue[#queue + 1] = { label, fn } end
  step("tv logo", function() A.logo() end)
  step("tv bug", function() A.bug(false); A.bug(true) end)
  step("tv digits", function() for d = 0, 10 do A.digit(d) end end)
  step("tv radar gun words", function() HUD.prewarmGun() end)
  step("tv scorebug", function()
    local b1 = scene.tl.beats[1]
    if b1 then HUD.buildBug(b1.post or b1.pre, m, false) end
  end)
  step("tv scorebug bits", function() HUD.prewarmBugBits() end)
  step("tv swing cam panel", function() PiP.prewarm(nil, nil) end)
  step("tv spin cam frames", function() Spin.prewarm(nil) end)
  Calls.prewarmSteps(step)
  step("tv k card", function() O.prewarm(g, nil) end)
  local texts = HUD.bannerTexts()
  for k, t in ipairs(texts) do
    local f = function() A.text(t[1], t[2], "wa") end
    local inn = tonumber(t[2]:match("^%a+ (%d+)"))
    if k <= 4 or (inn and inn <= 9) then step("tv text " .. t[2], f) else later("text " .. t[2], f) end
  end
  -- the first four batters of each side, every piece of their at-bat graphics, one per step
  -- (in a skipIntro start there is no idle time before they come up). Their PA beats if the
  -- timeline has them, else their first trip (which reads the same).
  do
    local firstPa = {}
    for jj, bb in ipairs(scene.tl.beats) do
      if bb.kind == "pa" and not firstPa[bb.e.bat] then firstPa[bb.e.bat] = jj end
    end
    for k = 1, 4 do
      for _, side in ipairs({ "away", "home" }) do
        local slot = k
        local bat = nil
        -- (the lineups step ran already: read it when the steps run)
        for pi = 1, 6 do
          step("tv at-bat " .. side .. " " .. k .. " piece " .. pi, function()
            bat = bat or (g.lineups[side] and g.lineups[side][slot])
            if not bat then return end
            local j = firstPa[bat]
            local pieces = TV.atBatPieces(scene, g, j, bat)
            if pieces[pi] then pieces[pi][2]() end
            if j then g.soonDone = g.soonDone or {}; g.soonDone[j] = true end
          end)
        end
      end
    end
    -- every player's scorebug name (small; so a jump or scrub never builds one)
    for id, q in pairs(m.people or {}) do
      if q.teamAbbr and q.name then step("tv bug name " .. q.name, function() HUD.bugName(q.name) end) end
    end
    for _, side in ipairs({ "away", "home" }) do
      step("tv starter bug name " .. side, function()
        local sp = g.lineups.sp[side]
        if sp and m.people[sp] then HUD.bugName(m.people[sp].name) end
      end)
    end
  end
  -- lower thirds in batting order, alternating sides; the first three of each in the loader
  for k = 1, 9 do
    for _, side in ipairs({ "away", "home" }) do
      local f = function()
        local id = g.lineups[side] and g.lineups[side][k]
        local p = id and m.people[id]
        if p then HUD.prewarmLowerThird(p.face, p.name or "?") end
      end
      if k > 4 then later("lower third " .. side .. " " .. k, f) end
    end
  end
  for _, side in ipairs({ "away", "home" }) do
    later("face small sp " .. side, function()
      local sp = g.lineups.sp[side]
      if sp and m.people[sp] then HUD.faceSmall(m.people[sp].face) end
    end)
  end
  for k = 1, 20 do
    local f = function() A.text("nb", "K #" .. k, "wo") end
    if k <= 3 then step("tv k label " .. k, f) else later("k label " .. k, f) end
  end
  -- this game's Enhanced League dossiers, in log order (the first one in the loader)
  local ultras, useen = {}, {}
  local function addU(who, power)
    local k = tostring(who) .. "|" .. tostring(power)
    if who and power and not useen[k] then useen[k] = true; ultras[#ultras + 1] = { who, power } end
  end
  for _, b in ipairs(scene.tl.beats) do for _, u in ipairs(b.ultra or {}) do addU(u.who, u.power) end end
  if scene.pendC then
    for line in ("\n" .. scene.pendC.s):gmatch("\nultra\t([^\n]+)") do addU(line:match("who=([^\t]+)"), line:match("power=([^\t]+)")) end
  end
  for _, e in ipairs(scene.pendingEv or {}) do if e.k == "ultra" then addU(e.who, e.power) end end
  for k, u in ipairs(ultras) do
    local f = function() O.prewarm(g, { u }) end
    if k == 1 then step("tv dossier " .. u[2], f) else later("dossier " .. u[2], f) end
  end
  for _, t in ipairs({ "INSTANT REPLAY", "SPECIAL REPORT", "DID YOU KNOW?" }) do later("text " .. t, function() A.text("waBig", t, "wa") end) end
  -- the replay chrome (replayChrome): its slow-motion rates (replay.lua's shots) and angles,
  -- ~7 ms each when a replay's first frame built them
  later("text replay chrome", function()
    A.text("nb", "REPLAY", "w"); A.text("nb", "TELESTRATOR", "w")
    for k = 1, 4 do A.text("nb", "ANGLE " .. k, "wo") end
  end)
  for _, r in ipairs({ 0.35, 0.45, 0.5, 0.7 }) do
    later("text slo-mo " .. r, function() A.text("tiny", string.format("SLO-MO %.2fX", r), "wo") end)
  end
  -- the camera guard's index of this park's stands (BallCast.Cam.safeEye), 150 polygons a step
  do
    local done = false
    local guard = 0
    while not done and guard < 100 do
      guard = guard + 1
      step("tv cam guard", function() done = BallCast.Cam.guardBuild(m.park, 150) end)
    end
  end
  -- the half-inning changeover's cameras, each checked against this park's geometry once
  if BallCast.Play.changeoverPrepare and BallCast.Cam.isClear then
    for _, top in ipairs({ true, false }) do
      for k = 1, 2 do step("tv changeover cam " .. (top and "top" or "bot") .. " " .. k, function() BallCast.Play.changeoverPrepare(m.park, top, k) end) end
    end
    -- a local game (Pennant): the bunt angle from each side of the plate, and the decision angles
    -- the scene cuts to while the player decides
    if scene.src and BallCast.Play.playCamPrepare then
      for _, sd in ipairs({ 1, -1 }) do step("tv bunt cam " .. sd, function() BallCast.Play.playCamPrepare(m.park, sd) end) end
    end
    if scene.src and BallCast.Render.decisionPrepare then
      for _, c in ipairs(BallCast.Render.decisionCombos()) do
        step("tv decision cam " .. c[1] .. " " .. c[2] .. " " .. c[3], function() BallCast.Render.decisionPrepare(m.park, c[1], c[2], c[3]) end)
      end
    end
    step("tv occluders release", function() BallCast.Cam.releaseOccluders(m.park) end)
  end
  -- the open's warmups: a dry run along the flyover path (bc3d records the sprite sizes it
  -- would need, nothing is drawn), then the sizes are built a couple per loader step
  if scene.live3d and bc3d and bc3d.collect and scene.R then
    local R = scene.R
    step("tv warmup dry run 1", function() bc3d.collect(true) end)
    for k = 0, 5 do
      step("tv warmup dry run " .. (k + 2), function()
        R:setCamera(TV.flyCam(k / 5))
        BallCast.TVWarmup.draw(R, k * 0.6, m)
      end)
    end
    local left = 1
    step("tv warmup collect", function() bc3d.collect(false) end)
    local guard = 0
    while left > 0 and guard < 200 do
      guard = guard + 1
      step("tv warmup sizes", function() left = bc3d.warmNext(); if left > 0 then left = bc3d.warmNext() end end)
    end
  end
  -- every sample that can play over a 3D frame, each in its own step (ballcast/audio.lua)
  Audio.warmSteps(step)
  -- the out-of-town scoreboard (async; the crawl image is built at the first break)
  K.get("/today", function(err, d)
    if err or not d or not G or G ~= g then return end
    local parts = {}
    for _, gm in ipairs(d.games or {}) do
      if gm.id ~= scene.gameId and gm.home and gm.away then
        local sc = gm.score
        if sc and sc.home and sc.away then
          parts[#parts + 1] = gm.away.abbr .. " " .. sc.away .. "  " .. gm.home.abbr .. " " .. sc.home .. ((gm.status == "final") and " (F)" or (" (" .. tostring(sc.inning or "") .. ")"))
        else
          parts[#parts + 1] = gm.away.abbr .. " AT " .. gm.home.abbr .. ": LATER"
        end
      end
    end
    g.crawlText = #parts > 0 and table.concat(parts, "   ***   ") or "NO OTHER GAMES TONIGHT. THE REST OF THE LEAGUE IS RESTING."
  end)
end

---------------------------------------------------------------------------
-- world rendering for segments (the replay's own camera)

local camCur, camShot
--- the open's flyover camera at k = 0..1: from high over the outfield, round and down to a
--- low angle behind the first-base side, where the warmups are
function TV.flyCam(k)
  -- (high over the center-field seats, then in and down over the grass to a low shot from
  -- behind first base's warmup pairs, looking across at home and the third-base line)
  k = A.ease(k)
  local x = -120 + 160 * k + sin(k * math.pi) * 60
  local y = 420 - 310 * k
  local z = 16 + 224 * (1 - k) ^ 1.4
  return { x, y, z, -20 * k, 150 - 130 * k, 3 * k, 54 - 2 * k }
end

local function renderWorld(beat, tau, cam)
  local scene = G.scene
  local R = scene.R
  if not R then return nil end
  local name = "high"
  if scene.live3d then
    local want
    if type(cam) == "function" then want = cam(beat, tau)
    elseif type(cam) == "table" and cam.name then want = BallCast.Render.shot(R, beat, tau, cam, G.camWant); G.camWant = want; name = cam.name
    elseif type(cam) == "table" then want = cam
    else want = BallCast.Render.shot(R, beat, tau, BallCast.Play.camAt(beat.plan, tau), G.camWant); G.camWant = want end
    if not camCur or camShot ~= cam then
      camCur = camCur or {}
      for k = 1, 7 do camCur[k] = want[k] end
    else
      for k = 1, 7 do camCur[k] = camCur[k] + (want[k] - camCur[k]) * 0.3 end
    end
    camShot = cam
    R:setCamera(camCur)
    if bc3d.quality then bc3d.quality(0) end
    R:background(0, 0, Audio.level and Audio.level() or 0.3)
  else
    name = (type(cam) == "string" and cam) or (type(cam) == "table" and cam.name) or BallCast.Play.camAt(beat.plan, tau).name
    R:use(name)
    R:background(0, 0)
  end
  local view = G.view or {}
  G.view = view
  local top = beat.pre.top
  view.defV, view.offV = top and "home" or "away", top and "away" or "home"
  view.incident = beat.kind == "inc" and beat.e.kind or nil
  view.brawl = false
  view.people = G.meta.people
  view.tags = false
  BallCast.Play.drawWorld(R, view, beat, tau)
  gfx.setDrawOffset(0, 0)
  return name
end

---------------------------------------------------------------------------
-- step drawers. Each: draw(step, u, dt) with u = seconds into the step.

local D = {}

-- network ident: warp streaks, a spinning diamond, the logo slams in, tagline, glint
D.ident = function(st, u)
  gfx.clear(gfx.kColorBlack)
  A.warp(200, 110, u, 30, true)
  local lg = A.logo()
  if u < 0.55 and not A.reduce then
    local r = A.ease(u / 0.5) * 44
    A.spinDiamond(200, 100, r, (1 - A.ease(u / 0.55)) * 5 * pi, true)
  else
    local q = A.reduce and 1 or A.back((u - 0.55) / 0.3)
    local s = 0.4 + q * 0.8
    if s ~= 1 and q < 1 then lg:drawScaled(200 - 75 * s, 100 - 32 * s, s) else lg:draw(125, 68) end
    if u > 0.55 and u < 0.61 then A.flash() end
    for k = 0, 2 do
      local rr = (u - 0.55 - k * 0.12) * 380
      if rr > 0 and rr < 320 then A.ring(200, 100, rr, 3, 1 - rr / 320) end
    end
  end
  if u > 0.85 then
    local tag = A.text("bold", "DEADBALL BROADCAST NETWORK", "w")
    local tw, th = tag:getSize()
    local w = floor(tw * A.ease((u - 0.85) / 0.4))
    gfx.setScreenClipRect(200 - tw // 2, 150, w, th)
    tag:draw(200 - tw // 2, 150)
    gfx.clearClipRect()
    if u > 1.25 then
      local sub = A.text("tiny", "1996. WE HAVE A CAMERA.", "w")
      local sw = sub:getSize()
      sub:draw(200 - sw // 2, 172)
    end
  end
  if u > 1.1 then A.glint(125, 68, 150, 64, (u - 1.1) / 0.45) end
end

-- stadium flyover with the show title
D.fly = function(st, u)
  local scene = G.scene
  local R = scene.R
  local tl = G.tl
  if R and scene.live3d then
    R:setCamera(TV.flyCam(u / st.dur))
    if bc3d.quality then bc3d.quality(0) end
    R:background(0, 0, 0.4)
    -- pregame warmups on the field (ballcast/tv/warmup.lua)
    BallCast.TVWarmup.draw(R, u, G.meta)
    gfx.setDrawOffset(0, 0)
  elseif R then
    R:use("high"); R:background(0, 0)
  end
  -- titles
  if not st.titles then
    local m = G.meta
    local pk = m.park or {}
    local w = pk.weather or {}
    local parts = {}
    if w.tempF then parts[#parts + 1] = w.tempF .. " DEGREES" end
    if w.windMph then parts[#parts + 1] = "WIND " .. w.windMph .. " MPH" end
    parts[#parts + 1] = (w.rain or 0) > 0.3 and "RAIN LIKELY" or ((w.rain or 0) > 0.05 and "SHOWERS" or "SKIES CLEAR")
    if pk.altitudeFt and pk.altitudeFt > 1000 then parts[#parts + 1] = pk.altitudeFt .. " FT UP" end
    local wx = table.concat(parts, "  -  ")
    st.titles = {
      A.text("waBig", "DBN BASEBALL", "wa"),
      A.text("bold", (scene.live and "LIVE FROM " or "FROM ") .. string.upper(pk.name or "THE BALLPARK"), "wo"),
      A.text("nb", wx, "wo"),
      A.text("tiny", string.upper((m.away and m.away.city or "") .. " AT " .. (m.home and m.home.city or "")), "wo"),
    }
  end
  local t = st.titles
  local w1 = t[1]:getSize()
  local x1 = 200 - w1 // 2 + floor((1 - A.ease((u - 0.2) / 0.35)) * 420)
  if u > 0.2 then
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 22, 400, 34)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(0, 22, 400, 2); gfx.fillRect(0, 54, 400, 2)
    gfx.setColor(gfx.kColorBlack)
    t[1]:draw(x1, 26)
  end
  local yb = 186
  if u > 0.6 then
    local q = A.ease((u - 0.6) / 0.3)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, yb, floor(400 * q), 44)
    if q >= 1 then
      t[2]:draw(10, yb + 3)
      if u > 0.9 then t[3]:draw(10, yb + 22) end
      local w4 = t[4]:getSize()
      t[4]:draw(390 - w4, yb + 6)
    end
  end
  -- a "LIVE"/"REPLAY" badge
  local badge = A.text("nb", scene.live and " LIVE " or " REPLAY ", "w")
  local bw, bh = badge:getSize()
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(392 - bw - 4, 64, bw + 4, bh + 2)
  if not scene.live or floor(u * 2) % 2 == 0 then badge:draw(392 - bw - 2, 65) end
end

D.card = function(st, u)
  if not st.card then st.card = st.build() end
  Cards.draw(st.card, u)
end

-- VHS rewind of the play
D.rewind = function(st, u)
  local s = st.script
  local b = s.b
  local from = b.dur
  local to = (s.shots[#s.shots].b == b) and s.shots[#s.shots].from or 0
  local tau = from + (to - from) * A.ease(u / st.dur)
  renderWorld(b, tau, nil)
  FX.vhs(0.8, floor(u * 30))
  -- ◄◄
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(8, 8, 96, 22)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillTriangle(14, 19, 26, 11, 26, 27)
  gfx.fillTriangle(26, 19, 38, 11, 38, 27)
  gfx.setColor(gfx.kColorBlack)
  A.drawText("nb", "REWIND", 44, 12, nil, "w")
end

-- INSTANT REPLAY stinger: the diamond zooms through the screen
D.sting = function(st, u)
  if st.prev then st.prev:draw(0, 0) else gfx.clear(gfx.kColorBlack) end
  local t = A.text("waBig", "INSTANT REPLAY", "wa")
  local tw, th = t:getSize()
  if A.reduce then
    A.shade(0, 0, 400, 240, min(1, u / 0.3))
  else
    local r = 6 + A.easeIn(min(1, u / 0.35)) * 300
    A.spinDiamond(200, 120, r, u * 9, true)
    if r > 280 then
      gfx.clear(gfx.kColorBlack)
      A.warp(200, 120, u, 24, true)
      A.spinDiamond(200, 120, 70, u * 3, true)
    end
  end
  if u > 0.12 then
    local q = A.reduce and 1 or A.back((u - 0.12) / 0.25)
    local s = 0.5 + 0.5 * q
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 120 - 20, 400, 40)
    if q < 1 then t:drawScaled(200 - tw * s / 2, 120 - th * s / 2, s) else t:draw(200 - tw // 2, 120 - th // 2) end
    A.glint(200 - tw // 2, 120 - th // 2, tw, th, (u - 0.4) / 0.3)
  end
end

local function replayChrome(st, u, frozen)
  -- top-left pill: spinning diamond + REPLAY; slow-motion factor; the bug
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(6, 6, 104, 20)
  gfx.setColor(gfx.kColorWhite)
  gfx.drawRect(7, 7, 102, 18)
  A.spinDiamond(19, 16, 6, A.reduce and 0 or u * 4, false)
  gfx.setColor(gfx.kColorWhite)
  gfx.drawPolygon(A.diamondPoly(19, 16, 7, 6))
  gfx.setColor(gfx.kColorBlack)
  A.drawText("nb", frozen and "TELESTRATOR" or "REPLAY", 30, 9, nil, "w")
  if not frozen then
    local r = st.shot.rate
    A.drawText("tiny", string.format("SLO-MO %.2fX", r), 114, 13, nil, "wo")
  end
  if st.angle then A.drawText("nb", "ANGLE " .. st.angle, 394, 9, "right", "wo") end
  A.bug(false):draw(346, 216)
end

-- one replay angle: slow motion, maybe a freeze with the telestrator
D.shot = function(st, u, dt)
  local sh = st.shot
  st.tau = st.tau or sh.from
  if st.frozen then
    st.fu = st.fu + dt
    gfx.pushContext(st.img)
    local started = RP.pen(st.strokes, st.fu)
    gfx.popContext()
    if started then sfx("tvPen") end
    st.img:draw(0, 0)
    if st.dist and st.fu > st.penDone then
      local q = A.ease((st.fu - st.penDone) / 0.25)
      local w, h = st.dist:getSize()
      if not st.distX then st.distX, st.distY = RP.clearSpot(st.strokes, w, h) end
      -- slides in from the nearer side edge
      local fromL = st.distX < 200 - w // 2
      local x = fromL and floor(st.distX - (1 - q) * (w + 20)) or floor(st.distX + (1 - q) * (w + 20))
      st.dist:draw(x, st.distY)
      if not st.distTick then st.distTick = true; sfx("tvTick") end
    end
    replayChrome(st, u, true)
    if st.fu >= st.hold then st.frozen = false; st.thawed = true end
    return
  end
  local prevTau = st.tau
  if u > 0 then st.tau = min(sh.to, st.tau + dt * sh.rate) end
  if sh.freeze and not st.thawed and st.tau >= sh.freeze then st.tau = sh.freeze end
  renderWorld(sh.b, st.tau, sh.cam)
  -- the sounds of the play, once more
  local cues = sh.b.plan.sfx
  for i = 1, #cues do
    local c = cues[i]
    if c.t > prevTau and c.t <= st.tau and (c.kind == "crack" or c.kind == "pop" or c.kind == "foul" or c.kind == "thud") then sfx(c.kind) end
  end
  if sh.freeze and not st.thawed and st.tau >= sh.freeze then
    -- freeze: capture the frame, then the pen draws into it
    st.img = gfx.getWorkingImage()
    st.strokes = sh.tele and sh.tele(G.scene.R, st.tau) or {}
    if TV.debugClock then print("[bctv] freeze at tau " .. string.format("%.2f", st.tau) .. ", " .. #st.strokes .. " strokes") end
    local total = RP.prep(st.strokes)
    st.penDone = total / 560 + 0.2
    st.hold = max(RP.TELE_DUR, st.penDone + (st.dist and 1.4 or 0.6))
    st.frozen, st.fu = true, 0
    if not A.reduce then A.flash() end
    sfx("tvFreeze")
  end
  replayChrome(st, u, false)
  -- reveal from the stinger through a diamond hole
  if st.reveal and u < 0.3 then FX.cover("hole", 1 - u / 0.3) end
end

local function shotDur(sh) return (sh.to - sh.from) / sh.rate + (sh.freeze and (RP.TELE_DUR + 1.6) or 0) end

---------------------------------------------------------------------------
-- segments

local function newSeg(kind, steps, outroKind)
  wipeN = wipeN + 1
  return { kind = kind, steps = steps, i = 1, u = 0, t = 0, prev = gfx.getDisplayImage(), outro = outroKind or FX.KINDS[wipeN % #FX.KINDS + 1] }
end

local function cardStep(build, wipe)
  wipeN = wipeN + 1
  return { kind = "card", build = build, wipe = wipe or FX.KINDS[wipeN % #FX.KINDS + 1], dur = nil }
end

local function stepDur(st)
  if st.dur then return st.dur end
  if st.kind == "card" then
    if not st.card then st.card = st.build() end
    st.dur = st.card.dur + WIPE - WIPE_IN
  elseif st.kind == "shot" then
    st.dur = shotDur(st.shot) + (st.shot.freeze and 0 or 0)
  end
  return st.dur or 1
end

-- a step begins: its sound
local function onStep(st)
  local k = st.kind
  if k == "ident" then sfx("tvIdent") elseif k == "rewind" then sfx("tvRewind") elseif k == "sting" then sfx("tvReplay") end
  if st.bulletin then sfx("tvBulletin") end
  if st.music and seg then sfx(st.music); seg.music = true end
end

local function start(kind, steps, outroKind)
  if #steps == 0 then return end
  if seg then
    -- (appending to a running segment: e.g. a break right after a replay)
    for _, s in ipairs(steps) do seg.steps[#seg.steps + 1] = s end
    return
  end
  seg = newSeg(kind, steps, outroKind)
  outro = nil
  onStep(steps[1])
end

--- Work off the prerender queue while this frame (started at frameStart ms) is under
--- `deadline` ms. One item at a time; each is a single image.
function TV.idle(frameStart, deadline)
  local g = G
  if not g or not g.queue or g.qi > #g.queue then return end
  local q = g.queue
  while g.qi <= #q and playdate.getCurrentTimeMilliseconds() - frameStart < deadline do
    local it = q[g.qi]
    g.qi = g.qi + 1
    local t0 = playdate.getElapsedTime()
    pcall(it[2])
    local ms = (playdate.getElapsedTime() - t0) * 1000
    g.idleMs = (g.idleMs or 0) + ms
    if ms > (g.idleMax or 0) then g.idleMax, g.idleMaxLabel = ms, it[1] end
    if ms > 8 then print(string.format("[bcidle] %s %.1f ms", it[1], ms)) end
    if g.qi > #q then
      print(string.format("[bcidle] prerender queue done: %d items, %.0f ms total, longest %.1f ms (%s)",
        #q, g.idleMs, g.idleMax or 0, tostring(g.idleMaxLabel)))
    end
  end
end

function TV.holding() return seg ~= nil end
function TV.active() return seg ~= nil or outro ~= nil end

--- The scene jumped ahead within the beat (A: the next camera shot) to plan time tau: what the
--- jump passed over (the banner's impact hit) doesn't fire on the way.
function TV.skipped(tau) if lastTau then lastTau = tau end end

function TV.interrupt()
  -- a swing-cam inset folds away (and the button is spent on that)
  if G and G.pipShowing then G.pipDismiss = G.pipShowing; G.pipShowing = nil; if not seg then return true end end
  if not seg and not outro then return false end
  local had = seg ~= nil
  if seg and seg.music then Audio.sfx("stopMusic") end
  seg, outro = nil, nil
  camCur = nil
  return had
end

-- the steps of an instant replay for beat bi
local function replaySteps(bi, tier, kind)
  local s = RP.script(G, bi, kind)
  if not s then return {} end
  local steps = {}
  if tier == 1 and not A.reduce then steps[#steps + 1] = { kind = "rewind", script = s, dur = 0.75 } end
  steps[#steps + 1] = { kind = "sting", dur = 0.7 }
  for k, sh in ipairs(s.shots) do
    local st = { kind = "shot", shot = sh, reveal = k == 1, angle = #s.shots > 1 and k or nil }
    if sh.freeze and k == #s.shots then st.dist = RP.distPanel(s) end
    steps[#steps + 1] = st
  end
  return steps
end

-- between innings: entering half beat bi
local function breakSteps(bi, b)
  local steps = {}
  local tl, m = G.tl, G.meta
  local inn, top = b.e.inn, b.e.top
  G.breaks = (G.breaks or 0) + 1
  local function lineups() return G.lineups end
  if top and inn >= 2 then
    local done = inn - 1
    steps[#steps + 1] = cardStep(function()
      G.curPit = curPitchers(tl, bi)
      if G.crawlText and not G.crawl then G.crawl = Cards.crawlImage(G.crawlText) end
      local due = St.dueUp(tl, lineups(), bi, "away", 3)
      return Cards.linescore(G, bi, "END OF " .. St.ordinal(done), "away", due)
    end)
    if done == 2 or done == 5 or done == 8 then
      local which = Cards.AD_ORDER[(G.adN or 0) % #Cards.AD_ORDER + 1]
      G.adN = (G.adN or 0) + 1
      steps[#steps + 1] = cardStep(function() return Cards.bumper(G) end, "swoosh")
      steps[#steps].music = "tvAdMusic"
      steps[#steps + 1] = cardStep(function() return Cards.ad(G, which) end, "checker")
    elseif done == 3 or done == 6 then
      local n = G.breaks
      steps[#steps + 1] = cardStep(function() return Cards.didYouKnow(G, St.didYouKnow(tl, m, bi, n, lineups())) end, "zip")
    end
  elseif not top then
    if inn == 7 then
      steps[#steps + 1] = cardStep(function() return Cards.stretch(G) end, "blinds")
    elseif inn == 1 or inn == 4 or inn == 9 then
      steps[#steps + 1] = cardStep(function()
        return Cards.dueUp(G, bi, "home", St.dueUp(tl, lineups(), bi, "home", 3), inn >= 9 and "DUE UP: LAST CHANCE" or "DUE UP")
      end, "swoosh")
    end
  end
  return steps
end

local function openSteps(short)
  local steps = { { kind = "ident", dur = 1.7 } }
  if not short then steps[#steps + 1] = { kind = "fly", dur = 3.2, wipe = "blinds", music = "tvTheme" } end
  steps[#steps + 1] = cardStep(function() return Cards.matchup(G) end, "swoosh")
  if not short then
    steps[#steps + 1] = cardStep(function() return Cards.lineup(G, "away") end, "zip")
    steps[#steps + 1] = cardStep(function() return Cards.lineup(G, "home") end, "checker")
  end
  return steps
end

local function postSteps()
  local tl, m = G.tl, G.meta
  local steps = { cardStep(function() return Cards.final(G) end, "diamond") }
  local id, kind, line = St.playerOfGame(tl, m)
  if id then steps[#steps + 1] = cardStep(function() return Cards.potg(G, id, kind, line) end, "swoosh") end
  steps[#steps + 1] = cardStep(function() return Cards.signoff(G) end, "blinds")
  return steps
end

-- run the current step; returns true (the segment drew the frame)
local function runSeg(dt)
  local st = seg.steps[seg.i]
  if TV.debugClock then dt = TV.debugClock end
  local u = seg.u
  local d = stepDur(st)
  local w = st.wipe and WIPE_IN or 0
  if st.wipe and u < w then
    -- cover the previous step's last frame
    if seg.prev then seg.prev:draw(0, 0) else gfx.clear(gfx.kColorBlack) end
    FX.cover(st.wipe, u / w)
    if not st.whoosh then st.whoosh = true; sfx("tvWhoosh") end
  else
    local su = u - w
    if st.kind == "card" or st.kind == "ident" or st.kind == "fly" or st.kind == "rewind" or st.kind == "sting" then
      if st.kind == "sting" and not st.prev then st.prev = seg.prev end
      D[st.kind](st, su, dt)
    else
      D.shot(st, su, dt)
    end
    if st.wipe and su < WIPE - WIPE_IN then FX.cover(st.wipe, 1 - su / (WIPE - WIPE_IN), true) end
  end
  seg.u = u + dt
  seg.t = seg.t + dt
  local finished = seg.u >= d + w
  if st.kind == "shot" then finished = (st.tau or 0) >= st.shot.to - 0.001 and not st.frozen and seg.u > 0.1 end
  if finished then
    seg.i = seg.i + 1
    seg.u = 0
    local nx = seg.steps[seg.i]
    if not nx then
      if seg.music then sfx("stopMusic") end
      outro = { kind = seg.outro, t = 0 }
      seg = nil
      camCur = nil
      return true
    end
    -- the frame we just drew is what the next wipe covers
    seg.prev = (nx.wipe or nx.kind == "sting") and gfx.getWorkingImage() or nil
    onStep(nx)
  end
  return true
end

---------------------------------------------------------------------------
-- per frame

local function bigTier(text)
  return text == "HOME RUN!" or text == "GRAND SLAM!" or text == "WALK-OFF HOME RUN!" or text == "WALK-OFF!"
    or text == "LEAP CATCH! ROBBED!" or text == "WHAT A CATCH"
end

local frameImpl
function TV.frame(scene, bi, b, tau, dt, scrubbing)
  local t0 = playdate.getElapsedTime()
  local r = frameImpl(scene, bi, b, tau, dt, scrubbing)
  TV.frameMs = (playdate.getElapsedTime() - t0) * 1000
  return r
end
frameImpl = function(scene, bi, b, tau, dt, scrubbing)
  local g = context(scene)
  g.scrubbing = scrubbing
  A.reduce = reduce()
  local tl = g.tl
  -- radar gun: the pitcher's pitch number (HUD.pitchBox shows it)
  if b.kind == "p" and b.pre.pit then
    if g.pnBi ~= bi then
      local c = St.counts(tl, bi)
      local pc = c.pit[b.pre.pit]
      g.pnBi, g.pn = bi, pc and pc.n or nil
    end
    HUD.pitchNo = g.pn
  end
  if g.prepBi ~= bi then g.prepBi = bi; prepUpcoming(scene, g, bi) end
  local full = true   -- (always: the lite mode is gone)
  local natural = scene.playing and not scrubbing and not scene.logOpen and lastBi ~= nil and bi == lastBi + 1
  -- the cold open: first frame of a from-the-top watch
  if not g.opened and scene.mode == "watch" then
    g.opened = true
    if full and scene.playing and not scene.live and not (scene.args and scene.args.skipIntro) and scene.t < 0.1 then
      start("open", openSteps(scene.highlights))
    end
  end
  if not seg and full and natural and scene.speed <= 2 then
    local steps = {}
    -- 1) the play that just ended: instant replay?
    if not seen["r" .. (bi - 1)] then
      local tier, kind = RP.worthy(tl, bi - 1)
      if tier and (tier == 1 or scene.speed == 1) then
        local half = (b.pre.inn or 0) * 2 + (b.pre.top and 0 or 1)
        if tier == 1 or g.lastT2 ~= half then
          seen["r" .. (bi - 1)] = true
          if tier == 2 then g.lastT2 = half end
          for _, s in ipairs(replaySteps(bi - 1, tier, kind)) do steps[#steps + 1] = s end
        end
      end
    end
    -- 2) what's starting: a break, a bulletin
    if not seen[bi] then
      seen[bi] = true
      if b.kind == "half" and scene.speed == 1 then
        for _, s in ipairs(breakSteps(bi, b)) do steps[#steps + 1] = s end
      elseif b.kind == "inc" then
        local text = BallCast.Timeline.describe(tl, b) or b.e.kind
        steps[#steps + 1] = cardStep(function() return Cards.special(G, b, text, b.e.note and string.upper(b.e.note) or St.INCIDENT_NOTE[b.e.kind]) end, "zip")
        steps[#steps].bulletin = true
      end
    end
    if #steps > 0 then start("seg", steps) end
  end
  -- postgame: the end of a final, reached by playing into it
  if not seg and full and b.kind == "end" and bi == #tl.beats and tl.final and not seen.post
    and lastTau and lastBi == bi and lastTau < b.dur - 0.15 and tau >= b.dur - 0.15 and not scrubbing then
    seen.post = true
    start("post", postSteps(), "dissolve")
  end
  -- big moment: an impact hit as the banner lands
  if not seg and b.big and lastBi == bi and lastTau and not scrubbing and scene.playing then
    local t0 = BallCast.Play.bannerT(b)
    if lastTau < t0 and tau >= t0 and bigTier(b.big) then sfx("tvImpact") end
  end
  lastBi, lastTau = bi, tau
  if seg then
    local t0 = playdate.getElapsedTime()
    local kind = seg.steps[seg.i] and seg.steps[seg.i].kind
    runSeg(dt)
    local ms = (playdate.getElapsedTime() - t0) * 1000
    if ms > 40 then print(string.format("[bctv] %d ms step=%s", floor(ms), tostring(kind))) end
    TV.lastMs, TV.lastStep = ms, kind
    -- card frames draw no 3D: room for the prerender queue
    if kind == "card" or kind == "ident" or kind == "sting" then TV.idle(scene.lastMs or playdate.getCurrentTimeMilliseconds(), 22) end
    return true
  end
  return false
end

function TV.overlay(scene, bi, b, tau, camName, slo, dt)
  if not G then return end
  local t0 = playdate.getElapsedTime()
  local pipOn, pipX = PiP.draw(G, scene.R, bi, b, tau, camName, { speed = scene.speed, scrubbing = G.scrubbing,
    logOpen = scene.logOpen, dismissed = G.pipDismiss })
  if pipOn then
    local pb = b.kind == "p" and b or G.tl.beats[bi - 1]
    G.pipShowing = pb and pb.n
  else
    G.pipShowing = nil
  end
  O.pipActive = pipOn
  O.draw(G, scene, bi, b, tau, camName, slo, scene.R)
  Spin.draw(b, tau, camName, { speed = scene.speed, scrubbing = G.scrubbing, logOpen = scene.logOpen })
  Calls.draw(G.tl, b, tau, { speed = scene.speed, scrubbing = G.scrubbing, logOpen = scene.logOpen, pipLeft = pipOn and pipX and pipX < 200, pipOn = pipOn, cam = camName })
  local ms = (playdate.getElapsedTime() - t0) * 1000
  -- per-camera averages of what DBN adds (overlays + banners + the TV.frame checks), for tours
  if scene.playing then
    local c = G.cost or {}
    G.cost = c
    local k = tostring(camName)
    local e = c[k] or { n = 0, ov = 0, hud = 0, fr = 0 }
    c[k] = e
    e.n, e.ov, e.hud, e.fr = e.n + 1, e.ov + ms, e.hud + (HUD.costMs or 0), e.fr + (TV.frameMs or 0)
    c.frames = (c.frames or 0) + 1
    if c.frames % 300 == 0 then
      for cam, v in pairs(c) do
        if type(v) == "table" and v.n > 0 then
          print(string.format("[bctv] cost cam=%s frames %d: overlay %.2f banner %.2f tv.frame %.2f ms avg", cam, v.n, v.ov / v.n, v.hud / v.n, v.fr / v.n))
          v.n, v.ov, v.hud, v.fr = 0, 0, 0, 0
        end
      end
    end
  end
  HUD.costMs = 0
  if ms > 6 then print(string.format("[bctv] overlay %.1f ms beat=%d(%s) cam=%s", ms, bi, b.kind, tostring(camName))) end
  -- spare time: paused, or a light frame
  if scene.lastMs then
    runSoon(G, scene.lastMs, 25)
    TV.idle(scene.lastMs, scene.playing and 14 or 24)
  end
  if outro then
    if TV.debugClock then dt = TV.debugClock end
    local p = 1 - outro.t / OUTRO
    if p > 0 then FX.cover(outro.kind, p, true) end
    outro.t = outro.t + (dt or 1 / 30)
    if outro.t >= OUTRO then outro = nil end
  end
end

---------------------------------------------------------------------------
-- lifecycle

function TV.reset(scene)
  G, seg, outro = nil, nil, nil
  lastBi, lastTau = nil, nil
  seen = {}
  camCur, camShot = nil, nil
  HUD.pitchNo = nil
end

function TV.release()
  TV.reset(nil)
  A.release()
  O.release()
  PiP.release()
  Spin.release()
  Calls.release()
end

--- lower third fact (HUD.lowerThird's third line)
local function paOf(tl, bi)
  while bi > 1 and tl.beats[bi].kind ~= "pa" do bi = bi - 1 end
  return bi
end

function TV.fact(scene, bi, id)
  local g = context(scene)
  -- (keyed by the at-bat's PA beat, so the card doesn't change when the first pitch starts)
  bi = paOf(g.tl, bi)
  local k = bi .. ":" .. tostring(id)
  g.facts = g.facts or {}
  local f = g.facts[k]
  if f == nil then f = St.fact(g.tl, g.meta, bi, id); g.facts[k] = f end
  return f
end

--- "1-FOR-2 TODAY" for the batter of the at-bat containing beat bi (memoized per at-bat: the
--- scene used to recount the whole game every frame the lower third was up)
function TV.lineToday(scene, bi, bat)
  local g = context(scene)
  local tl = g.tl
  bi = paOf(tl, bi)
  local k = bi .. ":" .. tostring(bat)
  g.lines = g.lines or {}
  local v = g.lines[k]
  if v then return v end
  local h, ab = 0, 0
  for i = 1, bi - 1 do
    local b = tl.beats[i]
    if b.pre.bat == bat then
      if b.kind == "bip" then
        local r = b.e.res
        if r ~= "SF" then ab = ab + 1 end
        if r == "1B" or r == "2B" or r == "3B" or r == "HR" then h = h + 1 end
      elseif b.kind == "p" and b.k then
        ab = ab + 1
      end
    end
  end
  v = ab == 0 and "FIRST TRIP TO THE PLATE" or (h .. "-FOR-" .. ab .. " TODAY")
  g.lines[k] = v
  return v
end

-- Before an at-bat starts, its lower third is made in small pieces on the frames before it
-- (one piece per frame with time left): the per-batter card, then the info line and the
-- fact. Queued for the next two at-bats each time a new beat starts.
-- the pieces of one at-bat's graphics, each one small image (< ~5 ms on the device): the
-- face, the lower third's card and name, its info line and fact, the scorebug name.
-- j: the PA beat (nil = the batter's first trip, which needs no timeline: see below)
local function atBatPieces(scene, g, j, bat)
  local p = g.meta.people[bat]
  if not p then return {} end
  local pos = (p.pos or "") .. (p.teamAbbr and (" - " .. p.teamAbbr) or "")
  local nm = p.name or "?"
  return {
    { "face " .. nm, function() HUD.faceSmall(p.face) end },
    { "card " .. nm, function() HUD.prewarmLowerThird(p.face, nm, 1) end },
    { "name " .. nm, function() HUD.prewarmLowerThird(p.face, nm, 2) end },
    { "info " .. nm, function()
      -- (a first trip reads the same without the timeline: "FIRST TRIP TO THE PLATE")
      HUD.prewarmLowerThirdText(pos, j and TV.lineToday(scene, j, bat) or "FIRST TRIP TO THE PLATE", nil)
    end },
    { "fact " .. nm, function()
      -- (a first trip's fact is the flavor one: St.fact only has a game fact after an at-bat)
      HUD.prewarmLowerThirdText(nil, nil, j and TV.fact(scene, j, bat) or St.flavor(bat))
    end },
    { "bug name " .. nm, function() HUD.bugName(p.name) end },
  }
end
TV.atBatPieces = atBatPieces

-- Scans only beats it hasn't seen (up to 25 ahead), so a beat change costs a few table reads,
-- not a 40-beat walk.
prepUpcoming = function(scene, g, bi)
  local tl, m = g.tl, g.meta
  g.soon = g.soon or {}
  g.soonDone = g.soonDone or {}
  local soon = g.soon
  local from = math.max(bi + 1, (g.scanTo or 0) + 1)
  if g.scanFrom and bi < g.scanFrom then from = bi + 1 end      -- (scrubbed back)
  g.scanFrom = bi
  local to = math.min(#tl.beats, bi + 25)
  for j = from, to do
    local b = tl.beats[j]
    local k = b.kind
    if not g.soonDone[j] then
      g.soonDone[j] = true
      if k == "p" then
        soon[#soon + 1] = { "spin label", function() Spin.prewarm(b) end }
        if PiP.tier(tl, b) then soon[#soon + 1] = { "swing verdict", function() PiP.prewarm(tl, b) end } end
      elseif k == "pa" then
        for _, piece in ipairs(atBatPieces(scene, g, j, b.e.bat)) do soon[#soon + 1] = piece end
      elseif k == "sub" then
        -- a new pitcher / fielder: his card and scorebug name
        local q = m.people[b.e["in"]]
        if q then
          soon[#soon + 1] = { "sub face", function() HUD.faceSmall(q.face) end }
          soon[#soon + 1] = { "sub card", function() HUD.prewarmLowerThird(q.face, q.name or "?", 1) end }
          soon[#soon + 1] = { "sub name", function() HUD.prewarmLowerThird(q.face, q.name or "?", 2) end }
          soon[#soon + 1] = { "sub bug name", function() HUD.bugName(q.name) end }
        end
      elseif k == "half" then
        local txt = (b.e.top and "TOP " or "BOT ") .. St.ordinal(b.e.inn)
        soon[#soon + 1] = { "pill " .. txt, function() A.text("wa", txt, "wa") end }
      end
    end
  end
  if to > (g.scanTo or 0) then g.scanTo = to end
end

--- one "soon" piece every frame (forced: the pitch cam rarely has time to spare, and each
--- piece is one small image); the device log shows any piece over 3 ms
runSoon = function(g, frameStart, deadline)
  local q = g and g.soon
  if not q or #q == 0 then return end
  local piece = table.remove(q, 1)
  local t0 = playdate.getElapsedTime()
  pcall(piece[2])
  local ms = (playdate.getElapsedTime() - t0) * 1000
  g.soonMax = math.max(g.soonMax or 0, ms)
  if ms > 3 then print(string.format("[bcidle] soon piece %-28s %.1f ms", piece[1], ms)) end
end

---------------------------------------------------------------------------
-- harness helpers

--- start a segment directly: what = "open" | "openShort" | "replay" | "break" | "special" | "post" | card name
function TV.debugStart(scene, what, bi)
  local g = context(scene)
  seg, outro = nil, nil
  local tl = g.tl
  if what == "open" or what == "openShort" then start("open", openSteps(what == "openShort"))
  elseif what == "replay" then
    local tier, kind = RP.worthy(tl, bi)
    if tier then start("seg", replaySteps(bi, tier, kind)) end
  elseif what == "replayK" then
    start("seg", replaySteps(bi, 2, "k"))
  elseif what == "break" then start("seg", breakSteps(bi, tl.beats[bi]))
  elseif what == "special" then
    local b = tl.beats[bi]
    local text = BallCast.Timeline.describe(tl, b) or b.e.kind
    start("seg", { cardStep(function() return Cards.special(G, b, text, St.INCIDENT_NOTE[b.e.kind]) end, "zip") })
  elseif what == "post" then start("post", postSteps(), "dissolve")
  elseif what == "ad" then
    local which = Cards.AD_ORDER[(bi - 1) % #Cards.AD_ORDER + 1]
    start("seg", { cardStep(function() return Cards.ad(G, which) end, "checker") })
  elseif what == "dyk" then
    start("seg", { cardStep(function() return Cards.didYouKnow(G, St.didYouKnow(tl, g.meta, #tl.beats, bi, g.lineups)) end, "zip") })
  elseif what == "stretch" then start("seg", { cardStep(function() return Cards.stretch(G) end, "blinds") })
  elseif what == "dueup" then start("seg", { cardStep(function() return Cards.dueUp(G, bi, "home", St.dueUp(tl, g.lineups, bi, "home", 3)) end, "swoosh") })
  elseif what == "linescore" then
    start("seg", { cardStep(function()
      g.curPit = curPitchers(tl, bi)
      if g.crawlText and not g.crawl then g.crawl = Cards.crawlImage(g.crawlText) end
      return Cards.linescore(G, bi, "END OF " .. St.ordinal(max(1, (tl.beats[bi].pre.inn or 2) - 1)), "away", St.dueUp(tl, g.lineups, bi, "away", 3))
    end) })
  end
  return seg ~= nil
end

--- the running segment's step kind and index (harness)
function TV.debugState()
  if not seg then return nil end
  local st = seg.steps[seg.i]
  return st and st.kind, seg.i, #seg.steps, seg.u, st and st.frozen
end

return TV
