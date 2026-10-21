-- DBN broadcast package: graphics drawn over live play (never hold the clock).
--   * corner network bug (with a glint now and then)
--   * K-ZONE inset: this at-bat's pitch locations, numbered; strike-zone box + pitch-tracker
--     trail projected onto the plate on the pitch cams
--   * Enhanced League power dossier strip during the windup
--   * strikeout "K" card stamp (backwards for a called third strike), K count
-- All of it is pure in (beat, tau), so scrubbing shows exactly the same thing.

import "ballcast/kit"
import "ballcast/tv/art"
import "ballcast/tv/fx"
import "ballcast/tv/cards"
import "ballcast/tv/stats"

local gfx <const> = playdate.graphics
local floor <const>, min <const>, max <const>, abs <const> = math.floor, math.min, math.max, math.abs

BallCast = BallCast or {}
local O = {}
BallCast.TVOverlay = O
local A = BallCast.TVArt
local FX = BallCast.TVFX
local Cards = BallCast.TVCards
local St = BallCast.TVStats
local K = BCKit

---------------------------------------------------------------------------
-- K-ZONE inset

local KZ_W <const>, KZ_H <const> = 64, 84
local kzImg, kzKey
local PX <const> = 13          -- px per foot
local function zx(px) return floor(KZ_W / 2 + px * PX + 0.5) end
local function zy(pz) return floor(14 + (4.6 - pz) * PX + 0.5) end

-- The empty inset (frame, grid, plate) is a template made once; a new at-bat copies it and
-- each pitch only stamps its own dot and number (cached digit images) - no text rendering.
local kzTemplate, kzPa, kzN = nil, nil, 0
local function template()
  if kzTemplate then return kzTemplate end
  -- (opaque: no mask, the inset blits a little faster every frame; it's all painted anyway)
  local img = gfx.image.new(KZ_W, KZ_H, gfx.kColorBlack)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, KZ_W, KZ_H)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(2, 12, KZ_W - 4, KZ_H - 14)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  K.fonts.tiny:drawText("K-ZONE", 4, 2)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  local x0, x1, y0, y1 = zx(-0.71), zx(0.71), zy(3.5), zy(1.5)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
  gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
  for k = 1, 2 do
    local gx = x0 + floor((x1 - x0) * k / 3)
    local gy = y0 + floor((y1 - y0) * k / 3)
    gfx.drawLine(gx, y0, gx, y1)
    gfx.drawLine(x0, gy, x1, gy)
  end
  gfx.setColor(gfx.kColorBlack)
  local py = KZ_H - 7
  gfx.fillPolygon(zx(-0.71), py, zx(0.71), py, zx(0.71), py + 2, zx(0), py + 4, zx(-0.71), py + 2)
  gfx.popContext()
  kzTemplate = img
  for d = 0, 9 do A.text("tiny", tostring(d), "b") end
  return img
end

--- one pitch's marker at (x, y) in the current context: ball hollow, strike / foul filled, in
--- play a diamond, hit by pitch an X; its number on a white tab up and to the right. (Pennant's
--- own zone panels stamp with it too.)
local function stampAt(i, r, x, y)
  gfx.setColor(gfx.kColorBlack)
  if r == "B" then
    gfx.setColor(gfx.kColorWhite); gfx.fillCircleAtPoint(x, y, 4)
    gfx.setColor(gfx.kColorBlack); gfx.drawCircleAtPoint(x, y, 4)
  elseif r == "X" then
    gfx.fillPolygon(x, y - 5, x + 5, y, x, y + 5, x - 5, y)
  elseif r == "H" then
    gfx.setLineWidth(2); gfx.drawLine(x - 3, y - 3, x + 3, y + 3); gfx.drawLine(x - 3, y + 3, x + 3, y - 3); gfx.setLineWidth(1)
  else
    gfx.fillCircleAtPoint(x, y, 4)
  end
  local s = tostring(i)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x + 4, y - 9, 5 * #s + 2, 8)
  gfx.setColor(gfx.kColorBlack)
  local dx = x + 5
  for k = 1, #s do
    local di = A.text("tiny", s:sub(k, k), "b")
    di:draw(dx, y - 9)
    dx = dx + di:getSize()
  end
end
O.stampAt = stampAt

local function kzPos(p) return zx(K.clamp(p.px, -2.2, 2.2)), zy(K.clamp(p.pz, 0.4, 4.6)) end
local function stamp(i, bj)
  local x, y = kzPos(bj.plan.pitch)
  stampAt(i, bj.e.r, x, y)
