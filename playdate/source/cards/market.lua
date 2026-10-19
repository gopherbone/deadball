-- BIDZ-R-US: the card market as a 90s auction site.
--   Browse (sort / rarity / team / redeemable filters), Watching, Selling tabs.
--   Item page: current bid, bids, time left, reserve badge, Buy It Now, proxy (max) bid
--   picked with the crank, masked bid history, price-history mini chart, watch toggle.
--   Sell flow (from the binder): auction or fixed price, start bid, reserve, Buy It Now, duration.
--
-- Shapes per docs/API.md "Market": ListingView { id, card, price, seller, at, kind, status,
-- watchers, watching, auction = { startBid, currentBid, bids, endsAt, minBid, hasReserve,
-- reserveMet, buyNow, leader, leading, yourMax } }.
--
-- Endpoints: GET /market?sort=&rarity=&redeemable=&team=&cursor=, GET /watchlist,
-- GET /market/:id → { listing, bids }, GET /market/history?def=, POST /market/:id/bid { max },
-- POST /market/:id/buy, POST|DELETE /market/:id/watch, POST /market (fixed { cardId, price } |
-- auction { cardId, kind, startBid, hours, reserve?, buyNow? }), DELETE /market/:id.

import "ballcast/kit"
import "cards/ui"
import "cards/render"

local gfx <const> = playdate.graphics
local floor <const>, min <const>, max <const>, abs <const> = math.floor, math.min, math.max, math.abs

Cards = Cards or {}
local K = BCKit
local UI = Cards.UI
local CR = Cards.Render

local SITE <const> = "BIDZ-R-US"

---------------------------------------------------------------------------
-- helpers

local function nowMs()
  if Api and Api.now then local ok, v = pcall(Api.now); if ok and v then return v end end
  -- Playdate epoch is 2000-01-01; integers are 32-bit, so do this in floats
  local s, ms = playdate.getSecondsSinceEpoch()
  return (s + 946684800.0) * 1000.0 + ms
end

-- server "now" at fetch + local elapsed (fixtures carry their own `now`)
local clock = { server = nil, localAt = 0 }
local function setClock(serverNow)
  clock.server = serverNow or nowMs()
  clock.localAt = playdate.getCurrentTimeMilliseconds()
end
local function serverNow()
  if not clock.server then return nowMs() end
  return clock.server + (playdate.getCurrentTimeMilliseconds() - clock.localAt)
end

local function auc(l) return l.auction or {} end
-- masked names ("G***e"): the pixel fonts have no '*'
local function mask(s) return (tostring(s or "?"):gsub("%*", ".")) end
local function bidsOf(l) return auc(l).bids or l.bids or 0 end
local function endsAt(l) return auc(l).endsAt or l.endsAt end
local function buyNowOf(l) return auc(l).buyNow or l.buyNow end
local function reserveNotMet(l)
  local a = auc(l)
  if a.hasReserve ~= nil then return a.hasReserve and not a.reserveMet end
  return l.reserveMet == false
end

--- seconds left on a listing (nil when unknown / fixed price without an end).
--- NOTE: the Playdate's json decoder mangles 13-digit epoch-ms numbers (32-bit ints), so
--- prefer a relative `endsIn` (seconds at response time) when the server sends one.
local function secsLeft(l)
  if l.status and l.status ~= "active" then return 0 end
  local a = auc(l)
  local rel = a.endsIn or l.endsIn
  if rel then
    l._fetchedAt = l._fetchedAt or playdate.getCurrentTimeMilliseconds()
    return floor(rel - (playdate.getCurrentTimeMilliseconds() - l._fetchedAt) / 1000)
  end
  local e = endsAt(l)
  if not e or e < 1.5e12 or e > 3e12 then return nil end
  return floor((e - serverNow()) / 1000)
end

local function fmtLeft(s)
  if not s then return "LIVE" end
  if s == true then return "" end
  if s <= 0 then return "ENDED" end
  local d, h, m = floor(s / 86400), floor(s % 86400 / 3600), floor(s % 3600 / 60)
  if d > 0 then return d .. "D " .. h .. "H" end
  if h > 0 then return h .. "H " .. m .. "M" end
  -- Lua numbers on the Playdate are single floats: epoch-ms math is only good to ~2 min
  if s < 180 then return "ENDING!" end
  return m .. "M"
end
Cards.fmtLeft = fmtLeft

local function isAuction(l) return l.kind == "auction" end

-- API.md: +$5 under $100, +$25 under $1k, +$100 under $5k, else +$250
local function increment(p)
  if p < 100 then return 5 elseif p < 1000 then return 25 elseif p < 5000 then return 100 end
  return 250
end

local function minBid(l)
  local a = auc(l)
  if a.minBid then return a.minBid end
  if bidsOf(l) == 0 then return max(1, a.startBid or l.startBid or l.price or 1) end
  return (l.price or 0) + increment(l.price or 0)
end

local function hot(l)
  local s = secsLeft(l)
  return isAuction(l) and bidsOf(l) >= 3 and s and s > 0 and s < 6 * 3600
end

