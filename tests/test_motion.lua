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
local function raycast(ox, oy, oz, dx, dy, dz, max)
  rays_cast = rays_cast + 1
  local l = math.sqrt(dx * dx + dy * dy + dz * dz)
  if l < 1e-9 then return nil end
  dx, dy, dz = dx / l, dy / l, dz / l
  local best
  for _, b in ipairs(boxes) do
    local inside = ox > b[1] and ox < b[4] and oy > b[2] and oy < b[5] and oz > b[3] and oz < b[6]
    if not inside then
      local t0, t1 = slab(ox, dx, b[1], b[4], 0, max)
      if t0 then t0, t1 = slab(oy, dy, b[2], b[5], t0, t1) end
      if t0 then t0 = slab(oz, dz, b[3], b[6], t0, t1) end
      if t0 and (not best or t0 < best) then best = t0 end
    end
  end
  return best
end

-- The world maths with it --------------------------------------------------------------------------
do
  -- a wall across +X at 2: a panel centred at x = 3 comes in to x <= 2 - margin
  boxes = { { 2, -5, -10, 2.4, 5, 10 } }
  local pull = motion.pull_in(raycast, 0, 1.1, 0, 3, 1.6, 0, -math.pi / 2, 0.5, 0, 0.15)
  assert(pull >= 1.15 - 1e-6 and pull < 1.4, 'pulled in front of the wall: ' .. pull)
  pull = motion.pull_in(raycast, 0, 1.1, 0, 1.2, 1.6, 0, -math.pi / 2, 0.5, 0, 0.15)
  assert(pull == 0, 'room enough: stays')
  -- a panel whose edge reaches the wall: pulled by the edge
  pull = motion.pull_in(raycast, 0, 1.1, 0, 1.5, 1.6, 0, math.pi, 1, 0, 0.15)
  assert(pull > 0, 'an edge in the wall pulls it')
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
  print('world maths OK')
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
      e.x, e.y, e.z, e.r, e.id = c.x, 0, c.z, 0.5, c.id
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
        if px > b[1] + 0.01 and px < b[4] - 0.01 and py > b[2] + 0.01 and py < b[5] - 0.01
           and pz > b[3] + 0.01 and pz < b[6] - 0.01 then return true end
      end
    end
  end
  return false
end
local function shown(id) return not W.anchors[id].m_blink end
-- Seen inside something: any part of it in a box, unless it has blinked out
-- (a pet that is gone is drawn a fiftieth of its size and nearly clear, where
-- it was; it is not seen there)
local function seen_inside(id)
  local a = W.anchors[id]
  if a.m_blink == 'hidden' then return false end
  return inside(outs[id])
end

-- 1. A wall close on your right: the pet on that side stops short of it,
--    easing in (never a jump while shown), and never comes inside your
--    personal space. Its slot starts inside the wall: it is never seen there.
do
  fresh(2)
  boxes = { { 2.0, -5, -10, 2.4, 5, 10 } }
  local worst_step, prev = 0, nil
  run(4, 1 / 60, nil, nil, function()
    local o = outs[ids[1]]
    assert(not seen_inside(ids[1]), 'never seen in the wall')
    if prev and shown(ids[1]) then worst_step = math.max(worst_step, math.sqrt((o.x - prev[1]) ^ 2 + (o.z - prev[2]) ^ 2)) end
    prev = shown(ids[1]) and { o.x, o.z } or nil
  end)
  local o = outs[ids[1]]
  local ax, _, bx = foot(o)
  assert(math.max(ax, bx, o.x) < 2.0 - 0.05, 'the pet on the wall side stops short of it: ' .. math.max(ax, bx, o.x))
  local hw = o.width / o.pixels_per_yalm / 2
  assert(math.sqrt(o.x ^ 2 + o.z ^ 2) >= hw + 0.6 - 1e-6, 'and keeps out of your personal space')
  assert(worst_step < 0.2, 'it eases there, no jumps: ' .. worst_step)
  local other = outs[ids[2]]
  assert(other.x < -1, 'the pet on the open side stays where it was')
  print('wall: pet 1 at', o.x, o.z)
end

-- 2. A wall with no room on your right at all: the pet swings round to where
--    there is room instead of sitting in it.
do
  fresh(1)
  W.pet.collide.swing = 2.4
  boxes = { { 1.2, -5, -10, 1.6, 5, 10 } }
  run(5, 1 / 60)
  local o = outs[ids[1]]
  local ax, _, bx = foot(o)
  assert(math.max(ax, bx, o.x) < 1.2, 'swung clear of the wall: ' .. math.max(ax, bx, o.x))
  W.pet.collide.swing = 1.2
  print('no room: pet swung to', o.x, o.z)
end

