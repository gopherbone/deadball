-- "While You Were Out": the payoff moment. After boot (and when the day turns over on the
-- desktop), if anything settled since the last visit, one dialog sums it up from
-- GET /digest: bets, props, jobs, cards, an arrest mugshot, and the NET.
--   A  "Cash it!": the status bar's money rolls up with a ka-ching and a coin burst
--      (a net loss gets Bobby's deadpan stamp and a sad trombone instead)
--   >  details: My Tickets at Bobby's
--   B  later: shown again next time
-- The last visit is remembered per account (datastore "wywo": the digest's day + cursor), so
-- each haul is shown once.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Digest = {}
Digest.__index = Digest
Sites.Digest = Digest

local W <const>, H <const> = 368, 206
local X <const>, Y <const> = 16, 18

-- Remembering the last visit ----------------------------------------------------------------

local function store()
  local s = playdate.datastore.read("wywo")
  return type(s) == "table" and s or {}
end

local function key() return Api.token or "fixtures" end

function Digest.seen()
  return store()[key()]
end

function Digest.markSeen(d)
  local s = store()
  s[key()] = { day = d.day, cursor = d.cursor }
  playdate.datastore.write(s, "wywo")
end

--- The path to ask for (the boot batch asks for exactly this, so the dialog reads it from cache).
function Digest.path()
  local st = Digest.seen()
  if st and st.day then
    return "/digest?sinceDay=" .. math.floor(st.day) .. (st.cursor and ("&since=" .. st.cursor) or "")
  end
  -- never seen one on this device: the last week (the server caps it)
  return "/digest?sinceDay=0"
end

--- Fetches the digest and shows it if anything happened. cb() runs when the player is done
--- (or right away when there's nothing). Returns true (the flow is asynchronous).
function Digest.maybeShow(cb)
  local host = App.top()
  local path = Digest.path()
  Api.get(path, function(err, d)
    if err or type(d) ~= "table" or App.top() ~= host then
      if cb then cb() end
      return
    end
    Game.absorb(d)
    if d.empty then
      Digest.markSeen(d)
      if cb then cb() end
      return
    end
    Digest.show(d, cb)
  end)
  return true
end

function Digest.show(d, cb)
  local s = setmetatable({ d = d, cb = cb, opaque = false }, Digest)
  App.push(s)
  return s
end

-- Content ------------------------------------------------------------------------------------

local function signed(n)
  n = n or 0
  if n > 0 then return "+" .. Fmt.money(n) end
  if n < 0 then return "-" .. Fmt.money(-n) end
  return "$0"
end

local JOB_WORD <const> = { done = "PULLED OFF", blown = "BLOWN", cancelled = "CALLED OFF" }

--- Rows: { label, text, money }.
local function rows(d)
  local out = {}
  local b = d.bets or {}
  if (b.won or 0) + (b.lost or 0) > 0 then
    out[#out + 1] = { "BETS", (b.won or 0) .. " won, " .. (b.lost or 0) .. " lost", signed(b.net) }
  end
  local p = d.props or {}
  for i, it in ipairs(p.items or {}) do
    if i > 2 then break end
    local q = it.question or ""
    local ans = it.refunded and "REFUNDED" or (it.outcome and it.outcome:upper()) or (it.pick or "")
    out[#out + 1] = { i == 1 and "PROPS" or "", "\"" .. q .. "\" " .. ans, signed(it.net) }
  end
  local jobs = d.jobs or {}
  local cost = 0
  for _, j in ipairs(jobs) do cost += j.cost or 0 end
  for i, j in ipairs(jobs) do
    if i > 3 then break end
    out[#out + 1] = { i == 1 and "JOBS" or "", j.name .. " " .. (j.where or "") .. ": " .. (JOB_WORD[j.status] or j.status:upper()),
      (i == math.min(3, #jobs) and cost > 0) and signed(-cost) or "" }
  end
  local c = d.cards or {}
  local parts = {}
  if (c.won or 0) > 0 then parts[#parts + 1] = "won " .. c.won .. " auction" .. (c.won > 1 and "s" or "") end
  if (c.sold or 0) > 0 then parts[#parts + 1] = "sold " .. c.sold end
  if (c.outbid or 0) > 0 then parts[#parts + 1] = "outbid " .. c.outbid .. "x" end
  if #parts > 0 then out[#out + 1] = { "CARDS", table.concat(parts, ", "), (c.soldFor or 0) > 0 and signed(c.soldFor) or "" } end
  return out
end

local function caseNo(name)
  local h = 0
  for i = 1, #name do h = (h * 31 + name:byte(i)) % 9000 end
  local yr = ((Game.clock and Game.clock.year) or 1996) % 100
  return string.format("#%02d-%04d", yr, 1000 + h)
end

--- Paints the static window once (texts never re-wrap per frame).
function Digest:paint()
  local d = self.d
  local img = gfx.image.new(W + 4, H + 4, gfx.kColorClear)
  gfx.pushContext(img)
  local ix, iy, iw, ih = Draw.window(0, 0, W, H, "While You Were Out")
  local name = (Game.account and Game.account.name) or "Pal"
  local y = iy + 3
  Text.draw(Text.ellipsize(name .. ", here's the damage:", UI.fonts.bold, iw - 110), ix + 6, y, UI.fonts.bold)
  local span = (d.sinceDay and d.sinceDay > 0 and d.sinceDay ~= d.day) and ("Day " .. d.sinceDay .. " \u{25b6} Day " .. (d.day or "?")) or ("Day " .. (d.day or "?"))
  Text.draw(span, ix + iw - 6, y, UI.fonts.body, nil, "right")
  y += 15
  Draw.hr(ix + 4, y, iw - 8)
  y += 4
  local list = rows(d)
  local arrested = d.arrests and d.arrests[1]
  local maxRows = arrested and 5 or 7
  for i, r in ipairs(list) do
    if i > maxRows then break end
    Text.draw(r[1], ix + 6, y, UI.fonts.bold)
    local mw = UI.fonts.bold:getTextWidth(r[3])
    Text.draw(Text.ellipsize(r[2], UI.fonts.body, iw - 70 - mw - 10), ix + 58, y, UI.fonts.body)
    if r[3] ~= "" then Text.draw(r[3], ix + iw - 6, y, UI.fonts.bold, nil, "right") end
    y += 14
  end
  -- bottom band: the mugshot (left) and NET (right)
  local by = iy + ih - 24 - (arrested and 64 or 48)
  if arrested then
    Faces.draw(arrested.face, ix + 7, by + 2, 48)
    local tx = ix + 62
    Text.draw("ARRESTED", tx, by + 1, UI.fonts.head)
    Text.draw(Text.ellipsize(arrested.name .. ", case " .. caseNo(arrested.name), UI.fonts.body, 170), tx, by + 17, UI.fonts.body)
    Text.draw(#d.arrests > 1 and ("and " .. (#d.arrests - 1) .. " more. Bail hearings tomorrow.") or "Bail hearing tomorrow.", tx, by + 31, UI.fonts.body)
    Text.draw("Heat's up.", tx, by + 45, UI.fonts.body)
  elseif (d.net or 0) >= 0 then
    Text.draw("Bobby pays in cash.", ix + 8, by + 18, UI.fonts.body)
  end
  -- NET box
  local nw, nh = 128, 44
  local nx, ny = ix + iw - nw - 6, by + (arrested and 12 or 2)
  self.netX, self.netY, self.netW, self.netH = X + nx, Y + ny, nw, nh
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(nx, ny, nw, nh)
  Text.draw("NET", nx + nw // 2, ny + 3, UI.fonts.bold, "white", "center")
  Text.draw(signed(d.net), nx + nw // 2, ny + 17, UI.fonts.big, "white", "center")
  -- buttons
  local bty = iy + ih - 21
  local labels = { "A: Cash it!", "\u{25b6} details", "B: later" }
  if (d.net or 0) < 0 then labels[1] = "A: Ouch." end
  local bw = (iw - 32) // 3
  self.btnY = Y + bty
  for i, l in ipairs(labels) do
    Draw.button(ix + 8 + (i - 1) * (bw + 8), bty, bw, 18, l, nil)
  end
  gfx.popContext()
  self.img = img
end

--- Bobby's deadpan stamp for a net loss (pre-rendered, tilted).
local function stampImage()
  local f = UI.fonts.bold
  local lines = { "BOBBY THANKS YOU", "FOR YOUR", "CONTRIBUTION" }
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, f:getTextWidth(l)) end
  local img = gfx.image.new(w + 16, #lines * 14 + 12, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(2, 2, w + 12, #lines * 14 + 8)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRect(2, 2, w + 12, #lines * 14 + 8)
  gfx.setLineWidth(1)
  for i, l in ipairs(lines) do Text.draw(l, (w + 16) // 2, 6 + (i - 1) * 14, f, nil, "center") end
  gfx.popContext()
  return img:rotatedImage(-9)
end

-- Scene --------------------------------------------------------------------------------------

function Digest:enter()
  self.t = 0
  self.state = "show"
  self:paint()
  self.loss = (self.d.net or 0) < 0
  -- the bar shows the money from before the haul; "Cash it!" rolls it up
  if not self.loss and (self.d.net or 0) > 0 and Game.account then
    Game.moneyHold = true
    Game.displayMoney = (Game.account.money or 0) - self.d.net
  end
  if self.loss then self.stamp = stampImage() end
  Sfx.mail()
end

function Digest:close(how)
  Game.moneyHold = false
  if how ~= "later" then
    Digest.markSeen(self.d)
    -- the status bar's ▲/▼ counts from before the haul
    if Game.account then Game.baseMoney = (Game.account.money or 0) - (self.d.net or 0) end
  end
  if App.top() == self then App.pop() end
  if how == "details" then Sites.Bets.open({ tickets = true }) end
  if self.cb then self.cb() end
end

function Digest:cashIt()
  if self.loss then
    Sfx.trombone()
    self.state = "ouch"
    self.t = 0
    return
  end
  self.state = "cash"
  self.t = 0
  Game.moneyHold = false
  Sfx.kaching()
  -- the coin burst: up to 20 coins from the NET box to the money in the status bar
  local n = math.max(6, math.min(20, (self.d.net or 0) // 25))
  self.coins = {}
  for i = 1, n do
    self.coins[i] = { x = self.netX + math.random(10, self.netW - 10), y = self.netY + math.random(4, self.netH - 4),
      delay = (i - 1) * 2, up = math.random(20, 50) }
  end
end

function Digest:AButtonDown()
  if self.t < 6 then return end
  if self.state == "show" then self:cashIt()
  elseif self.state == "cash" or self.state == "ouch" then self:close("cash") end
end
function Digest:rightButtonDown() if self.state == "show" then Sfx.select() self:close("details") end end
function Digest:BButtonDown() if self.state == "show" then Sfx.back() self:close("later") end end

local TX <const>, TY <const> = 362, 8   -- the money in the status bar

function Digest:update()
  self.t += 1
  Draw.dim(0.5)
  local k = Game.settings.reduceMotion and 1 or math.min(1, self.t / 6)
  local e = 1 - (1 - k) ^ 3
  local oy = math.floor((1 - e) * 140)
  self.img:draw(X, Y + oy)
  if k < 1 then return end
  -- the loss stamp thunks onto the NET box
  if self.loss and self.stamp then
    if self.t == 12 then Sfx.stamp() end
    if self.t >= 12 then
      local sw, sh = self.stamp:getSize()
      self.stamp:draw(self.netX - sw + 26, self.netY - 22)
    end
  end
  if self.state == "cash" then
    local done = true
    for _, c in ipairs(self.coins) do
      local t = (self.t - c.delay) / 22
      if t < 1 then
        done = false
        if t > 0 then
          local x = c.x + (TX - c.x) * t
          local y = c.y + (TY - c.y) * t - math.sin(t * math.pi) * c.up
          gfx.setColor(gfx.kColorWhite)
          gfx.fillCircleAtPoint(x, y, 5)
          gfx.setColor(gfx.kColorBlack)
          gfx.drawCircleAtPoint(x, y, 5)
          gfx.fillRect(x - 1, y - 2, 2, 4)
        end
      end
    end
    if self.t % 12 == 0 and self.t < 40 then Sfx.coin() end
    -- keep the bar on top so the roll-up shows above the dim
    Chrome.menubar()
    if done and Game.displayMoney == (Game.account and Game.account.money) and self.t > 30 then
      self:close("cash")
    end
  elseif self.state == "ouch" then
    if self.t > 45 then self:close("cash") end
  end
end
