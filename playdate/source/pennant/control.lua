--[[ Direct control in a live Pennant game: the two schemes' screens (pennant/schemes.lua has the
  input mappings). Methods on PennantLive's source (pennant/live.lua), which hands over at the
  engine's "bat" and "pitchsel" pauses when the player has that side.

  Shared: one strike zone (the inset on the right) with this at-bat's pitches so far marked on it
  (numbered, the latest ringed: hollow = ball, filled = strike or foul, X = hit by pitch; the
  markers come from BallCast's K-ZONE, ballcast/tv/overlay.lua, so they show once the picture has
  shown the pitch arrive). Once the pitch is away the zone stays up while it plays (drawTrack, with
  the call and the count for a moment): BallCast's own K-ZONE inset on the left is off all through a
  half you play, and back when the coaches have it. After a ball in play, BallCast's spray chart
  (left). Nothing else stays up: the old LAST card is gone. Scout's scouting card sits on the left
  while its decision is up. First use of a scheme shows its how-to card.

  Pitching, both schemes: the pitch menu first (on the pitch this pitcher threw last), then Arcade's
  aim and meter or Scout's spot. The crank doesn't pick the pitch any more.
]]

local gfx <const> = playdate.graphics
local floor, max, min, abs = math.floor, math.max, math.min, math.abs

local Live = PennantLive.Live
local F = function() return UI.fonts end

-- geometry: the zone inset on the right, the card on the left over BallCast's K-zone history
local KX, KY, KW, KH = 294, 48, 100, 100
local SX, SZ = 20, 22
local function kzx(x) return floor(KX + KW / 2 + x * SX + 0.5) end
local function kzy(z) return floor(KY + 14 + KH / 2 - 7 - z * SZ + 0.5) end
local CX, CY, CW, CH = 2, 58, 92, 92

