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

local motion = require('motion')

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
  damping = 0.95,        -- 1 = settle with no overshoot; lower swings like a pendulum before settling
  walk_speed = 0.6,      -- yalms per second above which the character counts as moving
  run_speed = 5.5,       -- yalms per second at which run_back is fully applied (running is ~6)
  run_back = 0.35,       -- radians the slots swing further back while running
  behind_clear = 0.8,    -- radians either side of straight behind you a pet never enters
  camera_clear = 0.85,   -- radians either side of the camera-to-you line a pet never enters
  stack_out = 1.1,       -- yalms further out per pet pair that no longer fits beside you
  stack_depth = 0.55,    -- yalms further out per step back round you: a stacked pet sits behind the
                         -- one before it, not through it (two panels a step apart round you cross)
  bob = 0.02,            -- vertical bob in yalms, up and down (each pet on its own beat: M.pet.cute)
  drift = 0.0,           -- radians they wander (small, so a focused pet holds still)
  curve = 9.0,           -- curve radius in yalms (concave toward the character); larger = flatter, 0 = flat
  gap = 0.3,             -- minimum yalms between neighbouring pets
  -- Pets that would cover each other *on screen* step aside. `gap` above keeps
  -- them apart in the world, which is a different question: a camera looking
  -- along the arc squashes that spacing to nothing, so two pets a comfortable
  -- distance apart can still land on top of each other in view. This nudges
  -- the slot angle of whichever has the weaker claim to its place until little
  -- enough is covered, and gives up rather than shove when there is no room.
  -- It moves the slot the springs aim at, never the pet itself, so a pet never
  -- jumps: it drifts across and settles like any other slot change.
  -- Lifting is the lever that works. A pet shoved sideways is put back by the
  -- world-space spacing above, which moves pets in x and z and never in y, so
  -- a pet that rises stays risen. It is also the only direction with room:
  -- `behind_clear` and `camera_clear` between them spoken for most of the
  -- circle, and what is left after those is usually one pet directly in front
  -- of another from where the camera sits, which no amount of sliding around
  -- you can fix.
  spread = {
    -- Off until it is understood why it disturbs the lineup: with it on,
    -- tests/test_worldpanel.nelua's "lined-up pets are smaller" fails, which
    -- says a pet that should be in the row is not in it. The arrangement
    -- itself is right and tested (tests/test_world_spread.lua: four pets that
    -- covered a third of each other end up covering none), so the code stays
    -- and the default does not.
    enabled = true,
    overlap = 0.12,      -- fraction of a pet's own screen area covered before it gives ground
    relax = 0.05,        -- covered less than this and it settles back down
    tier = 0.55,         -- yalms it rises per tier
    tiers = 3,           -- tiers it will ever rise
    step = 0.2,          -- radians per sideways try, after lifting has been tried
    max = 0.6,           -- radians it will ever give up from its slot
    settle = 0.4,        -- seconds before the arrangement is worked out again
    turn = 8,            -- degrees of camera turn that call for a new arrangement
  },
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
    brick = 0.3,         -- a tier above sits this much of a pet's width along, like bricks, not a column
  },
  -- Following you: each pet trails you a little more than the one before it
  -- in the order, so they follow like a small procession and set off and stop
  -- one after another.
  follow = {
    stagger = 0.04,      -- each place in the order is this much softer on its spring (at most 45 % softer)
  },
  -- The pets' character, kept calm: a slow bob on each pet's own beat (M.pet.bob
  -- is how high), a lean it barely sways on, a small tilt of its own, stacked
  -- pets fanned out a little, a slight bank into sideways movement, and a small
  -- squash when they bump or land. A pet you are typing into or pointing at
  -- holds still and straight, so its text never moves while you read it.
  -- M.motion.reduce turns all of it off.
  cute = {
    bob_speed = 0.6,     -- radians per second of the bob (each pet a little faster or slower): slow
    sway = 0.008,        -- radians of idle lean
    tilt = 0.012,        -- radians each pet keeps tilted, its own way
    fan = 0.012,         -- radians more per step back that a stacked pet fans out
    nestle = 0.12,       -- yalms higher per step back, so stacked pets peek over each other
    lean = 0.006,        -- radians of bank per yalm/s of sideways movement
    max_lean = 0.02,     -- radians
    max_tilt = 0.035,    -- radians all of the above together never go past (2 degrees)
    squash = 1.0,        -- how much bumps and landings squash a pet (0 = none; never more than 4 %)
  },
  -- Keeping out of the way: pets never pass through each other, other world
  -- panels, your character or your target, and never show inside the game's
  -- own walls, pillars, floors and ceilings (ghostty.raycast, the game's
  -- collision; an older core or shim without it leaves only the rest).
  -- Whatever is in the way moves the point the springs aim at, so a pet
  -- slides round or eases up to it. A wall is not gone round: a pet whose
  -- place would be in or behind one hangs on it like a painting, flat against
  -- the wallpaper, and slides along it as you move until its place is clear.
  collide = {
    enabled = true,
    world = true,        -- the game's collision (walls, pillars, floors, ceilings)
    gap = 0.12,          -- yalms kept between panels' nearest edges
    body = 0.55,         -- yalms kept between a panel and your character's or another's middle
    margin = 0.15,       -- yalms kept in front of a wall, above a floor, below a ceiling
    -- walls: hung on like a painting
    rays = 96,           -- game raycasts per frame at most, for every pet together
    look = 0.1,          -- seconds between looks for a wall in a pet's way
    recheck = 0.1,       -- yalms its place moves before it looks again sooner
    probe = 0.25,        -- yalms either side of a hit the wall's face is measured
    hang = 0.25,         -- seconds it takes to flatten onto a wall, and to peel off it
    peel = 0.3,          -- yalms its place must be clear of the wall before it peels off
    hold = 0.3,          -- seconds a wall must go unseen before a pet hung on it lets go
    bounce = 0.25,       -- of the speed into a contact that comes back out
    -- characters
    predict = 0.6,       -- seconds ahead a mob's or NPC's walk is looked at
    tuck = 0.45,         -- share of its height a pet may tuck its hem up to let someone under (0 with Reduce motion)
    float = 1.5,         -- yalms a pet may float up, besides the tuck, to let someone under
    under = 2.2,         -- yalms: characters taller than this are stepped aside from, not hiked over
    dwell = 1.2,         -- seconds another player must stay in a pet's place before it makes room
    dwell_out = 1.0,     -- seconds they must have been gone before it goes back
    trace = false,       -- log what the rays find, per pet, every frame (/term world rays)
  },
}

