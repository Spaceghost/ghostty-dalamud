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

-- Poses to hold while a terminal is out. `timeline` is the looping base
-- ActionTimeline of the emote (Emote sheet, ActionTimeline[0]).
local PRESETS = {
  { name = 'device',     timeline = 6302, label = 'Glowing device (/tomestone)' },
  { name = 'book',       timeline = 7357, label = 'Reading a book (/read)' },
  { name = 'pen',        timeline = 8144, label = 'Pen and paper (/pen)' },
  { name = 'photograph', timeline = 8151, label = 'Camera (/photograph)' },
  { name = 'think',      timeline = 736,  label = 'Thinking (/think)' },
  { name = 'lookout',    timeline = 713,  label = 'Lookout (/lookout)' },
}

local M = {
  enabled = true,
  preset = 'device',      -- one of the preset names above
  custom_timeline = 0,    -- any ActionTimeline id; overrides the preset when > 0
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
}

M.presets = PRESETS

function M.preset_names()
  local names = {}
  for i, p in ipairs(PRESETS) do names[i] = p.name end
  return names
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
  if base == M.timeline() then return true end
  for _, p in ipairs(PRESETS) do
    if base == p.timeline then return true end
  end
  return false
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
  if mode and not saved and (ours(mode, base) or mode == ANIM_LOCK) then
    ghostty.log('animation: clearing a leftover device pose (mode ' .. mode .. ')')
    ghostty.anim_set(NORMAL, 0, 0, true)
    ghostty.anim_play(M.idle_timeline)
    mode, param, base = NORMAL, 0, 0
  end
  if not M.enabled then return end
  if visible then
    if saved or not mode then return end -- already out / no character (title screen, zoning)
    saved = { mode, param, base }
    energy = 0
    applied_speed = nil
    if M.lock_movement then
      ghostty.anim_set(ANIM_LOCK, 0, M.timeline(), true)
    else
      ghostty.anim_set(KEEP, 0, M.timeline(), false)
    end
    ghostty.anim_play(M.timeline())
  elseif saved then
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

function M.on_key(t)
  if not M.enabled or not saved then return end
  energy = math.min(1, energy + M.energy_per_key)
end

function M.on_frame(t)
  if not M.enabled or not saved then last_t = t return end
  local dt = last_t and math.max(0, math.min(t - last_t, 0.1)) or 0
  last_t = t
  energy = math.max(0, energy - dt * M.energy_decay)
  set_speed(M.idle_speed + (M.typing_speed - M.idle_speed) * energy)

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

  if t >= next_guard then
    next_guard = t + M.guard_interval
    local mode, param, base, playing = ghostty.anim_state()
    if mode and (base ~= M.timeline() or (playing and playing ~= 0 and playing ~= M.timeline())) then
      -- something replaced the pose (idle variation, emote): put the device back
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