-- 2b. A pillar standing in the pet's face between the points the first
--     version looked at (its middle and both edges, from your chest): those
--     three rays miss it, and the pet sat in it. Now it is gone from the
--     pillar at once and comes back clear of it.
do
  fresh(1)
  boxes = {}
  run(3, 1 / 60)
  local o = outs[ids[1]]
  local hw = o.width / o.pixels_per_yalm / 2
  -- a pillar 0.3 across, centred on the face a little over halfway to the right edge
  local ang = 0.55 * hw / o.curve
  local lat, fwd = o.curve * math.sin(ang), o.curve * (1 - math.cos(ang))
  local cx, cz = o.x + math.cos(o.yaw) * lat + math.sin(o.yaw) * fwd, o.z - math.sin(o.yaw) * lat + math.cos(o.yaw) * fwd
  boxes = { { cx - 0.15, -5, cz - 0.15, cx + 0.15, 5, cz + 0.15 } }
  assert(inside(o), 'the pillar is in the pet as placed')
  assert(motion.pull_in(raycast, 0, 1.1, 0, o.x, o.y, o.z, o.yaw, hw, o.curve, 0.15) == 0,
    'the three rays the first version cast (middle and edges) miss it')
  local seen_in, back = 0, false
  run(3, 1 / 60, nil, nil, function()
    if seen_inside(ids[1]) then seen_in = seen_in + 1 end
    if shown(ids[1]) then back = true end
  end)
  -- the rest check comes a few times a second: the frames before it are the
  -- pillar appearing out of nowhere, which the game's world does not do
  assert(seen_in <= 7, 'gone from the pillar within a tenth of a second: shown in it ' .. seen_in .. ' frames')
  run(1, 1 / 60, nil, nil, function() assert(not seen_inside(ids[1]), 'and never in it again') end)
  assert(back and shown(ids[1]), 'back, clear of the pillar')
  print('pillar between the old rays OK')
end

-- 2c. Walking past a pillar: the pet's face would sweep through it. It
--     shuffles round it along a clear line instead, never seen inside it, not
--     for one frame, and without a blink.
do
  fresh(1)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  local o = outs[ids[1]]
  boxes = { { o.x - 0.2, -5, 2.5, o.x + 0.2, 5, 2.9 } }
  run(3, 1 / 60, nil, nil, function()
    player.z = player.z + 2 / 60
    assert(not seen_inside(ids[1]), 'never seen in the pillar while walking past it')
  end)
  run(2, 1 / 60, nil, nil, function() assert(not seen_inside(ids[1]), 'never in it') end)
  assert(shown(ids[1]), 'shown once past')
  assert((W.anchors[ids[1]].m_blinks or 0) == 0, 'round the pillar by a short clear shuffle, not a blink')
  player.x, player.z = 0, 0
  print('walking past a pillar OK')
end

-- 2d. Through a doorway: you walk through, your pets on either side would
--     float through the wall, which is too thick and too tall to squeeze,
--     shuffle or float past. They blink out on this side and back in on the
--     other (the last resort), never seen in the wall.
do
  fresh(2)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  boxes = { { -10, -5, 1.8, -0.7, 5, 2.1 }, { 0.7, -5, 1.8, 10, 5, 2.1 } }
  assert(not inside(outs[ids[1]]) and not inside(outs[ids[2]]), 'the wall is clear of the pets to begin with')
  local min_scale = { 1, 1 }
  run(4, 1 / 60, nil, nil, function()
    if player.z < 4.5 then player.z = player.z + 3 / 60 end
    for i = 1, 2 do
      assert(not seen_inside(ids[i]), 'never seen in the wall')
      local a = W.anchors[ids[i]]
      if a.m_blink then min_scale[i] = math.min(min_scale[i], a.m_bs or 0) end
    end
  end)
  run(2, 1 / 60, nil, nil, function() for i = 1, 2 do assert(not seen_inside(ids[i]), 'never in the wall') end end)
  for i = 1, 2 do
    local a, o = W.anchors[ids[i]], outs[ids[i]]
    assert((a.m_blinks or 0) >= 1 and min_scale[i] <= 0.05, 'blinked out to nothing')
    assert(o.z > 2.1 and shown(ids[i]), 'and back in past the wall: z ' .. o.z)
  end
  player.x, player.z = 0, 0
  print('doorway OK')
end

-- 2e. A tight gap: a low lintel over the pet's way, with a ceiling above it,
--     so it can neither pass under it at its size nor float over. It squeezes
--     smaller, slips under and springs back to size, without a blink and
--     without touching anything.
do
  fresh(1)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  local o = outs[ids[1]]
  local top = o.y + o.height / o.pixels_per_yalm / 2
  boxes = {
    { o.x - 0.7, top - 0.3, 2.8, o.x + 0.7, top + 0.1, 3.4 },   -- the lintel: its top 0.3 yalms would hit
    { o.x - 0.7, top + 0.45, 2.8, o.x + 0.7, top + 0.8, 3.4 },  -- a ceiling just above
  }
  local smallest = 1
  run(3, 1 / 60, nil, nil, function()
    if player.z < 5 then player.z = player.z + 2 / 60 end
    assert(not seen_inside(ids[1]), 'never seen in the lintel')
    smallest = math.min(smallest, W.anchors[ids[1]].m_sqz or 1)
  end)
  run(2, 1 / 60)
  local a = W.anchors[ids[1]]
  print('tight gap: smallest', smallest, 'blinks', a.m_blinks or 0, 'z', outs[ids[1]].z)
  assert((a.m_blinks or 0) == 0, 'a tight gap: squeezed through, no blink')
  assert(smallest < 0.8, 'it squeezed smaller')
  assert(outs[ids[1]].z > 3.4 and math.abs((a.m_sqz or 1) - 1) < 0.05, 'through, and back to its size')
  player.x, player.z = 0, 0
