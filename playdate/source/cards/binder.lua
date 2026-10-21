-- The binder: 3x2 pocket pages (crank turns pages), zoomed card view with flip, list on
-- the market, the player's fan page, and redeeming redeemable cards.

import "ballcast/kit"
import "cards/ui"
import "cards/render"

local gfx <const> = playdate.graphics
local floor <const>, abs <const>, min <const>, max <const> = math.floor, math.abs, math.min, math.max

Cards = Cards or {}
local K = BCKit
local UI = Cards.UI
local CR = Cards.Render

local B = { opaque = true }
Cards.binderScene = B

local PER <const> = 6
local TS <const> = 0.6               -- thumb scale (66x92)
local TW <const>, TH <const> = 66, 92
local GX <const>, GY <const> = 12, 30

function B:enter(args)
  args = args or {}
  self.cards = nil
  self.err = nil
  self.page, self.sel = 1, 1
  self.crankAcc = 0
  self.turn = 0          -- page-turn animation (-1..1)
  self.highlight = args.highlight
  UI.refreshMoney()
  self:load()
end

function B:load()
  local all = {}
  local function page(cursor)
    K.get("/cards" .. (cursor and ("?cursor=" .. cursor) or ""), function(err, d)
      if err or not d then
        if #all > 0 then self.cards = all else self.err = UI.errText(err) end
        return
      end
      for _, c in ipairs(d.cards or {}) do all[#all + 1] = c end
      if d.next and #all < 600 then page(d.next) else
        self.cards = all
        if self.highlight then
          for i, c in ipairs(all) do if c.id == self.highlight then self.page = floor((i - 1) / PER) + 1; self.sel = (i - 1) % PER + 1 end end
        end
      end
    end, { fresh = true })
  end
  page(nil)
end

function B:resume(result)
  UI.refreshMoney()
  if result == "reload" then self.cards = nil; self:load() end
end

function B:exit() CR.trim(nil) end

local function pages(self) return max(1, math.ceil(#(self.cards or {}) / PER)) end
local function current(self) return self.cards and self.cards[(self.page - 1) * PER + self.sel] end

local function turnPage(self, d)
  local np = self.page + d
  if np < 1 or np > pages(self) then K.sfx("buzz") return false end
  self.page = np
  self.turn = d
  local n = #self.cards - (np - 1) * PER
  if self.sel > n then self.sel = max(1, n) end
  K.sfx("flip")
  -- keep only this page's images around
  local keep = {}
  for i = (np - 1) * PER + 1, min(#self.cards, np * PER) do keep[self.cards[i].id] = true end
  CR.trim(keep)
  return true
end

function B:leftButtonDown()
  if not self.cards then return end
  if (self.sel - 1) % 3 == 0 then if turnPage(self, -1) then self.sel = self.sel + 2 end else self.sel = self.sel - 1; K.sfx("tick") end
end
function B:rightButtonDown()
  if not self.cards then return end
  local n = min(PER, #self.cards - (self.page - 1) * PER)
  if self.sel % 3 == 0 or self.sel >= n then if turnPage(self, 1) then self.sel = max(1, self.sel - 2) end else self.sel = self.sel + 1; K.sfx("tick") end
end
function B:upButtonDown() if self.sel > 3 then self.sel = self.sel - 3; K.sfx("tick") end end
function B:downButtonDown()
  if not self.cards then return end
  local n = min(PER, #self.cards - (self.page - 1) * PER)
  if self.sel + 3 <= n then self.sel = self.sel + 3; K.sfx("tick") end
end
function B:cranked(c)
  if not self.cards then return end
  self.crankAcc = self.crankAcc + c
  if self.crankAcc > 120 then self.crankAcc = 0; turnPage(self, 1)
  elseif self.crankAcc < -120 then self.crankAcc = 0; turnPage(self, -1) end
end
function B:AButtonDown()
  local c = current(self)
  if c then App.push(Cards.zoomScene, { card = c }); K.sfx("click") end
end
function B:BButtonDown() App.pop() end


function B:update()
  UI.paper()
  UI.header("THE BINDER")
  if self.err then K.text(K.fonts.nb, self.err, 200, 110, "center"); UI.hints("B BACK") return end
  if not self.cards then K.text(K.fonts.nb, "Opening the binder...", 200, 110, "center") return end
  if #self.cards == 0 then
    K.text(K.fonts.nb, "Your binder is empty. Go buy a pack, champ.", 200, 110, "center")
    UI.hints("B BACK")
    return
  end
  -- page-turn slide
  local off = 0
  if self.turn ~= 0 then
    self.turn = self.turn * 0.7
    if abs(self.turn) < 0.03 then self.turn = 0 end
    off = floor(self.turn * 120)
  end
  -- binder sheet with plastic pockets
  local sheetX = GX - 6 + off
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(sheetX, GY - 4, 3 * (TW + 6) + 6, 2 * (TH + 6) + 6)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(sheetX, GY - 4, 3 * (TW + 6) + 6, 2 * (TH + 6) + 6)
  -- ring holes on the left edge
  for _, hy in ipairs({ GY + 20, GY + 96, GY + 172 }) do gfx.drawCircleAtPoint(sheetX + 3, hy, 2) end
  local base = (self.page - 1) * PER
  for i = 1, PER do
    local c = self.cards[base + i]
    local col, row = (i - 1) % 3, floor((i - 1) / 3)
    local x, y = GX + col * (TW + 6) + off, GY + row * (TH + 6)
    -- pocket
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0.85, gfx.image.kDitherTypeBayer4x4)
    gfx.fillRect(x - 2, y - 2, TW + 4, TH + 4)
    gfx.setColor(gfx.kColorBlack)
    if c then
      CR.thumb(c, TS):draw(x, y)
      -- pocket shine
      gfx.setColor(gfx.kColorWhite)
      gfx.drawLine(x + TW - 14, y + 2, x + TW - 4, y + 12)
    end
    if i == self.sel and c then
      gfx.setColor(gfx.kColorBlack)
      gfx.setLineWidth(3)
      gfx.drawRect(x - 3, y - 3, TW + 6, TH + 6)
      gfx.setLineWidth(1)
    end
  end
  -- detail panel
  local c = current(self)
  local px = 236
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(px, 30, 156, 190)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(px, 30, 156, 190)
  if c then
    local r = CR.rarityOf(c)
    gfx.fillRect(px, 30, 156, 16)
    K.textW(K.fonts.nb, CR.RARITY_LABEL[r] or r, px + 78, Text and Text.boxY and Text.boxY(K.fonts.nb, 30, 16) or 31, "center")
    local y = 50
    for _, l in ipairs(K.wrap(K.fonts.slab, string.upper(c.person and c.person.name or "?"), 146)) do
      K.text(K.fonts.slab, l, px + 6, y); y = y + 16
    end
    local team = c.team and ((c.team.city or "") .. " " .. (c.team.name or "")) or ""
    K.text(K.fonts.bitmore, K.fit(K.fonts.bitmore, string.upper(team), 146), px + 6, y + 2)
    K.text(K.fonts.bitmore, ((c.front and c.front.pos) or (c.person and c.person.pos) or "") .. "  -  " .. (c.set or "") .. " #" .. (c.number or "?"), px + 6, y + 14)
    if c.serial then K.text(K.fonts.bitmore, "SERIAL NO. " .. c.serial, px + 6, y + 26) end
    if c.variant then K.text(K.fonts.bitmore, "VARIANT: " .. string.upper((c.variant:gsub("-", " "))), px + 6, y + 38) end
    gfx.drawLine(px + 6, 186, px + 150, 186)
    K.text(K.fonts.bitmore, "BOOK VALUE", px + 6, 192)
    K.text(K.fonts.big, K.money(c.value or 0), px + 150, 188, "right")
  end
  UI.hints("PAGE " .. self.page .. "/" .. pages(self) .. " (" .. #self.cards .. " CARDS)   D-PAD PICK   CRANK TURN PAGE   A ZOOM   B BACK")
end

---------------------------------------------------------------------------
-- zoomed card: flip, sell, fan page, redeem

local Z = { opaque = true }
Cards.zoomScene = Z

function Z:enter(args)
  self.card = args.card
  self.flip = 0           -- 0 = front, 1 = back (continuous with the crank)
  self.flipTarget = 0
  self.sel = 1
  self.stampT = nil
  self:buildActions()
  self.t = 0
end

function Z:buildActions()
  local c = self.card
  self.actions = { { key = "flip", label = "FLIP IT OVER" } }
  if not c.redeemed then self.actions[#self.actions + 1] = { key = "sell", label = "SELL ON BIDZ-R-US" } end
  if Sites and (Sites.Person or Sites.person) then self.actions[#self.actions + 1] = { key = "fan", label = "FAN PAGE" } end
  if c.redeem and not c.redeemed then
    self.actions[#self.actions + 1] = { key = "redeem", label = (c.redeem.kind == "retire") and "REDEEM: RETIRE HIM" or ("REDEEM: BOOST +" .. (c.redeem.boost or "")) }
  end
  if self.sel > #self.actions then self.sel = 1 end
end

function Z:upButtonDown() self.sel = (self.sel - 2) % #self.actions + 1; K.sfx("tick") end
function Z:downButtonDown() self.sel = self.sel % #self.actions + 1; K.sfx("tick") end
function Z:BButtonDown() App.pop(self.changed and "reload" or nil) end
function Z:cranked(c)
  self.flip = K.clamp(self.flip + c / 180, 0, 1)
  self.flipTarget = self.flip
end

function Z:redeem()
  local card = self.card
  local r = card.redeem
  local who = K.lastName(card.person and card.person.name or "He")
  local detail = r.detail
  if not detail then
    if r.kind == "retire" then
      detail = who .. " retires from baseball, today. His other cards become Final Season editions. The card is used up."
    else
      detail = who .. " gets +" .. (r.boost or "?") .. " for " .. (r.days or "?") .. " game days. The card is used up."
    end
  end
  App.push(UI.confirm("REDEEM THIS CARD?", detail .. " This can't be undone.", function()
    K.post("/cards/" .. card.id .. "/redeem", { confirm = true }, function(err, d)
      if err or not d then UI.toast(self, UI.errText(err)); K.sfx("buzz") return end
      UI.setAccount(d.account)
      if d.card then for k, v in pairs(d.card) do card[k] = v end end
      card.redeemed = true
      CR.trim(nil)
      self.flipTarget = 0
      self.stampT = 0
      self.changed = true
      self.resultText = (d.result or "Redeemed.") .. ((d.story and d.story.headline) and ("  BULLETIN: " .. d.story.headline) or "")
      self:buildActions()
      K.sfx("thud")
    end)
  end, "REDEEM"))
end

function Z:AButtonDown()
  local a = self.actions[self.sel]
  local card = self.card
  if a.key == "flip" then
    self.flipTarget = self.flipTarget < 0.5 and 1 or 0
    K.sfx("flip")
  elseif a.key == "sell" then
    App.push(Cards.sellScene, { card = card })
  elseif a.key == "fan" then
    if not UI.fanPage(card.person and card.person.id) then UI.toast(self, "Fan page is down for maintenance.") end
  elseif a.key == "redeem" then
    self:redeem()
  end
end

function Z:resume(result)
  if result == "listed" then self.changed = true; UI.toast(self, "Listed on Bidz-R-Us. Good luck.") end
end

function Z:update()
  self.t = self.t + 1 / 30
  UI.paper()
  self.flip = self.flip + (self.flipTarget - self.flip) * 0.25
  local card = self.card
  local u = self.flip
  local s = abs(math.cos(u * math.pi))
  if s < 0.03 then s = 0.03 end
  local img = (u < 0.5) and CR.front(card, "large") or CR.back(card, "large")
  local x, y = 30, 8
  gfx.setColor(gfx.kColorBlack)
  gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
  gfx.fillRect(x + 6, y + 6, 160 * s, 224)
  img:drawScaled(x + 80 - 80 * s, y, s, 1)
  if u < 0.1 and not card.redeemed then CR.flourish(card, x, y, 160, 224, self.t) end
  -- the stamp coming down: big, then thunk
  if self.stampT then
    self.stampT = self.stampT + 1 / 30
    local st = self.stampT
    if st < 0.22 then
      -- the stamp comes down from above the card...
      CR.stamp(x + 80, y + 101, 2.2 - st / 0.22 * 1.2)
    elseif st < 0.4 then
      -- ...and the card jolts
      img:drawScaled(x + 80 - 80 * s + ((floor(st * 40) % 2 == 0) and 1 or -1), y + 1, s, 1)
    end
  end
  -- side panel
  local px = 206
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(px, 8, 186, 214)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(px, 8, 186, 214)
  local r = CR.rarityOf(card)
  gfx.fillRect(px, 8, 186, 16)
  K.textW(K.fonts.nb, (CR.RARITY_LABEL[r] or r) .. (card.serial and ("  " .. card.serial) or ""), px + 93, 9, "center")
  local yy = 28
  for _, l in ipairs(K.wrap(K.fonts.slab, string.upper(card.person and card.person.name or "?"), 176)) do
    K.text(K.fonts.slab, l, px + 6, yy); yy = yy + 16
  end
  K.text(K.fonts.bitmore, "BOOK VALUE " .. K.money(card.value or 0), px + 6, yy + 2)
  yy = yy + 14
  if card.redeem then
    K.text(K.fonts.bitmore, K.fit(K.fonts.bitmore, card.redeemed and "REDEEMED" or ((card.front and card.front.redeem) or card.redeem.label or "REDEEMABLE"), 176), px + 6, yy + 2)
    yy = yy + 12
  end
  if card.finalSeason then K.text(K.fonts.bitmore, "FINAL SEASON", px + 6, yy + 2); yy = yy + 12 end
  yy = yy + 6
  for i, a in ipairs(self.actions) do
    local sel = i == self.sel
    local ry = yy + (i - 1) * 20
    if sel then gfx.setColor(gfx.kColorBlack); gfx.fillRect(px + 4, ry, 178, 18) end
    local label = a.label
    if a.key == "flip" then label = self.flipTarget < 0.5 and "FLIP IT OVER" or "FLIP IT BACK" end
    if sel then K.textW(K.fonts.nb, label, px + 10, ry + 2) else K.text(K.fonts.nb, label, px + 10, ry + 2) end
  end
  if self.resultText then
    local lines = K.wrap(K.fonts.bitmore, self.resultText, 174)
    for i, l in ipairs(lines) do if i <= 3 then K.text(K.fonts.bitmore, l, px + 6, 180 + (i - 1) * 11) end end
  end
  UI.hints("UP/DN CHOOSE   A DO IT   CRANK FLIP   B BACK")
  UI.drawToast(self)
end

-- dev/offline fallback for redeeming (only in fixture mode)
BCKit.offlinePost["POST /cards/.-/redeem"] = function(path, body)
  return BCKit.readJson("fixtures/redeem-boost.json") or { result = "Redeemed. The card is used up.", card = { redeemed = true } }
end
