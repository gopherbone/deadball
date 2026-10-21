--[[ The legacy layer's screens (pennant/legacy.lua):
  Inspire      Opening Day's legacy, an inspiration (weeks 9 / 18 of 26), run 1's alumni card:
               the sparks roll one by one (B skips), the season's legacy points against the cap
  RunEnd       the season's end: grades, then sparks, then who stays (keep 1 / 2 / 3)
  RunChoice    continue the career (after a pennant) / end the run / the run is over
  LegacyPick   a new run: two legacies, their chemistry, what they should do
  DeckPick     a new run: the alumni deck and Pennant Heat
  AlumniHall   the hall: browse, pick (legacies, the deck, a Hall of Fame slot), release
  HallOfFame   the All-Time Lineup, the Franchise Rating, its goals
  LegacyInfo   the Office's page: this run's legacies, the cap, the deck's bonds
  and the program cards' "with" slot (the deck's faces, bond bars, a Rally Week flashing).
  Animated scenes draw from images built on entry / on a change; a frame is a few blits.
]]

local gfx <const> = playdate.graphics
local floor, max, min = math.floor, math.max, math.min
PennantUI = PennantUI or {}
local G = PLegacy
local function F() return UI.fonts end

local function scene(name)
  local S = { opaque = true }
  S.__index = S
  S.open = function(args) local s = setmetatable({}, S) App.push(s, args or {}) return s end
  PennantUI[name] = S
  return S
end

local function white() gfx.setColor(gfx.kColorWhite) end
local function black() gfx.setColor(gfx.kColorBlack) end

--- ◎ ○ △ (chemistry marks), 9 x 9
local function chemGlyph(x, y, mark, wh)
  gfx.setColor(wh and gfx.kColorWhite or gfx.kColorBlack)
  if mark == 3 then gfx.drawCircleAtPoint(x + 4, y + 4, 4) gfx.fillCircleAtPoint(x + 4, y + 4, 2)
  elseif mark == 2 then gfx.drawCircleAtPoint(x + 4, y + 4, 4)
  else gfx.drawPolygon(x + 4, y, x + 8, y + 8, x, y + 8, x + 4, y) end
  black()
end
PennantUI.chemGlyph = chemGlyph

