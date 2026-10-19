-- Pennant league generation: eight clubs (the online league's identities), fresh players with
-- ratings / positions / faces / ages / potentials, a farm club for each, and a series schedule.
-- Generation is sliced (PGen.co returns a coroutine body) so the progress bar keeps moving.

PGen = PGen or {}

local D = PennantData
local clamp = PM.clamp

local function nrm(rng, m, sd) return rng:normal(m, sd) end

-- Position templates: offsets from the player's level mean.
local POS_T <const> = {
  C    = { con = -3, pow = 0, eye = 0, spd = -14, fld = 3, arm = 5 },
  ["1B"] = { con = 2, pow = 8, eye = 2, spd = -10, fld = -5, arm = -6 },
  ["2B"] = { con = 3, pow = -6, eye = 0, spd = 5, fld = 4, arm = 0 },
  SS   = { con = 0, pow = -6, eye = -1, spd = 5, fld = 8, arm = 6 },
  ["3B"] = { con = 0, pow = 4, eye = 0, spd = -3, fld = 2, arm = 6 },
  LF   = { con = 2, pow = 4, eye = 1, spd = 0, fld = -3, arm = -3 },
  CF   = { con = 2, pow = -2, eye = 0, spd = 10, fld = 6, arm = 2 },
  RF   = { con = 0, pow = 5, eye = 0, spd = 0, fld = 0, arm = 8 },
  DH   = { con = 3, pow = 7, eye = 3, spd = -8, fld = -10, arm = -6 },
}
local ALT_POS <const> = { C = "1B", ["1B"] = "LF", ["2B"] = "SS", SS = "2B", ["3B"] = "1B", LF = "RF", CF = "LF", RF = "LF", DH = "1B" }
local SECONDARY <const> = { "SL", "CB", "CH", "SPL", "CT", "SI" }

local function pickFace(L, rng, age)
  local pools
  if age <= 23 then pools = { D.FACES_YOUNG, D.FACES_ADULT }
  elseif age >= 33 then pools = { D.FACES_OLD, D.FACES_ADULT }
  else pools = { D.FACES_ADULT } end
  L.usedFaces = L.usedFaces or {}
  for _, pool in ipairs(pools) do
    for _ = 1, 12 do
      local f = rng:pick(pool)
      if not L.usedFaces[f] then L.usedFaces[f] = true return f end
    end
  end
  -- the bank is finite: reuse the least-bad choice
  return rng:pick(pools[1])
end

local function pickName(L, rng)
  L.usedNames = L.usedNames or {}
  for _ = 1, 30 do
    local fn, ln = rng:pick(D.FIRST), rng:pick(D.LAST)
    if not L.usedNames[fn .. ln] then L.usedNames[fn .. ln] = true return fn, ln end
  end
  return rng:pick(D.FIRST), rng:pick(D.LAST)
end

--- Caps: where each rating can grow to with training, from the player's potential.
local function setCaps(p, rng)
  p.cap = {}
  local o = PM.ovr(p)
  local gap = math.max(0, (p.pot or o) - o)
  for k, v in pairs(p.r) do
    local extra = (p.age or 25) < 30 and rng:range(3, 8) or rng:range(1.5, 4)
    p.cap[k] = clamp(math.floor(v + gap * rng:range(0.6, 1.5) + extra + 0.5), v, 80)
  end
end
PGen.setCaps = setCaps

--- A new player. opts: { pos =, role = "SP"/"RP", mean =, age = }
function PGen.player(L, rng, opts)
  local age = opts.age
  local m = opts.mean
  local fn, ln = pickName(L, rng)
  L.nextId = (L.nextId or 0) + 1
  local p = { id = L.nextId, fn = fn, ln = ln, age = age, pos = opts.pos, r = {}, xp = {},
    cond = 3, mood = 0, fat = 0, lvl = "ML", st = PM.newStats(), car = PM.newStats(), yrs = 0, mlYrs = 0,
    plan = { i = 1 } }
  p.face = pickFace(L, rng, age)
  if rng:chance(0.12) then p.nick = rng:pick(D.NICKS) end
  local x = rng:float()
  if opts.pos == "P" then
    p.role = opts.role or "RP"
    p.throws = rng:chance(0.28) and "L" or "R"
    p.bats = p.throws
    local sp = p.role == "SP"
    p.r.velo = clamp(nrm(rng, m + (sp and 0 or 2), 8), 20, 80)
    p.r.ctl = clamp(nrm(rng, m, 8), 20, 80)
    p.r.stf = clamp(nrm(rng, m, 8), 20, 80)
    p.r.sta = sp and clamp(nrm(rng, 62, 6), 48, 80) or clamp(nrm(rng, 34, 6), 20, 46)
    p.pitches = { { k = rng:chance(0.2) and "SI" or "FB", q = clamp((p.r.velo + p.r.stf) / 2 + nrm(rng, 0, 4), 20, 80) } }
    local n = sp and (rng:chance(0.5) and 3 or 2) or (rng:chance(0.35) and 2 or 1)
    local used = { [p.pitches[1].k] = true }
    for _ = 1, n do
      for _ = 1, 8 do
        local k = rng:pick(SECONDARY)
        if not used[k] then
          used[k] = true
          p.pitches[#p.pitches + 1] = { k = k, q = clamp(p.r.stf + nrm(rng, -2, 7), 20, 80) }
          break
        end
      end
    end
    p.plan.f = sp and "sta" or "ctl"
  else
    p.bats = x < 0.58 and "R" or (x < 0.9 and "L" or "S")
    local pos = opts.pos
    p.throws = (pos == "C" or pos == "SS" or pos == "2B" or pos == "3B") and "R" or (rng:chance(0.25) and "L" or "R")
    local t = POS_T[pos] or POS_T.DH
    for _, k in ipairs(PM.BAT_KEYS) do p.r[k] = clamp(nrm(rng, m + t[k], (k == "pow" or k == "spd") and 9 or 8), 20, 80) end
    if pos == "DH" then p.pos = "1B" end
    p.pos2 = ALT_POS[pos]
    p.plan.f = "con"
  end
  for k, v in pairs(p.r) do p.r[k] = math.floor(v + 0.5) end
  local o = PM.ovr(p)
  p.pot = clamp(math.floor(o + math.max(0, 28 - age) * rng:range(0.5, 2.0) + nrm(rng, 0, 3) + 0.5), o, 80)
  setCaps(p, rng)
  p.yrs = math.max(0, age - 19 - rng:int(3))
  L.players[p.id] = p
  return p
end

local ML_BATS <const> = { "C", "C", "1B", "2B", "SS", "3B", "LF", "CF", "RF", "SS", "CF", "DH", "3B" }
local FARM_BATS <const> = { "C", "SS", "2B", "CF", "RF", "3B", "1B" }

function PGen.team(L, rng, club, tick)
  local T = { abbr = club.abbr, ml = {}, farm = {}, w = 0, l = 0, rs = 0, ra = 0, streak = 0, l10 = {}, pen = {} }
  local q = rng:normal(0, 1.3)
  for _, pos in ipairs(ML_BATS) do
    local p = PGen.player(L, rng, { pos = pos, mean = 49 + q, age = 22 + rng:int(14) - 1 })
    p.team, p.lvl = club.abbr, "ML"
    p.mlYrs = math.max(0, p.age - 22 - rng:int(2))
    T.ml[#T.ml + 1] = p.id
    if tick then tick() end
  end
  for i = 1, 13 do
    local p = PGen.player(L, rng, { pos = "P", role = i <= 5 and "SP" or "RP", mean = 49 + q, age = 22 + rng:int(14) - 1 })
    p.team, p.lvl = club.abbr, "ML"
    p.mlYrs = math.max(0, p.age - 22 - rng:int(2))
    T.ml[#T.ml + 1] = p.id
    if tick then tick() end
  end
  for _, pos in ipairs(FARM_BATS) do
    local p = PGen.player(L, rng, { pos = pos, mean = 40 + q * 0.5, age = 18 + rng:int(6) - 1 })
    p.team, p.lvl = club.abbr, "F"
    T.farm[#T.farm + 1] = p.id
  end
  for i = 1, 7 do
    local p = PGen.player(L, rng, { pos = "P", role = i <= 3 and "SP" or "RP", mean = 40 + q * 0.5, age = 18 + rng:int(6) - 1 })
    p.team, p.lvl = club.abbr, "F"
    T.farm[#T.farm + 1] = p.id
  end
  return T
end

-- Schedule -------------------------------------------------------------------------------
-- Series of 3 games. A week = two series (6 game days) + a travel/off day. Each cycle is a
-- single round robin (7 rounds); home/away follows a per-team H-H-A-A rhythm so there are real
-- homestands and road trips, and every later cycle flips the earlier meeting's home side.

local function roundRobin(n)
  -- circle method: rounds of pairs (indices 1..n)
  local idx = {}
  for i = 1, n do idx[i] = i end
  local rounds = {}
  for _ = 1, n - 1 do
    local pairs_ = {}
    for i = 1, n // 2 do pairs_[#pairs_ + 1] = { idx[i], idx[n + 1 - i] } end
    rounds[#rounds + 1] = pairs_
    -- rotate all but the first
    local last = table.remove(idx)
    table.insert(idx, 2, last)
  end
  return rounds
end

function PGen.schedule(L, rng, games)
  local abbrs = {}
  for i, c in ipairs(PennantClubs) do abbrs[i] = c.abbr end
  local n = #abbrs
  local cycles = math.max(1, games // 3 // (n - 1))
  local base = roundRobin(n)
  -- shuffle round order once
  for i = #base, 2, -1 do local j = rng:int(i) base[i], base[j] = base[j], base[i] end
  local phase = {}
  for i = 1, n do phase[i] = rng:int(4) - 1 end
  local homeCount = {}
  for i = 1, n do homeCount[i] = 0 end
  local firstHome = {}   -- [a*16+b] = home index of the first meeting
  local series = {}      -- { home, away } list in round order
  local rounds = {}
  local r = 0
  for c = 1, cycles do
    for _, rd in ipairs(base) do
      r = r + 1
      local out = {}
      for _, pr in ipairs(rd) do
        local a, b = pr[1], pr[2]
        local key = math.min(a, b) * 16 + math.max(a, b)
        local h
        if firstHome[key] and c % 2 == 0 then
          h = firstHome[key] == a and b or a
        else
          local wantA = ((r + phase[a]) // 2) % 2 == 0
          local wantB = ((r + phase[b]) // 2) % 2 == 0
          if wantA and not wantB then h = a elseif wantB and not wantA then h = b
          else h = homeCount[a] <= homeCount[b] and a or b end
          if not firstHome[key] then firstHome[key] = h end
        end
        local aw = h == a and b or a
        homeCount[h] = homeCount[h] + 1
        out[#out + 1] = { h = abbrs[h], a = abbrs[aw] }
      end
      rounds[#rounds + 1] = out
    end
  end
  -- days: 3 game days per round, an off day after every second round
  local days = {}
  for ri, rd in ipairs(rounds) do
    for g = 1, 3 do
      local day = { games = {}, round = ri, gi = g }
      for _, s in ipairs(rd) do day.games[#day.games + 1] = { h = s.h, a = s.a } end
      days[#days + 1] = day
    end
    if ri % 2 == 0 and ri < #rounds then days[#days + 1] = { games = {}, off = true, round = ri } end
  end
  L.sched = days
  L.regDays = #days
  L.rounds = #rounds
end

--- The whole league. Runs as a coroutine body; yields between clubs.
function PGen.league(seed, userAbbr, games, yield)
  local rng = PRng.new(seed)
  local L = { v = 1, seed = seed, year = 1996, season = 1, day = 1, user = userAbbr, games = games,
    players = {}, teams = {}, nextId = 0, news = {}, history = {}, phase = "season", boxes = {},
    week = 1, settings = { landmarks = true } }
  for _, club in ipairs(PennantClubs) do
    -- (yield is called often; the caller decides by the clock when to give up the frame)
    L.teams[club.abbr] = PGen.team(L, rng:fork(club.idx), club, yield and function() yield((club.idx - 0.5) / (#PennantClubs + 1)) end)
    if yield then yield(club.idx / (#PennantClubs + 1)) end
  end
  PGen.schedule(L, rng:fork(99), games)
  L.usedNames, L.usedFaces = nil, nil
  return L
end
