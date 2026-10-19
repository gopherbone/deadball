-- Session state: settings, auth token, account, clock and shared lookups.

Game = Game or {}
Game.account = nil
Game.clock = nil
-- The live league. Clearing the host in Settings switches to offline fixtures.
Game.LIVE_HOST = "deadball.angelfire.workers.dev"
Game.settings = { host = Game.LIVE_HOST, port = 443, ssl = true, sound = true, reduceMotion = false, v = 2 }
Game.displayMoney = nil   -- animated bankroll shown in the status bar
Game.moneyFlash = 0
Game.words = nil

-- Screenshot and perf tours always run on the offline fixtures.
local function apiSettings()
  if Tour and Tour.isActive and Tour.isActive() then
    return { host = "", port = 443, ssl = true }
  end
  return Game.settings
end

local function authKey()
  local h = Api.config.host
  if not h or h == "" then return "fixtures" end
  return h .. ":" .. tostring(Api.config.port)
end

function Game.loadSettings()
  local s = playdate.datastore.read("settings")
  if type(s) == "table" then
    for k, v in pairs(s) do Game.settings[k] = v end
    -- builds from before the league went live saved an empty (offline) host
    if (s.v or 1) < 2 then
      Game.settings.host = Game.LIVE_HOST
      Game.settings.v = 2
    end
  end
  Api.configure(apiSettings())
  Sfx.enabled = Game.settings.sound ~= false
  Game.applyVolumes()
  local a = playdate.datastore.read("auth")
  Api.setToken(type(a) == "table" and a[authKey()] or nil)
end

--- Pushes volume settings to the synth fallback and the audio module (if present).
function Game.applyVolumes()
  local s = Game.settings
  Sfx.volume = (s.sfxVol or 8) / 10
  if Audio then
    if Audio.setSfxVolume then pcall(Audio.setSfxVolume, (s.sfxVol or 8) / 10) end
    if Audio.setMusicVolume then pcall(Audio.setMusicVolume, (s.musicVol or 8) / 10) end
    if Audio.setVolume then
      pcall(Audio.setVolume, "sfx", (s.sfxVol or 8) / 10)
      pcall(Audio.setVolume, "music", (s.musicVol or 8) / 10)
    end
    if Audio.setMuted then pcall(Audio.setMuted, s.sound == false) end
    if Audio.setPA then pcall(Audio.setPA, s.pa == true) end
  end
end

function Game.saveSettings()
  playdate.datastore.write(Game.settings, "settings")
  Api.configure(apiSettings())
  Sfx.enabled = Game.settings.sound ~= false
  Game.applyVolumes()
  local a = playdate.datastore.read("auth")
  Api.setToken(type(a) == "table" and a[authKey()] or nil)
end

function Game.saveToken(token)
  local a = playdate.datastore.read("auth")
  if type(a) ~= "table" then a = {} end
  a[authKey()] = token
  playdate.datastore.write(a, "auth")
  Api.setToken(token)
end

function Game.forgetToken()
  if Signer then Signer.drop() end
  if DiskCache then DiskCache.clear() end
  Game.saveToken(nil)
  Game.account = nil
end

function Game.hasToken()
  return Api.token ~= nil
end

function Game.setAccount(acct)
  if not acct then return end
  local prev = Game.account
  Game.account = acct
  if Game.baseMoney == nil then Game.baseMoney = acct.money end
  if Game.displayMoney == nil then
    Game.displayMoney = acct.money
  elseif prev and prev.money ~= acct.money then
    Game.moneyFlash = 24
  end
  if prev and (acct.heat or 0) > (prev.heat or 0) then
    Game.heatFlash = 90
    Sfx.siren()
  end
  if prev and (acct.unreadMail or 0) > (prev.unreadMail or 0) then
    if not Sfx.stinger("new_mail") then Sfx.mail() end
  end
end

