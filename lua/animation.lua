-- Character animation tied to the terminal (client-side only: nobody else
-- sees it, the same technique posing plugins use).
--
-- Showing a terminal pulls out the tablet (/tomestone pose); hiding every
-- terminal puts it away. While it is out, keystrokes sent to the shell make
-- the character tap on the tablet: the pose switches to a tap timeline for a
-- moment and back.
--
--   ghostty.anim_state()                 -> mode, mode_param, base_override
--   ghostty.anim_set(mode, param, base, use_set_mode)
--   ghostty.anim_play(action_timeline_id)
--   ghostty.log(message)
--
-- Timeline ids are ActionTimeline rows. A Penumbra mod can reskin the
-- tomestone prop into a real deck.
--
-- `style = 'desk'` sits the character at a desk instead (lua/desk.lua);
-- a character that cannot sit down there (already seated, mounted, in
-- combat) holds the device as usual.
--
-- Reactions: short timelines played over the hold when something happens in
-- a terminal (the core reports it through on_event): a bell, a command
-- failing or finishing after a long run, output after a quiet spell, and a
-- fidget after a long time without typing. Each plays once and the hold
-- comes straight back.

local desk = require('desk')

-- Poses to hold while a terminal is out. `timeline` is the looping base
-- ActionTimeline of the emote (Emote sheet, ActionTimeline[0]).
-- `seated` holds the emote's variants for a character that is already
-- sitting, by sit kind, as the Emote sheet has them: ActionTimeline[2] is
-- the ground-sit variant, [3] the chair one, [4] the upper-body one (played
-- over anything else: lying in a bed, a looping emote). They play over the
-- sit instead of replacing it, so the character keeps sitting. Presets
-- without one leave a seated character alone.
local PRESETS = {
  { name = 'device',     timeline = 6302, label = 'Glowing device (/tomestone)',
    seated = { ground = 6303, chair = 6303, upper = 6303 } },  -- emote_sp/u_sp16 for every sit
  { name = 'book',       timeline = 7357, label = 'Reading a book (/read)',
    seated = { ground = 7359, chair = 7358, upper = 7359 } },  -- u_sp23; s_sp23 on a chair
  { name = 'pen',        timeline = 8144, label = 'Pen and paper (/pen)' }, -- the sheet has no seated /pen
  { name = 'photograph', timeline = 8151, label = 'Camera (/photograph)',
    seated = { ground = 8152, chair = 8152, upper = 8152 } },  -- emote_sp/u_sp69
  { name = 'think',      timeline = 736,  label = 'Thinking (/think)',
    seated = { ground = 589, chair = 589, upper = 589 } },     -- emote/u_think
  { name = 'lookout',    timeline = 713,  label = 'Lookout (/lookout)',
    seated = { ground = 665, chair = 665, upper = 665 } },     -- emote/add_lookout
}

local M = {
  enabled = true,
  preset = 'device',      -- one of the preset names above
  custom_timeline = 0,    -- any ActionTimeline id; overrides the preset when > 0
  -- with custom_timeline: its seated variant, one id for every sit or
  -- { ground = id, chair = id, upper = id }; 0 leaves a seated character alone
  custom_seated = 0,
  idle_timeline = 3,      -- played when putting the pose away
  -- Typing: the pose loop plays faster while you type and settles when you
  -- stop, so the hands work in time with your keystrokes.
  idle_speed = 1.0,
  typing_speed = 2.6,     -- loop speed at full typing energy
  energy_per_key = 0.35,  -- each keystroke adds this much energy (capped at 1)
  energy_decay = 2.2,     -- energy lost per second
  -- Keep the pose: the game's idle system sometimes swaps the base pose;
  -- check this often (seconds) and put it back immediately.
  guard_interval = 0.1,
  -- AnimLock (what posing tools use) freezes movement; leave it off so you can
  -- walk with the pose held.
  lock_movement = false,
  -- 'phone' holds the device (standing or seated); 'desk' sits the
  -- character at a desk (lua/desk.lua, CONFIG.animation.desk).
  style = 'phone',
  reactions = true,
  seed = 0,               -- reactions' random draws: 0 seeds from the clock
}

