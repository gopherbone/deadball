-- Synthesized sound effects (internal to audio/audio.lua). These are the FALLBACK path:
-- Audio.sfx() plays a real recording from the manifest when one exists and only uses these
-- recipes for names that have no sample (and for the tiny UI blips, which are synth by
-- design). Every recipe schedules notes on cached synths with absolute sound-engine times,
-- so nothing here needs per-frame updates. Each recipe returns its duration in seconds.

local snd <const> = playdate.sound

AudioSfx = AudioSfx or {}
local S = AudioSfx

local voices = {}
local chans = {}

-- A cached synth for one role in one recipe (a synth only buffers one pending note).
local function voice(key, wave, a, d, s, r, ch)
  local v = voices[key]
  if not v then
    v = snd.synth.new(wave)
    v:setADSR(a or 0, d or 0.05, s or 0, r or 0.02)
    ;(ch or S.channel):addSource(v)
    voices[key] = v
  end
  return v
end

-- A cached channel with one filter (crowd, boos, whistles...). Routed at sfx volume.
local function fchan(key, ftype, freq, res)
  local c = chans[key]
  if not c then
    c = snd.channel.new()
    local f = snd.twopolefilter.new(ftype)
    f:setFrequency(freq)
    f:setResonance(res or 0.3)
    c:addEffect(f)
    chans[key] = c
  end
  c:setVolume(S.volume and S.volume() or 1)
  return c
end

local function lfo(kind, rate, depth, retrigger)
  local l = snd.lfo.new(kind)
  l:setRate(rate)
  l:setDepth(depth)
  if retrigger then l:setRetrigger(true) end
  return l
end

local function now() return snd.getCurrentTime() end

-- glide LFOs (sawtooth, retriggered on note-on): a one-shot pitch ramp of `oct` octaves
local glides = {}
local function glide(key, seconds, oct)
  local l = glides[key]
  if not l then
    l = lfo(oct > 0 and snd.kLFOSawtoothUp or snd.kLFOSawtoothDown, 1 / seconds, math.abs(oct) / 2, true)
    glides[key] = l
  end
  return l
end

local R = {}

-- UI ------------------------------------------------------------------------------------
function R.focus(v) voice("focus", snd.kWaveSquare, 0, 0.012, 0, 0.005):playNote(1900, 0.12 * v, 0.012) return 0.02 end
function R.select(v)
  local t = now()
  voice("sel1", snd.kWaveTriangle, 0, 0.05, 0.2, 0.04):playNote(880, 0.25 * v, 0.04, t)
  voice("sel2", snd.kWaveTriangle, 0, 0.05, 0.2, 0.04):playNote(1320, 0.25 * v, 0.06, t + 0.045)
  return 0.12
end
function R.back(v)
  local t = now()
  voice("back1", snd.kWaveTriangle, 0, 0.05, 0.2, 0.04):playNote(990, 0.22 * v, 0.04, t)
  voice("back2", snd.kWaveTriangle, 0, 0.05, 0.2, 0.04):playNote(620, 0.22 * v, 0.06, t + 0.045)
  return 0.12
end
function R.error_blip(v)
  voice("err", snd.kWaveSawtooth, 0, 0.12, 0.3, 0.05):playNote(110, 0.2 * v, 0.16)
  return 0.2
end

function R.tick(v) voice("tick", snd.kWaveNoise, 0, 0.008, 0, 0.004):playNote(4000, 0.12 * v, 0.006) return 0.01 end
function R.detent(v) voice("detent", snd.kWaveSquare, 0, 0.006, 0, 0.004):playNote(2600, 0.08 * v, 0.006) return 0.01 end
function R.chime(v)
  local t = now()
  for i, f in ipairs({ 523.25, 659.25, 783.99, 1046.5 }) do
    voice("chime" .. i, snd.kWaveSine, 0.005, 0.25, 0.3, 0.35):playNote(f, 0.2 * v, i == 4 and 0.5 or 0.12, t + (i - 1) * 0.11)
  end
  return 0.9
end
function R.mail(v)
  local t = now()
  voice("mail1", snd.kWaveSine, 0.005, 0.25, 0.3, 0.35):playNote(1568, 0.18 * v, 0.08, t)
  voice("mail2", snd.kWaveSine, 0.005, 0.25, 0.3, 0.35):playNote(2093, 0.18 * v, 0.2, t + 0.09)
  return 0.5
end

