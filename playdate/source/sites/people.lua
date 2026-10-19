-- Player/person fan pages: photo bank, traits, ties, family tree, stats, guestbook,
-- visitor counter and a webring through the club roster.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Person = Page.define({ canvasH = 1200 })
Sites.Person = Person

local function slugName(n) return Fmt.slug((n or ""):match("(%S+)$") or n) end

function Person:url()
  local p = self.data.page and self.data.page.person
  local nick = p and Fmt.slug(p.nickname or p.name) or "fan"
  return "http://members.aol.net/~" .. nick .. "fan/" .. (p and slugName(p.name) or "page") .. ".htm"
end

function Person:sources() return { page = "/people/" .. self.args.id } end

function Person:init()
  self.photo = 1
end

function Person:onResult(r)
  if r and r ~= "placed" then self:reload(true) end
end

function Person:loaded()
  local pg = self.data.page
  local team = pg and pg.team
  if team and team.id and not self.webring then
    Api.get("/teams/" .. team.id, function(err, d)
      if d and d.roster then
        self.webring = d.roster
        if not self.loading then self:render(true) end
      end
    end)
  end
end

function Person:ringNeighbor(d)
  local roster = self.webring
  if not roster or #roster == 0 then return nil end
  local idx = 1
  for i, r in ipairs(roster) do if r.id == self.args.id then idx = i end end
  local n = ((idx - 1 + d) % #roster) + 1
  return roster[n]
end

local function famBox(L, p, x, y, w, label)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, 30)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, 30)
  Faces.draw(p.face, x + 3, y + 3, 24)
  Text.draw(Text.ellipsize(p.name, UI.fonts.body, w - 34), x + 31, y + 3, UI.fonts.body)
  if label then Text.draw(label, x + 31, y + 15, UI.fonts.body) end
  L:link(x, y, w, 30, function() Nav.person(p.id) end, { id = "fam:" .. p.id .. ":" .. x, hint = (label or "Family") .. ": " .. p.name })
end