M.desk = desk

-- Reactions by event. Prefer additive (emote/add_*) and facial timelines:
-- they layer over the hold, standing or seated, so the device stays in the
-- hands. `duration` is how long one plays before the hold comes back;
-- `face` resets the face (facial/pose/base) afterwards. `cooldown` keeps a
-- kind from repeating; `gap` spaces any two reactions.
M.reaction_table = {
  bell = { cooldown = 4,        -- a quick look up
    { id = 665, weight = 3, duration = 1.6 },              -- emote/add_lookout
    { id = 618, weight = 2, duration = 1.4, face = true }, -- facial/pose/surprised
  },
  failed = { cooldown = 5,      -- a head shake, a sigh, a curse
    { id = 666, weight = 3, duration = 1.8 },              -- emote/add_no
    { id = 670, weight = 2, duration = 2.2 },              -- emote/add_upset
    { id = 668, weight = 1, duration = 2.2 },              -- emote/add_orz
    { id = 664, weight = 1, duration = 1.8 },              -- emote/add_angry_st
  },
  success = { cooldown = 5, min_seconds = 10,  -- a satisfied nod after a long run
    { id = 671, weight = 3, duration = 1.6 },              -- emote/add_yes
    { id = 6216, weight = 2, duration = 1.8, face = true },-- facial/pose/satisfied
  },
  glance = { cooldown = 20, quiet = 5, typing_quiet = 3, min_bytes = 64,  -- output after a quiet spell
    { id = 665, weight = 2, duration = 1.2 },              -- emote/add_lookout
    { id = 669, weight = 1, duration = 1.6 },              -- emote/add_think
  },
  fidget = { after_min = 30, after_max = 90,   -- a long time without typing
    { id = 669, weight = 2, duration = 2.0 },              -- emote/add_think
    { id = 625, weight = 1, duration = 1.6, face = true }, -- facial/pose/f_puzzled
    { id = 667, weight = 1, duration = 1.6 },              -- emote/add_no_st (a small head roll)
  },
}
M.reaction_gap = 1.5
M.face_reset = 604        -- facial/pose/base

M.presets = PRESETS

function M.preset_names()
  local names = {}
  for i, p in ipairs(PRESETS) do names[i] = p.name end
  return names
end

-- Sitting (Character.Mode): the game holds a sit as InPositionLoop (11) with
-- ModeParam its EmoteMode row, and looping emotes (dances, poses) as
-- EmoteLoop (3). Replacing the base pose would stand the character up and
-- the game would sit it down again, so a seated variant plays over it.
local EMOTE_LOOP, IN_POSITION_LOOP = 3, 11
-- The EmoteMode rows whose ConditionMode is InPositionLoop: 1 /groundsit
-- (Emote 52), 2 /sit on a chair (Emote 50), 3 lying in a bed (Emote 88).
-- /doze is no mode of its own: it keeps the sit it is done in.
local SIT_KINDS = { [1] = 'ground', [2] = 'chair', [3] = 'bed' }
local function seated_mode(mode) return mode == EMOTE_LOOP or mode == IN_POSITION_LOOP end

-- 'ground' | 'chair' | 'bed' | 'loop' | 'upper' (an unknown sit) for a
-- seated (mode, param); nil when standing.
function M.sit_kind(mode, param)
  if mode == IN_POSITION_LOOP then return SIT_KINDS[param] or 'upper' end
  if mode == EMOTE_LOOP then return 'loop' end
  return nil
end

-- One variant from a preset's `seated`: a number is every sit's; ground and
-- chair have their own, the rest take the upper-body one.
local function pick(seated, kind)
  if type(seated) == 'number' then return seated end
  if type(seated) ~= 'table' then return 0 end
  local id = seated[kind]
  if id == nil and kind ~= 'ground' and kind ~= 'chair' then id = seated.upper end
  return math.floor(tonumber(id) or 0)
end

