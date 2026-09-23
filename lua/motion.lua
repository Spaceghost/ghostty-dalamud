-- How world panels move and keep out of the way: the springs, the idle bob and
-- sway, squash and settle, and collision (panels against each other, against
-- your character, and against the world through the game's own raycasts).
--
-- Pure maths, no game and no core: lua/world.lua feeds it every frame and
-- tests/test_motion.lua checks it on its own. Nothing here allocates a table
-- per call, so placing panels every frame makes no garbage.
--
-- Coordinates are yalms with +Y up. A panel's yaw is the direction its
-- readable side faces: its front normal is (sin yaw, 0, cos yaw) and its right
-- (cos yaw, 0, -sin yaw), as in core/world.nelua.

local M = {}

local sin, cos, sqrt, exp, abs, min, max = math.sin, math.cos, math.sqrt, math.exp, math.abs, math.min, math.max

local function clamp(x, lo, hi) return x < lo and lo or (x > hi and hi or x) end
M.clamp = clamp
local EMPTY_T = {}

-- Springs ------------------------------------------------------------------------------------------

-- The largest angular frequency a spring may have (k = 25600): stiffer than any
-- panel needs, and the bound that keeps the substep count finite.
local W_MAX = 320
local STEPS_MAX = 64

-- One damped spring x'' = w^2 (target - x) - 2 zeta w x', w = 2 sqrt(k) (the
-- same stiffness scale lua/world.lua always used), from (x, v) over dt seconds.
-- Integrated semi-implicitly (the damping implicitly) in substeps of at most
-- 1/120 s and short enough that h * w <= 0.5, well inside the method's stable
-- range: the spring never runs away, whatever the stiffness, the damping, the
-- frame rate, or a hitch (dt is taken as at most 0.1 s). The same motion at
-- 30, 60 or 144 fps, to within the substep size.
function M.step(x, v, target, dt, k, zeta)
  if not (dt > 0) then return x, v end
  if dt > 0.1 then dt = 0.1 end
  local w = 2 * sqrt(max(k or 0, 0))
  if w > W_MAX then w = W_MAX end
  local steps = max(1, math.ceil(dt * 120), math.ceil(dt * w / 0.5))
  if steps > STEPS_MAX then steps = STEPS_MAX end
  local h = dt / steps
  local z = zeta or 1
  if z < 0 then z = 0 end
  local ww, zw = w * w, 2 * z * w
  -- the damping is taken implicitly, so however heavy it is it only ever
  -- takes speed away (explicit, 2 zeta w h > 2 would flip and grow it)
  local damp = 1 / (1 + zw * h)
  for _ = 1, steps do
    v = (v + ww * (target - x) * h) * damp
    x = x + v * h
  end
  return x, v
end

-- Exponential follow toward `target` with time constant tau seconds (0: at
-- once). Unconditionally stable: it only ever closes part of the gap.
function M.follow(x, target, dt, tau)
  if not tau or tau <= 1e-3 or not (dt > 0) then return target end
  return x + (target - x) * (1 - exp(-dt / tau))
end

-- Animations ------------------------------------------------------------------------------------
-- Every change a pet shows that is not the follow spring goes through one of
-- these two, so each is eased (no linear snaps, no jumps in position, size or
-- opacity), frame-rate independent, bounded, and settles in a time that is
-- said up front. Each property has one of them; layers that add up (the
-- follow spring's height, the bob, a hike's lift) are separate properties,
-- each smooth on its own. The state lives in the anchor under `m_an`, one
-- small table per property, made once. Active ones are listed by
-- M.active_anims for /term world anim.