--- A grade letter in a black box.
local function gradeBox(x, y, w, h, g)
  black()
  gfx.fillRect(x, y, w, h)
  local f = F().head
  local s = g or "-"
  if f:getTextWidth(s) > w - 3 then f = F().bold if f:getTextWidth(s) > w - 3 then s = (g == "LEGEND") and "L\u{2605}" or s:sub(1, 2) end end
  Text.draw(s, x + w // 2, Text.boxY(f, y, h), f, "white", "center")
end
PennantUI.gradeBox = gradeBox

local function chip(x, y, w, h, s, dark, f)
  f = f or F().bold
  if dark then black() gfx.fillRect(x, y, w, h) else white() gfx.fillRect(x, y, w, h) black() gfx.drawRect(x, y, w, h) end
  s = Text.ellipsize(s, f, w - 4)
  Text.draw(s, x + w // 2, Text.boxY(f, y, h, s), f, dark and "white" or nil, "center")
end

local function blackTop(left, right, chem)
  black()
  gfx.fillRect(0, 0, 400, 18)
  local ty = Text.boxY(F().bold, 0, 18)
  Text.draw(left, 5, ty, F().bold, "white")
  if right then
    local rw = Text.draw(right, 395, ty, F().body, "white", "right")
    if chem then chemGlyph(395 - rw - 13, 5, chem, true) end
  end
end

-- INSPIRE: Opening Day / an inspiration / run 1's card ---------------------------------------------

local Insp = scene("Inspire")

local function inspBg(self)
  local L = Pennant.L
  local R = L.run
  local img = gfx.image.new(400, 240, gfx.kColorBlack)
  gfx.pushContext(img)
  -- light from the press box
  gfx.setPattern(UI.pat.dark)
  gfx.fillPolygon(200, 44, 50, 18, 110, 18, 200, 44)
  gfx.fillPolygon(200, 44, 170, 18, 232, 18, 200, 44)
  gfx.fillPolygon(200, 44, 292, 18, 352, 18, 200, 44)
  black()
  local left
  if self.mode == "opening" then left = (self.res and self.res.half) and ("SEASON " .. L.season .. " \u{2022} THE LEGACY, HALF STRENGTH") or "OPENING DAY \u{2022} YOUR LEGACY"
  else left = "WEEK " .. ((self.res and self.res.w) or "?") .. " \u{2022} INSPIRATION" end
  blackTop(left, "CHEMISTRY " .. (R.chem or 0), G.chemMark(R.chem or 0))
  -- the cap panel's frame and the summary's
  white()
  gfx.fillRect(264, 22, 130, 152)
  black()
  gfx.fillRect(266, 24, 126, 13)
  Text.draw("THIS SEASON / CAP", 270, Text.boxY(F().bold, 24, 13), F().bold, "white")
  gfx.popContext()
  return img
end

function Insp:enter(args)
  local L = Pennant.L
  local R = L.run
  self.mode, self.onDone = args.mode or "insp", args.onDone
  self.t = 0
  if self.mode == "intro" then self:paintIntro() Sfx.stinger("new_mail") return end
  if self.mode == "insp" then
    local i = args.i or G.unseenInsp(L) or 1
    self.i = i
    self.res = R.insp["i" .. i] or G.inspire(L, i)
  else
    self.res = R.od
  end
  self.rows = (self.res and self.res.rows) or {}
  self.caps = (self.res and self.res.caps) or {}
  self.compact = #self.rows > 5
  self.rowH, self.gap, self.vis = self.compact and 15 or 28, self.compact and 17 or 31, self.compact and 9 or 5
  self.step = self.compact and 9 or 13
  self.shown = 0
  self.rowImg = {}
  self.bg = inspBg(self)
  self:paintCaps()
  self.bot = {}
  Sfx.stinger(self.mode == "opening" and "win" or "new_mail")
end

function Insp:paintIntro()
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  Draw.tile(0, 0, 400, 240, "light")
  black()
  gfx.fillRect(33, 27, 340, 188)
  white() gfx.fillRect(30, 24, 340, 188) black()
  gfx.setLineWidth(2) gfx.drawRect(30, 24, 340, 188) gfx.setLineWidth(1)
  gfx.fillRect(30, 24, 340, 16)
  Text.draw("THE ALUMNI HALL", 36, Text.boxY(F().bold, 24, 16), F().bold, "white")
  Text.draw("RUN 1", 364, Text.boxY(F().body, 24, 16), F().body, "white", "right")
  local y = 46
  y = y + Text.block("Every run is one pennant race. When it ends, your best players are graded and get SPARKS. Keep 1 for any finish, 2 for the playoffs, 3 for the pennant.", 40, y, 320, F().body, nil, 4) + 6
  y = y + Text.block("Make the playoffs once and every new run starts with two alumni as LEGACIES (their sparks boost whole units) and a DECK of alumni who turn up at your weekly programs.", 40, y, 320, F().body, nil, 4) + 6
  y = y + Text.block("Win the pennant and you can keep the club going.", 40, y, 320, F().bold, nil, 2)
  PUI.hintBar("A: play ball")
  gfx.popContext()
  self.bg = img
end

function Insp:row(i, done)
  local key = i * 2 + (done and 1 or 0)
  local img = self.rowImg[key]
  if img then return img end
  local r = self.rows[i]
  local w, h = 252, self.rowH
  img = gfx.image.new(w, h, gfx.kColorBlack)
  gfx.pushContext(img)
  local lit = done and r.ok
  if lit then white() gfx.fillRect(0, 0, w, h) black() else white() gfx.drawRect(0, 0, w, h) end
  local col = (not lit) and "white" or nil
  local cx, cw = 150, 98
  local res = done and (r.res or (r.ok and "FIRED" or "NO SPARK")) or (r.pct and (r.pct .. "% TO FIRE") or "\u{2026}")
  if self.compact then
    local who = (r.via and (r.who .. "*") or r.who)
    local s = Text.ellipsize(who .. ": " .. r.spark, F().body, cx - 8)
    Text.draw(s, 5, Text.boxY(F().body, 0, h, s), F().body, col)
    if lit then black() gfx.fillRect(cx, 1, cw, h - 2) else white() gfx.drawRect(cx, 1, cw, h - 2) end
    local rs = Text.ellipsize(res, F().body, cw - 4)
    Text.draw(rs, cx + cw // 2, Text.boxY(F().body, 1, h - 2, rs), F().body, "white", "center")
  else
    local who = r.via and (r.who .. " \u{2022} " .. r.via .. "'S LEGACY") or r.who
    Text.draw(Text.ellipsize(who, F().body, cx - 8), 5, 1, F().body, col)
    Text.draw(Text.ellipsize(r.spark, F().bold, cx - 8), 5, 14, F().bold, col)
    if lit then black() gfx.fillRect(cx, 5, cw, 18) else white() gfx.drawRect(cx, 5, cw, 18) end
    local f = F().bold:getTextWidth(res) <= cw - 4 and F().bold or F().body
    local rs = Text.ellipsize(res, f, cw - 4)
    Text.draw(rs, cx + cw // 2, Text.boxY(f, 5, 18, rs), f, "white", "center")
  end
  gfx.popContext()
  self.rowImg[key] = img
  return img
end

--- The cap panel: each rating's points this season before the event (black) and from the rows
--- revealed so far (dithered), against the cap.
function Insp:paintCaps()
  local img = gfx.image.new(126, 134, gfx.kColorWhite)
  gfx.pushContext(img)
  local n = #self.caps
  local hh = n > 4 and 22 or 32
  local y = 2
  for k = 1, min(n, 6) do
    local c = self.caps[k]
    local add = 0
    for i = 1, self.shown do local r = self.rows[i] if r.a == c.a and r.n then add = add + r.n end end
    local u = G.UNIT_NAME[G.UNIT[c.a]]
    Text.draw(u .. " " .. PM.SHORT[c.a], 2, y, F().body)
    Text.draw((c.before + add) .. "/" .. G.CAP, 123, y, F().bold, nil, "right")
    local by = y + (hh > 22 and 15 or 13)
    gfx.drawRect(2, by, 102, 7)
    local w0 = floor(c.before / G.CAP * 100 + 0.5)
    local w1 = floor(add / G.CAP * 100 + 0.5)
    if w0 > 0 then gfx.fillRect(3, by + 1, min(100, w0), 5) end
    if w1 > 0 then gfx.setPattern(UI.pat.gray) gfx.fillRect(3 + w0, by + 1, max(0, min(100 - w0, w1)), 5) black() end
    y = y + hh
  end
  if n == 0 then Text.block("No rating sparks this time.", 2, 2, 120, F().body, nil, 3) end
  gfx.popContext()
  self.capsImg = img
end

function Insp:summary()
  if self.sumImg then return self.sumImg end
  local L = Pennant.L
  local img = gfx.image.new(388, 36, gfx.kColorWhite)
  gfx.pushContext(img)
  local pts, fired = 0, 0
  for _, r in ipairs(self.rows) do if r.ok then fired = fired + 1 end pts = pts + (r.n or 0) end
  local l1, l2
  if self.mode == "opening" then
    l1 = "OPENING DAY: +" .. pts .. " RATING POINTS ACROSS THE CLUB"
    if self.res.half then l2 = "THE CAREER GOES ON: NO INSPIRATIONS, HEAT " .. (L.run.heat or 0)
    else local wk = G.inspWeeks(L) l2 = "SPARKS MAY FIRE AGAIN IN WEEKS " .. wk[1] .. " AND " .. wk[2] end
  else
    l1 = fired .. " OF " .. #self.rows .. " FIRED \u{2022} +" .. pts .. " RATING POINTS"
    local wk = G.inspWeeks(L)
    l2 = self.i == 1 and ("NEXT INSPIRATION: WEEK " .. wk[2] .. " (AFTER THE ALL-STAR BREAK)") or "THAT'S THE LAST ONE THIS SEASON"
  end
  Text.draw(Text.ellipsize(l1, F().bold, 380), 6, 3, F().bold)
  Text.draw(Text.ellipsize(l2, F().body, 380), 6, 19, F().body)
  gfx.popContext()
  self.sumImg = img
  return img
end

function Insp:botBar(done)
  local k = done and 2 or 1
  if self.bot[k] then return self.bot[k] end
  local img = gfx.image.new(400, 16, gfx.kColorWhite)
  gfx.pushContext(img)
  Text.draw("A: " .. (done and "continue" or "show them all"), 6, Text.boxY(F().bold, 0, 16), F().bold)
  if not done then Text.draw("B: skip", 394, Text.boxY(F().body, 0, 16), F().body, nil, "right") end
  gfx.popContext()
  self.bot[k] = img
  return img
end

function Insp:update()
  self.t = self.t + 1
  if self.mode == "intro" then self.bg:draw(0, 0) return end
  local n = #self.rows
  local due = self.skip and n or max(0, (self.t - 12) // self.step + 1)
  local changed = false
  while self.shown < min(due, n) do
    self.shown = self.shown + 1
    changed = true
    if not self.skip then
      local r = self.rows[self.shown]
      if r.ok then Sfx.coin() else Sfx.tick() end
    end
  end
  if changed then self:paintCaps() end
  self.bg:draw(0, 0)
  local last = min(n, max(self.vis, self.shown + 1))
  local first = max(1, last - self.vis + 1)
  for i = first, last do
    local y = 22 + (i - first) * self.gap
    if i <= self.shown then self:row(i, true):draw(8, y)
    else
      self:row(i, false):draw(8, y)
      if i == self.shown + 1 and self.t > 10 then
        -- the dice: the result chip flickers while it rolls
        gfx.setPattern((self.t // 2) % 2 == 0 and UI.pat.gray or UI.pat.dark)
        if self.compact then gfx.fillRect(159, y + 2, 80, self.rowH - 4) else gfx.fillRect(160, y + 7, 78, 14) end
        black()
      end
    end
  end
  self.capsImg:draw(266, 38)
  local done = self.shown >= n
  if done then self:summary():draw(6, 180) end
  self:botBar(done):draw(0, 224)
end

function Insp:close()
  local L = Pennant.L
  local R = L.run
  if self.mode == "intro" then R.intro = nil
  elseif self.mode == "opening" then R.showOD = nil
  elseif self.res then self.res.unseen = nil end
  Sfx.select()
  App.pop()
  if self.onDone then self.onDone() end
end

function Insp:AButtonDown()
  if self.t < 8 then return end
  if self.mode ~= "intro" and self.shown < #self.rows then self.skip = true return end
  self:close()
end
function Insp:BButtonDown()
  if self.mode ~= "intro" and self.shown < #self.rows then self.skip = true end
end

PWeek.addStop({ id = "inspire", due = function(L) return (G.unseenInsp(L)) end,
  open = function(L, i, onDone) PennantUI.Inspire.open({ mode = "insp", i = i, onDone = onDone }) end })

-- RUN END: grades, sparks, who stays ----------------------------------------------------------------

local RunEnd = scene("RunEnd")
local CW <const>, CH <const> = 124, 80

local function cardXY(i) local col, row = (i - 1) % 3, (i - 1) // 3 return 8 + col * 130, 21 + row * 86 end

function RunEnd:enter(args)
  local L = Pennant.L
  self.onDone = args.onDone
  self.E = G.seasonEnd(L)
  self.cands = self.E.cands
  self.slots = self.E.slots
  self.kept = {}
  self.sel = 1
  self.t = 0
  self.phase = "reveal"
  self.imgs = {}
  local n = #self.cands
  self.tFront = function(i) return 8 + (i - 1) * 9 end
  self.tSpark = function(i) return 8 + n * 9 + 10 + (i - 1) * 8 end
  self.tEnd = 8 + n * 9 + 10 + n * 8 + 6
  self:paintBase()
  Sfx.stinger(L.champ == L.user and "win" or "new_mail")
end

function RunEnd:paintBase()
  local L = Pennant.L
  for k = 1, 2 do
    local img = gfx.image.new(400, 240, gfx.kColorWhite)
    gfx.pushContext(img)
    Draw.tile(0, 0, 400, 240, "light")
    local fin = self.E.fin
    local left = L.year .. " IS OVER \u{2022} " .. (fin == "PENNANT" and "PENNANT WON" or (fin == "PLAYOFFS" and "PLAYOFFS" or ("FINISHED " .. fin)))
    blackTop(left, k == 1 and "GRADES & SPARKS" or "WHO STAYS ON AS ALUMNI?")
    gfx.popContext()
    self["base" .. k] = img
  end
  self:paintKeep()
end

--- The keep bar: KEEP n, the slots, the rule, DONE.
function RunEnd:paintKeep()
  local img = gfx.image.new(388, 26, gfx.kColorWhite)
  gfx.pushContext(img)
  black()
  gfx.drawRect(0, 0, 388, 26)
  local x = 6 + Text.draw("KEEP " .. self.slots, 6, Text.boxY(F().bold, 0, 26), F().bold) + 8
  local n = 0
  for _ in pairs(self.kept) do n = n + 1 end
  for i = 1, self.slots do
    if i <= n then gfx.fillRect(x, 7, 12, 12) else gfx.drawRect(x, 7, 12, 12) end
    x = x + 16
  end
  local endless = (Pennant.L.run.endless or 0) > 0
  local rule = endless and "CAREER: 1 A SEASON, 2 WITH A PENNANT" or "PENNANT 3 \u{2022} PLAYOFFS 2 \u{2022} ANY 1"
  Text.draw(Text.ellipsize(rule, F().body, 300 - x), x + 6, Text.boxY(F().body, 0, 26, rule), F().body)
  gfx.popContext()
  self.keepImg = img
end

function RunEnd:card(i, stage, kept)
  local key = i * 10 + stage * 2 + (kept and 1 or 0)
  if self.imgs[key] then return self.imgs[key] end
  local c = self.cands[i]
  local img = gfx.image.new(CW + 3, CH + 3, gfx.kColorClear)
  gfx.pushContext(img)
  black()
  if kept then gfx.fillRect(3, 3, CW, CH) end
  if stage == 0 then
    gfx.setPattern(UI.pat.gray) gfx.fillRect(0, 0, CW, CH) black()
    gfx.drawRect(0, 0, CW, CH)
    white() gfx.fillRect(CW // 2 - 14, CH // 2 - 12, 28, 24) black() gfx.drawRect(CW // 2 - 14, CH // 2 - 12, 28, 24)
    Text.draw("?", CW // 2, Text.boxY(F().head, CH // 2 - 12, 24), F().head, nil, "center")
  else
    white() gfx.fillRect(0, 0, CW, CH) black()
    if kept then gfx.setLineWidth(2) gfx.drawRect(1, 1, CW - 2, CH - 2) gfx.setLineWidth(1) else gfx.drawRect(0, 0, CW, CH) end
    if kept then gfx.fillRect(0, 0, CW, 14) else gfx.drawLine(0, 14, CW - 1, 14) end
    local nm = Text.ellipsize((c.fn:sub(1, 1) .. ". " .. c.ln):upper(), F().bold, CW - 30)
    Text.draw(nm, 5, Text.boxY(F().bold, 0, 14, nm), F().bold, kept and "white" or nil)
    Text.draw(G.posOf(c), CW - 5, Text.boxY(F().body, 0, 14), F().body, kept and "white" or nil, "right")
    gradeBox(5, 18, 28, 23, c.grade)
    Text.draw(Text.ellipsize(c.line, F().body, CW - 42), 38, 17, F().body)
    Text.draw(Text.ellipsize(c.note, F().body, CW - 42), 38, 30, F().body)
    Draw.dotted(5, CW - 5, 45)
    Text.draw(stage == 2 and "SPARKS" or "SCORE", 5, 47, F().body)
    Text.draw(tostring(c.score), CW - 5, 47, F().bold, nil, "right")
    if stage == 2 then
      local st, other = nil, nil
      for _, s in ipairs(c.sparks) do
        if s.k == "stat" then st = s elseif s.k == "trait" then other = s elseif not other then other = s end
      end
      local s1 = G.sparkName(st)
      if F().bold:getTextWidth(s1) > 72 then s1 = G.sparkShort(st) end
      chip(4, 62, 74, 14, s1, true)
      if other then chip(81, 62, 39, 14, other.k == "trait" and other.t or "PNT\u{2605}", false, F().body) end
      local hasP = false
      for _, s in ipairs(c.sparks) do if s.k == "pennant" then hasP = true end end
      if hasP and other and other.k == "trait" then PUI.flag(CW - 34, 1, kept) end
    else
      gfx.setPattern(UI.pat.lighter) gfx.fillRect(4, 62, 116, 14) black() gfx.drawRect(4, 62, 116, 14)
    end
  end
  gfx.popContext()
  self.imgs[key] = img
  return img
end

function RunEnd:keptN() local n = 0 for _ in pairs(self.kept) do n = n + 1 end return n end

function RunEnd:update()
  self.t = self.t + 1
  local n = #self.cands
  if self.phase == "reveal" then
    if self.t >= self.tEnd or self.skip then self.phase = "bank" self.t = 0 end
  end
  local bank = self.phase == "bank"
  self[bank and "base2" or "base1"]:draw(0, 0)
  for i = 1, n do
    local x, y = cardXY(i)
    local stage = 2
    if not bank then
      stage = self.t >= self.tSpark(i) and 2 or (self.t >= self.tFront(i) and 1 or 0)
      if self.t == self.tFront(i) then Sfx.tick() end
      if self.t == self.tSpark(i) then local s = self.cands[i].sparks[1] if s and s.s == 3 then Sfx.coin() else Sfx.focus() end end
    end
    local on = bank and self.sel == i
    self:card(i, stage, self.kept[i]):draw(x, on and y - 2 or y)
    if on then gfx.setLineWidth(2) gfx.drawRect(x - 3, y - 5, CW + 6, CH + 6) gfx.setLineWidth(1) end
  end
  if n == 0 then Text.draw("Nobody played enough to grade.", 200, 100, F().bold, nil, "center") end
  self.keepImg:draw(6, 193)
  -- DONE
  local dx, dy, dw, dh = 318, 196, 70, 20
  local on = bank and self.sel == n + 1
  if on then black() gfx.fillRect(dx, dy, dw, dh) else white() gfx.fillRect(dx, dy, dw, dh) black() gfx.drawRect(dx, dy, dw, dh) end
  Text.draw("DONE \u{25b6}", dx + dw // 2, Text.boxY(F().bold, dy, dh), F().bold, on and "white" or nil, "center")
  PUI.hintBar(bank and "\u{25c0}\u{25b6}\u{25b2}\u{25bc} choose   A: keep / let go   B: to DONE" or "A/B: show them all")
end

function RunEnd:move(dx, dy)
  if self.phase ~= "bank" then return end
  local n = #self.cands
  local s = self.sel
  if s == n + 1 then
    if dy < 0 or dx < 0 then s = n end
  else
    local col, row = (s - 1) % 3, (s - 1) // 3
    if dx ~= 0 then col = col + dx end
    if dy ~= 0 then row = row + dy end
    if dy > 0 and (row > 1 or (row * 3 + col + 1) > n) then s = n + 1
    elseif col >= 0 and col <= 2 and row >= 0 then
      local t = row * 3 + col + 1
      if t <= n then s = t end
    end
  end
  if s ~= self.sel then self.sel = s Sfx.focus() end
end
function RunEnd:leftButtonDown() self:move(-1, 0) end
function RunEnd:rightButtonDown() self:move(1, 0) end
function RunEnd:upButtonDown() self:move(0, -1) end
function RunEnd:downButtonDown() self:move(0, 1) end

function RunEnd:AButtonDown()
  if self.phase ~= "bank" then self.skip = true return end
  local n = #self.cands
  if self.sel <= n then
    if self.kept[self.sel] then self.kept[self.sel] = nil Sfx.back()
    elseif self:keptN() >= self.slots then Sfx.error() Toast.show("Keep slots full: let somebody go first.", "bad") return
    else self.kept[self.sel] = true Sfx.coin() end
    self:paintKeep()
    return
  end
  self:done()
end

function RunEnd:BButtonDown()
  if self.phase ~= "bank" then self.skip = true return end
  if self.sel ~= #self.cands + 1 then self.sel = #self.cands + 1 Sfx.focus() end
end

function RunEnd:done()
  local L = Pennant.L
  local picks = {}
  for i = 1, #self.cands do if self.kept[i] then picks[#picks + 1] = i end end
  local function bank(releases)
    local out = G.bank(L, picks, releases)
    local ids = {}
    for _, a in ipairs(out) do ids[#ids + 1] = a.id end
    Sfx.chime()
    App.pop()
    if self.onDone then self.onDone(ids) end
  end
  local function go()
    -- (the hall holds 40: make room first)
    local A = G.load()
    local new = 0
    for _, i in ipairs(picks) do if not L.run.banked[tostring(self.cands[i].pid)] then new = new + 1 end end
    local over = #A.alumni + new - G.MAX
    if over > 0 then
      PennantUI.AlumniHall.open({ release = over, onDone = function(rel) bank(rel) end })
    else bank() end
  end
  if #picks == 0 and #self.cands > 0 then
    Dialog.confirm("Keep nobody?", "Nobody from this season stays on as an alum.", "Nobody", "Back", function(yes) if yes then go() end end)
    return
  end
  go()
end

-- RUN CHOICE: carry on, or end the run --------------------------------------------------------------

local Choice = scene("RunChoice")

function Choice:enter(args)
  local L = Pennant.L
  local R = L.run
  self.args = args
  self.can = G.canContinue(L)
  self.sel = 1
  self.t = 0
  local T = L.teams[L.user]
  local E = R.endc or {}
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  Draw.tile(0, 0, 400, 240, "light")
  black() gfx.fillRect(27, 15, 352, 196)
  white() gfx.fillRect(24, 12, 352, 196) black()
  gfx.setLineWidth(2) gfx.drawRect(24, 12, 352, 196) gfx.setLineWidth(1)
  gfx.fillRect(24, 12, 352, 16)
  local champ = L.champ == L.user
  local title = champ and "PENNANT WON" or (R.old and "THE SEASON'S IN THE BOOKS" or ((R.endless or 0) > 0 and "THE CAREER" or ("RUN " .. (R.n or 1) .. " IS OVER")))
  Text.draw(title, 30, Text.boxY(F().bold, 12, 16), F().bold, "white")
  Text.draw(L.year .. " \u{2022} " .. T.w .. "-" .. T.l .. " \u{2022} " .. (E.fin or G.finishText(L)), 370, Text.boxY(F().body, 12, 16), F().body, "white", "right")
  local y = 34
  local A = G.load()
  if champ and not R.old then
    Draw.wordart(L.year .. " CHAMPS", 200, y, UI.fonts.slab)
    y = y + 34
  end
  local lines = {}
  if E.kept and E.kept > 0 then lines[#lines + 1] = { E.kept .. (E.kept == 1 and " ALUM" or " ALUMNI") .. " BANKED. THE HALL HOLDS " .. #A.alumni .. ".", true } end
  if E.unlockedNow then lines[#lines + 1] = { "LEGACIES UNLOCKED: NEW RUNS START WITH TWO ALUMNI AND A DECK.", true }
  elseif not A.unlocked then lines[#lines + 1] = { "MAKE THE PLAYOFFS TO UNLOCK LEGACIES AND THE DECK." } end
  if self.can then
    if R.old then lines[#lines + 1] = { "This career began before runs: carry on as always, or end it and start a run with your alumni." }
    elseif (R.endless or 0) > 0 and not champ then lines[#lines + 1] = { "The career goes on until two losing seasons in a row (or you call it)." }
    else lines[#lines + 1] = { "CONTINUE: same club, aging and the farm as ever. Heat +1 a season. Your legacies give half on Opening Day, no inspirations. Bank 1 a season (2 with a pennant)." } end
  else
    lines[#lines + 1] = { "Your alumni stay in the Hall. A new run starts with a new league; pick your club, your legacies and your deck." }
    if (R.losing or 0) >= 2 then lines[#lines + 1] = { "Two losing seasons running: the career is over." } end
  end
  for _, l in ipairs(lines) do
    y = y + Text.block(l[1], 34, y, 332, l[2] and F().bold or F().body, nil, 4) + 4
  end
  self.optY = 160
  gfx.popContext()
  self.bg = img
  self.opts = self.can and { "CONTINUE CAREER", "END THE RUN" } or { "START A NEW RUN" }
  self.optImg = {}
end

function Choice:opt(i, on)
  local key = i * 2 + (on and 1 or 0)
  if self.optImg[key] then return self.optImg[key] end
  local w = #self.opts == 1 and 200 or 160
  local img = gfx.image.new(w, 24, gfx.kColorWhite)
  gfx.pushContext(img)
  if on then gfx.fillRect(0, 0, w, 24) else gfx.drawRect(0, 0, w, 24) end
  Text.draw(self.opts[i], w // 2, Text.boxY(F().bold, 0, 24), F().bold, on and "white" or nil, "center")
  gfx.popContext()
  self.optImg[key] = img
  return img
end

function Choice:update()
  self.t = self.t + 1
  self.bg:draw(0, 0)
  if #self.opts == 1 then self:opt(1, true):draw(100, 176)
  else for i = 1, 2 do self:opt(i, i == self.sel):draw(i == 1 and 34 or 206, 176) end end
  PUI.hintBar(#self.opts == 1 and "A: a new run   B: the title screen" or "\u{25c0}\u{25b6} choose   A: decide")
end

function Choice:leftButtonDown() if #self.opts > 1 and self.sel ~= 1 then self.sel = 1 Sfx.focus() end end
function Choice:rightButtonDown() if #self.opts > 1 and self.sel ~= 2 then self.sel = 2 Sfx.focus() end end

function Choice:AButtonDown()
  if self.t < 10 then return end
  local L = Pennant.L
  if #self.opts > 1 and self.sel == 1 then
    Sfx.coin()
    App.pop()
    G.continueCareer(L)
    if self.args.onContinue then self.args.onContinue() end
    return
  end
  if #self.opts > 1 then
    Dialog.confirm("End the run?", "The club and this league go; your alumni stay in the Hall.", "End it", "Back", function(yes)
      if yes then PennantUI.endRun(L) end
    end)
    return
  end
  PennantUI.endRun(L)
end

function Choice:BButtonDown()
  if #self.opts == 1 then PennantUI.endRun(Pennant.L, true) end
end

--- The run is over: written down in the slot (it waits for a new run), then the new-run flow
--- (or the title screen).
function PennantUI.endRun(L, toTitle)
  G.endRun(L)
  PJobs.flush()
  PUI.busy("Closing the books", function() PSave.saveNow(L, L.slot) end)
  local slot = L.slot
  playdate.frameTimer.performAfterDelay(4, function()
    Pennant.L = nil
    Pennant.hub = nil
    while #App.stack > (Pennant.base or 0) do App.pop() end
    PennantUI.Title.open({})
    if not toTitle then PennantUI.NewGame.open({ slot = slot }) end
  end)
end

--- Pennant.seasonEndHooks: grades and sparks, the keep, the Hall of Fame, then carry on or not.
function PennantUI.legacyEnd(L, nx)
  local R = G.ensure(L)
  local function choice()
    PennantUI.RunChoice.open({ onContinue = function() nx() end })
  end
  local E = G.seasonEnd(L)
  if E.banked then choice() return end
  PennantUI.RunEnd.open({ onDone = function(ids)
    PennantUI.HallOfFame.open({ fresh = ids, after = true, onDone = choice })
  end })
end
Pennant.seasonEndHooks[#Pennant.seasonEndHooks + 1] = function(L, nx) PennantUI.legacyEnd(L, nx) end

-- LEGACY PICK: two alumni for a new run --------------------------------------------------------------

local Pick = scene("LegacyPick")

function Pick:enter(args)
  self.args = args
  self.L = args.L
  local A = G.load()
  local a, b = G.bestPair(A)
  self.leg = { a, b }
  self.sel = 3
  self.t = 0
  self:paint()
end

function Pick:resume() self:paint() end

local function parentCard(a, x, y, w, h)
  black() gfx.fillRect(x + 3, y + 3, w, h)
  white() gfx.fillRect(x, y, w, h) black()
  gfx.setLineWidth(2) gfx.drawRect(x, y, w, h) gfx.setLineWidth(1)
  gfx.fillRect(x, y, w, 16)
  if not a then
    Text.draw("EMPTY", x + 6, Text.boxY(F().bold, y, 16), F().bold, "white")
    Text.block("Bank another alum to fill this slot.", x + 8, y + 26, w - 16, F().body, nil, 3)
    return
  end
  local nm = Text.ellipsize(G.short(a):upper() .. " \u{2022} " .. G.posOf(a), F().bold, w - 50)
  Text.draw(nm, x + 6, Text.boxY(F().bold, y, 16, nm), F().bold, "white")
  Text.draw("RUN " .. (a.run or "?"), x + w - 6, Text.boxY(F().body, y, 16), F().body, "white", "right")
  gradeBox(x + 6, y + 20, 26, 22, a.grade)
  local l1 = (a.fin == "PENNANT" and ("PENNANT " .. a.year)) or (a.fin == "PLAYOFFS" and ("PLAYOFFS " .. a.year)) or (a.year .. " \u{2022} " .. (a.club or ""))
  Text.draw(Text.ellipsize(l1, F().body, w - 42), x + 37, y + 18, F().body)
  Text.draw(Text.ellipsize(a.note or a.line or "", F().body, w - 42), x + 37, y + 30, F().body)
  Text.draw("HIS SPARKS", x + 6, y + 45, F().body)
  local sy = y + 58
  for _, s in ipairs(a.sparks or {}) do
    local dark = s.k == "stat"
    if dark then black() gfx.fillRect(x + 5, sy, w - 10, 13) else white() gfx.fillRect(x + 5, sy, w - 10, 13) black() gfx.drawRect(x + 5, sy, w - 10, 13) end
    local col = dark and "white" or nil
    local nmS = G.sparkName(s)
    Text.draw(nmS, x + 9, Text.boxY(F().bold, sy, 13, nmS), F().bold, col)
    Text.draw(s.k == "stat" and "STAT" or (s.k == "trait" and "TRAIT" or "PRIDE"), x + w - 9, Text.boxY(F().body, sy, 13), F().body, col, "right")
    sy = sy + 15
  end
  sy = max(sy, y + 100)
  Text.draw("FROM HIS LEGACY", x + 6, sy, F().body)
  sy = sy + 12
  local inh = {}
  for _, gp in ipairs(a.par or {}) do for _, s in ipairs(gp.sp or {}) do inh[#inh + 1] = gp.n:upper() .. ": " .. G.sparkShort(s) .. (s.k == "trait" and (" " .. G.STARS[s.s]) or "") end end
  if #inh == 0 then Text.draw("(none: he was run 1's)", x + 10, sy, F().body) end
  for i = 1, min(2, #inh) do
    local s = (i == 2 and #inh > 2) and (inh[i] .. " +" .. (#inh - 2)) or inh[i]
    Text.draw(Text.ellipsize(s, F().body, w - 14), x + 10, sy, F().body)
    sy = sy + 12
  end
end

function Pick:paint()
  local L = self.L
  local A = G.load()
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  Draw.tile(0, 0, 400, 240, "light")
  blackTop("RUN " .. ((A.runs or 0) + 1) .. " \u{2022} PICK YOUR LEGACY", "ALUMNI HALL: " .. #A.alumni)
  parentCard(self.leg[1], 8, 22, 150, 136)
  parentCard(self.leg[2], 242, 22, 150, 136)
  local chem, why = G.chemistry(self.leg[1], self.leg[2])
  self.chem = chem
  -- chemistry
  white() gfx.fillRect(164, 56, 72, 50) black()
  gfx.setLineWidth(2) gfx.drawRect(164, 56, 72, 50) gfx.setLineWidth(1)
  Text.draw("CHEMISTRY", 200, 59, F().body, nil, "center")
  local cs = tostring(chem)
  local cw = F().head:getTextWidth(cs)
  chemGlyph(200 - (cw + 13) // 2, 80, G.chemMark(chem))
  Text.draw(cs, 200 - (cw + 13) // 2 + 13, 76, F().head)
  Text.draw(chem >= 60 and "GREAT" or (chem >= 30 and "GOOD" or "LOW"), 200, 92, F().body, nil, "center")
  local wy = 110
  for i = 1, min(4, #why) do
    local s = Text.ellipsize(why[i], F().body, 80)
    white() gfx.fillRect(200 - F().body:getTextWidth(s) // 2 - 2, wy, F().body:getTextWidth(s) + 4, 12) black()
    Text.draw(s, 200, wy, F().body, nil, "center")
    wy = wy + 12
  end
  -- what they should do
  local bx, by, bw, bh = 6, 162, 388, 58
  white() gfx.fillRect(bx, by, bw, bh) black() gfx.drawRect(bx, by, bw, bh)
  gfx.fillRect(bx, by, bw, 13)
  local wk = L and G.inspWeeks(L) or { 9, 18 }
  local head = "SPARKS FIRE ON OPENING DAY, THEN MAY FIRE AGAIN IN WEEKS " .. wk[1] .. " AND " .. wk[2]
  Text.draw(Text.ellipsize(head, F().bold, bw - 10), bx + 5, Text.boxY(F().bold, by, 13, head), F().bold, "white")
  local ex, traits = G.expect({ self.leg[1], self.leg[2] }, chem)
  local y = by + 16
  for i = 1, min(3, #ex) do
    local e = ex[i]
    Text.draw(Text.ellipsize(e.unit .. " " .. PM.LABEL[e.a]:upper() .. "  +" .. e.now .. " NOW, UP TO +" .. e.upto, F().body, 220), bx + 5, y, F().body)
    y = y + 13
  end
  if #ex == 0 then Text.draw("No rating sparks.", bx + 5, y, F().body) end
  local rx = bx + bw - 5
  Text.draw("TRAITS MAY CARRY OVER:", rx, by + 16, F().body, nil, "right")
  local seen, tl = {}, {}
  for _, t in ipairs(traits) do if not seen[t] then seen[t] = true tl[#tl + 1] = t end end
  Text.draw(Text.ellipsize(#tl > 0 and table.concat(tl, " \u{2022} ") or "NONE", F().bold, 150), rx, by + 29, F().bold, nil, "right")
  Text.draw("CHEMISTRY " .. chem .. ": +" .. chem .. "% TO FIRE AGAIN", rx, by + 42, F().body, nil, "right")
  gfx.popContext()
  self.img = img
end

function Pick:update()
  self.t = self.t + 1
  self.img:draw(0, 0)
  -- focus
  if self.sel <= 2 then
    local x = self.sel == 1 and 8 or 242
    gfx.setLineWidth(2) gfx.drawRect(x - 3, 19, 156, 142) gfx.setLineWidth(1)
  end
  black() gfx.fillRect(0, 224, 400, 16)
  local ty = Text.boxY(F().body, 224, 16)
  Text.draw(self.sel <= 2 and "\u{25c0}\u{25b6} slot   A: swap from the Hall   B: back" or "\u{25c0}\u{25b6} a legacy slot   A: on to the deck", 5, ty, F().body, "white")
  local s = "NEXT \u{25b6}"
  local sw = F().bold:getTextWidth(s) + 12
  if self.sel == 3 then white() gfx.fillRect(400 - sw - 3, 226, sw, 12) Text.draw(s, 400 - 9, Text.boxY(F().bold, 226, 12), F().bold, nil, "right")
  else Text.draw(s, 400 - 9, ty, F().bold, "white", "right") end
end

function Pick:leftButtonDown() self.sel = self.sel == 1 and 3 or self.sel - 1 Sfx.focus() end
function Pick:rightButtonDown() self.sel = self.sel % 3 + 1 Sfx.focus() end
function Pick:upButtonDown() end
function Pick:downButtonDown() if self.sel ~= 3 then self.sel = 3 Sfx.focus() end end

function Pick:AButtonDown()
  if self.t < 4 then return end
  if self.sel <= 2 then
    local other = self.leg[3 - self.sel]
    local k = self.sel
    Sfx.select()
    PennantUI.AlumniHall.open({ title = "Pick a legacy", pick = function(a) self.leg[k] = a end,
      filter = function(a) return not other or a.id ~= other.id end })
    return
  end
  Sfx.select()
  local leg = { self.leg[1], self.leg[2] }
  PennantUI.DeckPick.open({ L = self.L, leg = leg, onDone = self.args.onDone })
end

function Pick:BButtonDown()
  Sfx.back()
  App.pop()
end

-- DECK PICK + HEAT ---------------------------------------------------------------------------------------

local Deck = PUI.define({ title = "New run: the deck", hint = "A: change  \u{25c0}\u{25b6} heat" })
PennantUI.DeckPick = Deck

function Deck:init(args)
  self.args = args
  local A = G.load()
  self.n = G.deckSlots(A)
  local legIds = {}
  for _, a in ipairs(args.leg or {}) do if a then legIds[a.id] = true end end
  local pool = { alumni = {} }
  for _, a in ipairs(A.alumni) do if not legIds[a.id] then pool.alumni[#pool.alumni + 1] = a end end
  self.deck = G.bestDeck(pool, self.n)
  self.heat = A.lastHeat or 0
  self.legIds = legIds
end

function Deck:resume(r) Page.resume(self, r) self:render(true) end

local SPEC_NAME <const> = { bat = "BATTING", arms = "ARMS", def = "DEFENSE", gym = "GYM", farm = "FARM" }

function Deck:layout(Lb)
  local A = G.load()
  local y = 4
  Text.block("Your deck turns up at the weekly programs (most often at his specialty): +5% gains each, and a bond. At 80 bond, a week at his specialty is a RALLY WEEK: x1.3 (x1.5 for grade A and up).", 6, y, 388, F().body, nil, 3)
  y = y + 44
  for i = 1, self.n do
    local a = self.deck[i]
    local yy = y
    white() gfx.fillRect(6, yy, 388, 24) black() gfx.drawRect(6, yy, 388, 24)
    Text.draw("SLOT " .. i, 12, Text.boxY(F().bold, yy, 24), F().bold)
    if a then
      gradeBox(64, yy + 3, 26, 18, a.grade)
      Text.draw(Text.ellipsize(G.short(a):upper() .. " \u{2022} " .. G.posOf(a), F().bold, 160), 96, Text.boxY(F().bold, yy, 24), F().bold)
      Text.draw(SPEC_NAME[G.specialty(a)] .. " MENTOR", 388, Text.boxY(F().body, yy, 24), F().body, nil, "right")
    else
      Text.draw("EMPTY", 64, Text.boxY(F().body, yy, 24), F().body)
    end
    Lb:link(6, yy, 388, 24, function()
      PennantUI.AlumniHall.open({ title = "Deck slot " .. i, allowEmpty = true, pick = function(x)
        -- (one alum, one slot)
        for j = 1, self.n do if self.deck[j] and x and self.deck[j].id == x.id then self.deck[j] = nil end end
        self.deck[i] = x
      end, filter = function(x) return not self.legIds[x.id] end })
    end, { id = "d" .. i, style = "ring", hint = "A: pick from the Hall" })
    y = y + 28
  end
  local nxt = self.n < 3 and ("A 3RD SLOT AT 5 BANKED (" .. (A.banked or 0) .. ")") or (self.n < 4 and ("A 4TH SLOT AT 15 BANKED (" .. (A.banked or 0) .. ")") or "ALL FOUR SLOTS OPEN")
  Text.draw(nxt, 12, y, F().body)
  y = y + 18
  -- heat
  local h = self.heat
  white() gfx.fillRect(6, y, 388, 24) black() gfx.drawRect(6, y, 388, 24)
  Text.draw("PENNANT HEAT", 12, Text.boxY(F().bold, y, 24), F().bold)
  Text.draw("\u{25c0} " .. h .. " \u{25b6}", 150, Text.boxY(F().bold, y, 24), F().bold, nil, "center")
  local hs = h == 0 and "THE LEAGUE AS IT COMES" or ("AI CLUBS +" .. G.heatOf(h) .. " IN GAMES \u{2022} \u{2605}\u{2605}\u{2605} SPARKS +" .. (5 * h) .. "%")
  Text.draw(Text.ellipsize(hs, F().body, 210), 388, Text.boxY(F().body, y, 24, hs), F().body, nil, "right")
  Lb:link(6, y, 388, 24, function() self.heat = (self.heat + 1) % (G.HEAT_MAX + 1) self:render(true) end,
    PUI.opts("heat", "\u{25c0}\u{25b6} Heat 0-10: tougher clubs, better sparks", function(d) self.heat = math.max(0, math.min(G.HEAT_MAX, self.heat + d)) end, "ring"))
  y = y + 30
  Lb:button("Play ball!", 140, y, 120, 20, function() self:go() end, { id = "go", hint = "Opening Day: the legacy fires" })
  Lb:mark(y + 24)
end

function Deck:initialFocus() for i, l in ipairs(self.links) do if l.id == "go" then return i end end return 1 end

function Deck:go()
  local A = G.load()
  A.lastHeat = self.heat
  local deck = {}
  for i = 1, self.n do if self.deck[i] then deck[#deck + 1] = self.deck[i] end end
  Sfx.coin()
  local cb = self.args.onDone
  App.pop()
  local top = App.top()
  if top and getmetatable(top) == PennantUI.LegacyPick then App.pop() end
  if cb then cb({ leg = self.args.leg, deck = deck, heat = self.heat }) end
end

-- ALUMNI HALL: browse / pick / release ---------------------------------------------------------------

local Hall = PUI.define({ title = function(self) return (self.args and self.args.title) or "Alumni hall" end, hint = "A: choose" })
PennantUI.AlumniHall = Hall

function Hall:init(args)
  self.args = args or {}
  self.released = {}
  self.need = self.args.release or 0
end

function Hall:resume(r) Page.resume(self, r) self:render(true) end

function Hall:list()
  local A = G.load()
  local out = {}
  for _, a in ipairs(A.alumni) do
    if not self.released[a.id] and (not self.args.filter or self.args.filter(a)) then out[#out + 1] = a end
  end
  table.sort(out, function(x, y) if (x.score or 0) ~= (y.score or 0) then return (x.score or 0) > (y.score or 0) end return x.id < y.id end)
  return out
end

local function alumRow(a, x, y, w)
  white() gfx.fillRect(x, y, w, 26) black() gfx.drawRect(x, y, w, 26)
  gradeBox(x + 3, y + 3, 30, 20, a.grade)
  Text.draw(Text.ellipsize(G.short(a):upper() .. " \u{2022} " .. G.posOf(a), F().bold, 150), x + 38, y + 1, F().bold)
  Text.draw(Text.ellipsize("RUN " .. (a.run or "?") .. " \u{2022} " .. (a.year or "") .. " " .. (a.club or "") .. " \u{2022} " .. (a.line or ""), F().body, 170), x + 38, y + 13, F().body)
  local sp = {}
  for _, s in ipairs(a.sparks or {}) do sp[#sp + 1] = G.sparkShort(s) end
  Text.draw(Text.ellipsize(table.concat(sp, " \u{2022} "), F().body, 160), x + w - 4, y + 1, F().body, nil, "right")
  Text.draw(tostring(a.score or 0), x + w - 4, y + 13, F().bold, nil, "right")
end
PennantUI.alumRow = alumRow

function Hall:layout(Lb)
  local A = G.load()
  local y = 4
  local head
  if self.need > 0 then head = "THE HALL IS FULL (" .. G.MAX .. "): RELEASE " .. self.need .. " TO MAKE ROOM."
  elseif self.args.pick then head = "Pick one (best first)."
  else head = #A.alumni .. " OF " .. G.MAX .. " \u{2022} A: an alum's options (release)" end
  Text.draw(head, 6, y, self.need > 0 and F().bold or F().body)
  y = y + 18
  if self.args.allowEmpty then
    Lb:button("Leave it empty", 6, y, 120, 18, function() self.args.pick(nil) App.pop() end, { id = "empty" })
    y = y + 24
  end
  local list = self:list()
  if #list == 0 then Text.draw("Nobody here yet.", 10, y, F().body) y = y + 16 end
  for i, a in ipairs(list) do
    local yy = y
    PUI.lazy(Lb, 6, yy, 386, 26, function() alumRow(a, 6, yy, 386) end)
    Lb:link(6, yy, 386, 26, function() self:choose(a) end, { id = "a" .. a.id, style = "ring", hint = (a.par and #a.par > 0) and ("Legacy of " .. a.par[1].n .. (a.par[2] and (" and " .. a.par[2].n) or "")) or "A: choose" })
    y = y + 29
  end
  Lb:mark(y + 4)
end

function Hall:choose(a)
  if self.args.pick then
    Sfx.select()
    self.args.pick(a)
    App.pop()
    return
  end
  local function release()
    Dialog.confirm("Release " .. G.short(a) .. "?", "He leaves the Hall for good (and the Hall of Fame).", "Release", "Keep", function(yes)
      if not yes then return end
      if self.need > 0 then
        self.released[a.id] = true
        self.need = self.need - 1
        if self.need <= 0 then
          local rel = {}
          for id in pairs(self.released) do rel[#rel + 1] = id end
          App.pop()
          if self.args.onDone then self.args.onDone(rel) end
          return
        end
      else
        local A = G.load()
        G.release(A, a.id)
        G.hofRefresh(A)
        G.save()
      end
      self:render(true)
    end)
  end
  if self.need > 0 then release() return end
  Menu.open({ x = 150, y = 120, items = { { label = "Release " .. G.short(a), action = release }, { label = "Keep him", action = function() end } } })
end

function Hall:goBack()
  if self.need > 0 then Toast.show("Release " .. self.need .. " more to make room.", "bad") return end
  App.pop()
end

-- HALL OF FAME: the All-Time Lineup --------------------------------------------------------------------

local HoF = PUI.define({ title = "Hall of Fame", hint = "A: set the slot" })
PennantUI.HallOfFame = HoF

function HoF:init(args)
  self.args = args or {}
  self.fresh = {}
  for _, id in ipairs(self.args.fresh or {}) do self.fresh[id] = true end
  if self.args.after then Sfx.stinger("win") end
end

function HoF:resume(r) Page.resume(self, r) self:render(true) end

function HoF:layout(Lb)
  local A = G.load()
  local st = G.hofStats(A)
  -- the rating
  black() gfx.fillRect(4, 2, 190, 22)
  Text.draw("FRANCHISE RATING", 9, Text.boxY(F().bold, 2, 22), F().bold, "white")
  Text.draw(tostring(st.fr), 160, Text.boxY(F().head, 2, 22), F().head, "white", "right")
  gradeBox(164, 4, 26, 18, st.fr > 0 and st.grade or "-")
  local auto = A.hof.auto
  Lb:button(auto and "AUTO: ON" or "AUTO: OFF", 200, 3, 80, 20, function()
    A.hof.auto = not A.hof.auto
    if A.hof.auto then A.hof.slots = G.hofSuggest(A) end
    G.save()
    self:render(true)
  end, { id = "auto", hint = "AUTO: the best lineup the Hall can field, kept up to date" })
  Lb:button("Alumni", 286, 3, 54, 20, function() PennantUI.AlumniHall.open({}) end, { id = "hall", hint = "Every alum: browse, release" })
  if self.args.after then
    Lb:button("Next \u{25b6}", 344, 3, 50, 20, function() self:goBack() end, { id = "next", hint = "On" })
  end
  local function slotRow(slot, x, y, w)
    local id = A.hof.slots[slot]
    local a = id and G.byId(A, id)
    local new = a and self.fresh[a.id]
    white() gfx.fillRect(x, y, w, 18) black() gfx.drawRect(x, y, w, 18)
    black() gfx.fillRect(x, y, 26, 18)
    Text.draw(slot, x + 13, Text.boxY(F().bold, y, 18), F().bold, "white", "center")
    if a then
      local nm = G.short(a):upper() .. (new and "  NEW" or "")
      Text.draw(Text.ellipsize(nm, new and F().bold or F().body, w - 66), x + 30, Text.boxY(F().body, y, 18, nm), new and F().bold or F().body)
      gradeBox(x + w - 32, y + 2, 30, 14, a.grade)
    else
      gfx.setPattern(UI.pat.lighter) gfx.fillRect(x + 27, y + 1, w - 28, 16) black()
      Text.draw("-", x + 32, Text.boxY(F().body, y, 18), F().body)
    end
    Lb:link(x, y, w, 18, function()
      PennantUI.AlumniHall.open({ title = "Hall of Fame: " .. slot, allowEmpty = true, filter = function(x2) return G.fits(x2, slot) end, pick = function(x2)
        for k, v in pairs(A.hof.slots) do if x2 and v == x2.id then A.hof.slots[k] = nil end end
        A.hof.slots[slot] = x2 and x2.id or nil
        A.hof.auto = false
        G.save()
      end })
    end, { id = "s" .. slot, style = "ring", hint = a and (G.short(a) .. ": " .. (a.line or "") .. ", run " .. (a.run or "?") .. " (" .. (a.score or 0) .. ")") or ("A: put an alum at " .. slot) })
  end
  local y = 28
  for i = 1, 9 do slotRow(G.HOF[i], 4, y + (i - 1) * 20, 190) end
  for i = 10, 16 do slotRow(G.HOF[i], 202, y + (i - 10) * 20, 192) end
  -- goals
  local gy = y + 7 * 20 + 2
  local function goal(label, n, of, yy)
    Text.draw(label, 204, yy, F().body)
    Text.draw(n .. "/" .. of, 394, yy, F().bold, nil, "right")
  end
  goal("FILL EVERY SLOT", st.filled, st.total, gy)
  goal("GRADE-A LINEUP", st.aN, st.total, gy + 13)
  goal("LEGEND EVERYWHERE", st.legend, st.total, gy + 26)
  Lb:mark(208)
end

function HoF:initialFocus()
  for i, l in ipairs(self.links) do if l.id == (self.args.after and "next" or "sC") then return i end end
  return 1
end

function HoF:goBack()
  App.pop()
  if self.args.onDone then self.args.onDone() end
end

-- LEGACY INFO (the Office): this run's legacy, the cap, the deck ----------------------------------------

local Info = PUI.define({ title = "Legacy & alumni", hint = "A: open" })
PennantUI.LegacyInfo = Info

function Info:resume(r) Page.resume(self, r) self:render(true) end

function Info:layout(Lb)
  local L = Pennant.L
  local R = G.ensure(L)
  local y = 2
  local head = R.old and "A CAREER FROM BEFORE RUNS" or ("RUN " .. (R.n or "?"))
  if (R.endless or 0) > 0 then head = head .. " \u{2022} CAREER SEASON " .. (R.endless + 1) end
  head = head .. " \u{2022} HEAT " .. (R.heat or 0)
  Text.draw(head, 6, y, F().bold)
  y = y + 16
  if R.leg then
    Text.draw("LEGACIES", 6, y, F().bold)
    chemGlyph(300, y + 2, G.chemMark(R.chem or 0))
    Text.draw("CHEMISTRY " .. (R.chem or 0), 394, y, F().body, nil, "right")
    y = y + 14
    for _, a in ipairs(R.leg) do
      local sp = {}
      for _, s in ipairs(a.sparks or {}) do sp[#sp + 1] = G.sparkName(s) end
      Text.draw(Text.ellipsize(G.short(a):upper() .. " (" .. a.grade .. "): " .. table.concat(sp, " \u{2022} "), F().body, 386), 10, y, F().body)
      y = y + 13
    end
    -- this season's legacy points against the cap
    local parts = {}
    if R.gainSeason == L.season then
      for _, k in ipairs({ "con", "pow", "eye", "spd", "fld", "arm", "velo", "ctl", "stf", "sta" }) do
        if (R.gains[k] or 0) > 0 then parts[#parts + 1] = PM.SHORT[k] .. " " .. R.gains[k] .. "/" .. G.CAP end
      end
    end
    Text.draw(Text.ellipsize("THIS SEASON: " .. (#parts > 0 and table.concat(parts, "  ") or "NOTHING YET"), F().body, 386), 10, y, F().body)
    y = y + 13
    local wk = G.inspWeeks(L)
    local ins = {}
    for i = 1, 2 do local r = R.insp["i" .. i] ins[#ins + 1] = "WEEK " .. wk[i] .. (r and (": " .. r.fired .. "/" .. #r.rows .. " FIRED") or "") end
    if (R.endless or 0) == 0 then Text.draw("INSPIRATIONS: " .. table.concat(ins, " \u{2022} "), 10, y, F().body) y = y + 13 end
  else
    Text.block(G.unlocked() and "This run started without legacies." or "No legacy yet: make the playoffs once and new runs start with two alumni.", 10, y, 380, F().body, nil, 2)
    y = y + 28
  end
  y = y + 4
  Text.draw("THE DECK", 6, y, F().bold)
  y = y + 15
  if #(R.deck or {}) == 0 then Text.draw("Nobody: the deck opens with legacies.", 10, y, F().body) y = y + 14 end
  local pl = G.placements(L, PWeek.span(L).w) or {}
  local where = {}
  for prog, list in pairs(pl) do for _, i in ipairs(list) do where[i] = prog end end
  for i, d in ipairs(R.deck or {}) do
    local b = G.bond(L, d)
    gradeBox(10, y, 24, 14, d.grade)
    Text.draw(Text.ellipsize(G.short(d):upper() .. " \u{2022} " .. SPEC_NAME[d.spec], F().body, 160), 40, y, F().body)
    PennantUI.weekBar(196, y + 3, 50, 8, b / 100, (b < G.RALLY) and "gray" or nil)
    Text.draw(tostring(b), 250, y, F().bold)
    local w = where[i]
    Text.draw(w and ("THIS WEEK: " .. SPEC_NAME[w] .. ((w == d.spec and b >= G.RALLY) and " \u{2605}" or "")) or "AWAY", 394, y, F().body, nil, "right")
    y = y + 16
  end
  y = y + 6
  Lb:button("Hall of Fame", 6, y, 120, 20, function() PennantUI.HallOfFame.open({}) end, { id = "hof", hint = "The All-Time Lineup" })
  Lb:button("Alumni hall", 132, y, 120, 20, function() PennantUI.AlumniHall.open({}) end, { id = "hall", hint = "Every alum" })
  Lb:mark(y + 24)
end

-- The program cards' "with" slot: who's at the program this week ------------------------------------------

G.flash = 0

local function drawWith(L, pres, x, y, w, h)
  local R = L.run
  local n = min(2, #pres)
  -- a white panel at the box's right (over the icon's tail): one badge per alum, his bond under it
  local pw = n * 18 + 1
  white() gfx.fillRect(x + w - pw, y + 1, pw - 1, h - 2) black()
  gfx.drawLine(x + w - pw, y + 1, x + w - pw, y + h - 2)
  for k = 1, n do
    local e = pres[k]
    local d = R.deck[e.i]
    local bx = x + w - k * 18
    local by = y + 2
    -- a Rally Week: the badge flashes (black / ringed)
    local dark = e.rally and G.flash == 0
    if dark then black() gfx.fillRect(bx, by, 16, 13)
    else
      white() gfx.fillRect(bx, by, 16, 13) black()
      gfx.drawRect(bx, by, 16, 13)
      if e.rally then gfx.drawRect(bx + 1, by + 1, 14, 11) end
    end
    local ini = G.initials(d)
    local f = F().bold
    if f:getTextWidth(ini) > 14 then f = F().body end
    if f:getTextWidth(ini) > 14 then ini = ini:sub(2, 2) end
    Text.draw(ini, bx + 8, Text.boxY(f, by, 13), f, dark and "white" or nil, "center")
    -- the bond
    local b = G.bond(L, d)
    black() gfx.drawRect(bx, y + 16, 16, 4)
    gfx.fillRect(bx + 1, y + 17, max(0, min(14, floor(14 * b / 100 + 0.5))), 2)
  end
  if #pres > 2 then
    white() gfx.fillRect(x + 1, y + 1, 13, 12) black()
    Text.draw("+" .. (#pres - 2), x + 2, y, F().bold)
  end
end

function PWeek.withSlot(L, prog)
  local R = L.run
  if not R or #(R.deck or {}) == 0 then return nil end
  local pres = G.present(L, prog)
  if #pres == 0 then return nil end
  return { draw = function(x, y, w, h) drawWith(L, pres, x, y, w, h) end }
end

--- The card cache's key part for the slot (who's there, the flash of a Rally Week).
function PWeek.withKey(L, prog)
  local R = L.run
  if not R or #(R.deck or {}) == 0 then return "" end
  local pres = G.present(L, prog)
  if #pres == 0 then return "" end
  local rally = false
  for _, e in ipairs(pres) do if e.rally then rally = true end end
  return #pres .. (rally and ("r" .. G.flash) or "")
end
