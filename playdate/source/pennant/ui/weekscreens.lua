--[[ The week turn's other screens (pennant/week.lua):
  WeekReport   the week's games, each unit before / after, ALSO THIS WEEK, the goal
  Goals        the season's goal ladder; a cleared goal's reward pick; the month's turn
  Clubhouse    a team-level event between days, three choices
  SeriesPlan   a key series: the scouting strip and three game plans
  All are single cached images per state; a frame is a blit or two.
]]

local gfx <const> = playdate.graphics
local floor, max, min = math.floor, math.max, math.min
PennantUI = PennantUI or {}
local function F() return UI.fonts end

local function scene(name)
  local S = { opaque = true }
  S.__index = S
  S.open = function(args) local s = setmetatable({}, S) App.push(s, args or {}) return s end
  PennantUI[name] = S
  return S
end

local function window(x, y, w, h, title, right)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 3, y + 3, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2) gfx.drawRect(x, y, w, h) gfx.setLineWidth(1)
  gfx.fillRect(x, y, w, 15)
  Text.draw(title, x + 6, Text.boxY(F().bold, y, 15), F().bold, "white")
  if right then Text.draw(right, x + w - 6, Text.boxY(F().body, y, 15), F().body, "white", "right") end
end

local function panelHead(x, y, w, left, right)
  gfx.fillRect(x, y, w, 14)
  Text.draw(left, x + 4, Text.boxY(F().bold, y, 14), F().bold, "white")
  if right then Text.draw(right, x + w - 4, Text.boxY(F().body, y, 14), F().body, "white", "right") end
end

-- WEEK REPORT ------------------------------------------------------------------------------------------

local Rep = scene("WeekReport")

local function unitX(v) return floor((math.max(30, math.min(80, v)) - 30) / 50 * 98 + 0.5) end

