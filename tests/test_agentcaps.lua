-- Pure Lua: what the Settings tab says about the agent's features
-- (lua/agentcaps.lua), for a current agent, an older one and none at all.
package.path = 'lua/?.lua;' .. package.path
local agentcaps = require('agentcaps')

local function status(caps, extra)
  local s = { connected = true, version = 4, agent = '127.0.0.1:7777', caps = caps,
              agent_version = '0.3.1', platform = 'linux' }
  for k, v in pairs(extra or {}) do s[k] = v end
  return s
end
local function row(r, key)
  for _, x in ipairs(r.rows) do if x.key == key then return x end end
end

-- Everything on: no hints, the title names the version, platform and protocol.
local r = agentcaps.rows(status({ compositor = 'on', netlab = 'on', wg = 'on' }))
assert(r.title == 'Agent 0.3.1 on linux at 127.0.0.1:7777 (protocol 4)', r.title)
assert(r.note == nil and #r.rows == 3, 'three feature rows')
for _, x in ipairs(r.rows) do assert(x.state == 'on' and x.hint == nil, x.key) end

-- A Linux agent without netlab and the compositor: one clear hint each.
r = agentcaps.rows(status({ compositor = 'absent', netlab = 'absent', wg = 'absent' }))
assert(row(r, 'netlab').hint:find('built without netlab', 1, true), row(r, 'netlab').hint)
assert(row(r, 'compositor').hint:find('.fc44', 1, true), 'the compositor hint names the package that has it')
assert(row(r, 'wg').hint:find('not in this agent yet', 1, true) or row(r, 'wg').hint:find('Not in this agent yet', 1, true))
for _, x in ipairs(r.rows) do
  assert(not x.hint:find('\n'), 'every hint is one line: ' .. x.key)
end

-- Built in but not running: the hint points at the log.
r = agentcaps.rows(status({ compositor = 'off', netlab = 'on', wg = 'absent' }))
assert(row(r, 'compositor').state == 'off' and row(r, 'compositor').hint:find('log', 1, true))
assert(row(r, 'netlab').hint == nil)

-- Windows has no compositor and needs none: say so rather than "install".
r = agentcaps.rows(status({ compositor = 'absent', netlab = 'on', wg = 'absent' }, { platform = 'windows' }))
assert(row(r, 'compositor').hint:find('Not needed on Windows', 1, true), row(r, 'compositor').hint)

-- A value from a newer agent this plugin does not know: unknown, not a crash.
r = agentcaps.rows(status({ compositor = 'sideways', netlab = 'on' }))
assert(row(r, 'compositor').state == 'unknown' and row(r, 'wg').state == 'unknown')

-- An older agent sends no capabilities: one line telling the player to update.
r = agentcaps.rows({ connected = true, version = 4, agent = '127.0.0.1:7777' })
assert(r.note == agentcaps.UNKNOWN and #r.rows == 0, 'an older agent is "update", not guessed')
assert(r.title == 'Agent at 127.0.0.1:7777 (protocol 4)', r.title)

-- No agent, or no status at all (an older core).
assert(agentcaps.rows({ connected = false }).note == agentcaps.OFFLINE)
assert(agentcaps.rows(nil).note == agentcaps.OFFLINE)

-- The layout: header, title, and per feature a coloured state line and its hint.
local drawn = {}
local ui = {
  header = function() return true end,
  text = function(t) drawn[#drawn + 1] = t end,
  wrapped = function(t) drawn[#drawn + 1] = t end,
}
agentcaps.draw(ui, status({ compositor = 'on', netlab = 'absent', wg = 'absent' }))
assert(#drawn == 1 + 3 + 2, 'title, three state lines, two hints: got ' .. #drawn)
assert(drawn[3]:find('^Netlab') and drawn[4]:find('built without netlab', 1, true))
drawn = {}
agentcaps.draw({ header = function() return false end, text = error, wrapped = error }, status({}))
assert(#drawn == 0, 'a closed header draws nothing')

print('test_agentcaps ok')
