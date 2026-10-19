-- Fonts, patterns and small shared helpers for the Diamond Navigator shell.

local gfx <const> = playdate.graphics

UI = UI or {}
UI.W, UI.H = 400, 240

local function font(path, fallback)
  local f = gfx.font.new(path)
  if not f and fallback then f = gfx.font.new(fallback) end
  return f or gfx.getSystemFont()
end

-- Composite font: an unmodified SDK font plus our own "extras" glyph font for the
-- characters the base lacks. Quacks like a playdate.graphics.font for the calls the
-- shell uses (drawText, getTextWidth, getHeight).
local Composite = {}
Composite.__index = Composite

local function compose(base, extra, extraChars, tracking)
  if not base then return extra end
  if not extra then return base end
  local set = {}
  for _, cp in utf8.codes(extraChars) do set[cp] = true end
  return setmetatable({ base = base, extra = extra, set = set, h = base:getHeight(), tracking = tracking or 1, cache = {}, cacheN = 0 }, Composite)
end

function Composite:getHeight() return self.h end
function Composite:getLeading() return 0 end

-- quick check: anything outside plain letters/digits/common punctuation?
local function needsSplit(self, str)
  if str:find("[^%w%s!\"%(%)%-,:;%./%?=%%]") == nil then return false end
  for _, cp in utf8.codes(str, true) do
    if self.set[cp] then return true end
  end
  return false
end

