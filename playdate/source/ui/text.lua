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

--- Truncates to `width`, adding an ellipsis when cut.
function Text.ellipsize(str, font, width)
  str = tostring(str or "")
  if font:getTextWidth(str) <= width then return str end
  local key = fid(font) .. ":" .. width .. ":" .. str
  local hit = ellCache[key]
  if hit then return hit[1] end
  local ell = "\u{2026}"
  local ew = font:getTextWidth(ell)
  local lo, hi = 0, #str
  while lo < hi do
    local mid = (lo + hi + 1) // 2
    if font:getTextWidth(str:sub(1, mid)) + ew <= width then lo = mid else hi = mid - 1 end
  end
  -- don't cut a UTF-8 sequence in half
  while lo > 0 and lo < #str and (str:byte(lo + 1) or 0) >= 0x80 and (str:byte(lo + 1) or 0) < 0xC0 do lo -= 1 end
  local out = str:sub(1, lo):gsub("%s+$", "") .. ell
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

function Text.width(str, font)
  return (font or UI.fonts.body):getTextWidth(tostring(str or ""))
end
