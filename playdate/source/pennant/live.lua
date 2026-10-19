--[[ Pennant's live game in BallCast: a local source (BallCast.scene args.source, see the header of
  ballcast/scene.lua) that streams the engine's events into the replay as a live game, plus the
  overlays:
  * the dugout menu at the manager's spots (steal / bunt / hit-and-run / pinch hit; pitching
    change / IBB / pitch around / shift; one press = the coach's call),
  * direct batting: the K-zone inset with your bat's height (up/down), a power swing (left/right),
    the pitch coming in and a subtle timing strip; press A to swing,
  * direct pitching: pick the pitch (crank), aim on the K-zone (d-pad), A for the effort meter,
    A again to throw,
  * B: the dugout's own menu (call time, direct control on/off, simulate to the end, leave).
  The game is always created with every control on; anything the player leaves to the coaches
  is answered by stepping on (the contract: an unanswered pause is the AI's call).
]]

local gfx <const> = playdate.graphics
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

PennantLive = PennantLive or {}
local Live = {}
Live.__index = Live
Live.finalCard = true

local function nid(s) return PEng.nid(s) end
local function P(id) local L = Pennant.L return L.players[nid(id) or -1] end
local function short(id) local p = P(id) return p and PM.short(p) or tostring(id) end

--- mode: "manage" (dugout calls, coaches bat and pitch) | "play" (you bat and pitch too)
function PennantLive.start(mode)
  local L = Pennant.L
  local g = PL.gameFor(L, L.user)
  if not g or g.done then return end
  if not (BallCast and BallCast.scene) then
    Dialog.alert("No BallCast", "This build has no BallCast. Simulating instead.")
    PennantUI.Advance.open({ days = 1 })
    return
  end
  local T = L.teams[L.user]
  PRoster.validate(L, T)
  local ctrl = { [L.user] = { manage = true, bat = true, pitch = true } }
  local h = PEng.newGame(L, g, ctrl)
  local src = setmetatable({ L = L, g = g, h = h, pub = {}, mode = mode, directBat = mode == "play", directPitch = mode == "play",
    user = L.user, side = g.h == L.user and "home" or "away", id = "pennant-" .. L.season .. "-" .. L.day }, Live)
  -- the rest of the league plays in the background (sliced)
  PJobs.simDay(L, g)
  -- enough of the game for BallCast to start on
  for _ = 1, 20 do
    src:pump(30)
    if #src.pub > 2 or src.pause then break end
  end
  Sfx.stopMusic(0.5)
  src.scene = BallCast.scene
  App.push(BallCast.scene, { gameId = src.id, source = src, skipIntro = true })
  PennantLive.cur = src
end

-- Engine plumbing -------------------------------------------------------------------------------------

