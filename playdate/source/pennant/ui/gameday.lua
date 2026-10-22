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
  PL.maybeTradeCall(L)
  -- (the hub's LAST NIGHT panel shows what moved on the last game day)
  if rep.mine then L.lastRep = { changes = rep.changes, alerts = rep.alerts, day = rep.day } end
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
    PennantUI.frontPageFollowUp(function() PennantUI.trainerFollowUp(function() PennantUI.callFollowUp(function()
      if L.weekRep and not L.weekRep.seen then
        PennantUI.TrainingResults.open({ onDone = function() Pennant.toHub() end })
      else
        Pennant.toHub()
      end
    end) end) end)
  end
  if travel and (L.settings.travel ~= false or travel.landmark) then
    PennantUI.Travel.open({ from = travel.from, to = travel.to, landmark = travel.landmark, onDone = training })
  else
    training()
  end
end

-- Pregame ---------------------------------------------------------------------------------------------

local GameDay = PUI.define({ title = function(self)
  if not self.onChoice then return "Game day" end
  return (self.why == "featured" or self.why == "playoff") and "\u{2605} Tonight's big game" or "Tonight's game: live"
end, hint = "A: choose how to play today's game" })
PennantUI.GameDay = GameDay

--- args.onChoice(mode): the week run's pregame (any game that isn't SIM: the featured one, a
--- playoff game, one picked on the Week screen's strip or in the Office): mode = "watch" | "bat" |
--- "pitch" | "both" | "sim"; B = let it sim. args.mode: the mode it was set to (the selector starts
--- there; left/right change it, A goes with it). args.featured: why it's live (PWeek.modeFor).
function GameDay:init(args)
  self.onChoice = args and args.onChoice
  self.why = args and args.featured
  self.mode = (args and args.mode) or PWeek.lastLive(Pennant.L)
end

--- Go with the selected mode (SIM: the coaches play it).
function GameDay:go()
  local m = self.mode
  if self.onChoice then self.onChoice(m) return end
  if m == "sim" then PennantUI.Advance.open({ days = 1, fromGameDay = true }) else PennantLive.start(m) end
end

function GameDay:goBack()
  if self.onChoice then Sfx.back() self.onChoice("sim") return end
  Page.goBack(self)
end

function GameDay:resume(r) Page.resume(self, r) self:render(true) end

function GameDay:layout(Lb)
  local L = Pennant.L
  local g = PL.gameFor(L, L.user)
  if not g then return end
  local T = L.teams[L.user]
  local vs = PL.todayCard(L, L.user)
  PRoster.validate(L, T)
  local opp = g.h == L.user and g.a or g.h
  -- matchup header on one line (16 px logos), then park / date
  local function club(ab) return Text.fitTeam(PennantClubs.byAbbr[ab], 120, UI.fonts.bold) .. " " .. L.teams[ab].w .. "-" .. L.teams[ab].l end
  PUI.logo(g.a, 4, 2, 16)
  Text.draw(club(g.a), 24, 3, UI.fonts.bold)
  Text.draw("at", 200, 3, UI.fonts.bold, nil, "center")
  PUI.logo(g.h, 376, 2, 16)
  Text.draw(club(g.h), 372, 3, UI.fonts.bold, nil, "right")
  Text.draw(Text.ellipsize(PennantClubs.byAbbr[g.h].park .. " \u{2022} " .. PL.date(L), UI.fonts.body, 380), 200, 19, UI.fonts.body, nil, "center")
  gfx.drawLine(4, 34, 392, 34)
  -- the two lineups
  local function col(abbr, x)
    local TT = L.teams[abbr]
    PRoster.validate(L, TT)
    local sp = PRoster.starter(L, TT)
    local y = 37
    local p = L.players[sp]
    local hx = x + PUI.handChip(x, y + 1, p.throws)
    Text.draw(Text.ellipsize("SP " .. PM.short(p) .. "  " .. PUI.pitLine(p), UI.fonts.bold, 166), hx, y, UI.fonts.bold)
    if abbr == L.user then PUI.arrow(x + 180, y + 1, p.cond) end
    y = y + 15
    for i, id in ipairs(TT.order) do
      local q = L.players[id]
      Text.draw(i .. ". " .. (TT.field[id] or "DH") .. " " .. Text.ellipsize(PM.short(q), UI.fonts.body, 86), x, y, UI.fonts.body)
      PUI.handChip(x + 132, y + 1, q.bats)
      Text.draw(PM.rate3(PM.avg(q.st.b)), x + 148, y, UI.fonts.body)
      if abbr == L.user then PUI.arrow(x + 180, y + 1, q.cond) end
      y = y + 13
    end
    return y
  end
  col(g.a, 6)
  col(g.h, 204)
  gfx.drawLine(200, 36, 200, 168)
  local probs = PennantUI.lineupProblems(L, T)
  -- worn-out regulars: worth a day off
  for _, id in ipairs(T.order) do
    local q = L.players[id]
    if (q.fat or 0) >= 70 then probs[#probs + 1] = PM.short(q) .. " is worn out (fatigue " .. math.floor(q.fat) .. ")" end
  end
  local by = 188
  if #probs > 0 then
    Text.draw(Text.ellipsize("! " .. probs[1], UI.fonts.bold, 386), 6, by - 16, UI.fonts.bold)
  end
  local oc = self.onChoice
  if oc and self.why and #probs == 0 then
    local WHY = { featured = "\u{2605} The week's big one. Play it, or let the coaches have it.", playoff = "\u{2605} A playoff game. Every one counts.",
      all = "\u{25b6} Every game is live (the Office's default).", picked = "\u{25b6} You set this one to play live." }
    Text.draw(WHY[self.why] or WHY.picked, 6, by - 16, UI.fonts.bold)
  end
  -- the mode selector: left/right change it, A goes with it
  local s = L.settings
  local m = self.mode
  local how = PWeek.MODE_DESC[m]
  if m == "bat" or m == "both" then how = how .. " (" .. PScheme.NAME[s.batScheme or "arcade"] .. (m == "both" and (" / " .. PScheme.NAME[s.pitchScheme or "arcade"]) or "") .. ")"
  elseif m == "pitch" then how = how .. " (" .. PScheme.NAME[s.pitchScheme or "arcade"] .. ")" end
  local label = "\u{25c0} " .. (m == "sim" and "SIM IT" or ("PLAY: " .. PWeek.MODE_NAME[m])) .. " \u{25b6}"
  Lb:button(label, 4, by, 188, 18, function() self:go() end, { id = "mode",
    hint = "A: " .. how .. "   \u{25c0}\u{25b6}: watch / bat / pitch / both / sim",
    data = { adj = function(d) self.mode = PWeek.cycleMode(self.mode, d) end } })
  Lb:button("Simulate", 196, by, 92, 18, function() if oc then oc("sim") else PennantUI.Advance.open({ days = 1, fromGameDay = true }) end end, { id = "sim", hint = oc and "B: the coaches play it out; the week goes on" or "The coaches play it out" })
  Lb:button("Lineup", 292, by, 96, 18, function() PennantUI.Lineup.open({}) end, { id = "lineup", hint = "Order, positions, platoon cards, staff" })
  Lb:mark(PUI.VIEW_H - 2)
end

function GameDay:initialFocus() for i, l in ipairs(self.links) do if l.id == "mode" then return i end end return 1 end

-- Advance (simulate days) ------------------------------------------------------------------------------

local Advance = { opaque = true }
Advance.__index = Advance
PennantUI.Advance = Advance

--- Jump to where a wire line / stop / to-do says to go (over the hub).
function PennantUI.jump(j)
  if not j then return end
  local L = Pennant.L
  if j.screen == "training" then PennantUI.Training.open({ focusId = j.id })
  elseif j.screen == "lineup" then PennantUI.Lineup.open({})
  elseif j.screen == "staff" then PennantUI.Lineup.open({ tab = "pit" })
  elseif j.screen == "farm" then PennantUI.Farm.open({ tab = "farm" })
  elseif j.screen == "card" and L.players[j.id] then PennantUI.Card.open({ list = { L.players[j.id] }, i = 1 })
  elseif j.screen == "box" and j.id and L.boxes[j.id] then PennantUI.Box.open({ key = j.id })
  elseif j.screen == "report" and L.weekRep then PennantUI.TrainingResults.open({})
  elseif j.screen == "call" and L.tradeCall and not L.tradeCall.shown then L.tradeCall.shown = true PennantUI.Call.open({})
  elseif j.screen == "clinch" and L.clinchPage and not L.clinchPage.shown then L.clinchPage.shown = true PennantUI.FrontPage.open({})
  elseif j.screen == "trades" then PennantUI.Farm.open({ tab = "trades" })
  elseif j.screen == "trainer" and j.id and L.players[j.id] and L.players[j.id].inj and not L.trainerSeen then
    L.trainerSeen = L.day
    PennantUI.Trainer.open({ id = j.id, onDone = function() L.trainerSeen = nil end })
  end
end

--- args: { days = n } | { untilOff } | { untilSeries } | { untilTrip } | { untilPhase = "playoffs"|"awards" }
---       afterLive = true: the rest of a day whose game was just played
function Advance.open(args)
  local s = setmetatable({}, Advance)
  App.push(s, args)
  return s
end

function Advance:enter(args)
  self.args = args
  local L = Pennant.L
  -- where "series end" / "trip end" stop: the series (round) and home/road run we start in
  local g, d = PL.nextGame(L, L.user)
  if g then
    self.startRound = L.sched[d].round
    self.startAway = g.a == L.user
  end
  self.days = 0
  self.w, self.l = 0, 0
  self.t = 0
  self.multi = args.days ~= 1
  self.state = "day"
  -- the wire: lines revealed at a readable pace (faster when they pile up), crank scrolls back
  PWire.begin(L)
  self.shown, self.revealIn, self.back = 0, 0, 0
  self.lineImg = {}
  self.calDay, self.flip = L.day, 0
  self.todoSel = 1
  -- the week turn (ui/week.lua): runs to the week's end, stops only for what needs the player
  self.week = args.week
  if self.week then self.multi = true end
  self:startDay()
end

--- Before a day of a week run: travel between series (the globe), the registered stops (the
--- clubhouse event; future interstitials), the live game (featured, or picked in the Office).
function Advance:startDay()
  if not self.week then self:queueDay() return end
  local L = Pennant.L
  self.state = "pre"
  local steps = {}
  local g = PL.gameFor(L, L.user)
  if g and not g.done and self.args.skipTravel ~= L.day and L.settings.travel ~= false then
    local from = PennantUI.cityOn(L, L.day - 1)
    if from ~= g.h then
      local lm = L.settings.landmarks ~= false and PLand.maybe(L, from, g.h) or nil
      steps[#steps + 1] = function(nx) PennantUI.Travel.open({ from = from, to = g.h, landmark = lm, quick = true, onDone = nx }) end
    end
  end
  for _, st in ipairs(PWeek.dueStops(L)) do
    if st.stop.open then steps[#steps + 1] = function(nx) st.stop.open(L, st.payload, nx) end end
  end
  local live, why, mode = PWeek.liveToday(L)
  if live and not self.args.untilPhase then
    steps[#steps + 1] = function(nx) self:liveGame(why, mode, nx) end
  end
  local i = 0
  local function nx()
    i = i + 1
    local f = steps[i]
    if f then f(nx) else self.state = "day" self:queueDay() end
  end
  nx()
end

--- The pregame for a game played live inside the run; the run resumes after it.
function Advance:liveGame(why, mode, nx)
  PennantUI.GameDay.open({ featured = why, mode = mode, onChoice = function(m)
    App.pop()
    local L = Pennant.L
    -- (remembered for the day: the strip shows how it was played until the week turns)
    PWeek.setMode(L, L.day, m)
    if m == "sim" or not (BallCast and BallCast.scene) then nx() return end
    PennantUI.liveReturn = nx
    PennantLive.start(m)
  end })
end

--- After a day of a week run: what can't wait (the clinch, a regular's injury, a club on the
--- phone, a cleared goal's reward).
function Advance:hasFollow()
  local L = Pennant.L
  local c = L.club
  local T = L.teams[L.user]
  -- (a bench player's or a reliever's injury: the assistant GM covers it, no stop)
  local reg = {}
  for _, id in ipairs(T.order or {}) do reg[id] = true end
  for _, id in ipairs(T.rot or {}) do reg[id] = true end
  if L.trainerQ then
    local q = {}
    for _, e in ipairs(L.trainerQ) do if reg[e.id] then q[#q + 1] = e end end
    L.trainerQ = #q > 0 and q or nil
  end
  if L.clinchPage and not L.clinchPage.shown then return true end
  local e = PL.trainerPending(L)
  if e and not e.snoozed and not L.trainerSeen then return true end
  local tc = L.tradeCall
  if tc and L.day - tc.day <= 1 and not tc.shown then return true end
  if c.rewards and #c.rewards > 0 then return true end
  return false
end

function Advance:weekFollow(done)
  local L = Pennant.L
  local steps = {
    function(nx) PennantUI.frontPageFollowUp(nx) end,
    function(nx) PennantUI.trainerFollowUp(nx) end,
    function(nx) PennantUI.callFollowUp(nx) end,
    function(nx)
      local c = L.club
      if c.rewards and #c.rewards > 0 then PennantUI.Goals.open({ reward = true, onDone = nx }) else nx() end
    end,
  }
  local i = 0
  local function nx()
    i = i + 1
    local f = steps[i]
    if f then f(nx) else done() end
  end
  nx()
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
  if self.stopped then return false end
  if L.phase == "awards" then return false end
  if self.week then
    if a.untilPhase then return L.phase ~= a.untilPhase end
    return not PWeek.weekDone(L)
  end
  if a.days then return self.days < a.days end
  if a.untilOff then
    local day = PL.today(L)
    return not (self.lastOff) and day ~= nil
  end
  if a.untilPhase then return L.phase ~= a.untilPhase end
  if a.untilSeries or a.untilTrip then
    local g, d = PL.nextGame(L, L.user)
    if not g or L.phase ~= "season" then return false end
    if a.untilSeries then return L.sched[d].round == self.startRound end
    return (g.a == L.user) == self.startAway
  end
  return false
end

--- The day's close, spread over frames: PL.finishDay yields between clubs and players.
function Advance:startClose()
  local L = Pennant.L
  local today = PL.today(L)
  self.closeMine = PL.gameFor(L, L.user)
  self.lastOff = today and today.off
  self.state = "close"
  self.closeCo = coroutine.create(function()
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
  end
  self.rep = rep
  PWire.endDay(L, rep)
  if self.week then
    -- (the week run stops only for what needs the player; the rest is on the wire)
    PWire.stop = nil
    if self:hasFollow() then self.state = "followwait" else self:next() end
    return
  end
  -- a stop: shown once the wire has caught up (the weekly report just opens, then on we go)
  if self.multi and PWire.stop and not self.args.noStops then
    self.pending = PWire.stop
    PWire.stop = nil
    self.state = "stopwait"
    return
  end
  PWire.stop = nil
  self:next()
end

function Advance:next()
  if self:wantMore() then
    self.state = "day"
    self:startDay()
  else
    self.state = "saving"
    Pennant.autosave()
  end
end

function Advance:update()
  -- the week run lands on its report once the wire has been read (A skips the reading)
  if self.week and self.state == "done" and self:caughtUp() and not self.autoGo then
    self.weekHold = (self.weekHold or 0) + 1
    if self.weekHold > 20 then self.autoGo = true end
  end
  if self.autoGo then
    self.autoGo = false
    self:finish()
    -- (draw where we landed this frame: main.lua cleared the display)
    local t = App.top()
    if t ~= self then if t and t.update then t:update(false) end return end
  end
  local fs = playdate.getCurrentTimeMilliseconds()
  self:work()
  self:reveal()
  -- The screen is composed into a cached frame only when something changed (a new line, a page
  -- of the calendar, a stop...): most frames of a long sim are all work. The frame is blitted
  -- every frame (main.lua clears the display each frame, so a skipped draw would be a white
  -- frame), and the throbber is drawn live on top.
  local L = Pennant.L
  local key = self.shown .. ":" .. self.back .. ":" .. self.state .. ":" .. L.day .. ":" .. self.flip .. ":" .. self.todoSel .. ":" .. tostring(self:caughtUp())
  if key ~= self.drawKey or self.flip > 0 or not self.frameImg then
    self.drawKey = key
    self.frameImg = self.frameImg or gfx.image.new(400, 240, gfx.kColorWhite)
    gfx.pushContext(self.frameImg)
    self:draw()
    gfx.popContext()
  end
  self.frameImg:draw(0, 0)
  self:drawLive()
  local d = playdate.getCurrentTimeMilliseconds() - fs
  if d > 40 and PUI.PROF then print(string.format("[pnadv] %d ms frame (state %s)", d, tostring(self.state))) end
end

function Advance:prof(what, t0)
  local d = playdate.getCurrentTimeMilliseconds() - t0
  if d > 25 and PUI.PROF then print(string.format("[pnadv] %s %d ms", what, d)) end
end

function Advance:work()
  self.t = self.t + 1
  self.t0 = playdate.getCurrentTimeMilliseconds()
  -- ~15 ms of work a frame (the device runs Lua ~5-10x slower than the Simulator)
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
        self:afterClose(rep, travel)
      else break end
    elseif self.state == "stopwait" then
      if self.shown >= #PWire.lines then
        if self.pending.report then
          -- the weekly beat: the report, then on with the sim
          self.state = "report"
          PennantUI.TrainingResults.open({ onDone = function() self.state = "day" self.pending = nil self:next() end })
        else
          self.state = "stop"
          Sfx.stinger("new_mail")
        end
      end
      break
    elseif self.state == "followwait" then
      if self.shown >= #PWire.lines then
        self.state = "follow"
        self:weekFollow(function() self.state = "day" self:next() end)
      end
      break
    elseif self.state == "saving" then
      PJobs.tick(self.budget - (playdate.getCurrentTimeMilliseconds() - self.t0))
      if not PJobs.busy() then
        self.state = "done"
        -- a single day (or the rest of a played day) lands straight on the hub
        if not self.multi then self.autoGo = true end
      end
      break
    else
      break
    end
  end
end

--- Reveal wire lines at a readable pace: a beat each, quicker when they pile up.
function Advance:reveal()
  local n = #(PWire.lines or {})
  if self.shown >= n then return end
  self.revealIn = self.revealIn - 1
  if self.revealIn > 0 then return end
  self.shown = self.shown + 1
  local backlog = n - self.shown
  -- (at most a line every other frame: each new line recomposes the cached frame)
  self.revealIn = (backlog > 10 and 2) or (backlog > 4 and 3) or (self.args.untilPhase and 4) or 8
  if Game.settings.reduceMotion then self.revealIn = 2 end
  self.back = 0
end

-- drawing -------------------------------------------------------------------------------------------------

local LOG_X, LOG_Y, LOG_W, LOG_H = 106, 20, 292, 204

--- One wire line as an image (wrapped to two lines at most); league lines are drawn lighter.
function Advance:lineImage(i)
  local c = self.lineImg[i]
  if c then return c end
  local l = PWire.lines[i]
  local f = l.mine and UI.fonts.bold or UI.fonts.body
  local w = LOG_W - 18
  local lines = Text.wrap(l.text, f, w)
  local n = math.min(2, #lines)
  local img = gfx.image.new(LOG_W - 6, n * 13 + 2, gfx.kColorClear)
  gfx.pushContext(img)
  if l.mine then Text.draw(l.kind == "game" and "\u{25b6}" or "\u{2022}", 2, 0, UI.fonts.bold) end
  for k = 1, n do
    local s = lines[k]
    if k == 2 and #lines > 2 then s = Text.ellipsize(s .. " \u{2026}", f, w) end
    Text.draw(s, 14, (k - 1) * 13, f)
  end
  if not l.mine then Draw.fade(0, 0, LOG_W - 6, n * 13 + 2, 0.25, true) end
  gfx.popContext()
  c = { img = img, h = n * 13 + 2 }
  self.lineImg[i] = c
  return c
end

local MONTHS <const> = { "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" }
function Advance:calendar(d)
  local key = "cal" .. d
  if self.calKey == key then return self.calImg end
  local L = Pennant.L
  local m, day = PL.calendar(math.min(d, #L.sched), L)
  local img = gfx.image.new(96, 76, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(2, 2, 94, 74)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 0, 94, 74)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(0, 0, 94, 74)
  gfx.fillRect(0, 0, 94, 18)
  for k = 0, 3 do gfx.setColor(gfx.kColorWhite) gfx.fillCircleAtPoint(15 + k * 21, 5, 2) end
  gfx.setColor(gfx.kColorBlack)
  Text.draw(MONTHS[m] .. " " .. L.year, 47, 4, UI.fonts.bold, "white", "center")
  Text.draw(tostring(day), 47, 24, UI.fonts.big, nil, "center")
  local g = PL.gameFor(L, L.user, d)
  local sub = ""
  if L.sched[d] and L.sched[d].off then sub = "off day"
  elseif g then sub = (g.h == L.user) and ("vs " .. g.a) or ("at " .. g.h) end
  Text.draw(sub, 47, 56, UI.fonts.body, nil, "center")
  gfx.popContext()
  self.calKey, self.calImg = key, img
  return img
end

function Advance:racePanel()
  local L = Pennant.L
  local key = (L.dayCount or 0) .. L.phase
  if self.raceKey == key then return self.raceImg end
  local img = gfx.image.new(96, 96, gfx.kColorWhite)
  gfx.pushContext(img)
  gfx.drawRect(0, 0, 96, 96)
  gfx.fillRect(0, 0, 96, 14)
  Text.draw("THE RACE", 4, Text.boxY(UI.fonts.bold, 0, 14), UI.fonts.bold, "white")
  local y = 16
  if L.phase == "season" then
    for _, e in ipairs(PL.raceWindow(L)) do
      local mine = e.T.abbr == L.user
      if mine then gfx.fillRect(1, y - 1, 94, 13) end
      local col = mine and "white" or nil
      local ty = Text.boxY(UI.fonts.bold, y - 1, 13)
      Text.draw(e.rank .. " " .. e.T.abbr, 4, ty, UI.fonts.bold, col)
      Text.draw(e.T.w .. "-" .. e.T.l, 70, ty, UI.fonts.body, col, "right")
      Text.draw(PL.gbText(e.T.gb), 92, ty, UI.fonts.body, col, "right")
      if e.rank == 4 then gfx.setPattern(UI.pat.gray) gfx.drawLine(2, y + 12, 93, y + 12) gfx.setColor(gfx.kColorBlack) end
      y = y + 13
    end
    Text.draw(PL.raceNumber(L), 48, y + 2, UI.fonts.bold, nil, "center")
  else
    Text.draw(L.phase == "playoffs" and "PLAYOFFS" or "SEASON OVER", 48, 30, UI.fonts.bold, nil, "center")
  end
  gfx.popContext()
  self.raceKey, self.raceImg = key, img
  return img
end

function Advance:draw()
  local L = Pennant.L
  gfx.clear(gfx.kColorWhite)
  if not self.bg then
    self.bg = gfx.image.new(400, 240, gfx.kColorWhite)
    gfx.pushContext(self.bg)
    Draw.tile(0, 0, 400, 240, "light")
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(LOG_X, LOG_Y, LOG_W, LOG_H)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(LOG_X, LOG_Y, LOG_W, LOG_H)
    gfx.popContext()
  end
  self.bg:draw(0, 0)
  PUI.topBar("On the wire", PUI.rightText())
  -- the calendar flips a page per day
  local d = math.min(L.day, #L.sched)
  if d ~= self.calDay then self.prevCal = self:calendar(self.calDay) self.calDay = d self.flip = Game.settings.reduceMotion and 0 or 6 end
  local cal = self:calendar(d)
  cal:draw(4, 22)
  if self.flip > 0 and self.prevCal then
    self.flip = self.flip - 1
    local up = (6 - self.flip) * 12
    self.prevCal:draw(4, 22 - up, gfx.kImageUnflipped, playdate.geometry.rect.new(0, 0, 96, math.max(0, 76 - up)))
    if self.flip == 0 then Sfx.tick() end
  end
  self:racePanel():draw(4, 104)
  Text.draw("You: " .. self.w .. "-" .. self.l, 52, 204, UI.fonts.bold, nil, "center")
  -- the log, newest at the bottom; the crank scrolls back
  gfx.setClipRect(LOG_X + 2, LOG_Y + 2, LOG_W - 4, LOG_H - 4)
  local y = LOG_Y + LOG_H - 4
  local i = self.shown - self.back
  while i >= 1 and y > LOG_Y do
    local c = self:lineImage(i)
    y = y - c.h
    c.img:draw(LOG_X + 3, y)
    i = i - 1
  end
  gfx.clearClipRect()
  if self.back > 0 then Text.draw("\u{25bc} " .. self.back .. " newer", LOG_X + LOG_W - 6, LOG_Y + LOG_H - 14, UI.fonts.bold, nil, "right") end
  -- a stop, or the end
  if self.state == "stop" then self:drawStop()
  elseif self:caughtUp() and self.multi and not self.week then self:drawDone() end
  local hint = (self.state == "stop" and "A: deal with it   B: keep going") or (self:caughtUp() and (self.week and "A: the week's report" or "A: go   up/down: choose")) or (self.state == "done" and "A: skip ahead")
    or (self.week and "A: skip the reading   B: stop after today   crank: read back") or "B: stop after today   crank: read back"
  PUI.hintBar(hint)
end

--- Drawn every frame over the cached one.
function Advance:drawLive()
  if self.state == "day" or self.state == "close" then Draw.throbber(LOG_X + LOG_W - 12, LOG_Y + 10, 6, self.t, true) end
end

function Advance:drawStop()
  local x, y, w, h = 120, 70, 260, 90
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 3, y + 3, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  gfx.fillRect(x, y, w, 16)
  Text.draw("STOPPED", x + w // 2, Text.boxY(UI.fonts.bold, y, 16), UI.fonts.bold, "white", "center")
  Text.block(self.pending.reason, x + 8, y + 22, w - 16, UI.fonts.body, nil, 3)
  Text.draw("A: deal with it", x + 8, y + h - 16, UI.fonts.bold)
  Text.draw("B: keep going", x + w - 8, y + h - 16, UI.fonts.body, nil, "right")
end

--- The end: the tally and what to do about it, one press each.
function Advance:items()
  local list = {}
  for _, t in ipairs(PWire.todo()) do list[#list + 1] = t end
  list[#list + 1] = { text = "Back to the hub", jump = nil, hub = true }
  return list
end

function Advance:drawDone()
  local items = self:items()
  local x, y, w = 120, 50, 260
  local h = 40 + #items * 16
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 3, y + 3, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  gfx.fillRect(x, y, w, 16)
  Text.draw("WHAT TO DO", x + w // 2, Text.boxY(UI.fonts.bold, y, 16), UI.fonts.bold, "white", "center")
  local L = Pennant.L
  local endLine
  if L.phase == "playoffs" and L.po then
    local T = L.teams[L.user]
    local r = PL.rank(L, L.user)
    endLine = r <= 4 and ("PLAYOFFS! " .. T.w .. "-" .. T.l .. ", " .. PUI.ord(r) .. ".") or ("Season over. " .. T.w .. "-" .. T.l .. ", " .. PUI.ord(r) .. ".")
  elseif L.phase == "awards" then
    endLine = (L.champ == L.user) and "CHAMPIONS!" or ("The " .. PUI.nick(L.champ or L.user) .. " won it all.")
  end
  Text.draw(endLine or ("You went " .. self.w .. "-" .. self.l .. " over " .. self.days .. " day" .. (self.days == 1 and "" or "s") .. "."), x + 8, y + 19, endLine and UI.fonts.bold or UI.fonts.body)
  for i, it in ipairs(items) do
    local yy = y + 36 + (i - 1) * 16
    local on = i == self.todoSel
    if on then gfx.fillRect(x + 2, yy - 1, w - 4, 15) end
    Text.draw(Text.ellipsize(it.text, UI.fonts.bold, w - 20), x + 8, yy, UI.fonts.bold, on and "white" or nil)
  end
end

-- input ----------------------------------------------------------------------------------------------------

--- The end card waits until the wire has shown every line.
function Advance:caughtUp() return self.state == "done" and self.shown >= #(PWire.lines or {}) end

function Advance:finish(jump)
  App.pop()
  if self.week then
    local L = Pennant.L
    if self.args.untilPhase or not PWeek.weekDone(L) then
      -- (stopped part way: the Week screen offers to carry on)
      Pennant.toHub()
      if Pennant.hub then Pennant.hub:render(true) end
    else
      PennantUI.weekEnd()
    end
    return
  end
  PennantUI.followUps(self.travel)
  if jump then PennantUI.jump(jump) end
end

function Advance:AButtonDown()
  if self.state == "stop" then
    -- deal with it: the sim ends here (saved), the screen that fixes it opens over the hub
    Sfx.select()
    self.stopped = true
    self.dealWith = self.pending.jump
    self.pending = nil
    self.state = "saving"
    Pennant.autosave()
    return
  end
  if self.week then
    if self.state ~= "done" or not self:caughtUp() then self.shown = #PWire.lines self.back = 0 return end
    Sfx.select()
    self.autoGo = true
    return
  end
  if self.state ~= "done" then return end
  if not self:caughtUp() and self.multi then self.shown = #PWire.lines self.back = 0 return end
  Sfx.select()
  local it = self:items()[self.todoSel]
  self:finish(it and it.jump or self.dealWith)
end

function Advance:BButtonDown()
  if self.state == "stop" then
    Sfx.back()
    self.pending = nil
    self:next()
    return
  end
  if self.state == "done" then self:finish(nil) return end
  -- stop after today
  self.stopped = true
end

function Advance:upButtonDown() if self:caughtUp() then self.todoSel = math.max(1, self.todoSel - 1) Sfx.focus() else self.back = math.min(math.max(0, self.shown - 1), self.back + 1) end end
function Advance:downButtonDown() if self:caughtUp() then self.todoSel = math.min(#self:items(), self.todoSel + 1) Sfx.focus() else self.back = math.max(0, self.back - 1) end end
function Advance:cranked(c)
  self.crankAcc = (self.crankAcc or 0) + c
  while math.abs(self.crankAcc) >= 25 do
    local d = self.crankAcc > 0 and -1 or 1
    self.crankAcc = self.crankAcc + (d > 0 and -25 or 25)
    self.back = math.max(0, math.min(math.max(0, self.shown - 1), self.back + d))
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
  if not L.champ then return end   -- (the winter has passed: nothing to show)
  local A = L.awardsRes or PL.awards(L)
  local y = 2
  Draw.wordart(L.year .. " PENNANT", 200, y, UI.fonts.slab)
  y = y + 34
  -- the champion on one line under the wordart
  local champ = PUI.teamName(L.champ) .. " over the " .. PUI.teamName(L.runnerUp or "")
  local cw = math.min(360, UI.fonts.bold:getTextWidth(champ))
  PUI.logo(L.champ, 200 - (cw + 20) // 2, y - 1, 16)
  Text.draw(Text.ellipsize(champ, UI.fonts.bold, 360), 200 - (cw + 20) // 2 + 20, y, UI.fonts.bold)
  y = y + 18
  local function award(label, id, line, x)
    local p = id and L.players[id]
    if not p then return end
    Faces.draw("face:" .. p.face, x, y, 48)
    Text.draw(label, x + 54, y, UI.fonts.bold)
    Text.drawFit(PM.name(p), x + 54, y + 14, 74, UI.fonts.body, nil, nil, { short = { Text.initialName(PM.name(p)), p.ln } })
    Text.draw(p.team, x + 54, y + 27, UI.fonts.body)
    Text.drawFit(line(p), x + 54, y + 40, 74, UI.fonts.body)
  end
  -- short stat lines: the two numbers that won it
  local function bat(p) local s = p.st.b return PM.rate3(PM.avg(s)) .. ", " .. (s.hr or 0) .. " HR" end
  local function pit(p) local s = p.st.p return (s.w or 0) .. "-" .. (s.l or 0) .. ", " .. string.format("%.2f", PM.era(s)) end
  award("MVP", A.mvp, bat, 4)
  award("PITCHER", A.cy, pit, 136)
  award("ROOKIE", A.roy, function(p) return p.pos == "P" and pit(p) or bat(p) end, 268)
  y = y + 62
  Text.draw("LEAGUE LEADERS", 4, y, UI.fonts.bold)
  Draw.hr(120, y + 7, 272)
  y = y + 14
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
  Lb:button("Begin the offseason", 110, y + 2, 180, 18, function() PennantUI.seasonEnd(function() PennantUI.Winter.open({}) end) end,
    { id = "go", hint = "Aging, retirements, rookies, then a new season" })
  Lb:mark(y + 20)
end

function Awards:initialFocus() for i, l in ipairs(self.links) do if l.id == "go" then return i end end return 1 end

--- The end of a pennant race (after awards night, before the winter): Pennant.seasonEndHooks run
--- in order, each hook(L, next) opening whatever it likes over the stack and calling next() when
--- done. Future: the run summary / legacy alumni pick, and after a pennant the "continue career /
--- end the run" choice (L.champ == L.user) go here.
Pennant = Pennant or {}
Pennant.seasonEndHooks = Pennant.seasonEndHooks or {}
function PennantUI.seasonEnd(onDone)
  local L = Pennant.L
  local hooks = Pennant.seasonEndHooks
  local i = 0
  local function nx()
    i = i + 1
    local h = hooks[i]
    if h then h(L, nx) else onDone() end
  end
  nx()
end

-- Offseason report ---------------------------------------------------------------------------------------

local Off = PUI.define({ title = "Offseason", hint = "A: start the new season" })
PennantUI.Offseason = Off

--- The Hot Stove: a two-column spread (farewells and winter changes | draft day) that fits one screen.
function Off:layout(Lb)
  local L = Pennant.L
  local rep = L.offRep or { retired = {}, rookies = {}, grew = {}, declined = {} }
  Text.draw("Spring training, " .. L.year, 4, 2, UI.fonts.big)
  local CW = 190
  local function head(t, x, y) Text.draw(t, x, y, UI.fonts.bold) Draw.hr(x, y + 13, CW) return y + 16 end
  local function more(n, x, y) if n > 0 then Text.draw("+" .. n .. " more", x + 8, y, UI.fonts.body) return y + 13 end return y end
  -- left: farewells, then who grew and who slowed
  local x, y = 4, 30
  y = head("RETIRED", x, y)
  if #rep.retired == 0 then Text.draw("Nobody hung them up.", x + 4, y, UI.fonts.body) y = y + 13 end
  for i, r in ipairs(rep.retired) do
    if i > 3 then y = more(#rep.retired - 3, x, y) break end
    Text.draw(Text.ellipsize(r.pos .. " " .. r.name .. ", " .. r.age .. " (" .. (r.mlYrs or 0) .. " yrs)", UI.fonts.body, CW - 4), x + 4, y, UI.fonts.body)
    y = y + 13
  end
  y = head("OVER THE WINTER", x, y + 4)
  local changes = {}
  for _, g in ipairs(rep.grew) do changes[#changes + 1] = { g = g, up = true } end
  for _, g in ipairs(rep.declined) do changes[#changes + 1] = { g = g, up = false } end
  if #changes == 0 then Text.draw("No big changes.", x + 4, y, UI.fonts.body) y = y + 13 end
  local shown = 0
  for _, c in ipairs(changes) do
    local p = L.players[c.g.id]
    if p then
      if shown >= 5 then y = more(#changes - 5, x, y) break end
      Text.draw((c.up and "\u{25b2} " or "\u{25bc} ") .. Text.ellipsize(PM.short(p) .. " " .. (c.up and "+" or "") .. c.g.d .. " OVR (" .. PM.ovr(p) .. ")", UI.fonts.body, CW - 18), x + 4, y, c.up and UI.fonts.bold or UI.fonts.body)
      y = y + 13
      shown = shown + 1
    end
  end
  -- right: draft day
  local rx, ry = 204, 30
  ry = head("DRAFT DAY (to the farm)", rx, ry)
  local n = 0
  for _, id in ipairs(rep.rookies) do
    local p = L.players[id]
    if p then
      if n >= 8 then ry = more(#rep.rookies - 8, rx, ry) break end
      Text.draw(Text.ellipsize((p.pos == "P" and p.role or p.pos) .. " " .. PM.short(p) .. ", " .. p.age, UI.fonts.body, CW - 44), rx + 4, ry, UI.fonts.body)
      Text.draw(string.rep("\u{2605}", PM.potStars(p)), rx + CW, ry, UI.fonts.body, nil, "right")
      ry = ry + 13
      n = n + 1
    end
  end
  if n == 0 then Text.draw("No new faces.", rx + 4, ry, UI.fonts.body) ry = ry + 13 end
  local by = math.max(y, ry) + 6
  Lb:button("Opening Day " .. L.year, 120, by, 160, 18, function() Pennant.toHub() Pennant.hub:render(true) end, { id = "go", hint = "A new season" })
  Lb:mark(by + 18)
end

function Off:initialFocus() for i, l in ipairs(self.links) do if l.id == "go" then return i end end return 1 end

-- The Evening Lamp: an extra edition when the club clinches (P2-1) --------------------------------

local Front = { opaque = true }
Front.__index = Front
PennantUI.FrontPage = Front

function Front.open(args)
  local s = setmetatable({}, Front)
  App.push(s, args)
  return s
end

function PennantUI.frontPageFollowUp(onDone)
  local L = Pennant.L
  local c = L.clinchPage
  if c and not c.shown then
    c.shown = true
    PennantUI.FrontPage.open({ onDone = onDone })
    return true
  end
  if onDone then onDone() end
  return false
end

function Front:enter(args)
  local L = Pennant.L
  self.onDone = args and args.onDone
  self.t = 0
  local T = L.teams[L.user]
  local c = PennantClubs.byAbbr[L.user]
  local left = PL.seasonGames(L) - (T.w + T.l)
  local b = PL.lastBox(L)
  local hero = b and PL.hero(L, b, L.user)
  local hp = hero and L.players[hero.id]
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  Draw.tile(0, 0, 400, 240, "light")
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(6, 4, 388, 220)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(6, 4, 388, 220)
  Text.draw("The Evening Lamp", 200, 7, UI.fonts.serif or UI.fonts.big, nil, "center")
  gfx.drawLine(12, 31, 388, 31)
  Text.draw(Text.ellipsize(c.city:upper() .. " \u{2022} " .. PL.date(L):upper() .. ", " .. L.year .. " \u{2022} EXTRA \u{2022} 5 CENTS", UI.fonts.body, 370), 200, Text.boxY(UI.fonts.body, 32, 14), UI.fonts.body, nil, "center")
  gfx.drawLine(12, 46, 388, 46)
  Text.draw(Text.ellipsize(c.name:upper() .. " CLINCH", UI.fonts.big, 370), 200, 50, UI.fonts.big, nil, "center")
  local dek = "Playoff berth secured with " .. left .. " to play" .. (hp and ("; " .. hp.ln .. " " .. hero.text) or "")
  Text.draw(Text.ellipsize(dek, UI.fonts.body, 370), 200, 75, UI.fonts.body, nil, "center")
  local photo = Archive.get("bb-team-0" .. (L.year % 3 + 1), 160)
  if photo then photo:draw(12, 94) else gfx.drawRect(12, 94, 160, 120) end
  local opp = b and (b.h == L.user and b.a or b.h)
  local mine = b and (b.h == L.user and b.home.r or b.away.r)
  local theirs = b and (b.h == L.user and b.away.r or b.home.r)
  local how = not b and " got the news" or (mine > theirs and (" beat " .. PennantClubs.byAbbr[opp].city .. " " .. mine .. "-" .. theirs)
    or (" lost to " .. PennantClubs.byAbbr[opp].city .. " " .. theirs .. "-" .. mine .. " and clinched anyway,"))
  local body = "The " .. c.name .. how ..
    " and will play in October for the first time since anyone at this paper can remember. Manager said the champagne was \"about as cold as expected,\" and went to bed."
  Text.block(body, 180, 96, 206, UI.fonts.body, nil, 9)
  -- the stamp
  gfx.setLineWidth(3)
  gfx.drawRoundRect(256, 176, 112, 32, 5)
  gfx.setLineWidth(1)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(259, 179, 106, 26)
  gfx.setColor(gfx.kColorBlack)
  Text.draw("CLINCHED", 312, 183, UI.fonts.head, nil, "center")
  gfx.popContext()
  self.img = img
  Sfx.stinger("win")
end

function Front:update()
  self.t = self.t + 1
  self.img:draw(0, 0)
  PUI.hintBar("A: continue")
end

function Front:AButtonDown()
  if self.t < 8 then return end
  Sfx.select()
  App.pop()
  if self.onDone then self.onDone() end
end
Front.BButtonDown = Front.AButtonDown

-- The winter passes: the offseason in slices (aging, retirements, the draft, a new schedule), then a
-- streamed save, then the Hot Stove page. ~12 ms of work a frame.

local Winter = { opaque = true }
Winter.__index = Winter
PennantUI.Winter = Winter

local WINTER_WORDS <const> = { aging = "Everyone gets a year older", retirements = "Some hang them up",
  draft = "Draft day", rosters = "The clubs set their rosters", plans = "The clubs set their rosters", schedule = "The new schedule" }

function Winter.open(args)
  local s = setmetatable({}, Winter)
  App.push(s, args)
  return s
end

function Winter:enter()
  local L = Pennant.L
  self.t = 0
  self.label = "aging"
  self.state = "winter"
  self.co = coroutine.create(function()
    PL.offseason(L, function(label)
      self.label = label
      if playdate.getCurrentTimeMilliseconds() - self.t0 >= 12 then coroutine.yield() end
    end)
  end)
end

function Winter:update()
  self.t = self.t + 1
  self.t0 = playdate.getCurrentTimeMilliseconds()
  local L = Pennant.L
  if self.state == "winter" then
    local ok, e = coroutine.resume(self.co)
    if not ok then print("[pennant] offseason failed: " .. tostring(e)) self.state = "done" end
    if coroutine.status(self.co) == "dead" and self.state == "winter" then
      self.state = "saving"
      self.label = "saving"
      self.job = PSave.begin(L, L.slot)
    end
  elseif self.state == "saving" then
    if self.job.step(12) then self.state = "done" end
  end
  -- the screen (cheap: a few lines of text)
  gfx.clear(gfx.kColorWhite)
  Draw.tile(0, 0, 400, 240, "light")
  PUI.topBar("Offseason", PUI.rightText())
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(60, 80, 280, 70)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(60, 80, 280, 70)
  Text.draw("The winter passes" .. string.rep(".", (self.t // 10) % 4), 80, 92, UI.fonts.head)
  Text.draw(self.label == "saving" and "Writing it all down" or (WINTER_WORDS[self.label] or ""), 80, 116, UI.fonts.body)
  Draw.throbber(318, 100, 7, self.t, true)
  PUI.hintBar("")
  if self.state == "done" and not self.opened then
    self.opened = true
    App.pop()
    -- (the awards page under us is last season's: it goes too)
    if getmetatable(App.top()) == PennantUI.Awards then App.pop() end
    PennantUI.Offseason.open({})
    local t = App.top()
    if t and t ~= self and t.update then t:update(false) end
  end
end
