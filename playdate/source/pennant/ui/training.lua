-- Training: a weekly plan per player (focus + intensity) or by group, with the expected weekly
-- gain; and the week's results screen, where the ratings that went up fill in with a tick.

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

-- Under the week turn (pennant/week.lua) the club program sets everyone's plan each day; a player
-- changed here gets an individual plan (marked *) that the program leaves alone.
local Training = PUI.define({ title = function() return "Individual training" end, hint = "Left/right: focus  A: intensity (his own plan from now on)  crank: scroll" })
PennantUI.Training = Training

function Training:init(args)
  if PWeek and Pennant.L then PWeek.applyPlans(Pennant.L) end
  self.tab = args.tab or "bat"
  self.focusId = args.focusId
  if self.focusId then
    local p = Pennant.L.players[self.focusId]
    if p then self.tab = p.lvl == "F" and "farm" or (p.pos == "P" and "pit" or "bat") end
  end
  self.gf = { bat = 1, pit = 2, farm = 1 }
  self.gi = 2
end
function Training:resume(r) Page.resume(self, r) self:render(true) end

function Training:players()
  local L = Pennant.L
  local T = L.teams[L.user]
  local out = {}
  if self.tab == "farm" then
    for _, id in ipairs(T.farm) do out[#out + 1] = L.players[id] end
  else
    for _, id in ipairs(T.ml) do local p = L.players[id] if (p.pos == "P") == (self.tab == "pit") then out[#out + 1] = p end end
  end
  table.sort(out, function(a, b) if (a.pos == "P") ~= (b.pos == "P") then return b.pos == "P" end return PM.ovr(a) > PM.ovr(b) end)
  return out
end

local function fociFor(p) return p.pos == "P" and PL.FOCI_PIT or PL.FOCI_BAT end

local function own(p) if PWeek then PWeek.setOwn(Pennant.L, p.id, true) end end

local function cycleFocus(p, d)
  own(p)
  local list = fociFor(p)
  local cur = 1
  for i, k in ipairs(list) do if k == (p.plan and p.plan.f) then cur = i end end
  p.plan = p.plan or { i = 2 }
  p.plan.f = list[(cur - 1 + d) % #list + 1]
end

local function cycleInt(p)
  own(p)
  p.plan = p.plan or { i = 2 }
  p.plan.xm, p.plan.rk, p.plan.fx = nil, nil, nil
  p.plan.i = ((p.plan.i or 2) + 1) % 4
end

function Training:layout(Lb)
  local L = Pennant.L
  local y = PUI.tabs(Lb, {
    { "bat", "Hitters", function() self.tab = "bat" self:render() end },
    { "pit", "Pitchers", function() self.tab = "pit" self:render() end },
    { "farm", "Farm", function() self.tab = "farm" self:render() end },
  }, self.tab, 2)
  -- the group plan sits in the tab row: [focus] [intensity] Apply
  local gl = self.tab == "pit" and PL.FOCI_PIT or PL.FOCI_BAT
  if self.tab == "farm" then gl = PL.FOCI_BAT end
  local gy = 2
  local FX, FW, IX, IW, AX, AW = 176, 88, 267, 66, 336, 56
  local function paintF()
    gfx.drawRect(FX, gy, FW, 16)
    local s = Text.ellipsize(PL.FOCUS_NAME[gl[self.gf[self.tab]] or gl[1]], UI.fonts.body, FW - 4)
    Text.draw(s, FX + FW // 2, Text.boxY(UI.fonts.body, gy + 1, 14, s), UI.fonts.body, nil, "center")
  end
  local function paintI()
    gfx.drawRect(IX, gy, IW, 16)
    local s = PL.INTENSITY[self.gi + 1]
    Text.draw(s, IX + IW // 2, Text.boxY(UI.fonts.body, gy + 1, 14, s), UI.fonts.body, nil, "center")
  end
  paintF() paintI()
  -- (they share the tab row, so left/right moves between them and A steps the value)
  Lb:link(FX, gy, FW, 16, function()
    self.gf[self.tab] = self.gf[self.tab] % #gl + 1
    Sfx.tick()
    PUI.repaint(self, FX, gy, FW + 1, 17, paintF)
  end, PUI.opts("gf", "Everyone on this tab: A picks the focus, then Apply", nil))
  Lb:link(IX, gy, IW, 16, function()
    self.gi = (self.gi + 1) % 4
    Sfx.tick()
    PUI.repaint(self, IX, gy, IW + 1, 17, paintI)
  end, PUI.opts("gi", "Everyone on this tab: A picks the intensity, then Apply", nil))
  Lb:button("Apply", AX, gy, AW, 16, function()
    for _, p in ipairs(self:players()) do
      own(p)
      p.plan = p.plan or {}
      p.plan.xm, p.plan.rk, p.plan.fx = nil, nil, nil
      local list = fociFor(p)
      local want = gl[self.gf[self.tab]] or gl[1]
      local ok = false
      for _, k in ipairs(list) do if k == want then ok = true end end
      if not ok then want = (p.pos == "P") and PL.FOCI_PIT[self.gf.pit or 2] or list[1] end
      p.plan.f = want
      p.plan.i = self.gi
    end
    Sfx.select()
    for _, l in ipairs(self.links) do if l.data and l.data.repaint and l.id and l.id:sub(1, 1) == "t" then l.data.repaint() end end
  end, { id = "apply", hint = "Set everyone on this tab to that focus and intensity" })
  -- column heads
  y = y - 2
  Text.draw("PLAYER", 32, y, UI.fonts.body)
  Text.draw("C", 168, y, UI.fonts.body, nil, "center")
  Text.draw("FAT", 184, y, UI.fonts.body)
  Text.draw("FOCUS", 216, y, UI.fonts.body)
  Text.draw("INTENSITY", 300, y, UI.fonts.body)
  Text.draw("/WK", 390, y, UI.fonts.body, nil, "right")
  gfx.drawLine(4, y + 12, 392, y + 12)
  y = y + 14
  for _, p in ipairs(self:players()) do
    local ry = y
    PUI.lazy(Lb, 2, ry - 1, 391, 14, function() PennantUI.trainingRow(p, ry) end)
    local link
    local function repaint()
      PUI.repaint(self, 2, ry - 1, 391, 14, function() PennantUI.trainingRow(p, ry) end)
      link.hint = PennantUI.trainingHint(p)
    end
    link = Lb:link(2, ry - 1, 391, 14, function() cycleInt(p) Sfx.tick() repaint() end,
      { id = "t" .. p.id, style = "invert", hint = PennantUI.trainingHint(p), data = { adj = function(d) cycleFocus(p, d) end, repaint = repaint } })
    y = y + 13
  end
  Lb:mark(y)
end

local INT_GLYPH <const> = { "Rest", "Light", "Normal", "HARD" }

--- One player's training row (also repainted alone when it changes).
function PennantUI.trainingRow(p, y)
  local plan = p.plan or { i = 2 }
  local img = Faces.get("face:" .. p.face, 24)
  PUI.srcRectC = PUI.srcRectC or playdate.geometry.rect.new(0, 6, 24, 12)
  if img then img:draw(4, y, gfx.kImageUnflipped, PUI.srcRectC) end
  y = y - 1
  local mine = PWeek and Pennant.L and Pennant.L.club and Pennant.L.club.own[tostring(p.id)]
  Text.draw((p.pos == "P" and (p.role or "P") or p.pos) .. " " .. Text.ellipsize((mine and "*" or "") .. PM.short(p), UI.fonts.body, 94), 32, y + 1, UI.fonts.body)
  if p.inj then PUI.cross(162, y + 2) else PUI.arrow(162, y + 2, p.cond) end
  PUI.fatigue(180, y + 5, p.fat, 30)
  local f = plan.f
  local key = f == "pit" and "stf" or f
  local fl = PL.FOCUS_NAME[f or ""] or "-"
  if f == "pit" then fl = "Pitch: " .. (PL.devPitch(p) or "?") end
  Text.draw(fl, 216, y + 1, UI.fonts.bold)
  local i = plan.i or 2
  -- intensity as 3 pips
  for k = 1, 3 do
    if k <= i then gfx.fillRect(300 + (k - 1) * 9, y + 4, 7, 7) else gfx.drawRect(300 + (k - 1) * 9, y + 4, 7, 7) end
  end
  Text.draw(INT_GLYPH[i + 1], 330, y + 1, i == 3 and UI.fonts.bold or UI.fonts.body)
  local g = p.inj and 0 or PL.weekly(p, f or "con", i) * (plan.xm or 1)
  local room = key and ((p.cap[key] or 80) - (p.r[key] or 0)) or 1
  Text.draw(room <= 0 and "max" or string.format("+%.1f", g), 390, y + 1, UI.fonts.body, nil, "right")
end

function PennantUI.trainingHint(p)
  local plan = p.plan or { i = 2 }
  local f = plan.f
  local key = f == "pit" and "stf" or f
  local i = plan.i or 2
  return PM.name(p) .. ": " .. (PM.LABEL[key] or PL.FOCUS_NAME[f or ""] or "-") .. " " .. math.floor(p.r[key] or 0) .. " (cap " .. (p.cap[key] or "?") .. ")"
    .. (i == 3 and ". Hard: faster, but tiring, injury risk" or (i == 0 and ". Rest: recovers fatigue, lifts condition" or ""))
end

function Training:initialFocus()
  if self.focusId then
    for i, l in ipairs(self.links) do if l.id == "t" .. self.focusId then self.focusId = nil return i end end
  end
  for i, l in ipairs(self.links) do if l.id and l.id:sub(1, 1) == "t" and l.id ~= "tab:bat" then return i end end
  return 1
end

-- Weekly results -----------------------------------------------------------------------------------

local Results = { opaque = true }
Results.__index = Results
PennantUI.TrainingResults = Results

local PER_PAGE <const> = 5
local ROW_H <const> = 38

function Results.open(args)
  local s = setmetatable({}, Results)
  App.push(s, args)
  return s
end

function Results:enter(args)
  local L = Pennant.L
  self.rep = L.weekRep
  L.weekRep.seen = true
  self.rows = {}
  for _, r in ipairs(self.rep.rows) do
    local p = L.players[r.id]
    if p and p.team == L.user then self.rows[#self.rows + 1] = { p = p, d = r.d, learned = r.learned } end
  end
  self.page = 1
  self.t = 0
  self.ticks = 0
  self.onDone = args and args.onDone
  self.mode = (args and args.all) and "all" or "card"
  self.btn = 1
  self:buildCard()
  self:paint()
  Sfx.music("charge", {})
end

-- the one-page report card (P0-3) ----------------------------------------------------------------

--- Whole points crossed for one rating: floor(now) - floor(before).
local function whole(now, d) return math.floor(now) - math.floor(now - d + 1e-6) end

function Results:buildCard()
  local L = Pennant.L
  local big, farm, pitch = {}, {}, nil
  for _, r in ipairs(self.rows) do
    local p = r.p
    if r.learned and not pitch then pitch = r end
    for _, k in ipairs(PM.keys(p)) do
      local d = r.d[k]
      if d then
        local now = r.now and r.now[k] or p.r[k]
        local w = whole(now, d)
        if w ~= 0 then
          local e = { p = p, k = k, d = d, w = w, now = now, from = now - d, cap = p.cap[k] }
          if p.lvl == "F" then farm[#farm + 1] = e else big[#big + 1] = e end
        end
      end
    end
  end
  -- whole points first (gains before declines), then the bigger raw move
  local function order(a, b) if a.w ~= b.w then return a.w > b.w end return a.d > b.d end
  table.sort(big, order)
  table.sort(farm, order)
  local pow = (big[1] and big[1].w > 0 and big[1]) or (farm[1] and farm[1].w > 0 and farm[1]) or nil
  self.card = { big = {}, farm = farm, pow = pow, pitch = pitch, nFarmCloser = 0 }
  for _, e in ipairs(big) do
    if e ~= pow and #self.card.big < (pitch and 3 or 4) then self.card.big[#self.card.big + 1] = e end
  end
  -- farm hands who moved but didn't cross a point
  local crossed = {}
  for _, e in ipairs(farm) do crossed[e.p.id] = true end
  for _, r in ipairs(self.rows) do if r.p.lvl == "F" and not crossed[r.p.id] then self.card.nFarmCloser = self.card.nFarmCloser + 1 end end
  -- Adjust training opens on the top mover, or on someone whose focus is within a point of his cap
  local tgt = pow and pow.p
  for _, id in ipairs(L.teams[L.user].ml) do
    local p = L.players[id]
    local f = p and p.plan and p.plan.f
    if f and p.r[f] and p.cap[f] and p.cap[f] - p.r[f] <= 1 then tgt = p break end
  end
  self.card.target = tgt
end

Results.BUTTONS = { "Adjust training", "Every row", "Done" }

function Results:paintCard(ix, iy, iw, ih)
  local c = self.card
  local L = Pennant.L
  local y = iy + 2
  if c.pow then
    local e, p = c.pow, c.pow.p
    Text.draw("PLAYER OF THE WEEK", ix + 6, y, UI.fonts.bold)
    Faces.draw("face:" .. p.face, ix + 6, y + 14, 48)
    Text.draw(PM.name(p), ix + 64, y + 16, UI.fonts.head)
    Text.draw((p.pos == "P" and (p.role or "P") or p.pos) .. (p.lvl == "F" and " \u{2022} farm" or "") .. " \u{2022} age " .. (p.age or "?"), ix + 64, y + 34, UI.fonts.body)
    Text.draw(PM.SHORT[e.k], ix + 64, y + 50, UI.fonts.bold)
    self.bars[#self.bars + 1] = { x = ix + 96, y = y + 53, from = e.from, to = e.now, cap = e.cap, d = e.d, row = 0, w = 120 }
    -- the rubber stamp
    local sx, sy = ix + iw - 86, y + 16
    gfx.setLineWidth(2)
    gfx.drawRoundRect(sx, sy, 76, 34, 4)
    gfx.setLineWidth(1)
    Text.draw("+" .. e.w .. " " .. PM.SHORT[e.k], sx + 38, sy + 3, UI.fonts.head, nil, "center")
    Text.draw("P.O.W.", sx + 38, sy + 20, UI.fonts.bold, nil, "center")
    y = y + 76
  else
    Text.draw("A quiet week: nobody crossed a whole point.", ix + 6, y + 4, UI.fonts.bold)
    Text.draw("Rested players feel better. Try Normal or Hard.", ix + 6, y + 18, UI.fonts.body)
    y = y + 36
  end
  Draw.dotted(ix + 4, ix + iw - 5, y)
  y = y + 4
  if #c.big > 0 then
    Text.draw("BIG CLUB", ix + 6, y, UI.fonts.bold)
    y = y + 14
    for i, e in ipairs(c.big) do
      local p = e.p
      Text.draw(Text.ellipsize(PM.name(p), UI.fonts.body, 110), ix + 6, y, UI.fonts.body)
      Text.draw(PM.SHORT[e.k], ix + 122, y, UI.fonts.bold)
      self.bars[#self.bars + 1] = { x = ix + 152, y = y + 3, from = e.from, to = e.now, cap = e.cap, d = e.d, row = i, w = 90 }
      if e.w < 0 and (p.age or 0) >= 31 then Text.draw("(age " .. p.age .. ")", ix + iw - 8, y, UI.fonts.body, nil, "right") end
      y = y + 14
    end
  end
  if c.pitch then
    Text.draw("NEW PITCH: " .. PM.name(c.pitch.p) .. " learned the " .. (PM.PITCH_NAME[c.pitch.learned] or c.pitch.learned) .. "!", ix + 6, y + 1, UI.fonts.bold)
    y = y + 15
  end
  -- one farm line
  local parts = {}
  for i = 1, math.min(2, #c.farm) do
    local e = c.farm[i]
    parts[#parts + 1] = e.p.ln .. " " .. (e.w > 0 and "+" or "") .. e.w .. " " .. PM.SHORT[e.k]
  end
  if c.nFarmCloser > 0 then parts[#parts + 1] = c.nFarmCloser .. " other" .. (c.nFarmCloser == 1 and "" or "s") .. " closer" end
  if #parts > 0 then
    Text.draw(Text.ellipsize("FARM: " .. table.concat(parts, ", "), UI.fonts.body, iw - 12), ix + 6, y + 1, UI.fonts.body)
  end
  -- the buttons
  self.btnRects = {}
  local bw, by = 112, iy + ih - 22
  for i, label in ipairs(Results.BUTTONS) do
    local bx = ix + 8 + (i - 1) * (bw + 9)
    self.btnRects[i] = { bx, by, bw, 18 }
    Draw.button(bx, by, bw, 18, label)
  end
end

function Results:pages() return math.max(1, (#self.rows + PER_PAGE - 1) // PER_PAGE) end

--- Static parts of this page (names, faces, labels) into one image; bars animate on top.
function Results:paint()
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  Draw.tile(0, 0, 400, 240, "light")
  local ix, iy, iw, ih = Draw.window(6, 4, 386, 230, (self.mode == "card" and "Report card" or "Training report") .. " \u{2022} week " .. (self.rep.week or 1))
  self.bars = {}
  if self.mode == "card" then
    self:paintCard(ix, iy, iw, ih)
    gfx.popContext()
    self.img = img
    self.t = 0
    return
  end
  if #self.rows == 0 then
    Text.draw("No rating changes this week.", 200, 90, UI.fonts.head, nil, "center")
    Text.draw("Rested players feel better. Try Normal or Hard.", 200, 112, UI.fonts.body, nil, "center")
  end
  local first = (self.page - 1) * PER_PAGE + 1
  for i = first, math.min(#self.rows, first + PER_PAGE - 1) do
    local r = self.rows[i]
    local p = r.p
    local y = iy + 4 + (i - first) * ROW_H
    Faces.draw("face:" .. p.face, ix + 6, y + 4, 24)
    Text.draw(PM.name(p), ix + 36, y + 2, UI.fonts.bold)
    Text.draw((p.pos == "P" and (p.role or "P") or p.pos) .. (p.lvl == "F" and " \u{2022} farm" or ""), ix + 36, y + 16, UI.fonts.body)
    local bx = ix + 160
    local n = 0
    for _, k in ipairs(PM.keys(p)) do
      local d = r.d[k]
      if d and n < 3 then
        local y2 = y + 2 + n * 11
        Text.draw(PM.SHORT[k], bx, y2 - 2, UI.fonts.body)
        local now = r.now and r.now[k] or p.r[k]
        self.bars[#self.bars + 1] = { x = bx + 30, y = y2 + 1, from = now - d, to = now, cap = p.cap[k], d = d, row = i - first }
        n = n + 1
      end
    end
    if r.learned then Text.draw("NEW PITCH: " .. (PM.PITCH_NAME[r.learned] or r.learned), bx, y + 26, UI.fonts.bold) end
    if i < first + PER_PAGE - 1 then Draw.dotted(ix + 4, ix + iw - 5, y + ROW_H - 2) end
  end
  local pg = self:pages()
  Text.draw((pg > 1 and ("Page " .. self.page .. "/" .. pg .. "   ") or "") .. "A: " .. (self.page < pg and "next" or "done"), ix + iw - 6, iy + ih - 15, UI.fonts.body, nil, "right")
  gfx.popContext()
  self.img = img
  self.t = 0
end

function Results:update()
  self.img:draw(0, 0)
  self.t = self.t + 1
  for _, b in ipairs(self.bars) do
    -- each row starts a little later; the bar grows from the old value to the new one
    local start = b.row * 6 + 6
    local u = math.max(0, math.min(1, (self.t - start) / 16))
    if Game.settings.reduceMotion then u = 1 end
    local v = b.from + (b.to - b.from) * u
    local bw = b.w or 120
    PUI.bar(b.x, b.y, v, b.cap, bw, 8)
    local shown = math.floor(v)
    -- the whole rating; a point crossed mid-animation ticks over
    Text.draw(tostring(shown), b.x + bw + 6, b.y - 3, UI.fonts.bold)
    if u > 0 then
      local s = (b.d > 0 and "+" or "") .. (b.d % 1 == 0 and string.format("%d", b.d) or string.format("%.1f", b.d))
      local pop = u < 1 and math.floor((1 - u) * 3) or 0
      Text.draw(s, b.x + bw + 32, b.y - 3 - pop, UI.fonts.bold)
    end
    if u > 0 and b.lastShown and b.lastShown ~= shown and b.d > 0 then Sfx.coin() end
    b.lastShown = shown
    if u > 0 and u < 1 and self.t % 3 == 0 and b.d > 0 then Sfx.tick() end
    if u >= 1 and not b.dinged then b.dinged = true if b.d > 0 then Sfx.focus() end end
  end
  self:drawFocus()
end

function Results:drawFocus()
  if self.mode ~= "card" or not self.btnRects then return end
  local r = self.btnRects[self.btn]
  gfx.setColor(gfx.kColorXOR)
  gfx.fillRect(r[1] + 2, r[2] + 2, r[3] - 4, r[4] - 4)
  gfx.setColor(gfx.kColorBlack)
end
function Results:leftButtonDown() if self.mode == "card" then self.btn = math.max(1, self.btn - 1) Sfx.focus() end end
function Results:rightButtonDown() if self.mode == "card" then self.btn = math.min(#Results.BUTTONS, self.btn + 1) Sfx.focus() end end

function Results:AButtonDown()
  if self.mode == "card" then
    local L = Pennant.L
    if self.btn == 1 then
      local tgt = self.card.target
      self:finish(true)
      PennantUI.Training.open({ focusId = tgt and tgt.id, tab = tgt and tgt.pos == "P" and "pit" or "bat" })
    elseif self.btn == 2 then
      Sfx.select()
      self.mode = "all"
      self.page = 1
      self:paint()
    else
      self:finish()
    end
    return
  end
  if self.page < self:pages() then
    self.page = self.page + 1
    self:paint()
    Sfx.select()
  else
    self:finish()
  end
end
function Results:BButtonDown() self:finish() end
function Results:cranked(change)
  if self.mode == "card" then return end
  self.acc = (self.acc or 0) + change
  if math.abs(self.acc) > 90 then
    local d = self.acc > 0 and 1 or -1
    self.acc = 0
    local np = math.max(1, math.min(self:pages(), self.page + d))
    if np ~= self.page then self.page = np self:paint() Sfx.detent() end
  end
end

function Results:finish(quiet)
  if not quiet then Sfx.back() end
  App.pop()
  if self.onDone then self.onDone() end
end
