-- Shared bits for the card scenes: header strip, money, confirm box, toasts, price picker.

import "ballcast/kit"

local gfx <const> = playdate.graphics
local floor <const> = math.floor

Cards = Cards or {}
local UI = {}
Cards.UI = UI
local K = BCKit

UI.money = nil   -- last known balance

function UI.account()
  return (Game and Game.account) or UI.acct
end

function UI.setAccount(a)
  if not a then return end
  UI.acct = a
  UI.money = a.money
  if Game and Game.setAccount then pcall(Game.setAccount, a)
  elseif Game then Game.account = a end
end

function UI.refreshMoney()
  local a = UI.account()
  if a and a.money then UI.money = a.money return end
  K.get("/me", function(err, d)
    if not err and d and d.account then UI.setAccount(d.account) end
  end)
end

local titleW = {}

--- Header: title on a black band with a pinstripe and the balance at right.
function UI.header(title, sub)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 22)
  gfx.setColor(gfx.kColorWhite)
  gfx.drawLine(0, 19, 400, 19)
  K.textW(K.fonts.slab, title, 8, 1)
  local a = UI.account()
  local m = (a and a.money) or UI.money
  if Status and Status.drawCluster and Game and Game.account then
    -- the shell's status cluster: heartbeat chip, heat, mail, money (ui/status.lua)
    local tw = titleW[title]
    if not tw then
      local ok, w = pcall(function() return K.fonts.slab:getTextWidth(title) end)
      tw = ok and w or 150
      titleW[title] = tw
    end
    Status.drawCluster(396, 2, 8 + tw + 8)
  elseif m then K.textW(K.fonts.nb, K.money(m), 392, 4, "right") end
  if sub then
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(0, 22, 400, 13)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(0, 35, 400, 35)
    K.text(K.fonts.bitmore, sub, 8, 23)
  end
end

--- Bottom hint strip.
function UI.hints(s)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 226, 400, 14)
  K.textW(K.fonts.bitmore, s, 200, 227, "center")
end

--- Paper texture background (light, reads on the reflective screen).
local paper
function UI.paper()
  if not paper then
    do
      paper = gfx.image.new(400, 240, gfx.kColorWhite)
      gfx.pushContext(paper)
      gfx.setPattern({ 0xFF, 0xFF, 0xF7, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF })
      gfx.fillRect(0, 0, 400, 240)
      gfx.popContext()
    end
  end
  local w, h = paper:getSize()
  if w >= 400 and h >= 240 then paper:draw(0, 0) else
    for y = 0, 239, h do for x = 0, 399, w do paper:draw(x, y) end end
  end
end

--- Modal confirm box. Returns a scene to push.
function UI.confirm(title, body, onYes, yesLabel)
  local s = { opaque = false, t = 0 }
  function s:update()
    self.t = self.t + 1
    local w, h = 280, 100
    local x, y = 60, 66
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
    gfx.fillRect(0, 0, 400, 240)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x + 4, y + 4, w, h)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x, y, w, h)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
    gfx.drawRect(x, y, w, h)
    gfx.setLineWidth(1)
    gfx.fillRect(x, y, w, 18)
    K.textW(K.fonts.nb, title, x + w / 2, y + 2, "center")
    local lines = K.wrap(K.fonts.nl, body, w - 20)
    for i, l in ipairs(lines) do
      if i > 4 then break end
      K.text(K.fonts.nl, l, x + w / 2, y + 22 + (i - 1) * 14, "center")
    end
    K.text(K.fonts.nb, "A " .. (yesLabel or "YES") .. "      B NO", x + w / 2, y + h - 17, "center")
  end
  function s:AButtonDown() App.pop(); K.sfx("click"); onYes() end
  function s:BButtonDown() App.pop(); K.sfx("tick") end
  return s
end

