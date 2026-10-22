-- The game's end: who won, then what it did to the table (a match-end screen in the
-- Mahjong Soul mould: a big result beat, then the placements settling, in short beats).
--
--   beat 1 (0 - 1.2 s)  the headline ("LAMPLIGHTERS WIN"), the score line, your W/L stamp
--                       (Pennant), the line score (R/H/E by inning), tags (WALK-OFF, SHUTOUT,
--                       10 INNINGS, COMEBACK...), the decisions and the top performer
--   beat 2 (1.0 - 2.7 s) the standings, rows at their places before this game, then sliding to
--                       where it leaves them, W-L and GB ticking over, a ▲/▼ for a club that
--                       moved, the playoff line; Pennant adds the race (magic / elimination
--                       number) and the month's goal bar filling
--
-- Skippable: A jumps to the end state, then A (or B any time) continues: the owner asks
-- r:done() / r:skip(). Built once (one card: an opaque backdrop, a foreground revealed by
-- clipped row slides, see tv/cards.lua) plus a few small row images; the settled frame is kept
-- as one image, so after ~3 s a frame is a single blit and a blinking prompt.
--
-- spec (built by the owner: BallCast's league replays, Pennant's live games):
--   away / home  { abbr, name (nickname), city, runs }
--   meta         BallCast meta (club logos in the line score)
--   ls           St.linescore (the line score; tags come from the timeline via R.base)
--   mine         "home" | "away" | nil   (Pennant: the W/L stamp and your row)
--   tags         { "WALK-OFF", ... }
--   lines        { { "W", "T. MORROW" }, { "STAR", "PAIGE 3-4, HR" }, ... }
--   stand        { rows = { { abbr, hl, b = { r, w, l, gb }, a = { r, w, l, gb } } }, line = 4 }
--   note         one line under the decisions ("MAGIC # 12", "UP TO 2ND, 1 GB")
--   goal         { text, v0, v1, p0, p1 }   (the month's goal, before -> after)

import "ballcast/kit"
import "ballcast/tv/art"
import "ballcast/tv/cards"
import "ballcast/tv/stats"

local gfx <const> = playdate.graphics
local floor <const>, min <const>, max <const>, abs <const> = math.floor, math.min, math.max, math.abs

BallCast = BallCast or {}
local R = {}
R.__index = R
BallCast.Result = R
local A = BallCast.TVArt
local C = BallCast.TVCards
local St = BallCast.TVStats
local K = BCKit

-- the beats (s)
local T_STAMP <const> = 0.45     -- the W/L stamp lands (0.2 s slam)
local T_STAND <const> = 1.0      -- the standings slide in
local T_MOVE0 <const> = 1.45     -- rows start for their new places
local T_TICK <const> = 1.75      -- W-L / GB tick over (mid-move)
local T_MOVE1 <const> = 2.05     -- rows settled; arrows blink
local T_GOAL0 <const> = 2.05     -- the goal bar fills
local T_GOAL1 <const> = 2.5
R.END_HEAD = 1.3                 -- the settled frame, no standings
R.END_FULL = 2.7                 -- ... with them

local ROW_H <const> = 12
local SUB_Y <const>, SUB_H <const> = 37, 16
local LS_Y <const> = 59
local COL_Y <const> = 126
local SP_X <const>, SP_W <const> = 202, 192   -- the standings panel
local MAX_ROWS <const> = 8

local function F() return UI.fonts end

local function ord(n)
  local s = ({ "1ST", "2ND", "3RD" })[n]
  return s or (n .. "TH")
end
R.ord = ord

local function gbText(gb)
  if not gb or gb <= 0 then return "-" end
  return (gb % 1 == 0) and tostring(floor(gb)) or string.format("%.1f", gb)
end
R.gbText = gbText

---------------------------------------------------------------------------
-- spec helpers (pure data)

--- Tags from the timeline: walk-off, shutout, extra innings, comeback, rout, one-run game.
function R.tags(tl, ls)
  local out = {}
  local ra, rh = ls.R.away or 0, ls.R.home or 0
  if ra == rh then return out end
  local winH = rh > ra
  local walk, worst = false, 0
  for i = 1, #tl.beats do
    local b = tl.beats[i]
    if b.walkoff then walk = true end
    local p = b.post
    if p and b.kind ~= "end" then
      local d = winH and ((p.away or 0) - (p.home or 0)) or ((p.home or 0) - (p.away or 0))
      if d > worst then worst = d end
    end
  end
  local margin = abs(rh - ra)
  if walk then out[#out + 1] = "WALK-OFF" end
  if min(ra, rh) == 0 then out[#out + 1] = "SHUTOUT" end
  if (ls.inn or 9) > 9 then out[#out + 1] = ls.inn .. " INNINGS" end
  if worst >= 3 then out[#out + 1] = "CAME BACK FROM " .. worst .. " DOWN" end
  if margin >= 7 then out[#out + 1] = "ROUT"
  elseif margin == 1 and not walk then out[#out + 1] = "ONE-RUN GAME" end
  while #out > 3 do table.remove(out) end
  return out
end

--- The parts every result shares, from BallCast's timeline and meta.
function R.base(tl, meta)
  local ls = St.linescore(tl, #tl.beats)
  local function side(k)
    local t = meta[k] or {}
    return { abbr = t.abbr or "?", name = t.name or t.abbr or "?", city = t.city, runs = ls.R[k] or 0 }
  end
  local spec = { away = side("away"), home = side("home"), meta = meta, ls = ls, tags = R.tags(tl, ls), lines = {} }
  local id, _, line = St.playerOfGame(tl, meta)
  if id then spec.star = { St.last(meta, id), line } end
  return spec
end

local function cmpRow(a, b)
  local ga, gb = a.w + a.l, b.w + b.l
  local pa, pb = ga > 0 and a.w / ga or 0, gb > 0 and b.w / gb or 0
  if pa ~= pb then return pa > pb end
  if a.w ~= b.w then return a.w > b.w end
  local da, db = (a.rs or 0) - (a.ra or 0), (b.rs or 0) - (b.ra or 0)
  if da ~= db then return da > db end
  return a.abbr < b.abbr   -- (dead even: a fixed order, so clubs level on everything don't trade places)
end

--- Ranked { abbr, w, l, rs, ra } (sorted, games back filled in).
local function ranked(list)
  table.sort(list, cmpRow)
  local lead = list[1]
  for i, x in ipairs(list) do x.r = i x.gb = lead and ((lead.w - x.w) + (x.l - lead.l)) / 2 or 0 end
  return list
end
R.ranked = ranked

--- The standings rows from two ranked lists of { abbr, r, w, l, gb } (before and after this
--- game); hl: set of abbrs to highlight.
function R.rows(before, after, hl)
  local byB = {}
  for _, x in ipairs(before) do byB[x.abbr] = x end
  local rows = {}
  for _, x in ipairs(after) do
    local b = byB[x.abbr] or x
    rows[#rows + 1] = { abbr = x.abbr, hl = hl and hl[x.abbr] or false, b = { r = b.r, w = b.w, l = b.l, gb = b.gb }, a = { r = x.r, w = x.w, l = x.l, gb = x.gb } }
  end
  return rows
end

--- A league's table (the server's /standings rows: { teamId, w, l, rs, ra, team }) before and
--- after this game. isAfter: the rows already count it (a final), else they're from before it.
function R.leagueStand(srows, spec, isAfter)
  local home, away = spec.home, spec.away
  local hr, ar = home.runs, away.runs
  if hr == ar then return nil end
  local function list(sign)
    local out, seen = {}, 0
    for _, s in ipairs(srows or {}) do
      local abbr = (s.team and s.team.abbr) or s.teamId
      local x = { abbr = abbr, w = s.w or 0, l = s.l or 0, rs = s.rs or 0, ra = s.ra or 0 }
      local me = abbr == home.abbr and hr or (abbr == away.abbr and ar or nil)
      if me then
        local them = abbr == home.abbr and ar or hr
        seen = seen + 1
        if me > them then x.w = x.w + sign else x.l = x.l + sign end
        x.rs, x.ra = x.rs + sign * me, x.ra + sign * them
        if x.w < 0 or x.l < 0 then return nil end
      end
      out[#out + 1] = x
    end
    if seen < 2 then return nil end
    return ranked(out)
  end
  local cur = list(0)
  local other = list(isAfter and -1 or 1)
  if not cur or not other then return nil end
  local before, after = isAfter and other or cur, isAfter and cur or other
  local stand = { rows = R.rows(before, after, { [home.abbr] = true, [away.abbr] = true }) }
  -- the line under it: who moved
  local notes = {}
  for _, r in ipairs(stand.rows) do
    if r.hl and r.a.r ~= r.b.r then
      notes[#notes + 1] = string.upper(r.abbr) .. (r.a.r < r.b.r and " UP TO " or " DOWN TO ") .. ord(r.a.r)
    end
  end
  spec.note = notes[1] and table.concat(notes, ", ") or nil
  return stand
end

---------------------------------------------------------------------------
-- building

local function backdrop()
  gfx.clear(gfx.kColorBlack)
  gfx.setColor(gfx.kColorWhite)
  gfx.setDitherPattern(0.88, gfx.image.kDitherTypeDiagonalLine)   -- white at 12 %
  gfx.fillRect(0, 0, 400, 240)
  gfx.setColor(gfx.kColorBlack)
end

local function panel(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.setDitherPattern(0.25, gfx.image.kDitherTypeBayer4x4)
  gfx.fillRect(x + 4, y + 4, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRect(x, y, w, h)
  gfx.setLineWidth(1)
end

local function row(card, x, y, w, h, d, dir)
  card.rows[#card.rows + 1] = { x = x, y = y, w = w, h = h, d = d or 0, dir = dir or "r" }
end

--- the headline in the biggest WordArt that fits
local function headline(s, maxW)
  for _, k in ipairs({ "waBig", "wa" }) do
    local img = A.text(k, s, "wa")
    if img:getSize() <= maxW then return img end
  end
  return A.text("big", s, "b")
end

--- the W / L stamp: a tilted block, built once
local function stamp(won)
  local f = K.fonts.big
  local s = won and "W" or "L"
  local w, h = 36, 31
  local img = gfx.image.new(w, h, gfx.kColorClear)
  gfx.pushContext(img)
  if won then
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 0, w, h)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(3, 3, w - 6, h - 6)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  else
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(0, 0, w, h)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(3)
    gfx.drawRect(1, 1, w - 2, h - 2)
    gfx.setLineWidth(1)
    gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
  end
  f:drawText(s, (w - f:getTextWidth(s)) // 2, (h - f:getHeight()) // 2 + 1)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.popContext()
  return img:rotatedImage(won and -12 or 10)
end

--- one standings row (inner width), black on clear or (hl) white on black
local function rowImage(r, st, arrow, w)
  local img = gfx.image.new(w, ROW_H, r.hl and gfx.kColorBlack or gfx.kColorClear)
  gfx.pushContext(img)
  local col = r.hl and "white" or nil
  local fb = F().bold
  local y = Text.boxY(fb, 0, ROW_H)
  Text.draw(tostring(st.r), 14, y, fb, col, "right")
  if arrow then
    local d = r.b.r - r.a.r
    if d ~= 0 then Text.draw((d > 0 and "\u{25b2}" or "\u{25bc}") .. abs(d), 18, y, fb, col) end
  end
  Text.draw(r.abbr, 38, y, fb, col)
  Text.draw(tostring(st.w), w - 62, y, fb, col, "right")
  Text.draw(tostring(st.l), w - 38, y, fb, col, "right")
  Text.draw(gbText(st.gb), w - 4, y, fb, col, "right")
  gfx.popContext()
  return img
end

--- Prompt text for the corner of the score strip.
local function promptImg(s) return A.text("tiny", s, "w") end

function R.new(spec)
  local self = setmetatable({ spec = spec, t = 0, cues = {} }, R)
  self.END = spec.stand and R.END_FULL or R.END_HEAD
  return self
end

function R:build()
  local spec = self.spec
  local card = { bg = gfx.image.new(400, 240, gfx.kColorBlack), fg = gfx.image.new(400, 240, gfx.kColorClear), rows = {} }
  self.card = card
  local away, home = spec.away, spec.home
  local winH = home.runs > away.runs
  local W, Lo = winH and home or away, winH and away or home
  local tie = home.runs == away.runs
  gfx.pushContext(card.bg)
  backdrop()
  gfx.popContext()

  gfx.pushContext(card.fg)
  -- the headline band
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 0, 400, 33)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 33, 400, 3)
  local hx, hw = 200, 384
  if spec.mine then hx, hw = 178, 330 end
  local title = tie and "FINAL" or (string.upper(W.name or W.abbr) .. " WIN")
  local hi = headline(title, hw)
  local tw, th = hi:getSize()
  hi:draw(hx - tw // 2, max(0, (33 - th) // 2))
  row(card, 0, 0, 400, 36, 0, "d")
  -- the score strip: "LAMPLIGHTERS 5, RUSTLERS 3"
  gfx.fillRect(0, SUB_Y, 400, SUB_H)
  local sub = string.upper(W.name or W.abbr) .. " " .. W.runs .. ", " .. string.upper(Lo.name or Lo.abbr) .. " " .. Lo.runs
  sub = Text.ellipsize(sub, F().bold, 300)
  Text.draw(sub, 200, Text.boxY(F().bold, SUB_Y, SUB_H, sub), F().bold, "white", "center")
  row(card, 0, SUB_Y, 400, SUB_H, 0.15, "r")
  -- the line score, with a WIN tab on the winner's row
  local ls = spec.ls
  local n = max(9, ls.inn or 9)
  local cell = min(18, (384 - 66 - 72) // n)
  local lw = 66 + cell * n + 78
  local lx = (400 - lw - 40) // 2
  local h = C.lineTable(ls, spec.meta, lx, LS_Y, 384)
  if not tie then
    local yy = LS_Y + 18 * (winH and 2 or 1) + 1
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(lx + lw + 4, yy, 34, 16)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(lx + lw + 4, yy, 34, 16)
    Text.draw("WIN", lx + lw + 21, Text.boxY(F().bold, yy, 16), F().bold, "white", "center")
  end
  row(card, lx - 4, LS_Y - 3, lw + 50, h + 10, 0.3, "u")

  -- the left column: tags, the decisions, the race / goal
  local stand = spec.stand
  local cx, cw = 6, stand and (SP_X - 12) or 388
  local y = COL_Y
  if #spec.tags > 0 then
    local x = cx
    local fb = F().bold
    for _, s in ipairs(spec.tags) do
      local w = fb:getTextWidth(s) + 10
      if x + w > cx + cw then break end
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(x, y, w, 14)
      gfx.setColor(gfx.kColorBlack)
      gfx.fillRect(x + 1, y + 1, w - 2, 12)
      Text.draw(s, x + 5, Text.boxY(fb, y + 1, 12, s), fb, "white")
      x = x + w + 4
    end
    row(card, cx - 2, y - 2, cw + 4, 18, 0.55, "l")
    y = y + 18
  end
  local lines = {}
  for _, l in ipairs(spec.lines or {}) do lines[#lines + 1] = l end
  if spec.star then lines[#lines + 1] = { "STAR", spec.star[1] .. (spec.star[2] and (" " .. spec.star[2]) or "") } end
  if #lines > 0 then
    local ph = #lines * ROW_H + 6
    panel(cx, y, cw, ph)
    local fb, fl = F().bold, F().body
    for i, l in ipairs(lines) do
      local ry = y + 3 + (i - 1) * ROW_H
      Text.draw(l[1], cx + 5, Text.boxY(fb, ry, ROW_H), fb)
      local s = Text.ellipsize(l[2] or "", fl, cw - 52)
      Text.draw(s, cx + 44, Text.boxY(fl, ry, ROW_H, s), fl)
    end
    row(card, cx - 2, y - 2, cw + 8, ph + 8, 0.7, "l")
    y = y + ph + 6
  end
  if spec.note or spec.goal then
    local ph = (spec.note and 15 or 0) + (spec.goal and 24 or 0) + 2
    local gy = y
    panel(cx, gy, cw, ph)
    local yy = gy + 1
    if spec.note then
      gfx.fillRect(cx + 2, yy + 1, cw - 4, 13)
      local s = Text.ellipsize(spec.note, F().bold, cw - 10)
      Text.draw(s, cx + 6, Text.boxY(F().bold, yy + 1, 13, s), F().bold, "white")
      yy = yy + 15
    end
    if spec.goal then
      local g = spec.goal
      local s = Text.ellipsize(g.text or "", F().body, cw - 10)
      Text.draw(s, cx + 5, Text.boxY(F().body, yy, 12, s), F().body)
      local bx, by, bw = cx + 5, yy + 13, cw - 62
      gfx.drawRect(bx, by, bw, 7)
      self.bar = { x = bx + 1, y = by + 1, w = bw - 2, h = 5, vx = cx + cw - 5, vy = yy + 11 }
      self.v0 = A.text("tiny", g.v0 or "", "b")
      self.v1 = A.text("tiny", g.v1 or "", "b")
    end
    row(card, cx - 2, gy - 2, cw + 8, ph + 8, stand and 1.2 or 0.85, "l")
    self.goalD = stand and 1.2 or 0.85
  end

  gfx.popContext()

  -- the standings panel: its own image (a slide of the card's foreground would drag the left
  -- column in with it), the rows drawn over it per frame
  if stand then
    local nrows = min(MAX_ROWS, #stand.rows)
    local ph = 14 + nrows * ROW_H + 2
    local py = COL_Y
    self.spImg = gfx.image.new(SP_W + 8, ph + 8, gfx.kColorClear)
    gfx.pushContext(self.spImg)
    gfx.setDrawOffset(-(SP_X - 2), -(py - 2))
    panel(SP_X, py, SP_W, ph)
    gfx.fillRect(SP_X, py, SP_W, 13)
    local ft = K.fonts.tiny
    local ty = Text.boxY(ft, py, 13)
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    K.text(ft, stand.title or "STANDINGS", SP_X + 6, ty)
    local iw = SP_W - 4
    K.text(ft, "W", SP_X + 2 + iw - 62, ty, "right")
    K.text(ft, "L", SP_X + 2 + iw - 38, ty, "right")
    K.text(ft, "GB", SP_X + 2 + iw - 4, ty, "right")
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    gfx.setDrawOffset(0, 0)
    gfx.popContext()
    self.sp = { x = SP_X + 2, y = py + 14, w = iw, h = nrows * ROW_H, n = nrows, px = SP_X - 2, py = py - 2 }
    -- (a long table: the window of MAX_ROWS around the highlighted rows, by where they end up)
    local first = 1
    if #stand.rows > nrows then
      local lo = #stand.rows
      for _, r in ipairs(stand.rows) do if r.hl then lo = min(lo, r.a.r, r.b.r) end end
      first = max(1, min(#stand.rows - nrows + 1, lo - 1))
    end
    self.first = first
    for _, r in ipairs(stand.rows) do
      r.imgB = rowImage(r, r.b, false, iw)
      r.imgA = rowImage(r, r.a, true, iw)
    end
    -- highlighted rows drawn last (on top as they pass the others)
    local order = {}
    for _, r in ipairs(stand.rows) do if not r.hl then order[#order + 1] = r end end
    for _, r in ipairs(stand.rows) do if r.hl then order[#order + 1] = r end end
    self.order = order
    self.moved = false
    for _, r in ipairs(stand.rows) do if r.a.r ~= r.b.r then self.moved = true end end
  end

  if spec.mine and not tie then
    local won = (spec.mine == "home") == winH
    self.stampImg = stamp(won)
    self.won = won
  end
  self.promptSkip = promptImg("A: SKIP")
  self.promptGo = promptImg("A: CONTINUE")
end

---------------------------------------------------------------------------
-- per frame

local function slideDx(t, d, w)
  local q = K.clamp((t - d) / 0.24, 0, 1)
  if q >= 1 or A.reduce then return t >= d and 0 or nil end
  if q <= 0 then return nil end
  return floor((1 - A.ease(q)) * (w + 20))
end

function R:cue(name, at, t, kind)
  if t >= at and not self.cues[name] then
    self.cues[name] = true
    if not self.silent then pcall(K.sfx, kind) end
  end
end

--- Everything that isn't in the card: the stamp, the standings rows, the goal bar.
function R:anim(t)
  local st = self.stampImg
  if st and t >= T_STAMP then
    local w, h = st:getSize()
    local cx, cy = 370, 19
    local u = K.clamp((t - T_STAMP) / 0.2, 0, 1)
    if u < 1 and not A.reduce then
      local s = 1 + 2.2 * (1 - A.ease(u))
      st:drawScaled(floor(cx - w * s / 2), floor(cy - h * s / 2), s)
    else
      st:draw(cx - w // 2, cy - h // 2)
    end
  end
  local sp = self.sp
  if sp then
    local dx = slideDx(t, T_STAND, SP_W)
    if dx then
      local u = A.reduce and (t >= T_MOVE0 and 1 or 0) or A.ease((t - T_MOVE0) / (T_MOVE1 - T_MOVE0))
      local tick = t >= T_TICK
      self.spImg:draw(sp.px + dx, sp.py)
      gfx.setClipRect(sp.x + dx, sp.y, sp.w, sp.h)
      local first = self.first
      for i = 1, #self.order do
        local r = self.order[i]
        local yb = sp.y + (r.b.r - first) * ROW_H
        local ya = sp.y + (r.a.r - first) * ROW_H
        local y = floor(yb + (ya - yb) * u + 0.5)
        local x = sp.x + dx
        -- (a highlighted row on the move lifts a little off the table)
        if r.hl and u > 0 and u < 1 and ya ~= yb and not A.reduce then
          x = x - 3
          gfx.setColor(gfx.kColorBlack)
          gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
          gfx.fillRect(x + 3, y + 2, sp.w, ROW_H)
          gfx.setColor(gfx.kColorBlack)
        end
        ;(tick and r.imgA or r.imgB):draw(x, y)
        if r.hl and not A.reduce then
          -- the tick: a flash as the numbers turn over; the arrow blinks once the row lands
          if t >= T_TICK and t < T_TICK + 0.1 then
            gfx.setColor(gfx.kColorXOR) gfx.fillRect(x, y, sp.w, ROW_H) gfx.setColor(gfx.kColorBlack)
          elseif t >= T_MOVE1 and t < T_MOVE1 + 0.6 and r.a.r ~= r.b.r and floor((t - T_MOVE1) / 0.1) % 2 == 0 then
            gfx.setColor(gfx.kColorXOR) gfx.fillRect(x + 16, y, 20, ROW_H) gfx.setColor(gfx.kColorBlack)
          end
        end
      end
      -- the playoff line (dashed)
      local line = self.spec.stand.line
      if line and line >= first and line < first + sp.n - 1 then
        local ly = sp.y + (line - first + 1) * ROW_H - 1
        gfx.setColor(gfx.kColorBlack)
        gfx.setPattern({ 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC, 0xCC })
        gfx.fillRect(sp.x + dx, ly, sp.w, 1)
        gfx.setColor(gfx.kColorBlack)
      end
      gfx.clearClipRect()
    end
  end
  local bar = self.bar
  if bar and t >= (self.goalD or 0) + 0.24 then
    local g = self.spec.goal
    local t0, t1 = T_GOAL0, T_GOAL1
    if not self.sp then t0, t1 = 0.9, 1.2 end
    local u = A.reduce and 1 or A.ease((t - t0) / (t1 - t0))
    local p = K.clamp((g.p0 or 0) + ((g.p1 or 0) - (g.p0 or 0)) * u, 0, 1)
    local fw = floor(bar.w * p + 0.5)
    if fw > 0 then gfx.setColor(gfx.kColorBlack) gfx.fillRect(bar.x, bar.y, fw, bar.h) end
    local v = (u >= 0.6) and self.v1 or self.v0
    v:draw(bar.vx - v:getSize(), bar.vy)
  end
end

--- t: seconds into the screen (the owner's clock; R:advance keeps one)
function R:drawAt(t)
  if not self.card then self:build() end
  if t >= self.END and self.settled then
    self.settled:draw(0, 0)
  else
    C.draw(self.card, t)
    self:anim(t)
    if t >= self.END + 0.05 then self.settled = gfx.getWorkingImage() end
  end
  local p
  if t < self.END then p = self.promptSkip
  elseif floor((t - self.END) / 0.5) % 2 == 0 then p = self.promptGo end
  if p then
    local w, h = p:getSize()
    p:draw(396 - w, SUB_Y + (SUB_H - h) // 2)
  end
  -- sounds
  if self.stampImg then self:cue("stamp", T_STAMP + 0.15, t, self.won and "thud" or "flip") end
  if self.sp then
    self:cue("tick", T_TICK, t, "tick")
    if self.moved then self:cue("settle", T_MOVE1, t, "click") end
  end
end

--- Advance by dt (s) and draw. debugT (the tour's frame strip) pins the clock.
function R:draw(dt)
  if self.debugT then self.t = self.debugT
  else
    self.t = self.t + (dt or 1 / 30)
    if A.reduce and self.t < self.END then self.t = self.END end
  end
  self:drawAt(self.t)
end

function R:done() return self.t >= self.END end
--- A during the beats: straight to the settled frame (no sounds on the way).
function R:skip()
  self.skipped = true
  self.silent = true
  for _, k in ipairs({ "stamp", "tick", "settle" }) do self.cues[k] = true end
  self.t = max(self.t, self.END)
  self.silent = false
end

function R:release()
  self.card, self.settled, self.spImg = nil, nil, nil
  if self.spec and self.spec.stand then for _, r in ipairs(self.spec.stand.rows) do r.imgA, r.imgB = nil, nil end end
end