-- Motion overall. reduce: no bob, sway, tilt, fan, lean, squash or trailing,
-- and the springs settle without overshoot (for anyone who finds floating
-- panels hard to look at).
M.motion = {
  reduce = false,
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
  -- of the screen it fills (1 = edge to edge). It keeps its shape and its
  -- terminal keeps its columns and rows: shown bigger, never resized.
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
  damping = 0.95,     -- 1 = settles with no overshoot; lower wobbles a little first
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

-- Panels draw beneath what other plugins put in the background layer
-- earlier in the frame, such as Umbra's toolbar at the screen edge. false:
-- panels paint over them as before.
M.under_ui = true

-- Panels go beneath the game's own HUD (hotbars, chat log, minimap, party
-- list, target bars, ...): where a shown addon's rectangle is on the screen
-- the panel is cut away and the game's UI shows through. Needs a shim with
-- hud_rects; full-screen panels are not cut. Addons named here never cut
-- (layers over the whole screen, or ones you would rather see panels over);
-- anything covering most of the screen is left out anyway.
M.under_hud = true
M.under_hud_ignore = {
  'NamePlate', '_MiniTalk', '_FlyText', '_ScreenText', '_PopUpText', '_WideText',
  '_LocationTitle', '_LocationTitleShort', '_TextError', '_TextClassChange', '_AreaText',
  'FadeMiddle', 'FadeBack', 'ScreenFrameSystem', '_ScreenInfoFrontBack', '_ScreenInfoBack',
}

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
  out.hud = false
  out.x, out.y, out.z, out.yaw, out.pitch, out.roll = x, y, z, yaw, pitch, 0
  out.squash = 0
  out.width, out.height, out.pixels_per_yalm, out.opacity, out.curve = width, height, ppy, opacity, curve
  a.m_placed = now -- in the world this frame: pets keep off it (M.place_pet)
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
  if how == 'order' then return M.reorder(id, a[2] or '', a[3]) end
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

-- Mouse-drag resize from the core (core/app/resize.nelua): the new size in
-- panel pixels, clamped (keeping its aspect when `keep`). su/sv say which
-- edge moved (1 right/bottom, -1 left/top, 0 about the centre): a pin's
-- centre moves by half the growth along (rx, ry, rz) per pixel of width and
-- against (ux, uy, uz) per pixel of height (world units per panel pixel), a
-- HUD panel's in its screen fractions, so the opposite edge stays put. Other
-- anchors (pets, follows, orbits) are placed by their own logic and resize
-- about their centre. Called with the id alone: whether the opposite edge
-- would stay put.
function M.resize(id, w, h, keep, su, sv, rx, ry, rz, ux, uy, uz)
  local a = M.anchors[id]
  if not a then return false end
  local anchored = a.kind == 'world' or a.kind == 'hud'
  if not w or not h then return anchored end
  if keep and w > 0 and h > 0 then
    local f = clamp(1, math.max(MIN_W / w, MIN_H / h), math.min(MAX_W / w, MAX_H / h))
    w, h = w * f, h * f
  end
  w, h = clamp(w, MIN_W, MAX_W), clamp(h, MIN_H, MAX_H)
  local dw = (w - (a.width or M.defaults.width)) / 2
  local dh = (h - (a.height or M.defaults.height)) / 2
  a.width, a.height = w, h
  su, sv = su or 0, sv or 0
  if a.kind == 'world' and rx and a.x then
    a.x = a.x + su * dw * rx - sv * dh * ux
    a.y = a.y + su * dw * ry - sv * dh * uy
    a.z = a.z + su * dw * rz - sv * dh * uz
  elseif a.kind == 'hud' then
    local v = ghostty.view and ghostty.view() or nil
    if v and v.width > 0 and v.height > 0 then
      local sc = a.scale or 1
      a.sx = clamp((a.sx or 0.5) + su * dw * sc / v.width, 0, 1)
      a.sy = clamp((a.sy or 0.5) + sv * dh * sc / v.height, 0, 1)
    end
  end
  return anchored
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
  lu_t = true, lu_ang = true, lu_dist = true, lu_y = true, lu_scale = true,
  -- how far a pet has stepped aside and risen to keep off the others on screen
  -- (M.pet.spread): worked out from where the camera is now, so saving it would
  -- restore an answer to a question nobody asked any more
  sp = true, sp_y = true }

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
        -- m_: motion and collision state (lua/motion.lua), worked out again every frame
        if k ~= 'view' and k ~= 'font_scale' and not TRANSIENT[k] and not k:match('_v$') and not k:match('^m_')
           and (tv == 'number' or tv == 'string' or tv == 'boolean')
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

-- /term order left|right|first|last|N|swap ID: moves pet `id` in the order
-- (left and right swap it with its neighbour), which is both its slot beside
-- you and its place in the row while a panel is focused. `swap ID` exchanges
-- its place with another pet's, which is what dragging one pet onto another
-- does (core/world.nelua world_order_drag_step).
function M.reorder(id, how, arg)
  local a = M.anchors[id]
  if not a then return 'not a world terminal' end
  if a.kind ~= 'pet' or a.hidden then return 'only pets have a place in the order' end
  M._pet_ids = nil
  local ids = pet_ids()
  local k = 1
  for i, other in ipairs(ids) do if other == id then k = i end end
  if how == 'swap' then
    local other = tonumber(arg)
    if not other then return 'usage: /term order swap ID' end
    other = math.floor(other)
    local b = M.anchors[other]
    if not b or b.kind ~= 'pet' or b.hidden then return 'not a pet: #' .. tostring(other) end
    if other == id then return nil end
    a.order, b.order = b.order, a.order
    M._pet_ids = nil
    return nil
  end
  local to
  if how == 'left' or how == 'prev' then to = k - 1
  elseif how == 'right' or how == 'next' then to = k + 1
  elseif how == 'first' then to = 1
  elseif how == 'last' then to = #ids
  elseif tonumber(how) then to = math.floor(tonumber(how))
  else return 'usage: /term order left|right|first|last|N|swap ID' end
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

-- A shown pet's place in the order (1: first, the leftmost), else nil (IPC panel.list).
function M.pet_rank(id)
  for i, other in ipairs(pet_ids()) do
    if other == id then return i end
  end
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

-- a damped spring toward a target, per axis, kept in the anchor as `key` and
-- `key_v` (lua/motion.lua: frame-rate independent, and it never runs away)
local function spring(a, key, target, dt, k, zeta)
  local x, v = a[key], a[key .. '_v'] or 0
  if not x then a[key], a[key .. '_v'] = target, 0 return target end
  x, v = motion.step(x, v, target, dt, k, zeta or 1)
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
  return side_sign * want, math.max(cfg.distance, half_w + 0.9) + extra + level * (cfg.stack_depth or 0)
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
          -- every other tier starts half a brick along: a wall of pets, not columns
          if tier % 2 == 1 then off = off + (lu.brick or 0) * 2 * h end
          c = off + gap + h
        end
        local y
        if tier == 0 then
          y = math.max(cfg.height_above, (o.height or cfg.height) / pet_ppy(o) / 2 * scale + 0.2)
        else
          y = fy + fhh + gap + hh_max + (tier - 1) * (2 * hh_max + gap)
        end
        o.lu_t, o.lu_ang, o.lu_dist, o.lu_y, o.lu_scale = t, af + dir * atan(c, d), math.sqrt(d * d + c * c), y, scale
        o.m_tier, o.m_dir = tier, dir -- fanned out a little in place_pet
        off, count = c + h, count + 1
      end
    end
  end
  M._lu_on = true
  return true
end

-- Defined below, once the camera view is in scope: works out, at most a few
-- times a second, how far each pet steps aside so the pets do not cover each
-- other on screen (M.pet.spread).
local spread

-- Keeping out of the way (M.pet.collide) and the pets' character (M.pet.cute) --------

