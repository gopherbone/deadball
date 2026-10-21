--[[ Pennant save slots (playdate.datastore).

  Slot k is a set of datastore files:
    pennant-slots            index: { [k] = { team, year, date, w, l, rank, phase, gen, at } }
    pennant-s<k>-g<n>-m      the league without players (schedule, standings, history, news...)
    pennant-s<k>-g<n>-p      every player, each a positional array (PM.pack)
  (saves from the first version split players over -p1..-p9; still read)
  Writes alternate between generation 0 and 1, and the index is written last, so a save that's
  cut off half way leaves the previous one intact. Saving is sliced by time (PSave.begin returns
  a job for PJobs): encoding one player / schedule day / box at a time, then the text streamed to
  the files a few KB per call, so an autosave never stalls the UI.
]]

PSave = PSave or {}
PSave.SLOTS = 3
-- save format version: older slots are wiped cleanly (no migration; the season model changed)
PSave.VERSION = 2

local function ds() return playdate.datastore end

local function deleteFiles(slot)
  for g = 0, 1 do
    local base = "pennant-s" .. slot .. "-g" .. g
    ds().delete(base .. "-m")
    ds().delete(base .. "-p")
    for i = 1, 20 do ds().delete(base .. "-p" .. i) end
  end
end

function PSave.index()
  local t = ds().read("pennant-slots")
  if type(t) ~= "table" then t = {} end
  -- json turns sparse integer keys into strings
  local out, stale = {}, false
  for k, v in pairs(t) do
    local slot = tonumber(k) or k
    if type(v) == "table" and (v.v or 1) == PSave.VERSION then out[slot] = v
    else deleteFiles(slot) stale = true end
  end
  if stale then
    local w = {}
    for k, v in pairs(out) do w[tostring(k)] = v end
    ds().write(w, "pennant-slots", false)
    PSave.wiped = true
  end
  return out
end

local function writeIndex(idx)
  local t = {}
  for k, v in pairs(idx) do t[tostring(k)] = v end
  -- (the same file datastore.read reads; one small plain write is much quicker on the device)
  local f = playdate.file.open("pennant-slots.json", playdate.file.kFileWrite)
  if f then f:write(json.encode(t)) f:close() else ds().write(t, "pennant-slots", false) end
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
    if T.cards then
      t.cards = {}
      for side, c in pairs(T.cards) do
        -- the active card is T.order / T.field itself (written above)
        if side ~= T.cardSide then t.cards[side] = { order = c.order, field = pairsOf(c.field) } end
      end
    end
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

