-- Pennant rosters: auto lineup / rotation / bullpen roles, call-ups and demotions, injury
-- replacements, trade values. Pure Lua (no playdate APIs) so it runs in the desktop tests too.

PRoster = PRoster or {}
local R = PRoster

R.ML_MAX = 26
R.FARM_MAX = 16
R.ROLES = { "CL", "SU", "MR", "LR" }
R.ROLE_NAME = { CL = "Closer", SU = "Setup", MR = "Middle", LR = "Long" }

local function P(L, id) return L.players[id] end

function R.healthy(p) return not p.inj and (p.late or 0) <= 0 end

--- The platoon edge in rating points against a starter who throws `vs` ("R"|"L"); 0 without one.
--- (The engine gives the batter about 2.5 points with the platoon advantage, docs/PENNANT_ENGINE.md.)
function R.platoon(p, vs)
  if not vs then return 0 end
  if p.bats == "S" then return 2.5 end
  return (p.bats ~= vs) and 2.5 or -2.5
end

--- Bat value (no defense) for ordering; vs = the opposing starter's hand (optional).
function R.batValue(p, vs)
  local r = p.r
  return r.con * 0.34 + r.pow * 0.34 + r.eye * 0.18 + r.spd * 0.14 + PM.formBonus(p) + R.platoon(p, vs) * 2
end

--- How well p plays position pos (bat + glove, penalised off his position).
function R.posValue(p, pos, vs)
  if p.pos == "P" then return -999 end
  local r = p.r
  local bat = R.batValue(p, vs)
  if pos == "DH" then return bat end
  local pen = 0
  if p.pos ~= pos then
    pen = (p.pos2 == pos) and 4 or 12
    if pos == "C" then pen = 30 end
    if pos == "SS" and p.pos ~= "2B" and p.pos ~= "3B" and p.pos2 ~= "SS" then pen = 18 end
  end
  local dw = ({ C = 0.45, SS = 0.42, CF = 0.38, ["2B"] = 0.35, ["3B"] = 0.32, RF = 0.25, LF = 0.2, ["1B"] = 0.12 })[pos] or 0.2
  local glove = r.fld * 0.7 + r.arm * 0.3
  return bat * (1 - dw) + glove * dw - pen
end

local FILL <const> = { "C", "SS", "CF", "2B", "3B", "RF", "LF", "1B" }

