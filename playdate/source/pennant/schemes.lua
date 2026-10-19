--[[ Direct-control schemes: how a player's buttons become the engine's batInput / pitchInput
  (docs/PENNANT_ENGINE.md: batInput{swing, timing -1..1, aim -1..1, power}, pitchInput{type, x, z,
  effort}). The UI owns this mapping, so the two schemes differ only here and in their screens
  (pennant/control.lua). Pure functions: the in-game UI and the simulated-human checks
  (pennant/test.lua "bots") call the same code.

  ARCADE ("Power Swing")
    bat:   a meet cursor (D-pad) and a timing ring closing on the ball; tap A = swing, hold A in the
           windup and release = power swing. Generous: a dead zone around perfect timing, the
           cursor's height pulls the bat onto the ball, a horizontal miss costs timing instead.
    pitch: crank picks the pitch, D-pad aims anywhere, A starts an accuracy+effort meter, A stops
           it: off the pitcher's command band adds scatter; the far right reaches back.
  SCOUT ("Scout's Eye")
    bat:   before the pitch, pick an approach: sit fastball / sit soft / look in / look away / see
           it / take. A right guess means a tight, well-aimed swing; a wrong one is early or late.
           Contact and eye shape the noise; two strikes protect.
    pitch: 13 spots (3x3 + 4 chase spots), the catcher's call preselected; A throws, hold A to
           reach back. The engine's own command scatter decides the rest.
]]

PScheme = PScheme or {}
PScheme.LIST = { "arcade", "scout" }
PScheme.NAME = { arcade = "Arcade", scout = "Scout" }
PScheme.BLURB = { arcade = "Timing and aim. Quick and forgiving.", scout = "Guess the pitch, call the spot. Ratings rule." }

local abs, max, min, sqrt = math.abs, math.max, math.min, math.sqrt
local function clamp(v, a, b) if v < a then return a elseif v > b then return b end return v end

local FAST <const> = { FB = true, SI = true, CT = true }
function PScheme.isFast(t) return FAST[t] == true end

--- The batter's aim window in zone units (the contract's wA), and the meet cursor's half-size.
function PScheme.aimWindow(con) return 0.70 + 0.05 * ((con or 50) - 50) / 10 end
function PScheme.cursorHalf(con, power) return 0.30 * PScheme.aimWindow(con) / 0.70 * (power and 0.85 or 1) end

-- Arcade batting ------------------------------------------------------------------------------------
-- raw = { dt = swing time - plate time (beat seconds, + late), cx, cz = cursor, bx, bz = ball at the
-- plate (zone units), power }. con = the batter's contact rating.
PScheme.ARC_T = 0.20       -- beat seconds of mistiming that make timing 1 (playback runs at 0.6x)
PScheme.ARC_DEAD = 0.035   -- within this of perfect counts as perfect
function PScheme.arcadeBat(raw, con)
  local hw = PScheme.cursorHalf(con, raw.power)
  local dt = raw.dt or 0
  local t = abs(dt) <= PScheme.ARC_DEAD and 0 or (dt - (dt > 0 and PScheme.ARC_DEAD or -PScheme.ARC_DEAD)) / PScheme.ARC_T
  -- a horizontal miss beyond the cursor costs timing (the engine aims vertically only)
  local overX = max(0, abs((raw.cx or 0) - (raw.bx or 0)) - hw)
  if overX > 0 then t = t + (t >= 0 and 1 or -1) * overX * 1.4 end
  -- the cursor's height: on the ball inside it (the cursor did its job), the raw miss outside it
  local dz = (raw.cz or 0) - (raw.bz or 0)
  local aim
  if abs(dz) <= hw then aim = (raw.bz or 0) + dz * 0.2 else aim = (raw.bz or 0) + dz - (dz > 0 and hw or -hw) * 0.65 end
  return { swing = true, timing = clamp(t, -1, 1), aim = clamp(aim, -1.6, 1.6), power = raw.power == true }
end

