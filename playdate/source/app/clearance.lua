-- Text clearance checker (Simulator only, dev). If the Data folder holds "clearance.flag", every
-- text draw (font:drawText) and image blit is recorded per drawing target; at each tour shot the
-- text visible on screen is measured against the real frame: the text's ink box (rendered once per
-- font+string) is placed on the display image and the rows above / below it are scanned for the
-- edge of whatever box it sits in (a row the background colour stops in across >= 70% of the
-- text's width: a border line or the edge of a fill). Text whose top ink sits flush against that
-- edge (0 clear rows), is cut by it, or has a top gap 2+ px smaller than its bottom gap is logged:
--   [clear] <shot> <FLUSH|CLIP|LOW> font=<path> "<text>" ink=x,y,w,h top=<rows> bot=<rows>
-- Nothing is hooked without the flag.

Clearance = Clearance or {}

local gfx <const> = playdate.graphics
if not (playdate.isSimulator and playdate.file.exists("clearance.flag")) then return end
Clearance.on = true

local fontName = setmetatable({}, { __mode = "k" })
local rawFontNew = gfx.font.new
gfx.font.new = function(path, ...)
  local f = rawFontNew(path, ...)
  if f then fontName[f] = tostring(path):gsub("^.*/", "") end
  return f
end

local recs = setmetatable({}, { __mode = "k" })  -- image -> list of records
local screen = {}
local stack = {}   -- context targets (false = screen)
local function target() return stack[#stack] or false end
local function list()
  local t = target()
  if not t then return screen end
  local l = recs[t]
  if not l then l = {} recs[t] = l end
  return l
end
local function reset(t)
  if not t then screen = {} else recs[t] = {} end
end

local rawPush, rawPop = gfx.pushContext, gfx.popContext
gfx.pushContext = function(img, ...)
  stack[#stack + 1] = img or false
  return rawPush(img, ...)
end
gfx.popContext = function(...)
  stack[#stack] = nil
  return rawPop(...)
end
local rawLock, rawUnlock = gfx.lockFocus, gfx.unlockFocus
if rawLock then
  gfx.lockFocus = function(img, ...) stack[#stack + 1] = img or false return rawLock(img, ...) end
  gfx.unlockFocus = function(...) stack[#stack] = nil return rawUnlock(...) end
end

local rawClear = gfx.clear
gfx.clear = function(...)
  reset(target())
  return rawClear(...)
end
local rawImgClear = gfx.image.clear
gfx.image.clear = function(img, ...)
  recs[img] = {}
  return rawImgClear(img, ...)
end
local rawFill = gfx.fillRect
gfx.fillRect = function(x, y, w, h, ...)
  local t = target()
  if t and type(x) == "number" and x <= 0 and y <= 0 then
    local iw, ih = t:getSize()
    if x + w >= iw and y + h >= ih then recs[t] = {} end
  end
  return rawFill(x, y, w, h, ...)
end

-- the first caller outside the text plumbing (file:line), to group findings by draw site
local SKIP <const> = { ["ui/theme.lua"] = true, ["ui/text.lua"] = true, ["ballcast/tv/art.lua"] = true, ["ballcast/kit.lua"] = true }
local function site()
  local parts = {}
  for lv = 3, 9 do
    local i = debug.getinfo(lv, "Sl")
    if not i then break end
    local src = (i.short_src or "?"):gsub("^.*/source/", ""):gsub("^%.%.%.", "")
    local short = src:gsub("^.-([%w_]+/[%w_]+%.lua)$", "%1")
    if not SKIP[short] then return short .. ":" .. tostring(i.currentline) end
    parts[#parts + 1] = short .. ":" .. tostring(i.currentline)
  end
  return parts[1] or "?"
end

local rawText = gfx.font.drawText
gfx.font.drawText = function(f, s, x, y, ...)
  if type(s) == "string" and type(x) == "number" and s ~= "" then
    local ox, oy = gfx.getDrawOffset()
    local l = list()
    l[#l + 1] = { k = "t", f = f, s = s, x = x + ox, y = y + oy, site = site() }
  end
  return rawText(f, s, x, y, ...)
end

local rawDraw = gfx.image.draw
gfx.image.draw = function(img, x, y, flip, src, ...)
  if type(x) == "number" and (flip == nil or flip == gfx.kImageUnflipped) and recs[img] then
    local ox, oy = gfx.getDrawOffset()
    local sx, sy = 0, 0
    if src then
      if type(src) == "number" then sx, sy = src, ... else sx, sy = src.x, src.y end
    end
    local l = list()
    l[#l + 1] = { k = "i", img = img, x = x + ox - (sx or 0), y = y + oy - (sy or 0) }
  end
  return rawDraw(img, x, y, flip, src, ...)
end
local rawAnch = gfx.image.drawAnchored
gfx.image.drawAnchored = function(img, x, y, ax, ay, flip, ...)
  if (flip == nil or flip == gfx.kImageUnflipped) and recs[img] then
    local w, h = img:getSize()
    local ox, oy = gfx.getDrawOffset()
    local l = list()
    l[#l + 1] = { k = "i", img = img, x = x + ox - math.floor(w * ax), y = y + oy - math.floor(h * ay) }
  end
  return rawAnch(img, x, y, ax, ay, flip, ...)
end
local rawCent = gfx.image.drawCentered
gfx.image.drawCentered = function(img, x, y, flip, ...)
  if (flip == nil or flip == gfx.kImageUnflipped) and recs[img] then
    local w, h = img:getSize()
    local ox, oy = gfx.getDrawOffset()
    local l = list()
    l[#l + 1] = { k = "i", img = img, x = x + ox - w // 2, y = y + oy - h // 2 }
  end
  return rawCent(img, x, y, flip, ...)
end

-- ink box of one string in one font: rows/cols relative to the draw point, and ink pixels
local inkCache = setmetatable({}, { __mode = "k" })
local function ink(f, s)
  local fc = inkCache[f]
  if not fc then fc = {} inkCache[f] = fc end
  local r = fc[s]
  if r ~= nil then return r end
  local w = f:getTextWidth(s) + 4
  local h = f:getHeight() + 6
  local img = gfx.image.new(w, h, gfx.kColorWhite)
  rawPush(img)
  gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
  rawText(f, s, 2, 2)
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  rawPop()
  local x0, x1, y0, y1 = 9999, -1, 9999, -1
  local px = {}
  for yy = 0, h - 1 do
    for xx = 0, w - 1 do
      if img:sample(xx, yy) == gfx.kColorBlack then
        if xx < x0 then x0 = xx end
        if xx > x1 then x1 = xx end
        if yy < y0 then y0 = yy end
        if yy > y1 then y1 = yy end
        px[#px + 1] = { xx - 2, yy - 2 }
      end
    end
  end
  if x1 < 0 then r = false
  else r = { x0 = x0 - 2, x1 = x1 - 2, y0 = y0 - 2, y1 = y1 - 2, px = px } end
  fc[s] = r
  return r
end

local function collect(l, dx, dy, out, depth)
  if depth > 6 then return end
  for i = 1, #l do
    local r = l[i]
    if r.k == "t" then
      out[#out + 1] = { f = r.f, s = r.s, x = r.x + dx, y = r.y + dy, site = r.site }
    elseif r.k == "i" then
      local sub = recs[r.img]
      if sub and #sub > 0 then collect(sub, r.x + dx, r.y + dy, out, depth + 1) end
    end
  end
end

local seen = {}
Clearance.issues = {}

--- Measure the text visible in the frame just drawn; log the crowded ones.
function Clearance.check(name)
  local disp = gfx.getWorkingImage()
  local out = {}
  collect(screen, 0, 0, out, 0)
  local W, H = 400, 240
  local n = 0
  for _, t in ipairs(out) do
    local k = ink(t.f, t.s)
    if k then
      local X, Y = math.floor(t.x), math.floor(t.y)
      local ax0, ax1, ay0, ay1 = X + k.x0, X + k.x1, Y + k.y0, Y + k.y1
      if ax0 >= 0 and ax1 < W and ay0 >= 1 and ay1 < H - 1 then
        -- ink colour: majority over the ink pixels; per-row agreement for clip detection
        local cnt = { [0] = 0, [1] = 0 }
        local rowBad = {}
        local samples = {}
        local step = math.max(1, #k.px // 60)
        for i = 1, #k.px, step do
          local p = k.px[i]
          local c = disp:sample(X + p[1], Y + p[2])
          samples[#samples + 1] = { p, c }
          if c == gfx.kColorBlack then cnt[0] += 1 elseif c == gfx.kColorWhite then cnt[1] += 1 end
        end
        local inkC = cnt[0] >= cnt[1] and gfx.kColorBlack or gfx.kColorWhite
        local agree = math.max(cnt[0], cnt[1]) / #samples
        local bad = 0
        for _, sp in ipairs(samples) do
          if sp[2] ~= inkC then bad += 1 rowBad[sp[1][2]] = (rowBad[sp[1][2]] or 0) + 1 end
        end
        local clipped = false
        if bad > 0 then
          -- all disagreements in the top two ink rows: cut by something drawn over its top
          clipped = true
          for ry in pairs(rowBad) do if ry > k.y0 + 1 then clipped = false end end
        end
        if agree >= 0.97 or clipped then
          local bg = inkC == gfx.kColorBlack and gfx.kColorWhite or gfx.kColorBlack
          local sx0, sx1 = math.max(0, ax0 - 1), math.min(W - 1, ax1 + 1)
          local span = sx1 - sx0 + 1
          local function scan(y0, dir)
            for d = 1, 7 do
              local yy = y0 + dir * d
              if yy < 0 or yy >= H then return nil end
              local c = 0
              for xx = sx0, sx1 do if disp:sample(xx, yy) ~= bg then c += 1 end end
              if c >= span * 0.7 then return d - 1 end
              if c > 0 then return nil end
            end
            return nil
          end
          local top = clipped and -1 or scan(ay0, -1)
          local bot = scan(ay1, 1)
          local kind = nil
          if top and top <= 0 then kind = clipped and "CLIP" or "FLUSH"
          elseif top and bot and top <= 1 and bot - top >= 2 then kind = "LOW" end
          if kind then
            local fn = fontName[t.f] or "?"
            local key = fn .. "|" .. t.s .. "|" .. X .. "," .. Y
            if not seen[key] then
              seen[key] = true
              n += 1
              local line = string.format("[clear] %s %s font=%s \"%s\" ink=%d,%d,%d,%d top=%s bot=%s site=%s",
                name, kind, fn, t.s, ax0, ay0, ax1 - ax0 + 1, ay1 - ay0 + 1, tostring(top), tostring(bot), t.site or "?")
              print(line)
              Clearance.issues[#Clearance.issues + 1] = line
            end
          end
        end
      end
    end
  end
  print(string.format("[clear] %s checked %d texts, %d new", name, #out, n))
end

function Clearance.frameEnd()
  screen = {}
end