-- A critically damped glide toward `goal`, reaching it (within 2 %) in about
-- `time` seconds with no overshoot, its speed never above `vmax` (units per
-- second; nil: no limit). A goal that moves less than `dead` from the one it
-- is gliding to is ignored, so noise in what asks for it never makes it
-- twitch at rest. `time` 0: it is at the goal at once (Reduce motion).
-- -> the value this frame.
function M.anim(a, key, goal, dt, time, vmax, dead)
  local an = a.m_an
  if not an then an = {} a.m_an = an end
  local s = an[key]
  if not s then
    s = { x = goal, v = 0, goal = goal }
    an[key] = s
    return goal
  end
  if math.abs(goal - s.goal) > (dead or 0) then s.goal = goal end
  if not time or time <= 0 then
    s.x, s.v = s.goal, 0
    return s.x
  end
  if not (dt > 0) then return s.x end
  if dt > 0.1 then dt = 0.1 end
  local w = 5.8 / time -- (1 + w t) e^-wt reaches 2 % at w t = 5.8
  local steps = max(1, math.ceil(dt * 120), math.ceil(dt * w / 0.5))
  if steps > STEPS_MAX then steps = STEPS_MAX end
  local h = dt / steps
  local ww, zw = w * w, 2 * w
  local damp = 1 / (1 + zw * h)
  local x, v = s.x, s.v
  for _ = 1, steps do
    v = (v + ww * (s.goal - x) * h) * damp
    if vmax and v > vmax then v = vmax elseif vmax and v < -vmax then v = -vmax end
    x = x + v * h
  end
  s.x, s.v = x, v
  return x
end

-- The same with its speed, for callers that bank or squash on it.
function M.anim_state(a, key)
  local an = a.m_an
  local s = an and an[key]
  if not s then return nil end
  return s.x, s.v, s.goal
end

-- Put an animation where it is to be, at rest (a blink landing somewhere new).
function M.anim_set(a, key, value)
  local an = a.m_an
  if not an then an = {} a.m_an = an end
  local s = an[key]
  if not s then an[key] = { x = value, v = 0, goal = value } return end
  s.x, s.v, s.goal = value, 0, value
end

-- A tween from 0 to 1 (or back) over `time` seconds on a smootherstep curve:
-- it starts and stops with no speed at all. `on`: toward 1 or toward 0.
-- -> the eased value, and the raw progress.
function M.tween(a, key, on, dt, time)
  local an = a.m_an
  if not an then an = {} a.m_an = an end
  local s = an[key]
  if not s then s = { p = on and 1 or 0 } an[key] = s end
  local target = on and 1 or 0
  if not time or time <= 0 then s.p = target
  elseif dt > 0 then
    local step = math.min(dt, 0.1) / time
    if s.p < target then s.p = math.min(target, s.p + step) elseif s.p > target then s.p = math.max(target, s.p - step) end
  end
  local p = s.p
  return p * p * p * (p * (p * 6 - 15) + 10), p
end

-- The animations of anchor `a` still moving: key, value, goal, speed, into
-- `out` (a reused table of reused rows). -> how many.
function M.active_anims(a, out)
  local n = 0
  for key, s in pairs(a.m_an or EMPTY_T) do
    local moving
    if s.p then moving = s.p > 0 and s.p < 1
    else moving = math.abs(s.x - s.goal) > 1e-3 or math.abs(s.v) > 1e-3 end
    if moving then
      n = n + 1
      local row = out[n]
      if not row then row = {} out[n] = row end
      row.key, row.x, row.goal, row.v = key, s.x or s.p, s.goal or 1, s.v or 0
    end
  end
  return n
end

-- The idle bob -----------------------------------------------------------------------------------

-- A pet's own pace, from its phase: 0.85 .. 1.15 times `speed`, so no two pets
-- bob in lockstep.
local GOLDEN = 0.6180339887498949
function M.pace(phase, speed)
  return speed * (0.85 + 0.3 * ((phase * GOLDEN) % 1))
end

-- Two sines at an irrational ratio: never quite repeats, never jerks. In
-- [-amp, amp].
function M.bob(t, phase, amp, speed)
  if not amp or amp == 0 then return 0 end
  local r = M.pace(phase, speed or 0.9)
  return amp * (0.72 * sin(t * r + phase) + 0.28 * sin(t * r * 1.618 + phase * 2.3))
end

-- A lean that sways a little on its own beat: in [-amp, amp].
function M.sway(t, phase, amp, speed)
  if not amp or amp == 0 then return 0 end
  local r = M.pace(phase * 1.37 + 0.5, speed or 0.6)
  return amp * sin(t * r + phase * 1.9)
end

-- A pet's own small tilt, like a photo pinned by hand: in [-1, 1], fixed per phase.
function M.persona(phase)
  return sin(phase * 3.7 + 0.4)
end

-- Squash and settle ------------------------------------------------------------------------------
-- A panel's squash is a spring of its own around `target` (0 at rest): bumps and
-- landings kick its velocity, it wobbles and settles. Positive is wider and
-- shorter (the core keeps the area: core/world.nelua world_basis). State lives
-- in the anchor as `m_sq` and `m_sq_v` (m_: never saved, lua/world.lua).

