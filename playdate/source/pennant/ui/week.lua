--[[ The WEEK screen: Pennant's home (Pennant.hub). One decision a week for the whole club:
  a program (BATTING / ARMS / DEFENSE / GYM / FARM, or a REST WEEK) at an intensity, then A runs
  the week (pennant/week.lua; the run is the Advance screen in week mode, ui/gameday.lua).

    top bar     WEEK n / N, the club's record and place, the date
    ribbon      this month's goal and its progress
    left        ENERGY (the big club's fatigue), MOOD (five pips), THE CLUB: six unit grades
    cards       the five programs: what they move this week, the facility level, the injury risk
                (a "with" slot for future mentors sits in the icon box: PWeek.withSlot)
    intensity   LIGHT / NORMAL / HARD, and REST WEEK
    THIS WEEK   the week's games; the featured one is starred. Each game's glyph says how it's
                played (blank: sim, eye: watch, bat, ball: pitch, both); the strip is a focus row
  Focus rows (up/down): the program cards (left/right: the program), the intensity (left/right),
  the games strip (left/right: a game, A cycles SIM / WATCH / BAT / PITCH / BAT+PITCH). A on the
  cards or the intensity runs the week.
  B: the OFFICE (everything else, none of it required).

  Drawing: a static base (bars, the left column, the strip) and one image per card / intensity
  state, cached; a selection change is a few blits into the frame, and a frame is one blit.
]]

local gfx <const> = playdate.graphics
local floor, max, min = math.floor, math.max, math.min
PennantUI = PennantUI or {}

local Week = { opaque = true }
Week.__index = Week
PennantUI.Week = Week

local function F() return UI.fonts end
local function L_() return Pennant.L end

function Week.replace(args) local s = setmetatable({}, Week) App.replace(s, args) return s end
function Week.open(args) local s = setmetatable({}, Week) App.push(s, args) return s end

-- geometry
local CX0 <const>, CW <const>, CG <const>, CY <const>, CH <const> = 103, 55, 4, 40, 107
local SEL_REST <const> = 6
local ROW_CARDS <const>, ROW_INT <const>, ROW_GAMES <const> = 1, 2, 3
local ROW_TIRED <const> = 0   -- the TIRED chip on THE CLUB (up from the cards, when anyone's tired)
local STRIP_Y <const>, STRIP_H <const> = 201, 21

-- The mode glyphs (blank: sim, an eye: watch, a bat, a ball: pitch, bat and ball: both), 15 x 11,
-- cached per mode and colour.
local glyphs = {}
function PennantUI.modeGlyph(mode, white)
  if mode == "sim" or not mode then return nil end
  local key = mode .. (white and "w" or "b")
  local img = glyphs[key]
  if img then return img end
  img = gfx.image.new(15, 11, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(white and gfx.kColorWhite or gfx.kColorBlack)
  local function bat(x0, y0, x1, y1)
    local mx, my = (x0 + x1) // 2, (y0 + y1) // 2
    gfx.setLineWidth(1) gfx.drawLine(x0, y0, mx, my)
    gfx.setLineWidth(3) gfx.drawLine(mx, my, x1, y1)
    gfx.setLineWidth(1)
  end
  local function ball(cx, cy, r)
    gfx.drawCircleAtPoint(cx, cy, r)
    if r >= 4 then
      gfx.drawArc(cx - r - 3, cy, r + 1, 60, 120)
      gfx.drawArc(cx + r + 3, cy, r + 1, 240, 300)
    else
      gfx.fillCircleAtPoint(cx, cy, 1)
    end
  end
  if mode == "watch" then
    gfx.drawEllipseInRect(1, 1, 13, 9)
    gfx.fillCircleAtPoint(7, 5, 2)
  elseif mode == "bat" then
    bat(2, 10, 12, 1)
  elseif mode == "pitch" then
    ball(7, 5, 5)
  elseif mode == "both" then
    bat(0, 10, 7, 2)
    ball(11, 6, 3)
  end
  gfx.popContext()
  glyphs[key] = img
  return img
end

--- The legacy hook: faces / marks in a program card's "with" slot (the icon box). nil = none.
--- (pennant/ui/legacy.lua draws the alumni deck there; PWeek.withKey is its part of the card key)
PWeek.withSlot = PWeek.withSlot or function(L, prog) return nil end
PWeek.withKey = PWeek.withKey or function(L, prog) return "" end

function Week:enter()
  local c = PWeek.ensure(L_())
  self.sel = SEL_REST
  for i, k in ipairs(PWeek.PROGS) do if k == c.prog then self.sel = i end end
  self.cards = {}
  self.row, self.gameSel = ROW_CARDS, nil
  self.t = 0
  self.check = true
  self.frame = gfx.image.new(400, 240, gfx.kColorWhite)
end

function Week:resume()
  self.stale = true
  self.check = true
  -- (a game's mode may have changed in the Office, or a day gone by)
  self.strip = nil
  self.frameDirty = true
  if not Sfx.currentMusic() then Sfx.music("ragtime", { loop = true, fade = 1 }) end
end

--- (old hub API) force a rebuild
function Week:render() self.stale = true end

function Week:goBack()
  Dialog.show({ title = "Leave Pennant?", body = "Your career is saved every day.", buttons = { "Save & quit", "Stay" }, cancel = 2, icon = "?",
    onChoose = function(i) if i == 1 then
      PJobs.flush()
      PUI.busy("Saving", function() PSave.saveNow(Pennant.L, Pennant.L.slot) end)
      playdate.frameTimer.performAfterDelay(4, function() Pennant.quit() end)
    end end })
end

function Week:stamp()
  local L = L_()
  local T = L.teams[L.user]
  local c = L.club
  local f = {}
  for _, k in ipairs(PWeek.PROGS) do f[#f + 1] = c.fac[k] .. ":" .. (c.fxp[k] or 0) end
  local own = 0
  for _ in pairs(c.own) do own = own + 1 end
  return table.concat({ L.season, L.day, L.phase, L.dayCount or 0, #L.news, table.concat(T.order or {}, ","), #T.ml, #T.farm,
    table.concat(f, ","), own, tostring(c.goal and c.goal.state), tostring(c.noRest), tostring(c.wk and c.wk.w), PWeek.energy(L), tostring(c.goal and c.goal.text) }, "|")
end

-- Pending business on arrival: a finished week's report, a goal's reward, the month's goals.
function Week:pending()
  local L = L_()
  local c = L.club
  if c.wk and PWeek.weekDone(L) then
    PennantUI.weekEnd()
    return true
  end
  -- the legacy (pennant/legacy.lua): run 1's alumni card, Opening Day's sparks, an inspiration
  local R = L.run
  if R and PennantUI.Inspire then
    if R.intro then PennantUI.Inspire.open({ mode = "intro" }) return true end
    if R.showOD and R.od then PennantUI.Inspire.open({ mode = "opening" }) return true end
    local i = PLegacy.unseenInsp(L)
    if i then PennantUI.Inspire.open({ mode = "insp", i = i }) return true end
  end
  if c.rewards and #c.rewards > 0 then PennantUI.Goals.open({ reward = true }) return true end
  if c.monthNote then PennantUI.Goals.open({ note = true }) return true end
  if c.goalOffer then PennantUI.Goals.open({ pick = true }) return true end
  return false
end

-- Data ---------------------------------------------------------------------------------------------

function Week:rebuild()
  local t0 = playdate.getCurrentTimeMilliseconds()
  self:rebuildInner()
  if PUI.PROF then print(string.format("[pnweek] rebuild %d ms", playdate.getCurrentTimeMilliseconds() - t0)) end
end

function Week:rebuildInner()
  local L = L_()
  local c = PWeek.ensure(L)
  self.builtStamp = self:stamp()
  self.sp = PWeek.span(L)
  self.units = PWeek.units(L, L.user, true)
  self.energy = PWeek.energy(L)
  self.pips, self.moodWord = PWeek.mood(L)
  -- tired regulars (pennant/rest.lua): the chip on THE CLUB
  self.tired = (not self.sp.over and L.phase ~= "awards") and PRest.count(L) or 0
  if self.tired == 0 and self.row == ROW_TIRED then self.row = ROW_CARDS end
  self.prev = {}
  self.cards = {}
  self.detail = {}
  self.intImg = {}
  self.base = self:paintBase()
  self.strip = nil
  self.frameDirty = true
  -- a Rally Week ready: its card's alumni flash
  self.rally = PLegacy and PLegacy.rallyAny(L) or false
end

function Week:preview(prog, int)
  self.prev[int] = self.prev[int] or {}
  local p = self.prev[int][prog]
  if not p then
    p = PWeek.preview(L_(), prog, int)
    self.prev[int][prog] = p
  end
  return p
end

-- Painting --------------------------------------------------------------------------------------------

local function blackBar(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x, y, w, h)
end

local function bar(x, y, w, h, frac, pat)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  local fw = floor((w - 2) * math.max(0, math.min(1, frac)) + 0.5)
  if fw > 0 then
    if pat then gfx.setPattern(UI.pat[pat]) end
    gfx.fillRect(x + 1, y + 1, fw, h - 2)
    gfx.setColor(gfx.kColorBlack)
  end
end
PennantUI.weekBar = bar

--- The top bar: left / center / right (white on black).
function PennantUI.weekTop(left, center, right)
  blackBar(0, 0, 400, 18)
  local ty = Text.boxY(F().bold, 0, 18)
  local lw = Text.draw(left, 5, ty, F().bold, "white")
  local rw = right and F().body:getTextWidth(right) or 0
  if right then Text.draw(right, 395, ty, F().body, "white", "right") end
  if center then
    local room = 390 - lw - rw - 24
    local s = Text.ellipsize(center, F().body, room)
    local cx = 200
    local sw = F().body:getTextWidth(s)
    if cx - sw // 2 < lw + 14 then cx = lw + 14 + sw // 2 end
    if cx + sw // 2 > 395 - rw - 10 then cx = 395 - rw - 10 - sw // 2 end
    Text.draw(s, cx, ty, F().body, "white", "center")
  end
end

function Week:topLine()
  local L = L_()
  local T = L.teams[L.user]
  local sp = self.sp
  local left
  if sp.po then
    local s = sp.series
    left = s and (s.final and "THE PENNANT SERIES" or "PLAYOFFS \u{2022} SEMIFINAL") or "THE PLAYOFFS"
  elseif sp.over then left = "SEASON OVER"
  else left = "WEEK " .. sp.w .. " / " .. sp.n .. (PWeek.isCamp(L, sp.w) and " \u{2022} ALL-STAR CAMP" or "") end
  local center = PennantClubs.byAbbr[L.user].city:upper() .. " " .. T.w .. "-" .. T.l .. " \u{2022} " .. PUI.ord(PL.rank(L, L.user)):upper()
  if sp.po and sp.series then
    local s = sp.series
    local mine = s.hi == L.user and 1 or 2
    center = PennantClubs.byAbbr[L.user].city:upper() .. " " .. s.w[mine] .. "-" .. s.w[3 - mine] .. " vs " .. (s.hi == L.user and s.lo or s.hi)
  end
  return left, center, PL.date(L, math.min(L.day, #L.sched)):upper()
end

--- The goal ribbon (also on the report and the plan screens).
function PennantUI.goalRibbon(L, x, y, w)
  local c = L.club
  local g = c.goal
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, 16)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, 16)
  if not g then
    local last = c.goals[#c.goals]
    local s = last and (PWeek.MONTH[last.m] .. " GOAL " .. (last.state == "done" and "CLEARED" or "MISSED") .. ": " .. last.text) or "NO GOAL THIS MONTH"
    Text.draw(Text.ellipsize(s, F().body, w - 8), x + 4, Text.boxY(F().body, y, 16, s), F().body)
    return
  end
  local chip = PWeek.MONTH[g.m] .. " GOAL"
  local cw = F().bold:getTextWidth(chip) + 8
  gfx.fillRect(x, y, cw, 16)
  Text.draw(chip, x + 4, Text.boxY(F().bold, y, 16), F().bold, "white")
  local prog, frac = PWeek.goalProgress(L, g)
  local pw = F().bold:getTextWidth(prog)
  local bw = 56
  local bx = x + w - 6 - pw - 6 - bw
  if g.state == "done" then
    local s = "CLEARED"
    Text.draw(s, x + w - 5, Text.boxY(F().bold, y, 16), F().bold, nil, "right")
    bx = x + w - 6 - F().bold:getTextWidth(s) - 6 - bw
    frac = 1
  else
    Text.draw(prog, x + w - 5, Text.boxY(F().bold, y, 16), F().bold, nil, "right")
  end
  bar(bx, y + 5, bw, 7, frac, "gray")
  local s = Text.ellipsize(g.text, F().body, bx - (x + cw) - 10)
  Text.draw(s, x + cw + 5, Text.boxY(F().body, y, 16, s), F().body)
end

function Week:paintLeft()
  local L = L_()
  local x, w = 4, 92
  Text.draw("ENERGY", x, 40, F().bold)
  Text.draw(tostring(self.energy), x + w, 40, F().bold, nil, "right")
  bar(x, 55, w, 9, self.energy / 100, "gray")
  gfx.fillRect(x + w // 2, 53, 1, 13)
  Text.draw("MOOD", x, 68, F().bold)
  Text.draw(self.moodWord, x + w, 68, F().body, nil, "right")
  for i = 1, 5 do
    local px = x + (i - 1) * 19
    if i <= self.pips then gfx.fillRect(px, 83, 16, 7) else gfx.drawRect(px, 83, 16, 7) end
  end
  -- THE CLUB
  local by = 95
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, by, w, 101)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, by, w, 101)
  gfx.fillRect(x, by, w, 14)
  if (self.tired or 0) > 0 then
    -- the TIRED chip (white on the black header): up from the cards, A opens the swap list
    Text.draw("CLUB", x + 4, Text.boxY(F().bold, by, 14), F().bold, "white")
    local s = self.tired .. " TIRED"
    local cw = F().bold:getTextWidth(s) + 6
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x + w - 2 - cw, by + 1, cw, 12)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(s, x + w - 2 - cw // 2, Text.boxY(F().bold, by + 1, 12, s), F().bold, nil, "center")
  else
    Text.draw("THE CLUB", x + 4, Text.boxY(F().bold, by, 14), F().bold, "white")
  end
  local y = by + 17
  for _, k in ipairs(PWeek.UNITS) do
    local v = self.units[k]
    local name = PWeek.UNIT_NAME[k]
    if F().body:getTextWidth(name) > 50 then name = PWeek.UNIT_SHORT[k] end
    Text.draw(name, x + 4, y, F().body)
    if v > 0 then
      Text.draw(tostring(floor(v + 0.5)), x + 69, y, F().bold, nil, "right")
      PUI.grade(x + 74, y, floor(v + 0.5))
    else
      Text.draw("-", x + 69, y, F().body, nil, "right")
    end
    y = y + 14
  end
end

--- THIS WEEK: the days of the week (or the series) as chips.
function Week:days()
  local L = L_()
  local c = L.club
  local sp = self.sp
  local out = {}
  local feat = PWeek.featuredDay(L)
  local po = sp.po
  local function chip(d)
    local day = L.sched[d]
    if not day then return end
    if day.off then out[#out + 1] = { d = d, t = "OFF", off = true } return end
    local g = PL.gameFor(L, L.user, d)
    if not g then return end
    local home = g.h == L.user
    local opp = home and g.a or g.h
    local e = { d = d, t = (home and "" or "@") .. opp, feat = not po and d == feat }
    e.mode, e.why = PWeek.modeFor(L, d, feat or false)
    if g.done then
      local me, them = home and g.hs or g.as, home and g.as or g.hs
      e.t = (me > them and "W " or "L ") .. me .. "-" .. them
      e.won = me > them
      e.done = true
    end
    out[#out + 1] = e
  end
  if sp.po then
    local s = sp.series
    for d = math.max(1, (L.regEnd or L.regDays or 1) + 1), L.day do
      local g = PL.gameFor(L, L.user, d)
      if g and s and ((g.h == s.hi and g.a == s.lo) or (g.h == s.lo and g.a == s.hi)) then chip(d) end
    end
  elseif sp.d0 then
    for d = sp.d0, sp.d1 do chip(d) end
  end
  while #out > 7 do table.remove(out, 1) end
  return out
end

--- The games strip, cached (rebuilt when a mode or the focus changes): the week's days as chips,
--- each with its mode glyph; the focused chip (the strip row) is inverted.
function Week:stripImg()
  if self.strip then return self.strip end
  local list = self:days()
  self.chips = list
  local img = self.stripCanvas or gfx.image.new(400, STRIP_H + 6, gfx.kColorClear)
  self.stripCanvas = img
  img:clear(gfx.kColorClear)
  gfx.pushContext(img)
  local y, h = 5, STRIP_H
  local n = math.max(7, #list)
  local w = (392 - (n - 1) * 3) // n
  local focus = self.row == ROW_GAMES and self.gameSel
  for i, e in ipairs(list) do
    local x = 4 + (i - 1) * (w + 3)
    local today = e.d == L_().day
    local on = focus == e.d
    if e.off then
      gfx.setPattern(UI.pat.light) gfx.fillRect(x, y, w, h) gfx.setColor(gfx.kColorBlack)
      gfx.drawRect(x, y, w, h)
    elseif e.won or on then
      gfx.fillRect(x, y, w, h)
    else
      gfx.setColor(gfx.kColorWhite) gfx.fillRect(x, y, w, h) gfx.setColor(gfx.kColorBlack)
      gfx.drawRect(x, y, w, h)
    end
    if e.feat and not e.done then
      if on then gfx.setColor(gfx.kColorWhite) end
      gfx.setLineWidth(2) gfx.drawRect(x + 1, y + 1, w - 2, h - 2) gfx.setLineWidth(1)
      gfx.setColor(gfx.kColorBlack)
    end
    local white = e.won or on
    local f = F().bold
    local gl = not e.done and not e.off and PennantUI.modeGlyph(e.mode, white)
    local room = w - 4 - (gl and 16 or 0)
    local s = e.t
    if e.feat and not e.done and f:getTextWidth(s .. "\u{2605}") <= room then s = s .. "\u{2605}" end
    s = Text.ellipsize(s, f, room)
    if gl then
      local tw = f:getTextWidth(s)
      local x0 = x + (w - tw - 16) // 2
      Text.draw(s, x0, Text.boxY(f, y, h, s), f, white and "white" or nil)
      gl:draw(x0 + tw + 2, y + (h - 11) // 2)
    else
      Text.draw(s, x + w // 2, Text.boxY(f, y, h, s), f, white and "white" or nil, "center")
    end
    if today and not e.done then gfx.fillTriangle(x + w // 2 - 4, y - 4, x + w // 2 + 4, y - 4, x + w // 2, y) end
  end
  if #list == 0 then Text.draw("No games this week.", 8, y + 3, F().body) end
  gfx.popContext()
  self.strip = img
  return img
end

--- The days on the strip that can take a mode (games not played yet).
function Week:openDays()
  self:stripImg()
  local out = {}
  for _, e in ipairs(self.chips or {}) do if not e.off and not e.done then out[#out + 1] = e end end
  return out
end

function Week:paintBase()
  local L = L_()
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  PennantUI.weekTop(self:topLine())
  PennantUI.goalRibbon(L, 4, 20, 392)
  self:paintLeft()
  if L.phase == "awards" or self.sp.over then self:paintOver()
  else
    if L.phase == "playoffs" and not self.sp.series then self:paintOut() end
  end
  gfx.popContext()
  return img
end

--- After the season: the champion, and the way on.
function Week:paintOver()
  local L = L_()
  local x, y, w, h = CX0, CY, 292, 156
  gfx.drawRect(x, y, w, h)
  gfx.fillRect(x, y, w, 16)
  Text.draw("SEASON OVER", x + 5, Text.boxY(F().bold, y, 16), F().bold, "white")
  if L.champ then
    PUI.logo(L.champ, x + 8, y + 24, 32)
    Text.draw(Text.ellipsize(PUI.teamName(L.champ), F().bold, w - 56), x + 48, y + 24, F().bold)
    Text.draw("win the " .. L.year .. " pennant.", x + 48, y + 38, F().body)
  end
  local T = L.teams[L.user]
  Text.draw("You finished " .. T.w .. "-" .. T.l .. ", " .. PUI.ord(PL.rank(L, L.user)) .. ".", x + 8, y + 68, F().body)
  local done = 0
  for _, g in ipairs(L.club.goals) do if g.state == "done" then done = done + 1 end end
  Text.draw("Goals cleared: " .. done .. " of " .. #L.club.goals .. ".", x + 8, y + 84, F().body)
  Text.draw("A: awards night, then the winter.", x + 8, y + 116, F().bold)
end

--- The playoffs without you.
function Week:paintOut()
  local x, y, w, h = CX0, CY, 292, 156
  gfx.drawRect(x, y, w, h)
  gfx.fillRect(x, y, w, 16)
  Text.draw("THE PLAYOFFS", x + 5, Text.boxY(F().bold, y, 16), F().bold, "white")
  Text.block("Your season is over. The top four play on; the programs keep running for next year.", x + 8, y + 24, w - 16, F().body, nil, 4)
  Text.draw("A: sim the playoffs.", x + 8, y + 116, F().bold)
end

-- program icons (1-bit, in a 47 x 25 box)
local function icon(prog, x, y)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(3)
  if prog == "bat" then
    gfx.drawLine(x + 8, y + 20, x + 30, y + 6)
    gfx.fillCircleAtPoint(x + 37, y + 8, 4)
  elseif prog == "arms" then
    gfx.setLineWidth(2)
    gfx.drawCircleAtPoint(x + 23, y + 12, 9)
    gfx.drawArc(x + 13, y + 12, 6, 50, 130)
    gfx.drawArc(x + 33, y + 12, 6, 230, 310)
  elseif prog == "def" then
    gfx.setLineWidth(2)
    gfx.drawPolygon(x + 23, y + 3, x + 33, y + 13, x + 23, y + 23, x + 13, y + 13, x + 23, y + 3)
    gfx.fillRect(x + 21, y + 11, 4, 4)
  elseif prog == "gym" then
    gfx.drawLine(x + 8, y + 12, x + 38, y + 12)
    gfx.fillRect(x + 8, y + 5, 4, 15)
    gfx.fillRect(x + 13, y + 7, 3, 11)
    gfx.fillRect(x + 30, y + 7, 3, 11)
    gfx.fillRect(x + 34, y + 5, 4, 15)
  elseif prog == "farm" then
    gfx.setLineWidth(2)
    gfx.drawPolygon(x + 11, y + 22, x + 11, y + 11, x + 23, y + 4, x + 35, y + 11, x + 35, y + 22, x + 11, y + 22)
    gfx.drawRect(x + 19, y + 15, 8, 7)
  end
  gfx.setLineWidth(1)
end

local function signed(v, dec)
  if dec then
    local s = string.format("%.1f", v)
    return (v >= 0 and "+" or "") .. s
  end
  return (v > 0 and "+" or "") .. tostring(v)
end

--- One program card (cached by prog / intensity / selected).
function Week:card(prog, int, on)
  local key = prog .. int .. (on and "s" or "") .. PWeek.withKey(L_(), prog)
  local img = self.cards[key]
  if img then return img end
  local L = L_()
  local c = L.club
  local pv = self:preview(prog, int)
  img = gfx.image.new(CW + 3, CH + 3, gfx.kColorClear)
  gfx.pushContext(img)
  if on then gfx.setPattern(UI.pat.gray) gfx.fillRect(3, 3, CW, CH) gfx.setColor(gfx.kColorBlack) end
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 0, CW, CH)
  gfx.setColor(gfx.kColorBlack)
  if on then gfx.setLineWidth(2) gfx.drawRect(1, 1, CW - 2, CH - 2) gfx.setLineWidth(1) else gfx.drawRect(0, 0, CW, CH) end
  gfx.fillRect(0, 0, CW, 15)
  local name = PWeek.PROG[prog].name
  local nf = F().bold:getTextWidth(name) <= CW - 4 and F().bold or F().body
  Text.draw(name, CW // 2, Text.boxY(nf, 0, 15), nf, "white", "center")
  -- the icon box (and the future "with" slot)
  gfx.setPattern(UI.pat.lighter)
  gfx.fillRect(4, 18, CW - 8, 21)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(4, 18, CW - 8, 21)
  icon(prog, 4, 16)
  local with = PWeek.withSlot(L, prog)
  if with and with.draw then with.draw(4, 18, CW - 8, 21) end
  -- what it moves this week
  local y = 41
  local n = 0
  for _, e in ipairs(pv.fx) do
    if n >= 2 then break end
    local nm = PWeek.UNIT_SHORT[e[1]]
    Text.draw(nm, 3, y, F().body)
    Text.draw(signed(e[2], true), CW - 3, y, F().bold, nil, "right")
    y = y + 12
    n = n + 1
  end
  if n == 0 then Text.draw("-", 3, y, F().body) y = y + 12 end
  y = 65
  local en = "ENERGY"
  local ev = signed(pv.energy)
  if F().body:getTextWidth(en) + F().bold:getTextWidth(ev) > CW - 7 then en = "NRG" end
  Text.draw(en, 3, y, F().body)
  Text.draw(ev, CW - 3, y, F().bold, nil, "right")
  -- the facility
  Draw.dotted(3, CW - 3, 79)
  local lv = c.fac[prog]
  Text.draw("LV" .. lv, 3, 80, F().bold)
  local frac = PWeek.facProgress(L, prog)
  bar(26, 84, CW - 29, 5, frac)
  -- the chance it fails (energy below 50)
  local fp = pv.fail or 0
  if fp >= 10 then gfx.setPattern(fp >= 20 and UI.pat.gray or UI.pat.light) gfx.fillRect(0, CH - 14, CW, 14) gfx.setColor(gfx.kColorBlack) end
  gfx.drawLine(0, CH - 14, CW - 1, CH - 14)
  local rs = fp > 0 and ("FAIL " .. fp .. "%") or "SAFE"
  local rf = fp >= 20 and F().bold or F().body
  if rf:getTextWidth(rs) > CW - 4 then rs = fp .. "%" end
  if fp >= 20 then
    local tw = rf:getTextWidth(rs) + 6
    gfx.setColor(gfx.kColorWhite) gfx.fillRect(CW // 2 - tw // 2, CH - 12, tw, 11) gfx.setColor(gfx.kColorBlack)
  end
  Text.draw(rs, CW // 2, Text.boxY(rf, CH - 14, 14, rs), rf, nil, "center")
  gfx.popContext()
  self.cards[key] = img
  return img
end

--- The line under the cards: what the selected program does.
local DESC <const> = {
  bat = "Hitters: contact, power, eye, weakest first.",
  arms = "Pitchers: velocity, control, a pitch; starters stamina.",
  def = "Hitters: fielding and arm. Easier on energy.",
  gym = "Everybody lifts: power, stamina. The priciest.",
  farm = "The farm club works; the big club gets a breather.",
  rest = "Everybody rests: fatigue melts, arrows rise. No gains.",
}
function Week:detailImg(prog, int)
  local key = prog .. int
  if self.detail[key] then return self.detail[key] end
  local L = L_()
  local img = gfx.image.new(293, 14, gfx.kColorWhite)
  gfx.pushContext(img)
  local s = DESC[prog]
  if prog ~= "rest" then
    local pv = self:preview(prog, int)
    s = s .. string.format("  +%.1f a player", pv.per or 0)
    -- the alumni here this week (pennant/legacy.lua)
    local mm = PWeek.mentorMods(L, prog)
    if mm then
      local x = PWeek.gainMult(mm)
      s = (mm[2] and "\u{2605} RALLY WEEK" or mm[1].label) .. string.format(" x%.2f: ", x) .. s
    end
  end
  s = Text.ellipsize(s, F().body, 292)
  Text.draw(s, 0, Text.boxY(F().body, 0, 14, s), F().body)
  gfx.popContext()
  self.detail[key] = img
  return img
end

local INT_LINE <const> = {
  "LIGHT: gains x0.6, energy cost low, half the fail risk",
  "NORMAL: gains x1. Under 50 energy, it can fail",
  "HARD: gains x1.6, energy cost x1.7, fail risk +8%",
}

--- The intensity row and REST WEEK (cached by state).
function Week:intensityImg(int, rest)
  local key = int .. tostring(rest)
  if self.intImg[key] then return self.intImg[key] end
  local L = L_()
  local img = gfx.image.new(293, 34, gfx.kColorWhite)
  gfx.pushContext(img)
  for i = 1, 3 do
    local x = (i - 1) * 58
    local on = i == int and not rest
    if on then gfx.fillRect(x, 0, 56, 17) else gfx.drawRect(x, 0, 56, 17) end
    if i == int and rest then gfx.setPattern(UI.pat.light) gfx.fillRect(x + 1, 1, 54, 15) gfx.setColor(gfx.kColorBlack) end
    Text.draw(PWeek.INT[i], x + 28, Text.boxY(F().bold, 0, 17), F().bold, on and "white" or nil, "center")
  end
  local rx, rw = 178, 114
  local can = PWeek.canRest(L)
  if rest then
    gfx.setLineWidth(2) gfx.fillRect(rx, 0, rw, 17) gfx.setLineWidth(1)
    Text.draw("REST WEEK", rx + rw // 2, Text.boxY(F().bold, 0, 17), F().bold, "white", "center")
  else
    gfx.drawRect(rx, 0, rw, 17)
    Text.draw("REST WEEK", rx + rw // 2, Text.boxY(F().bold, 0, 17), F().bold, nil, "center")
    if not can then Draw.fade(rx + 1, 1, rw - 2, 15, 0.5, true) gfx.setColor(gfx.kColorBlack) end
  end
  local s
  if rest then
    local pv = self:preview("rest", int)
    s = "+30 TO +60 ENERGY, ARROWS UP, NO GAINS"
  else s = INT_LINE[int] end
  if not can and not rest then s = s .. "  (REST LOCKED)" end
  s = Text.ellipsize(s, F().body, 292)
  Text.draw(s, 0, 19, F().body)
  gfx.popContext()
  self.intImg[key] = img
  return img
end

function Week:hint()
  local L = L_()
  if L.phase == "awards" or self.sp.over then return "A: awards night   B: office" end
  if L.phase == "playoffs" and not self.sp.series then return "A: sim the playoffs   B: office" end
  local verb = (L.club.wk and L.club.wk.w == self.sp.w) and "continue the week" or (self.sp.po and "play the series" or "run the week")
  local tired = (self.tired or 0) > 0 and ("\u{25b2} " .. self.tired .. " tired  ") or ""
  if self.row == ROW_TIRED then
    return "A: rest the tired (" .. self.tired .. ": who sits, who covers)   \u{25bc} back"
  elseif self.row == ROW_GAMES then
    local e = self:focusChip()
    if not e then return "\u{25b2} back  B: office" end
    local nx = PWeek.cycleMode(e.mode, 1)
    return PL.date(L, e.d):upper() .. " " .. e.t .. ": " .. PWeek.MODE_NAME[e.mode] .. "   A: " .. PWeek.MODE_NAME[nx] .. "  \u{25c0}\u{25b6} game  \u{25b2} back"
  elseif self.row == ROW_INT then
    return "\u{25c0}\u{25b6} intensity  \u{25b2}\u{25bc} program / games  A: " .. verb .. "  B: office"
  end
  return tired .. "\u{25c0}\u{25b6} program  \u{25bc} intensity, games  A: " .. verb .. "  B: office"
end

function Week:compose()
  self.frameDirty = false
  local L = L_()
  local c = L.club
  gfx.pushContext(self.frame)
  self.base:draw(0, 0)
  local showCards = not (L.phase == "awards" or self.sp.over or (L.phase == "playoffs" and not self.sp.series))
  if showCards then
    local rest = c.prog == "rest"
    for i, k in ipairs(PWeek.PROGS) do
      local on = i == self.sel
      local x = CX0 + (i - 1) * (CW + CG)
      self:card(k, c.int, on):draw(x, on and CY - 3 or CY)
    end
    self:detailImg(c.prog, c.int):draw(CX0, CY + CH + 3)
    self:intensityImg(c.int, rest):draw(CX0, 166)
    if self.row == ROW_INT then
      -- (the intensity row has the focus: a bracket round the three buttons)
      gfx.drawRect(CX0 - 2, 164, 176, 21)
      gfx.fillTriangle(CX0 - 6, 169, CX0 - 6, 179, CX0 - 3, 174)
    end
  end
  if not (L.phase == "awards" or self.sp.over) then self:stripImg():draw(0, STRIP_Y - 5) end
  if self.row == ROW_TIRED then
    -- (the TIRED chip has the focus: a bracket round THE CLUB's header)
    gfx.setLineWidth(2)
    gfx.drawRect(2, 93, 96, 18)
    gfx.setLineWidth(1)
    gfx.fillTriangle(103, 97, 103, 107, 100, 102)
  end
  PUI.hintBar(self:hint())
  gfx.popContext()
end

function Week:update(covered)
  local L = L_()
  if not L then return end
  if not covered then PJobs.tick(10) end
  -- (the stamp is checked only on coming back to the screen: no per-frame string building)
  if self.stale or not self.base then
    self.stale = false
    if not self.base or self:stamp() ~= self.builtStamp then self:rebuild() end
  end
  if self.frameDirty then
    local t0 = playdate.getCurrentTimeMilliseconds()
    self:compose()
    local d = playdate.getCurrentTimeMilliseconds() - t0
    if PUI.PROF and d > 15 then print(string.format("[pnweek] compose %d ms", d)) end
  end
  self.frame:draw(0, 0)
  if covered then return end
  self.t = self.t + 1
  if self.rally and self.t % 15 == 0 and PLegacy then
    PLegacy.flash = 1 - (PLegacy.flash or 0)
    self.frameDirty = true
  end
  if self.check and self.t > 1 then
    self.check = false
    if self:pending() then return end
  end
  -- idle: build the other intensities' cards a card a frame (so ▲▼ never waits on text)
  if self.t > 10 and not self.prewarmed then
    local c = L.club
    for int = 1, 3 do
      for i, k in ipairs(PWeek.PROGS) do
        for _, on in ipairs({ false, true }) do
          if not self.cards[k .. int .. (on and "s" or "") .. PWeek.withKey(L, k)] then self:card(k, int, on) return end
        end
      end
    end
    self.prewarmed = true
  end
end

-- Input -------------------------------------------------------------------------------------------------

function Week:select(i)
  local L = L_()
  local c = L.club
  if L.phase == "awards" then return end
  i = math.max(1, math.min(SEL_REST, i))
  if i == SEL_REST and not PWeek.canRest(L) then Toast.show("No rest week yet: the charter flight.", "bad") return end
  if i == self.sel then return end
  self.sel = i
  c.prog = i == SEL_REST and "rest" or PWeek.PROGS[i]
  Sfx.focus()
  self.frameDirty = true
end

function Week:setInt(d)
  local L = L_()
  local c = L.club
  if L.phase == "awards" or c.prog == "rest" then return end
  local n = math.max(1, math.min(3, c.int + d))
  if n == c.int then return end
  c.int = n
  Sfx.tick()
  self.frameDirty = true
end

--- The chip the games row is on (nil: none open).
function Week:focusChip()
  for _, e in ipairs(self:openDays()) do if e.d == self.gameSel then return e end end
  return nil
end

--- Move between the focus rows: the cards, the intensity (not on a REST WEEK), the games strip.
function Week:setRow(r)
  local L = L_()
  if L.phase == "awards" or self.sp.over then return end
  local cards = not (L.phase == "playoffs" and not self.sp.series)
  if not cards then return end
  local dir = r > self.row and 1 or -1
  if r == ROW_INT and L.club.prog == "rest" then r = r + dir end
  if r == ROW_TIRED and (self.tired or 0) > 0 then
    self.row = ROW_TIRED
    Sfx.focus()
    self.frameDirty = true
    return
  end
  if r < ROW_CARDS or r > ROW_GAMES then return end
  if r == ROW_GAMES then
    local open = self:openDays()
    if #open == 0 then
      if self.row == ROW_INT or L.club.prog == "rest" then return end
      r = ROW_INT
    elseif not self:focusChip() then
      -- (the featured game first, else the first one left)
      self.gameSel = open[1].d
      for _, e in ipairs(open) do if e.feat then self.gameSel = e.d end end
    end
  end
  if r == self.row then return end
  self.row = r
  self.strip = nil
  Sfx.focus()
  self.frameDirty = true
end

function Week:moveGame(dir)
  local open = self:openDays()
  local k
  for i, e in ipairs(open) do if e.d == self.gameSel then k = i end end
  if not k then return end
  local n = k + dir
  if n < 1 or n > #open then return end
  self.gameSel = open[n].d
  self.strip = nil
  Sfx.focus()
  self.frameDirty = true
end

function Week:cycleGame(dir)
  local e = self:focusChip()
  if not e then return end
  local m = PWeek.cycleMode(e.mode, dir or 1)
  PWeek.setMode(L_(), e.d, m)
  self.strip = nil
  Sfx.tick()
  self.frameDirty = true
end

function Week:leftButtonDown()
  if self.row == ROW_TIRED then return end
  if self.row == ROW_GAMES then self:moveGame(-1)
  elseif self.row == ROW_INT then self:setInt(-1)
  else self:select(self.sel - 1) end
end
function Week:rightButtonDown()
  if self.row == ROW_TIRED then return end
  if self.row == ROW_GAMES then self:moveGame(1)
  elseif self.row == ROW_INT then self:setInt(1)
  else self:select(self.sel + 1) end
end
--- (the tour's navcheck) The focus rows: left/right moves along each one (selecting a card or an
--- intensity is choosing it); no item on them takes left/right for a value of its own (A cycles a game).
function Week:navItems()
  local out = {}
  for i, k in ipairs(PWeek.PROGS) do out[#out + 1] = { id = "card:" .. k, row = ROW_CARDS } end
  for _, k in ipairs({ "light", "normal", "hard", "rest" }) do out[#out + 1] = { id = "int:" .. k, row = ROW_INT } end
  for _, e in ipairs(self:openDays()) do out[#out + 1] = { id = "game:" .. e.d, row = ROW_GAMES } end
  return out
end
Week.navName = "Week"

function Week:upButtonDown() self:setRow(self.row - 1) end
function Week:downButtonDown() self:setRow(self.row + 1) end

function Week:AButtonDown()
  if self.row == ROW_GAMES and self:focusChip() then self:cycleGame(1) return end
  if self.row == ROW_TIRED then
    Sfx.select()
    PennantUI.RestTired.open({ onDone = function() self.base = nil self.stale = true end })
    return
  end
  Sfx.select()
  PennantUI.runWeek()
end

function Week:BButtonDown()
  Sfx.select()
  PennantUI.Office.open({})
end

-- The run ----------------------------------------------------------------------------------------------

--- A: the week runs: the series plan (a key series), leaving town (the globe), then the days.
function PennantUI.runWeek()
  local L = Pennant.L
  local c = PWeek.ensure(L)
  if L.phase == "awards" then PennantUI.Awards.open({}) return end
  if L.phase == "playoffs" and not PWeek.userSeries(L) then
    PennantUI.Advance.open({ untilPhase = "awards", week = true })
    return
  end
  PWeek.beginWeek(L)
  local function go()
    -- leaving town: the globe, one leg, as an interstitial
    local ng, nd = PL.nextGame(L, L.user)
    local from = PennantUI.cityOn(L, L.day - 1)
    local to = ng and ng.h
    if to and from ~= to and nd == L.day and L.settings.travel ~= false then
      local lm = L.settings.landmarks ~= false and PLand.maybe(L, from, to) or nil
      PennantUI.Travel.open({ from = from, to = to, landmark = lm, quick = true, onDone = function()
        PennantUI.Advance.open({ week = true, skipTravel = L.day })
      end })
    else
      PennantUI.Advance.open({ week = true, skipTravel = L.day })
    end
  end
  local ks = PWeek.keySeries(L)
  if ks and not (c.plan and c.plan.opp == ks.opp and c.plan.key) and not c.planSkip then
    PennantUI.SeriesPlan.open({ stub = ks, onDone = function(ok)
      if ok then
        -- the featured game follows the plan (if the week hasn't started)
        local d = PWeek.pickFeatured(L)
        if c.feat and (c.feat.d or 0) >= L.day then c.feat.d = d end
        go()
      end
    end })
    return
  end
  go()
end

--- The week is over: its report, the month's goals, then home.
function PennantUI.weekEnd()
  local L = Pennant.L
  local rep = PWeek.endWeek(L)
  Pennant.toHub()
  if not rep then return end
  PennantUI.WeekReport.open({ rep = rep, onDone = function()
    Pennant.toHub()
    local c = L.club
    if (c.rewards and #c.rewards > 0) then PennantUI.Goals.open({ reward = true }) return end
    if c.monthNote then PennantUI.Goals.open({ note = true }) return end
    if c.goalOffer then PennantUI.Goals.open({ pick = true }) end
  end })
end

-- The Office ---------------------------------------------------------------------------------------------

local Office = PUI.define({ title = "Office", hint = "A: open  B: back to the week" })
PennantUI.Office = Office

function Office:resume(r) Page.resume(self, r) self:render(true) end

function Office:layout(Lb)
  local L = Pennant.L
  local c = L.club
  local all = PWeek.allMode(L)
  local function cycleAll(d)
    L.settings.allGames = PWeek.cycleMode(all, d)
    if L.settings.allGames == "sim" then L.settings.allGames = nil end
  end
  local items = {
    { "This week's games", "How each game this week is played: sim, watch, bat, pitch or both", function() PennantUI.ThisWeek.open({}) end },
    { "Every game: " .. PWeek.MODE_NAME[all],
      all == "sim" and "A: change. Default for every game: SIM (only the \u{2605} game and the playoffs live)"
        or ("A: change. Default for every game: " .. PWeek.MODE_NAME[all] .. " (" .. PWeek.MODE_DESC[all] .. ")"),
      function() cycleAll(1) Sfx.tick() self:render(true) end },
    { "Season goals", "The month-by-month goals and what's next", function() PennantUI.Goals.open({}) end },
    { "Team", "Roster, player cards, condition", function() PennantUI.Team.open({}) end },
    { "Lineup", "Batting order, positions, rotation, bullpen (the coaches set it otherwise)", function() PennantUI.Lineup.open({}) end },
    { "Individual training", "Give a player his own plan; the program leaves him be", function() PennantUI.Training.open({}) end },
    { "Moves", "The farm (call-ups) and trades", function() PennantUI.Farm.open({}) end },
    { "League", "Standings, results, leaders, history", function() PennantUI.League.open({}) end },
    { "Last week's report", "The last week, unit by unit", function()
      if c.lastRep then PennantUI.WeekReport.open({ rep = c.lastRep, review = true }) else Toast.show("No week played yet.", nil) end end },
    { "Road map", "The season's road trips on the globe", function() PennantUI.RoadMap.open({}) end },
    { "Legacy & alumni", "This run's legacies, the season's cap, the deck's bonds", function() PennantUI.LegacyInfo.open({}) end },
    { "Hall of Fame", "The All-Time Lineup from every run's alumni", function() PennantUI.HallOfFame.open({}) end },
    { "Options", "Controls, travel animation, call-ups, save", function() PennantUI.Hub.optionsMenu() end },
    { "Save & quit", "Leave Pennant (it saves every day anyway)", function() Pennant.hub:goBack() end },
  }
  local y = 6
  for i, it in ipairs(items) do
    local col = (i - 1) % 2
    local row = (i - 1) // 2
    local x = 6 + col * 194
    local yy = y + row * 30
    -- (a grid: left/right always moves between the buttons; "Every game" changes with A)
    Lb:button(it[1], x, yy, 186, 24, it[3], { id = "o" .. i, hint = it[2] })
  end
  local own = 0
  for _ in pairs(c.own) do own = own + 1 end
  local yy = y + ((#items + 1) // 2) * 30
  if own > 0 then
    Lb:button("Back to the program (" .. own .. ")", 6, yy, 186, 18, function() PWeek.clearOwn(L) PWeek.applyPlans(L) Toast.show("Everyone is on the club program again.", nil) self:render(true) end,
      { id = "clearown", hint = own .. " players have their own training plan. A: put them back on the program" })
  end
  Lb:mark(yy + 20)
end

-- This week's games: how each one is played ---------------------------------------------------------------

local ThisWeek = PUI.define({ title = "This week's games", hint = "A / \u{25c0}\u{25b6}: SIM, WATCH, BAT, PITCH, BAT+PITCH" })
PennantUI.ThisWeek = ThisWeek

function ThisWeek:layout(Lb)
  local L = Pennant.L
  local sp = PWeek.span(L)
  local y = 4
  Text.block("Every game can be played live: the run stops for each one that isn't SIM. The default is set in the Office (Every game); the starred game is the week's big one.", 6, y, 386, UI.fonts.body, nil, 3)
  y = y + 44
  local feat = not sp.po and PWeek.featuredDay(L) or false
  local d0, d1 = L.day, sp.d1 or L.day
  if sp.po then d1 = L.day end
  local any = false
  for d = d0, d1 do
    local g = PL.gameFor(L, L.user, d)
    if g and not g.done then
      any = true
      local home = g.h == L.user
      local opp = home and g.a or g.h
      local isFeat = d == feat
      local mode = PWeek.modeFor(L, d, feat)
      local live = mode ~= "sim"
      local label = PL.date(L, d) .. "   " .. (home and "vs " or "at ") .. PUI.teamName(opp) .. (isFeat and "  \u{2605}" or "")
      local yy = y
      gfx.setColor(gfx.kColorWhite) gfx.fillRect(6, yy, 386, 20) gfx.setColor(gfx.kColorBlack)
      gfx.drawRect(6, yy, 386, 20)
      Text.draw(Text.ellipsize(label, UI.fonts.bold, 260), 12, Text.boxY(UI.fonts.bold, yy, 20), UI.fonts.bold)
      local s = PWeek.MODE_NAME[mode]
      if live then gfx.fillRect(280, yy + 3, 108, 14) end
      local gl = PennantUI.modeGlyph(mode, live)
      if gl then gl:draw(284, yy + 4) end
      Text.draw(s, 340, Text.boxY(UI.fonts.bold, yy + 3, 14), UI.fonts.bold, live and "white" or nil, "center")
      local function set(dir)
        PWeek.setMode(L, d, PWeek.cycleMode(PWeek.modeFor(L, d, feat), dir))
      end
      Lb:link(6, yy, 386, 20, function() set(1) Sfx.tick() self:render(true) end,
        { id = "g" .. d, style = "ring", hint = PWeek.MODE_NAME[mode] .. ": " .. PWeek.MODE_DESC[mode] .. ".  A / \u{25c0}\u{25b6}: change", data = { adj = set } })
      y = y + 24
    end
  end
  if not any then Text.draw("No games left this week.", 10, y, UI.fonts.body) y = y + 16 end
  Lb:mark(y + 4)
end
