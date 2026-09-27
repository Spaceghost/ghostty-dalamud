-- Hosts added from Settings -> Agent hosts.  Connection secrets live in the
-- user's config directory, never in the shipped init.lua.  Pairing runs the
-- fixed `ghostty-agent pair` command through ssh on the local agent; BatchMode
-- deliberately permits keys/ssh-agent only, so a password is never captured
-- by a hidden job or retained by the plugin.
local M = { hosts = {}, draft = { id = '', label = '', ssh = '', via = 'local', address = '', port = '7777', token_file = '' }, status = '' }

local DATA = (GHOSTTY_CONFIG_DIR or GHOSTTY_PLUGIN_DIR or '.') .. '/agent-hosts.lua'
local PREFIX = 'GHOSTTY_PAIR_V1\t'

local function valid_id(s)
  return type(s) == 'string' and s ~= 'local' and s ~= 'default'
    and #s > 0 and #s <= 64 and s:match('^[%w_.%-]+$') ~= nil
end

local function valid_ssh(s)
  return type(s) == 'string' and #s > 0 and #s <= 200 and s:sub(1, 1) ~= '-'
    and s:match('^[%w_.@:%-%[%]]+$') ~= nil
end

local function valid_address(s)
  return type(s) == 'string' and #s <= 200 and (s == '' or s:match('^[%w_.:%-%[%]]+$') ~= nil)
end

local function valid_remote_path(s)
  return type(s) == 'string' and #s <= 240 and (s == ''
    or (s:sub(1, 1) ~= '-' and s:match('^[%w_./~:%-\\]+$') ~= nil))
end

local function read()
  local chunk, err = loadfile(DATA, 't', {})
  if not chunk then return {}, err end
  local ok, value = pcall(chunk)
  if not ok or type(value) ~= 'table' then return {}, ok and 'not a table' or tostring(value) end
  local out = {}
  for id, h in pairs(value) do
    local port = math.floor(tonumber(type(h) == 'table' and h.port) or 7777)
    if valid_id(id) and type(h) == 'table' and valid_address(h.host or '')
      and h.host ~= '' and port >= 1 and port <= 65535
      and type(h.token) == 'string' and h.token ~= '' then
      out[id] = {
        label = type(h.label) == 'string' and h.label ~= '' and h.label or id,
        host = h.host, port = port, token = h.token,
      }
    end
  end
  return out
end

