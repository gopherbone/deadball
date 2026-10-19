-- BallCast nametags: small 1-bit labels (white box, black text, little pointer) over the key
-- puppets. Each label image is rendered once per name and cached; per frame we only project,
-- clamp to the screen and skip overlaps.
--
--   Tags.begin()                       start a frame
--   Tags.want(text, x, y, prio)        ask for a tag over the puppet standing at field (x, y)
--   Tags.draw(R)                       place + draw (highest prio first, max 4)

import "ballcast/kit"

local gfx <const> = playdate.graphics
local floor <const> = math.floor

BallCast = BallCast or {}
local T = {}
BallCast.Tags = T
local K = BCKit

local cache = {}       -- text → image
local reqs, nreq = {}, 0
local placed = {}
local MAX <const> = 4
local HEAD_FT <const> = 7.3   -- label sits just above the cap

local function label(text)
  local img = cache[text]
  if img then return img end
  local f = K.fonts.bold
  local w = f:getTextWidth(text) + 6
  local h = f:getHeight() + 3
  img = gfx.image.new(w, h + 3, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 0, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(0, 0, w, h)
  f:drawText(text, 3, 2)
  -- pointer
  local cx = floor(w / 2)
  gfx.fillTriangle(cx - 3, h - 1, cx + 3, h - 1, cx, h + 2)
  gfx.popContext()
  cache[text] = img
  return img
end

function T.begin() nreq = 0 end

function T.want(text, x, y, prio)
  if not text or text == "" then return end
  nreq = nreq + 1
  local r = reqs[nreq]
  if not r then r = {}; reqs[nreq] = r end
  r.text, r.x, r.y, r.prio = text, x, y, prio or 0
end

local function overlaps(x, y, w, h, n)
  for i = 1, n do
    local p = placed[i]
    if x < p[1] + p[3] and p[1] < x + w and y < p[2] + p[4] and p[2] < y + h then return true end
  end
  return false
end

function T.draw(R)
  if nreq == 0 then return end
  -- highest priority first (insertion sort; n is tiny)
  for i = 2, nreq do
    local v = reqs[i]
    local j = i - 1
    while j >= 1 and reqs[j].prio < v.prio do reqs[j + 1] = reqs[j]; j = j - 1 end
    reqs[j + 1] = v
  end
  local np = 0
  for i = 1, nreq do
    if np >= MAX then break end
    local r = reqs[i]
    local sx, sy, d = R:project(r.x, r.y, HEAD_FT)
    if sx and d then
      local ppf = R:ppf(d)
      -- no tags on specks in the distance or on figures culled right in front of the lens
      if ppf * 6.2 >= 9 and ppf * 6.2 <= 220 then
        local img = label(r.text)
        local w, h = img:getSize()
        local x = K.clamp(floor(sx - w / 2), 2, 398 - w)
        local y = floor(sy - h - 1)
        if y < 36 then y = 36 end
        if y + h > 222 then y = 222 - h end
        if overlaps(x, y, w, h, np) then
          y = y - h - 1
          if y < 36 or overlaps(x, y, w, h, np) then x = nil end
        end
        if x then
          img:draw(x, y)
          np = np + 1
          local p = placed[np]
          if not p then p = {}; placed[np] = p end
          p[1], p[2], p[3], p[4] = x, y, w, h
        end
      end
    end
  end
end

function T.release() cache = {} end

return T