end

-- 2f. A low crate in the pet's way: it floats up and over it (no blink, never
--     in it) and comes back down once past.
do
  fresh(1)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  local o = outs[ids[1]]
  local base_y = o.y
  local bottom = o.y - o.height / o.pixels_per_yalm / 2
  boxes = { { o.x - 0.6, -1, 2.8, o.x + 0.6, bottom + 0.35, 3.4 } } -- 0.35 higher than its bottom edge
  local highest = base_y
  run(3.5, 1 / 60, nil, nil, function()
    if player.z < 5 then player.z = player.z + 2 / 60 end
    assert(not seen_inside(ids[1]), 'never seen in the crate')
    highest = math.max(highest, outs[ids[1]].y)
  end)
  local land = 0
  run(3, 1 / 60, nil, nil, function() land = math.max(land, math.abs(outs[ids[1]].squash)) end)
  print('landing squash', land)
  assert(land <= 0.04 + 1e-9, 'a landing squashes no more than 4 %')
  local a = W.anchors[ids[1]]
  print('low crate: rose', highest - base_y, 'blinks', a.m_blinks or 0, 'z', outs[ids[1]].z, 'now', outs[ids[1]].y - base_y)
  assert((a.m_blinks or 0) == 0, 'a low crate: floated over, no blink')
  assert(highest - base_y > 0.3, 'it rose over the crate')
  assert(outs[ids[1]].z > 3.4 and math.abs(outs[ids[1]].y - base_y) < 0.1, 'past it, and back down')
  player.x, player.z = 0, 0
end

-- 2g. Characters: someone walking through a pet's place is let pass (the pet
--     does not dodge), someone who stays in it for a couple of seconds gets
--     room, and once they have gone the pet goes back.
do
  fresh(1)
  boxes = {}
  player.x, player.z, player.rotation = 0, 0, 0
  run(3, 1 / 60)
  local o = outs[ids[1]]
  local rest_x, rest_z = o.x, o.z
  chars = { { x = o.x - 3, z = o.z, id = 900 } }
  local moved = 0
  run(2, 1 / 60, nil, nil, function()
    chars[1].x = chars[1].x + 3 / 60 -- walking straight through it at a walk
    local q = outs[ids[1]]
    moved = math.max(moved, math.sqrt((q.x - rest_x) ^ 2 + (q.z - rest_z) ^ 2))
  end)
  assert(moved < 0.05, 'a passer-by is let pass: moved ' .. moved)
  -- someone stands in its place
  chars[1].x, chars[1].z = rest_x, rest_z
  run(0.8, 1 / 60)
  local q = outs[ids[1]]
  assert(math.sqrt((q.x - rest_x) ^ 2 + (q.z - rest_z) ^ 2) < 0.05, 'not at once: they may be passing')
  run(2.2, 1 / 60)
  q = outs[ids[1]]
  local ax, az, bx, bz = motion.footprint(q.x, q.z, q.yaw, q.width / q.pixels_per_yalm / 2, q.curve)
  local d = motion.point_seg(chars[1].x, chars[1].z, ax, az, bx, bz)
  assert(d >= W.pet.collide.body, 'someone who stays gets room: ' .. d)
  chars = {}
  run(3, 1 / 60)
  q = outs[ids[1]]
  assert(math.sqrt((q.x - rest_x) ^ 2 + (q.z - rest_z) ^ 2) < 0.1, 'and it goes back once they have gone')
  chars = nil
  print('characters OK')
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
  for _, id in ipairs(ids) do
    assert((W.anchors[id].m_blinks or 0) == 0, 'a clear path: plain spring motion, no blinks')
  end
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
  run(4, 1 / 60, nil, nil, function()
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
    for _ = 1, 60 do frame(1 / 60) end
    for _ = 1, 120 do
      clock = clock + 1 / 60
      for _, other in ipairs(ids) do outs[other] = W.place(other, clock, false, other == id) end
      hy[#hy + 1] = outs[id].y
      hr, hs = math.max(hr, math.abs(outs[id].roll)), math.max(hs, math.abs(outs[id].squash))
    end
    local tail = {}
    for k = 60, #hy do tail[#tail + 1] = hy[k] end
    assert(spread_of(tail) < 1e-3 and hr < 0.036 and hs <= 0.04, 'pointed at: held still')
    local _, lr = nil, 0
    lr = math.abs(outs[id].roll)
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
