-- terra
--
-- percussion synthesizer +
-- generative sequencer
--
-- combines concepts from:
-- UDO DMNO, Space Drum,
-- Esu's Trifecta, Nymira
--
-- E1: page
-- E2/E3: context params
-- K2: play/stop
-- K3: generate pattern
-- K2+K3: toggle drift
--
-- grid layout (128):
-- rows 1-6: step sequencer
-- row 7: track select + mute
-- row 8: transport + modes
--
-- hold grid step + turn E3:
--   adjust velocity
--
-- v1.1 @jamminstein

engine.name = "Terra"

local musicutil = require "musicutil"

-- ============ STATE ============

local NUM_VOICES = 6
local NUM_STEPS = 16
local NUM_FX_SLOTS = 3

-- pages: 1=main, 2=pattern, 3=fx, 4=harmony
local page = 1
local selected_track = 1
local selected_fx_slot = 1
local playing = false
local step = 1
local drift_mode = false
local react_mode = false
local k2_held = false
local swing_amt = 0  -- 0-100, 50=triplet swing

-- clock
local clock_id = nil
local tick_count = 0

-- grid
local g = grid.connect()
local grid_connected = false
local grid_held = {}  -- {x=, y=, time=} for hold detection
local grid_page = 1   -- 1=sequencer, 2=velocity
local mutes = {false, false, false, false, false, false}
local flash = {}      -- {track, step, brightness} for trigger flash
for i = 1, NUM_VOICES do flash[i] = 0 end

-- pattern clipboard
local clipboard = nil  -- {pattern, prob, vel}
local gen_flash = 0    -- countdown for "GEN" indicator
local k3_press_time = 0  -- for hold detection
local K3_HOLD_TIME = 0.4 -- seconds to count as hold
local screen_dirty = true
local grid_dirty = true

-- midi
local midi_out = nil
local opxy_out = nil
local midi_in_device = nil

-- voice names for display
local VOICE_NAMES = {"KICK", "SNARE", "HAT", "PERC", "TONE", "FX"}
local VOICE_SHORT = {"KK", "SN", "HH", "PC", "TN", "FX"}

-- synthesis mode names
local MODE_NAMES = {"FM", "SUB", "NOISE"}

-- fx type names
local FX_NAMES = {"bypass", "delay", "reverb", "filter", "crush", "ring", "chorus", "phaser"}
local FX_PARAMS = {
  {"--", "--"},
  {"time", "feedback"},
  {"size", "shimmer"},
  {"freq", "lfo rate"},
  {"bits", "drive"},
  {"freq", "depth"},
  {"rate", "depth"},
  {"rate", "depth"},
}

-- circle of fifths order (note indices 0-11)
local CIRCLE_OF_FIFTHS = {0, 7, 2, 9, 4, 11, 6, 1, 8, 3, 10, 5}
local NOTE_NAMES_SHARP = {"C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"}

-- ============ VOICE CONFIG ============
local voices = {}
for i = 1, NUM_VOICES do
  voices[i] = {
    mode = 0, base_freq = 60, decay = 0.3,
    filter_freq = 4000, filter_res = 0.3, filter_type = 0,
    pitch_env = 2, pitch_decay = 0.05,
    pan = 0, spread = 0.3, detune = 0, amp = 0.8,
    midi_note = 36 + (i - 1) * 4, midi_ch = 10,
    -- mode-specific deep synth params
    -- FM mode (0): fmIndex, fmRatio
    fm_index = 1.0, fm_ratio = 1.414,
    -- Sub mode (1): shape (0=sine..1=pulse), noise_amt, filter_env_amt
    shape = 0, noise_amt = 0, filter_env_amt = 2000,
    -- Noise mode (2): noise_type (0=white..1=crackle), grain_rate, ring_amt
    noise_type = 0, grain_rate = 40, ring_amt = 0,
  }
end

local function init_voice_presets()
  -- kick: subtractive sine, big pitch sweep
  voices[1].mode = 1; voices[1].base_freq = 48; voices[1].decay = 0.4
  voices[1].pitch_env = 8; voices[1].pitch_decay = 0.04; voices[1].filter_freq = 2000
  voices[1].pan = 0; voices[1].amp = 1.0
  voices[1].shape = 0; voices[1].noise_amt = 0.1; voices[1].filter_env_amt = 1500
  -- snare: noise
  voices[2].mode = 2; voices[2].base_freq = 72; voices[2].decay = 0.2
  voices[2].filter_freq = 5000; voices[2].filter_res = 0.4; voices[2].pan = -0.1
  voices[2].noise_type = 0; voices[2].grain_rate = 60; voices[2].ring_amt = 0
  -- hat: noise, high filter, short
  voices[3].mode = 2; voices[3].base_freq = 100; voices[3].decay = 0.08
  voices[3].filter_freq = 8000; voices[3].filter_type = 1; voices[3].pan = 0.2
  voices[3].noise_type = 0.3; voices[3].grain_rate = 80; voices[3].ring_amt = 0
  -- perc: FM metallic
  voices[4].mode = 0; voices[4].base_freq = 64; voices[4].decay = 0.15
  voices[4].filter_freq = 6000; voices[4].pan = -0.3
  voices[4].fm_index = 1.5; voices[4].fm_ratio = 1.414
  -- tone: FM bell-like
  voices[5].mode = 0; voices[5].base_freq = 72; voices[5].decay = 0.5
  voices[5].filter_freq = 8000; voices[5].pan = 0.3; voices[5].spread = 0.5
  voices[5].fm_index = 0.8; voices[5].fm_ratio = 2.0
  -- fx hit: noise textured
  voices[6].mode = 2; voices[6].base_freq = 55; voices[6].decay = 0.35
  voices[6].filter_freq = 3000; voices[6].filter_res = 0.7; voices[6].pan = 0.4
  voices[6].noise_type = 0.5; voices[6].grain_rate = 30; voices[6].ring_amt = 0.2
end

-- ============ SEQUENCER ============

local seq = {}
for i = 1, NUM_VOICES do
  seq[i] = {
    pattern = {}, prob = {}, vel = {},
    euclid_k = 0, euclid_offset = 0,
    track_prob = 100,  -- global probability for the track (robot-controllable)
  }
  for s = 1, NUM_STEPS do
    seq[i].pattern[s] = 0
    seq[i].prob[s] = 100
    seq[i].vel[s] = 0.8
  end
end

local function euclidean(steps, pulses, offset)
  local pattern = {}
  for i = 1, steps do pattern[i] = 0 end
  if pulses >= steps then
    for i = 1, steps do pattern[i] = 1 end
    return pattern
  end
  if pulses <= 0 then return pattern end
  local bucket = 0
  for i = 1, steps do
    bucket = bucket + pulses
    if bucket >= steps then
      bucket = bucket - steps
      pattern[i] = 1
    end
  end
  if offset > 0 then
    local rotated = {}
    for i = 1, steps do
      rotated[i] = pattern[((i - 1 + offset) % steps) + 1]
    end
    return rotated
  end
  return pattern
end

local function apply_euclidean(track)
  if seq[track].euclid_k > 0 then
    local pat = euclidean(NUM_STEPS, seq[track].euclid_k, seq[track].euclid_offset)
    for s = 1, NUM_STEPS do
      seq[track].pattern[s] = pat[s]
    end
  end
end

local function generate_pattern(track)
  local density = math.random(20, 70) / 100
  for s = 1, NUM_STEPS do
    seq[track].pattern[s] = math.random() < density and 1 or 0
    seq[track].prob[s] = math.random(60, 100)
    seq[track].vel[s] = 0.4 + math.random() * 0.6
  end
end

local function copy_pattern(track)
  clipboard = {
    pattern = {table.unpack(seq[track].pattern)},
    prob = {table.unpack(seq[track].prob)},
    vel = {table.unpack(seq[track].vel)},
    euclid_k = seq[track].euclid_k,
    euclid_offset = seq[track].euclid_offset,
  }
end

local function paste_pattern(track)
  if not clipboard then return end
  for s = 1, NUM_STEPS do
    seq[track].pattern[s] = clipboard.pattern[s]
    seq[track].prob[s] = clipboard.prob[s]
    seq[track].vel[s] = clipboard.vel[s]
  end
  seq[track].euclid_k = clipboard.euclid_k
  seq[track].euclid_offset = clipboard.euclid_offset
end

-- ============ HARMONIC SYSTEM (Nymira-inspired) ============

local harmony = {
  root = 0, scale_type = 1,
  chord_mode = false, chord_type = 1,
  drift_rate = 0, drift_counter = 0, circle_pos = 1,
}

local SCALE_NAMES = {}
local SCALE_COUNT = 0
for i = 1, #musicutil.SCALES do
  SCALE_NAMES[i] = musicutil.SCALES[i].name
  SCALE_COUNT = i
end

local function get_scale_notes()
  return musicutil.generate_scale(harmony.root + 36, SCALE_NAMES[harmony.scale_type], 4)
end

local function snap_to_scale(midi_note)
  local notes = get_scale_notes()
  return musicutil.snap_note_to_array(midi_note, notes)
end

local function get_chord_notes()
  local intervals = {
    {0, 4, 7},     -- major
    {0, 3, 7},     -- minor
    {0, 3, 6},     -- dim
  }
  local ivs = intervals[harmony.chord_type] or intervals[1]
  local root_midi = harmony.root + 48
  local notes = {}
  for i, iv in ipairs(ivs) do notes[i] = root_midi + iv end
  return notes
end

local function harmonic_drift_step()
  if harmony.drift_rate > 0 then
    harmony.drift_counter = harmony.drift_counter + 1
    if harmony.drift_counter >= (6 - harmony.drift_rate) * 8 then
      harmony.drift_counter = 0
      harmony.circle_pos = (harmony.circle_pos % 12) + 1
      harmony.root = CIRCLE_OF_FIFTHS[harmony.circle_pos]
    end
  end
end

-- ============ DRIFT MODE (Space Drum-inspired) ============

local function drift_step()
  if not drift_mode then return end
  tick_count = tick_count + 1
  if tick_count % (NUM_STEPS * 4) == 0 then
    for t = 1, NUM_VOICES do
      local flips = math.random(1, 2)
      for _ = 1, flips do
        local s = math.random(1, NUM_STEPS)
        if math.random() < 0.3 then
          seq[t].pattern[s] = 1 - seq[t].pattern[s]
        end
      end
      for s = 1, NUM_STEPS do
        seq[t].prob[s] = util.clamp(seq[t].prob[s] + math.random(-5, 5), 30, 100)
      end
    end
  end
  harmonic_drift_step()
end

-- ============ REACT MODE ============

local recent_density = {}
for i = 1, NUM_VOICES do recent_density[i] = 0 end

local function react_adjust()
  if not react_mode then return end
  local total = 0
  for t = 1, NUM_VOICES do total = total + recent_density[t] end
  for t = 1, NUM_VOICES do
    local next_step = (step % NUM_STEPS) + 1
    if total > 3 then
      if recent_density[t] == 1 then
        seq[t].prob[next_step] = util.clamp(seq[t].prob[next_step] - 5, 30, 100)
      end
    elseif total < 2 then
      seq[t].prob[next_step] = util.clamp(seq[t].prob[next_step] + 3, 30, 100)
    end
  end
end

-- ============ TIMBRE ENGINEER ============
-- Mode-aware sound sculptor. Knows each voice's synthesis mode and
-- sculpts the RIGHT params: FM voices get index/ratio sweeps,
-- Sub voices get shape/noise morphs, Noise voices get grain/ring mods.
-- Every voice is treated individually with its own phase and character.
--
-- Styles:
-- 1=SWEEP: multi-LFO sweeps — FM metallic shimmers, Sub filter dives, Noise grain rushes
-- 2=PUNCH: rhythmic stabs — different rhythm per voice role (kick=4, hat=8th, perc=synco)
-- 3=MORPH: glacial drift toward random deep targets, each voice on its own clock
-- 4=GLITCH: chaotic jumps into the extremes of each voice's synthesis capabilities
-- 5=BREATHE: organic golden-ratio waves, each voice a different organism

local TIMBRE_STYLES = {"off", "SWEEP", "PUNCH", "MORPH", "GLITCH", "BREATHE",
  "MUTATE", "SCATTER", "RATCHET", "DIALECT", "SWAP"}
local timbre = {
  style = 0,
  intensity = 0.5,
  phase = {},
  target = {},
}
for i = 1, NUM_VOICES do
  timbre.phase[i] = math.random() * 2 * math.pi
  timbre.target[i] = {}
end

local function randf(lo, hi) return lo + math.random() * (hi - lo) end

-- mode-specific sculpting: apply deep synthesis changes based on voice mode
local function sculpt_deep(v, t, amount)
  if v.mode == 0 then
    -- FM: sweep index (harmonic richness) and ratio (bell → clang → metallic)
    v.fm_index = util.clamp(v.fm_index + amount * 2, 0, 8)
    v.fm_ratio = util.clamp(v.fm_ratio + amount * 0.5, 0.25, 7)
  elseif v.mode == 1 then
    -- Sub: morph waveform shape and noise mix
    v.shape = util.clamp(v.shape + amount * 0.3, 0, 1)
    v.noise_amt = util.clamp(v.noise_amt + amount * 0.2, 0, 1)
    v.filter_env_amt = util.clamp(v.filter_env_amt + amount * 2000, 0, 8000)
  elseif v.mode == 2 then
    -- Noise: shift texture type, grain density, ring mod metallic
    v.noise_type = util.clamp(v.noise_type + amount * 0.3, 0, 1)
    v.grain_rate = util.clamp(v.grain_rate + amount * 30, 5, 200)
    v.ring_amt = util.clamp(v.ring_amt + amount * 0.25, 0, 1)
  end
end

-- ============ DRUM BRAIN ============
-- Curated library of great kick and snare configurations.
-- Every entry is a complete voice setup that sounds GOOD.
-- The timbre engineer draws from these instead of random params.
-- Each config specifies: mode, and all relevant params for that mode.

local KICK_BRAIN = {
  -- 808 sub: deep sine, long decay, heavy pitch sweep
  {mode=1, freq=42, decay=0.6, shape=0, noise_amt=0, filter_freq=800, filter_res=0.15,
   filter_type=0, pitch_env=10, pitch_decay=0.035, filter_env_amt=600, spread=0.1},
  -- punchy house: sine with click transient, tight
  {mode=1, freq=50, decay=0.3, shape=0, noise_amt=0.15, filter_freq=2500, filter_res=0.3,
   filter_type=0, pitch_env=6, pitch_decay=0.02, filter_env_amt=2000, spread=0.15},
  -- industrial: distorted, high pitch sweep, noise attack
  {mode=1, freq=55, decay=0.25, shape=0.3, noise_amt=0.4, filter_freq=4000, filter_res=0.5,
   filter_type=0, pitch_env=14, pitch_decay=0.015, filter_env_amt=3500, spread=0.2},
  -- minimal techno: tight sine, very short, subtle pitch
  {mode=1, freq=48, decay=0.15, shape=0, noise_amt=0, filter_freq=1200, filter_res=0.1,
   filter_type=0, pitch_env=4, pitch_decay=0.03, filter_env_amt=800, spread=0.05},
  -- boom bap: round, medium decay, warm filter
  {mode=1, freq=45, decay=0.45, shape=0, noise_amt=0.05, filter_freq=1500, filter_res=0.2,
   filter_type=0, pitch_env=8, pitch_decay=0.04, filter_env_amt=1000, spread=0.1},
  -- FM kick: metallic attack, sine body
  {mode=0, freq=44, decay=0.35, fm_index=2.5, fm_ratio=1.0, filter_freq=1800, filter_res=0.2,
   filter_type=0, pitch_env=12, pitch_decay=0.02, spread=0.1},
  -- gabber: extreme pitch sweep, hard distortion character
  {mode=1, freq=52, decay=0.2, shape=0.6, noise_amt=0.3, filter_freq=6000, filter_res=0.6,
   filter_type=0, pitch_env=16, pitch_decay=0.01, filter_env_amt=5000, spread=0.3},
  -- dub: very low, long tail, sub-heavy
  {mode=1, freq=38, decay=0.8, shape=0, noise_amt=0, filter_freq=600, filter_res=0.1,
   filter_type=0, pitch_env=6, pitch_decay=0.06, filter_env_amt=400, spread=0.05},
  -- electro: sharp click, tight body
  {mode=1, freq=55, decay=0.18, shape=0.15, noise_amt=0.25, filter_freq=3500, filter_res=0.35,
   filter_type=0, pitch_env=8, pitch_decay=0.012, filter_env_amt=3000, spread=0.15},
  -- noise kick: burst of filtered noise, no tone
  {mode=2, freq=60, decay=0.22, noise_type=0, grain_rate=80, ring_amt=0, filter_freq=1500,
   filter_res=0.4, filter_type=0, pitch_env=3, pitch_decay=0.02, spread=0.1},
  -- TR-909: punchy sine + noise transient
  {mode=1, freq=50, decay=0.35, shape=0, noise_amt=0.2, filter_freq=2000, filter_res=0.25,
   filter_type=0, pitch_env=7, pitch_decay=0.025, filter_env_amt=1800, spread=0.1},
  -- broken: detuned FM, glitchy character
  {mode=0, freq=46, decay=0.28, fm_index=4.0, fm_ratio=0.75, filter_freq=2500, filter_res=0.4,
   filter_type=0, pitch_env=9, pitch_decay=0.018, spread=0.25},
}

