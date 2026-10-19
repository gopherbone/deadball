-- Late-90s widget painting: bevels, windows, buttons, stripes, hit counters,
-- WordArt headlines, scrollbars, meters. All immediate-mode; cheap enough per frame,
-- but pages usually paint them once into their canvas.

local gfx <const> = playdate.graphics

Draw = Draw or {}

local F = function() return UI.fonts end

function Draw.pattern(name)
  gfx.setPattern(UI.pat[name])
end

--- Raised (or sunken) bevel: white top-left, black bottom-right, gray body optional.
function Draw.bevel(x, y, w, h, sunken, fill)
  if fill then
    if fill == "gray" or fill == "light" then gfx.setPattern(UI.pat[fill]) else gfx.setColor(gfx.kColorWhite) end
    gfx.fillRect(x, y, w, h)
  end
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  local hi, lo = gfx.kColorWhite, gfx.kColorBlack
  if sunken then hi, lo = lo, hi end
  gfx.setColor(hi)
  gfx.drawLine(x + 1, y + 1, x + w - 2, y + 1)
  gfx.drawLine(x + 1, y + 1, x + 1, y + h - 2)
  gfx.setColor(lo)
  gfx.drawLine(x + 1, y + h - 2, x + w - 2, y + h - 2)
  gfx.drawLine(x + w - 2, y + 1, x + w - 2, y + h - 2)
  gfx.setColor(gfx.kColorBlack)
end

--- A push button with a centered label. state: nil | "focus" | "pressed" | "disabled"
function Draw.button(x, y, w, h, label, state, font)
  font = font or F().bold
  local pressed = state == "pressed"
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRoundRect(x, y, w, h, 2)
  if not pressed then
    gfx.drawLine(x + 2, y + h, x + w - 1, y + h) -- drop edge
    gfx.drawLine(x + w, y + 2, x + w, y + h - 1)
  end
  local oy = pressed and 1 or 0
  local th = font:getHeight()
  Text.draw(label, x + w // 2 + oy, y + (h - th) // 2 + oy + 1, font, nil, "center")
  if state == "disabled" then
    Draw.fade(x + 1, y + 1, w - 2, h - 2, 0.5, true)
    gfx.setColor(gfx.kColorBlack)
  end
end

--- Classic window: double frame, striped title bar with a close box.
function Draw.window(x, y, w, h, title, opts)
  opts = opts or {}
  -- shadow
  if not opts.noShadow then
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x + 3, y + 3, w, h)
  end
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(1)
  gfx.drawRect(x, y, w, h)
  local th = 0
  if title then
    th = 15
    if opts.inverted then
      gfx.fillRect(x, y, w, th)
    else
      gfx.setPattern(UI.pat.title)
      gfx.fillRect(x + 2, y + 3, w - 4, th - 6)
      gfx.setColor(gfx.kColorBlack)
    end
    gfx.drawLine(x, y + th, x + w - 1, y + th)
    local tw = Text.width(title, F().bold) + 10
    local tx = x + (w - tw) // 2
    if opts.titleLeft then tx = x + 18 end
    if not opts.inverted then
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(tx, y + 1, tw, th - 2)
      gfx.setColor(gfx.kColorBlack)
      Text.draw(title, tx + 5, y + 2, F().bold)
      -- close box
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(x + 5, y + 3, 10, 9)
      gfx.setColor(gfx.kColorBlack)
      gfx.drawRect(x + 5, y + 3, 10, 9)
    else
      Text.draw(title, tx + 5, y + 2, F().bold, "white")
    end
  end
  return x + 1, y + th + 1, w - 2, h - th - 2
end

--- A plain boxed panel with an optional bold heading (like the mockup sidebars).
function Draw.panel(x, y, w, h, heading, opts)
  opts = opts or {}
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  if opts.double then gfx.drawRect(x + 2, y + 2, w - 4, h - 4) end
  if heading then
    if opts.invertHead then
      gfx.fillRect(x, y, w, 15)
      Text.draw(heading, x + 4, y + 1, F().head, "white")
    else
      Text.draw(heading, x + 4, y + 2, F().head)
    end
    return y + 17
  end
  return y + 3
end

