-- Modal dialogs (as non-opaque scenes) and toasts (drawn by main after the stack).

local gfx <const> = playdate.graphics

-- Toasts -------------------------------------------------------------------------------

Toast = Toast or {}
local toasts = {}

--- kind: nil | "good" | "bad" | "mail"
function Toast.show(text, kind)
  toasts[#toasts + 1] = { text = text, kind = kind, t = 0, life = 75 + #text }
  if kind == "bad" then Sfx.error() elseif kind == "mail" then Sfx.mail() end
end

function Toast.draw()
  if #toasts == 0 then return end
  local tst = toasts[1]
  tst.t += 1
  local f = UI.fonts.bold
  local lines = Text.wrap(tst.text, f, 300)
  local h = #lines * (f:getHeight() + 1) + 8
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, f:getTextWidth(l)) end
  w += 20
  if tst.kind then w += 14 end
  local slide = math.min(1, tst.t / 6)
  if tst.t > tst.life - 6 then slide = math.max(0, (tst.life - tst.t) / 6) end
  local ease = 1 - (1 - slide) * (1 - slide)
  local x = 200 - w // 2
  local y = 240 - math.floor((h + 18) * ease)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRoundRect(x + 2, y + 2, w, h, 4)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRoundRect(x, y, w, h, 4)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRoundRect(x, y, w, h, 4)
  gfx.setLineWidth(1)
  local tx = x + 10
  if tst.kind == "good" then
    Text.draw("\u{2713}", tx - 2, y + 4, UI.fonts.bold)
    tx += 12
  elseif tst.kind == "bad" then
    Text.draw("!", tx, y + 4, UI.fonts.bold)
    tx += 10
  elseif tst.kind == "mail" then
    Chrome.envelope(tx - 3, y + 6)
    tx += 12
  end
  for i, l in ipairs(lines) do
    Text.draw(l, tx, y + 4 + (i - 1) * (f:getHeight() + 1), f)
  end
  if tst.t >= tst.life then table.remove(toasts, 1) end
end

-- Dialog -------------------------------------------------------------------------------

Dialog = Dialog or {}
Dialog.__index = Dialog

--[[ Dialog.show{
       title = "...", body = "...", face = "face:12" (optional),
       buttons = { "OK", "Cancel" }   (strings or { label=, value=, note= })
       cancel = 2                     (button index for B; nil = B does nothing)
       onChoose = function(index, value) end,
       style = "alert" | "bbs" | "card",  icon = "!" | "?"
       vertical = true                (stack buttons as a list of choices)
     } ]]
function Dialog.show(opts)
  local d = setmetatable({ opts = opts, opaque = false, sel = opts.default or 1, t = 0 }, Dialog)
  App.push(d)
  return d
end

function Dialog.alert(title, body, cb)
  return Dialog.show({ title = title, body = body, buttons = { "OK" }, cancel = 1, onChoose = function() if cb then cb() end end, icon = "!" })
end

function Dialog.confirm(title, body, yes, no, cb)
  return Dialog.show({ title = title, body = body, buttons = { yes or "OK", no or "Cancel" }, cancel = 2, icon = "?",
    onChoose = function(i) if cb then cb(i == 1) end end })
end

