--[[ "On the wire": what happened while the days were simulated, as lines worth reading.
  Everything comes from real box scores, stats and state. Lines are ranked by usefulness,
  de-duplicated (the same insight about the same player waits days before it repeats), capped
  per day, and the important ones become sim stops (docs/ux/pennant P0-2).

  PWire.begin(L)            a fresh log (an Advance run)
  PWire.onGame(L, g, res)   after each finished game (PL.onApply)
  PWire.endDay(L, rep)      after the day closes: insights, the race, stops
  PWire.lines               { { text, mine, kind, score, day, jump } } in order
  PWire.stop                nil | { reason, jump }  (the Advance pauses on it)
  PWire.todo()              the end summary: up to 4 { text, jump } actions

  A jump is { screen = "training"|"lineup"|"staff"|"farm"|"card"|"box", id = ... }.
]]

PWire = PWire or {}
local W = PWire

local floor, max, min, abs = math.floor, math.max, math.min, math.abs
local function P(L, id) return L.players[id] end
local function nick(ab) local c = PennantClubs.byAbbr[ab] return c and c.name or ab end

W.PER_DAY = 4   -- insight lines a day (your game and the scores don't count)

function W.begin(L)
  W.lines = {}
  W.stop = nil
  W.todoList = {}
  W.games = {}
  W.dayStart = L.day
  W.magic0 = PL.magic(L, L.user) or PL.elimination(L, L.user)
  W.rank0 = PL.rank(L, L.user)
  L.wireSeen = L.wireSeen or {}
end

local function push(line)
  W.lines = W.lines or {}
  W.lines[#W.lines + 1] = line
end

--- seen: the same insight key waits `days` before it may repeat
local function fresh(L, key, days)
  local seen = L.wireSeen or {}
  L.wireSeen = seen
  local last = seen[key]
  if last and L.day - last < (days or 7) then return false end
  return true
end
local function mark(L, key) L.wireSeen[key] = L.day end

local function todo(text, jump, key)
  for _, t in ipairs(W.todoList) do if t.key == key then return end end
  W.todoList[#W.todoList + 1] = { text = text, jump = jump, key = key }
end

-- Per-player recent form (kept in memory; not part of the save) -----------------------------------
W.recent = W.recent or {}   -- [pid] = { h = {...last 10 games}, ab = {...}, qs = n }

local function form(id)
  local r = W.recent[id]
  if not r then r = { h = {}, ab = {}, qs = 0 } W.recent[id] = r end
  return r
end

--- After each finished game: recent form for everyone; lines for the user's game and big
--- moments elsewhere.
function W.onGame(L, g, res)
  for _, side in ipairs({ res.home, res.away }) do
    for id, ln in pairs(side.bat or {}) do
      local r = form(id)
      table.insert(r.h, 1, ln.h or 0)
      table.insert(r.ab, 1, ln.ab or 0)
      r.h[11], r.ab[11] = nil, nil
    end
    local sp = side.pitchOrder and side.pitchOrder[1]
    if sp then
      local ln = side.pitch[sp] or {}
      local r = form(sp)
      if (ln.outs or 0) >= 18 and (ln.er or 0) <= 3 then r.qs = (r.qs or 0) + 1 else r.qs = 0 end
    end
  end
  if not W.lines then return end
  local mine = g.h == L.user or g.a == L.user
  local hs, as = res.home.runs, res.away.runs
  local inn = res.innings or 9
  if mine then
    local home = g.h == L.user
    local me, them = home and hs or as, home and as or hs
    local opp = home and g.a or g.h
    local won = me > them
    local b = L.boxes[g.box]
    local tags = {}
    if inn > 9 then tags[#tags + 1] = inn .. " innings" end
    if them == 0 then tags[#tags + 1] = "shutout" end
    local mySide = home and res.home or res.away
    local oppSide = home and res.away or res.home
    if oppSide.hits <= 1 then tags[#tags + 1] = oppSide.hits == 0 and "NO-HITTER" or "one-hitter" end
    if mySide.hits <= 1 then tags[#tags + 1] = mySide.hits == 0 and "no-hit by them" or "one hit all game" end
    -- walk-off: the home side won it in its last at-bat
    local hl = res.home.line or {}
    if hs > as and (hl[inn] or 0) > 0 and inn >= 9 then tags[#tags + 1] = "walk-off" end
    local hero = b and PL.hero(L, b, L.user)
    local hp = hero and P(L, hero.id)
    local text = string.format("%s %d-%d %s %s%s", won and "W" or "L", me, them, home and "vs" or "at", nick(opp),
      #tags > 0 and (" (" .. table.concat(tags, ", ") .. ")") or "")
    if hp then text = text .. ". " .. hp.ln .. " " .. hero.text end
    push({ text = text, mine = true, kind = "game", score = 100, day = L.day, jump = { screen = "box", id = g.box } })
  else
    W.games[#W.games + 1] = string.format("%s %d %s %d%s", g.a, as, g.h, hs, inn > 9 and (" (" .. inn .. ")") or "")
    if res.home.hits == 0 or res.away.hits == 0 then
      local pitcher = res.home.hits == 0 and g.a or g.h
      push({ text = "NO-HITTER: the " .. nick(pitcher) .. " no-hit the " .. nick(pitcher == g.a and g.h or g.a) .. ".", kind = "league", score = 60, day = L.day })
    end
  end
end

-- Insights at the day's end --------------------------------------------------------------------------

local function insights(L, rep)
  local out = {}
  local T = L.teams[L.user]
  local function add(score, key, text, jump, days, isStop, todoText)
    if not fresh(L, key, days) then return end
    out[#out + 1] = { score = score, key = key, text = text, jump = jump, stop = isStop, todo = todoText }
  end
  -- injuries and returns (your club)
  for _, a in ipairs(rep.alerts or {}) do
    local p = a.kind == "inj" and P(L, a.id)
    if p and p.inj then
      local regular = false
      for _, id in ipairs(T.order or {}) do if id == p.id then regular = true end end
      for _, id in ipairs(T.rot or {}) do if id == p.id then regular = true end end
      add(regular and 95 or 60, "inj" .. p.id, string.format("INJURY: %s (%s), %s, out %d days.", PM.name(p), p.pos == "P" and (p.role or "P") or p.pos, p.inj.k, p.inj.d),
        { screen = "trainer", id = p.id }, 1, regular, regular and ("Fill in for " .. p.ln) or nil)
    end
  end
  -- hot and cold bats
  for _, id in ipairs(T.order or {}) do
    local p = P(L, id)
    local r = W.recent[id]
    if p and r then
      local h, ab = 0, 0
      for i = 1, min(5, #r.h) do h, ab = h + r.h[i], ab + r.ab[i] end
      if ab >= 16 and h / ab >= 0.45 then add(40 + h, "hot" .. id, string.format("%s is %d for his last %d.", p.ln, h, ab), { screen = "card", id = id }, 6) end
      if ab >= 15 and h <= 1 then add(45, "cold" .. id, string.format("%s is %d for his last %d. A day off?", p.ln, h, ab), { screen = "lineup" }, 6, false, "Rest " .. p.ln .. " (" .. h .. " for " .. ab .. ")") end
    end
  end
  -- starters on a roll
  for _, id in ipairs(T.rot or {}) do
    local p, r = P(L, id), W.recent[id]
    if p and r and (r.qs or 0) >= 3 then add(30 + r.qs * 3, "qs" .. id .. ":" .. r.qs, string.format("%s: %d straight quality starts.", p.ln, r.qs), { screen = "card", id = id }, 3) end
  end
  -- the team's form
  local last5 = 0
  for i = max(1, #T.l10 - 4), #T.l10 do last5 = last5 + (T.l10[i] or 0) end
  if #T.l10 >= 5 and last5 <= 1 then add(50, "slide", string.format("The %s have lost %d of 5.", nick(L.user), 5 - last5), nil, 4) end
  if #T.l10 >= 5 and last5 >= 5 then add(45, "roll", string.format("Five straight wins for the %s.", nick(L.user)), nil, 4) end
  -- workload: the bullpen and tired starters
  local penPitches, worst, wv = 0, nil, 0
  for id in pairs(T.pen or {}) do
    local p = P(L, id)
    if p and p.rp then
      local n = (p.rp[1] or 0) + (p.rp[2] or 0) + (p.rp[3] or 0)
      penPitches = penPitches + n
      if n > wv then worst, wv = p, n end
    end
  end
  if penPitches >= 150 and worst then
    add(55, "pen", string.format("The bullpen threw %d pitches in 3 days; %s (%d) should rest.", penPitches, worst.ln, wv), { screen = "staff" }, 3, false, "Rest " .. worst.ln .. " (" .. wv .. " pitches in 3 days)")
  end
  for _, id in ipairs(T.order or {}) do
    local p = P(L, id)
    if p and (p.fat or 0) >= 72 then add(50, "worn" .. id, string.format("%s is worn out (fatigue %d).", p.ln, floor(p.fat)), { screen = "lineup" }, 4, false, "Give " .. p.ln .. " a day off") end
    if p and p.cond == 1 then add(35, "awful" .. id, string.format("%s's condition is awful.", p.ln), { screen = "card", id = id }, 5) end
  end
  -- the next series: who starts against you (and with which hand)
  local ng, nd = PL.nextGame(L, L.user)
  if ng then
    local opp = ng.h == L.user and ng.a or ng.h
    local OT = L.teams[opp]
    local lefties = 0
    local n = #(OT.rot or {})
    for k = 0, 2 do
      local id = OT.rot and OT.rot[((OT.rotIdx or 1) - 1 + k) % max(1, n) + 1]
      local p = id and P(L, id)
      if p and p.throws == "L" then lefties = lefties + 1 end
    end
    if lefties >= 2 and nd and L.sched[nd] and (L.sched[nd].gi or 1) == 1 then
      add(48, "lefties" .. opp .. ":" .. nd, string.format("%d lefties likely start in the %s series.", lefties, nick(opp)), { screen = "lineup" }, 3, false, "Lineup vs LHP for the " .. nick(opp))
    end
  end
  -- the farm: someone is ready
  for _, id in ipairs(T.farm or {}) do
    local p = P(L, id)
    if p and not p.inj and PM.ovr(p) >= 50 then
      -- better than the worst big-leaguer at his kind of job?
      local worst = 99
      for _, mid in ipairs(T.ml) do
        local q = P(L, mid)
        if q and (q.pos == "P") == (p.pos == "P") then worst = min(worst, PM.ovr(q)) end
      end
      if PM.ovr(p) >= worst + 3 then
        add(52, "ready" .. id, string.format("READY: %s (%s, farm) is %d OVR; your weakest is %d.", PM.name(p), p.pos == "P" and (p.role or "P") or p.pos, PM.ovr(p), worst),
          { screen = "farm" }, 10, true, "Call up " .. p.ln)
      end
    end
  end
  -- training: a focus at its cap
  for _, id in ipairs(T.ml) do
    local p = P(L, id)
    local f = p and p.plan and p.plan.f
    local key = f == "pit" and "stf" or f
    if key and (p.plan.i or 2) > 0 and p.r[key] and p.cap[key] and p.r[key] >= p.cap[key] then
      add(38, "cap" .. id .. key, string.format("%s's %s is at his ceiling (%d). Train something else.", p.ln, (PM.LABEL[key] or key):lower(), floor(p.r[key])),
        { screen = "training", id = id }, 21, false, "Change " .. p.ln .. "'s training")
    end
  end
  -- mood: an upset regular
  for _, id in ipairs(T.ml) do
    local p = P(L, id)
    if p and (p.mood or 0) <= -2 and PM.ovr(p) >= 50 then
      -- (a stop at most once a fortnight; otherwise just a line)
      local stopNow = fresh(L, "upsetStop", 14)
      if stopNow then mark(L, "upsetStop") end
      add(50, "upset" .. id, string.format("%s is upset (%s).", p.ln, (p.sat or 0) >= 5 and "wants to play" or "a bad stretch"), { screen = "card", id = id }, 7, stopNow)
    end
  end
  -- milestones (season)
  for _, id in ipairs(T.ml) do
    local p = P(L, id)
    if p then
      local b, s = p.st.b, p.st.p
      for _, m in ipairs({ { b.hr, 10, "home runs" }, { b.h, 50, "hits" }, { s.w, 10, "wins" }, { s.sv, 10, "saves" }, { b.sb, 10, "steals" } }) do
        local v, step, what = m[1] or 0, m[2], m[3]
        if v > 0 and v % step == 0 then add(42, "ms" .. id .. what .. v, string.format("%s has %d %s.", p.ln, v, what), { screen = "card", id = id }, 30) end
      end
    end
  end
  return out
end

--- The race: magic number, a rival's result, the playoff line.
local function race(L)
  local out = {}
  if L.phase ~= "season" then return out end
  local r = PL.rank(L, L.user)
  local m = PL.magic(L, L.user)
  local e = PL.elimination(L, L.user)
  if m and m <= 0 and fresh(L, "clinch", 400) then
    mark(L, "clinch")
    L.clinchPage = { day = L.day }
    out[#out + 1] = { score = 99, text = string.format("CLINCHED: the %s are in the playoffs.", nick(L.user)), stop = true, mine = true, jump = { screen = "clinch" } }
  elseif e and e <= 0 and fresh(L, "elim", 400) then
    mark(L, "elim")
    out[#out + 1] = { score = 90, text = string.format("%s ELIMINATED. FANS REMIND EACH OTHER ABOUT NEXT YEAR.", nick(L.user):upper()), stop = true, mine = true }
  end
  local T = L.teams[L.user]
  local half = (T.w + T.l) * 2 >= PL.seasonGames(L)
  if half and (m or e) then
    local now = m or e
    if W.lastMagic and now ~= W.lastMagic then
      out[#out + 1] = { score = 70, text = string.format("%s number: %d%s.", m and "Magic" or "Elimination", now, W.lastMagic > now and (" (down " .. (W.lastMagic - now) .. ")") or "") }
    end
    W.lastMagic = now
  end
  if W.lastRank and r ~= W.lastRank then
    local up = r < W.lastRank
    local crossed = (W.lastRank > 4) ~= (r > 4)
    out[#out + 1] = { score = crossed and 85 or 55, mine = true, text = string.format("%s to %s place%s.", up and "Up" or "Down", PUI and PUI.ord(r) or r, crossed and (up and ", inside the playoff line" or ", below the playoff line") or "") }
  end
  W.lastRank = r
  if L.day == L.regDays then out[#out + 1] = { score = 99, text = "The last day of the regular season.", stop = true } end
  return out
end

--- After the day closes.
function W.endDay(L, rep)
  if not W.lines then return end
  -- the scores elsewhere, one light line
  if #W.games > 0 then push({ text = "Elsewhere: " .. table.concat(W.games, ", "), kind = "scores", score = 10, day = rep.day }) end
  W.games = {}
  local list = insights(L, rep)
  for _, x in ipairs(race(L)) do list[#list + 1] = x end
  table.sort(list, function(a, b) return a.score > b.score end)
  local n = 0
  for _, x in ipairs(list) do
    if n >= W.PER_DAY and not x.stop then break end
    n = n + 1
    if x.key then mark(L, x.key) end
    push({ text = x.text, mine = x.mine ~= false, kind = "insight", score = x.score, day = rep.day, jump = x.jump })
    if x.todo then todo(x.todo, x.jump, x.key) end
    if x.stop and not W.stop then W.stop = { reason = x.text, jump = x.jump } end
  end
  -- a club on the phone (a stop: the offer won't wait)
  local c = L.tradeCall
  if c and c.day == L.day and not c.wired then
    c.wired = true
    local give, get = P(L, c.give), P(L, c.get)
    if give and get then
      local txt = string.format("The %s GM is on the line: %s (%s, %d OVR) for your %s.", nick(c.from), PM.name(get), get.pos == "P" and (get.role or "P") or get.pos, PM.ovr(get), give.ln)
      push({ text = txt, mine = true, kind = "insight", score = 90, day = rep.day, jump = { screen = "call" } })
      if not W.stop then W.stop = { reason = txt, jump = { screen = "call" } } end
    end
  end
  local dl = PL.deadline(L) - L.day
  if L.phase == "season" and (dl == 7 or dl == 1) and fresh(L, "deadline" .. dl, 30) then
    mark(L, "deadline" .. dl)
    push({ text = dl == 1 and "The trade deadline is tomorrow." or "The trade deadline is a week away.", mine = true, kind = "insight", score = 60, day = rep.day, jump = { screen = "trades" } })
  end
  -- the week's training report is a stop of its own (it's the weekly beat)
  if L.weekRep and not L.weekRep.seen and not W.stop then W.stop = { reason = "The week's training report is in.", jump = { screen = "report" }, report = true } end
end

function W.todo()
  local out = {}
  local L = Pennant and Pennant.L
  if L and L.phase ~= "season" and L.phase ~= "playoffs" then return out end
  for i, t in ipairs(W.todoList or {}) do if i <= 4 then out[#out + 1] = t end end
  return out
end

PL.onApply = function(L, g, res) W.onGame(L, g, res) end
