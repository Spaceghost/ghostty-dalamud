-- Pure policy test: no game, agent or optional shell executable required.
for _, name in ipairs({'keymap', 'world', 'animation', 'bell', 'showcase'}) do
  package.preload[name] = function() return {} end
end
package.preload.settings = function() return { apply = function(c) return c end } end
for _, platform in ipairs({'windows', 'wine', 'posix'}) do
  GHOSTTY_PLATFORM = platform
  local c = dofile('lua/init.lua')
  assert(c.profiles[c.default_profile].transport == (platform == 'windows' and 'conpty' or 'agent'))
  assert(c.profiles[1].command[1] == '/bin/sh')
  assert(c.profiles[3].command[1] == 'powershell.exe')
  assert(c.profiles[4].command[1] == 'cmd.exe')
  assert(c.agent.token == '')
end
print('platform default policy OK')
