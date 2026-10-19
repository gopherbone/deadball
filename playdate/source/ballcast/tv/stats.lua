-- DBN broadcast package: numbers and facts from the timeline (linescore, pitch counts, batter
-- lines, lineups, player of the game) and the deadpan fact bank. Pure data, no drawing.

import "ballcast/kit"

BallCast = BallCast or {}
local St = {}
BallCast.TVStats = St
local K = BCKit

local HIT = { ["1B"] = true, ["2B"] = true, ["3B"] = true, HR = true }

local function name(meta, id)
  local p = meta.people and meta.people[id]
  return p and p.name or tostring(id or "?")
end
St.name = name
local function last(meta, id) return string.upper(K.lastName(name(meta, id))) end
St.last = last

local function ordinal(n) return ({ "1ST", "2ND", "3RD" })[n] or (n .. "TH") end
St.ordinal = ordinal

---------------------------------------------------------------------------
-- linescore: runs per half-inning, R/H/E per side, through beat `upto`

function St.linescore(tl, upto)
  local ls = { away = {}, home = {}, R = { away = 0, home = 0 }, H = { away = 0, home = 0 }, E = { away = 0, home = 0 }, inn = 1 }
  local beats = tl.beats
  upto = math.min(upto or #beats, #beats)
  for i = 1, upto do
    local b = beats[i]
    local pre, post = b.pre, b.post
    if pre and post then
      local inn = pre.inn or 1
      if b.kind == "half" then inn = b.e.inn; ls[b.e.top and "away" or "home"][inn] = ls[b.e.top and "away" or "home"][inn] or 0 end
      if inn > ls.inn then ls.inn = inn end
      local side = pre.top and "away" or "home"
      local r = ((post.away or 0) + (post.home or 0)) - ((pre.away or 0) + (pre.home or 0))
      if r > 0 and b.kind ~= "end" then
        ls[side][inn] = (ls[side][inn] or 0) + r
      end
      if b.kind == "bip" then
        if HIT[b.e.res] then ls.H[side] = ls.H[side] + 1 end
        if b.e.res == "ROE" then local f = pre.top and "home" or "away"; ls.E[f] = ls.E[f] + 1 end
      end
      ls.R.away, ls.R.home = post.away or 0, post.home or 0
      if b.kind == "end" then ls.R.away, ls.R.home = b.e.away or ls.R.away, b.e.home or ls.R.home end
    end
  end
  return ls
end

---------------------------------------------------------------------------
-- per-person counters through beat `upto` (cached per upto; cheap to recompute: one pass)

-- Incremental: playback moves forward a beat at a time, so the counters are extended from
-- where they were (a full pass only after a scrub backwards or a new timeline).
-- slot: callers that run ahead of playback (the next at-bat's lower third) keep their own
-- counters, so the playback ones never have to start over.
local caches = {}
function St.counts(tl, upto, slot)
  upto = math.min(upto or #tl.beats, #tl.beats)
  slot = slot or "play"
  local c = caches[slot]
  if c and c.tl == tl and c.upto == upto then return c end
  if not c or c.tl ~= tl or c.upto > upto then
    c = { tl = tl, upto = 0, pit = {}, bat = {} }
    caches[slot] = c
  end
  local function P(id) local t = c.pit[id]; if not t then t = { n = 0, k = 0, outs = 0, r = 0, h = 0, bb = 0 }; c.pit[id] = t end; return t end
  local function B(id) local t = c.bat[id]; if not t then t = { pa = 0, ab = 0, h = 0, hr = 0, rbi = 0, bb = 0, k = 0, r = 0, xb = 0, seen = 0, last = nil }; c.bat[id] = t end; return t end
  for i = c.upto + 1, upto do
    local b = tl.beats[i]
    local pre, post = b.pre, b.post
    if b.kind == "p" and pre.pit then
      local p = P(pre.pit)
      p.n = p.n + 1
      if pre.bat then B(pre.bat).seen = B(pre.bat).seen + 1 end
      if b.k then
        p.k = p.k + 1; p.outs = p.outs + 1
        local t = B(pre.bat); t.k = t.k + 1; t.ab = t.ab + 1; t.pa = t.pa + 1; t.last = "K"
      elseif b.walk then
        p.bb = p.bb + 1
        local t = B(pre.bat); t.bb = t.bb + 1; t.pa = t.pa + 1; t.last = "BB"
        t.rbi = t.rbi + (b.runs or 0)
      end
    elseif b.kind == "bip" and pre.bat then
      local t = B(pre.bat)
      local res = b.e.res
      t.pa = t.pa + 1
      if res ~= "SF" then t.ab = t.ab + 1 end
      if HIT[res] then
        t.h = t.h + 1
        if res ~= "1B" then t.xb = t.xb + 1 end
        if pre.pit then P(pre.pit).h = P(pre.pit).h + 1 end
      end
      if res == "HR" then t.hr = t.hr + 1; t.hrInn = pre.inn end
      if res ~= "ROE" and res ~= "DP" then t.rbi = t.rbi + (b.runs or 0) end
      t.last = res
      if pre.pit then P(pre.pit).outs = P(pre.pit).outs + (b.outsMade or 0) end
    end
    -- runs scored (credited to the runner) and runs allowed (to the pitcher on the mound)
    if b.mvs and pre then
      for _, m in ipairs(b.mvs) do
        if m.to == 4 then
          B(m.id).r = B(m.id).r + 1
          if pre.pit then P(pre.pit).r = P(pre.pit).r + 1 end
        end
      end
    end
    if b.kind == "sb" and not b.e.ok and pre.pit then P(pre.pit).outs = P(pre.pit).outs + 1 end
  end
  c.upto = upto
  return c
end

--- "2-FOR-3, HR, 2 RBI" (batter) or "6.1 IP, 7 K, 2 R" (pitcher), through upto
function St.batLine(c, id)
  local t = c.bat[id]
  if not t or t.pa == 0 then return "FIRST AT-BAT" end
  local s = t.h .. "-FOR-" .. t.ab
  if t.hr > 0 then s = s .. ", " .. (t.hr > 1 and (t.hr .. " ") or "") .. "HR" end
  if t.rbi > 0 then s = s .. ", " .. t.rbi .. " RBI" end
  if t.bb > 0 and t.hr == 0 then s = s .. ", " .. (t.bb > 1 and (t.bb .. " ") or "") .. "BB" end
  if t.k >= 2 and t.h == 0 then s = s .. ", " .. t.k .. " K" end
  return s
end

function St.pitLine(c, id)
  local p = c.pit[id]
  if not p then return "" end
  local ip = (p.outs // 3) .. "." .. (p.outs % 3)
  return ip .. " IP, " .. p.k .. " K, " .. p.r .. " R"
end

---------------------------------------------------------------------------
-- lineups: batting order from the PA sequence (the parsed timeline, then the compact log
-- string still waiting to be folded in, then pending list events). First 9 distinct per side.

function St.lineups(scene)
  local meta, tl = scene.meta, scene.tl
  local out = { away = {}, home = {}, sp = {} }
  local seen = {}
  local homeAbbr = meta.home and meta.home.abbr
  local top = true
  local function add(bat, pit, isTop)
    if not bat or seen[bat] then return end
    local side = isTop and "away" or "home"
    local p = meta.people and meta.people[bat]
    -- the people table knows each player's club: trust it over the inning when present
    if p and p.teamAbbr and homeAbbr then side = (p.teamAbbr == homeAbbr) and "home" or "away" end
    local l = out[side]
    if #l < 9 then seen[bat] = true; l[#l + 1] = bat end
    if pit then
      local ps = isTop and "home" or "away"
      out.sp[ps] = out.sp[ps] or pit
    end
  end
  for _, b in ipairs(tl.beats) do
    if b.kind == "half" then top = b.e.top end
    if b.kind == "pa" then add(b.e.bat, b.e.pit, top) end
  end
  local s = scene.pendC and scene.pendC.s
  if s and (#out.away < 9 or #out.home < 9) then
    local pos = scene.pendC.pos or 1
    for line in s:sub(pos):gmatch("[^\n]+") do
      local k = line:match("^(%a+)")
      if k == "half" then top = line:find("top=!1", 1, true) ~= nil
      elseif k == "pa" then
        add(line:match("\tbat=([^\t]+)"), line:match("\tpit=([^\t]+)"), top)
        if #out.away >= 9 and #out.home >= 9 then break end
      end
    end
  end
  if scene.pendingEv and (#out.away < 9 or #out.home < 9) then
    for i = scene.pendingI or 1, #scene.pendingEv do
      local e = scene.pendingEv[i]
      if e.k == "half" then top = e.top elseif e.k == "pa" then add(e.bat, e.pit, top) end
    end
  end
  return out
end

--- the next n batters due up for `side` after beat bi (wraps the lineup order)
function St.dueUp(tl, lineups, bi, side, n)
  local order = lineups[side]
  if not order or #order == 0 then return {} end
  local lastBat
  local homeTop = side == "home"
  for i = math.min(bi, #tl.beats), 1, -1 do
    local b = tl.beats[i]
    if b.kind == "pa" and b.pre.top == (not homeTop) then lastBat = b.e.bat break end
  end
  local at = 0
  for i, id in ipairs(order) do if id == lastBat then at = i end end
  local out = {}
  for k = 1, n do out[k] = order[(at + k - 1) % #order + 1] end
  return out
end

---------------------------------------------------------------------------
-- player of the game

function St.playerOfGame(tl, meta)
  local c = St.counts(tl, #tl.beats)
  local final = tl.beats[#tl.beats]
  local winHome = final and final.post and (final.post.home or 0) > (final.post.away or 0)
  local homeAbbr = meta.home and meta.home.abbr
  local best, bestS, kind = nil, -1e9, nil
  local function onWinner(id)
    local p = meta.people and meta.people[id]
    if not p or not p.teamAbbr or not homeAbbr then return 0 end
    return ((p.teamAbbr == homeAbbr) == winHome) and 1.5 or 0
  end
  for id, t in pairs(c.bat) do
    if t.pa > 0 then
      local s = t.h * 1.0 + t.xb * 0.6 + t.hr * 1.6 + t.rbi * 1.2 + t.r * 0.5 + t.bb * 0.3 + onWinner(id)
      if s > bestS then best, bestS, kind = id, s, "bat" end
    end
  end
  for id, p in pairs(c.pit) do
    local s = p.outs / 3 * 0.55 + p.k * 0.45 - p.r * 0.9 - p.h * 0.15 + onWinner(id)
    if s > bestS then best, bestS, kind = id, s, "pit" end
  end
  if not best then return nil end
  return best, kind, kind == "bat" and St.batLine(c, best) or St.pitLine(c, best)
end

---------------------------------------------------------------------------
-- deadpan facts. Stated flatly; the joke is in the content.

local FLAVOR = {
  "HAS NEVER SEEN THE OCEAN.",
  "OWES BETS BY BOBBY $%d.",
  "OWNS %d BOATS. NONE OF THEM FLOAT.",
  "WAS A WRITE-IN CANDIDATE FOR COMPTROLLER.",
  "HAS BEEN STRUCK BY LIGHTNING TWICE. SAME AFTERNOON.",
  "KEEPS A RACCOON. IT HAS A NAME.",
  "DOES NOT TRUST THE MOON.",
  "HAS HIS OWN CHAIR AT HOT DOG HAL'S.",
  "SURVIVED THE 1994 EEL INCIDENT.",
  "HAS NEVER BEEN ABDUCTED. HE ASKS EVERY YEAR.",
  "LEARNED TO HIT FROM A CORRESPONDENCE COURSE.",
  "SLEEPS IN HIS UNIFORM.",
  "HAS READ ONE BOOK. TWICE.",
  "WAS ONCE TRADED FOR A BUS.",
  "STOLE SECOND BASE IN 1993. THE BAG. IT WAS RETURNED.",
  "HAS A BROTHER IN THE ENHANCED LEAGUE. THEY DO NOT SPEAK.",
  "HIS MUSTACHE IS INSURED BY VOLTA POWER & LIGHT.",
  "WAS BORN IN A BALLPARK. NOT THIS ONE.",
  "WILL NOT STAND NEAR THE TARP.",
  "EATS %d HOT DOGS A GAME. HE IS FINE.",
  "IS LEGALLY A RESIDENT OF THE DESERT SANDS CASINO.",
  "HAS BEEN ON HOLD WITH THE COMMISSIONER SINCE APRIL.",
  "CANNOT SWIM. HAS NOT NEEDED TO.",
  "COLLECTS DOORKNOBS.",
  "IS AFRAID OF THE ORGAN.",
  "WAS NAMED AFTER A HORSE.",
  "HAS A SECOND, BETTER GLOVE AT HOME.",
  "DOES HIS OWN TAXES. BADLY.",
}

--- a flavor fact for a person (stable per id)
function St.flavor(id)
  local h = K.hash01(id or "?", 91)
  local i = math.floor(h * #FLAVOR) + 1
  local f = FLAVOR[i]
  if f:find("%d", 1, true) then
    local n = (i == 2) and (40 + math.floor(K.hash01(id, 92) * 90) * 10) or (2 + math.floor(K.hash01(id, 93) * 9))
    f = string.format(f, n)
  end
  return f
end

--- what the lower third says under the name: a game fact when there is one, else flavor
function St.fact(tl, meta, bi, id)
  local c = St.counts(tl, bi, "fact")
  local t = c.bat[id]
  if t then
    if t.hr > 0 and K.hash01(id, bi) < 0.6 then return "HOMERED IN THE " .. ordinal(t.hrInn or 1) .. "." end
    if t.k >= 2 and K.hash01(id, bi) < 0.6 then return "HAS STRUCK OUT " .. t.k .. " TIMES TODAY. HE IS AWARE." end
    if t.seen >= 12 and K.hash01(id, bi + 1) < 0.4 then return "HAS SEEN " .. t.seen .. " PITCHES TODAY." end
  end
  return St.flavor(id)
end

local PARK_FACTS = {
  function(pk) return pk.altitudeFt and pk.altitudeFt > 1000 and (string.upper(pk.name) .. " SITS " .. pk.altitudeFt .. " FEET ABOVE SEA LEVEL. THE BALL KNOWS.") end,
  function(pk) return pk.fences and ("THE CENTER FIELD FENCE IS " .. pk.fences[3] .. " FEET AWAY. IT HAS NOT MOVED.") end,
  function(pk) return pk.walls and ("THE WALL IN LEFT IS " .. pk.walls[1] .. " FEET TALL. IT WAS ONCE " .. (pk.walls[1] - 1) .. ".") end,
  function(pk) local w = pk.weather; return w and w.tempF and ("IT IS " .. w.tempF .. " DEGREES. THE HOT DOGS ARE " .. (w.tempF + 88) .. ".") end,
  function(pk) return pk.turf and "THE GRASS HERE IS NOT GRASS. NOBODY HAS TOLD THE GROUNDSKEEPER." end,
  function(pk) return "THE " .. string.upper(pk.name or "BALLPARK") .. " ORGANIST KNOWS FOUR SONGS. TONIGHT HE WILL PLAY ALL OF THEM." end,
  function(pk) return "THERE ARE " .. (11 + math.floor(K.hash01(pk.name or "?", 5) * 30)) .. " RACCOONS LIVING UNDER THE BLEACHERS. THE CLUB DISPUTES THIS." end,
}

--- a "DID YOU KNOW" card: { id = person id or nil, text = ... }, seeded by n (the break number)
function St.didYouKnow(tl, meta, bi, n, lineups)
  local pk = meta.park or {}
  if n % 3 == 1 then
    for k = 0, #PARK_FACTS - 1 do
      local f = PARK_FACTS[(n + k) % #PARK_FACTS + 1](pk)
      if f then return { text = f } end
    end
  end
  -- a player from either lineup
  local pool = {}
  for _, id in ipairs(lineups.away or {}) do pool[#pool + 1] = id end
  for _, id in ipairs(lineups.home or {}) do pool[#pool + 1] = id end
  if #pool == 0 then return { text = "BASEBALL HAS NINE INNINGS. THIS IS ONE OF THEM." } end
  local id = pool[math.floor(K.hash01(n, 61) * #pool) + 1]
  return { id = id, text = string.upper(name(meta, id)) .. " " .. St.flavor(id) }
end

-- incidents: the bulletin's flat second line
St.INCIDENT_NOTE = {
  RACCOONS_BULLPEN = "THE BULLPEN HAS BEEN CEDED.",
  RACCOON_ON_FIELD = "IT IS NOT LEAVING.",
  FOOD_POISONING = "HOT DOG HAL HAS NOT RETURNED OUR CALLS.",
  FAN_ON_FIELD = "HE IS WEARING NOTHING.",
  LASER_POINTER = "AUTHORITIES ARE LOOKING FOR A NUN.",
  RAIN_DELAY = "THE TARP IS OUT. PLEASE STAY TUNED.",
  EJECTION = "HE HAS BEEN ASKED TO LEAVE.",
  BRAWL = "EVERYONE IS INVOLVED.",
  BALL_TAMPERING = "SOMETHING IS ON THE BALL. IT IS UNCLEAR WHAT.",
  BLACKOUT = "VOLTA POWER & LIGHT HAS BEEN NOTIFIED.",
}
-- archive photo (images/archive, 96 px) per incident kind
St.INCIDENT_PHOTO = {
  RACCOONS_BULLPEN = "raccoon-01", RACCOON_ON_FIELD = "raccoon-photo-01", FOOD_POISONING = "hotdog-01",
  FAN_ON_FIELD = "fan-on-field-01", LASER_POINTER = "eye-01", RAIN_DELAY = "rain-tarp-01", EJECTION = "bb-umpire-01",
  BRAWL = "brawl-01", BALL_TAMPERING = "ball-01", BLACKOUT = "candle-01",
}

-- Enhanced League powers: what the dossier says
St.POWER_NOTE = {
  FIREBALL = "BALL WILL BE ON FIRE. THIS IS PERMITTED.",
  STOPPER = "BALL WILL STOP. THEN CONTINUE.",
  WARP_PITCH = "BALL WILL BE SOMEWHERE ELSE.",
  CLOUD_BALL = "VISIBILITY: POOR.",
  HYPER_HIT = "BAT HAS BEEN APPROVED BY THE LEAGUE.",
  LEAP_CATCH = "THE WALL IS NOT A BARRIER TO HIM.",
  LASER_ARM = "ARM: LASER.",
  WARP_RUN = "HE WILL ALREADY BE THERE.",
}
local ORIGIN = { "ABDUCTED 1994", "RETURNED FROM THE DESERT", "CLONE (THE SECOND ONE)", "RESURRECTED 1995",
  "HISTORICAL FIGURE", "ABDUCTED TWICE", "ORIGIN: CLASSIFIED", "FOUND IN A CROP CIRCLE" }
function St.origin(id) return ORIGIN[math.floor(K.hash01(id or "?", 97) * #ORIGIN) + 1] end

return St
