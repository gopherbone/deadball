-- DBN call text: every pitch's and play's result in big letters. BALL, STRIKE (with a small
-- "SWINGING" / "LOOKING" tag), FOUL, BALL FOUR, HIT BY PITCH, STRIKE THREE, and on balls in
-- play OUT / SAFE / SINGLE / DOUBLE / TRIPLE with a small tag (the homer has its own banner).
--
-- The vocabulary is fixed, so every call is one prerendered image (a black plate, the word in
-- WordArt, the tag under it), made in the loader; showing one is a blit. It slams in (bigger
-- for the big ones), holds, and wipes out to the right; reduceMotion: plain show/hide.
--
-- Where: bottom-left, between the spin cam (x 4-68) and the pitcher, above the ticker; it
-- moves to the bottom-right when the swing cam has taken the bottom-left.

import "ballcast/kit"
import "ballcast/tv/art"

local gfx <const> = playdate.graphics
local floor <const>, min <const>, max <const> = math.floor, math.min, math.max

BallCast = BallCast or {}
local C = {}
BallCast.TVCalls = C
local A = BallCast.TVArt
local K = BCKit

local HOLD <const> = 0.75
local IN <const>, OUT <const> = 0.12, 0.15
local X <const>, Y_BOTTOM <const> = 72, 221     -- left edge; the plate's bottom edge

-- word, tag, big (1 = a key call: bigger slam, a white rim)
local VOCAB = {
  ball = { "BALL" }, strikeC = { "STRIKE", "LOOKING" }, strikeS = { "STRIKE", "SWINGING" }, foul = { "FOUL" },
  ball4 = { "BALL FOUR", nil, 1 }, hbp = { "HIT", "BY PITCH", 1 }, k3C = { "STRIKE 3", "CALLED", 1 }, k3S = { "STRIKE 3", "SWINGING", 1 },
  outG = { "OUT", "ON THE GROUND" }, outF = { "OUT", "IN THE AIR" }, outL = { "OUT", "ON A LINER" }, outP = { "OUT", "POPPED UP" },
  outFoul = { "OUT", "FOUL POP" }, outSF = { "OUT", "SAC FLY. A RUN SCORES" }, outDP = { "OUT", "TWO OF THEM", 1 },
  fc = { "SAFE", "FIELDER'S CHOICE" }, roe = { "SAFE", "ON AN ERROR", 1 },
  single = { "SINGLE", nil, 1 }, double = { "DOUBLE", nil, 1 }, triple = { "TRIPLE", nil, 1 },
}
C.VOCAB = VOCAB

local imgs = {}
local function callImg(key)
  local img = imgs[key]
  if img then return img end
  local v = VOCAB[key]
  local word = A.text("wa", v[1], "wa")
  local ww, wh = word:getSize()
  local tag = v[2] and A.text("tiny", v[2], "w")
  local tw = tag and tag:getSize() or 0
  local w = max(ww, tw) + 12
  local h = wh + (tag and 11 or 0) + 8
  img = gfx.image.new(w, h, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, w, h)
  if v[3] then
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(1, 1, w - 2, h - 2)
    gfx.setColor(gfx.kColorBlack)
  end
  word:draw((w - ww) // 2, 4)
  if tag then tag:draw((w - tw) // 2, wh + 5) end
  gfx.popContext()
  imgs[key] = img
  return img
end

--- loader: every call image, one per step
function C.prewarmSteps(step)
  for key in pairs(VOCAB) do step("tv call " .. key, function() callImg(key) end) end
end

---------------------------------------------------------------------------
-- what the call is, and when (pitch-beat or bip-beat time)

local OUT_KEY = { GO = "outG", FO = "outF", LO = "outL", PO = "outP" }

--- key, t0 for beat b (nil when it gets no call)
function C.callFor(tl, b)
  local plan = b.plan
  if b.kind == "p" and plan.pitch then
    local p, e = plan.pitch, b.e
    local t = p.tPlate + 0.18          -- (the pop in the mitt is at tPlate + 0.06; the ump's call)
    if b.k then return (e.r == "C") and "k3C" or "k3S", (plan.kT or t) end
    if e.r == "H" then return "hbp", (plan.hbp or p.tPlate) + 0.2 end
    if b.walk then return "ball4", p.tPlate + 0.25 end
    if e.r == "B" then return "ball", t end
    if e.r == "C" then return "strikeC", t end
    if e.r == "S" then return "strikeS", t end
    if e.r == "F" then return "foul", t + 0.1 end
    return nil
  end
  if b.kind == "bip" then
    local res = b.e.res
    -- once the picture has shown it (play.lua plan.callT): the catch, the throw beating him to
    -- the bag, the hitter into his base, the last out of two. (It used to slam in at the
    -- outfielder's pickup, and 0.4 s before the throw reached first on a grounder.)
    local t = (plan.callT or max(0.5, b.dur - 1.7)) + 0.12
    if res == "HR" then return nil end                       -- (the HOME RUN banner)
    if res == "1B" then return "single", t end
    if res == "2B" then return "double", t end
    if res == "3B" then return "triple", t end
    if res == "DP" then return "outDP", t end
    -- ("A RUN SCORES": once he has)
    if res == "SF" then return "outSF", max(t, (plan.scoreT or 0) + 0.12) end
    if res == "FC" then return "fc", t end
    if res == "ROE" then return "roe", t end
    if res == "FOUL_OUT" then return "outFoul", t end
    return OUT_KEY[b.e.out] or "outG", t
  end
  return nil
end

local KEY_OUTCOME = { k3C = true, k3S = true, ball4 = true, hbp = true, single = true, double = true, triple = true, outDP = true, roe = true }

local function ease(t) t = K.clamp(t, 0, 1); return 1 - (1 - t) ^ 3 end

--- per frame. opts: { speed, scrubbing, logOpen, pipLeft }
function C.draw(tl, b, tau, opts)
  if opts.scrubbing or opts.logOpen then return false end
  local key, t0 = C.callFor(tl, b)
  if not key then return false end
  if (opts.speed or 1) > 2 and not KEY_OUTCOME[key] then return false end
  local age = tau - t0
  if age < 0 or age > HOLD + OUT then return false end
  local img = callImg(key)
  local w, h = img:getSize()
  local big = VOCAB[key][3]
  -- (the high-home shot has the batter bottom-center: use the right side there, unless the
  -- swing cam has it)
  local x = (opts.pipLeft or (opts.cam == "behindPlate" and not opts.pipOn)) and (396 - w) or X
  local y = Y_BOTTOM - h
  if A.reduce then
    img:draw(x, y)
    return true
  end
  if age < IN then
    -- slam: from big down to size (bigger for the key calls)
    local s = 1 + (1 - ease(age / IN)) * (big and 1.0 or 0.5)
    img:drawScaled(x + w / 2 - w * s / 2, y + h / 2 - h * s / 2, s)
  elseif age > HOLD then
    -- wipe out to the right
    local q = ease((age - HOLD) / OUT)
    local cut = floor(w * q)
    gfx.setScreenClipRect(x + cut, y, w - cut, h)
    img:draw(x, y)
    gfx.clearClipRect()
  else
    img:draw(x, y)
    if big and age < IN + 0.08 then
      gfx.setColor(gfx.kColorWhite)
      gfx.drawRect(x - 2, y - 2, w + 4, h + 4)
      gfx.setColor(gfx.kColorBlack)
    end
  end
  return true
end

function C.release() imgs = {} end

return C