-- ballpark ----------------------------------------------------------------------------
function R.bat_crack(v)
  local t = now()
  voice("crk1", snd.kWaveNoise, 0, 0.045, 0, 0.02):playNote(6000, 0.8 * v, 0.04, t)
  voice("crk2", snd.kWaveSquare, 0, 0.025, 0, 0.01):playNote(1250, 0.35 * v, 0.02, t)
  voice("crk3", snd.kWaveSine, 0, 0.05, 0, 0.02):playNote(190, 0.6 * v, 0.03, t)
  return 0.08
end

function R.mitt_pop(v)
  local c = fchan("mitt", snd.kFilterLowPass, 1400, 0.4)
  local t = now()
  voice("mit1", snd.kWaveNoise, 0, 0.05, 0, 0.02, c):playNote(800, 0.9 * v, 0.03, t)
  voice("mit2", snd.kWaveSine, 0, 0.06, 0, 0.02):playNote(140, 0.7 * v, 0.04, t)
  return 0.09
end

local function crowd(v, len, bright)
  local c = fchan("crowd", snd.kFilterBandPass, bright and 1100 or 800, 0.25)
  local n1 = voice("crowd1", snd.kWaveNoise, 0.35, 0.6, 0.55, 1.2, c)
  local n2 = voice("crowd2", snd.kWaveNoise, 0.2, 0.4, 0.4, 1.0, c)
  if not voices.crowdAM then
    local am = lfo(snd.kLFOSampleAndHold, 22, 0.25)
    am:setCenter(0.75)
    n2:setAmplitudeMod(am)
    voices.crowdAM = am
  end
  local t = now()
  n1:playNote(500, 0.9 * v, len, t)
  n2:playNote(1500, 0.6 * v, len * 0.8, t + 0.05)
  return len + 1.2
end
function R.crowd_roar(v) return crowd(v, 2.4, true) end
function R.crowd_cheer(v) return crowd(v, 1.2, true) end
function R.applause(v) return crowd(v * 0.8, 1.8, true) end
function R.crowd_ambience(v) return crowd(v * 0.35, 4, false) end

local function boo(v, up)
  local c = fchan(up and "ooh" or "boo", snd.kFilterLowPass, up and 900 or 650, 0.5)
  local t = now()
  local base = up and 200 or 150
  for i, f in ipairs({ base, base * 1.06, base * 1.13, base * 0.94 }) do
    local s = voice((up and "ooh" or "boo") .. i, snd.kWaveSawtooth, 0.15, 0.2, 0.8, 0.5, c)
    s:setFrequencyMod(glide((up and "oohg" or "boog") .. i, 1.6, up and 0.12 or -0.18))
    s:playNote(f, 0.22 * v, 1.4, t + i * 0.04)
  end
  return 1.9
end
function R.crowd_boo(v) return boo(v, false) end
function R.crowd_ooh(v) return boo(v, true) end

-- "Steee-rike!": an "s" hiss, then a buzzy voice gliding up through a bright "ee" band,
-- dropping into "-rike" with a "k" click.
function R.strike_call(v)
  local t = now()
  local ee = fchan("ee", snd.kFilterBandPass, 2300, 0.55)
  local ai = fchan("ai", snd.kFilterBandPass, 850, 0.5)
  voice("s_s", snd.kWaveNoise, 0.02, 0.05, 0.6, 0.03, fchan("hiss", snd.kFilterHighPass, 4500, 0.2))
    :playNote(5000, 0.5 * v, 0.14, t)
  local e = voice("s_ee", snd.kWaveSawtooth, 0.03, 0.1, 0.9, 0.05, ee)
  e:setFrequencyMod(glide("s_eeg", 0.7, 0.25))
  e:playNote(190, 0.7 * v, 0.62, t + 0.12)
  local r = voice("s_ai", snd.kWaveSawtooth, 0.02, 0.1, 0.8, 0.08, ai)
  r:setFrequencyMod(glide("s_aig", 0.35, -0.3))
  r:playNote(230, 0.7 * v, 0.28, t + 0.74)
  voice("s_k", snd.kWaveNoise, 0, 0.02, 0, 0.01):playNote(3000, 0.35 * v, 0.02, t + 1.04)
  return 1.1
end

function R.out_call(v)
  local t = now()
  local ai = fchan("ai", snd.kFilterBandPass, 850, 0.5)
  local o = voice("o_ow", snd.kWaveSawtooth, 0.02, 0.1, 0.9, 0.1, ai)
  o:setFrequencyMod(glide("o_owg", 0.5, -0.2))
  o:playNote(210, 0.75 * v, 0.42, t)
  voice("o_t", snd.kWaveNoise, 0, 0.02, 0, 0.01):playNote(3500, 0.3 * v, 0.02, t + 0.45)
  return 0.55
