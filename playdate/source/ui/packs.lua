-- Packed assets. The Makefile builds the .pdx from a staged copy of source/ in which the
-- loose face / archive PNGs and fixture JSONs are replaced by a few packed files
-- (tools/assets/pack.py): the device's data disk is very slow per file.
--
--   Packs.image(dir, key, size)  image `key` of size class `size` from <dir>/pack.json tables
--   Packs.json(path)             decoded JSON file, read loose or from <dir>/pack.json
--
-- Both fall back to the loose files, so a plain `pdc source` build (dev harness) still works.

local gfx <const> = playdate.graphics
local file <const> = playdate.file

Packs = Packs or {}

local MISSING <const> = {}

---------------------------------------------------------------------------
-- images

local imgIndex = {}   -- dir -> decoded pack.json (keys turned into a key -> n map) | MISSING

local function imageIndex(dir)
  local ix = imgIndex[dir]
  if ix == nil then
    ix = MISSING
    local p = dir .. "/pack.json"
    if file.exists(p) then
      local ok, d = pcall(json.decodeFile, p)
      if ok and type(d) == "table" and d.sizes then
        for _, s in pairs(d.sizes) do
          local map = {}
          for i, k in ipairs(s.keys) do map[k] = i end
          s.map, s.keys = map, nil
        end
        ix = d
      end
    end
    imgIndex[dir] = ix
  end
  return ix ~= MISSING and ix or nil
end

-- A whole imagetable is decoded at once (~120-220 KB each), so keep only the few most
-- recently used; images handed out are copies and don't pin their table.
local TABLE_SLOTS <const> = 8   -- small tables (~46 KB each decoded): 8 is less RAM than the old 3 big ones
local tables, lru = {}, {}

local function imagetable(path)
  local t = tables[path]
  if t then
    if lru[#lru] ~= path then
      for i = #lru, 1, -1 do
        if lru[i] == path then table.remove(lru, i) break end
      end
      lru[#lru + 1] = path
    end
    return t
  end
  t = gfx.imagetable.new(path)
  if not t then return nil end
  tables[path] = t
  lru[#lru + 1] = path
  while #lru > TABLE_SLOTS do tables[table.remove(lru, 1)] = nil end
  return t
end

--- Returns img, packed. `packed` is false when <dir> has no pack (use the loose file);
--- when packed, img is nil if the key/size isn't in the pack.
function Packs.image(dir, key, size)
  local ix = imageIndex(dir)
  if not ix then return nil, false end
  local s = ix.sizes[tostring(size)]
  local i = s and s.map[key]
  if not i then return nil, true end
  local t = imagetable(dir .. "/" .. s.tables[(i - 1) // s.per + 1])
  local img = t and t:getImage((i - 1) % s.per + 1)
  return img and img:copy() or nil, true
end

--- Packed image, or the loose file <dir>/<key>-<size> when the dir isn't packed.
function Packs.loadImage(dir, key, size)
  local img, packed = Packs.image(dir, key, size)
  if packed then return img end
  local p = dir .. "/" .. key .. "-" .. size
  if file.exists(p .. ".pdi") or file.exists(p .. ".png") then return gfx.image.new(p) end
  return nil
end

--- Drops the decoded tables (e.g. on low memory).
function Packs.flush()
  tables, lru = {}, {}
end

---------------------------------------------------------------------------
-- JSON

local jsonIndex = {}  -- dir ("fixtures/") -> { [name] = { offset, length } } | MISSING

local function packIndex(dir)
  local ix = jsonIndex[dir]
  if ix == nil then
    ix = MISSING
    local p = dir .. "pack-index.json"
    if file.exists(p) then
      local ok, d = pcall(json.decodeFile, p)
      if ok and type(d) == "table" then ix = d end
    end
    jsonIndex[dir] = ix
  end
  return ix ~= MISSING and ix or nil
end

--- Decoded JSON for `path` (loose file first, then the dir's pack); nil if absent/invalid.
function Packs.json(path)
  if file.exists(path) then
    local ok, d = pcall(json.decodeFile, path)
    if ok then return d end
    return nil
  end
  local dir, name = path:match("^(.*/)([^/]+)$")
  local ix = dir and packIndex(dir)
  local e = ix and ix[name]
  if not e then return nil end
  local f = file.open(dir .. "pack.json", file.kFileRead)
  if not f then return nil end
  f:seek(e[1])
  local s = f:read(e[2])
  f:close()
  if not s then return nil end
  local ok, d = pcall(json.decode, s)
  if ok then return d end
  return nil
end

--- True if `path` exists loose or in its dir's pack.
function Packs.jsonExists(path)
  if file.exists(path) then return true end
  local dir, name = path:match("^(.*/)([^/]+)$")
  local ix = dir and packIndex(dir)
  return (ix and ix[name]) ~= nil
end
