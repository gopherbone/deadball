-- The season hub: the lineup card and the race on one screen (docs/ux/pennant P0-1).
--   LAST NIGHT  your last game: final, W/L/S, the hero line, arrows that moved, a new injury
--   TODAY       opponent, series, park, both starters with their hand, one heads-up line
--   RACE        five clubs around the playoff line, the magic number, the rival's game tonight
--   verbs       PLAY BALL (in the career's mode) / the mode / Sim day / Sim to: ▸ (remembered)
--   menu strip  Team, Lineup, Training, Moves, League, Road Map, Options
-- The news ticker runs in the hint bar once you've stopped pressing buttons.

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

local Hub = PUI.define({ title = "Season", hint = "A: go  left/right: choose  hold B anywhere: back here" })
PennantUI.Hub = Hub

function Hub:init()
  self.jobMs = 14
  -- the hub is home: keep its canvas while other screens are up, and re-render on return only
  -- when something it shows has changed (a full hub render is ~100 ms on the device)
  self.keepCanvas = true
end

function Hub:stamp()
  local L = Pennant.L
  local T = L.teams[L.user]
  local inj = 0
  for _, id in ipairs(T.ml) do if L.players[id].inj then inj = inj + 1 end end
  return table.concat({ L.season, L.day, L.dayCount or 0, L.phase, #L.news, L.news[1] and L.news[1].t or "",
    table.concat(T.rot or {}, ","), T.rotIdx or 0, inj, tostring(L.weekRep and L.weekRep.seen) }, "|")
end

function Hub:resume(r)
  local t0 = playdate.getCurrentTimeMilliseconds()
  Page.resume(self, r)
  local st = self:stamp()
  if st ~= self.lastStamp or not self.canvas then self:render(true) end
  local t1 = playdate.getCurrentTimeMilliseconds()
  if not Sfx.currentMusic() then Sfx.music("ragtime", { loop = true, fade = 1 }) end
  if PUI.PROF then print(string.format("[pnhub] resume: render %d ms, music %d ms", t1 - t0, playdate.getCurrentTimeMilliseconds() - t1)) end
end

function Hub:goBack()
  Dialog.show({ title = "Leave Pennant?", body = "Your career is saved every day.", buttons = { "Save & quit", "Stay" }, cancel = 2, icon = "?",
    onChoose = function(i) if i == 1 then
      PJobs.flush()
      PUI.busy("Saving", function() PSave.saveNow(Pennant.L, Pennant.L.slot) end)
      playdate.frameTimer.performAfterDelay(4, function() Pennant.quit() end)
    end end })
end

local function L_() return Pennant.L end

--- "3-1, 2.45" style line for a pitcher.
function PUI.pitLine(p)
  local s = p.st.p
  return string.format("%d-%d, %.2f", s.w or 0, s.l or 0, PM.era(s))
end
function PUI.batLine(p)
  local s = p.st.b
  return string.format("%s, %d HR, %d RBI", PM.rate3(PM.avg(s)), s.hr or 0, s.rbi or 0)
end


local function L_() return Pennant.L end

-- small pieces ------------------------------------------------------------------------------------------

--- A hand chip: inverse L for a lefty, outlined R (S for a switch hitter).
function PUI.handChip(x, y, h)
  local w = 9
  if h == "L" then gfx.fillRect(x, y, w, 11) Text.draw("L", x + 5, y - 1, UI.fonts.bold, "white", "center")
  else gfx.drawRect(x, y, w, 11) Text.draw(h or "R", x + 5, y - 1, UI.fonts.bold, nil, "center") end
  return w + 3
end
local handChip = PUI.handChip

local function panelTitle(x, y, w, left, right)
  gfx.fillRect(x, y, w, 13)
  Text.draw(left, x + 4, y, UI.fonts.bold, "white")
  if right then Text.draw(right, x + w - 4, y, UI.fonts.bold, "white", "right") end
end

-- LAST NIGHT --------------------------------------------------------------------------------------------

function Hub:layoutLastNight(Lb, x, y, w, h)
  local L = L_()
  gfx.drawRect(x, y, w, h)
  local b, key = PL.lastBox(L)
  if not b then
    panelTitle(x, y, w, "LAST NIGHT")
    Text.draw("Opening Day. No games yet.", x + 6, y + 18, UI.fonts.body)
    Text.draw("Every club is 0-0.", x + 6, y + 32, UI.fonts.body)
    return
  end
  local mine = b.h == L.user and b.home or b.away
  local theirs = b.h == L.user and b.away or b.home
  local won = mine.r > theirs.r
  panelTitle(x, y, w, b.d >= L.day - 1 and "LAST NIGHT" or PL.date(L, b.d):upper(), won and "W" or "L")
  local function name(id) local p = id and L.players[id] return p and p.ln or "-" end
  local yy = y + 15
  for _, side in ipairs({ { b.a, b.away, b.W, b.L }, { b.h, b.home, b.W, b.L } }) do
    PUI.logo(side[1], x + 3, yy, 16)
    Text.draw(side[1] .. " " .. side[2].r, x + 22, yy + 1, side[1] == L.user and UI.fonts.bold or UI.fonts.body)
    yy = yy + 16
  end
  -- decisions beside the score
  local function rec(id) local p = id and L.players[id] if not p then return "" end local s = p.st.p return " " .. (s.w or 0) .. "-" .. (s.l or 0) end
  Text.draw("W " .. name(b.W) .. rec(b.W), x + 70, y + 16, UI.fonts.body)
  Text.draw("L " .. name(b.L) .. rec(b.L), x + 70, y + 30, UI.fonts.body)
  if b.S then Text.draw("S " .. name(b.S), x + 150, y + 16, UI.fonts.body) end
  -- the hero line
  local hero = PL.hero(L, b, L.user)
  if hero then
    local p = L.players[hero.id]
    Text.draw(Text.ellipsize("\u{2605} " .. (p and p.ln or "") .. " " .. hero.text, UI.fonts.bold, w - 8), x + 4, yy + 1, UI.fonts.bold)
  end
  yy = yy + 15
  -- a big-league debut last night
  for _, ln in ipairs(mine.bat or {}) do
    local p = L.players[ln[1]]
    if p and p.debut and p.debut >= b.d - 1 and p.debut <= b.d then
      gfx.fillRect(x + w - 64, y + 15, 60, 13)
      Text.draw("ML DEBUT", x + w - 34, y + 15, UI.fonts.bold, "white", "center")
      break
    end
  end
  -- arrows that moved, and a new injury
  local rep = L.lastRep or {}
  local cx = x + 4
  for i, c in ipairs(rep.changes or {}) do
    if i > 3 then break end
    local p = L.players[c.id]
    if p then
      PUI.arrow(cx, yy + 1, c.to)
      local wdt = Text.draw(Text.ellipsize(p.ln, UI.fonts.body, 44), cx + 14, yy, UI.fonts.body)
      cx = cx + 18 + math.min(44, wdt) + 4
    end
  end
  yy = yy + 14
  for _, a in ipairs(rep.alerts or {}) do
    local p = a.kind == "inj" and L.players[a.id]
    if p and p.inj then
      gfx.fillRect(x + 2, yy - 1, w - 4, 13)
      Text.draw(Text.ellipsize("+ " .. p.ln .. ": " .. p.inj.k .. ", " .. p.inj.d .. " days", UI.fonts.bold, w - 10), x + 5, yy - 1, UI.fonts.bold, "white")
      break
    end
  end
  Lb:link(x, y, w, h, function() PennantUI.Box.open({ key = key }) end, { id = "last", style = "ring", hint = "A: the box score" })
end

-- TODAY -------------------------------------------------------------------------------------------------

function Hub:layoutToday(Lb, x, y, w, h)
  local L = L_()
  gfx.drawRect(x, y, w, h)
  local day = PL.today(L)
  local g = PL.gameFor(L, L.user)
  if L.phase == "awards" then
    panelTitle(x, y, w, "SEASON OVER")
    PUI.logo(L.champ, x + 6, y + 18, 32)
    Text.draw(PUI.nick(L.champ), x + 44, y + 18, UI.fonts.bold)
    Text.draw("win the " .. L.year .. " pennant.", x + 44, y + 32, UI.fonts.body)
    Text.draw("Awards night is tonight.", x + 6, y + 58, UI.fonts.body)
    return
  end
  if not day then return end
  if day.off or not g then
    panelTitle(x, y, w, day.off and "OFF DAY" or "NO GAME", PL.date(L))
    local ng, nd = PL.nextGame(L, L.user)
    if day.off then Text.draw("A travel day. Rest helps;", x + 6, y + 18, UI.fonts.body) Text.draw("training goes on.", x + 6, y + 31, UI.fonts.body)
    else Text.draw(L.phase == "playoffs" and "Your season is over." or "No game today.", x + 6, y + 18, UI.fonts.body) end
    if ng then
      local away = ng.a == L.user
      Text.draw("Next: " .. (away and ("at " .. PUI.nick(ng.h)) or ("vs " .. PUI.nick(ng.a))), x + 6, y + 50, UI.fonts.bold)
      Text.draw(PL.date(L, nd) .. ", " .. PennantClubs.byAbbr[ng.h].park, x + 6, y + 64, UI.fonts.body)
    end
    return
  end
  local home = g.h == L.user
  local opp = home and g.a or g.h
  local sub
  if g.po then
    local s = L.po.series[g.si]
    sub = (s.final and "PENNANT " or "SEMI ") .. s.w[1] .. "-" .. s.w[2]
  else
    sub = "GAME " .. (day.gi or 1) .. " OF 3"
  end
  -- the series so far
  local sw, sl = 0, 0
  for _, st in ipairs(PL.route(L, L.user)) do
    if st.d0 <= L.day and st.d1 >= L.day then sw, sl = st.w, st.l end
  end
  panelTitle(x, y, w, "TODAY \u{2022} " .. sub, not g.po and (L.user .. " " .. sw .. "-" .. sl) or nil)
  PUI.logo(opp, x + 4, y + 16, 32)
  Text.draw(Text.ellipsize((home and "vs " or "at ") .. PUI.teamName(opp), UI.fonts.bold, w - 46), x + 40, y + 16, UI.fonts.bold)
  local To = L.teams[opp]
  Text.draw(Text.ellipsize(To.w .. "-" .. To.l .. ", " .. PUI.ord(PL.rank(L, opp)) .. " \u{2022} " .. PennantClubs.byAbbr[g.h].park, UI.fonts.body, w - 46), x + 40, y + 30, UI.fonts.body)
  -- the starters, with their hands
  local yy = y + 50
  for _, ab in ipairs({ L.user, opp }) do
    local T = L.teams[ab]
    if ab == L.user then PL.todayCard(L, ab) end
    PRoster.validate(L, T)
    local id = PRoster.starter(L, T)
    local p = id and L.players[id]
    Text.draw(ab, x + 4, yy, UI.fonts.bold)
    if p then
      local cx = x + 34
      Text.draw(Text.ellipsize(p.ln, UI.fonts.body, 62), cx, yy, UI.fonts.body)
      cx = cx + 66
      cx = cx + handChip(cx, yy + 1, p.throws)
      Text.draw(PUI.pitLine(p), cx, yy, UI.fonts.body)
      if ab == L.user then PUI.arrow(x + w - 15, yy + 1, p.cond) end
    end
    yy = yy + 13
  end
  -- one heads-up line
  local hu = PL.headsUp(L)
  if hu then
    gfx.fillRect(x + 2, y + h - 15, w - 4, 13)
    Text.draw(Text.ellipsize("\u{25b6} " .. hu, UI.fonts.bold, w - 10), x + 5, y + h - 16, UI.fonts.bold, "white")
  end
  Lb:link(x, y, w, h, function() PennantUI.GameDay.open({}) end, { id = "today", style = "ring", hint = "A: the pregame (lineups, starters, how to play it)" })
end

-- THE RACE ----------------------------------------------------------------------------------------------

function Hub:layoutRace(Lb, x, y, w)
  local L = L_()
  Text.draw("RACE", x, y + 7, UI.fonts.head)
  local bx = x + 40
  local bw = (w - 40) // 5
  if L.phase == "playoffs" or L.phase == "awards" then
    -- the bracket
    local list = {}
    if L.po.semis then
      for _, s in ipairs(L.po.semis) do list[#list + 1] = s end
    end
    for _, s in ipairs(L.po.series) do list[#list + 1] = s end
    for i, s in ipairs(list) do
      local cx = bx + (i - 1) * (bw * 5 // math.max(3, #list))
      local cw = bw * 5 // math.max(3, #list) - 3
      gfx.drawRect(cx, y, cw, 26)
      local mine = s.hi == L.user or s.lo == L.user
      Text.draw((s.final and "PENNANT" or "SEMI"), cx + 3, y, UI.fonts.body)
      Text.draw(s.hi .. " " .. s.w[1] .. "-" .. s.w[2] .. " " .. s.lo, cx + 3, y + 12, mine and UI.fonts.bold or UI.fonts.body)
      if s.winner then Text.draw("\u{2713}", cx + cw - 3, y, UI.fonts.bold, nil, "right") end
    end
    Lb:link(x - 2, y - 2, w + 4, 30, function() PennantUI.League.open({ tab = "stand" }) end, { id = "race", style = "ring", hint = "A: standings and the bracket" })
    return y + 28
  end
  local win = PL.raceWindow(L)
  for i, e in ipairs(win) do
    local cx = bx + (i - 1) * bw
    local T = e.T
    local mine = T.abbr == L.user
    if mine then gfx.fillRect(cx, y, bw - 3, 26) else gfx.drawRect(cx, y, bw - 3, 26) end
    local col = mine and "white" or nil
    Text.draw(e.rank .. ". " .. T.abbr, cx + 3, y, UI.fonts.bold, col)
    Text.draw(T.w .. "-" .. T.l, cx + 3, y + 12, UI.fonts.body, col)
    Text.draw(PL.gbText(T.gb), cx + bw - 6, y + 12, UI.fonts.bold, col, "right")
    -- the playoff line after 4th
    if e.rank == 4 and i < #win then
      gfx.setPattern(UI.pat.gray)
      gfx.fillRect(cx + bw - 2, y - 2, 2, 30)
      gfx.setColor(gfx.kColorBlack)
    end
  end
  Lb:link(x - 2, y - 2, w + 4, 30, function() PennantUI.League.open({ tab = "stand" }) end, { id = "race", style = "ring", hint = "A: the full standings. Top four make the playoffs" })
  y = y + 29
  -- the magic number (second half of the season or the last 20 games), else games back
  local T = L.teams[L.user]
  local played = T.w + T.l
  local left = PL.seasonGames(L) - played
  local chip, text
  local m, e = PL.magic(L, L.user), PL.elimination(L, L.user)
  if m and m <= 0 then chip, text = "CLINCHED", "a playoff spot."
  elseif e and e <= 0 then chip, text = "ELIMINATED", "Play for next year."
  elseif played * 2 >= PL.seasonGames(L) or left <= 20 then
    if m then chip, text = "MAGIC # " .. m, "for a playoff spot." else chip, text = "ELIM # " .. e, "to stay alive." end
  else
    local st = PL.standings(L)
    local r = PL.rank(L, L.user)
    if r <= 4 then chip, text = PUI.ord(r):upper(), left .. " games left; the 5th club is " .. PL.gbText(((T.w - st[5].w) + (st[5].l - T.l)) / 2) .. " back."
    else chip, text = PUI.ord(r):upper(), PL.gbText(((st[4].w - T.w) + (T.l - st[4].l)) / 2) .. " back of 4th, " .. left .. " to play." end
  end
  local cw = UI.fonts.bold:getTextWidth(chip) + 10
  gfx.fillRect(x, y, cw, 14)
  Text.draw(chip, x + 5, y, UI.fonts.bold, "white")
  local rv = PL.rivalTonight(L)
  Text.draw(Text.ellipsize(text .. (rv and ("  Tonight: " .. rv.a .. " @ " .. rv.h) or ""), UI.fonts.body, w - cw - 6), x + cw + 6, y + 1, UI.fonts.body)
  return y + 16
end

-- verbs ---------------------------------------------------------------------------------------------------

local TARGETS <const> = {
  { "off", "off day", "Sim to the next off day (the week's training report comes with it)" },
  { "series", "series end", "Sim to the end of this series" },
  { "trip", "trip end", "Sim to the end of this road trip or homestand" },
  { "playoffs", "playoffs", "Sim to the end of the regular season" },
  { "season", "season end", "Sim through the playoffs to awards night" },
}

function Hub:targets()
  local L = L_()
  local out = {}
  for _, t in ipairs(TARGETS) do
    if not (t[1] == "playoffs" and L.phase ~= "season") then out[#out + 1] = t end
  end
  return out
end

function Hub:simTo()
  local L = L_()
  local s = L.settings
  local list = self:targets()
  local t = list[1]
  for _, x in ipairs(list) do if x[1] == s.simTarget then t = x end end
  local args = ({ off = { untilOff = true }, series = { untilSeries = true }, trip = { untilTrip = true },
    playoffs = { untilPhase = "playoffs" }, season = { untilPhase = "awards" } })[t[1]]
  PennantUI.Advance.open(args)
end

function Hub:cycleTarget(d)
  local L = L_()
  local s = L.settings
  local list = self:targets()
  local k = 1
  for i, x in ipairs(list) do if x[1] == s.simTarget then k = i end end
  s.simTarget = list[(k - 1 + d) % #list + 1][1]
end

--- PLAY BALL: today's game in the career's mode (the first time, offer batting yourself).
function Hub:playBall()
  local L = L_()
  local s = L.settings
  if L.phase == "awards" then PennantUI.Awards.open({}) return end
  local day = PL.today(L)
  if not day then return end
  local g = PL.gameFor(L, L.user)
  if day.off or not g then PennantUI.Advance.open({ days = 1 }) return end
  if not s.offered then
    s.offered = true
    Dialog.show({ title = "Your first game", icon = "?", vertical = true,
      body = "You manage from the dugout: steals, bunts, pitching changes. Want to bat and pitch yourself too? (" .. PScheme.NAME[s.batScheme or "arcade"] .. " controls.) You can switch any time: the button beside PLAY BALL, Options, or a time out.",
      buttons = { "Manage from the dugout", "Bat and pitch myself" },
      onChoose = function(i)
        s.playMode = (i == 2) and "play" or "manage"
        self:render(true)
        PennantLive.start(s.playMode)
      end })
    return
  end
  PennantLive.start(s.playMode or "manage")
end

function Hub:layoutVerbs(Lb, x, y, w)
  local L = L_()
  local s = L.settings
  local day = PL.today(L)
  local g = PL.gameFor(L, L.user)
  local label, hint = "PLAY BALL", "A: play today's game (" .. ((s.playMode == "play") and "you bat and pitch" or "you manage") .. ")"
  if L.phase == "awards" then label, hint = "AWARDS", "A: awards night, then the offseason"
  elseif day and day.off then label, hint = "NEXT DAY", "A: the off day (travel, rest, training)"
  elseif not g then label, hint = "SIM DAY", "A: the rest of the league plays today" end
  local function remember(id) return function() s.verb = id end end
  local l = Lb:button(label, x, y, 108, 22, function() s.verb = "play" self:playBall() end, { id = "play", hint = hint, font = UI.fonts.head })
  if L.phase ~= "awards" then
    local mode = (s.playMode == "play") and "Bat & pitch" or "Manage"
    Lb:button(mode, x + 112, y + 3, 82, 17, function()
      s.playMode = (s.playMode == "play") and "manage" or "play"
      s.offered = true
      Sfx.select()
      self:render(true)
    end, { id = "mode", hint = (s.playMode == "play") and ("You bat (" .. PScheme.NAME[s.batScheme or "arcade"] .. ") and pitch (" .. PScheme.NAME[s.pitchScheme or "arcade"] .. "). A: manage instead") or "You manage from the dugout. A: bat and pitch yourself too" })
    Lb:button("Sim day", x + 198, y + 3, 64, 17, function() s.verb = "simday" PennantUI.Advance.open({ days = 1 }) end, { id = "simday", hint = "A: let the coaches play today" })
    local list = self:targets()
    local t = list[1]
    for _, x2 in ipairs(list) do if x2[1] == s.simTarget then t = x2 end end
    local sl = Lb:button("Sim to: " .. t[2] .. " \u{25b6}", x + 266, y + 3, w - 266, 17, function() s.verb = "simto" self:simTo() end,
      { id = "simto", hint = "Left/right: where to stop. " .. t[3], data = { adj = function(d) self:cycleTarget(d) end } })
  end
  return y + 25
end

local MENU <const> = {
  { "Team", "Roster, player cards, condition", function() PennantUI.Team.open({}) end },
  { "Lineup", "Batting order, positions, rotation, bullpen", function() PennantUI.Lineup.open({}) end },
  { "Training", "This week's training plans", function() PennantUI.Training.open({}) end },
  { "Moves", "The farm (call-ups) and trades", function() PennantUI.Farm.open({}) end },
  { "League", "Standings, results, leaders, history", function() PennantUI.League.open({}) end },
  { "Road Map", "The season's road: homestands and road trips", function() PennantUI.RoadMap.open({}) end },
  { "Options", "Controls, settings, save", function() Hub.optionsMenu() end },
}

function Hub.optionsMenu()
  local L = L_()
  local s = L.settings
  local function onoff(v) return v and "on" or "off" end
  Menu.open({ x = 104, y = 120, items = {
    { label = "Save now", action = function() PJobs.flush() PUI.busy("Saving", function() PSave.saveNow(L, L.slot) end) Toast.show("Saved to slot " .. L.slot .. ".", "good") end },
    { label = "Landmarks: " .. onoff(s.landmarks ~= false), action = function() s.landmarks = not (s.landmarks ~= false) Toast.show("Road trip landmarks " .. onoff(s.landmarks), nil) end },
    { label = "Travel animation: " .. onoff(s.travel ~= false), action = function() s.travel = not (s.travel ~= false) Toast.show("Travel animation " .. onoff(s.travel), nil) end },
    { label = "Auto call-ups: " .. onoff(s.autoRoster ~= false), action = function() s.autoRoster = not (s.autoRoster ~= false) Toast.show("Assistant GM call-ups " .. onoff(s.autoRoster), nil) end },
    { label = "Batting controls: " .. PScheme.NAME[s.batScheme or "arcade"], action = function()
      s.batScheme = (s.batScheme or "arcade") == "arcade" and "scout" or "arcade"
      Toast.show("Batting yourself: " .. PScheme.NAME[s.batScheme] .. ". " .. PScheme.BLURB[s.batScheme], nil) end },
    { label = "Pitching controls: " .. PScheme.NAME[s.pitchScheme or "arcade"], action = function()
      s.pitchScheme = (s.pitchScheme or "arcade") == "arcade" and "scout" or "arcade"
      Toast.show("Pitching yourself: " .. PScheme.NAME[s.pitchScheme] .. ". " .. PScheme.BLURB[s.pitchScheme], nil) end },
    { label = "Show the how-to cards again", action = function() s.seenHelp = {} Toast.show("The how-to cards will show again.", nil) end },
    "-",
    { label = "Save & quit", action = function() Pennant.hub:goBack() end },
  } })
end

function Hub:layout(Lb)
  local L = L_()
  self.lastStamp = self:stamp()
  self:layoutLastNight(Lb, 2, 2, 194, 94)
  self:layoutToday(Lb, 200, 2, 194, 94)
  local y = self:layoutRace(Lb, 4, 99, 388)
  y = self:layoutVerbs(Lb, 2, y + 2, 392)
  -- the menu strip
  local x = 2
  for _, m in ipairs(MENU) do
    local alert = (m[1] == "Training" and L.weekRep and not L.weekRep.seen) and " !" or ""
    if m[1] == "Team" then
      local n = 0
      for _, id in ipairs(L.teams[L.user].ml) do if L.players[id].inj then n = n + 1 end end
      if n > 0 then alert = " +" end
    end
    local label = m[1] .. alert
    local bw = UI.fonts.bold:getTextWidth(label) + 10
    Lb:button(label, x, y + 2, bw, 16, m[3], { id = "m:" .. m[1], hint = m[2] })
    x = x + bw + 4
  end
  self:buildTicker()
  Lb:mark(PUI.VIEW_H - 9)
end

function Hub:buildTicker()
  local L = L_()
  local parts = {}
  for i, n in ipairs(L.news) do
    if i > 10 then break end
    parts[#parts + 1] = PL.date(L, math.min(n.d, #L.sched)) .. ": " .. n.t
  end
  local text = #parts > 0 and table.concat(parts, "   \u{2022}   ") or "PENNANT '96"
  -- short news sits still; long news crawls with a gap before it comes round again
  self.tickerStatic = UI.fonts.body:getTextWidth(text) <= 388
  if not self.tickerStatic then text = text .. "   \u{2022}   " end
  if text == self.ticker then return end
  self.ticker = text
  self.tickerW = math.min(4000, UI.fonts.body:getTextWidth(text))
  self.tickerImg = gfx.image.new(self.tickerW, 13, gfx.kColorBlack)
  gfx.pushContext(self.tickerImg)
  Text.draw(text, 0, 0, UI.fonts.body, "white")
  gfx.popContext()
end

function Hub:initialFocus()
  local s = L_().settings
  local want = s.verb == "simday" and "simday" or (s.verb == "simto" and "simto" or "play")
  for i, l in ipairs(self.links) do if l.id == want then return i end end
  return 1
end

--- (overlay hook) the news ticker in the hint bar once nothing has been pressed for 3 s
function Hub:after()
  if (self.idleFrames or 0) < 90 or not self.tickerImg then return end
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, PUI.BOT + 2, 400, 240 - PUI.BOT - 2)
  gfx.setColor(gfx.kColorBlack)
  gfx.setClipRect(0, PUI.BOT + 2, 400, 240 - PUI.BOT - 2)
  gfx.setImageDrawMode(gfx.kDrawModeInverted)
  if self.tickerStatic then self.tickerImg:draw(4, PUI.BOT + 1)
  else
    local off = ((self.idleFrames - 90) * 2) % self.tickerW
    self.tickerImg:draw(4 - off, PUI.BOT + 1)
    if self.tickerW - off < 396 then self.tickerImg:draw(4 + self.tickerW - off, PUI.BOT + 1) end
  end
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.clearClipRect()
end
