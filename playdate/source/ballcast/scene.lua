-- BallCast 3D: the replay scene. Entered with App.push(BallCast.scene, { gameId = id }).
--
-- Controls: crank scrubs time · A play/pause · B back · up/down previous/next at-bat ·
-- left/right playback speed (1x/2x/4x). Finals open on a menu (watch / highlights / skip
-- to the end); live games join near the head of the log and keep polling.
--
-- Local games (offline modes, e.g. Pennant): App.push(BallCast.scene, { gameId = id, source = src })
-- where src answers the same requests the server would (src:get(path) -> data | nil, err:
-- "/games/<id>?lite=1", "/games/<id>/log?from=n", "/games/<id>/wire", "/today") and plays the
-- game live. Optional hooks, all called with the scene first:
--   src:frame(scene, bi, beat, tau, dt) -> rate multiplier | nil   every frame, before time advances
--   src:draw(scene, bi, beat, tau)       after the HUD (overlays: dugout menu, batting/pitching)
--   src:input(scene, button, ...)        "A","AUp","B","up","down","left","right","crank" -> true = consumed
--   src.finalCard = true                 the source draws its own final card
-- and the scene offers scene:feed(events) (append to the live log; no polling for local games)
-- and scene:dropLast() (take back the open last beat: a provisional pitch the source re-decides).

import "CoreLibs/graphics"
import "CoreLibs/timer"

import "ballcast/kit"
import "ballcast/cam"
import "ballcast/puppets"
import "ballcast/timeline"
import "ballcast/play"
import "ballcast/audio"
import "ballcast/crowd"
import "ballcast/hud"
import "ballcast/render3d"
import "ballcast/tags"
import "ballcast/gamelog"
import "ballcast/tv/tv"

local gfx <const> = playdate.graphics
local floor <const>, abs <const>, min <const>, max <const> = math.floor, math.abs, math.min, math.max

BallCast = BallCast or {}
local K = BCKit
local TL = BallCast.Timeline
local Play = BallCast.Play
local Cam = BallCast.Cam
local HUD = BallCast.HUD
local Audio = BallCast.Audio
local Crowd = BallCast.Crowd
local R3 = BallCast.Render
local Log = BallCast.GameLog
local TV = BallCast.TV

local S = { opaque = true }
BallCast.scene = S

local SPEEDS = { 1, 2, 4 }
local POLL_MS = 5000
local CAM_ORDER = { "pitch", "high", "deepC", "deepL", "deepR" }

---------------------------------------------------------------------------
-- loading

local function deriveTeams(meta, log)
  local people = meta.people or {}
  for _, e in ipairs(log) do
    if e.k == "pa" then
      -- first PA is the away team batting
      local p = people[e.bat]
      local q = people[e.pit]
      if p and q and p.teamAbbr and q.teamAbbr then
        meta.away = meta.away or { abbr = p.teamAbbr }
        meta.home = meta.home or { abbr = q.teamAbbr }
        return
      end
    end
  end
  meta.away = meta.away or { abbr = "AWY" }
  meta.home = meta.home or { abbr = "HOM" }
end

function S:fail(msg)
  self.mode = "error"
  self.err = msg
end

--- compact: ask for "?fmt=c" (one string; cb gets data.logc and an empty event list unless
--- the server is too old to know the format, in which case data.log comes back as usual)
function S:fetchLog(from, cb, compact)
  local id = self.gameId
  K.get("/games/" .. id .. "/log?from=" .. from .. (compact and "&fmt=c" or ""), function(err, data)
    if err or not data then cb(err or { message = "no data" }) return end
    local log = data.log or {}
    if compact and data.logc then cb(nil, data, log) return end
    -- fixtures (and old servers) ignore ?from= and send the whole log
    if data.from == nil and from > 0 then
      local sl = {}
      for i = from + 1, #log do sl[#sl + 1] = log[i] end
      log = sl
    end
    cb(nil, data, log)
  end, { fresh = true, ttl = 0 })
end

local function lt(self, what)
  local now = playdate.getCurrentTimeMilliseconds()
  print(string.format("[bcload] %-10s +%d ms", what, now - (self.loadT0 or now)))
  self.loadT0 = now
end

