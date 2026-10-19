-- Debug helpers. In the Simulator, print() output is mirrored to debug.log in the game's
-- Data folder (Disk/Data/com.deadball.game/debug.log) when a file named "debug.flag"
-- exists there. The screenshot tour lives in app/tour.lua.

Debug = Debug or {}
Debug.showFps = false

local logFile = nil
if playdate.file.exists("debug.flag") then
  logFile = playdate.file.open("debug.log", playdate.file.kFileWrite)
  local rawPrint = print
  print = function(...)
    rawPrint(...)
    if logFile then
      local parts = {}
      for i = 1, select("#", ...) do parts[#parts + 1] = tostring(select(i, ...)) end
      logFile:write(table.concat(parts, "\t") .. "\n")
      logFile:flush()
    end
  end
  Debug.showFps = true
  Debug.trapErrors = true
end

function Debug.log(...)
  print(...)
end
