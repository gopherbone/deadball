-- DBN "SPIN CAM": the ball up close under the K-zone inset on the pitch cams, its seams
-- turning while the pitch is in the air, then a short hold.
--
-- The frames are prerendered offline (tools/tv/spin_ball.py -> images/tv/spin-table-40-40:
-- six rows of 24 frames: four-seam, two-seam, curve, gyro, changeup tumble, knuckler wobble)
-- and loaded once in the loader; a frame costs one blit. The pitch type picks the row, its
-- spin rate picks the on-screen speed. The label ("4-SEAM 2,310 RPM") is prerendered by the
-- look-ahead queue. Enhanced League: FIREBALL burns, CLOUD_BALL dissolves, WARP_PITCH
-- blinks, STOPPER stops.

import "ballcast/kit"
import "ballcast/tv/art"

local gfx <const> = playdate.graphics
local floor <const>, min <const>, max <const> = math.floor, math.min, math.max

BallCast = BallCast or {}
local Sp = {}
BallCast.TVSpin = Sp
local A = BallCast.TVArt
local K = BCKit

local N <const> = 24
-- pitch type -> { row, nominal rpm, label }
local TYPES = {
  FB = { 1, 2300, "4-SEAM" }, SI = { 2, 2150, "SINKER" }, CT = { 4, 2400, "CUTTER" }, SL = { 4, 2450, "SLIDER" },
  CB = { 3, 2650, "CURVE" }, CU = { 3, 2650, "CURVE" }, CH = { 5, 1750, "CHANGEUP" }, SPL = { 5, 1350, "SPLITTER" },
  KN = { 6, 60, "KNUCKLER" }, SPIT = { 2, 900, "SPITTER" },
}
local POWER_LABEL = { FIREBALL = "FIREBALL. 9,999 RPM", CLOUD_BALL = "CLOUD BALL. RPM: ?", WARP_PITCH = "WARP PITCH. RPM: ERR",
  STOPPER = "STOPPER. 0 RPM" }

local tbl
local labels = {}
local BOX_W <const>, BOX_H <const> = 64, 68
local X0 <const>, Y0 <const> = 4, 148           -- under the K-zone inset (4, 62, 64 x 84)

local function comma(n)
  local s = tostring(n)
  if #s > 3 then s = s:sub(1, #s - 3) .. "," .. s:sub(-3) end
  return s
end

--- the label lines for a pitch: name, rpm (deadpan, seeded per pitcher)
function Sp.text(b)
  local ty = TYPES[b.e.t] or TYPES.FB
  local power = b.plan.power
  if power and POWER_LABEL[power] then
    local a, z = POWER_LABEL[power]:match("^(.-)%. (.*)$")
    return a, z
  end
  local rpm = ty[2] + floor(K.hash01(b.pre.pit or "?", 71) * 30 - 15) * 10 + floor(K.hash01(b.i, 72) * 6) * 10
  if ty[3] == "KNUCKLER" then rpm = 40 + floor(K.hash01(b.i, 73) * 50) end
  local tail = ty[3] == "SPITTER" and " RPM. DAMP." or " RPM"
  return ty[3], comma(max(0, rpm)) .. tail, rpm
end

