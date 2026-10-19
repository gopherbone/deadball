-- The status bar on every shell screen: the day, the heartbeat chip ("BETS LOCK 4:12 SEA@HCL"
-- for the next game to lock, "ON AIR B7" while one of yours is on, "ON AIR" for the league's,
-- "NEXT SLATE 0:40"), heat pips, unread mail and the bankroll with its change
-- this session. It's drawn every frame, so it is painted into an image only when one of
-- its values changes (about once a second, or each frame while the money rolls).
--
--   Status.draw(y, style)          the full 400x16 bar; style "light" (browser) | "dark" (BBS)
--   Status.drawCluster(rx, y)      the right half only (chip, heat, mail, money), white on
--                                  black, right-aligned at rx: the card programs' header
--   Status.phaseText()             the chip's text, for other screens that want it

local gfx <const> = playdate.graphics

Status = Status or {}
Status.H = 16
Status.dirty = false

local HOLD_BLINK <const> = 60000    -- the PRE countdown blinks in its last minute
local PAYOUT_MS <const> = 25000     -- "PAYING OUT" right after one of your games leaves the air
local RIGHT_MIN <const> = 140       -- what the money, mail and heat pips need at the least

-- per-second text cache (countdown strings are rebuilt once a second, not every frame)
local lastSec, lastKind, lastText, lastShort, lastSlate, lastLock = -1, nil, nil, nil, nil, nil

