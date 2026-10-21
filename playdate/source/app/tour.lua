-- Screenshot tour (Simulator only). If the Data folder contains "tour.flag", its first
-- line is an absolute directory path; the tour walks every screen and writes PNGs there
-- with playdate.simulator.writeToFile. Run: make tour (see playdate/Makefile).

Tour = Tour or {}

local gfx <const> = playdate.graphics

local steps = {}
local idx = 0
local wait = 0
local outDir = nil
local active = false

local perfMode = false
local acc = { n = 0, sum = 0, worst = 0 }

local function shot(name)
  if name:sub(1, 3) == "p12" or name == "p31_season_done" then
    local b = Tour.blank or { n = 0, bad = 0 }
    print(string.format("[tour] sim-screen frames %d, blank %d", b.n, b.bad))
    print(string.format("[inputprobe] states probed %d OK, %d FAIL", Tour.probe.ok, Tour.probe.fail))
  end
  if name:sub(1, 1) == "p" and acc.n > 0 and not perfMode then
    -- (pennant screens: Simulator frame cost over the settled frames before the shot)
    print(string.format("[tourperf] %-26s avg %5.1f ms  worst %3d ms", name, acc.sum / acc.n, acc.worst))
  end
  if perfMode then
    local avg = acc.n > 0 and (acc.sum / acc.n) or 0
    print(string.format("[perf] %-22s avg %5.1f ms  worst %3d ms  mem %d KB", name, avg, acc.worst, math.floor(collectgarbage("count"))))
    return
  end
  if not outDir then return end
  if Clearance and Clearance.on then Clearance.check(name) end
  local ok, e = pcall(playdate.simulator.writeToFile, gfx.getDisplayImage(), outDir .. "/" .. name .. ".png")
  print("[tour] shot " .. name .. (ok and "" or (" FAILED " .. tostring(e))))
end

local function top() return App.top() end
local function press(btn, n)
  for _ = 1, n or 1 do
    local s = top()
    if s and s[btn .. "ButtonDown"] then s[btn .. "ButtonDown"](s) end
    if s and s[btn .. "ButtonUp"] then s[btn .. "ButtonUp"](s) end
  end
end
local function crank(deg)
  local s = top()
  if s and s.cranked then s:cranked(deg, deg) end
end
local function home()
  Nav.home()
end
local function focusId(id)
  local s = top()
  if not s or not s.links then return end
  for i, l in ipairs(s.links) do
    if l.id == id then s.focus = i s.ring = nil s:ensureVisible(l) return end
  end
end
local function activate(id)
  focusId(id)
  local s = top()
  if s and s.activate then s:activate() end
end
Tour.press, Tour.crank, Tour.focusId, Tour.activate = press, crank, focusId, activate

