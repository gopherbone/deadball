-- The Clubhouse BBS: a black terminal for your crew. Crew roster, recruiting,
-- the operation planner and the op log.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local MONO = UI.fonts.mono
local CW <const> = 8    -- mono advance (approx.)

--- Shared BBS chrome: inverted title bar + right-aligned node text.
local function header(L, title, right)
  gfx.setColor(gfx.kColorWhite)
  local tw = MONO:getTextWidth(" " .. title .. " ")
  gfx.fillRect(4, 3, tw, 16)
  local ty = Text.boxY(MONO, 3, 16)
  Text.draw(" " .. title .. " ", 4, ty, MONO)
  Text.draw(right or "", 392, ty, MONO, "white", "right")
  gfx.setColor(gfx.kColorBlack)
  L:mark(20)
  return 22
end
Sites.bbsHeader = header

local function menuKey(L, x, y, key, rest, action, hint, id)
  -- "[R]ecruit" style: the bracketed letter is the link
  local s = "[" .. key .. "]" .. rest
  local w = Text.draw(s, x, y, MONO, "white")
  L:link(x - 1, y, w + 2, 16, action, { id = id or ("menu:" .. key), hint = hint, style = "invert" })
  return w
end
Sites.bbsMenuKey = menuKey

local STATUS_LABEL <const> = { ok = "OK", free = "OK", busy = "ON A JOB", jailed = "IN LOCKUP", hospital = "HOSPITAL", dead = "DECEASED", turned = "TURNED" }
local function statusLabel(s)
  s = s or "ok"
  return (STATUS_LABEL[s] or s):upper()
end
local function available(c)
  local s = (c.status or "free"):lower()
  return s == "ok" or s == "free" or s == "on the take" or s == "wanted"
end
Sites.crewAvailable = available

