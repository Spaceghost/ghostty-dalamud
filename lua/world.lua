-- World-space terminals: where each pinned terminal sits in the game world.
--
-- The core calls place(id, t) every frame for each pinned terminal and draws
-- it as a flat panel at the returned position/orientation (nil hides it). It
-- calls command(id, args) for `/term pin ...`. Everything about placement lives
-- here, so new anchor kinds are plain Lua.
--
-- Game queries (nil when unavailable, e.g. on the title screen):
--   ghostty.player([t])      -> { x, y, z, rotation, entity_id, territory }
--                               (fills and returns table t when given one)
--   ghostty.target([t])      -> same shape, your current target
--   ghostty.object(entity_id)-> same shape, any loaded object
--   ghostty.zone()           -> territory id
--   ghostty.view([t])        -> { x, y, z, fx, fy, fz, rx, ry, rz, ux, uy, uz,
--                                 tan_x, tan_y, width, height, yaw, pitch }:
--                               the camera's position, forward, screen-right and
--                               screen-up, tangents of half its field of view,
--                               the view in pixels
-- Coordinates are yalms with +Y up; rotation is radians and a character faces
-- (sin r, 0, cos r). A panel's yaw is the direction its readable side faces.

local M = {}

-- Pet terminals: float around your character, trail after it on springs, and
-- face it with a gentle inward curve. The camera plays no part, so turning the
-- camera never moves them.
M.pet = {
  -- panel pixels are rendered with a 40 px font, then scaled into the world
  width = 1520, height = 880, pixels_per_yalm = 660,
  distance = 2.3,        -- yalms from the character
  height_above = 1.6,    -- panel centre above the character's feet
  side = 1.45,           -- radians from the character's heading to its side (pi/2 = square to the side)
  step = 0.55,           -- radians between pets stacked on the same side
  stiffness = 5.0,       -- spring stiffness: higher follows more tightly
  damping = 0.8,         -- 1 = settle with no overshoot; lower swings like a pendulum before settling
  walk_speed = 0.6,      -- yalms per second above which the character counts as moving
  bob = 0.025,            -- vertical bob in yalms
  drift = 0.0,           -- radians they wander (small, so a focused pet holds still)
  curve = 9.0,           -- curve radius in yalms (concave toward the character); larger = flatter, 0 = flat
  gap = 0.3,             -- minimum yalms between neighbouring pets
  turn_speed = 5.0,      -- radians per second the character turns to face a newly selected pet
}

-- Clicking a panel presents it: it floats part of the way toward you and turns
-- to face you, and floats back when focus leaves. Panels you can walk up to
-- float toward the spot where you will stand; the rest toward a point in front
-- of the camera. Never nearer than min_distance, never between the camera and
-- your character.
M.present = {
  -- Single click only focuses: the panel stays where it is, facing where it
  -- faces. Set true to float it toward you on click as well.
  enabled = false,
  -- Double-click flies the panel forward onto the screen; this is how much
  -- of the screen it fills (1 = edge to edge).
  full_screen = 0.62,
  fraction = 0.4,        -- of the way to the goal
  distance = 1.6,        -- goal in front of the camera (yalms)
  min_distance = 1.2,    -- never nearer the camera or where you stand (yalms)
  ease = 0.35,           -- seconds, critically damped
  curve_relax = 0.5,     -- curve radius grows by this much (flatter) while presented
  eye_height = 1.6,      -- goal height above your feet
  margin = 0.35,         -- yalms kept behind your character's body
}

-- Clicking a panel fixed in the world (or on another character) walks you up
-- to it by holding forward; any movement of yours, losing focus, combat, a
-- wall or the time limit stops it where you are.
M.walk = {
  enabled = true,
  approach_distance = 1.8, -- stop this far from the panel (yalms, horizontal)
  max_seconds = 3.0,
  turn_speed = 8.0,        -- radians per second while turning toward it
  stuck_seconds = 0.5,     -- no ground covered this long = blocked
}

-- Alt + left-drag picks a panel up and carries it at its distance from the
-- camera (walking or zooming carries it too, the wheel pushes it out or pulls
-- it in); letting go pins it there in the world, whatever it was before. Hold
-- Shift to land it flush on the wall, floor or table under the cursor, and
-- Ctrl as well to stretch it over that surface. Let it go at a side or corner
-- of the screen, or with Ctrl alone, and it docks to the screen instead (see
-- M.hud). The right button puts it back.
M.drag = {
  enabled = true,
  wheel_step = 0.35,     -- yalms per wheel notch (negative flips the direction)
  min_distance = 0.8,    -- from the camera (yalms)
  max_distance = 40,
  reach = 80,            -- how far Shift looks for a surface (yalms)
  offset = 0.02,         -- gap kept to the surface (yalms, about 2 cm)
  probe = 0.15,          -- spacing of the rays that measure the surface's slope (yalms)
  fit_max = 3.0,         -- stretch at most this far from the cursor each way (yalms)
  fit_step = 0.1,        -- resolution of the stretch search (yalms)
  fit_margin = 0.05,     -- kept clear of the surface's edges (yalms)
  fit_min = 0.4,         -- smaller than this either way: keep the panel's own size
  fit_tolerance = 0.05,  -- bumps lower than this still count as flat (yalms)
}

