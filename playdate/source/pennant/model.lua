-- Pennant player model: ratings (20-80 scouting scale), overall, grades, potential caps,
-- condition/mood/fatigue, and the compact save encoding.
--
-- A player:
--   id, fn, ln, nick, face (face-bank number), age, pos ("C".."RF","DH","P"), pos2 (alt position),
--   bats ("L"/"R"/"S"), throws, role ("SP"/"RP" for pitchers), r = ratings, cap = per-rating caps,
--   pitches = { {k="FB", q=55}, ... }, xp = training progress per rating,
--   cond 1..5 (Power Pro arrows: 1 = worst), mood -2..2, fat 0..100, inj = { k = "hamstring", d = days } | nil,
--   team (club abbr), lvl ("ML" | "F" farm), plan = { f = focus, i = intensity 0..3 },
--   st (season stats), car (career totals), wk (last week's ratings), s0 (season-start ratings),
--   yrs (pro seasons), mlYrs, rk (rookie this season), tr (a legacy trait: pennant/legacy.lua)

PM = PM or {}

PM.BAT_KEYS = { "con", "pow", "eye", "spd", "fld", "arm" }
PM.PIT_KEYS = { "velo", "ctl", "stf", "sta" }
PM.LABEL = { con = "Contact", pow = "Power", eye = "Eye", spd = "Speed", fld = "Fielding", arm = "Arm",
  velo = "Velocity", ctl = "Control", stf = "Stuff", sta = "Stamina" }
PM.SHORT = { con = "CON", pow = "POW", eye = "EYE", spd = "SPD", fld = "FLD", arm = "ARM",
  velo = "VEL", ctl = "CTL", stf = "STF", sta = "STA" }
PM.POSITIONS = { "C", "1B", "2B", "3B", "SS", "LF", "CF", "RF" }
PM.PITCH_NAME = { FB = "Fastball", SI = "Sinker", CT = "Cutter", SL = "Slider", CB = "Curve", CH = "Change", SPL = "Splitter" }
PM.PITCH_DV = { FB = 0, SI = -1, CT = -4, SL = -8, CB = -12, CH = -9, SPL = -8 }

local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
PM.clamp = clamp

-- Defensive weight of each position for overall (catchers and shortstops field more).
local DEF_W <const> = { C = 0.30, SS = 0.28, CF = 0.26, ["2B"] = 0.24, ["3B"] = 0.22, RF = 0.18, LF = 0.14, ["1B"] = 0.10, DH = 0 }

function PM.isPitcher(p) return p.pos == "P" end

--- Overall 20-80.
function PM.ovr(p)
  local r = p.r
  if p.pos == "P" then
    local o = r.velo * 0.24 + r.ctl * 0.26 + r.stf * 0.32 + r.sta * (p.role == "SP" and 0.18 or 0.08)
    return math.floor(o / (p.role == "SP" and 1.0 or 0.90) + 0.5)
  end
  local dw = DEF_W[p.pos] or 0.2
  local bat = r.con * 0.32 + r.pow * 0.30 + r.eye * 0.18 + r.spd * 0.20
  local def = r.fld * 0.7 + r.arm * 0.3
  return math.floor(bat * (1 - dw) + def * dw + 0.5)
end

local GRADES <const> = { { 72, "S" }, { 65, "A" }, { 58, "B" }, { 50, "C" }, { 43, "D" }, { 36, "E" }, { 28, "F" }, { 0, "G" } }
function PM.grade(v)
  for _, g in ipairs(GRADES) do if v >= g[1] then return g[2] end end
  return "G"
end

--- Velocity rating -> fastball mph.
--- A uniform number for BallCast's player looks: stable per player (derived from the id, so no save
--- change), 1-59 like the online league's.
function PM.uniform(p) return p.num or (1 + (p.id * 37 + 11) % 59) end

function PM.mph(v) return math.floor(92.5 + (v - 50) * 0.15 + 0.5) end

function PM.name(p) return p.fn .. " " .. p.ln end
function PM.short(p) return p.fn:sub(1, 1) .. ". " .. p.ln end

--- Potential as 1..5 stars (from the gap between the caps and now, and the cap level).
function PM.potStars(p)
  local v = p.pot or PM.ovr(p)
  if v >= 70 then return 5 elseif v >= 62 then return 4 elseif v >= 54 then return 3 elseif v >= 46 then return 2 end
  return 1
