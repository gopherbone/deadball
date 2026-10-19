-- BallCast sound: a synth crowd (filtered noise bed that swells into a roar), bat crack,
-- mitt pop, whoosh, "ooh", and a ballpark organ riff. No samples needed.

import "ballcast/kit"

local snd <const> = playdate.sound

BallCast = BallCast or {}
local A = {}
BallCast.Audio = A

local crowd, crowdCh, crowdF
local ooh, oohCh
local level, target = 0, 0
local oohLevel = 0
local on = false

-- the audio agent's global `Audio` (organ, recordings, sampled SFX), when present
local function ext() return (type(_G.Audio) == "table" and _G.Audio.sfx) and _G.Audio or nil end
A.ext = ext
local function call(fn, ...)
  local X = ext()
  if X and X[fn] then pcall(X[fn], ...) return true end
  return false
end
A.call = call

function A.start()
  if on then return end
  on = true
  if ext() then
    call("stop", nil, 0.8)
    call("ambience", "crowd_ambience", 0.35)
    call("setLowCPU", true)
    level, target, oohLevel = 0.05, 0.05, 0
    return
  end
  crowdCh = snd.channel.new()
  crowdF = snd.twopolefilter.new(snd.kFilterLowPass)
  crowdF:setFrequency(700)
  crowdF:setResonance(0.2)
  crowdCh:addEffect(crowdF)
  crowd = snd.synth.new(snd.kWaveNoise)
  crowd:setADSR(0.4, 0, 1, 0.6)
  crowdCh:addSource(crowd)
  crowd:playNote(400, 1)
  crowdCh:setVolume(0.05)

  oohCh = snd.channel.new()
  local bp = snd.twopolefilter.new(snd.kFilterBandPass)
  bp:setFrequency(420)
  bp:setResonance(0.7)
  oohCh:addEffect(bp)
  ooh = snd.synth.new(snd.kWaveNoise)
  ooh:setADSR(0.2, 0, 1, 0.5)
  oohCh:addSource(ooh)
  ooh:playNote(300, 1)
  oohCh:setVolume(0)
  level, target, oohLevel = 0.05, 0.05, 0
end

function A.stop()
  if not on then return end
  on = false
  if ext() then
    call("ambience", nil)
    call("stop")
    call("setLowCPU", false)
    return
  end
  if crowd then crowd:stop() end
  if ooh then ooh:stop() end
  if crowdCh then crowdCh:remove() end
  if oohCh then oohCh:remove() end
  crowd, ooh, crowdCh, oohCh, crowdF = nil, nil, nil, nil, nil
end

--- Swell the crowd to v (0..1); it decays back to the murmur on its own.
function A.roar(v)
  if v > target then target = v end
end

function A.level() return level end

function A.ooh(v) oohLevel = math.max(oohLevel, v or 0.6) end

--- Per frame. muted: scrubbing / fast playback / paused.
function A.update(muted)
  if not on then return end
  if ext() then
    target = target + (0.05 - target) * 0.025
    level = level + (target - level) * 0.2
    return
  end
  local base = muted and 0.015 or 0.05
  target = target + (base - target) * 0.025
  if target < base then target = base end
  level = level + (target - level) * 0.2
  crowdCh:setVolume(math.min(0.6, level))
  crowdF:setFrequency(600 + level * 1800)
  oohLevel = oohLevel * 0.94
  oohCh:setVolume(muted and 0 or math.min(0.5, oohLevel))
end

local lastRoar = 0

-- Canned crowd reactions ("c_<kind>", v = volume 0..1, already leverage-scaled by the scene).
-- One reaction at a time: a new one needs 1.2 s of quiet, or 0.5 s if it outranks the last.
local REACT = {
  c_murmur = { "crowd_ooh", 0.35, 1 }, c_clap = { "crowd_clap", 0.8, 2 }, c_ooh = { "crowd_ooh", 1, 3 },
  c_groan = { "crowd_groan", 1, 3 }, c_applause = { "applause", 0.9, 3 }, c_boo = { "crowd_boo", 1, 4 },
  c_cheer = { "crowd_cheer", 1, 4 }, c_roar = { "crowd_roar", 1, 5 },
}
A.REACT = REACT
local lastReactMs, lastReactPrio = -10000, 0
local function react(kind, v)
  local r = REACT[kind]
  if not r then return false end
  local now = playdate.getCurrentTimeMilliseconds()
  local dt = now - lastReactMs
  if dt < 1200 and not (r[3] > lastReactPrio and dt > 500) then return true end
  lastReactMs, lastReactPrio = now, r[3]
  local vol = math.min(1, (v or 0.7) * r[2])
  -- the crowd texture on the 3D shots swells with it too
  target = math.max(target, 0.25 + vol * (r[3] >= 4 and 0.7 or 0.4))
  if ext() then
    local name = r[1]
    if kind == "c_boo" and math.random() < 0.5 then name = "crowd_boo_2" end
    if kind == "c_roar" and math.random() < 0.5 then name = "crowd_roar_2" end
    call("sfx", name, vol)
  else
    if r[3] >= 4 then A.roar(vol) else A.ooh(vol * 0.7) end
  end
  return true
