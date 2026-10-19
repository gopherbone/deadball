--[[
  net/diskcache.lua — the last good response per GET path, kept on the Playdate's disk, so a
  screen can paint immediately from the previous visit while the network (7-11 s of Wi-Fi /
  TLS setup per connection) catches up. Used by net/api.lua (Api.peek, writes after every
  successful GET) and ui/page.lua (stale-while-revalidate).

  - Scoped by host + account token: the index records a hash of both, and a different scope
    wipes the folder, so one account never sees another's cached mail or bets.
  - Stores the server's raw JSON (with its relative `fooIn` / `ago` fields) plus the device
    wall clock (playdate.getSecondsSinceEpoch, seconds since 2000: fits a 32-bit int) at
    save time. Readers rebase with `Api.now() - age` (see Api.peek), never epoch ms.
  - LRU-bounded (~300 KB total, 64 KB per item); replay logs/wire and ttl=0 GETs are skipped.
  - Writes are queued and done one per frame from Api.update (the device disk is slow).
]]

DiskCache = DiskCache or {}

local DIR <const> = "netcache/"
local INDEX <const> = DIR .. "index.json"
local MAX_TOTAL <const> = 300 * 1024
local MAX_ITEM <const> = 64 * 1024
local MAX_ITEMS <const> = 64

local index = nil       -- { scope = "...", seq = n, e = { [file] = { p = path, s = bytes, u = seq, t = savedSec } } }
local scope = nil
local pending = {}      -- ordered list of { path, raw, t }
local dirty = false
DiskCache.enabled = true

-- Small two-part hash; both halves stay far below 2^31 (Playdate Lua numbers are 32-bit).
local function hash(s)
  local a, b = 7, 11
  for i = 1, #s do
    local c = s:byte(i)
    a = (a * 31 + c) % 65521
    b = (b * 37 + c) % 65519
  end
  return string.format("%04x%04x", a, b)
end
DiskCache.hash = hash

local function nowSec()
  local s = playdate.getSecondsSinceEpoch()
  return s
end

local function fileFor(path) return hash(path) end

--- Whether a path's response belongs on disk (opts: the GET's ttl).
function DiskCache.accepts(path, ttl)
  if not DiskCache.enabled or not scope then return false end
  if ttl == 0 then return false end
  if path:find("^/games/[^/?]+/log") or path:find("^/games/[^/?]+/wire") then return false end
  if path:find("^/clock") or path:find("^/batch") then return false end
  return true
end

local function saveIndex()
  if not index then return end
  pcall(json.encodeToFile, INDEX, false, index)
  dirty = false
end

local function wipe()
  pcall(playdate.file.delete, DIR, true)
  playdate.file.mkdir(DIR)
  index = { scope = scope, seq = 0, e = {} }
  pending = {}
  saveIndex()
end

--- Selects the cache for a host + token (nil token / fixture mode disables it).
function DiskCache.setScope(key)
  if not key then
    scope = nil
    pending = {}
    return
  end
  local s = hash(key) .. hash(key:reverse())
  if s == scope and index then return end
  scope = s
  local ok, idx = pcall(json.decodeFile, INDEX)
  if ok and type(idx) == "table" and idx.scope == scope and type(idx.e) == "table" then
    index = idx
    index.seq = tonumber(index.seq) or 0
  else
    wipe()
  end
  pending = {}
end

function DiskCache.clear()
  if scope then wipe() end
end

--- Returns the cached decoded table for path and its age in seconds, or nil.
function DiskCache.get(path)
  if not scope or not index then return nil end
  -- a write still in the queue is the newest copy
  for i = #pending, 1, -1 do
    local p = pending[i]
    if p.path == path then
      local ok, d = pcall(json.decode, p.raw)
      if ok and type(d) == "table" then return d, math.max(0, nowSec() - p.t) end
    end
  end
  local name = fileFor(path)
  local e = index.e[name]
  if not e or e.p ~= path then return nil end
  local f = playdate.file.open(DIR .. name .. ".json", playdate.file.kFileReadData)
  if not f then
    index.e[name] = nil
    dirty = true
    return nil
  end
  local raw = f:read(e.s + 16)
  f:close()
  local ok, d = pcall(json.decode, raw or "")
  if not ok or type(d) ~= "table" then
    index.e[name] = nil
    dirty = true
    return nil
  end
  index.seq += 1
  e.u = index.seq
  dirty = true
  return d, math.max(0, nowSec() - (e.t or 0))
end

--- Queues the raw JSON body of a successful GET.
function DiskCache.put(path, raw)
  if not scope or type(raw) ~= "string" or #raw > MAX_ITEM or #raw < 2 then return end
  for i = #pending, 1, -1 do
    if pending[i].path == path then table.remove(pending, i) end
  end
  pending[#pending + 1] = { path = path, raw = raw, t = nowSec() }
end

local function evict(need)
  local total, n = 0, 0
  for _, e in pairs(index.e) do total += e.s n += 1 end
  while (total + need > MAX_TOTAL or n >= MAX_ITEMS) and n > 0 do
    local oldName, oldU = nil, nil
    for name, e in pairs(index.e) do
      if not oldU or (e.u or 0) < oldU then oldName, oldU = name, e.u or 0 end
    end
    if not oldName then break end
    total -= index.e[oldName].s
    n -= 1
    index.e[oldName] = nil
    pcall(playdate.file.delete, DIR .. oldName .. ".json")
  end
end

--- Does at most one queued write (call once per frame).
function DiskCache.update()
  if not scope or not index then return end
  local p = table.remove(pending, 1)
  if not p then
    if dirty then saveIndex() end
    return
  end
  local name = fileFor(p.path)
  local old = index.e[name]
  if old then index.e[name] = nil end
  evict(#p.raw)
  local f = playdate.file.open(DIR .. name .. ".json", playdate.file.kFileWrite)
  if not f then return end
  f:write(p.raw)
  f:close()
  index.seq += 1
  index.e[name] = { p = p.path, s = #p.raw, u = index.seq, t = p.t }
  dirty = true
  if #pending == 0 then saveIndex() end
end

function DiskCache.stats()
  local total, n = 0, 0
  for _, e in pairs(index and index.e or {}) do total += e.s n += 1 end
  return n, total, #pending
end
