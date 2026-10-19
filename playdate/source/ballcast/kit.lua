-- BCKit: helpers shared by BallCast and Cards (fonts, net shim, faces, text, synth).
-- Owned by the ballcast agent. Everything here is lazy and allocation-light.

-- ONE instance per session: the shell runs ballcast/ and cards/ as separate bundles
-- (app/optional.lua) and both import us; a second run would rebind every helper with fresh
-- caches (fonts/sounds loaded twice) while earlier modules keep the first closures.
if BCKit and BCKit.__loaded then return end

import "CoreLibs/graphics"
import "ui/packs"

local gfx <const> = playdate.graphics
local snd <const> = playdate.sound

BCKit = BCKit or {}
local K = BCKit
K.__loaded = true

K.DEBUG = K.DEBUG or false

---------------------------------------------------------------------------
-- fonts
local fontPaths = {
  tiny  = "ballcast/fonts/Quickboot-7-Medium",
  mono  = "ballcast/fonts/Roobert-9-Mono-Condensed",
  bold  = "ballcast/fonts/Roobert-10-Bold",
  nb    = "ballcast/fonts/Nontendo-Bold",
  nl    = "ballcast/fonts/Nontendo-Light",
  big   = "ballcast/fonts/Nontendo-Bold-2x",
  slab  = "ballcast/fonts/Sasser-Slab-Bold",
  caps  = "ballcast/fonts/Sasser-Small-Caps",
  serif = "ballcast/fonts/Newsleak-Serif",
  serifb = "ballcast/fonts/Newsleak-Serif-Bold",
  bitmore = "ballcast/fonts/Bitmore",
  slabr = "ballcast/fonts/Sasser-Slab",
  wordart = "ballcast/fonts/Deadball-WordArt",
}
-- faces with no "\u{2026}" glyph (it draws as nothing): K.fit cuts them with "..." instead
K.NO_ELLIPSIS = { tiny = true, mono = true, nb = true, nl = true, big = true, caps = true, bitmore = true, wordart = true }
K.noEllipsis = setmetatable({}, { __mode = "k" })
K.fonts = setmetatable({}, { __index = function(t, k)
  local p = fontPaths[k]
  local f = nil
  -- the plain SDK Nontendo faces lack glyphs we print: Light has no apostrophe ("can't" drew as
  -- "cant"), Bold no "+" ("CASHED +$99" drew as "CASHED$99"). In the shell, use its composites
  -- (ui/theme.lua: the same faces plus the missing glyphs).
  local shell = UI and UI.fonts
  if k == "nl" and shell and shell.body and shell.body.base then f = shell.body end
  if k == "nb" and shell and shell.bold and shell.bold.base then f = shell.bold end
  if p and not f then
    -- prefer the shared copy in fonts/ (assets agent) when it exists
    local shared = "fonts/" .. p:match("([^/]+)$")
    if playdate.file.exists(shared .. ".pft") or playdate.file.exists(shared .. ".fnt") then f = gfx.font.new(shared) end
    if not f then f = gfx.font.new(p) end
  end
  if not f then f = gfx.getSystemFont() end
  if K.NO_ELLIPSIS[k] and not f.base then K.noEllipsis[f] = true end
  rawset(t, k, f)
  return f
end })

-- Some SDK fonts have no "$": draw it with a font that does, vertically centred.
local noDollar = setmetatable({}, { __mode = "k" })
local function lacksDollar(font)
  local v = noDollar[font]
  if v == nil then
    v = font:getTextWidth("$") <= font:getTextWidth("") + 0
    noDollar[font] = v
  end
  return v
end

local function dollarFont(font)
  local h = font:getHeight()
  if h >= 20 then return K.fonts.slab end
  return K.fonts.bold
end

local function textWidth(font, s)
  if not s:find("$", 1, true) or not lacksDollar(font) then return font:getTextWidth(s) end
  local df = dollarFont(font)
  local w = 0
  for part, d in s:gmatch("([^$]*)(%$?)") do
    w = w + font:getTextWidth(part)
    if d ~= "" then w = w + df:getTextWidth("$") + 1 end
  end
  return w
