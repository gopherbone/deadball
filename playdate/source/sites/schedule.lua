-- Scoreboard (today's slate, live games link to BallCast) and box score pages.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Schedule = Page.define({ canvasH = 600 })
Sites.Schedule = Schedule

function Schedule:url() return "http://www.continentalleague.org/scoreboard.html" end
function Schedule:sources() return { today = "/today", sched = { "/schedule", optional = true } } end

function Schedule:statusText()
  return "Live games update in real time. Press A on a game to watch."
end

local function statusLabel(g)
  if g.status == "live" then return "LIVE " .. (g.score and g.score.inning or "") end
  if g.status == "final" then return "FINAL" end
  local left = (g.firstPitchAt or 0) - Api.now()
  return left > 0 and ("in " .. Fmt.dur(left)) or "soon"
end

function Schedule:layout(L)
  local W = 392
  local c = Game.clock or {}
  gfx.fillRect(0, 0, W, 24)
  Text.draw("SCOREBOARD", 8, 2, UI.fonts.big, "white")
  local sw = UI.fonts.bold:getTextWidth("STANDINGS \u{25b6}")
  Text.draw("STANDINGS \u{25b6}", W - 8, 6, UI.fonts.bold, "white", "right")
  L:link(W - 10 - sw, 3, sw + 4, 18, function() Sites.Standings.open() end, { id = "standings", style = "invert", hint = "League standings (all levels and the Enhanced League)" })
  Text.draw("Day " .. (c.day or "?"), W - 18 - sw, 6, UI.fonts.bold, "white", "right")
  local y = 30
  local games = self.data.today and self.data.today.games or {}
  local cont, enh = {}, {}
  -- your games first (stable otherwise)
  local ordered = {}
  for _, g in ipairs(games) do if g.myBet then ordered[#ordered + 1] = g end end
  for _, g in ipairs(games) do if not g.myBet then ordered[#ordered + 1] = g end end
  for _, g in ipairs(ordered) do
    if g.circuit == "enhanced" then enh[#enh + 1] = g else cont[#cont + 1] = g end
  end
  y = self:layoutGrid(L, cont, y, W)
  if #enh > 0 then
    gfx.fillRect(4, y, W - 8, 15)
    Text.draw("THE ENHANCED LEAGUE", 9, Text.boxY(UI.fonts.bold, y, 15), UI.fonts.bold, "white")
    Text.draw("out in the desert", W - 9, Text.boxY(UI.fonts.bold, y, 15), UI.fonts.body, "white", "right")
    L:link(4, y, W - 8, 15, function() Sites.Standings.open({ level = "EL" }) end, { id = "el-standings", hint = "Enhanced League standings & the Mirage Cup", style = "invert" })
    y += 19
    y = self:layoutGrid(L, enh, y, W)
  end
  -- upcoming from schedule
  local upcoming = {}
  local today = {}
  for _, g in ipairs(games) do today[g.id] = true end
  for _, g in ipairs(self.data.sched and self.data.sched.games or {}) do
    if not today[g.id] then upcoming[#upcoming + 1] = g end
  end
  if #upcoming > 0 then
    gfx.fillRect(4, y, W - 8, 15)
    Text.draw("COMING UP", 9, Text.boxY(UI.fonts.bold, y, 15), UI.fonts.bold, "white")
    y += 19
    for _, g in ipairs(upcoming) do
      Text.draw("Day " .. (g.day or "?"), 8, y, UI.fonts.bold)
      L:textLink(g.away.city .. " " .. g.away.name .. " @ " .. g.home.city .. " " .. g.home.name, 60, y, function() Sites.Game.open({ id = g.id }) end, { id = "up:" .. g.id, hint = g.park or "" })
      y += 15
    end
  end
  L:mark(y + 6)
end

--- Two-column grid of game cards; returns the y below it.
function Schedule:layoutGrid(L, games, y, W)
  local cw = (W - 20) // 2
  for i, g in ipairs(games) do
    local col = (i - 1) % 2
    local x = 6 + col * (cw + 8)
    local gy = y + ((i - 1) // 2) * 62
    local live = g.status == "live"
    -- card
    gfx.drawRect(x, gy, cw, 56)
    if live then gfx.drawRect(x + 1, gy + 1, cw - 2, 54) end
    local sc = g.score
    for k, side in ipairs({ "away", "home" }) do
      local t = g[side]
      local ry = gy + 4 + (k - 1) * 15
      local lx = x + 6
      if Logos.draw(t, lx, ry - 2, 16) then lx += 18 end
      Text.draw(t.abbr, lx, ry, UI.fonts.bold)
      Text.draw(Text.ellipsize(t.name, UI.fonts.body, cw - 104), lx + 34, ry, UI.fonts.body)
      if sc then
        local mine = sc[side] or 0
        local other = sc[side == "home" and "away" or "home"] or 0
        local f = (g.status == "final" and mine > other) and UI.fonts.head or UI.fonts.bold
        Text.draw(tostring(mine), x + cw - 8, ry - 1, f, nil, "right")
      else
        Text.draw(t.record or "", x + cw - 8, ry, UI.fonts.body, nil, "right")
      end
    end
    gfx.drawLine(x + 4, gy + 35, x + cw - 5, gy + 35)
    local st = statusLabel(g)
    if live then
      L:live(x + 4, gy + 37, cw - 8, 15, function(_, lx, ly, f)
        gfx.fillRect(lx, ly, 44, 14)
        if (f // 15) % 2 == 0 then gfx.setColor(gfx.kColorWhite) gfx.fillCircleAtPoint(lx + 6, ly + 7, 2) gfx.setColor(gfx.kColorBlack) end
        Text.draw("LIVE", lx + 12, ly + 1, UI.fonts.bold, "white")
        Text.draw(g.score and g.score.inning or "", lx + 50, ly + 1, UI.fonts.bold)
      end)
    else
      Text.draw(g.exhibition and (st .. " EXH") or st, x + 6, gy + 39, UI.fonts.bold)
    end
    local extra = g.myBet and ("\u{2605} " .. Fmt.money(g.myBet.amount) .. " on " .. (g.myBet.side == "home" and g.home.abbr or g.away.abbr)) or (g.probables and (g.probables.away.name:match("(%S+)$") .. " v " .. g.probables.home.name:match("(%S+)$")) or "")
    Text.draw(Text.ellipsize(extra, UI.fonts.body, cw - 80), x + cw - 6, gy + 39, UI.fonts.body, nil, "right")
    local hint = live and "Watch live in BallCast 3D" or (g.status == "final" and "Final: replay & box score" or ("First pitch " .. st .. " \u{2022} " .. (g.park or "")))
    L:link(x, gy, cw, 56, function()
      Nav.game(g.id)
    end, { id = "g:" .. g.id, hint = hint })
  end
  return y + ((#games + 1) // 2) * 62 + 6
end

-- The Game Hub: one page per game, for every status. Scheduled: probables, umpire, park,
-- pool, bulletins about either club, your bet and your job, and the verbs (bet either side,
-- order a job, watch). Live/final: the score up top, Watch first, then the box score.

local Game_ = Page.define({ canvasH = 900 })
Sites.Game = Game_

function Game_:url() return "http://www.continentalleague.org/game/" .. (self.args.id or "") .. ".html" end
function Game_:sources()
  local src = { g = "/games/" .. self.args.id, bulletins = { "/bulletins", optional = true }, ops = { "/ops", optional = true } }
  -- the probables' fan pages give the one-line "drama" under each (one batch with the rest)
  local slate = Game.slate
  for _, sg in ipairs(slate and slate.games or {}) do
    if sg.id == self.args.id and sg.status == "scheduled" and sg.probables then
      src.pa = { "/people/" .. sg.probables.away.id, optional = true }
      src.ph = { "/people/" .. sg.probables.home.id, optional = true }
    end
  end
  return src
end

function Game_:onResult(r)
  if r == "placed" then self:reload(true) end
end

function Game_:initialFocus()
  local want = self.data.g and self.data.g.status == "scheduled" and "bet:away" or "watch"
  for i, l in ipairs(self.links) do if l.id == want then return i end end
  return 1
end

function Game_:statusText()
  return "Every game, one page: bet it, rig it, watch it."
end

--- One line about a person from their fan page (when we have it): drama, else traits + mood.
local function dramaLine(pg)
  if type(pg) ~= "table" then return nil end
  if pg.drama and pg.drama[1] then return pg.drama[1] end
  local p = pg.person or {}
  local t = {}
  for i = 1, math.min(2, #(p.traits or {})) do t[#t + 1] = (p.traits[i]:lower():gsub("^%l", string.upper)) end
  local s = table.concat(t, ", ")
  if p.mood and p.mood ~= "" then s = (s ~= "" and (s .. ". ") or "") .. "Mood: " .. p.mood end
  return s ~= "" and s or nil
end

--- League bulletins (card redemptions) that touch either club, newest first.
local function bulletinsFor(g, list)
  local out = {}
  for _, b in ipairs(list or {}) do
    local t = b.team and b.team.id
    if t and (t == g.home.id or t == g.away.id) then
      local live = b.kind == "retire" or not b.untilDay or b.untilDay >= (g.day or 0)
      if live then out[#out + 1] = b end
    end
  end
  return out
end

--- Your jobs on this game.
local function jobsFor(g, ops)
  local out = {}
  for _, op in ipairs(ops or {}) do
    if op.game and op.game.id == g.id and op.status ~= "cancelled" then out[#out + 1] = op end
  end
  return out
end

local function shortName(t) return t and t.name or "?" end

function Game_:layoutHeader(L, g, W)
  gfx.fillRect(0, 0, W, 17)
  Text.draw(Text.ellipsize((g.away.name .. " @ " .. g.home.name):upper(), UI.fonts.bold, 240), 6, 2, UI.fonts.bold, "white")
  if g.status == "scheduled" then
    local fp = g.firstPitchAt or 0
    L:live(W - 130, 2, 126, 13, function(_, x, y)
      local left = fp - Api.now()
      Text.draw(left > 0 and ("first pitch " .. Fmt.countdown(left)) or "first pitch: now", x + 124, y, UI.fonts.bold, "white", "right")
    end)
  else
    local sc = g.score or {}
    local st = g.status == "live" and ("LIVE " .. Fmt.inning(sc.inning)) or "FINAL"
    Text.draw(st .. "  " .. g.away.abbr .. " " .. (sc.away or 0) .. "  " .. g.home.abbr .. " " .. (sc.home or 0), W - 6, 2, UI.fonts.bold, "white", "right")
  end
  L:mark(17)
end

function Game_:layoutMatchup(L, g, W, y)
  local colW = W // 2
  local pays = g.pool and g.pool.pays or {}
  for i, side in ipairs({ "away", "home" }) do
    local t = g[side]
    local x = 6 + (i - 1) * colW
    local p = g.probables and g.probables[side]
    if p then
      L:face(p.face, x + 1, y + 1, 48, function() Nav.person(p.id) end, { id = "face:" .. side, hint = "Fan page: " .. p.name })
    else
      Draw.silhouette(x + 1, y + 1, 48, 60)
    end
    local tx = x + 56
    local tw = colW - 62
    Text.draw(Text.ellipsize(t.name .. " " .. (t.record or ""), UI.fonts.head, tw), tx, y, UI.fonts.head)
    local ty = y + 16
    if p then
      L:textLink(Text.ellipsize("SP " .. (p.name:match("(%S+)$") or p.name) .. " " .. (p.line or ""), UI.fonts.body, tw), tx, ty,
        function() Nav.person(p.id) end, { id = "sp:" .. side, hint = "Fan page: " .. p.name })
    end
    ty += 14
    if g.status == "scheduled" then
      Text.draw("pays " .. ((pays[side] or 0) > 0 and (Fmt.pays(pays[side]) .. "x") or "--"), tx, ty, UI.fonts.bold)
    end
    ty += 14
    local drama = dramaLine(self.data[side == "away" and "pa" or "ph"])
    if drama then Text.block(drama, tx, ty, tw, UI.fonts.body, nil, 2) end
  end
  return y + 66
end

function Game_:layout(L)
  local W = 392
  local g = self.data.g or {}
  if not g.home then L:text("No such game.", 8, 8) return end
  self:layoutHeader(L, g, W)
  local y = 21
  if g.status == "scheduled" then
    y = self:layoutMatchup(L, g, W, y)
  else
    local tag = g.exhibition and "EXHIBITION \u{2022} " or (g.circuit == "enhanced" and "ENHANCED LEAGUE \u{2022} " or "")
    Text.draw(Text.ellipsize(tag .. g.away.city .. " " .. g.away.name .. " @ " .. g.home.city .. " " .. g.home.name .. " \u{2022} Day " .. (g.day or "?"), UI.fonts.body, W - 16), 6, y, UI.fonts.body)
    y += 15
  end
  -- the facts: umpire, park, pool
  local fx = 48
  if g.umpire then
    Text.draw("UMP", 6, y, UI.fonts.bold)
    L:textLink(g.umpire.name, fx, y, function() Nav.person(g.umpire.id) end, { id = "ump", hint = "Fan page: " .. g.umpire.name .. " (umpires have moods too)" })
    y += 14
  end
  Text.draw("PARK", 6, y, UI.fonts.bold)
  Text.draw(Text.ellipsize((g.park or "?") .. " \u{2022} " .. (g.weather or ""), UI.fonts.body, W - fx - 6), fx, y, UI.fonts.body)
  y += 14
  if g.pool then
    local p = g.pool
    Text.draw("POOL", 6, y, UI.fonts.bold)
    Text.draw(Fmt.money((p.home or 0) + (p.away or 0)) .. "  (" .. shortName(g.away) .. " " .. Fmt.money(p.away or 0) .. " / " .. shortName(g.home) .. " " .. Fmt.money(p.home or 0) .. ")", fx, y, UI.fonts.body)
    y += 14
  end
  -- bulletins: a card redemption on either club changes the game
  local bl = bulletinsFor(g, self.data.bulletins and self.data.bulletins.bulletins)
  if bl[1] then
    local b = bl[1]
    y += 2
    local txt = "BULLETIN: " .. (b.text or "") .. (b.redeemer and (" (redeemed by " .. b.redeemer .. ")") or "")
    gfx.fillRect(4, y, W - 8, 15)
    Text.draw(Text.ellipsize(txt, UI.fonts.bold, W - 18), 9, y + 1, UI.fonts.bold, "white")
    L:link(4, y, W - 8, 15, function() if b.storyId then Nav.story(b.storyId) end end, { id = "bulletin", style = "invert", hint = (#bl > 1 and (#bl .. " bulletins on these clubs. ") or "") .. "Read the bulletin" })
    y += 18
  end
  -- you: your bet and your jobs on this game
  local jobs = jobsFor(g, self.data.ops and self.data.ops.ops)
  local parts = {}
  if g.myBet then parts[#parts + 1] = Fmt.money(g.myBet.amount) .. " on " .. shortName(g[g.myBet.side]) end
  for _, op in ipairs(jobs) do parts[#parts + 1] = "job: " .. op.name .. (op.status ~= "planned" and (" (" .. op.status .. ")") or "") end
  Text.draw("YOU:", 6, y, UI.fonts.bold)
  Text.draw(Text.ellipsize(#parts > 0 and table.concat(parts, " \u{2022} ") or "nothing on this one yet", UI.fonts.body, W - 50), 44, y, UI.fonts.body)
  y += 17
  -- the verbs
  local bx = 6
  local function btn(label, id, action, hint, disabled)
    local w = UI.fonts.bold:getTextWidth(label) + 16
    if disabled then
      Draw.button(bx, y, w, 18, label, "disabled")
      L:mark(y + 19)
    else
      L:button(label, bx, y, w, 18, action, { id = id, hint = hint })
    end
    bx += w + 8
  end
  if g.status == "scheduled" then
    for _, side in ipairs({ "away", "home" }) do
      local t = g[side]
      btn("Bet " .. t.name, "bet:" .. side, function() Nav.bet(g.id, side, g) end,
        "Bet on the " .. t.city .. " " .. t.name .. " \u{2022} pays " .. Fmt.pays(g.pool and g.pool.pays and g.pool.pays[side]) .. " per $1")
    end
    local target = g.myBet and (g.myBet.side == "home" and g.away or g.home) or nil
    btn("Order a job", "job", function() Nav.job({ gameId = g.id, targetId = target and target.id }) end,
      "Plan a crew job on this game" .. (target and (" (against the " .. target.name .. ")") or ""))
    btn("Watch", "watch", nil, nil, true)
  else
    btn(g.status == "live" and "Watch LIVE" or "Watch replay", "watch", function() Nav.watch(g.id) end, BallCast and "BallCast 3D" or "BallCast 3D (not installed in this build)")
    if g.storyId then btn("Read the story", "story", function() Nav.story(g.storyId) end, "SportsWire recap") end
  end
  y += 26
  -- line score
  if g.line then
    local n = math.max(9, #g.line.home, #g.line.away)
    local cx0, cw = 50, 20
    Text.draw("", 8, y, UI.fonts.bold)
    for i = 1, n do Text.draw(tostring(i), cx0 + (i - 1) * cw + 10, y, UI.fonts.bold, nil, "center") end
    local rx = cx0 + n * cw + 8
    Text.draw("R", rx + 8, y, UI.fonts.bold, nil, "center")
    Text.draw("H", rx + 30, y, UI.fonts.bold, nil, "center")
    Text.draw("E", rx + 52, y, UI.fonts.bold, nil, "center")
    gfx.drawLine(8, y + 13, rx + 62, y + 13)
    y += 16
    for _, side in ipairs({ "away", "home" }) do
      Text.draw(g[side].abbr, 8, y, UI.fonts.bold)
      for i = 1, n do
        local v = g.line[side][i]
        Text.draw(v == nil and "" or (v == json.null and "x" or tostring(v)), cx0 + (i - 1) * cw + 10, y, UI.fonts.body, nil, "center")
      end
      local b = g.box and g.box[side] or {}
      Text.draw(tostring(b.r or (g.score and g.score[side]) or ""), rx + 8, y, UI.fonts.bold, nil, "center")
      Text.draw(tostring(b.h or ""), rx + 30, y, UI.fonts.body, nil, "center")
      Text.draw(tostring(b.e or ""), rx + 52, y, UI.fonts.body, nil, "center")
      y += 14
    end
    y += 6
  end
  if g.decisions then
    local d = g.decisions
    local parts = { { "W", d.w }, { "L", d.l }, { "S", d.s } }
    local x = 8
    for _, pr in ipairs(parts) do
      if pr[2] then
        Text.draw(pr[1] .. ":", x, y, UI.fonts.bold)
        local w = L:textLink(pr[2].name, x + 16, y, function() Nav.person(pr[2].id) end, { id = "dec" .. pr[1], hint = "Fan page" })
        x += w + 28
      end
    end
    y += 16
  end
  -- box-score notes (powers used, Enhanced League and exhibitions)
  if g.notes and #g.notes > 0 then
    for _, n in ipairs(g.notes) do
      y += Text.block(n, 8, y, W - 16, UI.fonts.bold) + 2
    end
    y += 4
  end
  -- incidents
  if g.incidents and #g.incidents > 0 then
    gfx.fillRect(4, y, W - 8, 15)
    Text.draw("INCIDENTS", 9, y + 1, UI.fonts.bold, "white")
    y += 19
    for _, inc in ipairs(g.incidents) do
      y += Text.block("Inn. " .. inc.inning .. ": " .. inc.text, 8, y, W - 16, UI.fonts.body) + 2
    end
    y += 4
  end
  -- box
  if g.box then
    for _, side in ipairs({ "away", "home" }) do
      local b = g.box[side]
      gfx.fillRect(4, y, W - 8, 15)
      Text.draw(g[side].city:upper() .. " " .. g[side].name:upper(), 9, y + 1, UI.fonts.bold, "white")
      y += 18
      local cols = { 8, 190, 220, 250, 280, 310, 340, W - 8 }
      local heads = { "BATTING", "AB", "R", "H", "RBI", "BB", "K", "AVG" }
      for i, h in ipairs(heads) do
        if i == 1 then Text.draw(h, cols[1], y, UI.fonts.bold) elseif i == #heads then Text.draw(h, cols[i], y, UI.fonts.bold, nil, "right") else Text.draw(h, cols[i] + 10, y, UI.fonts.bold, nil, "center") end
      end
      y += 14
      for _, r in ipairs(b.bat or {}) do
        local nm = (r.p.pos and (r.p.pos .. " ") or "") .. r.p.name
        L:textLink(Text.ellipsize(nm, UI.fonts.body, 170), cols[1], y, function() Nav.person(r.p.id) end, { id = "bat:" .. side .. r.p.id, hint = "Fan page" })
        local vals = { r.ab, r.r, r.h, r.rbi, r.bb, r.k }
        for k, v in ipairs(vals) do Text.draw(tostring(v), cols[k + 1] + 10, y, UI.fonts.body, nil, "center") end
        Text.draw(r.avg or "", cols[8], y, UI.fonts.body, nil, "right")
        y += 14
      end
      y += 4
      local pc = { 8, 190, 220, 250, 280, 310, 340, W - 8 }
      local ph = { "PITCHING", "IP", "H", "R", "ER", "BB", "K", "PC" }
      for i, h in ipairs(ph) do
        if i == 1 then Text.draw(h, pc[1], y, UI.fonts.bold) elseif i == #ph then Text.draw(h, pc[i], y, UI.fonts.bold, nil, "right") else Text.draw(h, pc[i] + 10, y, UI.fonts.bold, nil, "center") end
      end
      y += 14
      for _, r in ipairs(b.pitch or {}) do
        L:textLink(Text.ellipsize(r.p.name, UI.fonts.body, 170), pc[1], y, function() Nav.person(r.p.id) end, { id = "pit:" .. side .. r.p.id, hint = "Fan page" })
        local vals = { r.ip, r.h, r.r, r.er, r.bb, r.k }
        for k, v in ipairs(vals) do Text.draw(tostring(v), pc[k + 1] + 10, y, UI.fonts.body, nil, "center") end
        Text.draw(tostring(r.pc or ""), pc[8], y, UI.fonts.body, nil, "right")
        y += 14
      end
      y += 8
    end
  end
  L:mark(y + 4)
end
