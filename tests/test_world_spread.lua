-- Pure policy test: no game, no camera, no core.
--
-- Pets are kept apart in the world by M.pet.gap, which is a different question
-- from whether they cover each other on screen. A camera looking along the arc
-- of pets squashes a comfortable world spacing into nothing, and that is the
-- case this covers: same pets, same slots, one camera where they are spread
-- across the view and one where they are stacked up behind each other.
package.path = 'lua/?.lua;' .. package.path
for _, name in ipairs({ 'animation', 'settings' }) do
  package.preload[name] = function() return {} end
end

-- The camera the policy is handed. A real one comes from the core
-- (ghostty.view); this is the same table, filled by hand.
local view = {}
local function look_from(ex, ey, ez, tx, ty, tz)
  local fx, fy, fz = tx - ex, ty - ey, tz - ez
  local n = math.sqrt(fx * fx + fy * fy + fz * fz)
  fx, fy, fz = fx / n, fy / n, fz / n
  -- right = forward x world-up, normalised; up = right x forward
  local rx, ry, rz = fz, 0, -fx
  local rn = math.sqrt(rx * rx + rz * rz)
  rx, ry, rz = rx / rn, 0, rz / rn
  view.x, view.y, view.z = ex, ey, ez
  view.fx, view.fy, view.fz = fx, fy, fz
  view.rx, view.ry, view.rz = rx, ry, rz
  view.ux = ry * fz - rz * fy
  view.uy = rz * fx - rx * fz
  view.uz = rx * fy - ry * fx
  view.tan_x, view.tan_y = 0.7, 0.4
  view.width, view.height = 2560, 1440
end

local cam_x, cam_z = 0, -8
local player = { x = 0, y = 0, z = 0, rotation = 0, speed = 0 }

ghostty = {
  view = function(buf)
    if buf then for k, v in pairs(view) do buf[k] = v end return buf end
    return view
  end,
  camera = function() return cam_x, 0, cam_z end,
  player = function(buf)
    if buf then for k, v in pairs(player) do buf[k] = v end return buf end
    return player
  end,
  zone = function() return 1 end,
  object = function() return nil end,
  env = function() return nil end,          -- no daylight: lighting stays neutral
  target = function() return nil end,
  set_rotation = function() end,
}

local W = dofile('lua/world.lua')

-- Four pets, exactly as the core keeps them: a plain anchor table each.
local ids = { 1, 2, 3, 4 }
local function make_pets()
  for _, id in ipairs(ids) do
    W.anchors[id] = { kind = 'pet', phase = 0, order = id }
  end
  W._pet_ids = nil
end
make_pets()

local function place_all(t)
  local out = {}
  for _, id in ipairs(ids) do
    out[id] = W.place(id, t, false)
  end
  return out
end

-- Screen box of a placement, the same maths the policy uses internally.
local function box(pl)
  local hw = pl.width / pl.pixels_per_yalm / 2
  local hh = pl.height / pl.pixels_per_yalm / 2
  local sy, cy = math.sin(pl.yaw), math.cos(pl.yaw)
  local sp, cp = math.sin(pl.pitch or 0), math.cos(pl.pitch or 0)
  local minx, miny, maxx, maxy
  for i = 0, 3 do
    local ex = (i % 2 == 0) and -1 or 1
    local ey = (i < 2) and -1 or 1
    local dx = pl.x + ex * hw * cy + ey * hh * (-sy * sp) - view.x
    local dy = pl.y + ey * hh * cp - view.y
    local dz = pl.z + ex * hw * (-sy) + ey * hh * (-cy * sp) - view.z
    local depth = dx * view.fx + dy * view.fy + dz * view.fz
    if depth < 0.05 then return nil end
    local sx = ((dx * view.rx + dy * view.ry + dz * view.rz) / (depth * view.tan_x) + 1) / 2 * view.width
    local st = (1 - (dx * view.ux + dy * view.uy + dz * view.uz) / (depth * view.tan_y)) / 2 * view.height
    if not minx or sx < minx then minx = sx end
    if not maxx or sx > maxx then maxx = sx end
    if not miny or st < miny then miny = st end
    if not maxy or st > maxy then maxy = st end
  end
  return minx, miny, maxx, maxy