-- The seated variant of the current preset for a sit kind (M.sit_kind's
-- names) or a seated (mode, param); 0: none. Without either: the chair's.
function M.seated_timeline(mode, param)
  local kind = mode
  if type(mode) == 'number' then kind = M.sit_kind(mode, param) end
  kind = kind or 'chair'
  if (M.custom_timeline or 0) > 0 then return pick(M.custom_seated, kind) end
  for _, p in ipairs(PRESETS) do
    if p.name == M.preset then return pick(p.seated, kind) end
  end
  return pick(PRESETS[1].seated, kind)
end

-- The timeline to hold right now (preset, or the custom id).
function M.timeline()
  if (M.custom_timeline or 0) > 0 then return M.custom_timeline end
  for _, p in ipairs(PRESETS) do
    if p.name == M.preset then return p.timeline end
  end
  return PRESETS[1].timeline
end

-- Legacy field kept in sync for older configs that read it.
M.deck_timeline = PRESETS[1].timeline

local ANIM_LOCK = 8       -- CharacterModes.AnimLock
local NORMAL = 1          -- CharacterModes.Normal
local KEEP = 255          -- shim: leave the mode untouched, change only the pose

local saved = nil         -- { mode, param, base } from before the device came out
local reaction = nil      -- the reaction playing: { until_t, face }
local cool = {}           -- reaction kind -> time it may play again
local gap_until = 0
local last_key_t = 0
local last_output_t = nil
local next_fidget = nil
local rng = nil
local energy = 0
local last_t = nil
local next_guard = 0
local applied_speed = nil
local last_x, last_z = nil, nil -- the character last frame (two numbers: no table a frame)
local player_buf = {} -- ghostty.player fills this one every frame

-- A reload while the device was out leaves the character in our pose; never
-- treat that as the state to restore, and clear it so movement works.
local function ours(mode, base)
  if mode ~= ANIM_LOCK and mode ~= NORMAL then return false end
  if base == M.timeline() or desk.owns(base) then return true end
  for _, p in ipairs(PRESETS) do
    if base == p.timeline then return true end
  end
  return false
end

-- The device comes out over a sit: the variant for this sit kind (none: the
-- character is left sitting as it is).
local function sit_down(mode, param)
  saved.seated = M.sit_kind(mode, param) or 'chair'
  local st = M.seated_timeline(saved.seated)
  saved.seated_tl = st
  if st > 0 then ghostty.anim_play(st) end
end

local function set_speed(v)
  if applied_speed and math.abs(applied_speed - v) < 0.02 then return end
  applied_speed = v
  ghostty.anim_speed(0, v)
end

-- The first versions used AnimLock and restored the mode by writing the field
-- directly, which leaves the game believing the character is "operating a
-- siege machine" (no movement, most commands refused). Going through the
-- game's SetMode(Normal) clears that; do it once per load.
local MARKER = (GHOSTTY_PLUGIN_DIR or '.') .. '/animation-reset-done'
local normalized = io.open(MARKER, 'r') ~= nil -- only ever once (it would dismount / cancel an emote)