end

--- The at-bat's pitches the picture has shown by (bi, tau): a pitch counts once it has reached
--- the plate. skip: a beat to leave out (Pennant's provisional pitch). Returns the list (reused),
--- its length and the at-bat's "pa" beat index. out: a table to fill instead of the shared one.
function O.atBat(tl, bi, tau, skip, out)
  local pa = bi
  while pa > 1 and tl.beats[pa].kind ~= "pa" do pa = pa - 1 end
  local list = out or O.kzList or {}
  if not out then O.kzList = list end
  local n = 0
  for j = pa + 1, bi do
    local bj = tl.beats[j]
    if bj.kind == "p" and bj ~= skip and bj.plan.pitch and (j < bi or tau >= bj.plan.pitch.tPlate + 0.05) then
      n = n + 1
      list[n] = bj
    end
  end
  return list, n, pa
end

local kzBeats = {}
local function kzone(tl, bi, b, tau)
  local list, n, pa = O.atBat(tl, bi, tau)
  -- (a beat swapped under us: Pennant's provisional pitch replaced by the real one)
  local same = kzImg and pa == kzPa and n >= kzN
  if same then for i = 1, kzN do if kzBeats[i] ~= list[i] then same = false break end end end
  if same and n == kzN then return kzImg, n, list end
  if not same then
    -- new at-bat (or scrubbed back): a fresh copy of the empty inset
    kzImg = template():copy()
    kzPa, kzN = pa, 0
  end
  gfx.pushContext(kzImg)
  for i = kzN + 1, n do stamp(i, list[i]); kzBeats[i] = list[i] end
  gfx.popContext()
  kzN = n
  return kzImg, n, list
end

--- the inset at (x, y), the latest pitch ringed over the baked stamps (a circle and its marker
--- again). The ring is its own small image, made once per pitch (RING_*: the ring and the
--- number tab reach past the inset's edge, so it isn't baked into the inset): drawing the
--- circles and the stamp live cost that every frame on the device.
local RING_W <const>, RING_H <const>, RING_X <const>, RING_Y <const> = 28, 20, 9, 11
local ringImg, ringBeat, ringN
local function drawKzone(tl, bi, b, tau, x, y)
  local img, n, list = kzone(tl, bi, b, tau)
  img:draw(x, y)
  if n > 0 then
    local bj = list[n]
    if ringBeat ~= bj or ringN ~= n or not ringImg then
      ringImg = ringImg or gfx.image.new(RING_W, RING_H, gfx.kColorClear)
      ringImg:clear(gfx.kColorClear)
      gfx.pushContext(ringImg)
      gfx.setColor(gfx.kColorBlack)
      gfx.drawCircleAtPoint(RING_X, RING_Y, 7)
      gfx.setColor(gfx.kColorWhite)
      gfx.drawCircleAtPoint(RING_X, RING_Y, 6)
      -- (its number back on top of the ring)
      stampAt(n, bj.e.r, RING_X, RING_Y)
      gfx.popContext()
      ringBeat, ringN = bj, n
    end
    local mx, my = kzPos(bj.plan.pitch)
    ringImg:draw(x + mx - RING_X, y + my - RING_Y)
  end
  return n, list
end

--- the call on the latest pitch, with the count: a tab off the inset's title bar for a couple
--- of seconds from the ump's call (plan.callT), then gone
local function callWord(e)
  local r, bb, ss = e.r, e.b or 0, e.s or 0
  if r == "B" then return bb >= 4 and "BALL FOUR" or ("BALL " .. bb .. "-" .. ss) end
  if r == "C" or r == "S" then
    if ss >= 3 then return r == "C" and "CALLED K" or "SWINGING K" end
    return (r == "C" and "CALLED STRIKE " or "SWING & MISS ") .. bb .. "-" .. ss
  end
  if r == "F" then return "FOUL " .. bb .. "-" .. ss end
  if r == "H" then return "HIT BY PITCH" end
  if r == "X" then return "IN PLAY" end
  return nil
end
O.callWord = callWord
local function callTab(b, tau, x, y)
  if b.kind ~= "p" then return end
  local p = b.plan.pitch
  local t0 = b.plan.callT or (p.tPlate + 0.2)
  if tau < t0 or tau > t0 + 2.2 then return end
  local w = callWord(b.e)
  if not w then return end
  local img = A.text("tiny", w, "w")
  local tw = img:getSize()
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x, y, tw + 8, 12)
  img:draw(x + 3, y + 2)
end

---------------------------------------------------------------------------
-- spray chart: where the ball in play went (Pennant): the park's fence and the infield made once
-- per park, the batted ball's spot and the result stamped once per play; a blit per frame

local SP_W <const>, SP_H <const> = 64, 60
local SP_S <const> = 0.1                 -- px per foot
local SP_HX <const>, SP_HY <const> = 32, SP_H - 5
local function spx(x) return floor(SP_HX + x * SP_S + 0.5) end
local function spy(y) return floor(SP_HY - y * SP_S + 0.5) end
local spBase, spPark, spImg, spBeat

local function sprayTemplate(park)
  if spBase and spPark == park then return spBase end
  local Cam = BallCast.Cam
  local img = gfx.image.new(SP_W, SP_H, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, SP_W, SP_H)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(2, 12, SP_W - 4, SP_H - 14)
  gfx.setClipRect(2, 12, SP_W - 4, SP_H - 14)
  -- fair territory: a light dither inside the fence
  local poly = { SP_HX, SP_HY }
  for a = -45, 45, 5 do
    local d = Cam.fenceAt(park or {}, a)
    local r = math.rad(a)
    poly[#poly + 1] = spx(math.sin(r) * d); poly[#poly + 1] = spy(math.cos(r) * d)
  end
  gfx.setDitherPattern(0.75, gfx.image.kDitherTypeBayer4x4)
  gfx.fillPolygon(table.unpack(poly))
  gfx.setColor(gfx.kColorBlack)
  gfx.drawPolygon(table.unpack(poly))
  -- the infield
  local d = 90 * 0.7071
  gfx.drawPolygon(spx(0), spy(0), spx(d), spy(d), spx(0), spy(2 * d), spx(-d), spy(d))
  gfx.clearClipRect()
  gfx.popContext()
  spBase, spPark = img, park
  return img
end

local RES_WORD = { ["1B"] = "SINGLE", ["2B"] = "DOUBLE", ["3B"] = "TRIPLE", HR = "HOME RUN", SF = "SAC FLY",
  DP = "DBL PLAY", FC = "FC", ROE = "ERROR", FOUL_OUT = "FOUL OUT", OUT = "OUT" }
local HIT = { ["1B"] = true, ["2B"] = true, ["3B"] = true, HR = true }
local function sprayWord(e)
  local w = RES_WORD[e.res] or tostring(e.res or "")
  if (e.res == "OUT" or e.res == "ROE" or e.res == "FC") and e.f then w = w .. " " .. e.f end
  return w
end
O.sprayWord = sprayWord

local function sprayImg(G, b)
  if spImg and spBeat == b then return spImg end
  local img = sprayTemplate(G.tl.meta and G.tl.meta.park):copy()
  local sp = b.plan.spot
  gfx.pushContext(img)
  local w = A.text("tiny", sprayWord(b.e), "w")
  w:draw(4, 2)
  gfx.setClipRect(2, 12, SP_W - 4, SP_H - 14)
  local x, y = spx(sp[1]), max(15, spy(sp[2]))
  gfx.setColor(gfx.kColorBlack)
  gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
  gfx.drawLine(SP_HX, SP_HY, x, y)
  gfx.setColor(gfx.kColorBlack)
  if HIT[b.e.res] then
    -- a hit: a filled ball, ringed
    gfx.setColor(gfx.kColorWhite); gfx.fillCircleAtPoint(x, y, 5)
    gfx.setColor(gfx.kColorBlack); gfx.fillCircleAtPoint(x, y, 3); gfx.drawCircleAtPoint(x, y, 5)
  else
    -- an out (or reached on the defense): an X where they got it
    gfx.setColor(gfx.kColorWhite); gfx.fillRect(x - 4, y - 4, 9, 9)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2); gfx.drawLine(x - 3, y - 3, x + 3, y + 3); gfx.drawLine(x - 3, y + 3, x + 3, y - 3); gfx.setLineWidth(1)
  end
  gfx.clearClipRect()
  gfx.popContext()
  spImg, spBeat = img, b
  return img
end

--- the ball in play's spray chart, once the picture has shown the result (Play.revealT), held
--- SPRAY_HOLD s; in the K-zone's slot (the K-zone only shows on the pitch cams)
local SPRAY_HOLD <const> = 3.0
function O.sprayShown(b, tau)
  if b.kind ~= "bip" or not b.plan.spot then return false end
  local t0 = BallCast.Play.revealT(b)
  return tau >= t0 and tau < t0 + SPRAY_HOLD
end

--- strike-zone box + pitch-tracker trail, projected onto the plate (pitch cams only)
local trail = {}
-- the held trail as an image: the points it was drawn from, its top-left on screen
local trImg, trKey, trX, trY = nil, {}, 0, 0
local function drawTrail(n, ox, oy)
  gfx.setLineCapStyle(gfx.kLineCapStyleRound)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(4)
  for i = 1, n - 1 do gfx.drawLine(trail[i * 2 - 1] - ox, trail[i * 2] - oy, trail[i * 2 + 1] - ox, trail[i * 2 + 2] - oy) end
  gfx.setColor(gfx.kColorWhite)
  gfx.setLineWidth(2)
  for i = 1, n - 1 do gfx.drawLine(trail[i * 2 - 1] - ox, trail[i * 2] - oy, trail[i * 2 + 1] - ox, trail[i * 2 + 2] - oy) end
  gfx.setLineWidth(1)
  gfx.setLineCapStyle(gfx.kLineCapStyleButt)
  gfx.setColor(gfx.kColorBlack)
end
--- draw the trail's n points from the cached image (made now if they moved): false = not
--- cacheable here (a point off the top / left: drawn live instead)
local function trailCached(n)
  local same = trImg ~= nil and #trKey == n * 2
  local x0, y0, x1, y1 = 1e9, 1e9, -1e9, -1e9
  for i = 1, n * 2, 2 do
    local x, y = trail[i], trail[i + 1]
    if same and (trKey[i] ~= x or trKey[i + 1] ~= y) then same = false end
    if x < x0 then x0 = x end
    if x > x1 then x1 = x end
    if y < y0 then y0 = y end
    if y > y1 then y1 = y end
  end
  if not same then
    -- (integer offsets, on-screen points only: the lines land on exactly the pixels they would)
    if x0 < 4 or y0 < 4 or x1 > 2000 or y1 > 2000 then return false end
    local ox, oy = floor(x0) - 4, floor(y0) - 4
    trImg = gfx.image.new(floor(x1) - ox + 6, floor(y1) - oy + 6, gfx.kColorClear)
    gfx.pushContext(trImg)
    drawTrail(n, ox, oy)
    gfx.popContext()
    for k = #trKey, 1, -1 do trKey[k] = nil end
    for i = 1, n * 2 do trKey[i] = trail[i] end
    trX, trY = ox, oy
  end
  trImg:draw(trX, trY)
  return true
end
local function tracker(R, plan, tau)
  local p = plan.pitch
  if not p or tau < p.tRel + 0.04 or tau > p.tPlate + 1.4 then return end
  local Play = BallCast.Play
  -- the zone, once the pitch is on its way
  if tau > p.tPlate - 0.25 then
    local ax, ay = R:project(-0.71, 0.3, 3.5)
    local bx, by = R:project(0.71, 0.3, 1.5)
    if ax and bx then
      local x, y, w, h = min(ax, bx), min(ay, by), abs(bx - ax), abs(by - ay)
      if w > 5 and w < 160 then
        gfx.setColor(gfx.kColorBlack)
        gfx.drawRect(x - 1, y - 1, w + 2, h + 2)
        gfx.setColor(gfx.kColorWhite)
        gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
        gfx.drawRect(x, y, w, h)
        gfx.setColor(gfx.kColorBlack)
      end
    end
  end
  -- the trail: the ball's path from the release to where it is now (to the plate)
  local t1 = min(tau, p.tPlate)
  local n = 0
  for k = 0, 6 do
    local tt = p.tRel + (t1 - p.tRel) * k / 6
    local bx, by, bz = Play.ballAt(plan, tt)
    if bx then
      local sx, sy = R:project(bx, by, bz)
      if sx then n = n + 1; trail[n * 2 - 1] = sx; trail[n * 2] = sy end
    end
  end
  if n < 2 then return end
  local fade = tau > p.tPlate + 0.9 and (tau - p.tPlate - 0.9) / 0.5 or 0
  if fade >= 1 then return end
  if fade == 0 and tau >= p.tPlate then
    -- the whole trail, held (the ball is in): drawn once into an image while it doesn't move on
    -- screen (the wide round-capped lines cost ~2 ms a frame on the device)
    if trailCached(n) then return end
  end
  gfx.setLineCapStyle(gfx.kLineCapStyleRound)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(4)
  for i = 1, n - 1 do gfx.drawLine(trail[i * 2 - 1], trail[i * 2], trail[i * 2 + 1], trail[i * 2 + 2]) end
  gfx.setColor(gfx.kColorWhite)
  if fade > 0 then gfx.setDitherPattern(fade, gfx.image.kDitherTypeBayer4x4) end
  gfx.setLineWidth(2)
  for i = 1, n - 1 do gfx.drawLine(trail[i * 2 - 1], trail[i * 2], trail[i * 2 + 1], trail[i * 2 + 2]) end
  gfx.setLineWidth(1)
  gfx.setLineCapStyle(gfx.kLineCapStyleButt)
  gfx.setColor(gfx.kColorBlack)
end

---------------------------------------------------------------------------
-- power dossier (Enhanced League)

local powImgs = {}   -- "who|power" -> strip, prerendered in the loader (O.prewarm)
local function powerStripImg(G, who, power)
  local key = tostring(who) .. "|" .. power
  local img = powImgs[key]
  if not img then img = Cards.power(G, who, power); powImgs[key] = img end
  return img
end
local function powerStrip(G, who, power, age, dur)
  local powImg = powerStripImg(G, who, power)
  local y = 34
  local e = A.ease(age / 0.18)
  local out = K.clamp((age - (dur - 0.15)) / 0.15, 0, 1)
  if A.reduce then e, out = 1, (age > dur - 0.15) and 1 or 0 end
  local h = floor(74 * e * (1 - out))
  if h <= 0 then return end
  gfx.setScreenClipRect(0, y + (74 - h) // 2, 400, h)
  powImg:draw(0, y)
  if age < 0.3 and not A.reduce then FX.static(0, y, 400, 70, 160) end
  -- scan bar sweeping down the photo
  local sy = y + 6 + floor((age * 140) % 58)
  gfx.setColor(gfx.kColorXOR)
  gfx.fillRect(8, sy, 48, 2)
  gfx.setColor(gfx.kColorBlack)
  gfx.clearClipRect()
end

---------------------------------------------------------------------------
-- K card

local kImg, kImgBack
-- a fan's K card: a white card tilted a few degrees (a polygon, no image rotation: that was
-- the costly part on the device), thick border, a big K; reversed for a called third strike
local function cardImg(tilt, flipK)
  local w, h = 44, 54
  local img = gfx.image.new(w, h, gfx.kColorClear)
  gfx.pushContext(img)
  local cx, cy, hw, hh = 21, 26, 17, 22
  local c, s = math.cos(tilt), math.sin(tilt)
  local function corner(x, y, ox, oy) return cx + ox + x * c - y * s, cy + oy + x * s + y * c end
  local function quad(ox, oy, d)
    local ax, ay = corner(-hw + d, -hh + d, ox, oy)
    local bx, by = corner(hw - d, -hh + d, ox, oy)
    local qx, qy = corner(hw - d, hh - d, ox, oy)
    local dx, dy = corner(-hw + d, hh - d, ox, oy)
    return ax, ay, bx, by, qx, qy, dx, dy
  end
  gfx.setColor(gfx.kColorBlack)
  gfx.fillPolygon(quad(3, 3, 0))           -- shadow
  gfx.setColor(gfx.kColorWhite)
  gfx.fillPolygon(quad(0, 0, 0))
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawPolygon(quad(0, 0, 2))
  gfx.setLineWidth(1)
  local f = K.fonts.big
  local kw, kh = f:getTextWidth("K"), f:getHeight()
  local x, y = cx - kw // 2, cy - kh // 2 + 1
  if flipK then
    local k = gfx.image.new(kw + 1, kh, gfx.kColorClear)
    gfx.pushContext(k)
    f:drawText("K", 0, 0); f:drawText("K", 1, 0)
    gfx.popContext()
    k:draw(x, y, gfx.kImageFlippedX)
  else
    f:drawText("K", x, y); f:drawText("K", x + 1, y)
  end
  gfx.popContext()
  return img
end
local function kCard(back)
  if back then
    kImgBack = kImgBack or cardImg(0.12, true)
    return kImgBack
  end
  kImg = kImg or cardImg(-0.12, false)
  return kImg
end

local function kStamp(G, tl, bi, b, tau)
  local t0 = b.plan.kT
  local age = tau - t0
  if age < 0 or age > 1.9 then return end
  local back = b.e.r == "C"
  local img = kCard(back)
  local s = 1
  if age < 0.14 and not A.reduce then s = 2.2 - age / 0.14 * 1.2 end
  local w, h = img:getSize()
  local x, y = 352, 132
  if O.pipActive then x, y = 40, 178 end   -- (the swing cam has the bottom-right corner)
  if s ~= 1 then img:drawScaled(x - w * s / 2, y - h * s / 2, s)
  else img:draw(x - w // 2, y - h // 2) end
  if age > 0.2 then
    local c = St.counts(tl, bi)
    local pc = c.pit[b.pre.pit]
    -- (the call text says LOOKING / SWINGING now: the card just counts)
    local lab = A.text("nb", "K #" .. math.min(pc and pc.k or 1, 20), "wo")
    local lw = lab:getSize()
    lab:draw(x - lw // 2, y + h // 2 + 2)
  end
end

---------------------------------------------------------------------------
-- corner bug

local function bug(live, t)
  local img = A.bug(live)
  local bw = img:getSize()
  local x, y = 396 - bw, 204
  img:draw(x, y)
  -- glint every 20 s
  local u = (t % 20) / 0.7
  if u < 1 then A.glint(x, y, bw, 18, u) end
end

---------------------------------------------------------------------------

local WIDE = { deepL = true, deepC = true, deepR = true, blimp = true, wallLow = true, dugout = true, runner = true }

function O.draw(G, scene, bi, b, tau, camName, slo, R)
  local tl = G.tl
  local now = playdate.getCurrentTimeMilliseconds() / 1000
  -- pitch cams: zone + tracker + inset (a local game's own direct-control panel replaces the inset)
  -- (a local source with its own pitch tracking, src.pitchTrack: the call tab with the count, and
  -- the spray chart after a ball in play)
  local src = scene and scene.src
  local hideKz = src and src.hideKzone
  local track = src and src.pitchTrack
  if hideKz then
    if b.kind == "p" and b.plan.pitch and R and R.project and (camName == "pitch" or camName == "behindPlate") then tracker(R, b.plan, tau) end
  elseif b.kind == "p" and b.plan.pitch and (camName == "pitch" or camName == "behindPlate") then
    if R and R.project then tracker(R, b.plan, tau) end
    drawKzone(tl, bi, b, tau, 4, 62)
    if track then callTab(b, tau, 68, 62) end
  elseif b.kind == "pa" and camName == "pitch" then
    -- (the new at-bat: an empty zone keeps its spot)
    drawKzone(tl, bi, b, tau, 4, 62)
  elseif track and O.sprayShown(b, tau) then
    sprayImg(G, b):draw(4, 62)
  end
  -- power dossier
  local plan = b.plan
  if plan.power or plan.hyperPower then
    local u = b.ultra and b.ultra[1]
    if u then
      local age = tau - 0.12
      local dur = (plan.pitch and plan.pitch.tRel or 1) - 0.1
      if age >= 0 and age <= dur then powerStrip(G, u.who, u.power, age, dur) end
    end
  elseif plan.leap and b.ultra then
    local u = b.ultra[1]
    -- (with the catch: 1.3 s ahead of it, the dossier said he'd climb the wall and rob it)
    local age = tau - (plan.leap.tc + 0.15)
    if u and age >= 0 and age <= 1.1 then powerStrip(G, u.who, "LEAP_CATCH", age, 1.1) end
  end
  if b.kind == "p" and b.k and plan.kT then kStamp(G, tl, bi, b, tau) end
  -- the bug: not on the wide action shots (they're the frames with no time to spare)
  -- (not while the controls strip is up: the bug sat on its "L/R SPEED")
  local hinting = scene.hintUntil and playdate.getCurrentTimeMilliseconds() < scene.hintUntil
  if not slo and not WIDE[camName] and not O.pipActive and not hinting then bug(scene.live and true or false, now) end
end

--- loader: everything the overlays would otherwise render on the frame they first show
--- ultras: { {who, power}, ... } this game's Enhanced League powers
--- one prerender item: the two K cards (ultras nil) or one dossier per ultra
function O.prewarm(G, ultras)
  if not ultras then kCard(false); kCard(true) end
  for _, u in ipairs(ultras or {}) do powerStripImg(G, u[1], u[2]) end
  template()
end

function O.release()
  kzImg, kzKey, kImg, kImgBack = nil, nil, nil, nil
  kzTemplate, kzPa, kzN, kzBeats = nil, nil, 0, {}
  spBase, spPark, spImg, spBeat = nil, nil, nil, nil
  ringImg, ringBeat, ringN = nil, nil, nil
  trImg, trKey = nil, {}
  powImgs = {}
  O.kzList = nil
end

return O
