-- The desk scene (CONFIG.animation.style = 'desk'): opening a terminal puts
-- a desk and a chair where the character stands, sits it down and has it
-- work away, with a mood now and then: stretching, yawning, thinking,
-- getting frustrated, a sip of tea. Everything is client-side: the furniture
-- is a pair of background objects only this client draws (no collision;
-- core/app/deskprops.nelua), and the poses change the local character's
-- animation the way the phone pose does (lua/animation.lua). Nobody else
-- sees any of it.
--
-- Walking off, combat, a mount, a cutscene, group pose, an event or a zone
-- change ends the scene; it comes back the next time a terminal opens.
--
-- Not yet observed in game: the models' size, origin and facing (`models`),
-- the seated timelines' seat height against the chair, and the reference
-- height below are assumptions to tune.

local D = {
  -- The desk's size: 'normal' is the furniture's own scale, made for an
  -- average adult Midlander, so smaller characters look like children at
  -- a grown-up desk; 'fit' scales it to the character's height; a number
  -- is a factor of the normal size.
  scale = 'normal',
  -- The chair: 'fit' (the default) sizes it to the character, whose seated
  -- pose puts its hips at its own seat height; 'normal' or a number as above.
  chair_scale = 'fit',
  -- What 'fit' divides the character's model height (yalms) by: the height
  -- the furniture was made for. An assumption, not measured.
  reference_height = 1.75,
  min_scale = 0.25,
  max_scale = 3.0,
  -- Room between the chair's centre and the desk's near edge (yalms, at the
  -- chair's scale): the knees go there.
  knee_room = 0.3,
  -- Farther than this from the chair (yalms) and the character has walked off.
  leave_distance = 0.35,
  guard_interval = 0.1,
  seed = 0,              -- 0: seeded from the clock; any other value repeats the same day
}

-- The furniture (HousingFurniture.ModelKey -> bgcommon/hou/indoor/general/
-- <key>/bgparts/fun_b0_m<key>.mdl; each path checked against the game's
-- index). `depth` is the desk's front-to-back size at scale 1 and `yaw` a
-- turn (radians) added so the model's front faces the right way; both are
-- guesses until seen in game. Swap in any other pair from `alternatives`.
D.models = {
  desk = { name = 'Origenics Monitor Desk', item = 44889, path = 'bgcommon/hou/indoor/general/1419/bgparts/fun_b0_m1419.mdl', depth = 0.8, yaw = 0 },
  chair = { name = 'Origenics Chair', item = 44890, path = 'bgcommon/hou/indoor/general/1420/bgparts/fun_b0_m1420.mdl', yaw = 0 },
}
D.alternatives = {
  classroom = {
    desk = { name = 'Classroom Desk', item = 44902, path = 'bgcommon/hou/indoor/general/1432/bgparts/fun_b0_m1432.mdl', depth = 0.6, yaw = 0 },
    chair = { name = 'Classroom Chair', item = 44903, path = 'bgcommon/hou/indoor/general/1433/bgparts/fun_b0_m1433.mdl', yaw = 0 },
  },
}

-- Moods: seated ActionTimeline loops held as the base pose (ActionTimeline
-- sheet, event_base_chair_* are the game's own seated NPC poses). After any
-- other mood the character goes back to work; from work the next mood is
-- drawn by weight. `min`/`max` bound how long a mood lasts (seconds);
-- `layer` is an additive timeline played over it. `typing` moods speed up
-- with your keystrokes.
D.moods = {
  { name = 'working',    weight = 6, min = 8, max = 25, timelines = { 9287 }, typing = true },  -- event_base_chair_sit_pc: typing at a computer
  { name = 'writing',    weight = 2, min = 8, max = 18, timelines = { 4203 } },                -- event_base_chair_sit_memo
  { name = 'reading',    weight = 1, min = 8, max = 15, timelines = { 5593 } },                -- event_base_chair_read
  { name = 'thinking',   weight = 2, min = 4, max = 9,  timelines = { 9001, 5511 } },          -- chair_table_think, chair_think1
  { name = 'stretching', weight = 1, min = 4, max = 7,  timelines = { 5752 } },                -- event_base_chair_stretch
  { name = 'yawning',    weight = 1, min = 4, max = 8,  timelines = { 1068, 9040 } },          -- chair_sit_tired, chair_snooze
  { name = 'frustrated', weight = 1, min = 3, max = 6,  timelines = { 9042 }, layer = 664 },   -- chair_anxiety + emote/add_angry_st (swearing)
  { name = 'sip',        weight = 1, min = 4, max = 8,  timelines = { 9033, 9190 } },          -- chair_drink_tea, chair_drink_hotcoffee
}

-- A small deterministic generator (xorshift32): the same seed gives the same
-- day at the desk, whatever else uses math.random.
function D.rng(seed)
  local s = math.floor(seed or 1) % 4294967296
  if s == 0 then s = 2463534242 end
  return function()
    s = s ~ ((s << 13) & 0xffffffff)
    s = s ~ (s >> 17)
    s = s ~ ((s << 5) & 0xffffffff)
    return s / 4294967296
  end
end

-- Index of an entry drawn by `weight` with r in [0, 1).
function D.pick(list, r)
  local total = 0
  for _, e in ipairs(list) do total = total + math.max(0, e.weight or 1) end
  if total <= 0 then return 1 end
  local x = r * total
  for i, e in ipairs(list) do
    x = x - math.max(0, e.weight or 1)
    if x < 0 then return i end
  end
  return #list
end

-- The factor for a scale option: 'normal' 1, 'fit' the character's height
-- over the reference, or a number; clamped.
function D.scale_factor(opt, height)
  local s = 1
  if opt == 'fit' then
    s = (height and height > 0) and height / D.reference_height or 1
  elseif type(opt) == 'number' then
    s = opt
  elseif tonumber(opt) then
    s = tonumber(opt)
  end
  return math.max(D.min_scale, math.min(D.max_scale, s))
end

-- Where the furniture goes for a character at (x, y, z) facing `rotation`
-- (the game's: facing (sin r, 0, cos r)): the chair where it stands, turned
-- the same way, and the desk in front of it, turned to face the chair.
function D.layout(p)
  local ds = D.scale_factor(D.scale, p.height)
  local cs = D.scale_factor(D.chair_scale, p.height)
  local fx, fz = math.sin(p.rotation), math.cos(p.rotation)
  local desk, chair = D.models.desk, D.models.chair
  local ahead = D.knee_room * cs + (desk.depth or 0.8) * 0.5 * ds
  return {
    { model = chair.path, x = p.x, y = p.y, z = p.z, yaw = p.rotation + (chair.yaw or 0), scale = cs },
    { model = desk.path, x = p.x + fx * ahead, y = p.y, z = p.z + fz * ahead,
      yaw = p.rotation + math.pi + (desk.yaw or 0), scale = ds },
  }, ds, cs
end

local ANIM_LOCK, KEEP = 8, 255

local st = nil  -- the scene while it is on: { x, z, mood, timeline, until_t, rng, ... }

function D.active() return st ~= nil end

-- Timelines of ours, so a reload never takes one for the pose to restore.
function D.owns(base)
  if not base or base == 0 then return false end
  for _, m in ipairs(D.moods) do
    for _, id in ipairs(m.timelines) do if id == base then return true end end
  end
  return false
end

-- The pose to go back to after a reaction (lua/animation.lua).
function D.hold() return st and st.timeline or nil end
function D.mood() return st and D.moods[st.mood].name or nil end
function D.typing() return st and D.moods[st.mood].typing or false end

local function hold(A, tl)
  if A.lock_movement then
    ghostty.anim_set(ANIM_LOCK, 0, tl, true)
  else
    ghostty.anim_set(KEEP, 0, tl, false)
  end
  ghostty.anim_play(tl)
end

local function mood_index(name)
  for i, m in ipairs(D.moods) do if m.name == name then return i end end
  return 1
end

-- Enter mood `i` at time t.
local function enter(A, i, t)
  local m = D.moods[i]
  st.mood = i
  st.timeline = m.timelines[1 + math.floor(st.rng() * #m.timelines) % #m.timelines]
  st.until_t = t + (m.min or 8) + st.rng() * math.max(0, (m.max or 25) - (m.min or 8))
  hold(A, st.timeline)
  if m.layer and m.layer > 0 then ghostty.anim_play(m.layer) end
end

-- The next mood: back to work after anything else, otherwise by weight.
function D.next_mood(cur, r)
  local work = mood_index('working')
  if cur ~= work then return work end
  return D.pick(D.moods, r)
end

-- Why the scene cannot start now (nil when it can).
function D.refuse(p, mode)
  if not p then return 'no character' end
  if mode ~= 1 then return 'not standing (mode ' .. tostring(mode) .. ')' end
  if p.in_combat then return 'in combat' end
  if p.mounted then return 'mounted' end
  local b = ghostty.desk_blocked and ghostty.desk_blocked() or 0
  if b ~= 0 then return 'blocked (' .. b .. ')' end
  return nil
end

-- Sit down at a new desk. Returns false when the scene cannot start (the
-- caller holds the phone instead).
function D.start(A, p, mode, base, t)
  local why = D.refuse(p, mode)
  if why then
    ghostty.log('desk: not now: ' .. why)
    return false
  end
  local list = D.layout(p)
  ghostty.desk_props(list)
  local seed = (D.seed and D.seed ~= 0) and D.seed or math.floor((os.time() + os.clock() * 1000) % 2147483647)
  st = { x = p.x, z = p.z, territory = p.territory, saved_base = base or 0, rng = D.rng(seed), next_guard = 0,
         rebase = t == nil } -- no clock yet: the first frame sets it
  enter(A, mood_index('working'), t or 0)
  return true
end

-- Get up and put the furniture away. `why` goes to the log.
function D.stop(A, why)
  if not st then return end
  ghostty.log('desk: scene ends' .. (why and (': ' .. why) or ''))
  ghostty.desk_props(nil)
  local base = D.owns(st.saved_base) and 0 or st.saved_base
  st = nil
  if A.lock_movement then
    ghostty.anim_set(1, 0, base, true)
  else
    ghostty.anim_set(KEEP, 0, base, false)
  end
  ghostty.anim_play(A.idle_timeline)
end

-- Each frame while the scene is on. Returns false once it has ended.
function D.frame(A, t, p, busy)
  if not st then return false end
  if not p then D.stop(A, 'no character') return false end
  local d = math.sqrt((p.x - st.x) ^ 2 + (p.z - st.z) ^ 2)
  if d > D.leave_distance then D.stop(A, 'walked off') return false end
  if p.in_combat then D.stop(A, 'combat') return false end
  if p.mounted then D.stop(A, 'mounted') return false end
  if p.territory ~= st.territory then D.stop(A, 'zone change') return false end
  local b = ghostty.desk_blocked and ghostty.desk_blocked() or 0
  if b ~= 0 then D.stop(A, 'blocked (' .. b .. ')') return false end
  if st.rebase then st.until_t, st.rebase = st.until_t + t, false end
  if t >= st.until_t then
    enter(A, D.next_mood(st.mood, st.rng()), t)
    return true
  end
  -- keep the mood: the game's idle system may swap the base pose; a reaction
  -- (`busy`) plays over it and is left alone
  if not busy and t >= st.next_guard then
    st.next_guard = t + D.guard_interval
    local mode, _, base = ghostty.anim_state()
    if mode and base ~= st.timeline then hold(A, st.timeline) end
  end
  return true
end

return D
