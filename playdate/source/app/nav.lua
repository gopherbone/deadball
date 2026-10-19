-- Routing between sites, the system menu, and background refresh of mail/events.

Nav = Nav or {}
Nav.ready = false   -- set once the player reaches the desktop

function Nav.person(id)
  if not id then return end
  Sites.Person.open({ id = id })
end

function Nav.team(id)
  if not id then return end
  Sites.Team.open({ id = id })
end

function Nav.story(id)
  if not id then return end
  Sites.Story.open({ id = id })
end

--- Every game has one page, the Game Hub (sites/schedule.lua): bet it, rig it, watch it.
function Nav.game(id)
  if not id then return end
  Sites.Game.open({ id = id })
end

--- BallCast for a live/final game when it's installed; otherwise the hub.
function Nav.watch(id)
  if not id then return end
  if BallCast and BallCast.scene then
    App.push(BallCast.scene, { gameId = id })
  else
    Sites.Game.open({ id = id })
  end
end

--- The bet slip for a game. With the SlateGame in hand the slip opens over the current page;
--- otherwise Bobby's opens and pops the slip once the slate is in.
function Nav.bet(gameId, side, g)
  if not gameId then Sites.Bets.open() return end
  local top = App.top()
  if g and g.home and top and top.requireFresh then
    Sites.Bets.slip(top, g, side)
  else
    Sites.Bets.open({ slip = gameId, side = side })
  end
end

--- The job planner, pre-aimed: { gameId =, targetId =, storylineId = } (all optional).
function Nav.job(opts)
  Sites.OpsPlanner.open(opts or {})
end

--- A market listing (an auction you're in): the card market's item page, if installed.
function Nav.listing(l)
  if Cards and Cards.itemScene and l then App.push(Cards.itemScene, { listing = l }) else Nav.cards("market") end
end

--- The Gossip Board opened at one storyline (its questions focused).
function Nav.storyline(id)
  Sites.Gossip.open({ storyline = id })
end

function Nav.hasCards()
  return Cards ~= nil
end

function Nav.cards(which)
  if not Cards then
    Dialog.alert("Coming soon", "The card shop is still being built. Check back after the next homestand.")
    return
  end
  local s = which == "shop" and Cards.shopScene or which == "market" and Cards.marketScene or Cards.binderScene
  if s then App.push(s) else Dialog.alert("Coming soon", "This counter isn't open yet.") end
end

--- Pops back to the desktop (bottom-most site scene).
function Nav.home()
  Nav.fwd = {}
  while #App.stack > 1 and App.top() ~= Sites.Desktop.instance do
    App.pop()
  end
end

-- History: pages left with Back can be re-opened with Forward (toolbar). ------------------

Nav.fwd = {}

--- Page:enter: a fresh visit clears the forward list (unless Forward itself opened it).
function Nav.visited(page)
  if not Nav.goingForward then Nav.fwd = {} end
end

--- Page:goBack: remember the page so Forward can bring it back.
function Nav.leaving(page)
  local def = getmetatable(page)
  if def and def.open and page.args then
    Nav.fwd[#Nav.fwd + 1] = { def = def, args = page.args }
    if #Nav.fwd > 12 then table.remove(Nav.fwd, 1) end
  end
end

function Nav.canForward() return #Nav.fwd > 0 end

function Nav.forward()
  local e = table.remove(Nav.fwd)
  if not e then Sfx.detent() return end
  local keep = Nav.fwd
  Nav.goingForward = true
  e.def.open(e.args)
  Nav.goingForward = false
  Nav.fwd = keep
end

--- The toolbar's bookmarks: the core sites, one press away from any page.
function Nav.bookmarks(x, y, w, h)
  Menu.open({ x = (x or 60) - 2, y = (y or 19) + (h or 12) + 2, items = {
    { label = "Desktop", action = function() Nav.home() end },
    "-",
    { label = "Bets By Bobby", action = function() Sites.Bets.open() end },
    { label = "The Gossip Board", action = function() Sites.Gossip.open() end },
    { label = "SportsWire", action = function() Sites.News.open() end },
    { label = "Scoreboard", action = function() Sites.Schedule.open() end },
    { label = "DiamondMail", action = function() Sites.Mail.open() end,
      note = (Game.account and (Game.account.unreadMail or 0) > 0) and tostring(Game.account.unreadMail) or nil },
    { label = "The Clubhouse BBS", action = function() Sites.BBS.open() end },
  } })
end

-- Hold B = home ------------------------------------------------------------------------------

Nav.HOLD_B = 15        -- frames (0.5 s)
Nav.holdB = 0          -- frames B has been held (drawn as a progress bar in the status line)
local holdFired = false

--- Page:BButtonUp asks this: true if the hold already took us home (so don't also go back).
function Nav.consumeHoldB()
  local f = holdFired
  holdFired = false
  return f
end

local function trackHoldB()
  if playdate.buttonIsPressed(playdate.kButtonB) then
    Nav.holdB += 1
    if Nav.holdB == Nav.HOLD_B and Nav.ready and Sites.Desktop.instance and App.top() ~= Sites.Desktop.instance
      and not (App.top() and App.top().ownHoldB) and not Nav.offline then
      holdFired = true
      Sfx.back()
      Nav.home()
    end
  else
    Nav.holdB = 0
    holdFired = false   -- the release (Page:BButtonUp) already ran this frame
  end
end

function Nav.installSystemMenu()
  local menu = playdate.getSystemMenu()
  menu:addMenuItem("home", function()
    -- online: the desktop; in Pennant: its season hub
    if Pennant and Pennant.hub and Nav.offline then Pennant.toHub()
    elseif Nav.ready then Nav.home() end
  end)
  menu:addMenuItem("mode select", function()
    if Boot and Boot.toModeSelect then Boot.toModeSelect() end
  end)
  menu:addCheckmarkMenuItem("sound", Game.settings.sound ~= false, function(on)
    Game.settings.sound = on
    Game.saveSettings()
  end)
end

-- Background refresh ---------------------------------------------------------------------

local lastPoll = 0
local POLL_MS <const> = 90000
Nav.pendingEvents = {}

function Nav.checkEvents(showFirst)
  Api.get("/events", function(err, d)
    if not d or not d.events then return end
    local before = #Nav.pendingEvents
    Nav.pendingEvents = d.events
    if Sites.Desktop.instance then Sites.Desktop.instance.dirty = true end
    if #d.events > 0 and showFirst then
      Sites.EventCard.show(d.events[1])
    elseif #d.events > before and before >= 0 and not showFirst and Nav.ready then
      Toast.show("A decision awaits you. (" .. #d.events .. ")", "mail")
    end
  end, { fresh = true })
end

function Nav.tick()
  trackHoldB()
  if (Game.frame or 0) % 30 == 0 then
    Page.collect()
    -- the desktop tune stops once an opaque page covers the desktop
    local d = Sites.Desktop.instance
    local t = App.top()
    if Sites.Desktop.playing and t ~= d and t and t.opaque ~= false then
      Sites.Desktop.playing = false
      Sfx.stopMusic(1)
    end
  end
  -- (Nav.offline: an offline program such as Pennant is up; no background polling)
  if not Nav.ready or Nav.offline or Api.isBlocked() then return end
  Pager.tick()
  if Bonus and Bonus.tick then Bonus.tick() end
  local now = playdate.getCurrentTimeMilliseconds()
  if now - lastPoll > POLL_MS then
    lastPoll = now
    Game.refreshMe()
    Nav.checkEvents(false)
  end
end

function Nav.markPolled()
  lastPoll = playdate.getCurrentTimeMilliseconds()
end
