-- Preferences: server host/port/SSL, sound, motion, debug, account.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Settings = Page.define({ canvasH = 420 })
Sites.Settings = Settings

function Settings:url() return "about:preferences" end

function Settings:init()
  self.test = nil
end

local function row(L, y, label)
  Text.draw(label, 12, y + 3, UI.fonts.bold)
end

local function field(L, x, y, w, text, action, id, hint)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, 18)
  Draw.bevel(x, y, w, 18, true)
  Text.draw(Text.ellipsize(text, UI.fonts.body, w - 8), x + 4, y + 3, UI.fonts.body)
  L:link(x - 1, y - 1, w + 2, 20, action, { id = id, hint = hint })
end

local function check(L, x, y, label, on, action, id, hint)
  Draw.checkbox(x, y + 3, on)
  local w = Text.draw(label, x + 14, y + 1, UI.fonts.body)
  L:link(x - 2, y, w + 18, 15, action, { id = id, hint = hint, style = "invert" })
end

function Settings:layout(L)
  local W = 392
  local s = Game.settings
  Draw.tile(0, 0, W, 1000, "lighter")
  local ix, iy, iw = Draw.window(6, 4, W - 14, 470, "Preferences", { noShadow = true })
  local y = iy + 6
  -- Server
  Text.draw("LEAGUE SERVER", ix + 6, y, UI.fonts.head)
  y += 18
  local fixture = Api.isFixtureMode()
  local msg
  if not fixture then
    msg = "Online. Bets, jobs and comments go to the league server."
  elseif s.host ~= "" then
    msg = "OFFLINE for this session (sample data). Restart to connect to the host below."
  else
    msg = "No host set: OFFLINE FIXTURE MODE (sample data, nothing is saved to the league)."
  end
  Text.block(msg, ix + 6, y, iw - 12, UI.fonts.body, nil, 2)
  y += 28
  row(L, y, "Host")
  field(L, 70, y, 220, s.host ~= "" and s.host or "(none: offline)", function() self:editHost() end, "host", "Server host name, e.g. deadball.example.workers.dev")
  y += 22
  row(L, y, "Port")
  field(L, 70, y, 70, tostring(s.port or 443), function() self:editPort() end, "port", "Server port")
  check(L, 160, y + 1, "Use SSL (https)", s.ssl ~= false, function()
    s.ssl = not (s.ssl ~= false)
    if s.ssl and s.port == 80 then s.port = 443 elseif not s.ssl and s.port == 443 then s.port = 80 end
    self:save()
  end, "ssl", "Toggle https")
  y += 22
  -- signed plain HTTP is ~10x faster to connect than HTTPS on the Playdate (docs/API.md)
  check(L, 18, y, "Always use HTTPS (slower)", s.forceHttps == true, function()
    s.forceHttps = not (s.forceHttps == true)
    self:save()
  end, "forcehttps", "Off: requests go over signed plain HTTP (fast). On: every request over HTTPS")
  y += 16
  Text.draw(Text.ellipsize("Transport: " .. Api.transport(), UI.fonts.body, iw - 30), 18, y, UI.fonts.body)
  y += 18
  L:button("Test connection", 70, y, 120, 18, function() self:testConnection() end, { id = "test", hint = "Fetch /v1/clock" })
  if self.test then Text.draw(Text.ellipsize(self.test, UI.fonts.body, 170), 200, y + 3, UI.fonts.body) end
  y += 28
  Draw.hr(ix + 4, y, iw - 8)
  y += 8
  -- Sound & display
  Text.draw("SOUND & DISPLAY", ix + 6, y, UI.fonts.head)
  y += 18
  check(L, 18, y, "Sound effects (clicks, modem, chimes)", s.sound ~= false, function() s.sound = not (s.sound ~= false) self:save() if s.sound then Sfx.chime() end end, "sound", "UI sounds on/off")
  y += 16
  y = self:volumeRow(L, y, "Sound volume", "sfxVol")
  y = self:volumeRow(L, y, "Music volume", "musicVol")
  if Audio and Audio.setPA then
    check(L, 18, y, "Stadium PA echo on the organ", s.pa == true, function() s.pa = not (s.pa == true) pcall(Audio.setPA, s.pa) self:save() end, "pa", "Organ through the ballpark PA")
    y += 16
  end
  check(L, 18, y, "Reduce motion (no slides, wipes or tweens)", s.reduceMotion == true, function() s.reduceMotion = not s.reduceMotion self:save() end, "motion", "Turn off animations")
  y += 16
  check(L, 18, y, "Show frame rate", Debug.showFps == true, function() Debug.showFps = not Debug.showFps self:render(true) end, "fps", "Debug: FPS counter")
  y += 22
  Draw.hr(ix + 4, y, iw - 8)
  y += 8
  -- Account
  Text.draw("ACCOUNT", ix + 6, y, UI.fonts.head)
  y += 18
  local a = Game.account
  Text.draw(a and (a.name .. "  \u{2022}  " .. (a.rank or "") .. "  \u{2022}  joined day " .. (a.joinedDay or "?")) or "Not signed in", 18, y, UI.fonts.body)
  y += 18
  L:button("Sign out", 18, y, 90, 18, function() self:signOut() end, { id = "signout", hint = "Forget this device's token for this server" })
  L:button("Clear cache", 116, y, 100, 18, function()
    Api.invalidate("")
    if DiskCache then DiskCache.clear() end
    Faces.flush()
    Toast.show("Cache cleared.", "good")
  end, { id = "cache", hint = "Drop cached pages and photos" })
  L:button("Credits", 224, y, 80, 18, function() Sites.Credits.open() end, { id = "credits", hint = "About this site / webmaster credits" })
  y += 28
  Text.draw("Diamond Navigator Gold 3.0  \u{2022}  DEADBALL " .. (playdate.metadata and playdate.metadata.version or "") .. " (build " .. tostring(Api.BUILD) .. ")", ix + 6, y, UI.fonts.body)
  y += 16
  L:mark(y + 10)
