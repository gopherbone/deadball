-- Scene stack shared by every part of the client.
--
-- A scene is a plain table. All methods are optional:
--   scene:enter(args)        pushed (or returned to with args = nil and resumed = true)
--   scene:exit()             popped
--   scene:pause() / resume() another scene pushed on top / popped back to this one
--   scene:update()           once per frame; draw here (the stack does not clear the screen)
--   scene:AButtonDown(), BButtonDown(), upButtonDown(), downButtonDown(),
--   leftButtonDown(), rightButtonDown() (+ ...Up variants), cranked(change, accel)
--   scene.opaque = false     draw the scene below first (dialogs/overlays)
--   scene:inputLatched(set)  buttons in `set` (names: A B up down left right) were down when the
--                            screen changed: cancel any hold/charge/repeat this scene began with them
--
-- Input is on-press: a button already down when a screen appears belongs to the screen it was
-- pressed on. Every push/pop/replace (and App.latch(), for a menu/card/panel that appears inside
-- a scene) latches the buttons held right then: their release is swallowed, and App.isHeld()
-- reports them up until they've been let go. So a confirm only ever fires on a fresh press made
-- while the new UI is up, and a hold (hold A, hold B, d-pad repeat) only counts from one.

App = App or {}
App.stack = {}

local function top()
  return App.stack[#App.stack]
end

function App.top()
  return top()
end

-- Input latch (see the header) -------------------------------------------------------------

local BTN <const> = { A = playdate.kButtonA, B = playdate.kButtonB, up = playdate.kButtonUp,
  down = playdate.kButtonDown, left = playdate.kButtonLeft, right = playdate.kButtonRight }
local NAME = {}
for n, m in pairs(BTN) do NAME[m] = n end
App.latched = {}     -- button name -> true: down since before the current screen; ignored until up
App.fakeHeld = {}    -- (tour probes: button name -> true counts as physically down)
App.latches = { A = 0, B = 0, up = 0, down = 0, left = 0, right = 0 }   -- times each was latched

local function down(n) return App.fakeHeld[n] == true or playdate.buttonIsPressed(BTN[n]) end

--- Latch every button that's down right now (the screen/menu/card under it just changed).
function App.latch()
  local set = nil
  for n in pairs(BTN) do
    if down(n) and not App.latched[n] then
      App.latched[n] = true
      App.latches[n] += 1
      set = set or {}
      set[n] = true
    end
  end
  if set then
    local s = top()
    if s and s.inputLatched then s:inputLatched(set) end
  end
end

--- Is this button (name or playdate.kButton* mask) down from a press made on the current screen?
--- The polled replacement for playdate.buttonIsPressed in anything that acts on a hold.
function App.isHeld(b)
  local n = NAME[b] or b
  return down(n) and not App.latched[n]
end

--- Once a frame: a latch ends when its button is up (a release the stack missed).
function App.inputTick()
  for n in pairs(App.latched) do
    if not down(n) then App.latched[n] = nil end
  end
end

function App.push(scene, args)
  local cur = top()
  if cur and cur.pause then cur:pause() end
  table.insert(App.stack, scene)
  if scene.enter then scene:enter(args or {}) end
  App.latch()
end

function App.pop(result)
  local s = table.remove(App.stack)
  if s and s.exit then s:exit() end
  local cur = top()
  if cur and cur.resume then cur:resume(result) end
  App.latch()
  return s
end

function App.replace(scene, args)
  local s = table.remove(App.stack)
  if s and s.exit then s:exit() end
  table.insert(App.stack, scene)
  if scene.enter then scene:enter(args or {}) end
  App.latch()
end

-- Snapshot of the scenes under a modal. Redrawing a whole page (or a composer over a
-- page) every frame just to dim it behind a picker cost 30-70 ms on the device, so the
-- covered scenes are drawn once per stack change and the image is reused.
local below = { img = nil, top = nil, n = 0 }

--- Draw every non-opaque scene from the nearest opaque one upward.
function App.draw()
  local n = #App.stack
  if n == 0 then return end
  local first = n
  while first > 1 and App.stack[first].opaque == false do first = first - 1 end
  local top = App.stack[n]
  if first < n then
    if below.top ~= top or below.n ~= n or not below.img then
      for i = first, n - 1 do
        local s = App.stack[i]
        if s.update then s:update(true) end
      end
      below.img = playdate.graphics.getWorkingImage()
      below.top, below.n = top, n
    else
      below.img:draw(0, 0)
    end
  else
    below.img, below.top = nil, nil
  end
  if top.update then top:update(false) end
end

local function dispatch(name, ...)
  local b, edge = name:match("^(%a-)Button(%a+)$")
  if b then
    if edge == "Down" then
      App.latched[b] = nil          -- a fresh press: this screen's
    elseif App.latched[b] then
      App.latched[b] = nil          -- the release of a press made before this screen: not ours
      return
    end
  end
  -- the pager (ui/pager.lua) takes A while it's on screen: watch that game
  if name == "AButtonDown" and Pager and Pager.onA and Pager.onA() then return end
  local s = top()
  if s and s[name] then return s[name](s, ...) end
end

App.dispatch = dispatch   -- (tour probes: a button edge through the router, latch and all)

local buttons = { "A", "B", "up", "down", "left", "right" }
for _, b in ipairs(buttons) do
  playdate[b .. "ButtonDown"] = function() dispatch(b .. "ButtonDown") end
  playdate[b .. "ButtonUp"] = function() dispatch(b .. "ButtonUp") end
end

function playdate.cranked(change, accel)
  dispatch("cranked", change, accel)
end