--- Step the engine; publish new events. Returns the events.
function Live:pump(n, ms)
  if self.pause then return {} end
  local evs, pause = self.h:step(n or 30, ms)
  for _, e in ipairs(evs) do self.pub[#self.pub + 1] = e end
  self.pause = pause
  self.fresh = true
  return evs
end

function Live:feed(scene, evs)
  if #evs > 0 and scene.tl then scene:feed(evs) end
end

--- Answer the current pause (or not: nil = the coaches do it), step on, publish.
function Live:resume(scene, replaceProvisional)
  self.pause = nil
  self.ui = nil
  local evs = self:pump(30)
  if replaceProvisional then
    if not scene:dropLast() then print("[pennant] couldn't take back the provisional pitch") end
    self.prov = nil
  end
  self:feed(scene, evs)
end

-- BallCast's requests -----------------------------------------------------------------------------------

local function teamInfo(L, abbr)
  local c = PennantClubs.byAbbr[abbr]
  local T = L.teams[abbr]
  return { id = abbr, abbr = abbr, city = c.city, name = c.name, level = "ML", record = T.w .. "-" .. T.l }
end

function Live:get(path)
  local L = self.L
  local rest = path:match("^/games/[^/?]+(.*)$")
  if path:find("^/today") then
    local games = {}
    for _, g in ipairs((PL.today(L) or {}).games or {}) do
      if g ~= self.g then
        games[#games + 1] = { id = "x", home = { abbr = g.h }, away = { abbr = g.a }, status = g.done and "final" or "live",
          score = g.done and { home = g.hs, away = g.as, inning = "F" } or nil }
      end
    end
    return { games = games }
  end
  if not rest then return nil end
  if rest:find("^/wire") then return { lines = {} } end
  if rest:find("^/log") then
    local from = tonumber(rest:match("from=(%d+)")) or 0
    local log = {}
    for i = from + 1, #self.pub do log[#log + 1] = self.pub[i] end
    self.sentInitial = #self.pub
    return { id = self.id, status = "live", from = from, log = log, people = self.h.people, park = self.h.park }
  end
  return { id = self.id, status = "live", home = teamInfo(L, self.g.h), away = teamInfo(L, self.g.a) }
end

-- Situations --------------------------------------------------------------------------------------------

function Live:caughtUp(scene)
  local tl = scene.tl
  return tl and scene.t >= tl.total - 0.05 and not scene:timelinePending()
end

--- Would a manager want the menu here?
function Live:interesting(p)
  local i = p.info
  if self.callTime then return true end
  local mine = i.score[self.side]
  local theirs = i.score[self.side == "home" and "away" or "home"]
  local close = abs(mine - theirs) <= 3
  local b = i.bases
  if p.role == "def" then
    if (i.pitcher.fatigue or 0) > 0.12 then return true end
    if (b[2] or b[3]) and i.inn >= 6 and close then return true end
    if i.inn >= 8 and close and i.outs == 0 and not (b[1] or b[2] or b[3]) then return true end
  else
    if (b[1] or b[2]) and i.outs < 2 and close and i.inn >= 5 then return true end
    if i.inn >= 7 and close and #(i.bench or {}) > 0 and i.outs < 2 then return true end
  end
  return false
end

--- The coach's suggestion: { kind, id?, runner?, label }.
function Live:suggest(p)
  local i = p.info
  local mine = i.score[self.side]
  local theirs = i.score[self.side == "home" and "away" or "home"]
  local lead = mine - theirs
  local b = i.bases
  if p.role == "def" then
    if (i.pitcher.fatigue or 0) > 0.2 then
      local want = (i.inn >= 9 and lead >= 1 and lead <= 3) and "CL" or ((i.inn == 8 and lead >= 0 and lead <= 3) and "SU") or nil
      local pick
      for _, e in ipairs(i.pen or {}) do if e.ready and (not want or e.role == want) then pick = e break end end
      if not pick then for _, e in ipairs(i.pen or {}) do if e.ready then pick = e break end end end
      if pick then return { kind = "pitch_change", id = pick.id, label = "Bring in " .. short(pick.id) } end
    end
    local bat = P(i.batter.id)
    if bat and not b[1] and (b[2] or b[3]) and i.inn >= 7 and abs(lead) <= 1 and bat.r.pow >= 64 then return { kind = "ibb", label = "Walk him" } end
    return { kind = "none", label = "Play on" }
  end
  local r1 = b[1] and P(b[1])
  if r1 and not b[2] and i.outs < 2 and r1.r.spd >= 60 then return { kind = "steal", runner = 1, label = "Steal second" } end
  local bat = P(i.batter.id)
  if (b[1] or b[2]) and i.outs == 0 and i.inn >= 7 and abs(lead) <= 1 and bat and bat.r.con + bat.r.pow < 95 then return { kind = "bunt", label = "Bunt them over" } end
  return { kind = "none", label = "Swing away" }
end

--- Dugout menu items for this pause.
function Live:menuItems(p)
  local i = p.info
  local b = i.bases
  local sug = self:suggest(p)
  local items = {}
  local function add(kind, label, extra) local it = { kind = kind, label = label } for k, v in pairs(extra or {}) do it[k] = v end items[#items + 1] = it return it end
  local first = add("none", p.role == "def" and "Play on" or "Swing away")
  if p.role == "off" then
    if b[1] and not b[2] then add("steal", "Steal second", { runner = 1 }) end
    if b[2] and not b[3] then add("steal", "Steal third", { runner = 2 }) end
    if b[1] and not b[2] then add("hitrun", "Hit and run") end
    if (b[1] or b[2]) and i.outs < 2 then add("bunt", "Sacrifice bunt") end
    if b[3] and i.outs < 2 then add("squeeze", "Squeeze") end
    if #(i.bench or {}) > 0 then add("ph", "Pinch hit...") end
  else
    add("pc", "Pitching change...")
    if not b[1] or not (b[1] and b[2] and b[3]) then add("ibb", "Intentional walk") end
    add("pitch_around", "Pitch around him")
    add("shift", "Shift the infield")
    if b[3] and i.outs < 2 then add("infield_in", "Infield in") end
  end
  add("sim", "Sim to end")
  -- the coach's call is the highlighted default
  local sel = 1
  for k, it in ipairs(items) do
    if it.kind == sug.kind or (sug.kind == "pitch_change" and it.kind == "pc") then sel = k end
    if it.kind == "steal" and sug.kind == "steal" and it.runner ~= sug.runner then sel = sel end
  end
  if sug.kind == "pitch_change" then items[sel].label = sug.label items[sel].kind = "pitch_change" items[sel].id = sug.id end
  return items, sel, sug
end

-- Per-frame --------------------------------------------------------------------------------------------

local function held(btn) return playdate.buttonIsPressed(btn) end

function Live:frame(scene, bi, b, tau, dt)
  local tl = scene.tl
  -- the rest of the league: a sliver of each frame
  PJobs.tick(2)
  if not tl then return nil end
  -- initial events BallCast already has: nothing to feed; later ones are fed directly
  if self.simming then return self:simFrame(scene) end
  if not self.pause then
    if tl.total - scene.t < 14 then self:feed(scene, self:pump(40, 4)) end
    return nil
  end
  local p = self.pause
  if p.reason == "done" then return nil end
  if p.reason == "pa" then
    if not self:caughtUp(scene) then return nil end
    if not self.ui then
      if self:interesting(p) then
        local items, sel, sug = self:menuItems(p)
        self.ui = { kind = "dugout", items = items, sel = sel, sug = sug, t = 0 }
        self.callTime = false
        if BCKit and BCKit.sfx then pcall(BCKit.sfx, "click") end
      else
        -- not worth a stop: the coaches make the call (a human-managed side only steals or
        -- changes pitchers on order, so the coach's suggestion is ordered for them)
        local sug = self:suggest(p)
        if sug.kind == "steal" or sug.kind == "pitch_change" then self.h:decide({ kind = sug.kind, id = sug.id, runner = sug.runner }) end
        self:resume(scene)
      end
    end
    return nil
  end
  if p.reason == "bat" then
    if not self.directBat then self:resume(scene) return nil end
    if not self.prov then
      -- the pitch is on its way: show it now as a take, decide on the swing as it flies
      local pt, i = p.pitch, p.info
      local r = (pt.zone or 3) <= 1 and "C" or "B"
      local e = { k = "p", t = pt.t, v = pt.v, z = pt.zone, r = r, b = i.balls + (r == "B" and 1 or 0), s = i.strikes + (r == "C" and 1 or 0), px = pt.px, pz = pt.pz }
      scene:feed({ e })
      self.prov = { beat = #tl.beats, pitch = pt }
      self.ui = { kind = "bat", aim = self.lastAim or 0, power = false, t = 0 }
    end
    local pb = tl.beats[self.prov.beat]
    if bi ~= self.prov.beat or not pb or not pb.plan.pitch then return nil end
    local pp = pb.plan.pitch
    self.ui.tau, self.ui.plan = tau, pb.plan
    -- aim follows the d-pad while held
    if held(playdate.kButtonUp) then self.ui.aim = min(1.6, self.ui.aim + 0.06) elseif held(playdate.kButtonDown) then self.ui.aim = max(-1.6, self.ui.aim - 0.06) end
    if tau > pp.tPlate + 0.15 and not self.ui.swung then
      -- took it
      self.lastAim = self.ui.aim
      self.h:bat({ swing = false })
      self:resume(scene, true)
      return nil
    end
    if tau > pp.tRel - 0.25 and tau < pp.tPlate + 0.2 then return 0.6 end
    return nil
  end
  if p.reason == "pitchsel" then
    if not self.directPitch then self:resume(scene) return nil end
    if not self:caughtUp(scene) then return nil end
    if not self.ui then
      local i = p.info
      local ars = i.arsenal or {}
      local k = 1
      for n, a in ipairs(ars) do if a.kind == self.lastType then k = n end end
      self.ui = { kind = "pitch", ars = ars, k = k, x = self.lastX or 0.7, z = self.lastZ or -0.5, stage = "aim", t = 0 }
    end
    local u = self.ui
    u.t = u.t + 1
    if u.stage == "aim" then
      local step = 0.05
      if held(playdate.kButtonLeft) then u.x = max(-1.8, u.x - step) elseif held(playdate.kButtonRight) then u.x = min(1.8, u.x + step) end
      if held(playdate.kButtonUp) then u.z = min(1.8, u.z + step) elseif held(playdate.kButtonDown) then u.z = max(-1.8, u.z - step) end
    else
      u.m = (u.m or 0) + 1
    end
    return nil
  end
  return nil
end

--- Simulating to the end: step everything (coaches answer every pause), then jump.
function Live:simFrame(scene)
  local t0 = playdate.getCurrentTimeMilliseconds()
  while playdate.getCurrentTimeMilliseconds() - t0 < 18 do
    if self.pause and self.pause.reason == "done" then break end
    self.pause = nil
    local evs = self:pump(200, 10)
    if self.prov then scene:dropLast() self.prov = nil end
    self:feed(scene, evs)
  end
  if self.pause and self.pause.reason == "done" and not self.jumped then
    self.jumped = true
    scene:skipToEnd()
    if self.leaveAfter then self:finish() end
  end
  return nil
end

-- Input --------------------------------------------------------------------------------------------------

function Live:input(scene, btn, change)
  local u = self.ui
  if self.menu then return self:menuInput(scene, btn, change) end
  if self.pause and self.pause.reason == "done" and self:caughtUp(scene) and (btn == "A" or btn == "B") then
    self:finish()
    return true
  end
  if u and u.kind == "dugout" then return self:dugoutInput(scene, btn) end
  if u and u.kind == "bat" and scene.tl and self.prov and scene:curBeatIndex() == self.prov.beat then return self:batInput(scene, btn, change) end
  if u and u.kind == "pitch" then return self:pitchInput(scene, btn, change) end
  if btn == "B" then self:openMenu() return true end
  return false
end

function Live:dugoutInput(scene, btn)
  local u = self.ui
  local list = u.sub or u.items
  local sel = u.sub and u.subSel or u.sel
  if btn == "up" then sel = (sel - 2) % #list + 1
  elseif btn == "down" then sel = sel % #list + 1
  elseif btn == "B" then
    if u.sub then u.sub = nil else self:openMenu() end
    return true
  elseif btn == "A" then
    local it = list[sel]
    if u.sub then
      self.h:decide({ kind = u.subKind, id = it.id })
      Sfx.select()
      self:resume(scene)
      return true
    end
    local p = self.pause
    if it.kind == "ph" then
      u.sub, u.subSel, u.subKind = {}, 1, "pinch_hit"
      for _, id in ipairs(p.info.bench or {}) do
        local q = P(id)
        u.sub[#u.sub + 1] = { id = id, label = (q and (q.pos .. " " .. PM.short(q) .. "  " .. PM.rate3(PM.avg(q.st.b))) or id) }
      end
      return true
    elseif it.kind == "pc" then
      u.sub, u.subSel, u.subKind = {}, 1, "pitch_change"
      for _, e in ipairs(p.info.pen or {}) do
        local q = P(e.id)
        u.sub[#u.sub + 1] = { id = e.id, label = (e.role or "") .. " " .. (q and PM.short(q) or e.id) .. (e.ready and "" or " (tired)") .. (q and string.format(" %.2f", PM.era(q.st.p)) or "") }
      end
      if #u.sub == 0 then u.sub = nil Toast.show("Nobody left in the pen.", "bad") end
      return true
    elseif it.kind == "sim" then
      self:simToEnd(false)
      return true
    end
    if it.kind ~= "none" then
      local ok, err = self.h:decide({ kind = it.kind, id = it.id, runner = it.runner })
      if ok == false then Toast.show(tostring(err), "bad") end
    end
    Sfx.select()
    self:resume(scene)
    return true
  else
    return true
  end
  if u.sub then u.subSel = sel else u.sel = sel end
  Sfx.focus()
  return true
end

function Live:batInput(scene, btn, change)
  local u = self.ui
  if btn == "left" or btn == "right" then u.power = not u.power Sfx.tick() return true end
  if btn == "crank" then u.aim = max(-1.6, min(1.6, u.aim + (change or 0) / 180)) return true end
  if btn == "up" or btn == "down" or btn == "AUp" then return true end
  if btn == "B" then self:openMenu() return true end
  if btn == "A" and not u.swung then
    local pb = scene.tl.beats[self.prov.beat]
    local pp = pb.plan.pitch
    local tau = scene.t - pb.start
    if tau < pp.tRel then return true end    -- not thrown yet
    u.swung = true
    local timing = max(-1, min(1, (tau - pp.tPlate) / 0.10))
    self.lastAim = u.aim
    self.h:bat({ swing = true, timing = timing, aim = u.aim, power = u.power })
    self.lastSwing = { timing = timing }
    self:resume(scene, true)
    return true
  end
  return true
end

function Live:pitchInput(scene, btn, change)
  local u = self.ui
  if btn == "B" then self:openMenu() return true end
  if u.stage == "aim" then
    if btn == "crank" then
      u.acc = (u.acc or 0) + (change or 0)
      if abs(u.acc) > 40 then u.k = (u.k - 1 + (u.acc > 0 and 1 or -1)) % #u.ars + 1 u.acc = 0 Sfx.tick() end
      return true
    end
    if btn == "A" then u.stage = "effort" u.m = 0 Sfx.select() return true end
    return true
  end
  if btn == "A" then
    -- the meter swings 0 -> 1 -> 0 once a second
    local ph = ((u.m or 0) % 30) / 30
    local eff = ph < 0.5 and ph * 2 or (1 - ph) * 2
    local a = u.ars[u.k]
    self.lastType, self.lastX, self.lastZ = a and a.kind, u.x, u.z
    self.h:pitch({ type = a and a.kind, x = u.x, z = u.z, effort = eff })
    Sfx.select()
    self:resume(scene)
    return true
  end
  return true
end

-- The dugout's own menu (B) -----------------------------------------------------------------------------

function Live:openMenu()
  self.menu = { sel = 1, items = {
    { "Resume", function() end },
    { "Call time (next batter)", function() self.callTime = true Toast.show("The manager will come out for the next batter.", nil) end },
    { "Batting: " .. (self.directBat and "you" or "coaches"), function() self.directBat = not self.directBat end },
    { "Pitching: " .. (self.directPitch and "you" or "coaches"), function() self.directPitch = not self.directPitch end },
    { "Sim to end", function() self:simToEnd(false) end },
    { "Leave (sims the rest)", function() self:simToEnd(true) end },
  } }
  Sfx.select()
end

function Live:menuInput(scene, btn, change)
  local m = self.menu
  if btn == "up" then m.sel = (m.sel - 2) % #m.items + 1 Sfx.focus()
  elseif btn == "down" then m.sel = m.sel % #m.items + 1 Sfx.focus()
  elseif btn == "B" then self.menu = nil Sfx.back()
  elseif btn == "A" then
    local it = m.items[m.sel]
    self.menu = nil
    it[2]()
    Sfx.select()
  end
  return true
end

function Live:simToEnd(leave)
  self.directBat, self.directPitch = false, false
  self.ui = nil
  self.simming = true
  self.leaveAfter = leave
  self.h:release()
end

-- The end ----------------------------------------------------------------------------------------------

function Live:finish()
  if self.finished then return end
  self.finished = true
  local L = self.L
  -- make sure the game is over (leaving early: the coaches finish it)
  local guard = 0
  while not self.h:done() and guard < 2000 do self.pause = nil self:pump(400) guard = guard + 1 end
  local res = self.h:result()
  PL.apply(L, self.g, res)
  PennantLive.cur = nil
  App.pop()   -- BallCast
  -- the other games, then the day's report
  PennantUI.Advance.open({ days = 1, afterLive = true })
end

-- Drawing --------------------------------------------------------------------------------------------------

local F = function() return UI.fonts end

local function panel(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 2, y + 2, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
end

local function sitLine(i, noCount)
  local b = i.bases
  local runners = {}
  for k = 1, 3 do if b[k] then runners[#runners + 1] = k == 1 and "1st" or (k == 2 and "2nd" or "3rd") end end
  return string.format("%s%d \u{2022} %d out%s%s", i.top and "Top " or "Bot ", i.inn, i.outs,
    noCount and "" or string.format(" \u{2022} %d-%d", i.balls or 0, i.strikes or 0),
    #runners > 0 and (" \u{2022} on " .. table.concat(runners, ",")) or "")
end

local function fatigueMeter(x, y, f, w)
  -- f: engine fatigue (0 fresh, >0.2 gassed) -> a 0..1 meter
  local v = min(1, (f or 0) / 0.3)
  gfx.drawRect(x, y, w, 7)
  local fw = floor((w - 2) * v)
  if fw > 0 then
    if v > 0.66 then gfx.fillRect(x + 1, y + 1, fw, 5) else gfx.setPattern(UI.pat.gray) gfx.fillRect(x + 1, y + 1, fw, 5) gfx.setColor(gfx.kColorBlack) end
  end
end

function Live:drawDugout()
  local u = self.ui
  local p = self.pause
  local i = p.info
  local list = u.sub or u.items
  local sel = u.sub and u.subSel or u.sel
  local x, w = 226, 170
  local h = 62 + #list * 15
  local y = max(20, 200 - h)
  panel(x, y, w, h)
  gfx.fillRect(x, y, w, 15)
  Text.draw(u.sub and (u.subKind == "pinch_hit" and "PINCH HIT" or "TO THE MOUND") or "DUGOUT", x + 5, y + 1, F().bold, "white")
  Text.draw(Text.ellipsize(sitLine(i, true), F().body, w - 8), x + 5, y + 17, F().body)
  local bat, pit = P(i.batter.id), P(i.pitcher.id)
  Text.draw(Text.ellipsize((bat and PM.short(bat) or "?") .. " (" .. (i.batter.bats or "") .. ") " .. (bat and PM.rate3(PM.avg(bat.st.b)) or ""), F().body, w - 10), x + 5, y + 30, F().body)
  Text.draw(Text.ellipsize("vs " .. (pit and PM.short(pit) or "?") .. " " .. (i.pitcher.pitches or 0) .. "p", F().body, w - 60), x + 5, y + 43, F().body)
  fatigueMeter(x + w - 50, y + 46, i.pitcher.fatigue, 44)
  local yy = y + 58
  for k, it in ipairs(list) do
    local on = k == sel
    if on then gfx.fillRect(x + 2, yy - 1, w - 4, 15) end
    Text.draw(Text.ellipsize(it.label, F().body, w - 14), x + 7, yy, on and F().bold or F().body, on and "white" or nil)
    yy = yy + 15
  end
  if not u.sub and u.sug and u.sug.kind ~= "none" then
    Text.draw("Coach: " .. u.sug.label, x + 5, y + h - 2, F().body)
  end
end

-- K-zone inset (normalised zone units: |x|, |z| <= 1 is a strike)
-- (on the right: BallCast's own K-zone history, spin cam and lower thirds live on the left)
local KX, KY, KW, KH = 294, 48, 100, 100
local SX, SZ = 20, 22
local function kzx(x) return floor(KX + KW / 2 + x * SX + 0.5) end
local function kzy(z) return floor(KY + 14 + KH / 2 - 7 - z * SZ + 0.5) end

local function kzFrame(title)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(KX, KY, KW, KH)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(KX + 2, KY + 12, KW - 4, KH - 14)
  Text.draw(title, KX + 4, KY - 1, F().bold, "white")
  gfx.setColor(gfx.kColorBlack)
  local x0, x1, y0, y1 = kzx(-1), kzx(1), kzy(1), kzy(-1)
  gfx.drawRect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
  gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
  for k = 1, 2 do
    local gx = x0 + floor((x1 - x0) * k / 3)
    local gy = y0 + floor((y1 - y0) * k / 3)
    gfx.drawLine(gx, y0, gx, y1)
    gfx.drawLine(x0, gy, x1, gy)
  end
  gfx.setColor(gfx.kColorBlack)
end

function Live:drawBat(scene, b, tau)
  local u = self.ui
  local pp = u.plan and u.plan.pitch
  kzFrame(u.power and "POWER SWING" or "AT BAT")
  -- the bat's plane at the aim height
  local ay = kzy(u.aim)
  gfx.fillRect(KX + 6, ay - 1, KW - 12, 3)
  gfx.fillCircleAtPoint(KX + 8, ay, 3)
  -- the ball on its way (BallCast's own flight)
  if pp and tau >= pp.tRel and tau <= pp.tPlate + 0.2 then
    local bx, by, bz = BallCast.Play.ballAt(u.plan, math.min(tau, pp.tPlate))
    if bx then
      local nx, nz = bx / 0.83, bz - 2.5
      local r = floor(2 + 4 * (1 - min(1, (by or 0) / 55)))
      local cx, cy = max(KX + 4, min(KX + KW - 4, kzx(nx))), max(KY + 14, min(KY + KH - 4, kzy(nz)))
      gfx.setColor(gfx.kColorWhite)
      gfx.fillCircleAtPoint(cx, cy, r + 1)
      gfx.setColor(gfx.kColorBlack)
      gfx.drawCircleAtPoint(cx, cy, r + 1)
      gfx.fillCircleAtPoint(cx, cy, max(1, r - 2))
    end
  end
  -- timing strip: a tick moves toward the notch (the ball at the plate)
  local ty = KY + KH + 3
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(KX, ty, KW, 9)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(KX, ty, KW, 9)
  if pp then
    local span = pp.tPlate + 0.15 - (pp.tRel - 0.2)
    local nxp = KX + floor((pp.tPlate - (pp.tRel - 0.2)) / span * KW)
    gfx.fillRect(nxp - 1, ty, 3, 9)
    if tau >= pp.tRel - 0.2 then
      local mx = KX + floor(min(1, (tau - (pp.tRel - 0.2)) / span) * KW)
      gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
      gfx.fillRect(KX + 1, ty + 2, max(0, mx - KX - 1), 5)
      gfx.setColor(gfx.kColorBlack)
    end
  end
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(KX, ty + 10, KW, 13)
  gfx.setColor(gfx.kColorBlack)
  Text.draw(u.power and "\u{25c0}\u{25b6} normal swing" or "\u{25c0}\u{25b6} power swing", KX + 2, ty + 10, F().body, nil)
end

function Live:drawPitch()
  local u = self.ui
  local i = self.pause.info
  kzFrame("PITCH")
  -- target cursor
  local cx, cy = kzx(u.x), kzy(u.z)
  gfx.drawCircleAtPoint(cx, cy, 6)
  gfx.drawLine(cx - 9, cy, cx - 3, cy) gfx.drawLine(cx + 3, cy, cx + 9, cy)
  gfx.drawLine(cx, cy - 9, cx, cy - 3) gfx.drawLine(cx, cy + 3, cx, cy + 9)
  -- the arsenal, two to a row under the zone (crank picks)
  local rows = (#u.ars + 1) // 2
  local px, py = KX, KY + KH
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(px, py, KW, rows * 13 + 2)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(px, py, KW, rows * 13 + 2)
  for k, a in ipairs(u.ars) do
    local on = k == u.k
    local cx, cy = px + 1 + ((k - 1) % 2) * 49, py + 1 + ((k - 1) // 2) * 13
    if on then gfx.fillRect(cx, cy, 49, 13) end
    Text.draw(a.kind .. " " .. (a.velo or ""), cx + 2, cy, on and F().bold or F().body, on and "white" or nil)
  end
  local ty = py + rows * 13 + 4
  if u.stage == "effort" then
    local ph = ((u.m or 0) % 30) / 30
    local eff = ph < 0.5 and ph * 2 or (1 - ph) * 2
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(KX, ty, KW, 11)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(KX, ty, KW, 11)
    gfx.setPattern(UI.pat.gray)
    gfx.fillRect(KX + floor(KW * 0.75), ty + 1, floor(KW * 0.2), 9)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(KX + 1, ty + 3, floor((KW - 2) * eff), 5)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(KX, ty + 12, KW, 13)
    gfx.setColor(gfx.kColorBlack)
    Text.draw("A: throw (effort)", KX + 2, ty + 12, F().body)
  else
    local bat = P(i.batter.id)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(KX, ty, KW, 26)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(Text.ellipsize((bat and PM.short(bat) or "") .. " " .. i.balls .. "-" .. i.strikes, F().body, KW - 4), KX + 2, ty, F().body)
    Text.draw("crank: pitch  A: set", KX + 2, ty + 12, F().body)
  end
  -- pitcher fatigue, in the title strip
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(KX + KW - 36, KY + 1, 34, 9)
  gfx.setColor(gfx.kColorBlack)
  fatigueMeter(KX + KW - 35, KY + 2, i.pitcher.fatigue, 32)
end

function Live:drawMenu()
  local m = self.menu
  local x, w = 120, 160
  local h = 18 + #m.items * 16
  local y = 120 - h // 2
  panel(x, y, w, h)
  gfx.fillRect(x, y, w, 15)
  Text.draw("TIME OUT", x + 5, y + 1, F().bold, "white")
  for k, it in ipairs(m.items) do
    local on = k == m.sel
    local yy = y + 17 + (k - 1) * 16
    if on then gfx.fillRect(x + 2, yy - 1, w - 4, 15) end
    Text.draw(it[1], x + 8, yy, on and F().bold or F().body, on and "white" or nil)
  end
end

function Live:drawFinal(scene)
  local L = self.L
  local res = self.finalRes
  if not res then res = self.h:result() self.finalRes = res end
  local x, y, w, h = 100, 150, 200, 70
  panel(x, y, w, h)
  gfx.fillRect(x, y, w, 15)
  Text.draw("FINAL", x + w // 2, y + 1, F().bold, "white", "center")
  Text.draw(self.g.a .. " " .. res.away.runs .. "    " .. self.g.h .. " " .. res.home.runs .. ((res.innings or 9) > 9 and ("  (" .. res.innings .. ")") or ""), x + w // 2, y + 18, F().head, nil, "center")
  local function nm(id) local p = id and L.players[id] return p and PM.short(p) or "-" end
  Text.draw("W " .. nm(res.W) .. "   L " .. nm(res.L) .. (res.S and ("   S " .. nm(res.S)) or ""), x + w // 2, y + 36, F().body, nil, "center")
  Text.draw("A: box score & the rest of the day", x + w // 2, y + 54, F().body, nil, "center")
end

--- Text-heavy panels are painted into an image when they change and blitted every frame.
function Live:cached(key, x, y, w, h, paint)
  local c = self.pcache
  if not c or c.key ~= key then
    local img = gfx.image.new(w + 3, h + 3, gfx.kColorClear)
    gfx.pushContext(img)
    gfx.setDrawOffset(-x, -y)
    paint()
    gfx.setDrawOffset(0, 0)
    gfx.popContext()
    c = { key = key, img = img }
    self.pcache = c
  end
  c.img:draw(x, y)
end

function Live:draw(scene, bi, b, tau)
  if self.simming and not self.jumped then
    panel(130, 100, 140, 24)
    Text.draw("SIMULATING...", 200, 105, F().bold, nil, "center")
  end
  local u = self.ui
  if u and u.kind == "dugout" and self:caughtUp(scene) then
    local list = u.sub or u.items
    local h = 62 + #list * 15
    self:cached("d" .. tostring(u.sub ~= nil) .. (u.sub and u.subSel or u.sel) .. ":" .. tostring(self.pause), 226, math.max(20, 200 - h), 172, h + 2, function() self:drawDugout() end)
  elseif u and u.kind == "bat" and self.prov and bi == self.prov.beat then self:drawBat(scene, b, tau)
  elseif u and u.kind == "pitch" and self:caughtUp(scene) then self:drawPitch() end
  if self.pause and self.pause.reason == "done" and b.kind == "end" and tau > 1.0 then self:drawFinal(scene) end
  if self.menu then
    local m = self.menu
    local h = 18 + #m.items * 16
    self:cached("m" .. m.sel, 120, 120 - h // 2, 163, h + 2, function() self:drawMenu() end)
  end
end