-- Splitting a string into base/extra runs walks it codepoint by codepoint, which is
-- far too slow to repeat every frame (tickers, menubars, live widgets). Results are
-- cached per string: { [1..n] = { isExtra, text, width }, w = total width }.
local function splitRuns(self, str)
  local runs = {}
  local n = 0
  local cur, curExtra = {}, nil
  for _, cp in utf8.codes(str, true) do
    local isExtra = self.set[cp] == true
    if curExtra ~= nil and isExtra ~= curExtra then
      n += 1
      runs[n] = { curExtra, table.concat(cur) }
      cur = {}
    end
    curExtra = isExtra
    cur[#cur + 1] = utf8.char(cp)
  end
  if #cur > 0 then
    n += 1
    runs[n] = { curExtra, table.concat(cur) }
  end
  local w = 0
  for i = 1, n do
    local r = runs[i]
    r[3] = (r[1] and self.extra or self.base):getTextWidth(r[2])
    w += r[3]
    if i < n then w += self.tracking end
  end
  runs.w = w
  return runs
end

local RUN_CACHE_MAX <const> = 600

-- false = plain string (base font only), otherwise the cached runs
local function runsFor(self, str)
  local cache = self.cache
  local hit = cache[str]
  if hit ~= nil then return hit end
  local v = false
  if utf8.len(str, 1, -1, true) ~= nil and needsSplit(self, str) then v = splitRuns(self, str) end
  if self.cacheN >= RUN_CACHE_MAX then
    self.cache = {}
    self.cacheN = 0
    cache = self.cache
  end
  cache[str] = v
  self.cacheN += 1
  return v
end

function Composite:getTextWidth(str)
  str = tostring(str or "")
  local runs = runsFor(self, str)
  if not runs then return self.base:getTextWidth(str) end
  return runs.w
end

function Composite:drawText(str, x, y)
  str = tostring(str or "")
  local runs = runsFor(self, str)
  if not runs then return self.base:drawText(str, x, y) end
  for i = 1, #runs do
    local r = runs[i]
    local f = r[1] and self.extra or self.base
    f:drawText(r[2], x, y)
    x += r[3] + self.tracking
  end
end

local LIGHT_EXTRAS <const> = "$#@&'*[]{}<>_|~^\\`\u{25b6}\u{25c0}\u{25b2}\u{25bc}\u{2022}\u{2026}\u{2014}\u{b0}\u{2605}\u{2665}\u{2713}"
local BOLD_EXTRAS <const> = "$#@&*[]{}<>_|~^\\`+\u{25b6}\u{25c0}\u{25b2}\u{25bc}\u{2022}\u{2026}\u{2014}\u{b0}\u{2605}\u{2665}\u{2713}"

UI.fonts = {
  body  = compose(font("fonts/Nontendo-Light"), gfx.font.new("ui/fonts/Navigator-Extras-Light"), LIGHT_EXTRAS),  -- 13px main text
  bold  = compose(font("fonts/Nontendo-Bold"), gfx.font.new("ui/fonts/Navigator-Extras-Bold"), BOLD_EXTRAS),     -- 13px chrome/labels
  head  = font("fonts/Roobert-10-Bold"),              -- 14px section heads
  big   = font("ui/fonts/Roobert-11-Bold"),           -- 22px headlines
  serif = font("fonts/Newsleak-Serif-Bold"),          -- newspaper / event card headline
  slab  = font("fonts/Sasser-Slab-Bold"),             -- WordArt source
  mono  = font("fonts/Roobert-11-Mono-Condensed"),    -- BBS terminal
}
-- The assets agent's WordArt faces (outlined, drop-shadowed, caps only).
UI.fonts.wordart = gfx.font.new("fonts/Deadball-WordArt")
UI.fonts.wordartBig = gfx.font.new("fonts/Deadball-WordArt-Big")

-- 8x8 patterns (1 = white bit, 0 = black bit in the Playdate convention).
UI.pat = {
  gray    = { 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 },
  light   = { 0xEE, 0xFF, 0xBB, 0xFF, 0xEE, 0xFF, 0xBB, 0xFF },
  lighter = { 0xFF, 0xDD, 0xFF, 0xFF, 0xFF, 0x77, 0xFF, 0xFF },
  dark    = { 0x11, 0x00, 0x44, 0x00, 0x11, 0x00, 0x44, 0x00 },
  diag    = { 0x7F, 0xBF, 0xDF, 0xEF, 0xF7, 0xFB, 0xFD, 0xFE },
  hazard  = { 0x0F, 0x87, 0xC3, 0xE1, 0xF0, 0x78, 0x3C, 0x1E },
  bricks  = { 0x00, 0xEF, 0xEF, 0xEF, 0x00, 0xFE, 0xFE, 0xFE },
  dots    = { 0xFF, 0xFF, 0xF7, 0xFF, 0xFF, 0xFF, 0x7F, 0xFF },
  weave   = { 0x77, 0xBB, 0xDD, 0xEE, 0xDD, 0xBB, 0x77, 0xFF },
  title   = { 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00, 0xFF, 0x00 }, -- Mac-style title stripes
}

--- Load an image if it exists (assets may not have landed yet). Cached; nil if missing.
local imgCache = {}
local MISSING <const> = {}
function UI.image(path)
  local c = imgCache[path]
  if c == MISSING then return nil end
  if c then return c end
  local img = gfx.image.new(path)
  imgCache[path] = img or MISSING
  return img
end

function UI.imagetable(path)
  local c = imgCache["T:" .. path]
  if c == MISSING then return nil end
  if c then return c end
  local t = gfx.imagetable.new(path)
  imgCache["T:" .. path] = t or MISSING
  return t
end

function UI.releaseImage(path)
  imgCache[path] = nil
end

-- Formatting --------------------------------------------------------------

Fmt = Fmt or {}

function Fmt.int(n)
  n = math.floor((n or 0) + 0.5)
  local s = tostring(math.abs(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if out:sub(1, 1) == "," then out = out:sub(2) end
  if n < 0 then out = "-" .. out end
  return out
end

function Fmt.money(n)
  if n == nil then return "$--" end
  if n < 0 then return "-$" .. Fmt.int(-n) end
  return "$" .. Fmt.int(n)
end

function Fmt.pays(x)
  if not x or x <= 0 then return "--" end
  return string.format("%.2f", x)
end

--- "4m", "2h 5m", "now" from a millisecond delta.
function Fmt.dur(ms)
  if ms <= 0 then return "now" end
  local s = math.floor(ms / 1000)
  if s < 60 then return s .. "s" end
  local m = math.floor(s / 60)
  if m < 60 then return m .. "m" end
  local h = math.floor(m / 60)
  return h .. "h " .. (m % 60) .. "m"
end

--- "5m ago" style relative time against the server clock.
function Fmt.ago(at)
  if not at then return "" end
  local d = (Api and Api.now() or at) - at
  if d < 60000 then return "now" end
  if d < 3600000 then return math.floor(d / 60000) .. "m" end
  if d < 86400000 then return math.floor(d / 3600000) .. "h" end
  return math.floor(d / 86400000) .. "d"
end

function Fmt.clock()
  local t = playdate.getTime()
  local h = t.hour % 12
  if h == 0 then h = 12 end
  return string.format("%d:%02d", h, t.minute)
end

function Fmt.teamName(t)
  if not t then return "?" end
  return (t.city or "") .. " " .. (t.name or "")
end

function Fmt.levelName(l)
  return ({ ML = "Continental", AA = "Class AA", B = "Class B", D = "Class D", EL = "Enhanced" })[l] or l or ""
end

--- Lowercase url-ish slug for the fake address bar.
function Fmt.slug(s)
  return (tostring(s or ""):lower():gsub("[^%w]+", ""))
end

--- "first pitch in 12m" / "first pitch any minute" for a SlateGame.
function Fmt.firstPitch(g, cap)
  local left = (g and g.firstPitchAt or 0) - (Api and Api.now() or 0)
  local s = left > 60000 and ("first pitch in " .. Fmt.dur(left)) or "first pitch any minute"
  if cap then s = s:gsub("^%l", string.upper) end
  return s
end