end

function Settings:volumeRow(L, y, label, key)
  local v = Game.settings[key] or 8
  Text.draw(label, 32, y + 1, UI.fonts.body)
  local x = 150
  for i = 1, 10 do
    local bx = x + (i - 1) * 9
    local bh = 3 + i
    if i <= v then gfx.fillRect(bx, y + 13 - bh, 7, bh) else gfx.drawRect(bx, y + 13 - bh, 7, bh) end
  end
  Text.draw(v == 0 and "muted" or (v * 10 .. "%"), x + 96, y + 1, UI.fonts.body)
  L:link(28, y - 1, 250, 16, function() self:adjust(key, 2, true) end,
    { id = "vol:" .. key, hint = "Left/Right to adjust, A to step", style = "ring", data = { adjust = key } })
  return y + 18
end

function Settings:adjust(key, d, wrap)
  local v = (Game.settings[key] or 8) + d
  if wrap and v > 10 then v = 0 end
  v = math.max(0, math.min(10, v))
  Game.settings[key] = v
  Game.applyVolumes()
  Sfx.detent()
  self:save()
end

function Settings:leftButtonDown()
  local l = self.links[self.focus]
  if l and l.data and l.data.adjust then self:adjust(l.data.adjust, -1) return end
  Page.leftButtonDown(self)
end

function Settings:rightButtonDown()
  local l = self.links[self.focus]
  if l and l.data and l.data.adjust then self:adjust(l.data.adjust, 1) return end
  Page.rightButtonDown(self)
end

function Settings:save()
  Game.saveSettings()
  self:render(true)
end

function Settings:editHost()
  NameEntry.open({ title = "Server host", prompt = "Host name only (no http://). Leave empty for offline fixture mode.", text = Game.settings.host or "", maxLen = 64,
    onDone = function(t)
      if t == nil then return end
      Game.settings.host = t:gsub("^https?://", ""):gsub("/.*$", "")
      self.test = nil
      self:save()
    end })
end

function Settings:editPort()
  NameEntry.open({ title = "Server port", prompt = "Usually 443 for https, 80 or 8787 for local http.", text = tostring(Game.settings.port or 443), maxLen = 5,
    onDone = function(t)
      local n = tonumber(t or "")
      if n and n > 0 and n < 65536 then
        Game.settings.port = math.floor(n)
        self:save()
      elseif t then
        Toast.show("That's not a port number.", "bad")
      end
    end })
end

function Settings:testConnection()
  self.test = "Dialing..."
  self:render(true)
  Game.syncClock(function(err, d)
    if err then
      self.test = "Failed: " .. Api.errorText(err)
      Sfx.error()
    else
      self.test = "OK! Season " .. (d.season or "?") .. ", day " .. (d.day or "?")
      Sfx.chime()
    end
    self:render(true)
  end)
end

function Settings:signOut()
  Dialog.confirm("Sign out?", "This forgets your token for this server. Without it you can't get back into this account.", "Sign out", "Cancel", function(ok)
    if not ok then return end
    Game.forgetToken()
    Nav.ready = false
    for i = #App.stack, 1, -1 do
      local sc = App.stack[i]
      if sc.exit then sc:exit() end
    end
    App.stack = {}
    Boot.start()
  end)
end

function Settings:goBack()
  if self.args.fromBoot then
    Sfx.back()
    App.pop()
    return
  end
  Page.goBack(self)
end