local EMPTY = {}
local SQUASH_MAX = 0.04 -- a pet is never squashed or stretched by more than 4 %

-- Whether pets look at the game's collision: collision and the world on, and a
-- core that has ghostty.raycast.
local function sees_world()
  local col = M.pet.collide or EMPTY
  return col.enabled ~= false and col.world ~= false and ghostty.raycast ~= nil
end

-- Rays left this frame for every pet together (M.pet.collide.rays), 0 when
-- the pets do not see the world. The frame's rays and hits are counted for
-- /term world rays.
local function rays_left(t)
  if M._ray_t ~= t then
    M._ray_t = t
    M._rays = sees_world() and ((M.pet.collide or EMPTY).rays or 64) or 0
    M._ray_n, M._ray_hits, M._ray_new = 0, 0, 0
  end
  return M._rays
end

-- The game's collision within the budget: the distance to the first hit, or
-- nil (nothing hit, or no rays left).
local function cast(ox, oy, oz, dx, dy, dz, max)
  if (M._rays or 0) <= 0 then return nil end
  M._rays = M._rays - 1
  M._ray_n = (M._ray_n or 0) + 1
  local hit, _, _, _, filter = ghostty.raycast(ox, oy, oz, dx, dy, dz, max)
  if hit then
    M._ray_hits = (M._ray_hits or 0) + 1
    -- tracing (/term world rays): would the old filter have seen it?
    if M._trace_until and filter == 'all' and not ghostty.raycast(ox, oy, oz, dx, dy, dz, max, 'bg') then
      M._ray_new = (M._ray_new or 0) + 1
    end
  end
  return hit
end

-- A wall in pet `a`'s way, looked for every `look` seconds (sooner when its
-- place has moved `recheck`): three level rays from your chest's spot, at its
-- height, toward its place's middle and both edges (motion.wall). It hangs
-- on a wall its place would reach into, and peels off only once its place is
-- `peel` clear of it, and only after missing it for `hold` seconds (so it
-- does not flick on and off at an edge or a gap). The wall found is kept in
-- a.m_wall until the next look. -> the wall or nil.
local function wall_in_way(a, p, t, tx, ty, tz, hw)
  local col = M.pet.collide or EMPTY
  local recheck = col.recheck or 0.1
  local moved = a.m_wl_x ~= nil and (tx - a.m_wl_x) ^ 2 + (tz - a.m_wl_z) ^ 2 > recheck * recheck
  local due = not a.m_wl_t or t - a.m_wl_t >= (col.look or 0.1) or t < a.m_wl_t or moved
  if not due or rays_left(t) < 9 then return a.m_wall end
  a.m_wl_t, a.m_wl_x, a.m_wl_z = t, tx, tz
  local margin, probe = col.margin or 0.15, col.probe or 0.25
  local ux, uz = tx - p.x, tz - p.z
  local ul = math.sqrt(ux * ux + uz * uz)
  if ul < 1e-3 then return a.m_wall end
  ux, uz = ux / ul, uz / ul
  -- how far past its place a wall still counts: hanging, until it is clear
  -- by `peel`; else only when its face (and `margin`) would reach it
  local keep = a.m_wall and (col.peel or 0.3) or 0
  local found = false
  local w = a.m_wall_buf
  if not w then w = {} a.m_wall_buf = w end
  for s = -1, 1 do
    local ex, ez = tx + uz * hw * s, tz - ux * hw * s
    local reach = math.sqrt((ex - p.x) ^ 2 + (ez - p.z) ^ 2) + margin + keep
    local hx, hz, nx, nz = motion.wall(cast, p.x, ty, p.z, ex, ez, reach, probe)
    if hx then
      -- how far its place is in front of this wall (negative: in or behind
      -- it), its nearest edge counted: facing you, it spans hw either way
      -- across the line to you, and that reaches toward a wall at a slant
      local clear = (tx - hx) * nx + (tz - hz) * nz - hw * math.abs(uz * nx - ux * nz) - margin
      if clear < keep and (not found or clear < w.clear) then
        w.x, w.z, w.nx, w.nz, w.clear, found = hx, hz, nx, nz, clear, true
      end
    end
  end
  -- a look that misses the wall it hangs on (a ray through a gap, probes on
  -- a corner) is not enough to let go: only one that has gone on `hold` seconds
  if found or not a.m_wall then
    a.m_wall, a.m_lost_t = found and w or nil, nil
  else
    a.m_lost_t = a.m_lost_t or t
    if t - a.m_lost_t >= (col.hold or 0.3) or t < a.m_lost_t then a.m_wall, a.m_lost_t = nil, nil end
  end
  return a.m_wall
end

-- The floor and the ceiling where a pet is going, twice a second: how far
-- it floats up or down to keep clear of them (motion.headroom), eased.
local function headroom_at(a, t, dt, x, y, z, hh, reduce)
  local col = M.pet.collide or EMPTY
  if sees_world() and (not a.m_ht or t - a.m_ht >= 0.5 or t < a.m_ht) and rays_left(t) >= 2 then
    a.m_ht = t
    a.m_dy = clamp(motion.headroom(cast, x, y, z, hh, col.margin or 0.15, 1.0), -1.5, 1.5)
  elseif not sees_world() then
    a.m_dy = 0
  end
  return motion.anim(a, 'dy', a.m_dy or 0, dt, reduce and 0.3 or 0.6, 1.0, 0.02)
end

-- Panel `o` (placed this frame or the last, not a pet and not docked to the
-- screen) as an obstacle: -> its footprint, centre height and half height.
local function obstacle(o)
  local out = o._out
  local ppy = math.max(out.pixels_per_yalm or 300, 1)
  local hw, hh = (out.width or 0) / ppy / 2, (out.height or 0) / ppy / 2
  local x0, z0, x1, z1 = motion.footprint(out.x, out.z, out.yaw, hw, out.curve or 0)
  return x0, z0, x1, z1, out.y, hh
end

-- Pet `a` ran into a panel whose top is at `top`: it hops over it (M.place_pet)
-- rather than resting against it with its slot on the far side.
local function blocked_by(a, t, top)
  if a.m_block_t ~= t then a.m_block_t, a.m_block_top = t, top
  elseif top > a.m_block_top then a.m_block_top = top end
end

