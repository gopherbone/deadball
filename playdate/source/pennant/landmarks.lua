-- Road trip landmarks (Oregon Trail style): real places only, but placed wherever the route
-- needs them (the Eiffel Tower in Idaho is fine), by longitude/latitude on the Road Map. When a road trip's leg passes near one, the travel
-- animation stops on its card. About one every few road trips; Options can turn them off.
-- Card art: images/landmarks/<key>.png (400x160, 1-bit; see tools/assets/landmarks.py).

PLand = PLand or {}

-- lines: deadpan, flat. {p} = a player, {q} = another player, {city} = the next stop.
PLand.LIST = {
  { key = "rushmore", name = "Mount Rushmore", ll = { -103.46, 43.88 }, lines = {
    "The team stopped at Mount Rushmore. {p} asked which one was the commissioner.",
    "The bus parked at Mount Rushmore for forty minutes. {p} counted the faces twice and got five.",
  } },
  { key = "chimney_rock", name = "Chimney Rock", ll = { -103.35, 41.70 }, lines = {
    "The team passed Chimney Rock. {p} said it looked like a bat. Nobody agreed.",
    "Chimney Rock. The pioneers carved their names here. {p} carved his batting average.",
  } },
  { key = "independence_rock", name = "Independence Rock", ll = { -107.13, 42.49 }, lines = {
    "The team climbed Independence Rock. {p} did not, citing his hamstring.",
    "Independence Rock. {p} looked for the names of old ballplayers. He found a Smith.",
  } },
  { key = "grand_canyon", name = "The Grand Canyon", ll = { -112.11, 36.06 }, lines = {
    "The driver took a detour to the Grand Canyon. {p} threw a ball in. It did not come back.",
    "The Grand Canyon. {p} said the outfield at {city} is about this deep.",
  } },
  { key = "niagara", name = "Niagara Falls", ll = { -79.07, 43.08 }, lines = {
    "The team stopped at Niagara Falls. {p} wore the poncho for the rest of the trip.",
    "Niagara Falls. {p} and {q} rode the boat. They came back damp and closer friends.",
  } },
  { key = "gateway_arch", name = "The Gateway Arch", ll = { -90.18, 38.62 }, lines = {
    "The team rode to the top of the Arch. {p} kept his eyes shut the whole time.",
    "The Gateway Arch. {p} estimated it at two home runs, end to end.",
  } },
  { key = "hoover_dam", name = "Hoover Dam", ll = { -114.74, 36.01 }, lines = {
    "The team toured Hoover Dam. {p} asked where they keep the water. The guide pointed.",
  } },
  { key = "old_faithful", name = "Old Faithful", ll = { -110.83, 44.46 }, lines = {
    "Old Faithful went off on schedule. The pitching coach took notes.",
    "The team waited for Old Faithful. {p} said his slider is more reliable.",
  } },
  { key = "liberty_bell", name = "The Liberty Bell", ll = { -75.15, 39.95 }, lines = {
    "The team saw the Liberty Bell. {p} asked when they were going to fix it.",
  } },
  { key = "alamo", name = "The Alamo", ll = { -98.49, 29.43 }, lines = {
    "The driver went the long way, past the Alamo. {p} remembered it. Morale is fair.",
  } },
  { key = "devils_tower", name = "Devils Tower", ll = { -104.71, 44.59 }, lines = {
    "The team stopped at Devils Tower. {p} stared at it until the bus left without him, almost.",
  } },
  { key = "twine_ball", name = "The Giant Ball of Twine", ll = { -98.43, 39.51 }, lines = {
    "The team added a length of twine to the ball. {p} added two. He is competitive.",
    "The giant ball of twine. {p} asked if it was regulation. It is not.",
  } },
  { key = "frying_pan", name = "The World's Largest Frying Pan", ll = { -124.05, 46.35 }, lines = {
    "The team saw the world's largest frying pan. {p} asked about the eggs.",
  } },
  -- real places from elsewhere, dropped along the route anyway (the league's map is its own)
  { key = "eiffel_tower", name = "The Eiffel Tower", ll = { -114.5, 43.6 }, lines = {
    "The team stopped at the Eiffel Tower, which is in Idaho now. {p} said it was smaller than he expected.",
    "The Eiffel Tower. {p} asked for directions in French. He does not speak French.",
  } },
  { key = "pisa", name = "The Leaning Tower of Pisa", ll = { -85.6, 41.6 }, lines = {
    "The team passed the Leaning Tower of Pisa off Route 12. {p} leaned the other way to help.",
    "The Leaning Tower of Pisa. {p} said his curveball breaks more than that.",
  } },
  { key = "stonehenge", name = "Stonehenge", ll = { -101.5, 39.2 }, lines = {
    "The team stopped at Stonehenge, outside a gas station in Kansas. {p} asked who keeps score.",
    "Stonehenge. {p} and {q} argued about whether it was a ballpark. Nobody won.",
  } },
  { key = "sphinx", name = "The Great Sphinx", ll = { -82.3, 40.9 }, lines = {
    "The team saw the Great Sphinx near the Ohio line. {p} asked it a riddle. It did not answer.",
    "The Sphinx. {p} said it has a good poker face. He would know.",
  } },
  { key = "colosseum", name = "The Colosseum", ll = { -93.6, 40.4 }, lines = {
    "The team toured the Colosseum. {p} said the bleachers need work.",
    "The Colosseum. The guide said 50,000 people used to come here. {p} asked for the attendance figure on Tuesdays.",
  } },
}

-- Consequences: small and occasional. Each returns a sentence (or nil when nothing happens).
local EFFECTS <const> = {
  { w = 30, fn = function(L, T, rng, pick) return "Morale is fair." end },
  { w = 18, fn = function(L, T, rng, pick)
    for _, id in ipairs(T.ml) do local p = L.players[id] p.mood = math.min(2, (p.mood or 0) + 1) end
    return "Spirits are up. (Mood +1)"
  end },
  { w = 14, fn = function(L, T, rng, pick)
    local p = pick()
    p.cond = math.max(1, (p.cond or 3) - 1)
    return PM.name(p) .. " caught a cold. (Condition down)"
  end },
  { w = 12, fn = function(L, T, rng, pick)
    local p = pick(true)
    p.cond = math.min(5, (p.cond or 3) + 1)
    return PM.name(p) .. " bought a souvenir bat. He swears by it. (Condition up)"
  end },
  { w = 8, fn = function(L, T, rng, pick)
    local p = pick(true)
    p.late = 2
    return PM.name(p) .. " was left at a gas station. He will be a day late."
  end },
  { w = 10, fn = function(L, T, rng, pick)
    for _, id in ipairs(T.ml) do local p = L.players[id] p.fat = math.max(0, (p.fat or 0) - 5) end
    return "Everyone slept on the bus. (Fatigue down)"
  end },
}

--- Lon/lat to Road Map pixels (400 x 190 map; see ui/roadmap.lua).
function PLand.project(lon, lat)
  return math.floor((lon + 125) * 6.3 + 18 + 0.5), math.floor((49.5 - lat) * 6.6 + 14 + 0.5)
end

local function segDist(px, py, ax, ay, bx, by)
  local dx, dy = bx - ax, by - ay
  local l2 = dx * dx + dy * dy
  local t = l2 > 0 and math.max(0, math.min(1, ((px - ax) * dx + (py - ay) * dy) / l2)) or 0
  local qx, qy = ax + dx * t, ay + dy * t
  return math.sqrt((px - qx) ^ 2 + (py - qy) ^ 2), t
end
PLand.segDist = segDist

function PLand.byKey(k) for _, e in ipairs(PLand.LIST) do if e.key == k then return e end end end

--- Maybe a landmark on the leg from -> to (club abbrs). Applies its consequence. Returns
--- { key, name, text, effect, t (0..1 along the leg) } or nil.
function PLand.maybe(L, from, to)
  local rng = PL.rng(L, 77)
  L.lmTrips = (L.lmTrips or 0) + 1
  local a, b = PennantClubs.byAbbr[from], PennantClubs.byAbbr[to]
  if not a or not b then return nil end
  local ax, ay = PLand.project(a.ll[1], a.ll[2])
  local bx, by = PLand.project(b.ll[1], b.ll[2])
  local legLen = math.sqrt((bx - ax) ^ 2 + (by - ay) ^ 2)
  if legLen < 25 then return nil end
  -- odds: rare on the first trips after one, likelier the longer it's been
  local p = 0.08 + math.min(0.5, (L.lmTrips - 1) * 0.12)
  if not rng:chance(p) then return nil end
  L.lmSeen = L.lmSeen or {}
  local near, detour = {}, {}
  for _, e in ipairs(PLand.LIST) do
    local x, y = PLand.project(e.ll[1], e.ll[2])
    local d, t = segDist(x, y, ax, ay, bx, by)
    if t > 0.08 and t < 0.92 then
      local fresh = not L.lmSeen[e.key]
      if d < 16 then near[#near + 1] = { e = e, t = t, fresh = fresh } elseif d < 70 then detour[#detour + 1] = { e = e, t = t, fresh = fresh } end
    end
  end
  local function choose(list)
    local fresh = {}
    for _, c in ipairs(list) do if c.fresh then fresh[#fresh + 1] = c end end
    if #fresh > 0 then return fresh[rng:int(#fresh)] end
    if #list > 0 and rng:chance(0.3) then return list[rng:int(#list)] end
    return nil
  end
  local c = choose(near) or (rng:chance(0.35) and choose(detour)) or nil
  if not c then return nil end
  L.lmTrips = 0
  L.lmSeen[c.e.key] = true
  local T = L.teams[L.user]
  local pool = {}
  for _, id in ipairs(T.ml) do local p = L.players[id] if not p.inj then pool[#pool + 1] = p end end
  local function pick(notStar)
    local p = pool[rng:int(#pool)]
    return p
  end
  local p1, p2 = pick(), pick()
  local line = c.e.lines[rng:int(#c.e.lines)]
  line = line:gsub("{p}", PM.name(p1)):gsub("{q}", PM.name(p2 ~= p1 and p2 or pick())):gsub("{city}", b.city)
  local tot = 0
  for _, e in ipairs(EFFECTS) do tot = tot + e.w end
  local x = rng:float() * tot
  local eff = EFFECTS[1]
  for _, e in ipairs(EFFECTS) do x = x - e.w if x <= 0 then eff = e break end end
  local effText = eff.fn(L, T, rng, pick)
  PL.news(L, "ON THE ROAD: " .. c.e.name .. ". " .. (effText or ""), true)
  return { key = c.e.key, name = c.e.name, text = line, effect = effText, t = c.t }
end
