-- Ballpark organ instruments for the MIDI cues (internal to audio/audio.lua).
--
-- Each voice is a playdate.sound.synth playing a short organ note sample tuned to C4: an
-- attack section (key click + percussion) followed by a seamless sustain loop. One sample
-- voice per note is far cheaper than stacking sine "drawbars" live, and it lets the same
-- code play either our synthesized tonewheel tone (audio/organ/tonewheel, made by
-- tools/audio/organ_wave.py) or a real organ note sample if the manifest names one.
-- A shared slow LFO adds tonewheel-ish vibrato; the lead is doubled a few cents sharp on a
-- second instrument (MIDI channel 4) for chorus. The "stadium PA" is an effect chain on the
-- organ channel: band-limit (high-pass + low-pass), a touch of overdrive, and a slapback echo
-- off the bleachers.

local snd <const> = playdate.sound

AudioOrgan = AudioOrgan or {}
local O = AudioOrgan

local samples = {}   -- file -> sample (decompressed PCM)
local vibrato        -- shared LFO
local cheapWave      -- one-voice square fallback synth template

local function sampleFor(spec)
  local s = samples[spec.file]
  if s == nil then
    local err
    s, err = snd.sample.new(spec.file)
    if not s then
      print("[audio] organ sample missing: " .. tostring(spec.file) .. " " .. tostring(err))
      s = false
    else
      -- synths need uncompressed PCM; this is a no-op for PCM files
      if s.decompress then pcall(s.decompress, s) end
    end
    samples[spec.file] = s
  end
  return s or nil
end

local function vib()
  if not vibrato then
    vibrato = snd.lfo.new(snd.kLFOSine)
    vibrato:setRate(6.4)
    vibrato:setDepth(0.05 / 12) -- 0.05 semitone: a hint of tonewheel, not a wobble (frequency mod: 1.0 = one octave)
    vibrato:setGlobal(true)
  end
  return vibrato
end

--- A synth voice for the organ described by `spec` (manifest organs entry), or a plain
--- square-wave voice when spec is nil or its sample is missing.
function O.voice(spec, opts)
  opts = opts or {}
  local s
  local smp = spec and sampleFor(spec)
  if smp then
    s = snd.synth.new(smp, spec.loopStart, spec.loopEnd)
    s:setADSR(0.004, 0, 1, opts.release or 0.07)
  else
    s = snd.synth.new(snd.kWaveSquare)
    s:setParameter(1, 0.3) -- narrow-ish pulse: reedy, cheap
    s:setADSR(0.005, 0.08, 0.6, opts.release or 0.06)
  end
  if opts.vibrato ~= false then s:setFrequencyMod(vib()) end
  return s
end

--- An instrument with n voices on `channel`. opts: detune (semitones), volume, release.
function O.instrument(spec, n, channel, opts)
  opts = opts or {}
  local inst = snd.instrument.new()
  local proto = O.voice(spec, opts)
  for i = 1, n do
    inst:addVoice(i == 1 and proto or proto:copy())
  end
  if opts.detune then inst:setTranspose(opts.detune) end
  inst:setVolume(opts.volume or 1)
  if channel then channel:addSource(inst) end
  return inst
end

--- The "stadium PA" chain. Returns a table of effects so they can be removed for low CPU.
function O.addPA(channel)
  local fx = {}
  local hp = snd.twopolefilter.new(snd.kFilterHighPass)
  hp:setFrequency(220); hp:setResonance(0.1)
  local lp = snd.twopolefilter.new(snd.kFilterLowPass)
  lp:setFrequency(4200); lp:setResonance(0.25)
  local od = snd.overdrive.new()
  od:setGain(1.6); od:setLimit(0.8); od:setMix(0.35)
  local echo = snd.delayline.new(0.3)
  echo:setFeedback(0.28)
  echo:setMix(0.22)
  fx = { hp, lp, od, echo }
  for _, e in ipairs(fx) do channel:addEffect(e) end
  return fx
end

function O.removePA(channel, fx)
  for _, e in ipairs(fx or {}) do channel:removeEffect(e) end
end
