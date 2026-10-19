--[[ A crank-driven word wheel / list picker (modal).
  Picker.open{
    title = "Pick a player",
    items = { "Moose Mullane", ... } or { { label=, value=, note= }, ... },
    selected = 1,
    letterJump = true,          -- left/right jump between first letters
    onPick = function(item, index) end,   -- nil item when cancelled (B)
    style = "browser" | "bbs",
  }
  Crank: one item per 20 degrees with a detent click. Up/down: one item. Left/right: letter jump. ]]

local gfx <const> = playdate.graphics

Picker = Picker or {}
Picker.__index = Picker

local ROW_H <const> = 17
local VISIBLE <const> = 9

function Picker.open(opts)
  local p = setmetatable({ opts = opts, opaque = false }, Picker)
  App.push(p)
  return p
end

local built = setmetatable({}, { __mode = "k" })   -- opts.items table -> { items, letters }

--- The normalized list and its letter index. With `slice`, yields every `slice` items, so a
--- coroutine can spread a long list (the composer's ~1,000 players) over several frames.
local function build(src, slice)
  local items = {}
  for i, it in ipairs(src) do
    if type(it) ~= "table" then it = { label = tostring(it), value = it } end
    items[i] = it
    if slice and i % slice == 0 then coroutine.yield() end
  end
  local letters, seen = {}, {}
  for i, it in ipairs(items) do
    -- first letter or digit, skipping leading punctuation/space
    local p = it.label:find("[^%p%s]")
    local c = p and it.label:sub(p, p):upper() or ""
    if c ~= "" and not seen[c] then
      seen[c] = true
      letters[#letters + 1] = { c = c, i = i }
    end
    if slice and i % slice == 0 then coroutine.yield() end
  end
  return { items = items, letters = letters }
end

--- Builds a list's index ahead of time, from inside a coroutine (see Composer:loaded).
function Picker.prewarm(src, slice)
  if not built[src] then
    local b = build(src, slice)
    built[src] = built[src] or b
  end
end

function Picker:enter()
  -- the normalized list and its letter index are built once per items table (callers that
  -- reuse their list, like the composer's ~1,000 players, open the picker without a hitch)
  local src = self.opts.items or {}
  local b = built[src] or build(src)
  built[src] = b
  local items = b.items
  self.items = items
  self.letters = b.letters
  self.sel = math.max(1, math.min(#items, self.opts.selected or 1))
  self.pos = self.sel   -- smoothed position for the wheel
  self.acc = 0
  self.t = 0
  self.letterJump = self.opts.letterJump ~= false and #items > 12 and #self.letters > 1
  self.w = self.opts.width or 300
  self.h = 15 + 6 + VISIBLE * ROW_H + 22
  self.x = 200 - self.w // 2
  self.y = 120 - self.h // 2 + 4
end

function Picker:letterAt(i)
  local cur = nil
  for _, l in ipairs(self.letters) do
    if l.i <= i then cur = l end
  end
  return cur
end

function Picker:setSel(i, sound)
  i = math.max(1, math.min(#self.items, i))
  if i ~= self.sel then
    self.sel = i
    if sound ~= false then Sfx.detent() end
  else
    if sound ~= false then self.bumpT = 4 end
  end
end

function Picker:jumpLetter(d)
  if not self.letterJump then
    self:setSel(self.sel + d * VISIBLE)
    return
  end
  local cur = self:letterAt(self.sel)
  local idx = 1
  for k, l in ipairs(self.letters) do if l == cur then idx = k end end
  local target
  if d > 0 then
    target = self.letters[math.min(#self.letters, idx + 1)]
  else
    -- if we're inside a group, go to its start first
    if cur and self.sel > cur.i then target = cur else target = self.letters[math.max(1, idx - 1)] end
  end
  if target then
    self:setSel(target.i, false)
    Sfx.focus()
  end
end

function Picker:update()
  self.t += 1
  if self.bumpT and self.bumpT > 0 then self.bumpT -= 1 end
  local bbs = self.opts.style == "bbs"
  -- dim behind
  Draw.dim(0.5)
  gfx.setColor(gfx.kColorBlack)
  -- ease the wheel
  local d = self.sel - self.pos
  self.pos += d * (Game.settings.reduceMotion and 1 or 0.45)
  if math.abs(d) < 0.02 then self.pos = self.sel end

  -- settled: the panel is a cached image, repainted only when the selection changes
  -- (12 rows of text, four fades and the letter strip were ~20 ms a frame on the device)
  local settled = self.pos == self.sel and not (self.bumpT and self.bumpT > 0)
  if settled then
    if self.panelSel ~= self.sel or not self.panelImg then
      self.panelSel = self.sel
      self.panelImg = self.panelImg or gfx.image.new(self.w + 4, self.h + 4, gfx.kColorClear)
      self.panelImg:clear(gfx.kColorClear)
      gfx.pushContext(self.panelImg)
      gfx.setDrawOffset(-self.x, -self.y)
      self:drawPanel()
      gfx.setDrawOffset(0, 0)
      gfx.popContext()
    end
    self.panelImg:draw(self.x, self.y)
  else
    self:drawPanel()
  end
end

--- The window, the wheel, the letter strip and the footer, in screen coordinates.
function Picker:drawPanel()
  local bbs = self.opts.style == "bbs"
  local x, y, w, h = self.x, self.y, self.w, self.h
  local ix, iy, iw, ih
  if bbs then
    gfx.fillRect(x, y, w, h)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(x + 2, y + 2, w - 4, h - 4)
    gfx.fillRect(x + 2, y + 2, w - 4, 14)
    Text.draw(self.opts.title or "SELECT", x + 8, y + 1, UI.fonts.mono)
    gfx.setColor(gfx.kColorBlack)
    ix, iy, iw, ih = x + 3, y + 17, w - 6, h - 20
  else
    ix, iy, iw, ih = Draw.window(x, y, w, h, self.opts.title or "Choose")
  end
  local listW = iw - (self.letterJump and 22 or 8)
  local listX = ix + 4
  local listY = iy + 3
  local listH = VISIBLE * ROW_H
  local mid = listY + (VISIBLE // 2) * ROW_H
  local fg = bbs and "white" or nil
  gfx.setClipRect(listX, listY, listW, listH)
  local first = math.floor(self.pos) - VISIBLE // 2 - 1
  for i = first, first + VISIBLE + 2 do
    local it = self.items[i]
    if it then
      local ry = mid + math.floor((i - self.pos) * ROW_H + 0.5)
      local dist = math.abs(i - self.pos)
      local f = (dist < 0.5) and UI.fonts.bold or UI.fonts.body
      local bold = f == UI.fonts.bold
      local label = bold and it._eb or it._el
      if not label then
        label = Text.ellipsize(it.label, f, listW - 12 - (it.note and 60 or 0))
        if bold then it._eb = label else it._el = label end
      end
      Text.draw(label, listX + 8, ry + 2, f, fg)
      if it.note then Text.draw(it.note, listX + listW - 6, ry + 2, UI.fonts.body, fg, "right") end
    end
  end
  -- fade the edges like a drum
  local white = not bbs
  Draw.fade(listX, listY, listW, ROW_H, 0.75, white)
  Draw.fade(listX, listY + listH - ROW_H, listW, ROW_H, 0.75, white)
  Draw.fade(listX, listY + ROW_H, listW, ROW_H, 0.5, white)
  Draw.fade(listX, listY + listH - 2 * ROW_H, listW, ROW_H, 0.5, white)
  gfx.clearClipRect()
  -- selection bar (XOR)
  local bx = listX + ((self.bumpT and self.bumpT > 0) and ((self.bumpT % 2) * 2 - 1) or 0)
  gfx.setColor(gfx.kColorXOR)
  gfx.fillRect(bx + 2, mid, listW - 4, ROW_H)
  gfx.setColor(bbs and gfx.kColorWhite or gfx.kColorBlack)
  -- pointer triangles
  gfx.fillTriangle(listX - 3, mid + 4, listX + 1, mid + 8, listX - 3, mid + 12)
  gfx.setColor(gfx.kColorBlack)
  -- letter strip
  if self.letterJump then
    local sx = ix + iw - 16
    local cur = self:letterAt(self.sel)
    local n = #self.letters
    local step = math.min(12, listH / n)
    -- show a window of letters around the current one if too many
    local maxShow = math.floor(listH / 11)
    local startK = 1
    if n > maxShow then
      local ck = 1
      for k, l in ipairs(self.letters) do if l == cur then ck = k end end
      startK = math.max(1, math.min(n - maxShow + 1, ck - maxShow // 2))
      step = 11
    end
    for k = startK, math.min(n, startK + maxShow - 1) do
      local l = self.letters[k]
      local ly = listY + math.floor((k - startK) * step)
      if l == cur then
        gfx.setColor(bbs and gfx.kColorWhite or gfx.kColorBlack)
        gfx.fillRect(sx - 1, ly, 13, 11)
        Text.draw(l.c, sx + 5, ly - 1, UI.fonts.bold, (not bbs) and "white" or nil, "center")
        gfx.setColor(gfx.kColorBlack)
      else
        Text.draw(l.c, sx + 5, ly - 1, UI.fonts.body, fg, "center")
      end
    end
  end
  -- footer
  local fy = iy + listH + 6
  local hint = self.letterJump and "Crank/Up/Down: pick  Left/Right: A-Z  A: OK" or "Crank/Up/Down: pick   A: OK   B: cancel"
  Text.draw(hint, ix + 6, fy, UI.fonts.body, fg)
  Text.draw(self.sel .. "/" .. #self.items, ix + iw - 6, fy, UI.fonts.body, fg, "right")
end

function Picker:cranked(change)
  self.acc += change
  local step = 20
  while self.acc >= step do
    self.acc -= step
    self:setSel(self.sel + 1)
  end
  while self.acc <= -step do
    self.acc += step
    self:setSel(self.sel - 1)
  end
end

function Picker:upButtonDown() self.held = -1 self.heldT = 0 self:setSel(self.sel - 1) end
function Picker:downButtonDown() self.held = 1 self.heldT = 0 self:setSel(self.sel + 1) end
function Picker:upButtonUp() self.held = nil end
function Picker:downButtonUp() self.held = nil end
function Picker:leftButtonDown() self:jumpLetter(-1) end
function Picker:rightButtonDown() self:jumpLetter(1) end

function Picker:AButtonDown()
  local it = self.items[self.sel]
  Sfx.select()
  App.pop()
  if self.opts.onPick then self.opts.onPick(it, self.sel) end
end

function Picker:BButtonDown()
  Sfx.back()
  App.pop()
  if self.opts.onCancel then self.opts.onCancel() end
end

-- key repeat for up/down
local baseUpdate = Picker.update
function Picker:update(covered)
  if self.held and not covered then
    self.heldT += 1
    if self.heldT > 8 and self.heldT % 2 == 0 then self:setSel(self.sel + self.held) end
  end
  baseUpdate(self, covered)
end