end

local EXT = {
  crack = function() call("sfx", "bat_crack") end,
  pop = function() call("sfx", "mitt_pop") end,
  foul = function() call("sfx", "bat_crack", 0.5) end,
  whoosh = function() end,
  thud = function() call("sfx", "mitt_pop", 0.7) end,
  roar = function(v)
    target = math.max(target, v or 0.7)
    if (v or 0.7) >= 0.75 then react("c_roar", v) end
  end,
  ooh = function() end,
  fanfare = function() call("stinger", "home_run") end,
  organ = function() call("stinger", "charge") end,
  strike3 = function() call("sfx", "strike_call"); call("stinger", "strikeout") end,
  homerun = function() call("stinger", "home_run") end,
  error = function() call("stinger", "error") end,
  eject = function() call("sfx", "whistle"); call("stinger", "ejection") end,
  gladiators = function() call("play", "gladiators", { loop = false }) end,
  stretch = function() call("play", "take_me_out", { loop = false }) end,
  stopMusic = function() call("stop", nil, 0.5) end,
  telegraph = function() call("sfx", "telegraph", 0.6) end,
  walkup = function() call("play", "pop_weasel", { loop = false }) end,
  win = function() call("play", "stars_stripes") end,
  blowout = function() call("play", "funeral_march") end,
  -- DBN broadcast package (ballcast/tv): network stings, offline-rendered (tools/audio/tv_stings.py)
  tvIdent = function() call("sfx", "tv_ident", 0.9) end,
  tvWhoosh = function() call("sfx", "tv_whoosh", 0.55) end,
  tvReplay = function() call("sfx", "tv_replay", 0.85) end,
  tvRewind = function() call("sfx", "tv_rewind", 0.7) end,
  tvBulletin = function() call("sfx", "tv_bulletin", 0.85) end,
  tvPen = function() call("sfx", "tv_pen", 0.6) end,
  tvTick = function() call("sfx", "tv_tick", 0.7) end,
  tvFreeze = function() call("sfx", "tv_freeze", 0.7) end,
  tvImpact = function() call("sfx", "tv_impact", 0.9) end,
  tvTheme = function() call("play", "stars_stripes", { loop = false, fade = 0.3 }) end,   -- the open
  tvAdMusic = function() call("play", "ragtime", { loop = false, fade = 0.2 }) end,       -- commercials
}
-- sampled TV stings (the scene plays each once, silently, in the loader)
A.TV_SOUNDS = { "tv_ident", "tv_whoosh", "tv_replay", "tv_rewind", "tv_bulletin", "tv_pen", "tv_tick", "tv_freeze", "tv_impact" }
--- Loader: make every sample the replay can play over a 3D frame resident, one loader step
--- each (a sampleplayer reads its whole file on first use: a mid-play disk read). Sampled
--- sfx can have variants (bat_crack has three) picked at random per play, so each name is
--- played silently until every variant has had its turn (random picks; 8 per variant).
--- Stingers (strikeout, home_run, ...) load their file on first play too: played at volume 0.
A.WARM_SFX = { "bat_crack", "mitt_pop", "crowd_roar", "crowd_cheer", "crowd_ooh", "crowd_groan", "crowd_boo",
  "applause", "crowd_clap", "whistle", "telegraph", "strike_call", "tv_impact", "tv_rewind", "tv_freeze", "tv_pen", "tv_tick" }
