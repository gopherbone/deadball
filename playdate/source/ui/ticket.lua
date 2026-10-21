--[[ The betting ticket: one carbon-copy slip for game bets and prop bets alike.
  Ticket.open{
    title = function(side) -> "FRIARS to beat LAMPLIGHTERS",   -- the headline for a side
    sub = "Day 41 • Bellwood Park • 59F, wind out to RF",
    sides = { { key = "away", label = "Friars", pays = 2.25 }, ... },  -- up/down flips between them
    side = "away" | nil,            -- nil: the first up/down picks one (nobody bets HOME by accident)
    min = 5, max = 620, amount = 50,
    estimate = function(amount, key) -> win, mult     -- the live payout line (pools still move)
    closes = function() -> "first pitch, 4:12"         -- optional
    place = function(amount, key, done) ... done(ok) end,
    after = { next = "ELC @ MRL", onNext = fn, onRig = fn } | function(key) -> that table,
    page = the page underneath (its requireFresh guards money while it shows a saved copy)
  }
  Crank: fine steps. Left/right: the quick chips ($10 $25 $50 $100 MAX). Up/down: the side.
  A places it: no confirm dialog (the ticket is the confirmation; B always backs out). Over a
  quarter of the bankroll, A has to be held for half a second. Then a rubber stamp. ]]

local gfx <const> = playdate.graphics

Ticket = Ticket or {}
Ticket.__index = Ticket
Ticket.lastAmount = nil   -- remembered for the session

local X <const>, Y <const>, W <const>, H <const> = 46, 22, 308, 196
local CHIPS <const> = { 10, 25, 50, 100 }
local HOLD_FRAMES <const> = 15

function Ticket.open(opts)
  local t = setmetatable({ o = opts, opaque = false }, Ticket)
  App.push(t)
  return t
end

local function step(a)
  if a < 50 then return 5 elseif a < 200 then return 10 elseif a < 1000 then return 25 else return 100 end
end

function Ticket:enter()
  local o = self.o
  self.min = o.min or 5
  self.max = math.max(self.min, o.max or self.min)
  self.amount = math.max(self.min, math.min(self.max, o.amount or Ticket.lastAmount or 25))
  self.shown = self.amount
  self.side = o.side
  self.acc = 0
  self.t = 0
  self.bounce = 0
  self.no = 4000 + ((Game.frame or 0) * 37) % 6000
  self.state = "edit"
  Sfx.select()
end

function Ticket:sideIndex()
  for i, s in ipairs(self.o.sides or {}) do if s.key == self.side then return i end end
  return nil
end

function Ticket:setAmount(a, sound)
  a = math.max(self.min, math.min(self.max, a))
  if a ~= self.amount then
    self.amount = a
    if sound ~= false then Sfx.detent() end
  else
    self.bounce = 5
    Sfx.error()
  end
end