function Rep:enter(args)
  local L = Pennant.L
  self.rep, self.onDone, self.review = args.rep, args.onDone, args.review
  local r = self.rep
  self.t = 0
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  local title
  if r.po then title = "SERIES REPORT"
  else title = "WEEK " .. r.w .. " REPORT" end
  title = title .. " \u{2022} " .. PWeek.PROG[r.prog].name .. (r.prog ~= "rest" and (" \u{2022} " .. PWeek.INT[r.int]) or "")
  PennantUI.weekTop(title, nil, (r.po and "" or ("WEEK " .. r.ww .. "-" .. r.wl .. " \u{2022} ")) .. r.tw .. "-" .. r.tl)
  -- the days
  local n = math.max(7, #r.days)
  local cw = (392 - (n - 1) * 3) // n
  for i, d in ipairs(r.days) do
    if i > n then break end
    local x = 4 + (i - 1) * (cw + 3)
    local y = 21
    if d.off then gfx.setPattern(UI.pat.lighter) gfx.fillRect(x, y, cw, 28) gfx.setColor(gfx.kColorBlack) gfx.drawRect(x, y, cw, 28)
    elseif d.won then gfx.fillRect(x, y, cw, 28)
    else gfx.drawRect(x, y, cw, 28) end
    local col = d.won and "white" or nil
    local top = PL.date(L, d.d):upper() .. (d.feat and " \u{2605}" or "")
    Text.draw(Text.ellipsize(top, F().body, cw - 4), x + cw // 2, y + 1, F().body, col, "center")
    local res = d.off and "OFF" or (d.done and ((d.won and "W " or "L ") .. d.me .. "-" .. d.them) or "-")
    Text.draw(Text.ellipsize(res, F().bold, cw - 4), x + cw // 2, y + 14, F().bold, col, "center")
  end
  -- the club, unit by unit
  local bx, by, bw, bh = 4, 54, 248, 152
  gfx.drawRect(bx, by, bw, bh)
  panelHead(bx, by, bw, "THE CLUB", "BEFORE \u{25b6} AFTER")
  local y = by + 18
  for _, k in ipairs(PWeek.UNITS) do
    local a, b = r.u0[k] or 0, r.u1[k] or 0
    Text.draw(PWeek.UNIT_NAME[k], bx + 4, y, F().body)
    local x0 = bx + 74
    gfx.setColor(gfx.kColorWhite) gfx.fillRect(x0, y + 2, 100, 9) gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(x0, y + 2, 100, 9)
    local wa, wb = unitX(a), unitX(b)
    local lo = math.min(wa, wb)
    if lo > 0 then gfx.setPattern(UI.pat.gray) gfx.fillRect(x0 + 1, y + 3, lo, 7) gfx.setColor(gfx.kColorBlack) end
    if wb ~= wa then gfx.fillRect(x0 + 1 + lo, y + 3, math.abs(wb - wa), 7) end
    local d = b - a
    local ds = math.abs(d) < 0.05 and "\u{2022}" or string.format("%+.1f", d)
    Text.draw(ds, bx + 200, y, F().bold, nil, "right")
    local ga, gb = PWeek.grade(a), PWeek.grade(b)
    local gs = (a <= 0) and "-" or (ga == gb and gb or (ga .. " \u{25b6} " .. gb))
    gfx.fillRect(bx + 204, y - 1, 40, 14)
    Text.draw(gs, bx + 224, Text.boxY(F().bold, y - 1, 14), F().bold, "white", "center")
    y = y + 22
  end
  -- also this week
  local px, pw = 258, 138
  gfx.drawRect(px, by, pw, bh)
  panelHead(px, by, pw, "ALSO THIS WEEK")
  y = by + 18
  for i, nline in ipairs(r.notes) do
    if i > 7 then break end
    local f = nline[2] and F().bold or F().body
    Text.draw(Text.ellipsize(nline[1], f, pw - 8), px + 4, y, f)
    y = y + 14
  end
  if r.goal then
    local gy = by + bh - 24
    gfx.fillRect(px + 4, gy, pw - 8, 20)
    local s = Text.ellipsize(r.goal.text:gsub(":.*", "") .. " " .. r.goal.prog, F().bold, pw - 14)
    Text.draw(s, px + pw // 2, Text.boxY(F().bold, gy, 20), F().bold, "white", "center")
  end
  PUI.hintBar(self.review and "A/B: back" or "A: next week   B: player details")
  gfx.popContext()
  self.img = img
  if not self.review then Sfx.stinger((r.ww or 0) >= (r.wl or 0) and "bet_won" or "bet_lost") end
end

function Rep:update()
  self.t = self.t + 1
  self.img:draw(0, 0)
end

function Rep:AButtonDown()
  if self.t < 6 then return end
  Sfx.select()
  App.pop()
  if self.onDone then self.onDone() end
end

function Rep:BButtonDown()
  if self.review then self:AButtonDown() return end
  local L = Pennant.L
  if L.weekRep and #(L.weekRep.rows or {}) > 0 then
    L.weekRep.seen = false
    PennantUI.TrainingResults.open({})
  else
    Toast.show("No player changes to show this week.", nil)
  end
end

-- GOALS: the ladder, a reward pick, the month's turn ---------------------------------------------------

local Goals = scene("Goals")

local MONTHS <const> = { 4, 5, 6, 7, 8, 9, 10 }

function Goals:enter(args)
  local L = Pennant.L
  local c = L.club
  self.t = 0
  self.onDone = args.onDone
  self.mode = (args.reward and c.rewards and #c.rewards > 0) and "reward" or (args.note and c.monthNote and "note")
    or ((args.pick or args.note) and c.goalOffer and "pick") or "view"
  self.sel = 1
  self.note = c.monthNote
  if self.mode == "note" then c.monthNote = nil end
  self:paint()
  if self.mode == "reward" then Sfx.stinger("win") end
end

function Goals:paint()
  local L = Pennant.L
  local c = L.club
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  PennantUI.weekTop("SEASON GOALS \u{2022} " .. L.year, nil, "NO PENALTY FOR A MISS")
  -- the ladder
  local byM = {}
  for _, g in ipairs(c.goals) do byM[g.m] = g end
  local cur = c.goal
  gfx.setLineWidth(2) gfx.drawLine(20, 26, 20, 214) gfx.setLineWidth(1)
  local y = 22
  for _, m in ipairs(MONTHS) do
    local g = byM[m]
    local st, text, right = "lock", nil, ""
    if g then st, text, right = g.state, g.text, (g.state == "done" and ("DONE " .. (g.res or "")) or "MISSED")
    elseif cur and cur.m == m then st, text, right = "now", cur.text, "NOW " .. (PWeek.goalProgress(L, cur)) end
    if not text then text = m == 10 and "OCTOBER: A BONUS, IF YOU'RE IN" or "SET AT THE MONTH'S START" end
    -- the dot
    local dx, dy = 6, y
    if st == "done" then gfx.fillRect(dx, dy, 28, 22)
    elseif st == "lock" then gfx.setPattern(UI.pat.light) gfx.fillRect(dx, dy, 28, 22) gfx.setColor(gfx.kColorBlack) gfx.drawRect(dx, dy, 28, 22)
    else gfx.setColor(gfx.kColorWhite) gfx.fillRect(dx, dy, 28, 22) gfx.setColor(gfx.kColorBlack) gfx.setLineWidth(2) gfx.drawRect(dx, dy, 28, 22) gfx.setLineWidth(1) end
    local mk = PWeek.MONTH[m]
    Text.draw(mk, dx + 14, Text.boxY(F().bold, dy, 22), F().bold, st == "done" and "white" or nil, "center")
    -- the row
    local rx, rw = 38, 214
    if st == "lock" then gfx.setPattern(UI.pat.lighter) gfx.fillRect(rx, dy, rw, 22) gfx.setColor(gfx.kColorBlack)
    else gfx.setColor(gfx.kColorWhite) gfx.fillRect(rx, dy, rw, 22) gfx.setColor(gfx.kColorBlack) end
    gfx.drawRect(rx, dy, rw, 22)
    local rwid = right ~= "" and F().body:getTextWidth(right) + 6 or 0
    local f = st == "lock" and F().body or F().bold
    local s = Text.ellipsize(text, f, rw - 8 - rwid)
    Text.draw(s, rx + 4, Text.boxY(f, dy, 22, s), f)
    if right ~= "" then Text.draw(right, rx + rw - 4, Text.boxY(F().body, dy, 22, right), F().body, nil, "right") end
    if st == "miss" then gfx.drawLine(rx + 4, dy + 11, rx + 4 + F().bold:getTextWidth(s), dy + 11) end
    y = y + 27
  end
  -- the right panel
  local px, pw = 258, 138
  if self.mode == "reward" then
    local rw = c.rewards[1]
    gfx.drawRect(px, 22, pw, 120)
    panelHead(px, 22, pw, "PICK A REWARD")
    Text.draw(Text.ellipsize(rw.text, F().body, pw - 8), px + 4, 39, F().body)
    self.optY = 56
  elseif self.mode == "pick" then
    gfx.drawRect(px, 22, pw, 142)
    panelHead(px, 22, pw, PWeek.MONTH_LONG[c.goalOffer[1].m] .. ": PICK ONE")
    Text.block("Clear it for a reward. Miss it: the club's a little down. That's all.", px + 4, 118, pw - 8, F().body, nil, 3)
    self.optY = 40
  else
    gfx.drawRect(px, 22, pw, 120)
    panelHead(px, 22, pw, "CLEAR A GOAL")
    Text.block("Pick one reward: a facility level, a scouted prospect, or a breather for everyone. A miss costs nothing.", px + 4, 39, pw - 8, F().body, nil, 7)
  end
  -- the stamp: this month's turn, or a cleared goal
  local stampText, sub
  if self.mode == "reward" then stampText, sub = "CLEARED", PWeek.MONTH_LONG[c.rewards[1].m] .. " GOAL"
  elseif self.note then
    stampText = self.note.state == "done" and "CLEARED" or "MISSED"
    sub = PWeek.MONTH_LONG[self.note.m] .. " GOAL"
  end
  if stampText then
    local s = gfx.image.new(118, 44, gfx.kColorClear)
    gfx.pushContext(s)
    gfx.setColor(gfx.kColorWhite) gfx.fillRect(0, 0, 118, 44) gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(3) gfx.drawRect(1, 1, 116, 42) gfx.setLineWidth(1)
    gfx.drawRect(5, 5, 108, 34)
    Text.draw(sub, 59, 7, F().body, nil, "center")
    Text.draw(stampText, 59, 20, F().head, nil, "center")
    gfx.popContext()
    local rot = s:rotatedImage(-8)
    rot:drawCentered(327, 186)
  end
  if self.mode == "note" and self.note and self.note.next then
    gfx.fillRect(px, 146, pw, 14)
    Text.draw("NEXT: " .. PWeek.MONTH[self.note.nm or 5], px + 4, Text.boxY(F().bold, 146, 14), F().bold, "white")
  end
  gfx.popContext()
  self.img = img
end

function Goals:update()
  self.t = self.t + 1
  self.img:draw(0, 0)
  if self.mode == "pick" then
    local L = Pennant.L
    local x, w = 262, 130
    for i, g in ipairs(L.club.goalOffer or {}) do
      local y = self.optY + (i - 1) * 38
      local on = i == self.sel
      if on then gfx.fillRect(x, y, w, 34) else gfx.setColor(gfx.kColorWhite) gfx.fillRect(x, y, w, 34) gfx.setColor(gfx.kColorBlack) gfx.drawRect(x, y, w, 34) end
      Text.block(g.text, x + 4, y + 2, w - 8, F().bold, on and "white" or nil, 2)
    end
    PUI.hintBar("\u{25b2}\u{25bc} choose   A: this month's goal")
  elseif self.mode == "reward" then
    local L = Pennant.L
    local x, w = 262, 130
    for i, r in ipairs(PWeek.REWARDS) do
      local y = self.optY + (i - 1) * 26
      local on = i == self.sel
      if on then gfx.fillRect(x, y, w, 23) else gfx.setColor(gfx.kColorWhite) gfx.fillRect(x, y, w, 23) gfx.setColor(gfx.kColorBlack) gfx.drawRect(x, y, w, 23) end
      local t = r.t
      if r.k == "fac" then local f = PWeek.rewardFac(L) if f then t = PWeek.PROG[f].fac .. " +1 LV" end end
      Text.draw(Text.ellipsize(t, F().bold, w - 8), x + 4, Text.boxY(F().bold, y, 23), F().bold, on and "white" or nil)
    end
    PUI.hintBar("\u{25b2}\u{25bc} choose   A: take it")
  elseif self.mode == "note" then
    PUI.hintBar("A: on to " .. (self.note and self.note.nm and PWeek.MONTH_LONG[self.note.nm]:lower() or "the next month"))
  else
    PUI.hintBar("A/B: back")
  end
end

function Goals:upButtonDown() if self.mode == "reward" or self.mode == "pick" then self.sel = math.max(1, self.sel - 1) Sfx.focus() end end
function Goals:downButtonDown() if self.mode == "reward" or self.mode == "pick" then self.sel = math.min(self.mode == "pick" and 2 or #PWeek.REWARDS, self.sel + 1) Sfx.focus() end end

function Goals:AButtonDown()
  if self.t < 6 then return end
  local L = Pennant.L
  local c = L.club
  if self.mode == "reward" then
    local what = PWeek.claim(L, PWeek.REWARDS[self.sel].k)
    Sfx.coin()
    Toast.show(what, "good")
    if c.rewards and #c.rewards > 0 then self:paint() self.sel = 1 return end
    if c.monthNote then
      self.mode = "note"
      self.note = c.monthNote
      c.monthNote = nil
      self:paint()
      return
    end
    if c.goalOffer then self.mode = "pick" self.sel = 1 self:paint() return end
  elseif self.mode == "pick" then
    PWeek.pickGoal(L, self.sel)
    Sfx.coin()
  elseif self.mode == "note" and c.goalOffer then
    Sfx.select()
    self.mode = "pick"
    self.sel = 1
    self:paint()
    return
  else
    Sfx.select()
  end
  App.pop()
  if self.onDone then self.onDone() end
end

function Goals:BButtonDown()
  if self.mode == "reward" or self.mode == "pick" then return end
  self:AButtonDown()
end

-- CLUBHOUSE EVENT --------------------------------------------------------------------------------------

local Club = scene("Clubhouse")

function Club:enter(args)
  local L = Pennant.L
  self.ev, self.onDone = args.ev, args.onDone
  self.e = PWeek.EVENT[self.ev.key]
  self.sel = 1
  self.t = 0
  self.state = "choose"
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  Draw.tile(0, 0, 400, 240, "light")
  local g = PL.gameFor(L, L.user)
  local where = g and (g.h == L.user and "AT HOME" or ("ON THE ROAD \u{2022} " .. PennantClubs.byAbbr[g.h].city:upper())) or ""
  local sp = PWeek.span(L)
  window(14, 8, 372, 210, "CLUBHOUSE", (sp.w and not sp.po and ("WEEK " .. sp.w .. " \u{2022} ") or "") .. where)
  -- the picture
  local photo = Archive.get(self.e.photo .. "-01", 96) or Archive.get(self.e.photo .. "-02", 96)
  gfx.setPattern(UI.pat.gray) gfx.fillRect(22, 30, 120, 70) gfx.setColor(gfx.kColorBlack)
  if photo then
    local pw, ph = photo:getSize()
    photo:draw(22 + (120 - pw) // 2, 30 + math.max(0, (70 - ph) // 2), gfx.kImageUnflipped, playdate.geometry.rect.new(0, 0, math.min(pw, 120), math.min(ph, 70)))
  end
  gfx.drawRect(22, 30, 120, 70)
  local title = PWeek.eventText(L, self.e.title)
  local hy = 30
  local hl = Text.wrap(title, F().head, 228)
  for i = 1, math.min(2, #hl) do Text.draw(hl[i], 150, hy, F().head) hy = hy + 16 end
  Text.block(PWeek.eventText(L, self.e.body), 150, hy + 2, 228, F().body, nil, 4)
  gfx.popContext()
  self.bg = img
  Sfx.stinger("new_mail")
end

function Club:update()
  self.t = self.t + 1
  self.bg:draw(0, 0)
  local x, w = 22, 356
  if self.state == "choose" then
    for i, o in ipairs(self.e.opts) do
      local y = 106 + (i - 1) * 36
      local on = i == self.sel
      if on then gfx.fillRect(x, y, w, 32) else gfx.setColor(gfx.kColorWhite) gfx.fillRect(x, y, w, 32) gfx.setColor(gfx.kColorBlack) gfx.drawRect(x, y, w, 32) end
      local col = on and "white" or nil
      Text.draw(Text.ellipsize((on and "\u{25b6} " or "") .. o.t, F().bold, w - 12), x + 6, y + 2, F().bold, col)
      Text.draw(Text.ellipsize(o.fx, F().body, w - 12), x + 6, y + 16, F().body, col)
    end
    PUI.hintBar("\u{25b2}\u{25bc} choose   A: decide")
  else
    gfx.setColor(gfx.kColorWhite) gfx.fillRect(x, 106, w, 104) gfx.setColor(gfx.kColorBlack) gfx.drawRect(x, 106, w, 104)
    local o = self.e.opts[self.sel]
    Text.draw(Text.ellipsize("YOU CHOSE: " .. o.t, F().bold, w - 12), x + 6, 110, F().bold)
    Text.block(o.fx, x + 6, 126, w - 12, F().body, nil, 2)
    local y = 158
    if self.out.lucky ~= nil then
      Text.draw(self.out.lucky and "IT WORKED." or "IT DIDN'T COME OFF.", x + 6, y, F().head)
      y = y + 18
    end
    for _, line in ipairs(self.out) do Text.block(line, x + 6, y, w - 12, F().body, nil, 2) y = y + 26 end
    PUI.hintBar("A: back to the week")
  end
end

function Club:upButtonDown() if self.state == "choose" then self.sel = math.max(1, self.sel - 1) Sfx.focus() end end
function Club:downButtonDown() if self.state == "choose" then self.sel = math.min(#self.e.opts, self.sel + 1) Sfx.focus() end end

function Club:AButtonDown()
  if self.t < 8 then return end
  if self.state == "choose" then
    Sfx.coin()
    self.out = PWeek.resolveEvent(Pennant.L, self.sel) or {}
    self.state = "result"
    self.t = 0
    return
  end
  Sfx.select()
  App.pop()
  if self.onDone then self.onDone() end
end
function Club:BButtonDown() end

PWeek.addStop({ id = "clubhouse", due = PWeek.stops[1] and PWeek.stops[1].due or function() return nil end,
  open = function(L, ev, onDone) PennantUI.Clubhouse.open({ ev = ev, onDone = onDone }) end })

-- SERIES PLAN ------------------------------------------------------------------------------------------------

local Plan = scene("SeriesPlan")

function Plan:enter(args)
  local L = Pennant.L
  self.stub, self.onDone = args.stub, args.onDone
  self.opts = PWeek.planOptions(L, self.stub.opp)
  self.sel = 1
  self.t = 0
  self.cards = {}
  local opp = self.stub.opp
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  local ng = PL.nextGame(L, L.user)
  local away = ng and ng.a == L.user
  local Ot, T = L.teams[opp], L.teams[L.user]
  local gb = ((Ot.w - T.w) + (T.l - Ot.l)) / 2
  local right = self.stub.why or ""
  if not self.stub.po then right = (self.stub.why or "") .. (gb ~= 0 and (" \u{2022} " .. PL.gbText(math.abs(gb)) .. (gb > 0 and " UP" or " DOWN")) or " \u{2022} TIED") end
  PennantUI.weekTop("SERIES PREP \u{2022} " .. (away and "@ " or "vs ") .. PennantClubs.byAbbr[opp].name:upper(), nil, right)
  -- the scouting strip
  local sts = PWeek.oppStarters(L, opp, 3)
  local sp = sts[1] and L.players[sts[1]]
  local hot, hv = nil, -1
  for _, id in ipairs(Ot.order or {}) do
    local p = L.players[id]
    local s = p and p.st.b
    if s and (s.ab or 0) >= 10 and PM.avg(s) > hv then hot, hv = p, PM.avg(s) end
  end
  local load = PWeek.penLoad(L, opp)
  local strip = {
    { "GAME 1 STARTER", sp and ((sp.throws == "L" and "LHP " or "RHP ") .. sp.ln:upper() .. " " .. PM.ovr(sp)) or "-" },
    { "THEIR HOT BAT", hot and (hot.ln:upper() .. " " .. PM.rate3(hv)) or "NOBODY YET" },
    { "THEIR BULLPEN", load >= 120 and ("TIRED: " .. load .. " PITCHES") or "RESTED" },
  }
  for i, s in ipairs(strip) do
    local x = 4 + (i - 1) * 132
    gfx.drawRect(x, 21, 128, 32)
    gfx.fillRect(x, 21, 128, 13)
    Text.draw(s[1], x + 4, Text.boxY(F().body, 21, 13), F().body, "white")
    Text.draw(Text.ellipsize(s[2], F().bold, 120), x + 4, 37, F().bold)
  end
  -- the game you play
  local fd = PWeek.pickFeatured(L)
  if self.stub.po then fd = select(2, PL.nextGame(L, L.user)) end
  local fg = fd and PL.gameFor(L, L.user, fd)
  local line
  if fg and (fg.h == opp or fg.a == opp) then
    line = "\u{2605} " .. PL.date(L, fd):upper() .. " " .. (fg.h == L.user and "vs " or "@ ") .. opp .. ": YOU PLAY THIS ONE. THE REST SIM."
  else
    line = "\u{2605} THE PLAN HOLDS FOR EVERY GAME OF THE SERIES."
  end
  gfx.fillRect(4, 200, 392, 20)
  Text.draw(Text.ellipsize(line, F().bold, 384), 10, Text.boxY(F().bold, 200, 20), F().bold, "white")
  gfx.popContext()
  self.bg = img
  Sfx.stinger("new_mail")
end

function Plan:card(i, on)
  local key = i .. (on and "s" or "")
  if self.cards[key] then return self.cards[key] end
  local L = Pennant.L
  local k = self.opts[i]
  local pl = PWeek.PLANS[k]
  local w, h = 126, 136
  local img = gfx.image.new(w + 3, h + 3, gfx.kColorClear)
  gfx.pushContext(img)
  if on then gfx.setPattern(UI.pat.gray) gfx.fillRect(3, 3, w, h) gfx.setColor(gfx.kColorBlack) end
  gfx.setColor(gfx.kColorWhite) gfx.fillRect(0, 0, w, h) gfx.setColor(gfx.kColorBlack)
  if on then gfx.setLineWidth(2) gfx.drawRect(1, 1, w - 2, h - 2) gfx.setLineWidth(1) else gfx.drawRect(0, 0, w, h) end
  gfx.fillRect(0, 0, w, 28)
  Text.draw("PLAN " .. i, 5, 1, F().body, "white")
  local t, f = Text.fit(pl.t, w - 10, F().bold)
  Text.draw(t, 5, 14, f, "white")
  local y = 31
  for _, l in ipairs(pl.l) do Text.draw(Text.ellipsize(l, F().body, w - 10), 5, y, F().body) y = y + 13 end
  Draw.dotted(4, w - 4, 72)
  Text.draw("WIN ODDS (EST.)", 5, 75, F().body)
  local odds = PWeek.odds(L, self.stub.opp, k)
  PennantUI.weekBar(5, 92, 80, 8, odds, "gray")
  Text.draw(floor(odds * 100 + 0.5) .. "%", w - 5, 89, F().bold, nil, "right")
  Text.draw(Text.ellipsize(pl.cost, F().bold, w - 10), 5, 108, F().bold)
  gfx.popContext()
  self.cards[key] = img
  return img
end

function Plan:update()
  self.t = self.t + 1
  self.bg:draw(0, 0)
  for i = 1, #self.opts do
    local on = i == self.sel
    self:card(i, on):draw(4 + (i - 1) * 132, on and 57 or 60)
  end
  PUI.hintBar("\u{25c0}\u{25b6} plan   A: lock it in   B: back to the week")
end

function Plan:leftButtonDown() self.sel = math.max(1, self.sel - 1) Sfx.focus() end
function Plan:rightButtonDown() self.sel = math.min(#self.opts, self.sel + 1) Sfx.focus() end

function Plan:AButtonDown()
  if self.t < 6 then return end
  local L = Pennant.L
  local k = self.opts[self.sel]
  PWeek.choosePlan(L, self.stub, k)
  PL.news(L, "GAME PLAN vs the " .. PennantClubs.byAbbr[self.stub.opp].name .. ": " .. PWeek.PLANS[k].t:lower() .. ".", true)
  Sfx.coin()
  App.pop()
  if self.onDone then self.onDone(true) end
end

function Plan:BButtonDown()
  Sfx.back()
  App.pop()
  if self.onDone then self.onDone(false) end
end