--- kind ("pre" | "air" | "final" | "off" | nil), text, inverse, blinkOn, day, short text.
--- First pitches are staggered, so a lock is usually pending while games are on the air: one of
--- your games on the air wins, then your payout, then the next lock (giving way to "ON AIR" for
--- 3 s in every 8 while games are on and the lock isn't close), then "ON AIR", then the next slate.
local function chip()
  local phase, left, day, _, lock, live = Game.dayPhase()
  if not phase then return nil, nil end
  live = live or 0
  local mine = phase ~= "off" and Game.myLiveGame() or nil
  local paying = phase ~= "off" and not mine and Game.myJustFinal(PAYOUT_MS) or nil
  local kind = phase
  if mine then kind = "air"
  elseif paying then kind = "final"
  elseif phase == "pre" and live > 0 and left >= HOLD_BLINK and (Api.now() // 1000) % 8 >= 5 then kind = "air" end
  local sec = left // 1000
  local text, short
  local slateAt = Game.slate and Game.slate.at
  local lockId = lock and lock.id
  if sec ~= lastSec or kind ~= lastKind or slateAt ~= lastSlate or lockId ~= lastLock then
    lastSlate, lastLock = slateAt, lockId
    if kind == "air" then
      local inn = mine and mine.score and mine.score.inning
      text = inn and ("ON AIR " .. Fmt.inning(inn)) or "ON AIR"
      if not mine and live > 1 then short, text = text, text .. " (" .. live .. ")" end
    elseif kind == "pre" then
      short = "BETS LOCK " .. Fmt.countdown(left)
      text = (lock and lock.away and lock.home) and (short .. " " .. lock.away .. "@" .. lock.home) or short
      -- the last ten seconds tick
      if sec < 10 and sec ~= lastSec and lastKind == "pre" then Sfx.tick() end
    elseif kind == "final" then text = paying and "PAYING OUT" or ("NEXT SLATE " .. Fmt.countdown(left))
    else text = "HOT STOVE" end
    lastSec, lastKind, lastText, lastShort = sec, kind, text, short or text
  else
    text, short = lastText, lastShort
  end
  local f = Game.frame or 0
  local blink = kind == "pre" and left < HOLD_BLINK and (f // 8) % 2 == 1
  return kind, text, kind ~= "final" and kind ~= "off", blink, day, short or text
end

function Status.phaseText()
  local _, t = chip()
  return t
end

--- 0..5 pips (heat runs 0..10).
local function pips(heat)
  return math.max(0, math.min(5, ((heat or 0) + 1) // 2))
end

-- Painting ---------------------------------------------------------------------------------

local function diamond(x, y, fg, bg)
  gfx.setColor(fg)
  gfx.fillPolygon(x + 6, y, x + 12, y + 6, x + 6, y + 12, x, y + 6)
  gfx.setColor(bg)
  gfx.fillRect(x + 5, y + 5, 3, 3)
end

local function clockGlyph(x, y, fg)
  gfx.setColor(fg)
  gfx.drawCircleAtPoint(x + 5, y + 5, 5)
  gfx.drawLine(x + 5, y + 2, x + 5, y + 5)
  gfx.drawLine(x + 5, y + 5, x + 7, y + 6)
end

--- Paints the heartbeat chip at x; returns its width.
local function paintChip(v, x, y, fg, bg, fgName, bgName, text)
  text = text or v.text
  if not text then return 0 end
  local f = UI.fonts.bold
  local tw = f:getTextWidth(text)
  local w = tw + 20
  local inv = v.inv and not v.blink
  if inv then
    gfx.setColor(fg)
    gfx.fillRoundRect(x, y, w, 13, 2)
  else
    gfx.setColor(fg)
    gfx.drawRoundRect(x, y, w, 13, 2)
  end
  local ic, tc = fg, fgName
  if inv then ic, tc = bg, bgName end
  if v.kind == "air" then
    if (v.dot or 0) == 1 then gfx.setColor(ic) gfx.fillCircleAtPoint(x + 8, y + 6, 3) end
    gfx.setColor(ic)
    gfx.drawCircleAtPoint(x + 8, y + 6, 3)
  else
    clockGlyph(x + 3, y + 1, ic)
  end
  Text.draw(text, x + 16, y, f, tc)
  return w
end

--- Paints heat pips, mail and money right-aligned at rx; returns the left edge used.
local function paintRight(v, rx, y, fg, bg, fgName, bgName, roomLeft)
  local f, fb = UI.fonts.body, UI.fonts.bold
  local x = rx
  -- money change this session
  local dw = 0
  local dtext = nil
  if v.delta ~= 0 then
    dtext = (v.delta > 0 and "\u{25b2}+" or "\u{25bc}-") .. Fmt.int(math.abs(v.delta))
    dw = f:getTextWidth(dtext)
  end
  local mtext = Fmt.money(v.money)
  local mw = fb:getTextWidth(mtext)
  local mailText = v.mail > 0 and tostring(v.mail) or nil
  local mailW = mailText and (math.max(8, fb:getTextWidth(mailText)) + 22) or 0
  local heatLabel = true
  local need = dw + 4 + mw + 6 + mailW + 4 + 25 + 30 + (v.car > 0 and 17 or 0)
  if roomLeft and rx - need < roomLeft then heatLabel = false need -= 30 end
  if roomLeft and rx - need < roomLeft then dtext = nil end
  if dtext then
    x -= dw
    Text.draw(dtext, x, y + 1, f, fgName)
    x -= 4
  end
  x -= mw
  if v.flash then
    gfx.setColor(fg)
    gfx.fillRect(x - 2, y, mw + 4, 14)
    Text.draw(mtext, x, y + 1, fb, bgName)
  else
    Text.draw(mtext, x, y + 1, fb, fgName)
  end
  x -= 6
  if mailText then
    local sw = math.max(8, fb:getTextWidth(mailText))
    x -= sw + 8
    gfx.setColor(fg)
    gfx.fillRoundRect(x, y + 1, sw + 7, 12, 4)
    Text.draw(mailText, x + 4 + sw // 2, y, fb, bgName, "center")
    x -= 14
    gfx.setColor(fg)
    gfx.drawRect(x, y + 3, 11, 8)
    gfx.drawLine(x, y + 3, x + 5, y + 7)
    gfx.drawLine(x + 10, y + 3, x + 5, y + 7)
    x -= 6
  end
  -- heat 3+: a squad car (it flashes for a few seconds when the heat goes up)
  if v.car > 0 then
    x -= 13
    local inv = v.car == 2
    gfx.setColor(fg)
    if inv then gfx.fillRect(x - 1, y, 13, 14) gfx.setColor(bg) end
    gfx.fillRect(x + 1, y + 6, 10, 4)
    gfx.fillRect(x + 3, y + 3, 6, 3)
    gfx.setColor(inv and fg or bg)
    gfx.fillRect(x + 2, y + 10, 2, 2)
    gfx.fillRect(x + 8, y + 10, 2, 2)
    gfx.setColor(inv and bg or fg)
    gfx.fillRect(x + 5, y + 1, 2, 2)
    x -= 4
  end
  -- heat: 5 pips, filled = heat / 2
  x -= 25
  gfx.setColor(fg)
  for i = 1, 5 do
    local px = x + (i - 1) * 5
    if i <= v.heat then gfx.fillRect(px, y + 3, 4, 8) else gfx.drawRect(px, y + 3, 4, 8) end
  end
  if heatLabel then
    local hw = f:getTextWidth("HEAT")
    x -= hw + 3
    Text.draw("HEAT", x, y + 1, f, fgName)
  end
  return x
end

local function colors(style)
  if style == "dark" then return gfx.kColorWhite, gfx.kColorBlack, "white", nil end
  return gfx.kColorBlack, gfx.kColorWhite, nil, "white"
end

local function paintBar(img, v, style)
  local fg, bg, fgName, bgName = colors(style)
  img:clear(bg)
  gfx.pushContext(img)
  gfx.setColor(fg)
  gfx.drawLine(0, Status.H - 1, 399, Status.H - 1)
  diamond(4, 1, fg, bg)
  local x = 21
  if v.day then
    x += Text.draw("DAY " .. v.day, x, 2, UI.fonts.bold, fgName) + 6
  end
  -- the long chip ("... SEA@HCL") only if the money, mail and pips still fit beside it
  local text = v.text
  if text and v.short and text ~= v.short and x + UI.fonts.bold:getTextWidth(text) + 28 > 397 - RIGHT_MIN then text = v.short end
  local cw = paintChip(v, x, 1, fg, bg, fgName, bgName, text)
  if v.account then paintRight(v, 397, 1, fg, bg, fgName, bgName, x + cw + 8) end
  gfx.popContext()
end

--- minX: leftmost pixel (image coordinates) the cluster may use; the heat label, the
--- money change and then the chip give way when the screen's title is long.
local function paintCluster(img, v, minX)
  img:clear(gfx.kColorClear)
  gfx.pushContext(img)
  local fg, bg, fgName, bgName = colors("dark")
  local w, h = img:getSize()
  local left = v.account and paintRight(v, w - 1, 1, fg, bg, fgName, bgName, minX + 110) or w
  for _, text in ipairs({ v.text, v.short }) do
    local cw = UI.fonts.bold:getTextWidth(text) + 20
    if left - 8 - cw >= minX then paintChip(v, left - 8 - cw, 1, fg, bg, fgName, bgName, text) break end
  end
  gfx.popContext()
end

-- Values and caching -----------------------------------------------------------------------

local function values(v)
  local kind, text, inv, blink, day, short = chip()
  local a = Game.account
  v.kind, v.text, v.inv, v.blink, v.short = kind, text, inv, blink, short
  v.day = day or (Game.clock and Game.clock.day)
  v.dot = kind == "air" and (((Game.frame or 0) // 15) % 2) or 0
  v.account = a ~= nil
  if a then
    v.money = math.floor(Game.displayMoney or a.money or 0)
    v.delta = (a.money or 0) - (Game.baseMoney or a.money or 0)
    v.mail = a.unreadMail or 0
    v.heat = pips(a.heat)
    v.flash = (Game.moneyFlash or 0) > 0 and ((Game.moneyFlash // 3) % 2 == 0)
    local hf = Game.heatFlash or 0
    v.car = (a.heat or 0) >= 3 and ((hf > 0 and (hf // 6) % 2 == 0) and 2 or 1) or 0
  else
    v.money, v.delta, v.mail, v.heat, v.flash, v.car = 0, 0, 0, 0, false, 0
  end
  return v
end

local FIELDS <const> = { "kind", "text", "short", "inv", "blink", "day", "dot", "account", "money", "delta", "mail", "heat", "flash", "car" }

local function same(a, b)
  for i = 1, #FIELDS do
    local k = FIELDS[i]
    if a[k] ~= b[k] then return false end
  end
  return true
end

local function copy(dst, src)
  for i = 1, #FIELDS do local k = FIELDS[i] dst[k] = src[k] end
end

local bars = {}   -- style -> { img, v }
local scratch = {}

function Status.draw(y, style)
  style = style or "light"
  local b = bars[style]
  if not b then
    b = { img = gfx.image.new(400, Status.H, gfx.kColorWhite), v = {} }
    bars[style] = b
  end
  values(scratch)
  if not b.drawn or not same(scratch, b.v) then
    copy(b.v, scratch)
    paintBar(b.img, b.v, style)
    b.drawn = true
  end
  b.img:draw(0, y or 0)
end

local cluster = nil
--- minX (screen x): keep clear of a title that ends there.
function Status.drawCluster(rx, y, minX)
  if not cluster then cluster = { img = gfx.image.new(270, Status.H, gfx.kColorClear), v = {} } end
  values(scratch)
  local mx = math.max(0, (minX or 0) - (rx - 270))
  if not cluster.drawn or cluster.mx ~= mx or not same(scratch, cluster.v) then
    copy(cluster.v, scratch)
    cluster.mx = mx
    paintCluster(cluster.img, cluster.v, mx)
    cluster.drawn = true
  end
  cluster.img:draw(rx - 270, y or 0)
end