function M.on_toggle(visible)
  if not normalized then
    local m0 = ghostty.anim_state()
    if m0 then
      normalized = true
      local f = io.open(MARKER, 'w')
      if f then f:write('SetMode(Normal) applied once to clear the AnimLock siege-machine state\n') f:close() end
      ghostty.log('animation: resetting the character through SetMode(Normal) (was mode ' .. m0 .. ')')
      ghostty.anim_set(NORMAL, 0, 0, true)
      ghostty.anim_play(M.idle_timeline)
    end
  end
  local mode, param, base = ghostty.anim_state()
  ghostty.log(string.format('animation: visible=%s enabled=%s mode=%s param=%s base_override=%s',
    tostring(visible), tostring(M.enabled), tostring(mode), tostring(param), tostring(base)))
  if mode and not saved and not desk.active() and (ours(mode, base) or mode == ANIM_LOCK) then
    ghostty.log('animation: clearing a leftover device pose (mode ' .. mode .. ')')
    ghostty.anim_set(NORMAL, 0, 0, true)
    ghostty.anim_play(M.idle_timeline)
    mode, param, base = NORMAL, 0, 0
  end
  if not M.enabled then return end
  if visible then
    if saved or desk.active() or not mode then return end -- already out / no character (title screen, zoning)
    energy = 0
    applied_speed = nil
    reaction, next_fidget = nil, nil
    if M.style == 'desk' and desk.start(M, ghostty.player(player_buf), mode, base, last_t) then return end
    saved = { mode, param, base }
    if seated_mode(mode) then
      -- over the sit, not instead of it (the character stays seated)
      sit_down(mode, param)
      return
    end
    if M.lock_movement then
      ghostty.anim_set(ANIM_LOCK, 0, M.timeline(), true)
    else
      ghostty.anim_set(KEEP, 0, M.timeline(), false)
    end
    ghostty.anim_play(M.timeline())
  elseif desk.active() then
    set_speed(1.0)
    reaction = nil
    desk.stop(M, 'terminal put away')
  elseif saved and saved.seated then
    reaction = nil
    set_speed(1.0)
    local seated_mode_now, seated_param = ghostty.anim_state()
    saved = nil
    -- put the device away: the game's own SetMode replays the sit loop
    if seated_mode_now and seated_mode(seated_mode_now) then ghostty.anim_set(seated_mode_now, seated_param, 0, true) end
  elseif saved then
    reaction = nil
    set_speed(1.0)
    if M.lock_movement then
      ghostty.anim_set(saved[1], saved[2], saved[3], true)
    else
      ghostty.anim_set(KEEP, 0, ours(NORMAL, saved[3]) and 0 or saved[3], false)
    end
    saved = nil
    ghostty.anim_play(M.idle_timeline)
  end
end

-- Reactions --------------------------------------------------------------------

local function draw()
  if not rng then
    local seed = (M.seed and M.seed ~= 0) and M.seed or math.floor((os.time() + os.clock() * 1000) % 2147483647)
    rng = desk.rng(seed)
  end
  return rng()
end

-- Start over with a seed (tests; 0 = the clock), forgetting cooldowns.
function M.reseed(seed)
  M.seed = seed or 0
  rng, reaction, cool, gap_until, next_fidget, last_output_t = nil, nil, {}, 0, nil, nil
end

-- The pose a reaction returns to.
local function hold_timeline()
  if desk.active() then return desk.hold() end
  if saved and saved.seated then return M.seated_timeline(saved.seated) end
  return M.timeline()
end

function M.reacting() return reaction ~= nil end

-- Play a reaction of `kind` (a M.reaction_table key) at time t, unless one
-- is playing, it is too soon, or nothing is out. Returns the timeline id.
function M.react(kind, t)
  if not M.enabled or not M.reactions or not (saved or desk.active()) then return nil end
  if reaction or t < gap_until or t < (cool[kind] or 0) then return nil end
  local R = M.reaction_table[kind]
  if not R or #R == 0 then return nil end
  local e = R[desk.pick(R, draw())]
  if not e or not e.id or e.id <= 0 then return nil end
  ghostty.anim_play(e.id)
  reaction = { until_t = t + (e.duration or 1.5), face = e.face, id = e.id, kind = kind }
  cool[kind] = t + (R.cooldown or 0)
  return e.id
end

local function schedule_fidget(t)
  local F = M.reaction_table.fidget or {}
  local lo, hi = F.after_min or 30, F.after_max or 90
  next_fidget = t + lo + draw() * math.max(0, hi - lo)
end

-- The reaction's time is up: straight back to the hold. Fidgets are due a
-- while after the last keystroke.
local function reactions_tick(t)
  if reaction and t >= reaction.until_t then
    local tl = hold_timeline()
    if tl and tl > 0 then ghostty.anim_play(tl) end
    if reaction.face and (M.face_reset or 0) > 0 then ghostty.anim_play(M.face_reset) end
    reaction = nil
    gap_until = t + (M.reaction_gap or 0)
  end
  if not next_fidget then schedule_fidget(t) end
  if t >= next_fidget then
    M.react('fidget', t)
    schedule_fidget(t)
  end
end