local SNARE_BRAIN = {
  -- tight acoustic: noise + tone, crisp
  {mode=2, freq=180, decay=0.15, noise_type=0, grain_rate=90, ring_amt=0, filter_freq=5500,
   filter_res=0.35, filter_type=0, pitch_env=3, pitch_decay=0.02, spread=0.2},
  -- fat hip-hop: long noise tail, warm
  {mode=2, freq=150, decay=0.3, noise_type=0.3, grain_rate=60, ring_amt=0, filter_freq=4000,
   filter_res=0.25, filter_type=0, pitch_env=5, pitch_decay=0.03, spread=0.15},
  -- 808 clap: layered noise bursts
  {mode=2, freq=200, decay=0.2, noise_type=0, grain_rate=40, ring_amt=0, filter_freq=6000,
   filter_res=0.3, filter_type=1, pitch_env=2, pitch_decay=0.01, spread=0.4},
  -- metallic: FM ring, sharp
  {mode=0, freq=190, decay=0.12, fm_index=3.0, fm_ratio=2.3, filter_freq=8000, filter_res=0.5,
   filter_type=2, pitch_env=4, pitch_decay=0.015, spread=0.3},
  -- brush: soft noise, high filter, gentle
  {mode=2, freq=250, decay=0.25, noise_type=0.5, grain_rate=120, ring_amt=0, filter_freq=7000,
   filter_res=0.15, filter_type=0, pitch_env=1, pitch_decay=0.04, spread=0.35},
  -- rimshot: very short, high pitch, BP filter
  {mode=1, freq=220, decay=0.05, shape=0.4, noise_amt=0.5, filter_freq=4500, filter_res=0.7,
   filter_type=2, pitch_env=8, pitch_decay=0.008, filter_env_amt=4000, spread=0.2},
  -- industrial snare: distorted noise, crunchy
  {mode=2, freq=160, decay=0.18, noise_type=0.8, grain_rate=30, ring_amt=0.3, filter_freq=3500,
   filter_res=0.6, filter_type=0, pitch_env=6, pitch_decay=0.012, spread=0.25},
  -- 909 snare: classic noise + tone blend
  {mode=2, freq=180, decay=0.22, noise_type=0.1, grain_rate=70, ring_amt=0, filter_freq=5000,
   filter_res=0.3, filter_type=0, pitch_env=4, pitch_decay=0.025, spread=0.2},
  -- broken snare: ring mod metallic
  {mode=2, freq=200, decay=0.16, noise_type=0.2, grain_rate=50, ring_amt=0.5, filter_freq=6000,
   filter_res=0.45, filter_type=2, pitch_env=5, pitch_decay=0.015, spread=0.35},
  -- lo-fi: crushed, dark filter, gritty
  {mode=2, freq=140, decay=0.2, noise_type=0.6, grain_rate=25, ring_amt=0.1, filter_freq=2500,
   filter_res=0.5, filter_type=0, pitch_env=3, pitch_decay=0.03, spread=0.15},
  -- FM snare: bell-like overtones
  {mode=0, freq=170, decay=0.18, fm_index=2.0, fm_ratio=3.5, filter_freq=7000, filter_res=0.3,
   filter_type=0, pitch_env=3, pitch_decay=0.02, spread=0.3},
  -- ghost note: barely there, ultra short, quiet
  {mode=2, freq=200, decay=0.04, noise_type=0, grain_rate=100, ring_amt=0, filter_freq=4000,
   filter_res=0.2, filter_type=0, pitch_env=1, pitch_decay=0.01, spread=0.1},
}

-- apply a drum brain preset to a voice, with optional blend amount
local function apply_drum_preset(v, preset, blend)
  blend = blend or 1.0
  local inv = 1 - blend
  v.mode = preset.mode  -- mode always snaps (discrete)
  v.base_freq = math.floor(v.base_freq * inv + preset.freq * blend + 0.5)
  v.decay = v.decay * inv + preset.decay * blend
  v.filter_freq = v.filter_freq * inv + preset.filter_freq * blend
  v.filter_res = v.filter_res * inv + preset.filter_res * blend
  v.filter_type = preset.filter_type  -- snap
  v.pitch_env = v.pitch_env * inv + preset.pitch_env * blend
  v.pitch_decay = v.pitch_decay * inv + preset.pitch_decay * blend
  v.spread = v.spread * inv + preset.spread * blend
  -- mode-specific
  if preset.mode == 0 then
    v.fm_index = (v.fm_index or 1) * inv + (preset.fm_index or 1) * blend
    v.fm_ratio = (v.fm_ratio or 1.414) * inv + (preset.fm_ratio or 1.414) * blend
  elseif preset.mode == 1 then
    v.shape = (v.shape or 0) * inv + (preset.shape or 0) * blend
    v.noise_amt = (v.noise_amt or 0) * inv + (preset.noise_amt or 0) * blend
    v.filter_env_amt = (v.filter_env_amt or 2000) * inv + (preset.filter_env_amt or 2000) * blend
  elseif preset.mode == 2 then
    v.noise_type = (v.noise_type or 0) * inv + (preset.noise_type or 0) * blend
    v.grain_rate = (v.grain_rate or 40) * inv + (preset.grain_rate or 40) * blend
    v.ring_amt = (v.ring_amt or 0) * inv + (preset.ring_amt or 0) * blend
  end
end

