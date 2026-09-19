-- The Changelog and About tabs of the settings window.
--
-- Entries are written for players, newest first. `status` marks work that
-- is merged but not yet verified in game ('beta') or still being built
-- ('next'), so the tab never claims more than has been seen working.

local vote = require('vote')
local gallery = require('gallery')

local C = {}

C.releases = {
  {
    version = 'next', title = 'In the workshop',
    blurb = 'Being built right now. These land here as they are verified in game.',
    items = {
      { 'next', 'Share your screenshots: take one with the game\'s screenshot key while a terminal is on screen and a small prompt offers to share it to the gallery on spacegho.st. One click uploads it; the site owner reviews every shot before it is shown. /term share, the camera button in the dropdown and the About tab offer your latest one; "Don\'t ask again" or Settings, Gallery turns the prompt off. Not yet tried in game.' },
      { 'next', 'Themes: spaceghost (the look you know), gruvbox-dark and four Catppuccin flavours colour the terminals and the glass around them. Pick one in Settings (hover to preview) or with /term theme; drop any Ghostty theme file into themes/ in the config folder. Not yet tried in game.' },
      { 'next', 'Tooltips everywhere: every button, taskbar chip and setting explains itself when you rest the pointer on it, world screens included. Not yet tried in game.' },
      { 'next', 'A self-test you can run in the game: /term selftest checks the terminal, drawing, the camera maths, settings and the agent without moving your character, and writes a report. Not yet run in game.' },
      { 'next', 'Ask a local AI assistant from chat or a macro: /term ask <question> opens a terminal with the answer (as a pet by default), /term ask alone a conversation. Uses almanac, a separate program you install yourself; see Settings, Assistant. Not yet tried in game.' },
      { 'next', 'Vote on what gets built next: the About tab in Settings opens the vote page in your browser, and a small dot on the settings button shows while there are ideas you have not looked at. The plugin itself never goes online for it.' },
      { 'next', 'Windows without Linux: ghostty-agent now also runs on Windows, and on Windows the plugin uses it for PowerShell and cmd, or opens them locally while no agent runs. Not yet tried on Windows.' },
      { 'next', 'Local terminals (conpty) on Windows start their shell with the structure size Windows expects. Not yet verified on Windows or under Wine.' },
      { 'next', 'Controller: the DualSense Create button can open the terminal while the game is in front (choose create in Settings). Not yet tried with a real controller in game.' },
      { 'next', 'Select text with the mouse — drag, double-click a word, triple-click a line — and copy it.' },
      { 'next', 'Screens cast real in-game light: their backlight glows on your face and the world around you.' },
      { 'next', 'Experimental, off by default: screens cast shadows and block sunlight (Settings, Light). Not yet tried in game, and a game patch may crash it.' },
      { 'next', 'Click a screen and your character walks up to it while it floats out to meet you.' },
      { 'next', 'The terminal bell rings out as a ripple of light from your character; the screen that rang glows.' },
      { 'next', 'A Dalamud plugin of its own: /term, a server info bar entry with a popup terminal, Open and Settings in /xlplugins. Umbra adds its toolbar widget when installed, and your settings, token and screens move over by themselves.' },
      { 'next', 'Drag screens through the world and snap them flat against walls and tables.' },
      { 'next', 'The mouse wheel scrolls terminals, and scrolls less, vim and mouse-aware programs their own way.' },
      { 'next', 'Hold the left mouse button to turn the camera without losing the terminal; a quick click on the world still lets go.' },
      { 'next', 'Backspace and other keys no longer repeat when the game stutters.' },
      { 'next', 'The dropdown is glass like the screens: it takes on the time of day, glows in the dark, slides in softly, and its tab bar has icon buttons with tooltips.' },
    },
  },
  {
    version = '0.4', title = 'Make it yours',
    blurb = 'Everything is configurable, and your layout comes back exactly as you left it.',
    items = {
      { 'new', 'Settings window (/term config, or cfg in the tab bar) with live changes, saved to settings.lua.' },
      { 'new', 'Every terminal remembers where it lives — tab, window, minimized, pinned or pet — and its zoom.' },
      { 'new', 'Screens nobody can see go to sleep and wake with their output replayed; mark one to keep running.' },
      { 'new', 'Choose the pose your character holds: glowing device, book, pen and paper, camera, thinking, lookout, or any animation id.' },
      { 'new', 'Per-terminal zoom: ctrl+= ctrl+- ctrl+0, or ctrl+wheel.' },
      { 'new', 'Pop a screen into the dropdown, fly it full screen, or double-click to drop into first person facing it.' },
      { 'new', 'Screens react to the time of day and weather, with a backlight when it gets dark.' },
      { 'fix', 'Screens behind your character are cut out around it instead of drawing over it.' },
      { 'fix', 'Panels seen from behind read correctly instead of mirrored.' },
    },
  },
  {
    version = '0.3', title = 'Companions',
    blurb = 'Terminals that follow you around like pets, and a character who uses them.',
    items = {
      { 'new', 'Pet terminals float beside your character, trail after you on springs and settle gently when you stop.' },
      { 'new', 'Your character holds a glowing device while a terminal is out, and works it faster while you type.' },
      { 'new', 'Screens derez in a scanline dissolve when combat starts and come back afterwards.' },
      { 'new', 'Controller: tap to open, hold to step through screens, double-tap to step back.' },
      { 'new', 'Taskbar in the Umbra toolbar popup; hotbar macros: /term send, type, min, restore, focus.' },
      { 'fix', 'Movement is never taken over: clicking the world, moving or combat hands input back to the game.' },
      { 'fix', 'Recovered characters stuck in a pose the game treated as "operating a siege machine".' },
    },
  },
  {
    version = '0.2', title = 'Worldbound',
    blurb = 'Terminals leave the screen and step into Eorzea.',
    items = {
      { 'new', 'Pin terminals in the world: in place, above your target, in front of you, or orbiting you.' },
      { 'new', 'Curved panels with crisp 40 px text, resize by dragging an edge, close with the ×.' },
      { 'new', 'Floating windows, a hide button, ctrl+` for the dropdown and ctrl+shift+` for world screens.' },
      { 'new', 'Commands: /term, /tomestone and /tome.' },
    },
  },
  {
    version = '0.1', title = 'First light',
    blurb = 'A real terminal emulator inside the game, backed by libghostty.',
    items = {
      { 'new', 'Quake-style dropdown with tabs, connected to shells on your machine through ghostty-agent.' },
      { 'new', 'Full colour, cursor styles, kitty keyboard protocol, bracketed paste, scrollback.' },
      { 'new', 'Shells survive game restarts and reattach with their screen intact.' },
      { 'fix', 'Keys typed into the terminal no longer open the chat box.' },
    },
  },
}

