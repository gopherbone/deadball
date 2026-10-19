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
  local img = gfx.image.new(KZ_W, KZ_H, gfx.kColorClear)
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

local function stamp(i, bj)
  local p = bj.plan.pitch
  local x, y = zx(K.clamp(p.px, -2.2, 2.2)), zy(K.clamp(p.pz, 0.4, 4.6))
  local r = bj.e.r
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

local function kzone(tl, bi, b, tau)
  -- the at-bat's pitches so far (a pitch counts once it has reached the plate)
  local pa = bi
  while pa > 1 and tl.beats[pa].kind ~= "pa" do pa = pa - 1 end
  local list = O.kzList or {}
  O.kzList = list
  local n = 0
  for j = pa + 1, bi do
    local bj = tl.beats[j]
    if bj.kind == "p" and bj.plan.pitch and (j < bi or tau >= bj.plan.pitch.tPlate + 0.05) then
      n = n + 1
      list[n] = bj
    end
  end
  if kzImg and pa == kzPa and n == kzN then return kzImg, n end
  if not kzImg or pa ~= kzPa or n < kzN then
    -- new at-bat (or scrubbed back): a fresh copy of the empty inset
    kzImg = template():copy()
    kzPa, kzN = pa, 0
  end
  gfx.pushContext(kzImg)
  for i = kzN + 1, n do stamp(i, list[i]) end
  gfx.popContext()
  kzN = n
  return kzImg, n
end

--- strike-zone box + pitch-tracker trail, projected onto the plate (pitch cams only)
local trail = {}
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
  local x, y = 346, 204
  img:draw(x, y)
  -- glint every 20 s
  local u = (t % 20) / 0.7
  if u < 1 then A.glint(x, y, 50, 18, u) end
end

---------------------------------------------------------------------------

local WIDE = { deepL = true, deepC = true, deepR = true, blimp = true, wallLow = true, dugout = true, runner = true }

function O.draw(G, scene, bi, b, tau, camName, slo, R)
  local tl = G.tl
  local now = playdate.getCurrentTimeMilliseconds() / 1000
  -- pitch cams: zone + tracker + inset
  if b.kind == "p" and b.plan.pitch and (camName == "pitch" or camName == "behindPlate") then
    if R and R.project then tracker(R, b.plan, tau) end
    local img = kzone(tl, bi, b, tau)
    img:draw(4, 62)
  elseif b.kind == "pa" and camName == "pitch" then
    -- (the new at-bat: an empty zone keeps its spot)
    local img = kzone(tl, bi, b, tau)
    img:draw(4, 62)
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
    local age = tau - (plan.leap.tc - 1.3)
    if u and age >= 0 and age <= 1.1 then powerStrip(G, u.who, "LEAP_CATCH", age, 1.1) end
  end
  if b.kind == "p" and b.k and plan.kT then kStamp(G, tl, bi, b, tau) end
  -- the bug: not on the wide action shots (they're the frames with no time to spare)
  if not slo and not WIDE[camName] and not O.pipActive then bug(scene.live and true or false, now) end
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
  kzTemplate, kzPa, kzN = nil, nil, 0
  powImgs = {}
  O.kzList = nil
end

return O
