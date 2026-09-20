-- Settings window (/term config, or "cfg" in the tab bar).
--
-- Every entry edits a value inside the CONFIG table by path. Changes apply
-- immediately and are saved to settings.lua in the config directory (a slider
-- when it is released), which init.lua layers over its own defaults at load,
-- clamped to each slider's range. Add an entry here to expose a new
-- option; no core change is needed.

local changelog = require('changelog')
local vote = require('vote')
local themes = require('themes')
local tooltips = require('tooltips')
local gallery = require('gallery')

local S = {}

local ALIGN = { 'left', 'center', 'right' }
local MODS = { 'ctrl', 'ctrl+shift', 'ctrl+alt', 'alt', 'shift', '' }
local PAD = { 'select', 'create', 'start', 'l3', 'r3', 'dpad_up', 'dpad_down', 'dpad_left', 'dpad_right', 'north', 'south', 'west', 'east', 'l1', 'r1', 'l2', 'r2', '' }
local DTR_MODES = { 'auto', 'always', 'never' }

S.schema = {
  { 'Theme', {
    { 'theme', 'theme', 'Theme' },
  } },
  { 'Keys & controller', {
    { 'toggle_mods', 'combo', MODS, 'Dropdown toggle modifiers (+ `)' },
    { 'world_toggle_mods', 'combo', MODS, 'World terminals toggle modifiers (+ `)' },
    { 'toggle_gamepad_button', 'combo', PAD, 'Controller button (tap / hold / double tap; create = DualSense Create)' },
  } },
  { 'Dropdown', {
    { 'dropdown.height', 'slider', 0.15, 1.0, 'Height (fraction of screen)' },
    { 'dropdown.width', 'slider', 0.25, 1.0, 'Width (fraction of screen)' },
    { 'dropdown.min_width', 'slider_int', 400, 3000, 'Minimum width (px)' },
    { 'dropdown.align', 'combo', ALIGN, 'Alignment' },
    { 'dropdown.y_offset', 'slider_int', 0, 200, 'Top offset (px, e.g. toolbar height)' },
    { 'dropdown.opacity', 'slider', 0.3, 1.0, 'Opacity' },
    { 'dropdown.rounding', 'slider', 0, 24, 'Corner rounding' },
    { 'dropdown.margin', 'slider_int', 0, 80, 'Side margin (px)' },
    { 'dropdown.font_size', 'slider', 8, 32, 'Font size' },
    { 'dropdown.animation_ms', 'slider_int', 0, 600, 'Slide animation (ms)' },
    { 'dropdown.open_on_start', 'checkbox', 'Open when the plugin loads' },
    { 'dropdown.glass', 'checkbox', 'Glass (gradient body, edge highlight)' },
    { 'dropdown.glow', 'slider', 0, 1, 'Outer glow' },
    { 'dropdown.world_tint', 'slider', 0, 1, "Take on the world's light (time of day, weather)" },
  } },
  { 'Terminals', {
    { 'close_on_exit', 'checkbox', 'Close a terminal when its shell exits (ctrl+d)' },
    { 'copy_on_select', 'checkbox', 'Copy selected text when the mouse button is released' },
    { 'cursor_blink', 'checkbox', 'Blinking cursor' },
    { 'popup.font_size', 'slider', 8, 32, 'Toolbar popup font size' },
  } },
  { 'Pets (terminals around your character)', {
    { 'world.pet.distance', 'slider', 1.5, 8, 'Distance (yalms)' },
    { 'world.pet.height_above', 'slider', 0.5, 4, 'Height above feet (yalms)' },
    { 'world.pet.side', 'slider', 0.6, 3.0, 'Angle from facing (radians)' },
    { 'world.pet.step', 'slider', 0.2, 1.5, 'Spacing between pets (radians)' },
    { 'world.pet.stiffness', 'slider', 1, 20, 'Follow stiffness' },
    { 'world.pet.damping', 'slider', 0.3, 1.5, 'Damping (lower swings more)' },
    { 'world.pet.bob', 'slider', 0, 0.3, 'Bob (yalms)' },
    { 'world.pet.curve', 'slider', 0, 20, 'Curve radius (yalms, 0 = flat)' },
    { 'world.pet.pixels_per_yalm', 'slider_int', 200, 1400, 'Pixel density' },
    { 'world.pet.width', 'slider_int', 600, 4000, 'Default width (px)' },
    { 'world.pet.height', 'slider_int', 320, 3000, 'Default height (px)' },
    { 'world.pet.turn_speed', 'slider', 0, 12, 'Turn to face selected (rad/s, 0 = off)' },
    { 'world.defaults.opacity', 'slider', 0.3, 1.0, 'Panel opacity' },
    { 'world.occlusion', 'combo', { 'depth', 'capsule', 'off' }, 'Occlusion (depth = game geometry hides panels)' },
    { 'world.occlusion_tolerance', 'slider', 0.005, 0.2, 'Occlusion tolerance (yalms)' },
    { 'world.occlusion_edge', 'slider', 0, 3, 'Occlusion edge softness (px)' },
    { 'world.under_hud', 'checkbox', 'Panels go beneath the game\'s HUD (hotbars, chat, minimap)' },
  } },
  { 'Clicked world panels', {
    { 'world.present.enabled', 'checkbox', 'Float a clicked panel toward you' },
    { 'world.present.full_screen', 'slider', 0.3, 1.0, 'Double-click: how much of the screen it fills' },
    { 'world.present.fraction', 'slider', 0, 1, 'How far it floats (fraction of the way)' },
    { 'world.present.distance', 'slider', 0.8, 4, 'Goal in front of the camera (yalms)' },
    { 'world.present.min_distance', 'slider', 0.5, 3, 'Never nearer than (yalms)' },
    { 'world.present.ease', 'slider', 0.05, 1.5, 'Float time (seconds)' },
    { 'world.present.curve_relax', 'slider', 0, 2, 'Flatten while presented' },
    { 'world.walk.enabled', 'checkbox', 'Walk up to a clicked panel' },
    { 'world.walk.approach_distance', 'slider', 0.8, 5, 'Stop this far from it (yalms)' },
    { 'world.walk.max_seconds', 'slider', 0.5, 8, 'Give up after (seconds)' },
    { 'world.walk.turn_speed', 'slider', 1, 20, 'Turn speed (rad/s)' },
  } },
  { 'Placing world panels (Alt + drag)', {
    { 'world.drag.enabled', 'checkbox', 'Alt + drag moves a panel (Shift snaps to surfaces, + Ctrl stretches)' },
    { 'world.drag.wheel_step', 'slider', -1, 1, 'Wheel while dragging (yalms per notch)' },
    { 'world.drag.offset', 'slider', 0, 0.2, 'Gap to the surface when snapped (yalms)' },
    { 'world.drag.fit_max', 'slider', 0.5, 10, 'Stretch at most (yalms each way)' },
    { 'world.drag.fit_margin', 'slider', 0, 0.5, 'Stretch: keep clear of edges (yalms)' },
    { 'world.drag.fit_tolerance', 'slider', 0.01, 0.2, 'Stretch: bumps that still count as flat (yalms)' },
  } },
  { 'Light', {
    { 'world.light.enabled', 'checkbox', 'React to time of day and weather' },
    { 'world.light.backlight_below', 'slider', 0.5, 1.2, 'Backlight when dimmer than' },
    { 'world.light.rain_dim', 'slider', 0, 0.5, 'Rain darkening' },
    { 'rain.shelter', 'checkbox', 'Rain follows shelter (screens under a roof stay dry)' },
    { 'rain.shake', 'checkbox', 'Rough movement shakes the water off screens' },
    { 'rain.shake_accel', 'slider', 10, 150, 'Shake-off: how rough (yalms/s²)' },
    { 'world.light.cast_light', 'checkbox', 'Panels light up your character and the world' },
    { 'world.light.light_intensity', 'slider', 0, 4, 'Cast light intensity' },
    { 'world.light.light_range', 'slider', 1, 20, 'Cast light range (yalms)' },
    { 'world.light.light_by_day', 'slider', 0, 1, 'Cast light in daylight (share)' },
    { 'world.light.light_color_from_tint', 'checkbox', 'Cast light takes the time-of-day tint' },
    { 'world.light.shadows', 'checkbox', 'Cast light throws shadows (expensive)' },
    { 'world.shadows.enabled', 'checkbox', 'Screens cast shadows (experimental)' },
  } },
  { 'Character animation', {
    { 'animation.enabled', 'checkbox', 'Hold a pose while a terminal is out or focused' },
    { 'animation.style', 'combo', { 'phone', 'desk' }, 'Style (phone in hand, or working at a desk)' },
    { 'animation.desk.scale', 'combo', { 'normal', 'fit', '0.75', '1.25', '1.5', '2' }, 'Desk size (normal = sized for a Midlander)' },
    { 'animation.desk.chair_scale', 'combo', { 'fit', 'normal', '0.75', '1.25', '1.5', '2' }, 'Chair size' },
    { 'animation.reactions', 'checkbox', 'React to bells, failed and long commands, output and idling' },
    { 'animation.preset', 'combo', { 'device', 'book', 'pen', 'photograph', 'think', 'lookout' }, 'Pose' },
    { 'animation.custom_timeline', 'slider_int', 0, 40000, 'Custom ActionTimeline id (0 = use the pose)' },
    { 'animation.typing_speed', 'slider', 1, 4, 'Pose animation speed while typing' },
    { 'animation.energy_decay', 'slider', 0.5, 6, 'How fast typing energy fades' },
    { 'animation.lock_movement', 'checkbox', 'Lock movement while holding (not recommended)' },
  } },
  { 'Bell', {
    { 'bell.enabled', 'checkbox', 'Visual bell when a program rings (BEL)' },
    { 'bell.preset', 'combo', { 'ripple', 'sonar', 'burst', 'aura', 'calm', 'custom' }, 'Style (custom uses the values below)' },
    { 'bell.from_character', 'checkbox', 'Rings of light around your character' },
    { 'bell.ring_count', 'slider_int', 1, 3, 'Rings per bell' },
    { 'bell.max_radius', 'slider', 1, 6, 'Ring radius (yalms)' },
    { 'bell.duration', 'slider', 0.3, 2.5, 'Ring duration (s)' },
    { 'bell.glow_duration', 'slider', 0.3, 3, 'Terminal glow duration (s)' },
    { 'bell.follow_tint', 'checkbox', 'World screens tint it with their light' },
    { 'bell.accent.r', 'slider', 0, 1, 'Accent colour: red' },
    { 'bell.accent.g', 'slider', 0, 1, 'Accent colour: green' },
    { 'bell.accent.b', 'slider', 0, 1, 'Accent colour: blue' },
  } },
  { 'Assistant (/term ask)', {
    { 'assistant.enabled', 'checkbox', '/term ask opens the assistant' },
    { 'assistant.ui', 'combo', { 'panel', 'terminal' }, '/ask answers in (panel: chat bubbles with follow-ups)' },
    { 'assistant.game_actions', 'checkbox', 'The panel offers game actions (the game still asks you first)' },
    { 'assistant.echo', 'checkbox', 'Also print the start of each answer in the chat' },
    { 'assistant.stream', 'argv', 'The panel runs' },
    { 'assistant.view', 'combo', { 'pet', 'tab', 'window' }, 'Opens as (pet needs your character; else a tab)' },
    { 'assistant.transport', 'combo', { 'default', 'agent', 'conpty' }, 'Runs through (default: as your first profile)' },
    { 'assistant.chat', 'argv', '/term ask runs' },
    { 'assistant.ask', 'argv', '/term ask <question> runs, plus the question' },
  } },
  { 'Flat windows in the world', {
    { 'adopt.auto.mappy', 'checkbox', 'Mappy\'s map is a world panel whenever it is open' },
  } },
  { 'Remote windows', {
    { 'windows.auto_open', 'combo', { 'all', 'related', 'none' }, 'New windows of the agent become panels (related: dialogs and windows of apps you have out)' },
    { 'windows.links', 'combo', { 'game', 'host' }, 'Terminal links open in the game (the agent\'s browser, as a panel) or on the desktop' },
    { 'windows.never', 'list', 'Never show in game (app id, desktop id or part of a title; * matches anything)' },
  } },
  { 'Gallery', {
    { 'gallery.prompt', 'checkbox', 'Offer to share screenshots taken while a terminal is on screen' },
    { 'gallery.credit', 'checkbox', 'Credit shared screenshots to my character' },
  } },
  { 'Info bar & hidden UI', {
    { 'host.dtr.mode', 'combo', DTR_MODES, 'Server info bar entry (auto: only without the Umbra widget)' },
    { 'popup.close_on_blur', 'checkbox', 'Info bar popup closes when you click elsewhere' },
    { 'host.keep_visible.user_hidden', 'checkbox', 'Stay visible when you hide the game UI' },
    { 'host.keep_visible.cutscene', 'checkbox', 'Stay visible in cutscenes' },
    { 'host.keep_visible.gpose', 'checkbox', 'Stay visible in group pose' },
  } },
}

