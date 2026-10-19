-- Training: a weekly plan per player (focus + intensity) or by group, with the expected weekly
-- gain; and the week's results screen, where the ratings that went up fill in with a tick.

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

local Training = PUI.define({ title = "Training", hint = "Left/right: focus  A: intensity  crank: scroll" })
PennantUI.Training = Training

function Training:init(args)
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

local function cycleFocus(p, d)
  local list = fociFor(p)
  local cur = 1
  for i, k in ipairs(list) do if k == (p.plan and p.plan.f) then cur = i end end
  p.plan = p.plan or { i = 2 }
  p.plan.f = list[(cur - 1 + d) % #list + 1]
end

local function cycleInt(p)
  p.plan = p.plan or { i = 2 }
  p.plan.i = ((p.plan.i or 2) + 1) % 4
end

function Training:layout(Lb)
  local L = Pennant.L
  local y = PUI.tabs(Lb, {
    { "bat", "Hitters", function() self.tab = "bat" self:render() end },
    { "pit", "Pitchers", function() self.tab = "pit" self:render() end },
    { "farm", "Farm", function() self.tab = "farm" self:render() end },
  }, self.tab, 2)
  Text.draw("Week " .. (L.week or 1), 392, 4, UI.fonts.body, nil, "right")
  -- group plan
  local gl = self.tab == "pit" and PL.FOCI_PIT or PL.FOCI_BAT
  if self.tab == "farm" then gl = PL.FOCI_BAT end
  local gk = gl[self.gf[self.tab]] or gl[1]
  Text.draw("Everyone:", 4, y + 2, UI.fonts.bold)
  gfx.drawRect(72, y, 104, 17)
  Text.draw("\u{25c0} " .. PL.FOCUS_NAME[gk] .. " \u{25b6}", 124, y + 2, UI.fonts.body, nil, "center")
  Lb:link(72, y, 104, 17, function() end, PUI.opts("gf", "Left/right: focus for the whole group (pitchers get their own list on the farm)", function(d)
    self.gf[self.tab] = (self.gf[self.tab] - 1 + d) % #gl + 1 end))
  gfx.drawRect(180, y, 86, 17)
  Text.draw("\u{25c0} " .. PL.INTENSITY[self.gi + 1] .. " \u{25b6}", 223, y + 2, UI.fonts.body, nil, "center")
  Lb:link(180, y, 86, 17, function() end, PUI.opts("gi", "Left/right: intensity for the whole group", function(d) self.gi = (self.gi + d) % 4 end))
  Lb:button("Apply to all", 272, y, 90, 17, function()
    for _, p in ipairs(self:players()) do
      p.plan = p.plan or {}
      local list = fociFor(p)
      local want = gk
      local ok = false
      for _, k in ipairs(list) do if k == want then ok = true end end
      if not ok then want = (p.pos == "P") and PL.FOCI_PIT[self.gf.pit or 2] or list[1] end
      p.plan.f = want
      p.plan.i = self.gi
    end
    Sfx.select()
    self:render(true)
  end, { id = "apply", hint = "Set every player on this tab to that plan" })
  y = y + 22
  -- column heads
  Text.draw("PLAYER", 30, y, UI.fonts.body)
  Text.draw("CND", 160, y, UI.fonts.body)
  Text.draw("FAT", 180, y, UI.fonts.body)
  Text.draw("FOCUS", 216, y, UI.fonts.body)
  Text.draw("INTENSITY", 300, y, UI.fonts.body)
  Text.draw("/WK", 390, y, UI.fonts.body, nil, "right")
  gfx.drawLine(4, y + 13, 392, y + 13)
  y = y + 16
  local INT_GLYPH = { "Rest", "Light", "Normal", "HARD" }
  for _, p in ipairs(self:players()) do
    local plan = p.plan or { i = 2 }
    local img = Faces.get("face:" .. p.face, 24)
    PUI.srcRect = PUI.srcRect or playdate.geometry.rect.new(0, 4, 24, 16)
    if img then img:draw(4, y, gfx.kImageUnflipped, PUI.srcRect) end
    Text.draw((p.pos == "P" and (p.role or "P") or p.pos) .. " " .. Text.ellipsize(PM.short(p), UI.fonts.body, 96), 30, y + 1, UI.fonts.body)
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
    local g = p.inj and 0 or PL.weekly(p, f or "con", i)
    local room = key and ((p.cap[key] or 80) - (p.r[key] or 0)) or 1
    Text.draw(room <= 0 and "max" or string.format("+%.1f", g), 390, y + 1, UI.fonts.body, nil, "right")
    local hint = PM.name(p) .. ": " .. (PM.LABEL[key] or fl) .. " " .. math.floor(p.r[key] or 0) .. " (cap " .. (p.cap[key] or "?") .. ")"
      .. (i == 3 and ". Hard: faster, but tiring, injury risk" or (i == 0 and ". Rest: recovers fatigue, lifts condition" or ""))
    Lb:link(2, y - 1, 391, 17, function() cycleInt(p) Sfx.tick() self:render(true) end,
      { id = "t" .. p.id, style = "invert", hint = hint, data = { adj = function(d) cycleFocus(p, d) end } })
    y = y + 17
  end
  Lb:mark(y + 4)
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
  self:paint()
  Sfx.music("charge", {})
end

function Results:pages() return math.max(1, (#self.rows + PER_PAGE - 1) // PER_PAGE) end

--- Static parts of this page (names, faces, labels) into one image; bars animate on top.
function Results:paint()
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  Draw.tile(0, 0, 400, 240, "light")
  local ix, iy, iw, ih = Draw.window(6, 4, 386, 230, "Training report \u{2022} week " .. (self.rep.week or 1))
  self.bars = {}
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
    PUI.bar(b.x, b.y, v, b.cap, 120, 8)
    local shown = math.floor(v)
    -- the whole rating; a point crossed mid-animation ticks over
    Text.draw(tostring(shown), b.x + 126, b.y - 3, UI.fonts.bold)
    if u > 0 then
      local s = (b.d > 0 and "+" or "") .. (b.d % 1 == 0 and string.format("%d", b.d) or string.format("%.1f", b.d))
      local pop = u < 1 and math.floor((1 - u) * 3) or 0
      Text.draw(s, b.x + 152, b.y - 3 - pop, UI.fonts.bold)
    end
    if u > 0 and b.lastShown and b.lastShown ~= shown and b.d > 0 then Sfx.coin() end
    b.lastShown = shown
    if u > 0 and u < 1 and self.t % 3 == 0 and b.d > 0 then Sfx.tick() end
    if u >= 1 and not b.dinged then b.dinged = true if b.d > 0 then Sfx.focus() end end
  end
end

function Results:AButtonDown()
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
  self.acc = (self.acc or 0) + change
  if math.abs(self.acc) > 90 then
    local d = self.acc > 0 and 1 or -1
    self.acc = 0
    local np = math.max(1, math.min(self:pages(), self.page + d))
    if np ~= self.page then self.page = np self:paint() Sfx.detent() end
  end
end

function Results:finish()
  Sfx.back()
  App.pop()
  if self.onDone then self.onDone() end
end