function R.hitters(L, T, lvl)
  local out = {}
  for _, id in ipairs(lvl == "F" and T.farm or T.ml) do
    local p = P(L, id)
    if p and p.pos ~= "P" then out[#out + 1] = p end
  end
  return out
end

function R.pitchers(L, T, lvl)
  local out = {}
  for _, id in ipairs(lvl == "F" and T.farm or T.ml) do
    local p = P(L, id)
    if p and p.pos == "P" then out[#out + 1] = p end
  end
  return out
end

--- Positions + batting order from the healthy, rested ML hitters. vs: build the card for a
--- starter of that hand (default: the club's active platoon card, if it keeps two).
function R.autoLineup(L, T, vs)
  if not vs and T.cards then vs = T.cardSide or "R" end
  local pool = {}
  for _, p in ipairs(R.hitters(L, T)) do if R.healthy(p) then pool[#pool + 1] = p end end
  -- rest the exhausted if there's someone to play
  local rested = {}
  for _, p in ipairs(pool) do if (p.fat or 0) < 78 then rested[#rested + 1] = p end end
  if #rested >= 9 then pool = rested end
  local field, used = {}, {}
  for _, pos in ipairs(FILL) do
    local best, bv = nil, -1e9
    for _, p in ipairs(pool) do
      if not used[p.id] then
        local v = R.posValue(p, pos, vs)
        if v > bv then best, bv = p, v end
      end
    end
    if best then field[best.id] = pos used[best.id] = true end
  end
  local dh, dv = nil, -1e9
  for _, p in ipairs(pool) do
    if not used[p.id] and R.batValue(p, vs) > dv then dh, dv = p, R.batValue(p, vs) end
  end
  if dh then field[dh.id] = "DH" used[dh.id] = true end
  -- batting order: speed/OBP up top, power in the middle
  local nine = {}
  for id in pairs(field) do nine[#nine + 1] = P(L, id) end
  T.field = field
  T.order = R.orderFor(nine)
  if T.cards then T.cards[T.cardSide or "R"] = { order = T.order, field = T.field } end
  return T.order
end

-- Platoon cards (P0-4) ----------------------------------------------------------------------------
-- The user's club keeps a lineup card vs RHP and one vs LHP: T.cards = { R = {order, field}, L = ... },
-- T.cardSide = the active one. T.order / T.field always point at the active card's tables, so every
-- reader (sim, engine, hub, wire) is unchanged.

function R.syncCard(T)
  T.cards = T.cards or {}
  local side = T.cardSide or "R"
  T.cardSide = side
  if T.order then T.cards[side] = { order = T.order, field = T.field } end
end

--- Make `side` the active card (building it the first time); validates it.
function R.useCard(L, T, side)
  R.syncCard(T)
  if T.cardSide == side and T.order then return end
  T.cardSide = side
  local c = T.cards[side]
  if c and c.order then
    T.order, T.field = c.order, c.field
    R.validate(L, T)
  else
    R.autoLineup(L, T, side)
  end
end

function R.orderFor(nine)
  local order = {}
  local left = {}
  for _, p in ipairs(nine) do left[#left + 1] = p end
  local function take(score)
    local bi, bv = nil, -1e9
    for i, p in ipairs(left) do
      local v = score(p.r, p)
      if v > bv then bi, bv = i, v end
    end
    if not bi then return nil end
    return table.remove(left, bi)
  end
  local slots = {}
  slots[3] = take(function(r) return r.con * 0.5 + r.pow * 0.5 + r.eye * 0.2 end)
  slots[4] = take(function(r) return r.pow * 0.8 + r.con * 0.2 end)
  slots[1] = take(function(r) return r.spd * 0.45 + r.eye * 0.35 + r.con * 0.3 end)
  slots[2] = take(function(r) return r.con * 0.6 + r.eye * 0.2 + r.spd * 0.2 end)
  slots[5] = take(function(r) return r.pow * 0.6 + r.con * 0.4 end)
  for i = 6, 9 do slots[i] = take(function(r, p) return R.batValue(p) end) end
  for i = 1, 9 do if slots[i] then order[#order + 1] = slots[i].id end end
  return order
end

--- Five-man rotation and bullpen roles.
function R.autoPitching(L, T)
  local ps = {}
  for _, p in ipairs(R.pitchers(L, T)) do if R.healthy(p) then ps[#ps + 1] = p end end
  table.sort(ps, function(a, b)
    local sa = (a.role == "SP" and 100 or 0) + PM.ovr(a) + a.r.sta * 0.2
    local sb = (b.role == "SP" and 100 or 0) + PM.ovr(b) + b.r.sta * 0.2
    return sa > sb
  end)
  T.rot = {}
  local inRot = {}
  for i = 1, math.min(5, #ps) do T.rot[i] = ps[i].id inRot[ps[i].id] = true end
  T.rotIdx = T.rotIdx or 1
  if T.rotIdx > #T.rot then T.rotIdx = 1 end
  local pen = {}
  for _, p in ipairs(ps) do if not inRot[p.id] then pen[#pen + 1] = p end end
  table.sort(pen, function(a, b) return (a.r.stf + a.r.ctl + a.r.velo * 0.5) > (b.r.stf + b.r.ctl + b.r.velo * 0.5) end)
  T.pen = {}
  local lr, lv = nil, -1
  for i = 4, #pen do if pen[i].r.sta > lv then lr, lv = pen[i], pen[i].r.sta end end
  for i, p in ipairs(pen) do
    T.pen[p.id] = (i == 1 and "CL") or ((i == 2 or i == 3) and "SU") or (p == lr and "LR") or "MR"
  end
end

function R.auto(L, T)
  R.autoLineup(L, T)
  R.autoPitching(L, T)
end

--- Lineup sanity before a game: injured players out, empty slots filled (keeps the user's
--- choices where they're still valid). Returns a list of change notes.
function R.validate(L, T)
  local notes = {}
  local ok = true
  local inMl = {}
  for _, id in ipairs(T.ml) do inMl[id] = true end
  if not T.order or #T.order ~= 9 then ok = false end
  for _, id in ipairs(T.order or {}) do
    local p = P(L, id)
    if not p or not inMl[id] or not R.healthy(p) or p.pos == "P" then ok = false
      if p and p.inj then notes[#notes + 1] = PM.short(p) .. " (" .. p.inj.k .. ") out of the lineup" end
    end
  end
  if not ok then R.autoLineup(L, T) end
  local rotOk = T.rot and #T.rot >= 1
  for _, id in ipairs(T.rot or {}) do
    local p = P(L, id)
    if not p or not inMl[id] or not R.healthy(p) then rotOk = false end
  end
  local penOk = true
  for id in pairs(T.pen or {}) do
    local p = P(L, id)
    if not p or not inMl[id] then penOk = false end
  end
  -- pitchers new to the staff (call-ups) need a role
  for _, p in ipairs(R.pitchers(L, T)) do
    local inRot = false
    for _, id in ipairs(T.rot or {}) do if id == p.id then inRot = true end end
    if not inRot and not (T.pen and T.pen[p.id]) then penOk = false end
  end
  if not rotOk or not penOk then
    if not rotOk then notes[#notes + 1] = "Rotation reset (injury)" end
    local keepRoles = T.pen
    R.autoPitching(L, T)
  end
  return notes
end

--- Today's starter: next in the rotation who is healthy and rested.
function R.starter(L, T)
  local n = #T.rot
  for k = 0, n - 1 do
    local i = (T.rotIdx + k - 1) % n + 1
    local p = P(L, T.rot[i])
    if p and R.healthy(p) and (p.fat or 0) < 45 then return p.id, i end
  end
  -- everyone's tired: the freshest
  local best, bi, bf = nil, 1, 1e9
  for i, id in ipairs(T.rot) do
    local p = P(L, id)
    if p and R.healthy(p) and (p.fat or 0) < bf then best, bi, bf = id, i, p.fat end
  end
  return best, bi
end

function R.bench(L, T)
  local inOrder = {}
  for _, id in ipairs(T.order or {}) do inOrder[id] = true end
  local out = {}
  for _, p in ipairs(R.hitters(L, T)) do if not inOrder[p.id] and R.healthy(p) then out[#out + 1] = p.id end end
  return out
end

-- Moves ---------------------------------------------------------------------------------------

local function removeId(list, id)
  for i, x in ipairs(list) do if x == id then table.remove(list, i) return true end end
  return false
end
R.removeId = removeId

function R.activeCount(L, T)
  local n = 0
  for _, id in ipairs(T.ml) do local p = P(L, id) if p and not p.inj then n = n + 1 end end
  return n
end

--- Farm -> big club.
function R.callUp(L, T, id)
  if R.activeCount(L, T) >= R.ML_MAX then return false, "The roster is full (26). Send someone down first." end
  local p = P(L, id)
  if not removeId(T.farm, id) then return false, "Not on the farm." end
  T.ml[#T.ml + 1] = id
  p.lvl = "ML"
  p.mood = math.min(2, (p.mood or 0) + 1)
  if p.pos == "P" and T.pen then T.pen[id] = "MR" end
  return true
end

--- Big club -> farm.
function R.demote(L, T, id)
  local p = P(L, id)
  if #T.farm >= R.FARM_MAX + 4 then return false, "The farm club is full." end
  if not removeId(T.ml, id) then return false, "Not on the big club." end
  T.farm[#T.farm + 1] = id
  p.lvl = "F"
  p.mood = math.max(-2, (p.mood or 0) - 1)
  if T.pen then T.pen[id] = nil end
  removeId(T.rot or {}, id)
  if T.order then
    for i, x in ipairs(T.order) do if x == id then T.order = nil break end end
  end
  return true
end

--- READY: a healthy farm hand who beats the weakest big-leaguer of his kind by 3+ OVR.
function R.ready(L, T, p)
  if not p or p.inj or p.lvl ~= "F" then return false end
  local worst = 99
  for _, mid in ipairs(T.ml) do
    local q = P(L, mid)
    if q and not q.inj and (q.pos == "P") == (p.pos == "P") then worst = math.min(worst, PM.ovr(q)) end
  end
  return PM.ovr(p) >= worst + 3
end

--- The farm hand the assistant GM would call up for an opening (what aiMaintain picks first).
function R.aiPick(L, T)
  local n = 0
  for _, id in ipairs(T.ml) do local p = P(L, id) if p and not p.inj and p.pos == "P" then n = n + 1 end end
  local needPit = n < 12
  local best, bv = nil, -1e9
  for _, id in ipairs(T.farm) do
    local p = P(L, id)
    if p and not p.inj and ((p.pos == "P") == needPit) and PM.ovr(p) > bv then best, bv = id, PM.ovr(p) end
  end
  return best
end

--- The best farm replacement for an injured player: his position first, then his kind (pitcher / hitter).
function R.bestReplacement(L, T, hurt)
  local best, bv = nil, -1e9
  for _, id in ipairs(T.farm) do
    local p = P(L, id)
    if p and not p.inj and (p.pos == "P") == (hurt.pos == "P") then
      local v = PM.ovr(p) + ((p.pos == hurt.pos or p.pos2 == hurt.pos) and 8 or 0) + ((hurt.pos == "P" and p.role == hurt.role) and 6 or 0)
      if v > bv then best, bv = id, v end
    end
  end
  return best
end

--- Who the coaches would play at a position without a move (a scratch lineup; the club's card is untouched).
function R.coverFor(L, T, pos)
  local Tc = setmetatable({ cards = false }, { __index = T })
  R.autoLineup(L, Tc, T.cardSide)
  for id, ps in pairs(rawget(Tc, "field") or {}) do if ps == pos then return id end end
  return nil
end

--- AI: keep 26 healthy players on the big club (call up for the injured; send the healed back
--- down once the roster overflows), position and pitcher counts balanced.
function R.aiMaintain(L, T)
  local function count(pit)
    local n = 0
    for _, id in ipairs(T.ml) do local p = P(L, id) if p and not p.inj and (p.pos == "P") == pit then n = n + 1 end end
    return n
  end
  for _ = 1, 6 do
    local act = R.activeCount(L, T)
    if act >= R.ML_MAX then break end
    local needPit = count(true) < 12
    local best, bv = nil, -1e9
    for _, id in ipairs(T.farm) do
      local p = P(L, id)
      if p and not p.inj and ((p.pos == "P") == needPit) and PM.ovr(p) > bv then best, bv = id, PM.ovr(p) end
    end
    if not best then break end
    R.callUp(L, T, best)
  end
  -- too many: demote the weakest healthy of the overrepresented group
  for _ = 1, 6 do
    if R.activeCount(L, T) <= R.ML_MAX then break end
    local pit = count(true) > 13
    local worst, wv = nil, 1e9
    for _, id in ipairs(T.ml) do
      local p = P(L, id)
      if p and not p.inj and ((p.pos == "P") == pit) and PM.ovr(p) < wv then worst, wv = id, PM.ovr(p) end
    end
    if not worst then break end
    R.demote(L, T, worst)
  end
end

-- Trades -----------------------------------------------------------------------------------------

--- What a club thinks a player is worth: ability now, upside, age.
function R.value(p)
  local o = PM.ovr(p)
  local pot = p.pot or o
  local age = p.age
  local now = (o - 30) ^ 1.6
  local upside = math.max(0, pot - o) * math.max(0, 29 - age) * 0.25
  local agePen = age > 30 and (age - 30) * 0.08 or 0
  local v = (now + upside * 6) * (1 - math.min(0.6, agePen))
  if p.inj then v = v * (p.inj.d > 30 and 0.5 or 0.85) end
  return math.max(1, v)
end

--- AI response to a trade: give = user's players, get = theirs. Returns accepted, ratio, note.
function R.evaluate(L, T, other, give, get)
  local vg, vr = 0, 0
  for _, id in ipairs(give) do vg = vg + R.value(P(L, id)) end
  for _, id in ipairs(get) do vr = vr + R.value(P(L, id)) end
  -- they need roster balance: losing a position group hurts
  local ratio = vg / math.max(1, vr)
  local need = 1.08
  if #give < #get then need = need + 0.06 * (#get - #give) end
  local note
  if ratio >= need then note = "Deal."
  elseif ratio >= need * 0.85 then note = "Close. They want a little more."
  elseif ratio >= need * 0.6 then note = "Not enough for them."
  else note = "They hung up." end
  return ratio >= need, ratio / need, note
end

--- An AI club's call: one of your spare parts (a bench bat, a spare arm, a farm prospect) for one of
--- theirs who'd beat your weakest of his kind, priced so their side says yes. Returns give, get or nil.
function R.aiOffer(L, T, other)
  local regular = {}
  for _, id in ipairs(T.order or {}) do regular[id] = true end
  for _, id in ipairs(T.rot or {}) do regular[id] = true end
  for id, role in pairs(T.pen or {}) do if role == "CL" then regular[id] = true end end
  local spare = {}
  for _, list in ipairs({ T.ml, T.farm }) do
    for _, id in ipairs(list) do
      local p = P(L, id)
      if p and not p.inj and not regular[id] then spare[#spare + 1] = p end
    end
  end
  table.sort(spare, function(a, b) return R.value(a) > R.value(b) end)
  local weakest = { [true] = 99, [false] = 99 }
  for _, id in ipairs(T.ml) do
    local p = P(L, id)
    if p and not p.inj then local k = p.pos == "P" weakest[k] = math.min(weakest[k], PM.ovr(p)) end
  end
  local theirs = {}
  for _, id in ipairs(other.ml) do local q = P(L, id) if q and not q.inj then theirs[#theirs + 1] = q end end
  table.sort(theirs, function(a, b) return PM.ovr(a) > PM.ovr(b) end)
  -- (each club asks about a different one of your top four spare parts)
  local n = math.min(4, #spare)
  local off = n > 0 and ((other.abbr:byte(1) + other.abbr:byte(2) + (L.day // 7)) % n) or 0
  for k = 1, n do
    local want = spare[(k - 1 + off) % n + 1]
    for _, q in ipairs(theirs) do
      if PM.ovr(q) >= weakest[q.pos == "P"] + 3 then
        local ok = R.evaluate(L, T, other, { want.id }, { q.id })
        if ok then return want.id, q.id end
      end
    end
  end
  return nil
end

--- Execute a trade (lists of ids).
function R.trade(L, T, other, give, get)
  local function move(id, from, to)
    local p = P(L, id)
    local lvl = p.lvl or "ML"
    if not removeId(lvl == "F" and from.farm or from.ml, id) then removeId(from.ml, id) removeId(from.farm, id) end
    local list = (lvl == "F") and to.farm or to.ml
    list[#list + 1] = id
    p.team = to.abbr
    p.mood = math.max(-2, (p.mood or 0) - 1)
    if from.pen then from.pen[id] = nil end
    removeId(from.rot or {}, id)
  end
  for _, id in ipairs(give) do move(id, T, other) end
  for _, id in ipairs(get) do move(id, other, T) end
  T.order, other.order = nil, nil
  R.validate(L, T)
  R.aiMaintain(L, other)
  R.auto(L, other)
end