-- Pushes (x, z), a panel of half width hw and half height hh at height y
-- facing yaw, out of every panel it may not overlap: pets placed before it
-- this frame (while not lined up) and every other panel in the world.
-- `contact_fn`: for a pet's position (it loses the speed into it and squashes),
-- nil for a target. -> x, z
local function keep_off_panels(a, id, ids, k, lined_up, t, x, y, z, yaw, hw, hh, curve, gap, contact_fn)
  if not lined_up then
    for i = 1, k - 1 do
      local o = M.anchors[ids[i]]
      if o and o.placed_at == t and o.px and o.m_yaw then
        local ax0, az0, ax1, az1 = motion.footprint(x, z, yaw, hw, curve)
        local bx0, bz0, bx1, bz1 = motion.footprint(o.px, o.pz, o.m_yaw, o.m_hw or o.phw, o.m_curve or 0)
        local depth, nx, nz = motion.panel_push(ax0, az0, ax1, az1, y, hh, bx0, bz0, bx1, bz1, o.m_y or y, o.m_hh or hh, gap)
        if depth > 0 then
          if contact_fn then
            x, z = contact_fn(a, nx, nz, depth, x, z, t)
            blocked_by(a, t, (o.m_y or y) + (o.m_hh or hh))
          else
            x, z = x + nx * depth, z + nz * depth
          end
        end
      end
    end
  end
  for oid, o in pairs(M.anchors) do
    if oid ~= id and o.kind ~= 'pet' and o.kind ~= 'hud' and not o.hidden and o._out and o.m_placed
       and t >= o.m_placed and t - o.m_placed <= 0.25 and not o._out.hud then
      local ax0, az0, ax1, az1 = motion.footprint(x, z, yaw, hw, curve)
      local bx0, bz0, bx1, bz1, by, bhh = obstacle(o)
      local depth, nx, nz = motion.panel_push(ax0, az0, ax1, az1, y, hh, bx0, bz0, bx1, bz1, by, bhh, gap)
      if depth > 0 then
        if contact_fn then
          x, z = contact_fn(a, nx, nz, depth, x, z, t)
          blocked_by(a, t, by + bhh)
        else
          x, z = x + nx * depth, z + nz * depth
        end
      end
    end
  end
  return x, z
end

-- A contact: pet `a` at (x, z) is moved `depth` along (nx, nz), loses the speed
-- it had into it (keeping a little bounce) and squashes by how hard it hit, at
-- most every quarter second (a pet leaning on a no-go cone while you run is
-- not a string of bumps).
local function contact(a, nx, nz, depth, x, z, t)
  x, z = x + nx * depth, z + nz * depth
  local col = M.pet.collide or EMPTY
  local vx, vz, into = motion.contact(a.x_v or 0, a.z_v or 0, nx, nz, col.bounce or 0.25)
  a.x_v, a.z_v = vx, vz
  local gain = (M.pet.cute or EMPTY).squash or 1
  if into > 0.3 and gain > 0 and not (M.motion and M.motion.reduce)
     and (not a.m_kick or t - a.m_kick > 0.25 or t < a.m_kick) then
    a.m_kick = t
    motion.squash_kick(a, math.min(into, 4) * 0.25 * gain)
  end
  return x, z
end

-- The characters near yours, once per frame (ghostty.nearby_characters: players,
-- mobs, NPCs, chocobos, each with its hitbox radius, height and kind). An
-- older shim has no list: your target stands in for it, taken for an NPC.
-- Each one's velocity is kept from frame to frame (M._chr_v[id]) so pets can
-- see where a mob is going.
local function characters_at(t, p)
  if M._chr_t ~= t then
    local dt = M._chr_t and t - M._chr_t or 0
    M._chr_t = t
    local list = ghostty.nearby_characters and ghostty.nearby_characters(M._chr) or nil
    if list then
      M._chr = list
    else
      local c = M._chr_fb or { n = 0, {} }
      M._chr_fb, M._chr = c, c
      M._tbuf = M._tbuf or {}
      local tg = ghostty.target and ghostty.target(M._tbuf) or nil
      c.n = 0
      if tg and tg.entity_id ~= p.entity_id and (tg.x - p.x) ^ 2 + (tg.z - p.z) ^ 2 < 400 then
        local e = c[1]
        e.x, e.y, e.z, e.r, e.h, e.id, e.kind = tg.x, tg.y, tg.z, 0.5, tg.height or 1.7, tg.entity_id, 'npc'
        c.n = 1
      end
    end
    local vel = M._chr_v or {}
    M._chr_v = vel
    local seen = M._chr_seen or {}
    M._chr_seen = seen
    for i = 1, M._chr.n do
      local c = M._chr[i]
      local v = vel[c.id]
      if not v then v = { x = c.x, z = c.z, vx = 0, vz = 0 } vel[c.id] = v end
      if dt > 1e-4 and dt < 0.25 then
        local k = 1 - math.exp(-dt / 0.15) -- a little smoothing: positions arrive in steps
        v.vx = v.vx + ((c.x - v.x) / dt - v.vx) * k
        v.vz = v.vz + ((c.z - v.z) / dt - v.vz) * k
      end
      v.x, v.z, v.t = c.x, c.z, t
      seen[c.id] = t
    end
    for cid, st in pairs(seen) do
      if t - st > 3 or t < st then seen[cid], vel[cid] = nil, nil end
    end
  end
  return M._chr
end

-- Characters are not walls, and not all alike:
-- * mobs, NPCs and chocobos are kept clear of: where they are and where they
--   are going (their velocity `collide.predict` seconds ahead), their hitbox
--   radius plus `collide.body`;
-- * other players are let pass: a pet makes room only for one who stays in its
--   place for `collide.dwell` seconds, and goes back once they have been gone
--   `dwell_out`, so it never flickers between the two.
-- Room is made the tidiest way there is: when the character is short enough
-- to pass under (its height, and the ceiling over the pet, allow), the pet
-- hikes up its hem and floats up a little so they walk under it (the "tuck":
-- its bottom edge drawn up toward its top, by at most `collide.tuck` of its
-- height, then a lift for the rest); otherwise it steps aside. A pet held
-- still to be read (typed into, pointed at) makes no room: its text never
-- moves while you read it.
-- -> tx, tz (stepped aside when it must), and a.m_hike_need: how far its
-- bottom edge must rise this frame (0: none).
local function make_room(a, t, p, tx, tz, base_y, hw, hh, curve, held)
  local col = M.pet.collide or EMPTY
  a.m_hike_need = 0
  -- held still: nothing moves, not even a hike under way (it stays as it is)
  if held then a.m_hike_need = a.m_hike_goal or 0 return tx, tz end
  local list = characters_at(t, p)
  if not list or (list.n == 0 and not a.m_chr) then return tx, tz end
  local tyaw = yaw_towards(tx, tz, p.x, p.z)
  local ax0, az0, ax1, az1 = motion.footprint(tx, tz, tyaw, hw, curve) -- where it wants to be
  local bottom, top = base_y - hh, base_y + hh
  local recs = a.m_chr
  local pad = col.body or 0.55 -- `body` is the shared character state
  local ahead = col.predict or 0.6
  local vel = M._chr_v or EMPTY
  for i = 1, list.n do
    local c = list[i]
    local r = (c.r or 0.5) + pad
    local ch = c.h and c.h > 0.1 and c.h or 1.8
    -- beside it in height at all (a mob far below a floating pet is no matter)
    local beside = (c.y or 0) < top and (c.y or 0) + ch > bottom
    local d = motion.point_seg(c.x, c.z, ax0, az0, ax1, az1)
    local near = d < r
    local mob = c.kind ~= 'player'
    if mob and not near then
      -- where it is going: the line from here to `predict` seconds on
      local v = vel[c.id]
      if v and (v.vx ~= 0 or v.vz ~= 0) then
        local fx, fz = c.x + v.vx * ahead, c.z + v.vz * ahead
        local d2 = motion.seg_seg(c.x, c.z, fx, fz, ax0, az0, ax1, az1)
        near = d2 < r
      end
    end
    local rec = recs and recs[c.id]
    local must = false
    if mob then
      must = near and beside
    elseif near and beside then
      if not recs then recs = {} a.m_chr = recs end
      if not rec then rec = { in_at = t, seen = t, room = false } recs[c.id] = rec end
      if not rec.in_at then rec.in_at = t end
      rec.seen = t
      if not rec.room and t - rec.in_at >= (col.dwell or 1.2) then rec.room = true end
      must = rec.room
    elseif rec then
      if rec.room then
        if t - rec.seen >= (col.dwell_out or 1.0) then rec.room, rec.in_at = false, nil end
        must = rec.room and beside and d < r + 0.3 -- still making room while it is on its way back
      elseif t - rec.seen > 0.3 then
        rec.in_at = nil -- passed through: the next stay counts from the start
      end
    end
    if must then
      -- under it: how far the bottom edge must rise to clear their head
      local need = (c.y or 0) + ch + 0.15 - bottom
      local tuck_max = (M.motion and M.motion.reduce) and 0 or (col.tuck or 0.45)
      local can = tuck_max * 2 * hh + (col.float or 1.5)
      if need > 0 and need <= can and ch <= (col.under or 2.2) then
        if need > a.m_hike_need then a.m_hike_need = need end
      else
        local fx0, fz0, fx1, fz1 = motion.footprint(tx, tz, tyaw, hw, curve)
        local depth, nx, nz = motion.point_push(c.x, c.z, r + 0.05, fx0, fz0, fx1, fz1, tx - p.x, tz - p.z)
        if depth > 0 then tx, tz = tx + nx * depth, tz + nz * depth end
      end
    end
  end
  if recs then
    for cid, rec in pairs(recs) do
      if t - rec.seen > 5 or t < rec.seen then recs[cid] = nil end
    end
    if next(recs) == nil then a.m_chr = nil end
  end
  return tx, tz