function Dialog:enter()
  self.t = 0
  local o = self.opts
  self.buttons = {}
  for i, b in ipairs(o.buttons or { "OK" }) do
    if type(b) == "string" then b = { label = b, value = i } end
    self.buttons[i] = b
  end
  local f = UI.fonts.body
  self.w = o.width or (o.vertical and 300 or 280)
  local textW = self.w - 24 - ((o.face and 64) or (o.icon and 34) or 0)
  self.lines = Text.wrap(o.body or "", f, textW)
  local lh = f:getHeight() + 1
  local bodyH = #self.lines * lh
  if o.face then bodyH = math.max(bodyH, 72) end
  local btnH = o.vertical and (#self.buttons * 20 + 4) or 24
  self.h = 15 + 8 + bodyH + 8 + btnH + 6
  if self.h > 220 then self.h = 220 end
  self.x = 200 - self.w // 2
  self.y = 120 - self.h // 2
  self.bodyH = bodyH
  Sfx.select()
end

function Dialog:close(index)
  local b = self.buttons[index]
  App.pop()
  if self.opts.onChoose then self.opts.onChoose(index, b and b.value) end
end

function Dialog:update(covered)
  self.t += 1
  local o = self.opts
  -- dim the page behind
  if self.t == 1 or true then
    Draw.dim(0.5)
    gfx.setColor(gfx.kColorBlack)
  end
  local x, y, w, h = self.x, self.y, self.w, self.h
  -- zoom-open animation (outline rects growing from center)
  if self.t < 6 and not Game.settings.reduceMotion then
    local k = self.t / 6
    local zw, zh = math.floor(w * k), math.floor(h * k)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(200 - zw // 2 - 1, 120 - zh // 2 - 1, zw + 2, zh + 2)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(200 - zw // 2, 120 - zh // 2, zw, zh)
    return
  end
  local bbs = o.style == "bbs"
  if bbs then
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x, y, w, h)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(x + 2, y + 2, w - 4, h - 4)
    gfx.fillRect(x + 2, y + 2, w - 4, 14)
    Text.draw(o.title or "", x + 8, y + 2, UI.fonts.mono)
    gfx.setColor(gfx.kColorBlack)
  else
    Draw.window(x, y, w, h, o.title or "Message", { inverted = o.style == "card", titleLeft = o.style == "card" })
  end
  local cx, cy = x + 12, y + 23
  local color = bbs and "white" or nil
  if o.face then
    Faces.draw(o.face, cx, cy, 48)
    cx += 60
  elseif o.icon then
    -- classic alert icon
    gfx.setColor(bbs and gfx.kColorWhite or gfx.kColorBlack)
    gfx.fillCircleAtPoint(cx + 11, cy + 11, 12)
    Text.draw(o.icon, cx + 11, cy + 4, UI.fonts.head, bbs and nil or "white", "center")
    gfx.setColor(gfx.kColorBlack)
    cx += 34
  end
  local f = UI.fonts.body
  local lh = f:getHeight() + 1
  for i, l in ipairs(self.lines) do
    Text.draw(l, cx, cy + (i - 1) * lh, f, color)
  end
  -- buttons
  local by = y + 23 + self.bodyH + 8
  if o.vertical then
    for i, b in ipairs(self.buttons) do
      local ry = by + (i - 1) * 20
      local sel = i == self.sel
      local bx, bw = x + 10, w - 20
      if sel then
        gfx.setColor(bbs and gfx.kColorWhite or gfx.kColorBlack)
        gfx.fillRect(bx, ry, bw, 18)
      else
        gfx.setColor(bbs and gfx.kColorWhite or gfx.kColorBlack)
        gfx.drawRect(bx, ry, bw, 18)
      end
      local tc = (sel ~= bbs) and "white" or nil
      local label = string.char(64 + i) .. ") " .. b.label
      Text.draw(label, bx + 6, ry + 3, UI.fonts.bold, tc)
      if b.note then Text.draw(b.note, bx + bw - 6, ry + 3, UI.fonts.body, tc, "right") end
      gfx.setColor(gfx.kColorBlack)
    end
  else
    local n = #self.buttons
    local bw = math.min(90, (w - 20 - (n - 1) * 8) // n)
    local total = n * bw + (n - 1) * 8
    local bx = x + w - 10 - total
    for i, b in ipairs(self.buttons) do
      local sel = i == self.sel
      Draw.button(bx, by, bw, 18, b.label, (sel and self.pressT and self.pressT > 0) and "pressed" or nil)
      if sel then
        gfx.setLineWidth(2)
        gfx.drawRoundRect(bx - 3, by - 3, bw + 6, 24, 4)
        gfx.setLineWidth(1)
      end
      bx += bw + 8
    end
  end
  if self.pressT and self.pressT > 0 then
    self.pressT -= 1
    if self.pressT == 0 then self:close(self.sel) end
  end
end

function Dialog:move(d)
  local n = #self.buttons
  local s = math.max(1, math.min(n, self.sel + d))
  if s ~= self.sel then
    self.sel = s
    Sfx.focus()
  else
    Sfx.detent()
  end
end

function Dialog:leftButtonDown() if not self.opts.vertical then self:move(-1) end end
function Dialog:rightButtonDown() if not self.opts.vertical then self:move(1) end end
function Dialog:upButtonDown() if self.opts.vertical then self:move(-1) end end
function Dialog:downButtonDown() if self.opts.vertical then self:move(1) end end
function Dialog:cranked(change)
  self.crankAcc = (self.crankAcc or 0) + change
  if math.abs(self.crankAcc) > 30 then
    self:move(self.crankAcc > 0 and 1 or -1)
    self.crankAcc = 0
  end
end
function Dialog:AButtonDown()
  if self.t < 6 or self.pressT then return end
  Sfx.select()
  self.pressT = 3
end
function Dialog:BButtonDown()
  if self.opts.cancel and not self.pressT then
    Sfx.back()
    self:close(self.opts.cancel)
  end
end

-- Busy modal: blocks input while a write is in flight -----------------------------------

Busy = Busy or {}
Busy.__index = Busy

--- Shows a small "Please wait" box until done() is called.
function Busy.show(text)
  local b = setmetatable({ opaque = false, text = text or "Please wait", t = 0 }, Busy)
  App.push(b)
  return b
end

function Busy:update()
  self.t += 1
  if self.t < 4 then return end -- don't flash for instant fixture replies
  local w = 170
  local x, y = 200 - w // 2, 100
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 3, y + 3, w, 36)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, 36)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, 36)
  Draw.throbber(x + 18, y + 18, 9, self.t, true)
  Text.draw(self.text .. string.rep(".", (self.t // 6) % 4), x + 34, y + 11, UI.fonts.bold)
end

function Busy:done()
  if App.top() == self then App.pop() end
end

--- Runs an Api write behind a busy box; toasts errors; calls cb(data) only on success.
function Busy.post(path, body, text, cb, onErr)
  local b = Busy.show(text)
  Api.post(path, body, function(err, data)
    b:done()
    if err then
      Sfx.error()
      if onErr then onErr(err) else Dialog.alert("Error", Api.errorText(err)) end
      return
    end
    Game.absorb(data)
    if cb then cb(data) end
  end)
end
