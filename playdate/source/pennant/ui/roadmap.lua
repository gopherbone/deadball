--[[ The Road Map, as a geoscape (X-COM, simplified for 1-bit): water a dense dither with a dotted
  lat/long grid, land white with a sparse dot texture, the Great Lakes cut out, club cities as squares
  with boxed labels. Legs follow real road / main-line corridors (pennant/routes.lua), never water;
  long legs are charter flights drawn Indiana Jones style. A right-hand console carries the race, the
  next series, the road trip (with road wear) and the time controls.

  The map is painted once into an image (x1 for the screen, x2 for the travel pan); per frame only the
  route progress, the markers and the console move.

  Travel: the vehicle walks the corridor at constant speed (1-2 s, A skips); flights draw their arc ahead
  of the plane. A landmark on the corridor stops the trip on its card (Oregon Trail style); from the air
  it's a "FROM THE WINDOW" line instead.
]]

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

local MAP_W <const>, MAP_H <const> = 400, 190
local MAP_Y <const> = 18

-- A coarse outline of the lower 48, lon/lat, clockwise from Cape Flattery.
local OUTLINE <const> = {
  -124.7, 48.4, -122.8, 49.0, -95.2, 49.0, -95.2, 49.4, -94.6, 48.7, -91.0, 48.2, -89.6, 48.0, -88.0, 47.3,
  -86.2, 46.7, -84.6, 46.5, -84.0, 46.0, -83.4, 45.2, -83.4, 44.0, -82.5, 43.0, -83.1, 42.1, -82.6, 41.7,
  -81.0, 41.6, -79.0, 42.5, -79.1, 43.3, -76.4, 43.5, -76.2, 44.2, -75.0, 44.9, -71.5, 45.0, -70.0, 46.7,
  -69.2, 47.4, -68.2, 47.3, -67.8, 45.7, -67.0, 44.8, -68.8, 44.3, -70.2, 43.6, -70.6, 42.6, -70.1, 41.8,
  -71.4, 41.4, -72.9, 41.2, -74.0, 40.6, -74.0, 39.7, -74.9, 38.9, -75.1, 38.4, -75.9, 37.1, -75.5, 35.3,
  -77.0, 34.6, -78.5, 33.9, -79.2, 33.2, -80.9, 32.0, -81.5, 30.7, -80.6, 28.4, -80.1, 26.7, -80.4, 25.2,
  -81.1, 25.1, -81.8, 26.5, -82.7, 27.9, -83.0, 29.1, -84.0, 30.0, -85.4, 29.7, -86.5, 30.4, -88.0, 30.5,
  -89.5, 30.2, -89.2, 29.2, -90.5, 29.1, -92.0, 29.6, -93.8, 29.7, -95.0, 29.3, -97.0, 27.8, -97.2, 26.0,
  -99.2, 26.5, -100.3, 28.2, -101.4, 29.8, -103.0, 29.0, -104.5, 29.7, -106.5, 31.8, -108.2, 31.8, -108.2, 31.3,
  -111.1, 31.3, -114.8, 32.5, -117.1, 32.5, -118.5, 34.0, -120.6, 34.6, -121.9, 36.6, -122.5, 37.8, -123.8, 39.4,
  -124.4, 40.4, -124.2, 42.0, -124.5, 42.8, -123.9, 46.2, -124.1, 47.0,
}
local LAKES <const> = {
  { -87.8, 41.6, -87.0, 41.7, -86.3, 43.0, -86.4, 44.5, -85.6, 45.7, -87.0, 45.8, -87.6, 44.5, -87.9, 43.0 },                 -- Michigan
  { -92.1, 46.7, -90.4, 46.6, -88.4, 47.1, -86.6, 46.4, -84.9, 46.5, -84.6, 46.9, -86.0, 47.6, -88.2, 48.4, -89.6, 48.0, -91.4, 47.4 }, -- Superior
  { -84.6, 45.8, -83.4, 45.4, -82.5, 43.6, -82.4, 43.0, -81.7, 43.5, -81.7, 44.6, -80.4, 45.4, -81.4, 45.9, -83.6, 46.1 },         -- Huron
  { -83.4, 41.7, -81.7, 41.5, -80.0, 42.1, -78.9, 42.8, -79.6, 42.9, -81.2, 42.6, -82.6, 42.0 },                                 -- Erie
  { -79.8, 43.3, -78.0, 43.4, -76.3, 43.5, -76.2, 44.1, -77.6, 44.0, -79.3, 43.7 },                                               -- Ontario
}
local RIVER <const> = { -95.0, 47.5, -93.2, 45.0, -91.2, 43.5, -91.0, 40.5, -90.2, 38.6, -89.2, 37.0, -90.2, 35.0, -91.2, 32.3, -91.5, 31.0, -90.5, 29.9, -89.3, 29.2 }
local LINES <const> = {   -- a few straight-edged state lines (dotted)
  { -109.05, 41.0, -102.05, 41.0 }, { -114.0, 37.0, -94.6, 37.0 }, { -104.05, 49.0, -104.05, 41.0 }, { -102.05, 41.0, -102.05, 37.0 },
  { -111.05, 45.0, -111.05, 41.0 }, { -116.9, 49.0, -116.9, 44.5 }, { -120.0, 42.0, -111.05, 42.0 }, { -120.0, 42.0, -120.0, 39.0 },
  { -120.0, 39.0, -114.6, 35.1 }, { -103.0, 36.5, -103.0, 32.0 }, { -94.6, 36.5, -94.6, 33.6 }, { -80.5, 42.0, -80.5, 39.7 },
  { -80.5, 39.7, -75.8, 39.7 }, { -96.5, 46.0, -104.05, 46.0 }, { -96.5, 43.0, -104.05, 43.0 }, { -95.8, 40.0, -102.05, 40.0 },
}

