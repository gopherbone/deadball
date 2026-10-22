--[[ Rest the tired (PRest): the quick way to give worn-out players a day off. Pure Lua (no
  playdate APIs) so the self-test runs it headless.

  PRest.plan(L) lists who's tired today, each with the suggested cover:
    bat   a regular in today's lineup over PRest.TIRED (55: past it, fatigue costs him rating
          points, engine.lua form) -> the best rested bench bat at his position (R.posValue)
    sp    today's starter at PRest.SP_TIRED or more -> a spot start from the bullpen (the
          rotation doesn't turn: he's due again tomorrow)
    pen   a reliever at PRest.RP_TIRED or more -> he sits; a closer / setup man's role goes to
          the freshest middle man
  Each row: { k, id, sub, pos | role, d = the rating change (sub - him), rec = worth it, on }.
  PRest.apply(L, rows, mode) makes the swaps on today's card ("today": back tomorrow; "fresh":
  on both cards, back at PRest.FRESH). A rested player is saved in T.resting:
    { k = "bat", id, sub, pos, side, d0, s, m }  |  { k = "pen", id, sub, role, subRole, d0, s, m }
  PRest.daily(L) runs before the user's games (PL.todayCard): anyone due back is swapped back in,
  but only if the card still holds the swap as it was made (a lineup the user changed himself is
  his); with L.settings.autoRest the recommended swaps are made too, once a day. Resting players
  sit out the game (not on the bench / in the pen: PRest.sitSet).
]]

PRest = PRest or {}
local R = PRest

R.TIRED = 55      -- position players: over this, fatigue costs rating points (engine.lua form)
R.FRESH = 45      -- a rested regular is back at or under this
R.SP_TIRED = 35   -- today's starter
R.RP_TIRED = 60   -- relievers (the engine's own "ready" line)
R.RP_FRESH = 30

local floor = math.floor
local function P(L, id) return L.players[id] end
local function indexOf(list, x) for i, v in ipairs(list or {}) do if v == x then return i end end return nil end

--- A card's tables ({order, field}) for side "R"|"L" (the active tables when it's the active card).
local function card(T, side)
  if (T.cardSide or "R") == side and T.order then return { order = T.order, field = T.field } end
  local c = T.cards and T.cards[side]
  if c and c.order and c.field then return c end
  return nil
end
R.card = card

--- Today's card side (the opposing starter's hand; the active card on an off day).
function R.side(L)
  local T = L.teams[L.user]
  return PL.vsHand(L, L.user) or T.cardSide or "R"
end

