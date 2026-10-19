-- BallCast bleacher cam: a crowd shot (two pre-rendered frames: sitting / on their feet)
-- with incident overlays (raccoons, rain, laser, blackout, a fan on the loose...).

import "ballcast/kit"
import "ballcast/puppets"

local gfx <const> = playdate.graphics
local floor <const>, sin <const> = math.floor, math.sin

BallCast = BallCast or {}
local C = {}
BallCast.Crowd = C
local K = BCKit

local frames = nil

local SIGNS = { "DEADBALL!", "K", "HAL IS INNOCENT", "BEER ME", "HI MOM", "RAT", "%s!!", "FIRE THE UMP", "4-6-3", "EELS?" }

local function drawFan(x, y, s, standing, seed)
  -- head + shoulders bust, scale s (1 = front row)
  local hr = 6 * s
  local sh = 12 * s
  local body = K.hash01(seed, 1)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRoundRect(x - sh - 1, y + hr - 1, sh * 2 + 2, 30 * s, 4 * s)
  if body < 0.33 then gfx.setColor(gfx.kColorWhite)
  elseif body < 0.66 then gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
  else gfx.setColor(gfx.kColorBlack) end
  gfx.fillRoundRect(x - sh, y + hr, sh * 2, 30 * s, 4 * s)
  if standing then
    -- arms up
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(math.max(1, floor(3 * s)))
    local wave = K.hash01(seed, 4) * 6
    gfx.drawLine(x - sh + 2, y + hr + 4 * s, x - sh - 4 * s, y - 10 * s - wave)
    gfx.drawLine(x + sh - 2, y + hr + 4 * s, x + sh + 4 * s, y - 10 * s - wave)
    gfx.setLineWidth(1)
  end
  gfx.setColor(gfx.kColorBlack)
  gfx.fillCircleAtPoint(x, y, hr + 1)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillCircleAtPoint(x, y, hr)
  gfx.setColor(gfx.kColorBlack)
  local hat = K.hash01(seed, 2)
  if hat < 0.45 then
    gfx.fillRect(x - hr - 1, y - hr * 0.4, hr * 2 + 2, 2 * s)
    gfx.fillRect(x - hr * 0.7, y - hr * 1.2, hr * 1.4, hr * 0.85)
  elseif hat < 0.7 then
    gfx.fillRect(x - hr, y - hr, hr * 2, hr * 0.7)
  end
  -- eyes / open mouth when standing
  gfx.fillRect(x - hr * 0.4, y, math.max(1, s), math.max(1, s))
  gfx.fillRect(x + hr * 0.3, y, math.max(1, s), math.max(1, s))
  if standing then gfx.fillCircleAtPoint(x, y + hr * 0.5, math.max(1, 1.5 * s)) end
end

