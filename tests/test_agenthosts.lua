local dir = 'build/test-agenthosts'
os.execute('mkdir -p ' .. dir)
package.path = 'lua/?.lua;' .. package.path
GHOSTTY_CONFIG_DIR = dir
ghostty = { make_private = function() return true end }

package.loaded.agenthosts = nil
local H = require('agenthosts')

local p = H.parse_pair('GHOSTTY_PAIR_V1\t100.64.0.20\t7788\tsecret-token')
assert(p and p.host == '100.64.0.20' and p.port == 7788 and p.token == 'secret-token')
assert(not H.parse_pair('GHOSTTY_PAIR_V1\tbad host\t7788\tsecret'))
assert(not H.parse_pair('GHOSTTY_PAIR_V1\t100.64.0.20\t0\tsecret'))
assert(not H.parse_pair('noise'))

local f = assert(io.open(dir .. '/agent-hosts.lua', 'w'))
f:write([[return {
  workstation = { label = 'Workstation', host = '100.64.0.20', port = 7788, token = 'secret-token' },
}]])
f:close()
local config = { profiles = {}, ask = {} }
H.apply(config)
assert(config.agents.workstation.label == 'Workstation')
assert(config.agents.workstation.token == 'secret-token')
assert(#config.profiles == 2 and config.profiles[1].agent == 'workstation' and config.profiles[2].agent == 'workstation')
assert(type(config.ask.on_line) == 'function' and type(config.ask.on_exit) == 'function')

local spawned
ghostty.ask_spawn = function(argv, transport, fallback, via)
  spawned = { argv = argv, transport = transport, fallback = fallback, via = via }
  return 41
end
H.draft = { id = 'server', label = 'Home server', ssh = 'me@server', via = 'workstation', address = '100.64.0.30', port = '7789', token_file = '~/.config/ghostty-agent/token' }
local ok, err = H.start_pair()
assert(ok, err)
assert(spawned.transport == 'agent' and spawned.fallback == false and spawned.via == 'workstation')
assert(table.concat(spawned.argv, ' ') ==
  'ssh -o BatchMode=yes -o ConnectTimeout=10 -- me@server ghostty-agent pair --port 7789 --host 100.64.0.30 --token-file ~/.config/ghostty-agent/token')
config.ask.on_line(41, 'GHOSTTY_PAIR_V1\t100.64.0.30\t7789\tpaired-secret')
config.ask.on_exit(41, 0, false)
assert(H.hosts.server and H.hosts.server.token == 'paired-secret')
local saved = assert(loadfile(dir .. '/agent-hosts.lua', 't', {}))()
assert(saved.server.label == 'Home server' and saved.server.port == 7789)

print('agent hosts OK')
