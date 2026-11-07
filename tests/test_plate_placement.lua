local root = ...
package.path = root .. '/lua/?.lua;' .. package.path
local player = { x = 10, y = 2, z = 20, rotation = 0.7, territory = 123 }
ghostty = { player = function() return player end, target = function() return {entity_id = 9} end }
local world = require('world')
local function near(a,b) assert(math.abs(a-b)<1e-9, tostring(a)..' vs '..tostring(b)) end
for _, pin in ipairs({'pet', 'ground', 'hud 0.2 0.7 2.4 0.9', 'me 3.1 2.2', 'target 4.8', 'orbit 4.4 0.7', 'at 1.2 4.5 2.1 0.3 -0.2'}) do
  assert(world.command(1,pin)==nil)
  local before = world.anchors[1]
  local saved = assert(world.placement_args(1), pin)
  before.hidden = true
  assert(world.placement_args(1)==saved, 'temporary hiding is not part of placement')
  assert(world.command(2,saved)==nil)
  local restored = world.anchors[2]
  assert(before.kind==restored.kind)
  for _, key in ipairs({'x','y','z','yaw','pitch','sx','sy','scale','dist','forward','up','radius','speed'}) do
    if before[key] ~= nil then near(before[key],restored[key]) end
  end
end
local saved = assert(world.placement_args(1))
local old = world.anchors[1]
player.x,player.z,player.rotation,player.territory = 40,50,1.1,456
assert(world.placement_args(1)==nil, 'cannot capture a fixed pin from a different territory')
assert(world.command(3,saved)==nil)
local a = world.anchors[3]
near(math.sqrt((a.x-player.x)^2+(a.z-player.z)^2),4.5)
near(a.y-player.y,2.1)
near(a.yaw-player.rotation,0.3)
assert(a.zone==456)
world.anchors[4]={kind='hud',sx=0/0}
assert(world.placement_args(4)==nil, 'invalid coordinates never reach JSON')
print('plate placements: OK')
