-- DBN broadcast package: prerendered art and cheap per-frame effects.
--
-- Everything with text is rendered once into an image (cached by key) and then only blitted,
-- clipped, offset or dither-faded per frame. Per-frame drawing is limited to a few polygons,
-- rects and pattern fills (all C in the SDK).

import "ballcast/kit"

local gfx <const> = playdate.graphics
local floor <const>, sin <const>, cos <const>, abs <const>, min <const>, max <const> = math.floor, math.sin, math.cos, math.abs, math.min, math.max
local pi <const> = math.pi

BallCast = BallCast or {}
local A = {}
BallCast.TVArt = A
local K = BCKit

---------------------------------------------------------------------------
-- settings shared by the package

A.reduce = false   -- Game.settings.reduceMotion: no flashes, shakes or spins; wipes dissolve

local fontCache = {}
local FONTS = { wa = "fonts/Deadball-WordArt", waBig = "fonts/Deadball-WordArt-Big", serifb = "fonts/Newsleak-Serif-Bold",
  cub = "fonts/Cuberick-Bold", rob11 = "fonts/Roobert-11-Medium", okla = "fonts/Oklahoma-Bold" }
function A.font(k)
  local f = fontCache[k]
  if f then return f end
  if FONTS[k] then
    if playdate.file.exists(FONTS[k] .. ".pft") or playdate.file.exists(FONTS[k] .. ".fnt") then f = gfx.font.new(FONTS[k]) end
    f = f or K.fonts[k == "serifb" and "serifb" or "big"]
  else
    f = K.fonts[k]
  end
  fontCache[k] = f
  return f
end

---------------------------------------------------------------------------
-- text images

local txtCache = {}
local txtCount = 0

--- Text rendered once. style: "w" white glyphs, "b" black glyphs, "wo" white with a black
--- outline (readable on anything), "bo" black with a white outline, "wa" WordArt as drawn.
function A.text(fontKey, s, style, pad)
  style = style or "wo"
  local key = fontKey .. "|" .. style .. "|" .. s
  local img = txtCache[key]
  if img then return img end
  local t0 = playdate.getElapsedTime()
  local f = A.font(fontKey)
  pad = pad or ((style == "wo" or style == "bo") and 2 or 0)
  local w, h = K.textWidth(f, s) + pad * 2, f:getHeight() + pad * 2
  img = gfx.image.new(math.max(1, w), math.max(1, h), gfx.kColorClear)
  gfx.pushContext(img)
  if style == "wo" or style == "bo" then
    gfx.setImageDrawMode(style == "wo" and gfx.kDrawModeFillBlack or gfx.kDrawModeFillWhite)
    for dx = -pad, pad do for dy = -pad, pad do
      if dx ~= 0 or dy ~= 0 then K.text(f, s, pad + dx, pad + dy) end
    end end
    gfx.setImageDrawMode(style == "wo" and gfx.kDrawModeFillWhite or gfx.kDrawModeFillBlack)
    K.text(f, s, pad, pad)
  elseif style == "w" then
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    K.text(f, s, pad, pad)
  elseif style == "b" then
    gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
    K.text(f, s, pad, pad)
  else
    K.text(f, s, pad, pad)
  end
  gfx.popContext()
  txtCache[key] = img
  txtCount = txtCount + 1
  if A.onBuild then A.onBuild("text '" .. s .. "'", t0)
  else
    local ms = (playdate.getElapsedTime() - t0) * 1000
    if ms > 4 then print(string.format("[bctv] text built in %.1f ms: %s", ms, s)) end
  end
  return img
end

--- draw a cached text image centred / right-aligned at x
function A.drawText(fontKey, s, x, y, align, style)
  local img = A.text(fontKey, s, style)
  local w = img:getSize()
  if align == "center" then x = x - w // 2 elseif align == "right" then x = x - w end
  img:draw(x, y)
  return img
end

---------------------------------------------------------------------------
-- patterns