function M.squash_kick(a, amount)
  a.m_sq_v = (a.m_sq_v or 0) + amount
end

-- -> the squash this frame, never beyond +-lim (a kick that would pass it stops
-- there, with no bounce off the limit).
function M.squash(a, target, dt, k, zeta, lim)
  local x, v = M.step(a.m_sq or 0, a.m_sq_v or 0, target or 0, dt, k, zeta)
  if x > lim then x, v = lim, min(v, 0) elseif x < -lim then x, v = -lim, max(v, 0) end
  a.m_sq, a.m_sq_v = x, v
  return x
end

-- Shapes on the ground plane ---------------------------------------------------------------------

-- A panel's footprint: the chord of its face seen from above, from its left
-- edge to its right. A curved panel's edges bend `curve` toward its front.
-- -> ax, az, bx, bz
function M.footprint(x, z, yaw, hw, curve)
  local rx, rz = cos(yaw), -sin(yaw)
  local fx, fz = sin(yaw), cos(yaw)
  local lat, fwd = hw, 0
  if curve and curve > 0.01 then
    local ang = hw / curve
    lat, fwd = curve * sin(ang), curve * (1 - cos(ang))
  end
  return x - rx * lat + fx * fwd, z - rz * lat + fz * fwd,
         x + rx * lat + fx * fwd, z + rz * lat + fz * fwd
end

-- The point of segment a-b nearest to (px, pz). -> distance, x, z
function M.point_seg(px, pz, ax, az, bx, bz)
  local dx, dz = bx - ax, bz - az
  local len2 = dx * dx + dz * dz
  local t = 0
  if len2 > 1e-12 then t = clamp(((px - ax) * dx + (pz - az) * dz) / len2, 0, 1) end
  local cx, cz = ax + dx * t, az + dz * t
  return sqrt((px - cx) ^ 2 + (pz - cz) ^ 2), cx, cz
end

-- The nearest points of segments p1-q1 and p2-q2 (Ericson, Real-Time
-- Collision Detection 5.1.9, on the plane). -> distance, x1, z1, x2, z2
function M.seg_seg(p1x, p1z, q1x, q1z, p2x, p2z, q2x, q2z)
  local d1x, d1z = q1x - p1x, q1z - p1z
  local d2x, d2z = q2x - p2x, q2z - p2z
  local rx, rz = p1x - p2x, p1z - p2z
  local a = d1x * d1x + d1z * d1z
  local e = d2x * d2x + d2z * d2z
  local f = d2x * rx + d2z * rz
  local s, t
  if a <= 1e-12 and e <= 1e-12 then
    s, t = 0, 0
  elseif a <= 1e-12 then
    s, t = 0, clamp(f / e, 0, 1)
  else
    local c = d1x * rx + d1z * rz
    if e <= 1e-12 then
      t, s = 0, clamp(-c / a, 0, 1)
    else
      local b = d1x * d2x + d1z * d2z
      local denom = a * e - b * b
      s = denom > 1e-12 and clamp((b * f - c * e) / denom, 0, 1) or 0
      t = (b * s + f) / e
      if t < 0 then t, s = 0, clamp(-c / a, 0, 1)
      elseif t > 1 then t, s = 1, clamp((b - c) / a, 0, 1) end
    end
  end
  local x1, z1 = p1x + d1x * s, p1z + d1z * s
  local x2, z2 = p2x + d2x * t, p2z + d2z * t
  return sqrt((x1 - x2) ^ 2 + (z1 - z2) ^ 2), x1, z1, x2, z2
end

-- Whether two height ranges (centre, half height) come within `gap` of each other.
local function heights_meet(ya, hha, yb, hhb, gap)
  return abs(ya - yb) < hha + hhb + (gap or 0)
end
M.heights_meet = heights_meet