local TAG = {
  new = { 'NEW', 0.42, 0.80, 0.62 },
  fix = { 'FIX', 0.92, 0.74, 0.40 },
  beta = { 'BETA', 0.55, 0.70, 0.98 },
  next = { 'SOON', 0.66, 0.62, 0.78 },
}

function C.draw_changelog(ui)
  for i, rel in ipairs(C.releases) do
    local head = rel.version == 'next' and rel.title or (rel.version .. ' · ' .. rel.title)
    if ui.header(head .. '##rel' .. i, i <= 2) then
      ui.wrapped(rel.blurb, 0.72, 0.74, 0.78)
      ui.spacing()
      for _, item in ipairs(rel.items) do
        local tag = TAG[item[1]] or TAG.new
        ui.wrapped(tag[1] .. '   ' .. item[2], tag[2], tag[3], tag[4])
      end
      ui.spacing()
    end
  end
end

-- `settings` (lua/settings.lua) keeps the vote page marker; without it the
-- vote section is left out.
function C.draw_about(ui, settings)
  if settings then
    vote.draw(ui, settings)
    ui.spacing()
    ui.separator()
    ui.spacing()
    gallery.draw_about(ui)
    ui.spacing()
    ui.separator()
    ui.spacing()
  end
  ui.wrapped('Ghostty for FFXIV', 0.92, 0.86, 0.72)
  ui.wrapped('A real terminal emulator living in Eorzea: libghostty-vt for the terminal, a Nelua core for everything on screen, Lua for every decision you can change, and tiny C# shims that only forward calls to the game.')
  ui.spacing()
  ui.wrapped('Made by Johnneylee Jack Rollins', 0.92, 0.86, 0.72)
  ui.wrapped('github.com/Spaceghost', 0.55, 0.70, 0.98)
  ui.spacing()
  ui.wrapped('Umbra', 0.92, 0.86, 0.72)
  ui.wrapped('Ghostty is becoming a Dalamud plugin of its own (GhosttyDalamud). It loads the terminal core, answers /term, /tomestone and /tome, puts an entry in the server info bar (click for the dropdown, right-click for a popup terminal) and opens from /xlplugins. Everything works without Umbra: the dropdown, windows, world screens, pets, commands, settings and controller gestures.')
  ui.wrapped('With Umbra installed, the Ghostty toolbar widget becomes a small companion that asks the plugin for its status and popup terminal, and the info bar entry steps aside. Without the plugin running, the widget just says "ghostty offline".')
  ui.wrapped('Settings, the agent token and your screen layout live in pluginConfigs/GhosttyDalamud and are copied over once from the old Umbra home. All of this is new and still in the workshop: it has not been seen working in game yet (see Changelog).', 0.66, 0.62, 0.78)
  ui.spacing()
  ui.wrapped('Your data', 0.92, 0.86, 0.72)
  ui.wrapped('Shells run on your own machine through ghostty-agent (loopback, token protected). Poses, lights and screens are client-side: other players never see your terminal.')
  ui.wrapped('The plugin goes online only when you click Share on a screenshot: it sends that one image (and your character\'s name and world, if you ticked the credit box) to the gallery on spacegho.st.')
end

return C
