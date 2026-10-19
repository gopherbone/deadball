-- Boot splash ("Diamond Navigator" dialing in), first-run registration, then desktop.

local gfx <const> = playdate.graphics

Boot = Boot or {}

local STEPS <const> = {
  { 0.00, "Initializing modem..." },
  { 0.12, "Dialing 555-0197..." },
  { 0.40, "Handshaking..." },
  { 0.62, "Verifying username and password..." },
  { 0.85, "Connected at 2400 baud." },
}

local Splash = { opaque = true }
Splash.__index = Splash
Boot.Splash = Splash

function Splash:enter()
  self.t = 0
  self.dur = 78 -- frames, roughly the modem sound
  self.state = "dialing"
  self.clockDone = false
  self.meDone = false
  self.result = nil
  local snd = Sfx.modem()
  if snd and snd > 0 then self.dur = math.floor(snd * 30) end
  if Game.settings.reduceMotion then self.dur = 20 end
  -- already refused this session (build gate): no point dialing for long
  if Api.isBlocked() then self.dur = 20 end
  Game.syncClock(function(err)
    self.clockErr = err
    self.clockDone = true
  end)
  if Game.hasToken() then
    Api.get("/me", function(err, d)
      self.meDone = true
      if d and d.account then
        Game.setAccount(d.account)
        self.result = "desktop"
      elseif err and (err.status == 401 or err.code == "unauthorized") then
        self.result = "register"
      else
        self.result = "offline"
        self.err = err
      end
    end, { fresh = true })
    -- /clock, /me, the desktop's sources and the prefetch list are all queued this frame,
    -- so the client sends them as ONE /batch request: a single connection setup at boot
    Prefetch.boot()
  else
    self.meDone = true
    self.result = "register"
  end
end

function Splash:proceed()
  if self.left then return end
  self.left = true
  Sfx.stopModem()
  if Api.isBlocked() then
    -- the league refused this build (426): the "update required" page, never the desktop
    Sfx.error()
    Sites.Upgrade.replace({})
  elseif self.result == "desktop" then
    Sfx.chime()
    Sites.Desktop.replace({ fromBoot = true })
  elseif self.result == "register" then
    Sfx.chime()
    App.replace(Boot.Register)
  else
    Sfx.error()
    Dialog.show({
      title = "Connection failed",
      body = "Diamond Navigator could not reach the league server. " .. Api.errorText(self.err),
      buttons = { "Retry", "Settings", "Pennant" }, icon = "!",
      onChoose = function(i)
        if i == 1 then
          App.replace(Splash)
        elseif i == 3 and Pennant then
          -- no network needed: the offline season game
          self.left = false
          Pennant.open({ fromBoot = true })
        else
          self.left = false
          Sites.Settings.open({ fromBoot = true })
        end
      end,
    })
  end
end

function Splash:resume()
  -- back from settings: dial again
  App.replace(Splash)
end

function Splash:AButtonDown()
  -- any button skips the dial-up
  Sfx.stopModem()
  self.t = math.max(self.t, self.dur)
end
Splash.BButtonDown = Splash.AButtonDown
Splash.upButtonDown = Splash.AButtonDown
Splash.downButtonDown = Splash.AButtonDown
Splash.leftButtonDown = Splash.AButtonDown
Splash.rightButtonDown = Splash.AButtonDown

