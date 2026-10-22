--[[ Pennant's LEGACY layer (docs/PENNANT_ENGINE.md "Legacy"): runs, alumni, pointers, the deck,
  the Hall of Fame, Pennant Heat. Pure rules (playdate APIs only for the alumni file).

  A RUN is one season (a pennant can turn it into an endless career). At its end the season's best
  players are graded (an alumni score: ratings, awards, the postseason, traits) and get POINTERS (a
  stat pointer on one of their two best ratings, a trait pointer, a PENNANT pointer); the player banks 1 /
  2 / 3 of them (any finish / the playoffs / the pennant) into the ALUMNI HALL, which lives in its
  own file (pennant-alumni.json) shared by every save slot. After a playoff season, a new run picks
  two alumni as LEGACIES (their pointers pay off on Opening Day and may take again at two alumni visits;
  their own legacies' pointers count at half) and a DECK of alumni who turn up at the weekly programs
  (bond, Rally Weeks). The Hall of Fame is an All-Time Lineup built from the Hall.

  L.run (saved with the league meta):
    key, seed, n          the run's id / dice seed / number
    heat                  Pennant Heat (AI clubs + ratings in games; +5% ★★★ pointer odds a level)
    season0, endless      the run's first season; seasons continued past it (endless career)
    leg, chem, chemWhy    the two legacies (alumni copies), chemistry 0-100 and its sources
    deck, bond            deck entries { id, fn, ln, face, grade, score, spec, pos }; bond by id
    gains, gainSeason     legacy points this season by rating (cap G.CAP)
    od, showOD, intro     the last Opening Day's rolls; the reveal still to show; run 1's card
    insp                  alumni visit results by "i1"/"i2"
    endc                  this season's end: candidates (graded, given pointers), banked flag, keep slots
    banked                player id -> alum id (each player banked once; re-banking updates him)
    ended, old            the run is over (the slot waits for a new run); a save from before runs
  All dice are seeded by the run's seed and the context (season, week, pointer), so reloading a
  save rerolls nothing.
  (Pointers were called "sparks" once: the saved keys keep that name, an alum's `sparks`, a reveal
  row's `spark`, and the dice context "spark", so old saves and alumni files read as they are.)
]]

PLegacy = PLegacy or {}
local G = PLegacy
local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local clamp = PM.clamp

G.FILE = "pennant-alumni"
G.VERSION = 1
G.MAX = 40                      -- alumni storage

-- Tuning (scratchpad research REPORT.md "Pointers / legacy", "Alumni deck"; tuned in the legacy
-- chain self-test: pennant/test.lua "legacy")
G.OD = { 1, 2, 4 }              -- Opening Day points per ★ / ★★ / ★★★ (a legacy's stat pointer)
G.OD_GP = { 0.5, 1, 2 }         -- their legacies' (half)
G.PROC = { 0.60, 0.75, 0.90 }   -- alumni visit: a stat pointer takes (x (1 + chemistry / 100), cap 95%)
G.GAIN = { { 1, 2 }, { 1, 3 }, { 2, 5 } }
G.TPROC = { 0.15, 0.25, 0.40 }  -- a trait pointer passes the trait to one more player
G.GP_X = 0.5                    -- grandparents: half the odds
G.CAP = 10                      -- legacy points per rating per season (overflow: facility xp)
G.STACK = { 1, 0.75, 0.5 }      -- the same rating's pointers in one event
G.INSP_AT = { 9 / 26, 18 / 26 } -- inspirations (a 26-week season's weeks 9 and 18)
G.DECK_SPEC, G.DECK_OTHER, G.DECK_ABSENT = 200, 60, 60
G.MENTOR_X = 0.05               -- +5% gains per alum at the program
G.BOND = 7                      -- bond per week together
G.RALLY = 80                    -- bond for a Rally Week (at the alum's specialty)
G.RALLY_X = { 1.3, 1.5 }        -- (grade A and up: x1.5)
G.HEAT_MAX = 10
G.HEAT_X = 0.6                  -- AI rating points in games per Heat level
G.DECK_AT = { 0, 0, 5, 15 }     -- deck slots: 2, the 3rd at 5 alumni banked, the 4th at 15

G.GRADES = { { 800, "LEGEND" }, { 740, "SS" }, { 690, "S" }, { 640, "A" }, { 590, "B" }, { 540, "C" },
  { 490, "D" }, { 440, "E" }, { 390, "F" }, { 0, "G" } }
G.GRADE_RANK = { G = 1, F = 2, E = 3, D = 4, C = 5, B = 6, A = 7, S = 8, SS = 9, LEGEND = 10 }

function G.gradeOf(score)
  for _, g in ipairs(G.GRADES) do if score >= g[1] then return g[2] end end
  return "G"
end
function G.aPlus(grade) return (G.GRADE_RANK[grade] or 0) >= G.GRADE_RANK.A end

-- Traits: small game-time nudges (PEng.modFor), earned by a season's numbers or passed on by a
-- trait pointer. One per player. CLUTCH is also the engine's own clutch trait in live games.
G.TRAITS = {
  CLUTCH = { who = "bat", mod = { con = 2, eye = 2 }, d = "Big spots: contact, eye +2" },
  SLUGGER = { who = "bat", mod = { pow = 4 }, d = "Power +4 in games" },
  THIEF = { who = "bat", mod = { spd = 6 }, d = "Speed +6 in games" },
  CANNON = { who = "bat", mod = { arm = 6 }, d = "Arm +6 in games" },
  ACE = { who = "SP", mod = { sp = 3 }, d = "Starter: pitching +3" },
  CLOSER = { who = "RP", mod = { rp = 3 }, d = "Reliever: pitching +3" },
}
G.TRAIT_ORDER = { "CLUTCH", "SLUGGER", "THIEF", "CANNON", "ACE", "CLOSER" }

-- a rating's unit (PWeek.boostUnit), its program (facility, the deck specialty)
G.UNIT = { con = "hitters", pow = "hitters", eye = "hitters", spd = "hitters", fld = "hitters", arm = "hitters",
  velo = "pitchers", ctl = "pitchers", stf = "pitchers", sta = "rot" }
G.UNIT_NAME = { hitters = "LINEUP", pitchers = "STAFF", rot = "ROTATION" }
G.ATTR_PROG = { con = "bat", pow = "bat", eye = "bat", spd = "gym", fld = "def", arm = "def",
  velo = "arms", ctl = "arms", stf = "arms", sta = "gym" }

local STARS <const> = { "\u{2605}", "\u{2605}\u{2605}", "\u{2605}\u{2605}\u{2605}" }
G.STARS = STARS

local function hash(...)
  local h = 2166136
  for i = 1, select("#", ...) do
    local v = select(i, ...)
    if type(v) == "string" then for k = 1, #v do h = (h * 31 + v:byte(k)) & 0x7FFFFFFF end
    else h = (h * 131 + floor(tonumber(v) or 0)) & 0x7FFFFFFF end
  end
  return h
end
G.hash = hash

-- The alumni file ----------------------------------------------------------------------------------

local function fresh()
  return { v = G.VERSION, seq = 0, runs = 0, unlocked = false, alumni = {}, hof = { slots = {}, auto = true }, log = {}, banked = 0, seen = {} }
end

--- The alumni hall (cached). G.mem (a table) replaces the file: the self-test and the tour's
--- fixture pool never touch the player's real hall.
function G.load()
  if G.mem then return G.mem end
  if G.A then return G.A end
  local A = playdate.datastore.read(G.FILE)
  if type(A) ~= "table" or A.v ~= G.VERSION then A = fresh() end
  G.normalize(A)
  G.A = A
  return A
end

function G.normalize(A)
  A.alumni = type(A.alumni) == "table" and A.alumni or {}
  A.hof = type(A.hof) == "table" and A.hof or { slots = {}, auto = true }
  A.hof.slots = type(A.hof.slots) == "table" and A.hof.slots or {}
  A.log = type(A.log) == "table" and A.log or {}
  A.seen = type(A.seen) == "table" and A.seen or {}
  A.seq, A.runs, A.banked = tonumber(A.seq) or 0, tonumber(A.runs) or 0, tonumber(A.banked) or 0
  return A
end

function G.save()
  if G.mem then return end
  if G.A then playdate.datastore.write(G.A, G.FILE, false) end
end

function G.byId(A, id)
  for _, a in ipairs(A.alumni) do if a.id == id then return a end end
  return nil
end

--- Legacies and the deck: after the first playoff season, with somebody in the hall.
function G.unlocked() local A = G.load() return A.unlocked and #A.alumni > 0 end

function G.deckSlots(A)
  A = A or G.load()
  local n = 0
  for _, need in ipairs(G.DECK_AT) do if (A.banked or 0) >= need then n = n + 1 end end
  return n
end

function G.short(a) return (a.fn or "?"):sub(1, 1) .. ". " .. (a.ln or "?") end
function G.initials(a) return ((a.fn or "?"):sub(1, 1) .. (a.ln or "?"):sub(1, 1)):upper() end
function G.posOf(a) return a.pos == "P" and (a.role or "P") or a.pos end

-- Pointers -------------------------------------------------------------------------------------------

function G.pointerName(s)
  if s.k == "stat" then return PM.LABEL[s.a]:upper() .. " " .. STARS[s.s] end
  if s.k == "trait" then return s.t .. " " .. STARS[s.s] end
  return "PENNANT \u{2605}"
end
function G.pointerShort(s)
  if s.k == "stat" then return PM.SHORT[s.a] .. " " .. STARS[s.s] end
  if s.k == "trait" then return s.t end
  return "PENNANT"
end

--- ★ / ★★ / ★★★ odds (%) from the pointer's rating; Heat moves 5% a level into ★★★.
function G.starOdds(v, heat)
  local o
  if v >= 70 then o = { 15, 60, 25 } elseif v >= 60 then o = { 45, 45, 10 } else o = { 80, 20, 0 } end
  local add = 5 * (heat or 0)
  local take = min(add, o[1]) o[1], o[3], add = o[1] - take, o[3] + take, add - take
  take = min(add, o[2]) o[2], o[3] = o[2] - take, o[3] + take
  return o
end

local function statKeys(p)
  local keys = {}
  for _, k in ipairs(PM.keys(p)) do
    if p.r[k] and not (k == "sta" and p.role ~= "SP") then keys[#keys + 1] = k end
  end
  table.sort(keys, function(a, b) if p.r[a] ~= p.r[b] then return p.r[a] > p.r[b] end return a < b end)
  return keys
end

--- The stat pointer: one of his ratings, weighted to his top two (45 / 35, the rest share 20).
function G.statPointer(p, rng, heat, award)
  local keys = statKeys(p)
  local r = rng:int(100)
  local a
  if r <= 45 or #keys < 2 then a = keys[1]
  elseif r <= 80 or #keys < 3 then a = keys[2]
  else a = keys[3 + (r % (#keys - 2))] end
  local o = G.starOdds(p.r[a] or 50, heat)
  local x = rng:int(100)
  local s = x <= o[1] and 1 or (x <= o[1] + o[2] and 2 or 3)
  if award and s < 2 then s = 2 end
  return { k = "stat", a = a, s = s }
end

-- Traits ---------------------------------------------------------------------------------------------

function G.traitFits(p, t)
  local T = G.TRAITS[t]
  if not T then return false end
  if T.who == "bat" then return p.pos ~= "P" end
  if T.who == "SP" then return p.pos == "P" and p.role == "SP" end
  return p.pos == "P" and p.role ~= "SP"
end

local function traitRating(p, t)
  local r = p.r
  if t == "CLUTCH" then return (r.con or 0) + (r.eye or 0) end
  if t == "SLUGGER" then return r.pow or 0 end
  if t == "THIEF" then return r.spd or 0 end
  if t == "CANNON" then return r.arm or 0 end
  return PM.ovr(p)
end

--- Pass trait t on to n of the user's big-leaguers who fit it and have none (the best fits first).
--- Returns the players.
function G.grantTrait(L, t, n)
  local T = L.teams[L.user]
  local list = {}
  for _, id in ipairs(T.ml) do
    local p = L.players[id]
    if p and not p.tr and G.traitFits(p, t) then list[#list + 1] = p end
  end
  table.sort(list, function(a, b) local x, y = traitRating(a, t), traitRating(b, t) if x ~= y then return x > y end return a.id < b.id end)
  local out = {}
  for i = 1, min(n, #list) do list[i].tr = t out[#out + 1] = list[i] end
  if #out > 0 and PEng.invalidate then PEng.invalidate() end
  return out
end

--- A season's numbers earn a trait (the user's club, at the season's end; scaled by the season's length).
function G.earnTrait(L, p)
  if p.tr then return nil end
  local g = PL.seasonGames(L) / 84
  if p.pos ~= "P" then
    local s = p.st.b
    if (s.pa or 0) < 120 * g then return nil end
    if (s.hr or 0) >= 18 * g then p.tr = "SLUGGER"
    elseif (s.sb or 0) >= 20 * g then p.tr = "THIEF"
    elseif (s.rbi or 0) >= 55 * g then p.tr = "CLUTCH"
    elseif (p.r.arm or 0) >= 68 and (p.pos == "C" or p.pos == "RF" or p.pos == "SS" or p.pos == "3B" or p.pos == "CF") then p.tr = "CANNON" end
  else
    local s = p.st.p
    if p.role == "SP" then
      if (s.w or 0) >= 11 * g or ((s.outs or 0) >= 330 * g and PM.era(s) <= 3.2) then p.tr = "ACE" end
    elseif (s.sv or 0) >= 14 * g then p.tr = "CLOSER" end
  end
  return p.tr
end

-- In-game mods: the week's (series plans, events), a player's trait, Pennant Heat (AI clubs) --------

local weekModFor = PWeek.modFor
local combo = setmetatable({}, { __mode = "k" })
local NONE <const> = {}
local KEYS <const> = { "con", "pow", "eye", "spd", "sp", "rp", "arm", "fld" }

--- Heat in rating points for an AI club's players (+1-2 a level).
function G.heatPts(L) local R = L and L.run return R and G.heatOf(R.heat) or 0 end
--- (the report's +1-2 a level is a lot on the 20-80 scale: +8 at Heat 5 won 26 games of 84 with a
--- grown legacy; +0.6 a level keeps Heat 5 a fight and Heat 10 a wall: docs "Legacy")
function G.heatOf(h) return floor((h or 0) * G.HEAT_X + 0.5) end

function G.modFor(p)
  local L = Pennant and Pennant.L
  if not L then return nil end
  local m = weekModFor(p)
  local tr = p.tr and p.lvl == "ML" and G.TRAITS[p.tr]
  local h = (p.team ~= L.user) and G.heatPts(L) or 0
  if not tr and h == 0 then return m end
  local base = m or NONE
  local byT = combo[base]
  if not byT then byT = {} combo[base] = byT end
  local ck = (p.tr or "") .. h
  local out = byT[ck]
  if out then return out end
  out = {}
  for _, k in ipairs(KEYS) do out[k] = (base[k] or 0) + (tr and tr.mod[k] or 0) end
  if h > 0 then out.con, out.pow, out.eye, out.sp, out.rp = out.con + h, out.pow + h, out.eye + h, out.sp + h, out.rp + h end
  byT[ck] = out
  return out
end
PEng.modFor = G.modFor

-- Runs -------------------------------------------------------------------------------------------------

--- A save from before runs (or a league made without one) becomes a run: an old career keeps
--- every right it had (it can always carry on).
function G.ensure(L)
  local R = L.run
  if type(R) ~= "table" then
    R = { key = "r" .. tostring(L.seed or 1), seed = L.seed or 1, n = 0, old = true, heat = 0, endless = 0, season0 = L.season }
    L.run = R
  end
  R.seed = R.seed or L.seed or 1
  R.heat = clamp(floor(tonumber(R.heat) or 0), 0, 99)
  R.endless = tonumber(R.endless) or 0
  R.bond = type(R.bond) == "table" and R.bond or {}
  R.gains = type(R.gains) == "table" and R.gains or {}
  R.insp = type(R.insp) == "table" and R.insp or {}
  R.banked = type(R.banked) == "table" and R.banked or {}
  R.deck = type(R.deck) == "table" and R.deck or {}
  R.season0 = R.season0 or L.season
  return R
end

local function copy(t)
  if type(t) ~= "table" then return t end
  local o = {}
  for k, v in pairs(t) do o[k] = copy(v) end
  return o
end
G.copy = copy

--- The deck specialty: the stat pointer's program, else his position's.
function G.specialty(a)
  for _, s in ipairs(a.sparks or {}) do if s.k == "stat" then return G.ATTR_PROG[s.a] end end
  if a.pos == "P" then return "arms" end
  if a.pos == "C" or a.pos == "SS" or a.pos == "2B" or a.pos == "CF" then return "def" end
  return "bat"
end

function G.deckEntry(a)
  return { id = a.id, fn = a.fn, ln = a.ln, face = a.face, grade = a.grade, score = a.score, spec = G.specialty(a), pos = a.pos, role = a.role }
end

--- Chemistry between two legacies (0-100) and its sources.
function G.chemistry(a, b)
  if not (a and b) then return 0, {} end
  local c, why = 10, {}
  local pa, pb = a.pos == "P", b.pos == "P"
  if pa == pb then
    if a.pos == b.pos and (a.role or "") == (b.role or "") then c = c + 25 why[#why + 1] = "SAME POSITION"
    else c = c + 15 why[#why + 1] = pa and "BOTH ARMS" or "BOTH BATS" end
  end
  if a.runKey and a.runKey == b.runKey then c = c + 25 why[#why + 1] = "SAME RUN"
  elseif abs((a.run or 0) - (b.run or 0)) <= 1 then c = c + 10 why[#why + 1] = "SAME ERA" end
  if a.club and a.club == b.club then c = c + 10 why[#why + 1] = "SAME CLUB" end
  local pn = 0
  for _, x in ipairs({ a, b }) do for _, s in ipairs(x.sparks or {}) do if s.k == "pennant" then pn = pn + 1 end end end
  if pn > 0 then c = c + 10 * pn why[#why + 1] = pn == 1 and "A PENNANT" or (pn .. " PENNANTS") end
  local function related(x, y)
    for _, gp in ipairs(x.par or {}) do if gp.aid and gp.aid == y.id then return true end end
    return false
  end
  if related(a, b) or related(b, a) then c = c + 15 why[#why + 1] = "FAMILY" end
  return clamp(c, 0, 100), why
end

function G.chemMark(c) return c >= 60 and 3 or (c >= 30 and 2 or 1) end   -- ◎ ○ △

--- Every pointer a run's legacies carry: { who, via, gen (1 legacy, 2 his legacy), s }.
function G.sources(leg)
  local out = {}
  for _, a in ipairs(leg or {}) do
    for _, s in ipairs(a.sparks or {}) do out[#out + 1] = { who = G.short(a), gen = 1, s = s } end
  end
  for _, a in ipairs(leg or {}) do
    for _, gp in ipairs(a.par or {}) do
      for _, s in ipairs(gp.sp or {}) do
        if s.k ~= "pennant" then out[#out + 1] = { who = gp.n, via = G.short(a), gen = 2, s = s } end
      end
    end
  end
  return out
end

--- The best pair for a new run (the sum of their scores, plus chemistry); nil, nil with < 2.
function G.bestPair(A)
  local list = A.alumni
  local best, bv, bi, bj = nil, -1e9, nil, nil
  for i = 1, #list do
    for j = i + 1, #list do
      local c = G.chemistry(list[i], list[j])
      local v = (list[i].score or 0) + (list[j].score or 0) + c * 3
      if v > bv then bv, bi, bj = v, list[i], list[j] end
    end
  end
  if not bi and list[1] then return list[1], nil end
  return bi, bj
end

--- The best deck: highest scores, each specialty once if possible.
function G.bestDeck(A, n, leg)
  local list = {}
  for _, a in ipairs(A.alumni) do list[#list + 1] = a end
  table.sort(list, function(x, y) return (x.score or 0) > (y.score or 0) end)
  local out, used, spec = {}, {}, {}
  for pass = 1, 2 do
    for _, a in ipairs(list) do
      if #out >= n then break end
      local sp = G.specialty(a)
      if not used[a.id] and (pass == 2 or not spec[sp]) then out[#out + 1] = a used[a.id] = true spec[sp] = true end
    end
  end
  return out
end

--- What a pair of legacies should do (the new-run screen): lines per rating
--- { unit, a, now, upto } and the traits that may carry over.
function G.expect(leg, chem)
  local by, order = {}, {}
  for _, src in ipairs(G.sources(leg)) do
    local s = src.s
    if s.k == "stat" then
      local e = by[s.a]
      if not e then e = { a = s.a, od = {}, ins = 0 } by[s.a] = e order[#order + 1] = e end
      e.od[#e.od + 1] = (src.gen == 1 and G.OD or G.OD_GP)[s.s]
      local p = min(0.95, G.PROC[s.s] * (1 + (chem or 0) / 100) * (src.gen == 2 and G.GP_X or 1))
      e.ins = e.ins + 2 * p * G.GAIN[s.s][2]
    end
  end
  local out = {}
  for _, e in ipairs(order) do
    table.sort(e.od, function(x, y) return x > y end)
    local now = 0
    for i, v in ipairs(e.od) do now = now + v * G.STACK[min(i, 3)] end
    now = floor(now + 0.5)
    out[#out + 1] = { unit = G.UNIT_NAME[G.UNIT[e.a]], a = e.a, now = min(G.CAP, now), upto = min(G.CAP, floor(now + e.ins + 0.5)) }
  end
  table.sort(out, function(x, y) return x.upto > y.upto end)
  local traits = {}
  for _, src in ipairs(G.sources(leg)) do if src.s.k == "trait" then traits[#traits + 1] = src.s.t end end
  return out, traits
end

--- A new run starts on a fresh league (after PL.init): choice = { leg = { alum, alum }, deck = { alum.. }, heat }.
function G.beginRun(L, choice)
  local A = G.load()
  choice = choice or {}
  A.runs = (A.runs or 0) + 1
  local R = { key = "r" .. tostring(L.seed) .. "-" .. A.runs, seed = hash(L.seed or 1, A.runs), n = A.runs, heat = clamp(choice.heat or 0, 0, G.HEAT_MAX),
    endless = 0, season0 = L.season, bond = {}, gains = {}, insp = {}, banked = {}, deck = {} }
  L.run = R
  if choice.leg and #choice.leg > 0 then
    R.leg = {}
    for _, a in ipairs(choice.leg) do R.leg[#R.leg + 1] = copy(a) end
    R.chem, R.chemWhy = G.chemistry(R.leg[1], R.leg[2])
  end
  for _, a in ipairs(choice.deck or {}) do R.deck[#R.deck + 1] = G.deckEntry(a) end
  if R.leg then G.openingDay(L)
  elseif #A.alumni == 0 then R.intro = true end
  if PEng.invalidate then PEng.invalidate() end
  G.save()
  return R
end

-- Legacy points: the cap, stacking, the overflow ------------------------------------------------------

--- +n to rating a for the whole unit, within this season's cap; the overflow goes to the
--- program's facility as use points. Returns the points given and the overflow.
function G.grant(L, a, n)
  local R = L.run
  if R.gainSeason ~= L.season then R.gains, R.gainSeason = {}, L.season end
  local have = R.gains[a] or 0
  local use = max(0, min(n, G.CAP - have))
  if use > 0 then PWeek.boostUnit(L, G.UNIT[a], a, use) R.gains[a] = have + use end
  local over = n - use
  if over > 0 then PWeek.addFacXp(L, G.ATTR_PROG[a], over) end
  return use, over
end

--- Apply a list of stat contributions { a, amt, row } with the same-rating stacking; fills each
--- row's result. caps (optional) collects { a, before, add } per rating.
local function applyStats(L, list, caps)
  local by, order = {}, {}
  for _, e in ipairs(list) do
    if not by[e.a] then by[e.a] = {} order[#order + 1] = e.a end
    local t = by[e.a]
    t[#t + 1] = e
  end
  local R = L.run
  for _, a in ipairs(order) do
    local t = by[a]
    table.sort(t, function(x, y) return x.amt > y.amt end)
    if R.gainSeason ~= L.season then R.gains, R.gainSeason = {}, L.season end
    local before = R.gains[a] or 0
    local add = 0
    for i, e in ipairs(t) do
      local n = floor(e.amt * G.STACK[min(i, 3)] + 0.5)
      local use, over = G.grant(L, a, n)
      add = add + use
      local u = G.UNIT_NAME[G.UNIT[a]]
      e.row.res = use > 0 and ((over > 0) and (PM.SHORT[a] .. " +" .. use .. " \u{2022} CAP") or (u .. " " .. PM.SHORT[a] .. " +" .. use)) or "AT THE CAP"
      e.row.ok = use > 0 or over > 0
      if over > 0 and use == 0 then e.row.res = "CAP: FACILITY +" .. over end
      e.row.n, e.row.a = use, a
    end
    if caps then caps[#caps + 1] = { a = a, before = before, add = add } end
  end
end

--- Opening Day: every legacy stat pointer takes (+1 / +2 / +4 per ★, theirs at half) on its unit;
--- a trait pointer passes the trait to 1 / 2 / 3 players; ★★★ starts its program's facility at LV2;
--- a PENNANT pointer: energy +10, mood +1. half: the endless career's later seasons (half points,
--- no facility, traits to fewer). The rolls are kept for the reveal (R.od, R.showOD).
function G.openingDay(L, half)
  local R = L.run
  if not (R and R.leg) then return nil end
  PWeek.ensure(L)
  local rows, stats = {}, {}
  local c = L.club
  for _, src in ipairs(G.sources(R.leg)) do
    local s = src.s
    local row = { who = src.who, via = src.via, gen = src.gen, spark = G.pointerName(s), ok = true }
    if s.k == "stat" then
      local amt = (src.gen == 1 and G.OD or G.OD_GP)[s.s] * (half and 0.5 or 1)
      if amt >= 0.5 then
        stats[#stats + 1] = { a = s.a, amt = amt, row = row }
        rows[#rows + 1] = row
        if src.gen == 1 and s.s == 3 and not half then
          local prog = G.ATTR_PROG[s.a]
          if (c.fac[prog] or 1) < 2 then c.fac[prog] = 2 c.fxp[prog] = max(c.fxp[prog] or 0, PWeek.FAC_LV[2]) end
          row.fac = PWeek.PROG[prog].fac .. " LV2"
        end
      end
    elseif s.k == "trait" and src.gen == 1 then
      local n = half and max(1, s.s // 2) or s.s
      local got = G.grantTrait(L, s.t, n)
      row.res = #got > 0 and (s.t .. " TO " .. #got) or "NO ROOM"
      row.ok = #got > 0
      rows[#rows + 1] = row
    elseif s.k == "pennant" and src.gen == 1 then
      PWeek.addEnergy(L, half and 5 or 10)
      PWeek.addMood(L, 1)
      row.res = "ENERGY +" .. (half and 5 or 10) .. ", MOOD +1"
      rows[#rows + 1] = row
    end
  end
  local caps = {}
  applyStats(L, stats, caps)
  R.od = { season = L.season, half = half or nil, rows = rows, caps = caps }
  R.odSeason = L.season
  R.showOD = true
  if PEng.invalidate then PEng.invalidate() end
  return R.od
end

-- Alumni visits (weeks 9 and 18 of 26: here scaled to the season's weeks) ----------------------------

function G.inspWeeks(L)
  local n = #PWeek.weeks(L)
  local a = max(2, floor(n * G.INSP_AT[1] + 0.5))
  return { a, max(a + 2, floor(n * G.INSP_AT[2] + 0.5)) }
end

--- An alumni visit's due: the run's first season, legacies, the week reached, not yet held.
function G.inspDue(L)
  local R = L.run
  if not (R and R.leg) or (R.endless or 0) > 0 or R.season0 ~= L.season or L.phase ~= "season" then return nil end
  local sp = PWeek.span(L)
  if not sp.w then return nil end
  local wk = G.inspWeeks(L)
  for i = 1, 2 do if sp.w >= wk[i] and not R.insp["i" .. i] then return i end end
  return nil
end

--- Alumni visit i: each stat pointer may take again (60 / 75 / 90% x (1 + chemistry / 100), theirs at
--- half the odds) for +1-2 / +1-3 / +2-5; trait pointers 15 / 25 / 40% to pass the trait on once more.
--- Seeded by the run and i; held once (the result is kept).
function G.inspire(L, i)
  local R = L.run
  local key = "i" .. i
  if R.insp[key] then return R.insp[key] end
  PWeek.ensure(L)
  local rng = PRng.new(hash(R.seed, "insp", i, L.season))
  local chem = R.chem or 0
  local rows, stats = {}, {}
  for _, src in ipairs(G.sources(R.leg)) do
    local s = src.s
    local row = { who = src.who, via = src.via, gen = src.gen, spark = G.pointerName(s) .. (src.gen == 2 and " (HALF)" or "") }
    local gx = src.gen == 2 and G.GP_X or 1
    if s.k == "stat" then
      local p = min(0.95, G.PROC[s.s] * (1 + chem / 100) * gx)
      local roll = rng:float()
      local g = G.GAIN[s.s]
      local amt = g[1] + rng:int(g[2] - g[1] + 1) - 1
      row.pct = floor(p * 100 + 0.5)
      if roll < p then stats[#stats + 1] = { a = s.a, amt = amt, row = row }
      else row.res, row.ok = "DIDN'T TAKE", false end
      rows[#rows + 1] = row
    elseif s.k == "trait" then
      local p = G.TPROC[s.s] * gx
      row.pct = floor(p * 100 + 0.5)
      if rng:float() < p then
        local got = G.grantTrait(L, s.t, 1)
        row.res, row.ok = #got > 0 and ("+1 " .. s.t .. ": " .. got[1].ln:upper()) or "NO ROOM", #got > 0
      else row.res, row.ok = "DIDN'T TAKE", false end
      rows[#rows + 1] = row
    end
  end
  local caps = {}
  applyStats(L, stats, caps)
  local fired = 0
  for _, r in ipairs(rows) do if r.ok then fired = fired + 1 end end
  local res = { i = i, w = PWeek.span(L).w, rows = rows, caps = caps, fired = fired, season = L.season }
  R.insp[key] = res
  PL.news(L, "ALUMNI VISIT: " .. fired .. " of " .. #rows .. " pointers took.", true)
  if PEng.invalidate then PEng.invalidate() end
  return res
end

-- The deck -----------------------------------------------------------------------------------------

local placeMemo = {}
--- Where the deck's alumni turn up in week w: prog -> { deck index, ... } (seeded by the run, the
--- season and the week: weights specialty 200, each other program 60, absent 60).
function G.placements(L, w)
  local R = L.run
  if not R or not R.deck or #R.deck == 0 then return nil end
  local key = R.key .. ":" .. L.season .. ":" .. tostring(w) .. ":" .. #R.deck
  if placeMemo.key == key then return placeMemo.t end
  local rng = PRng.new(hash(R.seed, "deck", L.season, w or 0))
  local t = {}
  for i, d in ipairs(R.deck) do
    local r = rng:int(G.DECK_SPEC + 4 * G.DECK_OTHER + G.DECK_ABSENT)
    local prog
    if r <= G.DECK_SPEC then prog = d.spec
    else
      r = r - G.DECK_SPEC
      if r <= 4 * G.DECK_OTHER then
        local k = (r - 1) // G.DECK_OTHER + 1
        for _, pk in ipairs(PWeek.PROGS) do
          if pk ~= d.spec then k = k - 1 if k == 0 then prog = pk break end end
        end
      end
    end
    if prog then t[prog] = t[prog] or {} local l = t[prog] l[#l + 1] = i end
  end
  placeMemo.key, placeMemo.t = key, t
  return t
end

--- Bond a week together: +7 in a 26-week season (the research); scaled to this season's weeks
--- (+20 in 14), so a deck alum met at his specialty four or five times rallies in the second half.
function G.bondPer(L) return max(G.BOND, floor(G.BOND * 40 / max(1, #PWeek.weeks(L)) + 0.5)) end

function G.bond(L, d) return (L.run.bond[tostring(d.id)] or 0) end

--- The deck at a program this week: { { i, rally } ... } (empty when nobody).
function G.present(L, prog, w)
  local out = {}
  local R = L.run
  if not R or prog == "rest" then return out end
  local pl = G.placements(L, w or PWeek.span(L).w)
  for _, i in ipairs(pl and pl[prog] or {}) do
    local d = R.deck[i]
    out[#out + 1] = { i = i, rally = d.spec == prog and G.bond(L, d) >= G.RALLY }
  end
  return out
end

--- Is a Rally Week ready anywhere this week?
function G.rallyAny(L)
  local R = L.run
  if not R or #(R.deck or {}) == 0 then return false end
  for _, k in ipairs(PWeek.PROGS) do
    for _, e in ipairs(G.present(L, k)) do if e.rally then return true end end
  end
  return false
end

--- PWeek's mentor hook: +5% a present alum, a Rally Week x1.3 (x1.5 grade A+) each, stacking.
function PWeek.mentorMods(L, prog)
  local R = L.run
  if not R or #(R.deck or {}) == 0 or prog == "rest" then return nil end
  local c = L.club
  local wk = c and c.wk
  local sp = PWeek.span(L)
  local present = (wk and wk.mentors and wk.prog == prog and wk.w == sp.w) and wk.mentors or G.present(L, prog, sp.w)
  if #present == 0 then return nil end
  local out = { { k = "alumni", x = 1 + G.MENTOR_X * #present, label = #present .. (#present == 1 and " ALUM" or " ALUMNI") } }
  local rx = 1
  for _, e in ipairs(present) do
    local d = R.deck[e.i]
    if e.rally and d then rx = rx * G.RALLY_X[G.aPlus(d.grade) and 2 or 1] end
  end
  if rx > 1 then out[2] = { k = "rally", x = rx, label = "RALLY WEEK" } end
  return out
end

--- The week starts: who's there (kept with the week, so the gains don't move with the bond), +7 bond.
function G.weekStarted(L, wk)
  local R = L.run
  if not R or #(R.deck or {}) == 0 or wk.prog == "rest" then return end
  local present = G.present(L, wk.prog, wk.w)
  if #present == 0 then return end
  wk.mentors = present
  local names, rally = {}, false
  for _, e in ipairs(present) do
    local d = R.deck[e.i]
    local k = tostring(d.id)
    R.bond[k] = min(100, (R.bond[k] or 0) + G.bondPer(L))
    names[#names + 1] = G.short(d)
    if e.rally then rally = true end
  end
  if rally then
    PL.news(L, "RALLY WEEK: " .. table.concat(names, " and ") .. " ran " .. PWeek.PROG[wk.prog].name:lower() .. " with the club.", true)
  end
end

local beginWeek0 = PWeek.beginWeek
function PWeek.beginWeek(L)
  local wk, new = beginWeek0(L)
  if new and wk and L.run then G.weekStarted(L, wk) end
  return wk, new
end

local newSeason0 = PWeek.newSeason
function PWeek.newSeason(L)
  newSeason0(L)
  local R = L.run
  -- the endless career's later seasons: the original two at half on Opening Day
  if R and R.leg and (R.endless or 0) > 0 and R.odSeason ~= L.season and L.phase == "season" then G.openingDay(L, true) end
end

--- An alumni visit is held when its week comes round (after the day closes, whatever is running:
--- a week, a sim to the end); the reveal shows when the player is next there (G.unseenInsp).
local dayClosed0 = PWeek.dayClosed
function PWeek.dayClosed(L)
  dayClosed0(L)
  local i = G.inspDue(L)
  if i then G.inspire(L, i).unseen = true end
end

function G.unseenInsp(L)
  local R = L.run
  if not R or not R.insp then return nil end
  for i = 1, 2 do local r = R.insp["i" .. i] if r and r.unseen then return i, r end end
  return nil
end

PWeek.addStop({ id = "inspire", due = function(L) return (G.unseenInsp(L)) end })

-- The season's end: grades, pointers, the keep ---------------------------------------------------------

G.LEAD = { avg = "BATTING TITLE", hr = "HR CROWN", rbi = "RBI CROWN", sb = "SB CROWN", w = "WINS LEADER", era = "ERA TITLE", pk = "K CROWN", sv = "SAVES LEADER" }

function G.madePlayoffs(L)
  for _, a in ipairs(L.seeds or {}) do if a == L.user then return true end end
  return false
end

function G.finishText(L)
  if L.champ == L.user then return "PENNANT" end
  if G.madePlayoffs(L) then return "PLAYOFFS" end
  return PUI and PUI.ord(PL.rank(L, L.user)):upper() or tostring(PL.rank(L, L.user))
end

--- Keep slots: 1 for any finish, 2 the playoffs, 3 the pennant (the endless career: 1, 2 with a pennant).
function G.keepSlots(L)
  local R = L.run
  if R and (R.endless or 0) > 0 then return L.champ == L.user and 2 or 1 end
  if L.champ == L.user then return 3 end
  if G.madePlayoffs(L) then return 2 end
  return 1
end

local function seasonLine(p)
  if p.pos ~= "P" then
    local s = p.st.b
    local second = ((s.sb or 0) > (s.hr or 0) * 1.5 and (s.sb or 0) >= 10) and ((s.sb or 0) .. " SB") or ((s.hr or 0) .. " HR")
    return PM.rate3(PM.avg(s)) .. " \u{2022} " .. second
  end
  local s = p.st.p
  if p.role ~= "SP" and (s.sv or 0) > 0 then return (s.sv or 0) .. " SV \u{2022} " .. string.format("%.2f", PM.era(s)) end
  return (s.w or 0) .. "-" .. (s.l or 0) .. " \u{2022} " .. string.format("%.2f", PM.era(s))
end

--- The alumni score (visible): 10 x overall, awards (MVP / Pitcher of the Year 60, Rookie 30, each
--- league crown 15), the postseason (pennant 50, playoffs 20), a trait 30, the season's numbers (-20..50).
function G.score(L, p)
  local A = L.awardsRes or {}
  local s = PM.ovr(p) * 10
  local notes = {}
  local award = false
  if A.mvp == p.id then s = s + 60 notes[#notes + 1] = "MVP" award = true end
  if A.cy == p.id then s = s + 60 notes[#notes + 1] = "PITCHER OF YR" award = true end
  if A.roy == p.id then s = s + 30 notes[#notes + 1] = "ROOKIE OF YR" award = true end
  for _, k in ipairs({ "avg", "hr", "rbi", "sb", "w", "era", "pk", "sv" }) do
    local l = A.lead and A.lead[k]
    if l and l.id == p.id then s = s + 15 notes[#notes + 1] = G.LEAD[k] end
  end
  if L.champ == L.user then s = s + 50 elseif G.madePlayoffs(L) then s = s + 20 end
  if p.tr then s = s + 30 end
  local perf = p.pos == "P" and PL.pitScore(p) or PL.batScore(p)
  if perf > -99 then s = s + clamp(floor(perf + 0.5), -20, 50) end
  return s, notes, award
end

--- The season's end (once; kept in R.endc so a reload shows the same): traits earned, the six best
--- graded and given pointers. Returns R.endc.
function G.seasonEnd(L)
  local R = G.ensure(L)
  if R.endc and R.endc.season == L.season then return R.endc end
  local T = L.teams[L.user]
  local rng = PRng.new(hash(R.seed, "end", L.season))
  local list = {}
  for _, id in ipairs(T.ml) do
    local p = L.players[id]
    if p and ((p.st.b.pa or 0) >= 30 or (p.st.p.outs or 0) >= 30) then
      local earned = G.earnTrait(L, p)
      local sc, notes, award = G.score(L, p)
      list[#list + 1] = { p = p, score = sc, notes = notes, award = award, earned = earned }
    end
  end
  table.sort(list, function(a, b) if a.score ~= b.score then return a.score > b.score end return a.p.id < b.p.id end)
  local cands = {}
  local par = {}
  for _, a in ipairs(R.leg or {}) do
    local sp = {}
    for _, s in ipairs(a.sparks or {}) do if s.k ~= "pennant" then sp[#sp + 1] = copy(s) end end
    par[#par + 1] = { n = G.short(a), aid = a.id, sp = sp, grade = a.grade }
  end
  local fin = G.finishText(L)
  for i = 1, min(6, #list) do
    local e = list[i]
    local p = e.p
    local srng = PRng.new(hash(R.seed, "spark", L.season, p.id))
    local sparks = { G.statPointer(p, srng, R.heat, e.award) }
    local grade = G.gradeOf(e.score)
    if p.tr then sparks[#sparks + 1] = { k = "trait", t = p.tr, s = (G.GRADE_RANK[grade] >= G.GRADE_RANK.S and 3) or (G.GRADE_RANK[grade] >= G.GRADE_RANK.B and 2) or 1 } end
    if L.champ == L.user then sparks[#sparks + 1] = { k = "pennant", s = 1 } end
    local note = e.notes[1] or (e.earned and ("EARNED " .. e.earned)) or ((p.mlYrs or 0) >= 4 and (((p.mlYrs or 0) + 1) .. " YRS IN") or fin)
    cands[#cands + 1] = { pid = p.id, fn = p.fn, ln = p.ln, face = p.face, pos = p.pos, pos2 = p.pos2, role = p.role, r = PM.snapshot(p),
      ovr = PM.ovr(p), score = e.score, grade = grade, line = seasonLine(p), note = note, notes = e.notes, earned = e.earned, tr = p.tr,
      sparks = sparks, par = par, run = R.n, runKey = R.key, year = L.year, club = L.user, fin = fin }
  end
  R.endc = { season = L.season, cands = cands, slots = G.keepSlots(L), fin = fin, banked = false }
  return R.endc
end

--- Bank the picked candidates (indices into R.endc.cands) into the hall; releases (alum ids) first.
--- A player banked before in this run is updated (his best season stays). Unlocks legacies after a
--- playoff season; logs the run; refreshes the Hall of Fame. Returns the new / updated alumni.
function G.bank(L, picks, releases)
  local R = L.run
  local E = R.endc
  local A = G.load()
  for _, id in ipairs(releases or {}) do G.release(A, id) end
  local out = {}
  if not E.banked then
    for _, i in ipairs(picks or {}) do
      local c = E.cands[i]
      if c then
        local old = R.banked[tostring(c.pid)] and G.byId(A, R.banked[tostring(c.pid)])
        local rec = copy(c)
        if old then
          if (rec.score or 0) >= (old.score or 0) then
            rec.id = old.id
            for k in pairs(old) do old[k] = nil end
            for k, v in pairs(rec) do old[k] = v end
          end
          out[#out + 1] = old
        elseif #A.alumni < G.MAX then
          A.seq = (A.seq or 0) + 1
          rec.id = A.seq
          A.alumni[#A.alumni + 1] = rec
          A.banked = (A.banked or 0) + 1
          R.banked[tostring(c.pid)] = rec.id
          out[#out + 1] = rec
        end
      end
    end
    E.banked = true
    E.kept = #out
    if G.madePlayoffs(L) and not A.unlocked then A.unlocked = true E.unlockedNow = true end
    local T = L.teams[L.user]
    A.log[#A.log + 1] = { n = R.n, year = L.year, club = L.user, w = T.w, l = T.l, fin = E.fin, heat = R.heat, endless = R.endless }
    while #A.log > 60 do table.remove(A.log, 1) end
    G.hofRefresh(A)
    G.save()
  end
  return out
end

function G.release(A, id)
  for i, a in ipairs(A.alumni) do
    if a.id == id then
      table.remove(A.alumni, i)
      for k, v in pairs(A.hof.slots) do if v == id then A.hof.slots[k] = nil end end
      return true
    end
  end
  return false
end

--- Can the run carry on? (a pennant; an endless career until two losing seasons running; a save
--- from before runs, always)
function G.canContinue(L)
  local R = L.run
  if not R then return true end
  if R.old then return true end
  if (R.endless or 0) > 0 then return (R.losing or 0) < 2 end
  return L.champ == L.user
end

function G.continueCareer(L)
  local R = G.ensure(L)
  local T = L.teams[L.user]
  R.losing = (T.w < T.l) and ((R.losing or 0) + 1) or 0
  if L.champ == L.user then R.titles = (R.titles or 0) + 1 end
  R.endless = (R.endless or 0) + 1
  if not R.old then R.heat = (R.heat or 0) + 1 end
  R.endc = nil
end

function G.endRun(L)
  local R = G.ensure(L)
  R.ended = true
end

-- Hall of Fame: the All-Time Lineup --------------------------------------------------------------------

G.HOF = { "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "DH", "SP1", "SP2", "SP3", "SP4", "SP5", "RP1", "RP2" }

function G.fits(a, slot)
  local k = slot:sub(1, 2)
  if k == "SP" then return a.pos == "P" and a.role == "SP" end
  if k == "RP" then return a.pos == "P" and a.role ~= "SP" end
  if slot == "DH" then return a.pos ~= "P" end
  return a.pos == slot or a.pos2 == slot
end

--- The best All-Time Lineup the hall can field (fielders first, then arms, the DH last).
function G.hofSuggest(A)
  local list = {}
  for _, a in ipairs(A.alumni) do list[#list + 1] = a end
  table.sort(list, function(x, y) if (x.score or 0) ~= (y.score or 0) then return (x.score or 0) > (y.score or 0) end return x.id < y.id end)
  local used, slots = {}, {}
  for _, slot in ipairs(G.HOF) do
    for _, a in ipairs(list) do
      if not used[a.id] and G.fits(a, slot) then slots[slot] = a.id used[a.id] = true break end
    end
  end
  return slots
end

--- After a banking: an automatic lineup is rebuilt; a hand-set one only fills its empty slots.
function G.hofRefresh(A)
  local h = A.hof
  for k, v in pairs(h.slots) do if not G.byId(A, v) then h.slots[k] = nil end end
  if h.auto then h.slots = G.hofSuggest(A) return end
  local used = {}
  for _, v in pairs(h.slots) do used[v] = true end
  local sug = G.hofSuggest(A)
  for _, slot in ipairs(G.HOF) do
    if not h.slots[slot] then
      local best, bs = nil, -1
      for _, a in ipairs(A.alumni) do
        if not used[a.id] and G.fits(a, slot) and (a.score or 0) > bs then best, bs = a, a.score or 0 end
      end
      if best then h.slots[slot] = best.id used[best.id] = true end
    end
  end
  return sug
end

--- Franchise Rating (the lineup's mean score / 10; empty slots count zero) and the goals' progress.
function G.hofStats(A)
  local sum, n, aN, leg = 0, 0, 0, 0
  for _, slot in ipairs(G.HOF) do
    local a = A.hof.slots[slot] and G.byId(A, A.hof.slots[slot])
    if a then
      sum = sum + (a.score or 0)
      n = n + 1
      if G.aPlus(a.grade) then aN = aN + 1 end
      if a.grade == "LEGEND" then leg = leg + 1 end
    end
  end
  local fr = floor(sum / #G.HOF / 10 + 0.5)
  return { fr = fr, grade = G.gradeOf(fr * 10), filled = n, aN = aN, legend = leg, total = #G.HOF }
end
