-- Tiny synthesized UI sounds and the boot modem handshake. Mutable from Settings.

local snd <const> = playdate.sound

Sfx = Sfx or {}
Sfx.enabled = true
Sfx.volume = 1.0   -- 0..1, scales the fallback synths

-- When the audio agent's module is present, UI sounds go through it; the synths below
-- are the fallback. Cue names map Sfx.<fn> -> Audio cue.
Sfx.CUES = {
  focus = "blip", select = "select", back = "back", error = "error", tick = "tick", detent = "detent",
  coin = "cash", chime = "chime", mail = "mail", modem = "modem",
}

local function viaAudio(fn)
  if not Audio then return false end
  local cue = Sfx.CUES[fn]
  if not cue then return false end
  local f = Audio.sfx or Audio.play
  if not f then return false end
  local ok, r = pcall(f, cue)
  return ok and r ~= false and r ~= nil
end

--- Music / stingers via the audio module (no-ops without it).
function Sfx.music(cue, opts)
  if Audio and Audio.play and Sfx.enabled then pcall(Audio.play, cue, opts) end
end
function Sfx.stopMusic(fade)
  if Audio and Audio.stop then pcall(Audio.stop, nil, fade) end
end
function Sfx.stinger(cue)
  if Audio and Audio.stinger and Sfx.enabled then
    local ok, d = pcall(Audio.stinger, cue)
    return ok and d
  end
  return false
end
function Sfx.currentMusic()
  if Audio and Audio.current then
    local ok, c = pcall(Audio.current)
    return ok and c or nil
  end
  return nil
end
Sfx.viaAudio = viaAudio

local function mk(wave, a, d, s, r)
  local sy = snd.synth.new(wave)
  sy:setADSR(a or 0, d or 0.03, s or 0, r or 0.02)
  return sy
end

local click = mk(snd.kWaveSquare, 0, 0.012, 0, 0.005)
local blip = mk(snd.kWaveTriangle, 0, 0.05, 0.2, 0.04)
local blip2 = mk(snd.kWaveTriangle, 0, 0.05, 0.2, 0.04)
local buzz = mk(snd.kWaveSawtooth, 0, 0.12, 0.3, 0.05)
local tick = mk(snd.kWaveNoise, 0, 0.008, 0, 0.004)
local chimeA = mk(snd.kWaveSine, 0.005, 0.25, 0.3, 0.35)
local chimeB = mk(snd.kWaveSine, 0.005, 0.25, 0.3, 0.35)
local toneA = mk(snd.kWaveSine, 0.004, 0, 1, 0.01)
local toneB = mk(snd.kWaveSine, 0.004, 0, 1, 0.01)
local noise = mk(snd.kWaveNoise, 0.002, 0, 1, 0.01)
local sq = mk(snd.kWaveSquare, 0.001, 0, 1, 0.005)

-- A synth is monophonic, so sequences are scheduled with timers rather than `when`.
local function now() return 0 end
local function play(sy, f, v, len, t)
  v = v * Sfx.volume
  if not t or t <= 0.001 then sy:playNote(f, v, len) return end
  playdate.timer.performAfterDelay(math.floor(t * 1000), function() if Sfx.enabled then sy:playNote(f, v, len) end end)
end

local lastFocus = 0
function Sfx.focus()
  if not Sfx.enabled then return end
  if viaAudio("focus") then return end
  -- avoid machine-gunning when focus jumps rapidly
  local t = playdate.getCurrentTimeMilliseconds()
  if t - lastFocus < 25 then return end
  lastFocus = t
  click:playNote(1900, 0.12 * Sfx.volume, 0.012)
end

function Sfx.select()
  if not Sfx.enabled then return end
  if viaAudio("select") then return end
  local t = now()
  play(blip, 880, 0.22, 0.04, t)
  play(blip2, 1320, 0.22, 0.06, t + 0.045)
end

function Sfx.back()
  if not Sfx.enabled then return end
  if viaAudio("back") then return end
  local t = now()
  play(blip, 990, 0.2, 0.04, t)
  play(blip2, 620, 0.2, 0.06, t + 0.045)
end

function Sfx.error()
  if not Sfx.enabled then return end
  if viaAudio("error") then return end
  buzz:playNote(110, 0.18 * Sfx.volume, 0.16)
end

function Sfx.tick()
  if not Sfx.enabled then return end
  if viaAudio("tick") then return end
  tick:playNote(4000, 0.12 * Sfx.volume, 0.006)
end

function Sfx.detent()
  if not Sfx.enabled then return end
  if viaAudio("detent") then return end
  click:playNote(2600, 0.08 * Sfx.volume, 0.006)
end

function Sfx.coin()
  if not Sfx.enabled then return end
  if viaAudio("coin") then return end
  local t = now()
  play(chimeA, 1318, 0.18, 0.06, t)
  play(chimeB, 1976, 0.18, 0.25, t + 0.07)
