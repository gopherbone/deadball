-- Face bank photos: "face:<n>[variant]" -> images/faces/<n><variant>-<size>.png (packed into
-- imagetables in the build, see ui/packs.lua), with a drawn silhouette fallback.
-- Images are cached and evicted in bulk.

import "ui/packs"

local gfx <const> = playdate.graphics

Faces = Faces or {}

local SIZES <const> = { [24] = { 24, 24 }, [48] = { 48, 60 }, [96] = { 96, 120 } }
local cache = {}
local count = 0
local acache, acount = {}, 0   -- archive photos (below)
local MISSING <const> = {}
local LIMIT <const> = 120

function Faces.size(size)
  local s = SIZES[size] or SIZES[48]
  return s[1], s[2]
end

local function parse(id)
  if not id then return nil end
  local n, v = tostring(id):match("^face:(%d+)(%a?)$")
  return n, v or ""
end

--- Returns the image (or nil when the asset doesn't exist yet).
function Faces.get(id, size)
  local n, v = parse(id)
  if not n then return nil end
  local path = n .. v .. "-" .. size
  local c = cache[path]
  if c == MISSING then return nil end
  if c then return c end
  if count > LIMIT then
    cache = {}
    count = 0
  end
  local img = Packs.loadImage("images/faces", n .. v, size)
  if not img and v ~= "" then img = Packs.loadImage("images/faces", n, size) end
  cache[path] = img or MISSING
  count += 1
  return img
end

--- Draws the face (or a silhouette) framed at x, y. Returns w, h.
function Faces.draw(id, x, y, size, opts)
  local w, h = Faces.size(size)
  local img = Faces.get(id, size)
  if img then
    img:draw(x, y)
  else
    Draw.silhouette(x, y, w, h)
  end
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x - 1, y - 1, w + 2, h + 2)
  if opts and opts.double then gfx.drawRect(x - 3, y - 3, w + 6, h + 6) end
  return w, h
end

function Faces.flush()
  cache = {}
  count = 0
  acache, acount = {}, 0
  Packs.flush()
end

-- Public-domain archive photos: images/archive/<id>-<size>.png, sizes 400 (400x240),
-- 160 (160x100), 96 (96x72), 48 (48x36). Returns nil when absent. Packed like the faces;
-- cached and evicted in bulk.
Archive = Archive or {}
local ASIZES <const> = { [400] = { 400, 240 }, [160] = { 160, 100 }, [96] = { 96, 72 }, [48] = { 48, 36 } }
local ALIMIT <const> = 48

function Archive.size(size)
  local s = ASIZES[size] or ASIZES[96]
  return s[1], s[2]
end

function Archive.get(id, size)
  if not id or id == "" then return nil end
  id = tostring(id)
  local key = id .. "-" .. size
  local c = acache[key]
  if c == MISSING then return nil end
  if c then return c end
  if acount > ALIMIT then
    acache, acount = {}, 0
  end
  local img = Packs.loadImage("images/archive", id, size)
  acache[key] = img or MISSING
  acount += 1
  return img
end

--- Draws a framed archive photo if it exists; returns w, h (or nil when missing).
function Archive.draw(id, x, y, size)
  local img = Archive.get(id, size)
  if not img then return nil end
  img:draw(x, y)
  local w, h = Archive.size(size)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x - 1, y - 1, w + 2, h + 2)
  return w, h
end

-- Club logos: images/logos/<ABBR>-32|16.png for big clubs; farm clubs use the lettered
-- pennant tables (frame = city initial).
Logos = Logos or {}
function Logos.get(team, size)
  size = size or 32
  if not team then return nil end
  local abbr = team.abbr or team.id
  local img = abbr and UI.image("images/logos/" .. abbr .. "-" .. size)
  if img then return img end
  local tbl = UI.imagetable("images/logos/farm-" .. size)
  local c = (team.city or abbr or "A"):upper():byte(1) or 65
  if tbl and c >= 65 and c <= 90 then return tbl:getImage(c - 64) end
  return nil
end

function Logos.draw(team, x, y, size)
  local img = Logos.get(team, size)
  if img then img:draw(x, y) return true end
  return false
end