--- Yellow-and-black "under construction" hazard stripes (diagonal), with optional label.
function Draw.stripes(x, y, w, h, label, frame)
  gfx.setColor(gfx.kColorBlack)
  local st = UI.imagetable("images/ui/construction-stripe-table-32-10")
  if st and h >= 10 then
    local img = st:getImage(((frame or 0) % st:getLength()) + 1)
    gfx.setClipRect(x, y, w, h)
    for ty = y, y + h - 1, 10 do img:drawTiled(x, ty, w, math.min(10, y + h - ty)) end
    gfx.clearClipRect()
  else
    gfx.setPattern(UI.pat.hazard)
    gfx.fillRect(x, y, w, h)
  end
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  if label then
    local f = F().bold
    local tw = f:getTextWidth(label) + 8
    local tx = x + (w - tw) // 2
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(tx, y + 1, tw, h - 2)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(label, tx + 4, y + (h - f:getHeight()) // 2 + 1, f)
  end
end

--- Odometer-style hit counter: white digits in black cells. `roll` (0..1) animates the last digit.
function Draw.hitCounter(x, y, n, digits, roll)
  digits = digits or 6
  local s = string.format("%0" .. digits .. "d", math.floor(n or 0) % (10 ^ digits))
  local dt = UI.imagetable("images/ui/counter-digits-table-9-14")
  if dt then
    local rt = UI.imagetable("images/ui/counter-roll-table-9-14")
    for i = 1, digits do
      local d = tonumber(s:sub(i, i))
      local img = dt:getImage(d + 1)
      if i == digits and roll and roll > 0 and rt then
        local k = math.max(1, math.min(3, math.floor(roll * 4)))
        img = rt:getImage(d * 3 + k) or img
      end
      img:draw(x + (i - 1) * 9, y)
    end
    return digits * 9
  end
  local f = F().bold
  local cw, ch = 9, 13
  for i = 1, digits do
    local cx = x + (i - 1) * (cw + 1)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(cx, y, cw, ch)
    local d = s:sub(i, i)
    if i == digits and roll and roll > 0 then
      local nd = tostring((tonumber(d) + 1) % 10)
      local off = math.floor(roll * ch)
      gfx.setClipRect(cx, y, cw, ch)
      Text.draw(d, cx + 2, y + 1 - off, f, "white")
      Text.draw(nd, cx + 2, y + 1 + ch - off, f, "white")
      gfx.clearClipRect()
    else
      Text.draw(d, cx + 2, y + 1, f, "white")
    end
  end
  gfx.setColor(gfx.kColorWhite)
  gfx.drawLine(x, y + ch // 2, x + digits * (cw + 1) - 2, y + ch // 2)
  gfx.setColor(gfx.kColorBlack)
  return digits * (cw + 1)
end

-- WordArt ----------------------------------------------------------------
local wordartCache = {}

--- Returns a cached image of `text` as an outlined, drop-shadowed headline.
function Draw.wordartImage(text, font, opts)
  opts = opts or {}
  font = font or UI.fonts.slab
  local key = text .. "|" .. tostring(font) .. "|" .. (opts.style or "") .. (opts.big and "B" or "")
  local img = wordartCache[key]
  if img then return img end
  -- prefer the assets agent's pre-outlined WordArt face for the default style
  local wa = opts.big and UI.fonts.wordartBig or UI.fonts.wordart
  if wa and font == UI.fonts.slab and opts.style ~= "gradient" then
    local up = text:upper()
    local tw, th = wa:getTextWidth(up), wa:getHeight()
    img = gfx.image.new(tw + 2, th + 2, gfx.kColorClear)
    gfx.pushContext(img)
    wa:drawText(up, 1, 1)
    gfx.popContext()
    wordartCache[key] = img
    return img
  end
  local tw, th = font:getTextWidth(text), font:getHeight()
  local glyphs = gfx.image.new(tw, th, gfx.kColorClear)
  gfx.pushContext(glyphs)
  font:drawText(text, 0, 0)
  gfx.popContext()
  local pad = 4
  img = gfx.image.new(tw + pad * 2, th + pad * 2, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setImageDrawMode(gfx.kDrawModeFillBlack)
  -- 3px drop shadow
  for d = 1, 3 do glyphs:draw(pad + d, pad + d) end
  -- 1px outline in every direction
  for dx = -1, 1 do
    for dy = -1, 1 do glyphs:draw(pad + dx, pad + dy) end
  end
  gfx.setImageDrawMode(gfx.kDrawModeFillWhite)
  glyphs:draw(pad, pad)
  if opts.style == "gradient" then
    -- dither the lower half for that 1997 gradient fill
    local mask = gfx.image.new(tw, th, gfx.kColorClear)
    gfx.pushContext(mask)
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    glyphs:draw(0, 0)
    gfx.setColor(gfx.kColorClear)
    gfx.fillRect(0, 0, tw, th // 2 + 1)
    gfx.popContext()
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    local faded = mask:fadedImage(0.35, gfx.image.kDitherTypeBayer4x4)
    faded:draw(pad, pad)
  end
  gfx.setImageDrawMode(gfx.kDrawModeCopy)
  gfx.popContext()
  wordartCache[key] = img
  return img
end

--- Draws a WordArt headline centered at cx (or at x when align == "left"). Returns w, h.
function Draw.wordart(text, cx, y, font, opts)
  local img = Draw.wordartImage(text, font, opts)
  local w, h = img:getSize()
  local x = (opts and opts.align == "left") and cx or (cx - w // 2)
  img:draw(x, y)
  return w, h
end

function Draw.clearWordartCache()
  wordartCache = {}
end

--- Vertical scrollbar with bevelled thumb. frac = visible/total, pos = 0..1.
function Draw.scrollbar(x, y, h, frac, pos)
  local w = 7
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setPattern(UI.pat.gray)
  gfx.fillRect(x + 1, y + 1, w - 2, h - 2)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  local th = math.max(12, math.floor(h * math.min(1, frac)))
  local ty = y + math.floor((h - th) * math.max(0, math.min(1, pos)))
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, ty, w, th)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, ty, w, th)
  -- grip lines
  local my = ty + th // 2
  gfx.drawLine(x + 2, my - 2, x + w - 3, my - 2)
  gfx.drawLine(x + 2, my, x + w - 3, my)
  gfx.drawLine(x + 2, my + 2, x + w - 3, my + 2)
end

--- Feuds & friends style meter, value -5..5 drawn as bars from the center.
function Draw.relBar(x, y, w, value)
  local cx = x + w // 2
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(cx, y, cx, y + 7)
  local seg = (w // 2 - 2) // 5
  local n = math.max(-5, math.min(5, value or 0))
  for i = 1, math.abs(n) do
    local bx = n > 0 and (cx + 2 + (i - 1) * seg) or (cx - 1 - i * seg)
    gfx.fillRect(bx, y + 1, seg - 1, 6)
  end
end

--- Filled progress bar (0..1) with border.
function Draw.progress(x, y, w, h, frac, pattern)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
  local fw = math.floor((w - 4) * math.max(0, math.min(1, frac)))
  if fw > 0 then
    if pattern then gfx.setPattern(UI.pat[pattern]) end
    gfx.fillRect(x + 2, y + 2, fw, h - 4)
    gfx.setColor(gfx.kColorBlack)
  end
end

--- 1..5 pips (scouting grades, loyalty).
function Draw.pips(x, y, n, max)
  max = max or 5
  for i = 1, max do
    local px = x + (i - 1) * 6
    if i <= n then gfx.fillRect(px, y, 5, 5) else gfx.drawRect(px, y, 5, 5) end
  end
  return max * 6
end

function Draw.checkbox(x, y, on)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, 9, 9)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, 9, 9)
  if on then gfx.fillRect(x + 2, y + 2, 5, 5) end
end

function Draw.radio(x, y, on)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillCircleInRect(x, y, 9, 9)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawCircleInRect(x, y, 9, 9)
  if on then gfx.fillCircleInRect(x + 2, y + 2, 5, 5) end
end

--- A label chip (traits): inverted text in a black box.
function Draw.chip(x, y, label, font, outline)
  font = font or F().bold
  local w = font:getTextWidth(label) + 6
  local h = font:getHeight() + 1
  if outline then
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(x, y, w, h)
    Text.draw(label, x + 3, y + 1, font)
  else
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x, y, w, h)
    Text.draw(label, x + 3, y + 1, font, "white")
  end
  return w
end

--- Horizontal rule, 90s style (groove).
function Draw.hr(x, y, w)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(x, y, x + w - 1, y)
  gfx.setPattern(UI.pat.gray)
  gfx.drawLine(x + 1, y + 1, x + w - 1, y + 1)
  gfx.setColor(gfx.kColorBlack)
end

--- Fill a rect with a named tile pattern (backgrounds).
function Draw.tile(x, y, w, h, name)
  gfx.setPattern(UI.pat[name] or UI.pat.light)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
end

--- Little "NEW!" starburst.
function Draw.newBurst(cx, cy, r, t)
  local bt = UI.imagetable("images/ui/new-burst-table-30-20")
  if bt then
    bt:getImage((((t or 0) // 10) % 2) + 1):draw(cx - 15, cy - 10)
    return
  end
  local pts = {}
  local n = 12
  local rot = (t or 0) * 0.05
  for i = 0, n * 2 - 1 do
    local a = rot + i * math.pi / n
    local rr = (i % 2 == 0) and r or r * 0.68
    pts[#pts + 1] = cx + math.cos(a) * rr
    pts[#pts + 1] = cy + math.sin(a) * rr
  end
  gfx.setColor(gfx.kColorWhite)
  gfx.fillPolygon(table.unpack(pts))
  gfx.setColor(gfx.kColorBlack)
  gfx.drawPolygon(table.unpack(pts))
  Text.draw("NEW!", cx, cy - 6, F().bold, nil, "center")
end

--- Busy throbber: a spinning baseball (stitches rotate). t is a frame counter.
function Draw.throbber(cx, cy, r, t, spinning)
  local tbl = UI.imagetable("images/ui/throbber-table-22-14")
  if tbl and r <= 8 then
    local n = tbl:getLength()
    local f = spinning and ((t // 3) % (n - 1)) + 2 or 1
    tbl:getImage(math.min(n, f)):draw(cx - 11, cy - 7)
    return
  end
  gfx.setColor(gfx.kColorWhite)
  gfx.fillCircleAtPoint(cx, cy, r)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawCircleAtPoint(cx, cy, r)
  local a = spinning and (t * 0.35) or 0.6
  local ca, sa = math.cos(a), math.sin(a)
  -- two stitch arcs, rotated
  for side = -1, 1, 2 do
    for k = -2, 2 do
      local px = side * r * 0.55
      local py = k * r * 0.28
      local bx = px + side * (math.abs(k) * 0.12 * r)
      local x1 = cx + bx * ca - py * sa
      local y1 = cy + bx * sa + py * ca
      gfx.fillRect(math.floor(x1), math.floor(y1), 1, 1)
      gfx.drawPixel(math.floor(x1 + ca), math.floor(y1 + sa))
    end
  end
end

--- Placeholder person silhouette drawn into a box (used when a face image is missing).
function Draw.silhouette(x, y, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setPattern(UI.pat.lighter)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  local cx = x + w // 2
  local hr = math.max(3, math.floor(w * 0.17))
  local hy = y + math.floor(h * 0.42)
  -- shoulders (trapezoid to the bottom edge)
  local neck = hy + hr
  gfx.fillPolygon(cx - math.floor(w * 0.4), y + h - 1, cx - math.floor(w * 0.22), neck + 2, cx + math.floor(w * 0.22), neck + 2, cx + math.floor(w * 0.4), y + h - 1)
  gfx.fillCircleAtPoint(cx, hy, hr)
  -- flat cap + brim
  gfx.fillRect(cx - hr, hy - hr - math.max(1, hr // 3), hr * 2 + 1, math.max(2, hr // 2) + 1)
  gfx.fillRect(cx - hr - math.max(1, hr // 2), hy - hr + math.max(1, hr // 4), hr * 2 + hr, math.max(1, hr // 4))
  -- question mark on the face: "photo not on file"
  if w >= 48 then
    gfx.setColor(gfx.kColorWhite)
    Text.draw("?", cx, hy - 6, UI.fonts.bold, "white", "center")
    gfx.setColor(gfx.kColorBlack)
  end
  gfx.drawRect(x, y, w, h)
end

-- Masked fades (setDitherPattern with white is unreliable, so use explicit 8x8 masks).
local MASKS <const> = {
  [0.25] = { 0x88, 0x22, 0x88, 0x22, 0x88, 0x22, 0x88, 0x22 },
  [0.5] = { 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55, 0xAA, 0x55 },
  [0.75] = { 0x77, 0xDD, 0x77, 0xDD, 0x77, 0xDD, 0x77, 0xDD },
}
local fadePat = {}

--- Covers a rect with `level` (0.25 | 0.5 | 0.75) of black (default) or white pixels.
function Draw.fade(x, y, w, h, level, white)
  local m = MASKS[level] or MASKS[0.5]
  local v = white and 0xFF or 0x00
  for i = 1, 8 do
    fadePat[i] = v
    fadePat[i + 8] = m[i]
  end
  gfx.setPattern(fadePat)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
end

--- Full-screen dim behind modals.
function Draw.dim(level)
  Draw.fade(0, 0, 400, 240, level or 0.5)
end

--- A dotted horizontal line (separators) in black or white.
function Draw.dotted(x1, x2, y, white)
  Draw.fade(x1, y, x2 - x1 + 1, 1, 0.5, white)
end
