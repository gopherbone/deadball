-- The pager: live sweat while your games are ON AIR. While you have money on a game that's
-- airing, /today is polled in the background (one small GET every ~45 s through Api, held
-- while BallCast is open) and a 1990s pager slides in top-right when the score of one of
-- your games changes or it goes final:
--     PAGE  B7               PAGE  FINAL
--     HCL 3  STA 1           HCL 3  STA 1
--     YOU: $50 HCL WINNING   YOU WON ~$92
-- It hides after 3 s; A while it shows opens that game. Drawn by main.lua after the toasts.

local gfx <const> = playdate.graphics

Pager = Pager or {}

local POLL_MS <const> = 45000
local SHOW_FRAMES <const> = 90
local W <const>, H <const> = 156, 50

local lastPoll = 0
local seen = {}       -- gameId -> "away-home-status" last seen
local queue = {}      -- pages waiting their turn
local cur = nil       -- { img, gameId, t }

local function airMs()
  local c = Game.clock
  return ((c and c.msPerDay) or 1800000) * 7 // 10
end

--- My games that are on the air right now (by the clock, not the possibly stale status). First
--- pitches are staggered, so each game has its own window (firstPitchAt .. finalAt).
local function myAiring()
  local s = Game.slate
  if not s then return false end
  local now, air = Api.now(), airMs()
  for _, g in ipairs(s.games or {}) do
    if g.myBet and g.firstPitchAt and g.status ~= "final" and now >= g.firstPitchAt and now < (g.finalAt or (g.firstPitchAt + air)) + 60000 then
      return true
    end
  end
  return false
end

local function inBallCast()
  local t = App.top()
  return BallCast and BallCast.scene and t == BallCast.scene
end

--- The pager's body with three lines on the LCD (prerendered once per page).
local function pagerImage(l1, l2, l3)
  local img = gfx.image.new(W + 3, H + 3, gfx.kColorClear)
  gfx.pushContext(img)
  gfx.setColor(gfx.kColorBlack)
  gfx.fillRoundRect(3, 3, W, H, 6)
  gfx.fillRoundRect(0, 0, W, H, 6)
  -- the LCD
  gfx.setColor(gfx.kColorWhite)
  gfx.fillRect(5, 5, W - 30, H - 10)
  gfx.setColor(gfx.kColorBlack)
  Text.draw(Text.ellipsize(l1, UI.fonts.bold, W - 40), 9, 6, UI.fonts.bold)
  Text.draw(Text.ellipsize(l2, UI.fonts.bold, W - 40), 9, 19, UI.fonts.bold)
  Text.draw(Text.ellipsize(l3, UI.fonts.bold, W - 40), 9, 32, UI.fonts.bold)
  -- the buttons on the side
  gfx.setColor(gfx.kColorWhite)
  for i = 0, 2 do gfx.drawRoundRect(W - 21, 7 + i * 13, 15, 10, 3) end
  gfx.popContext()
  return img
end

local function render(g, kind)
  local sc = g.score or {}
  local mine = g.myBet.side
  local myRuns, theirRuns = sc[mine] or 0, sc[mine == "home" and "away" or "home"] or 0
  local abbr = mine == "home" and g.home.abbr or g.away.abbr
  local l1 = "PAGE  " .. (g.status == "final" and "FINAL" or Fmt.inning(sc.inning))
  local l2 = g.away.abbr .. " " .. (sc.away or 0) .. "  " .. g.home.abbr .. " " .. (sc.home or 0)
  local l3
  if g.status == "final" then
    if myRuns > theirRuns then
      local pays = g.pool and g.pool.pays and g.pool.pays[mine] or 0
      l3 = pays > 0 and ("YOU WON ~" .. Fmt.money(math.floor(g.myBet.amount * pays))) or "YOU WON"
    else
      l3 = "YOU LOST " .. Fmt.money(g.myBet.amount)
    end
  else
    local state = myRuns > theirRuns and "WINNING" or (myRuns < theirRuns and "LOSING" or "TIED")
    l3 = "YOU: " .. Fmt.money(g.myBet.amount) .. " " .. abbr .. " " .. state
  end
  return { img = pagerImage(l1, l2, l3), gameId = g.id, t = 0, final = g.status == "final", won = myRuns > theirRuns }
end

--- A /today copy came in (ours or anyone's): page for every change in a game you're on.
local function onToday(d)
  if type(d) ~= "table" or type(d.games) ~= "table" then return end
  for _, g in ipairs(d.games) do
    if g.myBet and g.score and g.status ~= "scheduled" then
      local key = (g.score.away or 0) .. "-" .. (g.score.home or 0) .. "-" .. g.status
      local before = seen[g.id]
      seen[g.id] = key
      -- the first sighting only records it (no page for a score you were already shown)
      if before and before ~= key and Nav.ready then queue[#queue + 1] = g end
    elseif g.id then
      seen[g.id] = seen[g.id] or "sched"
    end
  end
  -- the desktop's ticker leads with these scores
  local dt = Sites.Desktop and Sites.Desktop.instance
  if dt and dt.data then
    dt.data.today = d
    if dt.buildTicker then dt:buildTicker() end
    dt.dirty = true
  end
end
Api.observe("/today", onToday)

function Pager.tick()
  if not Nav.ready then return end
  local now = playdate.getCurrentTimeMilliseconds()
  if now - lastPoll > POLL_MS and myAiring() and not inBallCast() then
    lastPoll = now
    Api.get("/today", function() end, { fresh = true, bg = true })
  end
  local top = App.top()
  if not cur and #queue > 0 and not inBallCast() and not (top and top.holdToasts) then
    local g = table.remove(queue, 1)
    cur = g.note and g or render(g, nil)
    if cur.note then
      Sfx.pager()
    elseif cur.final then
      if cur.won then Sfx.kaching() else Sfx.trombone() end
    else
      Sfx.pager()
    end
  end
end

--- Main loop, after the toasts.
function Pager.draw()
  if not cur then return end
  if inBallCast() then cur = nil return end
  cur.t += 1
  local t = cur.t
  local slide = math.min(1, t / 6)
  if t > SHOW_FRAMES - 6 then slide = math.max(0, (SHOW_FRAMES - t) / 6) end
  local x = 400 - math.floor((W + 8) * (1 - (1 - slide) ^ 2))
  cur.img:draw(x, 20)
  if t >= SHOW_FRAMES then cur = nil end
end

--- A while the pager shows: watch that game. Returns true if it took the press.
function Pager.onA()
  if not cur or cur.t < 4 then return false end
  local id, onA = cur.gameId, cur.onA
  cur = nil
  Sfx.select()
  if onA then onA() else Nav.watch(id) end
  return true
end

--- For the tour: page a game right now.
function Pager.page(g)
  queue[#queue + 1] = g
end

--- A page that isn't a score (odd jobs: "ODD JOB DONE"): three LCD lines; A runs onA.
function Pager.note(l1, l2, l3, onA)
  queue[#queue + 1] = { note = true, img = pagerImage(l1, l2, l3), onA = onA, t = 0 }
end
