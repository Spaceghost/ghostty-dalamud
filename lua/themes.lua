-- Colour themes: the terminal's palette and default colours, and the glass
-- UI's colours (dropdown, windows, world screens, taskbar, tooltips).
--
-- A theme is a Ghostty theme file, so any of the hundreds of Ghostty (and
-- iTerm2-derived) themes can be dropped in as they are:
--
--   palette = 0=#1d1f21          (0..255)
--   background = #000000         (with or without the #)
--   foreground = ffffff
--   cursor-color = ...
--   cursor-text = ...
--   selection-background = ...
--   selection-foreground = ...
--
-- Other Ghostty keys are ignored. Lines that cannot be read are skipped with
-- a warning in the log. The plugin's own extension lives in comments, so the
-- file still loads in Ghostty:
--
--   # ffxiv: accent = #c8a05a
--
-- (keys in M.CHROME_KEYS, plus `bell`: the bell's custom accent colour).
-- Whatever a theme leaves out of the extension is derived from its terminal
-- colours. A theme can also be a .lua file returning the same keys:
--   return { background = '#282828', palette = { [0] = '#282828' }, ffxiv = { accent = '#fabd2f' } }
--
-- Themes load from themes/ beside the plugin (shipped) and themes/ in the
-- config directory (yours; a theme there wins over a shipped one of the
-- same name). The name is the file name without .theme or .lua.

local M = {}

M.DEFAULT = 'spaceghost'

-- Ghostty key -> field in the resolved terminal table.
M.TERMINAL_KEYS = {
  ['background'] = 'background',
  ['foreground'] = 'foreground',
  ['cursor-color'] = 'cursor',
  ['cursor-text'] = 'cursor_text',
  ['selection-background'] = 'selection_background',
  ['selection-foreground'] = 'selection_foreground',
}

-- The glass UI's colours, in the order the core reads them (core/theme.nelua).
M.CHROME_KEYS = {
  'accent', 'accent-2', 'ok', 'ink', 'ink-dim', 'ink-faint',
  'glass-top', 'glass-bottom', 'glass-flat', 'glow', 'panel', 'tooltip', 'tab',
  'close', 'close-idle', 'full', 'full-idle', 'popin', 'popin-idle', 'sleep', 'sleep-idle',
  'chip', 'chip-hot', 'chip-ink', 'label', 'label-ink',
}

-- libghostty-vt's own defaults: what a theme that leaves them out starts from.
M.BASE = {
  background = 0x000000, foreground = 0xffffff,
  palette = { [0] = 0x1d1f21, 0xcc6666, 0xb5bd68, 0xf0c674, 0x81a2be, 0xb294bb, 0x8abeb7, 0xc5c8c6,
    0x666666, 0xd54e53, 0xb9ca4a, 0xe7c547, 0x7aa6da, 0xc397d8, 0x70c0b1, 0xeaeaea },
}

local chrome_known = {}
for _, k in ipairs(M.CHROME_KEYS) do chrome_known[k] = true end
chrome_known.bell = true

local function log(msg)
  if ghostty and ghostty.log then ghostty.log(msg) end
end

-- '#rrggbb', 'rrggbb', '#rgb' or 'rgb' -> 0xRRGGBB, or nil.
function M.color(s)
  if type(s) == 'number' then return (s >= 0 and s <= 0xffffff and s == math.floor(s)) and math.floor(s) or nil end
  if type(s) ~= 'string' then return nil end
  s = s:gsub('^%s+', ''):gsub('%s+$', ''):gsub('^"(.*)"$', '%1')
  local hex = s:match('^#?(%x+)$')
  if not hex then return nil end
  if #hex == 3 then hex = hex:gsub('.', '%0%0') end
  if #hex ~= 6 then return nil end
  return tonumber(hex, 16)
end

function M.hex(c)
  return c and string.format('#%06x', c) or 'unset'
end

-- One setting into theme `t`; returns an error text for a value it cannot use.
local function put(t, key, value)
  if key == 'palette' then
    local idx, col = tostring(value):match('^%s*(%d+)%s*=%s*(.-)%s*$')
    idx = tonumber(idx)
    if not idx or idx > 255 then return 'palette wants N=#rrggbb with N 0..255, got "' .. tostring(value) .. '"' end
    local c = M.color(col)
    if not c then return 'palette ' .. idx .. ': not a colour: "' .. tostring(col) .. '"' end
    t.palette[idx] = c
    return nil
  end
  local field = M.TERMINAL_KEYS[key]
  if field then
    local c = M.color(value)
    if not c then return key .. ': not a colour: "' .. tostring(value) .. '"' end
    t[field] = c
  end
  return nil -- another Ghostty setting: not ours, not an error
end

local function put_chrome(t, key, value)
  if not chrome_known[key] then return 'unknown ffxiv key "' .. key .. '"' end
  local c = M.color(value)
  if not c then return 'ffxiv ' .. key .. ': not a colour: "' .. tostring(value) .. '"' end
  t.chrome[key] = c
  return nil
end

local function new_theme(name)
  return { name = name, palette = {}, chrome = {}, warnings = {} }
end

-- Parse the text of a Ghostty theme file. Returns the theme; unreadable
-- lines are listed in theme.warnings ("line N: why") and otherwise ignored.
function M.parse(text, name)
  local t = new_theme(name or '?')
  local n = 0
  for line in (text .. '\n'):gmatch('([^\n]*)\n') do
    n = n + 1
    line = line:gsub('\r$', ''):gsub('^%s+', ''):gsub('%s+$', '')
    local err
    if line:sub(1, 1) == '#' then
      local key, value = line:match('^#%s*ffxiv:%s*([%w%-_]+)%s*=%s*(.-)$')
      if key then err = put_chrome(t, key, value)
      elseif line:match('^#%s*ffxiv:') then err = 'ffxiv line wants "# ffxiv: key = #rrggbb"' end
    elseif line ~= '' then
      local key, value = line:match('^([%w%-_]+)%s*=%s*(.-)$')
      if not key then err = 'not "key = value": "' .. line .. '"'
      else err = put(t, key, value) end
    end
    if err then t.warnings[#t.warnings + 1] = 'line ' .. n .. ': ' .. err end
  end
  return t
end

-- A .lua theme: a table with the Ghostty keys, palette = { [i] = colour },
-- and ffxiv = { key = colour }.
function M.from_table(tbl, name)
  local t = new_theme(name or '?')
  if type(tbl) ~= 'table' then t.warnings[1] = 'a .lua theme must return a table' return t end
  for key, value in pairs(tbl) do
    local err
    if key == 'palette' and type(value) == 'table' then
      for i, c in pairs(value) do
        local e = put(t, 'palette', tostring(i) .. '=' .. (type(c) == 'number' and string.format('%06x', c) or tostring(c)))
        if e then t.warnings[#t.warnings + 1] = e end
      end
    elseif key == 'ffxiv' and type(value) == 'table' then
      for k, c in pairs(value) do
        local e = put_chrome(t, k, c)
        if e then t.warnings[#t.warnings + 1] = e end
      end
    elseif type(key) == 'string' then
      err = put(t, key, value)
    end
    if err then t.warnings[#t.warnings + 1] = err end
  end
  return t
end

-- Directories --------------------------------------------------------------------------

-- Overridable (tests); by default the plugin's and the config directory's themes/.
M.shipped_dir = nil
M.user_dir = nil

function M.dirs()
  local shipped = M.shipped_dir or ((GHOSTTY_INSTALL_DIR or GHOSTTY_PLUGIN_DIR or '.') .. '/themes')
  local user = M.user_dir or ((GHOSTTY_CONFIG_DIR or GHOSTTY_PLUGIN_DIR or '.') .. '/themes')
  return shipped, user
end

local index      -- name -> { path, user }
local cache = {} -- name -> parsed theme
local warned = {}

local function theme_name(file)
  if file:sub(1, 1) == '.' then return nil end
  local base, ext = file:match('^(.*)%.([%w]+)$')
  if ext == 'theme' or ext == 'lua' then return base, ext end
  if ext == 'md' or ext == 'txt' or ext == 'json' or ext == 'png' or ext == 'jpg' then return nil end
  return file, nil -- Ghostty's own theme files have no extension
end

local function scan_dir(dir, user, out)
  local names = ghostty and ghostty.listdir and ghostty.listdir(dir)
  if not names then return end
  table.sort(names)
  for _, file in ipairs(names) do
    local name, ext = theme_name(file)
    if name and name ~= '' then
      -- within one directory a .theme or .lua beats an extensionless file of the same name
      local prev = out[name]
      if not (prev and prev.dir == dir and prev.ext and not ext) then
        out[name] = { path = dir .. '/' .. file, user = user, dir = dir, ext = ext }
      end
    end
  end
end

-- Forget what was read; the next lookup lists the directories again.
function M.rescan()
  index = {}
  cache = {}
  warned = {}
  local shipped, user = M.dirs()
  scan_dir(shipped, false, index)
  if user ~= shipped then scan_dir(user, true, index) end
  return index
end

local function read_file(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local text = f:read('a')
  f:close()
  return text
end

-- Every theme name, sorted.
function M.names()
  if not index then M.rescan() end
  local out = {}
  for name in pairs(index) do out[#out + 1] = name end
  table.sort(out, function(a, b) return a:lower() < b:lower() end)
  return out
end

-- Where a theme comes from: 'shipped', 'user' or nil.
function M.source(name)
  if not index then M.rescan() end
  local e = index[name]
  return e and (e.user and 'user' or 'shipped') or nil
end

-- The parsed theme `name` (exact, else ignoring case), or nil.
function M.get(name)
  if type(name) ~= 'string' then return nil end
  if not index then M.rescan() end
  local e = index[name]
  if not e then
    for n, entry in pairs(index) do
      if n:lower() == name:lower() then name, e = n, entry break end
    end
  end
  if not e then return nil end
  if cache[name] then return cache[name] end
  local t
  if e.path:match('%.lua$') then
    local chunk, err = loadfile(e.path, 't', {})
    local ok, tbl = false, err
    if chunk then ok, tbl = pcall(chunk) end
    t = M.from_table(ok and tbl or nil, name)
    if not ok then t.warnings[1] = tostring(tbl) end
  else
    local text = read_file(e.path)
    if not text then return nil end
    t = M.parse(text, name)
  end
  t.path = e.path
  t.user = e.user
  for _, w in ipairs(t.warnings) do log('theme ' .. name .. ': ' .. w .. ' (ignored)') end
  cache[name] = t
  return t
end

-- Resolving ----------------------------------------------------------------------------

local function ch(c, s) return (c >> s) & 0xff end
local function mix(a, b, t)
  local function m(s) return math.floor(ch(a, s) + (ch(b, s) - ch(a, s)) * t + 0.5) end
  return (m(16) << 16) | (m(8) << 8) | m(0)
end

-- Chrome colours a theme leaves out, from its terminal colours.
local function derive(chrome, bg, fg, pal)
  local function p(i) return pal[i] or M.BASE.palette[i] end
  local d = {
    accent = p(3), ['accent-2'] = p(6), ok = p(2),
    ink = fg, ['ink-dim'] = mix(fg, bg, 0.35), ['ink-faint'] = mix(fg, bg, 0.6),
    ['glass-top'] = mix(bg, fg, 0.1), ['glass-bottom'] = mix(bg, 0x000000, 0.3), ['glass-flat'] = bg,
    glow = p(4), panel = bg, tooltip = bg, tab = fg,
    close = p(1), full = p(4), popin = p(3), sleep = p(5),
    chip = mix(bg, fg, 0.12), ['chip-ink'] = fg, label = bg, ['label-ink'] = fg,
  }
  for k, v in pairs(d) do if chrome[k] == nil then chrome[k] = v end end
  if chrome['chip-hot'] == nil then chrome['chip-hot'] = mix(chrome.accent, bg, 0.45) end
  -- idle title buttons: their hovered colour sunk into the background
  for _, k in ipairs({ 'close', 'full', 'popin', 'sleep' }) do
    if chrome[k .. '-idle'] == nil then chrome[k .. '-idle'] = mix(chrome[k], bg, 0.6) end
  end
  return chrome
end

-- What the core applies: { name, terminal = { background, foreground, cursor,
-- cursor_text, selection_background, selection_foreground, palette = { [i] } },
-- chrome = { every M.CHROME_KEYS key }, bell = colour or nil }. Colours are
-- 0xRRGGBB; terminal fields a theme leaves out stay nil (libghostty's
-- default). An unknown name falls back to spaceghost, and with no theme
-- files at all the result is empty and the core keeps its built-in look.
function M.resolve(name)
  name = type(name) == 'string' and name ~= '' and name or M.DEFAULT
  local t = M.get(name)
  if not t then
    if not warned[name] then
      warned[name] = true
      log('theme "' .. name .. '" not found, using ' .. M.DEFAULT)
    end
    t = M.get(M.DEFAULT)
    if not t then return { name = M.DEFAULT, terminal = { palette = {} }, chrome = {} } end
  end
  if t.resolved then return t.resolved end
  local term = { palette = {} }
  for _, field in pairs(M.TERMINAL_KEYS) do term[field] = t[field] end
  for i, c in pairs(t.palette) do term.palette[i] = c end
  local chrome = {}
  for k, v in pairs(t.chrome) do if k ~= 'bell' then chrome[k] = v end end
  derive(chrome, t.background or M.BASE.background, t.foreground or M.BASE.foreground, t.palette)
  t.resolved = { name = t.name, terminal = term, chrome = chrome, bell = t.chrome.bell }
  return t.resolved
end

-- A few colours that show a theme at a glance: background, foreground,
-- red..cyan, the accent and the glow.
function M.swatch(name)
  local r = M.resolve(name)
  local term = r.terminal
  local out = { term.background or M.BASE.background, term.foreground or M.BASE.foreground }
  for i = 1, 6 do out[#out + 1] = term.palette[i] or M.BASE.palette[i] end
  out[#out + 1] = r.chrome.accent or 0xc8a05a
  out[#out + 1] = r.chrome.glow or 0x5a96dc
  return out
end

-- The bell's custom accent follows the theme (lua/bell.lua, preset 'custom')
-- unless it was set in the settings window. `saved` is settings.lua's values.
local bell_default
function M.apply(config, saved)
  if type(config) ~= 'table' or type(config.bell) ~= 'table' then return end
  local acc = config.bell.accent
  if type(acc) ~= 'table' then return end
  if not bell_default then bell_default = { r = acc.r, g = acc.g, b = acc.b } end
  saved = saved or {}
  local c = M.resolve(config.theme).bell
  for _, k in ipairs({ 'r', 'g', 'b' }) do
    if saved['bell.accent.' .. k] == nil then
      local s = k == 'r' and 16 or (k == 'g' and 8 or 0)
      acc[k] = c and ((c >> s) & 0xff) / 255 or bell_default[k]
    end
  end
end

-- /term theme [name]: list the themes, or switch to one. Returns the message
-- to show and the new name when it switched.
function M.command(args, current)
  local name = tostring(args or ''):gsub('^%s+', ''):gsub('%s+$', '')
  if name == '' or name == 'list' then
    M.rescan()
    local parts = {}
    for _, n in ipairs(M.names()) do
      local mark = n == current and '*' or ''
      parts[#parts + 1] = n .. mark .. (M.source(n) == 'user' and ' (yours)' or '')
    end
    if #parts == 0 then return 'no themes found in ' .. (M.dirs()) end
    return 'themes: ' .. table.concat(parts, ', ')
  end
  local t = M.get(name)
  if not t then
    M.rescan()
    t = M.get(name)
  end
  if not t then return 'no theme "' .. name .. '"; /term theme lists them' end
  return 'theme: ' .. t.name, t.name
end

return M
