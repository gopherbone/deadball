-- Club org pages (owner/faction, farm chain, roster, feuds & friends, moves) and the
-- club directory.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Team = Page.define({ canvasH = 900 })
Sites.Team = Team

function Team:url()
  return "http://www.continentalleague.org/clubs/" .. Fmt.slug(self.args.id) .. "/org.html"
end

function Team:sources() return { t = "/teams/" .. self.args.id, thread = { "/threads/team:" .. self.args.id, optional = true } } end

function Team:onResult(r)
  if r and r ~= "placed" then self:reload(true) end
end

local LEVEL_ORDER <const> = { ML = 1, AA = 2, B = 3, D = 4 }

function Team:layout(L)
  local W = 392
  local d = self.data.t or {}
  local team = d.team or { name = self.args.id, city = "" }
  local owner = d.owner or {}
  -- page frame
  gfx.drawRect(1, 1, W - 2, 3000)
  local title = "~*~ " .. (owner.faction or (team.city .. " " .. team.name)):upper() .. " ~*~"
  local tf = UI.fonts.head
  if tf:getTextWidth(title) > W - 12 then title = (owner.faction or team.name):upper() end
  Text.draw(Text.ellipsize(title, tf, W - 80), W // 2, 4, tf, nil, "center")
  Logos.draw(team, 4, 3, 16)
  Logos.draw(team, W - 20, 3, 16)
  gfx.drawLine(4, 21, W - 5, 21)
  local y = 26
  local lw = 200
  -- owner
  local leader = owner.leader
  if leader then
    L:face(leader.face, 8, y + 1, 48, function() Nav.person(leader.id) end, { id = "owner", hint = "Fan page: " .. leader.name })
    L:textLink(leader.name, 64, y, function() Nav.person(leader.id) end, { id = "ownername", font = UI.fonts.bold, hint = "Fan page: " .. leader.name })
    Text.draw(Text.ellipsize("owner \u{2022} " .. (team.name or ""), UI.fonts.body, lw - 66), 64, y + 14, UI.fonts.body)
    local wants = owner.wants or {}
    local wy = y + 28
    if #wants > 0 then
      local h = Text.block("Wants: " .. table.concat(wants, ", ") .. ".", 64, wy, lw - 64, UI.fonts.body, nil, 3)
      wy += h
    end
    y = math.max(y + 64, wy + 4)
  end
  -- farm system
  Text.draw("FARM SYSTEM", 8, y, UI.fonts.bold)
  y += 15
  local chain = d.chain or {}
  table.sort(chain, function(a, b) return (LEVEL_ORDER[a.level] or 9) < (LEVEL_ORDER[b.level] or 9) end)
  for i, c in ipairs(chain) do
    local indent = 8 + (i - 1) * 8
    if i > 1 then
      gfx.drawLine(indent - 4, y - 7, indent - 4, y + 5)
      gfx.drawLine(indent - 4, y + 5, indent - 1, y + 5)
    end
    local name = c.city .. " " .. c.name
    if Logos.draw(c, indent, y - 1, 16) then indent += 18 end
    local nm = Text.ellipsize(name, i == 1 and UI.fonts.bold or UI.fonts.body, 122 - (i - 1) * 8 - 18)
    if c.id == team.id then
      Text.draw(nm, indent, y, UI.fonts.bold)
    else
      L:textLink(nm, indent, y, function() Nav.team(c.id) end, { id = "chain:" .. c.id, hint = Fmt.levelName(c.level) .. " \u{2022} " .. (c.record or "") })
    end
    Text.draw(c.level == "ML" and "Continental" or ("Class " .. c.level), lw - 4, y, UI.fonts.body, nil, "right")
    y += 14
  end
  y += 6
  -- recent moves
  Text.draw("RECENT MOVES", 8, y, UI.fonts.bold)
  y += 14
  for i, m in ipairs(d.moves or {}) do
    if i > 6 then break end
    local h = Text.block("D" .. m.day .. ": " .. m.text, 8, y, lw - 10, UI.fonts.body, nil, 2)
    y += h + 1
  end
  local leftBottom = y
  -- right column: feuds & friends
  local rx = lw + 8
  local rw = W - rx - 6
  gfx.drawLine(rx - 4, 24, rx - 4, leftBottom)
  local ry = 26
  Text.draw("FEUDS & FRIENDS", rx, ry, UI.fonts.head)
  ry += 18
  for _, r in ipairs(d.relations or {}) do
    local h = Text.block(r.name, rx, ry, rw - 54, UI.fonts.body, nil, 1)
    Draw.relBar(rx + rw - 52, ry + 2, 52, r.value)
    Text.block(r.reason or "", rx + 4, ry + 12, rw - 58, UI.fonts.body, nil, 1)
    ry += 28
  end
  Text.draw("hate", rx + rw - 52, ry, UI.fonts.body)
  Text.draw("love", rx + rw, ry, UI.fonts.body, nil, "right")
  ry += 18
  -- manager & park
  if d.manager then
    Text.draw("MANAGER", rx, ry, UI.fonts.bold)
    L:textLink(d.manager.name, rx + 62, ry, function() Nav.person(d.manager.id) end, { id = "mgr", hint = "Fan page: " .. d.manager.name })
    ry += 15
  end
  if d.park then
    Text.draw("PARK", rx, ry, UI.fonts.bold)
    Text.draw(Text.ellipsize(d.park, UI.fonts.body, rw - 62), rx + 62, ry, UI.fonts.body)
    ry += 15
  end
  y = math.max(leftBottom, ry) + 6
  -- roster
  gfx.fillRect(4, y, W - 8, 15)
  Text.draw("ROSTER (" .. #(d.roster or {}) .. ")", 9, y + 1, UI.fonts.bold, "white")
  y += 19
  local colW = (W - 16) // 2
  for i, p in ipairs(d.roster or {}) do
    local col = (i - 1) % 2
    local x = 8 + col * (colW + 4)
    local py = y + ((i - 1) // 2) * 15
    Text.draw(p.pos or "", x, py, UI.fonts.bold)
    local nm = Text.ellipsize(p.name, UI.fonts.body, colW - 96)
    L:textLink(nm, x + 22, py, function() Nav.person(p.id) end, { id = "r:" .. p.id, hint = p.name .. " \u{2022} " .. (p.line or "") })
    Text.draw(Text.ellipsize(p.line or "", UI.fonts.body, 70), x + colW - 2, py, UI.fonts.body, nil, "right")
  end
  y += ((#(d.roster or {}) + 1) // 2) * 15 + 8
  -- fan board
  gfx.fillRect(4, y, W - 8, 15)
  Text.draw("FAN BOARD", 9, y + 1, UI.fonts.bold, "white")
  y += 20
  local comments = self.data.thread and self.data.thread.comments or {}
  y = Comments.layout(L, self, comments, 8, y, W - 16, { thread = "team:" .. self.args.id, title = "Fan Board", max = 8 })
  L:mark(y + 8)
end

-- Club directory ------------------------------------------------------------------------

local Teams = Page.define({ canvasH = 400 })
Sites.Teams = Teams

function Teams:url() return "http://www.continentalleague.org/clubs/index.html" end
function Teams:sources() return { s = "/standings?level=ML" } end

function Teams:layout(L)
  local W = 392
  local bricks = UI.image("images/bg/bricks")
  if bricks then bricks:drawTiled(0, 0, W, 600) else Draw.tile(0, 0, W, 600, "bricks") end
  local y
  local mast = UI.image("images/ui/masthead-continental")
  if mast then
    local mw, mh = mast:getSize()
    gfx.setColor(gfx.kColorWhite) gfx.fillRect((W - mw) // 2 - 2, 0, mw + 4, mh + 2) gfx.setColor(gfx.kColorBlack)
    mast:draw((W - mw) // 2, 0)
    y = mh + 6
  else
    local _, h = Draw.wordart("THE CLUBS", W // 2, 2, UI.fonts.slab)
    y = h + 6
  end
  local rows = self.data.s and self.data.s.rows or {}
  local cw = (W - 24) // 2
  for i, r in ipairs(rows) do
    local t = r.team or { id = r.teamId, name = r.teamId, city = "" }
    local col = (i - 1) % 2
    local x = 8 + col * (cw + 8)
    local cy = y + ((i - 1) // 2) * 40
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(x, cy, cw, 34)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(x, cy, cw, 34)
    if not Logos.draw(t, x + 2, cy + 1, 32) then
      gfx.fillRect(x + 3, cy + 3, 28, 28)
      Text.draw(t.abbr or "?", x + 17, cy + 10, UI.fonts.bold, "white", "center")
    end
    Text.draw(Text.ellipsize(t.city .. " " .. t.name, UI.fonts.bold, cw - 40), x + 36, cy + 4, UI.fonts.bold)
    Text.draw(r.w .. "-" .. r.l .. "  \u{2022}  " .. (r.gb == 0 and "1st" or (r.gb .. " GB")), x + 36, cy + 18, UI.fonts.body)
    L:link(x, cy, cw, 34, function() Nav.team(t.id) end, { id = "club:" .. t.id, hint = "Org page: " .. t.city .. " " .. t.name })
  end
  L:mark(y + ((#rows + 1) // 2) * 40 + 4)
end
