-- League standings for every level (ML, AA, B, D) plus the Enhanced League, with level tabs.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Standings = Page.define({ canvasH = 400 })
Sites.Standings = Standings

local LEVELS <const> = { "ML", "AA", "B", "D", "EL" }

function Standings:init(args)
  self.level = args.level or "ML"
end

function Standings:url()
  return "http://www.continentalleague.org/standings/" .. self.level:lower() .. ".html"
end

function Standings:sources() return { s = "/standings?level=" .. self.level } end

function Standings:setLevel(l)
  if l == self.level then return end
  self.level = l
  self.keepTab = l
  self:reload(true)
end

function Standings:afterRender()
  if self.keepTab then
    for i, l in ipairs(self.links) do if l.id == "tab:" .. self.keepTab then self.focus = i end end
    self.keepTab = nil
  end
end

function Standings:layout(L)
  local W = 392
  local y = 4
  local mast = UI.image("images/ui/masthead-continental")
  if mast then
    local mw, mh = mast:getSize()
    mast:draw((W - mw) // 2, 0)
    y = mh + 2
  end
  Text.draw("STANDINGS", 8, y, UI.fonts.big)
  local c = Game.clock or {}
  Text.draw("Season " .. (c.season or "?") .. " \u{2022} through Day " .. ((c.day or 1) - 1), W - 8, y + 6, UI.fonts.body, nil, "right")
  y += 26
  -- tabs
  local tx = 8
  for _, l in ipairs(LEVELS) do
    local label = Fmt.levelName(l)
    local w = UI.fonts.bold:getTextWidth(label) + 16
    local sel = l == self.level
    if sel then
      gfx.fillRect(tx, y, w, 17)
      Text.draw(label, tx + 8, y + 2, UI.fonts.bold, "white")
    else
      gfx.drawRect(tx, y + 2, w, 15)
      Text.draw(label, tx + 8, y + 3, UI.fonts.bold)
    end
    L:link(tx, y, w, 17, function() self:setLevel(l) end, { id = "tab:" .. l, hint = "Show " .. label .. " standings", style = "ring" })
    tx += w + 4
  end
  y += 17
  gfx.drawLine(4, y, W - 4, y)
  y += 5
  -- header
  local cols = { 8, 166, 192, 220, 254, 290, 322, 352 }
  local heads = { "CLUB", "W", "L", "GB", "STRK", "L10", "RS", "RA" }
  for i, h in ipairs(heads) do
    if i == 1 then Text.draw(h, cols[i], y, UI.fonts.bold) else Text.draw(h, cols[i] + 14, y, UI.fonts.bold, nil, "center") end
  end
  y += 15
  local rows = self.data.s and self.data.s.rows or {}
  for i, r in ipairs(rows) do
    Draw.dotted(4, W - 6, y + 13)
    local t = r.team or { id = r.teamId, name = r.teamId, city = "" }
    Text.draw(tostring(i), cols[1], y, UI.fonts.body)
    L:textLink(Text.ellipsize(t.city .. " " .. t.name, UI.fonts.body, 140), cols[1] + 14, y, function() Nav.team(t.id) end,
      { id = "team:" .. t.id, hint = "Org page \u{2022} " .. (r.rs or 0) .. " runs scored, " .. (r.ra or 0) .. " allowed" })
    local vals = { r.w, r.l, (r.gb == 0 or not r.gb) and "-" or (r.gb % 1 == 0 and string.format("%d", r.gb) or string.format("%.1f", r.gb)), r.streak, r.last10, r.rs, r.ra }
    for k, v in ipairs(vals) do
      Text.draw(tostring(v or ""), cols[k + 1] + 14, y, UI.fonts.body, nil, "center")
    end
    y += 15
  end
  y += 6
  local po = self.data.s and self.data.s.playoff
  if po and po.series and #po.series > 0 then
    y = self:layoutBracket(L, y, po, W)
  end
  if self.level == "EL" then
    y += Text.block("The Enhanced League: six clubs out in the desert, where the Commissioner sends the players he can't explain. Top four play for the Mirage Cup.", 8, y, W - 16, UI.fonts.body)
  else
    Text.draw("Top two clubs at the Continental level meet in the pennant series.", 8, y, UI.fonts.body)
    y += 14
  end
  L:mark(y + 4)
end

--- Playoff bracket rows: "ESF1  MFP 2 - CCM 1" with the winner starred.
function Standings:layoutBracket(L, y, po, W)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(4, y, W - 8, 15)
  Text.draw((po.name or "Playoffs"):upper(), 9, y + 1, UI.fonts.bold, "white")
  if po.champion then Text.draw("CHAMPION: " .. po.champion.name:upper() .. (po.finalScore and (" (" .. po.finalScore .. ")") or ""), W - 9, y + 1, UI.fonts.bold, "white", "right") end
  y += 18
  for _, s in ipairs(po.series) do
    local hi, lo = s.high or {}, s.low or {}
    local mark = function(t) return (s.winner and s.winner == t.id) and "\u{2605} " or "" end
    local line = (s.round == "final" and "FINAL" or "SEMI") .. "  " .. mark(hi) .. (hi.abbr or "?") .. " " .. ((s.wins and s.wins.high) or 0)
      .. "  -  " .. mark(lo) .. (lo.abbr or "?") .. " " .. ((s.wins and s.wins.low) or 0) .. "   (first to " .. (s.need or "?") .. ")"
    Text.draw(line, 12, y, UI.fonts.body)
    Draw.dotted(4, W - 6, y + 13)
    y += 15
  end
  return y + 6
end