--- Quick chips: the next stop above (d = 1) or below (d = -1) the amount.
function Ticket:chip(d)
  local stops = {}
  for _, c in ipairs(CHIPS) do if c > self.min and c < self.max then stops[#stops + 1] = c end end
  stops[#stops + 1] = self.max
  table.insert(stops, 1, self.min)
  local target = nil
  if d > 0 then
    for _, c in ipairs(stops) do if c > self.amount then target = c break end end
  else
    for i = #stops, 1, -1 do if stops[i] < self.amount then target = stops[i] break end end
  end
  if target then self:setAmount(target) else self.bounce = 5 Sfx.detent() end
end

function Ticket:flip(d)
  local sides = self.o.sides or {}
  if #sides == 0 then return end
  local i = self:sideIndex()
  if not i then i = d > 0 and 1 or #sides else i = (i - 1 + d) % #sides + 1 end
  if #sides == 1 then i = 1 end
  self.side = sides[i].key
  Sfx.focus()
end

-- Input -------------------------------------------------------------------------------------

function Ticket:cranked(change)
  if self.state ~= "edit" then return end
  self.acc += change
  while self.acc >= 15 do self.acc -= 15 self:setAmount(self.amount + step(self.amount)) end
  while self.acc <= -15 do self.acc += 15 self:setAmount(self.amount - step(self.amount - 1)) end
end

function Ticket:leftButtonDown() if self.state == "edit" then self:chip(-1) end end
function Ticket:rightButtonDown() if self.state == "edit" then self:chip(1) end end
function Ticket:upButtonDown() if self.state == "edit" then self:flip(-1) end end
function Ticket:downButtonDown()
  if self.state == "edit" then self:flip(1)
  elseif self.state == "placed" and self.after and self.after.onRig then
    local f = self.after.onRig
    Sfx.select()
    App.pop("placed")
    f()
  end
end

function Ticket:BButtonDown()
  if self.state == "busy" then return end
  Sfx.back()
  App.pop(self.state == "placed" and "placed" or nil)
end

function Ticket:needsHold()
  local m = (Game.account and Game.account.money) or 0
  return self.amount > m * 0.25
end

function Ticket:AButtonDown()
  if self.t < 4 then return end
  if self.state == "placed" then
    local f = self.after and self.after.onNext
    Sfx.select()
    App.pop("placed")
    if f then f() end
    return
  end
  if self.state ~= "edit" then return end
  if not self.side then
    Sfx.error()
    self.nudge = 20
    return
  end
  if self:needsHold() then
    self.holdT = 0
    return
  end
  self:place()
end

function Ticket:AButtonUp()
  if self.holdT and self.holdT < HOLD_FRAMES then Sfx.detent() end
  self.holdT = nil
end

function Ticket:place()
  local page = self.o.page
  if page and page.requireFresh and not page:requireFresh() then return end
  self.state = "busy"
  Ticket.lastAmount = self.amount
  self.o.place(self.amount, self.side, function(ok)
    if not ok then self.state = "edit" return end
    self.state = "placed"
    self.stampT = 0
    Sfx.stamp()
    Sfx.coin()
    local a = self.o.after
    if type(a) == "function" then a = a(self.side) end
    self.after = a
  end)
end

-- Drawing ----------------------------------------------------------------------------------

local stampImg = nil
local stampGrow = {}   -- grow (px) -> the stamp prescaled for that slam step
local function stamp()
  if stampImg then return stampImg end
  local f = UI.fonts.big
  local tw = f:getTextWidth("BET PLACED!")
  local img = gfx.image.new(tw + 30, 50, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(2, 2, tw + 26, 46)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(3)
  gfx.drawRect(3, 3, tw + 24, 44)
  gfx.setLineWidth(1)
  gfx.drawRect(7, 7, tw + 16, 36)
  Text.draw("BET PLACED!", (tw + 30) // 2, 12, f, nil, "center")
  gfx.popContext()
  stampImg = img:rotatedImage(-7)
  return stampImg
end

--- The ticket's face (everything but the dim and the stamp), in screen coordinates.
function Ticket:drawFace(closesText)
  local o = self.o
  -- the ticket: white paper, a perforated top, the counterfoil number
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(X + 4, Y + 4, W, H)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(X, Y, W, H)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(X, Y, W, H)
  gfx.drawRect(X + 2, Y + 2, W - 4, H - 4)
  Text.draw("BETS BY BOBBY", X + 8, Y + 5, UI.fonts.bold)
  Text.draw("TICKET No. 00" .. self.no, X + W - 8, Y + 5, UI.fonts.body, nil, "right")
  Draw.dotted(X + 4, X + W - 5, Y + 19)
  local cx = X + W // 2
  local cy = Y + 24
  -- headline for the chosen side (or the choice to make)
  local title
  if self.side then title = o.title(self.side) else
    local names = {}
    for _, s in ipairs(o.sides or {}) do names[#names + 1] = s.label end
    title = "PICK: " .. table.concat(names, " / ")
  end
  local tl = Text.wrap(title, UI.fonts.head, W - 24)
  for i = 1, math.min(2, #tl) do
    local dx = (not self.side and self.nudge and self.nudge > 0) and ((self.nudge % 4 < 2) and 2 or -2) or 0
    Text.draw(tl[i], cx + dx, cy, UI.fonts.head, nil, "center")
    cy += 15
  end
  Text.draw(Text.ellipsize(o.sub or "", UI.fonts.body, W - 20), cx, cy, UI.fonts.body, nil, "center")
  cy += 16
  -- the side toggle hint (up/down)
  local si = self:sideIndex()
  if #(o.sides or {}) > 1 then
    local sx = X + 10
    for i, s in ipairs(o.sides) do
      local lbl = s.label .. (s.pays and s.pays > 0 and (" " .. Fmt.pays(s.pays) .. "x") or "")
      local w = UI.fonts.body:getTextWidth(lbl) + 10
      if sx + w > X + W - 10 then break end
      local ty = Text.boxY(UI.fonts.body, cy + 1, 11, lbl)
      if i == si then gfx.fillRect(sx, cy, w, 13) Text.draw(lbl, sx + 5, ty, UI.fonts.body, "white")
      else gfx.drawRect(sx, cy, w, 13) Text.draw(lbl, sx + 5, ty, UI.fonts.body) end
      sx += w + 4
    end
    Text.draw("\u{25b2}\u{25bc}", X + W - 10, cy, UI.fonts.body, nil, "right")
    cy += 17
  end
  -- the amount, big
  local ax = cx + ((self.bounce > 0) and ((self.bounce % 2) * 4 - 2) or 0)
  Text.draw("\u{25c0}", cx - 70, cy + 6, UI.fonts.bold)
  Text.draw("\u{25b6}", cx + 62, cy + 6, UI.fonts.bold)
  Text.draw(Fmt.money(math.floor(self.shown + 0.5)), ax, cy, UI.fonts.big, nil, "center")
  local dx, dy = X + W - 26, cy + 11
  gfx.drawCircleAtPoint(dx, dy, 8)
  local ang = math.rad(playdate.getCrankPosition() - 90)
  gfx.drawLine(dx, dy, dx + math.floor(math.cos(ang) * 7), dy + math.floor(math.sin(ang) * 7))
  cy += 27
  -- quick chips
  local chips = {}
  for _, c in ipairs(CHIPS) do if c <= self.max then chips[#chips + 1] = { c, "$" .. c } end end
  chips[#chips + 1] = { self.max, "MAX " .. Fmt.money(self.max) }
  local total = 0
  for _, ch in ipairs(chips) do ch.w = UI.fonts.bold:getTextWidth(ch[2]) + 8 total += ch.w + 4 end
  local kx = cx - total // 2
  for _, ch in ipairs(chips) do
    if ch[1] == self.amount then
      gfx.fillRoundRect(kx, cy, ch.w, 14, 3)
      Text.draw(ch[2], kx + 4, Text.boxY(UI.fonts.bold, cy + 1, 12), UI.fonts.bold, "white")
    else
      gfx.drawRoundRect(kx, cy, ch.w, 14, 3)
      Text.draw(ch[2], kx + 4, Text.boxY(UI.fonts.bold, cy + 1, 12), UI.fonts.bold)
    end
    kx += ch.w + 4
  end
  cy += 19
  -- the live line
  if self.side then
    -- the live line only changes with the amount or the side
    if self.lineAmt ~= self.amount or self.lineSide ~= self.side then
      self.lineAmt, self.lineSide = self.amount, self.side
      local win, mult = o.estimate(self.amount, self.side)
      local s = o.sides[si]
      local who = s and s.label or ""
      local line = (mult and mult < 1) and ("Returns ~" .. Fmt.money(win) .. ": nobody on the other side yet")
        or ("Pays ~" .. Fmt.money(win) .. " if " .. (o.winWord and o.winWord(self.side) or who) .. (mult and (" (" .. string.format("%.2f", mult) .. "x)") or ""))
      self.line = Text.ellipsize(line, UI.fonts.bold, W - 16)
    end
    Text.draw(self.line, cx, cy, UI.fonts.bold, nil, "center")
  else
    Text.draw("\u{25b2}\u{25bc} pick a side first", cx, cy, UI.fonts.bold, nil, "center")
  end
  cy += 14
  local closes = closesText
  Text.draw(Text.ellipsize("Pools still move" .. (closes and (" until " .. closes) or "") .. ". Min " .. Fmt.money(self.min) .. ", max " .. Fmt.money(self.max) .. ".", UI.fonts.body, W - 16), cx, cy, UI.fonts.body, nil, "center")
  -- footer: the verbs
  local fy = Y + H - 20
  Draw.dotted(X + 4, X + W - 5, fy - 4)
  if self.state == "placed" then
    local a = self.after or {}
    Text.draw("A: " .. (a.next and "next game" or "done") .. (a.onRig and "     \u{25bc}: rig this one" or ""), cx, fy, UI.fonts.bold, nil, "center")
  elseif self.state == "busy" then
    Text.draw("Calling Bobby" .. string.rep(".", (self.t // 6) % 4), cx, fy, UI.fonts.bold, nil, "center")
  else
    local hold = self:needsHold()
    Text.draw(hold and "HOLD A: PLACE IT        B: nah" or "A: PLACE IT        B: nah", cx, fy, UI.fonts.bold, nil, "center")
    if self.holdT then
      gfx.fillRect(X + 20, fy + 14, math.floor((W - 40) * self.holdT / HOLD_FRAMES), 3)
    end
  end
end

function Ticket:update(covered)
  self.t += 1
  if self.bounce > 0 then self.bounce -= 1 end
  if self.nudge and self.nudge > 0 then self.nudge -= 1 end
  if self.holdT and not covered then
    if playdate.buttonIsPressed(playdate.kButtonA) then
      self.holdT += 1
      if self.holdT >= HOLD_FRAMES then self.holdT = nil self:place() end
    else
      self.holdT = nil
    end
  end
  self.shown += (self.amount - self.shown) * 0.5
  if math.abs(self.amount - self.shown) < 0.5 then self.shown = self.amount end
  Draw.dim(0.5)
  -- The ticket's face is cached as an image and only repainted when something on it changes
  -- (redrawing ~30 text runs every frame cost the device 30+ ms; a blit is ~1 ms).
  local o = self.o
  local closes = o.closes and o.closes() or nil
  local crank = math.floor(playdate.getCrankPosition() / 15)
  local busyDots = self.state == "busy" and ((self.t // 6) % 4) or 0
  local key = table.concat({ tostring(self.side), self.amount, math.floor(self.shown + 0.5), self.state, tostring(self.holdT),
    (self.nudge or 0) > 0 and (self.nudge % 4 < 2 and 1 or 2) or 0, self.bounce > 0 and (self.bounce % 2) + 1 or 0, crank, busyDots,
    tostring(closes), tostring(self.after and self.after.next) }, "|")
  if key ~= self.faceKey or not self.faceImg then
    self.faceKey = key
    self.faceImg = self.faceImg or gfx.image.new(W + 5, H + 5, gfx.kColorClear)
    self.faceImg:clear(gfx.kColorClear)
    gfx.pushContext(self.faceImg)
    gfx.setDrawOffset(-X, -Y)
    self:drawFace(closes)
    gfx.setDrawOffset(0, 0)
    gfx.popContext()
  end
  self.faceImg:draw(X, Y)
  local cx = X + W // 2
  -- the stamp
  if self.state == "placed" then
    self.stampT += 1
    local img = stamp()
    local sw, sh = img:getSize()
    local grow = math.max(0, 4 - self.stampT) * 6
    if grow > 0 then
      -- the slam's scaled steps are made once (scaledImage), never scaled per frame
      local big = stampGrow[grow]
      if not big then big = img:scaledImage(1 + grow / sw * 2) stampGrow[grow] = big end
      big:draw(cx - sw // 2 - grow, Y + 70 - sh // 2 - grow)
    else
      -- landed: the stamp and its "next up" tag, painted once
      if not self.landedImg then
        local a = self.after
        local nt = a and a.next and ("next up: " .. a.next .. " \u{25b6}") or nil
        local nw = nt and (UI.fonts.bold:getTextWidth(nt) + 10) or 0
        local lw = math.max(sw, nw)
        local li = gfx.image.new(lw, sh + 12, gfx.kColorClear)
        gfx.pushContext(li)
        img:draw((lw - sw) // 2, 0)
        if nt then
          local tx = (lw - nw) // 2
          gfx.setColor(gfx.kColorWhite)
          gfx.fillRect(tx, sh - 6, nw, 15)
          gfx.setColor(gfx.kColorBlack)
          gfx.drawRect(tx, sh - 6, nw, 15)
          Text.draw(nt, lw // 2, Text.boxY(UI.fonts.bold, sh - 5, 13, nt), UI.fonts.bold, nil, "center")
        end
        gfx.popContext()
        self.landedImg, self.landedW = li, lw
      end
      self.landedImg:draw(cx - self.landedW // 2, Y + 70 - sh // 2)
    end
  end
  Chrome.menubar()
end
