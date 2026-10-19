-- The desktop ("DeadballOS 96"): a TV Guide and an inbox together.
--   left:   the To Do window, up to 6 things that need you, soonest deadline first, each one
--           press from its action; under it the lead story (EXTRA! strip)
--   right:  9 icons with badges that mean something (unbet games, new stories, unread mail,
--           a blown job, props closing today, an outbid auction); the 9th is Start
--   bottom: the taskbar: Start, a ticker that leads with your live games, modem lights
-- Every source rides the boot / prefetch batch (net/prefetch.lua Prefetch.DESKTOP), so the
-- desktop paints from cache and refreshes in one round trip.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Desktop = Page.define({ style = "bare", canvasH = 210 })
Sites.Desktop = Desktop

local TODO_X <const>, TODO_Y <const>, TODO_W <const> = 4, 4, 236
local ROW_H <const> = 17
local MAX_ROWS <const> = 6
local CD_W <const> = 44         -- countdown column
local RELOAD_MS <const> = 30000 -- coming back to the desktop refreshes at most this often

function Desktop:viewport() return 0, 16, 400, 210 end

function Desktop:sources()
  -- paths must match Prefetch.DESKTOP (and the sites' own sources) exactly
  local o = function(p) return { p, optional = true } end
  return {
    me = "/me", events = o("/events"), news = o("/news"), today = o("/today"), ops = o("/ops"),
    watch = o("/watchlist"), gossip = o("/gossip"), mail = o("/mail"), syn = o("/syndicate"),
    bulletins = o("/bulletins"), bonus = o("/bonus"),
  }
end

function Desktop:init(args)
  Desktop.instance = self
  self.fromBoot = args.fromBoot
  self.firstRun = args.firstRun
end

function Desktop:cleanup()
  if Desktop.instance == self then Desktop.instance = nil end
end

local TUNES <const> = { "summertime", "ragtime", "sweet_georgia" }

function Desktop.music()
  if not Sfx.currentMusic() then
    Sfx.music(TUNES[math.random(#TUNES)], { loop = true, fade = 1.5 })
    Desktop.playing = true
  end
end

-- Sources -> rows -------------------------------------------------------------------------

local function list(d, k) return type(d) == "table" and type(d[k]) == "table" and d[k] or {} end

local function lastName(n) return tostring(n or "?"):match("(%S+)$") or n end

--- The urgency queue: { glyph, text, at (deadline ms) | right (static text), action, hint }.
function Desktop:buildTodo()
  local rows = {}
  local now = Api.now()
  local d = self.data
  local function add(r) rows[#rows + 1] = r end
  -- event cards (they also pop up on their own)
  for _, ev in ipairs(Nav.pendingEvents or {}) do
    local cost = nil
    for _, c in ipairs(ev.choices or {}) do if c.cost then cost = c.cost break end end
    add({ glyph = "!", text = ev.title .. (cost and (" (" .. Fmt.money(cost) .. ")") or ""), at = ev.expiresAt,
      action = function() Sites.EventCard.show(ev) end, hint = "Decide: " .. ev.title, urgent = true })
  end
  -- chip-in asks from allies
  for _, ch in ipairs(list(d.syn, "chipIns")) do
    if (ch.status or "proposed") == "proposed" then
      add({ glyph = "%", text = "Chip in " .. Fmt.money(ch.share) .. " for " .. ch.from .. "'s job", at = ch.locksAt,
        action = function() self:chipIn(ch) end, hint = ch.from .. ": " .. ch.job .. " (" .. (ch.game or "") .. ")" })
    end
  end
  -- unbet games at Bobby's: each locks at its own first pitch, so the row counts down to the next one
  local open, first, games = 0, nil, list(d.today, "games")
  for _, g in ipairs(games) do
    if g.status == "scheduled" and (g.firstPitchAt or 0) > now and not g.myBet then
      open += 1
      if not first or g.firstPitchAt < first.firstPitchAt then first = g end
    end
  end
  self.unbet = open
  if first then
    local more = open > 1 and (" +" .. (open - 1) .. " more") or ""
    add({ glyph = "$", text = "Bobby's: " .. first.away.abbr .. " @ " .. first.home.abbr .. more, at = first.firstPitchAt,
      action = function() Sites.Bets.open({ unbet = true }) end, hint = open .. " game" .. (open > 1 and "s" or "") .. " open. Each locks at its own first pitch" })
  end
  -- your jobs, locking at first pitch
  for _, op in ipairs(list(d.ops, "ops")) do
    local g = op.game
    if op.status == "planned" and g and g.id and (g.firstPitchAt or 0) > now then
      add({ glyph = "#", text = op.name .. " vs " .. ((op.target and op.target.abbr) or g.home.abbr), at = g.firstPitchAt,
        action = function() Nav.game(g.id) end, hint = "Locks at first pitch: " .. g.away.abbr .. " @ " .. g.home.abbr .. " (call it off in the BBS)" })
    end
  end
  -- auctions you're losing
  self.outbid = 0
  for _, l in ipairs(list(d.watch, "listings")) do
    local au = l.auction
    if l.kind == "auction" and l.status == "active" and au and au.yourMax and not au.leading then
      self.outbid += 1
      local c = l.card or {}
      add({ glyph = "^", text = "Outbid: " .. lastName(c.person and c.person.name) .. " " .. ((c.rarity or ""):gsub("^%l", string.upper)), at = au.endsAt,
        action = function() Nav.listing(l) end, hint = "Bid " .. Fmt.money(au.minBid or 0) .. " or more to lead again" })
    end
  end
  -- props: yours closing today, else the hottest open market
  local gd = d.gossip or {}
  local mine, hot, hotPool = nil, nil, -1
  for _, s in ipairs(list(gd, "storylines")) do
    for _, p in ipairs(s.props or {}) do
      if p.status == "open" then
        if p.myBet and p.closesDay and gd.day and p.closesDay <= gd.day then
          if not mine then mine = { s = s, p = p } end
        elseif not p.myBet and (p.pool or 0) > hotPool then
          hot, hotPool = { s = s, p = p }, p.pool or 0
        end
      end
    end
  end
  self.propsToday = mine and 1 or 0
  local pr = mine or hot
  if pr then
    add({ glyph = "?", text = (mine and "Closing: " or "") .. pr.s.headline, at = pr.p.closesAt, right = mine and "today" or nil,
      action = function() Nav.storyline(pr.s.id) end, hint = pr.p.question })
  end
  -- tips: mail that turns into a prop bet
  for _, m in ipairs(list(d.mail, "mail")) do
    if m.kind == "tip" and not m.read then
      add({ glyph = "@", text = "Tip from " .. (m.from or "?") .. ": " .. (m.subject or ""), right = "new",
        action = function() Sites.Letter.open({ mail = m }) end, hint = m.storylineId and "A tip you can bet on" or "A tip" })
      break
    end
  end
  -- soonest first; untimed ("new") last
  for i, r in ipairs(rows) do r.n = i end
  table.sort(rows, function(a, b)
    local ta, tb = a.at or math.huge, b.at or math.huge
    if a.urgent ~= b.urgent then return a.urgent == true end
    if ta ~= tb then return ta < tb end
    return a.n < b.n
  end)
  while #rows > MAX_ROWS do table.remove(rows) end
  if #rows == 0 then
    local phase, left = Game.dayPhase()
    local nxt = Game.clock and Game.clock.nextDayAt
    add({ glyph = "-", text = "Nothing due. " .. (phase == "pre" and "Bobby's is open." or "Bobby's opens soon."), at = phase ~= "pre" and nxt or nil,
      action = function() Sites.Bets.open() end, hint = "Bets By Bobby" })
    local fresh = self.newStories or 0
    if fresh > 0 then
      add({ glyph = "*", text = fresh .. " new stor" .. (fresh > 1 and "ies" or "y") .. " at SportsWire", right = "new",
        action = function() Sites.News.open() end, hint = "SportsWire Online" })
    end
  end
  -- Bobby's loyalty card and odd jobs: last, and only if there's room (they never push out a deadline)
  if Bonus and Bonus.todoRows then
    for _, r in ipairs(Bonus.todoRows(d.bonus)) do
      if #rows >= MAX_ROWS then break end
      add(r)
    end
  end
  self.todo = rows
end

--- Stories newer than the newest one seen at SportsWire.
function Desktop:countNewStories()
  local seen = Game.settings.seenNews
  local n = 0
  for _, s in ipairs(list(self.data.news, "stories")) do
    if s.id == seen then break end
    n += 1
  end
  self.newStories = seen and n or math.min(n, 9)
end

--- Ticker: your live games first, then league bulletins, then the headlines.
function Desktop:buildTicker()
  local parts = {}
  local d = self.data
  for _, g in ipairs(list(d.today, "games")) do
    if g.myBet and g.status ~= "scheduled" and g.score then
      local sc = g.score
      local you = "(YOU: " .. Fmt.money(g.myBet.amount) .. " " .. (g.myBet.side == "home" and g.home.abbr or g.away.abbr) .. ")"
      parts[#parts + 1] = (g.status == "live" and "LIVE: " or "FINAL: ") .. g.away.abbr .. " " .. (sc.away or 0) .. " " .. g.home.abbr .. " " .. (sc.home or 0) .. (g.status == "live" and (" " .. Fmt.inning(sc.inning)) or "") .. " " .. you
    end
  end
  for i, b in ipairs(list(d.bulletins, "bulletins")) do
    if i > 3 then break end
    parts[#parts + 1] = (b.text or ""):upper()
  end
  for i, s in ipairs(list(d.news, "stories")) do
    if i > 8 then break end
    parts[#parts + 1] = s.headline:upper()
  end
  local text = #parts > 0 and (table.concat(parts, "  \u{2605}  ") .. "  \u{2605}  ") or nil
  if text == self.ticker then return end
  self.ticker = text
  self.tickerImg = nil
  if not text then return end
  -- prerendered once; drawing the long string through the font every frame is slow
  self.tickerW = math.min(4000, UI.fonts.bold:getTextWidth(text))
  self.tickerImg = gfx.image.new(self.tickerW, 14, gfx.kColorBlack)
  gfx.pushContext(self.tickerImg)
  Text.draw(text, 0, 1, UI.fonts.bold, "white")
  gfx.popContext()
end

function Desktop:loaded()
  Nav.ready = true
  Desktop.music()
  Nav.markPolled()
  self.loadedAt = playdate.getCurrentTimeMilliseconds()
  if self.data.events and self.data.events.events then Nav.pendingEvents = self.data.events.events end
  self:countNewStories()
  self:buildTicker()
  -- a saved copy's events may already be decided: wait for the fresh list
  if self.stale then return end
  if self.fromBoot then
    self.fromBoot = false
    local unread = (Game.account and Game.account.unreadMail) or 0
    if unread > 0 then
      if not Sfx.stinger("new_mail") then Sfx.mail() end
      Toast.show("Welcome! You've got mail. (" .. unread .. ")", nil)
    end
    playdate.timer.performAfterDelay(400, function()
      if App.top() ~= self then return end
      -- the payoff first (While You Were Out), then any decision that's waiting
      if Sites.Digest and Sites.Digest.maybeShow(function() self:afterDigest() end) then return end
      self:afterDigest()
    end)
  end
end

--- After a background prefetch: take the fresh copies from the cache and repaint.
function Desktop:refreshFromCache()
  local srcs = self:sources()
  for k, src in pairs(srcs) do
    local path = type(src) == "table" and src[1] or src
    local d = Api.peek(path)
    if d then self.data[k] = d end
  end
  self.loadedAt = playdate.getCurrentTimeMilliseconds()
  self:countNewStories()
  self:buildTicker()
  self:render(true)
  -- a new day while sitting on the desktop: the haul from the one that just ended
  local day = Game.clock and Game.clock.day
  if day and self.digestDay and day ~= self.digestDay and App.top() == self and Sites.Digest then
    Sites.Digest.maybeShow(nil)
  end
  self.digestDay = day
end

--- After the haul: today's loyalty-card punch (once a UTC day), then the rest.
function Desktop:afterDigest()
  if App.top() ~= self then return end
  if Sites.PunchCard and Sites.PunchCard.maybeShow(function() self:afterPunch() end) then return end
  self:afterPunch()
end

--- A decision that's waiting, else an EXTRA! that hasn't slammed in yet.
function Desktop:afterPunch()
  if App.top() ~= self then return end
  local ev = Nav.pendingEvents or {}
  if #ev > 0 then Sites.EventCard.show(ev[1]) return end
  if Sites.Extra then Sites.Extra.maybeShow(self.data.news, self.data.gossip) end
end

function Desktop:resume(result)
  Desktop.music()
  local age = playdate.getCurrentTimeMilliseconds() - (self.loadedAt or 0)
  if age > RELOAD_MS then
    self.paused = false
    self:reload(true)
  else
    Page.resume(self, result)
    self:countNewStories()
    self:render(true)
  end
  Nav.checkEvents(false)
end

function Desktop:tick()
  if self.dirty then
    self.dirty = false
    self:render(true)
  end
  -- warm the likely next pages in one background batch (boot / new day, idle only)
  Prefetch.tick(self)
end

function Desktop:chipIn(ch)
  Dialog.show({ title = "Chip in?", icon = "?",
    body = ch.from .. " has your crew on \"" .. ch.job .. "\" (" .. (ch.game or "") .. "). Your share: " .. Fmt.money(ch.share) .. " of " .. Fmt.money(ch.total) .. ".",
    buttons = { "Chip in " .. Fmt.money(ch.share), "No", "Later" }, cancel = 3,
    onChoose = function(i)
      if i == 3 then return end
      Busy.post("/ops/" .. ch.opId .. "/chipin", { accept = i == 1 }, i == 1 and "Passing the hat" or "Saying no", function(d)
        if i == 1 then Sfx.coin() end
        Toast.show(d.result or (i == 1 and "Chipped in." or "You pass."), i == 1 and "good" or nil)
        self:reload(true)
      end)
    end })
end

-- Layout -------------------------------------------------------------------------------------

local function glyphBox(g, x, y)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x, y, 12, 12)
  gfx.setColor(gfx.kColorWhite)
  if g == "#" then
    -- a crowbar: the crew's job
    gfx.drawLine(x + 3, y + 9, x + 8, y + 3)
    gfx.drawLine(x + 8, y + 3, x + 9, y + 5)
    gfx.drawLine(x + 2, y + 9, x + 3, y + 10)
  elseif g == "o" then
    -- a punch-card hole: the loyalty card
    gfx.drawCircleAtPoint(x + 6, y + 6, 4)
    gfx.drawCircleAtPoint(x + 6, y + 6, 3)
  elseif g == "^" then
    -- a flag: the auction
    gfx.drawLine(x + 3, y + 2, x + 3, y + 10)
    gfx.fillRect(x + 4, y + 2, 5, 4)
  else
    Text.draw(g, x + 6, y, UI.fonts.bold, "white", "center")
  end
  gfx.setColor(gfx.kColorBlack)
end

local function cdText(r, now)
  if r.right then return r.right end
  if not r.at then return "" end
  local left = r.at - now
  if left <= 0 then return "now" end
  if left < 3600000 then return Fmt.countdown(left) end
  return Fmt.dur(left)
end

function Desktop:layoutTodo(L)
  local c = Game.clock or {}
  local h = 15 + MAX_ROWS * ROW_H + 5
  local ix, iy, iw = Draw.window(TODO_X, TODO_Y, TODO_W, h, "To Do \u{2022} Day " .. (c.day or "?"))
  local rows = self.todo or {}
  local textW = iw - 22 - CD_W
  for i, r in ipairs(rows) do
    local ry = iy + 2 + (i - 1) * ROW_H
    glyphBox(r.glyph, ix + 3, ry + 2)
    local f = r.urgent and UI.fonts.bold or UI.fonts.body
    Text.draw(Text.ellipsize(r.text, f, textW), ix + 20, ry + 2, f)
    if i < #rows then Draw.dotted(ix + 2, ix + iw - 3, ry + ROW_H - 1) end
    L:link(ix + 1, ry, iw - 2, ROW_H - 1, r.action, { id = "todo:" .. i .. ":" .. (r.glyph or ""), style = "invert", hint = r.hint })
  end
  -- the countdown column ticks once a second: repaint its image only then
  local cx, cy = ix + iw - CD_W - 3, iy + 2
  local n = #rows
  if n > 0 then
    L:live(cx, cy, CD_W, n * ROW_H, function(_, x, y)
      local now = Api.now()
      local sec = now // 1000
      if sec ~= self.cdSec or not self.cdImg then
        self.cdSec = sec
        self.cdImg = self.cdImg or gfx.image.new(CD_W, MAX_ROWS * ROW_H, gfx.kColorClear)
        self.cdImg:clear(gfx.kColorClear)
        gfx.pushContext(self.cdImg)
        for i, r in ipairs(self.todo or {}) do
          local t = cdText(r, now)
          gfx.setColor(gfx.kColorWhite)
          local tw = UI.fonts.bold:getTextWidth(t)
          gfx.fillRect(CD_W - tw - 3, (i - 1) * ROW_H + 1, tw + 3, 13)
          Text.draw(t, CD_W - 1, (i - 1) * ROW_H + 2, UI.fonts.bold, nil, "right")
        end
        gfx.popContext()
      end
      self.cdImg:draw(x, y)
    end)
  end
  return TODO_Y + h
end

function Desktop:layoutExtra(L, y)
  local lead = list(self.data.news, "stories")[1]
  if not lead then return end
  local x, w, h = TODO_X, TODO_W, 206 - y
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  gfx.drawRect(x + 1, y + 1, w - 2, h - 2)
  local tx = x + 6
  if lead.photo and Archive.draw(lead.photo, x + 5, y + 5, 48) then
    tx = x + 58
  elseif lead.face and Faces.get(lead.face, 24) then
    Faces.draw(lead.face, x + 5, y + 5, 24)
    tx = x + 34
  end
  local cw = Draw.chip(tx, y + 4, "EXTRA!", UI.fonts.bold)
  Text.draw("SportsWire" .. ((self.newStories or 0) > 0 and ("  \u{2605}" .. self.newStories .. " new") or ""), tx + cw + 5, y + 5, UI.fonts.body)
  Text.block(lead.headline:upper(), tx, y + 19, x + w - tx - 5, UI.fonts.bold, nil, math.max(1, (h - 22) // 14))
  L:link(x, y, w, h, function() Nav.story(lead.id) end, { id = "extra", style = "ring", hint = lead.dek or lead.headline })
end

-- icon, label, action, hint, badge(self, account) -> text | nil
local ICONS <const> = {
  { "bets", "Bobby's", function() Sites.Bets.open() end, "Bets By Bobby: today's action",
    function(self) return (self.unbet or 0) > 0 and tostring(self.unbet) or nil end },
  { "news", "SportsWire", function() Sites.News.open() end, "SportsWire Online: news & scandal",
    function(self) return (self.newStories or 0) > 0 and ("\u{2605}" .. math.min(9, self.newStories)) or nil end },
  { "scores", "Scores", function() Sites.Schedule.open() end, "Live scores, the slate, standings" },
  { "bbs", "Clubhouse", function() Sites.BBS.open() end, "The Clubhouse BBS: your crew and jobs",
    function(self)
      local day = (Game.clock and Game.clock.day) or 0
      for _, op in ipairs(list(self.data.ops, "ops")) do
        if op.status == "blown" and op.game and (op.game.day or 0) >= day - 1 then return "!" end
      end
    end },
  { "mail", "Mail", function() Sites.Mail.open() end, "DiamondMail: your inbox",
    function(_, a) return (a.unreadMail or 0) > 0 and tostring(a.unreadMail) or nil end },
  { "gossip", "Gossip", function() Sites.Gossip.open() end, "The Gossip Board: bet on their private lives",
    function(self) return (self.propsToday or 0) > 0 and tostring(self.propsToday) or nil end },
  { "cards", "Cards", function() Nav.cards("binder") end, "Your binder (the Card Shop is one press in)" },
  { "market", "Market", function() Nav.cards("market") end, "Bidz-R-Us: buy & sell cards",
    function(self) return (self.outbid or 0) > 0 and "!" or nil end },
  { "start", "Start", function() Desktop.startMenu() end, "Everything else: standings, clubs, syndicate, settings" },
  { "pennant", "Pennant", function() if Pennant then Pennant.open() end end, "Pennant '96: an offline season with your own club" },
}

local function iconCell(i)
  local col = (i - 1) % 3
  local row = (i - 1) // 3
  return 270 + col * 51, 7 + row * 50
end

function Desktop:layoutIcons(L, a)
  for i, ic in ipairs(ICONS) do
    local cx, y = iconCell(i)
    Icons.draw(ic[1], cx - 16, y)
    local f = UI.fonts.body
    local lw = f:getTextWidth(ic[2]) + 6
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(cx - lw // 2, y + 33, lw, 12)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(ic[2], cx, y + 33, f, nil, "center")
    local badge = ic[5] and ic[5](self, a) or nil
    if badge then
      local bw = math.max(14, UI.fonts.bold:getTextWidth(badge) + 8)
      local bx = cx + 18 - bw // 2
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(bx - 1, y - 6, bw + 2, 16)
      gfx.setColor(gfx.kColorBlack)
      gfx.fillRect(bx, y - 5, bw, 14)
      Text.draw(badge, bx + bw // 2, y - 5, UI.fonts.bold, "white", "center")
    end
    L:link(cx - 25, y - 2, 50, 48, ic[3], { id = ic[1], style = "invert", hint = ic[4] })
  end
end

function Desktop:layout(L)
  -- heat 7+: the wallpaper turns into hazard tape (somebody is watching the house)
  local hot = ((Game.account and Game.account.heat) or 0) >= 7
  Draw.tile(0, 0, 400, 210, hot and "weave" or "light")
  local a = Game.account or {}
  self:buildTodo()
  local y = self:layoutTodo(L)
  self:layoutExtra(L, y + 5)
  self:layoutIcons(L, a)
  L:mark(208)
end

function Desktop:initialFocus()
  return 1
end

function Desktop:goBack()
  Sfx.detent()
end

function Desktop:statusLine()
  local l = self.links[self.focus]
  return l and l.hint or ""
end

-- Start menu ---------------------------------------------------------------------------------

function Desktop.startMenu(x, y)
  local lv = function(l) return function() Sites.Standings.open({ level = l }) end end
  Menu.open({ x = x or 0, y = y or 226, anchor = "bottom", banner = "DeadballOS 96", items = {
    { label = "Standings", sub = {
      { label = "Continental", action = lv("ML") }, { label = "Class AA", action = lv("AA") },
      { label = "Class B", action = lv("B") }, { label = "Class D", action = lv("D") } } },
    { label = "Clubs & Orgs", action = function() Sites.Teams.open() end },
    { label = "The Desert League", action = lv("EL") },
    { label = "Syndicate", action = function() Sites.Syndicate.open() end },
    { label = "Card Shop", action = function() Nav.cards("shop") end },
    { label = "Crew & Recruits", action = function() Sites.Recruit.open() end },
    { label = "Odd Jobs & Loyalty Card", action = function() Sites.OddJobs.open() end },
    "-",
    { label = "Pennant '96 (offline)", action = function() if Pennant then Pennant.open() end end },
    { label = "Settings", action = function() Sites.Settings.open() end },
    { label = "Credits", action = function() Sites.Credits.open() end },
  } })
end

-- Taskbar --------------------------------------------------------------------------------------

function Desktop:overlay()
  Chrome.menubar()
  local y = 226
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, y, 400, 14)
  -- ticker (clipped between Start and the tray)
  if self.tickerImg then
    gfx.setClipRect(44, y, 322, 14)
    local off = self.frame % self.tickerW
    self.tickerImg:draw(44 - off, y)
    if self.tickerW - off < 322 then self.tickerImg:draw(44 + self.tickerW - off, y) end
    gfx.clearClipRect()
  end
  -- Start
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(1, y + 1, 40, 13)
  gfx.setColor(gfx.kColorBlack)
  Text.draw("Start", 21, y + 1, UI.fonts.bold, nil, "center")
  -- tray: modem lights blink with real network traffic
  local busy = Api.busy() > 0
  local f = self.frame
  for i = 0, 2 do
    local lx = 372 + i * 9
    local on = busy and ((f // (2 + i)) % 2 == 0) or (i == 2)
    gfx.setColor(gfx.kColorWhite)
    if on then gfx.fillRect(lx, y + 4, 6, 6) else gfx.drawRect(lx, y + 4, 6, 6) end
  end
  gfx.drawLine(0, y, 399, y)
  gfx.setColor(gfx.kColorBlack)
end
