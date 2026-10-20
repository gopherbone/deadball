-- DBN "SWING CAM": a picture-in-picture swing analysis around big swings.
--
-- Two small panels in one inset: OVERHEAD (the plate from above: the zone's width, the
-- pitch coming in, the bat sweeping through) and SIDE (the zone's height, the pitch's height
-- at the plate, the bat's plane, and on contact the launch angle). Then a flat verdict:
-- "MISSED BY 4 IN.", "OUT IN FRONT", "LATE", "GOT UNDER IT", "BARRELED. 104 MPH.".
--
-- Why a diagram and not a second 3D camera: bc3d renders the whole frame, so an inset camera
-- is a second full render pass (~10-20 ms on the device) on the pitch cam's 25 ms frame. The
-- diagram is a cached panel image plus ~25 primitives and one cached label per frame.
--
-- It opens from its corner once the pitch is in and runs the swing back a beat behind (opening
-- ahead of the pitch gave away that he'd swing), then folds back up after the result (on
-- contact it stays into the ball in play). Pure in (beat, tau), so scrubbing matches; it
-- isn't shown while scrubbing, at 4x, or with the log open, and only the big ones at 2x. Any
-- button folds the current one away. reduceMotion: no fold, a dither fade.

import "ballcast/kit"
import "ballcast/tv/art"

local gfx <const> = playdate.graphics
local floor <const>, sin <const>, cos <const>, min <const>, max <const>, abs <const> = math.floor, math.sin, math.cos, math.min, math.max, math.abs

BallCast = BallCast or {}
local PiP = {}
BallCast.TVPiP = PiP
local A = BallCast.TVArt
local K = BCKit

local W <const>, H <const> = 152, 92        -- whole inset
local PW <const> = 74                        -- one panel's width
local TOP <const> = 12                       -- title strip height
local LAG <const> = 0.65                     -- s: the inset's swing runs this far behind the live pitch

---------------------------------------------------------------------------
-- which swings get it

local HARD <const> = 98          -- mph off the bat: a tier-1 swing cam

local function contactBeat(tl, b)
  local nb = tl.beats[b.n + 1]
  if b.e.r == "X" and nb and nb.kind == "bip" then return nb end
  return nil
end

--- tier 1 (always, also at 2x): hard contact (98+ mph off the bat). tier 2 (1x only): two-strike
--- swings and misses / fouls (some), and any swing in a big spot.
function PiP.tier(tl, b)
  if b.kind ~= "p" or not b.plan.pitch then return nil end
  local r = b.e.r
  if r ~= "S" and r ~= "F" and r ~= "X" then return nil end
  local cb = contactBeat(tl, b)
  -- (the hard-hit ones, caught or not: picking the extra-base hits told you it would fall in)
  if cb and (cb.e.ev or 0) >= HARD then return 1 end
  local late = (b.pre.inn or 1) >= 7 and abs((b.pre.home or 0) - (b.pre.away or 0)) <= 2
  local big = late or ((b.pre.b2 or b.pre.b3) and (b.pre.outs or 0) == 2)
  local twoK = (b.pre.s or 0) >= 2
  if r == "S" and (twoK or big) then return 2 end
  if r == "F" and twoK and K.hash01(b.i, 61) < 0.4 then return 2 end
  if r == "X" and big then return 2 end
  return nil
end

---------------------------------------------------------------------------
-- the verdict (deterministic per pitch)

local BREAKING = { SL = true, CB = true, CH = true, SPL = true, KN = true, SPIT = true }

function PiP.verdict(tl, b)
  local p = b.plan.pitch
  local e = b.e
  local h = K.hash01(b.i, 63)
  local cb = contactBeat(tl, b)
  if cb then
    local ev, la = cb.e.ev or 0, cb.e.la or 0
    -- (the homer used to get its own wording, with the angle: it read as HOME RUN mid-flight)
    if la < 2 then return "TOPPED IT. " .. ev .. " MPH.", "x" end
    if la > 38 then return "GOT UNDER IT. " .. la .. " DEG.", "x" end
    if ev >= 96 then return "BARRELED. " .. ev .. " MPH.", "x" end
    if ev < 78 then return "WEAK CONTACT. " .. ev .. " MPH.", "x" end
    return "SQUARED UP. " .. ev .. " MPH.", "x"
  end
  if e.r == "F" then
    return (h < 0.5 and "LATE. FOULED IT BACK." or "OUT IN FRONT. FOUL."), "f"
  end
  -- a miss: by how much, and how
  local inches = 2 + floor(h * 9)
  if p.pz < 1.7 then return "SWUNG OVER IT. MISSED BY " .. inches .. " IN.", "over" end
  if p.pz > 3.4 then return "UNDER IT. MISSED BY " .. inches .. " IN.", "under" end
  if abs(p.px) > 0.95 then return "CHASED IT. MISSED BY " .. inches .. " IN.", "chase" end
  if BREAKING[e.t] then return (h < 0.5 and "OUT IN FRONT. " or "FOOLED. ") .. "MISSED BY " .. inches .. " IN.", "front" end
  return (h < 0.5 and "LATE. " or "OUT IN FRONT. ") .. "MISSED BY " .. inches .. " IN.", h < 0.5 and "late" or "front"
end

---------------------------------------------------------------------------
-- cached pieces

local panel                -- the empty inset (frame, titles, zone, plate)
local labels = {}          -- verdict text -> image

local function panelImg()
  if panel then return panel end
  local img = gfx.image.new(W, H, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, W, H)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(2, TOP, PW - 2, H - TOP - 2)
  gfx.fillRect(PW + 2, TOP, PW - 2, H - TOP - 2)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  K.fonts.tiny:drawText("SWING CAM", 4, 2)
  K.fonts.tiny:drawText("DBN", W - 22, 2)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.setColor(gfx.kColorBlack)
  K.fonts.tiny:drawText("OVERHEAD", 5, TOP + 2)
  K.fonts.tiny:drawText("SIDE", PW + 5, TOP + 2)
  -- overhead: plate + zone width (the plate at the bottom, the mound up)
  local cx, py = 1 + PW // 2, H - 14
  gfx.fillPolygon(cx - 9, py - 6, cx + 9, py - 6, cx + 9, py - 1, cx, py + 4, cx - 9, py - 1)
  gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
  gfx.drawLine(cx - 9, TOP + 12, cx - 9, py - 7)
  gfx.drawLine(cx + 9, TOP + 12, cx + 9, py - 7)
  gfx.setColor(gfx.kColorBlack)
  -- side: zone band 1.5-3.5 ft over the plate (the plate at the left, the mound to the right)
  local zx, zb, zt = PW + 14, H - 6 - floor(1.5 * 15), H - 6 - floor(3.5 * 15)
  gfx.drawRect(zx - 3, zt, 7, zb - zt)
  gfx.fillRect(PW + 6, H - 6, PW - 10, 2)       -- the ground
  gfx.popContext()
  panel = img
  return img
end

local function labelImg(s)
  local img = labels[s]
  if img then return img end
  local f = K.fonts.tiny
  local w = min(W, f:getTextWidth(s) + 8)
  img = gfx.image.new(w, 11, gfx.kColorBlack)
  gfx.pushContext(img)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  f:drawText(s, 4, 2)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.popContext()
  labels[s] = img
  return img
end

--- prerender pieces: the panel (loader) or one beat's verdict (the look-ahead queue)
function PiP.prewarm(tl, b)
  if not b then panelImg() return end
  local s = PiP.verdict(tl, b)
  labelImg(s)
end

---------------------------------------------------------------------------
-- drawing

local function ease(t) t = K.clamp(t, 0, 1); return 1 - (1 - t) ^ 3 end

-- the swing, drawn into the inset at (x0, y0); t is pitch-beat time
local function drawSwing(x0, y0, tl, b, t, kind)
  local p = b.plan.pitch
  local tP = p.tPlate
  local side = p.side or 1                        -- batter: 1 = right-handed
  -- the pitch comes in over the last ~0.35 s (drawn slowed down: it's analysis)
  local u = K.clamp((t - (tP - 0.4)) / 0.4, 0, 1)
  -- OVERHEAD -------------------------------------------------------------
  local cx, py = x0 + 1 + PW // 2, y0 + H - 14
  local S = 13                                    -- px per foot
  local bxEnd, byEnd = cx + floor(p.px * S), py - 4
  local bx0, by0 = cx + floor(-0.6 * S), y0 + TOP + 12
  local bx, by = bx0 + (bxEnd - bx0) * u, by0 + (byEnd - by0) * u
  gfx.setColor(gfx.kColorBlack)
  gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
  gfx.drawLine(bx0, by0, bx, by)
  gfx.setColor(gfx.kColorBlack)
  -- the bat: pivots at the hands beside the plate, sweeps through the zone at swing time
  local hx, hy = cx - side * 26, py - 4
  local sw = b.plan.swing or (tP - 0.12)
  local s = K.clamp((t - (sw - 0.08)) / 0.2, 0, 1)
  local a0, a1 = -side * 2.4, -side * 0.15
  if kind == "late" then a1 = -side * 0.6 elseif kind == "front" then a1 = side * 0.45 end
  local a = a0 + (a1 - a0) * s
  local L = 32
  local ex, ey = hx + side * cos(a) * L, hy - sin(abs(a)) * L * 0.55
  gfx.setLineWidth(3)
  gfx.drawLine(hx, hy, ex, ey)
  gfx.setLineWidth(1)
  if s > 0 and s < 1 then
    gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
    gfx.drawLine(hx + side * cos(a0) * L, hy - sin(abs(a0)) * L * 0.55, ex, ey)
    gfx.setColor(gfx.kColorBlack)
  end
  gfx.fillCircleAtPoint(bx, by, 3)
  -- SIDE -------------------------------------------------------------------
  local sx0, ground = x0 + PW + 14, y0 + H - 6
  local Z = 15                                    -- px per foot of height
  local szEnd = ground - floor(p.pz * Z)
  local sbx = sx0 + (PW - 22) * (1 - u)
  local sby = szEnd - floor((1 - u) * 6)
  gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
  gfx.drawLine(sx0 + PW - 22, szEnd - 6, sbx, sby)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillCircleAtPoint(sbx, sby, 3)
  -- the bat's plane through the zone (over / under it on a miss)
  local bz = p.pz
  if kind == "over" then bz = p.pz + 0.45 elseif kind == "under" then bz = p.pz - 0.45 end
  if s > 0 then
    local by2 = ground - floor(bz * Z)
    gfx.setLineWidth(2)
    gfx.drawLine(sx0 - 8, by2 + 3, sx0 + 10, by2 - 2)
    gfx.setLineWidth(1)
    if (kind == "over" or kind == "under") and s >= 1 then
      -- the gap, with ticks
      gfx.drawLine(sx0 + 12, by2, sx0 + 12, szEnd)
      gfx.drawLine(sx0 + 10, by2, sx0 + 14, by2)
      gfx.drawLine(sx0 + 10, szEnd, sx0 + 14, szEnd)
    end
  end
  -- contact: a flash at the crossing, then the launch angle off the bat
  if kind == "x" and t >= tP then
    local cbt = t - tP
    if cbt < 0.15 then
      gfx.setColor(gfx.kColorBlack)
      for k = 0, 5 do
        local aa = k * math.pi / 3 + 0.3
        gfx.drawLine(bxEnd, byEnd, bxEnd + cos(aa) * 8, byEnd + sin(aa) * 8)
      end
    end
    local cb = contactBeat(tl, b)
    local la = math.rad(cb and cb.e.la or 15)
    local q = K.clamp(cbt / 0.4, 0, 1)
    local lx = sx0 + cos(la) * 44 * q
    local ly = szEnd - sin(la) * 44 * q
    gfx.setLineWidth(2)
    gfx.drawLine(sx0, szEnd, lx, ly)
    gfx.setLineWidth(1)
    if q >= 1 then
      -- arrowhead
      local dx, dy = cos(la), -sin(la)
      gfx.drawLine(lx, ly, lx - dx * 6 - dy * 3, ly - dy * 6 + dx * 3)
      gfx.drawLine(lx, ly, lx - dx * 6 + dy * 3, ly - dy * 6 - dx * 3)
    end
  end
end

--- the anchor pitch beat and pitch time for the current beat, if a PiP belongs here
local function anchor(tl, bi, b, tau)
  if b.kind == "p" then return b, tau end
  if b.kind == "bip" then
    local pb = tl.beats[bi - 1]
    if pb and pb.kind == "p" and pb.e.r == "X" then return pb, pb.dur + tau end
  end
  return nil
end

--- where it goes: the bottom corner away from the ball / batter on screen; never over the
--- K-zone inset on the pitch cams
local function corner(R, b, t, camName)
  -- (below the win-chance panel, above the ticker)
  if camName == "pitch" or camName == "behindPlate" then return 244, 124 end
  local p = b.plan.pitch
  local x
  if R and R.project then
    local Play = BallCast.Play
    local bx, by, bz = Play.ballAt(b.plan, min(t, b.dur))
    local sx = bx and R:project(bx, by, bz)
    local hx = R:project(-(p.side or 1) * 3.2, 0.6, 3)
    x = sx or hx
  end
  if x and x > 210 then return 6, 124 end
  return 244, 124
end

--- per frame (from the TV overlay). opts: { speed, scrubbing, logOpen, dismissed }
function PiP.draw(G, R, bi, b, tau, camName, opts)
  local tl = G.tl
  local ab, t = anchor(tl, bi, b, tau)
  if not ab then return false end
  local tier
  if PiP.force then
    -- (harness: any swing, pacing ignored)
    if ab.e.r ~= "S" and ab.e.r ~= "F" and ab.e.r ~= "X" then return false end
  else
    if opts.scrubbing or opts.logOpen or opts.speed > 2 or opts.dismissed == ab.n then return false end
    tier = PiP.tier(tl, ab)
    if not tier or (opts.speed == 2 and tier ~= 1) then return false end
  end
  local p = ab.plan.pitch
  -- it opens once the pitch is in (the mitt, the foul, the contact) and runs the swing back,
  -- LAG behind: opening as the pitch came in told you he'd swing (and on a two-strike pitch, or
  -- an extra-base hit's, what was coming)
  local tIn = p.tPlate + 0.1
  local verdict, kind = PiP.verdict(tl, ab)
  local tOut = ((kind == "x") and (ab.dur + 1.5) or (p.tPlate + 1.6)) + LAG
  if t < tIn or t > tOut + 0.22 then return false end
  local open = ease((t - tIn) / 0.22)
  if t > tOut then open = 1 - ease((t - tOut) / 0.22) end
  local x0, y0 = corner(R, ab, t, camName)
  local red = A.reduce
  -- fold open from the corner nearest the screen edge (a clip that grows); reduce: fade
  local w, h = W, H
  if not red then w, h = max(1, floor(W * open)), max(1, floor(H * open)) end
  local fromLeft = x0 < 200
  local cx = fromLeft and x0 or (x0 + W - w)
  local cy = y0 + H - h
  gfx.setScreenClipRect(cx, cy, w, h)
  panelImg():draw(x0, y0)
  drawSwing(x0, y0, tl, ab, t - LAG, kind)
  if t - LAG >= p.tPlate + 0.15 then
    local li = labelImg(verdict)
    local lw = li:getSize()
    li:draw(x0 + (W - lw) // 2, y0 + H - 11)
  end
  gfx.clearClipRect()
  if red and open < 1 then A.shade(x0, y0, W, H, 1 - open, true) end
  -- edge glint while it unfolds
  if not red and open < 1 and open > 0 then
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(cx, cy, w, h)
    gfx.setColor(gfx.kColorBlack)
  end
  return true, x0, y0
end

function PiP.release() panel, labels = nil, {} end

return PiP
