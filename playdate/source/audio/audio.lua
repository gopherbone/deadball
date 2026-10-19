--[[
DEADBALL audio — ballpark organ music, stingers and sound effects.   import "audio/audio"

Single entry file. Defines the global `Audio`. Everything is lazy: nothing is loaded until
first use, and Audio.init() is called implicitly by every function (calling it yourself at
boot is fine and cheap).

MUSIC  (one cue at a time; starting a cue stops the previous one)
  Audio.play(cue, opts)        -> true/false
      opts.loop    = bool      default: the cue's own setting (Audio.info(cue).loop)
      opts.volume  = 0..1      per-cue gain (multiplied with the music volume)
      opts.fade    = seconds   fade in
      opts.organ   = bool      force our MIDI organ arrangement even if a recording exists
      opts.restart = bool      restart if this cue is already playing (default: keep going)
  Audio.stop(cue|nil, fadeSeconds)   stop that cue (or everything incl. stingers if nil)
  Audio.current()              -> name of the playing music cue or nil
STINGERS (short one-shots over the music; the music ducks while they play)
  Audio.stinger(cue, volume, organ) -> duration (s); any cue name works as a stinger. Plays
                               the recording if the cue has one, else (or if organ=true)
                               our MIDI organ arrangement
SOUND EFFECTS
  Audio.sfx(name, volume)      -> duration in seconds (e.g. wait for "modem" at boot), 0 when
                               muted, false for an unknown name (so callers can fall back)
  Audio.stopSfx(name|nil)      stop a long sampled sfx early (e.g. skipping the boot modem)
  Audio.ambience(name|nil, volume)   loop a bed (e.g. "crowd_ambience", "teletype"); nil stops it
  Any synthesized recipe can be forced with a "_synth" suffix, e.g. "modem_synth" (4.5 s)
SETTINGS (the caller persists them; Audio only applies them)
  Audio.setMusicVolume(0..1)  Audio.setSfxVolume(0..1)
  Audio.setMuted(bool)  Audio.setMusicMuted(bool)  Audio.setSfxMuted(bool)
  Audio.getSettings()          -> { music=, sfx=, muted=, musicMuted=, sfxMuted=, lowCPU=, pa= }
  Audio.setLowCPU(bool)        organ cues drop chords/bass/chorus and the PA effects (use
                               while BallCast's renderer is busy if frame time is tight)
  Audio.setPA(bool)            "stadium PA" filter + echo on the organ (default on)
INTROSPECTION
  Audio.list()                 -> { music = {...}, stingers = {...}, sfx = {...} } (sorted names)
  Audio.info(cue)              -> manifest entry { kind, loop, desc, file?, midi? } or nil
  Audio.credits()              -> path of audio/credits.json (title/author/url/license per file)

Cues (see audio/README.md for where to use them):
  music:    take_me_out, stretch_vamp, summertime, sweet_georgia, hat_dance, gladiators,
            stars_stripes, turkey_straw, funeral_march, pop_weasel, hail_chief,
            wedding_march, bridal_chorus,
            ragtime, casey
  stingers: charge, charge_band, home_run, strikeout, error, ejection, bet_won, bet_lost,
            pack_opened, new_mail, arrest
  sfx (recorded): crowd_roar, crowd_cheer, crowd_boo, crowd_ooh, crowd_groan, crowd_clap,
            crowd_ambience, applause, bat_crack, mitt_pop, whistle, police_whistle,
            vendor_bell, vendor_call, telegraph, teletype, typewriter, typewriter_bell,
            modem (≈12.6 s), modem_full (≈26 s), cash_register, pack_tear, card_flip,
            card_shuffle, siren, handcuffs, jail_door, phone_ring, pa_chime
  sfx (synth): strike_call, out_call, focus, select, back, error_blip, tick, detent, chime,
            mail (+ "_synth" versions of most recorded names)
            (aliases for ui/sound.lua: blip=focus, error=error_blip, cash/coin=cash_register)
Unknown names are ignored (printed once), never an error.

CPU: recordings stream from disk as IMA ADPCM through one fileplayer (cheap). Organ cues
use at most 9 sample-playback synth voices (lead 2, chords 3, bass 1, chorus 2 + stinger
set) and a 4-effect PA chain on one channel; Audio.setLowCPU(true) cuts that to the lead
line with no effects. Fades use playdate.timer (main.lua already calls updateTimers()).
]]

import "CoreLibs/timer"
import "audio/manifest"
import "audio/organ"
import "audio/sfx"

local snd <const> = playdate.sound

Audio = Audio or {}
local A = Audio
local M = AudioManifest or { cues = {}, sfx = {}, organs = {} }

local st = { music = 0.7, sfx = 0.8, muted = false, musicMuted = false, sfxMuted = false,
             lowCPU = false, pa = false } -- PA chain off by default: overdrive + echo muddied the organ
local inited = false
local organCh, recCh, sfxCh, paFx
local fp                      -- the one music fileplayer
local current                 -- { name, mode = "file"|"midi", seq, gain, token }
local fade, fadeTimer = 1, nil
local duck = 1
local sting                   -- { seq | sp, token }
local token = 0
local inst                    -- { music = {role = instrument}, sting = {...} }
local seqCache = {}           -- "name" -> sequence
local spCache = {}            -- file -> sampleplayer
local attached = {}           -- source -> channel it was added to
local amb                     -- { name, sp }
local warned = {}

local ROLE_GAIN <const> = { 0.6, 0.32, 0.5, 0 } -- lead, chords, bass, chorus double (muted: the detuned double beat audibly)
local DUCK <const> = 0.3

local function warn(what, name)
  local k = what .. ":" .. tostring(name)
  if not warned[k] then warned[k] = true; print("[audio] " .. what .. ": " .. tostring(name)) end
end

local function musicLevel() return (st.muted or st.musicMuted) and 0 or st.music end
local function sfxLevel() return (st.muted or st.sfxMuted) and 0 or st.sfx end

local function applyVolumes()
  if not inited then return end
  organCh:setVolume(musicLevel())
  recCh:setVolume(musicLevel())
  sfxCh:setVolume(sfxLevel())
  AudioSfx.setVolume(sfxLevel())
  local g = current and (current.gain * fade * duck) or 0
  if fp and current and current.mode == "file" then fp:setVolume(g) end
  if inst then
    for i, ins in ipairs(inst.music) do ins:setVolume(ROLE_GAIN[i] * ((current and current.mode == "midi") and g or 0)) end
    local sg = sting and sting.gain or 1
    for i, ins in ipairs(inst.sting) do ins:setVolume(ROLE_GAIN[i] * sg) end
  end
end

-- Organ sample per role (manifest: organ = { lead=, chords=, bass= } naming organs entries;
-- each sample sits in the register it plays, so nothing is stretched more than ~1 octave).
local function organSpec(role)
  local o = M.organ
  local name = type(o) == "table" and o[role] or o
  return M.organs and (M.organs[name or "tonewheel"] or M.organs.tonewheel) or nil
end

local function ensureInstruments()
  if inst then return inst end
  local function set()
    return {
      AudioOrgan.instrument(organSpec("lead"), 2, organCh),
      AudioOrgan.instrument(organSpec("chords"), 3, organCh),
      AudioOrgan.instrument(organSpec("bass"), 1, organCh, { release = 0.04 }),
      AudioOrgan.instrument(organSpec("lead"), 2, organCh, { detune = 0.09 }),
    }
  end
  inst = { music = set(), sting = set() }
  applyVolumes()
  return inst
end

-- MIDI files from tools/audio/midi.py are format 1: sequence track 1 is the tempo track,
-- tracks 2..5 = lead, chords, bass, lead double (sequence tracks follow MTrk order).
local TRACK_OFFSET <const> = 1

local function applyLowCPU(seq)
  for i = 2 + TRACK_OFFSET, 4 + TRACK_OFFSET do
    local tr = seq:getTrackAtIndex(i)
    if tr then tr:setMuted(st.lowCPU) end
  end
end

-- Load (once) and wire a MIDI cue to an instrument set.
local function sequenceFor(name, cue, set)
  local key = name .. "/" .. set
  local seq = seqCache[key]
  if seq == nil then
    seq = snd.sequence.new(cue.midi)
    if not seq or seq:getTrackCount() == 0 then
      warn("midi missing", cue.midi)
      seqCache[key] = false
      return nil
    end
    local roles = ensureInstruments()[set]
    for i = 1, seq:getTrackCount() do
      local tr = seq:getTrackAtIndex(i)
      local role = roles[i - TRACK_OFFSET]
      if tr and role then tr:setInstrument(role) end
    end
    seqCache[key] = seq
  end
  if seq then applyLowCPU(seq) end
  return seq or nil
end

-- The PA chain costs CPU even when silent, so it is only attached while organ (MIDI)
-- music or a MIDI stinger is sounding.
local function updatePA()
  if not inited then return end
  local busy = (current and current.mode == "midi") or (sting and sting.seq ~= nil)
  local want = st.pa and not st.lowCPU and busy
  if want and not paFx then paFx = AudioOrgan.addPA(organCh)
  elseif not want and paFx then AudioOrgan.removePA(organCh, paFx); paFx = nil end
end

local function stopFadeTimer()
  if fadeTimer then fadeTimer:remove(); fadeTimer = nil end
end

local function fadeTo(target, seconds, done)
  stopFadeTimer()
  if not seconds or seconds <= 0 or not playdate.timer then
    fade = target; applyVolumes()
    if done then done() end
    return
  end
  local from = fade
  fadeTimer = playdate.timer.new(math.floor(seconds * 1000), from, target)
  fadeTimer.updateCallback = function(t) fade = t.value; applyVolumes() end
  fadeTimer.timerEndedCallback = function() fade = target; fadeTimer = nil; applyVolumes(); if done then done() end end
end

local function stopMusicNow()
  stopFadeTimer()
  if current then
    if current.mode == "file" and fp then fp:stop()
    elseif current.seq then current.seq:stop(); current.seq:allNotesOff() end
  end
  current = nil
  fade = 1
  updatePA()
end

local function stopStingerNow()
  if sting then
    if sting.seq then sting.seq:stop(); sting.seq:allNotesOff() end
    if sting.sp then sting.sp:stop() end
  end
  sting = nil
  duck = 1
  applyVolumes()
  updatePA()
end

-------------------------------------------------------------------------------------------

function A.init()
  if inited then return end
  inited = true
  organCh = snd.channel.new()
  recCh = snd.channel.new()
  sfxCh = snd.channel.new()
  AudioSfx.channel = sfxCh
  AudioSfx.volume = sfxLevel
  applyVolumes()
end

function A.info(name) return M.cues[name] end

function A.current() return current and current.name or nil end

function A.play(name, opts)
  A.init()
  opts = opts or {}
  local cue = M.cues[name]
  if not cue then warn("unknown cue", name); return false end
  if cue.kind == "stinger" and opts.loop == nil then
    A.stinger(name, opts.volume, opts.organ)
    return true
  end
  if current and current.name == name and not opts.restart then
    current.gain = opts.volume or current.gain
    fadeTo(1, opts.fade)
    return true
  end
  stopMusicNow()
  local loop = opts.loop
  if loop == nil then loop = cue.loop and true or false end
  token = token + 1
  local my = token
  local useMidi = cue.midi and (opts.organ or not cue.file)
  current = { name = name, gain = opts.volume or cue.gain or 1, token = my }
  fade = (opts.fade and opts.fade > 0) and 0 or 1
  if useMidi then
    local seq = sequenceFor(name, cue, "music")
    if not seq then current = nil; return false end
    current.mode, current.seq = "midi", seq
    seq:goToStep(1)
    -- steps are 1-based; loopCount 0 = forever, 1 = play once (then the callback fires)
    seq:setLoops(1, 1 + (cue.steps or seq:getLength()), loop and 0 or 1)
    applyVolumes()
    updatePA()
    seq:play(function() if current and current.token == my and not loop then current = nil; updatePA() end end)
  elseif cue.file then
    if not fp then fp = snd.fileplayer.new(); recCh:addSource(fp) end
    local ok = fp:load(cue.file)
    if ok == false then warn("music file missing", cue.file); current = nil; return false end
    current.mode = "file"
    fp:setFinishCallback(function() if current and current.token == my then current = nil end end)
    applyVolumes()
    fp:play(loop and 0 or 1)
  else
    current = nil
    return false
  end
  if opts.fade and opts.fade > 0 then fadeTo(1, opts.fade) end
  return true
end

function A.stop(name, fadeSeconds)
  if not inited then return end
  if name == nil or (sting and sting.name == name) then stopStingerNow() end
  if current and (name == nil or current.name == name) then
    if fadeSeconds and fadeSeconds > 0 then
      local my = current.token
      fadeTo(0, fadeSeconds, function() if current and current.token == my then stopMusicNow() end end)
    else
      stopMusicNow()
    end
  end
end

local function attach(src, ch)
  if attached[src] ~= ch then
    if attached[src] then attached[src]:removeSource(src) end
    ch:addSource(src)
    attached[src] = ch
  end
end

local function samplePlayer(file)
  local sp = spCache[file]
  if sp == nil then
    sp = snd.sampleplayer.new(file) or false
    if not sp then warn("sample missing", file) end
    spCache[file] = sp
  end
  return sp or nil
end

function A.stinger(name, volume, organ)
  A.init()
  local cue = M.cues[name]
  if not cue then warn("unknown cue", name); return 0 end
  stopStingerNow()
  token = token + 1
  local my = token
  local function done() if sting and sting.token == my then sting = nil; duck = 1; applyVolumes(); updatePA() end end
  sting = { name = name, token = my, gain = volume or 1 }
  duck = current and DUCK or 1
  local dur = 0
  if cue.midi and (organ or not cue.file) then
    local seq = sequenceFor(name, cue, "sting")
    if not seq then sting = nil; duck = 1; applyVolumes(); return 0 end
    sting.seq = seq
    seq:goToStep(1)
    seq:setLoops(1, 1 + (cue.steps or seq:getLength()), 1)
    applyVolumes()
    updatePA()
    seq:play(done)
    dur = (cue.steps or seq:getLength()) / math.max(1, seq:getTempo())
  elseif cue.file then
    local sp = samplePlayer(cue.file)
    if not sp then sting = nil; duck = 1; applyVolumes(); return 0 end
    sting.sp = sp
    attach(sp, recCh)
    sp:setVolume((volume or 1) * (cue.gain or 1))
    sp:setFinishCallback(done)
    applyVolumes()
    sp:play(1)
    dur = sp:getLength()
  end
  return dur
end

local function sfxFile(name)
  local e = M.sfx and M.sfx[name]
  if not e or not e.files or #e.files == 0 then return nil end
  return e.files[math.random(#e.files)], e.gain or 1
end

-- names the shell's ui/sound.lua (Sfx.CUES) already uses
local ALIAS <const> = { blip = "focus", error = "error_blip", cash = "cash_register", coin = "cash_register" }

function A.sfx(name, volume)
  A.init()
  name = ALIAS[name] or name
  if name:sub(-6) == "_synth" and AudioSfx.has(name:sub(1, -7)) then
    return sfxLevel() > 0 and AudioSfx.play(name:sub(1, -7), volume or 1) or 0
  end
  if not ((M.sfx and M.sfx[name]) or AudioSfx.has(name)) then warn("unknown sfx", name); return false end
  local v = volume or 1
  if sfxLevel() <= 0 then return 0 end
  local file, gain = sfxFile(name)
  if file then
    local sp = samplePlayer(file)
    if sp then
      attach(sp, sfxCh)
      sp:setVolume(math.min(1, v * gain))
      sp:play(1, 1 + (math.random() - 0.5) * 0.06)
      return sp:getLength()
    end
  end
  return AudioSfx.play(name, v)
end

--- Stop a sampled sfx that is still playing (e.g. skip the boot modem). nil = all.
function A.stopSfx(name)
  if not inited then return end
  for n, e in pairs(M.sfx or {}) do
    if name == nil or n == name then
      for _, f in ipairs(e.files or {}) do
        local sp = spCache[f]
        if sp and (not amb or amb.sp ~= sp) then sp:stop() end
      end
    end
  end
end

function A.ambience(name, volume)
  A.init()
  if amb then
    if amb.sp then amb.sp:stop() end
    amb = nil
  end
  if not name then return end
  local file, gain = sfxFile(name)
  local sp = file and samplePlayer(file)
  if sp then
    attach(sp, sfxCh)
    sp:setVolume(math.min(1, (volume or 0.5) * gain))
    sp:play(0)
    amb = { name = name, sp = sp }
  else
    AudioSfx.play(name, volume or 0.5) -- synth fallback: one swell, not a loop
  end
end

-- settings ------------------------------------------------------------------------------

local function clamp(x) return math.max(0, math.min(1, x or 0)) end
function A.setMusicVolume(v) st.music = clamp(v); applyVolumes() end
function A.setSfxVolume(v) st.sfx = clamp(v); applyVolumes() end
function A.setMuted(f) st.muted = f and true or false; applyVolumes() end
function A.setMusicMuted(f) st.musicMuted = f and true or false; applyVolumes() end
function A.setSfxMuted(f) st.sfxMuted = f and true or false; applyVolumes() end

function A.getSettings()
  return { music = st.music, sfx = st.sfx, muted = st.muted, musicMuted = st.musicMuted,
           sfxMuted = st.sfxMuted, lowCPU = st.lowCPU, pa = st.pa }
end

function A.setLowCPU(f)
  st.lowCPU = f and true or false
  if inited then
    for _, seq in pairs(seqCache) do if seq then applyLowCPU(seq) end end
    updatePA()
  end
end

function A.setPA(f)
  st.pa = f and true or false
  updatePA()
end

-- introspection -------------------------------------------------------------------------

function A.list()
  local music, stingers, sfx, seen = {}, {}, {}, {}
  for k, c in pairs(M.cues) do
    if c.kind == "stinger" then stingers[#stingers + 1] = k else music[#music + 1] = k end
  end
  for k in pairs(M.sfx or {}) do sfx[#sfx + 1] = k; seen[k] = true end
  for _, k in ipairs(AudioSfx.names()) do if not seen[k] then sfx[#sfx + 1] = k end end
  table.sort(music); table.sort(stingers); table.sort(sfx)
  return { music = music, stingers = stingers, sfx = sfx }
end

function A.credits() return "audio/credits.json" end
