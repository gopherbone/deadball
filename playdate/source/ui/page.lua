--[[
  ui/page.lua — a "web page" scene for the Diamond Navigator browser.

  A site is defined once with Page.define{...} and opened with Site.open(args)
  (which pushes a fresh instance on the App stack). Instances inherit from the
  definition, which inherits from Page, so sites override any method they like.

  Definition fields (all optional):
    style        "browser" (default) | "bbs" (black terminal) | "bare" (no chrome)
    url(self)    -> string for the address bar
    sources(self)-> { key = "/api/path", ... } fetched in parallel into self.data[key]
    layout(self, L)  paint the page into the canvas; register links with L
    live(self, ox, oy, frame)  per-frame drawing on top (ox, oy map canvas -> screen)
    statusText(self) status bar text when idle
    refreshOnResume  re-fetch when returning to this page
    canvasH      initial canvas height guess (grows automatically)

  Controls: d-pad moves the focus ring between links (TV-browser style), A follows,
  B goes back (on release; holding B goes home, see Nav.tick), the crank scrolls with
  inertia. Up from the top of a browser page focuses the toolbar (back, forward, home,
  reload, bookmarks).
]]

local gfx <const> = playdate.graphics
local geo <const> = playdate.geometry

Page = Page or {}
Page.__index = Page
Page.style = "browser"

local MAX_CANVAS <const> = 6400
local REPEAT_DELAY <const> = 9   -- frames
local REPEAT_RATE <const> = 3

local srcRect = geo.rect.new(0, 0, 400, 100)
local tbEnabled = {}

function Page.define(def)
  def.__index = def
  setmetatable(def, Page)
  def.open = function(args)
    local inst = setmetatable({}, def)
    App.push(inst, args)
    return inst
  end
  def.replace = function(args)
    local inst = setmetatable({}, def)
    App.replace(inst, args)
    return inst
  end
  return def
end

-- Viewport per style ---------------------------------------------------------------
function Page:viewport()
  if self.style == "bbs" then
    return 0, Status.H, 400, 226 - Status.H
  elseif self.style == "bare" then
    return 0, 0, 400, 240
  end
  return 0, Chrome.TOP, 400, Chrome.VIEW_H
end

-- Layout builder -------------------------------------------------------------------
local Layout = {}
Layout.__index = Layout

function Layout:mark(y)
  if y > self.maxY then self.maxY = y end
end

