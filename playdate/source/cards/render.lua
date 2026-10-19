-- Card rendering: vintage fronts (frame by rarity + dithered face-bank photo + nameplate),
-- snarky backs, misprint/original variants, and the rarity flourishes (gilded shimmer,
-- misprint glitch, original fanfare rays). Images are cached per card id + size.

import "ballcast/kit"
import "ballcast/puppets"

local gfx <const> = playdate.graphics
local floor <const>, sin <const>, cos <const> = math.floor, math.sin, math.cos

Cards = Cards or {}
local CR = {}
Cards.Render = CR
local K = BCKit

-- rects from images/README.md (x, y, w, h)
local LAYOUT = {
  small = { w = 110, h = 154, face = { 7, 7, 96, 120 }, name = { 6, 129, 98, 12 }, team = { 6, 142, 98, 9 },
            back = { title = { 8, 8, 94, 13 }, stats = { 8, 24, 94, 40 }, text = { 8, 68, 94, 66 }, rule = 9 } },
  large = { w = 160, h = 224, face = { 32, 28, 96, 120 }, name = { 14, 155, 132, 18 }, team = { 14, 175, 132, 13 }, serial = { 14, 190, 132, 11 },
            back = { title = { 10, 10, 140, 18 }, stats = { 10, 32, 140, 58 }, text = { 10, 95, 140, 100 }, rule = 11 } },
}
CR.LAYOUT = LAYOUT

local RARITY_LABEL = { common = "COMMON", uncommon = "UNCOMMON", rare = "RARE", gilded = "GILDED", misprint = "MISPRINT", original = "ORIGINAL" }
CR.RARITY_LABEL = RARITY_LABEL
local RANK = { common = 1, uncommon = 2, rare = 3, misprint = 4, gilded = 5, original = 6 }
CR.RANK = RANK

local function rarityOf(card)
  local r = string.lower(card.rarity or "common")
  if not RANK[r] then r = "common" end
  return r
end
CR.rarityOf = rarityOf

local function fonts(size)
  local F = K.fonts
  if size == "large" then return F.slab, F.bitmore, F.mono, F.nl end
  return F.nb, F.bitmore, F.bitmore, F.bitmore
end

local frameCache = {}
local function frameImage(kind, size)
  local L = LAYOUT[size]
  local path = "images/cards/" .. kind .. "-" .. L.w .. "x" .. L.h
  local img = frameCache[path]
  if img == nil then
    img = K.image(path) or false
    frameCache[path] = img
  end
  return img or nil
end

local function drawnFrame(r, L, back)
  -- fallback frame when the assets aren't there
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRoundRect(0, 0, L.w, L.h, 4)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRoundRect(2, 2, L.w - 4, L.h - 4, 3)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(5, 5, L.w - 10, L.h - 10)
  if r == "rare" or r == "original" then gfx.fillRect(L.team[1], L.team[2], L.team[3], L.team[4]) end
end

local function centered(font, s, rect, white)
  local w = font:getTextWidth(s)
  local x = rect[1] + (rect[3] - w) // 2
  local y = rect[2] + (rect[4] - font:getHeight()) // 2
  if white then gfx.setImageDrawMode(gfx.kDrawModeFillWhite) end
  font:drawText(s, x, y)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

local function fitText(font, s, w)
  return K.fit(font, s, w)
end

-- deterministic little helpers for variant art
local function thumbprint(x, y, r)
  gfx.setColor(gfx.kColorBlack)
  gfx.setDitherPattern(0.6, gfx.image.kDitherTypeBayer4x4)
  for i = 0, 4 do gfx.drawEllipseInRect(x - r + i * 2, y - r * 1.3 + i * 2, (r - i * 2) * 2, (r * 1.3 - i * 2) * 2) end
  gfx.setColor(gfx.kColorBlack)
end

local function hamStain(x, y, r)
  gfx.setDitherPattern(0.75, gfx.image.kDitherTypeBayer4x4)
  gfx.fillEllipseInRect(x - r, y - r * 0.7, r * 2, r * 1.4)
  gfx.fillEllipseInRect(x + r * 0.4, y - r, r, r * 0.8)
  gfx.setColor(gfx.kColorBlack)
