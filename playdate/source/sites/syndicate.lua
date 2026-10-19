-- Syndicates (BBS style): members, shared treasury, invites, private board, leaderboard.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local MONO = UI.fonts.mono

local Syn = Page.define({ style = "bbs", canvasH = 600, refreshOnResume = true })
Sites.Syndicate = Syn

function Syn:sources() return { s = "/syndicate" } end

local function line(y)
  gfx.setColor(gfx.kColorWhite)
  gfx.drawLine(4, y, 392, y)
  gfx.setColor(gfx.kColorBlack)
end

local function sectionTitle(text, y)
  line(y + 7)
  gfx.fillRect(10, y, MONO:getTextWidth(" " .. text .. " "), 16)
  Text.draw(" " .. text .. " ", 10, y, MONO, "white")
  return y + 20
end

function Syn:me() return Game.account and Game.account.name end

function Syn:layout(L)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 2000)
  local d = self.data.s or {}
  local s = d.syndicate
  if s == json.null then s = nil end
  local key = Sites.bbsMenuKey
  local y = Sites.bbsHeader(L, "SYNDICATE", s and ("max " .. (s.max or 4) .. " members") or "flying solo")
  if s then
    local _, nh = Draw.wordart(s.name:upper(), 200, y - 2, UI.fonts.slab)
    y += nh
    Text.draw("founded by " .. (s.founder or "?"), 200, y - 4, MONO, "white", "center")
    y += 16
    -- members table
    Text.draw("MEMBER", 4, y, MONO, "white")
    Text.draw("CASH", 236, y, MONO, "white", "right")
    Text.draw("CREW", 286, y, MONO, "white", "right")
    Text.draw("HEAT", 336, y, MONO, "white", "right")
    y += 16
    for _, m in ipairs(s.members or {}) do
      local nm = m.name .. (m.founder and " *" or "")
      -- name (rank) up to the CASH column: a 16-letter handle plus "(Made Man)" ran into the
      -- money; the rank goes first, then the name is cut
      local cash = Fmt.money(m.money)
      local label = Text.fit(nm .. " (" .. (m.rank or "") .. ")", 236 - MONO:getTextWidth(cash) - 12, MONO, { short = nm, fonts = {} })
      if m.name == self:me() then
        gfx.setColor(gfx.kColorWhite)
        gfx.fillRect(2, y, 392, 16)
        gfx.setColor(gfx.kColorBlack)
        Text.draw(label, 4, y, MONO)
        Text.draw(cash, 236, y, MONO, nil, "right")
        Text.draw(tostring(m.crewSize or 0), 286, y, MONO, nil, "right")
        Text.draw(tostring(m.heat or 0), 336, y, MONO, nil, "right")
      else
        Text.draw(label, 4, y, MONO, "white")
        Text.draw(cash, 236, y, MONO, "white", "right")
        Text.draw(tostring(m.crewSize or 0), 286, y, MONO, "white", "right")
        Text.draw(tostring(m.heat or 0), 336, y, MONO, "white", "right")
      end
      y += 16
    end
    for _ = #(s.members or {}) + 1, (s.max or 4) do
      Text.draw("- empty chair -", 4, y, MONO, "white")
      y += 16
    end
    y += 4
    -- treasury
    y = sectionTitle("TREASURY", y)
    Text.draw(Fmt.money(s.treasury or 0), 4, y - 2, UI.fonts.big, "white")
    local isFounder = s.founder == self:me()
    local x = 170
    x += key(L, x, y + 2, "D", "eposit", function() self:treasury(1) end, "Put money in the pot") + 12
    if isFounder then
      key(L, x, y + 2, "W", "ithdraw", function() self:treasury(-1) end, "Take money out (founder only)")
    else
      Text.draw("(founder withdraws)", x, y + 4, UI.fonts.body, "white")
    end
    y += 28
    -- commands
    y = sectionTitle("COMMANDS", y)
    x = 4
    x += key(L, x, y, "B", "oard", function() Sites.SynBoard.open({ thread = s.board or ("bbs:syn:" .. s.id), name = s.name }) end, "The private board (members only)") + 12
    x += key(L, x, y, "I", "nvite", function() self:invite(s) end, "Invite an account by name") + 12
    x += key(L, x, y, "T", "op 10", function() Sites.SynLeaderboard.open() end, "Syndicate leaderboard") + 12
    key(L, x, y, "Q", "uit", function() self:leave(s) end, "Leave the syndicate")
    y += 22
    y += Text.block("Allies can staff each other's jobs: their free crew show up in the op planner, marked with the ally's name.", 4, y, 388, UI.fonts.body, "white") + 6
  else
    y += 4
    y += Text.block("You're flying solo. Syndicates of up to 4 accounts share a treasury, a private board, and each other's crews. Rival crews still compete.", 4, y, 388, MONO, "white") + 8
    local x = 4
    x += key(L, x, y, "C", "reate one", function() self:create() end, "Start a syndicate (you name it)") + 14
    key(L, x, y, "T", "op 10", function() Sites.SynLeaderboard.open() end, "Syndicate leaderboard")
    y += 24
  end
  -- chip-in asks: an ally has your crew on a job and wants your share
  local chips = d.chipIns or {}
  if #chips > 0 then
    y = sectionTitle("CHIP IN?", y)
    for _, ch in ipairs(chips) do
      Text.draw(Text.ellipsize(ch.from .. ": " .. ch.job, MONO, 250), 4, y, MONO, "white")
      Text.draw(Fmt.money(ch.share) .. "/" .. Fmt.money(ch.total), 392, y, MONO, "white", "right")
      y += 16
      Text.draw(Text.ellipsize((ch.target and ("vs " .. ch.target.name .. ", ") or "") .. (ch.game or ""), UI.fonts.body, 250), 20, y + 2, UI.fonts.body, "white")
      local x = 280
      x += key(L, x, y, "Y", "es", function() self:chipIn(ch, true) end, "Pay " .. Fmt.money(ch.share) .. " toward " .. ch.job, "chip:y:" .. ch.opId) + 10
      key(L, x, y, "N", "o", function() self:chipIn(ch, false) end, "Let " .. ch.from .. " pay for it", "chip:n:" .. ch.opId)
      y += 20
    end
  end
  -- invites
  local invites = d.invites or {}
  if #invites > 0 then
    y = sectionTitle("INVITES", y)
    for _, inv in ipairs(invites) do
      Text.draw(Text.ellipsize(inv.from .. " -> " .. inv.syndicate, MONO, 280), 4, y, MONO, "white")
      key(L, 300, y, "A", "ccept", function() self:accept(inv) end, "Join " .. inv.syndicate, "inv:" .. inv.id)
      y += 18
    end
  end
  L:mark(y + 6)
