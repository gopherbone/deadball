-- BallCast HUD: scorebug, pitch box, telegraph ticker, win-chance panel, banners,
-- lower thirds and incident callouts. Static parts are cached into images and only
-- re-rendered when what they show changes.

import "ballcast/kit"
import "ballcast/tv/art"

local gfx <const> = playdate.graphics
local floor <const>, sin <const>, abs <const> = math.floor, math.sin, math.abs

BallCast = BallCast or {}
local H = {}
BallCast.HUD = H
local K = BCKit

---------------------------------------------------------------------------
-- scorebug (top-left)

local bugImg, bugKey

local function dots(x, y, n, max, label)
  local f = K.fonts.tiny
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  f:drawText(label, x, y)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  for i = 1, max do
    local cx = x + 8 + (i - 1) * 7
    gfx.setColor(gfx.kColorWhite)
    if i <= n then gfx.fillRect(cx, y + 1, 5, 5) else gfx.drawRect(cx, y + 1, 5, 5) end
  end
end

local BUG_W <const> = 240

local function diamond(x, y, b1, b2, b3)
  local function base(bx, by, on)
    gfx.setColor(gfx.kColorWhite)
    local p = { bx, by - 4, bx + 4, by, bx, by + 4, bx - 4, by }
    if on then gfx.fillPolygon(table.unpack(p)) else gfx.drawPolygon(table.unpack(p)) end
  end
  base(x + 7, y + 5, b2)
  base(x + 12, y + 10, b1)
  base(x + 2, y + 10, b3)
end

-- Split so a pitch never re-renders text: the base (teams, runs, P / AB names) is cached and
-- re-rendered only when one of those changes; the count area (half arrow, inning, bases,
-- B/S/O lights) is drawn live each frame from a dozen primitives and cached small images.
local bugLabels
local function countArea(x0, y0, st, b, s)
  local A = BallCast.TVArt
  -- inning arrow
  local ax, ay = x0 + 61, y0 + (st.top and 6 or 20)
  gfx.setColor(gfx.kColorWhite)
  if st.top then gfx.fillTriangle(ax, ay + 4, ax + 4, ay, ax + 8, ay + 4)
  else gfx.fillTriangle(ax, ay - 4, ax + 4, ay, ax + 8, ay - 4) end
  A.text("nb", tostring(st.inn or 1), "w"):draw(x0 + 72, y0 + 8)
  diamond(x0 + 88, y0 + 4, st.b1, st.b2, st.b3)
  if not bugLabels then
    bugLabels = gfx.image.new(8, 24, gfx.kColorClear)
    gfx.pushContext(bugLabels)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    K.fonts.tiny:drawText("B", 0, 0); K.fonts.tiny:drawText("S", 0, 8); K.fonts.tiny:drawText("O", 0, 16)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    gfx.popContext()
  end
  bugLabels:draw(x0 + 108, y0 + 4)
  local outs = math.min(st.outs or 0, 2) + ((st.outs or 0) >= 3 and 1 or 0)
  local function lights(y, n, max)
    for i = 1, max do
      local cx = x0 + 116 + (i - 1) * 7
      if i <= n then gfx.fillRect(cx, y + 1, 5, 5) else gfx.drawRect(cx, y + 1, 5, 5) end
    end
  end
  gfx.setColor(gfx.kColorWhite)
  lights(y0 + 4, b, 3)
  lights(y0 + 12, s, 2)
  lights(y0 + 20, outs, 3)
  gfx.setColor(gfx.kColorBlack)
end

-- the whole bug as drawn (base + count area + names) is kept as one opaque image and redrawn
-- only when something on it changes (a pitch, an out, a runner, a new batter): a blit a frame
local compImg
local compKey = {}
local bugVer = 0      -- (bumped each time the base image is redrawn)
local function drawBug(st, final, b, s, pitImg, batImg)
  bugImg:draw(2, 2)
  if not final then
    countArea(2, 2, st, b, s)
    -- pitcher / batter: proper-cased last names in a clean face, cached per person
    if pitImg then pitImg:draw(166, 3) end
    if batImg then batImg:draw(166, 16) end
  end
end
local function bugChanged(k, st, final, b, s, pitImg, batImg)
  local top, b1, b2, b3 = st.top and true or false, st.b1 and true or false, st.b2 and true or false, st.b3 and true or false
  local outs = st.outs or 0
  if k.ver == bugVer and k.final == final and k.inn == st.inn and k.top == top and k.b1 == b1 and k.b2 == b2 and k.b3 == b3
    and k.b == b and k.s == s and k.outs == outs and k.pit == pitImg and k.bat == batImg then return false end
  k.ver, k.final, k.inn, k.top, k.b1, k.b2, k.b3, k.b, k.s, k.outs, k.pit, k.bat = bugVer, final, st.inn, top, b1, b2, b3, b, s, outs, pitImg, batImg
  return true
