-- League pages: full standings, your schedule and results (box scores), league leaders,
-- franchise history and past champions.

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

local League = PUI.define({ title = "League", hint = "A: open  crank: scroll" })
PennantUI.League = League

function League:init(args) self.tab = args.tab or "stand" end
function League:resume(r) Page.resume(self, r) self:render(true) end

function League:layout(Lb)
  local L = Pennant.L
  local y = PUI.tabs(Lb, {
    { "stand", "Standings", function() self.tab = "stand" self:render() end },
    { "sched", "Schedule", function() self.tab = "sched" self:render() end },
    { "lead", "Leaders", function() self.tab = "lead" self:render() end },
    { "hist", "History", function() self.tab = "hist" self:render() end },
  }, self.tab, 2)
  if self.tab == "stand" then y = self:standings(Lb, y)
  elseif self.tab == "sched" then y = self:schedule(Lb, y)
  elseif self.tab == "lead" then y = self:leaders(Lb, y)
  else y = self:history(Lb, y) end
  Lb:mark(y)
end

function League:standings(Lb, y)
  local L = Pennant.L
  -- games left with the user's club, per club
  local left = {}
  for d = L.day, L.regDays or #L.sched do
    local day = L.sched[d]
    if day and not day.po then
      for _, g in ipairs(day.games) do
        if not g.done and (g.h == L.user or g.a == L.user) then
          local o = g.h == L.user and g.a or g.h
          left[o] = (left[o] or 0) + 1
        end
      end
    end
  end
  local season = L.phase == "season"
  local cols = { { "W", 200 }, { "L", 226 }, { "GB", 262 }, { "#", 292 }, { "vs", 318 }, { "STK", 356 }, { "L10", 392 } }
  for _, c in ipairs(cols) do Text.draw(c[1], c[2], y - 2, UI.fonts.body, nil, "right") end
  gfx.drawLine(4, y + 11, 392, y + 11)
  y = y + 15
  for i, T in ipairs(PL.standings(L)) do
    local mine = T.abbr == L.user
    if mine then gfx.fillRect(2, y - 2, 392, 18) end
    local col = mine and "white" or nil
    Text.draw(i .. ".", 18, y + 1, UI.fonts.bold, col, "right")
    if not mine then PUI.logo(T.abbr, 22, y - 1, 16) end
    Text.draw(PUI.teamName(T.abbr), 42, y + 1, mine and UI.fonts.bold or UI.fonts.body, col)
    -- # : the magic number inside the top four, the elimination number outside it
    local num = "-"
    if season then
      if i <= 4 then
        local m = PL.magic(L, T.abbr)
        num = m and (m <= 0 and "IN" or ("M" .. m)) or "-"
      else
        local e = PL.elimination(L, T.abbr)
        num = e and (e <= 0 and "OUT" or ("E" .. e)) or "-"
      end
    end
    local vals = { T.w, T.l, PL.gbText(T.gb), num, mine and "" or tostring(left[T.abbr] or 0), PL.streakText(T), PL.l10(T) }
    for k, c in ipairs(cols) do Text.draw(tostring(vals[k]), c[2], y + 1, k == 4 and UI.fonts.bold or UI.fonts.body, col, "right") end
    Lb:link(2, y - 2, 392, 18, function() PennantUI.Team.open({ abbr = T.abbr }) end, { id = "t" .. T.abbr, style = "ring", hint = "A: " .. PUI.nick(T.abbr) .. " roster (scouting).  RS " .. T.rs .. "  RA " .. T.ra .. "  PCT " .. PM.rate3(PL.pct(T)) })
    if i == 4 then gfx.setPattern(UI.pat.gray) gfx.fillRect(4, y + 16, 388, 1) gfx.setColor(gfx.kColorBlack) end
    y = y + 19
  end
  Text.draw(Text.ellipsize("Top 4 make the playoffs.  M: magic #  E: elimination #  vs: games left with you", UI.fonts.body, 388), 4, y, UI.fonts.body)
  return y + 13
end