--- ids resting right now (they sit out today's game).
function R.sitSet(L, T)
  local s = {}
  for _, e in ipairs(T.resting or {}) do s[e.id] = true end
  return s
end

function R.tired(p)
  if not p then return false end
  local f = p.fat or 0
  if p.pos == "P" then return f >= (p.role == "SP" and R.SP_TIRED or R.RP_TIRED) end
  return f > R.TIRED
end

--- The best rested bench bat for pos on card c (vs: the starter's hand), skipping `used`.
local function benchSub(L, T, c, pos, vs, used, sit)
  local inOrder = {}
  for _, id in ipairs(c.order) do inOrder[id] = true end
  local best, bv = nil, -1e9
  for _, q in ipairs(PRoster.hitters(L, T)) do
    if not inOrder[q.id] and not used[q.id] and not sit[q.id] and PRoster.healthy(q) and (q.fat or 0) <= R.TIRED then
      local v = PRoster.posValue(q, pos, vs)
      if v > bv then best, bv = q, v end
    end
  end
  return best, bv
end

local function penScore(q) return q.r.stf + q.r.ctl + q.r.velo * 0.5 end

--- Who's tired today and who'd cover. Returns rows (most tired first within each kind).
function R.plan(L)
  local T = L.teams[L.user]
  local rows = {}
  if not T or not T.order then return rows end
  local sit = R.sitSet(L, T)
  local side = R.side(L)
  local c = card(T, side) or { order = T.order, field = T.field }
  -- the lineup
  local tired = {}
  for slot, id in ipairs(c.order) do
    local p = P(L, id)
    if p and p.pos ~= "P" and R.tired(p) and PRoster.healthy(p) then tired[#tired + 1] = { p = p, slot = slot } end
  end
  table.sort(tired, function(a, b) return (a.p.fat or 0) > (b.p.fat or 0) end)
  local used = {}
  for _, t in ipairs(tired) do
    local p = t.p
    local pos = c.field[p.id] or "DH"
    local q, qv = benchSub(L, T, c, pos, side, used, sit)
    local row = { k = "bat", id = p.id, pos = pos, fat = p.fat or 0 }
    if q then
      used[q.id] = true
      row.sub = q.id
      local mine = PRoster.posValue(p, pos, side)
      row.d = floor(qv - mine + 0.5)
      -- worth it when the cover is within a few points (more the more tired he is: playing on, he
      -- only gets more tired)
      row.rec = row.d >= -(2 + ((p.fat or 0) - R.TIRED) * 0.6)
    end
    row.on = row.rec or false
    rows[#rows + 1] = row
  end
  -- today's starter
  if PL.gameFor(L, L.user) and T.rot and #T.rot > 0 then
    local sp = PRoster.starter(L, T)
    local p = sp and P(L, sp)
    if p and (p.fat or 0) >= R.SP_TIRED and not (T.spotSp and T.spotSp.day == L.day and T.spotSp.id == sp) then
      local best, bv = nil, -1e9
      for id, role in pairs(T.pen or {}) do
        local q = P(L, id)
        if q and role ~= "CL" and not sit[id] and PRoster.healthy(q) and (q.fat or 0) < 20 then
          local v = PM.ovr(q) + q.r.sta * 0.3
          if v > bv or (best and v == bv and id < best.id) then best, bv = q, v end
        end
      end
      local row = { k = "sp", id = p.id, pos = "SP", fat = p.fat or 0 }
      if best then
        row.sub = best.id
        row.d = PM.ovr(best) - PM.ovr(p)
        row.rec = (p.fat or 0) >= 45 or row.d >= -8
      end
      row.on = row.rec or false
      rows[#rows + 1] = row
    end
  end
  -- the bullpen
  local pens = {}
  for id, role in pairs(R.noPen and {} or T.pen or {}) do
    local q = P(L, id)
    if q and not sit[id] and PRoster.healthy(q) and (q.fat or 0) >= R.RP_TIRED then pens[#pens + 1] = { q = q, role = role } end
  end
  table.sort(pens, function(a, b) if (a.q.fat or 0) ~= (b.q.fat or 0) then return (a.q.fat or 0) > (b.q.fat or 0) end return a.q.id < b.q.id end)
  local taken = {}
  for _, e in ipairs(pens) do
    local row = { k = "pen", id = e.q.id, role = e.role, pos = e.role, fat = e.q.fat or 0, rec = true }
    if e.role == "CL" or e.role == "SU" then
      local best, bv = nil, -1e9
      for id, role in pairs(T.pen) do
        local q = P(L, id)
        if q and (role == "MR" or role == "LR") and not taken[id] and not sit[id] and PRoster.healthy(q) and (q.fat or 0) < R.RP_FRESH then
          local v = penScore(q)
          if v > bv or (best and v == bv and id < best.id) then best, bv = q, v end
        end
      end
      if best then
        taken[best.id] = true
        row.sub = best.id
        row.subRole = T.pen[best.id]
        row.d = PM.ovr(best) - PM.ovr(e.q)
      end
    end
    row.on = true
    rows[#rows + 1] = row
  end
  return rows
end

--- How many are tired today (the Week screen's chip, the pregame's button).
function R.count(L)
  if not (L.phase == "season" or L.phase == "playoffs") then return 0 end
  return #R.plan(L)
end

--- Swap one tired regular out of card c for sub. Returns true.
local function swapOut(T, c, id, sub)
  local slot = indexOf(c.order, id)
  if not slot or indexOf(c.order, sub) then return false end
  local pos = c.field[id] or "DH"
  c.order[slot] = sub
  c.field[sub] = pos
  c.field[id] = nil
  return true, pos
end

--- Make the swaps of the rows that are on. mode: "today" | "fresh". Returns how many rested.
function R.apply(L, rows, mode)
  local T = L.teams[L.user]
  T.resting = T.resting or {}
  local side = R.side(L)
  -- (today's card in play: built now if it never was)
  if PL.vsHand(L, L.user) then PRoster.useCard(L, T, side) end
  local n = 0
  for _, row in ipairs(rows) do
    local p = P(L, row.id)
    if row.on and p then
      if row.k == "bat" and row.sub then
        local c = card(T, side)
        local ok, pos = false, nil
        if c then ok, pos = swapOut(T, c, row.id, row.sub) end
        if ok then
          n = n + 1
          T.resting[#T.resting + 1] = { k = "bat", id = row.id, sub = row.sub, pos = pos, side = side, d0 = L.day, s = L.season, m = mode }
          -- until fresh: off the other card too (its own best cover)
          local other = side == "R" and "L" or "R"
          local oc = mode == "fresh" and card(T, other)
          if oc and indexOf(oc.order, row.id) then
            local opos = oc.field[row.id] or "DH"
            local q = benchSub(L, T, oc, opos, other, {}, R.sitSet(L, T))
            if q and swapOut(T, oc, row.id, q.id) then
              T.resting[#T.resting + 1] = { k = "bat", id = row.id, sub = q.id, pos = opos, side = other, d0 = L.day, s = L.season, m = mode }
            end
          end
        end
      elseif row.k == "sp" and row.sub then
        T.spotSp = { id = row.sub, day = L.day }
        n = n + 1
      elseif row.k == "pen" then
        local e = { k = "pen", id = row.id, role = row.role, d0 = L.day, s = L.season, m = mode }
        if row.sub and T.pen[row.sub] and T.pen[row.id] then
          e.sub, e.subRole = row.sub, T.pen[row.sub]
          T.pen[row.id], T.pen[row.sub] = e.subRole, row.role
        end
        T.resting[#T.resting + 1] = e
        n = n + 1
      end
    end
  end
  if n > 0 then
    local wk = L.club and L.club.wk
    if wk then wk.rested = (wk.rested or 0) + n end
    L.restedTotal = (L.restedTotal or 0) + n
  end
  return n
end

--- Anyone due back goes back in (when the card / the pen still holds the swap as it was made).
--- Returns how many came back.
function R.returns(L)
  local T = L.teams[L.user]
  if not T.resting then return 0 end
  local keep, back = {}, 0
  for _, e in ipairs(T.resting) do
    local p = P(L, e.id)
    local alive = p and p.team == L.user and p.lvl ~= "F" and e.s == L.season and (e.d0 or 0) <= L.day
    local due = alive and L.day > (e.d0 or 0) and (e.m == "today" or (p.fat or 0) <= (e.k == "pen" and R.RP_FRESH or R.FRESH))
    if not alive then
      -- (traded, sent down, a new season: the entry just goes)
    elseif e.k == "bat" then
      local c = card(T, e.side)
      local slot = c and indexOf(c.order, e.sub)
      local intact = slot and c.field[e.sub] == e.pos and not indexOf(c.order, e.id)
      if not intact then
        -- the user changed the card himself: it's his now
      elseif p.inj then
        -- hurt while resting: the cover stays
      elseif due then
        c.order[slot] = e.id
        c.field[e.id] = e.pos
        c.field[e.sub] = nil
        back = back + 1
      else
        keep[#keep + 1] = e
      end
    elseif e.k == "pen" then
      -- (gone from the pen, or the user moved the roles himself: he's not sitting any more)
      if T.pen and T.pen[e.id] and (not e.sub or T.pen[e.id] == e.subRole) then
        if due then
          if e.sub and T.pen[e.sub] == e.role and T.pen[e.id] == e.subRole then T.pen[e.id], T.pen[e.sub] = e.role, e.subRole end
          back = back + 1
        else
          keep[#keep + 1] = e
        end
      end
    end
  end
  T.resting = #keep > 0 and keep or nil
  return back
end

--- Before the user's games (PL.todayCard): returns, then the auto-rest (once a day, if on).
function R.daily(L)
  local T = L.teams[L.user]
  if T.spotSp and T.spotSp.day ~= L.day then T.spotSp = nil end
  R.returns(L)
  if L.settings and L.settings.autoRest and T.autoRestDay ~= L.day and PL.gameFor(L, L.user) then
    T.autoRestDay = L.day
    return R.apply(L, R.plan(L), "fresh")
  end
  return 0
end

--- One row as text: "RF Gallagher 72 > Huckaby -4" pieces for the UI.
function R.subText(L, row)
  local q = row.sub and P(L, row.sub)
  if row.k == "pen" then
    if q then return PM.short(q) .. " takes " .. row.role end
    return "sits today"
  elseif row.k == "sp" then
    if q then return "spot start: " .. PM.short(q) end
    return "nobody rested in the pen"
  end
  if q then return PM.short(q) end
  return "no rested cover"
end
