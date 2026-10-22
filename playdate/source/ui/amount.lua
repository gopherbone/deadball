-- Crank-driven money amount dialog.
-- Amount.open{ title=, prompt=, min=5, max=1000, value=25, style="bbs"|nil, onDone=function(amount|nil) end }

local gfx <const> = playdate.graphics

Amount = Amount or {}
Amount.__index = Amount

function Amount.open(opts)
  local a = setmetatable({ opts = opts, opaque = false }, Amount)
  App.push(a)
  return a
end

local function step(a)
  if a < 50 then return 5 elseif a < 200 then return 10 elseif a < 1000 then return 25 else return 100 end
end

function Amount:enter()
  local o = self.opts
  self.min = o.min or 1
  self.max = math.max(self.min, o.max or 1000)
  self.value = math.max(self.min, math.min(self.max, o.value or self.min))
  self.shown = self.value
  self.acc = 0
  self.t = 0
  self.bounce = 0
end

function Amount:set(v)
  v = math.max(self.min, math.min(self.max, v))
  if v ~= self.value then self.value = v Sfx.detent() else self.bounce = 5 Sfx.error() end
end

function Amount:cranked(c)
  self.acc += c
  while self.acc >= 15 do self.acc -= 15 self:set(self.value + step(self.value)) end
  while self.acc <= -15 do self.acc += 15 self:set(self.value - step(self.value - 1)) end
end
function Amount:upButtonDown() self:set(self.value + step(self.value)) self.hold = 1 self.holdT = 0 end
function Amount:downButtonDown() self:set(self.value - step(self.value - 1)) self.hold = -1 self.holdT = 0 end
function Amount:rightButtonDown() self:set(self.max) end
function Amount:leftButtonDown() self:set(self.min) end
function Amount:upButtonUp() self.hold = nil end
function Amount:downButtonUp() self.hold = nil end
function Amount:AButtonDown() Sfx.select() App.pop() if self.opts.onDone then self.opts.onDone(self.value) end end
function Amount:BButtonDown() Sfx.back() App.pop() if self.opts.onDone then self.opts.onDone(nil) end end

function Amount:update(covered)
  self.t += 1
  if self.hold and not App.isHeld(self.hold > 0 and "up" or "down") then self.hold = nil end
  if self.hold and not covered then
    self.holdT += 1
    if self.holdT > 8 and self.holdT % 2 == 0 then self:set(self.value + self.hold * step(self.value - (self.hold < 0 and 1 or 0))) end
  end
  if self.bounce > 0 then self.bounce -= 1 end
  self.shown += (self.value - self.shown) * 0.5
  if math.abs(self.shown - self.value) < 0.5 then self.shown = self.value end
  Draw.dim(0.5)
  local bbs = self.opts.style == "bbs"
  local x, y, w, h = 70, 60, 260, 120
  local fg = bbs and "white" or nil
  local ix, iy, iw
  if bbs then
    gfx.setColor(gfx.kColorBlack) gfx.fillRect(x, y, w, h)
    gfx.setColor(gfx.kColorWhite) gfx.drawRect(x + 2, y + 2, w - 4, h - 4) gfx.fillRect(x + 2, y + 2, w - 4, 14)
    Text.draw(self.opts.title or "AMOUNT", x + 8, y + 1, UI.fonts.mono)
    gfx.setColor(gfx.kColorBlack)
    ix, iy, iw = x + 3, y + 18, w - 6
  else
    ix, iy, iw = Draw.window(x, y, w, h, self.opts.title or "Amount")
  end
  Text.draw(self.opts.prompt or "", ix + iw // 2, iy + 4, UI.fonts.body, fg, "center")
  local ax = ix + iw // 2 + ((self.bounce > 0) and ((self.bounce % 2) * 4 - 2) or 0)
  Text.draw(Fmt.money(math.floor(self.shown + 0.5)), ax, iy + 22, UI.fonts.big, fg, "center")
  Text.draw("\u{25c0} min", ix + 10, iy + 28, UI.fonts.body, fg)
  Text.draw("max \u{25b6}", ix + iw - 10, iy + 28, UI.fonts.body, fg, "right")
  Draw.progress(ix + 20, iy + 54, iw - 40, 8, (self.value - self.min) / math.max(1, self.max - self.min), (not bbs) and "gray" or nil)
  Text.draw("Crank or Up/Down to adjust  \u{2022}  A: OK  B: cancel", ix + iw // 2, iy + 70, UI.fonts.body, fg, "center")
end
