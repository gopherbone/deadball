-- Game day and the calendar: the pregame screen (manage / play / simulate), advancing one or
-- many days with sliced background sims, the post-game report (box, around the league, arrows
-- that moved), and the season's end: awards night and the offseason report.

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

-- Day completion & the screens that follow it ------------------------------------------------------

--- Where the user's club is (the host city of its game on day d, or of the last game before).
function PennantUI.cityOn(L, d)
  for k = math.min(d, #L.sched), 1, -1 do
    local g = PL.gameFor(L, L.user, k)
    if g then return g.h end
  end
  return L.user
end

--- All of today's games are in: close the day, autosave, then the follow-up screens.
--- kind: "played" | "simmed" ; onReady(rep, travel) is called with the day report.
function PennantUI.closeDay(Y, noSave)
  local L = Pennant.L
  local from = PennantUI.cityOn(L, L.day)
  L.alerts = {}
  local rep = PL.finishDay(L, Y)
  rep.alerts = L.alerts
  local ng = PL.nextGame(L, L.user)
  local to = ng and ng.h or from
  local travel = nil
  if from ~= to and L.phase ~= "awards" then
    travel = { from = from, to = to }
    if L.settings.landmarks ~= false then travel.landmark = PLand.maybe(L, from, to) end
  end
  if not noSave then Pennant.autosave() end
  return rep, travel
end

--- After the day's report: travel animation, the week's training report, back to the hub.
function PennantUI.followUps(travel)
  local L = Pennant.L
  local function training()
    if L.weekRep and not L.weekRep.seen then
      PennantUI.TrainingResults.open({ onDone = function() Pennant.toHub() end })
    else
      Pennant.toHub()
    end
  end
  if travel and (L.settings.travel ~= false or travel.landmark) then
    PennantUI.Travel.open({ from = travel.from, to = travel.to, landmark = travel.landmark, onDone = training })
  else
    training()
  end
end

-- Pregame ---------------------------------------------------------------------------------------------

local GameDay = PUI.define({ title = "Game day", hint = "A: choose how to play today's game" })
PennantUI.GameDay = GameDay

function GameDay:resume(r) Page.resume(self, r) self:render(true) end

function GameDay:layout(Lb)
  local L = Pennant.L
  local g = PL.gameFor(L, L.user)
  if not g then return end
  local T = L.teams[L.user]
  PRoster.validate(L, T)
  local opp = g.h == L.user and g.a or g.h
  -- matchup header
  PUI.logo(g.a, 6, 4, 32)
  Text.draw(PUI.teamName(g.a), 44, 4, UI.fonts.bold)
  Text.draw(L.teams[g.a].w .. "-" .. L.teams[g.a].l, 44, 18, UI.fonts.body)
  Text.draw("at", 200, 12, UI.fonts.head, nil, "center")
  PUI.logo(g.h, 362, 4, 32)
  Text.draw(PUI.teamName(g.h), 356, 4, UI.fonts.bold, nil, "right")
  Text.draw(L.teams[g.h].w .. "-" .. L.teams[g.h].l, 356, 18, UI.fonts.body, nil, "right")
  Text.draw(PennantClubs.byAbbr[g.h].park .. " \u{2022} " .. PL.date(L), 200, 40, UI.fonts.body, nil, "center")
  -- the two lineups
  local function col(abbr, x)
    local TT = L.teams[abbr]
    PRoster.validate(L, TT)
    local sp = PRoster.starter(L, TT)
    local y = 58
    local p = L.players[sp]
    Text.draw("SP " .. PM.short(p) .. "  " .. PUI.pitLine(p), x, y, UI.fonts.bold)
    if abbr == L.user then PUI.arrow(x + 180, y + 1, p.cond) end
    y = y + 15
    for i, id in ipairs(TT.order) do
      local q = L.players[id]
      Text.draw(i .. ". " .. (TT.field[id] or "DH") .. " " .. Text.ellipsize(PM.short(q), UI.fonts.body, 92), x, y, UI.fonts.body)
      Text.draw(PM.rate3(PM.avg(q.st.b)), x + 150, y, UI.fonts.body)
      if abbr == L.user then PUI.arrow(x + 180, y + 1, q.cond) end
      y = y + 13
    end
    return y
  end
  col(g.a, 6)
  col(g.h, 204)
  gfx.drawLine(200, 56, 200, 190)
  local probs = PennantUI.lineupProblems(L, T)
  -- worn-out regulars: worth a day off
  for _, id in ipairs(T.order) do
    local q = L.players[id]
    if (q.fat or 0) >= 70 then probs[#probs + 1] = PM.short(q) .. " is worn out (fatigue " .. math.floor(q.fat) .. ")" end
  end
  local by = 190
  if #probs > 0 then
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(4, by - 14, 390, 13)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(Text.ellipsize("! " .. probs[1], UI.fonts.bold, 386), 6, by - 14, UI.fonts.bold)
  end
  by = by + 2
  Lb:button("Manage", 4, by, 92, 18, function() PennantLive.start("manage") end, { id = "manage", hint = "Watch it in BallCast and make the dugout's calls (steals, bunts, pitching changes...)" })
  local s = L.settings
  Lb:button("Play", 100, by, 92, 18, function() PennantLive.start("play") end, { id = "play",
    hint = "Bat and pitch yourself: " .. PScheme.NAME[s.batScheme or "arcade"] .. " / " .. PScheme.NAME[s.pitchScheme or "arcade"] .. " (Options; or time out in the game)" })
  Lb:button("Simulate", 196, by, 92, 18, function() PennantUI.Advance.open({ days = 1, fromGameDay = true }) end, { id = "sim", hint = "The coaches play it out; box score after" })
  Lb:button("Lineup", 292, by, 96, 18, function() PennantUI.Lineup.open({}) end, { id = "lineup", hint = "Change the order, positions, rotation" })
  Lb:mark(PUI.VIEW_H - 2)
end

function GameDay:initialFocus() for i, l in ipairs(self.links) do if l.id == "manage" then return i end end return 1 end

-- Advance (simulate days) ------------------------------------------------------------------------------

local Advance = { opaque = true }
Advance.__index = Advance
PennantUI.Advance = Advance

--- args: { days = n } | { untilOff = true } | { untilPhase = "playoffs"|"awards" }
function Advance.open(args)
  local s = setmetatable({}, Advance)
  App.push(s, args)
  return s
end

function Advance:enter(args)
  self.args = args
  self.days = 0
  self.w, self.l = 0, 0
  self.t = 0
  self.stopNote = nil
  self.lines = {}
  self.state = "day"
  self:queueDay()
end

function Advance:queueDay()
  local L = Pennant.L
  local day = PL.today(L)
  self.dayGames = day and #day.games or 0
  PJobs.simDay(L)
end

function Advance:wantMore()
  local L = Pennant.L
  local a = self.args
  if self.stopNote then return false end
  if L.phase == "awards" then return false end
  if a.days then return self.days < a.days end
  if a.untilOff then
    local day = PL.today(L)
    return not (self.lastOff) and day ~= nil
  end
  if a.untilPhase then return L.phase ~= a.untilPhase end
  return false
end

--- The day's close, spread over frames: PL.finishDay yields between clubs.
function Advance:startClose()
  local L = Pennant.L
  local today = PL.today(L)
  self.closeMine = PL.gameFor(L, L.user)
  self.lastOff = today and today.off
  self.state = "close"
  self.closeCo = coroutine.create(function()
    local more = true
    -- (the autosave waits for the end of a multi-day run)
    local rep, travel = PennantUI.closeDay(function() self:Y() end, true)
    return rep, travel
  end)
end

function Advance:Y()
  if playdate.getCurrentTimeMilliseconds() - self.t0 >= self.budget then coroutine.yield() end
end

function Advance:afterClose(rep, travel)
  local L = Pennant.L
  local mine = self.closeMine
  self.travel = travel or self.travel
  self.days = self.days + 1
  if mine and mine.done then
    local me = mine.h == L.user and mine.hs or mine.as
    local them = mine.h == L.user and mine.as or mine.hs
    if me > them then self.w = self.w + 1 else self.l = self.l + 1 end
    self.lastBox = mine.box
    self.lines[#self.lines + 1] = PL.date(L, L.day - 1) .. "  " .. (me > them and "W " or "L ") .. me .. "-" .. them .. (mine.h == L.user and " vs " or " at ") .. (mine.h == L.user and mine.a or mine.h)
  end
  self.rep = rep
  for _, a in ipairs(rep.alerts or {}) do
    if a.kind == "inj" and not self.args.days then
      local p = L.players[a.id]
      self.stopNote = "Stopped: " .. (p and PM.name(p) or "a player") .. " got hurt."
    end
  end
  if self:wantMore() then
    self.state = "day"
    self:queueDay()
  else
    self.state = "saving"
    Pennant.autosave()
  end
  self.dirtyText = true
end

function Advance:update()
  local L = Pennant.L
  local fs = playdate.getCurrentTimeMilliseconds()
  self:work()
  self:draw()
  local d = playdate.getCurrentTimeMilliseconds() - fs
  if d > 40 and PUI.PROF then print(string.format("[pnadv] %d ms frame (state %s)", d, tostring(self.state))) end
end

function Advance:prof(what, t0)
  local d = playdate.getCurrentTimeMilliseconds() - t0
  if d > 25 and PUI.PROF then print(string.format("[pnadv] %s %d ms", what, d)) end
end

function Advance:work()
  local L = Pennant.L
  self.t = self.t + 1
  self.t0 = playdate.getCurrentTimeMilliseconds()
  -- ~18 ms of work a frame (the device runs Lua ~5-10x slower than the Simulator)
  self.budget = 15
  local guard = 0
  while playdate.getCurrentTimeMilliseconds() - self.t0 < self.budget and guard < 50 do
    guard = guard + 1
    local ts = playdate.getCurrentTimeMilliseconds()
    if self.state == "day" then
      PJobs.tick(self.budget - (playdate.getCurrentTimeMilliseconds() - self.t0))
      self:prof("jobs", ts)
      if not PJobs.busy() then self:startClose() end
    elseif self.state == "close" then
      local ok, rep, travel = coroutine.resume(self.closeCo)
      self:prof("close slice", ts)
      if not ok then print("[pennant] day close failed: " .. tostring(rep)) self.state = "done" break end
      if coroutine.status(self.closeCo) == "dead" then
        self.closeCo = nil
        local ta = playdate.getCurrentTimeMilliseconds()
        self:afterClose(rep, travel)
        self:prof("after close", ta)
      else break end
    elseif self.state == "saving" then
      PJobs.tick(self.budget - (playdate.getCurrentTimeMilliseconds() - self.t0))
      if not PJobs.busy() then self.state = "done" self.dirtyText = true end
      break
    else
      break
    end
  end
end

--- The window is painted once; the changing lines are re-rendered only when they change.
function Advance:draw()
  local L = Pennant.L
  if not self.bg then
    self.bg = gfx.image.new(400, 240, gfx.kColorWhite)
    gfx.pushContext(self.bg)
    Draw.tile(0, 0, 400, 240, "light")
    self.ix, self.iy, self.iw, self.ih = Draw.window(50, 34, 300, 170, "Pennant '96")
    gfx.popContext()
  end
  self.bg:draw(0, 0)
  local ix, iy, iw, ih = self.ix, self.iy, self.iw, self.ih
  local key
  if self.state ~= "done" then
    key = PL.date(L, math.min(L.day, #L.sched)) .. self.days .. self.w .. self.l .. self.state
  else
    key = "done" .. #self.lines .. tostring(self.stopNote)
  end
  if key ~= self.textKey then
    self.textKey = key
    self.textImg = gfx.image.new(iw, ih, gfx.kColorClear)
    gfx.pushContext(self.textImg)
    if self.state ~= "done" then
      Text.draw(PL.dateLong(L, math.min(L.day, #L.sched)), iw // 2, 12, UI.fonts.head, nil, "center")
      Text.draw(self.days .. " day" .. (self.days == 1 and "" or "s") .. " done \u{2022} you went " .. self.w .. "-" .. self.l, iw // 2, 76, UI.fonts.body, nil, "center")
      Text.draw(self.state == "saving" and "Saving..." or (self.state == "close" and "Closing the books..." or "Playing the games..."), iw // 2, 96, UI.fonts.body, nil, "center")
    else
      Text.draw("You went " .. self.w .. "-" .. self.l .. " over " .. self.days .. " day" .. (self.days == 1 and "" or "s"), iw // 2, 6, UI.fonts.head, nil, "center")
      local y = 26
      for i = math.max(1, #self.lines - 6), #self.lines do Text.draw(self.lines[i], 14, y, UI.fonts.body) y = y + 13 end
      if self.stopNote then Text.draw(self.stopNote, 14, y + 2, UI.fonts.bold) end
      Text.draw("A: continue", iw - 8, ih - 15, UI.fonts.body, nil, "right")
    end
    gfx.popContext()
  end
  self.textImg:draw(ix, iy)
  if self.state ~= "done" then
    Draw.throbber(ix + 30, iy + 60, 8, self.t, true)
    local done = self.dayGames - #PL.pending(L)
    Draw.progress(ix + 50, iy + 54, iw - 80, 10, self.state == "day" and (self.dayGames > 0 and done / self.dayGames or 1) or 1, "gray")
  end
end

function Advance:AButtonDown()
  if self.state ~= "done" then return end
  local L = Pennant.L
  Sfx.select()
  -- a single simulated game: its report first
  if self.args.days == 1 and self.lastBox then
    App.pop()
    PennantUI.PostGame.open({ box = self.lastBox, rep = self.rep, travel = self.travel })
    return
  end
  App.pop()
  PennantUI.followUps(self.travel)
end
function Advance:BButtonDown()
  if self.state == "done" then self:AButtonDown() else
    -- stop after today
    self.args = { days = 0 }
    self.stopNote = "Stopped."
  end
end

-- Post-game report ------------------------------------------------------------------------------------

local PostGame = PUI.define({ title = "Final", hint = "A: continue  crank: scroll" })
PennantUI.PostGame = PostGame

function PostGame:init(args)
  self.box = args.box
  self.rep = args.rep
  self.travel = args.travel
  local L = Pennant.L
  local b = L.boxes[self.box]
  if b then
    local me = b.h == L.user and b.home.r or b.away.r
    local them = b.h == L.user and b.away.r or b.home.r
    Sfx.stinger(me > them and "bet_won" or "bet_lost")
  end
end

function PostGame:layout(Lb)
  local L = Pennant.L
  local b = L.boxes[self.box]
  local y = 2
  if b then
    local me = b.h == L.user and b.home.r or b.away.r
    local them = b.h == L.user and b.away.r or b.home.r
    Text.draw((me > them and "WIN " or "LOSS ") .. me .. "-" .. them, 4, y, UI.fonts.big)
    Text.draw(PUI.teamName(b.a) .. " at " .. PUI.teamName(b.h), 150, y + 6, UI.fonts.body)
    y = PennantUI.lineScore(L, b, 4, y + 26)
    local function nm(id) local p = id and L.players[id] return p and (PM.short(p) .. " (" .. PUI.pitLine(p) .. ")") or "-" end
    Text.draw("W " .. nm(b.W), 4, y, UI.fonts.body)
    Text.draw("L " .. nm(b.L), 200, y, UI.fonts.body)
    y = y + 13
    if b.S then Text.draw("S " .. nm(b.S), 4, y, UI.fonts.body) y = y + 13 end
  end
  -- around the league
  y = PUI.head(Lb, "Around the league", 4, y + 4, 388)
  local day = L.sched[L.day - 1]
  local col = 0
  for _, g in ipairs(day and day.games or {}) do
    if g.done and not (g.h == L.user or g.a == L.user) then
      local x = 4 + col * 130
      Text.draw(g.a .. " " .. g.as .. "  " .. g.h .. " " .. g.hs .. ((g.inn or 9) > 9 and (" (" .. g.inn .. ")") or ""), x, y, UI.fonts.body)
      col = col + 1
      if col == 3 then col = 0 y = y + 13 end
    end
  end
  if col > 0 then y = y + 13 end
  -- arrows that moved
  local ch = self.rep and self.rep.changes or {}
  y = PUI.head(Lb, "Condition", 4, y + 4, 388)
  if #ch == 0 then Text.draw("No changes.", 8, y, UI.fonts.body) y = y + 14 end
  col = 0
  for i, c in ipairs(ch) do
    if i > 12 then break end
    local p = L.players[c.id]
    local x = 4 + col * 196
    Text.draw(Text.ellipsize(PM.short(p), UI.fonts.body, 110), x + 4, y, UI.fonts.body)
    PUI.arrow(x + 120, y + 1, c.from)
    Text.draw("\u{25b6}", x + 140, y, UI.fonts.body)
    PUI.arrow(x + 154, y + 1, c.to)
    col = col + 1
    if col == 2 then col = 0 y = y + 15 end
  end
  if col > 0 then y = y + 15 end
  for _, a in ipairs(self.rep and self.rep.alerts or {}) do
    if a.kind == "inj" then
      local p = L.players[a.id]
      if p and p.inj then
        PUI.cross(6, y + 1)
        Text.draw(PM.name(p) .. ": " .. p.inj.k .. ", back " .. PL.date(L, L.day + p.inj.d), 22, y, UI.fonts.bold)
        y = y + 15
      end
    end
  end
  Lb:button("Continue", 4, y + 6, 90, 18, function() self:continue() end, { id = "go", hint = "On with the season" })
  if b then Lb:button("Box score", 100, y + 6, 90, 18, function() PennantUI.Box.open({ key = self.box }) end, { id = "box", hint = "Every line" }) end
  Lb:mark(y + 28)
end

function PostGame:initialFocus() for i, l in ipairs(self.links) do if l.id == "go" then return i end end return 1 end
function PostGame:continue() PennantUI.followUps(self.travel) end
function PostGame:goBack() self:continue() end

-- Awards night ------------------------------------------------------------------------------------------

local Awards = PUI.define({ title = "Awards night", hint = "A: on to the offseason" })
PennantUI.Awards = Awards

function Awards:init()
  Sfx.music("stars_stripes", { fade = 1 })
end

function Awards:layout(Lb)
  local L = Pennant.L
  local A = L.awardsRes or PL.awards(L)
  local y = 2
  Draw.wordart(L.year .. " PENNANT", 200, y, UI.fonts.slab)
  y = y + 34
  PUI.logo(L.champ, 120, y, 32)
  Text.draw(PUI.teamName(L.champ), 158, y + 2, UI.fonts.head)
  Text.draw("over the " .. PUI.teamName(L.runnerUp or ""), 158, y + 18, UI.fonts.body)
  y = y + 40
  local function award(label, id, line, x)
    local p = id and L.players[id]
    if not p then return end
    Faces.draw("face:" .. p.face, x, y, 48)
    Text.draw(label, x + 54, y, UI.fonts.bold)
    Text.draw(Text.ellipsize(PM.name(p), UI.fonts.body, 70), x + 54, y + 14, UI.fonts.body)
    Text.draw(p.team, x + 54, y + 27, UI.fonts.body)
    Text.draw(Text.ellipsize(line(p), UI.fonts.body, 74), x + 54, y + 40, UI.fonts.body)
  end
  award("MVP", A.mvp, function(p) return PUI.batLine(p) end, 4)
  award("PITCHER", A.cy, function(p) return PUI.pitLine(p) end, 136)
  award("ROOKIE", A.roy, function(p) return p.pos == "P" and PUI.pitLine(p) or PUI.batLine(p) end, 268)
  y = y + 66
  y = PUI.head(Lb, "League leaders", 4, y, 388)
  local names = { avg = "AVG", hr = "HR", rbi = "RBI", sb = "SB", w = "W", era = "ERA", pk = "K", sv = "SV" }
  local col = 0
  for _, k in ipairs({ "avg", "hr", "rbi", "sb", "w", "era", "pk", "sv" }) do
    local l = A.lead[k]
    if l then
      local p = L.players[l.id]
      local x = 4 + col * 196
      Text.draw(names[k], x, y, UI.fonts.bold)
      Text.draw((p and PM.short(p) or "?") .. " " .. (p and p.team or "") .. "  " .. PL.leaderText(k, l.v), x + 34, y, UI.fonts.body)
      col = col + 1
      if col == 2 then col = 0 y = y + 13 end
    end
  end
  Lb:button("Begin the offseason", 110, y + 8, 180, 20, function()
    PUI.busy("The offseason", function()
      PL.offseason(L)
      PSave.saveNow(L, L.slot)
    end)
    playdate.frameTimer.performAfterDelay(4, function() PennantUI.Offseason.open({}) end)
  end, { id = "go", hint = "Aging, retirements, rookies, then a new season" })
  Lb:mark(y + 32)
end

function Awards:initialFocus() for i, l in ipairs(self.links) do if l.id == "go" then return i end end return 1 end

-- Offseason report ---------------------------------------------------------------------------------------

local Off = PUI.define({ title = "Offseason", hint = "A: start the new season" })
PennantUI.Offseason = Off

function Off:layout(Lb)
  local L = Pennant.L
  local rep = L.offRep or { retired = {}, rookies = {}, grew = {}, declined = {} }
  local y = 2
  Text.draw("Spring training, " .. L.year, 4, y, UI.fonts.big)
  y = y + 28
  y = PUI.head(Lb, "Retired", 4, y, 388)
  if #rep.retired == 0 then Text.draw("Nobody hung them up.", 8, y, UI.fonts.body) y = y + 14 end
  for _, r in ipairs(rep.retired) do Text.draw(r.pos .. "  " .. r.name .. ", " .. r.age .. " (" .. (r.mlYrs or 0) .. " big-league seasons)", 8, y, UI.fonts.body) y = y + 13 end
  y = PUI.head(Lb, "Improved over the winter", 4, y + 4, 388)
  for _, g in ipairs(rep.grew) do
    local p = L.players[g.id]
    if p then Text.draw(p.pos .. "  " .. PM.name(p) .. "  +" .. g.d .. " OVR (now " .. PM.ovr(p) .. ")", 8, y, UI.fonts.body) y = y + 13 end
  end
  if #rep.grew == 0 then Text.draw("No big jumps.", 8, y, UI.fonts.body) y = y + 13 end
  y = PUI.head(Lb, "Slowing down", 4, y + 4, 388)
  for _, g in ipairs(rep.declined) do
    local p = L.players[g.id]
    if p then Text.draw(p.pos .. "  " .. PM.name(p) .. ", " .. p.age .. "  " .. g.d .. " OVR", 8, y, UI.fonts.body) y = y + 13 end
  end
  if #rep.declined == 0 then Text.draw("Everyone held up.", 8, y, UI.fonts.body) y = y + 13 end
  y = PUI.head(Lb, "New prospects (farm)", 4, y + 4, 388)
  for _, id in ipairs(rep.rookies) do
    local p = L.players[id]
    if p then
      Text.draw((p.pos == "P" and p.role or p.pos) .. "  " .. PM.name(p) .. ", " .. p.age .. "  " .. string.rep("\u{2605}", PM.potStars(p)), 8, y, UI.fonts.body)
      y = y + 13
    end
  end
  Lb:button("Opening Day " .. L.year, 120, y + 8, 160, 20, function() Pennant.toHub() Pennant.hub:render(true) end, { id = "go", hint = "A new season" })
  Lb:mark(y + 32)
end

function Off:initialFocus() for i, l in ipairs(self.links) do if l.id == "go" then return i end end return 1 end
