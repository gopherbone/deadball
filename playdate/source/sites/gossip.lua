-- Bets By Bobby's Gossip Board: drama props on rumoured and public storylines.
-- Tabloid rows (headline, blurb, stage) with their prop questions and pari-mutuel pools,
-- a bet slip via the Amount dialog, your open props, results, and the rumour mill.
-- Everything is painted once into the page canvas; the only live widget is the headline
-- ticker, which scrolls a pre-rendered image (no per-frame text work).

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Gossip = Page.define({ canvasH = 1400, refreshOnResume = false })
Sites.Gossip = Gossip

local W <const> = 392
local BX <const> = 4
local BW <const> = 384

function Gossip:url() return "http://www.betsbybobby.com/~bobby/gossip.html" end
function Gossip:sources() return { g = "/gossip" } end

function Gossip:statusText()
  local n = self.openCount or 0
  return n > 0 and (n .. (n == 1 and " open market" or " open markets") .. ". Bobby hears everything.") or "Transferring data from betsbybobby.com... done."
end

function Gossip:onResult(r)
  if r == "placed" then self:reload(true) end
end

--- The fonts lack a few typographic glyphs the server uses in bucket labels.
local function clean(s)
  s = tostring(s or "")
  s = s:gsub("\u{2264}", "<="):gsub("\u{2013}", "-")
  return s
end

local function labelOf(p, key)
  for _, o in ipairs(p.options or {}) do
    if o.key == key then return clean(o.label) end
  end
  return clean(key)
end

--- "answer by D41 (2h 10m)": when the question is forced to resolve even if the story lingers
local function resolveText(p)
  if not p.resolveByDay then return nil end
  local s = "answer by D" .. p.resolveByDay
  if p.resolveByAt then
    local ms = p.resolveByAt - Api.now()
    if ms > 0 then s = s .. " (" .. Fmt.dur(ms) .. ")" end
  end
  return s
end

local function closesText(p)
  local r = resolveText(p)
  if p.status ~= "open" then
    return r and ("book closed \u{2022} " .. r) or "book closed, waiting on the result"
  end
  if not p.closesAt then return r or "open" end
  local ms = p.closesAt - Api.now()
  local c = ms <= 0 and "closing..." or ("closes in " .. Fmt.dur(ms))
  return r and (c .. " \u{2022} " .. r) or c
end

-- Ticker -----------------------------------------------------------------------------------