--- step(waitFrames, fn, shotName)
local function S(w, fn, name) steps[#steps + 1] = { w = w, fn = fn, name = name } end
--- step that runs fn, then waits until cond() (checked every frame, up to maxFrames), then
--- `settle` more frames before the shot
local function U(cond, maxFrames, fn, name, settle)
  steps[#steps + 1] = { w = settle or 6, fn = fn or function() end, name = name, untilFn = cond, left = maxFrames or 300 }
end

-- Pennant '96 (offline season mode) ----------------------------------------------------------
-- Uses save slot 3 and erases it at the end. Run alone with a second line "pennant" in tour.flag.

--- The legacy layer's fixture hall (pennant/legacy.lua): in memory only (PLegacy.mem), so the
--- tour never touches the real alumni file. Nine alumni from three runs, two with legacies.
local function legacyFixture()
  local A = PLegacy.normalize({ v = PLegacy.VERSION })
  A.unlocked, A.runs, A.banked, A.seq = true, 3, 9, 9
  local function al(id, fn, ln, pos, role, grade, score, line, note, sparks, run, fin, par, face)
    A.alumni[#A.alumni + 1] = { id = id, fn = fn, ln = ln, pos = pos, role = role, grade = grade, score = score, line = line, note = note,
      sparks = sparks, run = run, runKey = "rT" .. run, year = 1995 + run, club = run == 3 and "HCL" or "ELC", fin = fin, par = par, face = face, r = {} }
  end
  local B = "\u{2022}"
  al(1, "Jack", "Paige", "SS", nil, "A", 668, ".301 " .. B .. " 31 HR", "SERIES MVP", { { k = "stat", a = "pow", s = 3 }, { k = "trait", t = "CLUTCH", s = 2 }, { k = "pennant", s = 1 } },
    3, "PENNANT", { { n = "R. Kessler", aid = 5, sp = { { k = "stat", a = "con", s = 2 } } }, { n = "D. Okafor", aid = 6, sp = { { k = "stat", a = "spd", s = 1 } } } }, 112)
  al(2, "Tom", "Morrow", "P", "SP", "S", 702, "18-6 " .. B .. " 2.71", "PITCHER OF YR", { { k = "stat", a = "ctl", s = 3 }, { k = "trait", t = "ACE", s = 3 }, { k = "pennant", s = 1 } },
    3, "PENNANT", { { n = "L. Ruiz", aid = 7, sp = { { k = "stat", a = "velo", s = 2 } } }, { n = "M. Holt", aid = 8, sp = { { k = "stat", a = "arm", s = 2 } } } }, 240)
  al(3, "Dee", "Okafor", "C", nil, "B", 604, ".274 " .. B .. " 14 HR", "41% CS", { { k = "stat", a = "arm", s = 2 }, { k = "trait", t = "CANNON", s = 2 } }, 2, "PLAYOFFS", {}, 318)
  al(4, "Rob", "Kessler", "CF", nil, "B", 611, ".288 " .. B .. " 38 SB", "SB CROWN", { { k = "stat", a = "spd", s = 2 }, { k = "trait", t = "THIEF", s = 2 } }, 2, "PLAYOFFS", {}, 455)
  al(5, "Luis", "Ruiz", "P", "RP", "B", 596, "34 SV " .. B .. " 1.98", "SAVES LEADER", { { k = "stat", a = "velo", s = 2 }, { k = "trait", t = "CLOSER", s = 2 } }, 2, "PLAYOFFS", {}, 502)
  al(6, "Mo", "Holt", "1B", nil, "C", 552, ".262 " .. B .. " 26 HR", "9 YRS IN", { { k = "stat", a = "con", s = 1 } }, 1, "5TH", {}, 610)
  al(7, "Ed", "Vance", "P", "SP", "C", 548, "11-9 " .. B .. " 3.88", "5TH", { { k = "stat", a = "sta", s = 1 } }, 1, "5TH", {}, 733)
  al(8, "Sal", "Delgado", "LF", nil, "D", 512, ".255 " .. B .. " 12 HR", "6TH", { { k = "stat", a = "eye", s = 2 } }, 1, "6TH", {}, 801)
  al(9, "Gus", "Pickles", "3B", nil, "LEGEND", 806, ".333 " .. B .. " 40 HR", "MVP", { { k = "stat", a = "pow", s = 3 }, { k = "trait", t = "SLUGGER", s = 3 }, { k = "pennant", s = 1 } },
    3, "PENNANT", { { n = "M. Holt", aid = 6, sp = { { k = "stat", a = "con", s = 1 } } } }, 922)
  A.hof.slots = PLegacy.hofSuggest(A)
  return A
end

local function buildPennant()
  local function T() return App.top() end
  local function live() return PennantLive and PennantLive.cur end
  local function bcWatching() local s = T() return s == BallCast.scene and s.mode == "watch" end
  -- the launch screen (dev runs skip it at boot; shown here on purpose)
  S(16, function() App.push(Boot.ModeSelect) end, "p00_mode_select")
  S(10, function() press("right") end, "p00b_mode_select_offline")
  S(4, function() App.pop() end, nil)
  S(10, function() if PSave then PSave.delete(3) end PLegacy.mem = PLegacy.normalize({ v = PLegacy.VERSION }) Pennant.open() end, nil)
  S(20, function() end, "p01_title")
  U(function() local t = T() return t and t.generating == false end, 600, function() PennantUI.NewGame.open({ slot = 3 }) end, nil, 4)
  S(8, function() focusId("club:HCL") press("A") end, "p02_new_club")
  -- the Week screen (home): programs, intensity, the club's units
  local function calm()
    local c = Pennant.L and Pennant.L.club
    if c then c.rewards, c.monthNote, c.goalOffer = nil, nil, nil end
  end
  local function home() calm() Pennant.toHub() if Pennant.hub then Pennant.hub:render(true) end end
  local function isA(t, S2) return t and getmetatable(t) == S2 end
  -- (run 1: the alumni hall's card, then the season opens on April's goal pick, over the Week screen)
  U(function() return isA(T(), PennantUI.Inspire) end, 300, function() T():go() end, "p02b_alumni_intro", 10)
  U(function() return Pennant.hub ~= nil and isA(T(), PennantUI.Goals) end, 300, function() local t = T() if isA(t, PennantUI.Inspire) then t.t = 99 t:AButtonDown() end end, "p03a_goal_pick", 10)
  S(30, function() local t = T() if isA(t, PennantUI.Goals) then t.t = 99 press("down") t:AButtonDown() end end, "p03_week")
  S(12, function() press("right") end, "p03b_week_arms")
  S(12, function() press("up") end, "p03c_week_arms_hard")
  S(12, function() press("right", 4) end, "p03d_week_rest")
  S(12, function() press("left", 5) press("down") end, nil)
  S(20, function() press("B") end, "p03e_office")
  S(20, function() PennantUI.ThisWeek.open({}) end, "p03f_this_week")
  S(20, function() home() PennantUI.Team.open({}) end, "p04_team")
  S(20, function() press("down", 3) press("A") end, "p05_card")
  S(15, function() local t = T() t.pg = "stats" t:render(true) end, "p05b_card_stats")
  S(20, function() home() PennantUI.Team.open({ tab = "pit" }) end, "p04b_team_pitchers")
  S(20, function() home() PennantUI.Training.open({}) end, nil)
  S(12, function() press("down", 3) press("right") press("A") press("A") end, "p06_training")
  S(4, function() PWeek.clearOwn(Pennant.L) end, nil)
  S(20, function() home() PennantUI.Lineup.open({}) end, "p07_lineup")
  S(10, function() press("A") press("down") end, "p07b_lineup_pick")
  S(10, function() press("B") T().tab = "pit" T():render() end, "p08_staff")
  S(20, function() home() PennantUI.Farm.open({}) end, "p09_farm")
  S(20, function() home() PennantUI.Trades.open({}) end, "p10_trades")
  S(20, function()
    PennantUI.TradeTable.open({ other = "STA" })
  end, nil)
  S(12, function() local t = T() local L = Pennant.L
    t.give = { L.teams.HCL.ml[5] } t.get = { L.teams.STA.farm[1] } t:render(true) end, "p11_trade_table")
  -- the week's interstitials, staged: the series plan, the globe on the way out of town, a
  -- clubhouse event (and what came of it)
  S(24, function() home() local L = Pennant.L
    local ks = PWeek.keySeries(L)
    if not ks then local g = PL.nextGame(L, L.user) ks = { opp = g.h == L.user and g.a or g.h, d0 = L.day, d1 = L.day + 2, round = 1, why = "THE CLUB ON YOUR HEELS" } end
    PennantUI.SeriesPlan.open({ stub = ks }) end, "p41_series_plan")
  S(10, function() press("right") end, "p41b_series_plan_run")
  S(6, function() local t = T() if t and t.stub then t.t = 99 t:AButtonDown() end end, nil)
  S(22, function() home() PennantUI.Travel.open({ from = "HCL", to = "ELC", quick = true }) end, "p22_travel")
  S(40, function() end, nil)
  S(20, function() local t = T() if t and t.finish then t:finish() end home() local L = Pennant.L
    local g, d = PL.nextGame(L, L.user)
    L.club.ev = { d = d, key = "bus" }
    PennantUI.Clubhouse.open({ ev = L.club.ev }) end, "p42_clubhouse")
  S(14, function() local t = T() if t and t.e then t.t = 99 press("down") t:AButtonDown() end end, "p42b_clubhouse_result")
  S(4, function() local t = T() if t and t.e then t.t = 99 t:AButtonDown() end Pennant.L.club.ev = nil end, nil)
  -- a week of baseball: the run (the wire), the featured game's pregame, then the week's report
  S(10, function() home() local c = Pennant.L.club c.prog, c.int = "bat", 2 PennantUI.runWeek() Tour.pn = { feat = false } end, nil)
  U(function()
    local t = T()
    if isA(t, PennantUI.WeekReport) then return true end
    if isA(t, PennantUI.SeriesPlan) then t.t = 99 t:AButtonDown() return false end
    if isA(t, PennantUI.Travel) then if (t.f or 0) > 10 then t:finish() end return false end
    if isA(t, PennantUI.Advance) and (t.shown or 0) >= 7 and not Tour.pn.wire then Tour.pn.wire = true shot("p12a_wire") end
    if t and t.onChoice then
      if not Tour.pn.feat then Tour.pn.feat = true Tour.pn.featF = 0 end
      Tour.pn.featF = Tour.pn.featF + 1
      if Tour.pn.featF == 12 then shot("p43_featured_game") end
      if Tour.pn.featF >= 14 then t.onChoice("sim") end
      return false
    end
    if isA(t, PennantUI.Clubhouse) or isA(t, PennantUI.Goals) or isA(t, PennantUI.Trainer) or isA(t, PennantUI.Call)
      or isA(t, PennantUI.CallUp) or isA(t, PennantUI.FrontPage) or isA(t, PennantUI.LandmarkCard) or isA(t, PennantUI.Telegram) then
      t.t = 99 if t.AButtonDown then t:AButtonDown() end if T() == t and t.AButtonDown then t:AButtonDown() end
    end
    return false
  end, 30 * 400, nil, "p44_week_report", 20)
  S(20, function() local t = T() if t and t.rep then press("B") end end, "p15_training_results")
  S(10, function() local t = T() if t and t.finish then t:finish() end end, nil)
  S(30, function() local t = T() if isA(t, PennantUI.WeekReport) then t.t = 99 t:AButtonDown() end home() end, "p16_week2")
  -- goals: a cleared goal's reward, the month's turn and the next month's pick, the ladder
  S(24, function() home() local L = Pennant.L local c = L.club
    c.goals[#c.goals + 1] = { m = 4, text = "FINISH APRIL .500 OR BETTER", state = "done", res = "14-12" }
    c.rewards = { { m = 4, text = "FINISH APRIL .500 OR BETTER" } }
    PennantUI.Goals.open({ reward = true }) end, "p45_goal_reward")
  S(24, function() local t = T() if t and t.mode then t.t = 99 press("down") t:AButtonDown() end
    local L = Pennant.L local c = L.club
    c.monthNote = { m = 4, state = "done", text = "FINISH APRIL .500 OR BETTER", next = "", nm = 5 }
    c.goalOffer = { PWeek.makeGoal(L, 5, "wins"), PWeek.makeGoal(L, 5, "series") }
    c.goal = c.goalOffer[1]
    if isA(T(), PennantUI.Goals) then App.pop() end
    PennantUI.Goals.open({ note = true }) end, "p46_goal_month")
  S(16, function() local t = T() if t and t.mode then t.t = 99 t:AButtonDown() end end, "p46b_goal_pick")
  S(8, function() local t = T() if t and t.mode then t.t = 99 press("down") t:AButtonDown() end end, nil)
  S(20, function() home() PennantUI.Goals.open({}) end, "p47_goals")
  -- the legacy layer (pennant/legacy.lua, ui/legacy.lua) on the fixture hall: a new run's legacy
  -- pick and deck, Opening Day, the deck at the programs, an inspiration, the Office's page, the
  -- Hall of Fame (the season end's screens come after awards night)
  S(20, function() home() PLegacy.mem = legacyFixture() Tour.pn.choice = nil
    PennantUI.LegacyPick.open({ L = Pennant.L, onDone = function(ch) Tour.pn.choice = ch end }) end, "p50_legacy_pick")
  S(16, function() press("left") end, "p50b_legacy_pick_slot")
  S(16, function() press("right") press("A") end, "p51_deck_pick")
  S(10, function() activate("go") end, nil)
  S(70, function() home() local L = Pennant.L
    PLegacy.beginRun(L, Tour.pn.choice or { leg = { PLegacy.mem.alumni[1], PLegacy.mem.alumni[2] }, deck = {} })
    PennantUI.Inspire.open({ mode = "opening" }) end, "p52_opening_day")
  S(20, function() local t = T() if isA(t, PennantUI.Inspire) then t.skip = true end end, "p52b_opening_day_done")
  S(20, function() local t = T() if isA(t, PennantUI.Inspire) then t.t = 99 t:AButtonDown() end
    local L = Pennant.L local R = L.run
    -- (bonds up, so a Rally Week shows; the program with the deck selected)
    for _, d in ipairs(R.deck) do R.bond[tostring(d.id)] = 86 end
    local c = L.club
    for i, k in ipairs(PWeek.PROGS) do if #PLegacy.present(L, k) > 0 then c.prog = k end end
    for i, k in ipairs(PWeek.PROGS) do for _, e in ipairs(PLegacy.present(L, k)) do if e.rally then c.prog = k end end end
    home() if Pennant.hub then Pennant.hub.sel = 1 for i, k in ipairs(PWeek.PROGS) do if k == c.prog then Pennant.hub.sel = i end end Pennant.hub.base = nil end end, "p53_week_deck")
  S(8, function() PLegacy.flash = 1 - (PLegacy.flash or 0) if Pennant.hub then Pennant.hub.frameDirty = true Pennant.hub.t = 1 end end, "p53b_week_deck_flash")
  S(36, function() local L = Pennant.L PLegacy.inspire(L, 1) PennantUI.Inspire.open({ mode = "insp", i = 1 }) end, "p54_inspiration_rolling")
  S(90, function() end, "p54b_inspiration")
  S(20, function() local t = T() if isA(t, PennantUI.Inspire) then t.t = 99 t:AButtonDown() end home() PennantUI.LegacyInfo.open({}) end, "p55_legacy_office")
  S(20, function() home() PennantUI.HallOfFame.open({}) end, "p56_hall_of_fame")
  S(20, function() home() PennantUI.AlumniHall.open({}) end, "p57_alumni_hall")
  S(6, function() home() end, nil)
  -- (a device perf run of the week screens alone: perftour.flag "pennantweek")
  if Tour.short then
    -- (the season end's reveal, on this season so far: the device perf run only, the full tour
    -- shows the real one after awards night)
    S(40, function() home() PennantUI.RunEnd.open({}) end, "p60_run_end_grades")
    S(110, function() end, "p61_run_end_sparks")
    S(20, function() press("A") press("right") press("A") end, "p62_banking")
    S(10, function() local t = T() if isA(t, PennantUI.RunEnd) then App.pop() end home() end, nil)
  end
  if Tour.short then S(20, function() home() end, "p48_week_again") S(10, function() Pennant.quit() PSave.delete(3) PLegacy.mem = nil end, nil) return end
  S(20, function() home() PennantUI.WeekReport.open({ rep = Pennant.L.club.lastRep, review = true }) end, nil)
  S(10, function() home() end, nil)
  S(20, function() PennantUI.League.open({ tab = "stand" }) end, "p17_standings")
  S(20, function() T().tab = "sched" T():render() end, "p18_schedule")
  S(20, function() T().tab = "lead" T():render() end, "p19_leaders")
  S(20, function() local L = Pennant.L local k for key, b in pairs(L.boxes) do if b.h == L.user or b.a == L.user then k = key end end
    if k then PennantUI.Box.open({ key = k }) end end, "p20_box")
  -- the Trainer's Room (a staged injury to the cleanup hitter), then the call-up ticket
  S(20, function() home() local L = Pennant.L local T = L.teams[L.user]
    local p = L.players[T.order[4]] p.inj = { k = "sprained ankle", d = 9 }
    L.trainerQ = { { id = p.id, day = L.day } } L.trainerSeen = nil
    Tour.pn = { hurt = p.id }
    PennantUI.trainerFollowUp(function() end) end, "p37_trainer")
  S(16, function() local t = T() if t and t.fixes then t.sel = 1 t:AButtonDown() end end, "p38_callup")
  S(4, function() local t = T() if t and t.AButtonDown and t ~= Pennant.hub then t:AButtonDown() end
    local p = Pennant.L.players[Tour.pn.hurt] if p then p.inj = nil end Pennant.L.trainerQ = nil home() end, nil)
  -- a club on the phone
  S(16, function() home() local L = Pennant.L
    local give, get = PRoster.aiOffer(L, L.teams[L.user], L.teams.MRL)
    if not give then give, get = L.teams[L.user].farm[1], L.teams.MRL.ml[3] end
    L.tradeCall = { from = "MRL", give = give, get = get, day = L.day }
    PennantUI.Call.open({}) end, "p39_trade_call")
  S(4, function() local t = T() if t and t.c then t.sel = 3 t:AButtonDown() end home() end, nil)
  S(16, function() Pennant.L.clinchPage = { day = Pennant.L.day } PennantUI.frontPageFollowUp(function() end) end, "p40_clinch")
  S(10, function() local t = T() if t and t.AButtonDown and t ~= Pennant.hub then t:AButtonDown() end Pennant.L.clinchPage = nil home() end, nil)
  -- the geoscape (the Office's road map now): the trip drawing itself in, drawn, a stop three to
  -- the right, the race card, the planet spun by the crank (perf runs time each)
  local function settled() local t = T() return t and t.trip and not t.anim and not t.tween end
  S(26, function() home() PennantUI.RoadMap.open({}) end, "p21a_roadmap_drawing")
  U(settled, 600, nil, "p21_roadmap", 4)
  U(settled, 600, function() press("right", 3) end, "p21b_roadmap_stop", 4)
  S(8, function() local t = T() if t and t.focus then t.focus = 6 t:paintColumn() press("A") end end, "p21c_roadmap_race")
  S(60, function() press("B") local t = T() if t then t.spin = 6 end end, "p21d_roadmap_spin")
  S(22, function() App.pop() home() PennantUI.Travel.open({ from = "HCL", to = "PEM", landmark = { key = "old_faithful", name = "Old Faithful", window = true, t = 0.35,
      text = "Old Faithful went off on schedule. The pitching coach took notes." } }) end, "p22b_flight")
  S(60, function() end, nil)
  S(14, function() local t = T() if t and t.finish then t:finish() end home() local e = PLand.byKey("rushmore")
    PennantUI.LandmarkCard.open({ lm = { key = "rushmore", name = e.name, text = "The team stopped at Mount Rushmore. The shortstop asked which one was the commissioner.", effect = "Morale is fair." } }) end, "p23_landmark")
  S(14, function() press("A") local e = PLand.byKey("eiffel_tower")
    PennantUI.LandmarkCard.open({ lm = { key = "eiffel_tower", name = e.name, text = e.lines[1]:gsub("{p}", "Moose Mullane"), effect = "Spirits are up. (Mood +1)" } }) end, "p23b_landmark")
  S(6, function() press("A") home() end, nil)
  -- game day and live games: you bat and pitch, first with the Arcade controls, then Scout
  -- (the week run's pregame for the featured game; the tour lets it sim, then opens the plain one)
  S(20, function() if PL.gameFor(Pennant.L, Pennant.L.user) then PennantUI.GameDay.open({ featured = "featured", onChoice = function() App.pop() end }) end end, "p24a_featured_game")
  S(20, function() if App.top() ~= Pennant.hub then App.pop() end Pennant.L.settings.playMode = "play" PennantUI.GameDay.open({}) end, "p24_gameday")
  local function liveGame(scheme, tag, withDugout)
    S(4, function()
      local st = Pennant.L.settings
      st.batScheme, st.pitchScheme = scheme, scheme
      st.seenHelp = {}
      Tour.pn = { shots = {} }
    end, nil)
    U(function() return bcWatching() end, 900, function()
      local t = T()
      if t and t.links then PennantLive.start("play") end
    end, nil, 30)
    U(function()
      local src = live()
      if not src then return true end
      local s = T()
      local pn = Tour.pn
      local function once(name) if not pn.shots[name] then pn.shots[name] = true shot(name) end end
      pn.f = (pn.f or 0) + 1
      -- the how-to cards: shoot each, then dismiss
      if src.help then
        pn.hf = (pn.hf or 0) + 1
        if pn.hf == 4 then once(tag .. "_help_" .. src.help.key) end
        if pn.hf >= 6 then pn.hf = 0 src:input(s, "A") end
        return false
      end
      local u = src.ui
      if u and u.kind == "bat_arcade" and src.prov and s:curBeatIndex() == src.prov.beat and u.plan then
        local pp = u.plan.pitch
        if u.tau and u.tau > pp.tRel + 0.12 then once(tag .. "_bat") end
        if u.tau and u.tau >= pp.tPlate - 0.03 and not u.swung then src:input(s, "A") pn.lastAt = pn.f pn.lastKind = "bat" end
      elseif u and u.kind == "bat_scout" and src:caughtUp(s) then
        pn.sf = (pn.sf or 0) + 1
        if pn.sf == 3 then once(tag .. "_bat") end
        if pn.sf >= 5 then pn.sf = 0 src:input(s, "up") pn.lastAt = pn.f pn.lastKind = "bat" end
      elseif u and u.kind == "pitch_arcade" and src:caughtUp(s) then
        pn.pt = (pn.pt or 0) + 1
        if pn.pt == 4 then once(tag .. "_pitch") end
        if pn.pt == 8 then u.stage = "meter" end
        if pn.pt == 14 then once(tag .. "_pitch_meter") end
        if pn.pt >= 16 then pn.pt = 0 src:input(s, "A") pn.lastAt = pn.f pn.lastKind = "pitch" end
      elseif u and u.kind == "pitch_scout" and src:caughtUp(s) then
        pn.pt = (pn.pt or 0) + 1
        if pn.pt == 4 then once(tag .. "_pitch") end
        -- the first time: hold the decision ~5 s (the world idles, the camera takes a decision angle)
        if not pn.idleShot then
          if pn.pt == 150 then once(tag .. "_pitch_idle") pn.idleShot = true end
          return false
        end
        if pn.pt == 6 then src:input(s, "A") end
        if pn.pt >= 8 then pn.pt = 0 src:input(s, "AUp") pn.lastAt = pn.f pn.lastKind = "pitch" end
      elseif u and u.kind == "dugout" and src:caughtUp(s) then
        pn.df = (pn.df or 0) + 1
        if pn.df == 4 and withDugout then once("p27_dugout") end
        -- the first call: hold ~15 s and shoot the decision angles as they come round
        if withDugout and not pn.decDone then
          if pn.df == 40 then once("p27b_decision_1") elseif pn.df == 175 then once("p27b_decision_2")
          elseif pn.df == 310 then once("p27b_decision_3") elseif pn.df == 445 then once("p27b_decision_4") end
          if pn.df >= 450 then pn.decDone = true end
          return false
        end
        if pn.df >= 6 then pn.df = 0 src:input(s, "A") end
      end
      -- the pitch tracking (pennant/control.lua, ballcast/tv/overlay.lua): a decision with the
      -- at-bat's pitches on the zone, the K-ZONE's call tab on a ball and on a strike, the spray
      -- chart on a hit and on an out, and the next at-bat's first decision with the zone cleared
      local info = src.pause and src.pause.info
      if u and info and src:caughtUp(s) and (u.kind == "pitch_arcade" or u.kind == "pitch_scout" or u.kind == "bat_scout") then
        local side = u.kind == "bat_scout" and "bat" or "pitch"
        local cnt = (info.balls or 0) + (info.strikes or 0)
        pn.dq = (pn.dq or 0) + 1
        if pn.dq == 3 then
          if cnt >= 2 and not pn.shots[tag .. "_" .. side .. "_seq"] then once(tag .. "_" .. side .. "_seq") pn.seqPa = info.batter and info.batter.id
          elseif cnt == 0 and pn.seqPa and pn.seqPa ~= (info.batter and info.batter.id) then once(tag .. "_new_ab") end
        end
      else
        pn.dq = 0
        if u and info and u.kind == "bat_arcade" and u.plan and u.tau and u.tau > u.plan.pitch.tRel + 0.3 and (info.balls or 0) + (info.strikes or 0) >= 2 then once(tag .. "_bat_seq") end
      end
      local bi = s.tl and s:curBeatIndex()
      local b = bi and s.tl.beats[bi]
      if b and not u then
        local tau = s.t - b.start
        local cam = s.curCam
        if b.kind == "p" and b.plan.pitch and (cam == "pitch" or cam == "behindPlate") then
          local t0 = b.plan.callT or (b.plan.pitch.tPlate + 0.2)
          if tau > t0 + 0.4 and tau < t0 + 0.8 then
            if b.e.r == "B" then once(tag .. "_ball") elseif b.e.r == "C" or b.e.r == "S" then once(tag .. "_strike") end
          end
        elseif b.kind == "bip" and BallCast.TVOverlay.sprayShown(b, tau) and BallCast.TVOverlay.sprayShown(b, tau - 0.5) then
          local hit = b.e.res == "1B" or b.e.res == "2B" or b.e.res == "3B" or b.e.res == "HR"
          once(tag .. (hit and "_spray_hit" or "_spray_out"))
        end
      end
      local extra = pn.f > 30 * 240 or (pn.shots[tag .. "_spray_hit"] and pn.shots[tag .. "_spray_out"] and pn.shots[tag .. "_new_ab"])
      local need = pn.shots[tag .. "_bat"] and pn.shots[tag .. "_pitch"] and pn.shots[tag .. "_ball"] and pn.shots[tag .. "_strike"] and extra
      if need and withDugout and not pn.called then pn.called = true src.callTime = true src.directBat, src.directPitch = false, false end
      return need and (not withDugout or pn.shots["p27_dugout"])
    end, 30 * 300, nil, nil, 2)
    if withDugout then S(10, function() local src = live() if src then src:openMenu() end end, "p28_timeout_menu") end
    U(function() local src = live() local s = T() return not src or (src.pause and src.pause.reason == "done" and s.tl and s:curBeatIndex() == #s.tl.beats and s.t - s.tl.beats[#s.tl.beats].start > 1.5) end,
      30 * 60, function() local src = live() if src then src.menu = nil src:simToEnd(false) end end, withDugout and "p29_final" or nil, 4)
    U(function() return T() and T().box ~= nil end, 600, function() local src = live() if src then src:finish() end end, nil, 2)
    U(function() local t = T() return t and t.state == "done" end, 600, nil, nil, 2)
    S(20, function() local t = T() if t and t.AButtonDown and t.state then t:AButtonDown() end end, withDugout and "p30_postgame" or nil)
  end
  liveGame("arcade", "p25_arcade", true)
  -- the next day (an off day sims straight through), then a Scout game
  S(10, function()
    local t = T()
    for _ = 1, 4 do t = T() if t ~= Pennant.hub and t and (t.rows or t.map2 or t.lm) and t.AButtonDown then t:AButtonDown() end end
    local c = Pennant.L.club c.rewards, c.monthNote, c.goalOffer = nil, nil, nil
    Pennant.toHub()
  end, nil)
  U(function() local t = T() return (t == Pennant.hub and PL.gameFor(Pennant.L, Pennant.L.user) ~= nil) or (t and t.state == "done") end, 30 * 60, function()
    local L = Pennant.L
    if not PL.gameFor(L, L.user) then PennantUI.Advance.open({ days = 1 }) end
  end, nil, 2)
  S(4, function() local t = T() if t and t.state == "done" then t:AButtonDown() end local c = Pennant.L.club c.rewards, c.monthNote, c.goalOffer = nil, nil, nil Pennant.toHub() end, nil)
  S(20, function() if PL.gameFor(Pennant.L, Pennant.L.user) then PennantUI.GameDay.open({}) end end, nil)
  liveGame("scout", "p26_scout", false)
  -- the rest of the season, the playoffs, awards, the offseason
  U(function() local t = T() if t and t.state == "done" and t.caughtUp then t.shown = #PWire.lines end return t and t.state == "done" end, 30 * 400, function() Pennant.toHub() PennantUI.Advance.open({ untilPhase = "awards", noStops = true }) end, "p31_season_done", 4)
  S(10, function() local t = T() if t.items then t.todoSel = #t:items() end press("A") end, nil)
  S(20, function() for _ = 1, 4 do local t = T() if t ~= Pennant.hub and t and (t.rows or t.map2 or t.lm) and t.AButtonDown then t:AButtonDown() end end
    local c = Pennant.L.club c.rewards, c.monthNote, c.goalOffer, c.wk = nil, nil, nil, nil
    local R = Pennant.L.run if R then for _, r in pairs(R.insp or {}) do r.unseen = nil end R.showOD = nil end
    Pennant.toHub() Pennant.hub:render(true) end, "p32_hub_awards")
  S(30, function() PennantUI.Awards.open({}) end, "p33_awards")
  -- (the tour's club takes the pennant, so the whole end shows: 3 keeps, the career prompt)
  S(30, function() local L = Pennant.L L.champ = L.user activate("go") end, "p60_run_end_grades")
  U(function() local t = T() return isA(t, PennantUI.RunEnd) and t.phase == "bank" end, 400, nil, "p61_run_end_sparks", 6)
  S(16, function() press("A") press("right") press("A") end, "p62_banking")
  S(24, function() press("B") press("A") end, "p63_hall_of_fame_update")
  S(24, function() local t = T() if isA(t, PennantUI.HallOfFame) then t:goBack() end end, "p64_continue_career")
  S(10, function() press("right") end, "p64b_end_run")
  U(function() local t = T() return t and getmetatable(t) == PennantUI.Offseason end, 900, function() press("left") local t = T() if isA(t, PennantUI.RunChoice) then t.t = 99 t:AButtonDown() end end, "p34_offseason", 10)
  -- (the endless career's next season: the legacy at half on Opening Day)
  S(40, function() local c = Pennant.L.club c.rewards, c.monthNote, c.goalOffer = nil, nil, nil activate("go") end, "p65_career_opening_day")
  S(20, function() local t = T() if isA(t, PennantUI.Inspire) then t.t = 99 t.skip = true t:AButtonDown() t:AButtonDown() end calm() Pennant.toHub() end, "p35_new_season")
  S(20, function() PennantUI.League.open({ tab = "hist" }) end, "p36_history")
  -- ending the run: the slot waits for a new one, the new run opens on the club pick, then the legacy
  S(30, function() Pennant.toHub() PennantUI.endRun(Pennant.L) end, nil)
  U(function() local t = T() return t and t.generating == false end, 600, nil, "p66_new_run", 4)
  S(16, function() focusId("club:HCL") press("A") activate("go") end, "p67_new_run_legacy")
  S(10, function() Pennant.quit() PSave.delete(3) PLegacy.mem = nil end, nil)
end

local function build()
  S(10, function() end, "01_boot")
  S(150, function() end, nil) -- wait for boot to reach the desktop (or the sign-up page)
  S(60, function()
    -- online run without a token: sign up with a throwaway name
    local t = top()
    if t and t.submit and t.pickName then
      t.name = "tour" .. (playdate.getSecondsSinceEpoch() % 100000)
      t:submit()
    end
  end, nil)
  S(30, function() while #App.stack > 1 and top() ~= Sites.Desktop.instance do App.pop() end end, "02_desktop")
  S(10, function() Sites.Desktop.startMenu() end, "02b_start_menu")
  S(10, function() press("A") end, "02c_start_standings")
  S(10, function() press("B") press("B") end, nil)
  S(40, function() local d = top() if d.todo then for i, r in ipairs(d.todo) do if r.glyph == "$" then focusId("todo:" .. i .. ":$") end end end activate(top().links[top().focus].id) end, "02d_todo_bobby")
  S(10, function() home() end, nil)
  S(30, function()
    -- heat 7+: the squad car (flashing: it just went up) and the hazard-tape wallpaper
    local a = Game.account
    Tour.heat = a.heat
    Game.setAccount({ id = a.id, name = a.name, money = a.money, heat = 8, crewSize = a.crewSize, unreadMail = a.unreadMail, cards = a.cards, rank = a.rank })
    Sites.Desktop.instance:render(true)
  end, "28_heat")
  S(5, function()
    local a = Game.account
    a.heat = Tour.heat or 1
    Sites.Desktop.instance:render(true)
  end, nil)
  S(30, function()
    home()
    -- the fixture's haul plus a prop and an arrest, to show every row
    local d = {}
    for k, v in pairs(Fixtures.peek("/digest")) do d[k] = v end
    d.sinceDay = (d.day or 5) - 3
    d.props = { won = 1, lost = 0, refunded = 0, net = 180, items = { { storylineId = "sl1", question = "Devlin exposed?", pick = "Yes", outcome = "Yes", net = 180 } } }
    d.arrests = { { name = "Dotty Dial", face = "face:83", status = "jailed" } }
    d.net = (d.net or 0) + 180
    Sites.Digest.show(d)
  end, "02e_while_you_were_out")
  S(4, function() press("A") end, nil)
  S(14, function() end, "02f_wywo_cash_it")
  S(40, function() local t = top() if t and t.close then t:close("cash") end
    local d = {}
    for k, v in pairs(Fixtures.peek("/digest")) do d[k] = v end
    d.bets = { won = 0, lost = 3, staked = 300, paid = 0, net = -300 }
    d.jobs = {}
    d.net = -300
    Sites.Digest.show(d)
  end, "02g_wywo_loss")
  S(4, function() local t = top() if t and t.close then t:close("later") end end, nil)
  S(30, function()
    local s = {}
    for k, v in pairs(Fixtures.peek("/news").stories[1]) do s[k] = v end
    s.id = "tour-extra" .. (Game.frame or 0)
    s.extra = true
    Sites.Extra.show(s, Fixtures.peek("/gossip"))
  end, "02h_extra")
  S(4, function() press("B") end, nil)
  -- Bobby's loyalty card and odd jobs (sites/bonus.lua): the To Do rows, the punch, the back room
  S(30, function()
    home()
    local dt = Sites.Desktop.instance
    -- a quiet day: just the card and the jobs (the fixture's other rows would fill the window)
    Tour.saved = { ev = Nav.pendingEvents, d = dt.data }
    Nav.pendingEvents = {}
    dt.data = { me = dt.data.me, news = dt.data.news, bonus = Fixtures.peek("/bonus") }
    dt:render(true)
  end, "02i_todo_bonus")
  S(4, function()
    local dt = Sites.Desktop.instance
    dt.data = Tour.saved.d
    Nav.pendingEvents = Tour.saved.ev
    dt:render(true)
  end, nil)
  S(24, function() Sites.PunchCard.open({ doc = Fixtures.peek("/bonus") }) end, "02j_punch_card")
  U(function() local t = top() return t.state == "wait" end, 60, function() press("A") end, nil, 3)
  S(0, function() end, "02k0_punch_swing")
  U(function() local t = top() return t.state == "punch" and (t.pt or -1) >= 0 end, 90, nil, "02k_punch_slam", 0)
  U(function() local t = top() return (t.pt or 0) >= 9 end, 30, nil, "02k2_punch_chad", 0)
  U(function() local t = top() return t.state == "done" end, 90, nil, "02l_punch_paid", 2)
  S(4, function() press("A") end, nil)
  S(30, function()
    -- the seventh hole: a free pack
    local b = Fixtures.peek("/bonus")
    local card = {}
    for k, v in pairs(b.card) do card[k] = v end
    card.holes, card.hole, card.punchedToday, card.streak = {}, 6, false, 13
    for i, h in ipairs(b.card.holes) do card.holes[i] = { n = h.n, reward = h.reward, cash = h.cash, packs = h.packs, stamped = i <= 6 } end
    b.card = card
    Sites.PunchCard.open({ doc = b })
  end, nil)
  U(function() local t = top() return t.state == "punch" and (t.pt or 0) >= 14 end, 120, function() press("A") end, "02m0_punch_stamp_slam", 0)
  U(function() local t = top() return t.state == "done" end, 120, nil, "02m_punch_full_card", 2)
  S(4, function() press("A") end, nil)
  S(40, function() home(); Sites.OddJobs.open() end, "02n_odd_jobs")
  S(10, function()
    local t = top()
    for _, l in ipairs(t.links or {}) do
      if l.id and l.id:find("^job:") and l.hint and l.hint:find("^A: claim") then focusId(l.id) break end
    end
  end, "02o_odd_jobs_focus")
  U(function() local t = top() return t.paidFx ~= nil and t.paidFx.t >= 2 end, 60, function() local t = top() if t.activate then t:activate() end end, "02p0_odd_jobs_stamp", 0)
  U(function() local t = top() return t.paidFx == nil end, 60, nil, "02p_odd_jobs_paid", 2)
  S(30, function() crank(300) end, "02q_odd_jobs_week")
  S(10, function()
    home()
    Pager.note("PAGE  ODD JOB DONE", "Back an underdog. Somebody has to.", "CLAIM $10 \u{25b6}A", function() Sites.OddJobs.open() end)
  end, nil)
  S(12, function() end, "02r_pager_odd_job")
  S(40, function() Sites.Bets.open() end, "03_bets")
  S(10, function() press("down", 2) end, "03b_bets_focus")
  S(10, function() local t = top() t.scroll:jump(0) t.focus = 1 press("up", 3) end, "03c_toolbar")
  S(12, function() press("right", 4) press("A") end, "03d_bookmarks")
  S(10, function() press("B") local t = top() t.tb = nil end, nil)
  S(10, function() focusId("g:" .. Fixtures.peek("/today").games[4].id) press("right") end, "03e_bets_side")
  S(30, function() press("A") end, "04_bet_slip")
  S(10, function() crank(120) press("left") end, "04b_bet_slip_cranked")
  S(30, function() press("A") end, "04c_bet_placed")
  S(30, function() press("A") end, "04d_bets_next_game")
  S(30, function() local t = top() if t.setTab then t:setTab("tickets") end end, "04e_my_tickets")
  S(10, function() press("B") end, nil)
  S(40, function() home(); Sites.Gossip.open() end, "04c_gossip")
  S(20, function() crank(500) end, "04d_gossip_props")
  S(15, function()
    local t = top()
    for _, l in ipairs(t and t.links or {}) do if l.id and l.id:find("^opt:") then focusId(l.id) break end end
  end, nil)
  S(15, function() local t = top() if t and t.activate then t:activate() end end, "04j_prop_ticket")
  S(10, function() press("B") end, nil)
  S(20, function() local t = top() if t and t.scrollToMine then t:scrollToMine() end end, "04f_gossip_mine")
  S(20, function() crank(900) end, "04g_gossip_rumors")
  S(40, function()
    home()
    local g = Fixtures.peek("/gossip")
    for _, sl in ipairs(g.storylines) do if #(sl.props or {}) > 0 then Tour.storyId = sl.id end end
    Nav.storyline(Tour.storyId)
  end, "04h_gossip_storyline")
  S(40, function() home(); Sites.News.open() end, "05_news")
  S(10, function()
    local live = Packs.json("fixtures/today-live.json")
    for _, g in ipairs(live and live.games or {}) do
      if g.myBet and g.score then Pager.page(g) break end
    end
  end, nil)
  S(12, function() end, "05b_pager")
  S(40, function() Sites.Story.open({ id = "s1" }) end, "06_story")
  S(20, function() crank(400) end, "06b_story_comments")
  S(40, function() Composer.open({ thread = "story:s1" }) end, "07_composer")
  S(10, function() press("A") end, "07b_composer_slot")
  S(10, function() crank(90); press("A") end, nil)
  S(10, function() press("A") end, "07c_composer_word")
  S(10, function() press("B"); press("B"); press("B"); press("B") end, nil)
  S(40, function() home(); Nav.person("p1") end, "08_fanpage")
  S(20, function() crank(300) end, "08b_fanpage_more")
  S(20, function() crank(600) end, "08c_fanpage_family")
  S(40, function() home(); Nav.team("HCL") end, "09_org")
  S(20, function() crank(400) end, "09b_org_roster")
  S(40, function() home(); Sites.Standings.open() end, "10_standings")
  S(40, function() home(); Sites.Standings.open({ level = "EL" }) end, "10b_standings_el")
  S(40, function() home(); Sites.Schedule.open() end, "11_scoreboard")
  S(20, function() crank(400) end, "11b_scoreboard_el")
  S(40, function() Sites.Game.open({ id = "g6201" }) end, "12_boxscore")
  S(40, function() home(); Nav.game(Fixtures.peek("/today").games[2].id) end, "12b_hub")
  S(20, function() activate("bet:home") end, "12c_hub_slip")
  S(10, function() press("B") end, nil)
  S(40, function() home(); Sites.BBS.open() end, "13_bbs")
  S(40, function() Sites.OpsPlanner.open({}) end, "14_ops")
  S(30, function() press("A") end, "14b_ops_jobs")
  S(10, function() press("down", 2) end, "14c_ops_jobs_focus")
  S(10, function() press("right") end, "14d_ops_target")
  S(20, function() press("A") end, "14e_ops_crew")
  S(10, function()
    local t = top()
    if t and t.catalog then
      for i, k in ipairs(t.catalog.kinds or {}) do if k.kind == "blackmail" then t.kindIdx = i end end
      t:fixStoryline()
      local ts = t:storyTargets(t:kind())
      if ts[1] then t.storylineId = ts[1].storylineId end
      t:render(true)
      focusId("story")
    end
  end, "14g_ops_story")
  S(10, function() focusId("go") press("A") end, nil)
  S(8, function() end, "14i_ops_job_on")
  S(10, function() for _ = 1, 8 do press("B") end end, nil)
  S(40, function()
    home()
    -- the gossip fixture comes from another server run: aim at a story the job catalog knows
    local cat = Fixtures.peek("/ops/catalog")
    local sl = cat and cat.storylines and cat.storylines[1]
    Nav.job({ storylineId = sl and sl.storylineId or Tour.storyId })
  end, "14h_ops_from_story")
  S(40, function() home(); Sites.Recruit.open() end, "14f_recruit")
  S(40, function() home(); Sites.Syndicate.open() end, "15_syndicate")
  S(40, function() Sites.SynBoard.open({ thread = "bbs:syn:syn1", name = "The Raccoon Lodge" }) end, "15b_syn_board")
  S(10, function() press("B") end, nil)
  S(40, function() Sites.SynLeaderboard.open() end, "16_syn_leaderboard")
  S(40, function() home(); Sites.Mail.open() end, "17_mail")
  S(30, function() press("A") end, "18_letter")
  S(30, function()
    home()
    local tip
    for _, m in ipairs(Fixtures.peek("/mail").mail) do if m.storylineId then tip = m break end end
    if tip then Sites.Letter.open({ mail = tip }) end
  end, "18b_letter_tip")
  S(30, function() home(); Sites.EventCard.show(Fixtures.peek("/events").events[1]) end, "19_event")
  S(10, function() press("B"); home(); Sites.Settings.open() end, nil)
  S(30, function() end, "20_settings")
  S(20, function() home(); Dialog.alert("Name rejected", "The League's Decency Board rejected that name.") end, "21_dialog")
  S(10, function() press("B"); Toast.show("Bet placed: $50 on the Friars", "good") end, nil)
  S(8, function() end, "22_toast")
  S(30, function() home(); Sites.Teams.open() end, "23_clubs")
  S(30, function() home(); Sites.Credits.open() end, "25_credits")
  S(40, function() home(); Nav.cards("binder") end, "26_binder")
  S(40, function() home(); Nav.cards("shop") end, "27_card_shop")
  S(10, function() home() end, nil)
  S(30, function()
    -- heat 7+: the squad car (flashing: it just went up) and the hazard-tape wallpaper
    local a = Game.account
    Tour.heat = a.heat
    Game.setAccount({ id = a.id, name = a.name, money = a.money, heat = 8, crewSize = a.crewSize, unreadMail = a.unreadMail, cards = a.cards, rank = a.rank })
    Sites.Desktop.instance:render(true)
  end, "28_heat")
  S(5, function()
    local a = Game.account
    a.heat = Tour.heat or 1
    Sites.Desktop.instance:render(true)
  end, nil)
  S(10, function() home(); Boot.Register.open() end, nil)
  S(30, function() end, "24_register")
  if Pennant then buildPennant() end
  if perfMode then
    -- BallCast at 1x on the live C renderer; frame costs bucketed by camera shot.
    -- (Checked when the step runs: optional modules load after the tour is built.)
    S(10, function()
      if not (BallCast and BallCast.scene) then print("[tour] no BallCast in this build") return end
      home(); App.push(BallCast.scene, { gameId = "g1", skipIntro = true }); Tour.bc = {}
    end, nil)
    S(30 * 45, function() end, nil)
    S(5, function()
      if not Tour.bc then return end
      local names = {}
      for k in pairs(Tour.bc) do names[#names + 1] = k end
      table.sort(names)
      for _, k in ipairs(names) do
        local b = Tour.bc[k]
        print(string.format("[perf] bc/%-19s avg %5.1f ms  worst %3d ms  frames %d", k, b.sum / b.n, b.worst, b.n))
      end
      Tour.bc = nil
      press("B")
    end, nil)
    -- the user's path: intro menu -> "watch from first pitch", then a second replay the
    -- same way (puppet art is cached across replays; [bcpup] at exit reports bad draws)
    for round = 1, 2 do
      S(20, function()
        if not (BallCast and BallCast.scene) then return end
        home(); print("[tour] intro replay " .. round); App.push(BallCast.scene, { gameId = "g1" })
      end, nil)
      S(150, function() end, nil)                 -- loader + intro card
      S(30 * 10, function() press("A") end, nil)  -- WATCH FROM FIRST PITCH, play ~10 s
      S(20, function() press("B") end, nil)       -- back out (prints [bcpup])
    end
  end
  S(10, function() Tour.finish() end, nil)
end

function Tour.isActive() return active end

function Tour.finish()
  print("[tour] done")
  active = false
  -- (auto-lock stays off after a perf run so the device is still on USB when the log is
  -- collected; the setting resets when the game is relaunched)
  if perfMode then playdate.file.delete("perftour.flag") end
  if outDir then
    local f = playdate.file.open("tour.done", playdate.file.kFileWrite)
    if f then f:write("ok\n") f:close() end
  end
end

function Tour.start()
  if playdate.file.exists("perftour.flag") then
    -- hardware perf run: same steps, no screenshots; logs frame times per screen
    -- (a first line "pennant" in the flag runs only the Pennant section)
    perfMode = true
    outDir = "perf"
    local pf = playdate.file.open("perftour.flag", playdate.file.kFileRead)
    local only = pf and pf:readline()
    if pf then pf:close() end
    if only and only:match("^pennant") then
      Tour.short = only:match("^pennantweek") ~= nil
      S(40, function() end, nil)
      buildPennant()
      S(10, function() Tour.finish() end, nil)
    else
      build()
    end
    active = true
    idx = 0
    wait = 0
    -- nobody touches the device during a perf run; keep it awake (and on USB)
    playdate.setAutoLockDisabled(true)
    print("[tour] perf mode")
    return
  end
  if not playdate.isSimulator then return end
  if not playdate.file.exists("tour.flag") then return end
  local f = playdate.file.open("tour.flag", playdate.file.kFileRead)
  local line = f and f:readline()
  local f2 = f and f:readline()
  if f then f:close() end
  local only = f2 and (f2:gsub("%s+$", "")) or nil
  print("[tour] flag: " .. tostring(line) .. " / " .. tostring(only))
  outDir = line and line:gsub("%s+$", "") or nil
  if not outDir or outDir == "" then return end
  playdate.file.delete("tour.done")
  if only == "pennant" or only == "pennantweek" then
    -- the Pennant section alone (it needs no server or fixtures); "pennantweek": the week screens only
    Tour.short = only == "pennantweek"
    S(40, function() end, nil)
    buildPennant()
    S(10, function() Tour.finish() end, nil)
  else
    build()
  end
  active = true
  Debug.showFps = false
  idx = 0
  wait = 0
  print("[tour] writing to " .. outDir)
end

--- Pennant live games own every input: in each input state (first time seen), send every input the
--- state does not allow, plus the crank everywhere, and assert BallCast's replay state didn't move
--- (game clock, beat index, speed, play/pause, game log, highlights) and nothing opened or closed.
--- In "play" it also presses A (the next camera shot) and checks the clock only went forward, no
--- further than what's been fed.
Tour.probe = { seen = {}, ok = 0, fail = 0 }
local function probeInputs()
  local src = PennantLive and PennantLive.cur
  local s = App.top()
  if not src or not BallCast or s ~= BallCast.scene or s.mode ~= "watch" or not s.tl then return end
  local st = src:inputState(s)
  local key = (src.directBat and "play:" or "manage:") .. st
  if Tour.probe.seen[key] then return end
  Tour.probe.seen[key] = true
  local allowed = PennantLive.Live.INPUT_MAP[st]
  local function snap()
    return { t = s.t, bi = s:curBeatIndex(), speed = s.speed, playing = s.playing, log = s.logOpen and true or false,
      hl = s.highlights and true or false, aDown = s.aDownAt ~= nil, menu = src.menu ~= nil, ui = src.ui and src.ui.kind or "-",
      help = src.help ~= nil, top = App.top(), n = #App.stack }
  end
  local a = snap()
  local sent = {}
  -- (B during a changeover skips it in local games: intended, so not probed then)
  local cb = s.tl.beats[s:curBeatIndex() or 1]
  local changeover = cb and cb.kind == "half"
  for _, b in ipairs({ "up", "down", "left", "right", "A", "B" }) do
    if not allowed[b] and not (b == "B" and changeover) then
      s[b .. "ButtonDown"](s)
      if b == "A" and not allowed.AUp then s:AButtonUp() end
      sent[#sent + 1] = b
    end
  end
  -- the crank never scrubs, even where it's an input (net zero turn there)
  if allowed.crank then s:cranked(30) s:cranked(-30) else s:cranked(120) s:cranked(-45) end
  sent[#sent + 1] = "crank"
  local b = snap()
  local bad = {}
  for k, v in pairs(a) do if b[k] ~= v then bad[#bad + 1] = k .. " " .. tostring(v) .. "->" .. tostring(b[k]) end end
  -- A where it's the next camera shot (watching): the clock may only move forward, to at most the
  -- end of what's been fed (the next decision); nothing else may change
  if st == "play" and allowed.A then
    local tl = s.tl
    s:AButtonDown()
    s:AButtonUp()
    local c = snap()
    if c.t < b.t or c.t > tl.total + 0.001 or (c.bi or 0) < (b.bi or 0) then bad[#bad + 1] = "A t " .. b.t .. "->" .. c.t .. " (total " .. tl.total .. ")" end
    for k, v in pairs(b) do if k ~= "t" and k ~= "bi" and c[k] ~= v then bad[#bad + 1] = "A " .. k .. " " .. tostring(v) .. "->" .. tostring(c[k]) end end
    sent[#sent + 1] = "A(next shot " .. string.format("%+.1f", c.t - b.t) .. "s)"
  end
  if #bad == 0 then Tour.probe.ok += 1 else Tour.probe.fail += 1 end
  print(string.format("[inputprobe] %-20s sent %-26s %s", key, table.concat(sent, ","), #bad == 0 and "OK" or ("FAIL " .. table.concat(bad, "; "))))
end

--- Called after each frame is drawn (from Debug.update).
function Tour.update()
  if not active then return end
  if PennantLive and PennantLive.cur and not perfMode then probeInputs() end
  -- Pennant screens must show something every frame (main.lua clears the display each frame):
  -- sample the frame just drawn; the top bar's corner is black on every Pennant screen
  if PennantUI and App.top() and getmetatable(App.top()) == PennantUI.Advance and not perfMode then
    Tour.blank = Tour.blank or { n = 0, bad = 0 }
    Tour.blank.n += 1
    local px = gfx.getWorkingImage():sample(2, 2)
    if px ~= gfx.kColorBlack then
      Tour.blank.bad += 1
      if Tour.blank.bad <= 3 then print("[tour] BLANK FRAME on the sim screen (frame " .. Tour.blank.n .. ")") end
    end
  end
  if Tour.bc and Debug.lastDt then
    local sc = App.top()
    local k = tostring(sc and ((sc.camShot and sc.camShot.name) or sc.curCam) or "?")
    local b = Tour.bc[k] or { n = 0, sum = 0, worst = 0 }
    Tour.bc[k] = b
    b.n += 1
    b.sum += Debug.lastDt
    if Debug.lastDt > b.worst then b.worst = Debug.lastDt end
  end
  if wait > 0 then
    wait -= 1
    -- measure the settled half of each wait (skip loading frames)
    if Debug.lastDt and wait < 12 then
      acc.n += 1
      acc.sum += Debug.lastDt
      if Debug.lastDt > acc.worst then acc.worst = Debug.lastDt end
    end
    return
  end
  -- take the shot for the step that just finished waiting
  local cur = steps[idx]
  if cur and cur.untilFn and cur.left > 0 then
    local ok, done = pcall(cur.untilFn)
    if not ok then print("[tour] wait error: " .. tostring(done)) done = true end
    if not done then cur.left -= 1 return end
    cur.untilFn = nil
    wait = cur.w
    return
  end
  if cur and cur.name then shot(cur.name) end
  acc.n, acc.sum, acc.worst = 0, 0, 0
  idx += 1
  local st = steps[idx]
  if not st then Tour.finish() return end
  local ok, e = pcall(st.fn)
  if not ok then print("[tour] step " .. idx .. " error: " .. tostring(e)) end
  wait = st.w
end

Debug.update = Tour.update
Tour.start()
