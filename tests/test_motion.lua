-- Pure policy test: no game, no core. lua/motion.lua on its own (springs,
-- bob, squash, the collision maths), then lua/world.lua's pets against a fake
-- game whose world is a few boxes for ghostty.raycast to hit: walls, a ledge,
-- other panels, your target. Run with a Lua 5.4 (tests/run.sh uses nelua-lua).
package.path = 'lua/?.lua;' .. package.path
for _, name in ipairs({ 'animation', 'settings' }) do
  package.preload[name] = function() return {} end
end

local motion = require('motion')

local function approx(a, b, eps) return math.abs(a - b) <= (eps or 1e-6) end

-- Springs -----------------------------------------------------------------------------------------
do
  -- the same motion whatever the frame rate: sampled at the same instants,
  -- 30, 60, 144 fps and a ragged 20..200 fps agree
  local function run(fps, k, zeta, seconds, ragged)
    local x, v, t = 0, 0, 0
    local samples, next_sample = {}, 0.25
    local seed = 12345
    while t < seconds - 1e-9 do
      local dt = 1 / fps
      if ragged then
        seed = (seed * 1103515245 + 12345) % 2147483648
        dt = 1 / (20 + (seed % 181))
      end
      if t + dt > next_sample then dt = next_sample - t end
      x, v = motion.step(x, v, 1, dt, k, zeta)
      t = t + dt
      if math.abs(t - next_sample) < 1e-9 then samples[#samples + 1] = x next_sample = next_sample + 0.25 end
    end
    return samples, x, v
  end
  for _, k in ipairs({ 5, 30, 110 }) do
    for _, zeta in ipairs({ 0.3, 0.8, 1.0 }) do
      local s60 = run(60, k, zeta, 4)
      for _, other in ipairs({ { 30 }, { 144 }, { 60, true } }) do
        local s = run(other[1], k, zeta, 4, other[2])
        for i = 1, #s60 do
          assert(approx(s[i], s60[i], 0.03), string.format('k=%g zeta=%g: %g vs %g at sample %d (fps %s)', k, zeta, s[i], s60[i], i, tostring(other[1])))
        end
      end
    end
  end
  -- bounded: never beyond the undamped overshoot, whatever the stiffness or
  -- the frame (a 0.1 s hitch, and one far longer, which is taken as 0.1 s)
  for _, k in ipairs({ 1, 20, 110, 1000, 25600, 1e9 }) do
    for _, zeta in ipairs({ 0, 0.3, 1, 3 }) do
      for _, dt in ipairs({ 1 / 144, 1 / 30, 0.1, 5 }) do
        local x, v = 0, 0
        local peak = 0
        for _ = 1, 400 do
          x, v = motion.step(x, v, 1, dt, k, zeta)
          assert(x == x and v == v, 'finite')
          peak = math.max(peak, math.abs(x))
        end
        -- undamped, semi-implicit Euler keeps a slightly tilted energy: bounded
        -- by 2 / sqrt(1 - (h w / 2)^2) <= 2.066 with h w <= 0.5, never growing;
        -- damped, never past the exact overshoot of 2
        local lim = zeta == 0 and 2.066 or 2.0001
        assert(peak <= lim, string.format('bounded: k=%g zeta=%g dt=%g peak %g', k, zeta, dt, peak))
      end
    end
  end
  -- damped: it settles, and its energy only ever goes down
  do
    local x, v = 0, 3
    local k, zeta = 110, 0.3
    local w = 2 * math.sqrt(k)
    local e_prev = math.huge
    for _ = 1, 240 do
      x, v = motion.step(x, v, 0, 1 / 60, k, zeta)
      local e = 0.5 * v * v + 0.5 * w * w * x * x
      assert(e <= e_prev * 1.0001, 'energy never grows')
      e_prev = e
    end
    assert(math.abs(x) < 1e-3 and math.abs(v) < 1e-2, 'settled within 4 s')
  end
  -- a zero or negative frame changes nothing
  local x, v = motion.step(0.5, 1, 1, 0, 30, 1)
  assert(x == 0.5 and v == 1)
  -- follow: exponential, stable, the same at any frame rate
  local a, b = 0, 0
  for _ = 1, 60 do a = motion.follow(a, 1, 1 / 60, 0.2) end
  for _ = 1, 144 do b = motion.follow(b, 1, 1 / 144, 0.2) end
  assert(approx(a, b, 1e-9) and approx(a, 1 - math.exp(-5), 1e-9), 'follow is exact')
  print('springs OK')
end

-- Animations: every eased property (motion.anim, motion.tween) sampled the
-- way a pet drives it: continuous (no speed jumps bigger than the curve's own
-- start), bounded (no overshoot past 2 %), settled in the time it says, the
-- same at any frame rate, still at rest (a goal that wobbles within the dead
-- zone moves nothing), and at the goal at once with no time (Reduce motion).
do
  local specs = {
    { 'drift', 0.9, 1.2, 0.01, 1.0 }, { 'pull', 0.63, 1.5, 0.02, 0.5 }, { 'dy', 0.6, 1.0, 0.02, 0.4 },
    { 'tuck', 0.25, 3, 0.01, 0.3 }, { 'hike', 0.35, 3, 0.02, 0.8 }, { 'squeeze', 0.3, 4, 0.01, -0.5 },
    { 'float', 0.5, 2, 0.02, 0.7 }, { 'hop', 0.3, 4, 0.02, 0.4 }, { 'row', 0.45, 3, 0.005, -0.3 },
    { 'roll', 0.5, 0.5, 0.0005, 0.03 }, { 'calm', 0.25, nil, nil, 1 },
  }
  for _, sp in ipairs(specs) do
    local name, time, vmax, dead, step = sp[1], sp[2], sp[3], sp[4], sp[5]
    for _, fps in ipairs({ 30, 60, 144 }) do
      local a = {}
      motion.anim(a, name, 0, 0, time, vmax, dead)
      local dt = 1 / fps
      local x, v_prev, peak, settled_at, max_dv = 0, 0, 0, nil, 0
      local t = 0
      local limit = vmax and math.max(time, math.abs(step) / vmax * 1.3 + time * 0.5) or time
      while t < limit * 3 + 1 do
        local nx = motion.anim(a, name, step, dt, time, vmax, dead)
        local v = (nx - x) / dt
        max_dv = math.max(max_dv, math.abs(v - v_prev))
        v_prev, x = v, nx
        t = t + dt
        peak = math.max(peak, x / step)
        if not settled_at and math.abs(x - step) <= 0.02 * math.abs(step) then settled_at = t end
      end
      assert(peak <= 1.02, name .. ' overshoots: ' .. peak)
      assert(settled_at and settled_at <= limit * 1.25 + 2 / fps, string.format('%s settles in its time at %d fps: %s (%.2f)', name, fps, tostring(settled_at), limit))
      -- no spike: the biggest change of speed in a frame is no more than the
      -- curve's own start (critically damped: w^2 * step * dt at most)
      local w = 5.8 / time
      assert(max_dv <= w * w * math.abs(step) * dt * 1.05 + 1e-9, string.format('%s speed jumps at %d fps: %.3f', name, fps, max_dv))
    end
    -- still at rest: a goal wobbling inside the dead zone moves nothing
    if dead then
      local a = {}
      motion.anim(a, name, 0.5, 0, time, vmax, dead)
      local seed, moved = 3, 0
      for _ = 1, 600 do
        seed = (seed * 1103515245 + 12345) % 2147483648
        local g = 0.5 + (seed / 2147483648 - 0.5) * dead * 1.8
        moved = math.max(moved, math.abs(motion.anim(a, name, g, 1 / 60, time, vmax, dead) - 0.5))
      end
      assert(moved == 0, name .. ' twitches at rest: ' .. moved)
    end
    -- no time: at the goal at once
    local a = {}
    motion.anim(a, name, 0, 0, 0)
    assert(motion.anim(a, name, step, 1 / 60, 0) == step, name .. ' with no time is at once')
  end
  -- the flatten tween (onto a wall and off it): smootherstep, starting and
  -- stopping with no speed
  local a = {}
  local prev, v_prev, max_dv, peak_v = 0, 0, 0, 0
  motion.tween(a, 'flat', false, 0, 0)
  for i = 1, 60 do
    local b = motion.tween(a, 'flat', true, 1 / 120, 0.2)
    local v = (b - prev) * 120
    assert(b >= prev - 1e-12 and b <= 1, 'it flattens steadily, never past flat')
    max_dv, peak_v = math.max(max_dv, math.abs(v - v_prev)), math.max(peak_v, v)
    prev, v_prev = b, v
  end
  assert(prev == 1 and v_prev < 0.2, 'it ends flat, with no speed left')
  assert(peak_v <= 1.875 / 0.2 + 1e-6, 'smootherstep: no faster than 1.875 of its time')
  print('animations OK')
end

-- The bob, sway and squash ------------------------------------------------------------------------
do
  -- bounded, and no two pets in lockstep
  local p1, p2 = 0.3, 2.9
  local n, sxy, sxx, syy = 0, 0, 0, 0
  for i = 0, 3000 do
    local t = i / 60
    local a, b = motion.bob(t, p1, 0.035, 0.9), motion.bob(t, p2, 0.035, 0.9)
    assert(math.abs(a) <= 0.035 + 1e-9 and math.abs(b) <= 0.035 + 1e-9, 'bob within its height')
    assert(math.abs(motion.sway(t, p1, 0.02, 0.6)) <= 0.02 + 1e-9, 'sway within its angle')
    n, sxy, sxx, syy = n + 1, sxy + a * b, sxx + a * a, syy + b * b
  end
  local corr = sxy / math.sqrt(sxx * syy)
  assert(math.abs(corr) < 0.6, 'two pets bob to their own beat: correlation ' .. corr)
  assert(motion.pace(p1, 1) ~= motion.pace(p2, 1), 'each at its own pace')
  assert(motion.bob(10, 1, 0, 1) == 0, 'no bob at 0')
  -- squash: a kick wobbles, never past its limit, and settles
  local a = {}
  motion.squash_kick(a, 50)
  local peak = 0
  for _ = 1, 90 do
    local s = motion.squash(a, 0, 1 / 60, 110, 0.3, 0.14)
    peak = math.max(peak, math.abs(s))
    assert(math.abs(s) <= 0.14 + 1e-12, 'squash within its limit')
  end
  assert(peak > 0.1, 'a hard kick squashes')
  for _ = 1, 60 do motion.squash(a, 0, 1 / 60, 110, 0.3, 0.14) end
  assert(math.abs(a.m_sq) < 2e-3, 'and settles in about two seconds: ' .. a.m_sq)
  print('bob and squash OK')
end

-- Collision maths ------------------------------------------------------------------------------------
do
  -- nearest points of two segments
  local d = motion.seg_seg(0, 0, 2, 0, 1, 1, 1, 3)
  assert(approx(d, 1), 'T apart')
  d = motion.seg_seg(0, 0, 2, 0, 1, -1, 1, 1)
  assert(approx(d, 0), 'crossing')
  d = motion.seg_seg(0, 0, 2, 0, 3, 0, 5, 0)
  assert(approx(d, 1), 'collinear apart')
  d = motion.seg_seg(0, 0, 0, 0, 3, 4, 3, 4)
  assert(approx(d, 5), 'two points')
  -- footprints: a panel facing +Z (yaw 0) runs along X; curved, its edges bend forward
  local ax, az, bx, bz = motion.footprint(1, 2, 0, 1, 0)
  assert(approx(ax, 0) and approx(az, 2) and approx(bx, 2) and approx(bz, 2), 'flat footprint')
  ax, az, bx, bz = motion.footprint(0, 0, 0, 1, 2)
  assert(az > 0 and bz > 0 and approx(az, bz) and bx - ax < 2, 'curved edges come forward')
  -- two panels side by side, overlapping: pushed apart along the row, by exactly enough
  local depth, nx, nz = motion.panel_push(0.5, 0, 2.5, 0, 1, 0.5, 0, 0.1, 2, 0.1, 1, 0.5, 0.3)
  assert(depth > 0, 'overlapping panels push')
  local sx, sz = nx * depth, nz * depth
  local after = motion.seg_seg(0.5 + sx, sz, 2.5 + sx, sz, 0, 0.1, 2, 0.1)
  assert(after >= 0.3 - 1e-6 and after <= 0.3 + 0.02, 'cleared by the gap, not more: ' .. after)
  -- apart but closer than the gap: exactly the gap after
  depth, nx, nz = motion.panel_push(0, 0, 1, 0, 0, 0.5, 1.05, 0, 2, 0, 0, 0.5, 0.2)
  assert(approx(depth, 0.15) and approx(nx, -1) and approx(nz, 0), 'end to end: back off along the row')
  -- crossed like an X: cleared along the line between their centres
  depth, nx, nz = motion.panel_push(-1, 0.2, 1, 0.2, 0, 0.5, 0, -1, 0, 1, 0, 0.5, 0.1)
  after = motion.seg_seg(-1 + nx * depth, 0.2 + nz * depth, 1 + nx * depth, 0.2 + nz * depth, 0, -1, 0, 1)
  assert(depth > 0 and after >= 0.1 - 1e-6 and after < 0.2, 'crossed panels cleared: ' .. after)
  -- one above the other: no push
  depth = motion.panel_push(0, 0, 2, 0, 3, 0.5, 0, 0, 2, 0, 1, 0.5, 0.1)
  assert(depth == 0, 'above each other: clear')
  -- a character: the panel keeps `radius` from its middle, pushed straight away
  depth, nx, nz = motion.point_push(1, 0.3, 0.5, 0, 0, 2, 0)
  assert(approx(depth, 0.2) and approx(nx, 0) and approx(nz, -1), 'away from the character')
  -- contacts lose the speed into the surface and bounce a little
  local vx, vz, into = motion.contact(-2, 1, 1, 0, 0.25)
  assert(approx(vx, 0.5) and approx(vz, 1) and approx(into, 2), 'bounced a quarter')
  vx, vz, into = motion.contact(2, 1, 1, 0, 0.25)
  assert(vx == 2 and vz == 1 and into == 0, 'moving away: untouched')
  print('collision maths OK')
end

-- A small world for ghostty.raycast: boxes. BG collision is one-sided, so a ray
-- that starts inside a box does not hit it.
local boxes = {}
local rays_cast = 0
-- (no tables per ray: the garbage check below measures lua/world.lua, not this)
local function slab(o, d, lo, hi, t0, t1)
  if math.abs(d) < 1e-12 then
    if o < lo or o > hi then return nil end
    return t0, t1
  end
  local ta, tb = (lo - o) / d, (hi - o) / d
  if ta > tb then ta, tb = tb, ta end
  if ta > t0 then t0 = ta end
  if tb < t1 then t1 = tb end
  if t0 > t1 then return nil end
  return t0, t1
end
-- A box marked `prop` stands for the game's props (lamp posts, stone posts):
-- on another collision layer, so the old filter ('bg', layer 1 only) misses it
-- and 'all' and 'layers' see it, as in game.
local function raycast(ox, oy, oz, dx, dy, dz, max, filter)
  rays_cast = rays_cast + 1
  filter = filter or 'all'
  local l = math.sqrt(dx * dx + dy * dy + dz * dz)
  if l < 1e-9 then return nil end
  dx, dy, dz = dx / l, dy / l, dz / l
  local best
  for _, b in ipairs(boxes) do
    local inside = ox > b[1] and ox < b[4] and oy > b[2] and oy < b[5] and oz > b[3] and oz < b[6]
    if not inside and not (b.prop and filter == 'bg') then
      local t0, t1 = slab(ox, dx, b[1], b[4], 0, max)
      if t0 then t0, t1 = slab(oy, dy, b[2], b[5], t0, t1) end
      if t0 then t0 = slab(oz, dz, b[3], b[6], t0, t1) end
      if t0 and (not best or t0 < best) then best = t0 end
    end
  end
  if best then return best, 0, 0, 0, filter end
  return nil
end

-- The world maths with it --------------------------------------------------------------------------
do
  -- a wall across +X at 2: found where the ray meets it, facing back at you
  boxes = { { 2, -5, -10, 2.4, 5, 10 } }
  local hx, hz, nx, nz = motion.wall(raycast, 0, 1.6, 0, 3, 0, 5, 0.25)
  assert(approx(hx, 2) and approx(hz, 0) and approx(nx, -1) and approx(nz, 0, 1e-9), 'the wall, facing you')
  -- looked at slantwise: still the wall's own facing, not the ray's
  hx, hz, nx, nz = motion.wall(raycast, 0, 1.6, 0, 3, 1.5, 5, 0.25)
  assert(approx(hx, 2) and approx(hz, 1) and approx(nx, -1) and approx(nz, 0, 1e-9), 'slantwise: the wall faces -X: ' .. nx .. ' ' .. nz)
  assert(motion.wall(raycast, 0, 1.6, 0, 1.2, 0, 1.3, 0.25) == nil, 'out of reach: no wall')
  -- a post thinner than the probes are apart is not a wall
  boxes = { { 1.95, -5, -0.05, 2.05, 5, 0.05 } }
  assert(motion.wall(raycast, 0, 1.6, 0, 3, 0, 5, 0.25) == nil, 'a thin post is not a wall')
  -- hung: where its place flattens onto the wall, margin in front, facing out
  boxes = { { 2, -5, -10, 2.4, 5, 10 } }
  local x, z, yaw = motion.hang(raycast, 1.6, 3, 0.4, 2, 0, -1, 0, 0.5, 0.15, 1.5)
  assert(approx(x, 1.85) and approx(z, 0.4) and approx(yaw, -math.pi / 2), 'hung flat on the wall: ' .. x .. ' ' .. z .. ' ' .. yaw)
  -- never further along than `slide` from where the wall was found
  x, z = motion.hang(raycast, 1.6, 3, 4, 2, 0, -1, 0, 0.5, 0.15, 1.5)
  assert(approx(z, 1.5), 'slides at most `slide` along: ' .. z)
  -- an inside corner (a second wall across +Z at 1): slid out of it
  boxes = { { 2, -5, -10, 2.4, 5, 10 }, { -10, -5, 1, 10, 5, 1.4 } }
  x, z = motion.hang(raycast, 1.6, 3, 0.8, 2, 0, -1, 0, 0.5, 0.15, 1.5)
  assert(approx(x, 1.85) and approx(z, 1 - 0.65), 'out of the corner, margin kept: ' .. z)
  -- between two walls closer than it is wide: in the middle
  boxes = { { 2, -5, -10, 2.4, 5, 10 }, { -10, -5, 0.6, 10, 5, 1 }, { -10, -5, -1, 10, 5, -0.6 } }
  x, z = motion.hang(raycast, 1.6, 3, 0.3, 2, 0, -1, 0, 0.5, 0.15, 1.5)
  assert(approx(z, 0, 1e-9), 'an alcove: hung in its middle: ' .. z)
  -- floors and ceilings
  boxes = { { -10, -5, -10, 10, 1.0, 10 } }
  local dy = motion.headroom(raycast, 0, 1.3, 0, 0.5, 0.15, 1)
  assert(approx(dy, 0.35, 1e-6), 'lifted off the floor: ' .. dy)
  boxes = { { -10, 2.0, -10, 10, 3, 10 } }
  dy = motion.headroom(raycast, 0, 1.6, 0, 0.5, 0.15, 1)
  assert(approx(dy, -0.25, 1e-6), 'lowered under the ceiling: ' .. dy)
  boxes = { { -10, -5, -10, 10, 1.0, 10 }, { -10, 2.0, -10, 10, 3, 10 } }
  dy = motion.headroom(raycast, 0, 1.5, 0, 0.5, 0.15, 1)
  assert(dy >= 0, 'no room for both: the floor wins')
  print('walls and floors OK')
end

-- lua/world.lua's pets in a fake game ---------------------------------------------------------------
local player = { x = 0, y = 0, z = 0, rotation = 0, entity_id = 7 }
local chars = nil -- characters near you (ghostty.nearby_characters)
local target = nil
-- the camera behind you, looking the way you face, as it follows a running character
local cam = { 0, -0.2, 1 }
ghostty = {
  view = function() return nil end,
  camera = function() return math.sin(player.rotation) * cam[3], cam[2], math.cos(player.rotation) * cam[3] end,
  player = function(buf)
    if buf then for k, v in pairs(player) do buf[k] = v end return buf end
    return player
  end,
  target = function(buf)
    if not target then return nil end
    if buf then for k, v in pairs(target) do buf[k] = v end return buf end
    return target
  end,
  zone = function() return 1 end,
  object = function() return nil end,
  env = function() return nil end,
  set_rotation = function() end,
  raycast = raycast,
  -- characters near you: nil until a test puts some there (then the
  -- fallback, your target, is not used)
  nearby_characters = function(buf)
    if not chars then return nil end
    buf = buf or {}
    buf.n = #chars
    for i, c in ipairs(chars) do
      local e = buf[i] or {}
      buf[i] = e
      e.x, e.y, e.z, e.r, e.id, e.h, e.kind = c.x, 0, c.z, c.r or 0.5, c.id, c.h or 1.7, c.kind or 'player'
    end
    return buf
  end,
}

local W = dofile('lua/world.lua')
local clock = 100
local ids = {}

local function fresh(n)
  for id in pairs(W.anchors) do W.forget(id) end
  ids = {}
  for i = 1, n do
    ids[i] = 500 + i
    W.anchors[ids[i]] = { kind = 'pet', phase = i * 1.3, order = i }
  end
  W._pet_ids = nil
end

local outs = {}
local function frame(dt, focus, pins)
  clock = clock + dt
  for _, id in ipairs(pins or {}) do W.place(id, clock, false) end
  for _, id in ipairs(ids) do outs[id] = W.place(id, clock, id == focus) end
  return outs
end
local function run(seconds, dt, focus, pins, each)
  local t = 0
  while t < seconds do
    frame(dt, focus, pins)
    if each then each() end
    t = t + dt
  end
end

-- a placement's footprint, half height, the most it reaches in x
local function foot(o)
  local hw = o.width / o.pixels_per_yalm / 2 * (1 + (o.squash or 0))
  local ax, az, bx, bz = motion.footprint(o.x, o.z, o.yaw, hw, o.curve)
  return ax, az, bx, bz, o.height / o.pixels_per_yalm / 2 / (1 + (o.squash or 0))
end

-- Whether a placement, as drawn (its size, squash and curve), has any part of
-- its face inside a box: points every tenth of its width at five heights.
-- Self-contained (no lua/motion.lua), so it measures any version of the code.
-- A face is looked at again each time it has moved `recheck` (3 cm), so it
-- may touch a surface by that much between two looks: `TOUCH` allows it
-- (in game, the depth test hides whatever is behind the surface).
local TOUCH = 0.04
local function inside(o)
  local sq = o.squash or 0
  local hw = o.width / o.pixels_per_yalm / 2 * (1 + sq)
  local hh = o.height / o.pixels_per_yalm / 2 / (1 + sq)
  local rx, rz, fx, fz = math.cos(o.yaw), -math.sin(o.yaw), math.sin(o.yaw), math.cos(o.yaw)
  for i = -10, 10 do
    local lat, fwd = hw * i / 10, 0
    if o.curve and o.curve > 0.01 then
      local ang = lat / o.curve
      lat, fwd = o.curve * math.sin(ang), o.curve * (1 - math.cos(ang))
    end
    local px, pz = o.x + rx * lat + fx * fwd, o.z + rz * lat + fz * fwd
    for j = -2, 2 do
      local py = o.y + hh * 0.45 * j
      for _, b in ipairs(boxes) do
        if px > b[1] + TOUCH and px < b[4] - TOUCH and py > b[2] + TOUCH and py < b[5] - TOUCH
           and pz > b[3] + TOUCH and pz < b[6] - TOUCH then return true end
      end
    end
  end
  return false
end
local function seen_inside(id) return inside(outs[id]) end
local function hung(id) return W.anchors[id].m_hung end
-- flat against the wall at x = `wall_x` (facing -X), `margin` off it
local function on_wall(o, wall_x)
  return math.abs(o.x - (wall_x - W.pet.collide.margin)) < 0.03 and math.abs(o.yaw + math.pi / 2) < 0.02
    and (o.curve or 0) < 0.01
end

-- 1. A wall close on your right: the pet on that side hangs on it like a
--    painting, flat against it and facing out, getting there smoothly (never a
--    jump), outside your personal space. Its slot is inside the wall: it is
--    never seen there.
do
  fresh(2)
  boxes = { { 2.0, -5, -10, 2.4, 5, 10 } }
  local worst_step, prev = 0, nil
  run(4, 1 / 60, nil, nil, function()
    local o = outs[ids[1]]
    assert(not seen_inside(ids[1]), 'never seen in the wall')
    if prev then worst_step = math.max(worst_step, math.sqrt((o.x - prev[1]) ^ 2 + (o.z - prev[2]) ^ 2)) end
    prev = { o.x, o.z }
  end)
  local o = outs[ids[1]]
  assert(hung(ids[1]) and on_wall(o, 2.0), 'hung flat on the wall: x ' .. o.x .. ' yaw ' .. o.yaw .. ' curve ' .. o.curve)
  local hw = o.width / o.pixels_per_yalm / 2
  assert(math.sqrt(o.x ^ 2 + o.z ^ 2) >= hw + 0.6 - 1e-6, 'and keeps out of your personal space')
  assert(worst_step < 0.2, 'it eases there, no jumps: ' .. worst_step)
  local other = outs[ids[2]]
  assert(other.x < -1 and not hung(ids[2]) and other.curve > 0.01, 'the pet on the open side stays as it was')
  print('wall: pet 1 hung at', o.x, o.z)
end

-- 2. A wall closer than your personal space: it still hangs on the wall, slid
--    along it far enough to keep out of your personal space.
do
  fresh(1)
  boxes = { { 1.2, -5, -10, 1.6, 5, 10 } }
  run(5, 1 / 60, nil, nil, function() assert(not seen_inside(ids[1]), 'never in the wall') end)
  local o = outs[ids[1]]
  local hw = o.width / o.pixels_per_yalm / 2
  assert(hung(ids[1]) and on_wall(o, 1.2), 'hung on the near wall: x ' .. o.x)
  assert(math.sqrt(o.x ^ 2 + o.z ^ 2) >= hw + 0.6 - 0.02, 'slid along it out of your personal space')
  print('near wall: pet at', o.x, o.z)
end

-- 2b. Walking along a wall: the pet stays on it and slides along the
--     wallpaper beside you, flat the whole way, never in it.
do
  fresh(1)
  boxes = { { 2.0, -5, -10, 2.4, 5, 14 } }
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  local lag = {}
  run(4, 1 / 60, nil, nil, function()
    player.z = player.z + 3 / 60
    local o = outs[ids[1]]
    assert(not seen_inside(ids[1]), 'never in the wall while sliding')
    assert(hung(ids[1]) and on_wall(o, 2.0), 'flat on the wall the whole way: x ' .. o.x .. ' yaw ' .. o.yaw)
    lag[#lag + 1] = player.z - o.z
  end)
  -- it keeps up: how far it trails you settles, it does not fall behind
  assert(math.abs(lag[#lag] - lag[#lag - 60]) < 0.05, 'slides along with you: trailing ' .. lag[#lag])
  -- and peels off where the wall ends
  run(3, 1 / 60, nil, nil, function() player.z = player.z + 3 / 60 end)
  run(2, 1 / 60)
  local o = outs[ids[1]]
  assert(not hung(ids[1]) and o.curve > 0.01 and o.x > 2.0, 'past the wall: peeled off, curved again, back in its place: x ' .. o.x)
  player.x, player.z = 0, 0
  print('sliding along a wall OK')
end

-- 2c. The wall goes (a door opens): the pet peels off and goes back to its
--     place within a moment, easing, no jump.
do
  fresh(1)
  boxes = { { 2.0, -5, -10, 2.4, 5, 10 } }
  run(3, 1 / 60)
  assert(hung(ids[1]), 'hung to begin with')
  boxes = {}
  local worst_step, prev = 0, { outs[ids[1]].x, outs[ids[1]].z }
  run(2, 1 / 60, nil, nil, function()
    local o = outs[ids[1]]
    worst_step = math.max(worst_step, math.sqrt((o.x - prev[1]) ^ 2 + (o.z - prev[2]) ^ 2))
    prev = { o.x, o.z }
  end)
  local o = outs[ids[1]]
  assert(not hung(ids[1]) and o.x > 2.1 and o.curve > 0.01, 'peeled off, back in its place')
  assert(worst_step < 0.2, 'eased, no jump: ' .. worst_step)
  print('peel off OK')
end

-- 2d. A corner: walls on your right and ahead. It hangs clear of the corner,
--     never in either wall.
do
  fresh(2)
  boxes = { { 2.0, -5, -10, 2.4, 5, 10 }, { -10, -5, 0.9, 10, 5, 1.3 } }
  player.x, player.z, player.rotation = 0, 0, 0
  run(4, 1 / 60, nil, nil, function()
    for _, id in ipairs(ids) do
      assert(not seen_inside(id), 'never in either wall')
    end
  end)
  print('corner: pet 1 at', outs[ids[1]].x, outs[ids[1]].z, 'hung', hung(ids[1]))
end

-- 2e. A post thinner than a wall in the pet's place: it is not hung on, and the
--     pet stays where it is (in game the depth test draws the post across it).
do
  fresh(1)
  boxes = {}
  run(3, 1 / 60)
  local o = outs[ids[1]]
  local x0, z0 = o.x, o.z
  boxes = { { o.x - 0.05, -5, o.z - 0.05, o.x + 0.05, 5, o.z + 0.05 } }
  run(2, 1 / 60)
  o = outs[ids[1]]
  assert(not hung(ids[1]) and math.abs(o.x - x0) + math.abs(o.z - z0) < 0.02, 'a thin post: nothing to hang on, it stays')
  print('thin post OK')
end

-- 2f. Through a doorway: your pets on either side meet the wall and hang on
--     it (never seen in it while they do), then come through after you.
do
  fresh(2)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  boxes = { { -10, -5, 1.8, -0.7, 5, 2.1 }, { 0.7, -5, 1.8, 10, 5, 2.1 } }
  local was_hung = {}
  run(4, 1 / 60, nil, nil, function()
    if player.z < 4.5 then player.z = player.z + 3 / 60 end
    for i = 1, 2 do
      -- once it is on the wall (not while it is still getting there from
      -- behind it: the game's depth test hides that part), never in it
      local o, w = outs[ids[i]], W.anchors[ids[i]].m_wall
      if hung(ids[i]) and w and math.abs((o.x - w.x) * w.nx + (o.z - w.z) * w.nz - W.pet.collide.margin) < 0.03 then
        assert(not seen_inside(ids[i]), 'never seen in the wall once on it')
      end
      if hung(ids[i]) then was_hung[i] = true end
    end
  end)
  run(3, 1 / 60)
  for i = 1, 2 do
    local o = outs[ids[i]]
    assert(was_hung[i], 'it hung on the wall on the way')
    assert(o.z > 2.1 and not hung(ids[i]), 'and came through after you: z ' .. o.z)
  end
  player.x, player.z = 0, 0
  print('doorway OK')
end

-- The drawn face (squash, tuck: hem up, top edge where it was) against a
-- character's cylinder (radius r, height h, feet at y): any point inside it.
local function hits_cylinder(o, c)
  local sq, tk = o.squash or 0, o.tuck or 0
  local hw = o.width / o.pixels_per_yalm / 2 * (1 + sq)
  local hh = o.height / o.pixels_per_yalm / 2 / (1 + sq)
  local top = o.y + hh
  local bottom = top - 2 * hh * (1 - tk)
  local rx, rz, fx, fz = math.cos(o.yaw), -math.sin(o.yaw), math.sin(o.yaw), math.cos(o.yaw)
  for i = -10, 10 do
    local lat, fwd = hw * i / 10, 0
    if o.curve and o.curve > 0.01 then
      local ang = lat / o.curve
      lat, fwd = o.curve * math.sin(ang), o.curve * (1 - math.cos(ang))
    end
    local px, pz = o.x + rx * lat + fx * fwd, o.z + rz * lat + fz * fwd
    if (px - c.x) ^ 2 + (pz - c.z) ^ 2 < (c.r or 0.5) ^ 2 then
      for j = 0, 4 do
        local py = bottom + (top - bottom) * j / 4
        if py > (c.y or 0) and py < (c.y or 0) + (c.h or 1.7) then return true end
      end
    end
  end
  return false
end

-- 2g. Characters. Other players walking through a pet's place are let pass;
--     one who stays gets room, and it goes back once they have gone.
do
  fresh(1)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  local o = outs[ids[1]]
  local rest_x, rest_z, rest_y = o.x, o.z, o.y
  chars = { { x = o.x - 3, z = o.z, id = 900, kind = 'player' } }
  local moved = 0
  run(2, 1 / 60, nil, nil, function()
    chars[1].x = chars[1].x + 3 / 60 -- walking straight through it at a walk
    local q = outs[ids[1]]
    moved = math.max(moved, math.sqrt((q.x - rest_x) ^ 2 + (q.z - rest_z) ^ 2) + math.abs(q.y - rest_y) + (q.tuck or 0))
  end)
  assert(moved < 0.06, 'a player passing by is let pass: moved ' .. moved)
  -- someone stands in its place
  chars[1].x, chars[1].z = rest_x, rest_z
  run(0.8, 1 / 60)
  local q = outs[ids[1]]
  assert(math.sqrt((q.x - rest_x) ^ 2 + (q.z - rest_z) ^ 2) < 0.05 and (q.tuck or 0) < 0.01, 'not at once: they may be passing')
  run(2.2, 1 / 60)
  assert(not hits_cylinder(outs[ids[1]], chars[1]), 'a player who stays gets room')
  chars = {}
  run(3, 1 / 60)
  q = outs[ids[1]]
  assert(math.sqrt((q.x - rest_x) ^ 2 + (q.z - rest_z) ^ 2) < 0.1 and (q.tuck or 0) < 0.01 and math.abs(q.y - rest_y) < 0.1, 'and it goes back once they have gone')
  chars = nil
  print('players OK')
end

-- 2h. A mob walks through the pet's place: the pet sees it coming, tucks its
--     hem up and floats a little so it walks under, never touching its
--     cylinder, and lets its hem down again once it has passed.
do
  fresh(1)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  local o = outs[ids[1]]
  local rest_x, rest_z = o.x, o.z
  chars = { { x = o.x - 4, z = o.z, id = 901, kind = 'mob', r = 0.6, h = 1.2 } }
  local most_tuck, most_lift, sidestep = 0, 0, 0
  run(3, 1 / 60, nil, nil, function()
    chars[1].x = chars[1].x + 3 / 60
    local q = outs[ids[1]]
    assert(not hits_cylinder(q, chars[1]), 'never touches the mob')
    most_tuck = math.max(most_tuck, q.tuck or 0)
    most_lift = math.max(most_lift, W.anchors[ids[1]].m_hlift or 0)
    sidestep = math.max(sidestep, math.sqrt((q.x - rest_x) ^ 2 + (q.z - rest_z) ^ 2))
  end)
  print('a mob walks under: tuck', most_tuck, 'lift', most_lift, 'sidestep', sidestep)
  assert(most_tuck > 0.1, 'it tucked its hem up')
  assert(sidestep < 0.2, 'rather than stepping aside')
  run(2, 1 / 60)
  assert((outs[ids[1]].tuck or 0) < 0.01, 'and let it down once the mob had passed')
  -- Reduce motion: no tuck, a plain lift
  W.motion.reduce = true
  chars[1].x = o.x - 4
  local tucked = 0
  run(3, 1 / 60, nil, nil, function()
    chars[1].x = chars[1].x + 3 / 60
    local q = outs[ids[1]]
    assert(not hits_cylinder(q, chars[1]), 'reduced: never touches the mob either')
    tucked = math.max(tucked, q.tuck or 0)
  end)
  assert(tucked < 1e-6, 'reduced: no tuck')
  W.motion.reduce = false
  chars = nil
  print('mob OK')
end

-- 2i. An NPC standing right beside the pet's place, too tall to pass under:
--     the pet keeps clear of it at once (no waiting, as for players), by
--     stepping aside.
do
  fresh(1)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  local o = outs[ids[1]]
  chars = { { x = o.x + 0.3, z = o.z + 0.4, id = 902, kind = 'npc', r = 0.5, h = 3.0 } }
  run(0.5, 1 / 60)
  run(2, 1 / 60, nil, nil, function() assert(not hits_cylinder(outs[ids[1]], chars[1]), 'keeps clear of a standing NPC') end)
  chars = nil
  print('NPC OK')
end

-- 2j. Calm. In the open the pets settle and stay; in a corridor they hang on
--     its walls and stay there; in a field of small clutter (knee-high
--     stones, thin stalks) and with a collision that answers noise, nothing
--     hangs and nothing moves; back and forth through a doorway they do not
--     flick on and off the wall.
do
  -- how often any pet went on or off a wall, and the shortest time one
  -- stayed on or off before changing again
  local function watch(seconds, each)
    local changes, last, at, shortest = 0, {}, {}, math.huge
    for _, id in ipairs(ids) do last[id] = hung(id) end
    run(seconds, 1 / 60, nil, nil, function()
      for _, id in ipairs(ids) do
        if hung(id) ~= last[id] then
          changes = changes + 1 last[id] = hung(id)
          if at[id] then shortest = math.min(shortest, clock - at[id]) end
          at[id] = clock
        end
      end
      if each then each() end
    end)
    return changes, shortest
  end
  local function stillness(seconds)
    local most = 0
    local at = {}
    for _, id in ipairs(ids) do at[id] = { outs[id].x, outs[id].z } end
    run(seconds, 1 / 60, nil, nil, function()
      for _, id in ipairs(ids) do
        local o = outs[id]
        most = math.max(most, math.sqrt((o.x - at[id][1]) ^ 2 + (o.z - at[id][2]) ^ 2))
      end
    end)
    return most
  end

  -- the open field
  fresh(2)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  assert(watch(6) == 0, 'open field: nothing to hang on')
  assert(stillness(3) < 0.01, 'open field: they settle and stay')
  print('open field OK')

  -- a corridor: walls close on both sides
  fresh(2)
  boxes = { { 1.5, -5, -3, 1.8, 5, 4 }, { -1.8, -5, -3, -1.5, 5, 4 } }
  player.x, player.z, player.rotation = 0, 0, 0
  run(4, 1 / 60, nil, nil, function()
    for _, id in ipairs(ids) do assert(not seen_inside(id), 'corridor: never seen in a wall') end
  end)
  for _, id in ipairs(ids) do assert(hung(id), 'corridor: hung on its walls') end
  assert(watch(4) == 0 and stillness(2) < 0.01, 'corridor: and they stay there')
  print('corridor OK')

  -- clutter: knee-high stones and thin stalks all round, nothing large
  fresh(2)
  boxes = {}
  local seed = 7
  local function rnd() seed = (seed * 1103515245 + 12345) % 2147483648 return seed / 2147483648 end
  for _ = 1, 60 do
    local x, z = rnd() * 12 - 6, rnd() * 12 - 6
    if x * x + z * z > 1 then
      if rnd() < 0.5 then
        local s = 0.15 + rnd() * 0.3
        boxes[#boxes + 1] = { x - s, -1, z - s, x + s, 0.3 + rnd() * 0.5, z + s } -- a stone, under knee height
      else
        boxes[#boxes + 1] = { x - 0.02, -1, z - 0.02, x + 0.02, 1.8, z + 0.02 } -- a thin stalk
      end
    end
  end
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  local c3 = watch(6)
  print('clutter: went on or off a wall', c3)
  assert(c3 == 0, 'clutter: pets do not hang on grass and stalks')
  assert(stillness(3) < 0.02, 'clutter: and hold still')
  print('clutter OK')

  -- noise: the collision answers a stray hit one ray in eight, anywhere
  fresh(2)
  boxes = {}
  local real = ghostty.raycast
  ghostty.raycast = function(ox, oy, oz, dx, dy, dz, max, f)
    if rnd() < 0.125 then return rnd() * max, 0, 0, 0, f or 'all' end
    return real(ox, oy, oz, dx, dy, dz, max, f)
  end
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  local c4 = watch(8)
  local still4 = stillness(2)
  ghostty.raycast = real
  print('noise: went on or off a wall', c4, 'moved', still4)
  assert(c4 <= 2, 'noise: stray answers are not walls')
  assert(still4 < 0.05, 'noise: holding still')
  print('noise OK')

  -- back and forth through a doorway for 12 s: on and off the wall as you
  -- come and go, not flickering
  fresh(2)
  boxes = { { -10, -5, 1.8, -0.7, 5, 2.1 }, { 0.7, -5, 1.8, 10, 5, 2.1 } }
  player.x, player.z, player.rotation = 0, 0, 0
  run(2, 1 / 60)
  local dir = 1
  local c5, shortest = watch(12, function()
    player.z = player.z + dir * 3 / 60
    if player.z > 4 then dir = -1 player.rotation = math.pi elseif player.z < -1.5 then dir = 1 player.rotation = 0 end
  end)
  print('doorway back and forth: went on or off a wall', c5, 'shortest stay', shortest)
  -- (a flicker was on or off for a look or two, 0.03 to 0.05 s; leaving one
  -- face of the wall for its other side as you go through takes longer)
  assert(shortest >= 0.1, 'no flicker at the wall: on or off for ' .. shortest .. ' s')
  player.x, player.z, player.rotation = 0, 0, 0
  print('doorway back and forth OK')
end

-- 3. A ledge under the pet's slot: it floats up over it rather than into it.
do
  fresh(1)
  boxes = { { 1.0, 0, -5, 5, 1.0, 5 } }
  run(4, 1 / 60)
  local o = outs[ids[1]]
  local _, _, _, _, hh = foot(o)
  assert(o.y - hh >= 1.0 + 0.1, 'above the ledge: bottom at ' .. (o.y - hh))
  print('ledge OK')
end

-- 4. Pets never pass through each other or a pinned panel, stacked or not,
--    standing or running and turning; their nearest edges keep the gap.
do
  fresh(4)
  boxes = {}
  -- a panel pinned where the first pet would sit
  W.command(900, 'at 1.45 2.4 1.7')
  local pins = { 900 }
  local worst, worst_pair = math.huge, ''
  local function check()
    for i = 1, #ids do
      local a = outs[ids[i]]
      local ax0, az0, ax1, az1, ahh = foot(a)
      local others = {}
      for j = 1, #ids do if j ~= i then others[#others + 1] = ids[j] end end
      others[#others + 1] = 900
      for _, bid in ipairs(others) do
        local b = bid == 900 and W.anchors[900]._out or outs[bid]
        local bx0, bz0, bx1, bz1, bhh = foot(b)
        if motion.heights_meet(a.y, ahh, b.y, bhh, 0) then
          local dd = motion.seg_seg(ax0, az0, ax1, az1, bx0, bz0, bx1, bz1)
          if dd < worst then worst, worst_pair = dd, ids[i] .. ' ' .. bid end
        end
      end
    end
  end
  run(4, 1 / 60, nil, pins)
  worst = math.huge
  run(1, 1 / 60, nil, pins, check)
  assert(worst >= W.pet.collide.gap - 0.02, 'standing: pets and the pin keep apart: ' .. worst)
  -- run forward, turn round, run back. Where the rules conflict (a pet pushed
  -- off another into a no-go cone goes back to the cone's edge) two may touch
  -- for a moment; they must not stay that way
  local speed = 6
  local frames, touching = 0, 0
  local function moving_check()
    worst = math.huge
    check()
    frames = frames + 1
    if worst < 0.01 then touching = touching + 1 end
  end
  run(3, 1 / 60, nil, pins, function() player.z = player.z + speed / 60 moving_check() end)
  player.rotation = math.pi
  run(3, 1 / 60, nil, pins, function() player.z = player.z - speed / 60 moving_check() end)
  player.rotation = 0
  print('frames with panels touching while running and turning', touching, 'of', frames)
  assert(touching <= frames * 0.1, 'hardly ever touching while moving')
  run(3, 1 / 60, nil, pins)
  worst = math.huge
  run(1, 1 / 60, nil, pins, check)
  if worst < W.pet.collide.gap - 0.02 then
    for _, id in ipairs({ 502, 504 }) do
      local a, o = W.anchors[id], outs[id]
      print(id, 'x', o.x, 'y', o.y, 'z', o.z, 'yaw', o.yaw, 'sq', o.squash, 'hop', a.m_hop, 'blk', a.m_block_t, clock, 'hw', a.m_hw, 'phw', a.phw, 'sp', a.sp, 'ls', a.ls)
    end
  end
  assert(worst >= W.pet.collide.gap - 0.02, 'apart again once you stop: ' .. worst .. ' between ' .. worst_pair)
  W.forget(900)
  print('panels OK')
end

-- 5. Your target: pets keep out of it as out of you.
do
  fresh(1)
  boxes = {}
  target = { x = 2.3, y = 0, z = 0.3, rotation = 0, entity_id = 42 }
  run(4, 1 / 60)
  local o = outs[ids[1]]
  local ax, az, bx, bz = foot(o)
  local d = motion.point_seg(target.x, target.z, ax, az, bx, bz)
  assert(d >= W.pet.collide.body - 0.02, 'clear of the target: ' .. d)
  target = nil
  print('target OK')
end

-- 6. Cute, and calm when asked: pets bob to their own beat, tilt a little,
--    bank, squash when they bump; the focused one holds still; reduce turns
--    it all off. Nothing ever runs away at any frame rate.
do
  fresh(3)
  boxes = {}
  run(4, 1 / 60)
  local ys = { {}, {}, {} }
  local rolls = {}
  -- long enough for a few slow bobs (about ten seconds each)
  run(24, 1 / 60, nil, nil, function()
    for i = 1, 3 do ys[i][#ys[i] + 1] = outs[ids[i]].y end
    rolls[#rolls + 1] = outs[ids[1]].roll
  end)
  local function spread_of(t) local lo, hi = math.huge, -math.huge for _, v in ipairs(t) do lo, hi = math.min(lo, v), math.max(hi, v) end return hi - lo end
  assert(spread_of(ys[1]) > 0.01 and spread_of(ys[1]) <= 0.045, 'a gentle bob, 2 cm at most each way: ' .. spread_of(ys[1]))
  local same = 0
  for k = 2, #ys[1] do
    if (ys[1][k] - ys[1][k - 1]) * (ys[2][k] - ys[2][k - 1]) > 0 then same = same + 1 end
  end
  assert(same < #ys[1] * 0.85, 'not in lockstep')
  assert(math.abs(outs[ids[3]].roll) > 0.004, 'a stacked pet fans out, a little')
  assert(spread_of(rolls) > 0.001, 'an idle sway')
  for _, id in ipairs(ids) do assert(math.abs(outs[id].roll) <= 0.0351 and math.abs(outs[id].squash) <= 0.04 + 1e-9, 'tilts under 2 degrees, squashes under 4 %') end
  -- the focused pet holds still and straight
  run(3, 1 / 60, ids[2])
  local fy = {}
  run(2, 1 / 60, ids[2], nil, function() fy[#fy + 1] = outs[ids[2]].y end)
  assert(spread_of(fy) < 1e-3 and math.abs(outs[ids[2]].roll) < 1e-3 and outs[ids[2]].squash == 0, 'focused: still and straight')
  -- pointed at (the core passes `held`): the same, so its text can be read
  do
    local id = ids[1]
    local hy, hr, hs = {}, 0, 0
    for _ = 1, 300 do frame(1 / 60) end -- back from the row beside the focused one
    for _ = 1, 120 do
      clock = clock + 1 / 60
      for _, other in ipairs(ids) do outs[other] = W.place(other, clock, false, other == id) end
      hy[#hy + 1] = outs[id].y
      hr, hs = math.max(hr, math.abs(outs[id].roll)), math.max(hs, math.abs(outs[id].squash))
    end
    local tail = {}
    for k = 60, #hy do tail[#tail + 1] = hy[k] end
    -- the bob is gone; what is left is the spring easing the last millimetre
    -- to rest, one way, not a wobble
    local ups, downs = 0, 0
    for k = 2, #tail do
      if tail[k] > tail[k - 1] + 1e-7 then ups = ups + 1 elseif tail[k] < tail[k - 1] - 1e-7 then downs = downs + 1 end
    end
    assert(spread_of(tail) < 3e-3 and (ups == 0 or downs == 0) and hr < 0.036 and hs <= 0.04, 'pointed at: held still')
    local lr = math.abs(outs[id].roll)
    assert(lr < 1e-3 and outs[id].squash == 0, 'pointed at: straight, unsquashed')
  end
  -- a run that stops: they lean, settle with a squash, and trail like a
  -- procession: with follow.stagger the third pet (softer on its spring) falls
  -- further behind the first than it does without it
  local function run_and_stop(stagger)
    W.pet.follow.stagger = stagger
    player.x, player.z = 0, 0
    fresh(3)
    run(3, 1 / 60)
    local start = {}
    for i = 1, 3 do start[i] = { outs[ids[i]].x, outs[ids[i]].z } end
    local rest_roll = outs[ids[1]].roll
    local lag = {}
    local peak_sq, peak_lean = 0, 0
    local t = 0
    run(1.5, 1 / 60, nil, nil, function()
      t = t + 1 / 60
      player.x = player.x + 6 / 60
      if not lag[1] and t >= 0.4 then
        for i = 1, 3 do lag[i] = t * 6 - (outs[ids[i]].x - start[i][1]) end
      end
      peak_lean = math.max(peak_lean, math.abs(outs[ids[1]].roll - rest_roll))
    end)
    run(2, 1 / 60, nil, nil, function()
      for i = 1, 3 do peak_sq = math.max(peak_sq, math.abs(outs[ids[i]].squash)) end
    end)
    player.x = 0
    return lag, peak_sq, peak_lean
  end
  local lag0 = run_and_stop(0)
  local lag, peak_sq, peak_lean = run_and_stop(0.08)
  print('trailing along x without and with stagger: first', lag0[1], lag[1], 'third', lag0[3], lag[3])
  assert(lag[3] - lag[1] > lag0[3] - lag0[1] + 0.05, 'a procession: the third trails further behind the first')
  assert(peak_sq <= 0.04 + 1e-9, 'stops do not squash (bumps and landings only), and never past 4 %: ' .. peak_sq)
  assert(peak_lean > 0.004 and peak_lean <= 0.036, 'a slight bank as they swing after you: ' .. peak_lean)
  -- reduce: no bob, sway, tilt or squash
  W.motion.reduce = true
  run(4, 1 / 60)
  local ry = {}
  run(2, 1 / 60, nil, nil, function()
    for i = 1, 3 do
      assert(math.abs(outs[ids[i]].roll) < 1e-3 and outs[ids[i]].squash == 0, 'reduced: straight and unsquashed')
    end
    ry[#ry + 1] = outs[ids[1]].y
  end)
  assert(spread_of(ry) < 1e-3, 'reduced: no bob')
  W.motion.reduce = false
  -- any frame rate, walls everywhere, running in circles: finite and bounded
  boxes = { { 1.5, -5, -10, 1.9, 5, 10 }, { -10, -5, 2.2, 10, 5, 2.6 }, { -10, -5, -10, 10, 0, 10 } }
  for _, fps in ipairs({ 20, 60, 144 }) do
    local ang = 0
    run(6, 1 / fps, nil, nil, function()
      ang = ang + 2 / fps
      player.x, player.z, player.rotation = math.sin(ang) * 0.8, math.cos(ang) * 0.8, ang + math.pi / 2
      for _, id in ipairs(ids) do
        local o = outs[id]
        assert(o.x == o.x and o.y == o.y and o.z == o.z and o.roll == o.roll and o.squash == o.squash, 'finite')
        assert(math.abs(o.x - player.x) < 12 and math.abs(o.z - player.z) < 12 and math.abs(o.y) < 8, 'bounded')
        local a = W.anchors[id]
        assert(math.abs(a.x_v or 0) < 40 and math.abs(a.z_v or 0) < 40, 'no runaway speed')
        assert(math.abs(o.squash) <= 0.04 + 1e-9 and math.abs(o.roll) <= 0.036, 'no runaway wobble')
      end
    end)
  end
  player.x, player.z, player.rotation = 0, 0, 0
  print('motion OK')
end

-- 6b. Calm, not flubbery: a step change (you appear a yalm to the side) is
--     followed without overshooting by more than 2 %, and so is the spring on
--     its own with the default damping.
do
  local x, v, peak = 0, 0, 0
  for _ = 1, 600 do
    x, v = motion.step(x, v, 1, 1 / 60, W.pet.stiffness, W.pet.damping)
    peak = math.max(peak, x)
  end
  assert(peak <= 1.02, 'the default spring overshoots under 2 %: ' .. peak)
  fresh(1)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(4, 1 / 60)
  local x0 = outs[ids[1]].x
  player.x = 1
  local most = -math.huge
  run(4, 1 / 60, nil, nil, function() most = math.max(most, outs[ids[1]].x - x0) end)
  local final = outs[ids[1]].x - x0
  print('a 1 yalm step: went', most, 'settled', final)
  assert(math.abs(final - 1) < 0.02 and most <= final + 0.02, 'no overshoot past 2 % on a step: ' .. most)
  player.x = 0
  print('calm OK')
end

-- 7. Rays per frame stay within the budget, and placing makes no garbage.
do
  fresh(4)
  boxes = { { 2.0, -5, -10, 2.4, 5, 10 } }
  run(2, 1 / 60)
  local most = 0
  for _ = 1, 120 do
    rays_cast = 0
    frame(1 / 60)
    most = math.max(most, rays_cast)
  end
  assert(most <= W.pet.collide.rays, 'rays per frame within the budget: ' .. most)
  collectgarbage('collect')
  collectgarbage('stop')
  local before = collectgarbage('count')
  for _ = 1, 600 do frame(1 / 60) end
  local grew = collectgarbage('count') - before
  collectgarbage('restart')
  print('4 pets against a wall, 600 frames: KB', grew, 'most rays in a frame', most)
  assert(grew < 64, 'placing pets against the world makes garbage every frame')
end

-- 8. An older core without ghostty.raycast: pets still keep off each other and you.
do
  local rc = ghostty.raycast
  ghostty.raycast = nil
  fresh(2)
  boxes = { { 2.0, -5, -10, 2.4, 5, 10 } }
  run(3, 1 / 60)
  assert(outs[ids[1]].x > 2.0, 'no raycast: the wall is not seen (as before)')
  ghostty.raycast = rc
  print('no raycast OK')
end

print('test_motion OK')
