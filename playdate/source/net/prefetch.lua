--[[
  net/prefetch.lua — warms the caches for the screens a player is likely to open next, in
  ONE background /batch request (each HTTPS connection costs the device 7-11 s; bytes are
  nearly free). Results land in Api's memory cache and the disk cache, so opening those
  pages paints at once (ui/page.lua stale-while-revalidate) and only refreshes behind it.

  When: once at boot (folded into the splash's /clock + /me batch, see app/boot.lua), then
  again only after the game day turns over (Game.clock.nextDayAt), and only while the
  player sits idle on the desktop. Never while a BallCast replay is open (it's CPU-bound):
  Api.holdBackground keeps queued prefetches parked until the replay closes.
]]

Prefetch = Prefetch or {}

-- Paths must match the sites' sources() exactly (the caches key on the full path).
Prefetch.PATHS = {
  "/today", "/bets?status=open", "/bets?status=settled",   -- Bets By Bobby (+ Scoreboard)
  "/news", "/standings?level=ML",                           -- SportsWire front page
  "/mail",                                                  -- DiamondMail
  "/gossip",                                                -- gossip / props
  "/schedule",                                              -- Scoreboard (optional source)
}
-- The desktop's own sources (sites/desktop.lua: the To Do, badges, ticker) ride along at boot.
-- With /clock and PATHS that's 15 paths: one /batch (the server takes up to 16).
Prefetch.DESKTOP = { "/me", "/events", "/news", "/today", "/ops", "/watchlist", "/gossip", "/mail", "/syndicate", "/bulletins" }

local IDLE_FRAMES <const> = 45          -- ~1.5 s without input on the desktop
local DAY_GRACE_MS <const> = 20000      -- let the server finish the day's run first
local RETRY_MS <const> = 60000

local st = { day = nil, inFlight = false, nextTry = 0, fails = 0 }

local function nowMs() return playdate.getCurrentTimeMilliseconds() end

function Prefetch.replayOpen()
  local bc = BallCast and BallCast.scene
  if not bc then return false end
  for _, s in ipairs(App.stack) do
    if s == bc then return true end
  end
  return false
end

Api.holdBackground = Prefetch.replayOpen

function Prefetch.enabled()
  return not Api.isFixtureMode() and Api.token ~= nil and Api.batching and not Api.batchOff and not Api.isBlocked()
end

--- Starts one background prefetch of Prefetch.PATHS (plus extra paths). Returns the count queued.
function Prefetch.run(why, extra)
  if not Prefetch.enabled() or st.inFlight or Prefetch.replayOpen() then return 0 end
  local paths = {}
  for _, p in ipairs(extra or {}) do paths[#paths + 1] = p end
  for _, p in ipairs(Prefetch.PATHS) do paths[#paths + 1] = p end
  st.inFlight = true
  st.nextTry = nowMs() + RETRY_MS
  local day = Game.clock and Game.clock.day
  local n = Api.prefetch(paths, function(ok, bad)
    st.inFlight = false
    print(string.format("[prefetch] %s done ok=%d err=%d", why, ok, bad))
    if ok == 0 and bad > 0 then
      st.fails += 1
      st.nextTry = nowMs() + RETRY_MS * math.min(8, 2 ^ (st.fails - 1))
    else
      st.fails = 0
      st.day = (Game.clock and Game.clock.day) or day or 0
      -- the desktop's To Do / badges / ticker repaint from what just landed in the cache
      local d = Sites.Desktop and Sites.Desktop.instance
      if d and d.refreshFromCache then d:refreshFromCache() end
    end
  end)
  print(string.format("[prefetch] %s n=%d", why, n))
  return n
end

--- Boot: called in the same frame as the splash's /clock and /me so all of it is one batch.
function Prefetch.desktopPaths()
  local extra = {}
  for i, p in ipairs(Prefetch.DESKTOP) do extra[i] = p end
  -- While You Were Out reads exactly this path from the cache when the desktop opens
  if Sites.Digest then extra[#extra + 1] = Sites.Digest.path() end
  return extra
end

function Prefetch.boot()
  return Prefetch.run("boot", Prefetch.desktopPaths())
end

--- From the desktop's tick: refresh after the day turns over, while the player is idle.
function Prefetch.tick(page)
  if not Prefetch.enabled() or st.inFlight or App.top() ~= page then return end
  if (page.idleFrames or 0) < IDLE_FRAMES or nowMs() < st.nextTry then return end
  local c = Game.clock
  local dayTurned = c and c.nextDayAt and Api.now() > c.nextDayAt + DAY_GRACE_MS
  if st.day ~= nil and not dayTurned then return end
  if dayTurned then
    -- new day: clock, account and events go in the same frame, so the same batch
    Game.syncClock()
    Game.refreshMe(function() if Sites.Desktop.instance then Sites.Desktop.instance.dirty = true end end)
    Nav.checkEvents(false)
    Nav.markPolled()
  end
  Prefetch.run(dayTurned and "day" or "idle", dayTurned and Prefetch.desktopPaths() or nil)
end
