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
  run_speed = 5.5,       -- yalms per second at which run_back is fully applied (running is ~6)
  run_back = 0.35,       -- radians the slots swing further back while running
  behind_clear = 0.8,    -- radians either side of straight behind you a pet never enters
  camera_clear = 0.85,   -- radians either side of the camera-to-you line a pet never enters
  stack_out = 1.1,       -- yalms further out per pet pair that no longer fits beside you
  bob = 0.025,            -- vertical bob in yalms
  drift = 0.0,           -- radians they wander (small, so a focused pet holds still)
  curve = 9.0,           -- curve radius in yalms (concave toward the character); larger = flatter, 0 = flat
  gap = 0.3,             -- minimum yalms between neighbouring pets
  turn_speed = 5.0,      -- radians per second the character turns to face a newly selected pet
  around_step = 1.0,     -- radians: a pet with further to go round you goes the long way, a step at a time
  -- While a panel is focused the other pets line up in a row beside it, at its
  -- distance from you: earlier in the order to its left, later to its right,
  -- smaller, and in tiers above it where a side would reach into a no-go cone
  -- (behind you, between the camera and you). Back to their slots when focus leaves.
  -- The order is yours: the arrows on a pet's edges or `/term order`.
  lineup = {
    enabled = true,
    scale = 0.7,         -- size of the lined-up pets (1 = their own size)
    gap = 0.2,           -- yalms between neighbours in the row
    reach = 4.5,         -- yalms the row reaches out each side before a tier above begins
    margin = 0.15,       -- yalms kept from the no-go cones
  },
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
-- Ctrl as well to stretch it over that surface. The right button puts it back.
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

-- Panels draw beneath what other plugins put in the background layer
-- earlier in the frame, such as Umbra's toolbar at the screen edge. false:
-- panels paint over them as before.
M.under_ui = true

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
  out.order_prev, out.order_next = false, false
  out.x, out.y, out.z, out.yaw, out.pitch = x, y, z, yaw, pitch
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
  if how == 'order' then return M.reorder(id, a[2] or '') end
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
    return 'usage: /term pin [here|me|target|orbit] ...'
  end
  return nil
end

-- Fields a panel keeps when it turns from pin to pet and back: only those set
-- on it (a terminal takes the new kind's default size; a window panel keeps
-- the size lua/windows.lua gave it).
local KEEP = { 'width', 'height', 'pixels_per_yalm', 'opacity', 'run_occluded', 'hidden', 'order' }

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
    opacity = old.opacity, run_occluded = old.run_occluded, order = old.order,
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

local TRANSIENT = { t = true, placed_at = true, px = true, pz = true, phw = true, ls = true,
  lu_t = true, lu_ang = true, lu_dist = true, lu_y = true, lu_scale = true }

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

-- The pet order: each pet anchor keeps `order` (saved with it), smaller first.
local function by_order(x, y)
  local ox, oy = M.anchors[x].order, M.anchors[y].order
  if ox ~= oy then return ox < oy end
  return x < y
end

