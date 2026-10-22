-- Rest the tired: the swap list (pennant/rest.lua). Each tired regular -> the suggested cover with
-- the rating change; A on a row ticks it on / off (the worthwhile ones start ticked). SWAP ALL makes
-- the ticked swaps on today's card. Opened from the Week screen's TIRED chip, the pregame card's
-- REST TIRED button and the Lineup screen.

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

local Rest = PUI.define({ title = "Rest the tired", hint = "A: tick / untick  SWAP ALL makes the ticked swaps" })
PennantUI.RestTired = Rest

--- args.onDone(n): after a swap (n rested) or a cancel (0).
function Rest:init(args)
  self.onDone = args and args.onDone
  self.rows = PRest.plan(Pennant.L)
end

local function check(x, y, on)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, 11, 11)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, 11, 11)
  if on then
    gfx.setLineWidth(2)
    gfx.drawLine(x + 2, y + 5, x + 4, y + 8)
    gfx.drawLine(x + 4, y + 8, x + 9, y + 2)
    gfx.setLineWidth(1)
  end
end

local function signed(d) return (d < 0 and "-" or "+") .. math.abs(d) end

function Rest:ticked()
  local n = 0
  for _, r in ipairs(self.rows) do if r.on and (r.sub or r.k == "pen") then n = n + 1 end end
  return n
end

function Rest:finish(n)
  App.pop()
  if self.onDone then self.onDone(n) end
end

function Rest:swap()
  local L = Pennant.L
  local n = PRest.apply(L, self.rows, L.settings.restMode or "fresh")
  -- (the C engine's roster encoding for today is cached)
  if PEng and PEng.invalidate then PEng.invalidate() end
  if n > 0 then
    Sfx.coin()
    Toast.show("Rested " .. n .. ((L.settings.restMode == "today") and ": back tomorrow." or ": back when fresh."), "good")
  else
    Sfx.back()
  end
  self:finish(n)
end

function Rest:layout(Lb)
  local L = Pennant.L
  local s = L.settings
  local y = 4
  Text.draw("WHO NEEDS A DAY OFF", 6, y, UI.fonts.head)
  Text.draw("over 55 fatigue costs points", 392, y + 2, UI.fonts.body, nil, "right")
  y = y + 19
  gfx.drawLine(4, y - 2, 392, y - 2)
  if #self.rows == 0 then
    Text.block("Nobody's tired. Everyone in today's lineup is at 55 fatigue or under, the starter is rested and the bullpen is ready.", 8, y + 4, 380, UI.fonts.body, nil, 3)
    y = y + 48
  end
  for i, r in ipairs(self.rows) do
    local p = L.players[r.id]
    local yy = y
    local can = r.sub or r.k == "pen"
    PUI.lazy(Lb, 4, yy - 1, 388, 18, function()
      if can then check(8, yy + 2, r.on) else gfx.drawRect(8, yy + 2, 11, 11) Draw.fade(9, yy + 3, 9, 9, 0.5) gfx.setColor(gfx.kColorBlack) end
      local ty = Text.boxY(UI.fonts.bold, yy, 16)
      Text.draw(r.pos or "", 24, ty, UI.fonts.bold)
      Text.draw(Text.ellipsize(PM.short(p), UI.fonts.body, 82), 50, ty, UI.fonts.body)
      PUI.fatigue(136, yy + 5, r.fat, 24)
      Text.draw(tostring(math.floor(r.fat + 0.5)), 164, ty, UI.fonts.bold)
      Text.draw("\u{25b6}", 186, ty, UI.fonts.bold)
      local d = r.d and (signed(r.d) .. " OVR") or ""
      local dw = UI.fonts.bold:getTextWidth(d)
      Text.draw(Text.ellipsize(PRest.subText(L, r), UI.fonts.body, 386 - dw - 8 - 198), 198, ty, UI.fonts.body)
      if d ~= "" then Text.draw(d, 388, ty, UI.fonts.bold, nil, "right") end
    end)
    local why
    if r.k == "bat" then
      why = string.format("fatigue %d: %.1f off every rating", math.floor(r.fat + 0.5), math.max(0, (r.fat - PRest.TIRED) / 7))
    elseif r.k == "sp" then
      why = "due to start tired: a spot start, he goes tomorrow"
    else
      why = "overused: he sits until rested"
    end
    local hint = can and ("A: " .. (r.on and "keep him in" or "rest him") .. "   " .. why .. ((r.rec == false) and " (cover is a big drop)" or ""))
      or ("Nobody rested to cover. " .. why)
    Lb:link(4, yy - 1, 388, 18, function()
      if not can then Sfx.back() return end
      r.on = not r.on
      Sfx.tick()
      self:render(true)
    end, { id = "row" .. i, style = "invert", hint = hint })
    y = y + 18
  end
  y = y + 6
  -- options (one row: left/right between them, A changes the value)
  local mode = s.restMode or "fresh"
  Lb:button(mode == "today" and "Rest: TODAY ONLY" or "Rest: UNTIL FRESH", 4, y, 190, 18, function()
    s.restMode = (s.restMode or "fresh") == "fresh" and "today" or "fresh"
    Sfx.tick()
    self:render(true)
  end, { id = "mode", hint = mode == "today" and "Back in tomorrow's lineup.  A: until fresh instead" or "Back in the lineup at 45 fatigue or under (unless you change it).  A: today only" })
  Lb:button("Auto-rest: " .. (s.autoRest and "ON" or "OFF"), 198, y, 190, 18, function()
    s.autoRest = not s.autoRest
    Sfx.tick()
    Toast.show(s.autoRest and "Auto-rest on: the coaches rest the tired before every game." or "Auto-rest off.", nil)
    self:render(true)
  end, { id = "auto", hint = "Before every game the coaches make the ticked kind of swaps themselves. A: turn " .. (s.autoRest and "off" or "on") })
  y = y + 24
  local n = self:ticked()
  Lb:button(#self.rows == 0 and "Back" or ("SWAP ALL (" .. n .. ")"), 4, y, 190, 18, function()
    if #self.rows == 0 then Sfx.back() self:finish(0) return end
    self:swap()
  end, { id = "swap", hint = #self.rows == 0 and "Back" or (n > 0 and ("A: rest the " .. n .. " ticked") or "Nothing ticked: tick a row first") })
  if #self.rows > 0 then
    Lb:button("Cancel", 198, y, 190, 18, function() Sfx.back() self:finish(0) end, { id = "cancel", hint = "Leave the lineup as it is" })
  end
  y = y + 22
  Lb:mark(y)
end

function Rest:initialFocus()
  for i, l in ipairs(self.links) do if l.id == "swap" then return i end end
  return 1
end

function Rest:goBack()
  Sfx.back()
  self:finish(0)
end