end

local function variantOf(card)
  return string.lower(card.variant or "")
end

--- Front image for a card. size = "small" (110x154) | "large" (160x224).
local cache = {}
function CR.front(card, size)
  size = size or "small"
  local key = (card.id or "?") .. "/f/" .. size
  local img = cache[key]
  if img then return img end
  local L = LAYOUT[size]
  local r = rarityOf(card)
  local v = variantOf(card)
  img = gfx.image.new(L.w, L.h, gfx.kColorClear)
  gfx.pushContext(img)
  local frame = frameImage("front-" .. r, size)
  if frame then frame:draw(0, 0) else drawnFrame(r, L) end
  -- face
  local fx, fy, fw, fh = table.unpack(L.face)
  local face = K.face(card.person and card.person.face, 96)
  local flip = gfx.kImageUnflipped
  if v == "upside-down" then flip = gfx.kImageFlippedY end
  if v == "mirrored" then flip = gfx.kImageFlippedX end
  local ox, oy = 0, 0
  if r == "misprint" then ox, oy = floor(K.hash01(card.id, 3) * 3) - 1, floor(K.hash01(card.id, 4) * 3) - 1 end
  gfx.setClipRect(fx, fy, fw, fh)
  if v == "batboy" then
    -- that's the batboy: a tiny kid grinning where the star should be
    face:drawScaled(fx + fw / 2 - fw * 0.22, fy + fh * 0.42, 0.44)
  elseif v == "double-print" then
    face:draw(fx + 3, fy - 2, flip)
    gfx.setColor(gfx.kColorWhite)
    gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
    gfx.fillRect(fx, fy, fw, fh)
    face:draw(fx + ox, fy + oy, flip, nil)
    gfx.setImageDrawMode(gfx.kDrawModeWhiteTransparent)
    face:draw(fx - 2, fy + 1, flip)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
  else
    face:draw(fx + ox, fy + oy, flip)
  end
  if v == "no-ink" then
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(fx, fy + fh * 0.55, fw, fh)
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0.8, gfx.image.kDitherTypeBayer8x8)
    gfx.fillRect(fx, fy + fh * 0.48, fw, fh * 0.07)
  elseif v == "hand-tinted" then
    gfx.setColor(gfx.kColorWhite)
    gfx.setDitherPattern(0.85, gfx.image.kDitherTypeBayer4x4)
    gfx.fillRect(fx, fy, fw, fh * 0.45)
  end
  gfx.clearClipRect()
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(fx - 1, fy - 1, fw + 2, fh + 2)
  if v == "raccoon-photobomb" then
    local rimg = select(1, BallCast.Puppets.frame("critter", "raccoon1"))
    if rimg then
      local s = size == "large" and 2 or 1.5
      rimg:drawScaled(fx + fw - 24 * s - 2, fy + fh - 15 * s, s, s)
    end
  elseif v == "printers-thumb" then
    thumbprint(fx + fw * 0.7, fy + fh * 0.65, size == "large" and 14 or 10)
  elseif v == "ham-stain" then
    hamStain(fx + fw * 0.3, fy + fh * 0.8, size == "large" and 16 or 11)
  elseif v == "signed" then
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
    local x0, y0 = fx + 10, fy + fh - 22
    for i = 0, 7 do
      gfx.drawLine(x0 + i * 9, y0 + sin(i * 1.7) * 6, x0 + i * 9 + 9, y0 + sin((i + 1) * 1.7) * 6)
    end
    gfx.setLineWidth(1)
  elseif v == "printers-proof" or v == "test-stock" then
    gfx.setColor(gfx.kColorBlack)
    for _, c in ipairs({ { 1, 1 }, { L.w - 8, 1 }, { 1, L.h - 8 }, { L.w - 8, L.h - 8 } }) do
      gfx.drawLine(c[1], c[2] + 3, c[1] + 6, c[2] + 3)
      gfx.drawLine(c[1] + 3, c[2], c[1] + 3, c[2] + 6)
    end
  end
  -- nameplate + caption
  local nameFont, teamFont = fonts(size)
  local caption = (card.front and card.front.caption) or string.upper(card.person and card.person.name or "?")
  local name = caption:match("^([^,]+)") or caption
  local city = caption:match(",%s*(.+)$") or (card.team and string.upper(card.team.city or "")) or ""
  if v == "mirrored" then name = name:reverse() end
  gfx.setColor(gfx.kColorBlack)
  centered(nameFont, fitText(nameFont, name, L.name[3]), L.name)
  local pos = (card.front and card.front.pos) or (card.person and card.person.pos) or ""
  local teamLine = city .. (pos ~= "" and (" - " .. pos) or "")
  local darkTeam = (r == "rare" or r == "original")
  if size == "small" then
    centered(teamFont, fitText(teamFont, teamLine, L.team[3]), { L.team[1], L.team[2] - 1, L.team[3], L.team[4] }, darkTeam)
  else
    centered(teamFont, fitText(teamFont, teamLine, L.team[3]), { L.team[1], L.team[2] - 1, L.team[3], L.team[4] })
    local serial = card.serial and ("NO. " .. card.serial) or ("#" .. (card.number or "?") .. "  " .. (card.set or ""))
    centered(teamFont, fitText(teamFont, serial, L.serial[3]), L.serial, darkTeam)
  end
  CR.marks(card, L, size)
  gfx.popContext()
  cache[key] = img
  return img
