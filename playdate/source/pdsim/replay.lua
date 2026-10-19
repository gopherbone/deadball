-- Plays a pdsim game in BallCast with no server and no BallCast changes: registers a local game
-- id that BallCast's K.get answers (detail, compact log, live polling, empty wire).
--
--   import "pdsim/pdsim"; import "pdsim/replay"
--   local id = PdsimReplay.register(g, spec)          -- g: pdsim game, spec: the table given to pdsim.new
--   App.push(BallCast.scene, { gameId = id })
--
-- While the game isn't done the replay reports status "live", so BallCast polls (every 5 s) and
-- folds in whatever the caller has stepped since. Call PdsimReplay.forget(id) when done with it.

PdsimReplay = PdsimReplay or { games = {}, n = 0 }
local R = PdsimReplay

local function people(spec)
  local out = {}
  for _, side in ipairs({ "home", "away" }) do
    local t = spec[side]
    for _, p in ipairs(t.players or {}) do
      out[p.id] = { id = p.id, name = p.name or p.id, face = p.face, teamAbbr = t.abbr or t.id, pos = p.pos }
    end
  end
  return out
end

local function teamInfo(t)
  return { id = t.id, abbr = t.abbr or t.id, city = t.city, name = t.teamName or t.name or t.abbr, level = "ML" }
end

local function route(path)
  local id, rest = path:match("^/games/(pdsim%-%d+)(.*)$")
  local e = id and R.games[id]
  if not e then return nil end
  local status = pdsim.done(e.g) and "final" or "live"
  if rest:find("^/wire") then return { lines = {} } end
  if rest:find("^/log") then
    local from = tonumber(rest:match("from=(%d+)")) or 0
    local data = { id = id, status = status, from = from, people = e.people, park = e.park }
    if rest:find("fmt=c") then
      data.logc = pdsim.logc(e.g, from)
      data.n = pdsim.eventCount(e.g) - from
      data.log = {}
    else
      local all = pdsim.log(e.g)
      local sl = {}
      for i = from + 1, #all do sl[#sl + 1] = all[i] end
      data.log = sl
    end
    return data
  end
  -- detail / ?lite=1
  local box = pdsim.box(e.g)
  return { id = id, status = status, home = teamInfo(e.spec.home), away = teamInfo(e.spec.away),
    score = { home = box.home.runs, away = box.away.runs } }
end

local function install()
  if R.installed or not BCKit then return end
  R.installed = true
  local K = BCKit
  local get = K.get
  K.get = function(path, cb, opts)
    local data = route(path)
    if data then
      playdate.timer.performAfterDelay(1, function() cb(nil, data) end)
      return
    end
    return get(path, cb, opts)
  end
end

--- Register a pdsim game for BallCast; returns the game id to push the scene with.
function R.register(g, spec)
  install()
  R.n = R.n + 1
  local id = "pdsim-" .. R.n
  local park = {}
  for k, v in pairs(spec.park or {}) do park[k] = v end
  park.id = park.id or ("park-" .. string.lower(spec.home.abbr or spec.home.id or "home"))
  park.name = park.name or "Ballpark"
  park.fences = park.fences or { 330, 375, 400, 375, 330 }
  park.walls = park.walls or { 10, 10, 10, 10, 10 }
  R.games[id] = { g = g, spec = spec, people = people(spec), park = park }
  return id
end

function R.forget(id) R.games[id] = nil end
