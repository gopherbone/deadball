-- The season hub: today's game (or off day / playoffs / awards), the standings, team leaders,
-- alerts and a plain news ticker; every other screen is one press away.

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

local Hub = PUI.define({ title = "Season", hint = "A: open  crank: scroll  hold B: here from anywhere" })
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

function Hub:layoutToday(Lb, x, y, w)
  local L = L_()
  local day = PL.today(L)
  local g, gi = PL.gameFor(L, L.user)
  local h = 100
  local title
  if L.phase == "awards" then title = "SEASON OVER"
  elseif not day then title = "SEASON"
  elseif day.off then title = "OFF DAY \u{2022} " .. PL.date(L)
  elseif day.po then title = "PLAYOFFS \u{2022} " .. PL.date(L)
  else title = "TODAY \u{2022} " .. PL.date(L) end
  local ix, iy, iw = Draw.window(x, y, w, h, title, { noShadow = true })
  if L.phase == "awards" then
    PUI.logo(L.champ, ix + 6, iy + 6, 32)
    Text.draw(PUI.teamName(L.champ), ix + 44, iy + 6, UI.fonts.bold)
    Text.draw("win the " .. L.year .. " pennant.", ix + 44, iy + 20, UI.fonts.body)
    Text.draw("The awards dinner is tonight.", ix + 6, iy + 46, UI.fonts.body)
    return y + h
  end
  if day and day.off then
    local ng, nd = PL.nextGame(L, L.user)
    Text.draw("No game today. Travel day.", ix + 6, iy + 6, UI.fonts.bold)
    if ng then
      local away = ng.a == L.user
      Text.draw("Next: " .. (away and ("at " .. PUI.teamName(ng.h)) or ("vs " .. PUI.teamName(ng.a))), ix + 6, iy + 24, UI.fonts.body)
      Text.draw(PL.date(L, nd) .. " at " .. PennantClubs.byAbbr[ng.h].park, ix + 6, iy + 38, UI.fonts.body)
    end
    Text.draw("Rest helps condition. Training goes on.", ix + 6, iy + 56, UI.fonts.body)
    return y + h
  end
  if not g then
    Text.draw(L.phase == "playoffs" and "Your season is over." or "No game today.", ix + 6, iy + 6, UI.fonts.bold)
    if L.phase == "playoffs" then Text.draw("The playoffs go on without you.", ix + 6, iy + 22, UI.fonts.body) end
    return y + h
  end
  PUI.logo(g.a, ix + 8, iy + 4, 32)
  Text.draw("@", ix + iw // 2, iy + 12, UI.fonts.head, nil, "center")
  PUI.logo(g.h, ix + iw - 40, iy + 4, 32)
  Text.draw(g.a, ix + 24, iy + 38, UI.fonts.bold, nil, "center")
  Text.draw(g.h, ix + iw - 24, iy + 38, UI.fonts.bold, nil, "center")
  local Ta, Th = L.teams[g.a], L.teams[g.h]
  Text.draw(Ta.w .. "-" .. Ta.l, ix + 24, iy + 50, UI.fonts.body, nil, "center")
  Text.draw(Th.w .. "-" .. Th.l, ix + iw - 24, iy + 50, UI.fonts.body, nil, "center")
  -- series / park
  local sub
  if g.po then
    local s = L.po.series[g.si]
    sub = (s.final and "Pennant series " or "Semifinal ") .. s.hi .. " " .. s.w[1] .. "-" .. s.w[2] .. " " .. s.lo
  else
    sub = "Game " .. (day.gi or 1) .. " of 3"
  end
  Text.draw(sub, ix + iw // 2, iy + 30, UI.fonts.body, nil, "center")
  Text.draw(Text.ellipsize(PennantClubs.byAbbr[g.h].park, UI.fonts.body, 90), ix + iw // 2, iy + 44, UI.fonts.body, nil, "center")
  -- probables
  local function prob(abbr)
    local T = L.teams[abbr]
    PRoster.validate(L, T)
    local id = PRoster.starter(L, T)
    local p = id and L.players[id]
    return p and (p.ln .. " " .. PUI.pitLine(p)) or "TBA"
  end
  Draw.dotted(ix + 2, ix + iw - 3, iy + 59)
  Text.draw(Text.ellipsize(g.a .. " " .. prob(g.a), UI.fonts.body, iw - 10), ix + 4, iy + 61, UI.fonts.body)
  Text.draw(Text.ellipsize(g.h .. " " .. prob(g.h), UI.fonts.body, iw - 10), ix + 4, iy + 72, UI.fonts.body)
  return y + h
end

function Hub:layoutStandings(Lb, x, y, w)
  local L = L_()
  if L.phase == "playoffs" or L.phase == "awards" then
    Text.draw("PLAYOFFS", x, y, UI.fonts.head)
    local yy = y + 18
    local function series(s, label)
      Text.draw(label, x, yy, UI.fonts.body)
      yy = yy + 13
      for _, ab in ipairs({ s.hi, s.lo }) do
        local wins = ab == s.hi and s.w[1] or s.w[2]
        local f = (s.winner == ab) and UI.fonts.bold or UI.fonts.body
        PUI.logo(ab, x + 2, yy, 16)
        Text.draw(PUI.nick(ab), x + 22, yy + 1, f)
        Text.draw(tostring(wins), x + w - 8, yy + 1, f, nil, "right")
        yy = yy + 17
      end
      yy = yy + 2
    end
    if L.po.semis then
      series(L.po.semis[1], "Semifinal") series(L.po.semis[2], "Semifinal")
      series(L.po.series[1], "Pennant series")
    else
      series(L.po.series[1], "Semifinal (best of 5)") series(L.po.series[2], "Semifinal (best of 5)")
    end
    Lb:link(x - 2, y - 2, w + 4, yy - y, function() PennantUI.League.open({ tab = "stand" }) end, { id = "stand", style = "ring", hint = "A: standings, leaders, results" })
    return yy
  end
  Text.draw("STANDINGS", x, y, UI.fonts.head)
  Text.draw("W-L", x + 120, y + 2, UI.fonts.body, nil, "right")
  Text.draw("GB", x + 152, y + 2, UI.fonts.body, nil, "right")
  Text.draw("STK", x + w - 2, y + 2, UI.fonts.body, nil, "right")
  local yy = y + 17
  for i, T in ipairs(PL.standings(L)) do
    local mine = T.abbr == L.user
    if mine then gfx.fillRect(x - 2, yy - 1, w + 4, 13) end
    local col = mine and "white" or nil
    Text.draw(i .. ".", x + 8, yy - 1, UI.fonts.body, col, "right")
    Text.draw(PUI.nick(T.abbr), x + 13, yy - 1, mine and UI.fonts.bold or UI.fonts.body, col)
    Text.draw(T.w .. "-" .. T.l, x + 120, yy - 1, UI.fonts.body, col, "right")
    Text.draw(PL.gbText(T.gb), x + 152, yy - 1, UI.fonts.body, col, "right")
    Text.draw(PL.streakText(T), x + w - 2, yy - 1, UI.fonts.body, col, "right")
    if i == 4 then gfx.setPattern(UI.pat.gray) gfx.drawLine(x, yy + 12, x + w, yy + 12) gfx.setColor(gfx.kColorBlack) end
    yy = yy + 13
  end
  Lb:link(x - 2, y - 2, w + 4, yy - y + 2, function() PennantUI.League.open({ tab = "stand" }) end, { id = "stand", style = "ring", hint = "A: full standings, leaders, results. Top four make the playoffs" })
  return yy
end

function Hub:layoutLeaders(Lb, x, y, w)
  local L = L_()
  Text.draw("TEAM LEADERS", x, y, UI.fonts.head)
  local yy = y + 17
  local rows = { { "avg", "AVG" }, { "hr", "HR" }, { "era", "ERA" }, { "w", "W" } }
  for i, r in ipairs(rows) do
    local top = PL.leaders(L, r[1], 1, L.user)[1]
    local cx = x + ((i - 1) % 2) * (w // 2)
    local cy = yy + ((i - 1) // 2) * 13
    Text.draw(r[2], cx, cy, UI.fonts.bold)
    if top then
      local p = L.players[top.id]
      local val = PL.leaderText(r[1], top.v)
      local vw = UI.fonts.body:getTextWidth(val)
      Text.draw(Text.ellipsize(p.ln, UI.fonts.body, w // 2 - 34 - vw), cx + 26, cy, UI.fonts.body)
      Text.draw(val, cx + w // 2 - 4, cy, UI.fonts.body, nil, "right")
    else
      Text.draw("-", cx + 28, cy, UI.fonts.body)
    end
  end
  return yy + 28
end

local MENU <const> = {
  { "Team", "Roster, player cards, condition", function() PennantUI.Team.open({}) end },
  { "Lineup", "Batting order, positions, rotation, bullpen", function() PennantUI.Lineup.open({}) end },
  { "Training", "This week's training plans", function() PennantUI.Training.open({}) end },
  { "Farm", "Call-ups and demotions", function() PennantUI.Farm.open({}) end },
  { "Trades", "Make a deal with another club", function() PennantUI.Trades.open({}) end },
  { "League", "Standings, results, leaders, history", function() PennantUI.League.open({}) end },
  { "Road Map", "The season's road: homestands and road trips", function() PennantUI.RoadMap.open({}) end },
  { "Options", "Settings, save", function() Hub.optionsMenu() end },
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

function Hub:playBall()
  local L = L_()
  if L.phase == "awards" then PennantUI.Awards.open({}) return end
  local day = PL.today(L)
  if not day then return end
  local g = PL.gameFor(L, L.user)
  if day.off or not g then
    PennantUI.Advance.open({ days = 1 })
    return
  end
  PennantUI.GameDay.open({})
end

function Hub:simMenu()
  local L = L_()
  local items = {
    { label = "Sim today", action = function() PennantUI.Advance.open({ days = 1 }) end },
    { label = "Sim to week's end", action = function() PennantUI.Advance.open({ untilOff = true }) end },
  }
  if L.phase == "season" then items[#items + 1] = { label = "Sim to the playoffs", action = function() PennantUI.Advance.open({ untilPhase = "playoffs" }) end } end
  if L.phase ~= "awards" then items[#items + 1] = { label = "Sim to season's end", action = function() PennantUI.Advance.open({ untilPhase = "awards" }) end } end
  Menu.open({ x = 104, y = 98, items = items })
end

function Hub:layout(Lb)
  local L = L_()
  self.lastStamp = self:stamp()
  local lx, lw = 4, 196
  local y = self:layoutToday(Lb, lx, 3, lw)
  local label = "PLAY BALL"
  local day = PL.today(L)
  local g = PL.gameFor(L, L.user)
  local hint = "A: today's game. Manage it, play it, or sim it"
  if L.phase == "awards" then label, hint = "AWARDS NIGHT", "A: the season's awards, then the offseason"
  elseif day and day.off then label, hint = "NEXT DAY", "A: the off day (travel, rest, training)"
  elseif not g then label, hint = "SIM THE DAY", "A: the rest of the league plays today" end
  Lb:button(label, lx, y + 3, 124, 21, function() self:playBall() end, { id = "play", hint = hint, font = UI.fonts.head })
  if L.phase ~= "awards" then
    Lb:button("SIM...", lx + 130, y + 3, 66, 21, function() self:simMenu() end, { id = "sim", hint = "Simulate a day, a week, or the rest of the season" })
  end
  y = y + 29
  for i, m in ipairs(MENU) do
    local col, row = (i - 1) % 3, (i - 1) // 3
    local bx, by = lx + col * 66, y + row * 19
    local alert = nil
    if m[1] == "Team" then
      local n = 0
      for _, id in ipairs(L.teams[L.user].ml) do if L.players[id].inj then n = n + 1 end end
      if n > 0 then alert = n .. "+" end
    elseif m[1] == "Training" and L.weekRep and not L.weekRep.seen then alert = "!" end
    Lb:button(m[1] .. (alert and (" " .. alert) or ""), bx, by, 63, 16, m[3], { id = "m:" .. m[1], hint = m[2] })
  end
  -- right column
  local rx, rw = 206, 186
  local ry = self:layoutStandings(Lb, rx, 4, rw)
  ry = self:layoutLeaders(Lb, rx, ry + 4, rw)
  -- ticker
  self:buildTicker()
  Lb:live(0, PUI.VIEW_H - 15, 395, 15, function(_, x, yy)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x, yy, 395, 15)
    if self.tickerImg then
      if self.tickerStatic then
        self.tickerImg:draw(x + 4, yy + 1)
      else
        -- a crawl; the copy that follows starts after the gap at the end of the text
        local off = (self.frame * 2) % self.tickerW
        self.tickerImg:draw(x + 4 - off, yy + 1)
        if self.tickerW - off < 395 then self.tickerImg:draw(x + 4 + self.tickerW - off, yy + 1) end
      end
    end
  end)
  Lb:mark(PUI.VIEW_H - 1)
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
  for i, l in ipairs(self.links) do if l.id == "play" then return i end end
  return 1
end

function Hub:afterRender()
  -- a fresh week's training report waits to be seen
end
