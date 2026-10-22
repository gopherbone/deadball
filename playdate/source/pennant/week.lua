--[[ Pennant's week turn (docs/PENNANT_ENGINE.md "The week"): the club-wide layer over the
  per-player season engine. Pure Lua (no playdate APIs): the self-test runs it headless.

  L.club (saved with the league meta; PWeek.ensure defaults old saves):
    prog, int       this week's program ("bat"|"arms"|"def"|"gym"|"farm"|"rest") and intensity 1..3
    fac, fxp        facility level (1..5) and use points per program
    wk              the week in progress: { w, po, d0, d1, prog, int, u0, e0, m0, w0, l0, cond0, inj0, fac0 }
    lastRep         the last week's report (PWeek.endWeek)
    goal, goals     this month's goal, the season's goal history; reward = a cleared goal's pick
    ev, evN, evSeen this week's clubhouse event, events this season, keys used this season
    plan            the series game plan { opp, d0, d1, round, po, opts, key }
    feat            the featured game { w, d }
    mode["d<day>"]  how a game this week is played, picked on the Week screen's strip, This week's
                    games or the pregame: "sim" | "watch" | "bat" | "pitch" | "both" (PWeek.modeFor;
                    unset = the default: L.settings.allGames, else the featured game and every
                    playoff game at the last live mode (PWeek.lastLive), the rest sim)
    tonight         one game's mods from an event { d, bat, pit }
    gainWk          this week's gain factor from an event { w, x }
    noRest          REST WEEK is locked until this week index
    own["<pid>"]    individual training (the Office's Training screen): the program leaves him be

  Programs map onto the per-player training engine (PL.trainDay): PWeek.applyPlans sets every
  user player's plan each day (focus, intensity, xp factor plan.xm, injury risk plan.rk, extra
  fatigue plan.fx). Gains go through one modifier list (PWeek.modifiers: program coaching, the
  facility level, an event's factor, and future mentor / alumni bonuses via PWeek.mentorMods).

  Stops between days of a run (PWeek.addStop / PWeek.dueStops): the clubhouse event registers
  here; future interstitials (legacy inheritance events at fixed weeks) use the same registry.
]]

PWeek = PWeek or {}
local W = PWeek

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local clamp = PM.clamp
local function P(L, id) return L.players[id] end

W.PROGS = { "bat", "arms", "def", "gym", "farm" }
W.PROG = {
  bat = { name = "BATTING", fac = "CAGES", units = { "lineup", "bench" } },
  arms = { name = "ARMS", fac = "MOUNDS", units = { "rot", "pen" } },
  def = { name = "DEFENSE", fac = "INFIELD", units = { "def", "lineup" } },
  gym = { name = "GYM", fac = "WEIGHTS", units = { "lineup", "rot", "pen" } },
  farm = { name = "FARM", fac = "CAMP", units = { "farm" } },
  rest = { name = "REST", fac = "", units = {} },
}
W.INT = { "LIGHT", "NORMAL", "HARD" }
W.UNITS = { "lineup", "rot", "pen", "def", "bench", "farm" }
W.UNIT_NAME = { lineup = "LINEUP", rot = "ROTATION", pen = "BULLPEN", def = "DEFENSE", bench = "BENCH", farm = "FARM" }
W.UNIT_SHORT = { lineup = "LINE", rot = "ROT", pen = "PEN", def = "DEF", bench = "BEN", farm = "FARM" }

-- Tuning (docs/PENNANT_ENGINE.md "The week"; Umamusume-style, scratchpad research):
W.PROG_MULT = 3.6           -- the program's coaching on its unit (the engine's Normal day is the base): a season on one focus ~ +8-12
W.INT_GAIN = { 0.6, 1.0, 1.6 }                    -- LIGHT / NORMAL / HARD gains
-- energy a week by program and intensity (negative: the FARM week gives energy back)
W.COST = { bat = { 8, 18, 30 }, arms = { 8, 18, 30 }, def = { 6, 14, 23 }, gym = { 10, 22, 36 }, farm = { -8, -5, 4 } }
W.FAC_LV = { 0, 3, 6, 9, 12 }                     -- use points for levels 1..5 (HARD counts 2)
W.FAC_X = { 1.0, 1.1, 1.2, 1.35, 1.5 }            -- gains by facility level
W.MOOD_X = { 0.8, 0.9, 1.0, 1.1, 1.2 }            -- gains by mood (pips)
W.ENERGY0 = 80              -- a season starts here
W.REST = { 30, 45, 60 }     -- a REST WEEK gives one of these back (seeded by the week)
local BASE_XP <const> = { 0, 0.5, 0.95, 1.6 }

-- Setup / save migration -----------------------------------------------------------------------------

function W.ensure(L)
  local c = L.club
  if type(c) ~= "table" then c = {} L.club = c end
  if not W.PROG[c.prog or ""] then c.prog = "bat" end
  c.int = clamp(floor(tonumber(c.int) or 2), 1, 3)
  c.fac = type(c.fac) == "table" and c.fac or {}
  c.fxp = type(c.fxp) == "table" and c.fxp or {}
  for _, k in ipairs(W.PROGS) do
    c.fac[k] = clamp(floor(tonumber(c.fac[k]) or 1), 1, 5)
    c.fxp[k] = tonumber(c.fxp[k]) or W.FAC_LV[c.fac[k]]
  end
  c.goals = type(c.goals) == "table" and c.goals or {}
  c.mode = type(c.mode) == "table" and c.mode or {}
  -- (old saves: games marked "play live" in the Office, a featured game let sim)
  if type(c.play) == "table" then
    for k, v in pairs(c.play) do if v and not c.mode[k] then c.mode[k] = W.lastLive(L) end end
  end
  c.play = nil
  if c.featSkip then
    if c.feat and c.feat.d and not c.mode["d" .. c.feat.d] then c.mode["d" .. c.feat.d] = "sim" end
    c.featSkip = nil
  end
  c.own = type(c.own) == "table" and c.own or {}
  c.evSeen = type(c.evSeen) == "table" and c.evSeen or {}
  c.evN = tonumber(c.evN) or 0
  c.energy = clamp(tonumber(c.energy) or W.ENERGY0, 0, 100)
  if c.season ~= L.season then W.newSeason(L) end
  if not c.goal and L.phase == "season" then W.newGoal(L) end
  return c
end

