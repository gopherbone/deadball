--[[ Pennant UI kit: the program's own window chrome (a title bar with the date and record, a hint
  bar at the bottom) around ui/page.lua pages, plus the sports-game widgets: condition arrows,
  mood faces, fatigue meters, grade letters, rating bars, tables, tabs.

  PUI.define(def) -> a Page definition (style "bare") with:
    def.title          screen title (string or function(self))
    def.hint           default hint text for the bottom bar
    links with opts.adj = function(dir) ... end react to left/right (cycle a value in place)
  Everything text-heavy is painted once into the page canvas (Page.render); per frame only the
  canvas blit, the focus ring and the two bars are drawn (the bars are cached images).
]]

local gfx <const> = playdate.graphics

PUI = PUI or {}
-- dev timing logs (slow frames, renders, job steps) with debug.flag in the Data folder
PUI.PROF = playdate.file.exists("debug.flag")
local function nowMs() return playdate.getCurrentTimeMilliseconds() end
PUI.TOP = 18
PUI.BOT = 225
PUI.VIEW_H = PUI.BOT - PUI.TOP

local F = function() return UI.fonts end

-- Chrome ---------------------------------------------------------------------------------------

local barCache = { key = nil, img = nil }
local hintCache = { key = nil, img = nil }

--- The pennant glyph (a little triangular flag on a pole).
function PUI.flag(x, y, white)
  gfx.setColor(white and gfx.kColorWhite or gfx.kColorBlack)
  gfx.drawLine(x, y, x, y + 11)
  gfx.fillTriangle(x + 1, y, x + 11, y + 3, x + 1, y + 6)
  gfx.setColor(gfx.kColorBlack)
end

