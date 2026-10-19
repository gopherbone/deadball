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

--- A punched hole: the card is gone there, so the table (dithered) shows through.
local function hole(x, y, r, state, label)
  if state == "punched" then
    gfx.setPattern(UI.pat.dark)
    gfx.fillCircleAtPoint(x, y, r)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawCircleAtPoint(x, y, r)
    gfx.drawCircleAtPoint(x, y, r + 1)
  elseif state == "next" then
    -- the one Bobby's about to punch: a dashed ring
    gfx.setColor(gfx.kColorBlack)
    local n = 16
    for i = 0, n - 1, 2 do
      local a0, a1 = i / n * 360, (i + 1) / n * 360
      gfx.drawArc(x, y, r, a0, a1)
    end
  else
    gfx.setColor(gfx.kColorBlack)
    gfx.drawCircleAtPoint(x, y, r)
  end
  if label and state ~= "punched" then
    Text.draw(label, x, y - 6, UI.fonts.bold, nil, "center")
  end
end
Bonus.hole = hole

--- The seven holes of a card view (server CardView) across [x, x + w). r: hole radius.
--- punching: the hole number being punched right now (drawn by the scene, not here).
function Bonus.drawHoles(card, x, y, w, r, opts)
  opts = opts or {}
  local holes = list(card, "holes")
  local n = math.max(1, #holes)
  local step = w // n
  local nextN = (card.punchedToday or card.lapsed) and -1 or ((card.hole or 0) + 1)
  if card.lapsed then nextN = 1 end
  for i, h in ipairs(holes) do
    local cx = x + step * (i - 1) + step // 2
    local state = (h.stamped and not card.lapsed and i ~= opts.punching) and "punched" or (i == nextN and "next" or "empty")
    hole(cx, y, r, state, (h.packs or 0) > 0 and state ~= "punched" and "\u{2605}" or nil)
    if opts.labels then
      local f = opts.labelFont or UI.fonts.body
      local lab = (h.packs or 0) > 0 and "PACK" or ("$" .. (h.cash or 0))
      Text.draw(lab, cx, y + r + 3, f, nil, "center")
    end
  end
  return step
end

-- The punch-card moment ------------------------------------------------------------------------

local Punch = {}
Punch.__index = Punch
Sites.PunchCard = Punch

local CW <const>, CH <const> = 330, 150
local CX <const>, CY <const> = 35, 34
local HOLES_X <const>, HOLES_Y <const>, HOLES_W <const> = 72, 86, 250
local HOLE_R <const> = 12

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

--- The card's static face (repainted only when its state changes).
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
  local stub = gfx.image.new(CH - 16, 40, gfx.kColorClear)
  gfx.pushContext(stub)
  Text.draw("REGULAR", (CH - 16) // 2, 2, UI.fonts.bold, nil, "center")
  Text.draw("No. " .. string.format("%04d", card.total or 0), (CH - 16) // 2, 18, UI.fonts.body, nil, "center")
  gfx.popContext()
  stub:rotatedImage(-90):draw(8, 8)
  -- masthead
  local title = Draw.wordartImage("BOBBY'S LOYALTY CLUB", UI.fonts.slab)
  local tw = title:getSize()
  title:draw(sx + (CW - sx - tw) // 2, 8)
  local name = (Game.account and Game.account.name) or "Pal"
  Text.draw(Text.ellipsize("MEMBER: " .. name:upper(), UI.fonts.bold, 170), sx + 10, 32, UI.fonts.bold)
  Text.draw("EST. 1996", CW - 10, 32, UI.fonts.body, nil, "right")
  gfx.drawLine(sx + 8, 47, CW - 10, 47)
  Text.draw("Show card. Get stuff. Don't ask.", sx + 10, 50, UI.fonts.body)
  -- the holes (the one being punched is drawn by the scene on top)
  Bonus.drawHoles(card, HOLES_X, HOLES_Y, HOLES_W, HOLE_R, { labels = true, punching = self.punching })
  -- footer: the streak and the fine print
  gfx.drawLine(sx + 8, CH - 30, CW - 10, CH - 30)
  local streak = card.streak or 0
  Text.draw("STREAK: " .. streak .. " DAY" .. (streak == 1 and "" or "S"), sx + 10, CH - 26, UI.fonts.bold)
  local fine = card.lapsed and "Your old card went through the wash."
    or (card.graceLeft and "Miss a day: Bobby looks the other way. Once." or "Bobby already looked the other way once.")
  Text.draw(Text.ellipsize(fine, UI.fonts.body, CW - sx - 20), sx + 10, CH - 14, UI.fonts.body)
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
  if d.punched == false then
    Game.moneyHold = false
    self.card = d.card or self.card
    self:paint()
    self.state = "done"
    return
  end
  -- repaint the card as it is now, minus the hole being punched (the press reveals it)
  self.card = d.card or self.card
  self.punching = self.target
  self:paint()
  self.state = "punch"
  self.t0 = self.t
  self.chad = {}
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

local packStamp = nil
local function bigStamp(lines)
  local f = UI.fonts.big
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, f:getTextWidth(l)) end
  local img = gfx.image.new(w + 20, #lines * 22 + 12, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(2, 2, w + 16, #lines * 22 + 8)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(3)
  gfx.drawRect(2, 2, w + 16, #lines * 22 + 8)
  gfx.setLineWidth(1)
  for i, l in ipairs(lines) do Text.draw(l, (w + 20) // 2, 5 + (i - 1) * 22, f, nil, "center") end
  gfx.popContext()
  return img:rotatedImage(-12)
end

function Punch:update()
  self.t += 1
  Draw.dim(0.5)
  if self.state == "loading" or not self.img then return end
  -- the card slides up
  local k = Game.settings.reduceMotion and 1 or math.min(1, self.t / 6)
  local oy = math.floor((1 - (1 - (1 - k) ^ 3)) * 150)
  self.img:draw(CX, CY + oy)
  if k < 1 then return end
  local hx, hy = holeAt(self.card or {}, self.target or 1)
  -- the hole punch: hovers over the next hole, slams on the response, lifts away
  local tool = nil
  if self.state == "wait" then
    tool = -16 - math.floor(math.abs(math.sin((self.t - (self.t0 or 0)) / 3)) * 6)
  elseif self.state == "punch" then
    local pt = self.t - self.t0
    if pt < 4 then tool = -16 + pt * 5
    elseif pt < 10 then tool = 2
    elseif pt < 20 then tool = 2 - (pt - 10) * 4 end
    if pt == 4 then
      Sfx.stamp()
      -- chad: little paper circles spray from the hole
      for i = 1, 8 do self.chad[i] = { x = hx, y = hy, vx = math.random(-30, 30) / 10, vy = math.random(-40, -10) / 10 } end
      self.punching = nil
      self:paint()
    end
    if pt == 10 then
      Game.moneyHold = false
      local r = self.res and self.res.reward or {}
      if (r.packs or 0) > 0 then
        Sfx.roar()
        packStamp = packStamp or bigStamp({ "FULL CARD!", "FREE PACK" })
      else
        Sfx.kaching()
      end
      self.chip = rewardChip("+" .. (r.label or "?"))
    end
    if pt >= 34 then self.state = "done" end
  end
  if self.state == "wait" and (self.t // 10) % 2 == 0 then
    -- the next hole blinks while the server thinks
    gfx.setColor(gfx.kColorWhite)
    gfx.fillCircleAtPoint(hx, hy, HOLE_R - 2)
    gfx.setColor(gfx.kColorBlack)
  end
  if tool then
    -- the hole punch (side view): a lever on a post, the pin comes down into the hole
    local pinB = hy + tool - 2          -- the pin's tip: in the hole at the slam
    local pinT = pinB - 22
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(hx - 3, pinT, 7, pinB - pinT)                -- the pin
    gfx.fillRoundRect(hx - 30, pinT - 9, 66, 10, 4)          -- the lever
    gfx.fillRect(hx + 24, pinT - 2, 9, pinB - pinT + 6)       -- the post
    gfx.setColor(gfx.kColorWhite)
    gfx.drawLine(hx - 26, pinT - 6, hx + 30, pinT - 6)       -- chrome
    gfx.fillRect(hx - 1, pinT + 2, 2, pinB - pinT - 4)
    gfx.setColor(gfx.kColorBlack)
  end
  -- chad falls
  for _, c in ipairs(self.chad or {}) do
    c.x += c.vx
    c.y += c.vy
    c.vy += 0.6
    if c.y < 240 then
      gfx.setColor(gfx.kColorWhite)
      gfx.fillCircleAtPoint(c.x, c.y, 3)
      gfx.setColor(gfx.kColorBlack)
      gfx.drawCircleAtPoint(c.x, c.y, 3)
    end
  end
  -- the reward floats up out of the hole
  if self.chip then
    local pt = self.t - (self.t0 or 0) - 10
    local cw = self.chip:getSize()
    self.chip:draw(math.max(4, math.min(396 - cw, hx - cw // 2)), hy - 40 - math.min(18, pt))
  end
  if packStamp and self.res and self.res.reward and (self.res.reward.packs or 0) > 0 and self.chip then
    local w, h = packStamp:getSize()
    packStamp:draw(200 - w // 2, CY + 38 - h // 2)
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
    Text.draw(Text.ellipsize(msg, UI.fonts.bold, CW - 12), 0, 1, UI.fonts.bold, "white")
    local keys = (self.state == "show" and not (self.card and self.card.punchedToday)) and "A: Punch it!   B: later" or (self.state == "done" and "A: OK" or "")
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

local paidImg = nil
local function paidStamp()
  if paidImg then return paidImg end
  local f = UI.fonts.head
  local w = f:getTextWidth("PAID") + 12
  local img = gfx.image.new(w + 4, 22, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(2, 2, w, 18)
  gfx.setColor(gfx.kColorBlack)
  gfx.setLineWidth(2)
  gfx.drawRect(2, 2, w, 18)
  gfx.setLineWidth(1)
  Text.draw("PAID", 2 + w // 2, 4, f, nil, "center")
  gfx.popContext()
  paidImg = img:rotatedImage(-10)
  return paidImg
end

local function countdown(ms)
  if not ms or ms <= 0 then return "now" end
  if ms < 3600000 then return Fmt.countdown(ms) end
  return Fmt.dur(ms)
end

--- One job row. Returns the y below it.
function Odd:jobRow(L, j, y)
  local x = 6
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
    Text.draw("Done and paid.", bx, y + 18, UI.fonts.body)
  end
  -- the right column: the reward, CLAIM when it's owed, PAID once it's paid
  local rx = W - rw
  local label = j.reward and j.reward.label or ""
  local petty = (self.data.b and self.data.b.pettyCash and self.data.b.pettyCash.left) or 1
  local owed = j.status == "done" and (j.weekly or petty > 0)
  if j.status == "claimed" then
    Text.draw(label, rx + rw - 6, y + 2, UI.fonts.bold, nil, "right")
    local fx = self.paidFx
    if fx and fx.id == j.id and fx.t < 12 then
      L:live(rx, y, rw, ROW_H - 2, function(_, sx, sy)
        fx.t += 1
        local img = paidStamp()
        local w, h = img:getSize()
        if fx.t < 5 then
          img:drawScaled(sx + rw // 2 - math.floor(w * (2 - fx.t / 5)) // 2, sy + 4, 2 - fx.t / 5)
        else
          if fx.t == 5 then Sfx.stamp() end
          img:draw(sx + rw // 2 - w // 2, sy + 9)
        end
        if fx.t >= 11 then self.paidFx = nil self.needRender = true end
      end)
    else
      local img = paidStamp()
      local w = img:getSize()
      img:draw(rx + rw // 2 - w // 2, y + 9)
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
  Bonus.drawHoles(card, 168, y + 18, 220, 9, { labels = true })
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
  local max, left = pc.max or 4, pc.left or 0
  Text.draw("PETTY CASH", 8, y, UI.fonts.bold)
  local px = 8 + UI.fonts.bold:getTextWidth("PETTY CASH") + 8
  for i = 1, max do
    if i <= left then gfx.fillRect(px, y + 2, 10, 10) else gfx.drawRect(px, y + 2, 10, 10) end
    px += 13
  end
  local refill = pc.refillAt and (pc.refillAt - Api.now()) or nil
  Text.draw(left .. " of " .. max .. " jobs left today \u{2022} refills at midnight UTC (" .. countdown(refill) .. ")", px + 4, y, UI.fonts.body)
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
