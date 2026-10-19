-- EXTRA! EXTRA!: when SportsWire runs a story flagged `extra` (the weird tier, a plane crash,
-- the famous; server: Story.prominence >= 5), the next time you're on the desktop a newspaper
-- spins in with a crowd roar: headline, archive photo, the first paragraph, and the prop
-- market on it if Bobby has one. A reads it, B later. Each story slams in once.

local gfx <const> = playdate.graphics

Sites = Sites or {}

local Extra = {}
Extra.__index = Extra
Sites.Extra = Extra

local PW <const>, PH <const> = 372, 214
local SPIN <const> = 10

local function seenList()
  local l = Game.settings.extraSeen
  if type(l) ~= "table" then l = {} Game.settings.extraSeen = l end
  return l
end

local function seen(id)
  for _, s in ipairs(seenList()) do if s == id then return true end end
  return false
end

local function markSeen(id)
  local l = seenList()
  l[#l + 1] = id
  while #l > 20 do table.remove(l, 1) end
  playdate.datastore.write(Game.settings, "settings")
end

--- The first unseen EXTRA in a /news list, or nil.
function Extra.pick(stories)
  for _, s in ipairs(stories or {}) do
    if s.extra and not seen(s.id) then return s end
  end
  return nil
end

--- A prop market on the story's subject (by last name in the headline), from a /gossip doc.
local function propFor(story, gossip)
  local h = (story.headline or ""):lower()
  for _, sl in ipairs(gossip and gossip.storylines or {}) do
    local last = sl.who and sl.who.name and (sl.who.name:match("(%S+)$") or ""):lower()
    if last and #last > 2 and h:find(last, 1, true) then
      for _, p in ipairs(sl.props or {}) do
        if p.status == "open" then return sl, p end
      end
    end
  end
end

--- Shows the slam for the first unseen EXTRA (if any). Returns true if it did.
function Extra.maybeShow(news, gossip)
  local s = Extra.pick(news and news.stories)
  if not s then return false end
  Extra.show(s, gossip)
  return true
end

function Extra.show(story, gossip)
  local e = setmetatable({ s = story, opaque = true }, Extra)
  e.sl, e.prop = propFor(story, gossip)
  App.push(e)
  return e
end

function Extra:paint()
  local s = self.s
  local img = gfx.image.new(PW, PH, gfx.kColorWhite)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRect(1, 1, PW - 2, PH - 2)
  gfx.setLineWidth(1)
  Text.draw("SportsWire", 10, 6, UI.fonts.serif)
  Draw.wordart("EXTRA!", PW - 70, 2, UI.fonts.slab, {})
  gfx.drawLine(8, 32, PW - 9, 32)
  gfx.drawLine(8, 34, PW - 9, 34)
  local y = 38
  local lines = Text.wrap((s.headline or ""):upper(), UI.fonts.big, PW - 24)
  for i = 1, math.min(2, #lines) do
    Text.draw(lines[i], PW // 2, y, UI.fonts.big, nil, "center")
    y += 22
  end
  y += 2
  local tx, tw = 12, PW - 24
  local ph = 0
  if s.photo and Archive.get(s.photo, 96) then
    Archive.draw(s.photo, 12, y + 2, 96)
    tx, tw, ph = 116, PW - 128, 74
  elseif s.face and Faces.get(s.face, 48) then
    Faces.draw(s.face, 12, y + 2, 48)
    tx, tw, ph = 68, PW - 80, 62
  end
  local bh = PH - 26 - y
  Text.block(s.dek or "", tx, y, tw, UI.fonts.body, nil, math.max(2, bh // 14))
  -- footer: the verbs (and the market, if Bobby has one)
  gfx.fillRect(2, PH - 20, PW - 4, 18)
  local foot = "A: read it  \u{2022}  B: later"
  if self.prop then foot = foot .. "  \u{2022}  \u{25b6} PROPS OPEN: " .. (self.prop.question or "") end
  Text.draw(Text.ellipsize(foot, UI.fonts.bold, PW - 16), 8, PH - 19, UI.fonts.bold, "white")
  gfx.popContext()
  self.img = img
end

function Extra:enter()
  self.t = 0
  self:paint()
  markSeen(self.s.id)
  Sfx.roar()
end

function Extra:update()
  self.t += 1
  gfx.setPattern(UI.pat.gray)
  gfx.fillRect(0, 0, 400, 240)
  gfx.setColor(gfx.kColorBlack)
  local k = Game.settings.reduceMotion and 1 or math.min(1, self.t / SPIN)
  if k < 1 then
    -- the newspaper spins in from nowhere
    local e = 1 - (1 - k) ^ 2
    self.img:drawRotated(200, 120, (1 - e) * 540 - 4, math.max(0.05, e))
  else
    -- rotate once, then just blit
    if not self.final then self.final = self.img:rotatedImage(-4) Sfx.stamp() end
    local w, h = self.final:getSize()
    self.final:draw(200 - w // 2, 120 - h // 2)
  end
end

function Extra:AButtonDown()
  if self.t < SPIN then return end
  Sfx.select()
  App.pop()
  Nav.story(self.s.id)
end

function Extra:BButtonDown()
  Sfx.back()
  App.pop()
end

function Extra:rightButtonDown()
  if self.sl and self.t >= SPIN then
    App.pop()
    Nav.storyline(self.sl.id)
  end
end