-- How far panel A must move on the ground plane to keep `gap` yalms from panel
-- B, and which way: -> depth, nx, nz (depth 0 when they are clear, or when one
-- is above the other). Panels are footprints (M.footprint): two pets side by
-- side keep `gap` between their nearest edges, not between their centres, so
-- they can nestle close without touching.
--
-- Apart, they are pushed along the line between their nearest points, and
-- that is exact: moving A that way by s leaves at least d + s between them
-- (the nearest point of a convex set). Crossed, they are pushed along the line
-- between their centres by the least distance that clears them, found by
-- halving (a crossed pair does not separate one for one with the push).
function M.panel_push(ax0, az0, ax1, az1, ay, ahh, bx0, bz0, bx1, bz1, by, bhh, gap)
  if not heights_meet(ay, ahh, by, bhh, 0) then return 0, 0, 0 end
  local d, x1, z1, x2, z2 = M.seg_seg(ax0, az0, ax1, az1, bx0, bz0, bx1, bz1)
  if d >= gap then return 0, 0, 0 end
  if d > 1e-4 then
    return gap - d, (x1 - x2) / d, (z1 - z2) / d
  end
  local nx, nz = (ax0 + ax1 - bx0 - bx1) * 0.5, (az0 + az1 - bz0 - bz1) * 0.5
  local l = sqrt(nx * nx + nz * nz)
  if l < 1e-6 then
    -- one exactly on the other: along A's own face
    nx, nz = ax1 - ax0, az1 - az0
    l = sqrt(nx * nx + nz * nz)
    if l < 1e-6 then nx, nz, l = 1, 0, 1 end
  end
  nx, nz = nx / l, nz / l
  -- far enough along n always clears them: both lengths and the gap
  local la = sqrt((ax1 - ax0) ^ 2 + (az1 - az0) ^ 2)
  local lb = sqrt((bx1 - bx0) ^ 2 + (bz1 - bz0) ^ 2)
  local lo, hi = 0, la + lb + gap
  for _ = 1, 14 do
    local mid = (lo + hi) * 0.5
    local dm = M.seg_seg(ax0 + nx * mid, az0 + nz * mid, ax1 + nx * mid, az1 + nz * mid, bx0, bz0, bx1, bz1)
    if dm >= gap then hi = mid else lo = mid end
  end
  return hi, nx, nz
end

-- How far a panel's footprint must move to keep `radius` yalms from the point
-- (px, pz) (a character standing there): -> depth, nx, nz (away from it).
-- Moving the footprint away from its nearest point is exact (the nearest point
-- of a convex set). A point right on the footprint goes off it square to the
-- face, toward the side (away_x, away_z) points to.
function M.point_push(px, pz, radius, ax, az, bx, bz, away_x, away_z)
  local d, cx, cz = M.point_seg(px, pz, ax, az, bx, bz)
  if d >= radius then return 0, 0, 0 end
  local nx, nz
  if d > 1e-4 then
    nx, nz = (cx - px) / d, (cz - pz) / d
  else
    nx, nz = -(bz - az), bx - ax
    local l = sqrt(nx * nx + nz * nz)
    if l < 1e-6 then
      nx, nz, l = away_x or 1, away_z or 0, sqrt((away_x or 1) ^ 2 + (away_z or 0) ^ 2)
      if l < 1e-6 then nx, nz, l = 1, 0, 1 end
    elseif nx * (away_x or 0) + nz * (away_z or 0) < 0 then
      nx, nz = -nx, -nz
    end
    nx, nz = nx / l, nz / l
  end
  return radius - d, nx, nz
end

-- A contact: velocity (vx, vz) meeting a surface of normal (nx, nz) loses the
-- part going into it, and bounces back `bounce` of it. -> vx, vz, the speed
-- that went into it (0 when it was already moving away).
function M.contact(vx, vz, nx, nz, bounce)
  local into = vx * nx + vz * nz
  if into >= 0 then return vx, vz, 0 end
  local k = (1 + (bounce or 0)) * into
  return vx - k * nx, vz - k * nz, -into
end

-- The world (game collision) -----------------------------------------------------------------------
-- `cast(ox, oy, oz, dx, dy, dz, max)` is ghostty.raycast: the distance to the
-- first hit along the (not necessarily unit) direction within `max` yalms, or
-- nil for none. Every function here says how many rays it cast, so the caller
-- can keep to a budget per frame.

-- A point on a panel's face seen from above: `s` from -1 (left edge) to 1
-- (right edge) along its (curved) width. -> x, z
function M.face_point(x, z, yaw, hw, curve, s)
  local rx, rz = cos(yaw), -sin(yaw)
  local fx, fz = sin(yaw), cos(yaw)
  local lat, fwd = hw * s, 0
  if curve and curve > 0.01 then
    local ang = hw * s / curve
    lat, fwd = curve * sin(ang), curve * (1 - cos(ang))
  end
  return x + rx * lat + fx * fwd, z + rz * lat + fz * fwd