--- Registers a focusable rect. opts: { hint = "status text", id = "stable key", style = "invert"|"ring"|"none", data = any }
function Layout:link(x, y, w, h, action, opts)
  opts = opts or {}
  local l = { x = x, y = y, w = w, h = h, action = action, hint = opts.hint, id = opts.id, style = opts.style or "ring", data = opts.data, onFocus = opts.onFocus }
  local links = self.links
  links[#links + 1] = l
  self:mark(y + h)
  return l
end

function Layout:text(str, x, y, font, color, align)
  font = font or UI.fonts.body
  local w = Text.draw(str, x, y, font, color, align)
  self:mark(y + font:getHeight())
  return w
end

function Layout:para(str, x, y, w, font, maxLines, color)
  local h = Text.block(str, x, y, w, font or UI.fonts.body, color, maxLines)
  self:mark(y + h)
  return h
end

--- Underlined text link. Returns w, h.
function Layout:textLink(str, x, y, action, opts)
  opts = opts or {}
  local font = opts.font or UI.fonts.body
  local w = Text.draw(str, x, y, font, opts.color)
  local h = font:getHeight()
  if not opts.noUnderline then
    gfx.setColor(opts.color == "white" and gfx.kColorWhite or gfx.kColorBlack)
    gfx.drawLine(x, y + h - 2, x + w - 1, y + h - 2)
    gfx.setColor(gfx.kColorBlack)
  end
  opts.style = opts.style or "invert"
  self:link(x - 2, y - 1, w + 4, h, action, opts)
  return w, h
end

function Layout:button(label, x, y, w, h, action, opts)
  Draw.button(x, y, w, h, label, opts and opts.state, opts and opts.font)
  local o = opts or {}
  o.style = o.style or "ring"
  return self:link(x, y, w, h, action, o)
end

function Layout:face(id, x, y, size, action, opts)
  local w, h = Faces.draw(id, x, y, size, opts)
  self:mark(y + h + 1)
  if action then self:link(x - 1, y - 1, w + 2, h + 2, action, opts) end
  return w, h
end

--- Registers a per-frame drawer for an area of the canvas (culled when offscreen).
function Layout:live(x, y, w, h, fn)
  local lv = self.lives
  lv[#lv + 1] = { x = x, y = y, w = w, h = h, fn = fn }
  self:mark(y + h)
end

-- Lifecycle -------------------------------------------------------------------------

function Page:enter(args)
  self.args = args or {}
  self.frame = 0
  self.data = {}
  self.links = {}
  self.lives = {}
  self.focus = 0
  self.scroll = Scroller.new(0)
  self.ring = nil
  self.reveal = 1
  self.held = {}
  self.idleFrames = 0
  self.tb = nil
  Nav.visited(self)
  if self.init then self:init(self.args) end
  self:reload()
end

function Page:exit()
  self.closed = true
  self.canvas = nil
  if self.cleanup then self:cleanup() end
end

function Page:pause()
  -- free the canvas while another opaque page covers us; re-render on resume
  self.paused = true
end

function Page:resume(result)
  self.paused = false
  if self.onResult and result ~= nil then self:onResult(result) end
  if self.refreshOnResume then
    self:reload(true)
  elseif not self.canvas then
    self:render(true)
  end
end

--- Fetches self.sources() (if any), then renders. quiet = keep current canvas while loading.
--- A non-quiet load paints the last saved copy right away when every required source has
--- one (stale-while-revalidate; Api.peek: memory or disk cache), then refreshes behind it.
function Page:reload(quiet)
  local srcs = self.sources and self:sources() or nil
  if not srcs or next(srcs) == nil then
    self.loading = false
    self:render(quiet)
    if not quiet then self.reveal = 0 end
    return
  end
  if not quiet and self:paintStale(srcs) then
    self:fetchSources(srcs, "revalidate")
    return
  end
  self.loading = true
  self.err = nil
  self.loadStart = self.frame
  if not quiet then self.canvas = nil end
  self:fetchSources(srcs, quiet and "quiet" or "load")
end

local function srcPath(src)
  if type(src) == "table" then return src[1], src.optional end
  return src, false
end

--- Paints cached copies of srcs if all required ones exist and any is past its ttl.
--- Sites opt out with `swr = false`; fixture mode never needs it.
function Page:paintStale(srcs)
  if self.swr == false or Api.isFixtureMode() then return false end
  local stale, anyStale, oldest = {}, false, 0
  for key, src in pairs(srcs) do
    local path, optional = srcPath(src)
    local d, age, fresh = Api.peek(path)
    if d then
      stale[key] = d
      if not fresh then
        anyStale = true
        if age > oldest then oldest = age end
      end
    elseif not optional then
      return false
    end
  end
  -- all fresh in memory: the normal load answers next frame, nothing to paint early
  if not anyStale then return false end
  for k, v in pairs(stale) do self.data[k] = v end
  self.loading = false
  self.err = nil
  self.stale = true
  self.staleAge = oldest
  self.staleErr = nil
  print(string.format("[page] %s: painted saved copy (%d s old), updating", self:url(), oldest))
  if self.loaded then self:loaded() end
  self:render()
  self.reveal = 0
  return true
end

--- mode: "load" (spinner, fresh render), "quiet" (keep canvas, bypass the cache) or
--- "revalidate" (stale copy on screen; on error keep it and say so in the status bar).
function Page:fetchSources(srcs, mode)
  local pending = 0
  local firstErr = nil
  local results = {}
  for _ in pairs(srcs) do pending += 1 end
  if mode == "revalidate" then
    self.updating = true
  else
    self.loadTotal = pending
    self.loadDone = 0
  end
  local gen = (self.loadGen or 0) + 1
  self.loadGen = gen
  for key, src in pairs(srcs) do
    local path, optional = srcPath(src)
    Api.get(path, function(err, d)
      if self.loadGen ~= gen or self.closed then return end   -- superseded or page gone
      if err and not firstErr and not optional then firstErr = err end
      results[key] = d
      Game.absorb(d)
      pending -= 1
      if mode ~= "revalidate" then self.loadDone += 1 end
      if pending == 0 then
        self.updating = false
        if mode == "revalidate" and firstErr then
          -- keep the saved copy up; the status bar says it's old
          self.staleErr = firstErr
          print("[page] " .. self:url() .. ": refresh failed, keeping saved copy")
          self:render(true)
          return
        end
        for k, v in pairs(results) do self.data[k] = v end
        self.stale = false
        self.staleErr = nil
        self.loading = false
        self.err = firstErr
        if self.loaded then self:loaded() end
        self:render(mode ~= "load")
        if mode == "load" then self.reveal = 0 end
      end
    end, { fresh = mode == "quiet" })
  end
end

--- Money-moving actions call this first: false (with a toast) while the page still shows
--- a saved copy, so nobody bets against yesterday's pools.
function Page:requireFresh()
  if not self.stale then return true end
  Toast.show(self.updating and "Hang on, still updating this page." or "This is a saved copy. Reload when the server answers.", "bad")
  return false
end

--- Paints the page into its canvas. keepFocus restores the focused link by id.
function Page:render(keepFocus)
  local prevId = nil
  local cur = self.links and self.links[self.focus]
  if keepFocus and cur then prevId = cur.id or (cur.x .. ":" .. cur.y) end
  local vx, vy, vw, vh = self:viewport()
  local h = self.canvasH or 480
  while true do
    if not self.canvas or self.canvasAllocH ~= h then
      self.canvas = gfx.image.new(vw, h, gfx.kColorWhite)
      self.canvasAllocH = h
    else
      self.canvas:clear(gfx.kColorWhite)
    end
    local L = setmetatable({ page = self, w = vw, h = vh, maxY = 0, links = {}, lives = {} }, Layout)
    gfx.pushContext(self.canvas)
    gfx.setColor(gfx.kColorBlack)
    gfx.setLineWidth(1)
    if self.err then
      self:layoutError(L)
    elseif self.loading then
      self:layoutLoading(L)
    elseif self.layout then
      local ok, e = pcall(self.layout, self, L)
      if not ok then
        print("[page] layout error: " .. tostring(e))
        gfx.popContext()
        gfx.pushContext(self.canvas)
        self.canvas:clear(gfx.kColorWhite)
        L = setmetatable({ page = self, w = vw, h = vh, maxY = 0, links = {}, lives = {} }, Layout)
        self.err = { code = "render", message = tostring(e) }
        self:layoutError(L)
      end
    end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    gfx.setColor(gfx.kColorBlack)
    gfx.popContext()
    if L.maxY + 8 > h and h < MAX_CANVAS then
      h = math.min(MAX_CANVAS, math.max(h * 2, L.maxY + 16))
      self.canvasH = h
    else
      self.links = L.links
      self.lives = L.lives
      self.contentH = math.max(vh, math.min(h, L.maxY + 8))
      break
    end
  end
  -- a page may forgive a few px of overflow (the bottom padding), so it doesn't scroll for nothing
  if self.contentH - vh <= (self.scrollSlack or 0) then self.contentH = vh end
  self.scroll:setMax(self.contentH - vh)
  -- restore focus
  self.focus = 0
  if prevId then
    for i, l in ipairs(self.links) do
      if (l.id or (l.x .. ":" .. l.y)) == prevId then self.focus = i end
    end
  end
  if self.focus == 0 and #self.links > 0 then
    self.focus = self.initialFocus and self:initialFocus() or self:firstVisibleLink(1) or 0
    self.ring = nil
  end
  if self.afterRender then self:afterRender() end
end

function Page:layoutLoading(L)
  local vx, vy, vw, vh = self:viewport()
  if self.style == "bbs" then
    L:text("CONNECTING...", 8, 8, UI.fonts.mono, "white")
    return
  end
  L:mark(vh - 8)
end

function Page:layoutError(L)
  local vx, vy, vw, vh = self:viewport()
  local e = self.err or {}
  local x = 40
  local y = 18
  local code = e.status == 404 or e.code == "not_found"
  -- big broken-page icon
  gfx.drawRect(x, y, 34, 40)
  gfx.drawLine(x + 24, y, x + 34, y + 10)
  gfx.drawLine(x + 6, y + 14, x + 26, y + 34)
  gfx.drawLine(x + 26, y + 14, x + 6, y + 34)
  local title = code and "404 Not Found" or (e.code == "render" and "This page has a bug in it" or "The server is not responding")
  L:text(title, x + 46, y, UI.fonts.head)
  local h = L:para(Api.errorText(e), x + 46, y + 18, 290, UI.fonts.body, 5)
  local by = math.max(y + 48, y + 22 + h)
  L:button("Retry", x + 46, by, 70, 18, function() self:reload() end, { id = "retry" })
  L:button("Back", x + 124, by, 70, 18, function() self:goBack() end, { id = "back" })
  Draw.stripes(0, vh - 18, vw, 14, "UNDER CONSTRUCTION")
  L:mark(vh - 4)
end

-- Focus & navigation --------------------------------------------------------------

function Page:linkVisible(l, margin)
  local _, _, _, vh = self:viewport()
  local sy = self.scroll:y()
  margin = margin or 0
  return l.y + l.h > sy + margin and l.y < sy + vh - margin
end

function Page:firstVisibleLink(dir)
  local best, bestY = nil, nil
  for i, l in ipairs(self.links) do
    if self:linkVisible(l, 2) then
      if not best or (dir > 0 and l.y < bestY) or (dir < 0 and l.y > bestY) or (l.y == bestY and l.x < self.links[best].x) then
        best, bestY = i, l.y
      end
    end
  end
  return best
end

function Page:ensureVisible(l)
  local _, _, _, vh = self:viewport()
  local sy = self.scroll.target or self.scroll.pos
  local pad = 14
  if l.h > vh - pad * 2 then
    self.scroll:scrollTo(l.y - pad)
  elseif l.y < sy + pad then
    self.scroll:scrollTo(l.y - pad)
  elseif l.y + l.h > sy + vh - pad then
    self.scroll:scrollTo(l.y + l.h - vh + pad)
  end
end

function Page:setFocus(i, silent)
  if i == self.focus then return end
  self.focus = i
  local l = self.links[i]
  if l then
    self:ensureVisible(l)
    if l.onFocus then l.onFocus(self, l) end
  end
  if not silent then Sfx.focus() end
end

--- Up from the top of a browser page: focus the toolbar buttons.
function Page:enterToolbar()
  if self.style ~= "browser" or self.noToolbar then return false end
  local sy = self.scroll.target or self.scroll.pos
  if sy > 2 then return false end
  self.tb = 1
  self.tbLink = self.focus
  Sfx.focus()
  return true
end

function Page:toolbarEnabled(i)
  if i == 1 then return #App.stack > 1 end
  if i == 2 then return Nav.canForward() end
  if i == 3 then return App.top() ~= Sites.Desktop.instance end
  return true
end

function Page:toolbarMove(dx, dy)
  if dy > 0 then
    self.tb = nil
    Sfx.focus()
    return
  end
  if dy < 0 then self:bump() return end
  local n = #Chrome.TOOL_BUTTONS
  local i = math.max(1, math.min(n, self.tb + dx))
  if i == self.tb then self:bump() else self.tb = i Sfx.focus() end
end

function Page:toolbarActivate()
  local i = self.tb
  if not self:toolbarEnabled(i) then self:bump() return end
  Sfx.select()
  local what = Chrome.TOOL_BUTTONS[i]
  self.tb = nil
  if what == "back" then self:goBack()
  elseif what == "forward" then Nav.forward()
  elseif what == "home" then Nav.home()
  elseif what == "reload" then self:reload(true) Toast.show("Reloading...", nil)
  else Nav.bookmarks(Chrome.toolButtonRect(i)) end
end

function Page:moveFocus(dx, dy)
  if self.tb then return self:toolbarMove(dx, dy) end
  local links = self.links
  local _, _, _, vh = self:viewport()
  local cur = links[self.focus]
  if #links == 0 then
    if dy < 0 and (self.scroll.target or self.scroll.pos) <= 2 and self:enterToolbar() then return end
    if dy ~= 0 then self.scroll:scrollBy(dy * 48) end
    return
  end
  if not cur or not self:linkVisible(cur, 0) then
    local i = self:firstVisibleLink(dy ~= 0 and dy or 1)
    if i then
      self:setFocus(i)
    elseif dy ~= 0 then
      self.scroll:scrollBy(dy * 60)
    end
    return
  end
  local cx, cy = cur.x + cur.w / 2, cur.y + cur.h / 2
  local best, bestScore = nil, math.huge
  for i, l in ipairs(links) do
    if i ~= self.focus then
      local lx, ly = l.x + l.w / 2, l.y + l.h / 2
      local ok, primary, secondary = false, 0, 0
      if dy ~= 0 then
        if (dy > 0 and ly > cy + 2 and l.y >= cur.y + 2) or (dy < 0 and ly < cy - 2 and l.y + l.h <= cur.y + cur.h - 2) then
          ok = true
          primary = math.abs(ly - cy)
          local ov = math.min(l.x + l.w, cur.x + cur.w) - math.max(l.x, cur.x)
          secondary = ov > 0 and 0 or (-ov + 20)
        end
      else
        if (dx > 0 and lx > cx + 2 and l.x >= cur.x + cur.w - 4) or (dx < 0 and lx < cx - 2 and l.x + l.w <= cur.x + 4) then
          ok = true
          primary = math.abs(lx - cx)
          local ov = math.min(l.y + l.h, cur.y + cur.h) - math.max(l.y, cur.y)
          secondary = ov > 0 and 0 or (-ov + 30)
        end
      end
      if ok then
        local score = primary + secondary * 2.5
        if score < bestScore then best, bestScore = i, score end
      end
    end
  end
  if best then
    local l = links[best]
    -- long gap below/above: scroll a step first so the reader sees the text between links
    if dy ~= 0 and not self:linkVisible(l, 0) then
      local sy = self.scroll.target or self.scroll.pos
      local gap = dy > 0 and (l.y - (sy + vh)) or (sy - (l.y + l.h))
      if gap > vh * 0.5 then
        self.scroll:scrollBy(dy * math.floor(vh * 0.6))
        return
      end
    end
    self:setFocus(best)
  elseif dy ~= 0 then
    local before = self.scroll.target or self.scroll.pos
    if dy < 0 and before <= 2 and self:enterToolbar() then return end
    self.scroll:scrollBy(dy * 60)
    if (self.scroll.target or before) == before then self:bump() end
  else
    self:bump()
  end
end

--- Does this link use left/right itself (a value cycler: opts.data.adj in Pennant pages,
--- data.adjust in Preferences) instead of moving the focus? The rule: only a link alone on its
--- row may; on a row of several, left/right always moves between them and A changes the value.
--- Pages that take left/right some other way override this (the tour's navcheck asks it).
function Page:linkTakesLR(l)
  local d = l and l.data
  return d ~= nil and type(d) == "table" and (d.adj ~= nil or d.adjust ~= nil)
end

function Page:bump()
  self.bumpT = 6
  Sfx.detent()
end

function Page:activate()
  if self.tb then return self:toolbarActivate() end
  local l = self.links[self.focus]
  if not l or not self:linkVisible(l, -4) then
    Sfx.detent()
    return
  end
  self.pressT = 5
  Sfx.select()
  if l.action then l.action(self, l) end
end

function Page:goBack()
  if #App.stack > 1 then
    Sfx.back()
    Nav.leaving(self)
    App.pop()
  else
    Sfx.detent()
  end
end

-- Input ---------------------------------------------------------------------------------

function Page:upButtonDown() self.held.up = 0 self.idleFrames = 0 self:moveFocus(0, -1) end
function Page:downButtonDown() self.held.down = 0 self.idleFrames = 0 self:moveFocus(0, 1) end
function Page:leftButtonDown() self.held.left = 0 self.idleFrames = 0 self:moveFocus(-1, 0) end
function Page:rightButtonDown() self.held.right = 0 self.idleFrames = 0 self:moveFocus(1, 0) end
function Page:upButtonUp() self.held.up = nil end
function Page:downButtonUp() self.held.down = nil end
function Page:leftButtonUp() self.held.left = nil end
function Page:rightButtonUp() self.held.right = nil end
function Page:AButtonDown() self.idleFrames = 0 self:activate() end
-- B acts on release so that holding it can mean "home" instead (Nav.tick)
function Page:BButtonDown() self.idleFrames = 0 self.bDown = true end
function Page:BButtonUp()
  if not self.bDown then return end
  self.bDown = false
  if Nav.consumeHoldB() then return end
  if self.tb then self.tb = nil Sfx.back() return end
  self:goBack()
end
function Page:cranked(change)
  self.idleFrames = 0
  self.scroll:crank(change)
end

local DIRS <const> = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
--- (app/scene.lua) Buttons that were down when the screen changed: their holds/repeats stop here.
function Page:inputLatched(set)
  for k in pairs(set) do self.held[k] = nil end
  if set.B then self.bDown = false end
end

function Page:repeatKeys()
  for k, t in pairs(self.held) do
    -- (only while it's still down from a press on this page: a release we didn't see ends it)
    if not App.isHeld(k) then
      self.held[k] = nil
    else
      t += 1
      self.held[k] = t
      if t >= REPEAT_DELAY and (t - REPEAT_DELAY) % REPEAT_RATE == 0 then
        local d = DIRS[k]
        self:moveFocus(d[1], d[2])
      end
    end
  end
end

-- Drawing -----------------------------------------------------------------------------------

function Page:drawRing(l, sx, sy, vy, vh)
  -- animated ring: eases toward the focused rect
  local tx, ty, tw, th = l.x + sx, l.y + sy, l.w, l.h
  local r = self.ring
  if not r or Game.settings.reduceMotion then
    r = { x = tx, y = ty, w = tw, h = th }
    self.ring = r
  else
    r.x += (tx - r.x) * 0.5
    r.y += (ty - r.y) * 0.5
    r.w += (tw - r.w) * 0.5
    r.h += (th - r.h) * 0.5
    if math.abs(tx - r.x) < 0.5 then r.x = tx end
    if math.abs(ty - r.y) < 0.5 then r.y = ty end
    if math.abs(tw - r.w) < 0.5 then r.w = tw end
    if math.abs(th - r.h) < 0.5 then r.h = th end
  end
  local x, y, w, h = math.floor(r.x + 0.5), math.floor(r.y + 0.5), math.floor(r.w + 0.5), math.floor(r.h + 0.5)
  if self.bumpT and self.bumpT > 0 then
    x += (self.bumpT % 2 == 0) and 1 or -1
  end
  gfx.setClipRect(0, vy, 400, vh)
  if l.style == "invert" then
    gfx.setColor(gfx.kColorXOR)
    gfx.fillRect(x, y, w, h)
    gfx.setColor(gfx.kColorBlack)
  elseif l.style == "ring" then
    local pulse = (self.frame // 8) % 2
    local p = 2 + ((self.pressT and self.pressT > 0) and -1 or 0)
    local fg, bg = gfx.kColorBlack, gfx.kColorWhite
    if self.style == "bbs" then fg, bg = bg, fg end
    gfx.setColor(fg)
    gfx.setLineWidth(2)
    gfx.drawRoundRect(x - p - 1, y - p - 1, w + p * 2 + 2, h + p * 2 + 2, 3)
    gfx.setLineWidth(1)
    if pulse == 1 then
      gfx.setColor(bg)
      gfx.drawRoundRect(x - p - 3, y - p - 3, w + p * 2 + 6, h + p * 2 + 6, 4)
      gfx.setColor(gfx.kColorBlack)
    end
  elseif l.style == "invert-white" then
    gfx.setColor(gfx.kColorXOR)
    gfx.fillRect(x, y, w, h)
    gfx.setColor(gfx.kColorBlack)
  end
  gfx.clearClipRect()
end

function Page:url()
  return "about:blank"
end

function Page:statusLine()
  if self.tb then
    local what = Chrome.TOOL_BUTTONS[self.tb]
    return Chrome.TOOL_HINTS[what] .. (self:toolbarEnabled(self.tb) and "" or " (nothing there)") .. "   \u{25bc}: back to the page"
  end
  if Nav.holdB > 4 then return "Keep holding B: home..." end
  if self.loading then
    local host = Api.isFixtureMode() and "localhost (offline)" or Api.config.host
    if self.frame - (self.loadStart or 0) < 6 then return "Contacting " .. host .. "..." end
    return "Transferring data from " .. host .. "..."
  end
  if self.err then return "Document contains no data." end
  local l = self.links[self.focus]
  local hint = l and l.hint and self:linkVisible(l, 0) and l.hint or nil
  if self.updating then return "Updating... " .. (hint or "") end
  if self.staleErr then return "Saved copy, " .. Fmt.dur(math.min(self.staleAge or 0, 999999) * 1000) .. " old (server not answering)" end
  if hint then return hint end
  if self.statusText then return self:statusText() end
  return "Document: Done."
end

function Page:drawContent(covered)
  local vx, vy, vw, vh = self:viewport()
  local sy = self.scroll:y()
  local bg = self.style == "bbs" and gfx.kColorBlack or gfx.kColorWhite
  if self.canvas then
    local revealH = vh
    if self.reveal < 1 then
      self.reveal = math.min(1, self.reveal + (Game.settings.reduceMotion and 1 or 0.2))
      revealH = math.floor(vh * self.reveal)
    end
    srcRect.x, srcRect.y, srcRect.width, srcRect.height = 0, sy, vw, math.max(0, math.min(revealH, self.canvasAllocH - sy))
    if srcRect.y < 0 then
      gfx.setColor(bg)
      gfx.fillRect(vx, vy, vw, -srcRect.y)
      srcRect.height += srcRect.y
      srcRect.y = 0
      self.canvas:draw(vx, vy - sy, gfx.kImageUnflipped, srcRect)
    else
      self.canvas:draw(vx, vy, gfx.kImageUnflipped, srcRect)
    end
    if revealH < vh then
      gfx.setColor(bg)
      gfx.fillRect(vx, vy + revealH, vw, vh - revealH)
      -- a "scanline" leading edge like a slow modem paint
      Draw.fade(vx, vy + revealH, vw, 3, 0.5, bg == gfx.kColorBlack)
      gfx.setColor(gfx.kColorBlack)
    end
    -- bottom overscroll fill
    local drawnBottom = vy + (self.canvasAllocH - sy)
    if drawnBottom < vy + vh then
      gfx.setColor(bg)
      gfx.fillRect(vx, drawnBottom, vw, vy + vh - drawnBottom)
      gfx.setColor(gfx.kColorBlack)
    end
  else
    gfx.setColor(bg)
    gfx.fillRect(vx, vy, vw, vh)
    gfx.setColor(gfx.kColorBlack)
  end
  -- live widgets
  local ox, oy = vx, vy - sy
  if self.canvas and self.reveal >= 1 then
    gfx.setClipRect(vx, vy, vw, vh)
    for _, lv in ipairs(self.lives) do
      if lv.y + lv.h > sy and lv.y < sy + vh then
        lv.fn(self, ox + lv.x, oy + lv.y, self.frame)
      end
    end
    if self.live then self:live(ox, oy, self.frame) end
    gfx.clearClipRect()
  end
  -- focus ring (not while the toolbar has focus)
  local l = (not self.tb) and self.links[self.focus] or nil
  if l and self.reveal >= 1 and not self.loading and self:linkVisible(l, -2) then
    self:drawRing(l, ox, oy, vy, vh)
  else
    self.ring = nil
  end
  -- loading overlay (centered)
  if self.loading and self.frame - (self.loadStart or 0) > 4 then
    self:drawLoading(vx, vy, vw, vh)
  end
  -- scrollbar
  if self.scroll.max > 0 and self.style ~= "bare" then
    local frac = vh / (self.scroll.max + vh)
    local pos = self.scroll.pos / self.scroll.max
    if self.style == "bbs" then
      gfx.setColor(gfx.kColorWhite)
      local th = math.max(10, math.floor(vh * frac))
      local ty = vy + math.floor((vh - th) * math.max(0, math.min(1, pos)))
      gfx.fillRect(397, ty, 3, th)
      gfx.setColor(gfx.kColorBlack)
    else
      Draw.scrollbar(393, vy, vh, frac, pos)
    end
  end
end

function Page:drawLoading(vx, vy, vw, vh)
  local cx, cy = vx + vw // 2, vy + vh // 2
  if self.style == "bbs" then
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(cx - 80, cy - 10, 160, 20)
    local dots = string.rep(".", (self.frame // 6) % 4)
    Text.draw("CARRIER DETECT" .. dots, cx - 70, cy - 7, UI.fonts.mono, "white")
    return
  end
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(cx - 74, cy - 22, 148, 44)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(cx - 74, cy - 22, 148, 44)
  gfx.drawRect(cx - 72, cy - 20, 144, 40)
  Draw.throbber(cx - 52, cy, 11, self.frame, true)
  Text.draw("Loading" .. string.rep(".", (self.frame // 5) % 4), cx - 34, cy - 12, UI.fonts.bold)
  local frac = ((self.frame - (self.loadStart or 0)) % 40) / 40
  -- indeterminate barber-pole bar
  gfx.drawRect(cx - 34, cy + 4, 96, 8)
  gfx.setPattern(UI.pat.diag, (self.frame * 2) % 8, 0)
  gfx.fillRect(cx - 32, cy + 6, 92, 4)
  gfx.setColor(gfx.kColorBlack)
end

--- Frees canvases of pages buried under opaque scenes (they re-render on resume).
function Page.collect()
  local now = Game.frame or 0
  for i = 1, #App.stack - 1 do
    local s = App.stack[i]
    if s.canvas and s.lastDrawn and now - s.lastDrawn > 30 and not s.keepCanvas then
      s.canvas = nil
      s.canvasAllocH = nil
    end
  end
end

function Page:update(covered)
  self.lastDrawn = Game.frame
  self.frame += 1
  if not covered then self:repeatKeys() end
  self.idleFrames += 1
  if self.bumpT and self.bumpT > 0 then self.bumpT -= 1 end
  if self.pressT and self.pressT > 0 then self.pressT -= 1 end
  self.scroll:update()
  if not self.canvas and not self.loading then self:render(true) end
  if self.tick then self:tick() end
  if self.underlay then self:underlay() end
  self:drawContent(covered)
  if self.style == "browser" then
    Chrome.menubar()
    if self.tb then
      for i = 1, #Chrome.TOOL_BUTTONS do tbEnabled[i] = self:toolbarEnabled(i) end
    end
    Chrome.toolbar(self:url(), self.frame, self.loading or Api.busy() > 0, self.tb, self.tb and tbEnabled or nil)
    local prog = nil
    if self.loading then
      prog = ((self.loadDone or 0) + math.min(0.9, (self.frame - (self.loadStart or 0)) / 30)) / math.max(1, self.loadTotal or 1)
    elseif Nav.holdB > 4 then
      prog = Nav.holdB / Nav.HOLD_B
    end
    Chrome.status(self:statusLine(), prog)
  end
  if self.style == "bbs" then
    Chrome.menubar("dark")
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(0, 226, 400, 14)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawLine(0, 226, 399, 226)
    gfx.setColor(gfx.kColorBlack)
    local st = self.loading and "CARRIER DETECT..." or self:statusLine()
    if st == "Document: Done." or st == "" then st = "A: select   B: hang up   hold B: home   crank: scroll" end
    Text.draw(Text.ellipsize(st, UI.fonts.body, 390), 4, 228, UI.fonts.body, "white")
    if Nav.holdB > 4 then
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(330, 230, math.floor(66 * math.min(1, Nav.holdB / Nav.HOLD_B)), 7)
      gfx.drawRect(330, 230, 66, 7)
      gfx.setColor(gfx.kColorBlack)
    end
  end
  if self.overlay then self:overlay() end
  -- crank hint after a while idle on a long page
  if not covered and self.scroll.max > 40 and playdate.isCrankDocked() and self.idleFrames > 120 then
    playdate.ui.crankIndicator:draw(0, (self.style == "bbs" or self.style == "bare") and 0 or -Chrome.STATUS_H)
  elseif self.idleFrames == 1 then
    playdate.ui.crankIndicator:resetAnimation()
  end
end
