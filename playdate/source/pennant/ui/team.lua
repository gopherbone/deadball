-- Team roster (hitters / pitchers / farm) with condition arrows, mood, fatigue and injuries,
-- and the player card: ratings with grades, caps and weekly trend, potential, stats, actions.

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

local Team = PUI.define({ title = "Team", hint = "A: player card  left/right on the tabs: switch" })
PennantUI.Team = Team

function Team:init(args)
  self.tab = args.tab or "bat"
  self.abbr = args.abbr or Pennant.L.user
end
function Team:resume(r) Page.resume(self, r) self:render(true) end

function Team:list()
  local L = Pennant.L
  local T = L.teams[self.abbr]
  local out = {}
  if self.tab == "farm" then
    for _, id in ipairs(T.farm) do out[#out + 1] = L.players[id] end
    table.sort(out, function(a, b) if (a.pos == "P") ~= (b.pos == "P") then return b.pos == "P" end return PM.ovr(a) > PM.ovr(b) end)
  else
    local pit = self.tab == "pit"
    for _, id in ipairs(T.ml) do local p = L.players[id] if (p.pos == "P") == pit then out[#out + 1] = p end end
    local ORDER = { C = 1, ["1B"] = 2, ["2B"] = 3, ["3B"] = 4, SS = 5, LF = 6, CF = 7, RF = 8 }
    table.sort(out, function(a, b)
      if pit then
        if (a.role == "SP") ~= (b.role == "SP") then return a.role == "SP" end
        return PM.ovr(a) > PM.ovr(b)
      end
      if a.pos ~= b.pos then return (ORDER[a.pos] or 9) < (ORDER[b.pos] or 9) end
      return PM.ovr(a) > PM.ovr(b)
    end)
  end
  return out
end

function Team:layout(Lb)
  local L = Pennant.L
  local T = L.teams[self.abbr]
  local mine = self.abbr == L.user
  local y = PUI.tabs(Lb, {
    { "bat", "Hitters", function() self.tab = "bat" self:render() end },
    { "pit", "Pitchers", function() self.tab = "pit" self:render() end },
    { "farm", PennantClubs.byAbbr[self.abbr].farm[2] .. " (farm)", function() self.tab = "farm" self:render() end },
  }, self.tab, 2)
  local active = PRoster.activeCount(L, T)
  Text.draw(mine and (active .. "/26 active") or PUI.teamName(self.abbr), 392, 4, UI.fonts.body, nil, "right")
  local extra = self.tab == "pit" and "ERA  W-L" or (self.tab == "farm" and "AGE  POT" or "AVG  HR")
  PUI.rowHeader(4, y - 2, extra)
  y = y + 12
  self.order = self:list()
  for i, p in ipairs(self.order) do
    local ex
    if self.tab == "farm" then ex = p.age .. "   " .. string.rep("\u{2605}", PM.potStars(p))
    elseif p.pos == "P" then ex = string.format("%.2f %d-%d", PM.era(p.st.p), p.st.p.w or 0, p.st.p.l or 0)
    else ex = PM.rate3(PM.avg(p.st.b)) .. " " .. (p.st.b.hr or 0) end
    if p.inj then ex = p.inj.k .. " (" .. p.inj.d .. "d)" end
    local hint = PM.name(p) .. ", " .. p.age .. ". " .. PM.COND_NAME[p.cond] .. " condition, " .. PM.MOOD_NAME[p.mood or 0]:lower() .. (p.inj and (". Out until " .. PL.date(L, L.day + p.inj.d)) or "")
    PUI.playerRow(Lb, p, 4, y, 388, function() PennantUI.Card.open({ list = self.order, i = i }) end, { extra = ex, hint = hint, id = "p" .. p.id, compact = true })
    y = y + 13
  end
  Lb:mark(y)
end

function Team:initialFocus()
  for i, l in ipairs(self.links) do if l.id and l.id:sub(1, 1) == "p" then return i end end
  return 1
end

-- Player card --------------------------------------------------------------------------------------

local Card = PUI.define({ title = "Player", hint = "Crank: another player  left/right on the tabs: Ratings / Stats" })
PennantUI.Card = Card

function Card:init(args)
  self.list = args.list
  self.i = args.i or 1
  self.pg = args.pg or "rat"
end
function Card:resume(r) Page.resume(self, r) self:render(true) end

function Card:player() return self.list[self.i] end

function Card:title()
  local p = self:player()
  return p and PM.name(p) or "Player"
end

local function trendMark(d)
  if not d or d == 0 then return "" end
  return (d > 0 and "\u{25b2}" or "\u{25bc}") .. math.abs(d)
end

--- The two pages (Ratings | Stats) and prev / next, along the bottom of both.
function Card:footer(Lb)
  local y = 190
  local function flip(d) self.pg = (self.pg == "rat") and "stats" or "rat" self:render(true) end
  local tx = 6
  for _, t in ipairs({ { "rat", "Ratings" }, { "stats", "Stats" } }) do
    local on = self.pg == t[1]
    local w = UI.fonts.bold:getTextWidth(t[2]) + 14
    local ty = Text.boxY(UI.fonts.bold, y + 1, 15, t[2])
    if on then gfx.fillRect(tx, y, w, 17) Text.draw(t[2], tx + 7, ty, UI.fonts.bold, "white")
    else gfx.drawRect(tx, y, w, 17) Text.draw(t[2], tx + 7, ty, UI.fonts.bold) end
    local key = t[1]
    Lb:link(tx, y, w, 17, function() if self.pg ~= key then flip() end end, PUI.opts("pg:" .. key, "Left/right: Ratings / Stats", function(d) flip(d) end, "ring"))
    tx = tx + w + 3
  end
  Text.draw((self.i) .. "/" .. #self.list, 240, y + 2, UI.fonts.body, nil, "right")
  Lb:button("\u{25c0} Prev", 248, y, 70, 17, function() self:step(-1) end, PUI.opts("prev", "Previous player (or crank)", function(d) self:step(d, true) end, "ring"))
  Lb:button("Next \u{25b6}", 322, y, 70, 17, function() self:step(1) end, PUI.opts("next", "Next player (or crank)", function(d) self:step(d, true) end, "ring"))
  Lb:mark(y + 18)
end

function Card:cranked(change)
  self.crankAcc = (self.crankAcc or 0) + change
  if math.abs(self.crankAcc) >= 90 then
    local d = self.crankAcc > 0 and 1 or -1
    self.crankAcc = 0
    self:step(d)
    Sfx.detent()
  end
end

function Card:layout(Lb)
  local L = Pennant.L
  local p = self:player()
  if not p then return end
  local mine = p.team == L.user
  if self.pg == "stats" then return self:layoutStats(Lb, p) end
  -- face
  Faces.draw("face:" .. p.face, 6, 4, 96, { double = false })
  -- identity
  local x = 110
  Text.draw(PM.name(p), x, 2, UI.fonts.big)
  local posTxt = p.pos == "P" and (p.role == "SP" and "Starting pitcher" or "Relief pitcher") or (({ C = "Catcher", ["1B"] = "First base", ["2B"] = "Second base", ["3B"] = "Third base", SS = "Shortstop", LF = "Left field", CF = "Center field", RF = "Right field" })[p.pos] or p.pos)
  Text.draw(string.format("%s \u{2022} Age %d \u{2022} B/T %s/%s%s", posTxt, p.age, p.bats, p.throws, (p.pos2 and p.pos2 ~= p.pos and p.pos ~= "P") and (" \u{2022} also " .. p.pos2) or ""), x, 26, UI.fonts.body)
  Text.draw(PUI.teamName(p.team) .. (p.lvl == "F" and " (farm)" or "") .. (p.rk and "  \u{2022} ROOKIE" or ""), x, 40, UI.fonts.body)
  -- overall / potential / condition
  local o = PM.ovr(p)
  PUI.grade(x, 56, o, true)
  Text.draw("OVR " .. o, x + 17, 56, UI.fonts.bold)
  Text.draw("POT", x + 78, 56, UI.fonts.body)
  PUI.stars(x + 104, 55, PM.potStars(p))
  -- status strip
  local sy = 74
  if p.inj then
    PUI.cross(x, sy + 1)
    Text.draw("Injured: " .. p.inj.k .. ", back " .. PL.date(L, L.day + p.inj.d) .. " (" .. p.inj.d .. " days)", x + 16, sy, UI.fonts.bold)
  else
    PUI.arrow(x, sy + 1, p.cond)
    Text.draw(PM.COND_NAME[p.cond], x + 16, sy, UI.fonts.bold)
    PUI.mood(x + 74, sy + 1, p.mood)
    Text.draw(PM.MOOD_NAME[p.mood or 0], x + 90, sy, UI.fonts.body)
    Text.draw("Fatigue", x + 158, sy, UI.fonts.body)
    PUI.fatigue(x + 204, sy + 4, p.fat, 60)
  end
  -- ratings
  local ry = 94
  local keys = PM.keys(p)
  for _, k in ipairs(keys) do
    local v = math.floor(p.r[k])
    Text.draw(PM.LABEL[k], x, ry, UI.fonts.body)
    PUI.grade(x + 62, ry, v)
    Text.draw(k == "velo" and (PM.mph(v) .. " mph") or tostring(v), x + 80, ry, UI.fonts.bold)
    PUI.bar(x + 130, ry + 3, v, p.cap[k], 110, 7)
    local d = p.wk and (v - math.floor(p.wk[k] or v)) or 0
    local ds = p.s0 and (v - math.floor(p.s0[k] or v)) or 0
    Text.draw(trendMark(d), x + 246, ry, UI.fonts.bold)
    if ds ~= 0 then Text.draw((ds > 0 and "+" or "") .. ds .. " yr", x + 278, ry, UI.fonts.body) end
    ry = ry + 14
  end
  if p.pos == "P" then
    Text.draw("Pitches", x, ry, UI.fonts.body)
    local px = x + 62
    for _, pt in ipairs(p.pitches) do
      local w = Text.draw(pt.k, px, ry, UI.fonts.bold)
      PUI.grade(px + w + 3, ry, pt.q)
      px = px + w + 22
    end
    if p.pitchDev then Text.draw("learning " .. p.pitchDev, px + 4, ry, UI.fonts.body) end
    ry = ry + 16
  end
  -- under the face: plan + moves
  local ly = 124
  if mine then
    local plan = p.plan or { i = 2 }
    Text.draw("Training", 6, ly, UI.fonts.bold)
    local fl = PL.FOCUS_NAME[plan.f or ""] or "-"
    Lb:link(4, ly + 14, 98, 15, function() PennantUI.Training.open({ focusId = p.id }) end,
      PUI.opts("plan", "A: the training screen", nil))
    Text.draw(Text.ellipsize(fl .. ", " .. PL.INTENSITY[(plan.i or 2) + 1], UI.fonts.body, 96), 6, ly + 15, UI.fonts.body)
    local gain = PL.weekly(p, plan.f or (p.pos == "P" and "ctl" or "con"), plan.i or 2)
    Text.draw(string.format("~+%.1f / week", gain), 6, ly + 29, UI.fonts.body)
    local T = L.teams[p.team]
    if p.lvl == "F" then
      Lb:button("Call up", 4, ly + 46, 98, 17, function()
        local ok, err = PRoster.callUp(L, T, p.id)
        if ok then PRoster.validate(L, T) PL.news(L, "CALLED UP: " .. PM.name(p) .. " (" .. p.pos .. ")", true) PennantUI.CallUp.open({ p = p }) else Toast.show(err, "bad") end
        self:render(true)
      end, { id = "move", hint = "Bring him up to the big club" })
    else
      Lb:button("Send down", 4, ly + 46, 98, 17, function()
        local ok, err = PRoster.demote(L, T, p.id)
        if ok then PRoster.validate(L, T) Toast.show(PM.short(p) .. " sent to " .. PennantClubs.byAbbr[p.team].farm[2] .. ".", nil) else Toast.show(err, "bad") end
        self:render(true)
      end, { id = "move", hint = "Option him to the farm club (he won't like it)" })
    end
  end
  self:footer(Lb)
end

function Card:layoutStats(Lb, p)
  local L = Pennant.L
  Faces.draw("face:" .. p.face, 6, 4, 48)
  Text.draw(PM.name(p), 62, 4, UI.fonts.big)
  Text.draw(string.format("%s \u{2022} Age %d \u{2022} %s", p.pos == "P" and (p.role or "P") or p.pos, p.age, PUI.teamName(p.team)), 62, 28, UI.fonts.body)
  local sy2 = PUI.head(Lb, "Stats", 6, 68, 386)
  local function batRow(lbl, s, yy)
    Text.draw(lbl, 6, yy, UI.fonts.bold)
    Text.draw(string.format("G %d  AB %d  H %d  2B %d  3B %d  HR %d  RBI %d  BB %d  K %d  SB %d", s.g or 0, s.ab or 0, s.h or 0, s.d or 0, s.t or 0, s.hr or 0, s.rbi or 0, s.bb or 0, s.k or 0, s.sb or 0), 60, yy, UI.fonts.body)
    Text.draw(string.format("AVG %s  OBP %s  SLG %s", PM.rate3(PM.avg(s)), PM.rate3(PM.obp(s)), PM.rate3(PM.slg(s))), 60, yy + 13, UI.fonts.body)
    return yy + 28
  end
  local function pitRow(lbl, s, yy)
    Text.draw(lbl, 6, yy, UI.fonts.bold)
    Text.draw(string.format("G %d  GS %d  W %d  L %d  SV %d  HLD %d  IP %s", s.g or 0, s.gs or 0, s.w or 0, s.l or 0, s.sv or 0, s.hld or 0, PM.ip(s)), 60, yy, UI.fonts.body)
    Text.draw(string.format("ERA %.2f  WHIP %.2f  H %d  BB %d  K %d  HR %d", PM.era(s), PM.whip(s), s.h or 0, s.bb or 0, s.k or 0, s.hr or 0), 60, yy + 13, UI.fonts.body)
    return yy + 28
  end
  if p.pos == "P" then
    sy2 = pitRow(tostring(L.year), p.st.p, sy2)
    sy2 = pitRow("Career", p.car.p, sy2)
  else
    sy2 = batRow(tostring(L.year), p.st.b, sy2)
    sy2 = batRow("Career", p.car.b, sy2)
  end
  Text.draw(string.format("Pro seasons %d \u{2022} big-league seasons %d", p.yrs or 0, p.mlYrs or 0), 6, sy2, UI.fonts.body)
  sy2 = sy2 + 14
  if p.awards then
    for a in p.awards:gmatch("[^;]+") do Text.draw("\u{2605} " .. a, 6, sy2, UI.fonts.bold) sy2 = sy2 + 14 end
  end
  self:footer(Lb)
end

function Card:step(d, noRender)
  self.i = (self.i - 1 + d) % #self.list + 1
  self.scroll:jump(0)
  if not noRender then self:render(true) end
end

function Card:initialFocus()
  for i, l in ipairs(self.links) do if l.id == "next" then return i end end
  return 1
end