--- The user's titles, newest first (years), for the masthead pennants.
function PUI.titles()
  local L = Pennant and Pennant.L
  local out = {}
  for i = #((L and L.history) or {}), 1, -1 do
    local h = L.history[i]
    if h.champ == L.user then out[#out + 1] = h.year end
  end
  return out
end

function PUI.topBar(title, right)
  local titles = PUI.titles()
  local key = (title or "") .. "|" .. (right or "") .. "|" .. #titles
  if barCache.key ~= key then
    local img = gfx.image.new(400, PUI.TOP, gfx.kColorBlack)
    gfx.pushContext(img)
    PUI.flag(5, 3, true)
    local w = Text.draw("PENNANT '96", 19, 2, F().bold, "white")
    -- a small pennant per title won, with its year
    for i = 1, math.min(3, #titles) do
      local px = 25 + w
      gfx.setColor(gfx.kColorWhite)
      gfx.fillTriangle(px, 4, px + 9, 7, px, 10)
      local yw = Text.draw("'" .. tostring(titles[i]):sub(-2), px + 10, 2, F().body, "white")
      w = w + 14 + yw
    end
    if #titles > 3 then w = w + 2 + Text.draw("+" .. (#titles - 3), 25 + w, 2, F().body, "white") end
    gfx.setColor(gfx.kColorWhite)
    gfx.drawLine(25 + w, 4, 25 + w, 13)
    if title then Text.draw(Text.ellipsize(title, F().bold, 190), 31 + w, 2, F().bold, "white") end
    if right then Text.draw(right, 395, 2, F().body, "white", "right") end
    gfx.popContext()
    barCache.key, barCache.img = key, img
  end
  barCache.img:draw(0, 0)
end

function PUI.hintBar(text)
  local key = text or ""
  if hintCache.key ~= key then
    local img = gfx.image.new(400, 240 - PUI.BOT, gfx.kColorWhite)
    gfx.pushContext(img)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(0, 0, 399, 0)
    -- (the rule, a clear row, then the line: descenders still fit in the 15 rows)
    Text.draw(Text.ellipsize(key, F().body, 392), 4, 2, F().body)
    gfx.popContext()
    hintCache.key, hintCache.img = key, img
  end
  hintCache.img:draw(0, PUI.BOT)
end

function PUI.rightText()
  local L = Pennant.L
  if not L then return "" end
  local T = L.teams[L.user]
  local phase = L.phase == "playoffs" and "Playoffs" or (L.phase == "season" and (T.w .. "-" .. T.l .. "  " .. PUI.ord(PL.rank(L, L.user))) or "Offseason")
  return PL.date(L, math.min(L.day, #L.sched)) .. "  " .. L.user .. " " .. phase
end

function PUI.ord(n)
  local s = ({ "st", "nd", "rd" })[n] or "th"
  if n >= 11 and n <= 13 then s = "th" end
  return n .. s
end

-- Page definition ---------------------------------------------------------------------------------

local Base = {}

function PUI.define(def)
  def.style = "bare"
  def.swr = false
  def.ownHoldB = true
  if def.scrollSlack == nil then def.scrollSlack = 8 end   -- (Page pads 8 px below the content)
  for k, v in pairs(Base) do if rawget(def, k) == nil then def[k] = v end end
  return Page.define(def)
end

function Base:viewport() return 0, PUI.TOP, 400, PUI.VIEW_H end

function Base:overlay()
  local t = self.title
  if type(t) == "function" then t = t(self) end
  PUI.topBar(t, PUI.rightText())
  local l = self.links[self.focus]
  local hint = (l and l.hint) or (type(self.hint) == "function" and self:hint() or self.hint) or ""
  if Nav.holdB > 4 then hint = "Keep holding B: back to the Pennant menu..." end
  PUI.hintBar(hint)
  -- scrollbar
  if self.scroll.max > 0 then
    local vh = PUI.VIEW_H
    local frac = vh / (self.scroll.max + vh)
    local th = math.max(10, math.floor(vh * frac))
    local ty = PUI.TOP + math.floor((vh - th) * math.max(0, math.min(1, self.scroll.pos / self.scroll.max)))
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(395, PUI.TOP, 5, vh)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(395, PUI.TOP, 395, PUI.BOT - 1)
    gfx.fillRect(396, ty, 4, th)
  end
  if self.after then self:after() end
end

function Base:tick()
  -- background sims / autosave run while menus are idle (well inside the frame budget)
  local t0 = nowMs()
  PJobs.tick(self.jobMs or 12)
  self.profJobs = nowMs() - t0
  if self.dirty then self.dirty = false self:render(true) end
  if self.onTick then self:onTick() end
end

local function adjust(self, dir)
  local l = self.links[self.focus]
  if l and l.data and l.data.adj then
    l.data.adj(dir)
    Sfx.tick()
    if l.data.repaint then l.data.repaint() else self:render(true) end
    return true
  end
  return false
end

--- Repaint one region of a page's canvas in place (a row that changed), instead of the whole
--- page: a full render of a long list costs 100+ ms on the device.
function PUI.repaint(page, x, y, w, h, paint)
  if not page.canvas then page:render(true) return end
  gfx.pushContext(page.canvas)
  gfx.setClipRect(x, y, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  paint()
  gfx.clearClipRect()
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.popContext()
end

--- A list row painted lazily: only when it scrolls into view (a live area), and only a few ms
--- of rows per frame, straight into the page canvas. Long lists (rosters, trade tables, the
--- schedule) then cost a screenful to open instead of every row (text is slow on the device).
--- paint() draws in canvas coordinates. Returns nothing; register links as usual.
function PUI.lazy(Lb, x, y, w, h, paint)
  local done = false
  local page = Lb.page
  Lb:live(x, y, w, h, function(pg)
    if done or not pg.canvas then return end
    local f = Game.frame or 0
    if pg.lazyFrame ~= f then pg.lazyFrame, pg.lazySpent = f, 0 end
    if pg.lazySpent > 10 then pg.dirtyLazy = true return end
    local t0 = playdate.getCurrentTimeMilliseconds()
    gfx.pushContext(pg.canvas)
    gfx.clearClipRect()
    gfx.setColor(gfx.kColorBlack)
    paint()
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    gfx.popContext()
    done = true
    pg.lazySpent = pg.lazySpent + (playdate.getCurrentTimeMilliseconds() - t0)
  end)
  Lb:mark(y + h)
end

--- (dev: renders slower than 30 ms are logged with debug.flag)
function Base:render(keep)
  local t0 = playdate.getCurrentTimeMilliseconds()
  Page.render(self, keep)
  local d = playdate.getCurrentTimeMilliseconds() - t0
  if d > 30 and PUI.PROF then
    local t = self.title
    if type(t) == "function" then t = t(self) end
    print(string.format("[pnrender] %s %d ms", tostring(t), d))
  end
end

function Base:leftButtonDown()
  if adjust(self, -1) then return end
  Page.leftButtonDown(self)
end
function Base:rightButtonDown()
  if adjust(self, 1) then return end
  Page.rightButtonDown(self)
end

function Base:statusLine() return "" end

--- Hold B: back to the hub.
function Base:BButtonUp()
  if not self.bDown then return end
  self.bDown = false
  if self.heldHome then self.heldHome = false return end
  self:goBack()
end

function Base:update(covered)
  local t0 = nowMs()
  self.profJobs = 0
  self:updateInner(covered)
  local d = nowMs() - t0
  if d > 40 and PUI.PROF and not covered then
    local t = self.title
    if type(t) == "function" then t = t(self) end
    print(string.format("[pnframe] %s %d ms (jobs %d, lazy %d)", tostring(t), d, self.profJobs or 0, self.lazySpent or 0))
  end
end

function Base:updateInner(covered)
  if not covered and App.isHeld("B") and self.bDown then
    self.bHeld = (self.bHeld or 0) + 1
    if self.bHeld == 15 and Pennant.hub and App.top() == self and self ~= Pennant.hub then
      self.heldHome = true
      Sfx.back()
      Pennant.toHub()
      -- (this frame still shows something: the screen we just landed on)
      local t = App.top()
      if t and t ~= self and t.update then t:update(false) end
      return
    end
  else
    self.bHeld = 0
  end
  Page.update(self, covered)
end

--- link opts helper: { id, hint, adj }
function PUI.opts(id, hint, adj, style)
  return { id = id, hint = hint, data = adj and { adj = adj } or nil, style = style or "invert" }
end

-- Widgets -------------------------------------------------------------------------------------------

-- condition arrows: 1 (down) .. 5 (up), 11x11, cached
local arrows = {}
local function arrowImg(c)
  if arrows[c] then return arrows[c] end
  local img = gfx.image.new(12, 12, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  local ang = ({ 90, 45, 0, -45, -90 })[c] -- degrees, 0 = right
  local a = math.rad(-ang)
  local ca, sa = math.cos(a), math.sin(a)
  -- arrow pointing right, centred on (6,6)
  local pts = { { -5, -1.6 }, { 1, -1.6 }, { 1, -4.6 }, { 5.6, 0 }, { 1, 4.6 }, { 1, 1.6 }, { -5, 1.6 } }
  local poly = {}
  for _, p in ipairs(pts) do
    poly[#poly + 1] = 6 + p[1] * ca - p[2] * sa
    poly[#poly + 1] = 6 + p[1] * sa + p[2] * ca
  end
  gfx.fillPolygon(table.unpack(poly))
  gfx.popContext()
  arrows[c] = img
  return img
end
PUI.arrowImg = arrowImg

function PUI.arrow(x, y, c)
  c = c or 3
  if c == 5 then
    -- great: inverted disc so it pops
    gfx.setColor(gfx.kColorBlack)
    gfx.fillCircleInRect(x - 1, y - 1, 14, 14)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    arrowImg(c):draw(x, y)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
  else
    arrowImg(c):draw(x, y)
    if c == 1 then gfx.drawCircleInRect(x - 1, y - 1, 14, 14) end
  end
end

--- Mood: a tiny face (-2..2).
function PUI.mood(x, y, m)
  m = m or 0
  gfx.setColor(gfx.kColorWhite)
  gfx.fillCircleInRect(x, y, 11, 11)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawCircleInRect(x, y, 11, 11)
  gfx.fillRect(x + 3, y + 3, 1, 2)
  gfx.fillRect(x + 7, y + 3, 1, 2)
  if m >= 1 then
    gfx.drawLine(x + 3, y + 7, x + 5, y + 8) gfx.drawLine(x + 5, y + 8, x + 7, y + 7)
    if m >= 2 then gfx.drawLine(x + 3, y + 6, x + 7, y + 6) end
  elseif m <= -1 then
    gfx.drawLine(x + 3, y + 8, x + 5, y + 7) gfx.drawLine(x + 5, y + 7, x + 7, y + 8)
    if m <= -2 then gfx.drawLine(x + 2, y + 2, x + 4, y + 3) gfx.drawLine(x + 8, y + 2, x + 6, y + 3) end
  else
    gfx.drawLine(x + 3, y + 7, x + 7, y + 7)
  end
end

--- Fatigue meter (0..100), w x 6. Fuller = more tired.
function PUI.fatigue(x, y, f, w)
  w = w or 24
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, 6)
  local fw = math.floor((w - 2) * math.max(0, math.min(100, f or 0)) / 100 + 0.5)
  if fw > 0 then
    if (f or 0) >= 70 then gfx.fillRect(x + 1, y + 1, fw, 4)
    else gfx.setPattern(UI.pat.gray) gfx.fillRect(x + 1, y + 1, fw, 4) gfx.setColor(gfx.kColorBlack) end
  end
end

--- Grade letter in a box (S..G) for a 20-80 value.
function PUI.grade(x, y, v, inv)
  local g = PM.grade(v)
  local inverted = inv or g == "S" or g == "A"
  -- (the letter stays on the row's text line; the box, 14 rows from 2 above it, clears its
  -- capitals by a row above and below inside the outline)
  if inverted then
    gfx.fillRect(x, y - 2, 13, 14)
    Text.draw(g, x + 7, y, F().bold, "white", "center")
  else
    gfx.drawRect(x, y - 2, 13, 14)
    Text.draw(g, x + 7, y, F().bold, nil, "center")
  end
end

--- Rating bar 20..80 (w px), with a tick at the cap.
function PUI.bar(x, y, v, cap, w, h)
  w, h = w or 80, h or 7
  local function px(val) return math.floor((math.max(20, math.min(80, val)) - 20) / 60 * (w - 2) + 0.5) end
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  local fw = px(v)
  if fw > 0 then gfx.fillRect(x + 1, y + 1, fw, h - 2) end
  if cap and cap > v then
    gfx.setPattern(UI.pat.gray)
    gfx.fillRect(x + 1 + fw, y + 1, px(cap) - fw, h - 2)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(x + 1 + px(cap), y - 1, x + 1 + px(cap), y + h)
  end
end

--- Stars 1..5 (potential).
function PUI.stars(x, y, n)
  local s = ""
  for i = 1, 5 do s = s .. (i <= n and "\u{2605}" or "") end
  Text.draw(s, x, y, F().bold)
  return F().bold:getTextWidth(s)
end

--- Injury badge: a little cross.
function PUI.cross(x, y)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x, y, 11, 11)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x + 4, y + 2, 3, 7)
  gfx.fillRect(x + 2, y + 4, 7, 3)
  gfx.setColor(gfx.kColorBlack)
end

--- Section heading with a rule.
function PUI.head(L, text, x, y, w)
  Text.draw(text, x, y, F().head)
  Draw.hr(x, y + 15, w or (392 - x))
  L:mark(y + 18)
  return y + 19
end

--- A row of tabs (links). items = { {id, label, action} }; sel = id.
function PUI.tabs(L, items, sel, y)
  local x = 4
  for _, it in ipairs(items) do
    local w = F().bold:getTextWidth(it[2]) + 14
    local on = it[1] == sel
    local ty = Text.boxY(F().bold, y + 1, 14, it[2])
    if on then
      gfx.fillRect(x, y, w, 16)
      Text.draw(it[2], x + 7, ty, F().bold, "white")
    else
      gfx.drawRect(x, y, w, 16)
      Text.draw(it[2], x + 7, ty, F().bold)
    end
    L:link(x, y, w, 16, it[3], { id = "tab:" .. it[1], style = "ring", hint = it[4] })
    x = x + w + 3
  end
  gfx.drawLine(0, y + 16, 394, y + 16)
  L:mark(y + 18)
  return y + 20
end

--- Club logo (32 or 16) with a fallback pennant.
function PUI.logo(abbr, x, y, size)
  size = size or 32
  if Logos.draw({ abbr = abbr }, x, y, size) then return end
  gfx.drawRect(x, y, size, size)
  Text.draw(abbr, x + size // 2, y + size // 2 - 7, F().bold, nil, "center")
end

function PUI.teamName(abbr) local c = PennantClubs.byAbbr[abbr] return c and (c.city .. " " .. c.name) or abbr end
function PUI.nick(abbr) local c = PennantClubs.byAbbr[abbr] return c and c.name or abbr end

--- One player row (roster-style). cols: name, pos, cond, mood, fatigue, ovr, extra text
function PUI.playerRow(Lb, p, x, y, w, action, opts)
  opts = opts or {}
  -- compact rows (14 px pitch, a 12 px face crop) let a 13-man list fit without scrolling
  local h = opts.compact and 13 or 16
  PUI.lazy(Lb, x - 2, y - 1, w + 4, h + 1, function() PUI.paintPlayerRow(p, x, y, w, opts) end)
  if action then Lb:link(x - 2, y - 1, w + 4, h + 1, action, { id = opts.id or ("p" .. p.id), style = "invert", hint = opts.hint, data = opts.data }) end
  return h
end

function PUI.paintPlayerRow(p, x, y, w, opts)
  if opts.face ~= false then
    -- tiny face (24px thumb, cropped to the row)
    local img = Faces.get("face:" .. p.face, 24)
    PUI.srcRect = PUI.srcRect or playdate.geometry.rect.new(0, 4, 24, 16)
    PUI.srcRectC = PUI.srcRectC or playdate.geometry.rect.new(0, 6, 24, 12)
    local r = opts.compact and PUI.srcRectC or PUI.srcRect
    if img then img:draw(x, y, gfx.kImageUnflipped, r) else gfx.drawRect(x, y, 24, r.height) end
  end
  if opts.compact then y = y - 1 end
  local nx = x + (opts.face ~= false and 28 or 2)
  Text.draw(p.pos == "P" and (p.role or "P") or p.pos, nx, y + 1, F().bold)
  Text.draw(Text.ellipsize(PM.short(p), F().body, 108), nx + 26, y + 1, F().body)
  local cx = nx + 138
  if p.inj then PUI.cross(cx, y + 2) else PUI.arrow(cx, y + 2, p.cond) end
  PUI.mood(cx + 17, y + 2, p.mood)
  PUI.fatigue(cx + 33, y + 5, p.fat, 22)
  local ovr = PM.ovr(p)
  PUI.grade(cx + 60, y + 1, ovr)
  Text.draw(tostring(ovr), cx + 92, y + 1, F().bold, nil, "right")
  if opts.extra then Text.draw(Text.ellipsize(opts.extra, F().body, x + w - cx - 98), cx + 98, y + 1, F().body) end
end

--- Column header for playerRow.
function PUI.rowHeader(x, y, extra)
  local nx = x + 28
  Text.draw("POS", nx, y, F().body)
  Text.draw("NAME", nx + 26, y, F().body)
  local cx = nx + 138
  -- (one-letter heads over the arrow and the mood face, so nothing runs together)
  Text.draw("C", cx + 6, y, F().body, nil, "center")
  Text.draw("M", cx + 23, y, F().body, nil, "center")
  Text.draw("FAT", cx + 34, y, F().body)
  Text.draw("OVR", cx + 92, y, F().body, nil, "right")
  if extra then Text.draw(extra, cx + 98, y, F().body) end
  gfx.drawLine(x, y + 13, 392, y + 13)
end

--- Run fn behind a "please wait" box (drawn for a few frames first so it's visible).
function PUI.busy(text, fn)
  local b = Busy.show(text)
  b.t = 4
  playdate.frameTimer.performAfterDelay(2, function()
    local ok, e = pcall(fn)
    b:done()
    if not ok then print("[pennant] " .. tostring(e)) Dialog.alert("Something broke", tostring(e)) end
  end)
end