end

-- How many points across a panel `hw` yalms half wide the rays look at: one
-- every `spacing` yalms or so, never fewer than 3 (both edges and the middle).
function M.columns(hw, spacing, most)
  local n = math.ceil(2 * hw / (spacing or 0.45)) + 1
  if n < 3 then n = 3 end
  if most and n > most then n = most end
  return n
end

-- How much nearer to O (the character's chest) a panel centred at T must come
-- so that every point of a grid over its face (`cols` across it, at `rows`
-- heights: 1 is the middle, 2 a quarter up and down from it, 3 all three) keeps
-- `margin` yalms in front of whatever the rays from O to it hit first. Moving
-- the panel toward O along O-T by `pull` moves each point that much along the
-- same line, which brings it nearer along its own ray by pull * cos(angle
-- between them). -> pull (0 when the panel fits where it is), rays cast.
function M.chest_pull(cast, ox, oy, oz, tx, ty, tz, yaw, hw, hh, curve, margin, cols, rows)
  local ux, uz = tx - ox, tz - oz
  local ul = sqrt(ux * ux + uz * uz)
  if ul < 1e-4 then return 0, 0 end
  ux, uz = ux / ul, uz / ul
  cols, rows = cols or 3, rows or 1
  local pull, rays = 0, 0
  for r = 1, rows do
    local py = ty
    if rows == 2 then py = ty + (r == 1 and -0.5 or 0.5) * hh
    elseif rows >= 3 then py = ty + (r - 2) * 0.6 * hh end
    for c = 0, cols - 1 do
      local px, pz = M.face_point(tx, tz, yaw, hw, curve, -1 + 2 * c / (cols - 1))
      local dx, dy, dz = px - ox, py - oy, pz - oz
      local d = sqrt(dx * dx + dy * dy + dz * dz)
      if d > 1e-4 then
        rays = rays + 1
        local hit = cast(ox, oy, oz, dx, dy, dz, d + margin)
        if hit and hit < d + margin then
          local need = d + margin - hit               -- how far this point must come back along its ray
          local along = (dx * ux + dz * uz) / d         -- cos between its ray and the pull
          if along < 0.25 then along = 0.25 end         -- a point nearly square to the pull: pull hard, not forever
          local p = need / along
          if p > pull then pull = p end
        end
      end
    end
  end
  return pull, rays
end

-- The centre and both edges at mid height only (what the first version
-- looked at; kept for callers with few rays to spare).
function M.pull_in(cast, ox, oy, oz, tx, ty, tz, yaw, hw, curve, margin)
  return M.chest_pull(cast, ox, oy, oz, tx, ty, tz, yaw, hw, 0, curve, margin, 3, 1)
end

-- Whether anything crosses a panel's face: rays along it, from its left edge
-- through its middle to its right edge (two segments, following the curve),
-- at `rows` heights (1: the middle; 2: near its bottom and top edges; 3: all
-- three, so a short post under its middle is seen too), and back the
-- other way too when `both` (the game's collision is one-sided: a ray that
-- starts inside a pillar does not see it). This is what catches a pillar
-- standing in the panel between the points the rays from the chest look at.
-- -> clear, rays cast.
function M.span_clear(cast, x, y, z, yaw, hw, hh, curve, rows, both)
  local lx, lz = M.face_point(x, z, yaw, hw, curve, -1)
  local rx, rz = M.face_point(x, z, yaw, hw, curve, 1)
  local rays = 0
  rows = rows or 1
  for r = 1, rows do
    local py = y
    if rows == 2 then py = y + (r == 1 and -0.9 or 0.9) * hh
    elseif rows >= 3 then py = y + (r - 2) * 0.9 * hh end
    for seg = 0, 1 do
      local ax, az, bx, bz = lx, lz, x, z
      if seg == 1 then ax, az, bx, bz = x, z, rx, rz end
      local dx, dz = bx - ax, bz - az
      local d = sqrt(dx * dx + dz * dz)
      if d > 1e-4 then
        rays = rays + 1
        local hit = cast(ax, py, az, dx, 0, dz, d)
        if hit and hit < d then return false, rays end
        if both then
          rays = rays + 1
          hit = cast(bx, py, bz, -dx, 0, -dz, d)
          if hit and hit < d then return false, rays end
        end
      end
    end
  end
  return true, rays
end

-- Whether a panel can move from pose 0 to pose 1 in a straight line without
-- anything in between: its middle both ways, both its edges forward, at mid
-- height (each with `margin` beyond the end). -> clear, rays cast.
function M.path_clear(cast, x0, y0, z0, yaw0, x1, y1, z1, yaw1, hw, curve, margin)
  local rays = 0
  margin = margin or 0
  for i = 0, 2 do
    local ax, az, bx, bz = x0, z0, x1, z1
    if i > 0 then
      local s = i == 1 and -1 or 1
      ax, az = M.face_point(x0, z0, yaw0, hw, curve, s)
      bx, bz = M.face_point(x1, z1, yaw1, hw, curve, s)
    end
    local dx, dy, dz = bx - ax, y1 - y0, bz - az
    local d = sqrt(dx * dx + dy * dy + dz * dz)
    if d > 1e-4 then
      rays = rays + 1
      local hit = cast(ax, y0, az, dx, dy, dz, d + margin)
      if hit and hit < d + margin then return false, rays end
      if i == 0 then
        rays = rays + 1
        hit = cast(bx, y1, bz, -dx, -dy, -dz, d + margin)
        if hit and hit < d + margin then return false, rays end
      end
    end
  end
  return true, rays
end

-- Openness: where around you there is room -----------------------------------------------------
-- Pets go where it is open rather than solving collisions frame by frame.
-- A ring of rays round you at a few heights, now and then, says how far each
-- direction is open, counting only what is large: a wall, a building, a
-- cliff, a big rock, a trunk, a post. Grass, kerbs, clutter and gaps do not
-- count.

-- rows[h][i]: the distance the ray at height h in direction i (of n round)
-- hit something, or false. -> free[i], filled: how far direction i is open,
-- counting a hit only when it is
--   tall: the same direction hits at another height within `near` of it, and
--   wide or close: a direction beside it hits too within 1 yalm, or it is
--   within `close` yalms (where the ring's directions are too far apart to
--   hit a post twice).
-- `tall` is scratch space the caller keeps (no tables made here).
function M.classify_ring(rows, nh, n, reach, tall, free, near, close)
  near, close = near or 0.6, close or 3
  for i = 1, n do
    local best = false
    for h = 1, nh do
      local d = rows[h][i]
      if d then
        local count = 0
        for k = 1, nh do
          local e = rows[k][i]
          if e and math.abs(e - d) <= near then count = count + 1 end
        end
        if count >= 2 and (not best or d < best) then best = d end
      end
    end
    tall[i] = best
  end
  for i = 1, n do
    local d = tall[i]
    local open = reach
    if d then
      local l, r = tall[(i - 2) % n + 1], tall[i % n + 1]
      if d <= close or (l and math.abs(l - d) <= 1) or (r and math.abs(r - d) <= 1) then open = d end
    end
    free[i] = open
  end
end

-- How much room a panel `hw` half wide has with its face `d` from the centre
-- of the ring, facing it, in direction `phi` (radians, x = sin, z = cos):
-- the least, over the ring directions its face spans, of how far that
-- direction is open past the face plus `margin`. Negative: it would be in
-- something. Directions are (i - 1) * 2 pi / n.
function M.clearance(free, n, phi, d, hw, margin)
  if d < 1e-3 then return -math.huge end
  local half = math.atan(hw + margin, d)
  local bin = 2 * math.pi / n
  local worst = math.huge
  for i = 1, n do
    local th = (i - 1) * bin
    local dl = (th - phi + math.pi) % (2 * math.pi) - math.pi
    if math.abs(dl) <= half + bin * 0.5 then
      local along = math.cos(dl)
      if along < 0.3 then along = 0.3 end
      local c = free[i] - (d / along + margin)
      if c < worst then worst = c end
    end
  end
  return worst
end

-- What crosses a panel's face, row by row: rays along it (left edge, middle,
-- right edge, following the curve) near its bottom edge, through its middle
-- and near its top edge. The middle and top rows are looked at each way (a ray
-- that starts inside something does not see it) and count when both hit, or
-- one does and a second ray a little higher agrees: one stray answer from the
-- collision is not a wall.
-- The bottom row is looked at one way. -> low, mid, high (each true when that
-- row is crossed), rays cast. Low alone is clutter under it (grass tips, a
-- short post, a crate): something to float over if it can, never a reason to
-- blink. Mid or high is large: a wall, a pillar, a beam.
function M.face_rows(cast, x, y, z, yaw, hw, hh, curve)
  local lx, lz = M.face_point(x, z, yaw, hw, curve, -1)
  local rx, rz = M.face_point(x, z, yaw, hw, curve, 1)
  local rays = 0
  local low, mid, high = false, false, false
  for r = 1, 3 do
    local py = y + (r - 2) * 0.9 * hh
    local hit = false
    for seg = 0, 1 do
      if not hit then
        local ax, az, bx, bz = lx, lz, x, z
        if seg == 1 then ax, az, bx, bz = x, z, rx, rz end
        local dx, dz = bx - ax, bz - az
        local dd = math.sqrt(dx * dx + dz * dz)
        if dd > 1e-4 then
          rays = rays + 1
          local h = cast(ax, py, az, dx, 0, dz, dd)
          local fwd = h and h < dd or false
          if r == 1 then
            hit = fwd
          else
            -- each way (a ray that starts inside something does not see it),
            -- and one way alone confirmed by a second ray a little higher
            rays = rays + 1
            h = cast(bx, py, bz, -dx, 0, -dz, dd)
            local back = h and h < dd or false
            if fwd and back then hit = true
            elseif fwd or back then
              rays = rays + 1
              local py2 = py + 0.12 * hh
              if fwd then h = cast(ax, py2, az, dx, 0, dz, dd) else h = cast(bx, py2, bz, -dx, 0, -dz, dd) end
              hit = h and h < dd or false
            end
          end
        end
      end
    end
    if r == 1 then low = hit elseif r == 2 then mid = hit else high = hit end
  end
  return low, mid, high, rays
