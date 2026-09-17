-- Visual bell: what you see when a program rings the terminal bell (BEL).
--
-- Soft rings of light spread on the ground from your character's feet, a
-- shimmer rises up the character, and the terminal that rang glows: world
-- screens light up, dropdown tabs and windows pulse their border, the toolbar
-- popup highlights its chip. The core asks style(id) once per bell and draws
-- the rest; returning nil ignores that bell.

local world = require('world')

local M = {
  enabled = true,
  -- A named look (see M.presets); the values below are 'custom' and are used
  -- when preset = 'custom'. Try them all with /term bell demo, pick one with
  -- /term bell <name>.
  preset = 'ripple',
  from_character = true,  -- rings around your character (off: only the terminal glows)
  ring_count = 3,         -- rings per bell, 1..3
  max_radius = 3.0,       -- yalms the rings spread to
  duration = 0.9,         -- seconds a ring takes to spread and fade
  glow_duration = 1.2,    -- seconds the terminal that rang glows
  follow_tint = true,     -- world screens colour it with the light they stand in
  accent = { r = 0.55, g = 0.82, b = 1.0 },
}

M.presets = {
  { name = 'ripple', label = 'Ripple',  rings = 3, max_radius = 3.0, duration = 0.9, glow = 1.2, accent = { 0.55, 0.82, 1.00 } },
  { name = 'sonar',  label = 'Sonar',   rings = 1, max_radius = 5.5, duration = 1.7, glow = 1.6, accent = { 0.40, 0.95, 0.80 } },
  { name = 'burst',  label = 'Burst',   rings = 3, max_radius = 2.0, duration = 0.5, glow = 0.8, accent = { 1.00, 0.80, 0.45 } },
  { name = 'aura',   label = 'Aura',    rings = 1, max_radius = 1.2, duration = 1.3, glow = 1.4, accent = { 0.78, 0.60, 1.00 } },
  { name = 'calm',   label = 'Calm',    rings = 2, max_radius = 2.6, duration = 1.5, glow = 1.8, accent = { 0.92, 0.94, 0.98 } },
}

local function preset(name)
  for _, p in ipairs(M.presets) do
    if p.name == name then return p end
  end
  return nil
end

-- /term bell <name|demo>: pick a look, or preview them. Returns an error
-- message, or nil.
function M.command(args)
  local name = args:match('^%s*(%S*)')
  if name == '' or name == 'demo' then return nil end
  if name == 'custom' or preset(name) then M.preset = name return nil end
  local names = {}
  for _, p in ipairs(M.presets) do names[#names + 1] = p.name end
  return 'bell styles: ' .. table.concat(names, ', ') .. ', custom'
end

-- The demo steps through every preset; step i (1-based) -> label or nil when done.
function M.demo(i)
  local p = M.presets[i]
  if not p then return nil end
  M.preset = p.name
  return string.format('Bell style %d of %d: %s  (/term bell %s to keep it)', i, #M.presets, p.label, p.name)
end

-- id: the terminal that rang.
function M.style(id)
  if not M.enabled then return nil end
  local p = preset(M.preset)
  local a = M.accent or {}
  if p then a = { r = p.accent[1], g = p.accent[2], b = p.accent[3] } end
  local r, g, b = a.r or 0.55, a.g or 0.82, a.b or 1.0
  if M.follow_tint and world.anchors and world.anchors[id] then
    -- keep the hue of the panel's light but not its dimness: the bell glows
    local tr, tg, tb = world.lighting()
    local m = math.max(tr, tg, tb, 1e-3)
    r, g, b = r * tr / m, g * tg / m, b * tb / m
  end
  return {
    from_character = M.from_character,
    rings = math.max(1, math.min(3, math.floor((p and p.rings) or M.ring_count or 3))),
    max_radius = (p and p.max_radius) or M.max_radius,
    duration = (p and p.duration) or M.duration,
    glow_duration = (p and p.glow) or M.glow_duration,
    r = r, g = g, b = b,
  }
end

return M