local function get(root, path)
  local t = root
  for part in path:gmatch('[^.]+') do
    if type(t) ~= 'table' then return nil end
    t = t[part]
  end
  return t
end

local function set(root, path, value)
  local parts = {}
  for part in path:gmatch('[^.]+') do parts[#parts + 1] = part end
  local t = root
  for i = 1, #parts - 1 do
    if type(t[parts[i]]) ~= 'table' then t[parts[i]] = {} end
    t = t[parts[i]]
  end
  t[parts[#parts]] = value
end

local function file()
  return (GHOSTTY_PLUGIN_DIR or '.') .. '/settings.lua'
end

S.values = {}   -- path -> value, what settings.lua stores

-- path -> schema entry, built on first use
local entries
local function entry(path)
  if not entries then
    entries = {}
    for _, section in ipairs(S.schema) do
      for _, e in ipairs(section[2]) do entries[e[1]] = e end
    end
  end
  return entries[path]
end

-- A saved value as the schema allows it: sliders clamped to their range (a
-- pixel density of 0 or NaN breaks every pet), nil when it cannot be used.
local function sanitize(path, value)
  local e = entry(path)
  if not e or (e[2] ~= 'slider' and e[2] ~= 'slider_int') then return value end
  if type(value) ~= 'number' or value ~= value then return nil end
  if e[2] == 'slider_int' then value = math.floor(value) end
  return math.min(math.max(value, e[3]), e[4])
end

-- Each setting's shipped value, for its tooltip (captured before saved values).
S.defaults = {}

local function capture_defaults(config)
  S.defaults = {}
  for _, section in ipairs(S.schema) do
    for _, e in ipairs(section[2]) do
      local v = get(config, e[1])
      if type(v) ~= 'table' and type(v) ~= 'function' then S.defaults[e[1]] = v end
    end
  end
  if S.defaults.theme == nil then S.defaults.theme = themes.DEFAULT end
end

-- Layer saved values over the config (called from init.lua before returning).
function S.apply(config)
  -- an init.lua copied before themes and tooltips existed still gets them
  if config.themes == nil then config.themes = themes end
  if config.tooltips == nil then config.tooltips = tooltips end
  -- ...and the gallery prompt, whose saved choices land in its module
  if config.gallery == nil then config.gallery = gallery end
  if type(config.theme) ~= 'string' or config.theme == '' then config.theme = themes.DEFAULT end
  capture_defaults(config)
  local chunk = loadfile(file())
  if chunk then
    local ok, saved = pcall(chunk)
    if ok and type(saved) == 'table' then
      for path, value in pairs(saved) do
        value = sanitize(path, value)
        if value ~= nil then
          S.values[path] = value
          set(config, path, value)
        end
      end
    end
  end
  S.config = config
  themes.apply(config, S.values)
  return config
end

-- Switch the theme (the settings window and /term theme) and save it.
function S.set_theme(name)
  local config = S.config or CONFIG
  if type(config) ~= 'table' then return end
  config.theme = name
  S.values.theme = name
  themes.apply(config, S.values)
  S.save()
end

-- The tooltip of setting `path`: its sentence and its default.
local function show_default(v)
  if type(v) == 'boolean' then return v and 'on' or 'off' end
  if type(v) == 'number' then
    if v == math.floor(v) then return string.format('%d', v) end
    return (string.format('%.3f', v):gsub('0+$', ''))
  end
  if v == '' then return 'none' end
  return tostring(v)
end

function S.tooltip(path)
  local tips = (S.config and S.config.tooltips) or tooltips
  local text = tips.settings and tips.settings[path]
  if not text then return nil end
  local d = S.defaults[path]
  if d ~= nil then text = text .. ' Default: ' .. show_default(d) .. '.' end
  return text
end

function S.save()
  local keys = {}
  for k in pairs(S.values) do keys[#keys + 1] = k end
  table.sort(keys)
  local out = { '-- Written by the Ghostty settings window.\nreturn {\n' }
  for _, k in ipairs(keys) do
    local v = S.values[k]
    local lit = type(v) == 'string' and string.format('%q', v) or tostring(v)
    if type(v) == 'table' then -- a list of strings (kind 'list')
      local items = {}
      for i, s in ipairs(v) do items[i] = string.format('%q', tostring(s)) end
      lit = '{ ' .. table.concat(items, ', ') .. ' }'
    end
    out[#out + 1] = string.format('  [%q] = %s,\n', k, lit)
  end
  out[#out + 1] = '}\n'
  local f = io.open(file(), 'w')
  if f then f:write(table.concat(out)) f:close() end
end

-- Unseen ideas on the vote page (lua/vote.lua): the core puts a small dot on
-- the settings button while this is true.
function S.badge()
  return vote.unseen(S.values) > 0
end

-- Back to the defaults. The vote page marker and the gallery's link to your
-- account (/term share unlink ends that) are not settings and stay.
function S.reset()
  local seen = S.values[vote.KEY]
  S.values = { [vote.KEY] = seen, ['gallery.token'] = S.values['gallery.token'] }
  S.save()
end

-- An error inside a tab is logged once (it repeats every frame) and the tab
-- is still closed, so ImGui's tab stack stays balanced.
local last_error
local function report(err)
  err = tostring(err)
  if err == last_error then return end
  last_error = err
  if ghostty and ghostty.log then ghostty.log('settings: ' .. err) end
end

-- The window body: Settings, Changelog and About tabs. Returns true when a
-- setting changed.
function S.draw()
  local ui = ghostty.ui
  local changed = false
  if ui.tabs('##ghostty_settings_tabs') then
    if ui.tab('Settings') then
      local ok, r = pcall(S.draw_settings, ui)
      ui.end_tab()
      if ok then changed = r else report(r) end
    end
    if ui.tab('Changelog') then
      local ok, err = pcall(changelog.draw_changelog, ui)
      ui.end_tab()
      if not ok then report(err) end
    end
    -- the label changes, the ###id keeps it the same tab
    local badge_ok, badge = pcall(S.badge)
    if not badge_ok then report(badge) end
    if ui.tab(badge_ok and badge and 'About (new)###about' or 'About###about') then
      local ok, err = pcall(changelog.draw_about, ui, S)
      ui.end_tab()
      if not ok then report(err) end
    end
    ui.end_tabs()
  end
  return changed
end

function S.draw_settings(ui)
  local config = S.config or CONFIG
  local changed = false
  local save_now = false -- toggles and choices save at once, sliders when released
  ui.text('Changes apply immediately and are saved to settings.lua.')
  ui.separator()
  local tips = config.tooltips or tooltips
  local tip = ui.tip or function() end -- an older core has no tooltips
  for si, section in ipairs(S.schema) do
    local open = ui.header(section[1], si <= 2)
    tip(tips.sections and tips.sections[section[1]])
    if open then
      for _, e in ipairs(section[2]) do
        local path, kind = e[1], e[2]
        local cur = get(config, path)
        local c, v, done = false, cur, false
        if kind == 'theme' then
          c, v = S.draw_theme(ui, e[3] .. '##' .. path, cur, tip, tips)
        elseif kind == 'slider' then
          c, v, done = ui.slider(e[5] .. '##' .. path, tonumber(cur) or e[3], e[3], e[4])
        elseif kind == 'slider_int' then
          c, v, done = ui.slider_int(e[5] .. '##' .. path, math.floor(tonumber(cur) or e[3]), e[3], e[4])
        elseif kind == 'checkbox' then
          c, v = ui.checkbox(e[3] .. '##' .. path, cur and true or false)
        elseif kind == 'combo' then
          c, v = ui.combo(e[4] .. '##' .. path, tostring(cur or ''), e[3])
        elseif kind == 'list' then
          c, v = S.draw_list(ui, path, e[3], cur)
        elseif kind == 'argv' then
          -- a command line, read-only here: edit it in the Lua module
          local words = {}
          for i, w in ipairs(type(cur) == 'table' and cur or {}) do words[i] = string.format('%q', w) end
          ui.wrapped(e[3] .. ': ' .. table.concat(words, ' ') .. ' (edit in lua/)', 0.72, 0.74, 0.78)
        end
        if kind ~= 'theme' then tip(S.tooltip(path)) end
        if c and kind == 'theme' then
          S.set_theme(v)
          changed = true
        elseif c then
          set(config, path, v)
          S.values[path] = v
          changed = true
          if kind == 'checkbox' or kind == 'combo' or kind == 'list' then save_now = true end
        end
        if done then save_now = true end
      end
    end
  end
  S.draw_status(ui)
  ui.separator()
  local reset = ui.button('Reset all to defaults')
  tip(tips.reset)
  if reset then
    S.reset()
    ui.text('Defaults restore on the next reload (/term reload).')
  end
  if save_now then S.save() end
  return changed
end

-- A list of strings: each with a remove button, and a box to add one
-- (Enter or Add). Returns changed and the new list (a copy).
S.drafts = {}
function S.draw_list(ui, path, label, cur)
  local list = type(cur) == 'table' and cur or {}
  ui.text(label)
  local out, changed = {}, false
  for i, item in ipairs(list) do
    if ui.button('x##' .. path .. i) then
      changed = true
    else
      out[#out + 1] = item
    end
    ui.same_line()
    ui.text(tostring(item))
  end
  if #list == 0 then ui.wrapped('(none)', 0.72, 0.74, 0.78) end
  if ui.input then
    local _, draft, entered = ui.input('##add' .. path, S.drafts[path] or '')
    S.drafts[path] = draft
    ui.same_line()
    local add = ui.button('Add##' .. path)
    draft = draft:match('^%s*(.-)%s*$')
    if (add or entered) and draft ~= '' then
      out[#out + 1] = draft
      S.drafts[path] = ''
      changed = true
    end
  end
  return changed, out
end

-- The Theme combo: picking one applies it at once (live), hovering one in
-- the list shows its colours, and the closed combo shows the current one's.
function S.draw_theme(ui, label, cur, tip, tips)
  local names = themes.names()
  if #names == 0 then names = { themes.DEFAULT } end
  local shown = {}
  for i, n in ipairs(names) do
    shown[i] = n
    if themes.source(n) == 'user' then shown[i] = n .. ' (yours)' end
  end
  local current = tostring(cur or themes.DEFAULT)
  local cur_label = current
  for i, n in ipairs(names) do if n == current then cur_label = shown[i] end end
  local c, v, hovered = ui.combo(label, cur_label, shown)
  if hovered then
    local name = names[hovered] or current
    tip(name .. ': ' .. (tips.theme_item or ''), themes.swatch(name), true)
  else
    tip((S.tooltip('theme') or tips.theme or ''), themes.swatch(current))
  end
  if c then
    for i, n in ipairs(shown) do
      if n == v then return true, names[i] end
    end
  end
  return false, current
end

-- Read-only: how the core is hosted, what it registered, and which lua files
-- in the config directory override or were set aside by the migration.
local function lua_files(dir)
  local out = {}
  for _, name in ipairs((ghostty.listdir and ghostty.listdir(dir)) or {}) do
    if name:match('%.lua$') then out[#out + 1] = name end
  end
  table.sort(out)
  return #out > 0 and table.concat(out, ', ') or 'none'
end

function S.draw_status(ui)
  if not ui.header('Plugin status') then return end
  local info = ghostty.host_info and ghostty.host_info()
  if not info then ui.text('No host information (old core).') return end
  ui.text('Core: ' .. info.state .. (info.reason ~= '' and (' (' .. info.reason .. ')') or ''))
  ui.text('Umbra loaded: ' .. (info.umbra and 'yes' or 'no') .. ', toolbar widget seen: ' .. (info.widget and 'yes' or 'no'))
  ui.text('Info bar entry shown: ' .. (info.dtr_shown and 'yes' or 'no'))
  local names = {}
  for name, ok in pairs(info.commands) do names[#names + 1] = name .. (ok and '' or ' (not registered)') end
  table.sort(names)
  ui.text('Commands: ' .. (#names > 0 and table.concat(names, ' ') or 'none'))
  if info.events_dropped > 0 then ui.text('Dropped events: ' .. info.events_dropped) end
  local config = GHOSTTY_CONFIG_DIR or info.config_dir
  ui.wrapped('Config: ' .. config, 0.72, 0.74, 0.78)
  ui.wrapped('Shipped files: ' .. (GHOSTTY_INSTALL_DIR or info.install_dir), 0.72, 0.74, 0.78)
  ui.text('Your overrides (lua/): ' .. lua_files(config .. '/lua'))
  local legacy = lua_files(config .. '/legacy-lua')
  if legacy ~= 'none' then
    ui.wrapped('Kept from the Umbra install, not loaded (legacy-lua/): ' .. legacy, 0.92, 0.74, 0.40)
  end
  local f = io.open(config .. '/migrated-from-umbra.txt', 'r')
  if f then
    ui.wrapped(f:read('l') or 'Migrated from the Umbra install.', 0.66, 0.62, 0.78)
    f:close()
  end
end

return S