--- Verdict words for the LAST card (batting).
function PScheme.batVerdict(raw, con)
  local dt = (raw.dt or 0) / 0.6          -- beat seconds -> real seconds at 0.6x playback
  local words
  if abs(raw.dt or 0) <= PScheme.ARC_DEAD then words = "ON TIME"
  elseif (raw.dt or 0) < 0 then words = "EARLY" else words = "LATE" end
  local by = math.floor(abs(dt) * 1000 + 0.5)
  local hw = PScheme.cursorHalf(con, raw.power)
  local dz = (raw.cz or 0) - (raw.bz or 0)
  local aimWord = abs(dz) <= hw and nil or (dz > 0 and "OVER IT" or "UNDER IT")
  return words, by, aimWord
end

-- Scout batting --------------------------------------------------------------------------------------
-- choice: "fast" | "soft" | "in" | "away" | "see" | "take"
-- pitch = { t, px, pz } (zone units), ctx = { con, eye, bats, strikes }, rng = PRng
function PScheme.inside(px, bats)
  -- x is + toward first base as the catcher sees it; a righty stands on the third-base side
  if bats == "L" then return px > 0 end
  return px < 0
end

function PScheme.scoutBat(choice, pitch, ctx, rng)
  if choice == "take" then return { swing = false }, "took" end
  local fast = FAST[pitch.t] == true
  local inn = PScheme.inside(pitch.px, ctx.bats)
  local strike = max(abs(pitch.px), abs(pitch.pz)) < 1.0
  local near = max(abs(pitch.px), abs(pitch.pz)) < 1.3
  local right
  if choice == "fast" then right = fast elseif choice == "soft" then right = not fast
  elseif choice == "in" then right = inn elseif choice == "away" then right = not inn end
  local protect = (ctx.strikes or 0) >= 2
  -- the swing decision: strikes always; a near miss that fits the guess; otherwise the eye
  local swing
  if strike then swing = true
  elseif protect and near then swing = rng:chance(0.7)
  elseif right and near then swing = rng:chance(0.3)
  else swing = rng:chance(clamp(0.16 - ((ctx.eye or 50) - 50) * 0.006 + (protect and 0.10 or 0), 0.02, 0.45)) end
  if not swing then return { swing = false }, "laid off" end
  -- noise: contact tightens everything (0.7x for an 80, 1.2x for a 20)
  local k = 1.2 - ((ctx.con or 50) - 20) / 60 * 0.5
  if protect then k = k * 1.15 end
  local timing, aim, note
  if choice == "see" then
    timing = rng:normal(0, 0.30 * k)
    aim = pitch.pz + rng:normal(0, 0.30 * k)
    note = "saw it"
  elseif right then
    timing = rng:normal(0, 0.13 * k)
    aim = pitch.pz + rng:normal(0, 0.16 * k)
    note = "right"
  else
    if choice == "fast" then timing = -0.75 + rng:normal(0, 0.12)         -- sat fastball, got something soft: out in front
    elseif choice == "soft" then timing = 0.75 + rng:normal(0, 0.12)      -- sat soft, got the heat: late
    elseif choice == "in" then timing = 0.55 + rng:normal(0, 0.15)        -- looked in, it was away: late
    else timing = -0.55 + rng:normal(0, 0.15) end                          -- looked away, it was in: early
    aim = pitch.pz + rng:normal(0, 0.32 * k)
    note = "wrong"
  end
  return { swing = true, timing = clamp(timing, -1, 1), aim = clamp(aim, -1.6, 1.6), power = false }, note
end

-- Arcade pitching -------------------------------------------------------------------------------------
-- The meter: a marker sweeping 0..1; the pitcher's command band sits at 0.55 (wider for better
-- command). Off the band adds scatter; past 0.92 reaches back (effort 1).
function PScheme.band(command) return 0.10 + clamp(((command or 50) - 20) / 60, 0, 1) * 0.22 end
PScheme.BAND_C = 0.55
function PScheme.arcadePitch(target, m, command, rng)
  local half = PScheme.band(command) / 2
  local off = max(0, abs(m - PScheme.BAND_C) - half)
  local x, z = target.x, target.z
  if off > 0 then
    local a = rng:float() * 6.2832
    local r = off * 2.4
    x, z = x + math.cos(a) * r, z + math.sin(a) * r
  end
  local effort = m >= 0.92 and 1.0 or clamp(0.35 + m * 0.5, 0.2, 0.8)
  return { type = target.type, x = clamp(x, -2, 2), z = clamp(z, -2, 2), effort = effort }, off