end

-- What is in the way of a panel moving from pose 0 to pose 1: its middle at
-- mid height and at its top, each counted when a ray each way hits (as
-- face_rows), and near its bottom forward (each with `margin` beyond the
-- end). -> low, large, rays cast.
function M.path_rows(cast, x0, y0, z0, x1, y1, z1, hh, margin)
  margin = margin or 0
  local dx, dy, dz = x1 - x0, y1 - y0, z1 - z0
  local dd = math.sqrt(dx * dx + dy * dy + dz * dz)
  if dd < 1e-4 then return false, false, 0 end
  local rays, large, low = 0, false, false
  local len = dd + margin
  for k = 0, 1 do
    if not large then
      local oy = k * 0.9 * hh
      rays = rays + 2
      local h = cast(x0, y0 + oy, z0, dx, dy, dz, len)
      local fwd = h and h < len or false
      h = cast(x1, y1 + oy, z1, -dx, -dy, -dz, len)
      local back = h and h < len or false
      if fwd and back then large = true
      elseif fwd or back then
        rays = rays + 1
        local oy2 = oy + 0.12 * hh
        if fwd then h = cast(x0, y0 + oy2, z0, dx, dy, dz, len) else h = cast(x1, y1 + oy2, z1, -dx, -dy, -dz, len) end
        large = h and h < len or false
      end
    end
  end
  if not large then
    rays = rays + 1
    local h = cast(x0, y0 - 0.9 * hh, z0, dx, dy, dz, len)
    low = h and h < len or false
  end
  return low, large, rays
end

-- The floor and the ceiling at a panel centred at (x, y, z) with half height
-- hh: -> how far up it must go (negative: down) to keep `margin` from both,
-- rays cast. Floor wins when there is no room for both: a panel sunk into the
-- ground looks worse than one brushing a ceiling.
function M.headroom(cast, x, y, z, hh, margin, reach)
  local rays = 2
  local down = cast(x, y, z, 0, -1, 0, hh + margin + (reach or 1))
  local up = cast(x, y, z, 0, 1, 0, hh + margin)
  local dy = 0
  if up and up < hh + margin then dy = up - hh - margin end
  if down and down < hh + margin then
    local lift = hh + margin - down
    if lift > dy then dy = lift end
  end
  return dy, rays
end

return M
