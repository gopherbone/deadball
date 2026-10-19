-- On-screen keyboard text entry (playdate.keyboard), styled as a 90s form field.
-- NameEntry.open{ title=, prompt=, text=, maxLen=16, onDone=function(textOrNil) end }

local gfx <const> = playdate.graphics
local kb <const> = playdate.keyboard

NameEntry = NameEntry or {}
NameEntry.__index = NameEntry

function NameEntry.open(opts)
  local s = setmetatable({ opts = opts, t = 0, text = opts.text or "" }, NameEntry)
  App.push(s)
  return s
end

function NameEntry:enter()
  self.t = 0
  self.done = false
  local maxLen = self.opts.maxLen or 16
  kb.textChangedCallback = function()
    if #kb.text > maxLen then kb.text = kb.text:sub(1, maxLen) Sfx.error() end
    self.text = kb.text
    Sfx.tick()
  end
  kb.keyboardWillHideCallback = function(ok)
    self.ok = ok
  end
  kb.keyboardDidHideCallback = function()
    self:finish()
  end
  kb.setCapitalizationBehavior(kb.kCapitalizationNormal)
  kb.show(self.text)
end

function NameEntry:finish()
  if self.done then return end
  self.done = true
  kb.textChangedCallback = nil
  kb.keyboardWillHideCallback = nil
  kb.keyboardDidHideCallback = nil
  if App.top() == self then App.pop() end
  local text = self.ok and (self.text:gsub("^%s+", ""):gsub("%s+$", "")) or nil
  if self.opts.onDone then self.opts.onDone(text) end
end

function NameEntry:exit()
  if kb.isVisible() then kb.hide() end
end

function NameEntry:update()
  self.t += 1
  local left = kb.isVisible() and kb.left() or 400
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 0, 400, 240)
  Draw.tile(0, 0, 400, 240, "light")
  local w = math.max(150, left - 20)
  local x, y, h = 8, 34, 150
  local ix, iy, iw = Draw.window(x, y, w, h, self.opts.title or "Enter text")
  local ty = iy + 6
  ty += Text.block(self.opts.prompt or "", ix + 8, ty, iw - 16, UI.fonts.body, nil, 5)
  ty += 6
  -- field
  local fy = ty
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(ix + 8, fy, iw - 16, 18)
  Draw.bevel(ix + 8, fy, iw - 16, 18, true)
  local shown = Text.ellipsize(self.text, UI.fonts.bold, iw - 30)
  local tw = Text.draw(shown, ix + 12, fy + 3, UI.fonts.bold)
  if (self.t // 10) % 2 == 0 then
    gfx.fillRect(ix + 13 + tw, fy + 3, 2, 12)
  end
  local maxLen = self.opts.maxLen or 16
  Text.draw(#self.text .. "/" .. maxLen, ix + iw - 8, fy + 21, UI.fonts.body, nil, "right")
  Text.draw("OK when done", ix + 8, fy + 21, UI.fonts.body)
  Chrome.menubar()
end
