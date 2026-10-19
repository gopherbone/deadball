-- Loads modules owned by other agents at runtime, if they're in the build.
-- pdc compiles every .lua under source/, so we can probe for the compiled .pdz and run
-- it; `import` inside those files still works at runtime. Callers must still guard:
--   if BallCast and BallCast.scene then App.push(BallCast.scene, { gameId = id }) end
--   if Cards and Cards.binderScene then App.push(Cards.binderScene) end

Optional = Optional or { loaded = {} }

local function try(name, candidates)
  for _, p in ipairs(candidates) do
    if playdate.file.exists(p .. ".pdz") then
      local ok, e = pcall(playdate.file.run, p)
      if ok then
        Optional.loaded[name] = p
        print("[optional] loaded " .. p)
      else
        print("[optional] failed to load " .. p .. ": " .. tostring(e))
        Optional.loaded[name] = false
      end
      return
    end
  end
end

-- Only probe if the module didn't already get imported some other way.
if not BallCast then
  try("ballcast", { "ballcast/main", "ballcast/init", "ballcast/ballcast", "ballcast/index" })
end
if not Audio then
  try("audio", { "audio/audio", "audio/main", "audio/init" })
end
if not Cards then
  try("cards", { "cards/main", "cards/init", "cards/cards", "cards/index" })
end
