--[[ Win95-style popup menu (modal, non-opaque): the toolbar's bookmarks and the Start menu.
  Menu.open{
    x = 10, y = 34,               -- top-left; or anchor = "bottom" to grow upward from y
    items = { { label = "Bobby's", action = fn, note = "4" }, { label = "Standings", sub = { ... } },
              "-" (separator) },
    banner = "DeadballOS 96",      -- optional vertical strip on the left (the Start menu)
    title = nil,
  }
  Up/down (or crank) move, A or right opens a submenu / runs the item, left or B closes. ]]

local gfx <const> = playdate.graphics

Menu = Menu or {}
Menu.__index = Menu

local ROW_H <const> = 17
local SEP_H <const> = 7
local BANNER_W <const> = 20

function Menu.open(opts)
  local m = setmetatable({ opts = opts, opaque = false, parent = opts.parent }, Menu)
  App.push(m)
  return m
end

local bannerCache = {}
local function bannerImage(text, h)
  local key = text .. h
  local img = bannerCache[key]
  if img then return img end
  local f = UI.fonts.bold
  local tw = f:getTextWidth(text)
  local strip = gfx.image.new(h, BANNER_W, gfx.kColorBlack)
  gfx.pushContext(strip)
  Text.draw(text, 6, 3, f, "white")
  gfx.popContext()
  img = strip:rotatedImage(-90)
  bannerCache[key] = img
  return img
end

function Menu:enter()
  local items = {}
  for _, it in ipairs(self.opts.items or {}) do
    if it == "-" then it = { sep = true } end
    items[#items + 1] = it
  end
  self.items = items
  self.sel = 1
  while self.items[self.sel] and (self.items[self.sel].sep or self.items[self.sel].disabled) do self.sel += 1 end
  local f = UI.fonts.bold
  local w = 60
  for _, it in ipairs(items) do
    if not it.sep then
      local lw = f:getTextWidth(it.label) + 24 + (it.note and (UI.fonts.body:getTextWidth(it.note) + 10) or 0) + (it.sub and 12 or 0)
      if lw > w then w = lw end
    end
  end
  self.bannerW = self.opts.banner and BANNER_W or 0
  self.w = math.min(260, w + self.bannerW)
  local h = 4
  for _, it in ipairs(items) do h += it.sep and SEP_H or ROW_H end
  self.h = h
  local x, y = self.opts.x or 4, self.opts.y or 34
  if self.opts.anchor == "bottom" then y = y - h end
  if x + self.w > 398 then x = 398 - self.w end
  if y + h > 238 then y = 238 - h end
  if y < 2 then y = 2 end
  self.x, self.y = x, y
  self.t = 0
  self.acc = 0
  Sfx.select()
end

function Menu:rowY(i)
  local y = self.y + 2
  for k = 1, i - 1 do y += self.items[k].sep and SEP_H or ROW_H end
  return y
end

function Menu:update()
  self.t += 1
  local x, y, w, h = self.x, self.y, self.w, self.h
  -- slide open (Win95 menus unrolled downward)
  local k = Game.settings.reduceMotion and 1 or math.min(1, self.t / 4)
  local shownH = math.max(6, math.floor(h * k))
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 3, y + 3, w, shownH)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, shownH)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, shownH)
  if k < 1 then return end
  gfx.drawLine(x + 1, y + h - 2, x + w - 2, y + h - 2)
  if self.opts.banner then
    local img = bannerImage(self.opts.banner, h - 2)
    img:draw(x + 1, y + 1)
  end
  local ix = x + self.bannerW + 2
  local iw = w - self.bannerW - 4
  local f, fb = UI.fonts.body, UI.fonts.bold
  for i, it in ipairs(self.items) do
    local ry = self:rowY(i)
    if it.sep then
      Draw.dotted(ix + 2, ix + iw - 3, ry + 3)
    else
      local sel = i == self.sel
      if sel then gfx.fillRect(ix, ry, iw, ROW_H) end
      local col = sel and "white" or nil
      Text.draw(it.label, ix + 6, ry + 2, fb, col)
      if it.note then Text.draw(it.note, ix + iw - (it.sub and 16 or 6), ry + 2, f, col, "right") end
      if it.sub then
        gfx.setColor(sel and gfx.kColorWhite or gfx.kColorBlack)
        gfx.fillTriangle(ix + iw - 9, ry + 4, ix + iw - 4, ry + 8, ix + iw - 9, ry + 12)
        gfx.setColor(gfx.kColorBlack)
      end
      if it.disabled then Draw.fade(ix + 1, ry + 1, iw - 2, ROW_H - 2, 0.5, not sel) gfx.setColor(gfx.kColorBlack) end
    end
  end
end

function Menu:move(d)
  local n = #self.items
  local i = self.sel
  repeat
    i += d
  until i < 1 or i > n or not (self.items[i].sep or self.items[i].disabled)
  if i < 1 or i > n then Sfx.detent() return end
  self.sel = i
  Sfx.focus()
end

--- Closes this menu and every parent menu.
function Menu:closeAll()
  local m = self
  while m do
    if App.top() == m then App.pop() end
    m = m.parent
  end
end

function Menu:choose()
  local it = self.items[self.sel]
  if not it or it.sep or it.disabled then Sfx.detent() return end
  if it.sub then
    local ry = self:rowY(self.sel)
    Menu.open({ x = self.x + self.w - 4, y = ry - 2, items = it.sub, parent = self })
    return
  end
  Sfx.select()
  self:closeAll()
  if it.action then it.action() end
end

function Menu:upButtonDown() self:move(-1) end
function Menu:downButtonDown() self:move(1) end
function Menu:rightButtonDown()
  local it = self.items[self.sel]
  if it and it.sub then self:choose() else Sfx.detent() end
end
function Menu:leftButtonDown()
  if self.parent then Sfx.back() App.pop() else Sfx.detent() end
end
function Menu:AButtonDown() self:choose() end
function Menu:BButtonDown() Sfx.back() App.pop() end
function Menu:cranked(change)
  self.acc += change
  if self.acc > 25 then self.acc = 0 self:move(1) elseif self.acc < -25 then self.acc = 0 self:move(-1) end
end
