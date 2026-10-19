-- DBN broadcast package: transitions. A wipe covers the screen as p goes 0 → 1 (1 = fully
-- covered, so whatever is under it needn't be drawn); `out` mirrors it so the same wipe
-- uncovers in its own direction of travel. Each is a handful of rects / polygons.

import "ballcast/tv/art"

local gfx <const> = playdate.graphics
local floor <const>, min <const>, max <const> = math.floor, math.min, math.max

BallCast = BallCast or {}
local FX = {}
BallCast.TVFX = FX
local A = BallCast.TVArt
local K = BCKit

local function clamp(v) if v < 0 then return 0 elseif v > 1 then return 1 end return v end

local WIPES = {}

-- venetian blinds: 10 bands close from the top of each band (open from the bottom)
WIPES.blinds = function(p, out)
  local bh = 24
  local h = floor(bh * p + 0.5)
  if h <= 0 then return end
  gfx.setColor(gfx.kColorBlack)
  for y = 0, 239, bh do
    local yy = out and (y + bh - h) or y
    gfx.fillRect(0, yy, 400, h)
    if h < bh then
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(0, out and yy or (yy + h - 2), 400, 2)
      gfx.setColor(gfx.kColorBlack)
    end
  end
end

-- checkerboard: 40 px cells pop in along the diagonal (alternate cells lag a beat)
WIPES.checker = function(p, out)
  gfx.setColor(gfx.kColorBlack)
  for cy = 0, 5 do
    for cx = 0, 9 do
      local d = (out and (15 - cx - cy) or (cx + cy)) / 14 * 0.55 + ((cx + cy) % 2) * 0.1
      local q = clamp((p - d) / 0.35)
      if q > 0 then
        local s = floor(40 * q + 0.5)
        local o = (40 - s) // 2
        gfx.fillRect(cx * 40 + o, cy * 40 + o, s, s)
      end
    end
  end
end

-- diagonal swoosh: a black slab with three white speed stripes on its leading edge
WIPES.swoosh = function(p, out)
  local skew = 120
  local e = -skew + (400 + skew * 2) * p       -- leading edge x at the top
  gfx.setColor(gfx.kColorBlack)
  if out then
    -- the slab keeps travelling right: covered region is to the right of the edge
    local x = -skew + (400 + skew * 2) * (1 - p)
    gfx.fillPolygon(x, 0, 520, 0, 520, 240, x - skew, 240)
    gfx.setColor(gfx.kColorWhite)
    for i = 1, 3 do
      local o = -i * 9
      gfx.fillPolygon(x + o, 0, x + o + 4, 0, x + o + 4 - skew, 240, x + o - skew, 240)
    end
  else
    gfx.fillPolygon(-skew - 10, 0, e, 0, e - skew, 240, -skew - 10, 240)
    gfx.setColor(gfx.kColorWhite)
    for i = 1, 3 do
      local o = i * 9
      gfx.fillPolygon(e + o - 4, 0, e + o, 0, e + o - skew, 240, e + o - 4 - skew, 240)
    end
  end
  gfx.setColor(gfx.kColorBlack)
end

-- diamond iris from the centre (the network logo shape), white rim (in only; out = checker)
WIPES.diamond = function(p)
  local r = 340 * p
  if r <= 0 then return end
  gfx.setColor(gfx.kColorBlack)
  gfx.fillPolygon(A.diamondPoly(200, 120, r * 1.25, r))
  gfx.setColor(gfx.kColorWhite)
  gfx.setLineWidth(3)
  gfx.drawPolygon(A.diamondPoly(200, 120, r * 1.25 - 6, r - 5))
  gfx.setLineWidth(1)
  gfx.setColor(gfx.kColorBlack)
end

-- dither dissolve (the reduce-motion fallback for everything)
WIPES.dissolve = function(p) A.shade(0, 0, 400, 240, p) end

-- horizontal bars from both sides (a 90s "zipper")
WIPES.zip = function(p, out)
  local bh = 20
  gfx.setColor(gfx.kColorBlack)
  for i = 0, 11 do
    local w = floor(400 * clamp(p * 1.4 - (i % 3) * 0.12))
    if w > 0 then
      local fromLeft = (i % 2 == 0) ~= (out == true)
      gfx.fillRect(fromLeft and 0 or (400 - w), i * bh, w, bh)
    end
  end
end

-- diamond hole: black everywhere outside a diamond that shrinks as p → 1 (a reveal when p falls)
WIPES.hole = function(p)
  local rh = 290 * (1 - p)
  local rw = rh * 1.35
  local cx, cy = 200, 120
  gfx.setColor(gfx.kColorBlack)
  if rh < 1 then gfx.fillRect(0, 0, 400, 240) return end
  gfx.fillPolygon(-1, -1, cx, -1, cx, cy - rh, cx - rw, cy, -1, cy)
  gfx.fillPolygon(cx, -1, 401, -1, 401, cy, cx + rw, cy, cx, cy - rh)
  gfx.fillPolygon(401, cy, 401, 241, cx, 241, cx, cy + rh, cx + rw, cy)
  gfx.fillPolygon(cx, 241, -1, 241, -1, cy, cx - rw, cy, cx, cy + rh)
  gfx.setColor(gfx.kColorWhite)
  gfx.setLineWidth(3)
  gfx.drawPolygon(A.diamondPoly(cx, cy, rw, rh))
  gfx.setLineWidth(1)
  gfx.setColor(gfx.kColorBlack)
end

FX.KINDS = { "blinds", "checker", "swoosh", "zip" }

--- draw wipe `kind` at coverage p (0..1)
function FX.cover(kind, p, out)
  p = clamp(p)
  if p <= 0 then return end
  if A.reduce then kind = "dissolve" end
  if kind == "diamond" and out then kind = "checker" end
  local f = WIPES[kind] or WIPES.dissolve
  f(p, out)
end

--- VHS: horizontal tear bands + tracking noise over what's on screen (rewind look).
--- k: strength 0..1, seed: changes the band layout per frame.
function FX.vhs(k, seed)
  if k <= 0 or A.reduce then return end
  local img = gfx.getWorkingImage()
  local s = seed or 0
  for i = 0, 5 do
    local h = 6 + floor(K.hash01(s, i * 3 + 1) * 26)
    local y = floor(K.hash01(s, i * 3 + 2) * (240 - h))
    local dx = floor((K.hash01(s, i * 3 + 3) - 0.5) * 60 * k)
    gfx.setScreenClipRect(0, y, 400, h)
    img:draw(dx, 0)
  end
  gfx.clearClipRect()
  -- tracking noise: a few broken white lines
  gfx.setColor(gfx.kColorWhite)
  local ny = floor((s * 37) % 240)
  for i = 0, 3 do
    local y = (ny + i * 5) % 240
    local x = floor(K.hash01(s, 40 + i) * 300)
    gfx.fillRect(x, y, 30 + floor(K.hash01(s, 50 + i) * 90), 2)
  end
  gfx.setColor(gfx.kColorBlack)
end

--- scanlines over a region (CRT / dossier look): every other row darkened
function FX.scan(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.setDitherPattern(0.5, gfx.image.kDitherTypeHorizontalLine)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
end

--- TV static in a rect (a few hundred random pixels)
function FX.static(x, y, w, h, n)
  gfx.setColor(gfx.kColorWhite)
  for i = 1, n or 120 do gfx.fillRect(x + math.random(0, w - 2), y + math.random(0, h - 1), math.random(1, 3), 1) end
  gfx.setColor(gfx.kColorBlack)
  for i = 1, (n or 120) // 2 do gfx.fillRect(x + math.random(0, w - 2), y + math.random(0, h - 1), math.random(1, 3), 1) end
end

return FX
