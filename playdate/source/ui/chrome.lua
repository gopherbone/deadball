-- Diamond Navigator chrome: the status bar on top (ui/status.lua), browser toolbar with
-- working nav buttons, address bar and throbber, status line with a progress meter.

local gfx <const> = playdate.graphics

Chrome = Chrome or {}
Chrome.MENU_H = 16
Chrome.TOOL_H = 18
Chrome.STATUS_H = 13
Chrome.TOP = Chrome.MENU_H + Chrome.TOOL_H        -- 34
Chrome.BOTTOM = 240 - Chrome.STATUS_H              -- 227
Chrome.VIEW_H = Chrome.BOTTOM - Chrome.TOP         -- 193

local function envelope(x, y, inverted)
  gfx.setColor(inverted and gfx.kColorWhite or gfx.kColorBlack)
  gfx.drawRect(x, y, 11, 8)
  gfx.drawLine(x, y, x + 5, y + 4)
  gfx.drawLine(x + 10, y, x + 5, y + 4)
  gfx.setColor(gfx.kColorBlack)
end
Chrome.envelope = envelope

--- The top bar: the day, the heartbeat chip, heat, mail and money (ui/status.lua).
function Chrome.menubar(style)
  Status.draw(0, style == "dark" and "dark" or "light")
end

-- Toolbar buttons: back, forward, home, reload, bookmarks. Reached by pressing up at the top
-- of a page (ui/page.lua); `focus` is the focused index or nil.
Chrome.TOOL_BUTTONS = { "back", "forward", "home", "reload", "bookmarks" }
Chrome.TOOL_HINTS = { back = "Back", forward = "Forward", home = "Home: the desktop",
  reload = "Reload this page", bookmarks = "Bookmarks: the core sites" }
local TOOL_X0 <const> = 3
local TOOL_STEP <const> = 14

--- x, y, w, h of toolbar button i.
function Chrome.toolButtonRect(i)
  return TOOL_X0 + (i - 1) * TOOL_STEP, Chrome.MENU_H + 3, 12, 12
end

--- Toolbar with nav buttons, "Go:" address field and a throbber. enabled[i] = false dims
--- button i; focus = index of the focused button (ringed).
function Chrome.toolbar(url, frame, busy, focus, enabled)
  local y = Chrome.MENU_H
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, y, 400, Chrome.TOOL_H)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(0, y + Chrome.TOOL_H - 1, 399, y + Chrome.TOOL_H - 1)
  local n = #Chrome.TOOL_BUTTONS
  for i = 1, n do
    local bx, by = Chrome.toolButtonRect(i)
    local on = focus == i
    if on then gfx.fillRect(bx - 1, by - 1, 14, 14) else gfx.drawRect(bx, by, 12, 12) end
    gfx.setColor(on and gfx.kColorWhite or gfx.kColorBlack)
    if i == 1 then
      gfx.fillTriangle(bx + 3, by + 6, bx + 8, by + 2, bx + 8, by + 10)
    elseif i == 2 then
      gfx.fillTriangle(bx + 9, by + 6, bx + 4, by + 2, bx + 4, by + 10)
    elseif i == 3 then -- home: little house
      gfx.drawLine(bx + 2, by + 6, bx + 6, by + 2)
      gfx.drawLine(bx + 6, by + 2, bx + 10, by + 6)
      gfx.drawRect(bx + 4, by + 6, 5, 4)
    elseif i == 4 then -- reload
      gfx.drawCircleAtPoint(bx + 6, by + 6, 3)
      gfx.fillRect(bx + 8, by + 2, 2, 2)
    else -- bookmarks: a star
      Text.draw("\u{2605}", bx + 2, by - 1, UI.fonts.bold, on and "white" or nil)
    end
    gfx.setColor(gfx.kColorBlack)
    if enabled and enabled[i] == false and not on then Draw.fade(bx + 1, by + 1, 10, 10, 0.5, true) gfx.setColor(gfx.kColorBlack) end
  end
  local bx = TOOL_X0 + n * TOOL_STEP
  Text.draw("Go:", bx + 3, y + 3, UI.fonts.bold)
  local fx = bx + 26
  local fw = 400 - fx - 24
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(fx, y + 2, fw, 14)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(fx, y + 2, fw, 14)
  gfx.drawLine(fx + 1, y + 3, fx + fw - 2, y + 3)
  local u = Text.ellipsize(url or "about:blank", UI.fonts.body, fw - 6)
  Text.draw(u, fx + 3, y + 3, UI.fonts.body)
  -- throbber
  Draw.throbber(388, y + 9, 7, frame or 0, busy)
end

--- Status bar. progress (0..1) shows a meter on the right when loading.
function Chrome.status(text, progress)
  local y = Chrome.BOTTOM
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, y, 400, Chrome.STATUS_H)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(0, y, 399, y)
  local w = progress and 300 or 394
  Text.draw(Text.ellipsize(text or "", UI.fonts.body, w), 3, y + 1, UI.fonts.body)
  if progress then
    Draw.progress(310, y + 3, 86, 8, progress, nil)
  end
end
