-- DBN broadcast package: full-screen cards (matchup, lineups, linescore, due up, did you
-- know, the stretch, commercials, special report, final, player of the game, sign-off).
--
-- A card is built once, when its segment starts (on a frame where the 3D isn't drawn):
--   bg   opaque 400x240 (backdrop, header, empty panels)
--   fg   transparent 400x240 (everything that animates in)
--   rows { x, y, w, h, d = delay, dir = "l"|"r"|"u"|"d" } : fg slides into each rect in turn
--   anim(card, t) optional extra per-frame bits (a few polygons / small image draws)
-- Drawing a card = one opaque blit + a clipped blit per row + the extras.

import "ballcast/kit"
import "ballcast/tv/art"
import "ballcast/tv/fx"
import "ballcast/tv/stats"

local gfx <const> = playdate.graphics
local floor <const>, sin <const>, cos <const>, min <const>, max <const> = math.floor, math.sin, math.cos, math.min, math.max

BallCast = BallCast or {}
local C = {}
BallCast.TVCards = C
local A = BallCast.TVArt
local FX = BallCast.TVFX
local St = BallCast.TVStats
local K = BCKit

C.ANNOUNCER = "CHET HOLLOWAY"
C.COLOR_MAN = "BUD KRANSKI"

---------------------------------------------------------------------------
-- building blocks

local function newCard()
  return { bg = gfx.image.new(400, 240, gfx.kColorBlack), fg = gfx.image.new(400, 240, gfx.kColorClear), rows = {} }
end

local function row(card, x, y, w, h, d, dir)
  card.rows[#card.rows + 1] = { x = x, y = y, w = w, h = h, d = d or 0, dir = dir or "r" }
end

--- studio backdrop: black, fine diagonal pinstripes, a ghost of the network diamond
local function backdrop(style)
  gfx.clear(gfx.kColorBlack)
  if style == "plain" then
    gfx.setColor(gfx.kColorWhite)
    gfx.setDitherPattern(0.88, gfx.image.kDitherTypeDiagonalLine)
    gfx.fillRect(0, 0, 400, 240)
    gfx.setColor(gfx.kColorBlack)
    return
  end
  if style == "white" then
    gfx.clear(gfx.kColorWhite)
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0.88, gfx.image.kDitherTypeDiagonalLine)
    gfx.fillRect(0, 0, 400, 240)
  else
    gfx.setColor(gfx.kColorWhite)
    gfx.setDitherPattern(0.88, gfx.image.kDitherTypeDiagonalLine)   -- white at 12 %
    gfx.fillRect(0, 0, 400, 240)
    gfx.setColor(gfx.kColorWhite)
    gfx.setLineWidth(2)
    gfx.drawPolygon(A.diamondPoly(330, 150, 150, 120))
    gfx.drawPolygon(A.diamondPoly(330, 150, 120, 96))
    gfx.setLineWidth(1)
  end
  gfx.setColor(gfx.kColorBlack)
end

--- header band: white strip with a WordArt title and the DBN bug
local function header(title, sub)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 0, 400, 30)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 30, 400, 3)
  local t = A.text("wa", title, "wa")
  local tw = t:getSize()
  if tw > 300 then t = A.text("big", title, "b"); tw = t:getSize() end
  t:draw(200 - tw // 2, 5)
  -- the bug, right
  gfx.setColor(gfx.kColorBlack)
  gfx.fillPolygon(A.diamondPoly(380, 15, 15, 12))
  gfx.setColor(gfx.kColorWhite)
  gfx.drawPolygon(A.diamondPoly(380, 15, 10, 8))
  gfx.setColor(gfx.kColorBlack)
  K.text(K.fonts.tiny, "DBN", 4, 4)
  if sub then K.text(K.fonts.tiny, sub, 4, 18) end
end

--- white panel with a 2px border and a hard drop shadow
local function panel(x, y, w, h, black)
  gfx.setColor(gfx.kColorBlack)
  gfx.setDitherPattern(0.25, gfx.image.kDitherTypeBayer4x4)
  gfx.fillRect(x + 5, y + 5, w, h)
  gfx.setColor(black and gfx.kColorBlack or gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(black and gfx.kColorWhite or gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRect(x, y, w, h)
  gfx.setLineWidth(1)
  gfx.setColor(gfx.kColorBlack)
end

local function framed(img, x, y)
  local w, h = img:getSize()
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x - 3, y - 3, w + 6, h + 6)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x - 2, y - 2, w + 4, h + 4)
  img:draw(x, y)
end

local function txt(font, s, x, y, align, white)
  if white then K.textW(font, s, x, y, align) else K.text(font, s, x, y, align) end
end

local function wrap(font, s, w) return K.wrap(font, s, w) end

---------------------------------------------------------------------------
-- drawing a card

local function slideOff(r, q)
  local e = 1 - A.ease(q)
  if r.dir == "l" then return -floor(e * (r.w + 20)), 0
  elseif r.dir == "u" then return 0, -floor(e * (r.h + 20))
  elseif r.dir == "d" then return 0, floor(e * (r.h + 20)) end
  return floor(e * (r.w + 20)), 0
end

function C.draw(card, t, ox, oy)
  ox, oy = ox or 0, oy or 0
  card.bg:draw(ox, oy)
  local rows = card.rows
  for i = 1, #rows do
    local r = rows[i]
    local q = A.reduce and ((t >= r.d) and 1 or 0) or K.clamp((t - r.d) / 0.24, 0, 1)
    if q > 0 then
      local dx, dy = 0, 0
      if q < 1 then dx, dy = slideOff(r, q) end
      gfx.setScreenClipRect(r.x + ox, r.y + oy, r.w, r.h)
      card.fg:draw(dx + ox, dy + oy)
      -- the leading edge glint while it slides
      if q < 1 and not A.reduce then
        gfx.setColor(gfx.kColorWhite)
        if r.dir == "r" then gfx.fillRect(r.x + ox + r.w + dx - 3, r.y + oy, 3, r.h)
        elseif r.dir == "l" then gfx.fillRect(r.x + ox + dx, r.y + oy, 3, r.h) end
        gfx.setColor(gfx.kColorBlack)
      end
      gfx.clearClipRect()
    end
  end
  if card.anim then card.anim(card, t, ox, oy) end
end

---------------------------------------------------------------------------
-- linescore table (shared by the linescore and final cards). Returns its height.

local function lineTable(ls, meta, x, y, w, upto)
  local n = max(9, ls.inn)
  local f, fb = K.fonts.nb, K.fonts.bold
  local teamW, cell, rhe = 66, min(18, (w - 66 - 3 * 24) // n), 24
  local h = 18 * 3 + 4
  panel(x, y, teamW + cell * n + rhe * 3 + 6, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x, y, teamW + cell * n + rhe * 3 + 6, 18)
  local cx = x + teamW
  for i = 1, n do txt(K.fonts.tiny, tostring(i), cx + (i - 1) * cell + cell // 2, y + 6, "center", true) end
  local rx = cx + n * cell + 4
  for j, s in ipairs({ "R", "H", "E" }) do txt(K.fonts.tiny, s, rx + (j - 1) * rhe + rhe // 2, y + 6, "center", true) end
  for k, side in ipairs({ "away", "home" }) do
    local yy = y + 18 * k + 2
    local team = meta[side] or {}
    local logo = A.clubLogo(team, 16)
    if logo then logo:draw(x + 4, yy) end
    txt(fb, team.abbr or "?", x + 24, yy + 1)
    for i = 1, n do
      local v = ls[side][i]
      local s = v and tostring(v) or ((i <= ls.inn and (side == "away" or i < ls.inn)) and "0" or "")
      if i > ls.inn then s = "" end
      if s ~= "" then txt(f, s, cx + (i - 1) * cell + cell // 2, yy + 2, "center") end
    end
    txt(fb, tostring(ls.R[side]), rx + rhe // 2, yy + 1, "center")
    txt(f, tostring(ls.H[side]), rx + rhe + rhe // 2, yy + 2, "center")
    txt(f, tostring(ls.E[side]), rx + rhe * 2 + rhe // 2, yy + 2, "center")
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0.7, gfx.image.kDitherTypeBayer2x2)
    gfx.drawLine(x + 2, yy + 16, x + teamW + cell * n + rhe * 3 + 4, yy + 16)
    gfx.setColor(gfx.kColorBlack)
  end
  gfx.drawLine(rx - 2, y + 18, rx - 2, y + h - 2)
  return h
end
C.lineTable = lineTable

---------------------------------------------------------------------------
-- crawl strip (out-of-town scores): one long image, scrolled per frame

function C.crawlImage(text)
  local f = K.fonts.bold
  local s = "     " .. text .. "     "
  local w = min(3000, f:getTextWidth(s) + 20)
  local img = gfx.image.new(w, 16, gfx.kColorBlack)
  gfx.pushContext(img)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  f:drawText(s, 0, 1)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.popContext()
  return img
end

function C.drawCrawl(img, y, t, label)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, y, 400, 18)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, y, 400, 1)
  local lw = 0
  if label then
    local li = A.text("nb", label, "b")
    lw = li:getSize() + 10
    gfx.fillRect(0, y + 1, lw, 17)
    li:draw(5, y + 3)
  end
  local w = img:getSize()
  local off = floor(t * 70) % w
  gfx.setScreenClipRect(lw, y + 1, 400 - lw, 17)
  img:draw(lw - off, y + 2)
  if w - off < 400 then img:draw(lw - off + w, y + 2) end
  gfx.clearClipRect()
  gfx.setColor(gfx.kColorBlack)
end

---------------------------------------------------------------------------
-- MATCHUP

function C.matchup(G)
  local card = newCard()
  local m = G.meta
  gfx.pushContext(card.bg)
  backdrop()
  header("TONIGHT ON DBN", G.live and "LIVE" or "REPLAY")
  gfx.popContext()
  gfx.pushContext(card.fg)
  for k, side in ipairs({ "away", "home" }) do
    local team = m[side] or {}
    local cx = k == 1 and 100 or 300
    panel(cx - 88, 44, 176, 132)
    local logo = A.clubLogo2x(team)
    if logo then logo:draw(cx - 32, 52) end
    txt(K.fonts.bold, string.upper(team.city or ""), cx, 120, "center")
    local nm = string.upper(team.name or team.abbr or "?")
    local f = K.fonts.big
    if f:getTextWidth(nm) > 168 then f = K.fonts.nb end
    txt(f, nm, cx, 136, "center")
    if team.record then txt(K.fonts.tiny, "(" .. team.record .. ")", cx, 164, "center") end
    -- starting pitcher
    local sp = G.lineups and G.lineups.sp[side]
    if sp then
      gfx.setColor(gfx.kColorBlack)
      gfx.fillRect(cx - 88, 186, 176, 40)
      local face = m.people[sp] and m.people[sp].face
      local fi = A.face(face):scaledImage(0.6)
      framed(fi, cx - 82, 190)
      txt(K.fonts.tiny, "STARTING", cx - 46, 194, nil, true)
      txt(K.fonts.bold, K.fit(K.fonts.bold, St.last(m, sp), 120), cx - 46, 206, nil, true)
    end
  end
  gfx.popContext()
  row(card, 0, 40, 196, 200, 0.05, "l")
  row(card, 204, 40, 196, 200, 0.15, "r")
  local vs = A.text("waBig", "AT", "wa")
  card.anim = function(c, t, ox, oy)
    if t < 0.35 then return end
    local s = 1 + max(0, 0.5 - (t - 0.35)) * 2
    local w, h = vs:getSize()
    if A.reduce then s = 1 end
    vs:drawScaled(200 + ox - w * s / 2, 100 + oy - h * s / 2, s)
  end
  card.dur = 2.8
  return card
end

---------------------------------------------------------------------------
-- LINEUP (one side)

function C.lineup(G, side)
  local card = newCard()
  local m = G.meta
  local team = m[side] or {}
  gfx.pushContext(card.bg)
  backdrop()
  header("STARTING LINEUP", string.upper(team.abbr or ""))
  local logo = A.clubLogo2x(team)
  if logo then logo:draw(300, 44) end
  gfx.popContext()
  gfx.pushContext(card.fg)
  local ids = G.lineups and G.lineups[side] or {}
  for i, id in ipairs(ids) do
    local y = 36 + (i - 1) * 22
    local p = m.people[id] or {}
    gfx.setColor(i % 2 == 1 and gfx.kColorWhite or gfx.kColorBlack)
    gfx.fillRect(8, y, 252, 21)
    local white = i % 2 == 0
    txt(K.fonts.nb, tostring(i), 18, y + 4, "center", white)
    local fi = A.face(p.face):scaledImage(0.34)
    fi:draw(30, y + 1)
    txt(K.fonts.bold, K.fit(K.fonts.bold, string.upper(p.name or id), 170), 52, y + 3, nil, white)
    txt(K.fonts.nb, p.pos or "", 252, y + 4, "right", white)
    row(card, 8, y, 252, 21, 0.1 + i * 0.07, "l")
  end
  -- on the mound
  local sp = G.lineups and G.lineups.sp[side]
  if sp then
    local p = m.people[sp] or {}
    panel(272, 116, 120, 112, true)
    txt(K.fonts.tiny, "ON THE MOUND", 332, 121, "center", true)
    framed(A.face(p.face), 308, 134)
    txt(K.fonts.bold, K.fit(K.fonts.bold, St.last(m, sp), 112), 332, 204, "center", true)
    row(card, 268, 112, 130, 122, 0.9, "u")
  end
  gfx.popContext()
  card.dur = 2.6
  return card
end

---------------------------------------------------------------------------
-- LINESCORE (between innings) + due up + pitch counts + out-of-town crawl

function C.linescore(G, bi, title, dueSide, due)
  local card = newCard()
  local m, tl = G.meta, G.tl
  local ls = St.linescore(tl, bi)
  local c = St.counts(tl, bi)
  gfx.pushContext(card.bg)
  backdrop()
  header(title)
  gfx.popContext()
  gfx.pushContext(card.fg)
  local h = lineTable(ls, m, 12, 42, 376, bi)
  row(card, 8, 38, 390, h + 10, 0.05, "r")
  -- pitch counts: whoever is on the mound for each side right now
  local y = 42 + h + 14
  panel(12, y, 180, 74)
  txt(K.fonts.tiny, "PITCH COUNT", 102, y + 5, "center")
  local pits = G.curPit or {}
  local k = 0
  for _, side in ipairs({ "away", "home" }) do
    local id = pits[side]
    if id then
      local pc = c.pit[id]
      local yy = y + 18 + k * 26
      txt(K.fonts.bold, K.fit(K.fonts.bold, St.last(m, id), 110), 20, yy)
      txt(K.fonts.big, tostring(pc and pc.n or 0), 184, yy - 6, "right")
      txt(K.fonts.tiny, St.pitLine(c, id), 20, yy + 14)
      k = k + 1
    end
  end
  row(card, 8, y - 4, 192, 84, 0.25, "l")
  -- due up
  if due and #due > 0 then
    panel(204, y, 184, 74, true)
    local team = m[dueSide] or {}
    txt(K.fonts.tiny, "DUE UP: " .. (team.abbr or ""), 296, y + 5, "center", true)
    for i, id in ipairs(due) do
      local yy = y + 17 + (i - 1) * 18
      txt(K.fonts.bold, K.fit(K.fonts.bold, St.last(m, id), 96), 212, yy, nil, true)
      txt(K.fonts.tiny, K.fit(K.fonts.tiny, St.batLine(c, id), 76), 382, yy + 3, "right", true)
    end
    row(card, 200, y - 4, 196, 84, 0.4, "r")
  end
  gfx.popContext()
  card.crawl = G.crawl
  card.anim = function(cd, t, ox, oy)
    if cd.crawl then C.drawCrawl(cd.crawl, 222 + oy, t, "AROUND THE LEAGUE") end
  end
  card.dur = 3.2
  return card
end

---------------------------------------------------------------------------
-- DUE UP (middle of an inning): three big faces

function C.dueUp(G, bi, side, ids, title)
  local card = newCard()
  local m, tl = G.meta, G.tl
  local c = St.counts(tl, bi)
  local team = m[side] or {}
  gfx.pushContext(card.bg)
  backdrop()
  header(title or "DUE UP", string.upper(team.abbr or ""))
  gfx.popContext()
  gfx.pushContext(card.fg)
  for i, id in ipairs(ids) do
    local p = m.people[id] or {}
    local x = 14 + (i - 1) * 128
    panel(x, 40, 116, 186)
    framed(A.face2x(p.face), x + 10, 48)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x, 174, 116, 20)
    txt(K.fonts.bold, K.fit(K.fonts.bold, St.last(m, id), 108), x + 58, 177, "center", true)
    txt(K.fonts.tiny, (p.pos or "") .. "  -  " .. (team.abbr or ""), x + 58, 198, "center")
    txt(K.fonts.tiny, K.fit(K.fonts.tiny, St.batLine(c, id), 110), x + 58, 210, "center")
    row(card, x - 2, 36, 128, 200, 0.05 + (i - 1) * 0.16, "d")
  end
  gfx.popContext()
  card.dur = 2.6
  return card
end

---------------------------------------------------------------------------
-- DID YOU KNOW

function C.didYouKnow(G, fact)
  local card = newCard()
  local m = G.meta
  gfx.pushContext(card.bg)
  backdrop()
  gfx.popContext()
  gfx.pushContext(card.fg)
  local title = A.text("waBig", "DID YOU KNOW?", "wa")
  local tw = title:getSize()
  title:draw(200 - tw // 2, 10)
  row(card, 0, 4, 400, 40, 0.0, "d")
  local tx, w = 24, 352
  if fact.id then
    local p = m.people[fact.id] or {}
    framed(A.face2x(p.face), 22, 58)
    txt(K.fonts.tiny, string.upper(p.pos or "") .. " - " .. (p.teamAbbr or ""), 70, 184, "center", true)
    row(card, 14, 50, 116, 145, 0.2, "l")
    tx, w = 140, 240
  end
  local f = A.font("serifb")
  local lines = wrap(f, fact.text, w - 16)
  if #lines > 5 then f = K.fonts.bold; lines = wrap(f, fact.text, w - 16) end
  local lh = f:getHeight() + 2
  local ph = #lines * lh + 18
  panel(tx, 58, w, ph)
  for i, l in ipairs(lines) do txt(f, l, tx + 8, 66 + (i - 1) * lh) end
  row(card, tx - 4, 54, w + 10, ph + 10, 0.35, "r")
  txt(K.fonts.tiny, "DBN FACT DESK. ALL FACTS ARE FACTS.", 390, 226, "right", true)
  row(card, 200, 222, 200, 14, 0.8, "r")
  gfx.popContext()
  card.anim = function(cd, t, ox, oy)
    if A.reduce then return end
    -- a slow starburst behind the title
    gfx.setScreenClipRect(0, 0, 400, 46)
    A.burst(200 + ox, 22 + oy, 260, t * 0.6, 16, true)
    gfx.clearClipRect()
    title:draw(200 - tw // 2 + ox, 10 + oy)
  end
  card.dur = 3.6
  return card
end

---------------------------------------------------------------------------
-- SEVENTH-INNING STRETCH (a bouncing ball over the lyric)

function C.stretch(G)
  local card = newCard()
  gfx.pushContext(card.bg)
  backdrop("white")
  header("SEVENTH INNING STRETCH")
  panel(20, 50, 360, 150)
  gfx.popContext()
  gfx.pushContext(card.fg)
  txt(K.fonts.bold, "PLEASE RISE. OR DON'T.", 200, 60, "center")
  local f = K.fonts.big
  local words = { "TAKE", "ME", "OUT", "TO", "THE", "BALL", "GAME" }
  local line1 = table.concat(words, " ", 1, 3)
  local line2 = table.concat(words, " ", 4, 7)
  local pos = {}
  local function lay(s, y, from)
    local x = 200 - f:getTextWidth(s) // 2
    local i = from
    for wd in s:gmatch("%S+") do
      local ww = f:getTextWidth(wd)
      pos[i] = { x + ww // 2, y }
      txt(f, wd, x, y)
      x = x + ww + f:getTextWidth(" ")
      i = i + 1
    end
  end
  lay(line1, 112, 1)
  lay(line2, 152, 4)
  txt(K.fonts.tiny, "LYRICS: J. NORWORTH, 1908. ORGAN: THE ORGANIST.", 200, 186, "center")
  gfx.popContext()
  row(card, 20, 50, 360, 150, 0.1, "r")
  card.anim = function(cd, t, ox, oy)
    local u = (t - 0.4) / 0.42
    if u < 0 then return end
    local i = min(#pos, floor(u) + 1)
    local fr = u - floor(u)
    if u >= #pos then fr = 0 end
    local a, b = pos[i], pos[min(#pos, i + 1)]
    local x = a[1] + (b[1] - a[1]) * fr
    local y = a[2] - 10 - sin(fr * math.pi) * (a[2] == b[2] and 16 or 30)
    if b[2] ~= a[2] then y = a[2] - 10 + (b[2] - a[2]) * fr - sin(fr * math.pi) * 26 end
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(x + ox, y + oy, 6)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawCircleAtPoint(x + ox, y + oy, 6)
    gfx.drawArc(x + ox - 7, y + oy, 6, 300, 60)
    gfx.drawArc(x + ox + 7, y + oy, 6, 120, 240)
  end
  card.dur = 3.6
  return card
end

---------------------------------------------------------------------------
-- COMMERCIALS (deadpan, in-world brands). bumper → ad.

function C.bumper(G)
  local card = newCard()
  gfx.pushContext(card.bg)
  backdrop("plain")
  gfx.popContext()
  gfx.pushContext(card.fg)
  local lg = A.logo()
  lg:draw(200 - 75, 50)
  txt(K.fonts.big, "BASEBALL", 200, 122, "center", true)
  txt(K.fonts.bold, "WILL RETURN AFTER THESE MESSAGES.", 200, 156, "center", true)
  txt(K.fonts.tiny, "PLEASE DO NOT GO ANYWHERE. WE CAN SEE YOU.", 200, 176, "center", true)
  gfx.popContext()
  row(card, 0, 40, 400, 80, 0, "u")
  row(card, 0, 118, 400, 70, 0.2, "d")
  card.dur = 1.3
  return card
end

local ADS = {}

-- SportsWire Online: the league's news site, advertised like it's 1996
ADS.wire = function(card)
  gfx.pushContext(card.bg)
  backdrop("white")
  -- a beige-box monitor
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRoundRect(54, 14, 292, 168, 10)
  gfx.fillRect(170, 182, 60, 10)
  gfx.fillRect(140, 190, 120, 6)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRoundRect(68, 26, 264, 138, 4)
  gfx.setColor(gfx.kColorBlack)
  gfx.popContext()
  gfx.pushContext(card.fg)
  local mh = K.image("images/ui/masthead-sportswire")
  if mh then local w = mh:getSize(); mh:draw(200 - w // 2, 32) else txt(A.font("wa"), "SPORTSWIRE", 200, 32, "center") end
  txt(K.fonts.big, "THE NEWS.", 200, 72, "center")
  txt(K.fonts.bold, "ON A COMPUTER.", 200, 102, "center")
  txt(K.fonts.nb, "YOU WILL NEED A COMPUTER.", 200, 122, "center")
  txt(K.fonts.tiny, "SCORES UPDATED HOURLY. SOME OF THEM.", 200, 206, "center")
  txt(K.fonts.tiny, "ASK YOUR NEPHEW HOW.", 200, 220, "center")
  gfx.popContext()
  row(card, 68, 28, 264, 36, 0.05, "u")
  row(card, 68, 66, 264, 70, 0.4, "r")
  row(card, 0, 200, 400, 30, 1.1, "d")
  card.anim = function(cd, t, ox, oy)
    -- dialling in: a progress bar that fills, then a blinking cursor
    local q = K.clamp((t - 0.6) / 1.6, 0, 1)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(110 + ox, 144 + oy, 180, 10)
    gfx.fillRect(112 + ox, 146 + oy, math.floor(176 * q), 6)
    if q >= 1 and math.floor(t * 3) % 2 == 0 then gfx.fillRect(296 + ox, 144 + oy, 6, 10) end
  end
end

ADS.sands = function(card)
  gfx.pushContext(card.bg)
  gfx.clear(gfx.kColorBlack)
  gfx.setColor(gfx.kColorWhite)
  gfx.setDitherPattern(0.9, gfx.image.kDitherTypeBayer8x8)
  gfx.fillRect(0, 0, 400, 240)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(30, 30, 340, 120)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(38, 38, 324, 104)
  gfx.popContext()
  gfx.pushContext(card.fg)
  txt(K.fonts.tiny, "THE", 200, 46, "center", true)
  local t1 = A.text("waBig", "DESERT SANDS", "wa")
  local w1 = t1:getSize()
  t1:draw(200 - w1 // 2, 58)
  txt(K.fonts.big, "CASINO", 200, 96, "center", true)
  txt(K.fonts.bold, "THE SIGN IS BIGGER NOW.", 200, 162, "center", true)
  txt(K.fonts.nb, "ROUTE 9, MIRAGE FLATS. LOOSE SLOTS. TIGHT LIPS.", 200, 184, "center", true)
  local ph = A.photo("gambling-01")
  if ph then ph:drawScaled(8, 166, 0.6) end
  txt(K.fonts.tiny, "THE SANDS DOES NOT TAKE BETS ON BASEBALL. ASK FOR BOBBY.", 200, 222, "center", true)
  gfx.popContext()
  row(card, 38, 38, 324, 104, 0.1, "u")
  row(card, 0, 156, 400, 46, 0.6, "r")
  row(card, 0, 216, 400, 20, 1.1, "d")
  card.anim = function(cd, t, ox, oy)
    -- marquee bulbs chase around the sign
    local ph2 = floor(t * 12) % 3
    gfx.setColor(gfx.kColorBlack)
    local i = 0
    for x = 34, 366, 10 do
      if i % 3 == ph2 then gfx.fillCircleAtPoint(x + ox, 34 + oy, 2); gfx.fillCircleAtPoint(x + ox, 146 + oy, 2) end
      i = i + 1
    end
    for y = 44, 136, 10 do
      if i % 3 == ph2 then gfx.fillCircleAtPoint(34 + ox, y + oy, 2); gfx.fillCircleAtPoint(366 + ox, y + oy, 2) end
      i = i + 1
    end
  end
end

ADS.bobby = function(card)
  gfx.pushContext(card.bg)
  backdrop("white")
  gfx.popContext()
  gfx.pushContext(card.fg)
  local mh = K.image("images/ui/masthead-bobby")
  if mh then local w = mh:getSize(); mh:draw(200 - w // 2, 20) else txt(A.font("wa"), "BETS BY BOBBY", 200, 20, "center") end
  panel(40, 70, 320, 120)
  txt(K.fonts.big, "TAKE THE OVER.", 200, 84, "center")
  txt(K.fonts.bold, "INTEREST COMPOUNDS DAILY.", 200, 120, "center")
  txt(K.fonts.bold, "BOBBY IS NOT A BANK.", 200, 140, "center")
  txt(K.fonts.bold, "BOBBY IS ALWAYS OPEN.", 200, 160, "center")
  txt(K.fonts.tiny, "BOBBY IS NOT AFFILIATED WITH THIS GAME.", 200, 214, "center")
  gfx.popContext()
  row(card, 0, 14, 400, 50, 0.05, "u")
  row(card, 36, 66, 330, 130, 0.35, "r")
  row(card, 0, 208, 400, 20, 1.0, "d")
  card.anim = function(cd, t, ox, oy)
    -- dice tumble
    local a = t * 9
    for k = 0, 1 do
      local x, y = 52 + k * 296 + ox, 158 + oy
      local s = 11
      local c, sn = cos(a + k), sin(a + k)
      gfx.setColor(gfx.kColorBlack)
      gfx.fillPolygon(x + (-s * c + s * sn), y + (-s * sn - s * c), x + (s * c + s * sn), y + (s * sn - s * c),
        x + (s * c - s * sn), y + (s * sn + s * c), x + (-s * c - s * sn), y + (-s * sn + s * c))
      gfx.setColor(gfx.kColorWhite)
      gfx.fillCircleAtPoint(x, y, 2)
    end
    gfx.setColor(gfx.kColorBlack)
  end
end

ADS.hal = function(card)
  gfx.pushContext(card.bg)
  gfx.clear(gfx.kColorWhite)
  A.stripes(0, 0, 400, 240, 0)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 150, 400, 90)
  gfx.popContext()
  gfx.pushContext(card.fg)
  panel(20, 18, 360, 70, true)
  txt(A.font("waBig"), "HOT DOG HAL'S", 200, 30, "center")
  txt(K.fonts.tiny, "A STADIUM CONCESSION", 200, 70, "center", true)
  local ph = A.photo("hotdog-01")
  if ph then framed(ph, 24, 104) end
  local x = ph and 132 or 40
  panel(x - 8, 102, 400 - x - 4, 82)
  txt(K.fonts.big, "NOW WITH LESS EEL.", x, 112)
  txt(K.fonts.bold, "HAL HAS BEEN CLEARED OF", x, 150)
  txt(K.fonts.bold, "MOST OF THE CHARGES.", x, 168)
  txt(K.fonts.tiny, "SECTION 112, BEHIND THE TARP. CASH ONLY.", 200, 222, "center")
  gfx.popContext()
  row(card, 14, 12, 372, 82, 0.05, "u")
  row(card, 18, 98, 104, 84, 0.3, "l")
  row(card, 124, 104, 276, 34, 0.5, "r")
  row(card, 124, 144, 276, 44, 0.9, "r")
  row(card, 0, 216, 400, 20, 1.3, "d")
end

C.AD_ORDER = { "wire", "sands", "bobby", "hal" }

function C.ad(G, which)
  local card = newCard()
  ADS[which](card)
  card.dur = 3.0
  return card
end

---------------------------------------------------------------------------
-- SPECIAL REPORT (incident bulletin)

function C.special(G, b, text, note)
  local card = newCard()
  local m = G.meta
  gfx.pushContext(card.bg)
  gfx.clear(gfx.kColorBlack)
  gfx.setColor(gfx.kColorWhite)
  gfx.setDitherPattern(0.8, gfx.image.kDitherTypeHorizontalLine)
  gfx.fillRect(0, 0, 400, 240)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 12, 400, 50)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 16, 400, 42)
  gfx.popContext()
  gfx.pushContext(card.fg)
  local t = A.text("waBig", "SPECIAL REPORT", "wa")
  local tw = t:getSize()
  t:draw(200 - tw // 2, 23)
  local inn = b.pre and ((b.pre.top and "TOP " or "BOTTOM ") .. St.ordinal(b.pre.inn or 1)) or ""
  txt(K.fonts.tiny, "DBN NEWS DESK  -  " .. string.upper((m.park and m.park.name) or "") .. "  -  " .. inn, 200, 66, "center", true)
  local ph = A.photo(St.INCIDENT_PHOTO[b.e.kind])
  local x0 = 24
  if ph then
    local big = ph:scaledImage(1.5)
    framed(big, 22, 88)
    x0 = 180
  end
  local f = A.font("serifb")
  local lines = wrap(f, text, 400 - x0 - 20)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x0 - 8, 80, 400 - x0 + 4, 130)
  gfx.setColor(gfx.kColorWhite)
  gfx.drawLine(x0 - 8, 80, x0 - 8, 210)
  gfx.setColor(gfx.kColorBlack)
  for i, l in ipairs(lines) do txt(f, l, x0, 86 + (i - 1) * 22, nil, true) end
  local y = 86 + #lines * 22 + 8
  local nl = wrap(K.fonts.bold, note or "", 400 - x0 - 20)
  for i, l in ipairs(nl) do txt(K.fonts.bold, l, x0, y + (i - 1) * 16, nil, true) end
  gfx.popContext()
  row(card, 0, 16, 400, 42, 0, "r")
  row(card, 0, 62, 400, 14, 0.25, "l")
  row(card, 14, 80, 160, 124, 0.4, "u")
  row(card, x0 - 4, 80, 400 - x0, 130, 0.55, "r")
  card.crawl = C.crawlImage("BULLETIN ... " .. string.upper(text) .. " ... " .. (note or "") .. " ... MORE AS IT HAPPENS ... ")
  card.anim = function(cd, tt, ox, oy)
    -- blinking "on air" dot and the bulletin crawl
    if floor(tt * 3) % 2 == 0 then
      gfx.setColor(gfx.kColorWhite)
      gfx.fillCircleAtPoint(20 + ox, 37 + oy, 6)
      gfx.setColor(gfx.kColorBlack)
    end
    C.drawCrawl(cd.crawl, 222 + oy, tt, "BULLETIN")
  end
  card.dur = 3.6
  return card
end

---------------------------------------------------------------------------
-- POWER DOSSIER (Enhanced League): a top strip, drawn over the live picture

function C.power(G, who, power)
  local m = G.meta
  local p = m.people[who] or {}
  local img = gfx.image.new(400, 74, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 70)
  -- hazard stripes top and bottom
  A.stripes(0, 0, 400, 6, 0)
  A.stripes(0, 64, 400, 6, 4)
  local fi = A.face(p.face)
  gfx.setScreenClipRect(0, 6, 400, 58)
  framed(fi, 8, 4)
  gfx.clearClipRect()
  FX.scan(8, 6, 48, 58)
  txt(K.fonts.tiny, "ENHANCED LEAGUE", 66, 9, nil, true)
  local pn = BallCast.Timeline.POWER_NAMES[power] or power
  local t = A.text("wa", pn .. "!", "wa")
  t:draw(66, 19)
  txt(K.fonts.bold, string.upper(p.name or who or "?"), 66, 44, nil, true)
  local note = St.POWER_NOTE[power] or ""
  gfx.setColor(gfx.kColorWhite)
  gfx.drawLine(246, 10, 246, 60)
  gfx.setColor(gfx.kColorBlack)
  txt(K.fonts.tiny, "STATUS", 254, 10, nil, true)
  txt(K.fonts.tiny, K.fit(K.fonts.tiny, St.origin(who), 140), 254, 20, nil, true)
  local nl = wrap(K.fonts.tiny, note, 140)
  for i, l in ipairs(nl) do if i <= 3 then txt(K.fonts.tiny, l, 254, 34 + (i - 1) * 9, nil, true) end end
  gfx.popContext()
  return img
end

---------------------------------------------------------------------------
-- FINAL

function C.final(G)
  local card = newCard()
  local m, tl = G.meta, G.tl
  local ls = St.linescore(tl, #tl.beats)
  gfx.pushContext(card.bg)
  backdrop()
  gfx.popContext()
  gfx.pushContext(card.fg)
  local title = A.text("waBig", "FINAL", "wa")
  local tw = title:getSize()
  title:draw(200 - tw // 2, 8)
  row(card, 0, 4, 400, 34, 0, "d")
  local winH = ls.R.home > ls.R.away
  for k, side in ipairs({ "away", "home" }) do
    local team = m[side] or {}
    local x = k == 1 and 20 or 210
    panel(x, 44, 170, 86, (side == "home") == winH)
    local white = (side == "home") == winH
    local logo = A.clubLogo(team, 32)
    if logo then logo:draw(x + 8, 52) end
    txt(K.fonts.bold, team.abbr or "?", x + 48, 52, nil, white)
    txt(K.fonts.tiny, K.fit(K.fonts.tiny, string.upper(team.name or ""), 70), x + 48, 70, nil, white)
    local sc = A.text("waBig", tostring(ls.R[side]), "wa")
    local sw = sc:getSize()
    sc:drawScaled(x + 160 - sw * 2, 54, 2)
    if white then txt(K.fonts.tiny, "WINNER", x + 8, 112, nil, true) end
    row(card, x - 4, 40, 182, 96, 0.2 + (k - 1) * 0.15, k == 1 and "l" or "r")
  end
  local h = lineTable(ls, m, 12, 142, 376, #tl.beats)
  row(card, 8, 138, 390, h + 10, 0.55, "u")
  -- the bet
  local bet = m.bet
  local line
  if bet then
    local won = (bet.side == "home" and winH) or (bet.side == "away" and not winH)
    local team = m[bet.side] and m[bet.side].abbr or ""
    local pays = m.pays and m.pays[bet.side]
    if won then
      line = "YOUR " .. K.money(bet.amount) .. " ON " .. team .. ": CASHED" .. (pays and (" +" .. K.money(floor(bet.amount * pays - bet.amount + 0.5))) or "")
    else
      line = "YOUR " .. K.money(bet.amount) .. " ON " .. team .. ": GONE"
    end
  else
    line = "YOU HAD NO MONEY ON THIS ONE."
  end
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 214, 400, 22)
  txt(K.fonts.bold, line, 200, 218, "center", true)
  row(card, 0, 212, 400, 26, 1.0, "r")
  gfx.popContext()
  card.dur = 3.4
  return card
end

---------------------------------------------------------------------------
-- PLAYER OF THE GAME

function C.potg(G, id, kind, boxline)
  local card = newCard()
  local m = G.meta
  local p = m.people[id] or {}
  gfx.pushContext(card.bg)
  backdrop()
  header("PLAYER OF THE GAME")
  K.textW(K.fonts.tiny, "PRESENTED BY SPORTSWIRE ONLINE.", 394, 228, "right")
  gfx.popContext()
  gfx.pushContext(card.fg)
  local fi = A.face2x(p.face)
  -- double "gold" frame
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(30, 48, 116, 140)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(33, 51, 110, 134)
  gfx.drawRect(35, 53, 106, 130)
  fi:draw(40, 58)
  row(card, 24, 42, 128, 152, 0.15, "u")
  local nmF = K.fonts.big
  local nm = string.upper(p.name or id)
  if nmF:getTextWidth(nm) > 230 then nmF = K.fonts.nb end
  txt(nmF, nm, 164, 56, nil, true)
  txt(K.fonts.bold, (p.pos or "") .. "  -  " .. (p.teamAbbr or ""), 164, 86, nil, true)
  row(card, 160, 50, 240, 52, 0.4, "r")
  panel(164, 110, 220, 34)
  txt(K.fonts.bold, boxline or "", 274, 119, "center")
  row(card, 160, 106, 236, 44, 0.7, "r")
  local fl = wrap(K.fonts.nb, string.upper(K.lastName(p.name or "")) .. " " .. St.flavor(id), 220)
  for i, l in ipairs(fl) do txt(K.fonts.nb, l, 164, 156 + (i - 1) * 15, nil, true) end
  row(card, 160, 152, 236, 50, 1.0, "r")
  gfx.popContext()
  card.anim = function(cd, t, ox, oy)
    if A.reduce or t < 0.3 then return end
    -- sparkles around the frame
    gfx.setColor(gfx.kColorWhite)
    for i = 0, 5 do
      local a = t * 1.3 + i * 1.047
      local x, y = 88 + cos(a) * 78 + ox, 118 + sin(a) * 92 + oy
      local s = 2 + floor((t * 8 + i) % 3)
      gfx.drawLine(x - s, y, x + s, y); gfx.drawLine(x, y - s, x, y + s)
    end
    gfx.setColor(gfx.kColorBlack)
  end
  card.dur = 3.6
  return card
end

---------------------------------------------------------------------------
-- SIGN-OFF

function C.signoff(G)
  local card = newCard()
  local m = G.meta
  gfx.pushContext(card.bg)
  backdrop("plain")
  gfx.popContext()
  gfx.pushContext(card.fg)
  local lg = A.logo()
  lg:draw(200 - 75, 22)
  row(card, 0, 18, 400, 72, 0.1, "u")
  txt(K.fonts.bold, "THAT'S OUR BROADCAST FROM " .. string.upper((m.park and m.park.name) or "THE BALLPARK") .. ".", 200, 100, "center", true)
  txt(K.fonts.bold, "FOR " .. C.COLOR_MAN .. ", I'M " .. C.ANNOUNCER .. ".", 200, 120, "center", true)
  txt(K.fonts.big, "GOOD NIGHT.", 200, 144, "center", true)
  row(card, 0, 96, 400, 76, 0.4, "r")
  local tail = G.raccoons and "DRIVE CAREFULLY. THE RACCOONS ARE OUT." or "DRIVE CAREFULLY. TIP YOUR VENDOR."
  txt(K.fonts.nb, tail, 200, 188, "center", true)
  txt(K.fonts.tiny, "DBN. DEADBALL BROADCAST NETWORK. WE HAVE A CAMERA.", 200, 214, "center", true)
  row(card, 0, 182, 400, 50, 1.2, "d")
  gfx.popContext()
  card.anim = function(cd, t, ox, oy) A.glint(125 + ox, 22 + oy, 150, 64, (t % 2.4) / 0.8 - 0.4) end
  card.dur = 3.4
  return card
end

return C
