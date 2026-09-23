-- What the connected agent can do, and what to do about what it cannot.
--
-- The agent says so in its greeting (core/agent_caps.nelua); the core hands it
-- to Lua as ghostty.agent_status().caps. Everything a player reads about it is
-- here: the labels, the hints and the layout. settings.lua draws it under
-- "Agent" in the Settings tab.
local M = {}

-- One row per feature, in the order they are shown. `why` is the one-line hint
-- for each state that is not `on`; `platform` hints override it where a
-- feature does not apply to that platform at all.
M.features = {
  {
    key = 'compositor',
    label = 'Desktop windows (Wayland compositor)',
    why = {
      absent = 'This agent has no compositor: install the Fedora 44 RPM (.fc44) or the container image (packaging/README-agent.md).',
      off = 'Built in but not running: see the agent log (journalctl --user -u ghostty-agent).',
    },
    platform = {
      windows = 'Not needed on Windows: desktop windows are captured directly.',
      macos = 'Not needed on macOS: desktop windows are captured directly.',
    },
  },
  {
    key = 'netlab',
    label = 'Netlab (moq over iroh)',
    why = {
      absent = 'This agent was built without netlab: install an agent package that includes it (RPM, tarball, Windows zip or container), or build with vendor/moq-iroh (docs/NETLAB.md).',
      off = 'Built in but not running: see the agent log.',
    },
  },
  {
    key = 'wg',
    label = 'Embedded WireGuard',
    why = {
      absent = 'Not in this agent yet: update ghostty-agent to one with WireGuard built in.',
      off = 'Built in, but no tunnel is up: add a peer with `ghostty-agent wg add` (it stays off while Tailscale runs).',
    },
  },
}

M.UNKNOWN = 'This agent does not report its features (it is older than this plugin): update ghostty-agent to see them.'
M.OFFLINE = 'No agent connected.'

-- The rows for a status table: { title, note, rows = { {label, state, hint}, ... } }.
-- `note` replaces the rows when there is nothing to list (no agent, or an
-- older one); a hint is nil for a feature that is on.
function M.rows(status)
  local out = { rows = {} }
  if type(status) ~= 'table' or not status.connected then
    out.title = 'Agent: not connected'
    out.note = M.OFFLINE
    return out
  end
  local where = (status.agent and status.agent ~= '') and (' at ' .. status.agent) or ''
  if type(status.caps) ~= 'table' then
    out.title = 'Agent' .. where .. ' (protocol ' .. tostring(status.version or '?') .. ')'
    out.note = M.UNKNOWN
    return out
  end
  local version = (status.agent_version and status.agent_version ~= '') and status.agent_version or '?'
  local platform = (status.platform and status.platform ~= '') and status.platform or '?'
  out.title = 'Agent ' .. version .. ' on ' .. platform .. where .. ' (protocol ' .. tostring(status.version or '?') .. ')'
  for _, f in ipairs(M.features) do
    local state = status.caps[f.key]
    if state ~= 'on' and state ~= 'off' and state ~= 'absent' then state = 'unknown' end
    local hint
    if state ~= 'on' then
      hint = (f.platform and f.platform[platform]) or f.why[state] or M.UNKNOWN
    end
    out.rows[#out.rows + 1] = { label = f.label, state = state, hint = hint, key = f.key }
  end
  return out
end

local COLOURS = {
  on = { 0.52, 0.84, 0.56 },
  off = { 0.92, 0.74, 0.40 },
  absent = { 0.72, 0.74, 0.78 },
  unknown = { 0.72, 0.74, 0.78 },
}
local HINT = { 0.72, 0.74, 0.78 }

-- Draw it: a collapsing header, then one line per feature and its hint.
function M.draw(ui, status)
  if not ui.header('Agent') then return end
  local r = M.rows(status)
  ui.text(r.title)
  if r.note then
    ui.wrapped(r.note, HINT[1], HINT[2], HINT[3])
    return
  end
  for _, row in ipairs(r.rows) do
    local c = COLOURS[row.state] or HINT
    ui.wrapped(row.label .. ': ' .. row.state, c[1], c[2], c[3])
    if row.hint then ui.wrapped('  ' .. row.hint, HINT[1], HINT[2], HINT[3]) end
  end
end

return M
