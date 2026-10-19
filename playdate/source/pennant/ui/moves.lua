-- Roster moves: the farm (call-ups / demotions) and simple trades (pick a club, pick up to three
-- players a side; the other club weighs ability, upside and age and says yes or no).

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

-- Farm -----------------------------------------------------------------------------------------

local Farm = PUI.define({ title = "Moves", hint = "A: call up / send down / card" })
PennantUI.Farm = Farm

function Farm:resume(r) Page.resume(self, r) self:render(true) end

function Farm:act(p)
  local L = Pennant.L
  local T = L.teams[L.user]
  local items = {}
  if p.lvl == "F" then
    items[#items + 1] = { label = "Call up", action = function()
      local ok, err = PRoster.callUp(L, T, p.id)
      if ok then PRoster.validate(L, T) PL.news(L, "CALLED UP: " .. PM.name(p) .. " (" .. p.pos .. ")", true) PennantUI.CallUp.open({ p = p })
      else Toast.show(err, "bad") end
      self:render(true)
    end }
  else
    items[#items + 1] = { label = "Send down", action = function()
      local ok, err = PRoster.demote(L, T, p.id)
      if ok then PRoster.validate(L, T) Toast.show(PM.short(p) .. " optioned to the farm.", nil) PL.news(L, "SENT DOWN: " .. PM.name(p), true)
      else Toast.show(err, "bad") end
      self:render(true)
    end }
  end
  items[#items + 1] = { label = "Player card", action = function() PennantUI.Card.open({ list = { p }, i = 1 }) end }
  local l = self.links[self.focus]
  Menu.open({ x = 230, y = math.min(180, (l and (l.y - self.scroll:y() + PUI.TOP + 14)) or 100), items = items })
end

function Farm:init(args) self.tab = args and args.tab or "farm" end

function Farm:layout(Lb)
  local L = Pennant.L
  local T = L.teams[L.user]
  local c = PennantClubs.byAbbr[L.user]
  local act = PRoster.activeCount(L, T)
  -- Moves: the farm and trades on one page
  local y = PUI.tabs(Lb, {
    { "farm", "Farm", function() self.tab = "farm" self:render() end, "Call-ups and demotions" },
    { "trades", "Trades", function() self.tab = "trades" self:render() end, "Call another club" },
  }, self.tab, 2)
  if self.tab == "trades" then
    PennantUI.tradeClubs(Lb, y)
    return
  end
  Text.draw("Big club: " .. act .. "/26 active" .. (act > 26 and "  (too many: send someone down)" or (act < 26 and "  (room to call up " .. (26 - act) .. ")" or "")), 4, y, UI.fonts.bold)
  y = y + 18
  y = PUI.head(Lb, c.farm[1] .. " " .. c.farm[2] .. " (farm)", 4, y, 388)
  PUI.rowHeader(4, y, "AGE POT")
  y = y + 16
  local farm = {}
  for _, id in ipairs(T.farm) do farm[#farm + 1] = L.players[id] end
  table.sort(farm, function(a, b) return PM.ovr(a) > PM.ovr(b) end)
  for _, p in ipairs(farm) do
    local ready = PRoster.ready(L, T, p)
    PUI.playerRow(Lb, p, 4, y, 388, function() self:act(p) end, { extra = (ready and "READY " or "") .. p.age .. "  " .. string.rep("\u{2605}", PM.potStars(p)), hint = PM.name(p) .. (ready and ": READY, better than your weakest. A to call him up" or ": A to call him up") })
    y = y + 17
  end
  y = PUI.head(Lb, "Big club", 4, y + 6, 388)
  local ml = {}
  for _, id in ipairs(T.ml) do ml[#ml + 1] = L.players[id] end
  table.sort(ml, function(a, b) return PM.ovr(a) < PM.ovr(b) end)
  for _, p in ipairs(ml) do
    PUI.playerRow(Lb, p, 4, y, 388, function() self:act(p) end, { extra = p.age .. (p.inj and ("  " .. p.inj.k) or ""), hint = PM.name(p) .. ": A to send him down" })
    y = y + 17
  end
  Lb:mark(y + 4)
end

function Farm:initialFocus() return 1 end

-- Trades ---------------------------------------------------------------------------------------

local Trades = PUI.define({ title = "Trades", hint = "A: pick a club" })
PennantUI.Trades = Trades

function Trades:resume(r) Page.resume(self, r) self:render(true) end

function Trades:layout(Lb) PennantUI.tradeClubs(Lb, 0) end

function PennantUI.tradeClubs(Lb, y0)
  local L = Pennant.L
  if not PL.tradeOpen(L) then
    Text.draw("The trade deadline has passed.", 6, y0 + 2, UI.fonts.bold)
    Text.draw("The phones open again in the offseason.", 6, y0 + 18, UI.fonts.body)
    Lb:mark(y0 + 34)
    return
  end
  local dl = PL.deadline(L) - L.day
  Text.draw(L.phase == "season" and ("Up to three a side. Deadline: " .. PL.date(L, PL.deadline(L)) .. (dl <= 7 and (" (" .. dl .. " days)") or "")) or "Up to three players a side. They'll tell you if it's close.", 6, y0 + 2, UI.fonts.body)
  local i = 0
  for _, c in ipairs(PennantClubs) do
    if c.abbr ~= L.user then
      local col, row = i % 2, i // 2
      local x, y = 6 + col * 194, y0 + 18 + row * 40
      local T = L.teams[c.abbr]
      gfx.drawRect(x, y, 188, 36)
      PUI.logo(c.abbr, x + 3, y + 2, 32)
      Text.draw(c.city .. " " .. c.name, x + 40, y + 3, UI.fonts.bold)
      Text.draw(T.w .. "-" .. T.l .. ", " .. PUI.ord(PL.rank(L, c.abbr)), x + 40, y + 18, UI.fonts.body)
      Lb:link(x, y, 188, 36, function() PennantUI.TradeTable.open({ other = c.abbr }) end, { id = "c" .. c.abbr, style = "ring", hint = "Talk to " .. c.name })
      i = i + 1
    end
  end
  Lb:mark(y0 + 16 + 4 * 40)
end

local TT = PUI.define({ title = function(self) return "Trade talk \u{2022} " .. PennantClubs.byAbbr[self.other].city end,
  hint = "A: add / remove  left/right on the logos: another club" })
PennantUI.TradeTable = TT

local FILTERS <const> = { "ALL", "C", "IF", "OF", "SP", "RP" }
local IF <const> = { ["1B"] = true, ["2B"] = true, ["3B"] = true, SS = true }
local OF <const> = { LF = true, CF = true, RF = true }
local function passes(p, f)
  if f == "ALL" then return true end
  if f == "C" then return p.pos == "C" end
  if f == "IF" then return IF[p.pos] == true end
  if f == "OF" then return OF[p.pos] == true end
  if f == "SP" then return p.pos == "P" and p.role == "SP" end
  return p.pos == "P" and p.role ~= "SP"
end

function TT:init(args)
  self.other = args.other
  self.give, self.get = {}, {}
  self.filter = 1
end

local function has(list, id) for i, x in ipairs(list) do if x == id then return i end end end

--- Other clubs, in league order.
local function clubs(L)
  local out = {}
  for _, c in ipairs(PennantClubs) do if c.abbr ~= L.user then out[#out + 1] = c.abbr end end
  return out
end

function TT:toggle(list, id, row)
  local i = has(list, id)
  if i then table.remove(list, i) Sfx.back()
  elseif #list < 3 then list[#list + 1] = id Sfx.select()
  else Toast.show("Three players a side, tops.", "bad") return end
  -- just that row and the call panel (a full render of 80 rows is slow on the device)
  if row then
    PUI.repaint(self, row.x - 1, row.y - 1, row.w + 2, 14, function() self:paintRow(row) end)
    row.link.style = has(list, id) and "ring" or "invert"
    self:repaintHeader()
  else
    self:render(true)
  end
end

function TT:paintRow(row)
  local p, list, x, y, w = row.p, row.list, row.x, row.y, row.w
  local on = has(list, p.id)
  if on then gfx.fillRect(x - 1, y - 1, w + 2, 14) end
  local col = on and "white" or nil
  Text.draw(p.pos == "P" and (p.role or "P") or p.pos, x + 2, y - 1, UI.fonts.bold, col)
  Text.draw(Text.ellipsize(PM.short(p) .. (p.lvl == "F" and " f" or ""), UI.fonts.body, 96), x + 26, y - 1, UI.fonts.body, col)
  Text.draw(tostring(PM.ovr(p)), x + 146, y - 1, UI.fonts.bold, col, "right")
  Text.draw(tostring(p.age), x + 168, y - 1, UI.fonts.body, col, "right")
  if p.inj then Text.draw("+", x + w - 2, y - 1, UI.fonts.bold, col, "right") end
end

function TT:column(Lb, T, list, x, y, w)
  local L = Pennant.L
  local f = FILTERS[self.filter]
  local ps = {}
  for _, id in ipairs(T.ml) do local p = L.players[id] if passes(p, f) or has(list, id) then ps[#ps + 1] = p end end
  for _, id in ipairs(T.farm) do local p = L.players[id] if passes(p, f) or has(list, id) then ps[#ps + 1] = p end end
  table.sort(ps, function(a, b) return PRoster.value(a) > PRoster.value(b) end)
  for _, p in ipairs(ps) do
    local row = { p = p, list = list, x = x, y = y, w = w }
    PUI.lazy(Lb, x - 1, y - 1, w + 2, 14, function() self:paintRow(row) end)
    row.link = Lb:link(x - 1, y - 1, w + 2, 14, function() self:toggle(list, p.id, row) end,
      { id = (list == self.give and "g" or "t") .. p.id, style = has(list, p.id) and "ring" or "invert",
        hint = PM.name(p) .. ", " .. p.age .. (p.lvl == "F" and " (farm)" or "") .. ". OVR " .. PM.ovr(p) .. ", potential " .. (p.pot or "?") .. (p.inj and (", hurt: " .. p.inj.k) or "") })
    y = y + 13
  end
  return y
end

--- The needle gauge: 0 (they hung up) .. 1 (DEAL) .. 1.25.
local function gauge(cx, cy, r, v)
  gfx.setLineWidth(2)
  gfx.drawArc(cx, cy, r, 270, 90)
  gfx.setLineWidth(1)
  -- the DEAL zone
  gfx.setPattern(UI.pat.gray)
  for a = 62, 88, 2 do
    local rad = math.rad(a)
    gfx.drawLine(cx + math.sin(rad) * (r - 6), cy - math.cos(rad) * (r - 6), cx + math.sin(rad) * r, cy - math.cos(rad) * r)
  end
  gfx.setColor(gfx.kColorBlack)
  for _, t in ipairs({ -90, -45, 0, 45, 60, 90 }) do
    local rad = math.rad(t)
    gfx.drawLine(cx + math.sin(rad) * (r - 4), cy - math.cos(rad) * (r - 4), cx + math.sin(rad) * r, cy - math.cos(rad) * r)
  end
  local ang = math.rad(-90 + math.max(0, math.min(1.25, v)) / 1.25 * 180)
  gfx.setLineWidth(2)
  gfx.drawLine(cx, cy, cx + math.sin(ang) * (r - 3), cy - math.cos(ang) * (r - 3))
  gfx.setLineWidth(1)
  gfx.fillCircleAtPoint(cx, cy, 3)
end

local MOOD_ART <const> = { "phone_candlestick", "phone_wall", "office_phone", "desk_phone", "switchboard", "phone_call" }

--- The call panel: the club strip, the GM's line (live), the needle, MAKE THE CALL.
function TT:paintHeader()
  local L = Pennant.L
  local mine, theirs = L.teams[L.user], L.teams[self.other]
  local ready = #self.give > 0 and #self.get > 0
  local ok, ratio, note = PRoster.evaluate(L, mine, theirs, self.give, self.get)
  -- the club strip
  local x = 4
  for _, ab in ipairs(clubs(L)) do
    PUI.logo(ab, x, 1, 16)
    if ab == self.other then gfx.setLineWidth(2) gfx.drawRect(x - 2, -1, 20, 20) gfx.setLineWidth(1) end
    x = x + 22
  end
  Text.draw("\u{25c0}\u{25b6} club", x + 2, 2, UI.fonts.body)
  -- the GM
  if not self.art then self.art = gfx.image.new("images/pennant/" .. MOOD_ART[(#self.other + self.other:byte(1)) % #MOOD_ART + 1] .. "-48") end
  if self.art then self.art:draw(4, 22) else gfx.drawRect(4, 22, 48, 48) end
  gfx.drawRect(56, 22, 222, 48)
  Text.draw(self.other .. " GM, on the line:", 60, 23, UI.fonts.bold)
  local line = ready and ("\"" .. note .. "\"") or "\"Who've you got for me?\""
  Text.block(line, 60, 37, 214, UI.fonts.body, nil, 2)
  -- the needle
  gauge(334, 68, 34, ready and ratio or 0)
  Text.draw("NO", 298, 56, UI.fonts.body, nil, "right")
  Text.draw("DEAL", 370, 56, UI.fonts.bold)
  local word = not ready and "" or (ok and "DEAL" or (ratio >= 0.85 and "CLOSE" or (ratio >= 0.6 and "SHORT" or "HUNG UP")))
  Text.draw(word, 334, 19, UI.fonts.bold, nil, "center")
  -- the call button
  Draw.button(292, 72, 100, 16, "MAKE THE CALL", (not ready) and "disabled" or nil)
  return ready and ("They say: " .. note) or "Pick players on both sides first"
end

function TT:repaintHeader()
  local hint
  PUI.repaint(self, 0, 0, 395, 90, function() hint = self:paintHeader() end)
  if self.offerLink then self.offerLink.hint = hint end
end

function TT:setClub(d)
  local L = Pennant.L
  local list = clubs(L)
  local i = 1
  for k, ab in ipairs(list) do if ab == self.other then i = k end end
  self.other = list[(i - 1 + d) % #list + 1]
  self.get = {}
  self.art = nil
  Sfx.tick()
  self:render(true)
end

function TT:layout(Lb)
  local L = Pennant.L
  local mine, theirs = L.teams[L.user], L.teams[self.other]
  local hint = self:paintHeader()
  Lb:link(2, 0, 7 * 22, 19, function() self:setClub(1) end, PUI.opts("clubs", "Left/right: dial another club", function(d) self:setClub(d) end, "ring"))
  self.offerLink = Lb:link(292, 72, 100, 16, function() self:offer() end, { id = "offer", style = "ring", hint = hint })
  -- the column heads and the position filter
  local y = 90
  Text.draw("YOU GIVE", 4, y, UI.fonts.head)
  Text.draw("YOU GET", 110, y, UI.fonts.head)
  local fx = 180
  for i, f in ipairs(FILTERS) do
    local w = UI.fonts.bold:getTextWidth(f) + 6
    if i == self.filter then gfx.fillRect(fx, y + 1, w, 13) Text.draw(f, fx + 3, y + 1, UI.fonts.bold, "white")
    else gfx.drawRect(fx, y + 1, w, 13) Text.draw(f, fx + 3, y + 1, UI.fonts.bold) end
    fx = fx + w + 2
  end
  Lb:link(178, y, fx - 178, 15, function() self.filter = self.filter % #FILTERS + 1 self:render(true) end,
    PUI.opts("filter", "Left/right: show only a position (both sides)", function(d) self.filter = (self.filter - 1 + d) % #FILTERS + 1 self:render(true) end, "ring"))
  y = y + 18
  gfx.drawLine(4, y - 2, 392, y - 2)
  local y1 = self:column(Lb, mine, self.give, 4, y, 188)
  local y2 = self:column(Lb, theirs, self.get, 202, y, 188)
  gfx.drawLine(197, y - 2, 197, math.max(y1, y2))
  Lb:mark(math.max(y1, y2) + 16)
end

--- The offer as one line, for the strip along the bottom.
function TT:summary()
  local L = Pennant.L
  if #self.give == 0 and #self.get == 0 then return nil end
  local function names(list) local t = {} for _, id in ipairs(list) do t[#t + 1] = L.players[id].ln end return table.concat(t, " + ") end
  return (#self.give > 0 and names(self.give) or "?") .. " for " .. (#self.get > 0 and names(self.get) or "?")
end

function TT:after()
  local s = self:summary()
  if not s then return end
  local y = PUI.BOT - 15
  gfx.fillRect(0, y, 394, 15)
  Text.draw(Text.ellipsize(s, UI.fonts.bold, 380), 4, y + 1, UI.fonts.bold, "white")
end

function TT:offer()
  local L = Pennant.L
  if #self.give == 0 or #self.get == 0 then Toast.show("Pick players on both sides.", "bad") return end
  if not PL.tradeOpen(L) then Toast.show("The trade deadline has passed.", "bad") return end
  local mine, theirs = L.teams[L.user], L.teams[self.other]
  local ok, ratio, note = PRoster.evaluate(L, mine, theirs, self.give, self.get)
  if not ok then
    Sfx.error()
    Toast.show(PUI.nick(self.other) .. ": \"" .. note .. "\"" .. (ratio > 0.85 and " Add a prospect or take less back." or ""), "bad")
    return
  end
  local function names(list) local t = {} for _, id in ipairs(list) do t[#t + 1] = PM.name(L.players[id]) end return table.concat(t, ", ") end
  Dialog.confirm("Deal!", "You send " .. names(self.give) .. " to " .. PUI.teamName(self.other) .. " for " .. names(self.get) .. ". Shake on it?", "Shake", "Wait", function(yes)
    if not yes then return end
    local txt = "TRADE: " .. PUI.nick(L.user) .. " send " .. names(self.give) .. " to " .. PUI.nick(self.other) .. " for " .. names(self.get)
    local short = "TRADE. " .. L.user .. " SEND " .. names(self.give):upper() .. " TO " .. self.other .. " FOR " .. names(self.get):upper() .. ". STOP."
    local got = {}
    for _, id in ipairs(self.get) do got[#got + 1] = L.players[id] end
    PRoster.trade(L, mine, theirs, self.give, self.get)
    PL.news(L, txt, true)
    Sfx.coin()
    self.give, self.get = {}, {}
    self:render(true)
    local crunch = PRoster.activeCount(L, mine) > 26
    PennantUI.Telegram.open({ text = short,
      note = (#got > 0 and (got[1].ln .. " reports tomorrow. Moving teams sours a man's mood a notch.") or "") .. (crunch and "  You're over 26 active: send someone down." or "") })
  end)
end

function TT:initialFocus() for i, l in ipairs(self.links) do if l.id and l.id:sub(1, 1) == "t" and l.id ~= "tab" then return i end end return 1 end

-- Telegram card (a done deal) ------------------------------------------------------------------------

local Telegram = { opaque = true }
Telegram.__index = Telegram
PennantUI.Telegram = Telegram

function Telegram.open(args)
  local s = setmetatable({}, Telegram)
  App.push(s, args)
  return s
end

function Telegram:enter(args)
  self.t = 0
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  local art = gfx.image.new("images/pennant/telegram")
  if art then art:draw(0, 0) end
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 160, 400, 80)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(0, 160, 399, 160)
  Text.block(args.text, 8, 164, 384, UI.fonts.bold, nil, 3)
  if args.note and args.note ~= "" then Text.block(args.note, 8, 206, 360, UI.fonts.body, nil, 2) end
  Text.draw("A \u{25b6}", 392, 222, UI.fonts.bold, nil, "right")
  gfx.popContext()
  self.img = img
  Sfx.stinger("new_mail")
end

function Telegram:update()
  self.t = self.t + 1
  self.img:draw(0, 0)
end

function Telegram:AButtonDown()
  if self.t < 6 then return end
  Sfx.select()
  App.pop()
end
Telegram.BButtonDown = Telegram.AButtonDown

-- Trainer's Room (P1-1) ---------------------------------------------------------------------------
-- A user player got hurt: who he is, how long, what he misses, and three fixes with the best one
-- picked. A = do it, B = later (the lineup auto-fills; the assistant GM steps in after two days).

local Trainer = { opaque = true }
Trainer.__index = Trainer
PennantUI.Trainer = Trainer

local LINES <const> = {
  "He rounded second like a man stepping off a moving bus.",
  "I've seen worse. Not on a ballplayer, but I've seen worse.",
  "Ice, rest, and nobody tells him about the standings.",
  "He says it only hurts when he plays baseball.",
  "We wrapped it. Then we wrapped the wrap.",
  "He'll be fine. The trainer's room coffee, I'm less sure about.",
}

function Trainer.open(args)
  local s = setmetatable({}, Trainer)
  App.push(s, args)
  return s
end

--- The opponents of the series he misses ("the CSR and ELC series").
local function missedSeries(L, p)
  local seen, list = {}, {}
  for d = L.day, math.min(#L.sched, L.day + p.inj.d - 1) do
    local g = PL.gameFor(L, L.user, d)
    if g then
      local o = g.h == L.user and g.a or g.h
      if not seen[o] and #list < 3 then seen[o] = true list[#list + 1] = o end
    end
  end
  if #list == 0 then return nil end
  if #list == 1 then return "misses the " .. list[1] .. " series" end
  return "misses the " .. table.concat(list, ", ", 1, #list - 1) .. " and " .. list[#list] .. " series"
end

function Trainer:enter(args)
  local L = Pennant.L
  local T = L.teams[L.user]
  local p = L.players[args.id]
  self.p, self.onDone = p, args.onDone
  self.sel = 1
  -- the fixes
  local fixes = {}
  local room = PRoster.activeCount(L, T) < PRoster.ML_MAX
  local rid = PRoster.bestReplacement(L, T, p)
  local r = rid and L.players[rid]
  local farmName = PennantClubs.byAbbr[L.user].farm[2]
  if r and room then
    local ready = PRoster.ready(L, T, r)
    local line = r.pos == "P" and string.format("%.2f ERA", PM.era(r.st.p)) or (PM.rate3(PM.avg(r.st.b)) .. " AVG")
    fixes[#fixes + 1] = { score = ready and 3 or 1,
      label = "Call up " .. r.ln .. " (" .. (r.pos == "P" and (r.role or "P") or r.pos) .. ", " .. farmName .. ")" .. (ready and "  \u{2605} READY" or ""),
      detail = "OVR " .. PM.ovr(r) .. ", " .. line .. " on the farm. " .. PRoster.activeCount(L, T) .. "/26 active: room for him.",
      act = function()
        local ok, err = PRoster.callUp(L, T, r.id)
        if ok then
          PRoster.validate(L, T)
          PL.news(L, "CALLED UP: " .. PM.name(r) .. " (" .. r.pos .. ")", true)
          self.after = { kind = "callup", p = r }
        else Toast.show(err, "bad") end
      end }
  end
  if p.pos ~= "P" then
    local pos = T.field and T.field[p.id] or p.pos
    local cid = PRoster.coverFor(L, T, pos)
    local c = cid and L.players[cid]
    if c then
      fixes[#fixes + 1] = { score = (p.inj.d <= 7) and 2 or 0,
        label = "No move: " .. c.ln .. " plays " .. pos,
        detail = pos .. " defense " .. PM.grade(p.r.fld) .. " \u{2192} " .. PM.grade(c.r.fld) .. ". The roster stays as it is.",
        act = function() PRoster.validate(L, T) end }
    end
  else
    fixes[#fixes + 1] = { score = (p.inj.d <= 7) and 2 or 0, label = "No move: the staff covers",
      detail = (p.role == "SP" and "The long man takes his turns." or "The bullpen shifts a role down.") .. " The roster stays as it is.",
      act = function() PRoster.autoPitching(L, T) PRoster.validate(L, T) end }
  end
  local aid = PRoster.aiPick(L, T)
  local a = aid and L.players[aid]
  fixes[#fixes + 1] = { score = 0.5,
    label = "Let the assistant GM decide" .. (a and room and (" (he'd call up " .. a.ln .. ")") or ""),
    detail = "He handles injuries from now on, too (Options: Assistant GM).",
    act = function()
      L.settings.autoRoster = true
      PRoster.aiMaintain(L, T)
      PRoster.validate(L, T)
    end }
  local best = 1
  for i, f in ipairs(fixes) do if f.score > fixes[best].score then best = i end end
  self.fixes, self.sel = fixes, best
  -- the static page
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  Draw.tile(0, 0, 400, 240, "light")
  local ix, iy, iw, ih = Draw.window(8, 4, 384, 214, "Trainer's room")
  local key = "doctor-0" .. (p.id % 3 + 1)
  local photo = Archive.get(key, 96)
  if photo then photo:draw(ix + 4, iy + 4)
  else
    photo = Archive.get(key, 160)
    if photo then photo:drawScaled(ix + 4, iy + 4, 0.6) end
  end
  gfx.drawRect(ix + 3, iy + 3, 98, 62)
  local px = ix + 104
  Faces.draw("face:" .. p.face, px, iy + 4, 48)
  local tx = px + 54
  Text.draw(Text.ellipsize(PM.name(p) .. ", " .. (p.pos == "P" and (p.role or "P") or p.pos), UI.fonts.bold, iw - (tx - ix) - 4), tx, iy + 4, UI.fonts.bold)
  Text.draw(p.inj.k:sub(1, 1):upper() .. p.inj.k:sub(2), tx, iy + 19, UI.fonts.head)
  Text.draw("Out " .. p.inj.d .. " days, back " .. PL.date(L, L.day + p.inj.d), tx, iy + 36, UI.fonts.body)
  local ms = missedSeries(L, p)
  if ms then Text.draw("(" .. ms .. ")", tx, iy + 49, UI.fonts.body) end
  Text.block("\"" .. LINES[p.id % #LINES + 1] .. "\" \u{2014} the trainer", px, iy + 66, iw - (px - ix) - 4, UI.fonts.body, nil, 2)
  gfx.popContext()
  self.bg = img
  self.ox, self.oy, self.ow = ix, iy + 98, iw
  Sfx.stinger("new_mail")
end

function Trainer:update()
  self.bg:draw(0, 0)
  local y = self.oy
  for i, f in ipairs(self.fixes) do
    local on = i == self.sel
    if on then gfx.fillRect(self.ox + 2, y - 1, self.ow - 4, 30) end
    local col = on and "white" or nil
    Text.draw(Text.ellipsize(f.label, UI.fonts.bold, self.ow - 12), self.ox + 6, y, UI.fonts.bold, col)
    Text.draw(Text.ellipsize(f.detail, UI.fonts.body, self.ow - 22), self.ox + 16, y + 14, UI.fonts.body, col)
    y = y + 32
  end
  PUI.hintBar("A: do it   up/down: other fixes   B: later (the lineup fills itself)")
end

function Trainer:upButtonDown() self.sel = math.max(1, self.sel - 1) Sfx.focus() end
function Trainer:downButtonDown() self.sel = math.min(#self.fixes, self.sel + 1) Sfx.focus() end

function Trainer:close()
  local L = Pennant.L
  -- handled: off the queue
  local q = {}
  for _, e in ipairs(L.trainerQ or {}) do if e.id ~= self.p.id then q[#q + 1] = e end end
  L.trainerQ = #q > 0 and q or nil
  App.pop()
  if self.after and self.after.kind == "callup" then
    PennantUI.CallUp.open({ p = self.after.p, onDone = self.onDone })
  elseif self.onDone then self.onDone() end
end

function Trainer:AButtonDown()
  Sfx.coin()
  self.fixes[self.sel].act()
  self.done = true
  self:close()
end

function Trainer:BButtonDown()
  Sfx.back()
  -- later: stays on the queue (the assistant GM takes it in two days), not shown again
  for _, e in ipairs(Pennant.L.trainerQ or {}) do if e.id == self.p.id then e.snoozed = true end end
  App.pop()
  if self.onDone then self.onDone() end
end

--- The next injury waiting for the Trainer's Room, opened over whatever is on top; then onDone.
function PennantUI.trainerFollowUp(onDone)
  local L = Pennant.L
  local e = PL.trainerPending(L)
  if e and e.snoozed then
    for _, x in ipairs(L.trainerQ or {}) do if not x.snoozed then e = x break end end
  end
  if e and not e.snoozed and not L.trainerSeen then
    L.trainerSeen = L.day
    PennantUI.Trainer.open({ id = e.id, onDone = function() L.trainerSeen = nil if onDone then onDone() end end })
    return true
  end
  if onDone then onDone() end
  return false
end

-- Call-up card (P1-5): a bus ticket ---------------------------------------------------------------

local CallUp = { opaque = true }
CallUp.__index = CallUp
PennantUI.CallUp = CallUp

local PACK <const> = { "He packed in four minutes.", "He left his glove on the bus and went back for it.", "His landlady cried. He did not.",
  "He asked if the big club has a laundry.", "He was on the bus before the call ended." }

function CallUp.open(args)
  local s = setmetatable({}, CallUp)
  App.push(s, args)
  return s
end

function CallUp:enter(args)
  local L = Pennant.L
  local p = args.p
  self.onDone = args.onDone
  self.t = 0
  local played = ((p.st.b and p.st.b.g) or 0) + ((p.st.p and p.st.p.g) or 0)
  p.debut = ((p.mlYrs or 0) == 0 and played == 0) and L.day or nil
  local c = PennantClubs.byAbbr[L.user]
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  Draw.tile(0, 0, 400, 240, "light")
  -- the ticket
  local x, y, w, h = 40, 40, 320, 150
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 4, y + 4, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRect(x, y, w, h)
  gfx.setLineWidth(1)
  gfx.fillRect(x, y, w, 20)
  Text.draw("ONE WAY \u{2022} ADMIT ONE BALLPLAYER", x + w // 2, y + 3, UI.fonts.bold, "white", "center")
  for k = 0, 9 do gfx.fillCircleAtPoint(x + 236, y + 28 + k * 12, 2) end
  Faces.draw("face:" .. p.face, x + 10, y + 28, 48)
  Text.draw("FROM", x + 66, y + 28, UI.fonts.body)
  Text.draw(Text.ellipsize(c.farm[1] .. " " .. c.farm[2], UI.fonts.bold, 160), x + 66, y + 41, UI.fonts.bold)
  Text.draw("TO", x + 66, y + 58, UI.fonts.body)
  Text.draw(Text.ellipsize(PUI.teamName(L.user), UI.fonts.bold, 160), x + 66, y + 71, UI.fonts.bold)
  Text.draw("CALLED UP", x + 278, y + 40, UI.fonts.head, nil, "center")
  Text.draw(PL.date(L), x + 278, y + 60, UI.fonts.bold, nil, "center")
  Text.block(PM.name(p) .. " has been called up from " .. c.farm[1] .. ". " .. PACK[p.id % #PACK + 1], x + 10, y + 94, 220, UI.fonts.body, nil, 4)
  Text.draw("A \u{25b6}", x + w - 10, y + h - 18, UI.fonts.bold, nil, "right")
  gfx.popContext()
  self.img = img
  Sfx.coin()
end

function CallUp:update()
  self.t = self.t + 1
  local u = Game.settings.reduceMotion and 1 or math.min(1, self.t / 10)
  gfx.clear(gfx.kColorWhite)
  -- the ticket slides up
  self.img:draw(0, math.floor((1 - u) * 60))
end

function CallUp:AButtonDown()
  if self.t < 6 then return end
  Sfx.select()
  App.pop()
  if self.onDone then self.onDone() end
end
CallUp.BButtonDown = CallUp.AButtonDown

-- An AI club's call (P2-8) ------------------------------------------------------------------------
-- A GM phones with an offer for one of your spare parts. A: take it (a telegram), B: no thanks,
-- or Counter: the trade table with both players already on it.

local Call = { opaque = true }
Call.__index = Call
PennantUI.Call = Call

local CALL_ART <const> = { "phone_candlestick", "phone_wall", "switchboard", "office_phone", "desk_phone", "phone_call" }
local PITCH <const> = {
  "We like your %s. We think he'd like it here.",
  "I'll be straight with you: %s doesn't play much over there.",
  "My manager's been asking about %s. Help me out.",
  "%s for a ballplayer who plays. What do you say?",
}

function Call.open(args)
  local s = setmetatable({}, Call)
  App.push(s, args)
  return s
end

function Call:enter(args)
  local L = Pennant.L
  local c = L.tradeCall
  self.c, self.onDone = c, args and args.onDone
  self.sel = 1
  local give, get = L.players[c.give], L.players[c.get]
  local img = gfx.image.new(400, 240, gfx.kColorWhite)
  gfx.pushContext(img)
  local art = gfx.image.new("images/pennant/" .. CALL_ART[(c.day + #c.from) % #CALL_ART + 1])
  if art then art:draw(0, 0) end
  -- the caller's card over the photo
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 16)
  Text.draw("LONG DISTANCE \u{2022} " .. PennantClubs.byAbbr[c.from].city:upper(), 200, 1, UI.fonts.bold, "white", "center")
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 118, 400, 122)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawLine(0, 118, 399, 118)
  PUI.logo(c.from, 6, 122, 32)
  Text.draw("The " .. PUI.nick(c.from) .. " GM:", 44, 122, UI.fonts.bold)
  Text.draw("\"" .. string.format(PITCH[c.day % #PITCH + 1], give.ln) .. "\"", 44, 136, UI.fonts.body)
  -- the offer: you give / you get
  local function side(p, x, label)
    Text.draw(label, x, 156, UI.fonts.body)
    Faces.draw("face:" .. p.face, x, 170, 24)
    Text.draw(Text.ellipsize(PM.name(p), UI.fonts.bold, 150), x + 28, 168, UI.fonts.bold)
    local line = p.pos == "P" and string.format("%s, %.2f ERA", p.role or "P", PM.era(p.st.p)) or (p.pos .. ", " .. PM.rate3(PM.avg(p.st.b)))
    Text.draw(Text.ellipsize("OVR " .. PM.ovr(p) .. ", age " .. p.age .. ", " .. line, UI.fonts.body, 160), x + 28, 182, UI.fonts.body)
  end
  side(give, 8, "YOU SEND")
  side(get, 206, "YOU GET")
  gfx.popContext()
  self.img = img
  Sfx.stinger("new_mail")
end

local CALL_BTNS <const> = { "Take it", "Counter", "No thanks" }

function Call:update()
  self.img:draw(0, 0)
  local bw = 120
  for i, t in ipairs(CALL_BTNS) do
    local bx = 8 + (i - 1) * (bw + 9)
    Draw.button(bx, 202, bw, 18, t)
    if i == self.sel then
      gfx.setColor(gfx.kColorXOR)
      gfx.fillRect(bx + 2, 204, bw - 4, 14)
      gfx.setColor(gfx.kColorBlack)
    end
  end
  PUI.hintBar("A: choose  left/right: Take it / Counter / No thanks")
end

function Call:leftButtonDown() self.sel = math.max(1, self.sel - 1) Sfx.focus() end
function Call:rightButtonDown() self.sel = math.min(#CALL_BTNS, self.sel + 1) Sfx.focus() end

function Call:close()
  App.pop()
  if self.onDone then self.onDone() end
end

function Call:AButtonDown()
  local L = Pennant.L
  local c = self.c
  L.tradeCall = nil
  if self.sel == 1 then
    local mine, theirs = L.teams[L.user], L.teams[c.from]
    local give, get = L.players[c.give], L.players[c.get]
    if not give or give.team ~= L.user or not get or get.team ~= c.from then Toast.show("That deal's gone.", "bad") self:close() return end
    PRoster.trade(L, mine, theirs, { c.give }, { c.get })
    PL.news(L, "TRADE: " .. PUI.nick(L.user) .. " send " .. PM.name(give) .. " to " .. PUI.nick(c.from) .. " for " .. PM.name(get), true)
    Sfx.coin()
    self:close()
    PennantUI.Telegram.open({ text = "TRADE. " .. L.user .. " SEND " .. PM.name(give):upper() .. " TO " .. c.from .. " FOR " .. PM.name(get):upper() .. ". STOP.",
      note = get.ln .. " reports tomorrow." .. (PRoster.activeCount(L, mine) > 26 and "  You're over 26 active: send someone down." or "") })
  elseif self.sel == 2 then
    Sfx.select()
    self:close()
    local t = PennantUI.TradeTable.open({ other = c.from })
    t.give, t.get = { c.give }, { c.get }
    t:render(true)
  else
    Sfx.back()
    PL.news(L, "You turned down the " .. PUI.nick(c.from) .. ".", true)
    self:close()
  end
end
function Call:BButtonDown() self.sel = 3 self:AButtonDown() end

--- A call waiting (from today or yesterday), opened over whatever is on top; then onDone.
function PennantUI.callFollowUp(onDone)
  local L = Pennant.L
  local c = L.tradeCall
  if c and L.day - c.day <= 1 and not c.shown and L.players[c.give] and L.players[c.get] then
    c.shown = true
    PennantUI.Call.open({ onDone = onDone })
    return true
  end
  if onDone then onDone() end
  return false
end
