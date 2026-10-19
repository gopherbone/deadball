-- SportsWire Online: front page (paginated) and story pages with comments.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local News = Page.define({ canvasH = 520 })
Sites.News = News

function News:url()
  local d = Game.clock and Game.clock.day or 0
  return "http://www.sportswire.net/news/day" .. d .. (self.args.cursor and ("/p" .. (self.args.page or 2)) or "") .. ".html"
end

function News:sources()
  local s = { news = "/news" .. (self.args.cursor and ("?cursor=" .. self.args.cursor) or ""), standings = "/standings?level=ML" }
  return s
end

--- First face of a story summary or story (servers send `face` or `faceIds`).
function News.faceOf(s)
  if s.face then return s.face end
  if s.faceIds and s.faceIds[1] then return s.faceIds[1] end
  return nil
end

function News:initialFocus()
  for i, l in ipairs(self.links) do if l.id == "lead" then return i end end
  return 1
end

function News:init(args)
  self.page = args.page or 1
  self.poll = 0
end

--- Remember the newest story read about (the desktop's ★N badge counts the ones after it).
function News:loaded()
  local top = self.page == 1 and self.data.news and self.data.news.stories and self.data.news.stories[1]
  if top and Game.settings.seenNews ~= top.id then
    Game.settings.seenNews = top.id
    playdate.datastore.write(Game.settings, "settings")
  end
end

--- Masthead shared by the front page and story pages.
function News.masthead(L, W, compact)
  local mast = UI.image("images/ui/masthead-sportswire")
  if mast then
    local mw, mh = mast:getSize()
    mast:draw(0, 0)
    local c = Game.clock or {}
    Text.draw("Season " .. (c.season or "?") .. " \u{2022} Day " .. (c.day or "?"), W - 6, 2, UI.fonts.body, nil, "right")
    Text.draw("Updated " .. Fmt.clock(), W - 6, 15, UI.fonts.body, nil, "right")
    gfx.setColor(gfx.kColorBlack)
    gfx.drawLine(0, mh, W, mh)
    gfx.drawLine(0, mh + 2, W, mh + 2)
    L:mark(mh + 3)
    return mh + 7
  end
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(0, 0, W, 26)
  Text.draw("SportsWire", 6, 1, UI.fonts.serif, "white")
  Text.draw("ONLINE", 6 + UI.fonts.serif:getTextWidth("SportsWire") + 8, 8, UI.fonts.bold, "white")
  local c = Game.clock or {}
  Text.draw("Season " .. (c.season or "?") .. " \u{2022} Day " .. (c.day or "?"), W - 6, 1, UI.fonts.body, "white", "right")
  Text.draw("Updated " .. Fmt.clock(), W - 6, 12, UI.fonts.body, "white", "right")
  L:mark(26)
  return 30
end

function News:layout(L)
  local W = 392
  local y = News.masthead(L, W)
  local stories = self.data.news and self.data.news.stories or {}
  local lead = stories[1]
  local colW = 238
  local rx = colW + 8
  local ly = y
  if lead and self.page == 1 then
    local h = L:para(lead.headline:upper(), 6, ly, colW - 6, UI.fonts.head, 3)
    ly += h + 3
    local fx, fy = 7, ly + 1
    local leadFace = News.faceOf(lead)
    local hint = "Read: " .. lead.headline
    if lead.photo and Archive.get(lead.photo, 160) then
      -- archive photo across the column, dek underneath
      local pw, ph = Archive.draw(lead.photo, fx, fy, 160)
      L:link(fx - 1, fy - 1, pw + 2, ph + 2, function() Nav.story(lead.id) end, { id = "leadphoto", hint = hint })
      if lead.photoCaption then Text.block(lead.photoCaption, fx + pw + 6, fy, colW - pw - 14, UI.fonts.body, nil, 7) end
      ly = fy + ph + 4
      ly += L:para(lead.dek or "", 6, ly, colW - 8, UI.fonts.body, 3) + 2
      L:textLink("Full story \u{25b6}", 6, ly, function() Nav.story(lead.id) end, { id = "lead", hint = hint, font = UI.fonts.bold })
      ly += 18
    elseif leadFace and Faces.get(leadFace, 96) then
      L:face(leadFace, fx, fy, 96, function() Nav.story(lead.id) end, { id = "leadphoto", hint = hint, style = "ring" })
      local tx = fx + 104
      local th = Text.block(lead.dek or "", tx, fy, colW - tx - 2, UI.fonts.body, nil, 7)
      L:textLink("Full story \u{25b6}", tx, fy + th + 4, function() Nav.story(lead.id) end, { id = "lead", hint = hint, font = UI.fonts.bold })
      ly = fy + 124
    else
      -- typographic lead: big serif dek, drop rule, no image box
      gfx.fillRect(6, ly, colW - 10, 2)
      ly += 6
      ly += L:para(lead.dek or "", 6, ly, colW - 10, UI.fonts.serif, 4) + 6
      L:textLink("Full story \u{25b6}", 6, ly, function() Nav.story(lead.id) end, { id = "lead", hint = hint, font = UI.fonts.bold })
      ly += 18
    end
  end
  -- also tonight
  gfx.fillRect(4, ly, colW - 4, 14)
  Text.draw(self.page == 1 and "ALSO TONIGHT" or ("MORE NEWS \u{2022} PAGE " .. self.page), 8, ly + 1, UI.fonts.bold, "white")
  ly += 17
  for i = (self.page == 1 and 2 or 1), #stories do
    local st = stories[i]
    local thumb = st.photo and Archive.get(st.photo, 48)
    local tx = 16
    local textW = colW - 22
    if thumb then
      Archive.draw(st.photo, 7, ly + 1, 48)
      tx = 60
      textW = colW - 62
    else
      Text.draw("\u{2022}", 7, ly, UI.fonts.body)
    end
    local top = ly
    local lines = Text.wrap(st.headline, UI.fonts.body, textW)
    local kind = (st.kind or ""):upper()
    for j, line in ipairs(lines) do
      if j > 2 then break end
      L:textLink(line, tx, ly, function() Nav.story(st.id) end, { id = "story:" .. st.id .. ":" .. j, hint = kind .. ": " .. (st.dek or st.headline) })
      ly += 14
    end
    if (st.comments or 0) > 0 then
      Text.draw(st.comments .. " comment" .. (st.comments > 1 and "s" or ""), tx, ly, UI.fonts.body)
      ly += 13
    end
    if thumb then ly = math.max(ly, top + 40) end
    ly += 2
  end
  ly += 6
  -- pagination
  local px = 6
  if self.page > 1 then
    local w = L:textLink("<< Newer", px, ly, function() self:goBack() end, { id = "prev", font = UI.fonts.bold, hint = "Back to page " .. (self.page - 1) })
    px += w + 14
  end
  Text.draw("Page " .. self.page, px, ly, UI.fonts.body)
  px += 50
  local nxt = self.data.news and self.data.news.next
  if nxt then
    L:textLink("Older >>", px, ly, function() News.open({ cursor = nxt, page = self.page + 1 }) end, { id = "next", font = UI.fonts.bold, hint = "More stories" })
  end
  ly += 20
  -- right column: standings box
  local ry = y
  local boxW = W - rx - 2
  local rows = self.data.standings and self.data.standings.rows or {}
  local bh = 18 + math.min(#rows, 8) * 13 + 4
  gfx.drawRect(rx, ry, boxW, bh)
  Text.draw("STANDINGS", rx + 4, ry + 2, UI.fonts.bold)
  L:link(rx, ry, boxW, 15, function() Sites.Standings.open() end, { id = "standings", hint = "Full standings", style = "invert" })
  local sy = ry + 17
  for i, r in ipairs(rows) do
    if i > 8 then break end
    local t = r.team or { name = r.teamId }
    Text.draw(Text.ellipsize(t.name or r.teamId, UI.fonts.body, boxW - 46), rx + 4, sy, UI.fonts.body)
    Text.draw(r.w .. "-" .. r.l, rx + boxW - 4, sy, UI.fonts.body, nil, "right")
    sy += 13
  end
  ry += bh + 6
  -- poll
  local opts = { "Gamblers", "The Friars", "Raccoons" }
  local ph = 18 + #opts * 15 + 24
  gfx.drawRect(rx, ry, boxW, ph)
  gfx.drawRect(rx + 2, ry + 2, boxW - 4, ph - 4)
  Text.block("POLL: Who is behind it all?", rx + 6, ry + 4, boxW - 12, UI.fonts.bold, nil, 2)
  local oy = ry + 30
  for i, o in ipairs(opts) do
    Draw.radio(rx + 7, oy + 2, self.poll == i)
    Text.draw(o, rx + 20, oy, UI.fonts.body)
    L:link(rx + 4, oy - 1, boxW - 10, 14, function()
      self.poll = i
      self:render(true)
    end, { id = "poll" .. i, hint = "Vote: " .. o, style = "invert" })
    oy += 15
  end
  if self.voted then
    Text.draw(self.voted, rx + 6, oy + 3, UI.fonts.body)
  else
    L:button("Vote", rx + 6, oy + 1, 46, 15, function()
      if self.poll == 0 then Toast.show("Pick one first.", "bad") return end
      self.voted = (40 + (self.poll * 17) % 50) .. "% agree with you"
      Sfx.coin()
      self:render(true)
    end, { id = "vote", font = UI.fonts.body })
  end
  ry += ph + 4
  L:mark(math.max(ly, ry))
end

function News:statusText() return "Document: Done." end

-- Story ----------------------------------------------------------------------------------

local Story = Page.define({ canvasH = 900 })
Sites.Story = Story

function Story:url()
  return "http://www.sportswire.net/news/" .. (self.args.id or "") .. ".html"
end

function Story:loaded()
  if self.jingled then return end   -- loaded() runs again when a saved copy is refreshed
  self.jingled = true
  local s = self.data.s and self.data.s.story
  local h = s and ((s.headline or "") .. " " .. (s.dek or "")):lower() or ""
  if h:find("raccoon") or h:find("clown") or h:find("circus") then
    Sfx.music("gladiators", { loop = false })
  elseif h:find("commissioner") then
    Sfx.music("hail_chief", { loop = false })
  elseif s and s.kind == "life" and (h:find("wed") or h:find("marr")) then
    Sfx.music("wedding_march", { loop = false })
  end
end

function Story:sources()
  return { s = "/news/" .. self.args.id }
end

function Story:onResult(r)
  if r and r ~= "placed" then self:reload(true) end
end

function Story:layout(L)
  local W = 392
  local y = News.masthead(L, W)
  local d = self.data.s or {}
  local s = d.story
  if not s then
    L:text("Story not found.", 8, y)
    return
  end
  Text.draw((s.kind or "news"):upper() .. "  \u{2022}  DAY " .. (s.day or "?"), 8, y, UI.fonts.bold)
  y += 15
  y += L:para(s.headline, 8, y, W - 16, UI.fonts.head, 4) + 2
  if s.dek and s.dek ~= "" then
    y += L:para(s.dek, 8, y, W - 16, UI.fonts.body, 4) + 2
  end
  Text.draw((s.dateline and (s.dateline .. "  \u{2022}  ") or "") .. "By SportsWire Staff", 8, y, UI.fonts.body)
  y += 14
  Draw.hr(8, y, W - 16)
  y += 6
  local body = s.body or {}
  local f = UI.fonts.body
  local lh = f:getHeight() + 1
  -- archive photo: full-width lead with caption
  if s.photo and Archive.get(s.photo, 400) then
    local img = Archive.get(s.photo, 160)
    local pw, ph = Archive.size(160)
    local px = (W - pw) // 2
    Archive.draw(s.photo, px, y + 1, 160)
    y += ph + 4
    if s.photoCaption then
      y += Text.block(s.photoCaption, px, y, pw, UI.fonts.body, nil, 3) + 4
    end
  elseif s.photo and Archive.get(s.photo, 160) then
    local pw, ph = Archive.draw(s.photo, (W - 160) // 2, y + 1, 160)
    y += ph + 4
    if s.photoCaption then y += Text.block(s.photoCaption, (W - 160) // 2, y, 160, UI.fonts.body, nil, 3) + 4 end
  end
  -- face photo floated left, body wraps beside it
  local fx = 9
  local photoBottom = y
  local textX, textW = 8, W - 16
  local face = News.faceOf(s)
  if face and not s.photo and Faces.get(face, 96) then
    Faces.draw(face, fx, y + 1, 96)
    local first = s.people and s.people[1]
    local cap = type(first) == "table" and first.name or ""
    if cap ~= "" then Text.block(cap, fx, y + 124, 96, UI.fonts.body, nil, 2) end
    photoBottom = y + 124 + (cap ~= "" and 26 or 0)
    textX, textW = fx + 106, W - fx - 106 - 8
  end
  for pi, para in ipairs(body) do
    local lines = Text.wrap(para, f, textW)
    local i = 1
    while i <= #lines do
      if textX > 8 and y >= photoBottom then
        local rest = table.concat(lines, " ", i)
        lines = Text.wrap(rest, f, W - 16)
        i = 1
        textX, textW = 8, W - 16
      end
      Text.draw(lines[i], textX, y, f)
      y += lh
      i += 1
    end
    y += 5
  end
  y = math.max(y, photoBottom) + 4
  L:mark(y)
  -- links: game, people, teams
  if s.gameId then
    L:button("Game page", 8, y, 80, 18, function() Nav.game(s.gameId) end, { id = "box", hint = "The game page: box score, pools, replay" })
    if BallCast and BallCast.scene then
      L:button("Watch replay", 96, y, 100, 18, function() Nav.watch(s.gameId) end, { id = "watch", hint = "Watch it in BallCast 3D" })
    end
    y += 26
  end
  if s.people and #s.people > 0 then
    Text.draw("IN THIS STORY:", 8, y, UI.fonts.bold)
    y += 15
    local x = 8
    for i, p in ipairs(s.people) do
      local id = type(p) == "table" and p.id or p
      local name = type(p) == "table" and p.name or nil
      local face = type(p) == "table" and p.face or (s.faceIds and s.faceIds[i])
      if name then
        local w = UI.fonts.body:getTextWidth(name) + 30
        if x + w > W - 8 then x = 8 y += 30 end
        Faces.draw(face, x + 1, y + 1, 24)
        L:link(x - 1, y - 1, 28, 28, function() Nav.person(id) end, { id = "pf:" .. id, hint = "Fan page: " .. name })
        L:textLink(name, x + 30, y + 6, function() Nav.person(id) end, { id = "p:" .. id, hint = "Fan page: " .. name })
        x += w + 10
      else
        if x + 30 > W - 8 then x = 8 y += 30 end
        Faces.draw(face, x + 1, y + 1, 24)
        L:link(x - 1, y - 1, 28, 28, function() Nav.person(id) end, { id = "pf:" .. id, hint = "Fan page" })
        x += 32
      end
    end
    y += 32
  end
  if s.teams and #s.teams > 0 then
    Text.draw("CLUBS:", 8, y, UI.fonts.bold)
    local x = 60
    for _, t in ipairs(s.teams) do
      local id = type(t) == "table" and t.id or t
      local label = type(t) == "table" and (t.city .. " " .. t.name) or t
      local w = L:textLink(label, x, y, function() Nav.team(id) end, { id = "t:" .. id, hint = "Org page: " .. label })
      x += w + 12
    end
    y += 16
  end
  y += 4
  -- comments
  gfx.fillRect(4, y, W - 8, 15)
  local n = d.comments and #d.comments or 0
  Text.draw("COMMENTS (" .. n .. ")", 9, y + 1, UI.fonts.bold, "white")
  y += 20
  y = Comments.layout(L, self, d.comments, 8, y, W - 16, { thread = "story:" .. s.id, title = "Comment on this story" })
  L:mark(y + 8)
end
