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
import "pennant/league"
import "pennant/engine"
import "pennant/landmarks"
import "pennant/save"
import "pennant/jobs"
import "pennant/ui/kit"
import "pennant/ui/title"
import "pennant/ui/hub"
import "pennant/ui/team"
import "pennant/ui/training"
import "pennant/ui/lineup"
import "pennant/ui/moves"
import "pennant/ui/league"
import "pennant/ui/gameday"
import "pennant/ui/roadmap"
import "pennant/live"
import "pennant/test"

Pennant = Pennant or {}

--- Open the program (title screen with the save slots).
function Pennant.open(opts)
  Pennant.opts = opts or {}
  Pennant.base = #App.stack
  -- the desktop's background polling stays quiet while Pennant is up (Nav.offline)
  Nav.offline = true
  Sfx.stopMusic(0.5)
  PennantUI.Title.open({})
end

--- Leave Pennant: finish the autosave, back to whatever opened it.
function Pennant.quit()
  PJobs.flush()
  Pennant.L = nil
  Pennant.hub = nil
  Nav.offline = false
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
  local hub = PennantUI.Hub.replace({})
  Pennant.hub = hub
end

function Pennant.autosave()
  local L = Pennant.L
  if L and L.slot then PJobs.save(L) end
end
