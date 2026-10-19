-- Bets By Bobby: a tote board. One row per game (away @ home, probables, what each side pays,
-- the pool, your stake); left/right picks a side right in the row, A opens the ticket
-- (ui/ticket.lua) on that side, A again places it. Tabs: TODAY, PROPS (the Gossip Board),
-- DESERT (the Enhanced League), MY TICKETS. After a bet the cursor moves to the next game
-- you're not in yet. Pools and payouts read the API's `pool.pays` (house money included).

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Bets = Page.define({ canvasH = 600, refreshOnResume = false })
Sites.Bets = Bets

local W <const> = 392
local ROW_H <const> = 34
-- row columns: away block, "@", home block, the pool / you column
local AX <const>, AW <const> = 6, 156
local MX <const> = 170
local HX <const>, HW <const> = 180, 156
local PX <const> = 342

local QUIPS <const> = {
  "\"I don't fix games. I just know who does.\"",
  "\"Never bet against a raccoon.\"",
  "\"The house always wins. I'm not the house. I'm Bobby.\"",
  "\"Cash only. Feelings, no.\"",
}

function Bets:url()
  local tab = self.tab or "today"
  return "http://www.betsbybobby.com/~bobby/" .. (tab == "today" and "odds" or tab) .. ".html"
end

function Bets:sources()
  return { today = "/today", open = "/bets?status=open", settled = "/bets?status=settled", gossip = { "/gossip", optional = true } }
end

function Bets:init(args)
  self.tab = args.tickets and "tickets" or (args.tab or "today")
  self.sides = {}          -- gameId -> "away" | "home" (picked in the row)
end

function Bets:statusText()
  if self.tab == "tickets" then return "Your tickets. A on a game: the game page." end
  return "\u{25c0}\u{25b6} pick a side \u{2022} A: bet \u{2022} \u{25b2}\u{25bc} next game \u{2022} crank: scroll"
end