end

--- Small printed marks: REDEEMABLE ribbon, FINAL SEASON tag, REDEEMED stamp.
function CR.marks(card, L, size)
  local f = K.fonts.bitmore
  if card.redeem and not card.redeemed then
    local label = (card.front and card.front.redeem) or card.redeem.label
      or ((card.redeem.kind == "retire") and "REDEEMABLE: RETIRES SUBJECT" or ("REDEEMABLE: BOOST +" .. (card.redeem.boost or "?") .. " FOR " .. (card.redeem.days or "?") .. " DAYS"))
    local w = math.min(L.w - 8, f:getTextWidth(label) + 6)
    local x = (L.w - w) // 2
    local y = size == "large" and 12 or 9
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x, y, w, 10)
    K.textW(f, K.fit(f, label, w - 4), L.w // 2, y, "center")
  end
  if card.finalSeason then
    local s = "FINAL SEASON"
    local w = f:getTextWidth(s) + 6
    local x, y = L.w - w - 6, (size == "large" and 136 or 112)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x, y, w, 10)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(x, y, w, 10)
    K.text(f, s, x + 3, y)
  end
  if card.redeemed then CR.stamp(L.w / 2, L.h * 0.45, size == "large" and 1 or 0.7) end
end

--- "REDEEMED" rubber stamp, slightly rotated, centred at (cx, cy).
local stampImg
function CR.stamp(cx, cy, scale)
  if not stampImg then
    local font = K.fonts.slab
    local s = "REDEEMED"
    local w, h = font:getTextWidth(s) + 20, font:getHeight() + 12
    local img = gfx.image.new(w, h, gfx.kColorClear)
    gfx.pushContext(img)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRoundRect(0, 0, w, h, 5)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(3)
    gfx.drawRoundRect(1, 1, w - 2, h - 2, 5)
    gfx.setLineWidth(1)
    gfx.drawRoundRect(5, 5, w - 10, h - 10, 3)
    gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
    font:drawText(s, 10, 6)
    font:drawText(s, 11, 6)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    -- worn ink
    gfx.setColor(gfx.kColorWhite)
    for i = 1, 30 do gfx.fillRect(floor(K.hash01(i, 3) * w), floor(K.hash01(i, 8) * h), 1, 1) end
    gfx.popContext()
    stampImg = img
  end
  local w, h = stampImg:getSize()
  if scale == 1 then stampImg:draw(cx - w / 2, cy - h / 2) else stampImg:drawScaled(cx - w * scale / 2, cy - h * scale / 2, scale) end
end