end

function H.scorebug(st, meta, final)
  local b, s = math.min(st.b or 0, 3), math.min(st.s or 0, 2)
  H.buildBug(st, meta, final)
  local pitImg, batImg
  if not final then
    local people = meta.people or {}
    H.drawing = true
    if st.pit and people[st.pit] then pitImg = H.bugName(people[st.pit].name) end
    if st.bat and people[st.bat] then batImg = H.bugName(people[st.bat].name) end
    H.drawing = false
  end
  if bugChanged(compKey, st, final, b, s, pitImg, batImg) or not compImg then
    -- (drawn at its screen spot through a draw offset: the image's (0, 0) is the screen's (2, 2))
    compImg = compImg or gfx.image.new(BUG_W, 30, gfx.kColorBlack)
    gfx.pushContext(compImg)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    gfx.setDrawOffset(-2, -2)
    drawBug(st, final, b, s, pitImg, batImg)
    gfx.setDrawOffset(0, 0)
    gfx.popContext()
  end
  compImg:draw(2, 2)
end

--- the scorebug's base image (teams, runs, labels) for this score; the loader calls it for
--- the first frame's state, so the replay's first frame renders no text
function H.buildBug(st, meta, final)
  local away = meta.away and meta.away.abbr or "AWY"
  local home = meta.home and meta.home.abbr or "HOM"
  local k = bugKey
  if not k or k.away ~= st.away or k.home ~= st.home or k.final ~= final then
    local tb = playdate.getElapsedTime()
    k = k or {}
    k.away, k.home, k.final = st.away, st.home, final
    bugKey = k
    bugVer = bugVer + 1
    bugImg = bugImg or gfx.image.new(BUG_W, 30, gfx.kColorBlack)
    gfx.pushContext(bugImg)
    gfx.clear(gfx.kColorBlack)
    local f = K.fonts.nb
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    f:drawText(away, 4, 2)
    f:drawText(home, 4, 15)
    K.text(f, tostring(st.away), 50, 2, "right")
    K.text(f, tostring(st.home), 50, 15, "right")
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawLine(55, 2, 55, 27)
    if final then
      K.textW(f, "FINAL", 60, 8)
    else
      local lab = K.fonts.tiny
      gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
      gfx.setColor(gfx.kColorWhite)
      gfx.drawLine(140, 3, 140, 26) -- divider between the count and the names
      lab:drawText("P", 144, 4)
      lab:drawText("AB", 144, 17)
      gfx.setImageDrawMode(gfx.kDrawModeCopy)
    end
    gfx.popContext()
    H.slow("scorebug", tb)
  end
end

--- loader: the count area's small images (B/S/O labels, inning numbers)
function H.prewarmBugBits()
  countArea(-400, -400, { inn = 1, top = true }, 0, 0)   -- (off screen: builds the labels)
  for i = 1, 15 do BallCast.TVArt.text("nb", tostring(i), "w") end
end