-- Shown pets in their order, kept until an anchor comes, goes, hides, changes
-- kind or is reordered (M.command, M.drop, M.restore, M.forget reset it). A
-- pet without a place in the order takes the next one after the rest.
local function pet_ids()
  local ids = M._pet_ids
  if ids then return ids end
  ids = {}
  local top = 0
  for id, a in pairs(M.anchors) do
    if a.kind == 'pet' and not a.hidden then ids[#ids + 1] = id end
    if type(a.order) == 'number' and a.order > top then top = a.order end
  end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local a = M.anchors[id]
    if type(a.order) ~= 'number' then top = top + 1 a.order = top end
  end
  table.sort(ids, by_order)
  M._pet_ids = ids
  return ids
end

-- /term order left|right|first|last|N: moves pet `id` in the order (left and
-- right swap it with its neighbour), which is both its slot beside you and its
-- place in the row while a panel is focused.
function M.reorder(id, how)
  local a = M.anchors[id]
  if not a then return 'not a world terminal' end
  if a.kind ~= 'pet' or a.hidden then return 'only pets have a place in the order' end
  M._pet_ids = nil
  local ids = pet_ids()
  local k = 1
  for i, other in ipairs(ids) do if other == id then k = i end end
  local to
  if how == 'left' or how == 'prev' then to = k - 1
  elseif how == 'right' or how == 'next' then to = k + 1
  elseif how == 'first' then to = 1
  elseif how == 'last' then to = #ids
  elseif tonumber(how) then to = math.floor(tonumber(how))
  else return 'usage: /term order left|right|first|last|N' end
  to = math.max(1, math.min(#ids, to))
  if to == k then return nil end
  local list = {}
  for i, other in ipairs(ids) do list[i] = other end
  table.remove(list, k)
  table.insert(list, to, id)
  for i, other in ipairs(list) do M.anchors[other].order = i end
  M._pet_ids = nil
  return nil
end

-- Which panel is focused: the core says so to place(id, t, true) only, and
-- may place it after the others, so this frame's answer falls back to the
-- last frame's (one frame late at most).
local focus = { t = nil, cur = nil, prev = nil }
local function note_focus(id, t, focused)
  if focus.t ~= t then focus.prev, focus.cur, focus.t = focus.cur, nil, t end
  if focused then focus.cur = id end
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

-- (x, z) moved around `p` to the nearest edge of the cone of half_angle
-- radians about direction `back`, when inside it
local function clear_of(x, z, p, back, half_angle)
  local ox, oz = x - p.x, z - p.z
  local rr = math.sqrt(ox * ox + oz * oz)
  local rel = wrap(atan(ox, oz) - back)
  if rr > 1e-3 and math.abs(rel) < half_angle then
    local edge = back + (rel < 0 and -half_angle or half_angle)
    return p.x + sin(edge) * rr, p.z + cos(edge) * rr
  end
  return x, z
end

local function pet_ppy(a)
  -- an anchor's own density wins (window panels, lua/windows.lua); a settings slider at 0 must not make NaN pets
  return math.max(a.pixels_per_yalm or M.pet.pixels_per_yalm or 0, 50)
end
local function pet_half_w(a) return (a.width or M.pet.width) / pet_ppy(a) / 2 end

-- Slot k beside the character, alternating right / left and stepping back:
-- the usual camera sits behind the character, so the sides stay visible
-- without ever coming between the camera and the character. Running swings
-- the slots a little further back; never into the cone straight behind you
-- (between you and the usual camera): pairs that no longer fit beside you
-- stack further out instead. -> angle from the pets' heading, distance
local function slot(k, half_w)
  local cfg = M.pet
  local side_sign = (k % 2 == 1) and 1 or -1
  local level = (k - 1) // 2
  local run = math.max(0, math.min(1, (body.speed - cfg.walk_speed) / math.max(cfg.run_speed - cfg.walk_speed, 0.1)))
  local max_side = pi - cfg.behind_clear
  local want = cfg.side + level * cfg.step + run * cfg.run_back
  local extra = 0
  if want > max_side then
    extra = math.ceil((want - max_side) / math.max(cfg.step, 0.1)) * cfg.stack_out
    want = max_side
  end
  -- stay clear of the character: never closer than the panel's half width plus a margin
  return side_sign * want, math.max(cfg.distance, half_w + 0.9) + extra
end

-- Direction from the character toward the camera, once per frame (nil unknown).
local function camera_back(t)
  if M._ct ~= t then
    local fx, fz
    if ghostty.camera then
      local cx, _, cz = ghostty.camera()
      fx, fz = cx, cz
    end
    M._ct, M._cam_back = t, (fx and (fx * fx + fz * fz) > 1e-4) and atan(-fx, -fz) or nil
  end
  return M._cam_back
end

-- Direction straight behind the character, the centre of the cone no pet enters.
local function behind(p)
  return (body.speed > M.pet.walk_speed and p.rotation or body.heading) + pi
end

-- Radians from direction `from`, turning `dir` (+1 or -1), before the cone of
-- half_angle about `centre` begins (0 when `from` is inside it).
local function room_before(from, dir, centre, half)
  local d = (dir * (centre - from)) % (2 * pi)
  if d > 2 * pi - half + 1e-3 then return 0 end
  return math.max(0, d - half)
end

-- The way around the character from direction `cur` to `target`: -> dir
-- (+1 or -1), radians. The way that enters neither no-go cone, else the
-- shorter one.
local function around(cur, target, p, t)
  local cfg = M.pet
  local back, cb = behind(p), camera_back(t)
  local best_dir, best_arc, best_clear = 1, nil, false
  for dir = -1, 1, 2 do
    local arc = (dir * (target - cur)) % (2 * pi)
    local clear = arc <= room_before(cur, dir, back, cfg.behind_clear) + 1e-3
      and (not cb or arc <= room_before(cur, dir, cb, cfg.camera_clear) + 1e-3)
    if best_arc == nil or (clear and not best_clear) or (clear == best_clear and arc < best_arc) then
      best_dir, best_arc, best_clear = dir, arc, clear
    end
  end
  return best_dir, best_arc
end

-- The row beside the focused pet, once per frame: each other pet gets lu_t,
-- lu_ang (absolute), lu_dist, lu_y (centre above the feet) and lu_scale.
-- The row runs straight through the focused pet, square to your line of
-- sight to it, so each pet is turned a little more toward you the further out
-- it sits. Earlier in the order goes to its left (a larger angle, seen from
-- you looking at it), later to its right. A side that would reach into a
-- no-go cone (behind you, between the camera and you) or past `reach` goes on
-- in a tier above the focused pet instead.
local function lineup(t, p)
  if M._lu_t == t then return M._lu_on end
  M._lu_t, M._lu_on = t, false
  local cfg = M.pet
  local lu = cfg.lineup
  local fid = focus.cur or focus.prev
  if not fid or type(lu) ~= 'table' or not lu.enabled then return false end
  local ids = pet_ids()
  if #ids < 2 then return false end
  local fk
  for i, id in ipairs(ids) do if id == fid then fk = i end end
  if not fk then return false end
  local fa = M.anchors[fid]
  local fhw = pet_half_w(fa)
  local fhh = (fa.height or cfg.height) / pet_ppy(fa) / 2
  local frel, d = slot(fk, fhw)
  local af = body.heading + frel
  local fy = math.max(cfg.height_above, fhh + 0.2)
  local back, cb = behind(p), camera_back(t)
  local scale, gap, margin = lu.scale or 0.7, lu.gap or 0.2, lu.margin or 0.15
  for dir = -1, 1, 2 do
    local first, last, step = fk + 1, #ids, 1 -- later: to the right
    if dir == 1 then first, last, step = fk - 1, 1, -1 end
    if first >= 1 and first <= #ids then
      -- how far out this side may reach (yalms along the row)
      local room = math.min(pi / 2 - 0.05, room_before(af, dir, back, cfg.behind_clear))
      if cb then room = math.min(room, room_before(af, dir, cb, cfg.camera_clear)) end
      local reach = math.min(lu.reach or 4.5, math.max(0, d * math.tan(math.max(room, 0)) - margin))
      local hh_max = 0
      for j = first, last, step do
        local o = M.anchors[ids[j]]
        hh_max = math.max(hh_max, (o.height or cfg.height) / pet_ppy(o) / 2 * scale)
      end
      local tier, off, count = 0, fhw, 0
      for j = first, last, step do
        local o = M.anchors[ids[j]]
        local h = pet_half_w(o) * scale
        local c = off + gap + h
        if c + h > reach and (count > 0 or tier == 0) then
          -- the next tier up starts at the focused pet's middle: each side
          -- keeps its own half above it
          tier, off, count = tier + 1, -gap / 2, 0
          c = off + gap + h
        end
        local y
        if tier == 0 then
          y = math.max(cfg.height_above, (o.height or cfg.height) / pet_ppy(o) / 2 * scale + 0.2)
        else
          y = fy + fhh + gap + hh_max + (tier - 1) * (2 * hh_max + gap)
        end
        o.lu_t, o.lu_ang, o.lu_dist, o.lu_y, o.lu_scale = t, af + dir * atan(c, d), math.sqrt(d * d + c * c), y, scale
        off, count = c + h, count + 1
      end
    end
  end
  M._lu_on = true
  return true
end

function M.place_pet(id, a, p, t, focused)
  local cfg = M.pet
  update_body(p, t)
  local dt = a.t and math.max(0, math.min(t - a.t, 0.1)) or 0
  a.t = t

  local ids = pet_ids()
  local k = 1
  for i, other in ipairs(ids) do if other == id then k = i end end
  local lined_up = lineup(t, p)
  local in_row = lined_up and a.lu_t == t

  -- lined up beside the focused pet, the pet shrinks by showing its pixels
  -- denser (its terminal keeps its grid)
  local s = spring(a, 'ls', in_row and a.lu_scale or 1, dt, cfg.stiffness, 1)
  s = math.max(s, 0.05)
  local width = a.width or cfg.width
  local height = a.height or cfg.height
  local ppy = pet_ppy(a) / s
  local half_w = width / ppy / 2
  local half_h = height / ppy / 2

  local ang, dist
  if in_row then
    ang, dist = a.lu_ang, a.lu_dist
  else
    local rel
    rel, dist = slot(k, pet_half_w(a))
    ang = body.heading + rel + sin(t * 0.11 + a.phase) * cfg.drift
  end
  local tx = p.x + sin(ang) * dist
  local tz = p.z + cos(ang) * dist
  -- the springs pull in a straight line: a slot across the character (a pet
  -- changing sides, lining up or going back) is reached around it instead,
  -- the way that passes neither no-go cone, a step at a time
  if a.x and a.z then
    local cur = atan(a.x - p.x, a.z - p.z)
    local dir, arc = around(cur, ang, p, t)
    local step = cfg.around_step or 1.0
    if arc > step then
      local wa = cur + dir * step
      tx, tz = p.x + sin(wa) * dist, p.z + cos(wa) * dist
    end
  end
  local ty = p.y + (in_row and a.lu_y or math.max(cfg.height_above, half_h + 0.2)) + sin(t * 0.9 + a.phase) * cfg.bob

  local x = spring(a, 'x', tx, dt, cfg.stiffness, cfg.damping)
  local y = spring(a, 'y', ty, dt, cfg.stiffness, cfg.damping)
  local z = spring(a, 'z', tz, dt, cfg.stiffness, cfg.damping)

  -- hard guarantees on top of the springs: outside the character's personal
  -- space, and (in the slots; the row is spaced already) not overlapping pets
  -- already placed this frame
  local dx, dz = x - p.x, z - p.z
  local r = math.sqrt(dx * dx + dz * dz)
  local min_r = half_w + 0.6
  if r < min_r then
    if r < 1e-3 then dx, dz, r = sin(ang), cos(ang), 1 end
    x, z = p.x + dx / r * min_r, p.z + dz / r * min_r
  end
  if not lined_up then
    for i = 1, k - 1 do
      local o = M.anchors[ids[i]]
      if o and o.placed_at == t and o.px then
        local ox, oz = x - o.px, z - o.pz
        local d = math.sqrt(ox * ox + oz * oz)
        local need = half_w + (o.phw or pet_half_w(o)) + cfg.gap
        if d < need then
          if d < 1e-3 then ox, oz, d = cos(ang), -sin(ang), 1 end
          x, z = o.px + ox / d * need, o.pz + oz / d * need
        end
      end
    end
  end
  -- the springs lag while you run or turn: keep the pet out of the cone behind
  -- you (your facing while moving; the pets' frame while standing still)
  -- and never between the camera and you, wherever the camera turns (focusing
  -- a pet turns it; the other pets step aside rather than fill the view)
  x, z = clear_of(x, z, p, behind(p), cfg.behind_clear)
  local cb = camera_back(t)
  if cb then x, z = clear_of(x, z, p, cb, cfg.camera_clear) end
  a.placed_at, a.px, a.pz, a.phw = t, x, z, half_w
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

  local out = placement(a, x, y, z, yaw, 0, width, height, ppy, a.opacity or M.defaults.opacity,
    cfg.curve > 0 and math.max(cfg.curve, half_w * 2.5) or 0, t)
  -- the arrows on its edges: a neighbour to swap places with in the order
  out.order_prev, out.order_next = k > 1, k < #ids
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
  note_focus(id, t, focused)
  local a = M.anchors[id]
  if not a or a.hidden then return nil end

  if a.kind == 'world' then
    if a.zone and a.zone ~= ghostty.zone() then return nil end
    return result(a, a.x, a.y, a.z, a.yaw, t)
  end

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
