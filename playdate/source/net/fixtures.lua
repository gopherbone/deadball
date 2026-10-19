-- Fixture mode: answers API paths from JSON files so the whole client works offline.
--
-- Lookup order for a fixture name N:
--   fixtures/N.json            (server agent's realistic fixtures)
--   fixtures_dev/N.json        (the shell's own dev fixtures, playdate/tools/make_dev_fixtures.py)
--   fixtures_dev/ballcast/N.json
-- Each route lists candidate names, most specific first. POSTs mutate an in-memory copy
-- so betting, commenting, recruiting etc. feel real during a session.

-- The build packs each dir into <dir>/pack.json (tools/assets/pack.py); Packs.json reads either.

import "ui/packs"
import "net/stress"   -- dev only: worst-case strings (stress.flag, Simulator)

Fixtures = Fixtures or {}

local DIRS <const> = { "fixtures/", "fixtures_dev/", "fixtures_dev/ballcast/" }

local db = {}        -- name -> decoded table (mutable session copy)
local MISSING <const> = {}

local function safe(s)
  return (tostring(s):gsub("[^%w%-_]", "_"))
end

-- The captured fixtures come from a 40-second game day (10 s of betting before the first of the
-- staggered first pitches, a few seconds apart). Offline, the day runs at the live length
-- instead (30 min: the first lock 4:30 after the fixtures load, the rest following at the live
-- spacing), so the clock, the status bar and Bobby's window behave like the real thing.
local FIX_DAY_S <const> = 1800
local FIX_BET_S <const> = 270     -- first pitch 4:30 after the fixtures load
local FIX_SCALE <const> = FIX_DAY_S // 40
local function retime(name, data)
  if name:find("^bonus") then
    -- odd jobs run on the game day: the captured 40 s board lasts a live-length day offline
    local function walk(t, depth)
      if depth > 5 then return end
      for k, v in pairs(t) do
        if type(v) == "table" then walk(v, depth + 1)
        elseif (k == "endsIn" or k == "claimUntilIn") and type(v) == "number" and v < 600 then t[k] = v * FIX_SCALE end
      end
    end
    walk(data, 0)
    return
  end
  if name == "clock" then
    data.msPerDay = FIX_DAY_S * 1000
    data.nextDayIn = FIX_BET_S + FIX_DAY_S * 3 // 4
    if data.nextPitchIn then data.nextPitchIn = FIX_BET_S end
  else
    -- every scheduled game anywhere in it (the slate, ops, open bets, schedules): the earliest
    -- pitches at FIX_BET_S, the others keep their (scaled) gaps
    local sched = {}
    local function walk(t, depth)
      if depth > 6 then return end
      if t.status == "scheduled" and t.firstPitchIn then sched[#sched + 1] = t end
      for _, v in pairs(t) do if type(v) == "table" then walk(v, depth + 1) end end
    end
    walk(data, 0)
    local min = nil
    for _, g in ipairs(sched) do if not min or g.firstPitchIn < min then min = g.firstPitchIn end end
    for _, g in ipairs(sched) do
      local fp = FIX_BET_S + (g.firstPitchIn - min) * FIX_SCALE
      if g.finalIn then g.finalIn = fp + (g.finalIn - g.firstPitchIn) * FIX_SCALE end
      g.firstPitchIn = fp
    end
  end
end

local function load(name)
  local hit = db[name]
  if hit == MISSING then return nil end
  if hit then return hit end
  for _, d in ipairs(DIRS) do
    local data = Packs.json(d .. name .. ".json")  -- loose or packed (ui/packs.lua)
    if data then
      retime(name, data)
      Stress.apply(name, data)
      db[name] = data
      return data
    end
  end
  db[name] = MISSING
  return nil
end

local function first(names)
  for _, n in ipairs(names) do
    local d = load(n)
    if d then return d, n end
  end
  return nil
end

local function splitQuery(path)
  local base, q = path:match("^([^?]*)%??(.*)$")
  local params = {}
  for k, v in (q or ""):gmatch("([^&=]+)=([^&]*)") do params[k] = v end
  return base, params
end

local function notFound(path)
  return { status = 404, code = "not_found", message = "No fixture for " .. path }
end

local function account()
  local me = load("me")
  return me and me.account
end

-- GET routes: pattern -> function(captures..., params) returning candidate names
local GET = {
  { "^/clock$", function() return { "clock" } end },
  { "^/me$", function() return { "me" } end },
  { "^/digest$", function() return { "digest" } end },
  { "^/today$", function() return { "today" } end },
  { "^/games/([^/]+)/log$", function(id, p)
    -- ?fmt=c: the compact replay log (one string; BallCast parses it lazily)
    if p.fmt == "c" then return { "game-logc-" .. safe(id), "game-logc" } end
    return { "game-log-" .. safe(id), "games-" .. safe(id) .. "-log", "game-log" }
  end },
  { "^/games/([^/]+)/wire$", function(id) return { "wire-" .. safe(id), "games-" .. safe(id) .. "-wire", "wire" } end },
  { "^/games/([^/]+)$", function(id, p)
    -- ?lite=1: BallCast's slim detail (no box score)
    if p.lite == "1" then return { "game-lite-" .. safe(id), "game-" .. safe(id), "games-" .. safe(id), "game-lite", "game" } end
    return { "game-" .. safe(id), "games-" .. safe(id), "game" }
  end },
  { "^/standings$", function(p) return { "standings-" .. (p.level or "ML"), "standings" } end },
  { "^/schedule$", function(p) return p.level and { "schedule-" .. p.level, "schedule" } or { "schedule" } end },
  { "^/bets$", function(p) return { "bets-" .. (p.status or "open"), "bets" } end },
  { "^/gossip$", function() return { "gossip" } end },
  { "^/props/bets$", function(p) return { "props-bets-" .. (p.status or "open"), "props-bets-open" } end },
  { "^/props$", function(p) return p.storyline and { "props-" .. safe(p.storyline), "props-storyline", "props" } or { "props" } end },
  { "^/news$", function(p) return p.cursor and { "news-" .. safe(p.cursor), "news-page2" } or { "news" } end },
  { "^/news/([^/]+)$", function(id) return { "story-" .. safe(id), "news-" .. safe(id), "story" } end },
  { "^/people/([^/]+)$", function(id) return { "person-" .. safe(id), "people-" .. safe(id), "person" } end },
  { "^/teams/([^/]+)$", function(id) return { "team-" .. safe(id), "teams-" .. safe(id), "team" } end },
  { "^/words$", function() return { "words" } end },
  { "^/threads/(.+)$", function(t) return { "thread-" .. safe(t), "threads-" .. safe(t), "thread" } end },
  { "^/crew/candidates$", function() return { "candidates", "crew-candidates" } end },
  { "^/crew$", function() return { "crew" } end, merge = { "crew-allies" } },
  { "^/ops/catalog$", function() return { "ops-catalog" } end },
  { "^/ops$", function() return { "ops" } end },
  { "^/mail$", function() return { "mail-props", "mail" } end },
  { "^/events$", function() return { "events" } end },
  { "^/shop$", function() return { "shop" } end },
  { "^/cards/([^/]+)$", function(id) return { "card-" .. safe(id), "cards-" .. safe(id), "card" } end },
  { "^/cards$", function(p) return p.cursor and { "cards-" .. safe(p.cursor) } or { "cards" } end },
  { "^/market$", function(p) return p.cursor and { "market-" .. safe(p.cursor) } or { "market" } end },
  { "^/syndicates/leaderboard$", function() return { "syndicate-leaderboard", "syndicates-leaderboard" } end },
  { "^/syndicate$", function() return { "syndicate" } end },
  { "^/watchlist$", function() return { "watchlist" } end },
  { "^/bulletins$", function() return { "bulletins" } end },
  { "^/bonus$", function() return { "bonus" } end },
}

local function routeGet(path)
  local base, params = splitQuery(path)
  -- a scheduled game's page: the captured game-<id> fixtures are all finals, so serve
  -- today's slate entry (a GameDetail before first pitch is just the SlateGame)
  local gid = base:match("^/games/([^/]+)$")
  if gid then
    local today = load("today")
    for _, g in ipairs(today and today.games or {}) do
      if g.id == gid and g.status == "scheduled" then
        local c = {}
        for k, v in pairs(g) do c[k] = v end
        c.incidents = c.incidents or {}
        return nil, c
      end
    end
  end
  for _, r in ipairs(GET) do
    local m = base:match(r[1])
    if m then
      local names
      if r[1]:find("%(") then
        names = r[2](m, params)
      else
        names = r[2](params)
      end
      local data = first(names)
      if data and r.merge then
        for _, mn in ipairs(r.merge) do
          local extra = load(mn)
          if extra then for k, v in pairs(extra) do if data[k] == nil then data[k] = v end end end
        end
      end
      if data then return nil, data end
      return notFound(path)
    end
  end
  return notFound(path)
end

-- Mutations ------------------------------------------------------------------------

local seq = 0
local function newId(prefix)
  seq += 1
  return prefix .. "dev" .. seq
end

local function err(status, code, message)
  return { status = status, code = code, message = message }
end

local BAD <const> = { "damn", "hell", "crap", "butt", "poop", "sex", "nazi", "fuck", "shit" }

local function fillTemplate(templateId, words)
  local w = load("words")
  local tpl
  for _, t in ipairs(w and w.templates or {}) do
    if t.id == templateId then tpl = t end
  end
  if not tpl then return nil end
  local i = 0
  local text = tpl.text:gsub("{(%w+)}", function()
    i += 1
    return words[i] or "___"
  end)
  return text
end

local function findComment(id)
  for name, data in pairs(db) do
    if data ~= MISSING then
      local lists = { data.comments, data.guestbook }
      for _, l in ipairs(lists) do
        for _, c in ipairs(l or {}) do
          if c.id == id then return c end
        end
      end
    end
  end
end

local function threadList(thread)
  local kind, id = thread:match("^(%w+):(.+)$")
  if kind == "story" then
    local d = first({ "story-" .. safe(id), "news-" .. safe(id) })
    if d then d.comments = d.comments or {} return d.comments end
  elseif kind == "person" then
    local d = first({ "person-" .. safe(id), "people-" .. safe(id) })
    if d then d.guestbook = d.guestbook or {} return d.guestbook end
  end
  local name = "thread-" .. safe(thread)
  local d = load(name)
  if not d then
    db[name] = { comments = {} }
    d = db[name]
  end
  d.comments = d.comments or {}
  return d.comments
end

-- Odd jobs offline: the session copy of /bonus moves when you do the things it asks.
local function bonusJobs(b)
  local out = {}
  for _, k in ipairs({ "leftovers", "jobs" }) do for _, j in ipairs(b[k] or {}) do out[#out + 1] = j end end
  if b.week then out[#out + 1] = b.week end
  return out
end

local function bonusClaimable(b)
  local n = 0
  local left = b.pettyCash and b.pettyCash.left or 0
  for _, j in ipairs(bonusJobs(b)) do if j.status == "done" and (j.weekly or left > 0) then n += 1 end end
  b.claimable = n
end

--- Something the odd jobs count happened: kinds = { "bet", ... } (any matching open job moves).
local function bonusProgress(kinds, n)
  local b = load("bonus")
  if not b then return end
  for _, j in ipairs(bonusJobs(b)) do
    for _, k in ipairs(kinds) do
      if j.kind == k and j.status == "open" then
        j.have = math.min(j.need or 1, (j.have or 0) + (n or 1))
        if j.have >= (j.need or 1) then j.status = "done" end
      end
    end
  end
  bonusClaimable(b)
end
Fixtures.bonusProgress = bonusProgress

local function withBonus(out)
  local b = load("bonus")
  if b then for k, v in pairs(b) do if out[k] == nil then out[k] = v end end end
  return out
end

local POST = {
  { "^/bonus/punch$", function()
    local b = load("bonus")
    if not (b and b.card) then return err(404, "not_found", "no bonus fixture") end
    local card = b.card
    local acct = account()
    if card.punchedToday then
      return nil, withBonus({ punched = false, hole = card.hole, line = "Already punched today. Bobby remembers faces.", account = acct })
    end
    local hole = card.lapsed and 1 or ((card.hole or 0) % #card.holes + 1)
    if hole == 1 then for _, h in ipairs(card.holes) do h.stamped = false h.today = nil end end
    local h = card.holes[hole]
    h.stamped, h.today = true, true
    card.hole, card.punchedToday, card.lapsed = hole, true, nil
    card.streak = (card.streak or 0) + 1
    card.total = (card.total or 0) + 1
    if card.streak > (card.best or 0) then card.best = card.streak end
    if acct then acct.money += h.cash or 0 end
    local fx = load("bonus-punch")
    local line = (h.packs or 0) > 0 and "Full card! Bobby slid a free pack across the counter. Pick it up at the Card Shop."
      or (fx and fx.line) or "Bobby punched your card without looking up."
    return nil, withBonus({ punched = true, hole = hole, streak = card.streak, reward = { cash = h.cash or 0, packs = h.packs or 0, label = h.reward }, line = line, account = acct })
  end },
  { "^/bonus/jobs/(.+)/claim$", function(body, id)
    local b = load("bonus")
    local acct = account()
    for _, j in ipairs(b and bonusJobs(b) or {}) do
      if j.id == id then
        if j.status == "claimed" then return nil, withBonus({ claimed = true, again = true, job = j, line = "Already paid. Bobby doesn't pay twice.", account = acct }) end
        if j.status ~= "done" then return err(400, "bad_request", "not done yet (" .. (j.have or 0) .. "/" .. (j.need or 1) .. ")") end
        local pc = b.pettyCash or {}
        if not j.weekly then
          if (pc.left or 0) <= 0 then return err(429, "rate_limited", "Bobby's petty-cash drawer is empty until midnight (UTC).") end
          pc.left -= 1
        end
        j.status = "claimed"
        local r = j.reward or {}
        if acct then
          acct.money += r.cash or 0
          acct.heat = math.max(0, (acct.heat or 0) - (r.heat or 0))
        end
        bonusClaimable(b)
        local claimFx = load("bonus-claim")
        local line = (r.heat or 0) > 0 and "Bobby made a phone call downtown. Somebody lost a file."
          or ((r.packs or 0) > 0 and "Bobby threw in a pack. It's at the Card Shop, under your name.")
          or (claimFx and claimFx.line) or "Bobby paid you from a cigar box marked PETTY."
        return nil, withBonus({ claimed = true, job = j, line = line, account = acct })
      end
    end
    return err(404, "not_found", "no such job on your board")
  end },
  { "^/bonus/report$", function(body)
    local kind = body.kind
    if kind ~= "replay" and kind ~= "read" then return err(400, "bad_request", "kind must be one of replay, read") end
    bonusProgress({ kind })
    return nil, withBonus({ marked = true })
  end },
  { "^/register$", function(body)
    local name = tostring(body.name or "")
    if #name < 3 or #name > 16 or name:find("[^%w_%-%. ]") then
      return err(400, "name_rejected", "Names are 3-16 letters, numbers, dots, dashes or underscores.")
    end
    local low = name:lower()
    for _, b in ipairs(BAD) do
      if low:find(b, 1, true) then return err(400, "name_rejected", "The League's Decency Board rejected \"" .. name .. "\".") end
    end
    if low == "bobby" or low == "kessler_fan69" or low == "lampgirl" then
      return err(409, "name_taken", "Somebody already goes by \"" .. name .. "\".")
    end
    local reg = load("register") or { token = "dev-token", account = { id = "a1", money = 1000, heat = 0, crewSize = 0, unreadMail = 1, cards = 0, joinedDay = 1, rank = "Rube" } }
    local acct = account()
    if acct then
      for k, v in pairs(reg.account) do acct[k] = v end
      acct.name = name
    end
    return nil, { token = reg.token, account = acct or reg.account }
  end },
  { "^/bets$", function(body)
    local acct = account()
    local amt = math.floor(tonumber(body.amount) or 0)
    if amt < 5 then return err(400, "bad_request", "Minimum bet is $5.") end
    if acct and amt > acct.money * 0.5 then return err(400, "insufficient_funds", "Bobby caps you at half your bankroll.") end
    local today = load("today")
    local game
    for _, g in ipairs(today and today.games or {}) do if g.id == body.gameId then game = g end end
    if not game then return err(404, "not_found", "No such game") end
    if game.status ~= "scheduled" then return err(400, "window_closed", "Betting closed at first pitch.") end
    acct.money -= amt
    local pool = game.pool
    pool[body.side] = (pool[body.side] or 0) + amt
    local tot = (pool.home + pool.away) * 0.9
    pool.pays = { home = math.floor(tot / math.max(1, pool.home) * 100) / 100, away = math.floor(tot / math.max(1, pool.away) * 100) / 100 }
    local prev = game.myBet
    game.myBet = { side = body.side, amount = (prev and prev.side == body.side and prev.amount or 0) + amt }
    local bets = load("bets-open") or { bets = {} }
    db["bets-open"] = bets
    local bet = { id = newId("b"), gameId = game.id, side = body.side, amount = amt, placedAt = Api.now(), status = "open", game = game,
      label = (body.side == "home" and game.home.abbr or game.away.abbr) .. " to win", pays = pool.pays[body.side] }
    table.insert(bets.bets, 1, bet)
    bonusProgress({ "bet", "bet3", "w_bets" })
    local other = body.side == "home" and "away" or "home"
    if (pool.pays[body.side] or 0) > (pool.pays[other] or 0) then bonusProgress({ "underdog" }) end
    return nil, { bet = bet, pool = pool, account = acct }
  end },
  { "^/props/bets$", function(body)
    local acct = account()
    local amt = math.floor(tonumber(body.amount) or 0)
    if amt < 5 then return err(400, "bad_request", "amount must be between 5 and 10000000") end
    if acct and amt * 2 > acct.money then return err(400, "bad_request", "max bet is 50% of your money") end
    -- every loaded copy of the question (gossip page doc, props list) moves together
    local copies = {}
    for _, name in ipairs({ "gossip", "props", "props-storyline" }) do
      local d = load(name)
      for _, s in ipairs(d and d.storylines or {}) do
        for _, p in ipairs(s.props or {}) do
          if p.id == body.propId then copies[#copies + 1] = { s = s, p = p } end
        end
      end
    end
    local first = copies[1]
    if not first then return err(404, "not_found", "no such prop") end
    if first.p.status ~= "open" then return err(409, "window_closed", "Bobby closed the book on that one") end
    if first.p.myBet and first.p.myBet.option ~= body.option then return err(400, "bad_request", "you already took another answer on this one") end
    local optLabel
    for _, o in ipairs(first.p.options) do if o.key == body.option then optLabel = o.label end end
    if not optLabel then return err(400, "bad_request", "no such option") end
    for _, c in ipairs(copies) do
      local p = c.p
      p.pool = (p.pool or 0) + amt
      for _, o in ipairs(p.options) do
        if o.key == body.option then o.pool = (o.pool or 0) + amt end
      end
      for _, o in ipairs(p.options) do
        o.pays = (o.pool or 0) > 0 and math.floor(p.pool * 0.9 * 100 / o.pool) / 100 or 0
      end
      p.myBet = { option = body.option, amount = ((p.myBet and p.myBet.amount) or 0) + amt }
    end
    if acct then acct.money -= amt end
    local p = first.p
    local pays
    for _, o in ipairs(p.options) do if o.key == body.option then pays = o.pays end end
    local bet = { id = newId("pb"), propId = p.id, storylineId = first.s.id, headline = first.s.headline, question = p.question,
      option = body.option, optionLabel = optLabel, amount = p.myBet.amount, status = "open", placedAt = Api.now(), pays = pays }
    for _, name in ipairs({ "gossip", "props-bets-open" }) do
      local d = load(name) or { bets = {} }
      db[name] = d
      local list = name == "gossip" and (function() d.my = d.my or {} return d.my end)() or d.bets
      for i = #list, 1, -1 do if list[i].propId == p.id then table.remove(list, i) end end
      table.insert(list, 1, bet)
    end
    bonusProgress({ "prop", "w_props" })
    return nil, { bet = bet, prop = p, account = acct }
  end },
  { "^/comments$", function(body)
    local text = fillTemplate(body.template, body.words or {})
    if not text then return err(400, "invalid_comment", "Unknown template.") end
    local acct = account()
    local c = { id = newId("c"), author = acct and acct.name or "you", authorRank = acct and acct.rank or "Rube", text = text, at = Api.now(), reactions = { agree = 0, lol = 0, rat = 0 } }
    local list = threadList(body.thread or "misc")
    table.insert(list, 1, c)
    local th = tostring(body.thread or "")
    bonusProgress({ th:find("^story:") and "story" or (th:find("^bbs:") and "bbs" or (th:find("^person:") and "guestbook" or "-")), "w_posts" })
    return nil, { comment = c }
  end },
  { "^/comments/([^/]+)/react$", function(body, id)
    local c = findComment(id)
    if not c then return err(404, "not_found", "No such comment") end
    local k = body.kind
    if k ~= "agree" and k ~= "lol" and k ~= "rat" then return err(400, "bad_request", "bad kind") end
    c.reactions[k] = (c.reactions[k] or 0) + 1
    bonusProgress({ "react" })
    return nil, { comment = c }
  end },
  { "^/crew/recruit$", function(body)
    local cands = load("candidates")
    local crew = load("crew")
    local acct = account()
    if not (cands and crew) then return err(404, "not_found", "no crew fixtures") end
    if #crew.crew >= (crew.max or 6) then return err(400, "bad_request", "Your crew is full.") end
    for i, c in ipairs(cands.candidates) do
      if c.id == body.candidateId then
        local cost = c.cost or 0
        if acct and acct.money < cost then return err(400, "insufficient_funds", "You can't afford their fee.") end
        if acct then acct.money -= cost; acct.crewSize += 1 end
        table.remove(cands.candidates, i)
        crew.crew[#crew.crew + 1] = { id = newId("cr"), person = c.person, role = c.role, skills = c.skills, loyalty = c.loyalty, status = "ok", note = "New in town." }
        return nil, { crew = crew.crew, account = acct }
      end
    end
    return err(404, "not_found", "That candidate left town.")
  end },
  { "^/crew/([^/]+)/dismiss$", function(body, id)
    local crew = load("crew")
    for i, c in ipairs(crew and crew.crew or {}) do
      if c.id == id then table.remove(crew.crew, i) break end
    end
    local acct = account()
    if acct then acct.crewSize = #crew.crew end
    return nil, { crew = crew.crew }
  end },
  { "^/ops$", function(body)
    local cat = load("ops-catalog")
    local acct = account()
    local kind
    for _, k in ipairs(cat and cat.kinds or {}) do if k.kind == body.kind then kind = k end end
    if not kind then return err(400, "bad_request", "Unknown operation") end
    if kind.blocked and (body.gameId or "") ~= "" then return err(403, "forbidden", kind.blocked) end
    local cost = kind.cost
    for _, gid in ipairs(body.gear or {}) do
      for _, g in ipairs(kind.gear) do if g.id == gid then cost += g.cost end end
    end
    if acct and acct.money < cost then return err(400, "insufficient_funds", "The crew wants cash up front.") end
    if acct then acct.money -= cost; acct.heat += 1 end
    local today = load("today")
    local game
    for _, g in ipairs(today and today.games or {}) do if g.id == body.gameId then game = g end end
    local target
    for _, t in ipairs(cat.targets or {}) do if t.id == body.targetTeamId then target = t end end
    local crewRefs = {}
    local crew = load("crew")
    local syn = load("syndicate")
    local pools = { crew and crew.crew or {}, crew and crew.allies or {}, syn and syn.syndicate and syn.syndicate.allyCrew or {} }
    local allies, seen = {}, {}
    for _, cid in ipairs(body.crew or {}) do
      for _, pool in ipairs(pools) do
        for _, c in ipairs(pool) do
          if c.id == cid then
            crewRefs[#crewRefs + 1] = c.person
            if c.owner and not seen[c.owner] then seen[c.owner] = true allies[#allies + 1] = c.owner end
          end
        end
      end
    end
    local op = { id = newId("op"), kind = kind.kind, name = kind.name, game = game, target = target, crew = crewRefs, status = "planned" }
    -- chip in: each ally on the job is asked for an even share of the job (the orderer keeps the gear)
    if body.chipIn and #allies > 0 then
      local share = math.floor(kind.cost / (#allies + 1))
      local shares, parts = {}, {}
      for i, a in ipairs(allies) do
        shares[i] = { name = a, amount = share, status = "proposed" }
        parts[i] = a .. " asked $" .. share
      end
      op.chipIn = { total = cost, yours = cost, shares = shares, line = "Chip-in: " .. table.concat(parts, ", ") .. ". You: $" .. cost .. "." }
    end
    local ops = load("ops") or { ops = {} }
    db["ops"] = ops
    table.insert(ops.ops, 1, op)
    bonusProgress({ "job" })
    return nil, { op = op, account = acct }
  end },
  { "^/ops/([^/]+)/chipin$", function(body, id)
    local syn = load("syndicate")
    local acct = account()
    for i, ch in ipairs(syn and syn.chipIns or {}) do
      if ch.opId == id then
        if body.accept then
          if acct and acct.money < ch.share then return err(400, "insufficient_funds", "Your share is $" .. ch.share .. ".") end
          if acct then acct.money -= ch.share end
        end
        table.remove(syn.chipIns, i)
        ch.status = body.accept and "paid" or "declined"
        return nil, { result = body.accept and ("You chipped in $" .. ch.share .. " on \"" .. ch.job .. "\".") or ("You pass. " .. ch.from .. " pays for \"" .. ch.job .. "\"."), chipIn = ch, account = acct }
      end
    end
    return err(404, "not_found", "Nobody asked you to chip in on that.")
  end },
  { "^/mail/([^/]+)/read$", function(body, id)
    local mail = load("mail")
    local acct = account()
    for _, m in ipairs(mail and mail.mail or {}) do
      if m.id == id and not m.read then
        m.read = true
        if acct and acct.unreadMail > 0 then acct.unreadMail -= 1 end
      end
    end
    return nil, { ok = true }
  end },
  { "^/events/([^/]+)/choose$", function(body, id)
    local ev = load("events")
    local acct = account()
    for i, e in ipairs(ev and ev.events or {}) do
      if e.id == id then
        local choice
        for _, c in ipairs(e.choices) do if c.key == body.key then choice = c end end
        if not choice then return err(400, "bad_request", "No such choice") end
        if choice.cost and acct then
          if acct.money < choice.cost then return err(400, "insufficient_funds", "You can't cover that.") end
          acct.money -= choice.cost
        end
        table.remove(ev.events, i)
        local results = {
          "Done. Word gets around.",
          "It's handled. For now.",
          "Consider it taken care of. Nobody saw nothing.",
        }
        if acct and choice.note and choice.note:find("HEAT") then acct.heat += 2 end
        if body.key == "accept" and (e.body or ""):find("syndicate") then
          local syn = load("syndicate")
          if syn then syn.syndicate = nil end
          for _, r in ipairs(Fixtures.POST) do
            if r[1] == "^/syndicate/invites/([^/]+)/accept$" then r[2]({}, "card") end
          end
          return nil, { result = "You're in. Shared crews, shared treasury, shared bail.", account = acct }
        end
        return nil, { result = results[math.random(#results)], account = acct }
      end
    end
    return err(404, "not_found", "That decision expired.")
  end },
  { "^/packs/buy$", function(body)
    local shop = load("shop")
    local acct = account()
    local price = 0
    for _, p in ipairs(shop and shop.packs or {}) do if p.kind == body.kind then price = p.price end end
    if acct and acct.money < price then return err(400, "insufficient_funds", "Not enough cash for that pack.") end
    if acct then acct.money -= price end
    if price > 0 then bonusProgress({ "pack" }) end
    local opened = load("pack-open") or load("cards") or { cards = {} }
    return nil, { cards = opened.cards, account = acct }
  end },
  { "^/market/([^/]+)/buy$", function(body, id)
    local m = load("market")
    local acct = account()
    for i, l in ipairs(m and m.listings or {}) do
      if l.id == id then
        if acct and acct.money < l.price then return err(400, "insufficient_funds", "You can't afford it.") end
        if acct then acct.money -= l.price end
        table.remove(m.listings, i)
        return nil, { card = l.card, account = acct }
      end
    end
    return err(404, "not_found", "Listing gone.")
  end },
  { "^/market$", function(body)
    local m = load("market") or { listings = {} }
    db["market"] = m
    local acct = account()
    local l = { id = newId("l"), card = { id = body.cardId }, price = body.price, seller = acct and acct.name or "you", at = Api.now() }
    table.insert(m.listings, 1, l)
    bonusProgress({ "market" })
    return nil, { listing = l }
  end },
  -- Syndicates
  { "^/syndicate$", function(body)
    local syn = load("syndicate") or {}
    db["syndicate"] = syn
    if syn.syndicate then return err(400, "bad_request", "You're already in a syndicate.") end
    local name = tostring(body.name or "")
    if #name < 3 then return err(400, "name_rejected", "Syndicate names need 3+ characters.") end
    local acct = account()
    syn.syndicate = { id = newId("syn"), name = name, founder = acct and acct.name or "you", treasury = 0, max = 4,
      members = { { name = acct and acct.name or "you", rank = acct and acct.rank or "Rube", money = acct and acct.money or 0, heat = acct and acct.heat or 0, crewSize = acct and acct.crewSize or 0, founder = true } } }
    syn.syndicate.board = "bbs:syn:" .. syn.syndicate.id
    return nil, { syndicate = syn.syndicate, account = acct }
  end },
  { "^/syndicate/invite$", function(body)
    local name = tostring(body.accountName or body.name or "")
    if #name < 3 then return err(400, "bad_request", "Who?") end
    if name:lower() == "nobody" then return err(404, "not_found", "No account named \"" .. name .. "\".") end
    local syn = load("syndicate")
    if not (syn and syn.syndicate) then return err(400, "bad_request", "Start a syndicate first.") end
    if #syn.syndicate.members >= (syn.syndicate.max or 4) then
      return err(400, "bad_request", "Syndicates max out at 4 members.")
    end
    return nil, { invite = { id = newId("inv"), to = name, syndicate = syn.syndicate.name, at = Api.now() } }
  end },
  { "^/syndicate/invites/([^/]+)/accept$", function(body, id)
    local syn = load("syndicate") or {}
    db["syndicate"] = syn
    local inv
    for _, i in ipairs(syn.invites or {}) do if i.id == id then inv = i end end
    syn.invites = {}
    local acct = account()
    syn.syndicate = { id = newId("syn"), name = inv and inv.syndicate or "The Corkers", founder = inv and inv.from or "bobbys_cousin", treasury = 800, max = 4,
      members = { { name = inv and inv.from or "bobbys_cousin", rank = "Made Man", money = 3100, heat = 5, crewSize = 3, founder = true },
                  { name = acct and acct.name or "you", rank = acct and acct.rank or "Rube", money = acct and acct.money or 0, heat = acct and acct.heat or 0, crewSize = acct and acct.crewSize or 0, founder = false } } }
    syn.syndicate.board = "bbs:syn:" .. syn.syndicate.id
    return nil, { result = "Welcome to " .. syn.syndicate.name .. ".", syndicate = syn.syndicate, account = acct }
  end },
  { "^/syndicate/leave$", function(body)
    local syn = load("syndicate")
    if syn then syn.syndicate = nil end
    return nil, { account = account() }
  end },
  { "^/syndicate/treasury$", function(body)
    local syn = load("syndicate")
    local acct = account()
    local amt = math.floor(tonumber(body.amount) or 0)
    if not (syn and syn.syndicate) then return err(400, "bad_request", "You're not in a syndicate.") end
    if amt < 0 and acct and syn.syndicate.founder ~= acct.name then return err(403, "forbidden", "Only the founder can withdraw.") end
    if amt > 0 and acct and acct.money < amt then return err(400, "insufficient_funds", "You don't have that much.") end
    if amt < 0 and syn.syndicate.treasury < -amt then return err(400, "insufficient_funds", "The treasury is short.") end
    if acct then acct.money -= amt end
    syn.syndicate.treasury += amt
    for _, m in ipairs(syn.syndicate.members or {}) do if acct and m.name == acct.name then m.money = acct.money end end
    return nil, { syndicate = syn.syndicate, account = acct }
  end },
}

Fixtures.POST = POST

local DELETE = {
  { "^/ops/([^/]+)$", function(id)
    local ops = load("ops")
    local acct = account()
    for _, op in ipairs(ops and ops.ops or {}) do
      if op.id == id then
        if op.status ~= "planned" then return err(400, "bad_request", "That job is already " .. tostring(op.status) .. ".") end
        op.status = "cancelled"
        op.result = "Called off. Everyone was refunded."
        if acct then acct.money += (op.chipIn and op.chipIn.yours) or 0 end
        return nil, { op = op, account = acct }
      end
    end
    return err(404, "not_found", "No such job.")
  end },
  { "^/market/([^/]+)$", function(id)
    local m = load("market")
    for i, l in ipairs(m and m.listings or {}) do if l.id == id then table.remove(m.listings, i) end end
    return nil, { ok = true }
  end },
}

--- Returns err, data for a request. Never throws.
function Fixtures.handle(method, path, body)
  local ok, e, d = pcall(function()
    if method == "GET" then return routeGet(path) end
    local base = splitQuery(path)
    local routes = method == "POST" and POST or DELETE
    for _, r in ipairs(routes) do
      local cap = base:match(r[1])
      if cap then
        if method == "POST" then
          if r[1]:find("%(") then return r[2](body or {}, cap) end
          return r[2](body or {})
        else
          return r[2](cap)
        end
      end
    end
    return err(404, "not_found", "No fixture route for " .. method .. " " .. path)
  end)
  if not ok then
    print("[fixtures] error: " .. tostring(e))
    return { code = "server_error", message = tostring(e) }
  end
  return e, d
end

--- For the tour / tests: direct synchronous read of a fixture.
function Fixtures.peek(path)
  local e, d = routeGet(path)
  return d
end