function Person:layout(L)
  local W = 392
  local pg = self.data.page or {}
  local p = pg.person or { name = "?" }
  Draw.tile(0, 0, W, 3000, "weave")
  -- WordArt name
  local _, nh = Draw.wordart((p.nickname and p.nickname ~= "" and not p.name:find(p.nickname, 1, true)) and (p.name:upper()) or p.name:upper(), W // 2, 0, UI.fonts.slab)
  local y = nh + 2
  -- left column: photo + photo bank
  local lx = 5
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(lx - 3, y - 3, 108, 196)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(lx - 3, y - 3, 108, 196)
  local faces = pg.faces or { p.face }
  local cur = faces[self.photo] or p.face
  Faces.draw(cur, lx + 3, y + 3, 96)
  local by = y + 128
  Text.draw("PHOTO BANK (" .. #faces .. ")", lx + 1, by, UI.fonts.bold)
  by += 14
  for i, f in ipairs(faces) do
    if i > 3 then break end
    local tx = lx + 3 + (i - 1) * 32
    Faces.draw(f, tx, by, 24)
    if i == self.photo then
      gfx.drawRect(tx - 3, by - 3, 30, 30)
    end
    L:link(tx - 2, by - 2, 28, 28, function()
      self.photo = i
      self:render(true)
    end, { id = "photo" .. i, hint = "Photo " .. i .. " of " .. #faces })
  end
  by += 32
  -- right column: info box
  local rx = 118
  local rw = W - rx - 4
  local info = {}
  info[#info + 1] = p.pos or (p.status or "")
  if pg.team then info[#info + 1] = pg.team.city end
  local line = pg.stats and pg.stats[1] and pg.stats[1].line
  if line then info[#info + 1] = line:match("^[^,]+") end
  local boxY = y - 3
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(rx, boxY, rw, 120)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(rx, boxY, rw, 120)
  local iy = boxY + 4
  Text.draw(table.concat(info, " \u{2022} "), rx + 6, iy, UI.fonts.bold)
  iy += 14
  local sub = {}
  if p.nickname then sub[#sub + 1] = "\"" .. p.nickname .. "\"" end
  if p.age then sub[#sub + 1] = "age " .. p.age end
  if p.bats then sub[#sub + 1] = "B/T " .. p.bats .. "/" .. (p.throws or "?") end
  if p.mood then sub[#sub + 1] = "mood: " .. p.mood end
  Text.draw(Text.ellipsize(table.concat(sub, "  "), UI.fonts.body, rw - 12), rx + 6, iy, UI.fonts.body)
  iy += 14
  if pg.team then
    Text.draw("CLUB", rx + 6, iy, UI.fonts.bold)
    L:textLink(pg.team.city .. " " .. pg.team.name .. " (" .. Fmt.levelName(pg.team.level) .. ")", rx + 46, iy, function() Nav.team(pg.team.id) end, { id = "team", hint = "Org page" })
    iy += 15
  end
  Text.draw("TRAITS", rx + 6, iy + 1, UI.fonts.bold)
  local cx = rx + 50
  for _, t in ipairs(p.traits or {}) do
    local label = t:gsub("_", " ")
    local w = UI.fonts.bold:getTextWidth(label) + 6
    if cx + w > rx + rw - 4 then cx = rx + 50 iy += 15 end
    cx += Draw.chip(cx, iy, label) + 3
  end
  iy += 18
  Text.draw("TIES", rx + 6, iy, UI.fonts.bold)
  for _, tie in ipairs(pg.ties or {}) do
    local bx = rx + 50
    local v = tie.value or 0
    -- +/- box
    if v < 0 then
      gfx.fillRect(bx, iy + 1, 10, 10)
      gfx.setColor(gfx.kColorWhite)
      gfx.drawLine(bx + 2, iy + 3, bx + 7, iy + 8) gfx.drawLine(bx + 7, iy + 3, bx + 2, iy + 8)
      gfx.setColor(gfx.kColorBlack)
    else
      gfx.drawRect(bx, iy + 1, 10, 10)
      gfx.drawLine(bx + 5, iy + 3, bx + 5, iy + 8) gfx.drawLine(bx + 2, iy + 6, bx + 8, iy + 6)
    end
    local nm = Text.ellipsize(tie.who.name, UI.fonts.body, 110)
    L:textLink(nm, bx + 15, iy, function() Nav.person(tie.who.id) end, { id = "tie:" .. tie.who.id, hint = tie.who.name .. " (" .. (v > 0 and "+" or "") .. v .. "): " .. (tie.reason or "") })
    Text.draw(Text.ellipsize(tie.reason or "", UI.fonts.body, rw - 140), rx + rw - 6, iy, UI.fonts.body, nil, "right")
    iy += 14
    if iy > boxY + 112 then break end
  end
  -- visitor counter under the info box
  local vy = boxY + 126
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(rx, vy, rw, 64)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(rx, vy, rw, 64)
  Text.draw("You are visitor number", rx + 6, vy + 4, UI.fonts.body)
  local visitors = (pg.visitors or 0) + 1
  L:live(rx + 6, vy + 18, 80, 14, function(_, x, yy, f)
    local roll = (f < 20) and (f / 20) or 0
    Draw.hitCounter(x, yy, f < 20 and visitors - 1 or visitors, 6, roll)
  end)
  Text.draw("Best viewed in Diamond Navigator", rx + 6, vy + 36, UI.fonts.body)
  Text.draw("at 400x240. Sign my guestbook!!", rx + 6, vy + 48, UI.fonts.body)
  y = math.max(by, vy + 64) + 8
  -- drama
  local function section(title)
    gfx.fillRect(4, y, W - 8, 15)
    Text.draw(title, 9, y + 1, UI.fonts.bold, "white")
    y += 19
  end
  local function panel(h)
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(4, y - 4, W - 8, h + 6)
    gfx.setColor(gfx.kColorBlack)
  end
  if pg.drama and #pg.drama > 0 then
    section("LATEST DRAMA")
    panel(#pg.drama * 14)
    for _, dline in ipairs(pg.drama) do
      Text.draw("\u{2022} " .. dline, 10, y, UI.fonts.body)
      y += 14
    end
    y += 6
  end
  -- scouting
  if pg.scouting and #pg.scouting > 0 then
    section("SCOUTING REPORT")
    local rowsN = math.ceil(#pg.scouting / 3)
    panel(rowsN * 14)
    for i, s in ipairs(pg.scouting) do
      local col = (i - 1) % 3
      local row = (i - 1) // 3
      local sx = 10 + col * 128
      local sy = y + row * 14
      Text.draw(s.label, sx, sy, UI.fonts.body)
      Draw.pips(sx + 60, sy + 3, s.value or 0, 5)
    end
    y += rowsN * 14 + 6
  end
  -- family tree
  local fam = pg.family
  if fam then
    section("FAMILY TREE \u{2022} " .. (fam.house or ""):upper())
    local treeH = 30 + 18 + 30 + 18 + 30 + 20
    panel(treeH)
    if fam.houseNote then Text.draw("\"" .. fam.houseNote .. "\"", 10, y, UI.fonts.body) y += 16 end
    local bw = 120
    -- parents row
    local parents = fam.parents or {}
    local py = y
    local midX = W // 2
    if #parents > 0 then
      local total = #parents * bw + (#parents - 1) * 12
      local px = midX - total // 2
      for _, pp in ipairs(parents) do
        famBox(L, pp, px, py, bw, "parent")
        px += bw + 12
      end
      gfx.drawLine(midX, py + 30, midX, py + 48)
      if #parents > 1 then gfx.drawLine(midX - 6 - bw // 2, py + 30, midX - 6 - bw // 2, py + 38) gfx.drawLine(midX + 6 + bw // 2, py + 30, midX + 6 + bw // 2, py + 38) gfx.drawLine(midX - 6 - bw // 2, py + 38, midX + 6 + bw // 2, py + 38) end
      py += 48
    end
    -- self + spouse row
    local sx = midX - bw // 2
    if fam.spouse then sx = midX - bw - 10 end
    gfx.setLineWidth(2)
    gfx.drawRect(sx - 1, py - 1, bw + 2, 32)
    gfx.setLineWidth(1)
    Faces.draw(p.face, sx + 3, py + 3, 24)
    Text.draw(Text.ellipsize(p.name, UI.fonts.bold, bw - 34), sx + 31, py + 3, UI.fonts.bold)
    Text.draw("(this page)", sx + 31, py + 15, UI.fonts.body)
    if fam.spouse then
      gfx.drawLine(sx + bw, py + 13, sx + bw + 20, py + 13)
      gfx.drawLine(sx + bw, py + 17, sx + bw + 20, py + 17)
      famBox(L, fam.spouse, sx + bw + 20, py, bw, "spouse")
    end
    local kids = fam.children or {}
    if #kids > 0 then
      local kx0 = sx + bw // 2
      gfx.drawLine(kx0, py + 30, kx0, py + 40)
      local kw = math.min(bw, (W - 20 - (#kids - 1) * 8) // #kids)
      local total = #kids * kw + (#kids - 1) * 8
      local kx = midX - total // 2
      gfx.drawLine(math.min(kx0, kx + kw // 2), py + 40, math.max(kx0, kx + total - kw // 2), py + 40)
      for _, k in ipairs(kids) do
        gfx.drawLine(kx + kw // 2, py + 40, kx + kw // 2, py + 48)
        famBox(L, k, kx, py + 48, kw, "child")
        kx += kw + 8
      end
      py += 48
    else
      Text.draw("No children (that we know of).", midX, py + 36, UI.fonts.body, nil, "center")
      py += 18
    end
    y = py + 38
  end
  -- stats
  if pg.stats and #pg.stats > 0 then
    section("STATS")
    panel((#pg.stats + 1) * 13)
    Text.draw("YEAR", 10, y, UI.fonts.bold)
    Text.draw("CLUB", 52, y, UI.fonts.bold)
    Text.draw("LINE", 110, y, UI.fonts.bold)
    y += 13
    for i, s in ipairs(pg.stats) do
      if i % 2 == 0 then
        gfx.setPattern(UI.pat.lighter)
        gfx.fillRect(6, y - 1, W - 12, 13)
        gfx.setColor(gfx.kColorBlack)
      end
      Text.draw("S" .. s.season, 10, y, UI.fonts.body)
      Text.draw(s.team or "", 52, y, UI.fonts.body)
      Text.draw(Text.ellipsize(s.line or "", UI.fonts.body, W - 124), 110, y, UI.fonts.body)
      y += 13
    end
    y += 6
  end
  if pg.notes and pg.notes ~= "" then
    section("WEBMASTER'S NOTES")
    local h = Text.wrap(pg.notes, UI.fonts.body, W - 20)
    panel(#h * 14)
    y += L:para(pg.notes, 10, y, W - 20, UI.fonts.body) + 8
  end
  -- guestbook
  section("GUESTBOOK")
  local gbStart = y
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(4, y - 4, W - 8, 2000)
  gfx.setColor(gfx.kColorBlack)
  y = Comments.layout(L, self, pg.guestbook, 10, y, W - 20, { thread = "person:" .. (p.id or self.args.id), title = "Sign the Guestbook", postLabel = "Sign the guestbook", emptyText = "Nobody has signed yet. Be the first!" })
  y += 6
  -- webring
  Draw.tile(0, y, W, 60, "weave")
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(40, y, W - 80, 20)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(40, y, W - 80, 20)
  local prev, nxt = self:ringNeighbor(-1), self:ringNeighbor(1)
  local label = "CONTINENTAL LEAGUE WEBRING"
  Text.draw(label, W // 2, y + 4, UI.fonts.bold, nil, "center")
  if prev then
    L:textLink("<< prev", 46, y + 4, function() Person.replace({ id = prev.id }) end, { id = "ringprev", hint = "Webring: " .. prev.name })
  end
  if nxt then
    L:textLink("next >>", W - 88, y + 4, function() Person.replace({ id = nxt.id }) end, { id = "ringnext", hint = "Webring: " .. nxt.name })
  end
  y += 28
  L:mark(y)
end