end

function Syn:treasury(sign)
  if not self:requireFresh() then return end
  local s = self.data.s.syndicate
  local a = Game.account or { money = 0 }
  local max = sign > 0 and (a.money or 0) or (s.treasury or 0)
  if max < 1 then
    Toast.show(sign > 0 and "You're broke." or "The pot is empty.", "bad")
    return
  end
  Amount.open({ title = sign > 0 and "DEPOSIT" or "WITHDRAW", style = "bbs", prompt = sign > 0 and "Into the pot:" or "Out of the pot:",
    min = 1, max = max, value = math.min(max, 50),
    onDone = function(v)
      if not v then return end
      Busy.post("/syndicate/treasury", { amount = sign * v }, "Counting bills", function(d)
        Sfx.coin()
        Toast.show((sign > 0 and "Deposited " or "Withdrew ") .. Fmt.money(v), "good")
        self:reload(true)
      end)
    end })
end

function Syn:invite(s)
  if #(s.members or {}) >= (s.max or 4) then
    Dialog.show({ title = "FULL HOUSE", style = "bbs", icon = "!", body = "Four chairs, four members. Somebody has to leave first.", buttons = { "OK" }, cancel = 1 })
    return
  end
  NameEntry.open({ title = "Invite to " .. s.name, prompt = "Type the account name of the person you want in. They'll get an offer they could refuse.", maxLen = 16,
    onDone = function(t)
      if not t or t == "" then return end
      Busy.post("/syndicate/invite", { accountName = t }, "Sending word", function()
        Toast.show("Invite sent to " .. t .. ".", "good")
      end)
    end })
end

function Syn:create()
  NameEntry.open({ title = "Name your syndicate", prompt = "Pick a name for your syndicate. The Decency Board is watching.", maxLen = 24,
    onDone = function(t)
      if not t or t == "" then return end
      Busy.post("/syndicate", { name = t }, "Filing paperwork", function()
        Sfx.chime()
        Toast.show(t .. " is open for business.", "good")
        self:reload(true)
      end)
    end })
end

