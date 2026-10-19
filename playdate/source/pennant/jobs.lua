--[[ Pennant background work, sliced by time so the UI never stalls:
  * the other games of the day (pdsim, a few dozen events per slice; the C engine does a whole
    game per slice),
  * the autosave (one datastore file per slice).
  PJobs.tick(ms) is called once a frame by whichever Pennant scene is on top (inside BallCast the
  live game source calls it with a small budget).
]]

PJobs = PJobs or { q = {} }
local q = PJobs.q

local function now() return playdate.getCurrentTimeMilliseconds() end

function PJobs.add(job) q[#q + 1] = job end
function PJobs.busy() return #q > 0 end
function PJobs.clear() for i = #q, 1, -1 do q[i] = nil end end

--- Run queued jobs for up to ms milliseconds.
function PJobs.tick(ms)
  if #q == 0 then return end
  local t0 = now()
  local guard = 0
  while #q > 0 and now() - t0 < ms and guard < 400 do
    guard = guard + 1
    local j = q[1]
    local ts = now()
    local ok, done = pcall(j.step, ms - (ts - t0))
    if not ok then print("[pjobs] job failed: " .. tostring(done)) done = true end
    local d = now() - ts
    if d > 20 and PUI and PUI.PROF then print(string.format("[pjobs] slow step %d ms (%s%s)", d, j.what or "?", j.phase and (" " .. j.phase()) or "")) end
    if done then table.remove(q, 1) if j.onDone then j.onDone() end end
  end
end

--- Finish everything now (behind a progress screen or at quit).
function PJobs.flush()
  local guard = 0
  while #q > 0 and guard < 100000 do PJobs.tick(1000) guard = guard + 1 end
end

--- Sim one league game in slices (PEng: the C engine, else the Lua one).
function PJobs.simGame(L, g, onDone)
  local job = PEng.simJob(L, g)
  job.onDone = onDone
  PJobs.add(job)
  return job
end

--- Queue the rest of today's games (except skip, e.g. the one being played live).
function PJobs.simDay(L, skip)
  local n = 0
  for _, g in ipairs(PL.pending(L)) do
    if g ~= skip and not g.queued then g.queued = true PJobs.simGame(L, g) n = n + 1 end
  end
  return n
end

function PJobs.remove(job)
  for i = #q, 1, -1 do if q[i] == job then table.remove(q, i) end end
end

function PJobs.save(L, onDone)
  if not L.slot then return end
  local j = PSave.begin(L, L.slot)
  j.onDone = onDone
  PJobs.add(j)
  return j
end
