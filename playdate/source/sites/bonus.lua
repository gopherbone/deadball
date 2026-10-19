-- Bobby's Loyalty Club and Odd Jobs (server: packages/server/src/routes/bonus.ts, docs/API.md
-- "Loyalty card & odd jobs"). Three pieces:
--   Bonus              the shell side: keeps the newest GET /bonus, pages "ODD JOB DONE" when a
--                      job flips to done, re-checks after the writes that can finish one, and
--                      reports the two things only the client sees (a replay watched to the final
--                      out, a story read) to POST /bonus/report
--   Sites.PunchCard    the punch-card moment: once a real (UTC) day, after While You Were Out on
--                      boot. A punches it (POST /bonus/punch): the punch slams, the chad falls, the
--                      reward rolls into the status bar. B: later (the To Do row keeps it).
--   Sites.OddJobs      "The Back Room" at bobbys.biz: the card, today's three jobs, the week's
--                      big one and the petty-cash drawer. A on a finished job claims it (ka-ching,
--                      PAID stamp); on an open one it takes you where it gets done.
-- Never nags: the card pops up once per UTC day, the To Do rows sort below everything that has
-- a deadline, and pages only come for jobs you've actually finished.

local gfx <const> = playdate.graphics

Sites = Sites or {}
Bonus = Bonus or {}
Bonus.PATH = "/bonus"
Bonus.doc = nil

local seen = {}            -- job id -> last status seen ("open" | "done" | "claimed")
local pokeAt = nil         -- ms: re-check /bonus then (after a write that may finish a job)
local POKE_MS <const> = 1500
local reported = {}        -- "replay:<id>" / "read:<id>" -> true (once per session)
local watch = { id = nil, frames = 0 }
local readFor = { id = nil, frames = 0 }
local REPLAY_FRAMES <const> = 30 * 40   -- 40 s of BallCast actually playing before the final out counts
local READ_FRAMES <const> = 30 * 6      -- 6 s on a story page

local function list(d, k) return type(d) == "table" and type(d[k]) == "table" and d[k] or {} end

