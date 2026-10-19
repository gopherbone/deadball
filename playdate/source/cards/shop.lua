-- The card shop: pack list → confirm → POST /packs/buy → pack opening.

import "ballcast/kit"
import "cards/ui"

local gfx <const> = playdate.graphics
local floor <const> = math.floor

Cards = Cards or {}
local K = BCKit
local UI = Cards.UI

local S = { opaque = true }
Cards.shopScene = S

local packImg = {}
local function packImage(kind)
  local img = packImg[kind]
  if img == nil then
    img = K.image("images/cards/pack-" .. kind) or false
    packImg[kind] = img
  end
  return img or nil
end
Cards.packImage = packImage

function S:enter()
  self.packs = nil
  self.sel = 1
  self.err = nil
  self.busy = false
  self.crankAcc = 0
  self.t = 0
  UI.refreshMoney()
  K.get("/shop", function(err, d)
    if err or not d then self.err = UI.errText(err) return end
    self.packs = d.packs or {}
  end)
end

function S:exit() packImg = {} end
function S:resume() UI.refreshMoney() end

local function move(self, d)
  if not self.packs or #self.packs == 0 then return end
  self.sel = (self.sel - 1 + d) % #self.packs + 1
  K.sfx("tick")
end

function S:upButtonDown() move(self, -1) end
function S:downButtonDown() move(self, 1) end
function S:leftButtonDown() move(self, -1) end
function S:rightButtonDown() move(self, 1) end
function S:cranked(c)
  self.crankAcc = self.crankAcc + c
  if self.crankAcc > 45 then self.crankAcc = 0; move(self, 1) elseif self.crankAcc < -45 then self.crankAcc = 0; move(self, -1) end
end
function S:BButtonDown() App.pop() end

function S:AButtonDown()
  if not self.packs or self.busy then return end
  local p = self.packs[self.sel]
  if not p then return end
  local priceTxt = (p.price or 0) == 0 and "FREE" or K.money(p.price)
  App.push(UI.confirm("BUY " .. string.upper(p.name or p.kind), (p.name or "Pack") .. " for " .. priceTxt .. "? " .. (p.count or "?") .. " cards. No refunds, no crying.", function()
    self.busy = true
    K.post("/packs/buy", { kind = p.kind }, function(err, d)
      self.busy = false
      if err or not d then UI.toast(self, UI.errText(err)) K.sfx("buzz") return end
      UI.setAccount(d.account)
      App.push(Cards.packOpenScene, { kind = p.kind, name = p.name, cards = d.cards or {} })
    end)
  end, "BUY"))
end

function S:update()
  self.t = self.t + 1
  UI.paper()
  UI.header("THE CARD COUNTER", "Fresh from the printer. Gum not guaranteed.")
  if self.err then
    K.text(K.fonts.nb, self.err, 200, 110, "center")
    UI.hints("B BACK")
    return
  end
  if not self.packs then
    K.text(K.fonts.nb, "Unlocking the display case...", 200, 110, "center")
    return
  end
  -- packs on the counter: selected one large and bobbing, others small
  local n = #self.packs
  local slotW = 400 / math.max(1, n)
  for i, p in ipairs(self.packs) do
    local cx = floor((i - 0.5) * slotW)
    local img = packImage(p.kind)
    local sel = i == self.sel
    local s = sel and 0.75 or 0.5
    local bob = sel and floor(math.sin(self.t / 6) * 2) or 0
    local w, h = 112 * s, 160 * s
    local x, y = cx - w / 2, 150 - h + bob
    if sel then
      gfx.setColor(gfx.kColorBlack)
      gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
      gfx.fillEllipseInRect(cx - w / 2, 146, w, 10)
      gfx.setColor(gfx.kColorBlack)
    end
    if img then img:drawScaled(x, y, s) else
      gfx.setColor(gfx.kColorBlack); gfx.fillRect(x, y, w, h)
      gfx.setColor(gfx.kColorWhite); gfx.fillRect(x + 4, y + 10, w - 8, h * 0.4)
      gfx.setColor(gfx.kColorBlack); K.text(K.fonts.bitmore, string.upper(p.kind), cx, y + 16, "center")
    end
    local price = (p.price or 0) == 0 and "FREE" or K.money(p.price)
    local f = sel and K.fonts.nb or K.fonts.bitmore
    local tw = f:getTextWidth(price) + 8
    gfx.setColor(sel and gfx.kColorBlack or gfx.kColorWhite)
    gfx.fillRect(cx - tw / 2, 156, tw, 15)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(cx - tw / 2, 156, tw, 15)
    if sel then K.textW(f, price, cx, 157, "center") else K.text(f, price, cx, 159, "center") end
  end
  -- description card
  local p = self.packs[self.sel]
  if p then
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(10, 176, 380, 46)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(10, 176, 380, 46)
    K.text(K.fonts.slab, string.upper(p.name or p.kind), 18, 177)
    K.text(K.fonts.nb, (p.count or "?") .. " CARDS", 382, 180, "right")
    local lines = K.wrap(K.fonts.nl, p.blurb or "", 360)
    if lines[1] then K.text(K.fonts.nl, lines[1], 18, 196) end
    if lines[2] then K.text(K.fonts.nl, lines[2], 18, 208) end
  end
  UI.hints(self.busy and "PAYING THE MAN..." or "< > CHOOSE   A BUY   B BACK")
  UI.drawToast(self)
end