function Syn:chipIn(ch, yes)
  Busy.post("/ops/" .. ch.opId .. "/chipin", { accept = yes }, yes and "Passing the hat" or "Saying no", function(d)
    if yes then Sfx.coin() end
    Toast.show(d.result or (yes and "Chipped in." or "You pass."), yes and "good" or nil)
    self:reload(true)
  end)
end

function Syn:accept(inv)
  Busy.post("/syndicate/invites/" .. inv.id .. "/accept", {}, "Shaking hands", function(d)
    Sfx.chime()
    Toast.show(d.result or ("You joined " .. inv.syndicate .. "."), "good")
    self:reload(true)
  end)
end

function Syn:leave(s)
  Dialog.show({ title = "LEAVE " .. s.name:upper() .. "?", style = "bbs", icon = "?",
    body = "Your crew stops answering their calls. If you're the last one out, you take the treasury.",
    buttons = { "Leave", "Stay" }, cancel = 2,
    onChoose = function(i)
      if i ~= 1 then return end
      Busy.post("/syndicate/leave", {}, "Cleaning out your locker", function()
        Toast.show("You're on your own now.", "good")
        self:reload(true)
      end)
    end })
end

-- Private board -------------------------------------------------------------------------------

local Board = Page.define({ style = "bbs", canvasH = 600 })
Sites.SynBoard = Board

function Board:sources() return { t = "/threads/" .. self.args.thread } end
function Board:onResult(r) if r and r ~= "placed" then self:reload(true) end end

function Board:layout(L)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 3000)
  local y = Sites.bbsHeader(L, "PRIVATE BOARD", Text.ellipsize(self.args.name or "", MONO, 180))
  y += 2
  y = Comments.layout(L, self, self.data.t and self.data.t.comments or {}, 4, y, 386,
    { thread = self.args.thread, style = "bbs", title = "Post to the board", postLabel = "Post a message", emptyText = "Nobody's said anything. Suspicious." })
  L:mark(y + 4)
end

-- Leaderboard ----------------------------------------------------------------------------------

local LB = Page.define({ style = "bbs", canvasH = 500 })
Sites.SynLeaderboard = LB

function LB:sources() return { lb = "/syndicates/leaderboard" } end

function LB:layout(L)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, 400, 2000)
  local d = self.data.lb or {}
  local y = Sites.bbsHeader(L, "TOP SYNDICATES", "season " .. (d.season or "?"))
  Text.draw("#  NAME", 4, y, MONO, "white")
  Text.draw("NET", 300, y, MONO, "white", "right")
  Text.draw("JOBS", 352, y, MONO, "white", "right")
  Text.draw("PINCH", 396, y, MONO, "white", "right")
  y += 18
  local myName = Game.account and Game.account.name
  for _, r in ipairs(d.rows or {}) do
    local mine = false
    for _, m in ipairs(r.members or {}) do if m == myName then mine = true end end
    local fg = "white"
    Text.draw(string.format("%-2d %s", r.rank or 0, Text.ellipsize(r.name, MONO, 200)), 4, y, MONO, fg)
    Text.draw(Fmt.money(r.net or 0), 300, y, MONO, fg, "right")
    Text.draw((r.pulledOff or 0) .. "/" .. (r.ops or 0), 352, y, MONO, fg, "right")
    Text.draw(tostring(r.arrests or 0), 392, y, MONO, fg, "right")
    Text.draw(Text.ellipsize(table.concat(r.members or {}, ", "), UI.fonts.body, 360), 28, y + 16, UI.fonts.body, fg)
    if mine then
      -- your syndicate: inverted row
      gfx.setColor(gfx.kColorXOR)
      gfx.fillRect(2, y - 1, 394, 32)
      gfx.setColor(gfx.kColorBlack)
    end
    L:link(2, y - 1, 394, 32, function()
      Dialog.show({ title = r.name:upper(), style = "bbs", body = "Members: " .. table.concat(r.members or {}, ", ") .. "\nNet this season: " .. Fmt.money(r.net or 0) .. "\nJobs pulled off: " .. (r.pulledOff or 0) .. " of " .. (r.ops or 0) .. "\nArrests: " .. (r.arrests or 0), buttons = { "OK" }, cancel = 1 })
    end, { id = "lb:" .. (r.id or r.rank), style = "ring", hint = r.name })
    y += 36
  end
  Text.draw("NET = money won or lost this season. PINCH = arrests.", 4, y + 2, UI.fonts.body, "white")
  L:mark(y + 18)
end
