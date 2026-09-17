-- Ghostty for Dalamud: user configuration.
--
-- This file is plain Lua and is reloaded with `/term reload`. Everything
-- about *what* the terminal does (profiles, keys, layout) is decided here;
-- the Nelua core only executes it. To change it, copy it into lua/ inside
-- the plugin's config directory (pluginConfigs/GhosttyDalamud/lua/): that
-- copy wins over the one shipped beside the plugin.

local keymap = require('keymap')
local world = require('world')
local animation = require('animation')
local settings = require('settings')
local bell = require('bell')
local showcase = require('showcase')

local home = os.getenv('HOME') or os.getenv('USERPROFILE') or ''

local config = {
  -- Key that toggles the Quake-style drop-down terminal. Names are ImGui
  -- key names in lowercase: "grave" is the backquote/tilde key.
  toggle_key = 'grave',
  -- Modifiers held with toggle_key: 'ctrl', 'ctrl+shift', 'alt', or '' for the bare key.
  toggle_mods = 'ctrl',
  -- Modifiers with toggle_key for the terminals floating in the world (pets).
  world_toggle_mods = 'ctrl+shift',
  -- Windows virtual-key code to swallow so the game never sees the toggle
  -- key press (0xC0 = VK_OEM_3, the backquote key on US layouts).
  toggle_consume_vk = 0xC0,
  -- Gamepad button that toggles the terminal (Dalamud GamepadButtons name):
  -- "select" is the PS5 Create / Xbox View button. Empty string disables it.
  -- dpad_up dpad_down dpad_left dpad_right north south west east
  -- l1 l2 l3 r1 r2 r3 select start
  toggle_gamepad_button = 'select',

  cursor_blink = true,
  -- Close a terminal (tab, window or world panel) when its shell exits, e.g. ctrl+d.
  close_on_exit = true,
  -- Copy text to the clipboard as soon as a mouse selection is released
  -- (ctrl+shift+c copies it too).
  copy_on_select = true,

  dropdown = {
    height = 0.45,        -- fraction of the game viewport
    y_offset = 0,         -- pixels below the top edge; set to Umbra's toolbar height if it is top-aligned
    animation_ms = 200,   -- eased slide and fade
    font_size = 15,
    opacity = 0.94,
    padding = 6,
    rounding = 8,         -- corner radius in pixels
    margin = 12,          -- inset from the left/right screen edges so the corners show
    width = 0.5,          -- fraction of the screen width on wide screens...
    min_width = 1200,     -- ...but never narrower than this many pixels
    align = 'center',     -- 'left' | 'center' | 'right'
    open_on_start = false, -- drop down as soon as the plugin loads
    glass = true,         -- rounded glass: gradient body, edge highlight, sheen (false = flat)
    glow = 0.6,           -- soft outer glow, 0..1; comes up with the backlight when the world is dark
    world_tint = 1.0,     -- 0..1: take on the world's light like the panels do (CONFIG.world.light)
  },

  -- The popup terminal: the Umbra toolbar widget's, or without Umbra the one
  -- the server info bar entry opens.
  popup = {
    width = 900,
    height = 480,
    font_size = 14,
    rounding = 6,
    close_on_blur = true, -- the info bar popup closes when you click elsewhere
  },

  -- What the plugin registers with Dalamud.
  host = {
    commands = { '/term', '/tomestone', '/tome' },
    help = 'Show/hide the terminal. window [n] | new [n] | pin [here|me|target|orbit] | unpin | config | reload',
    -- Server info bar entry. 'auto' shows it only while no Umbra toolbar
    -- widget is showing ghostty's status; 'always' | 'never'.
    dtr = {
      mode = 'auto',
      title = 'Ghostty',
      tooltip = 'Ghostty terminal. Click: dropdown, right-click: popup, shift+click: new window, ctrl+click: world screens',
      -- button 'left' | 'right'; mods.ctrl / mods.alt / mods.shift.
      -- Return 'toggle' | 'popup' | 'window' | 'world' | 'settings' | 'none'.
      on_click = function(button, mods)
        if button == 'right' then return 'popup' end
        if mods.shift then return 'window' end
        if mods.ctrl then return 'world' end
        return 'toggle'
      end,
    },
    -- Keep terminals drawn while the game hides its UI for these reasons
    -- (false = hide along with the game UI). `always` ignores all three.
    keep_visible = { user_hidden = true, cutscene = true, gpose = true, always = false },
  },

  -- ghostty-agent connection (Linux/macOS host). Keep it on loopback, or reach
  -- it through `ssh -L` or a private network: every connection must present
  -- the token, but the stream itself is not encrypted.
  agent = {
    host = '127.0.0.1',
    port = 7777,
    -- Either inline the token or point at the agent's token file. When the
    -- game runs on another machine, copy the file over (or use ssh -L).
    token = '',
    token_file = home .. '/.config/ghostty-agent/token',
  },

  -- Profiles appear in the new-tab menu. `transport` is one of:
  --   "agent"        run `command` on the ghostty-agent host (Linux/macOS)
  --   "conpty"       run `command` on the Windows host running the game (ConPTY)
  --   "superlogical" placeholder until Superlogical publishes its client protocol
  profiles = {
    { name = 'shell',      transport = 'agent',  command = { '/bin/bash', '-l' } },
    { name = 'tmux',       transport = 'agent',  command = { 'tmux', 'new-session', '-A', '-s', 'ghostty' } },
    { name = 'powershell', transport = 'conpty', command = { 'pwsh.exe', '-NoLogo' } },
    { name = 'cmd',        transport = 'conpty', command = { 'cmd.exe' } },
    -- ssh is a command like any other, through either transport:
    -- { name = 'ssh',       transport = 'agent',  command = { 'ssh', '-t', 'user@example-host' } },
    -- { name = 'ssh (win)', transport = 'conpty', command = { 'ssh.exe', 'user@example-host' } },
  },
  default_profile = 1,

  on_key = keymap.on_key,

  -- Terminals pinned into the game world: /term pin [here|me|target|orbit].
  -- Placement logic and defaults (size, scale, opacity) live in lua/world.lua.
  world = world,
  -- Character pulls out a deck while the terminal is open (lua/animation.lua).
  animation = animation,
  -- Visual bell: rings around your character and a glow on the terminal that rang (lua/bell.lua).
  bell = bell,
  -- /term showcase: demo terminals and camera shots for screenshots (lua/showcase.lua).
  showcase = showcase,
  -- The settings window (/term config) and its saved overrides (settings.lua).
  settings = settings,
  -- Pinned automatically once your character is loaded, e.g. { 'orbit 4 0.2', 'me' }.
  world_pins = {},
}

return settings.apply(config)
