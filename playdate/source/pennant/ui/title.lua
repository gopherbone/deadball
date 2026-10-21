-- Pennant title screen (save slots) and the new-game flow: generate a league, pick a club,
-- pick a season length.

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

-- Title ---------------------------------------------------------------------------------------

local Title = PUI.define({ title = "Welcome", hint = "A: choose  B: leave Pennant", ownHoldB = true })
PennantUI.Title = Title

function Title:init()
  self.idx = PSave.index()
  if PSave.wiped then
    PSave.wiped = false
    Toast.show("Old Pennant saves were cleared: careers now run April to October.", nil)
  end
  Sfx.music("take_me_out_organ", { loop = true, fade = 1 })
end

function Title:resume(r)
  self.idx = PSave.index()
  Page.resume(self, r)
  self:render(true)
end

function Title:layout(L)
  Draw.tile(0, 0, 400, PUI.VIEW_H, "dots")
  Draw.wordart("PENNANT '96", 200, 6, UI.fonts.slab)
  Text.draw("Continental League Baseball  \u{2022}  offline season mode", 200, 40, UI.fonts.body, nil, "center")
  local y = 60
  for k = 1, PSave.SLOTS do
    local e = self.idx[k]
    local x, w, h = 40, 320, 34
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x, y, w, h)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(x, y, w, h)
    gfx.drawRect(x + 1, y + 1, w - 2, h - 2)
    Text.draw("SLOT " .. k, x + 8, y + 4, UI.fonts.bold)
    if e then
      PUI.logo(e.team, x + 60, y + 9, 16)
      Text.draw(PUI.teamName(e.team), x + 82, y + 3, UI.fonts.bold)
      local phase = e.phase == "season" and (e.w .. "-" .. e.l .. ", " .. PUI.ord(e.rank or 1)) or (e.phase == "playoffs" and "Playoffs" or "Offseason")
      if e.ended then phase = "RUN OVER: a new run" end
      local runS = (e.run and e.run > 0) and ("run " .. e.run) or ("season " .. (e.season or 1))
      Text.draw(string.format("%d \u{2022} %s \u{2022} %s \u{2022} %s", e.year, e.date or "", phase, runS), x + 82, y + 18, UI.fonts.body)
      -- the slot's pennants
      local px = x + w - 8
      for i = 1, math.min(4, #(e.titles or {})) do
        local yr = "'" .. tostring(e.titles[i]):sub(-2)
        local tw = UI.fonts.body:getTextWidth(yr)
        px = px - tw
        Text.draw(yr, px, y + 3, UI.fonts.body)
        px = px - 11
        gfx.fillTriangle(px, y + 5, px + 9, y + 8, px, y + 11)
        px = px - 3
      end
      L:link(x, y, w, h, function() self:continue(k) end, { id = "slot" .. k, style = "ring", hint = "A: continue this career" })
    else
      Text.draw("Empty \u{2014} start a new career", x + 82, y + 10, UI.fonts.body)
      L:link(x, y, w, h, function() self:newGame(k) end, { id = "slot" .. k, style = "ring", hint = "A: new career in slot " .. k })
    end
    y = y + h + 6
  end
  local bx = 40
  L:button("New career", bx, y + 2, 84, 20, function()
    local free = nil
    for k = 1, PSave.SLOTS do if not self.idx[k] then free = k break end end
    if free then self:newGame(free) else
      Dialog.alert("All slots in use", "Delete a save first (or start over in a slot with Delete).")
    end
  end, { id = "new", hint = "Generate a fresh league and pick a club" })
  L:button("Delete...", bx + 90, y + 2, 64, 20, function() self:deleteMenu() end, { id = "del", hint = "Erase a save slot" })
  -- the legacy layer (pennant/legacy.lua): every run's alumni, every slot's
  L:button("Hall of Fame", bx + 160, y + 2, 84, 20, function() PennantUI.HallOfFame.open({}) end, { id = "hof", hint = "The All-Time Lineup and the alumni hall (shared by every slot)" })
  L:button(Pennant.opts.fromMode and "Main menu" or (Pennant.opts.fromBoot and "Go online" or "Desktop"), bx + 250, y + 2, 70, 20, function() Pennant.quit() end, { id = "quit", hint = "Leave Pennant" })
  L:mark(PUI.VIEW_H - 2)
end

function Title:goBack() Pennant.quit() end

--- Focus the slot played last.
function Title:initialFocus()
  local best, bt = nil, -1
  for k = 1, PSave.SLOTS do
    local e = self.idx[k]
    if e and (e.at or 0) > bt then best, bt = k, e.at or 0 end
  end
  if best then for i, l in ipairs(self.links) do if l.id == "slot" .. best then return i end end end
  return 1
end

function Title:continue(k)
  local L, err
  PUI.busy("Opening the ledgers", function() L, err = PSave.load(k) end)
  playdate.frameTimer.performAfterDelay(4, function()
    if not L then Dialog.alert("Couldn't load", tostring(err)) return end
    -- (a run that's over waits in its slot for a new one)
    if L.run and L.run.ended then
      Toast.show("That run is over: a new run starts in slot " .. k .. ".", nil)
      PennantUI.NewGame.open({ slot = k })
      return
    end
    Sfx.chime()
    Pennant.start(L)
  end)
end

function Title:newGame(k)
  PennantUI.NewGame.open({ slot = k })
end

function Title:deleteMenu()
  local items = {}
  for k = 1, PSave.SLOTS do
    local e = self.idx[k]
    if e then
      items[#items + 1] = { label = "Slot " .. k .. ": " .. e.team .. " " .. e.year, action = function()
        Dialog.confirm("Delete slot " .. k .. "?", "The whole career goes: every season, every record. No undo.", "Delete", "Keep", function(yes)
          if yes then PSave.delete(k) self.idx = PSave.index() self:render(true) Toast.show("Slot " .. k .. " erased.", nil) end
        end)
      end }
    end
  end
  if #items == 0 then Toast.show("Nothing to delete.", nil) return end
  Menu.open({ x = 150, y = 150, items = items })
end

-- New game -------------------------------------------------------------------------------------

local NewGame = PUI.define({ title = "New career", ownHoldB = true })
PennantUI.NewGame = NewGame

local LENGTHS <const> = { { 42, "Short (42 games)" }, { 84, "Standard (84 games)" }, { 126, "Long (126 games)" } }

function NewGame:init(args)
  self.slot = args.slot
  self.lenIdx = 2
  self.pick = nil
  self.seed = (playdate.getSecondsSinceEpoch() * 7 + math.random(1, 99999)) & 0x7FFFFFFF
  self.gen = coroutine.create(function()
    return PGen.league(self.seed, "HCL", 84, function(f)
      self.prog = f
      if playdate.getCurrentTimeMilliseconds() - (self.sliceT0 or 0) > 15 then coroutine.yield() end
    end)
  end)
  self.prog = 0
  self.generating = true
end

function NewGame:onTick()
  if self.generating then
    local t0 = playdate.getCurrentTimeMilliseconds()
    self.sliceT0 = t0
    while self.generating and playdate.getCurrentTimeMilliseconds() - t0 < 15 do
      local ok, L = coroutine.resume(self.gen)
      if not ok then print("[pennant] gen failed " .. tostring(L)) self.generating = false break end
      if coroutine.status(self.gen) == "dead" then
        self.L = L
        self.generating = false
        self:summarize()
        self:render(true)
      end
    end
  end
end

--- Team strength summaries for the club picker.
function NewGame:summarize()
  local L = self.L
  self.sum = {}
  for _, c in ipairs(PennantClubs) do
    local T = L.teams[c.abbr]
    local bat, pit, farm, nb, np, nf = 0, 0, 0, 0, 0, 0
    local star, sv = nil, -1
    for _, id in ipairs(T.ml) do
      local p = L.players[id]
      local o = PM.ovr(p)
      if p.pos == "P" then pit = pit + o np = np + 1 else bat = bat + o nb = nb + 1 end
      if o > sv then star, sv = p, o end
    end
    for _, id in ipairs(T.farm) do farm = farm + (L.players[id].pot or 40) nf = nf + 1 end
    self.sum[c.abbr] = { bat = bat / nb, pit = pit / np, farm = farm / nf, star = star }
  end
  -- pips are relative: the league's best club in each area gets five, its worst one
  for _, key in ipairs({ "bat", "pit", "farm" }) do
    local lo, hi = 1e9, -1e9
    for _, s in pairs(self.sum) do lo = math.min(lo, s[key]) hi = math.max(hi, s[key]) end
    for _, s in pairs(self.sum) do s[key] = 1 + math.floor((s[key] - lo) / math.max(0.01, hi - lo) * 4 + 0.5) end
  end
end

function NewGame:layout(L)
  if self.generating then
    Text.draw("Scouting a new league...", 200, 80, UI.fonts.head, nil, "center")
    -- (the bar is a live area: the page itself isn't re-rendered while it fills)
    L:live(100, 104, 200, 10, function(_, x, y) Draw.progress(x, y, 200, 10, self.prog or 0, "gray") end)
    Text.draw("Eight clubs, 320 players, all brand new.", 200, 124, UI.fonts.body, nil, "center")
    L:mark(PUI.VIEW_H - 2)
    return
  end
  Text.draw("Pick your club", 6, 3, UI.fonts.head)
  Text.draw("Same clubs as the online league; every player is new.", 120, 4, UI.fonts.body)
  local cw, ch = 96, 70
  for i, c in ipairs(PennantClubs) do
    local col, row = (i - 1) % 4, (i - 1) // 4
    local x, y = 4 + col * (cw + 2), 22 + row * (ch + 3)
    local sel = self.pick == c.abbr
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x, y, cw, ch)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(x, y, cw, ch)
    if sel then gfx.drawRect(x + 2, y + 2, cw - 4, ch - 4) end
    PUI.logo(c.abbr, x + 4, y + 3, 32)
    local s = self.sum[c.abbr]
    -- strengths beside the logo, the club's name under it
    Text.draw("B", x + 42, y + 2, UI.fonts.body) Draw.pips(x + 52, y + 6, s.bat, 5)
    Text.draw("P", x + 42, y + 13, UI.fonts.body) Draw.pips(x + 52, y + 17, s.pit, 5)
    Text.draw("F", x + 42, y + 24, UI.fonts.body) Draw.pips(x + 52, y + 28, s.farm, 5)
    Text.draw(Text.ellipsize(c.city, UI.fonts.bold, cw - 6), x + cw // 2, y + 39, UI.fonts.bold, nil, "center")
    Text.draw(Text.ellipsize(c.name, UI.fonts.body, cw - 6), x + cw // 2, y + 55, UI.fonts.body, nil, "center")
    local star = s.star
    L:link(x, y, cw, ch, function() self.pick = c.abbr self:render(true) end,
      { id = "club:" .. c.abbr, style = "ring", hint = "B bats, P pitching, F farm. Best: " .. PM.name(star) .. " (" .. (star.pos == "P" and star.role or star.pos) .. ", " .. PM.ovr(star) .. ")" })
  end
  local y = 22 + 2 * (ch + 3) + 1
  Text.draw("Season", 6, y + 3, UI.fonts.bold)
  local lab = LENGTHS[self.lenIdx][2]
  gfx.drawRect(56, y, 140, 18)
  Text.draw("\u{25c0} " .. lab .. " \u{25b6}", 126, y + 2, UI.fonts.body, nil, "center")
  L:link(56, y, 140, 18, function() self.lenIdx = self.lenIdx % #LENGTHS + 1 self:render(true) end,
    PUI.opts("len", "Left/right: season length (3-game series, an off day each week)", function(d) self.lenIdx = (self.lenIdx - 1 + d) % #LENGTHS + 1 end))
  -- controls: you manage by default; batting / pitching yourself is one press away, any time
  self.scheme = self.scheme or "arcade"
  local cy = Text.boxY(UI.fonts.body, y + 1, 16)
  Text.draw("Controls", 204, cy, UI.fonts.bold)
  gfx.drawRect(268, y, 124, 18)
  Text.draw("\u{25c0} " .. PScheme.NAME[self.scheme] .. " \u{25b6}", 330, cy, UI.fonts.body, nil, "center")
  L:link(268, y, 124, 18, function() self.scheme = self.scheme == "arcade" and "scout" or "arcade" self:render(true) end,
    PUI.opts("scheme", "For batting/pitching yourself: " .. PScheme.BLURB[self.scheme] .. " Change any time (Options, time out)", function(d) self.scheme = self.scheme == "arcade" and "scout" or "arcade" end))
  y = y + 20
  L:button(self.pick and ("Play ball with " .. self.pick .. "!") or "Pick a club first", 100, y, 200, 18, function() self:go() end, { id = "go", hint = "You manage; take the bat or the ball yourself whenever you like" })
  L:mark(PUI.VIEW_H - 2)
end

function NewGame:initialFocus() return 1 end

function NewGame:go()
  if not self.pick then Sfx.error() Toast.show("Pick a club first.", "bad") return end
  local L = self.L
  if self.inited and L.user ~= self.pick then
    -- (a second go after backing out of the legacy pick: the league is set up again)
    self.inited = false
  end
  if not self.inited then
    L.user = self.pick
    L.games = LENGTHS[self.lenIdx][1]
    L.settings.batScheme = self.scheme or "arcade"
    L.settings.pitchScheme = self.scheme or "arcade"
    PGen.schedule(L, PRng.new(self.seed + 5), L.games)
    PL.init(L)
    self.inited = true
  end
  -- the run (pennant/legacy.lua): two legacies and the deck, once the hall has them
  local function start(choice)
    PLegacy.beginRun(L, choice)
    L.slot = self.slot
    PUI.busy("Printing the schedule", function() PSave.saveNow(L, self.slot) end)
    playdate.frameTimer.performAfterDelay(4, function()
      Sfx.coin()
      Pennant.start(L)
    end)
  end
  if PLegacy.unlocked() then
    PennantUI.LegacyPick.open({ L = L, onDone = start })
  else
    start({})
  end
end