end

function R.whistle(v)
  local c = fchan("whistle", snd.kFilterBandPass, 2800, 0.6)
  local s = voice("whis", snd.kWaveSine, 0.01, 0, 1, 0.05)
  if not voices.whisTrill then
    voices.whisTrill = lfo(snd.kLFOSquare, 28, 0.04)
    s:setFrequencyMod(voices.whisTrill)
  end
  local t = now()
  s:playNote(2700, 0.35 * v, 0.55, t)
  voice("whisn", snd.kWaveNoise, 0.01, 0, 1, 0.05, c):playNote(3000, 0.12 * v, 0.55, t)
  return 0.6
end

function R.vendor_bell(v)
  local t = now()
  for i = 0, 2 do
    voice("bellA" .. i, snd.kWaveSine, 0.001, 0.9, 0, 0.3):playNote(1318, 0.3 * v, 0.9, t + i * 0.22)
    voice("bellB" .. i, snd.kWaveSine, 0.001, 0.5, 0, 0.2):playNote(3570, 0.12 * v, 0.5, t + i * 0.22)
  end
  return 1.4
end

function R.vendor_call(v)
  -- "Hey, PEA-nuts!": two buzzy vowel glides through the voice band
  local t = now()
  local ai = fchan("ai", snd.kFilterBandPass, 850, 0.5)
  local a = voice("vc1", snd.kWaveSawtooth, 0.02, 0.1, 0.8, 0.08, ai)
  a:setFrequencyMod(glide("vc1g", 0.3, 0.15)); a:playNote(240, 0.6 * v, 0.25, t)
  local b = voice("vc2", snd.kWaveSawtooth, 0.02, 0.1, 0.8, 0.08, ai)
  b:setFrequencyMod(glide("vc2g", 0.5, -0.25)); b:playNote(300, 0.6 * v, 0.45, t + 0.35)
  return 0.9
end

