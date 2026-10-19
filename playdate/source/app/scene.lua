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

App = App or {}
App.stack = {}

local function top()
  return App.stack[#App.stack]
end

function App.top()
  return top()
end

function App.push(scene, args)
  local cur = top()
  if cur and cur.pause then cur:pause() end
  table.insert(App.stack, scene)
  if scene.enter then scene:enter(args or {}) end
end

function App.pop(result)
  local s = table.remove(App.stack)
  if s and s.exit then s:exit() end
  local cur = top()
  if cur and cur.resume then cur:resume(result) end
  return s
end

function App.replace(scene, args)
  local s = table.remove(App.stack)
  if s and s.exit then s:exit() end
  table.insert(App.stack, scene)
  if scene.enter then scene:enter(args or {}) end
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
  -- the pager (ui/pager.lua) takes A while it's on screen: watch that game
  if name == "AButtonDown" and Pager and Pager.onA and Pager.onA() then return end
  local s = top()
  if s and s[name] then return s[name](s, ...) end
end

local buttons = { "A", "B", "up", "down", "left", "right" }
for _, b in ipairs(buttons) do
  playdate[b .. "ButtonDown"] = function() dispatch(b .. "ButtonDown") end
  playdate[b .. "ButtonUp"] = function() dispatch(b .. "ButtonUp") end
end

function playdate.cranked(change, accel)
  dispatch("cranked", change, accel)
end
