-- Text layout with the bitmap fonts: word wrap, ellipsis, pagination, drawing in
-- black or white. Wrapping results are cached (weak) so per-frame calls are cheap.

local gfx <const> = playdate.graphics

Text = Text or {}

-- Strong caches with a size cap: weak tables got emptied by every GC cycle, so
-- per-frame wraps kept re-measuring every word.
local CACHE_MAX <const> = 400
local wrapCache, wrapN = {}, 0
local ellCache, ellN = {}, 0
local fontIds = setmetatable({}, { __mode = "k" })
local nextFontId = 0

local function fid(font)
  local id = fontIds[font]
  if not id then
    nextFontId += 1
    id = nextFontId
    fontIds[font] = id
  end
  return id
end

--- Splits `str` into lines no wider than `width`. Honors "\n". Long words are broken.
function Text.wrap(str, font, width)
  str = tostring(str or "")
  local key = fid(font) .. ":" .. width .. ":" .. str
  local hit = wrapCache[key]
  if hit then return hit end
  local lines = {}
  for para in (str .. "\n"):gmatch("(.-)\n") do
    local line = ""
    for word in para:gmatch("%S+") do
      local cand = line == "" and word or (line .. " " .. word)
      if font:getTextWidth(cand) <= width then
        line = cand
      else
        if line ~= "" then lines[#lines + 1] = line end
        -- break words that are wider than the line on their own
        while font:getTextWidth(word) > width do
          -- longest prefix that fits (binary search), then back off to a UTF-8 boundary
          local lo, hi = 1, #word
          while lo < hi do
            local mid = (lo + hi + 1) // 2
            if font:getTextWidth(word:sub(1, mid)) <= width then lo = mid else hi = mid - 1 end
          end
          local n = lo
          while n > 1 and (word:byte(n + 1) or 0) >= 0x80 and (word:byte(n + 1) or 0) < 0xC0 do n -= 1 end
          lines[#lines + 1] = word:sub(1, n)
          word = word:sub(n + 1)
        end
        line = word
      end
    end
    lines[#lines + 1] = line
  end
  if wrapN >= CACHE_MAX then wrapCache, wrapN = {}, 0 end
  wrapCache[key] = lines
  wrapN += 1
  return lines
end

-- Fonts with no "\u{2026}" glyph draw it as nothing, so a cut line just stopped ("Monogrammed
-- statio"): they get three dots instead. (The Navigator composites, Roobert, the serif and the
-- slab faces have the glyph; the BBS mono and the WordArt faces don't.)
Text.noEllipsis = Text.noEllipsis or setmetatable({}, { __mode = "k" })
if UI and UI.fonts then
  for _, k in ipairs({ "mono", "wordart", "wordartBig" }) do
    if UI.fonts[k] then Text.noEllipsis[UI.fonts[k]] = true end
  end
end
function Text.ellipsisFor(font)
  return Text.noEllipsis[font] and "..." or "\u{2026}"
end

--- Truncates to `width`, adding an ellipsis when cut. A cut that would leave a stub of a word
--- ("Back an underdog. S...") backs up to the space before it.
function Text.ellipsize(str, font, width)
  str = tostring(str or "")
  if font:getTextWidth(str) <= width then return str end
  local key = fid(font) .. ":" .. width .. ":" .. str
  local hit = ellCache[key]
  if hit then return hit[1] end
  local ell = Text.ellipsisFor(font)
  local ew = font:getTextWidth(ell)
  local lo, hi = 0, #str
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if font:getTextWidth(str:sub(1, mid)) + ew <= width then lo = mid else hi = mid - 1 end
  end
  -- don't cut a UTF-8 sequence in half
  while lo > 0 and lo < #str and (str:byte(lo + 1) or 0) >= 0x80 and (str:byte(lo + 1) or 0) < 0xC0 do lo -= 1 end
  -- mid-word with only a few letters of it kept: end at the previous word instead
  if lo < #str and str:sub(lo + 1, lo + 1):find("%S") then
    local sp = str:sub(1, lo):match(".*()%s")
    if sp and sp > lo // 2 and lo - sp <= 3 then lo = sp - 1 end
  end
  local out = str:sub(1, lo):gsub("[%s%p]+$", "") .. ell
  if ellN >= CACHE_MAX then ellCache, ellN = {}, 0 end
  ellCache[key] = { out }
  ellN += 1
  return out
end

--- Splits wrapped lines into pages of `perPage` lines.
function Text.paginate(lines, perPage)
  local pages = {}
  for i = 1, #lines, perPage do
    local p = {}
    for j = i, math.min(#lines, i + perPage - 1) do p[#p + 1] = lines[j] end
    pages[#pages + 1] = p
  end
  if #pages == 0 then pages[1] = {} end
  return pages
end

function Text.lineHeight(font)
  return font:getHeight() + 1
end

--- Draws a single line. color: nil/black or "white". align: "left"|"center"|"right" (x is the anchor).
function Text.draw(str, x, y, font, color, align)
  str = tostring(str or "")
  font = font or UI.fonts.body
  if UI.plainPunct and not font.base then str = UI.plainPunct(font, str) end  -- (composites do their own)
  if align == "center" then
    x = x - font:getTextWidth(str) // 2
  elseif align == "right" then
    x = x - font:getTextWidth(str)
  end
  if color == "white" then
    gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
    font:drawText(str, x, y)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
  else
    gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
    font:drawText(str, x, y)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
  end
  return font:getTextWidth(str)
end

--- Draws wrapped text; returns the height used. maxLines truncates with an ellipsis.
function Text.block(str, x, y, width, font, color, maxLines, leading)
  font = font or UI.fonts.body
  local lines = Text.wrap(str, font, width)
  local lh = font:getHeight() + (leading or 1)
  local n = #lines
  if maxLines and n > maxLines then n = maxLines end
  for i = 1, n do
    local s = lines[i]
    if maxLines and i == n and #lines > n then s = Text.ellipsize(s .. " \u{2026}", font, width) end
    Text.draw(s, x, y + (i - 1) * lh, font, color)
  end
  return n * lh
end

--- Ink metrics of a face (cached): capTop / capBot are the first and last ink rows of "H" below
--- the draw y, descBot the lowest row of "gjpqy". Line heights don't say where the ink is: the
--- Nontendo faces (body, bold) start their capitals on the very first row of the line and keep
--- three rows of descender below, so text placed by getHeight() sits flush against a box's top.
local metricsCache = setmetatable({}, { __mode = "k" })
function Text.metrics(font)
  font = font or UI.fonts.body
  local m = metricsCache[font]
  if m then return m end
  local f = font.base or font   -- (composites: the base face carries the letters)
  local h = f:getHeight()
  local function rows(str)
    local w = f:getTextWidth(str) + 2
    local img = gfx.image.new(w, h + 4, gfx.kColorWhite)
    gfx.pushContext(img)
    gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
    f:drawText(str, 1, 2)
    gfx.popContext()
    local top, bot
    for yy = 0, h + 3 do
      for xx = 0, w - 1 do
        if img:sample(xx, yy) == gfx.kColorBlack then
          top = top or yy
          bot = yy
          break
        end
      end
    end
    return (top or 2) - 2, (bot or h + 1) - 2
  end
  local ct, cb = rows("H")
  local _, db = rows("gjpqy")
  m = { capTop = ct, capBot = cb, capH = cb - ct + 1, descBot = math.max(cb, db) }
  metricsCache[font] = m
  return m
end

--- The draw y that centres a line's capitals in the box rows [top, top + h) (the box's inside:
--- pass the rows between its borders). An odd spare row goes above. With `str` given, a line
--- with descenders is lifted (toward one clear row under the top) to keep them inside the box.
function Text.boxY(font, top, h, str)
  local m = Text.metrics(font)
  local y = top + (h - m.capH + 1) // 2 - m.capTop
  if str and m.descBot > m.capBot and tostring(str):find("[gjpqy,;Q%(%)%[%]{}|_]") then
    local maxY = top + h - 1 - m.descBot
    -- (never closer than one clear row under the top when the box has room for it)
    if y > maxY then y = math.max(maxY, top + (h >= m.capH + 2 and 1 or 0) - m.capTop) end
  end
  return y
end

function Text.width(str, font)
  return (font or UI.fonts.body):getTextWidth(tostring(str or ""))
end

--- Fit-or-shorten: the longest form of a label that fits `width`. Tries `str`, then each of
--- opts.short (a string or a list, e.g. the club nickname without the city, a surname), first in
--- `font`, then in each of opts.fonts (smaller faces; default: bold falls back to body), and
--- only then cuts `str` with an ellipsis in `font`. Returns the text and the font to draw it in.
function Text.fit(str, width, font, opts)
  str = tostring(str or "")
  font = font or UI.fonts.body
  if font:getTextWidth(str) <= width then return str, font end
  local cands = { str }
  local short = opts and opts.short
  if type(short) == "string" then cands[2] = short
  elseif type(short) == "table" then for _, c in ipairs(short) do cands[#cands + 1] = c end end
  local fonts = { font }
  local more = opts and opts.fonts
  if more == nil and font == UI.fonts.bold then more = { UI.fonts.body } end
  for _, f in ipairs(more or {}) do fonts[#fonts + 1] = f end
  for _, f in ipairs(fonts) do
    for _, c in ipairs(cands) do
      if c and c ~= "" and f:getTextWidth(c) <= width then return c, f end
    end
  end
  return Text.ellipsize(str, font, width), font
end

--- Text.fit, then draw (same args as Text.draw plus the width and the fit options).
--- Returns the width drawn.
function Text.drawFit(str, x, y, width, font, color, align, opts)
  local s, f = Text.fit(str, width, font, opts)
  font = font or UI.fonts.body
  -- a smaller face sits on the same baseline-ish line: centre it in the original's height
  local dy = (font:getHeight() - f:getHeight()) // 2
  return Text.draw(s, x, y + dy, f, color, align)
end

--- A club's "City Name" in `width`, else the nickname alone ("Prospectors"), else cut.
--- Same face throughout (callers line these up in columns). Returns the text.
function Text.fitTeam(t, width, font)
  if not t then return "?" end
  local full = ((t.city or "") ~= "" and (t.city .. " ") or "") .. (t.name or "")
  return (Text.fit(full, width, font or UI.fonts.body, { short = t.name, fonts = {} }))
end

--- "Ernesto Shaughnessy" -> "E. Shaughnessy" (a short form to hand Text.fit).
function Text.initialName(name)
  name = tostring(name or "")
  local first, rest = name:match("^(%S+)%s+(.+)$")
  if not first then return name end
  return first:sub(1, 1) .. ". " .. rest
end
