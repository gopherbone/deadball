-- PENNANT '96: the offline season game. A conventional pennant-race baseball sim on its own
-- device-generated league (the online league's club identities, fresh players), with training,
-- condition, lineups, the farm, trades, injuries, playoffs, awards and multi-season careers.
-- Games play in BallCast from a local engine (pennant/live.lua). No network calls anywhere.
--
-- Entry: Pennant.open() (desktop icon, Start menu, or the boot screen's offline button).

import "pdsim/pdsim"      -- the C engine (docs/PENNANT_ENGINE.md); pennant/sim.lua is the fallback
import "pennant/data"
import "pennant/rng"
import "pennant/clubs"
import "pennant/model"
import "pennant/gen"
import "pennant/sim"
import "pennant/roster"
import "pennant/rest"
import "pennant/league"
import "pennant/engine"
import "pennant/week"
import "pennant/legacy"
import "pennant/schemes"
import "pennant/wire"
import "pennant/routes"
import "pennant/landmarks"
import "pennant/globedata"
import "pennant/globe"
import "pennant/save"
import "pennant/jobs"
import "pennant/ui/kit"
import "pennant/ui/title"
import "pennant/ui/hub"
import "pennant/ui/team"
import "pennant/ui/training"
import "pennant/ui/lineup"
import "pennant/ui/rest"
import "pennant/ui/moves"
import "pennant/ui/league"
import "pennant/ui/gameday"
import "pennant/ui/roadmap"
import "pennant/ui/week"
import "pennant/ui/weekscreens"
import "pennant/ui/legacy"
import "pennant/live"
import "pennant/control"
import "pennant/test"
import "pennant/testlegacy"

Pennant = Pennant or {}

--- Open the program (title screen with the save slots).
function Pennant.open(opts)
  Pennant.opts = opts or {}
  Pennant.base = #App.stack
  -- the desktop's background polling stays quiet while Pennant is up (Nav.offline)
  Nav.offline = true
  -- long sims leave the Lua GC no idle time; garbage then piles up until a full collection
  -- stalls a frame for ~1 s on the device. A few ms of GC every frame keeps it incremental.
  if playdate.setMinimumGCTime then playdate.setMinimumGCTime(4) end
  Sfx.stopMusic(0.5)
  PennantUI.Title.open({})
end

--- Leave Pennant: finish the autosave, back to whatever opened it.
function Pennant.quit()
  PJobs.flush()
  Pennant.L = nil
  Pennant.hub = nil
  Nav.offline = false
  if playdate.setMinimumGCTime then playdate.setMinimumGCTime(1) end
  while #App.stack > (Pennant.base or 0) do App.pop() end
  if #App.stack == 0 then Boot.start() end
end

--- Pop everything above the hub.
function Pennant.toHub()
  if not Pennant.hub then return end
  while #App.stack > 1 and App.top() ~= Pennant.hub do App.pop() end
end

--- A league is loaded / created: show the season hub (replacing the title screens).
function Pennant.start(L)
  Pennant.L = L
  while #App.stack > (Pennant.base or 0) + 1 do App.pop() end
  -- (home is the Week screen, ui/week.lua; the old hub's helpers stay in ui/hub.lua)
  local hub = PennantUI.Week.replace({})
  Pennant.hub = hub
end

--- Queue a save; a save still pending is cancelled and replaced (one is enough).
function Pennant.autosave()
  local L = Pennant.L
  if not (L and L.slot) then return end
  local old = Pennant.saveJob
  if old and not old.done then old.cancel() PJobs.remove(old) end
  Pennant.saveJob = PJobs.save(L)
end