local burst
local function drawHot(x, y, t)
  burst = burst or (playdate.file.exists("images/ui/hot-burst-table-30-20.pdt") and gfx.imagetable.new("images/ui/hot-burst-table-30-20")) or false
  if burst then
    burst:getImage(1 + (floor(t * 6) % burst:getLength())):draw(x, y)
  else
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x, y + 3, 28, 13)
    K.textW(K.fonts.bitmore, "HOT!", x + 14, y + 4, "center")
  end
  -- little flames
  gfx.setColor(gfx.kColorBlack)
  for i = 0, 2 do
    local fx = x + 4 + i * 9
    local fh = 4 + (floor(t * 10 + i) % 3) * 2
    gfx.fillTriangle(fx, y + 3, fx + 5, y + 3, fx + 2, y + 3 - fh)
  end
end

local digits
local function drawCounter(n, x, y)
  digits = digits or (playdate.file.exists("images/ui/counter-digits-table-9-14.pdt") and gfx.imagetable.new("images/ui/counter-digits-table-9-14")) or false
  local s = string.format("%07d", floor(n) % 10000000)
  if digits then
    for i = 1, #s do digits:getImage(tonumber(s:sub(i, i)) + 1):draw(x + (i - 1) * 9, y) end
  else
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x, y, 63, 14)
    K.textW(K.fonts.mono, s, x + 2, y)
  end
end

local function header(sub)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 22)
  -- WordArt-ish logo: outlined, tilted letters
  local f = K.fonts.wordart
  if f == gfx.getSystemFont() then f = K.fonts.slab end
  K.textW(K.fonts.slab, SITE, 9, 2)
  K.textW(K.fonts.slab, SITE, 8, 1)
  local a = UI.account()
  local m = (a and a.money) or UI.money
  if m then K.textW(K.fonts.nb, K.money(m), 392, 4, "right") end
  if sub then K.textW(K.fonts.bitmore, sub, 120, 6) end
end

---------------------------------------------------------------------------
-- browse

local M = { opaque = true }
Cards.marketScene = M

local SORTS = {
  { key = "ending", label = "ENDING SOONEST", cmp = function(a, b) return (endsAt(a) or 9e15) < (endsAt(b) or 9e15) end },
  { key = "new", label = "NEWLY LISTED", cmp = function(a, b) return (a.at or 0) > (b.at or 0) end },
  { key = "price", label = "PRICE: LOW FIRST", cmp = function(a, b) return (a.price or 0) < (b.price or 0) end },
  { key = "-price", label = "PRICE: HIGH FIRST", cmp = function(a, b) return (a.price or 0) > (b.price or 0) end },
  { key = "bids", label = "MOST BIDS", cmp = function(a, b) return bidsOf(a) > bidsOf(b) end },
}
local RARITIES = { "all", "common", "uncommon", "rare", "gilded", "misprint", "original" }
local TABS = { { "browse", "ALL ITEMS" }, { "watch", "WATCHING" }, { "mine", "SELLING" } }

local ROW_H <const> = 32
local LIST_Y <const> = 40
local VISIBLE <const> = 5

