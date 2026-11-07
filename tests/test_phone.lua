package.path = 'lua/?.lua;' .. package.path
local P = require('phone')
local player = { x = 10, y = 3, z = 20, rotation = 0 }
ghostty = { player = function() return player end, zone = function() return 1 end,
  env = function() end, view = function() end }
local W = require('world')
local calls = { out = 0, away = 0, frames = 0 }
local A = { enabled = false, style = 'desk', preset = 'book', custom_timeline = 42, lock_movement = true,
  on_toggle = function(v) calls[v and 'out' or 'away'] = calls[v and 'out' or 'away'] + 1 end,
  on_frame = function() calls.frames = calls.frames + 1 end }
P.bind(W, A)
assert(P.enabled and P.frame(0, false) == 1, 'the phone starts put away')
P.command('off')
assert(P.frame(0, false) == 0)
assert(P.toggle_if_enabled() == 0)
W.anchors[2] = { kind = 'pet', width = 900, height = 900 }
W.anchors[7] = { kind = 'world', x = -100, y = 0, z = 0, width = 1800, height = 600 }
W.anchors[9] = { kind = 'hud', hidden = true }
P.command('open')
P.frame(0, false)
assert(calls.out == 1 and A.enabled and A.preset == 'device' and not A.lock_movement)
assert(A.custom_timeline == 0 and A.style == 'phone')
for i = 1, 10 do P.frame(i / 10, false) end
assert(P.progress == 1 and calls.out == 1)
local a, b = W.place(2, 1, false, false), W.place(7, 1, false, false)
assert(a and b and a.z > player.z and b.z > player.z, 'all anchors become forward projections')
assert(a.yaw == math.pi and a.x < b.x)
assert(b.x - a.x >= (900 + 1800) / P.pixels_per_yalm / 2 + P.gap - 1e-6, 'mixed widths never overlap')
local oldx, oldz = a.x - player.x, a.z - player.z
player.rotation = math.pi / 2
a = W.place(2, 2, false, false)
assert(math.abs(a.x - player.x - oldz) < 1e-6 and math.abs(a.z - player.z + oldx) < 1e-6, 'follows character heading')
assert(W.place(9, 2, false, false) == nil)
P.command('close')
for i = 11, 20 do P.frame(i / 10, false) end
assert(P.progress == 0 and calls.away == 1 and W.place(2, 3, false, false) == nil)
assert(not A.enabled and A.style == 'desk' and A.preset == 'book' and A.custom_timeline == 42 and A.lock_movement)
P.command('open')
P.frame(3, false)
P.frame(3.1, true)
assert(not P.opened and P.progress == 0 and calls.away == 2)
P.frame(4, false)
assert(not P.opened, 'leaving combat/loading never reopens the device')
P.command('open')
P.reduce_motion = true
P.frame(5, false)
assert(P.progress == 1)
P.command('off')
assert(not P.enabled and P.progress == 0)
assert(W.anchors[7].kind == 'world' and W.anchors[7].x == -100, 'original placements survive phone mode')
assert(not pcall(P.command, 'invalid'))
assert(P.state() == 0)
P.command('open')
P.pose = false
P.frame(6, false)
assert(calls.out == 3, 'pose can be disabled')
P.reset()
local opened
ghostty.game_action = function(verb, app)
  if verb == 'phone-state' then return app == 'get' and 1 or 1 end
  assert(verb == 'phone-app') opened = app return 1
end
P.command('journal')
assert(opened == 'journal' and P.opened)
P.command('close')
P.source_opened('phone_inventory')
assert(P.opened, 'a native hotkey opening its replacement summons the phone')
P.command('close')
P.source_opened('phone')
assert(not P.opened, 'the launcher cannot summon itself')
P.reset()
-- Even a failed animation release restores module settings and closes layout.
P.pose = true
P.frame(7, false)
P.command('open')
P.frame(8, false)
A.on_toggle = function() error('animation unavailable') end
assert(not pcall(P.reset))
assert(not P.opened and P.progress == 0 and not A.enabled and A.preset == 'book')
print('phone policy OK')
