import "CoreLibs/object"
import "CoreLibs/graphics"
import "CoreLibs/timer"
import "CoreLibs/frameTimer"
import "CoreLibs/crank"
import "CoreLibs/ui"
import "CoreLibs/keyboard"

import "app/scene"

-- shell: ui, net, app
import "ui/theme"
import "ui/text"
import "ui/draw"
import "ui/sound"
import "ui/scroller"
import "ui/faces"
import "ui/chrome"
import "ui/status"
import "ui/page"
import "ui/overlay"
import "ui/icons"
import "ui/picker"
import "ui/menu"
import "ui/ticket"
import "ui/amount"
import "ui/composer"
import "ui/nameentry"
import "net/diskcache"
import "net/sign"
import "net/api"
import "net/fixtures"
import "app/state"
import "app/nav"
import "net/prefetch"
import "ui/pager"
import "app/debug"

-- sites
import "sites/desktop"
import "sites/bets"
import "sites/gossip"
import "sites/news"
import "sites/people"
import "sites/teams"
import "sites/standings"
import "sites/schedule"
import "sites/bbs"
import "sites/syndicate"
import "sites/mail"
import "sites/events"
import "sites/digest"
import "sites/extra"
import "sites/settings"
import "sites/credits"

-- Pennant '96: the offline season game (its own league on the device; no network)
import "pennant/main"

import "app/boot"
import "app/tour"
import "app/nettest"
import "app/netshim"

-- Optional modules from other agents. pdc resolves imports at compile time, so these
-- entry files must exist; ballcast/ and cards/ each provide a main.lua.
import "app/optional"

local gfx <const> = playdate.graphics
playdate.display.setRefreshRate(30)
gfx.setBackgroundColor(gfx.kColorWhite)
math.randomseed(playdate.getSecondsSinceEpoch())

Game.frame = 0
if Audio and Audio.init then pcall(Audio.init) end
Game.loadSettings()
Nav.installSystemMenu()

local perf = { worst = 0 }

local frame

function playdate.update()
  if Debug.trapErrors then
    local ok, e = xpcall(frame, debug.traceback)
    if not ok then
      print("ERROR: " .. tostring(e))
      Debug.trapErrors = false
      error(e)
    end
  else
    frame()
  end
end

frame = function()
  Game.frame += 1
  local t0 = playdate.getCurrentTimeMilliseconds()
  Api.update()
  Game.tick()
  gfx.clear(gfx.kColorWhite)
  App.draw()
  Toast.draw()
  Pager.draw()
  Nav.tick()
  if Debug.update then Debug.update() end
  playdate.timer.updateTimers()
  playdate.frameTimer.updateTimers()
  local dt = playdate.getCurrentTimeMilliseconds() - t0
  if dt > perf.worst then perf.worst = dt end
  Debug.lastDt = dt
  if Debug.showFps then playdate.drawFPS(2, 224) end
end

function playdate.gameWillPause()
  -- system menu image: a little business card
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  Draw.wordart("DEADBALL", 100, 40, UI.fonts.slab)
  local a = Game.account
  if a then
    Text.draw(a.name, 100, 90, UI.fonts.head, nil, "center")
    Text.draw(a.rank or "", 100, 108, UI.fonts.body, nil, "center")
    Text.draw(Fmt.money(a.money), 100, 128, UI.fonts.big, nil, "center")
    Text.draw("Heat " .. (a.heat or 0) .. "  \u{2022}  Crew " .. (a.crewSize or 0), 100, 156, UI.fonts.body, nil, "center")
  end
  Text.draw(Game.dayLabel(), 100, 200, UI.fonts.body, nil, "center")
  gfx.popContext()
  playdate.setMenuImage(img)
end

Boot.start()