function M:enter()
  self.tab = 1
  self.sort, self.rarity, self.team, self.redeemable = 1, 1, 1, false
  self.sel, self.scroll = 1, 0
  self.listings, self.watch = nil, nil
  self.err = nil
  self.crankAcc = 0
  self.t = 0
  self.hits = 4000 + floor(K.hash01(playdate.getSecondsSinceEpoch() // 600, 1) * 9000)
  UI.refreshMoney()
  self:load()
end

function M:exit() CR.trim(nil); burst, digits = nil, nil end
function M:resume(result) UI.refreshMoney(); if result == "reload" then self:load() else self:rebuild() end end

function M:load()
  self.listings = nil
  local all = {}
  local q = "/market?sort=" .. SORTS[self.sort].key
  if self.rarity > 1 then q = q .. "&rarity=" .. RARITIES[self.rarity] end
  if self.redeemable then q = q .. "&redeemable=1" end
  local function page(cursor)
    K.get(q .. (cursor and ("&cursor=" .. cursor) or ""), function(err, d)
      if err or not d then
        if #all == 0 then self.err = UI.errText(err) end
        self.listings = all
        self:rebuild()
        return
      end
      if not cursor then
        -- fixture mode: fixtures are frozen in time, so run the clock from when they were made
        local base = d.now
        if not base and K.offlineOK() then
          for _, l in ipairs(d.listings or {}) do if l.at and (not base or l.at > base) then base = l.at end end
          if base then base = base + 60000 end
        end
        setClock(base)
      end
      for _, l in ipairs(d.listings or {}) do all[#all + 1] = l end
      if d.next and #all < 200 then page(d.next) else
        -- fixture mode with an old fixed-price fixture: use the richer dev auction data
        self.listings = all
        self:rebuild()
      end
    end, { fresh = true })
  end
  page(nil)
  K.get("/watchlist", function(err, d)
    self.watch = {}
    if not err and d then for _, l in ipairs(d.listings or {}) do self.watch[l.id] = true end end
    self:rebuild()
  end, { fresh = true })
end

local function myName() local a = UI.account(); return a and a.name end

function M:teams()
  local seen, list = {}, { "all" }
  for _, l in ipairs(self.listings or {}) do
    local t = l.card and l.card.team and l.card.team.abbr
    if t and not seen[t] then seen[t] = true; list[#list + 1] = t end
  end
  table.sort(list, function(a, b) if a == "all" then return true elseif b == "all" then return false end return a < b end)
  return list
end

function M:rebuild()
  if not self.listings then return end
  local me = myName() or "you"
  local rows = {}
  local tab = TABS[self.tab][1]
  local rf = RARITIES[self.rarity]
  local teams = self:teams()
  local tf = teams[self.team] or "all"
  for _, l in ipairs(self.listings) do
    local mine = l.seller == me or l.seller == "you" or l.mine
    if l.watching and self.watch then self.watch[l.id] = true end
    local c = l.card or {}
    local keep
    if tab == "mine" then keep = mine
    elseif tab == "watch" then keep = (self.watch and self.watch[l.id]) or l.watching
    else
      keep = not mine and (l.status == nil or l.status == "active")
        and (rf == "all" or CR.rarityOf(c) == rf)
        and (tf == "all" or (c.team and c.team.abbr) == tf)
        and (not self.redeemable or c.redeem ~= nil)
    end
    if keep then rows[#rows + 1] = l end
  end
  table.sort(rows, SORTS[self.sort].cmp)
  self.rows = rows
  local n = self:count()
  if self.sel > n then self.sel = max(1, n) end
end

-- browse has 4 control rows (sort, rarity, team, redeemable) before the listings
local CONTROLS = { "sort", "rarity", "team", "redeemable" }
function M:controls() return TABS[self.tab][1] == "browse" and #CONTROLS or (TABS[self.tab][1] == "watch" and 1 or 0) end
function M:count() return #(self.rows or {}) + self:controls() end
function M:itemAt(i)
  local nc = self:controls()
  if i <= nc then return TABS[self.tab][1] == "browse" and CONTROLS[i] or "sort" end
  return self.rows and self.rows[i - nc]
end

local function move(self, d)
  local n = self:count()
  if n == 0 then return end
  self.sel = K.clamp(self.sel + d, 1, n)
  if self.sel - self.scroll > VISIBLE then self.scroll = self.sel - VISIBLE end
  if self.sel <= self.scroll then self.scroll = self.sel - 1 end
  K.sfx("tick")
end

function M:upButtonDown() move(self, -1) end
function M:downButtonDown() move(self, 1) end
function M:cranked(c)
  self.crankAcc = self.crankAcc + c
  while self.crankAcc > 30 do self.crankAcc = self.crankAcc - 30; move(self, 1) end
  while self.crankAcc < -30 do self.crankAcc = self.crankAcc + 30; move(self, -1) end
end
local function switchTab(self, d)
  self.tab = (self.tab - 1 + d) % #TABS + 1
  self.sel, self.scroll = 1, 0
  self:rebuild()
  K.sfx("flip")
end
function M:leftButtonDown() switchTab(self, -1) end
function M:rightButtonDown() switchTab(self, 1) end
function M:BButtonDown() App.pop() end

function M:AButtonDown()
  local it = self:itemAt(self.sel)
  if it == "sort" then self.sort = self.sort % #SORTS + 1; self:load(); K.sfx("click") return
  elseif it == "rarity" then self.rarity = self.rarity % #RARITIES + 1; self:load(); K.sfx("click") return
  elseif it == "team" then self.team = self.team % #self:teams() + 1; self:rebuild(); K.sfx("click") return
  elseif it == "redeemable" then self.redeemable = not self.redeemable; self:load(); K.sfx("click") return end
  if type(it) == "table" then
    App.push(Cards.itemScene, { listing = it, market = self })
    K.sfx("click")
  end
end

local function drawRow(self, l, y, sel)
  local c = l.card or {}
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(4, y, 392, ROW_H - 2)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(4, y, 392, ROW_H - 2)
  if sel then gfx.setLineWidth(2); gfx.drawRect(3, y - 1, 394, ROW_H); gfx.setLineWidth(1) end
  if c.id and c.person then CR.thumb(c, 0.18):draw(7, y + 1) end
  local r = CR.rarityOf(c)
  -- blue-underlined "link" title, 90s style
  local title = K.fit(K.fonts.nb, string.upper(c.person and c.person.name or "?") .. " " .. (CR.RARITY_LABEL[r] or ""), 188)
  K.text(K.fonts.nb, title, 30, y + 1)
  gfx.drawLine(30, y + 14, 30 + K.textWidth(K.fonts.nb, title), y + 14)
  local tags = {}
  if c.redeem and not c.redeemed then tags[#tags + 1] = "REDEEMABLE" end
  if c.finalSeason then tags[#tags + 1] = "FINAL SEASON" end
  if isAuction(l) and reserveNotMet(l) then tags[#tags + 1] = "RESERVE NOT MET" end
  if buyNowOf(l) then tags[#tags + 1] = "BUY IT NOW " .. K.money(buyNowOf(l)) end
  if not isAuction(l) then tags[#tags + 1] = "FIXED PRICE" end
  if auc(l).leading then tags[#tags + 1] = "YOU'RE WINNING" end
  K.text(K.fonts.bitmore, K.fit(K.fonts.bitmore, table.concat(tags, " - "), 200), 30, y + 17)
  -- right block: price, bids, time
  K.text(K.fonts.big, K.money(l.price or 0), 390, y + 1, "right")
  local sub = isAuction(l) and (bidsOf(l) .. " BIDS  " .. fmtLeft(secsLeft(l))) or ((l.watchers and l.watchers > 0) and (l.watchers .. " WATCHING") or "")
  local w = K.fonts.big and K.textWidth(K.fonts.big, K.money(l.price or 0)) or 40
  K.text(K.fonts.bitmore, sub, 388 - w - 6, y + 17, "right")
  if hot(l) then drawHot(232, y + 6, self.t) end
end

function M:update()
  self.t = self.t + 1 / 30
  UI.paper()
  header("THE WORLD'S #1 CARD AUCTION SITE")
  -- tabs + hit counter
  for i, t in ipairs(TABS) do
    local x = 4 + (i - 1) * 86
    local on = i == self.tab
    gfx.setColor(on and gfx.kColorBlack or gfx.kColorWhite)
    gfx.fillRect(x, 24, 82, 13)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(x, 24, 82, 13)
    if on then K.textW(K.fonts.bitmore, t[2], x + 41, 25, "center") else K.text(K.fonts.bitmore, t[2], x + 41, 25, "center") end
  end
  K.text(K.fonts.bitmore, "VISITORS", 324, 25, "right")
  drawCounter(self.hits, 330, 23)
  if self.err and not self.rows then K.text(K.fonts.nb, self.err, 200, 110, "center"); UI.hints("B BACK") return end
  if not self.rows then K.text(K.fonts.nb, "Connecting to " .. SITE .. "...", 200, 110, "center") return end
  local n = self:count()
  for vi = 1, VISIBLE + 1 do
    local i = self.scroll + vi
    local it = self:itemAt(i)
    if not it then break end
    local y = LIST_Y + (vi - 1) * ROW_H
    if y > 222 - ROW_H + 2 then break end
    local sel = i == self.sel
    if type(it) == "string" then
      gfx.setColor(sel and gfx.kColorBlack or gfx.kColorWhite)
      gfx.fillRect(4, y, 392, ROW_H - 6)
      gfx.setColor(gfx.kColorBlack)
      gfx.drawRect(4, y, 392, ROW_H - 6)
      local label
      if it == "sort" then label = "SORT BY: " .. SORTS[self.sort].label
      elseif it == "rarity" then label = "RARITY: " .. string.upper(RARITIES[self.rarity])
      elseif it == "team" then label = "TEAM: " .. string.upper(self:teams()[self.team] or "all")
      else label = "REDEEMABLE ONLY: " .. (self.redeemable and "YES" or "NO") end
      if sel then K.textW(K.fonts.nb, label, 12, y + 6) else K.text(K.fonts.nb, label, 12, y + 6) end
      local cnt = (it == "redeemable") and ("  " .. #self.rows .. " ITEMS") or ""
      if sel then K.textW(K.fonts.bitmore, "A: CHANGE" .. cnt, 388, y + 8, "right") else K.text(K.fonts.bitmore, cnt, 388, y + 8, "right") end
    else
      drawRow(self, it, y, sel)
    end
  end
  if #self.rows == 0 then
    local msg = ({ browse = "No items match. Try fewer filters.", watch = "You're not watching anything.", mine = "You're not selling anything. Sell from your binder." })[TABS[self.tab][1]]
    K.text(K.fonts.nb, msg, 200, LIST_Y + self:controls() * ROW_H + 20, "center")
  end
  if n > VISIBLE then
    local h = VISIBLE * ROW_H
    local bh = max(10, h * VISIBLE / n)
    gfx.fillRect(397, LIST_Y + (h - bh) * (self.scroll / max(1, n - VISIBLE)), 3, bh)
  end
  UI.hints("UP/DN PICK   A OPEN   < > TABS   B BACK")
  UI.drawToast(self)
end

---------------------------------------------------------------------------
-- item page

local I = { opaque = true }
Cards.itemScene = I

function I:enter(args)
  self.l = args.listing
  self.market = args.market
  self.sel = 1
  self.showBids = false
  self.bidList, self.history = nil, nil
  self.t = 0
  self:refresh()
  local c = self.l.card or {}
  K.get("/market/history?def=" .. (c.defId or ""), function(err, d)
    self.history = {}
    self.stats = (not err and d) and d.stats or nil
    if not err and d then for _, sl in ipairs(d.sales or d.points or {}) do self.history[#self.history + 1] = sl end end
    -- oldest first for the chart
    table.sort(self.history, function(a, b) return (a.at or 0) < (b.at or 0) end)
  end)
  self:buildActions()
end

function I:refresh()
  local id = self.l.id
  K.get("/market/" .. id, function(err, d)
    if err or not d then self.bidList = self.bidList or {} return end
    if d.listing and d.listing.id == id then for k, v in pairs(d.listing) do self.l[k] = v end end
    self.bidList = d.bids or {}
    self:buildActions()
  end, { fresh = true })
end

function I:buildActions()
  local l = self.l
  local me = myName() or "you"
  local mine = l.seller == me or l.seller == "you" or l.mine
  local ended = secsLeft(l) and secsLeft(l) <= 0
  self.actions = {}
  if mine then
    if not isAuction(l) or bidsOf(l) == 0 then self.actions[#self.actions + 1] = { key = "cancel", label = "CANCEL LISTING" } end
  elseif not ended then
    if isAuction(l) then self.actions[#self.actions + 1] = { key = "bid", label = "PLACE A BID" } end
    if buyNowOf(l) and bidsOf(l) == 0 then
      self.actions[#self.actions + 1] = { key = "buy", label = "BUY IT NOW " .. K.money(buyNowOf(l)) }
    elseif not isAuction(l) then
      self.actions[#self.actions + 1] = { key = "buy", label = "BUY IT NOW " .. K.money(l.price or 0) }
    end
  end
  local watching = (self.market and self.market.watch and self.market.watch[l.id]) or l.watching
  self.actions[#self.actions + 1] = { key = "watch", label = watching and "STOP WATCHING" or "WATCH THIS ITEM" }
  self.actions[#self.actions + 1] = { key = "bids", label = "BID HISTORY / PRICES" }
  if self.sel > #self.actions then self.sel = 1 end
end

function I:upButtonDown() self.sel = (self.sel - 2) % #self.actions + 1; K.sfx("tick") end
function I:downButtonDown() self.sel = self.sel % #self.actions + 1; K.sfx("tick") end
function I:BButtonDown() App.pop(self.changed and "reload" or nil) end

function I:AButtonDown()
  local a = self.actions[self.sel]
  local l = self.l
  local who = l.card and l.card.person and l.card.person.name or "this card"
  if a.key == "bid" then
    App.push(Cards.bidPicker(l, function(maxBid)
      if not maxBid then return end
      K.post("/market/" .. l.id .. "/bid", { max = maxBid }, function(err, d)
        if err or not d then UI.toast(self, UI.errText(err)); K.sfx("buzz") return end
        if d.listing then for k, v in pairs(d.listing) do l[k] = v end end
        UI.setAccount(d.account)
        self.changed = true
        local high = d.leading ~= false
        self.resultText = d.result
        UI.toast(self, high and "YOU'RE THE HIGH BIDDER!" or "OUTBID! Somebody's max is higher.", 2.6)
        K.sfx(high and "chime" or "buzz")
        self:refresh()
      end)
    end))
  elseif a.key == "buy" then
    local price = buyNowOf(l) or l.price
    App.push(UI.confirm("BUY IT NOW?", who .. " for " .. K.money(price) .. ", right now, no waiting. Seller is " .. (l.seller or "a stranger") .. ".", function()
      K.post("/market/" .. l.id .. "/buy", {}, function(err, d)
        if err or not d then UI.toast(self, UI.errText(err)); K.sfx("buzz") return end
        UI.setAccount(d.account)
        if self.market and self.market.listings then
          for i, x in ipairs(self.market.listings) do if x.id == l.id then table.remove(self.market.listings, i) break end end
        end
        CR.revealSound(d.card or l.card or {})
        App.pop()
        if self.market then UI.toast(self.market, "SOLD! " .. who .. " is in your binder.") end
      end)
    end, "BUY"))
  elseif a.key == "watch" then
    local on = not ((self.market and self.market.watch and self.market.watch[l.id]) or l.watching)
    local function done(err, d)
      if err then UI.toast(self, UI.errText(err)) return end
      if d and d.watching ~= nil then on = d.watching end
      l.watching = on
      if self.market then self.market.watch = self.market.watch or {}; self.market.watch[l.id] = on or nil end
      UI.toast(self, on and "Added to your watch list." or "Removed from your watch list.")
      self:buildActions()
    end
    if on then K.post("/market/" .. l.id .. "/watch", {}, done) else K.delete("/market/" .. l.id .. "/watch", done) end
  elseif a.key == "bids" then
    self.showBids = not self.showBids
  elseif a.key == "cancel" then
    App.push(UI.confirm("END THIS LISTING?", "Take " .. who .. " off " .. SITE .. "? It goes back in your binder.", function()
      K.delete("/market/" .. l.id, function(err)
        if err then UI.toast(self, UI.errText(err)); K.sfx("buzz") return end
        if self.market and self.market.listings then
          for i, x in ipairs(self.market.listings) do if x.id == l.id then table.remove(self.market.listings, i) break end end
        end
        App.pop()
      end)
    end, "END IT"))
  end
end

local function chart(points, x, y, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  if not points or #points == 0 then K.text(K.fonts.bitmore, "NO SALES YET", x + w / 2, y + h / 2 - 5, "center") return end
  if #points == 1 then
    K.text(K.fonts.bitmore, "1 SALE: " .. K.money(points[1].price or 0), x + w / 2, y + h / 2 - 5, "center")
    return
  end
  local lo, hi = 1e12, -1e12
  for _, p in ipairs(points) do local v = p.price or p[2] or 0; lo = min(lo, v); hi = max(hi, v) end
  if hi == lo then hi = lo + 1 end
  local lx, ly
  for i, p in ipairs(points) do
    local v = p.price or p[2] or 0
    local px = x + 4 + (i - 1) * (w - 8) / (#points - 1)
    local py = y + h - 12 - (v - lo) / (hi - lo) * (h - 20)
    if lx then gfx.drawLine(lx, ly, px, py) end
    gfx.fillRect(px - 1, py - 1, 2, 2)
    lx, ly = px, py
  end
  K.text(K.fonts.bitmore, K.money(lo), x + 3, y + h - 10)
  K.text(K.fonts.bitmore, "HI " .. K.money(hi), x + w - 3, y + 2, "right")
end

function I:update()
  self.t = self.t + 1 / 30
  UI.paper()
  header()
  local l = self.l
  local c = l.card or {}
  CR.front(c, "small"):draw(8, 28)
  if hot(l) then drawHot(80, 26, self.t) end
  -- details
  local px = 126
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(px, 26, 268, 196)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(px, 26, 268, 196)
  local r = CR.rarityOf(c)
  K.text(K.fonts.nb, K.fit(K.fonts.nb, string.upper((c.person and c.person.name or "?") .. " - " .. (CR.RARITY_LABEL[r] or "")) .. (c.serial and (" " .. c.serial) or ""), 258), px + 5, 29)
  K.text(K.fonts.bitmore, "ITEM #" .. tostring(l.id) .. "   SELLER: " .. string.upper(l.seller or "?") .. (l.hits and ("   " .. l.hits .. " VIEWS") or ""), px + 5, 43)
  local y = 56
  if isAuction(l) then
    local a = auc(l)
    K.text(K.fonts.bitmore, bidsOf(l) > 0 and "CURRENT BID" or "STARTING BID", px + 5, y)
    K.text(K.fonts.big, K.money(a.currentBid or l.price or 0), px + 5, y + 9)
    K.text(K.fonts.nb, bidsOf(l) .. " BIDS" .. (a.leader and ("  " .. string.upper(mask(a.leader))) or ""), px + 150, y + 4)
    local sl = secsLeft(l)
    K.text(K.fonts.nb, sl and (sl > 0 and (fmtLeft(sl) .. " LEFT") or "ENDED") or "LIVE AUCTION", px + 150, y + 18)
    if reserveNotMet(l) then
      gfx.fillRect(px + 5, y + 37, 108, 11)
      K.textW(K.fonts.bitmore, "RESERVE NOT MET", px + 59, y + 37, "center")
    elseif a.hasReserve then
      K.text(K.fonts.bitmore, "RESERVE MET", px + 5, y + 37)
    end
    if a.yourMax then K.text(K.fonts.bitmore, (a.leading and "WINNING - " or "OUTBID - ") .. "YOUR MAX " .. K.money(a.yourMax), px + 120, y + 37) end
  else
    K.text(K.fonts.bitmore, "FIXED PRICE", px + 5, y)
    K.text(K.fonts.big, K.money(l.price or 0), px + 5, y + 9)
    local sl = secsLeft(l)
    if sl then K.text(K.fonts.nb, fmtLeft(sl) .. " LEFT", px + 150, y + 10) end
  end
  local extra = {}
  if c.redeem and not c.redeemed then extra[#extra + 1] = (c.front and c.front.redeem) or c.redeem.label or "REDEEMABLE" end
  if c.finalSeason then extra[#extra + 1] = "FINAL SEASON" end
  if (l.watchers or 0) > 0 then extra[#extra + 1] = l.watchers .. " WATCHING" end
  K.text(K.fonts.bitmore, K.fit(K.fonts.bitmore, table.concat(extra, " - "), 258), px + 5, y + 50)
  -- actions
  local ay = 120
  for i, a in ipairs(self.actions) do
    local sel = i == self.sel
    local ry = ay + (i - 1) * 16
    if sel then gfx.setColor(gfx.kColorBlack); gfx.fillRect(px + 4, ry, 124, 15) end
    local label = K.fit(K.fonts.nb, a.label, 118)
    if sel then K.textW(K.fonts.nb, label, px + 8, ry + 1) else K.text(K.fonts.nb, label, px + 8, ry + 1) end
  end
  -- right lower: price chart or bid history
  local bx, by, bw, bh = px + 134, 118, 128, 100
  if self.showBids then
    gfx.setColor(gfx.kColorWhite); gfx.fillRect(bx, by, bw, bh)
    gfx.setColor(gfx.kColorBlack); gfx.drawRect(bx, by, bw, bh)
    K.text(K.fonts.bitmore, "BID HISTORY", bx + 4, by + 2)
    local list = self.bidList or {}
    if #list == 0 then K.text(K.fonts.bitmore, self.bidList and "NO BIDS YET" or "LOADING...", bx + bw / 2, by + 40, "center") end
    for i, b in ipairs(list) do
      if i > 7 then break end
      local yy = by + 14 + (i - 1) * 12
      K.text(K.fonts.bitmore, string.upper(mask(b.bidder or b.who)) .. (b.auto and " (AUTO)" or ""), bx + 4, yy)
      K.text(K.fonts.bitmore, K.money(b.amount or 0), bx + bw - 4, yy, "right")
    end
  else
    local st = self.stats
    K.text(K.fonts.bitmore, "PRICE HISTORY" .. (st and st.median and ("  MEDIAN " .. K.money(st.median)) or ""), bx + 2, by - 1)
    chart(self.history, bx, by + 10, bw, bh - 10)
  end
  if self.resultText then
    K.text(K.fonts.bitmore, K.fit(K.fonts.bitmore, self.resultText, 262), px + 5, 208)
  end
  UI.hints("UP/DN PICK   A DO IT   B BACK")
  UI.drawToast(self)
end

---------------------------------------------------------------------------
-- proxy bid picker (crank)

function Cards.bidPicker(l, onDone)
  local s = { opaque = false, acc = 0 }
  local lo = minBid(l)
  s.bid = lo
  local function step(n)
    s.bid = max(lo, s.bid + n)
    K.sfx("tick")
  end
  function s:cranked(change)
    self.acc = self.acc + change
    local unit = increment(self.bid) * (abs(change) > 15 and 5 or 1)
    while self.acc >= 12 do self.acc = self.acc - 12; step(unit) end
    while self.acc <= -12 do self.acc = self.acc + 12; step(-unit) end
  end
  function s:upButtonDown() step(increment(self.bid)) end
  function s:downButtonDown() step(-increment(self.bid)) end
  function s:rightButtonDown() step(increment(self.bid) * 10) end
  function s:leftButtonDown() step(-increment(self.bid) * 10) end
  function s:AButtonDown()
    App.pop()
    local who = l.card and l.card.person and l.card.person.name or "this card"
    App.push(UI.confirm("CONFIRM YOUR BID", "Max bid " .. K.money(self.bid) .. " on " .. who .. ". We bid for you, one step at a time, up to your max. If you win, you pay.", function() onDone(self.bid) end, "BID"))
  end
  function s:BButtonDown() App.pop(); onDone(nil) end
  function s:update()
    local x, y, w, h = 80, 46, 240, 150
    gfx.setColor(gfx.kColorBlack)
    gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
    gfx.fillRect(0, 0, 400, 240)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x + 4, y + 4, w, h)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x, y, w, h)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(2)
    gfx.drawRect(x, y, w, h)
    gfx.setLineWidth(1)
    gfx.fillRect(x, y, w, 18)
    K.textW(K.fonts.nb, "ENTER YOUR MAXIMUM BID", x + w / 2, y + 2, "center")
    local mine = auc(l).yourMax
    K.text(K.fonts.bitmore, "CURRENT " .. K.money(l.price or 0) .. "  -  MINIMUM " .. K.money(lo) .. (mine and ("  -  YOURS " .. K.money(mine)) or ""), x + w / 2, y + 24, "center")
    gfx.fillRect(x + 40, y + 40, w - 80, 36)
    K.textW(K.fonts.big, K.money(s.bid), x + w / 2, y + 45, "center")
    local a = (s.bid * 7) % 360
    local cx, cy = x + w - 22, y + 58
    gfx.drawCircleAtPoint(cx, cy, 10)
    gfx.drawLine(cx, cy, cx + math.cos(math.rad(a)) * 9, cy + math.sin(math.rad(a)) * 9)
    K.text(K.fonts.bitmore, "PROXY BIDDING: WE ONLY BID AS MUCH", x + w / 2, y + 84, "center")
    K.text(K.fonts.bitmore, "AS IT TAKES TO KEEP YOU ON TOP.", x + w / 2, y + 95, "center")
    local acct = UI.account()
    local esc = acct and acct.escrow
    K.text(K.fonts.bitmore, "YOUR MAX IS HELD IN ESCROW" .. ((esc and esc > 0) and (" (" .. K.money(esc) .. " HELD NOW)") or ""), x + w / 2, y + 108, "center")
    if buyNowOf(l) and s.bid >= buyNowOf(l) then K.text(K.fonts.bitmore, "(BUY IT NOW IS " .. K.money(buyNowOf(l)) .. ", JUST SAYING)", x + w / 2, y + 119, "center") end
    K.text(K.fonts.nb, "CRANK SETS IT   A BID   B CANCEL", x + w / 2, y + h - 18, "center")
  end
  return s
end

---------------------------------------------------------------------------
-- sell flow

local SL = { opaque = true }
Cards.sellScene = SL

local HOURS = { 1, 6, 12, 24, 48, 72 }

function SL:enter(args)
  self.card = args.card
  local v = max(1, self.card.value or 5)
  self.kind = "auction"
  self.start = max(1, floor(v * 0.5))
  self.price = v
  self.reserve = 0
  self.buyNow = 0
  self.dayIdx = 4
  self.sel = 1
  self.acc = 0
end

function SL:rows()
  if self.kind == "auction" then return { "kind", "start", "reserve", "buyNow", "days", "go" } end
  return { "kind", "price", "go" }
end

local function adjust(self, row, dir, big)
  local function bump(v, allowZero)
    local inc = increment(max(1, v)) * (big and 5 or 1)
    local nv = v + dir * inc
    if allowZero and nv < 1 then nv = 0 elseif nv < 1 then nv = 1 end
    return nv
  end
  if row == "kind" then self.kind = self.kind == "auction" and "fixed" or "auction"; self.sel = 1
  elseif row == "start" then self.start = bump(self.start)
  elseif row == "price" then self.price = bump(self.price)
  elseif row == "reserve" then self.reserve = bump(self.reserve, true)
  elseif row == "buyNow" then self.buyNow = bump(self.buyNow, true)
  elseif row == "days" then self.dayIdx = K.clamp(self.dayIdx + dir, 1, #HOURS) end
  K.sfx("tick")
end

function SL:upButtonDown() self.sel = (self.sel - 2) % #self:rows() + 1; K.sfx("tick") end
function SL:downButtonDown() self.sel = self.sel % #self:rows() + 1; K.sfx("tick") end
function SL:leftButtonDown() adjust(self, self:rows()[self.sel], -1) end
function SL:rightButtonDown() adjust(self, self:rows()[self.sel], 1) end
function SL:cranked(c)
  self.acc = self.acc + c
  local row = self:rows()[self.sel]
  local step = row == "days" and 45 or 12
  while self.acc >= step do self.acc = self.acc - step; adjust(self, row, 1, abs(c) > 15) end
  while self.acc <= -step do self.acc = self.acc + step; adjust(self, row, -1, abs(c) > 15) end
end
function SL:BButtonDown() App.pop() end

function SL:AButtonDown()
  local row = self:rows()[self.sel]
  if row == "kind" then adjust(self, row, 1) return end
  if row ~= "go" then self.sel = self.sel + 1; K.sfx("tick") return end
  local c = self.card
  local who = c.person and c.person.name or "this card"
  local hours = HOURS[self.dayIdx]
  local body, desc
  if self.kind == "auction" then
    if self.reserve > 0 and self.reserve <= self.start then UI.toast(self, "Reserve has to be above the starting bid.") K.sfx("buzz") return end
    if self.buyNow > 0 and (self.buyNow < self.start or (self.reserve > 0 and self.buyNow < self.reserve)) then UI.toast(self, "Buy It Now can't be under the start or reserve.") K.sfx("buzz") return end
    body = { cardId = c.id, kind = "auction", startBid = self.start, hours = hours }
    if self.reserve > 0 then body.reserve = self.reserve end
    if self.buyNow > 0 then body.buyNow = self.buyNow end
    desc = "Auction " .. who .. " for " .. hours .. " hours, bids start at " .. K.money(self.start) .. (self.reserve > 0 and (", hidden reserve " .. K.money(self.reserve)) or "") .. (self.buyNow > 0 and (", Buy It Now " .. K.money(self.buyNow)) or "") .. ". House takes 5% of the final price."
  else
    body = { cardId = c.id, price = self.price }
    desc = "Sell " .. who .. " for " .. K.money(self.price) .. " flat. House takes 5%."
  end
  App.push(UI.confirm("LIST IT?", desc, function()
    K.post("/market", body, function(err, d)
      if err or not d then UI.toast(self, UI.errText(err)); K.sfx("buzz") return end
      K.sfx("chime")
      App.pop("listed")
    end)
  end, "LIST"))
end

function SL:update()
  UI.paper()
  header("SELL YOUR ITEM")
  local c = self.card
  CR.front(c, "small"):draw(8, 30)
  local px = 126
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(px, 26, 268, 196)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(px, 26, 268, 196)
  K.text(K.fonts.nb, K.fit(K.fonts.nb, string.upper(c.person and c.person.name or "?"), 258), px + 5, 29)
  K.text(K.fonts.bitmore, "BOOK VALUE " .. K.money(c.value or 0), px + 5, 43)
  local labels = {
    kind = function() return "FORMAT", self.kind == "auction" and "AUCTION" or "FIXED PRICE" end,
    start = function() return "STARTING BID", K.money(self.start) end,
    price = function() return "PRICE", K.money(self.price) end,
    reserve = function() return "RESERVE (SECRET)", self.reserve > 0 and K.money(self.reserve) or "NONE" end,
    buyNow = function() return "BUY IT NOW", self.buyNow > 0 and K.money(self.buyNow) or "NONE" end,
    days = function() return "DURATION", HOURS[self.dayIdx] .. " HOURS" end,
    go = function() return "LIST IT ON " .. SITE, "" end,
  }
  for i, row in ipairs(self:rows()) do
    local y = 58 + (i - 1) * 24
    local sel = i == self.sel
    local l, v = labels[row]()
    if sel then gfx.setColor(gfx.kColorBlack); gfx.fillRect(px + 4, y, 260, 20) end
    if sel then K.textW(K.fonts.nb, l, px + 10, y + 3); K.textW(K.fonts.nb, v, px + 256, y + 3, "right")
    else K.text(K.fonts.nb, l, px + 10, y + 3); K.text(K.fonts.nb, v, px + 256, y + 3, "right") end
  end
  UI.hints("UP/DN FIELD   CRANK / < > CHANGE   A NEXT   B CANCEL")
  UI.drawToast(self)
end

---------------------------------------------------------------------------
-- offline/dev fallbacks (fixture mode only)

K.offlinePost["POST /market/.-/bid"] = function(path, body)
  local fx = K.readJson("fixtures/market-bid.json")
  if fx then return fx end
  return { leading = true, result = "You're the high bidder." }
end
K.offlinePost["POST /market/.-/watch"] = function() return { ok = true, watching = true } end
K.offlinePost["DELETE /market/.-/watch"] = function() return { ok = true, watching = false } end
K.offlinePost["POST /market/.-/buy"] = function(path)
  local id = path:match("/market/([^/]+)/buy")
  local fx = K.fixture("/market") or {}
  for _, l in ipairs(fx.listings or {}) do if l.id == id then return { card = l.card } end end
  return { card = {} }
end
K.offlinePost["POST /market$"] = function(path, body) return { listing = { id = "new", card = { id = body.cardId }, kind = body.kind or "fixed", price = body.startBid or body.price } } end
K.offlinePost["DELETE /market/"] = function() return { ok = true } end
