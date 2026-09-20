-- Pure policy test: no game, no agent, no shell executable required.
-- The shipped defaults must be right for each platform the core reports
-- (lua/platform.lua), because the first profile is what opens on first run.
package.path = 'lua/?.lua;' .. package.path -- only lua/platform.lua is under test
for _, name in ipairs({ 'keymap', 'world', 'animation', 'bell', 'rain', 'showcase', 'assistant',
                        'ask', 'themes', 'tooltips', 'windows', 'adopt', 'gallery' }) do
  package.preload[name] = function() return {} end
end
package.preload.settings = function() return { apply = function(c) return c end } end

local reported
ghostty = { platform = function() return reported end }

local function load_for(platform)
  reported = platform
  for _, name in ipairs({ 'platform' }) do package.loaded[name] = nil end
  return dofile('lua/init.lua')
end

-- Native Windows: ghostty-agent.exe on the same machine, with a local ConPTY
-- shell to fall back to while no agent answers, and the token under APPDATA.
local w = load_for('windows')
assert(w.default_profile == 1)
local p = w.profiles[w.default_profile]
assert(p.transport == 'agent' and p.command[1] == 'powershell.exe', 'windows opens PowerShell through the agent')
assert(p.fallback == 'powershell (local)', 'and falls back to a local ConPTY shell')
local fallbacks = 0
for _, prof in ipairs(w.profiles) do
  if prof.transport == 'conpty' then fallbacks = fallbacks + 1 end
end
assert(fallbacks >= 2, 'the local ConPTY fallbacks are shipped too')
assert(w.agent.token_file:find('ghostty%-agent') and w.agent.token_file:find('\\'),
  'the Windows token file is a Windows path')

-- Wine/Proton on Linux, and the host builds: the POSIX agent and its token
-- under ~/.config, exactly as before lua/platform.lua existed.
for _, platform in ipairs({ 'wine', 'posix', 'linux', 'macos', 'unknown' }) do
  local c = load_for(platform)
  assert(c.default_profile == 1)
  assert(c.profiles[1].transport == 'agent' and c.profiles[1].command[1] == '/bin/sh',
    'the shipped POSIX default must not require bash: ' .. platform)
  assert(c.profiles[2].command[1] == '/bin/bash', platform)
  assert(c.profiles[3].command[1] == 'tmux', platform)
  assert(c.agent.token_file == (os.getenv('HOME') or os.getenv('USERPROFILE') or '') ..
    '/.config/ghostty-agent/token', platform)
end

-- Never a token in the shipped defaults, on any platform.
for _, platform in ipairs({ 'windows', 'wine', 'posix' }) do
  assert(load_for(platform).agent.token == '', 'no token ships with the plugin')
end

print('platform default policy OK')