end

local function covered(a, b)
  local ax0, ay0, ax1, ay1 = box(a)
  local bx0, by0, bx1, by1 = box(b)
  if not ax0 or not bx0 then return 0 end
  local w = math.min(ax1, bx1) - math.max(ax0, bx0)
  local h = math.min(ay1, by1) - math.max(ay0, by0)
  if w <= 0 or h <= 0 then return 0 end
  return w * h / ((ax1 - ax0) * (ay1 - ay0))
end

local function worst_pair(pls)
  local worst = 0
  for i = 1, #ids do
    for j = 1, #ids do
      if i ~= j then
        local c = covered(pls[ids[i]], pls[ids[j]])
        if c > worst then worst = c end
      end
    end
  end
  return worst
end

-- Run the springs out so the pets are sitting in their slots. One clock for
-- the whole test, only ever moving forward: stepping it backwards makes the
-- springs react to a time jump, which looks exactly like panels refusing to
-- settle.
local clock = 0
local function settle(seconds, step)
  local target, last = clock + seconds, nil
  while clock < target do
    clock = clock + step
    last = place_all(clock)
  end
  return last, clock
end
local function tick(step)
  clock = clock + step
  return place_all(clock)
end

-- 1. With the arrangement off, a camera down the arc leaves pets covering
--    each other: this is the complaint, reproduced.
W.pet.spread.enabled = false
look_from(0, 1.6, -9, 0, 1.6, 0)
local off_pls = settle(6, 1 / 30)
local off_worst = worst_pair(off_pls)

-- 2. With it on, from the same camera, they step aside.
for _, id in ipairs(ids) do W.forget(id) end
make_pets()
W.pet.spread.enabled = true
local on_pls = settle(6, 1 / 30)
local on_worst = worst_pair(on_pls)

print(string.format('worst overlap: off %.3f, on %.3f', off_worst, on_worst))
assert(on_worst <= off_worst + 1e-6,
  string.format('spreading must not make overlap worse (off %.3f, on %.3f)', off_worst, on_worst))
assert(on_worst <= math.max(W.pet.spread.overlap * 1.5, off_worst * 0.9),
  string.format('spreading should leave little covered (got %.3f)', on_worst))

-- 3. It must settle. With the camera still, the pets must stop moving: the
--    thing this feature must never do is keep them crawling. The bob is
--    deliberate movement, so it is turned off for the measurement rather than
--    tolerated -- otherwise this asserts nothing.
W.pet.bob, W.pet.drift = 0, 0
settle(3, 1 / 30)                         -- let the lift finish arriving
-- snapshot by value: placement() hands back one table per anchor and rewrites
-- it every call, so holding the table and reading it later reads the future
local before = {}
do
  local pls = tick(1 / 30)
  for _, id in ipairs(ids) do before[id] = { x = pls[id].x, y = pls[id].y, z = pls[id].z } end
end
local after = tick(1 / 30)
local moved = 0
for _, id in ipairs(ids) do
  local d = math.abs(after[id].x - before[id].x)
    + math.abs(after[id].y - before[id].y)
    + math.abs(after[id].z - before[id].z)
  if d > moved then moved = d end
end
assert(moved < 0.005, string.format('pets must settle with a still camera (moved %.4f yalms)', moved))

-- 4. A pet never gives up more than `max` from its slot, however bad it gets.
for _, id in ipairs(ids) do
  local anchor = W.anchors[id]
  assert(math.abs(anchor.sp or 0) <= W.pet.spread.max + 1e-9,
    string.format('pet %d stepped aside %.3f, past the %.3f limit', id, anchor.sp or 0, W.pet.spread.max))
end

-- 5. Turned off, no pet steps aside at all.
for _, id in ipairs(ids) do W.forget(id) end
make_pets()
W.pet.spread.enabled = false
settle(2, 1 / 30)
for _, id in ipairs(ids) do
  assert((W.anchors[id].sp or 0) == 0, 'nothing steps aside while spread.enabled is false')
end

print('world spread OK')