A.WARM_STINGERS = { "strikeout", "home_run", "error", "ejection", "charge" }
function A.warmSteps(step)
  local X = ext()
  if not (X and X.sfx) then return end
  local M = _G.AudioManifest
  for _, n in ipairs(A.WARM_SFX) do
    local e = M and M.sfx and M.sfx[n]
    local nf = (e and e.files and #e.files) or 1
    step("sfx " .. n .. (nf > 1 and (" x" .. nf) or ""), function()
      for i = 1, (nf > 1 and nf * 8 or 1) do pcall(X.sfx, n, 0) end
    end)
  end
  for _, n in ipairs(A.WARM_STINGERS) do
    step("stinger " .. n, function() pcall(X.stinger, n, 0) end)
  end
end

-- the ones the loader plays once silently (the others can play over a wipe or card, where a
-- first-use disk read doesn't cost a 3D frame)
A.TV_PRELOAD = { "tv_impact", "tv_rewind", "tv_freeze" }

function A.sfx(kind, v)
  if REACT[kind] then react(kind, v) return end
  if ext() then
    local f = EXT[kind]
    if f then f(v) end
    return
  end
  if kind == "crack" then
    BCKit.voice("crack", snd.kWaveNoise, 0, 0.05, 0, 0.02, 0.7):playNote(5000, 1, 0.05)
    BCKit.voice("crack2", snd.kWaveSquare, 0, 0.03, 0, 0.01, 0.3):playNote(1200, 1, 0.02)
  elseif kind == "pop" then
    BCKit.voice("pop", snd.kWaveNoise, 0, 0.06, 0, 0.02, 0.5):playNote(300, 1, 0.04)
  elseif kind == "foul" then
    BCKit.voice("foul", snd.kWaveNoise, 0, 0.04, 0, 0.02, 0.35):playNote(3500, 1, 0.03)
    A.ooh(0.25)
  elseif kind == "whoosh" then
    BCKit.voice("whoosh", snd.kWaveNoise, 0.08, 0.12, 0, 0.05, 0.12):playNote(1500, 0.6, 0.15)
  elseif kind == "thud" then
    BCKit.sfx("thud")
    A.ooh(0.5)
  elseif kind == "roar" then
    A.roar(v or 0.7)
  elseif kind == "ooh" then
    A.ooh(v or 0.6)
  elseif kind == "fanfare" then
    BCKit.sfx("fanfare")
  elseif kind:sub(1, 2) == "tv" then
    A.tvSynth(kind)
  elseif kind == "organ" then
    local t = snd.getCurrentTime()
    -- "charge!"
    local notes = { 392, 523, 659, 784, 0, 659, 784 }
    local lens = { 0.14, 0.14, 0.14, 0.24, 0.1, 0.12, 0.5 }
    for i = 1, #notes do
      -- one voice per note: a synth only buffers one pending note
      if notes[i] > 0 then BCKit.voice("organ" .. i, snd.kWaveSquare, 0.01, 0.05, 0.7, 0.08, 0.16):playNote(notes[i], 0.6, lens[i] * 0.85, t) end
      t = t + lens[i]
    end
  end
end

--- Synth fallbacks for the TV stings (no audio module): short and cheap.
function A.tvSynth(kind)
  local V = BCKit.voice
  local t = snd.getCurrentTime()
  if kind == "tvWhoosh" then
    V("tvw", snd.kWaveNoise, 0.1, 0.15, 0, 0.08, 0.15):playNote(2500, 0.6, 0.18)
  elseif kind == "tvIdent" or kind == "tvReplay" then
    local notes = kind == "tvIdent" and { 523, 659, 784, 1047 } or { 784, 1047 }
    for i, n in ipairs(notes) do V("tvi" .. i, snd.kWaveSawtooth, 0.01, 0.2, 0.4, 0.3, 0.12):playNote(n, 0.6, 0.18, t + (i - 1) * 0.09) end
  elseif kind == "tvBulletin" then
    for i = 0, 3 do V("tvb" .. i, snd.kWaveSquare, 0, 0.05, 0.6, 0.05, 0.12):playNote(i == 3 and 1175 or 880, 0.5, i == 3 and 0.4 or 0.1, t + i * 0.16) end
  elseif kind == "tvImpact" then
    V("tvx", snd.kWaveNoise, 0, 0.3, 0, 0.1, 0.4):playNote(200, 1, 0.3)
  elseif kind == "tvPen" or kind == "tvTick" or kind == "tvFreeze" then
    V("tvp", snd.kWaveSquare, 0, 0.03, 0, 0.02, 0.1):playNote(kind == "tvPen" and 2600 or 1800, 0.4, 0.03)
  elseif kind == "tvRewind" then
    V("tvr", snd.kWaveSquare, 0, 0.5, 0.3, 0.1, 0.06):playNote(300, 0.4, 0.6)
  end
end