function Splash:update()
  self.t += 1
  if self.t == 2 and not Api.isBlocked() then Api.requestAccess() end
  local frac = math.min(1, self.t / self.dur)
  gfx.clear(gfx.kColorWhite)
  local splash = UI.image("images/ui/splash-navigator")
  if splash then
    splash:draw(0, 0)
    local stepText = STEPS[1][2]
    for _, s in ipairs(STEPS) do if frac >= s[1] then stepText = s[2] end end
    if frac >= 1 and not (self.meDone and self.clockDone) then stepText = "Waiting for host..." end
    -- progress bar interior (54, 184, 236, 8)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(54, 184, math.floor(236 * frac), 8)
    -- replace the baked-in "Loading..." label with the modem step
    local short = stepText:gsub("%.%.%.$", ""):match("^(%S+)") or stepText
    if frac >= 0.85 and self.meDone then short = "Connected!" end
    if short == "Verifying" and Game.account and (Game.account.heat or 0) >= 7 then short = "Wiretaps?" end
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(296, 180, 60, 14)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(short .. string.rep(".", (self.t // 8) % 4), 298, 181, UI.fonts.body)
    if frac >= 1 and self.meDone and self.clockDone then self:proceed() end
    return
  end
  -- tiled backdrop
  Draw.tile(0, 0, 400, 240, "dots")
  local x, y, w, h = 50, 28, 300, 180
  local ix, iy, iw, ih = Draw.window(x, y, w, h, "Diamond Navigator")
  -- logo: a diamond with a ball orbiting
  local cx, cy = 200, iy + 38
  gfx.setColor(gfx.kColorBlack)
  gfx.fillPolygon(cx, cy - 24, cx + 24, cy, cx, cy + 24, cx - 24, cy)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillPolygon(cx, cy - 16, cx + 16, cy, cx, cy + 16, cx - 16, cy)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(cx - 3, cy - 3, 6, 6)
  local a = self.t * 0.15
  Draw.throbber(cx + math.floor(math.cos(a) * 34), cy + math.floor(math.sin(a) * 14), 5, self.t, true)
  Draw.wordart("Diamond Navigator", 200, iy + 66, UI.fonts.slab)
  Text.draw("Gold Edition 3.0 \u{2022} for the Continental League", 200, iy + 98, UI.fonts.body, nil, "center")
  -- progress
  local step = STEPS[1][2]
  for _, s in ipairs(STEPS) do if frac >= s[1] then step = s[2] end end
  if step:find("^Verifying") and Game.account and (Game.account.heat or 0) >= 7 then step = "Checking for wiretaps..." end
  if frac >= 1 and not (self.meDone and self.clockDone) then step = "Waiting for host..." end
  Text.draw(step, ix + 14, iy + 118, UI.fonts.bold)
  Draw.progress(ix + 14, iy + 134, iw - 28, 10, frac, "gray")
  -- blinking modem lights
  local lights = { "HS", "AA", "CD", "OH", "RD", "SD", "TR" }
  for i, l in ipairs(lights) do
    local lx = ix + 14 + (i - 1) * 40
    local on = (i == 3 and frac > 0.85) or (i == 4) or (i == 7) or ((i == 5 or i == 6) and math.random() < 0.5 and frac > 0.4)
    if on then gfx.fillCircleAtPoint(lx + 4, iy + 154, 3) else gfx.drawCircleAtPoint(lx + 4, iy + 154, 3) end
    Text.draw(l, lx + 10, iy + 148, UI.fonts.body)
  end
  if frac >= 1 and self.meDone and self.clockDone then
    self:proceed()
  end
end

-- Registration --------------------------------------------------------------------------

Boot.Register = Page.define({
  style = "browser",
})
local Register = Boot.Register

function Register:url() return "http://www.continentalleague.org/join.html" end

function Register:init()
  self.name = ""
end

function Register:statusText() return "Welcome, stranger." end

function Register:layout(L)
  local gfx = playdate.graphics
  Draw.tile(0, 0, 400, 193, "bricks")
  local x, y, w = 24, 8, 344
  local ix, iy, iw = Draw.window(x, y, w, 176, "Join the Continental League")
  Draw.wordart("WELCOME!", ix + iw // 2, iy + 2, UI.fonts.slab)
  local ty = iy + 34
  ty += L:para("You're new here. Pick a name, the only thing you'll ever get to type. Then you get $1,000 and a free pack of cards. Spend it wisely. Or don't.", ix + 10, ty, iw - 20, UI.fonts.body)
  ty += 6
  Text.draw("Your name:", ix + 10, ty + 3, UI.fonts.bold)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(ix + 90, ty, 150, 18)
  Draw.bevel(ix + 90, ty, 150, 18, true)
  Text.draw(self.name ~= "" and self.name or "(none yet)", ix + 95, ty + 3, self.name ~= "" and UI.fonts.bold or UI.fonts.body)
  L:link(ix + 88, ty - 2, 154, 22, function() self:pickName() end, { id = "name", hint = "Press A to type your name", style = "ring" })
  L:button(self.name ~= "" and "Sign up!" or "Sign up", ix + 250, ty - 1, 70, 20, function() self:submit() end, { id = "go", hint = "Create your account" })
  ty += 28
  L:para("3-16 letters or numbers. The Decency Board reads every one.", ix + 10, ty, iw - 20, UI.fonts.body)
  L:mark(190)
end

function Register:initialFocus()
  for i, l in ipairs(self.links) do if l.id == (self.name ~= "" and "go" or "name") then return i end end
  return 1
end

function Register:pickName()
  NameEntry.open({
    title = "Choose your name",
    prompt = "This is how the league will know you. Choose carefully: no take-backs.",
    text = self.name, maxLen = 16,
    onDone = function(t)
      if t and t ~= "" then
        self.name = t
        self:render()
        self.focus = self:initialFocus()
        self:submit()
      end
    end,
  })
end

function Register:submit()
  if self.name == "" then
    self:pickName()
    return
  end
  Busy.post("/register", { name = self.name }, "Registering", function(d)
    Game.saveToken(d.token)
    Game.setAccount(d.account)
    Sfx.coin()
    Toast.show("Welcome, " .. d.account.name .. "! Here's $1,000 and a free pack.", "good")
    Sites.Desktop.replace({ fromBoot = true, firstRun = true })
  end, function(err)
    local title = err.code == "name_taken" and "Name taken" or err.code == "name_rejected" and "Name rejected" or "Couldn't register"
    Dialog.show({
      title = title, icon = "!",
      body = Api.errorText(err),
      buttons = { "Try another", "Cancel" }, cancel = 2,
      onChoose = function(i) if i == 1 then self:pickName() end end,
    })
  end)
end

function Register:goBack() Sfx.detent() end

-- Mode select (the first screen at launch) -----------------------------------------------------
-- ONLINE: the Continental League (the desktop, as before). OFFLINE: Pennant '96. The last choice
-- is the default; dev runs (tour / perf tour / net tests) skip straight to the online path.

local ModeSelect = { opaque = true }
ModeSelect.__index = ModeSelect
Boot.ModeSelect = ModeSelect

local MODES <const> = {
  { id = "online", title = "ONLINE", name = "The Continental League",
    lines = { "Bet on the games.", "Run a crew.", "Read about it in the papers." },
    foot = "Requires a modem and nerve." },
  { id = "offline", title = "OFFLINE", name = "Pennant '96",
    lines = { "Your club. Your lineup.", "One game at a time.", "Nobody else is involved." },
    foot = "No modem. Just baseball." },
}

local DEV_FLAGS <const> = { "tour.flag", "perftour.flag", "nettest.flag", "livetest.flag", "netshim.flag" }

function Boot.devRun()
  for _, f in ipairs(DEV_FLAGS) do if playdate.file.exists(f) then return true end end
  return false
end

function ModeSelect:enter()
  self.sel = (Game.settings.mode == "offline") and 2 or 1
  self.t = 0
  self.acc = 0
  self.bg = nil
  Nav.ready = false
end

function ModeSelect:resume()
  self.t = 0
  Nav.offline = false
end

--- The static parts, painted once.
function ModeSelect:paint()
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  local tile = UI.image("images/bg/baseballs")
  if tile then tile:drawTiled(0, 0, 400, 240) else Draw.tile(0, 0, 400, 240, "dots") end
  Draw.fade(0, 0, 400, 240, 0.5, true)
  -- masthead
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 0, 400, 62)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 62, 400, 2)
  Draw.wordart("DEADBALL", 200, 8, UI.fonts.slab)
  Text.draw("BASEBALL, MORE OR LESS  \u{2022}  EST. 1996", 200, 46, UI.fonts.bold, nil, "center")
  -- footer
  gfx.fillRect(0, 222, 400, 18)
  Text.draw("\u{25c0}\u{25b6} or crank: choose     A: play ball", 200, 224, UI.fonts.bold, "white", "center")
  gfx.popContext()
  self.bg = img
  self.cards = {}
  for i = 1, 2 do self.cards[i] = { self:card(i, false), self:card(i, true) } end
end

function ModeSelect:card(i, on)
  local m = MODES[i]
  local w, h = 178, 142
  local img = gfx.image.new(w + 4, h + 4, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(4, 4, w, h)                      -- drop shadow
  gfx.setColor(on and gfx.kColorBlack or gfx.kColorWhite)
  gfx.fillRect(0, 0, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(0, 0, w, h)
  gfx.drawRect(2, 2, w - 4, h - 4)
  local col = on and "white" or nil
  -- emblem
  local ex, ey = w // 2, 30
  gfx.setColor(on and gfx.kColorWhite or gfx.kColorBlack)
  if m.id == "online" then
    -- a telephone pole and wire: the modem
    gfx.fillRect(ex - 1, ey - 18, 3, 30)
    gfx.fillRect(ex - 12, ey - 14, 25, 3)
    gfx.drawLine(ex - 40, ey - 6, ex - 12, ey - 13)
    gfx.drawLine(ex + 12, ey - 13, ex + 40, ey - 6)
    gfx.fillCircleAtPoint(ex + 26, ey - 9, 2)
  else
    -- a pennant on a pole
    gfx.fillRect(ex - 22, ey - 18, 2, 30)
    gfx.fillTriangle(ex - 20, ey - 18, ex + 26, ey - 10, ex - 20, ey - 2)
    gfx.setColor(on and gfx.kColorBlack or gfx.kColorWhite)
    Text.draw("96", ex - 12, ey - 17, UI.fonts.bold, on and nil or "white")
  end
  gfx.setColor(gfx.kColorBlack)
  Text.draw(m.title, w // 2, 46, UI.fonts.big, col, "center")
  Text.draw(m.name, w // 2, 70, UI.fonts.bold, col, "center")
  for k, l in ipairs(m.lines) do Text.draw(l, w // 2, 86 + (k - 1) * 13, UI.fonts.body, col, "center") end
  Text.draw(m.foot, w // 2, h - 18, UI.fonts.body, col, "center")
  gfx.popContext()
  return img
end

function ModeSelect:update()
  self.t += 1
  if not self.bg then self:paint() end
  self.bg:draw(0, 0)
  for i = 1, 2 do
    local on = i == self.sel
    local x, y = (i == 1) and 14 or 208, 72
    if on and not Game.settings.reduceMotion then y -= ((self.t // 10) % 2) end
    self.cards[i][on and 2 or 1]:draw(x, y)
    if on and (self.t // 8) % 2 == 0 then
      gfx.setColor(gfx.kColorBlack)
      gfx.setLineWidth(2)
      gfx.drawRoundRect(x - 4, y - 4, 186, 150, 4)
      gfx.setLineWidth(1)
    end
  end
  if Game.settings.mode then
    Text.draw("last time: " .. (Game.settings.mode == "offline" and "offline" or "online"), 396, 208, UI.fonts.body, nil, "right")
  end
end

function ModeSelect:move(d)
  local n = math.max(1, math.min(2, self.sel + d))
  if n ~= self.sel then self.sel = n Sfx.focus() else Sfx.detent() end
end
function ModeSelect:leftButtonDown() self:move(-1) end
function ModeSelect:rightButtonDown() self:move(1) end
function ModeSelect:upButtonDown() self:move(-1) end
function ModeSelect:downButtonDown() self:move(1) end
function ModeSelect:cranked(c)
  self.acc += c
  if math.abs(self.acc) > 50 then self:move(self.acc > 0 and 1 or -1) self.acc = 0 end
end

function ModeSelect:AButtonDown()
  local m = MODES[self.sel]
  Game.settings.mode = m.id
  Game.saveSettings()
  Sfx.select()
  if m.id == "offline" and Pennant then
    Pennant.open({ fromMode = true })
  else
    App.push(Splash)
  end
end
function ModeSelect:BButtonDown() Sfx.detent() end

--- System menu: back to the mode select from anywhere (Pennant saves on the way out).
function Boot.toModeSelect()
  if Pennant and Pennant.L then pcall(function() PJobs.flush() PSave.saveNow(Pennant.L, Pennant.L.slot) end) Pennant.L, Pennant.hub = nil, nil end
  Nav.ready = false
  Nav.offline = false
  while #App.stack > 0 do App.pop() end
  App.push(ModeSelect)
end

function Boot.start()
  if Boot.devRun() then App.push(Splash) return end
  App.push(ModeSelect)
end