--- A new season: the goals, events, plans start over; the facilities stay.
function W.newSeason(L)
  local c = L.club
  c.season = L.season
  c.goals, c.goal, c.reward, c.rewards = {}, nil, nil, nil
  c.ev, c.evN, c.evSeen = nil, 0, {}
  c.plan, c.feat, c.mode, c.tonight, c.gainWk, c.noRest = nil, nil, {}, nil, nil, nil
  c.wk, c.lastRep, c.monthNote, c.goalOffer = nil, nil, nil, nil
  c.energy = W.ENERGY0
  -- (facility levels reset each run, like a career's; the endless career may keep them)
  for _, k in ipairs(W.PROGS) do c.fac[k], c.fxp[k] = 1, 0 end
  if L.phase == "season" then W.newGoal(L) end
end

-- Weeks ------------------------------------------------------------------------------------------------

local wmemo = setmetatable({}, { __mode = "k" })
--- The regular season's weeks: { d0, d1 } runs of days ending on an off day (two series + the off day).
function W.weeks(L)
  local reg = L.regDays or #L.sched
  local m = wmemo[L]
  if m and m.sched == L.sched and m.reg == reg then return m.list end
  local list, d0 = {}, 1
  for d = 1, reg do
    local day = L.sched[d]
    if day.off or d == reg then list[#list + 1] = { d0 = d0, d1 = d } d0 = d + 1 end
  end
  wmemo[L] = { sched = L.sched, reg = reg, list = list }
  return list
end

function W.weekOf(L, d)
  d = d or L.day
  for i, w in ipairs(W.weeks(L)) do if d >= w.d0 and d <= w.d1 then return i, w end end
  return nil
end

--- The user's playoff series now (or nil): the series table and its index.
function W.userSeries(L)
  if L.phase ~= "playoffs" or not L.po then return nil end
  for si, s in ipairs(L.po.series) do
    if s.hi == L.user or s.lo == L.user then return s, si end
  end
  return nil
end

--- What "this week" is: { w, n, d0, d1 } in the season; { po = true, round, series } in the playoffs.
function W.span(L)
  if L.phase == "season" then
    local i, w = W.weekOf(L, L.day)
    if i then return { w = i, n = #W.weeks(L), d0 = w.d0, d1 = w.d1 } end
  elseif L.phase == "playoffs" then
    local s = W.userSeries(L)
    return { po = true, round = L.po.round, series = s, w = 100 + L.po.round, n = #W.weeks(L) }
  end
  return { over = true, w = 0, n = #W.weeks(L) }
end

-- Unit grades ---------------------------------------------------------------------------------------------

local DEF_W <const> = { C = 0.30, SS = 0.28, CF = 0.26, ["2B"] = 0.24, ["3B"] = 0.22, RF = 0.18, LF = 0.14, ["1B"] = 0.10, DH = 0 }

--- PM.ovr unrounded, on given ratings.
function W.ovrf(p, r)
  r = r or p.r
  if p.pos == "P" then
    local o = r.velo * 0.24 + r.ctl * 0.26 + r.stf * 0.32 + r.sta * (p.role == "SP" and 0.18 or 0.08)
    return o / (p.role == "SP" and 1.0 or 0.90)
  end
  local dw = DEF_W[p.pos] or 0.2
  local bat = r.con * 0.32 + r.pow * 0.30 + r.eye * 0.18 + r.spd * 0.20
  local def = r.fld * 0.7 + r.arm * 0.3
  return bat * (1 - dw) + def * dw
end

--- The six unit grades of a club (means on the 20-80 scale). prog: count the training XP banked
--- toward the next point (so a week's work shows). over[id] = ratings to use instead (previews).
function W.units(L, abbr, prog, over)
  local T = L.teams[abbr or L.user]
  local function R(p)
    if over and over[p.id] then return over[p.id] end
    return prog and PL.progress(p) or p.r
  end
  local function mean(list, fn)
    local s, n = 0, 0
    for _, id in ipairs(list) do
      local p = P(L, id)
      if p then local v = fn(p) if v then s, n = s + v, n + 1 end end
    end
    return n > 0 and s / n or 0
  end
  local u = {}
  u.lineup = mean(T.order or {}, function(p) return W.ovrf(p, R(p)) end)
  u.rot = mean(T.rot or {}, function(p) return W.ovrf(p, R(p)) end)
  local inRot, pen = {}, {}
  for _, id in ipairs(T.rot or {}) do inRot[id] = true end
  for _, id in ipairs(T.ml) do local p = P(L, id) if p and p.pos == "P" and not inRot[id] then pen[#pen + 1] = id end end
  u.pen = mean(pen, function(p) return W.ovrf(p, R(p)) end)
  u.def = mean(T.order or {}, function(p)
    local pos = T.field and T.field[p.id]
    if pos == "DH" then return nil end
    local r = R(p)
    return r.fld * 0.7 + r.arm * 0.3
  end)
  local bench = {}
  local inOrder = {}
  for _, id in ipairs(T.order or {}) do inOrder[id] = true end
  for _, id in ipairs(T.ml) do local p = P(L, id) if p and p.pos ~= "P" and not inOrder[id] then bench[#bench + 1] = id end end
  u.bench = mean(bench, function(p) return W.ovrf(p, R(p)) end)
  -- the farm: its eight best prospects
  local farm = {}
  for _, id in ipairs(T.farm) do farm[#farm + 1] = id end
  table.sort(farm, function(a, b) return W.ovrf(P(L, a)) > W.ovrf(P(L, b)) end)
  while #farm > 8 do table.remove(farm) end
  u.farm = mean(farm, function(p) return W.ovrf(p, R(p)) end)
  return u
end

function W.grade(v) return PM.grade(floor(v + 0.5)) end

-- Energy and mood -------------------------------------------------------------------------------------------

local function active(L)
  local out = {}
  for _, id in ipairs(L.teams[L.user].ml) do local p = P(L, id) if p and not p.inj then out[#out + 1] = p end end
  return out
end

--- The club's ENERGY (0..100): a weekly reserve the programs spend and rest weeks, the FARM and
--- events give back. Below 50 a program can fail; below 30 the club plays a little flat. (Each
--- player's day-to-day fatigue stays the engine's own.)
function W.energy(L) return floor((L.club and L.club.energy or W.ENERGY0) + 0.5) end

--- Mean fatigue of the active big club (shown in the report).
function W.fatigue(L)
  local s, n = 0, 0
  for _, p in ipairs(active(L)) do s, n = s + (p.fat or 0), n + 1 end
  return n > 0 and s / n or 0
end

function W.moodAvg(L)
  local s, n = 0, 0
  for _, p in ipairs(active(L)) do s, n = s + (p.mood or 0), n + 1 end
  return n > 0 and s / n or 0
end

W.MOOD_NAME = { "UPSET", "DOWN", "FINE", "GOOD", "FIRED UP" }
--- Mood as 1..5 pips and a word.
function W.mood(L)
  local m = W.moodAvg(L)
  local pips = clamp(floor(3 + m * 2.5 + 0.5), 1, 5)
  return pips, W.MOOD_NAME[pips], m
end

--- Change the club's energy by n points.
function W.addEnergy(L, n)
  local c = L.club
  c.energy = clamp((c.energy or W.ENERGY0) + n, 0, 100)
end

--- Mood for everyone (each moves with probability chance, default 0.7).
function W.addMood(L, n, rng, chance)
  for _, id in ipairs(L.teams[L.user].ml) do
    local p = P(L, id)
    if p and (not rng or rng:chance(chance or 0.7)) then p.mood = clamp((p.mood or 0) + n, -2, 2) end
  end
end

--- Condition arrows for k random big-leaguers.
function W.addCond(L, n, rng, k)
  local list = active(L)
  for _ = 1, min(k or 4, #list) do
    local i = rng:int(#list)
    local p = table.remove(list, i)
    p.cond = clamp((p.cond or 3) + n, 1, 5)
  end
end

--- Bulk rating boosts for a whole unit (events, rewards, legacy pointers): +n to `key` for
--- every player of `unit` ("lineup","bench","rot","pen","def","farm","hitters","pitchers","all"),
--- at most to `ceil` (default 80); a cap below the new rating rises with it. Returns the count.
function W.boostUnit(L, unit, key, n, ceil)
  local T = L.teams[L.user]
  ceil = ceil or 80
  local ids = {}
  local function add(list) for _, id in ipairs(list or {}) do ids[#ids + 1] = id end end
  if unit == "lineup" or unit == "def" then add(T.order)
  elseif unit == "rot" then add(T.rot)
  elseif unit == "farm" then add(T.farm)
  else
    for _, id in ipairs(T.ml) do
      local p = P(L, id)
      local inRot = false
      for _, r in ipairs(T.rot or {}) do if r == id then inRot = true end end
      if p and ((unit == "all") or (unit == "hitters" and p.pos ~= "P") or (unit == "pitchers" and p.pos == "P")
        or (unit == "pen" and p.pos == "P" and not inRot) or (unit == "bench" and p.pos ~= "P")) then ids[#ids + 1] = id end
    end
  end
  local k = 0
  for _, id in ipairs(ids) do
    local p = P(L, id)
    if p and p.r[key] then
      local v = min(ceil, p.r[key] + n)
      if v > p.r[key] then
        p.r[key] = v
        if (p.cap[key] or 0) < v then p.cap[key] = v end
        k = k + 1
      end
    end
  end
  return k
end

-- Programs -> the training engine -------------------------------------------------------------------------

local function room(p, k) local key = k == "pit" and "stf" or k return (p.cap[key] or 80) - (p.r[key] or 50) end
local function rating(p, k) return p.r[k == "pit" and "stf" or k] or 50 end

--- The weakest of keys that still has room to grow (else the one with the most room).
local function weakest(p, keys)
  local best, bv = nil, 1e9
  for _, k in ipairs(keys) do
    if room(p, k) >= 1 and rating(p, k) < bv then best, bv = k, rating(p, k) end
  end
  if best then return best end
  local br = -1e9
  for _, k in ipairs(keys) do if room(p, k) > br then best, br = k, room(p, k) end end
  return best
end

--- His own best plan (the coaches' default: the most room to grow).
local function maintenance(p)
  local best, bv = nil, -1e9
  for _, k in ipairs(p.pos == "P" and PL.FOCI_PIT or PL.FOCI_BAT) do
    local r = room(p, k)
    if r > bv then best, bv = k, r end
  end
  return best
end
W.maintenance = maintenance

--- The program's focus for p, or nil when p isn't in its unit.
function W.focusFor(p, prog)
  local farm = p.lvl == "F"
  if prog == "farm" then
    if not farm then return nil end
    return p.pos == "P" and weakest(p, { "velo", "ctl", "pit" }) or weakest(p, { "con", "pow", "eye", "fld" })
  end
  if farm then return nil end
  if prog == "bat" then return p.pos ~= "P" and weakest(p, { "con", "pow", "eye" }) or nil end
  if prog == "arms" then
    if p.pos ~= "P" then return nil end
    return weakest(p, p.role == "SP" and { "velo", "ctl", "pit", "sta" } or { "velo", "ctl", "pit" })
  end
  if prog == "def" then return p.pos ~= "P" and weakest(p, { "fld", "arm" }) or nil end
  if prog == "gym" then
    if p.pos == "P" then return room(p, "sta") >= 1 and "sta" or "velo" end
    return room(p, "pow") >= 1 and "pow" or "spd"
  end
  return nil
end


--- Future legacy hook: mentor / alumni bonuses for a program, as modifier entries
--- { k = "mentor", x = 1.2, label = "..." }. None yet.
function W.mentorMods(L, prog) return nil end

--- The All-Star break: the middle week (two in a long season) is camp, every facility at LV5.
function W.isCamp(L, w)
  local n = #W.weeks(L)
  w = w or W.span(L).w
  if not w or w > n then return false end
  local mid = n // 2 + 1
  return w == mid or (n >= 20 and w == mid + 1)
end

--- The program and intensity training now: the week in progress keeps what it started with.
function W.current(L)
  local c = L.club
  local sp = W.span(L)
  if c.wk and c.wk.w == sp.w and c.wk.season == L.season then return c.wk.prog, c.wk.int, c.wk end
  return c.prog, c.int, nil
end

--- The gain modifiers on a program's unit, one list (the product is the xp factor over the
--- engine's Normal day): coaching, intensity, the facility (camp: LV5), mood, this week's event,
--- future mentors. Each { k, x, label }.
function W.modifiers(L, prog, int)
  local c = L.club
  local list = {}
  if prog == "rest" then return list end
  int = int or c.int
  list[#list + 1] = { k = "program", x = W.PROG_MULT, label = "COACHING" }
  list[#list + 1] = { k = "intensity", x = W.INT_GAIN[int], label = W.INT[int] }
  local sp = W.span(L)
  local lv = c.fac[prog] or 1
  if W.isCamp(L, sp.w) then list[#list + 1] = { k = "facility", x = W.FAC_X[5], label = "ALL-STAR CAMP" }
  else list[#list + 1] = { k = "facility", x = W.FAC_X[lv], label = W.PROG[prog].fac .. " LV" .. lv } end
  local pips = W.mood(L)
  list[#list + 1] = { k = "mood", x = W.MOOD_X[pips], label = "MOOD" }
  if c.gainWk and c.gainWk.w == sp.w then list[#list + 1] = { k = "event", x = c.gainWk.x, label = "THIS WEEK" } end
  for _, m in ipairs(W.mentorMods(L, prog) or {}) do list[#list + 1] = m end
  return list
end

function W.gainMult(list)
  local x = 1
  for _, m in ipairs(list or {}) do x = x * (m.x or 1) end
  return x
end

--- Energy a program costs this week (negative: it gives energy back).
function W.cost(L, prog, int)
  if prog == "rest" then return 0 end
  local base = W.COST[prog][int]
  if base > 0 then base = base + ((L.club.fac[prog] or 1) - 1) end
  return base
end

--- The chance (0..95 %) that this week's program fails: none at 50+ energy, then
--- 70 x ((50 - E) / 50)^2, LIGHT x0.5, HARD x1.3 + 8. The FARM and rest never fail.
function W.failChance(L, prog, int)
  if prog == "rest" or prog == "farm" then return 0 end
  local E = W.energy(L)
  local f = E >= 50 and 0 or 70 * ((50 - E) / 50) ^ 2
  if int == 1 then f = f * 0.5 elseif int == 3 then f = f * 1.3 + 8 end
  return clamp(floor(f + 0.5), 0, 95)
end

--- Set every user player's plan from the program (daily, before training). Targets train on the
--- program's focus (the engine's Normal day x the modifier list), the rest of the club keeps up on
--- Light; a failed week leaves the targets nothing. Individual plans (c.own) are left alone.
function W.applyPlans(L)
  local c = W.ensure(L)
  local T = L.teams[L.user]
  local prog, int, wk = W.current(L)
  local mult = (wk and wk.fail) and 0 or W.gainMult(W.modifiers(L, prog, int))
  local sp = W.span(L)
  local evx = (c.gainWk and c.gainWk.w == sp.w) and c.gainWk.x or 1
  for _, list in ipairs({ T.ml, T.farm }) do
    for _, id in ipairs(list) do
      local p = P(L, id)
      if p and not c.own[tostring(id)] then
        p.plan = p.plan or {}
        local pl = p.plan
        if prog == "rest" then
          pl.f, pl.i, pl.xm, pl.rk, pl.fx = pl.f or maintenance(p), 0, 1, 0, 0
        else
          local f = W.focusFor(p, prog)
          if f then pl.f, pl.i, pl.xm, pl.rk, pl.fx = f, 2, mult, 0, 0
          else pl.f, pl.i, pl.xm, pl.rk, pl.fx = maintenance(p), 1, evx, 0, 0 end
        end
      elseif p then
        p.plan = p.plan or { i = 2 }
        p.plan.xm, p.plan.rk, p.plan.fx = nil, nil, nil
      end
    end
  end
end

--- Expected rating points a week for p on focus f (the engine's Normal day x xm; PL.weekly's model).
local function weekPts(p, f, xm)
  local key = f == "pit" and "stf" or f
  local rm = (p.cap[key] or 80) - (p.r[key] or 50)
  local rf = rm <= 0 and 0.05 or min(1, 0.35 + rm / 12)
  local cf = ({ 0.7, 0.85, 1, 1.1, 1.25 })[p.cond or 3]
  return BASE_XP[3] * PL.ageFactor(p.age) * rf * cf * 7 / PL.XP_PER_POINT * (p.lvl == "F" and 1.15 or 1) * (xm or 1)
end
W.weekPts = weekPts

--- What a program would do this week, before committing: { fx = { {unit, delta} }, energy,
--- fail = %, mult, per = mean points per player }. Unit deltas count the program's own work.
function W.preview(L, prog, int)
  local c = L.club
  local T = L.teams[L.user]
  local out = { fx = {}, energy = 0, fail = 0 }
  if prog == "rest" then
    out.energy = min(W.REST[2], 100 - W.energy(L))
    out.rest = true
    return out
  end
  local mult = W.gainMult(W.modifiers(L, prog, int))
  out.mult = mult
  local over = {}
  local pts, n = 0, 0
  for _, list in ipairs({ T.ml, T.farm }) do
    for _, id in ipairs(list) do
      local p = P(L, id)
      local f = p and not p.inj and not c.own[tostring(id)] and W.focusFor(p, prog)
      if f then
        local r = PL.progress(p)
        local key = f == "pit" and "stf" or f
        local g = weekPts(p, f, mult)
        r[key] = r[key] + g
        over[id] = r
        pts, n = pts + g, n + 1
      end
    end
  end
  out.per = n > 0 and pts / n or 0
  local u0 = W.units(L, L.user, true)
  local u1 = W.units(L, L.user, true, over)
  for _, k in ipairs(W.UNITS) do
    local d = u1[k] - u0[k]
    if d >= 0.05 then out.fx[#out.fx + 1] = { k, d } end
  end
  out.energy = -W.cost(L, prog, int)
  out.fail = W.failChance(L, prog, int)
  return out
end


--- The facility level from use points.
function W.facLevel(xp)
  local lv = 1
  for i, need in ipairs(W.FAC_LV) do if xp >= need then lv = i end end
  return lv
end

--- Progress toward the next level (0..1), and the points still needed.
function W.facProgress(L, prog)
  local c = L.club
  local lv = c.fac[prog] or 1
  if lv >= 5 then return 1, 0 end
  local a, b = W.FAC_LV[lv], W.FAC_LV[lv + 1]
  local xp = c.fxp[prog] or a
  return clamp((xp - a) / (b - a), 0, 1), b - xp
end

--- Use points into a facility (a level-up returns the new level).
function W.addFacXp(L, prog, n)
  local c = L.club
  if not c.fac[prog] then return nil end
  c.fxp[prog] = max(W.FAC_LV[c.fac[prog]], (c.fxp[prog] or 0) + n)
  local lv = W.facLevel(c.fxp[prog])
  if lv > c.fac[prog] then c.fac[prog] = lv return lv end
  return nil
end

--- REST WEEK is allowed (an event can lock it for a few weeks).
function W.canRest(L)
  local c = L.club
  return not (c.noRest and W.span(L).w < c.noRest)
end

-- The run's game mods (series plans, events) -> PEng.player / PL.view ------------------------------------

local modMemo = {}
--- Today's rating offsets for the user's big club: { con, pow, eye, spd, sp, rp } or nil.
function W.dayMods(L)
  local c = L.club
  if not c then return nil end
  local plan = c.plan
  local E = W.energy(L)
  local key = L.season .. ":" .. L.day .. ":" .. tostring(plan and plan.key) .. ":" .. tostring(c.tonight and c.tonight.d) .. ":" .. (E < 30 and E // 10 or 9)
  if modMemo.key == key then return modMemo.m end
  local m = nil
  local function add(t)
    if not t then return end
    m = m or { con = 0, pow = 0, eye = 0, spd = 0, sp = 0, rp = 0 }
    local b = t.bat or 0
    m.con, m.pow, m.eye = m.con + b + (t.con or 0), m.pow + b + (t.pow or 0), m.eye + b + (t.eye or 0)
    m.spd = m.spd + (t.spd or 0)
    local pi = t.pit or 0
    m.sp, m.rp = m.sp + pi + (t.sp or 0), m.rp + pi + (t.rp or 0)
  end
  if plan and plan.key and W.PLANS[plan.key] then
    local g = PL.gameFor(L, L.user)
    local opp = g and (g.h == L.user and g.a or g.h)
    if opp == plan.opp and ((plan.po and L.phase == "playoffs") or (not plan.po and L.day >= plan.d0 and L.day <= plan.d1)) then
      add(W.PLANS[plan.key].mod)
    end
  end
  if c.tonight and c.tonight.d == L.day then add(c.tonight) end
  -- a club out of gas plays a little flat
  if E < 30 then local pen = -math.ceil((30 - E) / 10) add({ bat = pen, pit = pen }) end
  modMemo.key, modMemo.m = key, m
  return m
end

--- Rating offsets for one player in today's game (nil: none).
function W.modFor(p)
  local L = Pennant and Pennant.L
  if not L or p.team ~= L.user or p.lvl ~= "ML" then return nil end
  return W.dayMods(L)
end
PEng.modFor = W.modFor

-- Series game plans ----------------------------------------------------------------------------------------

W.PLANS = {
  righties = { t = "STACK THE RIGHTIES", l = { "Right bats vs the lefty", "Lineup +2 all series", "Benched lefties sulk" },
    cost = "COST: MOOD -1, BENCH", mod = { bat = 2 }, edge = 0.03, moodBench = -1 },
  lefties = { t = "STACK THE LEFTIES", l = { "Left bats vs the righty", "Lineup +2 all series", "Benched righties sulk" },
    cost = "COST: MOOD -1, BENCH", mod = { bat = 2 }, edge = 0.03, moodBench = -1 },
  run = { t = "RUN ON THEM", l = { "Green light to steal", "Speed +8 all series", "More caught stealing" },
    cost = "COST: ENERGY -10", mod = { spd = 8 }, edge = 0.03, energy = -10 },
  pen = { t = "GO AFTER THE PEN", l = { "Take pitches early", "Eye +4, power -1", "Get to their tired pen" },
    cost = "COST: NONE", mod = { eye = 4, pow = -1 }, edge = 0.02, tired = 0.03 },
  ace = { t = "ACE ON FULL REST", l = { "Starters go deep", "Rotation +3 all series", "The workload adds up" },
    cost = "COST: ENERGY -8", mod = { sp = 3 }, edge = 0.03, energy = -8 },
  swing = { t = "SWING EARLY", l = { "Hack at strike one", "Power +4, eye -3", "More strikeouts" },
    cost = "COST: NONE", mod = { pow = 4, eye = -3 }, edge = 0.02 },
  leash = { t = "SHORT LEASH", l = { "Quick hooks", "Bullpen +3 all series", "The pen works overtime" },
    cost = "COST: ENERGY -6", mod = { rp = 3 }, edge = 0.02, energy = -6 },
}

--- The opponent's likely starters in the series (rotation order from today): ids.
function W.oppStarters(L, opp, n)
  local OT = L.teams[opp]
  local out = {}
  local k = #(OT.rot or {})
  for i = 0, (n or 3) - 1 do
    local id = OT.rot and OT.rot[((OT.rotIdx or 1) - 1 + i) % max(1, k) + 1]
    if id then out[#out + 1] = id end
  end
  return out
end

--- Their bullpen's last three days of pitches.
function W.penLoad(L, abbr)
  local T = L.teams[abbr]
  local n = 0
  for id in pairs(T.pen or {}) do
    local p = P(L, id)
    if p and p.rp then n = n + (p.rp[1] or 0) + (p.rp[2] or 0) + (p.rp[3] or 0) end
  end
  return n
end

--- Strength for the odds estimate.
local function strength(L, abbr)
  local u = W.units(L, abbr)
  return u.lineup * 0.45 + u.rot * 0.35 + u.pen * 0.1 + u.def * 0.1
end

--- The series that make this week's key series: 1st place, a club within a place (or 3 games),
--- every playoff series. Returns the plan stub or nil.
function W.keySeries(L)
  local sp = W.span(L)
  if sp.po then
    local s = sp.series
    if not s or s.winner then return nil end
    local opp = s.hi == L.user and s.lo or s.hi
    return { opp = opp, po = true, round = sp.round, why = s.final and "THE PENNANT SERIES" or "THE SEMIFINAL" }
  end
  if not sp.d0 then return nil end
  local st = PL.standings(L)
  local rank = {}
  for i, T in ipairs(st) do rank[T.abbr] = i end
  local me = L.teams[L.user]
  local best, bs = nil, 1
  local seen = {}
  for d = max(L.day, sp.d0), sp.d1 do
    local g = PL.gameFor(L, L.user, d)
    if g and not g.done then
      local opp = g.h == L.user and g.a or g.h
      local r = L.sched[d].round
      if not seen[r] then
        seen[r] = true
        local s, why = 0, nil
        local Ot = L.teams[opp]
        local gb = abs(((me.w - Ot.w) + (Ot.l - me.l)) / 2)
        if rank[opp] == 1 and rank[L.user] ~= 1 then s, why = s + 3, "THEY'RE 1ST" end
        if abs(rank[opp] - rank[L.user]) <= 1 then s = s + 2 why = why or (rank[opp] < rank[L.user] and "THE CLUB AHEAD OF YOU" or "THE CLUB ON YOUR HEELS") end
        if gb <= 3 and me.w + me.l >= 6 then s = s + 1 why = why or "A GAME APART" end
        if s > bs then
          local d1 = d
          while d1 + 1 <= sp.d1 and L.sched[d1 + 1].round == r do d1 = d1 + 1 end
          best, bs = { opp = opp, round = r, d0 = d, d1 = d1, why = why }, s
        end
      end
    end
  end
  return best
end

--- Three plans for a key series, from the scouting.
function W.planOptions(L, opp)
  local opts = {}
  local starters = W.oppStarters(L, opp, 3)
  local lefties = 0
  for _, id in ipairs(starters) do local p = P(L, id) if p and p.throws == "L" then lefties = lefties + 1 end end
  opts[1] = lefties >= 2 and "righties" or (lefties == 0 and "lefties" or "swing")
  opts[2] = "run"
  opts[3] = W.penLoad(L, opp) >= 120 and "pen" or "ace"
  return opts
end

--- Our chances in the series with a plan (an estimate for the card).
function W.odds(L, opp, key)
  local d = strength(L, L.user) - strength(L, opp)
  local pl = key and W.PLANS[key]
  local edge = pl and pl.edge or 0
  if key == "pen" and W.penLoad(L, opp) >= 120 then edge = edge + (pl.tired or 0) end
  return clamp(0.5 + d * 0.012 + edge, 0.2, 0.8)
end

--- Lock in a plan (pays its cost now).
function W.choosePlan(L, stub, key)
  local c = L.club
  local pl = W.PLANS[key]
  stub.key = key
  c.plan = stub
  if pl.energy then W.addEnergy(L, pl.energy) end
  if pl.moodBench then
    local T = L.teams[L.user]
    for _, id in ipairs(PRoster.bench(L, T)) do local p = P(L, id) if p then p.mood = clamp((p.mood or 0) + pl.moodBench, -2, 2) end end
  end
  if PEng.invalidate then PEng.invalidate() end
end

-- The featured game -----------------------------------------------------------------------------------------

--- The week's most important game (the one to play live): the key series' opener, else the
--- closest club in the standings, home first. Returns the day or nil.
function W.pickFeatured(L)
  local sp = W.span(L)
  if sp.po then
    local _, d = PL.nextGame(L, L.user)
    return d
  end
  if not sp.d0 then return nil end
  local st = PL.standings(L)
  local rank = {}
  for i, T in ipairs(st) do rank[T.abbr] = i end
  local plan = L.club.plan
  local best, bs = nil, -1e9
  for d = max(L.day, sp.d0), sp.d1 do
    local g = PL.gameFor(L, L.user, d)
    if g and not g.done then
      local opp = g.h == L.user and g.a or g.h
      local s = -abs(rank[opp] - rank[L.user]) - d * 0.01
      if plan and plan.opp == opp and not plan.po and d >= (plan.d0 or 0) and d <= (plan.d1 or 0) then s = s + 4 end
      if rank[opp] == 1 then s = s + 1 end
      if g.h == L.user then s = s + 0.5 end
      if s > bs then best, bs = d, s end
    end
  end
  return best
end

function W.featuredDay(L)
  local c = L.club
  local sp = W.span(L)
  if c.feat and c.feat.w == sp.w then return c.feat.d end
  return W.pickFeatured(L)
end

-- How each game is played -------------------------------------------------------------------------------

W.MODES = { "sim", "watch", "bat", "pitch", "both" }
W.MODE_NAME = { sim = "SIM", watch = "WATCH", bat = "BAT", pitch = "PITCH", both = "BAT+PITCH" }
W.MODE_DESC = { sim = "the coaches play it; the run goes on", watch = "watch in BallCast, make the dugout's calls",
  bat = "you bat, the coaches pitch", pitch = "you pitch, the coaches bat", both = "you bat and pitch" }

--- The next mode in the cycle SIM > WATCH > BAT > PITCH > BAT+PITCH (dir = 1 | -1).
function W.cycleMode(m, dir)
  local n = #W.MODES
  for i, k in ipairs(W.MODES) do
    if k == m then return W.MODES[(i - 1 + (dir or 1)) % n + 1] end
  end
  return "watch"
end

--- The last live mode (the hub's / a live game's direct controls: L.settings.directBat / directPitch).
function W.lastLive(L)
  local s = L.settings or {}
  local db, dp = s.directBat, s.directPitch
  if db == nil then db = s.playMode == "play" dp = db end
  return (db and dp and "both") or (db and "bat") or (dp and "pitch") or "watch"
end

--- The Office's "Play every game" default ("sim": only the featured game (and the playoffs) live).
function W.allMode(L)
  local m = L.settings and L.settings.allGames
  return (m and W.MODE_NAME[m]) and m or "sim"
end

--- How the user's game on day d is played: mode, why ("picked" | "featured" | "playoff" | "all" | nil).
--- feat: the featured day if the caller has it (saves the lookup).
function W.modeFor(L, d, feat)
  local c = L.club
  local m = c.mode and c.mode["d" .. d]
  if m and W.MODE_NAME[m] then return m, "picked" end
  local all = W.allMode(L)
  if L.phase == "playoffs" then return all ~= "sim" and all or W.lastLive(L), "playoff" end
  if feat == nil then feat = W.featuredDay(L) end
  if d == feat then return all ~= "sim" and all or W.lastLive(L), "featured" end
  if all ~= "sim" then return all, "all" end
  return "sim", nil
end

function W.setMode(L, d, m) L.club.mode["d" .. d] = m end

--- Does the run stop for a live game today? Returns live, why, mode.
function W.liveToday(L)
  local g = PL.gameFor(L, L.user)
  if not g or g.done then return false end
  local m, why = W.modeFor(L, L.day)
  if m == "sim" then return false end
  return true, why or "picked", m
end

-- Week start / end ---------------------------------------------------------------------------------------------

local function snapCond(L)
  local t = {}
  for _, id in ipairs(L.teams[L.user].ml) do local p = P(L, id) if p then t[tostring(id)] = p.cond end end
  return t
end
local function injSet(L)
  local t = {}
  for _, id in ipairs(L.teams[L.user].ml) do local p = P(L, id) if p and p.inj then t[tostring(id)] = true end end
  return t
end

--- The week starts (A on the Week screen): the snapshot for its report, the featured game, the
--- clubhouse event. A week already under way just carries on.
function W.beginWeek(L)
  local c = W.ensure(L)
  local sp = W.span(L)
  if c.wk and c.wk.w == sp.w and c.wk.season == L.season then return c.wk, false end
  local T = L.teams[L.user]
  local fail = W.failChance(L, c.prog, c.int)
  c.wk = { w = sp.w, po = sp.po or nil, season = L.season, d0 = L.day, d1 = sp.d1, prog = c.prog, int = c.int,
    u0 = W.units(L, L.user, true), e0 = W.energy(L), m0 = W.moodAvg(L), w0 = T.w, l0 = T.l,
    cond0 = snapCond(L), inj0 = injSet(L), fac0 = c.fac[c.prog], failPct = fail }
  -- the week's dice: seeded by the run, the week and the choice (reloading doesn't reroll them)
  local pi = 6
  for i, k in ipairs(W.PROGS) do if k == c.prog then pi = i end end
  local rng = PRng.new(((L.seed or 1) * 7919 + L.season * 1013 + sp.w * 131 + pi * 17 + c.int * 3) & 0x7FFFFFFF)
  if c.prog == "rest" then
    local gain = W.REST[rng:int(3)]
    c.wk.restGain = gain
    W.addEnergy(L, gain)
    if W.isCamp(L, sp.w) then W.addMood(L, 1) end
  else
    W.addEnergy(L, -W.cost(L, c.prog, c.int))
    if fail > 0 and rng:float() * 100 < fail then
      -- a failed week: no gains for the unit, the club sulks, and at 20%+ someone strains something
      c.wk.fail = true
      W.addMood(L, -1)
      local hurt
      if fail >= 20 and rng:chance(0.5) then
        local list = {}
        for _, id in ipairs(T.ml) do local p = P(L, id) if p and not p.inj and W.focusFor(p, c.prog) then list[#list + 1] = p end end
        if #list > 0 then
          hurt = list[rng:int(#list)]
          hurt.inj = { k = "training strain", d = 7 * rng:int(3) }
          L.trainerQ = L.trainerQ or {}
          L.trainerQ[#L.trainerQ + 1] = { id = hurt.id, day = L.day }
        end
      end
      PL.news(L, "TRAINING FLOP: the " .. PennantClubs.byAbbr[L.user].name .. " ran out of gas in " .. W.PROG[c.prog].name:lower() ..
        " drills" .. (hurt and ("; " .. PM.name(hurt) .. " strained something, out " .. hurt.inj.d .. " days") or "") .. ".", true)
    end
  end
  c.feat = { w = sp.w, d = W.pickFeatured(L) }
  W.pickEvent(L)
  return c.wk, true
end

--- Is the run of this week over? (the season: past its last day; the playoffs: the series is
--- decided or the phase moved on)
function W.weekDone(L)
  local c = L.club
  local wk = c and c.wk
  if not wk then return true end
  if wk.po then
    if L.phase ~= "playoffs" then return true end
    -- (the round, not the series: a series won early waits for the other one to finish)
    return L.po.round + 100 ~= wk.w
  end
  return L.phase ~= "season" or L.day > (wk.d1 or 0)
end

--- The week's report, and its facility use credited. Returns the report (also c.lastRep).
function W.endWeek(L)
  local c = L.club
  local wk = c.wk
  if not wk then return c.lastRep end
  local T = L.teams[L.user]
  local rep = { w = wk.w, po = wk.po, n = #W.weeks(L), prog = wk.prog, int = wk.int, d0 = wk.d0, d1 = L.day - 1,
    u0 = wk.u0, u1 = W.units(L, L.user, true), e0 = wk.e0, e1 = W.energy(L), m1 = W.moodAvg(L),
    ww = T.w - wk.w0, wl = T.l - wk.l0, tw = T.w, tl = T.l, days = {}, notes = {} }
  local feat = c.feat and c.feat.w == wk.w and c.feat.d
  for d = wk.d0, rep.d1 do
    local day = L.sched[d]
    if day and day.off then rep.days[#rep.days + 1] = { d = d, off = true }
    else
      local g = PL.gameFor(L, L.user, d)
      if g then
        local home = g.h == L.user
        local opp = home and g.a or g.h
        local me, them = home and g.hs or g.as, home and g.as or g.hs
        rep.days[#rep.days + 1] = { d = d, opp = (home and "" or "@") .. opp, won = g.done and me > them or nil, me = me, them = them, done = g.done, feat = d == feat }
      end
    end
  end
  rep.fail, rep.failPct, rep.restGain = wk.fail, wk.failPct, wk.restGain
  -- facility use (HARD counts twice; a failed week still wore the floor in)
  if wk.prog ~= "rest" then
    local lv = W.addFacXp(L, wk.prog, wk.int == 3 and 2 or 1)
    if lv then rep.facUp = { prog = wk.prog, lv = lv } end
  end
  -- also this week
  local up, down, hot = 0, 0, 0
  for _, id in ipairs(T.ml) do
    local p = P(L, id)
    local c0 = p and wk.cond0[tostring(id)]
    if c0 then
      if p.cond > c0 then up = up + 1 elseif p.cond < c0 then down = down + 1 end
    end
    if p and not p.inj and p.cond == 5 then hot = hot + 1 end
  end
  local N = rep.notes
  if wk.fail then N[#N + 1] = { "TRAINING FLOPPED: NO GAINS", true } end
  if wk.restGain then N[#N + 1] = { "REST: +" .. wk.restGain .. " ENERGY" } end
  if up > 0 then N[#N + 1] = { up .. (up == 1 and " PLAYER" or " PLAYERS") .. " UP AN ARROW" } end
  if down > 0 then N[#N + 1] = { down .. " DOWN AN ARROW" } end
  if hot > 0 then N[#N + 1] = { hot .. " RUNNING HOT" } end
  local hurt, worst = 0, 0
  for _, id in ipairs(T.ml) do
    local p = P(L, id)
    if p and p.inj and not wk.inj0[tostring(id)] then hurt = hurt + 1 worst = max(worst, p.inj.d) end
  end
  if hurt > 0 then
    N[#N + 1] = { hurt .. (hurt == 1 and " HURT: OUT " or " HURT, UP TO ") .. worst .. " DAYS", true }
    if L.settings.autoRoster ~= false then N[#N + 1] = { "  (THE BENCH COVERED IT)" } end
  end
  -- tired regulars given a day off (pennant/rest.lua: the swap list or the auto-rest)
  if (wk.rested or 0) > 0 then N[#N + 1] = { "RESTED " .. wk.rested .. " TIRED" .. (L.settings.autoRest and " (AUTO)" or "") } end
  local ready = 0
  for _, id in ipairs(T.farm) do if PRoster.ready(L, T, P(L, id)) then ready = ready + 1 end end
  if ready > 0 then N[#N + 1] = { "FARM: " .. ready .. " READY", true } end
  if rep.facUp then N[#N + 1] = { W.PROG[rep.facUp.prog].fac .. " UP TO LV" .. rep.facUp.lv .. "!", true } end
  N[#N + 1] = { "ENERGY " .. rep.e0 .. " \u{25b6} " .. rep.e1 }
  local g = c.goal
  if g then rep.goal = { text = W.goalShort(L, g), prog = W.goalProgress(L, g) } end
  c.lastRep = rep
  c.wk = nil
  c.plan = nil
  c.mode = {}
  return rep
end

-- Clubhouse events -----------------------------------------------------------------------------------------------

W.EVENTS = {
  { key = "bus", photo = "bus", when = "road", title = "THE BUS BROKE DOWN.",
    body = "Forty miles out. First pitch is in six hours. The club is looking at you.",
    opts = {
      { t = "HITCH RIDES WITH THE FANS", fx = "MOOD +1 \u{2022} ENERGY -10 \u{2022} 50%: FRONT PAGE, ARROWS UP",
        e = { mood = 1, energy = -10, chance = { p = 0.5, e = { cond = 1, news = "Fans drove the {club} to the ballpark. Front page." } } } },
      { t = "WAIT FOR THE MECHANIC", fx = "ENERGY +5 \u{2022} YOU START COLD: LINEUP -2 TONIGHT", e = { energy = 5, tonight = { bat = -2 } } },
      { t = "CALL IN A CHARTER FLIGHT", fx = "ENERGY +6 \u{2022} NO REST WEEK FOR 3 WEEKS", e = { energy = 6, noRest = 3 } } } },
  { key = "heat", photo = "heat", months = { 7, 8 }, title = "HEAT WAVE.",
    body = "It's 101 in the dugout. The water cooler is warm. The bat boy fainted. He's fine.",
    opts = {
      { t = "SHORT WORKOUTS", fx = "ENERGY +10 \u{2022} TRAINING GAINS x0.6 THIS WEEK", e = { energy = 10, gain = 0.6 } },
      { t = "BUY A FREEZER CHEST", fx = "ENERGY +5 \u{2022} MOOD +1 \u{2022} FACILITY XP -2", e = { energy = 5, mood = 1, facxp = -2 } },
      { t = "TOUGHEN UP", fx = "TRAINING GAINS x1.25 THIS WEEK \u{2022} ENERGY -12", e = { gain = 1.25, energy = -12 } } } },
  { key = "tarp", photo = "rain-tarp", when = "home", title = "RAIN. THE TARP IS STUCK.",
    body = "The grounds crew is three men and a dog. The dog is trying.",
    opts = {
      { t = "EVERYBODY GRAB A CORNER", fx = "MOOD +1 ALL \u{2022} ENERGY -8", e = { mood = 1, energy = -8 } },
      { t = "CARDS IN THE CLUBHOUSE", fx = "ENERGY +6 \u{2022} LINEUP -1 TONIGHT", e = { energy = 6, tonight = { bat = -1 } } },
      { t = "FILM SESSION", fx = "LINEUP +2 TONIGHT \u{2022} MOOD -1 (FILM IS BORING)", e = { tonight = { bat = 2 }, mood = -1 } } } },
  { key = "slump", photo = "bb-dugout", when = "slump", title = "{n} STRAIGHT LOSSES.",
    body = "Somebody wrote WHY on the clubhouse chalkboard. Nobody will say who.",
    opts = {
      { t = "CLOSED-DOOR MEETING", fx = "50%: LINEUP +3 & MOOD +1 \u{2022} ELSE MOOD -1", e = { chance = { p = 0.5, e = { tonight = { bat = 3 }, mood = 1 }, no = { mood = -1 } } } },
      { t = "KARAOKE NIGHT", fx = "MOOD +1 ALL \u{2022} ENERGY -6", e = { mood = 1, energy = -6 } },
      { t = "EXTRA BATTING PRACTICE", fx = "LINEUP +2 TONIGHT \u{2022} ENERGY -10", e = { tonight = { bat = 2 }, energy = -10 } } } },
  { key = "streak", photo = "bb-crowd", when = "streak", title = "{n} STRAIGHT WINS.",
    body = "Nobody has shaved. The clubhouse smells like a gym bag in July.",
    opts = {
      { t = "CHANGE NOTHING", fx = "LINEUP & STAFF +1 TONIGHT \u{2022} ENERGY -6", e = { tonight = { bat = 1, pit = 1 }, energy = -6 } },
      { t = "REST THE REGULARS", fx = "ENERGY +12 \u{2022} LINEUP -2 TONIGHT", e = { energy = 12, tonight = { bat = -2 } } },
      { t = "SHAVE, FOR GOD'S SAKE", fx = "MOOD -1 \u{2022} 4 PLAYERS UP AN ARROW", e = { mood = -1, cond = 1 } } } },
  { key = "column", photo = "newspaper", title = "A COLUMNIST CALLS YOU BUMS.",
    body = "\"They couldn't hit water if they fell out of a boat.\" It's taped up in every bar in town.",
    opts = {
      { t = "PIN IT TO THE WALL", fx = "LINEUP +2 TONIGHT \u{2022} MOOD -1", e = { tonight = { bat = 2 }, mood = -1 } },
      { t = "INVITE HIM TO BATTING PRACTICE", fx = "50%: HE WHIFFS ON TV. MOOD +1 ALL", e = { chance = { p = 0.5, e = { mood = 1, news = "A columnist took batting practice with the {club}. He did not hit water." } } } },
      { t = "NO COMMENT", fx = "ENERGY +3 \u{2022} NOTHING HAPPENS", e = { energy = 3 } } } },
  { key = "hotdog", photo = "hotdog", when = "home", title = "TEN-CENT HOT DOG NIGHT.",
    body = "Promotions ordered 40,000 hot dogs. Promotions did not order buns.",
    opts = {
      { t = "THE PLAYERS SERVE THE DOGS", fx = "MOOD +1 ALL \u{2022} ENERGY -8", e = { mood = 1, energy = -8 } },
      { t = "LOCK THE CLUBHOUSE DOOR", fx = "ENERGY +5 \u{2022} THE FANS NOTICE: MOOD -1", e = { energy = 5, mood = -1 } },
      { t = "EAT THE LEFTOVERS", fx = "MOOD +1 \u{2022} ENERGY -5 \u{2022} 30%: 4 DOWN AN ARROW", e = { mood = 1, energy = -5, chance = { p = 0.3, e = { cond = -1 } } } } } },
  { key = "flu", photo = "sick", title = "A FLU IS GOING AROUND.",
    body = "Half the bullpen is in the trainer's room. The other half is coughing on it.",
    opts = {
      { t = "QUARANTINE THE SICK", fx = "STAFF -2 TONIGHT \u{2022} ENERGY +5", e = { tonight = { pit = -2 }, energy = 5 } },
      { t = "PLAY THROUGH IT", fx = "ENERGY -14", e = { energy = -14 } },
      { t = "CALL THE TEAM DOCTOR", fx = "ENERGY +8 \u{2022} TRAINING GAINS x0.7 THIS WEEK", e = { energy = 8, gain = 0.7 } } } },
  { key = "alarm", photo = "streetlight", when = "road", title = "FIRE ALARM, 3 A.M.",
    body = "The hotel says it was a drill. The shortstop is still in the parking lot in a towel.",
    opts = {
      { t = "MOVE HOTELS", fx = "ENERGY +4 \u{2022} FACILITY XP -2 (THE BILL)", e = { energy = 4, facxp = -2 } },
      { t = "SLEEP IN, SKIP THE WORKOUT", fx = "ENERGY +8 \u{2022} TRAINING GAINS x0.8 THIS WEEK", e = { energy = 8, gain = 0.8 } },
      { t = "SHRUG IT OFF", fx = "ENERGY -10 \u{2022} MOOD +1 (A STORY TO TELL)", e = { energy = -10, mood = 1 } } } },
  { key = "oldtimers", photo = "oldman", when = "home", title = "OLD-TIMERS' DAY.",
    body = "Six legends, two canes and one argument about 1931 that nobody is going to win.",
    opts = {
      { t = "LET THEM RUN THE CAGES", fx = "CAGES XP +3 \u{2022} ENERGY -4", e = { fac = { k = "bat", n = 3 }, energy = -4 } },
      { t = "LET THEM TALK PITCHING", fx = "MOUNDS XP +3 \u{2022} ENERGY -4", e = { fac = { k = "arms", n = 3 }, energy = -4 } },
      { t = "FREE AUTOGRAPHS", fx = "MOOD +1 ALL", e = { mood = 1 } } } },
  { key = "owner", photo = "office", title = "THE OWNER WANTS A WORD.",
    body = "He has notes. He has a slide projector. He has the whole afternoon.",
    opts = {
      { t = "PROMISE HIM A BIG WEEK", fx = "LINEUP +2 & STAFF +1 TONIGHT \u{2022} ENERGY -8", e = { tonight = { bat = 2, pit = 1 }, energy = -8 } },
      { t = "ASK FOR NEW EQUIPMENT", fx = "60%: YOUR PROGRAM'S FACILITY XP +4", e = { chance = { p = 0.6, e = { facxp = 4, news = "The owner paid for new equipment. Nobody knows why." } } } },
      { t = "SEND THE PITCHING COACH", fx = "MOOD +1 ALL (THE CLUB HEARD ABOUT IT)", e = { mood = 1 } } } },
  { key = "snow", photo = "blizzard", months = { 4 }, title = "SNOW IN APRIL.",
    body = "The infield is white. The commissioner's office says the game is on.",
    opts = {
      { t = "PLAY ON", fx = "ENERGY -10 \u{2022} 30%: 4 DOWN AN ARROW", e = { energy = -10, chance = { p = 0.3, e = { cond = -1 } } } },
      { t = "SNOWBALL FIGHT", fx = "MOOD +1 ALL \u{2022} ENERGY -5", e = { mood = 1, energy = -5 } },
      { t = "INDOOR CAGES ALL DAY", fx = "TRAINING GAINS x1.2 THIS WEEK \u{2022} ENERGY -6", e = { gain = 1.2, energy = -6 } } } },
  { key = "mascot", photo = "mascot", when = "home", title = "THE MASCOT QUIT.",
    body = "He left the costume in the dugout. It is still looking at everyone.",
    opts = {
      { t = "THE BAT BOY WEARS IT", fx = "MOOD +1 ALL", e = { mood = 1, energy = -2 } },
      { t = "A PLAYER WEARS IT", fx = "MOOD +1 \u{2022} ENERGY -8 \u{2022} 50%: FRONT PAGE", e = { mood = 1, energy = -8, chance = { p = 0.5, e = { cond = 1, news = "A {club} player wore the mascot suit between innings. Front page." } } } },
      { t = "BURN THE COSTUME", fx = "MOOD -1 \u{2022} LINEUP +2 TONIGHT", e = { mood = -1, tonight = { bat = 2 } } } } },
  { key = "fan", photo = "fan-on-field", title = "A FAN RAN ON THE FIELD.",
    body = "He reached second base before security caught up. He was safe. Technically.",
    opts = {
      { t = "OFFER HIM A TRYOUT (A JOKE)", fx = "MOOD +1 ALL", e = { mood = 1, energy = -2 } },
      { t = "SPEED DRILLS, NOW", fx = "LINEUP +1 TONIGHT \u{2022} ENERGY -6", e = { tonight = { bat = 1 }, energy = -6 } },
      { t = "CLOSE THE GATES EARLY", fx = "ENERGY +4", e = { energy = 4 } } } },
}
W.EVENT = {}
for _, e in ipairs(W.EVENTS) do W.EVENT[e.key] = e end
W.EVENTS_PER_WEEK = 0.85

local function eligible(L, e, d)
  local m = PL.calendar(min(d, #L.sched), L)
  if e.months then
    local ok = false
    for _, x in ipairs(e.months) do if x == m then ok = true end end
    if not ok then return false end
  end
  local g = PL.gameFor(L, L.user, d)
  if not g then return false end
  local T = L.teams[L.user]
  if e.when == "road" then return g.a == L.user end
  if e.when == "home" then return g.h == L.user end
  if e.when == "slump" then return (T.streak or 0) <= -3 end
  if e.when == "streak" then return (T.streak or 0) >= 4 end
  return true
end

--- At the week's start: maybe one clubhouse event, on a game day of this week that isn't the
--- featured game (about 12 a season in 84 games).
function W.pickEvent(L)
  local c = L.club
  c.ev = nil
  local sp = W.span(L)
  if sp.po or not sp.d0 then return nil end
  local weeks = #W.weeks(L)
  local target = floor(weeks * W.EVENTS_PER_WEEK + 0.5)
  local left = weeks - sp.w + 1
  local rng = PL.rng(L, 77)
  if c.evN >= target or not rng:chance(clamp((target - c.evN) / max(1, left), 0, 1)) then return nil end
  local feat = c.feat and c.feat.d
  local days = {}
  for d = max(L.day + 1, sp.d0), sp.d1 do
    if PL.gameFor(L, L.user, d) and d ~= feat then days[#days + 1] = d end
  end
  if #days == 0 then return nil end
  local d = days[rng:int(#days)]
  local pool, any = {}, {}
  for _, e in ipairs(W.EVENTS) do
    if not c.evSeen[e.key] then
      any[#any + 1] = e
      if eligible(L, e, d) then pool[#pool + 1] = e end
    end
  end
  local e = (#pool > 0 and rng:pick(pool)) or nil
  if not e then
    -- (every event used once this season: the plain ones come round again)
    for _, x in ipairs(W.EVENTS) do if not x.when and not x.months then pool[#pool + 1] = x end end
    e = rng:pick(pool)
  end
  c.ev = { d = d, key = e.key }
  return c.ev
end

--- The event's text with the club's name and the streak filled in.
function W.eventText(L, s)
  local T = L.teams[L.user]
  local n = abs(T.streak or 0)
  local words = { "NO", "ONE", "TWO", "THREE", "FOUR", "FIVE", "SIX", "SEVEN", "EIGHT", "NINE", "TEN" }
  s = s:gsub("{n}", words[n + 1] or tostring(n))
  s = s:gsub("{club}", PennantClubs.byAbbr[L.user].name)
  return s
end

--- Apply one effect table; returns lines saying what happened.
function W.applyEffect(L, e, rng, out)
  out = out or {}
  local c = L.club
  if e.energy then W.addEnergy(L, e.energy) end
  if e.mood then W.addMood(L, e.mood, rng, 0.75) end
  if e.cond then W.addCond(L, e.cond, rng, 4) end
  if e.tonight then
    local _, d = PL.nextGame(L, L.user)
    if d then
      local t = c.tonight and c.tonight.d == d and c.tonight or { d = d }
      t.bat = (t.bat or 0) + (e.tonight.bat or 0)
      t.pit = (t.pit or 0) + (e.tonight.pit or 0)
      c.tonight = t
    end
  end
  if e.gain then c.gainWk = { w = W.span(L).w, x = e.gain } end
  if e.facxp then W.addFacXp(L, c.prog ~= "rest" and c.prog or "bat", e.facxp) end
  if e.fac then W.addFacXp(L, e.fac.k, e.fac.n) end
  if e.noRest then c.noRest = W.span(L).w + e.noRest end
  if e.news then PL.news(L, W.eventText(L, e.news), true) out[#out + 1] = W.eventText(L, e.news) end
  if e.chance then
    if rng:chance(e.chance.p) then
      out.lucky = true
      W.applyEffect(L, e.chance.e, rng, out)
    elseif e.chance.no then
      out.lucky = false
      W.applyEffect(L, e.chance.no, rng, out)
    else
      out.lucky = false
    end
  end
  return out
end

--- The user picked option i of today's event.
function W.resolveEvent(L, i)
  local c = L.club
  local ev = c.ev
  if not ev then return nil end
  local e = W.EVENT[ev.key]
  local o = e.opts[i] or e.opts[1]
  local rng = PL.rng(L, 141)
  local out = W.applyEffect(L, o.e, rng, {})
  ev.done = true
  c.evSeen[e.key] = true
  c.evN = (c.evN or 0) + 1
  PL.news(L, "CLUBHOUSE: " .. W.eventText(L, e.title):gsub("%.$", "") .. " You chose: " .. o.t:lower() .. ".", true)
  if PEng.invalidate then PEng.invalidate() end
  return out
end

-- Stops between the days of a run (the clubhouse event; future: inheritance events) ------------------------

W.stops = W.stops or {}
--- Register an interstitial: { id, due = function(L) -> payload|nil, open = function(L, payload, onDone) }.
--- Stops are checked before each day of a week run, in registration order.
function W.addStop(s)
  for i, x in ipairs(W.stops) do if x.id == s.id then W.stops[i] = s return end end
  W.stops[#W.stops + 1] = s
end

function W.dueStops(L)
  local out = {}
  for _, s in ipairs(W.stops) do
    local p = s.due(L)
    if p then out[#out + 1] = { stop = s, payload = p } end
  end
  return out
end

W.addStop({ id = "clubhouse", due = function(L)
  local ev = L.club and L.club.ev
  if ev and not ev.done and ev.d == L.day and PL.gameFor(L, L.user) then return ev end
  return nil
end })

-- Monthly goals --------------------------------------------------------------------------------------------------

W.MONTH = { "JAN", "FEB", "MAR", "APR", "MAY", "JUN", "JUL", "AUG", "SEP", "OCT", "NOV", "DEC" }
W.MONTH_LONG = { "JANUARY", "FEBRUARY", "MARCH", "APRIL", "MAY", "JUNE", "JULY", "AUGUST", "SEPTEMBER", "OCTOBER", "NOVEMBER", "DECEMBER" }

function W.monthOf(L, d)
  d = d or L.day
  if L.phase ~= "season" and d > (L.regDays or 0) then return 10 end
  return (PL.calendar(min(d, #L.sched), L))
end

--- The user's games in month m: days list (regular season).
local function monthDays(L, m)
  local out = {}
  for d = 1, L.regDays or #L.sched do
    if PL.calendar(d, L) == m and PL.gameFor(L, L.user, d) then out[#out + 1] = d end
  end
  return out
end

local function monthRecord(L, m)
  local w, l = 0, 0
  for _, d in ipairs(monthDays(L, m)) do
    local g = PL.gameFor(L, L.user, d)
    if g.done then
      local me = g.h == L.user and g.hs or g.as
      local them = g.h == L.user and g.as or g.hs
      if me > them then w = w + 1 elseif me < them then l = l + 1 end
    end
  end
  return w, l
end

local function seriesWon(L, m)
  local n = 0
  for _, st in ipairs(PL.route(L, L.user)) do
    if PL.calendar(st.d0, L) == m and st.done == st.n and st.w > st.l then n = n + 1 end
  end
  return n
end

local function seriesIn(L, m)
  local n = 0
  for _, st in ipairs(PL.route(L, L.user)) do if PL.calendar(st.d0, L) == m then n = n + 1 end end
  return n
end

--- Games back of 4th (0 inside the line).
local function gb4(L)
  local st = PL.standings(L)
  local T = L.teams[L.user]
  local r = PL.rank(L, L.user)
  if r <= 4 then return 0 end
  return ((st[4].w - T.w) + (T.l - st[4].l)) / 2
end

local function nextMonthDate(m) return W.MONTH[m % 12 + 1] .. " 1" end

--- One goal of a kind for month m, set from the club's spot.
function W.makeGoal(L, m, kind)
  local T = L.teams[L.user]
  local r = PL.rank(L, L.user)
  local g = { m = m, state = "now", kind = kind }
  local ML = W.MONTH_LONG[m] or "THE MONTH"
  if kind == "pennant" then g.text = "WIN THE PENNANT"
  elseif kind == "pct" then g.text = "FINISH " .. ML .. " .500 OR BETTER"
  elseif kind == "wins" then
    local left = 0
    for _, d in ipairs(monthDays(L, m)) do if d >= L.day then left = left + 1 end end
    local q = r <= 2 and 0.6 or (r >= 6 and 0.47 or 0.54)
    g.n = T.w + max(1, math.ceil(left * q))
    g.text = g.n .. " WINS BY " .. nextMonthDate(m):upper()
  elseif kind == "rank" then
    g.n = r <= 2 and 2 or 4
    g.text = "IN THE TOP " .. g.n .. " ON " .. nextMonthDate(m):upper()
  elseif kind == "gb4" then
    g.n = max(1, floor(gb4(L) / 2))
    g.text = "WITHIN " .. g.n .. " OF 4TH ON " .. nextMonthDate(m):upper()
  elseif kind == "series" then
    g.n = max(2, floor(seriesIn(L, m) * 0.5 + 0.5))
    g.text = "WIN " .. g.n .. " SERIES IN " .. ML
  elseif kind == "playoffs" then g.text = "MAKE THE PLAYOFFS" end
  return g
end

--- This month's goals: two offered (the Goals screen asks for a pick; the first stands until then).
--- A miss costs a point of mood, nothing more.
function W.newGoal(L)
  local c = L.club
  local m = W.monthOf(L)
  c.goalOffer = nil
  if L.phase == "awards" then c.goal = nil return nil end
  local r = PL.rank(L, L.user)
  local kinds
  if L.phase == "playoffs" or m >= 10 then
    if W.userSeries(L) or (L.seeds and (L.seeds[1] == L.user or L.seeds[2] == L.user or L.seeds[3] == L.user or L.seeds[4] == L.user)) then
      kinds = { "pennant" }
    else c.goal = nil return nil end
  else
    local place = r <= 4 and "rank" or "gb4"
    local e = PL.elimination(L, L.user)
    kinds = ({ [4] = { "pct", "series" }, [5] = { "wins", "series" }, [6] = { place, "wins" }, [7] = { "series", "pct" },
      [8] = { "wins", place }, [9] = { (e and e <= 8) and "pct" or "playoffs", "series" } })[m] or { "pct", "series" }
  end
  local a = W.makeGoal(L, m, kinds[1])
  c.goal = a
  if kinds[2] then c.goalOffer = { a, W.makeGoal(L, m, kinds[2]) } end
  return a
end

--- The pick (1 or 2) of this month's offered goals.
function W.pickGoal(L, i)
  local c = L.club
  local o = c.goalOffer
  if not o then return end
  c.goal = o[i] or o[1]
  c.goalOffer = nil
end


--- A goal's progress line: "11/18", "14-12", "3RD", "2 GB", "2/3".
function W.goalProgress(L, g)
  local T = L.teams[L.user]
  if g.kind == "wins" then return T.w .. "/" .. g.n, T.w / max(1, g.n) end
  if g.kind == "pct" then local w, l = monthRecord(L, g.m) return w .. "-" .. l, (w + l) > 0 and w / (w + l) or 0 end
  if g.kind == "rank" then local r = PL.rank(L, L.user) return PUI and PUI.ord(r):upper() or tostring(r), r <= g.n and 1 or 0.5 end
  if g.kind == "gb4" then local gb = gb4(L) return gb <= 0 and "IN" or (PL.gbText(gb) .. " GB"), gb <= g.n and 1 or 0.4 end
  if g.kind == "series" then local n = seriesWon(L, g.m) return n .. "/" .. g.n, n / g.n end
  if g.kind == "playoffs" then local r = PL.rank(L, L.user) return PUI and PUI.ord(r):upper() or tostring(r), r <= 4 and 1 or 0.4 end
  if g.kind == "pennant" then local s = W.userSeries(L) return s and (s.final and "FINAL" or "SEMI") or (L.champ == L.user and "WON" or "-"), 0.5 end
  return "", 0
end

function W.goalShort(L, g) return W.MONTH[g.m] .. " GOAL: " .. g.text end

local function clearGoal(L, g, state)
  local c = L.club
  g.state = state
  c.goals[#c.goals + 1] = { m = g.m, text = g.text, state = state, res = (W.goalProgress(L, g)) }
  if state == "done" then
    c.rewards = c.rewards or {}
    c.rewards[#c.rewards + 1] = { m = g.m, text = g.text }
    PL.news(L, "GOAL CLEARED: " .. g.text .. ".", true)
  else
    W.addMood(L, -1, PL.rng(L, 57), 0.5)
  end
  c.goalOffer = nil
end

--- After every day closes (PL.finishDay): goals cleared early, a month's end judged, the next goal.
function W.dayClosed(L)
  local c = L.club
  if not c then return end
  local g = c.goal
  if g and g.state == "now" then
    local T = L.teams[L.user]
    if g.kind == "wins" and T.w >= g.n then clearGoal(L, g, "done")
    elseif g.kind == "series" and seriesWon(L, g.m) >= g.n then clearGoal(L, g, "done")
    elseif g.kind == "playoffs" and (PL.magic(L, L.user) or 1) <= 0 then clearGoal(L, g, "done")
    elseif g.kind == "pennant" and L.phase == "awards" then clearGoal(L, g, L.champ == L.user and "done" or "miss")
    elseif g.kind == "pennant" and L.phase == "playoffs" and not W.userSeries(L) then clearGoal(L, g, "miss") end
  end
  -- the month is over
  local m = (L.phase == "season") and W.monthOf(L) or 10
  if g and g.m ~= m and L.phase ~= "awards" then
    if g.state == "now" then
      local ok
      if g.kind == "pct" then local w, l = monthRecord(L, g.m) ok = w >= l and (w + l) > 0
      elseif g.kind == "rank" then ok = PL.rank(L, L.user) <= g.n
      elseif g.kind == "gb4" then ok = gb4(L) <= g.n
      elseif g.kind == "playoffs" then ok = PL.rank(L, L.user) <= 4
      else ok = false end
      clearGoal(L, g, ok and "done" or "miss")
    end
    c.monthNote = { m = g.m, state = g.state, text = g.text }
    c.goal = nil
    W.newGoal(L)
    if c.goal then c.monthNote.next = c.goal.text c.monthNote.nm = c.goal.m end
  elseif not g and L.phase == "playoffs" then
    W.newGoal(L)
  end
end

W.REWARDS = {
  { k = "fac", t = "FACILITY +1 LV", d = "Your program's facility goes up a level" },
  { k = "scout", t = "SCOUT A PROSPECT", d = "A blue-chip kid joins the farm" },
  { k = "energy", t = "+20 ENERGY, ALL", d = "Everybody gets a breather" },
}

--- The facility a reward would raise: the current program's (the lowest when resting).
function W.rewardFac(L)
  local c = L.club
  if c.prog ~= "rest" and (c.fac[c.prog] or 1) < 5 then return c.prog end
  local best, bl = nil, 99
  for _, k in ipairs(W.PROGS) do if c.fac[k] < bl then best, bl = k, c.fac[k] end end
  return bl < 5 and best or nil
end

--- Claim the first pending reward with pick k; returns a line saying what it did.
function W.claim(L, k)
  local c = L.club
  local rw = c.rewards and table.remove(c.rewards, 1)
  if c.rewards and #c.rewards == 0 then c.rewards = nil end
  local rng = PL.rng(L, 313)
  local T = L.teams[L.user]
  if k == "fac" then
    local f = W.rewardFac(L)
    if f then
      local lv = c.fac[f] + 1
      c.fac[f] = lv
      c.fxp[f] = max(c.fxp[f], W.FAC_LV[lv])
      return W.PROG[f].fac .. " UP TO LV" .. lv
    end
    k = "energy"
  end
  if k == "scout" then
    local isP = rng:chance(0.5)
    local pos = isP and "P" or rng:pick(PM.POSITIONS)
    local p = PGen.player(L, rng, { pos = pos, role = isP and (rng:chance(0.5) and "SP" or "RP") or nil, mean = 47 + rng:normal(0, 2), age = 19 + rng:int(3) - 1 })
    p.pot = clamp(max(p.pot or 0, PM.ovr(p) + 14), 0, 80)
    PGen.setCaps(p, rng)
    p.team, p.lvl, p.rk = L.user, "F", true
    p.s0, p.wk = PM.snapshot(p), PM.snapshot(p)
    p.wkx = PL.progress(p)
    T.farm[#T.farm + 1] = p.id
    L.usedNames, L.usedFaces = nil, nil
    PL.news(L, "SCOUTED: " .. PM.name(p) .. " (" .. (p.pos == "P" and p.role or p.pos) .. ", " .. p.age .. ") signs with the farm club.", true)
    return "SIGNED " .. PM.name(p):upper() .. ", " .. (p.pos == "P" and p.role or p.pos) .. ", " .. string.rep("\u{2605}", PM.potStars(p))
  end
  W.addEnergy(L, 20)
  return "ENERGY +20 FOR EVERYONE"
end

-- Office: individual plans ----------------------------------------------------------------------------------------

function W.setOwn(L, id, on) L.club.own[tostring(id)] = on or nil end
function W.clearOwn(L) L.club.own = {} end