-- detail (slim "?lite=1") and the compact log are fetched in parallel; the log is one string
-- (see TL.decodeC) that the loader parses a few events at a time
function S:loadAll()
  local id = self.gameId
  self.loadT0 = playdate.getCurrentTimeMilliseconds()
  self.loadMsg = "DIALING THE PRESS BOX..."
  local gotDetail, gotLog = false, false
  local events, chunks, nC = {}, {}, 0
  local function ready()
    if not (gotDetail and gotLog) or self.closed or self.mode == "error" then return end
    self.status = (self.logData and self.logData.status) or (self.detail and self.detail.status) or "final"
    self:onLog(events, #chunks > 0 and table.concat(chunks, "\n") or nil, nC)
  end
  K.get("/games/" .. id .. "?lite=1", function(err, detail)
    if self.closed then return end
    lt(self, "detail")
    self.detail = (not err) and detail or nil
    gotDetail = true
    ready()
  end)
  local function page(from)
    self:fetchLog(from, function(err2, data, log)
      if self.closed then return end
      if err2 then self:fail((err2.message or err2.error or "replay unavailable")) return end
      for _, e in ipairs(log) do events[#events + 1] = e end
      if data.logc and data.logc ~= "" then chunks[#chunks + 1] = data.logc; nC = nC + (data.n or 0) end
      self.logData = self.logData or data
      if data.next and (#log > 0 or data.logc) then
        self.loadMsg = "RECEIVING... " .. (#events + nC) .. " PLAYS"
        page(data.next)
      else
        lt(self, "log")
        gotLog = true
        ready()
      end
    end, true)
  end
  page(0)
end

function S:onLog(events, logc, nC)
  local d = self.detail or {}
  local data = self.logData or {}
  local meta = {
    people = data.people or {},
    park = data.park or {},
    home = d.home, away = d.away,
    bet = d.myBet,
    pays = d.pool and d.pool.pays,
  }
  deriveTeams(meta, events)
  self.meta = meta
  self.tl = TL.new(meta)
  -- the timeline is built incrementally (TL.append in small chunks): enough to start during
  -- the load, the rest in the background while the replay plays (see pumpTimeline)
  self.pendingEv, self.pendingI = events, 1
  -- compact log: parsed lazily (pendC.pos = byte cursor), before any list events
  self.pendC = logc and { s = logc, pos = 1, left = nC or 0 } or nil
  if #events == 0 and not self.pendC then
    if self.status == "live" or self.status == "scheduled" then self.mode = "waiting" else self:fail("no plays in this replay") end
    return
  end
  self.bgQueue = {}
  self.live3d = R3.live()
  if not self.live3d then
    for _, n in ipairs(CAM_ORDER) do self.bgQueue[#self.bgQueue + 1] = n end
  end
  self.mode = "building"
  self.loadMsg = "BUILDING THE BALLPARK..."
  self.loadProg = 0
  self.loadCo = coroutine.create(function() self:loadWork() end)
  K.get("/games/" .. self.gameId .. "/wire", function(err, w)
    if self.closed or err or not w or not self.tl then return end
    TL.setWire(self.tl, w.lines)
  end)
end

--- pending events left to fold into the timeline
function S:timelinePending()
  return (self.pendC ~= nil and self.pendC.pos <= #self.pendC.s) or (self.pendingEv ~= nil and self.pendingI <= #self.pendingEv)
end
function S:pendingCount()
  local n = 0
  if self.pendC then n = n + self.pendC.left end
  if self.pendingEv then n = n + #self.pendingEv - self.pendingI + 1 end
  return n
end
--- next pending event (compact string first, then the list), or nil
function S:nextPending()
  local c = self.pendC
  if c and c.pos <= #c.s then
    local ev
    ev, c.pos = TL.decodeC(c.s, c.pos)
    c.left = c.left - 1
    if c.pos > #c.s then self.pendC = nil end
    return ev
  end
  self.pendC = nil
  local l = self.pendingEv
  if l and self.pendingI <= #l then
    local e = l[self.pendingI]
    self.pendingI = self.pendingI + 1
    return e
  end
  return nil
end

--- Fold pending log events into the timeline, one event at a time, until the budget (ms) is
--- spent (or maxEv done); then one settle (provisional plan + layout) for the frame.
--- On the device an event costs ~2-3 ms of Lua (planning), so small budgets stay small.
function S:pumpTimeline(budgetMs, maxEv)
  if not self:timelinePending() then return false end
  local t0 = playdate.getElapsedTime()
  local done = 0
  local one = self.oneEv or {}
  self.oneEv = one
  local budget = budgetMs / 1000
  repeat
    one[1] = self:nextPending()
    if not one[1] then break end
    TL.append(self.tl, one, true)
    done = done + 1
  until not self:timelinePending() or playdate.getElapsedTime() - t0 >= budget or (maxEv and done >= maxEv)
  TL.settle(self.tl)
  self.pumpMs = (playdate.getElapsedTime() - t0) * 1000
  if not self:timelinePending() then
    self.pendingEv = nil
    if self.tl.wireLines then TL.setWire(self.tl, self.tl.wireLines) end
    self:resetTicker(true)
    lt(self, "timeline")
    if self.skipWhenLoaded then self.skipWhenLoaded = false; self:skipToEnd() end
  end
  return true
end

-- the load, as a coroutine resumed once per frame with a time slice, so the splash keeps
-- animating at 30 fps: first innings of the timeline, the park, crowd art, pre-warmed caches
function S:loadWork()
  local function Y()
    if playdate.getCurrentTimeMilliseconds() - self.sliceT0 >= self.sliceMs then coroutine.yield() end
  end
  self.Y = Y
  -- enough of the timeline for the first at-bats (a live game needs all of it: we join at the head)
  local live = self.status == "live"
  while self:timelinePending() and (live or #self.tl.beats < 40) do
    self:pumpTimeline(self.sliceMs, 24)
    self.loadProg = 0.25 * math.min(1, #self.tl.beats / 40)
    coroutine.yield()
  end
  lt(self, "tl-first")
  if #self.tl.beats == 0 then
    if self.status == "live" or self.status == "scheduled" then self.mode = "waiting" else self:fail("no plays in this replay") end
    return
  end
  -- the park
  self.loadMsg = "BUILDING THE BALLPARK..."
  if self.live3d then
    self.R = R3.newLive(self.meta.park, function() self.loadProg = math.min(0.7, self.loadProg + 0.01); Y() end)
  else
    self.R = R3.newStatic(self.meta.park)
    for _, n in ipairs(CAM_ORDER) do Cam.ensureBg(self.R.rig[n], self.meta.park); self.loadProg = self.loadProg + 0.08; Y() end
  end
  lt(self, "park")
  self.loadProg = 0.75
  Y()
  Crowd.ensure(self.meta.home and self.meta.home.abbr)
  Y()
  lt(self, "crowd")
  self:prewarm(Y)
  lt(self, "prewarm")
  self.loadProg = 1
end

--- Pre-warm what the first shots would otherwise allocate mid-replay, one heavy item per
--- frame (each is timed into the [bcload] log so a hardware tour shows what's slow):
---  * the crowd photos the bleacher cutaways will use (a game uses at most two cheering, one
---    calm and one per incident kind, all known from the log up front)
---  * the puppets' scaled sprite sizes: dry-run draws of the first pitch and the first ball in
---    play with bc3d collecting (nothing drawn), then bc3d.warmNext builds them one at a time
function S:prewarm(Y)
  local tl = self.tl
  local function step(label, fn)
    local t = playdate.getCurrentTimeMilliseconds()
    fn()
    local now = playdate.getCurrentTimeMilliseconds()
    print(string.format("[bcload]   %-24s %d ms", label, now - t))
    -- cheap items share a frame; once 10 ms of it are gone, the next (maybe heavy) item waits
    -- for a fresh frame, so no slice runs much past ~10 ms + one item
    if now - self.sliceT0 >= 10 then coroutine.yield() end
  end
  step("photo cheer 0", function() Crowd.warm(true, nil, 0) end)
  step("photo cheer 1", function() Crowd.warm(true, nil, 1) end)
  step("photo calm", function() Crowd.warm(false, nil, 0) end)
  local seen = {}
  local function inc(kind)
    if kind and not seen[kind] then
      seen[kind] = true
      step("photo " .. kind, function() Crowd.warm(kind ~= "BRAWL", kind, 0) end)
    end
  end
  for _, e in ipairs(tl.log) do if e.k == "inc" then inc(e.kind) end end
  for _, e in ipairs(self.pendingEv or {}) do if e.k == "inc" then inc(e.kind) end end
  if self.pendC then for kind in ("\n" .. self.pendC.s):gmatch("\ninc\tkind=([^\t\n]+)") do inc(kind) end end
  -- samples load from disk on first play (a stall mid-replay on the device): play each crowd /
  -- contact sound once, silently, now
  local X = Audio.ext and Audio.ext()
  if X and X.sfx then
    for _, n in ipairs({ "crowd_roar", "crowd_roar_2", "crowd_cheer", "crowd_ooh", "crowd_groan", "crowd_boo", "crowd_boo_2",
      "applause", "crowd_clap", "bat_crack", "mitt_pop" }) do
      step("sfx " .. n, function() pcall(X.sfx, n, 0) end)
    end
  end
  TV.prepare(self, step)
  if not self.live3d or not bc3d.collect then return end
  local view = { defV = "home", offV = "away", people = self.meta.people }
  local done = {}
  bc3d.collect(true)
  -- (+ the first changeover: both teams on the move, ~20 puppets in poses nothing else uses;
  -- registering them at the cut was a 60-130 ms frame on the device)
  local TAUS <const> = { p = { 0.3, 1.2 }, bip = { 0.3, 1.2 }, halfT = { 0.05, 0.8, 1.6, 2.4, 3.2 }, halfB = { 0.05, 0.8, 1.6, 2.4, 3.2 } }
  for i, b in ipairs(tl.beats) do
    -- (a changeover each way: top and bottom swap who jogs in and who trots out)
    local hk = b.kind == "half" and (b.pre.top and "halfT" or "halfB") or nil
    local want = (b.kind == "p" and not done.p) and "p" or (b.kind == "bip" and not done.bip) and "bip"
      or (hk and not done[hk]) and hk or nil
    if want then
      done[want] = true
      for _, tau in ipairs(TAUS[want]) do
        for _, v in ipairs({ "home", "away" }) do
          step("dry run " .. want .. " " .. v .. " " .. tau, function()
            view.defV, view.offV = v, v == "home" and "away" or "home"
            local cc = Play.camAt(b.plan, tau)
            self.R:setCamera(R3.shot(self.R, b, tau, cc))
            Play.drawWorld(self.R, view, b, tau)
          end)
        end
      end
    end
    if done.p and done.bip and done.halfT and done.halfB then break end
  end
  bc3d.collect(false)
  local t, built = playdate.getCurrentTimeMilliseconds(), 0
  while bc3d.warmNext() > 0 do
    built = built + 1
    Y()
  end
  print(string.format("[bcload]   %-24s %d ms (%d sizes)", "sprite sizes", playdate.getCurrentTimeMilliseconds() - t, built))
  gfx.clear(gfx.kColorWhite)
end

function S:afterBuild()
  local live = self.status == "live"
  if live then
    self.mode = "watch"
    self.live = true
    self.playing = true
    -- join near the head: back up to the start of the current at-bat
    local tl = self.tl
    local pa = tl.paIdx[#tl.paIdx]
    self.t = pa and tl.beats[pa].start or 0
    self:startPolling()
  else
    self.mode = self.args.skipIntro and "watch" or "intro"
    self.menuSel = 1
    self.t = 0
    self.playing = self.mode == "watch"
  end
  self:resetTicker(true)
  self:addMenu()
  self.hintUntil = playdate.getCurrentTimeMilliseconds() + 3000
end

function S:startPolling()
  if self.pollTimer or self.src then return end
  self.pollTimer = playdate.timer.keyRepeatTimerWithDelay(POLL_MS, POLL_MS, function() self:poll() end)
end

function S:poll()
  if self.polling or not self.tl then return end
  self.polling = true
  local have = #self.tl.log + self:pendingCount()
  self:fetchLog(have, function(err, data, log)
    self.polling = false
    if self.closed or err then return end
    if #log > 0 then
      if self:timelinePending() then
        self.pendingEv = self.pendingEv or {}
        for _, e in ipairs(log) do self.pendingEv[#self.pendingEv + 1] = e end
      else
        TL.append(self.tl, log)
      end
      if #log > 0 and self.wirePending == nil then
        self.wirePending = true
        K.get("/games/" .. self.gameId .. "/wire", function(e2, w)
          self.wirePending = nil
          if not e2 and w and self.tl then TL.setWire(self.tl, w.lines) end
        end, { fresh = true, ttl = 0 })
      end
    end
    if data.status == "final" then
      self.status = "final"
      if self.pollTimer then self.pollTimer:remove(); self.pollTimer = nil end
    end
  end)
end

--- Local sources: append new events to a live game (what poll() does for the network).
function S:feed(events)
  if not self.tl or #events == 0 then return end
  if self:timelinePending() then
    self.pendingEv = self.pendingEv or {}
    for _, e in ipairs(events) do self.pendingEv[#self.pendingEv + 1] = e end
  else
    TL.append(self.tl, events)
  end
  for _, e in ipairs(events) do if e.k == "end" then self.status = "final" end end
end

--- Local sources: remove the open last beat when it is a single event (a provisional pitch the
--- source is about to replace with the real one). Its replacement keeps the same log index, so
--- the pitch's flight is identical and playback carries on seamlessly. Returns true if removed.
function S:dropLast()
  local tl = self.tl
  if not tl or self:timelinePending() then return false end
  local b = tl.beats[#tl.beats]
  if not b or b.i ~= #tl.log or b.kind ~= "p" then return false end
  table.remove(tl.beats)
  tl.log[#tl.log] = nil
  local prev = tl.beats[#tl.beats]
  if prev then tl.st = TL.copyState(prev.post) end
  tl.settledKey = nil
  TL.layout(tl)
  self.lastBeat = nil
  return true
end

---------------------------------------------------------------------------
-- scene lifecycle

function S:enter(args)
  self.args = args or {}
  self.gameId = self.args.gameId or "g1"
  self.src = self.args.source
  K.source = self.src
  self.closed = false
  self.mode = "loading"
  self.t, self.speed, self.playing = 0, 1, false
  self.R, self.camCur, self.camShot = nil, nil, nil
  self.tl, self.rig, self.detail, self.logData, self.meta = nil, nil, nil, nil, nil
  self.live = false
  self.highlights = false
  self.lastBeat, self.lastTau = nil, 0
  self.curCam, self.panX, self.panY = nil, 0, 0
  self.scrubT = 0
  self.bannerKey = nil
  self.lastMs = playdate.getCurrentTimeMilliseconds()
  self.tickerBeat = -1
  K.DEBUG = self.args.debug and true or K.DEBUG
  -- a replay is watched hands-off: don't let the device lock mid-inning
  playdate.setAutoLockDisabled(true)
  Audio.start()
  TV.reset(self)
  self:loadAll()
end

function S:exit()
  self.closed = true
  if self.src and K.source == self.src then K.source = nil end
  playdate.setAutoLockDisabled(false)
  if self.pollTimer then self.pollTimer:remove(); self.pollTimer = nil end
  self:removeMenu()
  Audio.stop()
  -- release big images
  if self.R then self.R:release() end
  self.R = nil
  self.tl = nil
  BallCast.Puppets.release()
  Crowd.release()
  TV.release()
  HUD.release()
  BallCast.Tags.release()
  Log.release()
  self.logOpen = false
  gfx.setDrawOffset(0, 0)
end

function S:pause() playdate.setAutoLockDisabled(false); Audio.stop(); self:removeMenu() end
function S:resume() playdate.setAutoLockDisabled(true); Audio.start(); self:addMenu() end

-- system menu: game log, nametags on/off, skip to end (the Playdate allows three)
function S:addMenu()
  if self.menuItem or not self.tl then return end
  local menu = playdate.getSystemMenu()
  local ok, item = pcall(function()
    return menu:addMenuItem("skip to end", function() self:skipToEnd() end)
  end)
  if ok then self.menuItem = item end
  ok, item = pcall(function()
    return menu:addMenuItem("game log", function() if self.mode == "watch" then self:openLog() end end)
  end)
  if ok then self.menuLog = item end
  ok, item = pcall(function()
    return menu:addCheckmarkMenuItem("nametags", self.tagsOn ~= false, function(v) self.tagsOn = v end)
  end)
  if ok then self.menuTags = item end
end

function S:removeMenu()
  for _, k in ipairs({ "menuItem", "menuLog", "menuTags" }) do
    if self[k] then
      local it = self[k]
      pcall(function() playdate.getSystemMenu():removeMenuItem(it) end)
      self[k] = nil
    end
  end
end

-- game log: hold A (or the system menu); playback pauses underneath
function S:openLog()
  if not self.tl or self.logOpen then return end
  self.logWasPlaying = self.playing
  self.playing = false
  Log.open(self)
  self.logOpen = true
  K.sfx("click")
end

function S:closeLog(jumpTo)
  Log.close()
  self.logOpen = false
  if jumpTo then
    -- back to the start of that at-bat
    local tl = self.tl
    local target = jumpTo
    for j = #tl.paIdx, 1, -1 do if tl.paIdx[j] <= jumpTo then target = tl.paIdx[j] break end end
    if tl.beats[jumpTo].kind == "half" or tl.beats[jumpTo].kind == "inc" then target = jumpTo end
    self:seekBeat(target)
    self.playing = true
  else
    self.playing = self.logWasPlaying
  end
  K.sfx("tick")
end

---------------------------------------------------------------------------
-- navigation

function S:curBeatIndex() return self.tl and TL.beatAt(self.tl, self.t) or nil end

function S:seekBeat(i, instant)
  local b = self.tl.beats[i]
  if not b then return end
  self.t = b.start
  self.lastBeat = nil
  self:resetTicker(true)
end

function S:skipToEnd()
  if not self.tl or #self.tl.beats == 0 then return end
  if self:timelinePending() then
    -- the end isn't built yet: jump there as soon as it is
    self.skipWhenLoaded = true
    self.mode = "watch"
    return
  end
  self.mode = "watch"
  local beats = self.tl.beats
  local last = beats[#beats]
  if last.kind == "end" then self:seekBeat(#beats) else self.t = self.tl.total end
  self.playing = true
end

function S:resetTicker(instant)
  self.tickerBeat = -1
  self.tickerInstant = instant
end

local function isHighlight(b)
  return (b.runs and b.runs > 0) or b.big or b.kind == "inc" or b.kind == "end" or b.walkoff
end

---------------------------------------------------------------------------
-- input

-- A local source (Pennant) may own every input: then nothing below reaches the replay controls
-- (seek, scrub, speed, pause, the game log, the intro menu, B = leave), in any mode.
local function hook(self, name, ...)
  local src = self.src
  if not src then return false end
  if src.input and self.mode == "watch" then
    if src:input(self, name, ...) then return true end
  end
  return src.ownsInput == true
end

function S:AButtonDown()
  if hook(self, "A") then return end
  if self.mode == "intro" then
    local sel = self.menuSel
    self.mode = "watch"
    self.playing = true
    if sel == 2 then self.highlights = true; self.t = 0
    elseif sel == 3 then self:skipToEnd() end
    K.sfx("click")
    return
  end
  if self.mode == "error" then App.pop() return end
  if self.mode ~= "watch" then return end
  if TV.interrupt() then return end
  if self.logOpen then self:closeLog(Log.pick()) return end
  -- tap = play/pause (on release); hold = game log (see update)
  self.aDownAt = playdate.getCurrentTimeMilliseconds()
end

function S:AButtonUp()
  if hook(self, "AUp") then self.aDownAt = nil return end
  if not self.aDownAt then return end
  self.aDownAt = nil
  if self.mode ~= "watch" or self.logOpen then return end
  self.playing = not self.playing
  self.hintUntil = playdate.getCurrentTimeMilliseconds() + 3000
  K.sfx("tick")
end

function S:BButtonDown()
  if Play.skipChangeover and Play.skipChangeover(self) then return end   -- (local games: B skips it)
  if hook(self, "B") then return end
  TV.interrupt()
  if self.logOpen then self:closeLog() return end
  App.pop()
end

function S:upButtonDown()
  if hook(self, "up") then return end
  TV.interrupt()
  if self.mode == "intro" then self.menuSel = (self.menuSel - 2) % 3 + 1; K.sfx("tick") return end
  if self.mode ~= "watch" then return end
  if self.logOpen then Log.move(-1); K.sfx("tick") return end
  local tl = self.tl
  local cur = self:curBeatIndex() or 1
  local target = nil
  for j = #tl.paIdx, 1, -1 do
    local bi = tl.paIdx[j]
    if bi < cur or (bi == cur and false) then
      -- if we're more than a moment into this PA, restart it; else go to the previous one
      target = bi
      local into = self.t - tl.beats[bi].start
      if into < 2.0 and j > 1 then
        -- find the PA before the current one
        local curPa = nil
        for jj = #tl.paIdx, 1, -1 do if tl.paIdx[jj] <= cur then curPa = jj break end end
        if curPa and tl.paIdx[curPa] == bi and curPa > 1 then target = tl.paIdx[curPa - 1] end
      end
      break
    elseif bi == cur then
      target = (j > 1) and tl.paIdx[j - 1] or bi
      break
    end
  end
  if target then self:seekBeat(target) end
  K.sfx("tick")
end

function S:downButtonDown()
  if hook(self, "down") then return end
  TV.interrupt()
  if self.mode == "intro" then self.menuSel = self.menuSel % 3 + 1; K.sfx("tick") return end
  if self.mode ~= "watch" then return end
  if self.logOpen then Log.move(1); K.sfx("tick") return end
  local tl = self.tl
  local cur = self:curBeatIndex() or 1
  for _, bi in ipairs(tl.paIdx) do
    if bi > cur then self:seekBeat(bi); K.sfx("tick") return end
  end
  -- no more at-bats: go to the end (or the live head)
  self.t = tl.total
  K.sfx("tick")
end

local function speedIndex(s) for i, v in ipairs(SPEEDS) do if v == s then return i end end return 1 end

function S:leftButtonDown()
  if hook(self, "left") then return end
  TV.interrupt()
  if self.mode ~= "watch" then return end
  if self.logOpen then Log.move(-8) return end
  self.speed = SPEEDS[max(1, speedIndex(self.speed) - 1)]
  self.speedShown = playdate.getCurrentTimeMilliseconds()
  K.sfx("tick")
end

function S:rightButtonDown()
  if hook(self, "right") then return end
  TV.interrupt()
  if self.mode ~= "watch" then return end
  if self.logOpen then Log.move(8) return end
  self.speed = SPEEDS[min(#SPEEDS, speedIndex(self.speed) + 1)]
  self.speedShown = playdate.getCurrentTimeMilliseconds()
  K.sfx("tick")
end

function S:cranked(change)
  if hook(self, "crank", change) then return end
  if self.mode == "intro" then
    self.crankAcc = (self.crankAcc or 0) + change
    if abs(self.crankAcc) > 40 then
      self.menuSel = (self.menuSel - 1 + (self.crankAcc > 0 and 1 or -1)) % 3 + 1
      self.crankAcc = 0
      K.sfx("tick")
    end
    return
  end
  if self.mode ~= "watch" or not self.tl then return end
  TV.interrupt()
  if self.logOpen then Log.crank(change) return end
  -- 12 seconds of replay per turn, faster when you spin it
  local mult = abs(change) > 20 and 3 or 1
  self.t = K.clamp(self.t + change / 360 * 12 * mult, 0, self.tl.total)
  self.scrubT = playdate.getCurrentTimeMilliseconds()
end

---------------------------------------------------------------------------
-- decision angles (a local source waiting on its player: see S:update)

-- Held angles with a stepped push-in (each step a cut, animatic style: most frames hold the camera
-- exactly, so the park render cache reuses the frame). R3.shot "decision" frames them and checks the
-- batter and the pitcher are both in the picture (else the next angle).
local DECISION <const> = { "overShoulder", "catcherView", "lowBox", "dugoutLook" }
local DEC_HOLD <const>, DEC_STEP <const> = 4.8, 0.8
function S:decisionCam(b)
  local it = self.idleT or 0
  local d = self.decision
  if not d then
    d = { k = floor(K.hash01(b.i or 1, 91) * #DECISION) }
    self.decision = d
  end
  local idx = floor(it / DEC_HOLD)
  local step = floor((it - idx * DEC_HOLD) / DEC_STEP)
  local key = idx * 100 + step
  if d.key ~= key then
    d.key = key
    d.cc = { name = "decision", opt = { kind = DECISION[(d.k + idx) % #DECISION + 1], step = step, side = (idx % 2 == 0) and 1 or -1, i = idx,
      bat = self.src and self.src.idleBatter and self.src:idleBatter() or nil } }
    -- the free strip of the screen (the source's panels cover the rest)
    if self.src and self.src.decisionFrame then d.cc.opt.x0, d.cc.opt.x1 = self.src:decisionFrame() end
    -- a murmur now and then while they wait
    if step == 0 and idx > 0 and K.hash01(b.i or 1, idx) < 0.5 then Audio.sfx(K.hash01(idx, 7) < 0.6 and "c_murmur" or "c_clap", 0.3) end
  end
  return d.cc
end

---------------------------------------------------------------------------
-- per-frame

local function stateShown(b, tau)
  local plan = b.plan
  if plan.pitch then
    if tau > plan.pitch.tPlate + 0.25 then return b.post end
    return b.pre
  end
  if b.kind == "bip" or b.kind == "sb" or b.kind == "wp" or b.kind == "mv" then
    if tau >= b.dur - 1.1 then return b.post end
    return b.pre
  end
  return tau > 0.2 and b.post or b.pre
end

local function revealT(b)
  if b.kind == "bip" then return max(0.5, b.dur - 1.6) end
  if b.plan.pitch then return b.plan.pitch.tPlate + 0.3 end
  return 0.3
end

function S:describe(i)
  local b = self.tl.beats[i]
  if b.desc == nil then b.desc = TL.describe(self.tl, b) or false end
  return self.tl.wire[i] or (b.desc or nil)
end

function S:updateTicker(bi, tau)
  local b = self.tl.beats[bi]
  local show = bi
  if tau < revealT(b) then show = bi - 1 end
  if show == self.tickerBeat then return end
  local seq = show == self.tickerBeat + 1 or (self.tickerBeat >= 0 and show > self.tickerBeat and show - self.tickerBeat < 4)
  self.tickerBeat = show
  local lines = {}
  local i = show
  local guard = 0
  while i >= 1 and #lines < 3 and guard < 80 do
    local s = self:describe(i)
    if s then table.insert(lines, 1, s) end
    i = i - 1
    guard = guard + 1
  end
  if #lines == 0 then
    local m = self.meta
    lines[1] = "BALLCAST 3D ... " .. (m.away and m.away.abbr or "") .. " AT " .. (m.home and m.home.abbr or "") .. (m.park and m.park.name and (" ... " .. string.upper(m.park.name)) or "")
  end
  HUD.tickerSet(lines, self.tickerInstant or not seq)
  self.tickerInstant = false
end

function S:update()
  local now = playdate.getCurrentTimeMilliseconds()
  local dt = min(0.1, (now - self.lastMs) / 1000)
  self.lastMs = now
  gfx.clear(gfx.kColorWhite)

  if self.mode == "loading" or self.mode == "waiting" or self.mode == "error" then
    self:drawSplash()
    return
  end
  if self.mode == "building" then
    -- resume the loader for a slice of this frame, then draw the (animated) splash
    self.sliceT0, self.sliceMs = now, 22
    if self.loadCo and coroutine.status(self.loadCo) ~= "dead" then
      local ok, err = coroutine.resume(self.loadCo)
      if not ok then print("[ballcast] load failed: " .. tostring(err)); self:fail("couldn't build the ballpark") end
    end
    local spent = playdate.getCurrentTimeMilliseconds() - now
    self.loadMaxSlice = math.max(self.loadMaxSlice or 0, spent)
    self.loadFrames = (self.loadFrames or 0) + 1
    if self.mode == "building" and self.loadCo and coroutine.status(self.loadCo) == "dead" then
      self.loadCo = nil
      self:afterBuild()
      lt(self, "first frame")
      print(string.format("[bcload] %d loader frames, longest slice %d ms, %d events still to fold in",
        self.loadFrames, self.loadMaxSlice, self:pendingCount()))
    end
    gfx.clear(gfx.kColorWhite)
    self:drawSplash()
    return
  end

  if self.mode == "intro" then
    self:drawIntro()
    Audio.update(false)
    TV.idle(now, 18)   -- (DBN prerender queue: the menu is idle time)
    self:backgroundLoad(now, 24)
    return
  end

  -- hold A for the game log
  if self.aDownAt and not self.logOpen and now - self.aDownAt > 450 then
    self.aDownAt = nil
    self:openLog()
  end

  -- advance time
  local tl = self.tl
  local scrubbing = (now - self.scrubT) < 250
  local bi = TL.beatAt(tl, self.t)
  local b = tl.beats[bi]
  local tau = self.t - b.start
  local slo = b.plan.slo and tau >= b.plan.slo[1] and tau <= b.plan.slo[2]
  local srcRate = self.src and self.src.frame and self.src:frame(self, bi, b, tau, dt)
  if self.src then
    -- (the source may have fed or taken back beats)
    bi = TL.beatAt(tl, math.min(self.t, tl.total))
    b = tl.beats[bi]
    tau = self.t - b.start
  end
  if self.playing and not scrubbing and not TV.holding() then
    local rate = self.speed * (slo and 0.3 or 1) * (srcRate or 1)
    if self.live then
      -- don't let a live game run dry: slow down as we near the head, speed up if behind
      local ahead = tl.total - self.t
      if ahead > 90 and self.speed == 1 then rate = 2 end
    end
    self.t = self.t + dt * rate
    if self.t >= tl.total then
      self.t = tl.total
      if not self.live and self.status ~= "live" then self.playing = (self.t < tl.total) end
    end
    -- highlights: hop over quiet beats
    if self.highlights then
      local nb = TL.beatAt(tl, self.t)
      local cb = tl.beats[nb]
      if not isHighlight(cb) then
        local j = nb + 1
        while j <= #tl.beats and not isHighlight(tl.beats[j]) do j = j + 1 end
        if j <= #tl.beats then
          -- include the at-bat's lead-in pitch for context
          local tgt = j
          if tl.beats[j - 1] and tl.beats[j - 1].kind == "p" and tl.beats[j].kind == "bip" then tgt = j - 1 end
          if tgt > nb then self.t = tl.beats[tgt].start; self.lastBeat = nil; self:resetTicker(true) end
        end
      end
    end
    bi = TL.beatAt(tl, self.t)
    b = tl.beats[bi]
    tau = self.t - b.start
  end
  if tau > b.dur then tau = b.dur end
  slo = b.plan.slo and tau >= b.plan.slo[1] and tau <= b.plan.slo[2]

  -- sound cues (only for normal forward playback)
  local quiet = scrubbing or not self.playing or self.speed > 2
  if quiet and not self.wasQuiet then Audio.sfx("stopMusic") end
  self.wasQuiet = quiet
  if bi ~= self.lastBeat then
    if self.lastBeat and bi == self.lastBeat + 1 and not quiet then
      if b.kind == "half" and not b.e.top and b.e.inn == 7 then Audio.sfx("stretch")
      elseif b.kind == "half" and (b.e.inn >= 7 or K.hash01(bi, 77) < 0.25) and not b.e.top then Audio.sfx("organ") end
      if b.kind == "pa" and K.hash01(bi, 5) < 0.06 then Audio.sfx("walkup") end
      if b.kind == "end" then
        local e = b.e
        if math.abs(e.home - e.away) >= 6 and e.home < e.away then Audio.sfx("blowout") elseif e.home > e.away then Audio.sfx("win") end
      end
      self.lastTau = -0.001
    else
      self.lastTau = tau
    end
    self.lastBeat = bi
  end
  if not quiet then
    local cues = b.plan.sfx
    for i = 1, #cues do
      local c = cues[i]
      if c.t > self.lastTau and c.t <= tau then
        local v = c.v
        if Audio.REACT and Audio.REACT[c.kind] then
          -- crowd reactions scale with leverage: late, close, big win-chance swings
          local lev = 0.6 + min(0.4, abs((b.we or 0.5) - (b.weBefore or 0.5)) * 3) + ((b.pre.inn or 1) >= 7 and 0.1 or 0)
          v = (v or 0.8) * min(1, lev)
        end
        Audio.sfx(c.kind, v)
        self.sfxThisFrame = (self.sfxThisFrame and (self.sfxThisFrame .. ",") or "") .. c.kind
      end
    end
  end
  self.lastTau = tau
  Audio.update(quiet)

  -- a local source waiting on its player with the clock held (Pennant: the dugout's call, the
  -- approach, the pitch): the world stays alive (Play: idle puppets; decision camera angles)
  local idle = self.src and self.src.idleDecision and self.src:idleDecision(self)
  if idle then self.idleT = (self.idleT or 0) + dt else self.idleT, self.decision = nil, nil end

  -- the decision idle runs the world at 15 fps (animatic, and half the cost): every other frame
  -- re-shows the last rendered one, with the source's panels drawn live on top
  if self.idleT then
    self.idleFrame = (self.idleFrame or 0) + 1
    if self.idleFrame % 2 == 1 and self.idleImg then
      self.idleImg:draw(0, 0)
      if self.src.draw then self.src:draw(self, bi, b, tau) end
      self:backgroundLoad(now, 27)
      return
    end
  else
    self.idleImg, self.idleFrame = nil, nil
  end

  -- a local source may freeze the picture under a static panel (time-out menu, final card):
  -- blit the last rendered frame instead of re-rendering the world
  local frz = self.src and self.src.freeze and self.src:freeze(self, bi, b, tau)
  if not frz then self.frozenImg = nil
  elseif self.frozenImg then
    self.frozenImg:draw(0, 0)
    if self.src.draw then self.src:draw(self, bi, b, tau) end
    self:backgroundLoad(now, 27)
    return
  end

  -- TV presentation (ballcast/tv): a running segment (replay, cards, open) owns the frame
  if TV.frame(self, bi, b, tau, dt, scrubbing) then
    self:backgroundLoad(now, 27)
    return
  end

  -- camera
  local cc = Play.camAt(b.plan, tau)
  if self.idleT and self.idleT > 0.4 then cc = self:decisionCam(b) end
  local camName = cc.name
  local incident = (b.kind == "inc") and b.e.kind or (cc.opt and cc.opt.incident)
  local shakeX, shakeY = 0, 0
  local still = Game and Game.settings and Game.settings.reduceMotion
  if b.plan.shake and not still and tau >= b.plan.shake and tau < b.plan.shake + 0.9 then
    local a = floor((1 - (tau - b.plan.shake) / 0.9) * 4 + 0.5)
    shakeX, shakeY = math.random(-a, a), math.random(-a, a)
  end
  -- impact kick on hard contact / wall hits (juice.lua; deterministic, off with reduceMotion)
  local kx, ky = BallCast.Juice.kick(b, tau)
  shakeX, shakeY = shakeX + kx, shakeY + ky
  if camName == "bleacher" then
    -- the latest canned reaction (from the plan, so scrubbing shows it too) for the text pops
    local rk, rage = nil, 0
    for i = 1, #b.plan.sfx do
      local c = b.plan.sfx[i]
      if Audio.REACT and Audio.REACT[c.kind] and c.t <= tau and tau - c.t < 2.5 then rk, rage = c.kind, tau - c.t end
    end
    local cheer = cc.opt and cc.opt.cheer
    local tw = playdate.getElapsedTime()
    Crowd.draw(tau, cheer, incident, self.meta.home and self.meta.home.abbr, (cheer and not incident) and (bi % 2) or 0, rk, rage)
    self.profWorld = (playdate.getElapsedTime() - tw) * 1000
  else
    local R = self.R
    if self.live3d then
      local want = R3.shot(R, b, tau, cc, self.camWant)
      self.camWant = want
      local cur = self.camCur
      self.cutThisFrame = cc ~= self.camShot
      if not cur or cc ~= self.camShot or scrubbing or not self.playing then
        cur = cur or {}
        for k = 1, 7 do cur[k] = want[k] end
      else
        local k = cc.opt and cc.opt.establish and 1 or 0.22
        for i = 1, 6 do cur[i] = cur[i] + (want[i] - cur[i]) * k end
        cur[7] = cur[7] + (want[7] - cur[7]) * 0.15
      end
      self.camCur = cur
      self.camShot = cc
      R:setCamera(cur)
      -- fast-moving tracking shots: crowd photo textures fall back to the cheap animated
      -- crowd-noise fill (the textured stands cost ~20 ms on device when they fill the frame)
      -- (the blimp, dugout and wall-level shots are mostly stands too)
      local cheap = camName:sub(1, 4) == "deep" or camName == "blimp" or camName == "dugout" or camName == "wallLow"
      if bc3d.quality then bc3d.quality(cheap and 0 or 600) end
      R:background(shakeX, shakeY, Audio.level and Audio.level() or 0.3)
    else
      R:use(camName)
      R:background(shakeX, shakeY)
    end
    local top = b.pre.top
    local view = self.view or {}
    self.view = view
    view.defV = top and "home" or "away"
    view.offV = top and "away" or "home"
    view.incident = incident
    view.brawl = incident == "BRAWL" and camName == "high"
    view.people = self.meta.people
    view.tags = self.tagsOn ~= false
    view.idleT = self.idleT
    -- (who's up: at a pause between plays the timeline doesn't have him yet)
    view.idleBat = self.idleT and self.src and self.src.idleBatter and self.src:idleBatter() or nil
    local tw = playdate.getElapsedTime()
    Play.drawWorld(R, view, b, tau)
    self.profWorld = (playdate.getElapsedTime() - tw) * 1000
  end
  self.curCam = camName
  gfx.setDrawOffset(0, 0)

  local th = playdate.getElapsedTime()
  self:drawHud(bi, b, tau, slo, camName, incident, dt)
  TV.overlay(self, bi, b, tau, camName, slo, dt)
  if self.logOpen then Log.draw() end
  if frz and not self.frozenImg then self.frozenImg = gfx.getWorkingImage() end
  if self.idleT then self.idleImg = gfx.getWorkingImage() end
  if self.src and self.src.draw then self.src:draw(self, bi, b, tau) end
  self.profHud = (playdate.getElapsedTime() - th) * 1000
  self:backgroundLoad(now, 27)
  local spent = playdate.getCurrentTimeMilliseconds() - now
  local sfxNow = self.sfxThisFrame
  self.sfxThisFrame = nil
  if spent > 45 then
    -- where the time went, for the hardware tour: C park render, C billboard flush (+ how many
    -- sprite sizes it had to build), Lua world, HUD, background timeline fold, camera cut
    local rms, fms, built = 0, 0, 0
    if bc3d then local _, _, _, _, a, f, nb = bc3d.stats(); rms, fms, built = a or 0, f or 0, nb or 0 end
    print(string.format("[bcspike] %d ms cam=%s%s beat=%d(%s) tau=%.2f | render %.1f flush %.1f (+%d sprites) world %.1f hud %.1f fold %.1f sfx=%s",
      spent, tostring(camName), self.cutThisFrame and " CUT" or "", bi, b.kind, tau, rms, fms, built,
      self.profWorld or 0, self.profHud or 0, self.pumpMs or 0, sfxNow or "-"))
  elseif bc3d and bc3d.stats then
    bc3d.stats()   -- (resets the per-frame "sprites built" count)
  end
end

--- The rest of the timeline, folded in with whatever is left of this frame's ~33 ms
--- (target: finish the frame by `deadline` ms after it started).
function S:backgroundLoad(frameStart, deadline)
  if not self:timelinePending() then self.pumpMs = 0 return end
  local left = deadline - (playdate.getCurrentTimeMilliseconds() - frameStart)
  -- while a replay is actually playing, at most ~1.5 ms a frame (about one event on the
  -- device), so playback frame times don't move; paused, on the intro menu, in the game log
  -- or waiting on a skip-to-end, use whatever the frame has left
  local idle = self.mode == "intro" or not self.playing or self.logOpen or self.skipWhenLoaded
  -- (and not at all on a frame that's already heavy)
  if not idle and left < 9 then self.pumpMs = 0 return end
  local budget = idle and (left - 2) or math.min(1.5, left - 2)
  if self.skipWhenLoaded then budget = math.max(budget, 20) end
  if budget > 0 then self:pumpTimeline(budget) end
end

---------------------------------------------------------------------------
-- HUD composition

local function linePA(tl, bi, bat)
  -- "1-FOR-2 TODAY" from earlier PAs in this game
  local h, ab = 0, 0
  for i = 1, bi - 1 do
    local b = tl.beats[i]
    if b.pre.bat == bat then
      if b.kind == "bip" then
        local r = b.e.res
        if r ~= "SF" then ab = ab + 1 end
        if r == "1B" or r == "2B" or r == "3B" or r == "HR" then h = h + 1 end
      elseif b.kind == "p" and b.k then
        ab = ab + 1
      end
    end
  end
  if ab == 0 then return "FIRST TRIP TO THE PLATE" end
  return h .. "-FOR-" .. ab .. " TODAY"
end

function S:drawHud(bi, b, tau, slo, camName, incident, dt)
  local tl = self.tl
  local meta = self.meta
  local final = b.kind == "end" and tau > 0.3
  local st = stateShown(b, tau)
  local yOff = 0

  if slo then HUD.sloBar(tau) end
  HUD.scorebug(st, meta, final)

  -- pitch box
  local rightY = 2 + yOff
  if b.kind == "p" and tau > b.plan.pitch.tPlate + 0.1 then
    HUD.pitchBox(b.e.t, b.e.v, nil, rightY)
    rightY = rightY + 31
  end
  -- live / replay tag
  local tag
  if not self.playing then tag = "II PAUSED"
  elseif self.live and tl.total - self.t < 8 then tag = "* LIVE"
  elseif self.highlights then tag = "HIGHLIGHTS " .. self.speed .. "x"
  else tag = (self.live and "LIVE +" or "REPLAY ") .. self.speed .. "x" end
  HUD.tag(tag, 398, rightY, not self.playing)
  rightY = rightY + 13

  -- win chance
  local dWe = abs((b.we or 0.5) - (b.weBefore or 0.5))
  -- (on plays, only once the play is over: it used to sit on top of the first baseman)
  local showWe = (b.kind == "half" and tau > 0.6) or b.kind == "end" or (not self.playing and not self.logOpen)
    or (dWe >= 0.08 and tau > b.dur - (b.kind == "bip" and 1.1 or 2.6) and b.kind ~= "p")
  if (showWe and camName ~= "bleacher" and b.kind ~= "inc") or (b.kind == "end") then
    local bet = meta.bet
    local forHome = true
    local abbr = meta.home and meta.home.abbr
    if bet then forHome = bet.side == "home"; abbr = forHome and (meta.home and meta.home.abbr) or (meta.away and meta.away.abbr) end
    HUD.winPanel(tl, bi, abbr, forHome, bet, 266, 48)
  end

  -- lower thirds
  local people = meta.people or {}
  if b.kind == "pa" or (b.kind == "p" and b.pre.b == 0 and b.pre.s == 0 and tau < 1.2 and tl.beats[bi - 1] and tl.beats[bi - 1].kind == "pa") then
    local age = b.kind == "pa" and tau or (tau + tl.beats[bi - 1].dur)
    local p = people[b.pre.bat]
    if p and age < 3.2 then
      local pos = (p.pos or "") .. (p.teamAbbr and (" - " .. p.teamAbbr) or "")
      -- slides off before the windup gets going
      local out = b.kind == "p" and K.clamp((tau - 0.45) / 0.2, 0, 1) or 0
      if out < 1 then HUD.lowerThird(p.face, p.name or "?", pos, TV.lineToday(self, bi, b.pre.bat), age, out, TV.fact(self, bi, b.pre.bat)) end
    end
  elseif b.kind == "sub" then
    local p = people[b.e["in"]]
    if p then
      HUD.lowerThird(p.face, p.name or "?", b.e.pos == "P" and "NOW PITCHING" or ("NOW AT " .. (b.e.pos or "")), b.e.why and string.upper(b.e.why) or nil, tau)
    end
  elseif b.kind == "half" then
    local txt = (b.e.top and "TOP " or "BOT ") .. TL.ordinal(b.e.inn)
    HUD.bigBanner(txt, tau)
  elseif b.kind == "end" then
    HUD.bigBanner("FINAL", tau)
    self:drawFinalCard(b, tau)
  end

  -- incident callout
  if b.kind == "inc" then
    local txt = TL.describe(tl, b) or b.e.kind
    if b.e.note then txt = txt .. ". " .. b.e.note end
    HUD.callout(txt, tau)
  end

  -- big moment banner
  if b.big then
    local t0 = b.plan.bannerT or (b.plan.wallT and b.plan.wallT + 0.3) or (b.plan.slo and b.plan.slo[2]) or (b.dur * 0.45)
    if tau >= t0 and tau < t0 + 2.0 then HUD.bigBanner(b.big, tau - t0) end
  end

  -- speed change flash
  if self.speedShown and playdate.getCurrentTimeMilliseconds() - self.speedShown < 700 then
    local img = HUD.textImage(K.fonts.big, self.speed .. "x  >>", 8)
    img:draw(200 - img:getSize() / 2, 60)
  end

  -- ticker
  self:updateTicker(bi, tau)
  local typing = HUD.ticker(dt)
  if typing and not self.wasTyping and self.playing and self.speed <= 2 and Audio.ext and Audio.ext() then Audio.sfx("telegraph") end
  self.wasTyping = typing
  if typing and self.playing and self.speed == 1 and not (Audio.ext and Audio.ext()) and floor(playdate.getCurrentTimeMilliseconds() / 70) % 2 == 0 then
    K.voice("telegraph", playdate.sound.kWaveSquare, 0, 0.012, 0, 0.005, 0.06):playNote(2400, 0.3, 0.008)
  end

  -- controls help: for a few seconds after entering / pausing
  if self.hintUntil and playdate.getCurrentTimeMilliseconds() < self.hintUntil and not slo then
    local f = K.fonts.tiny
    local s = "A PLAY  HOLD A LOG  CRANK SCRUB  UP/DN AT-BAT  L/R SPEED  B BACK"
    local w = f:getTextWidth(s) + 10
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(200 - w / 2, 210, w, 12)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(200 - w / 2, 210, w, 12)
    K.text(f, s, 200, 213, "center")
  end
  if self.live and tl.total - self.t < 0.05 and not self.src then
    K.textW(K.fonts.tiny, "WAITING ON THE WIRE...", 6, 213)
  end
end

function S:drawFinalCard(b, tau)
  if tau < 1.2 or (self.src and self.src.finalCard) then return end
  local meta = self.meta
  local e = b.e
  local x, y, w, h = 110, 132, 180, 62
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 3, y + 3, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  local f = K.fonts.nb
  K.text(f, (meta.away and meta.away.abbr or "AWY") .. " " .. e.away .. "   " .. (meta.home and meta.home.abbr or "HOM") .. " " .. e.home, x + w / 2, y + 5, "center")
  local bet = meta.bet
  local t = K.fonts.tiny
  if bet then
    local won = (bet.side == "home" and e.home > e.away) or (bet.side == "away" and e.away > e.home)
    local team = bet.side == "home" and meta.home and meta.home.abbr or meta.away and meta.away.abbr or ""
    K.text(t, "YOUR BET: " .. K.money(bet.amount) .. " ON " .. team, x + w / 2, y + 24, "center")
    -- pays = return per $1 staked (API.md), so profit = amount * pays - amount
    local pays = meta.pays and meta.pays[bet.side]
    local line
    if won then
      line = pays and ("CASHED +" .. K.money(math.floor(bet.amount * pays - bet.amount + 0.5))) or "CASHED!"
    else
      line = "LOST " .. K.money(bet.amount)
    end
    K.text(f, line, x + w / 2, y + 38, "center")
  else
    K.text(t, "NO MONEY ON THIS ONE.", x + w / 2, y + 28, "center")
    K.text(t, "COWARD.", x + w / 2, y + 40, "center")
  end
end

---------------------------------------------------------------------------
-- splash / intro

local logoImg
local function logo()
  if logoImg then return logoImg end
  logoImg = HUD.textImage(K.fonts.big, "BALLCAST 3D", 8)
  return logoImg
end

function S:drawSplash()
  gfx.setPattern({ 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 })
  gfx.fillRect(0, 0, 400, 240)
  local img = logo()
  local w = img:getSize()
  img:draw(200 - w / 2, 70)
  local msg = self.mode == "error" and ("NO SIGNAL: " .. tostring(self.err)) or self.mode == "waiting" and "GAME HASN'T STARTED. STAND BY." or (self.loadMsg or "TUNING IN...")
  local f = K.fonts.nb
  local mw = f:getTextWidth(msg) + 16
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(200 - mw / 2, 130, mw, 18)
  K.textW(f, msg, 200, 132, "center")
  if self.mode == "building" then
    local prog = K.clamp(self.loadProg or 0, 0, 1)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(140, 156, 120, 8)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(140, 156, 120, 8)
    gfx.fillRect(142, 158, 116 * prog, 4)
    -- snow under the bar so it visibly keeps running while the park builds
    for i = 1, 20 do gfx.fillRect(math.random(0, 399), math.random(170, 239), 2, 1) end
  elseif self.mode == "error" then
    K.textW(K.fonts.tiny, "B: BACK", 200, 156, "center")
  else
    -- snow
    gfx.setColor(gfx.kColorBlack)
    for i = 1, 30 do gfx.fillRect(math.random(0, 399), math.random(160, 239), 2, 1) end
  end
end

local MENU = { "WATCH FROM FIRST PITCH", "HIGHLIGHTS ONLY", "SKIP TO THE FINAL OUT" }

function S:drawIntro()
  local R = self.R
  if self.live3d then
    local a = math.rad(-30 + (playdate.getCurrentTimeMilliseconds() % 60000) / 1000 * 4)
    R:setCamera(Cam.introOrbit(self.meta and self.meta.park, a))
    R:background(0, 0, 0.3)
  else
    R:use("high")
    R:background(0, 0)
  end
  gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
  gfx.fillRect(0, 0, 400, 240)
  local img = logo()
  local w = img:getSize()
  img:draw(200 - w / 2, 18)
  local m = self.meta
  local f = K.fonts.nb
  local title = (m.away and m.away.abbr or "?") .. " AT " .. (m.home and m.home.abbr or "?")
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(80, 56, 240, 34)
  K.textW(K.fonts.big, title, 200, 58, "center")
  local sub = string.upper((m.park and m.park.name) or "") .. "  -  REPLAY"
  gfx.fillRect(80, 90, 240, 14)
  K.textW(K.fonts.tiny, sub, 200, 93, "center")
  for i, s in ipairs(MENU) do
    local y = 118 + (i - 1) * 24
    local sel = i == self.menuSel
    gfx.setColor(sel and gfx.kColorBlack or gfx.kColorWhite)
    gfx.fillRect(90, y, 220, 20)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(90, y, 220, 20)
    if sel then K.textW(f, "> " .. s, 200, y + 3, "center") else K.text(f, s, 200, y + 3, "center") end
  end
  if m.bet then
    local team = m.bet.side == "home" and (m.home and m.home.abbr) or (m.away and m.away.abbr) or ""
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(90, 194, 220, 14)
    K.textW(K.fonts.tiny, "YOU HAVE " .. K.money(m.bet.amount) .. " ON " .. (team or ""), 200, 197, "center")
  end
  HUD.ticker(1 / 30)
end

---------------------------------------------------------------------------
-- debug helpers (used by the test harness)

--- Seek to the first beat matching pred, tau seconds in.
function S:debugSeek(pred, tau)
  if not self.tl then return false end
  for i, b in ipairs(self.tl.beats) do
    if pred(b) then
      self.t = b.start + (type(tau) == "function" and tau(b) or tau or 0)
      self.lastBeat = nil
      self:resetTicker(true)
      return true
    end
  end
  return false
end