--- Pre-renders the headline ticker once per layout (the live widget only blits it).
function Gossip:buildTicker(items)
  local parts = {}
  for i = 1, math.min(#items, 8) do parts[#parts + 1] = items[i].headline:upper() end
  if #parts == 0 then parts[1] = "SLOW NEWS DAY" end
  local s = "HOT GOSSIP:  " .. table.concat(parts, "  ***  ") .. "  ***  "
  local f = UI.fonts.bold
  local w = math.min(3000, f:getTextWidth(s))
  local img = gfx.image.new(w, 13, gfx.kColorClear)
  gfx.pushContext(img)
  Text.draw(s, 0, 0, f)
  gfx.popContext()
  self.ticker, self.tickerW = img, w
end

-- Option buttons -------------------------------------------------------------------------------

local function optButton(L, x, y, w, label, mine, enabled, action, opts)
  local h = 15
  if mine then
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRoundRect(x, y, w, h, 3)
    Text.draw(label, x + w // 2, y + 1, UI.fonts.bold, "white", "center")
  else
    Draw.button(x, y, w, h, label, (not enabled) and "disabled" or nil, UI.fonts.body)
  end
  if enabled then
    opts.style = "ring"
    L:link(x, y, w, h, action, opts)
  else
    L:mark(y + h)
  end
end

-- Layout ------------------------------------------------------------------------------------------

function Gossip:layout(L)
  local g = self.data.g or {}
  local items = g.storylines or {}
  Draw.tile(0, 0, W, 6400, "lighter")
  -- masthead
  local _, mh = Draw.wordart("GOSSIP BOARD", W // 2, 2, UI.fonts.slab, { style = "gradient" })
  local y = 2 + mh
  Text.draw("You heard it here second.  \u{2022}  Day " .. (g.day or "?") .. "  \u{2022}  odds by Bobby", W // 2, y, UI.fonts.body, nil, "center")
  y += 16
  -- nav
  local bw = L:textLink("\u{25c0} Back to the odds", BX + 4, y, function() self:goBack() end, { id = "back", hint = "Bets By Bobby: today's games" })
  if #(g.my or {}) + #(g.recent or {}) > 0 then
    L:textLink("My props \u{25bc}", BX + 18 + bw, y, function() self:scrollToMine() end, { id = "mine", hint = "Jump to your prop bets" })
  end
  y += 18
  -- ticker
  self:buildTicker(items)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(2, y, W - 4, 15)
  local tickY = y
  L:live(4, tickY + 1, W - 8, 13, function(_, x, yy, f)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(x, yy, W - 8, 13)
    local img, tw = self.ticker, self.tickerW
    if not img then return end
    local off = (f * 2) % tw
    gfx.setClipRect(x, yy, W - 8, 13)
    gfx.setImageDrawMode(gfx.kDrawModeInverted)
    img:draw(x - off, yy + 1)
    if tw - off < W then img:draw(x - off + tw, yy + 1) end
    gfx.setImageDrawMode(gfx.kDrawModeCopy)
    gfx.setClipRect(0, Chrome.TOP, 400, Chrome.VIEW_H)
  end)
  y += 21

  -- storylines
  local open = 0
  self.storyY, self.storyLink = {}, {}
  if #items == 0 then
    Draw.panel(BX, y, BW, 40)
    L:text("No scandals on the board. Everybody is behaving. It won't last.", BX + 8, y + 6)
    L:text("Rumours turn into markets here the day they leak.", BX + 8, y + 21)
    y += 48
  end
  for _, s in ipairs(items) do
    y, open = self:layoutStory(L, s, y, open)
  end
  self.openCount = open

  -- your props
  self.mineY = y
  y = self:layoutBets(L, y, "YOUR OPEN PROPS", g.my or {}, "Nothing riding on anybody's private life. Yet.")
  y = self:layoutBets(L, y, "RESULTS", g.recent or {}, "No results yet.")

  -- rumour mill (the BBS)
  y = self:layoutChatter(L, y, g.chatter or {})
  -- the house rules: on a white card (light text straight on the dotted wallpaper was hard to read)
  local rules = "Bobby pays at the end of the day the story breaks. House keeps 10%. Bobby's regulars cover every answer. Story goes cold? Everybody gets their money back."
  local rh = #Text.wrap(rules, UI.fonts.body, BW - 8) * Text.lineHeight(UI.fonts.body) + 16
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(BX, y, BW, rh + 2)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(BX, y, BW, rh + 2)
  y += 2
  y += Text.block(rules, BX + 4, y, BW - 8, UI.fonts.body) + 1
  Text.draw("(not a real bookie, this is entertainment)", BX + 4, y, UI.fonts.body)
  y += 20
  Draw.stripes(BX, y, BW, 12, "UNDER CONSTRUCTION")
  L:mark(y + 16)
end

function Gossip:layoutStory(L, s, y, open)
  local top = y
  self.storyY[s.id] = top
  local x0, tx = BX + 6, BX + 62
  local tw = BW - 68
  -- paint the frame after measuring: draw content on a white fill first
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(BX, y, BW, 2000)   -- trimmed below by the next row's fill / the frame
  gfx.setColor(gfx.kColorBlack)
  y += 6
  -- photo
  local who = s.who or {}
  L:face(who.face, x0, y, 48, who.id and function() Nav.person(who.id) end or nil,
    { id = "who:" .. s.id, hint = (who.name or "") .. (who.teamAbbr and (" (" .. who.teamAbbr .. ")") or "") .. ": fan page" })
  -- stamp + kind
  local cx = tx
  if s.heard then
    cx += Draw.chip(cx, y, "YOU HEARD...", UI.fonts.bold) + 4
  elseif s.visibility == "rumoured" then
    cx += Draw.chip(cx, y, "RUMOR", UI.fonts.bold, true) + 4
  else
    cx += Draw.chip(cx, y, "CONFIRMED", UI.fonts.bold) + 4
  end
  Text.draw(clean(s.kind):gsub("_", " "):upper(), cx + 2, y + 1, UI.fonts.body)
  y += 16
  -- headline
  y += Text.block(clean(s.headline):upper(), tx, y, tw, UI.fonts.head, nil, 2) + 1
  -- who / stage
  local line = (who.name or "?") .. (s.team and (" \u{2022} " .. s.team.city .. " " .. s.team.name) or "") .. " \u{2022} status: " .. clean(s.stage)
  Text.draw(Text.ellipsize(line, UI.fonts.body, tw), tx, y, UI.fonts.body)
  y += 14
  if s.blurb and s.blurb ~= "" then
    y += Text.block("\"" .. clean(s.blurb) .. "\"", tx, y, tw, UI.fonts.body, nil, 2)
  end
  y = math.max(y, top + 6 + 62) + 4
  if s.heard then
    Draw.dotted(BX + 6, BX + BW - 7, y)
    y += 4
    y += Text.block("Only you know. No book until it leaks. A crew can help with that (BBS > Operations).", BX + 8, y, BW - 16, UI.fonts.body) + 3
  end
  -- prop questions
  for _, p in ipairs(s.props or {}) do
    Draw.dotted(BX + 6, BX + BW - 7, y)
    y += 4
    local isOpen = p.status == "open"
    if isOpen then open += 1 end
    y += Text.block(clean(p.question), BX + 8, y, BW - 16, UI.fonts.bold, nil, 2)
    y += 2
    -- options flow left to right, wrapping
    local ox = BX + 8
    for _, o in ipairs(p.options or {}) do
      local lbl = Text.ellipsize(clean(o.label), UI.fonts.body, 150)
      local mine = p.myBet and p.myBet.option == o.key
      local txt = (mine and "\u{2605} " or "") .. lbl .. "  " .. ((o.pays or 0) > 0 and (Fmt.pays(o.pays) .. "x") or "--")
      local w = UI.fonts.body:getTextWidth(txt) + 12
      if ox + w > BX + BW - 8 then
        ox = BX + 8
        y += 19
      end
      local hint = lbl .. ": " .. Fmt.money(o.pool or 0) .. " in the pool" .. ((o.pays or 0) > 0 and (", pays " .. Fmt.pays(o.pays) .. " per $1") or ", nobody on it yet")
      if mine then hint = "You: " .. Fmt.money(p.myBet.amount) .. " on " .. lbl .. ". " .. hint end
      local lid = "opt:" .. p.id .. ":" .. o.key
      if isOpen and not self.storyLink[s.id] then self.storyLink[s.id] = lid end
      optButton(L, ox, y, w, txt, mine, isOpen, function() self:bet(s, p, o) end, { id = lid, hint = hint })
      ox += w + 6
    end
    y += 18
    local foot = "Pool " .. Fmt.money(p.pool or 0) .. "  \u{2022}  " .. closesText(p)
    if p.myBet then foot = foot .. "  \u{2022}  you: " .. Fmt.money(p.myBet.amount) .. " on " .. labelOf(p, p.myBet.option) end
    Text.draw(Text.ellipsize(foot, UI.fonts.body, BW - 16), BX + 8, y, UI.fonts.body)
    y += 15
  end
  -- a crew can push the story along (love letters, tips to the wire, blackmail, smoothing it over)
  Draw.dotted(BX + 6, BX + BW - 7, y)
  y += 4
  L:textLink("Send a crew \u{25b6}", BX + 8, y, function() Nav.job({ storylineId = s.id }) end,
    { id = "rig:" .. s.id, hint = "Clubhouse BBS: a job on this story (a forged letter, a tip to the wire...)" })
  if not self.storyLink[s.id] then self.storyLink[s.id] = "rig:" .. s.id end
  y += 16
  y += 3
  -- frame (double rule, tabloid box) and clear what's below it
  gfx.setPattern(UI.pat.lighter)
  gfx.fillRect(0, y + 1, W, 2000)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(BX, top, BW, y - top)
  gfx.drawRect(BX + 2, top + 2, BW - 4, y - top - 4)
  L:mark(y)
  return y + 6, open
end

function Gossip:layoutBets(L, y, title, bets, empty)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(BX, y, BW, 15)
  Text.draw(title, BX + 5, Text.boxY(UI.fonts.bold, y, 15, title), UI.fonts.bold, "white")
  y += 18
  if #bets == 0 then
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(BX, y - 2, BW, 16)
    gfx.setColor(gfx.kColorBlack)
    L:text(empty, BX + 6, y, UI.fonts.body)
    return y + 20
  end
  for _, b in ipairs(bets) do
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(BX, y - 2, BW, 30)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(Fmt.money(b.amount), BX + 6, y, UI.fonts.bold)
    local right
    if b.status == "settled" then
      if b.refunded then right = "REFUNDED"
      elseif b.won then right = "WON " .. Fmt.money(b.payout or 0)
      else right = "LOST" end
    else
      right = (b.pays or 0) > 0 and ("pays ~" .. Fmt.money(math.floor(b.amount * b.pays))) or "open"
    end
    local rw = UI.fonts.bold:getTextWidth(right)
    Text.draw(Text.ellipsize(clean(b.optionLabel or b.option) .. "  \u{2022}  " .. clean(b.headline or ""), UI.fonts.body, BW - 80 - rw), BX + 60, y, UI.fonts.body)
    if b.won then
      gfx.fillRect(BX + BW - 9 - rw, y - 1, rw + 6, 13)
      Text.draw(right, BX + BW - 6, y, UI.fonts.bold, "white", "right")
    else
      Text.draw(right, BX + BW - 6, y, UI.fonts.bold, nil, "right")
    end
    local sub = clean(b.question or "")
    if b.status == "settled" and b.outcomeLabel then sub = "Answer: " .. clean(b.outcomeLabel) .. "  \u{2022}  " .. sub end
    Text.draw(Text.ellipsize(sub, UI.fonts.body, BW - 66), BX + 60, y + 13, UI.fonts.body)
    y += 32
  end
  return y + 4
end

function Gossip:layoutChatter(L, y, posts)
  if #posts == 0 then return y end
  local mono = UI.fonts.mono
  -- measure first so the black box fits
  local lines = {}
  for i = 1, math.min(#posts, 5) do
    local p = posts[i]
    local wrapped = Text.wrap((p.author or "anon") .. ": " .. clean(p.text), mono, BW - 16)
    for j = 1, math.min(3, #wrapped) do
      local s = wrapped[j]
      if j == 3 and #wrapped > 3 then s = Text.ellipsize(s .. " ...", mono, BW - 16) end
      lines[#lines + 1] = s
    end
  end
  local h = 22 + #lines * 15 + 6
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(BX, y, BW, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.drawRect(BX + 2, y + 2, BW - 4, h - 4)
  Text.draw("THE RUMOR MILL  (bbs:rumors, node 2)", BX + 8, y + 5, mono, "white")
  local ly = y + 22
  for _, s in ipairs(lines) do
    Text.draw(s, BX + 8, ly, mono, "white")
    ly += 15
  end
  gfx.setColor(gfx.kColorBlack)
  L:mark(y + h)
  return y + h + 8
end

--- Deep links: Nav.storyline(id) opens the board at that story, its first open question
--- focused; { mine = true } opens it at your props.
function Gossip:afterRender()
  if self.jumped or self.loading or not self.data.g then return end
  self.jumped = true
  if self.args.mine then self:scrollToMine() return end
  local id = self.args.storyline
  if not id then return end
  local y = self.storyY and self.storyY[id]
  if not y then
    Toast.show("That story isn't on the board. Bobby only books what's leaked.", "bad")
    return
  end
  self.scroll:jump(math.max(0, y - 4))
  local want = self.storyLink[id]
  for i, l in ipairs(self.links) do
    if l.id == want then self.focus = i self.ring = nil break end
  end
end

function Gossip:scrollToMine()
  if self.mineY then self.scroll:scrollTo(self.mineY - 4) end
end

-- Betting -------------------------------------------------------------------------------------------

--- A prop bet on the same ticket as a game bet (ui/ticket.lua): up/down flips the answer.
function Gossip:bet(s, p, o)
  if not Game.account then return end
  if not self:requireFresh() then return end
  if p.status ~= "open" then
    Dialog.alert("Book closed", "Bobby closed the book on that one. Results come in when the story breaks.")
    return
  end
  if p.myBet and p.myBet.option ~= o.key then
    Dialog.alert("One answer per question", "You're already on \"" .. labelOf(p, p.myBet.option) .. "\". Bobby doesn't let you hedge.")
    return
  end
  local max = math.floor((Game.account.money or 0) * 0.5)
  if max < 5 then
    Dialog.alert("Short on cash", "Bobby's minimum is $5, and he caps you at half your bankroll.")
    return
  end
  local sides = {}
  for _, opt in ipairs(p.options or {}) do
    -- top-ups only on the answer you already took
    if not p.myBet or p.myBet.option == opt.key then
      sides[#sides + 1] = { key = opt.key, label = clean(opt.label), pays = opt.pays }
    end
  end
  local function optOf(key)
    for _, opt in ipairs(p.options or {}) do if opt.key == key then return opt end end
  end
  Ticket.open({
    page = self,
    title = function(key) return clean(p.question) .. " " .. (labelOf(p, key)):upper() end,
    sub = clean(s.headline) .. " \u{2022} " .. closesText(p),
    sides = sides, side = o.key, min = 5, max = max,
    -- docs/API.md "House money": the house's own money isn't raked
    estimate = function(amount, key)
      local opt = optOf(key) or {}
      local pool, house = p.pool or 0, p.house or 0
      local net = 0.9 * (pool - house + amount) + house
      local mine = (opt.pool or 0) + amount
      return math.floor(amount * net / math.max(1, mine)), net / math.max(1, mine)
    end,
    winWord = function(key) return "it's \"" .. labelOf(p, key) .. "\"" end,
    closes = function() return p.closesAt and ("the book closes, " .. Fmt.dur(p.closesAt - Api.now())) or nil end,
    place = function(amount, key, done)
      Api.post("/props/bets", { propId = p.id, option = key, amount = amount }, function(err, d)
        if err then
          Sfx.error()
          Dialog.alert(err.code == "window_closed" and "Book closed" or "Bobby says no", Api.errorText(err))
          done(false)
          return
        end
        Game.absorb(d)
        done(true)
      end)
    end,
    after = { onRig = function() Nav.job({ storylineId = s.id }) end },
  })
end