end

function PM.keys(p) return p.pos == "P" and PM.PIT_KEYS or PM.BAT_KEYS end

-- Condition ------------------------------------------------------------------------------
-- 1 = arrow down (awful) .. 3 = level .. 5 = arrow up (great). Rating bonus applied in games.
PM.COND_BONUS = { -6, -3, 0, 3, 6 }
PM.COND_NAME = { "Awful", "Poor", "Normal", "Good", "Great" }
PM.MOOD_NAME = { [-2] = "Upset", [-1] = "Down", [0] = "Fine", [1] = "Happy", [2] = "Fired up" }

--- Effective rating bonus from condition, mood and fatigue (added to every rating in games).
function PM.formBonus(p)
  local b = PM.COND_BONUS[p.cond or 3] + (p.mood or 0) * 0.5
  local f = p.fat or 0
  if f > 55 then b = b - (f - 55) / 7 end
  return b
end

-- Season / career stats -------------------------------------------------------------------
PM.BAT_STATS = { "g", "pa", "ab", "h", "d", "t", "hr", "r", "rbi", "bb", "k", "sb", "cs", "hbp", "sf" }
PM.PIT_STATS = { "g", "gs", "w", "l", "sv", "hld", "outs", "h", "r", "er", "bb", "k", "hr", "bf", "np" }

function PM.newStats()
  return { b = {}, p = {} }
end

local function nz(t, k) return t[k] or 0 end
PM.nz = nz

function PM.avg(b) local ab = nz(b, "ab") return ab > 0 and nz(b, "h") / ab or 0 end
function PM.obp(b)
  local d = nz(b, "ab") + nz(b, "bb") + nz(b, "hbp") + nz(b, "sf")
  return d > 0 and (nz(b, "h") + nz(b, "bb") + nz(b, "hbp")) / d or 0
end
function PM.slg(b)
  local ab = nz(b, "ab")
  if ab == 0 then return 0 end
  local tb = nz(b, "h") + nz(b, "d") + 2 * nz(b, "t") + 3 * nz(b, "hr")
  return tb / ab