-- wire, office, crime ------------------------------------------------------------------
local MORSE = { ".-..", "--.", "-...", "..", "...-", ".-." } -- a few random letters
function R.telegraph(v)
  local t = now() + 0.01
  -- only one pending event per synth: alternate between a few cached clickers
  local k = 0
  local function click(at, f, vol)
    k = k + 1
    voice("tg" .. (k % 12), snd.kWaveSquare, 0, 0.007, 0, 0.004):playNote(f, vol, 0.006, at)
  end
  local letter = MORSE[math.random(#MORSE)]
  for i = 1, #letter do
    local len = letter:sub(i, i) == "." and 0.06 or 0.18
    click(t, 900, 0.35 * v)       -- sounder down
    click(t + len, 1500, 0.2 * v) -- sounder up
    t = t + len + 0.07
  end
  return t - now()
end

function R.typewriter(v)
  local t = now()
  voice("tw1", snd.kWaveNoise, 0, 0.012, 0, 0.005):playNote(4500, 0.5 * v, 0.008, t)
  voice("tw2", snd.kWaveSquare, 0, 0.01, 0, 0.005):playNote(700, 0.2 * v, 0.006, t)
  return 0.03
end

function R.card_flip(v)
  voice("flip", snd.kWaveNoise, 0.003, 0.03, 0, 0.01, fchan("flip", snd.kFilterHighPass, 2500, 0.2))
    :playNote(3000, 0.5 * v, 0.03)
  return 0.05
end

function R.pack_tear(v)
  local c = fchan("tear", snd.kFilterHighPass, 1800, 0.3)
  local s = voice("tear", snd.kWaveNoise, 0.01, 0.1, 0.8, 0.05, c)
  if not voices.tearAM then
    voices.tearAM = lfo(snd.kLFOSampleAndHold, 45, 0.45)
    voices.tearAM:setCenter(0.55)
    s:setAmplitudeMod(voices.tearAM)
  end
  s:playNote(4000, 0.7 * v, 0.38)
  return 0.45
end

function R.cash_register(v)
  local t = now()
  voice("cr_k", snd.kWaveNoise, 0, 0.03, 0, 0.02):playNote(2500, 0.6 * v, 0.03, t)
  voice("cr_d", snd.kWaveNoise, 0, 0.12, 0, 0.04, fchan("drawer", snd.kFilterLowPass, 700, 0.3))
    :playNote(800, 0.8 * v, 0.1, t + 0.06)
  voice("cr_b1", snd.kWaveSine, 0.001, 0.8, 0, 0.3):playNote(2637, 0.35 * v, 0.8, t + 0.12)
  voice("cr_b2", snd.kWaveSine, 0.001, 0.6, 0, 0.3):playNote(3951, 0.2 * v, 0.6, t + 0.12)
  voice("cr_b3", snd.kWaveSine, 0.001, 0.4, 0, 0.2):playNote(6200, 0.08 * v, 0.4, t + 0.12)
  return 1.0
end

function R.siren(v)
  local s = voice("siren", snd.kWaveSawtooth, 0.1, 0, 1, 0.3, fchan("siren", snd.kFilterLowPass, 2200, 0.2))
  if not voices.sirenLFO then
    voices.sirenLFO = lfo(snd.kLFOTriangle, 0.9, 0.25)
    s:setFrequencyMod(voices.sirenLFO)
  end
  s:playNote(700, 0.3 * v, 2.2)
  return 2.5
end

function R.jail_door(v)
  local t = now()
  voice("jd1", snd.kWaveNoise, 0, 0.25, 0, 0.1, fchan("clang", snd.kFilterBandPass, 1200, 0.7))
    :playNote(1000, 0.9 * v, 0.2, t)
  voice("jd2", snd.kWaveSquare, 0, 0.6, 0, 0.3):playNote(311, 0.18 * v, 0.5, t)
  voice("jd3", snd.kWaveSquare, 0, 0.6, 0, 0.3):playNote(440, 0.12 * v, 0.5, t)
  voice("jd4", snd.kWaveSine, 0, 0.3, 0, 0.1):playNote(80, 0.7 * v, 0.25, t)
  return 0.9
end

function R.phone_ring(v)
  local t = now()
  local a = voice("ph1", snd.kWaveSine, 0.005, 0, 1, 0.02)
  local b = voice("ph2", snd.kWaveSine, 0.005, 0, 1, 0.02)
  if not voices.phAM then
    voices.phAM = lfo(snd.kLFOSquare, 20, 0.5); voices.phAM:setCenter(0.5)
    a:setAmplitudeMod(voices.phAM); b:setAmplitudeMod(voices.phAM)
  end
  a:playNote(440, 0.2 * v, 1.0, t); b:playNote(480, 0.2 * v, 1.0, t)
  return 1.1
end

--- A dial-up handshake: dial tone, DTMF, answer tone, V.8/V.34-ish warble and hiss.
function R.modem(v)
  local t = now() + 0.05
  v = 0.12 * v
  local k = 0
  local function tone(f, vol, len, at, wave)
    k = k + 1
    voice("mdm" .. k, wave or snd.kWaveSine, 0.004, 0, 1, 0.01):playNote(f, vol, len, at)
  end
  tone(350, v, 0.5, t); tone(440, v, 0.5, t)
  t = t + 0.6
  local dtmf = { { 770, 1336 }, { 770, 1336 }, { 770, 1336 }, { 941, 1336 }, { 697, 1209 }, { 852, 1477 }, { 852, 1209 } }
  for _, p in ipairs(dtmf) do
    tone(p[1], v, 0.07, t); tone(p[2], v, 0.07, t)
    t = t + 0.1
  end
  t = t + 0.5
  tone(2100, v * 0.9, 0.7, t)                -- answer tone
  t = t + 0.8
  for i = 0, 7 do                            -- warble
    tone((i % 2 == 0) and 980 or 1180, v * 0.6, 0.06, t, snd.kWaveSquare)
    tone((i % 2 == 0) and 1650 or 1850, v * 0.5, 0.06, t)
    t = t + 0.07
  end
  tone(1800, v * 0.4, 0.5, t, snd.kWaveSquare)
  voice("mdmN", snd.kWaveNoise, 0.05, 0, 1, 0.1):playNote(1000, v * 0.8, 0.9, t + 0.3)
  t = t + 1.25
  return t - now()
end

S.recipes = R

function S.has(name) return R[name] ~= nil end

function S.play(name, v)
  local f = R[name]
  if not f then return 0 end
  return f(v or 1) or 0
end

function S.names()
  local out = {}
  for k in pairs(R) do out[#out + 1] = k end
  table.sort(out)
  return out
end

--- Keep filtered sub-channels in step with the sfx volume.
function S.setVolume(x)
  for _, c in pairs(chans) do c:setVolume(x) end
end