-- HUD panels (`/term pin hud`, or let a carried panel go at a side of the
-- screen): docked to a spot on the screen, but living in 3D just in front of
-- the camera, like Lakitu's cloud. When the camera turns the panel lags on a
-- spring, sliding back and twisting a little with the turn, then settles
-- where it was docked. It keeps a gentle bob. Always drawn in front of the
-- world, without the world's light.
M.hud = {
  distance = 1.6,     -- yalms in front of the camera (the panel keeps its screen size at any distance)
  stiffness = 14,     -- spring stiffness: higher follows the camera more tightly
  damping = 0.75,     -- 1 = settles with no overshoot; lower wobbles a little first
  tilt = 0.10,        -- radians the panel lags in facing per rad/s the camera turns
  roll = 0.06,        -- radians it banks per rad/s the camera turns sideways
  drag = 0.025,       -- screen fractions it slides back per rad/s the camera turns
  bob = 0.003,        -- idle bob, screen fractions
  bob_speed = 1.3,    -- radians per second
  max_tilt = 0.30,    -- radians, facing and bank alike: however fast the camera spins
  max_drag = 0.05,    -- screen fractions
  max_turn = 6,       -- camera turn rates above this (rad/s) count as this
  min_scale = 0.25,   -- screen pixels per panel pixel a docked panel keeps
  max_scale = 1.5,
  fill = 0.45,        -- a panel docked without a size to keep fills at most this much of the screen
  -- docking by dragging (Alt + drag): let go within `edge` pixels of a side or
  -- corner of the screen, or with Ctrl held, and it docks there
  dock = true,
  edge = 40,
  margin = 16,        -- pixels a docked panel keeps from the side it is docked to
}

M.defaults = {
  width = 1800,            -- terminal pixels (40 px font)
  height = 1040,
  pixels_per_yalm = 640,   -- 1800 px wide ~= 2.8 yalms
  opacity = 0.92,
}

-- What hides a panel where the game world is in front of it:
--   'depth'   the game's own depth buffer, per pixel: your character, other
--             characters, walls and props all cover the panel exactly
--   'capsule' a soft cut-out around your character only (the fallback when
--             the depth buffer cannot be used)
--   'off'     panels always draw on top
M.occlusion = 'depth'
M.occlusion_tolerance = 0.01  -- yalms a panel may sit behind a surface and still show (no flicker where they touch);
                              -- the depth test adds more with distance and at grazing angles
M.occlusion_edge = 1          -- pixels over which a covered edge blends (0 = hard, up to 3)

-- id -> anchor table
M.anchors = {}

local sin, cos, atan, pi = math.sin, math.cos, math.atan, math.pi

local function facing(rot) return sin(rot), cos(rot) end

local function yaw_towards(fx, fz, tx, tz)
  return atan(tx - fx, tz - fz)
end