function League:schedule(Lb, y)
  local L = Pennant.L
  local lastRound = nil
  local focusSet = false
  for d, day in ipairs(L.sched) do
    local g = PL.gameFor(L, L.user, d)
    if g then
      local home = g.h == L.user
      local opp = home and g.a or g.h
      local txt = PL.date(L, d) .. "  " .. (home and "vs " or "at ") .. PUI.nick(opp)
      if day.po then txt = txt .. "  (playoffs)" end
      local res = ""
      if g.done then
        local me, them = home and g.hs or g.as, home and g.as or g.hs
        res = (me > them and "W " or (me < them and "L " or "T ")) .. me .. "-" .. them .. ((g.inn or 9) > 9 and (" (" .. g.inn .. ")") or "")
      end
      local sep = day.round ~= lastRound and not day.po
      if sep then lastRound = day.round end
      local f = (d == L.day) and UI.fonts.bold or UI.fonts.body
      local ry = y
      PUI.lazy(Lb, 4, ry - 1, 388, 15, function()
        -- (the series divider sits in the gap above the row, clear of both rows' text)
        if sep then gfx.setPattern(UI.pat.gray) gfx.drawLine(4, ry - 2, 392, ry - 2) gfx.setColor(gfx.kColorBlack) end
        Text.draw(txt, 8, ry + 1, f)
        Text.draw(res, 300, ry + 1, UI.fonts.bold)
      end)
      if g.box and L.boxes[g.box] then
        Lb:link(4, y - 1, 388, 15, function() PennantUI.Box.open({ key = g.box }) end, { id = "d" .. d, style = "invert", hint = "A: box score" })
      elseif d >= L.day and not focusSet then
        Lb:link(4, y - 1, 388, 15, function() end, { id = "d" .. d, style = "invert", hint = d == L.day and "Today" or "Upcoming" })
      end
      if d == L.day then focusSet = true self.todayId = "d" .. d end
      y = y + 15
    end
  end
  return y
end

function League:initialFocus()
  if self.tab == "sched" and self.todayId then
    for i, l in ipairs(self.links) do if l.id == self.todayId then return i end end
  end
  return 1
end

local LEAD <const> = {
  { "avg", "Batting average" }, { "hr", "Home runs" }, { "rbi", "Runs batted in" }, { "sb", "Stolen bases" },
  { "ops", "OPS" }, { "h", "Hits" }, { "era", "ERA" }, { "w", "Wins" }, { "pk", "Strikeouts" }, { "sv", "Saves" },
}

function League:leaders(Lb, y)
  local L = Pennant.L
  for i, e in ipairs(LEAD) do
    local col = (i - 1) % 2
    local x = 6 + col * 196
    if col == 0 and i > 1 then y = y + 74 end
    local by = y
    -- (each block scans every player: done when it scrolls into view)
    PUI.lazy(Lb, x - 2, by - 1, 194, 70, function()
      Text.draw(e[2], x, by, UI.fonts.bold)
      local yy = by + 14
      for r, l in ipairs(PL.leaders(L, e[1], 4)) do
        local p = L.players[l.id]
        local mine = p.team == L.user
        Text.draw(r .. ". " .. Text.ellipsize(PM.short(p), UI.fonts.body, 100), x, yy, mine and UI.fonts.bold or UI.fonts.body)
        Text.draw(p.team, x + 132, yy, UI.fonts.body)
        Text.draw(PL.leaderText(e[1], l.v), x + 186, yy, UI.fonts.bold, nil, "right")
        yy = yy + 13
      end
    end)
    if col == 1 or i == #LEAD then
      Lb:link(x - 2, y - 1, 192, 70, function() end, { id = "l" .. i, style = "ring", hint = "Qualified: 2.7 PA (hitters) or 1 IP (pitchers) per team game" })
    end
  end
  return y + 76
end

function League:history(Lb, y)
  local L = Pennant.L
  Text.draw("PENNANT WINNERS", 6, y, UI.fonts.head)
  y = y + 18
  if #L.history == 0 then
    Text.draw("No seasons finished yet. Make some history.", 6, y, UI.fonts.body)
    y = y + 16
  end
  for i = #L.history, 1, -1 do
    local h = L.history[i]
    PUI.logo(h.champ, 6, y, 16)
    Text.draw(h.year .. "  " .. PUI.teamName(h.champ), 26, y + 1, UI.fonts.bold)
    Text.draw("over " .. PUI.nick(h.runnerUp or ""), 250, y + 1, UI.fonts.body)
    y = y + 17
    local y0 = y - 17
    local bh = Text.block(string.format("You: %d-%d (%s)  MVP %s  Pitcher %s  Rookie %s", h.w, h.l, PUI.ord(h.rank), h.mvp or "-", h.cy or "-", h.roy or "-"), 26, y, 364, UI.fonts.body, nil, 2)
    y = y + math.max(13, bh) + 3
    Lb:link(2, y0, 390, y - y0 - 1, function() end, { id = "h" .. i, style = "ring", hint = h.year .. " season" })
  end
  y = PUI.head(Lb, "Franchise: " .. PUI.teamName(L.user), 6, y + 6, 386)
  local T = L.teams[L.user]
  local w, l, titles = 0, 0, 0
  for _, h in ipairs(T.hist or {}) do w = w + h[2] l = l + h[3] end
  for _, h in ipairs(L.history) do if h.champ == L.user then titles = titles + 1 end end
  local ns = #(T.hist or {})
  Text.draw(string.format("%d season%s, %d-%d, %d pennant%s", ns, ns == 1 and "" or "s", w, l, titles, titles == 1 and "" or "s"), 6, y, UI.fonts.body)
  y = y + 16
  -- the user's award winners
  for id, p in pairs(L.players) do
    if p.awards and p.team == L.user then
      Text.drawFit("\u{2605} " .. PM.name(p) .. ": " .. p.awards:gsub(";", ", "), 6, y, 386, UI.fonts.body)
      y = y + 14
    end
  end
  return y
end

-- Box score --------------------------------------------------------------------------------------

local Box = PUI.define({ title = "Box score", hint = "crank / up-down: scroll" })
PennantUI.Box = Box

function Box:init(args) self.key = args.key end

local function name(L, id) local p = L.players[id] return p and PM.short(p) or "?" end

function PennantUI.lineScore(L, b, x, y)
  local inn = math.max(9, b.inn or 9)
  local cw = math.min(18, math.floor(220 / inn))
  Text.draw("", x, y, UI.fonts.body)
  for i = 1, inn do Text.draw(tostring(i), x + 44 + (i - 1) * cw + cw // 2, y, UI.fonts.body, nil, "center") end
  local rx = x + 44 + inn * cw + 6
  Text.draw("R", rx + 8, y, UI.fonts.bold, nil, "center")
  Text.draw("H", rx + 30, y, UI.fonts.bold, nil, "center")
  Text.draw("E", rx + 52, y, UI.fonts.bold, nil, "center")
  gfx.drawLine(x, y + 13, rx + 62, y + 13)
  for k, side in ipairs({ { b.a, b.away }, { b.h, b.home } }) do
    local yy = y + 15 + (k - 1) * 14
    Text.draw(side[1], x + 2, yy, UI.fonts.bold)
    for i = 1, inn do
      local v = side[2].line and side[2].line[i]
      local s = v and tostring(v) or ((k == 2 and i >= 9 and i == (b.inn or 9)) and "x" or "")
      Text.draw(s, x + 44 + (i - 1) * cw + cw // 2, yy, UI.fonts.body, nil, "center")
    end
    Text.draw(tostring(side[2].r), rx + 8, yy, UI.fonts.bold, nil, "center")
    Text.draw(tostring(side[2].h), rx + 30, yy, UI.fonts.body, nil, "center")
    Text.draw(tostring(side[2].e), rx + 52, yy, UI.fonts.body, nil, "center")
  end
  return y + 46
end

function PennantUI.boxLines(Lb, L, b, y)
  local hx = { 200, 226, 252, 278, 304, 330, 356, 386 }
  for _, side in ipairs({ { b.a, b.away }, { b.h, b.home } }) do
    y = PUI.head(Lb, PUI.teamName(side[1]), 4, y, 388)
    for i, h in ipairs({ "AB", "R", "H", "RBI", "BB", "K", "HR" }) do Text.draw(h, hx[i], y, UI.fonts.body, nil, "right") end
    y = y + 14
    for _, ln in ipairs(side[2].bat) do
      local ry = y
      PUI.lazy(Lb, 4, ry, 390, 13, function()
        Text.draw(name(L, ln[1]), 8, ry, UI.fonts.body)
        for i = 2, 8 do Text.draw(tostring(ln[i]), hx[i - 1], ry, UI.fonts.body, nil, "right") end
      end)
      y = y + 13
    end
    y = y + 4
    for i, h in ipairs({ "IP", "H", "R", "ER", "BB", "K", "NP" }) do Text.draw(h, hx[i], y, UI.fonts.body, nil, "right") end
    y = y + 14
    for _, ln in ipairs(side[2].pit) do
      local ry = y
      PUI.lazy(Lb, 4, ry, 390, 13, function()
        local dec = (ln[1] == b.W and " (W)") or (ln[1] == b.L and " (L)") or (ln[1] == b.S and " (S)") or ""
        Text.draw(name(L, ln[1]) .. dec, 8, ry, UI.fonts.body)
        Text.draw(string.format("%d.%d", ln[2] // 3, ln[2] % 3), hx[1], ry, UI.fonts.body, nil, "right")
        for i = 3, 8 do Text.draw(tostring(ln[i]), hx[i - 1], ry, UI.fonts.body, nil, "right") end
      end)
      y = y + 13
    end
    y = y + 6
  end
  return y
end

function Box:layout(Lb)
  local L = Pennant.L
  local b = L.boxes[self.key]
  if not b then Text.draw("Box score not kept.", 10, 10, UI.fonts.body) return end
  Text.draw(PUI.teamName(b.a) .. " at " .. PUI.teamName(b.h), 4, 2, UI.fonts.head)
  Text.draw(PL.date(L, b.d) .. " \u{2022} " .. PennantClubs.byAbbr[b.h].park, 4, 18, UI.fonts.body)
  local y = PennantUI.lineScore(L, b, 4, 34)
  y = PennantUI.boxLines(Lb, L, b, y + 2)
  Lb:link(0, 0, 10, 10, function() end, { id = "top", style = "none" })
  Lb:mark(y)
end