local function label(s)
  local img = labels[s]
  if img then return img end
  local f = K.fonts.tiny
  img = gfx.image.new(BOX_W - 4, 9, gfx.kColorClear)
  gfx.pushContext(img)
  K.text(f, K.fit(f, s, BOX_W - 6), (BOX_W - 4) // 2, 1, "center")
  gfx.popContext()
  labels[s] = img
  return img
end

--- loader (b nil): the frames; the look-ahead queue (b): that pitch's two label lines
function Sp.prewarm(b)
  if not b then
    tbl = tbl or gfx.imagetable.new("images/tv/spin")
    return
  end
  local a, z = Sp.text(b)
  label(a); label(z)
end

--- the frame index (1-based) for pitch-beat time tau
local function frameAt(b, tau, row, rpm)
  local p = b.plan.pitch
  local t = math.min(tau, p.tPlate) - p.tRel
  if b.plan.stall and tau >= b.plan.stall[1] then
    -- STOPPER: it stops; the spin resumes after the stall
    t = (tau >= b.plan.stall[2]) and (math.min(tau, p.tPlate) - p.tRel - (b.plan.stall[2] - b.plan.stall[1])) or (b.plan.stall[1] - p.tRel)
  end
  if t < 0 then t = 0 end
  local f
  if row == 6 then
    f = floor(t * 30) % N                                   -- the knuckler's wobble
  else
    local fps = math.max(6, math.min(40, rpm / 2300 * 30))  -- readable, scaled with the rpm
    f = floor(t * fps) % N
  end
  return (row - 1) * N + f + 1
end

local function ease(t) t = K.clamp(t, 0, 1); return 1 - (1 - t) ^ 3 end
local hdrImg, textB, textA, textZ, textR

--- per frame (pitch cams). opts: { speed, scrubbing, logOpen }
function Sp.draw(b, tau, camName, opts)
  if b.kind ~= "p" or not b.plan.pitch then return false end
  if camName ~= "pitch" and camName ~= "behindPlate" then return false end
  if not Sp.force and (opts.scrubbing or opts.logOpen or (opts.speed or 1) > 2) then return false end
  if not tbl then Sp.prewarm(nil) end
  if not tbl then return false end
  local p = b.plan.pitch
  local tIn, tOut = p.tRel - 0.25, p.tPlate + 0.6
  if b.k and b.plan.kT then tOut = math.min(tOut, b.plan.kT) end    -- (the K card wants the corner)
  if tau < tIn or tau > tOut + 0.15 then return false end
  local open = ease((tau - tIn) / 0.15)
  if tau > tOut then open = 1 - ease((tau - tOut) / 0.15) end
  local red = A.reduce
  local h = red and BOX_H or max(1, floor(BOX_H * open))
  -- unfold downward from the K-zone's bottom edge
  gfx.setScreenClipRect(X0, Y0, BOX_W, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(X0, Y0, BOX_W, BOX_H)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(X0 + 2, Y0 + 10, BOX_W - 4, BOX_H - 12)
  hdrImg = hdrImg or A.text("tiny", "SPIN CAM", "w")
  hdrImg:draw(X0 + 4, Y0 + 2)
  local ty = TYPES[b.e.t] or TYPES.FB
  -- (the labels once per pitch, not a string build every frame)
  if textB ~= b then textB, textA, textZ, textR = b, Sp.text(b) end
  local name, rpmText, rpm = textA, textZ, textR
  local power = b.plan.power
  local bx, by = X0 + (BOX_W - 40) // 2, Y0 + 11
  local fi = frameAt(b, tau, ty[1], rpm or ty[2])
  local img = tbl:getImage(fi)
  local show = true
  if power == "WARP_PITCH" and b.plan.warp and math.abs(tau - b.plan.warp) < 0.2 then
    -- blinks out and back, a few px over
    show = floor(tau * 20) % 2 == 0
    if tau > b.plan.warp then bx = bx + 3 end
  end
  if power == "FIREBALL" and tau >= p.tRel - 0.1 then
    -- flames behind it, flickering (deterministic per frame)
    local n = floor(tau * 30)
    gfx.setColor(gfx.kColorBlack)
    for k = 0, 4 do
      local fx = bx + 4 + k * 8 + floor(K.hash01(n, k) * 4)
      local fh = 10 + floor(K.hash01(n, k + 10) * 10)
      gfx.fillTriangle(fx - 5, by + 22, fx + 5, by + 22, fx + floor(K.hash01(n, k + 20) * 6) - 3, by + 22 - fh - 14)
    end
  end
  if show then
    if power == "CLOUD_BALL" and b.plan.cloud and tau >= b.plan.cloud[1] then
      local q = K.clamp((tau - b.plan.cloud[1]) / math.max(0.05, b.plan.cloud[2] - b.plan.cloud[1]), 0, 1)
      img:drawFaded(bx, by, 1 - q * 0.85, gfx.image.kDitherTypeBayer4x4)
    else
      img:draw(bx, by)
    end
  end
  if power == "STOPPER" and b.plan.stall and tau >= b.plan.stall[1] and tau < b.plan.stall[2] then
    A.text("tiny", "STOPPED", "b"):draw(X0 + 16, by + 16)
  end
  label(name):draw(X0 + 2, Y0 + BOX_H - 19)
  label(rpmText):draw(X0 + 2, Y0 + BOX_H - 10)
  gfx.clearClipRect()
  if red and open < 1 then A.shade(X0, Y0, BOX_W, BOX_H, 1 - open, true) end
  return true
end

function Sp.release() tbl, labels, hdrImg, textB = nil, {}, nil, nil end

return Sp