end

-- The hike: its hem tucked up first (quick, `collide.tuck` of its height at
-- most; none with Reduce motion), then floated up for the rest, and let down
-- again once nothing has needed it for a moment. The lift goes into the
-- height the spring aims at, and it only rises where nothing is overhead (a
-- ray up from its top; a ceiling leaves it at the tuck and whatever lift fits).
-- -> the tuck (share of its height) and the lift (yalms) this frame.
local function hike(a, t, dt, x, y, z, hh, reduce)
  local col = M.pet.collide or EMPTY
  local need = a.m_hike_need or 0
  if need > 0 then
    a.m_hike_t = t
    a.m_hike_goal = math.max(need, a.m_hike_goal or 0) -- no bobbing while they pass
  elseif not (a.m_hike_t and t - a.m_hike_t < 0.35 and t >= a.m_hike_t) then
    a.m_hike_goal = 0 -- clear a moment: the hem comes down
  end
  need = a.m_hike_goal or 0
  local tuck_max = reduce and 0 or (col.tuck or 0.45)
  local tuck_goal = math.min(need / math.max(2 * hh, 1e-3), tuck_max)
  local lift_goal = math.max(0, need - tuck_goal * 2 * hh)
  if lift_goal > 0 and rays_left(t) >= 1 then
    -- nothing overhead: a ceiling caps the lift
    local up = cast(x, y + hh, z, 0, 1, 0, lift_goal + (col.margin or 0.15))
    if up then lift_goal = math.max(0, up - (col.margin or 0.15)) end
    a.m_hike_cap = lift_goal
  elseif lift_goal > 0 and a.m_hike_cap then
    lift_goal = math.min(lift_goal, a.m_hike_cap)
  end
  local tk = clamp(motion.anim(a, 'tuck', tuck_goal, dt, 0.25, 3, 0.01), 0, 0.6)
  local lf = math.max(motion.anim(a, 'hike', lift_goal, dt, 0.35, 3, 0.02), 0)
  a.m_tuck, a.m_hlift = tk, lf
  return tk, lf
end

