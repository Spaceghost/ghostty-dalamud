-- Shipped defaults. Put user overrides in the plugin configuration's lua/.
-- Existing overrides remain authoritative and are not silently overwritten.
local keymap = require('keymap')
local world = require('world')
local animation = require('animation')
local settings = require('settings')
local bell = require('bell')
local rain = require('rain')
local showcase = require('showcase')
local platform = require('platform')
local assistant = require('assistant')
local ask = require('ask')
local themes = require('themes')
local tooltips = require('tooltips')
local windows = require('windows')
local adopt = require('adopt')
local gallery = require('gallery')

-- The agent connection and profiles for where the game runs (native Windows,
-- or Wine/Proton on Linux): see lua/platform.lua. The token authenticates the
-- agent stream; it does not encrypt it, so keep the agent on loopback or
-- behind a tunnel you trust.
local defaults = platform.defaults(platform.name())

local config = {
  toggle_key = 'grave',
  toggle_mods = 'ctrl',
  world_toggle_mods = 'ctrl+shift',
  toggle_consume_vk = 0xC0,
  -- select is Xbox View / DualSense touchpad click. Optional create uses HID.
  toggle_gamepad_button = 'select',

  -- Colour theme for the terminals and the glass UI: a name from themes/
  -- beside the plugin or themes/ in the config directory (yours win). Ships
  -- spaceghost (the default), gruvbox-dark, catppuccin (mocha),
  -- catppuccin-macchiato, catppuccin-frappe and catppuccin-latte; any Ghostty
  -- theme file works too. /term theme lists them, /term theme <name> switches.
  theme = 'spaceghost',
  themes = themes,
  -- Tooltip texts (lua/tooltips.lua), and the delay before they show.
  tooltips = tooltips,

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
    -- Commands of their own, each standing for one /term verb (the same
    -- functions): /window pull | run CMD | list | close, /ask [question],
    -- /agent ask [question]. Their /help lines are in lua/tooltips.lua.
    -- A name another plugin holds is retried; {} registers none.
    verb_commands = { ['/window'] = 'window', ['/ask'] = 'ask', ['/agent'] = 'agent' },
    help = 'Show/hide the terminal. window [n|list|pull [match]|close] | new [n] | pin [here|me|target|orbit] | unpin | ask [question] | theme [name] | shot [panel] [clean] | clip [seconds] | share | config | reload',
    -- Server info bar entry. 'auto' shows it only while no Umbra toolbar
    -- widget is showing ghostty's status; 'always' | 'never'.
    dtr = {
      mode = 'auto',
      title = 'Ghostty',
      tooltip = 'Ghostty terminal. Click: every terminal, alt+click: dropdown, right-click: popup, shift+click: new window, ctrl+click: world screens',
      -- button 'left' | 'right'; mods.ctrl / mods.alt / mods.shift.
      -- Return 'list' (every terminal; a click on one brings it forward) |
      -- 'toggle' (the dropdown) | 'popup' | 'window' | 'world' | 'settings' | 'none'.
      on_click = function(button, mods)
        if button == 'right' then return 'popup' end
        if mods.shift then return 'window' end
        if mods.ctrl then return 'world' end
        if mods.alt then return 'toggle' end
        return 'list'
      end,
    },
    keep_visible = { user_hidden = true, cutscene = true, gpose = true, always = false },
  },

  -- ghostty-agent connection. Keep it on loopback, or reach it through
  -- `ssh -L` or a private network: every connection must present the token,
  -- but the stream itself is not encrypted. The default (lua/platform.lua) is
  -- 127.0.0.1:7777 with the token read from the agent's token file:
  -- %APPDATA%\ghostty-agent\token on native Windows,
  -- ~/.config/ghostty-agent/token otherwise. To set your own:
  --   agent = { host = '127.0.0.1', port = 7777, token = '', token_file = '/path/to/token' },
  agent = defaults.agent,

  -- Profiles appear in the new-tab menu. `transport` is one of:
  --   "agent"        run `command` on the ghostty-agent host (Linux/macOS or Windows)
  --   "conpty"       run `command` on the Windows host running the game (ConPTY);
  --                  these shells end when the game closes
  --   "superlogical" placeholder until Superlogical publishes its client protocol
  -- An agent profile may name a `fallback` profile (a conpty one) that opens
  -- instead while no agent answers. The defaults (lua/platform.lua): on native
  -- Windows, powershell and cmd through the agent with local fallbacks; under
  -- Wine, bash and tmux through the agent plus pwsh and cmd over ConPTY. E.g.:
  --   profiles = {
  --     { name = 'shell', transport = 'agent', command = { '/bin/sh' } },
  --     { name = 'ssh',   transport = 'agent', command = { 'ssh', '-t', 'user@example-host' } },
  --     { name = 'cmd',   transport = 'agent', command = { 'cmd.exe' }, fallback = 'cmd (local)' },
  --     { name = 'cmd (local)', transport = 'conpty', command = { 'cmd.exe' } },
  --   },
  profiles = defaults.profiles,
  default_profile = 1,

  on_key = keymap.on_key,
  world = world,
  animation = animation,
  bell = bell,
  -- Rain on world panels when it rains in the world, and a wiper behind the glass (lua/rain.lua).
  rain = rain,
  -- /term showcase: demo terminals and camera shots for screenshots (lua/showcase.lua).
  showcase = showcase,
  -- /term ask [question]: a terminal running a local AI assistant (almanac by
  -- default), the question as one argument, never through a shell. Command,
  -- transport and where it opens: lua/assistant.lua. Change the fields
  -- (e.g. assistant.view = 'tab') rather than replacing the table: the core
  -- calls its functions.
  assistant = assistant,
  -- /ask [question]: the assistant's answers as chat bubbles in a panel, with
  -- follow-ups (threads), a thread list and a pin onto a pet. /ask new starts
  -- a new thread, /ask term the terminal. Behaviour: lua/ask.lua; what runs:
  -- lua/assistant.lua (ui = 'terminal' turns the panel off).
  ask = ask,
  -- Desktop windows streamed by ghostty-agent onto world panels: /term window
  -- list | pull [match|#wid|run CMD] | close. Sizes, frame rate and windows
  -- pulled at login: lua/windows.lua.
  windows = windows,
  -- Flat windows pulled into the world and back: /window adopt chat2 (ChatTwo),
  -- /window adopt chat (the game's chat), /window release; or hold Alt over a
  -- window and click its "pull into world" grip. Names, sizes, the modifier
  -- and chat colours: lua/adopt.lua (docs/ADOPT.md).
  adopt = adopt,
  -- Share screenshots to the gallery on spacegho.st: a prompt after a screenshot
  -- taken with a terminal on screen, /term share for the latest one. Nothing is
  -- uploaded until you click Share. Folders, timings: lua/gallery.lua; the
  -- prompt and credit toggles are in Settings, Gallery.
  gallery = gallery,
  -- The settings window (/term config) and its saved overrides (settings.lua).
  settings = settings,
  world_pins = {},
}
return settings.apply(config)
