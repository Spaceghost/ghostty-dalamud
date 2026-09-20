-- lua/platform.lua and the shipped lua/init.lua per platform (run by
-- tests/test_platform.nelua, which provides the core's ghostty table): the
-- host build says where it runs, native Windows gets the Windows agent with
-- local ConPTY fallbacks, and everywhere else opens a shell the agent host is
-- sure to have.
local ROOT, SCRATCH = ...
package.path = ROOT .. '/lua/?.lua;' .. package.path
local platform = require('platform')

-- the host build (these tests) is never Windows or Wine
local here = platform.name()
assert(here == 'linux' or here == 'macos' or here == 'posix', 'host platform: ' .. tostring(here))

local function env(t) return function(k) return t[k] end end

local function by_name(profiles, name)
  for _, p in ipairs(profiles) do if p.name == name then return p end end
end

-- native Windows
do
  local d = platform.defaults('windows', env({ APPDATA = 'C:\\Users\\player\\AppData\\Roaming', HOME = '/should/not/be/used' }))
  assert(d.agent.host == '127.0.0.1' and d.agent.port == 7777 and d.agent.token == '')
  assert(d.agent.token_file == 'C:\\Users\\player\\AppData\\Roaming\\ghostty-agent\\token', d.agent.token_file)
  assert(d.profiles[1].transport == 'agent', 'the default profile goes through the agent')
  local agents = 0
  for _, p in ipairs(d.profiles) do
    assert(p.command[1]:match('%.exe$'), 'Windows commands: ' .. p.command[1])
    if p.transport == 'agent' then
      agents = agents + 1
      local f = by_name(d.profiles, p.fallback)
      assert(f and f.transport == 'conpty', 'agent profile ' .. p.name .. ' falls back to a local shell')
      assert(f.command[1] == p.command[1], 'the fallback runs the same shell')
    else
      assert(p.transport == 'conpty' and p.fallback == nil)
    end
  end
  assert(agents >= 2)
  -- no APPDATA: from the user profile
  local d2 = platform.defaults('windows', env({ USERPROFILE = 'C:\\Users\\player' }))
  assert(d2.agent.token_file == 'C:\\Users\\player\\AppData\\Roaming\\ghostty-agent\\token', d2.agent.token_file)
end

-- Wine (and host builds): the POSIX agent defaults. /bin/sh opens first so the
-- shipped default needs no bash on the agent host; bash is the profile after it.
local function assert_classic(d, home)
  assert(d.agent.host == '127.0.0.1' and d.agent.port == 7777 and d.agent.token == '')
  assert(d.agent.token_file == home .. '/.config/ghostty-agent/token', d.agent.token_file)
  local want = {
    { 'shell', 'agent', { '/bin/sh' } },
    { 'bash', 'agent', { '/bin/bash', '-l' } },
    { 'tmux', 'agent', { 'tmux', 'new-session', '-A', '-s', 'ghostty' } },
    { 'powershell', 'conpty', { 'pwsh.exe', '-NoLogo' } },
    { 'cmd', 'conpty', { 'cmd.exe' } },
  }
  assert(#d.profiles == #want, 'profile count')
  for i, w in ipairs(want) do
    local p = d.profiles[i]
    assert(p.name == w[1] and p.transport == w[2] and p.fallback == nil, 'profile ' .. i)
    assert(table.concat(p.command, ' ') == table.concat(w[3], ' '), 'command ' .. i)
  end
end
assert_classic(platform.defaults('wine', env({ HOME = '/home/player' })), '/home/player')
assert_classic(platform.defaults('linux', env({ HOME = '/home/player' })), '/home/player')
assert_classic(platform.defaults('wine', env({ USERPROFILE = 'C:\\users\\player' })), 'C:\\users\\player')
assert_classic(platform.defaults('unknown', env({})), '')

-- the shipped init.lua follows ghostty.platform()
GHOSTTY_PLUGIN_DIR = SCRATCH
local real = ghostty.platform
local function load_init(name)
  ghostty.platform = function() return name end
  for _, m in ipairs({ 'platform', 'settings', 'keymap', 'world', 'animation', 'bell', 'showcase' }) do package.loaded[m] = nil end
  local cfg = dofile(ROOT .. '/lua/init.lua')
  ghostty.platform = real
  return cfg
end
local win = load_init('windows')
assert(win.profiles[1].name == 'powershell' and win.profiles[1].fallback == 'powershell (local)')
assert(win.agent.token_file:find('\\ghostty-agent\\token', 1, true), win.agent.token_file)
local wine = load_init('wine')
assert(wine.profiles[1].name == 'shell' and wine.profiles[1].command[1] == '/bin/sh')
assert(wine.profiles[2].name == 'bash' and wine.profiles[2].command[1] == '/bin/bash')
assert(wine.agent.token_file:find('/.config/ghostty-agent/token', 1, true), wine.agent.token_file)
print('platform defaults OK')