--- Eases the menu-bar bankroll toward the real number (called each frame).
function Game.tick()
  local a = Game.account
  if a and Game.displayMoney and not Game.moneyHold then
    local d = a.money - Game.displayMoney
    if d ~= 0 then
      local step = math.max(1, math.floor(math.abs(d) * 0.18))
      if math.abs(d) <= step then Game.displayMoney = a.money
      else Game.displayMoney += (d > 0 and step or -step) end
      if Game.frame and Game.frame % 2 == 0 then Sfx.tick() end
    end
  end
  if Game.moneyFlash > 0 then Game.moneyFlash -= 1 end
  if (Game.heatFlash or 0) > 0 then Game.heatFlash -= 1 end
end

function Game.refreshMe(cb)
  Api.get("/me", function(err, d)
    if d and d.account then Game.setAccount(d.account) end
    if cb then cb(err, d) end
  end, { fresh = true })
end

function Game.syncClock(cb)
  Api.get("/clock", function(err, d)
    if d then
      Game.clock = d
      Api.setClock(d.now)
    end
    if cb then cb(err, d) end
  end, { fresh = true })
end

--- Comment vocabulary (templates + slot words). Cached for the session.
function Game.loadWords(cb)
  if Game.words then
    cb(nil, Game.words)
    return
  end
  Api.get("/words", function(err, d)
    if d then Game.words = d end
    cb(err, d)
  end, { ttl = 600000 })
end

--- Applies an `account` field from any response that carries one.
function Game.absorb(data)
  if type(data) == "table" and data.account then Game.setAccount(data.account) end
end

-- The day's heartbeat -----------------------------------------------------------------------
-- A game day (msPerDay, 30 min live) starts; from 25% in its games pitch one after another, a
-- couple of minutes apart (server src/schedule.ts), each on the air ~70% of a day (finalAt), so
-- the last few are still on when the next day starts. Bets and jobs on a game lock at ITS first
-- pitch. /clock gives the day, nextDayAt and the next lock (nextPitchAt, nextGame); today's
-- slate (any /today the client fetches, via Api.observe) has every game's firstPitchAt/finalAt.

