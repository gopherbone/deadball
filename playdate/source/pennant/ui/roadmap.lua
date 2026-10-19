--[[ The Road Map: your club's season on a 1-bit map of the country. Played legs are solid
  railroad lines, upcoming ones dashed; every stop shows its series result; homestands and road
  trips are marked; rival clubs sit in their current cities. The map is an original drawing
  (a coarse hand-placed outline from lon/lat points), painted once into an image (x1 for the
  map screen, x2 for the travel pan); per frame only the route progress and the icon move.

  Travel: between series in different cities, a 1-2 s pan follows a bus / train / prop plane
  along the leg (skippable; reduceMotion shows the arrival). A landmark on the way stops the trip
  on its card (Oregon Trail style).
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
local LAKE_MICHIGAN <const> = { -87.8, 41.6, -87.0, 41.7, -86.3, 43.0, -86.4, 44.5, -85.6, 45.7, -87.0, 45.8, -87.6, 44.5, -87.9, 43.0 }
local RIVER <const> = { -95.0, 47.5, -93.2, 45.0, -91.2, 43.5, -91.0, 40.5, -90.2, 38.6, -89.2, 37.0, -90.2, 35.0, -91.2, 32.3, -91.5, 31.0, -90.5, 29.9, -89.3, 29.2 }
local LINES <const> = {   -- a few straight-edged state lines (dotted)
  { -109.05, 41.0, -102.05, 41.0 }, { -114.0, 37.0, -94.6, 37.0 }, { -104.05, 49.0, -104.05, 41.0 }, { -102.05, 41.0, -102.05, 37.0 },
  { -111.05, 45.0, -111.05, 41.0 }, { -116.9, 49.0, -116.9, 44.5 }, { -120.0, 42.0, -111.05, 42.0 }, { -120.0, 42.0, -120.0, 39.0 },
  { -120.0, 39.0, -114.6, 35.1 }, { -103.0, 36.5, -103.0, 32.0 }, { -94.6, 36.5, -94.6, 33.6 }, { -80.5, 42.0, -80.5, 39.7 },
  { -80.5, 39.7, -75.8, 39.7 }, { -96.5, 46.0, -104.05, 46.0 }, { -96.5, 43.0, -104.05, 43.0 }, { -95.8, 40.0, -102.05, 40.0 },
}

-- label placement on the 1x map (see mapImage)
local LABELS <const> = {
  PEM = { "right" }, CSR = { "below" }, MRL = { "below" }, ELC = { "above" }, MIL = { "below" },
  STA = { "leftup" }, HCL = { "sea", 86 }, NCG = { "sea", 100 },
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

local mapCache = {}
--- The map at scale s (1 or 2), painted once.
function PennantUI.mapImage(s)
  if mapCache[s] then return mapCache[s] end
  local img = gfx.image.new(MAP_W * s, MAP_H * s, gfx.kColorWhite)
  gfx.pushContext(img)
  -- sea: sparse wave marks
  gfx.setColor(gfx.kColorBlack)
  for y = 6 * s, MAP_H * s, 14 * s do
    for x = ((y // (14 * s)) % 2) * 9 * s, MAP_W * s, 18 * s do
      gfx.drawLine(x, y, x + 2 * s, y - s) gfx.drawLine(x + 2 * s, y - s, x + 4 * s, y)
    end
  end
  -- land
  local pts = polyPts(OUTLINE, s)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillPolygon(table.unpack(pts))
  gfx.setPattern(UI.pat.lighter)
  gfx.fillPolygon(table.unpack(pts))
  gfx.setColor(gfx.kColorBlack)
  -- lake
  local lk = polyPts(LAKE_MICHIGAN, s)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillPolygon(table.unpack(lk))
  gfx.setColor(gfx.kColorBlack)
  gfx.drawPolygon(table.unpack(lk))
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
  -- landmarks (small triangles), then the cities
  for _, e in ipairs(PLand.LIST) do
    local x, y = proj(e.ll[1], e.ll[2], s)
    gfx.fillTriangle(x, y - 2 * s, x - 2 * s, y + s, x + 2 * s, y + s)
  end
  for _, c in ipairs(PennantClubs) do
    local x, y = proj(c.ll[1], c.ll[2], s)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(x, y, 4 * s)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawCircleAtPoint(x, y, 4 * s)
    gfx.fillCircleAtPoint(x, y, 2 * s)
  end
  -- city names: placed by hand on the small map (the Northeast is crowded: those labels sit out
  -- over the Atlantic on leader lines); simply under the city on the big one
  for _, c in ipairs(PennantClubs) do
    local x, y = proj(c.ll[1], c.ll[2], s)
    local t = c.city
    local w = UI.fonts.body:getTextWidth(t)
    local lb = s == 1 and LABELS[c.abbr] or { "below" }
    local tx, ty
    if lb[1] == "below" then tx, ty = x - w // 2, y + 5 * s
    elseif lb[1] == "above" then tx, ty = x - w // 2, y - 5 * s - 12
    elseif lb[1] == "right" then tx, ty = x + 6 * s, y - 6
    elseif lb[1] == "leftup" then tx, ty = x - 5 - w, y - 16
    else
      -- "sea": right-aligned at the map's edge, at row lb[2], with a leader line
      tx, ty = MAP_W - 3 - w, lb[2]
      gfx.setPattern(UI.pat.gray)
      gfx.drawLine(x, y, tx - 2, ty + 6)
      gfx.setColor(gfx.kColorBlack)
    end
    tx = math.max(2, math.min(MAP_W * s - w - 2, tx))
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(tx - 1, ty + 1, w + 2, 11)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(t, tx, ty, UI.fonts.body)
  end
  -- compass + title cartouche
  local cx, cy = 384 * s, 176 * s
  gfx.drawCircleAtPoint(cx, cy, 8 * s)
  gfx.fillTriangle(cx, cy - 8 * s, cx - 3 * s, cy, cx + 3 * s, cy)
  Text.draw("N", cx, cy - 20 * s, UI.fonts.bold, nil, "center")
  gfx.popContext()
  mapCache[s] = img
  return img
end

function PennantUI.releaseMaps() mapCache = {} end

local function cityXY(abbr, s)
  local c = PennantClubs.byAbbr[abbr]
  return proj(c.ll[1], c.ll[2], s)
end

--- Railroad line (solid with ties) or dashed (upcoming).
local function rail(x1, y1, x2, y2, solid, upto)
  local dx, dy = x2 - x1, y2 - y1
  local len = math.sqrt(dx * dx + dy * dy)
  if len < 1 then return end
  local ux, uy = dx / len, dy / len
  upto = upto or 1
  if solid then
    gfx.setLineWidth(2)
    gfx.drawLine(x1, y1, x1 + dx * upto, y1 + dy * upto)
    gfx.setLineWidth(1)
    for d = 4, len * upto, 6 do
      local px, py = x1 + ux * d, y1 + uy * d
      gfx.drawLine(px - uy * 3, py + ux * 3, px + uy * 3, py - ux * 3)
    end
  else
    for d = 0, len, 6 do
      local e = math.min(len, d + 3)
      gfx.drawLine(x1 + ux * d, y1 + uy * d, x1 + ux * e, y1 + uy * e)
    end
  end
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
  local ax, ay = cityXY(from, 1)
  local bx, by = cityXY(to, 1)
  local d = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
  return d < 60 and "bus" or (d < 170 and "train" or "plane"), d
end

-- The Road Map screen -------------------------------------------------------------------------------

local Map = { opaque = true }
Map.__index = Map
PennantUI.RoadMap = Map

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
  self:paintOverlay()
end

--- Stops, route lines, results and rival markers into one overlay image (redrawn on change).
function Map:paintOverlay()
  local L = Pennant.L
  local img = PennantUI.mapImage(1):copy()
  gfx.pushContext(img)
  local route = self.route
  -- legs
  for i = 2, #route do
    local a, b = route[i - 1], route[i]
    if a.host ~= b.host then
      local x1, y1 = cityXY(a.host, 1)
      local x2, y2 = cityXY(b.host, 1)
      rail(x1, y1, x2, y2, i <= self.cur)
    end
  end
  -- results per city (the latest finished series there)
  local labels = {}
  for i, s in ipairs(route) do
    if s.done > 0 then labels[s.host] = { s = s, i = i } end
  end
  -- the last series result in each city (a filled tag: won it)
  local BADGE = { ELC = { 6, -2 }, NCG = { 5, 2 } }
  for abbr, lb in pairs(labels) do
    local x, y = cityXY(abbr, 1)
    local off = BADGE[abbr] or { 5, -13 }
    local bx, by = x + off[1], y + off[2]
    local s = lb.s
    local txt = s.w .. "-" .. s.l
    local w = UI.fonts.bold:getTextWidth(txt) + 4
    if s.w > s.l then gfx.fillRect(bx, by, w, 12) Text.draw(txt, bx + 2, by, UI.fonts.bold, "white")
    else gfx.setColor(gfx.kColorWhite) gfx.fillRect(bx, by, w, 12) gfx.setColor(gfx.kColorBlack) gfx.drawRect(bx, by, w, 12) Text.draw(txt, bx + 2, by, UI.fonts.bold) end
  end
  -- the four playoff spots' clubs where they are today: a small flag on the city
  for i, T in ipairs(PL.standings(L)) do
    if i <= 4 and T.abbr ~= L.user then
      local g = PL.gameFor(L, T.abbr) or PL.nextGame(L, T.abbr)
      local x, y = cityXY(g and g.h or T.abbr, 1)
      local fx, fy = x - 7 - (i - 1) * 3, y - 9
      gfx.drawLine(fx, fy, fx, fy + 7)
      gfx.fillTriangle(fx + 1, fy, fx + 6, fy + 2, fx + 1, fy + 4)
    end
  end
  -- the pennant race (bottom left, over the Pacific)
  local px, py, pw, ph = 2, 120, 104, 68
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(px, py, pw, ph)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(px, py, pw, ph)
  Text.draw("THE RACE", px + 4, py + 1, UI.fonts.bold)
  local yy = py + 15
  for i, T in ipairs(PL.standings(L)) do
    if i > 4 and T.abbr ~= L.user then goto continue end
    if yy > py + ph - 12 then break end
    local f = T.abbr == L.user and UI.fonts.bold or UI.fonts.body
    Text.draw(i .. " " .. T.abbr, px + 4, yy, f)
    Text.draw(T.w .. "-" .. T.l, px + 70, yy, f, nil, "right")
    Text.draw(PL.gbText(T.gb), px + pw - 4, yy, f, nil, "right")
    yy = yy + 12
    ::continue::
  end
  gfx.popContext()
  self.img = img
  self:paintInfo()
end

--- Bottom strip: the selected stop.
function Map:paintInfo()
  local L = Pennant.L
  local s = self.route[self.sel]
  local img = gfx.image.new(400, 16, gfx.kColorWhite)
  gfx.pushContext(img)
  gfx.drawLine(0, 0, 399, 0)
  if s then
    -- run of home / away series around the selection
    local i0, i1 = self.sel, self.sel
    while i0 > 1 and self.route[i0 - 1].home == s.home do i0 = i0 - 1 end
    while i1 < #self.route and self.route[i1 + 1].home == s.home do i1 = i1 + 1 end
    local games = 0
    for k = i0, i1 do games = games + self.route[k].n end
    local kind = s.home and (games .. "-game homestand") or (games .. "-game road trip")
    local res = s.done == s.n and (" \u{2022} " .. (s.w > s.l and "won " or (s.w < s.l and "lost " or "split ")) .. s.w .. "-" .. s.l) or (s.done > 0 and (" \u{2022} " .. s.w .. "-" .. s.l .. " so far") or "")
    local txt = string.format("%s %s %s \u{2022} %s-%s%s \u{2022} %s", self.sel == self.cur and "NOW:" or (self.sel < self.cur and "PLAYED:" or "NEXT:"),
      s.home and "vs" or "at", PUI.nick(s.opp), PL.date(L, s.d0), PL.date(L, s.d1):match("%d+$"), res, kind)
    Text.draw(Text.ellipsize(txt, UI.fonts.body, 392), 4, 2, UI.fonts.body)
  end
  gfx.popContext()
  self.info = img
end

function Map:update()
  self.t = self.t + 1
  PJobs.tick(10)
  gfx.clear(gfx.kColorWhite)
  PUI.topBar("Road Map", PUI.rightText())
  self.img:draw(0, MAP_Y)
  -- your club: blinking marker at the selected stop's city
  local s = self.route[self.sel]
  if s then
    local x, y = cityXY(s.host, 1)
    y = y + MAP_Y
    if (self.t // 8) % 2 == 0 or self.sel ~= self.cur then
      gfx.setColor(gfx.kColorBlack)
      gfx.drawCircleAtPoint(x, y, 8)
      gfx.drawCircleAtPoint(x, y, 9)
    end
    if self.sel == self.cur then
      local prev = self.route[self.sel - 1]
      local kind = prev and PennantUI.vehicleFor(prev.host, s.host) or "bus"
      PennantUI.vehicle(kind, x + 14, y - 14)
    end
  end
  self.info:draw(0, MAP_Y + MAP_H)
  PUI.hintBar("Left/right or crank: stops  B: back")
end

function Map:move(d)
  local n = math.max(1, math.min(#self.route, self.sel + d))
  if n ~= self.sel then self.sel = n self:paintInfo() Sfx.tick() end
end
function Map:leftButtonDown() self:move(-1) end
function Map:rightButtonDown() self:move(1) end
function Map:upButtonDown() self:move(-1) end
function Map:downButtonDown() self:move(1) end
function Map:cranked(c)
  self.acc = (self.acc or 0) + c
  if math.abs(self.acc) >= 30 then self:move(self.acc > 0 and 1 or -1) self.acc = 0 end
end
function Map:BButtonDown() Sfx.back() App.pop() end
function Map:AButtonDown() self.sel = self.cur self:paintInfo() Sfx.select() end
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
  self.kind, self.dist = PennantUI.vehicleFor(self.from, self.to)
  self.dur = math.max(30, math.min(60, math.floor(self.dist / 4)))   -- frames: 1-2 s
  self.f = 0
  self.u = 0
  self.paused = false
  self.map2 = PennantUI.mapImage(2)
  local L = Pennant.L
  local ng = PL.nextGame(L, L.user)
  local away = ng and ng.a == L.user
  local trip = away and PL.roadTripLen(L, L.user) or 0
  self.caption = "To " .. PennantClubs.byAbbr[self.to].city .. " (" .. ({ bus = "by bus", train = "by train", plane = "by air" })[self.kind] .. ")"
    .. (trip >= 6 and (" \u{2022} " .. trip .. "-game road trip") or (not away and " \u{2022} homestand" or ""))
  if Game.settings.reduceMotion and not self.lm then self.u = 1 end
  Sfx.music("turkey_straw", { fade = 0.5 })
end

function Travel:pos(u)
  local ax, ay = cityXY(self.from, 2)
  local bx, by = cityXY(self.to, 2)
  -- a gentle arc for flights
  local lift = self.kind == "plane" and math.sin(u * math.pi) * 30 or 0
  return ax + (bx - ax) * u, ay + (by - ay) * u - lift
end

function Travel:update()
  if not self.paused then
    self.f = self.f + 1
    local e = self.f / self.dur
    self.u = Game.settings.reduceMotion and 1 or math.min(1, e < 1 and (1 - (1 - e) * (1 - e)) or 1)
    if self.lm and not self.lmShown and self.u >= self.lm.t then
      self.lmShown = true
      self.paused = true
      PennantUI.LandmarkCard.open({ lm = self.lm, onDone = function() self.paused = false end })
    end
  end
  local x, y = self:pos(self.u)
  -- camera: centred on the icon, clamped to the map
  local camX = math.max(0, math.min(MAP_W * 2 - 400, x - 200))
  local camY = math.max(0, math.min(MAP_H * 2 - 208, y - 104))
  gfx.clear(gfx.kColorWhite)
  self.map2:draw(-camX, MAP_Y - camY)
  -- the leg so far (solid) and still to go (dashed)
  local ax, ay = cityXY(self.from, 2)
  local bx, by = cityXY(self.to, 2)
  gfx.setDrawOffset(-camX, MAP_Y - camY)
  rail(ax, ay, bx, by, false)
  local steps = 16
  local px, py = ax, ay
  gfx.setLineWidth(3)
  for k = 1, steps do
    local u = self.u * k / steps
    local qx, qy = self:pos(u)
    gfx.drawLine(px, py, qx, qy)
    px, py = qx, qy
  end
  gfx.setLineWidth(1)
  gfx.setDrawOffset(0, 0)
  -- the vehicle at double size, like the map
  local flip = bx < ax
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
  vi:drawScaled(x - camX - 22, y - camY + MAP_Y - 36, 2)
  PUI.topBar("On the road", PUI.rightText())
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 208, 400, 18)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(0, 208, 399, 208)
  Text.draw(self.caption, 200, 210, UI.fonts.bold, nil, "center")
  PUI.hintBar("A: skip")
  if self.u >= 1 and not self.paused then
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
  if self.lm and not self.lmShown then
    self.u = self.lm.t
    self.f = math.floor(self.dur * 0.6)
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