end

-- Scout pitching --------------------------------------------------------------------------------------
-- 13 spots: the 3x3 grid (in zone units) and 4 chase spots outside it.
PScheme.SPOTS = {
  { -0.67, 0.67 }, { 0, 0.67 }, { 0.67, 0.67 },
  { -0.67, 0 }, { 0, 0 }, { 0.67, 0 },
  { -0.67, -0.67 }, { 0, -0.67 }, { 0.67, -0.67 },
  { 0, 1.35 }, { -1.35, 0 }, { 1.35, 0 }, { 0, -1.35 },   -- high, in (3B side), away (1B side), in the dirt
}
-- D-pad moves between spots: a 5x5 layout (spot index or 0 for an empty cell)
PScheme.GRID = {
  { 0, 0, 10, 0, 0 },
  { 0, 1, 2, 3, 0 },
  { 11, 4, 5, 6, 12 },
  { 0, 7, 8, 9, 0 },
  { 0, 0, 13, 0, 0 },
}
function PScheme.spotXY(i) local s = PScheme.SPOTS[i] return s[1], s[2] end

function PScheme.scoutPitch(type_, spot, reachBack)
  local x, z = PScheme.spotXY(spot)
  return { type = type_, x = x, z = z, effort = reachBack and 1.0 or 0.5 }
end

--- The catcher's call: a pitch and a spot for the count (ahead: chase with a good secondary,
--- behind: the fastball on an edge, even: mix), lefty/righty aware.
function PScheme.catcherCall(arsenal, balls, strikes, bats, rng)
  local best2, bq = nil, -1
  for i, a in ipairs(arsenal) do
    if i > 1 and (a.quality or 50) > bq then best2, bq = a, a.quality or 50 end
  end
  local fb = arsenal[1]
  local awaySpot = (bats == "L") and 4 or 6        -- away from the batter, middle height
  local awayLow = (bats == "L") and 7 or 9
  local inHigh = (bats == "L") and 3 or 1
  local chaseAway = (bats == "L") and 11 or 12
  local pick, spot
  if strikes == 2 and balls < 3 then
    pick = best2 or fb
    spot = rng:chance(0.5) and 13 or chaseAway
  elseif balls >= 2 and balls > strikes then
    pick = fb
    spot = rng:chance(0.5) and awaySpot or 8
  else
    pick = (best2 and rng:chance(0.45)) and best2 or fb
    spot = rng:chance(0.5) and awayLow or (rng:chance(0.5) and inHigh or awaySpot)
  end
  return pick and pick.kind or "FB", spot
end

--- "missed your spot by a ball, arm side" style words. throws: the pitcher's hand.
function PScheme.missWords(tx, tz, ax, az, throws)
  local d = sqrt((ax - tx) ^ 2 + (az - tz) ^ 2)
  local balls = d / 0.29                       -- a ball is ~0.29 zone units wide
  if balls < 0.6 then return "hit the spot" end
  local dir
  if abs(az - tz) > abs(ax - tx) then dir = (az > tz) and "up" or "down"
  else
    -- arm side for a righty is the 1B side (+x as the catcher sees it)
    local armSide = (throws == "L") and (ax < tx) or (ax > tx)
    dir = armSide and "arm side" or "glove side"
  end
  local n = math.floor(balls + 0.5)
  return "missed " .. (n <= 1 and "a ball" or (n .. " balls")) .. " " .. dir
end

--- Location words for a pitch ("low, away").
function PScheme.whereWords(px, pz, bats)
  local v = pz > 0.5 and "up" or (pz < -0.5 and "low" or "middle")
  local h
  if abs(px) < 0.35 then h = "middle" else h = PScheme.inside(px, bats) and "in" or "away" end
  if v == "middle" and h == "middle" then return "middle-middle" end
  if v == "middle" then return h end
  if h == "middle" then return v end
  return v .. ", " .. h
end
