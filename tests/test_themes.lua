-- lua/themes.lua, lua/tooltips.lua and their place in lua/settings.lua (run
-- by tests/test_themes.nelua, which provides the core's ghostty table):
-- reading Ghostty theme files, user themes over shipped ones, spaceghost
-- against the colours the core had built in, the shipped themes against
-- their upstream colours, /term theme, the bell accent, the Theme combo and
-- a tooltip for every setting.
local ROOT, SCRATCH = ...
package.path = ROOT .. '/lua/?.lua;' .. package.path

local logged = {}
ghostty.log = function(msg) logged[#logged + 1] = msg end
local function logged_with(text)
  for _, m in ipairs(logged) do
    if m:find(text, 1, true) then return true end
  end
  return false
end

local function fresh()
  for _, m in ipairs({ 'themes', 'settings', 'tooltips', 'vote', 'changelog' }) do package.loaded[m] = nil end
  local T = require('themes')
  T.shipped_dir = ROOT .. '/themes'
  T.user_dir = SCRATCH .. '/no-user-themes'
  return T
end

local function write(path, text)
  local f = assert(io.open(path, 'wb'))
  f:write(text)
  f:close()
end

-- Parsing --------------------------------------------------------------------------------
do
  local T = fresh()
  local t = T.parse(table.concat({
    '# a comment = not a setting',
    '',
    '   palette = 0=#010203',
    'palette=1=#0A0B0C',
    'palette =  15 = 102030  ',
    'palette = 255=#fff',
    'palette = 256=#000000',
    'palette = x=#000000',
    'palette = 7=#nothex',
    'background   =   #102030   ',
    'foreground = abcdef\r',
    'cursor-color = "#112233"',
    'cursor-text = #445566',
    'selection-background = #778899',
    'selection-foreground = #aabbcc',
    'split-divider-color = #313244',
    'font-family = "Iosevka"',
    'this line has no equals sign',
    'foreground-ish',
    'background = transparent-ish',
    '# ffxiv: accent = #c8a05a',
    '#ffxiv:glow=#010101',
    '# ffxiv: sparkle = #010101',
    '# ffxiv: ok',
  }, '\n'), 'probe')
  assert(t.palette[0] == 0x010203 and t.palette[1] == 0x0a0b0c and t.palette[15] == 0x102030, 'spacing and case')
  assert(t.palette[255] == 0xffffff, 'three-digit colours and the last index')
  assert(t.background == 0x102030 and t.foreground == 0xabcdef, 'bare hex, CRLF')
  assert(t.cursor == 0x112233 and t.cursor_text == 0x445566, 'quoted value')
  assert(t.selection_background == 0x778899 and t.selection_foreground == 0xaabbcc)
  assert(t.chrome.accent == 0xc8a05a and t.chrome.glow == 0x010101, 'the ffxiv extension')
  local n = 0
  for _ in pairs(t.palette) do n = n + 1 end
  assert(n == 4, 'bad palette lines set nothing')
  local w = table.concat(t.warnings, '\n')
  assert(#t.warnings == 8, 'eight bad lines: ' .. w)
  for _, bad in ipairs({ 'line 7:', 'line 8:', 'line 9:', 'line 18:', 'line 19:', 'line 20:', 'line 23:', 'line 24:' }) do
    assert(w:find(bad, 1, true), 'warned about ' .. bad .. '\n' .. w)
  end
  assert(not w:find('split-divider', 1, true) and not w:find('font-family', 1, true), 'other Ghostty keys are not errors')
  assert(T.color('#abc') == 0xaabbcc and T.color('ABCDEF') == 0xabcdef and T.color('#abcd') == nil and T.color('red') == nil)
  print('parse OK')
end

-- Directories: user themes win, Ghostty's extensionless files, .lua themes ---------------
do
  local T = fresh()
  local shipped, user = SCRATCH .. '/themes-shipped', SCRATCH .. '/themes-user'
  assert(ghostty.mkdir(shipped) and ghostty.mkdir(user))
  write(shipped .. '/mine.theme', 'background = #111111\nforeground = #eeeeee\n')
  write(shipped .. '/only-shipped.theme', 'background = #222222\n')
  write(user .. '/mine.theme', 'background = #333333\npalette = 999=#000000\n')
  write(user .. '/Some Ghostty Theme', 'background = #444444\n')
  write(user .. '/README.md', 'background = #555555\n')
  write(user .. '/tabled.lua', "return { background = '#666666', palette = { [2] = '#00ff00', [3] = 0x0000ff }, ffxiv = { accent = '#777777' } }")
  write(user .. '/broken.lua', "return {")
  T.shipped_dir, T.user_dir = shipped, user
  T.rescan()
  local names = table.concat(T.names(), ',')
  assert(names == 'broken,mine,only-shipped,Some Ghostty Theme,tabled', names)
  assert(T.source('mine') == 'user' and T.source('only-shipped') == 'shipped')
  logged = {}
  local mine = T.get('mine')
  assert(mine.background == 0x333333 and mine.foreground == nil, 'the user copy replaces the shipped one whole')
  assert(logged_with('theme mine: line 2:') and logged_with('(ignored)'), 'a bad line is logged once, when read')
  assert(T.get('some ghostty theme').background == 0x444444, 'names without an extension, any case')
  local tabled = T.get('tabled')
  assert(tabled.background == 0x666666 and tabled.palette[2] == 0x00ff00 and tabled.palette[3] == 0x0000ff and tabled.chrome.accent == 0x777777, '.lua themes')
  assert(#T.get('broken').warnings > 0, 'a broken .lua theme is a warning, not an error')
  -- a missing theme falls back to spaceghost, or to nothing when there is none
  logged = {}
  local r = T.resolve('nope')
  assert(r.name == 'spaceghost' and next(r.chrome) == nil and next(r.terminal.palette) == nil, 'nothing to fall back to: empty')
  assert(logged_with('theme "nope" not found'), 'logged')
  -- everything a theme leaves out of the extension is derived
  local d = T.resolve('only-shipped')
  for _, k in ipairs(T.CHROME_KEYS) do assert(type(d.chrome[k]) == 'number', 'derived ' .. k) end
  assert(d.chrome.panel == 0x222222 and d.chrome.ink == 0xffffff, 'from its background and the default foreground')
  assert(T.resolve('tabled').chrome.accent == 0x777777, 'given ones stay')
  print('directories OK')
end

-- spaceghost: exactly the colours the core had built in ----------------------------------
local SPACEGHOST_CHROME = { -- core/theme.nelua CHROME_SPACEGHOST, the pre-theme constants
  accent = 0xc8a05a, ['accent-2'] = 0x78dcff, ok = 0x8cf096, ink = 0xf0e6dc, ['ink-dim'] = 0xaaa5a0, ['ink-faint'] = 0x787470,
  ['glass-top'] = 0x222732, ['glass-bottom'] = 0x0a0c11, ['glass-flat'] = 0x101218, glow = 0x5a96dc, panel = 0x0a0d12,
  tooltip = 0x101218, tab = 0xffffff, close = 0xbe3c32, ['close-idle'] = 0x5a2824, full = 0x466ea0, ['full-idle'] = 0x283246,
  popin = 0x78643c, ['popin-idle'] = 0x3c3428, sleep = 0x505a82, ['sleep-idle'] = 0x2c2e42,
  chip = 0x322c28, ['chip-hot'] = 0x785a32, ['chip-ink'] = 0xebe1d2, label = 0x0c1016, ['label-ink'] = 0xe6dec8,
}
do
  local T = fresh()
  local r = T.resolve('spaceghost')
  assert(#T.get('spaceghost').warnings == 0)
  local term = r.terminal
  assert(term.background == 0x000000 and term.foreground == 0xffffff, "libghostty's default background and foreground")
  assert(term.cursor == nil and term.cursor_text == nil, 'the cursor keeps following the foreground')
  assert(term.selection_background == nil and term.selection_foreground == nil, 'a selection keeps inverting')
  for i = 0, 15 do assert(term.palette[i] == T.BASE.palette[i], 'palette ' .. i) end
  assert(term.palette[16] == nil, 'the 256-colour cube stays libghostty\'s')
  local n = 0
  for k, v in pairs(r.chrome) do
    n = n + 1
    assert(SPACEGHOST_CHROME[k] == v, k .. ' = ' .. T.hex(v))
  end
  assert(n == #T.CHROME_KEYS and n == 26, 'every chrome colour, nothing derived')
  assert(r.bell == nil, 'the bell keeps its own default')
  assert(T.resolve(nil).name == 'spaceghost' and T.resolve('').name == 'spaceghost', 'the default')
  print('spaceghost OK')
end

-- The shipped themes against upstream ------------------------------------------------------
-- catppuccin/ghostty themes/catppuccin-*.conf and Ghostty's bundled "Gruvbox Dark"
-- (iTerm2-Color-Schemes), fetched 2026-09-19.
local UPSTREAM = {
  ['gruvbox-dark'] = { bg = 0x282828, fg = 0xebdbb2, cursor = 0xebdbb2, cursor_text = 0x282828, sel_bg = 0x665c54, sel_fg = 0xebdbb2,
    palette = { 0x282828, 0xcc241d, 0x98971a, 0xd79921, 0x458588, 0xb16286, 0x689d6a, 0xa89984,
                0x928374, 0xfb4934, 0xb8bb26, 0xfabd2f, 0x83a598, 0xd3869b, 0x8ec07c, 0xebdbb2 } },
  ['catppuccin'] = { bg = 0x1e1e2e, fg = 0xcdd6f4, cursor = 0xf5e0dc, cursor_text = 0x11111b, sel_bg = 0x353749, sel_fg = 0xcdd6f4,
    palette = { 0x45475a, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xa6adc8,
                0x585b70, 0xf38ba8, 0xa6e3a1, 0xf9e2af, 0x89b4fa, 0xf5c2e7, 0x94e2d5, 0xbac2de } },
  ['catppuccin-macchiato'] = { bg = 0x24273a, fg = 0xcad3f5, cursor = 0xf4dbd6, cursor_text = 0x181926, sel_bg = 0x3a3e53, sel_fg = 0xcad3f5,
    palette = { 0x494d64, 0xed8796, 0xa6da95, 0xeed49f, 0x8aadf4, 0xf5bde6, 0x8bd5ca, 0xa5adcb,
                0x5b6078, 0xed8796, 0xa6da95, 0xeed49f, 0x8aadf4, 0xf5bde6, 0x8bd5ca, 0xb8c0e0 } },
  ['catppuccin-frappe'] = { bg = 0x303446, fg = 0xc6d0f5, cursor = 0xf2d5cf, cursor_text = 0x232634, sel_bg = 0x44495d, sel_fg = 0xc6d0f5,
    palette = { 0x51576d, 0xe78284, 0xa6d189, 0xe5c890, 0x8caaee, 0xf4b8e4, 0x81c8be, 0xa5adce,
                0x626880, 0xe78284, 0xa6d189, 0xe5c890, 0x8caaee, 0xf4b8e4, 0x81c8be, 0xb5bfe2 } },
  ['catppuccin-latte'] = { bg = 0xeff1f5, fg = 0x4c4f69, cursor = 0xdc8a78, cursor_text = 0xeff1f5, sel_bg = 0xd8dae1, sel_fg = 0x4c4f69,
    palette = { 0x5c5f77, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xacb0be,
                0x6c6f85, 0xd20f39, 0x40a02b, 0xdf8e1d, 0x1e66f5, 0xea76cb, 0x179299, 0xbcc0cc } },
}
-- catppuccin's palette (https://catppuccin.com/palette): what the chrome takes
local CATPPUCCIN_ACCENTS = {
  ['catppuccin'] = { accent = 0xcba6f7, glow = 0xb4befe, ink = 0xcdd6f4, ['glass-bottom'] = 0x11111b },
  ['catppuccin-macchiato'] = { accent = 0xc6a0f6, glow = 0xb7bdf8, ink = 0xcad3f5, ['glass-bottom'] = 0x181926 },
  ['catppuccin-frappe'] = { accent = 0xca9ee6, glow = 0xbabbf1, ink = 0xc6d0f5, ['glass-bottom'] = 0x232634 },
  ['catppuccin-latte'] = { accent = 0x8839ef, glow = 0x7287fd, ink = 0x4c4f69, ['glass-bottom'] = 0xdce0e8 },
  ['gruvbox-dark'] = { accent = 0xfabd2f, glow = 0xfe8019, ink = 0xebdbb2, ['glass-bottom'] = 0x1d2021 },
}
do
  local T = fresh()
  local names = table.concat(T.names(), ',')
  assert(names == 'catppuccin,catppuccin-frappe,catppuccin-latte,catppuccin-macchiato,gruvbox-dark,spaceghost', names)
  for name, up in pairs(UPSTREAM) do
    local t = T.get(name)
    assert(#t.warnings == 0, name .. ': ' .. table.concat(t.warnings, '; '))
    local term = T.resolve(name).terminal
    assert(term.background == up.bg and term.foreground == up.fg and term.cursor == up.cursor and term.cursor_text == up.cursor_text, name)
    assert(term.selection_background == up.sel_bg and term.selection_foreground == up.sel_fg, name .. ' selection')
    for i = 0, 15 do assert(term.palette[i] == up.palette[i + 1], name .. ' palette ' .. i .. ' = ' .. T.hex(term.palette[i])) end
    local chrome = T.resolve(name).chrome
    for k, v in pairs(CATPPUCCIN_ACCENTS[name]) do assert(chrome[k] == v, name .. ' ' .. k) end
    for _, k in ipairs(T.CHROME_KEYS) do assert(type(chrome[k]) == 'number', name .. ' has ' .. k) end
    assert(T.resolve(name).bell, name .. ' sets the bell accent')
    assert(#T.swatch(name) == 10 and T.swatch(name)[1] == up.bg, 'swatch')
  end
  print('upstream OK')
end

-- /term theme and the bell accent ---------------------------------------------------------------
do
  local T = fresh()
  local list = T.command('', 'gruvbox-dark')
  assert(list:find('gruvbox-dark*', 1, true) and list:find('spaceghost', 1, true), list)
  assert(T.command('list') == T.command(''))
  local msg, name = T.command('  catppuccin-latte ')
  assert(msg == 'theme: catppuccin-latte' and name == 'catppuccin-latte', msg)
  msg, name = T.command('Gruvbox-Dark')
  assert(name == 'gruvbox-dark', 'any case')
  msg, name = T.command('nope')
  assert(name == nil and msg:find('no theme "nope"', 1, true), msg)

  local config = { theme = 'gruvbox-dark', bell = { accent = { r = 0.55, g = 0.82, b = 1.0 } } }
  T.apply(config, {})
  assert(math.abs(config.bell.accent.r - 0x8e / 255) < 1e-9 and math.abs(config.bell.accent.b - 0x7c / 255) < 1e-9, 'the theme sets it')
  config.theme = 'spaceghost'
  T.apply(config, {})
  assert(config.bell.accent.r == 0.55 and config.bell.accent.g == 0.82 and config.bell.accent.b == 1.0, 'spaceghost gives the default back')
  config.theme = 'catppuccin'
  config.bell.accent.g = 0.1
  T.apply(config, { ['bell.accent.g'] = 0.1 })
  assert(config.bell.accent.g == 0.1 and math.abs(config.bell.accent.r - 0x89 / 255) < 1e-9, 'a value set in the window stays')
  print('command OK')
end

-- The settings window: tooltips for everything, the Theme combo ----------------------------------
do
  local dir = SCRATCH .. '/themes-settings'
  assert(ghostty.mkdir(dir))
  GHOSTTY_PLUGIN_DIR = dir
  os.remove(dir .. '/settings.lua')
  local T = fresh()
  local S = require('settings')
  local tips = require('tooltips')
  local config = S.apply({ bell = { accent = { r = 0.55, g = 0.82, b = 1.0 } }, dropdown = { height = 0.45, glass = true },
    world = { occlusion = 'depth' }, toggle_gamepad_button = 'select' })
  assert(config.themes == T and config.tooltips == tips and config.theme == 'spaceghost', 'an old init.lua gets themes and tooltips')
  for _, section in ipairs(S.schema) do
    assert(tips.sections[section[1]], 'section tooltip: ' .. section[1])
    for _, e in ipairs(section[2]) do
      local text = S.tooltip(e[1])
      assert(text and #text > 10, 'tooltip for ' .. e[1])
      assert(not text:find('\n'), 'one line: ' .. e[1])
    end
  end
  assert(S.tooltip('dropdown.height') == tips.settings['dropdown.height'] .. ' Default: 0.45.', S.tooltip('dropdown.height'))
  assert(S.tooltip('dropdown.glass'):find('Default: on.', 1, true) and S.tooltip('world.occlusion'):find('Default: depth.', 1, true))
  assert(S.tooltip('theme'):find('Default: spaceghost.', 1, true))
  for _, k in ipairs({ 'tab.new', 'tab.profiles', 'tab.window', 'tab.pin', 'tab.pet', 'tab.min', 'tab.cfg', 'tab.cfg.badge', 'tab.hide',
    'tab.close', 'window.dock', 'window.pet', 'window.close', 'world.close', 'world.full', 'world.full.off', 'world.popin',
    'world.sleep.on', 'world.sleep.off', 'world.resize', 'chip.min', 'chip.tab', 'chip.win', 'chip.pet' }) do
    assert(type(tips[k]) == 'string' and #tips[k] > 0, 'core tooltip ' .. k)
  end

  -- a fake ui: the Theme combo picks gruvbox-dark, hovering shows swatches
  local shown, pick, hover = {}, nil, nil
  local ui = {
    tabs = function() return true end, tab = function() return true end, end_tab = function() end, end_tabs = function() end,
    header = function(label) return label == 'Theme' end,
    text = function() end, wrapped = function() end, spacing = function() end, separator = function() end, same_line = function() end,
    button = function() return false end,
    combo = function(label, cur, options)
      assert(label == 'Theme##theme' and cur == 'spaceghost', label .. ' ' .. cur)
      local hi
      for i, o in ipairs(options) do if o == hover then hi = i end end
      if pick then return true, pick, nil end
      return false, cur, hi
    end,
    tip = function(text, swatch, now) shown[#shown + 1] = { text = text, swatch = swatch, now = now } end,
  }
  ghostty.ui = ui
  hover = 'catppuccin-latte'
  assert(S.draw() == false, 'hovering changes nothing')
  local combo_tip
  for _, s in ipairs(shown) do if s.swatch then combo_tip = s end end
  assert(combo_tip and combo_tip.now and combo_tip.text:find('catppuccin-latte', 1, true) and combo_tip.swatch[1] == 0xeff1f5, 'the hovered theme\'s swatch')
  assert(shown[1].text == tips.sections['Theme'], 'the section header explains itself')
  shown, hover, pick = {}, nil, 'gruvbox-dark'
  assert(S.draw() == true, 'picking one is a change')
  assert(config.theme == 'gruvbox-dark' and S.values.theme == 'gruvbox-dark', 'applied at once')
  assert(math.abs(config.bell.accent.g - 0xc0 / 255) < 1e-9, 'with its bell accent')
  local f = assert(io.open(dir .. '/settings.lua'))
  assert(f:read('a'):find('["theme"] = "gruvbox-dark"', 1, true), 'saved')
  f:close()
  -- loaded again: the theme comes back from settings.lua
  local T2 = fresh()
  local S2 = require('settings')
  local c2 = S2.apply({})
  assert(c2.theme == 'gruvbox-dark' and T2.resolve(c2.theme).terminal.background == 0x282828, 'restored')
  -- /term theme goes through set_theme too
  S2.set_theme('catppuccin')
  local S3 = (function() fresh() return require('settings') end)()
  assert(S3.apply({}).theme == 'catppuccin', 'saved by set_theme')
  os.remove(dir .. '/settings.lua')
  print('settings OK')
end