-- pick a great drum sound: sometimes snap, sometimes blend
local function drum_brain_hit(track)
  if timbre.style < 6 then return end  -- only for per-hit styles
  local int = timbre.intensity
  local v = voices[track]

  if track == 1 then
    -- KICK: pick from kick brain
    if math.random() < 0.15 + int * 0.25 then
      local preset = KICK_BRAIN[math.random(1, #KICK_BRAIN)]
      -- blend amount: sometimes subtle morph, sometimes full snap
      local blend = math.random() < 0.3 * int and 1.0 or randf(0.2, 0.6) * int
      apply_drum_preset(v, preset, blend)
    end
  elseif track == 2 then
    -- SNARE: pick from snare brain
    if math.random() < 0.15 + int * 0.25 then
      local preset = SNARE_BRAIN[math.random(1, #SNARE_BRAIN)]
      local blend = math.random() < 0.3 * int and 1.0 or randf(0.2, 0.6) * int
      apply_drum_preset(v, preset, blend)
    end
  end
end

local function timbre_engineer_step(step_num)
  if timbre.style == 0 then return end

  local int = timbre.intensity

  for t = 1, NUM_VOICES do
    local v = voices[t]
    local phase = timbre.phase[t]

    if timbre.style == 1 then
      -- SWEEP: multi-rate LFOs — each voice has unique rates based on its role
      -- kick/snare = slower, hats = faster, tone = medium
      local speed = ({0.02, 0.025, 0.04, 0.03, 0.015, 0.035})[t]
      timbre.phase[t] = phase + speed + (t * 0.003)
      local p = timbre.phase[t]

      -- common params at voice-specific rates
      v.filter_freq = util.clamp(
        util.linexp(math.sin(p) * 0.5 + 0.5, 0, 1, 80, 14000) * int +
        v.filter_freq * (1 - int), 60, 16000)
      v.filter_res = util.clamp(0.3 + math.sin(p * 1.3 + t) * 0.35 * int, 0.05, 0.95)
      v.decay = util.clamp(0.05 + (math.sin(p * 0.6) * 0.5 + 0.5) * 0.8 * int, 0.02, 1.5)
      v.pitch_env = math.abs(math.sin(p * 0.4 + t * 0.5)) * 12 * int
      v.pitch_decay = 0.02 + math.abs(math.sin(p * 0.7)) * 0.15 * int
      v.pan = util.clamp(math.sin(p * 0.5 + t * 1.2) * 0.8 * int, -1, 1)
      v.spread = math.abs(math.sin(p * 0.3 + t * 0.7)) * int
      v.detune = math.sin(p * 2.1 + t) * 5 * int

      -- deep synth params: slow sweeps per mode
      local deep_lfo = math.sin(p * 0.2 + t * 2.0) * int
      sculpt_deep(v, t, deep_lfo * 0.3)

    elseif timbre.style == 2 then
      -- PUNCH: different rhythmic patterns per voice role
      local beat = step_num % 4
      local bar_pos = step_num % 16
      -- each voice has its own rhythmic emphasis pattern
      local hit_pattern = ({
        {1,0,0,0},  -- kick: downbeat only
        {0,0,1,0},  -- snare: backbeat
        {1,1,1,1},  -- hat: every beat
        {0,1,0,1},  -- perc: offbeats
        {1,0,0,1},  -- tone: 1 and 4
        {0,0,1,1},  -- fx: 3 and 4
      })[t]

      if hit_pattern[beat + 1] == 1 then
        -- HIT: open up
        v.filter_freq = util.clamp(v.filter_freq * (1 + 1.5 * int), 60, 16000)
        v.pitch_env = v.pitch_env + 4 * int
        v.decay = util.clamp(v.decay * (1 + 0.4 * int), 0.02, 1.5)
        sculpt_deep(v, t, 0.5 * int)  -- push deep params forward
      else
        -- REST: pull back
        v.filter_freq = util.clamp(v.filter_freq * (1 - 0.3 * int), 60, 16000)
        v.pitch_env = math.max(0, v.pitch_env * (1 - 0.3 * int))
        v.decay = util.clamp(v.decay * (1 - 0.2 * int), 0.02, 1.5)
        sculpt_deep(v, t, -0.3 * int)  -- pull deep params back
      end
      -- every 4 bars: chance to shift filter type and deep params
      if bar_pos == 0 and math.random() < 0.3 * int then
        v.filter_type = math.random(0, 2)
      end
      -- rhythmic panning per voice
      local pp = math.sin(step_num * 0.4 + t * 1.5) * int
      v.pan = util.clamp(v.pan * 0.7 + pp * 0.4, -1, 1)

    elseif timbre.style == 3 then
      -- MORPH: each voice drifts toward its own random targets on its own clock
      local interval = 16 + (t * 7) % 32
      if step_num % interval == 0 then
        local tgt = {
          filter = randf(80, 16000),
          res = randf(0.05, 0.95),
          decay = randf(0.02, 1.2),
          pitch_env = randf(0, 14),
          pitch_decay = randf(0.005, 0.2),
          spread = randf(0, 1),
          pan = randf(-0.8, 0.8),
          detune = randf(-8, 8),
          filter_type = math.random(0, 2),
        }
        -- mode-specific targets
        if v.mode == 0 then
          tgt.fm_index = randf(0.1, 6)
          tgt.fm_ratio = randf(0.5, 5)
        elseif v.mode == 1 then
          tgt.shape = randf(0, 1)
          tgt.noise_amt = randf(0, 0.8)
          tgt.filter_env_amt = randf(0, 6000)
        elseif v.mode == 2 then
          tgt.noise_type = randf(0, 1)
          tgt.grain_rate = randf(8, 150)
          tgt.ring_amt = randf(0, 0.8)
        end
        timbre.target[t] = tgt
      end

      local tgt = timbre.target[t]
      if tgt and tgt.filter then
        local slew = 0.04 * int
        v.filter_freq = v.filter_freq + (tgt.filter - v.filter_freq) * slew
        v.filter_res = v.filter_res + (tgt.res - v.filter_res) * slew
        v.decay = v.decay + (tgt.decay - v.decay) * slew
        v.pitch_env = v.pitch_env + (tgt.pitch_env - v.pitch_env) * slew
        v.pitch_decay = v.pitch_decay + (tgt.pitch_decay - v.pitch_decay) * slew
        v.spread = v.spread + (tgt.spread - v.spread) * slew
        v.pan = v.pan + (tgt.pan - v.pan) * slew
        v.detune = v.detune + (tgt.detune - v.detune) * slew

        -- deep params morph
        if v.mode == 0 and tgt.fm_index then
          v.fm_index = v.fm_index + (tgt.fm_index - v.fm_index) * slew
          v.fm_ratio = v.fm_ratio + (tgt.fm_ratio - v.fm_ratio) * slew
        elseif v.mode == 1 and tgt.shape then
          v.shape = v.shape + (tgt.shape - v.shape) * slew
          v.noise_amt = v.noise_amt + (tgt.noise_amt - v.noise_amt) * slew
          v.filter_env_amt = v.filter_env_amt + (tgt.filter_env_amt - v.filter_env_amt) * slew
        elseif v.mode == 2 and tgt.noise_type then
          v.noise_type = v.noise_type + (tgt.noise_type - v.noise_type) * slew
          v.grain_rate = v.grain_rate + (tgt.grain_rate - v.grain_rate) * slew
          v.ring_amt = v.ring_amt + (tgt.ring_amt - v.ring_amt) * slew
        end

        if math.random() < 0.02 * int then
          v.filter_type = tgt.filter_type
        end
      end

    elseif timbre.style == 4 then
      -- GLITCH: chaotic jumps into each voice's FULL synthesis range
      if math.random() < 0.25 * int then
        local hits = math.random(1, math.floor(3 * int) + 1)
        for _ = 1, hits do
          local which = math.random(1, 14)
          if which == 1 then v.filter_freq = randf(60, 16000)
          elseif which == 2 then v.decay = randf(0.01, 1.0)
          elseif which == 3 then v.filter_res = randf(0.05, 0.95)
          elseif which == 4 then v.pitch_env = randf(0, 16)
          elseif which == 5 then v.pitch_decay = randf(0.003, 0.3)
          elseif which == 6 then v.pan = randf(-1, 1)
          elseif which == 7 then v.spread = randf(0, 1)
          elseif which == 8 then v.detune = randf(-10, 10)
          elseif which == 9 then v.filter_type = math.random(0, 2)
          elseif which == 10 then v.amp = util.clamp(randf(0.3, 1.0), 0.1, 1.0)
          -- deep mode-specific glitches:
          elseif which == 11 then
            if v.mode == 0 then v.fm_index = randf(0, 8)
            elseif v.mode == 1 then v.shape = randf(0, 1)
            elseif v.mode == 2 then v.noise_type = randf(0, 1) end
          elseif which == 12 then
            if v.mode == 0 then v.fm_ratio = randf(0.25, 7)
            elseif v.mode == 1 then v.noise_amt = randf(0, 1)
            elseif v.mode == 2 then v.grain_rate = randf(5, 200) end
          elseif which == 13 then
            if v.mode == 1 then v.filter_env_amt = randf(0, 8000)
            elseif v.mode == 2 then v.ring_amt = randf(0, 1) end
          elseif which == 14 then
            -- wild: temporarily extreme combo
            v.filter_freq = randf(60, 16000)
            v.pitch_env = randf(0, 16)
            sculpt_deep(v, t, randf(-1, 1))
          end
        end
      else
        -- partial snap back toward base
        if math.random() < 0.3 then
          v.filter_freq = v.filter_freq * 0.7 + params:get("v" .. t .. "_filter") * 0.3
          v.decay = v.decay * 0.7 + params:get("v" .. t .. "_decay") * 0.3
          v.pitch_env = v.pitch_env * 0.7 + params:get("v" .. t .. "_penv") * 0.3
          -- snap deep params back too
          sculpt_deep(v, t, -0.2)
        end
      end

    elseif timbre.style == 5 then
      -- BREATHE: each voice is a different organism with its own breath cycle
      -- rates based on golden ratio and prime numbers for each voice
      local rates = {0.011, 0.013, 0.017, 0.019, 0.023, 0.029}
      timbre.phase[t] = phase + rates[t]
      local p = timbre.phase[t]

      -- each voice gets its own wave combination (unique character)
      local w1 = math.sin(p + t * 0.618)
      local w2 = math.sin(p * 1.618 + t * 1.1)
      local w3 = math.cos(p * 0.618 + t * 2.2)
      local w4 = math.sin(p * 2.718 + t * 0.3)
      local breath = (w1 + w2 * 0.7 + w3 * 0.5) / 2.2

      -- common params
      v.filter_freq = util.clamp(
        util.linexp(breath * 0.5 + 0.5, 0, 1, 100, 14000) * int +
        params:get("v" .. t .. "_filter") * (1 - int), 60, 16000)
      v.filter_res = util.clamp(0.3 + w2 * 0.35 * int, 0.05, 0.95)
      v.decay = util.clamp(
        params:get("v" .. t .. "_decay") * (1 + breath * 0.6 * int), 0.02, 1.5)
      v.pitch_env = math.max(0, params:get("v" .. t .. "_penv") + w3 * 6 * int)
      v.pitch_decay = util.clamp(0.03 + math.abs(w4) * 0.15 * int, 0.003, 0.3)
      v.spread = util.clamp(math.abs(w1) * int, 0, 1)
      v.pan = util.clamp(
        params:get("v" .. t .. "_pan") + w4 * 0.5 * int, -1, 1)
      v.detune = w2 * 6 * int
      v.amp = util.clamp(
        params:get("v" .. t .. "_amp") * (1 + w3 * 0.15 * int), 0.1, 1.0)

      -- deep mode-specific breathing
      local deep_breath = math.sin(p * 0.3 + t * 3.14) * int
      sculpt_deep(v, t, deep_breath * 0.2)

      -- rare filter type shift
      if math.random() < 0.008 * int then
        v.filter_type = math.random(0, 2)
      end

    elseif timbre.style == 10 then
      -- SWAP: periodically swap voice synthesis modes mid-sequence
      -- each voice independently swaps on its own cycle
      timbre.phase[t] = phase + 0.005 + (t * 0.002)
      if math.random() < 0.015 * int then
        -- swap to a different mode
        local new_mode = math.random(0, 2)
        if new_mode ~= v.mode then
          v.mode = new_mode
          -- set sensible defaults for the new mode
          if new_mode == 0 then
            v.fm_index = randf(0.3, 3)
            v.fm_ratio = ({0.5, 1, 1.414, 1.5, 2, 3})[math.random(1, 6)]
          elseif new_mode == 1 then
            v.shape = randf(0, 1)
            v.noise_amt = randf(0, 0.5)
            v.filter_env_amt = randf(500, 4000)
          elseif new_mode == 2 then
            v.noise_type = randf(0, 1)
            v.grain_rate = randf(15, 100)
            v.ring_amt = randf(0, 0.4)
          end
        end
      end
      -- also do gentle BREATHE-style modulation between swaps
      local p = timbre.phase[t]
      local w1 = math.sin(p + t * 0.618)
      v.filter_freq = util.clamp(
        params:get("v" .. t .. "_filter") * (1 + w1 * 0.4 * int), 60, 16000)
      v.decay = util.clamp(
        params:get("v" .. t .. "_decay") * (1 + math.sin(p * 0.7) * 0.3 * int), 0.02, 1.5)
    end
  end
end

-- ============ MUTATE: per-hit voice mutation ============
-- Called at the moment of each trigger. Every hit sounds different.
-- Uses a "wander + return" system: each voice slowly drifts away from
-- its base config, explores, then periodically snaps back closer to home
-- before wandering out in a new direction.

local mutate = {
  -- per-voice wander state: how far we've drifted from base (0-1)
  wander = {0, 0, 0, 0, 0, 0},
  -- per-voice direction: which way we're heading (1=explore, -1=return)
  direction = {1, 1, 1, 1, 1, 1},
  -- per-voice hit counter: track how many hits since last direction change
  hits = {0, 0, 0, 0, 0, 0},
  -- per-voice "home" snapshot: where we return to
  home = {},
}

-- snapshot current voice state as "home"
local function mutate_snapshot_home(t)
  local v = voices[t]
  mutate.home[t] = {
    filter_freq = params:get("v" .. t .. "_filter"),
    filter_res = params:get("v" .. t .. "_res"),
    decay = params:get("v" .. t .. "_decay"),
    pitch_env = params:get("v" .. t .. "_penv"),
    pitch_decay = v.pitch_decay,
    pan = params:get("v" .. t .. "_pan"),
    spread = params:get("v" .. t .. "_spread"),
    amp = params:get("v" .. t .. "_amp"),
    fm_index = v.fm_index, fm_ratio = v.fm_ratio,
    shape = v.shape, noise_amt = v.noise_amt, filter_env_amt = v.filter_env_amt,
    noise_type = v.noise_type, grain_rate = v.grain_rate, ring_amt = v.ring_amt,
  }
end

-- mutate a voice at the moment of triggering (called from trigger_voice)
-- styles 6-9 all use per-hit mutation but with different characters
local function mutate_on_hit(t)
  -- only active for per-hit styles (6=MUTATE, 7=SCATTER, 8=RATCHET, 9=DIALECT)
  if timbre.style < 6 then return end

  local v = voices[t]
  local int = timbre.intensity

  -- initialize home if needed
  if not mutate.home[t] then mutate_snapshot_home(t) end
  local home = mutate.home[t]

  mutate.hits[t] = mutate.hits[t] + 1

  -- === STYLE 6: MUTATE — wander + return ===
  if timbre.style == 6 then
    local w = mutate.wander[t]

    -- direction logic: explore 8-24 hits, return 4-12
    if mutate.direction[t] == 1 then
      mutate.wander[t] = math.min(1, w + randf(0.02, 0.08) * int)
      if mutate.hits[t] > math.random(8, 24) then
        mutate.direction[t] = -1; mutate.hits[t] = 0
      end
    else
      mutate.wander[t] = math.max(0, w - randf(0.04, 0.12))
      if mutate.wander[t] < 0.05 or mutate.hits[t] > math.random(4, 12) then
        mutate.direction[t] = 1; mutate.hits[t] = 0
        mutate_snapshot_home(t)
      end
    end

    w = mutate.wander[t]
    local amount = w * int
    local cc = 0.3 + amount * 0.5  -- change chance

    if math.random() < cc then
      v.filter_freq = util.clamp(
        home.filter_freq * (2 ^ (randf(-1, 1) * 2 * amount)), 60, 16000)
    end
    if math.random() < cc * 0.7 then
      v.filter_res = util.clamp(home.filter_res + randf(-0.4, 0.4) * amount, 0.05, 0.95)
    end
    if math.random() < cc * 0.8 then
      v.decay = util.clamp(home.decay * (1 + randf(-0.6, 0.8) * amount), 0.02, 1.5)
    end
    if math.random() < cc * 0.6 then
      v.pitch_env = math.max(0, home.pitch_env + randf(-4, 8) * amount)
    end
    if math.random() < cc * 0.5 then
      v.pan = util.clamp(home.pan + randf(-0.8, 0.8) * amount, -1, 1)
    end
    if math.random() < cc * 0.3 then v.spread = randf(0, 1) * amount end
    if math.random() < cc * 0.3 then v.detune = randf(-8, 8) * amount end
    if math.random() < 0.05 * amount then v.filter_type = math.random(0, 2) end
    if math.random() < cc then sculpt_deep(v, t, randf(-1, 1) * amount) end

  -- === STYLE 7: SCATTER — each hit picks from a palette of presets ===
  -- like a drummer switching between sticks/mallets/brushes per hit
  elseif timbre.style == 7 then
    -- define character "palettes" per voice role
    local palettes = {
      -- kick palettes: deep/tight/punchy/boomy
      {{filt=800, res=0.2, dec=0.6, pe=10, pd=0.03},
       {filt=2000, res=0.4, dec=0.15, pe=4, pd=0.08},
       {filt=1200, res=0.6, dec=0.3, pe=6, pd=0.05},
       {filt=400, res=0.15, dec=0.8, pe=12, pd=0.02}},
      -- snare palettes: crack/brush/rim/ghost
      {{filt=6000, res=0.5, dec=0.15, pe=3, pd=0.04},
       {filt=3000, res=0.3, dec=0.25, pe=1, pd=0.08},
       {filt=8000, res=0.7, dec=0.08, pe=6, pd=0.02},
       {filt=2000, res=0.2, dec=0.12, pe=2, pd=0.05}},
      -- hat palettes: closed/open/sizzle/chick
      {{filt=10000, res=0.4, dec=0.04, pe=0, pd=0.02},
       {filt=6000, res=0.3, dec=0.25, pe=0, pd=0.03},
       {filt=14000, res=0.6, dec=0.12, pe=1, pd=0.01},
       {filt=4000, res=0.8, dec=0.02, pe=0, pd=0.01}},
      -- perc palettes: bell/click/wood/metal
      {{filt=8000, res=0.3, dec=0.4, pe=2, pd=0.06},
       {filt=3000, res=0.5, dec=0.05, pe=8, pd=0.02},
       {filt=5000, res=0.2, dec=0.1, pe=4, pd=0.04},
       {filt=12000, res=0.7, dec=0.2, pe=1, pd=0.03}},
      -- tone palettes: bell/pluck/pad/glass
      {{filt=10000, res=0.2, dec=0.6, pe=1, pd=0.08},
       {filt=4000, res=0.4, dec=0.2, pe=3, pd=0.03},
       {filt=6000, res=0.15, dec=0.8, pe=0.5, pd=0.1},
       {filt=14000, res=0.5, dec=0.3, pe=2, pd=0.05}},
      -- fx palettes: zap/swirl/click/wash
      {{filt=2000, res=0.8, dec=0.1, pe=12, pd=0.01},
       {filt=6000, res=0.4, dec=0.4, pe=3, pd=0.06},
       {filt=800, res=0.6, dec=0.03, pe=8, pd=0.02},
       {filt=4000, res=0.2, dec=0.5, pe=1, pd=0.08}},
    }

    local pal = palettes[t] or palettes[1]
    -- weighted random: bias toward neighboring presets for smoother changes
    local idx = math.random(1, #pal)
    local p = pal[idx]
    local blend = 0.3 + int * 0.5  -- how much to apply (more at high intensity)

    v.filter_freq = util.clamp(v.filter_freq * (1 - blend) + p.filt * blend, 60, 16000)
    v.filter_res = v.filter_res * (1 - blend) + p.res * blend
    v.decay = util.clamp(v.decay * (1 - blend) + p.dec * blend, 0.02, 1.5)
    v.pitch_env = v.pitch_env * (1 - blend) + p.pe * blend
    v.pitch_decay = v.pitch_decay * (1 - blend) + p.pd * blend

    -- scatter pan on each hit
    v.pan = util.clamp(v.pan + randf(-0.4, 0.4) * int, -1, 1)

    -- deep params: small random walk per hit
    sculpt_deep(v, t, randf(-0.5, 0.5) * int)

    -- occasionally snap to very different palette entry
    if math.random() < 0.1 * int then
      local wild = pal[math.random(1, #pal)]
      v.filter_freq = util.clamp(wild.filt, 60, 16000)
      v.decay = util.clamp(wild.dec, 0.02, 1.5)
      v.pitch_env = wild.pe
    end

  -- === STYLE 8: RATCHET — rhythmic cycling through param sets ===
  -- like a sequencer within the sequencer: params rotate through
  -- a cycle of configurations, creating repeating timbral patterns
  elseif timbre.style == 8 then
    -- cycle length varies per voice (prime numbers for polyrhythmic feel)
    local cycles = {3, 5, 7, 4, 6, 8}
    local cycle_len = cycles[t]
    local pos = mutate.hits[t] % cycle_len
    local phase = pos / cycle_len  -- 0..1 position in cycle

    -- parameters follow smooth curves through the cycle
    local wave = math.sin(phase * 2 * math.pi)
    local wave2 = math.cos(phase * 2 * math.pi)
    local wave3 = math.sin(phase * 4 * math.pi)  -- double speed

    v.filter_freq = util.clamp(
      home.filter_freq * (1 + wave * 1.5 * int), 60, 16000)
    v.filter_res = util.clamp(
      home.filter_res + wave2 * 0.3 * int, 0.05, 0.95)
    v.decay = util.clamp(
      home.decay * (1 + wave3 * 0.5 * int), 0.02, 1.5)
    v.pitch_env = math.max(0,
      home.pitch_env * (1 + wave * int))
    v.pitch_decay = util.clamp(
      home.pitch_decay * (1 + wave2 * 0.6 * int), 0.003, 0.3)
    v.pan = util.clamp(
      home.pan + wave * 0.5 * int, -1, 1)
    v.spread = util.clamp(math.abs(wave2) * int, 0, 1)

    -- deep params cycle on the slower wave
    sculpt_deep(v, t, wave * 0.4 * int)

    -- every full cycle, slightly shift the home point (slow drift)
    if pos == 0 and math.random() < 0.4 * int then
      mutate_snapshot_home(t)
      -- nudge home in a random direction
      if mutate.home[t] then
        mutate.home[t].filter_freq = util.clamp(
          mutate.home[t].filter_freq * randf(0.7, 1.4), 60, 16000)
        mutate.home[t].decay = util.clamp(
          mutate.home[t].decay * randf(0.7, 1.4), 0.02, 1.5)
      end
    end

  -- === STYLE 9: DIALECT — each voice develops its own "vocabulary" ===
  -- voices remember configurations they've visited and revisit favorites,
  -- gradually building a repertoire of sound "words" they cycle through
  elseif timbre.style == 9 then
    -- vocabulary: store up to 6 configurations per voice
    if not mutate.vocab then
      mutate.vocab = {}
      for i = 1, NUM_VOICES do mutate.vocab[i] = {} end
    end
    local vocab = mutate.vocab[t]

    -- chance to "learn" current config (add to vocabulary)
    if #vocab < 6 and math.random() < 0.15 * int then
      table.insert(vocab, {
        filter_freq = v.filter_freq,
        filter_res = v.filter_res,
        decay = v.decay,
        pitch_env = v.pitch_env,
        pitch_decay = v.pitch_decay,
        pan = v.pan,
        spread = v.spread,
        fm_index = v.fm_index, fm_ratio = v.fm_ratio,
        shape = v.shape, noise_amt = v.noise_amt,
        noise_type = v.noise_type, grain_rate = v.grain_rate, ring_amt = v.ring_amt,
      })
    end

    if #vocab > 0 and math.random() < 0.5 + int * 0.3 then
      -- "speak": pick a word from vocabulary (weighted toward recent)
      local weights = {}
      for i = 1, #vocab do weights[i] = i end  -- newer = higher weight
      local total = #vocab * (#vocab + 1) / 2
      local r = math.random() * total
      local pick = 1
      local sum = 0
      for i = 1, #vocab do
        sum = sum + i
        if r <= sum then pick = i; break end
      end

      local word = vocab[pick]
      local blend = 0.4 + int * 0.4

      v.filter_freq = util.clamp(v.filter_freq * (1 - blend) + word.filter_freq * blend, 60, 16000)
      v.filter_res = v.filter_res * (1 - blend) + word.filter_res * blend
      v.decay = util.clamp(v.decay * (1 - blend) + word.decay * blend, 0.02, 1.5)
      v.pitch_env = v.pitch_env * (1 - blend) + word.pitch_env * blend
      v.pitch_decay = v.pitch_decay * (1 - blend) + word.pitch_decay * blend
      v.pan = util.clamp(v.pan * (1 - blend) + word.pan * blend, -1, 1)

      -- apply deep params from word
      if v.mode == 0 and word.fm_index then
        v.fm_index = v.fm_index * (1 - blend) + word.fm_index * blend
        v.fm_ratio = v.fm_ratio * (1 - blend) + word.fm_ratio * blend
      elseif v.mode == 1 and word.shape then
        v.shape = v.shape * (1 - blend) + word.shape * blend
        v.noise_amt = v.noise_amt * (1 - blend) + word.noise_amt * blend
      elseif v.mode == 2 and word.noise_type then
        v.noise_type = v.noise_type * (1 - blend) + word.noise_type * blend
        v.grain_rate = v.grain_rate * (1 - blend) + word.grain_rate * blend
        v.ring_amt = v.ring_amt * (1 - blend) + word.ring_amt * blend
      end
    else
      -- "improvise": random variation (adds new sounds to learn from)
      local amount = int * 0.5
      if math.random() < 0.6 then
        v.filter_freq = util.clamp(v.filter_freq * randf(0.6, 1.6), 60, 16000)
      end
      if math.random() < 0.4 then
        v.decay = util.clamp(v.decay * randf(0.5, 1.8), 0.02, 1.5)
      end
      if math.random() < 0.4 then
        v.pitch_env = math.max(0, v.pitch_env + randf(-3, 5) * amount)
      end
      if math.random() < 0.3 then
        v.pan = util.clamp(v.pan + randf(-0.5, 0.5) * amount, -1, 1)
      end
      sculpt_deep(v, t, randf(-0.5, 0.5) * amount)
    end

    -- chance to "forget" oldest word (keeps vocabulary fresh)
    if #vocab > 3 and math.random() < 0.03 * int then
      table.remove(vocab, 1)
    end
  end
end

-- ============ PATTERN ENGINEER ============
-- Evolves step patterns musically. Unlike drift (which just flips random steps),
-- the pattern engineer has musical strategies for how patterns grow and change.
--
-- Styles:
-- 1=BUILDER: gradually adds steps, building density toward peaks then stripping back
-- 2=SHIFTER: rotates and mirrors patterns, creating call+response
-- 3=POLYRHYTHM: morphs euclidean densities creating interlocking rhythms
-- 4=BREAKBEAT: chops patterns into fragments, rearranges, creates fills
-- 5=CONDUCTOR: coordinates all tracks — builds sections (sparse/dense/fill/drop)

local PAT_STYLES = {"off", "BUILDER", "SHIFTER", "POLY", "BREAK", "CONDUCTOR"}
local pat_eng = {
  style = 0,
  intensity = 0.5,
  phase = 0,
  section = 1,       -- for CONDUCTOR: 1=sparse, 2=build, 3=peak, 4=drop
  section_len = 0,   -- steps remaining in current section
  bar_count = 0,     -- for tracking musical phrases
}

local function pattern_engineer_step(step_num)
  if pat_eng.style == 0 then return end
  local int = pat_eng.intensity
  local beat = step_num % 4
  local bar_pos = step_num % 16

  if bar_pos == 0 then pat_eng.bar_count = pat_eng.bar_count + 1 end

  if pat_eng.style == 1 then
    -- BUILDER: like a person adding/removing hits in real-time
    -- acts every 2-4 steps depending on intensity
    if math.random() < 0.15 * int then
      pat_eng.phase = pat_eng.phase + 0.03 * int
      local building = math.sin(pat_eng.phase) > 0  -- build or strip phase
      local t = math.random(1, NUM_VOICES)
      local next_s = (step_num % NUM_STEPS) + 1 + math.random(0, 3)
      next_s = ((next_s - 1) % NUM_STEPS) + 1

      if building then
        seq[t].pattern[next_s] = 1
        seq[t].vel[next_s] = randf(0.5, 1.0)
        seq[t].prob[next_s] = math.random(70, 100)
      else
        seq[t].pattern[next_s] = 0
      end
    end
    -- every 2 bars: bigger density shift
    if bar_pos == 0 and pat_eng.bar_count % 2 == 0 then
      local t = math.random(1, NUM_VOICES)
      local target_k = math.random(0, math.floor(12 * int))
      seq[t].euclid_k = target_k
      if target_k > 0 then apply_euclidean(t) end
    end

  elseif pat_eng.style == 2 then
    -- SHIFTER: acts every 4-8 steps — quick rotations and echoes
    if beat == 0 and math.random() < 0.3 * int then
      local t = math.random(1, NUM_VOICES)
      local action = math.random(1, 3)
      if action == 1 then
        -- rotate by 1 step (very musical, just shifts the feel)
        local last = seq[t].pattern[NUM_STEPS]
        for s = NUM_STEPS, 2, -1 do seq[t].pattern[s] = seq[t].pattern[s-1] end
        seq[t].pattern[1] = last
      elseif action == 2 then
        -- echo another track's upcoming 4 steps
        local src = math.random(1, NUM_VOICES)
        local start = bar_pos + 1
        for s = start, math.min(start + 3, NUM_STEPS) do
          if math.random() < 0.6 then
            seq[t].pattern[s] = seq[src].pattern[s]
            seq[t].vel[s] = seq[src].vel[s] * randf(0.7, 1.0)
          end
        end
      elseif action == 3 then
        -- flip the next 2-4 steps (surprise variation)
        local len = math.random(2, 4)
        for s = bar_pos + 1, math.min(bar_pos + len, NUM_STEPS) do
          seq[t].pattern[s] = 1 - seq[t].pattern[s]
        end
      end
    end

  elseif pat_eng.style == 3 then
    -- POLYRHYTHM: changes euclidean on beat boundaries, fast morphing
    if beat == 0 and math.random() < 0.15 * int then
      local t = math.random(1, NUM_VOICES)
      local interesting = {2, 3, 4, 5, 7, 9, 11, 13}
      seq[t].euclid_k = interesting[math.random(1, #interesting)]
      seq[t].euclid_offset = math.random(0, NUM_STEPS - 1)
      apply_euclidean(t)
    end
    -- every beat: small offset shifts (creates rolling polyrhythmic feel)
    if math.random() < 0.1 * int then
      local t = math.random(1, NUM_VOICES)
      if seq[t].euclid_k > 0 then
        seq[t].euclid_offset = (seq[t].euclid_offset + 1) % NUM_STEPS
        apply_euclidean(t)
      end
    end

  elseif pat_eng.style == 4 then
    -- BREAKBEAT: acts EVERY step — constant chopping and rearranging
    if math.random() < 0.2 * int then
      local t = math.random(1, NUM_VOICES)
      local action = math.random(1, 6)

      if action == 1 then
        -- stutter: repeat current 4-step segment elsewhere
        local seg = math.floor(bar_pos / 4) * 4
        local target = math.random(0, 3) * 4
        if seg ~= target then
          for s = 1, 4 do
            seq[t].pattern[target + s] = seq[t].pattern[((seg + s - 1) % NUM_STEPS) + 1]
          end
        end
      elseif action == 2 then
        -- fill ahead: next 2-4 steps all on
        for s = 1, math.random(2, 4) do
          local idx = ((step_num + s - 1) % NUM_STEPS) + 1
          seq[t].pattern[idx] = 1
          seq[t].vel[idx] = randf(0.6, 1.0)
        end
      elseif action == 3 then
        -- drop ahead: next 2-4 steps all off
        for s = 1, math.random(2, 4) do
          local idx = ((step_num + s - 1) % NUM_STEPS) + 1
          seq[t].pattern[idx] = 0
        end
      elseif action == 4 then
        -- velocity accent: boost or cut upcoming hits
        for s = 1, math.random(2, 6) do
          local idx = ((step_num + s - 1) % NUM_STEPS) + 1
          seq[t].vel[idx] = randf(0.3, 1.0)
        end
      elseif action == 5 then
        -- probability shift: make upcoming steps uncertain
        for s = 1, math.random(2, 6) do
          local idx = ((step_num + s - 1) % NUM_STEPS) + 1
          seq[t].prob[idx] = math.random(30, 100)
        end
      elseif action == 6 then
        -- regenerate one track entirely
        if math.random() < 0.1 then generate_pattern(t) end
      end
    end

  elseif pat_eng.style == 5 then
    -- CONDUCTOR: song sections, but also makes per-beat decisions
    -- section transitions happen on bar boundaries
    if bar_pos == 0 then
      pat_eng.section_len = pat_eng.section_len - 1
      if pat_eng.section_len <= 0 then
        pat_eng.section = (pat_eng.section % 4) + 1
        pat_eng.section_len = math.random(2, 5)
      end
    end

    local sec = pat_eng.section
    -- per-step actions within each section:
    if sec == 1 then
      -- SPARSE: actively strip steps, reduce probability
      if math.random() < 0.12 * int then
        local t = math.random(1, NUM_VOICES)
        seq[t].pattern[math.random(1, NUM_STEPS)] = 0
      end
      if beat == 0 then
        for t = 1, NUM_VOICES do
          seq[t].track_prob = util.clamp(seq[t].track_prob - math.random(1, 4) * int, 30, 100)
        end
      end
    elseif sec == 2 then
      -- BUILD: add steps every few beats, raise probability
      if math.random() < 0.1 * int then
        local t = math.random(1, NUM_VOICES)
        seq[t].pattern[math.random(1, NUM_STEPS)] = 1
        seq[t].vel[math.random(1, NUM_STEPS)] = randf(0.5, 0.9)
      end
      if beat == 0 then
        for t = 1, NUM_VOICES do
          seq[t].track_prob = util.clamp(seq[t].track_prob + math.random(2, 6) * int, 30, 100)
        end
      end
    elseif sec == 3 then
      -- PEAK: fills, max velocity, full probability
      if math.random() < 0.08 * int then
        local t = math.random(1, NUM_VOICES)
        seq[t].pattern[math.random(1, NUM_STEPS)] = 1
        seq[t].vel[math.random(1, NUM_STEPS)] = randf(0.8, 1.0)
      end
      for t = 1, NUM_VOICES do seq[t].track_prob = 100 end
    elseif sec == 4 then
      -- DROP: mute/unmute voices rhythmically
      if beat == 0 and math.random() < 0.3 * int then
        local t = math.random(2, NUM_VOICES) -- never drop kick
        mutes[t] = not mutes[t]
      end
      -- thin out non-kick probability
      if math.random() < 0.1 * int then
        local t = math.random(2, NUM_VOICES)
        seq[t].track_prob = util.clamp(seq[t].track_prob - math.random(5, 15) * int, 20, 100)
      end
    end
  end
end

-- ============ FILTER ENGINEER ============
-- Plays with filters and mutes rhythmically.
-- Creates filter sweeps, rhythmic muting, filter-type cycling,
-- and resonance surges — all synced to the beat.
--
-- Styles:
-- 1=SWEEP: coordinated filter sweeps across voices (DJ-style)
-- 2=STROBE: rhythmic muting/unmuting creating gating effects
-- 3=RESONATE: resonance surges and filter-type switching
-- 4=ISOLATE: solo voices in rotation, spotlight each one

local FILT_STYLES = {"off", "SWEEP", "STROBE", "RESONATE", "ISOLATE"}
local filt_eng = {
  style = 0,
  intensity = 0.5,
  phase = 0,
  solo_voice = 0,     -- for ISOLATE
  solo_timer = 0,
  saved_mutes = nil,   -- backup mutes for restore
}

local function filter_engineer_step(step_num)
  if filt_eng.style == 0 then return end
  local int = filt_eng.intensity
  local beat = step_num % 4
  local bar_pos = step_num % 16

  if filt_eng.style == 1 then
    -- SWEEP: like a DJ riding the filter — EVERY STEP moves
    filt_eng.phase = filt_eng.phase + 0.06 + int * 0.04  -- full sweep in ~4 bars
    local sweep = math.sin(filt_eng.phase)

    for t = 1, NUM_VOICES do
      local base = params:get("v" .. t .. "_filter")
      -- main sweep: wide exponential filter movement
      voices[t].filter_freq = util.clamp(
        base * (2 ^ (sweep * 2.5 * int)), 60, 16000)
      -- resonance rides with the sweep (up when filter closes)
      voices[t].filter_res = util.clamp(
        params:get("v" .. t .. "_res") + (1 - sweep) * 0.3 * int, 0.05, 0.95)
    end
    -- on downbeats: chance of sudden filter snap (like a DJ flick)
    if beat == 0 and math.random() < 0.15 * int then
      for t = 1, NUM_VOICES do
        voices[t].filter_freq = util.clamp(
          params:get("v" .. t .. "_filter") * randf(0.3, 3.0), 60, 16000)
      end
    end

  elseif filt_eng.style == 2 then
    -- STROBE: rhythmic muting on EVERY STEP — like a trance gate
    for t = 1, NUM_VOICES do
      -- each voice has a different gate rhythm
      local gate_patterns = {
        {1,1,1,1, 1,1,1,1, 1,1,1,1, 1,1,1,1},  -- kick: solid
        {1,0,1,1, 1,0,1,0, 1,0,1,1, 1,0,1,0},  -- snare: syncopated
        {1,1,0,1, 1,0,1,1, 0,1,1,0, 1,1,0,1},  -- hat: shuffled
        {1,0,0,1, 0,1,0,0, 1,0,0,1, 0,1,0,0},  -- perc: sparse
        {0,1,1,0, 1,0,0,1, 1,0,1,0, 0,1,0,1},  -- tone: off-grid
        {1,0,1,0, 0,1,0,1, 1,0,1,0, 0,1,0,1},  -- fx: alternating
      }
      local pat = gate_patterns[t]
      local gate = pat[bar_pos + 1] or 1

      if math.random() < int then
        mutes[t] = gate == 0
      end
    end
    -- every 2 bars: rotate one voice's gate pattern
    if bar_pos == 0 and pat_eng.bar_count % 2 == 0 then
      -- (patterns are local so this creates natural evolution)
    end

  elseif filt_eng.style == 3 then
    -- RESONATE: rhythmic resonance surges synced to beats
    for t = 1, NUM_VOICES do
      -- resonance pumps on beats (different per voice)
      local pump_beats = ({
        {0},           -- kick: downbeat res surge
        {2},           -- snare: beat 3
        {0,1,2,3},     -- hat: every beat
        {1,3},         -- perc: offbeats
        {0,2},         -- tone: 1 and 3
        {1},           -- fx: beat 2
      })[t]

      local pumping = false
      for _, b in ipairs(pump_beats) do
        if beat == b then pumping = true; break end
      end

      if pumping then
        voices[t].filter_res = util.clamp(
          params:get("v" .. t .. "_res") + randf(0.15, 0.5) * int, 0.05, 0.95)
        voices[t].filter_freq = util.clamp(
          voices[t].filter_freq * (1 + randf(-0.3, 0.5) * int), 60, 16000)
      else
        -- snap back quickly
        voices[t].filter_res = voices[t].filter_res * 0.7 +
          params:get("v" .. t .. "_res") * 0.3
      end

      -- filter type: chance to switch on beat boundaries
      if beat == 0 and math.random() < 0.06 * int then
        voices[t].filter_type = math.random(0, 2)
      end
    end

  elseif filt_eng.style == 4 then
    -- ISOLATE: quick solo rotations — spotlight each voice rhythmically
    filt_eng.solo_timer = filt_eng.solo_timer - 1

    if filt_eng.solo_timer <= 0 then
      if not filt_eng.saved_mutes then
        filt_eng.saved_mutes = {table.unpack(mutes)}
      end

      -- unmute all first
      for t = 1, NUM_VOICES do mutes[t] = false end

      if math.random() < 0.65 * int then
        -- solo 1-2 voices
        local solo1 = math.random(1, NUM_VOICES)
        local solo2 = math.random() < 0.4 and math.random(1, NUM_VOICES) or solo1
        for t = 1, NUM_VOICES do
          mutes[t] = (t ~= solo1 and t ~= solo2)
        end
        filt_eng.solo_voice = solo1

        -- dramatically shape the soloed voice's filter
        voices[solo1].filter_freq = util.clamp(
          params:get("v" .. solo1 .. "_filter") * randf(0.4, 2.5), 60, 16000)
        voices[solo1].filter_res = util.clamp(
          params:get("v" .. solo1 .. "_res") + randf(0, 0.4) * int, 0.05, 0.95)
      else
        filt_eng.solo_voice = 0
      end

      -- shorter holds = more rhythmic (4-16 steps instead of 8-32)
      filt_eng.solo_timer = math.random(4, math.floor(16 / (int + 0.1)))
    end
  end

  -- === FX PARAM AUTOMATION (runs in all filter styles) ===
  -- occasionally sweep FX params for dramatic moments
  if math.random() < 0.06 * int then
    local slot = math.random(1, NUM_FX_SLOTS)
    if fx[slot].type > 0 then
      -- nudge param1 or param2
      if math.random() < 0.5 then
        fx[slot].param1 = util.clamp(fx[slot].param1 + randf(-0.15, 0.15) * int, 0, 1)
      else
        fx[slot].param2 = util.clamp(fx[slot].param2 + randf(-0.15, 0.15) * int, 0, 1)
      end
      update_fx_params(slot)
    end
  end

  -- on beats: chance of dramatic FX moment
  if beat == 0 and math.random() < 0.04 * int then
    local slot = math.random(1, NUM_FX_SLOTS)
    if fx[slot].type > 0 then
      -- big jump
      fx[slot].param1 = randf(0.1, 0.9)
      fx[slot].param2 = randf(0.1, 0.9)
      update_fx_params(slot)
    end
  end

  -- softcut looper automation: manipulate rate/filter if playing
  if sc_loop.playing and math.random() < 0.03 * int then
    sc_set_rate(({-1, -0.5, 0.5, 1, 1.5, 2})[math.random(1, 6)])
  end
  if sc_loop.playing and math.random() < 0.04 * int then
    sc_set_filter(randf(0.2, 1.0))
  end
end

-- restore mutes when filter engineer is turned off
local function filter_engineer_cleanup()
  if filt_eng.saved_mutes then
    for t = 1, NUM_VOICES do mutes[t] = filt_eng.saved_mutes[t] end
    filt_eng.saved_mutes = nil
  end
  filt_eng.solo_voice = 0
end

-- ============ BANDLEADER ============
-- Meta-system that coordinates all three engineers through a musical journey.
-- Thinks in song structure: builds energy arcs, creates contrast,
-- synchronizes and de-synchronizes the engineers for musical effect.
--
-- Phases: INTRO > GROOVE > BUILD > PEAK > BREAK > CLIMAX > DISSOLVE > (repeat)
-- Each phase tells the engineers what energy level, what styles to favor,
-- when to sync up, when to contrast, when to call+respond.

local BANDLEADER_STYLES = {"off", "JOURNEY", "MANTRA", "JAZZ", "TECHNO", "AMBIENT"}
local BANDLEADER_PHASES = {"INTRO", "GROOVE", "BUILD", "PEAK", "BREAK", "CLIMAX", "DISSOLVE"}
local bandleader = {
  active = false,
  mindset = 1,        -- 1=JOURNEY, 2=MANTRA, 3=JAZZ, 4=TECHNO, 5=AMBIENT
  phase = 1,
  phase_bars = 0,
  phase_length = 4,
  energy = 0.3,
  target_energy = 0.3,
  bar_count = 0,
  step_count = 0,
  sync_pulse = false,
  contrast_voice = 0,
  contrast_timer = 0,
}

-- phase config builder: {energy, timbre_int, pat_int, filt_int, prefer_timbre, prefer_pat, prefer_filt, mute_chance, bars}
local function pc(e, ti, pi, fi, pt, pp, pf, mc, bars)
  return { energy=e, timbre_int=ti, pat_int=pi, filt_int=fi,
    prefer_timbre=pt, prefer_pat=pp, prefer_filt=pf, mute_chance=mc, bars=bars }
end

-- === MINDSET CONFIGS ===
-- Each mindset defines its own phase sequence, pacing, and personality

local MINDSET_CONFIGS = {
  -- 1: JOURNEY — classic arc: intro > groove > build > peak > break > climax > dissolve
  -- like a DJ set. long arcs, dramatic peaks and valleys
  {
    name = "JOURNEY",
    phases = {
      pc({0.1,0.3},{0.1,0.3},{0,0.2},{0.1,0.2}, {1,5},{0,1},{0,1}, {0,0,0.8,0.6,0.8,0.9}, 3),
      pc({0.4,0.6},{0.2,0.5},{0.1,0.3},{0.1,0.3}, {6,7,8},{0,2},{0,3}, {0,0,0,0.1,0.2,0.3}, 6),
      pc({0.5,0.8},{0.3,0.7},{0.3,0.6},{0.2,0.5}, {2,3,8},{1,3},{1,3}, {0,0,0,0,0,0.1}, 4),
      pc({0.8,1.0},{0.5,0.9},{0.4,0.7},{0.3,0.6}, {4,10,6},{4,5},{1,4}, {0,0,0,0,0,0}, 4),
      pc({0.1,0.3},{0.1,0.3},{0,0.1},{0.2,0.5}, {5,9},{0},{2,4}, {0,0.5,0.7,0.8,0.3,0.9}, 2),
      pc({0.9,1.0},{0.6,1.0},{0.5,0.8},{0.4,0.7}, {4,10},{4,5},{1,3}, {0,0,0,0,0,0}, 4),
      pc({0.2,0.4},{0.1,0.4},{0.1,0.2},{0.1,0.3}, {5,3},{1},{1}, {0,0.2,0.3,0.4,0.3,0.5}, 3),
    },
    harmony_moves = true,    -- modulate keys on builds
    contrast_freq = 0.15,    -- how often contrast moments happen
    sync_interval = {4, 8},  -- bars between sync pulses
  },

  -- 2: MANTRA — hypnotic repetition with slow evolution
  -- stays in grooves for a LONG time, changes are subtle and rare
  -- like Fela Kuti or Steve Reich — the repetition IS the music
  {
    name = "MANTRA",
    phases = {
      pc({0.3,0.5},{0.1,0.3},{0,0.1},{0,0.1}, {5,9},{0},{0}, {0,0,0,0.3,0.3,0.5}, 8),    -- settle
      pc({0.4,0.6},{0.2,0.4},{0.1,0.2},{0.1,0.2}, {5,8,9},{0,2},{0,3}, {0,0,0,0,0,0.2}, 12),  -- long groove
      pc({0.5,0.7},{0.3,0.5},{0.1,0.3},{0.1,0.3}, {3,5},{1},{1}, {0,0,0,0,0,0}, 6),       -- subtle build
      pc({0.6,0.8},{0.3,0.6},{0.2,0.4},{0.2,0.4}, {6,7},{3},{3}, {0,0,0,0,0,0}, 8),       -- plateau
      pc({0.3,0.5},{0.1,0.3},{0,0.1},{0.1,0.2}, {5,9},{0},{0,1}, {0,0,0.2,0.3,0.1,0.4}, 4), -- thin
      pc({0.5,0.7},{0.2,0.5},{0.1,0.3},{0.1,0.3}, {8,9},{2},{3}, {0,0,0,0,0,0}, 10),      -- rebuild
      pc({0.3,0.5},{0.1,0.3},{0,0.1},{0,0.1}, {5},{0},{0}, {0,0,0.1,0.2,0.2,0.4}, 6),     -- return
    },
    harmony_moves = false,   -- stays in one key (mantra)
    contrast_freq = 0.05,    -- rare contrast (consistency)
    sync_interval = {8, 16}, -- very rare sync (hypnotic)
  },

  -- 3: JAZZ — conversational. short sections, call+response,
  -- voices solo and trade, harmony moves freely
  {
    name = "JAZZ",
    phases = {
      pc({0.3,0.5},{0.2,0.4},{0.1,0.2},{0.1,0.2}, {6,9},{0,2},{0}, {0,0,0,0.1,0,0.2}, 2),  -- head in
      pc({0.5,0.7},{0.3,0.6},{0.2,0.4},{0.1,0.3}, {6,7,9},{2},{3,4}, {0,0,0,0,0,0}, 3),     -- comping
      pc({0.4,0.6},{0.3,0.5},{0.1,0.2},{0.3,0.6}, {9,6},{0},{4}, {0,0.3,0.3,0,0,0.5}, 2),   -- solo 1
      pc({0.5,0.7},{0.4,0.7},{0.2,0.4},{0.2,0.4}, {7,8},{2,4},{3}, {0,0,0,0.3,0,0.3}, 2),   -- trading
      pc({0.4,0.6},{0.3,0.5},{0.1,0.2},{0.3,0.6}, {6,9},{0},{4}, {0.3,0,0.3,0.3,0,0.5}, 2), -- solo 2
      pc({0.7,0.9},{0.5,0.8},{0.3,0.6},{0.2,0.5}, {4,6,7},{4,3},{1,3}, {0,0,0,0,0,0}, 3),   -- collective
      pc({0.3,0.5},{0.2,0.4},{0.1,0.2},{0.1,0.2}, {5,9},{0},{0}, {0,0,0,0.1,0,0.2}, 2),     -- head out
    },
    harmony_moves = true,
    contrast_freq = 0.3,     -- lots of contrast (solos!)
    sync_interval = {2, 4},  -- frequent sync (conversation)
  },

  -- 4: TECHNO — relentless. kick never stops, energy stays high,
  -- changes happen through filters and FX, not pattern changes
  -- like a Berlin set: hypnotic but always moving forward
  {
    name = "TECHNO",
    phases = {
      pc({0.5,0.7},{0.2,0.4},{0,0.1},{0.2,0.5}, {1,2},{0},{1,2}, {0,0.5,0,0.3,0.5,0.7}, 4), -- filter intro
      pc({0.6,0.8},{0.3,0.6},{0.1,0.2},{0.3,0.6}, {2,8},{0,3},{1,3}, {0,0,0,0,0,0.3}, 6),    -- driving
      pc({0.7,0.9},{0.4,0.7},{0.2,0.4},{0.4,0.7}, {2,4,8},{3,4},{1,3}, {0,0,0,0,0,0}, 4),    -- intense
      pc({0.9,1.0},{0.5,0.9},{0.3,0.5},{0.5,0.8}, {4,10},{4},{1}, {0,0,0,0,0,0}, 4),         -- peak
      pc({0.4,0.6},{0.2,0.4},{0,0},{0.4,0.7}, {1,5},{0},{2,4}, {0,0.8,0.5,0.8,0.8,0.8}, 2),  -- breakdown (kick stays)
      pc({0.8,1.0},{0.5,0.9},{0.3,0.5},{0.4,0.7}, {2,4,8},{3,4},{1,3}, {0,0,0,0,0,0}, 6),    -- rebuild
      pc({0.6,0.8},{0.3,0.5},{0.1,0.2},{0.3,0.6}, {1,3},{0,1},{1}, {0,0,0,0.2,0.3,0.4}, 4),  -- cruise
    },
    harmony_moves = false,   -- stays in key (techno doesn't modulate much)
    contrast_freq = 0.1,     -- some contrast through filter spotlight
    sync_interval = {4, 8},
  },

  -- 5: AMBIENT — barely there. ultra-minimal, voices appear and disappear
  -- like ghosts. long silences, occasional events, deep patience
  -- like Brian Eno's generative installations
  {
    name = "AMBIENT",
    phases = {
      pc({0.05,0.15},{0.1,0.2},{0,0},{0,0.1}, {5},{0},{0}, {0.3,0.7,0.8,0.5,0.3,0.8}, 6),   -- near silence
      pc({0.1,0.25},{0.1,0.3},{0,0.1},{0,0.1}, {5,3},{0},{0,1}, {0.2,0.5,0.6,0.3,0.2,0.6}, 8), -- emerging
      pc({0.2,0.4},{0.2,0.4},{0.1,0.2},{0.1,0.2}, {3,5,9},{1},{1}, {0,0.3,0.4,0.1,0,0.3}, 6), -- present
      pc({0.3,0.5},{0.2,0.5},{0.1,0.2},{0.1,0.3}, {5,6,9},{0,2},{0,3}, {0,0.2,0.2,0,0,0.2}, 8), -- full
      pc({0.1,0.2},{0.1,0.2},{0,0},{0.1,0.2}, {5},{0},{4}, {0.1,0.6,0.7,0.5,0.2,0.7}, 4),    -- fading
      pc({0.2,0.4},{0.2,0.4},{0.1,0.2},{0.1,0.2}, {3,9},{1},{1}, {0,0.3,0.3,0.1,0,0.3}, 6),  -- echo
      pc({0.05,0.15},{0.1,0.2},{0,0},{0,0.1}, {5},{0},{0}, {0.3,0.7,0.8,0.6,0.4,0.8}, 8),    -- dissolve to silence
    },
    harmony_moves = true,    -- slow harmonic drift (atmospheric)
    contrast_freq = 0.03,    -- very rare (patience)
    sync_interval = {12, 24}, -- almost never (each voice is independent)
  },
}

local function bandleader_step(step_num)
  if not bandleader.active then return end
  bandleader.step_count = bandleader.step_count + 1

  local mind = MINDSET_CONFIGS[bandleader.mindset] or MINDSET_CONFIGS[1]
  local num_phases = #mind.phases
  local bar_pos = step_num % 16
  local beat = step_num % 4

  -- === BAR BOUNDARY: phase management ===
  if bar_pos == 0 then
    bandleader.bar_count = bandleader.bar_count + 1
    bandleader.phase_bars = bandleader.phase_bars + 1

    -- time to transition?
    if bandleader.phase_bars >= bandleader.phase_length then
      -- advance phase (wrap within this mindset's phase count)
      bandleader.phase = (bandleader.phase % num_phases) + 1
      bandleader.phase_bars = 0

      local cfg = mind.phases[bandleader.phase]
      bandleader.phase_length = cfg.bars + math.random(-1, 1)
      bandleader.phase_length = math.max(1, bandleader.phase_length)

      bandleader.target_energy = randf(cfg.energy[1], cfg.energy[2])

      -- === PHASE TRANSITION: tell engineers what to do ===

      -- pick styles from the phase's preferred lists
      if #cfg.prefer_timbre > 0 then
        local pick = cfg.prefer_timbre[math.random(1, #cfg.prefer_timbre)]
        timbre.style = pick
        params:set("timbre_style", pick + 1, true)
      end
      if #cfg.prefer_pat > 0 then
        local pick = cfg.prefer_pat[math.random(1, #cfg.prefer_pat)]
        pat_eng.style = pick
        params:set("pat_style", pick + 1, true)
      end
      if #cfg.prefer_filt > 0 then
        local pick = cfg.prefer_filt[math.random(1, #cfg.prefer_filt)]
        if pick == 0 and filt_eng.style > 0 then filter_engineer_cleanup() end
        filt_eng.style = pick
        params:set("filt_style", pick + 1, true)
      end

      -- set engineer intensities
      timbre.intensity = randf(cfg.timbre_int[1], cfg.timbre_int[2])
      params:set("timbre_intensity", timbre.intensity, true)
      pat_eng.intensity = randf(cfg.pat_int[1], cfg.pat_int[2])
      params:set("pat_intensity", pat_eng.intensity, true)
      filt_eng.intensity = randf(cfg.filt_int[1], cfg.filt_int[2])
      params:set("filt_intensity", filt_eng.intensity, true)

      -- apply initial mute pattern for phase
      for t = 1, NUM_VOICES do
        mutes[t] = math.random() < cfg.mute_chance[t]
      end
    end
  end

  -- === ENERGY SLEW: smooth transitions ===
  bandleader.energy = bandleader.energy + (bandleader.target_energy - bandleader.energy) * 0.02

  -- === SYNC PULSES ===
  bandleader.sync_pulse = false
  local si = mind.sync_interval
  if bar_pos == 0 and bandleader.bar_count % math.random(si[1], si[2]) == 0 then
    bandleader.sync_pulse = true
    -- sync moment: bump all intensities briefly
    local bump = 0.2 * bandleader.energy
    timbre.intensity = math.min(1, timbre.intensity + bump)
    pat_eng.intensity = math.min(1, pat_eng.intensity + bump)
    filt_eng.intensity = math.min(1, filt_eng.intensity + bump)
  end

  -- === CONTRAST: feature one engineer while others rest ===
  bandleader.contrast_timer = bandleader.contrast_timer - 1
  if bandleader.contrast_timer <= 0 then
    if math.random() < mind.contrast_freq * bandleader.energy then
      -- start a contrast moment: one engineer gets boosted, others dim
      bandleader.contrast_voice = math.random(1, 3)
      bandleader.contrast_timer = math.random(8, 24)  -- steps

      if bandleader.contrast_voice == 1 then
        timbre.intensity = math.min(1, timbre.intensity + 0.3)
        pat_eng.intensity = math.max(0, pat_eng.intensity - 0.2)
        filt_eng.intensity = math.max(0, filt_eng.intensity - 0.2)
      elseif bandleader.contrast_voice == 2 then
        pat_eng.intensity = math.min(1, pat_eng.intensity + 0.3)
        timbre.intensity = math.max(0, timbre.intensity - 0.2)
        filt_eng.intensity = math.max(0, filt_eng.intensity - 0.2)
      else
        filt_eng.intensity = math.min(1, filt_eng.intensity + 0.3)
        timbre.intensity = math.max(0, timbre.intensity - 0.2)
        pat_eng.intensity = math.max(0, pat_eng.intensity - 0.2)
      end
    else
      bandleader.contrast_voice = 0
    end
  end

  -- === CALL AND RESPONSE: on beats, sometimes mute/unmute voices ===
  if beat == 0 and math.random() < 0.08 * bandleader.energy then
    -- quick mute/unmute of a non-kick voice for rhythmic effect
    local t = math.random(2, NUM_VOICES)
    mutes[t] = not mutes[t]
    -- auto-restore after 4-8 steps
    clock.run(function()
      clock.sleep(0.1 * math.random(4, 8))
      mutes[t] = not mutes[t]
    end)
  end

  -- === HARMONIC JOURNEY ===
  if mind.harmony_moves and bar_pos == 0 and bandleader.phase_bars == 0 then
    -- on phase transitions: move through circle of fifths
    if bandleader.energy > 0.6 then
      -- high energy: move up a fifth (tension)
      harmony.root = (harmony.root + 7) % 12
      params:set("root", harmony.root, true)
    elseif bandleader.energy < 0.3 then
      -- low energy: return down a fifth
      harmony.root = (harmony.root + 5) % 12
      params:set("root", harmony.root, true)
    end

    -- chord mode shifts with energy
    if bandleader.energy > 0.7 then
      harmony.chord_mode = true
      harmony.chord_type = math.random() < 0.6 and 1 or 2  -- major or minor
      params:set("chord_mode", 2, true)
      params:set("chord_type", harmony.chord_type, true)
    elseif bandleader.energy < 0.3 then
      if math.random() < 0.4 then
        harmony.chord_mode = false
        params:set("chord_mode", 1, true)
      end
    end
  end

  -- === INTENSITY DRIFT: gradual within-phase adjustments ===
  local cfg = mind.phases[bandleader.phase]
  -- gently nudge intensities toward phase targets
  local t_target = randf(cfg.timbre_int[1], cfg.timbre_int[2])
  local p_target = randf(cfg.pat_int[1], cfg.pat_int[2])
  local f_target = randf(cfg.filt_int[1], cfg.filt_int[2])

  if step_num % 8 == 0 then
    timbre.intensity = timbre.intensity + (t_target - timbre.intensity) * 0.05
    pat_eng.intensity = pat_eng.intensity + (p_target - pat_eng.intensity) * 0.05
    filt_eng.intensity = filt_eng.intensity + (f_target - filt_eng.intensity) * 0.05
  end
end

-- ============ FX SYSTEM (Esu's Trifecta-inspired) ============

local fx = {}
for i = 1, NUM_FX_SLOTS do
  fx[i] = { type = 0, param1 = 0.5, param2 = 0.3 }
end

local duck_amt = 0
local duck_decay = 0.15

local function set_fx_type(slot, fxtype)
  fx[slot].type = fxtype
  engine.fx_set(slot - 1, fxtype)
end

local function update_fx_params(slot)
  local t = fx[slot].type
  local p1 = fx[slot].param1
  local p2 = fx[slot].param2
  local s = slot - 1
  if t == 1 then
    engine.fx_param(s, "time", p1 * 1.5 + 0.01)
    engine.fx_param(s, "feedback", p2 * 0.85)
    engine.fx_param(s, "mix", 0.3)
  elseif t == 2 then
    engine.fx_param(s, "size", p1)
    engine.fx_param(s, "shimmer", p2)
    engine.fx_param(s, "mix", 0.25)
  elseif t == 3 then
    engine.fx_param(s, "freq", util.linexp(p1, 0, 1, 80, 12000))
    engine.fx_param(s, "lfoRate", p2 * 5)
    engine.fx_param(s, "mix", 0.8)
  elseif t == 4 then
    engine.fx_param(s, "bits", util.linlin(p1, 0, 1, 4, 16))
    engine.fx_param(s, "drive", p2)
    engine.fx_param(s, "mix", 0.5)
  elseif t == 5 then
    engine.fx_param(s, "freq", util.linexp(p1, 0, 1, 50, 2000))
    engine.fx_param(s, "depth", p2)
    engine.fx_param(s, "mix", 0.5)
  elseif t == 6 then
    engine.fx_param(s, "rate", p1 * 3)
    engine.fx_param(s, "depth", p2 * 0.01)
    engine.fx_param(s, "mix", 0.4)
  elseif t == 7 then
    engine.fx_param(s, "rate", p1 * 2)
    engine.fx_param(s, "depth", p2)
    engine.fx_param(s, "mix", 0.5)
  end
end

-- ============ TRIGGER VOICE ============

local function trigger_voice(track, velocity)
  local v = voices[track]
  local freq = v.base_freq
  if track >= 4 then
    if harmony.chord_mode then
      local chord = get_chord_notes()
      local idx = ((track - 4) % #chord) + 1
      freq = chord[idx]
    else
      freq = snap_to_scale(v.base_freq)
    end
  end
  -- per-hit mutation (MUTATE style)
  mutate_on_hit(track)
  -- drum brain: curated kick/snare sound design
  drum_brain_hit(track)

  local hz = musicutil.note_num_to_freq(freq)
  local amp = v.amp * velocity

  -- mode-specific extra params
  local extra1, extra2, extra3 = 0, 0, 0
  if v.mode == 0 then      -- FM
    extra1 = v.fm_index
    extra2 = v.fm_ratio
    extra3 = 0
  elseif v.mode == 1 then  -- Sub
    extra1 = v.shape
    extra2 = v.noise_amt
    extra3 = v.filter_env_amt
  elseif v.mode == 2 then  -- Noise
    extra1 = v.noise_type
    extra2 = v.grain_rate
    extra3 = v.ring_amt
  end

  engine.trig_ext(
    track - 1, v.mode, hz, amp, v.pan,
    v.decay, v.filter_freq, v.filter_res, v.filter_type,
    v.pitch_env, v.pitch_decay, v.spread, v.detune,
    extra1, extra2, extra3
  )
  if track == 1 and duck_amt > 0 then engine.duck_trig() end
  flash[track] = 8

  -- MIDI out
  local midi_vel = math.floor(velocity * 127)
  local is_drum = track <= 3
  local midi_ch = is_drum and params:get("midi_drum_ch") or params:get("midi_melody_ch")
  local midi_note = v.midi_note

  -- for pitched voices, send the actual tuned note
  if track >= 4 then
    midi_note = freq  -- freq is already a MIDI note number at this point
  end

  if midi_out then
    midi_out:note_on(midi_note, midi_vel, midi_ch)
    clock.run(function()
      clock.sleep(v.decay * 0.8)
      midi_out:note_off(midi_note, 0, midi_ch)
    end)
  end

  -- OP-XY out (separate device + channels)
  if opxy_out then
    local opxy_ch = is_drum and params:get("opxy_drum_ch") or params:get("opxy_melody_ch")
    opxy_out:note_on(midi_note, midi_vel, opxy_ch)
    clock.run(function()
      clock.sleep(v.decay * 0.8)
      opxy_out:note_off(midi_note, 0, opxy_ch)
    end)
  end

  recent_density[track] = 1
end

-- ============ OP-XY CC MAP ============

local OPXY_CC = {
  track_vol = 7, track_mute = 9, track_pan = 10,
  param1 = 12, param2 = 13, param3 = 14, param4 = 15,
  amp_atk = 20, amp_dec = 21, amp_sus = 22, amp_rel = 23,
  fil_atk = 24, fil_dec = 25, fil_sus = 26, fil_rel = 27,
  fil_cut = 32, fil_res = 33, fil_env_amt = 34,
  send_tape = 37, send_fx1 = 38, send_fx2 = 39,
  lfo1 = 40, lfo2 = 41, lfo3 = 42, lfo4 = 43,
}

local function opxy_cc(cc_num, val, ch)
  if opxy_out then
    opxy_out:cc(cc_num, math.floor(util.clamp(val, 0, 127)), ch or params:get("opxy_drum_ch"))
  end
end

-- send voice state to OP-XY as CCs (filter, decay, pan etc)
local function opxy_send_voice_state(track)
  if not opxy_out then return end
  local v = voices[track]
  local is_drum = track <= 3
  local ch = is_drum and params:get("opxy_drum_ch") or params:get("opxy_melody_ch")

  -- filter cutoff -> CC 32 (0-127 from 60-16000hz)
  opxy_cc(OPXY_CC.fil_cut, util.linlin(
    math.log(v.filter_freq), math.log(60), math.log(16000), 0, 127), ch)
  -- filter res -> CC 33
  opxy_cc(OPXY_CC.fil_res, v.filter_res * 127, ch)
  -- pan -> CC 10
  opxy_cc(OPXY_CC.track_pan, (v.pan + 1) * 63.5, ch)
  -- decay -> CC 21 (amp decay)
  opxy_cc(OPXY_CC.amp_dec, util.linlin(v.decay, 0.01, 2.0, 0, 127), ch)
end

-- ============ MIDI INPUT ============

local function midi_event(data)
  local msg = midi.to_msg(data)
  if not msg then return end

  if msg.type == "note_on" and msg.vel > 0 then
    local mode = params:get("midi_in_mode")
    if mode == 1 then
      -- play mode: trigger voices based on note ranges
      -- C1-B1 (36-47) = drum voices 1-6
      -- C2+ (48+) = pitched voice (tone, track 5)
      if msg.note >= 36 and msg.note <= 41 then
        local track = msg.note - 35  -- 36=kick, 37=snare, etc
        trigger_voice(track, msg.vel / 127)
      elseif msg.note >= 48 then
        -- play as pitched percussion on track 5
        voices[5].base_freq = msg.note
        trigger_voice(5, msg.vel / 127)
      end
    end
  elseif msg.type == "note_off" or (msg.type == "note_on" and msg.vel == 0) then
    -- percussion is one-shot, nothing to do
  elseif msg.type == "cc" then
    -- CC mapping for live performance
    -- CC 1 (mod wheel) = timbre intensity
    if msg.cc == 1 then
      timbre.intensity = msg.val / 127
      params:set("timbre_intensity", timbre.intensity, true)
    -- CC 74 (filter) = selected track filter freq
    elseif msg.cc == 74 then
      local freq = util.linexp(msg.val, 0, 127, 60, 16000)
      voices[selected_track].filter_freq = freq
      params:set("v" .. selected_track .. "_filter", freq, true)
    -- CC 71 (resonance) = selected track filter res
    elseif msg.cc == 71 then
      voices[selected_track].filter_res = msg.val / 127
      params:set("v" .. selected_track .. "_res", msg.val / 127, true)
    -- CC 73 (attack) = selected track pitch env
    elseif msg.cc == 73 then
      voices[selected_track].pitch_env = msg.val / 127 * 16
      params:set("v" .. selected_track .. "_penv", voices[selected_track].pitch_env, true)
    -- CC 72 (release/decay) = selected track decay
    elseif msg.cc == 72 then
      voices[selected_track].decay = util.linexp(msg.val, 0, 127, 0.01, 2.0)
      params:set("v" .. selected_track .. "_decay", voices[selected_track].decay, true)
    -- CC 10 (pan) = selected track pan
    elseif msg.cc == 10 then
      voices[selected_track].pan = msg.val / 63.5 - 1
      params:set("v" .. selected_track .. "_pan", voices[selected_track].pan, true)
    end
  elseif msg.type == "start" then
    start_sequence()
  elseif msg.type == "stop" then
    stop_sequence()
  end
end

-- ============ SEQUENCER CLOCK ============

local function advance_step()
  step = (step % NUM_STEPS) + 1
  for t = 1, NUM_VOICES do recent_density[t] = 0 end

  for t = 1, NUM_VOICES do
    if not mutes[t] and seq[t].pattern[step] == 1 then
      -- combine step probability with track probability
      local prob = seq[t].prob[step] * seq[t].track_prob / 100
      if math.random(100) <= prob then
        trigger_voice(t, seq[t].vel[step])
      end
    end
  end

  drift_step()
  react_adjust()
  -- bandleader runs FIRST — sets intensities and styles for the engineers
  local bok, berr = pcall(bandleader_step, step)
  if not bok then print("terra bandleader error: " .. tostring(berr)) end
  -- then the three engineers execute with bandleader's guidance
  local tok, terr = pcall(timbre_engineer_step, step)
  if not tok then print("terra timbre error: " .. tostring(terr)) end
  local pok, perr = pcall(pattern_engineer_step, step)
  if not pok then print("terra pattern error: " .. tostring(perr)) end
  local fok, ferr = pcall(filter_engineer_step, step)
  if not fok then print("terra filter error: " .. tostring(ferr)) end

  -- send voice state to OP-XY every 4 steps (don't flood MIDI)
  if opxy_out and step % 4 == 1 then
    for t = 1, NUM_VOICES do
      pcall(opxy_send_voice_state, t)
    end
  end

  screen_dirty = true
  grid_dirty = true
end

local function stop_sequence()
  playing = false
  if clock_id then
    clock.cancel(clock_id)
    clock_id = nil
  end
end

local function start_sequence()
  -- prevent duplicate clocks
  if clock_id then stop_sequence() end
  playing = true
  step = 0
  clock_id = clock.run(function()
    while true do
      clock.sync(1/4)
      if swing_amt > 0 and step % 2 == 0 then
        clock.sleep((swing_amt / 100) * (60 / clock.get_tempo() / 4))
      end
      if playing then
        local ok, err = pcall(advance_step)
        if not ok then
          print("terra clock error: " .. tostring(err))
        end
      end
    end
  end)
end

-- ============ PARAMS ============


-- ============ PRESET SNAPSHOTS ============
-- 8 slots to save/recall the entire state

local NUM_PRESETS = 8
local presets = {}

local function snapshot_state()
  local state = {
    voices = {},
    seq = {},
    mutes = {table.unpack(mutes)},
    harmony = {
      root = harmony.root, scale_type = harmony.scale_type,
      chord_mode = harmony.chord_mode, chord_type = harmony.chord_type,
      drift_rate = harmony.drift_rate,
    },
    timbre_style = timbre.style, timbre_intensity = timbre.intensity,
    pat_style = pat_eng.style, pat_intensity = pat_eng.intensity,
    filt_style = filt_eng.style, filt_intensity = filt_eng.intensity,
    bandleader_mindset = bandleader.mindset, bandleader_active = bandleader.active,
    fx = {},
    duck_amt = duck_amt, duck_decay = duck_decay,
    swing_amt = swing_amt,
  }
  for i = 1, NUM_VOICES do
    local v = voices[i]
    state.voices[i] = {
      mode = v.mode, base_freq = v.base_freq, decay = v.decay,
      filter_freq = v.filter_freq, filter_res = v.filter_res, filter_type = v.filter_type,
      pitch_env = v.pitch_env, pitch_decay = v.pitch_decay,
      pan = v.pan, spread = v.spread, detune = v.detune, amp = v.amp,
      fm_index = v.fm_index, fm_ratio = v.fm_ratio,
      shape = v.shape, noise_amt = v.noise_amt, filter_env_amt = v.filter_env_amt,
      noise_type = v.noise_type, grain_rate = v.grain_rate, ring_amt = v.ring_amt,
    }
    state.seq[i] = {
      pattern = {table.unpack(seq[i].pattern)},
      prob = {table.unpack(seq[i].prob)},
      vel = {table.unpack(seq[i].vel)},
      euclid_k = seq[i].euclid_k, euclid_offset = seq[i].euclid_offset,
      track_prob = seq[i].track_prob,
    }
  end
  for i = 1, NUM_FX_SLOTS do
    state.fx[i] = { type = fx[i].type, param1 = fx[i].param1, param2 = fx[i].param2 }
  end
  return state
end

local function recall_state(state)
  if not state then return end
  for i = 1, NUM_VOICES do
    for k, v in pairs(state.voices[i]) do voices[i][k] = v end
    for s = 1, NUM_STEPS do
      seq[i].pattern[s] = state.seq[i].pattern[s]
      seq[i].prob[s] = state.seq[i].prob[s]
      seq[i].vel[s] = state.seq[i].vel[s]
    end
    seq[i].euclid_k = state.seq[i].euclid_k
    seq[i].euclid_offset = state.seq[i].euclid_offset
    seq[i].track_prob = state.seq[i].track_prob
    mutes[i] = state.mutes[i]
  end
  harmony.root = state.harmony.root
  harmony.scale_type = state.harmony.scale_type
  harmony.chord_mode = state.harmony.chord_mode
  harmony.chord_type = state.harmony.chord_type
  harmony.drift_rate = state.harmony.drift_rate
  timbre.style = state.timbre_style
  timbre.intensity = state.timbre_intensity
  pat_eng.style = state.pat_style
  pat_eng.intensity = state.pat_intensity
  filt_eng.style = state.filt_style
  filt_eng.intensity = state.filt_intensity
  bandleader.mindset = state.bandleader_mindset
  bandleader.active = state.bandleader_active
  swing_amt = state.swing_amt
  duck_amt = state.duck_amt; engine.duck_amt(duck_amt)
  duck_decay = state.duck_decay; engine.duck_decay(duck_decay)
  for i = 1, NUM_FX_SLOTS do
    fx[i].type = state.fx[i].type
    fx[i].param1 = state.fx[i].param1
    fx[i].param2 = state.fx[i].param2
    set_fx_type(i, fx[i].type)
    update_fx_params(i)
  end
end

local function save_preset(slot)
  presets[slot] = snapshot_state()
end

local function load_preset(slot)
  recall_state(presets[slot])
end

-- simple table serializer (tab.serialize may not exist on all norns)
local function _ser(t, ind)
  ind = ind or ""
  local ni = ind .. "  "
  local p = {"{"}
  for k, v in pairs(t) do
    local ks = type(k) == "number" and ("[" .. k .. "]") or k
    local vs
    if type(v) == "table" then vs = _ser(v, ni)
    elseif type(v) == "string" then vs = string.format("%q", v)
    elseif type(v) == "boolean" then vs = v and "true" or "false"
    else vs = tostring(v) end
    p[#p+1] = ni .. ks .. "=" .. vs .. ","
  end
  p[#p+1] = ind .. "}"
  return table.concat(p, "\n")
end

local function save_patterns_to_disk()
  local data = snapshot_state()
  local dir = norns.state.data
  os.execute("mkdir -p " .. dir)
  local file = io.open(dir .. "patterns.lua", "w")
  if file then
    file:write("return " .. _ser(data))
    file:close()
    print("terra: patterns saved")
  end
end

local function load_patterns_from_disk()
  local dir = norns.state.data
  local path = dir .. "patterns.lua"
  local file = io.open(path, "r")
  if file then
    file:close()
    local ok, data = pcall(dofile, path)
    if ok and data then
      recall_state(data)
      print("terra: patterns loaded from " .. path)
    end
  end
end

-- ============ SOFTCUT LOOPER ============
-- Records terra's output into a softcut buffer and plays it back
-- with speed/direction/grain manipulation

local sc_loop = {
  recording = false,
  playing = false,
  rate = 1.0,
  level = 0.5,
  loop_start = 0,
  loop_end = 4,  -- seconds
  rec_head = 0,
  filter = 1.0,  -- 0=dark, 1=bright
}

local function softcut_init()
  -- voice 1: record from input (terra's output goes to DAC which we can monitor)
  -- voice 2: playback
  softcut.buffer_clear()

  -- playback voice
  softcut.enable(1, 1)
  softcut.buffer(1, 1)
  softcut.level(1, sc_loop.level)
  softcut.pan(1, 0)
  softcut.rate(1, sc_loop.rate)
  softcut.loop(1, 1)
  softcut.loop_start(1, 0)
  softcut.loop_end(1, sc_loop.loop_end)
  softcut.position(1, 0)
  softcut.play(1, 0)
  softcut.pre_level(1, 0.8)
  softcut.rec_level(1, 1)
  softcut.rec(1, 0)
  softcut.level_slew_time(1, 0.1)
  softcut.rate_slew_time(1, 0.1)
  softcut.post_filter_dry(1, 0.5)
  softcut.post_filter_lp(1, 1.0)

  -- record voice (monitors input)
  softcut.enable(2, 1)
  softcut.buffer(2, 1)
  softcut.level(2, 0)  -- silent (just recording)
  softcut.rate(2, 1)
  softcut.loop(2, 1)
  softcut.loop_start(2, 0)
  softcut.loop_end(2, sc_loop.loop_end)
  softcut.position(2, 0)
  softcut.play(2, 1)
  softcut.rec_level(2, 1)
  softcut.pre_level(2, 0.6)  -- some overdub
  softcut.rec(2, 0)
  softcut.level_input_cut(1, 2, 1.0)  -- input 1 to record voice
  softcut.level_input_cut(2, 2, 1.0)  -- input 2 to record voice
end

local function sc_start_record()
  sc_loop.recording = true
  softcut.rec(2, 1)
  softcut.position(2, 0)
end

local function sc_stop_record()
  sc_loop.recording = false
  softcut.rec(2, 0)
end

local function sc_start_playback()
  sc_loop.playing = true
  softcut.level(1, sc_loop.level)
  softcut.rate(1, sc_loop.rate)
  softcut.play(1, 1)
  softcut.position(1, 0)
end

local function sc_stop_playback()
  sc_loop.playing = false
  softcut.play(1, 0)
  softcut.level(1, 0)
end

local function sc_set_rate(r)
  sc_loop.rate = r
  softcut.rate(1, r)
end

local function sc_set_level(l)
  sc_loop.level = l
  softcut.level(1, l)
end

local function sc_set_filter(f)
  sc_loop.filter = f
  softcut.post_filter_lp(1, f)
  softcut.post_filter_dry(1, 1 - f * 0.5)
end


local function build_params()
  params:add_separator("TERRA")

  -- === TRANSPORT ===
  params:add_separator("TRANSPORT")
  params:add_option("playing", "playing", {"off", "on"}, 1)
  params:set_action("playing", function(v)
    if v == 2 then start_sequence() else stop_sequence() end
  end)
  params:add_control("swing", "swing",
    controlspec.new(0, 80, 'lin', 1, 0, "%"))
  params:set_action("swing", function(v) swing_amt = v end)

  -- === VOICES (1-6) ===
  for i = 1, NUM_VOICES do
    params:add_separator("VOICE " .. i .. ": " .. VOICE_NAMES[i])
    params:add_option("v" .. i .. "_mode", "mode", MODE_NAMES, voices[i].mode + 1)
    params:set_action("v" .. i .. "_mode", function(v) voices[i].mode = v - 1 end)
    params:add_number("v" .. i .. "_note", "note", 24, 108, voices[i].base_freq)
    params:set_action("v" .. i .. "_note", function(v) voices[i].base_freq = v end)
    params:add_control("v" .. i .. "_decay", "decay",
      controlspec.new(0.01, 2.0, 'exp', 0.01, voices[i].decay, "s"))
    params:set_action("v" .. i .. "_decay", function(v) voices[i].decay = v end)
    params:add_control("v" .. i .. "_filter", "filter freq",
      controlspec.new(40, 18000, 'exp', 0, voices[i].filter_freq, "hz"))
    params:set_action("v" .. i .. "_filter", function(v) voices[i].filter_freq = v end)
    params:add_control("v" .. i .. "_res", "filter res",
      controlspec.new(0.05, 1.0, 'lin', 0.01, voices[i].filter_res))
    params:set_action("v" .. i .. "_res", function(v) voices[i].filter_res = v end)
    params:add_option("v" .. i .. "_ftype", "filter type", {"LP", "HP", "BP"}, voices[i].filter_type + 1)
    params:set_action("v" .. i .. "_ftype", function(v) voices[i].filter_type = v - 1 end)
    params:add_control("v" .. i .. "_penv", "pitch env",
      controlspec.new(0, 16, 'lin', 0.1, voices[i].pitch_env))
    params:set_action("v" .. i .. "_penv", function(v) voices[i].pitch_env = v end)
    params:add_control("v" .. i .. "_pdecay", "pitch decay",
      controlspec.new(0.005, 0.5, 'exp', 0.001, voices[i].pitch_decay, "s"))
    params:set_action("v" .. i .. "_pdecay", function(v) voices[i].pitch_decay = v end)
    params:add_control("v" .. i .. "_pan", "pan",
      controlspec.new(-1, 1, 'lin', 0.01, voices[i].pan))
    params:set_action("v" .. i .. "_pan", function(v) voices[i].pan = v end)
    params:add_control("v" .. i .. "_spread", "stereo spread",
      controlspec.new(0, 1, 'lin', 0.01, voices[i].spread))
    params:set_action("v" .. i .. "_spread", function(v) voices[i].spread = v end)
    params:add_control("v" .. i .. "_amp", "amp",
      controlspec.new(0, 1, 'lin', 0.01, voices[i].amp))
    params:set_action("v" .. i .. "_amp", function(v) voices[i].amp = v end)
    params:add_number("v" .. i .. "_euclid", "euclidean pulses", 0, 16, 0)
    params:set_action("v" .. i .. "_euclid", function(v)
      seq[i].euclid_k = v; apply_euclidean(i)
    end)
    params:add_number("v" .. i .. "_prob", "track probability", 0, 100, 100)
    params:set_action("v" .. i .. "_prob", function(v) seq[i].track_prob = v end)
    params:add_option("v" .. i .. "_mute", "mute", {"off", "on"}, 1)
    params:set_action("v" .. i .. "_mute", function(v) mutes[i] = v == 2 end)
  end

  -- === HARMONY ===
  params:add_separator("HARMONY")
  params:add_number("root", "root note", 0, 11, 0)
  params:set_action("root", function(v)
    harmony.root = v
    for i, n in ipairs(CIRCLE_OF_FIFTHS) do
      if n == v then harmony.circle_pos = i; break end
    end
  end)
  params:add_option("scale", "scale", SCALE_NAMES, 1)
  params:set_action("scale", function(v) harmony.scale_type = v end)
  params:add_option("chord_mode", "chord mode", {"off", "on"}, 1)
  params:set_action("chord_mode", function(v) harmony.chord_mode = v == 2 end)
  params:add_option("chord_type", "chord type", {"major", "minor", "dim"}, 1)
  params:set_action("chord_type", function(v) harmony.chord_type = v end)
  params:add_number("harmonic_drift", "harmonic drift", 0, 5, 0)
  params:set_action("harmonic_drift", function(v) harmony.drift_rate = v end)

  -- === BANDLEADER (master conductor) ===
  params:add_separator("BANDLEADER")
  params:add_option("bandleader", "mindset", BANDLEADER_STYLES, 1)
  params:set_action("bandleader", function(v)
    if v == 1 then
      bandleader.active = false
    else
      bandleader.active = true
      bandleader.mindset = v - 1
      bandleader.phase = 1
      bandleader.phase_bars = 0
      bandleader.bar_count = 0
    end
  end)

  -- === TIMBRE ENGINEER ===
  params:add_separator("TIMBRE ENGINEER")
  params:add_option("timbre_style", "style", TIMBRE_STYLES, 1)
  params:set_action("timbre_style", function(v) timbre.style = v - 1 end)
  params:add_control("timbre_intensity", "intensity",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("timbre_intensity", function(v) timbre.intensity = v end)

  -- === PATTERN ENGINEER ===
  params:add_separator("PATTERN ENGINEER")
  params:add_option("pat_style", "style", PAT_STYLES, 1)
  params:set_action("pat_style", function(v) pat_eng.style = v - 1 end)
  params:add_control("pat_intensity", "intensity",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("pat_intensity", function(v) pat_eng.intensity = v end)

  -- === FILTER ENGINEER ===
  params:add_separator("FILTER ENGINEER")
  params:add_option("filt_style", "style", FILT_STYLES, 1)
  params:set_action("filt_style", function(v)
    if v == 1 and filt_eng.style > 0 then filter_engineer_cleanup() end
    filt_eng.style = v - 1
  end)
  params:add_control("filt_intensity", "intensity",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("filt_intensity", function(v) filt_eng.intensity = v end)

  -- === FX CHAIN ===
  params:add_separator("FX CHAIN")
  for i = 1, NUM_FX_SLOTS do
    params:add_option("fx" .. i .. "_type", "fx " .. i .. " type", FX_NAMES, 1)
    params:set_action("fx" .. i .. "_type", function(v)
      set_fx_type(i, v - 1); fx[i].type = v - 1
    end)
    params:add_control("fx" .. i .. "_p1", "fx " .. i .. " param 1",
      controlspec.new(0, 1, 'lin', 0.01, 0.5))
    params:set_action("fx" .. i .. "_p1", function(v)
      fx[i].param1 = v; update_fx_params(i)
    end)
    params:add_control("fx" .. i .. "_p2", "fx " .. i .. " param 2",
      controlspec.new(0, 1, 'lin', 0.01, 0.3))
    params:set_action("fx" .. i .. "_p2", function(v)
      fx[i].param2 = v; update_fx_params(i)
    end)
  end

  -- === SIDECHAIN ===
  params:add_separator("SIDECHAIN")
  params:add_control("duck_amt", "duck amount",
    controlspec.new(0, 1, 'lin', 0.01, 0))
  params:set_action("duck_amt", function(v) duck_amt = v; engine.duck_amt(v) end)
  params:add_control("duck_decay", "duck decay",
    controlspec.new(0.03, 0.5, 'exp', 0.01, 0.15, "s"))
  params:set_action("duck_decay", function(v) duck_decay = v; engine.duck_decay(v) end)

  -- === LOOPER ===
  params:add_separator("LOOPER")
  params:add_option("loop_rec", "record", {"off", "on"}, 1)
  params:set_action("loop_rec", function(v)
    if v == 2 then sc_start_record() else sc_stop_record() end
  end)
  params:add_option("loop_play", "play", {"off", "on"}, 1)
  params:set_action("loop_play", function(v)
    if v == 2 then sc_start_playback() else sc_stop_playback() end
  end)
  params:add_control("loop_level", "level",
    controlspec.new(0, 1, 'lin', 0.01, 0.5))
  params:set_action("loop_level", function(v) sc_set_level(v) end)
  params:add_control("loop_rate", "rate",
    controlspec.new(-2, 2, 'lin', 0.01, 1))
  params:set_action("loop_rate", function(v) sc_set_rate(v) end)
  params:add_control("loop_filter", "filter",
    controlspec.new(0, 1, 'lin', 0.01, 1))
  params:set_action("loop_filter", function(v) sc_set_filter(v) end)
  params:add_control("loop_length", "length",
    controlspec.new(0.5, 16, 'lin', 0.1, 4, "s"))
  params:set_action("loop_length", function(v)
    sc_loop.loop_end = v
    softcut.loop_end(1, v)
    softcut.loop_end(2, v)
  end)

  -- === PRESETS ===
  params:add_separator("PRESETS")
  for i = 1, NUM_PRESETS do
    params:add_trigger("preset_save_" .. i, "save slot " .. i)
    params:set_action("preset_save_" .. i, function() save_preset(i) end)
    params:add_trigger("preset_load_" .. i, "load slot " .. i)
    params:set_action("preset_load_" .. i, function() load_preset(i) end)
  end
  params:add_trigger("save_to_disk", "> save to disk")
  params:set_action("save_to_disk", function() save_patterns_to_disk() end)
  params:add_trigger("load_from_disk", "> load from disk")
  params:set_action("load_from_disk", function() load_patterns_from_disk() end)

  -- === MIDI ===
  params:add_separator("MIDI OUT")
  params:add_number("midi_device", "midi device", 1, 4, 1)
  params:set_action("midi_device", function(v) midi_out = midi.connect(v) end)
  params:add_number("midi_drum_ch", "drum channel", 1, 16, 10)
  params:add_number("midi_melody_ch", "melody channel", 1, 16, 1)

  params:add_separator("OP-XY")
  params:add_option("opxy_enabled", "OP-XY out", {"off", "on"}, 1)
  params:add_number("opxy_device", "OP-XY device", 1, 4, 2)
  params:set_action("opxy_device", function(v)
    if params:get("opxy_enabled") == 2 then opxy_out = midi.connect(v) end
  end)
  params:add_number("opxy_drum_ch", "OP-XY drum ch", 1, 16, 1)
  params:add_number("opxy_melody_ch", "OP-XY melody ch", 1, 16, 2)

  params:add_separator("MIDI IN")
  params:add_number("midi_in_device", "midi in device", 1, 4, 1)
  params:set_action("midi_in_device", function(v)
    midi_in_device = midi.connect(v)
    midi_in_device.event = midi_event
  end)
  params:add_option("midi_in_mode", "midi in mode", {"play", "map"}, 1)
end

-- ============ SCREEN ============

local function draw_main()
  -- header
  screen.level(15)
  screen.move(0, 7)
  screen.text("TERRA")
  screen.level(playing and 15 or 4)
  screen.move(40, 7)
  if gen_flash > 10 then
    screen.level(15)
    screen.text("GEN ALL")
    gen_flash = gen_flash - 1
  elseif gen_flash > 0 then
    screen.level(15)
    screen.text("GEN " .. VOICE_SHORT[selected_track])
    gen_flash = gen_flash - 1
  else
    screen.text(playing and ">" or "STOP")
  end

  -- bandleader phase or engineer indicators
  if bandleader.active then
    local mind = MINDSET_CONFIGS[bandleader.mindset]
    -- mindset name (dim) + phase name (bright)
    screen.level(5)
    screen.move(64, 7)
    screen.text(string.sub(mind.name, 1, 3))
    screen.level(12)
    screen.move(84, 7)
    local phase_idx = math.min(bandleader.phase, #BANDLEADER_PHASES)
    screen.text(string.sub(BANDLEADER_PHASES[phase_idx], 1, 4))
    -- energy bar
    screen.level(math.floor(bandleader.energy * 12) + 2)
    screen.rect(110, 2, math.floor(bandleader.energy * 16), 3)
    screen.fill()
  else
    local eng_x = 74
    if drift_mode then
      screen.level(5); screen.move(eng_x, 7); screen.text("D"); eng_x = eng_x + 7
    end
    if timbre.style > 0 then
      screen.level(6); screen.move(eng_x, 7); screen.text("T"); eng_x = eng_x + 7
    end
    if pat_eng.style > 0 then
      screen.level(6); screen.move(eng_x, 7); screen.text("P"); eng_x = eng_x + 7
    end
    if filt_eng.style > 0 then
      screen.level(6); screen.move(eng_x, 7); screen.text("F"); eng_x = eng_x + 7
    end
  end

  -- voice lanes
  for t = 1, NUM_VOICES do
    local y = 10 + (t - 1) * 9

    -- selected track indicator: arrow
    if t == selected_track then
      screen.level(15)
      screen.move(0, y + 5)
      screen.text(">")
    end

    -- track name (dim if muted, bright if selected)
    local name_level = mutes[t] and 2 or (t == selected_track and 15 or 5)
    -- trigger flash: briefly boost name brightness
    if flash[t] > 0 then
      name_level = math.min(15, name_level + flash[t])
    end
    screen.level(name_level)
    screen.move(5, y + 6)
    screen.text(VOICE_SHORT[t])

    -- probability indicator
    if seq[t].track_prob < 100 then
      screen.level(3)
      screen.move(12, y + 6)
      screen.text(seq[t].track_prob)
    end

    -- steps
    for s = 1, NUM_STEPS do
      local x = 16 + (s - 1) * 7

      if mutes[t] then
        -- muted: dim everything
        if seq[t].pattern[s] == 1 then
          screen.level(2)
          screen.rect(x, y, 5, 5)
          screen.fill()
        end
      elseif seq[t].pattern[s] == 1 then
        if s == step and playing then
          screen.level(15)
        else
          -- brightness = velocity
          screen.level(math.floor(seq[t].vel[s] * 10) + 2)
        end
        screen.rect(x, y, 5, 5)
        screen.fill()
        -- probability dot (dim if < 100%)
        if seq[t].prob[s] < 90 then
          screen.level(1)
          screen.pixel(x + 2, y + 2)
          screen.fill()
        end
      else
        if s == step and playing then
          screen.level(5)
          screen.rect(x, y, 5, 5)
          screen.stroke()
        else
          screen.level(1)
          screen.pixel(x + 2, y + 2)
          screen.fill()
        end
      end
    end
  end
end

local function draw_pattern()
  screen.level(15)
  screen.move(0, 7)
  screen.text(VOICE_NAMES[selected_track])
  screen.level(4)
  screen.move(50, 7)
  screen.text(MODE_NAMES[voices[selected_track].mode + 1])
  if mutes[selected_track] then
    screen.level(3)
    screen.move(80, 7)
    screen.text("MUTE")
  end

  -- euclidean circle
  local cx, cy, r = 38, 38, 22
  for s = 1, NUM_STEPS do
    local angle = (s - 1) / NUM_STEPS * 2 * math.pi - math.pi / 2
    local px = cx + math.cos(angle) * r
    local py = cy + math.sin(angle) * r

    if seq[selected_track].pattern[s] == 1 then
      if s == step and playing then
        screen.level(15)
        screen.circle(px, py, 3)
        screen.fill()
      else
        screen.level(math.floor(seq[selected_track].vel[s] * 10) + 2)
        screen.circle(px, py, 2)
        screen.fill()
      end
    else
      screen.level(2)
      screen.circle(px, py, 1)
      screen.fill()
    end
  end

  -- playhead line
  if playing then
    local angle = (step - 1) / NUM_STEPS * 2 * math.pi - math.pi / 2
    local lx = cx + math.cos(angle) * (r - 6)
    local ly = cy + math.sin(angle) * (r - 6)
    screen.level(6)
    screen.move(cx, cy)
    screen.line(lx, ly)
    screen.stroke()
  end

  -- info
  local x = 72
  screen.level(10)
  screen.move(x, 16)
  screen.text("euc: " .. seq[selected_track].euclid_k)
  screen.move(x, 25)
  screen.text("off: " .. seq[selected_track].euclid_offset)
  screen.move(x, 36)
  screen.text(musicutil.note_num_to_name(voices[selected_track].base_freq, true))
  screen.move(x, 45)
  screen.text(string.format("%.2fs", voices[selected_track].decay))
  screen.move(x, 54)
  screen.text(math.floor(voices[selected_track].filter_freq) .. "hz")
  screen.move(x, 63)
  screen.text("prob:" .. seq[selected_track].track_prob .. "%")
end

local function draw_fx()
  screen.level(15)
  screen.move(0, 7)
  screen.text("FX CHAIN")

  -- timbre engineer status in header
  if timbre.style > 0 then
    screen.level(10)
    screen.move(62, 7)
    screen.text(TIMBRE_STYLES[timbre.style + 1])
  end

  for i = 1, NUM_FX_SLOTS do
    local y = 8 + (i - 1) * 16

    screen.level(i == selected_fx_slot and 15 or 6)
    screen.move(0, y + 8)
    screen.text(i .. ":" .. FX_NAMES[fx[i].type + 1])

    if fx[i].type > 0 then
      local pnames = FX_PARAMS[fx[i].type + 1]
      screen.level(4)
      screen.move(58, y + 4)
      screen.text(pnames[1])
      screen.level(i == selected_fx_slot and 12 or 6)
      local w1 = math.max(1, fx[i].param1 * 52)
      screen.rect(58, y + 6, w1, 3)
      screen.fill()

      screen.level(4)
      screen.move(58, y + 11)
      screen.text(pnames[2])
      screen.level(i == selected_fx_slot and 10 or 5)
      local w2 = math.max(1, fx[i].param2 * 52)
      screen.rect(58, y + 13, w2, 3)
      screen.fill()
    end
  end

  -- engineer status bar at bottom
  local ey = 58
  -- timbre
  if timbre.style > 0 then
    screen.level(10)
    screen.move(0, ey)
    screen.text("T:" .. string.sub(TIMBRE_STYLES[timbre.style + 1], 1, 3))
  end
  -- pattern
  if pat_eng.style > 0 then
    screen.level(10)
    screen.move(30, ey)
    screen.text("P:" .. string.sub(PAT_STYLES[pat_eng.style + 1], 1, 3))
  end
  -- filter
  if filt_eng.style > 0 then
    screen.level(10)
    screen.move(60, ey)
    screen.text("F:" .. string.sub(FILT_STYLES[filt_eng.style + 1], 1, 3))
  end
  -- duck
  if duck_amt > 0 then
    screen.level(8)
    screen.move(90, ey)
    screen.text("D:" .. string.format("%.0f", duck_amt * 100))
  end
  -- looper status
  if sc_loop.recording or sc_loop.playing then
    screen.level(sc_loop.recording and 15 or 8)
    screen.move(110, ey)
    screen.text(sc_loop.recording and "REC" or "LOOP")
  end
end

local function draw_harmony()
  screen.level(15)
  screen.move(0, 7)
  screen.text("HARMONY")

  local cx, cy, r = 38, 38, 22

  for i = 1, 12 do
    local angle = (i - 1) / 12 * 2 * math.pi - math.pi / 2
    local px = cx + math.cos(angle) * r
    local py = cy + math.sin(angle) * r
    local note_idx = CIRCLE_OF_FIFTHS[i]

    if note_idx == harmony.root then
      screen.level(15)
      screen.circle(px, py, 5)
      screen.fill()
      screen.level(0)
      screen.move(px - 3, py + 2)
      screen.text(NOTE_NAMES_SHARP[note_idx + 1])
    else
      local in_scale = false
      local scale_notes = get_scale_notes()
      for _, sn in ipairs(scale_notes) do
        if sn % 12 == note_idx then in_scale = true; break end
      end
      if in_scale then
        screen.level(8)
        screen.circle(px, py, 3)
        screen.fill()
      else
        screen.level(3)
        screen.circle(px, py, 2)
        screen.stroke()
      end
      local lx = cx + math.cos(angle) * (r + 8)
      local ly = cy + math.sin(angle) * (r + 8)
      screen.level(in_scale and 8 or 3)
      screen.move(lx - 2, ly + 2)
      screen.text(NOTE_NAMES_SHARP[note_idx + 1])
    end
  end

  local x = 72
  screen.level(12)
  screen.move(x, 16)
  screen.text(NOTE_NAMES_SHARP[harmony.root + 1])
  screen.move(x, 26)
  screen.level(8)
  -- truncate scale name to fit
  local sname = SCALE_NAMES[harmony.scale_type]
  if #sname > 10 then sname = string.sub(sname, 1, 9) .. "." end
  screen.text(sname)
  screen.move(x, 38)
  screen.level(harmony.chord_mode and 15 or 4)
  screen.text(harmony.chord_mode and "CHORD" or "scale")
  if harmony.chord_mode then
    screen.move(x, 48)
    screen.level(12)
    local ct = {"MAJ", "MIN", "DIM"}
    screen.text(ct[harmony.chord_type])
  end
  screen.move(x, 60)
  screen.level(harmony.drift_rate > 0 and 10 or 4)
  screen.text("drift:" .. harmony.drift_rate)
end

function redraw()
  screen.clear()
  if page == 1 then draw_main()
  elseif page == 2 then draw_pattern()
  elseif page == 3 then draw_fx()
  elseif page == 4 then draw_harmony()
  end
  screen.update()
end

-- ============ CONTROLS ============

-- E1: always page
-- page 1 (MAIN):   E2=select track, E3=euclid pulses (or velocity if grid held)
-- page 2 (PATTERN):E2=select track, E3=euclid offset
-- page 3 (FX):     E2=select FX slot, E3=FX type
-- page 4 (HARMONY):E2=root note, E3=scale
--
-- K2: play/stop (always)
-- K3 page-dependent:
--   page 1: generate pattern for selected track
--   page 2: toggle mute for selected track
--   page 3: cycle timbre engineer style
--   page 4: cycle chord mode (off → major → minor → dim → off)
-- K2 hold + K3: toggle drift+react
-- K2 hold + E2: filter freq for selected track (performance macro)
-- K2 hold + E3: decay for selected track (performance macro)

function enc(n, d)
  if n == 1 then
    page = util.clamp(page + d, 1, 4)

  elseif k2_held then
    -- K2 held: performance macros
    local t = selected_track
    if n == 2 then
      -- filter freq sweep
      voices[t].filter_freq = util.clamp(voices[t].filter_freq * (1 + d * 0.05), 60, 16000)
      params:set("v" .. t .. "_filter", voices[t].filter_freq, true)
    elseif n == 3 then
      -- decay sweep
      voices[t].decay = util.clamp(voices[t].decay + d * 0.02, 0.01, 2.0)
      params:set("v" .. t .. "_decay", voices[t].decay, true)
    end

  elseif page == 1 then
    if n == 2 then
      selected_track = util.clamp(selected_track + d, 1, NUM_VOICES)
    elseif n == 3 then
      -- check if any grid step held: adjust its velocity
      local held_step = nil
      for key, h in pairs(grid_held) do
        if h.y >= 1 and h.y <= 6 then held_step = h; break end
      end
      if held_step then
        local t = held_step.y
        local s = held_step.x
        seq[t].vel[s] = util.clamp(seq[t].vel[s] + d * 0.05, 0.1, 1.0)
      else
        seq[selected_track].euclid_k = util.clamp(seq[selected_track].euclid_k + d, 0, NUM_STEPS)
        apply_euclidean(selected_track)
        params:set("v" .. selected_track .. "_euclid", seq[selected_track].euclid_k, true)
      end
    end

  elseif page == 2 then
    if n == 2 then
      selected_track = util.clamp(selected_track + d, 1, NUM_VOICES)
    elseif n == 3 then
      seq[selected_track].euclid_offset = (seq[selected_track].euclid_offset + d) % NUM_STEPS
      apply_euclidean(selected_track)
    end

  elseif page == 3 then
    if n == 2 then
      selected_fx_slot = util.clamp(selected_fx_slot + d, 1, NUM_FX_SLOTS)
    elseif n == 3 then
      local slot = selected_fx_slot
      fx[slot].type = util.clamp(fx[slot].type + d, 0, #FX_NAMES - 1)
      set_fx_type(slot, fx[slot].type)
      params:set("fx" .. slot .. "_type", fx[slot].type + 1, true)
    end

  elseif page == 4 then
    if n == 2 then
      harmony.root = (harmony.root + d) % 12
      params:set("root", harmony.root, true)
    elseif n == 3 then
      harmony.scale_type = util.clamp(harmony.scale_type + d, 1, SCALE_COUNT)
      params:set("scale", harmony.scale_type, true)
    end
  end
  screen_dirty = true; grid_dirty = true
end

function key(n, z)
  if n == 2 then
    k2_held = z == 1
    if z == 1 then
      -- play/stop on all pages
      if playing then stop_sequence() else start_sequence() end
    end
  elseif n == 3 then
    if z == 1 then
      k3_press_time = util.time()
      if k2_held then
        -- K2+K3: toggle drift + react
        drift_mode = not drift_mode
        react_mode = drift_mode
      end
    elseif z == 0 and not k2_held then
      -- K3 release: check hold vs tap
      local held = (util.time() - k3_press_time) >= K3_HOLD_TIME

      if page == 1 then
        if held then
          -- HOLD: regenerate ALL patterns
          for i = 1, NUM_VOICES do generate_pattern(i) end
          gen_flash = 12
        else
          -- TAP: generate selected track only
          generate_pattern(selected_track)
          gen_flash = 8
        end
      elseif page == 2 then
        if held then
          -- HOLD: toggle all mutes
          local any_muted = false
          for i = 1, NUM_VOICES do if mutes[i] then any_muted = true end end
          for i = 1, NUM_VOICES do
            mutes[i] = not any_muted
            params:set("v" .. i .. "_mute", mutes[i] and 2 or 1, true)
          end
        else
          -- TAP: toggle mute for selected track
          mutes[selected_track] = not mutes[selected_track]
          params:set("v" .. selected_track .. "_mute", mutes[selected_track] and 2 or 1, true)
        end
      elseif page == 3 then
        -- cycle timbre engineer style
        timbre.style = (timbre.style + 1) % (#TIMBRE_STYLES)
        params:set("timbre_style", timbre.style + 1, true)
      elseif page == 4 then
        -- cycle: off > major > minor > dim > off
        if not harmony.chord_mode then
          harmony.chord_mode = true; harmony.chord_type = 1
        elseif harmony.chord_type < 3 then
          harmony.chord_type = harmony.chord_type + 1
        else
          harmony.chord_mode = false
        end
        params:set("chord_mode", harmony.chord_mode and 2 or 1, true)
        params:set("chord_type", harmony.chord_type, true)
      end
    end
  end
  screen_dirty = true; grid_dirty = true
end

-- ============ GRID ============

-- grid layout (128 = 16x8):
--   rows 1-6: step sequencer (x=step, y=voice)
--     brightness: 0=off, velocity-scaled=active, 15=playing now
--     hold step + E3 = adjust velocity
--   row 7: col1-6=track select, col7-12=mute toggle, col13=copy, col14=paste
--           col15=generate, col16=clear
--   row 8: col1=play/stop, col2=drift, col3=react
--           col5-8=pattern page (future), col13-16=fx type quick-select

function grid_redraw()
  if not grid_connected then return end
  g:all(0)

  -- rows 1-6: sequencer
  for t = 1, NUM_VOICES do
    for s = 1, NUM_STEPS do
      if seq[t].pattern[s] == 1 then
        if s == step and playing and not mutes[t] then
          g:led(s, t, 15) -- playhead on active step
        elseif mutes[t] then
          g:led(s, t, 3)  -- muted: dim
        else
          -- brightness from velocity (4-12 range)
          local vel_bright = math.floor(seq[t].vel[s] * 8) + 4
          -- dim slightly if low probability
          if seq[t].prob[s] < 70 then vel_bright = math.max(3, vel_bright - 2) end
          g:led(s, t, vel_bright)
        end
      else
        if s == step and playing then
          g:led(s, t, 3) -- playhead on empty step
        else
          g:led(s, t, 0)
        end
      end
    end

    -- trigger flash overlay (decays)
    if flash[t] > 0 then
      if playing and step >= 1 and step <= 16 then
        local current_bright = g.rows and 15 or 15
        g:led(step, t, 15)
      end
      flash[t] = flash[t] - 1
    end
  end

  -- row 7: track select (1-6) + mute (7-12) + copy/paste/gen/clear
  for t = 1, NUM_VOICES do
    -- track select
    g:led(t, 7, t == selected_track and 15 or 4)
    -- mute toggle
    g:led(t + 6, 7, mutes[t] and 15 or 3)
  end
  g:led(13, 7, clipboard and 8 or 3)  -- copy (bright if clipboard full)
  g:led(14, 7, clipboard and 10 or 2) -- paste
  g:led(15, 7, 6)                      -- generate
  g:led(16, 7, 4)                      -- clear

  -- row 8: transport + modes + status
  g:led(1, 8, playing and 15 or 4)     -- play/stop
  g:led(2, 8, drift_mode and 12 or 3)  -- drift
  g:led(3, 8, react_mode and 12 or 3)  -- react

  -- euclidean pulse count indicator for selected track (cols 5-12)
  local ek = seq[selected_track].euclid_k
  for c = 5, 12 do
    local pulse_idx = c - 4
    g:led(c, 8, pulse_idx <= ek and 8 or 2)
  end

  -- chord mode indicators (cols 14-16)
  g:led(14, 8, harmony.chord_mode and (harmony.chord_type == 1 and 12 or 4) or 2) -- major
  g:led(15, 8, harmony.chord_mode and (harmony.chord_type == 2 and 12 or 4) or 2) -- minor
  g:led(16, 8, harmony.chord_mode and (harmony.chord_type == 3 and 12 or 4) or 2) -- dim

  g:refresh()
end

g.key = function(x, y, z)
  grid_connected = true

  if z == 1 then
    -- record press
    grid_held[x .. "," .. y] = {x = x, y = y, time = util.time()}
  else
    -- release
    local key = x .. "," .. y
    local held = grid_held[key]
    grid_held[key] = nil

    -- detect short press vs hold (hold = >0.3s for velocity already handled by E3)
    if not held then return end
  end

  -- rows 1-6: step toggle (on press)
  if y >= 1 and y <= 6 and x >= 1 and x <= 16 then
    if z == 1 then
      local t = y
      selected_track = t

      -- check if this is a velocity edit hold (handled in enc)
      -- for now just toggle on short press
      local was_on = seq[t].pattern[x] == 1
      seq[t].pattern[x] = was_on and 0 or 1

      -- if turning on, initialize velocity
      if not was_on then
        seq[t].vel[x] = 0.8
        seq[t].prob[x] = 100
      end

      -- reset euclidean since manual edit
      seq[t].euclid_k = 0
      params:set("v" .. t .. "_euclid", 0, true)
    end

  -- row 7: track select + mute + clipboard + generate
  elseif y == 7 and z == 1 then
    if x >= 1 and x <= 6 then
      selected_track = x
    elseif x >= 7 and x <= 12 then
      local t = x - 6
      mutes[t] = not mutes[t]
      params:set("v" .. t .. "_mute", mutes[t] and 2 or 1, true)
    elseif x == 13 then
      copy_pattern(selected_track)
    elseif x == 14 then
      paste_pattern(selected_track)
    elseif x == 15 then
      generate_pattern(selected_track)
    elseif x == 16 then
      -- clear selected track
      for s = 1, NUM_STEPS do
        seq[selected_track].pattern[s] = 0
      end
      seq[selected_track].euclid_k = 0
    end

  -- row 8: transport + modes + euclidean + chords
  elseif y == 8 and z == 1 then
    if x == 1 then
      if playing then stop_sequence() else start_sequence() end
    elseif x == 2 then
      drift_mode = not drift_mode
    elseif x == 3 then
      react_mode = not react_mode
    elseif x >= 5 and x <= 12 then
      -- set euclidean pulses for selected track
      local pulses = x - 4
      -- toggle: if already at this value, turn off
      if seq[selected_track].euclid_k == pulses then
        seq[selected_track].euclid_k = 0
        params:set("v" .. selected_track .. "_euclid", 0, true)
        -- keep current pattern
      else
        seq[selected_track].euclid_k = pulses
        params:set("v" .. selected_track .. "_euclid", pulses, true)
        apply_euclidean(selected_track)
      end
    elseif x == 14 then
      -- major chord
      harmony.chord_mode = true; harmony.chord_type = 1
      params:set("chord_mode", 2, true)
      params:set("chord_type", 1, true)
    elseif x == 15 then
      -- minor chord
      harmony.chord_mode = true; harmony.chord_type = 2
      params:set("chord_mode", 2, true)
      params:set("chord_type", 2, true)
    elseif x == 16 then
      -- dim / toggle chord off
      if harmony.chord_mode and harmony.chord_type == 3 then
        harmony.chord_mode = false
        params:set("chord_mode", 1, true)
      else
        harmony.chord_mode = true; harmony.chord_type = 3
        params:set("chord_mode", 2, true)
        params:set("chord_type", 3, true)
      end
    end
  end

  screen_dirty = true
  grid_dirty = true
end

-- ============ INIT ============

function init()
  init_voice_presets()
  build_params()
  midi_out = midi.connect(params:get("midi_device"))

  -- OP-XY
  if params:get("opxy_enabled") == 2 then
    opxy_out = midi.connect(params:get("opxy_device"))
  end

  -- MIDI in
  midi_in_device = midi.connect(params:get("midi_in_device"))
  midi_in_device.event = midi_event

  -- screen refresh (dirty-flag driven)
  local screen_metro = metro.init()
  screen_metro.event = function()
    for t = 1, NUM_VOICES do
      if flash[t] > 0 then flash[t] = flash[t] - 1; screen_dirty = true end
    end
    if screen_dirty then
      screen_dirty = false
      redraw()
    end
  end
  screen_metro.time = 1/15
  screen_metro:start()

  -- grid refresh (dirty-flag driven)
  local grid_metro = metro.init()
  grid_metro.event = function()
    if grid_dirty then
      grid_dirty = false
      grid_redraw()
    end
  end
  grid_metro.time = 1/10
  grid_metro:start()

  -- softcut looper
  softcut_init()

  grid_connected = g.device ~= nil

  -- initial patterns
  seq[1].pattern = {1,0,0,0, 1,0,0,0, 1,0,0,0, 1,0,0,0}
  seq[2].pattern = {0,0,0,0, 1,0,0,0, 0,0,0,0, 1,0,0,0}
  seq[3].euclid_k = 5; apply_euclidean(3)
  seq[4].euclid_k = 3; apply_euclidean(4)
  seq[5].pattern = {1,0,0,0, 0,0,0,0, 0,0,1,0, 0,0,0,0}
  seq[6].euclid_k = 2; apply_euclidean(6)

  params:bang()
  screen_dirty = true; grid_dirty = true
end

function cleanup()
  stop_sequence()
  sc_stop_record()
  sc_stop_playback()
  if midi_out then
    for ch = 1, 16 do midi_out:cc(123, 0, ch) end
  end
  if opxy_out then
    for ch = 1, 16 do opxy_out:cc(123, 0, ch) end
  end
end
