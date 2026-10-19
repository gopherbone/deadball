--[[ Pennant save slots (playdate.datastore).

  Slot k is a set of datastore files:
    pennant-slots            index: { [k] = { team, year, date, w, l, rank, phase, gen, at } }
    pennant-s<k>-g<n>-m      the league without players (schedule, standings, history, news...)
    pennant-s<k>-g<n>-p<i>   players, 40 per file, each a positional array (PM.pack)
  Writes alternate between generation 0 and 1, and the index is written last, so a save that's
  cut off half way leaves the previous one intact. Saving is sliced: one file per frame
  (PSave.begin returns a job for PJobs), so autosave never stalls the UI.
]]

PSave = PSave or {}
local CHUNK <const> = 40
PSave.SLOTS = 3

local function ds() return playdate.datastore end

function PSave.index()
  local t = ds().read("pennant-slots")
  if type(t) ~= "table" then t = {} end
  -- json turns sparse integer keys into strings
  local out = {}
  for k, v in pairs(t) do out[tonumber(k) or k] = v end
  return out
end

local function writeIndex(idx)
  local t = {}
  for k, v in pairs(idx) do t[tostring(k)] = v end
  ds().write(t, "pennant-slots", false)
end

-- maps keyed by player id -> lists of pairs (JSON object keys are strings)
local function pairsOf(m)
  local t = {}
  for k, v in pairs(m or {}) do t[#t + 1] = { k, v } end
  return t
end
local function mapOf(t)
  local m = {}
  for _, kv in ipairs(t or {}) do m[kv[1]] = kv[2] end
  return m
end

local function metaOf(L)
  local m = {}
  for k, v in pairs(L) do
    if k ~= "players" and k ~= "teams" and k ~= "today" and k ~= "usedNames" and k ~= "usedFaces" then m[k] = v end
  end
  m.teams = {}
  for abbr, T in pairs(L.teams) do
    local t = {}
    for k, v in pairs(T) do t[k] = v end
    t.field = pairsOf(T.field)
    t.pen = pairsOf(T.pen)
    m.teams[abbr] = t
  end
  return m
end

--- Keep the box scores small: the user's last 12 games and the last two days of the rest.
function PSave.pruneBoxes(L)
  local mine = {}
  for k, b in pairs(L.boxes) do
    if b.h == L.user or b.a == L.user then mine[#mine + 1] = { k, b.d }
    elseif b.d < L.day - 2 then L.boxes[k] = nil end
  end
  table.sort(mine, function(a, b) return a[2] > b[2] end)
  for i = 13, #mine do L.boxes[mine[i][1]] = nil end
end

--- A sliced save job: step() writes one file per call, returns true when finished.
function PSave.begin(L, slot)
  PSave.pruneBoxes(L)
  local idx = PSave.index()
  local prev = idx[slot]
  local gen = prev and (1 - (prev.gen or 0)) or 0
  local base = "pennant-s" .. slot .. "-g" .. gen
  local ids = {}
  for id in pairs(L.players) do ids[#ids + 1] = id end
  table.sort(ids)
  local chunks = (#ids + CHUNK - 1) // CHUNK
  local i = 0
  local job = { done = false }
  function job.step()
    i = i + 1
    if i <= chunks then
      local arr = {}
      for j = (i - 1) * CHUNK + 1, math.min(#ids, i * CHUNK) do arr[#arr + 1] = PM.pack(L.players[ids[j]]) end
      ds().write(arr, base .. "-p" .. i, false)
      return false
    elseif i == chunks + 1 then
      local m = metaOf(L)
      m.nChunks = chunks
      ds().write(m, base .. "-m", false)
      return false
    else
      local T = L.teams[L.user]
      idx[slot] = { team = L.user, year = L.year, date = PL.date(L), w = T.w, l = T.l, rank = PL.rank(L, L.user),
        phase = L.phase, gen = gen, at = playdate.getSecondsSinceEpoch(), season = L.season }
      writeIndex(idx)
      job.done = true
      return true
    end
  end
  return job
end

--- Save now, all at once (quit / explicit save while a dialog is up).
function PSave.saveNow(L, slot)
  local j = PSave.begin(L, slot)
  while not j.step() do end
end

function PSave.load(slot)
  local idx = PSave.index()
  local e = idx[slot]
  if not e then return nil, "empty slot" end
  local base = "pennant-s" .. slot .. "-g" .. (e.gen or 0)
  local m = ds().read(base .. "-m")
  if type(m) ~= "table" then return nil, "save file missing" end
  local L = m
  L.players = {}
  for i = 1, m.nChunks or 0 do
    local arr = ds().read(base .. "-p" .. i)
    for _, a in ipairs(arr or {}) do
      local p = PM.unpack(a)
      L.players[p.id] = p
    end
  end
  for abbr, T in pairs(L.teams) do
    T.field = mapOf(T.field)
    T.pen = mapOf(T.pen)
    T.l10 = T.l10 or {}
  end
  -- boxes / settings defaults for older saves
  L.boxes = L.boxes or {}
  L.settings = L.settings or {}
  L.news = L.news or {}
  L.history = L.history or {}
  L.alerts = L.alerts or {}
  L.slot = slot
  return L
end

function PSave.delete(slot)
  local idx = PSave.index()
  local e = idx[slot]
  if e then
    for g = 0, 1 do
      local base = "pennant-s" .. slot .. "-g" .. g
      ds().delete(base .. "-m")
      for i = 1, 20 do ds().delete(base .. "-p" .. i) end
    end
  end
  idx[slot] = nil
  writeIndex(idx)
end
