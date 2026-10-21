--[[ The Road Map, as an X-COM geoscape: a flat-shaded low-poly planet on a starfield (pennant/globe.lua,
  drawn in C by c/globe.c), the club cities on it, and the road trip as thick flat ribbons arcing off
  the ground with their drop shadows. A dark bar on top ("EN ROUTE: <city>", the A verb), an X-COM
  column on the right: ROSTER / LINEUP / STANDINGS / THE WIRE / OPTIONS, the date block (A: the race
  card: the race, the next series, the road trip and road wear), the time-compression buttons (the
  hub's sim verbs) and the crank. The stop panel under the planet says where the selected stop is
  and how the club gets there (pennant/routes.lua: bus / rail / charter, miles, via, time zones).

  The trip draws itself in leg by leg, the camera riding the tip along the great circle and holding
  at each stop; left/right step the season's stops (the camera turns to each), the crank spins the
  planet freely. Static parts (the starfield, the column, the panels, label halos) are cached images;
  per frame only the planet's rotation and light, the ribbons and the markers move.

  Travel (between series): the same planet with the one leg drawing in and a travel card in the
  column. A landmark on the corridor stops the trip on its card (Oregon Trail style); from the air
  it's a "FROM THE WINDOW" line instead.
]]

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

local G = PGlobe
local floor, max, min, sin, cos, pi = math.floor, math.max, math.min, math.sin, math.cos, math.pi

local COL <const> = 291           -- the right column's left edge (106 px wide)
local COL_W <const> = 106

local function ease(x) if x <= 0 then return 0 elseif x >= 1 then return 1 end return x * x * (3 - 2 * x) end

local function commas(n)
  local t = tostring(floor(n))
  local out = t:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  return (out:gsub("^,", ""))
end

--- One fact about a park, for the race card.
local function parkFact(c)
  if c.alt >= 3000 then return c.alt .. " ft up. The ball carries." end
  if (c.walls[1] or 0) >= 20 then return "A " .. c.walls[1] .. "-ft wall in left." end
  if c.fences[1] <= 320 or c.fences[5] <= 320 then return min(c.fences[1], c.fences[5]) .. " ft down the line." end
  if c.fences[3] >= 415 then return c.fences[3] .. " to center. Bring a glove." end
  if c.turf then return "Turf. The grounders skip." end
  return "Fair to everyone. Mostly."
end

function PennantUI.vehicleFor(from, to)
  local r = PRoutes.path(from, to)
  return r.mode, r.miles
end

-- Shared pieces ------------------------------------------------------------------------------------

local Scape = {}
PennantUI.Scape = Scape

--- The starfield, the planet's dark disc and its dotted halo (painted once).
local bgImg
function Scape.background()
  if bgImg then return bgImg end
  bgImg = gfx.image.new(400, 240, gfx.kColorBlack)
  gfx.pushContext(bgImg)
  gfx.setColor(gfx.kColorWhite)
  for ty = 0, 240, 31 do
    for tx = 0, 400, 53 do
      gfx.fillRect(tx + 7, ty + 4, 1, 1) gfx.fillRect(tx + 31, ty + 12, 1, 1)
      gfx.fillRect(tx + 45, ty + 26, 1, 1) gfx.fillRect(tx + 18, ty + 22, 1, 1)
    end
  end
  gfx.setColor(gfx.kColorBlack)
  gfx.fillCircleAtPoint(G.CX, G.CY, G.R + 3)
  -- the halo: a dotted ring 3 px off the limb
  gfx.setColor(gfx.kColorWhite)
  local n = floor(2 * pi * (G.R + 3) / 3)
  for i = 0, n - 1 do
    local a = i / n * 2 * pi
    gfx.fillRect(floor(G.CX + (G.R + 3) * cos(a) + 0.5), floor(G.CY + (G.R + 3) * sin(a) + 0.5), 1, 1)
  end
  gfx.popContext()
  return bgImg
end

--- A label with a light halo (cached per text and weight).
local labelCache = {}
local HALO <const> = { { -1, -1 }, { 0, -1 }, { 1, -1 }, { -1, 0 }, { 1, 0 }, { -1, 1 }, { 0, 1 }, { 1, 1 }, { -2, 0 }, { 2, 0 }, { 0, -2 }, { 0, 2 } }
local function label(t, bold)
  local key = (bold and "B" or "R") .. t
  local img = labelCache[key]
  if img then return img end
  local f = bold and UI.fonts.bold or UI.fonts.body
  local w, h = f:getTextWidth(t), f:getHeight()
  -- the text once, then the halo stamped from it (image draws are cheaper than text draws)
  local ink = gfx.image.new(w, h, gfx.kColorClear)
  gfx.pushContext(ink)
  Text.draw(t, 0, 0, f)
  gfx.popContext()
  img = gfx.image.new(w + 4, h + 4, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  for _, o in ipairs(HALO) do ink:draw(2 + o[1], 2 + o[2]) end
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  ink:draw(2, 2)
  gfx.popContext()
  labelCache[key] = img
  return img
end

-- label anchors from the city (x, baseline-ish y, alignment), as in the concept
Scape.xs, Scape.ys = {}, {}

local LBL <const> = {
  PEM = { 0, 15, "c" }, ELC = { 0, -11, "c" }, STA = { 0, -7, "c" }, CSR = { 0, 12, "c" },
  MRL = { 0, 12, "c" }, MIL = { 7, 12, "l" }, HCL = { 9, 4, "l" }, NCG = { 0, 14, "c" },
}

-- the markers, drawn once into images: the home plate, a trip stop's ring, another club's dot
local marks
local function markImages()
  if marks then return marks end
  marks = {}
  marks.plate = gfx.image.new(16, 17, gfx.kColorClear)
  gfx.pushContext(marks.plate)
  local p = { 2, 2, 14, 2, 14, 9, 8, 15, 2, 9 }
  gfx.setColor(gfx.kColorWhite)
  gfx.fillPolygon(table.unpack(p))
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawPolygon(table.unpack(p))
  gfx.setLineWidth(1)
  gfx.popContext()
  marks.ring = gfx.image.new(13, 13, gfx.kColorClear)
  gfx.pushContext(marks.ring)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillCircleAtPoint(6, 6, 6)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillCircleAtPoint(6, 6, 4)
  gfx.popContext()
  marks.dot = gfx.image.new(9, 9, gfx.kColorClear)
  gfx.pushContext(marks.dot)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillCircleAtPoint(4, 4, 4)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillCircleAtPoint(4, 4, 3)
  gfx.popContext()
  gfx.setColor(gfx.kColorBlack)
  return marks
end

--- Landmark: a small triangle (filled = ahead on the trip, hollow and ticked = seen; the rest stay
--- off the planet until the road takes the club past them).
local function landmarkGlyph(x, y, ahead, seen)
  gfx.setColor(ahead and gfx.kColorBlack or gfx.kColorWhite)
  gfx.fillTriangle(x, y - 4, x - 4, y + 3, x + 4, y + 3)
  gfx.setColor(ahead and gfx.kColorWhite or gfx.kColorBlack)
  gfx.drawTriangle(x, y - 4, x - 4, y + 3, x + 4, y + 3)
  gfx.setColor(gfx.kColorBlack)
  if seen then
    gfx.setLineWidth(2)
    gfx.drawLine(x + 4, y - 1, x + 5, y + 1)
    gfx.drawLine(x + 5, y + 1, x + 8, y - 4)
    gfx.setLineWidth(1)
  end
end

--- The cities and landmarks on the visible side. opts: { stops = { [abbr] = true }, bold = abbr,
--- notes = { [abbr] = "2-1" }, ahead = { [key] = true } }
function Scape.places(opts)
  local L = Pennant.L
  -- landmarks under everything else
  for _, e in ipairs(PLand.LIST) do
    local ahead, seen = opts.ahead and opts.ahead[e.key], L.lmSeen and L.lmSeen[e.key]
    if ahead or seen then
      if not e.glv then e.glv = G.world(G.landmarkLL(e)) end
      local x, y, z = G.proj(e.glv)
      if z > 0.2 then landmarkGlyph(floor(x), floor(y), ahead, seen) end
    end
  end
  local mk = markImages()
  local xs, ys = Scape.xs, Scape.ys
  for i, c in ipairs(PennantClubs) do
    xs[i] = nil
    local x, y, z = G.proj(G.vec(c.abbr))
    if z >= 0.15 then
      x, y = floor(x + 0.5), floor(y + 0.5)
      xs[i], ys[i] = x, y
      if c.abbr == L.user then mk.plate:draw(x - 8, y - 8)
      elseif opts.stops and opts.stops[c.abbr] then mk.ring:draw(x - 6, y - 6)
      else mk.dot:draw(x - 4, y - 4) end
    end
  end
  -- labels last, over the markers
  for i, c in ipairs(PennantClubs) do
    local x, y = xs[i], ys[i]
    if x then
      local note = opts.notes and opts.notes[c.abbr]
      local bold = opts.bold == c.abbr
      -- (the image per club, refetched only when its note or weight changes)
      if c.lblNote ~= note or c.lblBold ~= bold or not c.lblImg then
        c.lblNote, c.lblBold = note, bold
        c.lblImg = label(c.city:upper() .. (note and (" " .. note) or ""), bold)
      end
      local img = c.lblImg
      local o = LBL[c.abbr] or { 0, 12, "c" }
      local w, h = img:getSize()
      local lx = o[3] == "c" and (x + o[1] - w // 2) or (x + o[1] - 2)
      -- (a label running into the column flips to the city's left; clamp the rest on screen)
      if lx + w > COL - 4 then lx = o[3] == "c" and (COL - 4 - w) or (x - o[1] - w + 2) end
      if lx < 0 then lx = 0 end
      img:draw(lx, y + o[2] - h + 4)
    end
  end
end

--- The dark banner along the top: "EN ROUTE: HARBOR CITY" and the A chip.
local barCache = {}
function Scape.banner(text, chip)
  local key = text .. "|" .. (chip or "")
  if barCache.key ~= key then
    local img = gfx.image.new(282, 19, gfx.kColorBlack)
    gfx.pushContext(img)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 0, 282, 19)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(0, 0, 282, 19)
    local cw = chip and UI.fonts.bold:getTextWidth(chip) + 10 or 0
    Text.draw(Text.ellipsize(text, UI.fonts.bold, 270 - cw), 6, Text.boxY(UI.fonts.bold, 3, 13), UI.fonts.bold, "white")
    if chip then
      gfx.fillRect(282 - cw - 3, 3, cw, 13)
      Text.draw(chip, 282 - 3 - cw / 2, Text.boxY(UI.fonts.bold, 3, 13), UI.fonts.bold, nil, "center")
    end
    gfx.setColor(gfx.kColorBlack)
    gfx.popContext()
    barCache.key, barCache.img = key, img
  end
  barCache.img:draw(3, 3)
end

--- The date block: the date, the weekday and year, the club's record and place.
local DOW <const> = { "SUN", "MON", "TUE", "WED", "THU", "FRI", "SAT" }
local function weekday(y, m, d)
  local t = { 0, 3, 2, 5, 0, 3, 5, 1, 4, 6, 2, 4 }
  if m < 3 then y = y - 1 end
  return (y + y // 4 - y // 100 + y // 400 + t[m] + d) % 7 + 1
end
function Scape.dateBlock(x, y, focused)
  local L = Pennant.L
  local T = L.teams[L.user]
  local d = min(L.day, #L.sched)
  local m, day = PL.calendar(d, L)
  gfx.setColor(focused and gfx.kColorWhite or gfx.kColorBlack)
  gfx.fillRect(x, y, COL_W, 50)
  gfx.setColor(focused and gfx.kColorBlack or gfx.kColorWhite)
  gfx.drawRect(x, y, COL_W, 50)
  if focused then gfx.drawRect(x + 2, y + 2, COL_W - 4, 46) end
  local col = not focused and "white" or nil
  Text.draw(PL.date(L, d):upper(), x + COL_W // 2, y + 3, UI.fonts.big, col, "center")
  local yr = (L.year or 1996) + ((L.phase ~= "season" and m < 4) and 1 or 0)
  Text.draw(DOW[weekday(yr, m, day)] .. " \u{2022} " .. yr, x + COL_W // 2, y + 22, UI.fonts.body, col, "center")
  local rec = L.phase == "playoffs" and "PLAYOFFS" or (L.phase == "season" and (L.user .. " " .. T.w .. "-" .. T.l .. " \u{2022} " .. PUI.ord(PL.rank(L, L.user)):upper()) or "OFFSEASON")
  Text.draw(rec, x + COL_W // 2, y + 34, UI.fonts.body, col, "center")
  gfx.setColor(gfx.kColorBlack)
end

--- The crank glyph and its caption.
function Scape.crankGlyph(x, y, l1, l2)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillCircleAtPoint(x, y, 14)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawArc(x, y, 8, 240, 135 + 360)
  gfx.setLineWidth(1)
  gfx.fillTriangle(x - 10, y - 6, x - 7, y - 1, x - 4, y - 6)
  Text.draw(l1, x + 20, y - 13, UI.fonts.body, "white")
  Text.draw(l2, x + 20, y - 2, UI.fonts.body, "white")
end

--- (debug.flag) frame costs per phase, printed when the screen closes: the work in update and the
--- period between frames (the device's real frame time)
local function now() return playdate.getCurrentTimeMilliseconds() end
function Scape.profStart() return PUI.PROF and now() or nil end
--- (debug.flag) the time since the last lap, added to section k
function Scape.lap(self, k)
  if not PUI.PROF then return end
  local t = now()
  self.secs = self.secs or { n = 0 }
  if k then self.secs[k] = (self.secs[k] or 0) + (t - (self.secT or t)) else self.secs.n = self.secs.n + 1 end
  self.secT = t
end
function Scape.profEnd(self, t0, tag)
  if not t0 then return end
  local t1 = now()
  local per = self.profLast and (t1 - self.profLast) or nil
  self.profLast = t1
  self.prof = self.prof or {}
  local s = self.prof[tag] or { n = 0, w = 0, ww = 0, p = 0, pn = 0, pw = 0 }
  self.prof[tag] = s
  s.n, s.w, s.ww = s.n + 1, s.w + (t1 - t0), max(s.ww, t1 - t0)
  if per and per < 250 then s.p, s.pn, s.pw = s.p + per, s.pn + 1, max(s.pw, per) end
end
function Scape.profPrint(self, name)
  for tag, s in pairs(self.prof or {}) do
    print(string.format("[geoperf] %s %-5s frames %4d  work avg %5.1f worst %3d ms  period avg %5.1f worst %3d ms%s", name, tag, s.n,
      s.w / s.n, s.ww, s.pn > 0 and s.p / s.pn or 0, s.pw, globe and string.format("  (globe C %.1f ms, coasts %.1f; %d polys, %d rows, %d px)", globe.ms()) or ""))
  end
  self.prof = nil
  local s = self.secs
  if s and s.n > 0 then
    local parts = {}
    for k, v in pairs(s) do if k ~= "n" then parts[#parts + 1] = string.format("%s %.1f", k, v / s.n) end end
    table.sort(parts)
    print("[geoperf] " .. name .. " sections (ms/frame): " .. table.concat(parts, ", "))
  end
  self.secs = nil
end

--- A light window with a dark title strip (the race card, the wire), painted into an image.
local function windowImg(w, h, title, fn)
  local img = gfx.image.new(w, h, gfx.kColorWhite)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, w, 14)
  Text.draw(title, 5, Text.boxY(UI.fonts.bold, 0, 14, title), UI.fonts.bold, "white")
  gfx.drawRect(0, 0, w, h)
  fn(w, h)
  gfx.popContext()
  return img
end

--- Which landmarks lie on a leg (its corridor on the travel data's own map), added to ahead.
local function landmarksOn(lg, ahead)
  local r = PRoutes.path(lg[1], lg[2])
  if r.mode == "plane" then return end
  local pts = {}
  for i = 1, #r.points, 2 do local x, y = PLand.project(r.points[i], r.points[i + 1]) pts[#pts + 1] = x pts[#pts + 1] = y end
  for _, e in ipairs(PLand.LIST) do
    local x, y = PLand.project(e.ll[1], e.ll[2])
    for k = 1, #pts - 2, 2 do
      if PLand.segDist(x, y, pts[k], pts[k + 1], pts[k + 2], pts[k + 3]) < 6 then ahead[e.key] = e.name break end
    end
  end
end

-- The Road Map screen -------------------------------------------------------------------------------

local Map = { opaque = true }
Map.__index = Map
PennantUI.RoadMap = Map

-- the column: buttons, the date block, time compression
local ITEMS <const> = {
  { id = "roster", label = "ROSTER", y = 5, chip = "A: OPEN", act = function() PennantUI.Team.open({}) end },
  { id = "lineup", label = "LINEUP", y = 25, chip = "A: OPEN", act = function() PennantUI.Lineup.open({}) end },
  { id = "stand", label = "STANDINGS", y = 45, chip = "A: OPEN", act = function() PennantUI.League.open({ tab = "stand" }) end },
  { id = "wire", label = "THE WIRE", y = 65, chip = "A: READ" },
  { id = "options", label = "OPTIONS", y = 85, chip = "A: OPEN", act = function() PennantUI.Hub.optionsMenu() end },
  { id = "date", date = true, y = 107, chip = "A: RACE" },
  { id = "t1", label = "1 DAY", x = 0, y = 162, time = { days = 1 }, chip = "A: GO" },
  { id = "t3", label = "3 DAYS", x = 54, y = 162, time = { days = 3 }, chip = "A: GO" },
  { id = "tstop", label = "TO STOP", x = 0, y = 180, time = { untilSeries = true }, chip = "A: GO" },
  { id = "t7", label = "1 WEEK", x = 54, y = 180, time = { days = 7 }, chip = "A: GO" },
}
local DRAW_MIN <const>, DRAW_MAX <const>, STAY <const> = 18, 36, 10

function Map.open(args)
  local s = setmetatable({}, Map)
  App.push(s, args)
  return s
end

function Map:enter(args)
  local L = Pennant.L
  G.load()
  self.route = PL.route(L, L.user)
  -- the current stop: the first series not finished
  self.cur = #self.route
  for i, s in ipairs(self.route) do if s.done < s.n then self.cur = i break end end
  self.sel = self.cur
  self.focus = 9
  for i, it in ipairs(ITEMS) do if it.id == L.settings.mapFocus then self.focus = i end end
  self.card = nil
  self:setTrip(true)
  self:paintColumn()
  self:paintPanel()
end

function Map:resume()
  self:paintColumn()
  self:paintPanel()
end

--- The trip around the selected stop: from the home stop before it (or from a homestand) out
--- through the road stops and back home. Starts its draw-in.
function Map:setTrip(snap)
  local route, s = self.route, self.sel
  if #route == 0 then
    self.trip = { a = 1, b = 0, legs = {}, away = 0 }
    self.anim = nil
    self:setCam(G.vec(Pennant.L.user))
    return
  end
  local a, b = s, s
  if route[s].home then
    while b < #route and route[b + 1].home do b = b + 1 end
    while b < #route and not route[b + 1].home do b = b + 1 end
    if b < #route then b = b + 1 end
  else
    while a > 1 and not route[a].home do a = a - 1 end
    while b < #route and not route[b].home do b = b + 1 end
  end
  if self.trip and self.trip.a == a and self.trip.b == b then return false end
  local legs, stops, notes, away = {}, {}, {}, 0
  for i = a, b do
    local st = route[i]
    if not st.home then stops[st.host] = true away = away + 1 end
    if st.done > 0 then notes[st.host] = st.w .. "-" .. st.l end
    if i > a and route[i - 1].host ~= st.host then
      local lg = G.leg(route[i - 1].host, st.host)
      legs[#legs + 1] = { leg = lg, i = i, frames = max(DRAW_MIN, min(DRAW_MAX, floor(lg.span * 0.8))) }
    end
  end
  local ll = {}
  for i = max(a + 1, self.cur + 1), b do if route[i - 1].host ~= route[i].host then ll[#ll + 1] = { route[i - 1].host, route[i].host } end end
  -- (the landmarks ahead fill in one leg a frame: a first route search costs a few ms)
  self.trip = { a = a, b = b, legs = legs, stops = stops, notes = notes, away = away, ahead = {}, aheadTodo = ll }
  -- the draw-in: leg k drawing (f frames in), or holding at its end
  if Game.settings.reduceMotion or #legs == 0 then
    self.anim = nil
    self:aimAt(route[s].host, snap)
  else
    self.anim = { k = 1, f = 0, hold = false }
    if snap or self.manual then self:setCam(legs[1].leg.A) end
    self.manual = false
  end
  return true
end

function Map:setCam(v)
  self.cam = v
  self.tween = nil
end

--- Turn the planet to a club's city (eased), or snap.
function Map:aimAt(abbr, snap)
  local v = G.vec(abbr)
  if snap or not self.cam then self:setCam(v) return end
  self.tween = { from = self.cam, to = v, t = 0, n = 14 }
  self.manual = false
end

--- One frame of the draw-in and the camera.
function Map:step()
  local todo = self.trip and self.trip.aheadTodo
  if todo and #todo > 0 then landmarksOn(table.remove(todo, 1), self.trip.ahead) end
  if self.spin then self:cranked(self.spin) end   -- (the tour's perf step: a steady crank)
  local an = self.anim
  if an then
    local lg = self.trip.legs[an.k]
    if not an.hold then
      an.f = an.f + 1
      if an.f >= lg.frames then an.hold, an.f = true, 0 end
    else
      an.f = an.f + 1
      if an.f >= STAY then
        if an.k < #self.trip.legs then an.k, an.f, an.hold = an.k + 1, 0, false
        else
          self.anim = nil
          self:aimAt(self.route[self.sel].host)
        end
      end
    end
    if self.anim and not self.manual then
      local u = an.hold and 1 or ease(an.f / lg.frames)
      self.cam = G.slerp(lg.leg.A, lg.leg.B, u)
    end
  elseif self.tween then
    local tw = self.tween
    tw.t = tw.t + 1
    self.cam = G.slerp(tw.from, tw.to, ease(tw.t / tw.n))
    if tw.t >= tw.n then self.tween = nil end
  end
end

--- The city in view: the tip's end of the leg drawing in, else the selected stop.
function Map:showing()
  local an = self.anim
  if an then
    local lg = self.trip.legs[an.k]
    local u = an.hold and 1 or an.f / lg.frames
    return u > 0.5 and lg.leg.b or lg.leg.a, true
  end
  local s = self.route[self.sel]
  return s and s.host or Pennant.L.user, false
end

--- The column: five buttons, the date block, the time controls, the crank.
function Map:paintColumn()
  -- (opaque, with the starfield behind: an image without a mask draws faster)
  local img = gfx.image.new(400 - COL + 3, 240, gfx.kColorBlack)
  gfx.pushContext(img)
  gfx.setDrawOffset(-COL + 3, 0)
  Scape.background():draw(0, 0)
  for i, it in ipairs(ITEMS) do
    local on = i == self.focus
    if it.date then
      Scape.dateBlock(COL, it.y, on)
    else
      local x, w, h = COL + (it.x or 0), it.time and 52 or COL_W, it.time and 16 or 17
      if on then
        gfx.setColor(gfx.kColorBlack)
        gfx.fillRect(x, it.y, w, h)
        gfx.setColor(gfx.kColorWhite)
        gfx.drawRect(x, it.y, w, h)
      else
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRect(x, it.y, w, h)
        gfx.setColor(gfx.kColorBlack)
        if not it.time then gfx.fillRect(x, it.y + h - 1, w, 1) end
      end
      gfx.setColor(gfx.kColorBlack)
      Text.draw(it.label, x + w // 2, Text.boxY(UI.fonts.bold, it.y + 1, h - 2, it.label), UI.fonts.bold, on and "white" or nil, "center")
    end
  end
  Scape.crankGlyph(COL + 25, 218, "CRANK", "SPINS")
  gfx.setDrawOffset(0, 0)
  gfx.popContext()
  self.column = img
end

--- The stop panel under the planet: the selected stop and how the club gets there.
function Map:paintPanel()
  local L = Pennant.L
  local s = self.route[self.sel]
  -- (drawn in two opaque parts, the tab and the box: no mask)
  local img = gfx.image.new(282, 50, gfx.kColorBlack)
  gfx.pushContext(img)
  local tr = self.trip
  local head = (tr and tr.away > 0) and ("ROAD TRIP \u{2022} " .. tr.away .. (tr.away == 1 and " STOP" or " STOPS")) or "HOMESTAND"
  local hw = UI.fonts.bold:getTextWidth(head) + 10
  self.tabRect = playdate.geometry.rect.new(0, 0, hw, 15)
  self.boxRect = self.boxRect or playdate.geometry.rect.new(0, 14, 282, 36)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, hw, 15)
  gfx.fillRect(0, 14, 282, 36)
  gfx.setColor(gfx.kColorWhite)
  gfx.drawRect(0, 0, hw, 15)
  gfx.drawRect(0, 14, 282, 36)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(1, 14, hw - 2, 1)
  Text.draw(head, 5, Text.boxY(UI.fonts.bold, 1, 13), UI.fonts.bold, "white")
  if s then
    local prev = self.route[self.sel - 1]
    local tag = self.sel == self.cur and "NOW" or (self.sel < self.cur and "PLAYED" or "NEXT")
    local res = s.done == s.n and (" \u{2022} " .. (s.w > s.l and "won " or (s.w < s.l and "lost " or "split ")) .. s.w .. "-" .. s.l) or (s.done > 0 and (" \u{2022} " .. s.w .. "-" .. s.l .. " so far") or "")
    local tw = UI.fonts.bold:getTextWidth(tag) + 6
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(4, 18, tw, 13)
    local l1 = (s.home and "vs " or "at ") .. PUI.nick(s.opp) .. ", " .. PL.date(L, s.d0) .. "-" .. PL.date(L, s.d1):match("%d+$") .. res
    local ty = Text.boxY(UI.fonts.bold, 18, 13)
    Text.draw(tag, 7, ty, UI.fonts.bold)
    Text.draw(Text.ellipsize(l1, UI.fonts.bold, 270 - tw), 8 + tw, ty, UI.fonts.bold, "white")
    local l2
    if prev and prev.host ~= s.host then
      local r = PRoutes.path(prev.host, s.host)
      local via = PRoutes.via(r, 3)
      l2 = PRoutes.MODE_NAME[r.mode] .. " from " .. PennantClubs.byAbbr[prev.host].city .. ", " .. commas(r.miles) .. " mi" .. (#via > 0 and r.mode ~= "plane" and (" via " .. table.concat(via, ", ")) or "")
      local z = PRoutes.zones(prev.host, s.host)
      if z ~= 0 then l2 = l2 .. ((z > 0) and " (back " or " (ahead ") .. math.abs(z) .. " hr)" end
    else
      l2 = "No travel: " .. (prev and "same park as the last series." or "the season starts here.")
    end
    Text.draw(Text.ellipsize(l2, UI.fonts.body, 272), 5, 34, UI.fonts.body, "white")
  else
    Text.draw("No games on the calendar.", 5, 20, UI.fonts.body, "white")
  end
  gfx.popContext()
  self.panel = img
end

--- The race card (the date block's A): the race, the next series, the road trip and road wear,
--- landmarks ahead.
function Map:raceCard()
  local L = Pennant.L
  return windowImg(150, 200, "THE RACE", function(w, h)
    local y = 18
    local function title(t) gfx.fillRect(1, y, w - 2, 13) Text.draw(t, 5, Text.boxY(UI.fonts.bold, y, 13, t), UI.fonts.bold, "white") y = y + 15 end
    if L.phase == "season" then
      for _, e in ipairs(PL.raceWindow(L)) do
        local mine = e.T.abbr == L.user
        if mine then gfx.fillRect(1, y - 1, w - 2, 12) end
        local col = mine and "white" or nil
        local ty = Text.boxY(UI.fonts.bold, y - 1, 12)
        Text.draw(e.rank .. " " .. e.T.abbr, 4, ty, UI.fonts.bold, col)
        Text.draw(e.T.w .. "-" .. e.T.l, 92, ty, UI.fonts.body, col, "right")
        Text.draw(PL.gbText(e.T.gb), w - 5, ty, UI.fonts.body, col, "right")
        if e.rank == 4 then gfx.setPattern(UI.pat.gray) gfx.drawLine(2, y + 10, w - 3, y + 10) gfx.setColor(gfx.kColorBlack) end
        y = y + 12
      end
      Text.draw(PL.raceNumber(L), 4, y + 1, UI.fonts.bold)
      y = y + 16
    else
      Text.draw(L.phase == "playoffs" and "Playoffs" or "Season over", 4, y, UI.fonts.bold)
      y = y + 16
    end
    local g, d = PL.nextGame(L, L.user)
    if g then
      local opp = g.h == L.user and g.a or g.h
      title("NEXT: " .. (g.h == L.user and "vs " or "at ") .. opp)
      local st = self.route[self.cur]
      local n = st and st.n or 1
      Text.draw(PL.date(L, d) .. ", " .. n .. " game" .. (n == 1 and "" or "s"), 4, y - 1, UI.fonts.body)
      local c = PennantClubs.byAbbr[g.h]
      Text.draw(Text.ellipsize(c.park, UI.fonts.body, w - 8), 4, y + 11, UI.fonts.body)
      Text.draw(Text.ellipsize(parkFact(c), UI.fonts.body, w - 8), 4, y + 23, UI.fonts.body)
      y = y + 37
    end
    local away = g and g.a == L.user
    local len = PL.roadTripLen(L, L.user)
    local rs = PL.roadStreak(L, L.user, max(1, L.day - 1))
    if away then title("ROAD TRIP " .. min(max(1, rs + 1), len + rs) .. "/" .. (len + rs))
    else title("HOMESTAND, " .. len .. " games") end
    Text.draw("Road wear", 4, y - 1, UI.fonts.body)
    -- the rule: from the 6th straight road game, a little fatigue every day
    local pips = max(0, min(5, rs - 4))
    for k = 1, 5 do
      local px = 68 + (k - 1) * 9
      if k <= pips then gfx.fillRect(px, y + 2, 7, 7) else gfx.drawRect(px, y + 2, 7, 7) end
    end
    Text.draw(Text.ellipsize(rs >= 6 and "Tired legs: +fatigue daily" or (away and "From game 6: tiring" or "Fresh at home"), UI.fonts.body, w - 8), 4, y + 11, UI.fonts.body)
    y = y + 26
    -- landmarks on the road ahead (the filled triangles on the planet)
    local names = {}
    for _, e in ipairs(PLand.LIST) do if self.trip.ahead and self.trip.ahead[e.key] then names[#names + 1] = e.name end end
    if #names > 0 and y < h - 14 then
      Text.draw(Text.ellipsize("\u{25b2} " .. table.concat(names, ", "), UI.fonts.body, w - 8), 4, y - 1, UI.fonts.body)
    end
  end)
end

--- The wire card: the latest news, newest first.
function Map:wireCard()
  local L = Pennant.L
  return windowImg(276, 178, "THE WIRE", function(w, h)
    local y = 16
    if #L.news == 0 then Text.draw("Nothing on the wire yet.", 5, y, UI.fonts.body) end
    for _, n in ipairs(L.news) do
      local lines = Text.wrap(PL.date(L, min(n.d, #L.sched)) .. ": " .. n.t, n.m and UI.fonts.bold or UI.fonts.body, w - 10)
      if y + #lines * 13 > h - 2 then break end
      for _, ln in ipairs(lines) do
        Text.draw(ln, 5, y, n.m and UI.fonts.bold or UI.fonts.body)
        y = y + 13
      end
      y = y + 2
    end
  end)
end

function Map:update()
  local t0 = Scape.profStart()
  Scape.lap(self)
  PJobs.tick(10)
  self:step()
  Scape.lap(self, "jobs+step")
  Scape.background():draw(0, 0)
  Scape.lap(self, "bg")
  if self.cam then G.lookAt(self.cam) end
  G.render()
  Scape.lap(self, "globe")
  -- the trip's legs: the drawn ones whole, the one drawing to its eased tip, the rest not yet
  local list = {}
  local an = self.anim
  for k, lg in ipairs(self.trip.legs) do
    local frac = 1
    if an then
      if k > an.k then frac = 0
      elseif k == an.k and not an.hold then frac = max(0.01, ease(an.f / lg.frames)) end
    end
    list[#list + 1] = { lg.leg, frac }
  end
  G.drawLegs(list)
  Scape.lap(self, "legs")
  local show, enRoute = self:showing()
  Scape.places({ stops = self.trip.stops, bold = show, notes = self.trip.notes, ahead = self.trip.ahead })
  Scape.lap(self, "places")
  -- the banner
  local it = ITEMS[self.focus]
  local city = PennantClubs.byAbbr[show] and PennantClubs.byAbbr[show].city:upper() or ""
  local head
  if enRoute or self.sel == self.cur then head = (self.route[self.sel] and self.route[self.sel].home and show == Pennant.L.user and not enRoute) and "AT HOME: " or "EN ROUTE: "
  else head = self.sel < self.cur and "PLAYED: " or "NEXT STOP: " end
  Scape.banner(head .. city, self.card and "B: CLOSE" or it.chip)
  self.panel:draw(3, 187, gfx.kImageUnflipped, self.tabRect)
  self.panel:draw(3, 201, gfx.kImageUnflipped, self.boxRect)
  self.column:draw(COL - 3, 0)
  if self.card then self.card:draw(6, 26) end
  Scape.lap(self, "ui")
  Scape.profEnd(self, t0, (self.manual or self.spin) and "spin" or (self.anim and "draw" or (self.tween and "turn" or "still")))
end

function Map:move(d)
  if self.card or #self.route == 0 then return end
  local n = max(1, min(#self.route, self.sel + d))
  if n == self.sel then return end
  self.sel = n
  Sfx.tick()
  local t0 = Scape.profStart()
  if not self:setTrip() then
    self.anim = nil
    self:aimAt(self.route[n].host)
  end
  local t1 = Scape.profStart()
  self:paintPanel()
  if t0 then print(string.format("[geoperf] step to stop %d: trip %d ms, panel %d ms", n, t1 - t0, Scape.profStart() - t1)) end
end

function Map:leftButtonDown() self:move(-1) end
function Map:rightButtonDown() self:move(1) end
function Map:focusBy(d)
  if self.card then return end
  self.focus = (self.focus - 1 + d) % #ITEMS + 1
  Pennant.L.settings.mapFocus = ITEMS[self.focus].id
  Sfx.focus()
  self:paintColumn()
end
function Map:upButtonDown() self:focusBy(-1) end
function Map:downButtonDown() self:focusBy(1) end

function Map:cranked(c)
  -- spin the planet freely (the draw-in goes on; left/right turn back to the stops)
  if not self.cam then return end
  self.manual = true
  self.tween = nil
  local lon, lat = G.toLL(self.cam)
  self.cam = G.world(lon - c / 2, lat)
end

function Map:BButtonDown()
  if self.card then self.card = nil Sfx.back() return end
  Sfx.back()
  App.pop()
end

function Map:AButtonDown()
  local it = ITEMS[self.focus]
  if self.card then self.card = nil Sfx.back() return end
  Sfx.select()
  if it.time then
    -- the time controls are the hub's sim verbs
    local args = {}
    for k, v in pairs(it.time) do args[k] = v end
    App.pop()
    PennantUI.Advance.open(args)
  elseif it.date then self.card = self:raceCard()
  elseif it.id == "wire" then self.card = self:wireCard()
  elseif it.act then it.act() end
end

function Map:exit()
  Scape.profPrint(self, "map")
  self.column, self.panel, self.card = nil, nil, nil
end

-- Travel ----------------------------------------------------------------------------------------------

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
  G.load()
  local r = PRoutes.path(self.from, self.to)
  self.kind = r.mode
  self.leg = G.leg(self.from, self.to)
  -- 1-2 s by the leg's length on the planet
  self.dur = max(30, min(60, floor(self.leg.span * 1.2)))
  self.f = 0
  self.u = 0
  self.paused = false
  self.cam = self.leg.A
  if Game.settings.reduceMotion and not self.lm then self.u = 1 end
  self:paintCard(r)
  Sfx.music("turkey_straw", { fade = 0.5 })
end

--- The travel card in the column: how, how far, which way, the clock, the trip.
function Travel:paintCard(r)
  local L = Pennant.L
  local ng = PL.nextGame(L, L.user)
  local away = ng and ng.a == L.user
  local trip = away and PL.roadTripLen(L, L.user) or 0
  local z = PRoutes.zones(self.from, self.to)
  -- (opaque, with the starfield behind: an image without a mask draws faster)
  local img = gfx.image.new(400 - COL + 3, 240, gfx.kColorBlack)
  gfx.pushContext(img)
  gfx.setDrawOffset(-COL + 3, 0)
  Scape.background():draw(0, 0)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(COL, 5, COL_W, 97)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(COL, 5, COL_W, 17)
  Text.draw(self.kind == "plane" and "BY AIR" or (self.kind == "train" and "BY RAIL" or "BY BUS"), COL + COL_W // 2, 6, UI.fonts.bold, "white", "center")
  local y = 24
  local function line(t, f) Text.draw(Text.ellipsize(t, f or UI.fonts.body, COL_W - 8), COL + 4, y, f or UI.fonts.body) y = y + 12 end
  line("to " .. PennantClubs.byAbbr[self.to].city, UI.fonts.bold)
  line(commas(r.miles) .. " mi")
  local via = self.kind ~= "plane" and PRoutes.via(r, 2) or {}
  for i, v in ipairs(via) do line((i == 1 and "via " or "    ") .. v) end
  if z ~= 0 then line((z > 0 and "back " or "ahead ") .. math.abs(z) .. " hour" .. (math.abs(z) > 1 and "s" or "")) end
  if trip >= 6 then line(trip .. "-game trip") elseif not away then line("homestand") end
  Scape.dateBlock(COL, 107, false)
  gfx.setDrawOffset(0, 0)
  gfx.popContext()
  self.card = img
end

function Travel:update()
  local t0 = Scape.profStart()
  if not self.paused then
    self.f = self.f + 1
    self.u = Game.settings.reduceMotion and 1 or min(1, self.f / self.dur)
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
  local e = ease(self.u)
  self.cam = G.slerp(self.leg.A, self.leg.B, e)
  Scape.background():draw(0, 0)
  G.lookAt(self.cam)
  G.render()
  G.drawLegs({ { self.leg, max(0.01, e) } })
  self.stopSet = self.stopSet or { [self.to] = true, [self.from] = true }
  Scape.places({ stops = self.stopSet, bold = e > 0.5 and self.to or self.from })
  Scape.banner("EN ROUTE: " .. PennantClubs.byAbbr[self.to].city:upper(), "A: SKIP")
  self.card:draw(COL - 3, 0)
  Scape.profEnd(self, t0, "leg")
  -- a window sighting
  if self.windowT then
    self.windowT = self.windowT + 1
    if self.windowT < 75 then
      local bx, by, bw = 6, 168, 276
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
  if self.u >= 1 and not self.paused and (not self.windowT or self.windowT >= 75) then
    self.hold = (self.hold or 0) + 1
    if self.hold > 12 then self:finish() end
  end
end

function Travel:finish()
  if self.closed then return end
  self.closed = true
  Scape.profPrint(self, "travel")
  App.pop()
  if self.onDone then self.onDone() end
end

function Travel:AButtonDown()
  if self.lm and not self.lmShown and not self.lm.window then
    self.u = self.lm.t
    self.f = floor(self.dur * self.lm.t)
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
