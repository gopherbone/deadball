-- 32x32 desktop icons. Uses images/ui/icons/<name>.png when the assets agent provides
-- them; otherwise paints a code-drawn placeholder (cached as an image).

local gfx <const> = playdate.graphics

Icons = Icons or {}
local cache = {}
-- shell icon name -> assets agent's images/ui/icons/<name>.png
Icons.ASSET = { bets = "bobby", news = "sportswire", bbs = "bbs", mail = "mail", cards = "binder",
  market = "market", standings = "standings", settings = "settings" }

local P = {}

P.bets = function()
  gfx.fillCircleAtPoint(16, 16, 14)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillCircleAtPoint(16, 16, 11)
  gfx.setColor(gfx.kColorBlack)
  Text.draw("$", 16, 6, UI.fonts.big, nil, "center")
end

P.news = function()
  gfx.setColor(gfx.kColorWhite) gfx.fillRect(3, 4, 26, 24) gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(3, 4, 26, 24)
  gfx.fillRect(5, 6, 22, 5)
  gfx.fillRect(5, 13, 10, 8)
  for i = 0, 3 do gfx.drawLine(17, 13 + i * 3, 26, 13 + i * 3) end
  gfx.drawLine(5, 24, 26, 24)
  gfx.drawLine(30, 6, 30, 29) gfx.drawLine(5, 29, 30, 29)
end

P.scores = function()
  gfx.fillRect(2, 5, 28, 20)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(5, 9, 9, 12) gfx.fillRect(18, 9, 9, 12)
  gfx.setColor(gfx.kColorBlack)
  Text.draw("7", 9, 9, UI.fonts.bold, nil, "center")
  Text.draw("1", 22, 9, UI.fonts.bold, nil, "center")
  gfx.fillRect(14, 25, 4, 5) gfx.fillRect(9, 29, 14, 2)
end

P.standings = function()
  gfx.drawRect(3, 26, 26, 3)
  gfx.fillRect(5, 16, 6, 10) gfx.fillRect(13, 8, 6, 18) gfx.fillRect(21, 12, 6, 14)
  -- pennant
  gfx.drawLine(16, 1, 16, 8)
  gfx.fillPolygon(16, 1, 24, 3, 16, 5)
end

P.bbs = function()
  gfx.drawRoundRect(2, 3, 28, 22, 3)
  gfx.fillRect(5, 6, 22, 16)
  gfx.setColor(gfx.kColorWhite)
  Text.draw(">_", 7, 7, UI.fonts.bold, "white")
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(10, 25, 12, 3) gfx.fillRect(6, 28, 20, 2)
end

P.mail = function()
  gfx.setColor(gfx.kColorWhite) gfx.fillRect(3, 8, 26, 18) gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(3, 8, 26, 18)
  gfx.drawLine(3, 8, 16, 18) gfx.drawLine(28, 8, 16, 18)
  gfx.drawLine(3, 25, 12, 16) gfx.drawLine(28, 25, 20, 16)
end

P.cards = function()
  for i = 2, 0, -1 do
    local o = i * 3
    gfx.setColor(gfx.kColorWhite) gfx.fillRect(6 + o, 2 + o, 17, 24) gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(6 + o, 2 + o, 17, 24)
  end
  gfx.drawRect(8, 4, 13, 14)
  gfx.fillCircleAtPoint(14, 10, 3)
  gfx.fillRect(10, 13, 9, 5)
end

P.shop = function()
  gfx.fillPolygon(6, 4, 26, 4, 28, 28, 4, 28)
  gfx.setColor(gfx.kColorWhite)
  for x = 4, 28, 4 do gfx.drawLine(x, 4, x - 1, 6) end
  gfx.fillRect(8, 11, 16, 9)
  gfx.setColor(gfx.kColorBlack)
  Text.draw("PACK", 16, 10, UI.fonts.body, nil, "center")
end

P.market = function()
  gfx.drawRect(4, 14, 24, 15)
  for i = 0, 5 do
    if i % 2 == 0 then gfx.fillRect(2 + i * 5, 6, 5, 8) else gfx.drawRect(2 + i * 5, 6, 5, 8) end
  end
  gfx.drawRect(8, 18, 7, 11)
  gfx.drawRect(18, 18, 7, 6)
