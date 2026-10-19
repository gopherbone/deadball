-- Pennant league: the season loop. Game specs for the engine, results into stats and standings,
-- daily condition / mood / fatigue / injuries, weekly training, road trips, playoffs, awards and
-- the offseason (aging, retirements, rookies). Pure Lua (no playdate APIs): the desktop tests run it.

PL = PL or {}

local clamp = PM.clamp
local floor, max, min, abs = math.floor, math.max, math.min, math.abs


local function P(L, id) return L.players[id] end
PL.P = P

function PL.rng(L, salt)
  L.rseq = (L.rseq or 0) + 1
  return PRng.new((L.seed or 1) * 31 + L.rseq * 7919 + (salt or 0))
end

-- Calendar -------------------------------------------------------------------------------------
local MONTHS <const> = { "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" }
local MDAYS <const> = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

--- Schedule day index -> month, day. The regular season is stretched over April 4 - September 28
--- whatever its length (a game day stands for a day or two of a real season); the playoffs run in
--- October, a day each.
local SPAN <const> = 177   -- April 4 .. September 28
function PL.calendar(d, L)
  local off
  local reg = L and L.regDays
  if not reg then off = d - 1
  elseif d <= reg then off = math.floor((d - 1) * SPAN / math.max(1, reg - 1) + 0.5)
  else off = 180 + (d - reg - 1) end      -- October 1 onward
  local m, day = 4, 4 + off
  while day > MDAYS[m] do day = day - MDAYS[m] m = m + 1 if m > 12 then m = 1 end end
  return m, day
end

function PL.date(L, d)
  local m, day = PL.calendar(d or L.day, L)
  return MONTHS[m] .. " " .. day
end

function PL.dateLong(L, d)
  local m, day = PL.calendar(d or L.day, L)
  return MONTHS[m] .. " " .. day .. ", " .. L.year
end

-- News -------------------------------------------------------------------------------------------
function PL.news(L, text, mine)
  table.insert(L.news, 1, { d = L.day, t = text, m = mine or nil })
  while #L.news > 40 do table.remove(L.news) end
end

-- Standings ----------------------------------------------------------------------------------------
function PL.pct(T) local g = T.w + T.l return g > 0 and T.w / g or 0 end

