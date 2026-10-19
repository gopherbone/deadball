-- pdsim: the on-device game engine (C, ../../c/pdsim_core.c) for Pennant mode.
-- The contract is docs/PENNANT_ENGINE.md. The C side registers `pdsim` with low-level
-- `pdsim._*` functions that take/return JSON strings (the C API can't touch Lua tables);
-- this file adds the table-based API on top. import "pdsim/pdsim" once.

if not pdsim then
  print("[pdsim] C extension not loaded (pdc-only build?): pdsim unavailable")
  return
end

local C <const> = pdsim
local enc <const>, dec <const> = json.encode, json.decode

PDSIM_VERSION = 1

--- A team pre-encoded for specs: pass the string as spec.home / spec.away to skip re-encoding
--- the roster every game (json.encode of a 26-man roster is ~28 KB; cache it per day).
function C.encodeTeam(team) return enc(team) end

-- spec -> JSON; spec.home / spec.away may be tables or pdsim.encodeTeam strings
local function specJson(spec)
  local h, a = spec.home, spec.away
  if type(h) ~= "string" and type(a) ~= "string" then return enc(spec) end
  local rest = {}
  for k, v in pairs(spec) do if k ~= "home" and k ~= "away" then rest[k] = v end end
  local r = enc(rest)
  local head = '{"home":' .. (type(h) == "string" and h or enc(h)) .. ',"away":' .. (type(a) == "string" and a or enc(a))
  if r == "{}" or r == "[]" then return head .. "}" end
  return head .. "," .. r:sub(2)
end
C.specJson = specJson

--- g = pdsim.new(spec) -> game object, or nil, err
function C.new(spec)
  return C._new(specJson(spec))
end

--- evs, pause = pdsim.step(g, maxEvents, budgetMs)
function C.step(g, maxEvents, budgetMs)
  local e, p = C._step(g, maxEvents, budgetMs)
  return dec(e) or {}, p and dec(p) or nil
end

--- ok, err = pdsim.decide(g, d)   d.kind + d.runner / d.id (see the doc)
function C.decide(g, d)
  local k = d and d.kind or "none"
  local a1, a2
  if k == "steal" then a1 = d.runner and tostring(d.runner)
  elseif k == "pinch_run" then a1, a2 = d.id, d.runner and tostring(d.runner)
  elseif k == "pinch_hit" or k == "pitch_change" then a1 = d.id
  end
  return C._decide(g, k, a1, a2)
end

--- pdsim.batInput(g, { swing = true, timing = 0, aim = 0, power = false })
function C.batInput(g, t)
  t = t or {}
  return C._bat(g, t.swing ~= false, t.timing or 0, t.aim or 0, t.power == true)
end

--- pdsim.pitchInput(g, { type = "FB", x = 0, z = 0, effort = 0.5 })
function C.pitchInput(g, t)
  t = t or {}
  return C._pitch(g, t.type or "", t.x or 0, t.z or 0, t.effort or 0.5)
end

function C.box(g) return dec(C._box(g)) end
function C.info(g) return dec(C._info(g)) end
--- the whole log as LogEv tables (pdsim.logc(g) is the compact string for BallCast)
function C.log(g) return dec(C._log(g)) end

--- box = pdsim.simulate(spec): a whole AI-vs-AI game, no log
function C.simulate(spec)
  local b, err = C._simulate(specJson(spec))
  if not b then return nil, err end
  return dec(b)
end

--- job = pdsim.simulateStart(spec); then each frame: done, box = pdsim.simulateSlice(job, ms)
function C.simulateStart(spec)
  return C._simStart(specJson(spec))
end
function C.simulateSlice(job, budgetMs)
  local done, b = C._simSlice(job, budgetMs or 5)
  return done, b and dec(b) or nil
end

--- { lineup, bench, starter, rotation, bullpen } as the engine's manager AI would pick them
function C.autoLineup(team, vsThrows)
  local s, err = C._autoLineup(enc(team), vsThrows)
  if not s then return nil, err end
  return dec(s)
end
