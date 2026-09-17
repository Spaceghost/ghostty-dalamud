-- Shipped defaults. Put user overrides in the plugin configuration's lua/.
-- Existing overrides remain authoritative and are not silently overwritten.
local keymap = require('keymap')
local world = require('world')
local animation = require('animation')
local settings = require('settings')
local bell = require('bell')
local showcase = require('showcase')
local home = os.getenv('HOME') or os.getenv('USERPROFILE') or ''
local native_windows = rawget(_G, 'GHOSTTY_PLATFORM') == 'windows'

local config = {
  toggle_key = 'grave',
  toggle_mods = 'ctrl',
  world_toggle_mods = 'ctrl+shift',
  toggle_consume_vk = 0xC0,
  -- select is Xbox View / DualSense touchpad click. Optional create uses HID.
  toggle_gamepad_button = 'select',
  cursor_blink = true,
  close_on_exit = true,
  copy_on_select = true,
  dropdown = {
    height = 0.45,
    y_offset = 0,
    animation_ms = 200,
    font_size = 15,
    opacity = 0.94,
    padding = 6,
    rounding = 8,
    margin = 12,
    width = 0.5,
    min_width = 1200,
    align = 'center',
    open_on_start = false,
    glass = true,
    glow = 0.6,
    world_tint = 1.0,
  },
  popup = {
    width = 900,
    height = 480,
    font_size = 14,
    rounding = 6,
    close_on_blur = true,
  },
  host = {
    commands = { '/term', '/tomestone', '/tome' },
    help = 'Show/hide the terminal. window [n] | new [n] | pin [here|me|target|orbit] | unpin | config | reload',
    dtr = {
      mode = 'auto',
      title = 'Ghostty',
      tooltip = 'Ghostty terminal. Click: dropdown, right-click: popup, shift+click: new window, ctrl+click: world screens',
      on_click = function(button, mods)
        if button == 'right' then return 'popup' end
        if mods.shift then return 'window' end
        if mods.ctrl then return 'world' end
        return 'toggle'
      end,
    },
    keep_visible = { user_hidden = true, cutscene = true, gpose = true, always = false },
  },
  -- Authentication is not encryption. Keep on loopback or use a secure tunnel.
  agent = {
    host = '127.0.0.1',
    port = 7777,
    token = '',
    token_file = home .. '/.config/ghostty-agent/token',
  },
  profiles = {
    { name = 'shell', transport = 'agent', command = { '/bin/sh' } },
    -- Optional: install tmux on the agent host before selecting this profile.
    { name = 'tmux', transport = 'agent', command = { 'tmux', 'new-session', '-A', '-s', 'ghostty' } },
    { name = 'powershell', transport = 'conpty', command = { 'powershell.exe', '-NoLogo' } },
    { name = 'cmd', transport = 'conpty', command = { 'cmd.exe' } },
    -- SSH is a command through one of these transports, not another transport.
    -- { name = 'ssh', transport = 'agent', command = { 'ssh', '-t', 'user@example-host' } },
  },
  -- A Windows-only installation need not run a POSIX agent. Wine still does.
  default_profile = native_windows and 4 or 1,
  on_key = keymap.on_key,
  world = world,
  animation = animation,
  bell = bell,
  showcase = showcase,
  settings = settings,
  world_pins = {},
}
return settings.apply(config)