local function skillsText(c)
  local parts = {}
  for _, s in ipairs(c.skills or {}) do
    if (s.v or 0) > 0 then parts[#parts + 1] = (s.k:gsub("^%l", string.upper)) .. s.v end
  end
  return table.concat(parts, " ")
end

-- BBS main ------------------------------------------------------------------------------

local BBS = Page.define({ style = "bbs", canvasH = 700, refreshOnResume = true })
Sites.BBS = BBS

function BBS:sources()
  return { crew = "/crew", ops = "/ops", events = { "/events", optional = true } }
end

function BBS:statusText() return "" end

function BBS:layout(L)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 2000)
  local y = header(L, "THE CLUBHOUSE BBS", "node 2 - 2400 baud")
  local crew = self.data.crew and self.data.crew.crew or {}
  local max = self.data.crew and self.data.crew.max or 6
  Text.draw("YOUR CREW (" .. #crew .. "/" .. max .. ")", 4, y, MONO, "white")
  Text.draw("STATUS", 392, y, MONO, "white", "right")
  y += 18
  for _, c in ipairs(crew) do
    local p = c.person
    gfx.setColor(gfx.kColorWhite)
    Faces.draw(p.face, 6, y + 2, 24)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(4, y, 28, 28)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(p.name, 40, y, MONO, "white")
    Text.draw("[" .. statusLabel(c.status) .. "]", 392, y, MONO, "white", "right")
    Text.draw(Text.ellipsize((c.role or "") .. ": " .. skillsText(c), MONO, 340), 40, y + 15, MONO, "white")
    L:link(38, y - 1, MONO:getTextWidth(p.name) + 4, 16, function() self:crewMenu(c) end,
      { id = "crew:" .. c.id, hint = p.name .. ": " .. (c.note or ""), style = "invert", onFocus = function() self.quote = c end })
    y += 34
  end
  if #crew == 0 then
    Text.draw("Nobody. Recruit some lowlifes.", 4, y, MONO, "white")
    y += 18
  end
  y += 4
  -- menu row
  local x = 4
  x += menuKey(L, x, y, "R", "ecruit", function() Sites.Recruit.open() end, "Hire new crew") + 10
  x += menuKey(L, x, y, "O", "perations", function() Sites.OpsPlanner.open({}) end, "Plan a job for an upcoming game") + 10
  x += menuKey(L, x, y, "S", "yndicate", function() Sites.Syndicate.open() end, "Your syndicate & allies") + 10
  x += menuKey(L, x, y, "M", "ail", function() Sites.Mail.open() end, "Your inbox") + 6
  L:live(x, y, 20, 16, function(_, lx, ly, f)
    Text.draw(">", lx, ly, MONO, "white")
    if (f // 10) % 2 == 0 then gfx.setColor(gfx.kColorWhite) gfx.fillRect(lx + 9, ly + 12, 7, 2) gfx.setColor(gfx.kColorBlack) end
  end)
  y += 18
  -- quote line (follows focus)
  L:live(4, y, 390, 16, function(_, lx, ly)
    local c = self.quote or crew[1]
    if c and c.note and c.note ~= "" then
      local first = c.person.name:gsub('"', ""):match("(%S+)") or ""
      Text.draw(Text.ellipsize(first .. ": " .. c.note, MONO, 388), lx, ly, MONO, "white")
    end
  end)
  y += 22
  -- pending decisions
  local ev = self.data.events and self.data.events.events or {}
  if #ev > 0 then
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(4, y, 388, 18)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(Text.ellipsize("!! " .. #ev .. " PENDING: " .. ev[1].title:upper(), MONO, 376), 8, y + 1, MONO, "white")
    L:link(4, y, 388, 18, function() Sites.EventCard.show(ev[1]) end, { id = "event", hint = "Decide now", style = "invert" })
    y += 24
  end
  -- op log
  gfx.setColor(gfx.kColorWhite)
  gfx.drawLine(4, y + 7, 392, y + 7)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(10, y, MONO:getTextWidth(" OPERATIONS LOG ") , 16)
  Text.draw(" OPERATIONS LOG ", 10, y, MONO, "white")
  y += 20
  local ops = self.data.ops and self.data.ops.ops or {}
  if #ops == 0 then
    Text.draw("No jobs yet. Clean record. Boring.", 4, y, MONO, "white")
    y += 18
  end
  for _, op in ipairs(ops) do
    local st = (op.status or "planned"):upper()
    local g = op.game or {}
    local where = g.away and (g.away.abbr .. "@" .. g.home.abbr .. " D" .. (g.day or "?")) or (op.storyline and "STORY" or "")
    local nw = Text.draw(Text.ellipsize(op.name or op.kind, MONO, 230), 4, y, MONO, "white")
    local ww = Text.draw(where, 300, y, MONO, "white", "right")
    if g.id then
      L:link(300 - ww - 1, y, ww + 2, 16, function() Nav.game(g.id) end, { id = "opgame:" .. op.id, hint = "The game page: " .. where, style = "invert" })
    end
    if op.status == "planned" then
      L:link(3, y, nw + 2, 16, function() self:callOff(op) end, { id = "op:" .. op.id, hint = "Call it off (everyone who paid is refunded)", style = "invert" })
    end
    local sw = MONO:getTextWidth("[" .. st .. "]")
    if op.status == "blown" then
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(392 - sw - 1, y, sw + 2, 16)
      Text.draw("[" .. st .. "]", 392, y, MONO, nil, "right")
      gfx.setColor(gfx.kColorBlack)
    else
      Text.draw("[" .. st .. "]", 392, y, MONO, "white", "right")
    end
    y += 16
    local crewNames = {}
    for _, p in ipairs(op.crew or {}) do crewNames[#crewNames + 1] = p.name end
    local detail = (op.storyline and ("story: " .. op.storyline.label .. " / ") or ("target " .. (op.target and op.target.name or "?") .. " / ")) .. "crew: " .. table.concat(crewNames, ", ")
    if op.nudge then detail = detail .. " / " .. op.nudge.kind .. (op.nudge.applied and (" x" .. op.nudge.strength) or " (didn't take)") end
    y += Text.block(detail, 20, y, 370, MONO, "white", 2)
    -- joint jobs: who chipped in
    if op.chipIn and op.chipIn.line then
      y += Text.block(op.chipIn.line, 20, y, 370, UI.fonts.body, "white", 2)
    end
    if op.result then
      y += Text.block("> " .. op.result, 20, y, 370, MONO, "white", 3)
    end
    y += 6
  end
  L:mark(y + 4)
end

--- Call off a planned job before it locks (DELETE /ops/:id): the orderer and any ally who chipped in get refunds.
function BBS:callOff(op)
  Dialog.show({ title = "CALL OFF " .. (op.name or op.kind):upper() .. "?", style = "bbs", icon = "?",
    body = "The crew goes home. Everyone who paid for it gets the money back.",
    buttons = { "Call it off", "Keep it" }, cancel = 2,
    onChoose = function(i)
      if i ~= 1 then return end
      local b = Busy.show("Phoning the crew")
      Api.delete("/ops/" .. op.id, function(err, d)
        b:done()
        if err then Sfx.error() Dialog.alert("Error", Api.errorText(err)) return end
        Game.absorb(d)
        Toast.show("Called off. Refunds sent.", "good")
        self:reload(true)
      end)
    end })
end

function BBS:crewMenu(c)
  local p = c.person
  local lines = {
    (c.role or "") .. " - " .. skillsText(c),
    "Loyalty " .. string.rep("*", c.loyalty or 0) .. string.rep(".", 5 - (c.loyalty or 0)) .. "   Status: " .. statusLabel(c.status),
    c.note or "",
  }
  Dialog.show({
    title = p.name, style = "bbs", face = p.face, body = table.concat(lines, "\n"),
    buttons = { "Fan page", "Dismiss", "Back" }, cancel = 3,
    onChoose = function(i)
      if i == 1 then
        Nav.person(p.id)
      elseif i == 2 then
        Dialog.show({ title = "Dismiss " .. p.name .. "?", style = "bbs", icon = "?", body = "They know things. They might talk.", buttons = { "Dismiss", "Keep" }, cancel = 2,
          onChoose = function(k)
            if k == 1 then
              Busy.post("/crew/" .. c.id .. "/dismiss", {}, "Paying them off", function()
                Toast.show(p.name .. " is off the crew.", "good")
                self:reload(true)
              end)
            end
          end })
      end
    end,
  })
end

-- Recruit board -----------------------------------------------------------------------------

local Recruit = Page.define({ style = "bbs", canvasH = 500 })
Sites.Recruit = Recruit

function Recruit:sources() return { c = "/crew/candidates", crew = "/crew" } end

function Recruit:layout(L)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 1200)
  local y = header(L, "RECRUIT", "the usual suspects")
  local cands = self.data.c and self.data.c.candidates or {}
  local crew = self.data.crew or {}
  local full = #(crew.crew or {}) >= (crew.max or 6)
  local refresh = self.data.c and self.data.c.refreshesAt
  if refresh then
    L:live(4, y, 390, 16, function(_, lx, ly)
      Text.draw("New faces in " .. Fmt.dur(refresh - Api.now()) .. (full and "  (CREW FULL)" or ""), lx, ly, MONO, "white")
    end)
    y += 20
  end
  for _, c in ipairs(cands) do
    local p = c.person
    Faces.draw(p.face, 6, y + 2, 48)
    gfx.setColor(gfx.kColorWhite)
    gfx.drawRect(4, y, 52, 64)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(p.name, 64, y, MONO, "white")
    local cost = c.ask or c.cost or 0
    Text.draw(Fmt.money(cost), 392, y, MONO, "white", "right")
    Text.draw(Text.ellipsize((c.role or "") .. ": " .. skillsText(c), MONO, 296), 64, y + 16, MONO, "white")
    Text.block(c.pitch or c.note or "", 64, y + 33, 326, UI.fonts.body, "white", 2)
    L:link(2, y - 2, 392, 68, function()
      if full then Dialog.show({ title = "CREW FULL", style = "bbs", icon = "!", body = "No room. Dismiss someone first.", buttons = { "OK" }, cancel = 1 }) return end
      Dialog.show({ title = "Hire " .. p.name .. "?", style = "bbs", face = p.face,
        body = (c.role or "") .. ". " .. (c.pitch or c.note or "") .. "\nFee: " .. Fmt.money(c.ask or c.cost or 0),
        buttons = { "Hire", "Pass" }, cancel = 2,
        onChoose = function(i)
          if i ~= 1 then return end
          Busy.post("/crew/recruit", { candidateId = c.id }, "Making the offer", function()
            Sfx.coin()
            Toast.show(p.name .. " joined your crew.", "good")
            App.pop()
          end)
        end })
    end, { id = "cand:" .. c.id, hint = "Hire " .. p.name .. " for " .. Fmt.money(c.ask or c.cost or 0), style = "ring" })
    y += 72
  end
  if #cands == 0 then Text.draw("Nobody's looking for work. Check back.", 4, y, MONO, "white") y += 18 end
  L:mark(y)
end

-- Operation planner ---------------------------------------------------------------------------

local Ops = Page.define({ style = "bbs", canvasH = 700 })
Sites.OpsPlanner = Ops

local RISK_HEAT <const> = { low = 1, mod = 2, high = 3, lol = 4 }

function Ops:init(args)
  self.gameId = args.gameId
  self.targetId = args.targetId
  self.kindIdx = 1
  self.crewSel = {}
  self.gearSel = {}
  self.storylineId = args.storylineId   -- storyline ops: the arc this job works on (nil = game job)
  self.wantStory = args.storylineId     -- deep link (Gossip Board, tip mail): start on a job that can reach it
  self.nudge = "expose"                 -- blackmail's choice: expose or soothe
  self.chipIn = false                   -- joint jobs: ask the allies on it to chip in their share
end

function Ops:sources()
  return { today = "/today", crew = "/crew", syn = { "/syndicate", optional = true } }
end

function Ops:scheduledGames()
  local out = {}
  for _, g in ipairs(self.data.today and self.data.today.games or {}) do
    if g.status == "scheduled" then out[#out + 1] = g end
  end
  return out
end

function Ops:game()
  for _, g in ipairs(self:scheduledGames()) do if g.id == self.gameId then return g end end
end

function Ops:fetchCatalog()
  self.catalog = nil
  self.catLoading = true
  -- without a game the catalog still lists storyline targets (storyline-only jobs need no game)
  Api.get("/ops/catalog" .. (self.gameId and ("?game=" .. self.gameId) or ""), function(err, d)
    self.catLoading = false
    self.catalog = d
    if d and d.targets then
      local ok = false
      for _, t in ipairs(d.targets) do if t.id == self.targetId then ok = true end end
      if not ok and d.targets[1] then self.targetId = d.targets[1].id end
    end
    if err then Toast.show(Api.errorText(err), "bad") end
    -- opened at a story: start on the first job that can work on it
    if d and self.wantStory and not self.storyPicked then
      self.storyPicked = true
      local found = false
      for i, k in ipairs(d.kinds or {}) do
        for _, t in ipairs(self:storyTargets(k)) do
          if t.storylineId == self.wantStory then found = true break end
        end
        if found then self.kindIdx = i self.storylineId = self.wantStory break end
      end
      if not found then Toast.show("No job can reach that story yet. Wait for it to leak.", "bad") end
    -- no game open: start on the first job that can work on a storyline
    elseif d and not self.gameId then
      for i, k in ipairs(d.kinds or {}) do if k.storyline then self.kindIdx = i break end end
    end
    self:fixStoryline()
    self.panelKey = nil
    self:render(true)
  end)
end

--- Storyline targets this job kind can work on (from the catalog).
function Ops:storyTargets(k)
  local out = {}
  if not (k and k.storyline) then return out end
  for _, t in ipairs(self.catalog and self.catalog.storylines or {}) do
    for _, o in ipairs(t.ops or {}) do
      if o.kind == k.kind then out[#out + 1] = t break end
    end
  end
  return out
end

function Ops:storyline()
  for _, t in ipairs(self:storyTargets(self:kind())) do if t.storylineId == self.storylineId then return t end end
end

--- Keep the chosen storyline valid for the chosen job (and pick one when the job needs it).
function Ops:fixStoryline()
  local k = self:kind()
  if self.storylineId and not self:storyline() then self.storylineId = nil end
  if k and k.storyline and not self.storylineId and (k.storyline.required or not self.gameId) then
    local ts = self:storyTargets(k)
    if ts[1] then self.storylineId = ts[1].storylineId end
  end
end

function Ops:pickStory()
  local k = self:kind()
  local ts = self:storyTargets(k)
  local items, sel = {}, 1
  if not (k.storyline and k.storyline.required) and self.gameId then
    items[1] = { label = "(none: just the game)", value = false }
  end
  for _, t in ipairs(ts) do
    local vis = t.visibility == "secret" and "you heard" or t.visibility
    items[#items + 1] = { label = t.label or t.storylineId, note = vis, value = t }
    if t.storylineId == self.storylineId then sel = #items end
  end
  if #items == 0 then
    Toast.show("No stories this job can work on. Wait for a rumour, or a tip.", "bad")
    return
  end
  Picker.open({ title = "WHICH STORY", style = "bbs", items = items, selected = sel, letterJump = false,
    onPick = function(it)
      self.storylineId = it.value and it.value.storylineId or nil
      self:render(true)
    end })
end

function Ops:kind()
  return self.catalog and self.catalog.kinds and self.catalog.kinds[self.kindIdx]
end

function Ops:crewPool()
  local pool = {}
  for _, c in ipairs(self.data.crew and self.data.crew.crew or {}) do pool[#pool + 1] = { c = c } end
  -- allies' crew: `allies` on /crew (CrewView + owner), or syndicate.allyCrew / members[].crew if the server sends them
  local seen = {}
  local function addAlly(c, owner)
    if c and c.id and not seen[c.id] then
      seen[c.id] = true
      pool[#pool + 1] = { c = c, ally = c.owner or owner or "ally" }
    end
  end
  for _, c in ipairs(self.data.crew and self.data.crew.allies or {}) do addAlly(c) end
  local syn = self.data.syn and self.data.syn.syndicate
  if syn and syn ~= json.null then
    for _, c in ipairs(syn.allyCrew or {}) do addAlly(c) end
    for _, m in ipairs(syn.members or {}) do
      if m.name ~= (Game.account and Game.account.name) then
        for _, c in ipairs(m.crew or {}) do addAlly(c, m.name) end
      end
    end
  end
  return pool
end

function Ops:selectedCrew()
  local out = {}
  for _, e in ipairs(self:crewPool()) do if self.crewSel[e.c.id] then out[#out + 1] = e end end
  return out
end

--- Allies whose crew are on the job (the people a chip-in would ask).
function Ops:alliesOnJob()
  local seen, out = {}, {}
  for _, e in ipairs(self:selectedCrew()) do
    if e.ally and not seen[e.ally] then seen[e.ally] = true out[#out + 1] = e.ally end
  end
  return out
end

function Ops:estimate()
  local k = self:kind()
  if not k then return 0, 0, 0 end
  local pct = k.successPct or 50
  local chosen = self:selectedCrew()
  -- rough client-side read of the crew: unfilled slots hurt, matching skills help
  local missing = (k.slots or 1) - #chosen
  pct -= missing * 15
  for _, e in ipairs(chosen) do
    for _, s in ipairs(e.c.skills or {}) do
      if (k.needs or ""):lower():find(s.k:lower(), 1, true) then pct += (s.v - 2) * 2 end
    end
  end
  local gearN = 0
  local cost = k.cost or 0
  for _, gr in ipairs(k.gear or {}) do
    if self.gearSel[gr.id] then gearN += 1 cost += gr.cost or 0 end
  end
  pct += gearN * 5
  pct = math.max(1, math.min(97, math.floor(pct)))
  local heat = k.heat or RISK_HEAT[k.risk] or 2
  return pct, cost, heat
end

function Ops:pickGame()
  local games = self:scheduledGames()
  if #games == 0 then return end
  local items, sel = {}, 1
  for i, g in ipairs(games) do
    items[i] = { label = g.away.abbr .. " @ " .. g.home.abbr .. "  Day " .. g.day, note = "in " .. Fmt.dur((g.firstPitchAt or 0) - Api.now()), value = g }
    if g.id == self.gameId then sel = i end
  end
  Picker.open({ title = "WHICH GAME", style = "bbs", items = items, selected = sel, letterJump = false,
    onPick = function(it)
      if it.value.id ~= self.gameId then
        self.gameId = it.value.id
        self.targetId = nil
        self:fetchCatalog()
      end
    end })
end

function Ops:pickTarget()
  local ts = self.catalog and self.catalog.targets or {}
  if #ts == 0 then return end
  local items, sel = {}, 1
  for i, t in ipairs(ts) do
    items[i] = { label = t.city .. " " .. t.name, value = t }
    if t.id == self.targetId then sel = i end
  end
  Picker.open({ title = "TARGET", style = "bbs", items = items, selected = sel, letterJump = false,
    onPick = function(it) self.targetId = it.value.id self:render(true) end })
end

function Ops:target()
  for _, t in ipairs(self.catalog and self.catalog.targets or {}) do if t.id == self.targetId then return t end end
end

function Ops:toggleCrew(e)
  local k = self:kind()
  local id = e.c.id
  if self.crewSel[id] then
    self.crewSel[id] = nil
    Sfx.back()
  else
    if not available(e.c) then
      Sfx.error()
      Toast.show(e.c.person.name .. " is " .. statusLabel(e.c.status):lower() .. ".", "bad")
      return
    end
    if k and #self:selectedCrew() >= (k.slots or 1) then
      Sfx.error()
      Toast.show("This job only has " .. (k.slots or 1) .. " slot" .. ((k.slots or 1) > 1 and "s" or "") .. ".", "bad")
      return
    end
    self.crewSel[id] = true
  end
  self:render(true)
end

-- The wizard -----------------------------------------------------------------------------------
-- 1 GAME (skipped when opened from a game: the hub, a bet ticket) -> 2 JOB (cost and success %
-- in the list, a side panel with the blurb, the odds, the best crew) -> 3 CREW & GO (best crew
-- already picked; gear, story, chip-in; A on GO places it and stamps "JOB ON").

local LIST_W <const> = 234     -- the list column; the side panel sits right of it (screen space)
local PANEL_X <const> = 238

function Ops:setStep(n)
  self.step = n
  self.focus = 0
  self.ring = nil
  self.panelKey = nil
  self.scroll:jump(0)
  self:render()
end

--- The best free crew for a job: highest total of the skills it needs, up to its slots.
function Ops:bestCrew(k)
  local need = {}
  for name, v in (k.needs or ""):gmatch("(%a+)(%d+)") do need[name:lower()] = tonumber(v) end
  local scored = {}
  for _, e in ipairs(self:crewPool()) do
    if available(e.c) then
      local sc = 0
      for _, sk in ipairs(e.c.skills or {}) do
        local n = need[(sk.k or ""):lower()]
        if n then sc += math.min(sk.v or 0, n + 1) end
      end
      scored[#scored + 1] = { e = e, sc = sc - (e.ally and 0.5 or 0) }
    end
  end
  table.sort(scored, function(a, b) return a.sc > b.sc end)
  local out = {}
  for i = 1, math.min(k.slots or 1, #scored) do out[i] = scored[i].e end
  return out
end

--- Picks job i and moves on to the crew step with the best crew already on it.
function Ops:chooseKind(i)
  local k = self.catalog and self.catalog.kinds and self.catalog.kinds[i]
  if not k then return end
  if k.blocked and self.gameId and not (k.storyline and k.storyline.required) then
    Sfx.error()
    Toast.show(k.blocked, "bad")
    return
  end
  self.kindIdx = i
  self.gearSel = {}
  self.crewSel = {}
  for _, e in ipairs(self:bestCrew(k)) do self.crewSel[e.c.id] = true end
  self:fixStoryline()
  self:setStep(3)
end

function Ops:cycleTarget(d)
  local ts = self.catalog and self.catalog.targets or {}
  if #ts < 2 then self:bump() return end
  local cur = 1
  for i, t in ipairs(ts) do if t.id == self.targetId then cur = i end end
  self.targetId = ts[(cur - 1 + d) % #ts + 1].id
  Sfx.focus()
  self.panelKey = nil
  self:render(true)
end

function Ops:moveFocus(dx, dy)
  -- job list: left/right switches the target club
  if self.step == 2 and dx ~= 0 and dy == 0 then return self:cycleTarget(dx) end
  return Page.moveFocus(self, dx, dy)
end

function Ops:goBack()
  if self.stampT then return end
  if self.step and self.step > (self.firstStep or 1) then
    Sfx.back()
    self:setStep(self.step - 1)
    return
  end
  Page.goBack(self)
end

function Ops:initialFocus()
  local want = self.step == 2 and ("kind:" .. ((self:kind() or {}).kind or "")) or (self.step == 3 and "go") or ("pick:" .. (self.gameId or ""))
  for i, l in ipairs(self.links) do if l.id == want then return i end end
  return 1
end

function Ops:statusText()
  if self.step == 1 then return "\u{25b2}\u{25bc} game   A: next (the job)   B: back" end
  if self.step == 2 then return "\u{25b2}\u{25bc} job   \u{25c0}\u{25b6} target   A: next (crew)   B: back" end
  return "A: toggle / GO   B: back to the jobs   hold B: home"
end

function Ops:go()
  if self.stampT then return end
  if not self:requireFresh() then return end
  local k = self:kind()
  local g = self:game()
  local t = self:target()
  local st = self:storyline()
  local storyOnly = k and k.storyline and (k.storyline.required or not g) and st
  if not k or (not storyOnly and not (g and t)) then
    Sfx.error()
    Toast.show(k and k.storyline and "Pick a story for this job." or "No game to work.", "bad")
    return
  end
  if k.blocked and not storyOnly then
    Sfx.error()
    Toast.show(k.blocked, "bad")
    return
  end
  local chosen = self:selectedCrew()
  if #chosen == 0 then
    Sfx.error()
    Toast.show("Assign at least one crew member.", "bad")
    return
  end
  local allies = self:alliesOnJob()
  local split = self.chipIn and #allies > 0
  local crewIds = {}
  for _, e in ipairs(chosen) do crewIds[#crewIds + 1] = e.c.id end
  local gear = {}
  for _, gr in ipairs(k.gear or {}) do if self.gearSel[gr.id] then gear[#gear + 1] = gr.id end end
  local body = {}
  local nudge = (k.storyline and k.storyline.nudge == "choice") and self.nudge or nil
  if storyOnly then
    body.gameId, body.targetTeamId = "", ""
  else
    body.gameId, body.targetTeamId = g.id, t.id
  end
  if st then body.storylineId = st.storylineId end
  if st and nudge then body.nudge = nudge end
  body.kind, body.crew, body.gear = k.kind, crewIds, gear
  if split then body.chipIn = true end
  -- no confirm dialog: the crew step is the ticket, and B always backs out
  Busy.post("/ops", body, "Briefing the crew", function()
    Sfx.stamp()
    Sfx.coin()
    self.stampT = 40
    Toast.show(split and "Job on. The hat is going around." or "Job on. Watch the news.", "good")
  end)
end

function Ops:tick()
  if self.stampT then
    self.stampT -= 1
    if self.stampT <= 0 then
      self.stampT = nil
      if App.top() == self then App.pop() end
    end
  end
end

function Ops:loaded()
  local games = self:scheduledGames()
  if not self:game() and games[1] and self.step ~= 1 then self.gameId = games[1].id end
  if not self:game() then self.gameId = nil end
  if not self.step then
    -- from a game (or a story) straight to the jobs; otherwise pick the game first
    self.firstStep = (self.args.gameId or self.args.storylineId or #games == 0) and 2 or 1
    if self.firstStep == 1 and not self.gameId and games[1] then self.gameId = games[1].id end
    self.step = self.firstStep
  end
  self:fetchCatalog()
end

local function header3(L, step, title, right)
  local y = header(L, "PLAN A JOB " .. step .. "/3", right)
  Text.draw(title, 4 + MONO:getTextWidth(" PLAN A JOB " .. step .. "/3 ") + 8, 3, MONO, "white")
  return y
end

function Ops:layout(L)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 2000)
  local step = self.step or 1
  if step == 1 then return self:layoutGames(L) end
  if not self.catalog then
    header3(L, step, step == 2 and "PICK THE JOB" or "CREW & GO", "")
    Text.draw(self.catLoading and "Loading the menu..." or "No catalog.", 4, 26, MONO, "white")
    L:mark(60)
    return
  end
  if step == 2 then return self:layoutKinds(L) end
  return self:layoutCrew(L)
end

function Ops:layoutGames(L)
  local y = header3(L, 1, "PICK THE GAME", "")
  local games = self:scheduledGames()
  for _, g in ipairs(games) do
    local you = g.myBet and ("  YOU " .. Fmt.money(g.myBet.amount) .. " " .. (g.myBet.side == "home" and g.home.abbr or g.away.abbr)) or ""
    Text.draw(g.away.abbr .. " @ " .. g.home.abbr .. "  Day " .. (g.day or "?") .. you, 8, y, MONO, "white")
    Text.draw(g.exhibition and "EXH" or (g.circuit == "enhanced" and "DESERT" or ""), 392, y, MONO, "white", "right")
    L:link(2, y, 392, 16, function()
      if g.id ~= self.gameId then self.gameId = g.id self.targetId = nil self:fetchCatalog() end
      self:setStep(2)
    end, { id = "pick:" .. g.id, style = "invert", hint = g.away.city .. " " .. g.away.name .. " at " .. g.home.city .. " " .. g.home.name .. " \u{2022} " .. Fmt.firstPitch(g) })
    y += 17
  end
  if #games == 0 then
    y += Text.block("No games open for business. Story jobs still run tonight.", 4, y, 388, UI.fonts.body, "white", 2) + 4
  end
  y += 4
  Text.draw("STORY JOBS (no game: letters, tips, blackmail)", 8, y, MONO, "white")
  L:link(2, y, 392, 16, function()
    self.gameId = nil
    self.targetId = nil
    self:fetchCatalog()
    self:setStep(2)
  end, { id = "pick:", style = "invert", hint = "Jobs that work on a storyline instead of a game" })
  y += 20
  L:mark(y)
end

function Ops:layoutKinds(L)
  local g = self:game()
  local t = self:target()
  local y = header3(L, 2, "PICK THE JOB", "")
  if g then
    -- the target: left/right anywhere in the list switches it
    local function arrows(n) return "TARGET \u{25c0} " .. n .. " \u{25b6}" end
    local tl = arrows(t and (t.city .. " " .. t.name) or "?")
    -- keep the right arrow: "Cold Spring Rustlers" fits, a longer club drops its city
    Text.draw(Text.fit(tl, LIST_W - 50, UI.fonts.bold, { short = t and arrows(t.name) or nil, fonts = {} }), 6, y, UI.fonts.bold, "white")
    Text.draw(g.away.abbr .. "@" .. g.home.abbr, LIST_W - 4, y, UI.fonts.body, "white", "right")
    y += 15
  else
    Text.draw("STORY JOBS: no game, they run tonight", 6, y, UI.fonts.bold, "white")
    y += 15
  end
  for i, k in ipairs(self.catalog.kinds or {}) do
    local banned = k.blocked and g and not (k.storyline and k.storyline.required)
    local storyless = not g and not k.storyline
    local sel = i == self.kindIdx
    local cost = Fmt.money(k.cost)
    Text.drawFit(k.name, 6, y + 1, 186 - MONO:getTextWidth(cost) - 12, UI.fonts.bold, "white")
    Text.draw(cost, 186, y, MONO, "white", "right")
    local pct = banned and "BANNED" or (storyless and "--" or ((k.successPct or 0) .. "%"))
    Text.draw(pct, LIST_W - 4, y, MONO, "white", "right")
    if banned or storyless then
      Draw.fade(2, y, LIST_W - 2, 16, 0.5)
      gfx.setColor(gfx.kColorBlack)
    end
    L:link(2, y, LIST_W - 2, 16, function() self:chooseKind(i) end,
      { id = "kind:" .. k.kind, style = "invert", hint = banned and k.blocked or (storyless and "This job needs a game." or k.blurb),
        onFocus = function() if self.kindIdx ~= i then self.kindIdx = i self.panelKey = nil end end })
    y += 16
  end
  L:mark(y + 4)
end

function Ops:layoutCrew(L)
  local k = self:kind()
  if not k then self.step = 2 return self:layoutKinds(L) end
  local g = self:game()
  local y = header3(L, 3, "CREW & GO", Text.ellipsize(k.name, MONO, 150))
  -- GO first: the best crew is already on it, so A sends them
  local pct, cost = self:estimate()
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(4, y, LIST_W - 8, 20)
  Text.draw("[G]O  " .. Fmt.money(cost) .. "  ~" .. pct .. "%", LIST_W // 2, y + 2, MONO, nil, "center")
  gfx.setColor(gfx.kColorBlack)
  L:link(4, y, LIST_W - 8, 20, function() self:go() end, { id = "go", style = "ring", hint = "Send the crew (" .. Fmt.money(cost) .. ")" .. (g and ". Orders lock at first pitch." or ". It happens tonight.") })
  y += 25
  local slots = k.slots or 1
  Text.draw("CREW " .. #self:selectedCrew() .. "/" .. slots .. "  (best picked)", 4, y, MONO, "white")
  y += 17
  for _, e in ipairs(self:crewPool()) do
    local c = e.c
    local on = self.crewSel[c.id]
    gfx.setColor(gfx.kColorWhite)
    if on then gfx.fillRect(6, y + 4, 9, 9) else gfx.drawRect(6, y + 4, 9, 9) end
    gfx.setColor(gfx.kColorBlack)
    local tag = e.ally and ("(" .. e.ally .. ")") or (not available(c) and statusLabel(c.status):lower() .. "!" or skillsText(c))
    local nw = Text.draw(Text.fit(c.person.name, 120, MONO, { short = Text.initialName(c.person.name), fonts = {} }), 20, y, MONO, "white")
    Text.draw(Text.ellipsize(tag, UI.fonts.body, LIST_W - 26 - nw), 26 + nw, y + 2, UI.fonts.body, "white")
    L:link(4, y, LIST_W - 4, 16, function() self:toggleCrew(e) self.panelKey = nil end,
      { id = "crew:" .. c.id, hint = (e.ally and ("Borrowed from " .. e.ally .. ": ") or "") .. c.person.name .. " \u{2022} " .. (c.role or "") .. " \u{2022} " .. skillsText(c), style = "invert" })
    y += 16
  end
  if #(k.gear or {}) > 0 then
    y += 3
    Text.draw("GEAR", 4, y, MONO, "white")
    y += 16
    for _, gr in ipairs(k.gear or {}) do
      local on = self.gearSel[gr.id]
      gfx.setColor(gfx.kColorWhite)
      if on then gfx.fillRect(6, y + 4, 9, 9) else gfx.drawRect(6, y + 4, 9, 9) end
      gfx.setColor(gfx.kColorBlack)
      Text.draw(Text.ellipsize(gr.name, MONO, 150), 20, y, MONO, "white")
      Text.draw("+" .. Fmt.money(gr.cost or 0), LIST_W - 4, y, MONO, "white", "right")
      L:link(4, y, LIST_W - 4, 16, function()
        self.gearSel[gr.id] = not self.gearSel[gr.id] or nil
        self.panelKey = nil
        self:render(true)
      end, { id = "gear:" .. gr.id, hint = gr.name .. " (+" .. Fmt.money(gr.cost or 0) .. ", better odds)", style = "invert" })
      y += 16
    end
  end
  -- storyline target (love letters, tips, blackmail, smoothing it over)
  if k.storyline then
    y += 3
    local st = self:storyline()
    local req = k.storyline.required or not g
    local lbl = st and (st.label .. (st.visibility == "secret" and " [heard]" or "")) or (req and "pick one" or "none")
    local w = Text.draw(Text.ellipsize("STORY " .. lbl .. " v", MONO, LIST_W - 6), 4, y, MONO, "white")
    L:link(3, y, w + 2, 16, function() self:pickStory() end, { id = "story", hint = req and "This job works on a storyline: pick which one" or "Aim it at a storyline too (optional)", style = "invert" })
    y += 17
    if st and k.storyline.nudge == "choice" then
      local x3 = 4
      for _, n in ipairs({ "expose", "soothe" }) do
        local on = self.nudge == n
        local nw = Text.draw((on and "(*) " or "( ) ") .. n, x3, y, MONO, "white")
        L:link(x3 - 1, y, nw + 2, 16, function() self.nudge = n self:render(true) end,
          { id = "nudge:" .. n, hint = n == "expose" and "Leak it: the story gets out" or "Hush it: the story calms down", style = "invert" })
        x3 += nw + 14
      end
      y += 17
    end
  end
  -- joint job: ask the allies on it to chip in (opt in)
  local allies = self:alliesOnJob()
  if #allies > 0 then
    local cw = Text.draw((self.chipIn and "[*] " or "[ ] ") .. "ASK FOR A CHIP-IN", 4, y, MONO, "white")
    L:link(3, y, cw + 2, 16, function() self.chipIn = not self.chipIn self:render(true) end,
      { id = "chipin", hint = "Split the job cost with " .. table.concat(allies, ", ") .. " (they can say no)", style = "invert" })
    y += 18
  end
  L:mark(y + 4)
end

--- The side panel (screen space, so it stays put while the list scrolls): the focused job
--- (step 2) or the job being staffed (step 3). Painted into an image only when it changes.
function Ops:panelImage()
  local k = self:kind()
  if not k then return nil end
  local pct, cost, heat = self:estimate()
  if self.step == 2 then pct, cost = k.successPct or 0, k.cost or 0 end
  local keyStr = self.step .. ":" .. self.kindIdx .. ":" .. tostring(self.targetId) .. ":" .. pct .. ":" .. cost .. ":" .. #self:selectedCrew()
  if self.panelKey == keyStr and self.panelImg then return self.panelImg end
  self.panelKey = keyStr
  local w, h = 400 - PANEL_X, 226 - Status.H
  local img = self.panelImg or gfx.image.new(w, h, gfx.kColorBlack)
  self.panelImg = img
  img:clear(gfx.kColorBlack)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorWhite)
  gfx.drawLine(0, 0, 0, h)
  gfx.fillRect(1, 0, w - 1, 16)
  Text.draw(Text.ellipsize(k.name:upper(), UI.fonts.bold, w - 8), 5, 1, UI.fonts.bold)
  local y = 19
  y += Text.block(k.blurb or "", 5, y, w - 9, UI.fonts.body, "white", 4) + 3
  Text.draw("SUCCESS", 5, y, UI.fonts.bold, "white")
  Text.draw(pct .. "%", w - 4, y, UI.fonts.bold, "white", "right")
  y += 14
  gfx.setColor(gfx.kColorWhite)
  gfx.drawRect(5, y, w - 10, 9)
  gfx.fillRect(7, y + 2, math.floor((w - 14) * pct / 100), 5)
  y += 14
  local function kv(a, b)
    Text.draw(a, 5, y, UI.fonts.body, "white")
    Text.draw(b, w - 4, y, UI.fonts.bold, "white", "right")
    y += 13
  end
  kv("COST", Fmt.money(cost))
  kv("RISK", ((k.risk or "?"):gsub("^%l", string.upper)))
  kv("HEAT", "+" .. (heat or k.heat or 1))
  local best = self.step == 2 and self:bestCrew(k) or self:selectedCrew()
  local names = {}
  for _, e in ipairs(best) do names[#names + 1] = (e.c.person.name:match("^(%S+)") or e.c.person.name) end
  kv("CREW", #names > 0 and Text.ellipsize(table.concat(names, ", ") .. (self.step == 2 and " (best)" or ""), UI.fonts.bold, w - 46) or "nobody free")
  y += 2
  for _, n in ipairs(k.notes or {}) do
    if y > h - 14 then break end
    y += Text.block("! " .. n, 5, y, w - 9, UI.fonts.body, "white", 2)
  end
  if k.blocked and self:game() then
    Text.block("BANNED: " .. k.blocked, 5, math.max(y, h - 42), w - 9, UI.fonts.body, "white", 3)
  end
  gfx.popContext()
  return img
end

local jobOnStamp = nil

function Ops:overlay()
  if (self.step or 1) >= 2 and self.catalog and not self.loading then
    local img = self:panelImage()
    if img then img:draw(PANEL_X, Status.H) end
  end
  if self.stampT then
    if not jobOnStamp then
      local f = UI.fonts.big
      local tw = f:getTextWidth("JOB ON!")
      local s = gfx.image.new(tw + 24, 40, gfx.kColorClear)
      gfx.pushContext(s)
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRect(2, 2, tw + 20, 36)
      gfx.setColor(gfx.kColorBlack)
      gfx.setLineWidth(3)
      gfx.drawRect(3, 3, tw + 18, 34)
      gfx.setLineWidth(1)
      Text.draw("JOB ON!", (tw + 24) // 2, 8, f, nil, "center")
      gfx.popContext()
      jobOnStamp = s:rotatedImage(-8)
    end
    local sw, sh = jobOnStamp:getSize()
    local grow = math.max(0, self.stampT - 34)
    jobOnStamp:draw(120 - sw // 2 - grow, 110 - sh // 2 - grow)
  end
end
