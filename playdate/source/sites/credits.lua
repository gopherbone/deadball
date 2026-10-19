-- "About this site / Webmaster credits": team line, SDK font note, and every CC-BY /
-- public-domain attribution from the asset agents' credits.json files.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Credits = Page.define({ canvasH = 1200 })
Sites.Credits = Credits

local SOURCES <const> = {
  { "Music & sound", "audio/credits.json" },
  { "Pictures & sprites", "images/credits.json" },
  { "Photo archive", "images/archive/credits.json" },
}

function Credits:url() return "http://www.deadball.net/about/credits.html" end

local function entries(data)
  if type(data) ~= "table" then return {} end
  if data[1] then return data end
  return data.credits or data.entries or data.items or data.assets or {}
end

local function isFree(lic)
  lic = (lic or ""):lower()
  return lic:find("^public") ~= nil or lic:find("cc0") ~= nil or lic:find("no known") ~= nil
end

-- Attribution-required items are listed one by one; public-domain items are grouped
-- by source with counts, and small sources collapse into one line. Full per-item
-- sources live in docs/CREDITS.md.
local function summarize(list)
  local out, bySrc, order = {}, {}, {}
  for _, e in ipairs(list) do
    if isFree(e.license) then
      local k = e.author or "Unknown"
      if not bySrc[k] then bySrc[k] = 0; order[#order + 1] = k end
      bySrc[k] += 1
    else
      out[#out + 1] = {
        head = (e.title or e.name or "Untitled") .. (e.author and (" by " .. e.author) or ""),
        sub = (e.year and (tostring(e.year) .. "  ") or "") .. (e.license or "") .. (e.notes and ("  (" .. e.notes .. ")") or ""),
      }
    end
  end
  table.sort(order, function(a, b) return bySrc[a] > bySrc[b] end)
  local rest, restN = 0, 0
  for _, k in ipairs(order) do
    if bySrc[k] >= 3 or #order <= 12 then
      out[#out + 1] = { head = k, sub = bySrc[k] .. (bySrc[k] == 1 and " item" or " items") .. ", public domain" }
    else
      rest += 1
      restN += bySrc[k]
    end
  end
  if rest > 0 then
    out[#out + 1] = { head = "Plus " .. rest .. " other sources", sub = restN .. " items, public domain. Full list in CREDITS.md." }
  end
  return out
end

function Credits:init()
  self.groups = {}
  local W = 392
  for _, src in ipairs(SOURCES) do
    local list = {}
    if playdate.file.exists(src[2]) then
      local ok, data = pcall(json.decodeFile, src[2])
      if ok then list = entries(data) end
    end
    -- wrap once here (strong refs), not on every layout pass
    local rows, hh = {}, 6
    for _, r in ipairs(summarize(list)) do
      local hl = Text.wrap(r.head, UI.fonts.bold, W - 40)
      local sl = r.sub ~= "" and Text.wrap(r.sub, UI.fonts.body, W - 46) or {}
      rows[#rows + 1] = { hl, sl }
      hh += #hl * 14 + #sl * 14 + 4
    end
    if #rows == 0 then hh = 20 end
    self.groups[#self.groups + 1] = { title = src[1], rows = rows, h = hh, file = src[2] }
  end
end

function Credits:layout(L)
  local W = 392
  local stars = UI.image("images/bg/stars")
  if stars then stars:drawTiled(0, 0, W, 6400) else Draw.tile(0, 0, W, 6400, "dots") end
  local _, h = Draw.wordart("CREDITS", W // 2, 2, UI.fonts.slab)
  local y = h + 4
  local function box(height)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(10, y, W - 20, height)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(10, y, W - 20, height)
  end
  local intro = {
    "DEADBALL: a baseball game for a shared online world.",
    "Made by the Deadball team with a lot of help from robots.",
    "Fonts: Playdate SDK fonts (Nontendo, Roobert, Newsleak Serif, Sasser Slab), used under the Playdate SDK license. The Navigator UI fonts are extended from Nontendo.",
    "Face bank photos: Library of Congress, Bain News Service collection (public domain).",
  }
  local ih = 8
  for _, t in ipairs(intro) do ih += #Text.wrap(t, UI.fonts.body, W - 40) * 14 + 4 end
  box(ih)
  local ty = y + 5
  for _, t in ipairs(intro) do
    ty += Text.block(t, 20, ty, W - 40, UI.fonts.body) + 4
  end
  y += ih + 8
  for _, g in ipairs(self.groups) do
    gfx.fillRect(10, y, W - 20, 15)
    Text.draw(g.title:upper(), 15, y + 1, UI.fonts.bold, "white")
    y += 15
    local rows, hh = g.rows, g.h
    box(hh)
    local ry = y + 4
    if #rows == 0 then
      Text.draw("(nothing listed yet)", 20, ry, UI.fonts.body)
    end
    for _, r in ipairs(rows) do
      for _, l in ipairs(r[1]) do Text.draw(l, 20, ry, UI.fonts.bold) ry += 14 end
      for _, l in ipairs(r[2]) do Text.draw(l, 26, ry, UI.fonts.body) ry += 14 end
      ry += 4
    end
    y += hh + 8
  end
  box(40)
  Text.draw("This site is best viewed with Diamond Navigator", W // 2, y + 6, UI.fonts.body, nil, "center")
  Text.draw("at 400x240 in glorious 1-bit.", W // 2, y + 20, UI.fonts.body, nil, "center")
  y += 46
  L:live(W // 2 - 30, y, 60, 14, function(_, x, yy, f) Draw.hitCounter(x, yy, 1996 + f // 300, 6) end)
  y += 20
  Draw.stripes(10, y, W - 20, 12, "UNDER CONSTRUCTION")
  L:button("Back", W // 2 - 35, y + 20, 70, 18, function() self:goBack() end, { id = "back" })
  L:mark(y + 44)
end
