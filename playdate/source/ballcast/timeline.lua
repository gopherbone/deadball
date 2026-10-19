-- BallCast timeline: turns the server's LogEv stream into "beats" (one camera-worthy
-- moment each) with game-state snapshots before/after, so playback can jump anywhere.
--
-- Log semantics (packages/sim/src/game.ts):
--  * mv {from:0,to:4} is how *every* run is logged (from is always 0), so the scorer's real
--    base comes from our own base tracking.
--  * After a bip, every runner who stays safe gets an mv (even from==to); runners and the
--    batter put out get none. Outs on a bip = participants − safe − scored.
--  * Walks/HBP log only the batter's mv (and a run if forced home); forced runners move
--    implicitly.

import "ballcast/kit"

BallCast = BallCast or {}
local TL = {}
BallCast.Timeline = TL

local K = BCKit

TL.DUR = { half = 3.2, pa = 1.9, p = 2.5, pX = 1.5, pH = 3.2, walk = 1.8, sb = 3.4, wp = 2.6, sub = 3.0, inc = 5.5, ["end"] = 7.0, mv = 1.6 }

---------------------------------------------------------------------------
-- win expectancy (home team), from score/inning/outs/bases

local RE = { -- run expectancy by bases mask (1=1B,2=2B,4=3B) and outs
  [0] = { 0.48, 0.25, 0.10 }, [1] = { 0.85, 0.50, 0.22 }, [2] = { 1.10, 0.66, 0.32 }, [3] = { 1.44, 0.90, 0.43 },
  [4] = { 1.35, 0.95, 0.35 }, [5] = { 1.78, 1.13, 0.48 }, [6] = { 1.96, 1.36, 0.57 }, [7] = { 2.29, 1.54, 0.75 },
}
local function erf(x)
  local s = x < 0 and -1 or 1
  x = math.abs(x)
  local t = 1 / (1 + 0.3275911 * x)
  local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t * math.exp(-x * x)
  return s * y
end
local function phi(z) return 0.5 * (1 + erf(z / 1.41421356)) end

function TL.winExp(st, final)
  if final then
    if st.home > st.away then return 1 elseif st.home < st.away then return 0 end
  end
  local inn = st.inn or 1
  local outs = math.min(st.outs or 0, 2)
  local mask = (st.b1 and 1 or 0) + (st.b2 and 2 or 0) + (st.b3 and 4 or 0)
  local reNow = st.outs >= 3 and 0 or RE[mask][outs + 1]
  local PER = 0.5        -- runs per half inning
  local VAR = 0.95       -- variance per half inning
  -- remaining full half-innings for each side (regulation 9, extra innings play 1 more)
  local lastInn = math.max(9, inn)
  local awayLeft, homeLeft, mean, var
  if st.top then
    awayLeft = lastInn - inn      -- after this one
    homeLeft = lastInn - inn + 1
    mean = (st.home - st.away) + homeLeft * PER - awayLeft * PER - reNow
    var = (awayLeft + homeLeft) * VAR + (st.outs < 3 and VAR * (1 - outs / 3) or 0)
  else
    awayLeft = lastInn - inn
    homeLeft = lastInn - inn
    mean = (st.home - st.away) + homeLeft * PER - awayLeft * PER + reNow
    var = (awayLeft + homeLeft) * VAR + (st.outs < 3 and VAR * (1 - outs / 3) or 0)
    if inn >= 9 and st.home > st.away then return 1 end
  end
  if var < 0.05 then var = 0.05 end
  -- ties go to extras ~ 52% home
  local p = phi((mean + 0.08) / math.sqrt(var))
  return K.clamp(p, 0.01, 0.99)
end

---------------------------------------------------------------------------

local function copyState(s)
  return { inn = s.inn, top = s.top, outs = s.outs, b = s.b, s = s.s, home = s.home, away = s.away,
    b1 = s.b1, b2 = s.b2, b3 = s.b3, bat = s.bat, pit = s.pit, pt = s.pt, pv = s.pv, pr = s.pr }
end
TL.copyState = copyState

function TL.new(meta)
  local tl = {
    meta = meta or {},
    log = {},
    beats = {},
    st = { inn = 1, top = true, outs = 0, b = 0, s = 0, home = 0, away = 0, b1 = false, b2 = false, b3 = false },
    total = 0,
    final = false,
    paIdx = {},      -- beat indices that start a PA (for up/down skipping)
    wire = {},       -- beat index → text
  }
  return tl
end

