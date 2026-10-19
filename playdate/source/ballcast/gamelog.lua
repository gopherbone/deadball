-- BallCast game log: a scrollable play-by-play of everything up to the current replay time
-- (inning headers, results, scoring plays with the score, incidents, Enhanced League powers).
-- Text comes from the wire lines when the server sent them, else Timeline.describe.
-- The whole list is rendered once into a tall image (re-rendered only when more plays
-- arrive); per frame we blit the visible window and invert the selected entry.
--
--   L.open(scene)  L.close()  L.isOpen()  L.draw()  L.move(d)  L.crank(change)  L.pick() → beat index

import "ballcast/kit"

local gfx <const> = playdate.graphics
local floor <const>, max <const>, min <const> = math.floor, math.max, math.min

BallCast = BallCast or {}
local L = {}
BallCast.GameLog = L
local K = BCKit

local X <const>, Y <const>, W <const>, H <const> = 14, 18, 372, 206
local LIST_Y <const> = Y + 20
local LIST_H <const> = H - 34
local PAD <const> = 6
local LINE <const> = 13

local st = { open = false, entries = {}, img = nil, upto = -1, sel = 1, scroll = 0, crankAcc = 0 }

local function ordinal(n) return BallCast.Timeline.ordinal(n) end

-- entries for beats 1..upto
local function collect(scene, upto)
  local tl = scene.tl
  local meta = scene.meta or {}
  local away = meta.away and meta.away.abbr or "AWY"
  local home = meta.home and meta.home.abbr or "HOM"
  local out = {}
  for i = 1, upto do
    local b = tl.beats[i]
    local k = b.kind
    if k == "half" then
      out[#out + 1] = { bi = i, head = true, text = (b.e.top and "TOP OF THE " or "BOTTOM OF THE ") .. ordinal(b.e.inn) }
    elseif k ~= "pa" then
      local text = scene:describe(i)
      if text then
        local score = b.runs and b.runs > 0
        if score then text = text .. "  (" .. away .. " " .. b.post.away .. ", " .. home .. " " .. b.post.home .. ")" end
        out[#out + 1] = { bi = i, text = text, score = score, inc = k == "inc", power = b.ultra ~= nil }
      end
    end
  end
  return out
end

-- render all entries into one tall image; records each entry's y/h
local function render(entries)
  local f, fb = K.fonts.nl, K.fonts.bold
  local tw = W - PAD * 2 - 14
  local lines = 0
  for _, e in ipairs(entries) do
    e.lines = K.wrap(e.head and fb or f, e.text, tw)
    lines = lines + #e.lines + (e.head and 1 or 0)
  end
  local h = max(LIST_H, lines * LINE + 6)
  local img = gfx.image.new(W - 4, h, gfx.kColorWhite)
  gfx.pushContext(img)
  local y = 2
  for _, e in ipairs(entries) do
    if e.head then y = y + 4 end
    e.y = y
    local font = e.head and fb or f
    for li, s in ipairs(e.lines) do
      if e.head then
        gfx.setColor(gfx.kColorBlack)
        gfx.fillRect(2, y - 1, W - 8, LINE + 1)
        K.textW(font, s, PAD, y)
      else
        font:drawText(s, PAD + 14, y)
      end
      y = y + LINE
    end
    -- margin marks: run scored, incident, power
    if not e.head then
      local mark = e.score and "*" or e.inc and "!" or e.power and "+" or nil
      if mark then fb:drawText(mark, PAD + 2, e.y) end
    end
    e.h = y - e.y
    if e.head then y = y + 2 end
  end
  gfx.popContext()
  return img
end

function L.isOpen() return st.open end

function L.open(scene)
  local upto = scene:curBeatIndex() or 0
  st.scene = scene
  if upto ~= st.upto or not st.img or st.tl ~= scene.tl then
    st.entries = collect(scene, upto)
    st.img = render(st.entries)
    st.upto = upto
    st.tl = scene.tl
  end
  st.open = true
  st.sel = max(1, #st.entries)
  st.crankAcc = 0
  L.follow(true)
end

function L.close() st.open = false end

-- keep the selection in view
function L.follow(snap)
  local e = st.entries[st.sel]
  if not e then st.scroll = 0 return end
  local _, ih = st.img:getSize()
  local maxScroll = max(0, ih - LIST_H)
  if e.y < st.scroll + 2 then st.scroll = e.y - 2 end
  if e.y + e.h > st.scroll + LIST_H - 2 then st.scroll = e.y + e.h - LIST_H + 2 end
  st.scroll = K.clamp(st.scroll, 0, maxScroll)
end

function L.move(d)
  if #st.entries == 0 then return end
  st.sel = K.clamp(st.sel + d, 1, #st.entries)
  L.follow()
end

function L.crank(change)
  st.crankAcc = st.crankAcc + change
  while st.crankAcc > 24 do st.crankAcc = st.crankAcc - 24; L.move(1) end
  while st.crankAcc < -24 do st.crankAcc = st.crankAcc + 24; L.move(-1) end
end

--- beat index of the selected entry
function L.pick()
  local e = st.entries[st.sel]
  return e and e.bi or nil
end

function L.draw()
  if not st.open then return end
  -- panel with a drop shadow
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(X + 4, Y + 4, W, H)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(X, Y, W, H)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRect(X, Y, W, H)
  gfx.setLineWidth(1)
  gfx.fillRect(X, Y, W, 17)
  K.textW(K.fonts.bold, "PLAY-BY-PLAY", X + 8, Y + 2)
  K.textW(K.fonts.tiny, #st.entries .. " PLAYS", X + W - 8, Y + 5, "right")
  -- list window
  gfx.setClipRect(X + 2, LIST_Y, W - 4, LIST_H)
  st.img:draw(X + 2, LIST_Y - floor(st.scroll))
  local e = st.entries[st.sel]
  if e then
    gfx.setColor(gfx.kColorXOR)
    gfx.fillRect(X + 2, LIST_Y + e.y - floor(st.scroll) - 1, W - 4, e.h + 1)
    gfx.setColor(gfx.kColorBlack)
  end
  gfx.clearClipRect()
  -- scrollbar
  local _, ih = st.img:getSize()
  if ih > LIST_H then
    local bh = max(10, LIST_H * LIST_H / ih)
    local by = LIST_Y + (LIST_H - bh) * st.scroll / (ih - LIST_H)
    gfx.fillRect(X + W - 5, by, 3, bh)
  end
  -- footer
  gfx.drawLine(X + 2, Y + H - 14, X + W - 3, Y + H - 14)
  K.text(K.fonts.tiny, "CRANK/UP/DN SCROLL   A WATCH THAT AT-BAT   B CLOSE", X + W / 2, Y + H - 11, "center")
end

function L.release() st = { open = false, entries = {}, img = nil, upto = -1, sel = 1, scroll = 0, crankAcc = 0 } end

return L
