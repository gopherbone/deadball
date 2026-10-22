--[[ Legacy chains (pennant/test.lua's "pennant-sim.flag" line "legacy [runs] [seed] [heat] [games] [base]"):
  a run after run, each on a fresh league (seed + run x 101), the user club HCL on the rotating
  program policy (rest under 40 energy); each run banks its best (1 / 2 / 3 by finish) into an
  in-memory hall (PLegacy.mem: the real alumni file is never touched) and the next run takes the
  best two as legacies plus the deck (unlocked after run 1 whatever its finish). The policy:
  a program with a Rally Week ready, else the one the most deck alumni turned up at, else the
  next in the rotation; REST under 40 energy. "base": the same leagues with no legacy at all (the control).
  Prints per run: the record, the legacy and chemistry, the season's legacy points per rating
  (Opening Day's in brackets, against the cap), the alumni visits, the deck's weeks, the units vs
  the AI, the graded candidates, the hall.
]]

local gfx <const> = playdate.graphics
local function now() return playdate.getCurrentTimeMilliseconds() end
local function log(...) print("[pntest] " .. string.format(...)) end

local Leg = { opaque = true }
Leg.__index = Leg
function PennantTest.legacy() App.push(setmetatable({}, Leg)) end
function Leg:enter() self.co = coroutine.create(function() self:body() end) self.msg = "" end
function Leg:update()
  self.t0 = now()
  if self.co and coroutine.status(self.co) ~= "dead" then
    local ok, e = coroutine.resume(self.co)
    if not ok then log("legacy ERROR %s", tostring(e)) self.co = nil PennantTest.finish() end
  end
  gfx.clear(gfx.kColorWhite)
  Text.draw("Pennant legacy chain: " .. tostring(self.msg), 200, 110, UI.fonts.body, nil, "center")
end
function Leg:Y() if now() - self.t0 > 40 then coroutine.yield() end end

local KEYS <const> = { "con", "pow", "eye", "spd", "fld", "arm", "velo", "ctl", "stf", "sta" }

function Leg:run(i, opt)
  local G = PLegacy
  local A = G.mem
  local L = PGen.league((opt.seed or 777) + i * 101, "HCL", opt.games or 84, function() self:Y() end)
  PL.init(L)
  Pennant.L = L
  local choice = { heat = opt.heat or 0 }
  if not opt.base and G.unlocked() then
    local a, b = G.bestPair(A)
    choice.leg = { a, b }
    local legIds = { [a.id] = true }
    if b then legIds[b.id] = true end
    local pool = { alumni = {} }
    for _, x in ipairs(A.alumni) do if not legIds[x.id] then pool.alumni[#pool.alumni + 1] = x end end
    choice.deck = G.bestDeck(pool, G.deckSlots(A))
  end
  local u00 = PWeek.units(L, "HCL")
  local R = G.beginRun(L, choice)
  local od = {}
  for k, v in pairs(R.gains or {}) do od[k] = v end
  local c = L.club
  local T = L.teams.HCL
  local u0 = PWeek.units(L, "HCL")
  local rot = { "bat", "arms", "def", "gym", "farm" }
  local ri, rallies, mentorWeeks = 0, 0, 0
  while L.phase ~= "awards" do
    self.msg = "run " .. i .. " " .. PL.date(L, math.min(L.day, #L.sched))
    if not c.wk or PWeek.weekDone(L) then
      if c.wk then PWeek.endWeek(L) end
      if c.goalOffer then PWeek.pickGoal(L, 1) end
      while c.rewards and #c.rewards > 0 do PWeek.claim(L, "fac") end
      c.monthNote = nil
      if L.phase == "season" or PWeek.userSeries(L) then
        ri = ri % 5 + 1
        local prog = rot[ri]
        -- (like a player reading the cards: a Rally Week ready, else where the deck turned up)
        local best = 0
        for _, k in ipairs(rot) do
          local v = 0
          for _, e in ipairs(G.present(L, k)) do v = v + (e.rally and 10 or 1) end
          if v > best then prog, best = k, v end
        end
        if PWeek.energy(L) < 40 and PWeek.canRest(L) then prog = "rest" ri = ri - 1 end
        c.prog, c.int = prog, 2
        local wk = PWeek.beginWeek(L)
        if wk and wk.mentors then
          mentorWeeks = mentorWeeks + 1
          for _, e in ipairs(wk.mentors) do if e.rally then rallies = rallies + 1 end end
        end
        local ks = PWeek.keySeries(L)
        if ks then PWeek.choosePlan(L, ks, PWeek.planOptions(L, ks.opp)[1]) end
      end
    end
    for _, st in ipairs(PWeek.dueStops(L)) do
      if st.stop.id == "clubhouse" then PWeek.resolveEvent(L, PL.rng(L, 5):int(3)) end
      if st.stop.id == "inspire" then local r = R.insp["i" .. st.payload] if r then r.unseen = nil end end
    end
    L.alerts = {}
    for _, g in ipairs(PL.pending(L)) do PEng.simNow(L, g) self:Y() end
    L.trainerQ = nil
    PL.finishDay(L)
    self:Y()
  end
  PL.awards(L)
  -- the season's end: the best kept, for the next run's legacy
  local E = G.seasonEnd(L)
  local picks = {}
  for k = 1, math.min(E.slots, #E.cands) do picks[#picks + 1] = k end
  G.bank(L, opt.base and {} or picks)
  local u1 = PWeek.units(L, "HCL")
  local ai = { lineup = 0, rot = 0, pen = 0 }
  for _, cl in ipairs(PennantClubs) do
    if cl.abbr ~= "HCL" then
      local a = PWeek.units(L, cl.abbr)
      for k in pairs(ai) do ai[k] = ai[k] + a[k] / 7 end
    end
  end
  local legS = "none"
  if R.leg then
    local p = {}
    for _, a in ipairs(R.leg) do
      local sp = {}
      for _, s in ipairs(a.sparks) do sp[#sp + 1] = G.pointerShort(s) .. (s.k == "trait" and G.STARS[s.s] or "") end
      local gp = 0
      for _, x in ipairs(a.par or {}) do gp = gp + #(x.sp or {}) end
      p[#p + 1] = a.ln .. "(" .. a.grade .. ":" .. table.concat(sp, "/") .. ", +" .. gp .. " inherited)"
    end
    legS = table.concat(p, " + ") .. " chem " .. (R.chem or 0)
  end
  local gains = {}
  for _, k in ipairs(KEYS) do
    if (R.gains[k] or 0) > 0 then gains[#gains + 1] = string.format("%s %d(od %d)", k, R.gains[k], od[k] or 0) end
  end
  local ins = {}
  for k = 1, 2 do local r = R.insp["i" .. k] if r then ins[#ins + 1] = r.fired .. "/" .. #r.rows end end
  local traits = 0
  for _, id in ipairs(T.ml) do if L.players[id].tr then traits = traits + 1 end end
  log("legacy run %d %s HCL %d-%d (%s)%s heat %d | legacy %s", i, opt.base and "BASE" or "LEG ", T.w, T.l, PUI.ord(PL.rank(L, "HCL")),
    L.champ == "HCL" and " PENNANT" or (G.madePlayoffs(L) and " playoffs" or ""), R.heat, legS)
  log("legacy run %d gains %s | insp %s | traits %d | deck %d, mentor weeks %d, rallies %d", i, #gains > 0 and table.concat(gains, " ") or "-",
    #ins > 0 and table.concat(ins, ",") or "-", traits, #R.deck, mentorWeeks, rallies)
  log("legacy run %d units lineup %.1f>%.1f>%.1f rot %.1f>%.1f>%.1f pen %.1f>%.1f>%.1f (AI at the end: lineup %.1f rot %.1f pen %.1f)", i,
    u00.lineup, u0.lineup, u1.lineup, u00.rot, u0.rot, u1.rot, u00.pen, u0.pen, u1.pen, ai.lineup, ai.rot, ai.pen)
  local cs = {}
  for _, cd in ipairs(E.cands) do cs[#cs + 1] = string.format("%s %s %d %s", cd.ln, cd.grade, cd.score, G.pointerShort(cd.sparks[1])) end
  log("legacy run %d cands %s", i, table.concat(cs, ", "))
  local st = G.hofStats(A)
  log("legacy run %d hall %d alumni, banked %d, deck slots %d, FR %d (%s), unlocked %s", i, #A.alumni, A.banked, G.deckSlots(A), st.fr, st.grade, tostring(A.unlocked))
  return T.w, L.champ == "HCL", G.madePlayoffs(L)
end

function Leg:body()
  local opt = PennantTest.legOpts or {}
  PLegacy.mem = PLegacy.normalize({ v = PLegacy.VERSION })
  local tot, pn, po = 0, 0, 0
  local n = opt.runs or 8
  for i = 1, n do
    local w, champ, pl = self:run(i, opt)
    tot = tot + w
    if champ then pn = pn + 1 end
    if pl then po = po + 1 end
    Pennant.L = nil
    -- (the chain unlocks legacies after run 1 whatever the finish, so every later run has them)
    PLegacy.mem.unlocked = true
    collectgarbage("collect")
  end
  log("legacy %s heat %d: mean wins %.1f, playoffs %d/%d, pennants %d", opt.base and "BASE" or "LEG", opt.heat or 0, tot / n, po, n, pn)
  PLegacy.mem = nil
  log("done")
  PennantTest.finish()
end
