-- Event cards: modal decision cards with choices (crew trouble, offers, invites).
-- Sites.EventCard.show(eventView) pushes the card; pending cards show on login.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Card = {}
Card.__index = Card
Sites.EventCard = Card

function Card.show(ev)
  if not ev then return end
  local c = setmetatable({ ev = ev, opaque = false }, Card)
  App.push(c)
  return c
end

local X, Y, W, H = 30, 22, 340, 200

function Card:enter()
  self.t = 0
  self.sel = 1
  self.choices = self.ev.choices or {}
  local tx = X + 118
  local tw = W - 118 - 10
  self.titleLines = Text.wrap(self.ev.title or "", UI.fonts.serif, tw)
  self.bodyLines = Text.wrap(self.ev.body or "", UI.fonts.body, tw)
  local t = ((self.ev.title or "") .. " " .. (self.ev.body or "")):lower()
  if t:find("arrest") or t:find("lockup") or t:find("jail") or t:find("cuffed") or t:find("d%.a%.") then
    if Sfx.stinger("arrest") then
      if Audio and Audio.sfx then pcall(Audio.sfx, "police_whistle", 0.6) end
    else
      Sfx.mail()
    end
  else
    Sfx.mail()
  end
end

function Card:update(covered)
  self.t += 1
  Draw.dim(0.5)
  -- slide up into place
  local k = math.min(1, self.t / 7)
  if Game.settings.reduceMotion then k = 1 end
  local e = 1 - (1 - k) ^ 3
  local oy = math.floor((1 - e) * 120)
  local x, y = X, Y + oy
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 4, y + 4, W, H)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, W, H)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, W, H)
  gfx.drawRect(x + 2, y + 2, W - 4, H - 4)
  -- title bar
  gfx.fillRect(x + 2, y + 2, W - 4, 15)
  local kicker = "! CREW NEWS"
  local title = (self.ev.title or ""):lower()
  if title:find("offer") or (self.ev.body or ""):find("syndicate") then kicker = "! AN OFFER" elseif title:find("bobby") then kicker = "! A WORD" end
  Text.draw(kicker, x + 7, y + 3, UI.fonts.bold, "white")
  local c = Game.clock
  local exp = self.ev.expiresAt and (self.ev.expiresAt - Api.now()) or nil
  local right = exp and ("decide within " .. Fmt.dur(exp)) or (c and ("Day " .. c.day) or "")
  Text.draw(right, x + W - 8, y + 3, UI.fonts.body, "white", "right")
  -- face column
  local fx, fy = x + 10, y + 24
  if self.ev.photo and Archive.get(self.ev.photo, 96) then
    Archive.draw(self.ev.photo, fx, fy, 96)
    gfx.drawRect(fx - 3, fy - 3, 102, 78)
    if self.ev.photoCaption then Text.block(self.ev.photoCaption, fx, fy + 78, 96, UI.fonts.body, nil, 5) end
  else
    Faces.draw(self.ev.face, fx, fy, 96, { double = true })
  end
  -- text column
  local tx = x + 118
  local ty = y + 22
  for i, l in ipairs(self.titleLines) do
    if i > 2 then break end
    Text.draw(l, tx, ty, UI.fonts.serif)
    ty += 19
  end
  ty += 2
  local lh = UI.fonts.body:getHeight() + 1
  local maxBodyLines = math.max(2, math.floor((y + H - 10 - #self.choices * 19 - ty) / lh))
  for i, l in ipairs(self.bodyLines) do
    if i > maxBodyLines then break end
    local s = l
    if i == maxBodyLines and #self.bodyLines > maxBodyLines then s = Text.ellipsize(l .. " \u{2026}", UI.fonts.body, W - 128) end
    Text.draw(s, tx, ty, UI.fonts.body)
    ty += lh
  end
  -- choices
  local cy = y + H - 8 - #self.choices * 19
  for i, ch in ipairs(self.choices) do
    local sel = i == self.sel
    local cx, cw = tx - 4, W - 118 - 2
    if sel then
      gfx.fillRect(cx, cy, cw, 17)
    else
      gfx.drawRect(cx, cy, cw, 17)
    end
    local col = sel and "white" or nil
    local label = string.char(64 + i) .. ") " .. ch.label
    local note = ch.cost and Fmt.money(ch.cost) or ch.note or ""
    local nw = UI.fonts.body:getTextWidth(note)
    Text.draw(Text.ellipsize(label, UI.fonts.bold, cw - nw - 16), cx + 5, cy + 2, UI.fonts.bold, col)
    Text.draw(note, cx + cw - 5, cy + 2, UI.fonts.body, col, "right")
    cy += 19
  end
  if self.pressT then
    self.pressT -= 1
    if self.pressT <= 0 then self.pressT = nil self:choose() end
  end
end

function Card:move(d)
  local n = #self.choices
  local s = math.max(1, math.min(n, self.sel + d))
  if s ~= self.sel then self.sel = s Sfx.focus() else Sfx.detent() end
end

function Card:upButtonDown() self:move(-1) end
function Card:downButtonDown() self:move(1) end
function Card:cranked(change)
  self.acc = (self.acc or 0) + change
  if math.abs(self.acc) > 30 then self:move(self.acc > 0 and 1 or -1) self.acc = 0 end
end
function Card:BButtonDown()
  -- decisions can wait: B closes the card without choosing
  Sfx.back()
  App.pop()
  Toast.show("It'll keep. For a while.", nil)
end
function Card:AButtonDown()
  if self.t < 6 or self.pressT or #self.choices == 0 then return end
  Sfx.select()
  self.pressT = 3
end

function Card:choose()
  local ch = self.choices[self.sel]
  if not ch then return end
  Busy.post("/events/" .. self.ev.id .. "/choose", { key = ch.key }, "Making the call", function(d)
    if App.top() == self then App.pop() end
    -- drop it from the pending list
    local rest = {}
    for _, e in ipairs(Nav.pendingEvents or {}) do if e.id ~= self.ev.id then rest[#rest + 1] = e end end
    Nav.pendingEvents = rest
    if Sites.Desktop.instance then Sites.Desktop.instance.dirty = true end
    Api.invalidate("")
    Dialog.show({ title = "What happened", body = d.result or "Done.", buttons = { #rest > 0 and "Next" or "OK" }, cancel = 1, face = self.ev.face,
      onChoose = function()
        if #rest > 0 then Card.show(rest[1]) end
      end })
  end)
end
