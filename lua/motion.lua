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
  -- not (dt > 0) rather than dt <= 0, here and below: a NaN dt stops too
  if not (dt > 0) then return x, v end -- luacheck: ignore 581
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
  if not tau or tau <= 1e-3 or not (dt > 0) then return target end -- luacheck: ignore 581
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
  if not (dt > 0) then return s.x end -- luacheck: ignore 581
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

-- Put an animation where it is to be, at rest (a jump to somewhere new).
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

-- Walls: a panel that would go into one hangs on it like a painting ---------------------------
-- Paper, not physics: rather than finding a way round a wall, a pet that meets
-- one flattens against it and slides along the wallpaper as you move, until
-- its place is clear again.

-- A level ray from S along unit (ux, uz), `reach` long: -> the hit x, z or nil.
local function probe_hit(cast, sx, y, sz, ux, uz, reach)
  local e = cast(sx, y, sz, ux, 0, uz, reach)
  if not e then return nil end
  return sx + ux * e, sz + uz * e
end

-- The wall between O (your chest, at the panel's height) and T (where the
-- panel wants to be), as a painting would hang on it: the first thing a level
-- ray from O toward T meets within `reach`, and which way that surface faces,
-- from two more rays `probe` either side of the hit. -> hx, hz, nx, nz (the
-- normal level, unit, facing O), or nil; rays cast.
function M.wall(cast, ox, oy, oz, tx, tz, reach, probe)
  local ux, uz = tx - ox, tz - oz
  local ul = sqrt(ux * ux + uz * uz)
  if ul < 1e-4 then return nil, nil, nil, nil, 0 end
  ux, uz = ux / ul, uz / ul
  local d = cast(ox, oy, oz, ux, 0, uz, reach)
  if not d then return nil, nil, nil, nil, 1 end
  local hx, hz = ox + ux * d, oz + uz * d
  probe = probe or 0.25
  -- the probes run alongside the ray, `probe` either side of it, from just
  -- short of the hit; far enough on to meet a wall seen at a slant (up to
  -- about 80 degrees off square)
  local back = math.min(2 * probe, d * 0.5)
  local sx, sz = hx - ux * back, hz - uz * back
  local wx, wz = uz, -ux
  local p1x, p1z = probe_hit(cast, sx - wx * probe, oy, sz - wz * probe, ux, uz, back + 6 * probe)
  local p2x, p2z = probe_hit(cast, sx + wx * probe, oy, sz + wz * probe, ux, uz, back + 6 * probe)
  -- the face through both probe hits, which must pass through the hit too.
  -- Without one it is not a wall: something thinner than the probes are apart
  -- (a post, a stalk: the game's depth test draws it across the panel) or a
  -- stray answer from the collision, which a pet must not jump for.
  if not (p1x and p2x) then return nil, nil, nil, nil, 3 end
  local fx, fz = p2x - p1x, p2z - p1z
  local fl = sqrt(fx * fx + fz * fz)
  if fl < probe * 0.5 then return nil, nil, nil, nil, 3 end
  local nx, nz = -fz / fl, fx / fl
  if nx * ux + nz * uz > 0 then nx, nz = -nx, -nz end
  if abs((hx - p1x) * nx + (hz - p1z) * nz) > probe * 0.15 then return nil, nil, nil, nil, 3 end -- a corner: two walls
  return hx, hz, nx, nz, 3
end

-- Where a panel `hw` half wide hangs on a wall (a point hx, hz on it, facing
-- nx, nz): at the spot its place (tx, tz) flattens onto, `margin` in front
-- of the wall, turned to face out from it. It keeps within `slide` of the
-- point the ray found, and `margin` clear of any corner along the wall each
-- way: rays along the wall from in front of that point (at height y; a ray
-- from inside the other wall would not see it). Between two corners closer
-- than it is wide it hangs in the middle. -> x, z, yaw, rays cast, and how
-- far it may still slide along the wall each way (toward -w and +w, where w is
-- (nz, -nx)) before it comes nearer a corner than that.
function M.hang(cast, y, tx, tz, hx, hz, nx, nz, hw, margin, slide)
  local wx, wz = nz, -nx -- along the wall
  local along = (tx - hx) * wx + (tz - hz) * wz
  slide = slide or hw
  if along > slide then along = slide elseif along < -slide then along = -slide end
  local ox, oz = hx + nx * margin, hz + nz * margin
  local reach = hw + margin
  local far = abs(along) + 2 * reach
  local right = cast(ox, y, oz, wx, 0, wz, far)
  local left = cast(ox, y, oz, -wx, 0, -wz, far)
  local lo, hi = left and reach - left or -math.huge, right and right - reach or math.huge
  if lo > hi then along = (lo + hi) / 2
  elseif along < lo then along = lo
  elseif along > hi then along = hi end
  return ox + wx * along, oz + wz * along, math.atan(nx, nz), 2, math.max(along - lo, 0), math.max(hi - along, 0)
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
