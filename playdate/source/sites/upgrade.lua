-- "Upgrade required": the league server refused this build (HTTP 426 upgrade_required, see
-- net/api.lua BUILD GATE). Online play needs a build from the latest source; offline play
-- (Pennant '96) works with any build, so this page always offers it. Shown by the boot splash
-- when the dial-in is refused, or over whatever is open when a later request is.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Upgrade = Page.define({ style = "browser", noToolbar = true })
Sites.Upgrade = Upgrade

Upgrade.REPO = "github.com/gopherbone/deadball"

function Upgrade:url() return "http://www.continentalleague.org/upgrade.html" end
function Upgrade:statusText() return "Document: Done. (Your copy is out of date.)" end

local function info()
  local b = Api.blocked or {}
  return b.build or Api.BUILD, b.minBuild
end

--- The obsolete-browser icon: a cracked, dusty diamond with a no-entry sign on it.
local function icon(x, y)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillPolygon(x + 20, y, x + 40, y + 20, x + 20, y + 40, x, y + 20)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillPolygon(x + 20, y + 6, x + 34, y + 20, x + 20, y + 34, x + 6, y + 20)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(x + 20, y + 6, x + 17, y + 16)
  gfx.drawLine(x + 17, y + 16, x + 23, y + 22)
  gfx.drawLine(x + 23, y + 22, x + 19, y + 34)
  -- the no-entry badge
  gfx.fillCircleAtPoint(x + 36, y + 34, 9)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x + 31, y + 33, 11, 3)
  gfx.setColor(gfx.kColorBlack)
end

function Upgrade:layout(L)
  local have, need = info()
  Draw.tile(0, 0, 400, 193, "dots")
  local ix, iy, iw = Draw.window(6, 4, 386, 184, "Diamond Navigator - Upgrade Required")
  icon(ix + 8, iy + 6)
  local tx, tw = ix + 58, iw - 66
  L:para("This version of Diamond Navigator is no longer supported.", tx, iy + 4, tw, UI.fonts.head, 2)
  L:para("The league upgraded its modems and your copy can't dial in. Bobby doesn't take bets from museum pieces.", tx, iy + 36, tw, UI.fonts.body, 3)
  -- your build vs the one the league wants, in a sunken box
  local bx, by, bw = ix + 8, iy + 80, 150
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(bx, by, bw, 32)
  Draw.bevel(bx, by, bw, 32, true)
  Text.draw("Your build:", bx + 6, by + 3, UI.fonts.body)
  Text.draw(tostring(have) .. " (old)", bx + 76, by + 3, UI.fonts.bold)
  Text.draw("Needed:", bx + 6, by + 17, UI.fonts.body)
  Text.draw(need and (tostring(need) .. " or newer") or "the latest", bx + 76, by + 17, UI.fonts.bold)
  L:para("Rebuild from the latest source (" .. Upgrade.REPO .. ") or grab the newest build on itch.io.", bx + bw + 10, by - 2, iw - bw - 26, UI.fonts.body, 3)
  L:para("Pennant '96 needs no modem and works on any build.", ix + 8, iy + 120, iw - 16, UI.fonts.body, 1)
  local y = iy + 140
  L:button("Play Pennant '96 (offline)", ix + 8, y, 186, 20, function() Upgrade.pennant() end,
    { id = "pennant", hint = "The offline season game: no server, any build" })
  L:button("Back to mode select", ix + 202, y, 168, 20, function() Upgrade.modeSelect() end,
    { id = "modes", hint = "Back to the launch screen" })
  L:mark(190)
end

function Upgrade:initialFocus()
  for i, l in ipairs(self.links) do if l.id == "pennant" then return i end end
  return 1
end

--- Leaving: the launch screen is the only way back (there's no online desktop to return to).
function Upgrade:goBack()
  Sfx.back()
  Upgrade.modeSelect()
end

function Upgrade.modeSelect()
  Boot.toModeSelect()
end

function Upgrade.pennant()
  Boot.toModeSelect()
  if Pennant then Pennant.open({ fromMode = true }) end
end

--- Shows the page in place of the online session: the stack becomes mode select + this page.
--- (The boot splash shows it itself; Pennant and the mode select are left alone; offline
--- play doesn't need the server, and the online path shows it on the next dial-in.)
function Upgrade.show()
  local t = App.top()
  if Nav.offline or t == Boot.Splash or t == Boot.ModeSelect then return end
  if t and getmetatable(t) == Upgrade then return end
  Sfx.error()
  Boot.toModeSelect()
  Upgrade.open({})
end

Api.onUpgradeRequired = function() Upgrade.show() end
