-- Rain on world panels: when it rains in the world, drops land on the glass of
-- the screens, grow, merge and trickle down, and a wiper behind the glass
-- sweeps them off. The core asks frame() once per frame and panel(id) per
-- world panel, and draws the rest (core/rain.nelua, core/app/rain.nelua).
--
-- /term rain on|off|auto: force it on or off (for testing and screenshots),
-- or follow the weather again.

local world = require('world')

local M = {
  enabled = true,
  mode = 'auto',            -- 'auto' follows the weather, 'on' always rains, 'off' never
  forced_intensity = 0.7,   -- how hard it rains with /term rain on
  max_drops = 90,           -- per panel at full intensity (the core holds at most 120)
  size_min = 2.5,           -- drop radius in panel pixels
  size_max = 7,
  trickle_speed = 70,       -- pixels per second a large drop runs down
  wiper_style = 'back',     -- 'back' (behind the glass), 'front', or 'none'
  wiper_period_light = 12,  -- seconds between sweeps in a drizzle ...
  wiper_period_heavy = 6,   -- ... and in heavier rain
  wiper_continuous_at = 0.85, -- intensity from which it sweeps without resting
  opacity = 0.85,
  fade = 3,                 -- seconds the rain takes to come and go on the glass
  -- drops that run off a panel's edge, or that the wiper flings off its tip,
  -- fall into the world and splash on the ground
  gravity = 12,             -- yalms/s^2
  fling_speed = 2.5,        -- yalms/s off the blade tip
  max_particles = 256,      -- falling at once, all panels together (the core holds at most 256)
}

-- Weather id (the game's Weather sheet) -> rain intensity 0..1. Anything not
-- listed counts as dry, unless the game's own rain amount says otherwise.
M.weather = {
  [7] = 0.55,   -- Rain
  [8] = 1.0,    -- Showers
  [9] = 0.35,   -- Thunder
  [10] = 0.9,   -- Thunderstorms
  -- zone variants with the same names (Weather sheet, checked through xiv-mcp)
  [62] = 0.55, [64] = 0.55,                          -- Rain
  [210] = 1.0,                                       -- Showers
  [57] = 0.35, [58] = 0.35, [88] = 0.35, [203] = 0.35, [204] = 0.35, -- Thunder
}

-- The rain intensity the weather gives: the listed weather or the game's rain
-- amount, whichever is more. Weather 0 is no weather at all (housing interiors,
-- instances without weather): dry.
function M.intensity()
  if not M.enabled or M.mode == 'off' then return 0 end
  if M.mode == 'on' then return math.max(0, math.min(1, M.forced_intensity or 0.7)) end
  if not (ghostty and ghostty.env) then return 0 end
  local _, rain, weather = ghostty.env()
  if not weather or weather == 0 then return 0 end
  local i = math.max(M.weather[weather] or 0, rain or 0)
  return math.max(0, math.min(1, i))
end

local frame = {}

-- Once per frame: the intensity and the tunables.
function M.frame()
  frame.intensity = M.intensity()
  frame.max_drops = M.max_drops
  frame.size_min = M.size_min
  frame.size_max = M.size_max
  frame.trickle_speed = M.trickle_speed
  frame.wiper = M.wiper_style
  frame.period_light = M.wiper_period_light
  frame.period_heavy = M.wiper_period_heavy
  frame.continuous_at = M.wiper_continuous_at
  frame.opacity = M.opacity
  frame.fade = M.fade
  frame.gravity = M.gravity
  frame.fling_speed = M.fling_speed
  frame.max_particles = M.max_particles
  return frame
end

-- Whether world panel `id` gets rain: not when docked on the HUD.
function M.panel(id)
  local a = world.anchors and world.anchors[id]
  return not (a and (a.kind == 'hud' or a.hud))
end

-- /term rain on|off|auto -> error text, or nil.
function M.command(args)
  local w = (args or ''):match('^%s*(%S*)')
  if w == 'on' or w == 'off' or w == 'auto' then
    M.mode = w
    if w ~= 'off' then M.enabled = true end
    return nil
  end
  return 'usage: /term rain on|off|auto (now ' .. tostring(M.mode) .. ')'
end

return M