-- 8x8 diagonal stripes (4 on / 4 off), phase-shifted by rotating the rows
local DIAG = { 0x0F, 0x1E, 0x3C, 0x78, 0xF0, 0xE1, 0xC3, 0x87 }
local diagPat = {}
for ph = 0, 7 do
  local p = {}
  for r = 1, 8 do p[r] = DIAG[(r - 1 + ph) % 8 + 1] end
  diagPat[ph] = p
end
function A.stripes(x, y, w, h, phase)
  gfx.setPattern(diagPat[floor(phase or 0) % 8])
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
end
A.CHECK = { 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 }
A.SCAN = { 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00 }   -- every other row: CRT scanlines

--- solid black with dither alpha a (0 = clear, 1 = solid black)
function A.shade(x, y, w, h, a, white)
  if a <= 0 then return end
  gfx.setColor(white and gfx.kColorWhite or gfx.kColorBlack)
  -- (setDitherPattern's alpha is transparency, for either colour)
  if a < 1 then gfx.setDitherPattern(1 - a, gfx.image.kDitherTypeBayer8x8) end
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
end

---------------------------------------------------------------------------
-- easing

function A.ease(t) t = K.clamp(t, 0, 1); return 1 - (1 - t) * (1 - t) * (1 - t) end
function A.easeIn(t) t = K.clamp(t, 0, 1); return t * t end
--- overshoot: 0 → 1.1 → 1
function A.back(t)
  t = K.clamp(t, 0, 1)
  local s = 1.9
  t = t - 1
  return t * t * ((s + 1) * t + s) + 1
end

---------------------------------------------------------------------------
-- the DBN logo: a stretched diamond with "DBN" in WordArt and baseball stitches

local logoImg, bugImg, bugLive
local function diamondPoly(cx, cy, rw, rh) return cx, cy - rh, cx + rw, cy, cx, cy + rh, cx - rw, cy end
A.diamondPoly = diamondPoly

local function stitches(cx, cy, rw, rh, s)
  -- two seams of short ticks near the left and right points
  gfx.setColor(gfx.kColorWhite)
  for side = -1, 1, 2 do
    for k = -2, 2 do
      local a = k * 0.32
      local x = cx + side * (rw - 11 * s) + side * cos(a) * 6 * s
      local y = cy + sin(a) * 9 * s
      gfx.drawLine(x - 2 * s, y, x + 2 * s, y)
    end
  end
end

function A.logo()
  if logoImg then return logoImg end
  local w, h = 150, 64
  logoImg = gfx.image.new(w, h, gfx.kColorClear)
  gfx.pushContext(logoImg)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillPolygon(diamondPoly(75, 32, 74, 31))
  gfx.setColor(gfx.kColorWhite)
  gfx.setLineWidth(2)
  gfx.drawPolygon(diamondPoly(75, 32, 67, 26))
  gfx.setLineWidth(1)
  stitches(75, 32, 67, 26, 1)
  local t = A.text("waBig", "DBN", "wa")
  local tw, th = t:getSize()
  t:draw(75 - tw // 2, 32 - th // 2)
  gfx.popContext()
  return logoImg
end

--- corner bug: small logo + "DBN" + optional "LIVE"
function A.bug(live)
  if bugImg and bugLive == live then return bugImg end
  bugLive = live
  -- as wide as its words: a fixed 50 px clipped "DBN LIVE" to "DBN L"
  local label = live and "DBN LIVE" or "DBN"
  local w, h = math.max(50, 18 + K.fonts.tiny:getTextWidth(label) + 4), 18
  bugImg = gfx.image.new(w, h, gfx.kColorClear)
  gfx.pushContext(bugImg)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillPolygon(diamondPoly(9, 9, 9, 8))
  gfx.setColor(gfx.kColorWhite)
  gfx.drawPolygon(diamondPoly(9, 9, 6, 5))
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(14, 3, w - 15, 12)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  K.fonts.tiny:drawText(label, 18, 5)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.popContext()
  return bugImg
end

--- the spinning diamond (live polygons): spin = radians about the vertical axis
function A.spinDiamond(cx, cy, r, spin, rings)
  local c = cos(spin)
  local rw = math.max(1, abs(c) * r * 1.35)
  local face = c >= 0
  gfx.setColor(face and gfx.kColorBlack or gfx.kColorWhite)
  gfx.fillPolygon(diamondPoly(cx, cy, rw, r))
  gfx.setColor(face and gfx.kColorWhite or gfx.kColorBlack)
  if rw > 6 then
    gfx.setLineWidth(r > 40 and 3 or 2)
    gfx.drawPolygon(diamondPoly(cx, cy, rw * 0.86, r * 0.84))
    if rings then gfx.drawPolygon(diamondPoly(cx, cy, rw * 0.6, r * 0.6)) end
    gfx.setLineWidth(1)
  end
  gfx.setColor(gfx.kColorBlack)
end

---------------------------------------------------------------------------
-- starburst (alternating wedges), radial "warp" streaks, dither rings

function A.burst(cx, cy, r, rot, n, white)
  n = n or 12
  gfx.setColor(white and gfx.kColorWhite or gfx.kColorBlack)
  local step = 2 * pi / n
  for i = 0, n - 1 do
    local a0 = rot + i * step
    local a1 = a0 + step * 0.5
    gfx.fillTriangle(cx, cy, cx + cos(a0) * r, cy + sin(a0) * r, cx + cos(a1) * r, cy + sin(a1) * r)
  end
  gfx.setColor(gfx.kColorBlack)
end

function A.warp(cx, cy, t, n, white)
  gfx.setColor(white and gfx.kColorWhite or gfx.kColorBlack)
  n = n or 28
  for i = 0, n - 1 do
    local a = i * 2.39996 -- golden angle
    local sp = 0.6 + (i * 37 % 11) / 11
    local r0 = ((t * 420 * sp + i * 53) % 300) + 10
    local r1 = r0 + 18 + r0 * 0.25
    gfx.setLineWidth(r0 > 140 and 2 or 1)
    gfx.drawLine(cx + cos(a) * r0, cy + sin(a) * r0 * 0.7, cx + cos(a) * r1, cy + sin(a) * r1 * 0.7)
  end
  gfx.setLineWidth(1)
  gfx.setColor(gfx.kColorBlack)
end

function A.ring(cx, cy, r, w, a)
  if r <= 0 then return end
  gfx.setColor(gfx.kColorWhite)
  if a and a < 1 then gfx.setDitherPattern(1 - a, gfx.image.kDitherTypeBayer4x4) end
  gfx.setLineWidth(w or 4)
  gfx.drawCircleAtPoint(cx, cy, r)
  gfx.setLineWidth(1)
  gfx.setColor(gfx.kColorBlack)
end

--- full-screen XOR flash (not with reduce motion)
function A.flash()
  if A.reduce then return end
  gfx.setColor(gfx.kColorXOR)
  gfx.fillRect(0, 0, 400, 240)
  gfx.setColor(gfx.kColorBlack)
end

--- a diagonal glint across an image's area (XOR band), u = 0..1 across
function A.glint(x, y, w, h, u)
  if u <= 0 or u >= 1 then return end
  local gx = x - h + (w + h * 2) * u
  gfx.setScreenClipRect(x, y, w, h)
  gfx.setColor(gfx.kColorXOR)
  gfx.fillPolygon(gx, y, gx + 10, y, gx + 10 - h, y + h, gx - h, y + h)
  gfx.setColor(gfx.kColorBlack)
  gfx.clearClipRect()
end

---------------------------------------------------------------------------
-- seven-segment digits (radar gun): prerendered 12x20, lit black on the LCD, unlit ghosted

local SEG = {   -- a b c d e f g
  [0] = "abcdef", "bc", "abged", "abgcd", "fgbc", "afgcd", "afgedc", "abc", "abcdefg", "abcfgd",
}
local digits
-- segment rects in a 12x21 cell (blocky LCD)
local SEGR = { a = { 2, 0, 8, 3 }, f = { 0, 2, 3, 8 }, b = { 9, 2, 3, 8 }, g = { 2, 9, 8, 3 },
  e = { 0, 11, 3, 8 }, c = { 9, 11, 3, 8 }, d = { 2, 18, 8, 3 } }
function A.digit(d)
  if not digits then
    digits = {}
    for n = 0, 10 do
      local img = gfx.image.new(12, 21, gfx.kColorClear)
      gfx.pushContext(img)
      for sname, r in pairs(SEGR) do
        local lit = n <= 9 and SEG[n]:find(sname, 1, true)
        gfx.setColor(gfx.kColorBlack)
        if not lit then gfx.setDitherPattern(0.85, gfx.image.kDitherTypeBayer2x2) end
        gfx.fillRect(r[1], r[2], r[3], r[4])
      end
      gfx.popContext()
      digits[n] = img
    end
  end
  return digits[d] or digits[10]
end

---------------------------------------------------------------------------
-- photos (preloaded in the loader: no disk reads mid-replay)

local faces = {}       -- face num -> 48x60 image
local faces2x = {}     -- face num -> 96x120 pixel-doubled
local photos = {}      -- archive id -> 96x72 image (false = missing)

function A.preloadFace(face)
  local n = K.faceNum(face)
  if faces[n] then return end
  faces[n] = K.face(face, 48)
end
function A.face(face)
  local n = K.faceNum(face)
  local img = faces[n]
  if not img then img = K.face(face, 48); faces[n] = img end   -- (only if not preloaded)
  return img
end
function A.face2x(face)
  local n = K.faceNum(face)
  local img = faces2x[n]
  if img then return img end
  img = A.face(face):scaledImage(2)
  faces2x[n] = img
  return img
end
function A.preloadPhoto(id)
  if photos[id] ~= nil then return end
  local img = Packs and Packs.loadImage and Packs.loadImage("images/archive", id, 96) or nil
  photos[id] = img or false
end
function A.photo(id) return id and photos[id] or nil end

local logos = {}
function A.clubLogo(team, size)
  size = size or 32
  local abbr = team and (team.abbr or team.id) or "?"
  local key = abbr .. size
  if logos[key] ~= nil then return logos[key] or nil end
  local img = K.image("images/logos/" .. abbr .. "-" .. size)
  if not img then
    local tbl = gfx.imagetable.new("images/logos/farm-" .. size)
    local c = ((team and team.city) or abbr):upper():byte(1) or 65
    if tbl and c >= 65 and c <= 90 then img = tbl:getImage(c - 64) end
  end
  logos[key] = img or false
  return img
end
function A.clubLogo2x(team)
  local key = "2x" .. (team and (team.abbr or team.id) or "?")
  if logos[key] ~= nil then return logos[key] or nil end
  local l = A.clubLogo(team, 32)
  local img = l and l:scaledImage(2) or false
  logos[key] = img
  return img or nil
end

function A.release()
  txtCache, txtCount = {}, 0
  logoImg, bugImg, digits = nil, nil, nil
  faces, faces2x, photos, logos = {}, {}, {}, {}
  fontCache = {}
end

function A.stats() return txtCount end

--- rough bytes held by the caches (1-bit rows padded to 32 bits; x2 for a mask: an upper bound)
local function bytes(img)
  if not img then return 0 end
  local w, h = img:getSize()
  return ((w + 31) // 32) * 4 * h * 2
end
function A.memBytes()
  local n = 0
  for _, t in ipairs({ txtCache, faces, faces2x, photos, logos }) do
    for _, img in pairs(t) do if img then n = n + bytes(img) end end
  end
  n = n + bytes(logoImg) + bytes(bugImg)
  if digits then for _, d in pairs(digits) do n = n + bytes(d) end end
  return n
end

return A