--- Every job in a doc: leftovers from yesterday, today's three, the week's.
function Bonus.allJobs(d)
  local out = {}
  for _, j in ipairs(list(d, "leftovers")) do out[#out + 1] = j end
  for _, j in ipairs(list(d, "jobs")) do out[#out + 1] = j end
  if type(d) == "table" and type(d.week) == "table" then out[#out + 1] = d.week end
  return out
end

--- Is there an open job of this kind? (Only then does the client bother reporting.)
function Bonus.wants(kind)
  for _, j in ipairs(Bonus.allJobs(Bonus.doc)) do
    if j.kind == kind and j.status == "open" then return true end
  end
  return false
end

--- A fresh copy (GET, or a POST's echo): page the jobs that just got done.
function Bonus.absorb(d)
  if type(d) ~= "table" or type(d.jobs) ~= "table" then return end
  Bonus.doc = d
  for _, j in ipairs(Bonus.allJobs(d)) do
    local before = seen[j.id]
    seen[j.id] = j.status
    if before == "open" and j.status == "done" and Nav.ready and Pager.note then
      local reward = j.reward and j.reward.label or ""
      Pager.note(j.weekly and "PAGE  THE BIG ONE" or "PAGE  ODD JOB DONE", j.text or "", "CLAIM " .. reward:upper() .. " \u{25b6}A",
        function() Sites.OddJobs.open() end)
    end
  end
  local dt = Sites.Desktop and Sites.Desktop.instance
  if dt and dt.data then dt.data.bonus = d dt.dirty = true end
end
Api.observe(Bonus.PATH, Bonus.absorb)

-- writes that can finish a job: look again a moment later (one small GET, only if a job is open)
local WRITES <const> = { "^/bets$", "^/props/bets$", "^/comments", "^/ops", "^/market", "^/packs/buy$" }
Api.observeWrites(function(path)
  if not Bonus.doc then return end
  local open = false
  for _, j in ipairs(Bonus.allJobs(Bonus.doc)) do if j.status == "open" then open = true break end end
  if not open then return end
  for _, p in ipairs(WRITES) do
    if path:find(p) then pokeAt = playdate.getCurrentTimeMilliseconds() + POKE_MS return end
  end
end)

function Bonus.report(kind, ref)
  local key = kind .. ":" .. tostring(ref)
  if reported[key] then return end
  reported[key] = true
  Api.post("/bonus/report", { kind = kind, ref = ref }, function(err, d)
    if d then Bonus.absorb(d) end
  end)
end

--- Per frame (Nav.tick): the delayed re-check, and the two client-side reports.
function Bonus.tick()
  local now = playdate.getCurrentTimeMilliseconds()
  if pokeAt and now >= pokeAt then
    pokeAt = nil
    Api.get(Bonus.PATH, function() end, { fresh = true, bg = true })
  end
  local s = App.top()
  -- BallCast: count the frames it actually plays; at the final out (the "end" beat), report
  local bc = BallCast and BallCast.scene
  if bc and s == bc and not s.src and s.gameId then
    if watch.id ~= s.gameId then watch.id, watch.frames = s.gameId, 0 end
    if s.mode == "watch" and s.playing then watch.frames += 1 end
    if (Game.frame or 0) % 15 == 0 and watch.frames >= REPLAY_FRAMES and s.tl and s.tl.beats and s.curBeatIndex then
      local beats = s.tl.beats
      local last = beats[#beats]
      if last and last.kind == "end" and s:curBeatIndex() == #beats and Bonus.wants("replay") then Bonus.report("replay", s.gameId) end
    end
    return
  end
  -- a SportsWire story that stayed on screen a few seconds
  if Sites.Story and s and getmetatable(s) == Sites.Story and s.args and s.args.id and not s.loading then
    if readFor.id ~= s.args.id then readFor.id, readFor.frames = s.args.id, 0 end
    readFor.frames += 1
    if readFor.frames == READ_FRAMES and Bonus.wants("read") then Bonus.report("read", s.args.id) end
  end
end

--- Where a job gets done.
function Bonus.go(j)
  local g = j and j.go
  if g == "bets" then Sites.Bets.open()
  elseif g == "gossip" then Sites.Gossip.open()
  elseif g == "news" then Sites.News.open()
  elseif g == "bbs" then Sites.BBS.open()
  elseif g == "scores" then Sites.Schedule.open()
  elseif g == "market" then Nav.cards("market")
  elseif g == "shop" then Nav.cards("shop")
  elseif g == "syndicate" then Sites.Syndicate.open()
  elseif g == "fanpage" then
    -- somebody pitching today has a guestbook
    local s = Game.slate
    local gm = s and s.games and s.games[1]
    local p = gm and gm.probables and gm.probables.home
    if p and p.id then Nav.person(p.id) else Sites.Teams.open() end
  else Sites.OddJobs.open() end
end

--- Desktop To Do rows (they sort below everything with a deadline; desktop.lua trims to fit).
function Bonus.todoRows(d)
  local rows = {}
  if type(d) ~= "table" then return rows end
  local card = d.card
  if type(card) == "table" and card.punchedToday == false then
    local nxt = list(card, "holes")[(card.lapsed and 0 or (card.hole or 0)) + 1]
    rows[#rows + 1] = { glyph = "o", text = "Punch your card at Bobby's" .. (nxt and nxt.reward and (" (" .. nxt.reward .. ")") or ""), right = "today",
      action = function() Sites.PunchCard.open() end, hint = "Bobby's Loyalty Club: one punch a day" }
  end
  local claim, cash, open = 0, 0, nil
  local petty = d.pettyCash and d.pettyCash.left or 1
  for _, j in ipairs(Bonus.allJobs(d)) do
    if j.status == "done" and (j.weekly or petty > 0) then
      claim += 1
      cash += (j.reward and j.reward.cash) or 0
    elseif j.status == "open" and not j.weekly and not open then
      open = j
    end
  end
  if claim > 0 then
    rows[#rows + 1] = { glyph = "+", text = "Odd jobs: " .. claim .. " to collect" .. (cash > 0 and (" (" .. Fmt.money(cash) .. ")") or ""), right = "claim",
      action = function() Sites.OddJobs.open() end, hint = "The Back Room at Bobby's: claim what you're owed" }
  elseif open and petty > 0 then
    rows[#rows + 1] = { glyph = "+", text = "Odd job: " .. (open.text or ""), right = open.reward and open.reward.label or nil,
      action = function() Bonus.go(open) end, hint = "Bobby's odd jobs: " .. (open.have or 0) .. "/" .. (open.need or 1) .. ". A: go do it" }
  end
  return rows
end

--- POST /bonus/jobs/:id/claim. cb(err, data)
function Bonus.claim(j, cb)
  Api.post("/bonus/jobs/" .. j.id .. "/claim", {}, function(err, d)
    if d then
      Game.absorb(d)
      Bonus.absorb(d)
    end
    cb(err, d)
  end)
end

-- Drawing the card ---------------------------------------------------------------------------
-- All of it prerendered by tools/assets/bonus_art.py (images/ui/bonus/): the star die's rim, the
-- target rings, the pliers keyframes (anchors in sites/bonus_art.lua), the chad, CHNK!, and the
-- inked stamps in slam steps. Nothing rotates or dithers at runtime.


local ART <const> = "images/ui/bonus/"
local function art(name) return UI.image(ART .. name) end
Bonus.art = art

--- The star die's outline, centered on (0, 0) in an image of size 2(R+3)+1 (matches bonus_art.py).
local starCache = {}
local function starPoly(R)
  local p = starCache[R]
  if p then return p end
  local c = R + 3
  local pts = {}
  for i = 0, 9 do
    local r = (i % 2 == 0) and R or R * 0.42
    local a = math.rad(-90 + i * 36)
    pts[#pts + 1] = c + r * math.cos(a)
    pts[#pts + 1] = c + r * math.sin(a)
  end
  p = playdate.geometry.polygon.new(table.unpack(pts))
  p:close()
  starCache[R] = p
  return p
end

--- A punched star at (x, y). mode "card": the cut is transparent (the backdrop shows through the
--- card image); otherwise (a page canvas) the hole shows a dark table. Then the rim: a 1 px edge
--- and the cut wall's shadow along the top and left.
local function punchedHole(x, y, R, mode)
  local c = R + 3
  local poly = starPoly(R):copy()
  poly:translate(x - c, y - c)
  if mode == "card" then
    gfx.setColor(gfx.kColorClear)
  else
    gfx.setPattern(UI.pat.dark)
  end
  gfx.fillPolygon(poly)
  gfx.setColor(gfx.kColorBlack)
  local rim = art("hole-rim-" .. R)
  if rim then rim:draw(x - c, y - c) end
end
Bonus.punchedHole = punchedHole

--- The seven holes of a card view (server CardView) across [x, x + w). R: 11 (the card) or 7.
--- opts: labels, punching (hole n drawn unpunched: the press is about to happen), mode ("card").
function Bonus.drawHoles(card, x, y, w, R, opts)
  opts = opts or {}
  local holes = list(card, "holes")
  local n = math.max(1, #holes)
  local step = w // n
  local nextN = (card.punchedToday or card.lapsed) and -1 or ((card.hole or 0) + 1)
  if card.lapsed then nextN = 1 end
  if opts.punching then nextN = opts.punching end
  local c = R + 3
  for i, h in ipairs(holes) do
    local cx = x + step * (i - 1) + step // 2
    if h.stamped and not card.lapsed and i ~= opts.punching then
      punchedHole(cx, y, R, opts.mode)
    else
      local ring = art(((i == nextN) and "ring-next-" or ((h.packs or 0) > 0 and "ring-pack-" or "ring-")) .. R)
      if ring then ring:draw(cx - c, y - c) end
    end
    if opts.labels then
      local f = opts.labelFont or UI.fonts.body
      local lab = (h.packs or 0) > 0 and "PACK" or ("$" .. (h.cash or 0))
      Text.draw(lab, cx, y + R + 4, f, nil, "center")
    end
  end
  return step
end

--- The inked stamp `name` at slam step k (1 = 1.6x ... 4 = 1x), centered on (cx, cy).
local function drawStamp(name, k, cx, cy)
  local img = art(name .. "-" .. math.max(1, math.min(4, k)))
  if not img then return end
  local w, h = img:getSize()
  img:draw(cx - w // 2, cy - h // 2)
end
Bonus.drawStamp = drawStamp

-- The punch-card moment ------------------------------------------------------------------------

local Punch = { holdToasts = true }   -- toasts and pages wait until the card is put away
Punch.__index = Punch
Sites.PunchCard = Punch

local CW <const>, CH <const> = 330, 150
local CX <const>, CY <const> = 35, 34
local HOLES_X <const>, HOLES_Y <const>, HOLES_W <const> = 72, 86, 250
local HOLE_R <const> = 11

local function askedToday(card)
  return Game.settings.punchAsked == card.utcDay
end

--- After While You Were Out on boot: the card, if today's punch is still open (once a UTC day).
--- cb() runs when the player is done (or at once). Returns true when the flow is asynchronous.
function Punch.maybeShow(cb)
  local host = App.top()
  Api.get(Bonus.PATH, function(err, d)
    local card = type(d) == "table" and d.card
    if err or type(card) ~= "table" or card.punchedToday ~= false or askedToday(card) or App.top() ~= host then
      if cb then cb() end
      return
    end
    Punch.open({ doc = d, cb = cb })
  end)
  return true
end

function Punch.open(args)
  local s = setmetatable({ opaque = false, args = args or {} }, Punch)
  App.push(s, args)
  return s
end

function Punch:enter(args)
  self.args = args or self.args or {}
  self.doc = self.args.doc or Bonus.doc or Api.peek(Bonus.PATH)
  self.card = self.doc and self.doc.card
  self.t = 0
  self.state = "show"
  if not self.card then
    -- nothing cached yet: fetch, then paint
    self.state = "loading"
    Api.get(Bonus.PATH, function(err, d)
      if d and d.card then self.doc, self.card = d, d.card self.state = "show" self:paint() else
        Toast.show(Api.errorText(err), "bad")
        self:close()
      end
    end)
  else
    self:paint()
  end
  if self.card then
    Game.settings.punchAsked = self.card.utcDay
    playdate.datastore.write(Game.settings, "settings")   -- (not saveSettings: that reconfigures the network)
  end
  Sfx.chime()
end

local stubCache = {}
--- The stub's sideways lettering (rotated once per card number, not per frame).
local function stubImage(total)
  local key = total or 0
  local img = stubCache[key]
  if img then return img end
  local s = gfx.image.new(CH - 16, 40, gfx.kColorClear)
  gfx.pushContext(s)
  Text.draw("REGULAR", (CH - 16) // 2, 2, UI.fonts.bold, nil, "center")
  Text.draw("No. " .. string.format("%04d", key), (CH - 16) // 2, 18, UI.fonts.body, nil, "center")
  gfx.popContext()
  img = s:rotatedImage(-90)
  stubCache[key] = img
  return img
end

--- The card's static face (repainted only when its state changes: shown, and at the slam).
function Punch:paint()
  local card = self.card or {}
  local img = gfx.image.new(CW + 4, CH + 4, gfx.kColorClear)
  gfx.pushContext(img)
  -- shadow, card stock, a double rule
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(4, 4, CW, CH)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(0, 0, CW, CH)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(0, 0, CW, CH)
  gfx.drawRect(3, 3, CW - 6, CH - 6)
  -- the stub, behind a perforation
  local sx = 50
  for yy = 6, CH - 8, 4 do gfx.fillRect(sx, yy, 1, 2) end
  gfx.fillCircleAtPoint(sx, 0, 4)
  gfx.fillCircleAtPoint(sx, CH, 4)
  stubImage(card.total):draw(8, 8)
  -- masthead
  local title = Draw.wordartImage("BOBBY'S LOYALTY CLUB", UI.fonts.slab)
  local tw = title:getSize()
  title:draw(sx + (CW - sx - tw) // 2, 8)
  local name = (Game.account and Game.account.name) or "Pal"
  Text.draw(Text.ellipsize("MEMBER: " .. name:upper(), UI.fonts.bold, 170), sx + 10, 32, UI.fonts.bold)
  Text.draw("EST. 1996", CW - 10, 32, UI.fonts.body, nil, "right")
  gfx.drawLine(sx + 8, 47, CW - 10, 47)
  Text.draw("Show card. Get stuff. Don't ask.", sx + 10, 50, UI.fonts.body)
  -- the holes: punched ones are cut out of the card (the dimmed desktop shows through)
  Bonus.drawHoles(card, HOLES_X, HOLES_Y, HOLES_W, HOLE_R, { labels = true, punching = self.punching, mode = "card" })
  -- footer: the streak and the fine print
  -- (inside the inner rule at CH - 4: the fine print's last line ends at CH - 6)
  gfx.drawLine(sx + 8, CH - 34, CW - 10, CH - 34)
  local streak = card.streak or 0
  Text.draw("STREAK: " .. streak .. " DAY" .. (streak == 1 and "" or "S"), sx + 10, CH - 32, UI.fonts.bold)
  local fine = card.lapsed and "Your old card went through the wash."
    or (card.graceLeft and "Miss a day: Bobby looks the other way. Once." or "Bobby already looked the other way once.")
  Text.drawFit(fine, sx + 10, CH - 19, CW - sx - 20, UI.fonts.body, nil, nil, { short = card.graceLeft and "Miss a day: Bobby looks away. Once." or "Bobby already looked away once." })
  gfx.popContext()
  self.img = img
end

--- Where hole n's center sits on screen.
local function holeAt(card, n)
  local holes = list(card, "holes")
  local step = HOLES_W // math.max(1, #holes)
  return CX + HOLES_X + step * (n - 1) + step // 2, CY + HOLES_Y
end

function Punch:close()
  if App.top() == self then App.pop() end
  local cb = self.args and self.args.cb
  if cb then cb() end
end

function Punch:AButtonDown()
  if self.t < 6 then return end
  if self.state == "show" then
    if self.card and self.card.punchedToday then self:close() return end
    self.state = "wait"
    self.t0 = self.t
    self.target = (self.card and self.card.lapsed) and 1 or ((self.card and self.card.hole or 0) % 7 + 1)
    self.punching = self.target
    Sfx.select()
    Api.post("/bonus/punch", {}, function(err, d) self:punched(err, d) end)
  elseif self.state == "done" then
    Sfx.select()
    self:close()
  end
end

function Punch:BButtonDown()
  if self.state == "wait" or self.state == "punch" then return end
  Sfx.back()
  self:close()
end

function Punch:punched(err, d)
  if err or type(d) ~= "table" then
    Toast.show(Api.errorText(err), "bad")
    self.state = "show"
    self.punching = nil
    return
  end
  self.res = d
  self.target = d.hole or self.target
  self.line = d.line
  -- the money shows up when the punch lands
  if d.account and Game.account then
    Game.moneyHold = true
    Game.displayMoney = Game.displayMoney or Game.account.money
    Game.setAccount(d.account)
  end
  Bonus.absorb(d)
  self.card = d.card or self.card
  if d.punched == false then
    Game.moneyHold = false
    self.punching = nil
    self:paint()
    self.state = "done"
    return
  end
  -- the card as it is now, with the target hole still whole: the slam cuts it
  self.punching = self.target
  self:paint()
  self.state = "punch"
  self.pt = -1
end

local function rewardChip(text)
  local f = UI.fonts.big
  local w = f:getTextWidth(text) + 14
  local img = gfx.image.new(w + 3, 26, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRoundRect(3, 3, w, 22, 4)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRoundRect(0, 0, w, 22, 4)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRoundRect(0, 0, w, 22, 4)
  Text.draw(text, w // 2, 0, f, nil, "center")
  gfx.popContext()
  return img
end

-- The pliers' keyframes, untweened: { frame, dx, dy } relative to the target hole. The approach
-- plays while the server answers (then holds on the hover), the rest after the slam.
local APPROACH <const> = { { 1, 46, -34 }, { 1, 46, -34 }, { 2, 18, -12 }, { 2, 18, -12 }, { 3, 0, -2 } }
local AFTER <const> = {   -- index = frames since the slam
  { 4, 0, 0 }, { 4, 0, 0 }, { 4, 0, 0 }, { 4, 0, 0 }, { 5, 0, -3 }, { 5, 0, -3 }, { 5, 0, -3 },
  { 2, 18, -12 }, { 2, 18, -12 }, { 1, 46, -34 }, { 1, 46, -34 },
}
local SHAKE <const> = { { 3, -2 }, { -2, 2 } }       -- the two frames after a slam
local CHAD_AT <const> = 4        -- the jaws open: the chad flips out
local CHIP_AT <const> = 8        -- the reward rises
local STAMP_AT <const> = 13      -- a full (or new) card: the rubber stamp comes down
local DONE_AT <const> = 40

local function drawPliers(f, hx, hy, ox, oy)
  local img = art("punch-" .. f)
  local an = BonusArt and BonusArt.punch and BonusArt.punch[f]
  if img and an then img:draw(hx - an[1] + ox, hy - an[2] + oy) end
end

function Punch:update()
  self.t += 1
  Draw.dim(0.5)
  if self.state == "loading" or not self.img then return end
  -- the card slides up
  local k = Game.settings.reduceMotion and 1 or math.min(1, self.t / 6)
  local oy = math.floor((1 - (1 - (1 - k) ^ 3)) * 150)
  local hx, hy = holeAt(self.card or {}, self.target or 1)
  -- the slam's shake: the card and everything on it
  local sx, sy = 0, 0
  local pt = self.state == "punch" and self.pt or nil
  local stampOn = self.res and self.res.reward and ((self.res.reward.packs or 0) > 0 or self.res.lapsed)
  if pt and pt >= 0 then
    local sh = SHAKE[pt + 1] or (stampOn and SHAKE[pt - STAMP_AT - 2]) or nil
    if sh then sx, sy = sh[1], sh[2] end
  end
  self.img:draw(CX + sx, CY + oy + sy)
  if k < 1 then return end
  hx, hy = hx + sx, hy + sy
  local wf = self.t - (self.t0 or 0)
  if self.state == "wait" then
    local a = APPROACH[math.min(#APPROACH, wf + 1)]
    -- (the hover bobs a pixel while the server thinks)
    drawPliers(a[1], hx, hy, a[2], a[3] - ((wf >= #APPROACH and (self.t // 6) % 2 == 0) and 1 or 0))
  elseif self.state == "punch" then
    -- the slam waits for the approach to finish
    if self.pt < 0 and wf < #APPROACH then
      local a = APPROACH[wf + 1]
      drawPliers(a[1], hx, hy, a[2], a[3])
    else
      self.pt += 1
      pt = self.pt
      if pt == 0 then
        Sfx.stamp()
        self.punching = nil
        self:paint()   -- the hole is cut
      end
      local a = AFTER[pt + 1]
      if a then drawPliers(a[1], hx, hy, a[2], a[3]) end
      if pt <= 5 then
        local burst = art(pt == 0 and "chnk-1" or "chnk-2")
        if burst then local bw, bh = burst:getSize() burst:draw(hx - 62 - bw // 2, hy - 34 - bh // 2) end
      end
      if pt == CHAD_AT then
        self.chad = { x = hx - 6, y = hy + 2, vx = -2.4, vy = -2.5, f = 0 }
      end
      if pt == CHIP_AT then
        Game.moneyHold = false
        local r = self.res and self.res.reward or {}
        if (r.packs or 0) > 0 then Sfx.roar() else Sfx.kaching() end
        self.chip = rewardChip("+" .. (r.label or "?"))
      end
      if stampOn and pt == STAMP_AT + 3 then Sfx.stamp() end
      if pt >= DONE_AT + (stampOn and 10 or 0) then self.state = "done" end
    end
  end
  -- the reward floats up out of the hole
  if self.chip then
    local rise = math.min(18, (self.pt or 0) - CHIP_AT)
    local cw = self.chip:getSize()
    self.chip:draw(math.max(4, math.min(396 - cw, hx - cw // 2)), hy - 40 - rise)
  end
  -- the chad: flips (4 prerendered faces) and falls
  local c = self.chad
  if c and c.y < 250 then
    c.x += c.vx
    c.y += c.vy
    c.vy += 0.7
    c.f += 1
    local img = art("chad-" .. ((c.f // 2) % 4 + 1))
    if img then local w, h = img:getSize() img:draw(math.floor(c.x) - w // 2, math.floor(c.y) - h // 2) end
  end
  -- a full card (or a new one): the stamp comes down, 1.6x -> 1x in four prerendered steps
  if stampOn and self.pt and self.pt >= STAMP_AT then
    drawStamp((self.res.reward.packs or 0) > 0 and "stamp-pack" or "stamp-new", self.pt - STAMP_AT + 1, 200 + sx, CY + 62 + sy)
  end
  -- the bar under the card: the line, then the buttons
  local by = CY + CH + 12
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(CX, by, CW, 30)
  local msg
  if self.state == "show" then
    if self.card and self.card.punchedToday then msg = "Punched today. Back tomorrow (UTC)."
    elseif self.card and self.card.lapsed then msg = "New card. Bobby keeps the old ones in a shoebox."
    else msg = "One punch a day. Day 7: a free pack." end
  elseif self.state == "wait" then msg = "Bobby's looking for the punch..."
  else msg = self.line or "" end
  if msg ~= self.msgText then
    self.msgText = msg
    self.msgImg = gfx.image.new(CW - 8, 28, gfx.kColorClear)
    gfx.pushContext(self.msgImg)
    local keys = (self.state == "show" and not (self.card and self.card.punchedToday)) and "A: Punch it!   B: later" or (self.state == "done" and "A: OK" or "")
    local kw = keys ~= "" and (UI.fonts.body:getTextWidth(keys) + 10) or 0
    -- Bobby's line wraps onto the second row, beside the keys (never cut mid-sentence on row one)
    local lines = Text.wrap(msg, UI.fonts.bold, CW - 12)
    Text.draw(lines[1] or "", 0, 1, UI.fonts.bold, "white")
    if lines[2] then
      local rest = table.concat(lines, " ", 2)
      Text.drawFit(rest, 0, 14, CW - 12 - kw, UI.fonts.bold, "white")
    end
    Text.draw(keys, CW - 12, 14, UI.fonts.body, "white", "right")
    gfx.popContext()
  end
  self.msgImg:draw(CX + 6, by + 1)
  -- keep the bar's money on top of the dim so the roll-up shows
  if self.state == "punch" or self.state == "done" then Chrome.menubar() end
end

-- The Back Room: odd jobs ------------------------------------------------------------------------

local Odd = Page.define({ canvasH = 520, refreshOnResume = true })
Sites.OddJobs = Odd

local W <const> = 392
local ROW_H <const> = 38

function Odd:url() return "http://www.bobbys.biz/backroom/oddjobs.html" end
function Odd:sources() return { b = Bonus.PATH } end
function Odd:statusText() return "A: claim it, or go do it \u{2022} crank: scroll" end

--- The countdowns are painted into the canvas: refresh them twice a minute (and after a stamp).
function Odd:tick()
  self.tickN = (self.tickN or 0) + 1
  if self.needRender or (self.tickN % 900 == 0 and not self.paidFx) then
    self.needRender = false
    self:render(true)
  end
end

function Odd:loaded()
  if self.data.b then Bonus.absorb(self.data.b) end
end

local function countdown(ms)
  if not ms or ms <= 0 then return "now" end
  if ms < 3600000 then return Fmt.countdown(ms) end
  return Fmt.dur(ms)
end

--- One job row. Returns the y below it.
function Odd:jobRow(L, j, y)
  local x = 6
  -- a solid white plate under the row: the page's dither stays in the margins, not behind the words
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(2, y, W - 4, ROW_H - 1)
  gfx.setColor(gfx.kColorBlack)
  -- the box: empty, a check (done), filled (paid)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y + 3, 16, 16)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y + 3, 16, 16)
  if j.status == "claimed" then
    gfx.fillRect(x + 3, y + 6, 10, 10)
  elseif j.status == "done" then
    Text.draw("\u{2713}", x + 8, y + 4, UI.fonts.bold, nil, "center")
  end
  local tx, rw = x + 24, 98
  local tw = W - tx - rw - 6
  local f = j.status == "done" and UI.fonts.bold or UI.fonts.body
  Text.draw(Text.ellipsize(j.text or "", f, tw), tx, y + 2, f)
  -- progress: a bar for counts, then where it gets done
  local need, have = math.max(1, j.need or 1), math.min(j.need or 1, j.have or 0)
  local line = have .. "/" .. need
  Text.draw(line, tx, y + 18, UI.fonts.bold)
  local bx = tx + UI.fonts.bold:getTextWidth(line) + 6
  if need > 1 then
    Draw.progress(bx, y + 21, 60, 7, have / need)
    bx += 66
  end
  if j.status == "open" then
    local where = ({ bets = "Bobby's", gossip = "Gossip Board", news = "SportsWire", bbs = "the Clubhouse", scores = "Scores", market = "Bidz-R-Us", shop = "Card Shop", fanpage = "a fan page", syndicate = "Syndicate" })[j.go or ""] or "the desktop"
    Text.draw("\u{25b6} " .. where, bx, y + 18, UI.fonts.body)
  elseif j.status == "claimed" then
    Text.draw("Done and paid: " .. (j.reward and j.reward.label or ""), bx, y + 18, UI.fonts.body)
  end
  -- the right column: the reward, CLAIM when it's owed, PAID once it's paid
  local rx = W - rw
  local label = j.reward and j.reward.label or ""
  local petty = (self.data.b and self.data.b.pettyCash and self.data.b.pettyCash.left) or 1
  local owed = j.status == "done" and (j.weekly or petty > 0)
  if j.status == "claimed" then
    local fx = self.paidFx
    -- the stamp owns the reward column (the amount moved to "Done and paid: $5")
    local px, py = rx + rw // 2 - 2, y + 18
    if fx and fx.id == j.id and fx.t < 10 then
      -- the PAID stamp slams: 1.6x -> 1x in four prerendered steps, a thunk and a 2-frame shake
      L:live(rx - 30, y - 12, rw + 30, ROW_H + 20, function(_, sx, sy)
        fx.t += 1
        if fx.t == 4 then Sfx.stamp() end
        local shake = (fx.t == 4 and 2) or (fx.t == 5 and -1) or 0
        Bonus.drawStamp("stamp-paid", fx.t, sx + (px - rx + 30) + shake, sy + (py - y + 12) - shake)
        if fx.t >= 9 then self.paidFx = nil self.needRender = true end
      end)
    else
      Bonus.drawStamp("stamp-paid", 4, px, py)
    end
  elseif owed then
    gfx.fillRect(rx, y + 2, rw - 4, 32)
    Text.draw("CLAIM", rx + (rw - 4) // 2, y + 3, UI.fonts.bold, "white", "center")
    Text.draw(label, rx + (rw - 4) // 2, y + 17, UI.fonts.bold, "white", "center")
  else
    Draw.chip(rx + rw - 6 - (UI.fonts.bold:getTextWidth(label) + 6), y + 2, label, UI.fonts.bold, true)
    if j.status == "done" then Text.draw("drawer's empty", rx + rw - 6, y + 18, UI.fonts.body, nil, "right") end
  end
  local hint
  if j.status == "claimed" then hint = "Paid. Bobby doesn't pay twice."
  elseif owed then hint = "A: claim " .. label
  elseif j.status == "done" then hint = "Done, but the petty cash is out until midnight (UTC)"
  else hint = "A: go do it (" .. have .. "/" .. need .. ")" end
  L:link(2, y, W - 4, ROW_H - 2, function() self:pick(j, owed) end, { id = "job:" .. j.id, style = "ring", hint = hint })
  Draw.dotted(4, W - 4, y + ROW_H - 1)
  return y + ROW_H
end

local function bar(y, left, right)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(2, y, W - 4, 16)
  Text.draw(left, 6, y + 1, UI.fonts.bold, "white")
  if right then Text.draw(right, W - 6, y + 1, UI.fonts.body, "white", "right") end
  return y + 19
end

function Odd:layout(L)
  Draw.tile(0, 0, W, 6400, "lighter")
  local d = self.data.b or {}
  local mast = UI.image("images/ui/masthead-bobby")
  if mast then mast:draw(4, 2) else Draw.wordart("BETS BY BOBBY", 110, 4, UI.fonts.slab) end
  -- the back-room sign
  gfx.fillRect(232, 2, 156, 34)
  Text.draw("THE BACK ROOM", 310, 3, UI.fonts.bold, "white", "center")
  Text.draw("ODD JOBS", 310, 14, UI.fonts.big, "white", "center")
  local y = 42
  -- the loyalty card, small
  local card = d.card or {}
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(4, y, W - 8, 62)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(4, y, W - 8, 62)
  gfx.drawRect(6, y + 2, W - 12, 58)
  Text.draw("BOBBY'S LOYALTY CLUB", 12, y + 5, UI.fonts.head)
  local streak = card.streak or 0
  Text.draw("Streak " .. streak .. (streak == 1 and " day" or " days") .. "  \u{2022}  best " .. (card.best or 0), 12, y + 22, UI.fonts.body)
  Bonus.drawHoles(card, 168, y + 18, 220, 7, { labels = true })
  if card.punchedToday == false then
    L:button("Punch it!", 12, y + 38, 90, 18, function() Sites.PunchCard.open({ cb = function() self:reload(true) end }) end,
      { id = "punch", hint = "One punch a real day (UTC). Day 7: a free pack." })
  else
    local left = card.nextAt and (card.nextAt - Api.now()) or nil
    Text.draw("Punched today \u{2713}  next in " .. countdown(left), 12, y + 41, UI.fonts.body)
  end
  y += 68
  -- today's jobs
  local jobs = list(d, "jobs")
  local endsIn = d.endsAt and (d.endsAt - Api.now()) or nil
  y = bar(y, "ODD JOBS \u{2022} DAY " .. (d.day or "?"), "new board in " .. countdown(endsIn))
  local leftovers = list(d, "leftovers")
  for _, j in ipairs(leftovers) do y = self:jobRow(L, j, y) end
  for _, j in ipairs(jobs) do y = self:jobRow(L, j, y) end
  if #jobs == 0 and #leftovers == 0 then
    Text.draw("Bobby's got nothing for you right now.", 8, y + 2, UI.fonts.body)
    y += 20
  end
  -- the week's
  if type(d.week) == "table" then
    local wl = d.week.endsAt and (d.week.endsAt - Api.now()) or nil
    y = bar(y + 4, "THE BIG ONE \u{2022} THIS WEEK", "ends in " .. countdown(wl))
    y = self:jobRow(L, d.week, y)
  end
  -- the drawer
  local pc = d.pettyCash or {}
  y += 6
  -- the fine print sits on a white plate too
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(2, y - 3, W - 4, 88)
  gfx.setColor(gfx.kColorBlack)
  local max, left = pc.max or 4, pc.left or 0
  Text.draw("PETTY CASH", 8, y, UI.fonts.bold)
  local px = 8 + UI.fonts.bold:getTextWidth("PETTY CASH") + 8
  for i = 1, max do
    if i <= left then gfx.fillRect(px, y + 2, 10, 10) else gfx.drawRect(px, y + 2, 10, 10) end
    px += 13
  end
  local refill = pc.refillAt and (pc.refillAt - Api.now()) or nil
  local cd = countdown(refill)
  Text.drawFit(left .. " of " .. max .. " jobs left today \u{2022} refills at midnight UTC (" .. cd .. ")", px + 4, y, W - 10 - (px + 4), UI.fonts.body, nil, nil,
    { short = { left .. " of " .. max .. " left today \u{2022} refills 00:00 UTC (" .. cd .. ")", left .. " of " .. max .. " left \u{2022} refills in " .. cd } })
  y += 18
  Text.block("Daily jobs change with the game day; finish one before the bell and you can still collect after it. The big one runs Monday to Sunday (UTC) and doesn't touch the drawer.", 8, y, W - 16, UI.fonts.body, nil, 3)
  y += 46
  Text.draw("\"Bobby is not responsible for jobs.\"", W // 2, y, UI.fonts.body, nil, "center")
  L:mark(y + 18)
end

function Odd:pick(j, owed)
  if j.status == "claimed" then Sfx.error() return end
  if not owed then
    if j.status == "done" then
      Sfx.error()
      Toast.show("The petty-cash drawer is empty until midnight (UTC).", nil)
      return
    end
    Sfx.select()
    Bonus.go(j)
    return
  end
  if self.claiming then return end
  self.claiming = true
  Sfx.select()
  Bonus.claim(j, function(err, d)
    self.claiming = false
    if err then
      Toast.show(Api.errorText(err), "bad")
      self:reload(true)
      return
    end
    if not d.again then
      Sfx.kaching()
      self.paidFx = { id = j.id, t = 0 }
    end
    if d.card then self.data.b = d end
    self:render(true)
    if d.line then Toast.show(d.line, "good") end
  end)
end