end
K.textWidth = textWidth

--- Draw text with a font, no *bold* parsing. align: nil/"left", "center", "right".
function K.text(font, s, x, y, align)
  s = tostring(s)
  if align == "center" then
    x = x - textWidth(font, s) // 2
  elseif align == "right" then
    x = x - textWidth(font, s)
  end
  if not s:find("$", 1, true) or not lacksDollar(font) then
    font:drawText(s, x, y)
    return
  end
  local df = dollarFont(font)
  local dy = (font:getHeight() - df:getHeight()) // 2
  for part, d in s:gmatch("([^$]*)(%$?)") do
    if part ~= "" then font:drawText(part, x, y); x = x + font:getTextWidth(part) end
    if d ~= "" then df:drawText("$", x, y + dy); x = x + df:getTextWidth("$") + 1 end
  end
end

--- White text (for black boxes).
function K.textW(font, s, x, y, align)
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  K.text(font, s, x, y, align)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
end

--- Greedy word wrap into a list of lines.
function K.wrap(font, s, width)
  local lines, line = {}, ""
  for word in string.gmatch(s or "", "%S+") do
    local try = line == "" and word or (line .. " " .. word)
    if font:getTextWidth(try) > width and line ~= "" then
      lines[#lines + 1] = line
      line = word
    else
      line = try
    end
  end
  if line ~= "" then lines[#lines + 1] = line end
  return lines
end

--- Fit a string into width by trimming with an ellipsis ("..." in faces without the glyph).
function K.fit(font, s, width)
  if font:getTextWidth(s) <= width then return s end
  local ell = K.noEllipsis[font] and "..." or "…"
  while #s > 1 and font:getTextWidth(s .. ell) > width do s = s:sub(1, -2) end
  -- (never end on half a UTF-8 sequence or a dangling space)
  while #s > 1 and (s:byte(#s) or 0) >= 0x80 and (s:byte(#s) or 0) < 0xC0 do s = s:sub(1, -2) end
  if #s > 1 and (s:byte(#s) or 0) >= 0xC0 then s = s:sub(1, -2) end
  return (s:gsub("%s+$", "")) .. ell
end

--- Fit-or-shorten for nameplates: `s` in the first of `fonts` it fits (largest first), else
--- each of `shorts` (e.g. the surname alone) the same way, else cut with an ellipsis in the
--- last font. Returns the text and its font.
function K.fitChain(fonts, s, width, shorts)
  local cands = { s }
  for _, c in ipairs(shorts or {}) do cands[#cands + 1] = c end
  for _, c in ipairs(cands) do
    for _, f in ipairs(fonts) do
      if f:getTextWidth(c) <= width then return c, f end
    end
  end
  local f = fonts[#fonts]
  return K.fit(f, cands[#cands], width), f
end

--- A name that fits: the whole name, then "F. LAST", each in font and then in the narrower alt
--- font, and only then cut. Returns font, text.
function K.fitName(font, alt, full, width, upper)
  full = full or ""
  if upper then full = string.upper(full) end
  local first, last = full:match("^(%S+)%s+(.+)$")
  local short = first and (first:sub(1, 1) .. ". " .. last) or full
  for _, f in ipairs({ font, alt }) do
    if f then
      if f:getTextWidth(full) <= width then return f, full end
      if f:getTextWidth(short) <= width then return f, short end
    end
  end
  local f = alt or font
  return f, K.fit(f, last or full, width)
end

function K.money(n)
  n = math.floor(tonumber(n) or 0)
  local neg = n < 0
  local s = tostring(math.abs(n))
  local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
  if out:sub(1, 1) == "," then out = out:sub(2) end
  return (neg and "-$" or "$") .. out
end

function K.lastName(name)
  if not name then return "?" end
  return name:match("(%S+)$") or name
end

function K.clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end
function K.lerp(a, b, t) return a + (b - a) * t end

--- Cheap deterministic hash of a string → 0..1.
function K.hash01(s, salt)
  -- small-number hash: safe with the Playdate's 32-bit Lua numbers
  local h = 7919 + (salt or 0) * 131
  s = tostring(s)
  for i = 1, #s do
    h = (h * 131 + s:byte(i)) % 65521
  end
  h = (h * 2654 + 40503) % 65521
  return h / 65521
end

---------------------------------------------------------------------------
-- networking shim: prefer the shell's Api; fall back to dev fixtures.

local DEV = "fixtures_dev/ballcast/"

local function readJson(path)
  local d = Packs.json(path)  -- loose file or the build's packed fixtures (ui/packs.lua)
  -- dev: worst-case strings for layout QA (net/stress.lua; only with stress.flag in the Simulator)
  if d and Stress and Stress.on then Stress.apply(path, d) end
  return d
end
K.readJson = readJson

-- path pattern → candidate fixture files (first that exists wins)
local routes = {
  -- "dev" game id: always the ballcast agent's own fixture (incidents, a brawl, HRs)
  { "^/games/dev/log%?.*fmt=c", { DEV .. "game-logc.json" } },
  { "^/games/ultra/log%?.*fmt=c", { DEV .. "game-logc-ultra.json" } },
  { "^/games/[^/]+/log%?.*fmt=c", { "fixtures/game-logc.json", DEV .. "game-logc.json" } },
  { "^/games/dev%?", { DEV .. "game.json" } },
  { "^/games/ultra%?", { DEV .. "game.json" } },
  { "^/games/[^/]+%?lite=1", { "fixtures/game-lite.json", "fixtures/game.json", DEV .. "game.json" } },
  { "^/games/dev/log", { DEV .. "game-log.json" } },
  -- "ultra": the dev replay with Enhanced League power events spliced in (tools/make_ultra_fixture.py)
  { "^/games/ultra/log", { DEV .. "game-log-ultra.json" } },
  { "^/games/ultra/wire", { DEV .. "wire.json" } },
  { "^/games/ultra$", { DEV .. "game.json" } },
  { "^/games/dev/wire", { DEV .. "wire.json" } },
  { "^/games/dev$", { DEV .. "game.json" } },
  { "^/games/[^/]+/log", { "fixtures/game-log.json", DEV .. "game-log.json" } },
  { "^/games/[^/]+/wire", { "fixtures/game-wire.json", "fixtures/wire.json", DEV .. "wire.json" } },
  { "^/games/[^/]+$", { "fixtures/game.json", "fixtures/game-detail.json", DEV .. "game.json" } },
  { "^/shop", { "fixtures/shop.json", DEV .. "shop.json" } },
  { "^/cards/", { "fixtures/card.json", DEV .. "card.json" } },
  { "^/cards", { "fixtures/cards.json", DEV .. "cards.json" } },
  { "^/watchlist", { "fixtures/watchlist.json" } },
  { "^/market/history", { "fixtures/price-history.json" } },
  { "^/market/[^/?]+$", { "fixtures/market-auction.json" } },
  { "^/bulletins", { "fixtures/bulletins.json" } },
  { "^/market", { "fixtures/market.json" } },
  { "^/me", { "fixtures/me.json", DEV .. "me.json" } },
  { "^/today", { "fixtures/today.json", DEV .. "today.json" } },
}

function K.fixture(path)
  if path:find("cursor=") then return { cards = {}, listings = {}, stories = {} } end
  for _, r in ipairs(routes) do
    if string.find(path, r[1]) then
      for _, f in ipairs(r[2]) do
        local d = readJson(f)
        if d then return d end
      end
    end
  end
  return nil
end

-- Local fallbacks for writes while offline (so pack opening etc. can be tested).
K.offlinePost = K.offlinePost or {}

local function deliver(cb, err, data)
  -- always async-ish so callers can rely on state set after the call
  playdate.timer.performAfterDelay(1, function() cb(err, data) end)
end

function K.get(path, cb, opts)
  -- a local game source (offline modes such as Pennant: BallCast.scene args.source) answers
  -- every request while it's set; nothing goes to the network
  if K.source and K.source.get then
    local data, err = K.source:get(path)
    if data ~= nil then deliver(cb, nil, data) else deliver(cb, err or { error = "not_found", message = "not in the local game" }, nil) end
    return
  end
  if Api and Api.get then
    Api.get(path, function(err, data)
      if err and not data then
        local fx = K.fixture(path)
        if fx then cb(nil, fx) return end
      end
      cb(err, data)
    end, opts)
    return
  end
  local fx = K.fixture(path)
  if fx then deliver(cb, nil, fx) else deliver(cb, { error = "not_found", message = "no fixture for " .. path }, nil) end
end

local function offlineWrite(method, path, body, cb)
  for pat, fn in pairs(K.offlinePost) do
    if string.find(method .. " " .. path, pat) then
      local ok, res = pcall(fn, path, body)
      if ok and res then deliver(cb, nil, res) return true end
    end
  end
  return false
end

--- offline write fallbacks only when we're not talking to a real server
function K.offlineOK()
  if Api and Api.isFixtureMode then
    local ok, v = pcall(Api.isFixtureMode)
    return ok and v
  end
  return true
end

function K.post(path, body, cb)
  if Api and Api.post then
    Api.post(path, body or {}, function(err, data)
      if err and not data and K.offlineOK() and offlineWrite("POST", path, body, cb) then return end
      cb(err, data)
    end)
    return
  end
  if not offlineWrite("POST", path, body, cb) then
    deliver(cb, { error = "offline", message = "No connection." }, nil)
  end
end

function K.delete(path, cb)
  local fn = Api and (Api.delete or Api.del)
  if fn then
    fn(path, function(err, data)
      if err and not data and K.offlineOK() and offlineWrite("DELETE", path, nil, cb) then return end
      cb(err, data)
    end)
    return
  end
  if Api and Api.request then
    Api.request("DELETE", path, nil, cb)
    return
  end
  if not offlineWrite("DELETE", path, nil, cb) then
    deliver(cb, { error = "offline", message = "No connection." }, nil)
  end
end

--- Load an image only if it exists in the pdx (no console noise when assets are missing).
function K.image(path)
  if playdate.file.exists(path .. ".pdi") or playdate.file.exists(path .. ".png") then
    return gfx.image.new(path)
  end
  return nil
end

---------------------------------------------------------------------------
-- faces: images/faces/<n>-48|96.png (packed, see ui/packs.lua), placeholder silhouettes until they land

local faceCache = {}
local placeholderCache = {}

local function faceNum(face)
  if type(face) == "number" then return face end
  return tonumber(tostring(face or ""):match("(%d+)")) or 0
end
K.faceNum = faceNum

local function placeholderFace(n, size)
  local key = n * 1000 + size
  local img = placeholderCache[key]
  if img then return img end
  local w, h = size, size
  img = gfx.image.new(w, h, gfx.kColorWhite)
  gfx.pushContext(img)
  local r = K.hash01(n, 7)
  -- backdrop: studio dither
  gfx.setDitherPattern(0.25 + r * 0.25, gfx.image.kDitherTypeBayer8x8)
  gfx.fillRect(0, 0, w, h)
  -- shoulders
  gfx.setDitherPattern(0.7, gfx.image.kDitherTypeBayer4x4)
  gfx.fillEllipseInRect(w * 0.08, h * 0.68, w * 0.84, h * 0.6)
  -- head
  gfx.setColor(gfx.kColorWhite)
  local hw = w * (0.38 + K.hash01(n, 3) * 0.1)
  gfx.fillEllipseInRect(w / 2 - hw / 2, h * 0.22, hw, h * 0.5)
  gfx.setDitherPattern(0.85, gfx.image.kDitherTypeBayer8x8)
  gfx.fillEllipseInRect(w / 2 - hw / 2 + w * 0.06, h * 0.30, hw * 0.75, h * 0.42)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawEllipseInRect(w / 2 - hw / 2, h * 0.22, hw, h * 0.5)
  -- eyes, mustache maybe
  local ey = h * 0.42
  gfx.fillRect(w / 2 - hw * 0.22, ey, math.max(1, w // 24), math.max(1, h // 32))
  gfx.fillRect(w / 2 + hw * 0.14, ey, math.max(1, w // 24), math.max(1, h // 32))
  if K.hash01(n, 5) > 0.5 then gfx.fillRect(w / 2 - hw * 0.18, h * 0.56, hw * 0.36, math.max(1, h // 24)) end
  -- cap or bowler
  local hat = K.hash01(n, 11)
  if hat < 0.5 then
    gfx.fillRect(w / 2 - hw * 0.55, h * 0.24, hw * 1.1, h * 0.09)
    gfx.fillEllipseInRect(w / 2 - hw * 0.45, h * 0.12, hw * 0.9, h * 0.2)
  elseif hat < 0.8 then
    gfx.fillRect(w / 2 - hw * 0.6, h * 0.26, hw * 1.2, h * 0.04)
    gfx.fillRect(w / 2 - hw * 0.4, h * 0.10, hw * 0.8, h * 0.17)
  end
  gfx.popContext()
  placeholderCache[key] = img
  return img
end

--- Face image for a face-bank id ("face:12") at size 48 or 96. Never nil.
function K.face(face, size)
  size = size or 48
  local n = faceNum(face)
  local key = n * 1000 + size
  local img = faceCache[key]
  if img then return img end
  img = Packs.loadImage("images/faces", tostring(n), size)
  if not img then img = placeholderFace(n, size) end
  faceCache[key] = img
  return img
end

function K.releaseFaces()
  faceCache = {}
  placeholderCache = {}
end

---------------------------------------------------------------------------
-- tiny synth kit (shared voices; created on first use)

local voices = {}
local function voice(name, wave, a, d, s, r, vol)
  local v = voices[name]
  if v then return v end
  v = snd.synth.new(wave)
  v:setADSR(a, d, s, r)
  v:setVolume(vol or 0.5)
  voices[name] = v
  return v
end
K.voice = voice

--- One-shot blips: kind = "click", "flip", "tick", "thud", "glitch", "chime", "fanfare", "buzz".
function K.sfx(kind)
  if kind == "click" then
    voice("click", snd.kWaveNoise, 0, 0.03, 0, 0.01, 0.3):playNote(3000, 0.4, 0.03)
  elseif kind == "tick" then
    voice("tick", snd.kWaveSquare, 0, 0.02, 0, 0.01, 0.15):playNote(1800, 0.3, 0.02)
  elseif kind == "flip" then
    voice("flip", snd.kWaveNoise, 0.01, 0.08, 0, 0.05, 0.35):playNote(900, 0.6, 0.08)
  elseif kind == "thud" then
    voice("thud", snd.kWaveSine, 0, 0.12, 0, 0.05, 0.6):playNote(70, 0.8, 0.1)
  elseif kind == "buzz" then
    voice("buzz", snd.kWaveSquare, 0, 0.2, 0, 0.05, 0.25):playNote(110, 0.6, 0.2)
  elseif kind == "glitch" then
    for i = 0, 6 do
      voice("glitch" .. i, snd.kWaveSquare, 0, 0.04, 0, 0.01, 0.25):playNote(200 + math.random(1800), 0.5, 0.03, snd.getCurrentTime() + i * 0.045)
    end
  elseif kind == "chime" then
    local v = voice("chime", snd.kWaveSine, 0, 0.3, 0.2, 0.3, 0.35)
    local t = snd.getCurrentTime()
    v:playNote(1568, 0.5, 0.08, t)
    voice("chime2", snd.kWaveSine, 0, 0.3, 0.2, 0.3, 0.3):playNote(2093, 0.5, 0.2, t + 0.09)
    voice("chime3", snd.kWaveSine, 0, 0.3, 0.2, 0.3, 0.25):playNote(2637, 0.5, 0.3, t + 0.18)
  elseif kind == "fanfare" then
    local t = snd.getCurrentTime()
    local notes = { 392, 523, 659, 784, 659, 784 }
    local lens = { 0.12, 0.12, 0.12, 0.3, 0.12, 0.5 }
    local at = t
    for i = 1, #notes do
      voice("fan" .. i, snd.kWaveSquare, 0.01, 0.1, 0.6, 0.15, 0.22):playNote(notes[i], 0.6, lens[i] * 0.9, at)
      at = at + lens[i]
    end
  end
end

return K