end

P.settings = function()
  gfx.fillCircleAtPoint(16, 16, 10)
  for i = 0, 7 do
    local a = i * math.pi / 4
    gfx.fillCircleAtPoint(16 + math.floor(math.cos(a) * 12 + 0.5), 16 + math.floor(math.sin(a) * 12 + 0.5), 3)
  end
  gfx.setColor(gfx.kColorWhite) gfx.fillCircleAtPoint(16, 16, 4) gfx.setColor(gfx.kColorBlack)
end

P.syndicate = function()
  -- three wise guys in fedoras; the boss in front
  local function guy(x, y, front)
    if front then
      gfx.setColor(gfx.kColorWhite)
      gfx.fillRoundRect(x - 7, y + 9, 14, 30 - y - 9 + 2, 3)
      gfx.fillCircleAtPoint(x, y + 6, 5)
      gfx.fillRect(x - 8, y - 1, 16, 5)
      gfx.setColor(gfx.kColorBlack)
    end
    gfx.fillRoundRect(x - 6, y + 10, 12, 30 - y - 10, 3)
    gfx.fillCircleAtPoint(x, y + 6, 4)
    gfx.fillRect(x - 4, y - 1, 8, 4)      -- crown
    gfx.fillRect(x - 7, y + 3, 14, 1)     -- brim
    gfx.setColor(gfx.kColorWhite)
    gfx.drawLine(x, y + 12, x, y + 18)    -- tie line
    gfx.setColor(gfx.kColorBlack)
  end
  guy(7, 8, false)
  guy(25, 8, false)
  guy(16, 4, true)
end

P.teams = function()
  gfx.drawLine(4, 3, 4, 30)
  gfx.fillPolygon(5, 4, 29, 11, 5, 18)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(9, 9, 6, 4)
  gfx.setColor(gfx.kColorBlack)
end

P.trash = function()
  gfx.drawRect(8, 8, 16, 21)
  gfx.drawLine(6, 7, 26, 7) gfx.drawRect(13, 4, 6, 3)
  for x = 12, 20, 4 do gfx.drawLine(x, 11, x, 26) end
end

P.gossip = function()
  -- a speech bubble: "psst."
  gfx.setColor(gfx.kColorWhite) gfx.fillRoundRect(1, 6, 30, 18, 6) gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRoundRect(1, 6, 30, 18, 6)
  gfx.setLineWidth(1)
  gfx.fillTriangle(7, 23, 13, 23, 5, 30)
  Text.draw("psst", 16, 9, UI.fonts.bold, nil, "center")
end

P.pennant = function()
  -- a pennant on a pole over a little diamond
  gfx.drawLine(6, 3, 6, 29)
  gfx.fillPolygon(7, 3, 29, 9, 7, 15)
  gfx.setColor(gfx.kColorWhite)
  Text.draw("96", 13, 3, UI.fonts.bold, "white")
  gfx.setColor(gfx.kColorBlack)
  gfx.fillPolygon(18, 18, 26, 24, 18, 30, 10, 24)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillPolygon(18, 21, 23, 24, 18, 27, 13, 24)
  gfx.setColor(gfx.kColorBlack)
end

P.start = function()
  -- the taskbar's Start button, big
  gfx.fillRoundRect(1, 8, 30, 17, 3)
  gfx.setColor(gfx.kColorWhite)
  gfx.drawLine(2, 9, 29, 9)
  gfx.setColor(gfx.kColorBlack)
  Text.draw("Start", 16, 10, UI.fonts.bold, "white", "center")
end

function Icons.get(name)
  local c = cache[name]
  if c then return c end
  c = UI.image("images/ui/icons/" .. (Icons.ASSET[name] or "__none"))
  if not c then
    c = gfx.image.new(32, 32, gfx.kColorClear)
    gfx.pushContext(c)
    gfx.setColor(gfx.kColorBlack)
    local p = P[name] or P.news
    p()
    gfx.popContext()
  end
  cache[name] = c
  return c
end

function Icons.draw(name, x, y)
  Icons.get(name):draw(x, y)
end
