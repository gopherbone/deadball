-- Roster moves: the farm (call-ups / demotions) and simple trades (pick a club, pick up to three
-- players a side; the other club weighs ability, upside and age and says yes or no).

local gfx <const> = playdate.graphics
PennantUI = PennantUI or {}

-- Farm -----------------------------------------------------------------------------------------

local Farm = PUI.define({ title = "Farm & roster", hint = "A: call up / send down / card" })
PennantUI.Farm = Farm

function Farm:resume(r) Page.resume(self, r) self:render(true) end

function Farm:act(p)
  local L = Pennant.L
  local T = L.teams[L.user]
  local items = {}
  if p.lvl == "F" then
    items[#items + 1] = { label = "Call up", action = function()
      local ok, err = PRoster.callUp(L, T, p.id)
      if ok then PRoster.validate(L, T) Sfx.coin() Toast.show(PM.short(p) .. " joins the big club.", "good") PL.news(L, "CALLED UP: " .. PM.name(p) .. " (" .. p.pos .. ")", true)
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

function Farm:layout(Lb)
  local L = Pennant.L
  local T = L.teams[L.user]
  local c = PennantClubs.byAbbr[L.user]
  local act = PRoster.activeCount(L, T)
  local y = 2
  Text.draw("Big club: " .. act .. "/26 active" .. (act > 26 and "  (too many: send someone down)" or (act < 26 and "  (room to call up " .. (26 - act) .. ")" or "")), 4, y, UI.fonts.bold)
  y = y + 18
  y = PUI.head(Lb, c.farm[1] .. " " .. c.farm[2] .. " (farm)", 4, y, 388)
  PUI.rowHeader(4, y, "AGE POT")
  y = y + 16
  local farm = {}
  for _, id in ipairs(T.farm) do farm[#farm + 1] = L.players[id] end
  table.sort(farm, function(a, b) return PM.ovr(a) > PM.ovr(b) end)
  for _, p in ipairs(farm) do
    PUI.playerRow(Lb, p, 4, y, 388, function() self:act(p) end, { extra = p.age .. "  " .. string.rep("\u{2605}", PM.potStars(p)), hint = PM.name(p) .. ": A to call him up" })
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

function Trades:layout(Lb)
  local L = Pennant.L
  Text.draw("Call another club", 6, 4, UI.fonts.head)
  Text.draw("Up to three players a side. They'll tell you if it's close.", 6, 22, UI.fonts.body)
  local i = 0
  for _, c in ipairs(PennantClubs) do
    if c.abbr ~= L.user then
      local col, row = i % 2, i // 2
      local x, y = 6 + col * 194, 42 + row * 40
      local T = L.teams[c.abbr]
      gfx.drawRect(x, y, 188, 36)
      PUI.logo(c.abbr, x + 3, y + 2, 32)
      Text.draw(c.city .. " " .. c.name, x + 40, y + 3, UI.fonts.bold)
      Text.draw(T.w .. "-" .. T.l .. ", " .. PUI.ord(PL.rank(L, c.abbr)), x + 40, y + 18, UI.fonts.body)
      Lb:link(x, y, 188, 36, function() PennantUI.TradeTable.open({ other = c.abbr }) end, { id = "c" .. c.abbr, style = "ring", hint = "Talk to " .. c.name })
      i = i + 1
    end
  end
  Lb:mark(42 + 4 * 40)
end

local TT = PUI.define({ title = "Trade talk", hint = "A: add / remove a player  Offer at the bottom" })
PennantUI.TradeTable = TT

function TT:init(args)
  self.other = args.other
  self.give, self.get = {}, {}
end

local function has(list, id) for i, x in ipairs(list) do if x == id then return i end end end

function TT:toggle(list, id, row)
  local i = has(list, id)
  if i then table.remove(list, i) Sfx.back()
  elseif #list < 3 then list[#list + 1] = id Sfx.select()
  else Toast.show("Three players a side, tops.", "bad") return end
  -- just that row and the offer strip (a full render of 80 rows is slow on the device)
  if row then
    PUI.repaint(self, row.x - 1, row.y - 1, row.w + 2, 15, function() self:paintRow(row) end)
    row.link.style = has(list, id) and "ring" or "invert"
    self:repaintHeader()
  else
    self:render(true)
  end
end

function TT:paintRow(row)
  local p, list, x, y, w = row.p, row.list, row.x, row.y, row.w
  local on = has(list, p.id)
  if on then gfx.fillRect(x - 1, y - 1, w + 2, 15) end
  local col = on and "white" or nil
  Text.draw(p.pos == "P" and (p.role or "P") or p.pos, x + 2, y, UI.fonts.bold, col)
  Text.draw(Text.ellipsize(PM.short(p), UI.fonts.body, 84), x + 26, y, UI.fonts.body, col)
  Text.draw(tostring(PM.ovr(p)), x + 134, y, UI.fonts.bold, col, "right")
  Text.draw(p.age .. (p.lvl == "F" and "f" or ""), x + 160, y, UI.fonts.body, col, "right")
  Text.draw(PM.potStars(p) .. "\u{2605}", x + w - 2, y, UI.fonts.body, col, "right")
end

function TT:column(Lb, T, list, x, y, w)
  local L = Pennant.L
  local ps = {}
  for _, id in ipairs(T.ml) do ps[#ps + 1] = L.players[id] end
  for _, id in ipairs(T.farm) do ps[#ps + 1] = L.players[id] end
  table.sort(ps, function(a, b) return PRoster.value(a) > PRoster.value(b) end)
  for _, p in ipairs(ps) do
    local row = { p = p, list = list, x = x, y = y, w = w }
    PUI.lazy(Lb, x - 1, y - 1, w + 2, 15, function() self:paintRow(row) end)
    row.link = Lb:link(x - 1, y - 1, w + 2, 15, function() self:toggle(list, p.id, row) end,
      { id = (list == self.give and "g" or "t") .. p.id, style = has(list, p.id) and "ring" or "invert",
        hint = PM.name(p) .. ", " .. p.age .. (p.lvl == "F" and " (farm)" or "") .. ". OVR " .. PM.ovr(p) .. ", potential " .. (p.pot or "?") .. (p.inj and (", hurt: " .. p.inj.k) or "") })
    y = y + 15
  end
  return y
end

--- The offer strip: counts, the interest meter, the Offer button.
function TT:paintHeader()
  local L = Pennant.L
  local mine, theirs = L.teams[L.user], L.teams[self.other]
  local ok, ratio, note = PRoster.evaluate(L, mine, theirs, self.give, self.get)
  local y = 2
  Text.draw("You give " .. #self.give .. ", get " .. #self.get, 4, y + 2, UI.fonts.bold)
  Text.draw("Their interest", 150, y + 2, UI.fonts.body)
  Draw.progress(236, y + 4, 70, 9, (#self.give > 0 and #self.get > 0) and math.min(1, ratio) or 0, "gray")
  Draw.button(314, y, 76, 17, "Offer")
  return (#self.give > 0 and #self.get > 0) and ("They say: " .. note) or "Pick players on both sides first"
end

function TT:repaintHeader()
  local hint
  PUI.repaint(self, 0, 0, 395, 20, function() hint = self:paintHeader() end)
  if self.offerLink then self.offerLink.hint = hint end
end

function TT:layout(Lb)
  local L = Pennant.L
  local mine, theirs = L.teams[L.user], L.teams[self.other]
  -- the offer, up top so it's always in reach
  local hint = self:paintHeader()
  self.offerLink = Lb:link(314, 2, 76, 17, function() self:offer() end, { id = "offer", style = "ring", hint = hint })
  local y = 24
  PUI.logo(L.user, 4, y, 16)
  Text.draw("You give", 24, y + 1, UI.fonts.head)
  PUI.logo(self.other, 202, y, 16)
  Text.draw("You get", 222, y + 1, UI.fonts.head)
  y = y + 20
  local y1 = self:column(Lb, mine, self.give, 4, y, 188)
  local y2 = self:column(Lb, theirs, self.get, 202, y, 188)
  gfx.drawLine(197, y - 4, 197, math.max(y1, y2))
  Lb:mark(math.max(y1, y2) + 4)
end

function TT:offer()
  local L = Pennant.L
  if #self.give == 0 or #self.get == 0 then Toast.show("Pick players on both sides.", "bad") return end
  local mine, theirs = L.teams[L.user], L.teams[self.other]
  local ok, ratio, note = PRoster.evaluate(L, mine, theirs, self.give, self.get)
  if not ok then
    Sfx.error()
    Dialog.alert(PUI.nick(self.other) .. " say no", note .. (ratio > 0.85 and " Add a prospect or take less back." or ""))
    return
  end
  local function names(list) local t = {} for _, id in ipairs(list) do t[#t + 1] = PM.name(L.players[id]) end return table.concat(t, ", ") end
  Dialog.confirm("Deal!", "You send " .. names(self.give) .. " to " .. PUI.teamName(self.other) .. " for " .. names(self.get) .. ". Shake on it?", "Shake", "Wait", function(yes)
    if not yes then return end
    local txt = "TRADE: " .. PUI.nick(L.user) .. " send " .. names(self.give) .. " to " .. PUI.nick(self.other) .. " for " .. names(self.get)
    PRoster.trade(L, mine, theirs, self.give, self.get)
    PL.news(L, txt, true)
    Sfx.coin()
    Toast.show("Trade done.", "good")
    self.give, self.get = {}, {}
    self:render(true)
    if PRoster.activeCount(L, mine) > 26 then Dialog.alert("Roster crunch", "You're over 26 active. Send someone down from the Farm screen.") end
  end)
end

function TT:initialFocus() for i, l in ipairs(self.links) do if l.id and l.id:sub(1, 1) == "t" then return i end end return 1 end
