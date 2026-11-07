-- Phone shell policy. The native core owns sessions/input/rendering; this
-- module owns when the device is out and where its projections appear.
-- A closed phone keeps its panels alive, but projects nothing.
local M = {
  enabled = true, opened = false, progress = 0,
  duration = 0.32, distance = 2.2, height = 1.65,
  columns = 3, gap = 0.18, pixels_per_yalm = 900,
  pose = true, reduce_motion = false,
}
M.apps = {
  { 'journal', 'Journal' }, { 'character', 'Character' },
  { 'inventory', 'Inventory' }, { 'crafting', 'Workshop' },
  { 'chat', 'Correspondence' }, { 'grimoire', 'Grimoire' },
}
M.source_windows = {
  phone_journal = { title = '###XivHud.Journal', label = 'Journal' },
  phone_tracker = { title = '###XivHud.Journal.Tracker', label = 'Quest tracker' },
  phone_character = { title = '###XivHud.Character', label = 'Character' },
  phone_inventory = { title = '###XivHud.Inventory', label = 'Inventory' },
  phone_crafting = { title = '###XivHud.Crafting', label = 'Workshop' },
  phone_chat = { title = '###XivHud.Chat', label = 'Correspondence' },
  phone_chat_settings = { title = '###XivHud.Chat.Settings', label = 'Correspondence settings' },
  phone_grimoire = { title = '###XivSpell', label = 'Grimoire' },
}
local world, animation, pose_settings, last_time
local first_frame = true
local restore_until

function M.bind(w, a)
  world, animation = w, a
  w.phone = M
end

local function put_away()
  if not pose_settings then return end
  -- Release while enabled: animation.on_toggle(false) restores the saved pose.
  local ok, err = pcall(animation.on_toggle, false)
  for k, v in pairs(pose_settings) do animation[k] = v end
  pose_settings = nil
  if not ok then error(err) end
end

function M.reset()
  M.opened, M.progress, last_time = false, 0, nil
  put_away()
end

function M.command(arg)
  first_frame, restore_until = false, nil
  if arg == 'off' then M.reset() M.enabled = false
  elseif arg == 'close' then M.opened = false
  elseif arg == 'open' then M.enabled, M.opened = true, true
  elseif arg == '' or arg == 'toggle' then M.enabled, M.opened = true, not M.opened
  elseif arg ~= 'status' then
    local found = false
    for _, app in ipairs(M.apps) do if app[1] == arg then found = true break end end
    if not found then error('unknown phone app or command: ' .. arg) end
    if not ghostty.game_action or ghostty.game_action('phone-app', arg) ~= 1 then error('Phone app unavailable: ' .. arg) end
    M.enabled, M.opened = true, true
  end
end

function M.source_opened(name)
  if M.enabled and not restore_until and M.source_windows[name] then M.opened = true end
end

function M.draw()
  local ui = ghostty.ui
  ui.text('TOMESTONE')
  for i, app in ipairs(M.apps) do
    if i % 2 == 0 then ui.same_line() end
    if ui.button(app[2]) then M.command(app[1]) end
  end
  if ui.button('Terminal') then ghostty.phone_command('terminal') end
  ui.same_line()
  if ui.button('Settings') then ghostty.phone_command('settings') end
  if ui.button('Phase focused panel to HUD') then ghostty.phone_command('hud') end
  if ui.button('Return panel to world') then ghostty.phone_command('world') end
  if ui.button('Put away') then M.command('close') end
end

function M.toggle_if_enabled()
  if not M.enabled then return 0 end
  M.opened = not M.opened
  return 1
end

function M.state()
  return M.enabled and (M.opened and 2 or 1) or 0
end

-- blocked includes combat, cutscenes, zoning, mounts and missing characters.
-- Do not reopen on leaving combat: the player explicitly summons the device.
function M.frame(t, blocked)
  if first_frame then
    first_frame = false
    if ghostty.game_action then
      local state = ghostty.game_action('phone-state', 'get')
      if state == 0 or state == 1 or state == 2 then
        M.enabled, M.opened = state > 0, state == 2
        if state == 1 then restore_until = t + 1 end
      end
    end
  end
  if restore_until and t >= restore_until then restore_until = nil end
  if blocked then M.reset() end
  if ghostty.game_action then ghostty.game_action('phone-state', tostring(M.state())) end
  if not M.enabled then return 0 end
  if not M.pose then put_away() end
  local target = M.opened and 1 or 0
  local dt = last_time and math.max(0, math.min(0.1, t - last_time)) or 0
  last_time = t
  if M.reduce_motion or M.duration <= 0 then M.progress = target
  else
    local step = dt / M.duration
    M.progress = M.progress + math.max(-step, math.min(step, target - M.progress))
  end
  if M.opened and M.pose and animation then
    if not pose_settings then
      pose_settings = { enabled = animation.enabled, style = animation.style,
        preset = animation.preset, lock_movement = animation.lock_movement,
        custom_timeline = animation.custom_timeline }
      animation.enabled, animation.style, animation.preset = true, 'phone', 'device'
      animation.custom_timeline, animation.lock_movement = 0, false
      animation.on_toggle(true)
    end
    animation.on_frame(t)
  elseif M.progress == 0 then put_away() end
  return M.opened and 2 or 1
end

-- Stable rows in front of the character, independent of camera direction.
-- Dimensions are measured per row/column so mixed-size apps do not overlap.
function M.layout(id, a, p)
  if not M.enabled or M.progress <= 0 then return nil end
  local ids = {}
  for key, anchor in pairs(world.anchors) do
    if not anchor.hidden then ids[#ids + 1] = key end
  end
  table.sort(ids)
  local cols = math.max(1, math.floor(M.columns))
  local widths, heights, index = {}, {}, nil
  for i, key in ipairs(ids) do
    local anchor = world.anchors[key]
    local col, row = (i - 1) % cols + 1, math.floor((i - 1) / cols) + 1
    local ppm = math.max(100, M.pixels_per_yalm)
    widths[col] = math.max(widths[col] or 0, (anchor.width or world.defaults.width) / ppm)
    heights[row] = math.max(heights[row] or 0, (anchor.height or world.defaults.height) / ppm)
    if key == id then index = i end
  end
  if not index then return nil end
  local col, row = (index - 1) % cols + 1, math.floor((index - 1) / cols) + 1
  local total, side, up = 0, 0, 0
  for _, width in ipairs(widths) do total = total + width + M.gap end
  total = total - M.gap
  for i = 1, col - 1 do side = side + widths[i] + M.gap end
  side = side + widths[col] / 2 - total / 2
  for i = 1, row - 1 do up = up + heights[i] / 2 + heights[i + 1] / 2 + M.gap end
  -- Smoothstep unfolds the hologram from the held device's approximate point.
  local f = M.progress * M.progress * (3 - 2 * M.progress)
  local forward = 0.35 + (M.distance - 0.35) * f
  local r = p.rotation
  return {
    x = p.x + math.sin(r) * forward + math.cos(r) * side * f,
    y = p.y + 1.1 + (M.height + up - 1.1) * f,
    z = p.z + math.cos(r) * forward - math.sin(r) * side * f,
    yaw = r + math.pi, opacity = (a.opacity or world.defaults.opacity) * f,
    ppm = math.max(100, M.pixels_per_yalm),
  }
end

return M
