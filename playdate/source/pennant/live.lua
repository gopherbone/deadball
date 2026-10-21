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
-- BallCast's K-ZONE inset gets the call with the count for a moment, and a ball in play a spray
-- chart (ballcast/tv/overlay.lua); our zone panels mark the at-bat's pitches (pennant/control.lua)
Live.pitchTrack = true
PennantLive.Live = Live

local function nid(s) return PEng.nid(s) end
local function P(id) local L = Pennant.L return L.players[nid(id) or -1] end
local function short(id) local p = P(id) return p and PM.short(p) or tostring(id) end

--- mode: "manage" (dugout calls, coaches bat and pitch) | "play" (you bat and pitch too), or nil
--- to keep the batting/pitching choices from the last game (settings.directBat / directPitch).
function PennantLive.start(mode)
  local L = Pennant.L
  local st = L.settings
  if mode then
    st.directBat, st.directPitch = mode == "play", mode == "play"
    st.playMode = mode
  elseif st.directBat == nil then
    st.directBat = st.playMode == "play"
    st.directPitch = st.playMode == "play"
  end
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
  local src = setmetatable({ L = L, g = g, h = h, pub = {}, mode = (st.directBat or st.directPitch) and "play" or "manage", directBat = st.directBat == true, directPitch = st.directPitch == true,
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
  -- each pitcher's mix this game (the Scout card)
  self.mix = self.mix or {}
  for _, e in ipairs(evs) do
    if e.k == "pa" then self.curPit = e.pit
    elseif e.k == "sub" and e.pos == "P" then self.curPit = e["in"]
    elseif e.k == "p" and self.curPit and not e.ibb then
      local m = self.mix[self.curPit] or {}
      self.mix[self.curPit] = m
      m[e.t] = (m[e.t] or 0) + 1
    end
  end
end

--- Answer the current pause (or not: nil = the coaches do it), step on, publish. Returns the
--- new events.
function Live:resume(scene, replaceProvisional)
  self.pause = nil
  self.ui = nil
  local evs = self:pump(30)
  if replaceProvisional then
    if not scene:dropLast() then print("[pennant] couldn't take back the provisional pitch") end
    self.prov = nil
  end
  self:feed(scene, evs)
  return evs
end
Live.resumeEvs = Live.resume

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

-- BallCast's lower third and "did you know" cards: plain baseball facts, not the online league's lore
function Live:flavor(id)
  local p = P(id)
  if not p then return "" end
  if p.pos == "P" then
    local s = p.st.p
    if (s.outs or 0) == 0 then return "HAS NOT PITCHED THIS SEASON." end
    return string.format("%d-%d, %.2f ERA THIS SEASON.", s.w or 0, s.l or 0, PM.era(s))
  end
  local s = p.st.b
  if (s.ab or 0) == 0 then return "FIRST AT-BAT OF THE SEASON." end
  return string.format("BATTING %s WITH %d HR AND %d RBI.", PM.rate3(PM.avg(s)), s.hr or 0, s.rbi or 0)
end

function Live:didYouKnow(tl, meta, bi, n)
  local L = self.L
  local c = PennantClubs.byAbbr[self.g.h]
  local facts = {
    c.park:upper() .. ": " .. c.fences[1] .. " DOWN THE LEFT FIELD LINE, " .. c.fences[3] .. " TO CENTER.",
    c.alt > 1000 and (c.park:upper() .. " SITS " .. c.alt .. " FEET UP. THE BALL CARRIES.") or (c.park:upper() .. " IS " .. c.alt .. " FEET ABOVE SEA LEVEL."),
  }
  for _, ab in ipairs({ self.g.a, self.g.h }) do
    local T = L.teams[ab]
    facts[#facts + 1] = string.format("THE %s ARE %d-%d, %s IN THE STANDINGS.", PUI.nick(ab):upper(), T.w, T.l, PUI.ord(PL.rank(L, ab)):upper())
  end
  return { text = facts[(n % #facts) + 1] }
end

-- Situations --------------------------------------------------------------------------------------------

function Live:caughtUp(scene, early)
  local tl = scene.tl
  return tl and scene.t >= tl.total - 0.05 - (early or 0) and not scene:timelinePending()
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
  self:updateHideKzone()
  -- (the rest of the league waits: BallCast has the frame; the Advance screen after the game
  -- plays the other games with a progress bar)
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
    -- (the manager's call comes up during the batter's walk-up, not half a second after it)
    if not self:caughtUp(scene, 0.55) then return nil end
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
    return self:batFrame(scene, bi, b, tau, p)
  end
  if p.reason == "pitchsel" then
    if not self.directPitch then self:resume(scene) return nil end
    return self:pitchFrame(scene, p)
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

-- Input: one whitelist gate -------------------------------------------------------------------------------
-- A Pennant game owns every input (Live.ownsInput: ballcast/scene.lua never falls through to its replay
-- controls: no crank scrub, no at-bat seek, no speed, no play/pause, no game log). Each state allows
-- only the inputs below; anything else is swallowed. See docs/PENNANT_INPUT_MAP.md.
-- (D-pad aiming in the Arcade panels and the B hold in Scout batting are polled in their own frames.)
-- The one replay control a watching state gets is A = the next camera shot (Live:nextShot): forward
-- only, never past the end of what the engine has fed (the next decision) or into a swing window.
Live.ownsInput = true
Live.INPUT_MAP = {
  menu = { up = true, down = true, A = true, B = true },                 -- time-out menu
  final = { A = true, B = true },                                        -- final card: on to the box score
  help = { A = true },                                                   -- how-to card: A dismisses
  dugout = { up = true, down = true, A = true, B = true },               -- manager's call (B: back / time out)
  bat_arcade = { A = true, AUp = true, B = true, crank = true },         -- swing / power swing, crank = cursor height
  bat_scout = { up = true, down = true, left = true, right = true, A = true, B = true },  -- approach; B tap/hold polled
  pitch_arcade = { A = true, B = true, crank = true },                   -- crank = pitch, A = meter, d-pad polled
  pitch_scout = { up = true, down = true, left = true, right = true, A = true, AUp = true, B = true, crank = true },
  play = { A = true, B = true },                                         -- ball in play / between batters: A = next shot, B = time out
}

--- A while watching: on to the next camera shot (BallCast's scene:nextShot), never past `limit`
--- (the provisional pitch's windup) or the end of what's been fed (the engine's next pause). Not
--- while a decision is up, the clock is held, or the game is simming or over.
function Live:nextShot(scene, limit)
  if self.menu or self.help or self.simming or self.finished then return false end
  if self.pause and self.pause.reason == "done" then return false end
  if self:idleDecision(scene) then return false end
  return scene:nextShot(limit)
end
Live.hint = "A NEXT SHOT  B TIME OUT"

--- (scene hook) Waiting on the player with the clock held: BallCast keeps the world alive (idle
--- puppets, slow decision angles). Not the time-out menu (the picture freezes under it) or the final.
function Live:idleDecision(scene)
  if self.menu or self.simming or self.finished then return false end
  if not self:caughtUp(scene) then return false end   -- (the walk-up still playing: let it)
  if self.pause and self.pause.reason == "done" then return false end
  if self.help then return true end
  local u = self.ui
  return u ~= nil and (u.kind == "dugout" or u.kind == "bat_scout" or u.kind == "pitch_arcade" or u.kind == "pitch_scout")
end

--- (scene hook) The strip of the screen our panels leave free, for BallCast's decision angles.
function Live:decisionFrame()
  local u = self.ui
  if u and u.kind == "dugout" then return 4, 224 end                 -- the dugout panel is on the right
  if u and (u.kind == "pitch_scout" or u.kind == "bat_scout") then return 96, 292 end  -- scouting card left, zone right
  if u and u.kind == "pitch_arcade" then return 4, 292 end                              -- zone right
  return 4, 396
end

--- (scene hook) Who's up while we wait (BallCast's id), for the idle batter and the decision angles.
function Live:idleBatter()
  local i = self.pause and self.pause.info
  return i and i.batter and i.batter.id or nil
end

--- The input state right now (a key of Live.INPUT_MAP).
function Live:inputState(scene)
  if self.menu then return "menu" end
  if self.pause and self.pause.reason == "done" then return "final" end
  if self.help then return "help" end
  local u = self.ui
  if u and Live.INPUT_MAP[u.kind] then return u.kind end
  return "play"
end

function Live:input(scene, btn, change)
  local st = self:inputState(scene)
  if PennantLive.onInput then PennantLive.onInput(st, btn) end
  if not Live.INPUT_MAP[st][btn] then return true end
  local u = self.ui
  if st == "menu" then self:menuInput(scene, btn, change) return true end
  if st == "final" then
    if self:caughtUp(scene) then self:finish() end
    return true
  end
  if st == "dugout" then self:dugoutInput(scene, btn) return true end
  if st == "play" then
    if btn == "A" then self:nextShot(scene) else self:openMenu() end
    return true
  end
  self:controlInput(scene, btn, change)
  return true
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

-- The dugout's own menu (B) -----------------------------------------------------------------------------

function Live:openMenu()
  self.menu = { sel = 1, items = {
    { "Resume", function() end },
    { "Call time (next batter)", function() self.callTime = true Toast.show("The manager will come out for the next batter.", nil) end },
    { self:controlLabel("bat"), function() self:cycleControl("bat") end },
    { self:controlLabel("pitch"), function() self:cycleControl("pitch") end },
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
  Text.draw(u.sub and (u.subKind == "pinch_hit" and "PINCH HIT" or "TO THE MOUND") or "DUGOUT", x + 5, Text.boxY(F().bold, y, 15), F().bold, "white")
  Text.draw(Text.ellipsize(sitLine(i, true), F().body, w - 8), x + 5, y + 17, F().body)
  local bat, pit = P(i.batter.id), P(i.pitcher.id)
  Text.draw(Text.ellipsize((bat and PM.short(bat) or "?") .. " (" .. (i.batter.bats or "") .. ") " .. (bat and PM.rate3(PM.avg(bat.st.b)) or ""), F().body, w - 10), x + 5, y + 30, F().body)
  Text.draw(Text.ellipsize("vs " .. (pit and PM.short(pit) or "?") .. " " .. (i.pitcher.pitches or 0) .. "p", F().body, w - 60), x + 5, y + 43, F().body)
  fatigueMeter(x + w - 50, y + 46, i.pitcher.fatigue, 44)
  local yy = y + 58
  for k, it in ipairs(list) do
    local on = k == sel
    if on then gfx.fillRect(x + 2, yy - 1, w - 4, 15) end
    local s = Text.ellipsize(it.label, F().body, w - 14)
    Text.draw(s, x + 7, Text.boxY(F().body, yy - 1, 15, s), on and F().bold or F().body, on and "white" or nil)
    yy = yy + 15
  end
  if not u.sub and u.sug and u.sug.kind ~= "none" then
    Text.draw("Coach: " .. u.sug.label, x + 5, y + h - 2, F().body)
  end
end

function Live:drawMenu()
  local m = self.menu
  local x, w = 120, 160
  local h = 18 + #m.items * 16
  local y = 120 - h // 2
  panel(x, y, w, h)
  gfx.fillRect(x, y, w, 15)
  Text.draw("TIME OUT", x + 5, Text.boxY(F().bold, y, 15), F().bold, "white")
  for k, it in ipairs(m.items) do
    local on = k == m.sel
    local yy = y + 17 + (k - 1) * 16
    if on then gfx.fillRect(x + 2, yy - 1, w - 4, 15) end
    Text.draw(it[1], x + 8, Text.boxY(F().body, yy - 1, 15, it[1]), on and F().bold or F().body, on and "white" or nil)
  end
end

--- The race after tonight (the result counted in before it's applied): "Up to 2nd, 1 GB",
--- "Still 5th, 3 GB", late in the year "MAGIC # 6" / "ELIM # 4".
function Live:raceLine(res)
  local L = self.L
  if L.phase ~= "season" then return nil end
  local T = L.teams[self.user]
  local before = PL.rank(L, self.user)
  local mine = self.side == "home" and res.home.runs or res.away.runs
  local them = self.side == "home" and res.away.runs or res.home.runs
  local won = mine > them
  if won then T.w = T.w + 1 else T.l = T.l + 1 end
  local ok, line = pcall(function()
    local r = PL.rank(L, self.user)
    local gb = T.gb or 0
    local left = PL.seasonGames(L) - (T.w + T.l)
    if left <= 20 then
      local m, e = PL.magic(L, self.user), PL.elimination(L, self.user)
      if m then return m <= 0 and "CLINCHED A PLAYOFF SPOT!" or ("Playoff MAGIC # " .. m .. ", " .. left .. " to play") end
      if e then return e <= 0 and "Eliminated." or ("ELIM # " .. e .. ", " .. left .. " to play") end
    end
    local verb = r < before and "Up to " or (r > before and "Down to " or "Still ")
    return verb .. PUI.ord(r) .. ", " .. (gb <= 0 and "in first" or (PL.gbText(gb) .. " GB"))
  end)
  if won then T.w = T.w - 1 else T.l = T.l - 1 end
  PL.standings(L)   -- (restore the GB column)
  return ok and line or nil
end

function Live:drawFinal(scene)
  local L = self.L
  local res = self.finalRes
  if not res then res = self.h:result() self.finalRes = res self.finalRace = self:raceLine(res) end
  local x, y, w, h = 90, 140, 220, 84
  panel(x, y, w, h)
  gfx.fillRect(x, y, w, 15)
  Text.draw("FINAL", x + w // 2, y + 1, F().bold, "white", "center")
  Text.draw(self.g.a .. " " .. res.away.runs .. "    " .. self.g.h .. " " .. res.home.runs .. ((res.innings or 9) > 9 and ("  (" .. res.innings .. ")") or ""), x + w // 2, y + 18, F().head, nil, "center")
  local function nm(id) local p = id and L.players[id] return p and PM.short(p) or "-" end
  Text.draw("W " .. nm(res.W) .. "   L " .. nm(res.L) .. (res.S and ("   S " .. nm(res.S)) or ""), x + w // 2, y + 36, F().body, nil, "center")
  if self.finalRace then
    gfx.fillRect(x + 2, y + 51, w - 4, 15)
    local s = Text.ellipsize(self.finalRace, F().bold, w - 10)
    Text.draw(s, x + w // 2, Text.boxY(F().bold, y + 51, 15, s), F().bold, "white", "center")
  end
  Text.draw("A: box score & the rest of the day", x + w // 2, y + 68, F().body, nil, "center")
end

--- BallCast holds the picture still under a static panel (the time-out menu, the final card).
function Live:freeze(scene, bi, b, tau)
  if self.menu then return true end
  return self.pause ~= nil and self.pause.reason == "done" and b.kind == "end" and tau > 1.25
end

--- Text-heavy panels are painted into an image when they change and blitted every frame.
function Live:cached(key, x, y, w, h, paint, slot)
  -- slots keep panels that show together (a pitch panel under the menu) from evicting each other
  self.pcaches = self.pcaches or {}
  slot = slot or "main"
  local c = self.pcaches[slot]
  if not c or c.key ~= key then
    local img = gfx.image.new(w + 3, h + 3, gfx.kColorClear)
    gfx.pushContext(img)
    gfx.setDrawOffset(-x, -y)
    paint()
    gfx.setDrawOffset(0, 0)
    gfx.popContext()
    c = { key = key, img = img }
    self.pcaches[slot] = c
  end
  c.img:draw(x, y)
end

function Live:draw(scene, bi, b, tau)
  if self.simming and not self.jumped then
    panel(130, 100, 140, 24)
    Text.draw("SIMULATING...", 200, 105, F().bold, nil, "center")
  end
  local u = self.ui
  if u and u.kind == "dugout" and self:caughtUp(scene, 0.55) then
    local list = u.sub or u.items
    local h = 62 + #list * 15
    self:cached("d" .. tostring(u.sub ~= nil) .. (u.sub and u.subSel or u.sel) .. ":" .. tostring(self.pause), 226, math.max(20, 200 - h), 172, h + 2, function() self:drawDugout() end)
  end
  self:drawControl(scene, bi, b, tau)
  if self.pause and self.pause.reason == "done" and b.kind == "end" and tau > 1.0 then
    self:cached("final", 90, 140, 223, 87, function() self:drawFinal(scene) end, "final")
  end
  if self.menu then
    local m = self.menu
    local h = 18 + #m.items * 16
    self:cached("m" .. m.sel, 120, 120 - h // 2, 163, h + 2, function() self:drawMenu() end, "menu")
  end
end
