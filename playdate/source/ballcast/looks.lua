-- BallCast player looks: every puppet a player id, every player id one look, for the whole
-- session (and every session: it's a pure function of the id).
--
--   body     1 average, 2 tall + lanky, 3 short + stocky (puppets.lua BODY: a width factor and a
--            figure height baked into the sprite's C size caches; no per-frame cost)
--   bits     the bc3d look stamps (bc3d.c lookPass): skin dither 0-3, facial hair (moustache,
--            beard, chin strap), socks (as rendered: high and dark; a stirrup stripe; low), long
--            dark undershirt sleeves, batting helmet (role, added by the caller), jersey number
--   lefty    throws left (pitchers are drawn mirrored)
--   stance   the batter's idle stance: crouch (sx, sy) and an open/closed lean (deg)
--
-- The people table (meta.people) may carry num / throws / bats; otherwise everything is seeded
-- by the id. Fielders without an id (the log names positions only) are seeded by team + position.

import "ballcast/kit"

BallCast = BallCast or {}
if BallCast.Looks then return end
local Lk = {}
BallCast.Looks = Lk
local K = BCKit
local floor <const> = math.floor

Lk.HELMET = 128
local cache = {}

local function make(key, p)
  local h = function(salt) return K.hash01(key, salt) end
  local L = {}
  local b = h(201)
  L.body = b < 0.2 and 2 or (b < 0.45 and 3 or 1)
  local s = h(202)
  local skin = s < 0.6 and 0 or (s < 0.78 and 1 or (s < 0.92 and 2 or 3))
  local f = h(203)
  local hair = f < 0.6 and 0 or (f < 0.8 and 1 or (f < 0.93 and 2 or 3))
  local k = h(204)
  local socks = k < 0.5 and 0 or (k < 0.8 and 1 or 2)
  local sleeves = h(205) < 0.3 and 64 or 0
  local num = (p and tonumber(p.num)) or (1 + floor(h(206) * 59))
  if num > 99 then num = num % 100 end
  L.num = num
  L.bits = skin + hair * 4 + socks * 16 + sleeves + num * 256
  L.lefty = (p and p.throws == "L") or (not (p and p.throws) and h(207) < 0.22) or false
  local c = h(208)
  L.stance = { 1 + c * 0.05, 1 - c * 0.07, floor((h(209) - 0.5) * 6 + 0.5) }
  return L
end

--- look for a player id (string/number); people: meta.people (optional)
function Lk.of(id, people)
  local key = tostring(id or "?")
  local L = cache[key]
  if L then return L end
  L = make(key, people and people[id])
  cache[key] = L
  return L
end

--- the team abbreviation for a puppet variant ("home"/"away") in the current scene
function Lk.team(variant)
  local sc = BallCast.scene
  local m = sc and sc.meta
  local t = m and m[variant]
  return (t and t.abbr) or variant
end

--- the id of the player at a position for a team (by listed position), else nil
local idxFor, idx = nil, nil
function Lk.fielderId(people, team, pos)
  if not people then return nil end
  if idxFor ~= people then
    idx = {}
    for id, q in pairs(people) do
      if q.teamAbbr and q.pos and not idx[q.teamAbbr .. ":" .. q.pos] then idx[q.teamAbbr .. ":" .. q.pos] = id end
    end
    idxFor = people
  end
  return idx[team .. ":" .. pos]
end

--- the look of the fielder at pos for the team wearing `variant` (memoised per frame-free key:
--- no strings built on the per-frame path once a (people, variant, pos) has been seen)
local fcache, fcPeople = {}, nil
function Lk.fielder(people, variant, pos)
  if fcPeople ~= people then fcache, fcPeople = {}, people end
  local v = fcache[variant]
  if not v then v = {}; fcache[variant] = v end
  local L = v[pos]
  if L then return L end
  local team = Lk.team(variant)
  local id = Lk.fielderId(people, team, pos)
  L = Lk.of(id or (team .. ":" .. pos), people)
  v[pos] = L
  return L
end
--- a team's base coach k (1 = first base, 2 = third)
local COACHKEY <const> = { "coach1", "coach2" }
function Lk.coach(people, variant, k) return Lk.fielder(people, variant, COACHKEY[k]) end
--- forget the memo (a new scene: teams may have changed)
function Lk.reset() fcache, fcPeople, cache = {}, nil, {} end

return Lk