--- The games on the current tab.
function Bets:games()
  local out = {}
  local desert = self.tab == "desert"
  for _, g in ipairs(self.data.today and self.data.today.games or {}) do
    if (g.circuit == "enhanced") == desert then out[#out + 1] = g end
  end
  return out
end

local function bettable(g)
  return g.status == "scheduled" and (g.firstPitchAt or 0) > Api.now()
end

--- The next game after `afterId` (wrapping) that's open and that you're not in yet.
function Bets:nextUnbet(afterId)
  local list = self:games()
  local start = 0
  for i, g in ipairs(list) do if g.id == afterId then start = i end end
  for k = 1, #list do
    local g = list[(start + k - 1) % #list + 1]
    if g.id ~= afterId and bettable(g) and not g.myBet then return g end
  end
  return nil
end

--- Opened by Nav.bet (a game named somewhere else): pop that game's ticket once the slate is in.
function Bets:loaded()
  local want = self.args.slip
  if not want or self.slipOpened or self.stale then return end
  self.slipOpened = true
  for _, g in ipairs(self.data.today and self.data.today.games or {}) do
    if g.id == want then
      if bettable(g) then Bets.slip(self, g, self.args.side) else Nav.game(g.id) end
      return
    end
  end
  Toast.show("That game isn't on today's board.", "bad")
end

function Bets:initialFocus()
  local want = nil
  if self.args.unbet then
    local g = self:nextUnbet(nil)
    if g then want = "g:" .. g.id end
  end
  for i, l in ipairs(self.links) do
    if (want and l.id == want) or (not want and l.id and l.id:find("^g:")) then return i end
  end
  return nil
end

function Bets:afterRender()
  local id = self.focusNext
  if id then
    self.focusNext = nil
    for i, l in ipairs(self.links) do
      if l.id == id then self.focus = i self.ring = nil self:ensureVisible(l) return end
    end
  end
  if self.args.unbet and not self.unbetShown and not self.loading and self.data.today then
    self.unbetShown = true
    local l = self.links[self.focus]
    if l then self:ensureVisible(l) end
  end
end

function Bets:onResult(r)
  if r == "placed" then self:reload(true) end
end

function Bets:setTab(t)
  if t == "props" then Sites.Gossip.open() return end
  if t == self.tab then return end
  self.tab = t
  self.focusNext = "tab:" .. t
  self.scroll:jump(0)
  self:render(true)
end

-- Left/right on a game row picks a side; elsewhere it moves the focus.
function Bets:moveFocus(dx, dy)
  local l = self.links[self.focus]
  if dx ~= 0 and dy == 0 and l and l.data and l.data.game and not self.tb then
    local g = l.data.game
    if bettable(g) then
      local side = dx < 0 and "away" or "home"
      if self.sides[g.id] ~= side then
        self.sides[g.id] = side
        Sfx.focus()
      else
        self:bump()
      end
      return
    end
  end
  return Page.moveFocus(self, dx, dy)
end

-- Layout -------------------------------------------------------------------------------------

function Bets:layoutTop(L)
  Draw.tile(0, 0, W, 6400, "lighter")
  local mast = UI.image("images/ui/masthead-bobby")
  local mh = 34
  if mast then mast:draw(4, 2) else Draw.wordart("BETS BY BOBBY", 110, 4, UI.fonts.slab) end
  -- the big countdown box: the next game to lock (first pitches are staggered), repainted once a second
  local bx, by, bw, bh = 232, 2, 156, 34
  gfx.fillRect(bx, by, bw, bh)
  L:live(bx, by, bw, bh, function(_, x, y)
    local phase, left, _, _, lock = Game.dayPhase()
    local sec = (left or 0) // 1000
    local lockId = lock and lock.id
    if sec ~= self.boxSec or phase ~= self.boxPhase or lockId ~= self.boxLock or not self.boxImg then
      self.boxSec, self.boxPhase, self.boxLock = sec, phase, lockId
      self.boxImg = self.boxImg or gfx.image.new(bw, bh, gfx.kColorBlack)
      self.boxImg:clear(gfx.kColorBlack)
      gfx.pushContext(self.boxImg)
      local top, big = "BETS LOCK IN", Fmt.countdown(left or 0)
      if phase == "pre" and lock and lock.away and lock.home then top = lock.away .. " @ " .. lock.home .. " LOCKS IN"
      elseif phase == "air" then top, big = "BOOK CLOSED", "ON AIR"
      elseif phase == "final" then top, big = "NEXT SLATE IN", Fmt.countdown(left or 0)
      elseif not phase then top, big = "BETS LOCK AT", "FIRST PITCH" end
      Text.draw(top, bw // 2, 2, UI.fonts.bold, "white", "center")
      Text.draw(big, bw // 2, 13, UI.fonts.big, "white", "center")
      gfx.popContext()
    end
    self.boxImg:draw(x, y)
  end)
  local y = mh + 6
  -- tabs
  local cont, desert, mine = 0, 0, #(self.data.open and self.data.open.bets or {})
  for _, g in ipairs(self.data.today and self.data.today.games or {}) do
    if bettable(g) then if g.circuit == "enhanced" then desert += 1 else cont += 1 end end
  end
  local props = 0
  for _, s in ipairs(self.data.gossip and self.data.gossip.storylines or {}) do
    for _, p in ipairs(s.props or {}) do if p.status == "open" then props += 1 end end
  end
  local tabs = { { "today", "TODAY (" .. cont .. ")" }, { "props", "PROPS (" .. props .. ")" }, { "desert", "DESERT (" .. desert .. ")" }, { "tickets", "MY TICKETS (" .. mine .. ")" } }
  local tx = 4
  for _, t in ipairs(tabs) do
    local w = UI.fonts.bold:getTextWidth(t[2]) + 12
    local sel = t[1] == (self.tab or "today")
    if sel then
      gfx.fillRect(tx, y, w, 16)
      Text.draw(t[2], tx + 6, y + 1, UI.fonts.bold, "white")
    else
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(tx, y + 1, w, 15)
      gfx.setColor(gfx.kColorBlack)
      gfx.drawRect(tx, y + 1, w, 15)
      Text.draw(t[2], tx + 6, y + 2, UI.fonts.bold)
    end
    L:link(tx, y, w, 16, function() self:setTab(t[1]) end, { id = "tab:" .. t[1], style = "ring",
      hint = t[1] == "props" and "The Gossip Board: bet on their private lives" or (t[1] == "desert" and "The Enhanced League, out in the desert" or (t[1] == "tickets" and "Your open and settled bets" or "Today's Continental slate")) })
    tx += w + 4
  end
  y += 16
  gfx.drawLine(4, y, W - 4, y)
  return y + 4
end

function Bets:layoutRow(L, g, y)
  local live, final = g.status == "live", g.status == "final"
  local open = bettable(g)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(4, y, W - 8, ROW_H)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(4, y, W - 8, ROW_H)
  local pays = g.pool and g.pool.pays or {}
  local sc = g.score or {}
  -- the YOU $n badge (bottom right) eats into the home pitcher's line: measure it first
  local you = g.myBet and ("YOU " .. Fmt.money(g.myBet.amount))
  local yw = you and (UI.fonts.bold:getTextWidth(you) + 6) or 0
  local homeR = you and math.min(HX + HW - 2, W - 7 - yw - 4) or (HX + HW - 2)
  for _, side in ipairs({ "away", "home" }) do
    local t = g[side]
    local p = g.probables and g.probables[side]
    local left = side == "away"
    local bx = left and AX or HX
    local line1 = left and (t.abbr .. "  " .. t.name .. " " .. (t.record or "")) or ((t.record or "") .. " " .. t.name .. "  " .. t.abbr)
    local ax = left and bx + 2 or bx + HW - 2
    Text.draw(Text.ellipsize(line1, UI.fonts.bold, HW - 6), ax, y + 3, UI.fonts.bold, nil, (not left) and "right" or nil)
    local pl = p and ((p.name:match("(%S+)$") or p.name) .. " " .. ((p.line or ""):match("^(%S+),") or "")) or ""
    local big
    if live or final then big = tostring(sc[side] or 0)
    else big = (pays[side] or 0) > 0 and (Fmt.pays(pays[side]) .. "x") or "--" end
    local bf = (live or final) and UI.fonts.head or UI.fonts.bold
    if left then
      Text.draw(Text.ellipsize(pl, UI.fonts.body, HW - 50), bx + 2, y + 18, UI.fonts.body)
      Text.draw(big, bx + HW - 2, y + 17, bf, nil, "right")
    else
      Text.draw(Text.ellipsize(pl, UI.fonts.body, homeR - (bx + 48)), homeR, y + 18, UI.fonts.body, nil, "right")
      Text.draw(big, bx + 2, y + 17, bf)
    end
  end
  Text.draw("@", MX, y + 10, UI.fonts.bold, nil, "center")
  -- pool / you / live state
  local pool = g.pool and ((g.pool.home or 0) + (g.pool.away or 0)) or 0
  if live then
    gfx.fillRect(PX, y + 3, 44, 13)
    Text.draw("LIVE", PX + 22, y + 3, UI.fonts.bold, "white", "center")
    Text.draw(Fmt.inning(sc.inning), PX + 22, y + 18, UI.fonts.bold, nil, "center")
  elseif final then
    Text.draw("FINAL", PX + 22, y + 3, UI.fonts.bold, nil, "center")
  else
    Text.draw(Fmt.money(pool), W - 8, y + 3, UI.fonts.bold, nil, "right")
  end
  if you then
    gfx.fillRect(W - 7 - yw, y + 18, yw, 13)
    Text.draw(you, W - 10, y + 18, UI.fonts.bold, "white", "right")
  elseif open then
    -- this game's own lock (first pitches are staggered): a countdown, repainted once a second
    local fp, cw = g.firstPitchAt or 0, W - 8 - (PX - 6)
    L:live(PX - 6, y + 18, cw, 13, function(_, x, yy) self:drawLock(g.id, fp, x, yy, cw) end)
  elseif not live and not final then
    Text.draw("pool", W - 8, y + 18, UI.fonts.body, nil, "right")
  end
  local hint
  if open then
    hint = g.away.city .. " " .. g.away.name .. " at " .. g.home.city .. " " .. g.home.name .. " \u{2022} " .. Fmt.firstPitch(g)
  elseif live then hint = "LIVE \u{2022} A: the game page (watch it there)"
  else hint = (final and "Final" or "Locked") .. " \u{2022} A: the game page" end
  L:link(4, y, W - 8, ROW_H, function() self:rowAction(g) end, { id = "g:" .. g.id, style = "ring", hint = hint, data = { game = g } })
  return y + ROW_H + 3
end

--- A row's "locks in m:ss", cached per game and second.
function Bets:drawLock(id, fp, x, y, w)
  local left = fp - Api.now()
  local sec = left // 1000
  self.lockImgs = self.lockImgs or {}
  local c = self.lockImgs[id]
  if not c then c = { img = gfx.image.new(w, 13, gfx.kColorClear) } self.lockImgs[id] = c end
  if c.sec ~= sec then
    c.sec = sec
    c.img:clear(gfx.kColorClear)
    gfx.pushContext(c.img)
    local soon = left < 60000
    Text.draw(left > 0 and ((soon and "" or "in ") .. Fmt.countdown(left)) or "LOCKED", w, 0, soon and UI.fonts.bold or UI.fonts.body, nil, "right")
    gfx.popContext()
  end
  c.img:draw(x, y)
end

function Bets:rowAction(g)
  if bettable(g) then Bets.slip(self, g, self.sides[g.id]) else Nav.game(g.id) end
end

--- The picked side in the focused row, drawn on top (no re-render per left/right).
function Bets:live(ox, oy)
  local l = self.links[self.focus]
  if not (l and l.data and l.data.game) or self.tb then return end
  local side = self.sides[l.data.game.id]
  if not side or not bettable(l.data.game) then return end
  local bx = side == "away" and AX or HX
  gfx.setColor(gfx.kColorXOR)
  gfx.fillRect(ox + bx - 1, oy + l.y + 2, HW + 2, ROW_H - 4)
  gfx.setColor(gfx.kColorBlack)
end

function Bets:layout(L)
  local y = self:layoutTop(L)
  if self.tab == "tickets" then
    y = self:layoutBets(L, y + 2, "OPEN TICKETS", self.data.open and self.data.open.bets or {}, "Nothing riding. Pick a game on the TODAY tab.")
    y = self:layoutBets(L, y, "SETTLED", self.data.settled and self.data.settled.bets or {}, "No history yet.")
  else
    local games = self:games()
    if #games == 0 then
      Draw.panel(4, y + 2, W - 8, 30)
      L:text(self.tab == "desert" and "No desert games today." or "No games on the board. The slate posts when the day starts.", 12, y + 10)
      y += 38
    end
    for _, g in ipairs(games) do y = self:layoutRow(L, g, y) end
  end
  y += 4
  -- Bobby box + visitor counter
  local bh = 34
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(4, y, 270, bh)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(4, y, 270, bh)
  Faces.draw("face:42", 8, y + 5, 24)
  local quip = QUIPS[((Game.clock and Game.clock.day) or 0) % #QUIPS + 1]
  Text.block(quip .. " -Bobby", 38, y + 3, 232, UI.fonts.body, nil, 2)
  local cx = 282
  Text.draw("visitors:", cx, y, UI.fonts.body)
  local visits = 4211 + (Game.frame or 0) // 900
  L:live(cx, y + 14, 70, 14, function(p, x, yy, f)
    local roll = ((f % 90) > 80) and ((f % 90) - 80) / 10 or 0
    Draw.hitCounter(x, yy, visits, 6, roll)
  end)
  y += bh + 4
  Text.draw("(not a real bookie, this is entertainment)", 6, y, UI.fonts.body)
  y += 16
  Draw.stripes(4, y, W - 8, 12, "UNDER CONSTRUCTION")
  L:mark(y + 16)
end

function Bets:layoutBets(L, y, title, bets, empty)
  local x, w = 4, 384
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x, y, w, 15)
  Text.draw(title, x + 5, y + 1, UI.fonts.bold, "white")
  y += 18
  if #bets == 0 then
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x, y - 2, w, 16)
    gfx.setColor(gfx.kColorBlack)
    L:text(empty, x + 6, y, UI.fonts.body)
    return y + 20
  end
  for _, b in ipairs(bets) do
    local g = b.game or {}
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x, y - 2, w, 30)
    gfx.setColor(gfx.kColorBlack)
    local side = g.home and (b.side == "home" and g.home or g.away) or nil
    local label = (side and (side.city .. " " .. side.name) or (b.label or "?")) .. " to win"
    Text.draw(Fmt.money(b.amount), x + 6, y, UI.fonts.bold)
    Text.draw(label, x + 60, y, UI.fonts.body)
    local st = b.status or "open"
    local right
    if st == "settled" then st = b.won and "won" or ((b.payout or 0) > 0 and "won" or "lost") end
    if st == "won" then right = "WON " .. Fmt.money(b.payout or 0)
    elseif st == "lost" then right = "LOST"
    elseif g.pool and g.pool.pays then right = "pays ~" .. Fmt.money(math.floor(b.amount * (g.pool.pays[b.side] or 0)))
    else right = "open" end
    if st == "won" then
      local rw = UI.fonts.bold:getTextWidth(right) + 6
      gfx.fillRect(x + w - 6 - rw, y - 1, rw, 13)
      Text.draw(right, x + w - 9, y, UI.fonts.bold, "white", "right")
    else
      Text.draw(right, x + w - 6, y, UI.fonts.bold, nil, "right")
    end
    if g.away then
      local gl = g.away.abbr .. " @ " .. g.home.abbr .. "  \u{2022}  Day " .. (g.day or "?")
      if g.score then gl = gl .. "  \u{2022}  " .. g.score.away .. "-" .. g.score.home .. " " .. (g.score.inning or "") end
      L:textLink(gl, x + 60, y + 13, function() Nav.game(g.id) end, { id = "bet:" .. (b.id or "") .. ":game", hint = "The game page" })
    end
    y += 32
  end
  return y + 4
end

-- The ticket ----------------------------------------------------------------------------------

--- Payout estimate for a new stake (docs/API.md "House money": the house's own money isn't
--- raked): win ~ amount * (0.9 * (pool - house + amount) + house) / (side + amount).
function Bets.estimate(g, side, amount)
  local p = g.pool or {}
  local pool = (p.home or 0) + (p.away or 0)
  local house = p.house and ((p.house.home or 0) + (p.house.away or 0)) or 0
  local mine = (p[side] or 0) + amount
  local net = 0.9 * (pool - house + amount) + house
  local win = math.floor(amount * net / math.max(1, mine))
  return win, net / math.max(1, mine)
end

--- Opens the ticket for game g. side: "away" | "home" | nil (pick it on the ticket).
function Bets.slip(page, g, side)
  if not Game.account then return end
  if page.requireFresh and not page:requireFresh() then return end
  if not bettable(g) then
    Dialog.alert("Window closed", "First pitch already happened. Bobby doesn't take bets on the past.")
    return
  end
  side = side or (g.myBet and g.myBet.side) or nil
  local money = Game.account.money or 0
  local max = math.max(5, math.floor(money * 0.5))
  if money < 10 then
    Dialog.alert("Short on cash", "Bobby's minimum is $5, and he caps you at half your bankroll.")
    return
  end
  local pays = g.pool and g.pool.pays or {}
  local function upper(t) return t.name:upper() end
  Ticket.open({
    page = page,
    title = function(s)
      local us, them = g[s], g[s == "home" and "away" or "home"]
      return upper(us) .. " to beat " .. upper(them)
    end,
    sub = "Day " .. (g.day or "?") .. " \u{2022} " .. (g.park or "") .. " \u{2022} " .. (g.weather or ""),
    sides = { { key = "away", label = g.away.name, pays = pays.away }, { key = "home", label = g.home.name, pays = pays.home } },
    side = side, min = 5, max = max,
    estimate = function(amount, s) return Bets.estimate(g, s, amount) end,
    winWord = function(s) return "the " .. g[s].name .. " win" end,
    closes = function()
      local left = (g.firstPitchAt or 0) - Api.now()
      return left > 0 and ("first pitch, " .. Fmt.countdown(left)) or "first pitch"
    end,
    place = function(amount, s, done)
      Api.post("/bets", { gameId = g.id, side = s, amount = amount }, function(err, d)
        if err then
          Sfx.error()
          Dialog.alert(err.code == "window_closed" and "Window closed" or "Bobby says no", Api.errorText(err))
          done(false)
          return
        end
        Game.absorb(d)
        g.myBet = { side = s, amount = ((g.myBet and g.myBet.side == s) and g.myBet.amount or 0) + amount }
        if page.sides then page.sides[g.id] = nil end
        done(true)
      end)
    end,
    after = function(s)
      local nxt = page.nextUnbet and page:nextUnbet(g.id) or nil
      local them = g[s == "home" and "away" or "home"]
      return {
        next = nxt and (nxt.away.abbr .. " @ " .. nxt.home.abbr) or nil,
        onNext = function()
          if not page.nextUnbet then return end
          if nxt then page.focusNext = "g:" .. nxt.id end
        end,
        onRig = function() Nav.job({ gameId = g.id, targetId = them.id }) end,
      }
    end,
  })
end