Game.slate = nil       -- { day, firstPitchAt (the earliest), games } from the newest /today
Game.baseMoney = nil   -- money when this session started (the status bar's ▲/▼)

local function absorbSlate(d)
  if type(d) ~= "table" or type(d.games) ~= "table" then return end
  local fp = nil
  for _, g in ipairs(d.games) do
    if g.firstPitchAt and (not fp or g.firstPitchAt < fp) then fp = g.firstPitchAt end
  end
  Game.slate = { day = d.day, firstPitchAt = fp, games = d.games, at = Api.now() }
  if Status then Status.dirty = true end
end
Api.observe("/today", absorbSlate)
Game.absorbSlate = absorbSlate

local clockAsk = 0
--- Re-sync the clock (throttled): the day turned over while we weren't looking.
function Game.wantClock()
  local t = playdate.getCurrentTimeMilliseconds()
  if t - clockAsk < 15000 then return end
  clockAsk = t
  Game.syncClock()
end

local function finalAtOf(g)
  if g.finalAt then return g.finalAt end
  local c = Game.clock
  return (g.firstPitchAt or 0) + (((c and c.msPerDay) or 1800000) * 7) // 10
end

--- Is this SlateGame on the air right now? By the clock, not its (possibly stale) status.
function Game.isLive(g)
  if not g or not g.firstPitchAt or g.status == "final" then return false end
  local now = Api.now()
  return now >= g.firstPitchAt and now < finalAtOf(g)
end

--- Still taking bets and jobs (scheduled, its first pitch ahead)?
function Game.isOpen(g)
  return g ~= nil and g.status == "scheduled" and (g.firstPitchAt or 0) > Api.now()
end

--- The next game to lock: { at, id, away, home (abbrs), game? }; the slate first, then /clock.
function Game.nextLock()
  local best = nil
  local s = Game.slate
  for _, g in ipairs(s and s.games or {}) do
    if Game.isOpen(g) and (not best or g.firstPitchAt < best.at) then
      best = { at = g.firstPitchAt, id = g.id, away = g.away and g.away.abbr, home = g.home and g.home.abbr, game = g }
    end
  end
  if best then return best end
  local c = Game.clock
  if c and c.nextPitchAt then
    if c.nextPitchAt > Api.now() then
      local ng = c.nextGame or {}
      return { at = c.nextPitchAt, id = ng.id, away = ng.away, home = ng.home }
    end
    Game.wantClock()
  end
  return nil
end

--- Games on the air right now (from the slate, by the clock).
function Game.onAir()
  local n = 0
  local s = Game.slate
  for _, g in ipairs(s and s.games or {}) do if Game.isLive(g) then n += 1 end end
  return n
end

--- One of your games that left the air in the last `ms` (its pool is paying out), or nil.
function Game.myJustFinal(ms)
  local s = Game.slate
  local now = Api.now()
  for _, g in ipairs(s and s.games or {}) do
    if g.myBet and g.firstPitchAt then
      local f = finalAtOf(g)
      if now >= f and now < f + ms then return g end
    end
  end
  return nil
end

--- phase, ms left in it, the world day, ms since it began, the next lock (Game.nextLock), games
--- on the air. Phases: "pre" (a game is taking bets: left = to its lock; games may be on the air
--- too), "air" (nothing left to bet, games on the air), "final" (nothing on, nothing to bet until
--- the next day), "off" (offseason). nil before /clock.
function Game.dayPhase()
  local c = Game.clock
  if not c or not c.nextDayAt then return nil end
  local now = Api.now()
  local dayMs = math.max(10000, c.msPerDay or 1800000)
  local nextAt, day = c.nextDayAt, c.day or 0
  if now >= nextAt then
    Game.wantClock()
    -- keep counting on the device's clock until the server answers (live only: the
    -- offline fixtures replay the same day forever)
    if not Api.isFixtureMode() then
      local n = (now - nextAt) // dayMs + 1
      nextAt += n * dayMs
      day += n
    end
  end
  if c.phase == "offseason" then return "off", math.max(0, nextAt - now), day, 0, nil, 0 end
  local lock, live = Game.nextLock(), Game.onAir()
  if lock then return "pre", lock.at - now, day, 0, lock, live end
  if live > 0 then
    -- until the last broadcast on the air ends
    local s, last, first = Game.slate, now, now
    for _, g in ipairs(s and s.games or {}) do
      if Game.isLive(g) then last = math.max(last, finalAtOf(g)) first = math.min(first, g.firstPitchAt) end
    end
    return "air", last - now, day, now - first, nil, live
  end
  return "final", math.max(0, nextAt - now), day, 0, nil, 0
end

--- "4:12" (m:ss) for countdowns; "1h 05" past an hour.
function Fmt.countdown(ms)
  local s = math.max(0, ms or 0) // 1000
  if s >= 3600 then return string.format("%dh %02d", s // 3600, (s % 3600) // 60) end
  return string.format("%d:%02d", s // 60, s % 60)
end

--- Biggest game on the air the player has money on (from the newest slate), or nil.
function Game.myLiveGame()
  local s = Game.slate
  if not s then return nil end
  local best = nil
  for _, g in ipairs(s.games or {}) do
    if g.myBet and Game.isLive(g) and (not best or g.myBet.amount > best.myBet.amount) then best = g end
  end
  return best
end

--- "BOT 7" / "TOP 3" -> "B7" / "T3".
function Fmt.inning(s)
  if not s then return "" end
  local half, n = tostring(s):match("^(%a+)%s*(%d+)")
  if half then return half:sub(1, 1):upper() .. n end
  return tostring(s)
end

function Game.dayLabel()
  local c = Game.clock
  if not c then return "" end
  return "Season " .. (c.season or "?") .. " \u{2022} Day " .. (c.day or "?")
end