--- Toast message drawn by scenes: UI.toast(scene, text)
function UI.toast(scene, text, secs)
  scene.toastText = text
  scene.toastUntil = playdate.getCurrentTimeMilliseconds() + (secs or 2.2) * 1000
end

function UI.drawToast(scene)
  if not scene.toastText or playdate.getCurrentTimeMilliseconds() > (scene.toastUntil or 0) then return end
  local f = K.fonts.nb
  local w = math.min(380, f:getTextWidth(scene.toastText) + 16)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(200 - w / 2, 196, w, 20)
  K.textW(f, K.fit(f, scene.toastText, w - 10), 200, 199, "center")
end

function UI.errText(err)
  if not err then return "Something went wrong." end
  return err.message or err.error or err.code or "Something went wrong."
end

--- Price picker overlay: crank / up-down to set, A to confirm. onDone(price) or nil on cancel.
function UI.pricePicker(card, suggested, onDone)
  local s = { opaque = false, price = math.max(1, suggested or 5), acc = 0 }
  local function step(n)
    s.price = math.max(1, math.min(999999, s.price + n))
    K.sfx("tick")
  end
  function s:cranked(change)
    self.acc = self.acc + change
    local unit = math.abs(change) > 15 and 25 or (self.price >= 500 and 10 or (self.price >= 100 and 5 or 1))
    while self.acc >= 12 do self.acc = self.acc - 12; step(unit) end
    while self.acc <= -12 do self.acc = self.acc + 12; step(-unit) end
  end
  function s:upButtonDown() step(self.price >= 100 and 10 or 1) end
  function s:downButtonDown() step(-(self.price > 100 and 10 or 1)) end
  function s:rightButtonDown() step(100) end
  function s:leftButtonDown() step(-100) end
  function s:AButtonDown() App.pop(); K.sfx("click"); onDone(self.price) end
  function s:BButtonDown() App.pop(); onDone(nil) end
  function s:update()
    local x, y, w, h = 90, 50, 220, 140
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
    gfx.fillRect(0, 0, 400, 240)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x + 4, y + 4, w, h)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x, y, w, h)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
    gfx.drawRect(x, y, w, h)
    gfx.setLineWidth(1)
    gfx.fillRect(x, y, w, 18)
    K.textW(K.fonts.nb, "LIST ON THE MARKET", x + w / 2, y + 2, "center")
    K.text(K.fonts.nl, K.fit(K.fonts.nl, card.person and card.person.name or "?", w - 20), x + w / 2, y + 24, "center")
    -- the big number, like a cash register
    local big = K.fonts.big
    local txt = K.money(self.price)
    gfx.fillRect(x + 30, y + 44, w - 60, 36)
    K.textW(big, txt, x + w / 2, y + 49, "center")
    -- crank dial
    local a = (self.price * 12) % 360
    local cx, cy = x + w - 18, y + 62
    gfx.drawCircleAtPoint(cx, cy, 9)
    gfx.drawLine(cx, cy, cx + math.cos(math.rad(a)) * 8, cy + math.sin(math.rad(a)) * 8)
    local fee = math.floor(self.price * 0.05 + 0.5)
    K.text(K.fonts.bitmore, "SUGGESTED " .. K.money(suggested or 0) .. "   HOUSE CUT 5% (" .. K.money(fee) .. ")", x + w / 2, y + 88, "center")
    K.text(K.fonts.bitmore, "YOU NET " .. K.money(self.price - fee), x + w / 2, y + 100, "center")
    K.text(K.fonts.nb, "CRANK/UP-DN  A LIST  B CANCEL", x + w / 2, y + h - 18, "center")
  end
  return s
end

--- Fan page for a person if the shell provides one.
function UI.fanPage(personId)
  if not personId then return false end
  if Nav and Nav.person and Sites and Sites.Person then Nav.person(personId) return true end
  if Sites and Sites.person then
    if type(Sites.person) == "function" then Sites.person(personId) else App.push(Sites.person, { id = personId }) end
    return true
  end
  return false
end