--- Back image (snarky writing + stats).
function CR.back(card, size)
  size = size or "small"
  local key = (card.id or "?") .. "/b/" .. size
  local img = cache[key]
  if img then return img end
  local L = LAYOUT[size]
  local B = L.back
  img = gfx.image.new(L.w, L.h, gfx.kColorClear)
  gfx.pushContext(img)
  local frame = frameImage("back", size)
  if frame then frame:draw(0, 0) else drawnFrame("common", L, true); gfx.setColor(gfx.kColorBlack); gfx.fillRect(B.title[1], B.title[2], B.title[3], B.title[4]) end
  local nameFont, _, statFont, textFont = fonts(size)
  local blank = variantOf(card) == "blank-back"
  local title = string.upper(card.person and card.person.name or "?")
  centered(nameFont, fitText(nameFont, title, B.title[3] - 4), B.title, true)
  local back = card.back or {}
  if not blank then
    -- stats table: columns spread evenly
    local rows = back.stats or {}
    local sx, sy, sw = B.stats[1] + 2, B.stats[2] + 1, B.stats[3] - 4
    for ri, row in ipairs(rows) do
      if ri > 4 then break end
      local n = #row
      for ci, cell in ipairs(row) do
        local cw = sw / n
        local s = tostring(cell)
        local w = statFont:getTextWidth(s)
        statFont:drawText(s, floor(sx + (ci - 1) * cw + (cw - w) / 2), sy + (ri - 1) * B.rule)
      end
    end
    -- the writing
    local text = table.concat(back.lines or {}, " ")
    local lines = K.wrap(textFont, text, B.text[3])
    local lh = textFont:getHeight() + (size == "large" and 1 or 0)
    local maxLines = floor(B.text[4] / lh)
    for i = 1, math.min(#lines, maxLines) do
      textFont:drawText(lines[i], B.text[1], B.text[2] + (i - 1) * lh)
    end
  else
    K.text(textFont, "(intentionally left blank)", B.text[1] + B.text[3] / 2, B.text[2] + 20, "center")
  end
  if card.redeem and not card.redeemed then
    local f = K.fonts.bitmore
    local y = B.text[2] + B.text[4] - 11
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(B.text[1], y, B.text[3], 11)
    local label = (card.front and card.front.redeem) or card.redeem.label or "REDEEMABLE"
    K.textW(f, K.fit(f, label, B.text[3] - 4), B.text[1] + B.text[3] // 2, y + 1, "center")
  end
  if card.redeemed then CR.stamp(L.w / 2, L.h * 0.45, size == "large" and 1 or 0.7) end
  gfx.popContext()
  cache[key] = img
  return img
end

local thumbCache = {}
--- Scaled front for grids. Keeps a small LRU-ish cap.
function CR.thumb(card, scale)
  local key = (card.id or "?") .. "@" .. scale
  local img = thumbCache[key]
  if img then return img end
  img = CR.front(card, "small"):scaledImage(scale)
  thumbCache[key] = img
  return img
end

local backThumb = {}
function CR.backThumb(scale)
  local img = backThumb[scale]
  if img then return img end
  local b = frameImage("back", "small")
  if not b then
    b = gfx.image.new(110, 154, gfx.kColorClear)
    gfx.pushContext(b)
    drawnFrame("common", LAYOUT.small, true)
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0.5, gfx.image.kDitherTypeDiagonalLine)
    gfx.fillRect(10, 10, 90, 134)
    gfx.popContext()
  end
  img = scale == 1 and b or b:scaledImage(scale)
  backThumb[scale] = img
  return img
end

--- Free cached images for cards not in `keep` (a set of ids), or everything.
function CR.trim(keep)
  for k in pairs(cache) do
    local id = k:match("^(.-)/")
    if not keep or not keep[id] then cache[k] = nil end
  end
  for k in pairs(thumbCache) do
    local id = k:match("^(.-)@")
    if not keep or not keep[id] then thumbCache[k] = nil end
  end
end

function CR.release()
  cache, thumbCache, backThumb, frameCache = {}, {}, {}, {}
  stampImg = nil
end

---------------------------------------------------------------------------
-- flourishes, drawn over a card at (x, y) of size (w, h); t = seconds since reveal

-- white sparkle pattern with a mask (16 numbers: 8 rows + 8 mask rows)
local function sparkle(phase)
  local rows, mask = {}, {}
  for i = 1, 8 do
    rows[i] = 0xFF
    local m = 0
    local k = (i + phase) % 8
    m = (0x81 >> (k % 4)) | (0x18 << (k % 3))
    mask[i] = m & 0xFF
  end
  local p = {}
  for i = 1, 8 do p[i] = rows[i] end
  for i = 1, 8 do p[8 + i] = mask[i] end
  return p
end

function CR.flourish(card, x, y, w, h, t)
  local r = rarityOf(card)
  if r == "gilded" then
    -- a diagonal band of shimmer sweeps across, every 1.6 s
    local u = (t % 1.6) / 1.6
    local bx = x - w + u * (w * 3)
    gfx.setClipRect(x, y, w, h)
    gfx.setPattern(sparkle(floor(t * 12)))
    gfx.fillPolygon(bx, y, bx + 26, y, bx + 26 - h * 0.5, y + h, bx - h * 0.5, y + h)
    gfx.setColor(gfx.kColorWhite)
    gfx.setDitherPattern(0.3, gfx.image.kDitherTypeBayer4x4)
    gfx.fillPolygon(bx + 8, y, bx + 14, y, bx + 14 - h * 0.5, y + h, bx + 8 - h * 0.5, y + h)
    gfx.clearClipRect()
    gfx.setColor(gfx.kColorBlack)
    -- twinkles on the border
    for i = 0, 3 do
      local a = t * 3 + i * 1.7
      local px = x + (sin(a) * 0.5 + 0.5) * w
      local py = y + (i % 2 == 0 and 2 or h - 3)
      gfx.setColor(gfx.kColorWhite)
      gfx.drawLine(px - 3, py, px + 3, py)
      gfx.drawLine(px, py - 3, px, py + 3)
    end
    gfx.setColor(gfx.kColorBlack)
  elseif r == "misprint" then
    -- glitch: for the first second, slices jump and invert
    if t < 1.2 and floor(t * 15) % 3 ~= 0 then
      for i = 0, 5 do
        local sy = y + floor(K.hash01(floor(t * 15) * 7 + i, 5) * h)
        local sh = 2 + floor(K.hash01(i, floor(t * 15)) * 8)
        local dx = floor((K.hash01(i * 3, floor(t * 20)) - 0.5) * 14)
        gfx.setColor(gfx.kColorXOR)
        gfx.fillRect(x + dx, sy, w, sh)
      end
      gfx.setColor(gfx.kColorBlack)
    end
  elseif r == "original" then
    -- rays behind are drawn by CR.rays(); stamp "1 OF 1"
    if t > 0.4 then
      local s = "1 OF 1"
      local f = K.fonts.nb
      local sw = f:getTextWidth(s) + 8
      local sx, sy = x + w - sw - 2, y + 10
      gfx.setColor(gfx.kColorBlack)
      gfx.fillRect(sx, sy, sw, 15)
      K.textW(f, s, sx + 4, sy + 1)
    end
  end
end

--- Rotating sunburst behind a card (original / gilded fanfare).
function CR.rays(cx, cy, t, n, dark)
  n = n or 12
  gfx.setColor(gfx.kColorBlack)
  if not dark then gfx.setDitherPattern(0.6, gfx.image.kDitherTypeBayer4x4) end
  local R = 320
  for i = 0, n - 1 do
    local a0 = t * 0.6 + i * (2 * math.pi / n)
    local a1 = a0 + math.pi / n
    gfx.fillTriangle(cx, cy, cx + cos(a0) * R, cy + sin(a0) * R, cx + cos(a1) * R, cy + sin(a1) * R)
  end
  gfx.setColor(gfx.kColorBlack)
end

--- One-shot sound for a reveal (prefers the audio agent's cues).
function CR.revealSound(card)
  local r = rarityOf(card)
  local A = _G.Audio
  if type(A) == "table" and A.stinger and (r == "original" or r == "gilded") then pcall(A.stinger, "pack_opened") end
  if r == "gilded" then K.sfx("chime")
  elseif r == "misprint" then K.sfx("glitch")
  elseif r == "original" then K.sfx("fanfare")
  elseif r == "rare" then K.sfx("chime")
  else K.sfx("flip") end
end
