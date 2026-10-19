-- Pack opening: crank tears the wrapper, cards slide out face-down, each one flips over
-- (A or a quarter turn of the crank) with a rarity flourish; summary at the end.
-- Entered with { kind = "wax", name = "Wax Pack", cards = { CardView... } }.

import "ballcast/kit"
import "cards/ui"
import "cards/render"

local gfx <const> = playdate.graphics
local floor <const>, abs <const>, min <const>, max <const> = math.floor, math.abs, math.min, math.max

Cards = Cards or {}
local K = BCKit
local UI = Cards.UI
local CR = Cards.Render

local S = { opaque = true }
Cards.packOpenScene = S

local CARD_X, CARD_Y = 145, 40

-- the audio agent's cues when present (see audio/README.md), else our synth blips
local function cue(name, fallback, kind)
  local A = _G.Audio
  if type(A) == "table" and A[kind or "sfx"] then
    local ok, r = pcall(A[kind or "sfx"], name)
    if ok and r ~= false then return end
  end
  if fallback then BCKit.sfx(fallback) end
end

-- paper rip while cranking: the real recorded tear, throttled so takes don't pile up.
-- (Retriggering a noise voice at random pitches every few frames warbled badly.)
local tearVoice
local lastTearMs = -1000
local function tearNoise(amount)
  local now = playdate.getCurrentTimeMilliseconds()
  if now - lastTearMs < 350 then return end
  lastTearMs = now
  local A = _G.Audio
  if type(A) == "table" and A.sfx then
    local ok, r = pcall(A.sfx, "pack_tear", math.min(1, 0.5 + amount))
    if ok and r ~= false then return end
  end
  -- fallback: one short burst at a fixed pitch
  tearVoice = tearVoice or K.voice("tear", playdate.sound.kWaveNoise, 0, 0.06, 0, 0.04, 0.3)
  tearVoice:playNote(1800, math.min(1, 0.3 + amount), 0.06)
end

function S:enter(args)
  args = args or {}
  self.kind = args.kind or "wax"
  self.name = args.name
  self.cards = args.cards or {}
  self.stage = "tear"
  self.progress = 0
  self.auto = false
  self.t = 0
  self.stageT = 0
  self.idx = 1
  self.flipT = nil
  self.revealT = nil
  self.crankAcc = 0
  self.lastFrame = 1
  local tbl = "images/cards/pack-" .. self.kind .. "-open"
  self.tear = playdate.file.exists(tbl .. "-table-112-160.pdt") and gfx.imagetable.new(tbl) or nil
  if not self.tear and playdate.file.exists(tbl .. ".pdt") then self.tear = gfx.imagetable.new(tbl) end
  self.pack = Cards.packImage and Cards.packImage(self.kind)
  self.total = 0
  for _, c in ipairs(self.cards) do self.total = self.total + (c.value or 0) end
  -- best pull
  self.best = nil
  for _, c in ipairs(self.cards) do
    if not self.best or (CR.RANK[CR.rarityOf(c)] or 0) > (CR.RANK[CR.rarityOf(self.best)] or 0) or ((c.value or 0) > (self.best.value or 0) and CR.rarityOf(c) == CR.rarityOf(self.best)) then self.best = c end
  end
  self.lastMs = playdate.getCurrentTimeMilliseconds()
end

function S:exit()
  CR.trim(nil)
end

local function setStage(self, st) self.stage = st; self.stageT = 0 end

function S:advance()
  if self.stage == "tear" then
    self.auto = true
  elseif self.stage == "reveal" then
    if not self.flipT and not self.revealT then
      self.flipT = 0
      cue("card_flip", "flip")
    elseif self.revealT and self.revealT > 0.35 then
      if self.idx < #self.cards then
        self.idx = self.idx + 1
        self.flipT, self.revealT = nil, nil
        self.slideT = 0
      else
        setStage(self, "summary")
        cue("card_shuffle", "chime")
      end
    end
  elseif self.stage == "summary" then
    App.pop()
    if Cards.binderScene then App.push(Cards.binderScene, { highlight = self.best and self.best.id }) end
  end
end

function S:AButtonDown() self:advance() end
function S:BButtonDown()
  if self.stage == "summary" or #self.cards == 0 then App.pop() return end
  -- skip ahead: reveal everything
  if self.stage == "tear" then self.auto = true return end
  setStage(self, "summary")
