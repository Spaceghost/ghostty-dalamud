-- Existing Neovim panes as independently routed world terminals.
-- Layout is pure data; only tick opens views. Closing a view never owns its job.
local M = { enabled = false, nodes = {}, panels = {}, errors = {}, interval = 0.2 }
local palette = { 0x7dcfff, 0xbb9af7, 0x9ece6a, 0xff9e64, 0xf7768e, 0xe0af68 }
local function label(value)
  local text = tostring(value or ''):gsub('[%c\127]', ' ')
  local stop = utf8.offset(text, 121)
  return stop and text:sub(1, stop - 1) or text
end
local function hash(text)
  local value = 0
  for i = 1, #text do value = (value * 33 + text:byte(i)) % 2147483647 end
  return value
end

-- Keys belong to a source/tab/buffer, not a title or an inventory array index.
-- A cycle, duplicate key or dangling parent cannot recursively expand forever.
function M.layout(nodes)
  assert(type(nodes) == 'table' and #nodes <= 256, 'workspace supports at most 256 panes')
  local by_key, ordered, groups, result = {}, {}, {}, {}
  for _, node in ipairs(nodes) do
    assert(type(node.key) == 'string' and #node.key > 0 and #node.key <= 256 and not node.key:find('%c') and not by_key[node.key], 'invalid or duplicate pane key')
    assert(type(node.source) == 'string' and node.tab ~= nil, 'pane source and tab are required')
    by_key[node.key] = node; ordered[#ordered + 1] = node
  end
  table.sort(ordered, function(a,b) return a.key < b.key end)
  for _, node in ipairs(ordered) do
    local root, seen, depth = node, {}, 0
    while root.parent and by_key[root.parent] do
      assert(not seen[root.key], 'workspace parent cycle')
      seen[root.key] = true; root = by_key[root.parent]; depth = depth + 1
    end
    local group = root.source .. ':tab:' .. tostring(root.tab)
    if not groups[group] then groups[group] = {} end
    groups[group][#groups[group]+1] = { node = node, depth = depth }
  end
  local names = {}; for name in pairs(groups) do names[#names+1] = name end; table.sort(names)
  local centers = {}
  for _, group in ipairs(names) do
    local entries = groups[group]
    table.sort(entries, function(a,b)
      if a.depth ~= b.depth then return a.depth < b.depth end
      return a.node.key < b.node.key
    end)
    local columns = math.ceil(math.sqrt(#entries))
    local rows = math.ceil(#entries / columns)
    local radius = math.sqrt((columns*1.45)^2 + (rows*0.9)^2)
    local gx, gz, angle, distance
    for attempt = 0, 2048 do
      angle = (#centers + attempt) * 2.399963229728653
      distance = 4.5 + radius + attempt * 0.1
      gx, gz = math.sin(angle)*distance, math.cos(angle)*distance
      local clear = true
      for _, center in ipairs(centers) do
        if (gx-center.x)^2+(gz-center.z)^2 < (radius+center.radius+2)^2 then clear=false;break end
      end
      if clear then break end
    end
    centers[#centers+1] = { x=gx, z=gz, radius=radius }
    local colour = palette[hash(group) % #palette + 1]
    for i, entry in ipairs(entries) do
      local node, col, row = entry.node, (i-1)%columns, math.floor((i-1)/columns)
      local offset = (col-(columns-1)*0.5)*2.9
      -- Screens sit across their cluster's tangent and face the same centre.
      local x, z = gx+math.cos(angle)*offset, gz-math.sin(angle)*offset
      result[node.key] = { key=node.key, group=group, depth=entry.depth, colour=colour, parent=node.parent, source=node.source,
        x=x, y=1.8+row*1.9, z=z, yaw=math.atan(-x,-z),
        label=label(label(node.source)..' / '..label(node.title)..(entry.depth>0 and (' / nested '..entry.depth) or '')),
        width=1320, height=740, pixels_per_yalm=600 }
    end
  end
  return result
end

function M.configure(config, snapshot)
  if type(snapshot) ~= 'table' or snapshot.version ~= 1 then return nil, 'unsupported workspace snapshot' end
  local ok, layout = pcall(M.layout, snapshot.nodes)
  if not ok then return nil, layout end
  local profiles, nodes = {}, {}
  for _, node in ipairs(snapshot.nodes) do
    if type(node.command) ~= 'table' or #node.command == 0 or #node.command > 16 then return nil, 'invalid view command' end
    for _, arg in ipairs(node.command) do
      if type(arg) ~= 'string' or #arg > 4096 or arg:find('%z') then return nil, 'invalid view argument' end
    end
    local profile = 'nvim:' .. node.key
    profiles[#profiles+1] = { name=profile, transport='agent', agent=node.agent or 'local', command=node.command }
    nodes[#nodes+1] = { key=node.key, profile=profile, placement=layout[node.key] }
  end
  -- Validate the entire snapshot before mutating configuration.
  for _, profile in ipairs(profiles) do config.profiles[#config.profiles+1] = profile end
  M.nodes, M.placements, M.enabled, M.errors = nodes, layout, true, snapshot.errors or {}
  config.workspace = M
  local base = config.world.place
  config.world.place = function(id, now, focused, held)
    local p = base(id, now, focused, held)
    local key = M.panels[id]
    local item = key and M.placements[key]
    if not item or not p or held then return p end
    -- Manual pins, hiding and dragging remain authoritative.
    local anchor = config.world.anchors[id]
    if not anchor or anchor.kind ~= 'pet' then return p end
    local player = ghostty.player()
    if not player then return nil end
    local pose=M.pose
    if not pose or pose.zone~=player.territory or (pose.x-player.x)^2+(pose.z-player.z)^2>900 then
      pose={x=player.x,y=player.y,z=player.z,yaw=player.rotation,zone=player.territory,now=now}
      M.pose=pose
    elseif pose.now~=now then
      local amount=1-math.exp(-math.min(math.max(now-pose.now,0),0.1)*7)
      pose.x=pose.x+(player.x-pose.x)*amount; pose.z=pose.z+(player.z-pose.z)*amount
      pose.y=pose.y+(player.y-pose.y)*amount
      local turn=(player.rotation-pose.yaw+math.pi)%(2*math.pi)-math.pi
      pose.yaw=pose.yaw+turn*amount;pose.now=now
    end
    local c,s = math.cos(pose.yaw),math.sin(pose.yaw)
    p.x=pose.x+item.x*c+item.z*s; p.z=pose.z-item.x*s+item.z*c
    p.y=pose.y+item.y; p.yaw=item.yaw+pose.yaw
    p.width=item.width; p.height=item.height; p.pixels_per_yalm=item.pixels_per_yalm
    p.pet=false; p.order_prev=false; p.order_next=false
    p.light_r=((item.colour>>16)&255)/255; p.light_g=((item.colour>>8)&255)/255; p.light_b=(item.colour&255)/255
    return p
  end
  return true
end

-- Snapshot metadata for a shared mod navigator; this never opens or focuses a view.
function M.describe(id)
  local item=M.panels[id] and M.placements[M.panels[id]]
  if not item then return nil end
  return {key=item.key, parent=item.parent, source=item.source, group=item.group,
    label=item.label, colour=item.colour, depth=item.depth}
end

function M.nameplate(id)
  local item=M.panels[id] and M.placements[M.panels[id]]
  return item and item.label or nil, item and item.colour or nil
end

function M.tick(now)
  if not M.enabled or now < (M.next_open or 0) or not ghostty.player() then return end
  M.next_open=now+M.interval
  local present,live_ids={},{}
  for _, panel in ipairs(ghostty.panels()) do
    if panel.profile then present[panel.profile]=panel.id end
    live_ids[panel.id]=true
  end
  for id in pairs(M.panels) do if not live_ids[id] then M.panels[id]=nil end end
  for _, node in ipairs(M.nodes) do
    local id=present[node.profile]
    if id then M.panels[id]=node.key
    elseif not node.opened then
      local opened,err=ghostty.terminal_new{profile=node.profile,pin='pet'}
      if opened then M.panels[opened]=node.key;node.opened=true
      else node.error=err;M.next_open=now+2 end
      return -- rate-limit new agent sessions and keep frame work bounded
    end
    if id then node.opened=true end -- closing a view is respected, not undone every frame
  end
end

function M.load(config, path)
  local file=io.open(path,'rb')
  if not file then return false end -- workspace is opt-in through a local snapshot
  local bytes=file:read(2*1024*1024+1);file:close()
  if not bytes or #bytes>2*1024*1024 then return nil,'workspace snapshot exceeds size limit' end
  local ok,snapshot=pcall(require('json').decode,bytes)
  if not ok then return nil,'invalid workspace JSON' end
  return M.configure(config,snapshot)
end
return M