local function words(s)
  local t = {}
  for w in s:gmatch('%S+') do t[#t + 1] = w end
  return t
end

-- Light ---------------------------------------------------------------------------
-- Panels take on the world's light: neutral by day, warm at dawn and dusk,
-- cool and dim at night, a little darker in rain. When the world is dim a
-- backlight glow comes on and lifts the panel so text stays readable.
M.light = {
  enabled = true,
  night = { 0.62, 0.70, 0.95 },   -- channel multipliers at night
  dusk = { 1.05, 0.86, 0.72 },    -- at sunrise/sunset
  day = { 1.0, 1.0, 1.0 },
  rain_dim = 0.12,                -- darkening at full rain
  backlight_below = 0.95,         -- brightness under which the backlight comes on
  -- a real game light in front of each panel, lighting your character and the world
  cast_light = true,
  light_intensity = 1.0,
  light_range = 6.0,              -- yalms
  light_by_day = 0.35,            -- share of the light cast in full daylight; the backlight adds the rest
  light_color = { 0.55, 0.72, 1.0 },
  light_color_from_tint = true,   -- warm at dusk, cool at night, like the panel itself
  shadows = false,                -- the light casts shadows (expensive)
}

-- Shadows (experimental, off by default): each shown panel gets a thin board
-- just behind it, a real scene object only you see, with no collision, so the
-- panel casts a shadow and blocks sunlight like furniture does. It relies on
-- a game function found by signature, so a game patch can break it; it has
-- not been tried in game yet. Seen from behind, the depth test likely lets the
-- board hide the panel.
M.shadows = {
  enabled = false,
  -- a flat model that faces +/-Z; its size in yalms at scale 1 and where its origin sits
  model = 'bgcommon/hou/indoor/general/0766/bgparts/fun_b0_m0766.mdl',
  model_width = 4,
  model_height = 3,
  model_origin = 0,     -- origin above the bottom edge, as a share of the height (0.5 = centred)
  offset = 0.05,        -- yalms behind the panel
  depth = 0.1,          -- thickness scale
  transparency = 0,     -- 0 fully drawn .. 1 invisible (what dithering does to shadows is unknown)
}

local function mix(a, b, t) return a + (b - a) * t end

function M.lighting()
  local cfg = M.light
  if not cfg.enabled then return 1, 1, 1, 0 end
  local day, rain = ghostty.env()
  if not day then return 1, 1, 1, 0 end
  local h = (day / 3600) % 24
  -- daylight 0..1 with soft ramps at 5-8 and 17-20
  local sun
  if h < 5 or h >= 20 then sun = 0
  elseif h < 8 then sun = (h - 5) / 3
  elseif h < 17 then sun = 1
  else sun = 1 - (h - 17) / 3 end
  local warm = 1 - math.abs(sun - 0.5) * 2 -- peaks mid-ramp
  local r = mix(cfg.night[1], cfg.day[1], sun)
  local g = mix(cfg.night[2], cfg.day[2], sun)
  local b = mix(cfg.night[3], cfg.day[3], sun)
  if warm > 0 then
    r, g, b = mix(r, cfg.dusk[1], warm * 0.6), mix(g, cfg.dusk[2], warm * 0.6), mix(b, cfg.dusk[3], warm * 0.6)
  end
  local dim = 1 - (rain or 0) * cfg.rain_dim
  r, g, b = r * dim, g * dim, b * dim
  local brightness = (r + g + b) / 3
  local backlight = math.max(0, math.min(1, (cfg.backlight_below - brightness) / 0.2))
  -- the backlight lifts the panel back toward its own colours
  r, g, b = mix(r, 1, backlight * 0.7), mix(g, 1, backlight * 0.7), mix(b, 1, backlight * 0.7)
  return r, g, b, backlight
end

-- M.lighting() once per frame time `t`, however many panels ask.
function M.lighting_at(t)
  if M._lt ~= t then
    M._lt = t
    M._lr, M._lg, M._lb, M._lbl = M.lighting()
  end
  return M._lr, M._lg, M._lb, M._lbl
end

local function lit(out, now)
  local r, g, b, bl = M.lighting_at(now)
  out.tint_r, out.tint_g, out.tint_b, out.backlight = r, g, b, bl
  local cfg = M.light
  if cfg.cast_light then
    local c = cfg.light_color
    out.light_r, out.light_g, out.light_b = c[1], c[2], c[3]
    if cfg.light_color_from_tint then out.light_r, out.light_g, out.light_b = c[1] * r, c[2] * g, c[3] * b end
    out.light_intensity = cfg.light_intensity * mix(cfg.light_by_day, 1, bl)
    out.light_range = cfg.light_range
    out.light_shadows = cfg.shadows
  else
    out.light_r, out.light_g, out.light_b, out.light_intensity, out.light_range, out.light_shadows = 0, 0, 0, 0, 0, false
  end
  return out
end

-- The placement table place() returns: one per anchor, rewritten every call
-- (all fields, so nothing stale is left), so placing makes no garbage. Table
-- fields are never saved (save_state keeps plain values only).
local function placement(a, x, y, z, yaw, pitch, width, height, ppy, opacity, curve, now)
  local out = a._out
  if not out then out = {} a._out = out end
  out.run_occluded = a.run_occluded or false
  out.pet = a.kind == 'pet'
  out.hud = false
  out.x, out.y, out.z, out.yaw, out.pitch, out.roll = x, y, z, yaw, pitch, 0
  out.width, out.height, out.pixels_per_yalm, out.opacity, out.curve = width, height, ppy, opacity, curve
  return lit(out, now)
end

local function result(a, x, y, z, yaw, now)
  return placement(a, x, y, z, yaw, a.pitch or 0,
    a.width or M.defaults.width, a.height or M.defaults.height,
    a.pixels_per_yalm or M.defaults.pixels_per_yalm, a.opacity or M.defaults.opacity, 0, now)
end

-- /term pin [here|me|target|orbit] [numbers...]
--   here            fixed in the world 2.5 yalms in front of you, facing you
--   me [fwd] [up]   follows you, in front of your character, turning with you
--   target [up]     follows your target, floating above it, facing you
--   orbit [r] [spd] circles you (radius yalms, radians per second)
--   pet             floats behind you facing the camera and trails after you
--   hud [X Y] [DIST] [SCALE]
--                   docked to the screen: its centre at X, Y (fractions of
--                   the screen, 0..1 from the top left; default where it
--                   shows now), DIST yalms in front of the camera (default
--                   M.hud.distance), SCALE screen pixels per panel pixel
--                   (default the size it shows at now)
--   toggle [x y z yaw [pitch]]
--                   a pet becomes a pin where it is (the pose the core drew it
--                   at, else where it was last placed, else as `here`); any
--                   other anchor becomes a pet. Its own size, opacity, hidden
--                   and run_occluded stay (the title button, /term pin toggle,
--                   IPC window.toggle_pet)
function M.command(id, args)
  M._pet_ids = nil -- pets may come, go, hide or show
  local a = words(args)
  local how = a[1] or 'here'
  if how == 'forget' then M.forget(id) return nil end
  if how == 'hide' then
    -- kept but not drawn (and out of the pet slots), e.g. during /term showcase
    local anchor = M.anchors[id]
    if not anchor then return 'not a world terminal' end
    anchor.hidden = a[2] ~= 'off' or nil
    return nil
  end
  if how == 'occluded' then
    local anchor = M.anchors[id]
    if not anchor then return 'not a world terminal' end
    anchor.run_occluded = (a[2] == 'on' or a[2] == 'true')
    return nil
  end
  if how == 'toggle' then return M.toggle(id, tonumber(a[2]), tonumber(a[3]), tonumber(a[4]), tonumber(a[5]), tonumber(a[6])) end
  if how == 'hud' then
    local x, y = tonumber(a[2]), tonumber(a[3])
    if (a[2] and not x) or (x and not y) then return 'usage: /term pin hud [X Y] [DIST] [SCALE]' end
    return M.dock(id, x, y, tonumber(a[5]), tonumber(a[4]), true)
  end
  local p = ghostty.player()
  if not p then return 'no player (log in first)' end
  if how == 'here' then
    local fx, fz = facing(p.rotation)
    M.anchors[id] = {
      kind = 'world', zone = p.territory,
      x = p.x + fx * 2.5, y = p.y + 1.7, z = p.z + fz * 2.5,
      yaw = p.rotation + pi,
    }
  elseif how == 'at' then
    -- at ANGLE DISTANCE HEIGHT: around where your character faces, turned toward it
    local ang = p.rotation + (tonumber(a[2]) or 0)
    local dist = tonumber(a[3]) or 3
    local x, z = p.x + sin(ang) * dist, p.z + cos(ang) * dist
    M.anchors[id] = { kind = 'world', zone = p.territory, x = x, y = p.y + (tonumber(a[4]) or 1.7), z = z, yaw = atan(p.x - x, p.z - z) }
  elseif how == 'me' then
    M.anchors[id] = { kind = 'follow', player = true, forward = tonumber(a[2]) or 2.0, up = tonumber(a[3]) or 1.7, turn = pi }
  elseif how == 'target' then
    local t = ghostty.target()
    if not t then return 'no target' end
    M.anchors[id] = { kind = 'follow', entity_id = t.entity_id, forward = 0, up = tonumber(a[2]) or 3.2, face_player = true }
  elseif how == 'pet' then
    M.anchors[id] = { kind = 'pet', phase = math.random() * 2 * pi, since = nil }
  elseif how == 'orbit' then
    M.anchors[id] = { kind = 'orbit', radius = tonumber(a[2]) or 3.5, speed = tonumber(a[3]) or 0.25, up = 1.8, phase = p.rotation }
  else
    return 'usage: /term pin [here|me|target|orbit|pet|hud] ...'
  end
  return nil
end

-- Fields a panel keeps when it turns from pin to pet and back: only those set
-- on it (a terminal takes the new kind's default size; a window panel keeps
-- the size lua/windows.lua gave it).
local KEEP = { 'width', 'height', 'pixels_per_yalm', 'opacity', 'run_occluded', 'hidden' }

-- Pin <-> pet at the panel's current pose (see `toggle` above).
function M.toggle(id, x, y, z, yaw, pitch)
  local old = M.anchors[id]
  if not old then return 'not a world terminal' end
  local a
  if old.kind == 'pet' then
    if not (x and y and z and yaw) and old._out then
      local o = old._out
      x, y, z, yaw, pitch = o.x, o.y, o.z, o.yaw, o.pitch
    end
    if x and y and z and yaw then
      local zone = ghostty.zone()
      if not zone then return 'no player (log in first)' end
      a = { kind = 'world', zone = zone, x = x, y = y, z = z, yaw = yaw, pitch = pitch or 0 }
    else
      -- never placed yet: in front of you, as `here`
      local err = M.command(id, 'here')
      if err then M.anchors[id] = old return err end
      a = M.anchors[id]
    end
  else
    a = { kind = 'pet', phase = math.random() * 2 * pi }
  end
  for _, k in ipairs(KEEP) do a[k] = old[k] end
  M.anchors[id] = a
  M._pet_ids = nil
  return nil
end

-- HUD docking --------------------------------------------------------------------

local function clamp(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end

-- Where a panel centred at (x, y, z), `ppy` pixels per yalm, shows in camera
-- view `v`: screen fractions and screen pixels per panel pixel (as
-- world_hud_spot in core/world.nelua); nil behind the camera.
local function hud_spot(v, x, y, z, ppy)
  local dx, dy, dz = x - v.x, y - v.y, z - v.z
  local depth = dx * v.fx + dy * v.fy + dz * v.fz
  if depth < 0.05 or not ppy or ppy <= 0 then return nil end
  local nx = (dx * v.rx + dy * v.ry + dz * v.rz) / (depth * v.tan_x)
  local ny = (dx * v.ux + dy * v.uy + dz * v.uz) / (depth * v.tan_y)
  return (nx + 1) / 2, (1 - ny) / 2, v.height / (2 * depth * v.tan_y * ppy)
end

-- Dock panel `id` to the screen as a HUD panel: centre at (x, y) in screen
-- fractions, `scale` screen pixels per panel pixel, `dist` yalms out. What is
-- not given comes from where and how big the panel shows now (else the
-- middle of the screen, at a size that fits). Also the core's drag-to-dock.
-- `new`: a terminal not in the world yet may be docked too (/term pin hud).
function M.dock(id, x, y, scale, dist, new)
  local old = M.anchors[id]
  if not old and not new then return 'not a world terminal' end
  old = old or {}
  local cfg = M.hud
  local v = ghostty.view and ghostty.view() or nil
  if (not x or not scale) and v and old._out and not old.hidden then
    local o = old._out
    local fx, fy, sc = hud_spot(v, o.x, o.y, o.z, o.pixels_per_yalm)
    if fx and (x or (fx > -0.05 and fx < 1.05 and fy > -0.05 and fy < 1.05)) then
      if not x then x, y = fx, fy end
      scale = scale or sc
    end
  end
  if not scale then
    local w, h = old.width or M.defaults.width, old.height or M.defaults.height
    scale = 1
    if v then scale = math.min(1, cfg.fill * v.width / w, cfg.fill * v.height / h) end
  end
  local a = {
    kind = 'hud', sx = clamp(x or 0.5, 0, 1), sy = clamp(y or 0.5, 0, 1),
    scale = clamp(scale, cfg.min_scale, cfg.max_scale),
    dist = dist and clamp(dist, 0.3, 20) or nil,
    phase = math.random() * 2 * pi,
  }
  for _, k in ipairs(KEEP) do a[k] = old[k] end
  M.anchors[id] = a
  M._pet_ids = nil
  return nil
end

-- Panel size limits in terminal pixels.
local MIN_W, MAX_W, MIN_H, MAX_H = 600, 5200, 320, 3600

-- Mouse-drag resize from the core (terminal pixels, centre-anchored).
function M.resize(id, w, h)
  local a = M.anchors[id]
  if not a then return end
  a.width = math.max(MIN_W, math.min(MAX_W, w))
  a.height = math.max(MIN_H, math.min(MAX_H, h))
end

-- A dragged panel let go (Alt + drag): pinned in the world, in this zone,
-- where and how it was dropped. p = { x, y, z, yaw, pitch, width, height,
-- pixels_per_yalm }, plus fit_width/fit_height in yalms when stretched over a
-- surface: the pixel density then changes so the text keeps a sane size.
function M.drop(id, p)
  local old = M.anchors[id]
  if not old then return 'not a world terminal' end
  local zone = ghostty.zone()
  if not zone then return 'no player (log in first)' end
  local a = {
    kind = 'world', zone = zone,
    x = p.x, y = p.y, z = p.z, yaw = p.yaw, pitch = p.pitch or 0,
    width = p.width, height = p.height, pixels_per_yalm = p.pixels_per_yalm,
    opacity = old.opacity, run_occluded = old.run_occluded,
  }
  if p.fit_width and p.fit_height and p.fit_width > 0 and p.fit_height > 0 then
    local lo = math.max(MIN_W / p.fit_width, MIN_H / p.fit_height)
    local hi = math.min(MAX_W / p.fit_width, MAX_H / p.fit_height)
    local ppm = math.max(lo, math.min(hi, a.pixels_per_yalm or M.defaults.pixels_per_yalm))
    a.pixels_per_yalm, a.width, a.height = ppm, p.fit_width * ppm, p.fit_height * ppm
  end
  a.width = math.max(MIN_W, math.min(MAX_W, a.width or M.defaults.width))
  a.height = math.max(MIN_H, math.min(MAX_H, a.height or M.defaults.height))
  M.anchors[id] = a
  M._pet_ids = nil -- a dropped pet is a pin now
  return nil
end

-- Persistence ---------------------------------------------------------------------
-- Anchors of live world terminals are saved keyed by agent session id, so a
-- reload (or game restart) reattaches them into the world, not the dropdown.

local TRANSIENT = { t = true, placed_at = true, px = true, pz = true }

local function state_path()
  return (GHOSTTY_PLUGIN_DIR or '.') .. '/world-state.lua'
end

function M.save_state(list)
  local out = { 'return {\n' }
  for _, e in ipairs(list) do
    local fields = { string.format('view = %q', e.view or 'tab'), string.format('font_scale = %s', tostring(e.font_scale or 0)) }
    local a = e.view == 'world' and M.anchors[e.id] or nil
    if a then
      for k, v in pairs(a) do
        local tv = type(v)
        if k ~= 'view' and k ~= 'font_scale' and not TRANSIENT[k] and not k:match('_v$') and (tv == 'number' or tv == 'string' or tv == 'boolean')
           -- a pet's spring state is recomputed around the character
           and not (a.kind == 'pet' and (k == 'x' or k == 'y' or k == 'z' or k == 'faced'))
           -- inf and nan would not load back
           and not (tv == 'number' and not (v == v and v ~= math.huge and v ~= -math.huge)) then
          fields[#fields + 1] = string.format('%s = %s', k, tv == 'string' and string.format('%q', v) or tostring(v))
        end
      end
    end
    table.sort(fields)
    out[#out + 1] = string.format('  [%d] = { %s },\n', e.agent, table.concat(fields, ', '))
  end
  out[#out + 1] = '}\n'
  local s = table.concat(out)
  if s == M._last_saved then return end -- unchanged: no write
  -- write beside it and swap, so a crash mid-write never leaves a truncated file
  local tmp = state_path() .. '.tmp'
  local f = io.open(tmp, 'w')
  if not f then return end
  local wok = f:write(s)
  local cok = f:close()
  -- a short write (disk full) must not replace the good file
  if not wok or not cok then os.remove(tmp) return end
  os.remove(state_path()) -- rename does not replace on Windows
  if os.rename(tmp, state_path()) then M._last_saved = s end
end

local saved_state = nil

-- -> view ('world' | 'window' | 'min' | 'tab'), font_scale; nil when unknown
function M.restore(id, agent)
  if saved_state == nil then
    local chunk = loadfile(state_path()) or loadfile(state_path() .. '.tmp') -- a swap cut short
    local ok, tbl = false, nil
    if chunk then ok, tbl = pcall(chunk) end
    saved_state = (ok and type(tbl) == 'table') and tbl or {}
  end
  local a = saved_state[agent]
  if not a then return nil end
  local view = a.view or (a.kind and 'world') or 'tab'
  if view == 'world' then
    local copy = {}
    for k, v in pairs(a) do if k ~= 'view' and k ~= 'font_scale' then copy[k] = v end end
    M.anchors[id] = copy
    M._pet_ids = nil
  end
  return view, a.font_scale or 0
end

function M.forget(id)
  M.anchors[id] = nil
  M._pet_ids = nil
end

-- Shown pets in id order, kept until an anchor comes, goes, hides or changes
-- kind (M.command, M.drop, M.restore, M.forget reset it).
local function pet_ids()
  local ids = M._pet_ids
  if ids then return ids end
  ids = {}
  for id, a in pairs(M.anchors) do
    if a.kind == 'pet' and not a.hidden then ids[#ids + 1] = id end
  end
  table.sort(ids)
  M._pet_ids = ids
  return ids
end

-- Shared per-frame character state: smoothed heading and whether it is moving.
local body = { t = nil, x = 0, z = 0, heading = 0, speed = 0 }

local function wrap(a) return (a + pi) % (2 * pi) - pi end

local function update_body(p, t)
  if body.t == t then return end
  local dt = body.t and math.max(0, math.min(t - body.t, 0.1)) or 0
  if dt > 0 then
    local v = math.sqrt((p.x - body.x) ^ 2 + (p.z - body.z) ^ 2) / dt
    body.speed = body.speed + (v - body.speed) * (1 - math.exp(-dt * 8))
    -- The frame the pets hang in follows the facing only while walking.
    -- Standing still (including turning in place to face a pet) it stays
    -- put, so a focused pet never moves away and sets off a spin.
    if body.speed > M.pet.walk_speed then
      body.heading = body.heading + wrap(p.rotation - body.heading) * (1 - math.exp(-dt * 2.5))
    end
  else
    body.heading = p.rotation
  end
  body.t, body.x, body.z = t, p.x, p.z
end

-- critically damped spring toward a target, per axis (frame-rate independent)
local function spring(a, key, target, dt, k, zeta)
  local x, v = a[key], a[key .. '_v'] or 0
  if not x then a[key], a[key .. '_v'] = target, 0 return target end
  local w = math.sqrt(k) * 2
  local steps = math.max(1, math.ceil(dt / (1 / 120)))
  local h = dt / steps
  for _ = 1, steps do
    local acc = w * w * (target - x) - 2 * (zeta or 1) * w * v
    v = v + acc * h
    x = x + v * h
  end
  a[key], a[key .. '_v'] = x, v
  return x
end

-- A spring whose value never leaves [-lim, lim]: at the limit it stops there
-- (no bounce off it), so a wild spin never flings the panel.
local function hud_spring(h, key, target, lim, dt, k, zeta)
  local x = spring(h, key, clamp(target, -lim, lim), dt, k, zeta)
  if x > lim or x < -lim then
    x = clamp(x, -lim, lim)
    h[key], h[key .. '_v'] = x, 0
  end
  return x
end

function M.place_pet(id, a, p, t, focused)
  local cfg = M.pet
  update_body(p, t)
  local dt = a.t and math.max(0, math.min(t - a.t, 0.1)) or 0
  a.t = t

  local width = a.width or cfg.width
  local height = a.height or cfg.height
  -- an anchor's own density wins (window panels, lua/windows.lua); a settings slider at 0 must not make NaN pets
  local ppy = math.max(a.pixels_per_yalm or cfg.pixels_per_yalm or 0, 50)
  local half_w = width / ppy / 2
  local half_h = height / ppy / 2

  -- slots beside the character, alternating right / left and stepping back:
  -- the usual camera sits behind the character, so the sides stay visible
  -- without ever coming between the camera and the character
  local ids = pet_ids()
  local k = 1
  for i, other in ipairs(ids) do if other == id then k = i end end
  local side_sign = (k % 2 == 1) and 1 or -1
  local level = (k - 1) // 2
  local slot = side_sign * (cfg.side + level * cfg.step)
  local ang = body.heading + slot + sin(t * 0.11 + a.phase) * cfg.drift
  -- stay clear of the character: never closer than the panel's half width plus a margin
  local dist = math.max(cfg.distance, half_w + 0.9) 
  local tx = p.x + sin(ang) * dist
  local tz = p.z + cos(ang) * dist
  local ty = p.y + math.max(cfg.height_above, half_h + 0.2) + sin(t * 0.9 + a.phase) * cfg.bob

  local x = spring(a, 'x', tx, dt, cfg.stiffness, cfg.damping)
  local y = spring(a, 'y', ty, dt, cfg.stiffness, cfg.damping)
  local z = spring(a, 'z', tz, dt, cfg.stiffness, cfg.damping)

  -- hard guarantees on top of the springs: outside the character's personal
  -- space, and not overlapping pets already placed this frame
  local dx, dz = x - p.x, z - p.z
  local r = math.sqrt(dx * dx + dz * dz)
  local min_r = half_w + 0.6
  if r < min_r then
    if r < 1e-3 then dx, dz, r = sin(ang), cos(ang), 1 end
    x, z = p.x + dx / r * min_r, p.z + dz / r * min_r
  end
  for i = 1, k - 1 do
    local o = M.anchors[ids[i]]
    if o and o.placed_at == t and o.px then
      local ox, oz = x - o.px, z - o.pz
      local d = math.sqrt(ox * ox + oz * oz)
      local need = half_w + (o.width or cfg.width) / ppy / 2 + cfg.gap
      if d < need then
        if d < 1e-3 then ox, oz, d = cos(ang), -sin(ang), 1 end
        x, z = o.px + ox / d * need, o.pz + oz / d * need
      end
    end
  end
  a.placed_at, a.px, a.pz = t, x, z
  a.x, a.z = x, z -- keep the spring from fighting the constraint

  -- face the character (the concave side looks at it)
  local yaw = yaw_towards(x, z, p.x, p.z)

  -- Selecting a pet turns the character to face it once, while standing still.
  -- The pet frame does not follow turning in place, so this settles; any
  -- movement cancels the turn and it is not retried until the next selection.
  if focused then
    if not a.faced and body.speed <= cfg.walk_speed then
      local want = yaw_towards(p.x, p.z, x, z)
      local diff = wrap(want - p.rotation)
      if math.abs(diff) < 0.04 then
        a.faced = true
      else
        local stepmax = cfg.turn_speed * dt
        ghostty.set_rotation(p.rotation + math.max(-stepmax, math.min(stepmax, diff)))
      end
    elseif body.speed > cfg.walk_speed then
      a.faced = true -- you moved: leave the facing to you
    end
  else
    a.faced = false
  end

  return placement(a, x, y, z, yaw, 0, width, height, ppy, a.opacity or M.defaults.opacity,
    cfg.curve > 0 and math.max(cfg.curve, half_w * 2.5) or 0, t)
end

-- The camera once per frame time, and how fast it turns (rad/s toward its
-- right and its up, from the last frame; 0 after a hitch or a gap).
local view_prev = { t = nil }
local function view_at(t)
  if M._vt == t then return M._v end
  M._vt = t
  M._vbuf = M._vbuf or {}
  local v = ghostty.view and ghostty.view(M._vbuf) or nil
  local p = view_prev
  M._turn_r, M._turn_u = 0, 0
  if v then
    local dt = p.t and t - p.t or 0
    if dt > 1e-4 and dt < 0.25 then
      local lim = M.hud.max_turn
      local ar = math.asin(clamp(v.fx * p.rx + v.fy * p.ry + v.fz * p.rz, -1, 1))
      local au = math.asin(clamp(v.fx * p.ux + v.fy * p.uy + v.fz * p.uz, -1, 1))
      -- more than a big turn in one frame is a cut (a cutscene, a teleport): no sway
      if math.abs(ar) + math.abs(au) < 0.5 then
        M._turn_r = clamp(ar / dt, -lim, lim)
        M._turn_u = clamp(au / dt, -lim, lim)
      end
    end
    p.t, p.rx, p.ry, p.rz, p.ux, p.uy, p.uz = t, v.rx, v.ry, v.rz, v.ux, v.uy, v.uz
  else
    p.t = nil
  end
  M._v = v
  return v
end

function M.place_hud(id, a, t)
  local cfg = M.hud
  local v = view_at(t)
  if not v then return nil end
  local h = a._hud
  if not h then h = { lx = 0, ly = 0, tr = 0, tu = 0, rl = 0 } a._hud = h end -- starts at rest
  local dt = h.t and clamp(t - h.t, 0, 0.1) or 0
  h.t = t
  local wr, wu = M._turn_r, M._turn_u
  local k, z, mt, md = cfg.stiffness, cfg.damping, cfg.max_tilt, cfg.max_drag
  -- lagging behind the turn: slid back on screen, still facing where the camera looked
  local lx = hud_spring(h, 'lx', -cfg.drag * wr, md, dt, k, z)
  local ly = hud_spring(h, 'ly', cfg.drag * wu, md, dt, k, z)
  local tr = hud_spring(h, 'tr', cfg.tilt * wr, mt, dt, k, z)
  local tu = hud_spring(h, 'tu', cfg.tilt * wu, mt, dt, k, z)
  local rl = hud_spring(h, 'rl', -cfg.roll * wr, mt, dt, k, z)
  local sx = a.sx + lx
  local sy = a.sy + ly + sin(t * cfg.bob_speed + (a.phase or 0)) * cfg.bob
  local d = a.dist or cfg.distance
  local nx, ny = (2 * sx - 1) * v.tan_x * d, (1 - 2 * sy) * v.tan_y * d
  local x = v.x + v.fx * d + v.rx * nx + v.ux * ny
  local y = v.y + v.fy * d + v.ry * nx + v.uy * ny
  local zz = v.z + v.fz * d + v.rz * nx + v.uz * ny
  -- face back along the camera's (lagged) view: parallel to the screen at rest
  local fx, fy, fz = v.fx - tr * v.rx - tu * v.ux, v.fy - tr * v.ry - tu * v.uy, v.fz - tr * v.rz - tu * v.uz
  local fl = math.sqrt(fx * fx + fy * fy + fz * fz)
  local yaw, pitch = atan(-fx, -fz), math.asin(clamp(-fy / fl, -1, 1))
  -- keeps its screen size whatever the distance or field of view
  local ppy = v.height / (2 * d * v.tan_y * (a.scale or 1))
  local out = placement(a, x, y, zz, yaw, pitch, a.width or M.defaults.width, a.height or M.defaults.height,
    ppy, a.opacity or M.defaults.opacity, 0, t)
  out.roll, out.hud = rl, true
  -- UI, not part of the world: none of its light, none cast
  out.tint_r, out.tint_g, out.tint_b, out.backlight = 1, 1, 1, 0
  out.light_intensity = 0
  return out
end

-- Walking up makes sense for panels that stay put when you move: pins in the
-- world and panels over other characters. Pets, `me` and orbits move with you.
function M.walkable(id)
  local a = M.anchors[id]
  if not a then return false end
  return a.kind == 'world' or (a.kind == 'follow' and not a.player)
end

function M.place(id, t, focused)
  local a = M.anchors[id]
  if not a or a.hidden then return nil end

  if a.kind == 'world' then
    if a.zone and a.zone ~= ghostty.zone() then return nil end
    return result(a, a.x, a.y, a.z, a.yaw, t)
  end

  if a.kind == 'hud' then return M.place_hud(id, a, t) end

  -- the player once per frame time, into the same table every time
  if M._pt ~= t then
    M._pbuf = M._pbuf or {}
    M._pt, M._p = t, ghostty.player(M._pbuf)
  end
  local p = M._p
  if not p then return nil end

  if a.kind == 'follow' then
    local o = a.player and p or ghostty.object(a.entity_id)
    if not o then return nil end
    local fx, fz = facing(o.rotation)
    local x, y, z = o.x + fx * a.forward, o.y + a.up, o.z + fz * a.forward
    local yaw = o.rotation + (a.turn or 0)
    if a.face_player then yaw = yaw_towards(x, z, p.x, p.z) end
    return result(a, x, y, z, yaw, t)
  end

  if a.kind == 'pet' then
    return M.place_pet(id, a, p, t, focused)
  end

  if a.kind == 'orbit' then
    local ang = a.phase + t * a.speed
    local x, z = p.x + sin(ang) * a.radius, p.z + cos(ang) * a.radius
    -- readable side faces your character
    return result(a, x, p.y + a.up, z, yaw_towards(x, z, p.x, p.z), t)
  end

  return nil
end

return M