end
function PM.era(p) local o = nz(p, "outs") return o > 0 and nz(p, "er") * 27 / o or 0 end
function PM.whip(p) local o = nz(p, "outs") return o > 0 and (nz(p, "h") + nz(p, "bb")) * 3 / o or 0 end
function PM.ip(p) local o = nz(p, "outs") return string.format("%d.%d", o // 3, o % 3) end

--- ".287" style.
function PM.rate3(v)
  local s = string.format("%.3f", v)
  if s:sub(1, 1) == "0" then s = s:sub(2) end
  return s
end

function PM.addStats(dst, src)
  for k, v in pairs(src) do dst[k] = (dst[k] or 0) + v end
end

-- Save encoding ---------------------------------------------------------------------------
-- One player = one positional array (JSON arrays are a third the size of keyed objects).
-- Version 1 layout; unknown trailing values are ignored by older readers.

local RK <const> = { "con", "pow", "eye", "spd", "fld", "arm", "velo", "ctl", "stf", "sta" }
local function packR(r)
  local t = {}
  for i, k in ipairs(RK) do t[i] = r[k] and math.floor(r[k] + 0.5) or -1 end
  return t
end
local function unpackR(t)
  local r = {}
  for i, k in ipairs(RK) do if t[i] and t[i] >= 0 then r[k] = t[i] end end
  return r
end
local function packStats(s, keys)
  if not s then return 0 end
  local t, any = {}, false
  for i, k in ipairs(keys) do t[i] = s[k] or 0 if t[i] ~= 0 then any = true end end
  return any and t or 0
end
local function unpackStats(t, keys)
  local s = {}
  if type(t) ~= "table" then return s end
  for i, k in ipairs(keys) do if t[i] and t[i] ~= 0 then s[k] = t[i] end end
  return s
end
local function packPitches(ps)
  local t = {}
  for _, x in ipairs(ps or {}) do t[#t + 1] = x.k .. ":" .. math.floor(x.q + 0.5) end
  return table.concat(t, ",")
end
local function unpackPitches(s)
  local t = {}
  for k, q in tostring(s or ""):gmatch("(%u+):(%d+)") do t[#t + 1] = { k = k, q = tonumber(q) } end
  return t
end
local function packXp(xp)
  local t = {}
  for i, k in ipairs(RK) do t[i] = xp and xp[k] and math.floor(xp[k] * 10) or 0 end
  t[#RK + 1] = xp and xp.newp or 0
  return t
end
local function unpackXp(t)
  local xp = {}
  for i, k in ipairs(RK) do if t and t[i] and t[i] ~= 0 then xp[k] = t[i] / 10 end end
  if t and (t[#RK + 1] or 0) ~= 0 then xp.newp = t[#RK + 1] end
  return xp
end

-- the training-progress snapshot (fractional ratings), tenths
local function packWkx(w)
  if not w then return 0 end
  local t = {}
  for i, k in ipairs(RK) do t[i] = w[k] and math.floor(w[k] * 10 + 0.5) or -1 end
  return t
end
local function unpackWkx(t)
  if type(t) ~= "table" then return nil end
  local w = {}
  for i, k in ipairs(RK) do if t[i] and t[i] >= 0 then w[k] = t[i] / 10 end end
  return w
end

function PM.pack(p)
  return {
    p.id, p.fn, p.ln, p.nick or "", p.face, p.age, p.pos, p.pos2 or "", p.bats, p.throws, p.role or "",
    packR(p.r), packR(p.cap), packPitches(p.pitches), packXp(p.xp), p.pot or 0,
    p.cond or 3, p.mood or 0, math.floor((p.fat or 0) + 0.5), p.inj and p.inj.k or "", p.inj and p.inj.d or 0,
    p.team or "", p.lvl or "ML", p.plan and p.plan.f or "", p.plan and p.plan.i or 1,
    packStats(p.st and p.st.b, PM.BAT_STATS), packStats(p.st and p.st.p, PM.PIT_STATS),
    packStats(p.car and p.car.b, PM.BAT_STATS), packStats(p.car and p.car.p, PM.PIT_STATS),
    p.wk and packR(p.wk) or 0, p.s0 and packR(p.s0) or 0, p.yrs or 0, p.mlYrs or 0, p.rk and 1 or 0,
    p.pitchDev or "", p.hand or "", p.awards or "", p.late or 0, p.road or 0, p.rp or 0, p.sat or 0, packWkx(p.wkx),
    p.tr or "",
  }
end

function PM.unpack(a)
  local p = {
    id = a[1], fn = a[2], ln = a[3], nick = a[4] ~= "" and a[4] or nil, face = a[5], age = a[6], pos = a[7],
    pos2 = a[8] ~= "" and a[8] or nil, bats = a[9], throws = a[10], role = a[11] ~= "" and a[11] or nil,
    r = unpackR(a[12]), cap = unpackR(a[13]), pitches = unpackPitches(a[14]), xp = unpackXp(a[15]), pot = a[16],
    cond = a[17], mood = a[18], fat = a[19], inj = (a[20] ~= "" and { k = a[20], d = a[21] }) or nil,
    team = a[22] ~= "" and a[22] or nil, lvl = a[23],
    plan = { f = a[24] ~= "" and a[24] or nil, i = a[25] },
    st = { b = unpackStats(a[26], PM.BAT_STATS), p = unpackStats(a[27], PM.PIT_STATS) },
    car = { b = unpackStats(a[28], PM.BAT_STATS), p = unpackStats(a[29], PM.PIT_STATS) },
    wk = type(a[30]) == "table" and unpackR(a[30]) or nil, s0 = type(a[31]) == "table" and unpackR(a[31]) or nil,
    yrs = a[32] or 0, mlYrs = a[33] or 0, rk = a[34] == 1, pitchDev = (a[35] or "") ~= "" and a[35] or nil,
    awards = (a[37] or "") ~= "" and a[37] or nil, late = a[38] or 0, road = a[39] or 0,
    rp = type(a[40]) == "table" and a[40] or nil, sat = a[41] or 0, wkx = unpackWkx(a[42]),
    tr = (a[43] or "") ~= "" and a[43] or nil,
  }
  return p
end

function PM.snapshot(p)
  local t = {}
  for k, v in pairs(p.r) do t[k] = v end
  return t
end