local function P(id) local L = Pennant.L return L.players[PEng.nid(id) or -1] end
-- (polled holds count only a press made since this panel came up: app/scene.lua's input latch)
local function held(btn) return App.isHeld(btn) end

local function panel(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(x + 2, y + 2, w, h)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(x, y, w, h)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(x, y, w, h)
end

local function kzFrame(title, tag)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRect(KX, KY, KW, KH)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(KX + 2, KY + 12, KW - 4, KH - 14)
  Text.draw(title, KX + 4, Text.boxY(F().bold, KY, 12), F().bold, "white")
  if tag then
    local w = F().body:getTextWidth(tag) + 6
    gfx.setColor(gfx.kColorWhite)
    -- (a tab open into the white below: its capitals clear the strip's top by a row)
    gfx.fillRect(KX + KW - w - 2, KY + 1, w, 11)
    gfx.setColor(gfx.kColorBlack)
    Text.draw(tag, KX + KW - w + 1, KY + 2, F().body)
  end
  gfx.setColor(gfx.kColorBlack)
  local x0, x1, y0, y1 = kzx(-1), kzx(1), kzy(1), kzy(-1)
  gfx.drawRect(x0, y0, x1 - x0 + 1, y1 - y0 + 1)
  gfx.setDitherPattern(0.5, gfx.image.kDitherTypeBayer2x2)
  for k = 1, 2 do
    local gx = x0 + floor((x1 - x0) * k / 3)
    local gy = y0 + floor((y1 - y0) * k / 3)
    gfx.drawLine(gx, y0, gx, y1)
    gfx.drawLine(x0, gy, x1, gy)
  end
  gfx.setColor(gfx.kColorBlack)
end

local function hintStrip(text, y)
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(KX, y, KW, 14)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(KX, y, KW, 14)
  local s = Text.ellipsize(text, F().body, KW - 4)
  Text.draw(s, KX + 2, Text.boxY(F().body, y + 1, 12, s), F().body)
end

-- Settings --------------------------------------------------------------------------------------------------

function Live:schemeOf(side)
  local s = self.L.settings
  if side == "bat" then return s.batScheme or "arcade" end
  return s.pitchScheme or "arcade"
end

function Live:setScheme(side, v)
  local s = self.L.settings
  if side == "bat" then s.batScheme = v else s.pitchScheme = v end
end

--- Time-out menu entry: coaches -> you (Arcade) -> you (Scout) -> coaches.
function Live:cycleControl(side)
  local on = side == "bat" and self.directBat or self.directPitch
  local sch = self:schemeOf(side)
  if not on then on, sch = true, "arcade"
  elseif sch == "arcade" then sch = "scout"
  else on = false end
  if side == "bat" then self.directBat = on else self.directPitch = on end
  self:setScheme(side, sch)
  -- kept for the next game too
  local st = self.L.settings
  st.directBat, st.directPitch = self.directBat == true, self.directPitch == true
  st.playMode = (st.directBat or st.directPitch) and "play" or "manage"
  if on then Toast.show((side == "bat" and "Batting" or "Pitching") .. ": you, " .. PScheme.NAME[sch], nil) end
end

function Live:controlLabel(side)
  local on = side == "bat" and self.directBat or self.directPitch
  return (side == "bat" and "Batting: " or "Pitching: ") .. (on and ("you (" .. PScheme.NAME[self:schemeOf(side)] .. ")") or "coaches")
end

-- How-to cards (first use of each scheme and side) -----------------------------------------------------

local HELP <const> = {
  arcade_bat = { "ARCADE BATTING", {
    "D-pad: move the meet cursor onto the pitch.",
    "Tap A when the ring closes on the ball.",
    "Hold A in the windup, let go to swing: POWER.",
    "The zone marks this at-bat's pitches.  B: time out." } },
  scout_bat = { "SCOUT BATTING", {
    "Before the pitch, pick an approach:",
    "Up: sit fastball   Down: sit soft stuff",
    "Left: look in   Right: look away",
    "A: see it and swing   B: take   hold B: time out" } },
  arcade_pitch = { "ARCADE PITCHING", {
    "Pick the pitch (up/down, A): last one's ready.",
    "D-pad: aim anywhere.  A starts the meter,",
    "A again stops it: in the band for accuracy,",
    "far right reaches back (faster, wilder)." } },
  scout_pitch = { "SCOUT PITCHING", {
    "Pick the pitch (up/down, A): last one's ready.",
    "The catcher's spot is set: A throws it there.",
    "D-pad: one of 13 spots.  Hold A: reach back.",
    "The card on the left scouts the hitter." } },
}

function Live:maybeHelp(key)
  local s = self.L.settings
  s.seenHelp = s.seenHelp or {}
  if s.seenHelp[key] then return false end
  s.seenHelp[key] = true
  self.help = { key = key, t = 0 }
  return true
end

function Live:drawHelp()
  local h = HELP[self.help.key]
  local x, y, w, ht = 60, 60, 280, 110
  panel(x, y, w, ht)
  gfx.fillRect(x, y, w, 16)
  Text.draw(h[1], x + w // 2, Text.boxY(F().bold, y, 16, h[1]), F().bold, "white", "center")
  for i, l in ipairs(h[2]) do Text.draw(l, x + 10, y + 22 + (i - 1) * 15, F().body) end
  Text.draw("A: play ball", x + w - 8, y + ht - 16, F().bold, nil, "right")
end

-- The scouting card (Scout's decisions) -------------------------------------------------------------------

function Live:drawCard()
  local c = self.card
  if not c then return end
  local x, y, w, h = CX, CY, CW, c.h or CH
  panel(x, y, w, h)
  gfx.fillRect(x, y, w, 13)
  Text.draw(c.title or "SCOUT", x + 3, Text.boxY(F().bold, y, 13, c.title or "SCOUT"), F().bold, "white")
  local yy = y + 15
  for _, l in ipairs(c.lines) do
    if type(l) == "table" then
      -- a name: inverted
      gfx.fillRect(x + 2, yy - 1, w - 4, 14)
      local s = Text.ellipsize(l[1], F().bold, w - 8)
      Text.draw(s, x + w // 2, Text.boxY(F().bold, yy - 1, 14, s), F().bold, "white", "center")
      yy = yy + 15
    else
      Text.draw(Text.ellipsize(l, F().body, w - 6), x + 3, yy, F().body)
      yy = yy + 13
    end
  end
end

function Live:setCard(c)
  local hh = 17
  for _, l in ipairs(c.lines) do hh = hh + (type(l) == "table" and 15 or 13) end
  c.h = math.max(CH, hh)
  self.card = c
  self.cardKey = (self.cardKey or 0) + 1
end

-- This at-bat's pitches on our zone -------------------------------------------------------------------------

-- a pitch's spot on the zone panels (the same mapping as the ball in Arcade batting)
local function markXY(p)
  local x = max(KX + 9, min(KX + KW - 15, kzx((p.px or 0) / 0.83)))
  local y = max(KY + 22, min(KY + KH - 9, kzy((p.pz or 2.5) - 2.5)))
  return x, y
end

--- A transparent layer over the zone panel: the at-bat's pitches the picture has shown (BallCast's
--- K-ZONE list; Arcade batting's provisional pitch left out), numbered, the latest ringed. Made
--- when a pitch is added, blitted every frame.
function Live:drawMarks(scene, bi, tau)
  local O = BallCast.TVOverlay
  local tl = scene.tl
  if not (O and O.atBat and O.stampAt and tl and bi) then return end
  local skip = self.prov and tl.beats[self.prov.beat] or nil
  self.mkList = self.mkList or {}
  local list, n, pa = O.atBat(tl, bi, tau, skip, self.mkList)
  if n == 0 then return end
  local key = pa .. ":" .. n .. ":" .. tostring(list[n])
  if self.mkKey ~= key or not self.mkImg then
    local img = gfx.image.new(KW, KH, gfx.kColorClear)
    gfx.pushContext(img)
    gfx.setDrawOffset(-KX, -KY)
    for i = 1, n do
      local x, y = markXY(list[i].plan.pitch)
      if i == n then
        -- the latest: ringed
        gfx.setColor(gfx.kColorWhite)
        gfx.fillCircleAtPoint(x, y, 8)
        gfx.setColor(gfx.kColorBlack)
        gfx.drawCircleAtPoint(x, y, 7)
      elseif list[i].e.r ~= "B" then
        -- (a white halo: the markers sit on Scout's spot boxes too)
        gfx.setColor(gfx.kColorWhite) gfx.fillCircleAtPoint(x, y, 5)
      end
      O.stampAt(i, list[i].e.r, x, y)
    end
    gfx.setDrawOffset(0, 0)
    gfx.popContext()
    self.mkImg, self.mkKey = img, key
  end
  self.mkImg:draw(KX, KY)
end

-- Batting ---------------------------------------------------------------------------------------------------

--- frame() for a "bat" pause the player handles. Returns a playback rate multiplier.
function Live:batFrame(scene, bi, b, tau, p)
  local tl = scene.tl
  local sch = self:schemeOf("bat")
  if self.help then return nil end
  if not self.helpDone then self.helpDone = {} end
  if not self.helpDone[sch .. "_bat"] then
    self.helpDone[sch .. "_bat"] = true
    if self:maybeHelp(sch .. "_bat") then return nil end
  end
  if sch == "scout" then return self:scoutBatFrame(scene, p) end
  return self:arcadeBatFrame(scene, bi, b, tau, p)
end

-- Arcade: the provisional pitch flies; the cursor and the ring; A or hold-A-release swings.
function Live:arcadeBatFrame(scene, bi, b, tau, p)
  local tl = scene.tl
  if not self.prov then
    local pt, i = p.pitch, p.info
    local r = (pt.zone or 3) <= 1 and "C" or "B"
    local e = { k = "p", t = pt.t, v = pt.v, z = pt.zone, r = r, b = i.balls + (r == "B" and 1 or 0), s = i.strikes + (r == "C" and 1 or 0), px = pt.px, pz = pt.pz }
    scene:feed({ e })
    self.prov = { beat = #tl.beats, pitch = pt }
    local bat = P(i.batter.id)
    self.ui = { kind = "bat_arcade", cx = self.lastCx or 0, cz = self.lastCz or 0, con = bat and bat.r.con or 50, power = false }
  end
  local u = self.ui
  local pb = tl.beats[self.prov.beat]
  if bi ~= self.prov.beat or not pb or not pb.plan.pitch then return nil end
  local pp = pb.plan.pitch
  u.tau, u.plan = tau, pb.plan
  local step = 0.07
  if held(playdate.kButtonUp) then u.cz = min(1.6, u.cz + step) elseif held(playdate.kButtonDown) then u.cz = max(-1.6, u.cz - step) end
  if held(playdate.kButtonLeft) then u.cx = max(-1.6, u.cx - step) elseif held(playdate.kButtonRight) then u.cx = min(1.6, u.cx + step) end
  -- holding A from the windup: the power swing is loaded; the release swings
  if u.charging then u.power = true end
  if tau > pp.tPlate + 0.15 and not u.swung then
    -- took it (or held the power swing too long)
    self.lastCx, self.lastCz = u.cx, u.cz
    self.h:bat({ swing = false })
    self:resumeEvs(scene, true)
    return nil
  end
  if tau > pp.tRel - 0.25 and tau < pp.tPlate + 0.2 then return 0.6 end
  return nil
end

function Live:arcadeSwing(scene, power)
  local u = self.ui
  local pb = scene.tl.beats[self.prov.beat]
  local pp = pb.plan.pitch
  local tau = scene.t - pb.start
  u.swung = true
  local pt = self.prov.pitch
  local raw = { dt = tau - pp.tPlate, cx = u.cx, cz = u.cz, bx = pt.px, bz = pt.pz, power = power }
  local input = PScheme.arcadeBat(raw, u.con)
  self.lastCx, self.lastCz = u.cx, u.cz
  self.h:bat(input)
  self:resumeEvs(scene, true)
end

function Live:arcadeBatInput(scene, btn, change)
  local u = self.ui
  local pb = scene.tl.beats[self.prov.beat]
  local pp = pb.plan.pitch
  local tau = scene.t - pb.start
  if btn == "crank" then u.cz = max(-1.6, min(1.6, u.cz + (change or 0) / 180)) return true end
  if btn == "B" then self:openMenu() return true end
  if u.swung then return true end
  if btn == "A" then
    if tau < pp.tRel then u.charging = true Sfx.tick() return true end   -- loading the power swing
    self:arcadeSwing(scene, false)
    return true
  end
  if btn == "AUp" and u.charging then
    u.charging = false
    if tau >= pp.tRel - 0.05 then self:arcadeSwing(scene, true) else u.power = false end
    return true
  end
  return true
end

function Live:drawArcadeBat(scene, bi, b, tau)
  local u = self.ui
  local pp = u.plan and u.plan.pitch
  local pw, ch = u.power and true or false, u.charging and true or false
  self:cached("ab" .. tostring(pw) .. tostring(ch), KX, KY - 1, KW + 2, KH + 18, function()
    kzFrame(pw and "POWER" or "AT BAT", "ARCADE")
    hintStrip(ch and "POWER loaded..." or "A swing  hold: power", KY + KH + 2)
  end, "control")
  self:drawMarks(scene, bi, tau)
  -- the meet cursor: its size is the batter's real aim window (smaller on a power swing)
  local hw = PScheme.cursorHalf(u.con, u.power)
  local x0, x1 = kzx(u.cx - hw), kzx(u.cx + hw)
  local y0, y1 = kzy(u.cz + hw), kzy(u.cz - hw)
  gfx.setLineWidth(2)
  gfx.drawRect(x0, y0, x1 - x0, y1 - y0)
  gfx.setLineWidth(1)
  local mx, my = kzx(u.cx), kzy(u.cz)
  gfx.drawLine(mx - 2, my, mx + 2, my) gfx.drawLine(mx, my - 2, mx, my + 2)
  -- the ball, and the ring closing on it at the plate
  if pp and tau >= pp.tRel and tau <= pp.tPlate + 0.2 then
    local bx, by, bz = BallCast.Play.ballAt(u.plan, min(tau, pp.tPlate))
    if bx then
      local nx, nz = bx / 0.83, bz - 2.5
      local cx, cy = max(KX + 4, min(KX + KW - 4, kzx(nx))), max(KY + 14, min(KY + KH - 4, kzy(nz)))
      gfx.setColor(gfx.kColorWhite)
      gfx.fillCircleAtPoint(cx, cy, 4)
      gfx.setColor(gfx.kColorBlack)
      gfx.drawCircleAtPoint(cx, cy, 4)
      gfx.fillCircleAtPoint(cx, cy, 2)
      local left = max(0, pp.tPlate - tau) / max(0.05, pp.tPlate - pp.tRel)
      local r = floor(5 + left * 22)
      gfx.drawCircleAtPoint(cx, cy, r)
      if left < 0.12 then gfx.drawCircleAtPoint(cx, cy, r + 2) end
    end
  end
end

-- Scout: an approach before the pitch; the swing comes out of the mapping.
local APPROACH <const> = { up = { "fast", "SIT FB" }, down = { "soft", "SIT SOFT" }, left = { "in", "LOOK IN" }, right = { "away", "LOOK AWAY" }, A = { "see", "SEE IT" } }
function Live:scoutBatFrame(scene, p)
  if not self:caughtUp(scene) then return nil end
  if not self.ui then
    local i = p.info
    self.ui = { kind = "bat_scout", t = 0 }
    self:setCard(self:scoutCard(i))
  end
  local u = self.ui
  u.t = u.t + 1
  -- B: a tap takes the pitch, a hold calls time
  -- (a hold cut short by the input latch, a menu or screen over it, is no tap: App.latches)
  if held(playdate.kButtonB) then
    if not u.bHeld then u.bLatch = App.latches.B end
    u.bHeld = (u.bHeld or 0) + 1
    if u.bHeld == 15 then self:openMenu() end
  elseif u.bHeld then
    local hold = u.bHeld
    u.bHeld = nil
    if hold < 15 and u.bLatch == App.latches.B then self:scoutChoose(scene, "take") end
  end
  return nil
end

--- The scouting card before the pitch: what this pitcher throws (this game) and the hitter.
function Live:scoutCard(i)
  local pit = P(i.pitcher.id)
  local bat = P(i.batter.id)
  local mix = self.mix and self.mix[i.pitcher.id] or {}
  local tot, best, bn = 0, nil, 0
  for k, n in pairs(mix) do tot = tot + n if n > bn then best, bn = k, n end end
  local lines = {}
  lines[#lines + 1] = (pit and pit.ln or "") .. " " .. (i.pitcher.throws or "")
  if tot > 0 then lines[#lines + 1] = best .. " " .. floor(bn * 100 / tot + 0.5) .. "% (" .. tot .. ")" else lines[#lines + 1] = "first look" end
  if pit then lines[#lines + 1] = "best: " .. ((pit.pitches[2] and pit.pitches[2].k) or pit.pitches[1].k) end
  if bat then
    lines[#lines + 1] = { PM.short(bat) }
    lines[#lines + 1] = PM.rate3(PM.avg(bat.st.b)) .. " " .. (bat.st.b.hr or 0) .. " HR"
    lines[#lines + 1] = "eye " .. PM.grade(bat.r.eye) .. "  con " .. PM.grade(bat.r.con)
  end
  return { title = "SCOUT", lines = lines }
end

function Live:scoutChoose(scene, choice)
  local p = self.pause
  local i = p.info
  local bat = P(i.batter.id)
  local pt = p.pitch
  self.rng = self.rng or PRng.new(playdate.getSecondsSinceEpoch())
  local input, note = PScheme.scoutBat(choice, pt, { con = bat and bat.r.con or 50, eye = bat and bat.r.eye or 50, bats = i.batter.bats, strikes = i.strikes }, self.rng)
  self.h:bat(input)
  self:resumeEvs(scene, false)
  Sfx.select()
end

function Live:scoutBatInput(scene, btn)
  if btn == "B" then return true end   -- (handled in the frame: tap = take, hold = time out)
  local a = APPROACH[btn]
  if a then self:scoutChoose(scene, a[1]) return true end
  return true
end

function Live:drawScoutBat()
  -- the approach around the zone: up/down sit on a pitch, left/right look in/away (the zone keeps
  -- this at-bat's pitches: drawMarks)
  kzFrame("APPROACH", "SCOUT")
  local cx = KX + KW // 2
  local x0, x1, y0, y1 = kzx(-1), kzx(1), kzy(1), kzy(-1)
  local function lab(t, x, y, al) Text.draw(t, x, y, F().body, nil, al) end
  lab("\u{25b2} SIT FB", cx, KY + 18, "center")
  lab("\u{25bc} SIT SOFT", cx, y1 + 3, "center")
  local my = (y0 + y1) // 2
  lab("\u{25c0}", KX + 4, my - 12)
  lab("IN", KX + 4, my)
  lab("\u{25b6}", KX + KW - 4, my - 12, "right")
  lab("AWAY", KX + KW - 4, my, "right")
  hintStrip("A: see it  B: take", KY + KH + 2)
  hintStrip("hold B: time out", KY + KH + 17)
end

-- Pitching --------------------------------------------------------------------------------------------------

function Live:pitchFrame(scene, p)
  if not self:caughtUp(scene) then return nil end
  local sch = self:schemeOf("pitch")
  if self.help then return nil end
  self.helpDone = self.helpDone or {}
  if not self.helpDone[sch .. "_pitch"] then
    self.helpDone[sch .. "_pitch"] = true
    if self:maybeHelp(sch .. "_pitch") then return nil end
  end
  local i = p.info
  if not self.ui then
    -- first the pitch menu, on the one this pitcher threw last (a fastball to start the game)
    local ars = i.arsenal or {}
    self.rng = self.rng or PRng.new(playdate.getSecondsSinceEpoch())
    local callType, callSpot = PScheme.catcherCall(ars, i.balls, i.strikes, i.batter.bats, self.rng)
    self.lastPitch = self.lastPitch or {}
    local last = self.lastPitch[i.pitcher.id] or "FB"
    local k, ck = 1, 1
    for n, a in ipairs(ars) do
      if a.kind == last then k = n end
      if a.kind == callType then ck = n end
    end
    self.ui = { kind = "pitch_menu", sch = sch, ars = ars, k = k, call = { k = ck, spot = callSpot }, t = 0,
      count = (i.balls or 0) .. "-" .. (i.strikes or 0), lefty = i.pitcher.throws == "L" }
    if sch == "scout" then self:setCard(self:batterCard(i)) end
  end
  local u = self.ui
  u.t = u.t + 1
  if u.kind == "pitch_arcade" then
    if u.stage == "aim" then
      local step = 0.05
      if held(playdate.kButtonLeft) then u.x = max(-1.8, u.x - step) elseif held(playdate.kButtonRight) then u.x = min(1.8, u.x + step) end
      if held(playdate.kButtonUp) then u.z = min(1.8, u.z + step) elseif held(playdate.kButtonDown) then u.z = max(-1.8, u.z - step) end
    else
      u.m = (u.m or 0) + 1
    end
  elseif u.aDown then
    u.aHeld = (u.aHeld or 0) + 1
  end
  return nil
end

--- Arcade meter position 0..1 (sweeps right then back, about 1.2 s a round trip).
local function meter(u)
  local ph = ((u.m or 0) % 36) / 36
  return ph < 0.5 and ph * 2 or (1 - ph) * 2
end

function Live:throw(scene, input, target)
  local i = self.pause.info
  local pit = P(i.pitcher.id)
  self.h:pitch(input)
  self:resumeEvs(scene, false)
  Sfx.select()
end

--- The pitch menu: up/down, A picks (on to the scheme's aim / spot step), B is time out.
function Live:pitchMenuInput(scene, btn)
  local u = self.ui
  if btn == "B" then self:openMenu() return true end
  local n = max(1, #u.ars)
  if btn == "up" then u.k, u.key = (u.k - 2) % n + 1, nil Sfx.focus() return true end
  if btn == "down" then u.k, u.key = u.k % n + 1, nil Sfx.focus() return true end
  if btn ~= "A" then return true end
  local i = self.pause.info
  local a = u.ars[u.k]
  self.lastPitch[i.pitcher.id] = a and a.kind or nil
  if u.sch == "scout" then
    self.ui = { kind = "pitch_scout", ars = u.ars, k = u.k, spot = u.call.spot, call = u.call, t = 0 }
  else
    local pit = P(i.pitcher.id)
    local x, z = PScheme.spotXY(u.call.spot)
    self.ui = { kind = "pitch_arcade", ars = u.ars, k = u.k, x = self.lastX or x, z = self.lastZ or z, stage = "aim", t = 0, command = pit and pit.r.ctl or 50 }
  end
  Sfx.select()
  return true
end

function Live:arcadePitchInput(scene, btn, change)
  local u = self.ui
  if btn == "B" then self:openMenu() return true end
  if u.stage == "aim" then
    if btn == "A" then u.stage = "meter" u.m = 0 Sfx.select() return true end
    return true
  end
  if btn == "A" then
    local a = u.ars[u.k]
    local m = meter(u)
    self.lastX, self.lastZ = u.x, u.z
    self.rng = self.rng or PRng.new(playdate.getSecondsSinceEpoch())
    local input = PScheme.arcadePitch({ type = a and a.kind, x = u.x, z = u.z }, m, u.command, self.rng)
    self:throw(scene, input, { x = u.x, z = u.z })
    return true
  end
  return true
end

function Live:scoutPitchInput(scene, btn, change)
  local u = self.ui
  if btn == "B" then self:openMenu() return true end
  local dirs = { up = { 0, -1 }, down = { 0, 1 }, left = { -1, 0 }, right = { 1, 0 } }
  local d = dirs[btn]
  if d then
    -- move on the 5x5 layout to the next spot in that direction
    local r0, c0
    for r, row in ipairs(PScheme.GRID) do for c, v in ipairs(row) do if v == u.spot then r0, c0 = r, c end end end
    local r, c = r0 + d[2], c0 + d[1]
    while r >= 1 and r <= 5 and c >= 1 and c <= 5 do
      local v = PScheme.GRID[r][c]
      if v ~= 0 then u.spot = v Sfx.tick() break end
      r, c = r + d[2], c + d[1]
    end
    return true
  end
  if btn == "A" then u.aDown = true u.aHeld = 0 return true end
  if btn == "AUp" and u.aDown then
    u.aDown = false
    local a = u.ars[u.k]
    local input = PScheme.scoutPitch(a and a.kind or "FB", u.spot, (u.aHeld or 0) >= 12)
    self:throw(scene, input, { x = input.x, z = input.z })
    return true
  end
  return true
end

--- Scouting the hitter (Scout pitching's left card).
function Live:batterCard(i)
  local bat = P(i.batter.id)
  local lines = {}
  if bat then
    lines[#lines + 1] = PM.short(bat) .. " " .. (i.batter.bats or "")
    lines[#lines + 1] = PM.rate3(PM.avg(bat.st.b)) .. " " .. (bat.st.b.hr or 0) .. " HR"
    lines[#lines + 1] = "power " .. PM.grade(bat.r.pow)
    lines[#lines + 1] = "contact " .. PM.grade(bat.r.con)
    lines[#lines + 1] = bat.r.eye < 45 and "chases away" or (bat.r.eye > 58 and "patient" or "average eye")
  end
  return { title = "SCOUT", lines = lines }
end

function Live:drawArcadePitch(scene, bi, tau)
  local u = self.ui
  local a = u.ars[u.k]
  -- the frame, the hint and the meter's bands are static: one cached image; the crosshair and the
  -- marker are drawn live
  self:cached("ap" .. u.k .. u.stage, KX, KY - 1, KW + 2, KH + 32, function()
    kzFrame("PITCH", "ARCADE")
    local y = KY + KH + 2
    hintStrip((a and (a.kind .. " " .. (a.velo or "") .. "  ") or "") .. (u.stage == "aim" and "A: meter" or "A: stop"), y)
    y = y + 15
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(KX, y, KW, 12)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(KX, y, KW, 12)
    local half = PScheme.band(u.command) / 2
    local bx0, bx1 = KX + floor((PScheme.BAND_C - half) * KW), KX + floor((PScheme.BAND_C + half) * KW)
    gfx.setPattern(UI.pat.gray)
    gfx.fillRect(bx0, y + 1, bx1 - bx0, 10)
    gfx.setColor(gfx.kColorBlack)
    gfx.fillRect(KX + floor(0.92 * KW), y + 1, KW - floor(0.92 * KW) - 1, 10)
  end, "control")
  self:drawMarks(scene, bi, tau)
  local cx, cy = kzx(u.x), kzy(u.z)
  gfx.drawCircleAtPoint(cx, cy, 6)
  gfx.drawLine(cx - 9, cy, cx - 3, cy) gfx.drawLine(cx + 3, cy, cx + 9, cy)
  gfx.drawLine(cx, cy - 9, cx, cy - 3) gfx.drawLine(cx, cy + 3, cx, cy + 9)
  local y = KY + KH + 17
  if u.stage == "meter" then
    local mx = KX + floor(meter(u) * (KW - 2)) + 1
    gfx.setColor(gfx.kColorWhite)
    gfx.fillRect(mx - 2, y - 2, 5, 16)
    gfx.setColor(gfx.kColorBlack)
    gfx.drawRect(mx - 2, y - 2, 5, 16)
  end
end

function Live:drawScoutPitch()
  local u = self.ui
  kzFrame("PITCH", "SCOUT")
  for n = 1, 13 do
    local x, z = PScheme.spotXY(n)
    local sx, sy = kzx(x), kzy(z)
    local on = n == u.spot
    if on then gfx.fillRect(sx - 6, sy - 6, 13, 13) else gfx.drawRect(sx - 5, sy - 5, 11, 11) end
    if n == u.call.spot then Text.draw("C", sx + 1, Text.boxY(F().bold, sy - 6, 13), F().bold, on and "white" or nil, "center") end
  end
  -- the pitches, the catcher's call marked
  local y = KY + KH + 2
  local rows = (#u.ars + 1) // 2
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(KX, y, KW, rows * 13 + 2)
  gfx.setColor(gfx.kColorBlack)
  gfx.drawRect(KX, y, KW, rows * 13 + 2)
  for k, a in ipairs(u.ars) do
    local on = k == u.k
    local cx, cy = KX + 1 + ((k - 1) % 2) * 49, y + 1 + ((k - 1) // 2) * 13
    if on then gfx.fillRect(cx, cy, 49, 13) end
    Text.draw(a.kind .. " " .. PM.grade(a.quality or 50) .. (k == u.call.k and "*" or ""), cx + 2, Text.boxY(F().body, cy, 13), on and F().bold or F().body, on and "white" or nil)
  end
  hintStrip(u.aDown and ((u.aHeld or 0) >= 12 and "REACH BACK!" or "hold: reach back") or "A throw *catcher", y + rows * 13 + 4)
end

-- The pitch menu (first thing up on your pitch, both schemes) ---------------------------------------------

-- each pitch's movement for the menu's glyph: across, down (BallCast's BREAK, ballcast/play.lua)
local BRK <const> = { SL = { 1.0, 0.4 }, CB = { 0.5, 1.4 }, SPL = { 0, 1.2 }, CH = { -0.4, 0.7 }, SI = { -0.6, 0.5 }, CT = { 0.4, 0.2 } }
local PMH <const> = 14   -- a row

--- A 9 x 11 glyph: the ball's path in from the top (straight for a fastball), the ball at its end.
local function moveGlyph(kind, cx, cy)
  local br = BRK[kind] or { 0, 0 }
  local ex = cx + floor(br[1] * 3.5 + 0.5)
  local ey = cy - 1 + floor(br[2] * 3 + 0.5)
  gfx.drawLine(cx, cy - 5, ex, ey)
  gfx.fillCircleAtPoint(ex, ey, 2)
end

local function pitchMenuH(u) return 14 + max(1, #u.ars) * PMH + 15 end

function Live:drawPitchMenu()
  local u = self.ui
  local x, y, w = KX, KY, KW
  local h = pitchMenuH(u)
  panel(x, y, w, h)
  gfx.fillRect(x, y, w, 13)
  Text.draw("PITCH", x + 4, Text.boxY(F().bold, y, 13), F().bold, "white")
  Text.draw(u.count, x + w - 4, Text.boxY(F().bold, y, 13, u.count), F().bold, "white", "right")
  local scout = u.sch == "scout"
  for k, a in ipairs(u.ars) do
    local on = k == u.k
    local ry = y + 14 + (k - 1) * PMH
    if on then gfx.fillRect(x + 1, ry, w - 2, PMH) end
    gfx.setColor(on and gfx.kColorWhite or gfx.kColorBlack)
    moveGlyph(a.kind, x + 8, ry + 7)
    local f = on and F().bold or F().body
    local col = on and "white" or nil
    local nm = (PM.PITCH_NAME[a.kind] or a.kind) .. ((scout and k == u.call.k) and "*" or "")
    Text.draw(Text.ellipsize(nm, f, w - 40), x + 16, Text.boxY(f, ry, PMH, nm), f, col)
    local g = PM.grade(a.quality or 50)
    Text.draw(g, x + w - 4, Text.boxY(f, ry, PMH, g), f, col, "right")
    gfx.setColor(gfx.kColorBlack)
  end
  -- the one on the cursor: its velocity (and Scout's catcher)
  local a = u.ars[u.k]
  local fy = y + h - 14
  gfx.drawLine(x + 2, fy - 1, x + w - 3, fy - 1)
  local s = (a and a.velo and (a.velo .. " mph") or "") .. (scout and "  *catcher" or "")
  Text.draw(Text.ellipsize(s, F().body, w - 6), x + 4, Text.boxY(F().body, fy, 13, s), F().body)
  hintStrip("A pick  B time out", y + h + 3)
end

--- After your pitch or your swing, while the pitch plays: the zone panel again with the at-bat's
--- pitches (BallCast's own K-ZONE on the left is off in a half you play, Live:updateHideKzone) and
--- the call with the count under it for a moment (BallCast's words, TVOverlay.callWord).
function Live:drawTrack(scene, bi, b, tau)
  local O = BallCast.TVOverlay
  local pp = b.plan and b.plan.pitch
  -- (BallCast's SWING CAM picture-in-picture takes the corner after a big swing: it has the pitch)
  if not pp or (O and O.pipActive) then return end
  local t0 = b.plan.callT or (pp.tPlate + 0.2)
  local word = (tau >= t0 and tau <= t0 + 2.2 and O and O.callWord) and O.callWord(b.e) or nil
  local title = self.ctlBat and "AT BAT" or "PITCH"
  self:cached("tr" .. title .. (word or ""), KX, KY - 1, KW + 2, KH + 18, function()
    kzFrame(title, nil)
    if word then hintStrip(word, KY + KH + 2) end
  end, "control")
  self:drawMarks(scene, bi, tau)
end

-- Dispatch helpers used by live.lua ----------------------------------------------------------------------

function Live:controlInput(scene, btn, change)
  local u = self.ui
  if self.help then
    if btn == "A" then self.help = nil Sfx.select() end
    return true
  end
  if not u then return false end
  if u.kind == "bat_arcade" then
    if scene.tl and self.prov and scene:curBeatIndex() == self.prov.beat then return self:arcadeBatInput(scene, btn, change) end
    if btn == "B" then self:openMenu() end
    -- (the last play still running before your pitch: A cuts ahead, at most to its windup)
    local pb = btn == "A" and self.prov and scene.tl and scene.tl.beats[self.prov.beat]
    if pb then self:nextShot(scene, pb.start) end
    return true
  end
  if u.kind == "bat_scout" then return self:scoutBatInput(scene, btn) end
  if u.kind == "pitch_menu" then return self:pitchMenuInput(scene, btn) end
  if u.kind == "pitch_arcade" then return self:arcadePitchInput(scene, btn, change) end
  if u.kind == "pitch_scout" then return self:scoutPitchInput(scene, btn, change) end
  return false
end

--- (frame hook) BallCast's own K-zone inset (left) and its call tab stay hidden while one of our
--- panels is up or a how-to card covers its spot, and all through a half where you bat or pitch
--- yourself: the zone lives in the control panel then (Live:drawTrack while a pitch plays). Watching
--- (the coaches' half, manage mode, simming) keeps BallCast's inset. b: the beat on screen.
function Live:updateHideKzone(b)
  local u = self.ui
  local panel = u and u.kind ~= "dugout"
  local bat, ctl = false, false
  local pre = b and b.pre
  if pre and not self.simming then
    bat = (pre.top and self.side == "away") or ((not pre.top) and self.side == "home")
    ctl = (bat and self.directBat) or ((not bat) and self.directPitch)
  end
  self.ctlHalf, self.ctlBat = ctl and true or false, bat and true or false
  self.hideKzone = (self.help ~= nil) or (panel and true or false) or self.ctlHalf
end

function Live:drawControl(scene, bi, b, tau)
  if self.help then self:cached("help" .. self.help.key, 60, 60, 283, 113, function() self:drawHelp() end) return end
  local u = self.ui
  local up = false
  if u and u.kind == "bat_arcade" and self.prov and bi == self.prov.beat then
    self:drawArcadeBat(scene, bi, b, tau)
  elseif u and u.kind == "bat_scout" and self:caughtUp(scene) then
    self:cached("sb", KX, KY - 1, KW + 2, KH + 34, function() self:drawScoutBat() end, "control")
    self:drawMarks(scene, bi, tau)
    up = true
  elseif u and u.kind == "pitch_menu" and self:caughtUp(scene) then
    -- (keyed by the pause too: the count and the pitcher change under the same cursor)
    u.key = u.key or ("pm" .. tostring(self.pause) .. u.k)
    self:cached(u.key, KX, KY, KW + 2, pitchMenuH(u) + 18, function() self:drawPitchMenu() end, "control")
    up = u.sch == "scout"
  elseif u and u.kind == "pitch_arcade" and self:caughtUp(scene) then
    self:drawArcadePitch(scene, bi, tau)
  elseif u and u.kind == "pitch_scout" and self:caughtUp(scene) then
    local rows = (#u.ars + 1) // 2
    local hs = u.aDown and ((u.aHeld or 0) >= 12 and 2 or 1) or 0
    self:cached("ps" .. u.spot .. ":" .. u.k .. ":" .. hs, KX, KY - 1, KW + 2, KH + rows * 13 + 22, function() self:drawScoutPitch() end, "control")
    self:drawMarks(scene, bi, tau)
    up = true
  elseif not u and self.ctlHalf and b and b.kind == "p" then
    self:drawTrack(scene, bi, b, tau)
  end
  -- Scout's scouting card on the left, only while its decision is up (nothing stays behind)
  if up and self.card then
    self:cachedCard(function() self:drawCard() end, CX, CY, CW + 3, self.card.h + 3)
  end
end

--- A second cache slot for the card (the main one holds dugout/menu panels).
function Live:cachedCard(paint, x, y, w, h)
  if self.cardImgKey ~= self.cardKey or not self.cardImg then
    local img = gfx.image.new(w, h, gfx.kColorClear)
    gfx.pushContext(img)
    gfx.setDrawOffset(-x, -y)
    paint()
    gfx.setDrawOffset(0, 0)
    gfx.popContext()
    self.cardImg, self.cardImgKey = img, self.cardKey
  end
  self.cardImg:draw(x, y)
end