end
function S:downButtonDown() self:advance() end

function S:cranked(change)
  if self.stage == "tear" then
    if change > 0 then
      local before = self.progress
      self.progress = min(1, self.progress + change / 300)
      self.crankAcc = self.crankAcc + change
      if self.crankAcc > 18 then self.crankAcc = 0; tearNoise(change / 30) end
      if before < 1 and self.progress >= 1 then self:torn() end
    end
  elseif self.stage == "reveal" then
    self.crankAcc = self.crankAcc + abs(change)
    if self.crankAcc > 90 then self.crankAcc = 0; self:advance() end
  end
end

function S:torn()
  setStage(self, "slide")
  cue("pack_tear", "thud")
end

local function drawPack(self, frame, x, y, jx)
  local img = self.tear and self.tear:getImage(frame) or self.pack
  if img then
    img:draw(x + (jx or 0), y)
  else
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x, y, 112, 160)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x + 8, y + 30, 96, 60)
    gfx.setColor(gfx.kColorBlack)
    K.text(K.fonts.slab, "BASE BALL", x + 56, y + 46, "center")
    if frame >= 3 then
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(x, y, 112, 14)
    end
  end
end

function S:update()
  local now = playdate.getCurrentTimeMilliseconds()
  local dt = min(0.1, (now - self.lastMs) / 1000)
  self.lastMs = now
  self.t = self.t + dt
  self.stageT = self.stageT + dt
  UI.paper()
  local name = string.upper(self.name or (self.kind .. " pack"))
  UI.header(name)

  if self.stage == "tear" then
    if self.auto then
      self.progress = min(1, self.progress + dt * 1.8)
      if floor(self.t * 20) % 3 == 0 then tearNoise(0.5) end
      if self.progress >= 1 then self:torn() end
    end
    local frame = 1 + min(3, floor(self.progress * 3.999))
    if frame ~= self.lastFrame then self.lastFrame = frame end
    local jx = (self.progress > 0 and self.progress < 1) and (floor(self.t * 30) % 2) or 0
    drawPack(self, frame, 144, 50, jx)
    -- tear meter: a dotted line along the top edge that fills as you crank
    gfx.setColor(gfx.kColorBlack)
    for i = 0, 27 do
      local x = 144 + i * 4
      if i / 28 < self.progress then gfx.fillRect(x, 44, 3, 2) else gfx.fillRect(x + 1, 44, 1, 1) end
    end
    local tip = (playdate.isCrankDocked and playdate.isCrankDocked()) and "UNDOCK THE CRANK TO TEAR - OR PRESS A" or "TURN THE CRANK TO TEAR IT OPEN - OR PRESS A"
    UI.hints(tip)
    return
  end

  if self.stage == "slide" then
    local u = min(1, self.stageT / 0.9)
    -- pack drops away, the stack of cards rises out of it
    local e = u * u
    local packY = 50 + e * 220
    local stackY = 50 + 10 - u * 30
    local back = CR.backThumb(1)
    for i = min(4, #self.cards), 1, -1 do
      back:draw(CARD_X + i * 2 - 1, min(stackY + i * 2, packY + 4))
    end
    drawPack(self, self.tear and min(4, self.tear:getLength()) or 4, 144, packY)
    if u >= 1 then setStage(self, "reveal"); self.slideT = 1 end
    UI.hints("")
    return
  end

  if self.stage == "reveal" then
    local card = self.cards[self.idx]
    if not card then setStage(self, "summary") return end
    local r = CR.rarityOf(card)
    -- revealed pile at left, face-down stack at right
    for i = 1, self.idx - 1 do
      local th = CR.thumb(self.cards[i], 0.4)
      th:draw(14 + (i - 1) * 4, 60 + (i - 1) * 3)
    end
    local back = CR.backThumb(0.4)
    for i = self.idx + 1, #self.cards do
      back:draw(338 - (i - self.idx) * 3, 60 + (i - self.idx) * 3)
    end
    -- slide in
    local x, y = CARD_X, CARD_Y
    if self.slideT and self.slideT < 1 then
      self.slideT = self.slideT + dt * 4
      local u = min(1, self.slideT)
      x = floor(338 + (CARD_X - 338) * (1 - (1 - u) * (1 - u)))
    end
    -- rarity backdrop (behind the card) once revealed
    if self.revealT then
      if r == "original" then CR.rays(x + 55, y + 77, self.revealT, 14, true)
      elseif r == "gilded" then CR.rays(x + 55, y + 77, self.revealT * 0.5, 10, false) end
    end
    if self.flipT then
      self.flipT = self.flipT + dt
      local u = min(1, self.flipT / 0.32)
      local s = math.abs(math.cos(u * math.pi))
      local img = (u < 0.5) and CR.backThumb(1) or CR.front(card, "small")
      if s < 0.04 then s = 0.04 end
      -- lift: a little hop while flipping
      local hop = math.sin(u * math.pi) * 8
      img:drawScaled(x + 55 - 55 * s, y - hop, s, 1)
      if u >= 1 then
        self.flipT = nil
        self.revealT = 0
        CR.revealSound(card)
      end
    elseif self.revealT then
      self.revealT = self.revealT + dt
      local img = CR.front(card, "small")
      local shake = (r == "misprint" and self.revealT < 0.8) and ((floor(self.revealT * 30) % 3) - 1) or 0
      img:draw(x + shake, y)
      CR.flourish(card, x + shake, y, 110, 154, self.revealT)
    else
      CR.backThumb(1):draw(x, y)
      if floor(self.t * 2) % 2 == 0 then
        K.text(K.fonts.nb, "?", x + 55, y + 70, "center")
      end
    end
    -- caption strip
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(60, 198, 280, 26)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(60, 198, 280, 26)
    if self.revealT then
      local label = CR.RARITY_LABEL[r] or string.upper(r)
      local who = card.person and card.person.name or "?"
      K.text(K.fonts.nb, K.fit(K.fonts.nb, string.upper(who), 180), 66, 200)
      K.text(K.fonts.bitmore, label .. (card.serial and ("  NO. " .. card.serial) or ""), 66, 213)
      K.text(K.fonts.nb, K.money(card.value or 0), 334, 205, "right")
      if r ~= "common" and r ~= "uncommon" and self.revealT < 1.6 then
        local big = ({ rare = "RARE!", gilded = "GILDED!", misprint = "MISPRINT?!", original = "AN ORIGINAL!" })[r]
        if big then
          -- the banner takes over the header strip
          gfx.setColor(gfx.kColorBlack)
          gfx.fillRect(0, 0, 400, 30)
          K.textW(K.fonts.big, big, 200, 2 + floor(math.sin(self.revealT * 14) * 2), "center")
        end
      end
    else
      K.text(K.fonts.nb, "CARD " .. self.idx .. " OF " .. #self.cards, 200, 204, "center")
    end
    UI.hints(self.revealT and "A NEXT CARD   B SKIP TO SUMMARY" or "A / CRANK  FLIP IT")
    return
  end

  -- summary
  local n = #self.cards
  local scale = 0.45
  local cw, ch = floor(110 * scale), floor(154 * scale)
  local perRow = min(5, n)
  local rows = math.ceil(n / perRow)
  local gx = 200 - (perRow * (cw + 6) - 6) / 2
  local gy = 26
  for i, c in ipairs(self.cards) do
    local col = (i - 1) % perRow
    local row = floor((i - 1) / perRow)
    local x, y = gx + col * (cw + 6), gy + row * (ch + 4)
    CR.thumb(c, scale):draw(x, y)
    if self.best and c.id == self.best.id then
      gfx.setColor(gfx.kColorBlack)
      gfx.setLineWidth(2)
      gfx.drawRect(x - 2, y - 2, cw + 4, ch + 4)
      gfx.setLineWidth(1)
    end
  end
  local y = gy + rows * (ch + 4) + 2
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(40, y, 320, 34)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(40, y, 320, 34)
  K.text(K.fonts.nb, n .. " CARDS   BOOK VALUE " .. K.money(self.total), 200, y + 3, "center")
  if self.best then
    K.text(K.fonts.bitmore, "BEST PULL: " .. string.upper(self.best.person and self.best.person.name or "?") .. " (" .. (CR.RARITY_LABEL[CR.rarityOf(self.best)] or "") .. ")", 200, y + 20, "center")
  end
  UI.hints("A TO THE BINDER   B BACK TO THE COUNTER")
end