-- boxed abbr labels on the 1x map: offsets from the city (hand-tuned so nothing collides)
local LABELS <const> = {
  PEM = { 6, -6 }, CSR = { -12, 6 }, MRL = { -12, 6 }, ELC = { -26, -14 }, MIL = { -10, 6 },
  STA = { -8, -16 }, HCL = { -10, 6 }, NCG = { 5, 2 },
}
local function proj(lon, lat, s)
  local x, y = PLand.project(lon, lat)
  s = s or 1
  return x * s, y * s
end

local function polyPts(list, s)
  local t = {}
  for i = 1, #list, 2 do
    local x, y = proj(list[i], list[i + 1], s)
    t[#t + 1] = x
    t[#t + 1] = y
  end
  return t
end

local WATER <const> = { 0x55, 0xBB, 0x55, 0xEE, 0x55, 0xBB, 0x55, 0xEE }   -- a dense dither
local LAND <const> = { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xF7, 0xFF, 0xFF }    -- a sparse dot

local mapCache = {}
--- The map at scale s (1 or 2), painted once.
function PennantUI.mapImage(s)
  if mapCache[s] then return mapCache[s] end
  local img = gfx.image.new(MAP_W * s, MAP_H * s, gfx.kColorWhite)
  gfx.pushContext(img)
  -- water, with a dotted lat/long grid (only the water shows it: the land covers the rest)
  gfx.setPattern(WATER)
  gfx.fillRect(0, 0, MAP_W * s, MAP_H * s)
  gfx.setColor(gfx.kColorWhite)
  for lon = -125, -65, 5 do
    local x = proj(lon, 40, s)
    for y = 0, MAP_H * s, 3 do gfx.fillRect(x, y, 1, 1) end
  end
  for lat = 25, 50, 5 do
    local _, y = proj(-100, lat, s)
    for x = 0, MAP_W * s, 3 do gfx.fillRect(x, y, 1, 1) end
  end
  -- land
  local pts = polyPts(OUTLINE, s)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillPolygon(table.unpack(pts))
  gfx.setPattern(LAND)
  gfx.fillPolygon(table.unpack(pts))
  -- the Great Lakes, cut out
  for _, lake in ipairs(LAKES) do
    local lk = polyPts(lake, s)
    gfx.setPattern(WATER)
    gfx.fillPolygon(table.unpack(lk))
    gfx.setColor(gfx.kColorBlack)
    gfx.drawPolygon(table.unpack(lk))
  end
  -- state lines
  gfx.setPattern(UI.pat.gray)
  for _, ln in ipairs(LINES) do
    local x1, y1 = proj(ln[1], ln[2], s)
    local x2, y2 = proj(ln[3], ln[4], s)
    gfx.drawLine(x1, y1, x2, y2)
  end
  gfx.setColor(gfx.kColorBlack)
  -- the river
  local rv = polyPts(RIVER, s)
  gfx.setLineWidth(s)
  for i = 1, #rv - 2, 2 do gfx.drawLine(rv[i], rv[i + 1], rv[i + 2], rv[i + 3]) end
  -- coast
  gfx.setLineWidth(2 * s)
  gfx.drawPolygon(table.unpack(pts))
  gfx.setLineWidth(1)
  -- landmarks: hollow triangles (the screen fills the ones ahead and ticks the ones seen)
  for _, e in ipairs(PLand.LIST) do
    local x, y = proj(e.ll[1], e.ll[2], s)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillTriangle(x, y - 3 * s, x - 3 * s, y + 2 * s, x + 3 * s, y + 2 * s)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawTriangle(x, y - 3 * s, x - 3 * s, y + 2 * s, x + 3 * s, y + 2 * s)
  end
  -- the cities: small squares, boxed labels
  for _, c in ipairs(PennantClubs) do
    local x, y = proj(c.ll[1], c.ll[2], s)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x - 3 * s, y - 3 * s, 7 * s, 7 * s)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(x - 3 * s, y - 3 * s, 7 * s, 7 * s)
    local t = s == 1 and c.abbr or c.city
    local f = UI.fonts.bold
    local w = f:getTextWidth(t)
    -- (x2: under the city, but Harbor City's name goes to its right, clear of New Corinth's)
    local off = s == 1 and LABELS[c.abbr] or (c.abbr == "HCL" and { 9 * s, -6 } or { -w // 2, 7 * s })
    local tx, ty = x + off[1], y + off[2]
    if s == 1 and off[1] < 0 and off[1] > -20 then tx = x - w // 2 end
    tx = math.max(2, math.min(MAP_W * s - w - 4, tx))
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(tx - 2, ty, w + 4, 12)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(tx - 2, ty, w + 4, 12)
    Text.draw(t, tx, ty - 1, f)
  end
  gfx.popContext()
  mapCache[s] = img
  return img
end

function PennantUI.releaseMaps() mapCache = {} end

local function cityXY(abbr, s)
  local c = PennantClubs.byAbbr[abbr]
  return proj(c.ll[1], c.ll[2], s)
end

local function commas(n)
  local t = tostring(math.floor(n))
  local out = t:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

--- A leg's points in map pixels at scale s (corridor, or the flight's arc), plus the ground corridor
--- under a flight, cached.
local legCache = {}
local function legPts(from, to, s)
  local key = from .. to .. s
  local c = legCache[key]
  if c then return c end
  local r = PRoutes.path(from, to)
  local function px(list)
    local t = {}
    for i = 1, #list, 2 do local x, y = proj(list[i], list[i + 1], s) t[#t + 1] = x t[#t + 1] = y end
    return t
  end
  local cum, len = { 0 }, 0
  local pts = px(r.points)
  for i = 3, #pts, 2 do len = len + math.sqrt((pts[i] - pts[i - 2]) ^ 2 + (pts[i + 1] - pts[i - 1]) ^ 2) cum[#cum + 1] = len end
  c = { pts = pts, cum = cum, len = len, mode = r.mode, miles = r.miles, ground = r.ground and px(r.ground), r = r }
  legCache[key] = c
  return c
end

--- The point u (0..1) of the way along a leg, and the direction there.
local function legAt(leg, u)
  local d = leg.len * math.max(0, math.min(1, u))
  local pts, cum = leg.pts, leg.cum
  for k = 2, #cum do
    if cum[k] >= d or k == #cum then
      local seg = cum[k] - cum[k - 1]
      local t = seg > 0 and (d - cum[k - 1]) / seg or 0
      local i = (k - 1) * 2 - 1
      local x1, y1, x2, y2 = pts[i], pts[i + 1], pts[i + 2], pts[i + 3]
      return x1 + (x2 - x1) * t, y1 + (y2 - y1) * t, x2 - x1, k
    end
  end
  return pts[#pts - 1], pts[#pts], 1, #cum
end

--- One segment: rail (solid with ties), dashed (upcoming), or faint (a flight's ground corridor).
local function seg(x1, y1, x2, y2, style, w)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 0.5 then return end
  local ux, uy = dx / len, dy / len
  if style == "solid" then
    gfx.setLineWidth(w or 2)
    gfx.drawLine(x1, y1, x2, y2)
    gfx.setLineWidth(1)
  elseif style == "rail" then
    gfx.setLineWidth(2)
    gfx.drawLine(x1, y1, x2, y2)
    gfx.setLineWidth(1)
    for d = 3, len, 6 do
      local px, py = x1 + ux * d, y1 + uy * d
      gfx.drawLine(px - uy * 2, py + ux * 2, px + uy * 2, py - ux * 2)
    end
  else
    local step = style == "faint" and 5 or 6
    for d = 0, len, step do
      local e = math.min(len, d + (style == "faint" and 1 or 3))
      gfx.drawLine(x1 + ux * d, y1 + uy * d, x1 + ux * e, y1 + uy * e)
    end
  end
end

--- Draw a leg (or its first u of the way) in a style.
local function drawLeg(leg, style, u, w)
  local pts = leg.pts
  if not u or u >= 1 then
    for i = 1, #pts - 2, 2 do seg(pts[i], pts[i + 1], pts[i + 2], pts[i + 3], style, w) end
    return
  end
  local x, y, _, k = legAt(leg, u)
  for i = 1, (k - 2) * 2 - 1, 2 do seg(pts[i], pts[i + 1], pts[i + 2], pts[i + 3], style, w) end
  local i = (k - 1) * 2 - 1
  seg(pts[i], pts[i + 1], x, y, style, w)
end

--- Travel icons by distance: bus, train, prop plane (16 x 10, drawn centred).
function PennantUI.vehicle(kind, x, y, flip)
  x, y = math.floor(x), math.floor(y)
  local f = flip and -1 or 1
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x - 9, y - 6, 18, 12)
  gfx.setColor(gfx.kColorBlack)
  if kind == "bus" then
    gfx.fillRoundRect(x - 8, y - 4, 16, 7, 2)
    gfx.setColor(gfx.kColorWhite)
    for i = 0, 3 do gfx.fillRect(x - 6 + i * 3, y - 3, 2, 2) end
    gfx.setColor(gfx.kColorBlack)
    gfx.fillCircleAtPoint(x - 4, y + 4, 2) gfx.fillCircleAtPoint(x + 4, y + 4, 2)
  elseif kind == "train" then
    gfx.fillRect(x - 7, y - 2, 12, 5)
    gfx.fillRect(x + 2 * f - (f < 0 and 4 or 0), y - 5, 4, 4)
    gfx.fillRect(x - 5, y - 4, 2, 2)
    gfx.fillCircleAtPoint(x - 4, y + 4, 2) gfx.fillCircleAtPoint(x + 2, y + 4, 2)
    gfx.drawLine(x - 8 * f, y + 1, x - 10 * f, y + 3)
  else
    -- prop plane
    gfx.fillRect(x - 7, y - 1, 14, 3)
    gfx.fillRect(x - 2, y - 5, 3, 11)
    gfx.fillRect(x - 7 * f - (f < 0 and 0 or 0), y - 3, 2, 6)
    gfx.drawLine(x + 7 * f, y - 3, x + 7 * f, y + 3)
  end
end

function PennantUI.vehicleFor(from, to)
  local r = PRoutes.path(from, to)
  return r.mode, r.miles
end

--- One fact about a park, for the console.
local function parkFact(c)
  if c.alt >= 3000 then return c.alt .. " ft up. The ball carries." end
  if (c.walls[1] or 0) >= 20 then return "A " .. c.walls[1] .. "-ft wall in left." end
  if c.fences[1] <= 320 or c.fences[5] <= 320 then return math.min(c.fences[1], c.fences[5]) .. " ft down the line." end
  if c.fences[3] >= 415 then return c.fences[3] .. " to center. Bring a glove." end
  if c.turf then return "Turf. The grounders skip." end
  return "Fair to everyone. Mostly."
end

-- The Road Map screen -------------------------------------------------------------------------------

local Map = { opaque = true }
Map.__index = Map
PennantUI.RoadMap = Map

local VW <const>, VH <const> = 282, 156      -- the map viewport (x 0..282, y MAP_Y..MAP_Y + VH)
local CX <const> = 285                       -- the console's left edge

function Map.open(args)
  local s = setmetatable({}, Map)
  App.push(s, args)
  return s
end

function Map:enter(args)
  local L = Pennant.L
  self.route = PL.route(L, L.user)
  -- the current stop: the first series not finished
  self.cur = #self.route
  for i, s in ipairs(self.route) do if s.done < s.n then self.cur = i break end end
  self.sel = self.cur
  self.t = 0
  self.btn = 1
  self.camX, self.camY = MAP_W - VW, 0
  self:follow()
  self:paintOverlay()
  self:paintConsole()
end

--- Keep the selected stop's city (and where we came from) in view.
function Map:follow()
  local s = self.route[self.sel]
  if not s then return end
  local x, y = cityXY(s.host, 1)
  if x - self.camX < 20 then self.camX = math.max(0, x - 40) end
  if x - self.camX > VW - 20 then self.camX = math.min(MAP_W - VW, x - VW + 40) end
  self.camY = math.max(0, math.min(MAP_H - VH, y - VH // 2))
end

--- Legs, results and landmark states into one overlay image (redrawn on change).
function Map:paintOverlay()
  local L = Pennant.L
  local img = PennantUI.mapImage(1):copy()
  gfx.pushContext(img)
  local route = self.route
  -- landmarks: filled = ahead on the next legs, ticked = seen
  local ahead = {}
  for i = self.cur + 1, math.min(#route, self.cur + 6) do
    local a, b = route[i - 1], route[i]
    if a and b and a.host ~= b.host then
      local leg = legPts(a.host, b.host, 1)
      if leg.mode ~= "plane" then
        for _, e in ipairs(PLand.LIST) do
          local x, y = proj(e.ll[1], e.ll[2], 1)
          for k = 1, #leg.pts - 2, 2 do
            if PLand.segDist(x, y, leg.pts[k], leg.pts[k + 1], leg.pts[k + 2], leg.pts[k + 3]) < 6 then ahead[e.key] = true break end
          end
        end
      end
    end
  end
  for _, e in ipairs(PLand.LIST) do
    local x, y = proj(e.ll[1], e.ll[2], 1)
    if ahead[e.key] then gfx.fillTriangle(x, y - 3, x - 3, y + 2, x + 3, y + 2) end
    if L.lmSeen and L.lmSeen[e.key] then gfx.drawLine(x + 3, y - 1, x + 4, y + 1) gfx.drawLine(x + 4, y + 1, x + 7, y - 4) end
  end
  -- legs: played solid (rail ties on the ground), upcoming dashed; flights an arc over a faint corridor
  for i = 2, #route do
    local a, b = route[i - 1], route[i]
    if a.host ~= b.host then
      local leg = legPts(a.host, b.host, 1)
      local played = i <= self.cur
      if leg.ground then
        local g = { pts = leg.ground }
        for k = 1, #g.pts - 2, 2 do seg(g.pts[k], g.pts[k + 1], g.pts[k + 2], g.pts[k + 3], "faint") end
      end
      drawLeg(leg, played and (leg.mode == "plane" and "solid" or "rail") or "dash")
    end
  end
  -- results per city (the latest finished series there): filled = won it
  local labels = {}
  for i, st in ipairs(route) do if st.done > 0 then labels[st.host] = st end end
  for abbr, st in pairs(labels) do
    local x, y = cityXY(abbr, 1)
    local off = LABELS[abbr] or { 5, -4 }
    local bx, by = x + off[1] + 26, y + off[2]
    local txt = st.w .. "-" .. st.l
    local w = UI.fonts.bold:getTextWidth(txt) + 4
    if st.w > st.l then gfx.fillRect(bx, by, w, 12) Text.draw(txt, bx + 2, by - 1, UI.fonts.bold, "white")
    else gfx.setColor(gfx.kColorWhite) gfx.fillRect(bx, by, w, 12) gfx.setColor(gfx.kColorBlack) gfx.drawRect(bx, by, w, 12) Text.draw(txt, bx + 2, by - 1, UI.fonts.bold) end
  end
  -- home: a filled center
  local hx, hy = cityXY(L.user, 1)
  gfx.fillRect(hx - 1, hy - 1, 3, 3)
  gfx.popContext()
  self.img = img
  self:paintInfo()
end

--- The strip under the map: the selected stop, how we get there.
function Map:paintInfo()
  local L = Pennant.L
  local s = self.route[self.sel]
  local img = gfx.image.new(VW, PUI.BOT - MAP_Y - VH, gfx.kColorWhite)
  gfx.pushContext(img)
  gfx.drawLine(0, 0, VW, 0)
  if s then
    local prev = self.route[self.sel - 1]
    local tag = self.sel == self.cur and "NOW" or (self.sel < self.cur and "PLAYED" or "NEXT")
    local res = s.done == s.n and (" \u{2022} " .. (s.w > s.l and "won " or (s.w < s.l and "lost " or "split ")) .. s.w .. "-" .. s.l) or (s.done > 0 and (" \u{2022} " .. s.w .. "-" .. s.l .. " so far") or "")
    local l1 = tag .. ": " .. (s.home and "vs " or "at ") .. PUI.nick(s.opp) .. ", " .. PL.date(L, s.d0) .. "-" .. PL.date(L, s.d1):match("%d+$") .. res
    Text.draw(Text.ellipsize(l1, UI.fonts.bold, VW - 6), 3, 2, UI.fonts.bold)
    local l2
    if prev and prev.host ~= s.host then
      local leg = legPts(prev.host, s.host, 1)
      local via = PRoutes.via(leg.r, 3)
      l2 = PRoutes.MODE_NAME[leg.mode] .. " from " .. PennantClubs.byAbbr[prev.host].city .. ", " .. commas(leg.miles) .. " mi" .. (#via > 0 and leg.mode ~= "plane" and (" via " .. table.concat(via, ", ")) or "")
      local z = PRoutes.zones(prev.host, s.host)
      if z ~= 0 then l2 = l2 .. ((z > 0) and " (back " or " (ahead ") .. math.abs(z) .. " hr)" end
    else
      l2 = "No travel: " .. (prev and "same park as the last series." or "the season starts here.")
    end
    Text.draw(Text.ellipsize(l2, UI.fonts.body, VW - 6), 3, 16, UI.fonts.body)
  end
  gfx.popContext()
  self.info = img
end

local TIME <const> = { { "\u{25b6}", "A day", { days = 1 } }, { "\u{25b6}\u{25b6}", "The series", { untilSeries = true } }, { "TRIP", "To the trip's end", { untilTrip = true } } }

--- The console: the race, the next series, the road trip and road wear, the time controls.
function Map:paintConsole()
  local L = Pennant.L
  local T = L.teams[L.user]
  local h = PUI.BOT - MAP_Y
  local img = gfx.image.new(400 - CX, h, gfx.kColorWhite)
  gfx.pushContext(img)
  local w = 400 - CX
  gfx.drawLine(0, 0, 0, h)
  local function title(y, t) gfx.fillRect(1, y, w - 1, 13) Text.draw(t, 4, y - 1, UI.fonts.bold, "white") return y + 14 end
  -- THE RACE
  local y = title(0, "THE RACE")
  if L.phase == "season" then
    for _, e in ipairs(PL.raceWindow(L)) do
      local mine = e.T.abbr == L.user
      if mine then gfx.fillRect(1, y - 1, w - 1, 12) end
      local col = mine and "white" or nil
      Text.draw(e.rank .. " " .. e.T.abbr, 3, y - 2, UI.fonts.bold, col)
      Text.draw(e.T.w .. "-" .. e.T.l, 76, y - 2, UI.fonts.body, col, "right")
      Text.draw(PL.gbText(e.T.gb), w - 3, y - 2, UI.fonts.body, col, "right")
      if e.rank == 4 then gfx.setPattern(UI.pat.gray) gfx.drawLine(2, y + 10, w - 2, y + 10) gfx.setColor(gfx.kColorBlack) end
      y = y + 12
    end
    Text.draw(PL.raceNumber(L), 3, y - 1, UI.fonts.bold)
    y = y + 14
  else
    Text.draw(L.phase == "playoffs" and "Playoffs" or "Season over", 3, y, UI.fonts.bold)
    y = y + 16
  end
  -- NEXT
  local g, d = PL.nextGame(L, L.user)
  if g then
    local opp = g.h == L.user and g.a or g.h
    y = title(y, "NEXT: " .. (g.h == L.user and "vs " or "at ") .. opp)
    local st = self.route[self.cur]
    local n = st and st.n or 1
    Text.draw(PL.date(L, d) .. ", " .. n .. " game" .. (n == 1 and "" or "s"), 3, y - 1, UI.fonts.body)
    local c = PennantClubs.byAbbr[g.h]
    Text.draw(Text.ellipsize(c.park, UI.fonts.body, w - 6), 3, y + 11, UI.fonts.body)
    Text.draw(Text.ellipsize(parkFact(c), UI.fonts.body, w - 6), 3, y + 23, UI.fonts.body)
    y = y + 37
  end
  -- ROAD TRIP / HOMESTAND, road wear
  local away = g and g.a == L.user
  local len = PL.roadTripLen(L, L.user)
  local rs = PL.roadStreak(L, L.user, math.max(1, L.day - 1))
  if away then
    local gameNo = math.max(1, rs + 1)
    y = title(y, "ROAD TRIP " .. math.min(gameNo, len + rs) .. "/" .. (len + rs))
  else
    y = title(y, "HOMESTAND, " .. len .. " games")
  end
  Text.draw("Road wear", 3, y - 1, UI.fonts.body)
  -- the rule: from the 6th straight road game, a little fatigue every day
  local pips = math.max(0, math.min(5, rs - 4))
  for k = 1, 5 do
    local px = 64 + (k - 1) * 9
    if k <= pips then gfx.fillRect(px, y + 2, 7, 7) else gfx.drawRect(px, y + 2, 7, 7) end
  end
  Text.draw(rs >= 6 and "Tired legs: +fatigue daily" or (away and "From game 6: tiring" or "Fresh at home"), 3, y + 11, UI.fonts.body)
  y = y + 26
  -- time controls
  self.btnY = MAP_Y + h - 19
  local bw = (w - 6) // 3
  self.btnRects = {}
  for i, t in ipairs(TIME) do
    local bx = 2 + (i - 1) * (bw + 1)
    Draw.button(bx, h - 19, bw, 17, t[1])
    self.btnRects[i] = { CX + bx, MAP_Y + h - 19, bw, 17 }
  end
  gfx.popContext()
  self.console = img
end

function Map:update()
  self.t = self.t + 1
  PJobs.tick(10)
  gfx.clear(gfx.kColorWhite)
  -- the map viewport
  gfx.setClipRect(0, MAP_Y, VW, VH)
  self.img:draw(-self.camX, MAP_Y - self.camY)
  -- your club: a blinking ring at the selected stop's city, the vehicle at the current one
  local s = self.route[self.sel]
  if s then
    local x, y = cityXY(s.host, 1)
    x, y = x - self.camX, y + MAP_Y - self.camY
    if (self.t // 8) % 2 == 0 or self.sel ~= self.cur then
      gfx.drawCircleAtPoint(x, y, 8)
      gfx.drawCircleAtPoint(x, y, 9)
    end
    if self.sel == self.cur then
      local prev = self.route[self.sel - 1]
      local kind = prev and prev.host ~= s.host and PennantUI.vehicleFor(prev.host, s.host) or "bus"
      PennantUI.vehicle(kind, x + 14, y - 14)
    end
  end
  gfx.clearClipRect()
  -- clubs off the edge get a tag ("< PEM")
  for _, c in ipairs(PennantClubs) do
    local x, y = cityXY(c.abbr, 1)
    x = x - self.camX
    if x < 0 or x > VW then
      local ty = math.max(MAP_Y + 2, math.min(MAP_Y + VH - 14, y + MAP_Y - self.camY - 6))
      local t = x < 0 and ("\u{25c0}" .. c.abbr) or (c.abbr .. "\u{25b6}")
      local tw = UI.fonts.bold:getTextWidth(t) + 4
      local tx = x < 0 and 2 or VW - tw - 2
      gfx.fillRect(tx, ty, tw, 12)
      Text.draw(t, tx + 2, ty - 1, UI.fonts.bold, "white")
    end
  end
  self.info:draw(0, MAP_Y + VH)
  self.console:draw(CX, MAP_Y)
  -- the focused time control
  local r = self.btnRects[self.btn]
  if r then
    gfx.setLineWidth(2)
    gfx.drawRoundRect(r[1] - 2, r[2] - 2, r[3] + 4, r[4] + 4, 3)
    gfx.setLineWidth(1)
  end
  PUI.topBar("Road Map", PUI.rightText())
  PUI.hintBar(TIME[self.btn][2] .. ": A    \u{25c0}\u{25b6} stops  \u{25b2}\u{25bc} time  crank: pan")
end

function Map:move(d)
  local n = math.max(1, math.min(#self.route, self.sel + d))
  if n ~= self.sel then self.sel = n self:follow() self:paintInfo() Sfx.tick() end
end
function Map:leftButtonDown() self:move(-1) end
function Map:rightButtonDown() self:move(1) end
function Map:upButtonDown() self.btn = (self.btn - 2) % #TIME + 1 Sfx.focus() end
function Map:downButtonDown() self.btn = self.btn % #TIME + 1 Sfx.focus() end
function Map:cranked(c)
  self.camX = math.max(0, math.min(MAP_W - VW, self.camX + c / 3))
end
function Map:BButtonDown() Sfx.back() App.pop() end
function Map:AButtonDown()
  -- the time controls are the hub's sim verbs
  Sfx.select()
  local args = {}
  for k, v in pairs(TIME[self.btn][3]) do args[k] = v end
  App.pop()
  PennantUI.Advance.open(args)
end
function Map:exit() self.img = nil end

-- Travel animation ---------------------------------------------------------------------------------

local Travel = { opaque = true }
Travel.__index = Travel
PennantUI.Travel = Travel

function Travel.open(args)
  local s = setmetatable({}, Travel)
  App.push(s, args)
  return s
end

function Travel:enter(args)
  self.from, self.to, self.lm, self.onDone = args.from, args.to, args.landmark, args.onDone
  self.leg = legPts(self.from, self.to, 2)
  self.kind = self.leg.mode
  -- constant speed: 1-2 s by length on the map
  self.dur = math.max(30, math.min(60, math.floor(self.leg.len / 8)))
  self.f = 0
  self.u = 0
  self.paused = false
  self.map2 = PennantUI.mapImage(2)
  local L = Pennant.L
  local ng = PL.nextGame(L, L.user)
  local away = ng and ng.a == L.user
  local trip = away and PL.roadTripLen(L, L.user) or 0
  local r = self.leg.r
  local z = PRoutes.zones(self.from, self.to)
  local via = PRoutes.via(r, 2)
  local parts = { (self.kind == "plane" and "By air" or (self.kind == "train" and "By rail" or "By bus")) .. " to " .. PennantClubs.byAbbr[self.to].city,
    commas(r.miles) .. " mi" .. (self.kind ~= "plane" and #via > 0 and (" via " .. table.concat(via, ", ")) or "") }
  if z ~= 0 then parts[#parts + 1] = (z > 0 and "back " or "ahead ") .. math.abs(z) .. " hour" .. (math.abs(z) > 1 and "s" or "") end
  if trip >= 6 then parts[#parts + 1] = trip .. "-game road trip" elseif not away then parts[#parts + 1] = "homestand" end
  self.caption = table.concat(parts, " \u{2022} ")
  if Game.settings.reduceMotion and not self.lm then self.u = 1 end
  Sfx.music("turkey_straw", { fade = 0.5 })
end

function Travel:update()
  if not self.paused then
    self.f = self.f + 1
    local e = self.f / self.dur
    self.u = Game.settings.reduceMotion and 1 or math.min(1, e)
    if self.lm and not self.lmShown and self.u >= self.lm.t then
      self.lmShown = true
      if self.lm.window then
        -- from the air: a line in a box, the flight goes on
        self.windowT = 0
      else
        self.paused = true
        PennantUI.LandmarkCard.open({ lm = self.lm, onDone = function() self.paused = false end })
      end
    end
  end
  local leg = self.leg
  local x, y, dx = legAt(leg, self.u)
  -- camera: centred on the vehicle, clamped to the map
  local camX = math.max(0, math.min(MAP_W * 2 - 400, x - 200))
  local camY = math.max(0, math.min(MAP_H * 2 - 190, y - 95))
  gfx.clear(gfx.kColorWhite)
  self.map2:draw(-camX, MAP_Y - camY)
  gfx.setDrawOffset(-camX, MAP_Y - camY)
  if leg.ground then
    local g = leg.ground
    for k = 1, #g - 2, 2 do seg(g[k], g[k + 1], g[k + 2], g[k + 3], "faint") end
  end
  if self.kind == "plane" then
    -- Indiana Jones: the flown part heavy, the rest dashed
    drawLeg(leg, "dash")
    drawLeg(leg, "solid", self.u, 4)
  else
    drawLeg(leg, "dash")
    drawLeg(leg, "rail", self.u)
  end
  gfx.setDrawOffset(0, 0)
  -- the vehicle at double size
  local flip = dx < 0
  local key = self.kind .. (flip and "f" or "")
  PennantUI.vehImgs = PennantUI.vehImgs or {}
  local vi = PennantUI.vehImgs[key]
  if not vi then
    vi = gfx.image.new(22, 16, gfx.kColorClear)
    gfx.pushContext(vi)
    PennantUI.vehicle(self.kind, 11, 8, flip)
    gfx.popContext()
    PennantUI.vehImgs[key] = vi
  end
  vi:drawScaled(x - camX - 22, y - camY + MAP_Y - 16, 2)
  -- a window sighting
  if self.windowT then
    self.windowT = self.windowT + 1
    if self.windowT < 75 then
      local bx, by, bw = 6, 140, 198
      gfx.setColor(gfx.kColorBlack)
      gfx.fillRect(bx + 3, by + 3, bw, 58)
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(bx, by, bw, 58)
      gfx.setColor(gfx.kColorBlack)
      gfx.drawRect(bx, by, bw, 58)
      gfx.fillRect(bx, by, bw, 13)
      Text.draw("FROM THE WINDOW", bx + 4, by - 1, UI.fonts.bold, "white")
      Text.block(self.lm.text, bx + 4, by + 14, bw - 8, UI.fonts.body, nil, 3)
      Text.draw("(no effect)", bx + bw - 4, by + 44, UI.fonts.body, nil, "right")
    end
  end
  PUI.topBar("On the road", PUI.rightText())
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 208, 400, 18)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(0, 208, 399, 208)
  Text.draw(Text.ellipsize(self.caption, UI.fonts.bold, 392), 200, 210, UI.fonts.bold, nil, "center")
  PUI.hintBar("A: skip")
  if self.u >= 1 and not self.paused and (not self.windowT or self.windowT >= 75) then
    self.hold = (self.hold or 0) + 1
    if self.hold > 12 then self:finish() end
  end
end

function Travel:finish()
  if self.closed then return end
  self.closed = true
  App.pop()
  if self.onDone then self.onDone() end
end

function Travel:AButtonDown()
  if self.lm and not self.lmShown and not self.lm.window then
    self.u = self.lm.t
    self.f = math.floor(self.dur * self.lm.t)
    return
  end
  self:finish()
end
Travel.BButtonDown = Travel.AButtonDown

-- Landmark card --------------------------------------------------------------------------------------

local Card = { opaque = true }
Card.__index = Card
PennantUI.LandmarkCard = Card

function Card.open(args)
  local s = setmetatable({}, Card)
  App.push(s, args)
  return s
end

local function chime()
  -- a little original travel ditty: five plucked notes on a square wave
  if not Sfx.enabled then return end
  local syn = playdate.sound.synth.new(playdate.sound.kWaveSquare)
  syn:setADSR(0.005, 0.08, 0.2, 0.15)
  syn:setVolume(0.25 * (Sfx.volume or 0.8))
  local notes = { 523, 659, 784, 659, 1047 }
  for i, n in ipairs(notes) do
    playdate.timer.performAfterDelay((i - 1) * 140, function() syn:playNote(n, 0.25, 0.12) end)
  end
end

function Card:enter(args)
  self.lm, self.onDone = args.lm, args.onDone
  self.t = 0
  self.photo = gfx.image.new("images/landmarks/" .. self.lm.key)
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 240)
  -- the picture
  if self.photo then
    self.photo:draw(0, 18)
  else
    -- (art not in this build: a plain dithered horizon)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(0, 18, 400, 160)
    gfx.setPattern(UI.pat.gray)
    gfx.fillRect(0, 130, 400, 48)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(self.lm.name, 200, 80, UI.fonts.big, nil, "center")
  end
  -- caption band
  Text.draw(self.lm.name:upper(), 200, 1, UI.fonts.bold, "white", "center")
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 178, 400, 62)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(0, 178, 399, 178)
  Text.block(self.lm.text, 8, 182, 384, UI.fonts.body, nil, 3)
  if self.lm.effect then Text.draw(self.lm.effect, 8, 222, UI.fonts.bold) end
  Text.draw("A \u{25b6}", 392, 222, UI.fonts.bold, nil, "right")
  gfx.popContext()
  self.img = img
  chime()
end

function Card:update()
  self.t = self.t + 1
  -- a quick iris-in (skipped with reduceMotion)
  local u = Game.settings.reduceMotion and 1 or math.min(1, self.t / 8)
  if u < 1 then
    gfx.clear(gfx.kColorBlack)
    local h = math.floor(240 * u)
    self.img:draw(0, 120 - h // 2, gfx.kImageUnflipped, playdate.geometry.rect.new(0, 120 - h // 2, 400, h))
  else
    self.img:draw(0, 0)
  end
end

function Card:AButtonDown()
  if self.t < 8 then return end
  Sfx.select()
  App.pop()
  self.photo = nil
  if self.onDone then self.onDone() end
end
Card.BButtonDown = Card.AButtonDown