end

function Sfx.chime()
  if not Sfx.enabled then return end
  if viaAudio("chime") then return end
  local t = now()
  local notes = { 523.25, 659.25, 783.99, 1046.5 }
  for i, f in ipairs(notes) do
    local s = (i % 2 == 1) and chimeA or chimeB
    play(s, f, 0.2, i == #notes and 0.5 or 0.12, t + (i - 1) * 0.11)
  end
end

function Sfx.mail()
  if not Sfx.enabled then return end
  if viaAudio("mail") then return end
  local t = now()
  play(chimeA, 1568, 0.16, 0.08, t)
  play(chimeB, 2093, 0.16, 0.2, t + 0.09)
end

--- A short, quiet dial-up handshake followed by a chime. Returns its duration (s).
function Sfx.modem()
  if not Sfx.enabled then return 0 end
  if Audio and Audio.sfx then
    local ok, dur = pcall(Audio.sfx, "modem")
    -- the recording runs ~12 s; the splash cuts it off after ~4 s (Sfx.stopModem)
    if ok and dur ~= false and dur ~= nil then return math.min(type(dur) == "number" and dur or 4, 4.2) end
  end
  local t = now() + 0.05
  local v = 0.09
  -- dial tone
  play(toneA, 350, v, 0.35, t); play(toneB, 440, v, 0.35, t)
  t += 0.42
  -- DTMF: 5 5 5 - 0 1 9 7
  local dtmf = { { 770, 1336 }, { 770, 1336 }, { 770, 1336 }, { 941, 1336 }, { 697, 1209 }, { 852, 1477 }, { 852, 1209 } }
  for _, p in ipairs(dtmf) do
    play(toneA, p[1], v, 0.06, t); play(toneB, p[2], v, 0.06, t)
    t += 0.09
  end
  t += 0.15
  -- answer tone
  play(toneA, 2100, v * 0.8, 0.32, t)
  t += 0.36
  -- handshake warble + hiss
  for i = 0, 9 do
    play(sq, (i % 2 == 0) and 1200 or 2400, v * 0.45, 0.035, t)
    t += 0.04
  end
  play(noise, 1000, v * 0.6, 0.45, t)
  play(toneA, 1650, v * 0.4, 0.45, t)
  t += 0.5
  return t
end

function Sfx.stopModem()
  if Audio and Audio.stopSfx then pcall(Audio.stopSfx, "modem") end
end

-- Ceremony: payouts, losses, stamps, the pager, EXTRA! -----------------------------------

--- Plays a recorded effect through the audio module (audio/manifest.lua sfx); false if absent.
local function rec(name, vol)
  if not (Sfx.enabled and Audio and Audio.sfx) then return false end
  local ok, r = pcall(Audio.sfx, name, vol)
  return ok and r ~= false and r ~= nil
end
Sfx.rec = rec

local thunk = mk(snd.kWaveNoise, 0.001, 0.07, 0, 0.03)
local low = mk(snd.kWaveSquare, 0.001, 0.06, 0, 0.03)
local horn = mk(snd.kWaveSawtooth, 0.02, 0.1, 0.6, 0.12)

--- Cash register: the payout.
function Sfx.kaching()
  if not Sfx.enabled then return end
  if rec("cash_register") then return end
  Sfx.coin()
end

--- A rubber stamp hitting paper (bet placed, job on).
function Sfx.stamp()
  if not Sfx.enabled then return end
  if rec("mitt_pop", 0.8) then return end
  thunk:playNote(180, 0.5 * Sfx.volume, 0.07)
  low:playNote(70, 0.35 * Sfx.volume, 0.05)
end

--- Sad trombone: a net loss.
function Sfx.trombone()
  if not Sfx.enabled then return end
  if Sfx.stinger("bet_lost") then return end
  local notes = { 293.7, 277.2, 261.6, 246.9 }
  for i, f in ipairs(notes) do play(horn, f, 0.16, i == 4 and 0.7 or 0.28, (i - 1) * 0.32) end
end

--- Beep-beep: the pager.
function Sfx.pager()
  if not Sfx.enabled then return end
  play(sq, 2093, 0.12, 0.07, 0)
  play(sq, 2093, 0.12, 0.07, 0.12)
  play(sq, 2637, 0.12, 0.1, 0.24)
end

--- Crowd roar: EXTRA! EXTRA!
function Sfx.roar()
  if not Sfx.enabled then return end
  if rec("crowd_roar", 0.7) then return end
  noise:playNote(800, 0.12 * Sfx.volume, 0.6)
end

--- Siren chirp: heat went up.
function Sfx.siren()
  if not Sfx.enabled then return end
  if rec("police_whistle", 0.5) then return end
  play(toneA, 900, 0.1, 0.12, 0)
  play(toneB, 1300, 0.1, 0.12, 0.13)
end