--- A sliced save job. step(ms) does at most ~ms of work: json.encode one player (or one
--- schedule day / box / team) at a time, then stream the text to the files a few KB per call.
--- The device spends ~10x the Simulator's time here, so nothing is done in one big piece.
function PSave.begin(L, slot)
  PSave.pruneBoxes(L)
  local idx = PSave.index()
  local prev = idx[slot]
  local gen = prev and (1 - (prev.gen or 0)) or 0
  local base = "pennant-s" .. slot .. "-g" .. gen
  local enc = json.encode
  local ids = {}
  for id in pairs(L.players) do ids[#ids + 1] = id end
  table.sort(ids)
  -- work list: { kind, ... } items that each produce one piece of text
  local m = metaOf(L)
  m.nChunks = nil
  m.pfile = 1
  local mparts = {}            -- { key, value, how } ; how: "arr" (element by element), "obj", "whole"
  for k, v in pairs(m) do
    local how = "whole"
    if type(v) == "table" and (k == "sched" or k == "news" or k == "history") then how = "arr"
    elseif type(v) == "table" and (k == "boxes" or k == "teams") then how = "obj" end
    mparts[#mparts + 1] = { k, v, how }
  end
  local pPieces, mPieces = { "[" }, { "{" }
  local phase, i, mi, inner, innerKeys = "players", 1, 1, nil, nil
  local writer
  local job = { done = false, slot = slot, what = "save" }
  local function now() return playdate.getCurrentTimeMilliseconds() end

  --- encode the next meta item (a whole value, or one element of a big one)
  local function metaStep()
    local part = mparts[mi]
    if not part then return true end
    local k, v, how = part[1], part[2], part[3]
    local key = enc(tostring(k)) .. ":"
    if how == "whole" then
      mPieces[#mPieces + 1] = (mi > 1 and "," or "") .. key .. enc(v)
      mi = mi + 1
    elseif not inner then
      mPieces[#mPieces + 1] = (mi > 1 and "," or "") .. key .. (how == "arr" and "[" or "{")
      inner = 1
      if how == "obj" then innerKeys = {} for kk in pairs(v) do innerKeys[#innerKeys + 1] = kk end end
    else
      local n = how == "arr" and #v or #innerKeys
      if inner > n then
        mPieces[#mPieces + 1] = how == "arr" and "]" or "}"
        inner, innerKeys = nil, nil
        mi = mi + 1
      elseif how == "arr" then
        mPieces[#mPieces + 1] = (inner > 1 and "," or "") .. enc(v[inner])
        inner = inner + 1
      else
        local kk = innerKeys[inner]
        mPieces[#mPieces + 1] = (inner > 1 and "," or "") .. enc(tostring(kk)) .. ":" .. enc(v[kk])
        inner = inner + 1
      end
    end
    return false
  end

  --- stream pieces into a file, ~6 KB per write
  local function openWriter(name, pieces)
    return { f = playdate.file.open(name .. ".json", playdate.file.kFileWrite), pieces = pieces, j = 1 }
  end
  local function writeSome(w)
    if not w.f then return true end
    local buf, n = {}, 0
    while w.j <= #w.pieces and n < 2000 do
      local s = w.pieces[w.j]
      buf[#buf + 1] = s
      n = n + #s
      w.pieces[w.j] = nil
      w.j = w.j + 1
    end
    if #buf > 0 then w.f:write(table.concat(buf)) end
    if w.j > #w.pieces then w.f:close() w.f = nil return true end
    return false
  end

  function job.phase() return phase end

  function job.cancel()
    if writer and writer.f then writer.f:close() writer.f = nil end
    job.done = true
  end

  function job.step(ms)
    local t0 = now()
    local budget = math.max(2, math.min(ms or 8, 12))
    repeat
      if phase == "players" then
        if i <= #ids then
          pPieces[#pPieces + 1] = (i > 1 and "," or "") .. enc(PM.pack(L.players[ids[i]]))
          i = i + 1
        else
          pPieces[#pPieces + 1] = "]"
          phase = "meta"
        end
      elseif phase == "meta" then
        if metaStep() then mPieces[#mPieces + 1] = "}" phase = "writeP" writer = openWriter(base .. "-p", pPieces) end
      elseif phase == "writeP" then
        if writeSome(writer) then phase = "writeM" writer = openWriter(base .. "-m", mPieces) end
        -- (one flash write per call: they're slow and uneven on the device)
        return false
      elseif phase == "writeM" then
        if writeSome(writer) then phase = "index" end
        return false
      else
        local T = L.teams[L.user]
        idx[slot] = { v = PSave.VERSION, team = L.user, year = L.year, date = PL.date(L, math.min(L.day, #L.sched)), w = T.w, l = T.l, rank = PL.rank(L, L.user),
          phase = L.phase, gen = gen, at = playdate.getSecondsSinceEpoch(), season = L.season, titles = PUI.titles and PUI.titles() or nil,
          run = L.run and L.run.n or nil, ended = (L.run and L.run.ended) or nil }
        writeIndex(idx)
        job.done = true
        return true
      end
    until now() - t0 >= budget
    return false
  end
  return job
end

--- Save now, all at once (quit / explicit save while a dialog is up).
function PSave.saveNow(L, slot)
  local j = PSave.begin(L, slot)
  while not j.step(1000) do end
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
  local files = {}
  if m.pfile then files[1] = base .. "-p" else for i = 1, m.nChunks or 0 do files[#files + 1] = base .. "-p" .. i end end
  for _, name in ipairs(files) do
    local arr = ds().read(name)
    for _, a in ipairs(arr or {}) do
      local p = PM.unpack(a)
      L.players[p.id] = p
    end
  end
  L.pfile, L.nChunks = nil, nil
  for abbr, T in pairs(L.teams) do
    T.field = mapOf(T.field)
    T.pen = mapOf(T.pen)
    if T.cards then
      for side, c in pairs(T.cards) do if c.field then c.field = mapOf(c.field) end end
      T.cards[T.cardSide or "R"] = { order = T.order, field = T.field }
    end
    T.l10 = T.l10 or {}
  end
  -- boxes / settings defaults for older saves
  L.boxes = L.boxes or {}
  L.settings = L.settings or {}
  L.news = L.news or {}
  L.history = L.history or {}
  L.alerts = L.alerts or {}
  L.slot = slot
  -- the week turn's club state (pennant/week.lua): defaults for saves from before it
  if PWeek then PWeek.ensure(L) end
  -- runs and the legacy layer (pennant/legacy.lua): a career from before runs becomes one
  if PLegacy then PLegacy.ensure(L) end
  return L
end

function PSave.delete(slot)
  local idx = PSave.index()
  local e = idx[slot]
  if e then deleteFiles(slot) end
  idx[slot] = nil
  writeIndex(idx)
end