-- /term world rays and /term world anim: a line per pet every frame for a
-- few seconds (M.trace).
local function trace_pet(id, a, t, x, y, z, flat)
  if M._trace_for then M._trace_until, M._trace_for = t + M._trace_for, nil end
  if not (M._trace_until and t <= M._trace_until and ghostty.log) then return end
  if M._trace_kind == 'anim' then
    M._anim_rows = M._anim_rows or {}
    local n = motion.active_anims(a, M._anim_rows)
    local parts = {}
    for i = 1, n do
      local r = M._anim_rows[i]
      parts[#parts + 1] = string.format('%s %.3f->%.3f (%.2f/s)', r.key, r.x, r.goal, r.v)
    end
    ghostty.log(string.format('anim pet %d: %s | %s', id, n > 0 and table.concat(parts, ', ') or 'at rest', a.m_wall and 'on a wall' or 'free'))
  else
    local w = a.m_wall
    ghostty.log(string.format('rays pet %d: %d cast this frame so far, %d hit (%d only with every layer and material) | %.2f up | %s, flat %.2f | at %.2f %.2f %.2f',
      id, M._ray_n or 0, M._ray_hits or 0, M._ray_new or 0, a.m_dy or 0,
      w and string.format('on a wall %.2f clear, facing %.2f %.2f', w.clear, w.nx, w.nz) or 'free', flat, x, y, z))
  end
end

function M.place_pet(id, a, p, t, focused, held)
  local cfg = M.pet
  local cute = cfg.cute or EMPTY
  local col = cfg.collide or EMPTY
  local reduce = M.motion and M.motion.reduce
  local colliding = col.enabled ~= false
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
  local s = motion.anim(a, 'row', in_row and a.lu_scale or 1, dt, reduce and 0.2 or 0.45, 3, 0.005)
  s = math.max(s, 0.05)
  local width = a.width or cfg.width
  local height = a.height or cfg.height
  local ppy = pet_ppy(a) / s
  local half_w = width / ppy / 2
  local half_h = height / ppy / 2
  local curve = cfg.curve > 0 and math.max(cfg.curve, half_w * 2.5) or 0
  local min_r = half_w + 0.6 -- personal space: never nearer your character than this
  -- as wide as it may be drawn: a squash widens it (by at most 4 %)
  local hw_c = half_w * (1 + math.max(a.m_sq or 0, 0))

  -- held still and straight while you type into it or point at it (easing in
  -- and out of it quickly); nothing lively at all with M.motion.reduce
  local calm = motion.anim(a, 'calm', (focused or held) and 1 or 0, dt, 0.25)
  local lively = reduce and 0 or clamp(1 - calm, 0, 1)
  if lively < 0.002 then lively = 0 end -- held still is still: nothing left over
  local phase = a.phase or 0

  local ang, dist
  local level, side -- how far back it is stacked, and on which side
  if in_row then
    ang, dist = a.lu_ang, a.lu_dist
    level, side = a.m_tier or 0, a.m_dir or 0
  else
    local rel
    rel, dist = slot(k, pet_half_w(a))
    level, side = (k - 1) // 2, (k % 2 == 1) and 1 or -1
    -- the row spaces itself and is laid out around the focused pet, so while
    -- pets are lined up nobody steps aside: only the slots ask for it
    if not lined_up then spread(t, p) end
    ang = body.heading + rel + sin(t * 0.11 + phase) * cfg.drift + (focused and 0 or (a.sp or 0))
  end
  local base_y = p.y + (in_row and a.lu_y or math.max(cfg.height_above, half_h + 0.2))
  -- a tier up when another pet would be covering this one on screen (M.pet.spread)
  if not in_row and not focused then base_y = base_y + (a.sp_y or 0) end
  -- stacked further back, a little higher: they peek over each other
  if not in_row and not reduce then base_y = base_y + level * (cute.nestle or 0) end

  local tx = p.x + sin(ang) * dist
  local tz = p.z + cos(ang) * dist
  if colliding then base_y = base_y + headroom_at(a, t, dt, tx, base_y, tz, half_h, reduce) end
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
  -- A wall in its way: it hangs on it like a painting, flat against the
  -- wallpaper where its place flattens onto it (wall_in_way, motion.hang),
  -- turned to face out from the wall. Its place moving slides it along the
  -- wall; its place clear of the wall again, it peels off and goes back.
  -- Flattening and peeling are one smootherstep turn (`hang` seconds).
  local hung = false
  if colliding and sees_world() then
    local w = wall_in_way(a, p, t, tx, base_y, tz, half_w)
    if w then
      local wyaw, _
      tx, tz, wyaw, _, a.m_room_lo, a.m_room_hi = motion.hang(cast, base_y, tx, tz, w.x, w.z, w.nx, w.nz, half_w, col.margin or 0.15, half_w + 1)
      if not a.m_hung and not reduce then motion.squash_kick(a, 0.25 * (cute.squash or 1)) end -- a soft slap onto the wall
      a.m_hyaw, hung = wyaw, true
    end
  else
    a.m_wall = nil
  end
  a.m_hung = hung
  local flat = motion.tween(a, 'flat', hung, dt, reduce and 0.15 or (col.hang or 0.25))
  -- aimed clear of the other panels and of mobs, NPCs and players who stay
  local gap = col.gap or 0.12
  if colliding then
    local tyaw = yaw_towards(tx, tz, p.x, p.z)
    tx, tz = keep_off_panels(a, id, ids, k, lined_up, t, tx, base_y, tz, tyaw, hw_c, half_h, curve, gap + 0.05, nil)
    tx, tz = make_room(a, t, p, tx, tz, base_y, half_w, half_h, curve, focused or held)
  end
  -- the bob (each pet on its own beat; none while it is held still or hangs on a wall)
  local ty = base_y + motion.bob(t, phase, cfg.bob, cute.bob_speed or 0.6) * lively * (1 - flat)

  -- a procession: each pet a little softer on its spring than the one before
  -- it in the order, so they set off and stop one after another
  local stiff = cfg.stiffness
  if not reduce then stiff = stiff * math.max(0.55, 1 - ((cfg.follow or EMPTY).stagger or 0) * (k - 1)) end
  local zeta = reduce and math.max(cfg.damping, 1) or cfg.damping
  local x = spring(a, 'x', tx, dt, stiff, zeta)
  local y = spring(a, 'y', ty, dt, stiff, zeta)
  local z = spring(a, 'z', tz, dt, stiff, zeta)
  -- a hop over another panel in its way (keep_off_panels), eased
  local hop_to = 0
  if colliding and a.m_block_t and t >= a.m_block_t and t - a.m_block_t < 0.35 then
    hop_to = clamp(a.m_block_top + gap + half_h - y + 0.02, 0, 2) -- its bottom just over their top
  end
  y = y + motion.anim(a, 'hop', hop_to, dt, 0.3, 4, 0.02)
  -- a mob or NPC passing under it: hem tucked up, floated up (make_room, hike).
  -- The shape the world checks below look at is the untucked one, which holds
  -- the tucked one, so what is clear for it is clear for the tuck too.
  local tuck, hlift = 0, 0
  if colliding then tuck, hlift = hike(a, t, dt, x, y, z, half_h, reduce) end
  y = y + hlift

  -- hard guarantees on top of the springs: out of your personal space, off the
  -- panels already placed this frame and the rest of the world's panels, out of
  -- the no-go cones. Each is a contact: the pet is put back outside and loses
  -- the speed it had into it, instead of snapping back every frame.
  local dx, dz = x - p.x, z - p.z
  local r = math.sqrt(dx * dx + dz * dz)
  if r < min_r and hung and a.m_wall then
    -- on a wall: slid along it out of your personal space, never off it and
    -- never into a corner (a wall or a corner nearer you keeps it nearer)
    local w = a.m_wall
    local wx, wz = w.nz, -w.nx
    local along, out = dx * wx + dz * wz, dx * w.nx + dz * w.nz
    local need = math.sqrt(math.max(min_r * min_r - out * out, 0))
    local slide = clamp((along >= 0 and need or -need) - along, -(a.m_room_lo or 0), a.m_room_hi or 0)
    x, z = x + wx * slide, z + wz * slide
  elseif r < min_r then
    if r < 1e-3 then dx, dz, r = sin(ang), cos(ang), 1 end
    x, z = contact(a, dx / r, dz / r, min_r - r, x, z, t)
  end
  -- facing you, or (hung) out from the wall, turning between them as it
  -- flattens or peels off; flat against a wall it is flat, not curved
  local yaw0 = yaw_towards(x, z, p.x, p.z)
  if a.m_hyaw then yaw0 = yaw0 + wrap(a.m_hyaw - yaw0) * flat end
  if flat <= 0 then a.m_hyaw = nil end
  curve = curve * (1 - flat)
  if colliding then
    x, z = keep_off_panels(a, id, ids, k, lined_up, t, x, y, z, yaw0, hw_c, half_h, curve, gap, contact)
    local body_r = col.body or 0.55
    local ax0, az0, ax1, az1 = motion.footprint(x, z, yaw0, half_w, curve)
    local depth, nx, nz = motion.point_push(p.x, p.z, body_r, ax0, az0, ax1, az1, x - p.x, z - p.z)
    if depth > 0 then x, z = contact(a, nx, nz, depth, x, z, t) end
  elseif not lined_up then
    -- collision off: pets kept apart by their centres, as before
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
  local cx, cz = clear_of(x, z, p, behind(p), cfg.behind_clear)
  local cb = camera_back(t)
  if cb then cx, cz = clear_of(cx, cz, p, cb, cfg.camera_clear) end
  local moved = math.sqrt((cx - x) ^ 2 + (cz - z) ^ 2)
  if moved > 1e-6 then
    contact(a, (cx - x) / moved, (cz - z) / moved, 0, x, z, t) -- only the speed into the cone's edge
    x, z = cx, cz -- exactly on the edge (the cone turns round you, the contact goes straight)
  end
  a.placed_at, a.px, a.pz, a.phw = t, x, z, half_w
  a.x, a.z = x, z -- keep the spring from fighting the constraint

  -- face the character (the concave side looks at it), or out from the wall
  local yaw = yaw0
  a.m_yaw, a.m_y, a.m_hh, a.m_curve, a.m_hw = yaw, y, half_h, curve, hw_c

  -- Selecting a pet turns the character to face it once, while standing still.
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

  -- its own small tilt, fanned out the further back it is stacked, an idle
  -- sway, and a slight bank into sideways movement; eased, never past max_tilt
  local roll_t = 0
  if not reduce then
    local fan = side * level * (cute.fan or 0)
    roll_t = (cute.tilt or 0) * motion.persona(phase) + fan + motion.sway(t, phase, cute.sway or 0, 0.6)
    local lat = (a.x_v or 0) * cos(yaw) - (a.z_v or 0) * sin(yaw)
    local ml = cute.max_lean or 0.02
    roll_t = roll_t + clamp(lat * (cute.lean or 0), -ml, ml)
    local mt = cute.max_tilt or 0.035
    roll_t = clamp(roll_t, -mt, mt) * lively
    yaw = yaw + lively * (1 - flat) * motion.sway(t, phase + 1.7, (cute.sway or 0) * 0.8, 0.5) -- a painting does not swing into its wall
  end
  local roll = motion.anim(a, 'roll', roll_t, dt, reduce and 0 or 0.5, 0.5, 0.0005)
  a.m_roll = roll

  -- squash: small (never past 4 %, area kept), and only for real events: a
  -- bump (contact), a fall that stops (landing), a slap onto a wall. None at
  -- all while held still or with M.motion.reduce.
  local sq = 0
  local gain = (cute.squash or 1) * lively
  if reduce then
    a.m_sq, a.m_sq_v, a.m_fall = 0, 0, nil
  else
    local vy = a.y_v or 0
    if vy < -0.6 then a.m_fall = math.min(-vy, 3) end
    if a.m_fall and vy > -0.05 then motion.squash_kick(a, a.m_fall * 0.25 * gain) a.m_fall = nil end
    sq = motion.squash(a, 0, dt, 110, 1, SQUASH_MAX)
    if lively < 0.999 then
      sq = sq * lively
      a.m_sq, a.m_sq_v = sq, (a.m_sq_v or 0) * lively
    end
  end

  local out = placement(a, x, y, z, yaw, 0, width, height, ppy, a.opacity or M.defaults.opacity, curve, t)
  out.roll, out.squash, out.tuck = roll, sq, tuck
  trace_pet(id, a, t, x, y, z, flat)
  -- the arrows on its edges: a neighbour to swap places with in the order
  out.order_prev, out.order_next = k > 1, k < #ids
  return out
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

-- Keeping pets off each other on screen (M.pet.spread) ----------------------------

-- The box a panel covers in view `v`: left, top, right, bottom in screen
-- pixels, or nil when any corner is behind the camera. The four corners bound
-- a flat panel; a curved one bulges its edges toward the viewer, so the box is
-- widened the way core/app/worldview.nelua widens it before deciding a panel
-- is off screen. Deliberately not the exact silhouette: an eight-corner hull
-- would be tighter but would jump as the camera crosses the curve, and a box
-- of projected corners changes smoothly, which is what keeps this settled.
local function screen_box(v, x, y, z, yaw, pitch, width, height, ppy)
  if not v or not v.width or not ppy or ppy <= 0 then return nil end
  local hw, hh = width / ppy / 2, height / ppy / 2
  local sy, cy = sin(yaw), cos(yaw)
  local sp, cp = sin(pitch or 0), cos(pitch or 0)
  -- right = (cy, 0, -sy) and up leaning back with the tilt, as world_basis
  local rx, rz = cy, -sy
  local ux, uy, uz = -sy * sp, cp, -cy * sp
  local minx, miny, maxx, maxy
  for i = 0, 3 do
    local ex = (i % 2 == 0) and -1 or 1
    local ey = (i < 2) and -1 or 1
    local dx = x + ex * hw * rx + ey * hh * ux - v.x
    local dy = y + ey * hh * uy - v.y
    local dz = z + ex * hw * rz + ey * hh * uz - v.z
    local depth = dx * v.fx + dy * v.fy + dz * v.fz
    if depth < 0.05 then return nil end
    local sx = ((dx * v.rx + dy * v.ry + dz * v.rz) / (depth * v.tan_x) + 1) / 2 * v.width
    local st = (1 - (dx * v.ux + dy * v.uy + dz * v.uz) / (depth * v.tan_y)) / 2 * v.height
    if not minx or sx < minx then minx = sx end
    if not maxx or sx > maxx then maxx = sx end
    if not miny or st < miny then miny = st end
    if not maxy or st > maxy then maxy = st end
  end
  local slack = (maxx - minx) * 0.1
  return minx - slack, miny, maxx + slack, maxy
end

-- How much of box A the box B covers, as a fraction of A's own area. A's own
-- area, not the smaller of the two: a big remote-desktop panel with a small
-- terminal on it has lost little and should not be the one to move.
local function box_covered(ax0, ay0, ax1, ay1, bx0, by0, bx1, by1)
  local w = math.min(ax1, bx1) - math.max(ax0, bx0)
  local h = math.min(ay1, by1) - math.max(ay0, by0)
  if w <= 0 or h <= 0 then return 0 end
  local area = (ax1 - ax0) * (ay1 - ay0)
  if area <= 0 then return 0 end
  return w * h / area
end

-- Worked out for every pet at once, a few times a second, never every frame.
-- Every pet keeps an angle `sp` it has stepped aside by; place_pet adds it to
-- the slot the springs aim at, so the pets slide across and settle instead of
-- being shoved. Solving rarely is what makes that safe: a solution that
-- followed the camera frame by frame would have the pets crawling whenever you
-- turned, which is the thing this must not do.
--
-- Order decides who yields: pets earlier in the pet order keep their slot and
-- later ones give ground, so the answer never depends on which pet was placed
-- first this frame, and two pets can never both flee each other.
spread = function(t, p)
  local cfg = M.pet.spread
  if not (cfg and cfg.enabled) then return end
  if M._sp_t == t then return end
  M._sp_t = t
  local v = view_at(t)
  if not v or not v.width then return end
  update_body(p, t)

  local ids = pet_ids()
  local turn = 0
  local pv = M._sp_view
  if pv then
    turn = math.deg(math.acos(clamp(v.fx * pv.fx + v.fy * pv.fy + v.fz * pv.fz, -1, 1)))
  end
  local changed = #ids ~= (M._sp_n or -1)
  local due = (not M._sp_at) or (t - M._sp_at) >= (cfg.settle or 0.4)
  if not (changed or (due and turn >= (cfg.turn or 8))) then return end
  M._sp_at, M._sp_n = t, #ids

  pv = M._sp_view
  if not pv then pv = {} M._sp_view = pv end
  pv.fx, pv.fy, pv.fz = v.fx, v.fy, v.fz

  local boxes = M._sp_boxes
  if not boxes then boxes = {} M._sp_boxes = boxes end
  local n = 0

  -- the one you are looking at never gives ground: it is the pet in question,
  -- the row is laid out around it, and moving it would move the row with it
  local keep = focus.cur or focus.prev

  for i, id in ipairs(ids) do
    local a = M.anchors[id]
    if a and a.kind == 'pet' and a.lu_t ~= t then
      local width = a.width or M.pet.width
      local height = a.height or M.pet.height
      local ppy = pet_ppy(a)
      local rel, dist = slot(i, pet_half_w(a))
      local base = body.heading + rel
      local ty = p.y + math.max(M.pet.height_above, height / ppy / 2 + 0.2)

      -- what this pet covers, and what covers it, at a given step aside
      local function worst_at(off, lift)
        local ang = base + off
        local x, z = p.x + sin(ang) * dist, p.z + cos(ang) * dist
        -- the same cones place_pet enforces after the spring. Without them the
        -- search happily picks an angle inside a no-go cone, clear_of shoves it
        -- straight back out, and the arrangement it worked out never happens.
        x, z = clear_of(x, z, p, behind(p), M.pet.behind_clear)
        local cb = camera_back(t)
        if cb then x, z = clear_of(x, z, p, cb, M.pet.camera_clear) end
        local x0, y0, x1, y1 = screen_box(v, x, ty + (lift or 0), z, yaw_towards(x, z, p.x, p.z),
          a.pitch or 0, width, height, ppy)
        if not x0 then return 0 end
        local worst = 0
        for b = 1, n do
          local o = (b - 1) * 4
          local ox0, oy0, ox1, oy1 = boxes[o + 1], boxes[o + 2], boxes[o + 3], boxes[o + 4]
          -- both ways round, and the worse of the two. Measuring only how much
          -- of *this* pet is covered would let it "improve" by moving toward
          -- the camera, where it grows on screen: less of it covered, far more
          -- of everything else covered by it.
          local mine = box_covered(x0, y0, x1, y1, ox0, oy0, ox1, oy1)
          local theirs = box_covered(ox0, oy0, ox1, oy1, x0, y0, x1, y1)
          if mine > worst then worst = mine end
          if theirs > worst then worst = theirs end
        end
        return worst, x0, y0, x1, y1
      end

      local off, lift = a.sp or 0, a.sp_y or 0
      if id == keep then off, lift = 0, 0 end
      local worst = worst_at(off, lift)
      -- the one kept still has nothing to decide: its box still goes in below,
      -- so the others keep off it
      if id ~= keep and worst > (cfg.overlap or 0.12) then
        -- Rising first, and as little as will do: a tier up is the move that
        -- survives everything downstream, and it reads as a shelf rather than
        -- as a pet wandering off. Sideways is tried too, but it is second and
        -- it is charged for, so a pet only slides when rising did not help.
        local tier, tiers = cfg.tier or 0.55, cfg.tiers or 3
        local step, lim = cfg.step or 0.2, cfg.max or 0.6
        local best_off, best_lift, best_cost = off, lift, math.huge
        for li = 0, tiers do
          local ly = li * tier
          local k = math.floor(lim / step)
          for si = -k, k do
            local try = si * step
            local cost = worst_at(try, ly)
              + 0.03 * li / math.max(tiers, 1)      -- rise only as far as needed
              + 0.06 * math.abs(try) / lim          -- and slide only if rising was not enough
            if cost < best_cost then best_off, best_lift, best_cost = try, ly, cost end
          end
        end
        off, lift = best_off, best_lift
      elseif id ~= keep and worst <= (cfg.relax or 0.05) and (off ~= 0 or lift ~= 0) then
        -- Nothing is covering it any more, so come back down -- but ask what
        -- coming down would look like before doing it. Testing the state it is
        -- in rather than the state it would move to is how this oscillates: it
        -- is clear *because* it is up, so it sinks, is covered again, rises
        -- again, for ever. The step is only taken when the lower place is
        -- clear too.
        local back_y = (cfg.tier or 0.55) * 0.5
        local back = (cfg.step or 0.2) * 0.5
        local down = math.max(0, lift - back_y)
        local home = (off > 0) and math.max(0, off - back) or math.min(0, off + back)
        if worst_at(home, down) <= (cfg.relax or 0.05) then
          off, lift = home, down
        end
      end
      a.sp_y = lift
      a.sp = off

      local _, x0, y0, x1, y1 = worst_at(off, lift)
      if x0 then
        local o = n * 4
        boxes[o + 1], boxes[o + 2], boxes[o + 3], boxes[o + 4] = x0, y0, x1, y1
        n = n + 1
      end
    end
  end
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

-- /term world rays [SECONDS]: log what the rays find for every pet, every
-- frame, for a few seconds (from the next frame). -> the first line of it:
-- whether the game's collision answers at all.
function M.trace(seconds, kind)
  M._trace_for = math.max(tonumber(seconds) or 5, 0.1)
  M._trace_kind = kind == 'anim' and 'anim' or 'rays'
  if M._trace_kind == 'anim' then
    local n = 0
    for _, a in pairs(M.anchors) do if a.kind == 'pet' and not a.hidden then n = n + 1 end end
    return string.format('%d pets: their animations still moving, each frame, for %g s', n, M._trace_for)
  end
  local n = 0
  for _, a in pairs(M.anchors) do if a.kind == 'pet' and not a.hidden then n = n + 1 end end
  local col = M.pet.collide or EMPTY
  local rc = ghostty.raycast
  local p = ghostty.player and ghostty.player() or nil
  local seen
  if not rc then seen = 'NO ghostty.raycast in this core: pets cannot see walls'
  elseif col.enabled == false or col.world == false then seen = 'the world is switched off (world.pet.collide)'
  elseif not p then seen = 'no character'
  else
    local down = rc(p.x, p.y + (col.chest or 1.1), p.z, 0, -1, 0, 5)
    local ahead = rc(p.x, p.y + (col.chest or 1.1), p.z, sin(p.rotation), 0, cos(p.rotation), 30)
    local ring = { all = { 0, nil }, bg = { 0, nil } }
    for i = 0, 15 do
      local ang = p.rotation + i * pi / 8
      for f, r in pairs(ring) do
        local d = rc(p.x, p.y + 0.5, p.z, sin(ang), 0, cos(ang), 6, f)
        if d then r[1] = r[1] + 1 if not r[2] or d < r[2] then r[2] = d end end
      end
    end
    seen = string.format('the ground %s below your chest, %s ahead; within 6 yalms at knee height: %d of 16 directions hit%s (%d%s with the old filter)',
      down and string.format('%.2f yalms', down) or 'NOT FOUND within 5 yalms',
      ahead and string.format('something %.2f yalms', ahead) or 'nothing within 30 yalms',
      ring.all[1], ring.all[2] and string.format(', nearest %.2f', ring.all[2]) or '',
      ring.bg[1], ring.bg[2] and string.format(', nearest %.2f', ring.bg[2]) or '')
  end
  return string.format('%s; %d pets, logging each for %g s', seen, n, M._trace_for)
end

-- The kind of terminal `id`'s anchor ('pet', 'world', 'follow', 'orbit',
-- 'hud'), nil without one: the info bar's list names pets and pins apart.
function M.kind(id)
  local a = M.anchors[id]
  return a and a.kind or nil
end

-- Walking up makes sense for panels that stay put when you move: pins in the
-- world and panels over other characters. Pets, `me` and orbits move with you.
function M.walkable(id)
  local a = M.anchors[id]
  if not a then return false end
  return a.kind == 'world' or (a.kind == 'follow' and not a.player)
end

function M.place(id, t, focused, held)
  note_focus(id, t, focused)
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
    return M.place_pet(id, a, p, t, focused, held)
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