local function render(standing, teamAbbr)
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  -- back wall / upper deck shadow
  gfx.setPattern({ 0x00, 0x44, 0x00, 0x11, 0x00, 0x44, 0x00, 0x11 })
  gfx.fillRect(0, 0, 400, 70)
  -- rows, back to front
  local rows = { { y = 58, s = 0.55, n = 16 }, { y = 88, s = 0.7, n = 13 }, { y = 124, s = 0.85, n = 11 }, { y = 166, s = 1.05, n = 9 }, { y = 214, s = 1.3, n = 7 } }
  for ri, r in ipairs(rows) do
    -- bench
    gfx.setPattern({ 0xFF, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF })
    gfx.fillRect(0, r.y + 14 * r.s, 400, 8 * r.s)
    local step = 400 / r.n
    for i = 0, r.n do
      local seed = ri * 100 + i
      local up = standing and K.hash01(seed, 9) < 0.75
      local x = i * step + (ri % 2) * step / 2 + (K.hash01(seed, 3) - 0.5) * 8
      local y = r.y + (up and -8 * r.s or 0)
      drawFan(x, y, r.s, up, seed)
    end
  end
  -- a sign in row 3
  local sign = SIGNS[1 + floor(K.hash01(teamAbbr or "x", 5) * #SIGNS)]
  sign = string.format(sign, teamAbbr or "GO")
  local f = K.fonts.nb
  local w = f:getTextWidth(sign) + 10
  local sx = 230
  local sy = standing and 92 or 100
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(sx - 1, sy - 1, w + 2, 20)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(sx, sy, w, 18)
  f:drawText(sign, sx + 5, sy + 3)
  -- front rail
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 228, 400, 3)
  gfx.popContext()
  return img
end

function C.ensure(teamAbbr)
  if not frames then
    frames = { calm = render(false, teamAbbr), up = render(true, teamAbbr) }
  end
end


---------------------------------------------------------------------------
-- real crowd photos (assets agent: images/crowd/*.png, 400x240 cutaways). Pre-scaled by
-- 4% once so a slow pan/drift never shows an edge.

local photos = nil      -- list of { name, path }
local photoCache = {}   -- path → scaled image

local function listPhotos()
  if photos then return photos end
  photos = {}
  -- prefer the manifest (kinds: cheering grandstand packed bleachers rooftop street scoreboard fans)
  local man = K.readJson("images/crowd/crowd.json")
  if man and man.backdrops then
    for _, b in ipairs(man.backdrops) do
      local path = b.file and b.file:gsub("%.png$", "")
      if path then photos[#photos + 1] = { name = (b.kind or "") .. ":" .. (b.name or ""), path = path, banner = b.banner } end
    end
    return photos
  end
  local ok, files = pcall(playdate.file.listFiles, "images/crowd/")
  if ok and files then
    for _, f in ipairs(files) do
      local base = f:match("^(.-)%.pdi$") or f:match("^(.-)%.png$")
      if base and not base:find("tex") and not base:find("tile") then
        photos[#photos + 1] = { name = base, path = "images/crowd/" .. base }
      end
    end
    table.sort(photos, function(a, b) return a.name < b.name end)
  end
  return photos
end

local WANT = {
  cheer = { "cheering", "packed", "fans" }, RAIN_DELAY = { "rooftop", "street" }, BLACKOUT = { "street" },
  RACCOONS_BULLPEN = { "bleachers" }, RACCOON_ON_FIELD = { "bleachers" }, FAN_ON_FIELD = { "bleachers", "cheering" },
  BRAWL = { "packed", "grandstand" }, LASER_POINTER = { "bleachers" }, FOOD_POISONING = { "grandstand" },
  BALL_TAMPERING = { "grandstand" }, EJECTION = { "packed" }, final = { "street", "scoreboard", "rooftop" },
  calm = { "grandstand", "bleachers", "fans" },
}

local picked = {}   -- "cheer|incident|seed" → image|false (no per-frame candidate lists)
local function pickPhoto(cheer, incident, seed)
  local key = (cheer and "1" or "0") .. "|" .. (incident or "") .. "|" .. tostring(seed)
  local hit = picked[key]
  if hit ~= nil then return hit or nil end
  local list = listPhotos()
  if #list == 0 then return nil end
  local want = WANT[incident or ""] or (cheer and WANT.cheer) or WANT.calm
  local cands = {}
  for _, p in ipairs(list) do
    for _, w in ipairs(want) do if p.name:find(w) then cands[#cands + 1] = p break end end
  end
  if #cands == 0 then cands = list end
  local p = cands[1 + floor(K.hash01(seed or "x", 13) * #cands) % #cands]
  local img = photoCache[p.path]
  if img == nil then
    -- (no 4% pre-scale any more: a 400x240 scale was a big one-frame stall on the device;
    -- the drift's exposed edge is filled with a mirrored copy instead, see C.draw)
    img = K.image(p.path) or false
    photoCache[p.path] = img
  end
  picked[key] = img
  return img or nil
end

--- Load (and pre-scale) the photo a bleacher shot will use, ahead of time (the loader calls
--- this so the cut to the stands doesn't stall on a PNG load + scale).
function C.warm(cheer, incident, seed) pickPhoto(cheer, incident, seed) end

--- Draw the bleacher cam. cheer: crowd on its feet. incident: LogEv inc kind. seed: varies the photo per beat.
function C.draw(tau, cheer, incident, teamAbbr, seed, react, rage)
  local photo = pickPhoto(cheer, incident, seed)
  if photo and incident ~= "BLACKOUT" then
    -- slow push + drift; a 1 px bounce when they're on their feet
    local dx = floor(-7 + math.min(6, tau * 2.2) + sin(tau * 0.7) * 1.5)
    local dy = -4 + ((cheer and floor(tau * 8) % 2 == 1) and 1 or 0)
    photo:draw(dx, dy)
    -- the strip the drift uncovers on the right: the photo mirrored, so the seam matches
    local pw = photo:getSize()
    if dx + pw < 400 then photo:draw(dx + pw, dy, gfx.kImageFlippedX) end
    C.overlay(tau, incident)
    C.puppets(tau, cheer, incident)
    C.shouts(react, rage, seed)
    return
  end
  C.ensure(teamAbbr)
  local img = frames.calm
  local bob = 0
  if cheer then
    img = (floor(tau * 5) % 2 == 0) and frames.up or frames.calm
    bob = (floor(tau * 10) % 2)
  end
  if incident == "BLACKOUT" then
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 0, 400, 240)
    -- lighters and flicker
    if floor(tau * 7) % 9 == 0 then img:draw(0, 0); gfx.setDitherPattern(0.2); gfx.fillRect(0, 0, 400, 240); gfx.setColor(gfx.kColorBlack) end
    gfx.setColor(gfx.kColorWhite)
    for i = 1, 24 do
      local x = K.hash01(i, 1) * 400
      local y = 60 + K.hash01(i, 2) * 170
      if (floor(tau * 4 + i) % 5) ~= 0 then gfx.fillRect(x, y, 2, 3) end
    end
    return
  end
  img:draw(0, bob)
  C.overlay(tau, incident)
  C.puppets(tau, cheer, incident)
  C.shouts(react, rage, seed)
end

--- crowd-text pops in the stands for the latest canned reaction ("OOOH", "BOO!")
local WORDS = {
  c_ooh = { "OOOOH!", "OHHH!" }, c_groan = { "AWWW...", "NOOO" }, c_cheer = { "YEAH!", "WOO!", "ATTABOY!" },
  c_boo = { "BOO!", "BOOOO!", "BUM!" }, c_roar = { "WOOOO!", "YAAAH!", "GONE!" }, c_applause = { "*CLAP*", "BRAVO!" },
  c_clap = { "*CLAP*", "OK!" }, c_murmur = { "huh?", "hmm..." },
}
local shoutCache = {}
local function shoutImg(text)
  local img = shoutCache[text]
  if img then return img end
  local f = K.fonts.nb
  local w, h = f:getTextWidth(text) + 10, f:getHeight() + 6
  img = gfx.image.new(w + 2, h + 6, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRoundRect(0, 0, w, h, 4)
  gfx.fillTriangle(6, h - 1, 14, h - 1, 4, h + 5)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRoundRect(0, 0, w, h, 4)
  gfx.setLineWidth(1)
  gfx.drawLine(6, h, 4, h + 5); gfx.drawLine(4, h + 5, 14, h)
  f:drawText(text, 5, 3)
  gfx.popContext()
  shoutCache[text] = img
  return img
end
function C.shouts(react, age, seed)
  local words = react and WORDS[react]
  if not words or age > 2.2 then return end
  for i = 1, 3 do
    local t0 = (i - 1) * 0.22                       -- they pop in one after another
    if age >= t0 then
      local w = words[1 + (i + floor((seed or 0) * 7)) % #words]
      local img = shoutImg(w)
      local x = 30 + ((i * 131 + (seed or 0) * 37) % 300)
      local y = 34 + ((i * 53 + (seed or 0) * 11) % 70)
      local bob = (floor((age - t0) * 6) % 2 == 0) and 0 or -2
      img:draw(floor(x), floor(y + bob))
    end
  end
end

--- foreground animatic puppets: front-row fans + the mascot when they're on their feet,
--- the streaker legging it across the front of the stands
local FRONT = { { 34, false, 0 }, { 118, false, 2 }, { 292, true, 0 }, { 374, true, 2 } }
function C.puppets(tau, cheer, incident)
  local Pup = BallCast.Puppets
  if incident == "FAN_ON_FIELD" then
    Pup.drawTrack2D("fan", "streaker", tau, ((tau * 150) % 560) - 70, 242, false, 91)
    return
  end
  if not cheer then return end
  for i = 1, #FRONT do
    local f = FRONT[i]
    Pup.drawTrack2D("fan", "fan_cheer", tau + i * 0.27, f[1], 262, f[2], 900 + i, f[3])
  end
  Pup.drawTrack2D("home", "mascot_wave", tau, 206, 256, false, 950)
end

--- incident overlays shared by the photo and drawn crowd shots
function C.overlay(tau, incident)
  if incident == "RAIN_DELAY" then
    gfx.setColor(gfx.kColorWhite)
    local off = floor(tau * 260) % 40
    for i = 0, 60 do
      local x = (i * 37) % 440 - 20
      local y = ((i * 53) % 240) + off - 40
      gfx.setColor(gfx.kColorBlack)
      gfx.drawLine(x, y, x - 4, y + 12)
      gfx.setColor(gfx.kColorWhite)
      gfx.drawLine(x + 1, y, x - 3, y + 12)
    end
    -- umbrellas
    gfx.setColor(gfx.kColorBlack)
    for i = 0, 4 do
      local x = 40 + i * 80 + K.hash01(i, 7) * 20
      gfx.fillEllipseInRect(x - 22, 100 + (i % 2) * 50, 44, 18)
      gfx.drawLine(x, 110 + (i % 2) * 50, x, 140 + (i % 2) * 50)
    end
  elseif incident == "LASER_POINTER" then
    local tx = 200 + sin(tau * 3) * 120
    local ty = -10
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(3)
    gfx.drawLine(96, 150, tx, ty)
    gfx.setColor(gfx.kColorWhite)
    gfx.setLineWidth(1)
    gfx.drawLine(96, 150, tx, ty)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillCircleAtPoint(96, 150, 5)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(96, 150, (floor(tau * 8) % 2) + 2)
  elseif incident == "RACCOONS_BULLPEN" or incident == "RACCOON_ON_FIELD" then
    for i = 0, 2 do
      local x = ((tau * 140 + i * 130) % 520) - 60
      local frame = (floor(tau * 10 + i) % 2 == 0) and "raccoon1" or "raccoon2"
      BallCast.Puppets.drawAt("critter", frame, x, 226 - i * 2, 12, false)
    end
  elseif incident == "FOOD_POISONING" then
    gfx.setColor(gfx.kColorBlack)
    for i = 0, 5 do
      local x = 50 + i * 60
      local y = 160 - (tau * 20 + i * 9) % 40
      gfx.drawLine(x, y, x + 4, y - 6); gfx.drawLine(x + 4, y - 6, x, y - 12); gfx.drawLine(x, y - 12, x + 4, y - 18)
    end
  elseif incident == "FAN_ON_FIELD" then
    -- the fans cheer him on; nothing extra
  end
end

-- (defined last so it resets the module locals above, not globals)
function C.release() frames = nil; photoCache = {}; photos = nil; picked = {} end
