-- The Changelog and About tabs of the settings window.
--
-- Entries are written for players, newest first. `status` marks work that
-- is merged but not yet verified in game ('beta') or still being built
-- ('next'), so the tab never claims more than has been seen working.
--
-- This file is the changelog: CHANGELOG.md is generated from it by
-- tools/changelog.py, and CI fails when the two disagree. Every change a
-- player can see adds its entry here, in the same commit as the change.

local vote = require('vote')
local gallery = require('gallery')

local C = {}
C.releases = {
  {
    version = 'next', title = 'In the workshop',
    blurb = 'BETA is built and merged but has not been seen working in game yet; SOON is still being built. Entries move into a release once they have been verified in game.',
    items = {
      { 'beta', 'Reach the agent from another machine without Tailscale: ghostty-agent has WireGuard built in. `ghostty-agent wg add gaming-pc` prints a config (and a QR code) for the ordinary WireGuard app on the game PC, and the line to point the plugin at the agent through the tunnel; no root and no driver on the agent\'s machine, and it can also carry RDP, VNC or Sunshine for you (`wg forward`). With Tailscale running it stays off, and the agent now refuses to listen on the network in the clear. Tested against kernel WireGuard; not yet seen in game.' },
      { 'beta', 'Screens from another machine arrive as sharp as the limit allows: a window larger than the size a screen asks for (1920x1200 unless you set another) is shrunk to the largest size that fits, keeping its shape, instead of being halved. A 2560x1440 browser now arrives at 1920x1080 rather than 1280x720, and clicks still land where you point. Game clips follow the same rule. Host tests only; not yet seen in game.' },
      { 'beta', 'Linux players install the agent instead of building it: ghostty-agent ships as a Fedora RPM, as an Alpine APK, and as a portable tarball for every other glibc machine, each built from source inside a container of its own distribution and attached to every release, with a systemd user unit so your shells start with your session and outlive the game. The Fedora 44 and Alpine packages carry the Wayland compositor, so screens from your desktop and the browser work; the portable build has terminals, jobs and clips. Asked for by @Xe. Built, installed and run in containers; not yet on a player\'s own machine, and not yet in game.' },
      { 'beta', 'Rough movement shakes the water off a screen, however it is moved — a pet behind a run that stops dead or a sharp turn, the lineup, an order swap, a fling with Alt + drag, a pin or pet toggle, a fast orbit, the presented float, a quick spin. Gentle movement makes the drops slide and streak instead; a hard stop throws them forward, a spin along the tangent, and they fall to the first surface below. Teleports and zone changes shed nothing (Settings, Light: shake-off). Not yet tried in game.' },
      { 'beta', 'Rain follows shelter: a screen gets rain only where the sky can reach it. One out in the open is rained on even while you stand under a roof, one half under an overhang only on its open side, and indoors nothing is — no drops, no run-off, no flung water — with the glass drying gradually as a pet screen follows you inside. Drops that fall off stop at the first floor below them (Settings, Light: Rain follows shelter). Not yet tried in game.' },
      { 'next', 'Clean first build: the toolchain and the Dalamud references it compiles against are pinned and checked before use, the default shell is chosen per platform, and a fresh clone builds with nothing else installed.' },
      { 'next', 'Emoji, CJK and other wide glyphs drawn through the same fallback, with Noto Sans Symbols 2 and an optional monochrome Noto Emoji you drop in yourself.' },
    },
  },
  {
    version = '0.3.0', title = 'Released 2026-09-20', date = '2026-09-20',
    blurb = 'BETA entries are in this release but have not been verified in game yet; they become NEW or FIX once they have been seen working.',
    items = {
      { 'beta', 'Sharing to the gallery signs in first: the first Share shows a short code and opens the link page in your browser; sign in there, approve Ghostty, and the screenshot goes up by itself. The link is kept for next time and never logged; /term share unlink forgets it. Not yet tried in game.' },
      { 'beta', 'Screenshots that have the terminals in them: /term shot (or the shutter button in the dropdown) photographs the frame the game just drew, ImGui and all, writes a PNG into the plugin\'s screenshots folder and offers it to the share prompt at once. "panel" crops to the terminal in focus, "clean" hides the game\'s own UI for the shot. The game\'s own screenshot key takes its picture before Dalamud draws, so it is the one shot a terminal cannot be in. Not yet tried in game.' },
      { 'beta', 'Short clips: /term clip [seconds] [gif|mp4] records a few seconds of the game and hands the frames to ghostty-agent, which encodes them with ffmpeg on the host so the game never stutters over it. Clips are for your own use; the gallery takes PNG and JPEG only. Needs ffmpeg on the host; it says so when there is none. Not yet tried in game.' },
      { 'beta', 'Double-clicking a screen to full screen keeps its pixels: the panel is scaled into place instead of re-flowed, so text no longer spills past its edges on the way there and the shell is not redrawn twice a round trip. Not yet tried in game.' },
      { 'beta', 'A plugin window pulled into the world now fits the panel it lives in instead of sitting in a band of empty space, and re-fits when you resize the panel — Mappy lays its map out for the screen. Not yet tried in game.' },
      { 'beta', 'Other plugins\' windows can be pulled into the world as screens (Mappy automatically), and so can the game\'s chat log. Not yet tried in game.' },
      { 'beta', 'Rain runs off world screens and falls to the ground, and the wiper flings what it collects. Outdoors only. Not yet tried in game.' },
      { 'beta', 'Dock a screen to a spot on your HUD: it stays there in front of the camera, lagging and settling on springs as you turn, and keeps the size you docked it at. Not yet tried in game.' },
      { 'beta', 'Opt-in desk scene: your character sits at a desk and chair with a cycle of seated moods, and reacts to the bell, to failed and long commands, to output after a quiet spell and to idle time. Not yet observed in game.' },
      { 'beta', 'Focus a screen and your pets line up beside it in an order you choose — the ◀ ▶ arrows on a hovered pet, or /term order left|right|first|last|N — smaller, stacked in tiers rather than reaching into the camera\'s line or the space directly behind you. The order is saved per pet. Not yet tried in game.' },
      { 'beta', 'Umbra\'s toolbar and other plugins\' overlays stay on top of world screens instead of being painted over (Settings, world: under_ui). Not yet tried in game.' },
      { 'beta', 'World screens are cut out of the game\'s own HUD — hotbars, chat log, minimap, party list — so the interface shows through instead of being covered (Settings, world: under_hud). Not yet tried in game.' },
      { 'beta', 'Box drawing, block elements, braille and powerline separators are drawn as shapes, so their lines meet exactly across cells instead of leaving gaps. Not yet tried in game.' },
      { 'beta', 'Icons the game\'s font cannot hold — Nerd Font glyphs above U+FFFF and anything else missing — are drawn by the plugin itself from a bundled symbol font into a texture of its own. Not yet tried in game.' },
      { 'beta', 'Ctrl+click a link in a terminal to open it: in the compositor\'s own browser window where one is running, otherwise in your desktop browser. Not yet tried in game.' },
      { 'beta', 'Windows from a machine running ghostty-agent can be pulled in as screens; on Linux the agent is a headless Wayland compositor of its own and the game is its only display. Host tests and a Wine run only — nothing in game or on a real desktop yet (docs/REMOTE_WINDOWS.md).' },
      { 'beta', 'Programs can be run as jobs on pipes instead of a terminal, kept alive across reconnects with their output replayed — this is how the plugin talks to a local assistant. Not yet tried in game.' },
      { 'beta', 'Share your screenshots: take one with the game\'s screenshot key while a terminal is on screen and a small prompt offers to share it to the gallery on spacegho.st. One click uploads it; the site owner reviews every shot before it is shown. /term share, the camera button in the dropdown and the About tab offer your latest one; "Don\'t ask again" or Settings, Gallery turns the prompt off. Not yet tried in game.' },
      { 'beta', 'Themes: spaceghost (the look you know), gruvbox-dark and four Catppuccin flavours colour the terminals and the glass around them. Pick one in Settings (hover to preview) or with /term theme; drop any Ghostty theme file into themes/ in the config folder. Not yet tried in game.' },
      { 'beta', 'Tooltips everywhere: every button, taskbar chip and setting explains itself when you rest the pointer on it, world screens included. Not yet tried in game.' },
      { 'beta', 'A self-test you can run in the game: /term selftest checks the terminal, drawing, the camera maths, settings and the agent without moving your character, and writes a report. Not yet run in game.' },
      { 'beta', 'Ask in a panel: /ask <question> answers as chat bubbles in Ghostty glass while you play, streamed as they are written, with code blocks and clickable links. Follow-ups keep the conversation (threads you can go back to), New starts over, Pin floats it beside you. /ask term still opens a terminal. Needs almanac with threads. Not yet tried in game.' },
      { 'beta', 'Ask a local AI assistant from chat or a macro: /term ask <question> opens a terminal with the answer (as a pet by default), /term ask alone a conversation. Uses almanac, a separate program you install yourself; see Settings, Assistant. Not yet tried in game.' },
      { 'beta', 'Vote on what gets built next: the About tab in Settings opens the vote page in your browser, and a small dot on the settings button shows while there are ideas you have not looked at. The plugin itself never goes online for it.' },
      { 'beta', 'Windows without Linux: ghostty-agent now also runs on Windows, and on Windows the plugin uses it for PowerShell and cmd, or opens them locally while no agent runs. Not yet tried on Windows.' },
      { 'beta', 'Local terminals (conpty) on Windows start their shell with the structure size Windows expects. Not yet verified on Windows or under Wine.' },
      { 'beta', 'Controller: the DualSense Create button can open the terminal while the game is in front (choose create in Settings). Not yet tried with a real controller in game.' },
      { 'beta', 'Select text with the mouse — drag, double-click a word, triple-click a line — and copy it.' },
      { 'beta', 'Screens cast real in-game light: their backlight glows on your face and the world around you.' },
      { 'beta', 'Experimental, off by default: screens cast shadows and block sunlight (Settings, Light). Not yet tried in game, and a game patch may crash it.' },
      { 'beta', 'Click a screen and your character walks up to it while it floats out to meet you.' },
      { 'beta', 'The terminal bell rings out as a ripple of light from your character; the screen that rang glows.' },
      { 'beta', 'A Dalamud plugin of its own: /term, a server info bar entry with a popup terminal, Open and Settings in /xlplugins. Umbra adds its toolbar widget when installed, and your settings, token and screens move over by themselves.' },
      { 'beta', 'Drag screens through the world and snap them flat against walls and tables.' },
      { 'beta', 'The mouse wheel scrolls terminals, and scrolls less, vim and mouse-aware programs their own way.' },
      { 'beta', 'Hold the left mouse button to turn the camera without losing the terminal; a quick click on the world still lets go.' },
      { 'beta', 'Backspace and other keys no longer repeat when the game stutters.' },
      { 'beta', 'The dropdown is glass like the screens: it takes on the time of day, glows in the dark, slides in softly, and its tab bar has icon buttons with tooltips.' },
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
  ui.wrapped('Independent developer preview using libghostty-vt, a Nelua core, Lua configuration and C# host adapters. Not an official Ghostty project or a claim of official Dalamud-list acceptance.')
  ui.spacing()
  ui.wrapped('Made by Johnneylee Jack Rollins', 0.92, 0.86, 0.72)
  ui.wrapped('github.com/Spaceghost', 0.55, 0.70, 0.98)
  ui.spacing()
  ui.wrapped('Umbra', 0.92, 0.86, 0.72)
  ui.wrapped('The standalone plugin is designed to work without Umbra. The optional widget uses its versioned IPC and displays offline status when the plugin is unavailable. Target-platform and in-game verification remain required.')
  ui.wrapped('User configuration belongs in pluginConfigs/GhosttyDalamud. Back up old Umbra configuration before testing migration. Host-side tests do not validate a game installation.', 0.66, 0.62, 0.78)
  ui.spacing()
  ui.wrapped('Your data', 0.92, 0.86, 0.72)
  ui.wrapped('Shells run on your own machine through ghostty-agent (loopback, token protected). Poses, lights and screens are client-side: other players never see your terminal.')
  ui.wrapped('The plugin goes online only when you click Share on a screenshot: it sends that one image (and your character\'s name and world, if you ticked the credit box) to the gallery on spacegho.st, signed with the link to your account there (made in your browser on the first Share).')
  ui.wrapped('The agent token says who you are; it does not encrypt the stream. Keep the agent on loopback or behind a tunnel you trust, and read back logs, terminal output and screenshots before you share them.')
end
return C
