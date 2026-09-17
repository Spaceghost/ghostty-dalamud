-- Historical feature notes and the About tab. Version labels below are
-- development milestones, not proof of published releases or target testing.
local vote = require('vote')
local C = {}
C.releases = {
  {
    version = 'next', title = 'Developer preview',
    blurb = 'Implemented or in development; target-platform and in-game verification remain required.',
    items = {
      { 'next', 'Platform-specific default terminals, clean-build bootstrap and verified build references.' },
      { 'next', 'The About tab opens the feature vote page; its catalogue is shipped locally.' },
      { 'next', 'ConPTY startup structure size corrected. Native Windows behavior still requires verification.' },
      { 'next', 'Optional DualSense Create handling via HID. Not yet verified with a real controller in game.' },
      { 'next', 'Mouse selection: drag, double-click a word, or triple-click a line, then copy.' },
      { 'next', 'World-panel lighting, drag placement and walk-up behavior require target testing.' },
      { 'next', 'Experimental shadow boards are off by default. Game updates may invalidate the signature.' },
      { 'next', 'Visual bell effects and standalone-plugin configuration migration require in-game testing.' },
      { 'next', 'Drop-down appearance, camera interaction and input handling remain under validation.' },
    },
  },
  {
    version = '0.4', title = 'Configuration and layout',
    blurb = 'Historical development notes; not a compatibility guarantee.',
    items = {
      { 'new', 'Settings window, saved overrides, per-terminal zoom and layout persistence.' },
      { 'new', 'Hidden-screen sleep/replay, configurable character poses and full-screen presentation.' },
      { 'new', 'Lighting and weather-dependent appearance.' },
      { 'fix', 'Character cut-outs and rear-facing panel text handling.' },
    },
  },
  {
    version = '0.3', title = 'Companions',
    blurb = 'Historical development notes; not a compatibility guarantee.',
    items = {
      { 'new', 'Following terminals, character animation and combat transitions.' },
      { 'new', 'Controller gestures, popup taskbar and terminal hotbar commands.' },
      { 'fix', 'Movement hand-back and recovery from a persistent character pose.' },
    },
  },
  {
    version = '0.2', title = 'World panels',
    blurb = 'Historical development notes; not a compatibility guarantee.',
    items = {
      { 'new', 'Pinned and orbiting world terminals, floating windows and resize controls.' },
      { 'new', 'Commands: /term, /tomestone and /tome.' },
    },
  },
  {
    version = '0.1', title = 'Terminal core',
    blurb = 'Historical development notes; not a compatibility guarantee.',
    items = {
      { 'new', 'Drop-down tabs and POSIX agent sessions.' },
      { 'new', 'libghostty-vt terminal state, color, keyboard encoding, paste and scrollback.' },
      { 'new', 'Reattachment while the agent and hosted session remain alive.' },
      { 'fix', 'Terminal versus game-chat keyboard handling.' },
    },
  },
}
local TAG = {
  new = { 'NEW', 0.42, 0.80, 0.62 },
  fix = { 'FIX', 0.92, 0.74, 0.40 },
  beta = { 'BETA', 0.55, 0.70, 0.98 },
  next = { 'PREVIEW', 0.66, 0.62, 0.78 },
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
  end
  ui.wrapped('Ghostty for FFXIV', 0.92, 0.86, 0.72)
  ui.wrapped('Independent developer preview using libghostty-vt, a Nelua core, Lua configuration and C# host adapters. Not an official Ghostty project or a claim of official Dalamud-list acceptance.')
  ui.spacing()
  ui.wrapped('Made by Spaceghost', 0.92, 0.86, 0.72)
  ui.wrapped('github.com/Spaceghost', 0.55, 0.70, 0.98)
  ui.spacing()
  ui.wrapped('Umbra', 0.92, 0.86, 0.72)
  ui.wrapped('The standalone plugin is designed to work without Umbra. The optional widget uses its versioned IPC and displays offline status when the plugin is unavailable. Target-platform and in-game verification remain required.')
  ui.wrapped('User configuration belongs in pluginConfigs/GhosttyDalamud. Back up old Umbra configuration before testing migration. Host-side tests do not validate a game installation.', 0.66, 0.62, 0.78)
  ui.spacing()
  ui.wrapped('Your data', 0.92, 0.86, 0.72)
  ui.wrapped('Local Windows terminals use ConPTY. Agent terminals execute commands on the configured agent host. Keep agent connections on loopback or behind a protected tunnel: the token authenticates, but does not encrypt, the stream. Review logs, terminal output and screenshots before sharing them.')
end
return C