local function save()
  local ids = {}
  for id in pairs(M.hosts) do ids[#ids + 1] = id end
  table.sort(ids)
  local lines = { '-- Written by Ghostty Agent hosts. Contains bearer tokens; keep private.\nreturn {\n' }
  for _, id in ipairs(ids) do
    local h = M.hosts[id]
    lines[#lines + 1] = string.format('  [%q] = { label = %q, host = %q, port = %d, token = %q },\n',
      id, h.label, h.host, h.port, h.token)
  end
  lines[#lines + 1] = '}\n'
  -- Create first, make private, then truncate through the same inode.  On
  -- POSIX this preserves 0600; on Windows/Wine it preserves the owner DACL.
  local f = io.open(DATA, 'a')
  if not f then return false, 'cannot create ' .. DATA end
  f:close()
  if ghostty and ghostty.make_private and not ghostty.make_private(DATA) then
    return false, 'cannot make ' .. DATA .. ' private'
  end
  f = io.open(DATA, 'w')
  if not f then return false, 'cannot write ' .. DATA end
  f:write(table.concat(lines))
  f:close()
  return true
end

local function add_profiles(config, id, label)
  config.profiles = type(config.profiles) == 'table' and config.profiles or {}
  local seen = false
  for _, p in ipairs(config.profiles) do if p.agent == id then seen = true break end end
  if seen then return end
  config.profiles[#config.profiles + 1] = {
    name = label .. ' / bash', transport = 'agent', agent = id,
    command = { '/bin/bash', '-l' },
  }
  config.profiles[#config.profiles + 1] = {
    name = label .. ' / tmux', transport = 'agent', agent = id,
    command = { 'tmux', 'new-session', '-A', '-s', 'ghostty' },
  }
end

local function parse_pair(line)
  if type(line) ~= 'string' or line:sub(1, #PREFIX) ~= PREFIX then return nil end
  local host, port, token = line:sub(#PREFIX + 1):match('^([^\t]+)\t(%d+)\t([^\t]+)$')
  port = tonumber(port)
  if not valid_address(host or '') or host == '' or not port or port < 1 or port > 65535
    or not token or token == '' or token:find('[%s]') then return nil end
  return { host = host, port = port, token = token }
end

local function pair_line(id, line)
  local job = M.job
  if not job or job.id ~= id then return false end
  local got = parse_pair(line)
  if got then job.pair = got
  elseif line:match('%S') then job.noise = line:sub(1, 240) end
  return true
end

local function pair_exit(id, status, refused)
  local job = M.job
  if not job or job.id ~= id then return false end
  M.job = nil
  if refused or status ~= 0 or not job.pair then
    M.status = refused and 'The local agent could not start ssh.'
      or job.noise or ('Pairing ended without a pairing line (status ' .. tostring(status) .. ').')
    return true
  end
  M.hosts[job.host_id] = {
    label = job.label ~= '' and job.label or job.host_id,
    host = job.pair.host, port = job.pair.port, token = job.pair.token,
  }
  local ok, err = save()
  if ok then
    M.status = 'Paired and saved privately. Run /term reload to connect and add bash/tmux.'
    M.draft.id, M.draft.label, M.draft.ssh, M.draft.via, M.draft.address, M.draft.port, M.draft.token_file = '', '', '', 'local', '', '7777', ''
  else
    M.hosts[job.host_id] = nil
    M.status = err
  end
  return true
end

local function hook_jobs(config)
  local ask = config.ask
  if type(ask) ~= 'table' or ask._agenthosts_hooked then return end
  local old_line, old_exit = ask.on_line, ask.on_exit
  ask.on_line = function(id, line)
    if pair_line(id, line) then return end
    if old_line then return old_line(id, line) end
  end
  ask.on_exit = function(id, status, refused)
    if pair_exit(id, status, refused) then return end
    if old_exit then return old_exit(id, status, refused) end
  end
  ask._agenthosts_hooked = true
end

function M.apply(config)
  M.hosts = read()
  config.agents = type(config.agents) == 'table' and config.agents or {}
  for id, h in pairs(M.hosts) do
    if config.agents[id] == nil then
      config.agents[id] = { label = h.label, host = h.host, port = h.port, token = h.token }
      add_profiles(config, id, h.label)
    end
  end
  hook_jobs(config)
  return config
end

local function field(ui, key, label)
  local changed, value = ui.input(label .. '##agenthost_' .. key, M.draft[key] or '')
  if changed then M.draft[key] = value end
end

function M.start_pair()
  if M.job then return false, 'Pairing is already running.' end
  local d = M.draft
  if not valid_id(d.id) then return false, 'ID: letters, numbers, dot, dash or underscore; not local/default.' end
  if M.hosts[d.id] then return false, 'That managed host already exists.' end
  if not valid_ssh(d.ssh) then return false, 'SSH target must look like user@host or an SSH config alias.' end
  if d.via ~= 'local' and not valid_id(d.via) then return false, 'Run SSH from must be local or an agent ID.' end
  if not valid_address(d.address) then return false, 'Address may contain only hostname/IP characters.' end
  if not valid_remote_path(d.token_file) then return false, 'Token file contains unsafe path characters.' end
  local port = tonumber(d.port)
  if not port or port ~= math.floor(port) or port < 1 or port > 65535 then return false, 'Port must be 1 to 65535.' end
  if not (ghostty and ghostty.ask_spawn) then return false, 'This core cannot run a pairing job.' end
  local argv = { 'ssh', '-o', 'BatchMode=yes', '-o', 'ConnectTimeout=10', '--', d.ssh,
    'ghostty-agent', 'pair', '--port', tostring(port) }
  if d.address ~= '' then
    argv[#argv + 1] = '--host'
    argv[#argv + 1] = d.address
  end
  if d.token_file ~= '' then
    argv[#argv + 1] = '--token-file'
    argv[#argv + 1] = d.token_file
  end
  local id, err = ghostty.ask_spawn(argv, 'agent', false, d.via)
  if not id then return false, err or 'could not start ssh' end
  M.job = { id = id, host_id = d.id, label = d.label }
  return true
end

function M.draw(ui)
  if not ui.header('Agent hosts') then return end
  ui.wrapped('Add a Linux host over SSH. It needs ghostty-agent installed and SSH key authentication; passwords are never captured. The resulting token file is private.', 0.72, 0.74, 0.78)
  local ids = {}
  for id in pairs(M.hosts) do ids[#ids + 1] = id end
  table.sort(ids)
  for _, id in ipairs(ids) do
    local h = M.hosts[id]
    if ui.button('Remove##agenthost_remove_' .. id) then
      M.hosts[id] = nil
      local ok, err = save()
      M.status = ok and 'Removed. Run /term reload to disconnect it.' or err
    end
    ui.same_line()
    ui.text(h.label .. '  (' .. id .. ', ' .. h.host .. ':' .. h.port .. ')')
  end
  if #ids > 0 then ui.separator() end
  field(ui, 'id', 'ID')
  field(ui, 'label', 'Display name')
  field(ui, 'ssh', 'SSH target')
  field(ui, 'via', 'Run SSH from (agent ID)')
  field(ui, 'address', 'Agent address (optional; auto-detects Tailscale)')
  field(ui, 'port', 'Agent port')
  field(ui, 'token_file', 'Remote token file (optional)')
  if ui.button((M.job and 'Pairing...' or 'Pair over SSH') .. '##agenthost_pair') and not M.job then
    local ok, err = M.start_pair()
    M.status = ok and 'Pairing over SSH...' or err
  end
  if M.status ~= '' then ui.wrapped(M.status, 0.92, 0.74, 0.40) end
end

M.parse_pair = parse_pair -- pure seam for tests
return M