local bugNames = {}
--- a scorebug name image (white, fitted), cached; the TV layer prerenders the ones coming up
function H.bugName(full)
  local img = bugNames[full or "?"]
  if img then return img end
  local t0 = playdate.getElapsedTime()
  local t = K.fonts.bold
  -- the surname in the bug's face; a long one ("Stottlemyre", "Shaughnessy") steps down to the
  -- narrower Nontendo faces before it's cut
  local s, f = K.fitChain({ t, K.fonts.nb, K.fonts.nl }, K.lastName(full or ""), BUG_W - 168)
  img = gfx.image.new(BUG_W - 166, t:getHeight(), gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  f:drawText(s, 0, (t:getHeight() - f:getHeight()) // 2)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.popContext()
  bugNames[full or "?"] = img
  H.slow("scorebug name " .. tostring(full), t0)
  return img
end

---------------------------------------------------------------------------
-- pitch box (top-right): pitch type + mph

local PN = { FB = "FASTBALL", SI = "SINKER", CT = "CUTTER", SL = "SLIDER", CB = "CURVE", CH = "CHANGEUP", SPL = "SPLITTER", KN = "KNUCKLER", SPIT = "SPITTER" }

local TVA = function() return BallCast.TVArt end

--- Radar gun (top-right): an LCD readout whose digits roll up to the velocity, the pitch
--- type and the pitcher's pitch count (H.pitchNo, set by the TV layer). 30 px tall, like the
--- old box, so the tags under it don't move. Static parts cached per (pitch, count).
local gunT0, gunKey
local GUN_W <const>, GUN_H <const> = 132, 29
--- the gun's words as cached images (names per pitch type, labels, small digits)
function H.prewarmGun()
  local A = TVA()
  for _, n in pairs(PN) do A.text("nb", n, "w") end
  A.text("tiny", "MPH", "w"); A.text("tiny", "PITCH", "w")
  for d = 0, 9 do A.text("tiny", tostring(d), "w") end
end
-- the whole gun as drawn, one opaque image redrawn only when it changes (a new pitch, the
-- digits rolling up): a blit a frame
local gunImg, gunPv, gunNo, gunShown
local drawGun
function H.pitchBox(pt, pv, x, y)
  if not pt then return end
  local A = TVA()
  local name = PN[pt] or pt
  x = x or (398 - GUN_W)
  y = y or 2
  if name ~= gunKey or pv ~= gunPv or H.pitchNo ~= gunNo then
    gunKey, gunPv, gunNo = name, pv, H.pitchNo
    gunT0 = playdate.getCurrentTimeMilliseconds()
    gunShown = nil
  end
  -- digits: roll up from 60 over a third of a second
  local v = tonumber(pv) or 0
  local age = (playdate.getCurrentTimeMilliseconds() - gunT0) / 1000
  local shown = v
  if age < 0.35 and A and not A.reduce then shown = math.floor(60 + (v - 60) * (1 - (1 - age / 0.35) ^ 3)) end
  -- (the cached image only where it's exact: the name inside the frame, the LCD's dither on
  -- the screen's 2 px grid)
  if x % 2 ~= 0 or y % 2 ~= 0 or A.text("nb", name, "w"):getSize() > GUN_W - 52 then
    drawGun(A, name, x, y, shown)
    return
  end
  if shown ~= gunShown or not gunImg then
    gunShown = shown
    gunImg = gunImg or gfx.image.new(GUN_W, GUN_H, gfx.kColorBlack)
    gfx.pushContext(gunImg)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    drawGun(A, name, 0, 0, shown)
    gfx.popContext()
  end
  gunImg:draw(x, y)
end
drawGun = function(A, name, x, y, shown)
  -- frame + LCD window: three fills
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x, y, GUN_W, GUN_H)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x + 2, y + 2, 46, 25)
  gfx.setColor(gfx.kColorBlack)
  gfx.setDitherPattern(0.9, gfx.image.kDitherTypeBayer2x2)
  gfx.fillRect(x + 2, y + 2, 46, 25)
  gfx.setColor(gfx.kColorBlack)
  A.text("nb", name, "w"):draw(x + 52, y + 1)
  A.text("tiny", "MPH", "w"):draw(x + 52, y + 17)
  if H.pitchNo then
    local ds = tostring(H.pitchNo)
    local dx = x + GUN_W - 3
    for i = #ds, 1, -1 do
      local di = A.text("tiny", ds:sub(i, i), "w")
      dx = dx - di:getSize()
      di:draw(dx, y + 17)
    end
    local pl = A.text("tiny", "PITCH", "w")
    pl:draw(dx - pl:getSize() - 3, y + 17)
  end
  local s = tostring(math.max(0, math.min(199, shown)))
  if A then
    local dx = x + 46 - #s * 14
    for i = 1, #s do A.digit(tonumber(s:sub(i, i))):draw(dx + (i - 1) * 14, y + 4) end
  end
end

--- small tag under the pitch box: LIVE / REPLAY 2x / PAUSED
-- (each one drawn once into an opaque image, then a blit a frame: no text rendering)
local tagImgs = { [true] = {}, [false] = {} }
local TAG_H <const> = 11
local drawTag
function H.tag(text, x, y, invert)
  invert = invert and true or false
  local img = tagImgs[invert][text]
  if not img then
    local w = K.fonts.tiny:getTextWidth(text) + 8
    img = gfx.image.new(w, TAG_H, gfx.kColorBlack)
    gfx.pushContext(img)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    drawTag(text, w, 0, invert)
    gfx.popContext()
    tagImgs[invert][text] = img
  end
  img:draw(x - img:getSize(), y)
end
drawTag = function(text, x, y, invert)
  local f = K.fonts.tiny
  local w = f:getTextWidth(text) + 8
  x = x - w
  gfx.setColor(invert and gfx.kColorWhite or gfx.kColorBlack)
  gfx.fillRect(x, y, w, TAG_H)
  if invert then
    gfx.setColor(gfx.kColorBlack); gfx.drawRect(x, y, w, TAG_H)
    f:drawText(text, x + 4, y + 2)
  else
    K.textW(f, text, x + 4, y + 2)
  end
end

---------------------------------------------------------------------------
-- telegraph ticker (bottom strip): newest line types itself in from the right

local tape = { img = nil, text = "", reveal = 0, from = 0, w = 0 }
local TICK_H <const> = 15

-- Only the tail of the tape is rendered (the strip shows the newest ~55 characters; older
-- text has scrolled off), so a new line costs a ~600 px image, not a 4000 px one.
local TAPE_KEEP <const> = 90
function H.tickerSet(lines, instant)
  local full = string.upper(table.concat(lines, "  \xc2\xb7\xc2\xb7\xc2\xb7  "))
  if full == tape.full then return end
  local f = K.fonts.mono
  local keepFrom = math.max(1, #full - TAPE_KEEP + 1)
  -- don't cut inside a multi-byte character
  while keepFrom > 1 and keepFrom <= #full and (full:byte(keepFrom) or 0) >= 0x80 and (full:byte(keepFrom) or 0) < 0xC0 do keepFrom = keepFrom + 1 end
  local text = full:sub(keepFrom)
  local prevW = 0
  local prev = tape.full or ""
  if not instant and prev ~= "" and full:sub(1, #prev) == prev then
    -- the part already typed: the old tape's characters that are still in the kept tail
    local shown = #prev - keepFrom + 1
    if shown > 0 then prevW = f:getTextWidth(text:sub(1, shown)) end
  end
  tape.full = full
  tape.text = text
  local w = math.min(4000, f:getTextWidth(text) + 8)
  tape.img = gfx.image.new(w, TICK_H, gfx.kColorBlack)
  gfx.pushContext(tape.img)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  f:drawText(text, 2, 0)
  gfx.popContext()
  tape.w = w
  tape.reveal = instant and w or prevW
end

-- between lines (nothing typing) the strip only changes when the cursor blinks: it's kept as
-- one opaque image, redrawn on a blink or a new line
local stripImg, stripTape, stripR, stripCur
local drawTicker
--- returns true while typing (for the telegraph clatter)
function H.ticker(dt)
  local y = 240 - TICK_H
  local typing = false
  if tape.img and tape.reveal < tape.w then
    tape.reveal = math.min(tape.w, tape.reveal + dt * 260)
    typing = true
  end
  if typing or not tape.img then
    drawTicker(y, typing)
    return typing
  end
  local r = floor(tape.reveal)
  local cur = floor(playdate.getCurrentTimeMilliseconds() / 400) % 2 == 0
  if not stripImg or stripTape ~= tape.img or stripR ~= r or stripCur ~= cur then
    stripTape, stripR, stripCur = tape.img, r, cur
    stripImg = stripImg or gfx.image.new(400, TICK_H, gfx.kColorBlack)
    gfx.pushContext(stripImg)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    gfx.setDrawOffset(0, -y)
    drawTicker(y, false, cur)
    gfx.setDrawOffset(0, 0)
    gfx.popContext()
  end
  stripImg:draw(0, y)
  gfx.setColor(cur and gfx.kColorWhite or gfx.kColorBlack)   -- (as the live strip left it)
  return false
end
--- the strip as it stands at y (cur: the blinking cursor's phase; nil = now)
drawTicker = function(y, typing, cur)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, y, 400, TICK_H)
  if tape.img then
    if cur == nil then cur = floor(playdate.getCurrentTimeMilliseconds() / 400) % 2 == 0 end
    local r = floor(tape.reveal)
    local x = 6
    if r > 388 then x = 394 - r end
    gfx.setClipRect(x, y, r, TICK_H)
    tape.img:draw(x, y + 1)
    gfx.clearClipRect()
    -- cursor block
    if typing or cur then
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(math.min(394, x + r + 1), y + 3, 5, 9)
    end
  end
  -- telegraph key icon at left edge
end

---------------------------------------------------------------------------
-- win chance panel (top-right), mockup 02

local weImg, weKey

function H.winPanel(tl, upto, teamAbbr, forHome, bet, x, y)
  x, y = x or 266, y or 34
  local beats = tl.beats
  local key = upto * 4 + (forHome and 1 or 0) + #beats * 100000
  if key ~= weKey then
    weKey = key
    weImg = weImg or gfx.image.new(132, 74, gfx.kColorWhite)   -- (all painted: opaque blits faster)
    gfx.pushContext(weImg)
    gfx.clear(gfx.kColorWhite)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(0, 0, 132, 74)
    gfx.drawRect(1, 1, 130, 72)
    local f = K.fonts.tiny
    f:drawText(string.upper(teamAbbr or "") .. " WIN CHANCE", 5, 4)
    -- graph area
    local gx, gy, gw, gh = 5, 14, 122, 28
    gfx.setDitherPattern(0.75, gfx.image.kDitherTypeBayer4x4)
    gfx.drawLine(gx, gy + gh / 2, gx + gw, gy + gh / 2)
    gfx.setColor(gfx.kColorBlack)
    local total = math.max(upto, 1)
    local lastX, lastY
    local function wv(i)
      local w = beats[i] and beats[i].we or 0.5
      return forHome and w or (1 - w)
    end
    local span = math.max(total, 60)
    for px = 0, gw do
      local i = floor(px / gw * span + 0.5)
      if i > total then break end
      local w = i == 0 and (forHome and 0.5 or 0.5) or wv(i)
      local yy = gy + gh - w * gh
      if lastX then gfx.drawLine(lastX, lastY, gx + px, yy) end
      lastX, lastY = gx + px, yy
    end
    if lastX then gfx.fillCircleAtPoint(lastX, lastY, 2) end
    -- before ▸ now
    local nowW = wv(total)
    local prevI = total
    -- compare to start of this half inning
    for i = total, 1, -1 do if beats[i].kind == "half" then prevI = math.max(1, i - 1) break end end
    local prevW = prevI >= 1 and wv(prevI) or 0.5
    local nf = K.fonts.nb
    nf:drawText(floor(prevW * 100 + 0.5) .. "%", 5, 45)
    f:drawText(">", 37, 48)
    nf:drawText(floor(nowW * 100 + 0.5) .. "%", 45, 45)
    gfx.drawLine(4, 59, 127, 59)
    K.text(f, bet and (K.money(bet.amount) .. " AT RISK") or "NO BET", 66, 63, "center")
    gfx.popContext()
  end
  weImg:draw(x, y)
end

---------------------------------------------------------------------------
-- banners

local bannerCache = {}
local function textImage(font, s, pad)
  local key = tostring(font) .. s
  local img = bannerCache[key]
  if img then return img end
  pad = pad or 6
  local w, h = font:getTextWidth(s) + pad * 2, font:getHeight() + pad
  img = gfx.image.new(w, h, gfx.kColorClear)
  gfx.pushContext(img)
  -- outlined text: black stamp around, white fill
  gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
  for dx = -2, 2 do for dy = -2, 2 do font:drawText(s, pad + dx, pad // 2 + dy) end end
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  font:drawText(s, pad, pad // 2)
  gfx.popContext()
  bannerCache[key] = img
  return img
end
H.textImage = textImage

--- Film-strip SLO-MO bar across the top (mockup 02).
function H.sloBar(t)
  local y = 203
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, y, 400, 22)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(0, y, 400, y)
  -- sprocket holes
  local off = floor(t * 30) % 16
  for x = -off, 400, 16 do
    gfx.fillRect(x, y + 2, 8, 3)
    gfx.fillRect(x, y + 17, 8, 3)
  end
  local f = K.fonts.nb
  local s = "SLO-MO"
  local w = f:getTextWidth(s) + 16
  gfx.fillRect(200 - w / 2, y + 4, w, 14)
  K.textW(f, s, 200, y + 4, "center")
end

--- Big-moment banners. age: seconds since shown (pure in age, so scrubbing matches).
---   tier 1 (HOME RUN!, GRAND SLAM!, WALK-OFF..., the great catches): flash, starburst, rings,
---     a WordArt slam with shake, a striped band, a glint; collapses at the end
---   half-innings ("TOP 3RD"): a pill that drops in;  FINAL: letters stamp in one by one
---   everything else: a skewed band that whips in from the right with speed lines
local TIER1 = { ["HOME RUN!"] = true, ["GRAND SLAM!"] = true, ["WALK-OFF HOME RUN!"] = true, ["WALK-OFF!"] = true,
  ["LEAP CATCH! ROBBED!"] = true, ["WHAT A CATCH"] = true }

local function ease(t) t = math.max(0, math.min(1, t)); return 1 - (1 - t) ^ 3 end

local function tier1(text, age, A)
  local img = A.text("waBig", text, "wa")
  local w, h = img:getSize()
  local red = A.reduce
  local cy = 112
  if age < 0.06 then A.flash() end
  if age < 0.3 and not red then
    -- starburst behind it all, white wedges at half density (short and small: big fills cost)
    local r = 40 + math.min(1, age / 0.2) * 140
    gfx.setColor(gfx.kColorWhite)
    gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer4x4)
    local n, rot = 10, age * 1.4
    for i = 0, n - 1 do
      local a0 = rot + i * 2 * math.pi / n
      local a1 = a0 + math.pi / n
      gfx.fillTriangle(200, cy, 200 + math.cos(a0) * r, cy + math.sin(a0) * r, 200 + math.cos(a1) * r, cy + math.sin(a1) * r)
    end
    gfx.setColor(gfx.kColorBlack)
    for k = 0, 1 do
      local rr = (age - k * 0.12) * 520
      if rr > 0 and rr < 180 then A.ring(200, cy, rr, 3, 1 - rr / 180) end
    end
  end
  -- the band
  local bh = 46
  local collapse = age > 1.7 and ease((age - 1.7) / 0.3) or 0
  local bw = red and 400 or math.floor(400 * ease(age / 0.18))
  local hh = math.floor(bh * (1 - collapse))
  if hh <= 0 then return end
  local by = cy - hh // 2
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(200 - bw // 2, by, bw, hh)
  if hh > 10 then
    A.stripes(200 - bw // 2, by, bw, 4, age * 30)
    A.stripes(200 - bw // 2, by + hh - 4, bw, 4, -age * 30)
  end
  -- the words: slam from big with overshoot, shake while they land
  local s = 1
  if age < 0.15 and not red then s = 1 + (1 - A.back(age / 0.15)) * 1.4 end
  local sx, sy = 0, 0
  if age < 0.55 and not red then
    local a = math.floor((1 - age / 0.55) * 5)
    sx, sy = math.random(-a, a), math.random(-a, a)
  end
  gfx.setScreenClipRect(0, by, 400, hh)
  if s ~= 1 then img:drawScaled(200 - w * s / 2 + sx, cy - h * s / 2 + sy, s)
  else img:draw(200 - w // 2 + sx, cy - h // 2 + sy) end
  gfx.clearClipRect()
  if not red then A.glint(200 - w // 2, cy - h // 2, w, h, (age - 0.45) / 0.4) end
end

local function halfPill(text, age, A)
  local img = A.text("wa", text, "wa")
  local w, h = img:getSize()
  local pw, ph = w + 40, h + 10
  local q = A.reduce and 1 or ease(age / 0.25)
  if age > 2.7 then q = q * (1 - ease((age - 2.7) / 0.3)) end
  local y = math.floor(-ph + (92 + ph) * q)
  if y + ph < 0 then return end
  local x = 200 - pw // 2
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 4, y + 4, pw, ph)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, pw, ph)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRect(x, y, pw, ph)
  gfx.setLineWidth(1)
  local top = text:sub(1, 3) == "TOP"
  local ax, ay = x + 14, y + ph // 2
  if top then gfx.fillTriangle(ax - 6, ay + 4, ax, ay - 5, ax + 6, ay + 4)
  else gfx.fillTriangle(ax - 6, ay - 4, ax, ay + 5, ax + 6, ay - 4) end
  img:draw(x + 28, y + 5)
end

local function finalStamp(text, age, A)
  local f = A.text("waBig", text, "wa")
  local w, h = f:getSize()
  local x0 = 200 - w
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 84, 400, h * 2 + 12)
  local cx = x0
  for i = 1, #text do
    local ch = text:sub(i, i)
    local li = A.text("waBig", ch, "wa")
    local lw, lh = li:getSize()
    local a = age - (i - 1) * 0.09
    if a >= 0 then
      local s = 2
      if a < 0.12 and not A.reduce then s = 2 + (1 - a / 0.12) * 2 end
      li:drawScaled(cx + lw - lw * s / 2, 90 + lh - lh * s / 2, s)
    end
    cx = cx + lw * 2
  end
end

--- every banner's text as { fontKey, text }, most likely first (the TV layer prerenders them:
--- a few in the loader, the rest in idle time; anything not ready yet is made on first use)
function H.bannerTexts()
  local out = {}
  local function ord(n) return ({ "1ST", "2ND", "3RD" })[n] or (n .. "TH") end
  for inn = 1, 12 do out[#out + 1] = { "wa", "TOP " .. ord(inn) }; out[#out + 1] = { "wa", "BOT " .. ord(inn) } end
  for _, t in ipairs({ "HOME RUN!", "GRAND SLAM!", "WALK-OFF HOME RUN!", "WALK-OFF!", "LEAP CATCH! ROBBED!", "WHAT A CATCH" }) do
    table.insert(out, 3, { "waBig", t })   -- (right after the first innings' pills)
  end
  for _, t in ipairs({ "DOUBLE PLAY!", "BANG-BANG!", "TRIPLE!", "ERROR!", "STOLEN BASE", "CAUGHT STEALING" }) do out[#out + 1] = { "wa", t } end
  for _, ch in ipairs({ "F", "I", "N", "A", "L" }) do out[#out + 1] = { "waBig", ch } end
  out[#out + 1] = { "waBig", "FINAL" }
  return out
end

H.costMs = 0   -- (time spent in the DBN-styled HUD pieces this frame; the TV layer reads it)
local bigBanner
function H.bigBanner(text, age)
  local t0 = playdate.getElapsedTime()
  H.drawing = true
  bigBanner(text, age)
  H.drawing = false
  H.costMs = H.costMs + (playdate.getElapsedTime() - t0) * 1000
end
bigBanner = function(text, age)
  local A = TVA()
  if not A then return end
  if TIER1[text] then return tier1(text, age, A) end
  if text:sub(1, 4) == "TOP " or text:sub(1, 4) == "BOT " then return halfPill(text, age, A) end
  if text == "FINAL" then return finalStamp(text, age, A) end
  -- tier 2: whip in from the right on a skewed band, speed lines behind, whip out left
  local img = A.text("wa", text, "wa")
  local w, h = img:getSize()
  local bw = w + 60
  local q = A.reduce and 1 or ease(age / 0.22)
  local x = math.floor(200 - bw / 2 + (1 - q) * 440)
  if age > 1.6 and not A.reduce then x = x - math.floor(ease((age - 1.6) / 0.3) * 460) end
  local y, bh = 98, h + 12
  gfx.setColor(gfx.kColorBlack)
  gfx.fillPolygon(x + 12, y, x + bw + 12, y, x + bw - 12, y + bh, x - 12, y + bh)
  gfx.setColor(gfx.kColorWhite)
  gfx.setLineWidth(2)
  gfx.drawLine(x + 12, y + 2, x + bw + 10, y + 2)
  gfx.setLineWidth(1)
  if q < 1 then
    for k = 0, 3 do
      local ly = y + 6 + k * (bh - 12) / 3
      gfx.drawLine(x + bw + 16, ly, x + bw + 16 + (1 - q) * 160 * (1 - k * 0.15), ly)
    end
  end
  gfx.setColor(gfx.kColorBlack)
  img:draw(x + 30, y + 6)
end

--- the 48x60 face-bank photo at 0.75 (36x45), cached (48s are preloaded by the TV layer)
local faceSmallCache = {}
function H.faceSmall(face)
  local key = tostring(face)
  local img = faceSmallCache[key]
  if img then return img end
  local A = TVA()
  local src = A and A.face(face) or K.face(face, 48)
  img = src:scaledImage(0.75)
  faceSmallCache[key] = img
  return img
end

--- Lower third (bottom-left): face box pops open, a black name bar and a white info bar wipe
--- in from the left with a glint on their leading edge, then the fact strip rises under them.
--- Prerendered once per card; animated with clip rects only. out: 0..1 wipes it back off.
-- The card is split so nothing big is drawn when it shows: the per-batter part (face box, name
-- bar, empty info bar and fact strip) is prerendered in the loader (H.prewarmLowerThird); the
-- at-bat's info line and fact are two small text images made when the at-bat starts.
local ltStatic, ltText = {}, {}
local LT_FACE <const> = 40
local LT_W <const>, LT_H <const> = 236, 47

--- dev: report a cache build that took long enough to matter on the device
local function slow(what, t0)
  local ms = (playdate.getElapsedTime() - t0) * 1000
  if H.drawing then
    -- built on the frame it shows: the look-ahead missed it
    H.misses = (H.misses or 0) + 1
    print(string.format("[bchud] MISS: built %s while drawing (%.1f ms)", what, ms))
  elseif ms > 4 then print(string.format("[bchud] built %s in %.1f ms", what, ms)) end
end
H.slow = slow
BallCast.TVArt.onBuild = slow     -- (text images report through here: a build while drawing is a miss)

-- built in two pieces (so each look-ahead slice stays small): 1 = the card and the face,
-- 2 = the name. Asking for the image finishes whatever is left.
local function ltStage(face, title, upto)
  local key = tostring(face) .. "|" .. title
  local e = ltStatic[key]
  if not e then e = { stage = 0 }; ltStatic[key] = e end
  local w, h = LT_W, LT_H
  local nx = LT_FACE + 2
  if e.stage < 1 and upto >= 1 then
    local t0 = playdate.getElapsedTime()
    local img = gfx.image.new(w, h, gfx.kColorBlack)   -- (fully covered: no mask needed)
    gfx.pushContext(img)
    H.faceSmall(face):draw(2, 1)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawPolygon(w - 12, 3, w - 5, 9, w - 12, 15, w - 19, 9)
    gfx.fillRect(nx, 18, w - nx, 15)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(nx, 18, w - nx, 15)
    gfx.popContext()
    e.img, e.stage = img, 1
    slow("lower third card " .. title, t0)
  end
  if e.stage < 2 and upto >= 2 then
    local t0 = playdate.getElapsedTime()
    gfx.pushContext(e.img)
    -- the full name, else "F. LAST", else the narrower font, before anything is cut
    local nf, s = K.fitName(K.fonts.bold, K.fonts.nb, title, w - nx - 30, true)
    K.textW(nf, s, nx + 5, 2)
    gfx.popContext()
    e.stage = 2
    slow("lower third name " .. title, t0)
  end
  return e.img
end
local function ltStaticImg(face, title) return ltStage(face, title, 2) end
--- stage nil = the whole card; 1 / 2 = one piece (the TV layer's look-ahead slices)
function H.prewarmLowerThird(face, title, stage) ltStage(face, title, stage or 2) end

local function ltTextImg(s, white)
  local key = (white and "w|" or "b|") .. s
  local img = ltText[key]
  if img then return img end
  local t0 = playdate.getElapsedTime()
  local lf = K.fonts.tiny
  img = gfx.image.new(lf:getTextWidth(s) + 4, 10, gfx.kColorClear)
  gfx.pushContext(img)
  if white then K.textW(lf, s, 0, 1) else K.text(lf, s, 0, 1) end
  gfx.popContext()
  ltText[key] = img
  slow("lower third text '" .. s .. "'", t0)
  return img
end

local function infoLine(line1, line2)
  if line2 == "FIRST TRIP TO THE PLATE" then line2 = "FIRST AT-BAT" end
  return (line1 or "") .. ((line1 and line2) and "   " or "") .. (line2 or "")
end
--- prerender an at-bat's two text lines (the TV layer does this before the at-bat starts)
function H.prewarmLowerThirdText(line1, line2, fact)
  ltTextImg(infoLine(line1, line2), false)
  if fact then ltTextImg(fact, true) end
end

function H.lowerThird(face, title, line1, line2, age, out, fact)
  H.drawing = true
  local w, h = LT_W, LT_H
  local img = ltStaticImg(face, title)
  local info = ltTextImg(infoLine(line1, line2), false)
  local fi = fact and ltTextImg(fact, true)
  H.drawing = false
  local x, y = 4, 222 - h
  local A = TVA()
  local red = A and A.reduce
  local vis = 1 - (out or 0)
  if vis <= 0 then return end
  local visW = math.floor(w * vis)
  -- face: opens from the middle
  local fq = red and 1 or ease(age / 0.15)
  local fh = math.floor(h * fq)
  if fh > 0 then
    gfx.setScreenClipRect(x, y + (h - fh) // 2, math.min(LT_FACE, visW), fh)
    img:draw(x, y)
  end
  -- bars: wipe in from behind the face
  local function bar(by, bh, delay, txt)
    local q = red and 1 or ease((age - delay) / 0.22)
    local bw = math.floor((w - LT_FACE) * q)
    if bw <= 0 then return end
    gfx.setScreenClipRect(x + LT_FACE, y + by, math.max(0, math.min(bw, visW - LT_FACE)), bh)
    img:draw(x, y)
    if txt then
      gfx.setScreenClipRect(x + LT_FACE, y + by, math.max(0, math.min(bw, visW - LT_FACE) - 4), bh)
      txt:draw(x + LT_FACE + 7, y + by + 3)
    end
    if q < 1 then
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(x + LT_FACE + bw - 3, y + by, 3, bh)
      gfx.setColor(gfx.kColorBlack)
    end
  end
  bar(0, 18, 0.06)
  bar(18, 15, 0.16, info)
  if fi then
    local q = red and ((age > 0.55) and 1 or 0) or ease((age - 0.55) / 0.2)
    local fh2 = math.floor(14 * q)
    if fh2 > 0 then
      local sw = math.max(0, visW - LT_FACE)
      gfx.setScreenClipRect(x + LT_FACE, y + 33, sw, fh2)
      img:draw(x, y + 14 - fh2)
      -- crawl the words if they're longer than the strip
      gfx.setScreenClipRect(x + LT_FACE + 3, y + 33, math.max(0, sw - 6), fh2)
      local over = fi:getSize() - (w - LT_FACE - 10)
      local off = over > 0 and math.floor(math.min(over, math.max(0, age - 0.9) * 75)) or 0
      fi:draw(x + LT_FACE + 5 - off, y + 33 + 3 + 14 - fh2)
    end
  end
  gfx.clearClipRect()
end

--- Incident callout box (top center, jittery)
function H.callout(text, age)
  local f = K.fonts.nb
  local lines = K.wrap(f, text, 250)
  local h = #lines * 14 + 22
  local jx = (floor(age * 20) % 2 == 0) and 1 or -1
  local x, y = 200 - 135 + jx, 40
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 4, y + 4, 270, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, 270, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRect(x, y, 270, h)
  gfx.setLineWidth(1)
  gfx.fillRect(x, y, 270, 13)
  K.textW(K.fonts.tiny, (floor(age * 3) % 2 == 0) and "!! INCIDENT !!" or "   INCIDENT   ", x + 135, y + 3, "center")
  for i, l in ipairs(lines) do K.text(f, l, x + 135, y + 16 + (i - 1) * 14, "center") end
end

function H.release()
  bugImg, bugKey, weImg, weKey = nil, nil, nil, nil
  compImg, compKey = nil, {}
  tape = { img = nil, text = "", reveal = 0, from = 0, w = 0 }
  stripImg, stripTape = nil, nil
  bannerCache = {}
  faceSmallCache = {}
  ltStatic, ltText = {}, {}
  bugNames = {}
  gunKey, gunImg, gunShown = nil, nil, nil
  tagImgs = { [true] = {}, [false] = {} }
  bugLabels = nil
end