function PL.standings(L)
  local t = {}
  for _, c in ipairs(PennantClubs) do t[#t + 1] = L.teams[c.abbr] end
  table.sort(t, function(a, b)
    local pa, pb = PL.pct(a), PL.pct(b)
    if pa ~= pb then return pa > pb end
    if a.w ~= b.w then return a.w > b.w end
    return (a.rs - a.ra) > (b.rs - b.ra)
  end)
  local lead = t[1]
  for _, T in ipairs(t) do T.gb = ((lead.w - T.w) + (T.l - lead.l)) / 2 end
  return t
end

function PL.gbText(gb) if gb <= 0 then return "-" end return (gb % 1 == 0) and tostring(floor(gb)) or string.format("%.1f", gb) end

function PL.rank(L, abbr)
  for i, T in ipairs(PL.standings(L)) do if T.abbr == abbr then return i end end
  return 8
end

function PL.l10(T)
  local w, l = 0, 0
  for _, r in ipairs(T.l10 or {}) do if r == 1 then w = w + 1 else l = l + 1 end end
  return w .. "-" .. l
end

function PL.streakText(T)
  local s = T.streak or 0
  if s == 0 then return "-" end
  return (s > 0 and "W" or "L") .. abs(s)
end

-- The schedule -------------------------------------------------------------------------------------
function PL.today(L) return L.sched[L.day] end

function PL.gameFor(L, abbr, d)
  local day = L.sched[d or L.day]
  if not day then return nil end
  for i, g in ipairs(day.games) do if g.h == abbr or g.a == abbr then return g, i end end
  return nil
end

--- The next day (>= L.day) with a game for abbr.
function PL.nextGame(L, abbr)
  for d = L.day, #L.sched do
    local g = PL.gameFor(L, abbr, d)
    if g and not g.done then return g, d end
  end
  return nil
end

--- Series stops for a club's season: { host, opp, home, d0, d1, w, l, done, round }.
function PL.route(L, abbr)
  local out, cur = {}, nil
  for d, day in ipairs(L.sched) do
    if not day.off and not day.po then
      for _, g in ipairs(day.games) do
        if g.h == abbr or g.a == abbr then
          local home = g.h == abbr
          local opp = home and g.a or g.h
          if not cur or cur.round ~= day.round then
            cur = { host = g.h, opp = opp, home = home, d0 = d, d1 = d, w = 0, l = 0, done = 0, n = 0, round = day.round }
            out[#out + 1] = cur
          end
          cur.d1 = d
          cur.n = cur.n + 1
          if g.done then
            cur.done = cur.done + 1
            local mine = home and g.hs or g.as
            local theirs = home and g.as or g.hs
            if mine > theirs then cur.w = cur.w + 1 elseif mine < theirs then cur.l = cur.l + 1 end
          end
        end
      end
    end
  end
  return out
end

--- Consecutive road days (games) up to and including day d for abbr (0 when at home).
function PL.roadStreak(L, abbr, d)
  local n = 0
  for k = d, 1, -1 do
    local day = L.sched[k]
    if day and not day.off then
      local g = PL.gameFor(L, abbr, k)
      if g then
        if g.a == abbr then n = n + 1 else break end
      end
    end
  end
  return n
end

--- Games in the road trip (or homestand) that starts with the club's next game.
function PL.roadTripLen(L, abbr)
  local _, d = PL.nextGame(L, abbr)
  if not d then return 0 end
  local first = PL.gameFor(L, abbr, d)
  local away = first.a == abbr
  local n = 0
  for k = d, #L.sched do
    local day = L.sched[k]
    if not day.off then
      local g = PL.gameFor(L, abbr, k)
      if g then if (g.a == abbr) == away then n = n + 1 else break end end
    end
  end
  return n
end

-- Building a game ----------------------------------------------------------------------------------

--- The engine's view of a player (ratings include condition / mood / fatigue).
function PL.view(p, abbr, norm)
  local b = PM.formBonus(p)
  local r = p.r
  local nb, np = norm and norm.bat or 0, norm and norm.pit or 0
  local v = { id = "p" .. p.id, name = PM.name(p), short = PM.short(p), face = "face:" .. p.face,
    bats = p.bats, throws = p.throws, pos = p.pos, fat = p.fat or 0, teamAbbr = abbr }
  if p.pos == "P" then
    v.velo = clamp(r.velo + b * 0.5 - np, 15, 85)
    v.ctl = clamp(r.ctl + b - np, 15, 85)
    v.stf = clamp(r.stf + b - np, 15, 85)
    v.sta = r.sta
    v.pitches = {}
    for i, pt in ipairs(p.pitches) do v.pitches[i] = { k = pt.k, q = clamp(pt.q + b - np, 15, 85) } end
    -- pitchers don't bat (DH)
    v.con, v.pow, v.eye, v.spd, v.fld, v.arm = 25, 20, 25, 30, 40, 50
  else
    v.con = clamp(r.con + b - nb, 15, 85)
    v.pow = clamp(r.pow + b - nb, 15, 85)
    v.eye = clamp(r.eye + b - nb, 15, 85)
    v.spd = clamp(r.spd + b * 0.5, 15, 85)
    v.fld = clamp(r.fld + b * 0.5, 15, 85)
    v.arm = r.arm
  end
  return v
end

--- The race in a few words: the magic / elimination number once half the season is gone, the
--- games back before that.
function PL.raceNumber(L)
  local T = L.teams[L.user]
  local m, e = PL.magic(L, L.user), PL.elimination(L, L.user)
  if m and m <= 0 then return "CLINCHED" end
  if e and e <= 0 then return "ELIMINATED" end
  if (T.w + T.l) * 2 >= PL.seasonGames(L) then
    if m then return "MAGIC # " .. m end
    if e then return "ELIM # " .. e end
  end
  PL.standings(L)
  return (T.gb or 0) <= 0 and "IN FIRST" or (PL.gbText(T.gb) .. " GB")
end

--- The trade deadline: two-thirds through the regular season.
function PL.deadline(L) return math.floor((L.regDays or #L.sched) * 2 / 3) end
function PL.tradeOpen(L) return L.phase ~= "season" or L.day <= PL.deadline(L) end

--- Now and then (before the deadline) a club phones with an offer the user can take or leave.
function PL.maybeTradeCall(L)
  if L.phase ~= "season" or not PL.tradeOpen(L) then L.tradeCall = nil return end
  if L.tradeCall and L.day - L.tradeCall.day > 2 then L.tradeCall = nil end
  if L.tradeCall or L.day - (L.lastCall or 0) < 12 or L.day < 10 then return end
  local rng = PL.rng(L, 91)
  if not rng:chance(0.3) then return end
  local list = {}
  for _, c in ipairs(PennantClubs) do if c.abbr ~= L.user then list[#list + 1] = c.abbr end end
  local from = list[rng:int(#list)]
  local give, get = PRoster.aiOffer(L, L.teams[L.user], L.teams[from])
  L.lastCall = L.day
  if give then L.tradeCall = { from = from, give = give, get = get, day = L.day } end
end

--- Injuries waiting for the Trainer's Room (fresh ones: today or yesterday; healed or traded drop out).
function PL.trainerPending(L)
  local q = L.trainerQ
  if not q then return nil end
  local keep = {}
  for _, e in ipairs(q) do
    local p = L.players[e.id]
    if p and p.inj and p.team == L.user and p.lvl ~= "F" and L.day - e.day < 2 then keep[#keep + 1] = e end
  end
  L.trainerQ = #keep > 0 and keep or nil
  return L.trainerQ and L.trainerQ[1] or nil
end

--- The opposing starter's hand today ("R"|"L"), or nil without a game.
function PL.vsHand(L, abbr, d)
  local g = PL.gameFor(L, abbr, d)
  if not g then return nil end
  local opp = L.teams[g.h == abbr and g.a or g.h]
  local sp = opp and opp.rot and #opp.rot > 0 and PRoster.starter(L, opp)
  local p = sp and L.players[sp]
  return (p and p.throws == "L") and "L" or "R"
end

--- The user's club plays today's platoon card (vs RHP / vs LHP). Returns the hand.
function PL.todayCard(L, abbr)
  abbr = abbr or L.user
  if abbr ~= L.user then return nil end
  local vs = PL.vsHand(L, abbr)
  if vs then PRoster.useCard(L, L.teams[abbr], vs) end
  return vs
end

function PL.sideSpec(L, abbr, ctrl)
  local T = L.teams[abbr]
  PL.todayCard(L, abbr)
  local notes = PRoster.validate(L, T)
  if abbr == L.user and #notes > 0 then L.lineupNotes = notes end
  local sp, idx = PRoster.starter(L, T)
  T.todaySp, T.todaySpIdx = sp, idx
  local s = { abbr = abbr, ctrl = ctrl, order = {}, field = {}, sp = sp, pen = {}, roles = {}, bench = {}, p = {} }
  for i, id in ipairs(T.order) do s.order[i] = id s.field[id] = T.field[id] or "DH" end
  for _, id in ipairs(T.ml) do
    local p = P(L, id)
    if p and not p.inj and (p.late or 0) <= 0 then s.p[id] = PL.view(p, abbr, L.norm) end
  end
  s.p[sp] = s.p[sp] or PL.view(P(L, sp), abbr, L.norm)
  for id, role in pairs(T.pen or {}) do
    if s.p[id] and id ~= sp then s.pen[#s.pen + 1] = id s.roles[id] = role end
  end
  table.sort(s.pen)
  for _, id in ipairs(PRoster.bench(L, T)) do if s.p[id] then s.bench[#s.bench + 1] = id end end
  return s
end

function PL.spec(L, g, ctrlFor)
  local c = PennantClubs.byAbbr[g.h]
  L.gseq = (L.gseq or 0) + 1
  local spec = {
    id = "d" .. L.day .. g.h, seed = (L.seed * 977 + L.day * 131 + c.idx * 17 + L.gseq) & 0x7FFFFFFF,
    park = { fences = c.fences, alt = c.alt, walls = c.walls },
    home = PL.sideSpec(L, g.h, ctrlFor and ctrlFor[g.h]),
    away = PL.sideSpec(L, g.a, ctrlFor and ctrlFor[g.a]),
  }
  return spec
end

--- BallCast's view of the people in a game and the park.
function PL.people(spec)
  local people = {}
  for _, key in ipairs({ "home", "away" }) do
    local s = spec[key]
    for id, v in pairs(s.p) do
      people[v.id] = { id = v.id, name = v.name, face = v.face, teamAbbr = s.abbr, pos = s.field[id] or v.pos }
    end
  end
  return people
end

function PL.park(abbr)
  local c = PennantClubs.byAbbr[abbr]
  return { id = "park-" .. abbr:lower(), name = c.park, fences = c.fences, walls = c.walls, altitudeFt = c.alt,
    foulTerritory = c.foul, turf = c.turf }
end

-- Results -----------------------------------------------------------------------------------------

local function boxSide(L, s)
  local bat, pit = {}, {}
  for _, id in ipairs(s.order) do end
  -- batting lines in lineup order, then subs
  local seen = {}
  local function addBat(id)
    if seen[id] or not s.bat[id] then return end
    seen[id] = true
    local b = s.bat[id]
    bat[#bat + 1] = { id, b.ab or 0, b.r or 0, b.h or 0, b.rbi or 0, b.bb or 0, b.k or 0, b.hr or 0 }
  end
  for _, id in ipairs(s.order) do addBat(id) end
  for id in pairs(s.bat) do addBat(id) end
  for _, id in ipairs(s.pitchOrder) do
    local p = s.pitch[id] or {}
    pit[#pit + 1] = { id, p.outs or 0, p.h or 0, p.r or 0, p.er or 0, p.bb or 0, p.k or 0, p.np or 0 }
  end
  return { r = s.runs, h = s.hits, e = s.errors, line = s.line, bat = bat, pit = pit }
end

--- Apply a finished game: stats, standings, fatigue, the rotation, a box score, injuries.
function PL.apply(L, g, res)
  if g.done then return end
  g.done = true
  g.queued = nil
  g.hs, g.as = res.home.runs, res.away.runs
  g.inn = res.innings
  g.W, g.L, g.S = res.W, res.L, res.S
  local key = L.day .. ":" .. g.h
  L.boxes[key] = { h = g.h, a = g.a, d = L.day, home = boxSide(L, res.home), away = boxSide(L, res.away), inn = res.innings, W = res.W, L = res.L, S = res.S }
  g.box = key
  local rng = PL.rng(L, 5)
  for _, side in ipairs({ { res.home, g.h, res.away }, { res.away, g.a, res.home } }) do
    local s, abbr, o = side[1], side[2], side[3]
    local T = L.teams[abbr]
    if not g.po then
      local won = s.runs > o.runs
      if s.runs ~= o.runs then
        if won then T.w = T.w + 1 else T.l = T.l + 1 end
        T.streak = won and (T.streak > 0 and T.streak + 1 or 1) or (T.streak < 0 and T.streak - 1 or -1)
        T.l10[#T.l10 + 1] = won and 1 or 0
        while #T.l10 > 10 do table.remove(T.l10, 1) end
      end
      T.rs, T.ra = T.rs + s.runs, T.ra + o.runs
    end
    -- the rotation turns over
    if T.todaySpIdx then T.rotIdx = T.todaySpIdx % math.max(1, #T.rot) + 1 end
    for id, line in pairs(s.bat) do
      local p = P(L, id)
      if p then
        if not g.po then PM.addStats(p.st.b, line) end
        p.playedToday = true
        p.fat = clamp((p.fat or 0) + (T.field and T.field[id] == "C" and 6 or 4), 0, 100)
        -- a big day lifts the arrows, an ugly one drops them
        local h, ab, k = line.h or 0, line.ab or 0, line.k or 0
        if h >= 2 or (line.hr or 0) >= 1 then if rng:chance(0.35) then p.cond = min(5, p.cond + 1) end
        elseif ab >= 4 and h == 0 and k >= 2 then if rng:chance(0.3) then p.cond = max(1, p.cond - 1) end end
      end
    end
    for i, id in ipairs(s.pitchOrder) do
      local p = P(L, id)
      local line = s.pitch[id] or {}
      if p then
        if not g.po then PM.addStats(p.st.p, line) end
        p.playedToday = true
        local np = line.np or 0
        if i == 1 then p.fat = clamp((p.fat or 0) + np * 0.72, 0, 100)
        else p.fat = clamp((p.fat or 0) + 8 + np * 0.8, 0, 100) end
        local er, outs = line.er or 0, line.outs or 0
        if i == 1 and outs >= 18 and er <= 2 then if rng:chance(0.45) then p.cond = min(5, p.cond + 1) end
        elseif er >= 5 then if rng:chance(0.45) then p.cond = max(1, p.cond - 1) end end
      end
    end
  end
  -- the engine's own injuries (HBP bruises) and the pitch counts for rest (recentPitches)
  for _, k in ipairs({ "home", "away" }) do
    for id, n in pairs(res[k].pc or {}) do
      local p = P(L, id)
      if p then p.rp = p.rp or { 0, 0, 0, 0, 0 } p.rp[1] = (p.rp[1] or 0) + n end
    end
  end
  for _, inj in ipairs(res.injuries or {}) do
    local p = P(L, inj.id)
    if p and not p.inj then
      p.inj = { k = inj.kind or "bruise", d = math.max(1, inj.days or 3) }
      if p.team == L.user then
        PL.news(L, string.format("INJURY: %s (%s): out %d days", PM.name(p), p.inj.k, p.inj.d), true)
        L.alerts = L.alerts or {}
        L.alerts[#L.alerts + 1] = { kind = "inj", id = p.id }
        L.trainerQ = L.trainerQ or {} L.trainerQ[#L.trainerQ + 1] = { id = p.id, day = L.day }
      end
    end
  end
  -- game injuries: anyone who played, by fatigue and age
  for _, abbr in ipairs({ g.h, g.a }) do
    local T = L.teams[abbr]
    for _, id in ipairs(T.ml) do
      local p = P(L, id)
      if p and p.playedToday and not p.inj then
        local risk = 0.0024 * (1 + (p.fat or 0) / 45) * (p.age >= 33 and 1.5 or 1)
        if rng:chance(risk) then PL.injure(L, p, rng, false) end
      end
    end
  end
  if PL.onApply then PL.onApply(L, g, res) end
  -- headline
  local hw = g.hs > g.as
  local wT, lT = hw and g.h or g.a, hw and g.a or g.h
  local ws, ls = max(g.hs, g.as), min(g.hs, g.as)
  local mine = g.h == L.user or g.a == L.user
  if mine then
    local won = wT == L.user
    local opp = L.user == g.h and g.a or g.h
    PL.news(L, string.format("%s %s %d-%d %s %s", PennantClubs.byAbbr[L.user].name:upper(), won and "BEAT" or "FALL TO",
      won and ws or ls, won and ls or ws, (L.user == g.h) and "vs" or "at", PennantClubs.byAbbr[opp].name), true)
  elseif ws - ls >= 9 then
    PL.news(L, string.format("%s rout %s %d-%d", PennantClubs.byAbbr[wT].name, PennantClubs.byAbbr[lT].name, ws, ls))
  end
end

local INJ_BAT <const> = { { "jammed finger", 2, 6, 20 }, { "sore hamstring", 4, 12, 22 }, { "sprained ankle", 6, 18, 18 },
  { "pulled groin", 8, 20, 12 }, { "strained oblique", 12, 28, 12 }, { "broken wrist", 30, 55, 4 }, { "torn knee ligament", 50, 110, 2 } }
local INJ_PIT <const> = { { "blister", 2, 6, 20 }, { "tired arm", 5, 14, 24 }, { "sore elbow", 10, 25, 18 },
  { "strained shoulder", 15, 40, 10 }, { "torn elbow ligament", 60, 150, 2 } }

function PL.injure(L, p, rng, training)
  local list = p.pos == "P" and INJ_PIT or INJ_BAT
  local tot = 0
  for _, e in ipairs(list) do tot = tot + e[4] end
  local x = rng:float() * tot
  local pick = list[1]
  for _, e in ipairs(list) do x = x - e[4] if x <= 0 then pick = e break end end
  local d = pick[2] + rng:int(pick[3] - pick[2] + 1) - 1
  if training then d = max(2, floor(d * 0.6)) end
  p.inj = { k = pick[1], d = d }
  p.cond = max(1, (p.cond or 3) - 1)
  if p.team == L.user then
    PL.news(L, string.format("%s %s (%s, %s): out %d days", training and "TRAINING:" or "INJURY:", PM.name(p), p.pos, pick[1], d), true)
    L.alerts = L.alerts or {}
    L.alerts[#L.alerts + 1] = { kind = "inj", id = p.id }
    L.trainerQ = L.trainerQ or {} L.trainerQ[#L.trainerQ + 1] = { id = p.id, day = L.day }
  end
end

-- Training -------------------------------------------------------------------------------------------

PL.INTENSITY = { "Rest", "Light", "Normal", "Hard" }
PL.XP_PER_POINT = 15
local BASE_XP <const> = { 0, 0.5, 0.95, 1.6 }
local TRAIN_FAT <const> = { -5, 0, 1, 3 }
PL.FOCI_BAT = { "con", "pow", "eye", "spd", "fld", "arm" }
PL.FOCI_PIT = { "velo", "ctl", "sta", "pit" }
PL.FOCUS_NAME = { con = "Contact", pow = "Power", eye = "Eye", spd = "Speed", fld = "Fielding", arm = "Arm",
  velo = "Velocity", ctl = "Control", sta = "Stamina", pit = "Pitch dev." }

local function ageFactor(a)
  if a <= 21 then return 1.35 elseif a <= 24 then return 1.25 elseif a <= 27 then return 1.0
  elseif a <= 30 then return 0.7 elseif a <= 33 then return 0.45 end
  return 0.25
end
PL.ageFactor = ageFactor

--- The pitch a pitcher is developing (his choice, else his weakest secondary).
function PL.devPitch(p)
  if p.pitchDev then return p.pitchDev end
  local worst, wq = nil, 999
  for i, pt in ipairs(p.pitches) do if i > 1 and pt.q < wq then worst, wq = pt.k, pt.q end end
  return worst or p.pitches[1].k
end

--- Expected rating points a week for plan (f, i) (the training screen's preview).
function PL.weekly(p, f, i)
  local key = f == "pit" and "stf" or f
  local room = (p.cap[key] or 80) - (p.r[key] or 50)
  local rf = room <= 0 and 0.05 or min(1, 0.35 + room / 12)
  local cf = ({ 0.7, 0.85, 1, 1.1, 1.25 })[p.cond or 3]
  return BASE_XP[(i or 2) + 1] * ageFactor(p.age) * rf * cf * 7 / PL.XP_PER_POINT * (p.lvl == "F" and 1.15 or 1)
end

--- One day of training for one player.
function PL.trainDay(L, p, rng, offDay)
  local plan = p.plan or { i = 2 }
  local i = plan.i or 2
  local f = plan.f
  if p.inj then i = 0 end
  local valid = false
  for _, k in ipairs(p.pos == "P" and PL.FOCI_PIT or PL.FOCI_BAT) do if k == f then valid = true end end
  if not valid then f = (p.pos == "P") and "ctl" or "con" plan.f = f end
  -- fatigue / condition / injury risk
  p.fat = clamp((p.fat or 0) + TRAIN_FAT[i + 1], 0, 100)
  if i == 3 and not p.inj then
    if rng:chance(0.0018 * (1 + (p.fat or 0) / 30)) then PL.injure(L, p, rng, true) return end
    if rng:chance(0.04) then p.cond = max(1, p.cond - 1) end
  elseif i == 0 and rng:chance(0.12) then
    p.cond = min(5, p.cond + 1)
  end
  if i == 0 then return end
  local key = f == "pit" and "stf" or f
  local room = (p.cap[key] or 80) - (p.r[key] or 50)
  local rf = room <= 0 and 0.05 or min(1, 0.35 + room / 12)
  local cf = ({ 0.7, 0.85, 1, 1.1, 1.25 })[p.cond or 3]
  local xp = BASE_XP[i + 1] * ageFactor(p.age) * rf * cf * rng:range(0.75, 1.25) * (p.lvl == "F" and 1.15 or 1)
  p.xp[key] = (p.xp[key] or 0) + xp
  while p.xp[key] >= PL.XP_PER_POINT do
    p.xp[key] = p.xp[key] - PL.XP_PER_POINT
    if (p.r[key] or 0) < (p.cap[key] or 80) or rng:chance(0.15) then
      p.r[key] = min(80, (p.r[key] or 50) + 1)
      if p.r[key] > (p.cap[key] or 80) then p.cap[key] = p.r[key] end
    end
    if f == "pit" then
      local k = PL.devPitch(p)
      local have = nil
      for _, pt in ipairs(p.pitches) do if pt.k == k then have = pt end end
      if have then
        have.q = min(80, have.q + 1.5)
      else
        p.xp.newp = (p.xp.newp or 0) + 1
        if p.xp.newp >= 3 then
          p.pitches[#p.pitches + 1] = { k = k, q = 32 }
          p.xp.newp = nil
          p.learned = k
          if p.team == L.user then PL.news(L, PM.name(p) .. " has learned a " .. (PM.PITCH_NAME[k] or k):lower(), true) end
        end
      end
    end
    -- fastball quality follows velocity and stuff
    if p.pos == "P" and (key == "velo" or key == "stf") then
      local fb = p.pitches[1]
      fb.q = min(80, max(fb.q, (p.r.velo + p.r.stf) / 2))
    end
  end
end

--- AI clubs set sensible plans: the biggest room to grow, rest when worn out.
function PL.aiPlan(L, T)
  for _, list in ipairs({ T.ml, T.farm }) do
    for _, id in ipairs(list) do
      local p = P(L, id)
      local best, bv = nil, -1
      for _, k in ipairs(p.pos == "P" and PL.FOCI_PIT or PL.FOCI_BAT) do
        local key = k == "pit" and "stf" or k
        local room = (p.cap[key] or 0) - (p.r[key] or 0)
        if room > bv then best, bv = k, room end
      end
      p.plan = p.plan or {}
      p.plan.f = best
      p.plan.i = (p.fat or 0) > 60 and 1 or 2
    end
  end
end

-- The day ----------------------------------------------------------------------------------------------

--- Games still to play today (not done).
function PL.pending(L)
  local out = {}
  local day = PL.today(L)
  if not day then return out end
  for _, g in ipairs(day.games) do if not g.done then out[#out + 1] = g end end
  return out
end

--- Simulate one game outright (AI both sides).
function PL.simGame(L, g)
  PEng.simNow(L, g)
end

--- After every game today: recovery, condition, mood, injuries healing, training, road trips,
--- AI rosters, the week's training report. Then the calendar moves on. Returns a day report.
--- Y (optional): called between clubs, so a caller can spread the day's close over frames.
function PL.finishDay(L, Y)
  local day = PL.today(L)
  local rng = PL.rng(L, 11)
  local report = { day = L.day, mine = PL.gameFor(L, L.user), changes = {} }
  local off = day and day.off
  -- before: snapshot the user's arrows
  local before = {}
  for _, id in ipairs(L.teams[L.user].ml) do local p = P(L, id) before[id] = p.cond end
  for abbr, T in pairs(L.teams) do
    local rs = (not off) and PL.roadStreak(L, abbr, L.day) or 0
    local g = (not off) and PL.gameFor(L, abbr) or nil
    local homeNow = g and g.h == abbr
    if homeNow and T.road and T.road >= 6 and not T.homeBump then
      -- back from a long road trip: the homestand lifts spirits
      for _, id in ipairs(T.ml) do local p = P(L, id) p.mood = min(2, (p.mood or 0) + 1) end
      T.homeBump = true
      if abbr == L.user then PL.news(L, "Home at last after a " .. T.road .. "-game road trip. Morale up.", true) end
    end
    if rs > 0 then T.homeBump = false end
    T.road = rs
    if T.streak >= 4 or T.streak <= -4 then
      for _, id in ipairs(T.ml) do
        local p = P(L, id)
        if rng:chance(0.25) then p.mood = clamp((p.mood or 0) + (T.streak > 0 and 1 or -1), -2, 2) end
      end
    end
    for _, list in ipairs({ T.ml, T.farm }) do
      for _, id in ipairs(list) do
        local p = P(L, id)
        local played = p.playedToday
        p.playedToday = nil
        if (p.late or 0) > 0 then p.late = p.late - 1 end
        -- the engine's rest model: pitches thrown on recent days, today first
        if p.pos == "P" then
          p.rp = p.rp or { 0, 0, 0, 0, 0 }
          table.insert(p.rp, 1, 0)
          p.rp[6] = nil
        end
        -- recovery
        -- recovery: pitchers by role (their game load is big); position players a steady 5 a
        -- day, more on the bench and on off days (an everyday catcher still needs a day off)
        local rec
        if p.pos == "P" then
          rec = (p.role == "SP" and 15 or 20) + (off and 6 or 0)
          if played then rec = rec * 0.35 end
        else
          rec = 5 + (played and 0 or 3) + (off and 6 or 0)
        end
        p.fat = clamp((p.fat or 0) - rec, 0, 100)
        -- long road trips wear people down
        if rs >= 6 and list == T.ml then
          p.fat = clamp(p.fat + 1.5, 0, 100)
          if rng:chance(0.03) then p.cond = max(1, p.cond - 1) end
        end
        -- injuries heal
        if p.inj then
          p.inj.d = p.inj.d - 1
          if p.inj.d <= 0 then
            if abbr == L.user then PL.news(L, PM.name(p) .. " is back from the " .. p.inj.k .. ".", true) end
            p.inj = nil
          end
        end
        -- condition drifts: mood and rest help, fatigue hurts, extremes pull back
        if rng:chance(0.22) then
          local up = 0.5 + (p.mood or 0) * 0.08 - ((p.fat or 0) - 35) / 160
          if p.cond >= 5 then up = up - 0.25 elseif p.cond <= 1 then up = up + 0.25 end
          if rng:chance(clamp(up, 0.08, 0.92)) then p.cond = min(5, p.cond + 1) else p.cond = max(1, p.cond - 1) end
        end
        -- mood drifts back to fine
        if (p.mood or 0) ~= 0 and rng:chance(0.08) then p.mood = p.mood - (p.mood > 0 and 1 or -1) end
        -- benched regulars sulk
        if list == T.ml and p.pos ~= "P" and not off then
          if played then p.sat = 0 else p.sat = (p.sat or 0) + 1 end
          if (p.sat or 0) >= 6 and PM.ovr(p) >= 50 and rng:chance(0.2) then p.mood = max(-2, (p.mood or 0) - 1) end
        end
        PL.trainDay(L, p, rng, off)
        if Y then Y("player") end
      end
    end
    if abbr ~= L.user then
      PRoster.aiMaintain(L, T)
      if Y then Y("aiMaintain") end
      if (L.day % 7) == 1 then PL.aiPlan(L, T) if Y then Y("aiPlan") end end
      PRoster.autoLineup(L, T)
      if Y then Y("autoLineup") end
      PRoster.autoPitching(L, T)
    elseif L.settings.autoRoster ~= false and not PL.trainerPending(L) then
      -- the user's assistant GM covers injuries with call-ups (Settings can turn it off); a fresh
      -- injury waits two days for the Trainer's Room, where the user picks the fix
      L.trainerQ = nil
      local before = #T.farm
      PRoster.aiMaintain(L, T)
      if #T.farm ~= before then PL.news(L, "Roster move: the assistant GM covered an injury from the farm.", true) end
      PRoster.validate(L, T)
    end
    if Y then Y("autoPitching/validate") end
  end
  -- the user's arrows that moved today
  for _, id in ipairs(L.teams[L.user].ml) do
    local p = P(L, id)
    if before[id] and p.cond ~= before[id] then report.changes[#report.changes + 1] = { id = id, from = before[id], to = p.cond } end
  end
  -- week's end: the training report
  L.dayCount = (L.dayCount or 0) + 1
  if off or (L.phase ~= "season" and L.dayCount % 7 == 0) then PL.weekReport(L) end
  L.day = L.day + 1
  if L.phase == "season" and L.day > #L.sched then
    PL.startPlayoffs(L)
  elseif L.phase == "playoffs" then
    PL.playoffAdvance(L, Y)
  end
  return report
end

--- Each rating plus the training XP banked toward its next point (a fractional rating).
function PL.progress(p)
  local t = {}
  for k, v in pairs(p.r) do t[k] = v + (p.xp[k] or 0) / PL.XP_PER_POINT end
  return t
end

--- Rating changes since the last report, for the user's club (big club + farm).
function PL.weekReport(L)
  local T = L.teams[L.user]
  local rows = {}
  for _, list in ipairs({ T.ml, T.farm }) do
    for _, id in ipairs(list) do
      local p = P(L, id)
      -- progress = rating + training XP toward the next point, so a week of work always shows
      local now = PL.progress(p)
      local wkx = p.wkx or now
      local d = {}
      local any = false
      for k, v in pairs(now) do
        local dv = floor((v - (wkx[k] or v)) * 10 + 0.5) / 10
        if dv >= 0.1 or dv <= -1 then d[k] = dv any = true end
      end
      if any or p.learned then rows[#rows + 1] = { id = id, d = d, now = now, learned = p.learned } end
      p.learned = nil
      p.wk = PM.snapshot(p)
      p.wkx = now
    end
  end
  table.sort(rows, function(a, b)
    local sa, sb = 0, 0
    for _, v in pairs(a.d) do sa = sa + v end
    for _, v in pairs(b.d) do sb = sb + v end
    return sa > sb
  end)
  L.week = (L.week or 1) + 1
  L.weekRep = { week = L.week - 1, rows = rows, seen = false }
end

-- Playoffs ---------------------------------------------------------------------------------------------

local function poGames(L)
  -- schedule the next game of every live series as one day
  local day = { games = {}, po = true }
  for si, s in ipairs(L.po.series) do
    if not s.winner then
      local n = s.w[1] + s.w[2] + 1
      local pattern = s.need == 3 and { 1, 1, 2, 2, 1 } or { 1, 1, 2, 2, 2, 1, 1 }
      local hiHome = pattern[n] == 1
      day.games[#day.games + 1] = { h = hiHome and s.hi or s.lo, a = hiHome and s.lo or s.hi, po = true, si = si, rd = L.po.round }
    end
  end
  L.sched[#L.sched + 1] = day
end

function PL.startPlayoffs(L)
  L.phase = "playoffs"
  local st = PL.standings(L)
  L.seeds = { st[1].abbr, st[2].abbr, st[3].abbr, st[4].abbr }
  L.po = { round = 1, series = {
    { hi = st[1].abbr, lo = st[4].abbr, w = { 0, 0 }, need = 3 },
    { hi = st[2].abbr, lo = st[3].abbr, w = { 0, 0 }, need = 3 },
  } }
  L.regEnd = #L.sched
  PL.news(L, string.format("PLAYOFFS: %s vs %s, %s vs %s", st[1].abbr, st[4].abbr, st[2].abbr, st[3].abbr), true)
  poGames(L)
end

--- After a playoff day: tally series, start the final, crown a champion.
function PL.playoffAdvance(L, Y)
  local day = L.sched[L.day - 1]
  for _, g in ipairs(day and day.games or {}) do
    local s = g.si and g.rd == L.po.round and L.po.series[g.si]
    if s and g.done and not g.counted then
      g.counted = true
      local winner = g.hs > g.as and g.h or g.a
      if winner == s.hi then s.w[1] = s.w[1] + 1 else s.w[2] = s.w[2] + 1 end
      if s.w[1] >= s.need then s.winner = s.hi elseif s.w[2] >= s.need then s.winner = s.lo end
      if s.winner then
        local loser = s.winner == s.hi and s.lo or s.hi
        PL.news(L, string.format("%s eliminate %s, %d games to %d", PennantClubs.byAbbr[s.winner].name, PennantClubs.byAbbr[loser].name, max(s.w[1], s.w[2]), min(s.w[1], s.w[2])), s.winner == L.user or loser == L.user)
      end
    end
  end
  local live = false
  for _, s in ipairs(L.po.series) do if not s.winner then live = true end end
  if live then poGames(L) return end
  if L.po.round == 1 then
    local a, b = L.po.series[1].winner, L.po.series[2].winner
    -- the better seed is "hi"
    local ia, ib = 0, 0
    for i, x in ipairs(L.seeds) do if x == a then ia = i end if x == b then ib = i end end
    if ib < ia then a, b = b, a end
    L.po.round = 2
    L.po.semis = L.po.series
    L.po.series = { { hi = a, lo = b, w = { 0, 0 }, need = 4, final = true } }
    PL.news(L, string.format("THE PENNANT SERIES: %s vs %s", a, b), a == L.user or b == L.user)
    poGames(L)
  else
    local s = L.po.series[1]
    L.champ = s.winner
    L.runnerUp = s.winner == s.hi and s.lo or s.hi
    L.phase = "awards"
    PL.news(L, string.format("%s %s WIN THE %d PENNANT", PennantClubs.byAbbr[s.winner].city:upper(), PennantClubs.byAbbr[s.winner].name:upper(), L.year), true)
    PL.awards(L, Y)
  end
end

-- Leaders & awards -------------------------------------------------------------------------------------

function PL.teamGames(L) local T = L.teams[L.user] return max(1, T.w + T.l) end

--- Leaders: kind = "avg","hr","rbi","sb","h","obp" (hitters) | "era","w","k","sv","whip" (pitchers)
-- leaders only change when games do: memo per day (not part of the save)
local leaderMemo = setmetatable({}, { __mode = "k" })
function PL.leaders(L, kind, n, abbr)
  local m = leaderMemo[L]
  local key = (L.season or 0) .. ":" .. (L.dayCount or 0) .. ":" .. L.day .. ":" .. kind .. ":" .. (n or 5) .. ":" .. (abbr or "")
  if not m or m.stamp ~= L.season .. ":" .. (L.dayCount or 0) .. ":" .. L.day then m = { stamp = L.season .. ":" .. (L.dayCount or 0) .. ":" .. L.day } leaderMemo[L] = m end
  if m[key] then return m[key] end
  local r = PL.leadersRaw(L, kind, n, abbr)
  m[key] = r
  return r
end

function PL.leadersRaw(L, kind, n, abbr)
  local G = PL.teamGames(L)
  local out = {}
  local pit = kind == "era" or kind == "w" or kind == "k" or kind == "sv" or kind == "whip" or kind == "pk"
  for id, p in pairs(L.players) do
    if (p.lvl == "ML") and (not abbr or p.team == abbr) then
      if pit then
        local s = p.st.p
        local outs = s.outs or 0
        local v
        if kind == "era" then if outs >= G * 3 then v = -PM.era(s) end
        elseif kind == "whip" then if outs >= G * 3 then v = -PM.whip(s) end
        elseif kind == "pk" then v = s.k
        else v = s[kind] end
        if v and (v ~= 0 or kind == "era") then out[#out + 1] = { id = id, v = v } end
      elseif p.pos ~= "P" then
        local s = p.st.b
        local v
        if kind == "avg" then if (s.pa or 0) >= G * 2.7 then v = PM.avg(s) end
        elseif kind == "obp" then if (s.pa or 0) >= G * 2.7 then v = PM.obp(s) end
        elseif kind == "ops" then if (s.pa or 0) >= G * 2.7 then v = PM.obp(s) + PM.slg(s) end
        else v = s[kind] end
        if v and v ~= 0 then out[#out + 1] = { id = id, v = v } end
      end
    end
  end
  table.sort(out, function(a, b) if a.v ~= b.v then return a.v > b.v end return a.id < b.id end)
  while #out > (n or 5) do table.remove(out) end
  return out
end

function PL.leaderText(kind, v)
  if kind == "avg" or kind == "obp" or kind == "ops" then return PM.rate3(v) end
  if kind == "era" or kind == "whip" then return string.format("%.2f", -v) end
  return tostring(floor(v))
end

--- Value scores for awards.
function PL.batScore(p)
  local s = p.st.b
  local pa = s.pa or 0
  if pa < 30 then return -99 end
  local obp, slg = PM.obp(s), PM.slg(s)
  local posAdj = ({ C = 6, SS = 5, ["2B"] = 3, CF = 3, ["3B"] = 2 })[p.pos] or 0
  return (obp + slg - 0.71) * pa * 0.55 + (s.hr or 0) * 0.3 + (s.sb or 0) * 0.1 + posAdj
end
function PL.pitScore(p)
  local s = p.st.p
  local outs = s.outs or 0
  if outs < 30 then return -99 end
  return (4.4 - PM.era(s)) * outs / 27 + (s.w or 0) * 0.6 + (s.sv or 0) * 0.35 + (s.k or 0) * 0.02
end

function PL.awards(L, Y)
  local function best(fn, filter)
    local b, bv = nil, -1e9
    for id, p in pairs(L.players) do
      if p.lvl == "ML" and (not filter or filter(p)) then
        local v = fn(p)
        if v > bv then b, bv = p, v end
      end
    end
    return b
  end
  local mvp = best(PL.batScore, function(p) return p.pos ~= "P" end)
  if Y then Y() end
  local cy = best(PL.pitScore, function(p) return p.pos == "P" end)
  if Y then Y() end
  local roy = best(function(p) return p.pos == "P" and PL.pitScore(p) * 1.4 or PL.batScore(p) end, function(p) return p.rk end)
  if Y then Y() end
  local A = { year = L.year, champ = L.champ, runnerUp = L.runnerUp, mvp = mvp and mvp.id, cy = cy and cy.id, roy = roy and roy.id, lead = {} }
  for _, k in ipairs({ "avg", "hr", "rbi", "sb", "w", "era", "pk", "sv" }) do
    local l = PL.leaders(L, k, 1)[1]
    if l then A.lead[k] = { id = l.id, v = l.v } end
    if Y then Y() end
  end
  local function honor(p, what) if p then p.awards = (p.awards and (p.awards .. ";") or "") .. L.year .. " " .. what end end
  honor(mvp, "MVP") honor(cy, "Pitcher of the Year") honor(roy, "Rookie of the Year")
  L.awardsRes = A
  return A
end

-- The offseason ------------------------------------------------------------------------------------------

--- Aging, development, retirements, rookies, a fresh schedule. Returns a report for the UI.
--- The winter: the season into the books, aging, retirements, the draft, a new schedule.
--- Y (optional) is called between players and clubs with a label; the caller yields on the clock
--- (a 4 s single frame on the device otherwise).
function PL.offseason(L, Y)
  Y = Y or function() end
  local rng = PL.rng(L, 23)
  local rep = { retired = {}, rookies = {}, grew = {}, declined = {} }
  local ut = L.teams[L.user]
  -- the season into the record book
  local st = PL.standings(L)
  local mine = L.teams[L.user]
  local A = L.awardsRes or {}
  local function nm(id) local p = id and L.players[id] return p and PM.name(p) or "" end
  L.history[#L.history + 1] = { year = L.year, champ = L.champ, runnerUp = L.runnerUp, w = mine.w, l = mine.l, rank = PL.rank(L, L.user),
    mvp = nm(A.mvp), cy = nm(A.cy), roy = nm(A.roy), mvpT = A.mvp and L.players[A.mvp].team, cyT = A.cy and L.players[A.cy].team }
  for _, T in pairs(L.teams) do
    T.hist = T.hist or {}
    T.hist[#T.hist + 1] = { L.year, T.w, T.l }
  end
  -- careers, aging, development
  local used = {}
  for id, p in pairs(L.players) do
    PM.addStats(p.car.b, p.st.b)
    PM.addStats(p.car.p, p.st.p)
    if (p.st.b.g or 0) > 0 or (p.st.p.g or 0) > 0 then p.mlYrs = (p.mlYrs or 0) + 1 end
    p.st = PM.newStats()
    p.age = p.age + 1
    p.yrs = (p.yrs or 0) + 1
    local before = PM.ovr(p)
    for k, v in pairs(p.r) do
      local d
      if p.age <= 26 then d = rng:range(0, 2.2) * (v < (p.cap[k] or 80) and 1 or 0.2)
      elseif p.age <= 30 then d = rng:range(-0.8, 1.0)
      else
        local fast = (k == "spd" or k == "velo" or k == "sta") and 1.4 or 1
        d = -rng:range(0.3, 1.4) * (p.age - 29) * 0.38 * fast
      end
      p.r[k] = clamp(floor(v + d + 0.5), 20, 80)
      if p.age > 30 then p.cap[k] = max(p.r[k], floor((p.cap[k] or 80) - rng:range(0.5, 2) + 0.5)) end
    end
    if p.pos == "P" then
      for _, pt in ipairs(p.pitches) do pt.q = clamp(pt.q + (p.age > 31 and -rng:range(0, 2) or rng:range(-0.5, 1.2)), 20, 80) end
    end
    local after = PM.ovr(p)
    if p.team == L.user then
      if after - before >= 3 then rep.grew[#rep.grew + 1] = { id = id, d = after - before } end
      if after - before <= -3 then rep.declined[#rep.declined + 1] = { id = id, d = after - before } end
    end
    p.fat, p.cond, p.mood = 0, 3, 0
    p.inj = (p.inj and p.inj.d > 60) and { k = p.inj.k, d = p.inj.d - 60 } or nil
    p.rk = false
    p.s0 = PM.snapshot(p)
    p.wk = PM.snapshot(p)
    p.wkx = PL.progress(p)
    used[p.face] = true
    Y("aging")
  end
  -- retirements
  for id, p in pairs(L.players) do
    local o = PM.ovr(p)
    local pr = 0
    if p.age >= 35 then pr = 0.3 + (p.age - 35) * 0.18 end
    if p.age >= 32 and o < 42 then pr = pr + 0.35 end
    if p.lvl == "F" and p.age >= 26 and o < 40 then pr = 0.8 end
    if rng:chance(clamp(pr, 0, 0.97)) then
      local T = L.teams[p.team]
      if T then PRoster.removeId(T.ml, id) PRoster.removeId(T.farm, id) if T.pen then T.pen[id] = nil end PRoster.removeId(T.rot or {}, id) end
      if p.team == L.user then rep.retired[#rep.retired + 1] = { name = PM.name(p), age = p.age, pos = p.pos, mlYrs = p.mlYrs } end
      L.players[id] = nil
      used[p.face] = nil
    end
    Y("retirements")
  end
  -- rookies: refill every farm club
  L.usedFaces = used
  L.usedNames = {}
  for _, p in pairs(L.players) do L.usedNames[p.fn .. p.ln] = true end
  local order = {}
  for i, T in ipairs(st) do order[T.abbr] = i end
  for _, c in ipairs(PennantClubs) do
    local T = L.teams[c.abbr]
    -- draft order: the worst clubs get the best prospects
    local boost = ((order[c.abbr] or 4) - 4.5) * 0.7
    local pit, bat = 0, 0
    for _, id in ipairs(T.farm) do if L.players[id].pos == "P" then pit = pit + 1 else bat = bat + 1 end end
    local adds = max(3, 14 - #T.farm)
    for i = 1, adds do
      local isP = pit < bat or (pit == bat and rng:chance(0.5))
      local pos = isP and "P" or rng:pick(PM.POSITIONS)
      local np = PGen.player(L, rng, { pos = pos, role = isP and (rng:chance(0.45) and "SP" or "RP") or nil, mean = 39 + boost + rng:normal(0, 2), age = 18 + rng:int(4) - 1 })
      np.team, np.lvl = c.abbr, "F"
      np.yrs = 0
      np.s0, np.wk = PM.snapshot(np), PM.snapshot(np)
      np.wkx = PL.progress(np)
      T.farm[#T.farm + 1] = np.id
      if isP then pit = pit + 1 else bat = bat + 1 end
      if c.abbr == L.user then rep.rookies[#rep.rookies + 1] = np.id end
      Y("draft")
    end
    -- trim the farm: release the weakest over the limit
    while #T.farm > PRoster.FARM_MAX do
      local worst, wv = nil, 1e9
      for _, id in ipairs(T.farm) do local v = PRoster.value(L.players[id]) if v < wv then worst, wv = id, v end end
      PRoster.removeId(T.farm, worst)
      L.players[worst] = nil
    end
    PRoster.aiMaintain(L, T)
    Y("rosters")
    T.order = nil
    if T.cards then T.cards = nil T.cardSide = nil end
    PRoster.auto(L, T)
    Y("rosters")
    if c.abbr ~= L.user then PL.aiPlan(L, T) Y("plans") end
    T.w, T.l, T.rs, T.ra, T.streak, T.l10, T.road, T.rotIdx = 0, 0, 0, 0, 0, {}, 0, 1
  end
  L.usedFaces, L.usedNames = nil, nil
  -- rookies this season: never played in the majors
  for _, p in pairs(L.players) do if (p.mlYrs or 0) == 0 then p.rk = true end end
  Y("schedule")
  -- the new season
  L.year = L.year + 1
  L.season = L.season + 1
  L.day = 1
  L.dayCount = 0
  L.week = 1
  L.phase = "season"
  L.po, L.seeds, L.champ, L.runnerUp, L.awardsRes = nil, nil, nil, nil, nil
  L.boxes = {}
  L.alerts = {}
  PGen.schedule(L, PL.rng(L, 31), L.games)
  PL.computeNorm(L)
  PL.news(L, "Opening Day " .. L.year .. ". Every club is 0-0.", true)
  L.offRep = rep
  return rep
end

--- League norms: big-league hitters' and pitchers' average ratings, so league scoring stays
--- level as the talent mix drifts (training, aging, rookies). Games see ratings relative to them.
function PL.computeNorm(L)
  local bs, bn, ps, pn = 0, 0, 0, 0
  for _, T in pairs(L.teams) do
    for _, id in ipairs(T.ml) do
      local p = L.players[id]
      if p.pos == "P" then ps = ps + (p.r.velo + p.r.ctl + p.r.stf) / 3 pn = pn + 1
      else bs = bs + (p.r.con + p.r.pow + p.r.eye) / 3 bn = bn + 1 end
    end
  end
  L.norm = { bat = bn > 0 and (bs / bn - 50) or 0, pit = pn > 0 and (ps / pn - 50) or 0 }
  -- (the generated league is the reference: its offsets are what the engine is tuned on)
  L.norm0 = L.norm0 or { bat = L.norm.bat, pit = L.norm.pit }
  L.norm.bat = L.norm.bat - L.norm0.bat
  L.norm.pit = L.norm.pit - L.norm0.pit
end

--- First-time setup after generation.
function PL.init(L)
  for _, c in ipairs(PennantClubs) do
    local T = L.teams[c.abbr]
    PRoster.auto(L, T)
    PL.aiPlan(L, T)
  end
  for _, p in pairs(L.players) do
    p.s0, p.wk = PM.snapshot(p), PM.snapshot(p)
    p.wkx = PL.progress(p)
    p.rk = (p.lvl == "ML" and (p.mlYrs or 0) == 0)
  end
  L.dayCount = 0
  L.alerts = {}
  PL.computeNorm(L)
  PL.news(L, "Opening Day " .. L.year .. ". Every club is 0-0.", true)
end

-- The race --------------------------------------------------------------------------------------------

--- Games each club plays in the regular season.
function PL.seasonGames(L) return L.games or 84 end

--- Playoff magic number for abbr (top 4 make it): wins by abbr plus losses by the first club outside
--- the line that clinch a spot. nil when abbr is outside the line (see PL.elimination). <= 0: clinched.
function PL.magic(L, abbr)
  local st = PL.standings(L)
  local G = PL.seasonGames(L)
  local rank
  for i, T in ipairs(st) do if T.abbr == abbr then rank = i end end
  if not rank or rank > 4 then return nil end
  local fifth = st[5]
  local T = L.teams[abbr]
  return G + 1 - T.w - fifth.l
end

--- Elimination number for a club outside the top 4: its losses plus the 4th club's wins that end it.
--- <= 0: eliminated.
function PL.elimination(L, abbr)
  local st = PL.standings(L)
  local G = PL.seasonGames(L)
  local rank
  for i, T in ipairs(st) do if T.abbr == abbr then rank = i end end
  if not rank or rank <= 4 then return nil end
  local fourth = st[4]
  local T = L.teams[abbr]
  return G + 1 - fourth.w - T.l
end

-- Hub helpers ------------------------------------------------------------------------------------------

--- The user's most recent finished game's box, and its key.
function PL.lastBox(L)
  local best, bk = nil, nil
  for k, b in pairs(L.boxes or {}) do
    if (b.h == L.user or b.a == L.user) and (not best or b.d > best.d) then best, bk = b, k end
  end
  return best, bk
end

--- The game's star for one side: { id, text } from the box lines (batting or the starter).
function PL.hero(L, b, abbr)
  local side = (b.h == abbr) and b.home or b.away
  local best, bv, txt = nil, -1e9, nil
  for _, ln in ipairs(side.bat or {}) do
    -- id, ab, r, h, rbi, bb, k, hr
    local v = ln[4] * 2 + ln[8] * 3 + ln[5] * 1.2 + ln[3] * 0.6 + ln[6] * 0.5 - ln[7] * 0.3
    if v > bv then
      best, bv = ln[1], v
      local parts = { ln[4] .. "-" .. ln[2] }
      if ln[8] > 0 then
        local p = L.players[ln[1]]
        parts[#parts + 1] = (ln[8] > 1 and (ln[8] .. " HR") or "HR") .. (p and (" (" .. (p.st.b.hr or 0) .. ")") or "")
      end
      if ln[5] > 0 then parts[#parts + 1] = ln[5] .. " RBI" end
      txt = table.concat(parts, ", ")
    end
  end
  local sp = side.pit and side.pit[1]
  if sp then
    -- id, outs, h, r, er, bb, k, np: a good start beats a quiet bat
    local v = sp[2] / 3 * 1.4 + sp[7] * 0.4 - sp[5] * 1.6 - sp[3] * 0.3 - 4
    if v > bv then
      best = sp[1]
      txt = string.format("%d.%d IP, %d ER, %d K", sp[2] // 3, sp[2] % 3, sp[5], sp[7])
    end
  end
  return best and { id = best, text = txt } or nil
end

--- One heads-up line for today (the hub): the most pressing thing about the lineup.
function PL.headsUp(L)
  local T = L.teams[L.user]
  local seen, missing = {}, nil
  for _, id in ipairs(T.order or {}) do seen[T.field[id] or "DH"] = (seen[T.field[id] or "DH"] or 0) + 1 end
  for _, pos in ipairs({ "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF", "DH" }) do
    if not seen[pos] then missing = pos break end
    if seen[pos] > 1 then return "Two at " .. pos .. " in the lineup", "lineup" end
  end
  if missing then return "Nobody at " .. missing .. " in the lineup", "lineup" end
  if T.platoonNote then return T.platoonNote, "lineup" end
  local dl = PL.deadline(L) - L.day
  if L.phase == "season" and dl >= 0 and dl <= 5 then return "TRADE DEADLINE " .. (dl == 0 and "TODAY" or ("IN " .. dl .. " DAY" .. (dl == 1 and "" or "S"))), "trades" end
  if T.cards and T.cardSide == "L" and PL.gameFor(L, L.user) then
    -- the lefty card goes in on its own; say so once a day
    local sp = PL.vsHand(L, L.user) == "L" and PL.gameFor(L, L.user)
    if sp then return "Lefty starter: your vs-LHP card is in", "lineup" end
  end
  for _, id in ipairs(T.order or {}) do
    local p = L.players[id]
    if p and (p.fat or 0) >= 70 then return PM.short(p) .. " is worn out (" .. math.floor(p.fat) .. ")", "lineup" end
  end
  for _, id in ipairs(T.ml) do
    local p = L.players[id]
    if p and p.pos ~= "P" and (p.sat or 0) >= 5 and (p.mood or 0) < 0 then return PM.short(p) .. " wants to play (" .. p.sat .. " days on the bench)", "lineup" end
  end
  for _, id in ipairs(T.order or {}) do
    local p = L.players[id]
    if p and T.field[id] == "C" and (p.fat or 0) >= 60 then return PM.short(p) .. " (C) is due a day off", "lineup" end
  end
  -- road wear (the rule: from the 6th straight road game, a little fatigue every day)
  local g = PL.gameFor(L, L.user)
  if g and g.a == L.user then
    local rs = PL.roadStreak(L, L.user, L.day)
    if rs >= 6 then return "Road wear: road game " .. rs .. " in a row, legs getting heavy", "map" end
  end
  return nil
end

--- Five consecutive standings places around the playoff line that include the user's club.
function PL.raceWindow(L)
  local st = PL.standings(L)
  local r = PL.rank(L, L.user)
  local s = math.max(1, math.min(4, r - 2))
  if r < s then s = r end
  if r > s + 4 then s = r - 4 end
  s = math.max(1, math.min(#st - 4, s))
  local out = {}
  for i = s, s + 4 do out[#out + 1] = { rank = i, T = st[i] } end
  return out
end

--- Tonight's game that matters most for the race: the club just above or below the user.
function PL.rivalTonight(L)
  local st = PL.standings(L)
  local r = PL.rank(L, L.user)
  for _, k in ipairs({ r - 1, r + 1, r - 2, r + 2 }) do
    local T = st[k]
    if T then
      local g = PL.gameFor(L, T.abbr)
      if g and g.h ~= L.user and g.a ~= L.user then return g end
    end
  end
  return nil
end