-- Something happened in a terminal (core/app/reactions.nelua):
--   'bell'               a BEL
--   'done', exit, secs   a command finished (OSC 133;D), secs = -1 unknown
--   'output', bytes      output arrived this frame
function M.on_event(kind, t, a, b)
  local R = M.reaction_table
  if kind == 'output' then
    local g = R.glance or {}
    local quiet = last_output_t == nil or t - last_output_t >= (g.quiet or 5)
    last_output_t = t
    if quiet and (a or 0) >= (g.min_bytes or 1) and t - last_key_t >= (g.typing_quiet or 3) then
      M.react('glance', t)
    end
  elseif kind == 'bell' then
    M.react('bell', t)
  elseif kind == 'done' then
    if (a or 0) ~= 0 then
      M.react('failed', t)
    elseif (b or -1) >= ((R.success or {}).min_seconds or 10) then
      M.react('success', t)
    end
  end
end

function M.on_key(t)
  last_key_t = t or last_key_t
  if next_fidget then schedule_fidget(last_key_t) end
  if not M.enabled or not (saved or desk.active()) then return end
  energy = math.min(1, energy + M.energy_per_key)
end

function M.on_frame(t)
  if not M.enabled or not (saved or desk.active()) then last_t = t return end
  local dt = last_t and math.max(0, math.min(t - last_t, 0.1)) or 0
  last_t = t
  energy = math.max(0, energy - dt * M.energy_decay)
  local typed = M.idle_speed + (M.typing_speed - M.idle_speed) * energy
  reactions_tick(t)

  if desk.active() then
    -- the hands type in time with you while working; other moods keep their pace
    set_speed(desk.typing() and typed or M.idle_speed)
    if not desk.frame(M, t, ghostty.player(player_buf), reaction ~= nil) then
      reaction = nil
      set_speed(1.0)
    end
    return
  end
  set_speed(typed)

  -- where is the character: the guard must not fight walking/running poses
  local p = ghostty.player(player_buf)
  local moving = false
  if p then
    if last_x and dt > 0 then
      moving = math.sqrt((p.x - last_x) ^ 2 + (p.z - last_z) ^ 2) / dt > 0.3
    end
    last_x, last_z = p.x, p.z
  end
  if moving then next_guard = t + 0.5 end
  if reaction then return end -- playing over the hold: leave it be until it ends

  if t >= next_guard then
    next_guard = t + M.guard_interval
    local mode, param, base, playing = ghostty.anim_state()
    if not mode then return end
    if saved.seated then
      if not seated_mode(mode) then
        -- stood up while the device was out: hold it the standing way
        saved = { mode, param, 0 }
        ghostty.anim_set(KEEP, 0, M.timeline(), false)
        ghostty.anim_play(M.timeline())
        return
      end
      -- Most seated variants are upper-body (u_) timelines, which play in a
      -- slot of their own while the state reports the base slot (the sit
      -- loop): replaying whenever those differed restarted the variant every
      -- guard tick, before its prop could come out. It loops by itself, so
      -- it plays again only for another sit kind or preset. Should the base
      -- slot ever report the variant, it lives there: then restart it once
      -- something else has replaced it.
      local kind = M.sit_kind(mode, param)
      local st = saved.seated_tl or 0
      if st > 0 and playing == st then saved.in_base = true end
      if kind ~= saved.seated or M.seated_timeline(kind) ~= st or (saved.in_base and st > 0 and playing and playing ~= st) then sit_down(mode, param) end
      return
    end
    if seated_mode(mode) then
      -- sat down while the device was out: switch to the seated variant
      -- instead of standing the character back up
      ghostty.anim_set(KEEP, 0, 0, false)
      sit_down(mode, param)
      return
    end
    if base ~= M.timeline() then
      -- something replaced the base pose (idle variation, emote): put it back.
      -- The base loops by itself, so nothing is restarted while the base is
      -- still ours: restarting it is what made the device blink.
      if M.lock_movement then
        ghostty.anim_set(ANIM_LOCK, 0, M.timeline(), true)
      else
        ghostty.anim_set(KEEP, 0, M.timeline(), false)
      end
      ghostty.anim_play(M.timeline())
    end
  end
end

return M