local function baseOf(st, id)
  if st.b1 == id then return 1 end
  if st.b2 == id then return 2 end
  if st.b3 == id then return 3 end
  return nil
end

local function setBase(st, n, v)
  if n == 1 then st.b1 = v elseif n == 2 then st.b2 = v elseif n == 3 then st.b3 = v end
end

local function scoreRun(tl, st)
  if st.top then st.away = st.away + 1 else st.home = st.home + 1 end
end

-- Rebuild a beat's post-state from its pre-state + attached mvs.
local function resolve(tl, beat)
  local pre = beat.pre
  local st = copyState(pre)
  local e = beat.e
  beat.mvs = beat.mvs or {}
  local mvs = beat.mvs
  for i = #mvs, 1, -1 do mvs[i] = nil end
  beat.runs = 0
  local raw = beat.raw or {}

  if beat.kind == "bip" then
    -- participants: batter + runners on base
    local parts = { { id = pre.bat, from = 0 } }
    if pre.b1 then parts[#parts + 1] = { id = pre.b1, from = 1 } end
    if pre.b2 then parts[#parts + 1] = { id = pre.b2, from = 2 } end
    if pre.b3 then parts[#parts + 1] = { id = pre.b3, from = 3 } end
    st.b1, st.b2, st.b3 = false, false, false
    local seen = {}
    local safe, scored = 0, 0
    for _, m in ipairs(raw) do
      local from = m.to == 4 and (baseOf(pre, m.id) or 0) or m.from
      if m.to == 4 then
        scored = scored + 1
        scoreRun(tl, st)
        beat.runs = beat.runs + 1
      elseif m.to >= 1 and m.to <= 3 then
        safe = safe + 1
        setBase(st, m.to, m.id)
      end
      seen[m.id] = true
      mvs[#mvs + 1] = { id = m.id, from = from, to = m.to }
    end
    for _, p in ipairs(parts) do
      if p.id and not seen[p.id] then
        mvs[#mvs + 1] = { id = p.id, from = p.from, to = -1 }
      end
    end
    local outs = #parts - safe - scored
    if outs < 0 then outs = 0 end
    beat.outsMade = outs
    st.outs = math.min(3, pre.outs + outs)
  else
    for _, m in ipairs(raw) do
      if beat.walk and m.from == 0 and m.to == 1 and m.id == pre.bat then
        -- force runners along
        if st.b1 then
          if st.b2 then
            st.b3 = st.b2
            mvs[#mvs + 1] = { id = st.b2, from = 2, to = 3 }
          end
          st.b2 = st.b1
          mvs[#mvs + 1] = { id = st.b1, from = 1, to = 2 }
        end
        st.b1 = m.id
        mvs[#mvs + 1] = { id = m.id, from = 0, to = 1 }
      elseif m.to == 4 then
        local from = baseOf(st, m.id) or 0
        if from > 0 then setBase(st, from, false) end
        scoreRun(tl, st)
        beat.runs = beat.runs + 1
        mvs[#mvs + 1] = { id = m.id, from = from, to = 4 }
      else
        local from = baseOf(st, m.id) or m.from
        if from and from > 0 then setBase(st, from, false) end
        if m.to >= 1 and m.to <= 3 then setBase(st, m.to, m.id) end
        mvs[#mvs + 1] = { id = m.id, from = from, to = m.to }
      end
    end
  end
  beat.post = st
end

local function closeBeat(tl, beat)
  if not beat or beat.closed then return end
  resolve(tl, beat)
  if BallCast.Play and BallCast.Play.plan then BallCast.Play.plan(beat, tl) end
  beat.dur = beat.dur or 2
  beat.we = TL.winExp(beat.post, beat.kind == "end")
end

local function addBeat(tl, kind, e, idx)
  local prev = tl.beats[#tl.beats]
  if prev then
    -- the previous beat is finished now (its trailing mvs are all in)
    closeBeat(tl, prev)
    prev.closed = true
    tl.st = copyState(prev.post)
  end
  local beat = { kind = kind, e = e, i = idx, last = idx, raw = {}, pre = copyState(tl.st), n = #tl.beats + 1 }
  local st = beat.pre
  -- state changes that happen "at" the event
  if kind == "half" then
    st.inn, st.top, st.outs, st.b, st.s = e.inn, e.top, 0, 0, 0
    st.b1, st.b2, st.b3 = false, false, false
    st.pt = nil
  elseif kind == "pa" then
    st.bat, st.pit, st.b, st.s = e.bat, e.pit, 0, 0
    st.pt = nil
    tl.paIdx[#tl.paIdx + 1] = beat.n
  elseif kind == "sub" then
    if e.pos == "P" and e["in"] then st.pit = e["in"] end
  end
  tl.beats[#tl.beats + 1] = beat
  return beat
end

-- Apply the event's own effect on the post-state baseline (pre → working state)
local function eventEffect(tl, beat)
  local e = beat.e
  local st = beat.pre
  if beat.kind == "p" then
    -- pre-state shows the count *before* this pitch; post gets the new count
    beat.walk = (e.r == "B" and e.b >= 4) or e.r == "H"
    beat.k = (e.r == "C" or e.r == "S") and e.s >= 3
  end
end

local function finishPost(tl, beat)
  -- pitch / sb / end effects layered on top of resolve()
  local e = beat.e
  local st = beat.post
  if beat.kind == "p" then
    st.pt, st.pv, st.pr = e.t, e.v, e.r
    if beat.k then
      st.outs = math.min(3, st.outs + 1)
      st.b, st.s = e.b, 3
    elseif beat.walk then
      st.b, st.s = math.min(e.b, 4), e.s
    else
      st.b, st.s = e.b, e.s
    end
  elseif beat.kind == "sb" then
    local from = baseOf(beat.pre, e.id) or (e.base - 1)
    setBase(st, from, false)
    if e.ok then setBase(st, e.base, e.id) else st.outs = math.min(3, st.outs + 1) end
    beat.mvs[#beat.mvs + 1] = { id = e.id, from = from, to = e.ok and e.base or -1 }
  elseif beat.kind == "end" then
    st.home, st.away = e.home, e.away
    tl.final = true
  end
end

local resolveBase = resolve
resolve = function(tl, beat)
  resolveBase(tl, beat)
  finishPost(tl, beat)
end

---------------------------------------------------------------------------
-- compact log ("/games/:id/log?fmt=c", server encodeLogC): one string, one event per line,
-- `k` then tab-separated key=value; values: number | !1/!0 | #n,n,n | @json | 'string | string.
-- Parsed one event at a time by the loader, so the JSON decode is a single string.

local find, sub, byte, gmatch = string.find, string.sub, string.byte, string.gmatch
local function cval(v)
  local c = byte(v, 1)
  if c == 35 then                       -- '#': number array
    local t, n = {}, 0
    for x in gmatch(sub(v, 2), "[^,]+") do n = n + 1; t[n] = tonumber(x) end
    return t
  elseif c == 33 then return v == "!1"  -- '!': boolean
  elseif c == 64 then return json.decode(sub(v, 2))   -- '@': nested
  elseif c == 39 then return sub(v, 2)  -- "'": string that looked like something else
  end
  return tonumber(v) or v
end

--- Decode the event starting at byte pos of compact string s → event, next pos
function TL.decodeC(s, pos)
  local nl = find(s, "\n", pos, true)
  local line = sub(s, pos, nl and nl - 1 or #s)
  local tab = find(line, "\t", 1, true)
  local ev = { k = tab and sub(line, 1, tab - 1) or line }
  if tab then
    for key, v in gmatch(sub(line, tab), "\t([^=\t]+)=([^\t]*)") do ev[key] = cval(v) end
  end
  return ev, nl and nl + 1 or #s + 1
end

--- Feed events (Lua array of LogEv tables). Safe to call repeatedly for live games.
--- defer: skip the provisional plan of the open last beat + the layout (call TL.settle later);
--- lets a loader fold events in one at a time without re-laying-out the game each time.
function TL.append(tl, events, defer)
  for _, e in ipairs(events) do
    local idx = #tl.log + 1
    tl.log[idx] = e
    local k = e.k
    if k == "ultra" then
      -- Enhanced League power: logged just before the event it powers (pitch powers and
      -- HYPER_HIT before the "p", LEAP_CATCH before the "bip"); attach it to that beat.
      tl.pendingUltra = tl.pendingUltra or {}
      tl.pendingUltra[#tl.pendingUltra + 1] = e
    elseif k == "mv" then
      local beat = tl.beats[#tl.beats]
      if not beat then beat = addBeat(tl, "mv", e, idx) end
      beat.raw[#beat.raw + 1] = e
      beat.last = idx
    else
      local prev = tl.beats[#tl.beats]
      local beat = addBeat(tl, k, e, idx)
      if tl.pendingUltra then
        beat.ultra = tl.pendingUltra
        tl.pendingUltra = nil
      end
      -- a HYPER_HIT that made contact carries over to the ball in play
      if k == "bip" and prev and prev.kind == "p" and prev.ultra then
        for _, u in ipairs(prev.ultra) do
          if u.power == "HYPER_HIT" then
            beat.ultra = beat.ultra or {}
            beat.ultra[#beat.ultra + 1] = u
          end
        end
      end
      eventEffect(tl, beat)
    end
  end
  if defer then return end
  TL.settle(tl)
end

--- Provisional plan for the open last beat + layout (start times, totals, walk-off flag).
function TL.settle(tl)
  -- the last beat stays open (more mvs may follow in a live game) but gets a provisional plan
  local last = tl.beats[#tl.beats]
  -- (re-plan only if the open beat changed since the last settle)
  local key = last and (#tl.beats * 1000 + #last.raw) or 0
  if last and tl.settledKey == key and last.plan then last = nil end
  tl.settledKey = key
  if last then
    last.closed = false
    resolve(tl, last)
    if BallCast.Play and BallCast.Play.plan then BallCast.Play.plan(last, tl) end
    last.we = TL.winExp(last.post, last.kind == "end")
  end
  TL.layout(tl)
end

--- Recompute start times and big-moment flags.
function TL.layout(tl)
  local t = 0
  local beats = tl.beats
  local prevWe = 0.5
  for i = 1, #beats do
    local b = beats[i]
    b.start = t
    b.dur = b.dur or 2
    b.weBefore = prevWe
    prevWe = b.we or prevWe
    t = t + b.dur
  end
  tl.total = t
  -- walk-off: final scoring beat in the bottom of the 9th+ that puts home ahead
  if tl.final then
    for i = #beats, 1, -1 do
      local b = beats[i]
      if b.runs and b.runs > 0 then
        if not b.pre.top and b.pre.inn >= 9 and b.post.home > b.post.away and b.pre.home <= b.pre.away then
          b.walkoff = true
        end
        break
      end
    end
  end
end

--- Beat index at time t (binary search).
function TL.beatAt(tl, t)
  local beats = tl.beats
  local lo, hi = 1, #beats
  if hi == 0 then return nil end
  if t <= 0 then return 1 end
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if beats[mid].start <= t then lo = mid else hi = mid - 1 end
  end
  return lo
end

--- Attach wire lines ({ i = log index (0-based), text }) to beats.
function TL.setWire(tl, lines)
  tl.wireLines = lines or {}
  tl.wire = {}
  if #tl.beats == 0 then return end
  local beats = tl.beats
  local nb = #beats
  for _, ln in ipairs(tl.wireLines) do
    local li = (ln.i or 0) + 1
    -- the beat containing log index li (binary search: beats are in log order)
    local bi = nil
    if beats[1].i <= li then
      local lo, hi = 1, nb
      while lo < hi do
        local mid = (lo + hi + 1) // 2
        if beats[mid].i <= li then lo = mid else hi = mid - 1 end
      end
      bi = lo
    end
    if bi then
      local prev = tl.wire[bi]
      tl.wire[bi] = prev and (prev .. " ... " .. ln.text) or ln.text
    end
  end
end

---------------------------------------------------------------------------
-- fallback play-by-play text (used when the wire has nothing for a beat)

local PITCH_NAMES = { FB = "FASTBALL", SI = "SINKER", CT = "CUTTER", SL = "SLIDER", CB = "CURVEBALL", CH = "CHANGEUP", SPL = "SPLITTER", KN = "KNUCKLEBALL", SPIT = "SPITTER" }
TL.PITCH_NAMES = PITCH_NAMES

local FIELD = { P = "the mound", C = "the catcher", ["1B"] = "first", ["2B"] = "second", ["3B"] = "third", SS = "short", LF = "left", CF = "center", RF = "right" }
local INCIDENT = {
  RACCOONS_BULLPEN = "RACCOONS LOOSE IN THE %s BULLPEN",
  RACCOON_ON_FIELD = "RACCOON ON THE FIELD",
  FOOD_POISONING = "%s DUGOUT REPORTS BAD HOT DOGS",
  FAN_ON_FIELD = "FAN ON THE FIELD. HE IS FAST",
  LASER_POINTER = "LASER POINTER IN THE BLEACHERS",
  RAIN_DELAY = "RAIN. TARP. DELAY",
  EJECTION = "%s IS EJECTED",
  BRAWL = "BENCHES CLEAR",
  BALL_TAMPERING = "SOMETHING ON THE BALL",
  BLACKOUT = "THE LIGHTS GO OUT",
}
TL.INCIDENT = INCIDENT
TL.POWER_NAMES = { FIREBALL = "FIREBALL", STOPPER = "STOPPER", WARP_PITCH = "WARP PITCH", CLOUD_BALL = "CLOUD BALL",
  HYPER_HIT = "HYPER HIT", LEAP_CATCH = "LEAP CATCH", LASER_ARM = "LASER ARM", WARP_RUN = "WARP RUN" }

local function nm(tl, id)
  local p = tl.meta.people and tl.meta.people[id]
  return string.upper(p and K.lastName(p.name) or (id or "?"))
end
TL.name = nm

local function ordinal(n)
  local s = ({ "1ST", "2ND", "3RD" })[n] or (n .. "TH")
  return s
end
TL.ordinal = ordinal

function TL.describe(tl, b)
  local e = b.e
  local k = b.kind
  if k == "half" then
    return (e.top and "TOP " or "BOTTOM ") .. ordinal(e.inn)
  elseif k == "pa" then
    return nm(tl, e.bat) .. " STEPS IN"
  elseif k == "p" then
    if b.ultra and b.ultra[1] then
      local u = b.ultra[1]
      local s = nm(tl, u.who) .. ": " .. (TL.POWER_NAMES[u.power] or u.power) .. "!"
      if b.k then s = s .. " ... " .. nm(tl, b.pre.bat) .. " STRUCK OUT" end
      return s
    end
    if b.k then return nm(tl, b.pre.bat) .. (e.r == "C" and " CAUGHT LOOKING" or " STRUCK OUT SWINGING") end
    if e.r == "H" then return nm(tl, b.pre.bat) .. " PLUNKED" end
    if b.walk then return nm(tl, b.pre.bat) .. " WALKS" end
    return nil
  elseif k == "bip" then
    local who = nm(tl, b.pre.bat)
    local to = FIELD[e.f or ""] or "the field"
    local r = e.res
    local s
    if r == "HR" then s = who .. " HOMERS" .. (b.runs > 1 and (" - " .. b.runs .. " RUN") or "") .. "!"
    elseif r == "1B" then s = who .. " SINGLES TO " .. string.upper(to)
    elseif r == "2B" then s = who .. " DOUBLES TO " .. string.upper(to)
    elseif r == "3B" then s = who .. " TRIPLES!"
    elseif r == "DP" then s = who .. " GROUNDS INTO A DOUBLE PLAY"
    elseif r == "FC" then s = who .. " ON A FIELDER'S CHOICE"
    elseif r == "ROE" then s = who .. " SAFE ON AN ERROR"
    elseif r == "SF" then s = who .. " SAC FLY"
    elseif r == "FOUL_OUT" then s = who .. " POPS OUT FOUL"
    else
      local ot = e.out
      s = who .. (ot == "GO" and " GROUNDS OUT" or ot == "LO" and " LINES OUT" or ot == "PO" and " POPS UP" or " FLIES OUT") .. " TO " .. string.upper(to)
    end
    for _, m in ipairs(b.mvs) do
      if m.to == 4 and m.id ~= b.pre.bat then s = s .. " ... " .. nm(tl, m.id) .. " SCORES" end
    end
    for _, u in ipairs(b.ultra or {}) do
      if u.power == "LEAP_CATCH" then s = nm(tl, u.who) .. " CLIMBS THE WALL AND ROBS " .. who .. "!"
      elseif u.power ~= "HYPER_HIT" then s = s .. " ... " .. (TL.POWER_NAMES[u.power] or u.power) .. "!" end
    end
    return s
  elseif k == "sb" then
    return nm(tl, e.id) .. (e.ok and " STEALS SECOND" or " CAUGHT STEALING")
  elseif k == "wp" then
    return e.pb and "PASSED BALL" or "WILD PITCH"
  elseif k == "sub" then
    if e.pos == "P" then return "PITCHING CHANGE: " .. nm(tl, e["in"]) end
    return nm(tl, e["in"]) .. " IN FOR " .. nm(tl, e.out)
  elseif k == "inc" then
    local f = INCIDENT[e.kind] or e.kind
    local arg = e.who and nm(tl, (tostring(e.who):match("^[^,]+"))) or e.team or "HOME"
    return string.format(f, arg)
  elseif k == "end" then
    return "FINAL"
  end
  return nil
end
